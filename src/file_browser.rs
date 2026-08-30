//! A directory listing as a PANE — the foundation for multi-panel file
//! work (superfile / Midnight Commander shape).
//!
//! Design conversation 2026-08-30. Of the three shapes sketched, the user
//! picked "C — no mode at all": a file browser is just another
//! [`crate::pane::Pane`], so it can sit in a split, a tab, or beside an
//! editor without any mode flag. Side-by-side panels then come free from
//! the existing `Layout::Split`, and the commander/superfile arrangements
//! become layout PRESETS rather than a second application with its own
//! conditionals threaded through the render layer.
//!
//! That is also the extension shape CLAUDE.md's spine describes: "adding a
//! feature = register commands + maybe a `Pane`/`EditOp` variant — not a
//! refactor."
//!
//! # Scope of this first slice
//!
//! Navigation and opening only: read a directory, sort it, move a cursor,
//! descend / ascend, open a file in an editor. File OPERATIONS (cut / copy
//! / paste / duplicate / move-to) already exist as `file.*` commands but
//! are wired to the tree's selection; routing them through a focused
//! Files pane is the next slice. Cross-pane drag-and-drop and a transfer
//! tracker are after that — those are the genuinely expensive parts, and
//! the fs ops are still synchronous, so dropping a 4 GB copy behind a
//! toast is not something to ship casually.

use std::path::{Path, PathBuf};

/// One row in a [`FileBrowserPane`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    /// `None` for directories — computing a recursive size on every
    /// listing would stat the whole subtree, which is exactly the kind of
    /// per-frame cost that makes a file manager feel slow.
    pub size: Option<u64>,
    /// Seconds since the epoch, or `None` when the platform/filesystem
    /// does not report it.
    pub modified: Option<u64>,
    pub is_symlink: bool,
}

/// How a listing is ordered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Sort {
    /// Directories first, then case-insensitive name. The default because
    /// it is what every file manager does and what muscle memory expects.
    #[default]
    DirsFirstName,
    Size,
    Modified,
}

#[derive(Debug)]
pub struct FileBrowserPane {
    pub cwd: PathBuf,
    pub entries: Vec<Entry>,
    /// Index into [`Self::entries`]. Always in range when `entries` is
    /// non-empty; see [`Self::clamp`].
    pub selected: usize,
    /// First visible row — owned here rather than recomputed, so the view
    /// can keep the cursor on screen across a resize.
    pub scroll: usize,
    pub sort: Sort,
    pub show_hidden: bool,
    /// Set when a jump moved the cursor discontinuously, so the renderer
    /// reveals it with context instead of pinning it to an edge. Same
    /// split as the git graph's `center_on_next_draw` (#1229): stepping
    /// wants minimal scroll, a jump wants context.
    pub center_on_next_draw: bool,
    /// Last read error, surfaced in the pane rather than as a toast — a
    /// permission-denied directory should say so where you are looking.
    pub error: Option<String>,
}

impl FileBrowserPane {
    pub fn open(dir: &Path) -> Self {
        let mut p = FileBrowserPane {
            cwd: dir.to_path_buf(),
            entries: Vec::new(),
            selected: 0,
            scroll: 0,
            sort: Sort::default(),
            show_hidden: false,
            center_on_next_draw: false,
            error: None,
        };
        p.reload();
        p
    }

    /// Tab label — the directory's own name, or the full path when it has
    /// none (a filesystem root).
    pub fn tab_title(&self) -> String {
        self.cwd
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| self.cwd.display().to_string())
    }

    /// Re-read `cwd`. Keeps the cursor on the same NAME where possible, so
    /// a reload after an external change does not teleport the selection.
    pub fn reload(&mut self) {
        let keep = self.entries.get(self.selected).map(|e| e.name.clone());
        self.error = None;
        let mut out: Vec<Entry> = Vec::new();
        match std::fs::read_dir(&self.cwd) {
            Ok(rd) => {
                for ent in rd.flatten() {
                    let name = ent.file_name().to_string_lossy().to_string();
                    if !self.show_hidden && name.starts_with('.') {
                        continue;
                    }
                    // `symlink_metadata` so a dangling symlink still
                    // lists instead of vanishing, and so a symlinked
                    // directory is reported as a link rather than
                    // silently followed.
                    let md = ent.path().symlink_metadata().ok();
                    let is_symlink = md.as_ref().is_some_and(|m| m.file_type().is_symlink());
                    // Follow the link for is_dir, so a symlinked dir is
                    // still enterable — that is what a user expects when
                    // they press Enter on it.
                    let is_dir = ent.path().is_dir();
                    out.push(Entry {
                        name,
                        path: ent.path(),
                        is_dir,
                        size: md.as_ref().and_then(|m| (!is_dir).then_some(m.len())),
                        modified: md.as_ref().and_then(|m| m.modified().ok()).and_then(|t| {
                            t.duration_since(std::time::UNIX_EPOCH)
                                .ok()
                                .map(|d| d.as_secs())
                        }),
                        is_symlink,
                    });
                }
            }
            Err(e) => {
                self.error = Some(format!("{}: {e}", self.cwd.display()));
            }
        }
        self.entries = out;
        self.apply_sort();
        // Restore the cursor by name; fall back to clamping.
        if let Some(name) = keep
            && let Some(i) = self.entries.iter().position(|e| e.name == name)
        {
            self.selected = i;
        }
        self.clamp();
    }

    pub fn apply_sort(&mut self) {
        match self.sort {
            Sort::DirsFirstName => self.entries.sort_by(|a, b| {
                b.is_dir
                    .cmp(&a.is_dir)
                    .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            }),
            // Largest first — "what is eating my disk" is the question
            // size-sorting is asked. Directories have no size, so they
            // sort together by name at the end rather than pretending 0.
            Sort::Size => self.entries.sort_by(|a, b| {
                b.size
                    .cmp(&a.size)
                    .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            }),
            // Newest first, same reasoning.
            Sort::Modified => self.entries.sort_by(|a, b| {
                b.modified
                    .cmp(&a.modified)
                    .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            }),
        }
    }

    pub fn set_sort(&mut self, sort: Sort) {
        // Keep the cursor on the same entry across a re-sort — a sort that
        // moves your selection makes you find your place again.
        let keep = self.entries.get(self.selected).map(|e| e.name.clone());
        self.sort = sort;
        self.apply_sort();
        if let Some(name) = keep
            && let Some(i) = self.entries.iter().position(|e| e.name == name)
        {
            self.selected = i;
        }
        self.clamp();
    }

    pub fn toggle_hidden(&mut self) {
        self.show_hidden = !self.show_hidden;
        self.reload();
    }

    fn clamp(&mut self) {
        if self.entries.is_empty() {
            self.selected = 0;
            self.scroll = 0;
            return;
        }
        self.selected = self.selected.min(self.entries.len() - 1);
    }

    /// Move the cursor by `delta` rows, saturating at both ends.
    ///
    /// Saturating rather than wrapping: wrapping from the last row to the
    /// first on a long list is disorienting, and it is not what the file
    /// tree does either.
    pub fn move_selection(&mut self, delta: isize) {
        if self.entries.is_empty() {
            return;
        }
        let last = self.entries.len() - 1;
        let next = if delta < 0 {
            self.selected.saturating_sub(delta.unsigned_abs())
        } else {
            self.selected.saturating_add(delta as usize).min(last)
        };
        self.selected = next;
    }

    pub fn select_first(&mut self) {
        self.selected = 0;
        self.center_on_next_draw = true;
    }

    pub fn select_last(&mut self) {
        if !self.entries.is_empty() {
            self.selected = self.entries.len() - 1;
            self.center_on_next_draw = true;
        }
    }

    pub fn selected_entry(&self) -> Option<&Entry> {
        self.entries.get(self.selected)
    }

    /// Descend into the selected directory. Returns false when the
    /// selection is a file (the caller opens it in an editor instead).
    pub fn enter_selected(&mut self) -> bool {
        let Some(e) = self.entries.get(self.selected) else {
            return false;
        };
        if !e.is_dir {
            return false;
        }
        let target = e.path.clone();
        self.navigate_to(&target);
        true
    }

    /// Go to the parent directory, leaving the cursor on the directory we
    /// came FROM — so ascending and descending are inverses and you do not
    /// lose your place walking a tree.
    pub fn go_parent(&mut self) -> bool {
        let Some(parent) = self.cwd.parent().map(|p| p.to_path_buf()) else {
            return false;
        };
        let came_from = self
            .cwd
            .file_name()
            .map(|n| n.to_string_lossy().to_string());
        self.cwd = parent;
        self.selected = 0;
        self.scroll = 0;
        self.reload();
        if let Some(name) = came_from
            && let Some(i) = self.entries.iter().position(|e| e.name == name)
        {
            self.selected = i;
            self.center_on_next_draw = true;
        }
        true
    }

    pub fn navigate_to(&mut self, dir: &Path) {
        self.cwd = dir.to_path_buf();
        self.selected = 0;
        self.scroll = 0;
        self.reload();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join("zeta_dir")).unwrap();
        std::fs::create_dir(d.path().join("alpha_dir")).unwrap();
        std::fs::write(d.path().join("b_file.txt"), "bb").unwrap();
        std::fs::write(d.path().join("a_file.txt"), "aaaa").unwrap();
        std::fs::write(d.path().join(".hidden"), "x").unwrap();
        d
    }

    #[test]
    fn dirs_sort_before_files_then_by_name() {
        let d = fixture();
        let p = FileBrowserPane::open(d.path());
        let names: Vec<&str> = p.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["alpha_dir", "zeta_dir", "a_file.txt", "b_file.txt"],
            "default order should be dirs-first then case-insensitive name"
        );
    }

    #[test]
    fn hidden_entries_are_excluded_until_toggled() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        assert!(!p.entries.iter().any(|e| e.name == ".hidden"));
        p.toggle_hidden();
        assert!(
            p.entries.iter().any(|e| e.name == ".hidden"),
            "toggle_hidden did not reveal dotfiles"
        );
    }

    /// Directories get no size on purpose — a recursive stat per listing
    /// is the classic reason a file manager feels slow.
    #[test]
    fn directories_report_no_size_and_files_do() {
        let d = fixture();
        let p = FileBrowserPane::open(d.path());
        let dir = p.entries.iter().find(|e| e.name == "alpha_dir").unwrap();
        let file = p.entries.iter().find(|e| e.name == "a_file.txt").unwrap();
        assert_eq!(dir.size, None);
        assert_eq!(file.size, Some(4));
    }

    #[test]
    fn entering_a_directory_moves_cwd_and_resets_the_cursor() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p.entries.iter().position(|e| e.name == "zeta_dir").unwrap();
        assert!(p.enter_selected());
        assert_eq!(p.cwd, d.path().join("zeta_dir"));
        assert_eq!(p.selected, 0);
    }

    #[test]
    fn entering_a_file_is_refused_so_the_caller_can_open_it() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        assert!(!p.enter_selected(), "a file must not be entered as a dir");
        assert_eq!(p.cwd, d.path(), "cwd moved on a file");
    }

    /// Ascending must leave the cursor on the directory you came from, or
    /// walking a tree loses your place every time.
    #[test]
    fn going_up_selects_the_directory_you_came_from() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.navigate_to(&d.path().join("zeta_dir"));
        assert!(p.go_parent());
        assert_eq!(p.cwd, d.path());
        assert_eq!(
            p.selected_entry().map(|e| e.name.as_str()),
            Some("zeta_dir"),
            "cursor should be on the dir we ascended out of"
        );
    }

    #[test]
    fn a_re_sort_keeps_the_cursor_on_the_same_entry() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        p.set_sort(Sort::Size);
        assert_eq!(
            p.selected_entry().map(|e| e.name.as_str()),
            Some("a_file.txt"),
            "sorting moved the selection out from under the user"
        );
    }

    #[test]
    fn size_sort_puts_the_largest_file_first() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.set_sort(Sort::Size);
        let first_file = p.entries.iter().find(|e| e.size.is_some()).unwrap();
        assert_eq!(first_file.name, "a_file.txt", "4 bytes should beat 2");
    }

    #[test]
    fn selection_saturates_instead_of_wrapping() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.move_selection(-5);
        assert_eq!(p.selected, 0, "moving up past the top should stop at 0");
        p.move_selection(500);
        assert_eq!(
            p.selected,
            p.entries.len() - 1,
            "moving down past the end should stop at the last row"
        );
    }

    /// An unreadable directory must report itself, not present as empty.
    #[test]
    fn a_read_error_is_recorded_rather_than_looking_empty() {
        let d = tempfile::tempdir().unwrap();
        let missing = d.path().join("does-not-exist");
        let p = FileBrowserPane::open(&missing);
        assert!(p.entries.is_empty());
        assert!(
            p.error.is_some(),
            "a failed read_dir must surface an error, or the pane silently \\
             claims the directory is empty"
        );
    }

    /// A reload after an external change keeps the cursor on the same NAME
    /// rather than the same index.
    #[test]
    fn reload_keeps_the_cursor_on_the_same_name() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "b_file.txt")
            .unwrap();
        // Something appears that sorts BEFORE it, shifting every index.
        std::fs::create_dir(d.path().join("aaa_new_dir")).unwrap();
        p.reload();
        assert_eq!(
            p.selected_entry().map(|e| e.name.as_str()),
            Some("b_file.txt"),
            "an unrelated new entry moved the user's selection"
        );
    }

    #[test]
    fn a_dangling_symlink_still_lists() {
        let d = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(d.path().join("nowhere"), d.path().join("dangling")).unwrap();
        let p = FileBrowserPane::open(d.path());
        #[cfg(unix)]
        {
            let e = p
                .entries
                .iter()
                .find(|e| e.name == "dangling")
                .expect("dangling symlink vanished from the listing");
            assert!(e.is_symlink);
            assert!(!e.is_dir);
        }
        let _ = p;
    }
}
