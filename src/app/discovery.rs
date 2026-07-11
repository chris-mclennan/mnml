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
    /// Hover tooltip shown by the bufferline chip.
    pub tooltip: String,
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
    pub tooltip_cursor: usize,
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

impl App {
    /// Open the integration-edit panel for the integration with the
    /// given id. Surfaced from the chip's right-click context menu.
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
        let tooltip = icon.tooltip.unwrap_or_default();
        let tooltip_cursor = tooltip.len();
        self.integration_edit = Some(IntegrationEditState {
            mode: IntegrationEditMode::Edit,
            id: icon.id,
            command: icon.command,
            glyph: icon.glyph,
            fallback: icon.fallback,
            color: icon.color,
            tooltip,
            focused_field: IntegrationEditField::Glyph,
            id_cursor,
            command_cursor,
            glyph_cursor,
            fallback_cursor,
            tooltip_cursor,
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
        for li in &self.config.ui.launcher_icons {
            if let Some(c) = li.glyph.chars().next() {
                taken.insert(c as u32);
            }
        }
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
        // Backtick-quoted id to match every other confirm-dialog
        // title (`Delete branch \`name\`?`, `Remove worktree
        // \`name\`?`, etc.). design-critic 2026-07-09.
        // Shortened copy so it doesn't truncate at ~45 cells on
        // longer ids — vscode-user-mouse 2026-07-09.
        let title = format!("Remove integration `{id}`?");
        self.pending_integration_remove_id = Some(id);
        let mut p =
            crate::prompt::Prompt::new(crate::prompt::PromptKind::IntegrationRemoveConfirm, title);
        // Cancel default (safety first) — mirrors the delete-confirm
        // pattern from `open_fs_delete_prompt`.
        p.cursor = 1;
        self.prompt = Some(p);
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
            tooltip: if panel.tooltip.trim().is_empty() {
                None
            } else {
                Some(panel.tooltip.trim().to_string())
            },
            enabled: true,
            in_palette_bar: false,
            manifest_can_override: false,
        };
        match panel.mode {
            IntegrationEditMode::Edit => {
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
        self.integration_edit = None;
    }

    /// Tab → move focus to the next field. `delta = 1` for forward,
    /// `-1` for backward (Shift+Tab). Skips `Id` / `Command` when
    /// the panel is in `Edit` mode (those fields are read-only).
    pub fn integration_edit_cycle_field(&mut self, delta: isize) {
        use IntegrationEditField::*;
        let order_full = [Id, Command, Glyph, Fallback, Color, Tooltip];
        let order_edit = [Glyph, Fallback, Color, Tooltip];
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
            Tooltip => panel.tooltip_cursor = panel.tooltip_cursor.min(panel.tooltip.len()),
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
            IntegrationEditField::Tooltip => (&mut panel.tooltip, &mut panel.tooltip_cursor, 128),
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
            IntegrationEditField::Tooltip => (&mut panel.tooltip, &mut panel.tooltip_cursor, 128),
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
            IntegrationEditField::Tooltip => (&mut panel.tooltip, &mut panel.tooltip_cursor),
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
            IntegrationEditField::Tooltip => (&mut panel.tooltip, &mut panel.tooltip_cursor),
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
            IntegrationEditField::Tooltip => (&panel.tooltip, &mut panel.tooltip_cursor),
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
            IntegrationEditField::Tooltip => (&panel.tooltip, &mut panel.tooltip_cursor),
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
            IntegrationEditField::Tooltip => panel.tooltip_cursor = 0,
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
            IntegrationEditField::Tooltip => panel.tooltip_cursor = panel.tooltip.len(),
            IntegrationEditField::Color => {}
        }
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
    let path = crate::config::user_config_path()
        .ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let new_line = format!("{key} = \"{value}\"");

    let mut out: Vec<String> = Vec::new();
    let mut in_ui = false;
    let mut ui_header_idx: Option<usize> = None;
    let mut key_replaced = false;
    for line in existing.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            // Section header — leave `in_ui` for the `[ui]` case only.
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
            // Preserve indentation.
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
            // No `[ui]` section anywhere — add one.
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

/// Sugar for the top-bar cluster mode setter. Called from the
/// TABS right-click menu.
pub fn persist_top_bar_cluster_mode(mode: &'static str) -> Result<std::path::PathBuf, String> {
    persist_ui_string("top_bar_cluster_mode", mode)
}

pub fn persist_launcher_icons(
    icons: &[crate::config::LauncherIcon],
) -> Result<std::path::PathBuf, String> {
    let path = crate::config::user_config_path()
        .ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let stripped = strip_launcher_icon_blocks(&existing);
    let appended = append_launcher_icon_blocks(&stripped, icons);
    std::fs::write(&path, appended).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// Mirror of `MANAGED_BANNER_MARKER` for the launcher_icons section.
const MANAGED_LAUNCHER_BANNER_MARKER: &str = "# ── mnml-managed launcher icons";

/// Remove every existing `[[ui.launcher_icon]]` block (and its
/// managed-section banner) from `src`.
fn strip_launcher_icon_blocks(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut skipping = false;
    let mut last_was_blank = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with(MANAGED_LAUNCHER_BANNER_MARKER) {
            skipping = true;
            continue;
        }
        if trimmed == "[[ui.launcher_icon]]" {
            skipping = true;
            continue;
        }
        if skipping {
            if (trimmed.starts_with('[') && !trimmed.starts_with("[ "))
                && trimmed != "[[ui.launcher_icon]]"
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

fn append_launcher_icon_blocks(existing: &str, icons: &[crate::config::LauncherIcon]) -> String {
    let mut out = existing.trim_end().to_string();
    if !out.is_empty() {
        out.push_str("\n\n");
    }
    out.push_str("# ── mnml-managed launcher icons ──────────────────────────────────────\n");
    out.push_str("# Written by the integration / launcher right-click menus. Edit by\n");
    out.push_str("# hand or via the chip context menu — re-saves replace this section.\n\n");
    for ic in icons {
        out.push_str("[[ui.launcher_icon]]\n");
        out.push_str(&format!("id = {}\n", toml_str(&ic.id)));
        out.push_str(&format!("glyph = {}\n", toml_str(&ic.glyph)));
        out.push_str(&format!("fallback = {}\n", toml_str(&ic.fallback)));
        out.push_str(&format!("command = {}\n", toml_str(&ic.command)));
        out.push_str(&format!("color = {}\n", toml_str(&ic.color)));
        if let Some(t) = &ic.tooltip {
            out.push_str(&format!("tooltip = {}\n", toml_str(t)));
        }
        out.push_str(&format!("enabled = {}\n", ic.enabled));
        out.push('\n');
    }
    out
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
    out.push_str("# Written by the chip right-click → Edit panel. Edit by hand or via\n");
    out.push_str("# the panel — re-saves replace this section in place.\n\n");
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
        out.push_str(&format!("enabled = {}\n", ic.enabled));
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
            tooltip: String::new(),
            focused_field: IntegrationEditField::Glyph,
            id_cursor: 0,
            command_cursor: 0,
            glyph_cursor: 4, // end of 4-byte glyph
            fallback_cursor: 0,
            tooltip_cursor: 0,
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
                tooltip: Some("Lambda".to_string()),
                enabled: false,
                in_palette_bar: false,
                manifest_can_override: false,
            },
            IntegrationIcon {
                id: "s3".to_string(),
                glyph: "y".to_string(),
                fallback: "S3".to_string(),
                command: ":term mnml-fs-s3".to_string(),
                color: "orange".to_string(),
                tooltip: None,
                enabled: false,
                in_palette_bar: false,
                manifest_can_override: false,
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
            in_palette_bar: false,
            manifest_can_override: false,
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
            tooltip: Some("My App".to_string()),
            enabled: true,
            in_palette_bar: false,
            manifest_can_override: false,
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
            tooltip: None,
            enabled: false,
            in_palette_bar: false,
            manifest_can_override: false,
        }];
        let toml_out = append_integration_icon_blocks("", &icons);
        assert!(
            toml_out.contains("enabled = false"),
            "enabled=false must appear literally; got:\n{toml_out}"
        );
    }

    #[test]
    fn append_launcher_icon_blocks_serializes_enabled_field() {
        let icons = vec![crate::config::LauncherIcon {
            id: "browser".to_string(),
            glyph: "\u{F0239}".to_string(),
            fallback: "B".to_string(),
            command: "view.browser".to_string(),
            color: "blue".to_string(),
            tooltip: Some("Open browser pane".to_string()),
            enabled: true,
        }];
        let toml_out = append_launcher_icon_blocks("", &icons);
        assert!(toml_out.contains("[[ui.launcher_icon]]"));
        assert!(toml_out.contains("enabled = true"));
        let stripped = strip_launcher_icon_blocks(&toml_out);
        assert!(
            !stripped.contains("[[ui.launcher_icon]]"),
            "strip should remove launcher blocks; got:\n{stripped}"
        );
    }
}
