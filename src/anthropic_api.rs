//! Anthropic API client for the Managed Agents flow.
//! Supports two backends:
//!
//!   • **First-party Claude API** — `api.anthropic.com` +
//!     `x-api-key: $ANTHROPIC_API_KEY` (default).
//!   • **Claude Platform on AWS** — `aws-external-anthropic.<region>.api.aws`
//!     + `x-api-key: $ANTHROPIC_AWS_API_KEY` + `anthropic-workspace-id`
//!     header. Bills through AWS Marketplace.
//!
//! Backend chosen by `detect_backend()` based on env vars set:
//! `ANTHROPIC_AWS_API_KEY` + `AWS_REGION` + `ANTHROPIC_AWS_WORKSPACE_ID`
//! → AWS; else `ANTHROPIC_API_KEY` → first-party.
//!
//! SigV4 auth (the enterprise IAM path on Claude Platform on AWS)
//! is deferred to Phase 3b.2 — the `aws-sigv4` crate is a large
//! transitive dep, so it's gated behind detected need.
//!
//! All requests carry `anthropic-beta: managed-agents-2026-04-01`
//! and block. Use from a worker thread, never the UI thread.

use crate::http::{Request, send};

const BETA: &str = "managed-agents-2026-04-01";
const VERSION: &str = "2023-06-01";

#[derive(Debug, Clone)]
pub enum Backend {
    /// `api.anthropic.com` + ANTHROPIC_API_KEY.
    FirstParty { api_key: String },
    /// `aws-external-anthropic.<region>.api.aws` + ANTHROPIC_AWS_API_KEY
    /// + ANTHROPIC_AWS_WORKSPACE_ID header.
    ClaudePlatformAws {
        api_key: String,
        region: String,
        workspace_id: String,
    },
}

impl Backend {
    pub fn label(&self) -> &'static str {
        match self {
            Backend::FirstParty { .. } => "first-party Claude API",
            Backend::ClaudePlatformAws { .. } => "Claude Platform on AWS",
        }
    }

    /// Where to POST. Per-backend base URL.
    fn base(&self) -> String {
        match self {
            Backend::FirstParty { .. } => "https://api.anthropic.com".to_string(),
            Backend::ClaudePlatformAws { region, .. } => {
                format!("https://aws-external-anthropic.{region}.api.aws")
            }
        }
    }

    /// Headers for every API call.
    fn headers(&self) -> Vec<(String, String)> {
        let mut out = vec![
            ("anthropic-version".to_string(), VERSION.to_string()),
            ("anthropic-beta".to_string(), BETA.to_string()),
            ("content-type".to_string(), "application/json".to_string()),
        ];
        match self {
            Backend::FirstParty { api_key } => {
                out.push(("x-api-key".to_string(), api_key.clone()));
            }
            Backend::ClaudePlatformAws {
                api_key,
                workspace_id,
                ..
            } => {
                out.push(("x-api-key".to_string(), api_key.clone()));
                out.push(("anthropic-workspace-id".to_string(), workspace_id.clone()));
            }
        }
        out
    }
}

/// Pick the backend from env vars. Prefers AWS when its trio of
/// vars is set (user has actively chosen the AWS path);
/// otherwise falls back to first-party.
pub fn detect_backend() -> Result<Backend, String> {
    let aws_key = std::env::var("ANTHROPIC_AWS_API_KEY").ok();
    let aws_region = std::env::var("AWS_REGION")
        .ok()
        .or_else(|| std::env::var("AWS_DEFAULT_REGION").ok());
    let aws_workspace = std::env::var("ANTHROPIC_AWS_WORKSPACE_ID").ok();
    match (aws_key, aws_region, aws_workspace) {
        (Some(k), Some(r), Some(w)) if !k.is_empty() && !r.is_empty() && !w.is_empty() => {
            return Ok(Backend::ClaudePlatformAws {
                api_key: k,
                region: r,
                workspace_id: w,
            });
        }
        _ => {}
    }
    let first = std::env::var("ANTHROPIC_API_KEY")
        .map_err(|_| "no managed-agents auth found — set either ANTHROPIC_API_KEY (first-party) OR ANTHROPIC_AWS_API_KEY + AWS_REGION + ANTHROPIC_AWS_WORKSPACE_ID (Claude Platform on AWS)".to_string())?;
    if first.is_empty() {
        return Err("ANTHROPIC_API_KEY is empty".to_string());
    }
    Ok(Backend::FirstParty { api_key: first })
}

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
pub fn create_agent(
    backend: &Backend,
    name: &str,
    model: &str,
    system: &str,
) -> Result<Created, String> {
    let body = serde_json::json!({
        "name": name,
        "model": model,
        "system": system,
        "tools": [{"type": "agent_toolset_20260401"}],
    })
    .to_string();
    let req = Request {
        method: "POST".to_string(),
        url: format!("{}/v1/agents", backend.base()),
        headers: backend.headers(),
        body: Some(body),
    };
    let resp = send(&req).map_err(|e| format!("create_agent: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!("create_agent HTTP {}: {}", resp.status, resp.body));
    }
    Ok(Created {
        id: extract_id(&resp.body)?,
    })
}

/// `POST /v1/environments` — create a sandbox environment.
/// `config_kind` is `"cloud"` (Anthropic-managed sandbox) or
/// `"self_hosted"` (user runs a worker; environment key is
/// generated in the Console after creation, not via this API).
pub fn create_environment(
    backend: &Backend,
    name: &str,
    config_kind: &str,
) -> Result<Created, String> {
    let config = match config_kind {
        "cloud" => serde_json::json!({
            "type": "cloud",
            "networking": {"type": "unrestricted"},
        }),
        "self_hosted" => serde_json::json!({"type": "self_hosted"}),
        other => return Err(format!("unknown environment kind: {other}")),
    };
    let body = serde_json::json!({"name": name, "config": config}).to_string();
    let req = Request {
        method: "POST".to_string(),
        url: format!("{}/v1/environments", backend.base()),
        headers: backend.headers(),
        body: Some(body),
    };
    let resp = send(&req).map_err(|e| format!("create_environment: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!(
            "create_environment HTTP {}: {}",
            resp.status, resp.body
        ));
    }
    Ok(Created {
        id: extract_id(&resp.body)?,
    })
}

/// `POST /v1/sessions` — start a session.
pub fn create_session(
    backend: &Backend,
    agent_id: &str,
    environment_id: &str,
    initial_prompt: &str,
    title: &str,
) -> Result<CreatedSession, String> {
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
        url: format!("{}/v1/sessions", backend.base()),
        headers: backend.headers(),
        body: Some(body),
    };
    let resp = send(&req).map_err(|e| format!("create_session: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!(
            "create_session HTTP {}: {}",
            resp.status, resp.body
        ));
    }
    Ok(CreatedSession {
        id: extract_id(&resp.body)?,
        agent_id: agent_id.to_string(),
        environment_id: environment_id.to_string(),
    })
}

/// `GET /v1/sessions` — list active sessions for the workspace.
/// Used by the Cloud Agents panel to surface managed-agent rows
/// alongside Tattle QWE rows. Returns minimal fields — id, agent,
/// status, created_at — enough to render rows; detail pane fetches
/// per-session events separately.
#[allow(dead_code)] // Used by Phase 3b.3 (panel row source merging) — keep for the imminent follow-up.
#[derive(Debug, Clone)]
pub struct SessionSummary {
    pub id: String,
    pub title: Option<String>,
    pub status: String,
    pub created_at: Option<String>,
    pub agent_id: Option<String>,
    pub environment_id: Option<String>,
}

#[allow(dead_code)]
pub fn list_sessions(backend: &Backend) -> Result<Vec<SessionSummary>, String> {
    let req = Request {
        method: "GET".to_string(),
        url: format!("{}/v1/sessions?limit=50", backend.base()),
        headers: backend.headers(),
        body: None,
    };
    let resp = send(&req).map_err(|e| format!("list_sessions: {e}"))?;
    if resp.status < 200 || resp.status >= 300 {
        return Err(format!("list_sessions HTTP {}: {}", resp.status, resp.body));
    }
    let v: serde_json::Value =
        serde_json::from_str(&resp.body).map_err(|e| format!("list_sessions JSON: {e}"))?;
    let arr = v.get("data").and_then(|d| d.as_array());
    let Some(arr) = arr else {
        return Err(format!("list_sessions missing `data`: {}", resp.body));
    };
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        let Some(id) = item.get("id").and_then(|x| x.as_str()) else {
            continue;
        };
        let status = item
            .get("status")
            .and_then(|x| x.as_str())
            .unwrap_or("unknown")
            .to_string();
        let title = item.get("title").and_then(|x| x.as_str()).map(String::from);
        let created_at = item
            .get("created_at")
            .and_then(|x| x.as_str())
            .map(String::from);
        let agent_id = item
            .get("agent")
            .and_then(|x| x.get("id"))
            .and_then(|x| x.as_str())
            .or_else(|| item.get("agent").and_then(|x| x.as_str()))
            .map(String::from);
        let environment_id = item
            .get("environment_id")
            .and_then(|x| x.as_str())
            .map(String::from);
        out.push(SessionSummary {
            id: id.to_string(),
            title,
            status,
            created_at,
            agent_id,
            environment_id,
        });
    }
    Ok(out)
}
