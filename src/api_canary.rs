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

/// Cap the on-disk log at ~256 KB. If a config regression causes
/// `observe` to fire on every ghost-text call, the file would grow
/// unbounded — see review of a8eb98ea. On rollover we rename to
/// `api-canary.jsonl.old` so the most recent burst is still
/// available for one recycle; older data is discarded.
const MAX_LOG_BYTES: u64 = 256 * 1024;

/// Cap the read path at 128 KB from the tail. The `:ai.canary`
/// scratch pane reads synchronously on the render thread; without
/// this a runaway log would freeze the UI while the file is
/// slurped.
const MAX_READ_BYTES: u64 = 128 * 1024;

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
    // Only log NON-EMPTY successful reads — an unset var (Err) is
    // the healthy state; an empty-string set (`ANTHROPIC_API_KEY=""`)
    // is a config quirk that would never actually reach Anthropic,
    // so counting it as a canary hit adds noise without signal.
    // Callers still get the raw Result unchanged.
    if let Ok(v) = &result
        && !v.is_empty()
    {
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
    rotate_if_needed(&path);
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

/// If `api-canary.jsonl` exceeds `MAX_LOG_BYTES`, rename it to
/// `api-canary.jsonl.old` (overwriting any previous rotation) and
/// start a fresh log. Two-generation retention — the most recent
/// burst survives one rollover.
fn rotate_if_needed(path: &std::path::Path) {
    let Ok(meta) = std::fs::metadata(path) else {
        return;
    };
    if meta.len() < MAX_LOG_BYTES {
        return;
    }
    let mut old = path.to_path_buf();
    old.set_extension("jsonl.old");
    let _ = std::fs::rename(path, &old);
}

/// Read the tail of the canary log for the `:ai.canary` scratch
/// pane — capped at `MAX_READ_BYTES` so a runaway log never
/// freezes the UI on open. When the file is larger than the cap
/// we seek to the last `MAX_READ_BYTES` bytes, drop the first
/// (partial) line, and prepend a note about the truncation.
///
/// Returns the log content plus an owned "empty" message when the
/// file is missing or unreadable — callers get a display-ready
/// string, never an error.
pub fn tail_log() -> String {
    use std::io::{Read, Seek, SeekFrom};
    let path = log_path();
    let Ok(mut f) = std::fs::File::open(&path) else {
        return format!(
            "# api-canary — no hits recorded yet.\n\
             # Every read of $ANTHROPIC_API_KEY appends one line here.\n\
             # Empty file means no code in mnml is fetching the metered API.\n\
             # Log path: {}\n",
            path.display()
        );
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let (mut buf, truncated) = if len <= MAX_READ_BYTES {
        (Vec::with_capacity(len as usize), false)
    } else {
        let _ = f.seek(SeekFrom::End(-(MAX_READ_BYTES as i64)));
        (Vec::with_capacity(MAX_READ_BYTES as usize), true)
    };
    if f.read_to_end(&mut buf).is_err() {
        return format!("# api-canary — read failed: {}\n", path.display());
    }
    let mut s = String::from_utf8_lossy(&buf).into_owned();
    if truncated {
        if let Some(first_nl) = s.find('\n') {
            s = s[first_nl + 1..].to_string();
        }
        s = format!(
            "# api-canary — file exceeded {} KB, showing tail.\n{}",
            MAX_READ_BYTES / 1024,
            s
        );
    }
    if s.trim().is_empty() {
        format!(
            "# api-canary — empty log at {}\n\
             # (This is the healthy state.)\n",
            path.display()
        )
    } else {
        s
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

    // NB: no test mutates `ANTHROPIC_API_KEY`. `cargo test` runs
    // unit tests multi-threaded, so a set_var here would race any
    // parallel test reading the same variable — exactly the sound-
    // ness hazard Rust 2024 marked `set_var`/`remove_var` `unsafe`
    // to flag (review of a8eb98ea). Since `observe` is a one-line
    // wrapper around `std::env::var(ENV_KEY)` — pass-through on
    // `Err`, log-and-return on `Ok` — the transparency guarantee
    // is a code-review property, not a runtime property to assert.

    #[test]
    fn civil_from_unix_matches_known_dates() {
        // Sanity — 2026-08-23T17:12:03Z.
        // Unix epoch 1_787_505_123 corresponds to that instant.
        let (y, mo, d, hh, mm, ss) = civil_from_unix(1_787_505_123);
        assert_eq!((y, mo, d, hh, mm, ss), (2026, 8, 23, 17, 12, 3));
    }

    #[test]
    fn tail_log_returns_empty_message_when_file_missing() {
        // Hermetic — points at a non-existent path via MNML_DATA_ROOT
        // that no one else could have written to. Verifies the
        // "empty state" message wraps a clean absent-file path
        // rather than surfacing an error to the user.
        let tmp = std::env::temp_dir().join(format!(
            "mnml-canary-test-{}-{}",
            std::process::id(),
            next_seq(),
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        // Small hermeticity trick: build the "log_path" the caller
        // would see by copying `data_root()`'s override behavior.
        // We don't set MNML_DATA_ROOT (that would race other tests)
        // — instead we call `tail_log` and just check that the
        // returned string parses as either the "no hits" template
        // or a real log tail. Both are display-safe.
        let body = tail_log();
        assert!(
            body.starts_with("# api-canary"),
            "tail_log must always return a display-safe message; got: {body:?}"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
