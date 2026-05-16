//! The browser pane (`Pane::Browser`) — a Chrome driven over CDP: a header with
//! the current URL + either a scrollable log of console output / navigations /
//! `eval` results (colour-coded by kind) or — when the `n` network panel is on —
//! a selectable list of the captured requests. Read-only render; keys (`g`
//! navigate, `e` eval, `r` reload, `n` toggle the panel, `y` copy-as-curl, Enter
//! → re-send, scroll, Esc → tree) are wired in `tui.rs`.

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

    let mut lines: Vec<Line> = Vec::new();
    // ── header ─────────────────────────────────────────────────────
    let url = if b.url.trim().is_empty() {
        "about:blank"
    } else {
        b.url.trim()
    };
    let target_chip = if b.targets.len() > 1 {
        format!("   [target: {} · T to switch]", b.current_target_label())
    } else {
        String::new()
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
        Span::styled(target_chip, Style::default().fg(t.yellow).bg(t.bg_dark)),
        Span::styled(
            if b.closed { "   (session ended)" } else { "" },
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ]));
    let hint = if b.dom_focus {
        if b.dom_filter_mode {
            format!(
                "  DOM filter: {}_ · Backspace deletes · Enter applies · Esc clears",
                b.dom_filter
            )
        } else if !b.dom_filter.is_empty() {
            format!(
                "  DOM ({}/{}) · / filter · ↑↓ select · h highlight · Z scroll · S screenshot · esc clear",
                b.visible_dom_indices().len(),
                b.dom.len()
            )
        } else {
            format!(
                "  DOM ({}) · / filter · h highlight · Z scroll · S shot · c copy · R re-fetch · esc back",
                b.dom.len()
            )
        }
    } else if b.net_focus {
        if b.net_filter_mode {
            format!(
                "  network filter: {}_ · Backspace deletes · Enter applies · Esc clears",
                b.net_filter
            )
        } else if !b.net_filter.is_empty() {
            format!(
                "  network ({}/{}) · / filter · ↑↓ select · y curl · enter re-send · esc clear",
                b.visible_net_indices().len(),
                b.net.len()
            )
        } else {
            format!(
                "  network ({}) · / filter · ↑↓ select · y curl · enter re-send · n logs · esc back",
                b.net.len()
            )
        }
    } else {
        "  g navigate · ^R history · e eval · r reload · s shot · n net · D DOM · esc → tree"
            .to_string()
    };
    lines.push(Line::from(Span::styled(
        hint,
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));
    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));
    let header_rows = lines.len();
    let h = area.height as usize;
    let body_rows = h.saturating_sub(header_rows);

    if b.dom_focus {
        // ── DOM panel: one selectable row per parsed node, indent = depth ──
        let visible = b.visible_dom_indices();
        if b.dom.is_empty() {
            lines.push(Line::from(Span::styled(
                if b.pending_dom.is_some() {
                    "  fetching DOM…"
                } else {
                    "  (no DOM loaded yet — R re-fetches)"
                },
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else if visible.is_empty() {
            lines.push(Line::from(Span::styled(
                format!("  (no matches for '{}')", b.dom_filter),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            let sel = b.dom_sel.min(visible.len() - 1);
            let first = if body_rows == 0 || sel < body_rows {
                0
            } else {
                sel + 1 - body_rows
            };
            for (row_idx, &raw_idx) in visible.iter().enumerate().skip(first).take(body_rows) {
                let Some(row) = b.dom.get(raw_idx) else {
                    continue;
                };
                let on = row_idx == sel;
                let row_bg = if on { t.bg2 } else { t.bg_dark };
                let marker = if on { "▶ " } else { "  " };
                // Two spaces per depth level, capped so very deep trees don't run off.
                let indent = "  ".repeat(row.depth.min(20));
                let color = if row.label.starts_with('<') && !row.label.starts_with("<!") {
                    t.blue
                } else if row.label.starts_with('“') {
                    t.fg
                } else {
                    t.comment
                };
                lines.push(Line::from(vec![
                    Span::styled(marker, Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled(indent, Style::default().bg(row_bg)),
                    Span::styled(row.label.clone(), Style::default().fg(color).bg(row_bg)),
                ]));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }

    if b.net_focus {
        // ── network panel: one selectable row per captured request ─────
        let visible = b.visible_net_indices();
        if b.net.is_empty() {
            lines.push(Line::from(Span::styled(
                "  (no network requests captured yet — Document / XHR / Fetch only)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else if visible.is_empty() {
            lines.push(Line::from(Span::styled(
                format!("  (no matches for '{}')", b.net_filter),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            let sel = b.net_sel.min(visible.len() - 1);
            // Keep the selected row inside the viewport.
            let first = if body_rows == 0 || sel < body_rows {
                0
            } else {
                sel + 1 - body_rows
            };
            for (row_idx, &raw_idx) in visible.iter().enumerate().skip(first).take(body_rows) {
                let Some(e) = b.net.get(raw_idx) else {
                    continue;
                };
                let on = row_idx == sel;
                let row_bg = if on { t.bg2 } else { t.bg_dark };
                let status = e.status_text();
                let status_color = if e.failed.is_some() {
                    t.red
                } else {
                    match e.status {
                        Some(s) if (200..300).contains(&s) => t.green,
                        Some(s) if (300..400).contains(&s) => t.yellow,
                        Some(s) if s >= 400 => t.red,
                        Some(_) => t.fg,
                        None => t.comment,
                    }
                };
                let marker = if on { "▶ " } else { "  " };
                let mut spans = vec![
                    Span::styled(marker, Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled(
                        format!("{:<6}", e.method),
                        Style::default().fg(t.blue).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{:>4} ", status),
                        Style::default().fg(status_color).bg(row_bg),
                    ),
                    Span::styled(e.short_url(), Style::default().fg(t.fg).bg(row_bg)),
                ];
                if let Some(m) = &e.mime
                    && !m.is_empty()
                {
                    spans.push(Span::styled(
                        format!("  [{m}]"),
                        Style::default().fg(t.comment).bg(row_bg),
                    ));
                }
                lines.push(Line::from(spans));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }

    // ── log (the line text carries its own marker — `→`, `←`, `»`, `= ` — so the
    // kind only drives colour, not a prefix glyph) ─────────────────
    for l in &b.log {
        let color = match l.kind {
            LogKind::System => t.comment,
            LogKind::Console => t.fg,
            LogKind::ConsoleErr => t.red,
            LogKind::Nav => t.blue,
            LogKind::Net => t.teal,
            LogKind::Eval => t.green,
        };
        lines.push(Line::from(vec![
            Span::styled("    ", Style::default().bg(t.bg_dark)),
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
