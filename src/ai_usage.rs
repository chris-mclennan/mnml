//! AI usage meters — Claude Code (JSONL transcript aggregation) +
//! Codex (local JSONL token telemetry aggregation).
//!
//! Populated by background workers spawned from `App::maybe_refresh_ai_usage`
//! + drained per tick via `App::drain_ai_usage`. Renders as two
//! statusline chips (see `ui::statusline`) gated by each integration
//! icon's `enabled` flag.
//!
//! ## Data sources
//!
//! Both providers write transcript JSONL locally + we sum per-turn
//! token counts. No auth, no network, no undocumented endpoints.
//!
//! * **Claude**: scans `~/.claude/projects/**/*.jsonl`. Each line
//!   is one turn; assistant lines carry a `message.usage` object
//!   with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
//!   `cache_read_input_tokens`. We sum input + output + cache_creation
//!   inside a rolling 5-hour window — an APPROXIMATION of the Max
//!   subscription's quota bucket, not a verified match (Anthropic
//!   hasn't published the exact weighting formula, and
//!   `cache_creation` is billed at a premium). Treat the percent
//!   as directional, not authoritative. `cache_read` is heavily
//!   discounted and excluded from the sum.
//! * **Codex**: `~/.codex/sessions/*.jsonl`, one `token_usage` /
//!   `usage` object per turn. Same shape, different key.

use std::path::{Path, PathBuf};
use std::sync::mpsc;

/// Rolling window we sum tokens over. Claude Max's per-user quota
/// resets every 5 hours; matching that so the percent chip reads
/// against a comparable bucket.
const CLAUDE_WINDOW_SECS: u64 = 5 * 3600;

/// Default token cap used to derive percent when the config hasn't
/// been overridden. Rough approximation of a Max 5x tier's 5h
/// quota; user can override via `[ai] claude_5h_cap`.
pub const CLAUDE_DEFAULT_5H_CAP: u64 = 500_000;

/// Last-fetched snapshot for the Claude chip. Sourced from Claude
/// Code's own JSONL transcripts (`~/.claude/projects/**/*.jsonl`),
/// summed over the last 5 hours.
#[derive(Debug, Clone, Default)]
pub struct ClaudeUsage {
    pub percent: u16,
    pub tokens_5h: u64,
    pub cap_5h: u64,
    /// Unix seconds when the OLDEST message in the window ages out
    /// (i.e. when the quota starts recovering — the "resets" hint).
    /// 0 when no messages are in the window.
    pub resets_at: u64,
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

/// Spawn a worker to scan `~/.claude/projects/**/*.jsonl` for the
/// last 5 hours of assistant turns + sum their token usage. No
/// network, no auth. Returns immediately; poll via `try_recv()` in
/// a per-tick drain.
pub fn spawn_claude_fetch(cap_5h: u64) -> mpsc::Receiver<Result<ClaudeUsage, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = fetch_claude_blocking(cap_5h);
        let _ = tx.send(result);
    });
    rx
}

fn fetch_claude_blocking(cap_5h: u64) -> Result<ClaudeUsage, String> {
    let projects_dir = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|h| h.join(".claude").join("projects"))
        .ok_or_else(|| "no $HOME".to_string())?;
    if !projects_dir.exists() {
        return Ok(ClaudeUsage {
            cap_5h,
            last_error: Some("~/.claude/projects not found".into()),
            fetched_at: now_unix(),
            ..Default::default()
        });
    }
    let cutoff = now_unix().saturating_sub(CLAUDE_WINDOW_SECS);
    let mut tokens = 0u64;
    let mut oldest_in_window: Option<u64> = None;
    // Walk `~/.claude/projects/*/*.jsonl` — one dir per project,
    // one JSONL per session. Only touch files whose mtime is
    // within (or after) the cutoff — session files that ended
    // long ago can't contribute to the current 5h window.
    let project_dirs = std::fs::read_dir(&projects_dir).map_err(|e| format!("read_dir: {e}"))?;
    for proj in project_dirs.flatten() {
        let Ok(pmeta) = proj.metadata() else { continue };
        if !pmeta.is_dir() {
            continue;
        }
        let Ok(files) = std::fs::read_dir(proj.path()) else {
            continue;
        };
        for file in files.flatten() {
            let path = file.path();
            if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                continue;
            }
            let Ok(fmeta) = file.metadata() else { continue };
            let Ok(mtime) = fmeta.modified() else {
                continue;
            };
            let Ok(mtime_secs) = mtime.duration_since(std::time::UNIX_EPOCH) else {
                continue;
            };
            if mtime_secs.as_secs() < cutoff {
                // File hasn't been touched in >5h — nothing in
                // the current window.
                continue;
            }
            let (t, oldest) = sum_claude_tokens_in_window(&path, cutoff);
            tokens += t;
            if let Some(o) = oldest {
                oldest_in_window = Some(oldest_in_window.map_or(o, |cur| cur.min(o)));
            }
        }
    }
    let percent = tokens
        .checked_mul(100)
        .and_then(|n| n.checked_div(cap_5h))
        .map(|p| p.min(999) as u16)
        .unwrap_or(0);
    let resets_at = oldest_in_window
        .map(|o| o + CLAUDE_WINDOW_SECS)
        .unwrap_or(0);
    Ok(ClaudeUsage {
        percent,
        tokens_5h: tokens,
        cap_5h,
        resets_at,
        fetched_at: now_unix(),
        last_error: None,
    })
}

/// Stream one Claude Code JSONL file, summing token usage from
/// assistant turns with a timestamp within the last 5h.
/// Returns `(tokens, oldest_in_window_ts)`. cache_read tokens
/// are excluded — they don't count against the quota.
fn sum_claude_tokens_in_window(path: &Path, cutoff: u64) -> (u64, Option<u64>) {
    use std::io::{BufRead, BufReader};
    const MAX_LINES_PER_FILE: usize = 100_000;
    let Ok(file) = std::fs::File::open(path) else {
        return (0, None);
    };
    let reader = BufReader::new(file);
    let mut sum = 0u64;
    let mut oldest: Option<u64> = None;
    for (i, line) in reader.lines().enumerate() {
        if i >= MAX_LINES_PER_FILE {
            break;
        }
        let Ok(line) = line else { continue };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        // Timestamp — usually top-level "timestamp" (ISO-8601)
        // OR nested `message.timestamp` / `created_at`. Skip if
        // we can't find one.
        let Some(ts) = extract_timestamp(&v) else {
            continue;
        };
        if ts < cutoff {
            continue;
        }
        // Assistant turns carry `message.usage`. Sum
        // input + output + cache_creation as an APPROXIMATION of
        // what the Max quota tracks. `cache_creation` is billed
        // at a ~1.25x premium so summing it 1:1 slightly
        // underweights it; `cache_read` is heavily discounted and
        // excluded. Anthropic hasn't published the exact quota
        // formula — treat the percent as directional.
        let usage = v
            .get("message")
            .and_then(|m| m.get("usage"))
            .or_else(|| v.get("usage"));
        if let Some(u) = usage {
            let inp = u.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
            let out = u.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
            let cache_create = u
                .get("cache_creation_input_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            sum += inp + out + cache_create;
            oldest = Some(oldest.map_or(ts, |cur| cur.min(ts)));
        }
    }
    (sum, oldest)
}

/// Extract a Unix-seconds timestamp from a Claude Code JSONL
/// record. Handles the ISO-8601 shape (`"2026-08-05T12:34:56Z"`)
/// and Unix-seconds int fallbacks.
fn extract_timestamp(v: &serde_json::Value) -> Option<u64> {
    let candidates = [
        v.get("timestamp"),
        v.get("message").and_then(|m| m.get("timestamp")),
        v.get("created_at"),
    ];
    for c in candidates.into_iter().flatten() {
        if let Some(n) = c.as_u64() {
            return Some(n);
        }
        if let Some(s) = c.as_str()
            && let Some(ts) = parse_iso8601_secs(s)
        {
            return Some(ts);
        }
    }
    None
}

/// Minimal ISO-8601 → Unix seconds parser. Handles the shape
/// Claude Code writes: `2026-08-05T12:34:56.789Z` or
/// `2026-08-05T12:34:56Z` or `2026-08-05T12:34:56±HH:MM`. Returns
/// None on anything else. We don't need full RFC 3339 coverage —
/// just what the emitter produces.
fn parse_iso8601_secs(s: &str) -> Option<u64> {
    // YYYY-MM-DDTHH:MM:SS at a minimum
    if s.len() < 19 {
        return None;
    }
    let (y, rest) = (s.get(0..4)?.parse::<i64>().ok()?, s.get(5..)?);
    let (mo, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (d, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (h, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (mi, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let sec: u64 = rest.get(0..2)?.parse().ok()?;
    // Consume optional fractional seconds `.NNN…` so we can find
    // the timezone suffix regardless of subsecond precision.
    let tz_start = rest.get(2..)?;
    let tz_str = if let Some(dot) = tz_start.strip_prefix('.') {
        // Skip the fractional digits, then whatever's left is the tz.
        dot.trim_start_matches(|c: char| c.is_ascii_digit())
    } else {
        tz_start
    };
    // Reviewer 2026-08-05 — timezone-aware. `Z` is UTC (offset 0).
    // `±HH:MM` (or `±HHMM`) is an offset that we SUBTRACT from the
    // local-clock time we parsed above to get UTC. Missing/empty tz
    // is treated as UTC (fallback; Claude Code writes `Z` in
    // practice, but we don't want to silently skew if that changes).
    let tz_offset_secs: i64 = match tz_str.chars().next() {
        Some('Z') | Some('z') | None => 0,
        Some(sign_ch) if sign_ch == '+' || sign_ch == '-' => {
            let sign: i64 = if sign_ch == '-' { -1 } else { 1 };
            let body = tz_str.get(1..)?;
            // Accept "HHMM" or "HH:MM"
            let (hh, mm) = if let Some((h_str, m_str)) = body.split_once(':') {
                (h_str.parse::<i64>().ok()?, m_str.parse::<i64>().ok()?)
            } else if body.len() >= 4 {
                (
                    body.get(0..2)?.parse::<i64>().ok()?,
                    body.get(2..4)?.parse::<i64>().ok()?,
                )
            } else {
                return None;
            };
            sign * (hh * 3600 + mm * 60)
        }
        _ => 0,
    };
    // Days since 1970-01-01 (proleptic Gregorian).
    let year_days = |y: i64| -> i64 {
        let y = y - 1;
        (y * 365) + (y / 4) - (y / 100) + (y / 400)
    };
    let is_leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = if is_leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut d_of_year: i64 = (d as i64) - 1;
    for m_idx in 0..(mo as usize).saturating_sub(1) {
        d_of_year += month_days.get(m_idx).copied().unwrap_or(0) as i64;
    }
    let days_since_epoch = year_days(y) - year_days(1970) + d_of_year;
    let local_secs = days_since_epoch * 86400 + (h as i64) * 3600 + (mi as i64) * 60 + sec as i64;
    // Local → UTC: subtract the offset (e.g. `+05:00` means clock
    // is 5h ahead of UTC, so UTC = local - 5h).
    let utc_secs = local_secs - tz_offset_secs;
    if utc_secs < 0 {
        None
    } else {
        Some(utc_secs as u64)
    }
}

/// Best-effort JSON parse. The endpoint's schema isn't officially
/// Depth-first search for a key anywhere in the JSON tree, capped
/// at MAX_DEPTH so a pathological deep JSON can't blow the worker's
/// stack. Returns the first match. Used by the Codex JSONL scanner
/// where the `usage` key can nest under different parent shapes
/// across Codex CLI releases.
fn walk<'a>(v: &'a serde_json::Value, key: &str, depth: usize) -> Option<&'a serde_json::Value> {
    const MAX_DEPTH: usize = 8;
    if depth > MAX_DEPTH {
        return None;
    }
    if let Some(map) = v.as_object() {
        if let Some(hit) = map.get(key) {
            return Some(hit);
        }
        for val in map.values() {
            if let Some(hit) = walk(val, key, depth + 1) {
                return Some(hit);
            }
        }
    }
    if let Some(arr) = v.as_array() {
        for item in arr {
            if let Some(hit) = walk(item, key, depth + 1) {
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
    use std::io::{BufRead, BufReader};
    // Reviewer 2026-08-05 — was `read_to_string` which slurped the
    // entire session file (potentially many MB after a long day).
    // Stream line-by-line so peak memory is bounded to one line +
    // its parsed Value. Also cap total lines read per file so a
    // runaway JSONL never blocks the worker indefinitely.
    const MAX_LINES_PER_FILE: usize = 100_000;
    let file = std::fs::File::open(path).ok()?;
    let reader = BufReader::new(file);
    let mut sum = 0u64;
    for (i, line) in reader.lines().enumerate() {
        if i >= MAX_LINES_PER_FILE {
            break;
        }
        let Ok(line) = line else { continue };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let usage = walk(&v, "token_usage", 0).or_else(|| walk(&v, "usage", 0));
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
