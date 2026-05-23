//! AWS-CLI-backed panes for mnml — the `aws-codebuild` Cargo feature.
//!
//! Generic AWS integrations that shell out to the `aws` CLI (no SDK). The
//! `Pane::CodeBuilds` browser lists recent CodeBuild runs for a configured
//! project; `Pane::LogTail` streams CloudWatch logs with per-line severity
//! colouring. Project names and log group names come from config, not
//! anything hardcoded — works for any AWS account / project the user has
//! `aws` credentials for.
//!
//! Off by default. `cargo build --features aws-codebuild` opts in. Pulls in
//! **no new dependencies** — both modules use `std::process::Command` to
//! shell to the `aws` CLI and parse its JSON output with `serde_json` (which
//! is already a default dep).

pub mod codebuild;
pub mod codebuilds_pane;
pub mod log_tail_pane;
