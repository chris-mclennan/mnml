//! Claude Code agents dashboard renderer. One row per session
//! discovered by `claude_agents::ClaudeAgentsPane::build`. The
//! drill-down panel at the bottom shows the selected row's last
//! user/assistant exchange, model, cwd, and full session id.

use ratatui::Frame;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::claude_agents::{AgentRow, AgentState};
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

    let live = p
        .rows
        .iter()
        .filter(|r| matches!(r.state, AgentState::Streaming | AgentState::ToolCall))
        .count();
    let total = p.rows.len();
    let header = format!(
        " Claude Agents · {live} live / {total} total · j/k · r refresh · y yank id · t transcript · q close "
    );

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(header);

    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 30 || inner.height < 4 {
        return;
    }

    // Split inner: rows above, detail panel (4 rows fixed) below.
    let detail_h = inner.height.min(7).saturating_sub(3).max(3);
    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(3), Constraint::Length(detail_h)])
        .split(inner);
    let rows_area = split[0];
    let detail_area = split[1];

    if p.rows.is_empty() {
        let empty = Paragraph::new(Line::from(vec![Span::styled(
            "  no Claude sessions found under ~/.claude/projects/ in the last 7 days",
            Style::default().fg(t.comment),
        )]))
        .style(Style::default().bg(t.bg_dark));
        frame.render_widget(empty, rows_area);
        return;
    }

    let body_h = rows_area.height as usize;
    let scroll = p.scroll.min(p.rows.len().saturating_sub(body_h.max(1)));
    let lines: Vec<Line> = p
        .rows
        .iter()
        .enumerate()
        .skip(scroll)
        .take(body_h)
        .map(|(i, row)| render_row(row, i == p.selected, &t, rows_area.width))
        .collect();

    let rows_para = Paragraph::new(lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(rows_para, rows_area);

    // Detail panel: header bar + last user/assistant exchange.
    if let Some(sel) = p.rows.get(p.selected) {
        draw_detail(frame, sel, detail_area, &t);
    }
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
    let state = format!("{:<8}", row.state.badge());

    let workspace = if row.workspace.is_empty() {
        "?".to_string()
    } else {
        row.workspace.clone()
    };
    let sid = row
        .session_id
        .chars()
        .take(8)
        .collect::<String>();
    let model = row
        .model
        .as_deref()
        .map(|m| {
            // Trim "claude-" prefix for compactness.
            m.strip_prefix("claude-").unwrap_or(m).to_string()
        })
        .unwrap_or_else(|| "?".to_string());
    let age = row
        .last_activity
        .map(|t| age_label(t))
        .unwrap_or_else(|| "?".to_string());
    let tokens = format_tokens(row.tokens);
    let pid = row
        .pid
        .map(|p| format!("#{p}"))
        .unwrap_or_else(|| "—".to_string());

    let row_text = format!(
        "{state}  {workspace:<14}  {sid}  {model:<14}  {age:<6}  {tokens:>6}  {pid:>6}"
    );
    // Pad to width.
    let pad = (width as usize).saturating_sub(row_text.chars().count() + 2);

    Line::from(vec![
        Span::styled(mark.to_string(), mark_style),
        Span::styled(
            state,
            Style::default().fg(state_color).bg(bg).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("  {workspace:<14}"), Style::default().fg(t.fg).bg(bg)),
        Span::styled(format!("  {sid}"), Style::default().fg(t.comment).bg(bg)),
        Span::styled(format!("  {model:<14}"), Style::default().fg(t.purple).bg(bg)),
        Span::styled(format!("  {age:<6}"), Style::default().fg(t.cyan).bg(bg)),
        Span::styled(format!("  {tokens:>6}"), Style::default().fg(t.yellow).bg(bg)),
        Span::styled(format!("  {pid:>6}"), Style::default().fg(t.comment).bg(bg)),
        Span::styled(" ".repeat(pad), Style::default().bg(bg)),
    ])
}

fn draw_detail(frame: &mut Frame, row: &AgentRow, area: Rect, t: &theme::Theme) {
    let mut lines: Vec<Line> = Vec::new();
    let label_style = Style::default().fg(t.comment).bg(t.bg_dark);
    let value_style = Style::default().fg(t.fg).bg(t.bg_dark);

    let mut header = vec![
        Span::styled("  session: ", label_style),
        Span::styled(row.session_id.clone(), value_style),
    ];
    if let Some(b) = &row.git_branch {
        header.push(Span::styled("   git: ", label_style));
        header.push(Span::styled(b.clone(), Style::default().fg(t.green).bg(t.bg_dark)));
    }
    if let Some(cwd) = &row.cwd {
        header.push(Span::styled("   cwd: ", label_style));
        header.push(Span::styled(cwd.clone(), value_style));
    }
    lines.push(Line::from(header));

    if let Some(u) = &row.last_user_msg {
        lines.push(Line::from(vec![
            Span::styled("  user: ", Style::default().fg(t.cyan).bg(t.bg_dark)),
            Span::styled(truncate_for_width(u, area.width), value_style),
        ]));
    }
    if let Some(a) = &row.last_assistant_msg {
        lines.push(Line::from(vec![
            Span::styled("  asst: ", Style::default().fg(t.purple).bg(t.bg_dark)),
            Span::styled(truncate_for_width(a, area.width), value_style),
        ]));
    }
    lines.push(Line::from(vec![Span::styled(
        format!(
            "  {} events parsed in tail · path {}",
            row.event_count,
            row.transcript_path.display()
        ),
        Style::default().fg(t.comment).bg(t.bg_dark),
    )]));

    let para = Paragraph::new(lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(para, area);
}

fn truncate_for_width(s: &str, width: u16) -> String {
    let max = (width as usize).saturating_sub(8);
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
