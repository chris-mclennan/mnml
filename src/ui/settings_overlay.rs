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
use ratatui::style::{Color, Modifier, Style};
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
    // Clear stale hit-test rects every frame whether or not the
    // overlay is open — they'd otherwise survive between opens.
    app.rects.settings_overlay_rect = None;
    app.rects.settings_rows.clear();
    if app.settings_overlay.is_none() {
        return;
    }
    let area = overlay_rect(parent);
    app.rects.settings_overlay_rect = Some(area);
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

    // Build rendered lines. We keep a parallel `line_row_counter`
    // vector so the windowing loop below can map a visible line back
    // to its 0-based row index — what `settings_move_row` /
    // `apply_setting` use. Section headers get `None`.
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(items.len());
    let mut line_row_counter: Vec<Option<usize>> = Vec::with_capacity(items.len());
    let mut rc = 0usize;
    for (i, item) in items.iter().enumerate() {
        match item {
            SettingItem::Section(name) => {
                lines.push(Line::from(Span::styled(
                    format!("── {name} ──"),
                    Style::default()
                        .fg(t.comment)
                        .add_modifier(Modifier::BOLD | Modifier::DIM),
                )));
                line_row_counter.push(None);
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
                line_row_counter.push(Some(rc));
                rc += 1;
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
                line_row_counter.push(Some(rc));
                rc += 1;
            }
            SettingItem::Text(row) => {
                let is_focused = Some(i) == focused_item_idx;
                let marker = if is_focused { "▸ " } else { "  " };
                let in_edit = is_focused
                    && app
                        .settings_overlay
                        .as_ref()
                        .and_then(|s| s.text_edit.as_ref())
                        .map(|e| e.key == row.key)
                        .unwrap_or(false);
                let value_display = if in_edit {
                    format!("[ \"{}│\" ]", row.value)
                } else {
                    format!("[ \"{}\" ]", row.value)
                };
                let hint = if in_edit {
                    "  (editing · Enter commit · Esc cancel)".to_string()
                } else {
                    format!("  (text · default \"{}\" · Enter to edit)", row.default)
                };
                let mut spans = vec![
                    Span::styled(
                        marker,
                        Style::default().fg(if is_focused { t.blue } else { t.bg2 }),
                    ),
                    Span::styled(
                        format!("{:30}  ", row.label),
                        Style::default().fg(if is_focused { t.fg } else { t.comment }),
                    ),
                    Span::styled(
                        value_display,
                        Style::default()
                            .fg(if is_focused { t.cyan } else { t.fg })
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        hint,
                        Style::default().fg(t.comment).add_modifier(Modifier::DIM),
                    ),
                ];
                if row.modified {
                    spans.push(Span::styled(
                        "  *",
                        Style::default().fg(t.yellow).add_modifier(Modifier::BOLD),
                    ));
                }
                lines.push(Line::from(spans));
                line_row_counter.push(Some(rc));
                rc += 1;
            }
            SettingItem::Color(row) => {
                let is_focused = Some(i) == focused_item_idx;
                let marker = if is_focused { "▸ " } else { "  " };
                let parsed = parse_hex_rgb(&row.value);
                let swatch_color = parsed.unwrap_or(t.fg);
                let suffix_text = if parsed.is_some() {
                    format!("  (color · default #{} · TOML to edit)", row.default)
                } else {
                    format!(
                        "  (color · default #{} · invalid hex · TOML to edit)",
                        row.default
                    )
                };
                let mut spans = vec![
                    Span::styled(
                        marker,
                        Style::default().fg(if is_focused { t.blue } else { t.bg2 }),
                    ),
                    Span::styled(
                        format!("{:30}  ", row.label),
                        Style::default().fg(if is_focused { t.fg } else { t.comment }),
                    ),
                    Span::styled(
                        format!("[ #{} ]  ", row.value),
                        Style::default()
                            .fg(if is_focused { t.cyan } else { t.fg })
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled("████", Style::default().fg(swatch_color)),
                    Span::styled(
                        suffix_text,
                        Style::default().fg(t.comment).add_modifier(Modifier::DIM),
                    ),
                ];
                if row.modified {
                    spans.push(Span::styled(
                        "  *",
                        Style::default().fg(t.yellow).add_modifier(Modifier::BOLD),
                    ));
                }
                lines.push(Line::from(spans));
                line_row_counter.push(Some(rc));
                rc += 1;
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
    // Truncate each line to fit inner.width — without this, long
    // descriptions used to cut mid-word at the right border with no
    // indicator (looked broken). 2026-06-07 bug-hunt SEV-3.
    let window: Vec<Line<'static>> = lines
        .iter()
        .skip(scroll)
        .take(body_h)
        .map(|l| truncate_line_to_width(l, inner.width as usize))
        .collect();
    let body_rect = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: body_h as u16,
    };
    // Hit-test rects: one per visible Row line, mapped to the
    // row_counter index `settings_move_row` / `apply_setting` use.
    // Section-header lines are excluded (None in line_row_counter).
    for (visible_y, line_idx) in (scroll..scroll + window.len()).enumerate() {
        if let Some(Some(rc_idx)) = line_row_counter.get(line_idx).copied() {
            app.rects.settings_rows.push((
                Rect {
                    x: body_rect.x,
                    y: body_rect.y + visible_y as u16,
                    width: body_rect.width,
                    height: 1,
                },
                rc_idx,
            ));
        }
    }
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

/// Parse a 6-char `RRGGBB` hex (no `#`) into a `ratatui::Color::Rgb`.
/// Returns `None` for invalid input. Used to render the color-row
/// swatch in `ColorRow`'s parsed color.
fn parse_hex_rgb(hex: &str) -> Option<Color> {
    let bytes = hex.as_bytes();
    if bytes.len() != 6 || !bytes.iter().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
    let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
    let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
    Some(Color::Rgb(r, g, b))
}

/// Truncate a `Line<'static>` (span-by-span) so its total char count
/// doesn't exceed `max_width`. If truncation happens, append `…` as
/// a final span to surface that something was cut (without it, the
/// row reads as broken mid-word at the right border). Width is char
/// count, not display width — sufficient for the settings overlay
/// where labels + values are ASCII/Latin.
fn truncate_line_to_width(line: &Line<'static>, max_width: usize) -> Line<'static> {
    let total: usize = line.spans.iter().map(|s| s.content.chars().count()).sum();
    if total <= max_width {
        return line.clone();
    }
    // Reserve 1 char for the trailing `…` marker.
    let budget = max_width.saturating_sub(1);
    let mut used = 0usize;
    let mut out_spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 1);
    for span in &line.spans {
        let span_len = span.content.chars().count();
        if used + span_len <= budget {
            out_spans.push(span.clone());
            used += span_len;
        } else {
            let take = budget.saturating_sub(used);
            if take > 0 {
                let s: String = span.content.chars().take(take).collect();
                out_spans.push(Span::styled(s, span.style));
            }
            break;
        }
    }
    out_spans.push(Span::styled("…", Style::default().fg(Color::DarkGray)));
    Line::from(out_spans)
}
