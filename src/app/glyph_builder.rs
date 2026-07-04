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

    /// Open the glyph builder pre-filled from an existing glyph's
    /// stored metadata (`~/.config/mnml/glyph_meta.toml`). Used by
    /// the icon picker's `e` key to re-tune width/height/center for
    /// a previously-baked custom glyph without retyping the SVG path.
    ///
    /// Returns `false` when no metadata exists for `cp` — caller
    /// should toast that the glyph wasn't built via mnml (e.g. it's
    /// a stock Nerd Font glyph) and no edit path applies.
    pub fn open_glyph_builder_for_edit_cp(&mut self, cp: u32) -> bool {
        use crate::glyph_builder::{
            BuilderField, GlyphBuilderState, category_for_codepoint, load_meta,
        };
        let meta = load_meta();
        let cp_hex = format!("{cp:04X}");
        let Some(entry) = meta.glyphs.iter().find(|g| g.codepoint == cp_hex) else {
            return false;
        };
        let s = GlyphBuilderState {
            svg_path: entry.svg.clone(),
            category: category_for_codepoint(cp),
            name: entry.name.clone(),
            codepoint_hex: entry.codepoint.clone(),
            width_frac: entry.width_frac,
            height_frac: entry.height_frac,
            center_frac: entry.center_frac,
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
}
