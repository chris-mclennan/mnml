//! Renders a `Pane::Pty` — the [`vt100`] grid the reader thread maintains, cell
//! by cell, into the pane's area. Resizes the pty session to the rendered area
//! first (so the child draws at the right size). Returns the on-screen cursor
//! cell when focused so `ui::draw` can place the caret.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let Some(Pane::Pty(session)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    session.resize(area.height, area.width);
    let exited = session.is_exited();
    // Recover from a poisoned lock rather than panicking the UI.
    let parser = match session.parser.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    let screen = parser.screen();
    let (rows, cols) = screen.size();

    let def_fg = theme::cur().fg;
    let def_bg = theme::cur().bg_dark;
    let mut lines: Vec<Line> = Vec::with_capacity(rows as usize);
    for r in 0..rows {
        let mut spans: Vec<Span> = Vec::new();
        let mut text = String::new();
        let mut style: Option<Style> = None;
        for c in 0..cols {
            let Some(cell) = screen.cell(r, c) else {
                push_run(&mut spans, &mut text, &mut style, " ", Style::default());
                continue;
            };
            if cell.is_wide_continuation() {
                continue; // the wide grapheme was emitted by its left cell
            }
            let s = cell_style(cell, def_fg, def_bg);
            let g = if cell.has_contents() {
                cell.contents()
            } else {
                " ".to_string()
            };
            push_run(&mut spans, &mut text, &mut style, &g, s);
        }
        if let Some(s) = style {
            spans.push(Span::styled(text, s));
        }
        lines.push(Line::from(spans));
    }
    frame.render_widget(Paragraph::new(lines), area);

    if exited && area.height >= 1 {
        // A thin banner on the bottom row so the user knows the child is gone.
        let banner = Rect::new(area.x, area.y + area.height - 1, area.width, 1);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                " [process exited — Ctrl+W to close] ",
                Style::default()
                    .fg(theme::cur().bg_darker)
                    .bg(theme::cur().red)
                    .add_modifier(Modifier::BOLD),
            ))),
            banner,
        );
    }

    app.rects.editor_panes.push((area, pane_id));

    if focused && !exited && !screen.hide_cursor() && screen.scrollback() == 0 {
        let (cr, cc) = screen.cursor_position();
        let cx = area.x + cc.min(area.width.saturating_sub(1));
        let cy = area.y + cr.min(area.height.saturating_sub(1));
        return Some((cx, cy));
    }
    None
}

fn push_run(
    spans: &mut Vec<Span<'static>>,
    text: &mut String,
    style: &mut Option<Style>,
    g: &str,
    s: Style,
) {
    match style {
        Some(cur) if *cur == s => text.push_str(g),
        _ => {
            if let Some(cur) = style.take() {
                spans.push(Span::styled(std::mem::take(text), cur));
            }
            text.push_str(g);
            *style = Some(s);
        }
    }
}

fn cell_style(cell: &vt100::Cell, def_fg: Color, def_bg: Color) -> Style {
    let conv = |c: vt100::Color, def: Color| match c {
        vt100::Color::Default => def,
        vt100::Color::Idx(i) => Color::Indexed(i),
        vt100::Color::Rgb(r, g, b) => Color::Rgb(r, g, b),
    };
    let mut fg = conv(cell.fgcolor(), def_fg);
    let mut bg = conv(cell.bgcolor(), def_bg);
    if cell.inverse() {
        std::mem::swap(&mut fg, &mut bg);
    }
    let mut s = Style::default().fg(fg).bg(bg);
    if cell.bold() {
        s = s.add_modifier(Modifier::BOLD);
    }
    if cell.italic() {
        s = s.add_modifier(Modifier::ITALIC);
    }
    if cell.underline() {
        s = s.add_modifier(Modifier::UNDERLINED);
    }
    s
}
