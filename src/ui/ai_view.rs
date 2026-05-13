//! Renders a `Pane::Ai` — either a `claude -p` answer (markdown, via
//! [`super::md_preview::render_markdown`]) or a live mirror of a Claude Code
//! session transcript (user / assistant / thinking / tool calls / tool results).
//! Read-only + scrollable; `r` re-asks, `c` continues interactively (handled in
//! `tui.rs`). `G` jumps to the bottom (follow the conversation).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::ai::AiState;
use crate::ai::transcript::Turn;
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
    let body = Style::default().fg(t.fg).bg(t.bg_dark);
    let mut rows: Vec<Line> = Vec::new();
    rows.push(Line::from(Span::styled(
        format!("✦ {}", ai.title),
        Style::default()
            .fg(t.purple)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));
    let prompt_first = ai.prompt.lines().next().unwrap_or("").trim();
    if !prompt_first.is_empty() {
        rows.push(Line::from(Span::styled(format!("  {prompt_first}"), dim)));
    }
    let hint: String = if ai.is_live() {
        "  live mirror · c open interactive pane · G follow · esc → tree".into()
    } else if matches!(ai.state, AiState::Asking | AiState::Streaming(_)) {
        "  x cancel · esc → tree".into()
    } else if ai.target.is_some() && matches!(ai.state, AiState::Done(_)) {
        "  r re-ask · a apply suggestion · c continue in Claude Code · esc → tree".into()
    } else {
        "  r re-ask · c continue in Claude Code · esc → tree".into()
    };
    rows.push(Line::from(Span::styled(hint, dim)));
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
        AiState::Streaming(text) => {
            rows.extend(md_preview::render_markdown(text));
            rows.push(Line::from(Span::styled(
                "  ▌ …",
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )));
        }
        AiState::Done(text) => rows.extend(md_preview::render_markdown(text)),
        AiState::Live { turns, .. } => {
            if turns.is_empty() {
                rows.push(Line::from(Span::styled("  (no messages yet)", dim)));
            }
            for turn in turns {
                render_turn(turn, &t, body, dim, &mut rows);
            }
        }
    }

    let rows = md_preview::wrap_lines(rows, area.width as usize);
    let h = area.height as usize;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    // Follow the tail while streaming (you want the newest text); the user can
    // scroll once it settles.
    if matches!(ai.state, AiState::Streaming(_)) {
        ai.scroll = max_scroll;
    }
    ai.scroll = ai.scroll.min(max_scroll);
    let view: Vec<Line> = rows.into_iter().skip(ai.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));
    None
}

fn render_turn(
    turn: &Turn,
    t: &theme::Theme,
    body: Style,
    dim: Style,
    rows: &mut Vec<Line<'static>>,
) {
    let blank = || Line::from(Span::styled(String::new(), body));
    match turn {
        Turn::User(text) => {
            rows.push(blank());
            rows.push(Line::from(Span::styled(
                "▸ you",
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )));
            for l in text.lines() {
                rows.push(Line::from(Span::styled(format!("  {l}"), body)));
            }
        }
        Turn::Assistant(text) => {
            rows.push(blank());
            rows.push(Line::from(Span::styled(
                "◆ claude",
                Style::default()
                    .fg(t.purple)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )));
            rows.extend(md_preview::render_markdown(text));
        }
        Turn::Thinking(preview) => {
            rows.push(Line::from(Span::styled(
                format!("  💭 {preview}"),
                dim.add_modifier(Modifier::ITALIC),
            )));
        }
        Turn::ToolUse { name, summary } => {
            rows.push(Line::from(vec![
                Span::styled("  ⚙ ", Style::default().fg(t.yellow).bg(t.bg_dark)),
                Span::styled(
                    name.clone(),
                    Style::default()
                        .fg(t.yellow)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("  {summary}"), dim),
            ]));
        }
        Turn::ToolResult(text) => {
            rows.push(Line::from(Span::styled(format!("    → {text}"), dim)));
        }
    }
}
