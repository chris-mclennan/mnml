//! #1117 (2026-08-21) — background prefetch pipeline.
//!
//! One worker per `[[prefetch]]` block across every installed
//! integration. Each worker runs its declared command at the
//! configured interval (jittered by index like statusline segments,
//! see #1117), captures stdout, and writes it to
//! `~/.cache/mnml/prefetch/<integration_id>-<prefetch_id>.json`.
//!
//! When the user opens a Pty pane for an integration, `open_pty_dir`
//! calls [`App::prefetch_cache_for_launch`] which walks the manifest's
//! prefetch decls, matches the launch's `--only <kind>` arg against
//! `for_pane_kind`, and returns the cache path if the file exists
//! AND is fresh (age < 3 × poll_interval — a stale cache is worse
//! than a cold fetch since the integration would show old data as
//! current). mnml stamps `MNML_PREFETCH_CACHE_FILE=<path>` on the
//! child env; the integration checks that env at startup and
//! hydrates from JSON to skip its first API round-trip.
//!
//! Freshness gate on the read side (`for_pane_kind` match + mtime
//! check) is intentionally simple — we don't want to reason about
//! per-integration schema versioning here. If the integration's
//! hydration branch bails (bad JSON, schema drift), it just
//! cold-fetches — no worse than today.

use std::path::PathBuf;
use std::sync::mpsc::{self};
#[cfg(not(test))]
use std::time::Duration;

use crate::app::App;

/// Minimum enforced interval (defense against a manifest declaring
/// `poll_interval_secs = 5` and hammering Atlassian).
const MIN_INTERVAL_SECS: u64 = 30;
/// Maximum enforced interval (a runaway = 3600s cap).
const MAX_INTERVAL_SECS: u64 = 3600;
/// Default when the manifest omits `poll_interval_secs`.
const DEFAULT_INTERVAL_SECS: u64 = 300;
/// Freshness multiplier: cache is usable if age < N × interval.
/// 3× so a slightly late poll doesn't force a cold fetch on the
/// pane-open path.
const FRESHNESS_MULTIPLIER: u32 = 3;

fn clamp_interval(v: Option<u64>) -> u64 {
    v.unwrap_or(DEFAULT_INTERVAL_SECS)
        .clamp(MIN_INTERVAL_SECS, MAX_INTERVAL_SECS)
}

/// The one root every worker writes into. Callers use
/// [`prefetch_cache_path`] to derive the per-source file name.
pub fn prefetch_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| {
        PathBuf::from(h)
            .join(".cache")
            .join("mnml")
            .join("prefetch")
    })
}

pub fn prefetch_cache_path(integration_id: &str, prefetch_id: &str) -> Option<PathBuf> {
    prefetch_dir().map(|d| d.join(format!("{integration_id}-{prefetch_id}.json")))
}

/// One work item the App fans out to the worker fleet. All fields
/// are read by `run_prefetch_worker` (in the `#[cfg(not(test))]`
/// build). Under `#[cfg(test)]`, `spawn_prefetch_worker` is a no-op
/// stub that ignores `job` — so every field appears unused to
/// clippy in the test build. `#[allow(dead_code)]` here suppresses
/// the test-build lint without hiding real unused-field regressions
/// in the prod path (those still show up under `cargo build`).
#[allow(dead_code)]
struct PrefetchJob {
    integration_id: String,
    prefetch_id: String,
    command: String,
    interval_secs: u64,
    stagger_secs: u64,
}

impl App {
    /// Spawn one background worker per `[[prefetch]]` declaration.
    /// Called at startup (via `with_integration_manifests_merged`)
    /// and any time integration manifests are re-merged. Mirrors the
    /// shape of `start_statusline_segment_workers` — reuses the same
    /// interruptible-sleep + shutdown-drop pattern so a manifest
    /// refresh drops the old fleet instantly.
    pub fn start_prefetch_workers(&mut self) {
        // Snapshot the jobs first (install gate: parent integration
        // must be enabled AND binary on PATH — same rules as
        // values_sources).
        let mut jobs: Vec<PrefetchJob> = Vec::new();
        for m in &self.integration_manifests {
            if !self.integration_chip_enabled(&m.id) {
                continue;
            }
            for p in &m.prefetch {
                if !crate::app::statusline_segments::binary_from_command_on_path(&p.command) {
                    continue;
                }
                jobs.push(PrefetchJob {
                    integration_id: m.id.clone(),
                    prefetch_id: p.id.clone(),
                    command: p.command.clone(),
                    interval_secs: clamp_interval(p.poll_interval_secs),
                    stagger_secs: 0, // set below with index
                });
            }
        }
        // Drop the prior generation's shutdowns → workers exit on
        // next recv_timeout.
        self.prefetch_worker_shutdowns.clear();
        if jobs.is_empty() {
            return;
        }
        // Ensure the cache dir exists ONCE per re-init, not per
        // worker startup — cheap.
        if let Some(dir) = prefetch_dir() {
            let _ = std::fs::create_dir_all(&dir);
        }
        // Same 2s-per-index stagger as statusline segments —
        // capped 30s so cold-start doesn't wait forever for the last
        // integration's first paint.
        for (index, mut job) in jobs.into_iter().enumerate() {
            let (shutdown_tx, shutdown_rx) = mpsc::channel::<()>();
            self.prefetch_worker_shutdowns.push(shutdown_tx);
            job.stagger_secs = (index as u64 * 2).min(30);
            spawn_prefetch_worker(job, shutdown_rx);
        }
    }

    /// #1117 — resolve the prefetch cache path (if any) that
    /// matches a Pty launch's args. Looks for `--only <kind>` in the
    /// args, walks the integration's prefetch decls, and returns
    /// the first match whose cache file exists AND is fresh (age
    /// under 3× the declared poll interval).
    ///
    /// Returns None on any of:
    ///   - integration not in manifests
    ///   - no prefetch decl for the launched kind
    ///   - cache file missing
    ///   - cache file older than 3× poll_interval (stale — better
    ///     to cold-fetch than show old data as current)
    pub fn prefetch_cache_for_launch(
        &self,
        integration_id: &str,
        args: &[String],
    ) -> Option<PathBuf> {
        let pane_kind = extract_only_kind(args);
        let manifest = self
            .integration_manifests
            .iter()
            .find(|m| m.id == integration_id)?;
        for p in &manifest.prefetch {
            // Match rule: prefetch decl's `for_pane_kind` must equal
            // the launch's `--only <kind>` (both present) OR the
            // decl omits `for_pane_kind` (matches every launch of
            // this integration).
            let matches = match (p.for_pane_kind.as_deref(), pane_kind.as_deref()) {
                (None, _) => true,
                (Some(want), Some(got)) => want == got,
                (Some(_), None) => false,
            };
            if !matches {
                continue;
            }
            let path = prefetch_cache_path(integration_id, &p.id)?;
            let meta = std::fs::metadata(&path).ok()?;
            let mtime = meta.modified().ok()?;
            let age = std::time::SystemTime::now().duration_since(mtime).ok()?;
            let stale_after = clamp_interval(p.poll_interval_secs) * FRESHNESS_MULTIPLIER as u64;
            if age.as_secs() > stale_after {
                continue;
            }
            return Some(path);
        }
        None
    }
}

/// Extract the value of `--only <kind>` from a flat argv, matching
/// both `--only kind` and `--only=kind`. Returns None if absent.
fn extract_only_kind(args: &[String]) -> Option<String> {
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(rest) = a.strip_prefix("--only=") {
            return Some(rest.to_string());
        }
        if a == "--only" {
            return it.next().cloned();
        }
    }
    None
}

/// Result the worker doesn't send anywhere — it writes directly to
/// disk. Kept as its own type for future channel-based reporting
/// (e.g. surfacing worker failures via the toast bus).
#[allow(dead_code)]
struct PrefetchUpdate {
    integration_id: String,
    prefetch_id: String,
    result: Result<(), String>,
}

#[cfg(not(test))]
fn spawn_prefetch_worker(job: PrefetchJob, shutdown_rx: std::sync::mpsc::Receiver<()>) {
    let name = format!("mnml-prefetch-{}-{}", job.integration_id, job.prefetch_id);
    std::thread::Builder::new()
        .name(name)
        .spawn(move || run_prefetch_worker(job, shutdown_rx))
        .ok();
}

#[cfg(test)]
fn spawn_prefetch_worker(_job: PrefetchJob, _shutdown_rx: std::sync::mpsc::Receiver<()>) {
    // Tests skip the thread — cache-path + freshness logic is
    // exercised via prefetch_cache_for_launch directly.
}

#[cfg(not(test))]
fn run_prefetch_worker(job: PrefetchJob, shutdown_rx: std::sync::mpsc::Receiver<()>) {
    // Initial stagger — same interruptible-sleep as the poll wait.
    if job.stagger_secs > 0 {
        match shutdown_rx.recv_timeout(Duration::from_secs(job.stagger_secs)) {
            Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
    loop {
        let _ = poll_and_write(&job);
        match shutdown_rx.recv_timeout(Duration::from_secs(job.interval_secs)) {
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        }
    }
}

#[cfg(not(test))]
fn poll_and_write(job: &PrefetchJob) -> Result<(), String> {
    let mut parts = job.command.split_whitespace();
    let bin = parts.next().ok_or_else(|| "empty command".to_string())?;
    let args: Vec<&str> = parts.collect();
    let out = std::process::Command::new(bin)
        .args(&args)
        .output()
        .map_err(|e| format!("spawn: {e}"))?;
    if !out.status.success() {
        return Err(format!("exit {}", out.status.code().unwrap_or(-1)));
    }
    let path = prefetch_cache_path(&job.integration_id, &job.prefetch_id)
        .ok_or_else(|| "no HOME".to_string())?;
    // Write via a `.tmp` sibling + rename so a reader never sees a
    // half-written file. Same pattern the ai_token writer uses.
    let mut tmp = path.clone();
    tmp.set_extension("json.tmp");
    std::fs::write(&tmp, &out.stdout).map_err(|e| format!("write tmp: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("rename: {e}"))?;
    Ok(())
}

// Silence the field-not-read warning on the test-only spawn stub
// while keeping the field for the future channel-based reporter.
#[allow(dead_code)]
fn _touch_update_shape(u: PrefetchUpdate) -> (String, String, Result<(), String>) {
    (u.integration_id, u.prefetch_id, u.result)
}

// Keep `PrefetchUpdate` fields used so #[allow(dead_code)] on the
// struct isn't the only anchor.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_only_kind_finds_space_form() {
        let args = vec![
            "--flag".to_string(),
            "--only".to_string(),
            "work".to_string(),
        ];
        assert_eq!(extract_only_kind(&args), Some("work".to_string()));
    }

    #[test]
    fn extract_only_kind_finds_equals_form() {
        let args = vec!["--only=boards".to_string()];
        assert_eq!(extract_only_kind(&args), Some("boards".to_string()));
    }

    #[test]
    fn extract_only_kind_absent_returns_none() {
        let args = vec!["--values".to_string()];
        assert_eq!(extract_only_kind(&args), None);
    }

    #[test]
    fn clamp_interval_floors_at_min() {
        assert_eq!(clamp_interval(Some(5)), MIN_INTERVAL_SECS);
    }
}
