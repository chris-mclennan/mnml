//! `Pane::IntegrationDetail` — App-side helpers.
//!
//! Owns the open path (`open_integration_detail_pane`), the two
//! id-keyed action helpers used by both the pane's button strip
//! and the right-click menu (`toggle_integration_enabled_by_id`,
//! `open_integration_manifest_by_id`), and the click / keyboard
//! routing entry points invoked by the mouse / pane handlers.
//!
//! The pane never mutates the integration itself — every action
//! either dispatches a registered command or calls one of the
//! helpers here. That keeps the "no special-casing across layers"
//! spine intact: the click-router and the keyboard-router both
//! call `crate::ui::integration_detail_view::fire_action`, which
//! calls `dispatch_detail_action`, which reaches back into `App`.
//!
//! Idempotent open: firing `open_integration_detail_pane("slack")`
//! twice reuses the same pane (matches Outline / Diagnostics).

use crate::app::App;
use crate::focus::Focus;
use crate::layout::PaneId;
use crate::pane::{IntegrationDetailPane, Pane};

impl App {
    /// Open (or refocus) the integration-detail pane for `id`. Hosts
    /// in the right panel by default (matches Outline / Diagnostics);
    /// falls back to a split in the active leaf when the right
    /// panel is closed.
    pub fn open_integration_detail_pane(&mut self, id: &str) {
        // Refuse silently if the id doesn't resolve to an installed
        // (or Marketplace-listed) integration — toast a hint.
        let known = self.config.ui.integration_icons.iter().any(|i| i.id == id);
        if !known {
            self.toast(format!("no integration with id `{id}`"));
            return;
        }
        // Reuse an existing detail pane for the same id if present.
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::IntegrationDetail(d) if d.id == id))
        {
            self.reveal_or_bring_to_front(pid);
            return;
        }
        let pane = Pane::IntegrationDetail(IntegrationDetailPane::new(id.to_string()));
        if self.right_panel_visible {
            self.panes.push(pane);
            let new_id = self.panes.len() - 1;
            self.right_panel_push(new_id);
            self.focus = Focus::RightPanel;
            return;
        }
        // Right panel closed — open the panel first, then host in
        // it. The detail pane's whole design assumes the narrow-
        // column right-panel layout; a body split would work but
        // wastes editor real estate.
        self.right_panel_visible = true;
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.right_panel_push(new_id);
        self.focus = Focus::RightPanel;
    }

    /// Best-effort reveal of an existing pane — if it's a
    /// right-panel host, switch its tab; else route through
    /// `reveal_pane`.
    fn reveal_or_bring_to_front(&mut self, pid: PaneId) {
        if let Some(idx) = self.right_panel_panes.iter().position(|&p| p == pid) {
            self.right_panel_visible = true;
            self.right_panel_active_idx = idx;
            self.focus = Focus::RightPanel;
        } else {
            self.reveal_pane(pid);
        }
    }

    /// Flip enabled/disabled for the integration with `id`, toast,
    /// persist. Same implementation as the right-click
    /// `ToggleIntegrationEnabled` handler — extracted so both
    /// call sites share behavior (persist + toast + no-op-if-
    /// missing).
    pub fn toggle_integration_enabled_by_id(&mut self, id: &str) {
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
            let _ =
                crate::app::discovery::persist_integration_icons(&self.config.ui.integration_icons);
        }
    }

    /// Open the on-disk manifest for `id` in an editor pane. Prefers
    /// the workspace override (`<ws>/.mnml/integrations/<id>.toml`),
    /// falls back to the user manifest, else toasts a hint.
    /// Same logic as the right-click `ShowIntegrationManifest`
    /// handler — extracted for reuse from the detail pane's
    /// [Edit manifest] button.
    pub fn open_integration_manifest_by_id(&mut self, id: &str) {
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

    /// Wrapper around `open_glyph_builder_for_edit_cp` that toasts on
    /// miss — used by the detail pane's [Bake glyph] button.
    pub fn open_glyph_builder_for_cp(&mut self, cp: u32) {
        if !self.open_glyph_builder_for_edit_cp(cp) {
            self.toast(format!("no glyph found for U+{cp:04X}"));
        }
    }

    /// Move the detail pane's button/link cursor by `delta`, clamped
    /// to the actionable-row count. Called from the pane keyboard
    /// handler for ↑ / ↓ / Tab / Shift+Tab.
    pub fn integration_detail_cursor_move(&mut self, delta: isize) {
        let Some(pid) = self.right_panel_active_pane_id().or(self.active) else {
            return;
        };
        let total = crate::ui::integration_detail_view::action_count(self, pid);
        if total == 0 {
            return;
        }
        let Some(Pane::IntegrationDetail(d)) = self.panes.get_mut(pid) else {
            return;
        };
        let new = (d.cursor as isize + delta).clamp(0, total as isize - 1) as usize;
        d.cursor = new;
    }

    /// Fire the currently-focused button/link — called from the
    /// pane keyboard handler for Enter / Space.
    pub fn integration_detail_fire_focused(&mut self) {
        let Some(pid) = self.right_panel_active_pane_id().or(self.active) else {
            return;
        };
        let Some(Pane::IntegrationDetail(d)) = self.panes.get(pid) else {
            return;
        };
        let action_idx = d.cursor;
        crate::ui::integration_detail_view::fire_action(self, pid, action_idx);
    }
}
