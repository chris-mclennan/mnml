//! GitLab REST API plumbing. Plain HTTPS via `reqwest::blocking` —
//! same pattern as the BB / GH siblings. The project identifier can
//! be either a numeric ID (`"12345"`) or a URL-encoded path
//! (`"group%2Fproject"`); we URL-encode unconditionally so either
//! input form works.
//!
//! Endpoints used:
//! * `GET /projects/{id}/pipelines?per_page=N` — recent pipelines for a project.
//! * `GET /projects/{id}/pipelines?ref=<branch>&per_page=1` — latest on branch.
//! * `GET /projects/{id}/merge_requests?state=opened&per_page=N` — open MRs.
//! * `GET /merge_requests?scope=created_by_me&state=opened&per_page=N` —
//!   cross-project Mine MRs (uses the global endpoint with `scope=`).
//!
//! Auth: `Authorization: Bearer <token>`. PATs (`glpat_*`) and project
//! access tokens both work with Bearer.

use std::time::Duration;

use serde::Deserialize;

use crate::config::GitlabProject;

const PER_PAGE: u32 = 20;
const HTTP_TIMEOUT: Duration = Duration::from_secs(20);

pub fn build_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())
}

pub fn auth_header_value(token: &str) -> String {
    format!("Bearer {}", token.trim())
}

/// URL-encode the project identifier so GitLab accepts either a
/// numeric ID or a path (`group/project`). Reuses the small encoder
/// shape from the BB sibling.
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

/// Walk every job of a pipeline and concatenate each job's `/trace` output
/// into one big string, with `══ job N: <name> (status) ══` separators
/// between them. Sibling to `bitbucket::fetch_combined_pipeline_log` and
/// `github::fetch_combined_run_log`.
///
/// GitLab's per-job trace endpoint returns plain text. Skipped / manual /
/// pending jobs return a 200 with an empty body — render as `(no log)` so
/// the structure still shows.
pub fn fetch_combined_pipeline_log(
    client: &reqwest::blocking::Client,
    base_url: &str,
    auth_header: &str,
    project: &str,
    pipeline_id: u64,
) -> Result<String, String> {
    let id = url_encode(project);
    let jobs_url = format!("{base_url}/projects/{id}/pipelines/{pipeline_id}/jobs?per_page=100");
    let body = http_get(client, &jobs_url, auth_header).map_err(|e| format!("jobs fetch: {e}"))?;
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("jobs json: {e}"))?;
    let jobs = v
        .as_array()
        .ok_or_else(|| "jobs json: not an array".to_string())?;
    let mut out = String::new();
    for (i, job) in jobs.iter().enumerate() {
        let job_id = job
            .get("id")
            .and_then(|x| x.as_u64())
            .ok_or_else(|| format!("job {}: missing id", i + 1))?;
        let job_name = job
            .get("name")
            .and_then(|s| s.as_str())
            .unwrap_or("(unnamed job)");
        let status = job.get("status").and_then(|s| s.as_str()).unwrap_or("?");
        out.push_str(&format!("\n══ job {}: {job_name}  ({status}) ══\n", i + 1));
        let trace_url = format!("{base_url}/projects/{id}/jobs/{job_id}/trace");
        let resp = client
            .get(&trace_url)
            .header("Authorization", auth_header)
            .send()
            .map_err(|e| format!("job {} trace: {e}", i + 1))?;
        // GitLab returns 404 for never-run jobs (skipped / manual not started).
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
            .map_err(|e| format!("job {} body: {e}", i + 1))?;
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
        out.push_str("(this pipeline has no jobs yet)\n");
    }
    Ok(out)
}

pub fn fetch_recent_pipelines(
    client: &reqwest::blocking::Client,
    base_url: &str,
    auth_header: &str,
    project: &GitlabProject,
) -> Result<Vec<PipelineRecord>, String> {
    let id = url_encode(&project.project);
    let url = format!("{base_url}/projects/{id}/pipelines?per_page={PER_PAGE}");
    let body = http_get(client, &url, auth_header)?;
    parse_pipelines_response(&body, &project.project)
}

pub fn fetch_latest_pipeline_for_branch(
    client: &reqwest::blocking::Client,
    base_url: &str,
    auth_header: &str,
    project: &GitlabProject,
    branch: &str,
) -> Result<Option<PipelineRecord>, String> {
    let id = url_encode(&project.project);
    let branch_enc = url_encode(branch);
    let url = format!(
        "{base_url}/projects/{id}/pipelines?ref={branch_enc}&per_page=1&order_by=id&sort=desc"
    );
    let body = http_get(client, &url, auth_header)?;
    let pipelines = parse_pipelines_response(&body, &project.project)?;
    Ok(pipelines.into_iter().next())
}

pub fn fetch_open_merge_requests(
    client: &reqwest::blocking::Client,
    base_url: &str,
    auth_header: &str,
    project: &GitlabProject,
) -> Result<Vec<MergeRequestRecord>, String> {
    let id = url_encode(&project.project);
    let url = format!(
        "{base_url}/projects/{id}/merge_requests?state=opened&per_page={PER_PAGE}&order_by=updated_at&sort=desc"
    );
    let body = http_get(client, &url, auth_header)?;
    parse_mrs_response(&body, Some(project.project.as_str()))
}

pub fn fetch_my_open_merge_requests(
    client: &reqwest::blocking::Client,
    base_url: &str,
    auth_header: &str,
) -> Result<Vec<MergeRequestRecord>, String> {
    let url = format!(
        "{base_url}/merge_requests?scope=created_by_me&state=opened&per_page=50&order_by=updated_at&sort=desc"
    );
    let body = http_get(client, &url, auth_header)?;
    // Mine endpoint returns project_id (numeric) per MR — use that as the project identifier.
    parse_mrs_response(&body, None)
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

pub fn parse_pipelines_response(body: &str, project: &str) -> Result<Vec<PipelineRecord>, String> {
    let raw: Vec<RawPipeline> =
        serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    Ok(raw
        .into_iter()
        .map(|p| project_pipeline(p, project))
        .collect())
}

fn project_pipeline(p: RawPipeline, project: &str) -> PipelineRecord {
    let state = PipelineState::from_raw(p.status.as_deref().unwrap_or(""));
    let created_at_ms = p.created_at.as_deref().and_then(parse_iso_ms);
    let updated_at_ms = p.updated_at.as_deref().and_then(parse_iso_ms);
    let duration_secs = p
        .duration
        .filter(|&d| d >= 0)
        .map(|d| d as u64)
        .or_else(|| match (created_at_ms, updated_at_ms) {
            (Some(s), Some(e)) if e >= s && state.is_terminal() => Some(((e - s) / 1000) as u64),
            _ => None,
        });
    PipelineRecord {
        project: project.to_string(),
        id: p.id.unwrap_or(0),
        iid: p.iid.unwrap_or(0),
        state,
        target_ref: p.r#ref,
        commit_hash: p.sha,
        created_at_ms,
        updated_at_ms,
        duration_secs,
        web_url: p
            .web_url
            .unwrap_or_else(|| format!("https://gitlab.com/{project}/-/pipelines")),
    }
}

pub fn parse_mrs_response(
    body: &str,
    project_hint: Option<&str>,
) -> Result<Vec<MergeRequestRecord>, String> {
    let raw: Vec<RawMr> = serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    Ok(raw
        .into_iter()
        .map(|m| project_mr(m, project_hint))
        .collect())
}

fn project_mr(m: RawMr, project_hint: Option<&str>) -> MergeRequestRecord {
    let state = MergeRequestState::from_raw(m.state.as_deref().unwrap_or(""), m.draft);
    let created_at_ms = m.created_at.as_deref().and_then(parse_iso_ms);
    let updated_at_ms = m.updated_at.as_deref().and_then(parse_iso_ms);
    let project = project_hint
        .map(str::to_string)
        .or_else(|| m.project_id.map(|n| n.to_string()))
        .unwrap_or_default();
    MergeRequestRecord {
        project,
        iid: m.iid.unwrap_or(0),
        title: m.title.unwrap_or_default(),
        state,
        author: m.author.and_then(|a| a.username),
        source_branch: m.source_branch,
        dest_branch: m.target_branch,
        reviewer_count: m.reviewers.as_ref().map(|r| r.len() as u32).unwrap_or(0),
        approved_count: 0, // populated separately by /approvals when we wire it (phase 4)
        changes_count: 0,
        comment_count: m.user_notes_count.unwrap_or(0),
        created_at_ms,
        updated_at_ms,
        web_url: m
            .web_url
            .unwrap_or_else(|| "https://gitlab.com".to_string()),
    }
}

// ─── Public projected types ────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct PipelineRecord {
    pub project: String,
    /// Pipeline ID (global). Used to construct URLs.
    pub id: u64,
    /// Pipeline IID (per-project). What users see in the UI as `#123`.
    pub iid: u64,
    pub state: PipelineState,
    pub target_ref: Option<String>,
    pub commit_hash: Option<String>,
    pub created_at_ms: Option<i64>,
    pub updated_at_ms: Option<i64>,
    pub duration_secs: Option<u64>,
    pub web_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipelineState {
    Success,
    Failed,
    Canceled,
    Skipped,
    Running,
    Pending,
    Created,
    Manual,
    Scheduled,
    Preparing,
    WaitingForResource,
    Unknown,
}

impl PipelineState {
    fn from_raw(s: &str) -> Self {
        match s {
            "success" => Self::Success,
            "failed" => Self::Failed,
            "canceled" => Self::Canceled,
            "skipped" => Self::Skipped,
            "running" => Self::Running,
            "pending" => Self::Pending,
            "created" => Self::Created,
            "manual" => Self::Manual,
            "scheduled" => Self::Scheduled,
            "preparing" => Self::Preparing,
            "waiting_for_resource" => Self::WaitingForResource,
            _ => Self::Unknown,
        }
    }
    pub fn glyph(self) -> &'static str {
        match self {
            Self::Success => "✓",
            Self::Failed => "✗",
            Self::Canceled => "⊘",
            Self::Skipped => "↷",
            Self::Running => "⏵",
            Self::Pending | Self::Created | Self::Preparing => "·",
            Self::Manual => "✋",
            Self::Scheduled => "⏰",
            Self::WaitingForResource => "⏳",
            Self::Unknown => "?",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Success => "succeeded",
            Self::Failed => "failed",
            Self::Canceled => "canceled",
            Self::Skipped => "skipped",
            Self::Running => "running",
            Self::Pending => "pending",
            Self::Created => "created",
            Self::Manual => "manual",
            Self::Scheduled => "scheduled",
            Self::Preparing => "preparing",
            Self::WaitingForResource => "waiting",
            Self::Unknown => "unknown",
        }
    }
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Success | Self::Failed | Self::Canceled | Self::Skipped
        )
    }
}

#[derive(Debug, Clone)]
pub struct MergeRequestRecord {
    pub project: String,
    /// `iid` is the per-project number (what shows in the URL).
    pub iid: u64,
    pub title: String,
    pub state: MergeRequestState,
    pub author: Option<String>,
    pub source_branch: Option<String>,
    pub dest_branch: Option<String>,
    pub reviewer_count: u32,
    pub approved_count: u32,
    pub changes_count: u32,
    pub comment_count: u32,
    pub created_at_ms: Option<i64>,
    pub updated_at_ms: Option<i64>,
    pub web_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeRequestState {
    Opened,
    Draft,
    Merged,
    Closed,
    Unknown,
}

impl MergeRequestState {
    fn from_raw(s: &str, draft: bool) -> Self {
        if draft {
            return Self::Draft;
        }
        match s {
            "opened" => Self::Opened,
            "merged" => Self::Merged,
            "closed" => Self::Closed,
            _ => Self::Unknown,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Opened => "opened",
            Self::Draft => "draft",
            Self::Merged => "merged",
            Self::Closed => "closed",
            Self::Unknown => "unknown",
        }
    }
}

// ─── Raw deser shapes ─────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct RawPipeline {
    id: Option<u64>,
    iid: Option<u64>,
    status: Option<String>,
    r#ref: Option<String>,
    sha: Option<String>,
    created_at: Option<String>,
    updated_at: Option<String>,
    duration: Option<i64>,
    web_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawMr {
    iid: Option<u64>,
    project_id: Option<u64>,
    title: Option<String>,
    state: Option<String>,
    draft: bool,
    author: Option<RawAuthor>,
    source_branch: Option<String>,
    target_branch: Option<String>,
    reviewers: Option<Vec<RawAuthor>>,
    user_notes_count: Option<u32>,
    created_at: Option<String>,
    updated_at: Option<String>,
    web_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawAuthor {
    username: Option<String>,
}

// ─── ISO-8601 → epoch ms (same parser as BB/GH siblings) ──────────────

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
    fn pipeline_states_map() {
        assert_eq!(PipelineState::from_raw("success"), PipelineState::Success);
        assert_eq!(PipelineState::from_raw("failed"), PipelineState::Failed);
        assert_eq!(PipelineState::from_raw("running"), PipelineState::Running);
        assert_eq!(PipelineState::from_raw("garbage"), PipelineState::Unknown);
    }

    #[test]
    fn url_encoding_path_form() {
        assert_eq!(url_encode("group/project"), "group%2Fproject");
        assert_eq!(url_encode("12345"), "12345");
    }

    #[test]
    fn parse_pipelines_smoke() {
        let body = r#"[{
            "id": 1001, "iid": 42, "status": "success",
            "ref": "main", "sha": "abc123",
            "created_at": "2026-05-15T14:37:02Z",
            "updated_at": "2026-05-15T14:42:08Z",
            "duration": 306,
            "web_url": "https://gitlab.com/g/p/-/pipelines/1001"
        }]"#;
        let rows = parse_pipelines_response(body, "g/p").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].iid, 42);
        assert_eq!(rows[0].state, PipelineState::Success);
        assert_eq!(rows[0].duration_secs, Some(306));
    }

    #[test]
    fn parse_mr_smoke() {
        let body = r#"[{
            "iid": 5, "project_id": 12345,
            "title": "Add feature", "state": "opened", "draft": false,
            "author": {"username": "chris"},
            "source_branch": "feat/x", "target_branch": "main",
            "reviewers": [{"username": "alice"}],
            "user_notes_count": 3,
            "created_at": "2026-05-10T10:00:00Z",
            "updated_at": "2026-05-15T10:00:00Z",
            "web_url": "https://gitlab.com/g/p/-/merge_requests/5"
        }]"#;
        let rows = parse_mrs_response(body, None).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].iid, 5);
        assert_eq!(rows[0].project, "12345");
        assert_eq!(rows[0].state, MergeRequestState::Opened);
        assert_eq!(rows[0].author.as_deref(), Some("chris"));
        assert_eq!(rows[0].reviewer_count, 1);
        assert_eq!(rows[0].comment_count, 3);
    }
}
