//! Workspace management methods on `App` (A-4 of the file-split
//! refactor — 2026-06-28). Owns runtime add/remove/switch/promote
//! across primary + extra workspaces, plus the workspaces-editor
//! overlay (rename, path edit, group edit, kebab menu).
//!
//! Extracted from `src/app/mod.rs`. Pure non-destructive move — every
//! method keeps its signature + visibility, only the file changes.

use super::*;

impl App {
    pub fn toggle_extra_workspace(&mut self, ws_idx: usize) {
        if let Some(ws) = self.extra_workspaces.get_mut(ws_idx) {
            ws.expanded = !ws.expanded;
        }
    }

    /// Handle a click on a row inside an extra-workspace's body. Updates that
    /// tree's cursor, then opens the file or toggles the dir under it. Repo-
    /// dir clicks also switch the active repo (sibling of the primary-tree
    /// behavior in `tui::dispatch_mouse`).
    pub fn click_extra_workspace_row(&mut self, ws_idx: usize, row_idx: usize) {
        self.click_extra_workspace_row_ex(ws_idx, row_idx, false);
    }

    /// Handle a click on a row inside an extra-workspace's body. Updates that
    /// tree's cursor, then opens the file or toggles the dir under it.
    /// `recursive = true` triggers recursive expand/collapse on the dir
    /// (Alt+click gesture). Repo-dir clicks also switch the active repo
    /// (sibling of the primary-tree behavior in `tui::dispatch_mouse`).
    pub fn click_extra_workspace_row_ex(&mut self, ws_idx: usize, row_idx: usize, recursive: bool) {
        let Some(ws) = self.extra_workspaces.get_mut(ws_idx) else {
            return;
        };
        let rows = ws.tree.visible_rows();
        if row_idx >= rows.len() {
            return;
        }
        ws.tree.set_cursor(row_idx);
        // Park keyboard focus on this extra workspace so the
        // renderer draws a cursor highlight + so future arrow
        // keys move within this tree (not the primary one).
        self.focus_tree();
        self.focused_extra_ws = Some(ws_idx);
        self.rail_section = RailSection::Workspace;
        let row = rows[row_idx].clone();
        if row.is_dir {
            // Multi-repo: clicking a depth-0 repo dir activates that repo so
            // the git rail follows. Same gesture as the primary tree.
            if row.depth == 0 && self.repos.len() > 1 {
                let repo_hit = self.repos.iter().position(|r| r.path == row.path);
                if let Some(idx) = repo_hit
                    && idx != self.active_repo
                {
                    self.switch_active_repo(idx);
                }
            }
            // Refetch the tree (may have been mutated by switch_active_repo)
            // and toggle. We only need the path's dir state to decide.
            if let Some(ws) = self.extra_workspaces.get_mut(ws_idx) {
                if recursive {
                    ws.tree.toggle_current_recursive();
                } else {
                    ws.tree.toggle_current();
                }
            }
        } else {
            self.open_path(&row.path);
        }
    }

    /// Runtime add: append a new extra workspace at `path` with a name
    /// derived from the path's basename (or the user-supplied name). Builds
    /// the tree + appends repos to the unified `repos` list. The new entry
    /// shows up as a new collapsible section in the rail; not persisted to
    /// config.toml — the user has to add the `[[workspaces]]` entry there
    /// for it to survive a relaunch (caller toasts the hint).
    pub fn add_workspace_runtime(&mut self, path: PathBuf, name: Option<String>) {
        let root = match path.canonicalize() {
            Ok(p) => p,
            Err(e) => {
                self.toast(format!("can't open workspace: {e}"));
                return;
            }
        };
        if root == self.workspace || self.extra_workspaces.iter().any(|w| w.root == root) {
            self.toast("workspace already open");
            return;
        }
        let resolved_name = name.unwrap_or_else(|| {
            root.file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| root.to_string_lossy().into_owned())
        });
        // Empty-state special case: when the primary workspace is
        // $HOME (the "no workspace open" landing), promote the new
        // path to primary rather than adding as an extra. Otherwise
        // the empty-state widget stays visible alongside the new
        // tree, which is the user-confusing state described in the
        // bug report. From a real primary workspace, fall through
        // to the existing add-as-extra path.
        if is_home_workspace(&self.workspace) {
            self.promote_to_primary_workspace(root, resolved_name);
            return;
        }
        // qa-feature 2026-07-01 — new workspaces open COLLAPSED at
        // the top level. Was: `expanded: true` + auto-expand of the
        // first sub-repo, which slammed the rail with a full tree the
        // moment you opened a second workspace. User asked for each
        // workspace to sit as a collapsed root; the user drills in
        // manually.
        let tree = Tree::open(&root);
        let mut found = crate::git::repos::discover_repos(&root);
        let position = self.next_free_workspace_position();
        self.extra_workspaces.push(ExtraWorkspace {
            name: resolved_name.clone(),
            root,
            tree,
            expanded: false,
            position,
        });
        self.repos.append(&mut found);
        self.toast(format!(
            "workspace added: {resolved_name} (also add to `[[workspaces]]` in config.toml to persist)"
        ));
    }

    /// Replace the PRIMARY workspace root with `path`. Used by
    /// [`Self::add_workspace_runtime`] when the user picks a folder
    /// while sitting on the empty-state landing ($HOME-as-workspace);
    /// promoting-to-primary is what the user expects instead of
    /// stacking the new folder as an extra.
    ///
    /// Side effects:
    ///   * `self.workspace` swaps to the new canonical root
    ///   * the primary tree is re-opened on the new root
    ///   * `self.repos` is replaced with `discover_repos(new root)`
    ///   * the empty-state predicate now returns false, so the
    ///     landing widget hides on the next render
    ///
    /// Anything keyed to the old workspace path that wants to
    /// survive ($HOME .mnml/ipc, session.json, git CWD context, etc.)
    /// would need to be re-initialized here. v0.1 takes the simpler
    /// path: we toast the user to relaunch if they care about a
    /// fresh session for the new workspace, and refresh the tree +
    /// repos. The user's mental model is "I just opened the
    /// workspace I wanted" — the rest of the side effects can be
    /// addressed in v0.2 once we see what breaks.
    pub(crate) fn promote_to_primary_workspace(&mut self, root: PathBuf, name: String) {
        // qa-feature 2026-07-01 — SWAP POSITIONS ONLY. The
        // primary + extras share a single stable ordering (each
        // has a `.position`); promoting an extra swaps its
        // `position` with `self.primary_position` and moves the
        // OLD primary into that extra slot, so the visible list
        // never reshuffles. Only the `●` marker moves. See the
        // `preserve original order` design decision — the earlier
        // "swap slots" version reads as weird because the
        // demoted workspace lands in the promoted one's OLD
        // slot instead of staying where it lives in the list.
        let tree = Tree::open(&root);
        let found = crate::git::repos::discover_repos(&root);
        let old_primary_root = std::mem::replace(&mut self.workspace, root.clone());
        let old_primary_name = old_primary_root
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("workspace")
            .to_string();
        let old_primary_position = self.primary_position;
        if let Some(pos) = self.extra_workspaces.iter().position(|w| w.root == root) {
            // Target was an extra. Promote its `.position` to
            // primary_position; replace its slot with the demoted
            // old primary carrying the new primary's OLD
            // position. Net: both positions swap.
            let target_position = self.extra_workspaces[pos].position;
            self.primary_position = target_position;
            self.extra_workspaces[pos] = ExtraWorkspace {
                name: old_primary_name.clone(),
                root: old_primary_root.clone(),
                tree: Tree::open(&old_primary_root),
                expanded: false,
                position: old_primary_position,
            };
        } else if old_primary_root != root {
            // Target came from outside the current extras (e.g. a
            // freshly-picked folder). Give the new primary a
            // fresh slot at the bottom; the OLD primary keeps its
            // original position but now sits in extras.
            let new_primary_position = self.next_free_workspace_position();
            self.primary_position = new_primary_position;
            self.extra_workspaces.push(ExtraWorkspace {
                name: old_primary_name.clone(),
                root: old_primary_root.clone(),
                tree: Tree::open(&old_primary_root),
                expanded: false,
                position: old_primary_position,
            });
        }

        // Rebuild the flat repo list from the NEW primary + all
        // extras in position order so tree-side lookups (green
        // dot, active repo) map to the right rows.
        self.tree = tree;
        self.repos = found;
        let mut extras_by_pos: Vec<&ExtraWorkspace> = self.extra_workspaces.iter().collect();
        extras_by_pos.sort_by_key(|w| w.position);
        let extra_roots: Vec<PathBuf> = extras_by_pos.iter().map(|w| w.root.clone()).collect();
        for extra_root in &extra_roots {
            let mut extra_repos = crate::git::repos::discover_repos(extra_root);
            self.repos.append(&mut extra_repos);
        }
        self.active_repo = 0;
        let new_root = self.active_repo_path().to_path_buf();
        self.git.retarget(&new_root);
        self.git_rail.refresh(&new_root);
        self.git_palette_selected = None;
        self.refresh_rail_pulls();
        for pane in &mut self.panes {
            match pane {
                Pane::GitStatus(g) => g.retarget(&new_root),
                Pane::GitGraph(g) => g.retarget(&new_root),
                _ => {}
            }
        }
        // qa-feature 2026-07-01 — drop any stale "workspace opened:"
        // toasts from the stack so back-to-back promotes don't leave
        // the previous name lingering next to the new one. Without
        // this the user saw two stacked toast boxes after clicking
        // a second `○` while the first was still within its 4s TTL.
        self.toast_stack
            .retain(|e| !e.text.starts_with("workspace opened:"));
        self.toast(format!("workspace opened: {name}"));
    }

    /// qa-feature 2026-07-01 — Remove the currently-primary workspace.
    /// Promotes the first extra (in position order) to primary, then
    /// drops the just-demoted OLD primary from the list. No-op when
    /// there are no extras — the context-menu item is hidden in that
    /// case, but we double-guard here so a stale command / rebind
    /// can't leave the app with nothing loaded.
    pub fn remove_primary_workspace(&mut self) {
        if self.extra_workspaces.is_empty() {
            self.toast("can't remove: no other workspace to fall back on");
            return;
        }
        // Pick the extra with the smallest .position — the visually
        // topmost row after the primary.
        let Some(target_idx) = self
            .extra_workspaces
            .iter()
            .enumerate()
            .min_by_key(|(_, w)| w.position)
            .map(|(i, _)| i)
        else {
            return;
        };
        let target = self.extra_workspaces[target_idx].root.clone();
        let target_name = self.extra_workspaces[target_idx].name.clone();
        // Snapshot the OLD primary's root before promotion swaps them.
        let old_primary_root = self.workspace.clone();
        // Promote — swaps `.position` and moves the OLD primary into the
        // target's slot in `extra_workspaces`.
        self.promote_to_primary_workspace(target, target_name);
        // Drop the demoted OLD primary from the extras.
        self.extra_workspaces.retain(|w| w.root != old_primary_root);
        // Rebuild the flat repo list since we dropped a workspace's repos.
        let mut fresh_repos = crate::git::repos::discover_repos(&self.workspace);
        for extra in &self.extra_workspaces {
            let mut extra_repos = crate::git::repos::discover_repos(&extra.root);
            fresh_repos.append(&mut extra_repos);
        }
        self.repos = fresh_repos;
        self.active_repo = 0;
        let name = old_primary_root
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("workspace")
            .to_string();
        self.toast(format!("workspace removed: {name}"));
    }

    /// Smallest positive integer not already in use by
    /// `primary_position` or any extra's `.position`.
    fn next_free_workspace_position(&self) -> usize {
        let mut used: std::collections::HashSet<usize> =
            self.extra_workspaces.iter().map(|w| w.position).collect();
        used.insert(self.primary_position);
        (0..).find(|p| !used.contains(p)).unwrap_or(0)
    }

    /// Right-click → "Set as workspace" from the tree context menu.
    /// Promotes `path` to the primary workspace regardless of the
    /// current empty-state / has-extras situation. Canonicalises the
    /// path so the resolved root is consistent with everything else
    /// in App that reads `self.workspace`.
    pub fn set_workspace_to(&mut self, path: PathBuf) {
        let root = match path.canonicalize() {
            Ok(p) => p,
            Err(e) => {
                self.toast(format!("can't open workspace: {e}"));
                return;
            }
        };
        if root == self.workspace {
            self.toast("workspace already active");
            return;
        }
        let name = root
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| root.to_string_lossy().into_owned());
        // Reuse `promote_to_primary_workspace` so the side-effects
        // (tree reload, repos rescan, toast) are consistent with the
        // existing workspace-replacement path.
        self.promote_to_primary_workspace(root, name);
    }

    /// Runtime remove: drop the extra workspace at index `idx` (1-based,
    /// matching the workspace-switcher picker convention where 0 is the
    /// primary). Removes its repos from `App.repos`. Primary workspace
    /// can't be removed.
    pub fn remove_workspace_runtime(&mut self, idx: usize) {
        if idx == 0 {
            self.toast("can't remove the primary (launched) workspace");
            return;
        }
        let ws_idx = idx - 1;
        if ws_idx >= self.extra_workspaces.len() {
            return;
        }
        let removed = self.extra_workspaces.remove(ws_idx);
        // Strip repos that lived under this workspace's root.
        let was_active = self
            .repos
            .get(self.active_repo)
            .map(|r| r.path.starts_with(&removed.root))
            .unwrap_or(false);
        self.repos.retain(|r| !r.path.starts_with(&removed.root));
        if was_active {
            self.active_repo = 0;
            if let Some(p) = self.repos.first().map(|r| r.path.clone()) {
                self.git.retarget(&p);
            }
        } else if self.active_repo >= self.repos.len() {
            self.active_repo = self.repos.len().saturating_sub(1);
        }
        self.toast(format!("workspace removed: {}", removed.name));
    }

    /// Picker accept handler for [`PickerKind::Workspaces`]. Expands the
    /// chosen workspace's tree section (collapses other extras so the rail
    /// reads as "this is the one I'm working in"). Primary workspace just
    /// gets focused.
    /// qa-feature 2026-07-02 — notification-only update flow. Fires
    /// one toast per session with a channel-appropriate upgrade
    /// instruction (`cargo install …`, `brew upgrade …`, or a GitHub
    /// URL for .app users). No in-app installer.
    pub(crate) fn maybe_announce_update(&mut self) {
        let Some(uc) = self.update_check.as_ref() else {
            return;
        };
        let Some(latest) = uc.take_pending_announcement() else {
            return;
        };
        let channel = uc.channel;
        self.toast(format!(
            "mnml v{latest} available — {}",
            channel.upgrade_hint(&latest)
        ));
    }

    pub fn switch_workspace(&mut self, idx: usize) {
        // 0 = primary, 1+ = extras (offset by -1 into `extra_workspaces`).
        self.focus_tree();
        self.rail_section = RailSection::Workspace;
        if idx == 0 {
            self.tree_root_expanded = true;
            for w in &mut self.extra_workspaces {
                w.expanded = false;
            }
            return;
        }
        let ws_idx = idx - 1;
        if ws_idx >= self.extra_workspaces.len() {
            return;
        }
        self.tree_root_expanded = false;
        for (i, w) in self.extra_workspaces.iter_mut().enumerate() {
            w.expanded = i == ws_idx;
        }
    }

    pub fn open_workspaces_editor(&mut self) {
        // Close settings first so the new overlay shows on top
        // cleanly.
        self.settings_overlay = None;
        self.workspaces_editor_open = true;
        self.workspaces_editor_selected = 0;
    }

    pub fn close_workspaces_editor(&mut self) {
        self.workspaces_editor_open = false;
    }

    /// Move the workspace at `idx` up by one row (no-op when
    /// already at the top). Persists immediately so reordering
    /// survives a restart.
    pub fn workspaces_editor_move_up(&mut self, idx: usize) {
        if idx == 0 || idx >= self.config.workspaces.len() {
            return;
        }
        self.config.workspaces.swap(idx, idx - 1);
        self.workspaces_editor_selected = idx - 1;
        if let Err(e) = crate::config::persist_workspaces_to_global(&self.config.workspaces) {
            self.toast(format!("save workspaces: {e}"));
        }
    }

    /// Move the workspace at `idx` down by one row (no-op at the
    /// last position). Persists immediately.
    pub fn workspaces_editor_move_down(&mut self, idx: usize) {
        if idx + 1 >= self.config.workspaces.len() {
            return;
        }
        self.config.workspaces.swap(idx, idx + 1);
        self.workspaces_editor_selected = idx + 1;
        if let Err(e) = crate::config::persist_workspaces_to_global(&self.config.workspaces) {
            self.toast(format!("save workspaces: {e}"));
        }
    }

    /// Remove the workspace at `idx`. Persists immediately.
    pub fn workspaces_editor_delete(&mut self, idx: usize) {
        if idx >= self.config.workspaces.len() {
            return;
        }
        let name = self.config.workspaces[idx].name.clone();
        self.config.workspaces.remove(idx);
        if self.workspaces_editor_selected >= self.config.workspaces.len() {
            self.workspaces_editor_selected = self.config.workspaces.len().saturating_sub(1);
        }
        match crate::config::persist_workspaces_to_global(&self.config.workspaces) {
            Ok(_) => self.toast(format!("removed workspace {name}")),
            Err(e) => self.toast(format!("save workspaces: {e}")),
        }
    }

    /// Open the rename prompt for workspace `idx`. Commit handler
    /// (`commit_workspace_rename`) applies + persists.
    pub fn workspaces_editor_open_rename(&mut self, idx: usize) {
        let Some(w) = self.config.workspaces.get(idx) else {
            return;
        };
        let seed = w.name.clone();
        self.workspaces_edit_target_name = Some(idx);
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::WorkspaceRename,
            "Workspace name (empty = revert to basename)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    /// Open the path-edit prompt for workspace `idx`.
    pub fn workspaces_editor_open_path(&mut self, idx: usize) {
        let Some(w) = self.config.workspaces.get(idx) else {
            return;
        };
        let seed = w.path.to_string_lossy().into_owned();
        self.workspaces_edit_target_path = Some(idx);
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::WorkspacePathEdit,
            "Path (tilde-expanded; must exist)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    /// Open the group-edit prompt for workspace `idx`.
    pub fn workspaces_editor_open_group(&mut self, idx: usize) {
        let Some(w) = self.config.workspaces.get(idx) else {
            return;
        };
        let seed = w.group.clone().unwrap_or_default();
        self.workspaces_edit_target_group = Some(idx);
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::WorkspaceGroupEdit,
            "Group (e.g. 'work', 'personal'; empty = ungrouped)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    pub fn commit_workspace_rename(&mut self, typed: &str) {
        let Some(idx) = self.workspaces_edit_target_name.take() else {
            return;
        };
        let Some(w) = self.config.workspaces.get_mut(idx) else {
            return;
        };
        let trimmed = typed.trim();
        w.name = if trimmed.is_empty() {
            w.path
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| w.path.to_string_lossy().into_owned())
        } else {
            trimmed.to_string()
        };
        let _ = crate::config::persist_workspaces_to_global(&self.config.workspaces);
    }

    pub fn commit_workspace_path_edit(&mut self, typed: &str) {
        let Some(idx) = self.workspaces_edit_target_path.take() else {
            return;
        };
        let Some(w) = self.config.workspaces.get_mut(idx) else {
            return;
        };
        let expanded = if let Some(rest) = typed.strip_prefix("~/")
            && let Some(home) = std::env::var_os("HOME")
        {
            std::path::PathBuf::from(home).join(rest)
        } else {
            std::path::PathBuf::from(typed.trim())
        };
        if !expanded.exists() {
            self.toast(format!("path doesn't exist: {}", expanded.display()));
            return;
        }
        w.path = expanded;
        let _ = crate::config::persist_workspaces_to_global(&self.config.workspaces);
    }

    pub fn commit_workspace_group_edit(&mut self, typed: &str) {
        let Some(idx) = self.workspaces_edit_target_group.take() else {
            return;
        };
        let Some(w) = self.config.workspaces.get_mut(idx) else {
            return;
        };
        let trimmed = typed.trim();
        w.group = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        let _ = crate::config::persist_workspaces_to_global(&self.config.workspaces);
    }

    /// Open the kebab menu for a workspace row in the editor.
    pub fn open_workspaces_editor_kebab(&mut self, idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(w) = self.config.workspaces.get(idx) else {
            return;
        };
        let title = Some(w.name.clone());
        let mut items = vec![
            MenuItem::new("Edit name…", MenuAction::WorkspaceEditName(idx)),
            MenuItem::new("Edit path…", MenuAction::WorkspaceEditPath(idx)),
            MenuItem::new("Edit group…", MenuAction::WorkspaceEditGroup(idx)),
        ];
        if idx > 0 {
            items.push(MenuItem::new("Move up", MenuAction::WorkspaceMoveUp(idx)));
        }
        if idx + 1 < self.config.workspaces.len() {
            items.push(MenuItem::new(
                "Move down",
                MenuAction::WorkspaceMoveDown(idx),
            ));
        }
        items.push(MenuItem::new("Delete", MenuAction::WorkspaceDelete(idx)));
        self.context_menu = Some(ContextMenu::new(title, anchor, items));
    }

    /// Open (or focus) the `Pane::HttpHome` dashboard. Called when
    /// the user activates the HTTP activity section so the icon
    /// brings up both the sectioned sidebar AND an all-in-one main
    /// pane. Idempotent — if the pane is already open we just
    /// reveal it.
    pub fn open_http_home(&mut self) {
        use crate::layout::{Layout, SplitDir};
        use crate::pane::Pane;
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::HttpHome(_)))
        {
            self.reveal_pane(id);
            return;
        }
        // Always refresh caches on first-open so the pane isn't blank
        // when the user opens it after a long session.
        self.http_panel_refresh();
        let pane = Pane::HttpHome(crate::http_home::HttpHomePane::new());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = crate::app::Focus::Pane;
    }

    /// HTTP panel `+ New request` action — creates `scratch.http` in
    /// the workspace root (or a numbered variant if it exists) and
    /// opens it in a Request pane. (#10)
    pub fn http_panel_new_request(&mut self) {
        let stub = "### GET request example\nGET https://httpbin.org/get\n";
        let mut path = self.workspace.join("scratch.http");
        let mut i = 1;
        while path.exists() {
            path = self.workspace.join(format!("scratch-{i}.http"));
            i += 1;
        }
        if let Err(e) = std::fs::write(&path, stub) {
            self.toast(format!("http: create failed: {e}"));
            return;
        }
        self.http_panel_refresh();
        self.open_path(&path);
    }

    /// Scan the workspace for TODO markers and repopulate
    /// `todos_hits`. Bounded walk (skips huge files, target,
    /// node_modules, dotdirs) — under a second on typical
    /// workspaces. (#9) On first activation this runs synchronously
    /// (blocks one frame's render) but subsequent \`todos.refresh\`
    /// clicks are cheap enough on typical trees. If it starts to
    /// hurt, extract to a background thread + mpsc.
    pub fn todos_panel_refresh(&mut self) {
        let mut hits = Vec::new();
        walk_for_todos(&self.workspace, 0, &mut hits);
        hits.sort_by(|a, b| a.path.cmp(&b.path).then(a.line.cmp(&b.line)));
        self.todos_hits = hits;
        self.todos_panel_scanned_once = true;
    }

    /// Refresh the HTTP panel caches (files + recent history +
    /// captured log). Called from the panel renderer only when the
    /// cache is empty (first activation) or via `http.refresh`.
    /// Keeps per-frame IO off the render path. (#10)
    ///
    /// Recent + captured are bounded (10 rows each in the sidebar);
    /// the reads are cheap even on large logs because
    /// `history::tail` tail-truncates and `captured::load` parses
    /// linewise — but we still gate on `http_panel_scanned_once` so
    /// they only run on activation, not every frame.
    pub fn http_panel_refresh(&mut self) {
        let mut out = Vec::new();
        walk_for_http(&self.workspace, 0, &mut out);
        out.sort();
        self.http_panel_files_cache = out;
        // Recent — last 10 from `.rqst/history.jsonl`. The tail is
        // reversed at display time so most-recent-first.
        self.http_panel_recent_cache = crate::http::history::tail(&self.workspace, 10);
        // Captured — last 10 from `.rqst/captured/log.jsonl`. `load`
        // returns oldest-first; we cap + reverse at render.
        let cap_path = crate::http::proxy::captured_log_path(&self.workspace);
        self.http_panel_captured_cache = crate::http::captured::load(&cap_path);
        self.http_panel_scanned_once = true;
    }

    /// Refresh the Notes panel file cache. Same lazy pattern as the
    /// HTTP one. (#8)
    pub fn notes_panel_refresh(&mut self) {
        let dir = crate::ui::notes_panel::notes_dir(&self.workspace);
        let mut out: Vec<std::path::PathBuf> = match std::fs::read_dir(&dir) {
            Ok(rd) => rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("md") && p.is_file())
                .collect(),
            Err(_) => Vec::new(),
        };
        // Sort by modified time descending — most-recently-worked-on first.
        out.sort_by_key(|p| {
            std::fs::metadata(p)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| std::cmp::Reverse(d.as_secs()))
                .unwrap_or(std::cmp::Reverse(0))
        });
        self.notes_panel_files_cache = out;
        self.notes_panel_scanned_once = true;
    }

    /// Notes panel `+ New note` action — creates a numbered markdown
    /// file under `<workspace>/.mnml/notes/` and opens it. Directory
    /// is created on demand. (#8)
    pub fn notes_panel_new_note(&mut self) {
        let dir = crate::ui::notes_panel::notes_dir(&self.workspace);
        if let Err(e) = std::fs::create_dir_all(&dir) {
            self.toast(format!("notes: create dir failed: {e}"));
            return;
        }
        let mut i = 1;
        let mut path = dir.join("note-1.md");
        while path.exists() {
            i += 1;
            path = dir.join(format!("note-{i}.md"));
        }
        let stub = format!("# Note {i}\n\n");
        if let Err(e) = std::fs::write(&path, stub) {
            self.toast(format!("notes: create failed: {e}"));
            return;
        }
        self.notes_panel_refresh();
        self.open_path(&path);
    }
}

fn walk_for_http(dir: &std::path::Path, depth: u32, out: &mut Vec<std::path::PathBuf>) {
    if depth > 4 || out.len() > 200 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with('.') || name_str == "target" || name_str == "node_modules" {
            continue;
        }
        if path.is_dir() {
            walk_for_http(&path, depth + 1, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str())
            && (ext == "http" || ext == "curl" || ext == "rest")
        {
            out.push(path);
        }
    }
}

fn walk_for_todos(
    dir: &std::path::Path,
    depth: u32,
    out: &mut Vec<crate::ui::todos_panel::TodoHit>,
) {
    if depth > 6 || out.len() > 1000 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with('.')
            || name_str == "target"
            || name_str == "node_modules"
            || name_str == "dist"
            || name_str == "build"
        {
            continue;
        }
        if path.is_dir() {
            walk_for_todos(&path, depth + 1, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str())
            && matches!(
                ext,
                "rs" | "ts"
                    | "tsx"
                    | "js"
                    | "jsx"
                    | "py"
                    | "go"
                    | "java"
                    | "kt"
                    | "swift"
                    | "cs"
                    | "cpp"
                    | "c"
                    | "h"
                    | "hpp"
                    | "rb"
                    | "sh"
                    | "yml"
                    | "yaml"
                    | "toml"
                    | "md"
            )
        {
            out.extend(crate::ui::todos_panel::scan_file(&path));
        }
    }
}
