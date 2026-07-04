//! Help overlay renderer. Paints the rows produced by
//! `app::help::build_help` — section headers, then rows of
//! `<keys-column>  <title>`. Scrollable when the list exceeds the
//! overlay's body height.
//!
//! Mirrors the visual language of the Settings overlay: centered,
//! bordered, blue title chip.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::app::help::{HelpRow, build_help};
use crate::ui::theme;

fn overlay_rect(parent: Rect) -> Rect {
    let w = ((parent.width as f32) * 0.7) as u16;
    let w = w.clamp(70, 140).min(parent.width.saturating_sub(4));
    let h = ((parent.height as f32) * 0.8) as u16;
    let h = h.clamp(20, 60).min(parent.height.saturating_sub(4));
    Rect {
        x: parent.x + (parent.width.saturating_sub(w)) / 2,
        y: parent.y + (parent.height.saturating_sub(h)) / 2,
        width: w,
        height: h,
    }
}

pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    if app.help_overlay.is_none() {
        return;
    }
    let area = overlay_rect(parent);
    let t = theme::cur();

    frame.render_widget(Clear, area);

    let block = crate::ui::design_tokens::modal_panel("Help");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let rows = build_help(&app.keymap);
    let scroll = app.help_overlay.as_ref().map(|s| s.scroll).unwrap_or(0);
    let collapsed: std::collections::HashSet<String> = app
        .help_overlay
        .as_ref()
        .map(|s| s.collapsed.clone())
        .unwrap_or_default();
    app.rects.help_section_headers.clear();

    // Compute key-column width — wide enough for the widest chord
    // string in the visible window, capped so the title column stays
    // readable on narrow terminals.
    let key_col_w: usize = rows
        .iter()
        .filter_map(|r| match r {
            HelpRow::Binding { keys, .. } => Some(keys.len()),
            _ => None,
        })
        .max()
        .unwrap_or(8)
        .clamp(8, 20);

    // Two-pass build so we can drop binding rows for collapsed
    // sections AND track which section each line corresponds to
    // (for click hit-testing).
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(rows.len());
    // Section name for each *visible* line — `None` for binding
    // rows (only header rows are clickable).
    let mut header_names: Vec<Option<String>> = Vec::with_capacity(rows.len());
    let mut current_section: Option<String> = None;
    let mut section_collapsed = false;
    for row in &rows {
        match row {
            HelpRow::Section(name) => {
                current_section = Some(name.to_string());
                section_collapsed = collapsed.contains(*name);
                let chev = if section_collapsed { "▸" } else { "▾" };
                lines.push(Line::from(Span::styled(
                    format!("{chev} ── {name} ──"),
                    Style::default()
                        .fg(t.comment)
                        .add_modifier(Modifier::BOLD | Modifier::DIM),
                )));
                header_names.push(Some(name.to_string()));
            }
            HelpRow::Binding { keys, title, .. } => {
                if section_collapsed {
                    continue;
                }
                let kc = if keys.is_empty() { "·" } else { keys.as_str() };
                let pad = key_col_w.saturating_sub(kc.chars().count());
                lines.push(Line::from(vec![
                    Span::styled(format!("  {}", kc), Style::default().fg(t.cyan)),
                    Span::raw(" ".repeat(pad + 2)),
                    Span::styled((*title).to_string(), Style::default().fg(t.fg)),
                ]));
                header_names.push(None);
            }
        }
    }
    let _ = current_section;

    // Scroll-window: reserve 1 row for the hint bar.
    let body_h = (inner.height as usize).saturating_sub(1);
    let max_scroll = lines.len().saturating_sub(body_h);
    let scroll = scroll.min(max_scroll);
    let window: Vec<Line<'static>> = lines.iter().skip(scroll).take(body_h).cloned().collect();
    let body_rect = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: body_h as u16,
    };
    frame.render_widget(Paragraph::new(window), body_rect);

    // Register click rects for visible section headers.
    for (visible_idx, header_name) in header_names.iter().skip(scroll).take(body_h).enumerate() {
        if let Some(name) = header_name {
            let row_rect = Rect {
                x: inner.x,
                y: inner.y + visible_idx as u16,
                width: inner.width,
                height: 1,
            };
            app.rects
                .help_section_headers
                .push((row_rect, name.clone()));
        }
    }

    let hint =
        "↑↓ / j k scroll · PageUp/Down faster · click section ▾/▸ to collapse · Esc / F1 close";
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
