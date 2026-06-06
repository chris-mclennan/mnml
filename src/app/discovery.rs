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
        // Best-effort TOML persistence so the chip survives a restart.
        // On failure we still report "added" but flag the persistence
        // error so the user can self-correct.
        match persist_integration_icons(&self.config.ui.integration_icons) {
            Ok(path) => self.toast(format!(
                "added {} to rail · persisted to {}",
                s.binary,
                path.display()
            )),
            Err(e) => self.toast(format!(
                "added {} to rail (runtime only — persist failed: {e})",
                s.binary
            )),
        }
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

/// Rewrite the `[[ui.integration_icon]]` section of the user's
/// `~/.config/mnml/config.toml` to reflect `icons`. Idempotent:
/// strips any existing `[[ui.integration_icon]]` blocks and replaces
/// them with the full new list. Other config sections + comments
/// (anything NOT inside an `[[ui.integration_icon]]` block) are
/// preserved verbatim.
///
/// Returns the path written on success.
pub fn persist_integration_icons(icons: &[IntegrationIcon]) -> Result<std::path::PathBuf, String> {
    let path = crate::config::user_config_path()
        .ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let stripped = strip_integration_icon_blocks(&existing);
    let appended = append_integration_icon_blocks(&stripped, icons);
    std::fs::write(&path, appended).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// Identifies our managed-section banner so the strip pass can
/// recognise it and remove it along with the blocks it heads.
const MANAGED_BANNER_MARKER: &str = "# ── mnml-managed integration icons";

/// Remove every existing `[[ui.integration_icon]]` block (and our
/// managed-section banner, if present) from `src`. Stops skipping when
/// it hits the next top-level `[…]` table header that isn't itself an
/// `[[ui.integration_icon]]`.
fn strip_integration_icon_blocks(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut skipping = false;
    let mut last_was_blank = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        // Banner is treated as the start of a managed section even
        // though it's a comment, so the strip can clean up after
        // itself across rewrites.
        if trimmed.starts_with(MANAGED_BANNER_MARKER) {
            skipping = true;
            continue;
        }
        if trimmed == "[[ui.integration_icon]]" {
            skipping = true;
            continue;
        }
        if skipping {
            if (trimmed.starts_with('[') && !trimmed.starts_with("[ "))
                && trimmed != "[[ui.integration_icon]]"
            {
                skipping = false;
            } else {
                continue;
            }
        }
        if line.trim().is_empty() {
            if last_was_blank {
                continue;
            }
            last_was_blank = true;
        } else {
            last_was_blank = false;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Append a full `[[ui.integration_icon]]` section for `icons` to
/// `existing`, including a banner comment so users can see it's
/// managed by mnml. Idempotent in combination with
/// [`strip_integration_icon_blocks`].
fn append_integration_icon_blocks(existing: &str, icons: &[IntegrationIcon]) -> String {
    let mut out = existing.trim_end().to_string();
    if !out.is_empty() {
        out.push_str("\n\n");
    }
    out.push_str("# ── mnml-managed integration icons ──────────────────────────────────\n");
    out.push_str("# Written by the `+ Add integration` overlay. Edit by hand or via the\n");
    out.push_str("# overlay — re-saves replace this section in place.\n\n");
    for ic in icons {
        out.push_str("[[ui.integration_icon]]\n");
        out.push_str(&format!("id = {}\n", toml_str(&ic.id)));
        out.push_str(&format!("glyph = {}\n", toml_str(&ic.glyph)));
        out.push_str(&format!("fallback = {}\n", toml_str(&ic.fallback)));
        out.push_str(&format!("command = {}\n", toml_str(&ic.command)));
        out.push_str(&format!("color = {}\n", toml_str(&ic.color)));
        if let Some(t) = &ic.tooltip {
            out.push_str(&format!("tooltip = {}\n", toml_str(t)));
        }
        out.push('\n');
    }
    out
}

/// TOML basic-string escape. Only handles the cases we emit
/// (printable ASCII, `\`, `"`); these are all that show up in
/// `IntegrationIcon` defaults plus user adds via the overlay.
fn toml_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            // Multibyte glyphs (nerd-font codepoints, emoji) survive verbatim.
            _ => out.push(c),
        }
    }
    out.push('"');
    out
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

    #[test]
    fn strip_removes_block_and_leaves_other_sections() {
        let src = "\
[ui]
ascii_icons = false

[[ui.integration_icon]]
id = \"lambda\"
glyph = \"x\"
fallback = \"L\"
command = \":host.launch mnml-aws-lambda\"
color = \"orange\"

[[ui.launcher_icon]]
id = \"claude\"
glyph = \"y\"
fallback = \"C\"
command = \":ai.claude_code\"
color = \"blue\"
";
        let out = strip_integration_icon_blocks(src);
        // Integration icon section is gone.
        assert!(!out.contains("integration_icon"));
        assert!(!out.contains("mnml-aws-lambda"));
        // Launcher icon section + ui table survive.
        assert!(out.contains("[[ui.launcher_icon]]"));
        assert!(out.contains("ascii_icons = false"));
    }

    #[test]
    fn append_writes_full_icon_list() {
        let icons = vec![
            IntegrationIcon {
                id: "lambda".to_string(),
                glyph: "x".to_string(),
                fallback: "L".to_string(),
                command: ":host.launch mnml-aws-lambda".to_string(),
                color: "orange".to_string(),
                tooltip: Some("Lambda".to_string()),
            },
            IntegrationIcon {
                id: "s3".to_string(),
                glyph: "y".to_string(),
                fallback: "S3".to_string(),
                command: ":host.launch mnml-fs-s3".to_string(),
                color: "orange".to_string(),
                tooltip: None,
            },
        ];
        let out = append_integration_icon_blocks("", &icons);
        let parsed: toml::Value = toml::from_str(&out).expect("roundtrips through toml::from_str");
        let array = parsed
            .get("ui")
            .and_then(|u| u.get("integration_icon"))
            .and_then(|a| a.as_array())
            .expect("integration_icon array present");
        assert_eq!(array.len(), 2);
    }

    #[test]
    fn strip_then_append_is_idempotent() {
        let icons = vec![IntegrationIcon {
            id: "lambda".to_string(),
            glyph: "x".to_string(),
            fallback: "L".to_string(),
            command: ":host.launch mnml-aws-lambda".to_string(),
            color: "orange".to_string(),
            tooltip: None,
        }];
        let first = append_integration_icon_blocks("", &icons);
        let stripped = strip_integration_icon_blocks(&first);
        let second = append_integration_icon_blocks(&stripped, &icons);
        assert_eq!(first, second);
    }

    #[test]
    fn toml_str_escapes_quotes_and_backslashes() {
        assert_eq!(toml_str("plain"), "\"plain\"");
        assert_eq!(toml_str("he said \"hi\""), "\"he said \\\"hi\\\"\"");
        assert_eq!(toml_str("c:\\path"), "\"c:\\\\path\"");
    }
}
