//! mixr now-playing source.
//!
//! The sibling `mixr-rs` DJ app writes a flat `key=value` status
//! summary to `~/.mixr/quick.txt` on every render — purpose-built for
//! a cheap external read (alongside the richer `status.json`). An
//! absent file ⇒ `None` (mixr has never run); a *stale* file ⇒ `None`
//! too (mixr exited and left the file behind — see [`STALE_AFTER`]).

use super::NowPlaying;
use std::path::PathBuf;
use std::time::Duration;

/// mixr's em-dash "nothing" sentinel — `quick.txt` writes `—` for an
/// empty deck; [`project`] normalizes it to an empty string.
const NONE_SENTINEL: &str = "—";

/// How long after `quick.txt`'s last write we treat it as stale. mixr
/// rewrites the file on every render — many times a second — for as
/// long as it's alive, so anything older than this means mixr has
/// exited and the file is a leftover. Without this guard a dead
/// mixr's last track is reported as "now playing" forever, masking
/// every other source (the bug: the chip stuck on an old mixr track
/// while Apple Music was actually playing). mnml SIGKILLs the hosted
/// mixr on close, so mixr can't clear the file itself — freshness is
/// the only reliable signal.
const STALE_AFTER: Duration = Duration::from_secs(10);

/// Path to mixr's quick-status file (`~/.mixr/quick.txt`).
fn quick_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".mixr").join("quick.txt"))
}

/// True iff `path` was modified within `within`. A future mtime (clock
/// skew) counts as fresh; a missing file / unreadable mtime ⇒ not
/// fresh. Used by [`poll`]'s stale-file guard.
fn fresh_within(path: &std::path::Path, within: Duration) -> bool {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .map(|t| t.elapsed().map(|age| age <= within).unwrap_or(true))
        .unwrap_or(false)
}

/// Read + project mixr's current state into a [`NowPlaying`]. `None`
/// when `$HOME` is unset, the file is absent, or the file is stale
/// (older than [`STALE_AFTER`] — mixr is no longer running).
pub fn poll() -> Option<NowPlaying> {
    let path = quick_path()?;
    // Stale-file guard: a dead mixr leaves quick.txt behind with its
    // last track still in it. A missing file / unreadable mtime ⇒ not
    // fresh ⇒ `None`.
    if !fresh_within(&path, STALE_AFTER) {
        return None;
    }
    let text = std::fs::read_to_string(&path).ok()?;
    Some(project(&text))
}

/// Project the flat `key=value` body of `quick.txt` into a
/// [`NowPlaying`]. Tolerant — unknown keys ignored, the `—` sentinel
/// normalized to empty, never panics on a half-written file.
/// Separated from [`poll`] so it's unit-testable without the
/// filesystem.
///
/// `playing` keys off mixr's explicit `playing_active` flag (true only
/// when the deck is actually producing audio, not merely cued). An
/// older mixr that predates the flag has no `playing_active` line — we
/// then fall back to "a track is loaded".
pub fn project(text: &str) -> NowPlaying {
    let (mut track, mut bpm) = (String::new(), String::new());
    let mut active: Option<bool> = None;
    for line in text.lines() {
        let Some((key, val)) = line.split_once('=') else {
            continue;
        };
        let val = val.trim();
        let val = if val == NONE_SENTINEL { "" } else { val };
        match key.trim() {
            "playing" => track = val.to_string(),
            "playing_bpm" => bpm = val.to_string(),
            "playing_active" => active = Some(val.eq_ignore_ascii_case("true")),
            _ => {}
        }
    }
    NowPlaying {
        source: "mixr".to_string(),
        playing: active.unwrap_or(!track.is_empty()),
        track,
        detail: bpm,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_quick_txt_is_not_playing() {
        // The exact shape mixr writes when nothing is loaded.
        let txt = "view=browse\nstate=Idle\nplaying=—\nplaying_bpm=—\n\
                   playing_time=0/0\nincoming=—\n";
        let n = project(txt);
        assert_eq!(n.source, "mixr");
        assert!(!n.playing);
        assert_eq!(n.track, "");
    }

    #[test]
    fn a_playing_track_projects() {
        // Legacy mixr (no `playing_active` line) — falls back to
        // "a track is loaded" ⇒ playing.
        let txt = "state=Playing\nplaying=Daft Punk - Aerodynamic\n\
                   playing_bpm=123\nplaying_time=1:04/3:38\n";
        let n = project(txt);
        assert!(n.playing);
        assert_eq!(n.track, "Daft Punk - Aerodynamic");
        assert_eq!(n.detail, "123"); // bpm rides in `detail`
    }

    #[test]
    fn playing_active_false_means_not_playing() {
        // A track cued on the deck but not actually producing audio —
        // what mixr writes when a deck is loaded but stopped/paused.
        // Must report not-playing so `Source::Auto` falls through to
        // another player (e.g. macOS Music).
        let txt = "state=Playing\nplaying=Prospa - Baby\nplaying_active=false\n\
                   playing_bpm=130\n";
        let n = project(txt);
        assert!(!n.playing);
        assert_eq!(n.track, "Prospa - Baby"); // name still captured
    }

    #[test]
    fn playing_active_true_means_playing() {
        let txt = "state=Playing\nplaying=Prospa - Baby\nplaying_active=true\n";
        let n = project(txt);
        assert!(n.playing);
        assert_eq!(n.track, "Prospa - Baby");
    }

    #[test]
    fn projection_is_tolerant_of_junk() {
        // Blank lines, unknown keys, a line with no `=` — all skipped;
        // a value containing `=` keeps everything after the first.
        let n = project("\nunknown=whatever\ngarbage line\nplaying=A=B=C\n");
        assert_eq!(n.track, "A=B=C");
        assert!(n.playing);
    }

    #[test]
    fn empty_input_is_idle() {
        let n = project("");
        assert!(!n.playing);
        assert_eq!(n.track, "");
        assert_eq!(n.source, "mixr");
    }

    #[test]
    fn fresh_within_tracks_recency_and_absence() {
        // A just-written file is fresh within a generous window…
        let p = std::env::temp_dir().join(format!("mnml-mixr-fresh-{}.txt", std::process::id()));
        std::fs::write(&p, "x").unwrap();
        assert!(fresh_within(&p, Duration::from_secs(60)));
        // …but not within a zero window (it was written in the past).
        assert!(!fresh_within(&p, Duration::from_secs(0)));
        std::fs::remove_file(&p).ok();
        // A missing file is never fresh.
        assert!(!fresh_within(&p, Duration::from_secs(60)));
    }
}
