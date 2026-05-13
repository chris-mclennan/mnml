//! The Playwright trace timeline (`Pane::Trace`) — a parsed `trace.zip` shown as
//! a flat, time-ordered list: `+1.234s  ⏵ page.goto("https://…")   234ms`, console
//! lines, page errors. The highlighted row's full detail (action params / error
//! stack) shows in a panel below the list. Read-only; `↑↓`/`jk` select, `r`
//! re-parses, `Esc` → tree (wired in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::playwright::trace::{EventKind, TraceEvent};
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

    let Some(Pane::Trace(tr)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    if tr.events.is_empty() {
        let lines = vec![
            Line::from(Span::styled(
                format!("  trace · {}", tr.test_title),
                Style::default()
                    .fg(t.fg)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(" ", Style::default().bg(t.bg_dark))),
            Line::from(Span::styled(
                "  (the trace.zip has no recognisable events)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            )),
        ];
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }
    if tr.selected >= tr.events.len() {
        tr.selected = tr.events.len() - 1;
    }

    // Detail panel height (the selected event's params / error) — up to ~8 rows,
    // never more than half the pane.
    let detail = selected_detail(&tr.events[tr.selected]);
    let detail_h = if detail.is_empty() {
        0
    } else {
        (detail.len() as u16 + 1).min(area.height / 2).min(9)
    };
    let list_h = area.height.saturating_sub(detail_h).max(1) as usize;

    // ── the timeline list ─────────────────────────────────────────
    let n_err = tr.events.iter().filter(|e| e.error.is_some()).count();
    let mut lines: Vec<Line> = Vec::new();
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            format!("trace · {}", tr.test_title),
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "    {} events · {} · ",
                tr.events.len(),
                fmt_ms(tr.span_ms())
            ),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
        Span::styled(
            if n_err > 0 {
                format!("{n_err} error{}", if n_err == 1 { "" } else { "s" })
            } else {
                "no errors".to_string()
            },
            Style::default()
                .fg(if n_err > 0 { t.red } else { t.green })
                .bg(t.bg_dark),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        "  ↑↓ select   h heal with Claude   r re-parse   esc back",
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));
    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));

    let header_rows = lines.len();
    let mut sel_row = header_rows;
    for (i, e) in tr.events.iter().enumerate() {
        if i == tr.selected {
            sel_row = lines.len();
        }
        lines.push(event_line(&t, e, i == tr.selected));
    }

    // scroll to keep the selected row visible within the list area
    if sel_row < tr.scroll + header_rows {
        tr.scroll = sel_row.saturating_sub(header_rows);
    } else if sel_row >= tr.scroll + list_h {
        tr.scroll = sel_row + 1 - list_h;
    }
    let max_scroll = lines.len().saturating_sub(list_h.min(lines.len()));
    tr.scroll = tr.scroll.min(max_scroll);

    let list_area = Rect {
        height: list_h as u16,
        ..area
    };
    let view: Vec<Line> = lines.into_iter().skip(tr.scroll).take(list_h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        list_area,
    );

    // ── detail panel ──────────────────────────────────────────────
    if detail_h > 0 {
        let dt_area = Rect {
            y: area.y + list_h as u16,
            height: detail_h,
            ..area
        };
        let mut dlines: Vec<Line> = Vec::with_capacity(detail_h as usize);
        dlines.push(Line::from(Span::styled(
            "─".repeat(area.width as usize),
            Style::default().fg(t.line).bg(t.bg_dark),
        )));
        for d in detail.iter().take(detail_h as usize - 1) {
            dlines.push(Line::from(Span::styled(
                format!("  {d}"),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        }
        frame.render_widget(
            Paragraph::new(dlines).style(Style::default().bg(t.bg_dark)),
            dt_area,
        );
    }
    None
}

fn fmt_ms(ms: f64) -> String {
    if ms >= 1000.0 {
        format!("{:.2}s", ms / 1000.0)
    } else {
        format!("{:.0}ms", ms)
    }
}

fn fmt_at(ms: f64) -> String {
    format!("+{:>7}", fmt_ms(ms))
}

fn event_line(t: &Theme, e: &TraceEvent, selected: bool) -> Line<'static> {
    let bg = if selected { t.bg2 } else { t.bg_dark };
    let glyph_color = match e.kind {
        _ if e.error.is_some() => t.red,
        EventKind::Action => t.cyan,
        EventKind::Console => t.blue,
        EventKind::Error => t.red,
        EventKind::Stdio => t.comment,
    };
    let mut spans = vec![
        Span::styled(
            if selected { "  ▶ " } else { "    " },
            Style::default().fg(t.yellow).bg(bg),
        ),
        Span::styled(
            format!("{} ", fmt_at(e.at_ms)),
            Style::default().fg(t.comment).bg(bg),
        ),
        Span::styled(
            format!("{} ", e.kind.glyph()),
            Style::default().fg(glyph_color).bg(bg),
        ),
        Span::styled(
            e.title.clone(),
            Style::default()
                .fg(if e.error.is_some() { t.red } else { t.fg })
                .bg(bg),
        ),
    ];
    if let Some(d) = e.dur_ms {
        spans.push(Span::styled(
            format!("   {}", fmt_ms(d)),
            Style::default().fg(t.comment).bg(bg),
        ));
    }
    if e.error.is_some() {
        spans.push(Span::styled(
            "   ✗",
            Style::default()
                .fg(t.red)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    Line::from(spans)
}

/// The detail text for the selected event: the error (message + stack) if any,
/// else the action params — split into trimmed lines, capped.
fn selected_detail(e: &TraceEvent) -> Vec<String> {
    let src = e
        .error
        .as_deref()
        .filter(|s| !s.is_empty())
        .unwrap_or(&e.detail);
    src.lines()
        .map(|l| l.trim_end().to_string())
        .filter(|l| !l.is_empty())
        .take(40)
        .collect()
}
