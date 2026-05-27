//! Bitbucket Cloud REST API plumbing. Plain HTTPS via `reqwest::blocking`
//! (already in the dep tree for the `http` track) — no Bitbucket SDK.
//!
//! Endpoints used:
//! * `GET /2.0/user` — fetch the authenticated user's `account_id` (cached
//!   once at worker spawn; required for the cross-repo "my PRs" view).
//! * `GET /2.0/pullrequests/{account_id}` — every non-merged PR I authored,
//!   across every accessible repo (cross-repo, not config-driven).
//! * `GET /2.0/repositories/{ws}/{slug}/pullrequests?state=OPEN&pagelen=N`
//!   — open PRs for one configured repo (per-repo view).
//! * `GET /2.0/repositories/{ws}/{slug}/pullrequests/{id}` — single-PR
//!   detail with accurate `participants[]` (the list endpoint above
//!   returns stale ones, per James's bbwatch.py note).
//! * `GET /2.0/repositories/{ws}/{slug}/pipelines/?sort=-created_on&pagelen=N`
//!   — recent pipelines for one repo (mixed branches).
//! * `GET /2.0/repositories/{ws}/{slug}/pipelines/?target.branch=<b>&pagelen=1`
//!   — single most-recent pipeline for one branch (per-branch view).
//! * `GET /2.0/repositories/{ws}/{slug}/pipelines/{uuid}/steps/` — when a
//!   pipeline is `IN_PROGRESS`, find the running step name so the pane
//!   can show `▶ build` / `▶ test` instead of just "running".
//! * `GET /2.0/repositories/{ws}/{slug}/refs/branches?q='name~"release"'`
//!   — discover active release/hotfix branches to include in the
//!   per-branch view alongside the long-lived defaults.
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

/// Max open PRs to fetch per repo. Generous so the in-view "show
/// more" expander has data to reveal — the renderer caps the
/// initial display at `PR_DEFAULT_VISIBLE = 5` and the `+ N more`
/// row toggles a per-repo expand flag (see `ui::bitbucket_pull
/// _requests_view::flatten_prs`).
const PR_PAGELEN: u32 = 20;

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

/// Fetch the authenticated user's `account_id` — the path segment the
/// cross-repo `/pullrequests/{account_id}` endpoint requires. Cached
/// once per worker spawn; cheap (~150ms one-shot) so we don't need to
/// persist it.
pub fn fetch_account_id(
    client: &reqwest::blocking::Client,
    auth_header: &str,
) -> Result<String, String> {
    let url = format!("{API_BASE}/user");
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
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("parse json: {e}"))?;
    v.get("account_id")
        .and_then(|x| x.as_str())
        .map(str::to_string)
        .ok_or_else(|| "no account_id in /user response".to_string())
}

/// Pull every open pull request authored by `account_id` in one
/// workspace. Bitbucket replaced the cross-account `/pullrequests/{aid}`
/// endpoint (404s now) with the workspace-scoped form below — so callers
/// iterate the configured workspaces and merge.
pub fn fetch_my_open_pull_requests_for_workspace(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    workspace: &str,
    account_id: &str,
) -> Result<Vec<PullRequestRecord>, String> {
    use std::borrow::Cow;
    let encoded: Cow<str> = url_encode_account_id(account_id);
    let url = format!(
        "{API_BASE}/workspaces/{workspace}/pullrequests/{encoded}?state=OPEN&sort=-updated_on&pagelen=50",
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
    parse_my_pull_requests_response(&body)
}

pub fn parse_my_pull_requests_response(body: &str) -> Result<Vec<PullRequestRecord>, String> {
    let raw: RawPrPage = serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
    let mut out = Vec::new();
    for p in raw.values {
        // For the cross-repo endpoint, workspace/slug come from
        // destination.repository.full_name (always present per BB spec).
        let full_name = p
            .destination
            .as_ref()
            .and_then(|d| d.repository.as_ref())
            .and_then(|r| r.full_name.clone());
        let (ws, slug) = match full_name {
            Some(fn_str) => {
                let mut split = fn_str.splitn(2, '/');
                let w = split.next().unwrap_or("").to_string();
                let s = split.next().unwrap_or("").to_string();
                (w, s)
            }
            None => continue, // Can't render a PR without its repo identity.
        };
        out.push(project_pr(p, &ws, &slug));
    }
    Ok(out)
}

/// Minimal percent-encoder for the segments we put in URL paths. Only
/// percent-encodes characters outside the unreserved set
/// (RFC 3986 §2.3) — that's enough for `account_id` values like
/// `{abc-uuid}` and `user:1234`.
fn url_encode_account_id(s: &str) -> std::borrow::Cow<'_, str> {
    let needs_escape = s
        .bytes()
        .any(|b| !(b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_' || b == b'~'));
    if !needs_escape {
        return std::borrow::Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_' || b == b'~' {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    std::borrow::Cow::Owned(out)
}

/// Fetch a single PR's full detail — the list endpoint returns stale
/// `participants[]` so reviewer / approval / changes-requested counts
/// need this follow-up call. James's bbwatch.py note flagged this.
pub fn fetch_pr_detail(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    workspace: &str,
    slug: &str,
    id: u64,
) -> Result<PullRequestRecord, String> {
    let url = format!("{API_BASE}/repositories/{workspace}/{slug}/pullrequests/{id}");
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
    let raw: RawPullRequest =
        serde_json::from_str(&body).map_err(|e| format!("parse json: {e}"))?;
    Ok(project_pr(raw, workspace, slug))
}

/// Fetch the single most-recent pipeline for a specific branch on a
/// repo. `None` ⇒ no pipeline has ever run for that branch (or the
/// branch doesn't exist).
pub fn fetch_latest_pipeline_for_branch(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &BitbucketRepo,
    branch: &str,
) -> Result<Option<PipelineRecord>, String> {
    let url = format!(
        "{API_BASE}/repositories/{ws}/{slug}/pipelines/?sort=-created_on&pagelen=1&target.branch={branch}",
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
    let pipelines = parse_pipelines_response(&body, &repo.workspace, &repo.slug)?;
    Ok(pipelines.into_iter().next())
}

/// For an `IN_PROGRESS` pipeline, return the name of the currently-running
/// step (or `⏸ <name>` for a pending step). `None` means nothing to show
/// (no in-progress steps, or the steps endpoint errored).
pub fn fetch_running_step(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    workspace: &str,
    slug: &str,
    pipeline_uuid: &str,
) -> Option<String> {
    // UUIDs in Bitbucket are `{abc-123}` — must be percent-encoded.
    let encoded = url_encode_account_id(pipeline_uuid);
    let url = format!(
        "{API_BASE}/repositories/{workspace}/{slug}/pipelines/{encoded}/steps/?pagelen=50",
    );
    let resp = client
        .get(&url)
        .header("Authorization", auth_header)
        .header("Accept", "application/json")
        .send()
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let body = resp.text().ok()?;
    parse_running_step(&body)
}

/// Walk every step of a pipeline and concatenate each step's `/log` output
/// into one big string, with `══ step N: <name> (state) ══` headers between
/// them. Used by the in-mnml pipeline-log viewer pane.
///
/// Returns `(combined_log, web_url_of_pipeline)` on success. Errors out at
/// the first transport / non-2xx — we don't partial-fail because the user
/// asked for the whole thing.
pub fn fetch_combined_pipeline_log(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    workspace: &str,
    slug: &str,
    pipeline_uuid: &str,
) -> Result<String, String> {
    let encoded = url_encode_account_id(pipeline_uuid);
    let steps_url =
        format!("{API_BASE}/repositories/{workspace}/{slug}/pipelines/{encoded}/steps/?pagelen=50");
    let resp = client
        .get(&steps_url)
        .header("Authorization", auth_header)
        .header("Accept", "application/json")
        .send()
        .map_err(|e| format!("steps fetch: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("steps fetch: HTTP {}", resp.status()));
    }
    let body = resp.text().map_err(|e| format!("steps body: {e}"))?;
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("steps json: {e}"))?;
    let values = v
        .get("values")
        .and_then(|x| x.as_array())
        .ok_or_else(|| "steps json: no `values` array".to_string())?;
    let mut out = String::new();
    for (i, step) in values.iter().enumerate() {
        let step_uuid = step
            .get("uuid")
            .and_then(|s| s.as_str())
            .ok_or_else(|| format!("step {}: missing uuid", i + 1))?;
        let step_name = step
            .get("name")
            .and_then(|s| s.as_str())
            .unwrap_or("(unnamed step)");
        let state_name = step
            .get("state")
            .and_then(|s| s.get("name"))
            .and_then(|s| s.as_str())
            .unwrap_or("UNKNOWN");
        out.push_str(&format!(
            "\n══ step {}: {step_name}  ({state_name}) ══\n",
            i + 1
        ));
        // Fetch this step's log. Bitbucket returns the *raw* log text for
        // `/log` (not JSON), so we don't try to parse it.
        let encoded_step = url_encode_account_id(step_uuid);
        let log_url = format!(
            "{API_BASE}/repositories/{workspace}/{slug}/pipelines/{encoded}/steps/{encoded_step}/log"
        );
        let resp = client
            .get(&log_url)
            .header("Authorization", auth_header)
            .send()
            .map_err(|e| format!("step {} log: {e}", i + 1))?;
        // 404 on the log endpoint = "step never ran" (skipped / pending).
        // Treat that as "(no log)" rather than failing the whole call.
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
            .map_err(|e| format!("step {} body: {e}", i + 1))?;
        out.push_str(&text);
        if !text.ends_with('\n') {
            out.push('\n');
        }
    }
    if out.is_empty() {
        out.push_str("(this pipeline has no steps yet)\n");
    }
    Ok(out)
}

pub fn parse_running_step(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let values = v.get("values")?.as_array()?;
    // In-progress wins over pending (matches James's logic).
    let mut pending_step: Option<String> = None;
    for step in values {
        let state = step
            .get("state")
            .and_then(|s| s.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("");
        let name = step
            .get("name")
            .and_then(|n| n.as_str())
            .unwrap_or("(unnamed)")
            .to_string();
        match state {
            "IN_PROGRESS" => return Some(name),
            "PENDING" if pending_step.is_none() => {
                pending_step = Some(format!("⏸ {name}"));
            }
            _ => {}
        }
    }
    pending_step
}

/// Discover active release/hotfix branches via Bitbucket's branch search.
/// Returns up to `max_n` most-recently-active matching branches. Empty
/// `Vec` on any failure (this is an enrichment, not load-bearing).
pub fn discover_release_branches(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &BitbucketRepo,
    max_n: usize,
) -> Vec<String> {
    let url = format!(
        "{API_BASE}/repositories/{ws}/{slug}/refs/branches?q={query}&sort=-target.date&pagelen={n}",
        ws = repo.workspace,
        slug = repo.slug,
        query = "name+~+%22release%22+OR+name+~+%22hotfix%22",
        n = max_n,
    );
    let resp = match client
        .get(&url)
        .header("Authorization", auth_header)
        .header("Accept", "application/json")
        .send()
    {
        Ok(r) if r.status().is_success() => r,
        _ => return Vec::new(),
    };
    let body = match resp.text() {
        Ok(b) => b,
        Err(_) => return Vec::new(),
    };
    let v: serde_json::Value = match serde_json::from_str(&body) {
        Ok(x) => x,
        Err(_) => return Vec::new(),
    };
    v.get("values")
        .and_then(|x| x.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|b| b.get("name").and_then(|n| n.as_str()).map(str::to_string))
                .take(max_n)
                .collect()
        })
        .unwrap_or_default()
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
        "{API_BASE}/repositories/{ws}/{slug}/pullrequests?state=OPEN&pagelen={PR_PAGELEN}",
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
    let raw: RawPrPage = serde_json::from_str(body).map_err(|e| format!("parse json: {e}"))?;
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
    let author = p.author.as_ref().and_then(|a| a.display_name.clone());
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
    let target_ref = p.target.as_ref().and_then(|t| {
        // 1. Branch build → branch name.
        if let Some(ref_name) = t.ref_name.clone().or_else(|| t.branch.clone()) {
            return Some(ref_name);
        }
        // 2. PR build → `PR #1234 (source→dest)` or just `PR #1234`.
        if let Some(pr_id) = t.pullrequest.as_ref().and_then(|p| p.id) {
            let src = t
                .source_branch
                .clone()
                .or_else(|| t.source.as_ref().and_then(extract_branch_name));
            let dst = t
                .destination_branch
                .clone()
                .or_else(|| t.destination.as_ref().and_then(extract_branch_name));
            return Some(match (src, dst) {
                (Some(s), Some(d)) => format!("PR #{pr_id} {s}→{d}"),
                (Some(s), None) => format!("PR #{pr_id} {s}"),
                _ => format!("PR #{pr_id}"),
            });
        }
        // 3. Custom build → the selector's pattern (the pipeline name).
        if let Some(sel) = t.selector.as_ref() {
            if let Some(pat) = sel.pattern.clone() {
                return Some(format!("custom: {pat}"));
            }
            if let Some(kind) = sel.kind.clone() {
                return Some(format!("custom: {kind}"));
            }
        }
        None
    });
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
        // Worker enriches this for in-progress runs via a follow-up
        // /pipelines/{uuid}/steps/ call; default to None.
        running_step: None,
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
    /// For `IN_PROGRESS` pipelines, the currently-running step's name
    /// (or `⏸ <name>` if a step is pending). Populated by the worker via
    /// a follow-up `/pipelines/{uuid}/steps/` call; `None` for terminal
    /// runs or when the steps fetch failed.
    pub running_step: Option<String>,
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
    // Branch-build shape: `{ref_type: "branch", ref_name: "main", ...}`.
    ref_name: Option<String>,
    ref_type: Option<String>,
    // Older branch-build form some BB tenants still emit.
    branch: Option<String>,
    r#type: Option<String>,
    commit: Option<RawCommit>,
    // PR-build shape: `{type: "pipeline_pullrequest_target",
    // pullrequest: {id, ...}, source: <variant>, destination: <variant>}`.
    // BB returns the source/destination as either a bare branch-name
    // string OR `{branch: {name}}` — keep it as raw JSON and resolve
    // when projecting the record.
    pullrequest: Option<RawTargetPr>,
    source: Option<serde_json::Value>,
    destination: Option<serde_json::Value>,
    // Some PR-build payloads use flat `source_branch` / `destination_branch`
    // strings at the target level instead of nesting under `source`/`destination`.
    source_branch: Option<String>,
    destination_branch: Option<String>,
    // Custom-build shape: `{type: "pipeline_commit_target",
    // selector: {type: "custom", pattern: "my-pipeline"}, commit: {...}}`.
    // The selector pattern is the only human-readable identifier.
    selector: Option<RawTargetSelector>,
}

#[derive(Debug, Deserialize)]
struct RawTargetPr {
    id: Option<u64>,
}

fn extract_branch_name(v: &serde_json::Value) -> Option<String> {
    // Accept either `"branch-name"` (string) or `{branch: {name: "..."}}`.
    if let Some(s) = v.as_str() {
        return Some(s.to_string());
    }
    v.get("branch")
        .and_then(|b| b.get("name"))
        .and_then(|n| n.as_str())
        .map(str::to_string)
}

#[derive(Debug, Deserialize)]
struct RawTargetSelector {
    pattern: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
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
    /// Present on the cross-repo `/pullrequests/{account_id}` endpoint —
    /// the PR's destination repo identity, since the endpoint doesn't
    /// scope by repo. The repo-scoped list omits this (we already know).
    #[serde(default)]
    repository: Option<RawRepoSummary>,
}

#[derive(Debug, Default, Deserialize)]
struct RawRepoSummary {
    /// `"exampleorg/example-api"` form — parse on the consumer side.
    full_name: Option<String>,
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
// Same hand-rolled parser shape used in `aws::codebuild::parse_iso_ms`,
// kept inline here so the `bitbucket` module has no cross-cargo-feature
// deps (codebuild lives under `--features aws-codebuild`).

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
    fn pr_build_target_ref_renders_pr_with_branch_arrow() {
        // PR build with source + destination as nested `{branch: {name}}`.
        let body = r#"{
          "values": [{
            "build_number": 99,
            "state": { "name": "COMPLETED", "result": { "name": "SUCCESSFUL" } },
            "target": {
              "type": "pipeline_pullrequest_target",
              "pullrequest": { "id": 4545 },
              "source":      { "branch": { "name": "TE-13216-foo" } },
              "destination": { "branch": { "name": "main" } }
            }
          }]
        }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert_eq!(
            rows[0].target_ref.as_deref(),
            Some("PR #4545 TE-13216-foo→main")
        );
    }

    #[test]
    fn pr_build_target_ref_handles_flat_source_branch_form() {
        // PR build where BB used flat `source_branch` / `destination_branch`
        // strings instead of nesting under `source` / `destination`.
        let body = r#"{
          "values": [{
            "build_number": 100,
            "state": { "name": "IN_PROGRESS" },
            "target": {
              "pullrequest": { "id": 12 },
              "source_branch": "feat/x",
              "destination_branch": "develop"
            }
          }]
        }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert_eq!(rows[0].target_ref.as_deref(), Some("PR #12 feat/x→develop"));
    }

    #[test]
    fn pr_build_target_ref_falls_back_to_bare_id() {
        // PR build with no source/destination at all — render just `PR #N`.
        let body = r#"{
          "values": [{
            "build_number": 101,
            "state": { "name": "IN_PROGRESS" },
            "target": { "pullrequest": { "id": 7 } }
          }]
        }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert_eq!(rows[0].target_ref.as_deref(), Some("PR #7"));
    }

    #[test]
    fn custom_build_target_ref_renders_selector_pattern() {
        let body = r#"{
          "values": [{
            "build_number": 102,
            "state": { "name": "IN_PROGRESS" },
            "target": {
              "type": "pipeline_commit_target",
              "selector": { "type": "custom", "pattern": "deploy-staging" },
              "commit": { "hash": "abc1234" }
            }
          }]
        }"#;
        let rows = parse_pipelines_response(body, "ws", "repo").unwrap();
        assert_eq!(
            rows[0].target_ref.as_deref(),
            Some("custom: deploy-staging")
        );
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
        assert_eq!(
            PullRequestState::from_raw(Some("OPEN")),
            PullRequestState::Open
        );
        assert_eq!(
            PullRequestState::from_raw(Some("merged")),
            PullRequestState::Merged
        );
        assert_eq!(
            PullRequestState::from_raw(Some("DECLINED")),
            PullRequestState::Declined
        );
        assert_eq!(
            PullRequestState::from_raw(Some("SUPERSEDED")),
            PullRequestState::Superseded
        );
        assert_eq!(PullRequestState::from_raw(None), PullRequestState::Unknown);
    }

    #[test]
    fn pr_falls_back_to_synthesized_url() {
        let body = r#"{
          "values": [{ "id": 99, "state": "OPEN", "title": "t" }]
        }"#;
        let rows = parse_pull_requests_response(body, "ws", "repo").unwrap();
        assert_eq!(
            rows[0].web_url,
            "https://bitbucket.org/ws/repo/pull-requests/99"
        );
    }
}
