//! One DAP adapter subprocess: Content-Length-framed JSON over stdio.
//! Mirrors `lsp::client` — same wire format, different message shapes
//! (DAP has `request` / `response` / `event` types, all with a numeric
//! `seq`).
//!
//! The reader thread pumps incoming messages → `DapEvent`s on the
//! caller's channel. Outbound requests are sent through a shared
//! `Mutex<ChildStdin>`. The App side never blocks on a reply — replies
//! that drive UI come back as events. The reader tracks in-flight
//! requests by `seq` so it knows which response is for what (e.g. a
//! `stackTrace` reply gets translated to a `DapEvent::StackTrace`).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde_json::{Value, json};

use super::{AdapterConfig, DapEvent, StackFrame};

type Sink = Arc<Mutex<ChildStdin>>;
/// `seq` → (command, optional metadata).
/// `command` lets the reader pick the right reply parser.
type Pending = Arc<Mutex<HashMap<i64, String>>>;

pub struct DapClient {
    pub adapter_name: String,
    child: Child,
    stdin: Sink,
    reader: Option<JoinHandle<()>>,
    next_seq: i64,
    pending: Pending,
}

impl DapClient {
    /// Spawn the adapter + start the reader thread. Doesn't send any
    /// requests yet — call `initialize` / `launch` / `set_breakpoints` /
    /// `configuration_done` on the returned client in order.
    pub fn spawn(
        cfg: &AdapterConfig,
        workspace: &std::path::Path,
        tx: Sender<DapEvent>,
    ) -> Result<Self, String> {
        let mut child = Command::new(&cfg.cmd)
            .args(&cfg.args)
            .current_dir(workspace)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("dap spawn {}: {e}", cfg.cmd))?;
        let stdin = Arc::new(Mutex::new(child.stdin.take().ok_or("no stdin")?));
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));

        let r_pending = Arc::clone(&pending);
        let adapter_name = cfg.cmd.clone();
        let r_adapter_name = adapter_name.clone();
        let reader = std::thread::Builder::new()
            .name(format!("mnml-dap-{adapter_name}"))
            .spawn(move || reader_loop(stdout, tx, r_pending, r_adapter_name))
            .map_err(|e| format!("dap reader thread: {e}"))?;

        Ok(DapClient {
            adapter_name,
            child,
            stdin,
            reader: Some(reader),
            next_seq: 1,
            pending,
        })
    }

    /// Send `initialize`. The adapter replies with `capabilities` (we
    /// don't currently care which ones); landing of the
    /// `initialized` *event* is what we wait for.
    pub fn initialize(&mut self) -> Result<(), String> {
        let body = json!({
            "clientID": "mnml",
            "clientName": "mnml",
            "adapterID": self.adapter_name,
            "locale": "en-US",
            "linesStartAt1": true,
            "columnsStartAt1": true,
            "pathFormat": "path",
            "supportsRunInTerminalRequest": false,
            "supportsVariableType": true,
            "supportsVariablePaging": false,
        });
        self.send_request("initialize", body)
    }

    /// `launch` (or `attach` — caller chooses). `launch_body` is the
    /// already-substituted `launch.*` JSON from config.
    pub fn launch(&mut self, launch_body: Value) -> Result<(), String> {
        // The body is a single JSON object; we wrap nothing, just pass
        // it through. Adapters key on `request: "launch"` or
        // `request: "attach"` inside the object.
        let cmd = launch_body
            .get("request")
            .and_then(|v| v.as_str())
            .unwrap_or("launch")
            .to_string();
        self.send_request(&cmd, launch_body)
    }

    /// `setBreakpoints` for a single source file. Lines are 0-based on
    /// our side (matching `Buffer.breakpoints`); DAP wants 1-based with
    /// `linesStartAt1: true`, so we add 1 here.
    pub fn set_breakpoints(
        &mut self,
        source: &std::path::Path,
        lines0: &[u32],
    ) -> Result<(), String> {
        let breakpoints: Vec<Value> = lines0.iter().map(|&l| json!({ "line": l + 1 })).collect();
        let body = json!({
            "source": { "path": source.to_string_lossy(), "name": source.file_name().map(|n| n.to_string_lossy()) },
            "breakpoints": breakpoints,
            "lines": lines0.iter().map(|&l| l + 1).collect::<Vec<_>>(),
            "sourceModified": false,
        });
        self.send_request("setBreakpoints", body)
    }

    /// `configurationDone` — tell the adapter we've set our breakpoints
    /// and are ready for the program to actually start running. Many
    /// adapters wait for this before resuming execution.
    pub fn configuration_done(&mut self) -> Result<(), String> {
        self.send_request("configurationDone", json!({}))
    }

    /// `continue` — resume from a stopped state.
    pub fn cont(&mut self, thread_id: i64) -> Result<(), String> {
        self.send_request("continue", json!({ "threadId": thread_id }))
    }

    /// `next` — step over.
    pub fn next(&mut self, thread_id: i64) -> Result<(), String> {
        self.send_request("next", json!({ "threadId": thread_id }))
    }

    /// `stepIn` — step into a call.
    pub fn step_in(&mut self, thread_id: i64) -> Result<(), String> {
        self.send_request("stepIn", json!({ "threadId": thread_id }))
    }

    /// `stepOut` — step out of the current frame.
    pub fn step_out(&mut self, thread_id: i64) -> Result<(), String> {
        self.send_request("stepOut", json!({ "threadId": thread_id }))
    }

    /// `pause` — suspend a running thread.
    pub fn pause(&mut self, thread_id: i64) -> Result<(), String> {
        self.send_request("pause", json!({ "threadId": thread_id }))
    }

    /// `stackTrace` — get the current call stack for a thread. Reply
    /// lands as `DapEvent::StackTrace`.
    pub fn stack_trace(&mut self, thread_id: i64) -> Result<(), String> {
        self.send_request(
            "stackTrace",
            json!({ "threadId": thread_id, "startFrame": 0, "levels": 20 }),
        )
    }

    /// `terminate` — clean shutdown of the debuggee.
    pub fn terminate(&mut self) -> Result<(), String> {
        self.send_request("terminate", json!({}))
    }

    /// `disconnect` — sever the session.
    pub fn disconnect(&mut self) -> Result<(), String> {
        self.send_request("disconnect", json!({ "terminateDebuggee": true }))
    }

    fn send_request(&mut self, command: &str, arguments: Value) -> Result<(), String> {
        let seq = self.next_seq;
        self.next_seq += 1;
        let msg = json!({
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        });
        self.pending
            .lock()
            .unwrap()
            .insert(seq, command.to_string());
        let mut w = self.stdin.lock().unwrap();
        write_message(&mut *w, &msg).map_err(|e| format!("dap write: {e}"))
    }
}

impl Drop for DapClient {
    fn drop(&mut self) {
        // Best-effort: tell the adapter to disconnect, kill the
        // subprocess, then drain the reader thread.
        let _ = self.disconnect();
        let _ = self.child.kill();
        if let Some(j) = self.reader.take() {
            let _ = j.join();
        }
    }
}

fn write_message(w: &mut impl Write, msg: &Value) -> std::io::Result<()> {
    let body = serde_json::to_vec(msg).unwrap_or_default();
    write!(w, "Content-Length: {}\r\n\r\n", body.len())?;
    w.write_all(&body)?;
    w.flush()
}

fn reader_loop(stdout: impl Read, tx: Sender<DapEvent>, pending: Pending, adapter_name: String) {
    let mut r = BufReader::new(stdout);
    loop {
        // Read headers until a blank line; only `Content-Length`
        // matters in practice.
        let mut len: Option<usize> = None;
        loop {
            let mut line = String::new();
            match r.read_line(&mut line) {
                Ok(0) => {
                    // EOF — adapter died.
                    let _ = tx.send(DapEvent::Terminated);
                    return;
                }
                Ok(_) => {}
                Err(_) => {
                    let _ = tx.send(DapEvent::Terminated);
                    return;
                }
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
            let _ = tx.send(DapEvent::Terminated);
            return;
        }
        let Ok(v) = serde_json::from_slice::<Value>(&buf) else {
            continue;
        };
        dispatch_message(&v, &tx, &pending, &adapter_name);
    }
}

fn dispatch_message(v: &Value, tx: &Sender<DapEvent>, pending: &Pending, _adapter: &str) {
    let kind = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
    match kind {
        "event" => {
            let name = v.get("event").and_then(|e| e.as_str()).unwrap_or("");
            let body = v.get("body").cloned().unwrap_or(json!({}));
            match name {
                "initialized" => {
                    let _ = tx.send(DapEvent::Initialized);
                }
                "stopped" => {
                    let reason = body
                        .get("reason")
                        .and_then(|r| r.as_str())
                        .unwrap_or("unknown")
                        .to_string();
                    let thread_id = body.get("threadId").and_then(|t| t.as_i64()).unwrap_or(0);
                    let description = body
                        .get("description")
                        .and_then(|d| d.as_str())
                        .map(|s| s.to_string());
                    let _ = tx.send(DapEvent::Stopped {
                        reason,
                        thread_id,
                        description,
                    });
                }
                "continued" => {
                    let _ = tx.send(DapEvent::Continued);
                }
                "output" => {
                    let category = body
                        .get("category")
                        .and_then(|c| c.as_str())
                        .unwrap_or("console")
                        .to_string();
                    let text = body
                        .get("output")
                        .and_then(|o| o.as_str())
                        .unwrap_or("")
                        .to_string();
                    if !text.is_empty() {
                        let _ = tx.send(DapEvent::Output { category, text });
                    }
                }
                "terminated" => {
                    let _ = tx.send(DapEvent::Terminated);
                }
                "exited" => {
                    let exit_code = body.get("exitCode").and_then(|c| c.as_i64()).unwrap_or(0);
                    let _ = tx.send(DapEvent::Exited { exit_code });
                }
                _ => {} // thread / breakpoint / process / module / loadedSource ignored for MVP
            }
        }
        "response" => {
            let success = v.get("success").and_then(|s| s.as_bool()).unwrap_or(false);
            let request_seq = v.get("request_seq").and_then(|s| s.as_i64()).unwrap_or(-1);
            let command = pending.lock().unwrap().remove(&request_seq);
            if !success {
                let msg = v
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("unknown error");
                let cmd = command.as_deref().unwrap_or("?");
                let _ = tx.send(DapEvent::Failed(format!("dap {cmd}: {msg}")));
                return;
            }
            let Some(command) = command else { return };
            match command.as_str() {
                "configurationDone" | "launch" | "attach" => {
                    let _ = tx.send(DapEvent::Running);
                }
                "stackTrace" => {
                    if let Some(body) = v.get("body")
                        && let Some(frames) = body.get("stackFrames").and_then(|f| f.as_array())
                    {
                        let parsed: Vec<StackFrame> =
                            frames.iter().filter_map(parse_stack_frame).collect();
                        // We don't know the thread id from the response;
                        // the App tracks the current thread separately
                        // and re-attaches.
                        let _ = tx.send(DapEvent::StackTrace {
                            thread_id: 0,
                            frames: parsed,
                        });
                    }
                }
                _ => {}
            }
        }
        "request" => {
            // Reverse requests (e.g. `runInTerminal`). We declined the
            // capability in `initialize`, so we shouldn't see any —
            // but if one slips through, just ignore it. A polite
            // implementation would reply with `success: false`.
        }
        _ => {}
    }
}

fn parse_stack_frame(v: &Value) -> Option<StackFrame> {
    let id = v.get("id").and_then(|i| i.as_i64())?;
    let name = v.get("name").and_then(|n| n.as_str())?.to_string();
    let line = v.get("line").and_then(|l| l.as_u64()).unwrap_or(0) as u32;
    let column = v.get("column").and_then(|c| c.as_u64()).unwrap_or(0) as u32;
    let source = v
        .get("source")
        .and_then(|s| s.get("path"))
        .and_then(|p| p.as_str())
        .map(PathBuf::from);
    Some(StackFrame {
        id,
        name,
        source,
        line,
        column,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_stack_frame_extracts_path_and_line() {
        let v = json!({
            "id": 7,
            "name": "main",
            "line": 42,
            "column": 5,
            "source": { "path": "/repo/main.py", "name": "main.py" }
        });
        let f = parse_stack_frame(&v).unwrap();
        assert_eq!(f.id, 7);
        assert_eq!(f.line, 42);
        assert_eq!(
            f.source.as_deref(),
            Some(std::path::Path::new("/repo/main.py"))
        );
    }

    #[test]
    fn parse_stack_frame_handles_missing_source() {
        // Some adapters omit `source` for synthetic frames (e.g. lib
        // code without a known file).
        let v = json!({
            "id": 1,
            "name": "<builtin>",
            "line": 0,
        });
        let f = parse_stack_frame(&v).unwrap();
        assert!(f.source.is_none());
    }
}
