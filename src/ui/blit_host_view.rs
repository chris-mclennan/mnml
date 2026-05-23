//! Renders `Pane::BlitHost` — paints the cell grid the hosted child
//! streams over the wire (`pane_host::BlitChannel`) into the pane's
//! body rect.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;

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

/// Paint the hosted child's cells into `area`. Cells past the child's
/// current grid (e.g. before its first frame arrives, or while it's
/// catching up to a resize) are left at the surrounding background.
pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    _focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let Some(Pane::BlitHost(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    // Tell the child the pane size if it changed.
    p.channel.resize(area.width, area.height);

    let cols = p.channel.cols as usize;
    let rows = p.channel.rows as usize;
    let cursor = p.channel.cursor;

    let buf = frame.buffer_mut();
    for ry in 0..area.height {
        for rx in 0..area.width {
            let (sx, sy) = (rx as usize, ry as usize);
            if sx >= cols || sy >= rows {
                continue;
            }
            let Some(cell) = p.channel.cells.get(sy * cols + sx) else {
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
    cursor.map(|(c, r)| (area.x + c, area.y + r))
}
