//! The single-line text-input overlay — "type a string, press Enter". A sibling
//! of the fuzzy [`Picker`](crate::picker) for the cases where there's no list to
//! filter, just free text (the commit message, …). `App` owns an `Option<Prompt>`
//! and maps the accepted text back to an action by [`PromptKind`].

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptKind {
    /// Accept ⇒ `App::add_workspace_runtime(input)`. Input is a path
    /// (tilde-expanded); the workspace name defaults to the basename.
    AddWorkspace,
    /// Accept ⇒ `git commit -m <input>`.
    GitCommit,
    /// Accept ⇒ `git commit --amend -m <input>` (rewrite HEAD's message in
    /// place). Opened by `git.ai_recompose` after the AI returns a new message.
    GitCommitAmend,
    /// Accept ⇒ `claude -p <input>`, answer in a `Pane::Ai`.
    AiAsk,
    /// Accept ⇒ `git checkout -b <input>`.
    NewBranch,
    /// Accept ⇒ `textDocument/rename` with the typed name (LSP).
    LspRename,
    /// Accept ⇒ launch Chrome on the typed URL in a `Pane::Browser` (CDP).
    BrowserUrl,
    /// Accept ⇒ `Page.navigate` the active browser pane to the typed URL.
    BrowserNavigate,
    /// Accept ⇒ `Runtime.evaluate` the typed JS in the active browser pane.
    BrowserEval,
    /// Accept ⇒ `Network.setCookie` with the new value. Name, domain,
    /// and path come from `App.pending_cookie_edit` (set when the chord
    /// fires). Replaces the existing cookie.
    BrowserCookieEdit,
    /// Accept ⇒ `Network.setCookie` with a `name=value` payload (parsed
    /// from the input). Domain comes from the active browser pane's
    /// URL host; path is `/`. Adds a new cookie if no match exists.
    BrowserCookieAdd,
    /// Accept ⇒ Web Storage eval that sets the value for the
    /// `(is_local, key)` stash on `App.pending_storage_edit`.
    BrowserStorageEdit,
    /// Accept ⇒ Web Storage eval that adds a `local|key=value` entry
    /// (parsed from the input — the leading `local|` or `session|`
    /// picks the storage).
    BrowserStorageAdd,
    /// Accept ⇒ find the typed string in the active editor (case-insensitive
    /// ASCII), highlight matches, jump to the nearest one.
    Find,
    /// Accept ⇒ replace every match of the active find with the typed text.
    /// Requires a non-empty find state already on the active buffer.
    Replace,
    /// Accept ⇒ grep the workspace (ripgrep; falls back to `git grep`), open
    /// the results in a `Pane::Grep`.
    Grep,
    /// Accept ⇒ replace every hit in the active `Pane::Grep` (across every
    /// file it matched) with the typed text. ASCII case-insensitive, like the
    /// in-buffer find/replace.
    GrepReplace,
    /// Accept ⇒ jump the active editor's cursor to the typed 1-based line
    /// number. (`Ctrl+G` — standard-mode equivalent of vim's `:N`.)
    GotoLine,
    /// Accept ⇒ create an empty file at `<parent>/<input>`, then open it.
    NewFile,
    /// Accept ⇒ `mkdir -p <parent>/<input>`. No buffer opened.
    NewFolder,
    /// Accept ⇒ rename the held path to `<dir>/<input>` (same parent).
    Rename,
    /// Accept ⇒ delete the held path *iff* the typed text matches its
    /// filename exactly (confirmation guard).
    DeleteConfirm,
    /// Accept ⇒ `git branch -D <held name>` *iff* the typed text matches the
    /// branch name exactly (confirmation guard). Comes from the git-rail's
    /// branch right-click menu.
    GitDeleteBranch,
    /// Accept ⇒ `git worktree remove <held path>` *iff* the typed text
    /// matches the worktree's basename exactly (confirmation guard).
    GitWorktreeRemove,
    /// Accept ⇒ reverse-apply the hunk against the working tree
    /// (`crate::git::diff::discard_hunk`) *iff* the typed text matches
    /// the literal word `discard` exactly. Hunk identity is held in
    /// `App.pending_discard_hunk = Some((pane_id, hunk_index))`.
    DiffDiscardHunk,
    /// Accept ⇒ `git restore -- <held rel>` *iff* the typed text
    /// matches the file's basename. Opened by GitStatus's
    /// right-click menu's "Discard changes" entry; path held in
    /// `App.pending_discard_file`.
    GitDiscardFile,
    /// Accept ⇒ `workspace/symbol` with the typed query; the reply lands as
    /// `LspEvent::WorkspaceSymbols` and opens a `Locations` picker.
    LspWorkspaceSymbol,
    /// Accept ⇒ `git stash push -u -m <input>` (or no `-m` if empty) — the
    /// optional message form of `git.stash`. Esc ⇒ cancel without stashing.
    GitStashMessage,
    /// Accept ⇒ add the typed expression to `App.dap_watches`. If a
    /// session is stopped at a breakpoint, immediately fires `evaluate`
    /// against the top frame so the watch row's value populates.
    DapAddWatch,
    /// Accept ⇒ toggle a conditional breakpoint at the cursor line in
    /// the active editor. Empty input ⇒ plain breakpoint (no condition);
    /// non-empty ⇒ the adapter only stops when the expression is truthy.
    DapBreakpointCondition,
    /// Accept ⇒ set a hit-count condition on the breakpoint at the
    /// cursor's line. Empty input ⇒ clear the hit count. Non-empty ⇒
    /// the adapter interprets it (e.g. `">= 5"` stops after 5+ hits,
    /// `"% 10"` every 10th hit). Independent of `DapBreakpointCondition`
    /// — a line can have both.
    DapBreakpointHitCount,
    /// Accept ⇒ fire `setVariable` against the parent_ref + name stashed
    /// on `App.pending_set_variable`. The adapter's reply lands as
    /// `DapEvent::SetVariableDone` and the variables panel updates in
    /// place. Failure (immutable / invalid value) routes through the
    /// generic `DapEvent::Failed` toast path. Seeded with the current
    /// value so the user can edit in place.
    DapSetVariable,
    /// Accept ⇒ `git tag -a <input> -m <input>` against either the selected
    /// `Pane::GitGraph` commit (when one is focused) or HEAD. Empty input
    /// cancels. The same input is used as both tag name AND annotation
    /// message — for finer control the user can drop to a pty.
    GitTag,
    /// Accept ⇒ set the GitGraph pane's date-range filter from the typed
    /// spec. Empty ⇒ clear. Accepts `--since=<s>`, `--until=<u>`, or
    /// `<s>..<u>` shorthand; any git-recognized date works
    /// (`1 week ago`, `2026-01-01`, …).
    GitGraphDateFilter,
    /// Accept ⇒ set `LogFilter.author` to the typed pattern. Empty ⇒ clear.
    GitGraphAuthorFilter,
    /// Accept ⇒ set `LogFilter.grep` to the typed pattern. Empty ⇒ clear.
    GitGraphGrepFilter,
    /// Accept ⇒ apply the pending tree move staged on
    /// `App.pending_tree_move`. Used by the tree drag-and-drop flow as
    /// the confirmation step.
    TreeMoveConfirm,
    /// Accept ⇒ exit mnml. Opened by `request_quit` so a fat-fingered
    /// `Ctrl+Q` doesn't kill the session unexpectedly. Esc cancels via
    /// the standard prompt machinery.
    QuitConfirm,
    /// Accept ⇒ context-aware Claude Code dispatch (`App::dispatch_ai_chat`).
    /// The wrapper formulates file + selection context and either seeds a
    /// fresh interactive Claude pane or types into an already-open one.
    /// Empty input + no selection ⇒ just open/focus a plain Claude pane.
    AiChat,
}

#[derive(Debug)]
pub struct Prompt {
    pub kind: PromptKind,
    pub title: String,
    pub input: String,
    /// Caret position, a byte index into `input` (always on a char boundary).
    pub cursor: usize,
}

impl Prompt {
    pub fn new(kind: PromptKind, title: impl Into<String>) -> Self {
        Prompt {
            kind,
            title: title.into(),
            input: String::new(),
            cursor: 0,
        }
    }

    /// Like [`Self::new`] but with the input field pre-filled (caret at the end) —
    /// e.g. an AI-suggested commit message you can then edit before confirming.
    pub fn seeded(kind: PromptKind, title: impl Into<String>, input: impl Into<String>) -> Self {
        let input = input.into();
        let cursor = input.len();
        Prompt {
            kind,
            title: title.into(),
            input,
            cursor,
        }
    }

    pub fn insert_char(&mut self, c: char) {
        self.input.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    pub fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let prev = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        self.input.replace_range(prev..self.cursor, "");
        self.cursor = prev;
    }

    /// Delete the word (and trailing run of spaces) before the caret — Ctrl+W.
    pub fn delete_word(&mut self) {
        let head = &self.input[..self.cursor];
        let trimmed = head.trim_end_matches(' ');
        let cut = trimmed
            .char_indices()
            .rev()
            .find(|&(_, c)| c == ' ')
            .map(|(i, _)| i + 1)
            .unwrap_or(0);
        self.input.replace_range(cut..self.cursor, "");
        self.cursor = cut;
    }

    pub fn move_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    pub fn move_right(&mut self) {
        if self.cursor >= self.input.len() {
            return;
        }
        let step = self.input[self.cursor..]
            .chars()
            .next()
            .map(char::len_utf8)
            .unwrap_or(0);
        self.cursor += step;
    }

    pub fn move_home(&mut self) {
        self.cursor = 0;
    }
    pub fn move_end(&mut self) {
        self.cursor = self.input.len();
    }

    /// Caret column for rendering (chars before the cursor).
    pub fn caret_col(&self) -> usize {
        self.input[..self.cursor].chars().count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_and_caret() {
        let mut p = Prompt::new(PromptKind::GitCommit, "Commit");
        for c in "fix the bug".chars() {
            p.insert_char(c);
        }
        assert_eq!(p.input, "fix the bug");
        assert_eq!(p.caret_col(), 11);
        p.delete_word();
        assert_eq!(p.input, "fix the ");
        p.backspace();
        assert_eq!(p.input, "fix the");
        p.move_home();
        p.move_right();
        p.insert_char('!');
        assert_eq!(p.input, "f!ix the");
    }

    #[test]
    fn utf8_safe() {
        let mut p = Prompt::new(PromptKind::GitCommit, "x");
        for c in "héllo→".chars() {
            p.insert_char(c);
        }
        p.backspace();
        assert_eq!(p.input, "héllo");
        p.move_left();
        p.backspace();
        assert_eq!(p.input, "hélo");
    }
}
