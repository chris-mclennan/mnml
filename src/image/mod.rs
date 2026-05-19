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

pub mod kitty;
pub mod pane;

pub use pane::ImagePane;

/// One pending image paint, captured by the renderer and consumed by
/// `tui.rs` after `terminal.draw()` to emit the protocol escape.
#[derive(Debug, Clone)]
pub struct PaintRequest {
    pub pane_id: crate::layout::PaneId,
    pub area: ratatui::layout::Rect,
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
#[derive(Debug, Clone)]
pub struct ImageData {
    pub path: PathBuf,
    pub bytes: Vec<u8>,
    pub format: ImageFormat,
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
}
