//! GitHub REST API plumbing for the Actions / Pull Requests panes.
//!
//! Endpoints used in phase 1:
//! * `GET /repos/{owner}/{repo}/actions/runs?per_page=N` — recent workflow runs.
//!
//! Endpoints planned for phase 3 (kept here as reference):
//! * `GET /repos/{owner}/{repo}/pulls?state=open&per_page=N`
//! * `GET /repos/{owner}/{repo}/pulls/{number}`
//! * `GET /repos/{owner}/{repo}/commits/{sha}/check-runs`
//!
//! Auth: `Authorization: Bearer <token>`. All four current PAT shapes
//! (classic `ghp_*`, fine-grained `github_pat_*`, app installation `ghs_*`,
//! OAuth `gho_*`) work with Bearer. Token never lives in config files —
//! sourced from `$GITHUB_TOKEN` (or `[github] auth_env`).
//!
//! Plus the GitHub-mandatory headers: `Accept: application/vnd.github+json`,
//! `X-GitHub-Api-Version: 2022-11-28`, and a meaningful `User-Agent`.

use std::time::Duration;

use serde::Deserialize;

use crate::config::GithubRepo;

const API_BASE: &str = "https://api.github.com";

/// Max workflow runs to ask the API for per repo per poll. GitHub allows
/// up to 100; 20 mirrors the Bitbucket pane's pagelen for visual parity.
const PER_PAGE: u32 = 20;

const HTTP_TIMEOUT: Duration = Duration::from_secs(20);

pub fn build_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())
}

/// `Authorization: Bearer <token>` — the modern format that works for
/// every PAT variant. Computed once per spawn.
pub fn auth_header_value(token: &str) -> String {
    format!("Bearer {}", token.trim())
}

pub fn fetch_recent_workflow_runs(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &GithubRepo,
) -> Result<Vec<WorkflowRunRecord>, String> {
    let url = format!(
        "{API_BASE}/repos/{owner}/{repo}/actions/runs?per_page={PER_PAGE}",
        owner = repo.owner,
        repo = repo.repo,
    );
    let resp = client
        .get(&url)
        .header("Authorization", auth_header)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .map_err(|e| format!("send: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().unwrap_or_default();
        let snippet = body.chars().take(200).collect::<String>();
        return Err(format!("HTTP {status} — {snippet}"));
    }
    let body = resp.text().map_err(|e| format!("read body: {e}"))?;
    parse_runs_response(&body, &repo.owner, &repo.repo)
}

pub fn parse_runs_response(
    body: &str,
    owner: &str,
    repo: &str,
) -> Result<Vec<WorkflowRunRecord>, String> {
    let raw: RawRunsPage =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    let out = raw
        .workflow_runs
        .into_iter()
        .map(|r| project_run(r, owner, repo))
        .collect();
    Ok(out)
}

fn project_run(r: RawWorkflowRun, owner: &str, repo: &str) -> WorkflowRunRecord {
    let state = WorkflowRunState::from_raw(&r.status, &r.conclusion);
    let created_at_ms = r.created_at.as_deref().and_then(parse_iso_ms);
    let updated_at_ms = r.updated_at.as_deref().and_then(parse_iso_ms);
    let run_started_at_ms = r.run_started_at.as_deref().and_then(parse_iso_ms);
    // Prefer run_started_at for "when did this actually start"; created_at
    // is when the trigger fired (can lag a few seconds).
    let started_at_ms = run_started_at_ms.or(created_at_ms);
    let duration_secs = match (started_at_ms, updated_at_ms) {
        (Some(s), Some(e)) if e >= s && state.is_terminal() => Some(((e - s) / 1000) as u64),
        _ => None,
    };
    let web_url = r.html_url.unwrap_or_else(|| {
        format!(
            "https://github.com/{owner}/{repo}/actions/runs/{id}",
            id = r.id.unwrap_or(0)
        )
    });
    WorkflowRunRecord {
        owner: owner.to_string(),
        repo: repo.to_string(),
        id: r.id.unwrap_or(0),
        run_number: r.run_number.unwrap_or(0),
        workflow_name: r.name.unwrap_or_default(),
        state,
        target_ref: r.head_branch,
        commit_hash: r.head_sha,
        creator: r.actor.and_then(|a| a.login),
        event: r.event,
        created_at_ms,
        started_at_ms,
        updated_at_ms,
        duration_secs,
        web_url,
    }
}

// ─── Public projected types ────────────────────────────────────────────

/// One row in `Pane::GithubActions` — a GitHub Actions workflow run
/// projected to the fields the IDE actually renders.
#[derive(Debug, Clone)]
pub struct WorkflowRunRecord {
    pub owner: String,
    pub repo: String,
    /// GitHub's internal run id (the path segment in `actions/runs/{id}`).
    pub id: u64,
    /// Human-friendly per-workflow counter (`#42`).
    pub run_number: u64,
    /// Workflow display name (`"CI"`, `"Release"`, …).
    pub workflow_name: String,
    pub state: WorkflowRunState,
    pub target_ref: Option<String>,
    pub commit_hash: Option<String>,
    pub creator: Option<String>,
    /// `"push"` / `"pull_request"` / `"schedule"` / `"workflow_dispatch"` / …
    pub event: Option<String>,
    pub created_at_ms: Option<i64>,
    pub started_at_ms: Option<i64>,
    pub updated_at_ms: Option<i64>,
    pub duration_secs: Option<u64>,
    /// `https://github.com/owner/repo/actions/runs/{id}` — opens the
    /// workflow's UI page.
    pub web_url: String,
}

/// Unified state for a GitHub Actions workflow run — folds the
/// `status` + `conclusion` two-step into one enum so the renderer can
/// color-code without branching.
///
/// The mapping from GitHub's vocabulary:
/// * `status=queued` → `Queued`
/// * `status=in_progress` → `InProgress`
/// * `status=requested` / `pending` / `waiting` → `Pending`
/// * `status=completed` + `conclusion=success` → `Success`
/// * `status=completed` + `conclusion=failure` → `Failed`
/// * `status=completed` + `conclusion=cancelled` → `Cancelled`
/// * `status=completed` + `conclusion=skipped` → `Skipped`
/// * `status=completed` + `conclusion=timed_out` → `TimedOut`
/// * `status=completed` + `conclusion=action_required` → `ActionRequired`
/// * `status=completed` + `conclusion=neutral|stale` → `Neutral` / `Stale`
/// * anything else → `Unknown`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowRunState {
    Success,
    Failed,
    Cancelled,
    Skipped,
    TimedOut,
    ActionRequired,
    Neutral,
    Stale,
    InProgress,
    Queued,
    Pending,
    Unknown,
}

impl WorkflowRunState {
    fn from_raw(status: &Option<String>, conclusion: &Option<String>) -> Self {
        let status = status
            .as_deref()
            .unwrap_or("")
            .to_ascii_lowercase();
        let conclusion = conclusion
            .as_deref()
            .unwrap_or("")
            .to_ascii_lowercase();
        match status.as_str() {
            "in_progress" => Self::InProgress,
            "queued" => Self::Queued,
            "requested" | "pending" | "waiting" => Self::Pending,
            "completed" => match conclusion.as_str() {
                "success" => Self::Success,
                "failure" => Self::Failed,
                "cancelled" => Self::Cancelled,
                "skipped" => Self::Skipped,
                "timed_out" => Self::TimedOut,
                "action_required" => Self::ActionRequired,
                "neutral" => Self::Neutral,
                "stale" => Self::Stale,
                _ => Self::Unknown,
            },
            _ => Self::Unknown,
        }
    }
    pub fn glyph(self) -> &'static str {
        match self {
            Self::Success => "✓",
            Self::Failed | Self::TimedOut => "✗",
            Self::Cancelled => "⊘",
            Self::Skipped => "↷",
            Self::ActionRequired => "‼",
            Self::Neutral | Self::Stale => "·",
            Self::InProgress => "⏵",
            Self::Queued => "⧗",
            Self::Pending => "⏸",
            Self::Unknown => "?",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Success => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Skipped => "skipped",
            Self::TimedOut => "timeout",
            Self::ActionRequired => "action required",
            Self::Neutral => "neutral",
            Self::Stale => "stale",
            Self::InProgress => "running",
            Self::Queued => "queued",
            Self::Pending => "pending",
            Self::Unknown => "unknown",
        }
    }
    pub fn is_terminal(self) -> bool {
        !matches!(
            self,
            Self::InProgress | Self::Queued | Self::Pending | Self::Unknown
        )
    }
}

// ─── Raw deserialization shapes ────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct RawRunsPage {
    #[serde(default)]
    workflow_runs: Vec<RawWorkflowRun>,
}

#[derive(Debug, Deserialize)]
struct RawWorkflowRun {
    id: Option<u64>,
    run_number: Option<u64>,
    name: Option<String>,
    status: Option<String>,
    conclusion: Option<String>,
    head_branch: Option<String>,
    head_sha: Option<String>,
    actor: Option<RawActor>,
    event: Option<String>,
    created_at: Option<String>,
    updated_at: Option<String>,
    run_started_at: Option<String>,
    html_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawActor {
    login: Option<String>,
}

// ─── ISO-8601 → epoch ms (same parser as the bitbucket sibling) ────────

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
    fn auth_uses_bearer() {
        assert_eq!(
            auth_header_value("ghp_abc123"),
            "Bearer ghp_abc123"
        );
        assert_eq!(
            auth_header_value("github_pat_xyz"),
            "Bearer github_pat_xyz"
        );
        assert_eq!(auth_header_value("  ghs_token  "), "Bearer ghs_token");
    }

    #[test]
    fn state_completed_success() {
        assert_eq!(
            WorkflowRunState::from_raw(
                &Some("completed".into()),
                &Some("success".into())
            ),
            WorkflowRunState::Success
        );
    }

    #[test]
    fn state_completed_fans_out_by_conclusion() {
        let mk = |c: &str| {
            WorkflowRunState::from_raw(&Some("completed".into()), &Some(c.into()))
        };
        assert_eq!(mk("failure"), WorkflowRunState::Failed);
        assert_eq!(mk("cancelled"), WorkflowRunState::Cancelled);
        assert_eq!(mk("skipped"), WorkflowRunState::Skipped);
        assert_eq!(mk("timed_out"), WorkflowRunState::TimedOut);
        assert_eq!(mk("action_required"), WorkflowRunState::ActionRequired);
        assert_eq!(mk("neutral"), WorkflowRunState::Neutral);
        assert_eq!(mk("stale"), WorkflowRunState::Stale);
    }

    #[test]
    fn state_in_flight_ignores_stale_conclusion() {
        // status=in_progress should win even if conclusion still has a
        // previous-run value lingering.
        assert_eq!(
            WorkflowRunState::from_raw(
                &Some("in_progress".into()),
                &Some("failure".into())
            ),
            WorkflowRunState::InProgress
        );
    }

    #[test]
    fn state_is_terminal_classifications() {
        assert!(WorkflowRunState::Success.is_terminal());
        assert!(WorkflowRunState::Failed.is_terminal());
        assert!(!WorkflowRunState::InProgress.is_terminal());
        assert!(!WorkflowRunState::Queued.is_terminal());
        assert!(!WorkflowRunState::Pending.is_terminal());
    }

    #[test]
    fn parses_real_world_runs_response() {
        // Trimmed sample of the actual /actions/runs payload shape.
        let body = r#"{
          "total_count": 2,
          "workflow_runs": [
            {
              "id": 8814561234,
              "run_number": 42,
              "name": "CI",
              "status": "completed",
              "conclusion": "success",
              "head_branch": "main",
              "head_sha": "abc1234deadbeef",
              "actor": { "login": "chrismclennan" },
              "event": "push",
              "created_at":     "2026-05-15T14:37:02Z",
              "updated_at":     "2026-05-15T14:42:08Z",
              "run_started_at": "2026-05-15T14:37:05Z",
              "html_url": "https://github.com/exampleorg/private-claude-knowledge/actions/runs/8814561234"
            },
            {
              "id": 8814561235,
              "run_number": 43,
              "name": "Release",
              "status": "in_progress",
              "conclusion": null,
              "head_branch": "release/2026.05",
              "head_sha": "deadbeef",
              "event": "workflow_dispatch",
              "created_at": "2026-05-15T15:00:00Z",
              "updated_at": "2026-05-15T15:00:30Z"
            }
          ]
        }"#;
        let rows = parse_runs_response(body, "exampleorg", "private-claude-knowledge").unwrap();
        assert_eq!(rows.len(), 2);
        let r = &rows[0];
        assert_eq!(r.run_number, 42);
        assert_eq!(r.workflow_name, "CI");
        assert_eq!(r.state, WorkflowRunState::Success);
        assert_eq!(r.target_ref.as_deref(), Some("main"));
        assert_eq!(r.creator.as_deref(), Some("chrismclennan"));
        assert_eq!(r.event.as_deref(), Some("push"));
        assert!(r.duration_secs.is_some_and(|d| d > 0));
        assert!(r.web_url.contains("/actions/runs/8814561234"));

        let q = &rows[1];
        assert_eq!(q.state, WorkflowRunState::InProgress);
        assert_eq!(q.workflow_name, "Release");
        // No duration on an in-flight run (not terminal).
        assert!(q.duration_secs.is_none());
    }

    #[test]
    fn synthesizes_web_url_when_missing() {
        let body = r#"{
          "workflow_runs": [{
            "id": 99,
            "run_number": 1,
            "status": "completed",
            "conclusion": "success"
          }]
        }"#;
        let rows = parse_runs_response(body, "ws", "repo").unwrap();
        assert_eq!(rows[0].web_url, "https://github.com/ws/repo/actions/runs/99");
    }

    #[test]
    fn empty_array_ok() {
        let rows = parse_runs_response(r#"{"workflow_runs": []}"#, "ws", "repo").unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn malformed_json_is_caught() {
        let err = parse_runs_response("not json", "ws", "repo").unwrap_err();
        assert!(err.contains("parse json"));
    }
}
