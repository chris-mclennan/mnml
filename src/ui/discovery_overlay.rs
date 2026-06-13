//! "+ Add integration" overlay renderer. Mirrors the settings
//! overlay's centered layout and key idioms — see
//! `src/ui/settings_overlay.rs` for the spine.
//!
//! Row shape:
//!   ▸ ✓  λ  mnml-aws-lambda            installed  (in rail)
//!     ✗  μ  mnml-tracker-linear        not installed
//!
//! Section headers between categories: `── AWS ──`, etc.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::app::discovery::{DiscoveryItem, SiblingStatus, build_items};
use crate::ui::theme;

fn overlay_rect(parent: Rect) -> Rect {
    let w = ((parent.width as f32) * 0.6) as u16;
    let w = w.clamp(64, 110).min(parent.width.saturating_sub(4));
    let h = ((parent.height as f32) * 0.7) as u16;
    let h = h.clamp(20, 60).min(parent.height.saturating_sub(4));
    Rect {
        x: parent.x + (parent.width.saturating_sub(w)) / 2,
        y: parent.y + (parent.height.saturating_sub(h)) / 2,
        width: w,
        height: h,
    }
}

pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    if app.discovery_overlay.is_none() {
        return;
    }
    let area = overlay_rect(parent);
    let t = theme::cur();

    frame.render_widget(Clear, area);

    // Stash the outer overlay rect so the mouse dispatcher can treat
    // any click INSIDE this rect as "stay open" (default to no-op
    // unless it lands on a sibling row), and any click OUTSIDE as a
    // dismiss. Without this, clicking a section header silently
    // closed the overlay (vscode-mouse-2026-06-10 SEV-2).
    app.rects.discovery_overlay_rect = Some(area);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            " + Add integration ",
            Style::default()
                .fg(t.bg_dark)
                .bg(t.green)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg_dark));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height < 4 {
        return;
    }

    // Body area = inner minus 1 row at the bottom for the hint bar.
    let body = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: inner.height.saturating_sub(1),
    };
    let hint = Rect {
        x: inner.x,
        y: inner.y + inner.height.saturating_sub(1),
        width: inner.width,
        height: 1,
    };

    let items = build_items(app);
    let selected_row = app
        .discovery_overlay
        .as_ref()
        .map(|s| s.selected_row)
        .unwrap_or(0);

    // Scroll: keep the selected row in the middle third when possible.
    let body_rows = body.height as usize;
    let total_lines = items.len();
    let mut nth_row = 0usize; // counts only non-Section rows
    let mut sel_abs = 0usize; // absolute line index of the selected row
    for (idx, item) in items.iter().enumerate() {
        if item.is_row() {
            if nth_row == selected_row {
                sel_abs = idx;
                break;
            }
            nth_row += 1;
        }
    }
    let start = if total_lines <= body_rows {
        0
    } else {
        let lo = sel_abs.saturating_sub(body_rows / 2);
        lo.min(total_lines.saturating_sub(body_rows))
    };

    // 2026-06-08 vscode-mouse hunt fix: clear the per-row rect list
    // so the mouse dispatcher can hit-test left-clicks against rows
    // instead of treating every click inside the overlay as a
    // dismiss.
    app.rects.discovery_integration_rows.clear();
    let mut row_visual_idx = 0usize;
    for (slot, abs_idx) in (0..body_rows).zip(start..total_lines) {
        let item = &items[abs_idx];
        let y = body.y + slot as u16;
        let row_rect = Rect {
            x: body.x,
            y,
            width: body.width,
            height: 1,
        };

        match item {
            DiscoveryItem::Section(header) => {
                let line = format!(" ── {header} ─");
                let pad = (body.width as usize).saturating_sub(line.chars().count());
                let line_full = format!("{line}{}", "─".repeat(pad));
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        line_full,
                        Style::default().fg(t.comment).add_modifier(Modifier::BOLD),
                    ))),
                    row_rect,
                );
            }
            DiscoveryItem::Sibling { sibling, status } => {
                // Figure out which non-Section row this is (so we can
                // compare against selected_row).
                let visual_idx = row_visual_idx_for_sibling(&items, abs_idx);
                let is_focused = visual_idx == selected_row;
                row_visual_idx += 1;
                let _ = row_visual_idx;
                // Stash the hit-rect for the mouse dispatcher.
                app.rects
                    .discovery_integration_rows
                    .push((row_rect, visual_idx));

                let cursor = if is_focused { "▸" } else { " " };
                let (status_glyph, status_color) = match status {
                    SiblingStatus::InRail => ("✓", t.green),
                    SiblingStatus::Installed => ("✓", t.cyan),
                    SiblingStatus::NotInstalled => ("✗", t.red),
                };
                let mut status_text: String = match status {
                    SiblingStatus::InRail => "installed (in rail)".to_string(),
                    SiblingStatus::Installed => "installed".to_string(),
                    SiblingStatus::NotInstalled => "not installed".to_string(),
                };
                if sibling.is_discovered() {
                    status_text.push_str(" · auto-discovered");
                }
                let name_col = 32usize;
                let name_padded = pad_or_truncate(sibling.binary(), name_col);
                let mut spans: Vec<Span<'static>> = Vec::new();
                let base_style = if is_focused {
                    Style::default()
                        .fg(t.fg)
                        .bg(t.bg_darker)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(t.fg).bg(t.bg_dark)
                };
                spans.push(Span::styled(
                    format!(" {cursor} "),
                    if is_focused {
                        Style::default().fg(t.blue).bg(t.bg_darker)
                    } else {
                        base_style
                    },
                ));
                spans.push(Span::styled(
                    format!("{status_glyph}  "),
                    Style::default()
                        .fg(status_color)
                        .bg(base_style.bg.unwrap_or(t.bg_dark)),
                ));
                spans.push(Span::styled(name_padded, base_style));
                let status_len = status_text.chars().count();
                spans.push(Span::styled(
                    format!("  {status_text}"),
                    Style::default()
                        .fg(t.comment)
                        .bg(base_style.bg.unwrap_or(t.bg_dark)),
                ));
                // Trailing pad to fill the row background.
                let used = 4 + 3 + name_col + 2 + status_len;
                let pad = (body.width as usize).saturating_sub(used);
                spans.push(Span::styled(
                    " ".repeat(pad),
                    Style::default().bg(base_style.bg.unwrap_or(t.bg_dark)),
                ));
                frame.render_widget(Paragraph::new(Line::from(spans)), row_rect);
            }
        }
    }

    let hint_text = " ↑↓ move · Enter add to rail · i install (cargo) · y yank cmd · Esc close ";
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            hint_text,
            Style::default()
                .fg(t.comment)
                .bg(t.bg_dark)
                .add_modifier(Modifier::DIM),
        ))),
        hint,
    );
}

fn row_visual_idx_for_sibling(items: &[DiscoveryItem], abs_idx: usize) -> usize {
    items[..=abs_idx]
        .iter()
        .filter(|i| i.is_row())
        .count()
        .saturating_sub(1)
}

fn pad_or_truncate(s: &str, n: usize) -> String {
    let count = s.chars().count();
    if count >= n {
        let mut out: String = s.chars().take(n.saturating_sub(1)).collect();
        out.push('…');
        out
    } else {
        format!("{s}{}", " ".repeat(n - count))
    }
}
