//! Tattle QWE-runner integration — surface cloud-run rows from
//! the `qwe-runner-runs` DynamoDB table alongside local Claude /
//! Codex sessions in the Agents dashboard.
//!
//! Auth strategy: shell out to the `aws` CLI rather than embed
//! the rust SDK (which would add ~50 transitive deps). The CLI
//! picks up the user's SSO session via `AWS_PROFILE` (typically
//! `tattle-dev`); no creds touched in-process.
//!
//! Data model (from `qwe-runner/packages/shared/src/types/run-record.ts`):
//!   runId · ticket · flow · source · state · createdAt ·
//!   finishedAt · approvalIntent · s3ArtifactPrefix · slackTs ·
//!   prUrl · lastRunStatus · lastError
//!
//! State lifecycle:  started → staged → approved → shipped
//!                                                  ↘ dismissed / failed

use crate::claude_agents::{AgentRow, AgentSource, AgentState};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// AWS region the qwe-runner stack lives in.
const REGION: &str = "us-east-1";
/// DynamoDB table name (see qwe-runner's CDK stack).
const TABLE: &str = "qwe-runner-runs";
/// Only surface runs in the last N hours — keeps the rail tidy
/// when historical rows accumulate.
const RECENT_HOURS: u64 = 24;

/// Scan the `qwe-runner-runs` table for recent rows and convert
/// each to an `AgentRow`. Returns an empty vec when:
///   - `aws` CLI is not on PATH,
///   - the user isn't SSO'd in (`aws` returns 255),
///   - the table is empty / the user can't read it,
///   - any parse error occurs.
///
/// Logs nothing to stderr — silent failure is fine here; the rail
/// just doesn't show cloud rows.
pub fn collect_cloud_rows() -> Vec<AgentRow> {
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(RECENT_HOURS * 3600))
        .unwrap_or(UNIX_EPOCH);
    let cutoff_iso = system_time_to_iso(cutoff);

    // `aws dynamodb scan` against the GSI is cheaper, but a simple
    // `scan + filter-expression` on createdAt is reliable and
    // matches the auth surface we already have. ~few-KB response
    // per call; runs once per refresh tick.
    let out = Command::new("aws")
        .args([
            "dynamodb",
            "scan",
            "--table-name",
            TABLE,
            "--region",
            REGION,
            "--filter-expression",
            "createdAt > :since",
            "--expression-attribute-values",
            &format!("{{\":since\":{{\"S\":\"{cutoff_iso}\"}}}}"),
            "--output",
            "json",
        ])
        .output();
    let bytes = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return Vec::new(),
    };
    let json: serde_json::Value = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let items = match json.get("Items").and_then(|v| v.as_array()) {
        Some(a) => a,
        None => return Vec::new(),
    };
    items.iter().filter_map(parse_run_record).collect()
}

/// Parse one DynamoDB Item (in low-level type-wrapped form, i.e.
/// `{"runId":{"S":"abc"},...}`) into an `AgentRow`.
fn parse_run_record(item: &serde_json::Value) -> Option<AgentRow> {
    let s = |k: &str| -> Option<String> {
        item.get(k)
            .and_then(|v| v.get("S"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    };
    let run_id = s("runId")?;
    let ticket = s("ticket").unwrap_or_default();
    let flow = s("flow").unwrap_or_default();
    let state_str = s("state").unwrap_or_else(|| "started".to_string());
    let created_at = s("createdAt").unwrap_or_default();
    let finished_at = s("finishedAt");
    let pr_url = s("prUrl");
    let last_error = s("lastError");

    let state = match state_str.as_str() {
        "started" | "approved" => AgentState::Streaming,
        "staged" => AgentState::ToolCall,
        "shipped" | "dismissed" => AgentState::Ended,
        "failed" => AgentState::Ended,
        _ => AgentState::Ended,
    };
    let pending_tool_uses = if state_str == "staged" { 1 } else { 0 };
    let last_activity = finished_at
        .as_ref()
        .and_then(|t| iso_to_system_time(t))
        .or_else(|| iso_to_system_time(&created_at));
    let last_assistant_msg = match state_str.as_str() {
        "started" => Some(format!("running — {flow}")),
        "staged" => Some(format!("awaiting approval — {flow}")),
        "approved" => Some(format!("shipping — {flow}")),
        "shipped" => pr_url.clone().or(Some("shipped".to_string())),
        "dismissed" => Some("dismissed".to_string()),
        "failed" => last_error.clone().or(Some("failed".to_string())),
        other => Some(other.to_string()),
    };

    Some(AgentRow {
        source: AgentSource::TattleQwe,
        // Transcript path is meaningless for cloud rows — use a
        // sentinel that `.is_file()` returns false on, so any
        // "open transcript" path no-ops cleanly.
        transcript_path: PathBuf::from(format!("/dev/null/qwe/{run_id}")),
        session_id: run_id,
        workspace: if ticket.is_empty() {
            "tattle".to_string()
        } else {
            ticket
        },
        cwd: None,
        git_branch: None,
        model: None,
        last_activity,
        tokens: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_create_tokens: 0,
        cache_read_tokens: 0,
        cost_usd: 0.0,
        event_count: 0,
        last_user_msg: None,
        last_assistant_msg,
        pid: None,
        state,
        current_tool: None,
        todos: Vec::new(),
        recent_bash: Vec::new(),
        recent_files: Vec::new(),
        recent_subagents: Vec::new(),
        pending_tool_uses,
        tokens_per_min: None,
    })
}

/// Format a `SystemTime` as a UTC ISO-8601 string. DynamoDB stores
/// timestamps in this shape; we only need a value that lexicographically
/// sorts the same way for our `createdAt > :since` filter — no need
/// to round-trip parse it.
fn system_time_to_iso(t: SystemTime) -> String {
    let secs = t
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    let (y, mo, d, h, mi, s) = epoch_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.000Z")
}

/// Parse a DynamoDB-style ISO-8601 string back to `SystemTime`.
/// Accepts the `YYYY-MM-DDTHH:MM:SS[.fff][Z|+HH:MM]` shapes the
/// qwe-runner emits.
fn iso_to_system_time(s: &str) -> Option<SystemTime> {
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let y: i32 = std::str::from_utf8(&bytes[0..4]).ok()?.parse().ok()?;
    let mo: u32 = std::str::from_utf8(&bytes[5..7]).ok()?.parse().ok()?;
    let d: u32 = std::str::from_utf8(&bytes[8..10]).ok()?.parse().ok()?;
    let h: u32 = std::str::from_utf8(&bytes[11..13]).ok()?.parse().ok()?;
    let mi: u32 = std::str::from_utf8(&bytes[14..16]).ok()?.parse().ok()?;
    let sec: u32 = std::str::from_utf8(&bytes[17..19]).ok()?.parse().ok()?;
    let epoch = ymdhms_to_epoch(y, mo, d, h, mi, sec);
    UNIX_EPOCH.checked_add(Duration::from_secs(epoch.max(0) as u64))
}

/// Days from civil 1970-01-01 to civil y-m-d, per Howard Hinnant.
fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = (y - era * 400) as u32;
    let doy = (153 * if m > 2 { m - 3 } else { m + 9 } + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era as i64 * 146_097 + doe as i64 - 719_468
}

fn ymdhms_to_epoch(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> i64 {
    days_from_civil(y, mo, d) * 86_400 + h as i64 * 3600 + mi as i64 * 60 + s as i64
}

/// Inverse of `days_from_civil`. Returns (year, month, day, h, m, s).
fn epoch_to_ymdhms(epoch: i64) -> (i32, u32, u32, u32, u32, u32) {
    let z = epoch.div_euclid(86_400) + 719_468;
    let secs_of_day = epoch.rem_euclid(86_400);
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i32 + era as i32 * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let h = (secs_of_day / 3600) as u32;
    let mi = ((secs_of_day % 3600) / 60) as u32;
    let s = (secs_of_day % 60) as u32;
    (y, m, d, h, mi, s)
}
