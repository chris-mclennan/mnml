//! Timestamped-backup helper for programmatic TOML rewrites.
//!
//! Every write site that mutates a user-facing TOML on disk
//! (mnml config, integration manifests, glyph assignments,
//! integration settings, custom theme) goes through
//! [`write_toml_with_backup`] so a bad write leaves a
//! recoverable copy behind. User rule (2026-08-18): "all
//! programmatic toml edits need the backups".
//!
//! Backup filename: `<original>.pre-<reason>-<UTC-YYYYMMDD-HHMMSS>`
//! placed alongside the file. Retention is capped per (path,
//! reason) at [`MAX_BACKUPS_PER_REASON`] most-recent; older
//! ones are unlinked after every successful write.

use std::io;
use std::path::{Path, PathBuf};

/// How many timestamped backups to keep per (file, reason). Older
/// ones get unlinked after every write. 10 is roughly two weeks of
/// aggressive UI-driven fiddling at one edit/day/reason; enough to
/// walk back a botched Configure-pane session without ballooning
/// the config directory.
pub(crate) const MAX_BACKUPS_PER_REASON: usize = 10;

/// Copy `path` to a timestamped backup (if it exists), then write
/// `contents` to `path`. Prunes older backups for the same
/// `(path, reason)` past [`MAX_BACKUPS_PER_REASON`].
///
/// - `path`: destination file to (over)write.
/// - `contents`: the new TOML string.
/// - `reason`: short kebab-case tag identifying the writer — one of
///   `"config"`, `"manifest"`, `"assignments"`, `"settings"`,
///   `"theme"`. Prunes only match backups tagged with the same
///   reason, so unrelated call sites never delete each other's
///   safety net.
///
/// Ordering: backup FIRST, then write. If the backup step fails
/// we still write (a stale backup blocking a legitimate write
/// would be worse than a missing backup); the io::Error is
/// suppressed to a debug-eprintln.
pub(crate) fn write_toml_with_backup(path: &Path, contents: &str, reason: &str) -> io::Result<()> {
    if path.exists() {
        if let Err(e) = make_backup(path, reason) {
            eprintln!("mnml: TOML backup for {} failed: {e}", path.display());
        }
        prune_backups(path, reason, MAX_BACKUPS_PER_REASON);
    }
    std::fs::write(path, contents)
}

fn make_backup(path: &Path, reason: &str) -> io::Result<PathBuf> {
    let backup = backup_path(path, reason);
    std::fs::copy(path, &backup)?;
    Ok(backup)
}

fn backup_path(path: &Path, reason: &str) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown");
    path.with_file_name(format!("{name}.pre-{reason}-{}", utc_stamp()))
}

/// Delete backups for `(path, reason)` past the `keep` most-recent.
/// Backups sort chronologically by the UTC stamp in their filename
/// (the format was chosen for exactly this).
fn prune_backups(path: &Path, reason: &str, keep: usize) {
    let Some(dir) = path.parent() else {
        return;
    };
    let Some(base_name) = path.file_name().and_then(|s| s.to_str()) else {
        return;
    };
    let prefix = format!("{base_name}.pre-{reason}-");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut candidates: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|s| s.to_str())
                .map(|s| s.starts_with(&prefix))
                .unwrap_or(false)
        })
        .collect();
    if candidates.len() <= keep {
        return;
    }
    // Sort by filename — lex order matches chronological because the
    // stamp is fixed-width YYYYMMDD-HHMMSS.
    candidates.sort();
    let excess = candidates.len() - keep;
    for old in &candidates[..excess] {
        let _ = std::fs::remove_file(old);
    }
}

/// `YYYYMMDD-HHMMSS` UTC — same shape reset.rs uses for its whole-
/// config backups so they interleave cleanly on `ls`.
pub(crate) fn utc_stamp() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (yr, mo, day, hr, mn, sc) = unix_to_ymdhms(now as i64);
    format!("{yr:04}{mo:02}{day:02}-{hr:02}{mn:02}{sc:02}")
}

fn unix_to_ymdhms(mut ts: i64) -> (i32, u32, u32, u32, u32, u32) {
    if ts < 0 {
        ts = 0;
    }
    let sc = (ts % 60) as u32;
    ts /= 60;
    let mn = (ts % 60) as u32;
    ts /= 60;
    let hr = (ts % 24) as u32;
    let mut days = ts / 24;
    let mut yr: i32 = 1970;
    loop {
        let leap = is_leap(yr);
        let year_days = if leap { 366 } else { 365 };
        if days < year_days {
            break;
        }
        days -= year_days;
        yr += 1;
    }
    let month_lengths: [u32; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut mo: u32 = 1;
    for (i, &len) in month_lengths.iter().enumerate() {
        let feb_bonus = if i == 1 && is_leap(yr) { 1 } else { 0 };
        let this_month = (len + feb_bonus) as i64;
        if days < this_month {
            mo = (i + 1) as u32;
            break;
        }
        days -= this_month;
    }
    let day = (days + 1) as u32;
    (yr, mo, day, hr, mn, sc)
}

fn is_leap(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn writes_new_file_without_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        write_toml_with_backup(&path, "a = 1\n", "config").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "a = 1\n");
        // No `.pre-` files yet — nothing to back up.
        let siblings: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .map(|s| s.contains(".pre-"))
                    .unwrap_or(false)
            })
            .collect();
        assert!(siblings.is_empty());
    }

    #[test]
    fn overwrites_leave_a_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, "a = 1\n").unwrap();
        write_toml_with_backup(&path, "a = 2\n", "config").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "a = 2\n");
        let backups: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .map(|s| s.contains(".pre-config-"))
                    .unwrap_or(false)
            })
            .collect();
        assert_eq!(backups.len(), 1);
        // Backup content matches the old bytes.
        assert_eq!(fs::read_to_string(backups[0].path()).unwrap(), "a = 1\n");
    }

    #[test]
    fn stamp_shape_is_15_chars() {
        let s = utc_stamp();
        assert_eq!(s.len(), 15, "YYYYMMDD-HHMMSS: {s}");
        assert_eq!(&s[8..9], "-");
    }

    #[test]
    fn prunes_past_max_keeping_newest() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.toml");
        fs::write(&path, "seed").unwrap();
        // Seed with (MAX + 3) fake backups whose UTC stamps sort
        // in a known order. Insert names manually so we don't need
        // to sleep 1s between real writes.
        for i in 0..(MAX_BACKUPS_PER_REASON + 3) {
            let name = format!("t.toml.pre-config-2026081{i:02}-000000");
            fs::write(dir.path().join(name), format!("v{i}")).unwrap();
        }
        prune_backups(&path, "config", MAX_BACKUPS_PER_REASON);
        let remaining: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .map(|s| s.starts_with("t.toml.pre-config-"))
                    .unwrap_or(false)
            })
            .collect();
        assert_eq!(remaining.len(), MAX_BACKUPS_PER_REASON);
        // The 3 oldest (v0, v1, v2 — lowest stamps) should be gone.
        for name in remaining.iter().map(|e| e.file_name()) {
            let s = name.to_string_lossy().to_string();
            assert!(
                !s.contains("2026081000") && !s.contains("2026081100") && !s.contains("2026081200"),
                "kept an over-old backup: {s}"
            );
        }
    }

    #[test]
    fn different_reasons_dont_prune_each_other() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.toml");
        fs::write(&path, "seed").unwrap();
        // 15 config backups + 1 manifest backup — the pruner
        // caps config at MAX; manifest untouched.
        for i in 0..15 {
            let name = format!("t.toml.pre-config-2026081{i:02}-000000");
            fs::write(dir.path().join(name), "x").unwrap();
        }
        fs::write(dir.path().join("t.toml.pre-manifest-20260810-000000"), "m").unwrap();
        prune_backups(&path, "config", MAX_BACKUPS_PER_REASON);
        let manifest_still_there = dir
            .path()
            .join("t.toml.pre-manifest-20260810-000000")
            .exists();
        assert!(manifest_still_there);
    }
}
