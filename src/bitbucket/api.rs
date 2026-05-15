//! Bitbucket Cloud REST API plumbing. Plain HTTPS via `reqwest::blocking`
//! (already in the dep tree for the `http` track) — no Bitbucket SDK.
//!
//! Endpoints used so far:
//! * `GET /2.0/repositories/{workspace}/{slug}/pipelines/?sort=-created_on&pagelen=N` (phase 1)
//! * `GET /2.0/repositories/{workspace}/{slug}/pullrequests?state=OPEN&pagelen=N` (phase 3)
//!
//! Endpoints planned for phase 4 polish (not yet wired):
//! * `GET /2.0/repositories/{ws}/{slug}/pullrequests/{id}/statuses` — build
//!   status chips on the PR's head commit (Bitbucket Pipelines build state
//!   per check).
//!
//! Auth: `Bearer <token>` for the modern API-token format (recommended
//! after Bitbucket's 2024 deprecation of App Passwords). Values containing
//! `:` are routed through Basic auth instead so existing `user:app_password`
//! pairs keep working until a team can rotate to tokens. Token never lives
//! in config files — sourced from `$BITBUCKET_TOKEN` (or
//! `[bitbucket] auth_env = "..."` to override).

use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;

use crate::config::BitbucketRepo;

const API_BASE: &str = "https://api.bitbucket.org/2.0";

/// Max pipelines to ask the API for per repo per poll. Bitbucket's default
/// is 10; 20 is more useful for spotting a recent failure pattern without
/// being expensive.
const PAGELEN: u32 = 20;

const HTTP_TIMEOUT: Duration = Duration::from_secs(20);

/// Build one `reqwest::blocking::Client` reused across every API call for
/// the lifetime of the worker. Connection pooling + DNS cache => much less
/// per-poll overhead than building a fresh client every time.
pub fn build_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())
}

/// Convert the raw token (Bearer-style API token OR legacy `user:password`
/// app-password pair) into the value for the `Authorization` header.
/// Detection: a single `:` ⇒ Basic; everything else ⇒ Bearer.
///
/// Cached per-spawn — the value is identical for every request the worker
/// makes, so we compute it once and clone the String per call.
pub fn auth_header_value(token: &str) -> String {
    let trimmed = token.trim();
    if trimmed.contains(':') {
        format!("Basic {}", BASE64.encode(trimmed))
    } else {
        format!("Bearer {trimmed}")
    }
}

/// Pull every open pull request for one repo (most teams have ≤50 open
/// at a time; we cap at `PAGELEN` to keep payloads small). Newest-first
/// by `updated_on` (Bitbucket's default sort for pullrequests).
pub fn fetch_open_pull_requests(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &BitbucketRepo,
) -> Result<Vec<PullRequestRecord>, String> {
    let url = format!(
        "{API_BASE}/repositories/{ws}/{slug}/pullrequests?state=OPEN&pagelen={PAGELEN}",
        ws = repo.workspace,
        slug = repo.slug,
    );
    let resp = client
        .get(&url)
        .header("Authorization", auth_header)
        .header("Accept", "application/json")
        .send()
        .map_err(|e| format!("send: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().unwrap_or_default();
        let snippet = body.chars().take(200).collect::<String>();
        return Err(format!("HTTP {status} — {snippet}"));
    }
    let body = resp.text().map_err(|e| format!("read body: {e}"))?;
    parse_pull_requests_response(&body, &repo.workspace, &repo.slug)
}

pub fn parse_pull_requests_response(
    body: &str,
    workspace: &str,
    slug: &str,
) -> Result<Vec<PullRequestRecord>, String> {
    let raw: RawPrPage =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    let out = raw
        .values
        .into_iter()
        .map(|p| project_pr(p, workspace, slug))
        .collect();
    Ok(out)
}

fn project_pr(p: RawPullRequest, workspace: &str, slug: &str) -> PullRequestRecord {
    let state = PullRequestState::from_raw(p.state.as_deref());
    let updated_on_ms = p.updated_on.as_deref().and_then(parse_iso_ms);
    let created_on_ms = p.created_on.as_deref().and_then(parse_iso_ms);
    let source_branch = p
        .source
        .as_ref()
        .and_then(|s| s.branch.as_ref())
        .and_then(|b| b.name.clone());
    let dest_branch = p
        .destination
        .as_ref()
        .and_then(|d| d.branch.as_ref())
        .and_then(|b| b.name.clone());
    let author = p
        .author
        .as_ref()
        .and_then(|a| a.display_name.clone());
    // Bitbucket's "participants" list carries per-reviewer state. We surface:
    //   - approved_count   — `approved: true`
    //   - changes_count    — `state: "changes_requested"`
    //   - reviewer_count   — every participant whose role is "REVIEWER"
    let mut approved_count = 0u32;
    let mut changes_count = 0u32;
    let mut reviewer_count = 0u32;
    for part in p.participants.iter().flatten() {
        let role = part.role.as_deref().unwrap_or("").to_ascii_uppercase();
        if role == "REVIEWER" {
            reviewer_count += 1;
        }
        if part.approved.unwrap_or(false) {
            approved_count += 1;
        }
        if part
            .state
            .as_deref()
            .map(|s| s.eq_ignore_ascii_case("changes_requested"))
            .unwrap_or(false)
        {
            changes_count += 1;
        }
    }
    let web_url = p
        .links
        .as_ref()
        .and_then(|l| l.html.as_ref())
        .and_then(|h| h.href.clone())
        .unwrap_or_else(|| {
            format!(
                "https://bitbucket.org/{ws}/{slug}/pull-requests/{n}",
                ws = workspace,
                slug = slug,
                n = p.id.unwrap_or(0),
            )
        });
    PullRequestRecord {
        workspace: workspace.to_string(),
        slug: slug.to_string(),
        id: p.id.unwrap_or(0),
        title: p.title.unwrap_or_default(),
        state,
        author,
        source_branch,
        dest_branch,
        reviewer_count,
        approved_count,
        changes_count,
        comment_count: p.comment_count.unwrap_or(0),
        task_count: p.task_count.unwrap_or(0),
        created_on_ms,
        updated_on_ms,
        web_url,
    }
}

/// Pull the most-recent `PAGELEN` pipelines for one repo. Returned in
/// newest-first order (the same order the API returns when we ask for
/// `sort=-created_on`).
///
/// Errors carry a short user-facing string; the worker prefixes the
/// repo path before forwarding to the channel so the pane can group by
/// repo when surfacing banners.
pub fn fetch_recent_pipelines(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &BitbucketRepo,
) -> Result<Vec<PipelineRecord>, String> {
    let url = format!(
        "{API_BASE}/repositories/{ws}/{slug}/pipelines/?sort=-created_on&pagelen={PAGELEN}",
        ws = repo.workspace,
        slug = repo.slug,
    );
    let resp = client
        .get(&url)
        .header("Authorization", auth_header)
        .header("Accept", "application/json")
        .send()
        .map_err(|e| format!("send: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        // Pull a short snippet of the body for context — Bitbucket's
        // error JSON usually has a useful "error.message" field but we
        // don't want to pull serde_json for just that.
        let body = resp.text().unwrap_or_default();
        let snippet = body.chars().take(200).collect::<String>();
        return Err(format!("HTTP {status} — {snippet}"));
    }
    let body = resp.text().map_err(|e| format!("read body: {e}"))?;
    parse_pipelines_response(&body, &repo.workspace, &repo.slug)
}

/// Parsed projection of a Bitbucket Cloud `pipelines/` list response.
/// Public for unit-test access; not part of the worker's external surface.
pub fn parse_pipelines_response(
    body: &str,
    workspace: &str,
    slug: &str,
) -> Result<Vec<PipelineRecord>, String> {
    let raw: RawPipelinesPage =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    let out = raw
        .values
        .into_iter()
        .map(|p| project_pipeline(p, workspace, slug))
        .collect();
    Ok(out)
}

fn project_pipeline(p: RawPipeline, workspace: &str, slug: &str) -> PipelineRecord {
    let state = PipelineState::from_raw(&p.state);
    let created_on_ms = p.created_on.as_deref().and_then(parse_iso_ms);
    let completed_on_ms = p.completed_on.as_deref().and_then(parse_iso_ms);
    let duration_secs = p
        .duration_in_seconds
        .or_else(|| match (created_on_ms, completed_on_ms) {
            (Some(s), Some(e)) if e >= s => Some(((e - s) / 1000) as u64),
            _ => None,
        });
    let target_ref = p
        .target
        .as_ref()
        .and_then(|t| t.ref_name.clone().or_else(|| t.branch.clone()));
    let target_kind = p
        .target
        .as_ref()
        .and_then(|t| t.ref_type.clone().or_else(|| t.r#type.clone()));
    let commit_hash = p
        .target
        .as_ref()
        .and_then(|t| t.commit.as_ref())
        .and_then(|c| c.hash.clone());
    let creator = p.creator.as_ref().and_then(|c| c.display_name.clone());
    let trigger = p.trigger.as_ref().and_then(|t| t.name.clone());
    let web_url = p
        .links
        .as_ref()
        .and_then(|l| l.html.as_ref())
        .and_then(|h| h.href.clone())
        .unwrap_or_else(|| {
            // Fallback: synthesize the dashboard URL from the build number.
            // Useful for tests; real responses include the `html.href`.
            format!(
                "https://bitbucket.org/{ws}/{slug}/addon/pipelines/home#!/results/{n}",
                ws = workspace,
                slug = slug,
                n = p.build_number.unwrap_or(0),
            )
        });

    PipelineRecord {
        workspace: workspace.to_string(),
        slug: slug.to_string(),
        uuid: p.uuid.unwrap_or_default(),
        build_number: p.build_number.unwrap_or(0),
        state,
        target_ref,
        target_kind,
        commit_hash,
        creator,
        trigger,
        created_on_ms,
        completed_on_ms,
        duration_secs,
        web_url,
    }
}

// ─── Public projected types ────────────────────────────────────────────

/// One row in the future `Pane::BitbucketPipelines` — a Bitbucket Cloud
/// pipeline record projected to the fields the IDE actually renders.
#[derive(Debug, Clone)]
pub struct PipelineRecord {
    pub workspace: String,
    pub slug: String,
    pub uuid: String,
    pub build_number: u64,
    pub state: PipelineState,
    /// `main`, `release/2026.05`, etc. when the target is a branch/tag.
    pub target_ref: Option<String>,
    /// `"branch"` / `"named_branch"` / `"tag"` / `"commit"`.
    pub target_kind: Option<String>,
    /// 40-hex commit SHA, when the API surfaced one.
    pub commit_hash: Option<String>,
    /// Display name of whoever (or what bot) kicked off the run.
    pub creator: Option<String>,
    /// `"PUSH"`, `"MANUAL"`, `"SCHEDULE"`, `"PULLREQUEST"`, …
    pub trigger: Option<String>,
    /// UNIX epoch ms — sortable, formatted at render.
    pub created_on_ms: Option<i64>,
    pub completed_on_ms: Option<i64>,
    /// Server-reported duration when available, else derived from
    /// (completed_on - created_on). `None` for still-running pipelines.
    pub duration_secs: Option<u64>,
    /// Bitbucket UI link (the dashboard's `#!/results/N` page).
    pub web_url: String,
}

/// Unified pipeline state — folds Bitbucket's two-level
/// `state.name` + `state.result.name` into one enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipelineState {
    Successful,
    Failed,
    Error,
    Stopped,
    Expired,
    InProgress,
    Pending,
    Paused,
    Halted,
    Unknown,
}

impl PipelineState {
    fn from_raw(raw: &Option<RawState>) -> Self {
        let Some(s) = raw else {
            return Self::Unknown;
        };
        let name = s.name.as_deref().unwrap_or("").to_ascii_uppercase();
        let result = s
            .result
            .as_ref()
            .and_then(|r| r.name.as_deref())
            .unwrap_or("")
            .to_ascii_uppercase();
        // Outer state first so an in-progress run isn't accidentally
        // classified by a stale `result` field.
        match name.as_str() {
            "IN_PROGRESS" => Self::InProgress,
            "PENDING" => Self::Pending,
            "PAUSED" => Self::Paused,
            "HALTED" => Self::Halted,
            "COMPLETED" => match result.as_str() {
                "SUCCESSFUL" => Self::Successful,
                "FAILED" => Self::Failed,
                "ERROR" => Self::Error,
                "STOPPED" => Self::Stopped,
                "EXPIRED" => Self::Expired,
                _ => Self::Unknown,
            },
            _ => Self::Unknown,
        }
    }
    pub fn glyph(self) -> &'static str {
        match self {
            Self::Successful => "✓",
            Self::Failed => "✗",
            Self::Error => "‼",
            Self::Stopped => "⊘",
            Self::Expired => "⏱",
            Self::InProgress => "⏵",
            Self::Pending => "·",
            Self::Paused => "⏸",
            Self::Halted => "⏹",
            Self::Unknown => "?",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Successful => "succeeded",
            Self::Failed => "failed",
            Self::Error => "error",
            Self::Stopped => "stopped",
            Self::Expired => "expired",
            Self::InProgress => "running",
            Self::Pending => "pending",
            Self::Paused => "paused",
            Self::Halted => "halted",
            Self::Unknown => "unknown",
        }
    }
    /// `true` while the pipeline could still finish — the pane fast-polls
    /// these so the user sees the transition without waiting for the next
    /// regular poll cycle.
    pub fn is_terminal(self) -> bool {
        !matches!(self, Self::InProgress | Self::Pending | Self::Paused)
    }
}

// ─── Pull-request types ────────────────────────────────────────────────

/// One row in `Pane::BitbucketPullRequests`. Projects the
/// `/pullrequests/` v2 payload to the fields the pane renders.
#[derive(Debug, Clone)]
pub struct PullRequestRecord {
    pub workspace: String,
    pub slug: String,
    pub id: u64,
    pub title: String,
    pub state: PullRequestState,
    pub author: Option<String>,
    /// PR's source branch — what's *being* merged.
    pub source_branch: Option<String>,
    /// PR's target branch — what it's merging *into*.
    pub dest_branch: Option<String>,
    /// Total reviewers (everyone whose participant `role` is `"REVIEWER"`).
    pub reviewer_count: u32,
    /// Reviewers who flipped `approved: true`.
    pub approved_count: u32,
    /// Reviewers whose participant state is `"changes_requested"`.
    pub changes_count: u32,
    pub comment_count: u32,
    pub task_count: u32,
    pub created_on_ms: Option<i64>,
    pub updated_on_ms: Option<i64>,
    pub web_url: String,
}

/// Unified PR state for both list-shape and per-PR-shape consumers.
/// Bitbucket only returns OPEN/MERGED/DECLINED/SUPERSEDED — we filter
/// the list call to `state=OPEN` but keep the enum exhaustive for the
/// per-PR phase-4 view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRequestState {
    Open,
    Merged,
    Declined,
    Superseded,
    Unknown,
}

impl PullRequestState {
    fn from_raw(s: Option<&str>) -> Self {
        match s.unwrap_or("").to_ascii_uppercase().as_str() {
            "OPEN" => Self::Open,
            "MERGED" => Self::Merged,
            "DECLINED" => Self::Declined,
            "SUPERSEDED" => Self::Superseded,
            _ => Self::Unknown,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Merged => "merged",
            Self::Declined => "declined",
            Self::Superseded => "superseded",
            Self::Unknown => "unknown",
        }
    }
}

// ─── Raw deserialization shapes ────────────────────────────────────────
//
// These mirror the Bitbucket Cloud `pipelines/` v2 payload but only keep
// the fields we project. `#[serde(default)]` everywhere so an upstream
// shape change doesn't break parsing — we just lose visibility on the
// changed field.

#[derive(Debug, Deserialize)]
struct RawPipelinesPage {
    #[serde(default)]
    values: Vec<RawPipeline>,
}

#[derive(Debug, Deserialize)]
struct RawPipeline {
    uuid: Option<String>,
    build_number: Option<u64>,
    state: Option<RawState>,
    target: Option<RawTarget>,
    creator: Option<RawCreator>,
    trigger: Option<RawTrigger>,
    created_on: Option<String>,
    completed_on: Option<String>,
    duration_in_seconds: Option<u64>,
    links: Option<RawLinks>,
}

#[derive(Debug, Deserialize)]
struct RawState {
    name: Option<String>,
    result: Option<RawStateResult>,
}

#[derive(Debug, Deserialize)]
struct RawStateResult {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawTarget {
    // Newer payload form.
    ref_name: Option<String>,
    ref_type: Option<String>,
    // Legacy form some older repos still emit.
    branch: Option<String>,
    r#type: Option<String>,
    commit: Option<RawCommit>,
}

#[derive(Debug, Deserialize)]
struct RawCommit {
    hash: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawCreator {
    display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawTrigger {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawLinks {
    html: Option<RawHrefHolder>,
}

#[derive(Debug, Deserialize)]
struct RawHrefHolder {
    href: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawPrPage {
    #[serde(default)]
    values: Vec<RawPullRequest>,
}

#[derive(Debug, Deserialize)]
struct RawPullRequest {
    id: Option<u64>,
    title: Option<String>,
    state: Option<String>,
    author: Option<RawCreator>,
    source: Option<RawPrEnd>,
    destination: Option<RawPrEnd>,
    participants: Option<Vec<RawParticipant>>,
    comment_count: Option<u32>,
    task_count: Option<u32>,
    created_on: Option<String>,
    updated_on: Option<String>,
    links: Option<RawLinks>,
}

#[derive(Debug, Deserialize)]
struct RawPrEnd {
    branch: Option<RawBranch>,
}

#[derive(Debug, Deserialize)]
struct RawBranch {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawParticipant {
    role: Option<String>,
    approved: Option<bool>,
    state: Option<String>,
}

// ─── ISO-8601 → ms parser ──────────────────────────────────────────────
//
// Same hand-rolled parser used in `private::codebuild::parse_iso_ms`, kept
// inline here so the `bitbucket` module has no cross-cargo-feature deps
// (codebuild lives under `--features private`).

/// Parse `2026-05-15T14:37:02.559Z` / `…+05:30` / `…-04:00` → UTC epoch ms.
/// Returns `None` for any malformed input. Cheap, dependency-free.
pub fn parse_iso_ms(s: &str) -> Option<i64> {
    let s = s.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let year: i64 = s.get(0..4)?.parse().ok()?;
    let month: u32 = s.get(5..7)?.parse().ok()?;
    let day: u32 = s.get(8..10)?.parse().ok()?;
    let hour: u32 = s.get(11..13)?.parse().ok()?;
    let min: u32 = s.get(14..16)?.parse().ok()?;
    let sec: u32 = s.get(17..19)?.parse().ok()?;
    let mut idx = 19;
    let mut frac_ms = 0u32;
    if bytes.get(idx).copied() == Some(b'.') {
        idx += 1;
        let frac_start = idx;
        while idx < bytes.len() && bytes[idx].is_ascii_digit() {
            idx += 1;
        }
        let frac_digits = &s[frac_start..idx];
        let truncated = &frac_digits[..frac_digits.len().min(3)];
        if let Ok(n) = truncated.parse::<u32>() {
            frac_ms = match truncated.len() {
                1 => n * 100,
                2 => n * 10,
                _ => n,
            };
        }
    }
    let tz_offset_min: i64 = if bytes.get(idx).copied() == Some(b'Z') {
        0
    } else if let Some(c) = bytes.get(idx).copied()
        && (c == b'+' || c == b'-')
        && idx + 5 < bytes.len()
    {
        let sign: i64 = if c == b'+' { 1 } else { -1 };
        let h: i64 = s.get(idx + 1..idx + 3)?.parse().ok()?;
        let m: i64 = s.get(idx + 4..idx + 6)?.parse().ok()?;
        sign * (h * 60 + m)
    } else {
        0
    };
    let utc_ms = days_from_civil(year, month, day) * 86_400_000
        + (hour as i64) * 3_600_000
        + (min as i64) * 60_000
        + (sec as i64) * 1_000
        + (frac_ms as i64)
        - tz_offset_min * 60_000;
    Some(utc_ms)
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let d = d as i64;
    let doy = (153 * if m > 2 { m - 3 } else { m + 9 } + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_bearer_when_no_colon() {
        assert_eq!(auth_header_value("ATAT-abc123"), "Bearer ATAT-abc123");
    }

    #[test]
    fn auth_basic_when_colon_present() {
        // user:pass → "Basic dXNlcjpwYXNz"
        assert_eq!(auth_header_value("user:pass"), "Basic dXNlcjpwYXNz");
    }

    #[test]
    fn auth_trims_whitespace() {
        assert_eq!(auth_header_value("  ATAT  "), "Bearer ATAT");
    }

    #[test]
    fn state_in_progress_outer_wins_over_stale_result() {
        let raw = Some(RawState {
            name: Some("IN_PROGRESS".into()),
            // Server might still carry a previous result field; outer
            // state must take precedence.
            result: Some(RawStateResult {
                name: Some("FAILED".into()),
            }),
        });
        assert_eq!(PipelineState::from_raw(&raw), PipelineState::InProgress);
    }

    #[test]
    fn state_completed_fans_out_by_result() {
        let mk = |result: &str| {
            Some(RawState {
                name: Some("COMPLETED".into()),
                result: Some(RawStateResult {
                    name: Some(result.into()),
                }),
            })
        };
        assert_eq!(
            PipelineState::from_raw(&mk("SUCCESSFUL")),
            PipelineState::Successful
        );
        assert_eq!(
            PipelineState::from_raw(&mk("FAILED")),
            PipelineState::Failed
        );
        assert_eq!(PipelineState::from_raw(&mk("ERROR")), PipelineState::Error);
        assert_eq!(
            PipelineState::from_raw(&mk("STOPPED")),
            PipelineState::Stopped
        );
        assert_eq!(
            PipelineState::from_raw(&mk("EXPIRED")),
            PipelineState::Expired
        );
    }

    #[test]
    fn state_is_terminal_classifications() {
        assert!(!PipelineState::InProgress.is_terminal());
        assert!(!PipelineState::Pending.is_terminal());
        assert!(!PipelineState::Paused.is_terminal());
        assert!(PipelineState::Successful.is_terminal());
        assert!(PipelineState::Failed.is_terminal());
        assert!(PipelineState::Halted.is_terminal());
    }

    #[test]
    fn parses_real_world_pipelines_response() {
        // Trimmed sample of the actual v2 response shape — confirmed
        // against `curl https://api.bitbucket.org/2.0/repositories/.../pipelines/`.
        let body = r#"{
          "values": [
            {
              "uuid": "{abc-123}",
              "build_number": 4521,
              "state": { "name": "COMPLETED", "result": { "name": "SUCCESSFUL" } },
              "creator": { "display_name": "Chris McLennan" },
              "target": {
                "type": "pipeline_ref_target",
                "ref_type": "branch",
                "ref_name": "main",
                "commit": { "hash": "abc1234deadbeef" }
              },
              "trigger": { "name": "PUSH" },
              "created_on": "2026-05-15T14:37:02.559Z",
              "completed_on": "2026-05-15T14:42:08.123Z",
              "duration_in_seconds": 306,
              "links": {
                "html": { "href": "https://bitbucket.org/exampleorg/example-api/addon/pipelines/home#!/results/4521" }
              }
            },
            {
              "uuid": "{def-456}",
              "build_number": 4522,
              "state": { "name": "IN_PROGRESS" },
              "target": {
                "type": "pipeline_ref_target",
                "ref_type": "branch",
                "ref_name": "feature/login",
                "commit": { "hash": "deadbeef" }
              },
              "trigger": { "name": "PUSH" },
              "created_on": "2026-05-15T15:00:00.000Z"
            }
          ]
        }"#;
        let rows = parse_pipelines_response(body, "exampleorg", "example-api").unwrap();
        assert_eq!(rows.len(), 2);
        let p = &rows[0];
        assert_eq!(p.build_number, 4521);
        assert_eq!(p.state, PipelineState::Successful);
        assert_eq!(p.target_ref.as_deref(), Some("main"));
        assert_eq!(p.target_kind.as_deref(), Some("branch"));
        assert_eq!(p.commit_hash.as_deref(), Some("abc1234deadbeef"));
        assert_eq!(p.creator.as_deref(), Some("Chris McLennan"));
        assert_eq!(p.trigger.as_deref(), Some("PUSH"));
        assert_eq!(p.duration_secs, Some(306));
        assert!(p.created_on_ms.is_some());
        assert!(p.completed_on_ms.is_some());
        assert!(p.web_url.contains("!/results/4521"));

        let q = &rows[1];
        assert_eq!(q.state, PipelineState::InProgress);
        assert_eq!(q.target_ref.as_deref(), Some("feature/login"));
        // No completed_on / duration on an in-progress pipeline.
        assert!(q.completed_on_ms.is_none());
        assert!(q.duration_secs.is_none());
    }

    #[test]
    fn falls_back_to_synthesized_web_url_when_links_missing() {
        let body = r#"{
          "values": [{ "build_number": 99, "state": { "name": "COMPLETED", "result": { "name": "SUCCESSFUL" } } }]
        }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert_eq!(
            rows[0].web_url,
            "https://bitbucket.org/ws/repo/addon/pipelines/home#!/results/99"
        );
    }

    #[test]
    fn duration_derived_when_server_omits_it() {
        let body = r#"{
          "values": [{
            "build_number": 1,
            "state": { "name": "COMPLETED", "result": { "name": "FAILED" } },
            "created_on":   "2026-05-15T14:00:00Z",
            "completed_on": "2026-05-15T14:02:30Z"
          }]
        }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert_eq!(rows[0].duration_secs, Some(150));
    }

    #[test]
    fn empty_values_array_is_ok() {
        let body = r#"{ "values": [] }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn malformed_json_is_a_caught_error() {
        let err = parse_pipelines_response("not json", "ws", "repo").unwrap_err();
        assert!(err.contains("parse json"));
    }

    #[test]
    fn iso_ms_round_trip() {
        let utc = parse_iso_ms("2026-05-15T14:37:02.559Z").unwrap();
        let east = parse_iso_ms("2026-05-15T20:07:02.559+05:30").unwrap();
        assert_eq!(utc, east);
    }

    #[test]
    fn parses_real_world_pull_requests_response() {
        let body = r#"{
          "values": [{
            "id": 4521,
            "title": "Add Safari fallback for auth middleware",
            "state": "OPEN",
            "author": { "display_name": "Chris McLennan" },
            "source":      { "branch": { "name": "feature/safari-auth" } },
            "destination": { "branch": { "name": "main" } },
            "participants": [
              { "role": "REVIEWER", "approved": true,  "state": "approved" },
              { "role": "REVIEWER", "approved": false, "state": "changes_requested" },
              { "role": "REVIEWER", "approved": false, "state": null }
            ],
            "comment_count": 7,
            "task_count":    1,
            "created_on": "2026-05-10T14:37:02Z",
            "updated_on": "2026-05-15T09:00:00Z",
            "links": {
              "html": { "href": "https://bitbucket.org/exampleorg/example-api/pull-requests/4521" }
            }
          }]
        }"#;
        let rows = parse_pull_requests_response(body, "exampleorg", "example-api").unwrap();
        assert_eq!(rows.len(), 1);
        let p = &rows[0];
        assert_eq!(p.id, 4521);
        assert_eq!(p.state, PullRequestState::Open);
        assert_eq!(p.author.as_deref(), Some("Chris McLennan"));
        assert_eq!(p.source_branch.as_deref(), Some("feature/safari-auth"));
        assert_eq!(p.dest_branch.as_deref(), Some("main"));
        assert_eq!(p.reviewer_count, 3);
        assert_eq!(p.approved_count, 1);
        assert_eq!(p.changes_count, 1);
        assert_eq!(p.comment_count, 7);
        assert!(p.web_url.contains("pull-requests/4521"));
    }

    #[test]
    fn pr_state_classification() {
        assert_eq!(PullRequestState::from_raw(Some("OPEN")), PullRequestState::Open);
        assert_eq!(PullRequestState::from_raw(Some("merged")), PullRequestState::Merged);
        assert_eq!(PullRequestState::from_raw(Some("DECLINED")), PullRequestState::Declined);
        assert_eq!(PullRequestState::from_raw(Some("SUPERSEDED")), PullRequestState::Superseded);
        assert_eq!(PullRequestState::from_raw(None), PullRequestState::Unknown);
    }

    #[test]
    fn pr_falls_back_to_synthesized_url() {
        let body = r#"{
          "values": [{ "id": 99, "state": "OPEN", "title": "t" }]
        }"#;
        let rows = parse_pull_requests_response(body, "ws", "repo").unwrap();
        assert_eq!(rows[0].web_url, "https://bitbucket.org/ws/repo/pull-requests/99");
    }
}
