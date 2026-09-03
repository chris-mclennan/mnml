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
            // 2026-08-01 (P2) — LauncherIcon variant removed.
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
            // Task #915 (R5 SEV-2 F1/F2) — AI chip right-click menus.
            crate::HoverChip::StatuslineAiClaude => self
                .rects
                .statusline_ai_claude_chip
                .map(|rect| (crate::HoverChip::StatuslineAiClaude, above_anchor(rect))),
            crate::HoverChip::StatuslineAiCodex => self
                .rects
                .statusline_ai_codex_chip
                .map(|rect| (crate::HoverChip::StatuslineAiCodex, above_anchor(rect))),
            // Task #875 (R5 SEV-3 F8) — coverage chip right-click.
            crate::HoverChip::StatuslineCoverage => self
                .rects
                .statusline_coverage_chip
                .map(|rect| (crate::HoverChip::StatuslineCoverage, above_anchor(rect))),
            // #1102 (2026-08-20) — dynamic statusline segment
            // (manifest-declared + IPC-set). Anchor is the segment's
            // hit rect index into `statusline_segment_hits`.
            crate::HoverChip::StatuslineSegment(idx) => self
                .rects
                .statusline_segment_hits
                .get(*idx)
                .map(|(rect, _)| {
                    (
                        crate::HoverChip::StatuslineSegment(*idx),
                        above_anchor(*rect),
                    )
                }),
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
                crate::HoverChip::StatuslineAiClaude => {
                    self.open_statusline_ai_context_menu(anchor, false);
                }
                crate::HoverChip::StatuslineAiCodex => {
                    self.open_statusline_ai_context_menu(anchor, true);
                }
                crate::HoverChip::StatuslineCoverage => {
                    self.open_statusline_coverage_context_menu(anchor);
                }
                crate::HoverChip::StatuslineSegment(idx) => {
                    self.open_statusline_segment_context_menu(idx, anchor);
                }
                _ => {}
            }
            return;
        }
        if matches!(self.focus, crate::focus::Focus::Tree) {
            // vscode-user-keyboard 2026-07-30 KB-09 — was firing the
            // tree's file context menu regardless of active section,
            // so a Sessions/Debug/Notes user got the wrong menu based
            // on the stale tree cursor. Only route to the tree file
            // menu when Explorer is actually the active section.
            if !matches!(self.active_section, crate::app::ActivitySection::Explorer) {
                self.toast(format!(
                    "Shift+F10: no context menu for the {:?} section (yet)",
                    self.active_section
                ));
                return;
            }
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
                crate::HoverChip::ActivityBarGear => {
                    self.open_gear_context_menu(anchor);
                }
                _ => {}
            }
            return;
        }
        self.toast("no context menu at this focus");
    }

    /// Right-click menu for the statusline notification bell.
    ///
    /// The bell had no right-click menu at all — left-click opens the
    /// history and that was the whole surface. These are the things you
    /// want ABOUT notifications rather than FROM them, and each maps to
    /// an API that already existed with no way to reach it:
    /// `mark_messages_seen` was only a side effect of opening the log,
    /// and the log's text was only copyable one row at a time.
    pub fn open_notification_bell_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let unread = self.unread_message_count();
        let total = self.message_log.len();
        let mut items = vec![MenuItem::new(
            "Show history",
            MenuAction::Command("messages.show"),
        )];
        // Only offered when there IS something to clear — a "mark all
        // read" on a quiet bell is a button that does nothing.
        if unread > 0 {
            items.push(MenuItem::new(
                format!("Mark {unread} read"),
                MenuAction::MarkMessagesSeen,
            ));
        }
        if total > 0 {
            items.push(MenuItem::new(
                "Copy last message",
                MenuAction::CopyLastMessage,
            ));
            items.push(MenuItem::new(
                format!("Copy all ({total})"),
                MenuAction::CopyAllMessages,
            ));
        }
        self.context_menu = Some(ContextMenu::new(
            Some("Notifications".to_string()),
            anchor,
            items,
        ));
    }

    /// Right-click menu for a panel's ↻ chip: refresh now, and flip
    /// auto-refresh. Every panel that has a chip gets the same two
    /// rows, so the gesture means the same thing everywhere.
    pub fn open_refresh_chip_menu(&mut self, panel: &'static str, anchor: (u16, u16)) {
        let on = self.panel_auto_refresh(panel);
        let items = vec![
            crate::context_menu::MenuItem::new(
                "Refresh now",
                crate::context_menu::MenuAction::Command(match panel {
                    "todos" => "todos.refresh",
                    "notes" => "notes.refresh",
                    "findings" => "findings.refresh",
                    "sessions" => "sessions.refresh",
                    "agents" => "agents.refresh",
                    "cloud_agents" => "cloud.agents_refresh",
                    "git" => "git.refresh",
                    _ => "http.refresh",
                }),
            ),
            crate::context_menu::MenuItem::new(
                if on {
                    "Auto-refresh: on"
                } else {
                    "Auto-refresh: off"
                },
                crate::context_menu::MenuAction::TogglePanelAutoRefresh(panel.to_string()),
            ),
        ];
        // The sort rows used to be appended here, unlabelled, because
        // the refresh chip's menu was the only affordance the sort
        // had. It now has its own `sort:` chip whose right-click opens
        // a titled "Sort by" menu — so keeping them here left four
        // rows duplicated across two menus, under a chip that
        // advertises refreshing. Removed 2026-09-03 (design review).
        self.context_menu = Some(crate::context_menu::ContextMenu::new(
            Some(panel.to_uppercase()),
            anchor,
            items,
        ));
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
        let has_clipboard = !self.file_clipboard.is_empty();
        let items = if is_dir {
            let mut items = vec![
                MenuItem::new("Set as workspace", MenuAction::SetAsWorkspace(path.clone())),
                MenuItem::new(
                    "Open in file browser",
                    MenuAction::OpenFilesPane(path.clone()),
                ),
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
                MenuItem::new("Cut", MenuAction::FileCut(path.clone())),
                MenuItem::new("Copy", MenuAction::FileCopy(path.clone())),
            ];
            if has_clipboard {
                items.push(MenuItem::new(
                    "Paste here",
                    MenuAction::FilePaste(path.clone()),
                ));
            }
            items.extend([
                MenuItem::new("Duplicate", MenuAction::FileDuplicate(path.clone())),
                MenuItem::new("Move to…", MenuAction::FileMoveTo(path.clone())),
                MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
                MenuItem::destructive("Delete…", MenuAction::Delete(path.clone())),
                MenuItem::new(
                    crate::app::reveal_in_files_label(),
                    MenuAction::RevealInFinder(path.clone()),
                ),
                MenuItem::new("Open externally", MenuAction::OpenExternally(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
                MenuItem::new("Refresh tree", MenuAction::Command("tree.refresh")),
            ]);
            items
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
                MenuItem::new("Cut", MenuAction::FileCut(path.clone())),
                MenuItem::new("Copy", MenuAction::FileCopy(path.clone())),
            ]);
            if has_clipboard {
                items.push(MenuItem::new(
                    "Paste here",
                    MenuAction::FilePaste(path.clone()),
                ));
            }
            items.extend([
                MenuItem::new("Duplicate", MenuAction::FileDuplicate(path.clone())),
                MenuItem::new("Move to…", MenuAction::FileMoveTo(path.clone())),
                MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
                MenuItem::destructive("Delete…", MenuAction::Delete(path.clone())),
                MenuItem::new(
                    crate::app::reveal_in_files_label(),
                    MenuAction::RevealInFinder(path.clone()),
                ),
                MenuItem::new("Open externally", MenuAction::OpenExternally(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            ]);
            items
        };
        self.context_menu = Some(ContextMenu::new(Some(name), anchor, items));
    }

    /// Right-click on a `{{VAR}}` token in a Request pane → context
    /// menu (set value, jump to definition, copy name). Dynamic `$foo`
    /// tokens (uuid / timestamp / etc.) skip the "set value" entry
    /// since they're built-ins, not env-file backed. 2026-07-07.
    pub fn open_request_var_context_menu(&mut self, name: &str, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = format!("{{{{{name}}}}}");
        let is_dynamic = name.starts_with('$');
        let mut items = Vec::new();
        if !is_dynamic {
            items.push(MenuItem::new(
                "Set value…",
                MenuAction::SetEnvVarValue(name.to_string()),
            ));
        }
        items.push(MenuItem::new(
            "Jump to definition",
            MenuAction::JumpToEnvVar(name.to_string()),
        ));
        items.push(MenuItem::new(
            "Copy variable name",
            MenuAction::CopyPath(name.to_string()),
        ));
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on an integration chip → quick-actions menu.
    /// Lets the user edit the chip's glyph/color/tooltip in place
    /// or remove it without opening the discovery overlay first.
    /// `icon_idx` is the position in `config.ui.integration_icons`.
    /// Read the current per-workspace launcher override for a
    /// built-in integration (currently `claude_code` / `codex`).
    /// Returns None if the workspace has no override. Thin wrapper
    /// around `pty_pane::resolve_launcher` — one source of truth
    /// for the TOML scrape.
    /// True when this integration is pinned as a launcher icon in
    /// the activity bar. Powers the right-click menu's "Add" ↔
    /// "Remove" label switch. 2026-07-20.
    pub fn integration_is_docked(&self, id: &str) -> bool {
        self.config
            .ui
            .activity_bar_pinned_integrations
            .iter()
            .any(|pinned| pinned == id)
    }

    /// Right-click "Add to activity bar" — pushes the id into
    /// `config.ui.activity_bar_pinned_integrations` + persists.
    /// The activity bar renders a launcher icon; click fires the
    /// chip's `command` (spawns a Pty pane in the main area — NOT
    /// a docked side panel). 2026-07-20 user report: "I only
    /// wanted a fucking launcher icon in the activity bar" —
    /// this is the surface for that.
    pub fn add_integration_to_activity_bar(&mut self, id: &str) {
        if !self.config.ui.integration_icons.iter().any(|i| i.id == id) {
            self.toast(format!("integration {id} not found"));
            return;
        }
        if self.integration_is_docked(id) {
            self.toast(format!("'{id}' is already on the activity bar"));
            return;
        }
        self.config
            .ui
            .activity_bar_pinned_integrations
            .push(id.to_string());
        let _ = crate::app::discovery::persist_activity_bar_pinned_integrations(
            &self.config.ui.activity_bar_pinned_integrations,
        );
        self.toast(format!("pinned '{id}' to activity bar"));
    }

    /// Right-click "Remove from activity bar" — removes the id
    /// from the pinned list + persists. Sidebar chip is
    /// untouched.
    pub fn remove_integration_from_activity_bar(&mut self, id: &str) {
        let before = self.config.ui.activity_bar_pinned_integrations.len();
        self.config
            .ui
            .activity_bar_pinned_integrations
            .retain(|p| p != id);
        if self.config.ui.activity_bar_pinned_integrations.len() == before {
            self.toast(format!("'{id}' wasn't on the activity bar"));
            return;
        }
        let _ = crate::app::discovery::persist_activity_bar_pinned_integrations(
            &self.config.ui.activity_bar_pinned_integrations,
        );
        self.toast(format!("unpinned '{id}' from activity bar"));
    }

    /// #1203 — flat menu rows for the AI chips' launch profiles.
    /// Empty unless 2+ profiles resolve for this workspace (the
    /// builtin `default` counts as one, so any custom profile or
    /// legacy `launcher =` override activates the rows). One "New
    /// session: <name>" row per profile (fire-once, no state change)
    /// followed by one "Default: <name>" row per profile (persists
    /// `default_profile` to the workspace manifest; ✓ marks current).
    pub fn ai_profile_menu_items(&self, id: &str) -> Vec<crate::context_menu::MenuItem> {
        use crate::context_menu::{MenuAction, MenuItem};
        if id != "claude_code" && id != "codex" {
            return Vec::new();
        }
        let default_exe = if id == "codex" { "codex" } else { "claude" };
        let lp = crate::launch_profiles::LaunchProfiles::load(&self.workspace, id, default_exe);
        let mut items = Vec::new();
        if lp.profiles.len() >= 2 {
            for p in &lp.profiles {
                items.push(MenuItem::new(
                    format!("New session: {}", p.name),
                    MenuAction::OpenAiSessionWithProfile(id.to_string(), p.name.clone()),
                ));
            }
            for p in &lp.profiles {
                let mark = if p.name == lp.default_name {
                    "\u{2713} "
                } else {
                    "  "
                };
                items.push(MenuItem::new(
                    format!("{mark}Default: {}", p.name),
                    MenuAction::SetAiDefaultProfile(id.to_string(), p.name.clone()),
                ));
            }
        }
        // #1203 f/u — UI-managed profiles: create is always offered
        // (it's the discoverable entry into the whole feature);
        // remove rows appear per workspace-declared profile.
        items.push(MenuItem::new(
            "New launch profile\u{2026}",
            MenuAction::NewAiLaunchProfile(id.to_string()),
        ));
        for p in crate::launch_profiles::workspace_profiles(&self.workspace, id) {
            items.push(MenuItem::destructive(
                format!("Remove profile: {}", p.name),
                MenuAction::RemoveAiLaunchProfile(id.to_string(), p.name),
            ));
        }
        items
    }

    /// #1203 f/u — step 1 of "New launch profile…": ask for the name.
    pub fn open_launch_profile_name_prompt(&mut self, id: String) {
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::LaunchProfileName,
            format!("New `{id}` launch profile \u{2014} name (e.g. multi-repo)"),
            String::new(),
        );
        self.pending_launch_profile = Some((id, None));
        self.prompt = Some(prompt);
    }

    /// Accept for `LaunchProfileName` — stash the name, chain into
    /// the command prompt (seeded with the template prefix so
    /// workspace-relative wrappers are one path-completion away).
    pub fn accept_launch_profile_name(&mut self, input: String) {
        let Some((id, _)) = self.pending_launch_profile.take() else {
            return;
        };
        let name = input.trim().to_string();
        if name.is_empty() || name.contains('"') {
            self.toast("profile name must be non-empty, without double quotes");
            return;
        }
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::LaunchProfileCommand,
            format!("Command for `{name}` \u{2014} executable path ({{{{workspace}}}} expands)"),
            "{{workspace}}/".to_string(),
        );
        self.pending_launch_profile = Some((id, Some(name)));
        self.prompt = Some(prompt);
    }

    /// Accept for `LaunchProfileCommand` — write the profile into the
    /// workspace manifest; the chip menu shows its run/default rows
    /// from the next right-click.
    pub fn accept_launch_profile_command(&mut self, input: String) {
        let Some((id, Some(name))) = self.pending_launch_profile.take() else {
            return;
        };
        match crate::launch_profiles::add_profile(&self.workspace, &id, &name, input.trim()) {
            // The profile is written into the WORKSPACE manifest, which
            // an untrusted workspace doesn't contribute. Say so rather
            // than reporting plain success and leaving the user to
            // wonder why their profile never runs — mnml can't tell a
            // just-authored profile from one a cloned repo shipped, so
            // the gate has to apply either way.
            Ok(()) if !crate::workspace_trust::is_workspace_trusted(&self.workspace) => {
                self.toast(format!(
                    "profile `{name}` saved, but this workspace isn't trusted so it won't run \
                     \u{2014} `workspace.review_trust` to trust it"
                ))
            }
            Ok(()) => self.toast(format!(
                "profile `{name}` added \u{2014} right-click the {id} chip to run or set default"
            )),
            Err(e) => self.toast(format!("add profile: {e}")),
        }
    }

    pub fn integration_launcher_override(&self, id: &str) -> Option<String> {
        // resolve_launcher returns default_exe if no override; use
        // a sentinel we can compare against to detect that case.
        let sentinel = "__no_override__";
        let val = crate::pty_pane::resolve_launcher(&self.workspace, id, sentinel);
        if val == sentinel { None } else { Some(val) }
    }

    /// Open a `PromptKind::IntegrationLauncher` prompt seeded with
    /// the current override (if any) so the user can edit / clear.
    /// The id is stashed on `pending_integration_launcher_id` so
    /// the prompt-accept knows which manifest to write.
    pub fn open_integration_launcher_prompt(&mut self, id: String) {
        let seed = self.integration_launcher_override(&id).unwrap_or_default();
        let title = format!(
            "Launcher for `{id}` — path (empty = default `{}`)",
            if id == "codex" { "codex" } else { "claude" }
        );
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::IntegrationLauncher,
            title,
            seed,
        );
        self.pending_integration_launcher_id = Some(id);
        self.prompt = Some(prompt);
    }

    /// Accept handler for `PromptKind::IntegrationLauncher`. Writes
    /// (or clears) `launcher = "<input>"` in
    /// `<workspace>/.mnml/integrations/<id>.toml`.
    ///
    /// - Empty input → strip the `launcher` key. If it's the only
    ///   field, remove the file entirely (leaves no orphan manifest).
    /// - Non-empty input → write a minimal file containing just the
    ///   `launcher` line. This keeps the "built-in integration" path
    ///   clean — we're not overriding glyph/color/etc., just the
    ///   launcher.
    pub fn accept_integration_launcher(&mut self, input: String) {
        let Some(id) = self.pending_integration_launcher_id.take() else {
            return;
        };
        let dir = self.workspace.join(".mnml").join("integrations");
        let path = dir.join(format!("{id}.toml"));
        let trimmed = input.trim();
        if trimmed.is_empty() {
            let _ = std::fs::remove_file(&path);
            self.toast(format!("launcher for `{id}` cleared (using default)"));
            return;
        }
        if let Err(e) = std::fs::create_dir_all(&dir) {
            self.toast(format!("mkdir {}: {e}", dir.display()));
            return;
        }
        let contents = format!(
            "# Workspace-scoped override for the `{id}` integration.\n\
             # Rewritten by mnml's \"Set launcher script…\" menu — hand-edit\n\
             # is fine too.\n\
             launcher = \"{trimmed}\"\n"
        );
        match std::fs::write(&path, contents) {
            Ok(()) => self.toast(format!("launcher for `{id}` → {trimmed}")),
            Err(e) => self.toast(format!("write {}: {e}", path.display())),
        }
    }

    pub fn open_integration_chip_context_menu(&mut self, icon_idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(icon) = self.config.ui.integration_icons.get(icon_idx) else {
            return;
        };
        let title = icon
            .label
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
        // 2026-08-06 — palette-bar visibility toggle. `enabled = true`
        // controls the RAIL chip + palette command availability;
        // `in_palette_bar = true` controls whether the chip also
        // renders in the top-right cluster. Both default to true on
        // enable; this menu item lets the user hide from the top bar
        // without disabling the whole integration.
        if icon.enabled {
            let palette_label = if icon.in_palette_bar {
                "Hide from top bar"
            } else {
                "Show on top bar"
            };
            items.push(MenuItem::new(
                palette_label,
                MenuAction::ToggleIntegrationPaletteBar(id.clone()),
            ));
        }
        // 2026-07-31 — Open the read-only detail pane. Sits above
        // Move / Edit / Remove so the discoverability path from
        // "right-click a chip → what is this thing?" is one hop.
        items.push(MenuItem::new(
            "View details",
            MenuAction::ShowIntegrationDetails(id.clone()),
        ));
        // #1054 (2026-08-19) — icon ids (`jira_work`, `jira_boards`)
        // aren't marketplace / update-cache keys; those are keyed by
        // CRATE id (`mnml-tracker-jira`). Resolve to the underlying
        // binary via the same helper the dedup path uses, so both
        // "Update to X" and "Show in marketplace" hit the right row.
        // Falls back to the icon id when the command isn't a
        // `:term <binary>` form (built-ins, ex commands, etc.).
        let crate_id = crate::integration_detect::integration_binary_for_command(&icon.command)
            .map(|s| s.to_string())
            .unwrap_or_else(|| id.clone());
        // #992 (2026-08-18) — "Update to <latest>" when an update
        // check reports one. Rendered above "Show in marketplace" so
        // an actionable item is the first thing a user reaching for
        // an update lands on. Live-lookup — mutex is held briefly.
        if let Ok(guard) = self.integration_updates.lock()
            && let Some(check) = guard.get(&crate_id)
            && crate::app::integration_updates::is_update_available(check)
        {
            items.push(MenuItem::new(
                format!("\u{2191} Update to {}", check.latest),
                MenuAction::UpdateIntegration(crate_id.clone()),
            ));
        }
        // #992 (2026-08-18) — always available: jump to the
        // integration's row inside the activity-bar Marketplace tab.
        // Filters the panel by the id so the row surfaces regardless
        // of tab order.
        items.push(MenuItem::new(
            "Show in marketplace",
            MenuAction::ShowIntegrationInMarketplace(crate_id.clone()),
        ));
        // #1088 (2026-08-19) — per-integration auto-update opt-in.
        // Resolve the current effective flag from any existing
        // override file so the label reflects the actual state.
        // Toggle writes to `<crate_id>.override.toml`.
        //
        // #1109 (2026-08-20): the write path uses `crate_id` (binary
        // basename) as the file key, so the read side must match on
        // manifest.binary basename OR manifest.id. Matching purely on
        // manifest.id was stale for multi-manifest crates (e.g. every
        // Jira icon shares binary `mnml-tracker-jira` but has its own
        // manifest.id like `jira_work`) — the override was written,
        // silently dropped in the merge, and this lookup returned
        // false, showing the toggle as OFF right after the toast said
        // it flipped ON.
        let auto_update_on = self
            .integration_manifests
            .iter()
            .find(|m| {
                m.id == id
                    || m.binary
                        .as_deref()
                        .map(|b| b.rsplit('/').next().unwrap_or(b) == crate_id)
                        .unwrap_or(false)
            })
            .and_then(|m| m.auto_update_override)
            .unwrap_or(false);
        let auto_update_label = if auto_update_on {
            "Auto-update: \u{25CF} on"
        } else {
            "Auto-update: \u{25CB} off"
        };
        items.push(MenuItem::new(
            auto_update_label,
            MenuAction::SetIntegrationAutoUpdate(crate_id.clone(), !auto_update_on),
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
        // #1229 (user ask) — env-grouped bookmarks on the browser chip:
        // "right click it and shoose from list of defined sites by env".
        //
        // One row per env, each opening a fuzzy picker, because the
        // context menu has no submenus and the user expects this list to
        // grow ("probably more coming"). A flat twelve-row menu would not
        // survive that; a picker does, and brings search with it.
        //
        // Rows appear only when bookmarks exist, so a user who has never
        // written the file sees no dead entries. The palette command
        // `bookmarks.open` names the file path when the list is empty.
        if id == "browser" {
            let marks = crate::bookmarks::load(&self.workspace);
            if !marks.is_empty() {
                for env in crate::bookmarks::envs(&marks) {
                    let n = crate::bookmarks::in_env(&marks, &env).len();
                    items.push(MenuItem::new(
                        format!("{env} ({n})\u{2026}"),
                        MenuAction::OpenBookmarks(Some(env.clone())),
                    ));
                }
                if crate::bookmarks::envs(&marks).len() > 1 {
                    items.push(MenuItem::new(
                        "All bookmarks\u{2026}",
                        MenuAction::OpenBookmarks(None),
                    ));
                }
            }
        }
        // Phase 2B (task #892) — surface "Configure…" only when the
        // integration declares [[auth]] fields. Opens the per-
        // integration Settings pane with a form of those fields.
        let has_auth = self
            .integration_manifests
            .iter()
            .any(|m| m.id == id && !m.auth.is_empty());
        if has_auth {
            items.push(MenuItem::new(
                "Configure…",
                MenuAction::ConfigureIntegration(id.clone()),
            ));
        }
        // #1103 f/u7 (2026-08-20) — "Run diagnostics" surfaces on
        // every integration whose manifest declares a binary. Runs
        // `<binary> --diag` in a Pty pane; the human-readable
        // output covers auth resolution + config summary + a live
        // auth probe. Universal debugging entry point.
        let has_binary = self
            .integration_manifests
            .iter()
            .any(|m| m.id == id && m.binary.is_some());
        if has_binary {
            items.push(MenuItem::new(
                "Run diagnostics",
                MenuAction::RunIntegrationDiag(id.clone()),
            ));
        }
        // v0.2.0 — per-workspace launcher-script override for
        // integrations that spawn a binary. Only surfaced on
        // built-ins where mnml chooses the exe (claude_code /
        // codex); integration integrations already control their own
        // spawn via `binary = "..."` in the manifest, so the
        // wrapper isn't useful for them.
        if id == "claude_code" || id == "codex" {
            // #1203 — launch-profile rows (pick one session's
            // launcher on the fly / persist a default) sit above the
            // legacy single-override prompt.
            items.extend(self.ai_profile_menu_items(&id));
            let label = match self.integration_launcher_override(&id) {
                Some(current) => format!("Set launcher script… (current: {current})"),
                None => "Set launcher script…".to_string(),
            };
            items.push(MenuItem::new(
                label,
                MenuAction::SetIntegrationLauncher(id.clone()),
            ));
        }
        // 2026-07-20 — promote/demote to activity bar. Chips whose
        // command is `:term <binary> [args…]` can back a Mount
        // pane (docked activity-bar icon). Chips wired to a mnml
        // command (e.g. `browser.open`) can't dock; we skip the
        // menu item to avoid a click-does-nothing surface.
        let can_dock = icon.command.starts_with(":term ") || icon.command.starts_with("term ");
        if can_dock {
            if self.integration_is_docked(&id) {
                items.push(MenuItem::new(
                    "Remove from activity bar",
                    MenuAction::RemoveIntegrationFromActivityBar(id.clone()),
                ));
            } else {
                items.push(MenuItem::new(
                    "Add to activity bar",
                    MenuAction::AddIntegrationToActivityBar(id.clone()),
                ));
            }
        }
        // 2026-07-09 user request — more integration-management
        // gestures in the right-click menu. Copy id + open the
        // manifest live above Remove so a mis-click is more likely
        // to land on the harmless action.
        items.push(MenuItem::new(
            "Copy id",
            MenuAction::CopyIntegrationId(id.clone()),
        ));
        items.push(MenuItem::new(
            "Show manifest…",
            MenuAction::ShowIntegrationManifest(id.clone()),
        ));
        // 2026-07-19 user request — Bake glyph directly from the
        // integration chip. Opens the glyph builder pre-loaded at
        // this chip's current codepoint (works for BUILTIN_GLYPHS
        // entries + user-baked custom glyphs). Nerd Font glyphs
        // land on a fresh mnml PUA codepoint per the builder's
        // standard behavior.
        if let Some(cp) = self
            .config
            .ui
            .integration_icons
            .get(icon_idx)
            .and_then(|i| i.glyph.chars().next())
            .map(|c| c as u32)
        {
            items.push(MenuItem::new(
                "Bake / tune glyph…",
                MenuAction::OpenGlyphBuilderForCp(cp),
            ));
            // #814 — one-tap rebake. Uses the last-baked meta (or
            // the builtin catalog fallback) verbatim; no visual
            // builder. Handy after editing a builtin SVG on disk.
            //
            // Tester-round SEV-3 fix — only offer when there IS
            // something to rebake. Nerd Font codicons (e.g. the
            // default `browser` chip at U+EB01) have no builtin
            // catalog entry AND no meta entry until the user has
            // opened the visual builder at least once; showing
            // "Rebake glyph now" for those was a dead-end that
            // toasted "no stored meta or builtin".
            let cp_hex = format!("{cp:04X}");
            let has_meta = crate::glyph_builder::load_meta()
                .glyphs
                .iter()
                .any(|g| g.codepoint == cp_hex);
            let has_builtin = crate::glyph_builder::builtin_for_codepoint(cp).is_some();
            if has_meta || has_builtin {
                items.push(MenuItem::new(
                    "Rebake glyph now",
                    MenuAction::RebakeGlyphForCp(cp),
                ));
            }
        }
        // 2026-08-06 — renamed "Remove" → "Uninstall". User asked
        // whether "remove" matched what the action does; it deletes
        // the manifest + codepoint + rail entry + SVG on disk,
        // which is a proper uninstall. Own function name
        // `remove_integration_by_id` stays; only the label changes.
        items.push(MenuItem::new(
            "Uninstall",
            MenuAction::RemoveIntegration(id),
        ));
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

    // 2026-08-01 (P2) — open_launcher_chip_context_menu deleted
    // with the LauncherIcon retirement. Chip context menus route
    // through open_integration_chip_context_menu.

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
        // #polish 2026-07-06 — "Set as default" label reflects
        // whether THIS workspace is already the persisted default
        // (`[startup] default_workspace` in the global config).
        let is_default = self
            .config
            .default_workspace
            .as_deref()
            .and_then(|p| std::fs::canonicalize(p).ok())
            .as_deref()
            == std::fs::canonicalize(&self.workspace).ok().as_deref();
        let set_default_label = if is_default {
            "Unset as default workspace"
        } else {
            "Set as default workspace"
        };
        // 2026-07-12 user request — recursive expand / collapse
        // were only on individual dir-row menus; the workspace
        // header should get them too since it IS a directory (the
        // top one). Cheap since the same MenuAction fires.
        let ws_root = self.workspace.clone();
        let mut items = vec![
            MenuItem::new(
                "Toggle expand",
                MenuAction::Command("view.toggle_tree_section"),
            ),
            MenuItem::new(
                "Expand recursively",
                MenuAction::TreeExpandRecursive(ws_root.clone()),
            ),
            MenuItem::new(
                "Collapse recursively",
                MenuAction::TreeCollapseRecursive(ws_root),
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
            MenuItem::new(set_default_label, MenuAction::SetDefaultWorkspace),
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
            crate::app::reveal_in_files_label(),
            MenuAction::RevealInFinder(self.workspace.clone()),
        ));
        items.push(MenuItem::new(
            "Refresh tree",
            MenuAction::Command("tree.refresh"),
        ));
        // 2026-07-19 user request — Collapse all / Expand all at
        // the workspace root menu. Same palette commands the
        // keyboard nav uses.
        items.push(MenuItem::new(
            "Collapse all",
            MenuAction::Command("tree.collapse_all"),
        ));
        items.push(MenuItem::new(
            "Expand all",
            MenuAction::Command("tree.expand_all"),
        ));
        // 2026-08-09 — audit Tier-1 #4: right-click discovery for
        // `view.toggle_workspace_dots`. Palette + menu-bar + `:set
        // wsdots` were shipped in e230a6bf; this is the mouse path
        // some users prefer since they're already right-clicking the
        // workspace row when they choose "Set as workspace".
        let dot_label = if self.config.ui.show_workspace_dots {
            "Hide workspace dots (● / ○)"
        } else {
            "Show workspace dots (● / ○)"
        };
        items.push(MenuItem::new(
            dot_label,
            MenuAction::Command("view.toggle_workspace_dots"),
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
                MenuAction::SetAsWorkspace(p.clone()),
            ));
            // #polish 2026-07-06 — persist as `[startup] default_workspace`
            // in the global config so mnml opens here next launch.
            let default_canon = self
                .config
                .default_workspace
                .as_deref()
                .and_then(|p| std::fs::canonicalize(p).ok());
            let this_canon = std::fs::canonicalize(&p).ok();
            let is_default = this_canon.is_some() && this_canon == default_canon;
            let label = if is_default {
                "Unset as default workspace"
            } else {
                "Set as default workspace"
            };
            items.push(MenuItem::new(label, MenuAction::SetDefaultWorkspaceAt(p)));
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
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(p),
            ));
        }
        items.push(MenuItem::new(
            "Refresh tree",
            MenuAction::Command("tree.refresh"),
        ));
        // 2026-07-19 user re-report — Collapse all / Expand all
        // also here on extra-workspace headers. Previous fix added
        // it only to the primary workspace header
        // (`open_workspace_header_context_menu`); the user was
        // right-clicking `mnml` which is one of their extra
        // workspaces and the menu didn't include them. Both
        // menus now match.
        items.push(MenuItem::new(
            "Collapse all",
            MenuAction::Command("tree.collapse_all"),
        ));
        items.push(MenuItem::new(
            "Expand all",
            MenuAction::Command("tree.expand_all"),
        ));
        // 2026-08-09 — audit Tier-1 #4 (extra-workspace-header
        // variant): match the primary workspace's dot-toggle entry so
        // right-clicking any workspace row surfaces the same control.
        let dot_label = if self.config.ui.show_workspace_dots {
            "Hide workspace dots (● / ○)"
        } else {
            "Show workspace dots (● / ○)"
        };
        items.push(MenuItem::new(
            dot_label,
            MenuAction::Command("view.toggle_workspace_dots"),
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
            // #980 (2026-08-18) — talk-to-Claude entry points. The
            // commands themselves have existed since the ai.* group
            // shipped (leader ae = explain, aa = ask); this menu was
            // the missing surface for mouse users. `ai.explain`
            // operates on the current selection if there is one, else
            // the whole file — matches the LSP/edit ops above.
            MenuItem::new("Explain with Claude", MenuAction::Command("ai.explain")),
            MenuItem::new("Ask Claude…", MenuAction::Command("ai.ask")),
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
            // mouse-round-9 SEV-2 2026-07-11 — terminal-native ops
            // at the top (users expect these first from a pty
            // right-click).
            MenuItem::new("Paste", MenuAction::Command("term.paste")),
            MenuItem::new("Clear (Ctrl+L)", MenuAction::Command("term.clear")),
            MenuItem::new("Restart (Ctrl+C)", MenuAction::Command("term.restart")),
            MenuItem::new("Dock left", MenuAction::Command("view.move_split_left")),
            MenuItem::new("Dock right", MenuAction::Command("view.move_split_right")),
            MenuItem::new("Dock top", MenuAction::Command("view.move_split_up")),
            MenuItem::new("Dock bottom", MenuAction::Command("view.move_split_down")),
            MenuItem::new("Maximize width", MenuAction::Command("view.maximize_width")),
            MenuItem::new(
                "Maximize height",
                MenuAction::Command("view.maximize_height"),
            ),
            MenuItem::new("Full screen", MenuAction::Command("view.fullscreen")),
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
            crate::app::reveal_in_files_label(),
            MenuAction::RevealInFinder(self.active_repo_path().to_path_buf()),
        ));
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on the statusline diagnostics chip — jump to
    /// next / prev / show all. design-critic round-3 #6 2026-07-11.
    pub fn open_statusline_diagnostics_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Next problem", MenuAction::Command("lsp.next_diagnostic")),
            MenuItem::new(
                "Previous problem",
                MenuAction::Command("lsp.prev_diagnostic"),
            ),
            MenuItem::new("Show all in panel", MenuAction::Command("lsp.diagnostics")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Problems".into()), anchor, items));
    }

    /// Right-click on the language chip — override / copy language.
    pub fn open_statusline_language_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let lang = self
            .active_editor()
            .and_then(|b| b.language_ext.clone())
            .unwrap_or_else(|| "—".to_string());
        let items = vec![MenuItem::new(
            "Copy language name",
            MenuAction::CopyPath(lang.clone()),
        )];
        self.context_menu = Some(ContextMenu::new(
            Some(format!("Language: {lang}")),
            anchor,
            items,
        ));
    }

    /// Right-click on the lncol chip — go-to-line / copy pos.
    pub fn open_statusline_lncol_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let pos = self
            .active_editor()
            .map(|b| {
                let (r, c) = b.editor.row_col();
                format!("{}:{}", r + 1, c + 1)
            })
            .unwrap_or_default();
        let items = vec![
            MenuItem::new("Go to line…", MenuAction::Command("editor.goto_line")),
            MenuItem::new(format!("Copy position ({pos})"), MenuAction::CopyPath(pos)),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Cursor".into()), anchor, items));
    }

    /// Right-click on the find chip — repeat / clear / open prompt.
    pub fn open_statusline_find_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Next match", MenuAction::Command("find.next")),
            MenuItem::new("Previous match", MenuAction::Command("find.prev")),
            MenuItem::new("Clear (`:noh`)", MenuAction::Command("find.clear")),
            MenuItem::new("Open find prompt…", MenuAction::Command("find.find")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Find".into()), anchor, items));
    }

    /// Right-click on the sel chip — copy / cut.
    pub fn open_statusline_sel_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Copy selection", MenuAction::Command("editor.copy")),
            MenuItem::new("Cut selection", MenuAction::Command("editor.cut")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Selection".into()), anchor, items));
    }

    /// Right-click on the filesize chip — copy bytes / open in OS.
    pub fn open_statusline_filesize_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let (size_bytes, path) = match self.active_editor() {
            Some(b) => (
                b.editor.text().len(),
                b.path.as_ref().map(|p| p.display().to_string()),
            ),
            None => (0, None),
        };
        let mut items = vec![MenuItem::new(
            format!("Copy size ({size_bytes} B)"),
            MenuAction::CopyPath(size_bytes.to_string()),
        )];
        if let Some(p) = path {
            items.push(MenuItem::new(
                "Open in system app",
                MenuAction::OpenExternally(p.into()),
            ));
        }
        self.context_menu = Some(ContextMenu::new(Some("Size".into()), anchor, items));
    }

    /// Right-click on an HTTP-panel section header (COLLECTIONS /
    /// FILES / ENVS / CHAINS / MOCKS / RECENT / CAPTURED). Offers
    /// the section-level verbs the individual-row menus miss.
    /// Left-click already toggles the specific section, so the
    /// menu focuses on "what else can I do with this whole group?".
    /// mouse-round-11 SEV-2 2026-07-12.
    pub fn open_http_panel_section_context_menu(&mut self, section: u8, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let (title, mut items): (&str, Vec<MenuItem>) = match section {
            0 => (
                "FILES",
                vec![MenuItem::new(
                    "New request…",
                    MenuAction::Command("http.new_request"),
                )],
            ),
            1 => (
                "RECENT",
                vec![MenuItem::new(
                    "Clear recent history",
                    MenuAction::Command("http.clear_recent"),
                )],
            ),
            2 => (
                "CAPTURED",
                vec![
                    MenuItem::new("Start capture", MenuAction::Command("http.capture_start")),
                    MenuItem::new("Clear captured", MenuAction::Command("http.clear_captured")),
                ],
            ),
            3 => (
                "ENVS",
                vec![MenuItem::new(
                    "New env…",
                    MenuAction::Command("http.new_env"),
                )],
            ),
            4 => (
                "CHAINS",
                vec![MenuItem::new(
                    "New chain…",
                    MenuAction::Command("http.new_chain"),
                )],
            ),
            // design-round-4 issue 9 2026-07-14 — MOCKS was the only
            // section of 7 with no section-specific verb, which read
            // like "the menu is broken" after the other 6 sections
            // taught the user "section header → section verbs." Mocks
            // can't be created from scratch (they're derived from
            // captured/live responses via http.save_mock on a request
            // pane), but surfacing the save/replay pair here at least
            // shows the mock lifecycle exists.
            5 => (
                "MOCKS",
                vec![
                    MenuItem::new(
                        "Save active response as mock",
                        MenuAction::Command("http.save_mock"),
                    ),
                    MenuItem::new(
                        "Replay mock into active request",
                        MenuAction::Command("http.replay_mock"),
                    ),
                ],
            ),
            6 => (
                "COLLECTIONS",
                vec![MenuItem::new(
                    "New collection…",
                    MenuAction::Command("http.new_collection"),
                )],
            ),
            _ => ("HTTP", vec![]),
        };
        items.push(MenuItem::new(
            "Toggle all sections",
            MenuAction::Command("http.toggle_collapse_all"),
        ));
        items.push(MenuItem::new(
            "Refresh HTTP panel",
            MenuAction::Command("http.refresh"),
        ));
        self.context_menu = Some(ContextMenu::new(Some(title.into()), anchor, items));
    }

    /// Right-click on the bufferline `+` new-tab button. Offers
    /// alternate new-tab flows (blank / recent / reopen closed).
    /// mouse-round-10 SEV-3 2026-07-12 — the mouse-discoverable
    /// path to Ctrl+Shift+T.
    pub fn open_new_tab_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("New blank tab", MenuAction::Command("tab.new")),
            MenuItem::new("Reopen last closed", MenuAction::Command("buffer.reopen")),
            MenuItem::new("Open recent…", MenuAction::Command("picker.recent")),
            MenuItem::new("Open file…", MenuAction::Command("picker.files")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("New tab".into()), anchor, items));
    }

    /// Right-click on a specific toast box. Offers dismiss for this
    /// one, dismiss-all, and (for the Undo case) commit. Index is
    /// into `App.toast_stack`. mouse-round-10 SEV-2 2026-07-12.
    /// mouse-round-11 SEV-3 2026-07-12 — bail if the toast has
    /// already expired instead of opening a `Toast: (gone)` menu.
    pub fn open_toast_context_menu(&mut self, idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(full_text) = self.toast_stack.get(idx).map(|e| e.text.clone()) else {
            return;
        };
        let text: String = {
            let t = full_text.chars().take(40).collect::<String>();
            if full_text.chars().count() > 40 {
                format!("{t}…")
            } else {
                t
            }
        };
        // Stash target index so the "dismiss" MenuAction knows
        // which toast it belongs to. `App.pending_toast_dismiss_idx`
        // is single-slot — the menu closes on any action so races
        // aren't possible.
        self.pending_toast_dismiss_idx = Some(idx);
        let items = vec![
            MenuItem::new(format!("Toast: {text}"), MenuAction::Command("noop.info")),
            MenuItem::new(
                "Dismiss this toast",
                MenuAction::Command("toast.dismiss_current"),
            ),
            MenuItem::new(
                "Dismiss all toasts",
                MenuAction::Command("toast.dismiss_all"),
            ),
            MenuItem::new("Copy text to clipboard", MenuAction::CopyPath(full_text)),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Toast".into()), anchor, items));
    }

    /// Right-click on the stress meter (either the statusline or
    /// top-right variant). Shows current numbers, a reset action,
    /// and a copy-summary action so users can drop the stats into
    /// an issue report. 2026-07-12 user request.
    pub fn open_stress_meter_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let score = self.stress_score();
        let mut sorted: Vec<u16> = self.frame_times_ms.iter().copied().collect();
        sorted.sort_unstable();
        let (p50, p95, max) = if sorted.is_empty() {
            (0, 0, 0)
        } else {
            (
                sorted[sorted.len() / 2],
                sorted[(sorted.len() * 95) / 100],
                sorted.last().copied().unwrap_or(0),
            )
        };
        let sample_count = self.frame_times_ms.len();
        let summary = format!(
            "stress {score}/100 · p50 {p50}ms · p95 {p95}ms · max {max}ms · {sample_count} samples"
        );
        let items = vec![
            MenuItem::new(
                format!("Score: {score}/100"),
                MenuAction::Command("noop.info"),
            ),
            MenuItem::new(
                format!("p50 {p50}ms · p95 {p95}ms · max {max}ms"),
                MenuAction::Command("noop.info"),
            ),
            MenuItem::new(
                "Reset the frame-time window",
                MenuAction::Command("perf.reset_stress"),
            ),
            MenuItem::new(
                "Copy the summary to clipboard",
                MenuAction::CopyPath(summary),
            ),
            MenuItem::new(
                "Toast the current numbers",
                MenuAction::Command("perf.toast_stress"),
            ),
            MenuItem::new(
                "Hide the stress meter",
                MenuAction::Command("perf.hide_stress"),
            ),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Stress meter".into()), anchor, items));
    }

    /// Right-click on the palette bar's back/forward buttons — lists
    /// the buffer MRU (top of stack), plus "Clear MRU". `forward` picks
    /// the direction to bias toward. mouse-round-9 SEV-3 2026-07-11.
    pub fn open_palette_nav_context_menu(&mut self, forward: bool, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = if forward { "Nav Forward" } else { "Nav Back" };
        let ws = self.workspace.clone();
        // Show up to 8 most-recent panes with their names.
        let entries: Vec<(usize, String)> = self
            .pane_mru
            .iter()
            .filter_map(|&pid| {
                let p = self.panes.get(pid)?;
                let label = match p {
                    crate::pane::Pane::Editor(b) => b
                        .path
                        .as_ref()
                        .map(|pp| crate::app::rel_path(&ws, pp))
                        .unwrap_or_else(|| b.display_name().to_string()),
                    other => other.title().to_string(),
                };
                Some((pid, label))
            })
            .take(8)
            .collect();
        let mut items: Vec<MenuItem> = Vec::new();
        if entries.is_empty() {
            // Nothing to navigate; skip the disabled row and just show
            // the Clear entry below.
        } else {
            for (_pid, label) in &entries {
                items.push(MenuItem::new(
                    label.clone(),
                    MenuAction::Command(if forward {
                        "buffer.next"
                    } else {
                        "buffer.prev"
                    }),
                ));
            }
        }
        items.push(MenuItem::new(
            "Clear buffer MRU",
            MenuAction::Command("buffer.clear_mru"),
        ));
        self.context_menu = Some(ContextMenu::new(Some(title.into()), anchor, items));
    }

    /// Right-click on the statusline PR chip — offers copy URL /
    /// number / open in browser. design-critic round-3 #6 2026-07-11.
    pub fn open_statusline_pr_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(pr) = self
            .git_rail
            .pulls
            .iter()
            .find(|p| p.is_current_branch)
            .cloned()
        else {
            self.toast("no PR for this branch");
            return;
        };
        let items = vec![
            MenuItem::new(
                "Open in browser",
                MenuAction::OpenExternally(pr.web_url.clone().into()),
            ),
            MenuItem::new("Copy URL", MenuAction::CopyPath(pr.web_url.clone())),
            MenuItem::new("Copy number", MenuAction::CopyPath(pr.number_label.clone())),
        ];
        self.context_menu = Some(ContextMenu::new(
            Some(format!("PR {}", pr.number_label)),
            anchor,
            items,
        ));
    }

    /// Right-click on the statusline file chip — buffer-scoped menu
    /// promised by `HoverChip::StatuslineFile`'s tooltip.
    /// design-critic round-3 finding #3 2026-07-11.
    pub fn open_statusline_file_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
            self.toast("no saved file");
            return;
        };
        let ws = self.workspace.clone();
        let abs = path.to_string_lossy().into_owned();
        let rel = crate::app::rel_path(&ws, &path);
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut items = vec![
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path (absolute)", MenuAction::CopyPath(abs)),
            MenuItem::new("Copy path (relative)", MenuAction::CopyPath(rel)),
        ];
        if !name.is_empty() {
            items.push(MenuItem::new("Copy filename", MenuAction::CopyPath(name)));
        }
        items.push(MenuItem::new(
            "Close buffer",
            MenuAction::Command("buffer.close"),
        ));
        self.context_menu = Some(ContextMenu::new(Some("Buffer".into()), anchor, items));
    }

    /// Right-click on the statusline mode chip — exposes the input-style
    /// switcher. design-critic-round-5 SEV-3 2026-07-12 — mark the
    /// currently-active input style with the `✓ ` prefix used by
    /// the top-bar-cluster menu, so users can tell at a glance
    /// which mode is on without reading the mode chip itself.
    pub fn open_statusline_mode_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let is_vim = self.config.editor.input_style == "vim";
        let vim_label = if is_vim { "✓ Use vim" } else { "  Use vim" };
        let std_label = if !is_vim {
            "✓ Use standard"
        } else {
            "  Use standard"
        };
        let items = vec![
            MenuItem::new(vim_label, MenuAction::Command("editor.use_vim")),
            MenuItem::new(std_label, MenuAction::Command("editor.use_standard")),
            MenuItem::new(
                "  Toggle keymap",
                MenuAction::Command("editor.toggle_keymap"),
            ),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Input style".into()), anchor, items));
    }

    /// Task #875 (R5 SEV-3 F8) — Right-click on the statusline
    /// coverage chip. The built-in Coverage pane was removed; this
    /// now opens the coverage integration Pty pane (provided by
    /// `mnml-tattle-coverage`). Refresh lives inside that pane
    /// (`r` reflex), so only one menu row remains.
    pub fn open_statusline_coverage_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // 2026-08-16 — show-mode filter. Current mode determines which
        // row shows the ✓ check. Each choice dispatches a registered
        // command that flips `[ui] coverage_chip_mode` in persisted
        // config and re-triggers a chip render.
        let mode = &self.config.ui.coverage_chip_mode;
        let checkmark = |on: bool| if on { "✓ " } else { "  " };
        // The chip's LEFT-click checks this integration is installed
        // before firing, and its fallback toast says "right-click for
        // options" — which pointed the user straight at this row, which
        // did not check, and answered `no such command`. Guard it the
        // same way; when it is absent the row says so instead of
        // pretending to work.
        let cov_id = "tattle_coverage_ext.open";
        let cov_installed = crate::command::registry().get(cov_id).is_some()
            || self.dynamic_commands.iter().any(|c| c.id == cov_id);
        let items = vec![
            if cov_installed {
                MenuItem::new("Open coverage pane", MenuAction::Command(cov_id))
            } else {
                MenuItem::new(
                    "Coverage integration not installed",
                    MenuAction::Command("integrations.show_marketplace"),
                )
            },
            MenuItem::new(
                format!("{}Show both (F + C)", checkmark(mode == "both")),
                MenuAction::Command("coverage.chip_show_both"),
            ),
            MenuItem::new(
                format!("{}Show Feature only", checkmark(mode == "feature")),
                MenuAction::Command("coverage.chip_show_feature"),
            ),
            MenuItem::new(
                format!("{}Show Code only", checkmark(mode == "code")),
                MenuAction::Command("coverage.chip_show_code"),
            ),
            MenuItem::new(
                format!(
                    "{}Ticker (cycle F ↔ C every 4s)",
                    checkmark(mode == "ticker")
                ),
                MenuAction::Command("coverage.chip_show_ticker"),
            ),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Coverage".into()), anchor, items));
    }

    /// #1102 (2026-08-20) — Right-click on any dynamic statusline
    /// segment (manifest-declared or IPC-set). Shows "← Move left"
    /// and "Move right →" against the current effective order (from
    /// `collect_dynamic_segments`), greying the endpoint direction
    /// when the segment is already at the edge of its side. `idx`
    /// is the index into `statusline_segment_hits` — we resolve the
    /// segment id and its neighbors in-render order via
    /// `statusline_segment_hits` (already sorted correctly).
    pub fn open_statusline_segment_context_menu(&mut self, idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // The hits list is in render order per side, but sides can
        // interleave. Filter to the same side as `idx` by walking
        // `dynamic_segments` for each hit-id's side.
        let hits = &self.rects.statusline_segment_hits;
        let Some((_, id)) = hits.get(idx).cloned() else {
            return;
        };
        let seg_side = self
            .dynamic_segments
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.side);
        let same_side_ids: Vec<String> = hits
            .iter()
            .filter(|(_, hid)| {
                self.dynamic_segments
                    .iter()
                    .find(|s| &s.id == hid)
                    .map(|s| Some(s.side) == seg_side)
                    .unwrap_or(false)
            })
            .map(|(_, hid)| hid.clone())
            .collect();
        let pos = same_side_ids.iter().position(|hid| hid == &id).unwrap_or(0);
        let at_left_end = pos == 0;
        let at_right_end = pos + 1 >= same_side_ids.len();
        // Both endpoints — nothing to reorder, don't waste a menu.
        if at_left_end && at_right_end {
            self.toast(format!("`{id}` is the only chip on its side"));
            return;
        }
        let mut items: Vec<MenuItem> = Vec::new();
        if !at_left_end {
            items.push(MenuItem::new(
                "\u{2190} Move left",
                MenuAction::ReorderStatuslineSegment(id.clone(), -1),
            ));
        }
        if !at_right_end {
            items.push(MenuItem::new(
                "Move right \u{2192}",
                MenuAction::ReorderStatuslineSegment(id.clone(), 1),
            ));
        }
        self.context_menu = Some(ContextMenu::new(Some(id), anchor, items));
    }

    /// Task #915 (R5 SEV-2 F1) — Right-click on the statusline AI
    /// Claude/Codex chip. Prior state was silent (no menu rendered),
    /// which read as a broken chip. Expose the same commands the
    /// palette can invoke so a mouse-first user has a visible surface.
    pub fn open_statusline_ai_context_menu(&mut self, anchor: (u16, u16), is_codex: bool) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = if is_codex { "Codex" } else { "Claude" };
        // 2026-08-16 — the "open usage pane" action fans out to the
        // per-product command since `Pane::AiUsage` split into
        // `Pane::ClaudeUsage` + `Pane::CodexUsage`.
        let open_cmd = if is_codex {
            "ai.codex_usage"
        } else {
            "ai.claude_usage"
        };
        let mut items = vec![
            MenuItem::new("Open usage pane", MenuAction::Command(open_cmd)),
            MenuItem::new("Refresh usage now", MenuAction::Command("ai.refresh_usage")),
            MenuItem::new(
                "Show last response (debug)",
                MenuAction::Command("ai.show_last_response"),
            ),
        ];
        // 2026-08-16 — Claude-side meter mode picker. Same idiom as the
        // coverage-chip filter — three rows with ✓ on the current mode.
        // Backed by `[ai] claude_meter_mode` which the render already
        // reads (three values: "session" / "weekly" / "both"). Codex chip
        // doesn't have a session-vs-weekly distinction so this only
        // surfaces on the Claude menu.
        if !is_codex {
            let mode = self
                .config
                .ai
                .as_table()
                .and_then(|t| t.get("claude_meter_mode"))
                .and_then(|v| v.as_str())
                .unwrap_or("session");
            let check = |on: bool| if on { "✓ " } else { "  " };
            items.push(MenuItem::new(
                format!("{}Show session % only", check(mode == "session")),
                MenuAction::Command("ai.chip_show_session"),
            ));
            items.push(MenuItem::new(
                format!("{}Show weekly % only", check(mode == "weekly")),
                MenuAction::Command("ai.chip_show_weekly"),
            ));
            items.push(MenuItem::new(
                format!("{}Show both (session · weekly)", check(mode == "both")),
                MenuAction::Command("ai.chip_show_both"),
            ));
            // #1012 f/u (2026-08-18) — countdown-to-reset suffix
            // toggle. Reads the same `[ai] claude_show_reset` the
            // render fn honors, same shape as claude_meter_mode.
            let show_reset = self
                .config
                .ai
                .as_table()
                .and_then(|t| t.get("claude_show_reset"))
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            items.push(MenuItem::new(
                format!("{}Show ⟳ reset countdown", check(show_reset)),
                MenuAction::Command("ai.chip_toggle_reset"),
            ));
            // Task #944 (extended 2026-08-17) — multi-account tri-state
            // picker. Only offered when >1 account is configured. Three
            // choices — the current one gets a ✓:
            //   Off      = active account only (original default).
            //   Compact  = all accounts in one row (`P40% · W62%
            //              · C12%`); can clip on busy right-side
            //              clusters.
            //   Ticker   = rotate one account per 4s window, full
            //              session+weekly detail per rotation (fits
            //              even with lots of other statusline chips).
            let n_accounts = self.config.claude_accounts().len();
            if n_accounts > 1 {
                use crate::config::ClaudeMultiMode;
                let multi = self.config.ai_claude_multi_mode();
                items.push(MenuItem::new(
                    format!(
                        "{}Active account only",
                        check(multi == ClaudeMultiMode::Off)
                    ),
                    MenuAction::Command("ai.chip_show_all_off"),
                ));
                items.push(MenuItem::new(
                    format!(
                        "{}All accounts (compact — P% · W% · C%)",
                        check(multi == ClaudeMultiMode::Compact)
                    ),
                    MenuAction::Command("ai.chip_show_all_compact"),
                ));
                items.push(MenuItem::new(
                    format!(
                        "{}All accounts (ticker — rotate every 4s)",
                        check(multi == ClaudeMultiMode::Ticker)
                    ),
                    MenuAction::Command("ai.chip_show_all_ticker"),
                ));
            }
        }
        self.context_menu = Some(ContextMenu::new(Some(title.into()), anchor, items));
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
        self.context_submenu = None;
    }

    pub fn context_menu_row_has_submenu(&self, i: usize) -> bool {
        self.context_menu
            .as_ref()
            .and_then(|m| m.items.get(i))
            .is_some_and(|it| it.has_submenu())
    }

    /// Open row `i`'s child menu, or close any open child when that row
    /// has none.
    ///
    /// Idempotent on the row already open, so pointer jitter inside a
    /// parent row does not reset the child's own selection out from
    /// under the user.
    pub fn open_context_submenu(&mut self, i: usize) {
        if self.context_submenu.as_ref().is_some_and(|(p, _)| *p == i) {
            return;
        }
        let items = self
            .context_menu
            .as_ref()
            .and_then(|m| m.items.get(i))
            .and_then(|it| it.submenu.clone());
        self.context_submenu = items.map(|items| {
            (
                i,
                crate::context_menu::ContextMenu::new(None, (0, 0), items),
            )
        });
    }

    /// Run row `i` of the open child menu, then close the whole chain.
    pub fn context_submenu_accept(&mut self, i: usize) {
        let Some((_, menu)) = self.context_submenu.take() else {
            return;
        };
        self.context_menu = None;
        let Some(item) = menu.items.into_iter().nth(i) else {
            return;
        };
        self.run_menu_action(item.action);
    }

    /// Open the per-row options for row `i` of a curatable menu.
    ///
    /// Reuses the submenu machinery rather than inventing a second kind
    /// of floating list: it anchors, clamps and dismisses identically,
    /// and the arrows already know to follow the child.
    pub fn open_menu_row_options(&mut self, i: usize) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(menu) = self.context_menu.as_ref() else {
            return;
        };
        if !menu.curatable {
            return;
        }
        let Some(item) = menu.items.get(i) else {
            return;
        };
        let Some(cmd) = (match &item.action {
            MenuAction::Command(c) => Some((*c).to_string()),
            MenuAction::RunCmd(c) => Some(c.clone()),
            _ => None,
        }) else {
            return;
        };
        let pinned = self.config.ui.plus_menu_pinned.contains(&cmd);
        let items = vec![
            if pinned {
                MenuItem::new("Unpin", MenuAction::PlusMenuUnpin(cmd.clone()))
            } else {
                MenuItem::new("Pin to top", MenuAction::PlusMenuPin(cmd.clone()))
            },
            MenuItem::new("Hide this row", MenuAction::PlusMenuHide(cmd.clone())),
            MenuItem::new("Copy command id", MenuAction::CopyPath(cmd)),
        ];
        self.context_menu_select(i);
        self.context_submenu = Some((i, ContextMenu::new(None, (0, 0), items)));
    }

    /// `\u{2190}` — step back out of a child menu without losing the parent.
    pub fn close_context_submenu(&mut self) {
        self.context_submenu = None;
    }

    pub fn context_menu_move(&mut self, delta: isize) {
        // The child owns the arrows while it is open.
        if let Some((_, m)) = &mut self.context_submenu {
            if delta < 0 {
                m.move_up();
            } else {
                m.move_down();
            }
            return;
        }
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
        if let Some((_, m)) = self.context_submenu.as_ref() {
            let i = m.selected;
            self.context_submenu_accept(i);
            return;
        }
        // Enter on a parent row opens it rather than firing — same rule
        // as the click path, since the row has no action of its own.
        if let Some(m) = self.context_menu.as_ref() {
            let i = m.selected;
            if m.items.get(i).is_some_and(|it| it.has_submenu()) {
                self.open_context_submenu(i);
                return;
            }
        }
        let Some(menu) = self.context_menu.take() else {
            return;
        };
        let Some(item) = menu.items.into_iter().nth(menu.selected) else {
            return;
        };
        self.run_menu_action(item.action);
    }

    pub(crate) fn run_menu_action(&mut self, action: crate::context_menu::MenuAction) {
        use crate::context_menu::MenuAction::*;
        match action {
            OpenPath(p) => self.open_path(&p),
            OpenPathAsText(p) => self.open_path_as_editor(&p),
            OpenInSplit(p) => {
                self.split_active(crate::layout::SplitDir::Horizontal);
                self.open_path(&p);
            }
            RevealInFinder(p) => self.reveal_in_os_file_manager(&p),
            RevealInTree(p) => self.reveal_path_in_tree(&p),
            OpenExternally(p) => open_path_external(&p),
            OpenTerminal(dir) => {
                self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(dir)));
            }
            CopyPath(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast(format!("copied {text}"));
            }
            SetTheme(name) => self.set_theme(&name),
            OpenCloudAgentRunDetail(idx) => {
                self.open_cloud_agent_run(idx);
            }
            SplitTabInto(src, zone) => {
                self.split_tab_into(src, zone);
            }
            HostInBottomPanel(pid) => {
                // #906 slice C (2026-08-20). Mirrors the palette
                // command `view.host_active_in_bottom_panel` but
                // targets the tab that was right-clicked, not the
                // currently-active pane. Idempotent: re-hosting an
                // already-hosted pane just refocuses it.
                if self.bottom_panel_panes.contains(&pid) {
                    self.bottom_panel_active_idx = self
                        .bottom_panel_panes
                        .iter()
                        .position(|p| *p == pid)
                        .unwrap_or(0);
                } else {
                    self.bottom_panel_panes.push(pid);
                    self.bottom_panel_active_idx = self.bottom_panel_panes.len() - 1;
                }
                self.bottom_panel_visible = true;
                self.active = Some(pid);
                self.focus = crate::focus::Focus::BottomPanel;
                self.toast("docked to bottom panel");
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
            SetDefaultWorkspace => {
                self.toggle_default_workspace();
            }
            SetDefaultWorkspaceAt(p) => {
                self.toggle_default_workspace_for(&p);
            }
            EditIntegration(id) => {
                self.open_integration_edit_by_id(&id);
            }
            ConfigureIntegration(id) => {
                self.open_integration_settings(&id);
            }
            RunIntegrationDiag(id) => {
                self.run_integration_diag(&id);
            }
            ShowIntegrationDetails(id) => {
                self.open_integration_detail_pane(&id);
            }
            ShowIntegrationInMarketplace(id) => {
                self.set_activity_section(crate::app::ActivitySection::Integrations);
                self.integrations_panel_tab = crate::app::IntegrationsPanelTab::Marketplace;
                self.integrations_panel_filter = id.clone();
                self.integrations_panel_filter_focused = false;
                self.focus = crate::focus::Focus::Tree;
                self.toast(format!("filtered marketplace to `{id}`"));
            }
            UpdateIntegration(id) => {
                self.apply_integration_update(&id);
            }
            ReorderStatuslineSegment(id, delta) => {
                // Materialize the order list against ALL currently-
                // rendered dynamic segments on the same side so a
                // brand-new user (empty order list) still gets a
                // meaningful swap. Strategy:
                //   1. Snapshot the currently rendered ids in order
                //      (same side as `id`).
                //   2. If `statusline_segment_order` is empty for the
                //      chip's side, seed it with the snapshot.
                //   3. Swap `id` with its neighbor at ±1.
                //   4. Persist + refresh.
                let seg_side = self
                    .dynamic_segments
                    .iter()
                    .find(|s| s.id == id)
                    .map(|s| s.side);
                let same_side_ids: Vec<String> = self
                    .rects
                    .statusline_segment_hits
                    .iter()
                    .filter(|(_, hid)| {
                        self.dynamic_segments
                            .iter()
                            .find(|s| &s.id == hid)
                            .map(|s| Some(s.side) == seg_side)
                            .unwrap_or(false)
                    })
                    .map(|(_, hid)| hid.clone())
                    .collect();
                // Merge existing order with same_side_ids: keep any
                // ids already in the order list (respect user's
                // prior choices for other sides / hidden chips),
                // and interleave the current same-side render order
                // for ids not yet listed.
                let mut order: Vec<String> = self.config.ui.statusline_segment_order.clone();
                for hid in &same_side_ids {
                    if !order.iter().any(|o| o == hid) {
                        order.push(hid.clone());
                    }
                }
                // Locate and swap.
                let Some(pos) = order.iter().position(|o| o == &id) else {
                    self.toast(format!("reorder: `{id}` not in order list"));
                    return;
                };
                let target = if delta < 0 {
                    if pos == 0 {
                        self.toast(format!("`{id}` already at left"));
                        return;
                    }
                    pos - 1
                } else {
                    if pos + 1 >= order.len() {
                        self.toast(format!("`{id}` already at right"));
                        return;
                    }
                    pos + 1
                };
                order.swap(pos, target);
                match crate::app::discovery::persist_ui_string_array(
                    "statusline_segment_order",
                    &order,
                ) {
                    Ok(_) => {
                        self.config.ui.statusline_segment_order = order;
                        let dir = if delta < 0 {
                            "\u{2190} left"
                        } else {
                            "right \u{2192}"
                        };
                        self.toast(format!("{id}: moved {dir}"));
                    }
                    Err(e) => self.toast(format!("reorder: persist failed: {e}")),
                }
            }
            TogglePanelAutoRefresh(panel) => {
                self.toggle_panel_auto_refresh(&panel);
            }
            MarkMessagesSeen => {
                let n = self.unread_message_count();
                self.mark_messages_seen();
                self.toast(format!("marked {n} message(s) read"));
            }
            CopyLastMessage => match self.message_log.last() {
                Some(m) => {
                    let text = m.text.clone();
                    self.clipboard.set(text, false);
                    self.toast("copied the last message");
                }
                None => self.toast("no messages to copy"),
            },
            CopyAllMessages => {
                if self.message_log.is_empty() {
                    self.toast("no messages to copy");
                } else {
                    let n = self.message_log.len();
                    let all = self
                        .message_log
                        .iter()
                        .map(|m| m.text.clone())
                        .collect::<Vec<_>>()
                        .join("\n");
                    self.clipboard.set(all, false);
                    self.toast(format!("copied {n} message(s)"));
                }
            }
            SetPanelSort(panel, mode) => {
                self.set_panel_sort(&panel, &mode);
            }
            SetIntegrationAutoUpdate(id, on) => {
                match crate::app::discovery::persist_integration_auto_update(&id, on) {
                    Ok(path) => {
                        // Refresh manifests so the in-memory
                        // `auto_update_override` reflects the new
                        // value (the menu builder reads it next
                        // right-click).
                        self.refresh_integration_manifests();
                        self.toast(format!(
                            "auto-update: {} \u{2192} {}",
                            id,
                            if on { "on" } else { "off" }
                        ));
                        let _ = path;
                    }
                    Err(e) => self.toast(format!("auto-update: {id}: {e}")),
                }
            }
            SetIntegrationLauncher(id) => {
                self.open_integration_launcher_prompt(id);
            }
            OpenAiSessionWithProfile(id, profile) => {
                self.open_ai_session_with_profile(&id, &profile);
            }
            SetAiDefaultProfile(id, profile) => {
                match crate::launch_profiles::set_default_profile(&self.workspace, &id, &profile) {
                    Ok(()) => self.toast(format!("default {id} profile \u{2192} {profile}")),
                    Err(e) => self.toast(format!("set default profile: {e}")),
                }
            }
            NewAiLaunchProfile(id) => {
                self.open_launch_profile_name_prompt(id);
            }
            RemoveAiLaunchProfile(id, profile) => {
                match crate::launch_profiles::remove_profile(&self.workspace, &id, &profile) {
                    Ok(()) => self.toast(format!("removed profile `{profile}` from {id}")),
                    Err(e) => self.toast(format!("remove profile: {e}")),
                }
            }
            RemoveIntegration(id) => {
                self.open_integration_remove_confirm(id);
            }
            CopyIntegrationId(id) => {
                let mut clip = crate::clipboard::Clipboard::new();
                clip.set(id.clone(), false);
                self.toast(format!("copied `{id}` to clipboard"));
            }
            ShowIntegrationManifest(id) => {
                // Manifests live at ~/.config/mnml/integrations/<id>.toml
                // (user) OR <workspace>/.mnml/integrations/<id>.toml
                // (workspace override). Open the workspace one if it
                // exists, else the user one, else toast.
                let ws_path = self
                    .workspace
                    .join(".mnml")
                    .join("integrations")
                    .join(format!("{id}.toml"));
                let home = std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                let user_path = home
                    .join(".config")
                    .join("mnml")
                    .join("integrations")
                    .join(format!("{id}.toml"));
                if ws_path.exists() {
                    self.open_path(&ws_path);
                } else if user_path.exists() {
                    self.open_path(&user_path);
                } else {
                    self.toast(format!(
                        "no manifest file for `{id}` — it's a built-in default"
                    ));
                }
            }
            ToggleIntegrationEnabled(id) => {
                // #852 — route through the shared toggle helper so
                // both the detail-pane button + right-click-menu
                // paths share the write_override_toml persistence
                // (avoids the config.toml-drop bug from the
                // 2026-08-01 flip; see integration_detail.rs).
                self.toggle_integration_enabled_by_id(&id);
            }
            ToggleIntegrationPaletteBar(id) => {
                self.toggle_integration_palette_bar_by_id(&id);
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
                    self.persist_integration_icon_order();
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
                    self.persist_integration_icon_order();
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
                    self.persist_integration_icon_order();
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
                    self.persist_integration_icon_order();
                }
            }
            AddIntegrationToActivityBar(id) => {
                self.add_integration_to_activity_bar(&id);
            }
            RemoveIntegrationFromActivityBar(id) => {
                self.remove_integration_from_activity_bar(&id);
            }
            LaunchPinnedIntegration(id) => {
                let cmd = self
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .find(|i| i.id == id)
                    .map(|i| i.command.clone());
                if let Some(cmd) = cmd {
                    if let Some(rest) = cmd.strip_prefix(':') {
                        self.run_ex_command(rest);
                    } else {
                        crate::command::run(&cmd, self);
                    }
                }
            }
            MovePinnedIntegrationUp(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .activity_bar_pinned_integrations
                    .iter()
                    .position(|p| p == &id)
                    && pos > 0
                {
                    self.config
                        .ui
                        .activity_bar_pinned_integrations
                        .swap(pos, pos - 1);
                    let _ = crate::app::discovery::persist_activity_bar_pinned_integrations(
                        &self.config.ui.activity_bar_pinned_integrations,
                    );
                }
            }
            MovePinnedIntegrationDown(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .activity_bar_pinned_integrations
                    .iter()
                    .position(|p| p == &id)
                    && pos + 1 < self.config.ui.activity_bar_pinned_integrations.len()
                {
                    self.config
                        .ui
                        .activity_bar_pinned_integrations
                        .swap(pos, pos + 1);
                    let _ = crate::app::discovery::persist_activity_bar_pinned_integrations(
                        &self.config.ui.activity_bar_pinned_integrations,
                    );
                }
            }
            MovePinnedIntegrationToTop(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .activity_bar_pinned_integrations
                    .iter()
                    .position(|p| p == &id)
                    && pos > 0
                {
                    let it = self.config.ui.activity_bar_pinned_integrations.remove(pos);
                    self.config
                        .ui
                        .activity_bar_pinned_integrations
                        .insert(0, it);
                    let _ = crate::app::discovery::persist_activity_bar_pinned_integrations(
                        &self.config.ui.activity_bar_pinned_integrations,
                    );
                }
            }
            MovePinnedIntegrationToBottom(id) => {
                if let Some(pos) = self
                    .config
                    .ui
                    .activity_bar_pinned_integrations
                    .iter()
                    .position(|p| p == &id)
                    && pos + 1 < self.config.ui.activity_bar_pinned_integrations.len()
                {
                    let it = self.config.ui.activity_bar_pinned_integrations.remove(pos);
                    self.config.ui.activity_bar_pinned_integrations.push(it);
                    let _ = crate::app::discovery::persist_activity_bar_pinned_integrations(
                        &self.config.ui.activity_bar_pinned_integrations,
                    );
                }
            }
            ToggleLauncherEnabled(_id) => {
                // 2026-08-01 (P2) — LauncherIcon retired. Kept the
                // MenuAction variant as a no-op so any lingering
                // menu items don't fail to dispatch; will be removed
                // when the enum is next touched.
            }
            SetTopBarClusterMode(mode) => {
                self.config.ui.top_bar_cluster_mode = mode.to_string();
                let _ = crate::app::discovery::persist_top_bar_cluster_mode(mode);
                self.toast(format!("top-bar cluster: {mode}"));
            }
            Command(id) => {
                crate::command::run(id, self);
            }
            RunCmd(cmd) => {
                if let Some(rest) = cmd.strip_prefix(':') {
                    self.run_ex_command(rest);
                } else {
                    crate::command::run(&cmd, self);
                }
            }
            OpenGlyphBuilderForCp(cp) => {
                if !self.open_glyph_builder_for_edit_cp(cp) {
                    self.toast(format!("no glyph found for U+{cp:04X}"));
                }
            }
            RebakeGlyphForCp(cp) => {
                self.rebake_glyph_for_cp(cp);
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
            PtyRestart(id) => {
                // mouse-round-7 SEV-3 2026-07-12 — snap active first
                // so `term.restart` (which reads App.active) targets
                // the tab the user right-clicked.
                self.reveal_pane(id);
                crate::command::run("term.restart", self);
            }
            PtyInterrupt(id) => {
                self.reveal_pane(id);
                if let Some(crate::pane::Pane::Pty(session)) = self.panes.get_mut(id) {
                    session.write_bytes(b"\x03");
                }
            }
            PtyClear(id) => {
                self.reveal_pane(id);
                crate::command::run("term.clear", self);
            }
            NewFile(parent) => self.open_new_file_prompt(parent),
            NewFolder(parent) => self.open_new_folder_prompt(parent),
            Rename(path) => self.open_fs_rename_prompt(path),
            Delete(path) => self.open_fs_delete_prompt(path),
            // Inert by construction — the click that lands on a submenu
            // row opens its child instead of dispatching. Reaching here
            // means the caller lost track of that.
            Submenu => {}
            GitSwitchRepo(i) => self.switch_active_repo(i),
            GitReopenRepo(path) => {
                if self.git_closed_repos.remove(&path) {
                    self.open_git_graph();
                    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("repo");
                    self.toast(format!("reopened {name}"));
                }
            }
            TodoAction { row, prefix, codex } => self.todos_run_action(row, &prefix, codex),
            PlusMenuPin(id) => self.plus_menu_curate(&id, PlusCuration::Pin),
            PlusMenuUnpin(id) => self.plus_menu_curate(&id, PlusCuration::Unpin),
            PlusMenuHide(id) => self.plus_menu_curate(&id, PlusCuration::Hide),
            FilesToggleMark(pane_id, path) => {
                if let Some(crate::pane::Pane::Files(f)) = self.panes.get_mut(pane_id) {
                    f.toggle_mark_path(path);
                }
            }
            FilesCutMarked(pane_id) => {
                let paths = self.files_pane_marked_paths(pane_id);
                self.file_stage_clipboard_many(paths, true);
            }
            FilesCopyMarked(pane_id) => {
                let paths = self.files_pane_marked_paths(pane_id);
                self.file_stage_clipboard_many(paths, false);
            }
            FileCut(path) => self.file_stage_clipboard(path, true),
            FileCopy(path) => self.file_stage_clipboard(path, false),
            FilePaste(target) => self.file_paste_into(target),
            FileDuplicate(path) => self.file_duplicate(path),
            FileMoveTo(path) => self.file_open_move_to_picker(path),
            SetEnvVarValue(name) => self.accept_env_vars(&name),
            JumpToEnvVar(name) => self.open_env_var_definition(&name),
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
            SessionTogglePin(pid) => self.session_toggle_pin(pid),
            SessionMoveUp(pid) => self.session_move_up(pid),
            SessionMoveDown(pid) => self.session_move_down(pid),
            SessionMoveToTop(pid) => self.session_move_to_top(pid),
            SessionMoveToBottom(pid) => self.session_move_to_bottom(pid),
            SessionSortAuto => self.session_sort_auto(),
            WorkspaceEditName(idx) => self.workspaces_editor_open_rename(idx),
            WorkspaceEditPath(idx) => self.workspaces_editor_open_path(idx),
            WorkspaceEditGroup(idx) => self.workspaces_editor_open_group(idx),
            WorkspaceDelete(idx) => self.workspaces_editor_delete(idx),
            WorkspaceSetDefault(idx) => self.workspaces_editor_toggle_default(idx),
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
            OpenBookmarks(env) => {
                self.open_bookmarks_picker(env.as_deref());
            }
            OpenFilesPane(dir) => self.open_files_pane(Some(dir)),
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

#[cfg(test)]
mod submenu_tests {
    use crate::app::App;
    use crate::config::Config;
    use crate::context_menu::{ContextMenu, MenuAction, MenuItem};

    fn app_with_menu() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let items = vec![
            MenuItem::new("Plain", MenuAction::Command("scratch.new")),
            MenuItem::submenu(
                "Group",
                vec![
                    MenuItem::new("Child A", MenuAction::Command("tab.new")),
                    MenuItem::new("Child B", MenuAction::Command("term.shell")),
                ],
            ),
        ];
        app.context_menu = Some(ContextMenu::new(None, (0, 0), items));
        (d, app)
    }

    #[test]
    fn opening_a_parent_row_makes_its_children_available() {
        let (_d, mut app) = app_with_menu();
        assert!(app.context_submenu.is_none());
        app.open_context_submenu(1);
        let (parent, m) = app.context_submenu.as_ref().expect("no child opened");
        assert_eq!(*parent, 1);
        assert_eq!(m.items.len(), 2);
    }

    /// A row with no children must CLOSE any open child, or the child
    /// lingers beside an unrelated row and its rows dispatch from the
    /// wrong context.
    #[test]
    fn moving_to_a_row_without_children_closes_the_open_child() {
        let (_d, mut app) = app_with_menu();
        app.open_context_submenu(1);
        assert!(app.context_submenu.is_some(), "precondition");
        app.open_context_submenu(0);
        assert!(
            app.context_submenu.is_none(),
            "a childless row left the previous child on screen"
        );
    }

    /// Re-opening the row already open must not reset the child's own
    /// selection — pointer jitter inside a parent row would otherwise
    /// yank the highlight back to the first child mid-reach.
    #[test]
    fn reopening_the_same_row_preserves_the_childs_selection() {
        let (_d, mut app) = app_with_menu();
        app.open_context_submenu(1);
        if let Some((_, m)) = app.context_submenu.as_mut() {
            m.set_selected(1);
        }
        app.open_context_submenu(1);
        assert_eq!(
            app.context_submenu.as_ref().unwrap().1.selected,
            1,
            "jitter inside the parent row reset the child's selection"
        );
    }

    /// Enter on a parent OPENS it. Firing `MenuAction::Submenu` would
    /// dismiss the menu and do nothing at all — a dead keypress on the
    /// row whose `▸` promises more.
    #[test]
    fn enter_on_a_parent_opens_it_rather_than_dismissing() {
        let (_d, mut app) = app_with_menu();
        app.context_menu_select(1);
        app.context_menu_accept();
        assert!(app.context_menu.is_some(), "Enter dismissed the menu");
        assert!(
            app.context_submenu.is_some(),
            "Enter on a parent row did nothing"
        );
    }

    /// Accepting a child runs the CHILD's action and closes the whole
    /// chain — not the parent's, and not leaving the parent up.
    #[test]
    fn accepting_a_child_closes_the_whole_chain() {
        let (_d, mut app) = app_with_menu();
        app.open_context_submenu(1);
        app.context_submenu_accept(0);
        assert!(app.context_submenu.is_none(), "child stayed open");
        assert!(app.context_menu.is_none(), "parent stayed open");
    }

    /// `←` steps out one level, keeping the parent. Esc closes
    /// everything — a user reaching for Esc wants out of the menu, not
    /// out of one level of it.
    #[test]
    fn left_closes_only_the_child_but_esc_closes_everything() {
        let (_d, mut app) = app_with_menu();
        app.open_context_submenu(1);
        app.close_context_submenu();
        assert!(app.context_submenu.is_none());
        assert!(app.context_menu.is_some(), "`←` closed the parent too");

        app.open_context_submenu(1);
        app.context_menu_cancel();
        assert!(
            app.context_submenu.is_none() && app.context_menu.is_none(),
            "Esc left part of the chain on screen"
        );
    }

    /// Arrows belong to the child while it is open, or the highlight
    /// moves in the parent behind a menu the user is looking at.
    #[test]
    fn arrows_drive_the_child_while_it_is_open() {
        let (_d, mut app) = app_with_menu();
        app.context_menu_select(1);
        app.open_context_submenu(1);
        app.context_menu_move(1);
        assert_eq!(
            app.context_submenu.as_ref().unwrap().1.selected,
            1,
            "the child did not take the arrow"
        );
        assert_eq!(
            app.context_menu.as_ref().unwrap().selected,
            1,
            "the parent's selection moved out from under the open child"
        );
    }
}

/// Which way a `+` menu row is being curated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlusCuration {
    Pin,
    Unpin,
    Hide,
}

impl crate::app::App {
    /// Apply one curation to the `+` menu and write it to user config.
    ///
    /// In-memory AND persisted together: a curation that reverts on
    /// restart is worse than none, because the user stops trusting the
    /// menu. This is the gap the 2026-08-09 persist sweep was chasing.
    pub fn plus_menu_curate(&mut self, id: &str, how: PlusCuration) {
        let ui = &mut self.config.ui;
        match how {
            PlusCuration::Pin => {
                ui.plus_menu_hidden.retain(|x| x != id);
                if !ui.plus_menu_pinned.iter().any(|x| x == id) {
                    ui.plus_menu_pinned.push(id.to_string());
                }
            }
            PlusCuration::Unpin => ui.plus_menu_pinned.retain(|x| x != id),
            PlusCuration::Hide => {
                // Hiding something pinned has to unpin it too, or it
                // stays on screen and the row appears to do nothing.
                ui.plus_menu_pinned.retain(|x| x != id);
                if !ui.plus_menu_hidden.iter().any(|x| x == id) {
                    ui.plus_menu_hidden.push(id.to_string());
                }
            }
        }
        let pinned = self.config.ui.plus_menu_pinned.clone();
        let hidden = self.config.ui.plus_menu_hidden.clone();
        let mut err = None;
        if let Err(e) = crate::app::discovery::persist_ui_string_array("plus_menu_pinned", &pinned)
        {
            err = Some(e);
        }
        if let Err(e) = crate::app::discovery::persist_ui_string_array("plus_menu_hidden", &hidden)
        {
            err = Some(e);
        }
        match err {
            Some(e) => self.toast(format!("could not save + menu layout: {e}")),
            None => {
                let what = match how {
                    PlusCuration::Pin => "pinned",
                    PlusCuration::Unpin => "unpinned",
                    // Name the way back, or a hidden row is a row the
                    // user cannot work out how to recover.
                    PlusCuration::Hide => "hidden — restore via :config or Settings",
                };
                self.toast(format!("{id} {what}"));
            }
        }
    }
}

#[cfg(test)]
mod bell_menu_tests {
    use crate::app::{App, ToastLevel};
    use crate::config::Config;

    fn app() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    fn labels(app: &App) -> Vec<String> {
        app.context_menu
            .as_ref()
            .map(|m| m.items.iter().map(|i| i.label.clone()).collect())
            .unwrap_or_default()
    }

    /// A quiet bell must not offer "mark read" — a row that does
    /// nothing teaches the user the menu is unreliable.
    #[test]
    fn a_quiet_bell_offers_no_mark_read_row() {
        let (_d, mut app) = app();
        app.open_notification_bell_menu((0, 0));
        let l = labels(&app);
        assert!(
            !l.iter().any(|s| s.contains("read")),
            "offered mark-read with nothing unread: {l:?}"
        );
        assert!(l.iter().any(|s| s == "Show history"), "{l:?}");
    }

    /// With unread messages the row appears AND says how many.
    #[test]
    fn an_unread_bell_offers_mark_read_with_a_count() {
        let (_d, mut app) = app();
        app.toast_leveled("a problem", ToastLevel::Error);
        app.open_notification_bell_menu((0, 0));
        let l = labels(&app);
        assert!(
            l.iter().any(|s| s == "Mark 1 read"),
            "no counted mark-read row: {l:?}"
        );
    }

    /// Mark-read clears the badge WITHOUT opening the history — the
    /// whole point, since that was previously the only way.
    #[test]
    fn mark_read_clears_the_badge_without_opening_the_history() {
        let (_d, mut app) = app();
        app.toast_leveled("a problem", ToastLevel::Error);
        assert_eq!(app.unread_message_count(), 1, "setup");
        app.run_menu_action(crate::context_menu::MenuAction::MarkMessagesSeen);
        assert_eq!(app.unread_message_count(), 0, "the badge did not clear");
        assert!(
            app.picker.is_none(),
            "it opened the history as a side effect"
        );
    }

    /// Copy must put the message somewhere, not just toast about it.
    ///
    /// Asserted on the internal REGISTER, not `Clipboard::text()`.
    /// `text()` prefers the OS clipboard when it differs, so the first
    /// version of this test was reading the developer's real macOS
    /// clipboard — which still held this exact string from the previous
    /// run. It passed with the copy removed entirely.
    #[test]
    fn copy_last_message_puts_the_text_on_the_clipboard() {
        let (_d, mut app) = app();
        app.toast_leveled("a uniquely identifying failure string", ToastLevel::Error);
        app.run_menu_action(crate::context_menu::MenuAction::CopyLastMessage);
        assert!(
            app.clipboard
                .register
                .contains("a uniquely identifying failure string"),
            "the register does not hold the message: {:?}",
            app.clipboard.register
        );
    }
}

#[cfg(test)]
mod reveal_action_tests {
    use crate::context_menu::MenuAction;

    /// USER 2026-09-03 — "is reveal in tree supposed to open finder? idd
    /// expect one that oepened in mnml filebrowser view and another that
    /// opened in finder".
    ///
    /// Nine menu rows read "Reveal in tree" while firing the OS reveal,
    /// so the in-app action did not exist — the label was the only thing
    /// claiming it did. This asserts the pairing directly on the source,
    /// because the defect was a label/action mismatch that compiles
    /// perfectly and no render test would notice.
    #[test]
    fn no_menu_row_labelled_reveal_in_tree_fires_the_os_reveal() {
        let mut offenders = Vec::new();
        for f in [
            "src/tui/mouse/right_click.rs",
            "src/app/context_menus.rs",
            "src/app/cloud_agents_methods.rs",
            "src/app/git.rs",
        ] {
            let src = std::fs::read_to_string(f).unwrap_or_default();
            for (i, line) in src.lines().enumerate() {
                if line.contains("\"Reveal in tree\"")
                    && (line.contains("RevealInFinder") || line.contains("view.reveal_active"))
                {
                    offenders.push(format!("{f}:{}", i + 1));
                }
            }
        }
        assert!(
            offenders.is_empty(),
            "these rows say \"Reveal in tree\" but open the OS file manager: {offenders:?}"
        );
    }

    /// The two actions must stay distinct variants. Collapsing them
    /// back into one is how the mislabel happened in the first place.
    #[test]
    fn reveal_in_tree_and_reveal_in_finder_are_different_actions() {
        let p = std::path::PathBuf::from("/tmp/x");
        let tree = MenuAction::RevealInTree(p.clone());
        let os = MenuAction::RevealInFinder(p);
        assert!(
            !matches!(tree, MenuAction::RevealInFinder(_)),
            "RevealInTree collapsed into RevealInFinder"
        );
        assert!(matches!(os, MenuAction::RevealInFinder(_)));
    }

    /// The OS reveal must not be macOS-only. It shelled out to a bare
    /// `open -R` for every platform, so "Reveal in Explorer" on Windows
    /// silently did nothing.
    #[test]
    fn the_os_reveal_handles_every_platform() {
        let src = std::fs::read_to_string("src/app/mod.rs").unwrap();
        let f = src
            .split("pub fn reveal_in_os_file_manager")
            .nth(1)
            .expect("reveal_in_os_file_manager is gone");
        let body: String = f.chars().take(900).collect();
        for needle in ["macos", "windows", "explorer", "open"] {
            assert!(
                body.contains(needle),
                "the OS reveal lost its {needle} path"
            );
        }
    }
}
