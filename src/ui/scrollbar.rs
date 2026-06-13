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

/// Paint a 1-cell scrollbar over `area`. Track is a dim `│` glyph on
/// `bg2`; thumb is a solid `█` block glyph in `comment` fg. `total`
/// is the underlying row count, `viewport` is the visible row count,
/// `scroll` is the top-row offset. No-op when `area` is empty.
///
/// vscode-mouse-2026-06-10 SEV-3 #7: the previous version painted
/// solid-color background blocks only — `comment` thumb on the
/// editor's `bg2` background was nearly indistinguishable on
/// onedark / catppuccin / kanagawa themes (the colors are
/// intentionally close). Switching to a glyph-on-bg model makes
/// the thumb visible without changing the palette.
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
    let track_glyph = "│".repeat(area.width as usize);
    let thumb_glyph = "█".repeat(area.width as usize);
    // Track — a dim `│` over `bg2`. Visible enough that the column
    // edge reads as a scrollbar gutter even when the thumb isn't
    // present (file fits in the viewport).
    for cy in 0..cells {
        frame.render_widget(
            Paragraph::new(track_glyph.clone()).style(Style::default().fg(t.grey).bg(t.bg2)),
            Rect::new(area.x, area.y + cy as u16, area.width, 1),
        );
    }
    // Thumb — `█` block in `comment` (mid-grey) on `bg2`. The block
    // glyph + the contrast of fg vs the surrounding track make the
    // thumb obviously visible.
    if total > viewport && viewport > 0 {
        let thumb_h = ((cells * viewport) / total).max(1);
        let max_scroll = total - viewport;
        let max_thumb_top = cells.saturating_sub(thumb_h);
        let thumb_top = (scroll * max_thumb_top)
            .checked_div(max_scroll)
            .unwrap_or(0);
        for cy in thumb_top..(thumb_top + thumb_h).min(cells) {
            frame.render_widget(
                Paragraph::new(thumb_glyph.clone()).style(Style::default().fg(t.comment).bg(t.bg2)),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::theme;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    /// The horizontal scrollbar paints a `━` thumb over a `─` track —
    /// the thumb width + offset are deterministic geometry.
    #[test]
    fn horizontal_scrollbar_places_the_thumb_by_scroll() {
        let t = theme::onedark();
        let row = |total: usize, viewport: usize, scroll: usize| -> String {
            let mut term = Terminal::new(TestBackend::new(20, 1)).unwrap();
            term.draw(|f| paint_horizontal_scrollbar(f, f.area(), &t, total, viewport, scroll))
                .unwrap();
            let buf = term.backend().buffer();
            (0..20).map(|x| buf[(x, 0)].symbol().to_string()).collect()
        };
        // 20/100 visible ⇒ a 4-cell thumb. At scroll 0 it's flush left.
        let r = row(100, 20, 0);
        assert_eq!(r, format!("{}{}", "━".repeat(4), "─".repeat(16)));
        // Scrolled to the end ⇒ thumb flush right.
        let r = row(100, 20, 80);
        assert_eq!(r, format!("{}{}", "─".repeat(16), "━".repeat(4)));
        // Content fits the viewport ⇒ no thumb, all track.
        assert_eq!(row(10, 20, 0), "─".repeat(20));
    }

    /// The vertical scrollbar paints `█` block-glyph thumb cells (fg
    /// `comment`) over a `│` track (fg `grey`), both on `bg2`.
    /// Detect thumb by the `█` symbol — that distinguishes thumb
    /// cells from track cells regardless of bg.
    #[test]
    fn simple_scrollbar_sizes_and_places_the_thumb() {
        let t = theme::onedark();
        let thumb_rows = |total: usize, viewport: usize, scroll: usize| -> Vec<usize> {
            let mut term = Terminal::new(TestBackend::new(1, 10)).unwrap();
            term.draw(|f| paint_simple_scrollbar(f, f.area(), &t, total, viewport, scroll))
                .unwrap();
            let buf = term.backend().buffer();
            (0..10u16)
                .filter(|&y| buf[(0, y)].symbol() == "█")
                .map(|y| y as usize)
                .collect()
        };
        // 10/100 visible over a 10-cell bar ⇒ a 1-cell thumb at the top.
        assert_eq!(thumb_rows(100, 10, 0), vec![0]);
        // Scrolled to the bottom ⇒ the thumb sits on the last row.
        assert_eq!(thumb_rows(100, 10, 90), vec![9]);
        // Content fits ⇒ no thumb at all.
        assert!(thumb_rows(10, 20, 0).is_empty());
    }
}
