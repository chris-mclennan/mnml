//! Cross-platform "is this `mnml-*` integration binary installed?" detector.
//!
//! Used to decide whether an `[[ui.integration_icon]]` row should show
//! a `(not installed)` badge. The previous implementation spawned
//! `/usr/bin/which` on every frame; this one:
//!
//!   * walks `$PATH` in-process (no fork, works on Windows)
//!   * falls back to well-known per-OS install dirs so binaries get
//!     detected even when PATH is curated (the macOS `.app` bundle case
//!     where Finder strips PATH but `cargo install` still drops the
//!     binary into `~/.cargo/bin`)
//!   * caches results — one filesystem stat per binary per session,
//!     unless `clear_cache()` is called (after an in-mnml install)

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

// 2026-08-08 — the `discover_mnml_binaries` / `mnml_discovery_cache` /
// `looks_like_mnml_integration` subgraph was removed with the empty
// family_catalog. Its only caller lived in that file. Marketplace is
// the source of truth for available integrations now.

fn cache() -> &'static Mutex<HashMap<String, bool>> {
    static CACHE: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Drop all cached lookups. Call after a successful in-mnml install
/// (the freshly-spawned binary won't be visible until cache is rebuilt).
pub fn clear_cache() {
    if let Ok(mut m) = cache().lock() {
        m.clear();
    }
}

/// Is `name` an executable somewhere we'd expect to find a `mnml-*`
/// integration? Returns `true` if found in `$PATH` or any well-known
/// per-OS install directory.
///
/// `name` is the leaf (e.g. `"mnml-aws-lambda"`) — no path components.
/// On Windows the `.exe` extension is appended automatically.
pub fn is_binary_installed(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    {
        let m = cache().lock().expect("integration_detect cache poisoned");
        if let Some(&hit) = m.get(name) {
            return hit;
        }
    }
    let found = probe(name);
    if let Ok(mut m) = cache().lock() {
        m.insert(name.to_string(), found);
    }
    found
}

fn probe(name: &str) -> bool {
    let executable = make_executable_name(name);

    // 1) Walk $PATH.
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            if is_file(&dir.join(&executable)) {
                return true;
            }
        }
    }

    // 2) Per-OS well-known install dirs (cargo, Homebrew, etc.).
    //    Useful when PATH is curated (e.g. macOS .app launchers).
    for dir in well_known_dirs() {
        if is_file(&dir.join(&executable)) {
            return true;
        }
    }

    false
}

fn is_file(p: &std::path::Path) -> bool {
    std::fs::metadata(p).map(|m| m.is_file()).unwrap_or(false)
}

#[cfg(windows)]
fn make_executable_name(name: &str) -> String {
    if name.to_ascii_lowercase().ends_with(".exe") {
        name.to_string()
    } else {
        format!("{name}.exe")
    }
}

#[cfg(not(windows))]
fn make_executable_name(name: &str) -> String {
    name.to_string()
}

/// Per-OS well-known dirs that hold `cargo install` / Homebrew /
/// system-installed binaries. These are checked even when not on
/// `$PATH` (the macOS `.app` case strips PATH unless launcher.sh
/// rebuilds it).
fn well_known_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    // `cargo install` target — universal. Read $HOME directly so we
    // avoid pulling the `dirs` crate (mnml core doesn't depend on it).
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join(".cargo").join("bin"));
    } else if let Some(home) = std::env::var_os("USERPROFILE") {
        // Windows: $HOME isn't standard; %USERPROFILE% is.
        dirs.push(PathBuf::from(home).join(".cargo").join("bin"));
    }

    #[cfg(target_os = "macos")]
    {
        // Apple Silicon Homebrew prefix, then Intel.
        dirs.push(PathBuf::from("/opt/homebrew/bin"));
        dirs.push(PathBuf::from("/usr/local/bin"));
    }

    #[cfg(target_os = "linux")]
    {
        // Linuxbrew default, then the FHS overrides dir.
        dirs.push(PathBuf::from("/home/linuxbrew/.linuxbrew/bin"));
        dirs.push(PathBuf::from("/usr/local/bin"));
    }

    #[cfg(windows)]
    {
        // Scoop's user-local app dir is the most common `mnml-*` target
        // outside Cargo's own bin. Just probe the LocalAppData root —
        // integration install dirs hang off there.
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            dirs.push(PathBuf::from(local).join("Programs"));
        }
    }

    dirs
}

/// Parse an integration `command` string and return the underlying
/// integration binary name, if it has one.
///
/// - `":term X"` → `Some("X")` — Pty pane launching a integration tool
/// - Any other `":foo.bar"` (built-in palette commands) → `None`,
///   meaning "always available".
pub fn integration_binary_for_command(command: &str) -> Option<&str> {
    let rest = command.strip_prefix(":term ")?;
    let bin = rest.split_whitespace().next()?;
    if bin.is_empty() { None } else { Some(bin) }
}

/// One entry from [`find_shadowed_binaries`] — the same binary name
/// appears at both `active` (what PATH resolves to) and `shadowed_by`
/// (the fresh copy elsewhere that PATH order hides). Existing tests
/// cover the discovery logic in `find_shadowed_binaries_tests`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShadowedBinary {
    /// The `mnml-*` binary name.
    pub name: String,
    /// What `which <name>` returns — the stale copy that PATH picks.
    pub active: PathBuf,
    /// mtime of `active`, epoch seconds.
    pub active_mtime: u64,
    /// The fresh copy in `~/.cargo/bin/` that PATH hides.
    pub shadowed_by: PathBuf,
    /// mtime of `shadowed_by`, epoch seconds.
    pub shadowed_by_mtime: u64,
}

/// Walk `$PATH`, find every `mnml-*` binary that resolves to a copy
/// OTHER than the one in `~/.cargo/bin/`. These are the shadowing
/// culprits — a `<integration> --install` invocation will run the stale
/// copy instead of the fresh one just installed by `cargo install`.
/// Result ordered by name for stable rendering.
///
/// Only reports shadows where the fresh cargo-bin copy actually
/// exists — a `mnml-*` in `~/.local/bin/` with NO peer in cargo-bin
/// isn't shadowing anything, it IS the installed copy.
///
/// See `src/app/mod.rs` install-command construction (~line 7594)
/// for the mitigation on mnml's own install button; this finder
/// covers the user-manual case (`cargo install` from the shell,
/// then a stale copy elsewhere silently wins on `--install`).
pub fn find_shadowed_binaries() -> Vec<ShadowedBinary> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let cargo_bin = PathBuf::from(home).join(".cargo").join("bin");
    let Ok(cargo_entries) = std::fs::read_dir(&cargo_bin) else {
        return Vec::new();
    };
    let path_dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let mut out = Vec::new();
    for entry in cargo_entries.flatten() {
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !name.starts_with("mnml-") {
            continue;
        }
        let cargo_path = entry.path();
        if !is_file(&cargo_path) {
            continue;
        }
        // Walk PATH in order. First hit wins — that's what the shell
        // resolves to. If the first hit isn't cargo_bin, it's a shadow.
        for dir in &path_dirs {
            let candidate = dir.join(&name);
            if !is_file(&candidate) {
                continue;
            }
            // Same file (via symlink or duplicate)? Not a shadow.
            if candidate == cargo_path {
                break;
            }
            let active_mtime = fs_mtime_secs(&candidate).unwrap_or(0);
            let shadowed_by_mtime = fs_mtime_secs(&cargo_path).unwrap_or(0);
            out.push(ShadowedBinary {
                name: name.clone(),
                active: candidate,
                active_mtime,
                shadowed_by: cargo_path.clone(),
                shadowed_by_mtime,
            });
            break;
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn fs_mtime_secs(p: &std::path::Path) -> Option<u64> {
    let meta = std::fs::metadata(p).ok()?;
    let modified = meta.modified().ok()?;
    modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integration_binary_extracted_from_term() {
        assert_eq!(
            integration_binary_for_command(":term mnml-aws-lambda"),
            Some("mnml-aws-lambda")
        );
        assert_eq!(
            integration_binary_for_command(":term mnml-aws-lambda --foo bar"),
            Some("mnml-aws-lambda")
        );
    }

    #[test]
    fn integration_binary_none_for_built_ins() {
        assert_eq!(integration_binary_for_command(":ai.claude_code"), None);
        assert_eq!(integration_binary_for_command(":palette"), None);
        assert_eq!(integration_binary_for_command(""), None);
    }

    #[test]
    fn integration_binary_none_for_term_with_no_binary() {
        assert_eq!(integration_binary_for_command(":term "), None);
        assert_eq!(integration_binary_for_command(":term"), None);
    }

    #[test]
    fn is_binary_installed_handles_empty_name() {
        assert!(!is_binary_installed(""));
    }

    #[test]
    fn clear_cache_forgets_results() {
        // Probe a name that almost certainly doesn't exist on PATH.
        let nonsense = "mnml-not-a-real-integration-xyz-12345";
        assert!(!is_binary_installed(nonsense));
        // Should be cached at this point.
        assert!(cache().lock().unwrap().contains_key(nonsense));
        clear_cache();
        assert!(!cache().lock().unwrap().contains_key(nonsense));
    }

    #[cfg(windows)]
    #[test]
    fn windows_appends_exe_extension() {
        assert_eq!(make_executable_name("foo"), "foo.exe");
        assert_eq!(make_executable_name("foo.exe"), "foo.exe");
        assert_eq!(make_executable_name("foo.EXE"), "foo.EXE");
    }

    // ── find_shadowed_binaries ─────────────────────────────────
    //
    // These tests run in a scratch $HOME + scratch $PATH so they don't
    // depend on (or corrupt) the developer's real environment. They
    // exercise the actual walk logic, not just the shape.

    #[cfg(unix)]
    fn make_exec(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;
        let p = dir.join(name);
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(b"#!/bin/sh\n").unwrap();
        let mut perm = std::fs::metadata(&p).unwrap().permissions();
        perm.set_mode(0o755);
        std::fs::set_permissions(&p, perm).unwrap();
        p
    }

    /// Scope $HOME + $PATH to a temp world so the shadow-finder walks
    /// only what the test authored. Reset on drop so peer tests aren't
    /// affected.
    ///
    /// #993 step 2a follow-up (2026-08-19): grabs `test_env_lock`
    /// alongside the env vars so `find_shadowed_binaries_*` tests
    /// serialise against every other env-mutating test in the crate
    /// (integration_glyphs, tools::is_on_path_finds_binary_in_synthetic_path,
    /// etc). Was racing on the second cargo-test invocation after the
    /// tools fix landed — cargo runs tests in parallel by default,
    /// two PATH-mutators clobbering each other = false-negative
    /// assertion. The guard drops in `impl Drop` order (guard first,
    /// then env vars restore) so the lock stays held across the
    /// restore side-effects too.
    #[cfg(unix)]
    struct EnvScope {
        home: Option<std::ffi::OsString>,
        path: Option<std::ffi::OsString>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }
    #[cfg(unix)]
    impl EnvScope {
        fn install(home: &std::path::Path, path: &str) -> Self {
            let lock = crate::test_env_lock()
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            let saved = EnvScope {
                home: std::env::var_os("HOME"),
                path: std::env::var_os("PATH"),
                _lock: lock,
            };
            unsafe {
                std::env::set_var("HOME", home);
                std::env::set_var("PATH", path);
            }
            saved
        }
    }
    #[cfg(unix)]
    impl Drop for EnvScope {
        fn drop(&mut self) {
            unsafe {
                match &self.home {
                    Some(v) => std::env::set_var("HOME", v),
                    None => std::env::remove_var("HOME"),
                }
                match &self.path {
                    Some(v) => std::env::set_var("PATH", v),
                    None => std::env::remove_var("PATH"),
                }
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn find_shadowed_binaries_detects_local_bin_ahead_of_cargo() {
        let tmp = tempfile::tempdir().unwrap();
        let cargo_bin = tmp.path().join(".cargo").join("bin");
        let local_bin = tmp.path().join(".local").join("bin");
        std::fs::create_dir_all(&cargo_bin).unwrap();
        std::fs::create_dir_all(&local_bin).unwrap();
        make_exec(&local_bin, "mnml-aws-amplify");
        make_exec(&cargo_bin, "mnml-aws-amplify");
        // $PATH: local_bin BEFORE cargo_bin — the actual failure mode.
        let path = format!("{}:{}", local_bin.display(), cargo_bin.display());
        let _scope = EnvScope::install(tmp.path(), &path);
        let hits = find_shadowed_binaries();
        assert_eq!(hits.len(), 1, "expected 1 shadow, got {hits:?}");
        assert_eq!(hits[0].name, "mnml-aws-amplify");
        assert_eq!(hits[0].active, local_bin.join("mnml-aws-amplify"));
        assert_eq!(hits[0].shadowed_by, cargo_bin.join("mnml-aws-amplify"));
    }

    #[cfg(unix)]
    #[test]
    fn find_shadowed_binaries_ignores_local_bin_only_with_no_peer() {
        // A `mnml-*` in ~/.local/bin/ with NO copy in ~/.cargo/bin/
        // isn't a shadow — it IS the installed copy. Must not flag.
        let tmp = tempfile::tempdir().unwrap();
        let cargo_bin = tmp.path().join(".cargo").join("bin");
        let local_bin = tmp.path().join(".local").join("bin");
        std::fs::create_dir_all(&cargo_bin).unwrap();
        std::fs::create_dir_all(&local_bin).unwrap();
        make_exec(&local_bin, "mnml-forge-github");
        let path = format!("{}:{}", local_bin.display(), cargo_bin.display());
        let _scope = EnvScope::install(tmp.path(), &path);
        let hits = find_shadowed_binaries();
        assert!(hits.is_empty(), "no cargo peer → no shadow, got {hits:?}");
    }

    #[cfg(unix)]
    #[test]
    fn find_shadowed_binaries_ignores_cargo_first_in_path() {
        // Correct PATH order (cargo_bin first) → nothing is shadowed
        // even when both copies exist.
        let tmp = tempfile::tempdir().unwrap();
        let cargo_bin = tmp.path().join(".cargo").join("bin");
        let local_bin = tmp.path().join(".local").join("bin");
        std::fs::create_dir_all(&cargo_bin).unwrap();
        std::fs::create_dir_all(&local_bin).unwrap();
        make_exec(&local_bin, "mnml-aws-lambda");
        make_exec(&cargo_bin, "mnml-aws-lambda");
        let path = format!("{}:{}", cargo_bin.display(), local_bin.display());
        let _scope = EnvScope::install(tmp.path(), &path);
        let hits = find_shadowed_binaries();
        assert!(hits.is_empty(), "cargo_bin first → no shadow, got {hits:?}");
    }

    #[cfg(unix)]
    #[test]
    fn find_shadowed_binaries_skips_non_mnml() {
        // Only `mnml-*` binaries — a shadowed `foo` (or `cargo` itself)
        // doesn't belong in this list.
        let tmp = tempfile::tempdir().unwrap();
        let cargo_bin = tmp.path().join(".cargo").join("bin");
        let local_bin = tmp.path().join(".local").join("bin");
        std::fs::create_dir_all(&cargo_bin).unwrap();
        std::fs::create_dir_all(&local_bin).unwrap();
        make_exec(&local_bin, "foo");
        make_exec(&cargo_bin, "foo");
        let path = format!("{}:{}", local_bin.display(), cargo_bin.display());
        let _scope = EnvScope::install(tmp.path(), &path);
        let hits = find_shadowed_binaries();
        assert!(hits.is_empty(), "non-mnml prefix skipped, got {hits:?}");
    }
}
