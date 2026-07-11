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
    // claude-agents-power-user 2026-06-28 finding 3: filter-mode
    // also halts live tail (p.paused = true) but the chip only
    // checked paused_by_user. A user typing a query for several
    // seconds had no indication tail was suspended. Check both.
    let pause_chip = if p.paused_by_user {
        " · paused"
    } else if p.paused {
        " · paused (filter)"
    } else {
        ""
    };
    let state_chip = match p.state_filter {
        Some(AgentState::Streaming) => " · ●live",
        Some(AgentState::ToolCall) => " · ▸tool",
        Some(AgentState::Idle) => " · ○idle",
        Some(AgentState::Ended) => " · ·ended",
        None => "",
    };
    let source_chip = match p.source_filter {
        Some(AgentSource::Claude) => " · ✦claude",
        Some(AgentSource::Codex) => " · ◈codex",
        Some(AgentSource::Ecs) => " · ☁ecs",
        Some(AgentSource::AnthropicManaged) => " · ☁managed",
        None => "",
    };
    let ws_chip = if p.workspace_only { " · this-ws" } else { "" };
    // #25 v4 — age-window chip. Shown on ALL views (filter mode
    // too, since narrowing by age is meaningful during search).
    let age_label = p.age_filter.label();
    let age_chip = if !matches!(p.age_filter, crate::claude_agents::AgeFilter::Week) {
        format!(" · {age_label}")
    } else {
        String::new()
    };
    let count_chip = if p.any_filter_active() {
        format!(" · {}/{}", p.visible_indices().len(), p.rows.len())
    } else {
        String::new()
    };
    let multi = if p.multi_selected.is_empty() {
        String::new()
    } else {
        format!(" · ☑ {}", p.multi_selected.len())
    };
    let group_label = p.group_by.label();
    let header_text = if p.filter_mode {
        // claude-agents-power-user 3rd 2026-06-29 SEV-3: filter-mode
        // sets p.paused=true, but the format here didn't show the
        // `· paused (filter)` chip — so the live-tail-suspended
        // signal was invisible exactly when it was relevant.
        format!(
            " Claude Agents · /{}{pause_chip} · enter applies · esc clears ",
            p.query
        )
    } else if !p.query.is_empty() {
        // 2026-06-21 design-critic + claude-agents SEV-3: when a
        // text filter is active, the header used to drop sort /
        // source / ws / multi-select chips. The chips matter MORE
        // during filter (the user is narrowing — knowing what other
        // filters are stacked is the point). Now they all stay.
        format!(
            " Claude Agents · filter: {}{state_chip}{source_chip}{ws_chip}{age_chip}{pause_chip}{multi}{count_chip} · sort:{} · group:{} · / edit · ? help ",
            p.query,
            p.sort_by.label(),
            group_label,
        )
    } else {
        format!(
            " Claude Agents{source_chip}{state_chip}{ws_chip}{age_chip}{pause_chip}{multi}{count_chip} · sort:{} · group:{} · j/k gg G · / · W ws · > src · s sort · ^G grp · ? help ",
            p.sort_by.label(),
            group_label,
        )
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
    // Register the pane's body so the global wheel dispatcher
    // routes ScrollUp/ScrollDown events to this pane's
    // move_up/move_down (see ClaudeAgents arm in dispatch.rs).
    app.rects.editor_panes.push((inner, id));

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

    draw_topbar(frame, &agg, topbar_area, &t, p, id, &mut app.rects);

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
            "  no Claude sessions found under ~/.claude/projects/ in the last 7 days".to_string()
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

    // Build the full line set first, then slice by scroll so the
    // selected row is always visible. `row_line_positions[vi]` is
    // the line index of row vi within the full set.
    let mut all_lines: Vec<Line> = Vec::new();
    let mut row_line_positions: std::collections::HashMap<usize, usize> =
        std::collections::HashMap::new();
    all_lines.push(column_header(rows_area.width, &t));
    for (key, indices) in &groups {
        let tokens: u64 = indices.iter().map(|&i| p.rows[vis[i]].tokens).sum();
        let cost: f64 = indices.iter().map(|&i| p.rows[vis[i]].cost_usd).sum();
        all_lines.push(section_header_keyed(
            key,
            indices.len(),
            tokens,
            cost,
            rows_area.width,
            &t,
        ));
        for &vi in indices {
            let row_idx = vis[vi];
            let marked = p.multi_selected.contains(&p.rows[row_idx].session_id);
            row_line_positions.insert(vi, all_lines.len());
            all_lines.push(render_row(
                &p.rows[row_idx],
                vi == p.selected,
                marked,
                &t,
                rows_area.width,
            ));
        }
    }
    let body_h = rows_area.height as usize;
    let sel_line = row_line_positions.get(&p.selected).copied().unwrap_or(0);
    // Auto-scroll: keep the selected row visible. Snaps cursor-row
    // to bottom of viewport when it would otherwise be cut off,
    // and to top when scrolling back up past the viewport.
    let scroll = if sel_line >= body_h {
        sel_line + 1 - body_h
    } else {
        0
    };
    let visible_lines: Vec<Line> = all_lines
        .iter()
        .skip(scroll)
        .take(body_h)
        .cloned()
        .collect();
    let rows_para = Paragraph::new(visible_lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(rows_para, rows_area);

    // Push rects for click selection. Accounts for the auto-scroll
    // so the y coordinate is the actual on-screen row.
    for (vi, &line_idx) in row_line_positions.iter() {
        if line_idx < scroll || line_idx >= scroll + body_h {
            continue;
        }
        let screen_y = rows_area.y.saturating_add((line_idx - scroll) as u16);
        app.rects.list_rows.push((
            Rect {
                x: rows_area.x,
                y: screen_y,
                width: rows_area.width,
                height: 1,
            },
            id,
            *vi,
        ));
    }
    // Visual scrollbar — a `▎` glyph at the right edge of the
    // rows area showing the visible window vs total height.
    if all_lines.len() > body_h && rows_area.width > 1 {
        let total = all_lines.len();
        let bar_h = ((body_h as f64 / total as f64) * body_h as f64).max(1.0) as usize;
        let bar_top = ((scroll as f64 / total as f64) * body_h as f64) as usize;
        for i in 0..body_h {
            let in_bar = i >= bar_top && i < bar_top + bar_h;
            let glyph = if in_bar { "▎" } else { " " };
            let style = if in_bar {
                Style::default().fg(t.cyan).bg(t.bg_dark)
            } else {
                Style::default().bg(t.bg_dark)
            };
            let area = Rect {
                x: rows_area.x + rows_area.width - 1,
                y: rows_area.y + i as u16,
                width: 1,
                height: 1,
            };
            frame.render_widget(Paragraph::new(Line::from(Span::styled(glyph, style))), area);
        }
    }

    if let Some(sel) = p.selected_row() {
        let file_clicks = draw_detail(frame, sel, p.detail, p.detail_scroll, detail_area, &t);
        for (rect, path) in file_clicks {
            app.rects.claude_drill_files.push((rect, path));
        }
    }
}

fn draw_topbar(
    frame: &mut Frame,
    agg: &crate::claude_agents::Aggregate,
    area: Rect,
    t: &theme::Theme,
    p: &crate::claude_agents::ClaudeAgentsPane,
    pane_id: PaneId,
    rects: &mut crate::app::PaneRects,
) {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let bg = t.bg_dark;
    let label_style = Style::default().fg(t.comment).bg(bg);

    spans.push(Span::styled(" ", label_style));
    spans.push(Span::styled(
        format!("● {} live  ", agg.streaming),
        Style::default()
            .fg(t.green)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    if agg.tool_calls > 0 {
        spans.push(Span::styled(
            format!("▸ {} tool  ", agg.tool_calls),
            Style::default()
                .fg(t.yellow)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
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
        format!("Σ {} tokens  ", format_tokens(agg.total_tokens)),
        Style::default().fg(t.yellow).bg(bg),
    ));
    if agg.total_cost_usd > 0.0 {
        spans.push(Span::styled(
            format!("≈ {}  ", format_cost(agg.total_cost_usd)),
            Style::default()
                .fg(t.orange)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    if agg.pending_confirms > 0 {
        spans.push(Span::styled(
            format!("⚠ {} pending tool  ", agg.pending_confirms),
            Style::default()
                .fg(t.red)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    // Track byte offsets of clickable chips so we can register
    // rects on the second pass. Use string-length math for cell
    // widths (works because chip labels are ASCII / single-cell).
    let chip_style = Style::default().fg(t.purple).bg(bg);

    // 2026-06-21 vscode-mouse SEV-2: make the topbar chips real
    // click targets. Each chip is a clickable rect (cycle on click)
    // — `[view]` cycles drill view (was `v` chord), `[sort]`
    // cycles sort (was `s`), `[grp]` cycles group_by (was Ctrl+G),
    // `[src]` cycles source filter (was `>`), `[ws]` toggles
    // workspace-only (was `W`).
    let view_label = format!("[view: {}] ", p.detail.label());
    let sort_label = format!("[sort: {}] ", p.sort_by.label());
    let grp_label = format!("[grp: {}] ", p.group_by.label());
    let src_label = format!(
        "[src: {}] ",
        match p.source_filter {
            None => "all".to_string(),
            Some(crate::claude_agents::AgentSource::Claude) => "claude".to_string(),
            Some(crate::claude_agents::AgentSource::Codex) => "codex".to_string(),
            Some(crate::claude_agents::AgentSource::Ecs) => "ecs".to_string(),
            Some(crate::claude_agents::AgentSource::AnthropicManaged) => "managed".to_string(),
        }
    );
    let ws_label = if p.workspace_only {
        "[ws: this-ws] ".to_string()
    } else {
        "[ws: all] ".to_string()
    };

    // Cumulative cell-width so far (sum of chars in pushed spans).
    let mut cell_off: u16 = spans.iter().map(|s| s.content.chars().count() as u16).sum();
    let mut register = |kind: super::TopbarChipKind, label: &str, off: &mut u16| {
        let w = label.chars().count() as u16;
        let x = area.x.saturating_add(*off);
        rects.claude_agents_topbar_chips.push((
            Rect {
                x,
                y: area.y,
                width: w,
                height: 1,
            },
            pane_id,
            kind,
        ));
        *off = off.saturating_add(w);
    };

    spans.push(Span::styled(view_label.clone(), chip_style));
    register(super::TopbarChipKind::View, &view_label, &mut cell_off);

    spans.push(Span::styled(sort_label.clone(), chip_style));
    register(super::TopbarChipKind::Sort, &sort_label, &mut cell_off);

    spans.push(Span::styled(grp_label.clone(), chip_style));
    register(super::TopbarChipKind::Group, &grp_label, &mut cell_off);

    spans.push(Span::styled(src_label.clone(), chip_style));
    register(super::TopbarChipKind::Source, &src_label, &mut cell_off);

    spans.push(Span::styled(ws_label.clone(), chip_style));
    register(super::TopbarChipKind::Workspace, &ws_label, &mut cell_off);

    let topbar = Line::from(spans);
    let divider = Line::from(Span::styled(
        " ".repeat(area.width as usize),
        Style::default().bg(t.bg2),
    ));
    frame.render_widget(
        Paragraph::new(vec![topbar, divider]).style(Style::default().bg(bg)),
        area,
    );
}

/// Section identity — what the group header represents.
#[derive(Debug, Clone)]
enum SectionKey {
    Source(AgentSource),
    Workspace(String),
}

fn build_groups(mode: GroupBy, vis: &[usize], rows: &[AgentRow]) -> Vec<(SectionKey, Vec<usize>)> {
    use std::collections::BTreeMap;
    match mode {
        GroupBy::Source => {
            let mut claude: Vec<usize> = Vec::new();
            let mut codex: Vec<usize> = Vec::new();
            let mut ecs: Vec<usize> = Vec::new();
            let mut managed: Vec<usize> = Vec::new();
            for (vi, &row_idx) in vis.iter().enumerate() {
                match rows[row_idx].source {
                    AgentSource::Claude => claude.push(vi),
                    AgentSource::Codex => codex.push(vi),
                    AgentSource::Ecs => ecs.push(vi),
                    AgentSource::AnthropicManaged => managed.push(vi),
                }
            }
            let mut out = Vec::new();
            if !claude.is_empty() {
                out.push((SectionKey::Source(AgentSource::Claude), claude));
            }
            if !codex.is_empty() {
                out.push((SectionKey::Source(AgentSource::Codex), codex));
            }
            if !ecs.is_empty() {
                out.push((SectionKey::Source(AgentSource::Ecs), ecs));
            }
            if !managed.is_empty() {
                out.push((SectionKey::Source(AgentSource::AnthropicManaged), managed));
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

/// Header row above the rows list — labels each column so the
/// dense per-row layout is decodable at a glance.
fn column_header(width: u16, t: &theme::Theme) -> Line<'static> {
    let style = Style::default()
        .fg(t.comment)
        .bg(t.bg_dark)
        .add_modifier(Modifier::DIM);
    let header = format!(
        "    {state:<10}  {ws:<14}  {sid:<8}  {model:<14}  {age:<6}  {tok:>6}  {rate:>7}  {cost:>7}  {pid:>6}",
        state = "state",
        ws = "workspace",
        sid = "session",
        model = "model",
        age = "age",
        tok = "tokens",
        rate = "tok/min",
        cost = "cost",
        pid = "pid",
    );
    let pad = (width as usize).saturating_sub(header.chars().count());
    Line::from(vec![
        Span::styled(header, style),
        Span::styled(" ".repeat(pad), Style::default().bg(t.bg_dark)),
    ])
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
        SectionKey::Source(AgentSource::Ecs) => ("ECS runner (cloud)".to_string(), t.blue, "☁"),
        SectionKey::Source(AgentSource::AnthropicManaged) => {
            ("Managed Agents".to_string(), t.cyan, "☁")
        }
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
    let mark_style = Style::default()
        .fg(t.cyan)
        .bg(bg)
        .add_modifier(Modifier::BOLD);
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
        AgentSource::Ecs => ("☁", t.blue),
        AgentSource::AnthropicManaged => ("☁", t.cyan),
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
        .map(age_label)
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
        let done = row.todos.iter().filter(|t| t.status == "completed").count();
        format!("  ☑ {done}/{}", row.todos.len())
    };

    let pending = if row.pending_tool_uses > 0 {
        format!(" ⚠{}", row.pending_tool_uses)
    } else {
        String::new()
    };

    let row_chars = state.chars().count()
        + workspace_pad.chars().count()
        + 8
        + model_pad.chars().count()
        + age.chars().count()
        + tokens.chars().count()
        + rate.chars().count()
        + cost.chars().count()
        + pid.chars().count()
        + pending.chars().count()
        + todos_chip.chars().count()
        + 24;
    let pad = (width as usize).saturating_sub(row_chars + 4);

    Line::from(vec![
        Span::styled(
            multi_glyph.to_string(),
            Style::default()
                .fg(t.green)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" {source_glyph}"),
            Style::default()
                .fg(source_color)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(mark.to_string(), mark_style),
        Span::styled(
            state,
            Style::default()
                .fg(state_color)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  {workspace_pad}"),
            Style::default().fg(t.fg).bg(bg),
        ),
        Span::styled(format!("  {sid}"), Style::default().fg(t.comment).bg(bg)),
        Span::styled(
            format!("  {model_pad}"),
            Style::default().fg(source_color).bg(bg),
        ),
        Span::styled(format!("  {:<6}", age), Style::default().fg(t.cyan).bg(bg)),
        Span::styled(
            format!("  {:>6}", tokens),
            Style::default().fg(t.yellow).bg(bg),
        ),
        Span::styled(
            format!("  {:>7}", rate),
            Style::default().fg(t.green).bg(bg),
        ),
        Span::styled(
            format!("  {:>7}", cost),
            Style::default().fg(t.orange).bg(bg),
        ),
        Span::styled(
            format!("  {:>6}", pid),
            Style::default().fg(t.comment).bg(bg),
        ),
        Span::styled(
            pending,
            Style::default()
                .fg(t.red)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(todos_chip, Style::default().fg(t.green).bg(bg)),
        Span::styled(" ".repeat(pad), Style::default().bg(bg)),
    ])
}

fn draw_detail(
    frame: &mut Frame,
    row: &AgentRow,
    view: DetailView,
    scroll: usize,
    area: Rect,
    t: &theme::Theme,
) -> Vec<(Rect, String)> {
    let mut lines: Vec<Line> = Vec::new();
    let mut file_clicks: Vec<(Rect, String)> = Vec::new();
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
                    Span::styled(
                        clip(u, (area.width as usize).saturating_sub(10)),
                        value_style,
                    ),
                ]));
            }
            if let Some(a) = &row.last_assistant_msg {
                lines.push(Line::from(vec![
                    Span::styled("  asst: ", Style::default().fg(t.purple).bg(t.bg_dark)),
                    Span::styled(
                        clip(a, (area.width as usize).saturating_sub(10)),
                        value_style,
                    ),
                ]));
            }
            lines.push(Line::from(Span::styled(
                format!(
                    "  {} events parsed in tail  ·  pid {}",
                    row.event_count,
                    row.pid
                        .map(|p| format!("{p}"))
                        .unwrap_or_else(|| "—".to_string())
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
                // 2026-06-21 claude-agents SEV-2 file-click-offset-wrong —
                // the renderer (further down) clamps scroll to
                // `actual_scroll = scroll.min(max_scroll)` so over-
                // scroll doesn't drop visible rows; the click rects
                // were computed against the raw `scroll`, so when
                // detail_scroll > max_scroll the rects pointed at
                // rows that weren't there. Compute the same clamp
                // here so click rects match what's rendered.
                let max_scroll = row.recent_files.len().saturating_sub(1);
                let actual_scroll = scroll.min(max_scroll);
                let scroll = actual_scroll; // shadow for the loop below
                for (i, f) in row.recent_files.iter().enumerate() {
                    let short = std::path::Path::new(&f.path)
                        .components()
                        .rev()
                        .take(2)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .map(|c| c.as_os_str().to_string_lossy().into_owned())
                        .collect::<Vec<_>>()
                        .join("/");
                    lines.push(Line::from(vec![
                        Span::styled(
                            format!("  {} ", f.tool),
                            Style::default().fg(t.purple).bg(t.bg_dark),
                        ),
                        Span::styled(
                            short,
                            Style::default()
                                .fg(t.cyan)
                                .bg(t.bg_dark)
                                .add_modifier(Modifier::UNDERLINED),
                        ),
                    ]));
                    // y_offset within area: 0 = session header,
                    // 1 = divider, 2..N = content. detail_scroll
                    // shifts the content rows up.
                    if i >= scroll {
                        let y_offset = 2u16 + (i - scroll) as u16;
                        if y_offset < area.height {
                            file_clicks.push((
                                Rect {
                                    x: area.x,
                                    y: area.y + y_offset,
                                    width: area.width,
                                    height: 1,
                                },
                                f.path.clone(),
                            ));
                        }
                    }
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
                        Span::styled("  $ ", Style::default().fg(t.green).bg(t.bg_dark)),
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

    // Apply detail_scroll only to the content lines (header +
    // divider = first 2 lines, always kept on top).
    let visible_lines: Vec<Line> = if scroll > 0 && lines.len() > 2 {
        let mut keep: Vec<Line> = lines.iter().take(2).cloned().collect();
        let content_len = lines.len() - 2;
        let max_scroll = content_len.saturating_sub(1);
        let actual_scroll = scroll.min(max_scroll);
        keep.extend(lines.into_iter().skip(2 + actual_scroll));
        keep
    } else {
        lines
    };
    let para = Paragraph::new(visible_lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(para, area);
    file_clicks
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
        "<$0.01".to_string()
    } else {
        "—".to_string()
    }
}

enum HelpEntry {
    Section(&'static str),
    Row(&'static str, &'static str),
}

const HELP_LINES: &[HelpEntry] = &[
    HelpEntry::Section("Navigation"),
    HelpEntry::Row("j / k or ↑/↓", "select row · mouse click also selects"),
    HelpEntry::Row("PgUp / PgDn", "page through rows (10 at a time)"),
    HelpEntry::Row("Shift+PgUp / Shift+PgDn", "scroll the drill-down panel"),
    HelpEntry::Row("Home / End", "first / last row"),
    HelpEntry::Section("Filters"),
    HelpEntry::Row("/", "filter by text (workspace · id · model · last msg)"),
    HelpEntry::Row(
        "0 / 1 / 2 / 3 / 4",
        "filter by state (all / live / tool / idle / ended)",
    ),
    HelpEntry::Row("> / <", "cycle source filter (all → claude → codex → all)"),
    HelpEntry::Row(
        "W",
        "toggle workspace-only filter (capital — bare w is vim word-motion)",
    ),
    HelpEntry::Row("Ctrl+L", "clear all filters at once"),
    HelpEntry::Section("Layout"),
    HelpEntry::Row("gg / G", "jump to top / bottom of list (vim canonical)"),
    HelpEntry::Row("Ctrl+G", "cycle grouping (by source ↔ by workspace)"),
    HelpEntry::Row("s", "cycle sort key (state → tokens↓ → cost↓ → recent → …)"),
    HelpEntry::Row(
        "v",
        "cycle drill-down view (Summary → Todos → Files → Bash → Agents)",
    ),
    HelpEntry::Row("r", "refresh now · p pause/resume the 3s auto-refresh"),
    HelpEntry::Section("Selection"),
    HelpEntry::Row("space", "toggle multi-select on the focused row"),
    HelpEntry::Row("R", "clear multi-select"),
    HelpEntry::Section("Clipboard / Open"),
    HelpEntry::Row("y / c", "yank session id / cwd to clipboard"),
    HelpEntry::Row("t / Enter / dbl-click", "open the transcript .jsonl"),
    HelpEntry::Row("(Files panel) click", "open the file in an editor pane"),
    HelpEntry::Section("Actions"),
    HelpEntry::Row("o", "resume the session in a new mnml pty pane"),
    HelpEntry::Row("K", "SIGTERM (escalates to SIGKILL after 2s)"),
    HelpEntry::Row("e", "export the selected transcript as markdown"),
    HelpEntry::Section("Palette commands"),
    HelpEntry::Row(":ai.session_search", "grep all transcripts"),
    HelpEntry::Row(":ai.spend_today", "today's tokens + cost by workspace"),
    HelpEntry::Section("Meta"),
    HelpEntry::Row("? / F1", "toggle this help (F1 works mid-filter)"),
    HelpEntry::Row("Esc / q", "focus tree / close the pane"),
];

pub fn help_overlay(t: &theme::Theme, width: u16) -> Vec<Line<'static>> {
    let mut lines: Vec<Line> = Vec::new();
    let bg = t.bg2;
    lines.push(Line::from(Span::styled(
        format!(
            " {:<width$}",
            " Claude Agents — help (? to close)",
            width = width as usize - 1
        ),
        Style::default()
            .fg(t.yellow)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    )));
    for entry in HELP_LINES {
        match entry {
            HelpEntry::Section(name) => {
                let txt = format!(" ── {name} ");
                let pad = (width as usize).saturating_sub(txt.chars().count());
                lines.push(Line::from(vec![
                    Span::styled(
                        txt,
                        Style::default()
                            .fg(t.cyan)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" ".repeat(pad), Style::default().bg(bg)),
                ]));
            }
            HelpEntry::Row(chord, desc) => {
                let txt = format!("   {chord:<24}  {desc}");
                let pad = (width as usize).saturating_sub(txt.chars().count());
                lines.push(Line::from(vec![
                    Span::styled(txt, Style::default().fg(t.fg).bg(bg)),
                    Span::styled(" ".repeat(pad), Style::default().bg(bg)),
                ]));
            }
        }
    }
    lines
}
