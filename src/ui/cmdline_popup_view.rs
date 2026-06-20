//! Floating completion popup for the `:` cmdline. Sits directly
//! above the cmdline bar, growing upward over the editor pane
//! content. Auto-shows on type so users discover completions
//! without knowing the Tab chord.
//!
//! Behavior:
//!  - Renders when cmdline is open AND there are ≥2 matches for the
//!    current token. Single match → no popup (the line itself is
//!    the only candidate; Tab still works to complete it).
//!  - Shows up to MAX_VISIBLE rows; if there are more matches, the
//!    last row hints `(N more — Tab to cycle)`.
//!  - Selected row highlights with bg3 + bold. Cycled by Tab / Down /
//!    Up; mouse-click on a row sets selected + writes match into
//!    cmdline.
//!  - Layout: width = max(label_len) + 4 (padding + border), capped
//!    at 60. Height = visible_rows + 2 (top + bottom border).
//!    x-anchor: same as cmdline.x. y-anchor: cmdline.y - height.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

const MAX_VISIBLE: usize = 8;
const MAX_WIDTH: u16 = 60;

pub fn draw(frame: &mut Frame, app: &mut App, cmdline_bar: Rect) {
    // Always clear the previous frame's rect registrations — the
    // popup is render-time-computed, no stale state survives.
    app.rects.cmdline_popup_items.clear();

    if cmdline_bar.width == 0 || cmdline_bar.y < 1 {
        return;
    }

    // Two paths can host an active `:` cmdline:
    //   1. App.no_pane_cmdline — Ctrl+; from tree / empty-state.
    //      Stored as raw text (no `:` prefix, no caret marker).
    //   2. The active editor's input handler `cmdline_get` — the
    //      vim `:` cmdline that the user just typed.
    // Check (1) first to mirror `pending_display`'s precedence.
    let line: String = if let Some(text) = app.no_pane_cmdline.clone() {
        text
    } else if let Some(text) = app
        .active_editor()
        .and_then(|b| b.input.cmdline_get())
    {
        text
    } else {
        return;
    };
    if line.trim().is_empty() {
        return;
    }

    // Compute matches fresh each frame. Cheap — N=~150 commands,
    // O(N) prefix filter.
    let Some(state) = crate::app::compute_cmdline_completions_for_app(app, &line) else {
        return;
    };
    if state.matches.len() < 2 {
        return;
    }

    let total = state.matches.len();
    let visible = total.min(MAX_VISIBLE);
    let label_w = state
        .matches
        .iter()
        .take(visible)
        .map(|m| m.chars().count() as u16)
        .max()
        .unwrap_or(0);
    let inner_w = label_w.max(20).min(MAX_WIDTH - 2);
    let box_w = (inner_w + 2).min(cmdline_bar.width);
    // +2 for top + bottom border; +1 if we need the "(N more)" row.
    let extra_row = if total > visible { 1 } else { 0 };
    let box_h = (visible as u16) + 2 + extra_row;
    // Anchor: float UPward from cmdline. y = cmdline.y - box_h.
    // If that goes negative (small terminal), clamp to row 0.
    let box_y = cmdline_bar.y.saturating_sub(box_h);
    let box_x = cmdline_bar.x;
    let area = Rect {
        x: box_x,
        y: box_y,
        width: box_w,
        height: box_h,
    };

    let t = theme::cur();
    // 2026-06-19 — earlier bg/border colors matched the editor
    // pane background too closely, making the popup invisible
    // against the splash screen. Now uses bg_darker (one step
    // darker than bg_dark, the editor pane bg) and a yellow
    // border (matching the cmdline_bar's yellow `:foo▏` text)
    // so the popup visually clusters with the cmdline.
    let block_style = Style::default().fg(t.fg).bg(t.bg_darker);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        )
        .style(block_style);
    // Clear underlying cells then paint the bordered box.
    frame.render_widget(Clear, area);
    frame.render_widget(block, area);

    let inner = Rect {
        x: area.x + 1,
        y: area.y + 1,
        width: area.width.saturating_sub(2),
        height: area.height.saturating_sub(2),
    };

    // Clamp selected to current match count.
    let selected = app.cmdline_popup_selected.min(total - 1);
    // Window the visible slice around the selected row so it stays
    // on screen as the user cycles past MAX_VISIBLE matches.
    let start = if selected < visible {
        0
    } else {
        selected + 1 - visible
    };
    let end = (start + visible).min(total);
    for (offset, idx) in (start..end).enumerate() {
        let match_text = &state.matches[idx];
        let is_sel = idx == selected;
        let style = if is_sel {
            Style::default()
                .fg(t.fg)
                .bg(t.bg3)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg_darker)
        };
        let marker = if is_sel { "▸ " } else { "  " };
        // Truncate to inner width.
        let text = format!("{marker}{match_text}");
        let truncated: String = text
            .chars()
            .take(inner.width as usize)
            .collect();
        let row_y = inner.y + offset as u16;
        let row_rect = Rect {
            x: inner.x,
            y: row_y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(truncated, style)))
                .style(Style::default().bg(t.bg_darker)),
            row_rect,
        );
        app.rects.cmdline_popup_items.push((row_rect, idx));
    }

    // "(N more — Tab to cycle)" hint row if truncated.
    if extra_row == 1 {
        let hint = format!("  ({} more — Tab to cycle)", total - visible);
        let truncated: String = hint
            .chars()
            .take(inner.width as usize)
            .collect();
        let row_y = inner.y + visible as u16;
        let row_rect = Rect {
            x: inner.x,
            y: row_y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                truncated,
                Style::default().fg(t.bg3).bg(t.bg_darker),
            )))
            .style(Style::default().bg(t.bg_darker)),
            row_rect,
        );
    }
}
