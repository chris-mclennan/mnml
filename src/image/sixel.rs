//! Sixel protocol encoder. Spec reference:
//! <https://vt100.net/docs/vt3xx-gp/chapter14.html>
//! Modern terminal reference:
//! <https://saitoha.github.io/libsixel/>
//!
//! Sixel encodes images as a sequence of 6-pixel-tall vertical bands.
//! Each band is processed per-color: for every column the encoder
//! emits a 6-bit mask of which pixel rows in the band belong to that
//! color. After every color in the band has been emitted, `$`
//! returns to the start of the band and the next color is drawn over
//! it; `-` advances to the next 6-row band.
//!
//! mnml uses a uniform 6×6×6 = 216-entry web-safe RGB palette. That's
//! enough for icon thumbnails, code-highlighted screenshots, and
//! coarse photos. Terminals that need true-color sixel can do better
//! quantization upstream (the user can always fall back to launching
//! `chafa` / `lsix` in a pty pane).
//!
//! Wraps in `\x1bP<params>q<data>\x1b\\` — DECSIXEL.

use std::fmt::Write as _;

/// Encode `png_bytes` as a sixel escape sequence sized to fit in
/// `cols × rows` terminal cells. Returns the ready-to-write payload.
///
/// The caller positions the cursor before emitting (the sixel paints
/// at the cursor position and leaves the cursor on the line *after*
/// the image — that's the spec, and matches how Kitty + iTerm2
/// behave with their image protocols).
pub fn encode_placement(png_bytes: &[u8], cols: u16, rows: u16) -> Result<String, String> {
    let img = image::load_from_memory(png_bytes).map_err(|e| format!("decode: {e}"))?;
    // Each terminal cell is ~6×12 px in most fonts; use a 6/12 cell-px
    // ratio to keep the aspect right after sixel renders 1 px per dot.
    // The terminal will clip to the actual cell size — sizing for a
    // little more than the reservation looks crisper than under-sizing
    // and letting the terminal upscale.
    let target_w = (cols as u32).saturating_mul(8).max(1);
    let target_h = (rows as u32).saturating_mul(16).max(1);
    let scaled = img.resize(target_w, target_h, image::imageops::FilterType::Lanczos3);
    let rgb = scaled.to_rgb8();
    let (w, h) = rgb.dimensions();
    Ok(encode_rgb(&rgb, w, h))
}

fn encode_rgb(rgb: &image::RgbImage, w: u32, h: u32) -> String {
    let mut out = String::with_capacity((w as usize) * (h as usize) / 4 + 4096);
    // DCS introducer. Params: P1=7 (1:1 aspect), P2=1 (background pixels
    // are kept transparent — most terminals interpret as the current
    // background color), P3=0 (default).
    out.push_str("\x1bP7;1;0q");
    // Raster attributes: "<pan>;<pad>;<width>;<height>q" extension. Pan/pad
    // = 1:1 aspect; width/height = pixel dimensions for clipping.
    let _ = write!(out, "\"1;1;{w};{h}");

    // Build the 216-entry web-safe palette declaration:
    // each `#<n>;2;<r>;<g>;<b>` where r/g/b are 0–100 (sixel uses
    // percent units, not 0–255).
    for idx in 0..216u32 {
        let (r, g, b) = palette_rgb(idx as u8);
        let _ = write!(
            out,
            "#{idx};2;{};{};{}",
            (r as u32 * 100) / 255,
            (g as u32 * 100) / 255,
            (b as u32 * 100) / 255
        );
    }

    // Quantize every pixel ahead of time so the band loop can iterate
    // by color without re-quantizing.
    let mut q = vec![0u8; (w * h) as usize];
    for y in 0..h {
        for x in 0..w {
            let p = rgb.get_pixel(x, y);
            q[(y * w + x) as usize] = quantize(p.0[0], p.0[1], p.0[2]);
        }
    }

    // Emit 6-row bands.
    let mut y_band = 0u32;
    while y_band < h {
        let band_h = (h - y_band).min(6);
        // For each color that appears in this band, emit one pass.
        let mut seen = [false; 216];
        for row in 0..band_h {
            for x in 0..w {
                seen[q[((y_band + row) * w + x) as usize] as usize] = true;
            }
        }
        let mut first_color = true;
        for (color, present) in seen.iter().enumerate() {
            if !present {
                continue;
            }
            if first_color {
                first_color = false;
            } else {
                // Carriage return inside the band so the next color
                // paints over the same columns.
                out.push('$');
            }
            let _ = write!(out, "#{color}");
            // RLE: emit `!<n><char>` when the same sixel byte repeats.
            let mut prev: u8 = 0;
            let mut run: u32 = 0;
            for x in 0..w {
                let mut mask: u8 = 0;
                for row in 0..band_h {
                    let pix = q[((y_band + row) * w + x) as usize] as usize;
                    if pix == color {
                        mask |= 1 << row;
                    }
                }
                let sixel = b'?' + mask; // 0x3F + 0..63
                if x == 0 {
                    prev = sixel;
                    run = 1;
                } else if sixel == prev {
                    run += 1;
                } else {
                    flush_run(&mut out, prev, run);
                    prev = sixel;
                    run = 1;
                }
            }
            if w > 0 {
                flush_run(&mut out, prev, run);
            }
        }
        out.push('-');
        y_band += band_h;
    }

    // DCS terminator.
    out.push_str("\x1b\\");
    out
}

fn flush_run(out: &mut String, sixel: u8, run: u32) {
    if run >= 4 {
        // `!<n><char>` RLE. Cheaper than 4+ raw bytes.
        let _ = write!(out, "!{run}{}", sixel as char);
    } else {
        for _ in 0..run {
            out.push(sixel as char);
        }
    }
}

/// 6×6×6 web-safe palette index → (r, g, b) bytes.
fn palette_rgb(idx: u8) -> (u8, u8, u8) {
    let r_b = idx / 36;
    let g_b = (idx / 6) % 6;
    let b_b = idx % 6;
    (
        bucket_to_value(r_b),
        bucket_to_value(g_b),
        bucket_to_value(b_b),
    )
}

/// Inverse: (r, g, b) bytes → 6×6×6 palette index. Uses `(c * 5) / 255`
/// bucket mapping so the round-trip palette_rgb(quantize(c)) is the
/// nearest-bucket centre.
fn quantize(r: u8, g: u8, b: u8) -> u8 {
    let r_b = ((r as u32) * 5) / 255;
    let g_b = ((g as u32) * 5) / 255;
    let b_b = ((b as u32) * 5) / 255;
    (r_b * 36 + g_b * 6 + b_b) as u8
}

fn bucket_to_value(b: u8) -> u8 {
    // 0,1,2,3,4,5 → 0,51,102,153,204,255 — even 51-step ramp.
    b.saturating_mul(51)
}

// Sixel doesn't have a dedicated "wipe all my images" escape (unlike
// Kitty's `\x1b_Ga=d\x1b\\`). Each sixel paint draws over whatever
// cells it covers, and ratatui's next-frame redraw paints over any
// stale pixels that fall outside the new placement. So there's no
// `clear_all` to expose here — the dispatcher just skips the clear
// step when `protocol == Sixel`.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_round_trip_via_quantize() {
        for idx in 0..216u8 {
            let (r, g, b) = palette_rgb(idx);
            assert_eq!(
                quantize(r, g, b),
                idx,
                "round-trip failed for palette index {idx}",
            );
        }
    }

    #[test]
    fn bucket_to_value_covers_full_range() {
        assert_eq!(bucket_to_value(0), 0);
        assert_eq!(bucket_to_value(5), 255);
    }

    #[test]
    fn quantize_pure_colors() {
        assert_eq!(quantize(0, 0, 0), 0);
        assert_eq!(quantize(255, 0, 0), 5 * 36); // pure red bucket
        assert_eq!(quantize(255, 255, 255), 215); // top palette idx
    }

    #[test]
    fn encode_rgb_wraps_dcs_introducer_and_terminator() {
        let img = image::RgbImage::from_pixel(2, 2, image::Rgb([255, 0, 0]));
        let s = encode_rgb(&img, 2, 2);
        assert!(s.starts_with("\x1bP7;1;0q\"1;1;2;2"));
        assert!(s.ends_with("\x1b\\"));
    }

    #[test]
    fn encode_rgb_declares_full_palette() {
        let img = image::RgbImage::from_pixel(1, 1, image::Rgb([0, 0, 0]));
        let s = encode_rgb(&img, 1, 1);
        // Every palette entry should be declared, even when only one
        // color appears in the image — sixel parsers want the palette
        // up front so they can be reused across multiple images.
        for idx in 0..216u32 {
            let hit = format!("#{idx};2;");
            assert!(s.contains(&hit), "palette entry {idx} missing");
        }
    }

    #[test]
    fn encode_placement_from_png_bytes() {
        // Build a tiny PNG to feed encode_placement.
        let raw = image::RgbImage::from_pixel(4, 4, image::Rgb([0, 200, 0]));
        let mut png_bytes = Vec::new();
        image::DynamicImage::ImageRgb8(raw)
            .write_to(
                &mut std::io::Cursor::new(&mut png_bytes),
                image::ImageFormat::Png,
            )
            .unwrap();
        let s = encode_placement(&png_bytes, 4, 2).unwrap();
        assert!(s.starts_with("\x1bP"));
        assert!(s.ends_with("\x1b\\"));
        assert!(s.contains('-'), "expected at least one band terminator");
    }

    #[test]
    fn encode_placement_rejects_bad_png() {
        let s = encode_placement(b"not a png", 4, 2);
        assert!(s.is_err());
    }

    #[test]
    fn flush_run_emits_rle_for_long_runs() {
        let mut out = String::new();
        flush_run(&mut out, b'?', 10);
        assert!(out.starts_with("!10"));
        assert!(out.contains('?'));
    }

    #[test]
    fn flush_run_emits_literals_for_short_runs() {
        let mut out = String::new();
        flush_run(&mut out, b'A', 2);
        assert_eq!(out, "AA");
    }
}
