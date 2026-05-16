//! The fuzzy-picker overlay — a generic "type to filter a list, pick one"
//! widget. Used for the command palette (`Ctrl+Shift+P`), the file finder
//! (`Ctrl+P`), and the buffer switcher. The caller supplies items keyed by an
//! opaque `id`; `App::picker_accept` maps the chosen `id` back to an action by
//! `PickerKind`.

use crate::fuzzy::fuzzy_match;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PickerKind {
    /// `id` = a filesystem path. Accept ⇒ open it.
    Files,
    /// `id` = a pane index (as a string). Accept ⇒ make it active.
    Buffers,
    /// `id` = a command id. Accept ⇒ run it.
    Commands,
    /// `id` = a theme name. Accept ⇒ switch to it.
    Themes,
    /// `id` = a `[tasks.<name>]` task name. Accept ⇒ run it in a pty pane.
    Tasks,
    /// `id` = `"local:<name>"` or `"remote:<name>"`. Accept ⇒ checkout that branch.
    Branches,
    /// `id` = a worktree path. Accept ⇒ open a shell pane there.
    Worktrees,
    /// `id` = `"<abs-path>\t<line>\t<col>"` (0-based). Accept ⇒ open + jump there.
    /// Used for LSP references (and any future "list of source locations").
    Locations,
    /// `id` = an absolute filesystem path. Accept ⇒ open it. Same as `Files`
    /// at accept time; separate kind keeps the title + ordering distinct.
    Recent,
    /// `id` = the index (as a string) into [`crate::app::App::pending_code_actions`].
    /// Accept ⇒ apply that action (workspace edit + / or `executeCommand`).
    CodeActions,
    /// `id` = `"<line>\t<col>"` (0-based) within the active editor at request
    /// time. Accept ⇒ jump the cursor to that line/col. Used for the LSP
    /// "Go to Symbol in file" (`textDocument/documentSymbol`) picker.
    Symbols,
    /// `id` = index (as a string) into [`crate::browser_pane::BrowserPane::targets`].
    /// Accept ⇒ switch which CDP target the active browser pane drives.
    BrowserTargets,
    /// `id` = the URL itself. Accept ⇒ `Page.navigate` the active browser
    /// pane to it. Populated by `browser.url_history` from
    /// `App::browser_url_history` (accumulated from `Page.frameNavigated`
    /// across sessions).
    BrowserHistory,
    /// `id` = the index (as a string) into [`crate::app::App::pending_snippets`].
    /// Accept ⇒ insert the snippet's expansion at the active editor's cursor.
    Snippets,
    /// `id` = `"local:<letter>"` (current buffer) or `"global:<letter>"`
    /// (cross-file). Accept ⇒ jump to the mark (open the file if needed).
    Marks,
    /// `id` = `"apply"` or `"cancel"`. Confirmation step for LSP rename:
    /// shows a per-file summary of the pending edits; Apply commits them,
    /// Cancel drops the stash on `App.pending_rename_preview`.
    RenamePreview,
    /// `id` = a commit hash. Accept ⇒ open a diff pane for that commit.
    /// Populated by `git.file_history` for commits touching the active file.
    FileHistory,
    /// `id` = a Claude Code session id. Accept ⇒ open a live transcript
    /// mirror for the session (read-only follow of `~/.claude/projects/
    /// <dashed-cwd>/<id>.jsonl`).
    AiSessions,
    /// `id` = a register letter (single char). Accept ⇒ insert that
    /// register's text at the cursor. Populated by `picker.clipboard`
    /// over `"0`-`"9` (yank + delete history) + lowercase named regs.
    Clipboard,
    /// `id` = the PR/MR's web URL. Accept ⇒ open it in the OS browser.
    /// Populated by `pr.picker` — a unified fuzzy picker over every
    /// open PR across the 4 SCM hosts (Bitbucket, GitHub, GitLab, Azure
    /// DevOps), reading from the per-host caches the SCM workers populate.
    OpenPullRequests,
    /// `id` = the index (as a string) into `App::repos`. Accept ⇒
    /// switch the active repo. Populated by `git.switch_repo`.
    Repos,
    /// `id` = an env name (`"dev"` / `"staging"` / `"prod"`). Accept ⇒
    /// run playwright tests against that env (private-feature only).
    /// Populated by `private.run_tests_pick_env`.
    the private integrationEnv,
    /// `id` = a branch name. Accept ⇒ run playwright tests with
    /// `BRANCH=<id>` (private-feature only). Populated by
    /// `private.run_tests_pick_branch`.
    the private integrationBranch,
}

#[derive(Debug, Clone)]
pub struct PickerItem {
    pub id: String,
    /// The text shown and fuzzy-matched against.
    pub label: String,
    /// A right-aligned, dimmed hint (a keybinding, a directory, …).
    pub detail: String,
}

impl PickerItem {
    pub fn new(id: impl Into<String>, label: impl Into<String>, detail: impl Into<String>) -> Self {
        PickerItem {
            id: id.into(),
            label: label.into(),
            detail: detail.into(),
        }
    }
}

#[derive(Debug)]
pub struct Picker {
    pub kind: PickerKind,
    pub title: String,
    items: Vec<PickerItem>,
    pub query: String,
    /// Indices into `items`, filtered + sorted (best match first).
    filtered: Vec<usize>,
    /// Index into `filtered`.
    pub selected: usize,
    /// First visible row (the view keeps `selected` on screen).
    pub scroll: usize,
}

impl Picker {
    pub fn new(kind: PickerKind, title: impl Into<String>, items: Vec<PickerItem>) -> Self {
        let mut p = Picker {
            kind,
            title: title.into(),
            items,
            query: String::new(),
            filtered: Vec::new(),
            selected: 0,
            scroll: 0,
        };
        p.refilter();
        p
    }

    fn refilter(&mut self) {
        let mut scored: Vec<(i64, usize)> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(i, it)| fuzzy_match(&self.query, &it.label).map(|(s, _)| (s, i)))
            .collect();
        // Best score first; ties keep the original order.
        scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        self.filtered = scored.into_iter().map(|(_, i)| i).collect();
        self.selected = self.selected.min(self.filtered.len().saturating_sub(1));
        self.scroll = 0;
    }

    pub fn items_view(&self) -> impl Iterator<Item = &PickerItem> {
        self.filtered.iter().map(move |&i| &self.items[i])
    }
    pub fn len(&self) -> usize {
        self.filtered.len()
    }
    pub fn is_empty(&self) -> bool {
        self.filtered.is_empty()
    }
    pub fn selected_item(&self) -> Option<&PickerItem> {
        self.filtered.get(self.selected).map(|&i| &self.items[i])
    }

    pub fn type_char(&mut self, c: char) {
        self.query.push(c);
        self.refilter();
    }
    pub fn backspace(&mut self) {
        self.query.pop();
        self.refilter();
    }
    pub fn clear_query(&mut self) {
        self.query.clear();
        self.refilter();
    }
    pub fn move_down(&mut self) {
        if self.selected + 1 < self.filtered.len() {
            self.selected += 1;
        }
    }
    pub fn move_up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }
    pub fn set_selected(&mut self, idx: usize) {
        if idx < self.filtered.len() {
            self.selected = idx;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> Picker {
        Picker::new(
            PickerKind::Commands,
            "Commands",
            vec![
                PickerItem::new("file.save", "Save file", "ctrl+s"),
                PickerItem::new("view.toggle_tree", "Toggle file tree", "ctrl+b"),
                PickerItem::new("app.quit", "Quit mnml", "ctrl+q"),
            ],
        )
    }

    #[test]
    fn filters_and_orders_by_match() {
        let mut pk = p();
        assert_eq!(pk.len(), 3);
        pk.type_char('s');
        pk.type_char('a');
        pk.type_char('v');
        // "sav" matches "Save file" best
        assert_eq!(pk.selected_item().unwrap().id, "file.save");
        pk.backspace();
        pk.backspace();
        pk.backspace();
        assert_eq!(pk.len(), 3);
    }

    #[test]
    fn selection_clamps() {
        let mut pk = p();
        pk.move_down();
        pk.move_down();
        pk.move_down(); // can't go past the last
        assert_eq!(pk.selected, 2);
        pk.move_up();
        assert_eq!(pk.selected, 1);
    }
}
