//! Picker + prompt accept dispatchers + picker openers.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move.

use super::*;

impl App {
    pub fn open_picker(&mut self, picker: Picker) {
        self.whichkey = None;
        // 2026-06-20 — themes picker captures the pre-preview theme
        // so Esc restores it. set when the kind is Themes; cleared on
        // accept or restored on close.
        if matches!(picker.kind, crate::picker::PickerKind::Themes) {
            self.theme_preview_restore = Some(crate::ui::theme::cur().name.to_string());
        }
        self.picker = Some(picker);
    }

    /// Picker Up/Down hook — used for kind-specific previews. For
    /// the Themes picker, applies the highlighted theme live so
    /// the user can see it before committing.
    pub fn on_picker_moved(&mut self) {
        let Some(p) = self.picker.as_ref() else {
            return;
        };
        if !matches!(p.kind, crate::picker::PickerKind::Themes) {
            return;
        }
        let name = match p.selected_item() {
            Some(it) => it.id.clone(),
            None => return,
        };
        let _ = self.set_theme_silent(&name);
    }

    pub fn close_picker(&mut self) {
        // 2026-06-19 — api-workflow-user agent flagged that Esc
        // on a lookup-stage picker left `lookup_fire_rx` armed;
        // when the response landed, `App::tick`'s drain popped a
        // ghost LookupItem picker over whatever the user was now
        // doing. Drop the receiver here so the worker's send is
        // silently discarded.
        if matches!(
            self.picker.as_ref().map(|p| p.kind),
            Some(crate::picker::PickerKind::LookupFile)
                | Some(crate::picker::PickerKind::LookupItem)
        ) {
            self.lookup_fire_rx = None;
            self.pending_lookup_items.clear();
            self.pending_lookup_picked_id = None;
        }
        // 2026-06-21 — api-workflow SEV-1: `pending_history_rows`
        // is shared between :http.history (workspace) and
        // :http.history_global (cross-workspace). Esc on one and
        // opening the other left stale rows in the shared Vec,
        // so picker-index resolution at accept time pointed into
        // the wrong snapshot — either silently returning the
        // wrong workspace's curl or hitting `None` for high
        // indexes. Clear it on close so the next opener owns it.
        if matches!(
            self.picker.as_ref().map(|p| p.kind),
            Some(crate::picker::PickerKind::HistoryRows)
        ) {
            self.pending_history_rows.clear();
        }
        // Themes picker: if Esc-closed (no accept), restore the
        // pre-preview theme. Clear the snapshot either way.
        if matches!(
            self.picker.as_ref().map(|p| p.kind),
            Some(crate::picker::PickerKind::Themes)
        ) {
            if let Some(orig) = self.theme_preview_restore.take() {
                let _ = self.set_theme_silent(&orig);
            }
        }
        self.picker = None;
    }

    /// Open the fuzzy file finder over every file in the workspace. Recent
    /// files (from `App::recent_files`) are prepended in recency order so
    /// "Ctrl+P, Enter" jumps straight back to the last file — fuzzy
    /// `refilter` keeps original order on tie scores, and the empty-query
    /// score is constant, so the prepended order survives until the user
    /// types something.
    pub fn open_file_picker(&mut self) {
        use crate::picker::PickerItem;
        use std::collections::HashSet;
        let root = self.workspace.clone();
        let make_item = |p: &Path| -> PickerItem {
            let rel = p.strip_prefix(&root).unwrap_or(p).to_path_buf();
            let label = rel.to_string_lossy().to_string();
            let dir = rel
                .parent()
                .map(|d| d.to_string_lossy().to_string())
                .unwrap_or_default();
            PickerItem::new(p.to_string_lossy().to_string(), label, dir)
        };
        // Recents first (newest first; absolute paths only — non-workspace
        // entries silently come along, which is fine, they still open).
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut items: Vec<PickerItem> = Vec::new();
        for p in &self.recent_files {
            if seen.insert(p.clone()) && p.exists() {
                items.push(make_item(p));
            }
        }
        // Then the rest of the primary workspace, skipping anything already in.
        for p in self.tree.all_files() {
            if seen.insert(p.clone()) {
                items.push(make_item(&p));
            }
        }
        // Multi-root: extra workspaces' files too, after the primary's. They
        // keep their natural tree order but appear below the launched
        // workspace so the picker doesn't shuffle the user's mental model
        // of "this is the workspace I opened".
        for ws in &self.extra_workspaces {
            for p in ws.tree.all_files() {
                if seen.insert(p.clone()) {
                    items.push(make_item(&p));
                }
            }
        }
        self.open_picker(Picker::new(PickerKind::Files, "Open file", items));
    }

    /// Open a fuzzy picker over `App::recent_files` (most-recent first). The
    /// items keep that order — fuzzy filtering still works on the labels but
    /// the unfiltered list is recency-sorted (the picker doesn't auto-sort
    /// alphabetically), so just opening the picker + Enter goes "back" to the
    /// last file.
    pub fn open_recent_files_picker(&mut self) {
        use crate::picker::PickerItem;
        // Multi-root: build a list of candidate workspace roots (primary +
        // each extra) so a file from any of them gets the right relative
        // label rather than its full absolute path.
        let primary = self.workspace.clone();
        let extra_roots: Vec<std::path::PathBuf> = self
            .extra_workspaces
            .iter()
            .map(|w| w.root.clone())
            .collect();
        // Exclude the currently focused editor's file from the
        // recent-files picker. Selecting "the file I'm already
        // looking at" is a no-op and just steals the top row from
        // the file the user probably wants next.
        // vscode-mouse-2026-06-10 SEV-3 #8.
        let active_path: Option<std::path::PathBuf> = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                crate::pane::Pane::Editor(b) => b.path.clone(),
                _ => None,
            });
        let items: Vec<PickerItem> = self
            .recent_files
            .iter()
            .filter(|p| p.exists())
            .filter(|p| active_path.as_deref() != Some(p.as_path()))
            .map(|p| {
                // Pick the workspace this file belongs to (longest matching
                // prefix), then build the relative label. Files outside any
                // configured workspace use their absolute path.
                let rel = std::iter::once(&primary)
                    .chain(extra_roots.iter())
                    .filter_map(|root| p.strip_prefix(root).ok())
                    .next()
                    .unwrap_or(p.as_path())
                    .to_path_buf();
                let label = rel.to_string_lossy().to_string();
                let dir = rel
                    .parent()
                    .map(|d| d.to_string_lossy().to_string())
                    .unwrap_or_default();
                PickerItem::new(p.to_string_lossy().to_string(), label, dir)
            })
            .collect();
        if items.is_empty() {
            self.toast("no recent files yet");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Recent, "Recent files", items));
    }

    /// Open the buffer switcher over the currently-open panes.
    pub fn open_buffer_picker(&mut self) {
        use crate::picker::PickerItem;
        // Order: MRU first, then anything left over (panes opened but never
        // focused — shouldn't happen normally but the fallback keeps the list
        // complete). The active pane is dropped from the top so the picker
        // starts on the second-most-recent (vim's "alternate buffer" pattern
        // — pressing Enter on the picker swaps quickly).
        let mut ordered: Vec<usize> = Vec::with_capacity(self.panes.len());
        let active = self.active;
        for &id in self.pane_mru.iter() {
            if id < self.panes.len() && Some(id) != active && !ordered.contains(&id) {
                ordered.push(id);
            }
        }
        for i in 0..self.panes.len() {
            if Some(i) != active && !ordered.contains(&i) {
                ordered.push(i);
            }
        }
        // Active last (so it's still in the list, but at the bottom).
        if let Some(a) = active
            && a < self.panes.len()
        {
            ordered.push(a);
        }
        let items: Vec<PickerItem> = ordered
            .into_iter()
            .map(|i| {
                let p = &self.panes[i];
                PickerItem::new(
                    i.to_string(),
                    p.title(),
                    if p.is_dirty() { "●" } else { "" },
                )
            })
            .collect();
        if items.is_empty() {
            self.toast("no open buffers");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Buffers, "Switch buffer", items));
    }

    /// `tab.picker` — fuzzy picker over the tab pages. Each row labels
    /// the tab number, the active pane's display name (or `(empty)`),
    /// and a `●` chip when any pane in the tab has unsaved changes.
    /// The active tab sorts last so the picker opens cursored on the
    /// second-most-recent (mirrors `open_buffer_picker`).
    pub fn open_tab_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.layouts.len() <= 1 {
            self.toast("only one tab");
            return;
        }
        let active = self.active_layout;
        let mut order: Vec<usize> = (0..self.layouts.len()).filter(|&i| i != active).collect();
        order.push(active);
        let items: Vec<PickerItem> = order
            .into_iter()
            .map(|i| {
                // Tab's "headline" — last-focused pane's title.
                let head_title = self
                    .tab_actives
                    .get(i)
                    .copied()
                    .unwrap_or(None)
                    .or_else(|| self.layouts.get(i)?.first_leaf())
                    .and_then(|id| self.panes.get(id))
                    .map(|p| p.title())
                    .unwrap_or_else(|| "(empty)".to_string());
                // Dirty if any editor pane in the tab is dirty.
                let dirty = self
                    .layouts
                    .get(i)
                    .map(|l| l.leaves())
                    .unwrap_or_default()
                    .into_iter()
                    .any(|id| matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.dirty));
                let mark = if i == active { "●" } else { "" };
                PickerItem::new(
                    i.to_string(),
                    format!("{} {} {}", i + 1, mark, head_title)
                        .trim()
                        .to_string(),
                    if dirty { "● dirty" } else { "" }.to_string(),
                )
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Tabs, "Switch tab page", items));
    }

    /// `picker.marks` (`<leader>m m`) — fuzzy picker over every set mark.
    /// Buffer-local (lowercase) marks first, then global (uppercase) ones.
    /// Each row labels the letter, the file (relative), the line/col, and a
    /// short slice of the line text as a preview.
    pub fn open_marks_picker(&mut self) {
        use crate::picker::PickerItem;
        let mut items: Vec<PickerItem> = Vec::new();
        // Local marks for the active buffer.
        if let Some(b) = self.active_editor() {
            let mut local: Vec<(char, (usize, usize))> =
                b.marks.iter().map(|(&c, &v)| (c, v)).collect();
            local.sort_by_key(|(c, _)| *c);
            let text = b.editor.text();
            let path = b
                .path
                .as_ref()
                .map(|p| rel_path(&self.workspace, p))
                .unwrap_or_else(|| b.display_name().to_string());
            for (c, (row, col)) in local {
                let line = text.lines().nth(row).unwrap_or("").trim();
                let preview: String = line.chars().take(40).collect();
                items.push(PickerItem::new(
                    format!("local:{c}"),
                    format!("'{c}  {path}:{}:{}  {preview}", row + 1, col + 1),
                    "local".to_string(),
                ));
            }
        }
        // Global marks across the workspace.
        let mut global: Vec<(char, (PathBuf, usize, usize))> = self
            .global_marks
            .iter()
            .map(|(&c, v)| (c, v.clone()))
            .collect();
        global.sort_by_key(|(c, _)| *c);
        for (c, (path, row, col)) in global {
            let rel = rel_path(&self.workspace, &path);
            // Try to read a preview line from disk (fast, single line).
            let preview = std::fs::read_to_string(&path)
                .ok()
                .and_then(|text| text.lines().nth(row).map(|s| s.trim().to_string()))
                .unwrap_or_default();
            let preview: String = preview.chars().take(40).collect();
            items.push(PickerItem::new(
                format!("global:{}", c.to_ascii_lowercase()),
                format!("'{c}  {rel}:{}:{}  {preview}", row + 1, col + 1),
                "global".to_string(),
            ));
        }
        if items.is_empty() {
            self.toast("no marks set");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Marks, "Marks", items));
    }

    /// Open the command palette over the registered commands (builtins + any
    /// plugin-registered ones).
    pub fn open_command_palette(&mut self) {
        use crate::picker::PickerItem;
        // 2026-06-19 — keyboard hunt SEV-2: include the command
        // id in the label so a user typing the dotted id (VS Code
        // muscle memory) finds the command directly. The id renders
        // visually as a faint suffix; the fuzzy matcher (with its
        // _-stripping fix) treats `http.send_streaming` ≈ `httpsendstreaming`
        // ≈ both the id and the title text.
        let mut items: Vec<PickerItem> = crate::command::registry()
            .all()
            .iter()
            .filter(|c| c.id != "palette")
            .map(|c| {
                PickerItem::new(
                    c.id,
                    format!("{}  ·  {}  ·  {}", c.group, c.title, c.id),
                    c.key_hint(),
                )
            })
            .collect();
        for dc in &self.dynamic_commands {
            items.push(PickerItem::new(
                dc.id.clone(),
                format!("{}  ·  {}", dc.group, dc.title),
                dc.keys.join(" / "),
            ));
        }
        self.open_picker(Picker::new(PickerKind::Commands, "Command palette", items));
    }

    /// Open the theme picker over the built-in themes. Each row's detail
    /// column flags the currently-active theme and the configured default
    /// (`[ui] theme` from config.toml) so the user can tell at a glance
    /// which is which — useful when they've live-switched away.
    pub fn open_theme_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::ui::theme::cur().name;
        let default_name = self.config.ui.theme.clone();
        let toggle_name = self.config.ui.theme_toggle.clone();
        let items: Vec<PickerItem> = crate::ui::theme::names()
            .into_iter()
            .map(|n| {
                let mut tags: Vec<&str> = Vec::new();
                if n == cur {
                    tags.push("current");
                }
                if n.eq_ignore_ascii_case(&default_name) {
                    tags.push("default");
                }
                if let Some(alt) = toggle_name.as_deref()
                    && n.eq_ignore_ascii_case(alt)
                {
                    tags.push("toggle");
                }
                PickerItem::new(n, n, tags.join(" · "))
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Themes, "Theme", items));
    }

    /// Tab on a picker — picker-kind-specific "secondary accept".
    /// `OpenPullRequests`: cross-nav from a PR to its pipeline/build
    /// via the matching `mnml-forge-*` sibling's
    /// `--find-pipeline-for-pr --json` headless mode.
    pub fn picker_accept_secondary(&mut self) {
        let Some(picker) = self.picker.as_ref() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match picker.kind {
            PickerKind::OpenPullRequests => {
                // Take the picker so we close the overlay before the
                // (potentially-1s) sibling shellout — keeps the UI
                // responsive while we look up the pipeline URL.
                self.picker = None;
                self.accept_pr_picker_secondary(&item.id);
            }
            _ => self.toast("Tab → no secondary action for this picker"),
        }
    }

    pub fn picker_accept(&mut self) {
        let Some(picker) = self.picker.take() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match picker.kind {
            PickerKind::Files | PickerKind::Recent => self.open_path(Path::new(&item.id)),
            PickerKind::Harpoon => {
                if let Ok(slot1) = item.id.parse::<usize>() {
                    self.harpoon_goto(slot1);
                }
            }
            PickerKind::Buffers => {
                if let Ok(i) = item.id.parse::<usize>()
                    && i < self.panes.len()
                {
                    self.reveal_pane(i);
                }
            }
            PickerKind::Tabs => {
                if let Ok(i) = item.id.parse::<usize>()
                    && i < self.layouts.len()
                {
                    self.switch_tab(i);
                }
            }
            PickerKind::Commands => {
                crate::command::run(&item.id, self);
            }
            PickerKind::Themes => {
                self.theme_preview_restore = None;
                self.set_theme(&item.id);
            }
            PickerKind::Tasks => {
                self.run_task(&item.id);
            }
            PickerKind::Branches => self.checkout_branch(&item.id),
            PickerKind::Worktrees => self.open_worktree_shell(&item.id),
            PickerKind::Locations => {
                let mut parts = item.id.split('\t');
                if let (Some(p), Some(l), Some(c)) = (parts.next(), parts.next(), parts.next()) {
                    let path = std::path::PathBuf::from(p);
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    self.open_path(&path);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
            PickerKind::CodeActions => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.apply_code_action(idx);
                }
            }
            PickerKind::RenamePreview => {
                let edits = self.pending_rename_preview.take();
                if item.id == "apply"
                    && let Some(edits) = edits
                {
                    self.apply_rename_edits(edits);
                } else {
                    self.toast("rename: cancelled");
                }
            }
            PickerKind::Symbols => {
                let mut parts = item.id.split('\t');
                if let (Some(l), Some(c)) = (parts.next(), parts.next()) {
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
            PickerKind::BrowserTargets => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_browser_target(idx);
                }
            }
            PickerKind::BrowserHistory => self.browser_navigate_to(&item.id),
            PickerKind::BrowserDevices => {
                if item.id == "reset" {
                    self.browser_clear_device();
                } else if let Ok(idx) = item.id.parse::<usize>() {
                    self.browser_set_device(idx);
                }
            }
            PickerKind::BrowserNetworkThrottle => {
                self.browser_set_network_throttle(&item.id);
            }
            PickerKind::Snippets => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.snippet_insert_at_cursor(idx);
                }
            }
            PickerKind::Marks => {
                let mut parts = item.id.splitn(2, ':');
                if let (Some(scope), Some(letter_str)) = (parts.next(), parts.next())
                    && let Some(c) = letter_str.chars().next()
                {
                    match scope {
                        "local" => self.jump_to_mark(c, true),
                        "global" => self.jump_to_mark(c.to_ascii_uppercase(), true),
                        _ => {}
                    }
                }
            }
            PickerKind::FileHistory => self.open_commit_diff(&item.id),
            PickerKind::AiSessions => self.open_ai_session_mirror(&item.id),
            PickerKind::Clipboard => self.paste_register(&item.id),
            PickerKind::OpenPullRequests => {
                // Restored 2026-06-06 after the SCM split: dispatched
                // by `pr.picker` — Enter opens the chosen PR's URL.
                // The picker's secondary-accept (Tab) is handled
                // separately by `accept_pr_picker_secondary` invoked
                // from the picker keymap.
                self.accept_pr_picker_primary(&item.id);
            }
            PickerKind::Repos => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_active_repo(idx);
                }
            }
            PickerKind::Workspaces => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_workspace(idx);
                }
            }
            PickerKind::RemoveWorkspace => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.remove_workspace_runtime(idx);
                }
            }
            PickerKind::Tools => {
                // `id` is a `KNOWN_TOOLS[i].name`. Find the entry and
                // copy its install command to the clipboard.
                if let Some(tool) = crate::tools::KNOWN_TOOLS.iter().find(|t| t.name == item.id) {
                    self.clipboard.set(tool.install, false);
                    self.toast(format!("copied install: {}", tool.install));
                }
            }
            PickerKind::DapWatchRemove => {
                // `id` is the watch expression itself.
                let expr = item.id;
                self.dap_watches.retain(|w| w != &expr);
                self.dap_watch_results.remove(&expr);
                self.toast(format!("watch: − {expr}"));
            }
            PickerKind::DapAttach => {
                if let Ok(pid) = item.id.parse::<i64>() {
                    self.dap_attach_to_pid(pid);
                }
            }
            PickerKind::DapThread => {
                if let Ok(tid) = item.id.parse::<i64>() {
                    self.dap_switch_thread(tid);
                }
            }
            PickerKind::DapException => {
                self.dap_toggle_exception_filter(&item.id);
            }
            PickerKind::CallHierarchyItems => {
                // id = "<idx>\t<in|out>" — pull the picked item out of
                // the stash + fire the chosen-direction follow-up.
                let mut parts = item.id.splitn(2, '\t');
                let idx: usize = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                let dir = parts.next().unwrap_or("in");
                if let Some(picked) = self.pending_call_hierarchy_items.get(idx).cloned() {
                    match dir {
                        "out" => self.lsp.call_hierarchy_outgoing(&picked),
                        _ => self.lsp.call_hierarchy_incoming(&picked),
                    }
                    // Replace the stash with just the picked item so a
                    // future opposite-direction re-fire skips prepare.
                    self.pending_call_hierarchy_items = vec![picked];
                }
            }
            PickerKind::GitTags => {
                let name = item.id;
                match crate::git::tag::delete_local(self.active_repo_path(), &name) {
                    Ok(summary) => {
                        self.after_git_change();
                        self.refresh_active_git_graph();
                        self.toast(summary);
                    }
                    Err(e) => self.toast(format!("git tag -d: {e}")),
                }
            }
            PickerKind::StashesApply => {
                let stash_ref = item.id;
                match crate::git::stash::apply(self.active_repo_path(), &stash_ref) {
                    Ok(summary) => {
                        self.after_git_change();
                        self.tree.refresh();
                        self.toast(summary);
                    }
                    Err(e) => self.toast(format!("git stash apply: {e}")),
                }
            }
            PickerKind::StashesDrop => {
                // Phase-in confirm prompt instead of acting
                // immediately. Reflog-recoverable only until next
                // `git gc` (~30 days); a hard typed confirm matches
                // the branch-delete floor.
                // untouched-surfaces-hunt-2026-06-08 SEV-2 #8.
                let stash_ref = item.id;
                let label = item.label.clone();
                self.prompt = Some(crate::prompt::Prompt::seeded(
                    crate::prompt::PromptKind::GitStashDrop,
                    format!("Type 'drop' to delete {label}"),
                    "",
                ));
                self.pending_stash_drop = Some((stash_ref, label));
            }
            PickerKind::Reflog => {
                // `id` is the full hash — open it as a commit-diff pane.
                self.open_commit_diff(&item.id);
            }
            PickerKind::GitGraphBranchFilter => {
                self.apply_git_graph_branch_filter(if item.id == "--all" {
                    None
                } else {
                    Some(item.id.clone())
                });
            }
            PickerKind::SuggestBackend => {
                let id = item.id.clone();
                self.accept_suggest_backend(&id);
            }
            PickerKind::CapturedRows => {
                if let Ok(idx) = item.id.parse::<usize>()
                    && let Some(row) = self.pending_captured_rows.get(idx).cloned()
                {
                    self.open_curl_scratch(&row.to_curl(), &row.method, &row.url);
                }
                self.pending_captured_rows.clear();
            }
            PickerKind::HistoryRows => {
                if let Ok(idx) = item.id.parse::<usize>()
                    && let Some(v) = self.pending_history_rows.get(idx).cloned()
                {
                    let method = v
                        .get("method")
                        .and_then(|s| s.as_str())
                        .unwrap_or("GET")
                        .to_string();
                    let url = v
                        .get("url")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string();
                    // History only logs method + url, not headers /
                    // body — build a minimal curl from those.
                    let curl = format!("curl -X {method} '{url}'");
                    self.open_curl_scratch(&curl, &method, &url);
                }
                self.pending_history_rows.clear();
            }
            PickerKind::LookupFile => {
                let path = std::path::PathBuf::from(item.id.clone());
                self.accept_lookup_file(&path);
            }
            PickerKind::LookupItem => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.accept_lookup_item(idx);
                }
            }
            PickerKind::EnvVars => {
                let id = item.id.clone();
                self.accept_env_vars(&id);
            }
            PickerKind::HttpHeader => {
                let name = item.id.clone();
                self.accept_http_header(&name);
            }
            PickerKind::AuthPresets => {
                let name = item.id.clone();
                self.accept_auth_preset(&name);
            }
            PickerKind::HttpChains => {
                let path = std::path::PathBuf::from(item.id.clone());
                self.http_chain_run_path(path);
            }
            PickerKind::GitDeleteBranch => {
                self.git_delete_branch_confirm(item.id.clone());
            }
            PickerKind::GitMergeInto => {
                // 2026-06-21 vscode-user SEV-2: was running merge
                // unconditionally on accept, so a single mouse
                // click fast-forwarded the current branch onto
                // whatever was clicked — no confirm gate while
                // sibling pickers (delete_branch, worktree_remove)
                // do gate. Now mirrors those: stash the branch
                // name + open a confirm prompt typed-`merge`.
                self.pending_merge_source = Some(item.id.clone());
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::GitMergeConfirm,
                    format!("type 'merge' to merge {} into current", item.id),
                ));
            }
            PickerKind::GitRebaseOnto => {
                self.pending_rebase_onto = Some(item.id.clone());
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::GitRebaseConfirm,
                    format!("type 'rebase' to rebase current onto {}", item.id),
                ));
            }
            PickerKind::GitWorktreeOpen => {
                self.git_open_worktree(std::path::PathBuf::from(item.id.clone()));
            }
            PickerKind::GitWorktreeRemove => {
                let path = std::path::PathBuf::from(item.id.clone());
                self.pending_worktree_path = Some(path.clone());
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::WorktreeRemoveConfirm,
                    format!("type 'remove' to drop worktree {}", path.display()),
                ));
            }
            PickerKind::GoRunCmd => {
                let app = item.id.clone();
                self.run_manifest_command("go.mod", "go", &format!("run ./cmd/{app}"));
            }
            PickerKind::GrpcService => {
                let service = item.id.clone();
                self.grpc_discover_service(service);
            }
            PickerKind::GrpcMethod => {
                let method = item.id.clone();
                self.grpc_discover_method(method);
            }
            PickerKind::WsHistory => {
                let url = item.id.clone();
                self.ws_history_open(url);
            }
            PickerKind::CookiesDelete => {
                if let Some((host, name)) = item.id.split_once('\t') {
                    let removed = {
                        let Ok(mut jar) = self.cookie_jar.lock() else {
                            self.toast("cookies: jar lock poisoned");
                            return;
                        };
                        jar.remove(host, name)
                    };
                    if removed {
                        let Ok(jar) = self.cookie_jar.lock() else {
                            return;
                        };
                        let _ = jar.save(&self.workspace);
                        drop(jar);
                        self.toast(format!("cookies: removed {host} · {name}"));
                    } else {
                        self.toast("cookies: not found");
                    }
                }
            }
            PickerKind::Cookies => {
                // id shape: `<host>\t<name>`.
                let lookup = item.id.split_once('\t').and_then(|(host, name)| {
                    let jar = self.cookie_jar.lock().ok()?;
                    let val = jar.iter().find_map(|(h, n, v)| {
                        if h == host && n == name {
                            Some(v.to_string())
                        } else {
                            None
                        }
                    });
                    val.map(|v| (name.to_string(), v))
                });
                if let Some((name, v)) = lookup {
                    let pair = format!("{name}={v}");
                    self.clipboard.set(pair.clone(), false);
                    self.toast(format!("cookies: copied {pair}"));
                }
            }
        }
    }

    /// Open a fuzzy picker over the repos discovered in the workspace.
    /// Accept ⇒ [`Self::switch_active_repo`]. No-op when there's only one
    /// repo or none.
    pub fn open_repo_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.repos.len() <= 1 {
            self.toast("only one repo in this workspace");
            return;
        }
        let items: Vec<PickerItem> = self
            .repos
            .iter()
            .enumerate()
            .map(|(i, r)| {
                let active_marker = if i == self.active_repo { "● " } else { "  " };
                let label = format!("{active_marker}{}", r.name);
                let detail = r
                    .path
                    .strip_prefix(&self.workspace)
                    .ok()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_else(|| r.path.to_string_lossy().into_owned());
                PickerItem::new(i.to_string(), label, detail)
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Repos, "Switch repo", items));
    }

    /// Picker over the primary + every configured extra workspace. Accept ⇒
    /// `switch_workspace(idx)` — for the primary that just refocuses the
    /// rail; for an extra it expands that section + collapses others. No-op
    /// when no extras are configured.
    pub fn open_workspace_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.extra_workspaces.is_empty() {
            self.toast("no extra workspaces — add `[[workspaces]]` to config.toml");
            return;
        }
        let primary_name = self
            .workspace
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("workspace")
            .to_string();
        let mut items: Vec<PickerItem> = Vec::with_capacity(self.extra_workspaces.len() + 1);
        items.push(PickerItem::new(
            "0".to_string(),
            format!("● {primary_name}"),
            self.workspace.to_string_lossy().into_owned(),
        ));
        for (i, w) in self.extra_workspaces.iter().enumerate() {
            let marker = if w.expanded { "● " } else { "  " };
            items.push(PickerItem::new(
                (i + 1).to_string(),
                format!("{marker}{}", w.name),
                w.root.to_string_lossy().into_owned(),
            ));
        }
        self.open_picker(Picker::new(
            PickerKind::Workspaces,
            "Switch workspace",
            items,
        ));
    }

    /// Picker over removable (extra) workspaces. Accept ⇒
    /// [`Self::remove_workspace_runtime`].
    pub fn open_remove_workspace_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.extra_workspaces.is_empty() {
            self.toast("no extra workspaces to remove");
            return;
        }
        let items: Vec<PickerItem> = self
            .extra_workspaces
            .iter()
            .enumerate()
            .map(|(i, w)| {
                PickerItem::new(
                    (i + 1).to_string(),
                    w.name.clone(),
                    w.root.to_string_lossy().into_owned(),
                )
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::RemoveWorkspace,
            "Remove workspace",
            items,
        ));
    }

    /// `task.run` — open a picker over `[tasks.<name>]` config entries.
    pub fn open_task_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.config.tasks.is_empty() {
            self.toast("no [tasks.*] defined in config".to_string());
            return;
        }
        let items: Vec<PickerItem> = self
            .config
            .tasks
            .iter()
            .map(|(name, t)| PickerItem::new(name.clone(), name.clone(), t.cmd.clone()))
            .collect();
        self.open_picker(Picker::new(PickerKind::Tasks, "Run task", items));
    }

    /// `picker.recent_commands` — fuzzy picker over the most-recently-
    /// run commands (newest first). Distinct from `palette` (alphabetical
    /// over all builtins + dynamic).
    pub fn open_recent_commands_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.recent_commands.is_empty() {
            self.toast("no recent commands yet");
            return;
        }
        let items: Vec<PickerItem> = self
            .recent_commands
            .iter()
            .filter_map(|id| {
                crate::command::registry().get(id).map(|cmd| {
                    PickerItem::new(
                        cmd.id,
                        format!("{}  ·  {}", cmd.group, cmd.title),
                        cmd.key_hint(),
                    )
                })
            })
            .collect();
        if items.is_empty() {
            self.toast("no recent commands resolvable");
            return;
        }
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Commands,
            "Recent commands",
            items,
        ));
    }

    /// `picker.clipboard` — pick from the named-register history
    /// (`"a`-`"z`, `"0` last yank, `"1`-`"9` delete history) and paste
    /// the chosen entry at the cursor. Useful for "pull back something I
    /// deleted three operations ago" without remembering its register.
    pub fn open_clipboard_picker(&mut self) {
        let registers = self.clipboard.named_registers();
        if registers.is_empty() {
            self.toast("clipboard: no register history");
            return;
        }
        let mut entries: Vec<(char, String, bool)> = registers
            .iter()
            .map(|(c, (t, lw))| (*c, t.clone(), *lw))
            .filter(|(_, t, _)| !t.is_empty())
            .collect();
        // Show numeric registers in ascending order (0..=9), then a..z.
        entries.sort_by(|a, b| {
            let key = |c: char| match c {
                '0'..='9' => (0u8, c),
                _ => (1, c),
            };
            key(a.0).cmp(&key(b.0))
        });
        let items: Vec<crate::picker::PickerItem> = entries
            .into_iter()
            .map(|(reg, text, linewise)| {
                let mut preview: String = text.replace('\n', "↵");
                let n_chars = preview.chars().count();
                if n_chars > 80 {
                    preview = preview.chars().take(80).collect::<String>() + "…";
                }
                let detail = if linewise { "linewise" } else { "" };
                crate::picker::PickerItem::new(
                    reg.to_string(),
                    format!("\"{reg}  {preview}"),
                    detail.to_string(),
                )
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Clipboard,
            "Clipboard / registers",
            items,
        ));
    }

    /// `git.file_history` — fuzzy picker over commits that touched the active
    /// file (`git log --follow`, capped at 200). Accept opens a diff pane for
    /// the chosen commit.
    pub fn open_file_history_picker(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("file history needs a saved file");
            return;
        };
        let repo = self.active_repo_path().to_path_buf();
        let rel = match path.strip_prefix(&repo) {
            Ok(r) => r.to_string_lossy().to_string(),
            Err(_) => {
                self.toast("file is outside the active git repo");
                return;
            }
        };
        let commits = crate::git::log::commits_for_file(&repo, &rel);
        if commits.is_empty() {
            self.toast("no commits touched this file");
            return;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let items: Vec<crate::picker::PickerItem> = commits
            .into_iter()
            .map(|c| {
                let age = crate::ui::git_graph_view::humanize_age(now.saturating_sub(c.time));
                crate::picker::PickerItem::new(
                    c.hash,
                    format!("{}  {}", c.short, c.subject),
                    format!("{age} · {}", c.author),
                )
            })
            .collect();
        let title = format!("File history — {rel}");
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::FileHistory,
            title,
            items,
        ));
    }

    /// `git.tag_delete` — open a picker over every local tag (newest-creation
    /// first). Accept ⇒ `git tag -d <name>`. No confirmation step — tags are
    /// cheap to re-create.
    pub fn open_git_tag_delete_picker(&mut self) {
        let tags = crate::git::tag::list(self.active_repo_path());
        if tags.is_empty() {
            self.toast("git tag: no local tags");
            return;
        }
        let items: Vec<crate::picker::PickerItem> = tags
            .iter()
            .map(|name| crate::picker::PickerItem::new(name, name, "delete"))
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::GitTags,
            format!("Delete tag ({} local)", tags.len()),
            items,
        ));
    }

    pub fn prompt_cancel(&mut self) {
        // Esc-cancel on a Find prompt restores the editor's prior find state
        // (incremental preview is dropped).
        let kind = self.prompt.as_ref().map(|p| p.kind);
        let was_find = matches!(kind, Some(crate::prompt::PromptKind::Find));
        // Esc on a tool-confirm prompt means "deny" — the blocked agent
        // worker is waiting for an answer.
        if matches!(kind, Some(crate::prompt::PromptKind::AiToolConfirm)) {
            self.resolve_tool_confirm(false);
        }
        self.prompt = None;
        self.pending_rename = None;
        self.pending_fs_action = None;
        self.pending_delete_branch = None;
        self.pending_worktree_remove = None;
        self.pending_branch_source = None;
        self.rename_preview_state = None;
        // 2026-06-21 — power-user-ws-git SEV-1: Esc on the
        // `:git.worktree_add` path prompt left
        // `pending_worktree_path = Some(empty)` stuck, so the very
        // next `view.add_workspace` (which reuses the AddWorkspace
        // PromptKind) silently hijacked the typed path into the
        // worktree-add flow. Clear it alongside the other path
        // stashes.
        self.pending_worktree_path = None;
        self.pending_branch_delete = None;
        self.pending_merge_source = None;
        self.pending_rebase_onto = None;
        self.pending_kill_pid = None;
        self.pending_kill_batch.clear();
        // 2026-06-19 — api-workflow-user SEV-3: Esc on a lookup
        // var-name / env edit prompt left these stashes set, so the
        // next picker accept of the same type could fire against
        // stale state.
        self.pending_lookup_picked_id = None;
        self.pending_env_edit_key = None;
        if was_find {
            self.restore_find_preview_snapshot();
            self.find_pending_range = None;
        }
    }

    pub fn prompt_accept(&mut self) {
        let Some(mut p) = self.prompt.take() else {
            return;
        };
        match p.kind {
            crate::prompt::PromptKind::AddWorkspace => {
                // If the user picked a row from the live directory
                // listing (↑↓ then Enter), that path wins over the
                // typed input — the row's `take_selected_input`
                // returns the full path with tilde already expanded.
                let from_selected = p.take_selected_input();
                let raw = from_selected.unwrap_or_else(|| p.input.trim().to_string());
                let input = raw.trim();
                if input.is_empty() {
                    return;
                }
                let path = if let Some(rest) = input.strip_prefix("~/") {
                    if let Some(home) = std::env::var_os("HOME") {
                        PathBuf::from(home).join(rest)
                    } else {
                        PathBuf::from(input)
                    }
                } else {
                    PathBuf::from(input)
                };
                // Sentinel: `:git.worktree_add` set
                // pending_worktree_path to an empty path before
                // opening this prompt. Reroute the path to the
                // worktree-add flow instead of opening a workspace.
                if self
                    .pending_worktree_path
                    .as_ref()
                    .is_some_and(|p| p.as_os_str().is_empty())
                {
                    self.git_worktree_add_path_chosen(path);
                    return;
                }
                self.add_workspace_runtime(path, None);
            }
            crate::prompt::PromptKind::GitCommit => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("commit cancelled (empty message)");
                    return;
                }
                match crate::git::commit::commit(self.active_repo_path(), msg) {
                    Ok(summary) => {
                        self.toast(summary);
                        self.note_commit_for_undo();
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit: {e}")),
                }
            }
            crate::prompt::PromptKind::GitCommitAmend => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("amend cancelled (empty message)");
                    return;
                }
                match crate::git::commit::amend(self.active_repo_path(), msg) {
                    Ok(summary) => {
                        self.toast(format!("amended: {summary}"));
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit --amend: {e}")),
                }
            }
            crate::prompt::PromptKind::GitStashMessage => {
                let msg = p.input.trim();
                let msg_opt = if msg.is_empty() { None } else { Some(msg) };
                self.run_git_stash_push(msg_opt);
            }
            crate::prompt::PromptKind::GitTag => {
                let name = p.input.trim().to_string();
                if name.is_empty() {
                    self.toast("tag cancelled (empty name)");
                    return;
                }
                let target = self.selected_graph_commit_hash();
                match crate::git::tag::create_annotated(
                    self.active_repo_path(),
                    &name,
                    &name,
                    target.as_deref(),
                ) {
                    Ok(summary) => {
                        self.after_git_change();
                        self.refresh_active_git_graph();
                        self.toast(summary);
                    }
                    Err(e) => self.toast(format!("git tag: {e}")),
                }
            }
            crate::prompt::PromptKind::DapAddWatch => {
                let expr = p.input.trim().to_string();
                if expr.is_empty() {
                    return;
                }
                if !self.dap_watches.iter().any(|w| w == &expr) {
                    self.dap_watches.push(expr.clone());
                }
                // Fire an immediate `evaluate` if we're stopped at a
                // breakpoint so the row populates without waiting for
                // the next stop. No-op when no session is active.
                let frame_id = self
                    .dap
                    .as_ref()
                    .and_then(|m| m.stack_frames.first().map(|f| f.id));
                if let (Some(mgr), Some(fid)) = (self.dap.as_mut(), frame_id) {
                    let _ = mgr.client.evaluate(&expr, Some(fid), "watch");
                }
                self.toast(format!("watch: + {expr}"));
            }
            crate::prompt::PromptKind::DapBreakpointCondition => {
                let cond = p.input.trim().to_string();
                let pending = self.dap_pending_bp_condition.take();
                let Some((line0, path)) = pending else {
                    return;
                };
                self.set_breakpoint_condition(&path, line0, cond);
            }
            crate::prompt::PromptKind::DapBreakpointHitCount => {
                let hit = p.input.trim().to_string();
                let pending = self.dap_pending_bp_condition.take();
                let Some((line0, path)) = pending else {
                    return;
                };
                self.set_breakpoint_hit_condition(&path, line0, hit);
            }
            crate::prompt::PromptKind::DapSetVariable => {
                let new_value = p.input.clone();
                let Some((parent_ref, name)) = self.dap_pending_set_variable.take() else {
                    return;
                };
                let Some(mgr) = self.dap.as_mut() else {
                    self.toast("dap: no session");
                    return;
                };
                if let Err(e) = mgr.client.set_variable(parent_ref, &name, &new_value) {
                    self.toast(format!("dap setVariable: {e}"));
                }
            }
            crate::prompt::PromptKind::AiAsk => {
                let q = p.input.trim();
                if q.is_empty() {
                    return;
                }
                let short: String = q.chars().take(24).collect();
                let ellip = if q.chars().count() > 24 { "…" } else { "" };
                self.ask_ai(format!("AI: {short}{ellip}"), q.to_string());
            }
            crate::prompt::PromptKind::NewBranch => {
                let name = p.input.clone();
                self.create_branch(&name);
            }
            crate::prompt::PromptKind::LspRename => {
                let new_name = p.input.trim().to_string();
                // Clear the preview before either path returns — keeps the
                // overlay from leaking past the accept moment.
                self.rename_preview_state = None;
                let Some((path, line, ch)) = self.pending_rename.take() else {
                    return;
                };
                if new_name.is_empty() {
                    self.toast("rename cancelled (empty name)");
                    return;
                }
                // Sync the buffer's current text so the server's positions line up.
                let text = self.panes.iter().find_map(|p| match p {
                    Pane::Editor(b) if b.is_at(&path) => Some(b.editor.text().to_string()),
                    _ => None,
                });
                if let Some(t) = text {
                    self.lsp.did_change(&path, &t);
                }
                if !self.lsp.rename(&path, line, ch, &new_name) {
                    self.toast("no language server for this file (rename)");
                }
            }
            crate::prompt::PromptKind::BrowserUrl => self.open_browser(p.input.trim()),
            crate::prompt::PromptKind::BrowserNavigate => {
                let url = p.input.clone();
                if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    b.navigate(&url);
                }
            }
            crate::prompt::PromptKind::BrowserCookieEdit => {
                self.accept_cookie_edit(p.input.clone())
            }
            crate::prompt::PromptKind::BrowserCookieAdd => self.accept_cookie_add(p.input.clone()),
            crate::prompt::PromptKind::BrowserStorageEdit => {
                self.accept_storage_edit(p.input.clone())
            }
            crate::prompt::PromptKind::BrowserStorageAdd => {
                self.accept_storage_add(p.input.clone())
            }
            crate::prompt::PromptKind::BrowserEval => {
                let expr = p.input.clone();
                if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    b.eval(&expr);
                }
            }
            crate::prompt::PromptKind::Find => {
                let q = p.input.clone();
                // Live-preview is the new find state already; commit it.
                self.find_preview_snapshot = None;
                self.accept_find(q);
            }
            crate::prompt::PromptKind::Replace => {
                let r = p.input.clone();
                self.accept_replace(r);
            }
            crate::prompt::PromptKind::Grep => {
                let q = p.input.clone();
                self.run_workspace_grep(q);
            }
            crate::prompt::PromptKind::GrepReplace => {
                let r = p.input.clone();
                self.run_grep_replace(r);
            }
            crate::prompt::PromptKind::GotoLine => {
                let s = p.input.trim().to_string();
                self.goto_line_str(&s);
            }
            crate::prompt::PromptKind::PatchNerdFontSvg => {
                let svg = p.input.trim().to_string();
                self.run_patch_nerd_font_svg(&svg);
            }
            crate::prompt::PromptKind::LookupVarName => {
                let var = p.input.trim().to_string();
                self.accept_lookup_var_name(&var);
            }
            crate::prompt::PromptKind::EnvEditValue => {
                let v = p.input.clone();
                self.accept_env_edit_value(&v);
            }
            crate::prompt::PromptKind::EnvAddKey => {
                let v = p.input.clone();
                self.accept_env_add_key(&v);
            }
            crate::prompt::PromptKind::HttpParamAdd => {
                let v = p.input.clone();
                self.accept_http_param_add(&v);
            }
            crate::prompt::PromptKind::AuthSavePreset => {
                let v = p.input.clone();
                self.accept_auth_save_preset(&v);
            }
            crate::prompt::PromptKind::AiAskAboutRequest => {
                let q = p.input.clone();
                self.ai_ask_about_request_with_question(&q);
            }
            crate::prompt::PromptKind::HttpSaveResponse => {
                let path = p.input.clone();
                self.http_save_response_to(&path);
            }
            crate::prompt::PromptKind::HttpAuthBearer => {
                let tok = p.input.clone();
                self.http_auth_set("Authorization", &format!("Bearer {tok}"));
            }
            crate::prompt::PromptKind::HttpAuthBasic => {
                use base64::prelude::*;
                let creds = p.input.clone();
                let encoded = BASE64_STANDARD.encode(creds.as_bytes());
                self.http_auth_set("Authorization", &format!("Basic {encoded}"));
            }
            crate::prompt::PromptKind::HttpAuthApiKey => {
                let key = p.input.clone();
                self.http_auth_set("X-Api-Key", &key);
            }
            crate::prompt::PromptKind::WsConnect => {
                let url = p.input.clone();
                self.ws_connect_to(&url);
            }
            crate::prompt::PromptKind::WsSendMessage => {
                let msg = p.input.clone();
                self.ws_send_on_active(&msg);
            }
            crate::prompt::PromptKind::HttpAiBuild => {
                let description = p.input.clone();
                self.http_ai_build_accept(description);
            }
            crate::prompt::PromptKind::ClaudeSessionSearch => {
                let q = p.input.clone();
                self.ai_session_search_run(q);
            }
            crate::prompt::PromptKind::AiBranchNameDescription => {
                let description = p.input.clone();
                self.ai_write_branch_name_accept(description);
            }
            crate::prompt::PromptKind::BranchName => {
                let name = p.input.trim().to_string();
                if name.is_empty() {
                    self.toast("branch name empty");
                    return;
                }
                match crate::git::branch::create(self.active_repo_path(), &name) {
                    Ok(()) => self.toast(format!("created + checked out {name}")),
                    Err(e) => self.toast(format!("branch {name}: {e}")),
                }
            }
            crate::prompt::PromptKind::WorktreeBranchName => {
                let branch = p.input.clone();
                self.git_worktree_add_apply(branch);
            }
            crate::prompt::PromptKind::NpmRunScript => {
                let script = p.input.clone();
                self.npm_run_script_accept(script);
            }
            crate::prompt::PromptKind::GoRunPath => {
                let path = p.input.clone();
                self.go_run_path_accept(path);
            }
            crate::prompt::PromptKind::GrpcDiscoverHost => {
                let host = p.input.clone();
                self.grpc_discover_host(host);
            }
            crate::prompt::PromptKind::GitMergeConfirm => {
                if p.input.trim().eq_ignore_ascii_case("merge") {
                    if let Some(branch) = self.pending_merge_source.take() {
                        self.git_merge_branch(branch);
                    }
                } else {
                    self.pending_merge_source = None;
                    self.toast("merge cancelled");
                }
            }
            crate::prompt::PromptKind::GitRebaseConfirm => {
                if p.input.trim().eq_ignore_ascii_case("rebase") {
                    if let Some(target) = self.pending_rebase_onto.take() {
                        self.git_rebase_onto(target);
                    }
                } else {
                    self.pending_rebase_onto = None;
                    self.toast("rebase cancelled");
                }
            }
            crate::prompt::PromptKind::WorktreeRemoveConfirm => {
                if p.input.trim().eq_ignore_ascii_case("remove") {
                    self.git_worktree_remove_apply();
                } else {
                    self.pending_worktree_path = None;
                    self.toast("worktree remove cancelled");
                }
            }
            crate::prompt::PromptKind::GitDeleteBranchConfirm => {
                if p.input.trim().eq_ignore_ascii_case("delete") {
                    self.git_delete_branch_apply();
                } else {
                    self.pending_branch_delete = None;
                    self.toast("branch delete cancelled");
                }
            }
            crate::prompt::PromptKind::ClaudeKillConfirm => {
                if p.input.trim().eq_ignore_ascii_case("kill") {
                    self.claude_agents_kill_confirmed();
                } else {
                    self.pending_kill_pid = None;
                    self.pending_kill_batch.clear();
                    self.toast("kill cancelled (type 'kill' to confirm)");
                }
            }
            crate::prompt::PromptKind::NewFile => {
                let name = p.input.clone();
                if let Some(FsAction::NewFile { parent }) = self.pending_fs_action.take() {
                    self.create_new_file(&parent, &name);
                }
            }
            crate::prompt::PromptKind::NewFolder => {
                let name = p.input.clone();
                if let Some(FsAction::NewFolder { parent }) = self.pending_fs_action.take() {
                    self.create_new_folder(&parent, &name);
                }
            }
            crate::prompt::PromptKind::Rename => {
                let name = p.input.clone();
                if let Some(FsAction::Rename { path }) = self.pending_fs_action.take() {
                    self.rename_fs_entry(&path, &name);
                }
            }
            crate::prompt::PromptKind::DeleteConfirm => {
                let typed = p.input.clone();
                if let Some(FsAction::Delete { path }) = self.pending_fs_action.take() {
                    self.confirm_delete_fs_entry(&path, &typed);
                }
            }
            crate::prompt::PromptKind::GitDeleteBranch => {
                self.confirm_delete_branch(p.input.clone());
            }
            crate::prompt::PromptKind::GitWorktreeRemove => {
                self.confirm_worktree_remove(p.input.clone());
            }
            crate::prompt::PromptKind::GitStashDrop => {
                self.confirm_stash_drop(p.input.clone());
            }
            crate::prompt::PromptKind::GitTagDelete => {
                self.confirm_tag_delete(p.input.clone());
            }
            crate::prompt::PromptKind::WorkspaceRename => {
                let typed = p.input.clone();
                self.commit_workspace_rename(&typed);
            }
            crate::prompt::PromptKind::WorkspacePathEdit => {
                let typed = p.input.clone();
                self.commit_workspace_path_edit(&typed);
            }
            crate::prompt::PromptKind::WorkspaceGroupEdit => {
                let typed = p.input.clone();
                self.commit_workspace_group_edit(&typed);
            }
            crate::prompt::PromptKind::LspWorkspaceSymbol => {
                let q = p.input.clone();
                self.run_workspace_symbol_query(&q);
            }
            crate::prompt::PromptKind::DiffDiscardHunk => {
                let typed = p.input.clone();
                self.accept_discard_hunk(&typed);
            }
            crate::prompt::PromptKind::GitDiscardFile => {
                let typed = p.input.clone();
                self.accept_discard_file(&typed);
            }
            crate::prompt::PromptKind::GitGraphDateFilter => {
                let typed = p.input.clone();
                self.apply_git_graph_date_filter(&typed);
            }
            crate::prompt::PromptKind::GitGraphAuthorFilter => {
                let typed = p.input.clone();
                self.apply_git_graph_author_filter(&typed);
            }
            crate::prompt::PromptKind::GitGraphGrepFilter => {
                let typed = p.input.clone();
                self.apply_git_graph_grep_filter(&typed);
            }
            crate::prompt::PromptKind::TreeMoveConfirm => {
                self.accept_tree_move();
            }
            crate::prompt::PromptKind::QuitConfirm => {
                self.accept_quit();
            }
            crate::prompt::PromptKind::AiToolConfirm => {
                self.resolve_tool_confirm(true);
            }
            crate::prompt::PromptKind::AiChat => {
                let typed = p.input.clone();
                self.dispatch_ai_chat(&typed);
            }
            crate::prompt::PromptKind::PtySessionName => {
                let typed = p.input.clone();
                self.rename_active_pty(&typed);
            }
            crate::prompt::PromptKind::DockWidgetRename => {
                let typed = p.input.clone();
                self.rename_dock_widget(&typed);
            }
        }
    }
}

#[cfg(test)]
mod picker_tests {
    use super::*;

    // Cross-host PR picker removed after the 2026-06 SCM split —
    // per-host happy-path tests live in each forge sibling's own repo.

    #[test]
    fn open_repo_picker_no_op_when_single() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join(".git")).unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_repo_picker();
        // Only one repo ⇒ no picker.
        assert!(app.picker.is_none());
    }
}
