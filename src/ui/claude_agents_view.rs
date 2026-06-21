//! Claude Code agents dashboard renderer. Top-bar aggregate +
//! filterable row list + per-row drill-down panel.

use ratatui::Frame;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::claude_agents::{AgentRow, AgentSource, AgentState, DetailView, GroupBy};
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, id: PaneId, area: Rect, focused: bool) {
    let Some(Pane::ClaudeAgents(p)) = app.panes.get(id) else {
        return;
    };
    let t = theme::cur();
    let border_style = if focused {
        Style::default().fg(t.blue)
    } else {
        Style::default().fg(t.bg3)
    };

    let agg = p.aggregate();
    let pause_chip = if p.paused_by_user { " · paused" } else { "" };
    let state_chip = match p.state_filter {
        Some(AgentState::Streaming) => " · ●live",
        Some(AgentState::ToolCall) => " · ▸tool",
        Some(AgentState::Idle) => " · ○idle",
        Some(AgentState::Ended) => " · ·ended",
        None => "",
    };
    let header_text = if p.filter_mode {
        format!(" Claude Agents · /{} · enter applies · esc clears ", p.query)
    } else if !p.query.is_empty() {
        format!(
            " Claude Agents · filter: {}{state_chip}{pause_chip} · / edit · ? help ",
            p.query
        )
    } else {
        let group = p.group_by.label();
        let multi = if p.multi_selected.is_empty() {
            String::new()
        } else {
            format!(" · ☑ {}", p.multi_selected.len())
        };
        format!(" Claude Agents{state_chip}{pause_chip}{multi} · j/k · / filter · ? help · v view · g {group} · space mark ")
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(header_text);

    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 30 || inner.height < 6 {
        return;
    }

    // Vertical layout: top-bar (2), rows (flex), detail (6).
    let topbar_h = 2u16;
    let detail_h = (inner.height / 3).clamp(6, 14);
    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(topbar_h),
            Constraint::Min(3),
            Constraint::Length(detail_h),
        ])
        .split(inner);
    let topbar_area = split[0];
    let rows_area = split[1];
    let detail_area = split[2];

    draw_topbar(frame, &agg, topbar_area, &t, p.detail);

    // Help overlay replaces the row + detail area while shown.
    if p.show_help {
        let help_lines = help_overlay(&t, inner.width);
        let help_area = Rect::new(
            inner.x,
            rows_area.y,
            inner.width,
            rows_area.height + detail_area.height,
        );
        frame.render_widget(
            Paragraph::new(help_lines).style(Style::default().bg(t.bg2)),
            help_area,
        );
        return;
    }

    let vis = p.visible_indices();
    if vis.is_empty() {
        let empty_text = if p.query.is_empty() {
            "  no Claude sessions found under ~/.claude/projects/ in the last 7 days"
                .to_string()
        } else {
            format!("  no sessions match {:?}", p.query)
        };
        let empty = Paragraph::new(Line::from(vec![Span::styled(
            empty_text,
            Style::default().fg(t.comment),
        )]))
        .style(Style::default().bg(t.bg_dark));
        frame.render_widget(empty, rows_area);
        return;
    }

    // Group visible rows by the configured grouping mode (source or
    // workspace). Each group gets a colored section header.
    let groups: Vec<(SectionKey, Vec<usize>)> = build_groups(p.group_by, &vis, &p.rows);

    let mut lines: Vec<Line> = Vec::new();
    // Track each rendered row's y-offset within rows_area + its
    // `selected` index so the click handler can map (x,y) → vi.
    let mut row_y_to_vi: Vec<(u16, usize)> = Vec::new();
    for (key, indices) in &groups {
        let tokens: u64 = indices.iter().map(|&i| p.rows[vis[i]].tokens).sum();
        let cost: f64 = indices.iter().map(|&i| p.rows[vis[i]].cost_usd).sum();
        lines.push(section_header_keyed(
            key,
            indices.len(),
            tokens,
            cost,
            rows_area.width,
            &t,
        ));
        for &vi in indices {
            let row_idx = vis[vi];
            let marked = p
                .multi_selected
                .contains(&p.rows[row_idx].session_id);
            row_y_to_vi.push((lines.len() as u16, vi));
            lines.push(render_row(
                &p.rows[row_idx],
                vi == p.selected,
                marked,
                &t,
                rows_area.width,
            ));
        }
    }
    let _scroll = p.scroll;
    let rows_para = Paragraph::new(lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(rows_para, rows_area);

    // Push rects for click selection. The dispatcher in tui.rs
    // looks up by (pane_id, vi) to call p.selected = vi.
    for (y_in_area, vi) in row_y_to_vi {
        let screen_y = rows_area.y.saturating_add(y_in_area);
        if screen_y >= rows_area.y.saturating_add(rows_area.height) {
            continue;
        }
        app.rects.list_rows.push((
            Rect {
                x: rows_area.x,
                y: screen_y,
                width: rows_area.width,
                height: 1,
            },
            id,
            vi,
        ));
    }

    if let Some(sel) = p.selected_row() {
        draw_detail(frame, sel, p.detail, detail_area, &t);
    }
}

fn draw_topbar(frame: &mut Frame, agg: &crate::claude_agents::Aggregate, area: Rect, t: &theme::Theme, detail: DetailView) {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let bg = t.bg_dark;
    let label_style = Style::default().fg(t.comment).bg(bg);

    spans.push(Span::styled(" ", label_style));
    spans.push(Span::styled(
        format!("● {} live  ", agg.streaming),
        Style::default().fg(t.green).bg(bg).add_modifier(Modifier::BOLD),
    ));
    if agg.tool_calls > 0 {
        spans.push(Span::styled(
            format!("▸ {} tool  ", agg.tool_calls),
            Style::default().fg(t.yellow).bg(bg).add_modifier(Modifier::BOLD),
        ));
    }
    spans.push(Span::styled(
        format!("○ {} idle  ", agg.idle),
        Style::default().fg(t.cyan).bg(bg),
    ));
    spans.push(Span::styled(
        format!("· {} ended  ", agg.ended),
        Style::default().fg(t.comment).bg(bg),
    ));
    spans.push(Span::styled(
        format!(
            "Σ {} tokens  ",
            format_tokens(agg.total_tokens)
        ),
        Style::default().fg(t.yellow).bg(bg),
    ));
    if agg.total_cost_usd > 0.0 {
        spans.push(Span::styled(
            format!("≈ {}  ", format_cost(agg.total_cost_usd)),
            Style::default().fg(t.orange).bg(bg).add_modifier(Modifier::BOLD),
        ));
    }
    if agg.pending_confirms > 0 {
        spans.push(Span::styled(
            format!("⚠ {} pending tool  ", agg.pending_confirms),
            Style::default().fg(t.red).bg(bg).add_modifier(Modifier::BOLD),
        ));
    }
    spans.push(Span::styled(
        format!("[view: {}] ", detail.label()),
        Style::default().fg(t.purple).bg(bg),
    ));
    let topbar = Line::from(spans);
    let divider = Line::from(Span::styled(
        " ".repeat(area.width as usize),
        Style::default().bg(t.bg2),
    ));
    frame.render_widget(Paragraph::new(vec![topbar, divider]).style(Style::default().bg(bg)), area);
}

/// Section identity — what the group header represents.
#[derive(Debug, Clone)]
enum SectionKey {
    Source(AgentSource),
    Workspace(String),
}

fn build_groups(
    mode: GroupBy,
    vis: &[usize],
    rows: &[AgentRow],
) -> Vec<(SectionKey, Vec<usize>)> {
    use std::collections::BTreeMap;
    match mode {
        GroupBy::Source => {
            let mut claude: Vec<usize> = Vec::new();
            let mut codex: Vec<usize> = Vec::new();
            for (vi, &row_idx) in vis.iter().enumerate() {
                match rows[row_idx].source {
                    AgentSource::Claude => claude.push(vi),
                    AgentSource::Codex => codex.push(vi),
                }
            }
            let mut out = Vec::new();
            if !claude.is_empty() {
                out.push((SectionKey::Source(AgentSource::Claude), claude));
            }
            if !codex.is_empty() {
                out.push((SectionKey::Source(AgentSource::Codex), codex));
            }
            out
        }
        GroupBy::Workspace => {
            let mut buckets: BTreeMap<String, Vec<usize>> = BTreeMap::new();
            for (vi, &row_idx) in vis.iter().enumerate() {
                let ws = rows[row_idx].workspace.clone();
                buckets.entry(ws).or_default().push(vi);
            }
            buckets
                .into_iter()
                .map(|(k, v)| (SectionKey::Workspace(k), v))
                .collect()
        }
    }
}

fn section_header_keyed(
    key: &SectionKey,
    count: usize,
    tokens: u64,
    cost: f64,
    width: u16,
    t: &theme::Theme,
) -> Line<'static> {
    let (label, accent, glyph) = match key {
        SectionKey::Source(AgentSource::Claude) => ("Claude Code".to_string(), t.purple, "✦"),
        SectionKey::Source(AgentSource::Codex) => ("Codex (OpenAI)".to_string(), t.teal, "◈"),
        SectionKey::Workspace(w) => (format!("workspace · {w}"), t.cyan, "▎"),
    };
    let cost_chip = if cost > 0.0 {
        format!("  {}", format_cost(cost))
    } else {
        String::new()
    };
    let header = format!(
        " {glyph}  {label}   {count} session(s)   {} tokens{cost_chip} ",
        format_tokens(tokens)
    );
    let pad = (width as usize).saturating_sub(header.chars().count());
    Line::from(vec![
        Span::styled(
            header,
            Style::default()
                .fg(t.bg_dark)
                .bg(accent)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ".repeat(pad), Style::default().bg(accent)),
    ])
}

fn render_row(
    row: &AgentRow,
    selected: bool,
    multi_marked: bool,
    t: &theme::Theme,
    width: u16,
) -> Line<'static> {
    let bg = if selected { t.bg2 } else { t.bg_dark };
    let mark = if selected { "▸ " } else { "  " };
    let mark_style = Style::default().fg(t.cyan).bg(bg).add_modifier(Modifier::BOLD);
    let multi_glyph = if multi_marked { "☑" } else { " " };

    let state_color = match row.state {
        AgentState::Streaming => t.green,
        AgentState::ToolCall => t.yellow,
        AgentState::Idle => t.cyan,
        AgentState::Ended => t.comment,
    };
    let badge = row.state_badge();
    let state = format!("{:<10}", badge);

    let (source_glyph, source_color) = match row.source {
        AgentSource::Claude => ("✦", t.purple),
        AgentSource::Codex => ("◈", t.teal),
    };

    let workspace_pad: String = format!("{:<14}", clip(&row.workspace, 14));
    let sid: String = row.session_id.chars().take(8).collect();
    let model = row
        .model
        .as_deref()
        .map(|m| m.strip_prefix("claude-").unwrap_or(m).to_string())
        .unwrap_or_else(|| row.source.label().to_string());
    let model_pad = format!("{:<14}", clip(&model, 14));
    let age = row
        .last_activity
        .map(|t| age_label(t))
        .unwrap_or_else(|| "?".to_string());
    let tokens = format_tokens(row.tokens);
    let cost = format_cost(row.cost_usd);
    let pid = row
        .pid
        .map(|p| format!("#{p}"))
        .unwrap_or_else(|| "—".to_string());
    // tok/min for live sessions; blank for idle/ended.
    let rate = row
        .tokens_per_min
        .map(|r| {
            if r >= 1_000.0 {
                format!("{:.1}k/m", r / 1_000.0)
            } else {
                format!("{:.0}/m", r)
            }
        })
        .unwrap_or_default();
    // TodoList progress, when the session has one.
    let todos_chip = if row.todos.is_empty() {
        String::new()
    } else {
        let done = row
            .todos
            .iter()
            .filter(|t| t.status == "completed")
            .count();
        format!("  ☑ {done}/{}", row.todos.len())
    };

    let pending = if row.pending_tool_uses > 0 {
        format!(" ⚠{}", row.pending_tool_uses)
    } else {
        String::new()
    };

    let row_chars =
        state.chars().count() + workspace_pad.chars().count() + 8 + model_pad.chars().count()
            + age.chars().count() + tokens.chars().count() + rate.chars().count() + cost.chars().count()
            + pid.chars().count() + pending.chars().count() + todos_chip.chars().count() + 24;
    let pad = (width as usize).saturating_sub(row_chars + 4);

    Line::from(vec![
        Span::styled(
            multi_glyph.to_string(),
            Style::default().fg(t.green).bg(bg).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" {source_glyph}"),
            Style::default().fg(source_color).bg(bg).add_modifier(Modifier::BOLD),
        ),
        Span::styled(mark.to_string(), mark_style),
        Span::styled(
            state,
            Style::default().fg(state_color).bg(bg).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("  {workspace_pad}"), Style::default().fg(t.fg).bg(bg)),
        Span::styled(format!("  {sid}"), Style::default().fg(t.comment).bg(bg)),
        Span::styled(format!("  {model_pad}"), Style::default().fg(source_color).bg(bg)),
        Span::styled(format!("  {:<6}", age), Style::default().fg(t.cyan).bg(bg)),
        Span::styled(format!("  {:>6}", tokens), Style::default().fg(t.yellow).bg(bg)),
        Span::styled(format!("  {:>7}", rate), Style::default().fg(t.green).bg(bg)),
        Span::styled(format!("  {:>7}", cost), Style::default().fg(t.orange).bg(bg)),
        Span::styled(format!("  {:>6}", pid), Style::default().fg(t.comment).bg(bg)),
        Span::styled(pending, Style::default().fg(t.red).bg(bg).add_modifier(Modifier::BOLD)),
        Span::styled(todos_chip, Style::default().fg(t.green).bg(bg)),
        Span::styled(" ".repeat(pad), Style::default().bg(bg)),
    ])
}

fn draw_detail(
    frame: &mut Frame,
    row: &AgentRow,
    view: DetailView,
    area: Rect,
    t: &theme::Theme,
) {
    let mut lines: Vec<Line> = Vec::new();
    let label_style = Style::default().fg(t.comment).bg(t.bg_dark);
    let value_style = Style::default().fg(t.fg).bg(t.bg_dark);

    let mut header = vec![
        Span::styled("  session: ", label_style),
        Span::styled(row.session_id.clone(), value_style),
    ];
    if let Some(b) = &row.git_branch {
        header.push(Span::styled("   git: ", label_style));
        header.push(Span::styled(
            b.clone(),
            Style::default().fg(t.green).bg(t.bg_dark),
        ));
    }
    if let Some(cwd) = &row.cwd {
        header.push(Span::styled("   cwd: ", label_style));
        header.push(Span::styled(
            clip(cwd, (area.width as usize).saturating_sub(40)),
            value_style,
        ));
    }
    lines.push(Line::from(header));
    lines.push(Line::from(Span::styled(
        " ".repeat(area.width as usize),
        Style::default().bg(t.bg2),
    )));

    match view {
        DetailView::Summary => {
            if let Some(u) = &row.last_user_msg {
                lines.push(Line::from(vec![
                    Span::styled("  user: ", Style::default().fg(t.cyan).bg(t.bg_dark)),
                    Span::styled(clip(u, (area.width as usize).saturating_sub(10)), value_style),
                ]));
            }
            if let Some(a) = &row.last_assistant_msg {
                lines.push(Line::from(vec![
                    Span::styled("  asst: ", Style::default().fg(t.purple).bg(t.bg_dark)),
                    Span::styled(clip(a, (area.width as usize).saturating_sub(10)), value_style),
                ]));
            }
            lines.push(Line::from(Span::styled(
                format!(
                    "  {} events parsed in tail  ·  pid {}",
                    row.event_count,
                    row.pid.map(|p| format!("{p}")).unwrap_or_else(|| "—".to_string())
                ),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        }
        DetailView::Todos => {
            if row.todos.is_empty() {
                lines.push(Line::from(Span::styled(
                    "  no todos recorded in tail",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            } else {
                for td in &row.todos {
                    let (glyph, glyph_color) = match td.status.as_str() {
                        "completed" => ("✓", t.green),
                        "in_progress" => ("▸", t.yellow),
                        _ => ("○", t.comment),
                    };
                    lines.push(Line::from(vec![
                        Span::styled(
                            format!("  {glyph} "),
                            Style::default().fg(glyph_color).bg(t.bg_dark),
                        ),
                        Span::styled(
                            clip(&td.content, (area.width as usize).saturating_sub(6)),
                            value_style,
                        ),
                    ]));
                }
            }
        }
        DetailView::Files => {
            if row.recent_files.is_empty() {
                lines.push(Line::from(Span::styled(
                    "  no Edit/Write in tail",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            } else {
                for f in &row.recent_files {
                    lines.push(Line::from(Span::styled(
                        format!("  {f}"),
                        value_style,
                    )));
                }
            }
        }
        DetailView::Bash => {
            if row.recent_bash.is_empty() {
                lines.push(Line::from(Span::styled(
                    "  no Bash invocations in tail",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            } else {
                for b in &row.recent_bash {
                    lines.push(Line::from(vec![
                        Span::styled(
                            "  $ ",
                            Style::default().fg(t.green).bg(t.bg_dark),
                        ),
                        Span::styled(
                            clip(b, (area.width as usize).saturating_sub(6)),
                            value_style,
                        ),
                    ]));
                }
            }
        }
        DetailView::Subagents => {
            if row.recent_subagents.is_empty() {
                lines.push(Line::from(Span::styled(
                    "  no Agent dispatches in tail",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            } else {
                for a in &row.recent_subagents {
                    lines.push(Line::from(vec![
                        Span::styled("  ⚡ ", Style::default().fg(t.purple).bg(t.bg_dark)),
                        Span::styled(
                            clip(a, (area.width as usize).saturating_sub(6)),
                            value_style,
                        ),
                    ]));
                }
            }
        }
    }

    let para = Paragraph::new(lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(para, area);
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let cut: String = s.chars().take(max.saturating_sub(1)).collect();
        format!("{cut}…")
    }
}

fn age_label(t: std::time::SystemTime) -> String {
    let now = std::time::SystemTime::now();
    let Ok(d) = now.duration_since(t) else {
        return "now".to_string();
    };
    let s = d.as_secs();
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m", s / 60)
    } else if s < 24 * 3600 {
        format!("{}h", s / 3600)
    } else {
        format!("{}d", s / (24 * 3600))
    }
}

fn format_tokens(n: u64) -> String {
    if n < 1_000 {
        n.to_string()
    } else if n < 1_000_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    }
}

fn format_cost(usd: f64) -> String {
    if usd >= 1.0 {
        format!("${usd:.2}")
    } else if usd >= 0.01 {
        format!("${usd:.3}")
    } else if usd > 0.0 {
        format!("<$0.01")
    } else {
        "—".to_string()
    }
}

const HELP_LINES: &[(&str, &str)] = &[
    ("j / k or ↑/↓", "select row · mouse click also selects"),
    ("/", "filter by text (workspace · id · model · last msg)"),
    ("0 / 1 / 2 / 3 / 4", "filter by state (all / live / tool / idle / ended)"),
    ("g", "cycle grouping (by source ↔ by workspace)"),
    ("space", "toggle multi-select on the focused row"),
    ("v", "cycle drill-down view (Summary → Todos → Files → Bash → Agents)"),
    ("r", "refresh now"),
    ("p", "pause/resume the 3s auto-refresh"),
    ("y", "yank session id to clipboard"),
    ("c", "yank cwd to clipboard"),
    ("t / Enter", "open the transcript .jsonl in an editor (or dbl-click)"),
    ("o", "resume the session in a new pty (claude --resume / fresh codex)"),
    ("K", "SIGTERM (batch when rows are multi-selected; confirm prompt)"),
    ("?", "toggle this help"),
    ("Esc", "focus file tree"),
    ("q", "close the pane"),
];

pub fn help_overlay(t: &theme::Theme, width: u16) -> Vec<Line<'static>> {
    let mut lines: Vec<Line> = Vec::new();
    let bg = t.bg2;
    lines.push(Line::from(Span::styled(
        format!(" {:<width$}", " Claude Agents — help (? to close)", width = width as usize - 1),
        Style::default().fg(t.yellow).bg(bg).add_modifier(Modifier::BOLD),
    )));
    for (chord, desc) in HELP_LINES {
        let txt = format!(" {chord:<22}  {desc}");
        let pad = (width as usize).saturating_sub(txt.chars().count());
        lines.push(Line::from(vec![
            Span::styled(txt, Style::default().fg(t.fg).bg(bg)),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]));
    }
    lines
}
