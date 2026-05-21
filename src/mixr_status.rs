//! mixr now-playing status — the data behind the statusline miniplayer.
//!
//! The sibling `mixr-rs` DJ app writes a flat `key=value` status summary
//! to `~/.mixr/quick.txt` on every render — purpose-built for a cheap
//! external read (vs. the richer `~/.mixr/status.json` it writes
//! alongside). mnml polls `quick.txt` so the statusline can show what
//! mixr is playing without mixr having to know mnml exists — the same
//! decoupled, file-based shape as mnml's own IPC channel.
//!
//! When the file is absent (mixr has never run) the read is a clean
//! `None`; the caller then renders the plain `mixr` launch button.

use std::path::PathBuf;

/// mixr's em-dash "nothing" sentinel — `quick.txt` writes `—` for an
/// empty deck. `parse` normalizes it to an empty string.
const NONE_SENTINEL: &str = "—";

/// A snapshot of mixr's now-playing state, parsed from `quick.txt`.
/// Every field is a display string straight off the wire.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MixrStatus {
    /// `Idle` / `Playing` / … — mixr's top-level state.
    pub state: String,
    /// The track on the playing deck, or empty when nothing's playing.
    pub playing: String,
    /// BPM of the playing track (display string, e.g. `123`), or empty.
    pub playing_bpm: String,
    /// `played/total` time of the playing track (e.g. `1:04/3:38`).
    pub playing_time: String,
    /// The track cued on the other deck, or empty.
    pub incoming: String,
}

impl MixrStatus {
    /// True when a track is actually playing — drives whether the
    /// statusline shows the track or the plain `mixr` launch button.
    pub fn is_playing(&self) -> bool {
        !self.playing.is_empty()
    }
}

/// Parse the flat `key=value` body of `~/.mixr/quick.txt`. Unknown keys
/// are ignored; missing keys stay default (empty); lines without an `=`
/// are skipped. Tolerant by design — mixr may add keys, and a
/// half-written file must never panic.
pub fn parse(text: &str) -> MixrStatus {
    let mut s = MixrStatus::default();
    for line in text.lines() {
        let Some((key, val)) = line.split_once('=') else {
            continue;
        };
        let val = val.trim();
        let val = if val == NONE_SENTINEL { "" } else { val };
        match key.trim() {
            "state" => s.state = val.to_string(),
            "playing" => s.playing = val.to_string(),
            "playing_bpm" => s.playing_bpm = val.to_string(),
            "playing_time" => s.playing_time = val.to_string(),
            "incoming" => s.incoming = val.to_string(),
            _ => {}
        }
    }
    s
}

/// Path to mixr's quick-status file (`~/.mixr/quick.txt`).
pub fn quick_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".mixr").join("quick.txt"))
}

/// Read + parse mixr's current status. `None` when `$HOME` is unset or
/// the file doesn't exist (mixr has never run) — the caller renders the
/// plain `mixr` launch button in that case.
pub fn read() -> Option<MixrStatus> {
    let text = std::fs::read_to_string(quick_path()?).ok()?;
    Some(parse(&text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_an_idle_quick_txt() {
        // The exact shape mixr writes when nothing is loaded.
        let txt = "view=browse\nstate=Idle\nplaying=—\nplaying_bpm=—\n\
                   playing_time=0/0\nincoming=—\nqueue=0\n";
        let s = parse(txt);
        assert_eq!(s.state, "Idle");
        // The em-dash sentinel normalizes to empty.
        assert_eq!(s.playing, "");
        assert_eq!(s.incoming, "");
        assert!(!s.is_playing());
    }

    #[test]
    fn parses_a_playing_track() {
        let txt = "state=Playing\nplaying=Daft Punk - Aerodynamic\n\
                   playing_bpm=123\nplaying_time=1:04/3:38\n\
                   incoming=Justice - Genesis\n";
        let s = parse(txt);
        assert_eq!(s.state, "Playing");
        assert_eq!(s.playing, "Daft Punk - Aerodynamic");
        assert_eq!(s.playing_bpm, "123");
        assert_eq!(s.playing_time, "1:04/3:38");
        assert_eq!(s.incoming, "Justice - Genesis");
        assert!(s.is_playing());
    }

    #[test]
    fn parsing_is_tolerant_of_junk() {
        // Blank lines, unknown keys, and a line with no `=` are all
        // skipped without panic; a value containing `=` keeps
        // everything after the first separator.
        let s = parse("\nunknown=whatever\ngarbage line\nplaying=A=B=C\n");
        assert_eq!(s.playing, "A=B=C");
        assert_eq!(s.state, "");
    }

    #[test]
    fn empty_input_is_all_default() {
        assert_eq!(parse(""), MixrStatus::default());
    }
}
