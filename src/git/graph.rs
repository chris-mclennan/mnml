//! `Pane::GitGraph` — a graphical-Git-GUI-style commit-DAG view: the lane graph + commit
//! list on the left, the selected commit's details (full message + changed
//! files) below it. Built on [`super::log`]. Read-only for now; "stage & commit
//! (with Claude / Codex)" and worktree management are follow-ups (see
//! `.local/PLAN.md` — "Git GUI").

use std::path::{Path, PathBuf};

use super::log::{self, Commit};

/// Details for the currently-selected commit (loaded lazily as the selection moves).
#[derive(Debug, Clone)]
pub struct CommitDetail {
    pub hash: String,
    /// Full commit message body (`git show -s --format=%B`).
    pub message: String,
    /// `(status-letter, path)` for each file the commit touched.
    pub files: Vec<(String, String)>,
}

pub struct GitGraphPane {
    pub workspace: PathBuf,
    pub commits: Vec<Commit>,
    /// Index into `commits` of the highlighted row.
    pub selected: usize,
    /// Top visible commit row (the renderer keeps `selected` on screen).
    pub scroll: usize,
    pub detail: Option<CommitDetail>,
}

/// How many commits to load (across all refs). Plenty for browsing; bump later
/// if "load more" becomes a thing.
const LIMIT: usize = 800;

impl GitGraphPane {
    pub fn open(workspace: &Path) -> Self {
        let commits = log::load(workspace, LIMIT);
        let mut p = GitGraphPane {
            workspace: workspace.to_path_buf(),
            commits,
            selected: 0,
            scroll: 0,
            detail: None,
        };
        p.reload_detail();
        p
    }

    pub fn tab_title(&self) -> String {
        "git graph".to_string()
    }

    /// Re-run `git log` (after a commit, fetch, etc.), keeping the selection in range.
    pub fn refresh(&mut self) {
        self.commits = log::load(&self.workspace, LIMIT);
        if self.selected >= self.commits.len() {
            self.selected = self.commits.len().saturating_sub(1);
        }
        self.reload_detail();
    }

    /// Move the selection by `delta` rows (clamped), reloading the detail panel.
    pub fn move_selection(&mut self, delta: isize) {
        if self.commits.is_empty() {
            return;
        }
        let n = self.commits.len() as isize;
        let next = (self.selected as isize + delta).clamp(0, n - 1) as usize;
        if next != self.selected {
            self.selected = next;
            self.reload_detail();
        }
    }

    pub fn selected_commit(&self) -> Option<&Commit> {
        self.commits.get(self.selected)
    }

    fn reload_detail(&mut self) {
        self.detail = self.commits.get(self.selected).map(|c| CommitDetail {
            hash: c.hash.clone(),
            message: log::full_message(&self.workspace, &c.hash),
            files: log::changed_files(&self.workspace, &c.hash),
        });
    }
}
