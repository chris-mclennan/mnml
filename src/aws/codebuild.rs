//! CodeBuild integration for the `aws-codebuild` feature — builds list.
//!
//! Shells out to the AWS CLI (no SDK; same pattern as the `git` track):
//!   1. `aws codebuild list-builds-for-project --project-name <p>`
//!      → most-recent build IDs (newest-first).
//!   2. `aws codebuild batch-get-builds --ids <id...>`
//!      → details (status, start/end time, source version, log links).
//!
//! Runs on a worker thread so the UI doesn't block on the CLI's
//! ~1-2-second latency. The pane consumes results over an `mpsc`
//! channel in `App::tick`.
//!
//! Phase 6b will add live log tail (`aws logs tail --follow` in a
//! `Pane::Pty`) and "fetch this build's Playwright report artifact"
//! piped into the existing `Pane::Tests`.

use std::process::Command;
use std::sync::mpsc::{Receiver, channel};
use std::thread;

use serde_json::Value;

/// How many recent builds to surface in the pane.
const RECENT_LIMIT: usize = 30;

/// Status string from CodeBuild, projected to a small enum for rendering.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildStatus {
    Succeeded,
    Failed,
    InProgress,
    Stopped,
    Fault,
    TimedOut,
    Unknown,
}

impl BuildStatus {
    fn parse(s: &str) -> Self {
        match s {
            "SUCCEEDED" => Self::Succeeded,
            "FAILED" => Self::Failed,
            "IN_PROGRESS" => Self::InProgress,
            "STOPPED" => Self::Stopped,
            "FAULT" => Self::Fault,
            "TIMED_OUT" => Self::TimedOut,
            _ => Self::Unknown,
        }
    }
    pub fn glyph(self) -> &'static str {
        match self {
            Self::Succeeded => "✓",
            Self::Failed => "✗",
            Self::InProgress => "⏵",
            Self::Stopped => "⊘",
            Self::Fault => "‼",
            Self::TimedOut => "⏱",
            Self::Unknown => "?",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::InProgress => "running",
            Self::Stopped => "stopped",
            Self::Fault => "fault",
            Self::TimedOut => "timeout",
            Self::Unknown => "unknown",
        }
    }
}

/// One row in the [`CodeBuildsPane`] — a CodeBuild build, projected to
/// the fields the IDE actually renders. Missing fields default to `None`
/// / `0` — older builds may not have every field populated.
#[derive(Debug, Clone)]
pub struct CodeBuildRecord {
    pub id: String,
    pub build_number: u64,
    pub status: BuildStatus,
    /// UNIX epoch ms — sortable, formatted at render.
    pub started_at_ms: Option<i64>,
    pub duration_ms: Option<u64>,
    /// `resolvedSourceVersion` (commit SHA) if available, else the raw
    /// `sourceVersion` (which can be a branch name or an S3 ARN when the
    /// build was pipeline-triggered).
    pub source_version: Option<String>,
    pub initiator: Option<String>,
    pub logs_deep_link: Option<String>,
    pub logs_group: Option<String>,
    pub logs_stream: Option<String>,
}

/// Events from the CodeBuild worker thread → main thread.
#[derive(Debug, Clone)]
pub enum CodeBuildEvent {
    Builds(Vec<CodeBuildRecord>),
    Failed(String),
}

/// Spawn a refresh in a worker thread. Returns the receiver; the caller
/// (the `CodeBuildsPane`) drains it via `App::tick`.
pub fn spawn_refresh(project: String, region: Option<String>) -> Receiver<CodeBuildEvent> {
    let (tx, rx) = channel();
    thread::spawn(move || {
        let result = fetch_recent_builds(&project, region.as_deref());
        let _ = match result {
            Ok(builds) => tx.send(CodeBuildEvent::Builds(builds)),
            Err(e) => tx.send(CodeBuildEvent::Failed(e)),
        };
    });
    rx
}

/// Synchronous version (used by the worker thread). Two CLI calls:
/// list-builds → batch-get-builds.
fn fetch_recent_builds(
    project: &str,
    region: Option<&str>,
) -> Result<Vec<CodeBuildRecord>, String> {
    // 1. List most-recent IDs.
    let ids_json = run_aws(
        &[
            "codebuild",
            "list-builds-for-project",
            "--project-name",
            project,
            "--max-items",
            &RECENT_LIMIT.to_string(),
        ],
        region,
    )?;
    let ids = ids_json
        .get("ids")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if ids.is_empty() {
        return Ok(Vec::new());
    }

    // 2. Batch-get details.
    let mut args = vec![
        "codebuild".to_string(),
        "batch-get-builds".to_string(),
        "--ids".to_string(),
    ];
    args.extend(ids);
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let details = run_aws(&arg_refs, region)?;
    let builds = details
        .get("builds")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "no 'builds' array in batch-get-builds response".to_string())?;

    let mut out: Vec<CodeBuildRecord> = builds.iter().filter_map(parse_build).collect();
    // CodeBuild returns batch-get-builds in the same order as the input IDs.
    // list-builds returns newest-first; preserve that.
    out.sort_by_key(|b| std::cmp::Reverse(b.started_at_ms.unwrap_or(0)));
    Ok(out)
}

fn run_aws(args: &[&str], region: Option<&str>) -> Result<Value, String> {
    let mut cmd = Command::new("aws");
    if let Some(r) = region {
        cmd.arg("--region").arg(r);
    }
    cmd.args(args).arg("--output").arg("json");
    let out = cmd
        .output()
        .map_err(|e| format!("spawn aws: {e} — is the AWS CLI on PATH?"))?;
    if !out.status.success() {
        return Err(format!(
            "aws {} → {}",
            args.first().copied().unwrap_or(""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("parse json: {e}"))
}

/// Map one CodeBuild JSON build → [`CodeBuildRecord`]. Returns `None` only
/// when the build has no `id` (shouldn't happen in practice).
fn parse_build(v: &Value) -> Option<CodeBuildRecord> {
    let id = v.get("id")?.as_str()?.to_string();
    let build_number = v.get("buildNumber").and_then(|b| b.as_u64()).unwrap_or(0);
    let status = v
        .get("buildStatus")
        .and_then(|s| s.as_str())
        .map(BuildStatus::parse)
        .unwrap_or(BuildStatus::Unknown);
    let started_at_ms = v
        .get("startTime")
        .and_then(|s| s.as_str())
        .and_then(parse_iso_ms);
    let end_ms = v
        .get("endTime")
        .and_then(|s| s.as_str())
        .and_then(parse_iso_ms);
    let duration_ms = match (started_at_ms, end_ms) {
        (Some(start), Some(end)) if end >= start => Some((end - start) as u64),
        _ => None,
    };
    let source_version = v
        .get("resolvedSourceVersion")
        .and_then(|s| s.as_str())
        .or_else(|| v.get("sourceVersion").and_then(|s| s.as_str()))
        .map(str::to_string);
    let initiator = v
        .get("initiator")
        .and_then(|s| s.as_str())
        .map(str::to_string);
    let logs = v.get("logs");
    let logs_deep_link = logs
        .and_then(|l| l.get("deepLink"))
        .and_then(|s| s.as_str())
        .map(str::to_string);
    let logs_group = logs
        .and_then(|l| l.get("groupName"))
        .and_then(|s| s.as_str())
        .map(str::to_string);
    let logs_stream = logs
        .and_then(|l| l.get("streamName"))
        .and_then(|s| s.as_str())
        .map(str::to_string);
    Some(CodeBuildRecord {
        id,
        build_number,
        status,
        started_at_ms,
        duration_ms,
        source_version,
        initiator,
        logs_deep_link,
        logs_group,
        logs_stream,
    })
}

/// Parse an ISO-8601 timestamp (the format CodeBuild returns) into epoch ms.
/// Hand-rolled because pulling in `chrono` for one parse felt heavy.
/// Accepts both `2026-05-15T14:37:02.559000-04:00` (with offset) and
/// `2026-05-15T14:37:02Z` (UTC) forms.
fn parse_iso_ms(s: &str) -> Option<i64> {
    // Split into date+time and timezone parts.
    let s = s.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    // YYYY-MM-DDTHH:MM:SS
    let year: i64 = s.get(0..4)?.parse().ok()?;
    let month: u32 = s.get(5..7)?.parse().ok()?;
    let day: u32 = s.get(8..10)?.parse().ok()?;
    let hour: u32 = s.get(11..13)?.parse().ok()?;
    let min: u32 = s.get(14..16)?.parse().ok()?;
    let sec: u32 = s.get(17..19)?.parse().ok()?;
    // Optional fractional seconds + timezone.
    let mut idx = 19;
    let mut frac_ms = 0u32;
    if bytes.get(idx).copied() == Some(b'.') {
        idx += 1;
        let frac_start = idx;
        while idx < bytes.len() && bytes[idx].is_ascii_digit() {
            idx += 1;
        }
        let frac_digits = &s[frac_start..idx];
        // Pad/truncate to 3 (ms).
        let truncated = &frac_digits[..frac_digits.len().min(3)];
        if let Ok(n) = truncated.parse::<u32>() {
            frac_ms = match truncated.len() {
                1 => n * 100,
                2 => n * 10,
                _ => n,
            };
        }
    }
    // Timezone: 'Z' or +/-HH:MM.
    let tz_offset_min: i64 = if bytes.get(idx).copied() == Some(b'Z') {
        0
    } else if let Some(c) = bytes.get(idx).copied()
        && (c == b'+' || c == b'-')
        && idx + 5 < bytes.len()
    {
        let sign: i64 = if c == b'+' { 1 } else { -1 };
        let h: i64 = s.get(idx + 1..idx + 3)?.parse().ok()?;
        let m: i64 = s.get(idx + 4..idx + 6)?.parse().ok()?;
        sign * (h * 60 + m)
    } else {
        0
    };

    let utc_ms = days_from_civil(year, month, day) * 86_400_000
        + (hour as i64) * 3_600_000
        + (min as i64) * 60_000
        + (sec as i64) * 1_000
        + (frac_ms as i64)
        - tz_offset_min * 60_000;
    Some(utc_ms)
}

/// Howard Hinnant's `days_from_civil` — returns days since 1970-01-01.
/// Closed-form, no leap-year tables. Returns `i64` days from epoch.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let d = d as i64;
    let doy = (153 * if m > 2 { m - 3 } else { m + 9 } + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_status_glyph_and_label() {
        assert_eq!(BuildStatus::parse("SUCCEEDED"), BuildStatus::Succeeded);
        assert_eq!(BuildStatus::parse("FAILED"), BuildStatus::Failed);
        assert_eq!(BuildStatus::parse("IN_PROGRESS"), BuildStatus::InProgress);
        assert_eq!(BuildStatus::parse("garbage"), BuildStatus::Unknown);
        assert_eq!(BuildStatus::Failed.glyph(), "✗");
        assert_eq!(BuildStatus::Succeeded.label(), "succeeded");
    }

    #[test]
    fn parse_iso_ms_round_trip() {
        // Known good: 2026-05-15T14:37:02.559000-04:00 → UTC 2026-05-15T18:37:02.559Z
        let got = parse_iso_ms("2026-05-15T14:37:02.559000-04:00").expect("parses");
        // Use `parse_iso_ms` on the UTC form too and confirm they match.
        let utc = parse_iso_ms("2026-05-15T18:37:02.559Z").expect("parses");
        assert_eq!(got, utc);
    }

    #[test]
    fn parse_iso_ms_handles_offset_signs() {
        let east = parse_iso_ms("2026-01-01T00:00:00+05:30").unwrap();
        let utc = parse_iso_ms("2025-12-31T18:30:00Z").unwrap();
        assert_eq!(east, utc);
    }

    #[test]
    fn parse_build_full_response() {
        let json = serde_json::json!({
            "id": "my-playwright:abc",
            "buildNumber": 38788,
            "buildStatus": "FAILED",
            "startTime": "2026-05-15T14:37:02.559000-04:00",
            "endTime":   "2026-05-15T14:37:31.431000-04:00",
            "resolvedSourceVersion": "629eda29d63c03c1fcfa01de38204e5b9d25559b",
            "sourceVersion": "arn:aws:s3:::pipeline-stuff",
            "initiator": "codepipeline/my-playwright",
            "logs": {
                "deepLink": "https://console.aws.amazon.com/cloudwatch/…",
                "groupName": "my-playwright",
                "streamName": "abc"
            }
        });
        let rec = parse_build(&json).expect("parses");
        assert_eq!(rec.id, "my-playwright:abc");
        assert_eq!(rec.build_number, 38788);
        assert_eq!(rec.status, BuildStatus::Failed);
        assert!(rec.started_at_ms.is_some());
        assert!(rec.duration_ms.is_some_and(|d| d > 0));
        // Prefer `resolvedSourceVersion` over the raw S3 ARN.
        assert!(
            rec.source_version
                .as_deref()
                .unwrap()
                .starts_with("629eda29")
        );
        assert_eq!(rec.initiator.as_deref(), Some("codepipeline/my-playwright"));
        assert_eq!(rec.logs_group.as_deref(), Some("my-playwright"));
    }

    #[test]
    fn parse_build_falls_back_to_source_version_when_no_resolved() {
        let json = serde_json::json!({
            "id": "p:x",
            "buildStatus": "SUCCEEDED",
            "sourceVersion": "develop"
        });
        let rec = parse_build(&json).expect("parses");
        assert_eq!(rec.source_version.as_deref(), Some("develop"));
    }
}
