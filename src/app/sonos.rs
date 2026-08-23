//! App-side Sonos wiring — the worker's channels, the snapshot the
//! statusline reads, and the actions the chip and palette fire.
//!
//! The rule here is the same one the now-playing miniplayer follows:
//! nothing on this path may block a frame. Commands are pushed to the
//! [`crate::sonos`] worker thread and their effect shows up on a later
//! poll; the app never waits for a speaker to answer.

use super::*;
use crate::sonos::Cmd;

impl App {
    /// Start the Sonos worker — call once, from the real terminal loop
    /// only. Headless / e2e deliberately skip it so no SSDP broadcast
    /// or HTTP traffic happens in tests; the chip renders its hidden
    /// (household-less) form there.
    pub fn start_sonos_worker(&mut self) {
        if self.sonos_tx.is_some() || !self.config.sonos.enabled {
            return;
        }
        let handle = crate::sonos::spawn(crate::sonos::Cfg {
            pinned_host: self.config.sonos.host.clone(),
            room: self.config.sonos.room.clone(),
            poll: Some(std::time::Duration::from_secs(
                self.config.sonos.poll_secs.max(1) as u64,
            )),
        });
        self.sonos_tx = Some(handle.tx);
        self.sonos_rx = Some(handle.rx);
    }

    /// Drain the worker channel into [`App::sonos`] — latest snapshot
    /// wins. Called from `tick`.
    pub(super) fn drain_sonos(&mut self) {
        let mut latest = None;
        if let Some(rx) = &self.sonos_rx {
            while let Ok(snap) = rx.try_recv() {
                latest = Some(snap);
            }
        }
        if let Some(snap) = latest {
            // Surface a failure once rather than every poll: the worker
            // keeps the message set until a poll succeeds, so toasting
            // unconditionally would spam.
            if let Some(err) = snap.error.as_deref()
                && self.sonos.error.as_deref() != Some(err)
            {
                self.toast(format!("sonos: {err}"));
            }
            self.sonos = snap;
        }
    }

    /// Push a command at the worker, or explain why nothing happened.
    pub fn sonos_send(&mut self, cmd: Cmd) {
        if !self.config.sonos.enabled {
            self.toast("sonos: disabled — `:set sonos` or Settings to enable");
            return;
        }
        match self.sonos_tx.as_ref() {
            Some(tx) => {
                if tx.send(cmd).is_err() {
                    // Worker died (only happens if its client couldn't
                    // be built); drop the handles so a retry can respawn.
                    self.sonos_tx = None;
                    self.sonos_rx = None;
                    self.toast("sonos: worker stopped — retrying on next launch");
                }
            }
            None => self.toast("sonos: no speaker found on this network"),
        }
    }

    /// Play / pause the active room.
    pub fn sonos_play_pause(&mut self) {
        if !self.sonos.found() {
            self.sonos_send(Cmd::Rediscover);
            self.toast("sonos: looking for speakers…");
            return;
        }
        let verb = if self.sonos.state.is_playing() {
            "pause"
        } else {
            "play"
        };
        let room = self.sonos.room().to_string();
        self.sonos_send(Cmd::PlayPause);
        self.toast(format!("sonos: {verb} — {room}"));
    }

    /// Volume nudge, in Sonos's 0-100 scale.
    pub fn sonos_volume(&mut self, delta: i16) {
        self.sonos_send(Cmd::Volume(delta));
    }

    /// Open the room picker. Selecting a room also persists it as the
    /// startup default, since "the room I use" rarely changes.
    pub fn sonos_pick_room(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        if !self.sonos.found() {
            self.sonos_send(Cmd::Rediscover);
            self.toast("sonos: no speakers found yet");
            return;
        }
        let active = self.sonos.active.clone().unwrap_or_default();
        let items: Vec<PickerItem> = self
            .sonos
            .players
            .iter()
            .map(|p| {
                let mut detail = if p.is_coordinator() {
                    String::new()
                } else {
                    "grouped".to_string()
                };
                if p.uuid == active {
                    detail = if detail.is_empty() {
                        "current".to_string()
                    } else {
                        format!("current · {detail}")
                    };
                }
                PickerItem::new(p.uuid.clone(), p.room.clone(), detail)
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::SonosRooms, "Sonos room", items));
    }

    /// Accept handler for the room picker.
    pub(crate) fn sonos_select_room(&mut self, uuid: &str) {
        let room = self
            .sonos
            .players
            .iter()
            .find(|p| p.uuid == uuid)
            .map(|p| p.room.clone());
        self.sonos_send(Cmd::Select(uuid.to_string()));
        if let Some(room) = room {
            self.config.sonos.room = Some(room.clone());
            let _ = crate::app::discovery::persist_sonos_string("room", &room);
            self.toast(format!("sonos: {room}"));
        }
    }

    /// Open the favorites picker, loading the list first when the
    /// snapshot hasn't got one yet.
    pub fn sonos_pick_favorite(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        if self.sonos.favorites.is_empty() {
            // Browsing is a round-trip, so the poll loop never does it
            // speculatively — ask now and let the user re-open.
            self.sonos_send(Cmd::LoadFavorites);
            self.toast("sonos: loading favorites…");
            return;
        }
        let items: Vec<PickerItem> = self
            .sonos
            .favorites
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let kind = if f.is_container() {
                    "playlist"
                } else {
                    "stream"
                };
                PickerItem::new(i.to_string(), f.title.clone(), kind)
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::SonosFavorites,
            "Sonos favorites",
            items,
        ));
    }

    /// Accept handler for the favorites picker.
    pub(crate) fn sonos_play_favorite(&mut self, index: &str) {
        let Ok(i) = index.parse::<usize>() else {
            return;
        };
        let title = self.sonos.favorites.get(i).map(|f| f.title.clone());
        self.sonos_send(Cmd::PlayFavorite(i));
        if let Some(title) = title {
            self.toast(format!("sonos: {title}"));
        }
    }

    /// Refresh the favorites list without opening a picker.
    pub fn sonos_reload_favorites(&mut self) {
        self.sonos_send(Cmd::LoadFavorites);
    }

    /// Toggle streaming this Mac's audio to the active room.
    ///
    /// Prefers native AirPlay when Music.app is what's playing and the
    /// room supports it — no transcoding and no added latency. Falls
    /// back to the loopback stream for every other source, because
    /// macOS 26 offers no way to pick a system AirPlay target.
    pub fn sonos_toggle_mac_audio(&mut self) {
        if self.sonos.streaming {
            self.sonos_send(Cmd::StopMacStream);
            self.toast("sonos: stopped streaming this Mac");
            return;
        }
        if !self.sonos.found() {
            self.toast("sonos: no speaker found on this network");
            return;
        }
        #[cfg(target_os = "macos")]
        if self.config.sonos.prefer_airplay && self.sonos_music_is_the_source() {
            let room = self.sonos.room().to_string();
            match crate::sonos::airplay::send_to(&room) {
                Ok(()) => {
                    self.toast(format!("sonos: Music → {room} (AirPlay)"));
                    return;
                }
                // Fall through to the stream: a Music.app that can't
                // reach the room is exactly what the stream is for.
                Err(e) => self.toast(format!("sonos: AirPlay hand-off failed ({e}) — streaming")),
            }
        }
        // 2026-08-23 (user report) — pre-flight the loopback driver
        // BEFORE firing the stream. Without BlackHole the worker
        // errors out and the user sees a one-line toast that clips
        // before they can read the install command. Toast the exact
        // brew line here (long-form + no truncation, since it's the
        // whole payload the user needs) so the failure path is
        // legible on the FIRST click, not the fifth. The stream fn
        // still checks — this is a UX shortcut, not the source of
        // truth.
        #[cfg(target_os = "macos")]
        if crate::sonos::coreaudio::find_output(crate::sonos::stream::LOOPBACK_NAME).is_none() {
            self.toast(format!("sonos: {}", crate::sonos::stream::INSTALL_HINT));
            return;
        }
        let room = self.sonos.room().to_string();
        self.sonos_send(Cmd::StartMacStream);
        self.toast(format!("sonos: streaming this Mac → {room}"));
    }

    /// True when Music.app is running and is the now-playing source —
    /// the one case with a native AirPlay route.
    #[cfg(target_os = "macos")]
    fn sonos_music_is_the_source(&self) -> bool {
        let music_playing = self
            .now_playing
            .as_ref()
            .is_some_and(|np| np.source.eq_ignore_ascii_case("music") && np.playing);
        music_playing && crate::sonos::airplay::music_running()
    }

    /// Open a picker over Music.app's AirPlay destinations.
    ///
    /// Deliberately explicit: reading the list launches Music.app, so
    /// it only ever happens on a direct user action.
    #[cfg(target_os = "macos")]
    pub fn sonos_pick_airplay_target(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        match crate::sonos::airplay::targets() {
            Ok(targets) if !targets.is_empty() => {
                let items: Vec<PickerItem> = targets
                    .iter()
                    .map(|t| {
                        let detail = if t.selected {
                            format!("{} · current", t.kind)
                        } else {
                            t.kind.clone()
                        };
                        PickerItem::new(t.name.clone(), t.name.clone(), detail)
                    })
                    .collect();
                self.open_picker(Picker::new(
                    PickerKind::SonosAirPlayTargets,
                    "Send Music.app to",
                    items,
                ));
            }
            Ok(_) => self.toast("Music.app lists no AirPlay destinations"),
            Err(e) => self.toast(format!("AirPlay: {e}")),
        }
    }

    /// Non-macOS builds have no Music.app to hand off to.
    #[cfg(not(target_os = "macos"))]
    pub fn sonos_pick_airplay_target(&mut self) {
        self.toast("AirPlay hand-off is macOS-only");
    }

    /// Accept handler for the AirPlay-target picker.
    pub(crate) fn sonos_send_music_to(&mut self, name: &str) {
        #[cfg(target_os = "macos")]
        match crate::sonos::airplay::send_to(name) {
            Ok(()) => self.toast(format!("Music → {name}")),
            Err(e) => self.toast(format!("AirPlay: {e}")),
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = name;
            self.toast("AirPlay hand-off is macOS-only");
        }
    }

    /// Put the system output back on the Mac's own speakers.
    ///
    /// The escape hatch for a stream that outlived its mnml: if the
    /// process is killed while streaming, the output device is left
    /// pointing at the loopback and the Mac appears to have gone
    /// silent. Nothing else on the machine explains that, so mnml
    /// offers the one-click way back.
    #[cfg(target_os = "macos")]
    pub fn sonos_restore_output(&mut self) {
        match crate::sonos::coreaudio::builtin_output() {
            Some(d) => match crate::sonos::coreaudio::set_default_output(d.id) {
                Ok(()) => self.toast(format!("audio output → {}", d.name)),
                Err(e) => self.toast(format!("audio output: {e}")),
            },
            None => self.toast("audio output: no built-in device found"),
        }
    }

    /// Switching the system output device is CoreAudio-specific.
    #[cfg(not(target_os = "macos"))]
    pub fn sonos_restore_output(&mut self) {
        self.toast("switching the audio output is macOS-only");
    }

    /// Copy what's playing on the speaker to the clipboard.
    pub fn sonos_copy_track(&mut self) {
        if !self.sonos.found() {
            self.toast("sonos: nothing playing");
            return;
        }
        let line = self.sonos.now_line();
        self.clipboard.set(line.clone(), false);
        self.toast(format!("copied: {line}"));
    }

    /// Human-readable one-liner for the chip tooltip / `:SonosStatus`.
    pub fn sonos_status_line(&self) -> String {
        if !self.config.sonos.enabled {
            return "sonos: disabled".to_string();
        }
        if !self.sonos.found() {
            return match self.sonos.error.as_deref() {
                Some(e) => format!("sonos: {e}"),
                None => "sonos: no speakers found".to_string(),
            };
        }
        let state = if self.sonos.state.is_playing() {
            "playing"
        } else {
            "paused"
        };
        let mute = if self.sonos.muted { " · muted" } else { "" };
        let stream = if self.sonos.streaming {
            " · streaming this Mac"
        } else {
            ""
        };
        format!(
            "sonos: {} — {} ({state}) · vol {}{mute}{stream}",
            self.sonos.room(),
            self.sonos.now_line(),
            self.sonos.volume,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::sonos::{Player, TrackInfo};

    fn app_with_player() -> App {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.sonos.players = vec![Player {
            uuid: "RINCON_A".into(),
            room: "Living Room".into(),
            host: "192.168.1.131".into(),
            coordinator: "RINCON_A".into(),
            airplay: true,
        }];
        app.sonos.active = Some("RINCON_A".into());
        app.sonos.volume = 31;
        app
    }

    /// The worker must never start under headless / e2e — a test run
    /// has no business broadcasting SSDP or touching the network.
    #[test]
    fn worker_is_not_started_by_construction() {
        let app = app_with_player();
        assert!(app.sonos_tx.is_none());
        assert!(app.sonos_rx.is_none());
    }

    #[test]
    fn disabled_chip_reports_disabled_not_missing() {
        let mut app = app_with_player();
        app.config.sonos.enabled = false;
        assert_eq!(app.sonos_status_line(), "sonos: disabled");
    }

    #[test]
    fn status_line_names_room_track_and_volume() {
        let mut app = app_with_player();
        app.sonos.state = crate::sonos::TransportState::Playing;
        app.sonos.track = TrackInfo {
            artist: "Burial".into(),
            title: "Archangel".into(),
            ..Default::default()
        };
        let line = app.sonos_status_line();
        assert!(line.contains("Living Room"));
        assert!(line.contains("Burial — Archangel"));
        assert!(line.contains("(playing)"));
        assert!(line.contains("vol 31"));
    }

    #[test]
    fn status_line_flags_mute_and_streaming() {
        let mut app = app_with_player();
        app.sonos.muted = true;
        app.sonos.streaming = true;
        let line = app.sonos_status_line();
        assert!(line.contains("muted"));
        assert!(line.contains("streaming this Mac"));
    }

    /// With no household, every action explains itself rather than
    /// silently doing nothing.
    #[test]
    fn commands_without_a_household_toast_instead_of_hanging() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert_eq!(app.sonos_status_line(), "sonos: no speakers found");
        app.sonos_toggle_mac_audio();
        assert!(!app.sonos.streaming);
        // A room picker with nothing to pick must not open an empty
        // overlay.
        app.sonos_pick_room();
        assert!(app.picker.is_none());
    }

    #[test]
    fn room_picker_lists_the_household_and_marks_the_current_room() {
        let mut app = app_with_player();
        app.sonos.players.push(Player {
            uuid: "RINCON_B".into(),
            room: "Kitchen".into(),
            host: "192.168.1.55".into(),
            coordinator: "RINCON_A".into(),
            airplay: false,
        });
        app.sonos_pick_room();
        let picker = app.picker.as_ref().expect("picker opens");
        assert_eq!(picker.kind, crate::picker::PickerKind::SonosRooms);
        assert_eq!(picker.len(), 2);
    }

    /// Favorites are browsed on demand, so the first call asks for the
    /// list rather than opening an empty picker.
    #[test]
    fn favorites_picker_waits_for_the_list() {
        let mut app = app_with_player();
        app.sonos_pick_favorite();
        assert!(app.picker.is_none());
        app.sonos.favorites = vec![crate::sonos::Favorite {
            title: "Radio Paradise".into(),
            uri: "x-rincon-mp3radio://example".into(),
            metadata: String::new(),
        }];
        app.sonos_pick_favorite();
        let picker = app.picker.as_ref().expect("picker opens once loaded");
        assert_eq!(picker.kind, crate::picker::PickerKind::SonosFavorites);
    }
}
