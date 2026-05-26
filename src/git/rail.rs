//! The persistent **GIT section** in the left rail — local branches + linked
//! worktrees, with click-to-checkout / click-to-open-shell-in-worktree. Sibling
//! to the `WORKSPACE` (tree) section that's been the rail's only content so
//! far. The state lives on [`crate::app::App`]; this module owns the data
//! shape + the refresh logic (which shells out to `git` via the existing
//! [`crate::git::branch`] helpers).
//!
//! Cursor counts only interactive rows (branches + worktrees) — the
//! sub-section labels (`branches`, `worktrees`) the renderer draws are dim
//! cues, not selectable. The rail's keyboard focus tracks which section
//! (workspace vs git) keys go to; the renderer paints the cursor on that one.

use std::path::Path;
use std::time::Instant;

use super::branch::{self, Worktree};

/// A row in the git rail you can click / Enter on. The renderer maps these
/// to (rect, hit) pairs in `PaneRects` for mouse routing; key navigation
/// uses [`GitRail::selected`] to ask "what's the cursor on now."
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitRailHit {
    /// Index into `GitRail::branches`.
    Branch(usize),
    /// Index into `GitRail::worktrees`.
    Worktree(usize),
    /// Index into `GitRail::pulls`.
    Pull(usize),
    /// The `+ N more` / `show less` toggle row at the end of the
    /// branches sub-section — flips `App.git_branches_expanded`.
    /// No payload: it's a singleton row, not a selectable entry.
    ToggleBranches,
}

#[derive(Debug, Clone)]
pub struct BranchRow {
    pub name: String,
    /// `current_branch == Some(name)` (the `●` glyph row).
    pub is_current: bool,
}

/// One open PR/MR for the *current* repo. The rail section consults
/// the per-host caches `App::bitbucket_pull_requests` / `github_pull_requests`
/// / `gitlab_merge_requests` / `azdevops_pull_requests` and projects to
/// this minimal shape so the renderer doesn't have to know about hosts.
#[derive(Debug, Clone)]
pub struct PullRow {
    /// Short host tag for the glyph color (`"BB"`, `"GH"`, `"GL"`, `"AZ"`).
    pub host_tag: &'static str,
    /// Display label — short identifier (e.g. `"#42"` or `"!17"`).
    pub number_label: String,
    /// PR title.
    pub title: String,
    /// `source_branch` — useful for spot-checking if the PR is for the
    /// branch the user is on.
    pub source_branch: Option<String>,
    /// Set on the row that matches `GitRail::current_branch` so the
    /// renderer can highlight it (mirrors the `●` mark on the active
    /// branch row).
    pub is_current_branch: bool,
    /// What `Enter` / click opens.
    pub web_url: String,
}

#[derive(Debug)]
pub struct GitRail {
    pub branches: Vec<BranchRow>,
    pub worktrees: Vec<Worktree>,
    /// Open PRs/MRs for the current repo (best-effort match by remote URL
    /// against the configured SCM hosts). Empty when there's no recognized
    /// remote, when caches are still loading, or when there are no open PRs.
    pub pulls: Vec<PullRow>,
    /// `git symbolic-ref --short HEAD`, or `None` on detached HEAD / not a repo.
    pub current_branch: Option<String>,
    /// Cursor over the interactive rows: branches → worktrees → pulls,
    /// in that order. `row_count() == branches.len() + worktrees.len() + pulls.len()`.
    pub cursor: usize,
    /// First visible row in the section (set by the view to keep `cursor` on
    /// screen). Cleared on every refresh.
    pub scroll: usize,
    /// When `refresh` last ran. `None` ⇒ never refreshed.
    pub last_refresh: Option<Instant>,
}

impl Default for GitRail {
    fn default() -> Self {
        GitRail::empty()
    }
}

impl GitRail {
    pub fn empty() -> Self {
        GitRail {
            branches: Vec::new(),
            worktrees: Vec::new(),
            pulls: Vec::new(),
            current_branch: None,
            cursor: 0,
            scroll: 0,
            last_refresh: None,
        }
    }

    /// Re-query `git`. Cheap enough to call on any git-change (it's just two
    /// `git` subprocess calls); we cache the result here so a render frame
    /// reads from memory.
    pub fn refresh(&mut self, workspace: &Path) {
        let current = branch::current(workspace);
        self.branches = branch::local_branches(workspace)
            .into_iter()
            .map(|name| BranchRow {
                is_current: Some(&name) == current.as_ref(),
                name,
            })
            .collect();
        self.worktrees = branch::worktrees(workspace);
        self.current_branch = current;
        let max = self.row_count().saturating_sub(1);
        self.cursor = self.cursor.min(max);
        self.scroll = 0;
        self.last_refresh = Some(Instant::now());
    }

    /// Total interactive (selectable) rows: branches + worktrees + pulls.
    /// Sub-section labels don't count.
    pub fn row_count(&self) -> usize {
        self.branches.len() + self.worktrees.len() + self.pulls.len()
    }
    pub fn is_empty(&self) -> bool {
        self.row_count() == 0
    }
    pub fn move_up(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
    }
    pub fn move_down(&mut self) {
        let max = self.row_count().saturating_sub(1);
        self.cursor = (self.cursor + 1).min(max);
    }
    pub fn set_cursor(&mut self, idx: usize) {
        let max = self.row_count().saturating_sub(1);
        self.cursor = idx.min(max);
    }

    /// What `cursor` points at, or `None` if the rail is empty.
    pub fn selected(&self) -> Option<GitRailHit> {
        let nb = self.branches.len();
        let nw = self.worktrees.len();
        if self.cursor < nb {
            Some(GitRailHit::Branch(self.cursor))
        } else if self.cursor < nb + nw {
            Some(GitRailHit::Worktree(self.cursor - nb))
        } else if self.cursor < nb + nw + self.pulls.len() {
            Some(GitRailHit::Pull(self.cursor - nb - nw))
        } else {
            None
        }
    }

    /// Move `cursor` to a [`GitRailHit`] (used by the mouse handler — `set_cursor`
    /// by row index, but the hit-test gives back a typed hit, so this is the
    /// adapter).
    pub fn focus(&mut self, hit: GitRailHit) {
        let nb = self.branches.len();
        let nw = self.worktrees.len();
        let idx = match hit {
            GitRailHit::Branch(i) => i.min(nb.saturating_sub(1)),
            GitRailHit::Worktree(i) => nb + i.min(nw.saturating_sub(1)),
            GitRailHit::Pull(i) => nb + nw + i.min(self.pulls.len().saturating_sub(1)),
            // ToggleBranches isn't a selectable row — caller should
            // intercept before reaching here, but if it gets through
            // (e.g. via a future code path), leave cursor untouched.
            GitRailHit::ToggleBranches => return,
        };
        self.set_cursor(idx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rail_with(branches: &[&str], current: Option<&str>, worktrees: usize) -> GitRail {
        let mut r = GitRail::empty();
        r.current_branch = current.map(str::to_string);
        r.branches = branches
            .iter()
            .map(|b| BranchRow {
                is_current: current == Some(b),
                name: b.to_string(),
            })
            .collect();
        r.worktrees = (0..worktrees)
            .map(|i| Worktree {
                path: std::path::PathBuf::from(format!("/tmp/wt{i}")),
                label: format!("wt{i}"),
                is_current: i == 0,
            })
            .collect();
        r
    }

    #[test]
    fn selected_maps_cursor_to_hit() {
        let mut r = rail_with(&["main", "feature/x", "feature/y"], Some("main"), 2);
        assert_eq!(r.row_count(), 5);
        assert_eq!(r.selected(), Some(GitRailHit::Branch(0)));
        r.move_down();
        r.move_down();
        r.move_down();
        assert_eq!(r.selected(), Some(GitRailHit::Worktree(0)));
        r.move_down();
        assert_eq!(r.selected(), Some(GitRailHit::Worktree(1)));
        // Move past the end clamps.
        r.move_down();
        assert_eq!(r.selected(), Some(GitRailHit::Worktree(1)));
        r.move_up();
        r.move_up();
        r.move_up();
        r.move_up();
        r.move_up();
        r.move_up();
        assert_eq!(r.selected(), Some(GitRailHit::Branch(0)));
    }

    #[test]
    fn empty_rail_has_no_selection() {
        let r = GitRail::empty();
        assert!(r.is_empty());
        assert_eq!(r.selected(), None);
    }

    #[test]
    fn focus_jumps_to_typed_hit() {
        let mut r = rail_with(&["main", "feat"], Some("main"), 3);
        r.focus(GitRailHit::Worktree(2));
        assert_eq!(r.selected(), Some(GitRailHit::Worktree(2)));
        r.focus(GitRailHit::Branch(1));
        assert_eq!(r.selected(), Some(GitRailHit::Branch(1)));
        // Out-of-range hits clamp.
        r.focus(GitRailHit::Branch(99));
        assert_eq!(r.selected(), Some(GitRailHit::Branch(1)));
    }
}
