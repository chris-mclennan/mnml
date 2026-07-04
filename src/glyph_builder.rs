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
}

/// Category range plan (matches `src/icon_catalog.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuilderCategory {
    Aws,
    Gcp,
    Azure,
    Ai,
    Saas,
    DevTool,
}

impl BuilderCategory {
    pub const ALL: &'static [BuilderCategory] = &[
        BuilderCategory::Aws,
        BuilderCategory::Gcp,
        BuilderCategory::Azure,
        BuilderCategory::Ai,
        BuilderCategory::Saas,
        BuilderCategory::DevTool,
    ];

    pub fn label(self) -> &'static str {
        match self {
            BuilderCategory::Aws => "aws",
            BuilderCategory::Gcp => "gcp",
            BuilderCategory::Azure => "azure",
            BuilderCategory::Ai => "ai",
            BuilderCategory::Saas => "saas",
            BuilderCategory::DevTool => "dev",
        }
    }

    pub fn range_start(self) -> u32 {
        match self {
            BuilderCategory::Aws => 0xF1B00,
            BuilderCategory::Gcp => 0xF1C00,
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
}

/// Hash-friendly snapshot of the fields the preview depends on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewSignature {
    pub path: String,
    pub w: u32, // bit-cast f32 (`to_bits`)
    pub h: u32,
    pub c: u32,
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
            focused_field: BuilderField::Path,
            preview_png: None,
            preview_signature: None,
            error: None,
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
            _ => {}
        }
    }

    /// Append a char to the focused text field. No-op for non-text
    /// fields.
    pub fn type_char(&mut self, ch: char) {
        let buf = match self.focused_field {
            BuilderField::Path => &mut self.svg_path,
            BuilderField::Name => &mut self.name,
            BuilderField::Codepoint => &mut self.codepoint_hex,
            _ => return,
        };
        // Cap at 128 chars; codepoint at 5 hex digits.
        let cap = if matches!(self.focused_field, BuilderField::Codepoint) {
            5
        } else {
            128
        };
        if buf.chars().count() >= cap {
            return;
        }
        buf.push(ch);
    }

    pub fn backspace(&mut self) {
        let buf = match self.focused_field {
            BuilderField::Path => &mut self.svg_path,
            BuilderField::Name => &mut self.name,
            BuilderField::Codepoint => &mut self.codepoint_hex,
            _ => return,
        };
        buf.pop();
    }

    pub fn cycle_field(&mut self, delta: isize) {
        use BuilderField::*;
        let order = [
            Path, Category, Name, Codepoint, WidthFrac, HeightFrac, CenterFrac,
        ];
        let cur = order
            .iter()
            .position(|f| *f == self.focused_field)
            .unwrap_or(0) as isize;
        let n = order.len() as isize;
        let next = (cur + delta).rem_euclid(n) as usize;
        self.focused_field = order[next];
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

    let svg_size = tree.size();
    let src_w = svg_size.width();
    let src_h = svg_size.height();
    if src_w <= 0.0 || src_h <= 0.0 {
        return Err("empty svg".to_string());
    }

    let target_w_units = CELL_W * width_frac;
    let target_h_units = EM * height_frac;
    let scale = (target_w_units / src_w).min(target_h_units / src_h);

    // Vertical center offset relative to em.
    let scaled_h = src_h * scale;
    let scaled_w = src_w * scale;
    let center_y = EM * center_frac;
    let bottom_units = center_y - scaled_h / 2.0;
    let left_units = (CELL_W - scaled_w) / 2.0;

    // Now project the "em box" (0..CELL_W wide, 0..EM tall with y-up)
    // into pixmap pixels. Sample at ~2px per em-unit for crisp preview.
    let pixmap_w = target_w.max(2);
    let pixmap_h = target_h.max(2);
    let px_per_unit_x = pixmap_w as f32 / CELL_W;
    let px_per_unit_y = pixmap_h as f32 / EM;

    let mut pixmap = Pixmap::new(pixmap_w, pixmap_h).ok_or("alloc pixmap")?;

    // Compose the render transform (resvg applies right-to-left):
    //   1. Scale SVG source units to em-units (× `scale`).
    //   2. Translate so the glyph sits at (left_units, bottom_units)
    //      in font (y-up) coordinates.
    //   3. Convert em-units to pixmap pixels — flip Y because the
    //      pixmap origin is top-left while our em coords are y-up.
    let t = Transform::from_scale(scale, scale)
        .post_translate(left_units, bottom_units)
        .post_scale(px_per_unit_x, -px_per_unit_y)
        .post_translate(0.0, pixmap_h as f32);
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
