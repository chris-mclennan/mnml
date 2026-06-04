//! Image rendering — protocol detection + encoders for terminals that
//! support inline images (Kitty graphics protocol, iTerm2 inline images).
//!
//! `Pane::Image` (defined in `src/pane.rs`) is the viewer pane: it caches
//! the file bytes + format on first load, and the renderer (`ui::image_view`)
//! reserves an area in the ratatui frame. After ratatui's draw completes,
//! `tui.rs` emits the protocol-specific escape directly to stdout to paint
//! the image *over* the reserved cells. This is the same two-phase trick
//! that crates like `ratatui-image` use — ratatui doesn't passthrough
//! escapes inside spans, so image draws have to happen after the regular
//! frame reconciliation.

pub mod iterm2;
pub mod kitty;
pub mod pane;

pub use pane::ImagePane;

/// One pending image paint, captured by the renderer and consumed by
/// `tui.rs` after `terminal.draw()` to emit the protocol escape. The
/// renderer is responsible for ensuring the PNG bytes are ready
/// (i.e. calling [`ImageData::ensure_png_bytes`] for non-PNG sources);
/// the emitter just writes them out.
#[derive(Debug, Clone)]
pub struct PaintRequest {
    /// Pane that owns the image — for logging / debugging. The emitter
    /// doesn't look this up; it just writes the bytes.
    pub pane_id: crate::layout::PaneId,
    pub area: ratatui::layout::Rect,
    /// Encoded PNG payload (`Arc` so the same image across multiple
    /// frames doesn't reallocate; `MdPreview` and `ImagePane` both
    /// hold their own `Arc` and share it cheaply per frame).
    pub png_bytes: std::sync::Arc<Vec<u8>>,
}

use std::path::{Path, PathBuf};

/// Image protocols supported by the active terminal. Detected once at
/// `App::new` time from env vars; reads cheaply via `App.image_protocol`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageProtocol {
    /// Kitty graphics protocol (`\x1b_G...`) — Kitty, WezTerm, Ghostty,
    /// recent Konsole.
    Kitty,
    /// iTerm2 inline image protocol (`\x1b]1337;File=...`) — iTerm2,
    /// recent WezTerm (via OSC 1337).
    Iterm2,
    /// No support — the pane shows a metadata-only placeholder.
    None,
}

/// Detect the active terminal's image protocol support via env vars.
///
/// Order matters: Kitty's env var (`KITTY_WINDOW_ID`) wins over `TERM_PROGRAM`
/// because some terminals set both. iTerm2 advertises via `TERM_PROGRAM`
/// alone. WezTerm sets `TERM_PROGRAM=WezTerm` AND implements both protocols
/// — we prefer Kitty there since it's the more featureful path.
pub fn detect_protocol() -> ImageProtocol {
    if std::env::var_os("KITTY_WINDOW_ID").is_some() {
        return ImageProtocol::Kitty;
    }
    if let Ok(term) = std::env::var("TERM")
        && term.to_lowercase().contains("kitty")
    {
        return ImageProtocol::Kitty;
    }
    if let Ok(tp) = std::env::var("TERM_PROGRAM") {
        let l = tp.to_lowercase();
        if l.contains("wezterm") || l == "ghostty" {
            return ImageProtocol::Kitty;
        }
        if l.contains("iterm") {
            return ImageProtocol::Iterm2;
        }
    }
    ImageProtocol::None
}

/// One file's worth of cached image data — the raw bytes plus a detected
/// format. Kept compact since PNG/JPEG files are typically a few hundred KB.
///
/// `png_bytes` is a cache of the PNG-transcoded payload for non-PNG sources.
/// Set lazily on first use via [`ImageData::ensure_png_bytes`]; transmission
/// pulls from this slot so the heavy decode only happens once per file.
#[derive(Debug, Clone)]
pub struct ImageData {
    pub path: PathBuf,
    pub bytes: Vec<u8>,
    pub format: ImageFormat,
    /// PNG-encoded payload for transmission. For PNG sources this points at
    /// `bytes` (zero-copy through `Arc`). For other formats it's lazily
    /// populated by decoding `bytes` then re-encoding as PNG.
    pub png_bytes: Option<std::sync::Arc<Vec<u8>>>,
    /// `(width, height)` in pixels — set once a decode has happened.
    /// `None` until first access.
    pub pixel_size: Option<(u32, u32)>,
}

impl ImageData {
    /// Return the PNG-encoded payload, decoding + re-encoding the source if
    /// necessary. PNG sources zero-copy through `Arc<Vec<u8>>`. Returns
    /// `Err` when the source can't be decoded (corrupt / unsupported).
    pub fn ensure_png_bytes(&mut self) -> Result<std::sync::Arc<Vec<u8>>, String> {
        if let Some(arc) = self.png_bytes.as_ref() {
            return Ok(arc.clone());
        }
        let arc = if matches!(self.format, ImageFormat::Png) {
            // PNG → reuse the bytes verbatim. Also fill pixel_size while
            // we're here (cheap — just parse the IHDR chunk).
            if self.pixel_size.is_none() {
                self.pixel_size = parse_png_size(&self.bytes);
            }
            std::sync::Arc::new(self.bytes.clone())
        } else {
            let img = image::load_from_memory(&self.bytes)
                .map_err(|e| format!("decode {}: {e}", format_label(self.format)))?;
            self.pixel_size = Some((img.width(), img.height()));
            let mut out: Vec<u8> = Vec::with_capacity(self.bytes.len());
            img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
                .map_err(|e| format!("encode PNG: {e}"))?;
            std::sync::Arc::new(out)
        };
        self.png_bytes = Some(arc.clone());
        Ok(arc)
    }
}

fn format_label(f: ImageFormat) -> &'static str {
    match f {
        ImageFormat::Png => "PNG",
        ImageFormat::Jpeg => "JPEG",
        ImageFormat::Gif => "GIF",
        ImageFormat::Webp => "WebP",
        ImageFormat::Bmp => "BMP",
        ImageFormat::Other => "image",
    }
}

/// Parse a PNG file's IHDR chunk for `(width, height)`. Returns None on a
/// non-PNG or truncated file. Cheap — reads only the first 24 bytes.
fn parse_png_size(bytes: &[u8]) -> Option<(u32, u32)> {
    // PNG magic (8 bytes) + IHDR length (4) + "IHDR" (4) + width (4) + height (4)
    if bytes.len() < 24 {
        return None;
    }
    if &bytes[0..8] != b"\x89PNG\r\n\x1a\n" {
        return None;
    }
    if &bytes[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
    let h = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
    Some((w, h))
}

/// Image formats recognized by the loader. Detection is by file extension
/// (cheap; supports common cases without dragging in a full image crate).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Png,
    Jpeg,
    Gif,
    Webp,
    Bmp,
    /// Unknown — kitty/iterm2 may still render it, but we can't promise.
    Other,
}

impl ImageFormat {
    /// Guess from file extension. Case-insensitive.
    pub fn from_path(path: &Path) -> Self {
        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .map(str::to_ascii_lowercase);
        match ext.as_deref() {
            Some("png") => ImageFormat::Png,
            Some("jpg") | Some("jpeg") => ImageFormat::Jpeg,
            Some("gif") => ImageFormat::Gif,
            Some("webp") => ImageFormat::Webp,
            Some("bmp") => ImageFormat::Bmp,
            _ => ImageFormat::Other,
        }
    }
}

/// Load an image file into memory. Refuses files past `MAX_BYTES` so a stray
/// click on a multi-GB raw file doesn't OOM the IDE.
pub fn load(path: &Path) -> Result<ImageData, String> {
    const MAX_BYTES: u64 = 50 * 1024 * 1024; // 50 MB
    let meta = std::fs::metadata(path).map_err(|e| format!("stat: {e}"))?;
    if meta.len() > MAX_BYTES {
        return Err(format!(
            "file too large ({} MB > 50 MB cap)",
            meta.len() / 1_048_576
        ));
    }
    let bytes = std::fs::read(path).map_err(|e| format!("read: {e}"))?;
    Ok(ImageData {
        path: path.to_path_buf(),
        bytes,
        format: ImageFormat::from_path(path),
        png_bytes: None,
        pixel_size: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_from_path_picks_known_extensions() {
        assert_eq!(ImageFormat::from_path(Path::new("a.png")), ImageFormat::Png);
        assert_eq!(
            ImageFormat::from_path(Path::new("a.JPG")),
            ImageFormat::Jpeg
        );
        assert_eq!(
            ImageFormat::from_path(Path::new("a.jpeg")),
            ImageFormat::Jpeg
        );
        assert_eq!(ImageFormat::from_path(Path::new("a.gif")), ImageFormat::Gif);
        assert_eq!(
            ImageFormat::from_path(Path::new("a.webp")),
            ImageFormat::Webp
        );
        assert_eq!(ImageFormat::from_path(Path::new("a.bmp")), ImageFormat::Bmp);
        assert_eq!(
            ImageFormat::from_path(Path::new("a.tif")),
            ImageFormat::Other
        );
        assert_eq!(
            ImageFormat::from_path(Path::new("noext")),
            ImageFormat::Other
        );
    }

    /// Build an in-memory image of `format`, then verify
    /// `ensure_png_bytes` decodes + re-encodes it as a valid PNG.
    /// Round-trip coverage that the `image` crate features pulled in
    /// (jpeg / gif / webp / bmp) actually decode at runtime — without
    /// this, a feature-flag regression in `Cargo.toml` would silently
    /// strand non-PNG sources.
    fn round_trip(format: image::ImageFormat, our_format: ImageFormat) {
        // 2×2 solid-red RGB image — the smallest meaningful payload.
        let raw = image::RgbImage::from_pixel(2, 2, image::Rgb([255, 0, 0]));
        let mut encoded = Vec::new();
        image::DynamicImage::ImageRgb8(raw)
            .write_to(&mut std::io::Cursor::new(&mut encoded), format)
            .expect("encode test fixture");
        let mut data = ImageData {
            path: PathBuf::from("x"),
            bytes: encoded,
            format: our_format,
            png_bytes: None,
            pixel_size: None,
        };
        let png = data.ensure_png_bytes().expect("decode + reencode");
        // PNG magic bytes confirm we got real PNG out.
        assert_eq!(&png[0..8], b"\x89PNG\r\n\x1a\n", "{our_format:?} → PNG");
        // Pixel size populated.
        assert_eq!(data.pixel_size, Some((2, 2)));
    }

    #[test]
    fn jpeg_decodes_and_reencodes_to_png() {
        round_trip(image::ImageFormat::Jpeg, ImageFormat::Jpeg);
    }

    #[test]
    fn gif_decodes_and_reencodes_to_png() {
        round_trip(image::ImageFormat::Gif, ImageFormat::Gif);
    }

    #[test]
    fn webp_decodes_and_reencodes_to_png() {
        // image 0.25's WebP encoder is lossless by default; round-trip
        // is byte-exact.
        round_trip(image::ImageFormat::WebP, ImageFormat::Webp);
    }

    #[test]
    fn bmp_decodes_and_reencodes_to_png() {
        round_trip(image::ImageFormat::Bmp, ImageFormat::Bmp);
    }

    #[test]
    fn png_source_zero_copies_through_ensure_png_bytes() {
        // PNG sources should hit the fast path that reuses self.bytes
        // verbatim (no decode → re-encode round trip).
        let raw = image::RgbImage::from_pixel(2, 2, image::Rgb([0, 255, 0]));
        let mut encoded = Vec::new();
        image::DynamicImage::ImageRgb8(raw)
            .write_to(
                &mut std::io::Cursor::new(&mut encoded),
                image::ImageFormat::Png,
            )
            .unwrap();
        let mut data = ImageData {
            path: PathBuf::from("x"),
            bytes: encoded.clone(),
            format: ImageFormat::Png,
            png_bytes: None,
            pixel_size: None,
        };
        let png = data.ensure_png_bytes().unwrap();
        assert_eq!(&*png, &encoded, "PNG source should be reused verbatim");
        assert_eq!(data.pixel_size, Some((2, 2)));
    }
}
