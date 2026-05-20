//! Direct HTTP client for Anthropic's `/v1/messages` endpoint — an
//! alternative to shelling out to `claude -p`. Pulls the API key from
//! `$ANTHROPIC_API_KEY`. Streaming via SSE (Server-Sent Events) — text
//! deltas flow into the same `AiMsg::Delta` channel the CLI path uses,
//! then a final `AiMsg::Done` (or `AiMsg::Failed`).
//!
//! Selected when `[ai] backend = "api"` is set in the user's config.
//! Default `[ai] backend = "cli"` keeps the existing behavior (no
//! API key required).
//!
//! `stream_to_channel` is the plain text-in/text-out streaming path.
//! `agent_to_channel` adds an agentic loop: the model gets a small set
//! of **read-only** workspace tools (`read_file` / `list_directory` /
//! `grep`) and the client runs request → tool calls → request until a
//! final answer. Read-only by design — no write_file / shell tool — so
//! it's strictly safer than the CLI backend (`claude -p`, which runs
//! with full permissions). `[ai] api_tools` (default on) picks between
//! the two for the API backend.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use super::AiMsg;

/// Anthropic Messages API endpoint (the only one we hit).
const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
/// API version header — pinned to a known-stable value. Bump when
/// Anthropic publishes a new major.
const API_VERSION: &str = "2023-06-01";
/// Default model. Users can override per-call via `App` config (a
/// follow-up — for now the constant is the only path). Picks Opus 4.7
/// (the model mnml itself is shipped to talk to).
const DEFAULT_MODEL: &str = "claude-opus-4-7";
/// Cap output tokens. The Messages API requires `max_tokens` so we
/// pick a generous default. Most code-explanation / commit-msg
/// answers come in under 1000.
const DEFAULT_MAX_TOKENS: u32 = 4096;
/// Fast model for inline ghost-text completion — latency matters far
/// more than depth here.
const COMPLETION_MODEL: &str = "claude-haiku-4-5";

/// One-shot, non-streaming code completion for the inline ghost-text
/// feature. Sends the code before + after the cursor and asks for ONLY
/// the text to insert. Blocking — call from a worker thread.
///
/// Deliberately separate from `stream_to_channel`: a focused system
/// prompt, a small `max_tokens`, the fast model, and a hard request
/// timeout so a slow response doesn't leave a stale job hanging.
///
/// `model` overrides [`COMPLETION_MODEL`] when `Some` (`[ai]
/// suggest_model` config) — latency matters here, so the default is the
/// fast model, but a user can pin a different one.
pub fn complete_code(
    prefix: &str,
    suffix: &str,
    language: &str,
    model: Option<&str>,
) -> Result<String, String> {
    let api_key =
        std::env::var("ANTHROPIC_API_KEY").map_err(|_| "$ANTHROPIC_API_KEY not set".to_string())?;
    let system = "You are an inline code-completion engine inside a text editor. \
        You receive the code BEFORE the cursor and the code AFTER the cursor. \
        Output ONLY the exact text that should be inserted at the cursor position \
        to continue the code naturally. No explanation, no markdown fences, no \
        repetition of the surrounding code. Prefer short completions — usually \
        the rest of the current line or a few lines. If no useful completion is \
        possible, output nothing.";
    let user = format!(
        "Language: {language}\n\n<code-before-cursor>\n{prefix}\n</code-before-cursor>\n\n\
         <code-after-cursor>\n{suffix}\n</code-after-cursor>\n\n\
         Output the text to insert at the cursor:"
    );
    let body = serde_json::json!({
        "model": model.unwrap_or(COMPLETION_MODEL),
        "max_tokens": 256u32,
        "system": system,
        "messages": [{ "role": "user", "content": user }],
    })
    .to_string();
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("build client: {e}"))?;
    let resp = client
        .post(ENDPOINT)
        .header("x-api-key", api_key)
        .header("anthropic-version", API_VERSION)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .map_err(|e| format!("POST: {e}"))?;
    let status = resp.status();
    let text = resp.text().unwrap_or_default();
    if !status.is_success() {
        return Err(format!(
            "HTTP {status}: {}",
            text.chars().take(200).collect::<String>()
        ));
    }
    // Non-streaming reply shape: `{ "content": [{ "type": "text",
    // "text": "..." }, …] }`. Concatenate every text block.
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("parse reply: {e}"))?;
    let out: String = v
        .get("content")
        .and_then(|c| c.as_array())
        .map(|arr| {
            arr.iter()
                .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text"))
                .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                .collect::<String>()
        })
        .unwrap_or_default();
    Ok(out)
}

/// Stream a one-shot prompt through Anthropic's `/v1/messages` with
/// `stream: true`. Each `content_block_delta` event with a `text_delta`
/// becomes an `AiMsg::Delta`; the final accumulated text lands as
/// `AiMsg::Done`. Errors (network / 4xx / 5xx) become `AiMsg::Failed`.
///
/// Blocking — call from a worker thread. `cancel` is polled between
/// SSE lines so the user's `x` in the AI pane bails out promptly.
///
/// `model` overrides the default; pass `None` for `DEFAULT_MODEL`.
/// `system` is an optional system prompt prepended to the request.
/// `max_tokens` overrides `DEFAULT_MAX_TOKENS` when set (clamped to a
/// sane 16..=200000 range).
pub fn stream_to_channel(
    prompt: &str,
    model: Option<&str>,
    system: Option<&str>,
    max_tokens: Option<u32>,
    cancel: &AtomicBool,
    sink: std::sync::mpsc::Sender<(u64, AiMsg)>,
    job_id: u64,
) {
    let Ok(api_key) = std::env::var("ANTHROPIC_API_KEY") else {
        let _ = sink.send((
            job_id,
            AiMsg::Failed(
                "$ANTHROPIC_API_KEY not set — switch `[ai] backend = \"cli\"` or set the key"
                    .to_string(),
            ),
        ));
        return;
    };
    let mt = max_tokens
        .map(|n| n.clamp(16, 200_000))
        .unwrap_or(DEFAULT_MAX_TOKENS);
    let mut body = serde_json::json!({
        "model": model.unwrap_or(DEFAULT_MODEL),
        "max_tokens": mt,
        "stream": true,
        "messages": [{ "role": "user", "content": prompt }],
    });
    if let Some(sys) = system
        && !sys.trim().is_empty()
        && let Some(obj) = body.as_object_mut()
    {
        obj.insert(
            "system".to_string(),
            serde_json::Value::String(sys.to_string()),
        );
    }
    let body = body.to_string();
    let client = match reqwest::blocking::Client::builder()
        // No timeout on streaming; the request itself reads SSE lines.
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            let _ = sink.send((job_id, AiMsg::Failed(format!("build client: {e}"))));
            return;
        }
    };
    let response = client
        .post(ENDPOINT)
        .header("x-api-key", api_key)
        .header("anthropic-version", API_VERSION)
        .header("content-type", "application/json")
        .body(body)
        .send();
    let response = match response {
        Ok(r) => r,
        Err(e) => {
            let _ = sink.send((job_id, AiMsg::Failed(format!("POST: {e}"))));
            return;
        }
    };
    let status = response.status();
    if !status.is_success() {
        let snippet = response
            .text()
            .unwrap_or_default()
            .chars()
            .take(400)
            .collect::<String>();
        let _ = sink.send((job_id, AiMsg::Failed(format!("HTTP {status}: {snippet}"))));
        return;
    }
    // Walk SSE events line-by-line.
    let mut reader = BufReader::new(response);
    let mut accumulated = String::new();
    let mut current_event: Option<String> = None;
    let mut input_tokens: u64 = 0;
    let mut output_tokens: u64 = 0;
    loop {
        if cancel.load(Ordering::Relaxed) {
            let _ = sink.send((job_id, AiMsg::Failed("cancelled".to_string())));
            return;
        }
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break, // end of stream
            Ok(_) => {}
            Err(e) => {
                let _ = sink.send((job_id, AiMsg::Failed(format!("read SSE: {e}"))));
                return;
            }
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        // SSE framing: `event: <name>` / `data: <json>` / blank line ends
        // an event. We only care about `content_block_delta` (text only)
        // and `message_stop` (end-of-message).
        if let Some(name) = trimmed.strip_prefix("event: ") {
            current_event = Some(name.to_string());
        } else if let Some(json) = trimmed.strip_prefix("data: ") {
            let Some(event) = current_event.as_deref() else {
                continue;
            };
            match event {
                "content_block_delta" => {
                    if let Some(delta_text) = parse_text_delta(json)
                        && !delta_text.is_empty()
                    {
                        accumulated.push_str(&delta_text);
                        let _ = sink.send((job_id, AiMsg::Delta(delta_text)));
                    }
                }
                "message_start" => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(json)
                        && let Some(n) = v
                            .get("message")
                            .and_then(|m| m.get("usage"))
                            .and_then(|u| u.get("input_tokens"))
                            .and_then(|t| t.as_u64())
                    {
                        input_tokens = n;
                    }
                }
                "message_delta" => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(json)
                        && let Some(n) = v
                            .get("usage")
                            .and_then(|u| u.get("output_tokens"))
                            .and_then(|t| t.as_u64())
                    {
                        output_tokens = n;
                    }
                }
                "message_stop" => break,
                "error" => {
                    let snippet = json.chars().take(400).collect::<String>();
                    let _ = sink.send((job_id, AiMsg::Failed(format!("API error: {snippet}"))));
                    return;
                }
                _ => {}
            }
        }
    }
    if input_tokens > 0 || output_tokens > 0 {
        let _ = sink.send((
            job_id,
            AiMsg::Usage {
                input_tokens,
                output_tokens,
            },
        ));
    }
    let _ = sink.send((job_id, AiMsg::Done(accumulated.trim().to_string())));
}

/// Extract a `text` field out of a `content_block_delta` data JSON.
/// Returns `None` for non-text deltas (e.g. tool-use deltas, which we
/// don't render in the MVP).
fn parse_text_delta(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let delta = v.get("delta")?;
    let kind = delta.get("type")?.as_str()?;
    if kind == "text_delta" {
        return Some(delta.get("text")?.as_str()?.to_string());
    }
    None
}

/// Max agent turns (one model response = one turn) before the loop
/// stops — guards against a tool-call cycle that never converges.
const AGENT_MAX_ITERS: usize = 12;
/// Per-tool output cap (bytes) — keeps a tool result from blowing the
/// context window.
const TOOL_OUTPUT_CAP: usize = 48 * 1024;

/// One content block streamed back within an agent turn.
enum TurnBlock {
    Text(String),
    ToolUse {
        id: String,
        name: String,
        input_json: String,
    },
}

/// The agentic loop over `/v1/messages`. Gives the model the read-only
/// workspace tools (`read_file` / `list_directory` / `grep`) and runs
/// request → (tool calls) → request until it produces a final answer.
/// Text streams to `sink` as `AiMsg::Delta`s; each tool call surfaces
/// as a `[tool: …]` status line. A final `AiMsg::Done` carries the
/// model's text across all turns (the status lines collapse away);
/// errors / cancel become `AiMsg::Failed`.
///
/// Blocking — call from a worker thread. `cancel` is polled between SSE
/// lines and between turns.
#[allow(clippy::too_many_arguments)]
pub fn agent_to_channel(
    prompt: &str,
    workspace: &Path,
    model: Option<&str>,
    system: Option<&str>,
    max_tokens: Option<u32>,
    cancel: &AtomicBool,
    sink: std::sync::mpsc::Sender<(u64, AiMsg)>,
    job_id: u64,
) {
    let Ok(api_key) = std::env::var("ANTHROPIC_API_KEY") else {
        let _ = sink.send((
            job_id,
            AiMsg::Failed(
                "$ANTHROPIC_API_KEY not set — switch `[ai] backend = \"cli\"` or set the key"
                    .to_string(),
            ),
        ));
        return;
    };
    let client = match reqwest::blocking::Client::builder().build() {
        Ok(c) => c,
        Err(e) => {
            let _ = sink.send((job_id, AiMsg::Failed(format!("build client: {e}"))));
            return;
        }
    };
    let mt = max_tokens
        .map(|n| n.clamp(16, 200_000))
        .unwrap_or(DEFAULT_MAX_TOKENS);
    let model = model.unwrap_or(DEFAULT_MODEL).to_string();
    let sys = agent_system_prompt(system);
    let mut messages: Vec<serde_json::Value> =
        vec![serde_json::json!({ "role": "user", "content": prompt })];
    let mut full_text = String::new();
    // Token usage summed across every turn — each turn is billed for
    // the full context it sends, so summing per-turn is the true total.
    let mut total_in: u64 = 0;
    let mut total_out: u64 = 0;

    for iter in 0..AGENT_MAX_ITERS {
        if cancel.load(Ordering::Relaxed) {
            let _ = sink.send((job_id, AiMsg::Failed("cancelled".to_string())));
            return;
        }
        let body = serde_json::json!({
            "model": model,
            "max_tokens": mt,
            "stream": true,
            "system": sys,
            "tools": agent_tools(),
            "messages": messages,
        })
        .to_string();
        let (blocks, stop_reason, (turn_in, turn_out)) =
            match run_agent_turn(&client, &api_key, body, cancel, &sink, job_id) {
                Ok(v) => v,
                Err(e) => {
                    let _ = sink.send((job_id, AiMsg::Failed(e)));
                    return;
                }
            };
        total_in += turn_in;
        total_out += turn_out;
        // Accumulate this turn's text, separated from the previous
        // turn's so the final answer doesn't run two turns together.
        let turn_text: String = blocks
            .iter()
            .filter_map(|b| match b {
                TurnBlock::Text(t) => Some(t.as_str()),
                _ => None,
            })
            .collect();
        if !turn_text.is_empty() {
            if !full_text.is_empty() && !full_text.ends_with('\n') {
                full_text.push_str("\n\n");
            }
            full_text.push_str(&turn_text);
        }
        // Record the assistant turn so the next request has context.
        let mut content = Vec::new();
        for b in &blocks {
            match b {
                TurnBlock::Text(t) if !t.is_empty() => {
                    content.push(serde_json::json!({ "type": "text", "text": t }));
                }
                TurnBlock::Text(_) => {}
                TurnBlock::ToolUse {
                    id,
                    name,
                    input_json,
                } => {
                    let input: serde_json::Value =
                        serde_json::from_str(input_json).unwrap_or(serde_json::json!({}));
                    content.push(serde_json::json!({
                        "type": "tool_use", "id": id, "name": name, "input": input,
                    }));
                }
            }
        }
        if content.is_empty() {
            break; // nothing came back — don't loop forever
        }
        messages.push(serde_json::json!({ "role": "assistant", "content": content }));

        let has_tool_use = blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ToolUse { .. }));
        if stop_reason.as_deref() != Some("tool_use") || !has_tool_use {
            break; // the model is done
        }
        // Execute each requested tool, feed the results back.
        let mut results = Vec::new();
        for b in &blocks {
            let TurnBlock::ToolUse {
                id,
                name,
                input_json,
            } = b
            else {
                continue;
            };
            let input: serde_json::Value =
                serde_json::from_str(input_json).unwrap_or(serde_json::json!({}));
            let _ = sink.send((
                job_id,
                AiMsg::Delta(format!("\n[tool: {}]\n", tool_summary(name, &input))),
            ));
            let (text, is_error) = match execute_tool(workspace, name, &input) {
                Ok(t) => (t, false),
                Err(e) => (e, true),
            };
            let mut r = serde_json::json!({
                "type": "tool_result", "tool_use_id": id, "content": text,
            });
            if is_error {
                r["is_error"] = serde_json::json!(true);
            }
            results.push(r);
        }
        messages.push(serde_json::json!({ "role": "user", "content": results }));
        if iter + 1 == AGENT_MAX_ITERS {
            full_text.push_str("\n\n[stopped: tool-iteration cap reached]");
        }
    }
    if total_in > 0 || total_out > 0 {
        let _ = sink.send((
            job_id,
            AiMsg::Usage {
                input_tokens: total_in,
                output_tokens: total_out,
            },
        ));
    }
    let _ = sink.send((job_id, AiMsg::Done(full_text.trim().to_string())));
}

/// Run one streaming agent turn — POST + read the SSE stream, forwarding
/// text deltas to `sink` and collecting the turn's content blocks +
/// `stop_reason`.
#[allow(clippy::type_complexity)]
fn run_agent_turn(
    client: &reqwest::blocking::Client,
    api_key: &str,
    body: String,
    cancel: &AtomicBool,
    sink: &std::sync::mpsc::Sender<(u64, AiMsg)>,
    job_id: u64,
) -> Result<(Vec<TurnBlock>, Option<String>, (u64, u64)), String> {
    let response = client
        .post(ENDPOINT)
        .header("x-api-key", api_key)
        .header("anthropic-version", API_VERSION)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .map_err(|e| format!("POST: {e}"))?;
    let status = response.status();
    if !status.is_success() {
        let snippet = response
            .text()
            .unwrap_or_default()
            .chars()
            .take(400)
            .collect::<String>();
        return Err(format!("HTTP {status}: {snippet}"));
    }
    let mut reader = BufReader::new(response);
    let mut blocks: Vec<TurnBlock> = Vec::new();
    let mut stop_reason: Option<String> = None;
    let mut current_event: Option<String> = None;
    let mut input_tokens: u64 = 0;
    let mut output_tokens: u64 = 0;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err("cancelled".to_string());
        }
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) => return Err(format!("read SSE: {e}")),
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if let Some(name) = trimmed.strip_prefix("event: ") {
            current_event = Some(name.to_string());
            continue;
        }
        let Some(json) = trimmed.strip_prefix("data: ") else {
            continue;
        };
        let Some(event) = current_event.as_deref() else {
            continue;
        };
        match event {
            "content_block_start" => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
                    let cb = v.get("content_block");
                    let kind = cb
                        .and_then(|c| c.get("type"))
                        .and_then(|t| t.as_str())
                        .unwrap_or("");
                    if kind == "tool_use" {
                        let id = cb
                            .and_then(|c| c.get("id"))
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let name = cb
                            .and_then(|c| c.get("name"))
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        blocks.push(TurnBlock::ToolUse {
                            id,
                            name,
                            input_json: String::new(),
                        });
                    } else {
                        // text (or anything else) — a placeholder keeps
                        // later block indices aligned.
                        blocks.push(TurnBlock::Text(String::new()));
                    }
                }
            }
            "content_block_delta" => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
                    let idx = v.get("index").and_then(|i| i.as_u64()).unwrap_or(0) as usize;
                    let delta = v.get("delta");
                    let dtype = delta
                        .and_then(|d| d.get("type"))
                        .and_then(|t| t.as_str())
                        .unwrap_or("");
                    match dtype {
                        "text_delta" => {
                            if let Some(t) =
                                delta.and_then(|d| d.get("text")).and_then(|x| x.as_str())
                            {
                                if let Some(TurnBlock::Text(buf)) = blocks.get_mut(idx) {
                                    buf.push_str(t);
                                }
                                if !t.is_empty() {
                                    let _ = sink.send((job_id, AiMsg::Delta(t.to_string())));
                                }
                            }
                        }
                        "input_json_delta" => {
                            if let Some(p) = delta
                                .and_then(|d| d.get("partial_json"))
                                .and_then(|x| x.as_str())
                                && let Some(TurnBlock::ToolUse { input_json, .. }) =
                                    blocks.get_mut(idx)
                            {
                                input_json.push_str(p);
                            }
                        }
                        _ => {}
                    }
                }
            }
            "message_start" => {
                // The `message_start` event carries the input-token count.
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(json)
                    && let Some(n) = v
                        .get("message")
                        .and_then(|m| m.get("usage"))
                        .and_then(|u| u.get("input_tokens"))
                        .and_then(|t| t.as_u64())
                {
                    input_tokens = n;
                }
            }
            "message_delta" => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
                    if let Some(sr) = v
                        .get("delta")
                        .and_then(|d| d.get("stop_reason"))
                        .and_then(|s| s.as_str())
                    {
                        stop_reason = Some(sr.to_string());
                    }
                    // `message_delta.usage.output_tokens` is cumulative —
                    // the last one seen is the turn's output total.
                    if let Some(n) = v
                        .get("usage")
                        .and_then(|u| u.get("output_tokens"))
                        .and_then(|t| t.as_u64())
                    {
                        output_tokens = n;
                    }
                }
            }
            "message_stop" => break,
            "error" => {
                let snippet = json.chars().take(400).collect::<String>();
                return Err(format!("API error: {snippet}"));
            }
            _ => {}
        }
    }
    Ok((blocks, stop_reason, (input_tokens, output_tokens)))
}

/// The agent's tool definitions — all read-only, workspace-scoped.
fn agent_tools() -> serde_json::Value {
    serde_json::json!([
        {
            "name": "read_file",
            "description": "Read a UTF-8 text file from the project workspace. The path is workspace-relative.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Workspace-relative file path." }
                },
                "required": ["path"]
            }
        },
        {
            "name": "list_directory",
            "description": "List the entries of a workspace directory. Path is workspace-relative; \".\" is the workspace root. Directories are suffixed with /.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Workspace-relative directory path." }
                },
                "required": ["path"]
            }
        },
        {
            "name": "grep",
            "description": "Search the workspace for a regular-expression pattern (ripgrep). Returns matching file:line:text rows.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "The regular expression to search for." }
                },
                "required": ["pattern"]
            }
        }
    ])
}

/// System prompt for the agent — a base instruction about the tools +
/// the workspace, with the user's optional `[ai] system_prompt` appended.
fn agent_system_prompt(user: Option<&str>) -> String {
    let base = "You are an AI assistant embedded in the mnml code editor, working inside \
        the user's project workspace. You have read-only tools — read_file, list_directory, \
        and grep — to explore the codebase. Use them to ground your answers in the actual \
        code rather than guessing. Keep answers focused and concise.";
    match user {
        Some(u) if !u.trim().is_empty() => format!("{base}\n\n{u}"),
        _ => base.to_string(),
    }
}

/// A short human label for a tool call — shown as a `[tool: …]` status
/// line while the agent runs.
fn tool_summary(name: &str, input: &serde_json::Value) -> String {
    let arg = input
        .get("path")
        .or_else(|| input.get("pattern"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if arg.is_empty() {
        name.to_string()
    } else {
        format!("{name} {arg}")
    }
}

/// Dispatch + run one tool call. `Ok` is the tool result; `Err` is a
/// user-visible error string (fed back to the model as an error result).
fn execute_tool(workspace: &Path, name: &str, input: &serde_json::Value) -> Result<String, String> {
    match name {
        "read_file" => {
            let path = input
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or("read_file: missing `path`")?;
            tool_read_file(workspace, path)
        }
        "list_directory" => {
            let path = input.get("path").and_then(|v| v.as_str()).unwrap_or(".");
            tool_list_directory(workspace, path)
        }
        "grep" => {
            let pattern = input
                .get("pattern")
                .and_then(|v| v.as_str())
                .ok_or("grep: missing `pattern`")?;
            tool_grep(workspace, pattern)
        }
        other => Err(format!("unknown tool: {other}")),
    }
}

/// Resolve a workspace-relative path, canonicalize it, and refuse
/// anything that escapes the workspace root (`..`, absolute paths,
/// symlinks pointing outside).
fn resolve_in_workspace(workspace: &Path, rel: &str) -> Result<PathBuf, String> {
    let canon = workspace
        .join(rel)
        .canonicalize()
        .map_err(|e| format!("{rel}: {e}"))?;
    let ws = workspace
        .canonicalize()
        .map_err(|e| format!("workspace: {e}"))?;
    if !canon.starts_with(&ws) {
        return Err(format!("{rel}: path escapes the workspace"));
    }
    Ok(canon)
}

fn tool_read_file(workspace: &Path, rel: &str) -> Result<String, String> {
    let path = resolve_in_workspace(workspace, rel)?;
    if !path.is_file() {
        return Err(format!("{rel}: not a file"));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("{rel}: {e}"))?;
    Ok(cap_output(&String::from_utf8_lossy(&bytes)))
}

fn tool_list_directory(workspace: &Path, rel: &str) -> Result<String, String> {
    let dir = resolve_in_workspace(workspace, rel)?;
    if !dir.is_dir() {
        return Err(format!("{rel}: not a directory"));
    }
    let mut entries: Vec<String> = std::fs::read_dir(&dir)
        .map_err(|e| format!("{rel}: {e}"))?
        .flatten()
        .map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                format!("{name}/")
            } else {
                name
            }
        })
        .collect();
    entries.sort();
    if entries.is_empty() {
        return Ok("(empty directory)".to_string());
    }
    Ok(cap_output(&entries.join("\n")))
}

fn tool_grep(workspace: &Path, pattern: &str) -> Result<String, String> {
    let out = std::process::Command::new("rg")
        .args([
            "--line-number",
            "--no-heading",
            "--color=never",
            "--max-count=50",
            "-e",
            pattern,
        ])
        .current_dir(workspace)
        .output()
        .map_err(|e| format!("grep: ripgrep (rg) not available: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout);
    if text.trim().is_empty() {
        return Ok(format!("(no matches for {pattern:?})"));
    }
    Ok(cap_output(&text))
}

/// Truncate tool output at [`TOOL_OUTPUT_CAP`] on a char boundary.
fn cap_output(s: &str) -> String {
    if s.len() <= TOOL_OUTPUT_CAP {
        return s.to_string();
    }
    let mut end = TOOL_OUTPUT_CAP;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n…[truncated at {TOOL_OUTPUT_CAP} bytes]", &s[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_text_delta_extracts_text() {
        let s = r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#;
        assert_eq!(parse_text_delta(s).as_deref(), Some("hello"));
    }

    #[test]
    fn parse_text_delta_ignores_non_text() {
        // input_json_delta (tool-use) — not text, return None.
        let s = r#"{"delta":{"type":"input_json_delta","partial_json":"{\""}}"#;
        assert_eq!(parse_text_delta(s), None);
    }

    #[test]
    fn parse_text_delta_handles_malformed_json() {
        assert_eq!(parse_text_delta("{not json"), None);
        assert_eq!(parse_text_delta("{}"), None);
    }

    #[test]
    fn execute_tool_read_file_reads_workspace_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("hello.txt"), "hi there").unwrap();
        let out = execute_tool(
            dir.path(),
            "read_file",
            &serde_json::json!({ "path": "hello.txt" }),
        )
        .unwrap();
        assert_eq!(out, "hi there");
    }

    #[test]
    fn execute_tool_read_file_rejects_workspace_escape() {
        let dir = tempfile::tempdir().unwrap();
        let r = execute_tool(
            dir.path(),
            "read_file",
            &serde_json::json!({ "path": "../../../../../../etc/passwd" }),
        );
        assert!(r.is_err(), "escape should be refused: {r:?}");
    }

    #[test]
    fn execute_tool_list_directory_lists_entries() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "").unwrap();
        std::fs::create_dir(dir.path().join("sub")).unwrap();
        let out = execute_tool(
            dir.path(),
            "list_directory",
            &serde_json::json!({ "path": "." }),
        )
        .unwrap();
        assert!(out.contains("a.txt"), "out: {out:?}");
        assert!(out.contains("sub/"), "out: {out:?}");
    }

    #[test]
    fn execute_tool_unknown_name_errors() {
        let dir = tempfile::tempdir().unwrap();
        assert!(execute_tool(dir.path(), "delete_everything", &serde_json::json!({})).is_err());
    }

    #[test]
    fn cap_output_truncates_on_char_boundary() {
        let big = "x".repeat(TOOL_OUTPUT_CAP + 100);
        let capped = cap_output(&big);
        assert!(capped.len() < big.len());
        assert!(capped.contains("truncated"));
        // Short input passes through untouched.
        assert_eq!(cap_output("short"), "short");
    }
}
