//! App-level glue for the statusline coverage chip — lazy-loads
//! `trends.json` on demand. The built-in `Pane::Coverage` was removed;
//! coverage is now shown as an integration Pty pane (`tattle_coverage_ext.open`,
//! provided by `mnml-tattle-coverage`). Only the always-visible statusline
//! chip lives in mnml core, and its data path stays here.

use crate::app::App;
use crate::coverage::TrendsFile;

/// How often we're willing to re-read `trends.json` from disk in a
/// steady-state loop. Cheap read (small JSON), but the cron only
/// updates once a day.
const RELOAD_INTERVAL_SECS: u64 = 300;

impl App {
    /// Load the trends JSON if we don't have it yet, or reload if the
    /// throttle window has elapsed. Called from render + right before
    /// painting the statusline chip.
    pub fn ensure_coverage_loaded(&mut self) {
        let now = unix_secs();
        if self.coverage_trends.is_some()
            && now.saturating_sub(self.coverage_trends_last_loaded_at) < RELOAD_INTERVAL_SECS
        {
            return;
        }
        self.coverage_trends = TrendsFile::load_default();
        self.coverage_trends_last_loaded_at = now;
    }
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
