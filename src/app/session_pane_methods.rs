//! Session-panel + tab-strip pane methods on `App` — context menus
//! for Cloud Agents rail rows / session tabs / hover-help kebab,
//! open-CloudWatch / open-S3 aux panes, per-session pin/reorder/
//! rename/color and close, plus the sort-auto reset.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

/// Shared "Color: …" menu items for right-click on a Pty session —
/// referenced by BOTH the sessions-rail context menu and the pty
/// tab-strip context menu at the top of a pane (task #1178 f/u,
/// 2026-08-23 user ask: "you can also do this in sessions … be
/// consistent"). Keep the two menus wired to the same list so a
/// color added here shows up in both surfaces without hunt-and-
/// pecking through two files.
pub(crate) fn session_color_menu_items(pane_id: usize) -> Vec<crate::context_menu::MenuItem> {
    use crate::context_menu::{MenuAction, MenuItem};
    // Drive both the label and the SessionSetColor payload off the
    // shared PALETTE — menu order = auto-cycle order = list order,
    // and adding a color is a one-line edit in session_color.rs.
    let colors = crate::ui::session_color::PALETTE;
    let mut items: Vec<MenuItem> = colors
        .iter()
        .map(|&name| {
            MenuItem::new(
                crate::ui::session_color::menu_label(name),
                MenuAction::SessionSetColor(pane_id, name),
            )
        })
        .collect();
    items.push(MenuItem::new(
        "Color: None",
        MenuAction::SessionSetColor(pane_id, "none"),
    ));
    items
}

impl App {
    /// Build + open the sessions-panel context menu for one
    /// Pty pane (right-click on a session tab).
    /// Right-click on a row in the Cloud Agents rail panel.
    /// Items vary by the run's state (PR-related only when shipped).
    pub fn open_cloud_row_context_menu(&mut self, row_idx: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(row) = self.cloud_agents_rows.get(row_idx).cloned() else {
            return;
        };
        // Managed-agent rows are a different beast — no CloudWatch
        // / S3 / PR. Branch to a separate menu and return.
        if matches!(
            row.source,
            crate::claude_agents::AgentSource::AnthropicManaged
        ) {
            let workspace = std::env::var("ANTHROPIC_AWS_WORKSPACE_ID")
                .ok()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "default".to_string());
            let console_url = format!(
                "https://platform.claude.com/workspaces/{workspace}/sessions/{}",
                row.session_id
            );
            let title = Some(format!("{} · {}", row.workspace, row.session_id));
            let items = vec![
                MenuItem::new("View details", MenuAction::OpenCloudAgentRunDetail(row_idx)),
                MenuItem::new(
                    "Copy session id",
                    MenuAction::CopyText(row.session_id.clone()),
                ),
                MenuItem::new(
                    "Open in Anthropic Console",
                    MenuAction::OpenUrl(console_url),
                ),
                MenuItem::new(
                    "Stop session",
                    MenuAction::StopManagedSession(row.session_id.clone()),
                ),
            ];
            self.context_menu = Some(ContextMenu::new(title, anchor, items));
            return;
        }
        let meta = self.cloud_agents_meta.get(&row.session_id).cloned();
        let title = Some(format!("{} · {}", row.workspace, row.session_id));
        let cloudwatch_url = meta
            .as_ref()
            .map(|m| m.cloudwatch_url(&row.session_id))
            .unwrap_or_else(|| {
                crate::ecs_runner::EcsRunMeta::default().cloudwatch_url(&row.session_id)
            });
        let mut items = vec![
            MenuItem::new("Copy runId", MenuAction::CopyText(row.session_id.clone())),
            // Sibling-tool integration: spawns `mnml-aws-cloudwatch-logs`
            // in a Pty pane, pre-filtered to this run's runId. Lets
            // the user read the logs without leaving mnml.
            MenuItem::new(
                "Tail logs in mnml",
                MenuAction::OpenCloudWatchPane {
                    log_group: self.config.cloud_agents.log_group.clone(),
                    filter: row.session_id.clone(),
                    label: format!("ecs: {}", row.workspace),
                },
            ),
            MenuItem::new(
                "Open CloudWatch in browser",
                MenuAction::OpenUrl(cloudwatch_url),
            ),
        ];
        if let Some(pr) = meta.as_ref().and_then(|m| m.pr_url.clone()) {
            items.push(MenuItem::new("Open PR", MenuAction::OpenUrl(pr)));
        }
        if let Some(prefix) = meta.as_ref().and_then(|m| m.s3_artifact_prefix.clone()) {
            // Split `s3://bucket/key/prefix/` → bucket + prefix
            // so we can hand them to mnml-fs-s3 as separate
            // CLI args (the integration expects `--bucket` and
            // `--prefix` rather than a single s3:// URL).
            let stripped = prefix.strip_prefix("s3://").unwrap_or(&prefix);
            let (bucket, key_prefix) = match stripped.split_once('/') {
                Some((b, p)) => (b.to_string(), p.to_string()),
                None => (stripped.to_string(), String::new()),
            };
            items.push(MenuItem::new(
                "Browse S3 artifacts in mnml",
                MenuAction::OpenS3Pane {
                    bucket: bucket.clone(),
                    prefix: key_prefix,
                    label: format!("s3: {}", row.workspace),
                },
            ));
            // Browser fallback for users without mnml-fs-s3.
            let console = s3_prefix_to_console_url(&prefix);
            items.push(MenuItem::new(
                "Open S3 artifacts in browser",
                MenuAction::OpenUrl(console),
            ));
        }
        self.context_menu = Some(ContextMenu::new(title, anchor, items));
    }

    /// 2026-08-11 — kebab menu for the Ableton-style hover-help panel.
    /// Anchored below the `⋮` glyph in the title bar.
    ///
    /// 2026-08-23 (user feedback) — was labeled "Close", which reads as
    /// "hide this one time" and misled users into globally-disabling
    /// the whole feature by persisting `[ui] hover_help = false` to
    /// their config. Item is now "Turn off info panel (Settings →
    /// UI to bring back)" so the consequence is legible before the
    /// click. Same underlying command; only the label changed.
    pub fn open_hover_help_kebab_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![MenuItem::destructive(
            "Turn off info panel (Settings → UI to bring back)",
            MenuAction::Command("view.toggle_hover_help"),
        )];
        self.context_menu = Some(ContextMenu::new(None, anchor, items));
    }

    /// Spawn the `mnml-aws-cloudwatch-logs` integration tool in a Pty
    /// pane. Friendly error toast when the binary isn't on PATH.
    pub fn open_cloudwatch_pane(&mut self, log_group: &str, filter: &str, label: &str) {
        if !binary_on_path("mnml-aws-cloudwatch-logs") {
            self.integrations_panel_tab = crate::app::IntegrationsPanelTab::Marketplace;
            self.toast("mnml-aws-cloudwatch-logs not installed — install from the Marketplace tab");
            return;
        }
        let profile = crate::pty_pane::BinaryProfile {
            label: label.to_string(),
            exe: "mnml-aws-cloudwatch-logs".to_string(),
            args: vec![
                "--log-group".to_string(),
                log_group.to_string(),
                "--log-group-name".to_string(),
                label.to_string(),
                "--filter".to_string(),
                filter.to_string(),
            ],
            cwd: Some(self.workspace.clone()),
            env: Vec::new(),
            session_id: None,
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!("tailing {log_group} · filter={filter}"));
    }

    /// Spawn the `mnml-fs-s3` integration tool in a Pty pane,
    /// pre-filtered to `bucket` + `prefix`. Friendly error toast
    /// when the binary isn't on PATH.
    pub fn open_s3_pane(&mut self, bucket: &str, prefix: &str, label: &str) {
        if !binary_on_path("mnml-fs-s3") {
            self.integrations_panel_tab = crate::app::IntegrationsPanelTab::Marketplace;
            self.toast("mnml-fs-s3 not installed — install from the Marketplace tab");
            return;
        }
        let profile = crate::pty_pane::BinaryProfile {
            label: label.to_string(),
            exe: "mnml-fs-s3".to_string(),
            args: vec![
                "--bucket".to_string(),
                bucket.to_string(),
                "--prefix".to_string(),
                prefix.to_string(),
                "--bucket-name".to_string(),
                label.to_string(),
            ],
            cwd: Some(self.workspace.clone()),
            env: Vec::new(),
            session_id: None,
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!("browsing s3://{bucket}/{prefix}"));
    }

    pub fn open_session_tab_context_menu(&mut self, pane_id: usize, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let label = match self.panes.get(pane_id) {
            Some(crate::pane::Pane::Pty(s)) => s
                .display_name
                .clone()
                .unwrap_or_else(|| s.profile.label.clone()),
            _ => return,
        };
        let title = Some(label);
        let pinned = self.sessions_pinned.contains(&pane_id);
        let pin_label = if pinned { "Unpin" } else { "Pin" };
        let sort_auto_label = match self.sessions_sort_mode {
            crate::app::SessionsSortMode::Auto => "✓ Auto sort",
            crate::app::SessionsSortMode::Manual => "Auto sort",
        };
        let mut items = vec![
            MenuItem::new(pin_label, MenuAction::SessionTogglePin(pane_id)),
            MenuItem::new("Move up", MenuAction::SessionMoveUp(pane_id)),
            MenuItem::new("Move down", MenuAction::SessionMoveDown(pane_id)),
            MenuItem::new("Move to top", MenuAction::SessionMoveToTop(pane_id)),
            MenuItem::new("Move to bottom", MenuAction::SessionMoveToBottom(pane_id)),
            MenuItem::new(sort_auto_label, MenuAction::SessionSortAuto),
            MenuItem::new("Rename…", MenuAction::SessionRename(pane_id)),
        ];
        items.extend(session_color_menu_items(pane_id));
        items.push(MenuItem::new(
            "Close session",
            MenuAction::SessionClose(pane_id),
        ));
        self.context_menu = Some(ContextMenu::new(title, anchor, items));
    }

    /// #1181 (2026-08-23) — right-click on the sessions rail's
    /// "+ New session" chip. Left-click still fires a single spawn;
    /// this menu is the shortcut for "give me a cluster" (×2 / ×4 /
    /// ×8) so users can fan out parallel Claudes without clicking
    /// the chip 8 times.
    pub fn open_new_session_batch_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = Some("New Claude sessions".to_string());
        let items = vec![
            MenuItem::new("New session", MenuAction::Command("ai.claude_code_new")),
            MenuItem::new("Open ×2", MenuAction::Command("ai.claude_code_new_x2")),
            MenuItem::new("Open ×4", MenuAction::Command("ai.claude_code_new_x4")),
            MenuItem::new("Open ×8", MenuAction::Command("ai.claude_code_new_x8")),
        ];
        self.context_menu = Some(ContextMenu::new(title, anchor, items));
    }

    /// Toggle pin state for a session; pinned sessions bubble to
    /// the top of the Sessions panel.
    pub fn session_toggle_pin(&mut self, pane_id: usize) {
        if self.sessions_pinned.contains(&pane_id) {
            self.sessions_pinned.remove(&pane_id);
        } else {
            self.sessions_pinned.insert(pane_id);
        }
    }

    /// Ensure the manual order vec contains `pane_id`. If it's
    /// missing, appends it. Idempotent.
    fn ensure_in_manual_order(&mut self, pane_id: usize) {
        if !self.sessions_manual_order.contains(&pane_id) {
            self.sessions_manual_order.push(pane_id);
        }
        self.sessions_sort_mode = crate::app::SessionsSortMode::Manual;
    }

    /// Move a session one slot up in the manual order (swap with
    /// its predecessor). Switches sort mode to Manual.
    pub fn session_move_up(&mut self, pane_id: usize) {
        self.ensure_in_manual_order(pane_id);
        if let Some(pos) = self
            .sessions_manual_order
            .iter()
            .position(|&p| p == pane_id)
            && pos > 0
        {
            self.sessions_manual_order.swap(pos, pos - 1);
        }
    }

    /// Move a session one slot down in the manual order.
    pub fn session_move_down(&mut self, pane_id: usize) {
        self.ensure_in_manual_order(pane_id);
        if let Some(pos) = self
            .sessions_manual_order
            .iter()
            .position(|&p| p == pane_id)
            && pos + 1 < self.sessions_manual_order.len()
        {
            self.sessions_manual_order.swap(pos, pos + 1);
        }
    }

    /// Move a session to the top of the manual order.
    pub fn session_move_to_top(&mut self, pane_id: usize) {
        self.ensure_in_manual_order(pane_id);
        if let Some(pos) = self
            .sessions_manual_order
            .iter()
            .position(|&p| p == pane_id)
        {
            let v = self.sessions_manual_order.remove(pos);
            self.sessions_manual_order.insert(0, v);
        }
    }

    /// Move a session to the bottom of the manual order.
    pub fn session_move_to_bottom(&mut self, pane_id: usize) {
        self.ensure_in_manual_order(pane_id);
        if let Some(pos) = self
            .sessions_manual_order
            .iter()
            .position(|&p| p == pane_id)
        {
            let v = self.sessions_manual_order.remove(pos);
            self.sessions_manual_order.push(v);
        }
    }

    /// Switch the Sessions panel back to Auto sort mode. Clears
    /// the user's manual order (nothing to preserve — the auto
    /// rules take over).
    pub fn session_sort_auto(&mut self) {
        self.sessions_sort_mode = crate::app::SessionsSortMode::Auto;
        self.sessions_manual_order.clear();
    }

    /// Open the rename prompt for a specific Pty pane (the
    /// sessions panel context menu's "Rename…" target). Sets
    /// `App::active` to that pane first so the commit handler
    /// (`rename_active_pty`) acts on it.
    pub fn open_session_rename_prompt(&mut self, pane_id: usize) {
        if !matches!(self.panes.get(pane_id), Some(crate::pane::Pane::Pty(_))) {
            return;
        }
        self.active = Some(pane_id);
        self.open_rename_session_prompt();
    }

    /// Set the accent color of a specific Pty pane. `"none"` clears
    /// the override so #1179's auto-assign can re-compute this
    /// session's palette slot on the fly (rather than leaving it
    /// `None`, which would fall through to different fallbacks in
    /// the rail vs. the pane and break color consistency —
    /// task #1178 f/u, 2026-08-23).
    pub fn set_session_color(&mut self, pane_id: usize, color: &'static str) {
        // Take (idx, prev_color) so we can splice the auto-assign back
        // in without holding a mut borrow across the second call.
        if !matches!(self.panes.get(pane_id), Some(crate::pane::Pane::Pty(_))) {
            return;
        }
        if let Some(crate::pane::Pane::Pty(s)) = self.panes.get_mut(pane_id) {
            match color {
                "none" | "" => {
                    s.accent_color = None;
                }
                other => {
                    s.accent_color = Some(other.to_string());
                    return;
                }
            }
        }
        // On "none" for a Claude Code pane: re-derive this pane's
        // auto slot. Detached the mutation from the count-scan above
        // so we're not borrowing self.panes both ways at once.
        //
        // The count filter EXCLUDES this pane so its palette index
        // matches "how many other Claude sessions exist before me".
        let is_claude = matches!(
            self.panes.get(pane_id),
            Some(crate::pane::Pane::Pty(s)) if s.profile.integration_id.as_deref() == Some("claude_code")
        );
        if !is_claude {
            return;
        }
        let position: usize = self
            .panes
            .iter()
            .enumerate()
            .take(pane_id)
            .filter(|(_, p)| match p {
                crate::pane::Pane::Pty(sess) => {
                    sess.profile.integration_id.as_deref() == Some("claude_code")
                }
                _ => false,
            })
            .count();
        let palette = crate::ui::session_color::PALETTE;
        let idx = position % palette.len();
        if let Some(crate::pane::Pane::Pty(s)) = self.panes.get_mut(pane_id) {
            s.accent_color = Some(palette[idx].to_string());
        }
    }

    /// Sessions panel — close the Pty at `pane_id` (kills the
    /// child via the standard `close_pane` path).
    pub fn close_session(&mut self, pane_id: usize) {
        if matches!(self.panes.get(pane_id), Some(crate::pane::Pane::Pty(_))) {
            self.close_pane(pane_id);
        }
    }

    pub fn open_rename_session_prompt(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active pane");
            return;
        };
        let seed = match self.panes.get(cur) {
            Some(Pane::Pty(s)) => s.display_name.clone().unwrap_or_default(),
            _ => {
                self.toast("rename works on terminal / Claude / Codex panes");
                return;
            }
        };
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::PtySessionName,
            "Rename session (empty = reset to default)",
            seed,
        );
        self.prompt = Some(prompt);
    }
}
