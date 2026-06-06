//! Pipeline-log pane infrastructure shared across the CI/CD-host
//! integrations (Bitbucket / GitHub / GitLab / Azure DevOps). The
//! pane is a scrollable read-only view of a build's combined per-step
//! log, populated by a per-host background worker.
//!
//! Originally lived under `src/bitbucket/` because bitbucket's
//! pipelines were the first integration; moved here when bitbucket's
//! own panes were split out into the standalone
//! `mnml-forge-bitbucket` viewer. The remaining hosts
//! (github / gitlab / azdevops) all import [`PipelineLogPane`] from
//! this module.

pub mod pane;

pub use pane::{LogHost, PipelineLogEvent, PipelineLogPane, PipelineLogState};
