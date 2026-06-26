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
    /// Accept ⇒ write `<typed-var>=<pending_lookup_picked_id>` to
    /// the current env file (`<workspace>/.rqst/env/<active>.env`)
    /// and toast the result. The picked id was stashed into
    /// `App::pending_lookup_picked_id` by the
    /// `PickerKind::LookupItem` accept handler. Phase 7 of the
    /// rqst→mnml port-back.
    LookupVarName,
    /// Accept ⇒ upsert `<pending_env_edit_key>=<typed>` into the
    /// active env file. Stashed via `App::pending_env_edit_key`
    /// when the EnvVars picker accepted an existing key. Phase 3
    /// polish.
    EnvEditValue,
    /// Accept ⇒ split typed input on `=` → `<key>=<value>` and
    /// upsert into the active env file. Empty / malformed input
    /// toasts an error. Triggered by the `+add` row in the
    /// `EnvVars` picker. Phase 3 polish.
    EnvAddKey,
    /// Accept ⇒ split typed input on `=`, append to the active
    /// Request pane's URL as a query parameter. `?` if URL has no
    /// query string yet; `&` if it does.
    HttpParamAdd,
    /// Accept ⇒ save active Request pane's Authorization header
    /// as `.mnml/auth/<typed-name>.txt`. The preset can later be
    /// applied via `:auth.apply_preset`.
    AuthSavePreset,
    /// Accept ⇒ ask Claude the typed question with the active
    /// Request pane's request + response as context. Spawned by
    /// clicking the AI section in the Request pane.
    AiAskAboutRequest,
    /// Accept ⇒ save the active Request pane's Done response body
    /// to the typed file path (workspace-relative or absolute).
    HttpSaveResponse,
    /// Accept ⇒ replace the active Request pane's Authorization
    /// header with `Bearer <typed-token>`.
    HttpAuthBearer,
    /// Accept ⇒ replace Authorization with `Basic <base64(typed)>`.
    /// Typed value is `user:pass`.
    HttpAuthBasic,
    /// Accept ⇒ replace `X-Api-Key` header value with typed.
    HttpAuthApiKey,
    /// Accept ⇒ connect to the typed wss:// URL via tungstenite.
    WsConnect,
    /// Accept ⇒ send the typed message on the active WebSocket.
    WsSendMessage,
    /// Accept ⇒ send the typed natural-language description to
    /// Claude (one-shot), wait for the curl reply, then open a new
    /// Request pane populated with the parsed request. Useful for
    /// "get me the top 5 users from prod" → fully-formed POST.
    HttpAiBuild,
    /// Accept (any non-empty input ⇒ proceed) ⇒ SIGTERM the PID
    /// stashed in `App.pending_kill_pid`. Prompt copy is
    /// "type 'kill' to terminate PID N · esc cancels".
    ClaudeKillConfirm,
    /// Accept ⇒ grep every transcript under ~/.claude/projects/
    /// for the typed substring (case-insensitive). Results land in
    /// a `[session-search]` scratch buffer.
    ClaudeSessionSearch,
    /// Accept (input == "delete") ⇒ force-delete the branch
    /// stashed in `App.pending_branch_delete`.
    GitDeleteBranchConfirm,
    /// Accept ⇒ pass the typed natural-language description to
    /// Claude one-shot; the reply (a branch name) gets seeded
    /// into a `BranchName` prompt for the user to accept/edit.
    AiBranchNameDescription,
    /// Accept ⇒ run `git checkout -b <input>` on the active repo.
    /// Pre-seeded with the AI's suggestion when the
    /// `AiBranchNameDescription` flow completes.
    BranchName,
    /// Accept (any non-empty) ⇒ `git worktree add <pending_path> <input>`.
    /// `App.pending_worktree_path` is set by `:git.worktree_add`
    /// before the prompt opens. Input is the branch name to check
    /// out in the new worktree.
    WorktreeBranchName,
    /// Accept (input == "remove") ⇒ `git worktree remove <pending_path>`.
    /// Confirm prompt for the GitWorktreeRemove picker.
    WorktreeRemoveConfirm,
    /// Accept ⇒ `npm run <input>` in a pty pane. Used by
    /// `:npm.run_script` so polyglot projects with non-`dev`
    /// scripts (next dev, vite, start:dev, etc.) can run them
    /// without a hardcoded chord.
    NpmRunScript,
    /// Accept ⇒ `go run <input>` in a pty pane. Used by
    /// `:go.run_path` so projects with a `cmd/<app>/main.go`
    /// layout can pick the right package without `:go.run` being
    /// hardcoded to `.`.
    GoRunPath,
    /// Accept ⇒ shell-out `grpcurl <plain?> -d "" <host> list` to
    /// enumerate services. Opens a picker over the discovered
    /// services. 2026-06-21 `:grpc.discover`.
    GrpcDiscoverHost,
    /// Accept (input == "merge") ⇒ `git merge <pending_merge_source>`.
    /// Confirm prompt for the GitMergeInto picker.
    GitMergeConfirm,
    /// Accept (input == "rebase") ⇒ `git rebase <pending_rebase_onto>`.
    /// Confirm prompt for the GitRebaseOnto picker.
    GitRebaseConfirm,
    /// Accept ⇒ patch the typed SVG path into the user's Nerd Font at
    /// the next free PUA codepoint, then yank the assigned glyph as a
    /// literal char to the clipboard so the user can paste it into
    /// the integration edit panel's Glyph field directly (NOT as
    /// `\u{XXXX}` — TOML doesn't parse Rust's escape syntax).
    /// Surfaced from the palette command
    /// `integrations.patch_nerd_font_svg`.
    PatchNerdFontSvg,
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
    /// Accept ⇒ `git stash drop <held ref>` *iff* the typed text matches
    /// the literal word `drop` exactly. Same gating shape as
    /// `DiffDiscardHunk` — drop is reflog-recoverable only until the
    /// next `git gc` (~30 days), so a hard typed confirm is the right
    /// floor. Ref + a short label held in `App.pending_stash_drop`.
    /// untouched-surfaces-hunt-2026-06-08 SEV-2 #8.
    GitStashDrop,
    /// Accept ⇒ run `git tag -d <name>` *iff* the typed text
    /// matches the tag's name exactly. Tag name held in
    /// `App.pending_tag_delete`.
    GitTagDelete,
    /// Workspaces editor — apply the typed value to
    /// `config.workspaces[App::workspaces_edit_target_name].name`
    /// then persist.
    WorkspaceRename,
    /// Workspaces editor — apply path edit (tilde-expanded; must
    /// exist on disk).
    WorkspacePathEdit,
    /// Workspaces editor — apply group label edit (empty = ungrouped).
    WorkspaceGroupEdit,
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
    /// Accept ⇒ set the active pty pane's `display_name` to the typed
    /// text (`:rename` / `term.rename`). Empty input clears the name
    /// back to the profile default.
    PtySessionName,
    /// Accept ⇒ rename the dock widget referenced by
    /// `App::dock_rename_target`. Empty input falls back to the
    /// default `Note N` style name (regenerated from id).
    DockWidgetRename,
    /// Accept ⇒ approve the AI agent's pending `write_file`; Esc ⇒ deny.
    /// The answer is relayed to the blocked agent worker through its
    /// confirm channel (`App::resolve_tool_confirm`).
    AiToolConfirm,
    /// Accept ⇒ spawn `<input>` as a Mount pane. Used by the
    /// `mount.open` palette command for developer / testing flows
    /// while siblings get ported to the Bridge tier-4 protocol.
    MountBinary,
}

#[derive(Debug)]
pub struct Prompt {
    pub kind: PromptKind,
    pub title: String,
    pub input: String,
    /// Caret position, a byte index into `input` (always on a char boundary).
    pub cursor: usize,
    /// Live-filtered directory suggestions — populated for path-typed
    /// prompts (`AddWorkspace`). Each entry is a full path that
    /// `Tab`/`Enter` can autocomplete or accept.
    pub suggestions: Vec<std::path::PathBuf>,
    /// `Some(i)` ⇒ the i-th suggestion is focused (↑/↓ navigation);
    /// `None` ⇒ no row focused (Enter accepts the typed input).
    pub selected_suggestion: Option<usize>,
}

impl Prompt {
    pub fn new(kind: PromptKind, title: impl Into<String>) -> Self {
        let mut p = Prompt {
            kind,
            title: title.into(),
            input: String::new(),
            cursor: 0,
            suggestions: Vec::new(),
            selected_suggestion: None,
        };
        p.refresh_suggestions();
        p
    }

    /// Like [`Self::new`] but with the input field pre-filled (caret at the end) —
    /// e.g. an AI-suggested commit message you can then edit before confirming.
    pub fn seeded(kind: PromptKind, title: impl Into<String>, input: impl Into<String>) -> Self {
        let input = input.into();
        let cursor = input.len();
        let mut p = Prompt {
            kind,
            title: title.into(),
            input,
            cursor,
            suggestions: Vec::new(),
            selected_suggestion: None,
        };
        p.refresh_suggestions();
        p
    }

    /// Does this prompt type want a directory listing alongside the
    /// text input? Today only `AddWorkspace`; extend as needed.
    pub fn is_path_kind(&self) -> bool {
        matches!(self.kind, PromptKind::AddWorkspace)
    }

    pub fn insert_char(&mut self, c: char) {
        self.input.insert(self.cursor, c);
        self.cursor += c.len_utf8();
        self.refresh_suggestions();
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
        self.refresh_suggestions();
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
        self.refresh_suggestions();
    }

    /// ↓ — focus the next suggestion (wraps to top).
    pub fn suggestion_next(&mut self) {
        if self.suggestions.is_empty() {
            return;
        }
        let n = self.suggestions.len();
        self.selected_suggestion = Some(match self.selected_suggestion {
            None => 0,
            Some(i) => (i + 1) % n,
        });
    }

    /// ↑ — focus the previous suggestion (wraps to bottom). Going up
    /// from the topmost row drops focus back to the input.
    pub fn suggestion_prev(&mut self) {
        if self.suggestions.is_empty() {
            return;
        }
        let n = self.suggestions.len();
        self.selected_suggestion = Some(match self.selected_suggestion {
            None => n - 1,
            Some(0) => return self.selected_suggestion = None,
            Some(i) => i - 1,
        });
    }

    /// Tab — autocomplete the input from the focused suggestion, or
    /// from the first suggestion when none is focused. The caret
    /// jumps to the end so further typing extends the path.
    pub fn autocomplete(&mut self) {
        let idx = self.selected_suggestion.unwrap_or(0);
        let Some(path) = self.suggestions.get(idx) else {
            return;
        };
        let s = path.to_string_lossy().to_string();
        self.input = s;
        self.cursor = self.input.len();
        // Refresh again — picking a directory should now show its
        // subdirectories.
        self.refresh_suggestions();
        // Clear the focus indicator after autocompleting; the user's
        // next ↑↓ re-engages the list.
        self.selected_suggestion = None;
    }

    /// Replace the input with the focused suggestion (no refresh). Used
    /// by Enter on a focused row to commit the picked path.
    pub fn take_selected_input(&mut self) -> Option<String> {
        let idx = self.selected_suggestion?;
        self.suggestions
            .get(idx)
            .map(|p| p.to_string_lossy().to_string())
    }

    /// Recompute `suggestions` based on the current `input`. No-op for
    /// non-path prompts. Errors (directory unreadable, etc.) silently
    /// produce an empty list.
    pub fn refresh_suggestions(&mut self) {
        if !self.is_path_kind() {
            self.suggestions.clear();
            self.selected_suggestion = None;
            return;
        }
        const MAX_SUGGESTIONS: usize = 12;
        let (parent, filter) = split_path_for_browse(&self.input);
        let mut out: Vec<std::path::PathBuf> = Vec::new();
        if let Ok(read) = std::fs::read_dir(&parent) {
            for entry in read.flatten() {
                let Ok(ft) = entry.file_type() else {
                    continue;
                };
                if !ft.is_dir() {
                    continue;
                }
                let name = entry.file_name();
                let name_str = name.to_string_lossy();
                // Skip dotfiles unless the filter explicitly asks for
                // them (typed `.` as the prefix).
                if name_str.starts_with('.') && !filter.starts_with('.') {
                    continue;
                }
                if !name_str.to_lowercase().starts_with(&filter.to_lowercase()) {
                    continue;
                }
                out.push(entry.path());
            }
        }
        out.sort_by(|a, b| {
            a.file_name()
                .map(|s| s.to_string_lossy().to_lowercase())
                .cmp(&b.file_name().map(|s| s.to_string_lossy().to_lowercase()))
        });
        out.truncate(MAX_SUGGESTIONS);
        self.suggestions = out;
        // Keep focus if it's still a valid index, otherwise drop it.
        if let Some(i) = self.selected_suggestion
            && i >= self.suggestions.len()
        {
            self.selected_suggestion = None;
        }
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

/// Resolve the user's typed path into `(parent_dir, filename_prefix)`
/// for live directory browsing. Tilde expansion happens here.
///
/// Examples (assuming `$HOME = /Users/chris`):
///   `""`             ⇒ ($HOME,            ""        )
///   `"~"`            ⇒ ($HOME,            ""        )
///   `"~/Pro"`        ⇒ ($HOME,            "Pro"     )
///   `"~/Projects"`   ⇒ ($HOME,            "Projects")
///   `"~/Projects/"`  ⇒ ($HOME/Projects,   ""        )
///   `"/Users/chris/Pr"` ⇒ ("/Users/chris", "Pr"     )
///   `"foo"`          ⇒ (PWD,              "foo"     )
fn split_path_for_browse(input: &str) -> (std::path::PathBuf, String) {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from);

    // Empty / "~" — browse $HOME.
    if input.is_empty() || input == "~" {
        return (
            home.unwrap_or_else(|| std::env::current_dir().unwrap_or_default()),
            String::new(),
        );
    }

    // Tilde expansion: "~/X" → "$HOME/X". Anything else stays literal.
    let expanded: std::path::PathBuf = if let Some(rest) = input.strip_prefix("~/") {
        match &home {
            Some(h) => h.join(rest),
            None => std::path::PathBuf::from(input),
        }
    } else {
        std::path::PathBuf::from(input)
    };

    // Trailing slash ⇒ treat the whole path as parent, empty filter.
    if input.ends_with('/') {
        return (expanded, String::new());
    }

    // Split into parent dir + last segment (the filter).
    let parent = expanded
        .parent()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let filter = expanded
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    // If the typed path is relative (no leading `/` or `~/`), resolve
    // against PWD so suggestions make sense.
    let parent = if parent.is_relative() {
        std::env::current_dir().unwrap_or_default().join(parent)
    } else {
        parent
    };

    (parent, filter)
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

    #[test]
    fn is_path_kind_only_addworkspace() {
        assert!(Prompt::new(PromptKind::AddWorkspace, "").is_path_kind());
        assert!(!Prompt::new(PromptKind::GitCommit, "").is_path_kind());
        assert!(!Prompt::new(PromptKind::Find, "").is_path_kind());
    }

    #[test]
    fn non_path_kinds_have_no_suggestions() {
        let mut p = Prompt::new(PromptKind::GitCommit, "");
        p.insert_char('f');
        p.insert_char('o');
        p.insert_char('o');
        assert!(p.suggestions.is_empty());
    }

    #[test]
    fn split_path_empty_is_home_no_filter() {
        let (parent, filter) = split_path_for_browse("");
        // Either $HOME or PWD — at least non-empty.
        assert!(parent.exists() || parent.to_string_lossy().is_empty().not());
        assert_eq!(filter, "");
    }

    #[test]
    fn split_path_trailing_slash_treats_whole_as_parent() {
        let (parent, filter) = split_path_for_browse("/tmp/");
        assert_eq!(parent, std::path::PathBuf::from("/tmp"));
        assert_eq!(filter, "");
    }

    #[test]
    fn split_path_extracts_prefix() {
        let (parent, filter) = split_path_for_browse("/tmp/myProj");
        assert_eq!(parent, std::path::PathBuf::from("/tmp"));
        assert_eq!(filter, "myProj");
    }

    #[test]
    fn split_path_tilde_expansion() {
        // SAFETY: setting HOME for the duration of one synchronous test
        // is fine — Rust runs `cargo test` single-threaded by default
        // within a process, and even with `--test-threads N` each test
        // touches its own keys. Set HOME explicitly so the assertion
        // doesn't depend on the CI machine's actual home.
        // SAFETY: see comment above — single test, restored before
        // returning, no cross-thread observation.
        let prev = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", "/Users/x") };
        let (parent, filter) = split_path_for_browse("~/Proj");
        assert_eq!(parent, std::path::PathBuf::from("/Users/x"));
        assert_eq!(filter, "Proj");
        if let Some(p) = prev {
            unsafe { std::env::set_var("HOME", p) };
        } else {
            unsafe { std::env::remove_var("HOME") };
        }
    }

    // Helper for `is_empty().not()` in the test above.
    trait NotExt {
        fn not(self) -> bool;
    }
    impl NotExt for bool {
        fn not(self) -> bool {
            !self
        }
    }
}
