//! Bitbucket Cloud REST API integration — phase 1 (worker skeleton).
//!
//! Architecture mirrors `crate::private::docdb`, but with simpler plumbing
//! because the Bitbucket surface is plain HTTPS — no async-only dep, no
//! contained tokio runtime, just one OS thread driving `reqwest::blocking`.
//!
//! One worker thread per [`BitbucketHandle`]. The loop iterates the
//! configured `[[bitbucket.repos]]` in order, fetching recent pipelines
//! per-repo, emitting a [`BitbucketEvent::Pipelines`] for each successful
//! response and a [`BitbucketEvent::Failed`] for any error (the loop then
//! sleeps a short backoff and continues — one failing repo doesn't kill
//! the others). After visiting every repo, the loop sleeps
//! `[bitbucket] poll_secs` (default 30, floor 5) before the next pass.
//!
//! Auth: the worker reads `$<auth_env>` at spawn time
//! (default `$BITBUCKET_TOKEN`). Values containing `:` are treated as
//! `user:app_password` for Bitbucket's legacy Basic-auth scheme; bare
//! tokens use Bearer auth (the modern API token format). If the env var
//! isn't set the worker emits a single `Failed` event and exits — surfaced
//! by the future pane as a banner pointing the user at the right env var.
//!
//! Phase 2 will land `Pane::BitbucketPipelines` reading from a cache the
//! [`App`](crate::app::App) maintains by draining this channel each tick.
//! Phase 3 adds the per-PR pane.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::config::{BitbucketConfig, BitbucketRepo};

pub mod api;
pub mod log_pane;
pub mod pipelines_pane;
pub mod pull_requests_pane;

pub use api::{PipelineRecord, PipelineState, PullRequestRecord, PullRequestState};
pub use log_pane::{PipelineLogEvent, PipelineLogPane, PipelineLogState};
pub use pipelines_pane::{BitbucketPipelinesPane, PipelineViewMode};
pub use pull_requests_pane::{BitbucketPullRequestsPane, PrViewMode};

/// One row in the PerBranch pipelines cache: `(branch_name, latest_pipeline_or_none)`.
/// Aliased so the App-side `HashMap` doesn't need to spell out the
/// tuple shape (clippy warns about the complexity otherwise).
pub type BranchPipelineSlot = (String, Option<PipelineRecord>);

/// Backoff after a per-repo fetch failure before we visit the next repo
/// in the same pass. Keeps a flaky repo from spinning at full speed.
const PER_REPO_ERROR_BACKOFF: Duration = Duration::from_secs(5);

/// Events from the Bitbucket worker thread → main thread.
#[derive(Debug, Clone)]
pub enum BitbucketEvent {
    /// Latest pipelines for a single repo (newest-N, mixed branches).
    /// Replaces — not merges — the receiver's cached vec for that repo.
    /// Powers the "recent pipelines" view-mode.
    Pipelines {
        workspace: String,
        slug: String,
        pipelines: Vec<PipelineRecord>,
    },
    /// Latest pipeline per branch for one repo (one row per branch in
    /// the per-branch view-mode). The branch list is resolved per-pass
    /// from `[[bitbucket.repos]] branches = […]` overlaid with
    /// [`crate::config::default_branches()`] and auto-discovered active
    /// release / hotfix branches. `Option<PipelineRecord>` is `None`
    /// when a branch has no pipelines (kept in the result so the pane
    /// renders the row anyway — useful when adding a new long-lived
    /// branch).
    BranchPipelines {
        workspace: String,
        slug: String,
        /// Branch name → its most-recent pipeline (or `None` if it
        /// never ran one).
        per_branch: Vec<(String, Option<PipelineRecord>)>,
    },
    /// Latest open pull requests for a single repo. Powers the
    /// "per-repo grouped" PR view-mode.
    PullRequests {
        workspace: String,
        slug: String,
        pull_requests: Vec<PullRequestRecord>,
    },
    /// Every non-merged PR the authenticated user authored, across
    /// every accessible repo (NOT scoped to configured repos). Powers
    /// the cross-repo "mine" PR view-mode. Replaces the cache wholesale
    /// each poll cycle.
    MyPullRequests(Vec<PullRequestRecord>),
    /// At least one successful response has landed. Pane drops the
    /// "loading…" chip on first receipt.
    Connected,
    /// Connection / parse / auth error — the `String` is a user-facing
    /// summary. The pane surfaces this as a banner. The worker keeps
    /// polling after backoff.
    Failed(String),
}

/// Handle returned by [`spawn`]. Dropping it signals the worker to stop
/// at the next iteration boundary.
pub struct BitbucketHandle {
    pub rx: Receiver<BitbucketEvent>,
    cancel: Arc<AtomicBool>,
    /// Wake the worker out of its sleep early — set by [`Self::force_refresh`]
    /// when the user presses `r` in the pane. Cleared by the worker on the
    /// next pass start.
    wake: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl BitbucketHandle {
    /// Wake the worker so it issues a fresh poll *now* rather than at the
    /// next `poll_secs` boundary. Returns immediately; results land on the
    /// channel as usual. Called from the pane's `r` key handler.
    pub fn force_refresh(&self) {
        self.wake.store(true, Ordering::Relaxed);
    }
}

impl Drop for BitbucketHandle {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
        if let Some(handle) = self.join.take() {
            let _ = handle.join();
        }
    }
}

/// Spawn the worker. When the config has no repos OR the auth env var is
/// unset, emits a single `Failed("…")` then exits — the pane surfaces it
/// as a hint about what to configure.
pub fn spawn(cfg: BitbucketConfig) -> BitbucketHandle {
    let (tx, rx) = channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let wake = Arc::new(AtomicBool::new(false));
    let cancel_for_thread = cancel.clone();
    let wake_for_thread = wake.clone();
    let join = thread::spawn(move || run_thread(cfg, tx, cancel_for_thread, wake_for_thread));
    BitbucketHandle {
        rx,
        cancel,
        wake,
        join: Some(join),
    }
}

fn run_thread(
    cfg: BitbucketConfig,
    tx: Sender<BitbucketEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
) {
    if !cfg.any_configured() {
        let _ = tx.send(BitbucketEvent::Failed(
            "no [[bitbucket.repos]] configured — add a workspace/slug pair in \
             ~/.config/mnml/config.toml"
                .to_string(),
        ));
        return;
    }
    let auth_env = cfg.auth_env_name().to_string();
    let token = match std::env::var(&auth_env) {
        Ok(t) if !t.is_empty() => t,
        _ => {
            let _ = tx.send(BitbucketEvent::Failed(format!(
                "${auth_env} not set — export your Bitbucket API token (or app password \
                 as user:password) before launching mnml"
            )));
            return;
        }
    };
    let client = match api::build_client() {
        Ok(c) => c,
        Err(e) => {
            let _ = tx.send(BitbucketEvent::Failed(format!("reqwest client: {e}")));
            return;
        }
    };
    let auth_header = api::auth_header_value(&token);
    let poll_interval = Duration::from_secs(cfg.poll_secs_or_default());

    // Fetch account_id once at spawn — required for the cross-repo
    // /pullrequests/{account_id} endpoint. Tokens without user-read scope
    // (workspace-scoped tokens, most common) 403 here. The per-repo views
    // still work, so we swallow the failure silently — the empty Mine PR
    // view is self-documenting. Surfacing it as a Failed event would flash
    // a banner that disappears on the first successful pipelines fetch.
    let account_id = api::fetch_account_id(&client, &auth_header).ok();

    let mut have_sent_connected = false;
    while !cancel.load(Ordering::Relaxed) {
        wake.store(false, Ordering::Relaxed);

        // ── Cross-repo: my open PRs (one list call + per-PR detail
        // calls to populate accurate participants — the list endpoint
        // returns stale ones, per James's bbwatch.py note). ────────────
        if let Some(aid) = account_id.as_deref() {
            match api::fetch_my_open_pull_requests(&client, &auth_header, aid) {
                Ok(mut prs) => {
                    if !have_sent_connected {
                        have_sent_connected = true;
                        let _ = tx.send(BitbucketEvent::Connected);
                    }
                    // Enrich each PR with detail-endpoint data so the
                    // ✓N / ✗N counts are accurate. Bounded by the
                    // pagelen=50 on the list call. Failures per-PR are
                    // silent — we just keep the stale row from the list.
                    for pr in prs.iter_mut() {
                        if cancel.load(Ordering::Relaxed) {
                            return;
                        }
                        if let Ok(detail) = api::fetch_pr_detail(
                            &client,
                            &auth_header,
                            &pr.workspace,
                            &pr.slug,
                            pr.id,
                        ) {
                            pr.reviewer_count = detail.reviewer_count;
                            pr.approved_count = detail.approved_count;
                            pr.changes_count = detail.changes_count;
                            pr.comment_count = detail.comment_count;
                            pr.task_count = detail.task_count;
                            // The list endpoint already gave us source / dest
                            // branches; detail has them too but the values
                            // should match.
                        }
                    }
                    let _ = tx.send(BitbucketEvent::MyPullRequests(prs));
                }
                Err(e) => {
                    let _ = tx.send(BitbucketEvent::Failed(format!("my prs: {e}")));
                }
            }
        }

        // ── Per-repo: pipelines + open PRs + per-branch pipelines ──────
        for repo in &cfg.repos {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            // Recent pipelines (newest-N mixed-branch).
            match api::fetch_recent_pipelines(&client, &auth_header, repo) {
                Ok(pipelines) => {
                    if !have_sent_connected {
                        have_sent_connected = true;
                        let _ = tx.send(BitbucketEvent::Connected);
                    }
                    let _ = tx.send(BitbucketEvent::Pipelines {
                        workspace: repo.workspace.clone(),
                        slug: repo.slug.clone(),
                        pipelines,
                    });
                }
                Err(e) => {
                    let _ = tx.send(BitbucketEvent::Failed(format!(
                        "{ws}/{slug}: pipelines: {e}",
                        ws = repo.workspace,
                        slug = repo.slug,
                    )));
                    sleep_cancellable_with_wake(PER_REPO_ERROR_BACKOFF, &cancel, &wake);
                }
            }
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            // Per-branch latest pipeline. Branch list is the config's
            // explicit branches, then default_branches, then discovered
            // active release/hotfix branches — deduped, order preserved.
            let branches = resolve_branches(&client, &auth_header, repo, &cancel);
            let mut per_branch: Vec<(String, Option<PipelineRecord>)> = Vec::new();
            for branch in &branches {
                if cancel.load(Ordering::Relaxed) {
                    return;
                }
                match api::fetch_latest_pipeline_for_branch(&client, &auth_header, repo, branch) {
                    Ok(Some(mut pipeline)) => {
                        // For in-progress runs, enrich with the running
                        // step name. James's bbwatch.py polish.
                        if !pipeline.state.is_terminal() && !pipeline.uuid.is_empty() {
                            pipeline.running_step = api::fetch_running_step(
                                &client,
                                &auth_header,
                                &repo.workspace,
                                &repo.slug,
                                &pipeline.uuid,
                            );
                        }
                        per_branch.push((branch.clone(), Some(pipeline)));
                    }
                    Ok(None) => {
                        // Branch exists but has no pipelines — only include
                        // it if it was explicitly configured (otherwise the
                        // default-branches list pollutes repos that don't
                        // use one of the defaults).
                        if repo.branches.iter().any(|b| b == branch) {
                            per_branch.push((branch.clone(), None));
                        }
                    }
                    Err(_) => {
                        // Don't spam Failed events per-branch — they add
                        // up too quickly. Just skip the branch this pass.
                    }
                }
            }
            let _ = tx.send(BitbucketEvent::BranchPipelines {
                workspace: repo.workspace.clone(),
                slug: repo.slug.clone(),
                per_branch,
            });
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            // Per-repo open PRs (still useful for the per-repo grouped view).
            match api::fetch_open_pull_requests(&client, &auth_header, repo) {
                Ok(pull_requests) => {
                    let _ = tx.send(BitbucketEvent::PullRequests {
                        workspace: repo.workspace.clone(),
                        slug: repo.slug.clone(),
                        pull_requests,
                    });
                }
                Err(e) => {
                    let _ = tx.send(BitbucketEvent::Failed(format!(
                        "{ws}/{slug}: prs: {e}",
                        ws = repo.workspace,
                        slug = repo.slug,
                    )));
                    sleep_cancellable_with_wake(PER_REPO_ERROR_BACKOFF, &cancel, &wake);
                }
            }
        }
        sleep_cancellable_with_wake(poll_interval, &cancel, &wake);
    }
}

/// Build the deduped, ordered branch list for one repo's per-branch
/// pipeline fetch. Order: explicit `[[bitbucket.repos]] branches = […]`
/// first, then [`crate::config::default_branches()`], then up to 2
/// recently-active release/hotfix branches discovered via the BB
/// `refs/branches?q=` search. Auto-discovery is best-effort and silent
/// on failure (it's an enrichment, not load-bearing).
fn resolve_branches(
    client: &reqwest::blocking::Client,
    auth_header: &str,
    repo: &BitbucketRepo,
    cancel: &Arc<AtomicBool>,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for b in &repo.branches {
        if !out.iter().any(|x| x == b) {
            out.push(b.clone());
        }
    }
    for b in crate::config::default_branches() {
        if !out.iter().any(|x| x == b) {
            out.push((*b).to_string());
        }
    }
    if cancel.load(Ordering::Relaxed) {
        return out;
    }
    for b in api::discover_release_branches(client, auth_header, repo, 2) {
        if !out.iter().any(|x| x == &b) {
            out.push(b);
        }
    }
    out
}

/// Sleep `dur`, waking early on either `cancel` or `wake`. Keeps shutdown
/// responsive (cancel fires within `CHECK_INTERVAL` of the App dropping
/// the handle) AND lets the pane's `r` key trigger an immediate refresh.
fn sleep_cancellable_with_wake(dur: Duration, cancel: &Arc<AtomicBool>, wake: &Arc<AtomicBool>) {
    const CHECK_INTERVAL: Duration = Duration::from_millis(250);
    let mut remaining = dur;
    while remaining > Duration::ZERO {
        if cancel.load(Ordering::Relaxed) || wake.load(Ordering::Relaxed) {
            return;
        }
        let chunk = remaining.min(CHECK_INTERVAL);
        thread::sleep(chunk);
        remaining = remaining.saturating_sub(chunk);
    }
}

/// One row in a future `Pane::BitbucketPipelines`. Re-exported here so
/// `App`-side consumers don't need to dig into `api::` for the shape.
#[allow(dead_code)] // Phase 1: built but not yet consumed by a pane.
pub type Repo = BitbucketRepo;
