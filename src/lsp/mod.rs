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

/// One candidate as parsed from a `textDocument/completion` reply:
/// `(label, insert_text, detail, documentation, raw_json, is_snippet)`.
/// `raw_json` is the original server item — kept so the App can round-trip
/// it on a `completionItem/resolve` request. `is_snippet` is `true` when
/// the server marked the item with `insertTextFormat == 2` (the `insert`
/// then holds LSP snippet syntax — `$1` / `${1:default}` / `$0`).
pub type CompletionItemTuple = (
    String,
    String,
    Option<String>,
    Option<String>,
    serde_json::Value,
    bool,
);

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
    /// Server-initiated `workspace/applyEdit` — same shape as `Rename`, with
    /// an optional label the server provides for the user-facing toast.
    ApplyEdit {
        label: Option<String>,
        edits: Vec<(PathBuf, Vec<(Range, String)>)>,
    },
    /// Result of a `textDocument/completion` request — see
    /// [`CompletionItemTuple`] for the field layout.
    Completion(Vec<CompletionItemTuple>),
    /// Result of a `completionItem/resolve` request — the resolved item's
    /// `(label, documentation, detail)`. `label` is the lookup key on the
    /// popup side; documentation may still be empty if the server didn't
    /// have anything to add.
    CompletionResolve {
        label: String,
        detail: Option<String>,
        documentation: Option<String>,
    },
    /// Result of a `textDocument/formatting` request — the `TextEdit[]` for `path`.
    Formatting {
        path: PathBuf,
        edits: Vec<(Range, String)>,
    },
    /// Result of a `textDocument/willSaveWaitUntil` request — the
    /// `TextEdit[]` the server wants applied *before* the file hits disk.
    /// Same shape as `Formatting` but a separate variant so the save
    /// state machine knows to chain into format-on-save (if enabled)
    /// after applying these edits.
    WillSaveWaitUntil {
        path: PathBuf,
        edits: Vec<(Range, String)>,
    },
    /// Result of a `textDocument/codeAction` request — the available actions at
    /// the requested range, in server order.
    CodeAction(Vec<CodeAction>),
    /// Result of a `codeAction/resolve` request — the resolved (edit, command)
    /// pair. The App matches it back to a pending action via the
    /// `pending_code_action_resolve` slot it set when firing the request.
    CodeActionResolve {
        edit: Option<WorkspaceEdit>,
        command: Option<CodeCommand>,
    },
    /// Result of a `textDocument/documentSymbol` request — `(name, kind,
    /// line, character, depth)` per symbol, depth-first (parents before
    /// children; depth = nesting level). Both the hierarchical `DocumentSymbol[]`
    /// reply shape and the legacy flat `SymbolInformation[]` shape feed in here.
    DocumentSymbols(Vec<DocumentSymbol>),
    /// Result of a `workspace/symbol` request — `(name, kind, path, line,
    /// character)` per hit across the whole project. Multiple servers may
    /// each contribute; events are emitted per server reply (the app merges).
    WorkspaceSymbols(Vec<WorkspaceSymbol>),
    /// Result of a `textDocument/signatureHelp` request — parameter info for
    /// the function call the cursor sits inside. `None` reply ⇒ no event
    /// emitted (so the open popup stays put).
    SignatureHelp(SignatureHelp),
    /// Result of a `textDocument/inlayHint` request — virtual text the
    /// server suggests inserting at specific positions. Rendered as dim
    /// chips by the editor view.
    InlayHints {
        path: PathBuf,
        hints: Vec<InlayHint>,
    },
    /// Result of a `textDocument/semanticTokens/full` request — server-aware
    /// syntax highlight spans, decoded from the protocol's flat delta-
    /// encoded `data[]` array. Layered on top of tree-sitter highlights by
    /// the editor renderer.
    SemanticTokens {
        path: PathBuf,
        tokens: Vec<SemanticToken>,
    },
    /// Result of a `textDocument/codeLens` request — actionable annotations
    /// (like "5 references" or "Run | Debug") attached to specific lines.
    /// Rendered as dim chips at end-of-line by the editor view.
    CodeLens {
        path: PathBuf,
        lenses: Vec<CodeLens>,
    },
    /// Result of a `textDocument/documentLink` request — clickable links
    /// (URLs / file paths) the server identified in the buffer.
    DocumentLinks {
        path: PathBuf,
        links: Vec<DocumentLink>,
    },
    /// Result of a `textDocument/foldingRange` request — line-based fold
    /// ranges the server suggests (`(start_line, end_line)`, inclusive,
    /// 0-based file lines).
    FoldingRanges {
        path: PathBuf,
        ranges: Vec<(u32, u32)>,
    },
    /// Result of a `textDocument/selectionRange` request — semantic
    /// ranges around the cursor, ordered smallest → largest. Each entry
    /// is `(start_line, start_char, end_line, end_char)`.
    SelectionRanges {
        path: PathBuf,
        ranges: Vec<(u32, u32, u32, u32)>,
    },
    /// Result of a `textDocument/documentColor` request — color literals
    /// the server recognized in the buffer.
    DocumentColor {
        path: PathBuf,
        colors: Vec<ColorDecoration>,
    },
    /// Result of a `textDocument/documentHighlight` request — usages of
    /// the symbol at the requested position, scope-aware. Each entry is
    /// `(start_line, start_char, end_line, end_char)`.
    DocumentHighlights {
        path: PathBuf,
        ranges: Vec<(u32, u32, u32, u32)>,
    },
    /// Result of a `textDocument/prepareCallHierarchy` request — items
    /// the server thinks the cursor is on (typically one). The App
    /// re-fires `callHierarchy/incomingCalls` or `outgoingCalls` using
    /// the first item; multi-item disambiguation is a follow-up.
    CallHierarchyPrepared {
        direction: CallHierarchyDirection,
        items: Vec<CallHierarchyItem>,
    },
    /// Result of `callHierarchy/{incoming,outgoing}Calls` — each entry is
    /// a `(name, path, line, character)` for the call site (incoming) or
    /// the callee (outgoing).
    CallHierarchyCalls {
        direction: CallHierarchyDirection,
        origin_name: String,
        hits: Vec<CallHit>,
    },
    /// Result of a `textDocument/prepareTypeHierarchy` request — same
    /// shape as call hierarchy's prepare. Direction tells the App which
    /// follow-up to fire (`supertypes` vs `subtypes`).
    TypeHierarchyPrepared {
        direction: TypeHierarchyDirection,
        items: Vec<CallHierarchyItem>,
    },
    /// Result of `typeHierarchy/{super,sub}types` — same `(name, path,
    /// line, character)` shape as call hits, reusing [`CallHit`].
    TypeHierarchyTypes {
        direction: TypeHierarchyDirection,
        origin_name: String,
        hits: Vec<CallHit>,
    },
    /// `$/progress` with `kind: begin` — a long-running server task started.
    /// `token` is the server-assigned id; `title` is the user-facing label.
    /// Used by the statusline busy chip.
    ProgressBegin { token: String, title: String },
    /// `$/progress` with `kind: report` — same task, possibly updated
    /// label / percentage. `title` is the latest message.
    ProgressReport { token: String, title: String },
    /// `$/progress` with `kind: end` — task done. Drop the token.
    ProgressEnd { token: String },
    /// A server-side message worth surfacing as a toast.
    Message(String),
}

/// Direction of a call-hierarchy walk. Incoming = "callers of this fn";
/// outgoing = "callees from this fn".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallHierarchyDirection {
    Incoming,
    Outgoing,
}

/// Direction of a type-hierarchy walk. Super = "parent classes / traits";
/// sub = "subclasses / impls".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeHierarchyDirection {
    Supertypes,
    Subtypes,
}

/// A `CallHierarchyItem` from `textDocument/prepareCallHierarchy`. We
/// keep the original JSON in `raw` so the follow-up
/// `callHierarchy/{incoming,outgoing}Calls` request can hand it back to
/// the server without re-parsing.
#[derive(Debug, Clone)]
pub struct CallHierarchyItem {
    pub name: String,
    pub kind: u32,
    pub path: PathBuf,
    pub line: u32,
    pub character: u32,
    pub raw: serde_json::Value,
}

/// One call site / callee returned by `callHierarchy/{incoming,outgoing}Calls`.
/// For incoming: `name` is the caller, `path/line/character` is the call's
/// source position in the caller. For outgoing: `name` is the callee.
#[derive(Debug, Clone)]
pub struct CallHit {
    pub name: String,
    pub path: PathBuf,
    pub line: u32,
    pub character: u32,
}

/// One semantic-token span returned by `textDocument/semanticTokens/full`.
/// The LSP wire form is a flat `data: number[]` with delta encoding (every
/// 5 numbers = deltaLine, deltaStart, length, tokenTypeIdx, modifiers); the
/// reader decodes that into absolute positions + resolves the token type
/// index to a name via the per-server legend before sending up.
///
/// `type_name` is the legend string (`"function"` / `"variable"` /
/// `"string"` / …) which the editor renderer maps to a theme color.
/// `modifiers` is the resolved set of modifier names (`"deprecated"` /
/// `"defaultLibrary"` / `"readonly"` / `"static"` / etc.) the renderer
/// maps to a `ratatui::style::Modifier` (CROSSED_OUT / DIM / ITALIC /
/// BOLD). Modifiers with no visual mapping are kept on the token but
/// have no rendering effect.
#[derive(Debug, Clone)]
pub struct SemanticToken {
    pub line: u32,
    pub start_char: u32,
    pub length: u32,
    pub type_name: String,
    pub modifiers: Vec<String>,
}

/// One color literal the server recognized. We keep just enough to paint
/// a swatch glyph at the literal's position. RGB is `0xRRGGBB` packed
/// (alpha dropped — the renderer uses a fixed-glyph chip).
#[derive(Debug, Clone)]
pub struct ColorDecoration {
    pub line: u32,
    pub start_char: u32,
    pub end_char: u32,
    /// Packed 0xRRGGBB.
    pub rgb: u32,
}

/// One link the server says is clickable — `range` is where it sits in the
/// source, `target` is the URL / path to open.
#[derive(Debug, Clone)]
pub struct DocumentLink {
    pub line: u32,
    pub start_char: u32,
    pub end_char: u32,
    pub target: String,
}

/// A single inlay hint — virtual text the server wants displayed at a
/// specific position. We keep just `(line, character, label)` since the
/// MVP renderer paints them as dim end-of-line chips.
#[derive(Debug, Clone)]
pub struct InlayHint {
    pub line: u32,
    pub character: u32,
    pub label: String,
}

/// A single code lens — an actionable annotation on a line. We keep the
/// line + the title (the human-readable text shown to the user). The
/// command to invoke isn't surfaced in the MVP renderer (clicks would
/// need rect tracking + a click-handler + workspace/executeCommand wiring).
#[derive(Debug, Clone)]
pub struct CodeLens {
    pub line: u32,
    pub title: String,
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

/// Parsed `textDocument/signatureHelp` reply — what to render in the popup.
#[derive(Debug, Clone)]
pub struct SignatureHelp {
    pub signatures: Vec<SignatureInfo>,
    /// Which signature in `signatures` is "active" (the one to show first).
    pub active_signature: usize,
}

/// One signature in a [`SignatureHelp`] reply — its label (full prototype
/// text the server returns), the parameter ranges within that label, and
/// which parameter is currently active.
#[derive(Debug, Clone)]
pub struct SignatureInfo {
    pub label: String,
    /// `(start_char, end_char)` ranges into `label`, one per parameter.
    /// May be empty if the server didn't expose them (we fall back to just
    /// showing the label without a highlight).
    pub parameters: Vec<(usize, usize)>,
    /// Index into `parameters` for the active param — `None` when unknown
    /// or out of range.
    pub active_parameter: Option<usize>,
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
    /// Original server JSON. Kept so we can round-trip the item back to the
    /// server on `codeAction/resolve` when `edit` is empty. `None` for
    /// internally-synthesized actions.
    pub raw: Option<serde_json::Value>,
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

    /// Count of running servers (each `(root, server-name)` pair counts once).
    pub fn server_count(&self) -> usize {
        self.clients.len()
    }

    /// Drop every running server (each `LspClient` kills its child on Drop).
    /// `dead` is cleared too so a new `did_open` can respawn them. Used by
    /// `:LspRestart` — a "the LSP got stuck" recovery gesture.
    pub fn restart_all(&mut self) {
        self.clients.clear();
        self.dead.clear();
    }

    /// `(server-name, root)` for each running server. Used by the statusline
    /// chip + `:LspStatus` ex command.
    pub fn servers_running(&self) -> Vec<(String, PathBuf)> {
        let mut v: Vec<_> = self
            .clients
            .keys()
            .map(|(root, name)| (name.clone(), root.clone()))
            .collect();
        v.sort();
        v
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
    /// Send a `textDocument/declaration` request — reply routes through
    /// [`LspEvent::GotoDefinition`] (same shape).
    pub fn goto_declaration(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/declaration", path, line, character)
    }
    /// Send a `textDocument/typeDefinition` request — reply routes through
    /// [`LspEvent::GotoDefinition`] (same shape).
    pub fn goto_type_definition(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/typeDefinition", path, line, character)
    }
    /// Send a `textDocument/implementation` request — reply routes through
    /// [`LspEvent::GotoDefinition`] (same shape).
    pub fn goto_implementation(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/implementation", path, line, character)
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
    /// Send a `completionItem/resolve` for `item` against whichever server
    /// has `path` open. Reply arrives as [`LspEvent::CompletionResolve`] tagged
    /// with `label` so the popup can find the row.
    pub fn completion_resolve(
        &mut self,
        path: &Path,
        label: &str,
        item: serde_json::Value,
    ) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.completion_resolve(item.clone(), label);
                sent = true;
            }
        }
        sent
    }
    /// Send a `codeAction/resolve` for `action` against whichever server has
    /// `path` open. Reply arrives as [`LspEvent::CodeActionResolve`].
    pub fn code_action_resolve(&mut self, path: &Path, action: serde_json::Value) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.code_action_resolve(action.clone());
                sent = true;
            }
        }
        sent
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
    /// Send a `textDocument/willSaveWaitUntil` request — fired before
    /// save, reply arrives as [`LspEvent::WillSaveWaitUntil`] and the
    /// edits are spliced into the buffer *before* the disk write.
    pub fn will_save_wait_until(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.will_save_wait_until(path);
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
    /// Send `textDocument/signatureHelp` at `(line, character)` — reply
    /// arrives as [`LspEvent::SignatureHelp`].
    pub fn signature_help(&mut self, path: &Path, line: u32, character: u32) -> bool {
        self.request_at("textDocument/signatureHelp", path, line, character)
    }
    /// Send `textDocument/inlayHint` for the whole file — reply arrives as
    /// [`LspEvent::InlayHints`]. Caller passes `line_count` so the request
    /// range covers the whole buffer.
    pub fn inlay_hint(&mut self, path: &Path, line_count: u32) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.inlay_hint(path, line_count);
                sent = true;
            }
        }
        sent
    }
    /// Request semantic tokens — `full` on first call, `full/delta` on
    /// subsequent calls (the client picks based on its per-path
    /// `resultId` cache). Reply arrives as [`LspEvent::SemanticTokens`]
    /// either way. No-op when the server didn't advertise
    /// `semanticTokensProvider` (the request would just be ignored).
    pub fn semantic_tokens(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.semantic_tokens(path);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/documentLink` — reply arrives as
    /// [`LspEvent::DocumentLinks`].
    pub fn document_link(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.document_link(path);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/foldingRange` — reply arrives as
    /// [`LspEvent::FoldingRanges`].
    pub fn folding_range(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.folding_range(path);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/selectionRange` at `(line, character)` — reply
    /// arrives as [`LspEvent::SelectionRanges`].
    pub fn selection_range(&mut self, path: &Path, line: u32, character: u32) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.selection_range(path, line, character);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/documentColor` — reply arrives as
    /// [`LspEvent::DocumentColor`].
    pub fn document_color(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.document_color(path);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/documentHighlight` at `(line, character)` —
    /// reply arrives as [`LspEvent::DocumentHighlights`].
    pub fn document_highlight(&mut self, path: &Path, line: u32, character: u32) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.document_highlight(path, line, character);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/prepareCallHierarchy` at `(line, character)`. The
    /// `direction` is stashed so the reply (carried as
    /// [`LspEvent::CallHierarchyPrepared`]) tells the App which follow-up
    /// to fire (`incomingCalls` vs `outgoingCalls`).
    pub fn prepare_call_hierarchy(
        &mut self,
        path: &Path,
        line: u32,
        character: u32,
        direction: CallHierarchyDirection,
    ) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.prepare_call_hierarchy(path, line, character, direction);
                sent = true;
            }
        }
        sent
    }
    /// Send `textDocument/onTypeFormatting` at `(line, char)` with a
    /// trigger char. Reply is delivered as [`LspEvent::Formatting`]
    /// (shape is identical to `textDocument/formatting`).
    pub fn on_type_formatting(
        &mut self,
        path: &Path,
        line: u32,
        character: u32,
        trigger: char,
        tab_size: u32,
        insert_spaces: bool,
    ) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.on_type_formatting(path, line, character, trigger, tab_size, insert_spaces);
                sent = true;
            }
        }
        sent
    }

    /// Send `callHierarchy/incomingCalls` for a previously-prepared item.
    /// `origin_name` is the prepared item's name — round-tripped back in
    /// [`LspEvent::CallHierarchyCalls`] so the picker title reads
    /// `"Incoming calls — fn foo"` without an extra lookup.
    pub fn call_hierarchy_incoming(&mut self, item: &CallHierarchyItem) {
        for c in self.clients.values_mut() {
            if c.is_open(&item.path) {
                c.call_hierarchy_calls(item, CallHierarchyDirection::Incoming);
                return;
            }
        }
    }
    /// Send `callHierarchy/outgoingCalls` for a previously-prepared item.
    pub fn call_hierarchy_outgoing(&mut self, item: &CallHierarchyItem) {
        for c in self.clients.values_mut() {
            if c.is_open(&item.path) {
                c.call_hierarchy_calls(item, CallHierarchyDirection::Outgoing);
                return;
            }
        }
    }

    /// Send `textDocument/prepareTypeHierarchy` at `(line, character)`.
    pub fn prepare_type_hierarchy(
        &mut self,
        path: &Path,
        line: u32,
        character: u32,
        direction: TypeHierarchyDirection,
    ) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.prepare_type_hierarchy(path, line, character, direction);
                sent = true;
            }
        }
        sent
    }
    /// Send `typeHierarchy/supertypes` for a previously-prepared item.
    pub fn type_hierarchy_supertypes(&mut self, item: &CallHierarchyItem) {
        for c in self.clients.values_mut() {
            if c.is_open(&item.path) {
                c.type_hierarchy_types(item, TypeHierarchyDirection::Supertypes);
                return;
            }
        }
    }
    /// Send `typeHierarchy/subtypes` for a previously-prepared item.
    pub fn type_hierarchy_subtypes(&mut self, item: &CallHierarchyItem) {
        for c in self.clients.values_mut() {
            if c.is_open(&item.path) {
                c.type_hierarchy_types(item, TypeHierarchyDirection::Subtypes);
                return;
            }
        }
    }
    /// Send `textDocument/codeLens` — reply arrives as [`LspEvent::CodeLens`].
    pub fn code_lens(&mut self, path: &Path) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.code_lens(path);
                sent = true;
            }
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
    /// Same as [`Self::code_action`] but with a `context.only` filter so
    /// the server returns only actions of those kinds (e.g.
    /// `["source.organizeImports"]`). Reply still arrives as
    /// [`LspEvent::CodeAction`].
    pub fn code_action_with_only(
        &mut self,
        path: &Path,
        range: Range,
        diagnostics: &[Diagnostic],
        only: &[String],
    ) -> bool {
        let mut sent = false;
        for c in self.clients.values_mut() {
            if c.is_open(path) {
                c.code_action_with_only(path, range, diagnostics, only);
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
