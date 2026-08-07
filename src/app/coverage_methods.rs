//! App-level glue for `Pane::Coverage` — loading `trends.json`, opening
//! the pane, and force-refreshing via `tattle_coverage.refresh`.

use crate::app::App;
use crate::coverage::TrendsFile;
use crate::pane::{CoveragePane, Pane};

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

    /// Force a re-read on the next paint (invalidates the throttle).
    /// Wired to `tattle_coverage.refresh`.
    pub fn force_reload_coverage(&mut self) {
        self.coverage_trends_last_loaded_at = 0;
        self.ensure_coverage_loaded();
        let count = self
            .coverage_trends
            .as_ref()
            .map(|f| f.apps.len())
            .unwrap_or(0);
        self.toast(format!("coverage: {count} surface(s) loaded"));
    }

    /// Open the coverage pane. Reuses an existing pane if there's
    /// already one open.
    pub fn open_coverage_pane(&mut self) {
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::Coverage(_)))
        {
            self.reveal_pane(pid);
            return;
        }
        self.ensure_coverage_loaded();
        let pane = Pane::Coverage(CoveragePane::new());
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.reveal_pane(new_id);
    }
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
