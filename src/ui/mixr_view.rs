//! Renders the native mixr panel — paints the cell grid mixr streams
//! over the wire (`mixr_host::MixrPanel`) into its docked rect.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};

use crate::mixr_host::MixrPanel;

// Wire attribute bits — mirror tmnl-protocol / the blit backend.
const ATTR_BOLD: u32 = 1 << 0;
const ATTR_DIM: u32 = 1 << 1;
const ATTR_ITALIC: u32 = 1 << 2;
const ATTR_UNDERLINE: u32 = 1 << 3;

/// Decode a packed-rgba wire colour into a ratatui `Color`.
fn rgba(packed: u32) -> Color {
    let [r, g, b, _] = tmnl_protocol::unpack_rgba(packed);
    Color::Rgb(
        (r.clamp(0.0, 1.0) * 255.0) as u8,
        (g.clamp(0.0, 1.0) * 255.0) as u8,
        (b.clamp(0.0, 1.0) * 255.0) as u8,
    )
}

/// Paint `panel`'s cells into `area`. Cells past mixr's current grid
/// are left as the surrounding background (e.g. before the first
/// frame arrives).
pub fn draw(frame: &mut Frame, panel: &MixrPanel, area: Rect) {
    let buf = frame.buffer_mut();
    let cols = panel.cols as usize;
    let rows = panel.rows as usize;
    for ry in 0..area.height {
        for rx in 0..area.width {
            let (sx, sy) = (rx as usize, ry as usize);
            if sx >= cols || sy >= rows {
                continue;
            }
            let Some(cell) = panel.cells.get(sy * cols + sx) else {
                continue;
            };
            let dst = &mut buf[(area.x + rx, area.y + ry)];
            dst.set_char(cell.ch);
            let mut style = Style::default().fg(rgba(cell.fg)).bg(rgba(cell.bg));
            if cell.attrs & ATTR_BOLD != 0 {
                style = style.add_modifier(Modifier::BOLD);
            }
            if cell.attrs & ATTR_DIM != 0 {
                style = style.add_modifier(Modifier::DIM);
            }
            if cell.attrs & ATTR_ITALIC != 0 {
                style = style.add_modifier(Modifier::ITALIC);
            }
            if cell.attrs & ATTR_UNDERLINE != 0 {
                style = style.add_modifier(Modifier::UNDERLINED);
            }
            dst.set_style(style);
        }
    }
}

/// Draw the panel's 1-row title bar — `♪ mixr` label on the left,
/// size-control chips on the right (`⤢` grow / `⤡` shrink / `–`
/// minimize). Each chip is shown only when it'd actually do
/// something; click-handlers in `tui.rs` snap the panel to the
/// matching `MixrSize`.
pub fn draw_header(
    frame: &mut Frame,
    app: &mut crate::app::App,
    header: Rect,
    size: crate::mixr_host::MixrSize,
) {
    use crate::mixr_host::MixrSize;
    // Reset hit-rects every paint — caller may toggle the panel off
    // entirely, and stale rects would let the click router fire on
    // empty cells.
    app.rects.mixr_size_grow_button = None;
    app.rects.mixr_size_shrink_button = None;
    app.rects.mixr_size_minimize_button = None;
    if header.height == 0 || header.width == 0 {
        return;
    }
    let t = crate::ui::theme::cur();
    let y = header.y;
    let buf = frame.buffer_mut();
    for x in header.x..header.x + header.width {
        let c = &mut buf[(x, y)];
        c.set_char(' ');
        c.set_style(Style::default().bg(t.bg2));
    }
    for (i, ch) in " ♪ mixr".chars().enumerate() {
        let x = header.x + i as u16;
        if x >= header.x + header.width {
            break;
        }
        let c = &mut buf[(x, y)];
        c.set_char(ch);
        c.set_style(Style::default().fg(t.comment).bg(t.bg2));
    }
    // Right-aligned chip cluster — each is a single cell, separated
    // by a 1-cell gap. Order (right → left): minimize, shrink, grow.
    // We paint from the right edge inward so the cluster always
    // hugs the right side regardless of header width.
    //
    //   grow   — visible unless already Full.
    //   shrink — visible only from Full (BottomStrip can't shrink
    //            further without minimizing).
    //   – minimize — always visible while the panel is shown.
    //
    // grow/shrink use nerd-font codepoints (nf-fa-expand /
    // nf-fa-compress), not the basic-Unicode arrows ⤢/⤡ — those render
    // as invisible glyphs in the user's font-fallback chain (the same
    // issue that hid the statusline transport chips, reported
    // 2026-06-17; only the minimize en-dash was ever visible). The
    // en-dash minimize renders fine, so it stays.
    const NF_GROW: char = '\u{f065}'; // nf-fa-expand
    const NF_SHRINK: char = '\u{f066}'; // nf-fa-compress
    let mut chip_x = header.x + header.width;
    let mut place_chip = |buf: &mut ratatui::buffer::Buffer, ch: char| -> Option<Rect> {
        if chip_x <= header.x + 1 {
            return None;
        }
        chip_x -= 1;
        let cell = &mut buf[(chip_x, y)];
        cell.set_char(ch);
        cell.set_style(Style::default().fg(t.fg).bg(t.bg2));
        let rect = Rect {
            x: chip_x,
            y,
            width: 1,
            height: 1,
        };
        // 1-cell gap between chips.
        chip_x = chip_x.saturating_sub(1);
        Some(rect)
    };
    if let Some(r) = place_chip(buf, '–') {
        app.rects.mixr_size_minimize_button = Some(r);
    }
    if size == MixrSize::Full
        && let Some(r) = place_chip(buf, NF_SHRINK)
    {
        app.rects.mixr_size_shrink_button = Some(r);
    }
    if size != MixrSize::Full
        && let Some(r) = place_chip(buf, NF_GROW)
    {
        app.rects.mixr_size_grow_button = Some(r);
    }
}
