//! `GlyphBuilderState` — in-flight state for the "Add custom glyph"
//! panel. Owns the SVG path, target codepoint, size/alignment
//! transforms, and a cached rasterized preview.
//!
//! The panel is opened from `integrations.glyph_builder` and lets the
//! user pick an SVG, tune width/height/vertical-center, and eyeball a
//! live preview before baking the glyph into `MnmlSymbols.ttf`.
//!
//! Preview implementation: `usvg` parses the SVG, `resvg` rasterizes
//! to RGBA, `image` re-encodes as PNG, then the render loop hands off
//! to the sixel encoder for terminal display.

use std::path::Path;

use resvg::tiny_skia::Pixmap;
use resvg::usvg::{Options, Transform, Tree};

/// Which field the panel's edit cursor is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuilderField {
    /// Filesystem path to the SVG source. Type / backspace to edit.
    Path,
    /// Category — pins the codepoint into the reserved block for that
    /// integration family (aws / gcp / azure / ai / saas / dev).
    /// ←→ cycles.
    Category,
    /// Internal glyph name (aws-amplify-inv, etc.). Auto-suggested from
    /// the SVG filename + category; user can override.
    Name,
    /// 4- or 5-digit hex codepoint. Auto-picks the next free slot in
    /// the category range; user can override with typed hex.
    Codepoint,
    /// Cell-width fraction. 1.0 fits exactly; >1.0 overflows.
    /// ←→ cycles 0.05.
    WidthFrac,
    /// Em-height fraction. Bigger = taller glyph. ←→ cycles 0.05.
    HeightFrac,
    /// Vertical center as a fraction of em. 0.36 = Latin cap-mid on
    /// JetBrainsMono NF (recommended default). ←→ cycles 0.02.
    CenterFrac,
    /// Horizontal center as a fraction of the cell's advance width.
    /// 0.5 = auto-center-on-bbox (dead middle of the cell); values
    /// below shift the glyph LEFT, values above shift RIGHT.
    /// ←→ cycles 0.02. Useful for SVGs with padded viewBoxes or
    /// asymmetric content — e.g. the codex.svg viewBox starts at
    /// x=175, so its content weight sits right-of-center under
    /// the default auto-centering.
    CenterXFrac,
}

/// Category range plan (matches `src/icon_catalog.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuilderCategory {
    Aws,
    /// U+F1C00-F1CFF — integration-shipped icons (auto-assigned when a
    /// integration drops an SVG via `mnml-bridge::install_integration`
    /// with `ChipSpec::glyph_svg`). Manual builder use is fine too;
    /// the codepoint pool is shared.
    IntegrationSvg,
    Azure,
    Ai,
    Saas,
    DevTool,
}

impl BuilderCategory {
    pub const ALL: &'static [BuilderCategory] = &[
        BuilderCategory::Aws,
        BuilderCategory::IntegrationSvg,
        BuilderCategory::Azure,
        BuilderCategory::Ai,
        BuilderCategory::Saas,
        BuilderCategory::DevTool,
    ];

    pub fn label(self) -> &'static str {
        match self {
            BuilderCategory::Aws => "aws",
            BuilderCategory::IntegrationSvg => "integration",
            BuilderCategory::Azure => "azure",
            BuilderCategory::Ai => "ai",
            BuilderCategory::Saas => "saas",
            BuilderCategory::DevTool => "dev",
        }
    }

    pub fn range_start(self) -> u32 {
        match self {
            BuilderCategory::Aws => 0xF1B00,
            BuilderCategory::IntegrationSvg => 0xF1C00,
            BuilderCategory::Azure => 0xF1D00,
            BuilderCategory::Ai => 0xF1E00,
            BuilderCategory::Saas => 0xF1F00,
            BuilderCategory::DevTool => 0xF2000,
        }
    }

    pub fn range_end(self) -> u32 {
        self.range_start() + 0xFF
    }

    pub fn cycled(self, delta: isize) -> Self {
        let idx = Self::ALL.iter().position(|c| *c == self).unwrap_or(0) as isize;
        let n = Self::ALL.len() as isize;
        let next = (idx + delta).rem_euclid(n) as usize;
        Self::ALL[next]
    }
}

#[derive(Debug, Clone)]
pub struct GlyphBuilderState {
    pub svg_path: String,
    pub category: BuilderCategory,
    pub name: String,
    pub codepoint_hex: String,
    pub width_frac: f32,
    pub height_frac: f32,
    pub center_frac: f32,
    /// Horizontal center as a fraction of cell-width. 0.5 =
    /// auto-center on the glyph bbox (historical default).
    /// 2026-07-19 user request.
    pub center_x_frac: f32,
    pub focused_field: BuilderField,
    /// Cached rasterized preview PNG. Recomputed whenever a field
    /// that affects the preview changes (path, w/h/center).
    pub preview_png: Option<Vec<u8>>,
    /// Signature of the last successfully rendered state — skip the
    /// re-rasterize when nothing that affects the preview changed.
    pub preview_signature: Option<PreviewSignature>,
    /// Non-empty when the last preview attempt failed. Renderer shows
    /// this in the preview area instead of an image.
    pub error: Option<String>,
    /// True when opened from inside an integration edit panel (via
    /// Ctrl+N on the Glyph field OR the "+ Create custom glyph" row
    /// in the icon picker). On commit, the baked codepoint char
    /// flows straight back into the edit panel's Glyph field so the
    /// user doesn't have to reopen the edit panel and paste.
    pub from_integration_edit: bool,
    /// Byte-offset cursor into the currently-focused text field.
    /// Kept per-field so switching back to a field lands where the
    /// user left off. Clamped to the field's byte length on every
    /// edit + on field switch. 2026-07-11 (fixes "can't arrow back
    /// to fix mid-string typos" reported by the user).
    pub svg_path_cursor: usize,
    pub name_cursor: usize,
    pub codepoint_hex_cursor: usize,
}

/// The values `reset_focused_to_default` / `reset_all_to_default`
/// snap fields back to. Pulled from a matching `BuiltinGlyph`
/// entry when the current codepoint is one mnml ships, else from
/// the hard-coded starting defaults.
#[derive(Debug, Clone, Copy)]
struct FieldDefaults {
    width_frac: f32,
    height_frac: f32,
    center_frac: f32,
    center_x_frac: f32,
}

/// Hash-friendly snapshot of the fields the preview depends on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewSignature {
    pub path: String,
    pub w: u32, // bit-cast f32 (`to_bits`)
    pub h: u32,
    pub c: u32,  // center_y
    pub cx: u32, // center_x
}

impl Default for GlyphBuilderState {
    fn default() -> Self {
        Self {
            svg_path: String::new(),
            category: BuilderCategory::Aws,
            name: String::new(),
            codepoint_hex: format!("{:04X}", BuilderCategory::Aws.range_start()),
            width_frac: 1.25,
            height_frac: 0.80,
            center_frac: 0.36,
            center_x_frac: 0.5,
            focused_field: BuilderField::Path,
            preview_png: None,
            preview_signature: None,
            error: None,
            from_integration_edit: false,
            svg_path_cursor: 0,
            name_cursor: 0,
            // Codepoint field defaults to the range-start hex; place
            // cursor at end so typing/backspacing edits the tail.
            codepoint_hex_cursor: 0,
        }
    }
}

impl GlyphBuilderState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Snapshot the preview-affecting fields into a signature so a
    /// caller can compare against `preview_signature` and skip
    /// re-rasterizing when nothing changed.
    pub fn signature(&self) -> PreviewSignature {
        PreviewSignature {
            path: self.svg_path.clone(),
            w: self.width_frac.to_bits(),
            h: self.height_frac.to_bits(),
            c: self.center_frac.to_bits(),
            cx: self.center_x_frac.to_bits(),
        }
    }

    /// Cycle the currently-focused field's value by `delta` (in whole
    /// notches — +1 or -1). Fields with continuous ranges have their
    /// own step. Text fields (path, name, codepoint) ignore this and
    /// respond to typing.
    pub fn cycle_value(&mut self, delta: isize) {
        match self.focused_field {
            BuilderField::Category => {
                self.category = self.category.cycled(delta);
                // Re-pick a fresh codepoint in the new category's range.
                self.codepoint_hex = format!("{:04X}", self.category.range_start());
            }
            BuilderField::WidthFrac => {
                self.width_frac = (self.width_frac + 0.05 * delta as f32).clamp(0.5, 2.0);
            }
            BuilderField::HeightFrac => {
                self.height_frac = (self.height_frac + 0.05 * delta as f32).clamp(0.4, 1.2);
            }
            BuilderField::CenterFrac => {
                self.center_frac = (self.center_frac + 0.02 * delta as f32).clamp(0.2, 0.6);
            }
            BuilderField::CenterXFrac => {
                self.center_x_frac = (self.center_x_frac + 0.02 * delta as f32).clamp(0.2, 0.8);
            }
            _ => {}
        }
    }

    /// Reset the currently-focused numeric field to its default.
    /// If the current codepoint matches a `BUILTIN_GLYPHS` entry,
    /// that entry's tuned value is the default; otherwise the
    /// hard-coded starting default (matches `Default::default()`).
    /// No-op on text fields — those don't have "defaults" beyond
    /// backspace-clear.
    pub fn reset_focused_to_default(&mut self) {
        let defaults = self.defaults_for_current_codepoint();
        match self.focused_field {
            BuilderField::WidthFrac => self.width_frac = defaults.width_frac,
            BuilderField::HeightFrac => self.height_frac = defaults.height_frac,
            BuilderField::CenterFrac => self.center_frac = defaults.center_frac,
            BuilderField::CenterXFrac => self.center_x_frac = defaults.center_x_frac,
            _ => {}
        }
    }

    /// Reset every numeric field to its default (width, height,
    /// center Y, center X). Same default-source rules as
    /// `reset_focused_to_default`.
    pub fn reset_all_to_default(&mut self) {
        let defaults = self.defaults_for_current_codepoint();
        self.width_frac = defaults.width_frac;
        self.height_frac = defaults.height_frac;
        self.center_frac = defaults.center_frac;
        self.center_x_frac = defaults.center_x_frac;
    }

    fn defaults_for_current_codepoint(&self) -> FieldDefaults {
        u32::from_str_radix(&self.codepoint_hex, 16)
            .ok()
            .and_then(builtin_for_codepoint)
            .map(|bi| FieldDefaults {
                width_frac: bi.width_frac,
                height_frac: bi.height_frac,
                center_frac: bi.center_frac,
                center_x_frac: bi.center_x_frac,
            })
            .unwrap_or(FieldDefaults {
                width_frac: 1.25,
                height_frac: 0.80,
                center_frac: 0.36,
                center_x_frac: 0.50,
            })
    }

    /// Append a char to the focused text field. No-op for non-text
    /// fields.
    pub fn type_char(&mut self, ch: char) {
        // Cap at 4096 chars for path (macOS paths can hit 1024+),
        // 128 for name, 5 hex digits for codepoint.
        let (buf, cursor, cap): (&mut String, &mut usize, usize) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor, 4096),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor, 128),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor, 5),
            _ => return,
        };
        if buf.chars().count() >= cap {
            return;
        }
        let cur = (*cursor).min(buf.len());
        buf.insert(cur, ch);
        *cursor = cur + ch.len_utf8();
    }

    /// Insert a full string at the cursor — used by Ctrl+V paste
    /// (2026-07-11). Newlines and control chars are stripped so a
    /// clipboard with a trailing newline doesn't break the
    /// single-line field. Respects the field's char cap.
    pub fn insert_str(&mut self, s: &str) {
        let (buf, cursor, cap): (&mut String, &mut usize, usize) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor, 4096),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor, 128),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor, 5),
            _ => return,
        };
        let cleaned: String = s
            .chars()
            .filter(|c| !c.is_control() && *c != '\r' && *c != '\n')
            .collect();
        if cleaned.is_empty() {
            return;
        }
        // Cap = how many MORE chars we can accept.
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

    pub fn backspace(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
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
    pub fn delete_forward(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
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
        // cursor stays put
    }

    pub fn move_cursor_left(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
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

    pub fn move_cursor_right(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
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

    pub fn move_cursor_home(&mut self) {
        match self.focused_field {
            BuilderField::Path => self.svg_path_cursor = 0,
            BuilderField::Name => self.name_cursor = 0,
            BuilderField::Codepoint => self.codepoint_hex_cursor = 0,
            _ => {}
        }
    }

    pub fn move_cursor_end(&mut self) {
        match self.focused_field {
            BuilderField::Path => self.svg_path_cursor = self.svg_path.len(),
            BuilderField::Name => self.name_cursor = self.name.len(),
            BuilderField::Codepoint => self.codepoint_hex_cursor = self.codepoint_hex.len(),
            _ => {}
        }
    }

    /// 2026-08-08 — Ctrl+W kill-word-back on the focused text field.
    pub fn delete_word_back(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
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
    pub fn delete_to_start(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
        };
        let cur = (*cursor).min(buf.len());
        buf.replace_range(..cur, "");
        *cursor = 0;
    }

    /// 2026-08-08 — Ctrl+K kill-to-end on the focused text field.
    pub fn delete_to_end(&mut self) {
        let (buf, cursor) = match self.focused_field {
            BuilderField::Path => (&mut self.svg_path, &mut self.svg_path_cursor),
            BuilderField::Name => (&mut self.name, &mut self.name_cursor),
            BuilderField::Codepoint => (&mut self.codepoint_hex, &mut self.codepoint_hex_cursor),
            _ => return,
        };
        let cur = (*cursor).min(buf.len());
        buf.truncate(cur);
    }

    /// Read-only cursor byte offset for the currently-focused text
    /// field. Used by the renderer to draw the caret.
    pub fn active_text_cursor(&self) -> Option<usize> {
        Some(match self.focused_field {
            BuilderField::Path => self.svg_path_cursor.min(self.svg_path.len()),
            BuilderField::Name => self.name_cursor.min(self.name.len()),
            BuilderField::Codepoint => self.codepoint_hex_cursor.min(self.codepoint_hex.len()),
            _ => return None,
        })
    }

    pub fn cycle_field(&mut self, delta: isize) {
        use BuilderField::*;
        let order = [
            Path,
            Category,
            Name,
            Codepoint,
            WidthFrac,
            HeightFrac,
            CenterFrac,
            CenterXFrac,
        ];
        let cur = order
            .iter()
            .position(|f| *f == self.focused_field)
            .unwrap_or(0) as isize;
        let n = order.len() as isize;
        let next = (cur + delta).rem_euclid(n) as usize;
        self.focused_field = order[next];
        // Clamp cursor to the new field's byte length so a stale
        // out-of-bounds value from a longer field can't crash the
        // insert path. Land the cursor at end-of-field so typing
        // resumes at a natural place. 2026-07-11.
        match self.focused_field {
            Path => self.svg_path_cursor = self.svg_path_cursor.min(self.svg_path.len()),
            Name => self.name_cursor = self.name_cursor.min(self.name.len()),
            Codepoint => {
                self.codepoint_hex_cursor = self.codepoint_hex_cursor.min(self.codepoint_hex.len())
            }
            _ => {}
        }
    }
}

/// Parse `path` as an SVG, rasterize at (roughly) `target_w × target_h`
/// pixels applying the same size/alignment transforms the font builder
/// uses, and return PNG-encoded bytes ready for the sixel encoder.
///
/// The transform pipeline mirrors `scripts/build_mnml_symbols.py`:
/// scale so the glyph fits in a `cell × em` box under the given
/// width/height fractions, then center vertically at `center_frac * em`.
pub fn rasterize(
    path: &str,
    width_frac: f32,
    height_frac: f32,
    center_frac: f32,
    center_x_frac: f32,
    target_w: u32,
    target_h: u32,
) -> Result<Vec<u8>, String> {
    if path.trim().is_empty() {
        return Err("no SVG path".to_string());
    }
    let p = Path::new(path);
    if !p.exists() {
        return Err(format!("file not found: {path}"));
    }
    let bytes = std::fs::read(p).map_err(|e| format!("read {path}: {e}"))?;
    let opt = Options::default();
    let tree = Tree::from_data(&bytes, &opt).map_err(|e| format!("parse svg: {e}"))?;

    // Font-cell reference geometry — matches build_mnml_symbols.py.
    const CELL_W: f32 = 600.0;
    const EM: f32 = 1000.0;

    // Use the actual CONTENT bounding box (not the viewBox) so
    // amplify-style SVGs with lots of viewBox padding still fill the
    // preview correctly. `abs_bounding_box` walks the render tree.
    let content_bbox = tree.root().abs_bounding_box();
    let src_x = content_bbox.x();
    let src_y = content_bbox.y();
    let src_w = content_bbox.width();
    let src_h = content_bbox.height();
    if src_w <= 0.0 || src_h <= 0.0 {
        return Err("empty svg".to_string());
    }

    let target_w_units = CELL_W * width_frac;
    let target_h_units = EM * height_frac;
    let scale = (target_w_units / src_w).min(target_h_units / src_h);

    // Pixmap aspect is (CELL_W * OVERFLOW_MARGIN) : EM so we have
    // room for glyphs that overflow the em-box horizontally (any
    // width_frac > 1.0). Without the margin, wide glyphs like
    // amplify at width=1.25 get clipped on both sides of the pixmap.
    // 1.5 covers everything up to width_frac = 1.5 without cropping.
    const OVERFLOW_MARGIN: f32 = 1.5;
    let box_w = CELL_W * OVERFLOW_MARGIN;
    let (pixmap_w, pixmap_h) = if (target_h as f32) * box_w >= (target_w as f32) * EM {
        let h = target_h.max(2);
        let w = ((h as f32) * box_w / EM).round() as u32;
        (w.max(2), h)
    } else {
        let w = target_w.max(2);
        let h = ((w as f32) * EM / box_w).round() as u32;
        (w, h.max(2))
    };
    // SAME px per em-unit on both axes so the glyph never distorts.
    // Height wins because we scale the em-box to the pixmap height.
    let px_per_unit = pixmap_h as f32 / EM;

    // Position the glyph inside the pixmap. Both axes use the same
    // px_per_unit so no distortion. Center horizontally on the pixmap
    // (which is 1.5× cell-width) so overflow shows symmetrically on
    // left + right. Vertically, `center_frac` is measured from the
    // baseline up (y-up); convert once to top-down pixmap space
    // (`1 - center_frac`).
    let px_glyph_w = src_w * scale * px_per_unit;
    let px_glyph_h = src_h * scale * px_per_unit;
    let px_center_y = (1.0 - center_frac) * pixmap_h as f32;
    // Horizontal: nudge from the pixmap's midpoint. The pixmap is
    // 1.5× cell-width; center_x_frac=0.5 puts the glyph in the
    // dead middle (historical auto-center behavior). Values <0.5
    // shift LEFT, values >0.5 shift RIGHT. Delta from midpoint is
    // proportional to (center_x_frac - 0.5) × CELL_W in em-units,
    // scaled to pixmap pixels.
    let px_nudge_x = (center_x_frac - 0.5) * CELL_W * px_per_unit;
    let px_left = (pixmap_w as f32 - px_glyph_w) / 2.0 + px_nudge_x;
    let px_top = px_center_y - px_glyph_h / 2.0;

    let mut pixmap = Pixmap::new(pixmap_w, pixmap_h).ok_or("alloc pixmap")?;

    // Compose (resvg applies right-to-left):
    //   1. Shift the content-bbox origin to (0,0) so scaling is pinned
    //      to the actual glyph, not the viewBox's padding.
    //   2. Scale SVG units → pixmap pixels using the font-size scale
    //      times the em → pixel ratio (same for X and Y).
    //   3. Translate to (px_left, px_top) inside the pixmap.
    let s = scale * px_per_unit;
    let t = Transform::from_translate(-src_x, -src_y)
        .post_scale(s, s)
        .post_translate(px_left, px_top);
    resvg::render(&tree, t, &mut pixmap.as_mut());

    // Encode as PNG (image crate) so the existing sixel encoder can
    // ingest it.
    let img = image::RgbaImage::from_raw(pixmap_w, pixmap_h, pixmap.data().to_vec())
        .ok_or("wrap rgba")?;
    let mut png = Vec::with_capacity((pixmap_w * pixmap_h) as usize);
    let dyn_img = image::DynamicImage::ImageRgba8(img);
    dyn_img
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .map_err(|e| format!("png encode: {e}"))?;
    Ok(png)
}

/// Per-glyph metadata for a glyph that mnml SHIPS. Used when the
/// user's `~/.config/mnml/glyph_meta.toml` doesn't have an entry for
/// a codepoint they want to edit — falls back to the shipped SVG
/// path so the edit-existing flow works out of the box for the 12
/// AWS icons (and any future built-ins).
///
/// The `svg_relpath` is resolved at runtime against the mnml source
/// tree — either the installed app's `Contents/Resources/glyphs/…`
/// or the dev tree's `assets/glyphs/…`. See `resolve_builtin_svg`.
#[derive(Debug, Clone, Copy)]
pub struct BuiltinGlyph {
    pub codepoint: u32,
    pub name: &'static str,
    pub svg_relpath: &'static str,
    pub width_frac: f32,
    pub height_frac: f32,
    pub center_frac: f32,
    /// Horizontal center as a fraction of cell-width; 0.5 =
    /// auto-center-on-bbox. Optional-esque — every BUILTIN_GLYPHS
    /// entry supplies it; historical AWS defaults are all 0.5.
    pub center_x_frac: f32,
}

/// mnml-shipped glyphs. Codepoints match `src/icon_catalog.rs`.
/// Defaults match the tuned `scripts/build_mnml_symbols.sh`.
///
/// 2026-08-01 — Stage 2 of the integration-owned icon SDK removed the
/// per-service AWS SVGs that used to live here (cloudwatch / codebuild
/// / cognito / ecr / ecs / eventbridge / lambda / rds / sns / sqs
/// + amplify). Each is now shipped by its own `mnml-aws-*` integration
/// via `ChipSpec::glyph_svg + glyph_codepoint`. Only `dynamodb`
/// (deferred, will migrate to `mnml-db`) still lives in mnml core.
pub const BUILTIN_GLYPHS: &[BuiltinGlyph] = &[
    // 2026-08-05 — restored the dev btop/htop/iftop entries. The
    // 2026-08-04 cleanup that removed them assumed launcher tomls
    // would ship SVG bytes via ChipSpec::glyph_svg — but the
    // launcher catalog is data-only (no cargo, no include_bytes!),
    // so those chips lost their glyphs. Better to keep the SVGs
    // baked into mnml core since only a handful of launcher tools
    // ever need a mnml-owned codepoint. (dynamodb stays out — it's
    // owned by the mnml-db sibling which DOES ship its own SVG.)
    //
    // DevTool range (F2000-F20FF) — used to bake btop/htop/iftop
    // PUA glyphs before launchers switched to the real Nerd Fonts
    // codepoints (F0A07/F0379/F06F3 = md-monitor_dashboard/
    // md-monitor/md-network) on 2026-08-05. Entries removed +
    // assets/glyphs/dev/ folder deleted 2026-08-06. Range stays
    // reserved for future first-party dev-tool bakes.
    //
    // AI range (F1E00-F1EFF).
    BuiltinGlyph {
        codepoint: 0xF1E00,
        // 2026-08-07 — swapped from the original "spark burst" SVG to
        // the user-supplied Claude Code app-icon glyph (square 24×24
        // viewBox with a keyboard-row pattern). Old values (1.20 /
        // 0.75 / 0.28) were tuned for the tall-narrow spark and
        // rendered the new shape as an oddly-warped blob.
        // Fresh values: square aspect (1.4/1.4 slightly larger than
        // cell so the glyph reads on par with sibling codicons),
        // dead-center anchor.
        name: "ai-claude-spark",
        svg_relpath: "assets/glyphs/ai/claude-spark.svg",
        // 2026-08-08 — settled at 1-cell width after the tuning spiral
        // (center_x_frac nudges rounded to whole-pixel boundaries in
        // ghostty and never actually shifted the icon). At 1.0 the
        // glyph fits inside its cell, ghostty places it dead-center
        // like every other nerd-font icon, and Claude visually
        // matches its siblings in the list.
        width_frac: 1.35,
        height_frac: 1.35,
        center_frac: 0.30,
        center_x_frac: 0.35,
    },
    BuiltinGlyph {
        codepoint: 0xF1E01,
        name: "ai-codex",
        svg_relpath: "assets/glyphs/ai/codex.svg",
        width_frac: 1.20,
        height_frac: 0.75,
        center_frac: 0.28,
        center_x_frac: 0.5,
    },
    // 2026-08-08 — Claude thinking-spinner frames, mnml-owned so we can
    // set `center_frac = 0.36` (Latin cap-mid) and align vertically with
    // the tab label. Previously used raw Unicode dingbats (✳ ✢ ✶ ✻ ✽)
    // rendered via ghostty's fallback font, which places them at the
    // text baseline — visually LOWER than the caps above. F1E10..F1E14
    // are private-use codepoints; the animation in pty_pane.rs maps to
    // these so the spinner reads as a proper vertical peer to text.
    BuiltinGlyph {
        codepoint: 0xF1E10,
        name: "ai-spinner-a",
        svg_relpath: "assets/glyphs/ai/spinner/spinner-a.svg",
        width_frac: 0.90,
        height_frac: 0.90,
        center_frac: 0.36,
        center_x_frac: 0.5,
    },
    BuiltinGlyph {
        codepoint: 0xF1E11,
        name: "ai-spinner-b",
        svg_relpath: "assets/glyphs/ai/spinner/spinner-b.svg",
        width_frac: 0.90,
        height_frac: 0.90,
        center_frac: 0.36,
        center_x_frac: 0.5,
    },
    BuiltinGlyph {
        codepoint: 0xF1E12,
        name: "ai-spinner-c",
        svg_relpath: "assets/glyphs/ai/spinner/spinner-c.svg",
        width_frac: 0.90,
        height_frac: 0.90,
        center_frac: 0.36,
        center_x_frac: 0.5,
    },
    BuiltinGlyph {
        codepoint: 0xF1E13,
        name: "ai-spinner-d",
        svg_relpath: "assets/glyphs/ai/spinner/spinner-d.svg",
        width_frac: 0.90,
        height_frac: 0.90,
        center_frac: 0.36,
        center_x_frac: 0.5,
    },
    BuiltinGlyph {
        codepoint: 0xF1E14,
        name: "ai-spinner-e",
        svg_relpath: "assets/glyphs/ai/spinner/spinner-e.svg",
        width_frac: 0.90,
        height_frac: 0.90,
        center_frac: 0.36,
        center_x_frac: 0.5,
    },
];

/// SVGs embedded into the binary so the AI-glyph bake path
/// never depends on the on-disk source layout. 2026-07-19 user
/// report: running the release binary from
/// `~/Projects/mnml/target/release/` while the actual worktree
/// was `~/Projects/mnml-one-tab-type/` — every on-disk fallback
/// missed. When resolve_builtin_svg can't find one of these on
/// disk, it drops the embedded copy into `/tmp` and returns
/// that path.
const EMBEDDED_SVGS: &[(&str, &[u8])] = &[
    (
        "assets/glyphs/ai/claude-spark.svg",
        include_bytes!("../assets/glyphs/ai/claude-spark.svg"),
    ),
    (
        "assets/glyphs/ai/codex.svg",
        include_bytes!("../assets/glyphs/ai/codex.svg"),
    ),
    (
        "assets/glyphs/ai/spinner/spinner-a.svg",
        include_bytes!("../assets/glyphs/ai/spinner/spinner-a.svg"),
    ),
    (
        "assets/glyphs/ai/spinner/spinner-b.svg",
        include_bytes!("../assets/glyphs/ai/spinner/spinner-b.svg"),
    ),
    (
        "assets/glyphs/ai/spinner/spinner-c.svg",
        include_bytes!("../assets/glyphs/ai/spinner/spinner-c.svg"),
    ),
    (
        "assets/glyphs/ai/spinner/spinner-d.svg",
        include_bytes!("../assets/glyphs/ai/spinner/spinner-d.svg"),
    ),
    (
        "assets/glyphs/ai/spinner/spinner-e.svg",
        include_bytes!("../assets/glyphs/ai/spinner/spinner-e.svg"),
    ),
    // assets/glyphs/dev/{btop,htop,iftop}.svg — removed 2026-08-06
    // together with their BUILTIN_GLYPHS entries. Launchers now use
    // real Nerd Fonts codepoints.
];

/// Locate a shipped SVG on disk. Tries in order:
///   1. `<installed-app>/Contents/Resources/<relpath>`
///   2. `<mnml exe parent>/../<relpath>` (dev build inside `target/`)
///   3. `~/Projects/{mnml,mnml-one-tab-type}/<relpath>` (repo checkout)
///   4. Embedded copy → extracted to `$TMPDIR/mnml-embedded/<relpath>`
///
/// Returns the first path that exists.
pub fn resolve_builtin_svg(relpath: &str) -> Option<std::path::PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        // .app bundle layout: MacOS/mnml → ../Resources/<relpath>
        if let Some(parent) = exe.parent()
            && let Some(macos_parent) = parent.parent()
        {
            let cand = macos_parent.join("Resources").join(relpath);
            if cand.exists() {
                return Some(cand);
            }
        }
        // Dev build: target/debug/mnml → walk up looking for the
        // asset next to a `Cargo.toml`.
        let mut cur = exe;
        while cur.pop() {
            let cand = cur.join(relpath);
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        // Historical layout was `~/Projects/mnml/`; worktrees now
        // land next to it as `~/Projects/mnml-<branch>/`. Try the
        // common suffixes so a release binary built inside one
        // worktree can find assets from another.
        let projects = std::path::PathBuf::from(home).join("Projects");
        for candidate_root in &["mnml", "mnml-one-tab-type"] {
            let cand = projects.join(candidate_root).join(relpath);
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    // Final fallback: extract the embedded copy to $TMPDIR. Cached
    // by relpath — one write per binary run per SVG.
    if let Some((_, bytes)) = EMBEDDED_SVGS.iter().find(|(p, _)| *p == relpath) {
        let dir = std::env::temp_dir().join("mnml-embedded");
        let out = dir.join(relpath);
        if let Some(parent) = out.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        // Write only if missing OR if the bytes differ (rare — a
        // stale copy from an older build could linger between
        // versions; overwrite so the current SVG wins).
        let stale = match std::fs::read(&out) {
            Ok(existing) => existing.as_slice() != *bytes,
            Err(_) => true,
        };
        if stale && std::fs::write(&out, bytes).is_err() {
            return None;
        }
        return Some(out);
    }
    None
}

/// Look up a codepoint in the built-in shipped-glyph list.
pub fn builtin_for_codepoint(cp: u32) -> Option<&'static BuiltinGlyph> {
    BUILTIN_GLYPHS.iter().find(|g| g.codepoint == cp)
}

/// Per-glyph build metadata persisted in
/// `~/.config/mnml/glyph_meta.toml`. Read on picker "edit existing"
/// so the builder pre-fills with the original SVG path + transform
/// tuning; written by `App::glyph_builder_commit` on every bake so a
/// glyph can be re-tuned later without remembering which SVG built it.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct GlyphMeta {
    /// Uppercase hex, no `U+` prefix (e.g. `"F1B00"`).
    pub codepoint: String,
    /// Internal glyph name (`aws-amplify-inv`).
    pub name: String,
    /// Absolute path to the SVG source.
    pub svg: String,
    /// Cell-width fraction the glyph was baked with.
    pub width_frac: f32,
    pub height_frac: f32,
    pub center_frac: f32,
    /// Horizontal center as a fraction of cell-width. Defaults to
    /// 0.5 (auto-center-on-bbox) when absent — TOML files written
    /// before this field existed still deserialize cleanly.
    #[serde(default = "default_center_x_frac")]
    pub center_x_frac: f32,
}

fn default_center_x_frac() -> f32 {
    0.5
}

#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct GlyphMetaFile {
    #[serde(default, rename = "glyph")]
    pub glyphs: Vec<GlyphMeta>,
}

/// Path to `~/.config/mnml/glyph_meta.toml`. Returns `None` if the
/// user config dir can't be resolved (no `$HOME` / `$XDG_CONFIG_HOME`).
pub fn meta_path() -> Option<std::path::PathBuf> {
    let cfg = crate::config::user_config_path()?;
    let dir = cfg.parent()?;
    Some(dir.join("glyph_meta.toml"))
}

pub fn load_meta() -> GlyphMetaFile {
    let Some(p) = meta_path() else {
        return GlyphMetaFile::default();
    };
    let Ok(txt) = std::fs::read_to_string(&p) else {
        return GlyphMetaFile::default();
    };
    toml::from_str(&txt).unwrap_or_default()
}

/// #863 — drop a glyph's meta entry by codepoint hex. Called from
/// integration / integration uninstall so the `glyph_meta.toml` doesn't
/// accumulate zombie entries for baked-then-uninstalled glyphs.
/// Returns true when a matching entry was removed. Silent no-op when
/// the file / entry doesn't exist.
pub fn remove_meta_by_cp_hex(cp_hex: &str) -> bool {
    let Some(p) = meta_path() else {
        return false;
    };
    if !p.exists() {
        return false;
    }
    let mut file = load_meta();
    let before = file.glyphs.len();
    file.glyphs.retain(|g| g.codepoint != cp_hex);
    if file.glyphs.len() == before {
        return false;
    }
    let Ok(txt) = toml::to_string_pretty(&file) else {
        return false;
    };
    std::fs::write(&p, txt).is_ok()
}

/// Insert-or-replace a glyph's metadata, then rewrite the file.
pub fn upsert_meta(entry: GlyphMeta) {
    let Some(p) = meta_path() else {
        return;
    };
    let mut file = load_meta();
    file.glyphs.retain(|g| g.codepoint != entry.codepoint);
    file.glyphs.push(entry);
    // Stable sort by codepoint so the file is diff-friendly.
    file.glyphs.sort_by(|a, b| a.codepoint.cmp(&b.codepoint));
    let Ok(txt) = toml::to_string_pretty(&file) else {
        return;
    };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(&p, txt);
}

/// Recover the category from a codepoint by matching against
/// `BuilderCategory::range_start()`/`range_end()`. Returns
/// `BuilderCategory::Aws` when the codepoint is outside any reserved
/// range — a defensible default since AWS is the first block and
/// most existing custom glyphs will land there.
pub fn category_for_codepoint(cp: u32) -> BuilderCategory {
    for cat in BuilderCategory::ALL {
        if cp >= cat.range_start() && cp <= cat.range_end() {
            return *cat;
        }
    }
    BuilderCategory::Aws
}

/// Refresh `state.preview_png` if a preview-affecting field changed.
/// `target_w × target_h` pick the pixel resolution for the preview —
/// the caller uses the panel's on-screen preview cell dimensions.
pub fn maybe_refresh_preview(state: &mut GlyphBuilderState, target_w: u32, target_h: u32) {
    let sig = state.signature();
    if state.preview_signature.as_ref() == Some(&sig) {
        return;
    }
    match rasterize(
        &state.svg_path,
        state.width_frac,
        state.height_frac,
        state.center_frac,
        state.center_x_frac,
        target_w,
        target_h,
    ) {
        Ok(png) => {
            state.preview_png = Some(png);
            state.error = None;
        }
        Err(msg) => {
            state.preview_png = None;
            state.error = Some(msg);
        }
    }
    state.preview_signature = Some(sig);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_focused_on_path() -> GlyphBuilderState {
        let mut s = GlyphBuilderState::new();
        s.focused_field = BuilderField::Path;
        s
    }

    #[test]
    fn type_and_backspace_at_cursor() {
        let mut s = state_focused_on_path();
        s.type_char('a');
        s.type_char('b');
        s.type_char('c');
        assert_eq!(s.svg_path, "abc");
        assert_eq!(s.svg_path_cursor, 3);
        s.move_cursor_left();
        s.move_cursor_left();
        assert_eq!(s.svg_path_cursor, 1);
        s.type_char('X');
        assert_eq!(s.svg_path, "aXbc");
        assert_eq!(s.svg_path_cursor, 2);
        s.backspace();
        assert_eq!(s.svg_path, "abc");
        assert_eq!(s.svg_path_cursor, 1);
    }

    #[test]
    fn paste_inserts_at_cursor_stripping_control_chars() {
        let mut s = state_focused_on_path();
        s.type_char('/');
        s.type_char('a');
        s.type_char('/');
        // Cursor at end. Paste a path with a trailing newline (typical
        // shell/finder drag payload).
        s.insert_str("Users/chris/foo.svg\n");
        assert_eq!(s.svg_path, "/a/Users/chris/foo.svg");
    }

    #[test]
    fn move_home_end_delete_forward() {
        let mut s = state_focused_on_path();
        for c in "hello".chars() {
            s.type_char(c);
        }
        s.move_cursor_home();
        assert_eq!(s.svg_path_cursor, 0);
        s.delete_forward();
        assert_eq!(s.svg_path, "ello");
        s.move_cursor_end();
        assert_eq!(s.svg_path_cursor, 4);
    }

    #[test]
    fn cycle_field_clamps_cursor() {
        let mut s = state_focused_on_path();
        for c in "verylongpath".chars() {
            s.type_char(c);
        }
        assert_eq!(s.svg_path_cursor, 12);
        // Move to name field (empty). Cursor should be safe.
        s.cycle_field(2); // Path -> Category -> Name
        assert_eq!(s.focused_field, BuilderField::Name);
        s.type_char('n');
        assert_eq!(s.name, "n");
        // Move back to path — cursor position is still at 12 (end).
        s.cycle_field(-2);
        assert_eq!(s.focused_field, BuilderField::Path);
        assert_eq!(s.svg_path_cursor, 12);
    }

    #[test]
    fn reset_focused_uses_builtin_defaults_when_present() {
        // Codepoint matches a BUILTIN entry (F1E00 = AI Claude).
        // 2026-08-09 — F1E00 defaults settled at
        // width=1.35/height=1.35/center=0.30/center_x=0.35 after the
        // 2026-08-08 tuning spiral; test asserts against the *current*
        // BUILTIN entry so it survives future tunings without hand
        // edits (read directly from BUILTIN_GLYPHS by codepoint).
        let expected = super::BUILTIN_GLYPHS
            .iter()
            .find(|g| g.codepoint == 0xF1E00)
            .expect("F1E00 entry present in BUILTIN_GLYPHS");
        let mut s = GlyphBuilderState::new();
        s.codepoint_hex = "F1E00".to_string();
        s.focused_field = BuilderField::CenterFrac;
        s.center_frac = 0.99; // way off
        s.reset_focused_to_default();
        assert!((s.center_frac - expected.center_frac).abs() < 1e-6);
        // Other fields untouched (still whatever new() set — assert
        // width_frac wasn't reset).
        let fresh = GlyphBuilderState::new();
        assert!((s.width_frac - fresh.width_frac).abs() < 1e-6);
    }

    #[test]
    fn reset_all_resets_every_numeric_field() {
        // 2026-08-09 — Read expected values from the live BUILTIN
        // entry so the test tracks tuning changes without hand
        // edits (see the 2026-08-08 Claude icon iteration spiral).
        let expected = super::BUILTIN_GLYPHS
            .iter()
            .find(|g| g.codepoint == 0xF1E00)
            .expect("F1E00 entry present in BUILTIN_GLYPHS");
        let mut s = GlyphBuilderState::new();
        s.codepoint_hex = "F1E00".to_string();
        s.width_frac = 0.5;
        s.height_frac = 0.5;
        s.center_frac = 0.5;
        s.center_x_frac = 0.2;
        s.reset_all_to_default();
        assert!((s.width_frac - expected.width_frac).abs() < 1e-6);
        assert!((s.height_frac - expected.height_frac).abs() < 1e-6);
        assert!((s.center_frac - expected.center_frac).abs() < 1e-6);
        assert!((s.center_x_frac - expected.center_x_frac).abs() < 1e-6);
    }

    #[test]
    fn reset_falls_back_to_hard_defaults_for_unknown_codepoint() {
        let mut s = GlyphBuilderState::new();
        // Not in BUILTIN_GLYPHS.
        s.codepoint_hex = "E123".to_string();
        s.center_frac = 0.99;
        s.center_x_frac = 0.1;
        s.reset_all_to_default();
        assert!((s.center_frac - 0.36).abs() < 1e-6);
        assert!((s.center_x_frac - 0.50).abs() < 1e-6);
    }
}
