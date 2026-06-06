//! Renderer for `Pane::PipelineLog` — a scrollable read-only
//! text view with a header line showing fetch state.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::pipeline_log::{PipelineLogPane, PipelineLogState};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, pane: &mut PipelineLogPane, area: Rect) {
    let t = theme::cur();
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    if area.height < 2 || area.width == 0 {
        return;
    }
    // Header.
    let header_line = match &pane.state {
        PipelineLogState::Fetching => Line::from(vec![
            Span::styled(
                " ⏵ fetching log… ",
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(pane.title.clone(), Style::default().fg(t.fg).bg(t.bg)),
        ]),
        PipelineLogState::Done(log) => {
            let lines = log.lines().count();
            Line::from(vec![
                Span::styled(
                    " ✓ ",
                    Style::default()
                        .fg(t.green)
                        .bg(t.bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(pane.title.clone(), Style::default().fg(t.fg).bg(t.bg)),
                Span::styled(
                    format!("  · {lines} lines"),
                    Style::default().fg(t.comment).bg(t.bg),
                ),
            ])
        }
        PipelineLogState::Failed(msg) => Line::from(vec![
            Span::styled(
                " ✗ ",
                Style::default()
                    .fg(t.red)
                    .bg(t.bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(pane.title.clone(), Style::default().fg(t.fg).bg(t.bg)),
            Span::styled(format!("  · {msg}"), Style::default().fg(t.red).bg(t.bg)),
        ]),
    };
    frame.render_widget(
        Paragraph::new(header_line),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );
    // Footer hint.
    if area.height >= 3 {
        let hint = Line::from(vec![Span::styled(
            " r refresh · y copy url · Enter open in browser · Esc back ",
            Style::default().fg(t.comment).bg(t.bg),
        )]);
        frame.render_widget(
            Paragraph::new(hint),
            Rect {
                x: area.x,
                y: area.y + area.height - 1,
                width: area.width,
                height: 1,
            },
        );
    }
    // Body — render the log text starting from `scroll`.
    let body_top = area.y + 1;
    let body_height = area.height.saturating_sub(2);
    if body_height == 0 {
        return;
    }
    let body_rect = Rect {
        x: area.x,
        y: body_top,
        width: area.width,
        height: body_height,
    };
    let lines: Vec<Line> = match &pane.state {
        PipelineLogState::Fetching => vec![Line::from(Span::styled(
            "(loading…)",
            Style::default().fg(t.comment).bg(t.bg),
        ))],
        PipelineLogState::Done(log) => {
            let total = log.lines().count();
            // Clamp scroll so the last line is at least visible.
            let max_scroll = total.saturating_sub(body_height as usize);
            if pane.scroll > max_scroll {
                pane.scroll = max_scroll;
            }
            log.lines()
                .skip(pane.scroll)
                .take(body_height as usize)
                .map(|raw| {
                    // Style step-separator lines (the ones we inject in the
                    // API helper) as bold cyan so they stand out from
                    // step output.
                    if raw.starts_with("══") {
                        Line::from(Span::styled(
                            raw.to_string(),
                            Style::default()
                                .fg(t.cyan)
                                .bg(t.bg)
                                .add_modifier(Modifier::BOLD),
                        ))
                    } else {
                        Line::from(Span::styled(
                            raw.to_string(),
                            Style::default().fg(t.fg).bg(t.bg),
                        ))
                    }
                })
                .collect()
        }
        PipelineLogState::Failed(msg) => vec![Line::from(Span::styled(
            msg.clone(),
            Style::default().fg(t.red).bg(t.bg),
        ))],
    };
    frame.render_widget(Paragraph::new(lines), body_rect);
}
