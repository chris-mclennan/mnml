//! Tiny wall-clock formatters shared by the Claude + Codex usage
//! panes. Extracted from the pre-split `ai_usage_view.rs` when
//! `Pane::AiUsage` fissioned into `Pane::ClaudeUsage` +
//! `Pane::CodexUsage` on 2026-08-16 — both panes want the same
//! `6:50pm` / `Aug 10 at 2am` rendering for reset timestamps.

/// `6:50pm` shape — for session resets (same day).
pub fn format_short_time(unix_secs: u64) -> String {
    let (h, m) = split_hm(unix_secs);
    let (h12, ampm) = if h == 0 {
        (12, "am")
    } else if h < 12 {
        (h, "am")
    } else if h == 12 {
        (12, "pm")
    } else {
        (h - 12, "pm")
    };
    if m == 0 {
        format!("{h12}{ampm}")
    } else {
        format!("{h12}:{m:02}{ampm}")
    }
}

/// `Aug 10 at 2am` shape — for weekly resets (different day).
pub fn format_long_time(unix_secs: u64) -> String {
    let (h, m) = split_hm(unix_secs);
    let (_y, mo, d) = split_ymd(unix_secs);
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let month = months
        .get((mo as usize).saturating_sub(1))
        .copied()
        .unwrap_or("?");
    let (h12, ampm) = if h == 0 {
        (12, "am")
    } else if h < 12 {
        (h, "am")
    } else if h == 12 {
        (12, "pm")
    } else {
        (h - 12, "pm")
    };
    let time = if m == 0 {
        format!("{h12}{ampm}")
    } else {
        format!("{h12}:{m:02}{ampm}")
    };
    format!("{month} {d} at {time}")
}

/// Approximate local hour/minute from unix seconds using $TZ (or 0
/// if not set). Good enough for a reset-time label.
fn split_hm(unix_secs: u64) -> (u64, u64) {
    let offset = local_tz_offset_secs();
    let local = (unix_secs as i64 + offset).max(0) as u64;
    let total_mins = (local / 60) % (24 * 60);
    (total_mins / 60, total_mins % 60)
}

fn split_ymd(unix_secs: u64) -> (i32, u32, u32) {
    let offset = local_tz_offset_secs();
    let local = (unix_secs as i64 + offset).max(0) as u64;
    let days = (local / 86400) as i64;
    day_to_ymd(days)
}

fn day_to_ymd(days: i64) -> (i32, u32, u32) {
    let mut d = days + 719_162;
    let mut y: i32 = 400 * (d as i32 / 146_097);
    d %= 146_097;
    if d == 146_096 {
        y += 400;
        d = 0;
    }
    let (mut yi, mut di) = (y as i64, d);
    let c = (di / 36524).min(3);
    di -= c * 36524;
    yi += c * 100;
    let f = di / 1461;
    di -= f * 1461;
    yi += f * 4;
    let g = (di / 365).min(3);
    di -= g * 365;
    yi += g;
    let leap = (yi % 4 == 0) && (yi % 100 != 0 || yi % 400 == 0);
    let dpm = if leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m: u32 = 1;
    let mut rem = di as u32;
    for &v in dpm.iter() {
        if rem < v {
            break;
        }
        rem -= v;
        m += 1;
    }
    (yi as i32, m, rem + 1)
}

fn local_tz_offset_secs() -> i64 {
    use std::sync::OnceLock;
    static CACHE: OnceLock<i64> = OnceLock::new();
    *CACHE.get_or_init(|| {
        let Ok(out) = std::process::Command::new("date").arg("+%z").output() else {
            return 0;
        };
        let s = String::from_utf8_lossy(&out.stdout);
        let s = s.trim();
        if s.len() != 5 {
            return 0;
        }
        let sign: i64 = if s.starts_with('-') { -1 } else { 1 };
        let Ok(hh) = s[1..3].parse::<i64>() else {
            return 0;
        };
        let Ok(mm) = s[3..5].parse::<i64>() else {
            return 0;
        };
        sign * (hh * 3600 + mm * 60)
    })
}
