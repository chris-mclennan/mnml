//! Cross-host SCM aggregation — fans out to the `mnml-forge-*`
//! sibling binaries via their `--list-prs --json` and
//! `--find-pipeline-for-pr --json` headless modes, merges results,
//! and exposes them to the `pr.picker` command + the rail's
//! "Open PRs" subsection.
//!
//! Sibling contract (matches every `mnml-forge-*` v0.1+):
//!
//! ```text
//! mnml-forge-<host> --list-prs --json
//!   → stdout: { host: "...", prs: [SiblingPr, ...] }
//!
//! mnml-forge-<host> --find-pipeline-for-pr --owner <o> --repo <r>
//!     --branch <b> --json
//!   → stdout: { url: "..." | null }
//! ```
//!
//! Per-sibling errors land on stderr and don't tank the merge — we
//! just skip that host and surface what the others returned.

use serde::Deserialize;
use std::process::Command;
use std::time::{Duration, Instant};

/// One PR row in the cross-host JSON schema. Field set must stay in
/// sync with each `mnml-forge-*/src/headless.rs`.
#[derive(Debug, Clone, Deserialize)]
pub struct SiblingPr {
    pub id: String,
    pub url: String,
    pub owner: String,
    pub repo: String,
    pub title: String,
    pub author: String,
    /// Null on hosts where the list endpoint doesn't return head.ref
    /// (e.g. GitHub's Issues search). Cross-nav falls back to "most
    /// recent run on the repo" when null.
    #[serde(default)]
    pub source_branch: Option<String>,
    #[serde(default)]
    pub dest_branch: Option<String>,
    pub state: String,
    pub updated_at: String,
    pub remote_url_https: String,
    pub remote_url_ssh: String,
    /// Set by `aggregate_all` to the `mnml-forge-*` host tag the row
    /// came from. Used for cross-nav dispatch + remote-URL matching.
    #[serde(default)]
    pub host: String,
}

#[derive(Debug, Deserialize)]
struct ListPrsResponse {
    host: String,
    prs: Vec<SiblingPr>,
}

#[derive(Debug, Deserialize)]
struct PipelineResponse {
    url: Option<String>,
}

/// All known forge-sibling binaries — the order is the merge order
/// for the picker. New siblings just get added here; missing
/// binaries (not on `$PATH`) are silently skipped, so users only
/// see what they have installed.
pub const KNOWN_FORGE_SIBLINGS: &[&str] = &[
    "mnml-forge-bitbucket",
    "mnml-forge-github",
    "mnml-forge-gitlab",
    "mnml-forge-azdevops",
];

/// Cache wrapper for the cross-host PR list. Refreshed on
/// `pr.refresh`, on `pr.picker` if older than `MAX_AGE`, and
/// rebuilt on demand from the rail's open-PRs path.
#[derive(Debug, Clone)]
pub struct ScmPrCache {
    pub prs: Vec<SiblingPr>,
    pub fetched_at: Instant,
    /// Stderr blobs per sibling — surfaces in a "PRs (with errors)"
    /// toast when something failed.
    pub errors: Vec<(String, String)>,
}

impl ScmPrCache {
    pub const MAX_AGE: Duration = Duration::from_secs(5 * 60);

    pub fn is_stale(&self) -> bool {
        self.fetched_at.elapsed() > Self::MAX_AGE
    }
}

/// Synchronous fan-out: run `--list-prs --json` against every
/// installed forge sibling, collect results. Per-sibling failures
/// are captured in the returned errors vec; we never propagate a
/// single sibling's error up.
///
/// Called from a worker thread (each call spawns the sibling
/// binaries and blocks on their HTTP calls — total wall-clock is
/// max of the four, ~1-3 seconds typically).
pub fn aggregate_all() -> ScmPrCache {
    let mut prs: Vec<SiblingPr> = Vec::new();
    let mut errors: Vec<(String, String)> = Vec::new();
    for bin in KNOWN_FORGE_SIBLINGS {
        match run_list_prs(bin) {
            Ok(mut response) => {
                for pr in &mut response.prs {
                    pr.host = response.host.clone();
                }
                prs.extend(response.prs);
            }
            Err(e) => {
                // Missing-binary is the most common path — silent.
                if !is_missing_binary(&e) {
                    errors.push((bin.to_string(), e));
                }
            }
        }
    }
    // Sort by `updated_at` descending — "what's happening now" first.
    prs.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    ScmPrCache {
        prs,
        fetched_at: Instant::now(),
        errors,
    }
}

fn run_list_prs(bin: &str) -> Result<ListPrsResponse, String> {
    let output = Command::new(bin)
        .arg("--list-prs")
        .arg("--json")
        .output()
        .map_err(|e| format!("spawn: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "exit {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    serde_json::from_slice(&output.stdout).map_err(|e| format!("parse JSON: {e}"))
}

fn is_missing_binary(err: &str) -> bool {
    err.contains("No such file or directory")
        || err.contains("not found")
        || err.contains("entity not found")
}

/// Synchronous lookup for a PR's pipeline URL — dispatches to the
/// matching forge sibling based on `host`. Returns `Some(url)` on
/// success, `None` when the sibling reports no matching pipeline or
/// errors. Called from a worker thread; takes ~1 second typically.
pub fn find_pipeline_url(host: &str, owner: &str, repo: &str, branch: &str) -> Option<String> {
    let bin = match host {
        "bitbucket" => "mnml-forge-bitbucket",
        "github" => "mnml-forge-github",
        "gitlab" => "mnml-forge-gitlab",
        "azdevops" => "mnml-forge-azdevops",
        _ => return None,
    };
    let output = Command::new(bin)
        .arg("--find-pipeline-for-pr")
        .arg("--owner")
        .arg(owner)
        .arg("--repo")
        .arg(repo)
        .arg("--branch")
        .arg(branch)
        .arg("--json")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let resp: PipelineResponse = serde_json::from_slice(&output.stdout).ok()?;
    resp.url
}

/// Match a PR against a `remote.origin.url` from `git config`. Each
/// sibling emits both `https://…` and `git@…` forms so we just
/// substring-match. Returns true when the URL matches either form
/// (with or without a trailing `.git`).
pub fn pr_matches_remote(pr: &SiblingPr, remote: &str) -> bool {
    let r = remote.trim_end_matches(".git");
    let https = pr.remote_url_https.trim_end_matches(".git");
    let ssh = pr.remote_url_ssh.trim_end_matches(".git");
    r == https || r == ssh
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pr_matches_https_remote() {
        let pr = SiblingPr {
            id: "1".into(),
            url: "u".into(),
            owner: "foo".into(),
            repo: "bar".into(),
            title: "t".into(),
            author: "a".into(),
            source_branch: None,
            dest_branch: None,
            state: "open".into(),
            updated_at: "x".into(),
            remote_url_https: "https://github.com/foo/bar.git".into(),
            remote_url_ssh: "git@github.com:foo/bar.git".into(),
            host: "github".into(),
        };
        assert!(pr_matches_remote(&pr, "https://github.com/foo/bar.git"));
        assert!(pr_matches_remote(&pr, "https://github.com/foo/bar"));
        assert!(pr_matches_remote(&pr, "git@github.com:foo/bar.git"));
        assert!(!pr_matches_remote(&pr, "https://github.com/foo/baz"));
    }
}
