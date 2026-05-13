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

use super::{LspEvent, Pos, Range, ServerConfig, parse_diagnostic, path_to_uri, uri_to_path};

type Pending = Arc<Mutex<HashMap<i64, String>>>;
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
                        "completion": { "completionItem": { "snippetSupport": false } }
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

    fn request(&mut self, method: &str, params: serde_json::Value) {
        let id = self.next_id;
        self.next_id += 1;
        if let Ok(mut p) = self.pending.lock() {
            p.insert(id, method.to_string());
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
        let method = pending.lock().ok().and_then(|mut p| p.remove(&id));
        let Some(method) = method else { return };
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
