//! Minimal Anthropic API client for the Managed Agents flow.
//! Only what the Cloud Agents wizard needs in Phase 3a:
//!   • POST /v1/agents       — create a reusable agent config
//!   • POST /v1/environments — create a sandbox environment
//!   • POST /v1/sessions     — start a session against agent+env
//!
//! All requests carry `anthropic-beta: managed-agents-2026-04-01`
//! and authenticate via `x-api-key: $ANTHROPIC_API_KEY`. Calls
//! block (use from a worker thread, never the UI thread).

use crate::http::{Request, send};

const BASE: &str = "https://api.anthropic.com";
const BETA: &str = "managed-agents-2026-04-01";
const VERSION: &str = "2023-06-01";

#[derive(Debug)]
pub struct Created {
    pub id: String,
}

#[derive(Debug)]
pub struct CreatedSession {
    pub id: String,
    pub agent_id: String,
    pub environment_id: String,
}

fn api_key() -> Result<String, String> {
    std::env::var("ANTHROPIC_API_KEY").map_err(|_| "ANTHROPIC_API_KEY env var not set".to_string())
}

fn headers(api_key: &str) -> Vec<(String, String)> {
    vec![
        ("x-api-key".to_string(), api_key.to_string()),
        ("anthropic-version".to_string(), VERSION.to_string()),
        ("anthropic-beta".to_string(), BETA.to_string()),
        ("content-type".to_string(), "application/json".to_string()),
    ]
}

fn extract_id(body: &str) -> Result<String, String> {
    // Tiny ad-hoc JSON peek for `"id": "…"` — avoids dragging in
    // full serde_json for this one field. The response from
    // Anthropic always has `id` as a top-level string.
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| format!("response JSON parse: {e}"))?;
    v.get("id")
        .and_then(|x| x.as_str())
        .map(str::to_string)
        .ok_or_else(|| format!("response missing `id` field: {body}"))
}

/// `POST /v1/agents` — create a reusable agent configuration.
/// `name` is human-readable; `model` is e.g. `"claude-opus-4-8"`;
/// `system` is the system prompt.
pub fn create_agent(name: &str, model: &str, system: &str) -> Result<Created, String> {
    let key = api_key()?;
    let body = serde_json::json!({
        "name": name,
        "model": model,
        "system": system,
        "tools": [{"type": "agent_toolset_20260401"}],
    })
    .to_string();
    let req = Request {
        method: "POST".to_string(),
        url: format!("{BASE}/v1/agents"),
        headers: headers(&key),
        body: Some(body),
    };
    let resp = send(&req).map_err(|e| format!("create_agent: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!("create_agent HTTP {}: {}", resp.status, resp.body));
    }
    let id = extract_id(&resp.body)?;
    Ok(Created { id })
}

/// `POST /v1/environments` — create a sandbox environment.
/// `config_kind` is `"cloud"` (Anthropic-managed sandbox) or
/// `"self_hosted"` (user runs a worker; user generates the
/// environment key in Console after creation).
pub fn create_environment(name: &str, config_kind: &str) -> Result<Created, String> {
    let key = api_key()?;
    let config = match config_kind {
        "cloud" => serde_json::json!({
            "type": "cloud",
            "networking": {"type": "unrestricted"},
        }),
        "self_hosted" => serde_json::json!({"type": "self_hosted"}),
        other => {
            return Err(format!("unknown environment kind: {other}"));
        }
    };
    let body = serde_json::json!({
        "name": name,
        "config": config,
    })
    .to_string();
    let req = Request {
        method: "POST".to_string(),
        url: format!("{BASE}/v1/environments"),
        headers: headers(&key),
        body: Some(body),
    };
    let resp = send(&req).map_err(|e| format!("create_environment: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!(
            "create_environment HTTP {}: {}",
            resp.status, resp.body
        ));
    }
    let id = extract_id(&resp.body)?;
    Ok(Created { id })
}

/// `POST /v1/sessions` — start a session. The session enters the
/// environment's work queue; if `environment.type == cloud`, it
/// runs on Anthropic's infra; if `self_hosted`, the user's
/// worker poller claims it.
pub fn create_session(
    agent_id: &str,
    environment_id: &str,
    initial_prompt: &str,
    title: &str,
) -> Result<CreatedSession, String> {
    let key = api_key()?;
    let body = serde_json::json!({
        "agent": agent_id,
        "environment_id": environment_id,
        "title": title,
        "initial_events": [{
            "type": "user.message",
            "content": [{"type": "text", "text": initial_prompt}],
        }],
    })
    .to_string();
    let req = Request {
        method: "POST".to_string(),
        url: format!("{BASE}/v1/sessions"),
        headers: headers(&key),
        body: Some(body),
    };
    let resp = send(&req).map_err(|e| format!("create_session: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!(
            "create_session HTTP {}: {}",
            resp.status, resp.body
        ));
    }
    let id = extract_id(&resp.body)?;
    Ok(CreatedSession {
        id,
        agent_id: agent_id.to_string(),
        environment_id: environment_id.to_string(),
    })
}
