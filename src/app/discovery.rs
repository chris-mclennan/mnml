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
use crate::family_catalog::{self, SiblingRef};

/// `None` on `App.discovery_overlay` ⇒ overlay closed.
#[derive(Debug)]
pub struct DiscoveryOverlayState {
    /// 0-indexed selection over `rows()` length — but skipping the
    /// section-header pseudo-rows. We re-derive the visible-rows list
    /// on every key/render so user-installed siblings that were just
    /// added flip to `InRail` immediately.
    pub selected_row: usize,
    /// When `Some`, the integration edit panel is layered over the
    /// discovery overlay; all key input routes there until the user
    /// saves (Enter) or cancels (Esc). `e` on an `InRail` row opens
    /// it in `Edit` mode; selecting the `[+ Add custom integration]`
    /// row at the top opens it in `AddCustom` mode.
    pub edit_panel: Option<IntegrationEditState>,
    /// Which view is showing — `Installed` shows only siblings
    /// you've installed (and the `+ Add custom` row), `Marketplace`
    /// shows the full catalog (everything you could install). User
    /// flips via the chips at the top of the overlay. Default is
    /// Installed because that's what you most often want to act on
    /// (open / configure / pin to rail).
    pub tab: DiscoveryTab,
}

/// View modes for the integrations discovery overlay.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
pub enum DiscoveryTab {
    /// Only siblings whose binary is on PATH. Lets users see what's
    /// active without scrolling through the full catalog.
    #[default]
    Installed,
    /// Full catalog — everything offered by the family + any
    /// discovered uncataloged tools. The "browse what's available"
    /// view.
    Marketplace,
}

impl DiscoveryTab {
    pub fn toggled(self) -> Self {
        match self {
            DiscoveryTab::Installed => DiscoveryTab::Marketplace,
            DiscoveryTab::Marketplace => DiscoveryTab::Installed,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            DiscoveryTab::Installed => "Installed",
            DiscoveryTab::Marketplace => "Marketplace",
        }
    }
}

impl DiscoveryOverlayState {
    pub fn open() -> Self {
        Self {
            selected_row: 0,
            edit_panel: None,
            tab: DiscoveryTab::default(),
        }
    }
}

/// In-flight edit of a `[[ui.integration_icon]]` entry. Owns the
/// per-field state + the focus cursor so the renderer can paint a
/// `▸` next to the focused field, family-Settings-row style.
#[derive(Debug, Clone)]
pub struct IntegrationEditState {
    pub mode: IntegrationEditMode,
    /// Stable id — required, must be unique across the config's
    /// existing icons. Read-only in `Edit` mode (you can't rename
    /// an existing integration without confusing the persistence
    /// path); editable in `AddCustom`.
    pub id: String,
    /// Command to run when the icon is clicked. Same format as
    /// `IntegrationIcon.command` — a registered command id or a
    /// `:colon-prefixed` ex-command. Editable only in `AddCustom`.
    pub command: String,
    /// The on-glyph — any single char (or short string for codepoints
    /// pasted as escape sequences). Free-form text input.
    pub glyph: String,
    /// What renders when the user's font lacks the glyph above —
    /// typically a 1-3 char ASCII / simple-Unicode fallback.
    pub fallback: String,
    /// Theme color name (`orange` / `cyan` / `purple` / …). Cycled
    /// with ←→ from a fixed palette.
    pub color: String,
    /// Hover tooltip shown by the bufferline chip.
    pub tooltip: String,
    /// Which field has the input cursor.
    pub focused_field: IntegrationEditField,
}

/// Whether the panel is editing an existing entry or adding a fresh
/// one. The `Edit` variant carries the id of the entry being edited
/// so the save path can locate + replace it (or persist back to the
/// catalog override).
#[derive(Debug, Clone)]
pub enum IntegrationEditMode {
    Edit,
    AddCustom,
}

/// Per-field focus marker for `IntegrationEditState`. `Id` and
/// `Command` are skipped while focused on an existing edit (their
/// state still lives in the struct but the renderer paints them
/// `[fixed]` and the key handler skips them on Tab).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegrationEditField {
    Id,
    Command,
    Glyph,
    Fallback,
    Color,
    Tooltip,
}

/// Closed-form color palette the `Color` field cycles through.
/// Names map onto the same vocabulary the live `parse_color` path
/// accepts via the existing `IntegrationIcon.color` field; the
/// order matches the family-Settings ROYGBIV-ish reading order.
pub const INTEGRATION_EDIT_COLORS: &[&str] = &[
    "fg", "dim", "red", "orange", "yellow", "green", "cyan", "blue", "purple",
];

/// Per-catalog-entry render shape, computed fresh on each frame so
/// install-state changes (after the user runs `i`) are reflected
/// without an explicit refresh step.
///
/// `Sibling` now holds a `SiblingRef` rather than a static catalog
/// pointer — so auto-discovered installs surface in the overlay
/// alongside the hardcoded family.
#[derive(Debug, Clone)]
pub enum DiscoveryItem {
    Section(&'static str),
    Sibling {
        sibling: SiblingRef,
        status: SiblingStatus,
    },
    /// Synthetic top-of-list affordance — `[+ Add custom integration]`.
    /// Enter on this row opens the edit panel in AddCustom mode (same
    /// path the `a` chord uses). Always the first navigable row so the
    /// user sees an obvious entry point even when the rail is full.
    AddCustom,
}

impl DiscoveryItem {
    pub fn is_row(&self) -> bool {
        matches!(
            self,
            DiscoveryItem::Sibling { .. } | DiscoveryItem::AddCustom
        )
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum SiblingStatus {
    InRail,
    Installed,
    NotInstalled,
}

/// Compute the visible row list. Section headers emit between
/// category boundaries; siblings within a category preserve catalog
/// order, with auto-discovered (community) siblings appended at the
/// end of each section.
pub fn build_items(app: &App) -> Vec<DiscoveryItem> {
    // Hardcoded catalog entries, wrapped as `SiblingRef::Catalog`.
    // 2026-06-26 — `is_private()` entries (currently all Tattle
    // category) are filtered out: their repos are private and the
    // catalog is compiled into every public mnml binary. Owners
    // install via direct `cargo install --git <ssh>` outside the
    // overlay.
    let catalog_refs: Vec<SiblingRef> = family_catalog::CATALOG
        .iter()
        .filter(|s| !s.is_private())
        .map(SiblingRef::Catalog)
        .collect();
    // Auto-discovered entries — already filtered to exclude anything
    // that's also in the catalog (so we don't double-list shipped
    // siblings the user happens to have installed).
    let discovered_refs: Vec<SiblingRef> = family_catalog::discover_uncataloged()
        .into_iter()
        .map(SiblingRef::Discovered)
        .collect();

    // Group both into a single Vec keyed by category so the renderer
    // gets one section per category with catalog rows first, then
    // auto-discovered rows.
    let mut by_category: std::collections::BTreeMap<&'static str, Vec<SiblingRef>> =
        std::collections::BTreeMap::new();
    for r in catalog_refs.into_iter().chain(discovered_refs) {
        by_category
            .entry(r.category().header())
            .or_default()
            .push(r);
    }
    // Stable section order: the order categories first appear in the
    // catalog, then any "Other" / community-only categories appended.
    let mut section_order: Vec<&'static str> = Vec::new();
    for s in family_catalog::CATALOG {
        let header = s.category.header();
        if !section_order.contains(&header) {
            section_order.push(header);
        }
    }
    for header in by_category.keys() {
        if !section_order.contains(header) {
            section_order.push(header);
        }
    }

    // 2026-06-27 — when the user is on the Installed tab, filter
    // out anything they haven't installed. Marketplace tab shows
    // everything (the catalog browser).
    let tab = app
        .discovery_overlay
        .as_ref()
        .map(|o| o.tab)
        .unwrap_or_default();
    let mut out = Vec::with_capacity(family_catalog::CATALOG.len() + 8);
    // `[+ Add custom integration]` lives at the very top so the
    // affordance is impossible to miss. Enter on this row opens the
    // edit panel in AddCustom mode (same path the `a` chord uses).
    out.push(DiscoveryItem::AddCustom);
    for header in section_order {
        let Some(rows) = by_category.get(header) else {
            continue;
        };
        if rows.is_empty() {
            continue;
        }
        // For the Installed tab, drop sections whose rows are all
        // not-installed; otherwise we'd render empty section headers.
        let visible_rows: Vec<&SiblingRef> = rows
            .iter()
            .filter(|r| match tab {
                DiscoveryTab::Marketplace => true,
                DiscoveryTab::Installed => {
                    let st = status_for(app, r);
                    matches!(st, SiblingStatus::Installed | SiblingStatus::InRail)
                }
            })
            .collect();
        if visible_rows.is_empty() {
            continue;
        }
        out.push(DiscoveryItem::Section(header));
        for r in visible_rows {
            let status = status_for(app, r);
            out.push(DiscoveryItem::Sibling {
                sibling: r.clone(),
                status,
            });
        }
    }
    out
}

fn status_for(app: &App, s: &SiblingRef) -> SiblingStatus {
    // Built-in catalog entries (e.g. the HTTP client) are always
    // installed — they ship with mnml core, no PATH probe needed.
    let installed = if s.is_builtin() {
        true
    } else {
        crate::integration_detect::is_binary_installed(s.binary())
    };
    if !installed {
        return SiblingStatus::NotInstalled;
    }
    let launch = s.launch_command();
    let already_in_rail = app
        .config
        .ui
        .integration_icons
        .iter()
        .any(|ic| ic.id == s.id() || ic.command == launch);
    if already_in_rail {
        SiblingStatus::InRail
    } else {
        SiblingStatus::Installed
    }
}

impl App {
    pub fn open_discovery_overlay(&mut self) {
        // Refresh detection caches on open so a binary the user just
        // installed (outside mnml) shows as installed without needing
        // a separate `integrations.refresh`. `clear_all_caches` also
        // drops the auto-discovery cache so a newly-installed
        // community sibling appears immediately.
        crate::integration_detect::clear_all_caches();
        self.discovery_overlay = Some(DiscoveryOverlayState::open());
    }

    /// Flip the Integrations overlay between Installed and
    /// Marketplace views. Triggered by the `t` key while the
    /// overlay is open, by clicking the chips, or via
    /// `:integrations.toggle_tab`.
    pub fn discovery_toggle_tab(&mut self) {
        if let Some(o) = self.discovery_overlay.as_mut() {
            o.tab = o.tab.toggled();
            o.selected_row = 0;
        }
    }

    pub fn close_discovery_overlay(&mut self) {
        self.discovery_overlay = None;
    }

    /// Open the integration-edit panel for the integration with the
    /// given id. Surfaced from the chip's right-click context menu
    /// so users can tweak a chip without going through the discovery
    /// overlay first. Opens the discovery overlay if it isn't
    /// already open — the edit panel lives layered on top of it.
    pub fn open_integration_edit_by_id(&mut self, id: &str) {
        let icon = self
            .config
            .ui
            .integration_icons
            .iter()
            .find(|ic| ic.id == id)
            .cloned();
        let Some(icon) = icon else {
            self.toast(format!("integration: {id} not in rail"));
            return;
        };
        if self.discovery_overlay.is_none() {
            self.open_discovery_overlay();
        }
        if let Some(state) = self.discovery_overlay.as_mut() {
            state.edit_panel = Some(IntegrationEditState {
                mode: IntegrationEditMode::Edit,
                id: icon.id,
                command: icon.command,
                glyph: icon.glyph,
                fallback: icon.fallback,
                color: icon.color,
                tooltip: icon.tooltip.unwrap_or_default(),
                focused_field: IntegrationEditField::Glyph,
            });
        }
    }

    /// Pop the "patch nerd font with this SVG" prompt — the user
    /// types an SVG file path, the accept handler runs the
    /// `scripts/patch_nerd_font.py` shell-out, the result toasts
    /// + copies the assigned codepoint to the clipboard for paste
    /// into the integration edit panel's Glyph field.
    pub fn open_patch_nerd_font_svg_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::PatchNerdFontSvg,
            "SVG file path to bake into Nerd Font:".to_string(),
        ));
    }

    /// Pick the next free PUA codepoint at or above U+F300 by
    /// scanning every currently-configured integration / launcher
    /// glyph for collisions. The script's own range comment notes
    /// U+F300+ is the recommended user-add range, well clear of
    /// Nerd Fonts' own `nf-*` glyphs.
    fn next_free_pua_codepoint(&self) -> Option<u32> {
        let mut taken: std::collections::HashSet<u32> = std::collections::HashSet::new();
        for ic in &self.config.ui.integration_icons {
            if let Some(c) = ic.glyph.chars().next() {
                taken.insert(c as u32);
            }
        }
        for li in &self.config.ui.launcher_icons {
            if let Some(c) = li.glyph.chars().next() {
                taken.insert(c as u32);
            }
        }
        // Walk U+F300 → U+F8FF (end of the BMP Private Use Area).
        // The script's docstring + the U+F300+ user-add convention
        // both end here; past F8FF we cross into CJK Compatibility
        // Ideographs which is a real Unicode block, not user space.
        // Returning `None` when the range is exhausted lets the
        // caller toast a meaningful error instead of patching an
        // out-of-range codepoint.
        let mut cp = 0xF300u32;
        while cp <= 0xF8FF {
            if !taken.contains(&cp) {
                return Some(cp);
            }
            cp += 1;
        }
        None
    }

    /// Spawn the patch script. Picks the next free PUA codepoint,
    /// runs `fontforge -script scripts/patch_nerd_font.py …` via
    /// shell, and toasts the result. The patched font lands at the
    /// `--output` path the script chose; the user has to install it
    /// in Font Book (or copy to `~/Library/Fonts/`) for the new
    /// glyph to render. The assigned codepoint is yanked to the
    /// clipboard so the user can paste it into the Glyph field of
    /// the integration edit panel.
    pub fn run_patch_nerd_font_svg(&mut self, svg: &str) {
        let svg = svg.trim();
        if svg.is_empty() {
            self.toast("svg path can't be empty");
            return;
        }
        let svg_path = std::path::PathBuf::from(svg);
        if !svg_path.exists() {
            self.toast(format!("svg not found: {}", svg_path.display()));
            return;
        }
        let Some(cp) = self.next_free_pua_codepoint() else {
            self.toast("PUA range U+F300–F8FF exhausted — remove an integration first");
            return;
        };
        // Default in/out font paths — same convention as the
        // existing Claude/Codex shipped patch. User can re-run the
        // script by hand if they want a different output path.
        let home = match std::env::var_os("HOME") {
            Some(h) => std::path::PathBuf::from(h),
            None => {
                self.toast("HOME unset — can't resolve font paths");
                return;
            }
        };
        let font_in = home.join("Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf");
        let font_out = home.join("Library/Fonts/JetBrainsMonoNerdFont-Regular-mnml.ttf");
        if !font_in.exists() {
            self.toast(format!(
                "font not found: {} — install JetBrainsMono Nerd Font first",
                font_in.display()
            ));
            return;
        }
        // Script lives at <repo>/scripts/patch_nerd_font.py — locate
        // by walking up from the binary's dir. For installed mnml
        // this won't be the source tree; toast a hint.
        let script = match std::env::current_exe()
            .ok()
            .and_then(|p| {
                // walk up looking for scripts/patch_nerd_font.py
                let mut cur = p;
                while cur.pop() {
                    let cand = cur.join("scripts/patch_nerd_font.py");
                    if cand.exists() {
                        return Some(cand);
                    }
                }
                None
            })
            .or_else(|| {
                // fall back to ~/Projects/mnml — the dev path
                let cand = home.join("Projects/mnml/scripts/patch_nerd_font.py");
                if cand.exists() { Some(cand) } else { None }
            }) {
            Some(p) => p,
            None => {
                self.toast(
                    "patch_nerd_font.py not found — clone mnml source tree to use this command",
                );
                return;
            }
        };
        // Eagerly copy the literal glyph character to the clipboard
        // (NOT a Rust `\u{...}` escape — TOML rejects that syntax).
        // The script writes the same codepoint, so by the time the
        // user pastes into the Glyph field, the patched font + the
        // clipboard agree. char::from_u32 on a PUA codepoint always
        // succeeds (the PUA is a defined block) so the unwrap is
        // safe in practice; defensive fallback prints `U+XXXX` for
        // any non-char codepoint that might slip in via a config
        // edit.
        let glyph_str = char::from_u32(cp)
            .map(|c| c.to_string())
            .unwrap_or_else(|| format!("U+{cp:X}"));
        {
            let mut clip = crate::clipboard::Clipboard::new();
            clip.set(glyph_str.clone(), false);
        }
        // Spawn fontforge in a Pty pane so the user can watch
        // progress without freezing the TUI render loop. FontForge
        // can take 2-5 seconds on a Nerd Font and was blocking the
        // editor frame in the synchronous version.
        let glyph_name = format!("custom_{cp:04x}");
        let glyph_spec = format!("{}:{cp:X}:{glyph_name}", svg_path.display());
        let profile = crate::pty_pane::BinaryProfile {
            label: format!("patch font: U+{cp:X}"),
            exe: "fontforge".to_string(),
            args: vec![
                "-script".to_string(),
                script.to_string_lossy().into_owned(),
                "--font".to_string(),
                font_in.to_string_lossy().into_owned(),
                "--output".to_string(),
                font_out.to_string_lossy().into_owned(),
                "--glyph".to_string(),
                glyph_spec,
            ],
            cwd: None,
            env: vec![],
            session_id: None,
        };
        // Mirror the install-flow pattern at line 920: close the
        // discovery overlay before splitting so the new Pty isn't
        // hidden under the still-painted overlay. The reachable
        // case is "user opens the SVG prompt from inside the
        // overlay" (vs the palette path, where the overlay isn't
        // open) — second-pass reviewer caught this.
        self.close_discovery_overlay();
        self.open_pty(profile);
        self.toast(format!(
            "patching · glyph copied · install {} after fontforge exits, then paste",
            font_out.file_name().unwrap_or_default().to_string_lossy()
        ));
    }

    /// Drop the integration with the given id from the rail and
    /// persist to TOML. Surfaced from the chip right-click menu's
    /// "Remove from rail" entry.
    pub fn remove_integration_by_id(&mut self, id: &str) {
        let before = self.config.ui.integration_icons.len();
        self.config.ui.integration_icons.retain(|ic| ic.id != id);
        if self.config.ui.integration_icons.len() == before {
            self.toast(format!("integration: {id} not in rail"));
            return;
        }
        match persist_integration_icons(&self.config.ui.integration_icons) {
            Ok(_) => self.toast(format!("removed {id} from rail")),
            Err(e) => self.toast(format!("removed in-memory (persist failed: {e})")),
        }
    }

    /// Open the integration-edit panel for the row currently focused
    /// in the discovery overlay. No-op when the overlay isn't open
    /// or the focused row isn't an `InRail` sibling (only rail
    /// entries are editable — `Installed`/`NotInstalled` aren't in
    /// the config yet). Pressed via `e` in the overlay key handler.
    pub fn open_integration_edit_from_focused(&mut self) {
        let Some((sibling, status)) = self.discovery_focused() else {
            return;
        };
        if status != SiblingStatus::InRail {
            return;
        }
        let id = sibling.id();
        let icon = self
            .config
            .ui
            .integration_icons
            .iter()
            .find(|ic| ic.id == id)
            .cloned();
        let Some(icon) = icon else {
            return;
        };
        if let Some(state) = self.discovery_overlay.as_mut() {
            state.edit_panel = Some(IntegrationEditState {
                mode: IntegrationEditMode::Edit,
                id: icon.id,
                command: icon.command,
                glyph: icon.glyph,
                fallback: icon.fallback,
                color: icon.color,
                tooltip: icon.tooltip.unwrap_or_default(),
                focused_field: IntegrationEditField::Glyph,
            });
        }
    }

    /// Open the integration-edit panel in `AddCustom` mode. Fields
    /// start blank; user fills in id + command + glyph + color +
    /// fallback + tooltip and saves. Triggered by the `[+ Add custom
    /// integration]` row at the top of the discovery overlay.
    pub fn open_integration_edit_add_custom(&mut self) {
        if let Some(state) = self.discovery_overlay.as_mut() {
            state.edit_panel = Some(IntegrationEditState {
                mode: IntegrationEditMode::AddCustom,
                id: String::new(),
                command: String::new(),
                glyph: String::new(),
                fallback: String::new(),
                color: "fg".to_string(),
                tooltip: String::new(),
                focused_field: IntegrationEditField::Id,
            });
        }
    }

    /// Close the edit panel without saving. Esc binding inside the
    /// panel; also called when the overlay itself is dismissed.
    pub fn integration_edit_cancel(&mut self) {
        if let Some(state) = self.discovery_overlay.as_mut() {
            state.edit_panel = None;
        }
    }

    /// Commit the edit panel's current field values to
    /// `config.ui.integration_icons` + persist to TOML. Returns
    /// without saving when the panel state is invalid (empty id in
    /// AddCustom, empty glyph, etc.) — toasts the reason so the user
    /// can fix it without losing the in-flight edit. Closes the
    /// panel on success.
    pub fn integration_edit_save(&mut self) {
        let Some(state) = self.discovery_overlay.as_ref() else {
            return;
        };
        let Some(panel) = state.edit_panel.as_ref().cloned() else {
            return;
        };
        // Validation — same rules the config parser enforces so we
        // can't write a TOML the next load would reject.
        let id = panel.id.trim();
        let command = panel.command.trim();
        let glyph = panel.glyph.trim();
        if id.is_empty() {
            self.toast("integration: id can't be empty");
            return;
        }
        if command.is_empty() {
            self.toast("integration: command can't be empty");
            return;
        }
        if glyph.is_empty() {
            self.toast("integration: glyph can't be empty");
            return;
        }
        // Build the IntegrationIcon — `tooltip` is Option<String>
        // (the existing struct); empty input collapses back to None.
        let new_icon = IntegrationIcon {
            id: id.to_string(),
            glyph: glyph.to_string(),
            fallback: if panel.fallback.trim().is_empty() {
                glyph.to_string()
            } else {
                panel.fallback.trim().to_string()
            },
            command: command.to_string(),
            color: panel.color.trim().to_string(),
            tooltip: if panel.tooltip.trim().is_empty() {
                None
            } else {
                Some(panel.tooltip.trim().to_string())
            },
            // User-added chips via the discovery overlay default
            // to enabled — the act of clicking "Add" is the opt-in.
            enabled: true,
        };
        match panel.mode {
            IntegrationEditMode::Edit => {
                // Replace in place. The save panel can't change the
                // id, so we match by the captured id directly.
                if let Some(slot) = self
                    .config
                    .ui
                    .integration_icons
                    .iter_mut()
                    .find(|ic| ic.id == new_icon.id)
                {
                    *slot = new_icon;
                } else {
                    self.toast(format!("integration: {} no longer in rail", new_icon.id));
                    return;
                }
            }
            IntegrationEditMode::AddCustom => {
                if self
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .any(|ic| ic.id == new_icon.id)
                {
                    self.toast(format!("integration: id {} already in rail", new_icon.id));
                    return;
                }
                self.config.ui.integration_icons.push(new_icon);
            }
        }
        match persist_integration_icons(&self.config.ui.integration_icons) {
            Ok(path) => self.toast(format!("integration saved · {}", path.display())),
            Err(e) => self.toast(format!("integration saved in-memory (persist failed: {e})")),
        }
        if let Some(state) = self.discovery_overlay.as_mut() {
            state.edit_panel = None;
        }
    }

    /// Tab → move focus to the next field. `delta = 1` for forward,
    /// `-1` for backward (Shift+Tab). Skips `Id` / `Command` when
    /// the panel is in `Edit` mode (those fields are read-only).
    pub fn integration_edit_cycle_field(&mut self, delta: isize) {
        use IntegrationEditField::*;
        let order_full = [Id, Command, Glyph, Fallback, Color, Tooltip];
        let order_edit = [Glyph, Fallback, Color, Tooltip];
        let Some(state) = self.discovery_overlay.as_mut() else {
            return;
        };
        let Some(panel) = state.edit_panel.as_mut() else {
            return;
        };
        let order: &[IntegrationEditField] = match panel.mode {
            IntegrationEditMode::Edit => &order_edit,
            IntegrationEditMode::AddCustom => &order_full,
        };
        let Some(cur) = order.iter().position(|f| *f == panel.focused_field) else {
            return;
        };
        let n = order.len() as isize;
        let next = ((cur as isize + delta).rem_euclid(n)) as usize;
        panel.focused_field = order[next];
    }

    /// ←→ cycle the Color field through `INTEGRATION_EDIT_COLORS`.
    /// `delta = 1` for forward, `-1` for backward. No-op when the
    /// focused field isn't `Color`.
    pub fn integration_edit_color_cycle(&mut self, delta: isize) {
        let Some(state) = self.discovery_overlay.as_mut() else {
            return;
        };
        let Some(panel) = state.edit_panel.as_mut() else {
            return;
        };
        if panel.focused_field != IntegrationEditField::Color {
            return;
        }
        let n = INTEGRATION_EDIT_COLORS.len() as isize;
        let cur = INTEGRATION_EDIT_COLORS
            .iter()
            .position(|c| *c == panel.color)
            .unwrap_or(0) as isize;
        let next = (cur + delta).rem_euclid(n) as usize;
        panel.color = INTEGRATION_EDIT_COLORS[next].to_string();
    }

    /// Append a character to the focused text field. No-op when the
    /// focused field is `Color` (cycled with arrows, not typed) or
    /// when the panel is closed. The `Glyph` field accepts only the
    /// first char of the input (so a paste of multiple chars trims).
    pub fn integration_edit_type_char(&mut self, ch: char) {
        let Some(state) = self.discovery_overlay.as_mut() else {
            return;
        };
        let Some(panel) = state.edit_panel.as_mut() else {
            return;
        };
        let buf: &mut String = match panel.focused_field {
            IntegrationEditField::Id => &mut panel.id,
            IntegrationEditField::Command => &mut panel.command,
            IntegrationEditField::Glyph => &mut panel.glyph,
            IntegrationEditField::Fallback => &mut panel.fallback,
            IntegrationEditField::Tooltip => &mut panel.tooltip,
            IntegrationEditField::Color => return,
        };
        // Hard cap on field length so an unbounded paste can't blow
        // the panel render off-screen. 64 chars covers any
        // reasonable tooltip / command. Glyph specifically caps at
        // one to keep the chip a single cell.
        let cap = if matches!(panel.focused_field, IntegrationEditField::Glyph) {
            1
        } else {
            64
        };
        if buf.chars().count() >= cap {
            return;
        }
        buf.push(ch);
    }

    /// Backspace — delete one char from the focused field.
    pub fn integration_edit_backspace(&mut self) {
        let Some(state) = self.discovery_overlay.as_mut() else {
            return;
        };
        let Some(panel) = state.edit_panel.as_mut() else {
            return;
        };
        let buf: &mut String = match panel.focused_field {
            IntegrationEditField::Id => &mut panel.id,
            IntegrationEditField::Command => &mut panel.command,
            IntegrationEditField::Glyph => &mut panel.glyph,
            IntegrationEditField::Fallback => &mut panel.fallback,
            IntegrationEditField::Tooltip => &mut panel.tooltip,
            IntegrationEditField::Color => return,
        };
        buf.pop();
    }

    pub fn discovery_move_row(&mut self, delta: isize) {
        let items = build_items(self);
        let row_count = items.iter().filter(|i| i.is_row()).count();
        if row_count == 0 {
            return;
        }
        if let Some(state) = self.discovery_overlay.as_mut() {
            // Clamp at the boundaries — was `rem_euclid` which wrapped
            // around. The wrap surfaced as a user-reported "scroll back
            // to the top" bug: wheel-scrolling down past the last row
            // jumped selected_row to 0, the viewport recentered at the
            // top, and any subsequent click landed on whatever was now
            // visible there. Clamp keeps the cursor pinned at the
            // bottom (or top) edge instead. Keyboard ↑/↓ get the same
            // change; wrap-around in overlay lists is uncommon vs
            // clamp.
            let new = (state.selected_row as isize + delta).clamp(0, row_count as isize - 1);
            state.selected_row = new as usize;
        }
    }

    /// The sibling under the current selection cursor, paired with its
    /// status — returns `None` if the overlay isn't open OR the focused
    /// row is the `AddCustom` synthetic (caller uses
    /// [`Self::discovery_focused_is_add_custom`] for that case) OR the
    /// row index is out of range.
    pub fn discovery_focused(&self) -> Option<(SiblingRef, SiblingStatus)> {
        let state = self.discovery_overlay.as_ref()?;
        let items = build_items(self);
        let mut row_idx = 0usize;
        for item in &items {
            match item {
                DiscoveryItem::Sibling { sibling, status } => {
                    if row_idx == state.selected_row {
                        return Some((sibling.clone(), *status));
                    }
                    row_idx += 1;
                }
                DiscoveryItem::AddCustom => {
                    row_idx += 1;
                }
                DiscoveryItem::Section(_) => {}
            }
        }
        None
    }

    /// `true` iff the focused row in the discovery overlay is the
    /// synthetic `[+ Add custom integration]` row. Enter on this row
    /// opens the edit panel in AddCustom mode.
    pub fn discovery_focused_is_add_custom(&self) -> bool {
        let Some(state) = self.discovery_overlay.as_ref() else {
            return false;
        };
        let items = build_items(self);
        let mut row_idx = 0usize;
        for item in &items {
            match item {
                DiscoveryItem::AddCustom => {
                    if row_idx == state.selected_row {
                        return true;
                    }
                    row_idx += 1;
                }
                DiscoveryItem::Sibling { .. } => {
                    row_idx += 1;
                }
                DiscoveryItem::Section(_) => {}
            }
        }
        false
    }

    /// Enter on a row dispatches by status:
    /// - `InRail` → toast "already in rail"
    /// - `Installed` → add to rail config (in-memory; persistence is v2)
    /// - `NotInstalled` → toast hint to press `i` or `y`
    pub fn discovery_enter(&mut self) {
        // AddCustom synthetic row → open the edit panel in
        // AddCustom mode. Same path as the `a` chord.
        if self.discovery_focused_is_add_custom() {
            self.open_integration_edit_add_custom();
            return;
        }
        let Some((sibling, status)) = self.discovery_focused() else {
            return;
        };
        match status {
            SiblingStatus::InRail => {
                self.toast(format!("{} already in rail", sibling.binary()));
            }
            SiblingStatus::Installed => {
                self.discovery_add_to_rail(&sibling);
            }
            SiblingStatus::NotInstalled => {
                self.toast(format!(
                    "{} not installed — press i to install or y to copy command",
                    sibling.binary()
                ));
            }
        }
    }

    fn discovery_add_to_rail(&mut self, s: &SiblingRef) {
        // Reject re-adds (defensive — discovery_enter already checks).
        let launch = s.launch_command();
        let id = s.id().to_string();
        let binary = s.binary().to_string();
        if self
            .config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == id || ic.command == launch)
        {
            self.toast(format!("{} already in rail", binary));
            return;
        }
        self.config.ui.integration_icons.push(IntegrationIcon {
            id,
            glyph: s.icon_glyph().to_string(),
            fallback: s.icon_fallback().to_string(),
            command: launch,
            color: s.icon_color().to_string(),
            tooltip: Some(s.icon_tooltip().to_string()),
            enabled: true,
        });
        // Best-effort TOML persistence so the chip survives a restart.
        // On failure we still report "added" but flag the persistence
        // error so the user can self-correct.
        match persist_integration_icons(&self.config.ui.integration_icons) {
            Ok(path) => self.toast(format!(
                "added {} to rail · persisted to {}",
                binary,
                path.display()
            )),
            Err(e) => self.toast(format!(
                "added {} to rail (runtime only — persist failed: {e})",
                binary
            )),
        }
    }

    /// `y` — copy the `cargo install` command for the focused row.
    /// No-op for auto-discovered siblings (we don't know the repo URL).
    pub fn discovery_yank_install(&mut self) {
        let Some((sibling, _)) = self.discovery_focused() else {
            return;
        };
        let Some(cmd) = sibling.install_command() else {
            self.toast(format!(
                "{} is auto-discovered — install source unknown, no command to yank",
                sibling.binary()
            ));
            return;
        };
        let mut clip = crate::clipboard::Clipboard::new();
        clip.set(cmd.clone(), false);
        self.toast(format!("copied: {}", cmd));
    }

    /// `i` — spawn a Pty pane running `cargo install --git <url> --tag <ver>`
    /// for the focused row. No-op for auto-discovered siblings (already
    /// installed by definition — and we wouldn't know the repo URL
    /// anyway). The catalog path closes the overlay so the Pty pane
    /// gets the screen real estate.
    pub fn discovery_install_selected(&mut self) {
        let Some((sibling, _)) = self.discovery_focused() else {
            return;
        };
        let SiblingRef::Catalog(catalog) = sibling else {
            self.toast(format!(
                "{} is auto-discovered (already installed) — nothing to install",
                sibling.binary()
            ));
            return;
        };
        let id = catalog.id.to_string();
        // 2026-06-26 — delegate to the unified install path so the
        // discovery overlay, palette command (`mounts.install` /
        // `sibling.install`), AI tool, and the y/n install prompt
        // all funnel through the same logic — `main`-pin handling,
        // Mount manifest writing, Pty spawn shape.
        self.close_discovery_overlay();
        self.install_sibling(&id);
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
            sibling: SiblingRef::Catalog(s),
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
command = \":term mnml-aws-lambda\"
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
                command: ":term mnml-aws-lambda".to_string(),
                color: "orange".to_string(),
                tooltip: Some("Lambda".to_string()),
                enabled: false,
            },
            IntegrationIcon {
                id: "s3".to_string(),
                glyph: "y".to_string(),
                fallback: "S3".to_string(),
                command: ":term mnml-fs-s3".to_string(),
                color: "orange".to_string(),
                tooltip: None,
                enabled: false,
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
            command: ":term mnml-aws-lambda".to_string(),
            color: "orange".to_string(),
            tooltip: None,
            enabled: false,
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
