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

/// Short-form an `agent_…` / `env_…` id so it fits the panel
/// header chip line (`agent_…ZyXw9` instead of the full 26 chars).
fn short_id(id: &str) -> String {
    let n = id.chars().count();
    if n <= 14 {
        return id.to_string();
    }
    let prefix: String = id.chars().take(4).collect();
    let suffix: String = id.chars().skip(n.saturating_sub(6)).collect();
    format!("{prefix}…{suffix}")
}

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
    app.rects.cloud_agents_view_chip = None;
    app.rects.cloud_agents_new_run_button = None;

    let mut y = area.y;
    let header_row = Rect {
        x: area.x,
        y,
        width: area.width,
        height: 1,
    };
    // Build the header line: "CLOUD AGENTS  (N)        [chip]"
    // where [chip] is "compact ⇄" or "standard ⇄" — clickable to
    // toggle the row-density mode.
    let view_label = app.cloud_agents_view.label();
    let chip_text = format!("{view_label} ⇄");
    let chip_width = chip_text.chars().count() as u16 + 2; // " " padding
    let header_label = "CLOUD AGENTS";
    let header_count = format!("  ({})", app.cloud_agents_rows.len());
    let used_left = 1 + header_label.chars().count() + header_count.chars().count();
    let pad_width = (area.width as usize).saturating_sub(used_left + chip_width as usize + 1);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                header_label,
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(header_count.clone(), Style::default().fg(t.comment).bg(bg)),
            Span::styled(" ".repeat(pad_width), Style::default().bg(bg)),
            Span::styled(
                chip_text.clone(),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg2)
                    .add_modifier(Modifier::BOLD),
            ),
        ])),
        header_row,
    );
    // Click rect for the chip — let users tap to flip density.
    let chip_x = area.x + (used_left + pad_width) as u16;
    if chip_x + chip_width <= area.x + area.width {
        app.rects.cloud_agents_view_chip = Some(Rect {
            x: chip_x,
            y: header_row.y,
            width: chip_width,
            height: 1,
        });
    }
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
        y += 1;
    }

    // Quick-fire input row vs first-run "+ New Cloud Run" button.
    // When `[cloud_run.defaults] agent_id` is set the user has
    // run the wizard at least once — show the input + change-
    // defaults chip. When unset, show the wizard CTA (and skip
    // the input, since there's nowhere to send to).
    app.rects.cloud_agents_quick_input = None;
    app.rects.cloud_agents_change_defaults_chip = None;
    app.rects.cloud_agents_new_run_button = None;
    let has_defaults = !app.config.cloud_run.defaults.agent_id.is_empty()
        && !app.config.cloud_run.defaults.env_id.is_empty();
    if has_defaults && y < area.y + area.height {
        // Tiny defaults chip line — shows which agent + env the
        // quick-send is targeting so the user can verify before
        // hitting Enter.
        let agent_short = short_id(&app.config.cloud_run.defaults.agent_id);
        let env_short = short_id(&app.config.cloud_run.defaults.env_id);
        let info_line = format!(
            "  ▸ {agent_short} → {env_short} ({})",
            app.config.cloud_run.defaults.sandbox
        );
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                info_line,
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
    }
    if has_defaults && y < area.y + area.height {
        // Input + change-defaults chip on the same row.
        let chip = " ⚙ defaults ";
        let chip_w = chip.chars().count() as u16;
        let focused = app.cloud_run_prompt_focused;
        let bg_in = if focused { t.bg2 } else { t.bg_darker };
        let fg_in = if app.cloud_run_prompt_input.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        let placeholder = if app.cloud_run_prompt_input.is_empty() {
            "Type a prompt + Enter to fire…".to_string()
        } else {
            app.cloud_run_prompt_input.clone()
        };
        let cursor = if focused { "▏" } else { " " };
        let pad = (area.width as usize)
            .saturating_sub(2 + 2 + placeholder.chars().count() + 1 + chip_w as usize + 2);
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(" \u{F0349} ", Style::default().fg(t.cyan).bg(bg_in)),
                Span::styled(placeholder, Style::default().fg(fg_in).bg(bg_in)),
                Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_in)),
                Span::styled(" ".repeat(pad), Style::default().bg(bg_in)),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    chip.to_string(),
                    Style::default()
                        .fg(t.bg_dark)
                        .bg(t.purple)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            row_rect,
        );
        // Input rect = everything left of the chip
        let chip_rect = Rect {
            x: area.x + area.width.saturating_sub(chip_w + 1),
            y,
            width: chip_w,
            height: 1,
        };
        let input_rect = Rect {
            x: area.x,
            y,
            width: area.width.saturating_sub(chip_w + 2),
            height: 1,
        };
        app.rects.cloud_agents_quick_input = Some(input_rect);
        app.rects.cloud_agents_change_defaults_chip = Some(chip_rect);
        y += 2;
    } else if !has_defaults && y < area.y + area.height {
        // First-run path — wizard CTA.
        let btn = " + New Cloud Run ";
        let bw = btn.chars().count() as u16;
        let btn_rect = Rect {
            x: area.x + 2,
            y,
            width: bw,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                btn.to_string(),
                Style::default()
                    .fg(t.bg_dark)
                    .bg(t.cyan)
                    .add_modifier(Modifier::BOLD),
            ))),
            btn_rect,
        );
        app.rects.cloud_agents_new_run_button = Some(btn_rect);
        y += 2;
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

    // Build a flat row list. Standard mode renders multi-line rows
    // (Vec<Line>) so we widen the Session variant.
    enum Item {
        Header(String),
        Session(usize, Vec<Line<'static>>),
        Blank,
    }
    let view_mode = app.cloud_agents_view;
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

    // Standard mode: render 3 lines per row so the user can tell
    // runs apart without drilling in. Line 1 has the same status
    // glyph + workspace label as compact mode so muscle memory is
    // preserved; lines 2-3 surface ticket / flow / state / time +
    // a wider last-message excerpt.
    let make_row_standard = |r: &crate::claude_agents::AgentRow,
                             m: Option<&crate::tattle_qwe::TattleQweMeta>|
     -> Vec<Line<'static>> {
        let (glyph, glyph_color) = if r.pending_tool_uses > 0 {
            ("!", t.red)
        } else if matches!(r.state, AgentState::Streaming | AgentState::ToolCall) {
            (spinner, t.cyan)
        } else {
            ("✓", t.green)
        };
        let ticket = m.map(|x| x.ticket.clone()).unwrap_or_default();
        let flow = m.map(|x| x.flow.clone()).unwrap_or_default();
        let state = m.map(|x| x.state.clone()).unwrap_or_default();
        let when = r
            .last_activity
            .map(|s| {
                use std::time::SystemTime;
                let now = SystemTime::now();
                let secs = now.duration_since(s).map(|d| d.as_secs()).unwrap_or(0);
                if secs < 60 {
                    format!("{secs}s ago")
                } else if secs < 3600 {
                    format!("{}m ago", secs / 60)
                } else if secs < 86400 {
                    format!("{}h ago", secs / 3600)
                } else {
                    format!("{}d ago", secs / 86400)
                }
            })
            .unwrap_or_else(|| "—".to_string());
        let last_msg = r
            .last_assistant_msg
            .clone()
            .unwrap_or_else(|| "(no summary)".to_string());
        let inner_w = (area.width as usize).saturating_sub(6);
        let msg_clip: String = last_msg
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(inner_w)
            .collect();
        // Line 1 — status glyph + ticket prominently + workspace.
        let line1 = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(glyph.to_string(), Style::default().fg(glyph_color).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled("☁", Style::default().fg(t.blue).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                if ticket.is_empty() {
                    r.workspace.clone()
                } else {
                    ticket.clone()
                },
                Style::default()
                    .fg(t.fg)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                if ticket.is_empty() {
                    String::new()
                } else {
                    r.workspace.clone()
                },
                Style::default().fg(t.comment).bg(bg),
            ),
        ]);
        // Line 2 — flow · state · last activity. Tight metadata
        // strip in muted color.
        let mut line2_spans = vec![Span::styled("     ", Style::default().bg(bg))];
        if !flow.is_empty() {
            line2_spans.push(Span::styled(
                flow.clone(),
                Style::default().fg(t.cyan).bg(bg),
            ));
            line2_spans.push(Span::styled(" · ", Style::default().fg(t.comment).bg(bg)));
        }
        if !state.is_empty() {
            line2_spans.push(Span::styled(
                state.clone(),
                Style::default().fg(t.yellow).bg(bg),
            ));
            line2_spans.push(Span::styled(" · ", Style::default().fg(t.comment).bg(bg)));
        }
        line2_spans.push(Span::styled(when, Style::default().fg(t.comment).bg(bg)));
        let line2 = Line::from(line2_spans);
        // Line 3 — last-message excerpt (one line, truncated).
        let line3 = Line::from(vec![
            Span::styled("     ", Style::default().bg(bg)),
            Span::styled(msg_clip, Style::default().fg(t.comment).bg(bg)),
        ]);
        vec![line1, line2, line3]
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
            let lines = match view_mode {
                crate::app::CloudAgentsView::Compact => vec![make_row(r)],
                crate::app::CloudAgentsView::Standard => {
                    let m = app.cloud_agents_meta.get(&r.session_id);
                    make_row_standard(r, m)
                }
            };
            content.push(Item::Session(i, lines));
        }
        content.push(Item::Blank);
    }

    let content_top = y;
    let content_bottom = area.y + area.height;
    let visible_h = content_bottom.saturating_sub(content_top) as usize;
    // Variable item heights — sessions take their lines.len() rows;
    // headers and blanks always take 1 row. Walk total height in
    // rows, not item count.
    let item_height = |it: &Item| -> usize {
        match it {
            Item::Session(_, lines) => lines.len(),
            Item::Header(_) | Item::Blank => 1,
        }
    };
    let total_rows: usize = content.iter().map(item_height).sum();
    let max_scroll = total_rows.saturating_sub(visible_h);
    app.cloud_agents_scroll = app.cloud_agents_scroll.min(max_scroll);
    let scroll = app.cloud_agents_scroll;

    let mut click_targets: Vec<(Rect, usize)> = Vec::new();
    let mut cursor_row: usize = 0;
    for item in content.into_iter() {
        let h = item_height(&item);
        let item_top = cursor_row;
        cursor_row += h;
        // Skip items that are above the scroll window OR start past
        // the bottom of the visible area.
        if item_top + h <= scroll {
            continue;
        }
        if item_top >= scroll + visible_h {
            break;
        }
        // Offset within the visible window (might be negative if the
        // item starts above the scroll — we clamp by skipping lines).
        let visible_start_in_item = scroll.saturating_sub(item_top);
        let render_y = content_top + (item_top + visible_start_in_item - scroll) as u16;
        match item {
            Item::Session(idx, lines) => {
                let lines_to_render: Vec<Line<'static>> =
                    lines.into_iter().skip(visible_start_in_item).collect();
                let row_rect = Rect {
                    x: area.x,
                    y: render_y,
                    width: area.width,
                    height: lines_to_render.len() as u16,
                };
                for (li, line) in lines_to_render.iter().enumerate() {
                    let line_rect = Rect {
                        x: area.x,
                        y: render_y + li as u16,
                        width: area.width,
                        height: 1,
                    };
                    if line_rect.y >= content_bottom {
                        break;
                    }
                    frame.render_widget(Paragraph::new(line.clone()), line_rect);
                }
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
                    Rect {
                        x: area.x,
                        y: render_y,
                        width: area.width,
                        height: 1,
                    },
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
