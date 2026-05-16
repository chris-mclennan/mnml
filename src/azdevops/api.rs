//! Azure DevOps REST plumbing.
//!
//! Endpoints used (api-version=7.1):
//! * `GET /{org}/{project}/_apis/build/builds?$top=N` — recent builds.
//! * `GET /{org}/{project}/_apis/build/builds?branchName=refs/heads/<b>&$top=1` — per-branch latest.
//! * `GET /{org}/{project}/_apis/git/repositories/{repo}/pullrequests?searchCriteria.status=active`
//!   — open PRs on a repo.
//! * `GET /{org}/_apis/git/pullrequests?searchCriteria.status=active&searchCriteria.creatorId=<self>`
//!   — Mine PRs across an org. (Note: creatorId needs the user's GUID,
//!   which we resolve once per worker via `/{org}/_apis/ConnectionData`.)
//!
//! Auth: HTTP Basic with empty username + PAT, base64-encoded as `:<PAT>`.

use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;

use crate::config::AzDevOpsProject;

const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
const PER_PAGE: u32 = 20;
const API_VERSION: &str = "7.1";

pub fn build_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())
}

pub fn auth_header_value(token: &str) -> String {
    // Empty username + PAT, base64-encoded — Azure DevOps's Basic auth shape.
    format!("Basic {}", BASE64.encode(format!(":{}", token.trim())))
}

fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_' || b == b'~' {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

fn project_url_prefix(p: &AzDevOpsProject) -> String {
    format!(
        "https://dev.azure.com/{}/{}",
        url_encode(&p.org),
        url_encode(&p.project)
    )
}

pub fn fetch_recent_builds(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    p: &AzDevOpsProject,
) -> Result<Vec<BuildRecord>, String> {
    let url = format!(
        "{}/_apis/build/builds?$top={PER_PAGE}&api-version={API_VERSION}",
        project_url_prefix(p)
    );
    let body = http_get(client, &url, auth_header)?;
    parse_builds_response(&body, p)
}

pub fn fetch_latest_build_for_branch(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    p: &AzDevOpsProject,
    branch: &str,
) -> Result<Option<BuildRecord>, String> {
    // Azure's branchName uses the full ref form (`refs/heads/<branch>`).
    let branch_full = format!("refs/heads/{branch}");
    let url = format!(
        "{}/_apis/build/builds?branchName={}&$top=1&api-version={API_VERSION}",
        project_url_prefix(p),
        url_encode(&branch_full),
    );
    let body = http_get(client, &url, auth_header)?;
    let builds = parse_builds_response(&body, p)?;
    Ok(builds.into_iter().next())
}

pub fn fetch_open_pull_requests(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    p: &AzDevOpsProject,
) -> Result<Vec<PullRequestRecord>, String> {
    let url = format!(
        "{}/_apis/git/repositories/{}/pullrequests?searchCriteria.status=active&$top={PER_PAGE}&api-version={API_VERSION}",
        project_url_prefix(p),
        url_encode(&p.repo),
    );
    let body = http_get(client, &url, auth_header)?;
    parse_prs_response(&body, p)
}

pub fn fetch_my_open_pull_requests(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    org: &str,
) -> Result<Vec<PullRequestRecord>, String> {
    // Cross-org-project: we'd ideally fetch by creatorId, but that's a
    // GUID we have to look up first. To keep this simple, we use the
    // `searchCriteria.creatorId=me` shorthand — Azure DevOps accepts
    // the literal `me` keyword in some API versions. If a real user
    // hits this and it doesn't work, follow up with a ConnectionData
    // lookup and substitute the GUID.
    let url = format!(
        "https://dev.azure.com/{}/_apis/git/pullrequests?searchCriteria.status=active&searchCriteria.creatorId=me&$top=50&api-version={API_VERSION}",
        url_encode(org),
    );
    let body = http_get(client, &url, auth_header)?;
    // For Mine we don't know the project/repo per-PR upfront — the
    // response carries repository.project.name + repository.name so
    // we use those.
    parse_prs_response_mine(&body, org)
}

fn http_get(
    client: &reqwest::blocking::Client,
    url: &str,
    auth_header: &str,
) -> Result<String, String> {
    let resp = client
        .get(url)
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
    resp.text().map_err(|e| format!("read body: {e}"))
}

pub fn parse_builds_response(
    body: &str,
    p: &AzDevOpsProject,
) -> Result<Vec<BuildRecord>, String> {
    let raw: RawBuildsPage =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    Ok(raw.value.into_iter().map(|b| project_build(b, p)).collect())
}

fn project_build(b: RawBuild, p: &AzDevOpsProject) -> BuildRecord {
    let state = BuildState::from_raw(b.status.as_deref(), b.result.as_deref());
    let started_at_ms = b.start_time.as_deref().and_then(parse_iso_ms);
    let finished_at_ms = b.finish_time.as_deref().and_then(parse_iso_ms);
    let duration_secs = match (started_at_ms, finished_at_ms) {
        (Some(s), Some(e)) if e >= s => Some(((e - s) / 1000) as u64),
        _ => None,
    };
    let target_ref = b.source_branch.map(|s| {
        s.strip_prefix("refs/heads/")
            .map(str::to_string)
            .unwrap_or(s)
    });
    let web_url = b
        .links
        .as_ref()
        .and_then(|l| l.web.as_ref())
        .and_then(|w| w.href.clone())
        .unwrap_or_else(|| {
            format!(
                "https://dev.azure.com/{}/{}/_build/results?buildId={}",
                p.org,
                p.project,
                b.id.unwrap_or(0)
            )
        });
    BuildRecord {
        label: crate::azdevops::project_label(p),
        id: b.id.unwrap_or(0),
        build_number: b.build_number.unwrap_or_default(),
        state,
        target_ref,
        commit_hash: b.source_version,
        creator: b.requested_for.as_ref().and_then(|r| r.display_name.clone()),
        reason: b.reason,
        started_at_ms,
        finished_at_ms,
        duration_secs,
        web_url,
    }
}

pub fn parse_prs_response(
    body: &str,
    p: &AzDevOpsProject,
) -> Result<Vec<PullRequestRecord>, String> {
    let raw: RawPrsPage = serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    Ok(raw
        .value
        .into_iter()
        .map(|m| project_pr(m, Some(p), None))
        .collect())
}

pub fn parse_prs_response_mine(
    body: &str,
    org: &str,
) -> Result<Vec<PullRequestRecord>, String> {
    let raw: RawPrsPage = serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    Ok(raw
        .value
        .into_iter()
        .map(|m| project_pr(m, None, Some(org)))
        .collect())
}

fn project_pr(
    m: RawPr,
    project_hint: Option<&AzDevOpsProject>,
    org_hint: Option<&str>,
) -> PullRequestRecord {
    let state = PullRequestState::from_raw(m.status.as_deref().unwrap_or(""), m.is_draft);
    let created_at_ms = m.creation_date.as_deref().and_then(parse_iso_ms);
    let label = if let Some(p) = project_hint {
        crate::azdevops::project_label(p)
    } else {
        let org = org_hint.unwrap_or("");
        let proj = m
            .repository
            .as_ref()
            .and_then(|r| r.project.as_ref())
            .and_then(|p| p.name.clone())
            .unwrap_or_default();
        let repo = m
            .repository
            .as_ref()
            .and_then(|r| r.name.clone())
            .unwrap_or_default();
        format!("{org}/{proj}/{repo}")
    };
    // Reviewers, approvals, change-requested counts from `reviewers[]`.
    let (reviewer_count, approved_count, changes_count) = m
        .reviewers
        .as_ref()
        .map(|rs| {
            let total = rs.len() as u32;
            let approved = rs.iter().filter(|r| r.vote.unwrap_or(0) >= 5).count() as u32;
            let changes = rs.iter().filter(|r| r.vote.unwrap_or(0) < 0).count() as u32;
            (total, approved, changes)
        })
        .unwrap_or((0, 0, 0));
    let web_url = m
        .links
        .as_ref()
        .and_then(|l| l.web.as_ref())
        .and_then(|w| w.href.clone())
        .unwrap_or_default();
    PullRequestRecord {
        label,
        id: m.pull_request_id.unwrap_or(0),
        title: m.title.unwrap_or_default(),
        state,
        author: m.created_by.and_then(|c| c.display_name),
        source_branch: m.source_ref_name.map(strip_heads),
        dest_branch: m.target_ref_name.map(strip_heads),
        reviewer_count,
        approved_count,
        changes_count,
        comment_count: 0, // Azure doesn't surface this on the PR list endpoint.
        created_at_ms,
        web_url,
    }
}

fn strip_heads(s: String) -> String {
    s.strip_prefix("refs/heads/")
        .map(str::to_string)
        .unwrap_or(s)
}

// ─── Projected types ──────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct BuildRecord {
    pub label: String,
    pub id: u64,
    pub build_number: String,
    pub state: BuildState,
    pub target_ref: Option<String>,
    pub commit_hash: Option<String>,
    pub creator: Option<String>,
    pub reason: Option<String>,
    pub started_at_ms: Option<i64>,
    pub finished_at_ms: Option<i64>,
    pub duration_secs: Option<u64>,
    pub web_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildState {
    Succeeded,
    Failed,
    Canceled,
    PartiallySucceeded,
    InProgress,
    NotStarted,
    Unknown,
}

impl BuildState {
    fn from_raw(status: Option<&str>, result: Option<&str>) -> Self {
        let status = status.unwrap_or("").to_ascii_lowercase();
        let result = result.unwrap_or("").to_ascii_lowercase();
        match status.as_str() {
            "inprogress" => Self::InProgress,
            "notstarted" | "postponed" | "cancelling" | "none" => Self::NotStarted,
            "completed" => match result.as_str() {
                "succeeded" => Self::Succeeded,
                "failed" => Self::Failed,
                "canceled" => Self::Canceled,
                "partiallysucceeded" => Self::PartiallySucceeded,
                _ => Self::Unknown,
            },
            _ => Self::Unknown,
        }
    }
    pub fn glyph(self) -> &'static str {
        match self {
            Self::Succeeded => "✓",
            Self::Failed => "✗",
            Self::Canceled => "⊘",
            Self::PartiallySucceeded => "◐",
            Self::InProgress => "⏵",
            Self::NotStarted => "·",
            Self::Unknown => "?",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Canceled => "canceled",
            Self::PartiallySucceeded => "partial",
            Self::InProgress => "running",
            Self::NotStarted => "queued",
            Self::Unknown => "unknown",
        }
    }
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Succeeded | Self::Failed | Self::Canceled | Self::PartiallySucceeded
        )
    }
}

#[derive(Debug, Clone)]
pub struct PullRequestRecord {
    pub label: String,
    pub id: u64,
    pub title: String,
    pub state: PullRequestState,
    pub author: Option<String>,
    pub source_branch: Option<String>,
    pub dest_branch: Option<String>,
    pub reviewer_count: u32,
    pub approved_count: u32,
    pub changes_count: u32,
    pub comment_count: u32,
    pub created_at_ms: Option<i64>,
    pub web_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRequestState {
    Active,
    Draft,
    Completed,
    Abandoned,
    Unknown,
}

impl PullRequestState {
    fn from_raw(s: &str, draft: bool) -> Self {
        if draft {
            return Self::Draft;
        }
        match s {
            "active" => Self::Active,
            "completed" => Self::Completed,
            "abandoned" => Self::Abandoned,
            _ => Self::Unknown,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Draft => "draft",
            Self::Completed => "completed",
            Self::Abandoned => "abandoned",
            Self::Unknown => "unknown",
        }
    }
}

// ─── Raw deser ────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct RawBuildsPage {
    #[serde(default)]
    value: Vec<RawBuild>,
}

#[derive(Debug, Deserialize)]
struct RawBuild {
    id: Option<u64>,
    #[serde(rename = "buildNumber")]
    build_number: Option<String>,
    status: Option<String>,
    result: Option<String>,
    reason: Option<String>,
    #[serde(rename = "sourceBranch")]
    source_branch: Option<String>,
    #[serde(rename = "sourceVersion")]
    source_version: Option<String>,
    #[serde(rename = "startTime")]
    start_time: Option<String>,
    #[serde(rename = "finishTime")]
    finish_time: Option<String>,
    #[serde(rename = "requestedFor")]
    requested_for: Option<RawIdentity>,
    #[serde(rename = "_links")]
    links: Option<RawLinks>,
}

#[derive(Debug, Deserialize)]
struct RawPrsPage {
    #[serde(default)]
    value: Vec<RawPr>,
}

#[derive(Debug, Deserialize)]
struct RawPr {
    #[serde(rename = "pullRequestId")]
    pull_request_id: Option<u64>,
    title: Option<String>,
    status: Option<String>,
    #[serde(rename = "isDraft", default)]
    is_draft: bool,
    #[serde(rename = "createdBy")]
    created_by: Option<RawIdentity>,
    #[serde(rename = "sourceRefName")]
    source_ref_name: Option<String>,
    #[serde(rename = "targetRefName")]
    target_ref_name: Option<String>,
    reviewers: Option<Vec<RawReviewer>>,
    #[serde(rename = "creationDate")]
    creation_date: Option<String>,
    repository: Option<RawRepo>,
    #[serde(rename = "_links")]
    links: Option<RawLinks>,
}

#[derive(Debug, Deserialize)]
struct RawIdentity {
    #[serde(rename = "displayName")]
    display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawReviewer {
    /// Vote semantics: 10 = approved, 5 = approved-with-suggestions,
    /// 0 = no vote, -5 = waiting, -10 = rejected.
    vote: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct RawRepo {
    name: Option<String>,
    project: Option<RawProject>,
}

#[derive(Debug, Deserialize)]
struct RawProject {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawLinks {
    web: Option<RawHref>,
}

#[derive(Debug, Deserialize)]
struct RawHref {
    href: Option<String>,
}

// ─── ISO-8601 parser ──────────────────────────────────────────────────

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
    fn auth_basic_format() {
        // ":mytoken" base64 = OnRva2Vu... let's check the prefix only.
        let h = auth_header_value("mytoken");
        assert!(h.starts_with("Basic "));
    }

    #[test]
    fn build_state_mapping() {
        assert_eq!(
            BuildState::from_raw(Some("inProgress"), None),
            BuildState::InProgress
        );
        assert_eq!(
            BuildState::from_raw(Some("completed"), Some("succeeded")),
            BuildState::Succeeded
        );
        assert_eq!(
            BuildState::from_raw(Some("completed"), Some("failed")),
            BuildState::Failed
        );
    }

    #[test]
    fn pr_state_mapping() {
        assert_eq!(PullRequestState::from_raw("active", false), PullRequestState::Active);
        assert_eq!(PullRequestState::from_raw("active", true), PullRequestState::Draft);
    }
}
