//! Renderer for `Pane::SpendReport` — sortable per-workspace
//! breakdown of AI spend in the last 24h. Headers are clickable
//! (cycle sort key + flip desc). 2026-06-21.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::{Pane, SpendSortKey};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, id: PaneId, area: Rect, focused: bool) {
    let Some(Pane::SpendReport(p)) = app.panes.get(id) else {
        return;
    };
    let t = theme::cur();

    let border_style = if focused {
        Style::default().fg(t.blue)
    } else {
        Style::default().fg(t.bg3)
    };
    let arrow = if p.sort_desc { "↓" } else { "↑" };
    // 2026-06-29: spend_today runs on a background thread now.
    // Show a "computing…" badge in the title while it's pending
    // so the user sees the pane isn't stale.
    let loading_chip = if p.loading { " · computing…" } else { "" };
    let header_text = format!(
        " AI spend (24h) · sort: {} {arrow}{loading_chip} · {} sessions · ${:.4} total · r refresh · s sort · esc back ",
        p.sort_by.label(),
        p.snapshot.claude_sessions + p.snapshot.codex_sessions,
        p.snapshot.total_cost_usd,
    );
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(header_text);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 30 || inner.height < 4 {
        return;
    }

    // Register the body for wheel routing.
    app.rects.editor_panes.push((inner, id));

    // Column widths: workspace stretches; tokens + cost are fixed.
    let cost_w: u16 = 12;
    let tokens_w: u16 = 14;
    let pad = 2u16;
    let workspace_w = inner.width.saturating_sub(cost_w + tokens_w + pad * 3);

    // Header row + click rects per column.
    let header_y = inner.y;
    let workspace_x = inner.x;
    let tokens_x = workspace_x + workspace_w + pad;
    let cost_x = tokens_x + tokens_w + pad;

    let header_color = |k: SpendSortKey| -> Style {
        if k == p.sort_by {
            Style::default()
                .fg(t.yellow)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED)
        } else {
            Style::default().fg(t.comment).add_modifier(Modifier::BOLD)
        }
    };
    let workspace_arrow = if p.sort_by == SpendSortKey::Workspace {
        format!(" {arrow}")
    } else {
        String::new()
    };
    let tokens_arrow = if p.sort_by == SpendSortKey::Tokens {
        format!(" {arrow}")
    } else {
        String::new()
    };
    let cost_arrow = if p.sort_by == SpendSortKey::Cost {
        format!(" {arrow}")
    } else {
        String::new()
    };
    let header_line = Line::from(vec![
        Span::styled(
            format!(
                "{:<w$}",
                format!("workspace{workspace_arrow}"),
                w = workspace_w as usize
            ),
            header_color(SpendSortKey::Workspace),
        ),
        Span::raw(" ".repeat(pad as usize)),
        Span::styled(
            format!(
                "{:>w$}",
                format!("tokens{tokens_arrow}"),
                w = tokens_w as usize
            ),
            header_color(SpendSortKey::Tokens),
        ),
        Span::raw(" ".repeat(pad as usize)),
        Span::styled(
            format!("{:>w$}", format!("cost{cost_arrow}"), w = cost_w as usize),
            header_color(SpendSortKey::Cost),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(vec![header_line]),
        Rect {
            x: inner.x,
            y: header_y,
            width: inner.width,
            height: 1,
        },
    );
    // Click rects per header for sort-cycle.
    app.rects.spend_headers.push((
        Rect {
            x: workspace_x,
            y: header_y,
            width: workspace_w,
            height: 1,
        },
        id,
        SpendSortKey::Workspace,
    ));
    app.rects.spend_headers.push((
        Rect {
            x: tokens_x,
            y: header_y,
            width: tokens_w,
            height: 1,
        },
        id,
        SpendSortKey::Tokens,
    ));
    app.rects.spend_headers.push((
        Rect {
            x: cost_x,
            y: header_y,
            width: cost_w,
            height: 1,
        },
        id,
        SpendSortKey::Cost,
    ));

    // Data rows.
    let rows = p.sorted_rows();
    let body_y = header_y + 1;
    let body_h = inner.height.saturating_sub(1);
    if rows.is_empty() {
        let empty = Line::from(Span::styled(
            "  no sessions in window (last 24h)",
            Style::default().fg(t.comment),
        ));
        frame.render_widget(
            Paragraph::new(vec![empty]),
            Rect {
                x: inner.x,
                y: body_y,
                width: inner.width,
                height: 1,
            },
        );
        return;
    }
    let scroll = p
        .scroll
        .min(rows.len().saturating_sub(body_h.max(1) as usize));
    let take = (body_h as usize).min(rows.len().saturating_sub(scroll));
    let mut lines: Vec<Line> = Vec::with_capacity(take);
    for (rel_i, (ws, tokens, cost)) in rows.iter().skip(scroll).take(take).enumerate() {
        let abs_i = scroll + rel_i;
        let sel = abs_i == p.selected;
        let row_style = if sel {
            Style::default()
                .fg(t.bg_dark)
                .bg(t.yellow)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg)
        };
        let tok_str = format_tokens(*tokens);
        let cost_str = format!("${cost:.4}");
        lines.push(Line::from(vec![
            Span::styled(
                format!(
                    "{:<w$}",
                    clip(ws, workspace_w as usize),
                    w = workspace_w as usize
                ),
                row_style,
            ),
            Span::raw(" ".repeat(pad as usize)),
            Span::styled(format!("{:>w$}", tok_str, w = tokens_w as usize), row_style),
            Span::raw(" ".repeat(pad as usize)),
            Span::styled(format!("{:>w$}", cost_str, w = cost_w as usize), row_style),
        ]));
        // Register row click rect.
        app.rects.list_rows.push((
            Rect {
                x: inner.x,
                y: body_y + rel_i as u16,
                width: inner.width,
                height: 1,
            },
            id,
            abs_i,
        ));
    }
    frame.render_widget(
        Paragraph::new(lines),
        Rect {
            x: inner.x,
            y: body_y,
            width: inner.width,
            height: body_h,
        },
    );
}

fn clip(s: &str, w: usize) -> String {
    if s.chars().count() <= w {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(w.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

fn format_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}
