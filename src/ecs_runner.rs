//! Cloud-agent ECS runner — surface cloud-run rows from the
//! configured DynamoDB run-records table alongside local Claude /
//! Codex sessions in the Agents dashboard.
//!
//! Auth: shell out to the `aws` CLI so the user's SSO session is
//! picked up via `AWS_PROFILE`. No creds touched in-process.
//!
//! The feature is a no-op until the user configures
//! `[cloud_agents]` — rail rows return empty, the wizard entry is
//! skipped, the trigger short-circuits with an "unconfigured" toast.
//!
//! Data model (per-row):
//!   runId · ticket · flow · source · state · createdAt ·
//!   finishedAt · approvalIntent · s3ArtifactPrefix · slackTs ·
//!   prUrl · lastRunStatus · lastError
//!
//! State lifecycle:  started → staged → approved → shipped
//!                                                  ↘ dismissed / failed

use crate::claude_agents::{AgentRow, AgentSource, AgentState};
use crate::config::CloudAgentsConfig;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Only surface runs in the last N hours — keeps the rail tidy
/// when historical rows accumulate.
const RECENT_HOURS: u64 = 24;

/// Per-run metadata kept on `App` keyed by runId. Stores the
/// cloud-specific URLs / state we need for the right-click menu
/// but don't want to bolt onto every `AgentRow` (most rows are
/// local Claude/Codex sessions that don't carry this data).
#[derive(Debug, Clone, Default)]
pub struct EcsRunMeta {
    pub ticket: String,
    pub flow: String,
    pub state: String,
    pub pr_url: Option<String>,
    pub s3_artifact_prefix: Option<String>,
    /// Snapshot of the account/region/log-group used to build
    /// this run's CloudWatch URL. Kept on the meta so URL
    /// construction stays stateless.
    pub account_id: String,
    pub region: String,
    pub log_group: String,
}

impl EcsRunMeta {
    /// Build a CloudWatch Logs Insights URL pre-filtered to lines
    /// mentioning this `runId`. Returns an empty string when
    /// account/region/log_group is missing.
    pub fn cloudwatch_url(&self, run_id: &str) -> String {
        if self.account_id.is_empty() || self.region.is_empty() || self.log_group.is_empty() {
            return String::new();
        }
        let encoded_group = self.log_group.replace('/', "$252F");
        let query = format!(
            "fields @timestamp, @message | filter @message like /{run_id}/ | sort @timestamp desc"
        );
        let encoded_query = urlencoding_minimal(&query);
        let region = &self.region;
        let account = &self.account_id;
        format!(
            "https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}#logsV2:logs-insights$3FqueryDetail$3D~(end~0~start~-86400~timeType~'RELATIVE~unit~'seconds~editorString~'{encoded_query}~source~(~'{encoded_group}))?account={account}"
        )
    }
}

/// Tiny URL-encoder for the characters Logs-Insights syntax cares
/// about. The console's bespoke `~` / `$3F` format is fussy, so we
/// only escape the bits we know matter (space, pipe, slash, dot,
/// quote, paren) — anything else is fine literal.
fn urlencoding_minimal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for c in s.chars() {
        match c {
            ' ' => out.push_str("*20"),
            '|' => out.push_str("*7c"),
            '/' => out.push_str("*2f"),
            '.' => out.push_str("*2e"),
            ',' => out.push_str("*2c"),
            '\'' => out.push_str("*27"),
            '(' => out.push_str("*28"),
            ')' => out.push_str("*29"),
            '@' => out.push_str("*40"),
            other => out.push(other),
        }
    }
    out
}

/// Scan the configured run-records DynamoDB table for recent
/// rows. Returns (rows, per-runId metadata) — both empty when:
///   - `cloud_agents` isn't configured,
///   - `aws` CLI is not on PATH,
///   - the user isn't SSO'd in (`aws` returns 255),
///   - the table is empty / the user can't read it,
///   - any parse error occurs.
///
/// Logs nothing to stderr — silent failure is fine here; the rail
/// just doesn't show cloud rows.
pub fn collect_cloud_rows_with_meta(
    config: &CloudAgentsConfig,
) -> (Vec<AgentRow>, HashMap<String, EcsRunMeta>) {
    if !config.is_enabled() {
        return (Vec::new(), HashMap::new());
    }
    let region = config.effective_region();
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(RECENT_HOURS * 3600))
        .unwrap_or(UNIX_EPOCH);
    let cutoff_iso = system_time_to_iso(cutoff);
    let mut bytes = run_scan(&cutoff_iso, &region, &config.runs_table, None);
    if bytes.is_none()
        && let Some(fallback) = config.effective_aws_profile_fallback()
    {
        bytes = run_scan(&cutoff_iso, &region, &config.runs_table, Some(&fallback));
    }
    let bytes = match bytes {
        Some(b) => b,
        None => return (Vec::new(), HashMap::new()),
    };
    let json: serde_json::Value = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(_) => return (Vec::new(), HashMap::new()),
    };
    let items = match json.get("Items").and_then(|v| v.as_array()) {
        Some(a) => a,
        None => return (Vec::new(), HashMap::new()),
    };
    let default_ws = config.effective_default_workspace_label().to_string();
    let mut rows = Vec::new();
    let mut meta = HashMap::new();
    for item in items {
        if let Some((row, m)) = parse_run_record(
            item,
            &config.account_id,
            &region,
            &config.log_group,
            &default_ws,
        ) {
            meta.insert(row.session_id.clone(), m);
            rows.push(row);
        }
    }
    (rows, meta)
}

/// Parse one DynamoDB Item (in low-level type-wrapped form, i.e.
/// `{"runId":{"S":"abc"},...}`) into an `(AgentRow, EcsRunMeta)`.
fn parse_run_record(
    item: &serde_json::Value,
    account_id: &str,
    region: &str,
    log_group: &str,
    default_workspace: &str,
) -> Option<(AgentRow, EcsRunMeta)> {
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
    let s3_prefix = s("s3ArtifactPrefix");
    let last_error = s("lastError");
    let meta = EcsRunMeta {
        ticket: ticket.clone(),
        flow: flow.clone(),
        state: state_str.clone(),
        pr_url: pr_url.clone(),
        s3_artifact_prefix: s3_prefix,
        account_id: account_id.to_string(),
        region: region.to_string(),
        log_group: log_group.to_string(),
    };

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

    let row = AgentRow {
        source: AgentSource::Ecs,
        // Transcript path is meaningless for cloud rows — use a
        // sentinel that `.is_file()` returns false on, so any
        // "open transcript" path no-ops cleanly.
        transcript_path: PathBuf::from(format!("/dev/null/ecs/{run_id}")),
        session_id: run_id,
        workspace: if ticket.is_empty() {
            default_workspace.to_string()
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
    };
    Some((row, meta))
}

/// Single `aws dynamodb scan` invocation. Returns `Some(stdout)`
/// on success, `None` on any failure (no auth, no network, …).
fn run_scan(cutoff_iso: &str, region: &str, table: &str, profile: Option<&str>) -> Option<Vec<u8>> {
    let mut cmd = Command::new("aws");
    cmd.args([
        "dynamodb",
        "scan",
        "--table-name",
        table,
        "--region",
        region,
        "--filter-expression",
        "createdAt > :since",
        "--expression-attribute-values",
        &format!("{{\":since\":{{\"S\":\"{cutoff_iso}\"}}}}"),
        "--output",
        "json",
    ]);
    if let Some(p) = profile {
        cmd.env("AWS_PROFILE", p);
    }
    cmd.output()
        .ok()
        .and_then(|o| o.status.success().then_some(o.stdout))
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

/// Parse an ISO-8601 string back to `SystemTime`. Accepts
/// `YYYY-MM-DDTHH:MM:SS[.fff][Z|+HH:MM]`.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_config_returns_empty() {
        let cfg = CloudAgentsConfig::default();
        let (rows, meta) = collect_cloud_rows_with_meta(&cfg);
        assert!(rows.is_empty());
        assert!(meta.is_empty());
    }

    #[test]
    fn cloudwatch_url_empty_when_no_account() {
        let m = EcsRunMeta::default();
        assert!(m.cloudwatch_url("run-x").is_empty());
    }

    #[test]
    fn cloudwatch_url_contains_region_and_account() {
        let m = EcsRunMeta {
            account_id: "123456789012".to_string(),
            region: "us-east-1".to_string(),
            log_group: "/ecs/my/log".to_string(),
            ..Default::default()
        };
        let url = m.cloudwatch_url("run-abc");
        assert!(url.contains("us-east-1"));
        assert!(url.contains("123456789012"));
    }
}
