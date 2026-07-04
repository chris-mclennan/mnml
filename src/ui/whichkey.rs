//! The which-key popup: a bottom-anchored panel (NvChad-style) listing the key
//! continuations available at the current leader prefix. Group entries show in
//! blue with a `+` prefix; leaf commands in the default fg. Driven entirely by
//! `App::whichkey_menu()`; key handling lives in `tui::dispatch_key`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

/// 2026-06-21 — vim-operator whichkey popup. Same renderer as the
/// leader popup, different title prefix ("Vim: g" instead of
/// "<leader>"). Driven by `App::vim_operator_menu()` which reads
/// the active editor's input handler.
pub fn draw_vim_operators(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some((prefix, entries_raw)) = app.vim_operator_menu() else {
        return;
    };
    // Match the leader popup's shape: (char, &'static str, is_group).
    let entries: Vec<(char, &'static str, bool)> = entries_raw;
    let title = format!(" Vim: {prefix} ");
    draw_popup_with_title(frame, screen, &title, &entries);
}

fn draw_popup_with_title(
    frame: &mut Frame,
    screen: Rect,
    title: &str,
    entries: &[(char, &'static str, bool)],
) {
    let mut entries: Vec<(char, &'static str, bool)> = entries.to_vec();
    entries.sort_by_key(|&(k, _, _)| k);
    let cell_w = entries
        .iter()
        .map(|(_, label, _)| 1 + 3 + label.chars().count() + 2)
        .max()
        .unwrap_or(20)
        .max(12) as u16;
    let avail_w = screen.width.saturating_sub(4).max(cell_w);
    let cols = (avail_w / cell_w).max(1) as usize;
    let rows_n = entries.len().div_ceil(cols).max(1);
    let panel_h = (rows_n as u16 + 3)
        .min(screen.height.saturating_sub(2))
        .max(4);
    let panel_w = screen.width.saturating_sub(2).max(20);
    let area = Rect {
        x: screen.x + (screen.width - panel_w) / 2,
        y: screen.y + screen.height.saturating_sub(panel_h + 1),
        width: panel_w,
        height: panel_h,
    };
    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_panel(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }
    let actual_cols = (inner.width / cell_w).max(1) as usize;
    let actual_rows = entries.len().div_ceil(actual_cols).max(1);
    let mut lines: Vec<Line> = Vec::with_capacity(actual_rows);
    for r in 0..actual_rows {
        let mut spans: Vec<Span> = Vec::new();
        for c in 0..actual_cols {
            let idx = c * actual_rows + r;
            let Some(&(key, label, is_group)) = entries.get(idx) else {
                continue;
            };
            let key_color = if is_group {
                theme::cur().blue
            } else {
                theme::cur().yellow
            };
            let label_color = if is_group {
                theme::cur().blue
            } else {
                theme::cur().fg
            };
            let cell_used = 1 + 3 + label.chars().count();
            let pad = (cell_w as usize).saturating_sub(cell_used);
            spans.push(Span::styled(
                key.to_string(),
                Style::default()
                    .fg(key_color)
                    .bg(theme::cur().bg_darker)
                    .add_modifier(Modifier::BOLD),
            ));
            spans.push(Span::styled(
                " → ",
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg_darker),
            ));
            spans.push(Span::styled(
                label,
                Style::default().fg(label_color).bg(theme::cur().bg_darker),
            ));
            spans.push(Span::styled(
                " ".repeat(pad),
                Style::default().bg(theme::cur().bg_darker),
            ));
        }
        lines.push(Line::from(spans));
    }
    if (lines.len() as u16) < inner.height {
        lines.push(Line::from(Span::styled(
            "  esc to cancel",
            Style::default()
                .fg(theme::cur().grey_fg)
                .bg(theme::cur().bg_darker),
        )));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(theme::cur().bg_darker)),
        inner,
    );
}

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some((prefix, mut entries)) = app.whichkey_menu().map(|(p, e)| (p.to_string(), e)) else {
        return;
    };
    entries.sort_by_key(|&(k, _, _)| k);

    // Lay the entries into columns. Each cell ≈ " k → label  " — size to the widest.
    let cell_w = entries
        .iter()
        .map(|(_, label, _)| 1 /*key*/ + 3 /*" → "*/ + label.chars().count() + 2)
        .max()
        .unwrap_or(20)
        .max(12) as u16;
    let avail_w = screen.width.saturating_sub(4).max(cell_w);
    let cols = (avail_w / cell_w).max(1) as usize;
    let rows_n = entries.len().div_ceil(cols).max(1);

    // Panel: full-ish width, anchored above the statusline, height = rows + borders + title.
    let panel_h = (rows_n as u16 + 3)
        .min(screen.height.saturating_sub(2))
        .max(4);
    let panel_w = screen.width.saturating_sub(2).max(20);
    let area = Rect {
        x: screen.x + (screen.width - panel_w) / 2,
        y: screen.y + screen.height.saturating_sub(panel_h + 1), // sit just above the statusline
        width: panel_w,
        height: panel_h,
    };

    frame.render_widget(Clear, area);
    let title = if prefix.is_empty() {
        " <leader> ".to_string()
    } else {
        format!(" <leader> {prefix} ")
    };
    let block = crate::ui::design_tokens::popup_panel(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let actual_cols = (inner.width / cell_w).max(1) as usize;
    let actual_rows = entries.len().div_ceil(actual_cols).max(1);
    let mut lines: Vec<Line> = Vec::with_capacity(actual_rows);
    for r in 0..actual_rows {
        let mut spans: Vec<Span> = Vec::new();
        for c in 0..actual_cols {
            // Column-major fill so alphabetical keys read top-to-bottom.
            let idx = c * actual_rows + r;
            let Some(&(key, label, is_group)) = entries.get(idx) else {
                continue;
            };
            // Group labels already carry a leading `+` (e.g. "+find").
            let key_color = if is_group {
                theme::cur().blue
            } else {
                theme::cur().yellow
            };
            let label_color = if is_group {
                theme::cur().blue
            } else {
                theme::cur().fg
            };
            let cell_used = 1 + 3 + label.chars().count();
            let pad = (cell_w as usize).saturating_sub(cell_used);
            spans.push(Span::styled(
                key.to_string(),
                Style::default()
                    .fg(key_color)
                    .bg(theme::cur().bg_darker)
                    .add_modifier(Modifier::BOLD),
            ));
            spans.push(Span::styled(
                " → ",
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg_darker),
            ));
            spans.push(Span::styled(
                label,
                Style::default().fg(label_color).bg(theme::cur().bg_darker),
            ));
            spans.push(Span::styled(
                " ".repeat(pad),
                Style::default().bg(theme::cur().bg_darker),
            ));
        }
        lines.push(Line::from(spans));
    }
    // A faint hint row.
    if (lines.len() as u16) < inner.height {
        lines.push(Line::from(Span::styled(
            "  esc to cancel",
            Style::default()
                .fg(theme::cur().grey_fg)
                .bg(theme::cur().bg_darker),
        )));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(theme::cur().bg_darker)),
        inner,
    );
}
