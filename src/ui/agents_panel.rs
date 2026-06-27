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
    app.rects.agents_panel_pr_chip = None;
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
        // Two chips on the row: "+ New session" + "+ from PR".
        // The first fires a single Claude Code session in the
        // workspace; the second opens the wizard that picks PRs
        // and fires one session per checked PR.
        let new_chip_text = " + New session ";
        let pr_chip_text = " + from PR ";
        let new_w = new_chip_text.chars().count() as u16;
        let pr_w = pr_chip_text.chars().count() as u16;
        let pad = (area.width as usize).saturating_sub(1 + new_w as usize + 1 + pr_w as usize + 1);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    new_chip_text.to_string(),
                    Style::default()
                        .fg(t.bg_darker)
                        .bg(t.green)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    pr_chip_text.to_string(),
                    Style::default()
                        .fg(t.bg_darker)
                        .bg(t.cyan)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ])),
            new_rect,
        );
        app.rects.agents_panel_new_chip = Some(Rect {
            x: area.x + 1,
            y,
            width: new_w,
            height: 1,
        });
        app.rects.agents_panel_pr_chip = Some(Rect {
            x: area.x + 1 + new_w + 1,
            y,
            width: pr_w,
            height: 1,
        });
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
    // Build one session row's Line (owned — borrows nothing from `app`, so
    // the content list can outlive the `agents_panel_rows` borrow below).
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
        Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(glyph.to_string(), Style::default().fg(glyph_color).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(ws_label, Style::default().fg(t.fg).bg(bg)),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(msg_clip, Style::default().fg(t.comment).bg(bg)),
        ])
    };

    // Build a flat content list (headers + session rows) for whichever view
    // mode is active. The borrow of `app.agents_panel_rows` ends with this
    // `let` (the rows are cloned into owned Lines), freeing `app` to mutate.
    let content: Vec<PanelRow> = if app.agents_panel_group_by_workspace {
        // Group by workspace. Insertion order = first-seen workspace order
        // (roughly most-recent activity, thanks to the rail's sort).
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
        // Sort rows newest-first within each group, and groups by their
        // newest row's activity.
        for (_, items) in &mut groups {
            items.sort_by_key(|(_, b)| std::cmp::Reverse(b.last_activity));
        }
        groups.sort_by(|(_, a_rows), (_, b_rows)| {
            let a_newest = a_rows.first().map(|(_, r)| r.last_activity);
            let b_newest = b_rows.first().map(|(_, r)| r.last_activity);
            b_newest.cmp(&a_newest)
        });
        let expanded = app.agents_panel_expanded_workspaces.clone();
        let mut content = Vec::new();
        for (ws, rows) in &groups {
            let is_expanded = expanded.contains(ws);
            let chev = if is_expanded {
                CHEVRON_OPEN
            } else {
                CHEVRON_CLOSED
            };
            content.push(PanelRow::WsHeader(
                ws.clone(),
                Line::from(vec![
                    Span::styled(" ", Style::default().bg(bg)),
                    Span::styled(
                        format!("{chev} {ws}  ({})", rows.len()),
                        Style::default()
                            .fg(t.fg)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]),
            ));
            if is_expanded {
                for &(i, r) in rows {
                    content.push(PanelRow::Session(i, make_row(r)));
                }
            }
        }
        content
    } else {
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
        for v in [&mut action_needed, &mut running, &mut done] {
            v.sort_by_key(|(_, b)| std::cmp::Reverse(b.last_activity));
        }
        let sections: [(&str, &[(usize, &crate::claude_agents::AgentRow)]); 3] = [
            ("Action needed", &action_needed[..]),
            ("Running", &running[..]),
            ("Done", &done[..]),
        ];
        let mut content = Vec::new();
        for (label, items) in sections {
            if items.is_empty() {
                continue;
            }
            content.push(PanelRow::Header(Line::from(vec![
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
            ])));
            for &(i, r) in items {
                content.push(PanelRow::Session(i, make_row(r)));
            }
            content.push(PanelRow::Blank);
        }
        content
    };

    // Window the content against the visible height, applying the scroll
    // offset and reserving a column for a scrollbar when it overflows.
    let content_top = y;
    let content_bottom = area.y + area.height;
    let visible_h = content_bottom.saturating_sub(content_top) as usize;
    let total = content.len();
    let needs_sb = visible_h > 0 && total > visible_h;
    let sb_w: u16 = if needs_sb { 1 } else { 0 };
    let row_w = area.width.saturating_sub(sb_w);

    let max_scroll = total.saturating_sub(visible_h);
    app.agents_panel_scroll = app.agents_panel_scroll.min(max_scroll);
    let scroll = app.agents_panel_scroll;

    let mut click_targets: Vec<(Rect, usize)> = Vec::new();
    let mut workspace_headers: Vec<(Rect, String)> = Vec::new();
    for (vi, item) in content.into_iter().enumerate().skip(scroll).take(visible_h) {
        let row_rect = Rect {
            x: area.x,
            y: content_top + (vi - scroll) as u16,
            width: row_w,
            height: 1,
        };
        match item {
            PanelRow::Session(idx, line) => {
                frame.render_widget(Paragraph::new(line), row_rect);
                click_targets.push((row_rect, idx));
            }
            PanelRow::Header(line) => {
                frame.render_widget(Paragraph::new(line), row_rect);
            }
            PanelRow::WsHeader(ws, line) => {
                frame.render_widget(Paragraph::new(line), row_rect);
                workspace_headers.push((row_rect, ws));
            }
            PanelRow::Blank => {}
        }
    }
    app.rects.agents_panel_rows = click_targets;
    app.rects.agents_panel_workspace_headers = workspace_headers;
    app.rects.agents_panel_area = Some(Rect {
        x: area.x,
        y: content_top,
        width: area.width,
        height: visible_h as u16,
    });

    if needs_sb {
        let sb_area = Rect {
            x: area.x + row_w,
            y: content_top,
            width: sb_w,
            height: visible_h as u16,
        };
        crate::ui::scrollbar::paint_simple_scrollbar(frame, sb_area, &t, total, visible_h, scroll);
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id: 0,
            total,
            viewport: visible_h,
            kind: crate::app::ScrollbarKind::AgentsPanel,
        });
    }
}

/// One flat row of the agents panel's scrollable content list — built for
/// whichever view mode is active, then windowed against the visible height.
enum PanelRow {
    /// A session row; carries the `agents_panel_rows` index for click routing.
    Session(usize, ratatui::text::Line<'static>),
    /// A section header (Action needed / Running / Done).
    Header(ratatui::text::Line<'static>),
    /// A workspace group header; carries the workspace for click routing.
    WsHeader(String, ratatui::text::Line<'static>),
    /// A blank spacer row (section gap).
    Blank,
}
