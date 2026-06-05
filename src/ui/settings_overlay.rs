//! Settings overlay renderer. Paints a centered bordered overlay
//! showing every `SettingItem` from `app::settings::build_settings`
//! — section headers as `── <name> ──`, rows as
//! `▸ <label>:  [active] / other  *`. See the "Family settings UI
//! convention" in CLAUDE.md.
//!
//! Sizing: overlay takes ~60% of the screen width (clamped 60..=120)
//! and ~70% of the height (clamped 20..=60). Scrolls when the row
//! list exceeds the visible area.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::app::settings::{RESET_ALL_KEY, SettingItem, build_settings};
use crate::ui::theme;

/// Compute the overlay rect — centered, ~60% width × ~70% height,
/// clamped to comfortable terminal sizes.
fn overlay_rect(parent: Rect) -> Rect {
    let w = ((parent.width as f32) * 0.6) as u16;
    let w = w.clamp(60, 120).min(parent.width.saturating_sub(4));
    let h = ((parent.height as f32) * 0.7) as u16;
    let h = h.clamp(20, 60).min(parent.height.saturating_sub(4));
    Rect {
        x: parent.x + (parent.width.saturating_sub(w)) / 2,
        y: parent.y + (parent.height.saturating_sub(h)) / 2,
        width: w,
        height: h,
    }
}

/// Paint the settings overlay. No-op when the overlay is closed.
pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    if app.settings_overlay.is_none() {
        return;
    }
    let area = overlay_rect(parent);
    let t = theme::cur();

    // Solid background — Clear wipes whatever the editor painted underneath.
    frame.render_widget(Clear, area);

    // Outer block — title "Settings", blue bg / dark fg accent chip.
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            " Settings ",
            Style::default()
                .fg(t.bg_dark)
                .bg(t.blue)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg_dark));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Build rows + paint.
    let items = build_settings(&app.config);
    let selected = app
        .settings_overlay
        .as_ref()
        .map(|s| s.selected_row)
        .unwrap_or(0);

    // Find the `items`-level index of the focused row (skipping section
    // headers, which selected_row doesn't count).
    let mut row_counter = 0usize;
    let mut focused_item_idx: Option<usize> = None;
    for (i, item) in items.iter().enumerate() {
        if item.is_row() {
            if row_counter == selected {
                focused_item_idx = Some(i);
                break;
            }
            row_counter += 1;
        }
    }

    // Build rendered lines.
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        match item {
            SettingItem::Section(name) => {
                lines.push(Line::from(Span::styled(
                    format!("── {name} ──"),
                    Style::default()
                        .fg(t.comment)
                        .add_modifier(Modifier::BOLD | Modifier::DIM),
                )));
            }
            SettingItem::Row(row) => {
                let is_focused = Some(i) == focused_item_idx;
                let marker = if is_focused { "▸ " } else { "  " };

                let mut spans = vec![
                    Span::styled(
                        marker,
                        Style::default().fg(if is_focused { t.blue } else { t.bg2 }),
                    ),
                    Span::styled(
                        format!("{:30}  ", row.label),
                        Style::default().fg(if is_focused { t.fg } else { t.comment }),
                    ),
                ];

                if row.key == RESET_ALL_KEY {
                    // Sentinel row — paint a red-tinted "Enter to reset" hint.
                    spans.push(Span::styled(
                        "(Enter to reset)",
                        Style::default().fg(t.red).add_modifier(if is_focused {
                            Modifier::BOLD
                        } else {
                            Modifier::DIM
                        }),
                    ));
                } else {
                    for (j, opt) in row.options.iter().enumerate() {
                        let is_current = j == row.current_idx;
                        if j > 0 {
                            spans.push(Span::styled(" / ", Style::default().fg(t.bg2)));
                        }
                        if is_current {
                            spans.push(Span::styled(
                                format!("[{opt}]"),
                                Style::default()
                                    .fg(if is_focused { t.cyan } else { t.fg })
                                    .add_modifier(Modifier::BOLD),
                            ));
                        } else {
                            spans.push(Span::styled(opt.clone(), Style::default().fg(t.bg2)));
                        }
                    }
                    if row.modified {
                        spans.push(Span::styled(
                            "  *",
                            Style::default().fg(t.yellow).add_modifier(Modifier::BOLD),
                        ));
                    }
                }

                lines.push(Line::from(spans));
            }
            SettingItem::Number(num) => {
                let is_focused = Some(i) == focused_item_idx;
                let marker = if is_focused { "▸ " } else { "  " };
                let mut spans = vec![
                    Span::styled(
                        marker,
                        Style::default().fg(if is_focused { t.blue } else { t.bg2 }),
                    ),
                    Span::styled(
                        format!("{:30}  ", num.label),
                        Style::default().fg(if is_focused { t.fg } else { t.comment }),
                    ),
                    Span::styled(
                        format!("[ {}{} ]", num.value, num.unit),
                        Style::default()
                            .fg(if is_focused { t.cyan } else { t.fg })
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        format!(
                            "  ({}–{} · step {} · default {})",
                            num.min, num.max, num.step, num.default
                        ),
                        Style::default().fg(t.comment).add_modifier(Modifier::DIM),
                    ),
                ];
                if num.modified {
                    spans.push(Span::styled(
                        "  *",
                        Style::default().fg(t.yellow).add_modifier(Modifier::BOLD),
                    ));
                }
                lines.push(Line::from(spans));
            }
        }
    }

    // Scroll-window the lines so the focused row stays visible. Reserve
    // a 1-row hint bar at the bottom of the inner rect.
    let body_h = (inner.height as usize).saturating_sub(1);
    let focused_line_idx = focused_item_idx.unwrap_or(0);
    let scroll = if focused_line_idx >= body_h {
        focused_line_idx + 1 - body_h
    } else {
        0
    };
    let window: Vec<Line<'static>> = lines.iter().skip(scroll).take(body_h).cloned().collect();
    let body_rect = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: body_h as u16,
    };
    frame.render_widget(Paragraph::new(window), body_rect);

    // 1-line hint bar at the bottom.
    let hint = "←→ adjust · ↑↓ move · r reset row · R reset all · Enter save · Esc cancel";
    let hint_rect = Rect {
        x: inner.x,
        y: inner.y + inner.height.saturating_sub(1),
        width: inner.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Span::styled(
            hint,
            Style::default().fg(t.comment).add_modifier(Modifier::DIM),
        )),
        hint_rect,
    );
}
