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
    /// True when opened from inside an integration edit panel (via
    /// Ctrl+N on the Glyph field OR the "+ Create custom glyph" row
    /// in the icon picker). On commit, the baked codepoint char
    /// flows straight back into the edit panel's Glyph field so the
    /// user doesn't have to reopen the edit panel and paste.
    pub from_integration_edit: bool,
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
            from_integration_edit: false,
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

    let pixmap_w = target_w.max(2);
    let pixmap_h = target_h.max(2);
    let px_per_unit_x = pixmap_w as f32 / CELL_W;
    let px_per_unit_y = pixmap_h as f32 / EM;

    // Where the glyph's center lands in pixel space. SVG's y-down
    // and the pixmap's y-down agree, so no flip is needed. But
    // font "center_frac" is measured from the BASELINE up (y-up
    // convention), so we invert it once when translating to
    // top-down pixmap space: pixmap_y_of_center = (1 - center_frac)
    // * pixmap_h.
    let px_glyph_w = src_w * scale * px_per_unit_x;
    let px_glyph_h = src_h * scale * px_per_unit_y;
    let px_center_y = (1.0 - center_frac) * pixmap_h as f32;
    let px_left = (pixmap_w as f32 - px_glyph_w) / 2.0;
    let px_top = px_center_y - px_glyph_h / 2.0;

    let mut pixmap = Pixmap::new(pixmap_w, pixmap_h).ok_or("alloc pixmap")?;

    // Compose (resvg applies right-to-left):
    //   1. Shift the content-bbox origin to (0,0) so scaling is pinned
    //      to the actual glyph, not the viewBox's padding.
    //   2. Scale SVG units → pixmap pixels using the font-size scale
    //      times the em → pixel ratio.
    //   3. Translate to (px_left, px_top) inside the pixmap.
    let sx = scale * px_per_unit_x;
    let sy = scale * px_per_unit_y;
    let t = Transform::from_translate(-src_x, -src_y)
        .post_scale(sx, sy)
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
}

/// mnml-shipped glyphs. Codepoints match `src/icon_catalog.rs`.
/// Defaults match the tuned `scripts/build_mnml_symbols.sh`.
pub const BUILTIN_GLYPHS: &[BuiltinGlyph] = &[
    BuiltinGlyph {
        codepoint: 0xF1B00,
        name: "aws-amplify-inv",
        svg_relpath: "assets/glyphs/aws/amplify.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B01,
        name: "aws-lambda-inv",
        svg_relpath: "assets/glyphs/aws/lambda.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B02,
        name: "aws-ecs-inv",
        svg_relpath: "assets/glyphs/aws/ecs.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B03,
        name: "aws-ecr-inv",
        svg_relpath: "assets/glyphs/aws/ecr.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B04,
        name: "aws-rds-inv",
        svg_relpath: "assets/glyphs/aws/rds.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B05,
        name: "aws-sqs-inv",
        svg_relpath: "assets/glyphs/aws/sqs.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B06,
        name: "aws-sns-inv",
        svg_relpath: "assets/glyphs/aws/sns.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B07,
        name: "aws-dynamodb-inv",
        svg_relpath: "assets/glyphs/aws/dynamodb.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B08,
        name: "aws-cognito-inv",
        svg_relpath: "assets/glyphs/aws/cognito.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B09,
        name: "aws-cloudwatch-inv",
        svg_relpath: "assets/glyphs/aws/cloudwatch.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B0A,
        name: "aws-codebuild-inv",
        svg_relpath: "assets/glyphs/aws/codebuild.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
    BuiltinGlyph {
        codepoint: 0xF1B0B,
        name: "aws-eventbridge-inv",
        svg_relpath: "assets/glyphs/aws/eventbridge.svg",
        width_frac: 1.25,
        height_frac: 0.80,
        center_frac: 0.36,
    },
];

/// Locate a shipped SVG on disk. Tries in order:
///   1. `<installed-app>/Contents/Resources/<relpath>`
///   2. `<mnml exe parent>/../<relpath>` (dev build inside `target/`)
///   3. `~/Projects/mnml/<relpath>` (fallback for repo checkout)
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
        // Dev build: target/debug/mnml → target/../<relpath>
        let mut cur = exe;
        while cur.pop() {
            let cand = cur.join(relpath);
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let cand = std::path::PathBuf::from(home)
            .join("Projects/mnml")
            .join(relpath);
        if cand.exists() {
            return Some(cand);
        }
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
