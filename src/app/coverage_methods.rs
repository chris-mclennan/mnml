//! App-level glue for the statusline coverage chip — lazy-loads
//! `trends.json` on demand. The built-in `Pane::Coverage` was removed;
//! coverage is now shown as an integration Pty pane (`tattle_coverage_ext.open`,
//! provided by `mnml-tattle-coverage`). Only the always-visible statusline
//! chip lives in mnml core, and its data path stays here.

use crate::app::App;
use crate::coverage::{IstanbulTrendsFile, TrendsFile};

/// How often we're willing to re-read `trends.json` from disk in a
/// steady-state loop. Cheap read (small JSON), but the cron only
/// updates once a day.
const RELOAD_INTERVAL_SECS: u64 = 300;

impl App {
    /// Load both trends JSONs if we don't have them yet, or reload if the
    /// throttle window has elapsed. Called from render + right before
    /// painting the statusline chip.
    ///
    /// Feature coverage lives at
    /// `~/.tattle-claude-artifacts/feature-coverage/_trends/trends.json`;
    /// Istanbul coverage at `.../code-coverage/_trends/trends.json`.
    /// Either can be absent (no local sync yet, or non-tattle user) —
    /// missing files silently leave `None`, and the statusline chip
    /// hides the corresponding number. 2026-08-16.
    pub fn ensure_coverage_loaded(&mut self) {
        let now = unix_secs();
        // 2026-08-16 — throttle keys off last-ATTEMPT, not last-success.
        // Prior condition `is_some() && elapsed < 300s` meant a non-tattle
        // user (both files absent, trends stay None forever) re-ran two
        // blocking `fs::read_to_string` + serde parses on EVERY render
        // frame. Now the timestamp advances unconditionally after each
        // attempt so the 5-min window applies whether the file existed
        // or not.
        if now.saturating_sub(self.coverage_trends_last_loaded_at) < RELOAD_INTERVAL_SECS
            && self.coverage_trends_last_loaded_at != 0
        {
            return;
        }
        self.coverage_trends = TrendsFile::load_default();
        self.istanbul_trends = IstanbulTrendsFile::load_default();
        self.coverage_trends_last_loaded_at = now;
    }
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
