//! Well-known destinations — Home, Downloads, Documents, Pictures,
//! Videos, Music, mounted volumes, configured workspaces, recent dirs.
//!
//! #files item 3. Feeds the Files pane's breadcrumb dropdown, and is
//! deliberately a standalone module because `ActivitySection::Places`
//! wants exactly this list: building it here means Places is mostly done
//! when it gets built.
//!
//! Every entry is FILTERED FOR EXISTENCE. A dropdown row for a directory
//! that is not there is a dead click, and `~/Videos` genuinely does not
//! exist on plenty of machines.

use std::path::{Path, PathBuf};

/// Which group a destination belongs to, for section headers in the
/// picker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    Standard,
    Volume,
    Workspace,
    Recent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    pub label: String,
    pub path: PathBuf,
    pub group: Group,
    /// Nerd Font glyph; callers fall back to their own ASCII when
    /// `[ui] ascii_icons` is on.
    pub glyph: &'static str,
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// The XDG-ish user directories, in the order a file manager lists them.
///
/// Hardcoded names rather than reading `~/.config/user-dirs.dirs`: that
/// file is Linux-only, and on macOS — the platform this is being built on
/// — the English names are what exists on disk regardless of the UI
/// language. A localised-name lookup is a later refinement, not a
/// correctness issue, since anything missing is simply omitted.
pub fn standard_dirs() -> Vec<Place> {
    let Some(h) = home() else {
        return Vec::new();
    };
    let rows: [(&str, &str, &'static str); 7] = [
        ("Home", "", "\u{f015}"),
        ("Desktop", "Desktop", "\u{f108}"),
        ("Downloads", "Downloads", "\u{f019}"),
        ("Documents", "Documents", "\u{f0f6}"),
        ("Pictures", "Pictures", "\u{f03e}"),
        ("Music", "Music", "\u{f001}"),
        ("Videos", "Movies", "\u{f03d}"),
    ];
    rows.iter()
        .filter_map(|(label, sub, glyph)| {
            let p = if sub.is_empty() {
                h.clone()
            } else {
                h.join(sub)
            };
            p.is_dir().then(|| Place {
                label: (*label).to_string(),
                path: p,
                group: Group::Standard,
                glyph,
            })
        })
        .collect()
}

/// Mounted volumes.
///
/// macOS lists them under `/Volumes`; Linux uses `/media/<user>` and
/// `/run/media/<user>`. The startup disk appears in `/Volumes` on macOS as
/// a symlink to `/`, which is worth keeping — it is how you reach the root
/// of the boot disk by name.
pub fn volumes() -> Vec<Place> {
    let mut roots: Vec<PathBuf> = vec![PathBuf::from("/Volumes")];
    if let Some(user) = std::env::var_os("USER") {
        roots.push(PathBuf::from("/media").join(&user));
        roots.push(PathBuf::from("/run/media").join(&user));
    }
    let mut out = Vec::new();
    for root in roots {
        let Ok(rd) = std::fs::read_dir(&root) else {
            continue;
        };
        for ent in rd.flatten() {
            let p = ent.path();
            if !p.is_dir() {
                continue;
            }
            let name = ent.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            out.push(Place {
                label: name,
                path: p,
                group: Group::Volume,
                glyph: "\u{f0a0}",
            });
        }
    }
    out.sort_by_key(|a| a.label.to_lowercase());
    out
}

/// Everything, in menu order: standard dirs, volumes, workspaces, recent.
///
/// `workspaces` and `recents` come from the caller because they live on
/// `App` — keeping them as parameters is what lets this module stay
/// testable without constructing an `App`.
pub fn all(workspaces: &[(String, PathBuf)], recents: &[PathBuf]) -> Vec<Place> {
    let mut out = standard_dirs();
    out.extend(volumes());
    out.extend(
        workspaces
            .iter()
            .filter(|(_, p)| p.is_dir())
            .map(|(label, p)| Place {
                label: label.clone(),
                path: p.clone(),
                group: Group::Workspace,
                glyph: "\u{f4d5}",
            }),
    );
    // Recents last and de-duplicated against everything above: a
    // directory you visited that is ALSO your Downloads folder should not
    // appear twice.
    let mut seen: Vec<&Path> = out.iter().map(|p| p.path.as_path()).collect();
    let mut recent_rows = Vec::new();
    for r in recents {
        if !r.is_dir() || seen.contains(&r.as_path()) {
            continue;
        }
        seen.push(r.as_path());
        recent_rows.push(Place {
            label: r
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| r.display().to_string()),
            path: r.clone(),
            group: Group::Recent,
            glyph: "\u{f017}",
        });
    }
    out.extend(recent_rows);
    out
}

/// Ancestor chain for a breadcrumb, root-first, including `dir` itself.
///
/// Returns `(label, path)` pairs. The root renders as `/` rather than an
/// empty label, which is what `file_name()` would give it.
pub fn breadcrumb(dir: &Path) -> Vec<(String, PathBuf)> {
    let mut chain: Vec<(String, PathBuf)> = Vec::new();
    let mut cur = Some(dir);
    while let Some(p) = cur {
        let label = p
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| p.display().to_string());
        chain.push((label, p.to_path_buf()));
        cur = p.parent();
    }
    chain.reverse();
    chain
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_dirs_only_lists_directories_that_exist() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _h = crate::EnvGuard::set("HOME", d.path());
        // Only Downloads exists.
        std::fs::create_dir(d.path().join("Downloads")).unwrap();

        let places = standard_dirs();
        let labels: Vec<&str> = places.iter().map(|p| p.label.as_str()).collect();
        assert!(labels.contains(&"Home"), "Home always exists: {labels:?}");
        assert!(labels.contains(&"Downloads"), "{labels:?}");
        assert!(
            !labels.contains(&"Pictures"),
            "listed a directory that does not exist — a dead click: {labels:?}"
        );
    }

    #[test]
    fn standard_dirs_are_in_menu_order_not_alphabetical() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _h = crate::EnvGuard::set("HOME", d.path());
        for n in ["Desktop", "Downloads", "Documents"] {
            std::fs::create_dir(d.path().join(n)).unwrap();
        }
        let labels: Vec<String> = standard_dirs().into_iter().map(|p| p.label).collect();
        assert_eq!(
            labels,
            vec!["Home", "Desktop", "Downloads", "Documents"],
            "alphabetical order would put Documents before Downloads"
        );
    }

    #[test]
    fn breadcrumb_is_root_first_and_includes_the_directory_itself() {
        let chain = breadcrumb(Path::new("/a/b/c"));
        let labels: Vec<&str> = chain.iter().map(|(l, _)| l.as_str()).collect();
        assert_eq!(labels, vec!["/", "a", "b", "c"]);
        assert_eq!(chain.last().unwrap().1, PathBuf::from("/a/b/c"));
        // Each entry's path must be the real ancestor, or clicking a
        // segment navigates somewhere unrelated.
        assert_eq!(chain[1].1, PathBuf::from("/a"));
        assert_eq!(chain[2].1, PathBuf::from("/a/b"));
    }

    #[test]
    fn breadcrumb_of_the_root_is_just_the_root() {
        let chain = breadcrumb(Path::new("/"));
        assert_eq!(chain.len(), 1);
        assert_eq!(chain[0].0, "/");
    }

    /// A recent directory that is already listed above must not appear
    /// twice.
    #[test]
    fn recents_are_deduplicated_against_the_other_groups() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _h = crate::EnvGuard::set("HOME", d.path());
        let dl = d.path().join("Downloads");
        std::fs::create_dir(&dl).unwrap();

        let places = all(&[], std::slice::from_ref(&dl));
        let hits = places.iter().filter(|p| p.path == dl).count();
        assert_eq!(hits, 1, "Downloads appeared {hits} times");
    }

    #[test]
    fn a_workspace_that_no_longer_exists_is_dropped() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _h = crate::EnvGuard::set("HOME", d.path());
        let gone = d.path().join("deleted-project");
        let places = all(&[("Gone".into(), gone.clone())], &[]);
        assert!(
            !places.iter().any(|p| p.path == gone),
            "listed a workspace directory that has been deleted"
        );
    }
}
