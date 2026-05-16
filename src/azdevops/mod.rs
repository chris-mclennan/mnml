//! Azure DevOps integration. Parallel to bitbucket / github / gitlab —
//! Builds + PullRequests dashboards. Less battle-tested than the other
//! hosts; expect to refine field projections + state mapping when a
//! real Azure team starts using mnml against their org.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::config::{AzDevOpsConfig, AzDevOpsProject};

pub mod api;
pub mod builds_pane;
pub mod pull_requests_pane;

pub use api::{BuildRecord, BuildState, PullRequestRecord, PullRequestState};
pub use builds_pane::{AzBuildsViewMode, AzDevOpsBuildsPane};
pub use pull_requests_pane::{AzDevOpsPullRequestsPane, AzPrViewMode};

pub type BranchBuildSlot = (String, Option<BuildRecord>);

const PER_PROJECT_ERROR_BACKOFF: Duration = Duration::from_secs(5);

/// Project entries get a label like `"org/project/repo"` used as the
/// header key in renderers + collapse set lookups.
pub fn project_label(p: &AzDevOpsProject) -> String {
    format!("{}/{}/{}", p.org, p.project, p.repo)
}

#[derive(Debug, Clone)]
pub enum AzDevOpsEvent {
    Builds {
        label: String,
        builds: Vec<BuildRecord>,
    },
    BranchBuilds {
        label: String,
        per_branch: Vec<BranchBuildSlot>,
    },
    PullRequests {
        label: String,
        pull_requests: Vec<PullRequestRecord>,
    },
    MyPullRequests(Vec<PullRequestRecord>),
    Connected,
    Failed(String),
}

pub struct AzDevOpsHandle {
    pub rx: Receiver<AzDevOpsEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl AzDevOpsHandle {
    pub fn force_refresh(&self) {
        self.wake.store(true, Ordering::Relaxed);
    }
}

impl Drop for AzDevOpsHandle {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
        if let Some(handle) = self.join.take() {
            let _ = handle.join();
        }
    }
}

pub fn spawn(cfg: AzDevOpsConfig) -> AzDevOpsHandle {
    let (tx, rx) = channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let wake = Arc::new(AtomicBool::new(false));
    let cf = cancel.clone();
    let wf = wake.clone();
    let join = thread::spawn(move || run_thread(cfg, tx, cf, wf));
    AzDevOpsHandle {
        rx,
        cancel,
        wake,
        join: Some(join),
    }
}

fn run_thread(
    cfg: AzDevOpsConfig,
    tx: Sender<AzDevOpsEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
) {
    if !cfg.any_configured() {
        let _ = tx.send(AzDevOpsEvent::Failed(
            "no [[azdevops.projects]] configured".to_string(),
        ));
        return;
    }
    let auth_env = cfg.auth_env_name().to_string();
    let token = match std::env::var(&auth_env) {
        Ok(t) if !t.is_empty() => t,
        _ => {
            let _ = tx.send(AzDevOpsEvent::Failed(format!(
                "${auth_env} not set — export your Azure DevOps PAT first"
            )));
            return;
        }
    };
    let client = match api::build_client() {
        Ok(c) => c,
        Err(e) => {
            let _ = tx.send(AzDevOpsEvent::Failed(format!("reqwest: {e}")));
            return;
        }
    };
    let auth_header = api::auth_header_value(&token);
    let poll_interval = Duration::from_secs(cfg.poll_secs_or_default());
    let creator_id = cfg.creator_id.clone();

    // Per-org dedup for Mine fetches.
    let mut orgs: Vec<String> = cfg.projects.iter().map(|p| p.org.clone()).collect();
    orgs.sort();
    orgs.dedup();

    let mut have_sent_connected = false;
    while !cancel.load(Ordering::Relaxed) {
        wake.store(false, Ordering::Relaxed);

        // ── Mine PRs (per unique org) ────────────────────────────────
        let mut all_mine: Vec<PullRequestRecord> = Vec::new();
        for org in &orgs {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            match api::fetch_my_open_pull_requests(
                &client,
                &auth_header,
                org,
                creator_id.as_deref(),
            ) {
                Ok(prs) => {
                    if !have_sent_connected {
                        have_sent_connected = true;
                        let _ = tx.send(AzDevOpsEvent::Connected);
                    }
                    all_mine.extend(prs);
                }
                Err(e) => {
                    let _ = tx.send(AzDevOpsEvent::Failed(format!("{org}: my prs: {e}")));
                }
            }
        }
        let _ = tx.send(AzDevOpsEvent::MyPullRequests(all_mine));

        // ── Per-project: builds + per-branch + repo PRs ──────────────
        for project in &cfg.projects {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            let label = project_label(project);
            match api::fetch_recent_builds(&client, &auth_header, project) {
                Ok(builds) => {
                    if !have_sent_connected {
                        have_sent_connected = true;
                        let _ = tx.send(AzDevOpsEvent::Connected);
                    }
                    let _ = tx.send(AzDevOpsEvent::Builds {
                        label: label.clone(),
                        builds,
                    });
                }
                Err(e) => {
                    let _ = tx.send(AzDevOpsEvent::Failed(format!("{label}: builds: {e}")));
                    sleep_cancellable_with_wake(PER_PROJECT_ERROR_BACKOFF, &cancel, &wake);
                }
            }
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            // Per-branch latest builds. Explicitly-configured branches
            // always get a row (so the user can SEE the branch is tracked
            // even when nothing's run yet). Default branches with no
            // builds get a row too — gives a visible diff between Recent
            // and PerBranch on thin repos.
            let branches = resolve_branches(project);
            let mut per_branch: Vec<BranchBuildSlot> = Vec::new();
            for branch in &branches {
                if cancel.load(Ordering::Relaxed) {
                    return;
                }
                match api::fetch_latest_build_for_branch(&client, &auth_header, project, branch) {
                    Ok(Some(b)) => per_branch.push((branch.clone(), Some(b))),
                    Ok(None) => per_branch.push((branch.clone(), None)),
                    Err(_) => {}
                }
            }
            let _ = tx.send(AzDevOpsEvent::BranchBuilds {
                label: label.clone(),
                per_branch,
            });
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            match api::fetch_open_pull_requests(&client, &auth_header, project) {
                Ok(prs) => {
                    let _ = tx.send(AzDevOpsEvent::PullRequests {
                        label,
                        pull_requests: prs,
                    });
                }
                Err(e) => {
                    let _ = tx.send(AzDevOpsEvent::Failed(format!("{label}: prs: {e}")));
                    sleep_cancellable_with_wake(PER_PROJECT_ERROR_BACKOFF, &cancel, &wake);
                }
            }
        }
        sleep_cancellable_with_wake(poll_interval, &cancel, &wake);
    }
}

fn resolve_branches(project: &AzDevOpsProject) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for b in &project.branches {
        if !out.iter().any(|x| x == b) {
            out.push(b.clone());
        }
    }
    for b in crate::config::default_branches() {
        if !out.iter().any(|x| x == b) {
            out.push((*b).to_string());
        }
    }
    out
}

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
