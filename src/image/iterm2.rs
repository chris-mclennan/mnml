//! iTerm2 inline-image protocol encoder. Spec reference:
//! <https://iterm2.com/documentation-images.html>
//!
//! Wraps the image bytes in an OSC 1337 escape:
//!   `\x1b]1337;File=inline=1;width=Nx;height=Ny;preserveAspectRatio=1:<base64>\x07`
//!
//! `width` / `height` are specified in *cells* (matching the area
//! the renderer reserved). `preserveAspectRatio=1` keeps it from
//! stretching weirdly when the cell ratio doesn't match the image's.
//! No chunking — iTerm2 reads the OSC string in one go (unlike
//! Kitty's protocol which caps individual escapes at ~4KB).

use base64::{Engine as _, engine::general_purpose::STANDARD};

/// Encode `png_bytes` as a single OSC 1337 inline-image escape. The
/// image paints at the current cursor position; the caller positions
/// the cursor before emitting.
pub fn encode_placement(png_bytes: &[u8], cols: u16, rows: u16) -> String {
    let b64 = STANDARD.encode(png_bytes);
    format!("\x1b]1337;File=inline=1;width={cols};height={rows};preserveAspectRatio=1:{b64}\x07")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_wraps_base64_in_osc_1337() {
        let s = encode_placement(b"hi", 5, 3);
        assert!(s.starts_with("\x1b]1337;File=inline=1;width=5;height=3;preserveAspectRatio=1:"));
        assert!(s.ends_with('\x07'));
        // base64("hi") = "aGk="
        assert!(s.contains("aGk="));
    }

    #[test]
    fn encode_handles_empty_bytes() {
        let s = encode_placement(&[], 1, 1);
        assert!(s.starts_with("\x1b]1337;File=inline=1;"));
        assert!(s.ends_with('\x07'));
    }
}
