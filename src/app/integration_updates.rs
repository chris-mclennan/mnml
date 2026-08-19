//! Background worker + shared state for the marketplace "↑ Update
//! available" chip.
//!
//! One long-lived thread wakes every 6h (or immediately, on a manual
//! `integrations.check_updates_now`) and walks `~/.cargo/.crates2.json`
//! to figure out which installed cargo binaries have a newer version
//! upstream:
//!
//! - crates.io installs (`registry+https://…crates.io-index`) — GET
//!   `https://crates.io/api/v1/crates/<name>` and compare
//!   `.crate.max_stable_version` to the installed version string.
//! - git installs (`git+https://github.com/<owner>/<repo>.git#<sha>`) —
//!   `git ls-remote https://github.com/<owner>/<repo>.git HEAD` and
//!   compare the returned SHA to the sha stored in the crates2 key.
//!
//! Results land in a shared `Arc<Mutex<HashMap<id, UpdateCheck>>>` that
//! the marketplace-tab renderer + click handler consult on every frame.
//! The map is also persisted to `~/.cache/mnml/integration-updates.json`
//! so a mnml restart displays the last-known state instantly, before
//! the network round-trips complete.
//!
//! Silent on every failure mode. A missing crates2.json / missing
//! `git` on PATH / network hiccup / rate-limited crates.io response
//! all resolve to "no data for this id, don't render the chip". The
//! feature is decorative, not load-bearing.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// One update-check result — parked on the shared map by the worker,
/// consumed by the marketplace-tab renderer + click handler.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateCheck {
    pub id: String,
    pub current: String,
    pub latest: String,
    pub kind: UpdateKind,
    pub checked_at: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateKind {
    /// Installed from crates.io — comparing semver strings.
    Cargo,
    /// Installed from a git ref — comparing full SHAs.
    CargoGit,
}

/// Is `current != latest`? Cheap string compare — semver / SHA both
/// work as plain strings for this purpose. A false positive would only
/// nag the user to run `cargo install --force`, which cargo would
/// silently no-op on if the version genuinely already matches.
pub fn is_update_available(check: &UpdateCheck) -> bool {
    !check.current.is_empty() && !check.latest.is_empty() && check.current != check.latest
}

/// #993 step 1 (2026-08-19). Resolve the effective auto-update
/// setting for one integration + source-kind, honoring the
/// precedence chain:
///
///   1. Per-integration override (`IntegrationManifestOverride::auto_update`)
///      wins outright when set — user's per-integration choice
///      always beats the global.
///   2. Global config (`Config::integrations.auto_update_cargo` /
///      `auto_update_git`) — different keys per source kind.
///   3. Shipped default: `false` for everything.
///
/// `override_flag` is `Some(x)` iff the user wrote
/// `auto_update = x` in `~/.config/mnml/integrations/<id>.toml`.
/// `None` = not set, fall through.
///
/// Full worker wiring lands in step 2 (see design doc); this step
/// exposes the resolution so tests + a future Settings-row lookup
/// share one code path. Design:
/// `docs/design/auto-update-integrations.md`.
// Used only by tests until step 2b wires the sweeper against it —
// suppress the dead_code lint at the fn level so `-D warnings`
// stays enabled everywhere else.
#[allow(dead_code)]
pub fn effective_auto_update(
    override_flag: Option<bool>,
    kind: UpdateKind,
    integrations_cfg: &crate::config::IntegrationsConfig,
) -> bool {
    if let Some(v) = override_flag {
        return v;
    }
    match kind {
        UpdateKind::Cargo => integrations_cfg.auto_update_cargo,
        UpdateKind::CargoGit => integrations_cfg.auto_update_git,
    }
}

/// #993 step 2a (2026-08-19). Pure planner: given a set of update
/// checks + per-integration overrides + global config + a last-
/// attempted map, return the subset that should auto-update NOW.
///
/// The planner is deliberately side-effect-free — it doesn't run
/// `cargo install`, doesn't touch disk, doesn't fetch anything. Step
/// 2b's worker calls this then dispatches. Split so the "who is
/// eligible" logic is testable in isolation from the subprocess
/// plumbing.
///
/// Eligibility rules (all must hold):
///
/// - `is_update_available(check)` — non-empty current + latest that
///   differ. Stale-cache blanks are skipped upstream by the same
///   guard the chip painter uses.
/// - `effective_auto_update(override, kind, cfg)` — the resolution
///   chain from step 1: per-integration override wins bidirectionally,
///   then global-by-kind, then default OFF.
/// - Rate cap: `now_secs - last_attempts.get(id).unwrap_or(0) >=
///   AUTO_UPDATE_RATE_CAP_SECS` (24h). Design doc rationale — one
///   auto-install per integration per day so a genuinely broken
///   upstream can't hammer the user's shell all day.
///
/// The returned `AutoUpdatePlan`s carry enough info for step 2b to
/// build the shell command + a status label; the `install_args`
/// helper on `AutoUpdatePlan` produces the exact argv for Cargo
/// installs (the CargoGit case defers to the worker's
/// InstalledEntry lookup since the `--git <repo>` args live there,
/// not on the UpdateCheck).
#[allow(dead_code)]
pub fn plan_auto_updates(
    checks: &HashMap<String, UpdateCheck>,
    overrides: &HashMap<String, Option<bool>>,
    integrations_cfg: &crate::config::IntegrationsConfig,
    last_attempts: &HashMap<String, u64>,
    now_secs: u64,
) -> Vec<AutoUpdatePlan> {
    let mut out: Vec<AutoUpdatePlan> = Vec::new();
    for check in checks.values() {
        if !is_update_available(check) {
            continue;
        }
        let override_flag = overrides.get(&check.id).copied().flatten();
        if !effective_auto_update(override_flag, check.kind, integrations_cfg) {
            continue;
        }
        let last = last_attempts.get(&check.id).copied().unwrap_or(0);
        if now_secs.saturating_sub(last) < AUTO_UPDATE_RATE_CAP_SECS {
            continue;
        }
        out.push(AutoUpdatePlan {
            id: check.id.clone(),
            kind: check.kind,
            current: check.current.clone(),
            latest: check.latest.clone(),
        });
    }
    // Stable order so the sweeper + tests can rely on deterministic
    // output. Sorted by id — the sweep is per-integration independent
    // so the order only matters for the sweeper's status logging.
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

/// Minimum seconds between auto-install attempts per integration.
/// Design doc §Safety guardrails — one auto-install per integration
/// per 24h; a broken upstream can't hammer the user's shell all day.
pub const AUTO_UPDATE_RATE_CAP_SECS: u64 = 24 * 60 * 60;

/// One entry in the planner's output — the "we should try to update
/// this now" verdict. Consumed by the worker in step 2b to build the
/// actual `cargo install` command.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub struct AutoUpdatePlan {
    pub id: String,
    pub kind: UpdateKind,
    pub current: String,
    pub latest: String,
}

impl AutoUpdatePlan {
    /// Argv (excluding the leading `cargo` binary) for the Cargo-kind
    /// case. `--locked` prevents dependency resolution from drifting
    /// mid-install; `--force` replaces the currently-installed binary
    /// (crates.io semver equality is the trigger, so cargo would
    /// otherwise no-op).
    ///
    /// Returns `None` for `CargoGit` — that path needs the `--git
    /// <repo>` args which live on the worker's `InstalledEntry`, not
    /// on the plan. Worker wires that in step 2b.
    #[allow(dead_code)]
    pub fn cargo_install_args(&self) -> Option<Vec<String>> {
        match self.kind {
            UpdateKind::Cargo => Some(vec![
                "install".into(),
                "--locked".into(),
                "--force".into(),
                self.id.clone(),
            ]),
            UpdateKind::CargoGit => None,
        }
    }
}

/// Persist shape for the last sweep. Loaded on startup so the UI has
/// data instantly (before the first fetch resolves); rewritten after
/// every successful sweep.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct UpdateCache {
    fetched_at: u64,
    checks: Vec<UpdateCheck>,
}

fn cache_path() -> Option<PathBuf> {
    if crate::data_root::data_root_kind() == crate::data_root::DataRootKind::Portable {
        return Some(
            crate::data_root::data_root()
                .join("cache")
                .join("integration-updates.json"),
        );
    }
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(
        home.join(".cache")
            .join("mnml")
            .join("integration-updates.json"),
    )
}

/// #993 step 2b (2026-08-19). Path for the per-integration
/// last-attempted-at map that backs the 24h rate cap in
/// `plan_auto_updates`. Sibling of `cache_path()` — same portable /
/// $HOME/.cache split, different filename so the two persist
/// independently (rate-cap state survives a cache wipe, and vice
/// versa).
fn attempts_path() -> Option<PathBuf> {
    if crate::data_root::data_root_kind() == crate::data_root::DataRootKind::Portable {
        return Some(
            crate::data_root::data_root()
                .join("cache")
                .join("integration-update-attempts.json"),
        );
    }
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(
        home.join(".cache")
            .join("mnml")
            .join("integration-update-attempts.json"),
    )
}

/// Persist shape for the per-integration last-attempted-at map.
/// Wrapper struct rather than a raw HashMap so future fields (per-
/// attempt outcome, error tail, etc.) fit without a migration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct AttemptsFile {
    /// `id -> unix-seconds-of-last-cargo-install-attempt`. Recorded
    /// at fire time (not completion) so a hung install still counts
    /// toward the 24h cap — a genuinely broken upstream can't
    /// hammer the shell.
    #[serde(default)]
    attempts: HashMap<String, u64>,
}

/// #993 step 2b. Best-effort load of the rate-cap state. Silent
/// no-op on any error (missing file / malformed JSON / no HOME) —
/// treats "no data" as "no attempts recorded", which means the next
/// sweep will fire eagerly. That matches the shipped-default posture:
/// auto-update stays off unless the user opts in AND the ledger has
/// no recent attempt.
#[allow(dead_code)]
pub fn load_last_attempts() -> HashMap<String, u64> {
    let Some(path) = attempts_path() else {
        return HashMap::new();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    let file: AttemptsFile = serde_json::from_str(&text).unwrap_or_default();
    file.attempts
}

/// #993 step 2b. Persist the last-attempts map atomically-ish (write
/// + rename via `std::fs::write` — same best-effort pattern
/// `save_update_cache` uses; the file is decorative so a torn write
/// on a crash just means the next sweep re-fires, which is safe under
/// cargo's `--locked --force`). Silent on any error.
#[allow(dead_code)]
pub fn save_last_attempts(attempts: &HashMap<String, u64>) {
    let Some(path) = attempts_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let file = AttemptsFile {
        attempts: attempts.clone(),
    };
    let Ok(text) = serde_json::to_string_pretty(&file) else {
        return;
    };
    let _ = std::fs::write(&path, text);
}

/// #993 step 2b. Record a fresh attempt against `id` at `now_secs`
/// in-place. Cheap wrapper the future worker (step 2c) can call
/// immediately after firing `cargo install` so the rate cap holds
/// regardless of how long the install takes / whether it succeeds.
///
/// The caller decides when to persist — batching the writes across a
/// whole sweep is fine (single file rewrite vs. one per plan) since
/// nothing depends on the on-disk state within a single sweep pass.
#[allow(dead_code)]
pub fn record_attempt(attempts: &mut HashMap<String, u64>, id: &str, now_secs: u64) {
    attempts.insert(id.to_string(), now_secs);
}

/// Load the persisted cache into the shared map so the UI has data
/// instantly on startup — no waiting for the first network fetch.
/// Silent no-op on any error (missing file, malformed JSON, etc);
/// the cache is best-effort.
///
/// Returns the cache's `fetched_at` (for diagnostics + so the worker
/// can decide whether the cache is fresh enough to skip an immediate
/// re-check).
pub fn load_update_cache_into(map: &Arc<Mutex<HashMap<String, UpdateCheck>>>) -> Option<u64> {
    let path = cache_path()?;
    let text = std::fs::read_to_string(&path).ok()?;
    let cache: UpdateCache = serde_json::from_str(&text).ok()?;
    if let Ok(mut guard) = map.lock() {
        for c in &cache.checks {
            guard.insert(c.id.clone(), c.clone());
        }
    }
    Some(cache.fetched_at)
}

fn save_update_cache(map: &HashMap<String, UpdateCheck>, fetched_at: u64) {
    let Some(path) = cache_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let cache = UpdateCache {
        fetched_at,
        checks: map.values().cloned().collect(),
    };
    let Ok(text) = serde_json::to_string_pretty(&cache) else {
        return;
    };
    let _ = std::fs::write(&path, text);
}

/// Handle the palette command uses to nudge the worker off its 6h
/// timer. Cheap to clone — the underlying sender is bounded so a
/// second poke while one is already queued coalesces (the worker
/// picks up both in its next pass).
#[derive(Clone)]
pub struct UpdateWaker {
    tx: SyncSender<()>,
}

impl UpdateWaker {
    /// Non-blocking. Signals the worker to wake early; a full channel
    /// means an earlier poke is still pending and this one is safely
    /// dropped (the worker services every queued update in one pass).
    pub fn poke(&self) {
        let _ = self.tx.try_send(());
    }
}

/// Guards against spawning a second worker if `App::new` somehow gets
/// called more than once in a process. The first call spawns; every
/// subsequent call returns a waker (bound to a dead channel — pokes
/// silently drop, harmless).
static SPAWNED: AtomicBool = AtomicBool::new(false);

/// Spawn ONE background thread and return the waker for the palette
/// command. Idempotent — a second call never spawns a second thread.
///
/// Callers gate this with `#[cfg(not(test))]` (see `App::new`) so the
/// unit + e2e suites don't stack un-joined daemon threads per
/// invocation. Same pattern used by `spawn_coverage_s3_syncer`.
#[cfg_attr(test, allow(dead_code))]
pub fn spawn_update_check_worker(
    app_updates: Arc<Mutex<HashMap<String, UpdateCheck>>>,
) -> UpdateWaker {
    let (tx, rx) = mpsc::sync_channel::<()>(1);
    let waker = UpdateWaker { tx };
    if SPAWNED.swap(true, Ordering::SeqCst) {
        return waker;
    }
    std::thread::Builder::new()
        .name("mnml-integration-updates".into())
        .spawn(move || run_loop(app_updates, rx))
        .ok();
    waker
}

const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
/// Grace period before the first check on a fresh mnml — lets the UI
/// paint the pre-loaded cache values before we open network sockets.
const STARTUP_GRACE: Duration = Duration::from_secs(30);

fn run_loop(app_updates: Arc<Mutex<HashMap<String, UpdateCheck>>>, rx: Receiver<()>) {
    // If the persisted cache is still within its 6h window, delay the
    // first fetch by the full interval — a rapid restart cycle
    // shouldn't hammer crates.io. A manual poke still wakes early.
    let initial_wait = if cache_is_stale() {
        STARTUP_GRACE
    } else {
        CHECK_INTERVAL
    };
    match rx.recv_timeout(initial_wait) {
        Ok(()) | Err(RecvTimeoutError::Timeout) => {}
        Err(RecvTimeoutError::Disconnected) => return,
    }
    loop {
        run_one_sweep(&app_updates);
        // Coalesce any additional pokes that landed during the sweep.
        while rx.try_recv().is_ok() {}
        match rx.recv_timeout(CHECK_INTERVAL) {
            Ok(()) => while rx.try_recv().is_ok() {},
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

fn cache_is_stale() -> bool {
    let Some(path) = cache_path() else {
        return true;
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return true,
    };
    let cache: UpdateCache = match serde_json::from_str(&text) {
        Ok(c) => c,
        Err(_) => return true,
    };
    let now = now_secs();
    now.saturating_sub(cache.fetched_at) > CHECK_INTERVAL.as_secs()
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn run_one_sweep(app_updates: &Arc<Mutex<HashMap<String, UpdateCheck>>>) {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return;
    };
    let installed = parse_installed_from_crates2(&home.join(".cargo").join(".crates2.json"));
    // Only track the ids that look like mnml integrations — avoids
    // hitting crates.io for every random `cargo install` on the box.
    let installed: Vec<InstalledEntry> = installed
        .into_iter()
        .filter(|e| e.id.starts_with("mnml-"))
        .collect();
    if installed.is_empty() {
        return;
    }
    let client = match reqwest::blocking::Client::builder()
        .user_agent(format!(
            "mnml-integration-updates/{}",
            env!("CARGO_PKG_VERSION")
        ))
        .timeout(Duration::from_secs(10))
        .build()
    {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut results: HashMap<String, UpdateCheck> = HashMap::new();
    for inst in installed {
        let latest = match &inst.kind {
            InstalledKind::Cargo => fetch_cargo_latest(&client, &inst.id),
            InstalledKind::CargoGit { repo } => fetch_git_ls_remote_sha(repo),
        };
        let Some(latest) = latest else { continue };
        let kind = match &inst.kind {
            InstalledKind::Cargo => UpdateKind::Cargo,
            InstalledKind::CargoGit { .. } => UpdateKind::CargoGit,
        };
        results.insert(
            inst.id.clone(),
            UpdateCheck {
                id: inst.id,
                current: inst.current,
                latest,
                kind,
                checked_at: now_secs(),
            },
        );
    }
    let fetched_at = now_secs();
    // Full replace — ids that disappeared from crates2.json (user
    // uninstalled) drop off; ids that failed to fetch also drop and
    // will be re-checked on the next sweep.
    //
    // 2026-08-16 (reviewer polish) — clone the map for the disk
    // write so the UI-thread lock isn't held across
    // JSON-serialize + `fs::write`. Prior code held the lock for
    // the whole write; low practical impact on a 6h cadence + small
    // file, but the render loop reads this map every frame and
    // shouldn't wait on disk I/O.
    let snapshot: HashMap<String, UpdateCheck> = if let Ok(mut guard) = app_updates.lock() {
        *guard = results;
        guard.clone()
    } else {
        return;
    };
    save_update_cache(&snapshot, fetched_at);
}

fn fetch_cargo_latest(client: &reqwest::blocking::Client, name: &str) -> Option<String> {
    let url = format!("https://crates.io/api/v1/crates/{name}");
    let body = client
        .get(&url)
        .send()
        .ok()
        .and_then(|r| r.error_for_status().ok())
        .and_then(|r| r.text().ok())?;
    #[derive(Deserialize)]
    struct Resp {
        #[serde(rename = "crate")]
        krate: Crate,
    }
    #[derive(Deserialize, Default)]
    struct Crate {
        #[serde(default)]
        max_stable_version: Option<String>,
        #[serde(default)]
        max_version: Option<String>,
    }
    let r: Resp = serde_json::from_str(&body).ok()?;
    r.krate.max_stable_version.or(r.krate.max_version)
}

fn fetch_git_ls_remote_sha(repo: &str) -> Option<String> {
    let url = format!("https://github.com/{repo}.git");
    let out = std::process::Command::new("git")
        .args(["ls-remote", &url, "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8(out.stdout).ok()?;
    let first_line = stdout.lines().next()?;
    let sha = first_line.split_whitespace().next()?;
    if sha.len() < 7 {
        return None;
    }
    Some(sha.to_string())
}

#[derive(Debug, Clone)]
struct InstalledEntry {
    id: String,
    current: String,
    kind: InstalledKind,
}

#[derive(Debug, Clone)]
enum InstalledKind {
    Cargo,
    CargoGit { repo: String },
}

fn parse_installed_from_crates2(path: &Path) -> Vec<InstalledEntry> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    parse_crates2_str(&text)
}

/// Public for unit tests. Given the raw contents of
/// `~/.cargo/.crates2.json`, return one `InstalledEntry` per unique
/// crate id. Any install whose source string doesn't match a known
/// `registry+…` or `git+…` shape is silently skipped — path installs,
/// custom registries, and future cargo formats fall out the same way.
fn parse_crates2_str(text: &str) -> Vec<InstalledEntry> {
    let value: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let Some(installs) = value.get("installs").and_then(|v| v.as_object()) else {
        return Vec::new();
    };
    // De-dupe by id — cargo can list historical installs; the last one
    // seen wins (should match the current install anyway).
    let mut seen: HashMap<String, InstalledEntry> = HashMap::new();
    for key in installs.keys() {
        if let Some(entry) = classify_crates2_key(key) {
            seen.insert(entry.id.clone(), entry);
        }
    }
    seen.into_values().collect()
}

fn classify_crates2_key(key: &str) -> Option<InstalledEntry> {
    // Shape: "<name> <ver> (<source>)"
    //   crates.io: "mnml-msg-slack 0.1.3 (registry+https://github.com/rust-lang/crates.io-index)"
    //   git:       "mnml-tattle-coverage 0.1.3 (git+https://github.com/x/y.git?rev=SHA#SHA)"
    let (name_ver, source) = key.split_once(" (")?;
    let source = source.strip_suffix(')').unwrap_or(source);
    let (name, ver) = name_ver.split_once(' ')?;
    if source.starts_with("registry+") {
        return Some(InstalledEntry {
            id: name.to_string(),
            current: ver.to_string(),
            kind: InstalledKind::Cargo,
        });
    }
    if let Some(rest) = source.strip_prefix("git+") {
        // Strip the query + fragment to get the bare URL for the
        // repo-slug parse; keep the fragment for the sha.
        let url_part = rest
            .split(['?', '#'])
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or(rest);
        let repo = parse_repo_slug_from_git_url(url_part)?;
        let sha = rest
            .rsplit_once('#')
            .map(|(_, s)| s.to_string())
            .unwrap_or_else(|| ver.to_string());
        return Some(InstalledEntry {
            id: name.to_string(),
            current: sha,
            kind: InstalledKind::CargoGit { repo },
        });
    }
    None
}

fn parse_repo_slug_from_git_url(url: &str) -> Option<String> {
    let stripped = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("http://github.com/"))
        .or_else(|| url.strip_prefix("git@github.com:"))?;
    let stripped = stripped.strip_suffix(".git").unwrap_or(stripped);
    let mut parts = stripped.split('/');
    let owner = parts.next()?;
    let name = parts.next()?;
    if owner.is_empty() || name.is_empty() {
        return None;
    }
    Some(format!("{owner}/{name}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_update_available_flags_version_change() {
        let check = UpdateCheck {
            id: "foo".into(),
            current: "0.1.3".into(),
            latest: "0.1.4".into(),
            kind: UpdateKind::Cargo,
            checked_at: 0,
        };
        assert!(is_update_available(&check));
        let same = UpdateCheck {
            latest: "0.1.3".into(),
            ..check.clone()
        };
        assert!(!is_update_available(&same));
    }

    // ── #993 step 1 — effective_auto_update resolution ──────────

    #[test]
    fn effective_auto_update_defaults_off_for_both_kinds() {
        let cfg = crate::config::IntegrationsConfig::default();
        assert!(!effective_auto_update(None, UpdateKind::Cargo, &cfg));
        assert!(!effective_auto_update(None, UpdateKind::CargoGit, &cfg));
    }

    #[test]
    fn effective_auto_update_global_cargo_toggle_only_flips_cargo() {
        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: false,
        };
        assert!(effective_auto_update(None, UpdateKind::Cargo, &cfg));
        assert!(!effective_auto_update(None, UpdateKind::CargoGit, &cfg));
    }

    #[test]
    fn effective_auto_update_per_integration_true_wins_over_global_false() {
        let cfg = crate::config::IntegrationsConfig::default();
        assert!(effective_auto_update(Some(true), UpdateKind::Cargo, &cfg));
        assert!(effective_auto_update(
            Some(true),
            UpdateKind::CargoGit,
            &cfg
        ));
    }

    #[test]
    fn effective_auto_update_per_integration_false_wins_over_global_true() {
        // Confirms the override precedence is bidirectional: a user
        // with `auto_update = false` on one integration keeps that
        // integration manual even when the global cargo switch is on.
        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: true,
        };
        assert!(!effective_auto_update(Some(false), UpdateKind::Cargo, &cfg));
        assert!(!effective_auto_update(
            Some(false),
            UpdateKind::CargoGit,
            &cfg
        ));
    }

    // ── #993 step 2a — plan_auto_updates planner ────────────────

    fn mk_check(id: &str, current: &str, latest: &str, kind: UpdateKind) -> UpdateCheck {
        UpdateCheck {
            id: id.into(),
            current: current.into(),
            latest: latest.into(),
            kind,
            checked_at: 0,
        }
    }

    fn checks_map(entries: Vec<UpdateCheck>) -> HashMap<String, UpdateCheck> {
        entries.into_iter().map(|c| (c.id.clone(), c)).collect()
    }

    #[test]
    fn plan_auto_updates_skips_everything_when_defaults_are_off() {
        let checks = checks_map(vec![
            mk_check(
                "mnml-forge-bitbucket",
                "0.3.15",
                "0.3.16",
                UpdateKind::Cargo,
            ),
            mk_check("mnml-obs-datadog", "abc123", "def456", UpdateKind::CargoGit),
        ]);
        let overrides = HashMap::new();
        let cfg = crate::config::IntegrationsConfig::default();
        let attempts = HashMap::new();
        let plans = plan_auto_updates(&checks, &overrides, &cfg, &attempts, 1_000_000);
        assert!(plans.is_empty(), "default OFF ⇒ nothing planned");
    }

    #[test]
    fn plan_auto_updates_includes_eligible_cargo_but_not_git_when_only_cargo_on() {
        let checks = checks_map(vec![
            mk_check(
                "mnml-forge-bitbucket",
                "0.3.15",
                "0.3.16",
                UpdateKind::Cargo,
            ),
            mk_check("mnml-obs-datadog", "abc123", "def456", UpdateKind::CargoGit),
        ]);
        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: false,
        };
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &HashMap::new(), 1_000_000);
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].id, "mnml-forge-bitbucket");
        assert_eq!(plans[0].kind, UpdateKind::Cargo);
    }

    #[test]
    fn plan_auto_updates_per_integration_override_wins_bidirectionally() {
        let checks = checks_map(vec![
            mk_check(
                "mnml-forge-bitbucket",
                "0.3.15",
                "0.3.16",
                UpdateKind::Cargo,
            ),
            mk_check("mnml-tracker-jira", "0.2.7", "0.2.8", UpdateKind::Cargo),
        ]);
        // Global cargo=true; per-integration `false` on jira should
        // hold it back.
        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: false,
        };
        let mut overrides = HashMap::new();
        overrides.insert("mnml-tracker-jira".to_string(), Some(false));
        let plans = plan_auto_updates(&checks, &overrides, &cfg, &HashMap::new(), 1_000_000);
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].id, "mnml-forge-bitbucket");

        // Flip: global OFF; per-integration `true` on jira should
        // include just jira.
        let cfg = crate::config::IntegrationsConfig::default();
        let mut overrides = HashMap::new();
        overrides.insert("mnml-tracker-jira".to_string(), Some(true));
        let plans = plan_auto_updates(&checks, &overrides, &cfg, &HashMap::new(), 1_000_000);
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].id, "mnml-tracker-jira");
    }

    #[test]
    fn plan_auto_updates_rate_cap_skips_recent_attempts() {
        let checks = checks_map(vec![mk_check(
            "mnml-forge-bitbucket",
            "0.3.15",
            "0.3.16",
            UpdateKind::Cargo,
        )]);
        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: false,
        };
        let now = 1_000_000u64;
        // Attempted 12h ago → still within the 24h cap → skip.
        let mut attempts = HashMap::new();
        attempts.insert("mnml-forge-bitbucket".to_string(), now - 12 * 60 * 60);
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &attempts, now);
        assert!(plans.is_empty(), "12h ago ⇒ inside 24h cap ⇒ skip");

        // Attempted 25h ago → outside the cap → include.
        attempts.insert("mnml-forge-bitbucket".to_string(), now - 25 * 60 * 60);
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &attempts, now);
        assert_eq!(plans.len(), 1, "25h ago ⇒ outside cap ⇒ include");
    }

    #[test]
    fn plan_auto_updates_skips_when_current_equals_latest() {
        // Not really an "update available" but let's confirm the
        // planner's guard against noise.
        let checks = checks_map(vec![mk_check(
            "mnml-forge-bitbucket",
            "0.3.16",
            "0.3.16",
            UpdateKind::Cargo,
        )]);
        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: false,
        };
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &HashMap::new(), 1_000_000);
        assert!(plans.is_empty(), "no version drift ⇒ nothing to plan");
    }

    #[test]
    fn cargo_install_args_shape() {
        let plan = AutoUpdatePlan {
            id: "mnml-forge-bitbucket".into(),
            kind: UpdateKind::Cargo,
            current: "0.3.15".into(),
            latest: "0.3.16".into(),
        };
        assert_eq!(
            plan.cargo_install_args().unwrap(),
            vec!["install", "--locked", "--force", "mnml-forge-bitbucket"]
        );

        let git_plan = AutoUpdatePlan {
            id: "mnml-obs-datadog".into(),
            kind: UpdateKind::CargoGit,
            current: "abc".into(),
            latest: "def".into(),
        };
        // CargoGit deferred to step 2b — planner returns None so the
        // worker knows to look up InstalledEntry for --git args.
        assert!(git_plan.cargo_install_args().is_none());
    }

    // ── #993 step 2b — LastAttempts persistence ─────────────────

    #[test]
    fn record_attempt_writes_now_secs() {
        let mut m = HashMap::new();
        record_attempt(&mut m, "mnml-forge-bitbucket", 1_000_000);
        assert_eq!(m.get("mnml-forge-bitbucket").copied(), Some(1_000_000));
        // Second attempt overwrites (fresh timestamp wins).
        record_attempt(&mut m, "mnml-forge-bitbucket", 2_000_000);
        assert_eq!(m.get("mnml-forge-bitbucket").copied(), Some(2_000_000));
    }

    #[test]
    fn save_then_load_last_attempts_round_trips() {
        // Sandbox HOME so save/load target the tempdir, not the
        // dev machine's real ~/.cache/mnml. XDG guards + test_env_lock
        // match the pattern from integration_glyphs's persistence
        // tests (which also target data_root() paths).
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let tmp = tempfile::tempdir().unwrap();
        let _xdg = crate::EnvGuard::remove("XDG_CACHE_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));

        let mut input = HashMap::new();
        input.insert("mnml-forge-bitbucket".to_string(), 1_700_000_000);
        input.insert("mnml-tracker-jira".to_string(), 1_700_050_000);
        save_last_attempts(&input);

        let loaded = load_last_attempts();
        assert_eq!(loaded, input);
    }

    #[test]
    fn load_last_attempts_missing_file_returns_empty() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let tmp = tempfile::tempdir().unwrap();
        let _xdg = crate::EnvGuard::remove("XDG_CACHE_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));

        // No file written — load returns empty rather than erroring
        // or panicking. Matches the shipped default: no attempts on
        // disk = fire eagerly next sweep.
        let loaded = load_last_attempts();
        assert!(loaded.is_empty());
    }

    #[test]
    fn planner_end_to_end_with_persisted_attempts() {
        // Compose the whole path: attempts are recorded + persisted,
        // the planner reads them + honors the rate cap. This is the
        // wiring shape the step-2c worker will use.
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let tmp = tempfile::tempdir().unwrap();
        let _xdg = crate::EnvGuard::remove("XDG_CACHE_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));

        let cfg = crate::config::IntegrationsConfig {
            auto_update_cargo: true,
            auto_update_git: false,
        };
        let checks = checks_map(vec![mk_check(
            "mnml-forge-bitbucket",
            "0.3.15",
            "0.3.16",
            UpdateKind::Cargo,
        )]);
        let now = 2_000_000u64;

        // First pass: no attempts persisted → plan fires.
        let attempts = load_last_attempts();
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &attempts, now);
        assert_eq!(plans.len(), 1, "first sweep with no history should include");

        // Simulate the worker: record + persist attempts for the
        // planned integration.
        let mut attempts = attempts;
        for plan in &plans {
            record_attempt(&mut attempts, &plan.id, now);
        }
        save_last_attempts(&attempts);

        // Second pass 12h later: rate cap still active → skip.
        let attempts = load_last_attempts();
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &attempts, now + 12 * 3600);
        assert!(plans.is_empty(), "12h later ⇒ inside 24h cap ⇒ skip");

        // Third pass 25h later: cap expired → fires again.
        let plans = plan_auto_updates(&checks, &HashMap::new(), &cfg, &attempts, now + 25 * 3600);
        assert_eq!(plans.len(), 1, "25h later ⇒ outside cap ⇒ include");
    }

    #[test]
    fn is_update_available_ignores_empty_strings() {
        // Defensive: a stale cache with a blank current/latest
        // shouldn't render the ↑ chip.
        let mut check = UpdateCheck {
            id: "foo".into(),
            current: String::new(),
            latest: "0.1.4".into(),
            kind: UpdateKind::Cargo,
            checked_at: 0,
        };
        assert!(!is_update_available(&check));
        check.current = "0.1.3".into();
        check.latest = String::new();
        assert!(!is_update_available(&check));
    }

    #[test]
    fn parses_cargo_registry_install() {
        let json = r#"{"installs":{"mnml-msg-slack 0.1.3 (registry+https://github.com/rust-lang/crates.io-index)":{}}}"#;
        let out = parse_crates2_str(json);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "mnml-msg-slack");
        assert_eq!(out[0].current, "0.1.3");
        assert!(matches!(out[0].kind, InstalledKind::Cargo));
    }

    #[test]
    fn parses_git_install_with_rev_and_sha_fragment() {
        let json = r#"{"installs":{"mnml-tattle-coverage 0.1.3 (git+https://github.com/chris-mclennan/mnml-tattle-integrations.git?rev=abc123def456789012345678901234567890abcd#abc123def456789012345678901234567890abcd)":{}}}"#;
        let out = parse_crates2_str(json);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "mnml-tattle-coverage");
        assert_eq!(out[0].current, "abc123def456789012345678901234567890abcd");
        match &out[0].kind {
            InstalledKind::CargoGit { repo } => {
                assert_eq!(repo, "chris-mclennan/mnml-tattle-integrations");
            }
            _ => panic!("wrong kind"),
        }
    }

    #[test]
    fn parses_git_install_hash_only() {
        let json = r#"{"installs":{"mnml-foo 0.0.0 (git+https://github.com/x/y.git#abc1234)":{}}}"#;
        let out = parse_crates2_str(json);
        assert_eq!(out.len(), 1);
        match &out[0].kind {
            InstalledKind::CargoGit { repo } => assert_eq!(repo, "x/y"),
            _ => panic!(),
        }
        assert_eq!(out[0].current, "abc1234");
    }

    #[test]
    fn parses_git_install_branch_and_sha() {
        let json = r#"{"installs":{"mnml-bar 0.0.0 (git+https://github.com/x/y.git?branch=main#deadbeef)":{}}}"#;
        let out = parse_crates2_str(json);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].current, "deadbeef");
        match &out[0].kind {
            InstalledKind::CargoGit { repo } => assert_eq!(repo, "x/y"),
            _ => panic!(),
        }
    }

    #[test]
    fn skips_installs_with_unknown_source_shape() {
        let json = r#"{"installs":{"foo 1.0 (path+file:///tmp/bar)":{}}}"#;
        assert!(parse_crates2_str(json).is_empty());
    }

    #[test]
    fn malformed_json_returns_empty() {
        assert!(parse_crates2_str("not json").is_empty());
        assert!(parse_crates2_str("").is_empty());
        assert!(parse_crates2_str("{}").is_empty());
    }

    #[test]
    fn parses_repo_slug_from_ssh_and_https_urls() {
        assert_eq!(
            parse_repo_slug_from_git_url("https://github.com/foo/bar.git"),
            Some("foo/bar".to_string())
        );
        assert_eq!(
            parse_repo_slug_from_git_url("https://github.com/foo/bar"),
            Some("foo/bar".to_string())
        );
        assert_eq!(
            parse_repo_slug_from_git_url("git@github.com:foo/bar.git"),
            Some("foo/bar".to_string())
        );
        assert_eq!(
            parse_repo_slug_from_git_url("https://gitlab.com/foo/bar.git"),
            None
        );
    }

    #[test]
    fn dedupes_multiple_installs_of_same_id() {
        // Newer cargo can list two rows for the same crate. The parser
        // must keep exactly one InstalledEntry per id.
        let json = r#"{"installs":{
            "mnml-msg-slack 0.1.2 (registry+https://github.com/rust-lang/crates.io-index)": {},
            "mnml-msg-slack 0.1.3 (registry+https://github.com/rust-lang/crates.io-index)": {}
        }}"#;
        let out = parse_crates2_str(json);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "mnml-msg-slack");
    }
}
