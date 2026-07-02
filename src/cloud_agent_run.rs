//! Cloud-agent-run detail pane — `Pane::CloudAgentRun`.
//!
//! Renders one pane that aggregates every available source of info
//! for a single QWE runner cloud run:
//!   - Summary (ticket, flow, state, timestamps)
//!   - Web links (Jira, PR, CloudWatch console, S3 console)
//!   - Artifacts list (S3 objects under `s3_artifact_prefix`)
//!   - Logs (historical via `aws logs filter-log-events`, or
//!     tail via `aws logs tail --follow` when the run is still
//!     in flight)
//!
//! All async work is offloaded to worker threads; the UI thread
//! drains channels each tick. Browser links open via the system
//! `open` command (or `xdg-open` on Linux).

use std::sync::mpsc::Receiver;
use std::time::SystemTime;

/// One entry in the artifacts list — represents an S3 object the
/// run uploaded. We keep both the full key (for opening) and a
/// display-friendly trailing component (for the row label).
#[derive(Debug, Clone)]
pub struct ArtifactRow {
    pub key: String,
    pub display: String,
    pub size_bytes: Option<u64>,
}

/// One log line — usually `<timestamp> <message>` from
/// `aws logs filter-log-events`. We render them verbatim; the
/// CloudWatch console URL is the escape hatch for richer
/// filtering / highlighting.
#[derive(Debug, Clone)]
pub struct LogLine {
    pub text: String,
}

/// Events from the log-fetcher worker.
pub enum LogEvent {
    /// Batch of lines from the historical fetch or the tail.
    Lines(Vec<LogLine>),
    /// The fetch finished (all of history loaded, or the tail
    /// stream closed).
    Done,
    /// Worker hit an error — surfaced in the pane as a banner.
    Error(String),
}

/// Events from the artifacts-fetcher worker.
pub enum ArtifactsEvent {
    Rows(Vec<ArtifactRow>),
    Done,
    Error(String),
}

/// Which cloud-agent backend produced this row. The renderer
/// branches on this so the labels match the source — managed
/// agents don't have Jira/CloudWatch/S3, they have an Anthropic
/// Console session URL + an agent ID + an environment ID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CloudRunSource {
    #[default]
    Ecs,
    AnthropicManaged,
}

#[derive(Debug)]
pub struct CloudAgentRunPane {
    pub source: CloudRunSource,
    // ─── identity ────────────────────────────────────────────────
    pub run_id: String,
    pub ticket: String,
    pub flow: String,
    pub state: String,
    pub workspace_name: String,

    // ─── timing ──────────────────────────────────────────────────
    pub started_at: Option<SystemTime>,
    pub last_activity: Option<SystemTime>,

    // ─── linked surfaces (none = "no URL available") ─────────────
    pub jira_url: Option<String>,
    pub pr_url: Option<String>,
    pub cloudwatch_url: String,
    pub s3_artifact_prefix: Option<String>,
    pub s3_console_url: Option<String>,

    // ─── async content (loaded after pane opens) ────────────────
    pub logs: Vec<LogLine>,
    pub logs_loading: bool,
    pub logs_err: Option<String>,
    pub log_rx: Option<Receiver<LogEvent>>,

    pub artifacts: Vec<ArtifactRow>,
    pub artifacts_loading: bool,
    pub artifacts_err: Option<String>,
    pub artifacts_rx: Option<Receiver<ArtifactsEvent>>,

    /// Managed-agents only — SSE stream of session events from
    /// `/v1/sessions/{id}/stream`. ECS path leaves this None
    /// and uses the CloudWatch `log_rx` channel instead.
    pub session_event_rx: Option<Receiver<crate::anthropic_api::SessionStreamEvent>>,

    // ─── UI state ────────────────────────────────────────────────
    /// Top-row scroll offset for the logs viewport. Keystroke
    /// scrolling sets this; `auto_follow` keeps the bottom
    /// pinned for in-flight runs.
    pub log_scroll: usize,
    /// When true, every new log batch resets `log_scroll` so we
    /// stay pinned to the tail. Set to true on open, toggled to
    /// false when the user scrolls up.
    pub log_follow: bool,

    /// Auto-refresh cadence in seconds. `0` = disabled (manual
    /// refresh only). Cycled by clicking the `[auto: …]` chip on
    /// the detail pane header: off → 10s → 30s → 60s → 5m → off.
    /// Default for running runs is 30s; Done runs default to 0
    /// since their state doesn't change.
    pub auto_refresh_secs: u64,
    /// When auto_refresh_secs > 0, track the last fired refresh
    /// so tick() can decide when the next is due. None until the
    /// first refresh runs.
    pub last_auto_refresh: Option<std::time::Instant>,
}

impl CloudAgentRunPane {
    /// Build the pane shell. Workers are spawned by
    /// `App::open_cloud_agent_run` so this constructor stays
    /// side-effect-free for tests.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        run_id: String,
        ticket: String,
        flow: String,
        state: String,
        workspace_name: String,
        last_activity: Option<SystemTime>,
        jira_url: Option<String>,
        pr_url: Option<String>,
        cloudwatch_url: String,
        s3_artifact_prefix: Option<String>,
        s3_console_url: Option<String>,
    ) -> Self {
        // Default 30s polling when the run is live; off when it's
        // done since artifacts/logs don't change after.
        let auto_refresh_secs =
            if state.eq_ignore_ascii_case("running") || state.eq_ignore_ascii_case("queued") {
                30
            } else {
                0
            };
        Self {
            source: CloudRunSource::Ecs,
            run_id,
            ticket,
            flow,
            state,
            workspace_name,
            started_at: None,
            last_activity,
            jira_url,
            pr_url,
            cloudwatch_url,
            s3_artifact_prefix,
            s3_console_url,
            logs: Vec::new(),
            logs_loading: true,
            logs_err: None,
            log_rx: None,
            artifacts: Vec::new(),
            artifacts_loading: true,
            artifacts_err: None,
            artifacts_rx: None,
            session_event_rx: None,
            log_scroll: 0,
            log_follow: true,
            auto_refresh_secs,
            last_auto_refresh: None,
        }
    }

    /// Build the pane for an Anthropic Managed Agents session.
    /// Skips the AWS-specific fields (CloudWatch / S3); links
    /// degenerate to the Anthropic Console session URL.
    pub fn new_managed(
        session_id: String,
        title: String,
        status: String,
        agent_id: Option<String>,
        environment_id: Option<String>,
    ) -> Self {
        // Console sessions are workspace-scoped. When on Claude
        // Platform on AWS, the workspace ID is in env; on first-
        // party API there's just "default". Anthropic-side URL
        // format: /workspaces/<id>/sessions/<id>.
        let workspace = std::env::var("ANTHROPIC_AWS_WORKSPACE_ID")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "default".to_string());
        let console_url =
            format!("https://platform.claude.com/workspaces/{workspace}/sessions/{session_id}");
        Self {
            source: CloudRunSource::AnthropicManaged,
            run_id: session_id,
            // Repurpose the ECS field names so the existing
            // renderer's labels still make sense after we tweak
            // them: ticket → agent id, flow → environment id.
            ticket: agent_id.unwrap_or_else(|| "—".to_string()),
            flow: environment_id.unwrap_or_else(|| "—".to_string()),
            state: status,
            workspace_name: if title.is_empty() {
                "managed".to_string()
            } else {
                title
            },
            started_at: None,
            last_activity: None,
            jira_url: None,
            // Anthropic Console session URL goes here so the
            // existing "PR" row in the renderer becomes the
            // console link. Renamed by source in the view.
            pr_url: Some(console_url),
            cloudwatch_url: String::new(),
            s3_artifact_prefix: None,
            s3_console_url: None,
            logs: Vec::new(),
            logs_loading: true,
            logs_err: None,
            log_rx: None,
            artifacts: Vec::new(),
            artifacts_loading: false,
            artifacts_err: None,
            artifacts_rx: None,
            // Stream from /v1/sessions/{id}/stream — set by
            // App::open_cloud_agent_run after construction.
            session_event_rx: None,
            log_scroll: 0,
            log_follow: true,
            // Managed agents stream live via SSE, so the polling
            // shim doesn't apply. Auto-refresh stays off; the
            // user can still manual-refresh to restart the SSE.
            auto_refresh_secs: 0,
            last_auto_refresh: None,
        }
    }

    /// Drain whichever worker channels are open. Called from
    /// `App::tick`. Returns true when something changed (so the UI
    /// requests a redraw — currently all ticks redraw anyway, but
    /// the return value is documentation).
    /// True when the log stream contained any "put-dir failed",
    /// "artifact publish warnings", or "upload failed" lines.
    /// Used by the renderer to swap the "(none)" placeholder for
    /// a clearer hint pointing at the IAM cause. Scans the
    /// in-memory log buffer — cheap (logs are <1k lines typically).
    pub fn artifacts_upload_failed(&self) -> bool {
        self.logs.iter().any(|l| {
            let s = &l.text;
            s.contains("put-dir failed")
                || s.contains("artifact publish warnings")
                || (s.contains("upload failed") && s.contains("AccessDenied"))
        })
    }

    pub fn drain(&mut self) -> bool {
        let mut changed = false;
        if let Some(rx) = self.log_rx.take() {
            let mut still_open = true;
            while let Ok(ev) = rx.try_recv() {
                changed = true;
                match ev {
                    LogEvent::Lines(mut batch) => {
                        self.logs.append(&mut batch);
                        if self.log_follow {
                            self.log_scroll = usize::MAX;
                        }
                    }
                    LogEvent::Done => {
                        self.logs_loading = false;
                        still_open = false;
                    }
                    LogEvent::Error(e) => {
                        self.logs_err = Some(e);
                        self.logs_loading = false;
                        still_open = false;
                    }
                }
            }
            if still_open {
                self.log_rx = Some(rx);
            }
        }
        if let Some(rx) = self.session_event_rx.take() {
            use crate::anthropic_api::SessionStreamEvent;
            let mut still_open = true;
            while let Ok(ev) = rx.try_recv() {
                changed = true;
                match ev {
                    SessionStreamEvent::Line(text) => {
                        self.logs.push(LogLine { text });
                        if self.log_follow {
                            self.log_scroll = usize::MAX;
                        }
                    }
                    SessionStreamEvent::Done => {
                        self.logs_loading = false;
                        still_open = false;
                    }
                    SessionStreamEvent::Error(e) => {
                        self.logs_err = Some(e);
                        self.logs_loading = false;
                        still_open = false;
                    }
                }
            }
            if still_open {
                self.session_event_rx = Some(rx);
            }
        }
        if let Some(rx) = self.artifacts_rx.take() {
            let mut still_open = true;
            while let Ok(ev) = rx.try_recv() {
                changed = true;
                match ev {
                    ArtifactsEvent::Rows(mut rows) => self.artifacts.append(&mut rows),
                    ArtifactsEvent::Done => {
                        self.artifacts_loading = false;
                        still_open = false;
                    }
                    ArtifactsEvent::Error(e) => {
                        self.artifacts_err = Some(e);
                        self.artifacts_loading = false;
                        still_open = false;
                    }
                }
            }
            if still_open {
                self.artifacts_rx = Some(rx);
            }
        }
        changed
    }
}

/// Spawn a worker that runs `aws logs` against the run's log group
/// and streams lines back via the channel. `state` controls which
/// command we use: completed runs get `filter-log-events` for full
/// history, running runs get `tail --follow` for live updates.
pub fn spawn_log_fetcher(run_id: String, state: String, log_group: String) -> Receiver<LogEvent> {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};
    use std::sync::mpsc::Sender;
    use std::sync::mpsc::channel;

    let (tx, rx): (Sender<LogEvent>, Receiver<LogEvent>) = channel();
    std::thread::spawn(move || {
        let running = state.eq_ignore_ascii_case("running") || state.eq_ignore_ascii_case("queued");
        let mut cmd = Command::new("aws");
        // CloudWatch Filter Pattern tokenizes on `-`, so an
        // unquoted `TE-1234-prod-mnml-…` matches lines containing
        // any of those tokens (TE, 1234, prod, mnml). Wrap with
        // double-quotes — that's CloudWatch's literal-substring
        // syntax (per AWS Filter and Pattern Syntax docs). Result:
        // only lines that contain the exact run-id substring.
        let pattern = format!("\"{run_id}\"");
        if running {
            // Tail mode — live updates from now on, plus the last
            // hour of context so the user doesn't stare at an empty
            // viewport while waiting.
            cmd.args([
                "logs",
                "tail",
                &log_group,
                "--since",
                "1h",
                "--follow",
                "--filter-pattern",
                &pattern,
                "--format",
                "short",
            ]);
        } else {
            // Historical mode — pull the full log for this run.
            // 24h window is the QWE retention sweet spot.
            cmd.args([
                "logs",
                "tail",
                &log_group,
                "--since",
                "24h",
                "--filter-pattern",
                &pattern,
                "--format",
                "short",
            ]);
        }
        let child = cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(e) => {
                let _ = tx.send(LogEvent::Error(format!("spawn aws logs: {e}")));
                return;
            }
        };
        let stdout = match child.stdout.take() {
            Some(s) => s,
            None => {
                let _ = tx.send(LogEvent::Error("aws logs: no stdout".to_string()));
                return;
            }
        };
        let reader = BufReader::new(stdout);
        let mut batch: Vec<LogLine> = Vec::with_capacity(32);
        for line in reader.lines().map_while(Result::ok) {
            batch.push(LogLine { text: line });
            if batch.len() >= 32
                && tx
                    .send(LogEvent::Lines(std::mem::take(&mut batch)))
                    .is_err()
            {
                return;
            }
        }
        if !batch.is_empty() {
            let _ = tx.send(LogEvent::Lines(batch));
        }
        let _ = child.wait();
        let _ = tx.send(LogEvent::Done);
    });
    rx
}

/// Spawn a worker that runs `aws s3 ls <prefix> --recursive` and
/// streams parsed rows back. Empty prefix → empty stream + Done.
pub fn spawn_artifacts_fetcher(s3_prefix: Option<String>) -> Receiver<ArtifactsEvent> {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};
    use std::sync::mpsc::Sender;
    use std::sync::mpsc::channel;

    let (tx, rx): (Sender<ArtifactsEvent>, Receiver<ArtifactsEvent>) = channel();
    std::thread::spawn(move || {
        let Some(prefix) = s3_prefix else {
            let _ = tx.send(ArtifactsEvent::Done);
            return;
        };
        if prefix.trim().is_empty() {
            let _ = tx.send(ArtifactsEvent::Done);
            return;
        }
        let child = Command::new("aws")
            .args(["s3", "ls", &prefix, "--recursive"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(e) => {
                let _ = tx.send(ArtifactsEvent::Error(format!("spawn aws s3 ls: {e}")));
                return;
            }
        };
        let stdout = match child.stdout.take() {
            Some(s) => s,
            None => {
                let _ = tx.send(ArtifactsEvent::Error("aws s3: no stdout".to_string()));
                return;
            }
        };
        let reader = BufReader::new(stdout);
        let mut batch: Vec<ArtifactRow> = Vec::new();
        // `aws s3 ls --recursive` rows look like:
        // 2026-06-27 10:42:31  123456 some/key/path.png
        // Parse into ArtifactRow. Anything that doesn't match we
        // pass through as a display-only row (size None).
        for line in reader.lines().map_while(Result::ok) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            let row = if parts.len() >= 4 {
                let size: Option<u64> = parts[2].parse().ok();
                let key = parts[3..].join(" ");
                let display = key.rsplit('/').next().unwrap_or(&key).to_string();
                ArtifactRow {
                    key,
                    display,
                    size_bytes: size,
                }
            } else {
                ArtifactRow {
                    key: line.clone(),
                    display: line.clone(),
                    size_bytes: None,
                }
            };
            batch.push(row);
            if batch.len() >= 16
                && tx
                    .send(ArtifactsEvent::Rows(std::mem::take(&mut batch)))
                    .is_err()
            {
                return;
            }
        }
        if !batch.is_empty() {
            let _ = tx.send(ArtifactsEvent::Rows(batch));
        }
        let _ = child.wait();
        let _ = tx.send(ArtifactsEvent::Done);
    });
    rx
}

/// Build a Jira ticket URL. `domain` is the org's Jira instance
/// (e.g. `"acme.atlassian.net"`); `None` or empty domain → `None`
/// (feature off — no chip renders). Callers should pass
/// `config.jira.effective_domain()` so `MNML_JIRA_DOMAIN` wins
/// over the file.
pub fn jira_url_for(ticket: &str, domain: Option<&str>) -> Option<String> {
    let t = ticket.trim();
    if t.is_empty() || !t.contains('-') {
        return None;
    }
    let d = domain?;
    if d.is_empty() {
        return None;
    }
    Some(format!("https://{d}/browse/{t}"))
}

/// Build an S3 console URL from a `s3://bucket/prefix` path.
pub fn s3_console_url_for(s3_path: &str) -> Option<String> {
    let s = s3_path.strip_prefix("s3://").unwrap_or(s3_path);
    let mut parts = s.splitn(2, '/');
    let bucket = parts.next()?;
    let prefix = parts.next().unwrap_or("");
    Some(format!(
        "https://s3.console.aws.amazon.com/s3/buckets/{bucket}?prefix={prefix}"
    ))
}

#[cfg(test)]
mod jira_url_tests {
    use super::*;

    #[test]
    fn builds_url_when_domain_set() {
        assert_eq!(
            jira_url_for("TE-1234", Some("acme.atlassian.net")),
            Some("https://acme.atlassian.net/browse/TE-1234".to_string()),
        );
    }

    #[test]
    fn none_without_domain() {
        assert_eq!(jira_url_for("TE-1234", None), None);
        assert_eq!(jira_url_for("TE-1234", Some("")), None);
    }

    #[test]
    fn none_for_malformed_ticket() {
        assert_eq!(jira_url_for("", Some("acme.atlassian.net")), None);
        assert_eq!(jira_url_for("nodashhere", Some("acme.atlassian.net")), None);
    }
}
