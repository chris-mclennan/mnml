//! The `Pane::Request` view — the request fired from a `.http`/`.curl` editor
//! and (once the background send returns) its response: status line, headers,
//! pretty body, `@assert` results, `@capture`s. Read-only + scrollable; `r`
//! re-fires the request (handled in `tui.rs`). Long lines clip (no wrap yet).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::request_pane::RunState;
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
    let Some(Pane::Request(rp)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let body_style = Style::default().fg(t.fg).bg(t.bg_dark);
    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let mut rows: Vec<Line> = Vec::new();
    let plain = |s: String, st: Style| Line::from(Span::styled(s, st));

    // ── request ──
    rows.push(Line::from(vec![
        Span::styled("▶ ", Style::default().fg(t.yellow).bg(t.bg_dark)),
        Span::styled(
            format!("{} ", rp.request.method),
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            rp.request.url.clone(),
            Style::default().fg(t.blue).bg(t.bg_dark),
        ),
    ]));
    for (k, v) in &rp.request.headers {
        rows.push(plain(format!("  {k}: {v}"), dim));
    }
    if let Some(b) = &rp.request.body {
        rows.push(plain(String::new(), body_style));
        for l in b.lines() {
            rows.push(plain(
                format!("  {l}"),
                Style::default().fg(t.grey_fg).bg(t.bg_dark),
            ));
        }
    }
    rows.push(plain(String::new(), body_style));

    // ── response ──
    match &rp.state {
        RunState::Sending => {
            rows.push(plain(
                "  ⟳ sending…".to_string(),
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        RunState::Failed(e) => {
            rows.push(plain(
                format!("  ✗ {e}"),
                Style::default()
                    .fg(t.red)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        RunState::Done(r) => {
            let status_color = match r.status {
                200..=299 => t.green,
                300..=399 => t.yellow,
                400..=499 => t.orange,
                _ => t.red,
            };
            rows.push(Line::from(vec![
                Span::styled("← ", Style::default().fg(t.yellow).bg(t.bg_dark)),
                Span::styled(
                    format!("{} {}", r.status, r.status_text),
                    Style::default()
                        .fg(status_color)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("   {} ms", r.elapsed.as_millis()), dim),
            ]));
            for (k, v) in &r.headers {
                rows.push(plain(format!("  {k}: {v}"), dim));
            }
            rows.push(plain(String::new(), body_style));
            let pretty = pretty_body(&r.body, &r.headers);
            for l in pretty.lines() {
                rows.push(plain(l.to_string(), body_style));
            }
            if !r.assertions.is_empty() {
                rows.push(plain(String::new(), body_style));
                for a in &r.assertions {
                    if a.passed {
                        rows.push(plain(
                            format!("  ✓ {}", a.label),
                            Style::default().fg(t.green).bg(t.bg_dark),
                        ));
                    } else {
                        let line = match &a.detail {
                            Some(d) => format!("  ✗ {} — {d}", a.label),
                            None => format!("  ✗ {}", a.label),
                        };
                        rows.push(plain(line, Style::default().fg(t.red).bg(t.bg_dark)));
                    }
                }
            }
            if !r.captures.is_empty() {
                rows.push(plain(String::new(), body_style));
                for (name, value) in &r.captures {
                    rows.push(Line::from(vec![
                        Span::styled(
                            format!("  ⇒ {name} = "),
                            Style::default().fg(t.cyan).bg(t.bg_dark),
                        ),
                        Span::styled(
                            value.clone(),
                            Style::default()
                                .fg(t.cyan)
                                .bg(t.bg_dark)
                                .add_modifier(Modifier::BOLD),
                        ),
                    ]));
                }
            }
        }
    }

    // scroll
    let h = area.height as usize;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    rp.scroll = rp.scroll.min(max_scroll);
    let view: Vec<Line> = rows.into_iter().skip(rp.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));
    None
}

/// Pretty-print a body if it looks like JSON; otherwise return it as-is.
fn pretty_body(body: &str, headers: &[(String, String)]) -> String {
    let is_json = headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("content-type") && v.contains("json"))
        || {
            let b = body.trim_start();
            b.starts_with('{') || b.starts_with('[')
        };
    if is_json
        && let Ok(v) = serde_json::from_str::<serde_json::Value>(body)
        && let Ok(p) = serde_json::to_string_pretty(&v)
    {
        return p;
    }
    body.to_string()
}
