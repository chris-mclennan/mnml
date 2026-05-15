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

pub use api::{PipelineRecord, PipelineState};

/// Backoff after a per-repo fetch failure before we visit the next repo
/// in the same pass. Keeps a flaky repo from spinning at full speed.
const PER_REPO_ERROR_BACKOFF: Duration = Duration::from_secs(5);

/// Events from the Bitbucket worker thread → main thread.
#[derive(Debug, Clone)]
pub enum BitbucketEvent {
    /// Latest pipelines for a single repo. Replaces (does not merge with)
    /// the receiver's cached vec for that repo — Bitbucket gives us the
    /// canonical newest-N each poll so wholesale-replace is simplest.
    Pipelines {
        workspace: String,
        slug: String,
        pipelines: Vec<PipelineRecord>,
    },
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
    join: Option<JoinHandle<()>>,
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
    let cancel_for_thread = cancel.clone();
    let join = thread::spawn(move || run_thread(cfg, tx, cancel_for_thread));
    BitbucketHandle {
        rx,
        cancel,
        join: Some(join),
    }
}

fn run_thread(cfg: BitbucketConfig, tx: Sender<BitbucketEvent>, cancel: Arc<AtomicBool>) {
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

    let mut have_sent_connected = false;
    while !cancel.load(Ordering::Relaxed) {
        for repo in &cfg.repos {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
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
                        "{ws}/{slug}: {e}",
                        ws = repo.workspace,
                        slug = repo.slug,
                    )));
                    // Brief inter-repo backoff so a single broken repo
                    // doesn't make us hammer the API for the rest of the
                    // list at no-delay.
                    sleep_cancellable(PER_REPO_ERROR_BACKOFF, &cancel);
                }
            }
        }
        sleep_cancellable(poll_interval, &cancel);
    }
}

/// Sleep `dur`, waking early if `cancel` flips. Keeps shutdown responsive
/// — the worker can exit within `CHECK_INTERVAL` of the App dropping the
/// handle, regardless of poll interval.
fn sleep_cancellable(dur: Duration, cancel: &Arc<AtomicBool>) {
    const CHECK_INTERVAL: Duration = Duration::from_millis(250);
    let mut remaining = dur;
    while remaining > Duration::ZERO {
        if cancel.load(Ordering::Relaxed) {
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
