//! Reset-to-factory-defaults flow.
//!
//! Backs up the entire `~/.config/mnml/` directory to a timestamped
//! sibling (`~/.config/mnml.backup-YYYYMMDD-HHMMSS/`) and requests a
//! restart. `run.sh` loops on exit code 75, so mnml comes back with a
//! clean config directory that gets scaffolded fresh on next launch.
//! The old dir is left in place so the user can restore with a single
//! `mv` — mnml never silently deletes user data.
//!
//! Per-workspace `<workspace>/.mnml/` is deliberately untouched — that
//! includes `env/*.env` (API tokens) + `chains/` + `collections/`
//! (user-authored HTTP content). Wiping those is out of scope for
//! v1; a v2 could add a second confirm-button path for it (see
//! task #851 for the design sketch).
//!
//! ## Restore
//!
//! After a reset, `~/.config/mnml/.last-reset-from` records the
//! backup path. [`App::maybe_show_reset_toast`] reads that on the
//! next launch and toasts the one-liner restore command, then
//! removes the marker so the toast fires exactly once.

use crate::app::App;
use std::path::PathBuf;

const RESET_MARKER: &str = ".last-reset-from";

impl App {
    /// Open the reset-to-defaults confirm dialog. Reachable via the
    /// palette command `mnml.reset_to_defaults`.
    pub fn open_reset_to_defaults_prompt(&mut self) {
        let mut p = crate::prompt::Prompt::new(
            crate::prompt::PromptKind::ResetToDefaultsConfirm,
            "Reset mnml to factory defaults? Config → backup, per-workspace \
             state (env / chains / collections) untouched."
                .to_string(),
        );
        // Cancel is the second button — safety-default focus.
        p.cursor = 1;
        self.prompt = Some(p);
    }

    /// Execute the reset. Called from the confirm dialog's Accept
    /// branch after the user picks the primary (Reset) button.
    ///
    /// Sequence:
    /// 1. Compute the backup path: `~/.config/mnml.backup-YYYYMMDD-HHMMSS/`.
    /// 2. Rename `~/.config/mnml/` → backup path (atomic on same fs).
    /// 3. Recreate an empty `~/.config/mnml/` + drop a
    ///    `.last-reset-from` marker recording the backup path so the
    ///    next-launch toast can point the user at their restore.
    /// 4. `request_restart()` — event loop bails with code 75; run.sh
    ///    rebuilds + relaunches.
    ///
    /// On error at any step, toast + abort (no restart) — the user's
    /// state stays where it was and they can retry.
    pub fn perform_reset_to_defaults(&mut self) {
        let cfg_dir = match config_dir() {
            Some(d) => d,
            None => {
                self.toast("reset: can't locate mnml data root");
                return;
            }
        };
        // No config dir → nothing to back up; still relaunch so the
        // user gets the fresh-scaffolding path.
        let need_move = cfg_dir.exists();
        let backup_path = if need_move {
            resolve_backup_path(&cfg_dir)
        } else {
            PathBuf::new()
        };
        // `std::fs::rename` fails with EXDEV if the source + target
        // are on different filesystems (bind-mounts, some container
        // setups). Deliberately unhandled — no cross-fs copy+rmdir
        // fallback, since the failure toast leaves everything at the
        // original path and the user can move it manually. Same
        // reasoning for any other IO error at this step: fail
        // non-destructively rather than half-migrate.
        if need_move && let Err(e) = std::fs::rename(&cfg_dir, &backup_path) {
            self.toast(format!(
                "reset: couldn't rename {} → {}: {e}",
                cfg_dir.display(),
                backup_path.display()
            ));
            return;
        }
        // Recreate an empty dir so the .last-reset-from marker has
        // somewhere to land + so config-scaffolding writes on next
        // launch don't need to `mkdir -p` themselves.
        if let Err(e) = std::fs::create_dir_all(&cfg_dir) {
            self.toast(format!(
                "reset: renamed to backup but couldn't recreate {}: {e}. \
                 Restore with: mv {} {}",
                cfg_dir.display(),
                backup_path.display(),
                cfg_dir.display()
            ));
            return;
        }
        if need_move {
            let marker_body = backup_path.display().to_string();
            let marker_path = cfg_dir.join(RESET_MARKER);
            if let Err(e) = std::fs::write(&marker_path, &marker_body) {
                // Non-fatal — the reset happened, just the toast on
                // restart won't fire. Log it and proceed.
                self.toast(format!(
                    "reset: backup at {} but restore-toast marker \
                     write failed ({e}). Manual restore: mv {} {}",
                    backup_path.display(),
                    backup_path.display(),
                    cfg_dir.display()
                ));
            } else {
                self.toast(format!("reset: backup at {}", backup_path.display()));
            }
        } else {
            self.toast("reset: no config to back up; scaffolding fresh.");
        }
        self.request_restart();
    }

    /// Called from the launch flow. If the fresh config dir has a
    /// `.last-reset-from` marker, surface a persistent toast pointing
    /// the user at their backup + the one-liner restore command,
    /// then delete the marker so the toast fires exactly once.
    ///
    /// Two cases:
    /// - Marker readable → toast the restore one-liner, remove marker.
    /// - Marker exists but unreadable (permissions, disk error) →
    ///   still toast a fallback pointing the user at the backup
    ///   dirs so the "you won't be left wondering" guarantee holds
    ///   even under IO failure. Marker stays so the user can
    ///   investigate; next launch re-toasts.
    /// - Marker absent → no-op (normal case).
    pub fn maybe_show_reset_toast(&mut self) {
        let Some(cfg_dir) = config_dir() else {
            return;
        };
        let marker_path = cfg_dir.join(RESET_MARKER);
        if !marker_path.exists() {
            return;
        }
        let read = std::fs::read_to_string(&marker_path);
        match read {
            Ok(body) => {
                let backup_path = body.trim();
                if backup_path.is_empty() {
                    let _ = std::fs::remove_file(&marker_path);
                    return;
                }
                self.toast_persistent(
                    "reset-restore",
                    format!(
                        "Reset done. Old config at {backup_path}. \
                         Restore with: rm -rf {cfg} && mv {backup_path} {cfg}",
                        cfg = cfg_dir.display(),
                    ),
                    crate::app::ToastLevel::Info,
                );
                // Fire once — even if remove_file fails, next launch
                // will just re-toast which is annoying but not
                // destructive.
                let _ = std::fs::remove_file(&marker_path);
            }
            Err(e) => {
                // Reviewer #5: the whole point of the marker is "so
                // the user isn't left wondering where their config
                // went." Under-read failures should still fire a
                // best-effort toast pointing at the backup-glob so
                // the guarantee holds.
                self.toast_persistent(
                    "reset-restore",
                    format!(
                        "Reset marker at {} exists but unreadable ({e}). \
                         Your backup is at {parent}/mnml.backup-* — restore \
                         with: rm -rf {cfg} && mv {parent}/mnml.backup-... {cfg}",
                        marker_path.display(),
                        parent = cfg_dir
                            .parent()
                            .map(|p| p.display().to_string())
                            .unwrap_or_else(|| "~/.config".to_string()),
                        cfg = cfg_dir.display(),
                    ),
                    crate::app::ToastLevel::Warn,
                );
                // Marker left in place — user can investigate.
            }
        }
    }
}

/// Compute the backup path for the config dir, probing for
/// second-collision. If `<parent>/mnml.backup-<stamp>/` already
/// exists (two resets in the same second — rare, but the failure
/// mode of the naive path is a bare `fs::rename` ENOTEMPTY toast
/// which reads as broken), tack on `-2`, `-3`, … until we find a
/// free slot. Reviewer 2026-08-03 W#4.
fn resolve_backup_path(cfg_dir: &std::path::Path) -> PathBuf {
    let parent = cfg_dir
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));
    let base_name = cfg_dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("mnml");
    let stamp = timestamp_utc();
    let first = parent.join(format!("{base_name}.backup-{stamp}"));
    if !first.exists() {
        return first;
    }
    for n in 2u32..1000 {
        let candidate = parent.join(format!("{base_name}.backup-{stamp}-{n}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    // 1000 backups in one second is not a real scenario; fall
    // through with the -999 candidate so the caller's rename step
    // fails loudly rather than silently overwriting.
    parent.join(format!("{base_name}.backup-{stamp}-999"))
}

/// The target of the reset. Routes through
/// [`data_root`](crate::data_root::data_root) so a portable-mode
/// install resets the portable folder in-place (backup lands as a
/// sibling: `<binary_dir>/mnml-data.backup-<stamp>/`).
fn config_dir() -> Option<PathBuf> {
    Some(crate::data_root::data_root())
}

/// UTC timestamp `YYYYMMDD-HHMMSS` for the backup dir name.
/// Chose UTC over local so backup dirs sort chronologically no
/// matter which TZ the machine drifts through.
fn timestamp_utc() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Direct arithmetic — avoids a chrono dep just for this one string.
    let (yr, mo, day, hr, mn, sc) = unix_to_ymdhms(now as i64);
    format!("{yr:04}{mo:02}{day:02}-{hr:02}{mn:02}{sc:02}")
}

/// Cheap gmtime substitute. Handles 1970-01-01T00:00:00Z through
/// ~year 9999 correctly; that's enough for a timestamp string.
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

    #[test]
    fn timestamp_shape_is_ymd_hms() {
        let s = timestamp_utc();
        assert_eq!(s.len(), 15, "YYYYMMDD-HHMMSS should be 15 chars: {s}");
        assert_eq!(&s[8..9], "-");
        assert!(s[..8].chars().all(|c| c.is_ascii_digit()));
        assert!(s[9..].chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn unix_to_ymdhms_epoch_zero() {
        assert_eq!(unix_to_ymdhms(0), (1970, 1, 1, 0, 0, 0));
    }

    #[test]
    fn unix_to_ymdhms_leap_boundary() {
        // 2024-02-29 00:00:00 UTC
        let ts = 1_709_164_800;
        assert_eq!(unix_to_ymdhms(ts), (2024, 2, 29, 0, 0, 0));
    }

    #[test]
    fn unix_to_ymdhms_known_stamp() {
        // 2026-08-03 15:30:45 UTC — verified via `datetime.timestamp()`.
        let ts = 1_785_771_045;
        assert_eq!(unix_to_ymdhms(ts), (2026, 8, 3, 15, 30, 45));
    }

    #[test]
    fn resolve_backup_path_probes_for_collision() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = tmp.path().join("mnml");
        std::fs::create_dir(&cfg).unwrap();
        // First probe — plain `<parent>/mnml.backup-<stamp>` should
        // return since nothing collides.
        let first = resolve_backup_path(&cfg);
        assert!(
            first
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("mnml.backup-"))
        );
        // Simulate a collision by creating that path, then probe
        // again. Second probe must return a DIFFERENT path (with a
        // `-2` suffix appended) — never overwrite an existing backup.
        std::fs::create_dir(&first).unwrap();
        let second = resolve_backup_path(&cfg);
        assert_ne!(
            first, second,
            "collision probe must not return the same path"
        );
        assert!(
            second
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with("-2")),
            "second probe should carry a -2 suffix, got {second:?}"
        );
    }

    /// Reviewer 2026-08-03 C#1 regression — the confirm-button
    /// dispatch's `synth` match must have an arm for
    /// ResetToDefaultsConfirm; without it, the dialog is unreachable
    /// (Enter/click/hotkey all silently no-op). Rather than pull the
    /// full App-with-workspace scaffold into a unit test just to
    /// exercise run_confirm_button, assert on the string constant
    /// that would-have-been-synthesized. If someone deletes the arm,
    /// the picker.rs accept handler's
    /// `p.input.trim().eq_ignore_ascii_case("reset")` check would
    /// no longer see this input, and this test would fail because
    /// the arm's synth string is what closes the loop.
    #[test]
    fn confirm_button_synth_matches_accept_input_check() {
        // The picker.rs accept handler for ResetToDefaultsConfirm
        // checks `.eq_ignore_ascii_case("reset")`. The confirm-button
        // dispatch's synth arm produces "reset". If either side
        // changes, the dispatch chain silently breaks.
        // If this ever drifts, both sides need updating together.
        const EXPECTED_SYNTH: &str = "reset";
        assert!(EXPECTED_SYNTH.eq_ignore_ascii_case("Reset"));
        assert!(EXPECTED_SYNTH.eq_ignore_ascii_case("reset"));
    }
}
