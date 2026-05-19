//! The diagnostics list (`Pane::Diagnostics`) — a "Problems" panel: every LSP
//! diagnostic on an open buffer, errors first, `rel:line:col  message  (source)`
//! per row with the highlighted one inverted. Read-only render; `↑↓`/`jk`
//! select, `Enter` jumps to the location, `r` refreshes, `Esc` → tree (all
//! wired in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::lsp::Severity;
use crate::lsp::diagnostics_pane::DiagItem;
use crate::pane::Pane;
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

    // Reserve a 1-cell scrollbar on the right edge when the pane is
    // wide enough. Track + thumb only — no change markers.
    let want_sb = area.width >= 8;
    let sb_w = if want_sb { 1 } else { 0 };
    let body_area = Rect::new(area.x, area.y, area.width - sb_w, area.height);
    let sb_area = Rect::new(area.x + area.width - sb_w, area.y, sb_w, area.height);
    let area = body_area;

    let Some(Pane::Diagnostics(d)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    d.clamp();
    let (errors, warnings) = d.counts();

    let mut lines: Vec<Line> = Vec::new();

    // ── header ─────────────────────────────────────────────────────
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            format!("{errors} error{}", if errors == 1 { "" } else { "s" }),
            Style::default()
                .fg(if errors > 0 { t.red } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("   ·   ", Style::default().fg(t.comment).bg(t.bg_dark)),
        Span::styled(
            format!("{warnings} warning{}", if warnings == 1 { "" } else { "s" }),
            Style::default()
                .fg(if warnings > 0 { t.yellow } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        "  ⏎ jump   r refresh   esc back",
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));

    if d.items.is_empty() {
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        lines.push(Line::from(Span::styled(
            "  ✓ no diagnostics in open files",
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

    let body_start_offset = lines.len();
    let mut selected_row = lines.len();
    let mut row_indices: Vec<usize> = Vec::with_capacity(d.items.len());
    for (idx, it) in d.items.iter().enumerate() {
        let sel = idx == d.selected;
        if sel {
            selected_row = lines.len();
        }
        row_indices.push(lines.len());
        lines.push(item_line(&t, it, sel));
    }

    // ── scroll to keep the selected row visible ────────────────────
    let h = area.height as usize;
    if selected_row < d.scroll {
        d.scroll = selected_row;
    } else if selected_row >= d.scroll + h {
        d.scroll = selected_row + 1 - h;
    }
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    d.scroll = d.scroll.min(max_scroll);

    // Record clickable rects for each visible data row.
    for (idx, line_y) in row_indices.iter().enumerate() {
        if *line_y < d.scroll || *line_y >= d.scroll + h {
            continue;
        }
        let visible_y = line_y - d.scroll;
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
                idx,
            ));
        }
    }
    let _ = body_start_offset;

    let total_lines = lines.len();
    let scroll = d.scroll;
    let view: Vec<Line> = lines.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    if sb_w > 0 {
        crate::ui::scrollbar::paint_simple_scrollbar(frame, sb_area, &t, total_lines, h, scroll);
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id,
            total: total_lines,
            viewport: h,
            kind: crate::app::ScrollbarKind::Diagnostics,
        });
    }
    None
}

fn sev_glyph(s: Severity) -> &'static str {
    match s {
        Severity::Error => "✗",
        Severity::Warning => "⚠",
        Severity::Info => "ℹ",
        Severity::Hint => "·",
    }
}

fn item_line(t: &Theme, it: &DiagItem, selected: bool) -> Line<'static> {
    let bg = if selected { t.bg2 } else { t.bg_dark };
    let sev_color = match it.severity {
        Severity::Error => t.red,
        Severity::Warning => t.yellow,
        Severity::Info => t.blue,
        Severity::Hint => t.comment,
    };
    let loc = format!("{}:{}:{}", it.rel, it.line + 1, it.col + 1);
    let mut spans = vec![
        Span::styled(
            if selected { "  ▶ " } else { "    " },
            Style::default().fg(t.yellow).bg(bg),
        ),
        Span::styled(
            format!("{} ", sev_glyph(it.severity)),
            Style::default()
                .fg(sev_color)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("{loc}   "), Style::default().fg(t.comment).bg(bg)),
        Span::styled(it.message.clone(), Style::default().fg(t.fg).bg(bg)),
    ];
    if let Some(src) = &it.source {
        spans.push(Span::styled(
            format!("  ({src})"),
            Style::default().fg(t.comment).bg(bg),
        ));
    }
    Line::from(spans)
}
