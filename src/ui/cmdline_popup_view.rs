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
use ratatui::style::Color;

/// Parse a `RRGGBB` hex string (no leading `#`) into a Color.
/// Empty or malformed returns None — caller falls back to theme.
fn parse_hex_color(hex: &str) -> Option<Color> {
    let h = hex.trim().trim_start_matches('#');
    if h.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&h[0..2], 16).ok()?;
    let g = u8::from_str_radix(&h[2..4], 16).ok()?;
    let b = u8::from_str_radix(&h[4..6], 16).ok()?;
    Some(Color::Rgb(r, g, b))
}

const MAX_VISIBLE: usize = 8;
const MAX_WIDTH: u16 = 110;

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
    } else if let Some(text) = app.active_editor().and_then(|b| b.input.cmdline_get()) {
        text
    } else {
        return;
    };
    // 2026-06-19 polish — empty cmdline (user just typed `:` or
    // opened with Ctrl+;) shows recent commands so they can be
    // re-fired with one keystroke. VS Code's palette behavior.
    // Falls back to nothing if recent_commands is empty (fresh
    // session).
    let state = if line.trim().is_empty() {
        if app.recent_commands.is_empty() {
            return;
        }
        let matches: Vec<String> = app
            .recent_commands
            .iter()
            .take(MAX_VISIBLE * 2)
            .cloned()
            .collect();
        crate::app::CmdlineCompleteState {
            head: String::new(),
            matches,
            idx: 0,
            last_shown: String::new(),
        }
    } else {
        // Compute matches fresh each frame. Cheap — N=~150 commands.
        match crate::app::compute_cmdline_completions_for_app(app, &line) {
            Some(s) if s.matches.len() >= 2 => s,
            _ => return,
        }
    };
    // Reset the popup-selected idx when the cmdline content has
    // changed since the last render. Without this, typing in
    // the cmdline leaves the highlight stranded on a row that's
    // no longer first — visually disorienting. We piggyback off
    // cmdline_complete_state.last_shown which the Tab cycle
    // already tracks.
    let prior_line = app
        .cmdline_complete_state
        .as_ref()
        .map(|s| s.last_shown.clone())
        .unwrap_or_default();
    if prior_line != line {
        app.cmdline_popup_selected = 0;
    }

    let total = state.matches.len();
    let visible = total.min(MAX_VISIBLE);

    // 2026-06-19 — polish: show command title alongside id, mark
    // recent rows with ★. Recent-set + per-row title lookup
    // (registry().get) are cheap — one HashMap probe per row.
    let recent_set: std::collections::HashSet<&str> =
        app.recent_commands.iter().map(|s| s.as_str()).collect();
    let id_w = state
        .matches
        .iter()
        .take(visible)
        .map(|m| m.chars().count() as u16)
        .max()
        .unwrap_or(0);
    let title_w = state
        .matches
        .iter()
        .take(visible)
        .filter_map(|m| {
            crate::command::registry()
                .get(m.as_str())
                .map(|c| c.title.chars().count() as u16)
        })
        .max()
        .unwrap_or(0);
    let key_w = state
        .matches
        .iter()
        .take(visible)
        .filter_map(|m| crate::command::registry().get(m.as_str()))
        .map(|c| c.key_hint().chars().count() as u16)
        .max()
        .unwrap_or(0);
    // 2 (marker) + id + 3 (sep) + title + 3 (sep) + key hint
    let needed = 2 + id_w + 3 + title_w + if key_w > 0 { 3 + key_w } else { 0 };
    let inner_w = needed.max(20).min(MAX_WIDTH - 2);
    let box_w = (inner_w + 2).min(cmdline_bar.width);
    // +2 for top + bottom border; +1 if we need the "(N more)" row;
    // +1 for the chord-hint footer (always shown).
    let extra_row = if total > visible { 1 } else { 0 };
    let footer_row = 1;
    let box_h = (visible as u16) + 2 + extra_row + footer_row;
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
    // 2026-06-20 — border color is configurable via Settings →
    // Color row `ui.cmdline_popup_border_color`. Empty string =
    // theme yellow. Invalid hex falls back to theme yellow.
    let border_color =
        parse_hex_color(&app.config.ui.cmdline_popup_border_color).unwrap_or(t.yellow);
    let block_style = Style::default().fg(t.fg).bg(t.bg_darker);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(
            Style::default()
                .fg(border_color)
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
        let title = crate::command::registry()
            .get(match_text.as_str())
            .map(|c| c.title);
        let is_recent = recent_set.contains(match_text.as_str());

        // Marker column: ▸ for selected, ★ for recent (only when
        // not selected — selected wins visually), space otherwise.
        let marker = if is_sel {
            "▸ "
        } else if is_recent {
            "★ "
        } else {
            "  "
        };
        let marker_style = if is_sel {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg3)
                .add_modifier(Modifier::BOLD)
        } else if is_recent {
            Style::default().fg(t.yellow).bg(t.bg_darker)
        } else {
            Style::default().fg(t.comment).bg(t.bg_darker)
        };
        let id_style = if is_sel {
            Style::default()
                .fg(t.fg)
                .bg(t.bg3)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(t.bg_darker)
        };
        let sep_style = Style::default()
            .fg(t.bg3)
            .bg(if is_sel { t.bg3 } else { t.bg_darker });
        let title_style = if is_sel {
            Style::default().fg(t.comment).bg(t.bg3)
        } else {
            Style::default().fg(t.comment).bg(t.bg_darker)
        };

        // Pad the id to id_w so the title column aligns.
        let id_padded = format!("{:<width$}", match_text, width = id_w as usize);
        let mut spans = vec![
            Span::styled(marker.to_string(), marker_style),
            Span::styled(id_padded, id_style),
        ];
        if let Some(t_str) = title {
            spans.push(Span::styled("   ".to_string(), sep_style));
            // Pad title so the key column is right-aligned at
            // inner.width (preserves visual alignment when the
            // title is shorter than title_w).
            let title_padded = format!("{:<width$}", t_str, width = title_w as usize);
            spans.push(Span::styled(title_padded, title_style));
        }
        // Key chord column — right side, dim style. Shows the
        // chord that fires this command if it has one bound.
        let key_hint = crate::command::registry()
            .get(match_text.as_str())
            .map(|c| c.key_hint())
            .unwrap_or_default();
        if !key_hint.is_empty() {
            spans.push(Span::styled("   ".to_string(), sep_style));
            let key_style = if is_sel {
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg3)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_darker)
                    .add_modifier(Modifier::DIM)
            };
            spans.push(Span::styled(key_hint.to_string(), key_style));
        }
        // Pad to inner width so the selected row's bg covers the
        // entire line (no half-painted background on long titles).
        let used: usize = spans.iter().map(|s| s.content.chars().count()).sum();
        if used < inner.width as usize {
            spans.push(Span::styled(
                " ".repeat(inner.width as usize - used),
                if is_sel {
                    Style::default().bg(t.bg3)
                } else {
                    Style::default().bg(t.bg_darker)
                },
            ));
        }

        let row_y = inner.y + offset as u16;
        let row_rect = Rect {
            x: inner.x,
            y: row_y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(spans)).style(Style::default().bg(t.bg_darker)),
            row_rect,
        );
        app.rects.cmdline_popup_items.push((row_rect, idx));
    }

    // "(N more — Tab to cycle)" hint row if truncated.
    if extra_row == 1 {
        let hint = format!("  ({} more — Tab to cycle)", total - visible);
        let truncated: String = hint.chars().take(inner.width as usize).collect();
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
    // 2026-06-20 — chord-hint footer at the bottom of the popup.
    // Shows the keys that work here so first-time users don't
    // have to guess. Right at the bottom-inside-the-border row.
    let footer_y = inner.y + visible as u16 + extra_row;
    let footer = "  Tab/↓ next · Shift+Tab/↑ prev · Enter run · Esc cancel";
    let truncated: String = footer.chars().take(inner.width as usize).collect();
    let footer_rect = Rect {
        x: inner.x,
        y: footer_y,
        width: inner.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            truncated,
            Style::default()
                .fg(t.comment)
                .bg(t.bg_darker)
                .add_modifier(Modifier::DIM),
        )))
        .style(Style::default().bg(t.bg_darker)),
        footer_rect,
    );
}
