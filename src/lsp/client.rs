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
/// knows what shape to expect) + an optional path (so methods whose reply
/// doesn't include the file — like `textDocument/formatting` — can be
/// routed back to the right buffer).
type Pending = Arc<Mutex<HashMap<i64, (String, Option<PathBuf>)>>>;
type Sink = Arc<Mutex<ChildStdin>>;

pub struct LspClient {
    name: String,
    child: Child,
    stdin: Sink,
    reader: Option<JoinHandle<()>>,
    next_id: i64,
    pending: Pending,
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

        let r_pending = Arc::clone(&pending);
        let r_stdin = Arc::clone(&stdin);
        let reader = std::thread::Builder::new()
            .name(format!("mnml-lsp-{}", sc.name))
            .spawn(move || reader_loop(stdout, tx, r_pending, r_stdin))
            .map_err(|e| format!("reader thread: {e}"))?;

        let mut c = LspClient {
            name: sc.name.clone(),
            child,
            stdin,
            reader: Some(reader),
            next_id: 1,
            pending,
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
                    "textDocument": {
                        "synchronization": { "didSave": true },
                        "publishDiagnostics": {},
                        "hover": { "contentFormat": ["markdown", "plaintext"] },
                        "definition": { "linkSupport": true },
                        "references": {},
                        "rename": {},
                        "completion": { "completionItem": { "snippetSupport": false } },
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
                            }
                        },
                        "inlayHint": {
                            "dynamicRegistration": false,
                            "resolveSupport": { "properties": ["label.tooltip", "label.location"] }
                        },
                        "codeLens": {
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
        let id = self.next_id;
        self.next_id += 1;
        if let Ok(mut p) = self.pending.lock() {
            p.insert(id, (method.to_string(), path.map(|p| p.to_path_buf())));
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
) {
    let mut r = BufReader::new(stdout);
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
        handle_message(&v, &tx, &pending, &stdin);
    }
}

fn handle_message(
    v: &serde_json::Value,
    tx: &std::sync::mpsc::Sender<LspEvent>,
    pending: &Pending,
    stdin: &Sink,
) {
    // A server→client request (has both `id` and `method`): reply `null` so a
    // strict server (registerCapability / configuration / progress create) moves on.
    if let (Some(id), Some(_method)) = (v.get("id"), v.get("method").and_then(|m| m.as_str())) {
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
        return;
    }

    // A response to one of our requests.
    if let Some(id) = v.get("id").and_then(|i| i.as_i64()) {
        let pend = pending.lock().ok().and_then(|mut p| p.remove(&id));
        let Some((method, req_path)) = pend else {
            return;
        };
        let Some(result) = v.get("result") else {
            return;
        }; // error / null → nothing to do
        match method.as_str() {
            "textDocument/definition"
            | "textDocument/declaration"
            | "textDocument/typeDefinition" => {
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
            "textDocument/formatting" => {
                let edits = parse_text_edits(result);
                if let (false, Some(path)) = (edits.is_empty(), req_path) {
                    let _ = tx.send(LspEvent::Formatting { path, edits });
                }
            }
            "textDocument/codeAction" => {
                let actions = parse_code_actions(result);
                let _ = tx.send(LspEvent::CodeAction(actions));
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
            _ => {}
        }
    }
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
/// `CompletionList { items }`) into `(label, insert_text, detail)` per item.
/// `insertText` (then `textEdit.newText`, then `label`) supplies the text to
/// insert; snippet items (`insertTextFormat == 2`) fall back to the label since
/// we don't expand placeholders.
fn parse_completion(result: &serde_json::Value) -> Vec<(String, String, Option<String>)> {
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
        let insert = if is_snippet {
            label.to_string()
        } else {
            it.get("insertText")
                .and_then(|t| t.as_str())
                .or_else(|| {
                    it.get("textEdit")
                        .and_then(|e| e.get("newText"))
                        .and_then(|t| t.as_str())
                })
                .unwrap_or(label)
                .to_string()
        };
        let detail = it
            .get("detail")
            .and_then(|d| d.as_str())
            .map(str::to_string);
        out.push((label.to_string(), insert, detail));
    }
    out
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
        });
    }
    out
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
        assert_eq!(
            got[0],
            (
                "push".into(),
                "push".into(),
                Some("fn(&mut self, T)".into())
            )
        );
        // snippet ⇒ fall back to the label, not the placeholder text
        assert_eq!(got[1].1, "println!");
        // no insertText ⇒ use the label
        assert_eq!(got[2], ("len".into(), "len".into(), None));
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
