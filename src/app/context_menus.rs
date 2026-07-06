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
    /// Keyboard equivalent of right-click — opens the context menu
    /// over whichever surface currently has focus. Mirrors VS Code +
    /// macOS Shift+F10 convention. Routes by Focus:
    ///   * Focus::Tree → tree-row context menu over the selected row
    ///     (uses the rail's last-known x and the row's screen y).
    ///   * Focus::Pane → bufferline-tab context menu for the active
    ///     pane (anchor at the active tab's rect).
    ///   * hover_chip set (any chip the mouse most-recently hovered)
    ///     → the corresponding chip context menu. Lets the user
    ///     tab to a chip with the mouse, then drive everything else
    ///     by keyboard.
    ///   * Other (no selection, cmdline, etc.) → toast.
    pub fn open_context_menu_at_focus(&mut self) {
        // v2 polish (2026-06-28): hover_chip fallback for chip /
        // launcher / gear right-click via keyboard. The cursor's
        // last-hovered chip is the most-natural target — same
        // pattern as pressing the right-mouse-button when over a
        // chip. keyboard-hunter v3 2026-06-28 SEV-2: was dead code
        // because Focus::Pane with active.is_some() always matched
        // first. Now a RECENT hover_chip (within 2s) takes priority
        // — matches user intent when they hovered a chip and then
        // hit Shift+F10 deliberately.
        let hover_recent = self
            .hover_chip
            .as_ref()
            .is_some_and(|(_, t)| t.elapsed() < std::time::Duration::from_secs(2));
        // vscode-user 2026-06-28 SEV-3: statusline chips have
        // right-click context menus (workspace/branch/mode/clock)
        // but Shift+F10 couldn't reach them. Extended the hover-
        // chip anchor closure so any statusline chip the user
        // hovered within 2s opens its menu on Shift+F10.
        // Statusline is at the BOTTOM of the screen — anchor y =
        // rect.y - 1 so the menu pops UPWARD (the rect.y + 1
        // pattern used elsewhere would render below the screen).
        let above_anchor =
            |rect: ratatui::layout::Rect| -> (u16, u16) { (rect.x, rect.y.saturating_sub(1)) };
        let hover_chip_anchor = self.hover_chip.as_ref().and_then(|(c, _)| match c {
            crate::HoverChip::IntegrationIcon(idx) => {
                let &(rect, _) = self
                    .rects
                    .integration_icon_rects
                    .iter()
                    .find(|(_, i)| i == idx)?;
                Some((
                    crate::HoverChip::IntegrationIcon(*idx),
                    (rect.x, rect.y + 1),
                ))
            }
            crate::HoverChip::LauncherIcon(idx) => {
                let &(rect, _) = self
                    .rects
                    .launcher_icon_rects
                    .iter()
                    .find(|(_, i)| i == idx)?;
                Some((crate::HoverChip::LauncherIcon(*idx), (rect.x, rect.y + 1)))
            }
            crate::HoverChip::ActivityBarGear => self
                .rects
                .activity_bar_gear
                .map(|rect| (crate::HoverChip::ActivityBarGear, (rect.x, rect.y + 1))),
            crate::HoverChip::StatuslineBranch => self
                .rects
                .statusline_branch_chip
                .map(|rect| (crate::HoverChip::StatuslineBranch, above_anchor(rect))),
            crate::HoverChip::StatuslineWorkspace => self
                .rects
                .statusline_workspace_chip
                .map(|rect| (crate::HoverChip::StatuslineWorkspace, above_anchor(rect))),
            crate::HoverChip::StatuslineMode => self
                .rects
                .statusline_mode_chip
                .map(|rect| (crate::HoverChip::StatuslineMode, above_anchor(rect))),
            crate::HoverChip::StatuslineClock => self
                .rects
                .statusline_clock_chip
                .map(|rect| (crate::HoverChip::StatuslineClock, above_anchor(rect))),
            _ => None,
        });
        // Tree: use selected_row + the first tree row rect to derive
        // a sensible anchor. Without rect data, fall back to (1, 1).
        // Recent hover_chip takes precedence over focus-based routing.
        // A user who hovered a chip and pressed Shift+F10 within 2s
        // clearly wants THAT chip's menu, not the active tab's.
        if hover_recent && let Some((chip, anchor)) = hover_chip_anchor {
            match chip {
                crate::HoverChip::IntegrationIcon(idx) => {
                    self.open_integration_chip_context_menu(idx, anchor);
                }
                crate::HoverChip::LauncherIcon(idx) => {
                    self.open_launcher_chip_context_menu(idx, anchor);
                }
                crate::HoverChip::ActivityBarGear => {
                    self.open_gear_context_menu(anchor);
                }
                crate::HoverChip::StatuslineBranch => {
                    self.open_statusline_branch_context_menu(anchor);
                }
                crate::HoverChip::StatuslineWorkspace => {
                    self.open_statusline_workspace_context_menu(anchor);
                }
                crate::HoverChip::StatuslineMode => {
                    self.open_statusline_mode_context_menu(anchor);
                }
                crate::HoverChip::StatuslineClock => {
                    self.open_statusline_clock_context_menu(anchor);
                }
                _ => {}
            }
            return;
        }
        if matches!(self.focus, crate::focus::Focus::Tree) {
            if let Some(row) = self.tree.selected_row() {
                // Anchor x: rail's left edge plus a few cells; y: try
                // to grab the y of the selected row from
                // `tree_icon_buttons` which carries per-row rects.
                let anchor_y = self
                    .rects
                    .tree_icon_buttons
                    .get(self.tree.cursor())
                    .map(|(r, _)| r.y)
                    .unwrap_or(2);
                let anchor_x = self.rects.tree.map(|r| r.x + 2).unwrap_or(1);
                self.open_tree_context_menu(row.path, row.is_dir, (anchor_x, anchor_y));
                return;
            }
            self.toast("no tree row selected");
            return;
        }
        // Pane: open the bufferline-tab context menu for the active
        // pane. Anchor at the tab's rect if we have it; else fall
        // back to top-left of the body.
        if matches!(self.focus, crate::focus::Focus::Pane)
            && let Some(pid) = self.active
        {
            let anchor = self
                .rects
                .bufferline_tabs
                .iter()
                .find(|(_, id)| *id == pid)
                .map(|(r, _)| (r.x + 1, r.y))
                .or_else(|| self.rects.body.map(|r| (r.x, r.y)))
                .unwrap_or((1, 1));
            self.open_tab_context_menu(pid, anchor);
            return;
        }
        // hover_chip fallback — chip / launcher / gear menus.
        if let Some((chip, anchor)) = hover_chip_anchor {
            match chip {
                crate::HoverChip::IntegrationIcon(idx) => {
                    self.open_integration_chip_context_menu(idx, anchor);
                }
                crate::HoverChip::LauncherIcon(idx) => {
                    self.open_launcher_chip_context_menu(idx, anchor);
                }
                crate::HoverChip::ActivityBarGear => {
                    self.open_gear_context_menu(anchor);
                }
                _ => {}
            }
            return;
        }
        self.toast("no context menu at this focus");
    }

    /// Right-click in the file tree on `path` (at screen cell `anchor`).
    /// Right-click a row inside an extra-workspace section. Resolves
    /// the row's path/is_dir from that workspace's own tree and hands
    /// off to `open_tree_context_menu` (which uses the primary workspace
    /// only for the "Copy path" relative-path display — actions themselves
    /// operate on absolute paths, so they work either way).
    pub fn open_extra_workspace_tree_row_context_menu(
        &mut self,
        ws_idx: usize,
        row_idx: usize,
        anchor: (u16, u16),
    ) {
        let Some(ws) = self.extra_workspaces.get(ws_idx) else {
            return;
        };
        let rows = ws.tree.visible_rows();
        let Some(row) = rows.get(row_idx) else {
            return;
        };
        let path = row.path.clone();
        let is_dir = row.is_dir;
        self.open_tree_context_menu(path, is_dir, anchor);
    }

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
                MenuItem::new("New folder…", MenuAction::NewFolder(parent.clone())),
                MenuItem::new(
                    "Expand recursively",
                    MenuAction::TreeExpandRecursive(path.clone()),
                ),
                MenuItem::new(
                    "Collapse recursively",
                    MenuAction::TreeCollapseRecursive(path.clone()),
                ),
                MenuItem::new("Open in terminal", MenuAction::OpenTerminal(parent)),
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
                MenuItem::new("New folder…", MenuAction::NewFolder(parent.clone())),
                MenuItem::new("Open in terminal", MenuAction::OpenTerminal(parent)),
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
    pub fn open_integration_chip_context_menu(&mut self, icon_idx: usize, anchor: (u16, u16)) {
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
        // Enable toggle — labelled per current state. After the
        // palette-bar refactor, `enabled=false` chips don't paint;
        // this is the in-app path to flip them.
        let toggle_label = if icon.enabled {
            "Disable (hide chip)"
        } else {
            "Enable (show chip)"
        };
        // Position-aware reorder items — skip Move up on the first
        // row, Move down on the last, so the menu doesn't offer
        // no-ops. 2026-07-03 user-request: reorder from UI.
        let is_first = icon_idx == 0;
        let is_last = icon_idx + 1 >= self.config.ui.integration_icons.len();
        let mut items = Vec::new();
        items.push(MenuItem::new(
            toggle_label,
            MenuAction::ToggleIntegrationEnabled(id.clone()),
        ));
        if !is_first {
            items.push(MenuItem::new(
                "Move to top",
                MenuAction::MoveIntegrationToTop(id.clone()),
            ));
            items.push(MenuItem::new(
                "Move up",
                MenuAction::MoveIntegrationUp(id.clone()),
            ));
        }
        if !is_last {
            items.push(MenuItem::new(
                "Move down",
                MenuAction::MoveIntegrationDown(id.clone()),
            ));
            items.push(MenuItem::new(
                "Move to bottom",
                MenuAction::MoveIntegrationToBottom(id.clone()),
            ));
        }
        items.push(MenuItem::new(
            "Edit…",
            MenuAction::EditIntegration(id.clone()),
        ));
        items.push(MenuItem::new("Remove", MenuAction::RemoveIntegration(id)));
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click menu for a launcher chip on the palette bar.
    /// Chips render identically to integration chips but have
    /// fewer in-app management gestures — launcher_icons currently
    /// only support enable/disable (no Edit / Remove overlay
    /// because launchers are TOML-only). vscode-user-mouse SEV-2:
    /// dropped the "parallel" claim from the doc since the menus
    /// genuinely diverge here.
    pub fn open_top_bar_cluster_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let current = self.config.ui.top_bar_cluster_mode.as_str();
        let marker = |val: &str| if val == current { "✓ " } else { "  " };
        let items = vec![
            MenuItem::new(
                format!("{}Expanded (always show TABS)", marker("expanded")),
                MenuAction::SetTopBarClusterMode("expanded"),
            ),
            MenuItem::new(
                format!("{}Compact (hide TABS)", marker("compact")),
                MenuAction::SetTopBarClusterMode("compact"),
            ),
            MenuItem::new(
                format!("{}Auto (space-based)", marker("auto")),
                MenuAction::SetTopBarClusterMode("auto"),
            ),
        ];
        self.context_menu = Some(ContextMenu::new(
            Some("Top-bar cluster".to_string()),
            anchor,
            items,
        ));
    }

    pub fn open_launcher_chip_context_menu(&mut self, icon_idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(icon) = self.config.ui.launcher_icons.get(icon_idx) else {
            return;
        };
        let title = icon
            .tooltip
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| icon.id.clone());
        let id = icon.id.clone();
        let toggle_label = if icon.enabled {
            "Disable (hide chip)"
        } else {
            "Enable (show chip)"
        };
        let items = vec![MenuItem::new(
            toggle_label,
            MenuAction::ToggleLauncherEnabled(id),
        )];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click context menu for a right-panel tab chip. v3
    /// polish — mouse-hunter SEV-2 F.
    pub fn open_right_panel_tab_context_menu(&mut self, tab_idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(&pid) = self.right_panel_panes.get(tab_idx) else {
            return;
        };
        let title = self
            .panes
            .get(pid)
            .map(|p| p.title())
            .unwrap_or_else(|| "tab".to_string());
        let mut items = Vec::new();
        if tab_idx != self.right_panel_active_idx {
            // render-reviewer/crash-investigator W-1: jump to the
            // clicked index directly. Was firing next_tab which
            // worked at MAX_TABS=2 but breaks past that.
            items.push(MenuItem::new(
                "Switch to this tab",
                MenuAction::SetRightPanelTab(tab_idx),
            ));
        }
        items.push(MenuItem::new("Close tab", MenuAction::CloseTab(pid)));
        // 2026-06-29 polish: parity with bufferline tab menu.
        // Only show when there's something to close — Close
        // others needs >=2 tabs; Close all needs >=1.
        if self.right_panel_panes.len() > 1 {
            items.push(MenuItem::new(
                "Close other tabs",
                MenuAction::CloseOtherRightPanelTabs(tab_idx),
            ));
            items.push(MenuItem::new(
                "Close all tabs",
                MenuAction::CloseAllRightPanelTabs,
            ));
        }
        // mouse-polish F-5 — give the active-tab right-click menu
        // something the × button doesn't already cover.
        items.push(MenuItem::new(
            "Hide side panel",
            MenuAction::Command("view.toggle_right_panel"),
        ));
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
        let mut items = vec![
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
                "Manage workspaces…",
                MenuAction::Command("view.manage_workspaces"),
            ),
        ];
        // qa-feature 2026-07-01 — "Remove workspace" only when there's
        // at least one extra to fall back on. If we removed the sole
        // primary, mnml would be left with no tree, no repos, and no
        // graceful state to recover to — better to hide the option
        // than crash into an empty rail.
        if !self.extra_workspaces.is_empty() {
            items.push(MenuItem::new(
                "Remove workspace",
                MenuAction::RemovePrimaryWorkspace,
            ));
        }
        items.push(MenuItem::new(
            "Reveal in Finder",
            MenuAction::RevealInFinder(self.workspace.clone()),
        ));
        items.push(MenuItem::new(
            "Refresh tree",
            MenuAction::Command("tree.refresh"),
        ));
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
        // qa-feature 2026-07-01 — "Set as workspace" now actually
        // promotes this row to primary (green dot moves, old
        // primary demotes into the freed slot). Previously fired
        // `SwitchToExtraWorkspace` which only EXPANDED the
        // section — the label lied. The picker-style expand-only
        // behavior stays reachable via "Expand this section"
        // below.
        let mut items = vec![];
        if let Some(p) = path.clone() {
            items.push(MenuItem::new(
                "Set as workspace",
                MenuAction::SetAsWorkspace(p),
            ));
        }
        items.push(MenuItem::new(
            "Expand this section",
            MenuAction::SwitchToExtraWorkspace(ws_idx + 1),
        ));
        // #polish 2026-07-06 — reorder without opening Manage.
        items.push(MenuItem::new(
            "Move up",
            MenuAction::ExtraWorkspaceMoveUp(ws_idx),
        ));
        items.push(MenuItem::new(
            "Move down",
            MenuAction::ExtraWorkspaceMoveDown(ws_idx),
        ));
        items.push(MenuItem::new(
            "Switch workspace…",
            MenuAction::Command("view.switch_workspace"),
        ));
        items.push(MenuItem::new(
            "Remove this workspace",
            MenuAction::Command("view.remove_workspace"),
        ));
        items.push(MenuItem::new(
            "Manage workspaces…",
            MenuAction::Command("view.manage_workspaces"),
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
        // vscode-mouse 2026-07-06 r2 SEV-2 — clipboard / undo ops
        // used to be missing from the editor right-click menu. VS
        // Code migrants land on this menu after making a selection
        // and expect Cut / Copy / Paste on top. Cut/Copy commands
        // handle the "no selection → operate on current line" case
        // at run-time.
        let mut items = vec![
            MenuItem::new("Cut", MenuAction::Command("editor.cut")),
            MenuItem::new("Copy", MenuAction::Command("editor.copy")),
            MenuItem::new("Paste", MenuAction::Command("editor.paste")),
            MenuItem::new("Undo", MenuAction::Command("editor.undo")),
            MenuItem::new("Redo", MenuAction::Command("editor.redo")),
            MenuItem::new("Select all", MenuAction::Command("editor.select_all")),
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
            "Manage workspaces…",
            MenuAction::Command("view.manage_workspaces"),
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
            OpenTerminal(dir) => {
                self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(dir)));
            }
            CopyPath(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast(format!("copied {text}"));
            }
            OpenCloudAgentRunDetail(idx) => {
                self.open_cloud_agent_run(idx);
            }
            SplitTabInto(src, zone) => {
                self.split_tab_into(src, zone);
            }
            StopManagedSession(session_id) => {
                let tx = self.cloud_run_msg_tx.clone();
                let sid = session_id.clone();
                std::thread::spawn(move || {
                    macro_rules! emit { ($($t:tt)*) => { let _ = tx.send(format!($($t)*)); }; }
                    let backend = match crate::anthropic_api::detect_backend() {
                        Ok(b) => b,
                        Err(e) => {
                            emit!("stop · backend: {e}");
                            return;
                        }
                    };
                    match crate::anthropic_api::stop_session(&backend, &sid) {
                        Ok(_) => {
                            emit!("session {sid} stop requested");
                        }
                        Err(e) => {
                            emit!("stop · {e}");
                        }
                    }
                });
                self.toast(format!("stopping {session_id}…"));
            }
            SetAsWorkspace(p) => {
                self.set_workspace_to(p);
            }
            TreeExpandRecursive(p) => {
                self.tree.expand_subtree(&p);
            }
            TreeCollapseRecursive(p) => {
                self.tree.collapse_subtree(&p);
            }
            RemovePrimaryWorkspace => {
                self.remove_primary_workspace();
            }
            EditIntegration(id) => {
                self.open_integration_edit_by_id(&id);
            }
            RemoveIntegration(id) => {
                self.remove_integration_by_id(&id);
            }
            ToggleIntegrationEnabled(id) => {
                if let Some(slot) = self
                    .config
                    .ui
                    .integration_icons
                    .iter_mut()
                    .find(|i| i.id == id)
                {
                    slot.enabled = !slot.enabled;
                    let now = slot.enabled;
                    self.toast(format!(
                        "integration {id} {}",
                        if now { "enabled" } else { "disabled" }
                    ));
                    let _ = crate::app::discovery::persist_integration_icons(
                        &self.config.ui.integration_icons,
                    );
                }
            }
            MoveIntegrationUp(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .position(|i| i.id == id)
                    && pos > 0
                {
                    self.config.ui.integration_icons.swap(pos, pos - 1);
                    self.toast(format!("moved {id} up"));
                    let _ = crate::app::discovery::persist_integration_icons(
                        &self.config.ui.integration_icons,
                    );
                }
            }
            MoveIntegrationDown(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .position(|i| i.id == id)
                    && pos + 1 < self.config.ui.integration_icons.len()
                {
                    self.config.ui.integration_icons.swap(pos, pos + 1);
                    self.toast(format!("moved {id} down"));
                    let _ = crate::app::discovery::persist_integration_icons(
                        &self.config.ui.integration_icons,
                    );
                }
            }
            MoveIntegrationToTop(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .position(|i| i.id == id)
                    && pos > 0
                {
                    let icon = self.config.ui.integration_icons.remove(pos);
                    self.config.ui.integration_icons.insert(0, icon);
                    self.toast(format!("moved {id} to top"));
                    let _ = crate::app::discovery::persist_integration_icons(
                        &self.config.ui.integration_icons,
                    );
                }
            }
            MoveIntegrationToBottom(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .position(|i| i.id == id)
                    && pos + 1 < self.config.ui.integration_icons.len()
                {
                    let icon = self.config.ui.integration_icons.remove(pos);
                    self.config.ui.integration_icons.push(icon);
                    self.toast(format!("moved {id} to bottom"));
                    let _ = crate::app::discovery::persist_integration_icons(
                        &self.config.ui.integration_icons,
                    );
                }
            }
            ToggleLauncherEnabled(id) => {
                if let Some(slot) = self
                    .config
                    .ui
                    .launcher_icons
                    .iter_mut()
                    .find(|i| i.id == id)
                {
                    slot.enabled = !slot.enabled;
                    let now = slot.enabled;
                    self.toast(format!(
                        "launcher {id} {}",
                        if now { "enabled" } else { "disabled" }
                    ));
                    // Persist via the launcher-icons writer. 2026-06-28
                    // fix for the prior TODO — was using the integrations
                    // path which silently dropped launcher toggles on
                    // restart.
                    let _ = crate::app::discovery::persist_launcher_icons(
                        &self.config.ui.launcher_icons,
                    );
                }
            }
            SetTopBarClusterMode(mode) => {
                self.config.ui.top_bar_cluster_mode = mode.to_string();
                let _ = crate::app::discovery::persist_top_bar_cluster_mode(mode);
                self.toast(format!("top-bar cluster: {mode}"));
            }
            Command(id) => {
                crate::command::run(id, self);
            }
            CloseTab(id) => self.close_pane(id),
            CloseOtherTabs(id) => self.close_panes_except(Some(id)),
            CloseAllTabs => self.close_panes_except(None),
            SetRightPanelTab(idx) => {
                if idx < self.right_panel_panes.len() {
                    self.right_panel_active_idx = idx;
                }
            }
            CloseOtherRightPanelTabs(keep_idx) => {
                // code-reviewer W-1 2026-06-29 SEV-2: close_pane
                // calls remove_pane_storage which SHIFTS every PaneId
                // above the removed slot down by 1 across the whole
                // arena. Iterating ascending closes the wrong pane on
                // the second iteration. Sort DESCENDING so each
                // close removes a slot above all remaining targets.
                let to_close: Vec<usize> = self
                    .right_panel_panes
                    .iter()
                    .enumerate()
                    .filter_map(|(i, &pid)| (i != keep_idx).then_some(pid))
                    .collect();
                // qa-8th crash SEV-2 2026-06-30 — same dirty-prompt
                // clobber bug as CloseAllRightPanelTabs. Partition
                // clean vs dirty: close clean immediately, prompt
                // for ONE dirty at a time.
                let (dirty, clean): (Vec<usize>, Vec<usize>) =
                    to_close.into_iter().partition(|&id| {
                        matches!(
                            self.panes.get(id),
                            Some(p) if p.is_dirty()
                        )
                    });
                let mut clean = clean;
                clean.sort_unstable_by(|a, b| b.cmp(a));
                for pid in clean {
                    self.force_close_pane(pid);
                }
                if let Some(&pid) = dirty.first() {
                    self.close_pane(pid);
                }
            }
            CloseAllRightPanelTabs => {
                // qa-8th crash SEV-2 2026-06-30 — was looping
                // close_pane on every pane, but close_pane stashes
                // dirty panes in the single close_prompt Option,
                // so the second dirty pane clobbered the first
                // before its dialog resolved. With N dirty panes,
                // N-1 were silently kept alive. Now: clean panes
                // close immediately via force_close_pane; dirty
                // panes pop ONE save/discard prompt first — the
                // user resolves it, and the close_prompt resolve
                // path can re-fire CloseAllRightPanelTabs if more
                // dirty panes remain. (Simpler than a queue: the
                // user clicks 'Close all' again or it cascades.)
                let to_close: Vec<usize> = self.right_panel_panes.clone();
                // Partition into clean + dirty (preserve original
                // order so the user sees prompts in panel order).
                let (dirty, clean): (Vec<usize>, Vec<usize>) =
                    to_close.into_iter().partition(|&id| {
                        matches!(
                            self.panes.get(id),
                            Some(p) if p.is_dirty()
                        )
                    });
                // Close clean panes first, descending so arena
                // shifts don't invalidate IDs.
                let mut clean = clean;
                clean.sort_unstable_by(|a, b| b.cmp(a));
                for pid in clean {
                    self.force_close_pane(pid);
                }
                // One dirty prompt at a time. The resolve handler
                // (close_prompt_resolve) leaves the user free to
                // re-fire 'Close all tabs' for the remaining ones.
                if let Some(&pid) = dirty.first() {
                    self.close_pane(pid);
                }
            }
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
            GitMergeBranchInto(name) => self.git_merge_branch(name),
            GitRebaseCurrentOnto(name) => self.git_rebase_onto(name),
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
            WorkspaceMoveUp(idx) => self.workspaces_editor_move_up(idx),
            WorkspaceMoveDown(idx) => self.workspaces_editor_move_down(idx),
            ExtraWorkspaceMoveUp(ws_idx) => self.move_extra_workspace(ws_idx, -1),
            ExtraWorkspaceMoveDown(ws_idx) => self.move_extra_workspace(ws_idx, 1),
            SwitchToExtraWorkspace(idx) => self.switch_workspace(idx),
            PreviewMarkdown(path) => self.open_md_preview_for_path(path, self.active, true),
            OpenUrl(url) => {
                open_url_external(&url);
                self.toast("opened in browser");
            }
            CopyText(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast("copied URL");
            }
            OpenCloudWatchPane {
                log_group,
                filter,
                label,
            } => {
                self.open_cloudwatch_pane(&log_group, &filter, &label);
            }
            OpenS3Pane {
                bucket,
                prefix,
                label,
            } => {
                self.open_s3_pane(&bucket, &prefix, &label);
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
