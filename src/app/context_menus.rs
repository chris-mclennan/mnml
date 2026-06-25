//! Context-menu and menu-action machinery.
//!
//! Every `open_*_context_menu` opener (tree row, workspace header,
//! editor gutter, pty dock, statusline chip, …) lives here, plus the
//! menu navigation primitives (move / select / accept / cancel) and
//! the big `run_menu_action` dispatcher that wires every `MenuAction`
//! variant to its App method.
//!
//! Extracted from `app/mod.rs` (file-split follow-up).

use super::*;

impl App {
    // ─── context menu (right-click) ─────────────────────────────────
    /// Right-click in the file tree on `path` (at screen cell `anchor`).
    pub fn open_tree_context_menu(&mut self, path: PathBuf, is_dir: bool, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        let rel = rel_path(&self.workspace, &path);
        // `parent` for new-file/new-folder: the dir itself when right-clicked
        // on a directory, the file's parent dir when right-clicked on a file.
        let parent = if is_dir {
            path.clone()
        } else {
            path.parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| self.workspace.clone())
        };
        let items = if is_dir {
            vec![
                MenuItem::new("Set as workspace", MenuAction::SetAsWorkspace(path.clone())),
                MenuItem::new("New file…", MenuAction::NewFile(parent.clone())),
                MenuItem::new("New folder…", MenuAction::NewFolder(parent)),
                MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
                MenuItem::new("Delete…", MenuAction::Delete(path.clone())),
                MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                MenuItem::new("Open externally", MenuAction::OpenExternally(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
                MenuItem::new("Refresh tree", MenuAction::Command("tree.refresh")),
            ]
        } else {
            let mut items = vec![
                MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
                MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            ];
            if is_markdown_path(&path) {
                items.push(MenuItem::new(
                    "Preview markdown",
                    MenuAction::PreviewMarkdown(path.clone()),
                ));
            }
            items.extend([
                MenuItem::new("New file…", MenuAction::NewFile(parent.clone())),
                MenuItem::new("New folder…", MenuAction::NewFolder(parent)),
                MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
                MenuItem::new("Delete…", MenuAction::Delete(path.clone())),
                MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                MenuItem::new("Open externally", MenuAction::OpenExternally(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            ]);
            items
        };
        self.context_menu = Some(ContextMenu::new(Some(name), anchor, items));
    }

    /// Right-click on an integration chip → quick-actions menu.
    /// Lets the user edit the chip's glyph/color/tooltip in place
    /// or remove it without opening the discovery overlay first.
    /// `icon_idx` is the position in `config.ui.integration_icons`.
    pub fn open_integration_chip_context_menu(
        &mut self,
        icon_idx: usize,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(icon) = self.config.ui.integration_icons.get(icon_idx) else {
            return;
        };
        let title = icon
            .tooltip
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| icon.id.clone());
        let id = icon.id.clone();
        let items = vec![
            MenuItem::new("Edit…", MenuAction::EditIntegration(id.clone())),
            MenuItem::new("Remove from rail", MenuAction::RemoveIntegration(id)),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// VS Code-style gear-icon menu — opens when the user clicks
    /// the gear at the bottom of the activity bar. Five-item menu
    /// covering the daily-use trio (Settings / Command Palette /
    /// Cheatsheet), a Themes submenu placeholder, and About.
    pub fn open_gear_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Settings…", MenuAction::Command("view.settings")),
            MenuItem::new("Command Palette…", MenuAction::Command("palette")),
            MenuItem::new("Cheatsheet…", MenuAction::Command("view.help")),
            // Themes — opens the existing theme picker (a Cmd+P-style
            // filtered list of every discovered theme). v1 of the
            // gear menu reuses it directly instead of building a
            // submenu — fewer clicks for the same result.
            MenuItem::new("Themes…", MenuAction::Command("theme.pick")),
            MenuItem::new("About mnml", MenuAction::Command("view.about")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("mnml".into()), anchor, items));
    }

    /// Right-click on the `> WORKSPACE` section header — exposes the
    /// workspace-scoped ops as a menu.
    pub fn open_workspace_header_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self
            .workspace
            .file_name()
            .and_then(|n| n.to_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "workspace".into());
        let items = vec![
            MenuItem::new(
                "Toggle expand",
                MenuAction::Command("view.toggle_tree_section"),
            ),
            MenuItem::new(
                "Switch workspace…",
                MenuAction::Command("view.switch_workspace"),
            ),
            MenuItem::new("Add workspace…", MenuAction::Command("view.add_workspace")),
            MenuItem::new(
                "Reveal in Finder",
                MenuAction::RevealInFinder(self.workspace.clone()),
            ),
            MenuItem::new("Refresh tree", MenuAction::Command("tree.refresh")),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on an extra-workspace section header — toggle, switch to,
    /// or remove that extra workspace.
    pub fn open_extra_workspace_header_context_menu(&mut self, ws_idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self
            .extra_workspaces
            .get(ws_idx)
            .map(|w| w.name.clone())
            .unwrap_or_else(|| format!("workspace {ws_idx}"));
        let path = self.extra_workspaces.get(ws_idx).map(|w| w.root.clone());
        let mut items = vec![MenuItem::new("Toggle expand", MenuAction::Command(""))];
        // Replace the Command("") placeholder with a no-op since we don't
        // have a per-extra "toggle" command; the click action will toggle
        // directly via the rect handler in tui.rs. Keep the row for menu
        // parity. Switching workspaces still routes through the picker.
        items[0] = MenuItem::new(
            "Switch workspace…",
            MenuAction::Command("view.switch_workspace"),
        );
        items.push(MenuItem::new(
            "Remove this workspace",
            MenuAction::Command("view.remove_workspace"),
        ));
        if let Some(p) = path {
            items.push(MenuItem::new(
                "Reveal in Finder",
                MenuAction::RevealInFinder(p),
            ));
        }
        items.push(MenuItem::new(
            "Refresh tree",
            MenuAction::Command("tree.refresh"),
        ));
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on an editor gutter row — exposes the most common line-
    /// scoped operations as a discoverable menu. Mouse coords identify
    /// `(pane_id, line)`; the menu items run against that target.
    pub fn open_editor_gutter_context_menu(
        &mut self,
        pane_id: PaneId,
        line: u32,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // Place the cursor + focus the pane so the existing line-scoped
        // commands (which read the cursor position) act on the right line.
        let prior_active = self.active;
        self.active = Some(pane_id);
        self.focus_pane();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(pane_id) {
            b.editor.place_cursor(line as usize, 0);
        }
        let title = self
            .panes
            .get(pane_id)
            .and_then(|p| match p {
                Pane::Editor(b) => Some(b.display_name().to_string()),
                _ => None,
            })
            .map(|name| format!("{name} : line {}", line + 1))
            .unwrap_or_else(|| format!("line {}", line + 1));
        let items = vec![
            MenuItem::new(
                "Toggle breakpoint",
                MenuAction::Command("dap.toggle_breakpoint"),
            ),
            MenuItem::new(
                "Conditional breakpoint…",
                MenuAction::Command("dap.toggle_breakpoint_conditional"),
            ),
            MenuItem::new(
                "Go to definition",
                MenuAction::Command("lsp.goto_definition"),
            ),
            MenuItem::new("Find references", MenuAction::Command("lsp.references")),
            MenuItem::new("Hover info", MenuAction::Command("lsp.hover")),
            MenuItem::new("Peek change", MenuAction::Command("git.peek_change")),
            MenuItem::new("Toggle blame", MenuAction::Command("git.blame_toggle")),
            MenuItem::new(
                "Open at remote (browse line)",
                MenuAction::Command("git.browse"),
            ),
        ];
        let _ = prior_active; // Capture happened above for future hooks.
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on the editor BODY (not the gutter) — exposes the
    /// text-scoped operations VS Code users expect: cut / copy /
    /// paste, plus the same LSP / Save shortcuts the gutter menu
    /// offers. Places the cursor at the click position first so the
    /// commands (which read the cursor) act on the right spot.
    /// Surfaced by the VS-Code-mouse hunt's SEV-2 "Editor text body
    /// has no right-click context menu" finding.
    pub fn open_editor_body_context_menu(
        &mut self,
        pane_id: PaneId,
        row: usize,
        col: usize,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        self.active = Some(pane_id);
        self.focus_pane();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(pane_id) {
            // Place the cursor at the click position so the LSP /
            // fold commands below act on that spot. (Any active
            // selection gets cleared as a side-effect of place_cursor
            // — matches the gutter menu's behavior; the user can
            // re-select if needed before picking a menu item.)
            b.editor.place_cursor(row, col);
        }
        let (title, dirty, has_path) = match self.panes.get(pane_id) {
            Some(Pane::Editor(b)) => (
                format!("{} : line {}", b.display_name(), row + 1),
                b.dirty,
                b.path.is_some(),
            ),
            _ => (format!("line {}", row + 1), false, false),
        };
        let mut items = vec![
            MenuItem::new(
                "Go to definition",
                MenuAction::Command("lsp.goto_definition"),
            ),
            MenuItem::new("Find references", MenuAction::Command("lsp.references")),
            MenuItem::new("Hover info", MenuAction::Command("lsp.hover")),
            MenuItem::new("Rename symbol…", MenuAction::Command("lsp.rename")),
            MenuItem::new(
                "Select all occurrences",
                MenuAction::Command("editor.select_all_occurrences"),
            ),
            MenuItem::new(
                "Expand selection (LSP)",
                MenuAction::Command("lsp.selection_expand"),
            ),
            MenuItem::new("Toggle fold", MenuAction::Command("editor.toggle_fold")),
        ];
        if dirty && has_path {
            items.push(MenuItem::new("Save", MenuAction::SavePane(pane_id)));
        }
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on a pty pane (terminal / Claude / Codex) — exposes
    /// dock-position controls so the user can shift the pane around the
    /// layout (left / right / top / bottom) or maximize it, without
    /// memorizing the `Ctrl+W H/J/K/L` chords. Focuses the pane first
    /// so the `view.move_split_*` commands act on it.
    pub fn open_pty_dock_context_menu(&mut self, pane_id: PaneId, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        self.active = Some(pane_id);
        self.focus_pane();
        let title = self
            .panes
            .get(pane_id)
            .map(|p| p.title())
            .unwrap_or_else(|| "terminal".into());
        let items = vec![
            MenuItem::new("Dock left", MenuAction::Command("view.move_split_left")),
            MenuItem::new("Dock right", MenuAction::Command("view.move_split_right")),
            MenuItem::new("Dock top", MenuAction::Command("view.move_split_up")),
            MenuItem::new("Dock bottom", MenuAction::Command("view.move_split_down")),
            MenuItem::new("Maximize width", MenuAction::Command("view.maximize_width")),
            MenuItem::new(
                "Maximize height",
                MenuAction::Command("view.maximize_height"),
            ),
            MenuItem::new("Full screen (zen)", MenuAction::Command("view.zen")),
            MenuItem::new(
                "Equalize splits",
                MenuAction::Command("view.equalize_splits"),
            ),
            MenuItem::new("Close pane", MenuAction::Command("buffer.close")),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on the statusline workspace / repo chip — exposes
    /// repo + worktree switching so they don't need keyboard chords.
    pub fn open_statusline_workspace_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self
            .repos
            .get(self.active_repo)
            .map(|r| r.name.clone())
            .or_else(|| {
                self.workspace
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| "workspace".into());
        let mut items = vec![];
        if self.repos.len() > 1 {
            items.push(MenuItem::new(
                "Switch repo…",
                MenuAction::Command("git.switch_repo"),
            ));
            items.push(MenuItem::new(
                "Next repo",
                MenuAction::Command("git.next_repo"),
            ));
            items.push(MenuItem::new(
                "Previous repo",
                MenuAction::Command("git.prev_repo"),
            ));
        }
        items.push(MenuItem::new(
            "Worktrees…",
            MenuAction::Command("git.worktrees"),
        ));
        items.push(MenuItem::new(
            "Switch workspace…",
            MenuAction::Command("view.switch_workspace"),
        ));
        items.push(MenuItem::new(
            "Add workspace…",
            MenuAction::Command("view.add_workspace"),
        ));
        items.push(MenuItem::new(
            "Refresh repos",
            MenuAction::Command("git.refresh_repos"),
        ));
        items.push(MenuItem::new(
            "Reveal in Finder",
            MenuAction::RevealInFinder(self.active_repo_path().to_path_buf()),
        ));
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on the statusline mode chip — exposes the input-style
    /// switcher.
    pub fn open_statusline_mode_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Use vim", MenuAction::Command("editor.use_vim")),
            MenuItem::new("Use standard", MenuAction::Command("editor.use_standard")),
            MenuItem::new("Toggle keymap", MenuAction::Command("editor.toggle_keymap")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Input style".into()), anchor, items));
    }

    /// Right-click on the statusline clock chip — exposes the local ↔ UTC
    /// toggle as a discoverable menu (vs left-click which just flips).
    pub fn open_statusline_clock_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let local_label = if self.clock_show_utc {
            "Show local time"
        } else {
            "Show local time (current)"
        };
        let utc_label = if self.clock_show_utc {
            "Show UTC (current)"
        } else {
            "Show UTC"
        };
        let items = vec![
            MenuItem::new(local_label, MenuAction::Command("clock.local")),
            MenuItem::new(utc_label, MenuAction::Command("clock.utc")),
            MenuItem::new("Hide clock", MenuAction::Command("clock.hide")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Clock".into()), anchor, items));
    }

    pub fn context_menu_cancel(&mut self) {
        self.context_menu = None;
    }

    pub fn context_menu_move(&mut self, delta: isize) {
        if let Some(m) = &mut self.context_menu {
            if delta < 0 {
                m.move_up();
            } else {
                m.move_down();
            }
        }
    }

    pub fn context_menu_select(&mut self, i: usize) {
        if let Some(m) = &mut self.context_menu {
            m.set_selected(i);
        }
    }

    /// Run the highlighted context-menu item and close the menu.
    pub fn context_menu_accept(&mut self) {
        let Some(menu) = self.context_menu.take() else {
            return;
        };
        let Some(item) = menu.items.into_iter().nth(menu.selected) else {
            return;
        };
        self.run_menu_action(item.action);
    }

    fn run_menu_action(&mut self, action: crate::context_menu::MenuAction) {
        use crate::context_menu::MenuAction::*;
        match action {
            OpenPath(p) => self.open_path(&p),
            OpenInSplit(p) => {
                self.split_active(crate::layout::SplitDir::Horizontal);
                self.open_path(&p);
            }
            RevealInFinder(p) => {
                // macOS; harmless no-op (an Err we ignore) elsewhere.
                let _ = std::process::Command::new("open").arg("-R").arg(&p).spawn();
            }
            OpenExternally(p) => open_path_external(&p),
            CopyPath(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast(format!("copied {text}"));
            }
            SetAsWorkspace(p) => {
                self.set_workspace_to(p);
            }
            EditIntegration(id) => {
                self.open_integration_edit_by_id(&id);
            }
            RemoveIntegration(id) => {
                self.remove_integration_by_id(&id);
            }
            Command(id) => {
                crate::command::run(id, self);
            }
            CloseTab(id) => self.close_pane(id),
            CloseOtherTabs(id) => self.close_panes_except(Some(id)),
            CloseAllTabs => self.close_panes_except(None),
            SavePane(id) => {
                // `save_active` reads `self.active`; reveal the pane
                // first so the existing save path lights up. The
                // user's previous focus isn't preserved (matches the
                // existing CloseTab pattern, which also drops focus
                // onto the closed pane's neighbour). One-click save
                // is the goal of the menu entry.
                self.reveal_pane(id);
                self.save_active();
            }
            PinTab(id) => self.buffer_pin_toggle_at(id),
            RenameSession(id) => {
                // Reveal the session so it's the active pane, then
                // reuse the `:rename` prompt (which targets `active`).
                self.reveal_pane(id);
                self.open_rename_session_prompt();
            }
            NewFile(parent) => self.open_new_file_prompt(parent),
            NewFolder(parent) => self.open_new_folder_prompt(parent),
            Rename(path) => self.open_fs_rename_prompt(path),
            Delete(path) => self.open_fs_delete_prompt(path),
            GitCheckoutBranch(name) => self.git_checkout_named(&name),
            GitNewBranchFrom(name) => self.git_new_branch_from(name),
            GitDeleteBranch(name) => self.git_delete_branch_prompt(name),
            GitWorktreeShell(path) => self.open_worktree_shell(&path.to_string_lossy()),
            GitWorktreeRemove(path) => self.git_worktree_remove_prompt(path),
            GitStashPop(id) => self.git_stash_pop(&id),
            GitStashApply(id) => self.git_stash_apply(&id),
            GitStashDrop(id) => self.git_stash_drop_prompt(&id),
            GitTagDelete(name) => self.git_tag_delete_prompt(&name),
            GitRemoteCheckout(name) => self.checkout_branch(&name),
            SessionRename(pid) => self.open_session_rename_prompt(pid),
            SessionSetColor(pid, color) => self.set_session_color(pid, color),
            SessionClose(pid) => self.close_session(pid),
            WorkspaceEditName(idx) => self.workspaces_editor_open_rename(idx),
            WorkspaceEditPath(idx) => self.workspaces_editor_open_path(idx),
            WorkspaceEditGroup(idx) => self.workspaces_editor_open_group(idx),
            WorkspaceDelete(idx) => self.workspaces_editor_delete(idx),
            PreviewMarkdown(path) => self.open_md_preview_for_path(path, self.active, true),
            OpenUrl(url) => {
                open_url_external(&url);
                self.toast("opened in browser");
            }
            CopyText(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast("copied URL");
            }
            DiffOpenAtRevision { hash, rel } => self.open_file_at_revision(&hash, &rel),
            DiffHunkAction {
                pane_id,
                hunk_index,
                action,
            } => self.apply_hunk_action(pane_id, hunk_index, action),
            GitStageFile(rel) => {
                let rel_s = rel.to_string_lossy().into_owned();
                match crate::git::stage::stage(self.active_repo_path(), &rel_s) {
                    Ok(()) => {
                        self.toast(format!("staged {rel_s}"));
                        self.after_git_change();
                    }
                    Err(e) => self.toast(format!("git add: {e}")),
                }
            }
            GitUnstageFile(rel) => {
                let rel_s = rel.to_string_lossy().into_owned();
                match crate::git::stage::unstage(self.active_repo_path(), &rel_s) {
                    Ok(()) => {
                        self.toast(format!("unstaged {rel_s}"));
                        self.after_git_change();
                    }
                    Err(e) => self.toast(format!("git restore --staged: {e}")),
                }
            }
            GitDiscardFile(rel) => self.open_discard_file_prompt(rel),
            GitStashFile(rel) => {
                let rel_s = rel.to_string_lossy().into_owned();
                match crate::git::stage::stash_file(self.active_repo_path(), &rel_s) {
                    Ok(()) => {
                        self.toast(format!("stashed {rel_s}"));
                        self.after_git_change();
                    }
                    Err(e) => self.toast(format!("git stash: {e}")),
                }
            }
            GitIgnoreFile(rel) => {
                let rel_s = rel.to_string_lossy().into_owned();
                match crate::git::stage::append_gitignore(self.active_repo_path(), &rel_s) {
                    Ok(()) => {
                        self.toast(format!("ignored {rel_s}"));
                        self.after_git_change();
                    }
                    Err(e) => self.toast(format!("ignore: {e}")),
                }
            }
            GitIgnoreExtension(ext) => {
                let pat = format!("*.{ext}");
                match crate::git::stage::append_gitignore(self.active_repo_path(), &pat) {
                    Ok(()) => {
                        self.toast(format!("ignored {pat}"));
                        self.after_git_change();
                    }
                    Err(e) => self.toast(format!("ignore: {e}")),
                }
            }
        }
    }

    pub fn run_wip_action(&mut self, action: crate::WipAction) {
        // Three of the variants don't return Result<String, String> —
        // handle them up front. `OpenCommitPrompt` now prefers the
        // inline textarea on the active GitGraph pane (commits using
        // whatever the user typed there) and falls back to the modal
        // prompt for non-GitGraph contexts.
        match &action {
            crate::WipAction::OpenCommitPrompt => {
                self.commit_from_active_wip_textarea_or_prompt();
                return;
            }
            crate::WipAction::RequestAiCommitMessage => {
                self.request_ai_commit_message();
                return;
            }
            crate::WipAction::ClearCommitDraft => {
                if let Some(Pane::GitGraph(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    g.wip_commit.clear();
                }
                return;
            }
            _ => {}
        }
        let repo = self.active_repo_path().to_path_buf();
        let result: Result<String, String> = match &action {
            crate::WipAction::StageAll => crate::git::stage::stage_all(&repo)
                .map(|_| "staged all changes".to_string())
                .map_err(|e| format!("git add -A: {e}")),
            crate::WipAction::UnstageAll => crate::git::stage::unstage_all(&repo)
                .map(|_| "unstaged everything".to_string())
                .map_err(|e| format!("git restore --staged: {e}")),
            crate::WipAction::StageFile(path) => {
                let rel = path
                    .strip_prefix(&self.workspace)
                    .unwrap_or(path)
                    .display()
                    .to_string();
                crate::git::stage::stage(&repo, &rel)
                    .map(|_| format!("staged {rel}"))
                    .map_err(|e| format!("git add: {e}"))
            }
            crate::WipAction::UnstageFile(path) => {
                let rel = path
                    .strip_prefix(&self.workspace)
                    .unwrap_or(path)
                    .display()
                    .to_string();
                crate::git::stage::unstage(&repo, &rel)
                    .map(|_| format!("unstaged {rel}"))
                    .map_err(|e| format!("git restore --staged: {e}"))
            }
            crate::WipAction::OpenCommitPrompt
            | crate::WipAction::RequestAiCommitMessage
            | crate::WipAction::ClearCommitDraft => unreachable!(),
        };
        match result {
            Ok(msg) => {
                self.after_git_change();
                self.refresh_active_git_graph();
                self.toast(msg);
            }
            Err(e) => self.toast(e),
        }
    }
}
