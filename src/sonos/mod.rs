//! Sonos — the statusline speaker chip and the machinery behind it.
//!
//! Two independent capabilities live under this module, because a Mac
//! can reach a Sonos two very different ways:
//!
//! 1. **Control the player** (this module + [`ops`]) — Sonos speakers
//!    run an open UPnP server on port 1400, so transport, volume,
//!    grouping and favorites are plain HTTP away. No account, no
//!    cloud, no permissions.
//! 2. **Send this Mac's audio to it** ([`stream`] + [`airplay`]) —
//!    macOS 26 exposes no API for picking an AirPlay target (Control
//!    Center's accessibility tree is empty and the Sound pane lists
//!    only CoreAudio devices), so mnml routes around it: Music.app has
//!    a scriptable AirPlay hand-off, and everything else goes out as a
//!    local stream the Sonos plays as internet radio.
//!
//! All network work happens on the [`spawn`]ed worker thread. The
//! render loop only ever reads the latest [`Snapshot`] off a channel
//! and pushes [`Cmd`]s down another — a sleeping speaker must never
//! cost a frame.

pub mod discovery;
pub mod ops;
pub mod soap;
pub mod stream;

#[cfg(target_os = "macos")]
pub mod airplay;
#[cfg(target_os = "macos")]
pub mod coreaudio;

pub use discovery::Player;
pub use ops::{Favorite, SourceKind, TrackInfo, TransportState};

use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

/// Default poll cadence. Matches the now-playing miniplayer's 3s — a
/// speaker chip doesn't need tighter, and it keeps the HTTP chatter
/// with the player negligible.
pub const DEFAULT_POLL: Duration = Duration::from_secs(3);

/// How long to wait before re-running discovery when no player has
/// been found. Long enough that a Sonos-less network isn't broadcasting
/// SSDP every few seconds, short enough that plugging a speaker in
/// shows up without restarting mnml.
const REDISCOVER_AFTER: Duration = Duration::from_secs(60);

/// Everything the UI needs to draw the chip, refreshed each poll.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    /// Visible rooms in the household (satellites excluded).
    pub players: Vec<Player>,
    /// `uuid` of the room the chip is pointed at.
    pub active: Option<String>,
    pub state: TransportState,
    pub track: TrackInfo,
    pub volume: u8,
    pub muted: bool,
    /// Populated on demand by [`Cmd::LoadFavorites`] — browsing costs a
    /// round-trip, so the poll loop doesn't do it speculatively.
    pub favorites: Vec<Favorite>,
    /// True while mnml is streaming this Mac's audio to the player.
    pub streaming: bool,
    /// Last failure, for the chip's tooltip. `None` once a poll
    /// succeeds again.
    pub error: Option<String>,
}

impl Snapshot {
    /// The active player, if it's still in the household.
    pub fn active_player(&self) -> Option<&Player> {
        let uuid = self.active.as_deref()?;
        self.players.iter().find(|p| p.uuid == uuid)
    }

    /// Room name for the chip, or `"Sonos"` before discovery lands.
    pub fn room(&self) -> &str {
        self.active_player()
            .map(|p| p.room.as_str())
            .unwrap_or("Sonos")
    }

    /// True when a player was found at all — the chip hides otherwise,
    /// so a household-less network shows no dead furniture.
    pub fn found(&self) -> bool {
        !self.players.is_empty()
    }

    /// One line describing what's on: `"Artist — Title"` when metadata
    /// exists, else the source's own name (`AirPlay`, `TV`, `Line-in`)
    /// so a metadata-less source still reads as something real.
    pub fn now_line(&self) -> String {
        let t = &self.track;
        match (t.artist.is_empty(), t.title.is_empty()) {
            (false, false) => format!("{} — {}", t.artist, t.title),
            (true, false) => t.title.clone(),
            // mnml's own stream is the one case where we know more than
            // the player does: it reports generic radio, we know it's
            // this Mac.
            _ if self.streaming => "This Mac".to_string(),
            _ => t.source.label().to_string(),
        }
    }
}

/// A request from the UI to the worker. Fire-and-forget: the effect
/// shows up in the next [`Snapshot`].
#[derive(Debug, Clone)]
pub enum Cmd {
    /// Pause if playing, play if not.
    PlayPause,
    Next,
    Previous,
    /// Nudge volume (Sonos clamps at 0/100).
    Volume(i16),
    SetVolume(u8),
    ToggleMute,
    /// Point the chip at a different room (by `uuid`).
    Select(String),
    /// Fetch favorites into the snapshot.
    LoadFavorites,
    /// Play a favorite by index into `Snapshot::favorites`.
    PlayFavorite(usize),
    /// Group every other room onto the active one.
    JoinAll,
    /// Drop the active room out of its group.
    Unjoin,
    /// Start streaming this Mac's audio to the active room.
    StartMacStream,
    /// Stop the stream and release the audio device.
    StopMacStream,
    /// Re-run SSDP + topology now.
    Rediscover,
}

/// Worker configuration, sourced from `[sonos]` in the config file.
#[derive(Debug, Clone, Default)]
pub struct Cfg {
    /// Skip SSDP and talk to this host directly. Useful where
    /// multicast is filtered.
    pub pinned_host: Option<String>,
    /// Preferred room to select at startup (by name, case-insensitive).
    pub room: Option<String>,
    /// Poll cadence; `None` ⇒ [`DEFAULT_POLL`].
    pub poll: Option<Duration>,
}

/// The two channel ends the app holds onto.
pub struct Handle {
    pub tx: Sender<Cmd>,
    pub rx: Receiver<Snapshot>,
}

/// Start the worker. It polls until the receiver is dropped (mnml
/// quitting), at which point it stops any running stream and exits.
pub fn spawn(cfg: Cfg) -> Handle {
    let (cmd_tx, cmd_rx) = std::sync::mpsc::channel::<Cmd>();
    let (snap_tx, snap_rx) = std::sync::mpsc::channel::<Snapshot>();
    std::thread::spawn(move || {
        let Ok(client) = reqwest::blocking::Client::builder()
            .timeout(Duration::from_millis(2500))
            .build()
        else {
            return;
        };
        let mut w = Worker {
            client,
            poll_every: cfg.poll.unwrap_or(DEFAULT_POLL),
            cfg,
            snap: Snapshot::default(),
            stream: None,
            last_discover: None,
            fails: 0,
        };
        w.discover();
        loop {
            w.refresh();
            if snap_tx.send(w.snap.clone()).is_err() {
                break; // app is gone
            }
            match cmd_rx.recv_timeout(w.poll_every) {
                Ok(cmd) => w.handle(cmd),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }
        // Never leave the Mac's audio pointed at a loopback device
        // after mnml exits.
        w.stop_stream();
    });
    Handle {
        tx: cmd_tx,
        rx: snap_rx,
    }
}

/// Worker-thread state. Not `pub` — the app only ever sees snapshots.
struct Worker {
    client: reqwest::blocking::Client,
    cfg: Cfg,
    poll_every: Duration,
    snap: Snapshot,
    stream: Option<stream::Session>,
    last_discover: Option<Instant>,
    /// Consecutive failed polls — see the three-strike rule in
    /// [`Worker::refresh`].
    fails: u8,
}

impl Worker {
    /// Run SSDP + topology and pick the room to point at: the
    /// configured one if it exists, else the first group coordinator,
    /// else the first room at all.
    fn discover(&mut self) {
        self.last_discover = Some(Instant::now());
        let players = discovery::discover(&self.client, self.cfg.pinned_host.as_deref());
        // Keep the current selection across a re-discover when it's
        // still there — re-pointing the chip under the user is worse
        // than a stale-but-valid choice.
        let keep = self
            .snap
            .active
            .as_deref()
            .filter(|uuid| players.iter().any(|p| &p.uuid == uuid))
            .map(str::to_string);
        let preferred = self.cfg.room.as_deref().and_then(|want| {
            players
                .iter()
                .find(|p| p.room.eq_ignore_ascii_case(want.trim()))
                .map(|p| p.uuid.clone())
        });
        self.snap.active = keep.or(preferred).or_else(|| {
            players
                .iter()
                .find(|p| p.is_coordinator())
                .or_else(|| players.first())
                .map(|p| p.uuid.clone())
        });
        self.snap.players = players;
    }

    /// Host to send commands to — the active room's *coordinator*,
    /// since Sonos refuses transport calls aimed at a grouped
    /// follower.
    fn control_host(&self) -> Option<String> {
        let active = self.snap.active_player()?;
        let coord = self
            .snap
            .players
            .iter()
            .find(|p| p.uuid == active.coordinator);
        Some(coord.unwrap_or(active).host.clone())
    }

    /// `uuid` of the coordinator driving the active room's group.
    fn control_uuid(&self) -> Option<String> {
        self.snap
            .active_player()
            .map(|p| p.coordinator.clone())
            .filter(|u| !u.is_empty())
    }

    /// One poll cycle: state, track, volume, mute.
    fn refresh(&mut self) {
        if !self.snap.found() {
            // Nothing found yet — retry discovery on a slow cadence.
            let due = self
                .last_discover
                .map(|t| t.elapsed() >= REDISCOVER_AFTER)
                .unwrap_or(true);
            if due {
                self.discover();
            }
            if !self.snap.found() {
                return;
            }
        }
        let Some(host) = self.control_host() else {
            return;
        };
        match ops::transport_state(&self.client, &host) {
            Ok(state) => {
                self.snap.state = state;
                self.snap.error = None;
                self.fails = 0;
            }
            Err(e) => {
                // One missed poll is usually Wi-Fi, not a vanished
                // speaker — dropping the household on the first blip
                // would hide the chip for a full rediscovery window.
                // Three in a row means it really is gone, and clearing
                // `last_discover` makes the next cycle re-scan at once
                // rather than waiting out REDISCOVER_AFTER.
                self.snap.error = Some(e);
                self.fails = self.fails.saturating_add(1);
                if self.fails >= 3 {
                    self.snap.players.clear();
                    self.last_discover = None;
                }
                return;
            }
        }
        if let Ok(track) = ops::position(&self.client, &host) {
            self.snap.track = track;
        }
        // Volume is read from the *active* room, not the coordinator —
        // each speaker keeps its own level inside a group.
        if let Some(room_host) = self.snap.active_player().map(|p| p.host.clone()) {
            if let Ok(v) = ops::volume(&self.client, &room_host) {
                self.snap.volume = v;
            }
            if let Ok(m) = ops::muted(&self.client, &room_host) {
                self.snap.muted = m;
            }
        }
        self.snap.streaming = self
            .stream
            .as_ref()
            .map(stream::Session::is_alive)
            .unwrap_or(false);
    }

    /// Apply one command, recording any failure in the snapshot so the
    /// chip can say what went wrong instead of silently doing nothing.
    fn handle(&mut self, cmd: Cmd) {
        let host = self.control_host();
        let room_host = self.snap.active_player().map(|p| p.host.clone());
        let result: Result<(), String> = match cmd {
            Cmd::Rediscover => {
                self.discover();
                Ok(())
            }
            Cmd::Select(uuid) => {
                if self.snap.players.iter().any(|p| p.uuid == uuid) {
                    self.snap.active = Some(uuid);
                    Ok(())
                } else {
                    Err("room is no longer in the household".into())
                }
            }
            Cmd::PlayPause => match (host, self.snap.state.is_playing()) {
                (Some(h), true) => ops::pause(&self.client, &h),
                (Some(h), false) => ops::play(&self.client, &h),
                (None, _) => Err("no player selected".into()),
            },
            Cmd::Next => Self::with_host(host, |h| ops::next(&self.client, h)),
            Cmd::Previous => Self::with_host(host, |h| ops::previous(&self.client, h)),
            Cmd::Volume(d) => {
                Self::with_host(room_host, |h| ops::adjust_volume(&self.client, h, d))
            }
            Cmd::SetVolume(v) => {
                Self::with_host(room_host, |h| ops::set_volume(&self.client, h, v))
            }
            Cmd::ToggleMute => {
                let want = !self.snap.muted;
                Self::with_host(room_host, |h| ops::set_mute(&self.client, h, want))
            }
            Cmd::LoadFavorites => match host {
                Some(h) => ops::favorites(&self.client, &h).map(|f| self.snap.favorites = f),
                None => Err("no player selected".into()),
            },
            Cmd::PlayFavorite(i) => {
                match (
                    host,
                    self.control_uuid(),
                    self.snap.favorites.get(i).cloned(),
                ) {
                    (Some(h), Some(uuid), Some(fav)) => {
                        ops::play_favorite(&self.client, &h, &uuid, &fav)
                    }
                    (_, _, None) => Err("favorite is gone — reload the list".into()),
                    _ => Err("no player selected".into()),
                }
            }
            Cmd::JoinAll => self.join_all(),
            Cmd::Unjoin => Self::with_host(room_host, |h| ops::unjoin(&self.client, h)),
            Cmd::StartMacStream => self.start_stream(),
            Cmd::StopMacStream => {
                self.stop_stream();
                Ok(())
            }
        };
        if let Err(e) = result {
            self.snap.error = Some(e);
        }
    }

    /// Run `f` against a host, or report that nothing is selected.
    fn with_host<F>(host: Option<String>, f: F) -> Result<(), String>
    where
        F: FnOnce(&str) -> Result<(), String>,
    {
        match host {
            Some(h) => f(&h),
            None => Err("no player selected".into()),
        }
    }

    /// Group every other visible room onto the active one.
    fn join_all(&mut self) -> Result<(), String> {
        let Some(target) = self.snap.active.clone() else {
            return Err("no player selected".into());
        };
        let others: Vec<String> = self
            .snap
            .players
            .iter()
            .filter(|p| p.uuid != target)
            .map(|p| p.host.clone())
            .collect();
        if others.is_empty() {
            return Err("only one room in the household".into());
        }
        let mut last_err = None;
        for host in others {
            if let Err(e) = ops::join(&self.client, &host, &target) {
                last_err = Some(e);
            }
        }
        // Group membership changed — the topology we hold is stale.
        self.discover();
        last_err.map_or(Ok(()), Err)
    }

    /// Point this Mac's audio at the active room. See [`stream`] for
    /// the mechanism (and why it isn't AirPlay).
    fn start_stream(&mut self) -> Result<(), String> {
        let (Some(host), Some(room)) = (
            self.control_host(),
            self.snap.active_player().map(|p| p.room.clone()),
        ) else {
            return Err("no player selected".into());
        };
        self.stop_stream();
        let session = stream::Session::start(&room, &host)?;
        let uri = session.sonos_uri();
        let metadata = stream::didl(&room);
        ops::play_uri(&self.client, &host, &uri, &metadata)?;
        self.stream = Some(session);
        self.snap.streaming = true;
        Ok(())
    }

    /// Tear the stream down and hand the Mac's audio back to its
    /// previous output device.
    fn stop_stream(&mut self) {
        if let Some(session) = self.stream.take() {
            session.stop();
        }
        self.snap.streaming = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn player(room: &str, uuid: &str) -> Player {
        Player {
            uuid: uuid.to_string(),
            room: room.to_string(),
            host: "10.0.0.1".to_string(),
            coordinator: uuid.to_string(),
            airplay: true,
        }
    }

    #[test]
    fn hidden_until_a_player_is_found() {
        let snap = Snapshot::default();
        assert!(!snap.found());
        assert_eq!(snap.room(), "Sonos");
    }

    #[test]
    fn now_line_prefers_metadata() {
        let mut snap = Snapshot {
            players: vec![player("Living Room", "RINCON_A")],
            active: Some("RINCON_A".into()),
            ..Default::default()
        };
        snap.track.artist = "Burial".into();
        snap.track.title = "Archangel".into();
        assert_eq!(snap.now_line(), "Burial — Archangel");
        assert_eq!(snap.room(), "Living Room");
    }

    #[test]
    fn now_line_falls_back_to_the_source_name() {
        let snap = Snapshot {
            track: TrackInfo {
                source: SourceKind::AirPlay,
                ..Default::default()
            },
            ..Default::default()
        };
        assert_eq!(snap.now_line(), "AirPlay");
    }

    #[test]
    fn now_line_names_this_mac_while_streaming() {
        // The player only knows it's playing internet radio; mnml knows
        // the radio is this Mac, and says so.
        let snap = Snapshot {
            streaming: true,
            track: TrackInfo {
                source: SourceKind::Stream,
                ..Default::default()
            },
            ..Default::default()
        };
        assert_eq!(snap.now_line(), "This Mac");
    }

    #[test]
    fn title_without_artist_stands_alone() {
        let snap = Snapshot {
            track: TrackInfo {
                title: "BBC Radio 6".into(),
                ..Default::default()
            },
            ..Default::default()
        };
        assert_eq!(snap.now_line(), "BBC Radio 6");
    }
}
