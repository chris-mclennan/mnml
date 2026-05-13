//! Branch + worktree queries and operations — `git branch` / `checkout` /
//! `worktree list`. Shells out to `git`; queries degrade to empty lists, ops
//! return the first stderr line on failure.

use std::path::{Path, PathBuf};
use std::process::Command;

fn lines_of(workspace: &Path, args: &[&str]) -> Vec<String> {
    match Command::new("git")
        .args(args)
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

/// Local branch names.
pub fn local_branches(workspace: &Path) -> Vec<String> {
    lines_of(
        workspace,
        &["for-each-ref", "--format=%(refname:short)", "refs/heads"],
    )
}

/// Remote-tracking branch names (`origin/main`, …), minus the `*/HEAD` aliases.
pub fn remote_branches(workspace: &Path) -> Vec<String> {
    lines_of(
        workspace,
        &["for-each-ref", "--format=%(refname:short)", "refs/remotes"],
    )
    .into_iter()
    .filter(|b| !b.ends_with("/HEAD"))
    .collect()
}

/// The current branch name, or `None` on detached HEAD / not a repo.
pub fn current(workspace: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["symbolic-ref", "--short", "-q", "HEAD"])
        .current_dir(workspace)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!b.is_empty()).then_some(b)
}

/// One linked worktree.
#[derive(Debug, Clone)]
pub struct Worktree {
    pub path: PathBuf,
    /// Branch name, `"(detached)"`, or `"(bare)"`.
    pub label: String,
    /// True for the worktree we're currently in.
    pub is_current: bool,
}

/// `git worktree list --porcelain`, with the entry for `workspace` flagged.
pub fn worktrees(workspace: &Path) -> Vec<Worktree> {
    let out = match Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };
    let here = workspace.canonicalize().ok();
    let mut out_v = Vec::new();
    let mut path: Option<PathBuf> = None;
    let mut label = String::from("(detached)");
    let flush = |path: &mut Option<PathBuf>, label: &mut String, v: &mut Vec<Worktree>| {
        if let Some(p) = path.take() {
            let is_current = here
                .as_ref()
                .and_then(|h| p.canonicalize().ok().map(|c| &c == h))
                == Some(true);
            v.push(Worktree {
                path: p,
                label: std::mem::replace(label, String::from("(detached)")),
                is_current,
            });
        } else {
            *label = String::from("(detached)");
        }
    };
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(p) = line.strip_prefix("worktree ") {
            flush(&mut path, &mut label, &mut out_v);
            path = Some(PathBuf::from(p));
        } else if let Some(b) = line.strip_prefix("branch ") {
            label = b.strip_prefix("refs/heads/").unwrap_or(b).to_string();
        } else if line == "bare" {
            label = "(bare)".to_string();
        } else if line == "detached" {
            label = "(detached)".to_string();
        }
        // (`HEAD <sha>`, `locked`, … lines: ignored.)
    }
    flush(&mut path, &mut label, &mut out_v);
    out_v
}

fn run(workspace: &Path, args: &[&str]) -> Result<(), String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(workspace)
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git failed")
            .to_string())
    }
}

/// `git checkout <branch>` — switch to an existing local branch.
pub fn checkout(workspace: &Path, branch: &str) -> Result<(), String> {
    run(workspace, &["checkout", branch])
}
/// `git checkout --track <remote>` — create + switch to a local branch tracking
/// a remote one (git derives the local name).
pub fn checkout_track(workspace: &Path, remote: &str) -> Result<(), String> {
    run(workspace, &["checkout", "--track", remote])
}
/// `git checkout -b <name>` — create + switch to a new branch off the current HEAD.
pub fn create(workspace: &Path, name: &str) -> Result<(), String> {
    run(workspace, &["checkout", "-b", name])
}
/// `git branch -D <name>` — force-delete a local branch (the rail's confirm
/// prompt already gated this on a name match; soft-delete would refuse
/// unmerged branches and surface as a generic git error).
pub fn delete_branch(workspace: &Path, name: &str) -> Result<(), String> {
    run(workspace, &["branch", "-D", name])
}
/// `git worktree remove <path>` — drop a linked worktree. Same confirm-gating
/// principle as branch delete.
pub fn worktree_remove(workspace: &Path, path: &Path) -> Result<(), String> {
    run(workspace, &["worktree", "remove", &path.to_string_lossy()])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_on_non_repo() {
        let d = tempfile::tempdir().unwrap();
        assert!(local_branches(d.path()).is_empty());
        assert!(remote_branches(d.path()).is_empty());
        assert!(worktrees(d.path()).is_empty());
        assert!(current(d.path()).is_none());
    }
}
