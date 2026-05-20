//! Shared scrollbar drawing for list-style panes. Each pane renders
//! its body, reserves the rightmost column, then calls
//! [`paint_simple_scrollbar`] + pushes a [`crate::app::ScrollbarHit`]
//! so the existing dispatcher in `tui.rs` handles click + drag.
//!
//! "Simple" because there are no change-density markers here — the
//! editor + diff scrollbars are a richer variant that lives next to
//! their renderers.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::widgets::Paragraph;

use crate::ui::theme::Theme;

/// Paint a 1-cell scrollbar (track in `bg2`, solid `comment` thumb)
/// over `area`. `total` is the underlying row count, `viewport` is
/// the visible row count, `scroll` is the top-row offset. No-op when
/// `area` is empty.
pub fn paint_simple_scrollbar(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    total: usize,
    viewport: usize,
    scroll: usize,
) {
    if area.height == 0 || area.width == 0 {
        return;
    }
    let cells = area.height as usize;
    // Track.
    for cy in 0..cells {
        frame.render_widget(
            Paragraph::new(" ".repeat(area.width as usize)).style(Style::default().bg(t.bg2)),
            Rect::new(area.x, area.y + cy as u16, area.width, 1),
        );
    }
    // Thumb — only when content overflows the viewport.
    if total > viewport && viewport > 0 {
        let thumb_h = ((cells * viewport) / total).max(1);
        let max_scroll = total - viewport;
        let max_thumb_top = cells.saturating_sub(thumb_h);
        let thumb_top = (scroll * max_thumb_top)
            .checked_div(max_scroll)
            .unwrap_or(0);
        for cy in thumb_top..(thumb_top + thumb_h).min(cells) {
            frame.render_widget(
                Paragraph::new(" ".repeat(area.width as usize))
                    .style(Style::default().bg(t.comment)),
                Rect::new(area.x, area.y + cy as u16, area.width, 1),
            );
        }
    }
}

/// Paint a 1-row HORIZONTAL scrollbar over `area` (a single row). `total`
/// is the widest content column, `viewport` the visible column count,
/// `scroll` the left-column offset (`Buffer.h_scroll`). The thumb spans
/// the visible fraction; track in `bg2`, thumb in `comment`.
pub fn paint_horizontal_scrollbar(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    total: usize,
    viewport: usize,
    scroll: usize,
) {
    if area.height == 0 || area.width == 0 {
        return;
    }
    let cells = area.width as usize;
    // Track.
    frame.render_widget(
        Paragraph::new("─".repeat(cells)).style(Style::default().fg(t.bg2).bg(t.bg_dark)),
        area,
    );
    if total > viewport && viewport > 0 {
        let thumb_w = ((cells * viewport) / total).max(1);
        let max_scroll = total - viewport;
        let max_thumb_left = cells.saturating_sub(thumb_w);
        let thumb_left = (scroll.min(max_scroll) * max_thumb_left)
            .checked_div(max_scroll)
            .unwrap_or(0);
        frame.render_widget(
            Paragraph::new("━".repeat(thumb_w)).style(Style::default().fg(t.comment).bg(t.bg_dark)),
            Rect::new(
                area.x + thumb_left as u16,
                area.y,
                thumb_w.min(cells) as u16,
                1,
            ),
        );
    }
}
