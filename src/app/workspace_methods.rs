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
        // api-workflow SEV-2 2026-07-11: `http_env_override` used to
        // survive workspace swaps. A user picking `dev` in workspace
        // A, then jumping to workspace B, silently resolved B's
        // requests against `.mnml/env/dev.env` there — either
        // masking B's real defaults or blowing up on a missing file.
        // Reset per-workspace state that doesn't make sense
        // cross-workspace.
        self.http_env_override = None;
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
    /// #polish 2026-07-06 — right-click "Set as default workspace"
    /// on the workspace-header rail row. Toggles the persisted
    /// `[startup] default_workspace` in `~/.config/mnml/config.toml`:
    /// - if not currently the default → set it
    /// - if currently the default → clear it
    ///
    /// Writes via `crate::config::persist_default_workspace`, updates
    /// the in-memory config, toasts the result.
    pub fn toggle_default_workspace(&mut self) {
        let ws = self.workspace.clone();
        self.toggle_default_workspace_for(&ws);
    }

    /// Same as `toggle_default_workspace` but targeting an
    /// arbitrary path (used by the extra-workspace right-click and
    /// the Manage-workspaces kebab).
    pub fn toggle_default_workspace_for(&mut self, target: &std::path::Path) {
        let current = self
            .config
            .default_workspace
            .clone()
            .and_then(|p| std::fs::canonicalize(&p).ok());
        let target_canon = std::fs::canonicalize(target).ok();
        let already_default = current.is_some() && current == target_canon;
        let new_value = if already_default { None } else { Some(target) };
        match crate::config::persist_default_workspace(new_value) {
            Ok(_) => {
                self.config.default_workspace = new_value.map(|p| p.to_path_buf());
                let ws_label = target
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("workspace");
                if already_default {
                    self.toast("default workspace cleared");
                } else {
                    self.toast(format!("default workspace: {ws_label}"));
                }
            }
            Err(e) => self.toast(format!("default workspace: {e}")),
        }
    }

    /// Workspaces-editor kebab → "Set as default" / "Unset as
    /// default". Persists to `~/.config/mnml/config.toml` and
    /// updates the in-memory config.
    pub fn workspaces_editor_toggle_default(&mut self, idx: usize) {
        let Some(entry) = self.config.workspaces.get(idx).cloned() else {
            return;
        };
        self.toggle_default_workspace_for(&entry.path);
    }

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
    pub(crate) fn next_free_workspace_position(&self) -> usize {
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
        // Persist the removal to `[[workspaces]]` in the global
        // config — WITHOUT this the entry sticks around and the
        // startup path re-adds it on the next launch, which reads
        // as a bug ("I removed it, why is it back?"). Match by
        // canonical path so name-only edits still resolve. Silent
        // no-op when the entry isn't in the config (a workspace
        // added via `:view.add_workspace` and never persisted).
        let removed_root = removed.root.clone();
        let cfg_position = self.config.workspaces.iter().position(|w| {
            std::fs::canonicalize(&w.path)
                .map(|p| p == removed_root)
                .unwrap_or(false)
        });
        let restored_config = cfg_position.map(|i| self.config.workspaces.remove(i));
        if restored_config.is_some()
            && let Err(e) = crate::config::persist_workspaces_to_global(&self.config.workspaces)
        {
            self.toast(format!("save workspaces: {e}"));
        }
        // #20 — offer undo for the removal. Captures both the
        // config entry and its index so the restore path can put
        // it back exactly where the user had it.
        let name = removed.name.clone();
        if let (Some(cfg), Some(pos)) = (restored_config, cfg_position) {
            self.set_pending_undo(
                format!("removed workspace {name}"),
                crate::app::UndoAction::RestoreWorkspace {
                    config: cfg,
                    position: pos,
                },
            );
        }
        self.toast(format!("workspace removed: {name}"));
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

    /// #polish 2026-07-06 — reorder an extra workspace up (or down)
    /// by swapping its `.position` with the adjacent extra. Persists
    /// the swap to `[[workspaces]]` in the global config so the
    /// ordering survives a relaunch. `direction = -1` means "up",
    /// `+1` means "down". No-op when the target is the primary or
    /// there's nothing to swap with.
    pub fn move_extra_workspace(&mut self, ws_idx: usize, direction: i32) {
        if ws_idx >= self.extra_workspaces.len() {
            return;
        }
        let src_pos = self.extra_workspaces[ws_idx].position;
        // Find the extra with the "adjacent" position — nearest
        // position value in the requested direction that isn't the
        // primary's slot. Skips the primary so extras only swap
        // with extras.
        let mut best: Option<usize> = None;
        let mut best_pos: usize = 0;
        for (i, w) in self.extra_workspaces.iter().enumerate() {
            if i == ws_idx {
                continue;
            }
            let adjacent = if direction < 0 {
                w.position < src_pos && best.map(|_| w.position > best_pos).unwrap_or(true)
            } else {
                w.position > src_pos && best.map(|_| w.position < best_pos).unwrap_or(true)
            };
            if adjacent {
                best = Some(i);
                best_pos = w.position;
            }
        }
        let Some(other_idx) = best else {
            self.toast(if direction < 0 {
                "already at the top"
            } else {
                "already at the bottom"
            });
            return;
        };
        // Swap positions in the runtime rail.
        let a = self.extra_workspaces[ws_idx].position;
        let b = self.extra_workspaces[other_idx].position;
        self.extra_workspaces[ws_idx].position = b;
        self.extra_workspaces[other_idx].position = a;
        // Also swap the corresponding config entries so a relaunch
        // uses the same order. Match by canonical path.
        let (src_root, dst_root) = (
            self.extra_workspaces[ws_idx].root.clone(),
            self.extra_workspaces[other_idx].root.clone(),
        );
        let src_cfg = self.config.workspaces.iter().position(|w| {
            std::fs::canonicalize(&w.path)
                .map(|p| p == src_root)
                .unwrap_or(false)
        });
        let dst_cfg = self.config.workspaces.iter().position(|w| {
            std::fs::canonicalize(&w.path)
                .map(|p| p == dst_root)
                .unwrap_or(false)
        });
        if let (Some(s), Some(d)) = (src_cfg, dst_cfg) {
            self.config.workspaces.swap(s, d);
            if let Err(e) = crate::config::persist_workspaces_to_global(&self.config.workspaces) {
                self.toast(format!("save workspaces: {e}"));
                return;
            }
        }
        let name = self.extra_workspaces[ws_idx].name.clone();
        self.toast(format!(
            "moved {name} {}",
            if direction < 0 { "up" } else { "down" }
        ));
    }

    /// Remove the workspace at `idx`. Persists immediately.
    /// Offers undo via `pending_undo` (#20).
    pub fn workspaces_editor_delete(&mut self, idx: usize) {
        if idx >= self.config.workspaces.len() {
            return;
        }
        let removed = self.config.workspaces.remove(idx);
        let name = removed.name.clone();
        if self.workspaces_editor_selected >= self.config.workspaces.len() {
            self.workspaces_editor_selected = self.config.workspaces.len().saturating_sub(1);
        }
        match crate::config::persist_workspaces_to_global(&self.config.workspaces) {
            Ok(_) => {
                self.set_pending_undo(
                    format!("removed workspace {name}"),
                    crate::app::UndoAction::RestoreWorkspace {
                        config: removed,
                        position: idx,
                    },
                );
                self.toast(format!("removed workspace {name}"));
            }
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
        // #polish 2026-07-06 — "Set / Unset default" label matches
        // whether THIS entry's path is the persisted default.
        let entry_canon = std::fs::canonicalize(&w.path).ok();
        let default_canon = self
            .config
            .default_workspace
            .as_deref()
            .and_then(|p| std::fs::canonicalize(p).ok());
        let is_default = entry_canon.is_some() && entry_canon == default_canon;
        let set_default_label = if is_default {
            "Unset as default"
        } else {
            "Set as default"
        };
        let mut items = vec![
            MenuItem::new(set_default_label, MenuAction::WorkspaceSetDefault(idx)),
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

    /// HTTP panel `+ New request` action — spawns a blank
    /// form-style Request pane (Edit view, no source file). The
    /// pane exists only in memory until the user hits Save-As;
    /// nothing lands on disk on click. This replaces the earlier
    /// "write scratch-N.http + open editor + fire send + close
    /// editor" dance, which was littering the workspace with
    /// scratch-1.http … scratch-N.http files as the user
    /// explored.
    ///
    /// If a Request pane is already active we don't spawn a new
    /// one — matches the "reuse the current request pane"
    /// semantics of `open_curl_scratch` + `paste_curl`. The
    /// active pane just gets its fields cleared back to defaults.
    pub fn http_panel_new_request(&mut self) {
        use crate::pane::Pane;
        use crate::request_pane::{EditField, EditTab, RunState, ViewMode};
        let has_request = matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(_))
        );
        if !has_request {
            self.open_new_request_pane();
            return;
        }
        // 2026-08-23 (mouse-r16 SEV-2) — don't silently wipe an
        // active Request pane that has real content in it. If the
        // URL, body, or headers are non-empty, spawn a NEW request
        // pane instead of clobbering the current one. The old
        // reset-in-place path was reachable by clicking `+ New
        // request` while typing a URL, with no confirm.
        let Some(cur) = self.active else { return };
        let has_content = matches!(
            self.panes.get(cur),
            Some(Pane::Request(rp))
                if !rp.request.url.is_empty()
                    || !rp.headers_buffer.is_empty()
                    || rp.request.body.as_deref().is_some_and(|b| !b.is_empty())
        );
        if has_content {
            self.open_new_request_pane();
            return;
        }
        // Blank pane in place — safe to reset (nothing to lose).
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.request = crate::http::Request {
                method: "GET".to_string(),
                url: String::new(),
                headers: Vec::new(),
                body: None,
                insecure: false,
            };
            rp.headers_buffer = String::new();
            rp.headers_cursor = 0;
            rp.url_cursor = 0;
            rp.body_cursor = 0;
            rp.source_path = None;
            rp.source_block_name = None;
            rp.view = ViewMode::Edit;
            rp.focus = EditField::Url;
            rp.edit_tab = EditTab::Body;
            rp.state = RunState::Failed("not sent yet · press `r` to fire".to_string());
        }
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
        self.todos_panel_cursor = 0;
    }

    // vscode-user-keyboard SEV-2 fix 2026-07-09 — j/k / arrow
    // nav on the three activity panels. Cursor is an index into
    // the currently-visible filtered list; each `_cursor_down`
    // clamps to the list length so filtering doesn't leave the
    // cursor pointing past the end.
    fn todos_filtered_len(&self) -> usize {
        let f = self.todos_panel_filter.to_ascii_lowercase();
        if f.is_empty() {
            return self.todos_hits.len();
        }
        self.todos_hits
            .iter()
            .filter(|h| {
                h.tag.to_ascii_lowercase().contains(&f)
                    || h.path.to_string_lossy().to_ascii_lowercase().contains(&f)
                    || h.title.to_ascii_lowercase().contains(&f)
            })
            .count()
    }

    pub fn todos_panel_cursor_down(&mut self) {
        let n = self.todos_filtered_len();
        if n == 0 {
            self.todos_panel_cursor = 0;
            return;
        }
        self.todos_panel_cursor = (self.todos_panel_cursor + 1).min(n - 1);
        self.todos_panel_preview();
    }

    pub fn todos_panel_cursor_up(&mut self) {
        self.todos_panel_cursor = self.todos_panel_cursor.saturating_sub(1);
        self.todos_panel_preview();
    }

    /// The TODO hits currently listed, in display order.
    ///
    /// One definition of "what the filter shows". The predicate lived in
    /// three places — the renderer, `todos_panel_activate`, and the click
    /// handler — and `todos_panel_cursor` indexes into THIS list, not
    /// into `todos_hits`, so any drift between them moves the selection
    /// to a different TODO than the highlighted one.
    pub fn todos_filtered(&self) -> Vec<&crate::ui::todos_panel::TodoHit> {
        let f = self.todos_panel_filter.to_ascii_lowercase();
        self.todos_hits
            .iter()
            .filter(|h| {
                f.is_empty()
                    || h.tag.to_ascii_lowercase().contains(&f)
                    || h.path.to_string_lossy().to_ascii_lowercase().contains(&f)
                    || h.title.to_ascii_lowercase().contains(&f)
            })
            .collect()
    }

    /// Show the highlighted TODO without leaving the panel.
    ///
    /// Opens as a PREVIEW tab, so arrowing through twenty entries reuses
    /// one tab instead of opening twenty, and restores panel focus after
    /// — `open_path` sets `Focus::Pane`, which is what stopped the arrows
    /// working after a click (user report: "i cant click and arrow from
    /// there").
    pub fn todos_panel_preview(&mut self) {
        let picked = self
            .todos_filtered()
            .get(self.todos_panel_cursor)
            .map(|h| (h.path.clone(), h.line.to_string()));
        let Some((path, line)) = picked else {
            return;
        };
        let before = self.focus;
        self.open_path_preview(&path);
        self.goto_line_str(&line);
        self.focus = before;
    }

    /// Open the highlighted TODO and move INTO it — the Enter gesture,
    /// as opposed to arrowing, which previews and stays put.
    pub fn todos_panel_activate(&mut self) {
        let picked = self
            .todos_filtered()
            .get(self.todos_panel_cursor)
            .map(|h| (h.path.clone(), h.line.to_string()));
        if let Some((path, line)) = picked {
            self.open_path(&path);
            self.goto_line_str(&line);
        }
    }

    pub fn notes_panel_cursor_down(&mut self) {
        let n = self.notes_filtered().len();
        if n == 0 {
            self.notes_panel_cursor = 0;
            return;
        }
        self.notes_panel_cursor = (self.notes_panel_cursor + 1).min(n - 1);
    }

    pub fn notes_panel_cursor_up(&mut self) {
        self.notes_panel_cursor = self.notes_panel_cursor.saturating_sub(1);
    }

    pub fn notes_panel_activate(&mut self) {
        if let Some(path) = self
            .notes_filtered()
            .into_iter()
            .nth(self.notes_panel_cursor)
        {
            self.open_path(&path);
        }
    }

    fn notes_filtered(&self) -> Vec<std::path::PathBuf> {
        let f = self.notes_panel_filter.to_ascii_lowercase();
        if f.is_empty() {
            return self.notes_panel_files_cache.clone();
        }
        self.notes_panel_files_cache
            .iter()
            .filter(|p| {
                p.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase()
                    .contains(&f)
            })
            .cloned()
            .collect()
    }

    /// Cursor slot 0 = the "+ New session" chip (visually FIRST as of
    /// #1188). Slots 1..=n = the n AI session rows below it. Was:
    /// slots 0..n-1 = sessions, n = chip; but #1188 moved the chip to
    /// the top of the panel and left the cursor slot at the bottom,
    /// so `↓↓↓↓` walked off the last row and the highlight jumped
    /// visually UP to the chip (R15 vscode-keyboard K-03).
    pub fn sessions_panel_cursor_down(&mut self) {
        let n = self.sessions_filtered_ids().len();
        let max = n; // valid range: 0..=n, chip at 0
        self.sessions_panel_cursor = (self.sessions_panel_cursor + 1).min(max);
    }

    pub fn sessions_panel_cursor_up(&mut self) {
        self.sessions_panel_cursor = self.sessions_panel_cursor.saturating_sub(1);
    }

    pub fn sessions_panel_activate(&mut self) {
        // Cursor 0 = chip → spawn a new Claude. Slots 1..=n =
        // sessions → focus session[i-1]. Empty state (n=0) → chip is
        // the only slot, so Enter always spawns.
        if self.sessions_panel_cursor == 0 {
            crate::command::run("ai.claude_code_new", self);
            return;
        }
        let ids = self.sessions_filtered_ids();
        let idx = self.sessions_panel_cursor.saturating_sub(1);
        if let Some(pid) = ids.into_iter().nth(idx) {
            self.reveal_pane(pid);
        }
    }

    fn sessions_filtered_ids(&self) -> Vec<usize> {
        let f = self.sessions_panel_filter.to_ascii_lowercase();
        // R15 nvchad-user SEV-2 (2026-08-23) — was
        // `matches!(p, Pane::Pty(_))`, which counted every Pty
        // including shells and integration tools. The panel view
        // filters to `is_ai_session_pane` (Claude Code / Codex only),
        // so `j`/`k` and `Enter` walked through invisible slots and
        // Enter on the highlighted "+ New session" chip focused an
        // unrelated shell instead of spawning a new Claude. Share
        // the render-side predicate here so keyboard and mouse agree.
        self.panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| crate::ui::sessions_panel::is_ai_session_pane(p).then_some(i))
            .filter(|pid| {
                if f.is_empty() {
                    return true;
                }
                let Some(crate::pane::Pane::Pty(s)) = self.panes.get(*pid) else {
                    return false;
                };
                let cwd = s.profile.cwd.as_ref();
                let cwd_basename = cwd
                    .and_then(|p| p.file_name().and_then(|n| n.to_str()))
                    .unwrap_or_default();
                [
                    s.display_name.as_deref().unwrap_or_default(),
                    s.profile.label.as_str(),
                    cwd_basename,
                ]
                .iter()
                .any(|c| !c.is_empty() && c.to_ascii_lowercase().contains(&f))
            })
            .collect()
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
        // Walk the workspace tree for `.http` / `.curl` / `.rest` files.
        let mut all_workspace_files = Vec::new();
        walk_for_http(&self.workspace, 0, &mut all_workspace_files);
        all_workspace_files.sort();
        // Recent + Captured share a ceiling of 20 rows — the sidebar
        // clips to 10 at display time, the home pane shows all 20.
        // Both loaders cap at load time so a multi-GB capture / a
        // never-rotated history.jsonl don't blow through allocator.
        self.http_panel_recent_cache = crate::http::history::tail(&self.workspace, 20);
        let cap_path = crate::http::proxy::captured_log_path(&self.workspace);
        self.http_panel_captured_cache = crate::http::captured::load_tail(&cap_path, 20);
        // Env cache — walks both `.mnml/env/` and `.rqst/env/`,
        // dedupes by basename, sorted alphabetically. Same shape
        // as `open_http_env_picker`.
        let mut envs = std::collections::BTreeSet::new();
        for sub in [".mnml", ".rqst"] {
            let dir = self.workspace.join(sub).join("env");
            if let Ok(rd) = std::fs::read_dir(&dir) {
                for entry in rd.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) == Some("env")
                        && let Some(stem) = path.file_stem().and_then(|s| s.to_str())
                    {
                        envs.insert(stem.to_string());
                    }
                }
            }
        }
        self.http_panel_envs_cache = envs.into_iter().collect();
        // Chains — flat scan of `.mnml/chains/*.chain.json`. Small
        // dir; cheap.
        let chains_dir = self.workspace.join(".mnml").join("chains");
        let mut chains: Vec<std::path::PathBuf> = std::fs::read_dir(&chains_dir)
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name()
                            .and_then(|s| s.to_str())
                            .is_some_and(|n| n.ends_with(".chain.json"))
                    })
                    .collect()
            })
            .unwrap_or_default();
        chains.sort();
        self.http_panel_chains_cache = chains;
        // Mocks — collect all `*.mock.json` picked up by the http
        // file walk. R7 api-workflow SEV-2 2026-08-09: was reading
        // `self.http_panel_files_cache` — which is only assigned at
        // line 1242 below — so the first refresh always saw the
        // PRIOR call's cache. Now reads from `all_workspace_files`
        // (fresh, sorted at line 1007). Mocks live as siblings of
        // the source files they mock, so the walk covers them.
        let mut mocks: Vec<std::path::PathBuf> = all_workspace_files
            .iter()
            .filter(|p| {
                p.file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(|n| n.ends_with(".mock.json"))
            })
            .cloned()
            .collect();
        // As of R6 api-workflow SEV-2 (2026-08-09) `walk_for_http`
        // ALSO collects `*.mock.json` sidecars, which is where
        // `sibling_path_for_block` actually writes them. This
        // `.rqst/mocks` / `.mnml/mocks` shallow-walk stays as a
        // fallback for mocks manually placed into those legacy dirs.
        for sub in [".rqst", ".mnml"] {
            let dir = self.workspace.join(sub).join("mocks");
            if let Ok(rd) = std::fs::read_dir(&dir) {
                for entry in rd.flatten() {
                    let p = entry.path();
                    if p.file_name()
                        .and_then(|s| s.to_str())
                        .is_some_and(|n| n.ends_with(".mock.json"))
                    {
                        mocks.push(p);
                    }
                }
            }
        }
        mocks.sort();
        mocks.dedup();
        self.http_panel_mocks_cache = mocks;
        // #polish 2026-07-06 — universal collection discovery. A
        // "collection" is either:
        //   (a) a subdir of `.mnml/collections/*` (Hidden — per-user)
        //   (b) any workspace folder with ≥2 request files (InTree
        //       — Bruno-flavor, git-tracked)
        // Files not inside any collection root land in the FILES
        // section as stragglers.
        use crate::app::HttpCollectionKind;
        let mut roots: Vec<(std::path::PathBuf, HttpCollectionKind)> = Vec::new();

        // (a) Hidden collections — each direct subdir of
        // `.mnml/collections/`. Empty subdirs still count as a
        // collection (user just created it, no requests yet).
        let hidden_root = self.workspace.join(".mnml").join("collections");
        if let Ok(rd) = std::fs::read_dir(&hidden_root) {
            for entry in rd.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    roots.push((p, HttpCollectionKind::Hidden));
                }
            }
        }

        // #polish 2026-07-06 — `.rqst/` support (legacy .rqst-style
        // request stores). Classic layout:
        //   .rqst/requests/<name>/*.curl — each <name> is a collection
        //   .rqst/snippets/*.curl        — snippets is a collection
        //   .rqst/lookups/*.curl         — lookups is a collection
        // Skip the structural dirs (env / mocks / captured / ipc /
        // config) that mnml handles separately.
        let rqst_root = self.workspace.join(".rqst");
        if rqst_root.exists() {
            let has_request_file = |dir: &std::path::Path| -> bool {
                std::fs::read_dir(dir)
                    .map(|rd| {
                        rd.flatten().any(|e| {
                            let p = e.path();
                            p.is_file()
                                && matches!(
                                    p.extension().and_then(|s| s.to_str()),
                                    Some("http") | Some("curl") | Some("rest")
                                )
                        })
                    })
                    .unwrap_or(false)
            };
            // Same predicate as `has_request_file` but recurses so a
            // dir that contains request files ONLY in deeper subfolders
            // still qualifies as a collection root. Bug 2026-07-08 —
            // integrations-api/Admin/*.curl was invisible in the HTTP
            // panel because integrations-api/ had no direct files and
            // the old scanner only looked one level down.
            fn has_request_file_recursive(dir: &std::path::Path, depth: u32) -> bool {
                if depth > 6 {
                    return false;
                }
                let Ok(rd) = std::fs::read_dir(dir) else {
                    return false;
                };
                for entry in rd.flatten() {
                    let p = entry.path();
                    if p.is_file() {
                        if matches!(
                            p.extension().and_then(|s| s.to_str()),
                            Some("http") | Some("curl") | Some("rest")
                        ) {
                            return true;
                        }
                    } else if p.is_dir() && has_request_file_recursive(&p, depth + 1) {
                        return true;
                    }
                }
                false
            }
            let skip = ["env", "mocks", "captured", "ipc", "config"];
            if let Ok(rd) = std::fs::read_dir(&rqst_root) {
                for entry in rd.flatten() {
                    let p = entry.path();
                    if !p.is_dir() {
                        continue;
                    }
                    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                    if skip.iter().any(|s| s == &name) {
                        continue;
                    }
                    // Two shapes: either the dir itself has direct
                    // request files (snippets, lookups), or its
                    // children do (requests/<sub>/). Sub-level is
                    // checked recursively so a `requests/<api>/` whose
                    // .curl files live in `requests/<api>/<endpoint>/`
                    // still surfaces as its own collection.
                    if has_request_file(&p) {
                        roots.push((p, HttpCollectionKind::Hidden));
                    } else if let Ok(sub_rd) = std::fs::read_dir(&p) {
                        for sub in sub_rd.flatten() {
                            let sp = sub.path();
                            if sp.is_dir() && has_request_file_recursive(&sp, 0) {
                                roots.push((sp, HttpCollectionKind::Hidden));
                            }
                        }
                    }
                }
            }
        }

        // (b) In-tree collections — group workspace files by parent
        // dir; parents with ≥2 request files become collection roots.
        // Skip the workspace root itself (that would eat every loose
        // .http; the "workspace as one big collection" case isn't
        // what the user wants). R7 api-workflow SEV-3 2026-08-09:
        // `.mock.json` sidecars are NOT request files and shouldn't
        // count toward the ≥2 threshold — a folder with 1 `.curl` +
        // 1 `foo.curl.mock.json` isn't a collection.
        let is_mock_sidecar = |p: &std::path::Path| -> bool {
            p.file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|n| n.ends_with(".mock.json"))
        };
        let mut by_parent: std::collections::HashMap<std::path::PathBuf, usize> =
            std::collections::HashMap::new();
        for f in &all_workspace_files {
            if is_mock_sidecar(f) {
                continue;
            }
            if let Some(parent) = f.parent()
                && parent != self.workspace
            {
                *by_parent.entry(parent.to_path_buf()).or_insert(0) += 1;
            }
        }
        for (parent, n) in by_parent {
            if n >= 2 {
                roots.push((parent, HttpCollectionKind::InTree));
            }
        }
        roots.sort_by(|a, b| a.0.cmp(&b.0));
        self.http_panel_collection_roots = roots;

        // Partition all files into (in a collection) vs (straggler).
        // A file belongs to a collection iff any collection root is
        // its ancestor.
        let is_in_collection = |p: &std::path::Path| -> bool {
            self.http_panel_collection_roots
                .iter()
                .any(|(root, _)| p.starts_with(root))
        };
        let mut in_collection: Vec<std::path::PathBuf> = Vec::new();
        let mut stragglers: Vec<std::path::PathBuf> = Vec::new();
        for f in all_workspace_files {
            // R7 api-workflow SEV-3 2026-08-09: exclude .mock.json
            // sidecars from both FILES and COLLECTIONS — they live
            // in the MOCKS section only. `all_workspace_files`
            // includes them (needed for the mocks-collect above)
            // but they shouldn't render as clickable request files.
            if is_mock_sidecar(&f) {
                continue;
            }
            if is_in_collection(&f) {
                in_collection.push(f);
            } else {
                stragglers.push(f);
            }
        }
        // Also pull hidden-collection files (they weren't in the
        // workspace walk — walk_for_http skips hidden dirs). Two
        // sources now: .mnml/collections/*/ and .rqst/**/.
        for (root, kind) in &self.http_panel_collection_roots {
            if *kind == HttpCollectionKind::Hidden {
                let mut hidden_files = Vec::new();
                walk_collections(root, &mut hidden_files);
                in_collection.extend(hidden_files);
            }
        }
        in_collection.sort();
        in_collection.dedup();
        self.http_panel_files_cache = stragglers;
        self.http_panel_collections_cache = in_collection;
        self.http_panel_scanned_once = true;
    }

    /// Truncate the captured-traffic log for this workspace. Fires
    /// from the CAPTURED section header's `✕` chip. Silent no-op
    /// when the file doesn't exist (nothing to clear).
    /// Snapshots the file into `pending_undo` so the user can bring
    /// the traffic back (#20).
    pub fn http_panel_clear_captured(&mut self) {
        let cap_path = crate::http::proxy::captured_log_path(&self.workspace);
        if cap_path.exists() {
            let snapshot = std::fs::read(&cap_path).unwrap_or_default();
            match std::fs::write(&cap_path, "") {
                Ok(_) => {
                    if !snapshot.is_empty() {
                        self.set_pending_undo(
                            "cleared captured traffic".to_string(),
                            crate::app::UndoAction::RestoreCapturedFile { bytes: snapshot },
                        );
                    }
                    self.toast("captured traffic cleared");
                }
                Err(e) => self.toast(format!("clear captured: {e}")),
            }
        }
        self.http_panel_captured_cache.clear();
    }

    /// Truncate the workspace-local request history (`.rqst/history.jsonl`).
    /// Fires from the RECENT section header's `✕` chip. Silent no-op
    /// when the file doesn't exist. Does NOT touch the global mirror
    /// (`~/.local/state/mnml/history.jsonl`) — that's cross-workspace
    /// and clearing it would surprise other workspaces sharing the
    /// mirror. To wipe the global one too, add a modifier + prompt.
    /// Snapshots the file into `pending_undo` (#20).
    pub fn http_panel_clear_recent(&mut self) {
        let hist_path = self.workspace.join(".rqst").join("history.jsonl");
        if hist_path.exists() {
            let snapshot = std::fs::read(&hist_path).unwrap_or_default();
            match std::fs::write(&hist_path, "") {
                Ok(_) => {
                    if !snapshot.is_empty() {
                        self.set_pending_undo(
                            "cleared request history".to_string(),
                            crate::app::UndoAction::RestoreHistoryFile { bytes: snapshot },
                        );
                    }
                    self.toast("request history cleared");
                }
                Err(e) => self.toast(format!("clear recent: {e}")),
            }
        }
        self.http_panel_recent_cache.clear();
    }

    /// Refresh the Findings panel file cache. Walks
    /// `.mnml/findings/` recursively (depth cap 4) picking up every
    /// `*.md` — tester agents commonly nest reports under
    /// per-round subdirectories (`2026-07-21-16-09-design-round-1/*.md`),
    /// so a flat scan misses everything but the top-level `README.md`.
    /// Sorted by mtime desc so the freshest finding is first. Task #908.
    pub fn findings_panel_refresh(&mut self) {
        let dir = crate::ui::findings_panel::findings_dir(&self.workspace);
        let mut out: Vec<std::path::PathBuf> = Vec::new();
        walk_findings(&dir, 0, &mut out);
        out.sort_by_key(|p| {
            std::fs::metadata(p)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| std::cmp::Reverse(d.as_secs()))
                .unwrap_or(std::cmp::Reverse(0))
        });
        self.findings_panel_files_cache = out;
        self.findings_panel_scanned_once = true;
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

    /// SESSIONS panel refresh (#1221). Sessions aren't fetched from
    /// anywhere — the list is derived from the live Pty panes — so
    /// this drops the render-side caches that would otherwise hold a
    /// card stale for up to their TTL, plus the 30 s port cache. The
    /// next frame re-reads every transcript and re-scans ports.
    pub fn sessions_panel_refresh(&mut self) {
        crate::ui::sessions_panel::invalidate_render_caches();
        self.session_port_cache.clear();
    }

    /// Notes panel `+ New note` action — opens the "New file"
    /// prompt seeded with the next auto-numbered default
    /// (`note-N.md`) so the user can accept it with Enter (fast
    /// path, common case) or type over it with a real name
    /// (mouse-r16 SEV-3 — the click used to silently create
    /// `note-1.md` with no chance to name it). The prompt already
    /// routes accept → `create_new_file` which writes the file
    /// and opens it in an editor pane.
    pub fn notes_panel_new_note(&mut self) {
        let dir = crate::ui::notes_panel::notes_dir(&self.workspace);
        if let Err(e) = std::fs::create_dir_all(&dir) {
            self.toast(format!("notes: create dir failed: {e}"));
            return;
        }
        let mut i = 1;
        let mut candidate = dir.join("note-1.md");
        while candidate.exists() {
            i += 1;
            candidate = dir.join(format!("note-{i}.md"));
        }
        let seed = format!("note-{i}.md");
        self.pending_fs_action = Some(FsAction::NewFile {
            parent: dir.clone(),
        });
        let title = format!(
            "New note in {}/",
            crate::app::util::rel_path(&self.workspace, &dir)
        );
        self.prompt = Some(crate::prompt::Prompt::seeded_select_all(
            crate::prompt::PromptKind::NewFile,
            title,
            seed,
        ));
    }
}

/// Task #908 — recursive `.md` collector for the Findings panel.
/// Depth-limited (max 4) as an upper bound on nesting; symlinks are
/// safe by construction — `DirEntry::file_type` is lstat-based, so
/// symlinks report `is_symlink()`, not `is_dir()`, and the recursion
/// branch never follows them (cycles unreachable, not just
/// depth-bounded). Also caps output at 500 rows — a runaway workspace
/// with thousands of findings shouldn't produce a Vec that dwarfs the
/// panel viewport. Skips any `README.md` at the root so the shipped
/// index file doesn't clutter the row list. Matches the size-cap
/// idiom in the integration `walk_for_http` / `walk_for_todos` walkers.
fn walk_findings(dir: &std::path::Path, depth: usize, out: &mut Vec<std::path::PathBuf>) {
    if depth > 4 || out.len() > 500 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if out.len() > 500 {
            return;
        }
        let path = entry.path();
        let Ok(ft) = entry.file_type() else { continue };
        if ft.is_dir() {
            walk_findings(&path, depth + 1, out);
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        // Skip README.md at the root — it's the shipped index/help
        // page, not a finding. Nested READMEs (a per-round index)
        // still surface because their parent dir names them
        // meaningfully.
        if depth == 0
            && path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.eq_ignore_ascii_case("README.md"))
        {
            continue;
        }
        out.push(path);
    }
}

/// #22 — walker for `.mnml/collections/`. Recurses through
/// subdirs (a collection is a folder) and collects `.http` /
/// `.curl` / `.rest` request files. Unlike `walk_for_http`,
/// this one doesn't skip hidden dirs — the whole tree lives
/// under `.mnml/`, so hidden-dot filtering would trip on the
/// parent path itself.
fn walk_collections(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_collections(&path, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str())
            && (ext == "http" || ext == "curl" || ext == "rest")
        {
            out.push(path);
        }
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
        } else if name_str.ends_with(".mock.json") {
            // R6 api-workflow SEV-2 2026-08-09 — sidecar mocks live
            // next to their source (e.g. `get.curl.mock.json` in the
            // workspace root, not under `.rqst/mocks/`). Without this
            // branch, `App::http_panel_refresh` filters an already-
            // empty `http_panel_files_cache` for `.mock.json` and
            // always renders MOCKS `(0)` — the actual save path
            // (`sibling_path_for_block`) and the panel's discovery
            // never intersect. `path.extension()` on `foo.curl.mock.json`
            // returns `"json"`, not `"mock.json"`, so match on the
            // full-name suffix instead.
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

#[cfg(test)]
mod notes_new_note_tests {
    #[test]
    fn new_note_opens_prompt_seeded_with_next_auto_number() {
        // 2026-08-23 (mouse-r16 SEV-3) — was direct-create; now
        // opens a NewFile prompt seeded with the next auto-numbered
        // default so the user can accept it (fast) or type over it
        // (deliberate name).
        let d = tempfile::tempdir().unwrap();
        let cfg = crate::config::Config::default();
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        app.notes_panel_new_note();
        let p = app.prompt.as_ref().expect("new_note should open a prompt");
        assert!(matches!(p.kind, crate::prompt::PromptKind::NewFile));
        assert_eq!(
            p.input, "note-1.md",
            "seed should be the next auto-numbered default"
        );
    }

    #[test]
    fn new_note_seeds_next_number_when_prior_notes_exist() {
        // Pre-seed the dir with note-1.md and note-2.md so
        // notes_panel_new_note lands on note-3.md as the default.
        let d = tempfile::tempdir().unwrap();
        let cfg = crate::config::Config::default();
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        let dir = d.path().join(".mnml").join("notes");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("note-1.md"), "").unwrap();
        std::fs::write(dir.join("note-2.md"), "").unwrap();
        app.notes_panel_new_note();
        let p = app.prompt.as_ref().expect("prompt should open");
        assert_eq!(p.input, "note-3.md");
    }
}

#[cfg(test)]
mod findings_walk_tests {
    use super::walk_findings;
    use std::fs;

    #[test]
    fn walks_nested_subdirs_and_skips_root_readme() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path();
        fs::write(root.join("README.md"), "# index").unwrap();
        fs::write(root.join("top.md"), "# top").unwrap();
        let round = root.join("2026-08-14-round-1");
        fs::create_dir(&round).unwrap();
        fs::write(round.join("finding-a.md"), "a").unwrap();
        fs::write(round.join("finding-b.md"), "b").unwrap();
        // Non-md siblings are ignored.
        fs::write(round.join("notes.txt"), "x").unwrap();
        let mut out = Vec::new();
        walk_findings(root, 0, &mut out);
        // 3 md files: top.md + 2 in round. README.md skipped.
        assert_eq!(out.len(), 3, "walked: {out:?}");
        assert!(out.iter().any(|p| p.ends_with("top.md")));
        assert!(out.iter().any(|p| p.ends_with("finding-a.md")));
        assert!(out.iter().any(|p| p.ends_with("finding-b.md")));
        assert!(!out.iter().any(|p| p.ends_with("README.md")));
    }

    #[test]
    fn depth_cap_prevents_runaway_walk() {
        let d = tempfile::tempdir().unwrap();
        let mut path = d.path().to_path_buf();
        // Create 7 nested dirs, each with a .md file. Depth cap is 4,
        // so files past depth 4 shouldn't show up.
        for i in 0..7 {
            path.push(format!("d{i}"));
            fs::create_dir(&path).unwrap();
            fs::write(path.join("f.md"), "x").unwrap();
        }
        let mut out = Vec::new();
        walk_findings(d.path(), 0, &mut out);
        // Files at depths 1..=4 land (4 files); depths 5,6,7 don't.
        assert_eq!(out.len(), 4, "walked: {out:?}");
    }

    #[test]
    fn missing_dir_returns_empty() {
        let d = tempfile::tempdir().unwrap();
        let mut out = Vec::new();
        walk_findings(&d.path().join("does-not-exist"), 0, &mut out);
        assert!(out.is_empty());
    }
}

#[cfg(test)]
mod todos_nav_tests {
    use crate::app::App;
    use crate::config::Config;
    use crate::focus::Focus;
    use crate::ui::todos_panel::TodoHit;

    fn app_with_todos() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("src")).unwrap();
        for n in ["a.rs", "b.rs", "c.rs"] {
            std::fs::write(
                d.path().join("src").join(n),
                "one\ntwo\nthree\nfour\nfive\n",
            )
            .unwrap();
        }
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.todos_panel_scanned_once = true;
        app.todos_hits = vec![
            TodoHit {
                tag: "TODO",
                path: d.path().join("src/a.rs"),
                line: 1,
                title: "aaa".into(),
            },
            TodoHit {
                tag: "FIXME",
                path: d.path().join("src/b.rs"),
                line: 2,
                title: "bbb".into(),
            },
            TodoHit {
                tag: "TODO",
                path: d.path().join("src/c.rs"),
                line: 3,
                title: "ccc".into(),
            },
        ];
        (d, app)
    }

    /// User report — "i should be able to click on todo on left and arrow
    /// up and down and keep focus on left panel... right now i cant click
    /// and arrow from there."
    ///
    /// Previewing must not steal focus. `open_path` sets `Focus::Pane`,
    /// which is precisely what broke the arrows after a click.
    #[test]
    fn previewing_a_todo_keeps_focus_in_the_panel() {
        let (_d, mut app) = app_with_todos();
        app.focus = Focus::Tree;
        app.todos_panel_cursor = 1;
        app.todos_panel_preview();

        assert_eq!(
            app.focus,
            Focus::Tree,
            "preview stole focus — the arrows now drive the editor"
        );
        // ...and it really did open the file.
        assert!(
            app.panes.iter().any(|p| matches!(
                p,
                crate::pane::Pane::Editor(b) if b.path.as_deref().is_some_and(|q| q.ends_with("b.rs"))
            )),
            "preview did not open the highlighted TODO's file"
        );
    }

    /// Enter is the "commit to this one" gesture and SHOULD move focus
    /// into the editor — otherwise there is no way in from the keyboard.
    #[test]
    fn enter_moves_focus_into_the_editor() {
        let (_d, mut app) = app_with_todos();
        app.focus = Focus::Tree;
        app.todos_panel_cursor = 0;
        app.todos_panel_activate();
        assert_eq!(app.focus, Focus::Pane, "Enter left focus in the panel");
    }

    /// Arrowing walks the list rather than opening a tab per step —
    /// hence preview, which reuses one tab.
    #[test]
    fn arrowing_through_todos_does_not_open_a_tab_each_time() {
        let (_d, mut app) = app_with_todos();
        app.focus = Focus::Tree;
        app.todos_panel_cursor = 0;
        app.todos_panel_preview();
        let after_first = app.panes.len();
        app.todos_panel_cursor_down();
        app.todos_panel_cursor_down();
        assert_eq!(
            app.panes.len(),
            after_first,
            "arrowing opened a tab per TODO instead of reusing the preview"
        );
        assert_eq!(app.focus, Focus::Tree, "arrowing lost panel focus");
    }

    /// `todos_panel_cursor` indexes the FILTERED list. When a filter is
    /// active, resolving it against `todos_hits` lands on a different
    /// TODO than the highlighted one.
    #[test]
    fn the_cursor_resolves_against_the_filtered_list() {
        let (_d, mut app) = app_with_todos();
        app.todos_panel_filter = "fixme".into();
        assert_eq!(app.todos_filtered().len(), 1, "filter setup");

        app.focus = Focus::Tree;
        app.todos_panel_cursor = 0;
        app.todos_panel_preview();
        assert!(
            app.panes.iter().any(|p| matches!(
                p,
                crate::pane::Pane::Editor(b) if b.path.as_deref().is_some_and(|q| q.ends_with("b.rs"))
            )),
            "filtered cursor 0 opened the wrong file — it resolved against \
             the unfiltered list"
        );
    }
}

/// TODO row actions — hand a marker to an AI session.
///
/// **User ask 2026-08-30:** "the todos should probably also have some
/// kind of action like fix, or implement… need a way for tattle people
/// to have it use our agents/skills/commands but if user not have that
/// it just uses claude code or codex."
///
/// Nothing here knows about Tattle. `claude_assets::discover` reads
/// whatever `.claude/` the workspace has; a workspace with none falls
/// through to a plain Claude Code / Codex session, which is the same
/// code path with an empty prefix.
impl crate::app::App {
    /// The prompt handed to the AI for `hit`, with `prefix` naming the
    /// agent / command / skill (empty for the plain fallback).
    ///
    /// Carries file:line and the marker text, because the model needs to
    /// find it — a bare "fix the TODO" makes it search.
    pub fn todo_action_prompt(
        &self,
        hit: &crate::ui::todos_panel::TodoHit,
        prefix: &str,
        verb: &str,
    ) -> String {
        let rel = hit
            .path
            .strip_prefix(&self.workspace)
            .unwrap_or(&hit.path)
            .to_string_lossy();
        format!(
            "{prefix}{verb} the {} at {rel}:{} — {}",
            hit.tag, hit.line, hit.title
        )
    }

    /// Build the action menu for the TODO at filtered position `row`.
    ///
    /// Discovered assets first, then the plain fallbacks under a
    /// separator. The fallbacks are ALWAYS present: a workspace with a
    /// hundred agents still wants "just open Claude Code on this".
    pub fn todos_action_menu_items(&self, row: usize) -> Vec<crate::context_menu::MenuItem> {
        use crate::context_menu::{MenuAction, MenuItem};
        let mut items = Vec::new();
        for a in crate::claude_assets::discover(&self.workspace) {
            items.push(MenuItem::new(
                a.label(),
                MenuAction::TodoAction {
                    row,
                    prefix: a.prompt_prefix(),
                    codex: false,
                },
            ));
        }
        items.push(MenuItem::new(
            "Fix with Claude Code",
            MenuAction::TodoAction {
                row,
                prefix: String::new(),
                codex: false,
            },
        ));
        items.push(MenuItem::new(
            "Fix with Codex",
            MenuAction::TodoAction {
                row,
                prefix: String::new(),
                codex: true,
            },
        ));
        items
    }

    /// Open the action menu for the TODO at filtered position `row`.
    ///
    /// Selects the row first, so the menu and the highlight cannot
    /// disagree about which TODO is being acted on.
    pub fn open_todos_action_menu(&mut self, row: usize, anchor: (u16, u16)) {
        let items = self.todos_action_menu_items(row);
        if items.is_empty() {
            return;
        }
        self.todos_panel_cursor = row;
        let title = self
            .todos_filtered()
            .get(row)
            .map(|h| format!("{} {}", h.tag, h.title));
        self.context_menu = Some(crate::context_menu::ContextMenu::new(title, anchor, items));
    }

    /// Spawn an AI session on the TODO at filtered position `row`.
    pub fn todos_run_action(&mut self, row: usize, prefix: &str, codex: bool) {
        let hit = self.todos_filtered().get(row).map(|h| (*h).clone());
        let Some(hit) = hit else {
            return;
        };
        let prompt = self.todo_action_prompt(&hit, prefix, "Fix");
        let profile = if codex {
            let mut p = crate::pty_pane::BinaryProfile::codex(self.workspace.clone());
            p.args.push(prompt);
            p
        } else {
            crate::pty_pane::BinaryProfile::claude_code_with_prompt(self.workspace.clone(), prompt)
        };
        self.open_pty(profile);
    }
}

#[cfg(test)]
mod todo_action_tests {
    use crate::app::App;
    use crate::config::Config;
    use crate::ui::todos_panel::TodoHit;

    fn app_with(assets: bool) -> (tempfile::TempDir, tempfile::TempDir, App) {
        let home = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("HOME", home.path()) };
        let d = tempfile::tempdir().unwrap();
        if assets {
            let c = d.path().join(".claude/agents");
            std::fs::create_dir_all(&c).unwrap();
            std::fs::write(
                c.join("developer.md"),
                "---\nname: developer\ndescription: implements a ticket\n---\n",
            )
            .unwrap();
            let cmds = d.path().join(".claude/commands");
            std::fs::create_dir_all(&cmds).unwrap();
            std::fs::write(cmds.join("qa-sweep.md"), "sweep\n").unwrap();
        }
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Build hits under `app.workspace`, not the raw tempdir path:
        // `App::new` canonicalizes, and on macOS that turns /var into
        // /private/var. The real scanner walks from `app.workspace` so
        // its hits always match; a fixture using the tempdir path does
        // not, and `strip_prefix` then leaves an absolute path.
        let root = app.workspace.clone();
        app.todos_hits = vec![TodoHit {
            tag: "FIXME",
            path: root.join("src/a.rs"),
            line: 42,
            title: "handle the empty case".into(),
        }];
        (d, home, app)
    }

    /// The Tattle half of the ask: a workspace's own agents and commands
    /// become actions, with the plain sessions still offered under them.
    #[test]
    fn a_workspace_with_claude_assets_offers_them_as_actions() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, _h, app) = app_with(true);
        let labels: Vec<String> = app
            .todos_action_menu_items(0)
            .into_iter()
            .map(|i| i.label)
            .collect();
        assert!(
            labels.contains(&"agent: developer".to_string()),
            "{labels:?}"
        );
        assert!(labels.contains(&"/qa-sweep".to_string()), "{labels:?}");
        assert!(
            labels.contains(&"Fix with Claude Code".to_string()),
            "the plain fallback vanished when assets existed: {labels:?}"
        );
    }

    /// The other half: someone without any of that still gets a working
    /// menu, which is the same code path with an empty prefix.
    #[test]
    fn a_workspace_without_assets_still_offers_claude_and_codex() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, _h, app) = app_with(false);
        let labels: Vec<String> = app
            .todos_action_menu_items(0)
            .into_iter()
            .map(|i| i.label)
            .collect();
        assert_eq!(
            labels,
            vec!["Fix with Claude Code", "Fix with Codex"],
            "a workspace with no .claude/ got something other than the \
             plain fallbacks: {labels:?}"
        );
    }

    /// The prompt has to carry file:line and the marker text. "Fix the
    /// TODO" with no location makes the model go looking.
    #[test]
    fn the_prompt_names_the_file_line_and_text() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, _h, app) = app_with(true);
        let hit = app.todos_hits[0].clone();
        let p = app.todo_action_prompt(&hit, "Use the developer agent to ", "Fix");
        assert!(p.starts_with("Use the developer agent to Fix"), "{p}");
        assert!(p.contains("src/a.rs:42"), "no file:line in the prompt: {p}");
        assert!(p.contains("handle the empty case"), "no marker text: {p}");
        assert!(p.contains("FIXME"), "the tag is dropped: {p}");
        // Workspace-relative, not the absolute tempdir path.
        assert!(!p.contains("/var/"), "leaked an absolute path: {p}");
    }

    /// The menu's row index is the FILTERED position, like the cursor —
    /// with a filter active, resolving against `todos_hits` would act on
    /// a different TODO than the one clicked.
    #[test]
    fn the_action_resolves_against_the_filtered_list() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, _h, mut app) = app_with(false);
        let root = app.workspace.clone();
        app.todos_hits.push(TodoHit {
            tag: "TODO",
            path: root.join("src/b.rs"),
            line: 7,
            title: "second".into(),
        });
        app.todos_panel_filter = "second".into();
        assert_eq!(app.todos_filtered().len(), 1, "filter setup");
        let hit = app.todos_filtered()[0].clone();
        assert_eq!(hit.line, 7, "filtered position 0 is not the filtered hit");
    }

    /// Opening the menu selects the row, or the menu and the highlight
    /// disagree about which TODO is being acted on.
    #[test]
    fn opening_the_menu_moves_the_selection_to_that_row() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, _h, mut app) = app_with(false);
        let root = app.workspace.clone();
        app.todos_hits.push(TodoHit {
            tag: "TODO",
            path: root.join("src/b.rs"),
            line: 7,
            title: "second".into(),
        });
        app.todos_panel_cursor = 0;
        app.open_todos_action_menu(1, (0, 0));
        assert_eq!(app.todos_panel_cursor, 1, "the selection did not follow");
        assert!(app.context_menu.is_some(), "no menu opened");
    }
}
