//! `Pane::AiUsage` — App-side helpers.
//!
//! Ports the old `:ai.usage` overlay into a proper pane so it
//! docks / splits / tabs / closes with `:bd` or `Ctrl+W q` like
//! every other center-hosted view. Data plumbing (fetcher,
//! ClaudeUsage cache, retry-after) is untouched — the pane just
//! reads `App::ai_usage_claude` at render time.

use crate::app::App;
use crate::pane::{AiUsagePane, Pane};

impl App {
    /// Open (or refocus) the AI usage pane. Idempotent — matches
    /// the `open_integration_detail_pane` shape: reuse an existing
    /// `Pane::AiUsage` if present, else push a new one and reveal.
    /// Kicks a fresh fetch on open so the numbers reflect what
    /// Anthropic sees right now, not what mnml last polled.
    pub fn open_ai_usage_pane(&mut self) {
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::AiUsage(_)))
        {
            // Drop any right-panel copy so we don't render twice
            // (same defensive move as `open_integration_detail_pane`).
            self.right_panel_panes.retain(|&p| p != pid);
            self.reveal_pane(pid);
        } else {
            self.panes.push(Pane::AiUsage(AiUsagePane::new()));
            let new_id = self.panes.len() - 1;
            self.reveal_pane(new_id);
        }
        // Force a fresh fetch — same behavior the retired overlay
        // toggle had on open.
        self.ai_usage_last_refresh_at = 0;
        self.maybe_refresh_ai_usage();
    }

    /// `r` inside a `Pane::AiUsage` and the `ai.refresh_usage`
    /// command surface both dispatch here. Resets the throttle so
    /// `maybe_refresh_ai_usage` actually re-hits Anthropic instead
    /// of short-circuiting on the 5-minute cooldown.
    pub fn refresh_ai_usage_pane(&mut self) {
        self.ai_usage_last_refresh_at = 0;
        self.maybe_refresh_ai_usage();
        self.toast("refreshing Claude usage…".to_string());
    }
}
