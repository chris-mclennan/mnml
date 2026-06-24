//! Workspace-picker dropdown — opens from the `▾` chevron next to the
//! workspace name in the rail header. Lists configured
//! `[[workspaces]]` entries, optionally grouped by their `group`
//! label (`"work"`, `"personal"`, …).
//!
//! Click a row → `App::switch_workspace(idx)`. Esc or click-outside
//! closes without switching. A filter input at the top narrows the
//! list by case-insensitive substring match against name + group.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App) {
    app.rects.workspace_picker_rows.clear();
    app.rects.workspace_picker_filter_input = None;
    if !app.workspace_picker_open {
        return;
    }
    let Some(chev_rect) = app.rects.workspace_picker_chevron else {
        return;
    };
    if app.config.workspaces.is_empty() {
        return;
    }
    let t = theme::cur();

    // Group workspaces by the optional `group` label, preserving
    // the user's config order within each group.
    let filter_lc = app.workspace_picker_filter.to_ascii_lowercase();
    let mut groups: Vec<(String, Vec<usize>)> = Vec::new();
    for (i, w) in app.config.workspaces.iter().enumerate() {
        let group = w.group.clone().unwrap_or_default();
        // Filter check — match on name OR group.
        let name_lc = w.name.to_ascii_lowercase();
        let group_lc = group.to_ascii_lowercase();
        if !filter_lc.is_empty()
            && !name_lc.contains(&filter_lc)
            && !group_lc.contains(&filter_lc)
        {
            continue;
        }
        if let Some(slot) = groups.iter_mut().find(|(g, _)| g == &group) {
            slot.1.push(i);
        } else {
            groups.push((group, vec![i]));
        }
    }
    if groups.is_empty() {
        return;
    }

    // Compute panel dimensions: width = max(workspace_name) + 4
    // padding; height = filter input + group headers + rows + 2
    // borders.
    let max_label = app
        .config
        .workspaces
        .iter()
        .map(|w| w.name.chars().count())
        .max()
        .unwrap_or(20);
    let w = (max_label as u16 + 4).max(28);
    let body_rows: u16 = groups
        .iter()
        .map(|(g, rows)| if g.is_empty() { rows.len() } else { 1 + rows.len() } as u16)
        .sum::<u16>();
    let h = body_rows + 4; // borders(2) + filter(1) + 1 spacer
    let screen_w = frame.area().width;
    let screen_h = frame.area().height;
    let x = chev_rect.x.min(screen_w.saturating_sub(w));
    let y = (chev_rect.y + 1).min(screen_h.saturating_sub(h));
    let area = Rect {
        x,
        y,
        width: w.min(screen_w),
        height: h.min(screen_h),
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let mut y = inner.y;

    // ── filter input ──────────────────────────────────────────
    if y < inner.y + inner.height {
        let display = if app.workspace_picker_filter.is_empty() {
            "Filter workspaces…".to_string()
        } else {
            app.workspace_picker_filter.clone()
        };
        let fg = if app.workspace_picker_filter.is_empty() {
            t.comment
        } else {
            t.fg
        };
        let cursor = "▏";
        let pad =
            (inner.width as usize).saturating_sub(display.chars().count() + 1 + 1);
        let line = Line::from(vec![
            Span::styled(
                "\u{F0349} ",
                Style::default().fg(t.comment).bg(t.bg2),
            ),
            Span::styled(display, Style::default().fg(fg).bg(t.bg2)),
            Span::styled(cursor, Style::default().fg(t.cyan).bg(t.bg2)),
            Span::styled(" ".repeat(pad), Style::default().bg(t.bg2)),
        ]);
        let row = Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(line), row);
        app.rects.workspace_picker_filter_input = Some(row);
        y += 1;
    }
    // Spacer between filter and groups.
    if y < inner.y + inner.height {
        y += 1;
    }

    for (group, rows) in &groups {
        if y >= inner.y + inner.height {
            break;
        }
        if !group.is_empty() {
            let header_line = Line::from(vec![
                Span::styled(
                    format!(" {group} "),
                    Style::default()
                        .fg(t.comment)
                        .bg(t.bg2)
                        .add_modifier(Modifier::BOLD),
                ),
            ]);
            frame.render_widget(
                Paragraph::new(header_line),
                Rect {
                    x: inner.x,
                    y,
                    width: inner.width,
                    height: 1,
                },
            );
            y += 1;
        }
        for &i in rows {
            if y >= inner.y + inner.height {
                break;
            }
            let w_cfg = &app.config.workspaces[i];
            // 0 is the primary workspace; configured rows in
            // `[[workspaces]]` map to indices 1+ in
            // `App::switch_workspace`.
            let ws_idx = i + 1;
            let line = Line::from(vec![
                Span::styled("  ", Style::default().bg(t.bg2)),
                Span::styled(
                    w_cfg.name.clone(),
                    Style::default().fg(t.fg).bg(t.bg2),
                ),
            ]);
            let row = Rect {
                x: inner.x,
                y,
                width: inner.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(line), row);
            app.rects.workspace_picker_rows.push((row, ws_idx));
            y += 1;
        }
    }
}
