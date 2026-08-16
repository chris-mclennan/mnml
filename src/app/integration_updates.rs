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
