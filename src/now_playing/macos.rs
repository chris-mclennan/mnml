//! macOS now-playing source — queries the Music and Spotify apps via
//! AppleScript.
//!
//! Covers the two desktop players. Browser-tab audio is *not*
//! reachable: that needs the private `MediaRemote` framework, which
//! Apple locked down on macOS 15.4+.
//!
//! Each app gets its **own** `osascript` call with a *literal*
//! `tell application "Music"` / `tell application "Spotify"` target.
//! A literal target is mandatory: AppleScript resolves an app's
//! terminology (`player state`, `current track`, …) against its
//! dictionary at *compile* time, so a variable target
//! (`tell application appName`) gives it nothing to resolve and the
//! whole script fails to compile — which is why the earlier
//! parameterised version silently never returned anything. Running
//! the two apps as separate processes also means a missing Spotify
//! (whose `tell` block then won't compile either) only fails its own
//! `osascript`, leaving the Music check intact. Each script guards
//! the `tell` with `if application "…" is running` so polling never
//! *launches* a player.

use super::NowPlaying;

/// AppleScript for the Music app — emits `Music\t<track>\t<artist>`
/// when Music is running *and* playing, else an empty line. Music
/// ships with macOS, so this always compiles.
const MUSIC_SCRIPT: &str = r#"set np to ""
try
    if application "Music" is running then
        tell application "Music"
            if player state is playing then
                set np to "Music" & tab & (name of current track) & tab & (artist of current track)
            end if
        end tell
    end if
end try
return np"#;

/// AppleScript for Spotify — same shape.
const SPOTIFY_SCRIPT: &str = r#"set np to ""
try
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is playing then
                set np to "Spotify" & tab & (name of current track) & tab & (artist of current track)
            end if
        end tell
    end if
end try
return np"#;

/// True iff a `<name>.app` bundle exists at one of the standard macOS
/// install locations. Guards the `osascript` shell-out so the system
/// doesn't pop the "Choose Application" picker dialog when the target
/// player isn't installed (the dialog appeared even though each
/// script wraps its `tell` in `if application "…" is running` — the
/// guard fires too late once AppleScript has decided to *resolve* the
/// name and can't find a matching app).
fn app_installed(name: &str) -> bool {
    let mut paths: Vec<std::path::PathBuf> = vec![
        std::path::PathBuf::from(format!("/Applications/{name}.app")),
        std::path::PathBuf::from(format!("/System/Applications/{name}.app")),
    ];
    if let Ok(home) = std::env::var("HOME") {
        paths.push(std::path::PathBuf::from(format!(
            "{home}/Applications/{name}.app"
        )));
    }
    paths.iter().any(|p| p.exists())
}

/// Run one AppleScript via `osascript`, returning its trimmed stdout.
/// Any failure — `osascript` missing, the script not compiling because
/// the target app isn't installed, a non-zero exit — yields `""`.
fn run_script(script: &str) -> String {
    std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// Poll Music, then Spotify. `None` when neither is playing, the
/// platform isn't macOS, or `osascript` is unavailable. Each script
/// only runs when the corresponding `.app` is actually installed —
/// otherwise macOS pops a "Choose Application" picker dialog at the
/// user, which is the bug this guard exists to prevent.
pub fn poll() -> Option<NowPlaying> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    if app_installed("Music")
        && let Some(np) = parse(&run_script(MUSIC_SCRIPT))
    {
        return Some(np);
    }
    if app_installed("Spotify")
        && let Some(np) = parse(&run_script(SPOTIFY_SCRIPT))
    {
        return Some(np);
    }
    None
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
