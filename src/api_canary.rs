//! Trip-wire around every read of `$ANTHROPIC_API_KEY`.
//!
//! Task #1160 (2026-08-23) — the user's mnml API key kept accruing
//! metered charges after ghost-text + `http.ai_build` migrated to the
//! `claude -p` sub CLI. Rather than delete the key or grep the
//! codebase again each surprise-charge cycle, every remaining
//! `std::env::var("ANTHROPIC_API_KEY")` read now routes through
//! [`observe`], which appends one JSONL line per read to
//! `<data_root>/api-canary.jsonl` naming the callsite. When a new
//! charge appears, `tail -20 ~/.config/mnml/api-canary.jsonl` names
//! the path that fired.
//!
//! The key stays functional — this is telemetry, not a gate.
//!
//! Log lines:
//!   {"ts":"2026-08-23T17:12:03Z","callsite":"anthropic_api::detect_backend","pid":12345,"thread":"cloud-agent-worker"}
//!
//! `observe` never panics on I/O errors — a canary that crashes on a
//! read-only filesystem would be worse than one that misses a write.

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

const ENV_KEY: &str = "ANTHROPIC_API_KEY";

/// Read `$ANTHROPIC_API_KEY` and log the hit to the canary jsonl.
/// Returns the same `Result` shape callers previously got from
/// `std::env::var(ENV_KEY)`. Wrap every remaining direct-API entry
/// point with this so a surprise console charge can be traced back
/// to its callsite.
///
/// `callsite` should be a short, stable identifier like
/// `"api_client::stream_to_channel"` — not a full sentence. This is
/// the string that lands in the log.
pub fn observe(callsite: &'static str) -> Result<String, std::env::VarError> {
    let result = std::env::var(ENV_KEY);
    // Only log successful reads — an unset env var is not a canary
    // hit, it's the expected steady state.
    if result.is_ok() {
        record_hit(callsite);
    }
    result
}

/// Path the canary log is written to. Callers reading the log
/// (`:api.canary`, tests, users curious about recent hits) go through
/// here so the location stays a single source of truth.
pub fn log_path() -> PathBuf {
    crate::data_root::data_root().join("api-canary.jsonl")
}

fn record_hit(callsite: &'static str) {
    let path = log_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{}\",\"callsite\":\"{}\",\"pid\":{},\"thread\":\"{}\",\"seq\":{}}}\n",
        rfc3339_now(),
        callsite,
        std::process::id(),
        thread_name(),
        next_seq(),
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn rfc3339_now() -> String {
    let now = std::time::SystemTime::now();
    let secs = now
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Compact civil-time renderer — chrono is already a dep but
    // pulling it in for one format string keeps this file self-
    // contained. The output matches RFC3339's UTC form.
    let (year, month, day, hh, mm, ss) = civil_from_unix(secs);
    format!("{year:04}-{month:02}-{day:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

fn thread_name() -> String {
    std::thread::current()
        .name()
        .unwrap_or("<unnamed>")
        .to_string()
}

static SEQ: AtomicU64 = AtomicU64::new(0);

fn next_seq() -> u64 {
    SEQ.fetch_add(1, Ordering::Relaxed)
}

// Same civil-from-epoch conversion mnml uses elsewhere (see
// http/session ts formatting) — Howard Hinnant's date algorithm.
fn civil_from_unix(secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let days = (secs / 86_400) as i64;
    let rem = (secs % 86_400) as u32;
    let hh = rem / 3600;
    let mm = (rem % 3600) / 60;
    let ss = rem % 60;
    // days since 1970-01-01 → civil date (Hinnant).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = (y + if m <= 2 { 1 } else { 0 }) as u32;
    (year, m, d, hh, mm, ss)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observe_returns_env_result_unchanged_when_unset() {
        // The canary must be transparent — a missing key still yields
        // Err so callers show the same "$ANTHROPIC_API_KEY not set"
        // message they always did.
        // SAFETY: single-threaded test; we save/restore.
        let saved = std::env::var(ENV_KEY).ok();
        // SAFETY: single-threaded test.
        unsafe {
            std::env::remove_var(ENV_KEY);
        }
        assert!(observe("test::unset_check").is_err());
        // SAFETY: single-threaded test.
        if let Some(v) = saved {
            unsafe {
                std::env::set_var(ENV_KEY, v);
            }
        }
    }

    #[test]
    fn civil_from_unix_matches_known_dates() {
        // Sanity — 2026-08-23T17:12:03Z.
        // Unix epoch 1_787_505_123 corresponds to that instant.
        let (y, mo, d, hh, mm, ss) = civil_from_unix(1_787_505_123);
        assert_eq!((y, mo, d, hh, mm, ss), (2026, 8, 23, 17, 12, 3));
    }
}
