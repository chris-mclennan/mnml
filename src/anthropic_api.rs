//! Anthropic API client for the Managed Agents flow.
//! Supports three backends, picked by `detect_backend()`:
//!
//!   • **First-party Claude API** — `api.anthropic.com` +
//!     `x-api-key: $ANTHROPIC_API_KEY`. The default. Native
//!     transport via `http::send`.
//!   • **Claude Platform on AWS (API key)** —
//!     `aws-external-anthropic.<region>.api.aws` +
//!     `x-api-key: $ANTHROPIC_AWS_API_KEY` +
//!     `anthropic-workspace-id`. Bills via AWS Marketplace. Use
//!     when running solo and OK managing a bearer key.
//!   • **Claude Platform on AWS (SigV4)** — same URL, but no
//!     `x-api-key`; auth via AWS SigV4 request signing using the
//!     AWS credential provider chain (env, ~/.aws/config, SSO,
//!     IMDS). Right choice for a team: CloudTrail per-user audit,
//!     IAM-controlled access, zero long-lived secrets. Transport
//!     shells out to `aws configure export-credentials` + `curl
//!     --aws-sigv4` (the SSE stream already uses curl, so this is
//!     cheaper than pulling the `aws-sigv4` crate in).
//!
//! Selection precedence:
//!   1. SigV4: `AWS_REGION` + `ANTHROPIC_AWS_WORKSPACE_ID` set,
//!      `ANTHROPIC_AWS_API_KEY` unset
//!   2. AWS API key: same trio + `ANTHROPIC_AWS_API_KEY` set
//!   3. First-party: `ANTHROPIC_API_KEY`
//!
//! All requests carry `anthropic-beta: managed-agents-2026-04-01`
//! and block. Use from a worker thread, never the UI thread.

use crate::http::{Request, send};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, Sender, channel};

const BETA: &str = "managed-agents-2026-04-01";
const VERSION: &str = "2023-06-01";

#[derive(Debug, Clone)]
pub enum Backend {
    /// `api.anthropic.com` + ANTHROPIC_API_KEY. Native HTTP via
    /// `http::send`.
    FirstParty { api_key: String },
    /// `aws-external-anthropic.<region>.api.aws` + ANTHROPIC_AWS_API_KEY
    /// + ANTHROPIC_AWS_WORKSPACE_ID header. Native HTTP via
    /// `http::send`. Simpler than SigV4 but requires a long-lived
    /// bearer key in env.
    ClaudePlatformAwsKey {
        api_key: String,
        region: String,
        workspace_id: String,
    },
    /// `aws-external-anthropic.<region>.api.aws` + AWS SigV4
    /// request signing. No long-lived secret in env — uses the
    /// AWS credential provider chain (env, ~/.aws/config, SSO,
    /// IMDS) via the `aws` CLI to fetch fresh credentials for
    /// every request. Right choice for a team — CloudTrail
    /// per-user audit, IAM-controlled access, no key sprawl.
    /// Transport: `curl --aws-sigv4` (the SSE stream already
    /// uses curl; the POSTs join it).
    ClaudePlatformAwsSigV4 {
        region: String,
        workspace_id: String,
    },
}

impl Backend {
    #[allow(dead_code)] // exposed for future "current backend" status chip
    pub fn label(&self) -> &'static str {
        match self {
            Backend::FirstParty { .. } => "first-party Claude API",
            Backend::ClaudePlatformAwsKey { .. } => "Claude Platform on AWS (API key)",
            Backend::ClaudePlatformAwsSigV4 { .. } => "Claude Platform on AWS (SigV4)",
        }
    }

    /// Where to POST. Per-backend base URL.
    pub fn base(&self) -> String {
        match self {
            Backend::FirstParty { .. } => "https://api.anthropic.com".to_string(),
            Backend::ClaudePlatformAwsKey { region, .. }
            | Backend::ClaudePlatformAwsSigV4 { region, .. } => {
                format!("https://aws-external-anthropic.{region}.api.aws")
            }
        }
    }

    /// Headers for every API call. SigV4 path adds Authorization
    /// later in curl — only the workspace + beta headers go here.
    pub fn headers(&self) -> Vec<(String, String)> {
        let mut out = vec![
            ("anthropic-version".to_string(), VERSION.to_string()),
            ("anthropic-beta".to_string(), BETA.to_string()),
            ("content-type".to_string(), "application/json".to_string()),
        ];
        match self {
            Backend::FirstParty { api_key } => {
                out.push(("x-api-key".to_string(), api_key.clone()));
            }
            Backend::ClaudePlatformAwsKey {
                api_key,
                workspace_id,
                ..
            } => {
                out.push(("x-api-key".to_string(), api_key.clone()));
                out.push(("anthropic-workspace-id".to_string(), workspace_id.clone()));
            }
            Backend::ClaudePlatformAwsSigV4 { workspace_id, .. } => {
                // No x-api-key — curl --aws-sigv4 will add the
                // Authorization header. anthropic-workspace-id
                // is signed in as a header so the request still
                // resolves to the right workspace.
                out.push(("anthropic-workspace-id".to_string(), workspace_id.clone()));
            }
        }
        out
    }

    /// True for paths where requests must shell out to curl
    /// (SigV4 path uses curl's native --aws-sigv4 support; the
    /// SSE stream uses curl regardless).
    fn is_sigv4(&self) -> bool {
        matches!(self, Backend::ClaudePlatformAwsSigV4 { .. })
    }
}

/// Run `aws configure export-credentials --format env` and parse
/// the AWS_* env vars from its stdout. This is the modern way to
/// pull credentials regardless of source (SSO, profile, env, IMDS)
/// — `aws` resolves the credential chain for us. Returns the
/// HashMap of env var → value, ready to pass to a Command.
fn aws_export_credentials() -> Result<Vec<(String, String)>, String> {
    let out = Command::new("aws")
        .args(["configure", "export-credentials", "--format", "env"])
        .output()
        .map_err(|e| format!("spawn `aws configure export-credentials`: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "`aws configure export-credentials` failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut creds = Vec::new();
    for line in text.lines() {
        // Format is `export AWS_FOO='bar'`; strip the `export `
        // prefix and the surrounding quotes.
        let line = line.trim();
        let rest = line.strip_prefix("export ").unwrap_or(line);
        let Some((k, v)) = rest.split_once('=') else {
            continue;
        };
        let v = v.trim_matches(|c| c == '\'' || c == '"');
        creds.push((k.to_string(), v.to_string()));
    }
    if !creds.iter().any(|(k, _)| k == "AWS_ACCESS_KEY_ID") {
        return Err(
            "no AWS_ACCESS_KEY_ID in aws export — credentials not available (run `aws sso login`?)"
                .to_string(),
        );
    }
    Ok(creds)
}

/// Run a request via `curl --aws-sigv4`. Returns body + status.
/// `method` is POST/GET; `url` is full; `headers` are key:value
/// pairs to forward; `body` is JSON (None for GET). Used by every
/// API call when `Backend::is_sigv4()`.
/// Look up a credential value from the parsed env list. Returns
/// empty string when missing — callers decide if absence is fatal.
fn cred(creds: &[(String, String)], key: &str) -> String {
    creds
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

fn curl_sigv4(
    region: &str,
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<&str>,
) -> Result<(u16, String), String> {
    let creds = aws_export_credentials()?;
    // curl --aws-sigv4 REQUIRES the access-key + secret-key pair
    // via --user. It does NOT read them from env (verified
    // against curl 8.x source: aws_sigv4.c). The session token
    // (SSO/STS) goes on the side via x-amz-security-token.
    let access = cred(&creds, "AWS_ACCESS_KEY_ID");
    let secret = cred(&creds, "AWS_SECRET_ACCESS_KEY");
    let session_token = cred(&creds, "AWS_SESSION_TOKEN");
    if access.is_empty() || secret.is_empty() {
        return Err("aws export-credentials returned no access key / secret".to_string());
    }
    let mut cmd = Command::new("curl");
    cmd.args([
        "-sS",
        "-X",
        method,
        "-w",
        "\n__HTTP_STATUS__%{http_code}",
        "--max-time",
        "30",
        "--aws-sigv4",
        &format!("aws:amz:{region}:aws-external-anthropic"),
        "--user",
    ]);
    cmd.arg(format!("{access}:{secret}"));
    if !session_token.is_empty() {
        cmd.arg("-H");
        cmd.arg(format!("x-amz-security-token: {session_token}"));
    }
    for (k, v) in headers {
        cmd.arg("-H");
        cmd.arg(format!("{k}: {v}"));
    }
    if let Some(b) = body {
        cmd.arg("--data-binary");
        cmd.arg(b);
    }
    cmd.arg(url);
    let out = cmd.output().map_err(|e| format!("spawn curl: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "curl failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let raw = String::from_utf8_lossy(&out.stdout).to_string();
    // Split off the trailing `\n__HTTP_STATUS__NNN` we asked curl
    // to append, leaving the body.
    let (body, status) = match raw.rsplit_once("\n__HTTP_STATUS__") {
        Some((b, s)) => (b.to_string(), s.parse::<u16>().unwrap_or(0)),
        None => (raw, 0),
    };
    Ok((status, body))
}

/// Dispatch a request to the right transport. FirstParty +
/// AwsKey go through http::send; SigV4 goes through curl.
fn dispatch(
    backend: &Backend,
    method: &str,
    path: &str,
    body: Option<String>,
) -> Result<(u16, String), String> {
    let url = format!("{}{}", backend.base(), path);
    if backend.is_sigv4() {
        let region = match backend {
            Backend::ClaudePlatformAwsSigV4 { region, .. } => region.clone(),
            _ => unreachable!(),
        };
        return curl_sigv4(&region, method, &url, &backend.headers(), body.as_deref());
    }
    let req = Request {
        method: method.to_string(),
        url,
        headers: backend.headers(),
        body,
    };
    let resp = send(&req).map_err(|e| format!("send: {e}"))?;
    Ok((resp.status, resp.body))
}

/// Pick the backend from env vars. Order of preference:
///
///   1. **SigV4** — `AWS_REGION` + `ANTHROPIC_AWS_WORKSPACE_ID` set
///      AND no `ANTHROPIC_AWS_API_KEY`. Best for teams: CloudTrail
///      audit per IAM principal, no long-lived keys.
///   2. **AWS API key** — same trio + `ANTHROPIC_AWS_API_KEY` set.
///      Simpler than SigV4, useful for solo dev.
///   3. **First-party** — falls back to `ANTHROPIC_API_KEY`.
///
/// To force SigV4 even when a bearer key is set, unset
/// `ANTHROPIC_AWS_API_KEY`. To force AWS API key, set it.
pub fn detect_backend() -> Result<Backend, String> {
    let aws_key = std::env::var("ANTHROPIC_AWS_API_KEY").ok();
    let aws_region = std::env::var("AWS_REGION")
        .ok()
        .or_else(|| std::env::var("AWS_DEFAULT_REGION").ok());
    let aws_workspace = std::env::var("ANTHROPIC_AWS_WORKSPACE_ID").ok();
    let region_ok = aws_region
        .as_deref()
        .map(|s| !s.is_empty())
        .unwrap_or(false);
    let workspace_ok = aws_workspace
        .as_deref()
        .map(|s| !s.is_empty())
        .unwrap_or(false);
    let key_set = aws_key.as_deref().map(|s| !s.is_empty()).unwrap_or(false);
    if region_ok && workspace_ok {
        let region = aws_region.unwrap();
        let workspace_id = aws_workspace.unwrap();
        if key_set {
            return Ok(Backend::ClaudePlatformAwsKey {
                api_key: aws_key.unwrap(),
                region,
                workspace_id,
            });
        }
        return Ok(Backend::ClaudePlatformAwsSigV4 {
            region,
            workspace_id,
        });
    }
    let first = std::env::var("ANTHROPIC_API_KEY")
        .map_err(|_| "no managed-agents auth found — set ANTHROPIC_API_KEY (first-party), OR AWS_REGION + ANTHROPIC_AWS_WORKSPACE_ID (Claude Platform on AWS via SigV4), optionally + ANTHROPIC_AWS_API_KEY (AWS API key auth)".to_string())?;
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
    #[allow(dead_code)]
    pub agent_id: String,
    #[allow(dead_code)]
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
    let (status, body) = dispatch(backend, "POST", "/v1/agents", Some(body))
        .map_err(|e| format!("create_agent: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(format!("create_agent HTTP {status}: {body}"));
    }
    Ok(Created {
        id: extract_id(&body)?,
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
    let (status, body) = dispatch(backend, "POST", "/v1/environments", Some(body))
        .map_err(|e| format!("create_environment: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(format!("create_environment HTTP {status}: {body}"));
    }
    Ok(Created {
        id: extract_id(&body)?,
    })
}

/// `POST /v1/sessions` — provision a session (sandbox boots, but
/// no work runs yet). To actually start the agent, follow up with
/// `send_user_message`. Per the docs: "Creating a session
/// provisions the environment's sandbox but does not start any
/// work. To delegate a task, send events to the session using a
/// user event."
pub fn create_session(
    backend: &Backend,
    agent_id: &str,
    environment_id: &str,
    title: &str,
) -> Result<CreatedSession, String> {
    let body = serde_json::json!({
        "agent": agent_id,
        "environment_id": environment_id,
        "title": title,
    })
    .to_string();
    let (status, body) = dispatch(backend, "POST", "/v1/sessions", Some(body))
        .map_err(|e| format!("create_session: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(format!("create_session HTTP {status}: {body}"));
    }
    Ok(CreatedSession {
        id: extract_id(&body)?,
        agent_id: agent_id.to_string(),
        environment_id: environment_id.to_string(),
    })
}

/// `POST /v1/sessions/{id}/events` — send a user message into an
/// existing session. This is the step that actually transitions
/// the session from `idle` to `running` and produces output.
pub fn send_user_message(backend: &Backend, session_id: &str, text: &str) -> Result<(), String> {
    let body = serde_json::json!({
        "events": [{
            "type": "user.message",
            "content": [{"type": "text", "text": text}],
        }],
    })
    .to_string();
    let path = format!("/v1/sessions/{session_id}/events");
    let (status, body) = dispatch(backend, "POST", &path, Some(body))
        .map_err(|e| format!("send_user_message: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(format!("send_user_message HTTP {status}: {body}"));
    }
    Ok(())
}

/// `GET /v1/sessions` — list active sessions for the workspace.
/// Used by the Cloud Agents panel to surface managed-agent rows
/// alongside Tattle QWE rows. Returns minimal fields — id, agent,
/// status, created_at — enough to render rows; detail pane fetches
/// per-session events separately.
#[derive(Debug, Clone)]
pub struct SessionSummary {
    pub id: String,
    pub title: Option<String>,
    pub status: String,
    /// Reserved for sort-by-recency in a follow-up.
    #[allow(dead_code)]
    pub created_at: Option<String>,
    /// Reserved for cross-reference with `list_agents()` in a follow-up.
    #[allow(dead_code)]
    pub agent_id: Option<String>,
    /// Reserved for grouping rows by environment in a follow-up.
    #[allow(dead_code)]
    pub environment_id: Option<String>,
}

pub fn list_sessions(backend: &Backend) -> Result<Vec<SessionSummary>, String> {
    let (status, body) = dispatch(backend, "GET", "/v1/sessions?limit=50", None)
        .map_err(|e| format!("list_sessions: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(format!("list_sessions HTTP {status}: {body}"));
    }
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("list_sessions JSON: {e}"))?;
    let arr = v.get("data").and_then(|d| d.as_array());
    let Some(arr) = arr else {
        return Err(format!("list_sessions missing `data`: {body}"));
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

/// One event emitted by the session-stream worker. Mapped from
/// the SSE `data:` JSON lines `/v1/sessions/{id}/stream` returns.
/// Per docs, event `type` is one of `agent.message`,
/// `agent.tool_use`, `agent.tool_result`, `session.status_*`,
/// `user.message`, etc. We collapse them into a tiny shape so
/// the existing log-viewport renderer can show them line-by-line.
#[derive(Debug, Clone)]
pub enum SessionStreamEvent {
    /// One rendered text/tool line. UI shows this verbatim.
    Line(String),
    /// Stream closed by Anthropic — session reached idle / ended.
    Done,
    /// curl exited non-zero or refused to start.
    Error(String),
}

/// Spawn a worker thread that streams `/v1/sessions/{id}/stream`
/// via curl (mnml's http::send is sync only, so we shell out).
/// Returns the consumer end of a channel; caller drains on tick.
///
/// The worker does its own backend detection so the UI thread
/// never blocks on env-var lookup. On any auth-missing /
/// network failure it sends a single Error event and exits.
pub fn spawn_session_event_stream(session_id: String) -> Receiver<SessionStreamEvent> {
    let (tx, rx) = channel::<SessionStreamEvent>();
    std::thread::spawn(move || {
        let backend = match detect_backend() {
            Ok(b) => b,
            Err(e) => {
                let _ = tx.send(SessionStreamEvent::Error(format!("backend: {e}")));
                return;
            }
        };
        let url = format!("{}/v1/sessions/{}/stream", backend.base(), session_id);
        let mut args: Vec<String> = vec![
            "-sS".to_string(),
            "-N".to_string(),
            "-H".to_string(),
            "Accept: text/event-stream".to_string(),
        ];
        // SigV4 path: add --aws-sigv4 + --user (curl requires the
        // pair via --user, not env) + x-amz-security-token header
        // if there's an STS session token. Same shape as
        // curl_sigv4 — only difference is `-N` for SSE.
        if let Backend::ClaudePlatformAwsSigV4 { region, .. } = &backend {
            let creds = match aws_export_credentials() {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(SessionStreamEvent::Error(format!(
                        "aws export-credentials: {e}"
                    )));
                    return;
                }
            };
            let access = cred(&creds, "AWS_ACCESS_KEY_ID");
            let secret = cred(&creds, "AWS_SECRET_ACCESS_KEY");
            let session_token = cred(&creds, "AWS_SESSION_TOKEN");
            if access.is_empty() || secret.is_empty() {
                let _ = tx.send(SessionStreamEvent::Error(
                    "aws export-credentials: missing access key / secret".to_string(),
                ));
                return;
            }
            args.push("--aws-sigv4".to_string());
            args.push(format!("aws:amz:{region}:aws-external-anthropic"));
            args.push("--user".to_string());
            args.push(format!("{access}:{secret}"));
            if !session_token.is_empty() {
                args.push("-H".to_string());
                args.push(format!("x-amz-security-token: {session_token}"));
            }
        }
        for (k, v) in backend.headers() {
            args.push("-H".to_string());
            args.push(format!("{k}: {v}"));
        }
        args.push(url);
        let mut cmd = Command::new("curl");
        cmd.args(&args).stdout(Stdio::piped()).stdin(Stdio::null());
        match cmd.spawn() {
            Ok(mut child) => {
                let stdout = match child.stdout.take() {
                    Some(s) => s,
                    None => {
                        let _ = tx.send(SessionStreamEvent::Error(
                            "curl produced no stdout".to_string(),
                        ));
                        return;
                    }
                };
                let reader = BufReader::new(stdout);
                let _ = run_sse_reader(reader, &tx);
                let _ = child.wait();
                let _ = tx.send(SessionStreamEvent::Done);
            }
            Err(e) => {
                let _ = tx.send(SessionStreamEvent::Error(format!("spawn curl: {e}")));
            }
        }
    });
    rx
}

/// Read the curl stdout line-by-line. SSE format is `data: <json>`
/// blocks separated by blank lines. We pluck the JSON, extract
/// a renderable line per event type, send to the channel.
fn run_sse_reader<R: BufRead>(reader: R, tx: &Sender<SessionStreamEvent>) -> std::io::Result<()> {
    for line in reader.lines() {
        let line = line?;
        let Some(payload) = line.strip_prefix("data: ") else {
            continue;
        };
        let v: serde_json::Value = match serde_json::from_str(payload) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let rendered = render_stream_event(&v);
        if !rendered.is_empty() && tx.send(SessionStreamEvent::Line(rendered)).is_err() {
            // Receiver dropped — nothing to do but stop.
            break;
        }
    }
    Ok(())
}

/// Turn one parsed SSE event into a renderable log line. Returns
/// empty string for events we don't surface (e.g. heartbeat).
/// Kept liberal: unknown event types still pass through as
/// `[type]` so a docs change won't silently drop them.
fn render_stream_event(v: &serde_json::Value) -> String {
    let ty = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
    match ty {
        "agent.message" => v
            .get("content")
            .and_then(|c| c.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_default(),
        "agent.tool_use" => {
            let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("?");
            format!("[tool {name}]")
        }
        "agent.tool_result" => {
            let ok = v
                .get("is_error")
                .and_then(|x| x.as_bool())
                .map(|b| !b)
                .unwrap_or(true);
            if ok {
                "[tool ok]".to_string()
            } else {
                "[tool error]".to_string()
            }
        }
        "user.message" => v
            .get("content")
            .and_then(|c| c.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .filter(|s| !s.is_empty())
            .map(|s| format!("[user] {s}"))
            .unwrap_or_default(),
        "session.status_idle" => "[idle]".to_string(),
        "session.status_run_started" => "[run started]".to_string(),
        "session.status_run_completed" => "[run completed]".to_string(),
        "session.status_run_failed" => "[run FAILED]".to_string(),
        "" => String::new(),
        other => format!("[{other}]"),
    }
}

/// Strip the tagged prefix off an Anthropic id (e.g.
/// `env_01HqR2k7vXbZ9mNpL3wYcT8f` → `env_…7vXbZ9mNpL3wYcT8f`)
/// so it fits the panel's narrow workspace column. Keeps the
/// type tag for readability.
fn short_id(id: &str) -> String {
    let n = id.chars().count();
    if n <= 14 {
        return id.to_string();
    }
    let prefix: String = id.chars().take(4).collect();
    let suffix: String = id.chars().skip(n.saturating_sub(8)).collect();
    format!("{prefix}…{suffix}")
}

/// Collect Managed Agents sessions for the Cloud Agents panel.
/// Returns rows in the same `AgentRow` shape as the Tattle QWE
/// scan, so the panel renderer can mix them. On any failure
/// (missing creds, network, API error) returns an empty vec —
/// matches the Tattle scan's silent-fallback shape so a missing
/// backend doesn't blow up the panel.
pub fn collect_managed_agent_rows() -> Vec<crate::claude_agents::AgentRow> {
    use crate::claude_agents::{AgentRow, AgentSource, AgentState};
    use std::path::PathBuf;
    let backend = match detect_backend() {
        Ok(b) => b,
        Err(_) => return Vec::new(),
    };
    let sessions = match list_sessions(&backend) {
        Ok(s) => s,
        Err(e) => {
            // Silent — list_sessions runs from the rail
            // refresh worker every 30s; printing to stderr
            // would corrupt the TUI. The empty-vec fallback
            // matches the Tattle scan's behavior so the panel
            // just stays empty if the backend isn't configured.
            let _ = e;
            return Vec::new();
        }
    };
    sessions
        .into_iter()
        .map(|s| {
            // Map Anthropic session status → mnml AgentState.
            // Status strings per docs: pending, in_progress,
            // idle, completed, failed, cancelled.
            let state = match s.status.as_str() {
                "in_progress" => AgentState::Streaming,
                "pending" => AgentState::ToolCall,
                "idle" => AgentState::Idle,
                "completed" | "failed" | "cancelled" => AgentState::Ended,
                _ => AgentState::Idle,
            };
            // Workspace column shows the env id (where the
            // session runs) so user can tell at a glance which
            // env it belongs to. Title goes to last_assistant_msg
            // (the right column).
            let workspace = s
                .environment_id
                .clone()
                .filter(|e| !e.is_empty())
                .map(|e| short_id(&e))
                .unwrap_or_else(|| "managed".to_string());
            AgentRow {
                source: AgentSource::AnthropicManaged,
                transcript_path: PathBuf::from(format!("/dev/null/managed/{}", s.id)),
                session_id: s.id,
                workspace,
                cwd: None,
                git_branch: None,
                model: None,
                last_activity: None,
                tokens: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_create_tokens: 0,
                cache_read_tokens: 0,
                cost_usd: 0.0,
                event_count: 0,
                last_user_msg: None,
                last_assistant_msg: s.title.or_else(|| Some(s.status.clone())),
                pid: None,
                state,
                current_tool: None,
                todos: Vec::new(),
                recent_bash: Vec::new(),
                recent_files: Vec::new(),
                recent_subagents: Vec::new(),
                pending_tool_uses: 0,
                tokens_per_min: None,
            }
        })
        .collect()
}
