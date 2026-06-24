//! Renderer for `App::dock_widgets`. Paints each widget into a
//! corner of the editor body area, stacking inward when multiple
//! widgets share a corner.
//!
//! Slice 1 ships only `DockCorner::BottomLeft` painting + the
//! `DockContent::Text` variant + a close `×`. Other corners
//! match the same shape — the `corner_anchor_y` helper computes
//! the starting y per corner so adding them is a small follow-up.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
};

use crate::app::App;
use crate::dock::{DockContent, DockCorner};
use crate::ui::theme;

/// Paint all dock widgets into the editor body area. Called from
/// `ui::draw` AFTER the editor / split tree paints, so the dock
/// chrome overlays the editor when they overlap.
pub fn draw(frame: &mut Frame, app: &mut App, editor_area: Rect) {
    app.rects.dock_widget_bodies.clear();
    app.rects.dock_widget_close_buttons.clear();
    app.rects.dock_widget_titles.clear();
    if app.dock_widgets.is_empty() {
        return;
    }
    if editor_area.width < 12 || editor_area.height < 4 {
        return;
    }
    let t = theme::cur();

    // Group widgets by corner so we know how to stack inside each.
    // Iterate the four corners explicitly so painting order is
    // deterministic regardless of insertion order.
    for &corner in &[
        DockCorner::BottomLeft,
        DockCorner::BottomRight,
        DockCorner::TopLeft,
        DockCorner::TopRight,
    ] {
        paint_corner_stack(frame, app, editor_area, corner, t);
    }
}

fn paint_corner_stack(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    corner: DockCorner,
    t: crate::ui::theme::Theme,
) {
    // Collect widgets pinned to this corner, in the order they
    // were inserted. The order determines stack order: BottomLeft
    // stacks UPWARD (first widget sits at the very bottom),
    // TopLeft stacks DOWNWARD (first widget sits at the very top).
    let indexed: Vec<(usize, _)> = app
        .dock_widgets
        .iter()
        .enumerate()
        .filter(|(_, w)| w.corner == corner)
        .map(|(i, w)| (i, w.clone()))
        .collect();
    if indexed.is_empty() {
        return;
    }

    // Compute per-widget rect, then cap the total height per
    // corner to 50% of editor body so the stack can't smother
    // the editor underneath.
    let max_stack_h = area.height / 2;
    let mut painted_h: u16 = 0;
    // For bottom corners we stack from the bottom edge inward
    // (upward), so we iterate widgets in REVERSE so the
    // visually-topmost widget gets the last (smallest) y. For
    // top corners we stack downward, so iterate forward.
    let is_bottom = matches!(corner, DockCorner::BottomLeft | DockCorner::BottomRight);
    let order: Box<dyn Iterator<Item = &(usize, crate::dock::DockWidget)>> =
        if is_bottom {
            Box::new(indexed.iter().rev())
        } else {
            Box::new(indexed.iter())
        };

    for (_, w) in order {
        // Clamp the user's fractions to a sane range so a widget
        // is never unusably small or oversized.
        let w_frac = w.width_frac.clamp(0.15, 0.9);
        let h_frac = w.height_frac.clamp(0.15, 0.9);
        let widget_w = (area.width as f32 * w_frac) as u16;
        let widget_h = (area.height as f32 * h_frac) as u16;
        if widget_w < 8 || widget_h < 3 {
            continue;
        }
        // Skip if this widget would push the stack past 50%.
        if painted_h.saturating_add(widget_h) > max_stack_h {
            break;
        }

        // Position depends on corner. For bottom corners,
        // `painted_h` is the distance already consumed above the
        // bottom edge; the new widget sits with its bottom edge at
        // `area.y + area.height - painted_h - widget_h`.
        let (x, y) = match corner {
            DockCorner::BottomLeft => (
                area.x,
                area.y + area.height - painted_h - widget_h,
            ),
            DockCorner::BottomRight => (
                area.x + area.width - widget_w,
                area.y + area.height - painted_h - widget_h,
            ),
            DockCorner::TopLeft => (area.x, area.y + painted_h),
            DockCorner::TopRight => (
                area.x + area.width - widget_w,
                area.y + painted_h,
            ),
        };
        let widget_rect = Rect {
            x,
            y,
            width: widget_w,
            height: widget_h,
        };
        frame.render_widget(Clear, widget_rect);

        // Block border + bg.
        let block = Block::default()
            .borders(Borders::ALL)
            .style(Style::default().fg(t.comment).bg(t.bg2));
        let inner = block.inner(widget_rect);
        frame.render_widget(block, widget_rect);

        // Title bar (top row of inner area) + close button at the
        // rightmost cell of that row.
        if inner.width > 4 {
            let close_glyph = "×";
            let title_w = inner.width.saturating_sub(2);
            let title_clipped: String = w.title.chars().take(title_w as usize).collect();
            let pad = (title_w as usize).saturating_sub(title_clipped.chars().count());
            let title_line = Line::from(vec![
                Span::styled(
                    title_clipped,
                    Style::default()
                        .fg(t.fg)
                        .bg(t.bg2)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(" ".repeat(pad), Style::default().bg(t.bg2)),
                Span::styled(
                    close_glyph,
                    Style::default().fg(t.red).bg(t.bg2),
                ),
                Span::styled(" ", Style::default().bg(t.bg2)),
            ]);
            let title_rect = Rect {
                x: inner.x,
                y: inner.y,
                width: inner.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(title_line), title_rect);
            // Close button click rect — the rightmost 1 cell (the ×).
            let close_rect = Rect {
                x: inner.x + inner.width - 2,
                y: inner.y,
                width: 1,
                height: 1,
            };
            app.rects.dock_widget_close_buttons.push((close_rect, w.id));
            // Title-bar drag-anchor rect — everything EXCEPT the
            // close × button.
            let title_drag_rect = Rect {
                x: inner.x,
                y: inner.y,
                width: inner.width.saturating_sub(2),
                height: 1,
            };
            app.rects.dock_widget_titles.push((title_drag_rect, w.id));
        }

        // Body content (inner minus title row).
        if inner.height >= 2 {
            let body_rect = Rect {
                x: inner.x,
                y: inner.y + 1,
                width: inner.width,
                height: inner.height - 1,
            };
            match &w.content {
                DockContent::Text(s) => {
                    render_text_body(frame, body_rect, s, t);
                }
                DockContent::LogTail { path, max_lines } => {
                    render_log_tail_body(frame, body_rect, path, *max_lines, t);
                }
            }
            app.rects.dock_widget_bodies.push((body_rect, w.id));
        }

        painted_h = painted_h.saturating_add(widget_h);
    }
}

/// Render static text into the widget's body. Naive char-boundary
/// line-wrap; long single words just clip at the right edge. Good
/// enough for v1 — proper word-wrap can land later.
fn render_text_body(
    frame: &mut Frame,
    body_rect: Rect,
    text: &str,
    t: crate::ui::theme::Theme,
) {
    let mut lines: Vec<Line> = Vec::with_capacity(body_rect.height as usize);
    let max_w = body_rect.width as usize;
    for raw in text.lines() {
        let mut remaining = raw;
        while !remaining.is_empty() && lines.len() < body_rect.height as usize {
            let take = remaining.chars().take(max_w).collect::<String>();
            let take_len = take.chars().count();
            lines.push(Line::from(Span::styled(
                take,
                Style::default().fg(t.fg).bg(t.bg2),
            )));
            remaining = remaining
                .char_indices()
                .nth(take_len)
                .map(|(idx, _)| &remaining[idx..])
                .unwrap_or("");
        }
        if lines.len() >= body_rect.height as usize {
            break;
        }
    }
    frame.render_widget(Paragraph::new(lines), body_rect);
}

/// Render the last `max_lines` rows of `path` into the body. Re-
/// reads the file every frame; sufficient for the small log
/// tails this widget targets (tests + build output + AI session
/// jsonl), and avoids the complexity of mtime caching.
///
/// Empty / missing file → render a dim placeholder.
fn render_log_tail_body(
    frame: &mut Frame,
    body_rect: Rect,
    path: &std::path::Path,
    max_lines: usize,
    t: crate::ui::theme::Theme,
) {
    let max_w = body_rect.width as usize;
    let max_h = body_rect.height as usize;
    let take_n = max_lines.min(max_h);

    let mut lines_out: Vec<Line> = Vec::with_capacity(take_n);
    match std::fs::read_to_string(path) {
        Ok(s) => {
            let all_lines: Vec<&str> = s.lines().collect();
            let start = all_lines.len().saturating_sub(take_n);
            for raw in &all_lines[start..] {
                // Truncate to width — log tails are usually long-
                // line stdout; wrapping wastes vertical space.
                let display: String = raw.chars().take(max_w).collect();
                lines_out.push(Line::from(Span::styled(
                    display,
                    Style::default().fg(t.fg).bg(t.bg2),
                )));
            }
        }
        Err(_) => {
            // File missing / unreadable — show the path so the
            // user knows what we tried to open.
            let display: String = format!("(no file: {})", path.display())
                .chars()
                .take(max_w)
                .collect();
            lines_out.push(Line::from(Span::styled(
                display,
                Style::default().fg(t.comment).bg(t.bg2),
            )));
        }
    }
    frame.render_widget(Paragraph::new(lines_out), body_rect);
}
