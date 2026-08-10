//! Integration edit panel state + `[[ui.integration_icon]]` TOML
//! persistence.
//!
//! The old "+ Add integration" browse-list overlay was removed
//! 2026-07-03 — the sidebar's Integrations panel (Installed /
//! Marketplace tabs) covers browse + install + enable, so the big
//! centered overlay was redundant. What's left here is:
//!
//!  - The in-flight edit panel state (`IntegrationEditState` +
//!    field/mode/color enums) owned by [`App::integration_edit`].
//!    Opened by right-click chip → Edit (id: name/glyph pre-filled).
//!  - `integration_edit_*` methods that mutate the panel.
//!  - `persist_integration_icons` / `persist_launcher_icons` —
//!    idempotent `[[ui.integration_icon]]` / `[[ui.launcher_icon]]`
//!    TOML writers used by the edit panel, the chip context menu,
//!    and any other rail-mutation path.
//!  - `run_patch_nerd_font_svg` — spawns FontForge on an SVG the
//!    user pasted into the SVG prompt (right-click chip → Patch
//!    Nerd Font). Assigned codepoint yanked to clipboard.

use crate::app::App;
use crate::config::IntegrationIcon;

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
    /// Short display name for the chip / tree row / picker / detail
    /// pane header. Persists to `IntegrationIcon.label`. Was named
    /// `tooltip` pre-2026-08-01 — renamed for consistency with the
    /// runtime type.
    pub label: String,
    /// Which field has the input cursor.
    pub focused_field: IntegrationEditField,
    /// Per-field byte-offset cursor. Same shape as the glyph-builder
    /// (2026-07-11) — enables Left/Right/Home/End caret motion and
    /// mid-string paste. `None` (Color) has no cursor since it's a
    /// menu-style choice, not a text field.
    pub id_cursor: usize,
    pub command_cursor: usize,
    pub glyph_cursor: usize,
    pub fallback_cursor: usize,
    pub label_cursor: usize,
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
    Label,
}

/// Closed-form color palette the `Color` field cycles through.
/// Names map onto the same vocabulary the live `parse_color` path
/// accepts via the existing `IntegrationIcon.color` field; the
/// order matches the family-Settings ROYGBIV-ish reading order.
pub const INTEGRATION_EDIT_COLORS: &[&str] = &[
    "fg", "dim", "red", "orange", "yellow", "green", "cyan", "blue", "purple",
];

impl App {
    /// Open the integration-edit panel for the integration with the
    /// given id. Surfaced from the chip's right-click context menu.
    /// P5 (2026-08-01) — palette command entry point for "add a
    /// local launcher." Opens the same edit overlay
    /// `open_integration_edit_by_id` uses but in AddCustom mode with
    /// an empty ChipSpec. Users type an id, label, glyph, fallback,
    /// color, and command; Save writes the entry to
    /// `[[ui.integration_icon]]` in user config.
    ///
    /// Handles private local launchers that don't warrant a shared
    /// catalog PR — quick-and-yours setup.
    pub fn open_launcher_add_local(&mut self) {
        self.integration_edit = Some(IntegrationEditState {
            mode: IntegrationEditMode::AddCustom,
            id: String::new(),
            command: ":term ".to_string(),
            glyph: String::new(),
            fallback: String::new(),
            color: "cyan".to_string(),
            label: String::new(),
            focused_field: IntegrationEditField::Id,
            id_cursor: 0,
            command_cursor: 6, // land after ":term "
            glyph_cursor: 0,
            fallback_cursor: 0,
            label_cursor: 0,
        });
    }

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
        let id_cursor = icon.id.len();
        let command_cursor = icon.command.len();
        let glyph_cursor = icon.glyph.len();
        let fallback_cursor = icon.fallback.len();
        let label = icon.label.unwrap_or_default();
        let label_cursor = label.len();
        self.integration_edit = Some(IntegrationEditState {
            mode: IntegrationEditMode::Edit,
            id: icon.id,
            command: icon.command,
            glyph: icon.glyph,
            fallback: icon.fallback,
            color: icon.color,
            label,
            focused_field: IntegrationEditField::Glyph,
            id_cursor,
            command_cursor,
            glyph_cursor,
            fallback_cursor,
            label_cursor,
        });
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

    /// Pick the next free PUA codepoint at or above U+F1B00 by
    /// scanning every currently-configured integration / launcher
    /// glyph for collisions.
    ///
    /// 2026-07-04 — moved from U+F300+ to U+F1B00+ because U+F300-F381
    /// is Nerd Fonts' Font Logos range (Alpine, Debian, Ubuntu, etc.),
    /// so custom AWS glyphs collided with real Nerd Font glyphs and
    /// were shadowed by any bundled Symbols Nerd Font (Ghostty's
    /// behavior). U+F1AF1+ is past the end of Material Design Icons
    /// (which stop at U+F1AF0) and unclaimed by any Nerd Font block.
    fn next_free_pua_codepoint(&self) -> Option<u32> {
        let mut taken: std::collections::HashSet<u32> = std::collections::HashSet::new();
        for ic in &self.config.ui.integration_icons {
            if let Some(c) = ic.glyph.chars().next() {
                taken.insert(c as u32);
            }
        }
        // 2026-08-01 (P2) — launcher_icons scan deleted with the
        // LauncherIcon retirement. All chip glyphs are in
        // integration_icons above.
        // Walk U+F1B00 → U+F1FFF (well past MDI end at U+F1AF0, well
        // inside the Supplementary Private Use Area).
        let mut cp = 0xF1B00u32;
        while cp <= 0xF1FFF {
            if !taken.contains(&cp) {
                return Some(cp);
            }
            cp += 1;
        }
        None
    }

    /// Spawn the patch script. Picks the next free PUA codepoint,
    /// runs `fontforge -script scripts/patch_nerd_font.py …` via
    /// shell, and toasts the result.
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
        let script = match std::env::current_exe()
            .ok()
            .and_then(|p| {
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
        let glyph_str = char::from_u32(cp)
            .map(|c| c.to_string())
            .unwrap_or_else(|| format!("U+{cp:X}"));
        {
            let mut clip = crate::clipboard::Clipboard::new();
            clip.set(glyph_str.clone(), false);
        }
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
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!(
            "patching · glyph copied · install {} after fontforge exits, then paste",
            font_out.file_name().unwrap_or_default().to_string_lossy()
        ));
    }

    /// Two-button confirm before actually removing an integration.
    /// 2026-07-09 — user report: bumped Remove instead of Edit in
    /// the right-click menu and lost a configured integration. The
    /// underlying removal (`remove_integration_by_id`) still runs
    /// unconditionally; this shim just guards the destructive
    /// entry points (context menu + palette picker).
    pub fn open_integration_remove_confirm(&mut self, id: String) {
        // Fast-path: if the integration doesn't exist, skip the
        // dialog and just toast — same UX as the direct-remove path.
        if !self
            .config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == id)
        {
            self.toast(format!("integration: {id} not in rail"));
            return;
        }
        // 2026-08-07 — protect the first-party built-ins from an
        // accidental uninstall. Browser / Claude Code / Codex / http
        // ship in mnml core; there's no `<sibling> --install` to
        // re-run to bring them back. User can still Disable via
        // right-click → Disable (hides the chip but keeps the
        // manifest). This is the same guard the settings pane
        // should apply once it lands.
        if is_builtin_integration_id(&id) {
            self.toast(format!(
                "integration: `{id}` is built-in — use Disable to hide the chip instead of Uninstall",
            ));
            return;
        }
        // 2026-08-06 — "Remove integration `X`?" → "Uninstall `X`?"
        // matches the new menu label + the toast this action
        // already emits ("uninstalled {id}").
        let title = format!("Uninstall `{id}`?");
        // Stash the manifest's binary name (if any) so the accept
        // handler can toast a follow-up hint about
        // `cargo uninstall <bin>` for users who also want the
        // compiled binary gone from ~/.cargo/bin.
        self.pending_integration_remove_binary = self
            .integration_manifests
            .iter()
            .find(|m| m.id == id)
            .and_then(|m| m.binary.clone());
        self.pending_integration_remove_id = Some(id);
        let mut p =
            crate::prompt::Prompt::new(crate::prompt::PromptKind::IntegrationRemoveConfirm, title);
        // Cancel default (safety first) — mirrors the delete-confirm
        // pattern from `open_fs_delete_prompt`.
        p.cursor = 1;
        self.prompt = Some(p);
    }

    /// Uninstall the integration with the given id — full round-trip
    /// with `install_launcher_from_url` / `<sibling> --install`:
    ///
    /// 1. Delete the installed manifest at
    ///    `~/.config/mnml/integrations/<id>.toml` (if present).
    /// 2. Re-scan the manifest dir so `self.integration_manifests` no
    ///    longer contains it.
    /// 3. Drop the entry from `config.ui.integration_icons` (the rail
    ///    list) + persist mnml's config.toml.
    ///
    /// Pre-2026-08-03 this only did step 3 — so a "removed" integration
    /// re-appeared on the next manifest merge (startup or
    /// `integrations.refresh`) because the manifest file was still on
    /// disk. Bug surfaced during the post-consolidation clean-slate
    /// audit where 10 orphaned Aug-1 manifests kept resurrecting
    /// themselves.
    pub fn remove_integration_by_id(&mut self, id: &str) {
        // Step 1: delete the manifest file + its sidecar override,
        // if either is present.
        let base_dir = Some(crate::data_root::data_root().join("integrations"));
        let manifest_removed = base_dir
            .as_ref()
            .map(|d| d.join(format!("{id}.toml")))
            .is_some_and(|p| p.exists() && std::fs::remove_file(&p).is_ok());
        // Delete the override sidecar too — leaving it behind would
        // resurrect (partial) user settings if the id is later
        // re-installed with a fresh canonical manifest. Same
        // "one uninstall gesture cleans everything" principle as
        // the folder-based override design (task #851).
        if let Some(override_path) = base_dir.map(|d| d.join(format!("{id}.override.toml")))
            && override_path.exists()
        {
            let _ = std::fs::remove_file(&override_path);
        }
        // Step 1.5: purge sibling-icons SDK state for this id —
        // `~/.config/mnml/glyphs/<id>.svg` and its assignments.toml
        // entry. Non-fatal if either is missing (most integrations
        // don't ship SVG glyphs). Reviewer 2026-08-03 W#3.
        let (svg_gone, assignment_gone) =
            crate::app::integration_glyphs::purge_integration_glyph_state(id);
        if svg_gone || assignment_gone {
            // In-memory codepoint map also drops the entry so the
            // next render doesn't briefly reach for the stale glyph.
            self.integration_glyph_codepoints.remove(id);
        }
        // Step 2: re-scan so the in-memory manifest list drops it.
        if manifest_removed {
            self.integration_manifests.retain(|m| m.id != id);
        }
        // Step 3: rail / config.toml pruning.
        let before = self.config.ui.integration_icons.len();
        self.config.ui.integration_icons.retain(|ic| ic.id != id);
        let rail_removed = self.config.ui.integration_icons.len() != before;
        match (manifest_removed, rail_removed) {
            (false, false) => self.toast(format!("integration: {id} not installed")),
            (true, _) => self.toast(format!("uninstalled {id}")),
            (false, true) => self.toast(format!("removed {id} from rail")),
        }
        // 2026-08-04 — was: `persist_integration_icons(&integration_icons)`
        // to rewrite `[[ui.integration_icon]]` blocks in config.toml.
        // That fought the #851-phase-3 migration: the migration
        // strips those blocks at startup, then this write reintroduced
        // them from in-memory state, so a legacy chip like Slack
        // "came back" every session. Trust the manifest+override
        // mechanism instead — uninstall deletes the manifest (step 1
        // above), and mnml core's config.rs filter drops surviving
        // `[[ui.integration_icon]]` blocks for retired ids at load.
        //
        // 2026-08-04 (user report) — also strip the id from the
        // activity-bar pinned list so an uninstalled chip doesn't
        // leave a dead entry in `activity_bar_pinned_integrations`.
        // Silent no-op when the id wasn't pinned. Persist directly
        // via `persist_activity_bar_pinned_integrations` since it
        // only rewrites the one key (unlike the retired
        // persist_integration_icons which rewrote whole blocks).
        let pin_before = self.config.ui.activity_bar_pinned_integrations.len();
        self.config
            .ui
            .activity_bar_pinned_integrations
            .retain(|s| s != id);
        if self.config.ui.activity_bar_pinned_integrations.len() != pin_before
            && let Err(e) = persist_activity_bar_pinned_integrations(
                &self.config.ui.activity_bar_pinned_integrations,
            )
        {
            self.toast(format!("(pinned-list persist failed: {e})"));
        }
    }

    /// Close the edit panel without saving. Esc binding inside the panel.
    pub fn integration_edit_cancel(&mut self) {
        self.integration_edit = None;
    }

    /// Commit the edit panel's current field values to
    /// `config.ui.integration_icons` + persist to TOML. Returns
    /// without saving when the panel state is invalid (empty id in
    /// AddCustom, empty glyph, etc.) — toasts the reason so the user
    /// can fix it without losing the in-flight edit. Closes the
    /// panel on success.
    pub fn integration_edit_save(&mut self) {
        let Some(panel) = self.integration_edit.clone() else {
            return;
        };
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
            label: if panel.label.trim().is_empty() {
                None
            } else {
                Some(panel.label.trim().to_string())
            },
            enabled: true,
            in_palette_bar: false,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        };
        // 2026-08-03 (#851 phase 2) — write to the integrations
        // folder, not `[[ui.integration_icon]]` in config.toml.
        //
        // - **Edit mode**: user is customizing chip visuals for an
        //   existing integration. Persist as an
        //   `<id>.override.toml` sidecar so the canonical manifest
        //   (from marketplace install or upstream update) stays the
        //   source of truth. Uninstall or a hand-delete of the
        //   override reverts to base.
        // - **AddCustom mode**: user is authoring a brand-new
        //   integration with no upstream. Write a full `<id>.toml`
        //   authorial manifest; there's nothing to override.
        //
        // In-memory rail entry gets updated either way so the chip
        // rerenders immediately without waiting on the next scan.
        let write_result = match panel.mode {
            IntegrationEditMode::Edit => {
                if let Some(slot) = self
                    .config
                    .ui
                    .integration_icons
                    .iter_mut()
                    .find(|ic| ic.id == new_icon.id)
                {
                    *slot = new_icon.clone();
                } else {
                    self.toast(format!("integration: {} no longer in rail", new_icon.id));
                    return;
                }
                write_override_toml(&new_icon)
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
                self.config.ui.integration_icons.push(new_icon.clone());
                write_authored_manifest_toml(&new_icon)
            }
        };
        match write_result {
            Ok(path) => self.toast(format!("integration saved · {}", path.display())),
            Err(e) => self.toast(format!("integration saved in-memory (persist failed: {e})")),
        }
        self.integration_edit = None;
    }

    /// Tab → move focus to the next field. `delta = 1` for forward,
    /// `-1` for backward (Shift+Tab). Skips `Id` / `Command` when
    /// the panel is in `Edit` mode (those fields are read-only).
    pub fn integration_edit_cycle_field(&mut self, delta: isize) {
        use IntegrationEditField::*;
        let order_full = [Id, Command, Glyph, Fallback, Color, Label];
        let order_edit = [Glyph, Fallback, Color, Label];
        let Some(panel) = self.integration_edit.as_mut() else {
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
        // Clamp the new field's cursor to its byte length so a stale
        // out-of-bounds offset (e.g. long id, short glyph) can't crash
        // the insert path.
        match panel.focused_field {
            Id => panel.id_cursor = panel.id_cursor.min(panel.id.len()),
            Command => panel.command_cursor = panel.command_cursor.min(panel.command.len()),
            Glyph => panel.glyph_cursor = panel.glyph_cursor.min(panel.glyph.len()),
            Fallback => panel.fallback_cursor = panel.fallback_cursor.min(panel.fallback.len()),
            Label => panel.label_cursor = panel.label_cursor.min(panel.label.len()),
            Color => {}
        }
    }

    /// ←→ cycle the Color field through `INTEGRATION_EDIT_COLORS`.
    /// `delta = 1` for forward, `-1` for backward. No-op when the
    /// focused field isn't `Color`.
    pub fn integration_edit_color_cycle(&mut self, delta: isize) {
        let Some(panel) = self.integration_edit.as_mut() else {
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
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor, cap): (&mut String, &mut usize, usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor, 64),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor, 128),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor, 1),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor, 8),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor, 128),
            IntegrationEditField::Color => return,
        };
        if buf.chars().count() >= cap {
            return;
        }
        let cur = (*cursor).min(buf.len());
        buf.insert(cur, ch);
        *cursor = cur + ch.len_utf8();
    }

    /// Paste the clipboard into the focused field at the cursor.
    /// Trims quotes + surrounding whitespace, strips control chars,
    /// respects the field cap. 2026-07-11 user request.
    pub fn integration_edit_paste(&mut self) {
        let text = self.clipboard.text();
        let cleaned: String = text
            .trim()
            .trim_matches(|c| c == '\'' || c == '"')
            .chars()
            .filter(|c| !c.is_control() && *c != '\r' && *c != '\n')
            .collect();
        if cleaned.is_empty() {
            return;
        }
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor, cap): (&mut String, &mut usize, usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor, 64),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor, 128),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor, 1),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor, 8),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor, 128),
            IntegrationEditField::Color => return,
        };
        let existing = buf.chars().count();
        let allowed = cap.saturating_sub(existing);
        if allowed == 0 {
            return;
        }
        let to_insert: String = cleaned.chars().take(allowed).collect();
        let cur = (*cursor).min(buf.len());
        buf.insert_str(cur, &to_insert);
        *cursor = cur + to_insert.len();
    }

    /// Backspace — delete one char BEFORE the cursor.
    pub fn integration_edit_backspace(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&mut String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        if cur == 0 {
            return;
        }
        let prev = buf[..cur]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        buf.replace_range(prev..cur, "");
        *cursor = prev;
    }

    /// Forward-delete (Delete key) — remove the char AT the cursor.
    pub fn integration_edit_delete_forward(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&mut String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        if cur >= buf.len() {
            return;
        }
        let end = buf[cur..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| cur + i)
            .unwrap_or(buf.len());
        buf.replace_range(cur..end, "");
    }

    pub fn integration_edit_move_left(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        if cur == 0 {
            return;
        }
        let prev = buf[..cur]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        *cursor = prev;
    }

    pub fn integration_edit_move_right(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        if cur >= buf.len() {
            return;
        }
        let next = buf[cur..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| cur + i)
            .unwrap_or(buf.len());
        *cursor = next;
    }

    pub fn integration_edit_move_home(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        match panel.focused_field {
            IntegrationEditField::Id => panel.id_cursor = 0,
            IntegrationEditField::Command => panel.command_cursor = 0,
            IntegrationEditField::Glyph => panel.glyph_cursor = 0,
            IntegrationEditField::Fallback => panel.fallback_cursor = 0,
            IntegrationEditField::Label => panel.label_cursor = 0,
            IntegrationEditField::Color => {}
        }
    }

    pub fn integration_edit_move_end(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        match panel.focused_field {
            IntegrationEditField::Id => panel.id_cursor = panel.id.len(),
            IntegrationEditField::Command => panel.command_cursor = panel.command.len(),
            IntegrationEditField::Glyph => panel.glyph_cursor = panel.glyph.len(),
            IntegrationEditField::Fallback => panel.fallback_cursor = panel.fallback.len(),
            IntegrationEditField::Label => panel.label_cursor = panel.label.len(),
            IntegrationEditField::Color => {}
        }
    }

    /// 2026-08-08 — Ctrl+W kill-word-back on the focused text field.
    pub fn integration_edit_delete_word_back(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&mut String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        let head = &buf[..cur];
        let trimmed = head.trim_end_matches(char::is_whitespace);
        let cut = trimmed
            .char_indices()
            .rev()
            .find(|&(_, c)| c.is_whitespace())
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(0);
        buf.replace_range(cut..cur, "");
        *cursor = cut;
    }

    /// 2026-08-08 — Ctrl+U kill-to-start on the focused text field.
    pub fn integration_edit_delete_to_start(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&mut String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        buf.replace_range(..cur, "");
        *cursor = 0;
    }

    /// 2026-08-08 — Ctrl+K kill-to-end on the focused text field.
    pub fn integration_edit_delete_to_end(&mut self) {
        let Some(panel) = self.integration_edit.as_mut() else {
            return;
        };
        let (buf, cursor): (&mut String, &mut usize) = match panel.focused_field {
            IntegrationEditField::Id => (&mut panel.id, &mut panel.id_cursor),
            IntegrationEditField::Command => (&mut panel.command, &mut panel.command_cursor),
            IntegrationEditField::Glyph => (&mut panel.glyph, &mut panel.glyph_cursor),
            IntegrationEditField::Fallback => (&mut panel.fallback, &mut panel.fallback_cursor),
            IntegrationEditField::Label => (&mut panel.label, &mut panel.label_cursor),
            IntegrationEditField::Color => return,
        };
        let cur = (*cursor).min(buf.len());
        buf.truncate(cur);
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

/// Write an `<id>.override.toml` sidecar next to the canonical
/// manifest at `~/.config/mnml/integrations/<id>.toml` — BUT ONLY
/// if a base manifest exists. If it doesn't, promote the write to a
/// full `<id>.toml` authorial manifest instead: an orphan override
/// with no base is silently dropped at the next scan
/// (`integration_manifest.rs::scan_dir`), so writing one for a chip
/// whose "canonical" is a Rust-hardcoded builtin (browser,
/// claude_code, codex — `config.rs::default_integration_icons`)
/// would round-trip to nothing on restart. Reviewer flagged this
/// as reintroducing the exact resurrection-bug class the folder-
/// override arc was fixing (#851 code review, Critical #1).
///
/// Emits the full field set that the overlay exposes — the loader
/// only applies fields that are present + non-null, and
/// re-emitting a value equal to the base is a no-op at merge time.
///
/// Returns the written path on success.
pub fn write_override_toml(icon: &IntegrationIcon) -> Result<std::path::PathBuf, String> {
    let dir = integrations_dir_or_err()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let base_path = dir.join(format!("{}.toml", icon.id));
    if !base_path.exists() {
        // 2026-08-06 — was: promote to authored manifest from the
        // live slot for any id with no base file. Broken for
        // built-ins (browser / claude_code / codex) because the
        // in-memory slot's glyph/label can be stale/partial by the
        // time this fires — the resulting manifest scaffold wrote
        // empty glyph + id-as-label + fake `<id>.open` command,
        // then the next scan loaded THAT as authoritative and
        // clobbered the Rust defaults with garbage.
        //
        // Now: for built-in ids, rebuild the icon from the shipped
        // Rust defaults (source-of-truth) and preserve only the
        // user's toggle values (enabled + in_palette_bar). That
        // way the scaffolded manifest carries the real glyph,
        // label, color, and command regardless of what the slot
        // looked like at toggle time.
        if is_builtin_integration_id(&icon.id) {
            let mut authoritative = builtin_default_icon(&icon.id).unwrap_or(icon.clone());
            authoritative.enabled = icon.enabled;
            authoritative.in_palette_bar = icon.in_palette_bar;
            return write_authored_manifest_toml(&authoritative);
        }
        return write_authored_manifest_toml(icon);
    }
    let path = dir.join(format!("{}.override.toml", icon.id));
    let mut body = String::new();
    body.push_str(&format!("id = {}\n", toml_str(&icon.id)));
    if let Some(label) = &icon.label {
        body.push_str(&format!("label = {}\n", toml_str(label)));
    }
    body.push_str("\n[chip]\n");
    body.push_str(&format!("glyph = {}\n", toml_str(&icon.glyph)));
    body.push_str(&format!("fallback = {}\n", toml_str(&icon.fallback)));
    body.push_str(&format!("color = {}\n", toml_str(&icon.color)));
    body.push_str(&format!("enabled = {}\n", icon.enabled));
    body.push_str(&format!("in_palette_bar = {}\n", icon.in_palette_bar));
    std::fs::write(&path, body).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// 2026-08-06 — the built-in integrations shipped in mnml's Rust
/// defaults (browser / claude_code / codex). Toggling these
/// persists as `[[ui.integration_icon]]` in config.toml, not as
/// a scaffolded manifest — the Rust default is the source of
/// truth for glyph/label/color, and writing a scaffold from the
/// live slot risks capturing a stale/partial snapshot.
pub fn is_builtin_integration_id(id: &str) -> bool {
    matches!(id, "browser" | "claude_code" | "codex" | "http")
}

/// Look up the shipped Rust default for a built-in integration id.
/// Returns `None` for anything not in the shipped default list.
/// Used by `write_override_toml`'s built-in scaffold path to
/// resurrect authoritative glyph/label/color/command values so a
/// user-triggered toggle doesn't clobber them with a stale slot.
pub fn builtin_default_icon(id: &str) -> Option<crate::config::IntegrationIcon> {
    let cfg = crate::config::Config::default();
    cfg.ui.integration_icons.into_iter().find(|i| i.id == id)
}

/// Write a full `<id>.toml` authorial manifest for a user-created
/// integration (AddCustom mode). No sibling exists upstream, so the
/// file is the canonical source, not an override. `binary` is left
/// unset so the manifest is treated as a launcher; the `command`
/// field is emitted as a single palette-command entry the chip
/// dispatches to.
pub fn write_authored_manifest_toml(icon: &IntegrationIcon) -> Result<std::path::PathBuf, String> {
    let dir = integrations_dir_or_err()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let path = dir.join(format!("{}.toml", icon.id));
    let mut body = String::new();
    body.push_str(&format!("id = {}\n", toml_str(&icon.id)));
    let display_label = icon.label.clone().unwrap_or_else(|| icon.id.clone());
    body.push_str(&format!("label = {}\n", toml_str(&display_label)));
    body.push_str("\n[chip]\n");
    body.push_str(&format!("glyph = {}\n", toml_str(&icon.glyph)));
    body.push_str(&format!("fallback = {}\n", toml_str(&icon.fallback)));
    body.push_str(&format!("color = {}\n", toml_str(&icon.color)));
    body.push_str(&format!("enabled = {}\n", icon.enabled));
    body.push_str(&format!("in_palette_bar = {}\n", icon.in_palette_bar));
    body.push_str("\n[[commands]]\n");
    body.push_str(&format!(
        "id = {}\n",
        toml_str(&format!("{}.open", icon.id))
    ));
    body.push_str(&format!(
        "title = {}\n",
        toml_str(&format!("{}: open", display_label))
    ));
    body.push_str(&format!("run = {}\n", toml_str(&icon.command)));
    std::fs::write(&path, body).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

fn integrations_dir_or_err() -> Result<std::path::PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("no $HOME set — can't locate integrations dir")?;
    Ok(std::path::PathBuf::from(home)
        .join(".config")
        .join("mnml")
        .join("integrations"))
}

/// Persist the launcher_icons array to the user's mnml config
/// the same way `persist_integration_icons` handles its peer.
/// Filed against the 2026-06-28 TODO in context_menus.rs that
/// noted launcher toggles didn't survive restart.
/// Persist a single `[ui]` scalar setting to the user config. Reads
/// the existing file, replaces the first `key = <old>` line inside
/// the `[ui]` section with `key = "<value>"`, or appends the pair
/// after the `[ui]` header if the key isn't present. If there's no
/// `[ui]` section at all, adds one. Comments elsewhere in the file
/// stay put.
pub fn persist_ui_string(key: &'static str, value: &str) -> Result<std::path::PathBuf, String> {
    let esc = value.replace('\\', r"\\").replace('"', "\\\"");
    persist_config_scalar("ui", key, format!("\"{esc}\""))
}

/// Persist the pinned-integration list to `[ui]
/// activity_bar_pinned_integrations = […]`. Right-click "Add to
/// activity bar" / "Remove from activity bar" write via this.
/// Preserves comments + other keys in the file. 2026-07-20.
pub fn persist_activity_bar_pinned_integrations(
    ids: &[String],
) -> Result<std::path::PathBuf, String> {
    persist_ui_string_array("activity_bar_pinned_integrations", ids)
}

/// Sugar for the top-bar cluster mode setter. Called from the
/// TABS right-click menu.
pub fn persist_top_bar_cluster_mode(mode: &'static str) -> Result<std::path::PathBuf, String> {
    persist_ui_string("top_bar_cluster_mode", mode)
}

/// Bool variant of [`persist_ui_string`] — see [`persist_ui_bool`].
pub fn persist_ui_bool(key: &'static str, value: bool) -> Result<std::path::PathBuf, String> {
    persist_config_scalar("ui", key, value.to_string())
}

/// Int variant of [`persist_ui_string`] — TOML integer literal.
pub fn persist_ui_int(key: &'static str, value: i64) -> Result<std::path::PathBuf, String> {
    persist_config_scalar("ui", key, value.to_string())
}

/// `[editor] KEY = <value>` (bool). Same in-place replace / append
/// semantics as the `[ui]` helpers, targeting the `[editor]`
/// section instead. Used by runtime editor toggles (auto-pair,
/// breadcrumb, …) so interactive changes survive restart.
pub fn persist_editor_bool(key: &'static str, value: bool) -> Result<std::path::PathBuf, String> {
    persist_config_scalar("editor", key, value.to_string())
}

/// `[editor] KEY = "value"` (string). Used by `set_input_style` so
/// swapping vim ↔ standard from a running mnml survives restart.
pub fn persist_editor_string(key: &'static str, value: &str) -> Result<std::path::PathBuf, String> {
    let esc = value.replace('\\', r"\\").replace('"', "\\\"");
    persist_config_scalar("editor", key, format!("\"{esc}\""))
}

/// Shared writer for `[section] KEY = <toml-encoded-value>`. The
/// caller pre-encodes the value (quoted string, bare bool, bare
/// int) — this fn owns the section-header find / in-place replace
/// / append behavior and preserves comments + surrounding keys.
fn persist_config_scalar(
    section: &str,
    key: &str,
    value_encoded: String,
) -> Result<std::path::PathBuf, String> {
    let path = crate::config::user_config_path()
        .ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let new_line = format!("{key} = {value_encoded}");
    let header = format!("[{section}]");

    let mut out: Vec<String> = Vec::new();
    let mut in_section = false;
    let mut section_header_idx: Option<usize> = None;
    let mut key_replaced = false;
    for line in existing.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_section = trimmed == header;
            if in_section {
                section_header_idx = Some(out.len());
            }
            out.push(line.to_string());
            continue;
        }
        if in_section
            && !key_replaced
            && (trimmed.starts_with(&format!("{key} ")) || trimmed.starts_with(&format!("{key}=")))
        {
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            out.push(format!("{indent}{new_line}"));
            key_replaced = true;
            continue;
        }
        out.push(line.to_string());
    }
    if !key_replaced {
        if let Some(idx) = section_header_idx {
            out.insert(idx + 1, new_line);
        } else {
            if !out.is_empty() && !out.last().is_some_and(|l| l.trim().is_empty()) {
                out.push(String::new());
            }
            out.push(header);
            out.push(new_line);
        }
    }
    let contents = out.join("\n") + "\n";
    std::fs::write(&path, contents).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// #864 — persist `[ui] integration_icon_order = ["id1", "id2", …]`
/// to the user config. Called after any MoveIntegrationUp/Down/
/// ToTop/ToBottom right-click-menu action. Replaces `persist_integration_icons`
/// for reorder: that helper's `[[ui.integration_icon]]` blocks get
/// dropped by `config::finalize` (post 2026-08-01 flip) for any
/// non-builtin id, so it can't hold reorder state for a manifest-
/// backed chip. This one persists just the order list — the chip
/// visuals stay canonical, only the sort order travels.
///
/// Preserves comments + other `[ui]` keys via the same in-place
/// replace / append-under-header pattern the other `persist_*`
/// helpers use.
pub fn persist_integration_icon_order(ids: &[String]) -> Result<std::path::PathBuf, String> {
    persist_ui_string_array("integration_icon_order", ids)
}

/// #865 — shared writer for `[ui] KEY = ["a", "b", …]` entries.
/// Serializes to a TOML array literal (escaping `"` and `\`),
/// finds an existing `KEY` line under `[ui]` and replaces it
/// in place, otherwise inserts a fresh line under an existing
/// `[ui]` header or appends the header + line at EOF. Preserves
/// comments + all other keys.
///
/// Callers: `persist_activity_bar_pinned_integrations`,
/// `persist_integration_icon_order`. Kept `pub` so future
/// array-shaped `[ui]` keys can reuse the same shape.
pub fn persist_ui_string_array(key: &str, ids: &[String]) -> Result<std::path::PathBuf, String> {
    let path = crate::config::user_config_path()
        .ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let esc = |s: &str| s.replace('\\', r"\\").replace('"', "\\\"");
    let arr = ids
        .iter()
        .map(|s| format!("\"{}\"", esc(s)))
        .collect::<Vec<_>>()
        .join(", ");
    let new_line = format!("{key} = [{arr}]");

    let mut out: Vec<String> = Vec::new();
    let mut in_ui = false;
    let mut ui_header_idx: Option<usize> = None;
    let mut key_replaced = false;
    for line in existing.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_ui = trimmed == "[ui]";
            if in_ui {
                ui_header_idx = Some(out.len());
            }
            out.push(line.to_string());
            continue;
        }
        if in_ui
            && !key_replaced
            && (trimmed.starts_with(&format!("{key} ")) || trimmed.starts_with(&format!("{key}=")))
        {
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            out.push(format!("{indent}{new_line}"));
            key_replaced = true;
            continue;
        }
        out.push(line.to_string());
    }
    if !key_replaced {
        if let Some(idx) = ui_header_idx {
            out.insert(idx + 1, new_line);
        } else {
            if !out.is_empty() && !out.last().is_some_and(|l| l.trim().is_empty()) {
                out.push(String::new());
            }
            out.push("[ui]".to_string());
            out.push(new_line);
        }
    }
    let contents = out.join("\n") + "\n";
    std::fs::write(&path, contents).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

// 2026-08-01 (P2) — persist_launcher_icons + strip/append helpers
// deleted with the LauncherIcon retirement. Chip persistence now
// goes through persist_integration_icons (slim entries).

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
    out.push_str("# 2026-08-01 — slim entries. Only `enabled` +\n");
    out.push_str("# `in_palette_bar` (and file order) come from here now;\n");
    out.push_str("# glyph / label / command / color / fallback / description\n");
    out.push_str("# all read from the sibling's installed manifest (or a\n");
    out.push_str("# built-in default in mnml core). This section is rewritten\n");
    out.push_str("# in place on every right-click toggle. Any fields you add\n");
    out.push_str("# by hand will get dropped on next save — add an override\n");
    out.push_str("# mechanism if you need per-user glyph/label customization.\n\n");
    for ic in icons {
        out.push_str("[[ui.integration_icon]]\n");
        out.push_str(&format!("id = {}\n", toml_str(&ic.id)));
        out.push_str(&format!("enabled = {}\n", ic.enabled));
        if ic.in_palette_bar {
            out.push_str("in_palette_bar = true\n");
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
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

/// #851 phase 3 — one-shot AGGRESSIVE migration of legacy
/// `[[ui.integration_icon]]` blocks in `config.toml` into folder-
/// based overrides (`~/.config/mnml/integrations/<id>.override.toml`).
///
/// Runs at startup. Idempotent — when no legacy blocks are present
/// (post-migration or fresh install) it's a no-op and does not
/// rewrite config.toml (so no needless config-backup churn).
///
/// Behavior:
/// - Parse config.toml as a plain TOML value tree.
/// - For every `[[ui.integration_icon]]` block, read `id`,
///   `enabled`, `in_palette_bar`. Any other field on the legacy
///   block was already dead per the 2026-08-01 precedence flip.
/// - When the block carries a non-default state (`enabled = false`
///   or `in_palette_bar = true`), materialize an
///   `<id>.override.toml` sidecar preserving that state. Manifest
///   defaults for glyph/color/label/etc are inherited on next
///   startup — the override only records user-touched fields.
/// - Regardless of whether a sidecar was written, drop the legacy
///   block from config.toml. Stripping is done via the existing
///   `strip_integration_icon_blocks` line-oriented pass so
///   comments + non-integration keys survive.
/// - Write config.toml back via `config::write_user_config` so the
///   pre-migration copy lands in `~/.config/mnml/backups/`
///   (recoverable if anything looks wrong).
///
/// Callers: `App::new` at startup. Returns the count of migrated
/// blocks (0 when idempotent no-op) plus a Vec of anything that
/// could not be migrated (unrecognized id shape, override write
/// error). Both surface via startup toast when non-empty.
/// 2026-08-04 — one-shot cleanup for retired-id manifest files that
/// the buggy pre-c7d781b7 migration wrote to disk before the
/// retired-id filter existed. Deletes any `<retired>.toml` +
/// `<retired>.override.toml` in the integrations dir. Idempotent
/// — a fresh install with no such files is a no-op.
///
/// The buggy path: legacy `[[ui.integration_icon]] id="slack"
/// enabled=false` block → `write_override_toml` called with
/// no base → promoted to `write_authored_manifest_toml` → `slack.toml`
/// written with a dead `slack.open` command. Post-fix (c7d781b7) the
/// migration filters these ids out before promotion, but the files
/// created by the old buggy run stayed on disk and kept re-loading
/// the chip on every launch. User report 2026-08-04: "why slack keep
/// com ing back".
pub fn cleanup_retired_id_manifests() -> usize {
    // Two categories:
    // 1. Retired ids (bitbucket, linear, gitlab, cypress, slack) —
    //    always safe to delete; mnml core no longer knows about them.
    // 2. Built-in ids (browser, claude_code, codex, http) — only
    //    delete when the manifest LOOKS BOGUS (pre-c7d781b7 migration
    //    wrote `label = <id>` + empty glyph + `<id>.open` command,
    //    which shadowed mnml core's proper defaults). Since 2026-08-06
    //    `write_override_toml` writes AUTHORITATIVE manifests for
    //    built-ins (real glyph/label/color/command from Rust
    //    defaults). Those must NOT get deleted — otherwise the user's
    //    `enabled = true` toggle for Claude Code / Codex evaporates
    //    on every startup (user report 2026-08-07: "claude code and
    //    codex keep getting disabled when I exit").
    let retired_ids = ["bitbucket", "linear", "gitlab", "cypress", "slack"];
    let builtin_ids = ["browser", "claude_code", "codex", "http"];
    let dir = crate::data_root::data_root().join("integrations");
    let mut cleaned = 0usize;
    for id in retired_ids {
        for suffix in ["toml", "override.toml"] {
            let p = dir.join(format!("{id}.{suffix}"));
            if p.exists() && std::fs::remove_file(&p).is_ok() {
                cleaned += 1;
            }
        }
    }
    for id in builtin_ids {
        for suffix in ["toml", "override.toml"] {
            let p = dir.join(format!("{id}.{suffix}"));
            if p.exists() && manifest_looks_bogus(&p, id) && std::fs::remove_file(&p).is_ok() {
                cleaned += 1;
            }
        }
    }
    cleaned
}

/// True when a built-in-id manifest at `path` looks like the pre-
/// c7d781b7 bogus scaffold — empty glyph, id-as-label, or `<id>.open`
/// command with no other content. Used by `cleanup_retired_id_manifests`
/// to distinguish "delete me" old junk from "keep me" real
/// user-enabled manifests written by `write_override_toml` since
/// 2026-08-06.
fn manifest_looks_bogus(path: &std::path::Path, id: &str) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(doc) = toml::from_str::<toml::Value>(&text) else {
        // Parse failure = we can't tell — leave it alone so the user
        // can fix it manually rather than losing custom edits silently.
        return false;
    };
    // Bogus scaffold signature: empty/missing chip.glyph field.
    let glyph_empty = doc
        .get("chip")
        .and_then(|c| c.get("glyph"))
        .and_then(|v| v.as_str())
        .map(|s| s.is_empty())
        .unwrap_or(true);
    // Bogus scaffold signature: command == `<id>.open` (default the
    // migration wrote when it didn't know the real one).
    let bogus_command = doc
        .get("command")
        .and_then(|v| v.as_str())
        .map(|s| s == format!("{id}.open"))
        .unwrap_or(false);
    glyph_empty || bogus_command
}

pub fn migrate_legacy_integration_icon_blocks() -> Result<(usize, Vec<String>), String> {
    let cfg_path = crate::config::user_config_path()
        .ok_or_else(|| "no user config path resolvable".to_string())?;
    let Ok(existing) = std::fs::read_to_string(&cfg_path) else {
        return Ok((0, Vec::new()));
    };
    // Fast path: if the file has no legacy blocks at all, we're done.
    if !existing.contains("[[ui.integration_icon]]") {
        return Ok((0, Vec::new()));
    }
    // Parse via the toml crate for structured id/enabled/in_palette_bar
    // extraction. Malformed config → return the error; startup handles
    // toasting.
    let doc: toml::Value =
        toml::from_str(&existing).map_err(|e| format!("parse {}: {e}", cfg_path.display()))?;
    let mut migrated = 0usize;
    let mut warns: Vec<String> = Vec::new();
    let legacy_blocks = doc
        .get("ui")
        .and_then(|u| u.get("integration_icon"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    // Retired-in-2026-07-19 ids — mnml core removed the built-ins
    // for these but old configs still carry `[[ui.integration_icon]]`
    // blocks with `enabled = false` (user's "keep it hidden" intent).
    // Promoting those to authored manifests re-creates a dead chip
    // that dispatches to a `<id>.open` command with no handler.
    // Drop them instead. Matches the retain filter in
    // config.rs:2033-2038. User report 2026-08-04 — Slack kept
    // "coming back" because the migration promoted to `slack.toml`.
    let retired_ids = ["bitbucket", "linear", "gitlab", "cypress", "slack"];
    for block in &legacy_blocks {
        let Some(id) = block.get("id").and_then(|v| v.as_str()) else {
            warns.push("legacy block without id — skipped".to_string());
            continue;
        };
        if retired_ids.contains(&id) {
            migrated += 1;
            continue;
        }
        let enabled = block.get("enabled").and_then(|v| v.as_bool());
        let in_palette_bar = block.get("in_palette_bar").and_then(|v| v.as_bool());
        // Manifest defaults are `enabled = true`, `in_palette_bar = false`.
        // Only when the legacy block deviates do we need to preserve
        // user intent via an override sidecar.
        let has_delta = matches!(enabled, Some(false)) || matches!(in_palette_bar, Some(true));
        if !has_delta {
            // Legacy block carries only defaults — safe to drop with
            // no override needed. Counts toward migrated to reflect
            // the change we're making to config.toml.
            migrated += 1;
            continue;
        }
        let icon = IntegrationIcon {
            id: id.to_string(),
            enabled: enabled.unwrap_or(true),
            in_palette_bar: in_palette_bar.unwrap_or(false),
            // These fields carry the manifest / built-in default at
            // load time — `write_override_toml` uses them to emit
            // the [chip] section. Empty strings here are fine
            // because we ONLY write override files when the base
            // manifest exists (the write_override_toml logic itself
            // promotes to authored when no base is present, which
            // is the right behavior for a builtin id whose block
            // predates the manifest era).
            glyph: String::new(),
            fallback: String::new(),
            command: String::new(),
            color: String::new(),
            label: None,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        };
        match write_override_toml(&icon) {
            Ok(_) => migrated += 1,
            Err(e) => warns.push(format!("override write for {id}: {e}")),
        }
    }
    // Now strip legacy blocks from the source. Use the existing
    // line-oriented strip so comments + non-integration content
    // survive intact.
    let stripped = strip_integration_icon_blocks(&existing);
    if stripped != existing {
        crate::config::write_user_config(&cfg_path, &stripped)
            .map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
    }
    Ok((migrated, warns))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// crash-investigator SEV-1 2026-07-11: Nerd Font BMP private-use
    /// glyphs are 3 bytes UTF-8; Material Design Icons at U+F0000+
    /// are 4 bytes. If the Glyph field previously held a 3-byte icon
    /// with `glyph_cursor = 3` (end) and the user picks a 4-byte MDI
    /// icon, cursor stays at 3 — mid-codepoint of the new glyph.
    /// The next backspace / move_left / type_char would slice
    /// mid-UTF-8 and panic. Fixed at picker.rs by resetting cursor
    /// to `panel.glyph.len()` on the swap.
    #[test]
    fn integration_edit_backspace_after_glyph_width_swap_is_safe() {
        let d = tempfile::tempdir().unwrap();
        let cfg = crate::config::Config::default();
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        app.integration_edit = Some(IntegrationEditState {
            mode: IntegrationEditMode::Edit,
            id: "test".to_string(),
            command: String::new(),
            glyph: "\u{F0001}".to_string(), // 4-byte MDI
            fallback: String::new(),
            color: "cyan".to_string(),
            label: String::new(),
            focused_field: IntegrationEditField::Glyph,
            id_cursor: 0,
            command_cursor: 0,
            glyph_cursor: 4, // end of 4-byte glyph
            fallback_cursor: 0,
            label_cursor: 0,
        });
        // Simulate the picker swap: replace with a 3-byte BMP glyph.
        // Old (buggy) behavior left glyph_cursor at 4, past the new
        // 3-byte buffer — backspace would then panic on the byte
        // slice. Fixed behavior resets cursor to len (3).
        if let Some(p) = app.integration_edit.as_mut() {
            p.glyph.clear();
            p.glyph.push('\u{E000}'); // 3-byte BMP private use
            p.glyph_cursor = p.glyph.len();
        }
        // Must not panic.
        app.integration_edit_backspace();
        assert_eq!(app.integration_edit.as_ref().unwrap().glyph, "");
        assert_eq!(app.integration_edit.as_ref().unwrap().glyph_cursor, 0);
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
        assert!(!out.contains("integration_icon"));
        assert!(!out.contains("mnml-aws-lambda"));
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
                label: Some("Lambda".to_string()),
                enabled: false,
                in_palette_bar: false,
                description: None,
                homepage: None,
                docs: None,
                repository: None,
                author: None,
                version: None,
                commands: Vec::new(),
            },
            IntegrationIcon {
                id: "s3".to_string(),
                glyph: "y".to_string(),
                fallback: "S3".to_string(),
                command: ":term mnml-fs-s3".to_string(),
                color: "orange".to_string(),
                label: None,
                enabled: false,
                in_palette_bar: false,
                description: None,
                homepage: None,
                docs: None,
                repository: None,
                author: None,
                version: None,
                commands: Vec::new(),
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
            label: None,
            enabled: false,
            in_palette_bar: false,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
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

    #[test]
    fn append_integration_icon_blocks_preserves_enabled_true() {
        // Regression lock for commit 10e6cfa — the `enabled` field
        // was silently dropped during serialisation so right-click
        // → Enable appeared to work in-session but reset to false
        // on restart (the deserializer defaults missing key to false).
        let icons = vec![IntegrationIcon {
            id: "myapp".to_string(),
            glyph: "x".to_string(),
            fallback: "M".to_string(),
            command: ":term myapp".to_string(),
            color: "cyan".to_string(),
            label: Some("My App".to_string()),
            enabled: true,
            in_palette_bar: false,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        }];
        let toml_out = append_integration_icon_blocks("", &icons);
        assert!(
            toml_out.contains("enabled = true"),
            "enabled=true must appear in TOML output; got:\n{toml_out}"
        );
        let parsed: toml::Value = toml::from_str(&toml_out).expect("valid TOML");
        let enabled = parsed
            .get("ui")
            .and_then(|u| u.get("integration_icon"))
            .and_then(|a| a.as_array())
            .and_then(|a| a.first())
            .and_then(|e| e.get("enabled"))
            .and_then(|v| v.as_bool())
            .expect("enabled key present in parsed TOML");
        assert!(enabled);
    }

    #[test]
    fn append_integration_icon_blocks_enabled_false_is_explicit() {
        let icons = vec![IntegrationIcon {
            id: "disabled_one".to_string(),
            glyph: "y".to_string(),
            fallback: "D".to_string(),
            command: ":term disabled_one".to_string(),
            color: "red".to_string(),
            label: None,
            enabled: false,
            in_palette_bar: false,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        }];
        let toml_out = append_integration_icon_blocks("", &icons);
        assert!(
            toml_out.contains("enabled = false"),
            "enabled=false must appear literally; got:\n{toml_out}"
        );
    }

    // 2026-08-01 (P2) — append_launcher_icon_blocks_serializes_enabled_field
    // deleted with the LauncherIcon retirement.

    /// Regression for the 2026-08-03 install/uninstall audit — the
    /// prior `remove_integration_by_id` only trimmed the rail chip,
    /// leaving `~/.config/mnml/integrations/<id>.toml` on disk so the
    /// integration resurrected itself on the next manifest scan.
    #[test]
    fn remove_integration_by_id_deletes_installed_manifest() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        // Seed an installed manifest at HOME/.config/mnml/integrations/testxyz.toml
        // — the shape write_launcher_from_url would produce.
        let dir = tmp.path().join(".config").join("mnml").join("integrations");
        std::fs::create_dir_all(&dir).unwrap();
        let manifest_path = dir.join("testxyz.toml");
        std::fs::write(
            &manifest_path,
            r#"id = "testxyz"
label = "Test XYZ"
[chip]
glyph = "T"
fallback = "T"
color = "cyan"
enabled = true
"#,
        )
        .unwrap();
        assert!(manifest_path.exists());
        // Build an App and hand-populate the in-memory rail entry the way
        // the real merge would (avoids depending on the full scan path).
        let ws = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(ws.path().to_path_buf(), crate::config::Config::default())
                .unwrap();
        app.config
            .ui
            .integration_icons
            .push(crate::config::IntegrationIcon {
                id: "testxyz".to_string(),
                glyph: "T".to_string(),
                fallback: "T".to_string(),
                command: "testxyz.open".to_string(),
                color: "cyan".to_string(),
                label: Some("Test XYZ".to_string()),
                enabled: true,
                in_palette_bar: false,
                description: None,
                homepage: None,
                docs: None,
                repository: None,
                author: None,
                version: None,
                commands: Vec::new(),
            });
        // Uninstall via the shared path.
        app.remove_integration_by_id("testxyz");
        // EnvGuard restores HOME on scope exit (even on panic), so
        // asserts can run inline without ordering around the restore.
        assert!(!manifest_path.exists(), "manifest file should be deleted");
        assert!(
            !app.config
                .ui
                .integration_icons
                .iter()
                .any(|i| i.id == "testxyz"),
            "rail chip should be removed"
        );
    }

    /// #851 phase 2 — `remove_integration_by_id` must also delete
    /// the sidecar override so a later re-install of the same id
    /// doesn't inherit partial user chrome from a stale
    /// `<id>.override.toml`.
    #[test]
    fn remove_integration_by_id_also_deletes_override_sidecar() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let dir = tmp.path().join(".config").join("mnml").join("integrations");
        std::fs::create_dir_all(&dir).unwrap();
        let base = dir.join("testxyz.toml");
        let over = dir.join("testxyz.override.toml");
        std::fs::write(&base, "id = \"testxyz\"\nlabel = \"X\"\n").unwrap();
        std::fs::write(&over, "id = \"testxyz\"\n").unwrap();
        let ws = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(ws.path().to_path_buf(), crate::config::Config::default())
                .unwrap();
        app.remove_integration_by_id("testxyz");
        assert!(!base.exists(), "base .toml should be deleted");
        assert!(!over.exists(), "sidecar .override.toml should be deleted");
    }

    /// #851 phase 2 — Edit-mode save writes to
    /// `<id>.override.toml`, not to `[[ui.integration_icon]]` in
    /// config.toml. Assert the file content contains the fields
    /// the loader reads (id, chip.glyph, chip.color, etc.).
    /// A base `<id>.toml` is seeded first so the promotion path
    /// (see `write_override_toml_promotes_to_authored_when_no_base`)
    /// doesn't fire and we exercise the true override write.
    #[test]
    fn write_override_toml_emits_loader_readable_shape() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        // Seed a canonical `myint.toml` so write_override_toml
        // stays on the override path (vs the no-base promotion).
        let dir = tmp.path().join(".config").join("mnml").join("integrations");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("myint.toml"),
            "id = \"myint\"\nlabel = \"canonical\"\n",
        )
        .unwrap();
        let icon = IntegrationIcon {
            id: "myint".to_string(),
            glyph: "M".to_string(),
            fallback: "M".to_string(),
            command: "myint.open".to_string(),
            color: "purple".to_string(),
            label: Some("My Integration".to_string()),
            enabled: true,
            in_palette_bar: true,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        };
        let path = write_override_toml(&icon).expect("write");
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("id = \"myint\""));
        assert!(body.contains("label = \"My Integration\""));
        assert!(body.contains("[chip]"));
        assert!(body.contains("glyph = \"M\""));
        assert!(body.contains("color = \"purple\""));
        assert!(body.contains("in_palette_bar = true"));
        // File landed in the integrations dir under HOME.
        assert!(path.ends_with("myint.override.toml"));
    }

    /// #851 code review Critical #1 — Edit on a chip with no base
    /// `<id>.toml` (e.g., the three first-party Rust-hardcoded
    /// defaults browser/claude_code/codex) must NOT silently drop
    /// on next scan. Prior behavior wrote `<id>.override.toml` for
    /// them, which the loader discarded as an orphan override.
    /// Fix: promote to a full authored `<id>.toml` when no base
    /// exists.
    /// 2026-08-07 regression — user report: Claude Code + Codex kept
    /// getting disabled on every restart. Cause: unconditional cleanup
    /// of built-in-id manifests nuked the file that `write_override_toml`
    /// had legitimately written. This test proves an authored manifest
    /// (real glyph + real command) survives the cleanup call.
    #[test]
    fn cleanup_preserves_legitimate_builtin_manifest() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let icon = IntegrationIcon {
            id: "codex".to_string(),
            glyph: "\u{F1E01}".to_string(),
            fallback: "\u{276F}_".to_string(),
            command: "ai.codex".to_string(),
            color: "cyan".to_string(),
            label: Some("Codex".to_string()),
            enabled: true,
            in_palette_bar: true,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        };
        let path = write_override_toml(&icon).expect("write");
        assert!(path.exists(), "manifest written by toggle path");
        let cleaned = cleanup_retired_id_manifests();
        assert_eq!(
            cleaned, 0,
            "legitimate builtin manifest must not be deleted"
        );
        assert!(path.exists(), "codex.toml must survive cleanup");
    }

    /// 2026-08-07 — the OTHER side of the fix. A pre-c7d781b7 bogus
    /// scaffold (empty glyph, `<id>.open` command) still gets deleted
    /// so old broken files don't stick around forever.
    #[test]
    fn cleanup_still_deletes_bogus_builtin_scaffold() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let dir = tmp.path().join(".config").join("mnml").join("integrations");
        std::fs::create_dir_all(&dir).unwrap();
        let bogus = dir.join("codex.toml");
        // Signature of the pre-c7d781b7 migration bug: `label = <id>`
        // + empty glyph + `<id>.open` command.
        std::fs::write(
            &bogus,
            "id = \"codex\"\nlabel = \"codex\"\ncommand = \"codex.open\"\n\n[chip]\nglyph = \"\"\n",
        )
        .unwrap();
        let cleaned = cleanup_retired_id_manifests();
        assert_eq!(cleaned, 1, "bogus scaffold must be deleted");
        assert!(!bogus.exists(), "bogus codex.toml should be gone");
    }

    #[test]
    fn write_override_toml_promotes_to_authored_when_no_base() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let icon = IntegrationIcon {
            id: "claude_code".to_string(),
            glyph: "C".to_string(),
            fallback: "C".to_string(),
            command: "ai.claude_code".to_string(),
            color: "orange".to_string(),
            label: Some("Claude".to_string()),
            enabled: true,
            in_palette_bar: false,
            description: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            version: None,
            commands: Vec::new(),
        };
        // No base `<id>.toml` exists at HOME/.config/mnml/integrations/.
        let path = write_override_toml(&icon).expect("write");
        let dir = tmp.path().join(".config").join("mnml").join("integrations");
        let base = dir.join("claude_code.toml");
        let over = dir.join("claude_code.override.toml");
        assert!(
            path.ends_with("claude_code.toml"),
            "expected authored .toml, got {path:?}"
        );
        assert!(base.exists(), "base file must exist after promotion");
        assert!(!over.exists(), "no override sidecar for a promoted write");
    }

    /// #851 phase 3 — legacy block with `enabled = false` migrates to
    /// an `<id>.override.toml` and the block is stripped from
    /// config.toml. Idempotent — a second call with no legacy
    /// blocks is a no-op.
    #[test]
    fn migrate_legacy_integration_icon_blocks_writes_override_and_strips() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        // Ubuntu CI has XDG_CONFIG_HOME set to /home/runner/.config,
        // which `config::user_config_path()` prefers over $HOME. That
        // sent the migrate at the real user's config, not our tmpdir
        // seed, so both migration tests failed on ubuntu-latest
        // (2026-08-04). Unset for the duration of this test.
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        // Seed a canonical manifest so the migration writes an
        // override (vs promoting to authored).
        let idir = tmp.path().join(".config").join("mnml").join("integrations");
        std::fs::create_dir_all(&idir).unwrap();
        std::fs::write(
            idir.join("mystery.toml"),
            "id = \"mystery\"\nlabel = \"Mystery\"\n",
        )
        .unwrap();
        // Seed config.toml with a legacy block that has a delta.
        let cfg_dir = tmp.path().join(".config").join("mnml");
        std::fs::create_dir_all(&cfg_dir).unwrap();
        let cfg_path = cfg_dir.join("config.toml");
        std::fs::write(
            &cfg_path,
            "[ui]\ntheme = \"onedark\"\n\n\
             [[ui.integration_icon]]\nid = \"mystery\"\nenabled = false\n",
        )
        .unwrap();

        let (n, warns) = migrate_legacy_integration_icon_blocks().unwrap();
        assert_eq!(n, 1, "one block migrated");
        assert!(warns.is_empty(), "no warnings: {warns:?}");
        // Override sidecar exists with enabled=false.
        let override_path = idir.join("mystery.override.toml");
        assert!(override_path.exists(), "override sidecar written");
        let body = std::fs::read_to_string(&override_path).unwrap();
        assert!(
            body.contains("enabled = false"),
            "override preserves enabled=false: {body}"
        );
        // config.toml has the legacy block stripped, [ui]/theme preserved.
        let after = std::fs::read_to_string(&cfg_path).unwrap();
        assert!(
            after.contains("theme = \"onedark\""),
            "non-integration keys survive: {after}"
        );
        assert!(
            !after.contains("[[ui.integration_icon]]"),
            "legacy block removed: {after}"
        );
        // Idempotent — second call is a no-op returning (0, empty).
        let (n2, warns2) = migrate_legacy_integration_icon_blocks().unwrap();
        assert_eq!(n2, 0, "second call migrates nothing");
        assert!(warns2.is_empty());
    }

    /// #851 phase 3 — legacy block that carries only manifest
    /// defaults gets stripped without writing an override (no delta
    /// to preserve).
    #[test]
    fn migrate_legacy_default_only_block_strips_without_override() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        // See sibling test for why — Ubuntu CI has XDG_CONFIG_HOME
        // set, which shadows $HOME in config::user_config_path().
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let idir = tmp.path().join(".config").join("mnml").join("integrations");
        std::fs::create_dir_all(&idir).unwrap();
        std::fs::write(idir.join("thing.toml"), "id = \"thing\"\nlabel = \"T\"\n").unwrap();
        let cfg_dir = tmp.path().join(".config").join("mnml");
        std::fs::create_dir_all(&cfg_dir).unwrap();
        let cfg_path = cfg_dir.join("config.toml");
        std::fs::write(
            &cfg_path,
            "[[ui.integration_icon]]\nid = \"thing\"\nenabled = true\n",
        )
        .unwrap();
        let (n, _) = migrate_legacy_integration_icon_blocks().unwrap();
        assert_eq!(n, 1, "block counted as migrated");
        assert!(
            !idir.join("thing.override.toml").exists(),
            "no override for default-only block"
        );
        assert!(
            !std::fs::read_to_string(&cfg_path)
                .unwrap()
                .contains("[[ui.integration_icon]]"),
            "block still stripped"
        );
    }
}
