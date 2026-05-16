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

/// Walk every log of a build and concatenate each `/logs/{logId}` output
/// into one big string, with `══ log N (lines a-b) ══` separators between
/// them. Sibling to `bitbucket::fetch_combined_pipeline_log`,
/// `github::fetch_combined_run_log`, and `gitlab::fetch_combined_pipeline_log`.
///
/// Azure DevOps splits a build's output into many "log" resources (one per
/// step / job); the list endpoint returns metadata, the per-log endpoint
/// returns plain text. Builds still in progress may have a partial list —
/// not-yet-written logs return 404, handled inline as `(no log)`.
pub fn fetch_combined_build_log(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    org: &str,
    project: &str,
    build_id: u64,
) -> Result<String, String> {
    let prefix = format!(
        "https://dev.azure.com/{}/{}",
        url_encode(org),
        url_encode(project)
    );
    let logs_url = format!("{prefix}/_apis/build/builds/{build_id}/logs?api-version={API_VERSION}");
    let body = http_get(client, &logs_url, auth_header).map_err(|e| format!("logs fetch: {e}"))?;
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("logs json: {e}"))?;
    let values = v
        .get("value")
        .and_then(|x| x.as_array())
        .ok_or_else(|| "logs json: no `value` array".to_string())?;
    let mut out = String::new();
    for (i, log) in values.iter().enumerate() {
        let log_id = log
            .get("id")
            .and_then(|x| x.as_u64())
            .ok_or_else(|| format!("log {}: missing id", i + 1))?;
        let line_count = log.get("lineCount").and_then(|x| x.as_u64()).unwrap_or(0);
        out.push_str(&format!(
            "\n══ log {} (id {log_id}, {line_count} lines) ══\n",
            i + 1
        ));
        let log_url = format!(
            "{prefix}/_apis/build/builds/{build_id}/logs/{log_id}?api-version={API_VERSION}"
        );
        let resp = client
            .get(&log_url)
            .header("Authorization", auth_header)
            // Azure honors `?$format=text`, but the default for this endpoint
            // is already plain text — set Accept to keep it explicit.
            .header("Accept", "text/plain")
            .send()
            .map_err(|e| format!("log {} body: {e}", i + 1))?;
        if resp.status().as_u16() == 404 {
            out.push_str("(no log)\n");
            continue;
        }
        if !resp.status().is_success() {
            out.push_str(&format!("(log fetch failed: HTTP {})\n", resp.status()));
            continue;
        }
        let text = resp
            .text()
            .map_err(|e| format!("log {} read: {e}", i + 1))?;
        if text.is_empty() {
            out.push_str("(no log)\n");
            continue;
        }
        out.push_str(&text);
        if !text.ends_with('\n') {
            out.push('\n');
        }
    }
    if out.is_empty() {
        out.push_str("(this build has no logs yet)\n");
    }
    Ok(out)
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
    creator_id: Option<&str>,
) -> Result<Vec<PullRequestRecord>, String> {
    // Cross-org-project — query by `searchCriteria.creatorId`. Azure
    // DevOps accepts the literal `me` keyword in recent API versions; if
    // a user's tenant rejects that (some on-prem TFS / older orgs do),
    // they can configure their account's GUID via
    // `[azdevops] creator_id = "..."` and we pass it directly.
    //
    // If the `me` form errors out, we fall through to `fetch_creator_id`
    // (ConnectionData → user descriptor → GUID) and retry — slower (one
    // extra round-trip) but works without manual config.
    let id = creator_id.unwrap_or("me");
    let url = format!(
        "https://dev.azure.com/{}/_apis/git/pullrequests?searchCriteria.status=active&searchCriteria.creatorId={}&$top=50&api-version={API_VERSION}",
        url_encode(org),
        url_encode(id),
    );
    let resp_or_err = http_get(client, &url, auth_header);
    let body = match resp_or_err {
        Ok(b) => b,
        Err(e) if creator_id.is_none() && e.contains("HTTP ") => {
            // `me` likely rejected; try the GUID lookup path.
            match fetch_creator_id(client, auth_header) {
                Ok(guid) => {
                    let url = format!(
                        "https://dev.azure.com/{}/_apis/git/pullrequests?searchCriteria.status=active&searchCriteria.creatorId={}&$top=50&api-version={API_VERSION}",
                        url_encode(org),
                        url_encode(&guid),
                    );
                    http_get(client, &url, auth_header).map_err(|e2| {
                        format!("Mine fetch (me + GUID retry both failed): {e} | {e2}")
                    })?
                }
                Err(lookup_err) => {
                    return Err(format!(
                        "Mine fetch failed with `creatorId=me` ({e}); GUID lookup also failed ({lookup_err}). Set `[azdevops] creator_id` to your account GUID."
                    ));
                }
            }
        }
        Err(e) => return Err(e),
    };
    // For Mine we don't know the project/repo per-PR upfront — the
    // response carries repository.project.name + repository.name so
    // we use those.
    parse_prs_response_mine(&body, org)
}

/// Resolve the authenticated user's Azure DevOps account GUID via
/// `https://app.vssps.visualstudio.com/_apis/profile/profiles/me`. Used
/// when `creatorId=me` is rejected by the Mine endpoint.
fn fetch_creator_id(
    client: &reqwest::blocking::Client,
    auth_header: &str,
) -> Result<String, String> {
    let url =
        "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1-preview.3";
    let body = http_get(client, url, auth_header)?;
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("profile json: {e}"))?;
    v.get("id")
        .and_then(|x| x.as_str())
        .map(str::to_string)
        .ok_or_else(|| "no `id` in profile/me response".to_string())
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

pub fn parse_builds_response(body: &str, p: &AzDevOpsProject) -> Result<Vec<BuildRecord>, String> {
    let raw: RawBuildsPage = serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
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
        creator: b
            .requested_for
            .as_ref()
            .and_then(|r| r.display_name.clone()),
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

pub fn parse_prs_response_mine(body: &str, org: &str) -> Result<Vec<PullRequestRecord>, String> {
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
        assert_eq!(
            PullRequestState::from_raw("active", false),
            PullRequestState::Active
        );
        assert_eq!(
            PullRequestState::from_raw("active", true),
            PullRequestState::Draft
        );
    }

    fn project_fixture() -> crate::config::AzDevOpsProject {
        crate::config::AzDevOpsProject {
            org: "getprivate".to_string(),
            project: "hello-world".to_string(),
            repo: "hello-world".to_string(),
            branches: vec![],
        }
    }

    #[test]
    fn parses_branch_build_response() {
        // Shape verified against getprivate/hello-world on 2026-05-16.
        let body = r#"{
          "count": 1,
          "value": [{
            "id": 42,
            "buildNumber": "20260516.1",
            "status": "completed",
            "result": "succeeded",
            "sourceBranch": "refs/heads/main",
            "sourceVersion": "abc1234deadbeef",
            "startTime": "2026-05-16T14:00:00Z",
            "finishTime": "2026-05-16T14:00:13Z",
            "requestedFor": { "displayName": "Chris McLennan" },
            "reason": "individualCI",
            "_links": { "web": { "href": "https://dev.azure.com/getprivate/hello-world/_build/results?buildId=42" } }
          }]
        }"#;
        let rows = parse_builds_response(body, &project_fixture()).unwrap();
        assert_eq!(rows.len(), 1);
        let b = &rows[0];
        assert_eq!(b.id, 42);
        assert_eq!(b.build_number, "20260516.1");
        assert_eq!(b.state, BuildState::Succeeded);
        // `refs/heads/main` → `main` after strip.
        assert_eq!(b.target_ref.as_deref(), Some("main"));
        assert_eq!(b.commit_hash.as_deref(), Some("abc1234deadbeef"));
        assert_eq!(b.creator.as_deref(), Some("Chris McLennan"));
        assert_eq!(b.reason.as_deref(), Some("individualCI"));
        assert_eq!(b.duration_secs, Some(13));
        assert!(b.web_url.contains("buildId=42"));
        assert_eq!(b.label, "getprivate/hello-world/hello-world");
    }

    #[test]
    fn pr_build_branch_ref_doesnt_strip_pull_form() {
        // PR builds: Azure sets `sourceBranch: refs/pull/123/merge` instead
        // of `refs/heads/...`. The strip_prefix-only logic should leave the
        // ref intact (so users still see *something* identifying the PR).
        let body = r#"{
          "value": [{
            "id": 50,
            "buildNumber": "20260516.2",
            "status": "completed",
            "result": "succeeded",
            "sourceBranch": "refs/pull/123/merge",
            "reason": "pullRequest"
          }]
        }"#;
        let rows = parse_builds_response(body, &project_fixture()).unwrap();
        assert_eq!(rows[0].target_ref.as_deref(), Some("refs/pull/123/merge"));
        assert_eq!(rows[0].reason.as_deref(), Some("pullRequest"));
    }

    #[test]
    fn manual_build_with_no_source_branch() {
        // Manual / triggered-by-API builds may have no sourceBranch at all.
        let body = r#"{ "value": [{
          "id": 51,
          "buildNumber": "20260516.3",
          "status": "completed",
          "result": "succeeded",
          "reason": "manual"
        }] }"#;
        let rows = parse_builds_response(body, &project_fixture()).unwrap();
        assert_eq!(rows[0].target_ref, None);
        assert_eq!(rows[0].reason.as_deref(), Some("manual"));
        // No `_links.web.href` ⇒ synthesized URL.
        assert!(rows[0].web_url.contains("buildId=51"));
    }

    #[test]
    fn duration_omitted_when_finish_before_start() {
        // Defensive: malformed timestamps shouldn't produce negative durations.
        let body = r#"{ "value": [{
          "id": 52,
          "buildNumber": "x",
          "status": "completed",
          "result": "failed",
          "startTime": "2026-05-16T14:00:13Z",
          "finishTime": "2026-05-16T14:00:00Z"
        }] }"#;
        let rows = parse_builds_response(body, &project_fixture()).unwrap();
        assert_eq!(rows[0].duration_secs, None);
    }

    #[test]
    fn empty_value_array_is_ok() {
        let body = r#"{ "count": 0, "value": [] }"#;
        let rows = parse_builds_response(body, &project_fixture()).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn parses_pr_response_with_reviewers() {
        // Reviewers vote: 10=approved, 5=approved-with-suggestions,
        // -5=waiting, -10=rejected. Both ≥5 count as approved; <0 as
        // change-requested.
        let body = r#"{ "value": [{
          "pullRequestId": 7,
          "title": "TE-13216 add foo",
          "status": "active",
          "isDraft": false,
          "createdBy": { "displayName": "alice" },
          "sourceRefName": "refs/heads/feature/foo",
          "targetRefName": "refs/heads/main",
          "creationDate": "2026-05-16T14:00:00Z",
          "reviewers": [
            { "vote": 10 },
            { "vote": 5 },
            { "vote": -10 },
            { "vote": 0 }
          ],
          "_links": { "web": { "href": "https://dev.azure.com/getprivate/hello-world/_git/hello-world/pullrequest/7" } }
        }] }"#;
        let rows = parse_prs_response(body, &project_fixture()).unwrap();
        assert_eq!(rows.len(), 1);
        let p = &rows[0];
        assert_eq!(p.id, 7);
        assert_eq!(p.title, "TE-13216 add foo");
        assert_eq!(p.state, PullRequestState::Active);
        assert_eq!(p.author.as_deref(), Some("alice"));
        assert_eq!(p.source_branch.as_deref(), Some("feature/foo"));
        assert_eq!(p.dest_branch.as_deref(), Some("main"));
        assert_eq!(p.reviewer_count, 4);
        assert_eq!(p.approved_count, 2);
        assert_eq!(p.changes_count, 1);
        assert!(p.web_url.contains("/pullrequest/7"));
    }

    #[test]
    fn pr_draft_state_wins_over_active() {
        let body = r#"{ "value": [{
          "pullRequestId": 8,
          "title": "WIP",
          "status": "active",
          "isDraft": true
        }] }"#;
        let rows = parse_prs_response(body, &project_fixture()).unwrap();
        assert_eq!(rows[0].state, PullRequestState::Draft);
    }

    #[test]
    fn pr_mine_response_uses_per_pr_label() {
        // The Mine endpoint returns PRs across multiple repos in one org;
        // each row's label comes from `repository.project.name` + `.name`
        // (vs. a fixed project hint for the per-repo endpoint).
        let body = r#"{ "value": [{
          "pullRequestId": 9,
          "title": "x",
          "status": "active",
          "repository": {
            "name": "other-repo",
            "project": { "name": "OtherProject" }
          }
        }] }"#;
        let rows = parse_prs_response_mine(body, "getprivate").unwrap();
        assert_eq!(rows[0].label, "getprivate/OtherProject/other-repo");
    }
}
