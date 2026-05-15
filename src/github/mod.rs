//! GitHub Actions / Pull Requests integration. Architecturally parallel to
//! [`crate::bitbucket`] — one worker thread polls every configured
//! `[[github.repos]]` entry for recent workflow runs, drops projected
//! records on an `mpsc` channel that [`crate::app::App::tick`] drains into
//! a per-repo cache.
//!
//! Kept as a sibling module (not folded into a unified "CI" abstraction)
//! so each host's REST quirks can stay flat and readable. The Record
//! shape is intentionally similar to Bitbucket's though — a future fourth
//! host would be a reasonable time to unify.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::config::{GithubConfig, GithubRepo};

pub mod actions_pane;
pub mod api;

pub use actions_pane::GithubActionsPane;
pub use api::{WorkflowRunRecord, WorkflowRunState};

/// Backoff after a per-repo fetch failure before moving to the next repo
/// in the same pass. Keeps a flaky repo from accelerating the rest.
const PER_REPO_ERROR_BACKOFF: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
pub enum GithubEvent {
    /// Latest workflow runs for one repo, newest-first.
    WorkflowRuns {
        owner: String,
        repo: String,
        runs: Vec<WorkflowRunRecord>,
    },
    /// At least one successful poll has landed — the pane drops "loading…".
    Connected,
    /// User-facing error summary (auth / 404 / parse / …). Worker keeps polling.
    Failed(String),
}

pub struct GithubHandle {
    pub rx: Receiver<GithubEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl GithubHandle {
    /// Wake the worker out of its sleep so the next poll fires now.
    /// Pane's `r` key handler calls this.
    pub fn force_refresh(&self) {
        self.wake.store(true, Ordering::Relaxed);
    }
}

impl Drop for GithubHandle {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
        if let Some(handle) = self.join.take() {
            let _ = handle.join();
        }
    }
}

pub fn spawn(cfg: GithubConfig) -> GithubHandle {
    let (tx, rx) = channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let wake = Arc::new(AtomicBool::new(false));
    let cancel_for_thread = cancel.clone();
    let wake_for_thread = wake.clone();
    let join = thread::spawn(move || run_thread(cfg, tx, cancel_for_thread, wake_for_thread));
    GithubHandle {
        rx,
        cancel,
        wake,
        join: Some(join),
    }
}

fn run_thread(
    cfg: GithubConfig,
    tx: Sender<GithubEvent>,
    cancel: Arc<AtomicBool>,
    wake: Arc<AtomicBool>,
) {
    if !cfg.any_configured() {
        let _ = tx.send(GithubEvent::Failed(
            "no [[github.repos]] configured — add an owner/repo pair in \
             ~/.config/mnml/config.toml"
                .to_string(),
        ));
        return;
    }
    let auth_env = cfg.auth_env_name().to_string();
    let token = match std::env::var(&auth_env) {
        Ok(t) if !t.is_empty() => t,
        _ => {
            let _ = tx.send(GithubEvent::Failed(format!(
                "${auth_env} not set — export your GitHub PAT (ghp_… / github_pat_… / \
                 ghs_… / gho_… all work) before launching mnml"
            )));
            return;
        }
    };
    let client = match api::build_client() {
        Ok(c) => c,
        Err(e) => {
            let _ = tx.send(GithubEvent::Failed(format!("reqwest client: {e}")));
            return;
        }
    };
    let auth_header = api::auth_header_value(&token);
    let poll_interval = Duration::from_secs(cfg.poll_secs_or_default());

    let mut have_sent_connected = false;
    while !cancel.load(Ordering::Relaxed) {
        wake.store(false, Ordering::Relaxed);
        for repo in &cfg.repos {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            match api::fetch_recent_workflow_runs(&client, &auth_header, repo) {
                Ok(runs) => {
                    if !have_sent_connected {
                        have_sent_connected = true;
                        let _ = tx.send(GithubEvent::Connected);
                    }
                    let _ = tx.send(GithubEvent::WorkflowRuns {
                        owner: repo.owner.clone(),
                        repo: repo.repo.clone(),
                        runs,
                    });
                }
                Err(e) => {
                    let _ = tx.send(GithubEvent::Failed(format!(
                        "{owner}/{repo}: {e}",
                        owner = repo.owner,
                        repo = repo.repo,
                    )));
                    sleep_cancellable_with_wake(PER_REPO_ERROR_BACKOFF, &cancel, &wake);
                }
            }
        }
        sleep_cancellable_with_wake(poll_interval, &cancel, &wake);
    }
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

#[allow(dead_code)] // Same shape as the Bitbucket sibling — kept for parity.
pub type Repo = GithubRepo;
