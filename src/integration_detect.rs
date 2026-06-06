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

/// Parse an integration `command` string and return the underlying
/// sibling binary name, if it's a `:host.launch X` invocation.
/// Returns `None` for built-in palette commands (`":ai.claude_code"`)
/// which are always available.
pub fn sibling_binary_for_command(command: &str) -> Option<&str> {
    let rest = command.strip_prefix(":host.launch ")?;
    let bin = rest.split_whitespace().next()?;
    if bin.is_empty() { None } else { Some(bin) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sibling_binary_extracted_from_host_launch() {
        assert_eq!(
            sibling_binary_for_command(":host.launch mnml-aws-lambda"),
            Some("mnml-aws-lambda")
        );
        assert_eq!(
            sibling_binary_for_command(":host.launch mnml-aws-lambda --foo bar"),
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
    fn sibling_binary_none_for_host_launch_with_no_binary() {
        assert_eq!(sibling_binary_for_command(":host.launch "), None);
        assert_eq!(sibling_binary_for_command(":host.launch"), None);
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

    #[cfg(windows)]
    #[test]
    fn windows_appends_exe_extension() {
        assert_eq!(make_executable_name("foo"), "foo.exe");
        assert_eq!(make_executable_name("foo.exe"), "foo.exe");
        assert_eq!(make_executable_name("foo.EXE"), "foo.EXE");
    }
}
