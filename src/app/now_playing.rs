//! Now-playing chip poller — drains the background `now_playing`
//! source (mixr quick.txt + macOS Music/Spotify via osascript) and
//! surfaces the result for the statusline `♪` chip.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move.

use super::*;

impl App {
    /// Per-event-loop housekeeping (cheap).
    /// Start the background now-playing poller — call once, from the
    /// real terminal loop only (`tui.rs`). Headless / e2e deliberately
    /// skip it so no `osascript` subprocess spawns in tests; the
    /// miniplayer chip just renders its idle form there.
    pub fn start_now_playing_poller(&mut self) {
        if self.now_playing_rx.is_none() {
            self.now_playing_rx = Some(crate::now_playing::spawn_poller(
                crate::now_playing::Source::Auto,
            ));
        }
    }

    /// Drain the now-playing poller channel into `now_playing` — the
    /// latest snapshot wins. No-op until the poller is started.
    pub(super) fn drain_now_playing(&mut self) {
        if let Some(rx) = &self.now_playing_rx {
            while let Ok(np) = rx.try_recv() {
                self.now_playing = np;
            }
        }
    }
}
