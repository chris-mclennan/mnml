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
//! - **Portable, opted-in** — if `<binary_dir>/mnml-data/` exists
//!   AND contains a `.opted-in` file, use it. The two-file gate
//!   prevents an accidentally-named `mnml-data/` folder from
//!   silently redirecting a user's data. Phase C's welcome UI
//!   creates the marker on user consent; power-users can `touch`
//!   it manually for headless setups.
//! - **Portable, awaiting consent** — folder exists but no
//!   `.opted-in`. Reported via [`portable_state`] so the welcome
//!   UI can default its choice to Portable, but resolution stays
//!   on Home until the user consents.
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

/// Cache the fact that we are (or aren't) in portable mode. The
/// binary can't move mid-process, so this is a fine one-shot
/// probe. We deliberately do NOT cache the resolved path — HOME
/// can change mid-process (test env swaps + `--sandbox` mode
/// after startup), and re-reading `env::var_os("HOME")` per call
/// is a cheap HashMap lookup.
static PORTABLE_CACHE: OnceLock<bool> = OnceLock::new();

fn is_portable() -> bool {
    *PORTABLE_CACHE.get_or_init(|| matches!(portable_state(), PortableState::Active))
}

/// Return the absolute path to the user-scoped mnml data root for
/// this process. Never panics — falls back to `./mnml` if HOME is
/// unset AND no portable marker exists (a broken environment;
/// safer to use CWD than to bail).
pub fn data_root() -> PathBuf {
    if is_portable()
        && let Some(p) = portable_candidate()
    {
        return p;
    }
    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home).join(".config").join("mnml");
    }
    PathBuf::from(".").join("mnml")
}

/// Which of the two layouts we resolved to. Cheap wrapper around
/// [`is_portable`] — the reported kind can't change once the
/// portable-cache has been probed.
pub fn data_root_kind() -> DataRootKind {
    if is_portable() {
        DataRootKind::Portable
    } else {
        DataRootKind::Home
    }
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

/// Filename inside the portable folder that gates activation. The
/// welcome UI (Phase C) creates this on user consent; power-users
/// can `touch` it manually for headless setups. Empty file — its
/// presence is the whole signal.
pub const PORTABLE_OPT_IN_FILENAME: &str = ".opted-in";

/// Reported to the welcome UI so it can shape the first-run
/// choice: default to Portable when the folder is already there,
/// default to Normal otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortableState {
    /// No `mnml-data/` folder next to the binary. Welcome UI
    /// defaults the choice to Normal.
    Absent,
    /// Folder is there but no `.opted-in` marker. Welcome UI
    /// defaults the choice to Portable and creates the marker if
    /// the user accepts. Until then, [`data_root`] stays on Home.
    AwaitingConsent,
    /// Folder + marker both present. [`data_root`] returns the
    /// portable folder; no prompt needed.
    Active,
}

/// Report the portable-mode state at the current binary
/// location. Non-cached — cheap enough to call on demand, and the
/// welcome UI needs the live answer (creating the marker mid-run
/// should be immediately observable).
pub fn portable_state() -> PortableState {
    let Some(candidate) = portable_candidate() else {
        return PortableState::Absent;
    };
    if !candidate.is_dir() {
        return PortableState::Absent;
    }
    if candidate.join(PORTABLE_OPT_IN_FILENAME).exists() {
        PortableState::Active
    } else {
        PortableState::AwaitingConsent
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
