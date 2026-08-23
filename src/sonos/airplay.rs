//! Native AirPlay, via the one door macOS leaves open: Music.app.
//!
//! There is no public API for choosing a system AirPlay output on
//! macOS 26 — but Music.app's scripting dictionary exposes its own
//! AirPlay device list and lets you *set* the destination. So when the
//! thing making sound is Music.app, mnml can hand it to a Sonos with
//! real AirPlay (no transcoding, no added latency, correct metadata on
//! the speaker) instead of falling back to [`super::stream`].
//!
//! Scope, precisely: this moves **Music.app's** audio only. Spotify,
//! browsers, and mnml's own mixr keep playing wherever the system
//! output points.
//!
//! macOS only.

use std::process::Command;

/// One entry from Music.app's AirPlay device list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub name: String,
    /// Music.app's own classification — `computer` for this Mac,
    /// `AirPlay device` for speakers (a Sonos, a HomePod), `TV` for an
    /// Apple TV or AirPlay-capable television.
    pub kind: String,
    /// True when Music is currently routed here.
    pub selected: bool,
}

impl Target {
    /// True for this Mac's own speakers — the entry to route *back* to.
    pub fn is_this_mac(&self) -> bool {
        self.kind.eq_ignore_ascii_case("computer")
    }
}

/// Escape a device name for embedding in an AppleScript string
/// literal. Room names are user-set, so quotes are entirely possible.
fn applescript_string(s: &str) -> String {
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Run one AppleScript and return stdout, or the script's own error.
fn osascript(script: &str) -> Result<String, String> {
    let out = Command::new("osascript")
        .args(["-e", script])
        .output()
        .map_err(|e| format!("osascript: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(if err.is_empty() {
            "osascript failed".to_string()
        } else {
            err
        });
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim_end().to_string())
}

/// True when Music.app is already running.
///
/// Checked with `pgrep` rather than AppleScript precisely *because*
/// talking to Music.app launches it — and silently opening a music app
/// to answer a status question would be obnoxious.
pub fn music_running() -> bool {
    Command::new("pgrep")
        .args(["-x", "Music"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// List Music.app's AirPlay targets.
///
/// Note: this **launches Music.app** if it isn't running — there's no
/// way to read its device list otherwise. Only call it from an explicit
/// user action, never from a poll loop.
pub fn targets() -> Result<Vec<Target>, String> {
    // One record per line, tab-separated, so names containing commas
    // survive (AppleScript's default list output would not).
    let script = "tell application \"Music\"\n\
set out to \"\"\n\
repeat with d in AirPlay devices\n\
set out to out & (name of d) & tab & (kind of d as text) & tab & (selected of d as text) & linefeed\n\
end repeat\n\
return out\n\
end tell";
    Ok(parse_targets(&osascript(script)?))
}

/// Parse the tab-separated listing produced by [`targets`].
fn parse_targets(out: &str) -> Vec<Target> {
    out.lines()
        .filter_map(|line| {
            let mut parts = line.split('\t');
            let name = parts.next()?.trim();
            if name.is_empty() {
                return None;
            }
            let kind = parts.next().unwrap_or("").trim();
            let selected = parts.next().unwrap_or("").trim();
            Some(Target {
                name: name.to_string(),
                kind: kind.to_string(),
                selected: selected.eq_ignore_ascii_case("true"),
            })
        })
        .collect()
}

/// Route Music.app to `name` (a room / device name as Music lists it).
///
/// Cold-capable: the target does not need to be connected first, which
/// is the whole reason this path exists.
pub fn send_to(name: &str) -> Result<(), String> {
    let script = format!(
        "tell application \"Music\" to set current AirPlay devices to {{AirPlay device {}}}",
        applescript_string(name)
    );
    osascript(&script).map(|_| ())
}

/// Route Music.app back to this Mac's own speakers.
pub fn send_to_this_mac() -> Result<(), String> {
    let this_mac = targets()?
        .into_iter()
        .find(Target::is_this_mac)
        .ok_or("Music.app does not list this computer as a destination")?;
    send_to(&this_mac.name)
}

/// Names Music.app is currently playing to (AirPlay allows several).
pub fn current() -> Result<Vec<String>, String> {
    let script = "tell application \"Music\"\n\
set out to \"\"\n\
repeat with d in current AirPlay devices\n\
set out to out & (name of d) & linefeed\n\
end repeat\n\
return out\n\
end tell";
    Ok(osascript(script)?
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_tab_separated_listing() {
        let out = "Chris's MacBook Pro (2)\tcomputer\ttrue\n\
Living Room\tAirPlay device\tfalse\n\
50in TCL Roku TV\tTV\tfalse\n";
        let targets = parse_targets(out);
        assert_eq!(targets.len(), 3);
        assert!(targets[0].is_this_mac());
        assert!(targets[0].selected);
        assert_eq!(targets[1].name, "Living Room");
        assert_eq!(targets[1].kind, "AirPlay device");
        assert!(!targets[1].selected);
    }

    #[test]
    fn names_with_commas_survive() {
        // The reason the script emits tabs: AppleScript's own list
        // formatting would split this name in two.
        let targets = parse_targets("Kitchen, Upstairs\tAirPlay device\tfalse");
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].name, "Kitchen, Upstairs");
    }

    #[test]
    fn blank_lines_are_dropped() {
        assert!(parse_targets("\n\n").is_empty());
    }

    #[test]
    fn escapes_quotes_in_room_names() {
        assert_eq!(applescript_string("Nora\"s Room"), "\"Nora\\\"s Room\"");
        assert_eq!(applescript_string("plain"), "\"plain\"");
    }
}
