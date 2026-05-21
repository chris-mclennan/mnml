//! macOS now-playing source — queries the Music and Spotify apps via
//! AppleScript.
//!
//! Covers the two desktop players. Browser-tab audio is *not*
//! reachable: that needs the private `MediaRemote` framework, which
//! Apple locked down on macOS 15.4+. The script guards each app with
//! an `is running` check so polling never *launches* a player, and
//! wraps each in `try` so a missing app (Spotify not installed) is
//! silently skipped.

use super::NowPlaying;

/// AppleScript: report `<app>\t<track>\t<artist>` for whichever of
/// Music / Spotify is running *and* playing, else an empty line.
const SCRIPT: &str = r#"
on playingInfo(appName)
	try
		if application appName is running then
			tell application appName
				if player state is playing then
					return appName & tab & (name of current track) & tab & (artist of current track)
				end if
			end tell
		end if
	end try
	return ""
end playingInfo
set r to playingInfo("Music")
if r is "" then set r to playingInfo("Spotify")
return r
"#;

/// Poll Music / Spotify. `None` when nothing is playing, `osascript`
/// isn't available, or the platform isn't macOS.
pub fn poll() -> Option<NowPlaying> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let out = std::process::Command::new("osascript")
        .arg("-e")
        .arg(SCRIPT)
        .output()
        .ok()?;
    parse(&String::from_utf8_lossy(&out.stdout))
}

/// Parse the script's `<app>\t<track>\t<artist>` line into a
/// [`NowPlaying`]. Empty / track-less input ⇒ `None`. Pure — unit-
/// testable without `osascript`.
pub fn parse(line: &str) -> Option<NowPlaying> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let mut parts = line.split('\t');
    let app = parts.next().unwrap_or("").trim();
    let track = parts.next().unwrap_or("").trim();
    let artist = parts.next().unwrap_or("").trim();
    if track.is_empty() {
        return None;
    }
    Some(NowPlaying {
        source: if app.is_empty() {
            "macOS".to_string()
        } else {
            app.to_string()
        },
        playing: true,
        track: track.to_string(),
        detail: artist.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_music_line() {
        let n = parse("Music\tAerodynamic\tDaft Punk\n").unwrap();
        assert_eq!(n.source, "Music");
        assert!(n.playing);
        assert_eq!(n.track, "Aerodynamic");
        assert_eq!(n.detail, "Daft Punk");
    }

    #[test]
    fn parses_a_spotify_line_without_an_artist() {
        let n = parse("Spotify\tSome Track\t").unwrap();
        assert_eq!(n.source, "Spotify");
        assert_eq!(n.track, "Some Track");
        assert_eq!(n.detail, "");
    }

    #[test]
    fn empty_or_trackless_input_is_none() {
        assert!(parse("").is_none());
        assert!(parse("   \n").is_none());
        assert!(parse("Music\t\t").is_none()); // no track
    }
}
