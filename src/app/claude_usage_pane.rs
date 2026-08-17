//! `Pane::ClaudeUsage` — App-side helpers.
//!
//! Ports the old `:ai.usage` overlay into a proper pane so it
//! docks / splits / tabs / closes with `:bd` or `Ctrl+W q` like
//! every other center-hosted view. Data plumbing (fetcher, per-
//! account ClaudeUsage cache, retry-after) is untouched — the
//! pane just reads `App::ai_usage_claude_accounts` at render
//! time (task #944 — one section per configured account).
//!
//! 2026-08-16 — split off from the shared `ai_usage_pane.rs` when
//! `Pane::AiUsage` fissioned into `Pane::ClaudeUsage` +
//! `Pane::CodexUsage` (see `docs/design/info-view-v0.3.md` — the
//! two products' data shapes had drifted enough that one pane
//! doing both was clumsy for both).

use crate::app::App;
use crate::pane::{ClaudeUsagePane, Pane};

impl App {
    /// Open (or refocus) the Claude usage pane. Idempotent — matches
    /// the `open_integration_detail_pane` shape: reuse an existing
    /// `Pane::ClaudeUsage` if present, else push a new one and reveal.
    /// Kicks a fresh fetch on open so the numbers reflect what
    /// Anthropic sees right now, not what mnml last polled.
    pub fn open_claude_usage_pane(&mut self) {
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::ClaudeUsage(_)))
        {
            // Drop any right-panel copy so we don't render twice
            // (same defensive move as `open_integration_detail_pane`).
            self.right_panel_panes.retain(|&p| p != pid);
            self.reveal_pane(pid);
        } else {
            self.panes.push(Pane::ClaudeUsage(ClaudeUsagePane::new()));
            let new_id = self.panes.len() - 1;
            self.reveal_pane(new_id);
        }
        // Force a fresh fetch across every account.
        //
        // Reviewer 2026-08-16 — resetting the throttles alone wasn't
        // enough: `maybe_refresh_ai_usage` also gates per-account on
        // the cached snapshot's `retry_after_at > now`, so after any
        // 429 the click became a silent no-op until Anthropic's
        // cooldown expired. An explicit user action needs to bypass
        // the header-honored cooldown too, so clear every account's
        // `retry_after_at` before kicking the fetch.
        for acct in self.ai_usage_claude_accounts.iter_mut() {
            acct.usage.retry_after_at = 0;
        }
        self.ai_usage_last_refresh_at = 0;
        self.ai_usage_claude_last_refresh_at.clear();
        self.maybe_refresh_ai_usage();
    }

    /// `r` inside a `Pane::ClaudeUsage` and the `ai.refresh_usage`
    /// command surface both dispatch here. Resets the throttle so
    /// `maybe_refresh_ai_usage` actually re-hits Anthropic instead
    /// of short-circuiting on the 5-minute cooldown OR the honored
    /// Retry-After cooldown from a prior 429.
    pub fn refresh_claude_usage_pane(&mut self) {
        for acct in self.ai_usage_claude_accounts.iter_mut() {
            acct.usage.retry_after_at = 0;
        }
        self.ai_usage_last_refresh_at = 0;
        self.ai_usage_claude_last_refresh_at.clear();
        self.maybe_refresh_ai_usage();
        self.toast("refreshing Claude usage…".to_string());
    }
}
