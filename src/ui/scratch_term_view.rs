//! Scratch terminal strip — a small persistent pty at the bottom of the
//! body. Sibling to `Pane::Pty` (full pane); this one is a fixed-height
//! overlay strip that survives pane switches.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.width < 4 || area.height < 3 {
        return;
    }
    let t = theme::cur();
    let Some(scratch) = app.scratch_term.as_mut() else {
        return;
    };
    let border_style = if scratch.focused {
        Style::default().fg(t.yellow).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.bg3)
    };
    let title = if scratch.focused {
        " scratch · Esc blurs · `term.scratch_toggle` closes "
    } else {
        " scratch · click to focus · `term.scratch_toggle` closes "
    };
    let block = Block::default()
        .borders(Borders::TOP)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(if scratch.focused { t.yellow } else { t.bg3 })
                .add_modifier(Modifier::BOLD),
        ))
        .border_style(border_style);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let session = &mut scratch.session;
    session.resize(inner.height, inner.width);
    let parser = match session.parser.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    let screen = parser.screen();
    let (rows, cols) = screen.size();

    let def_fg = t.fg;
    let def_bg = t.bg_dark;
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
                continue;
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
    frame.render_widget(Paragraph::new(lines), inner);
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
