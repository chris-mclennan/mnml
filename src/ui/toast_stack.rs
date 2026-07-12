//! Stacked toasts + progress overlay — paints, bottom-up from
//! the statusline:
//!
//!   1. `App.toast_stack` (ephemeral, TTL-expiring) — closest to
//!      statusline, newest first.
//!   2. `App.persistent_toasts` (pinned until dismiss) — above.
//!   3. `App.progress_items` (active work, animated spinner) —
//!      topmost. These represent the most demanding attention:
//!      something is actively happening.
//!
//! Level-driven border color per `ToastLevel`: info + warn use the
//! standard comment color (calm); error uses red so failures stand
//! out. Progress items use a cyan border (distinct from toasts) so
//! the eye can separate "something's happening" from "here's a
//! notification."

use std::time::Duration;

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::{App, PendingUndo, ProgressItem, ProgressStatus, ToastEntry, ToastLevel};
use crate::ui::theme;

const MAX_WIDTH: u16 = 50;
const RIGHT_MARGIN: u16 = 1;
const BOTTOM_MARGIN: u16 = 2; // 1 statusline + 1 spacer
const FADE_TAIL: Duration = Duration::from_millis(800);
/// Max visible toasts. Beyond this we render a `+K more…` collapse
/// chip in place of the oldest visible slot. Bounded so a burst of
/// activity doesn't paint the whole pane column with toasts (issue #13).
const MAX_VISIBLE_TOASTS: usize = 5;

/// Braille-cycle spinner frames. Standard 8-phase pattern; each
/// frame is one Nerd-Font-safe grapheme.
const SPINNER_FRAMES: [&str; 8] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];
/// How long one spinner frame stays on screen before advancing.
const SPINNER_FRAME_MS: u128 = 100;

pub fn draw(frame: &mut Frame, app: &mut App) {
    let has_persistent = !app.persistent_toasts.is_empty();
    let has_stack = app.toast_stack.len() > 1;
    let has_progress = !app.progress_items.is_empty();
    let has_undo = app.pending_undo.is_some();
    if !has_persistent && !has_stack && !has_progress && !has_undo {
        return;
    }
    let area = frame.area();
    if area.width < 20 || area.height < 6 {
        return;
    }
    let t = theme::cur();
    let max_x_right = area.x + area.width.saturating_sub(RIGHT_MARGIN);
    let mut y_bottom = area.y + area.height.saturating_sub(BOTTOM_MARGIN);

    // #20 — pending undo chip sits closest to the statusline
    // (right below the toast stack). Painted first so it's the
    // most visible affordance right after the destructive action.
    app.rects.pending_undo_chip = None;
    if let Some(u) = app.pending_undo.clone()
        && let Some(chip_rect) = draw_undo_chip(frame, &u, &mut y_bottom, max_x_right, area, &t)
    {
        app.rects.pending_undo_chip = Some(chip_rect);
    }

    // Ephemeral toasts (newest first — closest to statusline).
    // Cap the visible count; if there are more than MAX_VISIBLE_TOASTS,
    // reserve the last visible slot for a "+K more…" chip so we never
    // fully hide the older ones from the user's awareness.
    let total = app.toast_stack.len();
    let show_more_chip = total > MAX_VISIBLE_TOASTS;
    let visible_take = if show_more_chip {
        MAX_VISIBLE_TOASTS.saturating_sub(1)
    } else {
        MAX_VISIBLE_TOASTS
    };
    for entry in app.toast_stack.iter().take(visible_take) {
        if !draw_toast_box(frame, entry, &mut y_bottom, max_x_right, area, &t) {
            break;
        }
    }
    if show_more_chip {
        let hidden = total.saturating_sub(visible_take);
        draw_more_chip(frame, hidden, &mut y_bottom, max_x_right, area, &t);
    }
    // Persistent toasts (above the ephemeral stack).
    for entry in app.persistent_toasts.iter().rev() {
        if !draw_toast_box(frame, entry, &mut y_bottom, max_x_right, area, &t) {
            break;
        }
    }
    // Progress items (topmost — active work).
    for item in app.progress_items.iter().rev() {
        if !draw_progress_box(frame, item, &mut y_bottom, max_x_right, area, &t) {
            break;
        }
    }
}

/// Draw one toast box just above `y_bottom`; updates `y_bottom`
/// to the new top edge. Returns false when out of vertical space.
fn draw_toast_box(
    frame: &mut Frame,
    entry: &ToastEntry,
    y_bottom: &mut u16,
    max_x_right: u16,
    area: Rect,
    t: &crate::ui::theme::Theme,
) -> bool {
    let text: String = entry.text.chars().take(MAX_WIDTH as usize - 4).collect();
    let inner_w = text.chars().count() as u16 + 2;
    let box_w = (inner_w + 2)
        .min(MAX_WIDTH)
        .min(area.width.saturating_sub(2));
    let box_h: u16 = 3;
    if *y_bottom < area.y + box_h {
        return false;
    }
    let y = *y_bottom - box_h;
    let x = max_x_right.saturating_sub(box_w);
    let rect = Rect {
        x,
        y,
        width: box_w,
        height: box_h,
    };
    let is_persistent = entry.persistent_id.is_some();
    let age = entry.created_at.elapsed();
    let fading = !is_persistent && age + FADE_TAIL >= Duration::from_secs(4);
    let border_fg = match entry.level {
        ToastLevel::Error => t.red,
        ToastLevel::Warn | ToastLevel::Info if fading => t.bg3,
        _ => t.comment,
    };
    frame.render_widget(Clear, rect);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(border_fg).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    let line = Line::from(vec![
        Span::raw(" "),
        Span::styled(
            text,
            Style::default()
                .fg(t.fg)
                .bg(t.bg_darker)
                .add_modifier(if fading {
                    Modifier::DIM
                } else {
                    Modifier::empty()
                }),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(t.bg_darker)),
        inner,
    );
    *y_bottom = y;
    true
}

/// "+K more toasts…" collapse chip drawn above the visible stack
/// when there are more toasts than [`MAX_VISIBLE_TOASTS`]. Same
/// dimensions as a toast so the visual pattern is consistent.
fn draw_more_chip(
    frame: &mut Frame,
    hidden: usize,
    y_bottom: &mut u16,
    max_x_right: u16,
    area: Rect,
    t: &crate::ui::theme::Theme,
) {
    let text = format!("+{hidden} more…");
    let inner_w = text.chars().count() as u16 + 2;
    let box_w = (inner_w + 2)
        .min(MAX_WIDTH)
        .min(area.width.saturating_sub(2));
    let box_h: u16 = 3;
    if *y_bottom < area.y + box_h {
        return;
    }
    let y = *y_bottom - box_h;
    let x = max_x_right.saturating_sub(box_w);
    let rect = Rect {
        x,
        y,
        width: box_w,
        height: box_h,
    };
    frame.render_widget(Clear, rect);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(t.comment).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    let line = Line::from(vec![
        Span::raw(" "),
        Span::styled(
            text,
            Style::default()
                .fg(t.comment)
                .bg(t.bg_darker)
                .add_modifier(Modifier::DIM),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(t.bg_darker)),
        inner,
    );
    *y_bottom = y;
}

/// #20 — the undo chip. Anchored just above the statusline,
/// paints a compact box: `<label> · ↶ Undo`. Returns the click
/// rect so mouse routing can dispatch to `commit_pending_undo`.
fn draw_undo_chip(
    frame: &mut Frame,
    u: &PendingUndo,
    y_bottom: &mut u16,
    max_x_right: u16,
    area: Rect,
    t: &crate::ui::theme::Theme,
) -> Option<Rect> {
    let label: String = u.label.chars().take(MAX_WIDTH as usize - 20).collect();
    // keyboard-round-8 SEV-3 2026-07-11 — was "(⇧⌃Z)" which
    // implied a chord that doesn't fire the undo action. `u` is
    // the actual key that fires it (vim-mode); mouse users click
    // the chip. Neutral hint.
    let suffix = "  \u{21B6} Undo (click) ";
    let inner_text = format!(" {label}{suffix}");
    let inner_w = inner_text.chars().count() as u16;
    let box_w = (inner_w + 2)
        .min(MAX_WIDTH)
        .min(area.width.saturating_sub(2));
    let box_h: u16 = 3;
    if *y_bottom < area.y + box_h {
        return None;
    }
    let y = *y_bottom - box_h;
    let x = max_x_right.saturating_sub(box_w);
    let rect = Rect {
        x,
        y,
        width: box_w,
        height: box_h,
    };
    frame.render_widget(Clear, rect);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(t.cyan).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    let line = Line::from(vec![
        Span::styled(
            format!(" {label} "),
            Style::default().fg(t.fg).bg(t.bg_darker),
        ),
        Span::styled(
            "· \u{21B6} Undo ",
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            "(click) ",
            Style::default()
                .fg(t.comment)
                .bg(t.bg_darker)
                .add_modifier(Modifier::DIM),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(t.bg_darker)),
        inner,
    );
    *y_bottom = y;
    Some(rect)
}

/// Draw one progress item box just above `y_bottom`; updates
/// `y_bottom` to the new top edge. Returns false when out of
/// space. Spinner phase derives from wall-clock time via
/// `started_at.elapsed()`.
fn draw_progress_box(
    frame: &mut Frame,
    item: &ProgressItem,
    y_bottom: &mut u16,
    max_x_right: u16,
    area: Rect,
    t: &crate::ui::theme::Theme,
) -> bool {
    // Body: <glyph> <label> [<percent>%].
    let glyph: String = match item.finished {
        None => {
            let ms = item.started_at.elapsed().as_millis();
            let phase = (ms / SPINNER_FRAME_MS) as usize % SPINNER_FRAMES.len();
            SPINNER_FRAMES[phase].to_string()
        }
        Some((ProgressStatus::Success, _)) => "✓".to_string(),
        Some((ProgressStatus::Failed, _)) => "✗".to_string(),
        Some((ProgressStatus::Cancelled, _)) => "⊘".to_string(),
    };
    let percent_suffix = item.percent.map(|p| format!(" {p}%")).unwrap_or_default();
    let label: String = item
        .label
        .chars()
        .take(MAX_WIDTH as usize - percent_suffix.chars().count() - 6)
        .collect();
    let body_text = format!(" {glyph} {label}{percent_suffix}");
    let inner_w = body_text.chars().count() as u16;
    let box_w = (inner_w + 2)
        .min(MAX_WIDTH)
        .min(area.width.saturating_sub(2));
    let box_h: u16 = 3;
    if *y_bottom < area.y + box_h {
        return false;
    }
    let y = *y_bottom - box_h;
    let x = max_x_right.saturating_sub(box_w);
    let rect = Rect {
        x,
        y,
        width: box_w,
        height: box_h,
    };
    let border_fg = match item.finished {
        None => t.cyan,
        Some((ProgressStatus::Success, _)) => t.green,
        Some((ProgressStatus::Failed, _)) => t.red,
        Some((ProgressStatus::Cancelled, _)) => t.comment,
    };
    frame.render_widget(Clear, rect);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(border_fg).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    let line = Line::from(Span::styled(
        body_text,
        Style::default().fg(t.fg).bg(t.bg_darker),
    ));
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(t.bg_darker)),
        inner,
    );
    *y_bottom = y;
    true
}
