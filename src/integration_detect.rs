//! Cross-platform "is this `mnml-*` sibling binary installed?" detector.
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
/// sibling? Returns `true` if found in `$PATH` or any well-known
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
        // sibling install dirs hang off there.
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            dirs.push(PathBuf::from(local).join("Programs"));
        }
    }

    dirs
}

/// Walk `$PATH` + well-known dirs and return every binary matching
/// the `mnml-<class>-<name>` family naming convention (`class` and
/// `name` are at least one ASCII alphanumeric char each; `name` may
/// contain `-`). De-duped, sorted, lowercase. Used by
/// `family_catalog::discover_uncataloged` to surface installed
/// community siblings the hardcoded catalog doesn't know about.
///
/// Cached per-session via [`clear_cache`] (the same `clear_cache`
/// also drops the per-name install cache). Cheap to call from the `+`
/// overlay open path.
pub fn discover_mnml_binaries() -> Vec<String> {
    {
        let m = mnml_discovery_cache()
            .lock()
            .expect("mnml discovery cache poisoned");
        if let Some(cached) = m.as_ref() {
            return cached.clone();
        }
    }
    let mut found = std::collections::BTreeSet::new();
    let mut search_dirs: Vec<PathBuf> = Vec::new();
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            search_dirs.push(dir);
        }
    }
    search_dirs.extend(well_known_dirs());

    for dir in search_dirs {
        let Ok(read) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in read.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            // Strip Windows .exe suffix for the convention check.
            let stem = name.trim_end_matches(".exe").trim_end_matches(".EXE");
            if !looks_like_mnml_sibling(stem) {
                continue;
            }
            if let Ok(ft) = entry.file_type()
                && (ft.is_file() || ft.is_symlink())
            {
                found.insert(stem.to_ascii_lowercase());
            }
        }
    }
    let result: Vec<String> = found.into_iter().collect();
    if let Ok(mut m) = mnml_discovery_cache().lock() {
        *m = Some(result.clone());
    }
    result
}

fn mnml_discovery_cache() -> &'static Mutex<Option<Vec<String>>> {
    static CACHE: OnceLock<Mutex<Option<Vec<String>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// `true` for strings shaped like `mnml-<class>-<name>` where both
/// segments are non-empty and consist of ASCII alphanumerics or `-`
/// (after the first two `-`). The reserved root binary `mnml` and
/// the family-info binary `mnml-info` return `false` — they're not
/// integrations.
fn looks_like_mnml_sibling(name: &str) -> bool {
    let Some(rest) = name.strip_prefix("mnml-") else {
        return false;
    };
    // Require at least one more `-` so there's a class+name split.
    let Some((class, suffix)) = rest.split_once('-') else {
        return false;
    };
    if class.is_empty() || suffix.is_empty() {
        return false;
    }
    let valid_class = class.chars().all(|c| c.is_ascii_alphanumeric());
    let valid_suffix = suffix
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-');
    valid_class && valid_suffix
}

/// Parse an integration `command` string and return the underlying
/// sibling binary name, if it has one.
///
/// - `":term X"` → `Some("X")` — Pty pane launching a sibling tool
/// - Any other `":foo.bar"` (built-in palette commands) → `None`,
///   meaning "always available".
pub fn sibling_binary_for_command(command: &str) -> Option<&str> {
    let rest = command.strip_prefix(":term ")?;
    let bin = rest.split_whitespace().next()?;
    if bin.is_empty() { None } else { Some(bin) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sibling_binary_extracted_from_term() {
        assert_eq!(
            sibling_binary_for_command(":term mnml-aws-lambda"),
            Some("mnml-aws-lambda")
        );
        assert_eq!(
            sibling_binary_for_command(":term mnml-aws-lambda --foo bar"),
            Some("mnml-aws-lambda")
        );
    }

    #[test]
    fn sibling_binary_none_for_built_ins() {
        assert_eq!(sibling_binary_for_command(":ai.claude_code"), None);
        assert_eq!(sibling_binary_for_command(":palette"), None);
        assert_eq!(sibling_binary_for_command(""), None);
    }

    #[test]
    fn sibling_binary_none_for_term_with_no_binary() {
        assert_eq!(sibling_binary_for_command(":term "), None);
        assert_eq!(sibling_binary_for_command(":term"), None);
    }

    #[test]
    fn is_binary_installed_handles_empty_name() {
        assert!(!is_binary_installed(""));
    }

    #[test]
    fn clear_cache_forgets_results() {
        // Probe a name that almost certainly doesn't exist on PATH.
        let nonsense = "mnml-not-a-real-sibling-xyz-12345";
        assert!(!is_binary_installed(nonsense));
        // Should be cached at this point.
        assert!(cache().lock().unwrap().contains_key(nonsense));
        clear_cache();
        assert!(!cache().lock().unwrap().contains_key(nonsense));
    }

    #[test]
    fn looks_like_mnml_sibling_accepts_canonical_names() {
        assert!(looks_like_mnml_sibling("mnml-aws-lambda"));
        assert!(looks_like_mnml_sibling("mnml-db-dynamodb"));
        assert!(looks_like_mnml_sibling("mnml-tracker-jira"));
        assert!(looks_like_mnml_sibling("mnml-forge-azdevops"));
        assert!(looks_like_mnml_sibling("mnml-fs-s3"));
        // Names with hyphenated suffix still ok.
        assert!(looks_like_mnml_sibling("mnml-aws-cloudwatch-logs"));
    }

    #[test]
    fn looks_like_mnml_sibling_rejects_non_siblings() {
        assert!(!looks_like_mnml_sibling("mnml"));
        assert!(!looks_like_mnml_sibling("mnml-info"));
        assert!(!looks_like_mnml_sibling("mnml-"));
        assert!(!looks_like_mnml_sibling("mnml--x"));
        assert!(!looks_like_mnml_sibling("mxnml-aws-lambda"));
        assert!(!looks_like_mnml_sibling("aws-lambda"));
        // Special chars rejected (no shell-injection vector etc.).
        assert!(!looks_like_mnml_sibling("mnml-aws-fn$weird"));
        // Uppercase letters are tolerated by the predicate — the
        // sweep lowercases names before storing, and most filesystems
        // (macOS, Windows) match case-insensitively for the eventual
        // `is_binary_installed` lookup.
    }

    #[cfg(windows)]
    #[test]
    fn windows_appends_exe_extension() {
        assert_eq!(make_executable_name("foo"), "foo.exe");
        assert_eq!(make_executable_name("foo.exe"), "foo.exe");
        assert_eq!(make_executable_name("foo.EXE"), "foo.EXE");
    }
}
