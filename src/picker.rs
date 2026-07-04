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
    /// `id` = `"reset"` or the index (as a string) into
    /// [`crate::browser_pane::DEVICE_PRESETS`]. Accept ⇒ apply the preset
    /// (or clear emulation if `"reset"`). Populated by
    /// `browser.device_picker`.
    BrowserDevices,
    /// Picker over network-throttle presets — accepts the preset
    /// id (`"none" | "offline" | "slow3g" | "fast3g" | "wifi"`)
    /// and fires `Network.emulateNetworkConditions` on the
    /// active browser pane.
    BrowserNetworkThrottle,
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
    /// Vestigial variant kept after the 2026-06 SCM split removed
    /// `pr.picker`. No code constructs it any more; left in the enum
    /// so a forge-host index file can re-light cross-host PR
    /// aggregation without re-introducing the variant.
    OpenPullRequests,
    /// `id` = the index (as a string) into `App::repos`. Accept ⇒
    /// switch the active repo. Populated by `git.switch_repo`.
    Repos,
    /// `id` = workspace index (`"0"` = primary, `"1"..` = each extra in
    /// `App::extra_workspaces`). Accept ⇒ expand that workspace's tree
    /// section + focus the rail on it. Populated by `view.switch_workspace`.
    Workspaces,
    /// `id` = workspace index (1-based; can't remove the primary). Accept ⇒
    /// drop the extra workspace at that index. Populated by
    /// `view.remove_workspace`.
    RemoveWorkspace,
    /// `id` = `"<slot1>"` (1..=9) for an occupied harpoon slot.
    /// Accept ⇒ jump to that slot's pinned file. Empty-slot rows are
    /// not added to the picker. Populated by `harpoon.menu`.
    Harpoon,
    /// `id` = `"<tool-name>"` matching `crate::tools::KNOWN_TOOLS`. Accept ⇒
    /// copy the install command to the clipboard. Populated by
    /// `tools.installer` (mnml's Mason-style picker — lists every LSP /
    /// formatter / linter mnml looks for + installed status + install hint).
    Tools,
    /// `id` = a tab index (as a string). Accept ⇒ switch to that tab
    /// page. Populated by `tab.picker`.
    Tabs,
    /// `id` = the watch expression string. Accept ⇒ remove that
    /// expression from `App::dap_watches` + drop its cached result.
    /// Populated by `dap.remove_watch`.
    DapWatchRemove,
    /// `id` = a PID (as a string). Accept ⇒ spawn the active
    /// language's DAP adapter and send `attach` with that pid.
    /// Populated by `dap.attach`.
    DapAttach,
    /// `id` = a thread id (as a string). Accept ⇒ switch the debug
    /// pane's tracked thread + re-fetch its stack trace. Populated by
    /// `dap.pick_thread`.
    DapThread,
    /// `id` = an exception-filter id (e.g. `"raised"` / `"uncaught"`).
    /// Accept ⇒ toggle that filter on/off in
    /// `DapManager.enabled_exception_filters` and re-fire
    /// `setExceptionBreakpoints`. Populated by `dap.exceptions`.
    DapException,
    /// `id` = `<idx>\t<direction>` where idx indexes into
    /// `App.pending_call_hierarchy_items` and direction is `"in"` or
    /// `"out"`. Opened when `prepareCallHierarchy` returns more than
    /// one item (overloaded fn / multi-symbol cursor); accept fires
    /// the chosen direction's follow-up against the picked item.
    CallHierarchyItems,
    /// `id` = the tag name. Accept ⇒ `git tag -d <name>`. Populated by
    /// `git.tag_delete`.
    GitTags,
    /// `id` = a stash ref (`stash@{N}`). Accept ⇒ `git stash apply <id>`.
    /// Populated by `git.stash_list`.
    StashesApply,
    /// `id` = a stash ref (`stash@{N}`). Accept ⇒ `git stash drop <id>`.
    /// Populated by `git.stash_drop`.
    StashesDrop,
    /// `id` = a full commit hash. Accept ⇒ open the commit's diff
    /// (`DiffScope::Commit`). Populated by `git.reflog`.
    Reflog,
    /// `id` = a branch name (or `"--all"` for the reset entry). Accept ⇒
    /// narrow the active `Pane::GitGraph`'s commit listing to commits
    /// reachable from that branch. Populated by `git.graph_filter_branch`.
    GitGraphBranchFilter,
    /// `id` = `"claude-api"` / `"local"` / `"off"`. Accept ⇒ set the
    /// inline-suggestion backend (`[ai] suggest_backend`). Opened the
    /// first time the user enables ghost-text.
    SuggestBackend,
    /// `id` = the row index (as a string) into
    /// [`crate::app::App::pending_captured_rows`]. Accept ⇒ open
    /// the row as a `.curl` text in a new editor pane (formatted
    /// via [`crate::http::captured::CapturedRow::to_curl`]) so the
    /// user can fire it as a regular request. Phase 4 of the
    /// rqst→mnml port-back.
    CapturedRows,
    /// `id` = the row index (as a string) into
    /// [`crate::app::App::pending_history_rows`]. Accept ⇒ open
    /// the request as a `.curl` editor pane so the user can re-
    /// fire it. Phase 9 of the rqst→mnml port-back.
    HistoryRows,
    /// `id` = path of a `.curl` file under `.rqst/lookups/`. Accept
    /// ⇒ fire the file as a request in a background thread; when
    /// the response lands, parse the body for list items and open
    /// a [`PickerKind::LookupItem`] picker. Phase 7 of the
    /// rqst→mnml port-back.
    LookupFile,
    /// `id` = the index (as a string) into
    /// [`crate::app::App::pending_lookup_items`]. Accept ⇒ open a
    /// [`crate::prompt::PromptKind::LookupVarName`] prompt asking
    /// what env var name to write the picked item's id under.
    LookupItem,
    /// `id` = the key name (string) for an existing var, or the
    /// synthetic `"+add"` for the top-of-list "Add new variable…"
    /// row. Accept ⇒ open a
    /// [`crate::prompt::PromptKind::EnvEditValue`] prompt seeded
    /// with the current value (or
    /// [`crate::prompt::PromptKind::EnvAddKey`] for the `+add`
    /// case). Structured env editor — phase 3 polish.
    EnvVars,
    /// `id` = `<host>\t<name>` (tab-separated). Accept ⇒ copy
    /// `<name>=<value>` to clipboard so the user can paste it
    /// into a Cookie header. 2026-06-19 — cookie jar v1.
    Cookies,
    /// `id` = `<host>\t<name>` (same as Cookies). Accept ⇒
    /// remove that cookie from the jar + persist. 2026-06-20.
    CookiesDelete,
    /// `id` = the header name. Accept ⇒ insert `<id>: ` at the
    /// active Request pane's Headers cursor.
    HttpHeader,
    /// `id` = the auth preset filename stem (no extension). Accept
    /// ⇒ read `.mnml/auth/<id>.txt`, set the active Request pane's
    /// Authorization header to its content.
    AuthPresets,
    /// `id` = absolute path to a `.chain.json` file. Accept ⇒
    /// run the chain in a worker thread; the step-by-step trace
    /// lands in a `[chain-trace]` scratch. 2026-06-20 — Postman
    /// runner arc (chains are mnml's chain format; Postman
    /// collections feed in via `:http.import_postman` first).
    HttpChains,
    /// `id` = local branch name. Accept ⇒ open a confirm prompt
    /// before running `git branch -D`. 2026-06-21 — git polish.
    GitDeleteBranch,
    /// `id` = local branch name. Accept ⇒ `git merge <name>` into
    /// the current branch. Surfaces conflicts as a toast; the user
    /// resolves via the editor.
    GitMergeInto,
    /// `id` = branch name. Accept ⇒ `git rebase <name>` of the
    /// current branch onto the picked one.
    GitRebaseOnto,
    /// `id` = absolute path to a linked worktree. Accept ⇒ open
    /// that worktree as a workspace via `:open_workspace`. Useful
    /// when you've parked work in another worktree and want to
    /// jump into it without leaving mnml.
    GitWorktreeOpen,
    /// `id` = absolute path to a worktree to remove. Accept ⇒
    /// `git worktree remove <path>` (confirm prompt first).
    GitWorktreeRemove,
    /// 2026-06-21 — `id` = the directory name under `cmd/`.
    /// Accept ⇒ `go run ./cmd/<id>`. Opened by `:go.run` when
    /// the module has 2+ `cmd/<app>/` packages.
    GoRunCmd,
    /// 2026-06-21 — `id` = a wss:// URL from the WS history
    /// store. Accept ⇒ open that URL as a fresh `:ws.connect`
    /// (so the user can re-fire messages against the same
    /// server) and optionally seed the message log with the
    /// last N messages via a `[ws-history-<host>]` scratch.
    WsHistory,
    /// `id` = a `family_catalog::FamilySibling::id`. Accept ⇒
    /// `App::install_sibling(id)`. Used by the `mounts.install` /
    /// `sibling.install` palette commands.
    SiblingInstall,
    /// `id` = the codepoint hex string (e.g. `"F0E2D"`) of a
    /// browsable Nerd Font glyph. Accept ⇒ copy the literal char +
    /// the `\u{XXXX}` escape to clipboard and toast the result.
    /// Populated by `integrations.icon_picker`.
    IconGlyphs,
}

#[derive(Debug, Clone)]
pub struct PickerItem {
    pub id: String,
    /// The text shown and fuzzy-matched against.
    pub label: String,
    /// A right-aligned, dimmed hint (a keybinding, a directory, …).
    pub detail: String,
    /// vscode-user 3rd 2026-06-29 SEV-2: tie-breaker that beats
    /// fuzzy-score asymmetries. The file picker uses this to
    /// pin current-workspace files above cross-workspace recents
    /// even when the latter have shorter (and thus higher-scoring)
    /// labels like `lib.rs` vs `src/lib.rs`. Sort order in
    /// `refilter` is (priority desc, score desc, index asc).
    /// Default 0; higher = more preferred.
    pub priority: u8,
}

impl PickerItem {
    pub fn new(id: impl Into<String>, label: impl Into<String>, detail: impl Into<String>) -> Self {
        PickerItem {
            id: id.into(),
            label: label.into(),
            detail: detail.into(),
            priority: 0,
        }
    }
    pub fn with_priority(mut self, priority: u8) -> Self {
        self.priority = priority;
        self
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
    /// Columns per row when the picker is rendered as a grid
    /// (currently only `PickerKind::IconGlyphs`). `0` ⇒ list mode
    /// (Up/Down jump ±1). Set fresh by the renderer each frame from
    /// `list_area.width / cell_width`; nav uses it to jump ±grid_cols
    /// for Up/Down and ±1 for Left/Right.
    pub grid_cols: usize,
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
            grid_cols: 0,
        };
        p.refilter();
        p
    }

    fn refilter(&mut self) {
        // vscode-user 3rd 2026-06-29 SEV-2: sort tuple is
        // (priority desc, score desc, index asc). Items with a
        // higher `priority` win regardless of score — used by the
        // file picker to pin local-workspace files above
        // cross-workspace recents whose shorter labels would
        // otherwise out-score the local entries.
        let mut scored: Vec<(u8, i64, usize)> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(i, it)| {
                fuzzy_match(&self.query, &it.label).map(|(s, _)| (it.priority, s, i))
            })
            .collect();
        scored.sort_by(|a, b| {
            b.0.cmp(&a.0) // priority desc
                .then(b.1.cmp(&a.1)) // score desc
                .then(a.2.cmp(&b.2)) // index asc
        });
        self.filtered = scored.into_iter().map(|(_, _, i)| i).collect();
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
        let step = if self.grid_cols > 0 {
            self.grid_cols
        } else {
            1
        };
        let last = self.filtered.len().saturating_sub(1);
        self.selected = (self.selected + step).min(last);
    }
    pub fn move_up(&mut self) {
        let step = if self.grid_cols > 0 {
            self.grid_cols
        } else {
            1
        };
        self.selected = self.selected.saturating_sub(step);
    }
    /// Grid mode only — move one cell left. No-op in list mode.
    pub fn move_left(&mut self) {
        if self.grid_cols > 0 {
            self.selected = self.selected.saturating_sub(1);
        }
    }
    /// Grid mode only — move one cell right. No-op in list mode.
    pub fn move_right(&mut self) {
        if self.grid_cols > 0 && self.selected + 1 < self.filtered.len() {
            self.selected += 1;
        }
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

    /// vscode-user 3rd 2026-06-29 SEV-2 regression test: priority
    /// beats fuzzy score in `refilter`. A cross-workspace `lib.rs`
    /// (priority 1, shorter label, higher score) must rank BELOW
    /// a local `src/lib.rs` (priority 2, longer label, lower
    /// score).
    #[test]
    fn priority_beats_score_in_refilter() {
        let items = vec![
            // Cross-workspace recent — short label, high fuzzy score
            // for "lib", priority 1.
            PickerItem::new("/other/lib.rs", "lib.rs", "/other").with_priority(1),
            // Local file — longer label, lower fuzzy score for "lib",
            // priority 2.
            PickerItem::new("/here/src/lib.rs", "src/lib.rs", "src").with_priority(2),
        ];
        let mut pk = Picker::new(PickerKind::Files, "Open file", items);
        pk.type_char('l');
        pk.type_char('i');
        pk.type_char('b');
        let top = pk.selected_item().unwrap();
        assert_eq!(
            top.id, "/here/src/lib.rs",
            "priority 2 must beat the higher-scoring priority 1 cross-workspace item"
        );
    }
}
