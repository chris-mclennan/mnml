//! Rail-content panel for the Cloud Agents activity-bar section.
//! Renders Tattle QWE runner rows (from `App::cloud_agents_rows`)
//! grouped by state.
//!
//! Unlike the local Agents panel:
//!   - No `+ New session` chip (yet — would need to call qwe-runner's
//!     trigger API; deferred).
//!   - No group-by-workspace mode (cloud rows are already per-ticket).
//!   - Click → copy runId + toast (no local resume path).
//!   - Right-click → context menu (Copy runId · Open CloudWatch · Open PR).

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

/// 6-frame partial-circle spinner — same as the local agents panel.
const SPINNER_FRAMES: &[&str] = &["◜", "◠", "◝", "◞", "◡", "◟"];

fn spinner_frame() -> &'static str {
    let now = std::time::Instant::now();
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

    // Triggers the same worker that builds local agents — cheap on
    // most frames; the actual scan runs every 30s.
    app.refresh_agents_panel_if_due();

    app.rects.cloud_agents_rows.clear();
    app.rects.cloud_agents_filter_input = None;

    let mut y = area.y;
    let header_row = Rect {
        x: area.x,
        y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "CLOUD AGENTS",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  ({})", app.cloud_agents_rows.len()),
                Style::default().fg(t.comment).bg(bg),
            ),
        ])),
        header_row,
    );
    y += 1;

    // Filter input — same shape as the local panel for muscle memory.
    if y < area.y + area.height {
        let focused = app.cloud_agents_filter_focused;
        let bg_chip = t.bg2;
        let fg_chip = if app.cloud_agents_filter.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        let display = if app.cloud_agents_filter.is_empty() {
            "Filter ticket / runId / state…".to_string()
        } else {
            app.cloud_agents_filter.clone()
        };
        let cursor = if focused { "▏" } else { " " };
        let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled("\u{F0349} ", Style::default().fg(t.comment).bg(bg_chip)),
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
        app.rects.cloud_agents_filter_input = Some(row_rect);
        y += 2; // 1-row gap before content
    }

    // Cold-start placeholder.
    if app.agents_panel_built_at.is_none() && y < area.y + area.height {
        let label = if app.agents_panel_rx.is_some() {
            "Scanning qwe-runner-runs…"
        } else {
            "(start a refresh — open Agents view)"
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(label, Style::default().fg(t.comment).bg(bg)),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        return;
    }
    if app.cloud_agents_rows.is_empty() && y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "No recent cloud runs.",
                    Style::default().fg(t.comment).bg(bg),
                ),
                Span::styled(
                    "  (last 24h · AWS_PROFILE=claude-ro)",
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        return;
    }

    let spinner = spinner_frame();
    let filter_lc = app.cloud_agents_filter.to_ascii_lowercase();
    let matches_filter = |r: &crate::claude_agents::AgentRow,
                          m: Option<&crate::tattle_qwe::TattleQweMeta>|
     -> bool {
        if filter_lc.is_empty() {
            return true;
        }
        let mut parts: Vec<String> = vec![
            r.workspace.to_ascii_lowercase(),
            r.session_id.to_ascii_lowercase(),
        ];
        if let Some(m) = m {
            parts.push(m.state.to_ascii_lowercase());
            parts.push(m.flow.to_ascii_lowercase());
        }
        parts.iter().any(|p| p.contains(&filter_lc))
    };

    // Partition by state — same shape as the local panel's
    // "Action needed / Running / Done" but using qwe state.
    let mut action_needed: Vec<(usize, &crate::claude_agents::AgentRow)> = Vec::new();
    let mut running: Vec<(usize, &crate::claude_agents::AgentRow)> = Vec::new();
    let mut done: Vec<(usize, &crate::claude_agents::AgentRow)> = Vec::new();
    for (i, r) in app.cloud_agents_rows.iter().enumerate() {
        let m = app.cloud_agents_meta.get(&r.session_id);
        if !matches_filter(r, m) {
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
    for v in [&mut action_needed, &mut running, &mut done] {
        v.sort_by_key(|(_, b)| std::cmp::Reverse(b.last_activity));
    }

    // Build a flat row list.
    enum Item {
        Header(String),
        Session(usize, Line<'static>),
        Blank,
    }
    let make_row = |r: &crate::claude_agents::AgentRow| -> Line<'static> {
        let (glyph, glyph_color) = if r.pending_tool_uses > 0 {
            ("!", t.red)
        } else if matches!(r.state, AgentState::Streaming | AgentState::ToolCall) {
            (spinner, t.cyan)
        } else {
            ("✓", t.green)
        };
        let ws_label = r.workspace.clone();
        let last_msg = r
            .last_assistant_msg
            .clone()
            .unwrap_or_else(|| "(no summary)".to_string());
        let max_msg = (area.width as usize).saturating_sub(ws_label.chars().count() + 10);
        let msg_clip: String = last_msg
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(max_msg)
            .collect();
        Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(glyph.to_string(), Style::default().fg(glyph_color).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled("☁", Style::default().fg(t.blue).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(ws_label, Style::default().fg(t.fg).bg(bg)),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(msg_clip, Style::default().fg(t.comment).bg(bg)),
        ])
    };
    let sections: [(&str, &[(usize, &crate::claude_agents::AgentRow)]); 3] = [
        ("Action needed", &action_needed[..]),
        ("Running", &running[..]),
        ("Done", &done[..]),
    ];
    let mut content: Vec<Item> = Vec::new();
    for (label, items) in sections {
        if items.is_empty() {
            continue;
        }
        content.push(Item::Header(format!("{label}  ({})", items.len())));
        for &(i, r) in items {
            content.push(Item::Session(i, make_row(r)));
        }
        content.push(Item::Blank);
    }

    let content_top = y;
    let content_bottom = area.y + area.height;
    let visible_h = content_bottom.saturating_sub(content_top) as usize;
    let total = content.len();
    let max_scroll = total.saturating_sub(visible_h);
    app.cloud_agents_scroll = app.cloud_agents_scroll.min(max_scroll);
    let scroll = app.cloud_agents_scroll;

    let mut click_targets: Vec<(Rect, usize)> = Vec::new();
    for (vi, item) in content.into_iter().enumerate().skip(scroll).take(visible_h) {
        let row_rect = Rect {
            x: area.x,
            y: content_top + (vi - scroll) as u16,
            width: area.width,
            height: 1,
        };
        match item {
            Item::Session(idx, line) => {
                frame.render_widget(Paragraph::new(line), row_rect);
                click_targets.push((row_rect, idx));
            }
            Item::Header(label) => {
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled(" ", Style::default().bg(bg)),
                        Span::styled(
                            label,
                            Style::default()
                                .fg(t.comment)
                                .bg(bg)
                                .add_modifier(Modifier::BOLD),
                        ),
                    ])),
                    row_rect,
                );
            }
            Item::Blank => {}
        }
    }
    app.rects.cloud_agents_rows = click_targets;
    app.rects.cloud_agents_area = Some(Rect {
        x: area.x,
        y: content_top,
        width: area.width,
        height: visible_h as u16,
    });
}
