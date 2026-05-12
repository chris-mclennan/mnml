//! Renders a `Pane::Ai` — the prompt sent to `claude -p` and, once the worker
//! returns, the answer (rendered as markdown via [`super::md_preview::render_markdown`],
//! since the CLI replies in markdown). Read-only + scrollable; `r` re-asks
//! (handled in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::ai::AiState;
use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::{md_preview, theme};

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
    let Some(Pane::Ai(ai)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let mut rows: Vec<Line> = Vec::new();
    rows.push(Line::from(Span::styled(
        format!("✦ {}", ai.title),
        Style::default()
            .fg(t.purple)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));
    // The prompt, dimmed — first line only (it can be long when it wraps a code block).
    let prompt_first = ai.prompt.lines().next().unwrap_or("").trim();
    if !prompt_first.is_empty() {
        rows.push(Line::from(Span::styled(format!("  {prompt_first}"), dim)));
    }
    rows.push(Line::from(Span::styled(
        "─".repeat(area.width as usize),
        Style::default().fg(t.line).bg(t.bg_dark),
    )));

    match &ai.state {
        AiState::Asking => rows.push(Line::from(Span::styled(
            "  ⟳ thinking… (claude -p)".to_string(),
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ))),
        AiState::Failed(e) => rows.push(Line::from(Span::styled(
            format!("  ✗ {e}"),
            Style::default()
                .fg(t.red)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ))),
        AiState::Done(text) => rows.extend(md_preview::render_markdown(text)),
    }

    let h = area.height as usize;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    ai.scroll = ai.scroll.min(max_scroll);
    let view: Vec<Line> = rows.into_iter().skip(ai.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));
    None
}
