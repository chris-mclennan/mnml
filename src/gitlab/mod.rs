//! GitLab CI / Merge Requests integration. Architecturally parallel to
//! [`crate::bitbucket`] and [`crate::github`] — separate module, separate
//! panes. Same `recent / per-branch` and `per-project / mine` view-modes.
//!
//! Worker fetches per-project pipelines + merge requests + per-branch
//! latest pipeline on each poll cycle. Mine is fetched via the global
//! `/merge_requests?scope=created_by_me` endpoint (no per-project loop).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::config::{GitlabConfig, GitlabProject};

pub mod api;
pub mod merge_requests_pane;
pub mod pipelines_pane;

pub use api::{MergeRequestRecord, MergeRequestState, PipelineRecord, PipelineState};
pub use merge_requests_pane::{GitlabMergeRequestsPane, GlMrViewMode};
pub use pipelines_pane::{GitlabPipelinesPane, GlPipelineViewMode};

/// One row in the PerBranch pipelines cache.
pub type BranchPipelineSlot = (String, Option<PipelineRecord>);

const PER_PROJECT_ERROR_BACKOFF: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
pub enum GitlabEvent {
    Pipelines {
        project: String,
        pipelines: Vec<PipelineRecord>,
    },
    BranchPipelines {
        project: String,
        per_branch: Vec<BranchPipelineSlot>,
    },
    MergeRequests {
        project: String,
        merge_requests: Vec<MergeRequestRecord>,
    },
    MyMergeRequests(Vec<MergeRequestRecord>),
    Connected,
    Failed(String),
}

pub struct GitlabHandle {
    pub rx: Receiver<GitlabEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl GitlabHandle {
    pub fn force_refresh(&self) {
        self.wake.store(true, Ordering::Relaxed);
    }
}

impl Drop for GitlabHandle {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
        if let Some(handle) = self.join.take() {
            let _ = handle.join();
        }
    }
}

pub fn spawn(cfg: GitlabConfig) -> GitlabHandle {
    let (tx, rx) = channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let wake = Arc::new(AtomicBool::new(false));
    let cancel_for_thread = cancel.clone();
    let wake_for_thread = wake.clone();
    let join = thread::spawn(move || run_thread(cfg, tx, cancel_for_thread, wake_for_thread));
    GitlabHandle {
        rx,
        cancel,
        wake,
        join: Some(join),
    }
}

fn run_thread(
    cfg: GitlabConfig,
    tx: Sender<GitlabEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
) {
    if !cfg.any_configured() {
        let _ = tx.send(GitlabEvent::Failed(
            "no [[gitlab.projects]] configured — add a project entry in \
             ~/.config/mnml/config.toml"
                .to_string(),
        ));
        return;
    }
    let auth_env = cfg.auth_env_name().to_string();
    let token = match std::env::var(&auth_env) {
        Ok(t) if !t.is_empty() => t,
        _ => {
            let _ = tx.send(GitlabEvent::Failed(format!(
                "${auth_env} not set — export your GitLab token before launching mnml"
            )));
            return;
        }
    };
    let client = match api::build_client() {
        Ok(c) => c,
        Err(e) => {
            let _ = tx.send(GitlabEvent::Failed(format!("reqwest client: {e}")));
            return;
        }
    };
    let auth_header = api::auth_header_value(&token);
    let base_url = cfg.base_url_or_default().to_string();
    let poll_interval = Duration::from_secs(cfg.poll_secs_or_default());

    let mut have_sent_connected = false;
    while !cancel.load(Ordering::Relaxed) {
        wake.store(false, Ordering::Relaxed);

        // ── Cross-project mine MRs ─────────────────────────────────────
        match api::fetch_my_open_merge_requests(&client, &base_url, &auth_header) {
            Ok(mrs) => {
                if !have_sent_connected {
                    have_sent_connected = true;
                    let _ = tx.send(GitlabEvent::Connected);
                }
                let _ = tx.send(GitlabEvent::MyMergeRequests(mrs));
            }
            Err(e) => {
                let _ = tx.send(GitlabEvent::Failed(format!("my mrs: {e}")));
            }
        }

        // ── Per-project: pipelines + per-branch + open MRs ────────────
        for project in &cfg.projects {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            match api::fetch_recent_pipelines(&client, &base_url, &auth_header, project) {
                Ok(pipelines) => {
                    if !have_sent_connected {
                        have_sent_connected = true;
                        let _ = tx.send(GitlabEvent::Connected);
                    }
                    let _ = tx.send(GitlabEvent::Pipelines {
                        project: project.project.clone(),
                        pipelines,
                    });
                }
                Err(e) => {
                    let _ = tx.send(GitlabEvent::Failed(format!(
                        "{p}: pipelines: {e}",
                        p = project.project
                    )));
                    sleep_cancellable_with_wake(PER_PROJECT_ERROR_BACKOFF, &cancel, &wake);
                }
            }
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            let branches = resolve_branches(project);
            let mut per_branch: Vec<BranchPipelineSlot> = Vec::new();
            for branch in &branches {
                if cancel.load(Ordering::Relaxed) {
                    return;
                }
                match api::fetch_latest_pipeline_for_branch(
                    &client,
                    &base_url,
                    &auth_header,
                    project,
                    branch,
                ) {
                    Ok(Some(pipeline)) => {
                        per_branch.push((branch.clone(), Some(pipeline)));
                    }
                    Ok(None) => {
                        if project.branches.iter().any(|b| b == branch) {
                            per_branch.push((branch.clone(), None));
                        }
                    }
                    Err(_) => {}
                }
            }
            let _ = tx.send(GitlabEvent::BranchPipelines {
                project: project.project.clone(),
                per_branch,
            });
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            match api::fetch_open_merge_requests(&client, &base_url, &auth_header, project) {
                Ok(merge_requests) => {
                    let _ = tx.send(GitlabEvent::MergeRequests {
                        project: project.project.clone(),
                        merge_requests,
                    });
                }
                Err(e) => {
                    let _ = tx.send(GitlabEvent::Failed(format!(
                        "{p}: mrs: {e}",
                        p = project.project
                    )));
                    sleep_cancellable_with_wake(PER_PROJECT_ERROR_BACKOFF, &cancel, &wake);
                }
            }
        }
        sleep_cancellable_with_wake(poll_interval, &cancel, &wake);
    }
}

fn resolve_branches(project: &GitlabProject) -> Vec<String> {
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
