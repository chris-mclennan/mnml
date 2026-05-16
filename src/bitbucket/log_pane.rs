//! `Pane::PipelineLog` — a scrollable read-only view of a Bitbucket
//! pipeline's combined per-step build log. Spawned by `L` on a BB
//! pipeline row; populated by a background worker that fetches
//! every step's `/log` endpoint and concatenates them with header
//! separators.
//!
//! The fetch is a one-shot (not a tail) — for finished pipelines that's
//! exactly the inspection-the-failure use case. In-progress pipelines
//! show the partial log captured at fetch time; `r` re-fetches.

use std::sync::Arc;
use std::sync::atomic::AtomicBool;

/// Which host's API the pane should query on refetch. The pane carries
/// identifying strings (workspace/slug/uuid in the BB case, owner/repo/
/// run-id for GH, …); this enum tells the refetch path which API to call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogHost {
    Bitbucket,
    Github,
}

#[derive(Debug)]
pub struct PipelineLogPane {
    /// e.g. `exampleorg/example-api · build #4521`
    pub title: String,
    /// Which host this pane is wired to.
    pub host: LogHost,
    /// Host-specific id strings. For BB: `workspace` / `slug` / `pipeline_uuid`.
    /// For GH: `owner` / `repo` / `run_id-as-string`.
    pub workspace: String,
    pub slug: String,
    pub pipeline_uuid: String,
    /// State of the fetch.
    pub state: PipelineLogState,
    /// Top rendered row.
    pub scroll: usize,
    /// Re-fire counter — the worker tags each reply so a stale reply
    /// (from a previous `r`) doesn't clobber the current job.
    pub job_id: u64,
    /// Set true to ask the worker to bail. Replaced on each re-fetch.
    pub cancel: Arc<AtomicBool>,
    /// The pipeline's Bitbucket dashboard URL — opened by `y` (copy)
    /// and `Enter` (open in browser).
    pub web_url: String,
}

#[derive(Debug)]
pub enum PipelineLogState {
    Fetching,
    Done(String),
    Failed(String),
}

impl PipelineLogPane {
    pub fn new(
        title: impl Into<String>,
        workspace: String,
        slug: String,
        pipeline_uuid: String,
        web_url: String,
        job_id: u64,
        cancel: Arc<AtomicBool>,
    ) -> Self {
        Self::new_with_host(
            title,
            LogHost::Bitbucket,
            workspace,
            slug,
            pipeline_uuid,
            web_url,
            job_id,
            cancel,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_with_host(
        title: impl Into<String>,
        host: LogHost,
        workspace: String,
        slug: String,
        pipeline_uuid: String,
        web_url: String,
        job_id: u64,
        cancel: Arc<AtomicBool>,
    ) -> Self {
        PipelineLogPane {
            title: title.into(),
            host,
            workspace,
            slug,
            pipeline_uuid,
            state: PipelineLogState::Fetching,
            scroll: 0,
            job_id,
            cancel,
            web_url,
        }
    }
}

/// Message sent from the worker thread back to the App.
#[derive(Debug)]
pub enum PipelineLogEvent {
    Done { job_id: u64, log: String },
    Failed { job_id: u64, err: String },
}
