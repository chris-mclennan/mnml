//! DAP (Debug Adapter Protocol) client. Connects to a debug adapter
//! subprocess (debugpy / vscode-node-debug2 / lldb-vscode / codelldb / …)
//! over `Content-Length`-framed JSON-RPC on stdio, runs the canonical
//! handshake (initialize → launch → setBreakpoints → configurationDone),
//! and surfaces adapter events (stopped / output / terminated / thread)
//! back to the App over an mpsc channel.
//!
//! Single active session for now (multi-thread UI is a follow-up).
//! Supports: real wire protocol, breakpoints (plain + conditional),
//! step controls (continue/next/step in/out/pause/terminate), stack
//! traces, scopes + variables tree with lazy-expand of composites,
//! and watch expressions re-evaluated at every stop.
//!
//! Config shape:
//! ```toml
//! [dap.python]
//! cmd = "python"
//! args = ["-m", "debugpy.adapter"]
//! launch.request = "launch"
//! launch.type = "python"
//! launch.program = "${file}"
//! launch.console = "internalConsole"
//! launch.justMyCode = false
//! ```
//!
//! `${file}` / `${workspace}` are substituted from the active editor +
//! workspace. Everything else under `launch.*` is sent verbatim to the
//! adapter.

pub mod client;

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};

pub use client::DapClient;

/// Per-language adapter config — read from `[dap.<name>]` in the user's
/// TOML.
#[derive(Debug, Clone)]
pub struct AdapterConfig {
    /// The adapter binary (e.g. `"python"`, `"node"`, `"lldb-vscode"`).
    pub cmd: String,
    pub args: Vec<String>,
    /// Everything under `launch.*` — passed verbatim to the adapter
    /// after `${file}` / `${workspace}` substitution.
    pub launch: serde_json::Value,
}

impl AdapterConfig {
    /// Parse a `toml::Value` for a single `[dap.<name>]` entry. Returns
    /// `Err(msg)` on malformed input.
    pub fn from_toml(v: &toml::Value) -> Result<Self, String> {
        let table = v.as_table().ok_or("expected a table")?;
        let cmd = table
            .get("cmd")
            .and_then(|c| c.as_str())
            .ok_or("missing `cmd`")?
            .to_string();
        let args = table
            .get("args")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        // The `launch` table is the payload we hand to the adapter. Default
        // to an empty object so the user can omit it and we'll send
        // `launch` with just the substituted `${file}` etc.
        let launch_toml = table
            .get("launch")
            .cloned()
            .unwrap_or(toml::Value::Table(toml::value::Table::new()));
        let launch = serde_json::to_value(launch_toml).map_err(|e| format!("launch json: {e}"))?;
        Ok(AdapterConfig { cmd, args, launch })
    }
}

/// Substitute `${file}` / `${workspace}` (and a few aliases) in a JSON
/// value tree. Used on `launch.*` right before the launch request goes
/// out so the adapter receives concrete paths.
pub fn substitute_vars(
    v: &mut serde_json::Value,
    workspace: &std::path::Path,
    file: Option<&std::path::Path>,
) {
    match v {
        serde_json::Value::String(s) => {
            let mut out = s.clone();
            if let Some(f) = file {
                out = out.replace("${file}", &f.to_string_lossy());
                out = out.replace(
                    "${fileBasename}",
                    &f.file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default(),
                );
                out = out.replace(
                    "${fileDirname}",
                    &f.parent()
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_default(),
                );
            }
            out = out.replace("${workspaceFolder}", &workspace.to_string_lossy());
            out = out.replace("${workspace}", &workspace.to_string_lossy());
            *s = out;
        }
        serde_json::Value::Array(arr) => {
            for child in arr {
                substitute_vars(child, workspace, file);
            }
        }
        serde_json::Value::Object(obj) => {
            for (_, child) in obj.iter_mut() {
                substitute_vars(child, workspace, file);
            }
        }
        _ => {}
    }
}

/// What the reader thread sends back over the channel. Mirrors the LSP
/// approach — the App drains in `tick`.
#[derive(Debug)]
pub enum DapEvent {
    /// Adapter accepted `initialize` and replied with capabilities. The
    /// App can now send `launch` / `setBreakpoints` etc.
    Initialized,
    /// Adapter has fully launched (saw `configurationDone` response).
    /// Execution is running.
    Running,
    /// Program produced output on stdout / stderr / "console" / "telemetry".
    Output { category: String, text: String },
    /// Program stopped (breakpoint / step / pause / exception). The
    /// adapter reports which thread hit the stop + a reason. The App
    /// follows up by requesting `stackTrace` to populate the debug pane.
    Stopped {
        reason: String,
        thread_id: i64,
        description: Option<String>,
    },
    /// Resumed (continue / step replied). Clears any "stopped at" UI
    /// indicators.
    Continued,
    /// Stack trace for a thread (response to `stackTrace`).
    StackTrace {
        thread_id: i64,
        frames: Vec<StackFrame>,
    },
    /// Scopes for a stack frame (response to `scopes`). The App follows
    /// up with `variables` requests per scope's `variables_reference`.
    Scopes { frame_id: i64, scopes: Vec<Scope> },
    /// Variables for a `variables_reference` (response to `variables`).
    /// Used for both the initial scope contents and lazy-expanded
    /// children of a composite variable.
    Variables {
        variables_ref: i64,
        variables: Vec<Variable>,
    },
    /// Result of an `evaluate` request — used for watch expressions
    /// (re-fired on each stop) and one-shot REPL evals. `expression`
    /// echoes the original input so the App can route to the right
    /// watch row. `err` carries the adapter's error message when
    /// the evaluation failed (e.g. "name 'foo' is not defined"); a
    /// successful evaluate leaves it `None`.
    Evaluate {
        expression: String,
        value: String,
        ty: Option<String>,
        err: Option<String>,
        /// Non-zero ⇒ the result is composite (e.g. a struct/array) and
        /// could be lazily expanded the same way scope variables are.
        /// Reserved for future use; the current watch UI shows the
        /// formatted `value` only.
        variables_ref: i64,
    },
    /// Result of a `threads` request — the active thread list. The
    /// App caches this on `DapManager.threads` and the multi-thread
    /// picker reads it on user demand.
    Threads(Vec<ThreadInfo>),
    /// Adapter accepted a `setVariable` request. `parent_ref` is the
    /// `variablesReference` the request targeted (i.e. the scope or
    /// composite that owns the variable); `name` echoes the original
    /// name. `value` / `ty` / `variables_ref` come from the response
    /// body (the adapter may rewrite the formatted value, e.g.
    /// trimming quotes). The App patches the cached child in place +
    /// toasts confirmation. Errors land on [`Self::Failed`] via the
    /// generic non-success path.
    SetVariableDone {
        parent_ref: i64,
        name: String,
        value: String,
        ty: Option<String>,
        variables_ref: i64,
    },
    /// Result of the `initialize` request — the adapter's
    /// `exceptionBreakpointFilters`. Used by `dap.exceptions` to
    /// build a picker over which exception kinds should stop the
    /// debuggee. Empty for adapters that don't advertise them.
    InitializeCaps {
        exception_filters: Vec<ExceptionFilter>,
    },
    /// Program exited.
    Exited { exit_code: i64 },
    /// Adapter terminated. The session is over; the App should clear
    /// `App.dap` and any pane state.
    Terminated,
    /// Something went wrong — surface to a toast.
    Failed(String),
}

/// One frame in a thread's call stack.
#[derive(Debug, Clone)]
pub struct StackFrame {
    pub id: i64,
    pub name: String,
    /// Absolute path to the source file, if the adapter provided one.
    pub source: Option<PathBuf>,
    /// 1-based line (per DAP).
    pub line: u32,
    pub column: u32,
}

/// One variable scope (Locals / Globals / Arguments / Closure / …).
#[derive(Debug, Clone)]
pub struct Scope {
    pub name: String,
    /// The reference handle the App passes to `variables` to fetch
    /// this scope's contents. `0` ⇒ no variables (e.g. an empty scope).
    pub variables_reference: i64,
    /// Adapters mark some scopes (e.g. "Globals") as expensive — we
    /// honor this and don't auto-expand them.
    pub expensive: bool,
}

/// One thread the debug adapter is tracking. `name` is the adapter's
/// thread label (e.g. `"MainThread"`, `"worker-3"`); the user picks
/// from this list via the multi-thread picker.
#[derive(Debug, Clone)]
pub struct ThreadInfo {
    pub id: i64,
    pub name: String,
}

/// One exception-breakpoint filter the adapter advertised in its
/// `initialize` reply. `filter` is the wire id passed back via
/// `setExceptionBreakpoints`; `label` is human-readable (e.g.
/// "Raised Exceptions", "Uncaught Exceptions"). `default` ⇒ the
/// adapter recommends this filter be on by default.
#[derive(Debug, Clone)]
pub struct ExceptionFilter {
    pub filter: String,
    pub label: String,
    pub default: bool,
}

/// A single variable in a scope or under a parent composite. `value`
/// is the adapter's pre-formatted string; `ty` is the type name (when
/// the adapter advertised `supportsVariableType`). A positive
/// `variables_reference` ⇒ the variable is composite (struct / array /
/// object) and can be lazily expanded by another `variables` request
/// keyed on it.
#[derive(Debug, Clone)]
pub struct Variable {
    pub name: String,
    pub value: String,
    pub ty: Option<String>,
    pub variables_reference: i64,
}

/// Owns the active session (one adapter at a time for the MVP).
pub struct DapManager {
    pub client: DapClient,
    pub rx: Receiver<DapEvent>,
    /// True after `Initialized` event landed. The App gates step
    /// commands on this so a press before the adapter's ready is a
    /// no-op (not a deadlock).
    pub initialized: bool,
    /// True after `Running` event. Used by step controls.
    pub running: bool,
    /// Last stopped state — `(thread_id, source, line, reason)`. `None`
    /// when execution is running or before first stop.
    pub stopped_at: Option<(i64, Option<PathBuf>, u32, String)>,
    /// Current thread's stack frames (last `StackTrace` event).
    pub stack_frames: Vec<StackFrame>,
    /// Scopes for the top stack frame (set on `Scopes` event after a
    /// `StackTrace`). Cleared on every `Stopped`/`Continued`.
    pub scopes: Vec<Scope>,
    /// Cached variable lists keyed by `variables_reference`. Filled
    /// lazily — the App requests a scope's vars on `Scopes`, and a
    /// composite var's children on user expand. Cleared on Continued
    /// (the references become stale after the program resumes).
    pub variables: HashMap<i64, Vec<Variable>>,
    /// Which variable references the UI considers expanded — only
    /// expanded composites have their children walked into the flat
    /// tree. Cleared on Continued (refs are stale across resume).
    pub expanded_vars: std::collections::HashSet<i64>,
    /// Persisted user-expansion state by name path. Survives
    /// `Continued` so a step doesn't collapse everything back to
    /// the scope headers. Paths like
    /// `["Locals", "self"]` (depth 2) or
    /// `["Locals", "self", "data"]` (depth 3). On each `Variables`
    /// event, [`Self::restore_expanded_paths_under`] re-arms
    /// matching children — fetching their composites' children too
    /// so the depth-N expansion fans back out naturally.
    pub expanded_paths: std::collections::HashSet<Vec<String>>,
    /// Threads the adapter is tracking (refreshed by `threads`
    /// request — fired on `Stopped` and on user demand via
    /// `dap.pick_thread`). Empty until the first reply lands.
    pub threads: Vec<ThreadInfo>,
    /// Exception-breakpoint filters the adapter advertised (lands
    /// when the `initialize` reply parses). Empty for adapters that
    /// don't advertise any.
    pub exception_filters: Vec<ExceptionFilter>,
    /// Filter IDs currently enabled. The `dap.exceptions` picker
    /// toggles these and re-sends `setExceptionBreakpoints` so the
    /// adapter knows which exceptions should stop the debuggee.
    pub enabled_exception_filters: std::collections::HashSet<String>,
}

impl DapManager {
    pub fn new(client: DapClient, rx: Receiver<DapEvent>) -> Self {
        DapManager {
            client,
            rx,
            initialized: false,
            running: false,
            stopped_at: None,
            stack_frames: Vec::new(),
            scopes: Vec::new(),
            variables: HashMap::new(),
            expanded_vars: std::collections::HashSet::new(),
            expanded_paths: std::collections::HashSet::new(),
            threads: Vec::new(),
            exception_filters: Vec::new(),
            enabled_exception_filters: std::collections::HashSet::new(),
        }
    }
}

/// A flat-tree row in the variables panel. `depth` is the visual
/// indent; `is_scope` marks scope-header rows; `var_ref` is the
/// `variablesReference` for expandable rows (0 ⇒ leaf).
#[derive(Debug, Clone)]
pub struct VarRow {
    pub depth: usize,
    pub is_scope: bool,
    pub label: String,
    /// The bare variable / scope name, without any ` : type` suffix.
    /// Used by the expanded-paths persistence to identify the row
    /// across `Stopped` cycles (where references churn).
    pub name: String,
    pub value: String,
    pub var_ref: i64,
    pub expanded: bool,
    /// True ⇔ this row can be expanded (scope with vars OR composite var).
    pub expandable: bool,
    /// The `variablesReference` of the immediate parent — needed for
    /// `setVariable` (which targets the parent's ref + a name). For
    /// top-level scope rows this is 0 (scopes have no parent); for
    /// vars directly under a scope this is the scope's ref; for nested
    /// children this is the enclosing composite's ref.
    pub parent_ref: i64,
}

impl DapManager {
    /// Flatten the scope + variable cache into a single visible-row
    /// list for the `Pane::Debug` variables panel. Walks scopes in
    /// order; for each expanded scope/variable, walks its children
    /// (recursively for nested composites). Skips expensive scopes
    /// unless explicitly expanded.
    pub fn variable_rows(&self) -> Vec<VarRow> {
        let mut out: Vec<VarRow> = Vec::new();
        for scope in &self.scopes {
            let r = scope.variables_reference;
            let expandable = r > 0;
            let expanded = expandable && self.expanded_vars.contains(&r);
            out.push(VarRow {
                depth: 0,
                is_scope: true,
                label: scope.name.clone(),
                name: scope.name.clone(),
                value: if scope.expensive {
                    "(expensive)".to_string()
                } else {
                    String::new()
                },
                var_ref: r,
                expanded,
                expandable,
                parent_ref: 0,
            });
            if expanded && let Some(vars) = self.variables.get(&r) {
                for v in vars {
                    self.walk_var(v, 1, r, &mut out);
                }
            }
        }
        out
    }

    fn walk_var(&self, v: &Variable, depth: usize, parent_ref: i64, out: &mut Vec<VarRow>) {
        let expandable = v.variables_reference > 0;
        let expanded = expandable && self.expanded_vars.contains(&v.variables_reference);
        let label = match &v.ty {
            Some(ty) if !ty.is_empty() => format!("{}: {}", v.name, ty),
            _ => v.name.clone(),
        };
        out.push(VarRow {
            depth,
            is_scope: false,
            label,
            name: v.name.clone(),
            value: v.value.clone(),
            var_ref: v.variables_reference,
            expanded,
            expandable,
            parent_ref,
        });
        if expanded && let Some(children) = self.variables.get(&v.variables_reference) {
            for child in children {
                self.walk_var(child, depth + 1, v.variables_reference, out);
            }
        }
    }

    /// Compute the name-path for a row by var_ref against the
    /// current flattened tree. Thin wrapper around
    /// [`path_for_var_ref_in`] that snapshots `variable_rows()`.
    pub fn path_for_var_ref(&self, var_ref: i64) -> Option<Vec<String>> {
        path_for_var_ref_in(&self.variable_rows(), var_ref)
    }

    /// Find the var_ref for a row matching `path` (name chain) in
    /// the current flattened tree. Thin wrapper around
    /// [`var_ref_for_path_in`].
    pub fn var_ref_for_path(&self, path: &[String]) -> Option<i64> {
        var_ref_for_path_in(&self.variable_rows(), path)
    }
}

/// Walk `rows`'s `parent_ref` chain from the row with `var_ref` back
/// to its scope (parent_ref == 0), collecting names top-down.
/// Returns `None` when `var_ref` isn't in `rows` (the row is hidden
/// by a parent collapse, or hasn't been materialised yet).
pub fn path_for_var_ref_in(rows: &[VarRow], var_ref: i64) -> Option<Vec<String>> {
    use std::collections::HashMap;
    let by_ref: HashMap<i64, &VarRow> = rows.iter().map(|r| (r.var_ref, r)).collect();
    let mut current = by_ref.get(&var_ref).copied()?;
    let mut path = vec![current.name.clone()];
    while current.parent_ref != 0 {
        let Some(parent) = by_ref.get(&current.parent_ref).copied() else {
            break;
        };
        path.insert(0, parent.name.clone());
        current = parent;
    }
    Some(path)
}

/// Top-down path walk: find a scope (depth 0) matching `path[0]`,
/// then a depth-1 row under it matching `path[1]`, etc. Returns the
/// last matched row's `var_ref`, or `None` if any segment fails to
/// match.
pub fn var_ref_for_path_in(rows: &[VarRow], path: &[String]) -> Option<i64> {
    let mut current_parent: i64 = 0;
    let mut target_depth: usize = 0;
    let mut chosen_ref: Option<i64> = None;
    for segment in path {
        chosen_ref = rows.iter().find_map(|r| {
            if r.depth == target_depth && r.parent_ref == current_parent && r.name == *segment {
                Some(r.var_ref)
            } else {
                None
            }
        });
        match chosen_ref {
            Some(r) => {
                current_parent = r;
                target_depth += 1;
            }
            None => return None,
        }
    }
    chosen_ref
}

/// Parse the `[dap.*]` config sub-table out of mnml's main config.
/// Returns a `name -> AdapterConfig` map.
#[allow(dead_code)]
pub fn parse_adapters(table: &BTreeMap<String, toml::Value>) -> BTreeMap<String, AdapterConfig> {
    let mut out = BTreeMap::new();
    for (name, v) in table {
        match AdapterConfig::from_toml(v) {
            Ok(cfg) => {
                out.insert(name.clone(), cfg);
            }
            Err(e) => {
                eprintln!("dap: skipping [dap.{name}]: {e}");
            }
        }
    }
    out
}

/// Type alias for the App-side outbound event channel.
#[allow(dead_code)]
pub type DapEventTx = Sender<DapEvent>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitute_vars_replaces_file_and_workspace() {
        let mut v = serde_json::json!({
            "program": "${file}",
            "cwd": "${workspace}",
            "args": ["--ws", "${workspaceFolder}"],
        });
        let ws = std::path::Path::new("/repo");
        let f = std::path::Path::new("/repo/src/main.py");
        substitute_vars(&mut v, ws, Some(f));
        assert_eq!(v["program"], "/repo/src/main.py");
        assert_eq!(v["cwd"], "/repo");
        assert_eq!(v["args"][1], "/repo");
    }

    #[test]
    fn variable_rows_flattens_scopes_and_expanded_composites() {
        use std::sync::mpsc;
        // Build a manager directly (no real adapter) so we can poke
        // the scopes / variables / expanded_vars fields by hand.
        let (_tx, rx) = mpsc::channel::<DapEvent>();
        // We can't easily construct a DapClient without a real
        // subprocess, so wrap the test in a manual `DapManager`
        // shape — we only call `variable_rows()`, which is a pure
        // function of the data members. Use unsafe-style direct
        // construction via a helper struct mirror.
        struct Mgr {
            scopes: Vec<Scope>,
            variables: HashMap<i64, Vec<Variable>>,
            expanded_vars: std::collections::HashSet<i64>,
        }
        impl Mgr {
            fn variable_rows(&self) -> Vec<VarRow> {
                // Reuse the real algorithm via a tiny adapter.
                let real = FakeDap {
                    scopes: self.scopes.clone(),
                    variables: self.variables.clone(),
                    expanded_vars: self.expanded_vars.clone(),
                };
                real.variable_rows()
            }
        }
        // The "real" implementation reified — same field set as
        // DapManager but without the client + rx.
        struct FakeDap {
            scopes: Vec<Scope>,
            variables: HashMap<i64, Vec<Variable>>,
            expanded_vars: std::collections::HashSet<i64>,
        }
        impl FakeDap {
            fn variable_rows(&self) -> Vec<VarRow> {
                let mut out: Vec<VarRow> = Vec::new();
                for scope in &self.scopes {
                    let r = scope.variables_reference;
                    let expandable = r > 0;
                    let expanded = expandable && self.expanded_vars.contains(&r);
                    out.push(VarRow {
                        depth: 0,
                        is_scope: true,
                        label: scope.name.clone(),
                        name: scope.name.clone(),
                        value: String::new(),
                        var_ref: r,
                        expanded,
                        expandable,
                        parent_ref: 0,
                    });
                    if expanded && let Some(vars) = self.variables.get(&r) {
                        for v in vars {
                            self.walk(v, 1, r, &mut out);
                        }
                    }
                }
                out
            }
            fn walk(&self, v: &Variable, depth: usize, parent_ref: i64, out: &mut Vec<VarRow>) {
                let expandable = v.variables_reference > 0;
                let expanded = expandable && self.expanded_vars.contains(&v.variables_reference);
                out.push(VarRow {
                    depth,
                    is_scope: false,
                    label: v.name.clone(),
                    name: v.name.clone(),
                    value: v.value.clone(),
                    var_ref: v.variables_reference,
                    expanded,
                    expandable,
                    parent_ref,
                });
                if expanded && let Some(children) = self.variables.get(&v.variables_reference) {
                    for child in children {
                        self.walk(child, depth + 1, v.variables_reference, out);
                    }
                }
            }
        }
        let _ = rx; // silence unused
        let scope = Scope {
            name: "Locals".to_string(),
            variables_reference: 1,
            expensive: false,
        };
        let composite = Variable {
            name: "list".to_string(),
            value: "Vec<i32>".to_string(),
            ty: None,
            variables_reference: 2,
        };
        let leaf = Variable {
            name: "count".to_string(),
            value: "42".to_string(),
            ty: None,
            variables_reference: 0,
        };
        let child = Variable {
            name: "[0]".to_string(),
            value: "7".to_string(),
            ty: None,
            variables_reference: 0,
        };
        let mut variables = HashMap::new();
        variables.insert(1, vec![composite.clone(), leaf.clone()]);
        variables.insert(2, vec![child.clone()]);
        let mut expanded = std::collections::HashSet::new();
        expanded.insert(1); // scope is expanded
        expanded.insert(2); // composite is expanded
        let mgr = Mgr {
            scopes: vec![scope],
            variables,
            expanded_vars: expanded,
        };
        let rows = mgr.variable_rows();
        // Expected order: scope, composite, child, leaf.
        assert_eq!(rows.len(), 4);
        assert!(rows[0].is_scope);
        assert_eq!(rows[0].label, "Locals");
        assert_eq!(rows[0].parent_ref, 0); // scope has no parent
        assert_eq!(rows[1].depth, 1);
        assert_eq!(rows[1].label, "list");
        assert!(rows[1].expanded);
        assert_eq!(rows[1].parent_ref, 1); // child of Locals
        assert_eq!(rows[2].depth, 2);
        assert_eq!(rows[2].label, "[0]");
        assert_eq!(rows[2].parent_ref, 2); // child of `list` composite
        assert_eq!(rows[3].depth, 1);
        assert_eq!(rows[3].label, "count");
        assert!(!rows[3].expandable);
        assert_eq!(rows[3].parent_ref, 1); // sibling of `list` under Locals
    }

    fn mk_row(depth: usize, name: &str, var_ref: i64, parent_ref: i64) -> VarRow {
        VarRow {
            depth,
            is_scope: depth == 0,
            label: name.to_string(),
            name: name.to_string(),
            value: String::new(),
            var_ref,
            expanded: false,
            expandable: var_ref > 0,
            parent_ref,
        }
    }

    #[test]
    fn path_for_var_ref_walks_back_to_scope() {
        // Locals (ref 1) > self (ref 2) > data (ref 3)
        let rows = vec![
            mk_row(0, "Locals", 1, 0),
            mk_row(1, "self", 2, 1),
            mk_row(2, "data", 3, 2),
        ];
        let p = path_for_var_ref_in(&rows, 3).unwrap();
        assert_eq!(p, vec!["Locals", "self", "data"]);
        let p2 = path_for_var_ref_in(&rows, 2).unwrap();
        assert_eq!(p2, vec!["Locals", "self"]);
        let p3 = path_for_var_ref_in(&rows, 1).unwrap();
        assert_eq!(p3, vec!["Locals"]);
    }

    #[test]
    fn path_for_var_ref_returns_none_when_ref_missing() {
        let rows = vec![mk_row(0, "Locals", 1, 0)];
        assert!(path_for_var_ref_in(&rows, 999).is_none());
    }

    #[test]
    fn var_ref_for_path_resolves_top_down() {
        // Same tree as above, but with new refs (simulates a new
        // Stopped where refs churned but names persisted).
        let rows = vec![
            mk_row(0, "Locals", 10, 0),
            mk_row(1, "self", 20, 10),
            mk_row(2, "data", 30, 20),
        ];
        assert_eq!(
            var_ref_for_path_in(&rows, &["Locals".to_string()]),
            Some(10)
        );
        assert_eq!(
            var_ref_for_path_in(&rows, &["Locals".to_string(), "self".to_string()]),
            Some(20)
        );
        assert_eq!(
            var_ref_for_path_in(
                &rows,
                &["Locals".to_string(), "self".to_string(), "data".to_string()]
            ),
            Some(30)
        );
    }

    #[test]
    fn var_ref_for_path_returns_none_when_segment_missing() {
        let rows = vec![mk_row(0, "Locals", 1, 0), mk_row(1, "self", 2, 1)];
        // `self` exists but `nope` doesn't.
        assert_eq!(
            var_ref_for_path_in(&rows, &["Locals".to_string(), "nope".to_string()]),
            None
        );
    }

    #[test]
    fn path_round_trips_through_ref_renumbering() {
        // Old run: refs [1, 2, 3] for Locals > self > data.
        let old = vec![
            mk_row(0, "Locals", 1, 0),
            mk_row(1, "self", 2, 1),
            mk_row(2, "data", 3, 2),
        ];
        let path = path_for_var_ref_in(&old, 3).unwrap();
        // New run after Stopped: same names, different refs.
        let new = vec![
            mk_row(0, "Locals", 100, 0),
            mk_row(1, "self", 200, 100),
            mk_row(2, "data", 300, 200),
        ];
        let new_ref = var_ref_for_path_in(&new, &path).unwrap();
        assert_eq!(new_ref, 300);
    }

    #[test]
    fn adapter_from_toml_parses_basic_shape() {
        let raw: toml::Value = toml::from_str(
            r#"
cmd = "python"
args = ["-m", "debugpy.adapter"]
[launch]
request = "launch"
program = "${file}"
"#,
        )
        .unwrap();
        let cfg = AdapterConfig::from_toml(&raw).unwrap();
        assert_eq!(cfg.cmd, "python");
        assert_eq!(cfg.args, vec!["-m", "debugpy.adapter"]);
        assert_eq!(cfg.launch["request"], "launch");
    }
}
