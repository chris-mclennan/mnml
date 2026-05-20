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
    if !matches!(app.panes.get(pane_id), Some(Pane::Pty(_))) {
        return None;
    }
    // Reserve the top row for a session tab strip — lists every pty
    // session (Claude / Codex / shell), highlights this leaf's, ends
    // with a `+` chip that spawns a new Claude. Always shown for pty
    // panes: it carries the `+` and the per-session names.
    let mut grid_area = area;
    if area.height >= 3 {
        let strip = Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        };
        draw_tab_strip(frame, app, pane_id, strip);
        grid_area = Rect {
            x: area.x,
            y: area.y + 1,
            width: area.width,
            height: area.height - 1,
        };
    } else {
        app.rects.pty_tabs.clear();
        app.rects.pty_tab_new = None;
    }
    let area = grid_area;
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

/// Paint the pty-session tab strip into `strip` (1 row). Lists every
/// `Pane::Pty` in the app — the one for `active_id` is highlighted —
/// then a `+` chip. Registers click rects on `app.rects.pty_tabs` /
/// `pty_tab_new`. Appends (the registries are cleared once per frame
/// in `ui::draw`) so multiple visible pty panes can each carry a strip.
fn draw_tab_strip(frame: &mut Frame, app: &mut App, active_id: PaneId, strip: Rect) {
    let t = theme::cur();
    // Gather pty panes in pane order: `(id, label, exited)`.
    let ptys: Vec<(PaneId, String, bool)> = app
        .panes
        .iter()
        .enumerate()
        .filter_map(|(id, p)| match p {
            Pane::Pty(s) => Some((id, s.tab_label(), s.is_exited())),
            _ => None,
        })
        .collect();

    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_darker)),
        strip,
    );
    let mut spans: Vec<Span> = Vec::new();
    let mut x = strip.x;
    let right_limit = strip.x + strip.width;
    for (id, label, exited) in &ptys {
        // ` <label> ` — truncate long names to keep the strip tidy.
        let mut shown: String = label.chars().take(18).collect();
        if *exited {
            shown.push_str(" ✗");
        }
        let chip = format!(" {shown} ");
        let w = chip.chars().count() as u16;
        if x + w + 4 > right_limit {
            break; // out of room — drop the rest (rare; many ptys)
        }
        let is_active = *id == active_id;
        let style = if is_active {
            Style::default()
                .fg(t.bg_darker)
                .bg(t.orange)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg2)
        };
        spans.push(Span::styled(chip, style));
        spans.push(Span::styled(" ", Style::default().bg(t.bg_darker)));
        app.rects.pty_tabs.push((
            Rect {
                x,
                y: strip.y,
                width: w,
                height: 1,
            },
            *id,
        ));
        x += w + 1;
    }
    // `+` chip — spawn a new Claude session.
    if x + 3 <= right_limit {
        spans.push(Span::styled(
            " + ",
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.pty_tab_new = Some(Rect {
            x,
            y: strip.y,
            width: 3,
            height: 1,
        });
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), strip);
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
