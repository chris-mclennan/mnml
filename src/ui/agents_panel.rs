//! Rail-content compact view of the Claude / Codex agents
//! dashboard. Rendered when `ActivitySection::Agents` is active.
//!
//! Polished version per user spec:
//!   - Animated spinner glyph on Running rows (replaces the
//!     static Claude logo).
//!   - Green ✓ on Done; red ! on Action Needed (pending tool
//!     confirm).
//!   - Rows grouped: Action Needed (top) · Running (middle) ·
//!     Done (bottom).
//!   - Filter input + `+ New` row at the top.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::claude_agents::AgentState;
use crate::ui::theme;

/// 6-frame partial-circle spinner. Cycles based on the system
/// clock so every rendered frame advances naturally — no need to
/// track tick state on App.
const SPINNER_FRAMES: &[&str] = &["◜", "◠", "◝", "◞", "◡", "◟"];

fn spinner_frame() -> &'static str {
    // ~150ms per frame; total cycle ≈ 900ms. Uses Instant arithmetic
    // not wall-clock so it stays smooth across DST etc.
    let now = std::time::Instant::now();
    // Anchor: a process-static start; differences are stable
    // within a run.
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(std::time::Instant::now);
    let ms = now.duration_since(*start).as_millis();
    let idx = (ms / 150) as usize % SPINNER_FRAMES.len();
    SPINNER_FRAMES[idx]
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 4 || area.width < 12 {
        return;
    }

    // Cheap-on-most-frames; only fires the actual scan every
    // ~5s.
    app.refresh_agents_panel_if_due();

    app.rects.agents_panel_rows.clear();
    app.rects.agents_panel_new_chip = None;
    app.rects.agents_panel_filter_input = None;

    let mut y = area.y;

    // Header.
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "AGENTS",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
        ])),
        Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        },
    );
    y += 1;

    // Filter input.
    if y < area.y + area.height {
        let focused = app.agents_panel_filter_focused;
        let bg_chip = t.bg2;
        let fg_chip = if app.agents_panel_filter.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        let display = if app.agents_panel_filter.is_empty() {
            "Filter…".to_string()
        } else {
            app.agents_panel_filter.clone()
        };
        let cursor = if focused { "▏" } else { " " };
        let pad = (area.width as usize)
            .saturating_sub(3 + display.chars().count() + 1 + 1);
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "\u{F0349} ",
                Style::default().fg(t.comment).bg(bg_chip),
            ),
            Span::styled(display, Style::default().fg(fg_chip).bg(bg_chip)),
            Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_chip)),
            Span::styled(" ".repeat(pad), Style::default().bg(bg_chip)),
            Span::styled(" ", Style::default().bg(bg)),
        ]);
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(line), row_rect);
        app.rects.agents_panel_filter_input = Some(row_rect);
        y += 1;
    }

    // `+ New` row.
    if y < area.y + area.height {
        let new_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    "+ New session ",
                    Style::default()
                        .fg(t.green)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    "(Claude · Codex)",
                    Style::default().fg(t.comment).bg(bg),
                ),
            ])),
            new_rect,
        );
        app.rects.agents_panel_new_chip = Some(new_rect);
        y += 1;
    }

    // 1-row gap before sections.
    y += 1;

    // Partition rows by status. Action Needed comes from
    // `pending_tool_uses > 0` (the row is waiting on a tool
    // confirm). Streaming → Running. Idle / Ended → Done.
    let filter_lc = app.agents_panel_filter.to_ascii_lowercase();
    let matches_filter = |r: &crate::claude_agents::AgentRow| -> bool {
        if filter_lc.is_empty() {
            return true;
        }
        let parts = [
            r.workspace.to_ascii_lowercase(),
            r.session_id.to_ascii_lowercase(),
            r.last_user_msg
                .as_deref()
                .unwrap_or_default()
                .to_ascii_lowercase(),
            r.last_assistant_msg
                .as_deref()
                .unwrap_or_default()
                .to_ascii_lowercase(),
        ];
        parts.iter().any(|p| p.contains(&filter_lc))
    };

    let mut action_needed: Vec<(usize, &crate::claude_agents::AgentRow)> = Vec::new();
    let mut running: Vec<(usize, &crate::claude_agents::AgentRow)> = Vec::new();
    let mut done: Vec<(usize, &crate::claude_agents::AgentRow)> = Vec::new();
    for (i, r) in app.agents_panel_rows.iter().enumerate() {
        if !matches_filter(r) {
            continue;
        }
        if r.pending_tool_uses > 0 {
            action_needed.push((i, r));
        } else if matches!(r.state, AgentState::Streaming | AgentState::ToolCall) {
            running.push((i, r));
        } else {
            done.push((i, r));
        }
    }

    let spinner = spinner_frame();
    let sections: [(&str, &[(usize, &crate::claude_agents::AgentRow)], &str, ratatui::style::Color); 3] = [
        ("Action needed", &action_needed[..], "!", t.red),
        ("Running", &running[..], spinner, t.cyan),
        ("Done", &done[..], "✓", t.green),
    ];

    let mut click_targets: Vec<(Rect, usize)> = Vec::new();
    for (label, items, glyph, glyph_color) in sections {
        if items.is_empty() || y >= area.y + area.height {
            continue;
        }
        // Section header.
        let header = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                label.to_string(),
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  ({})", items.len()),
                Style::default().fg(t.comment).bg(bg),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(header),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
        for &(i, r) in items {
            if y >= area.y + area.height {
                break;
            }
            // Truncate label for the rail width.
            let ws_label = r.workspace.clone();
            let last_msg = r
                .last_assistant_msg
                .clone()
                .or_else(|| r.last_user_msg.clone())
                .unwrap_or_else(|| "(no messages)".to_string());
            let max_msg = (area.width as usize).saturating_sub(ws_label.chars().count() + 8);
            let msg_clip: String =
                last_msg.lines().next().unwrap_or("").chars().take(max_msg).collect();
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            let line = Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    glyph.to_string(),
                    Style::default().fg(glyph_color).bg(bg),
                ),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(ws_label, Style::default().fg(t.fg).bg(bg)),
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(msg_clip, Style::default().fg(t.comment).bg(bg)),
            ]);
            frame.render_widget(Paragraph::new(line), row_rect);
            click_targets.push((row_rect, i));
            y += 1;
        }
        // 1-row gap between sections.
        if y < area.y + area.height {
            y += 1;
        }
    }
    app.rects.agents_panel_rows = click_targets;
}
