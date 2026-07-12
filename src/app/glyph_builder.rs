//! `App` methods for the glyph builder panel — open/close, key
//! dispatch (via cycle_field / type_char / cycle_value / backspace),
//! and commit (bake the SVG into MnmlSymbols.ttf).
//!
//! The panel state itself lives in `crate::glyph_builder`.

use crate::app::App;
use crate::glyph_builder::{BuilderField, GlyphBuilderState};

impl App {
    /// Open a fresh glyph builder panel. Cursor lands on the SVG path
    /// field first so the user can paste + Tab straight into the
    /// preview flow.
    pub fn open_glyph_builder(&mut self) {
        self.glyph_builder = Some(GlyphBuilderState::new());
    }

    /// Same as `open_glyph_builder`, but marks the panel as opened
    /// from an integration edit context. On commit, the resulting
    /// codepoint char flows back into the edit panel's Glyph field
    /// so the user doesn't have to reopen it manually.
    pub fn open_glyph_builder_from_edit(&mut self) {
        let mut s = GlyphBuilderState::new();
        s.from_integration_edit = true;
        // Also close the icon picker if it's open (this path can be
        // reached from the picker's "+ Create custom glyph" row).
        self.picker = None;
        self.glyph_builder = Some(s);
    }

    /// Open the glyph builder pre-filled from a glyph's saved
    /// metadata. Precedence:
    ///
    ///   1. User's `~/.config/mnml/glyph_meta.toml` (per-bake meta —
    ///      whatever the user baked most recently, including custom
    ///      SVGs they added themselves).
    ///   2. `BUILTIN_GLYPHS` shipped list (the AWS set + future
    ///      built-ins). The SVG is resolved from the mnml install
    ///      or dev tree; if it's not found on disk, we can't render
    ///      a preview and fall through to `false`.
    ///
    /// Returns `false` when neither source has an entry — caller
    /// toasts that the glyph wasn't built via mnml.
    pub fn open_glyph_builder_for_edit_cp(&mut self, cp: u32) -> bool {
        use crate::glyph_builder::{
            BuilderField, GlyphBuilderState, builtin_for_codepoint, category_for_codepoint,
            load_meta, resolve_builtin_svg,
        };
        let cp_hex = format!("{cp:04X}");

        // 1. User meta — most recent per-bake state wins.
        let meta = load_meta();
        let (svg, name, width, height, center) =
            if let Some(entry) = meta.glyphs.iter().find(|g| g.codepoint == cp_hex) {
                (
                    entry.svg.clone(),
                    entry.name.clone(),
                    entry.width_frac,
                    entry.height_frac,
                    entry.center_frac,
                )
            } else if let Some(bi) = builtin_for_codepoint(cp) {
                // 2. Fall back to the built-in catalog.
                let Some(svg_path) = resolve_builtin_svg(bi.svg_relpath) else {
                    return false;
                };
                (
                    svg_path.to_string_lossy().into_owned(),
                    bi.name.to_string(),
                    bi.width_frac,
                    bi.height_frac,
                    bi.center_frac,
                )
            } else {
                return false;
            };

        let s = GlyphBuilderState {
            svg_path_cursor: svg.len(),
            name_cursor: name.len(),
            codepoint_hex_cursor: cp_hex.len(),
            svg_path: svg,
            category: category_for_codepoint(cp),
            name,
            codepoint_hex: cp_hex,
            width_frac: width,
            height_frac: height,
            center_frac: center,
            focused_field: BuilderField::WidthFrac,
            preview_png: None,
            preview_signature: None,
            error: None,
            from_integration_edit: self.integration_edit.is_some(),
        };
        self.picker = None;
        self.glyph_builder = Some(s);
        true
    }

    pub fn close_glyph_builder(&mut self) {
        self.glyph_builder = None;
    }

    pub fn glyph_builder_cycle_field(&mut self, delta: isize) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.cycle_field(delta);
        }
    }

    pub fn glyph_builder_cycle_value(&mut self, delta: isize) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.cycle_value(delta);
        }
    }

    pub fn glyph_builder_type_char(&mut self, ch: char) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.type_char(ch);
        }
    }

    pub fn glyph_builder_backspace(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.backspace();
        }
    }

    pub fn glyph_builder_delete_forward(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.delete_forward();
        }
    }

    pub fn glyph_builder_move_left(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.move_cursor_left();
        }
    }

    pub fn glyph_builder_move_right(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.move_cursor_right();
        }
    }

    pub fn glyph_builder_move_home(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.move_cursor_home();
        }
    }

    pub fn glyph_builder_move_end(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.move_cursor_end();
        }
    }

    /// Ctrl+V paste into the currently-focused text field. Reads from
    /// the app's clipboard (which mirrors the OS clipboard on macOS).
    /// Trims surrounding whitespace + strips quotes so a shell-copied
    /// path like `'~/foo/bar.svg'` pastes as `~/foo/bar.svg`.
    pub fn glyph_builder_paste(&mut self) {
        let text = self.clipboard.text();
        let cleaned = text
            .trim()
            .trim_matches(|c| c == '\'' || c == '"')
            .to_string();
        if cleaned.is_empty() {
            return;
        }
        if let Some(s) = self.glyph_builder.as_mut() {
            s.insert_str(&cleaned);
        }
    }

    /// Bake the panel's SVG into MnmlSymbols.ttf at the selected
    /// codepoint with the tuned size/alignment. Shells out to
    /// `scripts/build_mnml_symbols.py` for the fontforge work,
    /// then flushes the font cache. On success: toast the codepoint
    /// + close the panel.
    pub fn glyph_builder_commit(&mut self) {
        let Some(s) = self.glyph_builder.clone() else {
            return;
        };
        let svg = s.svg_path.trim();
        if svg.is_empty() {
            self.toast("glyph builder: SVG path is empty");
            return;
        }
        if !std::path::Path::new(svg).exists() {
            self.toast(format!("glyph builder: SVG not found: {svg}"));
            return;
        }
        let name = s.name.trim();
        let name_owned;
        let name = if name.is_empty() {
            // Derive from filename stem + category prefix.
            let stem = std::path::Path::new(svg)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("glyph");
            name_owned = format!("{}-{}", s.category.label(), stem);
            name_owned.as_str()
        } else {
            name
        };
        let cp_str = s.codepoint_hex.trim();
        let cp = match u32::from_str_radix(cp_str, 16) {
            Ok(cp) if cp > 0 => cp,
            _ => {
                self.toast(format!(
                    "glyph builder: codepoint must be hex, got {cp_str:?}"
                ));
                return;
            }
        };
        if cp < s.category.range_start() || cp > s.category.range_end() {
            self.toast(format!(
                "glyph builder: codepoint U+{cp:04X} outside {} range (U+{:04X}-U+{:04X})",
                s.category.label(),
                s.category.range_start(),
                s.category.range_end(),
            ));
            return;
        }
        let Some(home) = std::env::var_os("HOME") else {
            self.toast("glyph builder: $HOME unset");
            return;
        };
        let home = std::path::PathBuf::from(home);
        let font_out = home.join("Library/Fonts/MnmlSymbols.ttf");
        // The build script needs a script path. Walk up from the
        // running binary looking for scripts/build_mnml_symbols.py.
        let script = match std::env::current_exe()
            .ok()
            .and_then(|p| {
                let mut cur = p;
                while cur.pop() {
                    let cand = cur.join("scripts/build_mnml_symbols.py");
                    if cand.exists() {
                        return Some(cand);
                    }
                }
                None
            })
            .or_else(|| {
                let cand = home.join("Projects/mnml/scripts/build_mnml_symbols.py");
                if cand.exists() { Some(cand) } else { None }
            }) {
            Some(p) => p,
            None => {
                self.toast("glyph builder: build_mnml_symbols.py not found in tree");
                return;
            }
        };
        // Spawn fontforge in a Pty pane so the user can watch the
        // build; when it exits, MnmlSymbols.ttf is refreshed on disk.
        // Pass the tuned width/height/center as extras so the panel's
        // preview matches the baked glyph.
        let glyph_spec = format!(
            "{svg}:{cp:04X}:{name}:width={:.2}:height={:.2}:center={:.2}",
            s.width_frac, s.height_frac, s.center_frac
        );
        let profile = crate::pty_pane::BinaryProfile {
            label: format!("bake glyph U+{cp:04X}"),
            exe: "fontforge".to_string(),
            args: vec![
                "-script".to_string(),
                script.to_string_lossy().into_owned(),
                "--output".to_string(),
                font_out.to_string_lossy().into_owned(),
                "--glyph".to_string(),
                glyph_spec,
            ],
            cwd: None,
            env: vec![],
            session_id: None,
        };
        // Persist the build metadata so the "edit existing" flow
        // (picker `e` key) can re-load it. Best-effort — write
        // failure just means the user can't re-tune later without
        // remembering the SVG path.
        crate::glyph_builder::upsert_meta(crate::glyph_builder::GlyphMeta {
            codepoint: format!("{cp:04X}"),
            name: name.to_string(),
            svg: svg.to_string(),
            width_frac: s.width_frac,
            height_frac: s.height_frac,
            center_frac: s.center_frac,
        });
        // Copy the codepoint char to the clipboard so the user can
        // paste it into their integration config immediately.
        let cp_char = char::from_u32(cp);
        if let Some(c) = cp_char {
            let mut clip = crate::clipboard::Clipboard::new();
            clip.set(c.to_string(), false);
        }
        let route_to_edit = s.from_integration_edit;
        self.close_glyph_builder();
        // Route the codepoint char straight back into the still-open
        // integration edit panel's Glyph field when we were opened
        // from that context.
        if route_to_edit
            && let Some(c) = cp_char
            && let Some(panel) = self.integration_edit.as_mut()
        {
            panel.focused_field = crate::app::discovery::IntegrationEditField::Glyph;
            panel.glyph.clear();
            panel.glyph.push(c);
            // Sibling of the picker.rs SEV-1 fix 2026-07-11: reset the
            // Glyph field cursor so a stale byte-offset from a
            // previously-typed / previously-picked glyph of a different
            // UTF-8 width doesn't land mid-codepoint on the newly-baked
            // one. Next backspace / arrow would then panic on the
            // byte-slice.
            panel.glyph_cursor = panel.glyph.len();
        }
        self.open_pty(profile);
        if route_to_edit {
            self.toast(format!(
                "baking U+{cp:04X} · glyph inserted into edit panel · restart terminal after fontforge exits"
            ));
        } else {
            self.toast(format!(
                "baking U+{cp:04X} · glyph copied · restart terminal after fontforge exits"
            ));
        }
    }

    /// Where the UI should look for the current focus. Used by the
    /// key handler + the renderer to keep the two in sync.
    pub fn glyph_builder_focused_field(&self) -> Option<BuilderField> {
        self.glyph_builder.as_ref().map(|s| s.focused_field)
    }

    /// Open the 3-option "what do you want to do with a glyph?"
    /// chooser. Fired by Enter on the Glyph field of the integration
    /// edit panel so the user doesn't have to remember Right = browse,
    /// Ctrl+N = new, or that the picker has an edit-existing key.
    pub fn open_glyph_action_menu(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        // Only offer "Edit current glyph" when the current Glyph field
        // has a codepoint we can actually load (custom U+F1B00+ range,
        // and there's meta OR a shipped built-in for it).
        let cur_cp: Option<u32> = self
            .integration_edit
            .as_ref()
            .and_then(|p| p.glyph.chars().next().map(|c| c as u32));
        let has_editable = cur_cp.is_some_and(|cp| {
            let cp_hex = format!("{cp:04X}");
            let meta = crate::glyph_builder::load_meta();
            meta.glyphs.iter().any(|g| g.codepoint == cp_hex)
                || crate::glyph_builder::builtin_for_codepoint(cp).is_some()
        });
        let mut items = vec![
            PickerItem {
                id: "library".to_string(),
                label: "󰉦  Choose from library".to_string(),
                detail: "browse all glyphs".to_string(),
                priority: 0,
            },
            PickerItem {
                id: "new".to_string(),
                label: "  Create custom glyph…".to_string(),
                // Copy hints at when Edit isn't available — Nerd Font
                // glyphs (E000-F1AFF) come from the FONT itself, so
                // mnml can't scale them. Users who want to resize /
                // re-center a Nerd Font icon bake their own SVG at a
                // new codepoint via this action. 2026-07-11.
                detail: "bake an SVG · use this to resize a Nerd Font glyph".to_string(),
                priority: 0,
            },
        ];
        if has_editable {
            let name = cur_cp
                .and_then(|cp| crate::glyph_builder::builtin_for_codepoint(cp).map(|b| b.name))
                .unwrap_or("current glyph");
            items.insert(
                1,
                PickerItem {
                    id: "edit".to_string(),
                    label: format!("  Edit current ({name})"),
                    detail: "re-tune size / alignment".to_string(),
                    priority: 0,
                },
            );
        } else if cur_cp.is_some() {
            // Show a disabled-looking hint row explaining why Edit
            // isn't offered — the user's asked for it multiple times
            // now, and the silence read as a missing feature. 2026-07-11.
            items.insert(
                1,
                PickerItem {
                    id: "edit_unavailable".to_string(),
                    label: "  Edit current (unavailable)".to_string(),
                    detail: "Nerd Font glyph — scale via `Create custom glyph…`".to_string(),
                    priority: 0,
                },
            );
        }
        let picker = Picker::new(PickerKind::GlyphAction, "Glyph action", items);
        self.open_picker(picker);
    }

    /// Dispatch a `PickerKind::GlyphAction` accept. Called from the
    /// picker's accept handler.
    pub fn glyph_action_dispatch(&mut self, id: &str) {
        match id {
            "library" => {
                self.close_picker();
                self.open_icon_picker();
            }
            "new" => {
                self.close_picker();
                self.open_glyph_builder_from_edit();
            }
            "edit" => {
                self.close_picker();
                let cur_cp = self
                    .integration_edit
                    .as_ref()
                    .and_then(|p| p.glyph.chars().next().map(|c| c as u32));
                if let Some(cp) = cur_cp
                    && !self.open_glyph_builder_for_edit_cp(cp)
                {
                    self.toast(format!(
                        "glyph U+{cp:04X} not editable — no metadata + not shipped"
                    ));
                }
            }
            "edit_unavailable" => {
                // No-op selection — the row exists purely to
                // surface WHY Edit isn't available. Close the menu
                // and toast the workaround one more time so the
                // user has the hint even after picking blindly.
                self.close_picker();
                self.toast(
                    "Nerd Font glyphs can't be scaled — use `Create custom glyph…` to bake an SVG at a new codepoint",
                );
            }
            _ => {}
        }
    }
}
