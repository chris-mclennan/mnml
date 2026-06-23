//! First-launch "did you know about the rest of the family?" check.
//!
//! On launch, detect which of mnml's sibling apps (mixr) are
//! installed. If any are *missing*, fire a one-shot toast with the
//! install command for each. Marker file at
//! `~/.config/mnml/.family-offer-shown` suppresses subsequent
//! launches — we ask once, not every time.
//!
//! Detection is `which`-style (PATH lookup) plus a macOS-only
//! `/Applications/X.app` check, so it covers both `brew install`
//! and DMG-installed users. Cross-platform install commands are
//! picked at compile time via `cfg!(target_os)`.
//!
//! Skipped in headless mode — no toast surface.

use std::path::PathBuf;

/// The family members. `mnml` includes itself so the "missing"
/// filter is just `!= "mnml"` — easier than maintaining a separate
/// sibling list.
const FAMILY: &[&str] = &["mnml", "mixr"];
const SELF: &str = "mnml";

pub struct FamilyOffer {
    pub missing: Vec<&'static str>,
}

impl FamilyOffer {
    /// Detect missing siblings unless this user has already seen
    /// the offer once.
    ///
    /// IMPORTANT: writes the "shown" marker even when nothing is
    /// missing. The `is_installed()` probe stat's `/Applications/<app>.app`
    /// on macOS, which Sequoia (15.x) gates behind the "App
    /// Management / Files and Folders" privacy prompt. Re-running
    /// it every launch re-fires the prompt every launch (the OS
    /// only persists the Allow/Deny per binary hash; cargo builds
    /// change the hash each time). The marker short-circuits the
    /// whole function on subsequent runs so the prompt only fires
    /// once per user, not once per build.
    pub fn maybe_new() -> Option<Self> {
        if marker_path().exists() {
            return None;
        }
        let missing: Vec<&'static str> = FAMILY
            .iter()
            .copied()
            .filter(|name| *name != SELF && !is_installed(name))
            .collect();
        // Persist the marker BEFORE the empty-check return — see the
        // doc comment above for why this can't move to the "shown"
        // path. Best-effort: a write failure means the prompt fires
        // again next launch, which is annoying but not fatal.
        write_marker();
        if missing.is_empty() {
            return None;
        }
        Some(FamilyOffer { missing })
    }

    /// Persist the "shown" marker so the toast doesn't re-fire next
    /// launch. Best-effort — a write failure isn't fatal. Mostly a
    /// no-op now that `maybe_new` always writes the marker; kept
    /// because callers may still call `mark_shown()` defensively.
    pub fn mark_shown(&self) {
        write_marker();
    }

    /// Human-readable single-line install hint per missing sibling.
    /// Platform-specific — Homebrew on macOS + Linuxbrew, winget on
    /// Windows.
    pub fn hint_lines(&self) -> Vec<String> {
        self.missing.iter().map(|app| hint_for(app)).collect()
    }
}

fn hint_for(app: &str) -> String {
    #[cfg(target_os = "macos")]
    {
        format!("Try {app}: brew install chris-mclennan/tap/{app}  ·  https://{app}.sh")
    }
    #[cfg(all(target_os = "linux", not(target_os = "macos")))]
    {
        format!(
            "Try {app}: brew install chris-mclennan/tap/{app}  ·  apt/dnf/AppImage at https://{app}.sh"
        )
    }
    #[cfg(target_os = "windows")]
    {
        format!("Try {app}: winget install chris-mclennan.{app}  ·  https://{app}.sh")
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        format!("Try {app}: https://{app}.sh")
    }
}

fn is_installed(app: &str) -> bool {
    if path_lookup(app) {
        return true;
    }
    #[cfg(target_os = "macos")]
    {
        let p = format!("/Applications/{app}.app");
        if std::path::Path::new(&p).exists() {
            return true;
        }
    }
    false
}

/// `which`-style PATH lookup without a `which` crate dependency.
fn path_lookup(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for entry in std::env::split_paths(&path) {
        let candidate = entry.join(name);
        if candidate.is_file() {
            return true;
        }
        // Windows: also try common executable extensions.
        #[cfg(target_os = "windows")]
        {
            for ext in &[".exe", ".cmd", ".bat"] {
                let mut p = candidate.clone();
                let stem = p
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("")
                    .to_string();
                p.set_file_name(format!("{stem}{ext}"));
                if p.is_file() {
                    return true;
                }
            }
        }
    }
    false
}

fn marker_path() -> PathBuf {
    // mnml doesn't depend on `dirs`; use the $HOME env directly.
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join(".config")
        .join("mnml")
        .join(".family-offer-shown")
}

/// Shared marker-write helper. Best-effort — directory creation or
/// the file write itself may fail (read-only $HOME, full disk, etc.);
/// those failures are silent because the worst-case is the prompt
/// fires again next launch, which is annoying but not breaking.
fn write_marker() {
    let path = marker_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(&path, b"shown\n");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn family_contains_self() {
        assert!(FAMILY.contains(&SELF));
    }

    #[test]
    fn hint_for_includes_app_name() {
        let h = hint_for("mixr");
        assert!(h.contains("mixr"));
    }

    #[test]
    fn path_lookup_finds_a_common_binary() {
        // `ls` exists on every supported platform's PATH for our
        // test runners.
        assert!(path_lookup("ls") || path_lookup("ls.exe"));
    }

    #[test]
    fn path_lookup_misses_garbage() {
        assert!(!path_lookup("definitely-not-a-real-binary-xyz12345"));
    }
}
