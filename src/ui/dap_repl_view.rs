//! `Pane::DapRepl` — a tiny REPL for the DAP `evaluate` request.
//!
//! Layout: 1 row header, history list (each row = expression + result),
//! 1 row input strip with the caret. Reuses the App's `evaluate`
//! infrastructure (same channel watches use, just `context: "repl"`)
//! so the adapter sees the same call shape.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::{DapReplPane, Pane};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, pane_id: PaneId, area: Rect, focused: bool) {
    let Some(Pane::DapRepl(p)) = app.panes.get(pane_id) else {
        return;
    };
    let t = theme::cur();
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .split(area);
    draw_header(frame, p, chunks[0]);
    draw_history(frame, app, p, chunks[1]);
    draw_input(frame, p, chunks[2], focused);
    let _ = t;
}

fn draw_header(frame: &mut Frame, p: &DapReplPane, area: Rect) {
    let t = theme::cur();
    let line = if p.filter_mode {
        Line::from(vec![
            Span::styled(" DAP REPL ", Style::default().fg(t.bg_dark).bg(t.cyan)),
            Span::styled(
                format!(
                    "  filter: {}_ · Backspace · Enter applies · Esc clears",
                    p.filter
                ),
                Style::default().fg(t.yellow).bg(t.bg_dark),
            ),
        ])
    } else if !p.filter.is_empty() {
        let visible = p.visible_history_indices().len();
        Line::from(vec![
            Span::styled(" DAP REPL ", Style::default().fg(t.bg_dark).bg(t.cyan)),
            Span::styled(
                format!(
                    "  ({}/{} match \"{}\")  ",
                    visible,
                    p.history.len(),
                    p.filter
                ),
                Style::default().fg(t.yellow).bg(t.bg_dark),
            ),
            Span::styled(
                "Enter: eval · ↑↓: history · /: refilter · Esc clears filter",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ])
    } else {
        Line::from(vec![
            Span::styled(" DAP REPL ", Style::default().fg(t.bg_dark).bg(t.cyan)),
            Span::styled(
                "  Enter: eval · ↑↓: history · Sh-↑↓: select row · o: expand · /: filter · Esc: tree",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ])
    };
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(t.bg_dark)),
        area,
    );
}

fn draw_history(frame: &mut Frame, app: &App, p: &DapReplPane, area: Rect) {
    let t = theme::cur();
    let body_h = area.height as usize;
    let total = p.history.len();
    // When a filter is held, walk only the matched entries. `visible`
    // is the index-into-history list; everything below indexes through
    // it so scroll math + selection work in the narrowed view.
    let visible: Vec<usize> = p.visible_history_indices();
    let visible_count = visible.len();
    let mut lines: Vec<Line> = Vec::new();
    if total == 0 {
        lines.push(Line::from(Span::styled(
            "  (no evaluations yet — type an expression below)",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    } else if visible_count == 0 {
        lines.push(Line::from(Span::styled(
            format!("  (no matches for \"{}\")", p.filter),
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    } else {
        // Pick the starting offset (into `visible`) for the render walk.
        // Tail-pinned ⇒ walk back from the end until we run out of budget;
        // explicit scroll ⇒ snap to the closest visible position so a
        // partial filter doesn't blank the pane.
        let render_from_in_visible = if p.scroll == usize::MAX {
            let mut budget = body_h;
            let mut idx = visible_count;
            while idx > 0 {
                let e = &p.history[visible[idx - 1]];
                let rows = entry_render_rows(app, e);
                if budget < rows {
                    break;
                }
                budget -= rows;
                idx -= 1;
            }
            idx
        } else {
            visible
                .iter()
                .position(|&i| i >= p.scroll)
                .unwrap_or(visible_count.saturating_sub(1))
        };
        for &i in visible.iter().skip(render_from_in_visible) {
            if lines.len() >= body_h {
                break;
            }
            let entry = &p.history[i];
            let selected = p.selected == Some(i);
            let chip_bg = if selected { t.bg2 } else { t.bg_dark };
            // `> expr` row — yellow prefix, fg text. Selected row gets
            // a brighter bg so the user knows where `o` will fire.
            let expand_chip = if entry.variables_ref > 0 {
                if entry.expanded { "▾ " } else { "▸ " }
            } else {
                "  "
            };
            lines.push(Line::from(vec![
                Span::styled(
                    format!("{}▶ ", if selected { "● " } else { "  " }),
                    Style::default().fg(t.cyan).bg(chip_bg),
                ),
                Span::styled(expand_chip, Style::default().fg(t.comment).bg(chip_bg)),
                Span::styled(
                    entry.expression.clone(),
                    Style::default().fg(t.fg).bg(chip_bg),
                ),
            ]));
            // Result row.
            let (text, fg) = if entry.pending {
                ("    (evaluating…)".to_string(), t.comment)
            } else if let Some(err) = &entry.err {
                (format!("    err: {err}"), t.red)
            } else if let Some(ty) = &entry.ty {
                (format!("    = {} : {ty}", entry.value), t.green)
            } else {
                (format!("    = {}", entry.value), t.green)
            };
            lines.push(Line::from(Span::styled(
                text,
                Style::default().fg(fg).bg(chip_bg),
            )));
            // Expanded children — pull from DapManager.variables.
            if entry.expanded && entry.variables_ref > 0 {
                let kids = app
                    .dap
                    .as_ref()
                    .and_then(|m| m.variables.get(&entry.variables_ref));
                if let Some(kids) = kids {
                    for k in kids {
                        let kid_chip = match &k.ty {
                            Some(ty) if !ty.is_empty() => {
                                format!("      {} : {} = {}", k.name, ty, k.value)
                            }
                            _ => format!("      {} = {}", k.name, k.value),
                        };
                        lines.push(Line::from(Span::styled(
                            kid_chip,
                            Style::default().fg(t.fg).bg(t.bg_dark),
                        )));
                    }
                } else {
                    lines.push(Line::from(Span::styled(
                        "      (fetching children…)".to_string(),
                        Style::default().fg(t.comment).bg(t.bg_dark),
                    )));
                }
            }
        }
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
        area,
    );
}

/// How many rendered rows a single REPL entry needs (expression line +
/// result line + expanded children if any).
fn entry_render_rows(app: &App, entry: &crate::pane::DapReplEntry) -> usize {
    let mut rows = 2;
    if entry.expanded && entry.variables_ref > 0 {
        let kid_count = app
            .dap
            .as_ref()
            .and_then(|m| m.variables.get(&entry.variables_ref))
            .map(|v| v.len())
            .unwrap_or(1); // placeholder "fetching" row
        rows += kid_count;
    }
    rows
}

fn draw_input(frame: &mut Frame, p: &DapReplPane, area: Rect, focused: bool) {
    let t = theme::cur();
    let prompt = "(repl) > ";
    let mut spans = vec![Span::styled(
        prompt,
        Style::default()
            .fg(t.yellow)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )];
    // Render the input with the caret as a `▏` (left one-eighth block)
    // — same convention as the cmdline bar.
    let before: String = p.input[..p.cursor].to_string();
    let after: String = p.input[p.cursor..].to_string();
    spans.push(Span::styled(
        before,
        Style::default().fg(t.fg).bg(t.bg_dark),
    ));
    if focused {
        spans.push(Span::styled(
            "▏",
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ));
    }
    spans.push(Span::styled(after, Style::default().fg(t.fg).bg(t.bg_dark)));
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(t.bg_dark)),
        area,
    );
}
