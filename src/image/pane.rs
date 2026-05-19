//! `Pane::Image` state — a one-image viewer. Holds the cached image bytes +
//! a few scrolling/sizing parameters. The actual paint is two-phase: the
//! renderer reserves the area + draws a placeholder banner; `tui.rs` emits
//! the terminal-specific escape after `terminal.draw()` so the image
//! lands on top.

use std::path::{Path, PathBuf};

use super::{ImageData, ImageFormat, load};

#[derive(Debug)]
pub struct ImagePane {
    pub data: ImageData,
    /// Whether the user has hidden the file metadata header. Toggled by `i`.
    pub show_header: bool,
}

impl ImagePane {
    pub fn open(path: &Path) -> Result<Self, String> {
        let data = load(path)?;
        Ok(ImagePane {
            data,
            show_header: true,
        })
    }

    /// Re-read the file from disk (file might have been overwritten externally).
    pub fn reload(&mut self) -> Result<(), String> {
        let data = load(&self.data.path)?;
        self.data = data;
        Ok(())
    }

    pub fn path(&self) -> &PathBuf {
        &self.data.path
    }

    pub fn tab_title(&self) -> String {
        let name = self
            .data
            .path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "image".to_string());
        let ext_tag = match self.data.format {
            ImageFormat::Png => "PNG",
            ImageFormat::Jpeg => "JPG",
            ImageFormat::Gif => "GIF",
            ImageFormat::Webp => "WEBP",
            ImageFormat::Bmp => "BMP",
            ImageFormat::Other => "IMG",
        };
        format!("{name} [{ext_tag}]")
    }
}
