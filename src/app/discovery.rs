//! "+ Add integration" discovery overlay state + handlers.
//!
//! Opened by clicking the `+` chip on the sidebar's `> INTEGRATIONS`
//! header (or via `integrations.add` from the palette). Shows the
//! hardcoded family catalog (`crate::family_catalog::CATALOG`), with
//! each row tagged by install state:
//!
//!  - `InRail`       — binary installed AND already in `integration_icons`
//!  - `Installed`    — binary installed but not yet in the rail (Enter adds)
//!  - `NotInstalled` — binary not detected (i installs, y yanks)
//!
//! Renderer at `src/ui/discovery_overlay.rs`. Key dispatch hooked
//! from `src/tui.rs` (Esc/Enter/i/y/↑/↓).
//!
//! v1: in-memory mutation only. Adding a row pushes onto
//! `config.ui.integration_icons` for this session; on next launch
//! the user's TOML wins. Persistence is a v2 follow-up. The toast
//! that fires after `Add to rail` flags this.

use crate::app::App;
use crate::config::IntegrationIcon;
use crate::family_catalog::{self, FamilySibling};

/// `None` on `App.discovery_overlay` ⇒ overlay closed.
#[derive(Debug)]
pub struct DiscoveryOverlayState {
    /// 0-indexed selection over `rows()` length — but skipping the
    /// section-header pseudo-rows. We re-derive the visible-rows list
    /// on every key/render so user-installed siblings that were just
    /// added flip to `InRail` immediately.
    pub selected_row: usize,
}

impl DiscoveryOverlayState {
    pub fn open() -> Self {
        Self { selected_row: 0 }
    }
}

/// Per-catalog-entry render shape, computed fresh on each frame so
/// install-state changes (after the user runs `i`) are reflected
/// without an explicit refresh step.
#[derive(Debug, Clone)]
pub enum DiscoveryItem {
    Section(&'static str),
    Sibling {
        sibling: &'static FamilySibling,
        status: SiblingStatus,
    },
}

impl DiscoveryItem {
    pub fn is_row(&self) -> bool {
        matches!(self, DiscoveryItem::Sibling { .. })
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum SiblingStatus {
    InRail,
    Installed,
    NotInstalled,
}

/// Compute the visible row list. Section headers are emitted between
/// category boundaries; siblings within a category preserve catalog
/// order.
pub fn build_items(app: &App) -> Vec<DiscoveryItem> {
    let mut out = Vec::with_capacity(family_catalog::CATALOG.len() + 8);
    let mut last_category: Option<&'static str> = None;
    for sibling in family_catalog::CATALOG {
        let header = sibling.category.header();
        if last_category != Some(header) {
            out.push(DiscoveryItem::Section(header));
            last_category = Some(header);
        }
        out.push(DiscoveryItem::Sibling {
            sibling,
            status: status_for(app, sibling),
        });
    }
    out
}

fn status_for(app: &App, s: &FamilySibling) -> SiblingStatus {
    let installed = crate::integration_detect::is_binary_installed(s.binary);
    if !installed {
        return SiblingStatus::NotInstalled;
    }
    let launch = s.launch_command();
    let already_in_rail = app
        .config
        .ui
        .integration_icons
        .iter()
        .any(|ic| ic.id == s.id || ic.command == launch);
    if already_in_rail {
        SiblingStatus::InRail
    } else {
        SiblingStatus::Installed
    }
}

impl App {
    pub fn open_discovery_overlay(&mut self) {
        // Refresh detection cache on open so a binary the user just
        // installed (outside mnml) shows as installed without needing
        // a separate `integrations.refresh`.
        crate::integration_detect::clear_cache();
        self.discovery_overlay = Some(DiscoveryOverlayState::open());
    }

    pub fn close_discovery_overlay(&mut self) {
        self.discovery_overlay = None;
    }

    pub fn discovery_move_row(&mut self, delta: isize) {
        let items = build_items(self);
        let row_count = items.iter().filter(|i| i.is_row()).count();
        if row_count == 0 {
            return;
        }
        if let Some(state) = self.discovery_overlay.as_mut() {
            let new = (state.selected_row as isize + delta).rem_euclid(row_count as isize);
            state.selected_row = new as usize;
        }
    }

    /// The catalog entry under the current selection cursor, paired
    /// with its status — returns `None` if the overlay isn't open or
    /// the row index is out of range.
    pub fn discovery_focused(&self) -> Option<(&'static FamilySibling, SiblingStatus)> {
        let state = self.discovery_overlay.as_ref()?;
        let items = build_items(self);
        let mut row_idx = 0usize;
        for item in &items {
            if let DiscoveryItem::Sibling { sibling, status } = item {
                if row_idx == state.selected_row {
                    return Some((sibling, *status));
                }
                row_idx += 1;
            }
        }
        None
    }

    /// Enter on a row dispatches by status:
    /// - `InRail` → toast "already in rail"
    /// - `Installed` → add to rail config (in-memory; persistence is v2)
    /// - `NotInstalled` → toast hint to press `i` or `y`
    pub fn discovery_enter(&mut self) {
        let Some((sibling, status)) = self.discovery_focused() else {
            return;
        };
        match status {
            SiblingStatus::InRail => {
                self.toast(format!("{} already in rail", sibling.binary));
            }
            SiblingStatus::Installed => {
                self.discovery_add_to_rail(sibling);
            }
            SiblingStatus::NotInstalled => {
                self.toast(format!(
                    "{} not installed — press i to install or y to copy command",
                    sibling.binary
                ));
            }
        }
    }

    fn discovery_add_to_rail(&mut self, s: &FamilySibling) {
        // Reject re-adds (defensive — discovery_enter already checks).
        let launch = s.launch_command();
        if self
            .config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == s.id || ic.command == launch)
        {
            self.toast(format!("{} already in rail", s.binary));
            return;
        }
        self.config.ui.integration_icons.push(IntegrationIcon {
            id: s.id.to_string(),
            glyph: s.icon.glyph.to_string(),
            fallback: s.icon.fallback.to_string(),
            command: launch,
            color: s.icon.color.to_string(),
            tooltip: Some(s.icon.tooltip.to_string()),
        });
        self.toast(format!(
            "added {} to rail (runtime only — add to ~/.config/mnml/config.toml to persist)",
            s.binary
        ));
    }

    /// `y` — copy the `cargo install` command for the focused row.
    pub fn discovery_yank_install(&mut self) {
        let Some((sibling, _)) = self.discovery_focused() else {
            return;
        };
        let cmd = sibling.install_command();
        let mut clip = crate::clipboard::Clipboard::new();
        clip.set(cmd.clone(), false);
        self.toast(format!("copied: {}", cmd));
    }

    /// `i` — spawn a Pty pane running `cargo install --git <url> --tag <ver>`
    /// for the focused row. The user watches install progress live; once
    /// `cargo` exits cleanly the binary lands in `~/.cargo/bin` and is
    /// picked up by the next `open_discovery_overlay` (which clears the
    /// detection cache).
    ///
    /// Closes the discovery overlay — the user wants to *see* the install
    /// output, not have it bury behind the picker.
    pub fn discovery_install_selected(&mut self) {
        let Some((sibling, _)) = self.discovery_focused() else {
            return;
        };
        let profile = crate::pty_pane::BinaryProfile {
            label: format!("install: {}", sibling.binary),
            exe: "cargo".to_string(),
            args: vec![
                "install".to_string(),
                "--git".to_string(),
                sibling.repo_url.to_string(),
                "--tag".to_string(),
                sibling.pinned_version.to_string(),
                sibling.binary.to_string(),
            ],
            cwd: None,
            env: vec![],
            session_id: None,
        };
        // Close overlay first so the new Pty pane has the screen real
        // estate. The detection cache is cleared on next open of the
        // overlay (or via `integrations.refresh`).
        self.close_discovery_overlay();
        self.open_pty(profile);
        self.toast(format!(
            "installing {} — watch the pty pane; re-open + when done",
            sibling.binary
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_item_is_row_predicate() {
        assert!(!DiscoveryItem::Section("AWS").is_row());
        let s = family_catalog::CATALOG.first().expect("catalog non-empty");
        let item = DiscoveryItem::Sibling {
            sibling: s,
            status: SiblingStatus::NotInstalled,
        };
        assert!(item.is_row());
    }

    #[test]
    fn overlay_state_starts_at_row_zero() {
        let s = DiscoveryOverlayState::open();
        assert_eq!(s.selected_row, 0);
    }
}
