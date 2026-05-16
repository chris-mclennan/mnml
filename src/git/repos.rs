//! Multi-repo workspace discovery.
//!
//! A "workspace" can contain multiple git repos (e.g. a `~/Projects` folder
//! with several sibling repo dirs). `discover_repos` walks the workspace
//! looking for `.git/` markers (capped at a small depth to avoid
//! pathological perf on huge trees), returning a sorted list of repo roots.
//!
//! Rule: if the workspace root itself is a git repo, that's the *only*
//! entry — we don't descend into nested sub-repos in that case (matches
//! the user's typical "edit one repo" intent). Otherwise, return every
//! direct or near-direct git repo found below it.

use std::path::{Path, PathBuf};

/// One repo found inside the workspace.
#[derive(Debug, Clone)]
pub struct RepoEntry {
    /// Absolute path to the repo root (the directory that contains `.git/`).
    pub path: PathBuf,
    /// Human-readable name — the path's basename, or `"."` for the
    /// workspace root itself.
    pub name: String,
    /// True when the repo IS the workspace root (the single-repo case).
    pub is_workspace_root: bool,
}

/// Bounded walk for nested `.git/` directories. We stop descending into
/// any directory once we find a `.git/` (so a repo's own internal dirs
/// don't show as sub-repos), and we cap depth so a workspace containing
/// some monster `node_modules/`-style tree can't make startup hang.
const MAX_DEPTH: usize = 3;

/// Walk `workspace` and return every repo found.
///
/// Order: workspace root first (when it's a repo), then discovered
/// sub-repos sorted by name (case-insensitive).
pub fn discover_repos(workspace: &Path) -> Vec<RepoEntry> {
    // The "workspace itself is a repo" case wins outright.
    if workspace.join(".git").exists() {
        let name = workspace
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| ".".to_string());
        return vec![RepoEntry {
            path: workspace.to_path_buf(),
            name,
            is_workspace_root: true,
        }];
    }
    let mut out: Vec<RepoEntry> = Vec::new();
    walk(workspace, 0, &mut out);
    out.sort_by_key(|r| r.name.to_lowercase());
    out
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<RepoEntry>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        // Skip dot-dirs (.git itself, .vscode, .mnml, etc.) and common
        // huge non-source trees. Crude but enough for the MVP.
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name == "node_modules" || name == "target" {
            continue;
        }
        if path.join(".git").exists() {
            out.push(RepoEntry {
                path: path.clone(),
                name: name.clone(),
                is_workspace_root: false,
            });
            // Don't recurse into a repo we already found — its own
            // sub-modules / nested-repos aren't picked up by the MVP.
            continue;
        }
        walk(&path, depth + 1, out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_is_a_repo_returns_just_itself() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join(".git")).unwrap();
        // Add a sub-dir that's also a repo — it should NOT be discovered.
        let sub = d.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        std::fs::create_dir(sub.join(".git")).unwrap();
        let repos = discover_repos(d.path());
        assert_eq!(repos.len(), 1);
        assert!(repos[0].is_workspace_root);
        assert_eq!(repos[0].path, d.path());
    }

    #[test]
    fn discovers_sibling_repos() {
        let d = tempfile::tempdir().unwrap();
        // workspace has no `.git/` of its own.
        for name in ["alpha", "beta", "gamma"] {
            let p = d.path().join(name);
            std::fs::create_dir(&p).unwrap();
            std::fs::create_dir(p.join(".git")).unwrap();
        }
        // Plus a non-repo dir that should be ignored.
        std::fs::create_dir(d.path().join("just-a-dir")).unwrap();
        let repos = discover_repos(d.path());
        assert_eq!(repos.len(), 3);
        assert_eq!(repos[0].name, "alpha");
        assert_eq!(repos[1].name, "beta");
        assert_eq!(repos[2].name, "gamma");
        assert!(!repos.iter().any(|r| r.is_workspace_root));
    }

    #[test]
    fn skips_dot_and_node_modules() {
        let d = tempfile::tempdir().unwrap();
        // A `.mnml/` dir (should be skipped) with a fake .git inside.
        let mn = d.path().join(".mnml");
        std::fs::create_dir(&mn).unwrap();
        std::fs::create_dir(mn.join(".git")).unwrap();
        // A `node_modules/`-style tree (skipped).
        let nm = d.path().join("node_modules").join("pkg");
        std::fs::create_dir_all(&nm).unwrap();
        std::fs::create_dir(nm.join(".git")).unwrap();
        // A real one.
        let real = d.path().join("real");
        std::fs::create_dir(&real).unwrap();
        std::fs::create_dir(real.join(".git")).unwrap();
        let repos = discover_repos(d.path());
        assert_eq!(repos.len(), 1);
        assert_eq!(repos[0].name, "real");
    }
}
