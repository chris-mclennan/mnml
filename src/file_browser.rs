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
    /// Marked entries, by PATH rather than index.
    ///
    /// #files item 2 — indices shift under a re-sort, a reload, or a
    /// hidden-files toggle, so an index-based mark set would silently
    /// re-point at different files. Paths survive all three. Marks also
    /// deliberately survive navigating away and back, which is what makes
    /// "gather from several directories, then act" possible — the reason
    /// multi-select exists in a file manager.
    pub marked: std::collections::HashSet<PathBuf>,
    /// The pane this browser last previewed into.
    ///
    /// #files item 4 — `open_path_preview` finds the tab to REPLACE by
    /// looking at `App::active`. That works for a tree click, where focus
    /// follows the preview. It cannot work here, because the whole point
    /// is that focus stays in the listing so you can keep arrowing — so
    /// by the second preview `active` is the browser, the lookup finds no
    /// preview tab, and every glance opens another pane.
    ///
    /// Remembering the id lets the browser point `active` at the right
    /// pane for the duration of the call, which is the mechanism working
    /// as documented rather than around it.
    pub preview_pane: Option<crate::layout::PaneId>,
    /// Type-to-narrow filter over the listing.
    ///
    /// #files — mnml's house idiom: the tree, Outline, Agents, Cloud
    /// Agents and the HTTP panel all bind `/` to a filter, and
    /// `filter_placeholder` is a shared design-system module. The Files
    /// pane was the only list without one, which the vim tester flagged:
    /// in a 60-entry directory with no filter, no count prefix and no
    /// `G`, holding `j` is the only tool.
    pub filter: String,
    /// Is the filter row taking keystrokes?
    pub filter_focused: bool,
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
            marked: std::collections::HashSet::new(),
            preview_pane: None,
            filter: String::new(),
            filter_focused: false,
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
                    // Case-insensitive substring, matching every other
                    // filter in the app.
                    if !self.filter.is_empty()
                        && !name.to_lowercase().contains(&self.filter.to_lowercase())
                    {
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
                // REASON first. This led with the absolute path, which
                // the breadcrumb one row above already shows — so the row
                // clipped at the pane edge before ever reaching "Permission
                // denied", and conveyed nothing. Reported by the vim
                // tester.
                self.error = Some(format!("{e}"));
            }
        }
        self.entries = out;
        self.apply_sort();
        // An operation that consumed the marks (cut+paste) leaves them
        // pointing at paths that have moved.
        self.marked.retain(|p| p.exists());
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

    /// Set the filter and re-read. Kept as one method so the listing can
    /// never disagree with the filter that produced it.
    pub fn set_filter(&mut self, f: String) {
        self.filter = f;
        self.reload();
    }

    pub fn clear_filter(&mut self) {
        self.filter.clear();
        self.filter_focused = false;
        self.reload();
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

    /// Toggle the mark on the cursor row, then advance.
    ///
    /// Advancing is what makes marking a run of files one keypress each —
    /// ranger, mc and superfile all do it. Without it every mark costs
    /// `Space` plus `j`.
    pub fn toggle_mark(&mut self) {
        let Some(e) = self.entries.get(self.selected) else {
            return;
        };
        let p = e.path.clone();
        if !self.marked.remove(&p) {
            self.marked.insert(p);
        }
        self.move_selection(1);
    }

    /// Mark every entry in the current listing. Respects the FILTER of
    /// what is currently listed — a hidden file you cannot see must not be
    /// swept into an operation.
    pub fn mark_all(&mut self) {
        for e in &self.entries {
            self.marked.insert(e.path.clone());
        }
    }

    pub fn clear_marks(&mut self) {
        self.marked.clear();
    }

    pub fn is_marked(&self, path: &Path) -> bool {
        self.marked.contains(path)
    }

    /// The paths an operation should act on: the marked set when there is
    /// one, otherwise the cursor row.
    ///
    /// Marks WIN over the cursor. If they did not, a user who marked ten
    /// files and then moved the cursor would delete one file and wonder
    /// where the other nine went.
    pub fn action_paths(&self) -> Vec<PathBuf> {
        if !self.marked.is_empty() {
            // Listing order, not HashSet order, so any confirmation
            // prompt reads in the order the user sees.
            return self
                .entries
                .iter()
                .filter(|e| self.marked.contains(&e.path))
                .map(|e| e.path.clone())
                .chain(
                    // Marks from OTHER directories still count.
                    self.marked
                        .iter()
                        .filter(|p| !self.entries.iter().any(|e| &e.path == *p))
                        .cloned(),
                )
                .collect();
        }
        self.selected_entry()
            .map(|e| e.path.clone())
            .into_iter()
            .collect()
    }

    /// `(count, total_bytes)` for the marked set — the footer summary.
    /// Directories contribute no bytes, matching the listing.
    pub fn marked_summary(&self) -> (usize, u64) {
        // Bytes come from the WHOLE mark set, not just the visible
        // listing.
        //
        // The count already did, so after marking three files and
        // navigating elsewhere the footer read "3 selected  0 B" — which
        // says the selection is empty, the opposite of the truth, in
        // exactly the state where the next paste moves files you cannot
        // see. Reported by the vim tester; the original test only covered
        // the single-directory case, where both halves agree.
        //
        // Sizes for marks outside the listing come from a stat, which is
        // one syscall per off-screen mark and only while a footer is
        // being drawn.
        let bytes = self
            .marked
            .iter()
            .filter_map(|p| match self.entries.iter().find(|e| &e.path == p) {
                Some(e) => e.size,
                None => std::fs::metadata(p)
                    .ok()
                    .filter(|m| m.is_file())
                    .map(|m| m.len()),
            })
            .sum();
        (self.marked.len(), bytes)
    }

    /// Drop marks whose paths no longer exist.
    ///
    /// After a cut+paste the marked paths are gone, but the set still
    /// held them: the footer kept claiming "3 selected", a second cut
    /// reported "cut 3 items" for files that had moved, and the paste
    /// then failed with "already exists" for a source that was not
    /// there. Reported by the vim tester.
    pub fn prune_missing_marks(&mut self) {
        self.marked.retain(|p| p.exists());
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

    /// #files item 2 — marks are stored by PATH, so a re-sort must not
    /// re-point them at different files.
    /// Vim tester SEV-2 — the Files pane was the only list in mnml with
    /// no `/` filter, despite it being the house idiom (tree, Outline,
    /// Agents, Cloud Agents, HTTP panel all have one).
    #[test]
    fn the_filter_narrows_the_listing_case_insensitively() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        let all = p.entries.len();
        p.set_filter("A_FILE".to_string());
        let names: Vec<&str> = p.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["a_file.txt"],
            "filter did not narrow: {names:?}"
        );
        p.clear_filter();
        assert_eq!(p.entries.len(), all, "clearing the filter did not restore");
    }

    /// The filter composes with the hidden toggle rather than overriding
    /// it — a dotfile must stay hidden even when it matches.
    #[test]
    fn the_filter_does_not_reveal_hidden_files() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.set_filter("hidden".to_string());
        assert!(
            p.entries.is_empty(),
            "the filter surfaced a hidden file: {:?}",
            p.entries.iter().map(|e| &e.name).collect::<Vec<_>>()
        );
        p.toggle_hidden();
        assert_eq!(p.entries.len(), 1, "with hidden shown it should match");
    }

    /// A filter that matches nothing must leave a usable pane, not panic
    /// on a cursor pointing past the end.
    #[test]
    fn a_filter_matching_nothing_leaves_a_valid_cursor() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p.entries.len() - 1;
        p.set_filter("no-such-file-anywhere".to_string());
        assert!(p.entries.is_empty());
        assert_eq!(p.selected, 0, "cursor left dangling past the end");
        assert!(p.selected_entry().is_none());
    }

    #[test]
    fn marks_survive_a_re_sort() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        p.toggle_mark();
        assert_eq!(p.marked.len(), 1);

        p.set_sort(Sort::Size);

        let marked: Vec<&str> = p
            .entries
            .iter()
            .filter(|e| p.is_marked(&e.path))
            .map(|e| e.name.as_str())
            .collect();
        assert_eq!(
            marked,
            vec!["a_file.txt"],
            "the mark moved to a different file after sorting"
        );
    }

    /// And a reload that shifts every index must not move them either.
    #[test]
    fn marks_survive_a_reload_that_shifts_indices() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "b_file.txt")
            .unwrap();
        p.toggle_mark();
        std::fs::create_dir(d.path().join("aaa_first")).unwrap();
        p.reload();
        let marked: Vec<&str> = p
            .entries
            .iter()
            .filter(|e| p.is_marked(&e.path))
            .map(|e| e.name.as_str())
            .collect();
        assert_eq!(marked, vec!["b_file.txt"]);
    }

    /// Marking advances the cursor, so a run of files is one keypress each.
    #[test]
    fn marking_advances_the_cursor() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = 0;
        p.toggle_mark();
        assert_eq!(p.selected, 1, "toggle_mark did not advance");
        p.toggle_mark();
        assert_eq!(p.marked.len(), 2, "two rows marked in two keypresses");
    }

    /// Marks WIN over the cursor. Otherwise a user who marks ten files and
    /// then moves the cursor deletes one and loses track of the rest.
    #[test]
    fn action_paths_prefers_marks_over_the_cursor() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        p.toggle_mark();
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "b_file.txt")
            .unwrap();

        let paths = p.action_paths();
        assert_eq!(paths.len(), 1, "{paths:?}");
        assert!(
            paths[0].ends_with("a_file.txt"),
            "action used the cursor instead of the mark: {paths:?}"
        );
    }

    /// With nothing marked, the cursor is the target — so every operation
    /// still works without ever touching Space.
    #[test]
    fn action_paths_falls_back_to_the_cursor() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "b_file.txt")
            .unwrap();
        let paths = p.action_paths();
        assert_eq!(paths.len(), 1);
        assert!(paths[0].ends_with("b_file.txt"));
    }

    /// `mark_all` must respect what is LISTED — a hidden file you cannot
    /// see must not be swept into an operation.
    #[test]
    fn mark_all_ignores_entries_that_are_not_listed() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.mark_all();
        assert!(
            !p.marked.iter().any(|q| q.ends_with(".hidden")),
            "mark_all swept in a hidden file the user cannot see"
        );
        assert_eq!(p.marked.len(), p.entries.len());
    }

    /// Marks made in one directory survive navigating elsewhere — that is
    /// what makes "gather, then act" possible.
    #[test]
    fn marks_persist_across_navigation() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        p.toggle_mark();
        p.navigate_to(&d.path().join("zeta_dir"));
        assert_eq!(p.marked.len(), 1, "marks were dropped by navigation");
        // And they still surface as action targets from the new directory.
        assert_eq!(p.action_paths().len(), 1);
    }

    /// Vim tester SEV-3 — the count was global but the byte total was
    /// local, so after navigating away the footer read "3 selected  0 B":
    /// "the selection is empty", the opposite of the truth, in exactly
    /// the state where the next paste moves files you cannot see.
    #[test]
    fn marked_bytes_include_marks_outside_the_current_listing() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        p.toggle_mark(); // 4 bytes
        let (n_here, bytes_here) = p.marked_summary();
        assert_eq!((n_here, bytes_here), (1, 4), "setup");

        p.navigate_to(&d.path().join("zeta_dir"));
        let (n, bytes) = p.marked_summary();
        assert_eq!(n, 1, "count should survive navigation");
        assert_eq!(
            bytes, 4,
            "byte total collapsed to 0 after navigating — the footer would \
             claim the selection is empty"
        );
    }

    /// Vim tester SEV-3 — after a cut+paste the marks pointed at paths
    /// that had moved, so the footer kept claiming a selection, a second
    /// cut reported "cut 3 items" for files that were gone, and the paste
    /// failed with "already exists" for a source that did not exist.
    #[test]
    fn reload_drops_marks_whose_files_have_gone() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.selected = p
            .entries
            .iter()
            .position(|e| e.name == "a_file.txt")
            .unwrap();
        p.toggle_mark();
        assert_eq!(p.marked.len(), 1);

        std::fs::remove_file(d.path().join("a_file.txt")).unwrap();
        p.reload();

        assert!(
            p.marked.is_empty(),
            "a mark survived the file being removed: {:?}",
            p.marked
        );
    }

    #[test]
    fn marked_summary_counts_files_and_bytes() {
        let d = fixture();
        let mut p = FileBrowserPane::open(d.path());
        p.mark_all();
        let (n, bytes) = p.marked_summary();
        assert_eq!(n, p.entries.len());
        // a_file.txt (4) + b_file.txt (2); dirs contribute nothing.
        assert_eq!(bytes, 6, "byte total wrong: {bytes}");
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
