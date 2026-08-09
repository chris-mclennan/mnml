//! `App` methods for the glyph builder panel — open/close, key
//! dispatch (via cycle_field / type_char / cycle_value / backspace),
//! and commit (bake the SVG into MnmlSymbols.ttf).
//!
//! The panel state itself lives in `crate::glyph_builder`.

use crate::app::App;
use crate::glyph_builder::{BUILTIN_GLYPHS, BuilderField, GlyphBuilderState, GlyphMetaFile};

/// Pick the next free codepoint in mnml's PUA range (0xF1B00+) that
/// isn't already occupied by a shipped built-in OR a user-baked
/// custom glyph. Scans linearly — the range is small (~256 slots).
/// 2026-07-11 user request — the "Edit current" flow for Nerd Font
/// glyphs bakes a scaled replacement at a new custom codepoint,
/// leaving the original Nerd Font entry untouched.
fn next_free_mnml_pua_codepoint(meta: &GlyphMetaFile) -> u32 {
    let taken: std::collections::HashSet<u32> = BUILTIN_GLYPHS
        .iter()
        .map(|b| b.codepoint)
        .chain(
            meta.glyphs
                .iter()
                .filter_map(|g| u32::from_str_radix(&g.codepoint, 16).ok()),
        )
        .collect();
    for cp in 0xF1B00..=0xF1BFF {
        if !taken.contains(&cp) {
            return cp;
        }
    }
    // Fall back at the top of the range if the tuning band is
    // somehow saturated (never happens in practice).
    0xF1BFF
}

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
    ///      a preview and fall through to a fresh-start blank
    ///      builder for that codepoint (user request 2026-07-11 —
    ///      the previous "unavailable" no-op was frustrating).
    ///   3. Nerd Font glyphs (E000-F1AFF and 0xF0000+ ranges outside
    ///      mnml's private-use band) — open a blank builder with
    ///      the next-free mnml PUA codepoint pre-filled and the
    ///      icon-catalog name copied as the suggested name, so the
    ///      user can paste an SVG and bake a scaled replacement.
    ///
    /// Always returns `true` now.
    pub fn open_glyph_builder_for_edit_cp(&mut self, cp: u32) -> bool {
        use crate::glyph_builder::{
            BuilderField, GlyphBuilderState, builtin_for_codepoint, category_for_codepoint,
            load_meta, resolve_builtin_svg,
        };
        let cp_hex = format!("{cp:04X}");

        // 1. User meta — most recent per-bake state wins.
        let meta = load_meta();
        let (svg, name, codepoint_hex, width, height, center, center_x, focused_field) =
            if let Some(entry) = meta.glyphs.iter().find(|g| g.codepoint == cp_hex) {
                (
                    entry.svg.clone(),
                    entry.name.clone(),
                    cp_hex.clone(),
                    entry.width_frac,
                    entry.height_frac,
                    entry.center_frac,
                    entry.center_x_frac,
                    BuilderField::WidthFrac,
                )
            } else if let Some(bi) = builtin_for_codepoint(cp) {
                // 2. Fall back to the built-in catalog. If the SVG isn't
                //    resolvable on disk (rare — usually only when running
                //    from an install without the assets), still open a
                //    blank builder pre-filled with the codepoint + name
                //    so the user has SOMETHING to work with.
                match resolve_builtin_svg(bi.svg_relpath) {
                    Some(svg_path) => (
                        svg_path.to_string_lossy().into_owned(),
                        bi.name.to_string(),
                        cp_hex.clone(),
                        bi.width_frac,
                        bi.height_frac,
                        bi.center_frac,
                        bi.center_x_frac,
                        BuilderField::WidthFrac,
                    ),
                    None => (
                        String::new(),
                        bi.name.to_string(),
                        cp_hex.clone(),
                        bi.width_frac,
                        bi.height_frac,
                        bi.center_frac,
                        bi.center_x_frac,
                        BuilderField::Path,
                    ),
                }
            } else {
                // 3. Nerd Font / unknown glyph. Open the builder with a
                //    NEW mnml PUA codepoint so baking creates a scaled
                //    replacement (leaving the Nerd Font entry untouched
                //    but letting the integration edit panel commit the
                //    new codepoint). Copy the icon-catalog name as a
                //    starting suggestion.
                let name = crate::icon_catalog::ICON_CATALOG
                    .iter()
                    .find(|e| u32::from_str_radix(e.codepoint, 16).ok() == Some(cp))
                    .map(|e| format!("custom-{}", e.name))
                    .unwrap_or_else(|| format!("custom-{cp_hex}"));
                let next_cp = next_free_mnml_pua_codepoint(&meta);
                (
                    String::new(),
                    name,
                    format!("{next_cp:04X}"),
                    1.20,
                    0.85,
                    0.36,
                    0.5,
                    BuilderField::Path,
                )
            };
        let category = if codepoint_hex == cp_hex {
            category_for_codepoint(cp)
        } else {
            category_for_codepoint(u32::from_str_radix(&codepoint_hex, 16).unwrap_or(cp))
        };
        let s = GlyphBuilderState {
            svg_path_cursor: svg.len(),
            name_cursor: name.len(),
            codepoint_hex_cursor: codepoint_hex.len(),
            svg_path: svg,
            category,
            name,
            codepoint_hex,
            width_frac: width,
            height_frac: height,
            center_frac: center,
            center_x_frac: center_x,
            focused_field,
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

    /// Reset the focused numeric field back to its default. `r`
    /// in the glyph builder overlay.
    pub fn glyph_builder_reset_focused(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.reset_focused_to_default();
        }
    }

    /// Reset every numeric field (width / height / center Y /
    /// center X) back to its default. `R` (Shift+r) in the
    /// overlay.
    pub fn glyph_builder_reset_all(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.reset_all_to_default();
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

    /// 2026-08-08 — Ctrl+W kill-word-back on the focused text field.
    pub fn glyph_builder_delete_word_back(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.delete_word_back();
        }
    }

    /// 2026-08-08 — Ctrl+U kill-to-start on the focused text field.
    pub fn glyph_builder_delete_to_start(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.delete_to_start();
        }
    }

    /// 2026-08-08 — Ctrl+K kill-to-end on the focused text field.
    pub fn glyph_builder_delete_to_end(&mut self) {
        if let Some(s) = self.glyph_builder.as_mut() {
            s.delete_to_end();
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
            "{svg}:{cp:04X}:{name}:width={:.2}:height={:.2}:center={:.2}:x_center={:.2}",
            s.width_frac, s.height_frac, s.center_frac, s.center_x_frac
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
            integration_id: None,
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
            center_x_frac: s.center_x_frac,
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

    /// Bake the mnml-owned AI chip glyphs into
    /// `~/Library/Fonts/MnmlSymbols.ttf`. Covers:
    /// - F1E00 (claude-spark), F1E01 (codex) — AI brand glyphs
    /// - F1E10..F1E14 — Claude thinking-spinner frames
    pub fn bake_ai_glyphs_default(&mut self) {
        // 2026-08-08 — expanded from F1E00/F1E01 to include the
        // Claude thinking-spinner frames at F1E10..F1E14 (baked with
        // Latin cap-mid center_frac so they align with tab text
        // instead of sitting at the font baseline like raw dingbats).
        self.bake_builtin_glyphs_matching(|cp| {
            cp == 0xF1E00 || cp == 0xF1E01 || (0xF1E10..=0xF1E14).contains(&cp)
        });
    }

    /// #814 — one-tap rebake for a single codepoint. Skips the visual
    /// builder: reads the last-baked meta (or falls back to the built-
    /// in catalog entry) and shells out to fontforge with the same
    /// SVG + width/height/center numbers that produced the stored
    /// glyph. Used by the integration-chip right-click "Rebake glyph
    /// now" menu item.
    ///
    /// Toasts + returns false when the codepoint has neither a stored
    /// meta entry NOR a builtin catalog entry (nothing to rebake).
    pub fn rebake_glyph_for_cp(&mut self, cp: u32) -> bool {
        use crate::glyph_builder::{builtin_for_codepoint, load_meta, resolve_builtin_svg};
        let cp_hex = format!("{cp:04X}");
        let meta = load_meta();
        let entry = meta.glyphs.iter().find(|g| g.codepoint == cp_hex);
        let (svg, name, w, h, c, cx) = if let Some(m) = entry {
            (
                m.svg.clone(),
                m.name.clone(),
                m.width_frac,
                m.height_frac,
                m.center_frac,
                m.center_x_frac,
            )
        } else if let Some(bi) = builtin_for_codepoint(cp) {
            let Some(path) = resolve_builtin_svg(bi.svg_relpath) else {
                self.toast(format!(
                    "rebake U+{cp:04X}: builtin SVG missing ({})",
                    bi.svg_relpath
                ));
                return false;
            };
            (
                path.to_string_lossy().into_owned(),
                bi.name.to_string(),
                bi.width_frac,
                bi.height_frac,
                bi.center_frac,
                bi.center_x_frac,
            )
        } else {
            self.toast(format!("rebake U+{cp:04X}: no stored meta or builtin"));
            return false;
        };
        let Some(home) = std::env::var_os("HOME") else {
            self.toast("rebake glyph: $HOME unset");
            return false;
        };
        let home = std::path::PathBuf::from(home);
        let font_out = home.join("Library/Fonts/MnmlSymbols.ttf");
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
                self.toast("rebake glyph: build_mnml_symbols.py not found");
                return false;
            }
        };
        let glyph_spec = format!(
            "{svg}:{cp:04X}:{name}:width={w:.2}:height={h:.2}:center={c:.2}:x_center={cx:.2}"
        );
        let profile = crate::pty_pane::BinaryProfile {
            label: format!("rebake U+{cp:04X}"),
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
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!(
            "rebaking U+{cp:04X} ({name}) · restart terminal after fontforge exits"
        ));
        true
    }

    /// Bake every mnml `BuiltinGlyph` into MnmlSymbols in one pass
    /// — AI + AWS + Dev tools. Same shell-out shape, just a wider
    /// filter. Used by `integrations.bake_all_glyphs`.
    pub fn bake_all_builtin_glyphs(&mut self) {
        self.bake_builtin_glyphs_matching(|_| true);
    }

    fn bake_builtin_glyphs_matching<F: Fn(u32) -> bool>(&mut self, keep: F) {
        use crate::glyph_builder::{BUILTIN_GLYPHS, load_meta, resolve_builtin_svg};
        let ai_glyphs: Vec<_> = BUILTIN_GLYPHS
            .iter()
            .filter(|g| keep(g.codepoint))
            .collect();
        if ai_glyphs.is_empty() {
            self.toast("bake glyphs: no builtins matched the filter");
            return;
        }
        // 2026-08-08 (user report: "what happened to the ghostty
        // icon?") — the fontforge script writes a NEW MnmlSymbols.ttf
        // containing ONLY the `--glyph` args we pass. Prior versions
        // of this fn passed just the filter set, which meant a
        // selective rebake (e.g. tuning F1E00 size while iterating)
        // wiped every other baked glyph: custom user glyphs (ghostty
        // terminal), all sibling-baked AWS/GCP glyphs, everything.
        // Fix: seed `resolved` from `glyph_meta.toml` (the record of
        // every glyph ever baked into the font) so the output always
        // includes them, then override any filter-matched entries
        // with the fresh builtin values.
        let mut resolved: Vec<(String, u32, String, f32, f32, f32, f32)> = Vec::new();
        let mut seen_codepoints: std::collections::HashSet<u32> = std::collections::HashSet::new();
        // Seed from meta first — every previously-baked glyph.
        for m in load_meta().glyphs {
            let Ok(cp) = u32::from_str_radix(&m.codepoint, 16) else {
                continue;
            };
            // Skip if the source SVG no longer exists — passing it to
            // fontforge would abort the whole bake. Prefer silent drop
            // (glyph won't be in the new font, but the bake succeeds
            // for everything else) over hard failure.
            if !std::path::Path::new(&m.svg).exists() {
                continue;
            }
            if keep(cp) {
                // This codepoint is in the filter — will be overridden
                // by the builtin loop below with fresh values.
                continue;
            }
            resolved.push((
                m.svg,
                cp,
                m.name,
                m.width_frac,
                m.height_frac,
                m.center_frac,
                m.center_x_frac,
            ));
            seen_codepoints.insert(cp);
        }
        // Now layer in the freshly-filtered builtins (fresh tuning wins).
        for g in &ai_glyphs {
            match resolve_builtin_svg(g.svg_relpath) {
                Some(path) => {
                    resolved.push((
                        path.to_string_lossy().into_owned(),
                        g.codepoint,
                        g.name.to_string(),
                        g.width_frac,
                        g.height_frac,
                        g.center_frac,
                        g.center_x_frac,
                    ));
                    seen_codepoints.insert(g.codepoint);
                }
                None => {
                    self.toast(format!("bake AI glyphs: SVG not found — {}", g.svg_relpath));
                    return;
                }
            }
        }
        let Some(home) = std::env::var_os("HOME") else {
            self.toast("bake AI glyphs: $HOME unset");
            return;
        };
        let home = std::path::PathBuf::from(home);
        let font_out = home.join("Library/Fonts/MnmlSymbols.ttf");
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
                self.toast("bake AI glyphs: build_mnml_symbols.py not found");
                return;
            }
        };
        let mut args: Vec<String> = vec![
            "-script".to_string(),
            script.to_string_lossy().into_owned(),
            "--output".to_string(),
            font_out.to_string_lossy().into_owned(),
        ];
        for (svg, cp, name, w, h, c, cx) in &resolved {
            args.push("--glyph".to_string());
            args.push(format!(
                "{svg}:{cp:04X}:{name}:width={:.2}:height={:.2}:center={:.2}:x_center={:.2}",
                w, h, c, cx
            ));
            // Only upsert meta for entries that came from `ai_glyphs`
            // — meta-sourced entries are already in the file. This
            // also avoids rewriting them with identical values every
            // bake.
            if BUILTIN_GLYPHS.iter().any(|g| g.codepoint == *cp) {
                crate::glyph_builder::upsert_meta(crate::glyph_builder::GlyphMeta {
                    codepoint: format!("{cp:04X}"),
                    name: name.clone(),
                    svg: svg.clone(),
                    width_frac: *w,
                    height_frac: *h,
                    center_frac: *c,
                    center_x_frac: *cx,
                });
            }
        }
        let preserved = resolved.len().saturating_sub(ai_glyphs.len());
        let profile = crate::pty_pane::BinaryProfile {
            label: "bake AI glyphs".to_string(),
            exe: "fontforge".to_string(),
            args,
            cwd: None,
            env: vec![],
            session_id: None,
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!(
            "baking {} glyph(s) + preserving {} prior glyph(s) · restart terminal after fontforge exits",
            ai_glyphs.len(),
            preserved
        ));
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
        let cur_cp: Option<u32> = self
            .integration_edit
            .as_ref()
            .and_then(|p| p.glyph.chars().next().map(|c| c as u32));
        let mut items = vec![PickerItem {
            id: "library".to_string(),
            label: "󰉦  Choose from library".to_string(),
            detail: "browse all glyphs".to_string(),
            priority: 0,
        }];
        // Edit current — always offered when there IS a current glyph.
        // For shipped/user-baked glyphs, opens the tuning panel with
        // the existing SVG loaded. For Nerd Font glyphs (no SVG on
        // hand), opens the builder pointed at a fresh mnml PUA
        // codepoint so the user can paste an SVG and bake a scaled
        // replacement. The integration edit panel picks up the new
        // codepoint on commit. 2026-07-11 user request — was
        // greyed-out "unavailable" for Nerd Font glyphs, which was
        // frustrating since the underlying capability (bake a
        // scaled SVG) has always been there.
        if let Some(cp) = cur_cp {
            let cp_hex = format!("{cp:04X}");
            let meta = crate::glyph_builder::load_meta();
            let is_editable = meta.glyphs.iter().any(|g| g.codepoint == cp_hex)
                || crate::glyph_builder::builtin_for_codepoint(cp).is_some();
            let (label, detail) = if is_editable {
                let name = crate::glyph_builder::builtin_for_codepoint(cp)
                    .map(|b| b.name)
                    .unwrap_or("current glyph");
                (
                    format!("  Edit current ({name})"),
                    "re-tune size / alignment".to_string(),
                )
            } else {
                let name = crate::icon_catalog::ICON_CATALOG
                    .iter()
                    .find(|e| u32::from_str_radix(e.codepoint, 16).ok() == Some(cp))
                    .map(|e| e.name)
                    .unwrap_or("current glyph");
                (
                    format!("  Edit current ({name})"),
                    "bake a scaled replacement at a new codepoint".to_string(),
                )
            };
            items.push(PickerItem {
                id: "edit".to_string(),
                label,
                detail,
                priority: 0,
            });
        }
        items.push(PickerItem {
            id: "new".to_string(),
            label: "  Create custom glyph…".to_string(),
            detail: "bake an SVG at a fresh codepoint".to_string(),
            priority: 0,
        });
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
            _ => {}
        }
    }
}
