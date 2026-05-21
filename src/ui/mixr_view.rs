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

/// Draw the floating panel's 1-row header — a drag handle carrying the
/// `‹` `›` width controls and the five reposition buttons. Registers
/// each button's rect.
pub fn draw_header(
    frame: &mut Frame,
    header: Rect,
    active: crate::mixr_host::MixrPos,
    pos_buttons: &mut Vec<(Rect, crate::mixr_host::MixrPos)>,
    width_minus: &mut Option<Rect>,
    width_plus: &mut Option<Rect>,
) {
    use crate::mixr_host::MixrPos;
    *width_minus = None;
    *width_plus = None;
    if header.height == 0 || header.width == 0 {
        return;
    }
    let t = crate::ui::theme::cur();
    let y = header.y;
    let buf = frame.buffer_mut();
    // Background fill.
    for x in header.x..header.x + header.width {
        let c = &mut buf[(x, y)];
        c.set_char(' ');
        c.set_style(Style::default().bg(t.bg2));
    }
    // Label / drag hint.
    for (i, ch) in " ♪ mixr — drag".chars().enumerate() {
        let x = header.x + i as u16;
        if x >= header.x + header.width {
            break;
        }
        let c = &mut buf[(x, y)];
        c.set_char(ch);
        c.set_style(Style::default().fg(t.comment).bg(t.bg2));
    }
    let btn_w: u16 = 2;
    let pos_total = MixrPos::ALL.len() as u16 * btn_w;
    let width_total = 2 * btn_w;
    if header.width < pos_total + width_total + 12 {
        return;
    }
    let mut paint = |bx: u16, glyph: char, fg: Color, bg: Color| {
        for dx in 0..btn_w {
            let c = &mut buf[(bx + dx, y)];
            c.set_char(if dx == 0 { glyph } else { ' ' });
            c.set_style(Style::default().fg(fg).bg(bg));
        }
    };
    // Width controls `‹ ›`, then a 1-col gap, then the anchor buttons.
    let w_start = header.x + header.width - pos_total - 1 - width_total;
    paint(w_start, '‹', t.fg, t.bg2);
    paint(w_start + btn_w, '›', t.fg, t.bg2);
    *width_minus = Some(Rect {
        x: w_start,
        y,
        width: btn_w,
        height: 1,
    });
    *width_plus = Some(Rect {
        x: w_start + btn_w,
        y,
        width: btn_w,
        height: 1,
    });
    // Anchor buttons, far right: ▘ ▝ ▖ ▗ ◆
    let p_start = header.x + header.width - pos_total;
    for (i, pos) in MixrPos::ALL.iter().enumerate() {
        let bx = p_start + i as u16 * btn_w;
        let (fg, bg) = if *pos == active {
            (t.bg2, t.yellow)
        } else {
            (t.fg, t.bg2)
        };
        paint(bx, pos.glyph(), fg, bg);
        pos_buttons.push((
            Rect {
                x: bx,
                y,
                width: btn_w,
                height: 1,
            },
            *pos,
        ));
    }
}
