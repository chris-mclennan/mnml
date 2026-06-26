//! Render the body of a `Pane::Mount` — stamps the sibling's
//! latest `Frame` into mnml's ratatui buffer.

use mnml_bridge::{Cell, RgbOrIndex, modifier};
use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
};

use crate::mount::MountSession;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, session: &mut MountSession, area: Rect) {
    // Tell the sibling about size changes before we render this frame.
    session.resize(mnml_bridge::Geometry {
        cols: area.width,
        rows: area.height,
    });
    session.pump();

    if session.disconnected {
        // Sibling exited / crashed / refused. Show a small placeholder
        // — the user can close the pane or restart it.
        let t = theme::cur();
        let label = format!(
            " {} · sibling disconnected (press q to close the pane) ",
            session.label
        );
        let line = Line::from(vec![Span::styled(
            label,
            Style::default()
                .fg(t.red)
                .bg(t.bg)
                .add_modifier(Modifier::DIM),
        )]);
        frame.render_widget(Paragraph::new(line), area);
        return;
    }

    let Some(cells) = session.latest_frame.as_ref() else {
        let t = theme::cur();
        let line = Line::from(vec![Span::styled(
            format!(" {} · waiting for first frame… ", session.label),
            Style::default().fg(t.comment).bg(t.bg),
        )]);
        frame.render_widget(Paragraph::new(line), area);
        return;
    };

    // Stamp each cell of the sibling's frame into the ratatui buffer.
    // We clip to the rendered area in case the sibling sent a frame
    // sized for a stale geometry.
    let buf = frame.buffer_mut();
    let max_row = (area.height as usize).min(cells.len());
    for (y, row) in cells.iter().take(max_row).enumerate() {
        let max_col = (area.width as usize).min(row.len());
        for (x, cell) in row.iter().take(max_col).enumerate() {
            let dst_x = area.x + x as u16;
            let dst_y = area.y + y as u16;
            // Bounds-safe write via ratatui's cell accessor.
            if let Some(target) = buf.cell_mut((dst_x, dst_y)) {
                let _ = target.set_symbol(if cell.symbol.is_empty() {
                    " "
                } else {
                    &cell.symbol
                });
                let style = bridge_cell_style(cell);
                target.set_style(style);
            }
        }
    }
}

fn bridge_cell_style(cell: &Cell) -> Style {
    let mut style = Style::default();
    if let Some(c) = cell.fg {
        style = style.fg(bridge_color(c));
    }
    if let Some(c) = cell.bg {
        style = style.bg(bridge_color(c));
    }
    let mut mods = Modifier::empty();
    if cell.modifiers & modifier::BOLD != 0 {
        mods |= Modifier::BOLD;
    }
    if cell.modifiers & modifier::DIM != 0 {
        mods |= Modifier::DIM;
    }
    if cell.modifiers & modifier::ITALIC != 0 {
        mods |= Modifier::ITALIC;
    }
    if cell.modifiers & modifier::UNDERLINED != 0 {
        mods |= Modifier::UNDERLINED;
    }
    if cell.modifiers & modifier::SLOW_BLINK != 0 {
        mods |= Modifier::SLOW_BLINK;
    }
    if cell.modifiers & modifier::RAPID_BLINK != 0 {
        mods |= Modifier::RAPID_BLINK;
    }
    if cell.modifiers & modifier::REVERSED != 0 {
        mods |= Modifier::REVERSED;
    }
    if cell.modifiers & modifier::HIDDEN != 0 {
        mods |= Modifier::HIDDEN;
    }
    if cell.modifiers & modifier::CROSSED_OUT != 0 {
        mods |= Modifier::CROSSED_OUT;
    }
    if !mods.is_empty() {
        style = style.add_modifier(mods);
    }
    style
}

fn bridge_color(c: RgbOrIndex) -> Color {
    match c {
        RgbOrIndex::Rgb([r, g, b]) => Color::Rgb(r, g, b),
        RgbOrIndex::Index(i) => Color::Indexed(i),
    }
}
