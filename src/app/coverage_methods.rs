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

/// S3 sync daemon — spawns ONE background thread that periodically
/// pulls both coverage rollups from S3 into
/// `~/.tattle-claude-artifacts/{feature,code}-coverage/_trends/trends.json`
/// so the statusline chip's `ensure_coverage_loaded` (which reads local
/// disk) stays fresh.
///
/// Fire-and-forget: silent on every failure mode (aws CLI absent, no
/// credentials, network hiccup, bucket permission). No signaling back
/// to the app — the render loop discovers new data on its next
/// throttled read.
///
/// Skipped entirely when `aws` isn't on PATH (non-tattle users get
/// no useless syscalls). Called once from `App::new`. 2026-08-16.
/// Test-mode call site is `#[cfg(not(test))]`-gated to prevent
/// per-test-invocation thread stacks — hence `dead_code` in test.
#[cfg_attr(test, allow(dead_code))]
pub fn spawn_coverage_s3_syncer() {
    // Cheap probe: skip the whole thread if aws CLI isn't available.
    // `which` succeeds silently; failure = binary absent.
    if std::process::Command::new("which")
        .arg("aws")
        .output()
        .ok()
        .map(|o| !o.status.success())
        .unwrap_or(true)
    {
        return;
    }
    std::thread::Builder::new()
        .name("mnml-coverage-s3-sync".into())
        .spawn(|| {
            const BUCKET: &str = "s3://tattle-claude-artifacts/artifacts";
            const INTERVAL: std::time::Duration = std::time::Duration::from_secs(300);
            let Some(home) = std::env::var_os("HOME") else {
                return;
            };
            let home = std::path::PathBuf::from(home);
            let targets: &[(&str, &str)] = &[
                (
                    "feature-coverage/_trends/trends.json",
                    "feature-coverage/_trends/trends.json",
                ),
                (
                    "code-coverage/_trends/trends.json",
                    "code-coverage/_trends/trends.json",
                ),
            ];
            loop {
                for (remote_suffix, local_suffix) in targets {
                    let local_path = home.join(".tattle-claude-artifacts").join(local_suffix);
                    if let Some(parent) = local_path.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    let remote = format!("{BUCKET}/{remote_suffix}");
                    // 30s timeout keeps a hung network call from
                    // starving the next tick. `-only-show-errors`
                    // suppresses the progress bar on stdout.
                    let _ = std::process::Command::new("aws")
                        .args([
                            "s3",
                            "cp",
                            &remote,
                            local_path.to_string_lossy().as_ref(),
                            "--only-show-errors",
                            "--cli-read-timeout",
                            "30",
                            "--cli-connect-timeout",
                            "10",
                        ])
                        .output(); // ignore result entirely
                }
                std::thread::sleep(INTERVAL);
            }
        })
        .ok();
}
