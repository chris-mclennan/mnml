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

use super::{AdapterConfig, DapEvent, ExceptionFilter, Scope, StackFrame, ThreadInfo, Variable};

type Sink = Arc<Mutex<ChildStdin>>;
/// One in-flight request — `command` tells the reader which parser to
/// run; `aux` echoes back the input identifier (variables_ref for
/// `variables`, frame_id for `scopes`, etc.) so the App can route the
/// reply to the right slot without a separate correlation pass.
/// `aux_str` is the string-shaped equivalent (the original expression
/// for `evaluate`).
#[derive(Debug, Clone)]
pub(crate) struct PendingReq {
    pub command: String,
    pub aux: Option<i64>,
    pub aux_str: Option<String>,
}
type Pending = Arc<Mutex<HashMap<i64, PendingReq>>>;

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

    /// Like [`set_breakpoints`] but attaches a per-line `condition`
    /// expression (DAP's conditional-breakpoint feature) and an
    /// optional per-line `hit_condition` (count-based stopping —
    /// strings like `">= 5"` or `"% 10"`; the adapter interprets).
    /// Lines absent from either map get the plain-breakpoint shape.
    /// Requires `supportsConditionalBreakpoints` /
    /// `supportsHitConditionalBreakpoints` advertised by the adapter;
    /// fields are silently ignored otherwise.
    pub fn set_breakpoints_with_conditions(
        &mut self,
        source: &std::path::Path,
        lines0: &[u32],
        conditions: &std::collections::HashMap<u32, String>,
        hit_conditions: &std::collections::HashMap<u32, String>,
    ) -> Result<(), String> {
        let breakpoints: Vec<Value> = lines0
            .iter()
            .map(|&l| {
                let mut bp = json!({ "line": l + 1 });
                if let Some(cond) = conditions.get(&l) {
                    bp["condition"] = json!(cond);
                }
                if let Some(hit) = hit_conditions.get(&l) {
                    bp["hitCondition"] = json!(hit);
                }
                bp
            })
            .collect();
        let body = json!({
            "source": {
                "path": source.to_string_lossy(),
                "name": source.file_name().map(|n| n.to_string_lossy()),
            },
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

    /// `scopes` — list the variable scopes for a stack frame
    /// (typically "Locals" / "Globals" / "Arguments"). Each scope
    /// carries a `variablesReference` the App follows up with via
    /// [`variables`].
    pub fn scopes(&mut self, frame_id: i64) -> Result<(), String> {
        self.send_request_with_aux("scopes", json!({ "frameId": frame_id }), Some(frame_id))
    }

    /// `variables` — fetch the children of a `variablesReference`. Used
    /// for the top-level vars in a scope AND for lazy-expanding a
    /// composite variable (struct / array / object) when the user
    /// drills in. The reply echoes nothing about which ref it was for
    /// — we stash the ref in `aux` so the reader can attach it to the
    /// `DapEvent::Variables` payload.
    pub fn variables(&mut self, variables_ref: i64) -> Result<(), String> {
        self.send_request_with_aux(
            "variables",
            json!({ "variablesReference": variables_ref }),
            Some(variables_ref),
        )
    }

    /// `threads` — fetch the active thread list. Reply lands as
    /// `DapEvent::Threads`. The App refreshes this on `Stopped` so
    /// the multi-thread picker always has a current list.
    pub fn threads(&mut self) -> Result<(), String> {
        self.send_request("threads", json!({}))
    }

    /// `setVariable` — replace `name`'s value inside the composite
    /// referenced by `parent_ref` (a scope's or struct's
    /// `variablesReference`). The reply lands as
    /// `DapEvent::SetVariableDone` with the adapter's formatted
    /// post-set value (which may differ from `value` — e.g. the
    /// adapter strips quotes from a typed string literal). Errors
    /// (invalid value, immutable field) flow through the generic
    /// `DapEvent::Failed` path.
    ///
    /// `aux` carries `parent_ref` and `aux_str` carries `name` so
    /// the reader can route the reply with full context — the
    /// response body doesn't include either field on its own.
    pub fn set_variable(&mut self, parent_ref: i64, name: &str, value: &str) -> Result<(), String> {
        self.send_request_full(
            "setVariable",
            json!({
                "variablesReference": parent_ref,
                "name": name,
                "value": value,
            }),
            Some(parent_ref),
            Some(name.to_string()),
        )
    }

    /// `evaluate` — evaluate `expression` in the context of `frame_id`
    /// (or globally when `frame_id` is `None`). `context` is one of
    /// "watch" / "repl" / "hover" — the adapter may format the result
    /// differently. The reply lands as `DapEvent::Evaluate` with the
    /// expression echoed back via `aux_str` so the App can dedupe
    /// against `App.dap_watches`.
    pub fn evaluate(
        &mut self,
        expression: &str,
        frame_id: Option<i64>,
        context: &str,
    ) -> Result<(), String> {
        let mut body = json!({
            "expression": expression,
            "context": context,
        });
        if let Some(fid) = frame_id {
            body["frameId"] = json!(fid);
        }
        self.send_request_with_aux_str("evaluate", body, Some(expression.to_string()))
    }

    /// `setExceptionBreakpoints` — tell the adapter which exception
    /// filters should stop the debuggee (e.g. `["raised", "uncaught"]`
    /// for debugpy). Filter IDs come from the `initialize` reply's
    /// `exceptionBreakpointFilters`. Empty list ⇒ no exceptions break;
    /// passing every filter ⇒ every exception breaks.
    pub fn set_exception_breakpoints(&mut self, filter_ids: &[String]) -> Result<(), String> {
        self.send_request("setExceptionBreakpoints", json!({ "filters": filter_ids }))
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
        self.send_request_full(command, arguments, None, None)
    }

    fn send_request_with_aux(
        &mut self,
        command: &str,
        arguments: Value,
        aux: Option<i64>,
    ) -> Result<(), String> {
        self.send_request_full(command, arguments, aux, None)
    }

    fn send_request_with_aux_str(
        &mut self,
        command: &str,
        arguments: Value,
        aux_str: Option<String>,
    ) -> Result<(), String> {
        self.send_request_full(command, arguments, None, aux_str)
    }

    fn send_request_full(
        &mut self,
        command: &str,
        arguments: Value,
        aux: Option<i64>,
        aux_str: Option<String>,
    ) -> Result<(), String> {
        let seq = self.next_seq;
        self.next_seq += 1;
        let msg = json!({
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        });
        self.pending.lock().unwrap().insert(
            seq,
            PendingReq {
                command: command.to_string(),
                aux,
                aux_str,
            },
        );
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
            let req = pending.lock().unwrap().remove(&request_seq);
            if !success {
                let msg = v
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("unknown error");
                // Watch evaluations frequently fail (name-not-defined,
                // out-of-scope, etc.) — route those to the watch row's
                // err slot instead of a noisy toast. Take ownership of
                // `req` here so the move-out doesn't conflict with the
                // borrow used in the fall-through branch.
                if let Some(req) = req {
                    if req.command == "evaluate"
                        && let Some(expr) = req.aux_str
                    {
                        let _ = tx.send(DapEvent::Evaluate {
                            expression: expr,
                            value: String::new(),
                            ty: None,
                            err: Some(msg.to_string()),
                            variables_ref: 0,
                        });
                    } else {
                        let _ = tx.send(DapEvent::Failed(format!("dap {}: {msg}", req.command)));
                    }
                } else {
                    let _ = tx.send(DapEvent::Failed(format!("dap ?: {msg}")));
                }
                return;
            }
            let Some(req) = req else { return };
            match req.command.as_str() {
                "configurationDone" | "launch" | "attach" => {
                    let _ = tx.send(DapEvent::Running);
                }
                "initialize" => {
                    // Capture the adapter's advertised exception
                    // filters so `dap.exceptions` can show a picker.
                    // Other capabilities aren't routed back — we
                    // assume modern defaults (supportsConditional,
                    // supportsEvaluateForHovers, etc.).
                    if let Some(body) = v.get("body")
                        && let Some(arr) = body
                            .get("exceptionBreakpointFilters")
                            .and_then(|x| x.as_array())
                    {
                        let parsed: Vec<ExceptionFilter> =
                            arr.iter().filter_map(parse_exception_filter).collect();
                        let _ = tx.send(DapEvent::InitializeCaps {
                            exception_filters: parsed,
                        });
                    }
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
                "scopes" => {
                    if let Some(body) = v.get("body")
                        && let Some(scopes) = body.get("scopes").and_then(|s| s.as_array())
                    {
                        let parsed: Vec<Scope> = scopes.iter().filter_map(parse_scope).collect();
                        let _ = tx.send(DapEvent::Scopes {
                            frame_id: req.aux.unwrap_or(0),
                            scopes: parsed,
                        });
                    }
                }
                "variables" => {
                    if let Some(body) = v.get("body")
                        && let Some(vars) = body.get("variables").and_then(|x| x.as_array())
                    {
                        let parsed: Vec<Variable> =
                            vars.iter().filter_map(parse_variable).collect();
                        let _ = tx.send(DapEvent::Variables {
                            variables_ref: req.aux.unwrap_or(0),
                            variables: parsed,
                        });
                    }
                }
                "threads" => {
                    if let Some(body) = v.get("body")
                        && let Some(ts) = body.get("threads").and_then(|t| t.as_array())
                    {
                        let parsed: Vec<ThreadInfo> =
                            ts.iter().filter_map(parse_thread_info).collect();
                        let _ = tx.send(DapEvent::Threads(parsed));
                    }
                }
                "setVariable" => {
                    if let (Some(parent_ref), Some(name), Some(body)) =
                        (req.aux, req.aux_str, v.get("body"))
                    {
                        let value = body
                            .get("value")
                            .and_then(|r| r.as_str())
                            .unwrap_or("")
                            .to_string();
                        let ty = body
                            .get("type")
                            .and_then(|t| t.as_str())
                            .map(|s| s.to_string());
                        let variables_ref = body
                            .get("variablesReference")
                            .and_then(|r| r.as_i64())
                            .unwrap_or(0);
                        let _ = tx.send(DapEvent::SetVariableDone {
                            parent_ref,
                            name,
                            value,
                            ty,
                            variables_ref,
                        });
                    }
                }
                "evaluate" => {
                    if let Some(expr) = req.aux_str
                        && let Some(body) = v.get("body")
                    {
                        let result = body
                            .get("result")
                            .and_then(|r| r.as_str())
                            .unwrap_or("")
                            .to_string();
                        let ty = body
                            .get("type")
                            .and_then(|t| t.as_str())
                            .map(|s| s.to_string());
                        let variables_ref = body
                            .get("variablesReference")
                            .and_then(|r| r.as_i64())
                            .unwrap_or(0);
                        let _ = tx.send(DapEvent::Evaluate {
                            expression: expr,
                            value: result,
                            ty,
                            err: None,
                            variables_ref,
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

fn parse_exception_filter(v: &Value) -> Option<ExceptionFilter> {
    let filter = v.get("filter").and_then(|f| f.as_str())?.to_string();
    let label = v
        .get("label")
        .and_then(|l| l.as_str())
        .unwrap_or(&filter)
        .to_string();
    let default = v.get("default").and_then(|d| d.as_bool()).unwrap_or(false);
    Some(ExceptionFilter {
        filter,
        label,
        default,
    })
}

fn parse_thread_info(v: &Value) -> Option<ThreadInfo> {
    let id = v.get("id").and_then(|i| i.as_i64())?;
    let name = v
        .get("name")
        .and_then(|n| n.as_str())
        .unwrap_or("(unnamed)")
        .to_string();
    Some(ThreadInfo { id, name })
}

fn parse_scope(v: &Value) -> Option<Scope> {
    let name = v.get("name").and_then(|n| n.as_str())?.to_string();
    let variables_reference = v
        .get("variablesReference")
        .and_then(|r| r.as_i64())
        .unwrap_or(0);
    let expensive = v
        .get("expensive")
        .and_then(|e| e.as_bool())
        .unwrap_or(false);
    Some(Scope {
        name,
        variables_reference,
        expensive,
    })
}

fn parse_variable(v: &Value) -> Option<Variable> {
    let name = v.get("name").and_then(|n| n.as_str())?.to_string();
    let value = v
        .get("value")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let ty = v
        .get("type")
        .and_then(|t| t.as_str())
        .map(|s| s.to_string());
    let variables_reference = v
        .get("variablesReference")
        .and_then(|r| r.as_i64())
        .unwrap_or(0);
    Some(Variable {
        name,
        value,
        ty,
        variables_reference,
    })
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

    #[test]
    fn parse_scope_extracts_ref_and_expensive() {
        let v = json!({
            "name": "Globals",
            "variablesReference": 17,
            "expensive": true,
        });
        let s = parse_scope(&v).unwrap();
        assert_eq!(s.name, "Globals");
        assert_eq!(s.variables_reference, 17);
        assert!(s.expensive);
    }

    #[test]
    fn parse_variable_handles_type_and_ref() {
        let v = json!({
            "name": "count",
            "value": "42",
            "type": "i32",
            "variablesReference": 0,
        });
        let var = parse_variable(&v).unwrap();
        assert_eq!(var.name, "count");
        assert_eq!(var.value, "42");
        assert_eq!(var.ty.as_deref(), Some("i32"));
        assert_eq!(var.variables_reference, 0);
    }

    #[test]
    fn parse_variable_handles_missing_type() {
        // Adapters that didn't see `supportsVariableType` in initialize
        // omit `type`. We should still parse the row.
        let v = json!({
            "name": "list",
            "value": "[1, 2, 3]",
            "variablesReference": 9,
        });
        let var = parse_variable(&v).unwrap();
        assert!(var.ty.is_none());
        assert_eq!(var.variables_reference, 9);
    }
}
