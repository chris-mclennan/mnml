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
use crate::layout::PaneId;
use crate::pane::{IntegrationDetailPane, Pane};

impl App {
    /// Open (or refocus) the integration-detail pane for `id`. Hosts
    /// in the right panel by default (matches Outline / Diagnostics);
    /// falls back to a split in the active leaf when the right
    /// panel is closed.
    pub fn open_integration_detail_pane(&mut self, id: &str) {
        // Refuse silently if the id doesn't resolve to an installed
        // integration OR a fetched marketplace entry — toast a hint.
        // 2026-08-06 — was `integration_icons` only; extended to
        // include marketplace_entries so left-clicking a marketplace
        // row opens the detail pane instead of firing install.
        let known = self.config.ui.integration_icons.iter().any(|i| i.id == id)
            || self.marketplace_entries.iter().any(|e| e.id == id);
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
        // 2026-08-01 — was hosted in the right panel (narrow column).
        // User: "the integration page is showing up on right slide out
        // panel but should take the center like the http area does."
        // Host as a regular pane so it gets the full body area, tab
        // strip, drag-to-split behavior, and Ctrl+W close semantics
        // like every other center-hosted pane (Editor / Request / etc).
        let pane = Pane::IntegrationDetail(IntegrationDetailPane::new(id.to_string()));
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.reveal_pane(new_id);
    }

    /// Reveal an existing detail pane. Previously handled a right-
    /// panel branch; now that the detail pane lives in the center
    /// like any other pane, just delegate. (Kept the helper for
    /// callers instead of inlining `reveal_pane` at every open site.)
    fn reveal_or_bring_to_front(&mut self, pid: PaneId) {
        // Legacy: if a prior session left a copy of this pane in the
        // right panel, drop it there so we don't render twice — the
        // new center-hosted copy is the authoritative one.
        self.right_panel_panes.retain(|&p| p != pid);
        self.reveal_pane(pid);
    }

    /// #864 — snapshot the current in-memory rail order + persist
    /// via `discovery::persist_integration_icon_order`. Also
    /// updates the in-memory `integration_icon_order` field so
    /// subsequent renders + persists see the current order without
    /// waiting on a config reload. Called from every
    /// MoveIntegration{Up,Down,ToTop,ToBottom} handler.
    pub fn persist_integration_icon_order(&mut self) {
        let ids: Vec<String> = self
            .config
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.clone())
            .collect();
        self.config.ui.integration_icon_order.clone_from(&ids);
        if let Err(e) = crate::app::discovery::persist_integration_icon_order(&ids) {
            self.toast(format!("integration order: persist failed ({e})"));
        }
    }

    /// Flip enabled/disabled for the integration with `id`, toast,
    /// persist via `write_override_toml`. Same implementation as
    /// the right-click `ToggleIntegrationEnabled` handler — extracted
    /// so both call sites share behavior.
    ///
    /// #852 fix (2026-08-03) — used to route through
    /// `persist_integration_icons`, which writes
    /// `[[ui.integration_icon]]` blocks to config.toml. But since
    /// the 2026-08-01 config flip, `config::finalize` drops any
    /// raw entry whose id isn't in the pre-manifest builtin set
    /// (browser/claude_code/codex/http), so toggling any real
    /// marketplace-installed chip's enabled state silently
    /// evaporated on next launch. `write_override_toml` handles
    /// the manifest-backed case (writes `<id>.override.toml`) AND
    /// the no-base builtin case (promotes to an authored
    /// `<id>.toml`) — see da1ce2e3.
    pub fn toggle_integration_enabled_by_id(&mut self, id: &str) {
        let Some(slot_snapshot) = self
            .config
            .ui
            .integration_icons
            .iter_mut()
            .find(|i| i.id == id)
            .map(|slot| {
                slot.enabled = !slot.enabled;
                slot.clone()
            })
        else {
            return;
        };
        let now = slot_snapshot.enabled;
        self.toast(format!(
            "integration {id} {}",
            if now { "enabled" } else { "disabled" }
        ));
        if let Err(e) = crate::app::discovery::write_override_toml(&slot_snapshot) {
            self.toast(format!("integration: persist failed ({e})"));
        }
    }

    /// 2026-08-06 — flip `in_palette_bar` for `id` (top-bar
    /// visibility). Mirrors `toggle_integration_enabled_by_id`'s
    /// shape: mutate slot, snapshot, persist via
    /// `write_override_toml`. Toasts the new state.
    pub fn toggle_integration_palette_bar_by_id(&mut self, id: &str) {
        let Some(slot_snapshot) = self
            .config
            .ui
            .integration_icons
            .iter_mut()
            .find(|i| i.id == id)
            .map(|slot| {
                slot.in_palette_bar = !slot.in_palette_bar;
                slot.clone()
            })
        else {
            return;
        };
        let now = slot_snapshot.in_palette_bar;
        self.toast(format!(
            "integration {id} {} top bar",
            if now { "shown on" } else { "hidden from" }
        ));
        if let Err(e) = crate::app::discovery::write_override_toml(&slot_snapshot) {
            self.toast(format!("integration: persist failed ({e})"));
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
