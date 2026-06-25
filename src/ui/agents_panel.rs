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

/// Match the file-browser's chevron convention: nf-fa-angle-down
/// for open, nf-fa-angle-right for closed. Same glyphs as
/// `src/ui/tree_view.rs` so collapsible groups read the same
/// across the rail.
const CHEVRON_OPEN: &str = "\u{f107}";
const CHEVRON_CLOSED: &str = "\u{f105}";

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
    app.rects.agents_panel_view_chip = None;
    app.rects.agents_panel_workspace_headers.clear();

    let mut y = area.y;

    // Header with view-mode toggle chip on the right.
    let view_label = if app.agents_panel_group_by_workspace {
        "workspace"
    } else {
        "status"
    };
    let view_chip = format!(" view: {view_label} ");
    let view_w = view_chip.chars().count() as u16;
    let header_left = "AGENTS";
    let header_used = 1 + header_left.chars().count() as u16 + view_w + 1;
    let pad = (area.width).saturating_sub(header_used);
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
                header_left.to_string(),
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ".repeat(pad as usize), Style::default().bg(bg)),
            Span::styled(
                view_chip,
                Style::default()
                    .fg(t.bg)
                    .bg(t.cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ", Style::default().bg(bg)),
        ])),
        header_row,
    );
    let chip_rect = Rect {
        x: area.x + 1 + header_left.chars().count() as u16 + pad,
        y,
        width: view_w,
        height: 1,
    };
    app.rects.agents_panel_view_chip = Some(chip_rect);
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
                Span::styled("(Claude · Codex)", Style::default().fg(t.comment).bg(bg)),
            ])),
            new_rect,
        );
        app.rects.agents_panel_new_chip = Some(new_rect);
        y += 1;
    }

    // 1-row gap before sections.
    y += 1;

    // First-load placeholder — the worker hasn't reported back
    // yet OR there genuinely are no sessions. Shown until the
    // first scan completes.
    if app.agents_panel_built_at.is_none() && y < area.y + area.height {
        let label = if app.agents_panel_rx.is_some() {
            "Scanning sessions…"
        } else {
            "No sessions yet."
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

    let spinner = spinner_frame();
    // Helper closure to render one row.
    let mut click_targets: Vec<(Rect, usize)> = Vec::new();
    let render_row = |frame: &mut Frame,
                      y: &mut u16,
                      i: usize,
                      r: &crate::claude_agents::AgentRow,
                      click_targets: &mut Vec<(Rect, usize)>| {
        if *y >= area.y + area.height {
            return;
        }
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
            .or_else(|| r.last_user_msg.clone())
            .unwrap_or_else(|| "(no messages)".to_string());
        let max_msg = (area.width as usize).saturating_sub(ws_label.chars().count() + 8);
        let msg_clip: String = last_msg
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(max_msg)
            .collect();
        let row_rect = Rect {
            x: area.x,
            y: *y,
            width: area.width,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(glyph.to_string(), Style::default().fg(glyph_color).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(ws_label, Style::default().fg(t.fg).bg(bg)),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(msg_clip, Style::default().fg(t.comment).bg(bg)),
        ]);
        frame.render_widget(Paragraph::new(line), row_rect);
        click_targets.push((row_rect, i));
        *y += 1;
    };

    if app.agents_panel_group_by_workspace {
        // Group by workspace. Insertion order = first-seen
        // workspace order (which roughly corresponds to most
        // recent activity due to the rail's existing sort).
        let mut groups: Vec<(String, Vec<(usize, &crate::claude_agents::AgentRow)>)> = Vec::new();
        for (i, r) in app.agents_panel_rows.iter().enumerate() {
            if !matches_filter(r) {
                continue;
            }
            if let Some(slot) = groups.iter_mut().find(|(w, _)| w == &r.workspace) {
                slot.1.push((i, r));
            } else {
                groups.push((r.workspace.clone(), vec![(i, r)]));
            }
        }
        // Default: every workspace collapsed. `expanded` set
        // tracks the workspaces the user has opened. Sort rows
        // inside each group newest-first, and sort groups by
        // their newest-row's activity.
        for (_, items) in &mut groups {
            items.sort_by_key(|(_, b)| std::cmp::Reverse(b.last_activity));
        }
        groups.sort_by(|(_, a_rows), (_, b_rows)| {
            let a_newest = a_rows.first().map(|(_, r)| r.last_activity);
            let b_newest = b_rows.first().map(|(_, r)| r.last_activity);
            b_newest.cmp(&a_newest)
        });
        let expanded = app.agents_panel_expanded_workspaces.clone();
        let mut workspace_headers: Vec<(Rect, String)> = Vec::new();
        for (ws, rows) in &groups {
            if y >= area.y + area.height {
                break;
            }
            let is_expanded = expanded.contains(ws);
            let chev = if is_expanded {
                CHEVRON_OPEN
            } else {
                CHEVRON_CLOSED
            };
            let header = Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    format!("{chev} {ws}  ({})", rows.len()),
                    Style::default()
                        .fg(t.fg)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ]);
            let header_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(header), header_rect);
            workspace_headers.push((header_rect, ws.clone()));
            y += 1;
            if is_expanded {
                for &(i, r) in rows {
                    render_row(frame, &mut y, i, r, &mut click_targets);
                }
            }
        }
        app.rects.agents_panel_workspace_headers = workspace_headers;
        app.rects.agents_panel_rows = click_targets;
        return;
    }

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
    // Newest-first in each section.
    for v in [&mut action_needed, &mut running, &mut done] {
        v.sort_by_key(|(_, b)| std::cmp::Reverse(b.last_activity));
    }
    let sections: [(&str, &[(usize, &crate::claude_agents::AgentRow)]); 3] = [
        ("Action needed", &action_needed[..]),
        ("Running", &running[..]),
        ("Done", &done[..]),
    ];
    for (label, items) in sections {
        if items.is_empty() || y >= area.y + area.height {
            continue;
        }
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
            render_row(frame, &mut y, i, r, &mut click_targets);
        }
        if y < area.y + area.height {
            y += 1;
        }
    }
    app.rects.agents_panel_rows = click_targets;
}
