//! The browser pane (`Pane::Browser`) — a Chrome driven over CDP: a header with
//! the current URL + a scrollable log of console output, page navigations and
//! `eval` results, colour-coded by kind. Read-only render; keys (`g` navigate,
//! `e` eval, `r` reload, scroll, Esc → tree) are wired in `tui.rs`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::browser_pane::LogKind;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

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

    let Some(Pane::Browser(b)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::with_capacity(b.log.len() + 3);
    // ── header ─────────────────────────────────────────────────────
    let url = if b.url.trim().is_empty() {
        "about:blank"
    } else {
        b.url.trim()
    };
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            if b.closed { "● " } else { "◉ " },
            Style::default()
                .fg(if b.closed { t.comment } else { t.green })
                .bg(t.bg_dark),
        ),
        Span::styled(
            url.to_string(),
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            if b.closed { "   (session ended)" } else { "" },
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        "  g navigate · e eval JS · r reload · esc → tree",
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));
    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));

    // ── log ────────────────────────────────────────────────────────
    for l in &b.log {
        let (prefix, color) = match l.kind {
            LogKind::System => ("·  ", t.comment),
            LogKind::Console => ("   ", t.fg),
            LogKind::ConsoleErr => ("✗  ", t.red),
            LogKind::Nav => ("→  ", t.blue),
            LogKind::Eval => ("=  ", t.green),
        };
        // Eval *request* lines (start with "» ") are dim; results ("= ") are green;
        // we keep it simple — colour by kind, request lines just look like Eval too.
        lines.push(Line::from(vec![
            Span::styled(
                format!("  {prefix}"),
                Style::default().fg(color).bg(t.bg_dark),
            ),
            Span::styled(l.text.clone(), Style::default().fg(color).bg(t.bg_dark)),
        ]));
    }
    if b.log.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (no console output yet)",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    }

    // ── scroll (follow the tail when pinned) ───────────────────────
    let h = area.height as usize;
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    if b.scroll >= max_scroll {
        b.scroll = max_scroll;
    }
    let view: Vec<Line> = lines.into_iter().skip(b.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    None
}
