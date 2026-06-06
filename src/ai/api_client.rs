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
//! `agent_to_channel` adds an agentic loop: the model gets workspace
//! tools — `read_file` / `list_directory` / `grep` (read-only, always),
//! plus `write_file` when `[ai] api_write_tools` is opted in, plus
//! `shell_exec` when `[ai] api_shell_tools` is opted in — and the
//! client runs request → tool calls → request until a final answer.
//! Write + shell both default off; when on, each invocation blocks
//! for the user's per-call approval (set `[ai] api_write_confirm = false`
//! / `api_shell_confirm = false` to opt out of the prompt).
//! `[ai] api_tools` (default on) picks agent loop vs plain streaming
//! for the API backend.

use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use super::AiMsg;

/// One parsed image attachment, ready to embed in a `content` block.
#[derive(Debug, Clone)]
pub struct ImageAttachment {
    /// `image/png` / `image/jpeg` / `image/gif` / `image/webp`. Anthropic
    /// accepts these four. Other extensions are rejected by [`load_image`].
    pub media_type: String,
    pub base64_data: String,
}

/// Walk the prompt for leading `\image <path>` (or `\img <path>`)
/// directives. Each match is stripped from the prompt, the file is
/// read + base64-encoded, and the result is appended to the returned
/// vec. Directives are only honored at the start of the prompt
/// (consecutive lines), so the rest of the text — including a literal
/// `\image` later in the body — passes through untouched.
///
/// Paths starting with `~` are tilde-expanded. Relative paths resolve
/// against `workspace`. Returns the cleaned prompt plus the parsed
/// attachments, and a list of per-line errors so the caller can
/// surface them (a bad path doesn't tank the whole prompt).
pub fn extract_image_attachments(
    prompt: &str,
    workspace: &Path,
) -> (String, Vec<ImageAttachment>, Vec<String>) {
    let mut imgs = Vec::new();
    let mut errs = Vec::new();
    // Iterate by lines, but only consume `\image` lines while we're
    // still at the leading block.
    let mut rest_lines: Vec<&str> = Vec::new();
    let mut in_directives = true;
    for line in prompt.lines() {
        if in_directives {
            let trimmed = line.trim_start();
            if let Some(arg) = trimmed
                .strip_prefix("\\image ")
                .or_else(|| trimmed.strip_prefix("\\img "))
            {
                let path = arg.trim();
                if path.is_empty() {
                    errs.push("\\image directive missing path".to_string());
                    continue;
                }
                let resolved = resolve_path(path, workspace);
                match load_image(&resolved) {
                    Ok(att) => imgs.push(att),
                    Err(e) => errs.push(format!("{path}: {e}")),
                }
                continue;
            }
            // Empty lines between directives are tolerated. Anything
            // else closes the directive block.
            if !trimmed.is_empty() {
                in_directives = false;
            }
        }
        if !in_directives {
            rest_lines.push(line);
        }
    }
    // Trailing newline handling: `lines()` drops the trailing newline,
    // so the cleaned prompt is the rest, joined by `\n`.
    let cleaned = rest_lines.join("\n");
    (cleaned, imgs, errs)
}

fn resolve_path(path: &str, workspace: &Path) -> PathBuf {
    if let Some(stripped) = path.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(stripped);
        }
    }
    let p = PathBuf::from(path);
    if p.is_absolute() {
        p
    } else {
        workspace.join(p)
    }
}

/// Read + base64-encode an image file. Rejects anything that isn't
/// PNG / JPEG / GIF / WebP (those are the Anthropic-accepted four).
/// Caps the file size at 5 MB — Anthropic's per-image limit is 5 MB
/// after base64 expansion, so we cap before the encode.
pub fn load_image(path: &Path) -> Result<ImageAttachment, String> {
    const MAX_BYTES: u64 = 5 * 1024 * 1024;
    let meta = std::fs::metadata(path).map_err(|e| format!("stat: {e}"))?;
    if meta.len() > MAX_BYTES {
        return Err(format!(
            "file too large ({} MB > 5 MB cap)",
            meta.len() / 1_048_576
        ));
    }
    let bytes = std::fs::read(path).map_err(|e| format!("read: {e}"))?;
    let media_type = match path
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        other => {
            return Err(format!(
                "unsupported extension `{}` — use png / jpg / gif / webp",
                other.unwrap_or("(none)")
            ));
        }
    };
    Ok(ImageAttachment {
        media_type: media_type.to_string(),
        base64_data: STANDARD.encode(&bytes),
    })
}

/// Build the `content` field for a user message. When `images` is
/// empty we pass through as a plain string (the historical shape).
/// With images we switch to a content-block array so the API sees
/// the image source(s) followed by the text.
fn user_content(prompt: &str, images: &[ImageAttachment]) -> serde_json::Value {
    if images.is_empty() {
        return serde_json::Value::String(prompt.to_string());
    }
    let mut blocks = Vec::with_capacity(images.len() + 1);
    for img in images {
        blocks.push(serde_json::json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": img.media_type,
                "data": img.base64_data,
            }
        }));
    }
    if !prompt.is_empty() {
        blocks.push(serde_json::json!({
            "type": "text",
            "text": prompt,
        }));
    }
    serde_json::Value::Array(blocks)
}

/// Anthropic Messages API endpoint (the only one we hit).
const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
/// API version header — pinned to a known-stable value. Bump when
/// Anthropic publishes a new major.
const API_VERSION: &str = "2023-06-01";
/// Default model when `[ai] model` isn't set. Opus 4.7 (the model mnml
/// itself ships to talk to); callers pass `Some(...)` to override.
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
#[allow(clippy::too_many_arguments)]
pub fn stream_to_channel(
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
    let mt = max_tokens
        .map(|n| n.clamp(16, 200_000))
        .unwrap_or(DEFAULT_MAX_TOKENS);
    let (cleaned_prompt, images, image_errs) = extract_image_attachments(prompt, workspace);
    for err in &image_errs {
        let _ = sink.send((job_id, AiMsg::Delta(format!("[image: {err}]\n"))));
    }
    let mut body = serde_json::json!({
        "model": model.unwrap_or(DEFAULT_MODEL),
        "max_tokens": mt,
        "stream": true,
        "messages": [{ "role": "user", "content": user_content(&cleaned_prompt, &images) }],
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
/// Returns `None` for non-text deltas (e.g. `input_json_delta` tool-use
/// deltas — `stream_to_channel` is the plain text path; the agent loop
/// handles tool-use blocks itself).
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
/// workspace tools (`read_file` / `list_directory` / `grep`) — plus
/// `write_file` when `write_tools` is on — and runs request → (tool
/// calls) → request until it produces a final answer. Text streams to
/// `sink` as `AiMsg::Delta`s; each tool call surfaces as a `[tool: …]`
/// status line. A final `AiMsg::Done` carries the model's text across
/// all turns (the status lines collapse away); errors / cancel become
/// `AiMsg::Failed`.
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
    write_tools: bool,
    write_confirm: bool,
    shell_tools: bool,
    shell_confirm: bool,
    confirm_rx: &std::sync::mpsc::Receiver<bool>,
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
    let sys = agent_system_prompt(system, write_tools, shell_tools);
    let (cleaned_prompt, images, image_errs) = extract_image_attachments(prompt, workspace);
    for err in &image_errs {
        let _ = sink.send((job_id, AiMsg::Delta(format!("[image: {err}]\n"))));
    }
    let mut messages: Vec<serde_json::Value> = vec![serde_json::json!({
        "role": "user",
        "content": user_content(&cleaned_prompt, &images),
    })];
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
            "tools": agent_tools(write_tools, shell_tools),
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
            // Confirmation gate — `write_file` and `shell_exec` both
            // block on the user's approval (sent back through
            // `confirm_rx`) when their respective confirm flag is on.
            let needs_confirm =
                (write_confirm && name == "write_file") || (shell_confirm && name == "shell_exec");
            if needs_confirm {
                let _ = sink.send((
                    job_id,
                    AiMsg::ConfirmTool {
                        summary: tool_summary(name, &input),
                    },
                ));
                let approved = wait_for_confirm(confirm_rx, cancel);
                match approved {
                    None => {
                        // Cancelled while waiting — bail the whole run.
                        let _ = sink.send((job_id, AiMsg::Failed("cancelled".to_string())));
                        return;
                    }
                    Some(false) => {
                        let (label, hint) = if name == "shell_exec" {
                            (
                                "[shell run declined by user]",
                                "The user declined this shell_exec call. Do not retry the same \
                                command; describe what you would have run and why instead.",
                            )
                        } else {
                            (
                                "[write declined by user]",
                                "The user declined this write_file operation. Do not retry it; \
                                explain what you would have written instead.",
                            )
                        };
                        let _ = sink.send((job_id, AiMsg::Delta(format!("\n{label}\n"))));
                        results.push(serde_json::json!({
                            "type": "tool_result", "tool_use_id": id,
                            "content": hint,
                        }));
                        continue;
                    }
                    Some(true) => {}
                }
            }
            let (text, is_error) =
                match execute_tool(workspace, name, &input, write_tools, shell_tools) {
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

/// Block until the user answers a tool-confirmation prompt. Polls
/// `confirm_rx` with a short timeout so `cancel` stays responsive.
/// `Some(true/false)` is the answer; `None` ⇒ cancelled or the main
/// thread hung up.
fn wait_for_confirm(
    confirm_rx: &std::sync::mpsc::Receiver<bool>,
    cancel: &AtomicBool,
) -> Option<bool> {
    use std::sync::mpsc::RecvTimeoutError;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return None;
        }
        match confirm_rx.recv_timeout(std::time::Duration::from_millis(120)) {
            Ok(answer) => return Some(answer),
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => return None,
        }
    }
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

/// The agent's tool definitions — workspace-scoped. The read-only
/// three are always offered. `write_file` is included only when
/// `write` is on (`[ai] api_write_tools`, default off). `shell_exec`
/// is included only when `shell` is on (`[ai] api_shell_tools`,
/// default off).
fn agent_tools(write: bool, shell: bool) -> serde_json::Value {
    let mut tools = vec![
        serde_json::json!({
            "name": "read_file",
            "description": "Read a UTF-8 text file from the project workspace. The path is workspace-relative.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Workspace-relative file path." }
                },
                "required": ["path"]
            }
        }),
        serde_json::json!({
            "name": "list_directory",
            "description": "List the entries of a workspace directory. Path is workspace-relative; \".\" is the workspace root. Directories are suffixed with /.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Workspace-relative directory path." }
                },
                "required": ["path"]
            }
        }),
        serde_json::json!({
            "name": "grep",
            "description": "Search the workspace for a regular-expression pattern (ripgrep). Returns matching file:line:text rows.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "The regular expression to search for." }
                },
                "required": ["pattern"]
            }
        }),
    ];
    if write {
        tools.push(serde_json::json!({
            "name": "write_file",
            "description": "Write (creating or overwriting) a UTF-8 text file in the project workspace. The path is workspace-relative; parent directories are created as needed. Use sparingly and only when the user asked for an edit.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Workspace-relative file path." },
                    "content": { "type": "string", "description": "The full new file contents." }
                },
                "required": ["path", "content"]
            }
        }));
    }
    if shell {
        tools.push(serde_json::json!({
            "name": "shell_exec",
            "description": "Run a shell command in the project workspace via `sh -c`. Returns stdout, stderr, and exit code in a `<stdout>...</stdout><stderr>...</stderr><exit>N</exit>` envelope. The 60-second wall-clock timeout, 256 KB combined-output cap, and the user's per-call confirmation prompt are enforced by the editor. Use sparingly and only when read-only tools and write_file can't get the answer.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "The shell command to execute (passed verbatim to `sh -c`)." }
                },
                "required": ["command"]
            }
        }));
    }
    serde_json::Value::Array(tools)
}

/// System prompt for the agent — a base instruction about the tools +
/// the workspace, with the user's optional `[ai] system_prompt` appended.
fn agent_system_prompt(user: Option<&str>, write: bool, shell: bool) -> String {
    let mut tools_list = String::from("read_file, list_directory, grep");
    if write {
        tools_list.push_str(", write_file");
    }
    if shell {
        tools_list.push_str(", shell_exec");
    }
    let read_only_note = if write || shell {
        "Ground your work in the actual code (read before you write or run anything)."
    } else {
        "Use them to ground your answers in the actual code rather than guessing."
    };
    let write_note = if write {
        " Only use write_file when the user asked for an edit."
    } else {
        ""
    };
    let shell_note = if shell {
        " shell_exec runs `sh -c <command>` in the workspace with a 60-second timeout and a per-call user confirmation; prefer the read-only tools and write_file when they suffice."
    } else {
        ""
    };
    let base = format!(
        "You are an AI assistant embedded in the mnml code editor, working inside \
         the user's project workspace. You have tools — {tools_list} — to explore \
         the codebase.{write_note}{shell_note} {read_only_note} Keep answers focused and concise."
    );
    match user {
        Some(u) if !u.trim().is_empty() => format!("{base}\n\n{u}"),
        _ => base,
    }
}

/// A short human label for a tool call — shown as a `[tool: …]`
/// status line and also as the confirm-prompt body. Commands are
/// truncated to 80 chars so a wall-of-text invocation doesn't bury
/// the rest of the UI.
fn tool_summary(name: &str, input: &serde_json::Value) -> String {
    let arg = input
        .get("path")
        .or_else(|| input.get("pattern"))
        .or_else(|| input.get("command"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if arg.is_empty() {
        return name.to_string();
    }
    let mut trimmed = arg.replace('\n', " ");
    if trimmed.chars().count() > 80 {
        trimmed = trimmed.chars().take(77).collect::<String>() + "…";
    }
    format!("{name} {trimmed}")
}

/// Dispatch + run one tool call. `Ok` is the tool result; `Err` is a
/// user-visible error string (fed back to the model as an error result).
/// `write_enabled` gates `write_file` (defense in depth — it's also
/// absent from the tool list when off).
fn execute_tool(
    workspace: &Path,
    name: &str,
    input: &serde_json::Value,
    write_enabled: bool,
    shell_enabled: bool,
) -> Result<String, String> {
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
        "write_file" => {
            if !write_enabled {
                return Err(
                    "write_file: disabled (set `[ai] api_write_tools = true` to enable)"
                        .to_string(),
                );
            }
            let path = input
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or("write_file: missing `path`")?;
            let content = input
                .get("content")
                .and_then(|v| v.as_str())
                .ok_or("write_file: missing `content`")?;
            tool_write_file(workspace, path, content)
        }
        "shell_exec" => {
            if !shell_enabled {
                return Err(
                    "shell_exec: disabled (set `[ai] api_shell_tools = true` to enable)"
                        .to_string(),
                );
            }
            let command = input
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or("shell_exec: missing `command`")?;
            tool_shell_exec(workspace, command)
        }
        other => Err(format!("unknown tool: {other}")),
    }
}

/// Run a shell command via `sh -c <command>` in the workspace. Enforces
/// a 60-second wall-clock timeout and a 256 KB combined stdout+stderr
/// cap (anything past is truncated). Returns the result wrapped in a
/// `<stdout>...</stdout><stderr>...</stderr><exit>N</exit>` envelope so
/// the model can parse without guessing which is which. Confirmation
/// is handled upstream by the agent loop (`api_shell_confirm`).
fn tool_shell_exec(workspace: &Path, command: &str) -> Result<String, String> {
    use std::io::Read;
    use std::time::{Duration, Instant};

    const TIMEOUT: Duration = Duration::from_secs(60);
    const OUTPUT_CAP: usize = 256 * 1024;

    if command.trim().is_empty() {
        return Err("shell_exec: empty command".to_string());
    }
    let mut child = std::process::Command::new("sh")
        .arg("-c")
        .arg(command)
        .current_dir(workspace)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("shell_exec spawn: {e}"))?;
    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let stdout_join = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(mut s) = stdout.take() {
            let _ = s.read_to_end(&mut buf);
        }
        buf
    });
    let stderr_join = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(mut s) = stderr.take() {
            let _ = s.read_to_end(&mut buf);
        }
        buf
    });
    let deadline = Instant::now() + TIMEOUT;
    let exit_code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(-1),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!(
                        "shell_exec: timed out after {}s",
                        TIMEOUT.as_secs()
                    ));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("shell_exec wait: {e}")),
        }
    };
    let stdout_bytes = stdout_join.join().unwrap_or_default();
    let stderr_bytes = stderr_join.join().unwrap_or_default();

    let truncate = |bytes: Vec<u8>| -> String {
        if bytes.len() > OUTPUT_CAP {
            let mut s = String::from_utf8_lossy(&bytes[..OUTPUT_CAP]).into_owned();
            s.push_str("\n[truncated]\n");
            s
        } else {
            String::from_utf8_lossy(&bytes).into_owned()
        }
    };
    let out = truncate(stdout_bytes);
    let err = truncate(stderr_bytes);
    Ok(format!(
        "<stdout>{out}</stdout><stderr>{err}</stderr><exit>{exit_code}</exit>"
    ))
}

/// Write a workspace file. Refuses absolute paths and any `..`
/// component; the (created) parent must canonicalize to inside the
/// workspace (catches a symlinked subdir escape).
fn tool_write_file(workspace: &Path, rel: &str, content: &str) -> Result<String, String> {
    use std::path::Component;
    if rel.trim().is_empty() {
        return Err("write_file: empty path".to_string());
    }
    let relp = Path::new(rel);
    if relp.is_absolute() || relp.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(format!(
            "{rel}: must be a workspace-relative path with no `..`"
        ));
    }
    let target = workspace.join(relp);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{rel}: {e}"))?;
        let ws = workspace
            .canonicalize()
            .map_err(|e| format!("workspace: {e}"))?;
        let cp = parent.canonicalize().map_err(|e| format!("{rel}: {e}"))?;
        if !cp.starts_with(&ws) {
            return Err(format!("{rel}: path escapes the workspace"));
        }
    }
    std::fs::write(&target, content).map_err(|e| format!("{rel}: {e}"))?;
    Ok(format!("wrote {} bytes to {rel}", content.len()))
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
            false,
            false,
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
            false,
            false,
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
            false,
            false,
        )
        .unwrap();
        assert!(out.contains("a.txt"), "out: {out:?}");
        assert!(out.contains("sub/"), "out: {out:?}");
    }

    #[test]
    fn execute_tool_unknown_name_errors() {
        let dir = tempfile::tempdir().unwrap();
        assert!(
            execute_tool(
                dir.path(),
                "delete_everything",
                &serde_json::json!({}),
                false,
                false
            )
            .is_err()
        );
    }

    #[test]
    fn execute_tool_write_file_writes_when_enabled() {
        let dir = tempfile::tempdir().unwrap();
        let out = execute_tool(
            dir.path(),
            "write_file",
            &serde_json::json!({ "path": "out/note.txt", "content": "hello" }),
            true,
            false,
        )
        .unwrap();
        assert!(out.contains("wrote"), "out: {out:?}");
        let written = std::fs::read_to_string(dir.path().join("out/note.txt")).unwrap();
        assert_eq!(written, "hello");
    }

    #[test]
    fn execute_tool_write_file_refused_when_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let r = execute_tool(
            dir.path(),
            "write_file",
            &serde_json::json!({ "path": "x.txt", "content": "nope" }),
            false,
            false,
        );
        assert!(r.is_err(), "write should be refused when disabled: {r:?}");
        assert!(!dir.path().join("x.txt").exists());
    }

    #[test]
    fn execute_tool_write_file_rejects_escape() {
        let dir = tempfile::tempdir().unwrap();
        let r = execute_tool(
            dir.path(),
            "write_file",
            &serde_json::json!({ "path": "../escaped.txt", "content": "x" }),
            true,
            false,
        );
        assert!(r.is_err(), "`..` escape should be refused: {r:?}");
    }

    #[test]
    fn execute_tool_shell_exec_refused_when_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let r = execute_tool(
            dir.path(),
            "shell_exec",
            &serde_json::json!({ "command": "echo hi" }),
            false,
            false,
        );
        assert!(r.is_err(), "shell should be refused when disabled: {r:?}");
    }

    #[test]
    fn execute_tool_shell_exec_runs_when_enabled() {
        let dir = tempfile::tempdir().unwrap();
        let out = execute_tool(
            dir.path(),
            "shell_exec",
            &serde_json::json!({ "command": "echo from-shell; echo to-stderr 1>&2" }),
            false,
            true,
        )
        .unwrap();
        assert!(out.contains("from-shell"), "stdout missing: {out:?}");
        assert!(out.contains("to-stderr"), "stderr missing: {out:?}");
        assert!(out.contains("<exit>0</exit>"), "exit missing: {out:?}");
    }

    #[test]
    fn execute_tool_shell_exec_records_nonzero_exit() {
        let dir = tempfile::tempdir().unwrap();
        let out = execute_tool(
            dir.path(),
            "shell_exec",
            &serde_json::json!({ "command": "exit 42" }),
            false,
            true,
        )
        .unwrap();
        assert!(
            out.contains("<exit>42</exit>"),
            "exit code missing: {out:?}"
        );
    }

    #[test]
    fn execute_tool_shell_exec_rejects_empty_command() {
        let dir = tempfile::tempdir().unwrap();
        let r = execute_tool(
            dir.path(),
            "shell_exec",
            &serde_json::json!({ "command": "" }),
            false,
            true,
        );
        assert!(r.is_err());
    }

    #[test]
    fn agent_tools_includes_shell_when_shell_flag_set() {
        let tools = agent_tools(false, true);
        let arr = tools.as_array().unwrap();
        let names: Vec<&str> = arr
            .iter()
            .filter_map(|t| t.get("name").and_then(|v| v.as_str()))
            .collect();
        assert!(names.contains(&"shell_exec"));
        assert!(!names.contains(&"write_file"));
    }

    #[test]
    fn agent_tools_excludes_shell_when_shell_flag_off() {
        let tools = agent_tools(true, false);
        let arr = tools.as_array().unwrap();
        let names: Vec<&str> = arr
            .iter()
            .filter_map(|t| t.get("name").and_then(|v| v.as_str()))
            .collect();
        assert!(names.contains(&"write_file"));
        assert!(!names.contains(&"shell_exec"));
    }

    #[test]
    fn tool_summary_truncates_long_commands() {
        let long = "echo ".repeat(50);
        let s = tool_summary("shell_exec", &serde_json::json!({ "command": long }));
        assert!(s.starts_with("shell_exec "));
        assert!(
            s.chars().count() <= "shell_exec ".len() + 80,
            "summary too long: {s}"
        );
    }

    #[test]
    fn wait_for_confirm_returns_the_answer() {
        let (tx, rx) = std::sync::mpsc::channel();
        tx.send(true).unwrap();
        let cancel = AtomicBool::new(false);
        assert_eq!(wait_for_confirm(&rx, &cancel), Some(true));
    }

    #[test]
    fn wait_for_confirm_none_on_cancel() {
        let (_tx, rx) = std::sync::mpsc::channel::<bool>();
        let cancel = AtomicBool::new(true);
        assert_eq!(wait_for_confirm(&rx, &cancel), None);
    }

    #[test]
    fn wait_for_confirm_none_when_sender_dropped() {
        let (tx, rx) = std::sync::mpsc::channel::<bool>();
        drop(tx);
        let cancel = AtomicBool::new(false);
        assert_eq!(wait_for_confirm(&rx, &cancel), None);
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

    fn write_tiny_png(path: &Path) {
        // 2×2 solid blue PNG built via the `image` crate (already a
        // dep). Keeps the test self-contained — no fixture file.
        let img = image::RgbImage::from_pixel(2, 2, image::Rgb([0, 0, 200]));
        image::DynamicImage::ImageRgb8(img)
            .save_with_format(path, image::ImageFormat::Png)
            .expect("write tiny PNG");
    }

    #[test]
    fn extract_no_directives_passes_through() {
        let dir = tempfile::tempdir().unwrap();
        let (cleaned, imgs, errs) = extract_image_attachments("Hello\nWorld", dir.path());
        assert_eq!(cleaned, "Hello\nWorld");
        assert!(imgs.is_empty());
        assert!(errs.is_empty());
    }

    #[test]
    fn extract_leading_image_directive_strips_and_loads() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("x.png");
        write_tiny_png(&png);
        let prompt = format!("\\image {}\nWhat do you see?", png.display());
        let (cleaned, imgs, errs) = extract_image_attachments(&prompt, dir.path());
        assert_eq!(cleaned, "What do you see?");
        assert_eq!(imgs.len(), 1);
        assert_eq!(imgs[0].media_type, "image/png");
        assert!(!imgs[0].base64_data.is_empty());
        assert!(errs.is_empty());
    }

    #[test]
    fn extract_image_directive_short_form_alias() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("x.png");
        write_tiny_png(&png);
        let prompt = format!("\\img {}\nWhat?", png.display());
        let (_, imgs, _) = extract_image_attachments(&prompt, dir.path());
        assert_eq!(imgs.len(), 1);
    }

    #[test]
    fn extract_multiple_directives() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.png");
        let b = dir.path().join("b.png");
        write_tiny_png(&a);
        write_tiny_png(&b);
        let prompt = format!(
            "\\image {}\n\\image {}\nCompare them",
            a.display(),
            b.display()
        );
        let (cleaned, imgs, errs) = extract_image_attachments(&prompt, dir.path());
        assert_eq!(cleaned, "Compare them");
        assert_eq!(imgs.len(), 2);
        assert!(errs.is_empty());
    }

    #[test]
    fn extract_only_honors_directives_at_the_top() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("x.png");
        write_tiny_png(&png);
        // `\image` mid-prompt should NOT be treated as a directive.
        let prompt = format!("hi\n\\image {}\nbye", png.display());
        let (cleaned, imgs, _) = extract_image_attachments(&prompt, dir.path());
        assert_eq!(cleaned, format!("hi\n\\image {}\nbye", png.display()));
        assert!(imgs.is_empty());
    }

    #[test]
    fn extract_relative_path_resolves_against_workspace() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("ws.png");
        write_tiny_png(&png);
        let prompt = "\\image ws.png\nQ".to_string();
        let (_, imgs, errs) = extract_image_attachments(&prompt, dir.path());
        assert_eq!(imgs.len(), 1, "errs: {errs:?}");
    }

    #[test]
    fn extract_missing_path_reports_error_without_killing_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let prompt = "\\image nope.png\nstill ok";
        let (cleaned, imgs, errs) = extract_image_attachments(prompt, dir.path());
        assert_eq!(cleaned, "still ok");
        assert!(imgs.is_empty());
        assert_eq!(errs.len(), 1);
        assert!(errs[0].contains("nope.png"));
    }

    #[test]
    fn load_image_rejects_unsupported_extension() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("x.tiff");
        std::fs::write(&f, b"fake").unwrap();
        let err = load_image(&f).unwrap_err();
        assert!(err.contains("unsupported extension"));
    }

    #[test]
    fn user_content_string_when_no_images() {
        let v = user_content("hello", &[]);
        assert_eq!(v, serde_json::Value::String("hello".to_string()));
    }

    #[test]
    fn user_content_array_when_images_present() {
        let img = ImageAttachment {
            media_type: "image/png".to_string(),
            base64_data: "AAA".to_string(),
        };
        let v = user_content("look at this", &[img]);
        let arr = v.as_array().expect("expected array");
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["type"], "image");
        assert_eq!(arr[0]["source"]["media_type"], "image/png");
        assert_eq!(arr[1]["type"], "text");
        assert_eq!(arr[1]["text"], "look at this");
    }

    #[test]
    fn user_content_image_only_omits_text_block() {
        let img = ImageAttachment {
            media_type: "image/png".to_string(),
            base64_data: "AAA".to_string(),
        };
        let v = user_content("", &[img]);
        let arr = v.as_array().expect("expected array");
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["type"], "image");
    }
}
