//! Rail-content panel for the Cloud Agents activity-bar section.
//! Renders ECS runner rows (from `App::cloud_agents_rows`)
//! grouped by state.
//!
//! Unlike the local Agents panel:
//!   - No `+ New session` chip (yet — would need to call the ECS
//!     runner's trigger API; deferred).
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
    // most frames; the actual refresh cadence is set in
    // `App::refresh_agents_panel_if_due` (30s local / 2min when
    // cloud_agents is configured, since this section's DynamoDB
    // scan is the expensive half).
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
    // R16 design-critic pass (2026-08-24) — header overhaul for
    // parity with AGENTS: DIM count subtitle via
    // `caps_subtitle_style`, `M of N` when the filter narrows,
    // pale-cyan `view: <mode>` chip, and a refresh chip in the
    // top-right corner (was missing entirely — the sole
    // data-fetching panel in the family without one).
    let view_label = app.cloud_agents_view.label();
    let view_chip = format!(" view: {view_label} ");
    let view_w = view_chip.chars().count() as u16;
    let refresh_text = crate::ui::refresh_glyph::chip_icon_only(app.config.ui.ascii_icons);
    let refresh_w = refresh_text.chars().count() as u16;
    let header_label = "CLOUD AGENTS";
    let filter_lc_hdr = app.cloud_agents_filter.to_ascii_lowercase();
    // Filtered count uses the same substring match the row loop
    // uses (workspace / session_id / state / flow); computed
    // twice (here + at the render loop) since re-borrowing across
    // the header/render split adds no real cost.
    let total = app.cloud_agents_rows.len();
    let visible = if filter_lc_hdr.is_empty() {
        total
    } else {
        app.cloud_agents_rows
            .iter()
            .filter(|r| {
                let m = app.cloud_agents_meta.get(&r.session_id);
                let mut parts: Vec<String> = vec![
                    r.workspace.to_ascii_lowercase(),
                    r.session_id.to_ascii_lowercase(),
                ];
                if let Some(m) = m {
                    parts.push(m.state.to_ascii_lowercase());
                    parts.push(m.flow.to_ascii_lowercase());
                }
                parts.iter().any(|p| p.contains(&filter_lc_hdr))
            })
            .count()
    };
    let count_txt = if filter_lc_hdr.is_empty() {
        format!("  ({total})")
    } else {
        format!("  ({visible} of {total})")
    };
    let count_w = count_txt.chars().count() as u16;
    let label_and_count = 1 + header_label.chars().count() as u16 + count_w;
    // 2026-09-03 design review — the drop order was BACKWARDS relative
    // to the four list panels, which drop their mode chip and keep the
    // refresh chip. Here `header_used` folded the `view:` chip into the
    // refresh budget, so narrowing dropped REFRESH and kept `view:`.
    // Two panels a rail apart answered "which chip survives?" with
    // opposite answers.
    //
    // Refresh wins everywhere: it is a functional button users reach
    // for by position, while the mode chip is informational and its
    // menu is reachable another way. The view chip now drops first,
    // and — as the refresh guard already did — it drops its RECT too,
    // so it cannot leak past the panel divider or leave a dead target.
    let show_view = area.width >= label_and_count + view_w + refresh_w + 2;
    let show_refresh = area.width >= label_and_count + refresh_w + 2;
    let header_used = label_and_count
        + if show_view { view_w } else { 0 }
        + if show_refresh { refresh_w } else { 0 }
        + 2;
    let pad_width = area.width.saturating_sub(header_used) as usize;
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                header_label,
                crate::ui::panel_chrome::caps_label_style(&t, bg),
            ),
            Span::styled(
                count_txt.clone(),
                crate::ui::panel_chrome::caps_subtitle_style(&t, bg),
            ),
            Span::styled(" ".repeat(pad_width), Style::default().bg(bg)),
            // Match the AGENTS view chip: dark-fg on pale-cyan bg.
            Span::styled(
                if show_view { view_chip } else { String::new() },
                Style::default()
                    .fg(t.bg)
                    .bg(t.cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                if show_view && show_refresh { " " } else { "" }.to_string(),
                Style::default().bg(bg),
            ),
            Span::styled(
                if show_refresh {
                    refresh_text.to_string()
                } else {
                    String::new()
                },
                Style::default().fg(t.cyan).bg(bg),
            ),
        ])),
        header_row,
    );
    let view_chip_x = area.x + 1 + header_label.chars().count() as u16 + count_w + pad_width as u16;
    if show_view {
        app.rects.cloud_agents_view_chip = Some(Rect {
            x: view_chip_x,
            y: header_row.y,
            width: view_w,
            height: 1,
        });
    }
    if show_refresh {
        app.rects.cloud_agents_refresh_chip = Some(Rect {
            x: view_chip_x + if show_view { view_w + 1 } else { 0 },
            y: header_row.y,
            width: refresh_w,
            height: 1,
        });
    }
    y += 1;

    // Filter input — same shape as the local panel for muscle memory.
    if y < area.y + area.height {
        let focused = app.cloud_agents_filter_focused;
        let bg_chip = crate::ui::panel_chrome::filter_chip_bg(&t);
        let fg_chip = if app.cloud_agents_filter.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        // 2026-08-24 (user ask) — normalize to the shared
        // `filter_placeholder::for_state` used by every other
        // activity-bar filter. The field-specific hint (ticket /
        // runId / state) now lives in the filter chip's
        // hover-help copy — see `info_view_copy` for
        // `HoverChip::CloudAgentsFilter`. Prior in-line hint
        // read as an outlier next to the plain `type to filter…`
        // used elsewhere.
        let display = if app.cloud_agents_filter.is_empty() {
            crate::ui::filter_placeholder::for_state(focused).to_string()
        } else {
            app.cloud_agents_filter.clone()
        };
        let cursor = if focused { "▏" } else { " " };
        let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                format!("{} ", crate::ui::search_glyph::NERD),
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
            if focused {
                "type a prompt + Enter to fire…".to_string()
            } else {
                "/ prompt".to_string()
            }
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
                Span::styled(
                    format!(" {} ", crate::ui::search_glyph::NERD),
                    Style::default().fg(t.cyan).bg(bg_in),
                ),
                Span::styled(placeholder, Style::default().fg(fg_in).bg(bg_in)),
                Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_in)),
                Span::styled(" ".repeat(pad), Style::default().bg(bg_in)),
                Span::styled(" ", Style::default().bg(bg)),
                // R16 (2026-08-24) — was `.fg(t.bg_dark)` which
                // `action_button`'s doc-comment records as an
                // already-fixed contrast bug against mid-brightness
                // fills. Route through `action_button::secondary`
                // for guaranteed pure-black label parity with
                // AGENTS' `+ from PR` chip.
                Span::styled(chip.to_string(), crate::ui::action_button::secondary(&t)),
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
        // First-run path — wizard CTA. User feedback 2026-08-23
        // (two rounds): the button's LEFT EDGE lines up 1 cell right
        // of where it started, and the button keeps its inner
        // padding — a bg-styled leading space before the `+` so the
        // chip reads like the "+ New session" / "+ from Palette"
        // pair on the local Sessions panel. Net: button at
        // `area.x + 1`, text still `" + New Cloud Run "` with the
        // leading pad space.
        // 2026-08-23 (#1200) — routed through `action_button::primary`
        // so the wizard CTA reads the same as every other panel's
        // main call-to-action (was solid cyan; now solid green).
        let label = "+ New Cloud Run";
        let bw = crate::ui::action_button::chip_width(label);
        let btn_rect = Rect {
            x: area.x + 1,
            y,
            width: bw,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(crate::ui::action_button::chip_line(
                label,
                crate::ui::action_button::primary(&t),
            )),
            btn_rect,
        );
        app.rects.cloud_agents_new_run_button = Some(btn_rect);
        y += 2;
    }

    // Cold-start placeholder.
    if app.agents_panel_built_at.is_none() && y < area.y + area.height {
        let label = if app.agents_panel_rx.is_some() {
            "Scanning ECS runner-runs…"
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
    let matches_filter =
        |r: &crate::claude_agents::AgentRow, m: Option<&crate::ecs_runner::EcsRunMeta>| -> bool {
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
    // R16 design-critic pass (2026-08-24) — filtered-to-zero
    // state. Without this branch the panel just paints nothing
    // (looks broken/loading) when the filter narrows a
    // non-empty list to zero matches. Route through
    // `empty_state::draw` so hint-row + fit() behavior matches
    // every other panel's filtered-empty state.
    if !filter_lc.is_empty() && action_needed.is_empty() && running.is_empty() && done.is_empty() {
        crate::ui::empty_state::draw(
            frame,
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: area.height.saturating_sub(y - area.y),
            },
            "No matches — Esc clears",
            None,
            bg,
            &t,
        );
        return;
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
                             m: Option<&crate::ecs_runner::EcsRunMeta>|
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
}
