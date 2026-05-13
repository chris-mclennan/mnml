//! The right-click context menu — a small floating list of actions, anchored at
//! the click. Opened from the file tree (on a file / dir) or a bufferline tab;
//! steals key + mouse input like the picker until dismissed. `App` owns an
//! `Option<ContextMenu>` and maps the chosen [`MenuAction`] to an effect.

use std::path::PathBuf;

use crate::layout::PaneId;

/// What a menu entry does when chosen.
#[derive(Debug, Clone)]
pub enum MenuAction {
    /// Open the file (in the focused leaf).
    OpenPath(PathBuf),
    /// Open the file in a new split to the right.
    OpenInSplit(PathBuf),
    /// `open -R <path>` (macOS Finder reveal); a no-op elsewhere.
    RevealInFinder(PathBuf),
    /// Hand `path` to the OS's default app — `open` / `xdg-open` / `start`.
    OpenExternally(PathBuf),
    /// Copy `text` (a workspace-relative path) to the clipboard.
    CopyPath(String),
    /// Run a registered command by id (e.g. `tree.refresh`).
    Command(&'static str),
    CloseTab(PaneId),
    CloseOtherTabs(PaneId),
    CloseAllTabs,
    /// Prompt for a name and create an empty file in `parent_dir`.
    NewFile(PathBuf),
    /// Prompt for a name and create an empty directory in `parent_dir`.
    NewFolder(PathBuf),
    /// Prompt for a new name and rename `path` (kept in the same dir).
    Rename(PathBuf),
    /// Prompt for the filename as a confirmation; on exact match, delete
    /// `path` (`rm` for a file, `rm -rf` for a directory).
    Delete(PathBuf),
    /// Git rail — checkout an existing local branch.
    GitCheckoutBranch(String),
    /// Git rail — prompt for a new branch name (off the named base; first cut
    /// just branches off `HEAD`).
    GitNewBranchFrom(String),
    /// Git rail — confirm + `git branch -D <name>`.
    GitDeleteBranch(String),
    /// Git rail — open a shell pane rooted in the worktree directory.
    GitWorktreeShell(PathBuf),
    /// Git rail — confirm + `git worktree remove <path>`.
    GitWorktreeRemove(PathBuf),
}

#[derive(Debug, Clone)]
pub struct MenuItem {
    pub label: String,
    pub action: MenuAction,
}

impl MenuItem {
    pub fn new(label: impl Into<String>, action: MenuAction) -> Self {
        MenuItem {
            label: label.into(),
            action,
        }
    }
}

pub struct ContextMenu {
    /// Optional heading shown above the items (e.g. the file name).
    pub title: Option<String>,
    pub items: Vec<MenuItem>,
    /// Where the menu's top-left should sit (the click cell) — clamped on render.
    pub anchor: (u16, u16),
    pub selected: usize,
}

impl ContextMenu {
    pub fn new(title: Option<String>, anchor: (u16, u16), items: Vec<MenuItem>) -> Self {
        ContextMenu {
            title,
            items,
            anchor,
            selected: 0,
        }
    }
    pub fn move_up(&mut self) {
        if self.selected == 0 {
            self.selected = self.items.len().saturating_sub(1);
        } else {
            self.selected -= 1;
        }
    }
    pub fn move_down(&mut self) {
        if self.items.is_empty() {
            return;
        }
        self.selected = (self.selected + 1) % self.items.len();
    }
    pub fn set_selected(&mut self, i: usize) {
        if i < self.items.len() {
            self.selected = i;
        }
    }
    /// Inner content width (the longest label + a little padding).
    pub fn content_width(&self) -> usize {
        let longest = self
            .items
            .iter()
            .map(|i| i.label.chars().count())
            .chain(self.title.iter().map(|t| t.chars().count()))
            .max()
            .unwrap_or(8);
        (longest + 2).max(12)
    }
}
