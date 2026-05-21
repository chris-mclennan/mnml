//! mixr now-playing source.
//!
//! The sibling `mixr-rs` DJ app writes a flat `key=value` status
//! summary to `~/.mixr/quick.txt` on every render — purpose-built for
//! a cheap external read (alongside the richer `status.json`). An
//! absent file ⇒ `None` (mixr has never run).

use super::NowPlaying;
use std::path::PathBuf;

/// mixr's em-dash "nothing" sentinel — `quick.txt` writes `—` for an
/// empty deck; [`project`] normalizes it to an empty string.
const NONE_SENTINEL: &str = "—";

/// Path to mixr's quick-status file (`~/.mixr/quick.txt`).
fn quick_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".mixr").join("quick.txt"))
}

/// Read + project mixr's current state into a [`NowPlaying`]. `None`
/// when `$HOME` is unset or the file is absent.
pub fn poll() -> Option<NowPlaying> {
    let text = std::fs::read_to_string(quick_path()?).ok()?;
    Some(project(&text))
}

/// Project the flat `key=value` body of `quick.txt` into a
/// [`NowPlaying`]. Tolerant — unknown keys ignored, the `—` sentinel
/// normalized to empty, never panics on a half-written file.
/// Separated from [`poll`] so it's unit-testable without the
/// filesystem.
pub fn project(text: &str) -> NowPlaying {
    let (mut track, mut bpm) = (String::new(), String::new());
    for line in text.lines() {
        let Some((key, val)) = line.split_once('=') else {
            continue;
        };
        let val = val.trim();
        let val = if val == NONE_SENTINEL { "" } else { val };
        match key.trim() {
            "playing" => track = val.to_string(),
            "playing_bpm" => bpm = val.to_string(),
            _ => {}
        }
    }
    NowPlaying {
        source: "mixr".to_string(),
        playing: !track.is_empty(),
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
        let txt = "state=Playing\nplaying=Daft Punk - Aerodynamic\n\
                   playing_bpm=123\nplaying_time=1:04/3:38\n";
        let n = project(txt);
        assert!(n.playing);
        assert_eq!(n.track, "Daft Punk - Aerodynamic");
        assert_eq!(n.detail, "123"); // bpm rides in `detail`
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
}
