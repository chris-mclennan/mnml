//! Lightweight `git status --porcelain` reader — no libgit2, shells out to `git`.
//! Always succeeds: if `git` is missing or this isn't a repo, the branch is `None`
//! and all counts are zero. Cached with a short TTL so it's cheap to poll every tick.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const TTL: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileState {
    Modified,
    Staged,
    Untracked,
    Conflicted,
}

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub branch: Option<String>,
    pub modified: usize,
    pub staged: usize,
    pub untracked: usize,
    pub conflicts: usize,
    /// Path → state, for the tree tint. Keys are absolute (workspace-joined).
    pub files: HashMap<PathBuf, FileState>,
}

impl Snapshot {
    pub fn change_count(&self) -> usize {
        self.modified + self.staged + self.untracked + self.conflicts
    }
}

#[derive(Debug)]
pub struct GitStatus {
    workspace: PathBuf,
    snapshot: Snapshot,
    probed_at: Option<Instant>,
}

impl GitStatus {
    pub fn new(workspace: &Path) -> Self {
        let mut g = GitStatus { workspace: workspace.to_path_buf(), snapshot: Snapshot::default(), probed_at: None };
        g.refresh();
        g
    }

    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }

    /// Re-probe if the cache is stale; cheap to call every event-loop tick.
    pub fn tick(&mut self) {
        let stale = self.probed_at.map(|t| t.elapsed() >= TTL).unwrap_or(true);
        if stale {
            self.refresh();
        }
    }

    pub fn refresh(&mut self) {
        self.snapshot = probe(&self.workspace);
        self.probed_at = Some(Instant::now());
    }
}

fn probe(workspace: &Path) -> Snapshot {
    let mut snap = Snapshot::default();

    // Branch (gracefully degrade on detached HEAD / not a repo).
    if let Ok(out) = Command::new("git")
        .args(["symbolic-ref", "--short", "-q", "HEAD"])
        .current_dir(workspace)
        .output()
        && out.status.success() {
            let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !b.is_empty() {
                snap.branch = Some(b);
            }
        }
    if snap.branch.is_none()
        && let Ok(out) = Command::new("git")
            .args(["rev-parse", "--short", "HEAD"])
            .current_dir(workspace)
            .output()
            && out.status.success() {
                let h = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !h.is_empty() {
                    snap.branch = Some(format!("@{h}"));
                }
            }

    // Status.
    if let Ok(out) = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace)
        .output()
        && out.status.success() {
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                if line.len() < 3 {
                    continue;
                }
                let bytes = line.as_bytes();
                let (x, y) = (bytes[0] as char, bytes[1] as char);
                let path_part = line[3..].trim();
                // handle "old -> new" for renames; take the new path
                let rel = path_part.rsplit(" -> ").next().unwrap_or(path_part).trim_matches('"');
                let abs = workspace.join(rel);
                let state = if x == 'U' || y == 'U' || (x == 'D' && y == 'D') || (x == 'A' && y == 'A') {
                    snap.conflicts += 1;
                    FileState::Conflicted
                } else if x == '?' && y == '?' {
                    snap.untracked += 1;
                    FileState::Untracked
                } else {
                    if x != ' ' && x != '?' {
                        snap.staged += 1;
                    }
                    if y != ' ' && y != '?' {
                        snap.modified += 1;
                    }
                    if y != ' ' { FileState::Modified } else { FileState::Staged }
                };
                snap.files.insert(abs, state);
            }
        }

    snap
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_repo_is_quiet() {
        let d = tempfile::tempdir().unwrap();
        let g = GitStatus::new(d.path());
        assert!(g.snapshot().branch.is_none());
        assert_eq!(g.snapshot().change_count(), 0);
    }
}
