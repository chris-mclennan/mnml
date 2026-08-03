//! `data_root()` — single accessor for the user-scoped mnml data
//! directory. Task #858 phase A.
//!
//! Historically ~25 call sites read `HOME` directly and appended
//! `.config/mnml/…`. That worked but blocked two features:
//!
//! 1. **Portable mode** — a "no HOME footprint" layout that keeps
//!    every user-scoped file next to the mnml binary in a
//!    `mnml-data/` folder. Wanted for USB sticks, restricted-HOME
//!    Windows setups, "try before you install" runs, and pinned
//!    per-version data with a portable release.
//! 2. **Sandbox mode** — the existing `--sandbox` flag redirects
//!    HOME to a tempdir so the whole surface (config, glyphs,
//!    sessions, marketplace cache) is throwaway. That path is
//!    already respected by every call site because they all read
//!    HOME — but the abstraction was ad-hoc.
//!
//! This module centralizes the resolution. Precedence:
//!
//! - **Portable marker present** — if `<binary_dir>/mnml-data/` is
//!   a directory, use it. Discovered via `env::current_exe()` at
//!   first call, cached. Portable wins over HOME so a marker file
//!   shipped alongside a binary always takes effect.
//! - **Otherwise** — `$HOME/.config/mnml/`. Sandbox mode's HOME
//!   redirect is invisible here — it just changes what `HOME`
//!   resolves to, which is exactly the point.
//!
//! Every downstream helper (config dir, integrations dir, glyphs
//! dir, marketplace cache path, welcome marker) sits on top of
//! `data_root()`. Adding a new user-scoped file? Route through the
//! helper, not `env::var_os("HOME")`.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Which layout mnml is running in this process. Reported by
/// `/version` / About / troubleshooting reports so a user copying
/// a bug in can tell us which store their files are in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DataRootKind {
    /// `<binary_dir>/mnml-data/` — portable install, no HOME
    /// footprint.
    Portable,
    /// `$HOME/.config/mnml/` — normal install.
    Home,
}

/// Cached result of the current process's data-root resolution.
/// Contains both the resolved directory AND the kind so callers
/// don't have to re-detect. Populated on first `data_root()` call.
struct Resolved {
    path: PathBuf,
    kind: DataRootKind,
}

static RESOLVED: OnceLock<Resolved> = OnceLock::new();

/// Return the absolute path to the user-scoped mnml data root for
/// this process. Never panics — falls back to `.` if HOME is unset
/// AND no portable marker exists (a broken environment; safer to
/// use CWD than to bail).
pub fn data_root() -> PathBuf {
    RESOLVED.get_or_init(resolve).path.clone()
}

/// Which of the two layouts we resolved to. Cached alongside the
/// path — same lifetime.
pub fn data_root_kind() -> DataRootKind {
    RESOLVED.get_or_init(resolve).kind
}

/// Short human-readable label for the current layout. Used by
/// `/version` and About. Not localized.
pub fn data_root_label() -> &'static str {
    match data_root_kind() {
        DataRootKind::Portable => "portable",
        DataRootKind::Home => "normal",
    }
}

/// Detect the current binary's containing directory (via
/// `env::current_exe`). Returns None if the OS can't tell us or
/// if the exe path has no parent. Callers use this to place
/// `mnml-data/` for portable-mode probing AND for the welcome
/// flow's "create portable folder here" action.
pub fn binary_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
}

/// Portable marker path (`<binary_dir>/mnml-data/`) IF the binary
/// directory can be resolved. Just constructs the path — does not
/// check whether it exists.
pub fn portable_candidate() -> Option<PathBuf> {
    binary_dir().map(|d| d.join("mnml-data"))
}

fn resolve() -> Resolved {
    // Portable wins: shipping a mnml-data/ folder next to the
    // binary is an explicit user intent (they set it up on the
    // USB stick / release download / whatever).
    if let Some(portable) = portable_candidate()
        && portable.is_dir()
    {
        return Resolved {
            path: portable,
            kind: DataRootKind::Portable,
        };
    }
    // Otherwise the HOME-scoped layout that every prior mnml used.
    // Sandbox mode's HOME redirect flows through here naturally.
    if let Some(home) = std::env::var_os("HOME") {
        return Resolved {
            path: PathBuf::from(home).join(".config").join("mnml"),
            kind: DataRootKind::Home,
        };
    }
    // No HOME, no portable marker — degenerate environment. Fall
    // back to CWD/mnml so at least reads/writes land somewhere
    // predictable instead of crashing.
    Resolved {
        path: PathBuf::from(".").join("mnml"),
        kind: DataRootKind::Home,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // These tests intentionally do NOT set/unset HOME — the
    // resolution is cached at first call and other tests may
    // already have poisoned the cache. The cheap invariants we
    // can check without racing are the pure helpers.

    #[test]
    fn portable_candidate_ends_in_mnml_data() {
        if let Some(p) = portable_candidate() {
            assert_eq!(p.file_name().and_then(|s| s.to_str()), Some("mnml-data"));
        }
    }

    #[test]
    fn binary_dir_is_absolute_when_present() {
        if let Some(d) = binary_dir() {
            assert!(d.is_absolute(), "binary_dir should be absolute");
        }
    }

    #[test]
    fn data_root_label_is_stable_string() {
        // Just make sure the label matches one of the two variants.
        let l = data_root_label();
        assert!(l == "portable" || l == "normal");
    }
}
