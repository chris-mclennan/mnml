//! One language-server subprocess: JSON-RPC over stdio. A reader thread parses
//! `Content-Length`-framed messages from the server's stdout — forwarding
//! `publishDiagnostics` notifications and the responses to requests we sent
//! (`definition` / `hover` / `references` / `rename` / `completion`) over an
//! [`super::LspEvent`] channel, and replying with
//! `null` to any server→client request so strict servers don't stall. Outbound
//! messages go through a shared `Mutex<ChildStdin>` (UI thread for requests,
//! reader thread for those `null` replies).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde_json::json;

use super::{
    CodeAction, CodeCommand, Diagnostic, DocumentSymbol, LspEvent, Pos, Range, ServerConfig,
    Severity, parse_diagnostic, path_to_uri, uri_to_path,
};

/// Tracks each in-flight request: the LSP method (so the reply parser
/// knows what shape to expect), an optional path (so methods whose reply
/// doesn't include the file — like `textDocument/formatting` — can be
/// routed back to the right buffer), and an optional opaque string
/// (used by `completionItem/resolve` to remember the original label so
/// the popup can match the reply to a row).
type Pending = Arc<Mutex<HashMap<i64, (String, Option<PathBuf>, Option<String>)>>>;
type Sink = Arc<Mutex<ChildStdin>>;

/// Per-path cache for semantic-tokens delta requests. The server returns a
/// `resultId` with every reply; we cache it (plus the raw decoded `data[]`
/// array) so the next request can be `semanticTokens/full/delta` with
/// `previousResultId`. Shared between the App-thread client (which reads
/// the result_id when crafting requests) and the reader thread (which
/// updates both fields when replies land).
#[derive(Debug, Default, Clone)]
struct SemState {
    result_id: Option<String>,
    /// Last full decoded raw token data — the protocol-shape flat array
    /// of u32, 5 per token. Used to apply incoming deltas via splice.
    raw_data: Vec<u32>,
}
type SemStates = Arc<Mutex<HashMap<PathBuf, SemState>>>;

/// Per-server semantic-tokens capability flags, captured from the
/// `initialize` reply's `capabilities.semanticTokensProvider`. The
/// App-thread client reads these when choosing which request shape to
/// send (delta > full > range); the reader thread writes them once.
/// Defaults are optimistic (`supports_full = true`) so requests made
/// before the initialize reply lands still go out — most servers do
/// support full.
#[derive(Debug, Clone)]
struct SemServerCaps {
    supports_full: bool,
    supports_delta: bool,
    supports_range: bool,
}
impl Default for SemServerCaps {
    fn default() -> Self {
        Self {
            supports_full: true,
            supports_delta: false,
            supports_range: false,
        }
    }
}
type SemCaps = Arc<Mutex<SemServerCaps>>;

pub struct LspClient {
    name: String,
    child: Child,
    stdin: Sink,
    reader: Option<JoinHandle<()>>,
    next_id: i64,
    pending: Pending,
    sem_states: SemStates,
    sem_caps: SemCaps,
    /// path → document version (also: presence ⇒ the doc is open with this server).
    versions: HashMap<PathBuf, i64>,
}

impl LspClient {
    pub fn spawn(
        sc: &ServerConfig,
        root: &Path,
        tx: std::sync::mpsc::Sender<LspEvent>,
    ) -> Result<Self, String> {
        let mut child = Command::new(&sc.cmd)
            .args(&sc.args)
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("spawn {}: {e}", sc.cmd))?;

        let stdin = Arc::new(Mutex::new(child.stdin.take().ok_or("no stdin")?));
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let sem_states: SemStates = Arc::new(Mutex::new(HashMap::new()));
        let sem_caps: SemCaps = Arc::new(Mutex::new(SemServerCaps::default()));

        let r_pending = Arc::clone(&pending);
        let r_stdin = Arc::clone(&stdin);
        let r_sem_states = Arc::clone(&sem_states);
        let r_sem_caps = Arc::clone(&sem_caps);
        let reader = std::thread::Builder::new()
            .name(format!("mnml-lsp-{}", sc.name))
            .spawn(move || reader_loop(stdout, tx, r_pending, r_stdin, r_sem_states, r_sem_caps))
            .map_err(|e| format!("reader thread: {e}"))?;

        let mut c = LspClient {
            name: sc.name.clone(),
            child,
            stdin,
            reader: Some(reader),
            next_id: 1,
            pending,
            sem_states,
            sem_caps,
            versions: HashMap::new(),
        };

        // `initialize` → `initialized`. We don't wait for the response (servers in
        // practice queue the messages that follow); the reader just ignores it.
        let root_uri = path_to_uri(root);
        c.request(
            "initialize",
            json!({
                "processId": std::process::id(),
                "clientInfo": { "name": "mnml" },
                "rootUri": root_uri,
                "workspaceFolders": [ { "uri": root_uri, "name": "workspace" } ],
                "capabilities": {
                    "window": {
                        "workDoneProgress": true
                    },
                    "textDocument": {
                        "synchronization": {
                            "didSave": true,
                            "willSave": true,
                            "willSaveWaitUntil": true
                        },
                        "publishDiagnostics": {},
                        "hover": { "contentFormat": ["markdown", "plaintext"] },
                        "definition": { "linkSupport": true },
                        "declaration": { "linkSupport": true },
                        "typeDefinition": { "linkSupport": true },
                        "implementation": { "linkSupport": true },
                        "references": {},
                        "documentHighlight": {},
                        "callHierarchy": { "dynamicRegistration": false },
                        "typeHierarchy": { "dynamicRegistration": false },
                        "rename": {},
                        "completion": {
                            "completionItem": {
                                "snippetSupport": false,
                                "documentationFormat": ["markdown", "plaintext"],
                                "resolveSupport": {
                                    "properties": ["documentation", "detail"]
                                }
                            }
                        },
                        "signatureHelp": {
                            "signatureInformation": {
                                "parameterInformation": { "labelOffsetSupport": true }
                            }
                        },
                        "codeAction": {
                            "codeActionLiteralSupport": {
                                "codeActionKind": {
                                    "valueSet": [
                                        "", "quickfix", "refactor",
                                        "refactor.extract", "refactor.inline", "refactor.rewrite",
                                        "source", "source.organizeImports"
                                    ]
                                }
                            },
                            "resolveSupport": {
                                "properties": ["edit", "command"]
                            }
                        },
                        "inlayHint": {
                            "dynamicRegistration": false,
                            "resolveSupport": { "properties": ["label.tooltip", "label.location"] }
                        },
                        "semanticTokens": {
                            "dynamicRegistration": false,
                            "requests": { "full": { "delta": true }, "range": true },
                            "tokenTypes": [
                                "namespace", "type", "class", "enum", "interface",
                                "struct", "typeParameter", "parameter", "variable",
                                "property", "enumMember", "event", "function",
                                "method", "macro", "keyword", "modifier", "comment",
                                "string", "number", "regexp", "operator", "decorator"
                            ],
                            "tokenModifiers": [
                                "declaration", "definition", "readonly", "static",
                                "deprecated", "abstract", "async", "modification",
                                "documentation", "defaultLibrary"
                            ],
                            "formats": ["relative"]
                        },
                        "codeLens": {
                            "dynamicRegistration": false
                        },
                        "onTypeFormatting": { "dynamicRegistration": false },
                        "foldingRange": {
                            "dynamicRegistration": false,
                            "lineFoldingOnly": true
                        },
                        "colorProvider": {
                            "dynamicRegistration": false
                        },
                        "documentSymbol": {
                            "hierarchicalDocumentSymbolSupport": true,
                            "symbolKind": {
                                "valueSet": [
                                    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                                    11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
                                    21, 22, 23, 24, 25, 26
                                ]
                            }
                        }
                    }
                }
            }),
        );
        c.notify("initialized", json!({}));
        Ok(c)
    }

    pub fn is_open(&self, path: &Path) -> bool {
        self.versions.contains_key(path)
    }

    pub fn did_open(&mut self, path: &Path, language_id: &str, text: &str) {
        if self.versions.contains_key(path) {
            return;
        }
        self.versions.insert(path.to_path_buf(), 1);
        self.notify(
            "textDocument/didOpen",
            json!({ "textDocument": {
                "uri": path_to_uri(path), "languageId": language_id, "version": 1, "text": text
            }}),
        );
    }

    pub fn did_change(&mut self, path: &Path, text: &str) {
        let Some(v) = self.versions.get_mut(path) else {
            return;
        };
        *v += 1;
        let version = *v;
        self.notify(
            "textDocument/didChange",
            json!({
                "textDocument": { "uri": path_to_uri(path), "version": version },
                "contentChanges": [ { "text": text } ]
            }),
        );
    }

    pub fn did_save(&mut self, path: &Path, text: &str) {
        if !self.versions.contains_key(path) {
            return;
        }
        self.notify(
            "textDocument/didSave",
            json!({ "textDocument": { "uri": path_to_uri(path) }, "text": text }),
        );
    }

    pub fn did_close(&mut self, path: &Path) {
        if self.versions.remove(path).is_none() {
            return;
        }
        if let Ok(mut s) = self.sem_states.lock() {
            s.remove(path);
        }
        self.notify(
            "textDocument/didClose",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
        );
    }

    /// Send a `textDocument/<method>` request whose params are `{textDocument, position}`.
    pub fn request_text_position(&mut self, method: &str, path: &Path, line: u32, character: u32) {
        self.request(
            method,
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character }
            }),
        );
    }

    /// `completionItem/resolve` — round-trip the original item back to the
    /// server, which fills in any docs / detail it withheld from the initial
    /// `textDocument/completion` reply. The reply arrives as
    /// `LspEvent::CompletionResolve`; the `label` is stashed in the pending
    /// table so the popup can match it without grovelling through the raw
    /// item.
    pub fn completion_resolve(&mut self, item: serde_json::Value, label: &str) {
        self.request_with_context(
            "completionItem/resolve",
            item,
            None,
            Some(label.to_string()),
        );
    }
    /// `codeAction/resolve` — round-trip the original action back so the
    /// server fills in the lazy `edit` / `command`. Reply arrives as
    /// `LspEvent::CodeActionResolve`.
    pub fn code_action_resolve(&mut self, action: serde_json::Value) {
        self.request("codeAction/resolve", action);
    }

    /// `textDocument/references` (params carry the extra `context`).
    pub fn references(&mut self, path: &Path, line: u32, character: u32) {
        self.request(
            "textDocument/references",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character },
                "context": { "includeDeclaration": true }
            }),
        );
    }

    /// `textDocument/rename` — the reply is a `WorkspaceEdit`.
    pub fn rename(&mut self, path: &Path, line: u32, character: u32, new_name: &str) {
        self.request(
            "textDocument/rename",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character },
                "newName": new_name
            }),
        );
    }

    /// `textDocument/documentSymbol` — reply is either `DocumentSymbol[]`
    /// (hierarchical) or the legacy `SymbolInformation[]` (flat).
    pub fn document_symbol(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/documentSymbol",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
            Some(path),
        );
    }

    /// `workspace/symbol` — reply is `SymbolInformation[]` (or the newer
    /// `WorkspaceSymbol[]`). Empty `query` means "all symbols" — servers
    /// typically cap the result count.
    pub fn workspace_symbol(&mut self, query: &str) {
        self.request("workspace/symbol", json!({ "query": query }));
    }

    /// `textDocument/codeAction` — reply is `(Command | CodeAction)[]`.
    pub fn code_action(&mut self, path: &Path, range: Range, diagnostics: &[Diagnostic]) {
        self.code_action_inner(path, range, diagnostics, None);
    }
    /// Same as [`Self::code_action`] but with `context.only` set so the
    /// server returns only actions of those kinds. Used by
    /// `lsp.organize_imports` (`only = ["source.organizeImports"]`).
    pub fn code_action_with_only(
        &mut self,
        path: &Path,
        range: Range,
        diagnostics: &[Diagnostic],
        only: &[String],
    ) {
        self.code_action_inner(path, range, diagnostics, Some(only));
    }
    fn code_action_inner(
        &mut self,
        path: &Path,
        range: Range,
        diagnostics: &[Diagnostic],
        only: Option<&[String]>,
    ) {
        let diags_json: Vec<serde_json::Value> = diagnostics
            .iter()
            .map(|d| {
                let sev = match d.severity {
                    Severity::Error => 1,
                    Severity::Warning => 2,
                    Severity::Info => 3,
                    Severity::Hint => 4,
                };
                let mut v = json!({
                    "range": {
                        "start": { "line": d.range.start.line, "character": d.range.start.character },
                        "end": { "line": d.range.end.line, "character": d.range.end.character }
                    },
                    "severity": sev,
                    "message": d.message,
                });
                if let Some(src) = &d.source {
                    v["source"] = json!(src);
                }
                v
            })
            .collect();
        let mut context = json!({ "diagnostics": diags_json });
        if let Some(only) = only {
            context["only"] = json!(only);
        }
        self.request(
            "textDocument/codeAction",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "range": {
                    "start": { "line": range.start.line, "character": range.start.character },
                    "end": { "line": range.end.line, "character": range.end.character }
                },
                "context": context,
            }),
        );
    }

    /// `workspace/executeCommand` — fire-and-forget. The server's effects show
    /// up later as workspace edits / diagnostics through their own channels.
    pub fn execute_command(&mut self, cmd: &CodeCommand) {
        self.request(
            "workspace/executeCommand",
            json!({
                "command": cmd.command,
                "arguments": cmd.arguments,
            }),
        );
    }

    /// `textDocument/codeLens` — reply is `CodeLens[]`. Each lens has a
    /// `range` and an optional `command`; we keep just `(line, title)` for
    /// the end-of-line chip. The `resolve` step (`codeLens/resolve`) is
    /// skipped — servers that need it would return lenses without
    /// `command`, which we silently filter out.
    pub fn code_lens(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/codeLens",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
            Some(path),
        );
    }

    /// `textDocument/inlayHint` — reply is `InlayHint[]` (or null). Range
    /// covers the whole file (servers are typically scope-aware enough to
    /// only return relevant hints — and we MVP-render just end-of-line
    /// chips so total volume isn't a concern).
    pub fn inlay_hint(&mut self, path: &Path, line_count: u32) {
        self.request_with_path(
            "textDocument/inlayHint",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "range": {
                    "start": { "line": 0, "character": 0 },
                    "end": { "line": line_count.saturating_sub(1), "character": 0 }
                }
            }),
            Some(path),
        );
    }

    /// Request semantic tokens for `path`. Picks the best request shape
    /// for what the server advertises:
    ///
    /// 1. `full/delta` when the server advertises delta AND we have a
    ///    cached `resultId` — the cheapest update, sparse edits we
    ///    splice into the cached raw data.
    /// 2. `full` when the server advertises full (the typical path).
    /// 3. `range` (line 0 → `line_count`) when the server only
    ///    advertises range — uncommon, but the rare path where neither
    ///    full nor delta is available.
    /// 4. No-op when the server advertises none of the three.
    ///
    /// `line_count` is needed only for the range fallback — pass the
    /// active buffer's line count so the request covers the whole file.
    /// Reply arrives as [`super::LspEvent::SemanticTokens`] in every case.
    pub fn semantic_tokens(&mut self, path: &Path, line_count: u32) {
        let caps = self.sem_caps.lock().map(|c| c.clone()).unwrap_or_default();
        let prev_id = self
            .sem_states
            .lock()
            .ok()
            .and_then(|s| s.get(path).and_then(|st| st.result_id.clone()));
        if caps.supports_delta
            && let Some(id) = prev_id
        {
            self.semantic_tokens_delta(path, &id);
        } else if caps.supports_full {
            self.semantic_tokens_full(path);
        } else if caps.supports_range {
            self.semantic_tokens_range(path, 0, line_count);
        }
        // else: server advertised no semantic-tokens capability at all
        // (or hasn't replied to initialize yet, in which case the
        // optimistic `supports_full = true` default kicked in above).
    }

    /// `textDocument/semanticTokens/full` — reply is `SemanticTokens { data:
    /// number[] }` in protocol's flat delta-encoded form. The reader thread
    /// decodes against the per-server legend (stashed when the `initialize`
    /// reply arrived) and forwards as [`super::LspEvent::SemanticTokens`].
    pub fn semantic_tokens_full(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/semanticTokens/full",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
            Some(path),
        );
    }

    /// `textDocument/semanticTokens/full/delta` — reply is either a full
    /// `SemanticTokens { resultId?, data }` (when the server gives up on
    /// computing a delta) or a `SemanticTokensDelta { resultId?, edits }`
    /// whose `edits` are sparse splices into our previously-cached raw
    /// data. The reader merges and re-decodes either way.
    pub fn semantic_tokens_delta(&mut self, path: &Path, previous_result_id: &str) {
        self.request_with_path(
            "textDocument/semanticTokens/full/delta",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "previousResultId": previous_result_id,
            }),
            Some(path),
        );
    }

    /// `textDocument/semanticTokens/range` — reply is `SemanticTokens {
    /// data }` for tokens within `[start_line, end_line)`. Used as a
    /// fallback when the server doesn't advertise `full` (rare). Tokens
    /// replace any prior cached set on receipt — coverage is just for
    /// the requested range, not cumulative across requests.
    pub fn semantic_tokens_range(&mut self, path: &Path, start_line: u32, end_line: u32) {
        self.request_with_path(
            "textDocument/semanticTokens/range",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "range": {
                    "start": { "line": start_line, "character": 0 },
                    "end": { "line": end_line, "character": 0 }
                }
            }),
            Some(path),
        );
    }

    /// `textDocument/documentLink` — reply is `DocumentLink[]`. Path is
    /// stashed so we can route the reply to the right buffer.
    pub fn document_link(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/documentLink",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
            Some(path),
        );
    }

    /// `textDocument/foldingRange` — reply is `FoldingRange[]`. Path is
    /// stashed so the reply routes back to the right buffer.
    pub fn folding_range(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/foldingRange",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
            Some(path),
        );
    }

    /// `textDocument/selectionRange` — reply is `SelectionRange[]`. We pass
    /// a single position (the cursor) and read the linked-list of parents
    /// from the reply's first entry. Path is stashed so the reply routes
    /// back to the right buffer.
    pub fn selection_range(&mut self, path: &Path, line: u32, character: u32) {
        self.request_with_path(
            "textDocument/selectionRange",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "positions": [{ "line": line, "character": character }]
            }),
            Some(path),
        );
    }

    /// `textDocument/documentColor` — reply is `ColorInformation[]`. Path
    /// is stashed so the reply routes back to the right buffer.
    pub fn document_color(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/documentColor",
            json!({ "textDocument": { "uri": path_to_uri(path) } }),
            Some(path),
        );
    }

    /// `textDocument/documentHighlight` — reply is `DocumentHighlight[]`.
    /// Path is stashed so the reply routes back to the right buffer.
    pub fn document_highlight(&mut self, path: &Path, line: u32, character: u32) {
        self.request_with_path(
            "textDocument/documentHighlight",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character }
            }),
            Some(path),
        );
    }

    /// `textDocument/prepareCallHierarchy` — reply is
    /// `CallHierarchyItem[]`. The opaque slot encodes which direction
    /// (`"i"`/`"o"`) the App wants for the follow-up `incomingCalls` /
    /// `outgoingCalls` request.
    pub fn prepare_call_hierarchy(
        &mut self,
        path: &Path,
        line: u32,
        character: u32,
        direction: super::CallHierarchyDirection,
    ) {
        let dir = match direction {
            super::CallHierarchyDirection::Incoming => "i",
            super::CallHierarchyDirection::Outgoing => "o",
        };
        self.request_with_context(
            "textDocument/prepareCallHierarchy",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character }
            }),
            Some(path),
            Some(dir.to_string()),
        );
    }

    /// `callHierarchy/incomingCalls` or `outgoingCalls`. The opaque slot
    /// carries `"i:<name>"` / `"o:<name>"` so the reply parser knows
    /// the direction and the origin name (for the picker title) without
    /// stashing the whole item.
    pub fn call_hierarchy_calls(
        &mut self,
        item: &super::CallHierarchyItem,
        direction: super::CallHierarchyDirection,
    ) {
        let (method, tag) = match direction {
            super::CallHierarchyDirection::Incoming => {
                ("callHierarchy/incomingCalls", format!("i:{}", item.name))
            }
            super::CallHierarchyDirection::Outgoing => {
                ("callHierarchy/outgoingCalls", format!("o:{}", item.name))
            }
        };
        self.request_with_context(
            method,
            json!({ "item": item.raw }),
            Some(&item.path),
            Some(tag),
        );
    }

    /// `textDocument/prepareTypeHierarchy`.
    pub fn prepare_type_hierarchy(
        &mut self,
        path: &Path,
        line: u32,
        character: u32,
        direction: super::TypeHierarchyDirection,
    ) {
        let dir = match direction {
            super::TypeHierarchyDirection::Supertypes => "s",
            super::TypeHierarchyDirection::Subtypes => "b",
        };
        self.request_with_context(
            "textDocument/prepareTypeHierarchy",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character }
            }),
            Some(path),
            Some(dir.to_string()),
        );
    }

    /// `typeHierarchy/supertypes` / `subtypes`. Opaque tag is `"s:<name>"`
    /// / `"b:<name>"` so the reply knows direction + origin name.
    pub fn type_hierarchy_types(
        &mut self,
        item: &super::CallHierarchyItem,
        direction: super::TypeHierarchyDirection,
    ) {
        let (method, tag) = match direction {
            super::TypeHierarchyDirection::Supertypes => {
                ("typeHierarchy/supertypes", format!("s:{}", item.name))
            }
            super::TypeHierarchyDirection::Subtypes => {
                ("typeHierarchy/subtypes", format!("b:{}", item.name))
            }
        };
        self.request_with_context(
            method,
            json!({ "item": item.raw }),
            Some(&item.path),
            Some(tag),
        );
    }

    /// `textDocument/onTypeFormatting` — fired when the user types a
    /// trigger char (`}` / `;` / `\n`). Reply is a `TextEdit[]` to apply
    /// in the surrounding area. We hand back the trigger char + cursor
    /// position; the server decides what to format.
    pub fn on_type_formatting(
        &mut self,
        path: &Path,
        line: u32,
        character: u32,
        trigger: char,
        tab_size: u32,
        insert_spaces: bool,
    ) {
        let mut buf = [0u8; 4];
        let ch = trigger.encode_utf8(&mut buf).to_string();
        self.request_with_path(
            "textDocument/onTypeFormatting",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "position": { "line": line, "character": character },
                "ch": ch,
                "options": {
                    "tabSize": tab_size,
                    "insertSpaces": insert_spaces,
                    "trimTrailingWhitespace": true,
                    "insertFinalNewline": true,
                }
            }),
            Some(path),
        );
    }

    /// `textDocument/willSaveWaitUntil` — fired before a save. Reply is a
    /// `TextEdit[]` (possibly null) the server wants applied *before* the
    /// file hits disk. Different from `textDocument/formatting`: this is
    /// the hook some servers (eslint --fix, organizeImports-on-save) use
    /// because the protocol guarantees the edits apply *before* didSave
    /// fires. We pass `reason: 1` (Manual — the user explicitly saved).
    pub fn will_save_wait_until(&mut self, path: &Path) {
        self.request_with_path(
            "textDocument/willSaveWaitUntil",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "reason": 1
            }),
            Some(path),
        );
    }

    /// `textDocument/formatting` — reply is a `TextEdit[]` (possibly null).
    /// The path is stashed so we can route the reply to the right buffer.
    pub fn formatting(&mut self, path: &Path, tab_size: u32, insert_spaces: bool) {
        self.request_with_path(
            "textDocument/formatting",
            json!({
                "textDocument": { "uri": path_to_uri(path) },
                "options": {
                    "tabSize": tab_size,
                    "insertSpaces": insert_spaces,
                    "trimTrailingWhitespace": true,
                    "insertFinalNewline": true,
                }
            }),
            Some(path),
        );
    }

    fn request(&mut self, method: &str, params: serde_json::Value) {
        self.request_with_path(method, params, None);
    }
    fn request_with_path(&mut self, method: &str, params: serde_json::Value, path: Option<&Path>) {
        self.request_with_context(method, params, path, None);
    }
    fn request_with_context(
        &mut self,
        method: &str,
        params: serde_json::Value,
        path: Option<&Path>,
        opaque: Option<String>,
    ) {
        let id = self.next_id;
        self.next_id += 1;
        if let Ok(mut p) = self.pending.lock() {
            p.insert(
                id,
                (method.to_string(), path.map(|p| p.to_path_buf()), opaque),
            );
        }
        self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
    }
    fn notify(&mut self, method: &str, params: serde_json::Value) {
        self.send(&json!({ "jsonrpc": "2.0", "method": method, "params": params }));
    }
    fn send(&self, msg: &serde_json::Value) {
        if let Ok(mut w) = self.stdin.lock() {
            let _ = write_message(&mut *w, msg);
        }
    }
}

impl Drop for LspClient {
    fn drop(&mut self) {
        // Best-effort polite shutdown, then make sure the child + reader exit.
        self.send(&json!({ "jsonrpc": "2.0", "id": -1, "method": "shutdown" }));
        self.send(&json!({ "jsonrpc": "2.0", "method": "exit" }));
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(j) = self.reader.take() {
            let _ = j.join();
        }
        let _ = &self.name; // (kept for debugging / future use)
    }
}

fn write_message(w: &mut impl Write, msg: &serde_json::Value) -> std::io::Result<()> {
    let body = serde_json::to_vec(msg).unwrap_or_default();
    write!(w, "Content-Length: {}\r\n\r\n", body.len())?;
    w.write_all(&body)?;
    w.flush()
}

fn reader_loop(
    stdout: impl Read,
    tx: std::sync::mpsc::Sender<LspEvent>,
    pending: Pending,
    stdin: Sink,
    sem_states: SemStates,
    sem_caps: SemCaps,
) {
    let mut r = BufReader::new(stdout);
    // Per-server semantic-tokens legends, captured when the `initialize`
    // reply lands. Empty until then — semantic-tokens replies before
    // capture are dropped (servers shouldn't send them before initialize
    // anyway). Type-index → name lookup at decode time; the modifier
    // legend lets us resolve each bit in the per-token modifier bitmask
    // back to its string name.
    let mut sem_legend: Vec<String> = Vec::new();
    let mut sem_mod_legend: Vec<String> = Vec::new();
    loop {
        // Read headers until a blank line; we only need Content-Length.
        let mut len: Option<usize> = None;
        loop {
            let mut line = String::new();
            match r.read_line(&mut line) {
                Ok(0) => return, // EOF — server gone
                Ok(_) => {}
                Err(_) => return,
            }
            let trimmed = line.trim_end_matches(['\r', '\n']);
            if trimmed.is_empty() {
                break;
            }
            if let Some(v) = trimmed
                .split_once(':')
                .filter(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                .and_then(|(_, v)| v.trim().parse::<usize>().ok())
            {
                len = Some(v);
            }
        }
        let Some(len) = len else { continue };
        let mut buf = vec![0u8; len];
        if r.read_exact(&mut buf).is_err() {
            return;
        }
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(&buf) else {
            continue;
        };
        handle_message(
            &v,
            &tx,
            &pending,
            &stdin,
            &mut sem_legend,
            &mut sem_mod_legend,
            &sem_states,
            &sem_caps,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_message(
    v: &serde_json::Value,
    tx: &std::sync::mpsc::Sender<LspEvent>,
    pending: &Pending,
    stdin: &Sink,
    sem_legend: &mut Vec<String>,
    sem_mod_legend: &mut Vec<String>,
    sem_states: &SemStates,
    sem_caps: &SemCaps,
) {
    // A server→client request (has both `id` and `method`).
    if let (Some(id), Some(method)) = (v.get("id"), v.get("method").and_then(|m| m.as_str())) {
        // `workspace/applyEdit` — server wants us to apply a WorkspaceEdit.
        // Forward via LspEvent so the App can route it through
        // `apply_rename_edits`, then reply `{applied: true}`.
        if method == "workspace/applyEdit"
            && let Some(edit) = v.get("params").and_then(|p| p.get("edit"))
        {
            let edits = parse_workspace_edit(edit);
            let label = v
                .get("params")
                .and_then(|p| p.get("label"))
                .and_then(|l| l.as_str())
                .map(String::from);
            if !edits.is_empty() {
                let _ = tx.send(LspEvent::ApplyEdit { label, edits });
            }
            if let Ok(mut w) = stdin.lock() {
                let _ = write_message(
                    &mut *w,
                    &json!({ "jsonrpc": "2.0", "id": id, "result": { "applied": true } }),
                );
            }
            return;
        }
        // Default: reply `null` so a strict server (registerCapability /
        // configuration / progress create) moves on.
        if let Ok(mut w) = stdin.lock() {
            let _ = write_message(
                &mut *w,
                &json!({ "jsonrpc": "2.0", "id": id, "result": null }),
            );
        }
        return;
    }

    // A notification.
    if let Some(method) = v.get("method").and_then(|m| m.as_str()) {
        if method == "textDocument/publishDiagnostics"
            && let Some(params) = v.get("params")
            && let Some(uri) = params.get("uri").and_then(|u| u.as_str())
            && let Some(path) = uri_to_path(uri)
        {
            let diags = params
                .get("diagnostics")
                .and_then(|d| d.as_array())
                .map(|a| a.iter().filter_map(parse_diagnostic).collect())
                .unwrap_or_default();
            let _ = tx.send(LspEvent::Diagnostics { path, diags });
        }
        // window/showMessage → toast
        if (method == "window/showMessage" || method == "window/logMessage")
            && let Some(m) = v
                .get("params")
                .and_then(|p| p.get("message"))
                .and_then(|m| m.as_str())
            && method == "window/showMessage"
        {
            let _ = tx.send(LspEvent::Message(format!("LSP: {m}")));
        }
        // `$/progress` — long-running task indicator. Routes to the
        // statusline busy chip via three events (begin / report / end).
        if method == "$/progress"
            && let Some(params) = v.get("params")
            && let Some(token) = params.get("token").and_then(|t| {
                t.as_str()
                    .map(String::from)
                    .or_else(|| t.as_i64().map(|n| n.to_string()))
            })
            && let Some(value) = params.get("value")
            && let Some(kind) = value.get("kind").and_then(|k| k.as_str())
        {
            let title = value
                .get("title")
                .and_then(|s| s.as_str())
                .or_else(|| value.get("message").and_then(|s| s.as_str()))
                .unwrap_or("")
                .to_string();
            match kind {
                "begin" => {
                    let _ = tx.send(LspEvent::ProgressBegin { token, title });
                }
                "report" => {
                    let _ = tx.send(LspEvent::ProgressReport { token, title });
                }
                "end" => {
                    let _ = tx.send(LspEvent::ProgressEnd { token });
                }
                _ => {}
            }
        }
        return;
    }

    // A response to one of our requests.
    if let Some(id) = v.get("id").and_then(|i| i.as_i64()) {
        let pend = pending.lock().ok().and_then(|mut p| p.remove(&id));
        let Some((method, req_path, req_opaque)) = pend else {
            return;
        };
        let Some(result) = v.get("result") else {
            return;
        }; // error / null → nothing to do
        match method.as_str() {
            "textDocument/definition"
            | "textDocument/declaration"
            | "textDocument/typeDefinition"
            | "textDocument/implementation" => {
                if let Some((path, line, ch)) = first_location(result) {
                    let _ = tx.send(LspEvent::GotoDefinition {
                        path,
                        line,
                        character: ch,
                    });
                }
            }
            "textDocument/hover" => {
                if let Some(text) = hover_text(result) {
                    let _ = tx.send(LspEvent::Hover { text });
                }
            }
            "textDocument/references" => {
                let locs: Vec<(PathBuf, u32, u32)> = result
                    .as_array()
                    .map(|a| a.iter().filter_map(first_location).collect())
                    .unwrap_or_default();
                if !locs.is_empty() {
                    let _ = tx.send(LspEvent::References(locs));
                }
            }
            "textDocument/rename" => {
                let edits = parse_workspace_edit(result);
                if !edits.is_empty() {
                    let _ = tx.send(LspEvent::Rename(edits));
                }
            }
            "textDocument/completion" => {
                let items = parse_completion(result);
                if !items.is_empty() {
                    let _ = tx.send(LspEvent::Completion(items));
                }
            }
            "completionItem/resolve" => {
                let (detail, documentation) = parse_completion_resolve(result);
                if let Some(label) = req_opaque
                    && (detail.is_some() || documentation.is_some())
                {
                    let _ = tx.send(LspEvent::CompletionResolve {
                        label,
                        detail,
                        documentation,
                    });
                }
            }
            "textDocument/formatting" | "textDocument/onTypeFormatting" => {
                let edits = parse_text_edits(result);
                if let (false, Some(path)) = (edits.is_empty(), req_path) {
                    let _ = tx.send(LspEvent::Formatting { path, edits });
                }
            }
            "textDocument/willSaveWaitUntil" => {
                // Always emit (even empty) so the App can advance its
                // save state machine — otherwise a no-op server would
                // stall a save behind the deadline.
                let edits = parse_text_edits(result);
                if let Some(path) = req_path {
                    let _ = tx.send(LspEvent::WillSaveWaitUntil { path, edits });
                }
            }
            "textDocument/codeAction" => {
                let actions = parse_code_actions(result);
                let _ = tx.send(LspEvent::CodeAction(actions));
            }
            "codeAction/resolve" => {
                let (edit, command) = parse_code_action_resolve(result);
                let _ = tx.send(LspEvent::CodeActionResolve { edit, command });
            }
            "textDocument/documentSymbol" => {
                let symbols = parse_document_symbols(result);
                let _ = tx.send(LspEvent::DocumentSymbols(symbols));
            }
            "workspace/symbol" => {
                let symbols = parse_workspace_symbols(result);
                if !symbols.is_empty() {
                    let _ = tx.send(LspEvent::WorkspaceSymbols(symbols));
                }
            }
            "textDocument/signatureHelp" => {
                if let Some(sh) = parse_signature_help(result) {
                    let _ = tx.send(LspEvent::SignatureHelp(sh));
                }
            }
            "initialize" => {
                // Cache the server's semanticTokens legend so subsequent
                // `textDocument/semanticTokens/full` replies can resolve
                // type-index → name and modifier-bit → name.
                let provider = result
                    .get("capabilities")
                    .and_then(|c| c.get("semanticTokensProvider"));
                let legend = provider.and_then(|p| p.get("legend"));
                if let Some(types) = legend
                    .and_then(|l| l.get("tokenTypes"))
                    .and_then(|t| t.as_array())
                {
                    sem_legend.clear();
                    for v in types {
                        if let Some(s) = v.as_str() {
                            sem_legend.push(s.to_string());
                        }
                    }
                }
                if let Some(mods) = legend
                    .and_then(|l| l.get("tokenModifiers"))
                    .and_then(|m| m.as_array())
                {
                    sem_mod_legend.clear();
                    for v in mods {
                        if let Some(s) = v.as_str() {
                            sem_mod_legend.push(s.to_string());
                        }
                    }
                }
                // Capture the server's request-shape capability flags.
                let new_caps = parse_semantic_tokens_caps(provider);
                if let Ok(mut caps) = sem_caps.lock() {
                    *caps = new_caps;
                }
            }
            "textDocument/semanticTokens/full" => {
                if let Some(path) = req_path {
                    let raw = extract_semantic_data(result);
                    let result_id = result
                        .get("resultId")
                        .and_then(|v| v.as_str())
                        .map(String::from);
                    let tokens = parse_semantic_tokens_from_raw(&raw, sem_legend, sem_mod_legend);
                    if let Ok(mut s) = sem_states.lock() {
                        s.insert(
                            path.clone(),
                            SemState {
                                result_id,
                                raw_data: raw,
                            },
                        );
                    }
                    let _ = tx.send(LspEvent::SemanticTokens { path, tokens });
                }
            }
            "textDocument/semanticTokens/range" => {
                if let Some(path) = req_path {
                    let raw = extract_semantic_data(result);
                    let tokens = parse_semantic_tokens_from_raw(&raw, sem_legend, sem_mod_legend);
                    // Range replies don't carry a `resultId` we can use
                    // for delta requests (different request shape). Drop
                    // the per-path cache so a future call doesn't try
                    // to send a stale delta against a range result.
                    if let Ok(mut s) = sem_states.lock() {
                        s.remove(&path);
                    }
                    let _ = tx.send(LspEvent::SemanticTokens { path, tokens });
                }
            }
            "textDocument/semanticTokens/full/delta" => {
                if let Some(path) = req_path {
                    let result_id = result
                        .get("resultId")
                        .and_then(|v| v.as_str())
                        .map(String::from);
                    // Two reply shapes — `data` ⇒ server bailed on
                    // computing a delta and returned a fresh full set;
                    // `edits` ⇒ sparse splices to apply to cached raw.
                    if result.get("data").is_some() {
                        let raw = extract_semantic_data(result);
                        let tokens =
                            parse_semantic_tokens_from_raw(&raw, sem_legend, sem_mod_legend);
                        if let Ok(mut s) = sem_states.lock() {
                            s.insert(
                                path.clone(),
                                SemState {
                                    result_id,
                                    raw_data: raw,
                                },
                            );
                        }
                        let _ = tx.send(LspEvent::SemanticTokens { path, tokens });
                    } else if let Some(edits) = parse_semantic_token_edits(result) {
                        // Splice into the cached raw_data; on failure
                        // (out-of-bounds edit) drop the cache so the
                        // next request falls back to `full`.
                        let merged = sem_states.lock().ok().map(|mut s| {
                            let entry = s.entry(path.clone()).or_default();
                            let ok = apply_semantic_token_edits(&mut entry.raw_data, edits);
                            if !ok {
                                s.remove(&path);
                                None
                            } else {
                                entry.result_id = result_id;
                                Some(entry.raw_data.clone())
                            }
                        });
                        let Some(Some(raw)) = merged else {
                            // Edit failed — emit nothing; the App keeps
                            // the previous frame's tokens until the next
                            // save kicks off a fresh `full` request.
                            return;
                        };
                        let tokens =
                            parse_semantic_tokens_from_raw(&raw, sem_legend, sem_mod_legend);
                        let _ = tx.send(LspEvent::SemanticTokens { path, tokens });
                    }
                }
            }
            "textDocument/inlayHint" => {
                if let Some(path) = req_path {
                    let hints = parse_inlay_hints(result);
                    let _ = tx.send(LspEvent::InlayHints { path, hints });
                }
            }
            "textDocument/codeLens" => {
                if let Some(path) = req_path {
                    let lenses = parse_code_lenses(result);
                    let _ = tx.send(LspEvent::CodeLens { path, lenses });
                }
            }
            "textDocument/documentLink" => {
                if let Some(path) = req_path {
                    let links = parse_document_links(result);
                    if !links.is_empty() {
                        let _ = tx.send(LspEvent::DocumentLinks { path, links });
                    }
                }
            }
            "textDocument/foldingRange" => {
                if let Some(path) = req_path {
                    let ranges = parse_folding_ranges(result);
                    let _ = tx.send(LspEvent::FoldingRanges { path, ranges });
                }
            }
            "textDocument/selectionRange" => {
                if let Some(path) = req_path {
                    let ranges = parse_selection_ranges(result);
                    let _ = tx.send(LspEvent::SelectionRanges { path, ranges });
                }
            }
            "textDocument/documentColor" => {
                if let Some(path) = req_path {
                    let colors = parse_document_color(result);
                    let _ = tx.send(LspEvent::DocumentColor { path, colors });
                }
            }
            "textDocument/documentHighlight" => {
                if let Some(path) = req_path {
                    let ranges = parse_document_highlights(result);
                    let _ = tx.send(LspEvent::DocumentHighlights { path, ranges });
                }
            }
            "textDocument/prepareCallHierarchy" => {
                // `req_opaque` is "i" or "o" — the direction of the
                // follow-up call the App wants.
                let direction = match req_opaque.as_deref() {
                    Some("o") => super::CallHierarchyDirection::Outgoing,
                    _ => super::CallHierarchyDirection::Incoming,
                };
                let items = parse_call_hierarchy_items(result);
                let _ = tx.send(LspEvent::CallHierarchyPrepared { direction, items });
            }
            "callHierarchy/incomingCalls" | "callHierarchy/outgoingCalls" => {
                // `req_opaque` is "i:<name>" / "o:<name>".
                let (direction, origin_name) = match req_opaque.as_deref() {
                    Some(s) if s.starts_with("o:") => {
                        (super::CallHierarchyDirection::Outgoing, s[2..].to_string())
                    }
                    Some(s) if s.starts_with("i:") => {
                        (super::CallHierarchyDirection::Incoming, s[2..].to_string())
                    }
                    _ => (super::CallHierarchyDirection::Incoming, String::new()),
                };
                let hits = parse_call_hierarchy_calls(result, direction);
                let _ = tx.send(LspEvent::CallHierarchyCalls {
                    direction,
                    origin_name,
                    hits,
                });
            }
            "textDocument/prepareTypeHierarchy" => {
                let direction = match req_opaque.as_deref() {
                    Some("b") => super::TypeHierarchyDirection::Subtypes,
                    _ => super::TypeHierarchyDirection::Supertypes,
                };
                let items = parse_call_hierarchy_items(result);
                let _ = tx.send(LspEvent::TypeHierarchyPrepared { direction, items });
            }
            "typeHierarchy/supertypes" | "typeHierarchy/subtypes" => {
                let (direction, origin_name) = match req_opaque.as_deref() {
                    Some(s) if s.starts_with("b:") => {
                        (super::TypeHierarchyDirection::Subtypes, s[2..].to_string())
                    }
                    Some(s) if s.starts_with("s:") => (
                        super::TypeHierarchyDirection::Supertypes,
                        s[2..].to_string(),
                    ),
                    _ => (super::TypeHierarchyDirection::Supertypes, String::new()),
                };
                let hits = parse_type_hierarchy_types(result);
                let _ = tx.send(LspEvent::TypeHierarchyTypes {
                    direction,
                    origin_name,
                    hits,
                });
            }
            _ => {}
        }
    }
}

/// Parse a `textDocument/prepareCallHierarchy` reply
/// (`CallHierarchyItem[]`). Each item's full JSON is preserved as `raw`
/// so the follow-up `incomingCalls` / `outgoingCalls` request can hand
/// it back to the server verbatim (the spec requires this round-trip).
pub fn parse_call_hierarchy_items(result: &serde_json::Value) -> Vec<super::CallHierarchyItem> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let Some(name) = it.get("name").and_then(|v| v.as_str()) else {
            continue;
        };
        let kind = it.get("kind").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let Some(uri) = it.get("uri").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(path) = uri_to_path(uri) else {
            continue;
        };
        let line = it
            .get("selectionRange")
            .and_then(|r| r.get("start"))
            .and_then(|s| s.get("line"))
            .and_then(|n| n.as_u64())
            .unwrap_or(0) as u32;
        let character = it
            .get("selectionRange")
            .and_then(|r| r.get("start"))
            .and_then(|s| s.get("character"))
            .and_then(|n| n.as_u64())
            .unwrap_or(0) as u32;
        out.push(super::CallHierarchyItem {
            name: name.to_string(),
            kind,
            path,
            line,
            character,
            raw: it.clone(),
        });
    }
    out
}

/// Parse a `typeHierarchy/{super,sub}types` reply. The reply is a flat
/// array of `TypeHierarchyItem` (same shape as `CallHierarchyItem`).
/// We surface only `(name, path, line, character)` since the picker
/// only needs a location.
pub fn parse_type_hierarchy_types(result: &serde_json::Value) -> Vec<super::CallHit> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for it in arr {
        let Some(name) = it.get("name").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(uri) = it.get("uri").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(path) = uri_to_path(uri) else {
            continue;
        };
        let line = it
            .get("selectionRange")
            .and_then(|r| r.get("start"))
            .and_then(|s| s.get("line"))
            .and_then(|n| n.as_u64())
            .unwrap_or(0) as u32;
        let character = it
            .get("selectionRange")
            .and_then(|r| r.get("start"))
            .and_then(|s| s.get("character"))
            .and_then(|n| n.as_u64())
            .unwrap_or(0) as u32;
        out.push(super::CallHit {
            name: name.to_string(),
            path,
            line,
            character,
        });
    }
    out
}

/// Parse a `callHierarchy/{incoming,outgoing}Calls` reply. The reply
/// is an array of `CallHierarchyIncomingCall` / `CallHierarchyOutgoingCall`
/// objects. For incoming: `from` is the caller, `fromRanges` are the
/// call sites in the caller's file. For outgoing: `to` is the callee
/// (use its own `range` / `selectionRange`).
pub fn parse_call_hierarchy_calls(
    result: &serde_json::Value,
    direction: super::CallHierarchyDirection,
) -> Vec<super::CallHit> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for it in arr {
        let (item_key, range_key) = match direction {
            super::CallHierarchyDirection::Incoming => ("from", "fromRanges"),
            super::CallHierarchyDirection::Outgoing => ("to", "fromRanges"),
        };
        let Some(item) = it.get(item_key) else {
            continue;
        };
        let Some(name) = item.get("name").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(uri) = item.get("uri").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(path) = uri_to_path(uri) else {
            continue;
        };
        // For incoming we'd like to land on the *call site* in the caller;
        // for outgoing the call site list `fromRanges` is again in the
        // *caller* (the prepared item) — but pointing the user at the
        // callee's `selectionRange` is what they expect. Pick accordingly.
        let pos = match direction {
            super::CallHierarchyDirection::Incoming => it
                .get(range_key)
                .and_then(|a| a.as_array())
                .and_then(|a| a.first())
                .and_then(|r| r.get("start")),
            super::CallHierarchyDirection::Outgoing => {
                item.get("selectionRange").and_then(|r| r.get("start"))
            }
        };
        let (Some(line), Some(character)) = (
            pos.and_then(|p| p.get("line")).and_then(|n| n.as_u64()),
            pos.and_then(|p| p.get("character"))
                .and_then(|n| n.as_u64()),
        ) else {
            continue;
        };
        out.push(super::CallHit {
            name: name.to_string(),
            path,
            line: line as u32,
            character: character as u32,
        });
    }
    out
}

/// Parse a `textDocument/documentHighlight` reply
/// (`DocumentHighlight[]`). Each entry has a `range`; the `kind` field
/// (read/write/text) is dropped — the renderer paints them uniformly.
pub fn parse_document_highlights(result: &serde_json::Value) -> Vec<(u32, u32, u32, u32)> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let Some(range) = it.get("range") else {
            continue;
        };
        let (Some(s_line), Some(s_char), Some(e_line), Some(e_char)) = (
            range
                .get("start")
                .and_then(|s| s.get("line"))
                .and_then(|n| n.as_u64()),
            range
                .get("start")
                .and_then(|s| s.get("character"))
                .and_then(|n| n.as_u64()),
            range
                .get("end")
                .and_then(|e| e.get("line"))
                .and_then(|n| n.as_u64()),
            range
                .get("end")
                .and_then(|e| e.get("character"))
                .and_then(|n| n.as_u64()),
        ) else {
            continue;
        };
        if s_line != e_line {
            continue;
        }
        out.push((s_line as u32, s_char as u32, e_line as u32, e_char as u32));
    }
    out
}

/// Parse a `textDocument/documentColor` reply (`ColorInformation[]`).
/// Each entry has a `range` and a `color { red, green, blue, alpha }`
/// with components in `[0.0, 1.0]`. We drop alpha and pack RGB into
/// `0xRRGGBB`. Multi-line ranges are dropped — the renderer is per-line.
pub fn parse_document_color(result: &serde_json::Value) -> Vec<super::ColorDecoration> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let Some(range) = it.get("range") else {
            continue;
        };
        let (Some(s_line), Some(s_char), Some(e_line), Some(e_char)) = (
            range
                .get("start")
                .and_then(|s| s.get("line"))
                .and_then(|n| n.as_u64()),
            range
                .get("start")
                .and_then(|s| s.get("character"))
                .and_then(|n| n.as_u64()),
            range
                .get("end")
                .and_then(|e| e.get("line"))
                .and_then(|n| n.as_u64()),
            range
                .get("end")
                .and_then(|e| e.get("character"))
                .and_then(|n| n.as_u64()),
        ) else {
            continue;
        };
        if s_line != e_line {
            continue;
        }
        let Some(color) = it.get("color") else {
            continue;
        };
        let r = color.get("red").and_then(|n| n.as_f64()).unwrap_or(0.0);
        let g = color.get("green").and_then(|n| n.as_f64()).unwrap_or(0.0);
        let b = color.get("blue").and_then(|n| n.as_f64()).unwrap_or(0.0);
        let r8 = (r.clamp(0.0, 1.0) * 255.0).round() as u32;
        let g8 = (g.clamp(0.0, 1.0) * 255.0).round() as u32;
        let b8 = (b.clamp(0.0, 1.0) * 255.0).round() as u32;
        out.push(super::ColorDecoration {
            line: s_line as u32,
            start_char: s_char as u32,
            end_char: e_char as u32,
            rgb: (r8 << 16) | (g8 << 8) | b8,
        });
    }
    out
}

/// Parse a `textDocument/selectionRange` reply. The reply is one
/// `SelectionRange` per requested position; we only ever request one,
/// so we walk the linked list of `parent` entries from the first reply
/// and return the ranges smallest → largest.
pub fn parse_selection_ranges(result: &serde_json::Value) -> Vec<(u32, u32, u32, u32)> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let Some(first) = arr.first() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut cur = Some(first);
    while let Some(node) = cur {
        let Some(range) = node.get("range") else {
            break;
        };
        let (Some(s_line), Some(s_char)) = (
            range
                .get("start")
                .and_then(|s| s.get("line"))
                .and_then(|n| n.as_u64()),
            range
                .get("start")
                .and_then(|s| s.get("character"))
                .and_then(|n| n.as_u64()),
        ) else {
            break;
        };
        let (Some(e_line), Some(e_char)) = (
            range
                .get("end")
                .and_then(|e| e.get("line"))
                .and_then(|n| n.as_u64()),
            range
                .get("end")
                .and_then(|e| e.get("character"))
                .and_then(|n| n.as_u64()),
        ) else {
            break;
        };
        out.push((s_line as u32, s_char as u32, e_line as u32, e_char as u32));
        cur = node.get("parent");
    }
    out
}

/// Parse a `textDocument/foldingRange` reply (`FoldingRange[]`).
/// Returns `(start_line, end_line)` pairs, inclusive on both ends.
/// Ranges where end <= start are dropped (vim convention — a fold must
/// have at least one hidden line).
pub fn parse_folding_ranges(result: &serde_json::Value) -> Vec<(u32, u32)> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let Some(start) = it
            .get("startLine")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32)
        else {
            continue;
        };
        let Some(end) = it.get("endLine").and_then(|v| v.as_u64()).map(|n| n as u32) else {
            continue;
        };
        if end <= start {
            continue;
        }
        out.push((start, end));
    }
    out
}

/// Parse a `textDocument/documentLink` reply (`DocumentLink[]`). Drops any
/// entry without a `target` (mnml doesn't resolve lazily yet). Multi-line
/// ranges are dropped — the renderer is per-line.
fn parse_document_links(result: &serde_json::Value) -> Vec<super::DocumentLink> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let target = match it.get("target").and_then(|t| t.as_str()) {
            Some(t) => t.to_string(),
            None => continue,
        };
        let Some(range) = it.get("range") else {
            continue;
        };
        let Some(start) = range.get("start") else {
            continue;
        };
        let Some(end) = range.get("end") else {
            continue;
        };
        let (Some(s_line), Some(s_char)) = (
            start.get("line").and_then(|l| l.as_u64()),
            start.get("character").and_then(|c| c.as_u64()),
        ) else {
            continue;
        };
        let (Some(e_line), Some(e_char)) = (
            end.get("line").and_then(|l| l.as_u64()),
            end.get("character").and_then(|c| c.as_u64()),
        ) else {
            continue;
        };
        if s_line != e_line {
            continue;
        }
        out.push(super::DocumentLink {
            line: s_line as u32,
            start_char: s_char as u32,
            end_char: e_char as u32,
            target,
        });
    }
    out
}

/// Pull the first `(path, line, character)` out of a `definition` result, which
/// may be a `Location`, `Location[]`, a `LocationLink`, or `LocationLink[]`.
fn first_location(result: &serde_json::Value) -> Option<(PathBuf, u32, u32)> {
    let one = match result {
        serde_json::Value::Array(a) => a.first()?,
        other => other,
    };
    // LocationLink uses `targetUri` + `targetSelectionRange`; Location uses `uri` + `range`.
    let uri = one
        .get("uri")
        .or_else(|| one.get("targetUri"))
        .and_then(|u| u.as_str())?;
    let range = one
        .get("range")
        .or_else(|| one.get("targetSelectionRange"))?;
    let start = range.get("start")?;
    Some((
        uri_to_path(uri)?,
        start.get("line")?.as_u64()? as u32,
        start.get("character")?.as_u64()? as u32,
    ))
}

/// Parse a `WorkspaceEdit` (`{ changes: { uri: TextEdit[] } }` and/or
/// `{ documentChanges: [{ textDocument: {uri}, edits: TextEdit[] }, …] }`) into
/// `(path, [(range, new_text)])` per file. `null` / unknown shapes ⇒ empty.
fn parse_workspace_edit(result: &serde_json::Value) -> Vec<(PathBuf, Vec<(Range, String)>)> {
    let mut out: Vec<(PathBuf, Vec<(Range, String)>)> = Vec::new();
    let mut push = |uri: &str, edits: &serde_json::Value| {
        let Some(path) = uri_to_path(uri) else { return };
        let mut parsed: Vec<(Range, String)> = Vec::new();
        if let Some(arr) = edits.as_array() {
            for e in arr {
                if let Some(te) = parse_text_edit(e) {
                    parsed.push(te);
                }
            }
        }
        if !parsed.is_empty() {
            out.push((path, parsed));
        }
    };
    if let Some(changes) = result.get("changes").and_then(|c| c.as_object()) {
        for (uri, edits) in changes {
            push(uri, edits);
        }
    }
    if let Some(dcs) = result.get("documentChanges").and_then(|d| d.as_array()) {
        for dc in dcs {
            // Skip create/rename/delete-file operations (they have a "kind" field).
            if dc.get("kind").is_some() {
                continue;
            }
            if let (Some(uri), Some(edits)) = (
                dc.get("textDocument")
                    .and_then(|t| t.get("uri"))
                    .and_then(|u| u.as_str()),
                dc.get("edits"),
            ) {
                push(uri, edits);
            }
        }
    }
    out
}

/// Parse a `textDocument/completion` result (`CompletionItem[]` or
/// `CompletionList { items }`) into `(label, insert_text, detail, doc, raw,
/// is_snippet)` per item. `insertText` (then `textEdit.newText`, then
/// `label`) supplies the text to insert. Snippet items
/// (`insertTextFormat == 2`) keep their LSP snippet syntax in `insert` —
/// the App side runs it through `lsp_snippet::to_mnml` on accept and
/// applies it via `App::apply_snippet_edit` so `$1` / `$0` placeholders
/// drive the existing Tab-cycle.
fn parse_completion(result: &serde_json::Value) -> Vec<super::CompletionItemTuple> {
    let arr = match result {
        serde_json::Value::Array(a) => a,
        serde_json::Value::Object(o) => match o.get("items").and_then(|i| i.as_array()) {
            Some(a) => a,
            None => return Vec::new(),
        },
        _ => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let Some(label) = it.get("label").and_then(|l| l.as_str()) else {
            continue;
        };
        let is_snippet = it.get("insertTextFormat").and_then(|f| f.as_u64()) == Some(2);
        let insert = it
            .get("insertText")
            .and_then(|t| t.as_str())
            .or_else(|| {
                it.get("textEdit")
                    .and_then(|e| e.get("newText"))
                    .and_then(|t| t.as_str())
            })
            .unwrap_or(label)
            .to_string();
        let detail = it
            .get("detail")
            .and_then(|d| d.as_str())
            .map(str::to_string);
        let documentation = parse_completion_doc(it.get("documentation"));
        out.push((
            label.to_string(),
            insert,
            detail,
            documentation,
            it.clone(),
            is_snippet,
        ));
    }
    out
}

/// Extract doc text from a `documentation` field — handles plain-string
/// and `MarkupContent { kind, value }` shapes.
fn parse_completion_doc(v: Option<&serde_json::Value>) -> Option<String> {
    v.and_then(|d| match d {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Object(o) => o.get("value").and_then(|v| v.as_str()).map(String::from),
        _ => None,
    })
}

/// Parse a `completionItem/resolve` reply — `(detail, documentation)` from
/// the resolved item. The label is matched on the App side from the
/// pending-request stash so the popup can find which row to update.
pub(crate) fn parse_completion_resolve(
    result: &serde_json::Value,
) -> (Option<String>, Option<String>) {
    let detail = result
        .get("detail")
        .and_then(|d| d.as_str())
        .map(String::from);
    let documentation = parse_completion_doc(result.get("documentation"));
    (detail, documentation)
}

/// Parse a `TextEdit[]` (the shape `textDocument/formatting` returns).
fn parse_text_edits(result: &serde_json::Value) -> Vec<(Range, String)> {
    result
        .as_array()
        .map(|a| a.iter().filter_map(parse_text_edit).collect())
        .unwrap_or_default()
}

fn parse_text_edit(v: &serde_json::Value) -> Option<(Range, String)> {
    let r = v.get("range")?;
    let pos = |k: &str| -> Option<Pos> {
        let p = r.get(k)?;
        Some(Pos {
            line: p.get("line")?.as_u64()? as u32,
            character: p.get("character")?.as_u64()? as u32,
        })
    };
    let new_text = v.get("newText").and_then(|t| t.as_str())?.to_string();
    Some((
        Range {
            start: pos("start")?,
            end: pos("end")?,
        },
        new_text,
    ))
}

/// Parse a `textDocument/codeAction` result — `(Command | CodeAction)[]` — into
/// our [`CodeAction`] list. Items missing both `edit` and `command` (the "needs
/// resolve" shape) are kept with empty fields so callers can still display them
/// but won't try to apply anything; in practice we don't advertise
/// `resolveSupport` so servers return eager actions.
fn parse_code_actions(result: &serde_json::Value) -> Vec<CodeAction> {
    let arr = match result.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        // Legacy `Command` shape: `{ title, command, arguments? }` (no `edit`).
        let title = match it.get("title").and_then(|t| t.as_str()) {
            Some(t) => t.to_string(),
            None => continue,
        };
        // Skip "disabled" actions (the server told us they don't apply).
        if it.get("disabled").is_some() {
            continue;
        }
        let kind = it.get("kind").and_then(|k| k.as_str()).map(str::to_string);
        let edit = it.get("edit").map(parse_workspace_edit).and_then(|e| {
            if e.is_empty() && it.get("edit").map(|j| j.is_null()).unwrap_or(true) {
                None
            } else {
                Some(e)
            }
        });
        // Two shapes: a CodeAction with nested `command: Command`, or a bare
        // `Command` literal (the `command` field is itself a string).
        let command = match it.get("command") {
            Some(serde_json::Value::Object(o)) => {
                o.get("command")
                    .and_then(|c| c.as_str())
                    .map(|c| CodeCommand {
                        command: c.to_string(),
                        arguments: o
                            .get("arguments")
                            .and_then(|a| a.as_array())
                            .cloned()
                            .unwrap_or_default(),
                    })
            }
            Some(serde_json::Value::String(s)) => Some(CodeCommand {
                command: s.clone(),
                arguments: it
                    .get("arguments")
                    .and_then(|a| a.as_array())
                    .cloned()
                    .unwrap_or_default(),
            }),
            _ => None,
        };
        out.push(CodeAction {
            title,
            kind,
            edit,
            command,
            raw: Some(it.clone()),
        });
    }
    out
}

/// Parse a `codeAction/resolve` reply — returns `(edit, command)` from the
/// resolved action. Same shape as one entry of [`parse_code_actions`] but
/// without re-extracting title/kind (the App already has those).
pub(crate) fn parse_code_action_resolve(
    result: &serde_json::Value,
) -> (Option<super::WorkspaceEdit>, Option<super::CodeCommand>) {
    let edit = result.get("edit").map(parse_workspace_edit).and_then(|e| {
        if e.is_empty() && result.get("edit").map(|j| j.is_null()).unwrap_or(true) {
            None
        } else {
            Some(e)
        }
    });
    let command = match result.get("command") {
        Some(serde_json::Value::Object(o)) => {
            o.get("command")
                .and_then(|c| c.as_str())
                .map(|c| super::CodeCommand {
                    command: c.to_string(),
                    arguments: o
                        .get("arguments")
                        .and_then(|a| a.as_array())
                        .cloned()
                        .unwrap_or_default(),
                })
        }
        Some(serde_json::Value::String(s)) => Some(super::CodeCommand {
            command: s.clone(),
            arguments: result
                .get("arguments")
                .and_then(|a| a.as_array())
                .cloned()
                .unwrap_or_default(),
        }),
        _ => None,
    };
    (edit, command)
}

/// Parse a `textDocument/documentSymbol` reply, handling both shapes — the
/// hierarchical `DocumentSymbol[]` (preferred) and the legacy flat
/// `SymbolInformation[]`. Children are walked depth-first so the picker shows
/// them indented under their parents. Empty / null result ⇒ empty vec.
fn parse_document_symbols(result: &serde_json::Value) -> Vec<DocumentSymbol> {
    let Some(arr) = result.as_array() else {
        return Vec::new();
    };
    if arr.is_empty() {
        return Vec::new();
    }
    let is_hierarchical = arr.iter().any(|v| v.get("range").is_some());
    let mut out = Vec::new();
    if is_hierarchical {
        for v in arr {
            walk_doc_symbol(v, 0, &mut out);
        }
    } else {
        // SymbolInformation[]: flat, `location.range` for the position.
        for v in arr {
            if let Some(s) = parse_symbol_information(v) {
                out.push(s);
            }
        }
    }
    out
}

fn walk_doc_symbol(v: &serde_json::Value, depth: u32, out: &mut Vec<DocumentSymbol>) {
    let Some(name) = v.get("name").and_then(|n| n.as_str()) else {
        return;
    };
    let kind = symbol_kind_label(v.get("kind").and_then(|k| k.as_u64()).unwrap_or(0));
    // `selectionRange` is the identifier itself; fall back to the full `range`.
    let pos = v
        .get("selectionRange")
        .or_else(|| v.get("range"))
        .and_then(|r| r.get("start"))
        .and_then(|s| {
            Some((
                s.get("line")?.as_u64()? as u32,
                s.get("character")?.as_u64()? as u32,
            ))
        });
    let (line, character) = pos.unwrap_or((0, 0));
    out.push(DocumentSymbol {
        name: name.to_string(),
        kind,
        line,
        character,
        depth,
    });
    if let Some(children) = v.get("children").and_then(|c| c.as_array()) {
        for child in children {
            walk_doc_symbol(child, depth + 1, out);
        }
    }
}

/// Parse a `workspace/symbol` reply — `SymbolInformation[]` or (in newer LSP)
/// `WorkspaceSymbol[]`. Both shapes carry `name`, `kind`, and a `location`
/// (either eager `{ uri, range }` or lazy `{ uri }`). Lazy locations land at
/// (0, 0). `containerName` becomes a dim picker detail.
fn parse_workspace_symbols(result: &serde_json::Value) -> Vec<crate::lsp::WorkspaceSymbol> {
    let Some(arr) = result.as_array() else {
        return Vec::new();
    };
    let mut out: Vec<crate::lsp::WorkspaceSymbol> = Vec::new();
    for v in arr {
        let Some(name) = v.get("name").and_then(|n| n.as_str()) else {
            continue;
        };
        let kind = symbol_kind_label(v.get("kind").and_then(|k| k.as_u64()).unwrap_or(0));
        let container = v
            .get("containerName")
            .and_then(|c| c.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        // location is either { uri, range } (SymbolInformation) or a bare uri
        // wrapped in { uri } (lazy WorkspaceSymbol). Try both.
        let loc = v.get("location");
        let uri = loc
            .and_then(|l| l.get("uri"))
            .and_then(|u| u.as_str())
            .or_else(|| v.get("uri").and_then(|u| u.as_str()));
        let Some(uri) = uri else { continue };
        let Some(path) = uri_to_path(uri) else {
            continue;
        };
        let (line, character) = loc
            .and_then(|l| l.get("range"))
            .and_then(|r| r.get("start"))
            .and_then(|s| {
                Some((
                    s.get("line")?.as_u64()? as u32,
                    s.get("character")?.as_u64()? as u32,
                ))
            })
            .unwrap_or((0, 0));
        out.push(crate::lsp::WorkspaceSymbol {
            name: name.to_string(),
            kind,
            path,
            line,
            character,
            container,
        });
    }
    out
}

/// Parse a `textDocument/signatureHelp` reply into [`crate::lsp::SignatureHelp`].
/// Returns `None` for null / empty replies so the open popup can stay put
/// (the spec says null means "no change", not "dismiss").
/// Parse a `textDocument/codeLens` reply (`CodeLens[]` or null) into our
/// flat `(line, title)` form. Lenses without a command (i.e., requiring
/// `codeLens/resolve` to flesh out) are dropped — the renderer needs the
/// title text up front.
pub fn parse_code_lenses(result: &serde_json::Value) -> Vec<crate::lsp::CodeLens> {
    let mut out = Vec::new();
    let Some(arr) = result.as_array() else {
        return out;
    };
    for lens in arr {
        let Some(range) = lens.get("range") else {
            continue;
        };
        let Some(start) = range.get("start") else {
            continue;
        };
        let line = start.get("line").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let title = lens
            .get("command")
            .and_then(|c| c.get("title"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if !title.is_empty() {
            out.push(crate::lsp::CodeLens { line, title });
        }
    }
    out
}

/// Decode a `textDocument/semanticTokens/full` reply against the per-server
/// `legend`. The protocol's `data` is a flat array of u32, 5-per-token, with
/// `(deltaLine, deltaStart, length, tokenTypeIdx, tokenModifiersBitmask)`:
///
/// * `deltaLine` is relative to the *previous token's* line (or 0 for the
///   first). When > 0, `deltaStart` is the absolute char column on the new
///   line; when 0 (same-line continuation), `deltaStart` is relative to the
///   previous token's start char.
/// * `length` is in chars (not bytes — UTF-16 by spec, but most servers in
///   practice work in chars; we follow the more-common interpretation).
/// * `tokenTypeIdx` indexes into `legend`; we resolve to the type-name
///   string before emitting so the renderer doesn't have to keep the legend.
/// * `tokenModifiersBitmask` is decoded against `mod_legend` — each set bit
///   resolves to a modifier name (`"deprecated"` / `"readonly"` / etc.)
///   the renderer maps to a `Modifier` style (CROSSED_OUT / DIM / etc.).
///
/// Returns `Vec<SemanticToken>` in source order. Empty when the reply is
/// shaped weirdly (no `data` array, or non-multiple-of-5 length).
pub fn parse_semantic_tokens(
    result: &serde_json::Value,
    legend: &[String],
    mod_legend: &[String],
) -> Vec<crate::lsp::SemanticToken> {
    let raw = extract_semantic_data(result);
    parse_semantic_tokens_from_raw(&raw, legend, mod_legend)
}

/// Pull the flat `data: number[]` array off a `SemanticTokens` reply
/// into a typed `Vec<u32>`. Returns empty when the field is missing or
/// shaped wrong (non-array, non-numeric entries).
pub(crate) fn extract_semantic_data(result: &serde_json::Value) -> Vec<u32> {
    let Some(arr) = result.get("data").and_then(|d| d.as_array()) else {
        return Vec::new();
    };
    arr.iter().map(|v| v.as_u64().unwrap_or(0) as u32).collect()
}

/// Core decoder — same delta-encoded shape as the protocol's `data[]`, but
/// already typed as `Vec<u32>`. Splits the reply parser from the cache-
/// merging path so deltas can decode without round-tripping through JSON.
pub(crate) fn parse_semantic_tokens_from_raw(
    data: &[u32],
    legend: &[String],
    mod_legend: &[String],
) -> Vec<crate::lsp::SemanticToken> {
    if !data.len().is_multiple_of(5) || legend.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(data.len() / 5);
    let mut line: u32 = 0;
    let mut start: u32 = 0;
    for chunk in data.chunks_exact(5) {
        let delta_line = chunk[0];
        let delta_start = chunk[1];
        let length = chunk[2];
        let type_idx = chunk[3] as usize;
        let mod_bits = chunk[4];
        line += delta_line;
        if delta_line == 0 {
            start += delta_start;
        } else {
            start = delta_start;
        }
        if length == 0 {
            continue;
        }
        let type_name = legend
            .get(type_idx)
            .cloned()
            .unwrap_or_else(|| String::from("unknown"));
        let modifiers = decode_modifier_bits(mod_bits, mod_legend);
        out.push(crate::lsp::SemanticToken {
            line,
            start_char: start,
            length,
            type_name,
            modifiers,
        });
    }
    out
}

/// Parse the server's `semanticTokensProvider` capability from its
/// `initialize` reply into the three flags we use to pick a request
/// shape. `provider` is the value at `capabilities.semanticTokensProvider`,
/// or `None` when the server didn't advertise semantic tokens.
///
/// `requests.full` can be `true` (full only) or `{ delta: true }`
/// (full + delta). `requests.range` can be `true` or an object. When
/// the provider exists but `requests` is bare, we assume `full` is
/// supported (older LSP servers may not populate `requests`).
fn parse_semantic_tokens_caps(provider: Option<&serde_json::Value>) -> SemServerCaps {
    let Some(provider) = provider else {
        return SemServerCaps {
            supports_full: false,
            supports_delta: false,
            supports_range: false,
        };
    };
    let requests = provider.get("requests");
    let full = requests.and_then(|r| r.get("full"));
    let supports_full = match full {
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::Object(_)) => true,
        _ => requests.is_none(),
    };
    let supports_delta = match full {
        Some(serde_json::Value::Object(o)) => {
            o.get("delta").and_then(|v| v.as_bool()).unwrap_or(false)
        }
        _ => false,
    };
    let supports_range = match requests.and_then(|r| r.get("range")) {
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::Object(_)) => true,
        _ => false,
    };
    SemServerCaps {
        supports_full,
        supports_delta,
        supports_range,
    }
}

/// Decode a modifier bitmask against the per-server modifier legend.
/// Bit `i` set ⇒ `mod_legend[i]` is in the returned list. Unknown bits
/// (set beyond `mod_legend.len()`) are dropped silently — a forward-
/// compat shape since some servers report modifiers we don't recognize.
pub(crate) fn decode_modifier_bits(bits: u32, mod_legend: &[String]) -> Vec<String> {
    if bits == 0 || mod_legend.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (i, name) in mod_legend.iter().enumerate() {
        if bits & (1 << i) != 0 {
            out.push(name.clone());
        }
    }
    out
}

/// Parse a `SemanticTokensDelta` reply's `edits[]` into typed splices.
/// Each edit: `{ start, deleteCount, data?: [u32] }`. Returns `None` when
/// the reply isn't a delta shape (no `edits` array) so the caller can
/// branch on full-replacement vs delta cleanly.
pub(crate) fn parse_semantic_token_edits(
    result: &serde_json::Value,
) -> Option<Vec<SemanticTokenEdit>> {
    let arr = result.get("edits")?.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for e in arr {
        let start = e.get("start").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        let delete_count = e.get("deleteCount").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        let data: Vec<u32> = e
            .get("data")
            .and_then(|d| d.as_array())
            .map(|a| a.iter().map(|v| v.as_u64().unwrap_or(0) as u32).collect())
            .unwrap_or_default();
        out.push(SemanticTokenEdit {
            start,
            delete_count,
            data,
        });
    }
    Some(out)
}

/// One splice operation against the cached raw token data.
#[derive(Debug, Clone)]
pub(crate) struct SemanticTokenEdit {
    pub start: usize,
    pub delete_count: usize,
    pub data: Vec<u32>,
}

/// Apply a server-supplied list of edits to the cached raw token array.
/// Edits are applied in descending-`start` order so earlier offsets stay
/// valid as later splices shrink/grow the array. Returns `false` when an
/// edit is out of bounds — the caller should drop the cache and request
/// `full` instead of trusting a half-merged buffer.
pub(crate) fn apply_semantic_token_edits(
    raw: &mut Vec<u32>,
    edits: Vec<SemanticTokenEdit>,
) -> bool {
    let mut edits = edits;
    edits.sort_by_key(|e| std::cmp::Reverse(e.start));
    for e in edits {
        if e.start > raw.len() || e.start.saturating_add(e.delete_count) > raw.len() {
            return false;
        }
        raw.splice(e.start..e.start + e.delete_count, e.data);
    }
    true
}

/// Parse a `textDocument/inlayHint` reply (`InlayHint[]` or null) into our
/// flat `(line, char, label)` form. Labels can be either a plain string or
/// an array of `InlayHintLabelPart` (we concatenate the parts' values).
pub fn parse_inlay_hints(result: &serde_json::Value) -> Vec<crate::lsp::InlayHint> {
    let mut out = Vec::new();
    let Some(arr) = result.as_array() else {
        return out;
    };
    for hint in arr {
        let Some(pos) = hint.get("position") else {
            continue;
        };
        let line = pos.get("line").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let character = pos.get("character").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let label = match hint.get("label") {
            Some(serde_json::Value::String(s)) => s.clone(),
            Some(serde_json::Value::Array(parts)) => parts
                .iter()
                .filter_map(|p| p.get("value").and_then(|v| v.as_str()))
                .collect::<Vec<_>>()
                .join(""),
            _ => continue,
        };
        if !label.is_empty() {
            out.push(crate::lsp::InlayHint {
                line,
                character,
                label,
            });
        }
    }
    out
}

fn parse_signature_help(result: &serde_json::Value) -> Option<crate::lsp::SignatureHelp> {
    if result.is_null() {
        return None;
    }
    let sigs_v = result.get("signatures").and_then(|s| s.as_array())?;
    if sigs_v.is_empty() {
        return None;
    }
    let active_signature = result
        .get("activeSignature")
        .and_then(|v| v.as_u64())
        .map(|n| n as usize)
        .unwrap_or(0);
    let top_active_param = result
        .get("activeParameter")
        .and_then(|v| v.as_u64())
        .map(|n| n as usize);
    let mut sigs: Vec<crate::lsp::SignatureInfo> = Vec::with_capacity(sigs_v.len());
    for s in sigs_v {
        let label = s
            .get("label")
            .and_then(|l| l.as_str())
            .unwrap_or("")
            .to_string();
        if label.is_empty() {
            continue;
        }
        let active_parameter = s
            .get("activeParameter")
            .and_then(|v| v.as_u64())
            .map(|n| n as usize)
            .or(top_active_param);
        let mut parameters: Vec<(usize, usize)> = Vec::new();
        if let Some(ps) = s.get("parameters").and_then(|p| p.as_array()) {
            for p in ps {
                if let Some((s_off, e_off)) = parse_param_label(p, &label) {
                    parameters.push((s_off, e_off));
                }
            }
        }
        sigs.push(crate::lsp::SignatureInfo {
            label,
            parameters,
            active_parameter,
        });
    }
    if sigs.is_empty() {
        return None;
    }
    let active_signature = active_signature.min(sigs.len().saturating_sub(1));
    Some(crate::lsp::SignatureHelp {
        signatures: sigs,
        active_signature,
    })
}

/// `parameters[i].label` is either `[start_char, end_char]` (preferred — we
/// advertised `labelOffsetSupport`) or a substring of the signature label
/// (legacy). Returns `(start, end)` char offsets into `label`, or `None`.
fn parse_param_label(p: &serde_json::Value, sig_label: &str) -> Option<(usize, usize)> {
    let lbl = p.get("label")?;
    if let Some(arr) = lbl.as_array()
        && arr.len() == 2
    {
        let s = arr[0].as_u64()? as usize;
        let e = arr[1].as_u64()? as usize;
        if e <= sig_label.chars().count() && s <= e {
            return Some((s, e));
        }
    }
    if let Some(sub) = lbl.as_str()
        && let Some(off) = sig_label.find(sub)
    {
        // byte offset to char offset
        let start_char = sig_label[..off].chars().count();
        let end_char = start_char + sub.chars().count();
        return Some((start_char, end_char));
    }
    None
}

fn parse_symbol_information(v: &serde_json::Value) -> Option<DocumentSymbol> {
    let name = v.get("name").and_then(|n| n.as_str())?;
    let kind = symbol_kind_label(v.get("kind").and_then(|k| k.as_u64()).unwrap_or(0));
    let r = v
        .get("location")
        .and_then(|l| l.get("range"))
        .and_then(|r| r.get("start"))?;
    let line = r.get("line")?.as_u64()? as u32;
    let character = r.get("character")?.as_u64()? as u32;
    Some(DocumentSymbol {
        name: name.to_string(),
        kind,
        line,
        character,
        depth: 0,
    })
}

/// LSP `SymbolKind` enum → a short display label.
fn symbol_kind_label(k: u64) -> &'static str {
    match k {
        1 => "file",
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "ctor",
        10 => "enum",
        11 => "interface",
        12 => "fn",
        13 => "var",
        14 => "const",
        15 => "string",
        16 => "num",
        17 => "bool",
        18 => "array",
        19 => "obj",
        20 => "key",
        21 => "null",
        22 => "variant",
        23 => "struct",
        24 => "event",
        25 => "op",
        26 => "type",
        _ => "?",
    }
}

/// Flatten a `Hover.contents` (string | MarkedString | MarkedString[] | MarkupContent).
fn hover_text(result: &serde_json::Value) -> Option<String> {
    let c = result.get("contents")?;
    fn one(v: &serde_json::Value) -> Option<String> {
        match v {
            serde_json::Value::String(s) => Some(s.clone()),
            serde_json::Value::Object(o) => {
                o.get("value").and_then(|v| v.as_str()).map(str::to_string)
            }
            _ => None,
        }
    }
    let text = match c {
        serde_json::Value::Array(a) => a.iter().filter_map(one).collect::<Vec<_>>().join("\n\n"),
        other => one(other)?,
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_semantic_tokens_decodes_delta_form() {
        // Synthetic legend mirrors LSP's standard order (truncated).
        let legend: Vec<String> = ["keyword", "function", "variable", "string"]
            .iter()
            .map(|&s| s.to_string())
            .collect();
        // Three tokens:
        //   (0, 0, 3, 0, 0) → keyword at line 0, col 0..3
        //   (0, 4, 5, 1, 0) → function at line 0, col 4..9 (delta_line=0 ⇒
        //                    delta_start is offset from prev start (0+4))
        //   (1, 2, 1, 2, 0) → variable at line 1, col 2..3 (delta_line=1 ⇒
        //                    delta_start is absolute)
        let reply = json!({
            "data": [
                0, 0, 3, 0, 0,
                0, 4, 5, 1, 0,
                1, 2, 1, 2, 0
            ]
        });
        let tokens = parse_semantic_tokens(&reply, &legend, &[]);
        assert_eq!(tokens.len(), 3);
        assert_eq!(tokens[0].line, 0);
        assert_eq!(tokens[0].start_char, 0);
        assert_eq!(tokens[0].length, 3);
        assert_eq!(tokens[0].type_name, "keyword");
        assert_eq!(tokens[1].line, 0);
        assert_eq!(tokens[1].start_char, 4);
        assert_eq!(tokens[1].type_name, "function");
        assert_eq!(tokens[2].line, 1);
        assert_eq!(tokens[2].start_char, 2);
        assert_eq!(tokens[2].type_name, "variable");
        // No modifier legend supplied ⇒ every token's `modifiers` is empty.
        assert!(tokens.iter().all(|t| t.modifiers.is_empty()));
    }

    #[test]
    fn parse_semantic_tokens_handles_empty_or_malformed() {
        let legend = vec!["keyword".to_string()];
        // No data array
        assert!(parse_semantic_tokens(&json!({}), &legend, &[]).is_empty());
        // Non-multiple-of-5
        assert!(parse_semantic_tokens(&json!({"data": [1, 2, 3]}), &legend, &[]).is_empty());
        // Empty legend ⇒ can't resolve type names ⇒ bail
        assert!(parse_semantic_tokens(&json!({"data": [0, 0, 1, 0, 0]}), &[], &[]).is_empty());
    }

    #[test]
    fn parse_semantic_tokens_drops_zero_length() {
        let legend = vec!["keyword".to_string()];
        let reply = json!({ "data": [0, 0, 0, 0, 0, 0, 5, 3, 0, 0] });
        let tokens = parse_semantic_tokens(&reply, &legend, &[]);
        assert_eq!(tokens.len(), 1);
        // First entry's zero length skipped; second advances by delta_start=5
        // (delta_line=0) from the prior start_char=0 → start at 5.
        assert_eq!(tokens[0].start_char, 5);
        assert_eq!(tokens[0].length, 3);
    }

    #[test]
    fn decode_modifier_bits_picks_set_bits() {
        let legend = vec![
            "declaration".to_string(),
            "definition".to_string(),
            "readonly".to_string(),
            "static".to_string(),
            "deprecated".to_string(),
            "abstract".to_string(),
        ];
        // bits 2 (readonly) + 4 (deprecated) set
        let mods = decode_modifier_bits(0b0001_0100, &legend);
        assert_eq!(mods, vec!["readonly".to_string(), "deprecated".to_string()]);
        // Zero bitmask ⇒ no modifiers.
        assert!(decode_modifier_bits(0, &legend).is_empty());
        // Empty legend ⇒ no modifiers regardless of bits.
        assert!(decode_modifier_bits(0xff, &[]).is_empty());
        // Bit beyond legend length ⇒ silently dropped.
        let mods = decode_modifier_bits(0b1000_0000, &legend);
        assert!(mods.is_empty());
    }

    #[test]
    fn parse_semantic_tokens_caps_handles_common_shapes() {
        // No provider ⇒ all flags off.
        let caps = parse_semantic_tokens_caps(None);
        assert!(!caps.supports_full);
        assert!(!caps.supports_delta);
        assert!(!caps.supports_range);
        // Modern rust-analyzer / tsserver / pyright shape: full + delta
        // + range.
        let provider = json!({
            "legend": { "tokenTypes": [], "tokenModifiers": [] },
            "requests": { "full": { "delta": true }, "range": true }
        });
        let caps = parse_semantic_tokens_caps(Some(&provider));
        assert!(caps.supports_full);
        assert!(caps.supports_delta);
        assert!(caps.supports_range);
        // Full only (no delta, no range).
        let provider = json!({
            "legend": { "tokenTypes": [], "tokenModifiers": [] },
            "requests": { "full": true }
        });
        let caps = parse_semantic_tokens_caps(Some(&provider));
        assert!(caps.supports_full);
        assert!(!caps.supports_delta);
        assert!(!caps.supports_range);
        // Range only — the rare server that omits full.
        let provider = json!({
            "legend": { "tokenTypes": [], "tokenModifiers": [] },
            "requests": { "range": true }
        });
        let caps = parse_semantic_tokens_caps(Some(&provider));
        assert!(!caps.supports_full);
        assert!(!caps.supports_delta);
        assert!(caps.supports_range);
        // Provider exists but `requests` is omitted (older LSP form) ⇒
        // assume full only.
        let provider = json!({
            "legend": { "tokenTypes": [], "tokenModifiers": [] }
        });
        let caps = parse_semantic_tokens_caps(Some(&provider));
        assert!(caps.supports_full);
        assert!(!caps.supports_delta);
        assert!(!caps.supports_range);
    }

    #[test]
    fn parse_semantic_tokens_resolves_modifiers_when_legend_supplied() {
        let legend = vec!["function".to_string()];
        let mod_legend = vec![
            "declaration".to_string(),
            "readonly".to_string(),
            "deprecated".to_string(),
        ];
        // One token, bits 0 + 2 set (declaration + deprecated).
        let reply = json!({ "data": [0, 0, 3, 0, 0b0000_0101] });
        let tokens = parse_semantic_tokens(&reply, &legend, &mod_legend);
        assert_eq!(tokens.len(), 1);
        assert_eq!(
            tokens[0].modifiers,
            vec!["declaration".to_string(), "deprecated".to_string()]
        );
    }

    #[test]
    fn semantic_token_edits_splice_in_descending_order() {
        // raw: 5 tokens worth, edits at positions 10 and 5; descending
        // order means the larger offset's splice doesn't shift the
        // smaller offset out from under us.
        let mut raw: Vec<u32> = (0..25).collect();
        let edits = vec![
            SemanticTokenEdit {
                start: 5,
                delete_count: 5,
                data: vec![99, 99, 99],
            },
            SemanticTokenEdit {
                start: 15,
                delete_count: 0,
                data: vec![55, 55],
            },
        ];
        assert!(apply_semantic_token_edits(&mut raw, edits));
        // After: 0..5, 99,99,99, 10..15, 55,55, 15..25 (with the original
        // 10..15 shrunk away since we deleted [5..10) and replaced with 3).
        assert_eq!(
            raw,
            vec![
                0, 1, 2, 3, 4, 99, 99, 99, 10, 11, 12, 13, 14, 55, 55, 15, 16, 17, 18, 19, 20, 21,
                22, 23, 24
            ]
        );
    }

    #[test]
    fn semantic_token_edits_reject_out_of_bounds() {
        let mut raw: Vec<u32> = vec![0, 1, 2, 3, 4];
        let edits = vec![SemanticTokenEdit {
            start: 10,
            delete_count: 0,
            data: vec![99],
        }];
        assert!(!apply_semantic_token_edits(&mut raw, edits));
    }

    #[test]
    fn parse_semantic_token_edits_picks_up_edits_array() {
        let reply = json!({
            "resultId": "abc",
            "edits": [
                { "start": 0, "deleteCount": 5, "data": [0, 0, 3, 0, 0] },
                { "start": 10, "deleteCount": 0 }
            ]
        });
        let edits = parse_semantic_token_edits(&reply).expect("edits");
        assert_eq!(edits.len(), 2);
        assert_eq!(edits[0].start, 0);
        assert_eq!(edits[0].delete_count, 5);
        assert_eq!(edits[0].data, vec![0, 0, 3, 0, 0]);
        assert_eq!(edits[1].start, 10);
        assert_eq!(edits[1].delete_count, 0);
        assert!(edits[1].data.is_empty());
    }

    #[test]
    fn parse_semantic_token_edits_none_when_data_form() {
        // `data` form ⇒ full replacement, not a delta — parser should
        // return None so the caller knows to take the full path.
        let reply = json!({ "resultId": "abc", "data": [0, 0, 1, 0, 0] });
        assert!(parse_semantic_token_edits(&reply).is_none());
    }

    #[test]
    fn delta_then_decode_round_trips_through_cache() {
        let legend: Vec<String> = ["keyword", "function", "variable"]
            .iter()
            .map(|&s| s.to_string())
            .collect();
        // Start with one token at (0,0,3,0,0) — `keyword` at line 0 col 0..3.
        let mut raw: Vec<u32> = vec![0, 0, 3, 0, 0];
        // Server says "splice in a new token at offset 5" (append).
        let edits = vec![SemanticTokenEdit {
            start: 5,
            delete_count: 0,
            data: vec![1, 2, 5, 1, 0],
        }];
        assert!(apply_semantic_token_edits(&mut raw, edits));
        let tokens = parse_semantic_tokens_from_raw(&raw, &legend, &[]);
        assert_eq!(tokens.len(), 2);
        assert_eq!(tokens[0].type_name, "keyword");
        assert_eq!(tokens[1].line, 1);
        assert_eq!(tokens[1].start_char, 2);
        assert_eq!(tokens[1].length, 5);
        assert_eq!(tokens[1].type_name, "function");
    }

    #[test]
    fn first_location_handles_shapes() {
        let loc = json!({"uri": "file:///x.rs", "range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 9}}});
        assert_eq!(
            first_location(&loc).unwrap(),
            (PathBuf::from("/x.rs"), 2, 4)
        );
        let arr = json!([loc]);
        assert_eq!(first_location(&arr).unwrap().1, 2);
        let link = json!([{"targetUri": "file:///y.rs", "targetSelectionRange": {"start": {"line": 7, "character": 0}, "end": {"line": 7, "character": 3}}}]);
        assert_eq!(
            first_location(&link).unwrap(),
            (PathBuf::from("/y.rs"), 7, 0)
        );
        assert!(first_location(&json!(null)).is_none());
    }

    #[test]
    fn parse_workspace_edit_handles_both_shapes() {
        let te = |l: u64, c0: u64, c1: u64, t: &str| json!({"range": {"start": {"line": l, "character": c0}, "end": {"line": l, "character": c1}}, "newText": t});
        // `changes` form
        let we = json!({"changes": {"file:///a.rs": [te(1, 4, 7, "bar")]}});
        let got = parse_workspace_edit(&we);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, PathBuf::from("/a.rs"));
        assert_eq!(got[0].1[0].1, "bar");
        // `documentChanges` form, with a file-op entry that must be skipped
        let we2 = json!({"documentChanges": [
            {"kind": "create", "uri": "file:///new.rs"},
            {"textDocument": {"uri": "file:///b.rs", "version": 3}, "edits": [te(0, 0, 3, "baz")]}
        ]});
        let got2 = parse_workspace_edit(&we2);
        assert_eq!(got2.len(), 1);
        assert_eq!(got2[0].0, PathBuf::from("/b.rs"));
        assert_eq!(got2[0].1[0].0.start.line, 0);
        // null ⇒ empty
        assert!(parse_workspace_edit(&json!(null)).is_empty());
    }

    #[test]
    fn parse_code_lenses_keeps_those_with_titles() {
        let reply = json!([
            {
                "range": { "start": {"line": 5, "character": 0}, "end": {"line": 5, "character": 0} },
                "command": { "title": "5 references", "command": "rust-analyzer.showReferences" }
            },
            {
                // No command yet — would need codeLens/resolve. Drop.
                "range": { "start": {"line": 10, "character": 0}, "end": {"line": 10, "character": 0} }
            }
        ]);
        let lenses = parse_code_lenses(&reply);
        assert_eq!(lenses.len(), 1);
        assert_eq!(lenses[0].line, 5);
        assert_eq!(lenses[0].title, "5 references");
    }

    #[test]
    fn parse_inlay_hints_handles_string_and_part_labels() {
        let reply = json!([
            {
                "position": { "line": 0, "character": 5 },
                "label": ": i32"
            },
            {
                "position": { "line": 1, "character": 10 },
                "label": [{"value": ": "}, {"value": "String"}]
            },
            {
                // No label ⇒ skip
                "position": { "line": 2, "character": 0 }
            }
        ]);
        let hints = parse_inlay_hints(&reply);
        assert_eq!(hints.len(), 2);
        assert_eq!(hints[0].label, ": i32");
        assert_eq!(hints[0].line, 0);
        assert_eq!(hints[0].character, 5);
        assert_eq!(hints[1].label, ": String");
        assert_eq!(hints[1].line, 1);
    }

    #[test]
    fn parse_completion_handles_list_and_array() {
        // CompletionList { items }
        let cl = json!({"isIncomplete": false, "items": [
            {"label": "push", "insertText": "push", "detail": "fn(&mut self, T)"},
            {"label": "println!", "insertText": "println!($0)", "insertTextFormat": 2},
            {"label": "len"}
        ]});
        let got = parse_completion(&cl);
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].0, "push");
        assert_eq!(got[0].1, "push");
        assert_eq!(got[0].2, Some("fn(&mut self, T)".to_string()));
        assert_eq!(got[0].3, None);
        // snippet ⇒ keep the LSP snippet body in `insert` (expanded on accept)
        assert_eq!(got[1].1, "println!($0)");
        assert!(got[1].5, "println! should be flagged is_snippet");
        assert!(!got[0].5, "push should not be flagged is_snippet");
        // no insertText ⇒ use the label
        assert_eq!(got[2].0, "len");
        assert_eq!(got[2].1, "len");
        assert_eq!(got[2].2, None);
        assert_eq!(got[2].3, None);
        // bare array form
        let arr = json!([{"label": "x", "textEdit": {"newText": "x_edited"}}]);
        assert_eq!(parse_completion(&arr)[0].1, "x_edited");
        assert!(parse_completion(&json!(null)).is_empty());
    }

    #[test]
    fn parse_code_actions_handles_both_shapes() {
        let we = json!({"changes": {"file:///x.rs": [
            {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}, "newText": "foo"}
        ]}});
        // (a) Nested CodeAction with edit + command + kind.
        // (b) CodeAction with only a command.
        // (c) Legacy Command literal.
        // (d) Disabled action — skipped.
        // (e) Resolve-only stub (no edit/command — kept with empty fields).
        let r = json!([
            {"title": "Quick fix", "kind": "quickfix", "edit": we, "command": {"title": "c", "command": "do.fix", "arguments": [1, 2]}},
            {"title": "Only cmd",  "command": {"title": "c", "command": "do.run"}},
            {"title": "Legacy",    "command": "old.cmd",  "arguments": ["a"]},
            {"title": "Disabled",  "disabled": {"reason": "nope"}, "command": {"command": "x"}},
            {"title": "Stub"}
        ]);
        let got = parse_code_actions(&r);
        assert_eq!(got.len(), 4);
        // (a)
        assert_eq!(got[0].title, "Quick fix");
        assert_eq!(got[0].kind.as_deref(), Some("quickfix"));
        assert!(got[0].edit.is_some());
        assert_eq!(got[0].command.as_ref().unwrap().command, "do.fix");
        assert_eq!(got[0].command.as_ref().unwrap().arguments.len(), 2);
        // (b)
        assert!(got[1].edit.is_none());
        assert_eq!(got[1].command.as_ref().unwrap().command, "do.run");
        // (c)
        assert_eq!(got[2].command.as_ref().unwrap().command, "old.cmd");
        assert_eq!(got[2].command.as_ref().unwrap().arguments[0], json!("a"));
        // (d) skipped, (e) stub kept
        assert_eq!(got[3].title, "Stub");
        assert!(got[3].edit.is_none() && got[3].command.is_none());
        // null/non-array ⇒ empty
        assert!(parse_code_actions(&json!(null)).is_empty());
        assert!(parse_code_actions(&json!({})).is_empty());
    }

    #[test]
    fn parse_document_symbols_handles_both_shapes() {
        // Hierarchical DocumentSymbol[] with nested children.
        let r = json!([
            {
                "name": "App", "kind": 23,
                "range": {"start": {"line": 10, "character": 0}, "end": {"line": 100, "character": 0}},
                "selectionRange": {"start": {"line": 10, "character": 7}, "end": {"line": 10, "character": 10}},
                "children": [
                    {
                        "name": "new", "kind": 12,
                        "range": {"start": {"line": 15, "character": 4}, "end": {"line": 20, "character": 5}},
                        "selectionRange": {"start": {"line": 15, "character": 11}, "end": {"line": 15, "character": 14}}
                    }
                ]
            }
        ]);
        let got = parse_document_symbols(&r);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].name, "App");
        assert_eq!(got[0].kind, "struct");
        assert_eq!(got[0].depth, 0);
        assert_eq!((got[0].line, got[0].character), (10, 7));
        assert_eq!(got[1].name, "new");
        assert_eq!(got[1].kind, "fn");
        assert_eq!(got[1].depth, 1);
        assert_eq!((got[1].line, got[1].character), (15, 11));

        // Legacy flat SymbolInformation[].
        let r2 = json!([
            {"name": "main", "kind": 12,
             "location": {"uri": "file:///x.rs", "range": {"start": {"line": 0, "character": 3}, "end": {"line": 0, "character": 7}}}}
        ]);
        let got2 = parse_document_symbols(&r2);
        assert_eq!(got2.len(), 1);
        assert_eq!(got2[0].name, "main");
        assert_eq!(got2[0].kind, "fn");
        assert_eq!((got2[0].line, got2[0].character), (0, 3));

        // null / empty.
        assert!(parse_document_symbols(&json!(null)).is_empty());
        assert!(parse_document_symbols(&json!([])).is_empty());
    }

    #[test]
    fn parse_workspace_symbols_handles_both_shapes() {
        // Legacy SymbolInformation[] (with full location).
        let r = json!([
            {"name": "foo", "kind": 12, // 12 == function
             "containerName": "mod_a",
             "location": {
                "uri": "file:///proj/src/lib.rs",
                "range": {"start": {"line": 10, "character": 4},
                          "end":   {"line": 10, "character": 7}}
             }},
            // Newer WorkspaceSymbol — uri at the top level, range omitted.
            {"name": "Bar", "kind": 5, "location": {"uri": "file:///proj/src/types.rs"}}
        ]);
        let got = parse_workspace_symbols(&r);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].name, "foo");
        assert_eq!(got[0].kind, "fn");
        assert_eq!(got[0].line, 10);
        assert_eq!(got[0].character, 4);
        assert_eq!(got[0].container.as_deref(), Some("mod_a"));
        assert_eq!(got[1].name, "Bar");
        assert_eq!(got[1].kind, "class");
        assert_eq!((got[1].line, got[1].character), (0, 0));
        assert!(got[1].container.is_none());

        assert!(parse_workspace_symbols(&json!(null)).is_empty());
        assert!(parse_workspace_symbols(&json!([])).is_empty());
    }

    #[test]
    fn hover_text_flattens() {
        assert_eq!(
            hover_text(&json!({"contents": "hi"})).as_deref(),
            Some("hi")
        );
        assert_eq!(
            hover_text(&json!({"contents": {"kind": "markdown", "value": "**x**"}})).as_deref(),
            Some("**x**")
        );
        assert_eq!(
            hover_text(&json!({"contents": ["a", {"value": "b"}]})).as_deref(),
            Some("a\n\nb")
        );
        assert!(hover_text(&json!({"contents": ""})).is_none());
    }
}
