//! LSP client subsystem. One [`client::LspClient`] per `(project-root, language)`,
//! each a subprocess speaking JSON-RPC over stdio on its own reader thread; the
//! thread forwards `publishDiagnostics` notifications (and request responses we
//! care about) over an mpsc channel that [`crate::app::App::tick`] drains.
//!
//! Servers come from `[lsp.<name>]` config tables (`cmd`, `args`, `extensions`,
//! `root_markers`); a small built-in default set covers common languages so it
//! works out of the box. Everything degrades gracefully — a server that's not
//! installed / not configured / dies just means no LSP for that language.
//!
//! Known simplifications (first cut): full-text document sync (no incremental);
//! columns are treated as char offsets (LSP uses UTF-16 code units — fine for
//! ASCII, off for astral-plane chars on a line); `initialize` is followed
//! immediately by `initialized` + `didOpen` without waiting for the response
//! (works with rust-analyzer/gopls/pyright/clangd/tsserver in practice).

pub mod client;
pub mod diagnostics_pane;
pub mod outline_pane;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc;

use crate::config::Config;

/// 0-based position, LSP semantics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pos {
    pub line: u32,
    pub character: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Range {
    pub start: Pos,
    pub end: Pos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
    Info,
    Hint,
}

impl Severity {
    fn from_lsp(n: u64) -> Severity {
        match n {
            1 => Severity::Error,
            2 => Severity::Warning,
            3 => Severity::Info,
            _ => Severity::Hint,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub range: Range,
    pub severity: Severity,
    pub message: String,
    /// e.g. `"rustc"`, `"clippy"`, `"eslint"` — the diagnostic's source, if given.
    pub source: Option<String>,
}

/// What the reader thread sends to the event loop.
#[derive(Debug)]
pub enum LspEvent {
    /// New diagnostics for a file (replaces any previous set for that path).
    Diagnostics {
        path: PathBuf,
        diags: Vec<Diagnostic>,
    },
    /// Result of a `textDocument/definition` request — jump here.
    GotoDefinition {
        path: PathBuf,
        line: u32,
        character: u32,
    },
    /// Result of a `textDocument/hover` request — show this (markdown-ish) text.
    Hover { text: String },
    /// Result of a `textDocument/references` request — `(path, line, character)` per hit.
    References(Vec<(PathBuf, u32, u32)>),
    /// Result of a `textDocument/rename` request — a `WorkspaceEdit` flattened to
    /// `(path, [(range, new_text)])` per affected file.
    Rename(Vec<(PathBuf, Vec<(Range, String)>)>),
    /// Result of a `textDocument/completion` request — `(label, insert_text, detail)`
    /// per candidate.
    Completion(Vec<(String, String, Option<String>)>),
    /// Result of a `textDocument/formatting` request — the `TextEdit[]` for `path`.
    Formatting {
        path: PathBuf,
        edits: Vec<(Range, String)>,
    },
    /// Result of a `textDocument/codeAction` request — the available actions at
    /// the requested range, in server order.
    CodeAction(Vec<CodeAction>),
    /// Result of a `textDocument/documentSymbol` request — `(name, kind,
    /// line, character, depth)` per symbol, depth-first (parents before
    /// children; depth = nesting level). Both the hierarchical `DocumentSymbol[]`
    /// reply shape and the legacy flat `SymbolInformation[]` shape feed in here.
    DocumentSymbols(Vec<DocumentSymbol>),
    /// Result of a `workspace/symbol` request — `(name, kind, path, line,
    /// character)` per hit across the whole project. Multiple servers may
    /// each contribute; events are emitted per server reply (the app merges).
    WorkspaceSymbols(Vec<WorkspaceSymbol>),
    /// A server-side message worth surfacing as a toast.
    Message(String),
}

/// A single entry in a `textDocument/documentSymbol` reply. We keep just
/// what the picker / jump needs — name, a short kind label, the position to
/// land the cursor at, and the nesting depth (so the picker can indent
/// children under their parent).
#[derive(Debug, Clone)]
pub struct DocumentSymbol {
    pub name: String,
    /// "fn" / "struct" / "class" / "method" / "h1" / etc.
    pub kind: &'static str,
    pub line: u32,
    pub character: u32,
    pub depth: u32,
}

/// A single entry in a `workspace/symbol` reply — like [`DocumentSymbol`] but
/// project-wide (and so includes the file path). `container` is the owning
/// scope (`"impl Foo"`, `"mod inner"`, …) when the server supplies one — used
/// as a dim detail in the picker.
#[derive(Debug, Clone)]
pub struct WorkspaceSymbol {
    pub name: String,
    pub kind: &'static str,
    pub path: PathBuf,
    pub line: u32,
    pub character: u32,
    pub container: Option<String>,
}

/// Flattened `WorkspaceEdit` — `(path, [(range, new_text), …])` per affected
/// file. Same shape `textDocument/rename` produces.
pub type WorkspaceEdit = Vec<(PathBuf, Vec<(Range, String)>)>;

/// One offered code action. The server may give us a fully-resolved action
/// (with `edit` and/or `command` populated) or — for some servers / capabilities
/// — a stub that needs a follow-up `codeAction/resolve`. We don't advertise
/// resolveSupport in `initialize`, so in practice we get the eager shape.
#[derive(Debug, Clone)]
pub struct CodeAction {
    pub title: String,
    /// LSP `CodeActionKind` (`"quickfix"`, `"refactor.extract"`, …) when given.
    pub kind: Option<String>,
    /// Flattened `WorkspaceEdit` — `Some` ⇒ applying the action means applying
    /// these edits.
    pub edit: Option<WorkspaceEdit>,
    /// LSP `Command` — `Some` ⇒ also (or instead) send `workspace/executeCommand`
    /// when the action is accepted.
    pub command: Option<CodeCommand>,
}

/// LSP `Command` — `workspace/executeCommand` payload.
#[derive(Debug, Clone)]
pub struct CodeCommand {
    pub command: String,
    pub arguments: Vec<serde_json::Value>,
}

/// One configured language server.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// Display name (the `[lsp.<name>]` key).
    pub name: String,
    /// Executable (looked up on PATH).
    pub cmd: String,
    pub args: Vec<String>,
    /// File extensions this server handles (without the dot).
    pub extensions: Vec<String>,
    /// Files whose presence marks a project root (walk up from the file).
    pub root_markers: Vec<String>,
    /// The LSP `languageId` to tag documents with (e.g. `"rust"`, `"typescript"`).
    pub language_id: String,
}

/// Built-in defaults (used unless `[lsp.<name>]` overrides the same name).
fn builtin_servers() -> Vec<ServerConfig> {
    let s = |name: &str, cmd: &str, args: &[&str], exts: &[&str], roots: &[&str], lang: &str| {
        ServerConfig {
            name: name.to_string(),
            cmd: cmd.to_string(),
            args: args.iter().map(|a| a.to_string()).collect(),
            extensions: exts.iter().map(|e| e.to_string()).collect(),
            root_markers: roots.iter().map(|r| r.to_string()).collect(),
            language_id: lang.to_string(),
        }
    };
    vec![
        s(
            "rust",
            "rust-analyzer",
            &[],
            &["rs"],
            &["Cargo.toml"],
            "rust",
        ),
        s(
            "python",
            "pyright-langserver",
            &["--stdio"],
            &["py"],
            &["pyproject.toml", "setup.py", "requirements.txt"],
            "python",
        ),
        s(
            "typescript",
            "typescript-language-server",
            &["--stdio"],
            &["ts", "tsx", "js", "jsx"],
            &["tsconfig.json", "jsconfig.json", "package.json"],
            "typescript",
        ),
        s("go", "gopls", &[], &["go"], &["go.mod"], "go"),
        s(
            "c",
            "clangd",
            &[],
            &["c", "h", "cpp", "hpp", "cc"],
            &["compile_commands.json", ".clangd"],
            "cpp",
        ),
    ]
}

/// Parse `[lsp.<name>]` tables, layered over the built-in defaults (a config
/// table replaces the built-in of the same name; partial tables fall back
/// field-by-field).
fn server_configs(cfg: &Config) -> Vec<ServerConfig> {
    let mut by_name: HashMap<String, ServerConfig> = builtin_servers()
        .into_iter()
        .map(|s| (s.name.clone(), s))
        .collect();
    for (name, val) in &cfg.lsp {
        let t = match val.as_table() {
            Some(t) => t,
            None => continue,
        };
        let str_of = |k: &str| t.get(k).and_then(|v| v.as_str()).map(str::to_string);
        let strs_of = |k: &str| {
            t.get(k).and_then(|v| v.as_array()).map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect::<Vec<_>>()
            })
        };
        let base = by_name.get(name).cloned();
        let merged = ServerConfig {
            name: name.clone(),
            cmd: str_of("cmd")
                .or_else(|| base.as_ref().map(|b| b.cmd.clone()))
                .unwrap_or_else(|| name.clone()),
            args: strs_of("args")
                .or_else(|| base.as_ref().map(|b| b.args.clone()))
                .unwrap_or_default(),
            extensions: strs_of("extensions")
                .or_else(|| base.as_ref().map(|b| b.extensions.clone()))
                .unwrap_or_default(),
            root_markers: strs_of("root_markers")
                .or_else(|| base.as_ref().map(|b| b.root_markers.clone()))
                .unwrap_or_default(),
            language_id: str_of("language_id")
                .or_else(|| base.as_ref().map(|b| b.language_id.clone()))
                .unwrap_or_else(|| name.clone()),
        };
        by_name.insert(name.clone(), merged);
    }
    by_name.into_values().collect()
}

/// Walk up from `file`'s directory looking for any of `markers`; fall back to
/// the file's directory (or `fallback`) if none found.
fn find_root(file: &Path, markers: &[String], fallback: &Path) -> PathBuf {
    let start = file.parent().unwrap_or(fallback);
    let mut cur = Some(start);
    while let Some(dir) = cur {
        if markers.iter().any(|m| dir.join(m).exists()) {
            return dir.to_path_buf();
        }
        cur = dir.parent();
    }
    start.to_path_buf()
}

pub struct LspManager {
    workspace: PathBuf,
    servers: Vec<ServerConfig>,
    /// Keyed `(root, server-name)`.
    clients: HashMap<(PathBuf, String), client::LspClient>,
    /// Server names we've already tried + failed to spawn (don't retry / re-toast).
    dead: std::collections::HashSet<String>,
    tx: mpsc::Sender<LspEvent>,
    rx: mpsc::Receiver<LspEvent>,
}

impl LspManager {
    pub fn new(workspace: &Path, cfg: &Config) -> LspManager {
        let (tx, rx) = mpsc::channel();
        LspManager {
            workspace: workspace.to_path_buf(),
            servers: server_configs(cfg),
            clients: HashMap::new(),
            dead: std::collections::HashSet::new(),
            tx,
            rx,
        }
    }

    /// True when no language server is currently running. Used as a guard
    /// before workspace-wide requests (`workspace/symbol`).
    pub fn is_empty(&self) -> bool {
        self.clients.is_empty()
    }

    fn server_for_ext(&self, ext: &str) -> Option<ServerConfig> {
        self.servers
            .iter()
            .find(|s| s.extensions.iter().any(|e| e == ext))
            .cloned()
    }

    /// Ensure a client exists for `path`'s language; returns the `(root, name)`
    /// key + the language id, or `None` if there's no server for this extension /
    /// it couldn't be started.
    fn ensure_client(&mut self, path: &Path) -> Option<((PathBuf, String), String)> {
        let ext = path.extension()?.to_str()?.to_string();
        let sc = self.server_for_ext(&ext)?;
        if self.dead.contains(&sc.name) {
            return None;
        }
        let root = find_root(path, &sc.root_markers, &self.workspace);
        let key = (root.clone(), sc.name.clone());
        if !self.clients.contains_key(&key) {
            match client::LspClient::spawn(&sc, &root, self.tx.clone()) {
                Ok(c) => {
                    self.clients.insert(key.clone(), c);
                }
                Err(e) => {
                    self.dead.insert(sc.name.clone());
                    let _ = self.tx.send(LspEvent::Message(format!(
                        "LSP: {} unavailable ({e}) — skipping",
                        sc.cmd
                    )));
                    return None;
                }
            }
        }
        Some((key, sc.language_id))
    }

    pub fn did_open(&mut self, path: &Path, text: &str) {
        if let Some((key, lang)) = self.ensure_client(path)
            && let Some(c) = self.clients.get_mut(&key)
        {
            c.did_open(path, &lang, text);
        }
    }
    pub fn did_change(&mut self, path: &Path, text: &str) {
        for c in self.clients.values_mut() {
            c.did_change(path, text);
        }
    }
    pub fn did_save(&mut self, path: &Path, text: &str) {
        for c in self.clients.values_mut() {
            c.did_save(path, text);
        }
    }
    pub fn did_close(&mut self, path: &Path) {
        for c in self.clients.values_mut() {
            c.did_close(path);
        }
    }
    /// Send a `textDocument/definition` request for the cursor position.
    pub fn goto_definition(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/definition", path, line, character)
    }
    /// Send a `textDocument/hover` request for the cursor position.
    pub fn hover(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/hover", path, line, character)
    }
    /// Send a `textDocument/references` request for the cursor position.
    pub fn references(&mut self, path: &Path, line: u32, character: u32) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.references(path, line, character);
                sent = true;
            }
        }
        sent
    }
    /// Send a `textDocument/rename` request — the reply arrives as [`LspEvent::Rename`].
    pub fn rename(&mut self, path: &Path, line: u32, character: u32, new_name: &str) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.rename(path, line, character, new_name);
                sent = true;
            }
        }
        sent
    }
    /// Send a `textDocument/completion` request — the reply arrives as [`LspEvent::Completion`].
    pub fn completion(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/completion", path, line, character)
    }
    /// Send a `textDocument/formatting` request — the reply arrives as [`LspEvent::Formatting`].
    pub fn formatting(&mut self, path: &Path, tab_size: u32, insert_spaces: bool) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.formatting(path, tab_size, insert_spaces);
                sent = true;
            }
        }
        sent
    }
    /// Send a `textDocument/documentSymbol` request — reply arrives as
    /// [`LspEvent::DocumentSymbols`].
    pub fn document_symbol(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.document_symbol(path);
                sent = true;
            }
        }
        sent
    }
    /// Send `workspace/symbol` to **every** running server (each may host its
    /// own project; merging on the app side). Reply arrives per server as
    /// [`LspEvent::WorkspaceSymbols`].
    pub fn workspace_symbol(&mut self, query: &str) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            c.workspace_symbol(query);
            sent = true;
        }
        sent
    }
    /// Send a `textDocument/codeAction` request — the reply arrives as
    /// [`LspEvent::CodeAction`]. `diagnostics` are the ones overlapping the
    /// requested range (the server uses them to decide which quickfixes apply).
    pub fn code_action(&mut self, path: &Path, range: Range, diagnostics: &[Diagnostic]) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.code_action(path, range, diagnostics);
                sent = true;
            }
        }
        sent
    }
    /// Send a `workspace/executeCommand` request (no reply handling — fire and
    /// forget; the server's effects come back as `applyEdit` / diagnostics).
    pub fn execute_command(&mut self, path: &Path, cmd: &CodeCommand) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.execute_command(cmd);
                sent = true;
            }
        }
        sent
    }
    fn request_at(&mut self, method: &str, path: &Path, line: u32, character: u32) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.request_text_position(method, path, line, character);
                sent = true;
            }
        }
        sent
    }

    /// Drain everything the reader threads have produced since last call.
    pub fn poll(&mut self) -> Vec<LspEvent> {
        self.rx.try_iter().collect()
    }
}

// ── shared JSON helpers used by client.rs ──────────────────────────

/// `file:///abs/path` for `path` (already absolute). Minimal percent-encoding.
pub(crate) fn path_to_uri(path: &Path) -> String {
    let s = path.to_string_lossy();
    let mut out = String::from("file://");
    for b in s.bytes() {
        match b {
            b'/' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Inverse of [`path_to_uri`] (best-effort): `file:///x` → `/x`, percent-decoded.
pub(crate) fn uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    let mut bytes = Vec::with_capacity(rest.len());
    let mut it = rest.bytes();
    while let Some(b) = it.next() {
        if b == b'%' {
            let h = it.next()?;
            let l = it.next()?;
            let hv = (h as char).to_digit(16)?;
            let lv = (l as char).to_digit(16)?;
            bytes.push((hv * 16 + lv) as u8);
        } else {
            bytes.push(b);
        }
    }
    Some(PathBuf::from(String::from_utf8_lossy(&bytes).into_owned()))
}

/// Parse a diagnostic JSON object into our [`Diagnostic`].
pub(crate) fn parse_diagnostic(v: &serde_json::Value) -> Option<Diagnostic> {
    let r = v.get("range")?;
    let pos = |k: &str| -> Option<Pos> {
        let p = r.get(k)?;
        Some(Pos {
            line: p.get("line")?.as_u64()? as u32,
            character: p.get("character")?.as_u64()? as u32,
        })
    };
    Some(Diagnostic {
        range: Range {
            start: pos("start")?,
            end: pos("end")?,
        },
        severity: v
            .get("severity")
            .and_then(|s| s.as_u64())
            .map(Severity::from_lsp)
            .unwrap_or(Severity::Error),
        message: v
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("")
            .to_string(),
        source: v.get("source").and_then(|s| s.as_str()).map(str::to_string),
    })
}

/// Byte offset in `text` of the `character`-th char on the 0-based `line`
/// (LSP positions are line + UTF-16 units; we treat `character` as a *char*
/// index — fine for ASCII / BMP). `character` past the end of the line maps to
/// the line's end (before the `\n`). `None` if `line` is out of range.
pub(crate) fn byte_at(text: &str, line: u32, character: u32) -> Option<usize> {
    let mut start = 0usize;
    for _ in 0..line {
        let nl = text[start..].find('\n')?;
        start += nl + 1;
    }
    let line_text = match text[start..].find('\n') {
        Some(nl) => &text[start..start + nl],
        None => &text[start..],
    };
    match line_text.char_indices().nth(character as usize) {
        Some((off, _)) => Some(start + off),
        None => Some(start + line_text.len()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_at_resolves_positions() {
        let t = "ab\ncde\nf";
        assert_eq!(byte_at(t, 0, 0), Some(0));
        assert_eq!(byte_at(t, 0, 2), Some(2)); // end of line 0 (the '\n')
        assert_eq!(byte_at(t, 1, 0), Some(3));
        assert_eq!(byte_at(t, 1, 1), Some(4));
        assert_eq!(byte_at(t, 1, 9), Some(6)); // past end → line end
        assert_eq!(byte_at(t, 2, 0), Some(7));
        assert_eq!(byte_at(t, 3, 0), None); // out of range
    }

    #[test]
    fn uri_round_trips() {
        let p = Path::new("/tmp/a b/x.rs");
        let u = path_to_uri(p);
        assert!(u.starts_with("file:///tmp/a%20b/x.rs"));
        assert_eq!(uri_to_path(&u).unwrap(), p);
    }

    #[test]
    fn ext_lookup_hits_builtins() {
        let cfg = Config::default();
        let m = LspManager::new(Path::new("/tmp"), &cfg);
        assert!(m.server_for_ext("rs").is_some());
        assert_eq!(m.server_for_ext("rs").unwrap().cmd, "rust-analyzer");
        assert!(m.server_for_ext("zzz").is_none());
    }

    #[test]
    fn config_overrides_builtin() {
        let mut cfg = Config::default();
        let mut t = toml::value::Table::new();
        t.insert("cmd".into(), toml::Value::String("my-ra".into()));
        cfg.lsp.insert("rust".into(), toml::Value::Table(t));
        let m = LspManager::new(Path::new("/tmp"), &cfg);
        assert_eq!(m.server_for_ext("rs").unwrap().cmd, "my-ra");
        // unspecified fields keep the builtin
        assert_eq!(m.server_for_ext("rs").unwrap().language_id, "rust");
    }

    #[test]
    fn parse_diagnostic_basic() {
        let v = serde_json::json!({
            "range": {"start": {"line": 3, "character": 1}, "end": {"line": 3, "character": 5}},
            "severity": 2, "message": "unused", "source": "rustc"
        });
        let d = parse_diagnostic(&v).unwrap();
        assert_eq!(d.severity, Severity::Warning);
        assert_eq!(d.range.start.line, 3);
        assert_eq!(d.source.as_deref(), Some("rustc"));
    }
}
