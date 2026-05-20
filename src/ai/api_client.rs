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
//! Tool use is NOT wired in this MVP — the request payload doesn't
//! include `tools[]`, so the model can't read files or run shell. For
//! agentic flows the user still wants the CLI backend (`claude -p` runs
//! the full agent loop). Direct-API shines for short asks: commit
//! messages, "explain this", "refactor to do X".

use std::io::{BufRead, BufReader};
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
pub fn complete_code(prefix: &str, suffix: &str, language: &str) -> Result<String, String> {
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
        "model": COMPLETION_MODEL,
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
}
