//! Kitty graphics protocol encoder. Spec reference:
//! <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
//!
//! mnml uses the simplest path: send the file bytes inline (no shared
//! memory / temp files), with `a=T` (transmit + display) and chunked
//! base64 payload (`m=1` continuation chunks, `m=0` final). The image is
//! displayed at the current cursor position; the caller positions the
//! cursor before emitting the escape.

use base64::{Engine as _, engine::general_purpose::STANDARD};

/// Max base64 chars per chunk. Kitty docs recommend ≤ 4096; we use 4000
/// for breathing room since some terminals are stricter.
const CHUNK_SIZE: usize = 4000;

/// Encode `png_bytes` as a sequence of Kitty graphics protocol escape
/// sequences, ready to write directly to stdout. The image will paint at
/// the terminal's current cursor position; size in cells = `cols × rows`.
/// Cursor is *not* moved after the paint (Kitty leaves it where the
/// placement started by default — `C=1` was previously default but is
/// now opt-in).
///
/// Pure PNG-encoded input — non-PNG sources are transcoded upstream via
/// [`crate::image::ImageData::ensure_png_bytes`] so callers don't have
/// to branch on format here.
pub fn encode_placement(png_bytes: &[u8], cols: u16, rows: u16) -> Result<String, String> {
    let b64 = STANDARD.encode(png_bytes);
    let mut out = String::with_capacity(b64.len() + 256);
    let mut chars = b64.as_bytes();
    let mut first = true;
    while !chars.is_empty() {
        let take = chars.len().min(CHUNK_SIZE);
        let (chunk, rest) = chars.split_at(take);
        let more = if rest.is_empty() { 0 } else { 1 };
        // First chunk carries the metadata; continuation chunks just `m=0|1`.
        if first {
            out.push_str(&format!("\x1b_Ga=T,f=100,c={cols},r={rows},m={more};"));
            first = false;
        } else {
            out.push_str(&format!("\x1b_Gm={more};"));
        }
        out.push_str(std::str::from_utf8(chunk).map_err(|e| e.to_string())?);
        out.push_str("\x1b\\");
        chars = rest;
    }
    Ok(out)
}

/// Clear *every* Kitty image placement in the terminal. Used when the
/// pane closes or a different image takes over — without this the previous
/// image lingers under whatever ratatui draws next.
pub fn clear_all() -> &'static str {
    "\x1b_Ga=d\x1b\\"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_small_png_in_single_chunk() {
        let bytes = vec![0u8; 100];
        let s = encode_placement(&bytes, 20, 10).unwrap();
        // Single chunk → m=0 in the first (and only) escape.
        assert!(s.starts_with("\x1b_Ga=T,f=100,c=20,r=10,m=0;"));
        assert!(s.ends_with("\x1b\\"));
    }

    #[test]
    fn encode_large_png_in_multiple_chunks() {
        // 4000 bytes raw → ~5400 b64 chars → 2 chunks.
        let bytes = vec![0u8; 4000];
        let s = encode_placement(&bytes, 20, 10).unwrap();
        // First chunk: m=1 (more coming); last chunk: m=0.
        assert!(s.contains("m=1;"), "expected m=1 in continuation: {s}");
        assert!(s.contains(",m=1;"), "first chunk should have m=1: {s}");
        assert!(s.ends_with("\x1b\\"));
        // Multiple escape sequences = 2+ "\x1b\\" terminators.
        let count = s.matches("\x1b\\").count();
        assert!(count >= 2, "expected ≥2 chunks, got {count}");
    }
}
