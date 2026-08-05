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
    let raw = std::fs::read_to_string(path).ok()?;
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    // Two accepted formats:
    //   1. Plain access token string (starts with `sk-ant-…`)
    //   2. JSON with `accessToken` (+ optional `refreshToken`,
    //      `expiresAt`) — same shape as Claude Code's keychain
    //      `claudeAiOauth` entry so the user can paste the whole
    //      block instead of digging the accessToken out.
    if s.starts_with('{') {
        let v: serde_json::Value = serde_json::from_str(s).ok()?;
        // Accept either `{claudeAiOauth: {…}}` or a bare
        // `{accessToken: …}` inner object.
        let inner = v.get("claudeAiOauth").unwrap_or(&v);
        let token = inner.get("accessToken")?.as_str()?.trim().to_string();
        if token.is_empty() { None } else { Some(token) }
    } else {
        Some(s.to_string())
    }
}

/// If the on-disk token file is a JSON blob with a `refreshToken`,
/// return it. `None` when the file is a plain-string token or the
/// blob doesn't include a refresh token.
pub fn read_claude_refresh_token() -> Option<String> {
    let path = claude_token_path()?;
    let raw = std::fs::read_to_string(path).ok()?;
    let s = raw.trim();
    if !s.starts_with('{') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(s).ok()?;
    let inner = v.get("claudeAiOauth").unwrap_or(&v);
    inner
        .get("refreshToken")
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Persist the OAuth token to `~/.config/mnml/ai_token` with 0600
/// perms (owner read/write only). Idempotent — overwrites the
/// existing file if any.
///
/// Accepts EITHER a plain `sk-ant-oat…` access token OR the whole
/// `claudeAiOauth` JSON blob (as pasted from `security
/// find-generic-password -s 'Claude Code-credentials' -w`). Storing
/// the JSON preserves the refresh token so mnml can auto-refresh on
/// 401 without prompting the user daily.
pub fn write_claude_token(token: &str) -> Result<PathBuf, String> {
    let path = claude_token_path().ok_or_else(|| "no $HOME".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {e}"))?;
    }
    // Best-effort: if the input is a JSON blob, pretty-print it so
    // the on-disk file is readable if the user cats it. Otherwise
    // store verbatim.
    let trimmed = token.trim();
    let to_write = if trimmed.starts_with('{') {
        serde_json::from_str::<serde_json::Value>(trimmed)
            .and_then(|v| serde_json::to_string_pretty(&v))
            .unwrap_or_else(|_| trimmed.to_string())
    } else {
        trimmed.to_string()
    };
    std::fs::write(&path, to_write).map_err(|e| format!("write: {e}"))?;
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
    // Debug hook — always write the last raw response to a
    // predictable path so `:ai.show_last_response` can open it
    // when the parser returns 0% for something the endpoint
    // clearly filled in. Best-effort, silent on failure.
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let dir = home.join(".cache").join("mnml");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(
            dir.join("ai_last_response.json"),
            format!(
                "// HTTP {}\n// fetched_at: {}\n{}\n",
                status.as_u16(),
                now_unix(),
                text
            ),
        );
    }
    if !status.is_success() {
        // Reviewer 2026-08-05 — don't echo the response body on
        // auth failures. Some auth middlewares include the raw
        // Authorization header value in error strings ("invalid
        // Authorization header: Bearer sk-ant-oat-…"), which
        // would then flow into `last_error` → toast → `screen.txt`
        // on disk. Better to render a generic hint. For other
        // status codes, redact any bearer-token-like substring.
        let msg = if status.as_u16() == 401 || status.as_u16() == 403 {
            "token rejected — re-link via :ai.link_claude_token".to_string()
        } else {
            truncate(&redact_bearer(&text), 80)
        };
        return Err(format!("HTTP {}: {}", status.as_u16(), msg));
    }
    parse_claude_response(&text)
}

/// Replace anything that looks like a bearer token with `<redacted>`
/// so error responses that echo it back can't leak into logs /
/// toasts / on-disk screen.txt. Matches `sk-ant-…`, `sk-…`, and
/// generic `Bearer <hex-ish blob>` shapes.
fn redact_bearer(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(idx) = rest.find(['s', 'B']) {
        out.push_str(&rest[..idx]);
        let tail = &rest[idx..];
        // Consume until whitespace / closing quote / end
        let end = tail
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'')
            .unwrap_or(tail.len());
        let candidate = &tail[..end];
        let looks_bearer = candidate.starts_with("sk-")
            || candidate.starts_with("Bearer ")
            || candidate.starts_with("sk_ant")
            || (candidate.len() > 40 && candidate.starts_with("sk"));
        if looks_bearer {
            out.push_str("<redacted>");
        } else {
            out.push_str(candidate);
        }
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

/// Parse the real Anthropic `/api/oauth/usage` response.
/// Verified shape (2026-08-05):
///   `{five_hour: {utilization, resets_at (ISO-8601 string), …},
///     seven_day: {utilization, resets_at, …},
///     limits: [{kind: "session"|"weekly_all"|…, percent, resets_at, …}], …}`
/// Both `five_hour` and `seven_day` are optional (older tiers may
/// omit); the `limits[]` array is the fallback when the top-level
/// shortcuts are missing.
fn parse_claude_response(text: &str) -> Result<ClaudeUsage, String> {
    let v: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("parse json: {e}"))?;
    let (percent, resets_at) = extract_session(&v);
    let (weekly_percent, _weekly_resets) = extract_weekly(&v);
    Ok(ClaudeUsage {
        percent,
        weekly_percent,
        resets_at,
        tokens_5h: 0, // endpoint doesn't return raw token counts
        fetched_at: now_unix(),
        last_error: None,
    })
}

/// Pull the 5h/session utilization + reset time. Preferred path:
/// `five_hour.utilization` + `.resets_at`. Fallback: scan the
/// `limits[]` array for `kind == "session"`.
fn extract_session(v: &serde_json::Value) -> (u16, u64) {
    if let Some(fh) = v.get("five_hour") {
        let util = fh
            .get("utilization")
            .and_then(|x| x.as_f64())
            .map(|n| n.round().clamp(0.0, 999.0) as u16)
            .unwrap_or(0);
        let resets = fh
            .get("resets_at")
            .and_then(|x| x.as_str())
            .and_then(parse_iso8601_secs)
            .unwrap_or(0);
        if util > 0 || resets > 0 {
            return (util, resets);
        }
    }
    // Fallback: limits[] with kind "session".
    if let Some(limits) = v.get("limits").and_then(|x| x.as_array()) {
        for entry in limits {
            let kind = entry.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            if kind == "session" {
                let pct = entry
                    .get("percent")
                    .and_then(|x| x.as_f64())
                    .map(|n| n.round().clamp(0.0, 999.0) as u16)
                    .unwrap_or(0);
                let resets = entry
                    .get("resets_at")
                    .and_then(|x| x.as_str())
                    .and_then(parse_iso8601_secs)
                    .unwrap_or(0);
                return (pct, resets);
            }
        }
    }
    (0, 0)
}

/// Same pattern for the 7-day/weekly window. Preferred:
/// `seven_day.utilization`. Fallback: `limits[]` with kind
/// `weekly_all` (the top-level weekly, not per-model scoped).
fn extract_weekly(v: &serde_json::Value) -> (u16, u64) {
    if let Some(sd) = v.get("seven_day") {
        let util = sd
            .get("utilization")
            .and_then(|x| x.as_f64())
            .map(|n| n.round().clamp(0.0, 999.0) as u16)
            .unwrap_or(0);
        let resets = sd
            .get("resets_at")
            .and_then(|x| x.as_str())
            .and_then(parse_iso8601_secs)
            .unwrap_or(0);
        if util > 0 || resets > 0 {
            return (util, resets);
        }
    }
    if let Some(limits) = v.get("limits").and_then(|x| x.as_array()) {
        for entry in limits {
            let kind = entry.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            if kind == "weekly_all" {
                let pct = entry
                    .get("percent")
                    .and_then(|x| x.as_f64())
                    .map(|n| n.round().clamp(0.0, 999.0) as u16)
                    .unwrap_or(0);
                let resets = entry
                    .get("resets_at")
                    .and_then(|x| x.as_str())
                    .and_then(parse_iso8601_secs)
                    .unwrap_or(0);
                return (pct, resets);
            }
        }
    }
    (0, 0)
}

/// Depth-first search for a key anywhere in the JSON tree, capped
/// at MAX_DEPTH so a pathological / attacker-crafted deep JSON can't
/// blow the worker's stack. Returns the first match. Used only as a
/// FALLBACK — see `parse_claude_response` for the preferred
/// known-path lookups.
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

/// Minimal ISO-8601 → Unix seconds parser. Handles the shape
/// Anthropic's OAuth-usage endpoint writes for `resets_at`:
/// `2026-08-05T22:50:00.123240+00:00` or `2026-08-05T22:50:00Z`.
fn parse_iso8601_secs(s: &str) -> Option<u64> {
    if s.len() < 19 {
        return None;
    }
    let (y, rest) = (s.get(0..4)?.parse::<i64>().ok()?, s.get(5..)?);
    let (mo, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (d, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (h, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (mi, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let sec: u64 = rest.get(0..2)?.parse().ok()?;
    // Skip optional `.fff…` fractional seconds, then read the tz.
    let tz_start = rest.get(2..)?;
    let tz_str = if let Some(dot) = tz_start.strip_prefix('.') {
        dot.trim_start_matches(|c: char| c.is_ascii_digit())
    } else {
        tz_start
    };
    let tz_offset_secs: i64 = match tz_str.chars().next() {
        Some('Z') | Some('z') | None => 0,
        Some(sign_ch) if sign_ch == '+' || sign_ch == '-' => {
            let sign: i64 = if sign_ch == '-' { -1 } else { 1 };
            let body = tz_str.get(1..)?;
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
    let utc_secs = local_secs - tz_offset_secs;
    if utc_secs < 0 {
        None
    } else {
        Some(utc_secs as u64)
    }
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

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        s.chars().take(n).collect::<String>() + "…"
    }
}
