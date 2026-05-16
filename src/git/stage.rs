//! `Pane::GitStatus` — a staging view: worktree changes split into "unstaged"
//! and "staged" lists, stage/unstage a file (or all), open a file's diff, commit
//! (optionally with an AI-written message). Shells out to `git`; degrades to
//! empty lists when `git` is missing / this isn't a repo.
//!
//! The "Git GUI" track's staging half (the commit-DAG browser is `graph.rs`).
//! Per-hunk staging already exists in the diff pane (`diff.rs`); this is the
//! file-level view + the commit flow.

use std::path::{Path, PathBuf};
use std::process::Command;

/// One file in the status lists.
#[derive(Debug, Clone)]
pub struct Entry {
    /// Porcelain status letter — `M` modified, `A` added, `D` deleted, `R` renamed,
    /// `C` copied, `?` untracked, `U` unmerged.
    pub status: char,
    /// Workspace-relative path (the new path for renames).
    pub rel: String,
    /// Absolute path.
    pub abs: PathBuf,
}

impl Entry {
    fn new(workspace: &Path, status: char, rel: &str) -> Self {
        Entry {
            status,
            rel: rel.to_string(),
            abs: workspace.join(rel),
        }
    }
}

/// `(unstaged, staged)` file lists from `git status --porcelain`. A file can be
/// in both (e.g. a staged change with further worktree edits).
pub fn lists(workspace: &Path) -> (Vec<Entry>, Vec<Entry>) {
    let out = match Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return (Vec::new(), Vec::new()),
    };
    let mut unstaged = Vec::new();
    let mut staged = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if line.len() < 3 {
            continue;
        }
        let b = line.as_bytes();
        let (x, y) = (b[0] as char, b[1] as char);
        let path_part = line[3..].trim();
        let rel = path_part
            .rsplit(" -> ")
            .next()
            .unwrap_or(path_part)
            .trim_matches('"');
        if x == '?' && y == '?' {
            unstaged.push(Entry::new(workspace, '?', rel));
            continue;
        }
        if x == 'U' || y == 'U' {
            unstaged.push(Entry::new(workspace, 'U', rel));
            continue;
        }
        if x != ' ' && x != '?' {
            staged.push(Entry::new(workspace, x, rel));
        }
        if y != ' ' && y != '?' {
            unstaged.push(Entry::new(workspace, y, rel));
        }
    }
    (unstaged, staged)
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
            .next()
            .unwrap_or("git failed")
            .to_string())
    }
}

pub fn stage(workspace: &Path, rel: &str) -> Result<(), String> {
    run(workspace, &["add", "--", rel])
}
pub fn unstage(workspace: &Path, rel: &str) -> Result<(), String> {
    // `restore --staged` is the modern spelling; fall back to `reset` on old git.
    run(workspace, &["restore", "--staged", "--", rel])
        .or_else(|_| run(workspace, &["reset", "-q", "HEAD", "--", rel]))
}
pub fn stage_all(workspace: &Path) -> Result<(), String> {
    run(workspace, &["add", "-A"])
}
pub fn unstage_all(workspace: &Path) -> Result<(), String> {
    run(workspace, &["restore", "--staged", "."]).or_else(|_| run(workspace, &["reset", "-q"]))
}

/// `git diff --cached` — the staged changes, for feeding an AI commit-message prompt.
pub fn staged_diff(workspace: &Path) -> String {
    Command::new("git")
        .args(["diff", "--cached", "--no-color"])
        .current_dir(workspace)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

// ── the pane ───────────────────────────────────────────────────────

pub struct GitStatusPane {
    pub workspace: PathBuf,
    pub branch: Option<String>,
    pub unstaged: Vec<Entry>,
    pub staged: Vec<Entry>,
    /// Index into the flattened list `[unstaged…, staged…]`.
    pub selected: usize,
    pub scroll: usize,
    /// Job id of an in-flight AI commit-message request (so the spinner shows).
    pub ai_msg_job: Option<u64>,
}

impl GitStatusPane {
    pub fn open(workspace: &Path) -> Self {
        let mut p = GitStatusPane {
            workspace: workspace.to_path_buf(),
            branch: None,
            unstaged: Vec::new(),
            staged: Vec::new(),
            selected: 0,
            scroll: 0,
            ai_msg_job: None,
        };
        p.refresh();
        p
    }

    pub fn tab_title(&self) -> String {
        "git status".to_string()
    }

    pub fn refresh(&mut self) {
        let (u, s) = lists(&self.workspace);
        self.unstaged = u;
        self.staged = s;
        self.branch = branch(&self.workspace);
        let n = self.flat_len();
        if n == 0 {
            self.selected = 0;
        } else if self.selected >= n {
            self.selected = n - 1;
        }
    }

    /// Re-point the cached workspace at a different repo root + refresh.
    /// Used when `App::switch_active_repo` flips to a different repo so the
    /// status list follows. Resets selection + scroll since the new repo's
    /// file list has nothing to do with the old one.
    pub fn retarget(&mut self, workspace: &Path) {
        self.workspace = workspace.to_path_buf();
        self.selected = 0;
        self.scroll = 0;
        self.refresh();
    }

    pub fn flat_len(&self) -> usize {
        self.unstaged.len() + self.staged.len()
    }

    /// `(entry, is_staged)` for the highlighted row.
    pub fn selected_entry(&self) -> Option<(&Entry, bool)> {
        if self.selected < self.unstaged.len() {
            Some((&self.unstaged[self.selected], false))
        } else {
            self.staged
                .get(self.selected - self.unstaged.len())
                .map(|e| (e, true))
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        let n = self.flat_len();
        if n == 0 {
            return;
        }
        self.selected = (self.selected as isize + delta).clamp(0, n as isize - 1) as usize;
    }
}

fn branch(workspace: &Path) -> Option<String> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_on_non_repo() {
        let d = tempfile::tempdir().unwrap();
        let (u, s) = lists(d.path());
        assert!(u.is_empty() && s.is_empty());
        let p = GitStatusPane::open(d.path());
        assert_eq!(p.flat_len(), 0);
        assert!(p.selected_entry().is_none());
    }
}
