//! Claude Code agents dashboard renderer. Top-bar aggregate +
//! filterable row list + per-row drill-down panel.

use ratatui::Frame;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::claude_agents::{AgentRow, AgentSource, AgentState, DetailView};
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
    let header_text = if p.filter_mode {
        format!(" Claude Agents · /{} · enter applies · esc clears ", p.query)
    } else if !p.query.is_empty() {
        format!(
            " Claude Agents · filter: {} · / to edit · v cycles view · r refresh ",
            p.query
        )
    } else {
        " Claude Agents · j/k · / filter · v view · r refresh · y id · c cwd · K kill · o resume ".to_string()
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

    // Group visible rows by source so we can drop a section header
    // between Claude and Codex blocks. Row indices remain stable so
    // `selected` still refers to a real visible row.
    let mut claude_indices: Vec<usize> = Vec::new();
    let mut codex_indices: Vec<usize> = Vec::new();
    for (vi, &row_idx) in vis.iter().enumerate() {
        match p.rows[row_idx].source {
            AgentSource::Claude => claude_indices.push(vi),
            AgentSource::Codex => codex_indices.push(vi),
        }
    }

    let mut lines: Vec<Line> = Vec::new();
    let claude_section_tokens: u64 = claude_indices.iter().map(|&i| p.rows[vis[i]].tokens).sum();
    let codex_section_tokens: u64 = codex_indices.iter().map(|&i| p.rows[vis[i]].tokens).sum();
    if !claude_indices.is_empty() {
        lines.push(section_header(
            AgentSource::Claude,
            claude_indices.len(),
            claude_section_tokens,
            rows_area.width,
            &t,
        ));
        for &vi in &claude_indices {
            let row_idx = vis[vi];
            lines.push(render_row(&p.rows[row_idx], vi == p.selected, &t, rows_area.width));
        }
    }
    if !codex_indices.is_empty() {
        lines.push(section_header(
            AgentSource::Codex,
            codex_indices.len(),
            codex_section_tokens,
            rows_area.width,
            &t,
        ));
        for &vi in &codex_indices {
            let row_idx = vis[vi];
            lines.push(render_row(&p.rows[row_idx], vi == p.selected, &t, rows_area.width));
        }
    }
    let _scroll = p.scroll; // section-aware scroll is v2
    let rows_para = Paragraph::new(lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(rows_para, rows_area);

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

fn section_header(
    source: AgentSource,
    count: usize,
    tokens: u64,
    width: u16,
    t: &theme::Theme,
) -> Line<'static> {
    let (label, accent, glyph) = match source {
        AgentSource::Claude => ("Claude Code", t.purple, "✦"),
        AgentSource::Codex => ("Codex (OpenAI)", t.teal, "◈"),
    };
    let header = format!(" {glyph}  {label}   {count} session(s)   {} tokens ", format_tokens(tokens));
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

fn render_row(row: &AgentRow, selected: bool, t: &theme::Theme, width: u16) -> Line<'static> {
    let bg = if selected { t.bg2 } else { t.bg_dark };
    let mark = if selected { "▸ " } else { "  " };
    let mark_style = Style::default().fg(t.cyan).bg(bg).add_modifier(Modifier::BOLD);

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
    let pid = row
        .pid
        .map(|p| format!("#{p}"))
        .unwrap_or_else(|| "—".to_string());

    let pending = if row.pending_tool_uses > 0 {
        format!(" ⚠{}", row.pending_tool_uses)
    } else {
        String::new()
    };

    let row_chars =
        state.chars().count() + workspace_pad.chars().count() + 8 + model_pad.chars().count()
            + age.chars().count() + tokens.chars().count() + pid.chars().count() + pending.chars().count() + 18;
    let pad = (width as usize).saturating_sub(row_chars + 2);

    Line::from(vec![
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
        Span::styled(format!("  {:>6}", pid), Style::default().fg(t.comment).bg(bg)),
        Span::styled(pending, Style::default().fg(t.red).bg(bg).add_modifier(Modifier::BOLD)),
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
