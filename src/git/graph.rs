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
    /// Index into the *virtual* list (WIP row + commits). When
    /// `has_wip` is true, `0 = WIP, 1..=commits.len() = commits[i-1]`;
    /// otherwise `0..commits.len() = commits[i]`.
    pub selected: usize,
    /// Top visible row in the virtual list (the renderer keeps
    /// `selected` on screen).
    pub scroll: usize,
    pub detail: Option<CommitDetail>,
    /// `/` filter — accumulating hash prefix to fuzzy-jump to a commit.
    /// Empty when inactive. The renderer shows a chip in the header row when
    /// non-empty; `tui.rs` routes printable keys / Backspace / Enter / Esc.
    pub hash_filter: String,
    /// True while the filter is actively accepting keystrokes (the `/` chord
    /// was pressed and we haven't pressed Enter/Esc yet).
    pub hash_filter_mode: bool,
    /// True when the working tree has uncommitted changes — drives the
    /// "WIP" virtual row rendered above commits[0]. Recomputed on
    /// `open` / `refresh` / `retarget` from `git status --porcelain`.
    pub has_wip: bool,
}

/// How many commits to load (across all refs). Plenty for browsing; bump later
/// if "load more" becomes a thing.
const LIMIT: usize = 800;

impl GitGraphPane {
    pub fn open(workspace: &Path) -> Self {
        let commits = log::load(workspace, LIMIT);
        let has_wip = working_tree_has_changes(workspace);
        let mut p = GitGraphPane {
            workspace: workspace.to_path_buf(),
            commits,
            // Start at row 0 — that's the WIP row when changes exist,
            // otherwise the newest commit. Either way, the user opens
            // the graph to see what's been happening lately.
            selected: 0,
            scroll: 0,
            detail: None,
            hash_filter: String::new(),
            hash_filter_mode: false,
            has_wip,
        };
        p.reload_detail();
        p
    }

    /// Total virtual rows = commits + maybe a WIP row at the top.
    pub fn total_rows(&self) -> usize {
        self.commits.len() + usize::from(self.has_wip)
    }

    /// True when the WIP virtual row sits at `selected`.
    pub fn is_wip_selected(&self) -> bool {
        self.has_wip && self.selected == 0
    }

    /// Returns the index into `self.commits` for the current selection,
    /// or `None` when the WIP row is selected. Use this to translate
    /// virtual-list selection back to a real commit.
    pub fn commit_index(&self) -> Option<usize> {
        if self.is_wip_selected() {
            return None;
        }
        let offset = usize::from(self.has_wip);
        let idx = self.selected.checked_sub(offset)?;
        if idx < self.commits.len() {
            Some(idx)
        } else {
            None
        }
    }

    /// Find the first commit whose short hash (or full hash, ASCII case-
    /// insensitive) begins with `prefix`. Empty prefix ⇒ None. Returns
    /// the **commit-list** index (not the virtual row), so callers using
    /// `jump_to` need to add `has_wip as usize` to land on the right row.
    pub fn find_by_hash_prefix(&self, prefix: &str) -> Option<usize> {
        if prefix.is_empty() {
            return None;
        }
        let needle = prefix.to_ascii_lowercase();
        self.commits
            .iter()
            .position(|c| c.hash.to_ascii_lowercase().starts_with(&needle))
    }

    /// Set the selection to the virtual-row index `idx` (0 = WIP if
    /// present, then commits). Returns true on change.
    pub fn jump_to(&mut self, idx: usize) -> bool {
        let total = self.total_rows();
        if total == 0 {
            return false;
        }
        let clamped = idx.min(total - 1);
        if clamped == self.selected {
            return false;
        }
        self.selected = clamped;
        self.reload_detail();
        true
    }

    /// Jump to a commit by its index in `self.commits`. Adjusts for the
    /// WIP row offset.
    pub fn jump_to_commit(&mut self, commit_idx: usize) -> bool {
        self.jump_to(commit_idx + usize::from(self.has_wip))
    }

    pub fn tab_title(&self) -> String {
        "git graph".to_string()
    }

    /// Re-run `git log` (after a commit, fetch, etc.), keeping the selection in range.
    pub fn refresh(&mut self) {
        self.commits = log::load(&self.workspace, LIMIT);
        self.has_wip = working_tree_has_changes(&self.workspace);
        let total = self.total_rows();
        if total == 0 {
            self.selected = 0;
        } else if self.selected >= total {
            self.selected = total - 1;
        }
        self.reload_detail();
    }

    /// Re-point the cached workspace at a different repo root + reload.
    /// Used when `App::switch_active_repo` flips repos so the graph follows.
    /// Resets selection + scroll since the new repo's commit history is
    /// entirely different.
    pub fn retarget(&mut self, workspace: &Path) {
        self.workspace = workspace.to_path_buf();
        self.selected = 0;
        self.scroll = 0;
        self.commits = log::load(&self.workspace, LIMIT);
        self.has_wip = working_tree_has_changes(&self.workspace);
        self.reload_detail();
    }

    /// Move the selection by `delta` rows (clamped), reloading the detail panel.
    pub fn move_selection(&mut self, delta: isize) {
        let total = self.total_rows();
        if total == 0 {
            return;
        }
        let n = total as isize;
        let next = (self.selected as isize + delta).clamp(0, n - 1) as usize;
        if next != self.selected {
            self.selected = next;
            self.reload_detail();
        }
    }

    /// The commit at the current selection — `None` when the WIP row
    /// is selected (or no commits loaded).
    pub fn selected_commit(&self) -> Option<&Commit> {
        let idx = self.commit_index()?;
        self.commits.get(idx)
    }

    fn reload_detail(&mut self) {
        let idx = self.commit_index();
        self.detail = idx.and_then(|i| self.commits.get(i)).map(|c| CommitDetail {
            hash: c.hash.clone(),
            message: log::full_message(&self.workspace, &c.hash),
            files: log::changed_files(&self.workspace, &c.hash),
        });
    }
}

/// True when `git status --porcelain` reports any uncommitted change
/// (untracked / modified / staged / conflict). Cheap — runs once per
/// graph-pane open / refresh. Falls back to `false` when git is missing
/// or this isn't a repo.
fn working_tree_has_changes(workspace: &Path) -> bool {
    use std::process::Command;
    match Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace)
        .output()
    {
        Ok(out) if out.status.success() => !out.stdout.is_empty(),
        _ => false,
    }
}
