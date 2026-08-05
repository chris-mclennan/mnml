//! AI usage meters — Claude Code (Max subscription OAuth quota) +
//! Codex (local JSONL token telemetry aggregation).
//!
//! Populated by background workers spawned from `App::maybe_refresh_ai_usage`
//! + drained per tick via `App::drain_ai_usage`. Renders as two
//! statusline chips (see `ui::statusline`) gated by each integration
//! icon's `enabled` flag.
//!
//! ## Auth
//!
//! Claude: reads an OAuth token from `~/.config/mnml/ai_token`
//! (written by the `:ai.link_claude_token` palette command — the
//! user pastes their Claude Code OAuth token once). The chip shows
//! `—` until the token file exists.
//!
//! Codex: no auth needed. The Codex CLI logs each turn to
//! `~/.codex/sessions/*.jsonl` (session files, one JSON per line);
//! we sum today's token counts across those files.

use std::path::{Path, PathBuf};
use std::sync::mpsc;

/// Last-fetched snapshot for the Claude chip. `percent` is the 5-hour
/// window utilization; `weekly_percent` is the weekly window (if the
/// endpoint returns it — currently uncertain, defaults 0). `resets_at`
/// is a Unix timestamp when the current 5h window ends.
#[derive(Debug, Clone, Default)]
pub struct ClaudeUsage {
    pub percent: u16,
    pub weekly_percent: u16,
    pub resets_at: u64,
    pub tokens_5h: u64,
    pub fetched_at: u64,
    pub last_error: Option<String>,
}

/// Last-fetched snapshot for the Codex chip. Cumulative tokens
/// today across all `~/.codex/sessions/*.jsonl` sessions started
/// today, plus a coarse session count.
#[derive(Debug, Clone, Default)]
pub struct CodexUsage {
    pub tokens_today: u64,
    pub sessions_today: u64,
    pub fetched_at: u64,
    pub last_error: Option<String>,
}

/// Path where the user's Claude Code OAuth token lives after the
/// `:ai.link_claude_token` prompt persists it. Chmod 600. Returns
/// None if $HOME can't be resolved (headless / bad env).
pub fn claude_token_path() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|h| h.join(".config").join("mnml").join("ai_token"))
}

pub fn read_claude_token() -> Option<String> {
    let path = claude_token_path()?;
    std::fs::read_to_string(path).ok().and_then(|s| {
        let t = s.trim().to_string();
        if t.is_empty() { None } else { Some(t) }
    })
}

/// Persist the OAuth token to `~/.config/mnml/ai_token` with 0600
/// perms (owner read/write only). Idempotent — overwrites the
/// existing file if any.
pub fn write_claude_token(token: &str) -> Result<PathBuf, String> {
    let path = claude_token_path().ok_or_else(|| "no $HOME".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {e}"))?;
    }
    std::fs::write(&path, token.trim()).map_err(|e| format!("write: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(path)
}

/// Spawn a worker thread to fetch Claude usage from Anthropic's
/// undocumented OAuth-usage endpoint. Returns immediately with a
/// Receiver — poll via `try_recv()` in a per-tick drain. Emits Err
/// with a human-readable message on any failure (network, HTTP
/// status, JSON parse). No token = Err.
pub fn spawn_claude_fetch() -> mpsc::Receiver<Result<ClaudeUsage, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = fetch_claude_blocking();
        let _ = tx.send(result);
    });
    rx
}

fn fetch_claude_blocking() -> Result<ClaudeUsage, String> {
    let token = read_claude_token().ok_or_else(|| "not linked".to_string())?;
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let resp = client
        .get("https://api.anthropic.com/api/oauth/usage")
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .map_err(|e| format!("fetch: {e}"))?;
    let status = resp.status();
    let text = resp.text().map_err(|e| format!("body read: {e}"))?;
    if !status.is_success() {
        return Err(format!("HTTP {}: {}", status.as_u16(), truncate(&text, 80)));
    }
    parse_claude_response(&text)
}

/// Best-effort JSON parse. The endpoint's schema isn't officially
/// documented, so we probe several plausible field names + fall back
/// to zero if a field is missing. If the entire body doesn't look
/// like JSON, return Err.
fn parse_claude_response(text: &str) -> Result<ClaudeUsage, String> {
    let v: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("parse json: {e}"))?;
    // Try common shapes: {five_hour: {percent, resets_at, tokens}} +
    // {weekly: {percent}}. Fall back to top-level percent fields.
    let percent =
        pick_percent(&v, &["five_hour_percent", "session_percent", "percent"]).unwrap_or(0);
    let weekly_percent =
        pick_percent(&v, &["weekly_percent", "week_percent", "weekly"]).unwrap_or(0);
    let resets_at = pick_u64(
        &v,
        &[
            "five_hour_resets_at",
            "resets_at",
            "reset_at",
            "session_resets_at",
        ],
    )
    .unwrap_or(0);
    let tokens_5h = pick_u64(
        &v,
        &[
            "five_hour_tokens",
            "session_tokens",
            "tokens",
            "input_tokens",
        ],
    )
    .unwrap_or(0);
    let fetched_at = now_unix();
    Ok(ClaudeUsage {
        percent,
        weekly_percent,
        resets_at,
        tokens_5h,
        fetched_at,
        last_error: None,
    })
}

fn pick_percent(v: &serde_json::Value, keys: &[&str]) -> Option<u16> {
    for &k in keys {
        if let Some(n) = walk(v, k).and_then(|x| x.as_f64()) {
            return Some(n.round().clamp(0.0, 999.0) as u16);
        }
    }
    None
}

fn pick_u64(v: &serde_json::Value, keys: &[&str]) -> Option<u64> {
    for &k in keys {
        if let Some(n) = walk(v, k).and_then(|x| x.as_u64()) {
            return Some(n);
        }
    }
    None
}

/// Depth-first search for a key anywhere in the JSON tree. Returns
/// the first match. Safer than assuming a schema shape when the
/// endpoint isn't documented.
fn walk<'a>(v: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    if let Some(map) = v.as_object() {
        if let Some(hit) = map.get(key) {
            return Some(hit);
        }
        for val in map.values() {
            if let Some(hit) = walk(val, key) {
                return Some(hit);
            }
        }
    }
    if let Some(arr) = v.as_array() {
        for item in arr {
            if let Some(hit) = walk(item, key) {
                return Some(hit);
            }
        }
    }
    None
}

/// Spawn a worker to scan `~/.codex/sessions/*.jsonl` for today's
/// files + sum per-turn token counts. Codex CLI writes one JSON
/// object per line; we look for `token_usage.total_tokens` (or
/// similar) on each and add.
pub fn spawn_codex_fetch() -> mpsc::Receiver<Result<CodexUsage, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = fetch_codex_blocking();
        let _ = tx.send(result);
    });
    rx
}

fn fetch_codex_blocking() -> Result<CodexUsage, String> {
    let sessions_dir = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|h| h.join(".codex").join("sessions"))
        .ok_or_else(|| "no $HOME".to_string())?;
    if !sessions_dir.exists() {
        return Ok(CodexUsage {
            last_error: Some("~/.codex/sessions not found".into()),
            fetched_at: now_unix(),
            ..Default::default()
        });
    }
    let _today = today_string();
    let mut tokens_today = 0u64;
    let mut sessions_today = 0u64;
    let entries = std::fs::read_dir(&sessions_dir).map_err(|e| format!("read_dir: {e}"))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        // Filter to files modified today — cheap prefilter before
        // reading the (potentially large) file.
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(mtime) = meta.modified() else { continue };
        if !is_today(mtime) {
            continue;
        }
        sessions_today += 1;
        tokens_today += sum_tokens_in_jsonl(&path).unwrap_or(0);
    }
    Ok(CodexUsage {
        tokens_today,
        sessions_today,
        fetched_at: now_unix(),
        last_error: None,
    })
}

fn sum_tokens_in_jsonl(path: &Path) -> Option<u64> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut sum = 0u64;
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        // Codex CLI records `token_usage: {input_tokens, output_tokens, ...}`
        // on turn-record objects. Sum whatever we find — schema
        // varies between Codex CLI releases so probe several fields.
        let usage = walk(&v, "token_usage").or_else(|| walk(&v, "usage"));
        if let Some(usage) = usage {
            let inp = usage
                .get("input_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            let out = usage
                .get("output_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            let total = usage
                .get("total_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(inp + out);
            sum += total;
        }
    }
    Some(sum)
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn today_string() -> String {
    // YYYY-MM-DD in local time (via chrono would be tidier but we
    // stay dep-light here; the epoch math + local offset is enough
    // for a "same day" check).
    let secs = now_unix() as i64;
    let days = secs / 86400;
    // 1970-01-01 is day 0. Adjust to local — approximate via
    // TZ envvar not applied; sufficient for a rough today filter.
    // (mtime comparison is used for the actual filter — this string
    // is only for parity with future rolling-day logic.)
    let (y, m, d) = day_to_ymd(days);
    format!("{y:04}-{m:02}-{d:02}")
}

fn day_to_ymd(days: i64) -> (i32, u32, u32) {
    // From `chrono`'s NaiveDate::from_num_days_from_ce, simplified.
    // We approximate: 1970-01-01 is day 719_162 in CE.
    let mut d = days + 719_162;
    let mut y: i32 = 400 * (d as i32 / 146_097);
    d %= 146_097;
    if d == 146_096 {
        y += 400;
        d = 0;
    }
    let (mut yi, mut di) = (y as i64, d);
    // 100-year cycles.
    let c = (di / 36524).min(3);
    di -= c * 36524;
    yi += c * 100;
    // 4-year cycles.
    let f = di / 1461;
    di -= f * 1461;
    yi += f * 4;
    // Single years.
    let g = (di / 365).min(3);
    di -= g * 365;
    yi += g;
    // Month/day.
    let leap = (yi % 4 == 0) && (yi % 100 != 0 || yi % 400 == 0);
    let days_per_month = if leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m: u32 = 1;
    let mut rem = di as u32;
    for &dpm in days_per_month.iter() {
        if rem < dpm {
            break;
        }
        rem -= dpm;
        m += 1;
    }
    let day = rem + 1;
    (yi as i32, m, day)
}

fn is_today(t: std::time::SystemTime) -> bool {
    let Ok(dur) = t.duration_since(std::time::UNIX_EPOCH) else {
        return false;
    };
    let secs = dur.as_secs() as i64;
    let now = now_unix() as i64;
    // Same day if both round to the same `days` bucket. Approximate
    // (no local-TZ offset); good enough for today-vs-not.
    (secs / 86400) == (now / 86400)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        s.chars().take(n).collect::<String>() + "…"
    }
}
