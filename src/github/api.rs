//! GitHub REST API plumbing for the Actions / Pull Requests panes.
//!
//! Endpoints used:
//! * `GET /user` — authenticated user's `login` (cached at worker spawn).
//! * `GET /search/issues?q=is:pr+is:open+author:@me+sort:updated-desc`
//!   — cross-repo "my open PRs" (Mine view-mode source).
//! * `GET /repos/{owner}/{repo}/actions/runs?per_page=N` — recent runs
//!   for one repo (mixed branches).
//! * `GET /repos/{owner}/{repo}/actions/runs?branch=<b>&per_page=1` —
//!   single most-recent run for one branch (PerBranch view-mode).
//! * `GET /repos/{owner}/{repo}/pulls?state=open&per_page=N` — per-repo
//!   open PRs (PerRepo view-mode).
//! * `GET /repos/{owner}/{repo}/actions/runs/{id}/jobs` — current job +
//!   step on an in-progress run (the per-branch view's `▶ <step>`).
//! * `GET /repos/{owner}/{repo}/git/matching-refs/heads/release` and
//!   `/heads/hotfix` — active release/hotfix branch discovery for the
//!   PerBranch view (mirrors BB's `refs/branches?q=` query).
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

/// Pull every open pull request for one repo. Sorted newest-first by
/// `updated_at` — same default as GitHub's web UI.
pub fn fetch_open_pull_requests(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &GithubRepo,
) -> Result<Vec<PullRequestRecord>, String> {
    let url = format!(
        "{API_BASE}/repos/{owner}/{repo}/pulls?state=open&per_page={PER_PAGE}&sort=updated&direction=desc",
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
    parse_pulls_response(&body, &repo.owner, &repo.repo)
}

pub fn parse_pulls_response(
    body: &str,
    owner: &str,
    repo: &str,
) -> Result<Vec<PullRequestRecord>, String> {
    // GitHub's `/pulls` endpoint returns the array directly (no envelope).
    let raw: Vec<RawPullRequest> =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    let out = raw
        .into_iter()
        .map(|p| project_pr(p, owner, repo))
        .collect();
    Ok(out)
}

fn project_pr(p: RawPullRequest, owner: &str, repo: &str) -> PullRequestRecord {
    let state = PullRequestState::from_raw(p.state.as_deref(), p.draft.unwrap_or(false));
    let updated_at_ms = p.updated_at.as_deref().and_then(parse_iso_ms);
    let created_at_ms = p.created_at.as_deref().and_then(parse_iso_ms);
    let source_branch = p.head.as_ref().and_then(|h| h.ref_field.clone());
    let dest_branch = p.base.as_ref().and_then(|b| b.ref_field.clone());
    let author = p.user.as_ref().and_then(|u| u.login.clone());
    // GitHub's `/pulls` list endpoint surfaces `requested_reviewers` (people
    // tagged for review who haven't yet responded). Approval counts need a
    // separate `/reviews` call which we defer to phase 4 polish — for the
    // list view, surfacing the request count + tagged team count is enough
    // signal for "is anyone watching this PR".
    let reviewer_count = p
        .requested_reviewers
        .as_ref()
        .map(|v| v.len() as u32)
        .unwrap_or(0)
        + p.requested_teams
            .as_ref()
            .map(|v| v.len() as u32)
            .unwrap_or(0);
    let web_url = p.html_url.unwrap_or_else(|| {
        format!(
            "https://github.com/{owner}/{repo}/pull/{n}",
            n = p.number.unwrap_or(0)
        )
    });
    PullRequestRecord {
        owner: owner.to_string(),
        repo: repo.to_string(),
        number: p.number.unwrap_or(0),
        title: p.title.unwrap_or_default(),
        state,
        author,
        source_branch,
        dest_branch,
        reviewer_count,
        // Phase 3 list view doesn't fetch /reviews — approved/changes counts
        // stay 0 here. Phase 4 will populate them via a per-PR follow-up.
        approved_count: 0,
        changes_count: 0,
        comment_count: p.comments.unwrap_or(0),
        // GH splits "issue comments" and "review comments" — surface their sum
        // as `comment_count` for parity with BB's totals.
        review_comment_count: p.review_comments.unwrap_or(0),
        created_at_ms,
        updated_at_ms,
        web_url,
    }
}

/// Fetch the authenticated user's `login` — used to scope the
/// cross-repo PR search. Cached once at worker spawn.
pub fn fetch_login(
    client: &reqwest::blocking::Client,
    auth_header: &str,
) -> Result<String, String> {
    let url = format!("{API_BASE}/user");
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
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("parse json: {e}"))?;
    v.get("login")
        .and_then(|x| x.as_str())
        .map(str::to_string)
        .ok_or_else(|| "no login in /user response".to_string())
}

/// Cross-repo "my open PRs" via GH's search API. Single call, returns
/// every open PR you authored across every repo you can read.
/// Search has its own rate limit (30/min for authenticated users) but
/// one call per poll cycle is well under.
pub fn fetch_my_open_pull_requests(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    login: &str,
) -> Result<Vec<PullRequestRecord>, String> {
    let q = format!("is:pr is:open author:{login} sort:updated-desc");
    // Search needs URL-encoded query, so use the params builder.
    let url = format!("{API_BASE}/search/issues?per_page=50");
    let resp = client
        .get(&url)
        .query(&[("q", &q)])
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
    parse_search_issues_response(&body)
}

pub fn parse_search_issues_response(body: &str) -> Result<Vec<PullRequestRecord>, String> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    let items = match v.get("items").and_then(|x| x.as_array()) {
        Some(a) => a,
        None => return Ok(Vec::new()),
    };
    let mut out = Vec::new();
    for item in items {
        // Search /issues returns issue-shaped objects for PRs. The
        // `repository_url` is `https://api.github.com/repos/{owner}/{repo}`
        // — parse owner/repo out of it.
        let (owner, repo) = match item
            .get("repository_url")
            .and_then(|u| u.as_str())
            .and_then(parse_owner_repo_from_url)
        {
            Some(pair) => pair,
            None => continue,
        };
        let number = item.get("number").and_then(|n| n.as_u64()).unwrap_or(0);
        let title = item
            .get("title")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        let state_str = item.get("state").and_then(|s| s.as_str());
        let draft = item.get("draft").and_then(|d| d.as_bool()).unwrap_or(false);
        let state = PullRequestState::from_raw(state_str, draft);
        let author = item
            .get("user")
            .and_then(|u| u.get("login"))
            .and_then(|l| l.as_str())
            .map(str::to_string);
        let html_url = item
            .get("html_url")
            .and_then(|u| u.as_str())
            .map(str::to_string);
        let created_at_ms = item
            .get("created_at")
            .and_then(|t| t.as_str())
            .and_then(parse_iso_ms);
        let updated_at_ms = item
            .get("updated_at")
            .and_then(|t| t.as_str())
            .and_then(parse_iso_ms);
        let comments = item
            .get("comments")
            .and_then(|c| c.as_u64())
            .map(|n| n as u32)
            .unwrap_or(0);
        let labels: Vec<_> = item
            .get("labels")
            .and_then(|l| l.as_array())
            .map(|arr| arr.len() as u32)
            .into_iter()
            .collect();
        // Search /issues doesn't surface source/dest branches or
        // requested_reviewers. PR-only fields stay None for the Mine
        // view — phase 4 polish can do a per-PR follow-up if accuracy
        // becomes worth the cost.
        let web_url = html_url.unwrap_or_else(|| {
            format!("https://github.com/{owner}/{repo}/pull/{number}")
        });
        out.push(PullRequestRecord {
            owner,
            repo,
            number,
            title,
            state,
            author,
            source_branch: None,
            dest_branch: None,
            reviewer_count: 0,
            approved_count: 0,
            changes_count: 0,
            comment_count: comments,
            // Labels count is not split issue/review on search results;
            // we surface it under `review_comment_count` as a label-count
            // signal — the renderer can show it as `🏷N` distinct from 💬N.
            review_comment_count: labels.first().copied().unwrap_or(0),
            created_at_ms,
            updated_at_ms,
            web_url,
        });
    }
    Ok(out)
}

fn parse_owner_repo_from_url(url: &str) -> Option<(String, String)> {
    // `https://api.github.com/repos/{owner}/{repo}` — split on `/repos/`.
    let after = url.split_once("/repos/").map(|(_, rest)| rest)?;
    let mut parts = after.splitn(2, '/');
    let owner = parts.next()?.to_string();
    let repo = parts.next()?.to_string();
    if owner.is_empty() || repo.is_empty() {
        None
    } else {
        Some((owner, repo))
    }
}

/// Latest workflow run for one branch on one repo. `None` ⇒ no runs.
pub fn fetch_latest_run_for_branch(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &GithubRepo,
    branch: &str,
) -> Result<Option<WorkflowRunRecord>, String> {
    let url = format!(
        "{API_BASE}/repos/{owner}/{repo}/actions/runs?per_page=1&branch={branch}",
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
    let runs = parse_runs_response(&body, &repo.owner, &repo.repo)?;
    Ok(runs.into_iter().next())
}

/// For an in-progress run, find the currently-executing job + step
/// name. GH's API returns jobs (one per workflow job) each with steps.
/// We pick the first IN_PROGRESS job's first IN_PROGRESS step.
pub fn fetch_running_step(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    owner: &str,
    repo: &str,
    run_id: u64,
) -> Option<String> {
    let url =
        format!("{API_BASE}/repos/{owner}/{repo}/actions/runs/{run_id}/jobs?per_page=30");
    let resp = client
        .get(&url)
        .header("Authorization", auth_header)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let body = resp.text().ok()?;
    parse_running_step(&body)
}

pub fn parse_running_step(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let jobs = v.get("jobs")?.as_array()?;
    for job in jobs {
        if job.get("status").and_then(|s| s.as_str()) != Some("in_progress") {
            continue;
        }
        let job_name = job
            .get("name")
            .and_then(|n| n.as_str())
            .unwrap_or("(unnamed)");
        let steps = job.get("steps").and_then(|s| s.as_array());
        if let Some(steps) = steps {
            for step in steps {
                if step.get("status").and_then(|s| s.as_str()) == Some("in_progress") {
                    let step_name = step
                        .get("name")
                        .and_then(|n| n.as_str())
                        .unwrap_or("(unnamed)");
                    return Some(format!("{job_name} / {step_name}"));
                }
            }
        }
        return Some(job_name.to_string());
    }
    None
}

/// Discover active release/hotfix branches via the matching-refs
/// endpoint. Returns up to `max_n` per prefix (release/ then hotfix/).
pub fn discover_release_branches(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &GithubRepo,
    max_n: usize,
) -> Vec<String> {
    let mut out = Vec::new();
    for prefix in &["release", "hotfix"] {
        let url = format!(
            "{API_BASE}/repos/{owner}/{repo}/git/matching-refs/heads/{prefix}",
            owner = repo.owner,
            repo = repo.repo,
        );
        let resp = match client
            .get(&url)
            .header("Authorization", auth_header)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
        {
            Ok(r) if r.status().is_success() => r,
            _ => continue,
        };
        let body = match resp.text() {
            Ok(b) => b,
            Err(_) => continue,
        };
        let v: serde_json::Value = match serde_json::from_str(&body) {
            Ok(x) => x,
            Err(_) => continue,
        };
        let arr = match v.as_array() {
            Some(a) => a,
            None => continue,
        };
        for r in arr.iter().take(max_n) {
            // `ref` is `refs/heads/release/2026.05` — strip the prefix.
            let name = r
                .get("ref")
                .and_then(|n| n.as_str())
                .and_then(|s| s.strip_prefix("refs/heads/"))
                .map(str::to_string);
            if let Some(b) = name
                && !out.iter().any(|x| x == &b)
            {
                out.push(b);
            }
        }
    }
    out
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
        running_step: None,
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
    /// For in-progress runs, the currently-executing job/step
    /// (`"<job> / <step>"`). Populated by the worker via a follow-up
    /// `/runs/{id}/jobs` call. `None` otherwise.
    pub running_step: Option<String>,
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

// ─── Pull-request types ────────────────────────────────────────────────

/// One row in `Pane::GithubPullRequests`.
#[derive(Debug, Clone)]
pub struct PullRequestRecord {
    pub owner: String,
    pub repo: String,
    /// GitHub's "PR number" (the path segment in `pull/{n}`).
    pub number: u64,
    pub title: String,
    pub state: PullRequestState,
    pub author: Option<String>,
    pub source_branch: Option<String>,
    pub dest_branch: Option<String>,
    /// `requested_reviewers.len() + requested_teams.len()` from the list
    /// endpoint. Approval / change-request counts arrive in phase 4 polish
    /// when we follow up with a `/reviews` call.
    pub reviewer_count: u32,
    pub approved_count: u32,
    pub changes_count: u32,
    /// "Issue comments" on the PR — equivalent to BB's `comment_count`.
    pub comment_count: u32,
    /// "Review comments" — inline file/line discussions. GitHub-specific.
    pub review_comment_count: u32,
    pub created_at_ms: Option<i64>,
    pub updated_at_ms: Option<i64>,
    pub web_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRequestState {
    Open,
    Draft,
    Merged,
    Closed,
    Unknown,
}

impl PullRequestState {
    fn from_raw(s: Option<&str>, draft: bool) -> Self {
        // GH's `state` is just "open" or "closed". Whether a closed PR
        // merged is encoded by a separate `merged` field — but that field
        // isn't always populated on the list endpoint, so we coalesce to
        // "closed" and let phase 4 disambiguate.
        if draft {
            return Self::Draft;
        }
        match s.unwrap_or("").to_ascii_lowercase().as_str() {
            "open" => Self::Open,
            "closed" => Self::Closed,
            _ => Self::Unknown,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Draft => "draft",
            Self::Merged => "merged",
            Self::Closed => "closed",
            Self::Unknown => "unknown",
        }
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

#[derive(Debug, Deserialize)]
struct RawPullRequest {
    number: Option<u64>,
    title: Option<String>,
    state: Option<String>,
    draft: Option<bool>,
    user: Option<RawActor>,
    head: Option<RawPrEnd>,
    base: Option<RawPrEnd>,
    requested_reviewers: Option<Vec<RawActor>>,
    requested_teams: Option<Vec<RawTeam>>,
    comments: Option<u32>,
    review_comments: Option<u32>,
    created_at: Option<String>,
    updated_at: Option<String>,
    html_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawPrEnd {
    /// GitHub's API field is literally named `ref`, which clashes with the
    /// Rust keyword — rename it for serde.
    #[serde(rename = "ref")]
    ref_field: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawTeam {
    #[allow(dead_code)] // shape-only — we just count entries
    slug: Option<String>,
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

    #[test]
    fn parses_real_world_pulls_response() {
        // `/pulls` returns the array at the top level (no envelope).
        let body = r#"[
          {
            "number": 4521,
            "title": "Add Safari fallback for auth",
            "state": "open",
            "draft": false,
            "user": { "login": "chrismclennan" },
            "head": { "ref": "feature/safari-auth" },
            "base": { "ref": "main" },
            "requested_reviewers": [{ "login": "alice" }, { "login": "bob" }],
            "requested_teams":     [{ "slug": "core-eng" }],
            "comments": 7,
            "review_comments": 12,
            "created_at": "2026-05-10T14:37:02Z",
            "updated_at": "2026-05-15T09:00:00Z",
            "html_url": "https://github.com/exampleorg/private-claude-knowledge/pull/4521"
          },
          {
            "number": 4522,
            "title": "WIP: refactor pipeline cache",
            "state": "open",
            "draft": true,
            "user": { "login": "chrismclennan" },
            "head": { "ref": "wip/cache" },
            "base": { "ref": "main" },
            "comments": 0,
            "review_comments": 0,
            "created_at": "2026-05-15T10:00:00Z",
            "updated_at": "2026-05-15T10:00:00Z"
          }
        ]"#;
        let rows = parse_pulls_response(body, "exampleorg", "private-claude-knowledge").unwrap();
        assert_eq!(rows.len(), 2);
        let p = &rows[0];
        assert_eq!(p.number, 4521);
        assert_eq!(p.state, PullRequestState::Open);
        assert_eq!(p.source_branch.as_deref(), Some("feature/safari-auth"));
        assert_eq!(p.dest_branch.as_deref(), Some("main"));
        // 2 reviewers + 1 team = 3 total
        assert_eq!(p.reviewer_count, 3);
        assert_eq!(p.comment_count, 7);
        assert_eq!(p.review_comment_count, 12);
        assert!(p.web_url.contains("/pull/4521"));

        let q = &rows[1];
        // Draft flag wins over `state`.
        assert_eq!(q.state, PullRequestState::Draft);
    }

    #[test]
    fn pr_state_classification() {
        assert_eq!(PullRequestState::from_raw(Some("open"), false), PullRequestState::Open);
        assert_eq!(PullRequestState::from_raw(Some("open"), true), PullRequestState::Draft);
        assert_eq!(PullRequestState::from_raw(Some("closed"), false), PullRequestState::Closed);
        assert_eq!(PullRequestState::from_raw(None, false), PullRequestState::Unknown);
    }

    #[test]
    fn pr_falls_back_to_synthesized_url() {
        let body = r#"[{ "number": 99, "state": "open", "title": "t" }]"#;
        let rows = parse_pulls_response(body, "ws", "repo").unwrap();
        assert_eq!(rows[0].web_url, "https://github.com/ws/repo/pull/99");
    }
}
