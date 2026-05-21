//! Pluggable "now playing" — the data behind the statusline miniplayer.
//!
//! mnml shows what an external player is playing; the *source* of that
//! info is pluggable, so the sibling `mixr` DJ app today and the macOS
//! Music / Spotify apps both feed the same statusline chip. Adding a
//! source = a new sub-module + one arm in [`poll`].
//!
//! A background poller thread ([`spawn_poller`]) runs the source's
//! poll on an interval and sends snapshots over a channel — a source
//! read (a file for mixr, an `osascript` shell-out for macOS) must
//! never block the render loop.

mod macos;
mod mixr;

use std::sync::mpsc::Receiver;
use std::time::Duration;

/// How often the background poller refreshes. 3s — a miniplayer
/// doesn't need tighter, and it keeps the macOS `osascript` spawn
/// rate modest.
const POLL_INTERVAL: Duration = Duration::from_secs(3);

/// A player-agnostic now-playing snapshot. Whatever the source, it
/// projects to this.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NowPlaying {
    /// Which player this came from — `mixr` / `Music` / `Spotify` —
    /// for future multi-source UI.
    pub source: String,
    /// True when a track is actually playing right now.
    pub playing: bool,
    /// The track title (mixr bakes the artist into this string;
    /// macOS keeps the artist in `detail`).
    pub track: String,
    /// A short extra detail — bpm for mixr, artist for macOS. May be
    /// empty.
    pub detail: String,
}

/// Which now-playing source(s) the miniplayer reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// The sibling mixr DJ app (`~/.mixr/quick.txt`).
    Mixr,
    /// macOS Music / Spotify via AppleScript.
    Macos,
    /// Whatever is actually playing — mixr first (a cheap file read),
    /// then macOS. The default.
    Auto,
}

/// Poll the given source once. `None` ⇒ nothing to show. Blocking —
/// runs on the [`spawn_poller`] thread, never the render loop.
pub fn poll(source: Source) -> Option<NowPlaying> {
    match source {
        Source::Mixr => mixr::poll(),
        Source::Macos => macos::poll(),
        Source::Auto => {
            // Prefer whatever's actually playing; mixr first (a cheap
            // file read), macOS only when mixr is idle (an osascript
            // spawn). Fall back to either source's idle snapshot so
            // the chip still knows a player exists.
            let m = mixr::poll();
            if m.as_ref().is_some_and(|n| n.playing) {
                return m;
            }
            let mac = macos::poll();
            if mac.as_ref().is_some_and(|n| n.playing) {
                return mac;
            }
            m.or(mac)
        }
    }
}

/// Spawn the background poller. It polls `source` every
/// [`POLL_INTERVAL`] and sends each snapshot over the returned
/// channel; it exits when the receiver is dropped (mnml quitting).
/// The first snapshot is sent immediately, before the first sleep,
/// so the chip populates without a 3s lag.
pub fn spawn_poller(source: Source) -> Receiver<Option<NowPlaying>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        loop {
            if tx.send(poll(source)).is_err() {
                break; // receiver gone — mnml is shutting down
            }
            std::thread::sleep(POLL_INTERVAL);
        }
    });
    rx
}
