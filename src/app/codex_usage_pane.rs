//! `Pane::CodexUsage` — App-side helpers.
//!
//! Codex telemetry is a local-JSONL scan (no network) so its
//! usage pane is simpler than Claude's: single account, no
//! retry-after negotiation, no per-account throttle map. Same
//! open+refresh shape as `claude_usage_pane.rs` so the palette
//! commands feel identical.
//!
//! 2026-08-16 — split off from the shared `ai_usage_pane.rs` when
//! `Pane::AiUsage` fissioned into `Pane::ClaudeUsage` +
//! `Pane::CodexUsage`.

use crate::app::App;
use crate::pane::{CodexUsagePane, Pane};

impl App {
    /// Open (or refocus) the Codex usage pane. Idempotent — reuse
    /// an existing `Pane::CodexUsage` if present, else push a new
    /// one and reveal. Kicks a fresh fetch on open so the numbers
    /// reflect the latest Codex session activity.
    pub fn open_codex_usage_pane(&mut self) {
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::CodexUsage(_)))
        {
            self.right_panel_panes.retain(|&p| p != pid);
            self.reveal_pane(pid);
        } else {
            self.panes.push(Pane::CodexUsage(CodexUsagePane::new()));
            let new_id = self.panes.len() - 1;
            self.reveal_pane(new_id);
        }
        // Force a fresh scan — bypass the shared 5-min throttle so
        // the panel lights up with today's tokens immediately when
        // the user opens it. Codex has no retry-after (local JSONL
        // scan, no rate limiter), so nothing else to clear.
        self.ai_usage_last_refresh_at = 0;
        self.maybe_refresh_ai_usage();
    }

    /// `r` inside a `Pane::CodexUsage` and the surfaced palette
    /// command both dispatch here. Same short-circuit-clear as the
    /// Claude side, minus the retry-after clearing (no 429s here).
    pub fn refresh_codex_usage_pane(&mut self) {
        self.ai_usage_last_refresh_at = 0;
        self.maybe_refresh_ai_usage();
        self.toast("refreshing Codex usage…".to_string());
    }
}
