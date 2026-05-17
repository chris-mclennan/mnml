//! DAP (Debug Adapter Protocol) client. Connects to a debug adapter
//! subprocess (debugpy / vscode-node-debug2 / lldb-vscode / codelldb / …)
//! over `Content-Length`-framed JSON-RPC on stdio, runs the canonical
//! handshake (initialize → launch → setBreakpoints → configurationDone),
//! and surfaces adapter events (stopped / output / terminated / thread)
//! back to the App over an mpsc channel.
//!
//! This is the *starter MVP* — one active session at a time, no
//! conditional breakpoints, no watches / expression eval, no
//! multi-thread UI. Step controls + a `Pane::Debug` come next.
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

use std::collections::BTreeMap;
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
        }
    }
}

/// Parse the `[dap.*]` config sub-table out of mnml's main config.
/// Returns a `name -> AdapterConfig` map.
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
