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
            let source = match self.config.ui.now_playing_source.as_str() {
                "mixr" => crate::now_playing::Source::Mixr,
                "macos" => crate::now_playing::Source::Macos,
                _ => crate::now_playing::Source::Auto,
            };
            self.now_playing_rx = Some(crate::now_playing::spawn_poller(source));
        }
    }

    /// Drain the now-playing poller channel into `now_playing` — the
    /// latest snapshot wins, with a small stickiness layer that
    /// keeps the previous mixr track on screen across the brief
    /// "between songs" / `playing_active` flag dips mixr writes
    /// every few cycles. Without this, the statusline `♪` chip
    /// flickers back to the idle `♪ mixr` form for a poll cycle or
    /// two even while the deck is producing audio (user-reported
    /// 2026-06-17). After ~10 s of confirmed empty mixr reads, the
    /// sticky cache lapses — that's a true queue-empty / deck-cleared
    /// state and the chip should reflect it.
    pub(super) fn drain_now_playing(&mut self) {
        if self.now_playing_rx.is_none() {
            return;
        }
        // Take + replace pattern so the immutable borrow on the
        // receiver doesn't conflict with `&mut self` in
        // `merge_now_playing`.
        let mut drained: Vec<Option<crate::now_playing::NowPlaying>> = Vec::new();
        if let Some(rx) = &self.now_playing_rx {
            while let Ok(np) = rx.try_recv() {
                drained.push(np);
            }
        }
        for np in drained {
            let merged = self.merge_now_playing(np);
            self.now_playing = merged;
        }
    }

    /// Stickiness rule for `drain_now_playing` — pulled out so the
    /// merge logic is unit-testable without spinning up the channel.
    fn merge_now_playing(
        &mut self,
        new: Option<crate::now_playing::NowPlaying>,
    ) -> Option<crate::now_playing::NowPlaying> {
        let now = std::time::Instant::now();
        const STICKY_TTL: std::time::Duration = std::time::Duration::from_secs(10);
        let (new_is_mixr, new_track_empty) = new
            .as_ref()
            .map(|n| (n.source.eq_ignore_ascii_case("mixr"), n.track.is_empty()))
            .unwrap_or((false, true));
        if new_is_mixr && !new_track_empty {
            // Real track read — refresh the sticky timestamp.
            self.last_mixr_track_at = Some(now);
            return new;
        }
        // Empty mixr read (or no mixr at all): if we recently had a
        // mixr track and TTL hasn't lapsed, paper over the gap by
        // keeping the previous snapshot's track. Don't extend the
        // timestamp — only a fresh non-empty read does that, so a
        // genuine queue-empty state still lapses after STICKY_TTL.
        if new_is_mixr
            && let Some(ts) = self.last_mixr_track_at
            && now.duration_since(ts) <= STICKY_TTL
            && let Some(old) = self.now_playing.as_ref()
            && !old.track.is_empty()
        {
            let mut merged = new.clone().unwrap_or_else(|| old.clone());
            merged.track = old.track.clone();
            if merged.detail.is_empty() {
                merged.detail = old.detail.clone();
            }
            return Some(merged);
        }
        new
    }
}
