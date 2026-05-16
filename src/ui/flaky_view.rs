//! The flaky-test dashboard (`Pane::Flaky`) — every wobbly test in the
//! workspace's history (per [`crate::playwright::history::TestHistory`])
//! flattened into a navigable list with a compact outcome bar. Read-only
//! render; `↑↓`/`jk` select, `Enter` jumps to the test in its source, `r`
//! refreshes, `Esc` → tree (wired in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::playwright::flaky_pane::outcomes_glyphs;
use crate::ui::theme::{self, Theme};

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
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));

    let Some(Pane::Flaky(f)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    f.clamp();
    let n = f.items.len();

    let mut lines: Vec<Line> = Vec::new();

    // ── header ─────────────────────────────────────────────────────
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "≋ ",
            Style::default()
                .fg(t.purple)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{n} wobbly test{}", if n == 1 { "" } else { "s" }),
            Style::default()
                .fg(if n > 0 { t.purple } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        "  ⏎ jump to source   r refresh   esc back",
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));

    if f.items.is_empty() {
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        lines.push(Line::from(Span::styled(
            "  ✓ no flaky tests in recent history",
            Style::default().fg(t.green).bg(t.bg_dark),
        )));
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }

    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));

    let mut selected_row = lines.len();
    let mut last_file: Option<String> = None;
    let mut row_indices: Vec<(usize, usize)> = Vec::with_capacity(f.items.len());
    for (idx, it) in f.items.iter().enumerate() {
        if last_file.as_deref() != Some(it.rel.as_str()) {
            lines.push(Line::from(vec![
                Span::styled("  ", Style::default().bg(t.bg_dark)),
                Span::styled(
                    it.rel.clone(),
                    Style::default()
                        .fg(t.comment)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::DIM),
                ),
            ]));
            last_file = Some(it.rel.clone());
        }
        let sel = idx == f.selected;
        if sel {
            selected_row = lines.len();
        }
        row_indices.push((lines.len(), idx));
        lines.push(item_line(&t, it, sel));
    }

    let h = area.height as usize;
    let total = lines.len();
    if total > h {
        let above = selected_row;
        let max_scroll = total.saturating_sub(h);
        let scroll = above.saturating_sub(h / 2).min(max_scroll);
        f.scroll = scroll;
    } else {
        f.scroll = 0;
    }

    for (line_y, idx) in &row_indices {
        if *line_y < f.scroll || *line_y >= f.scroll + h {
            continue;
        }
        let visible_y = line_y - f.scroll;
        let screen_y = area.y.saturating_add(visible_y as u16);
        if screen_y < area.y.saturating_add(area.height) {
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: area.x,
                    y: screen_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                *idx,
            ));
        }
    }

    let visible: Vec<Line> = lines.into_iter().skip(f.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(visible).style(Style::default().bg(t.bg_dark)),
        area,
    );
    None
}

fn item_line(t: &Theme, it: &crate::playwright::flaky_pane::FlakyItem, sel: bool) -> Line<'static> {
    let bg = if sel { t.bg2 } else { t.bg_dark };
    let arrow = if sel { "▶ " } else { "  " };
    let glyphs = outcomes_glyphs(&it.outcomes);
    let mut spans: Vec<Span> = Vec::new();
    spans.push(Span::styled(
        arrow.to_string(),
        Style::default().fg(t.purple).bg(bg),
    ));
    spans.push(Span::styled(
        format!("{:>10}  ", glyphs),
        Style::default().fg(t.purple).bg(bg),
    ));
    let mut title_style = Style::default().fg(t.fg).bg(bg);
    if sel {
        title_style = title_style.add_modifier(Modifier::BOLD);
    }
    spans.push(Span::styled(it.title.clone(), title_style));
    if it.line > 0 {
        spans.push(Span::styled(
            format!(":{}", it.line + 1),
            Style::default().fg(t.comment).bg(bg),
        ));
    }
    Line::from(spans)
}
