//! Startup workspace-picker overlay.
//!
//! Shown on launch when mnml is invoked with `--startup-picker` (or
//! the `MNML_STARTUP_PICKER` env var is set). Lets the user pick
//! between:
//!   - New file (in the launched workspace — usually $HOME)
//!   - Open file... (fires `view.discovery` after dismiss)
//!   - One of the configured `[[workspaces]]` rows (1-9 keys)
//!
//! Dismissed via Esc / `q` / Enter on the highlighted row. The
//! main use case is launching from Finder / the mnml.app icon
//! where there's no terminal context to type a workspace path —
//! the launcher exports `MNML_STARTUP_PICKER=1` so users land here
//! instead of being dropped into `$HOME`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::{App, StartupPickerAction};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    let Some(picker) = app.startup_picker.as_ref() else {
        return;
    };
    let t = theme::cur();

    // Build the rows: built-in actions + configured workspaces.
    let mut rows: Vec<(String, String)> = vec![
        (
            "1".to_string(),
            "New file (in current workspace)".to_string(),
        ),
        ("2".to_string(), "Open file…".to_string()),
        ("3".to_string(), "Open folder…".to_string()),
    ];
    for (i, w) in app.config.workspaces.iter().enumerate() {
        if i >= 6 {
            break; // only 1-9 keys, 3 reserved for actions
        }
        let key = (b'4' + i as u8) as char;
        rows.push((key.to_string(), format!("Open: {}", w.name)));
    }

    let title = " Open mnml — Esc to skip ";
    let label_w = rows
        .iter()
        .map(|(_, v)| v.chars().count())
        .max()
        .unwrap_or(40);
    let inner_w = (4 + label_w).max(title.chars().count() + 4);
    let w = (inner_w as u16 + 4).min(screen.width);
    let n_lines = rows.len() as u16 + 2; // header + footer
    let h = (n_lines + 2).min(screen.height);
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 3);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(rows.len() + 2);
    lines.push(Line::from(Span::styled(
        " Pick a workspace or action: ".to_string(),
        Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
    )));
    for (i, (k, v)) in rows.iter().enumerate() {
        let marker = if i == picker.selected { "▸" } else { " " };
        let row_style = if i == picker.selected {
            Style::default().fg(t.cyan).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg)
        };
        lines.push(Line::from(vec![
            Span::raw(format!(" {marker} ")),
            Span::styled(
                format!("[{k}] "),
                Style::default().fg(t.yellow).add_modifier(Modifier::BOLD),
            ),
            Span::styled(v.to_string(), row_style),
        ]));
    }
    lines.push(Line::from(Span::styled(
        " ↑↓ move · Enter select · Esc skip ".to_string(),
        Style::default()
            .fg(t.comment)
            .add_modifier(Modifier::ITALIC),
    )));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

/// How many rows the picker is currently showing — used by key
/// handling to clamp `selected` on up/down.
pub fn row_count(app: &App) -> usize {
    let configured = app.config.workspaces.len().min(6);
    3 + configured
}

/// Resolve `selected` index into the action to fire.
pub fn action_for(app: &App, idx: usize) -> Option<StartupPickerAction> {
    match idx {
        0 => Some(StartupPickerAction::NewFile),
        1 => Some(StartupPickerAction::OpenFile),
        2 => Some(StartupPickerAction::OpenFolder),
        n => {
            let ws = n - 3;
            if ws < app.config.workspaces.len() {
                // The user-facing workspace switcher uses 1-based indices
                // where 0 = primary / 1+ = extras. The configured rows in
                // `[[workspaces]]` map to 1-based extras, so add 1.
                Some(StartupPickerAction::SwitchWorkspace(ws + 1))
            } else {
                None
            }
        }
    }
}

/// Map a number key (`'1'`..='9'`) to a row index, if it's in range.
pub fn row_for_key(app: &App, ch: char) -> Option<usize> {
    if !ch.is_ascii_digit() || ch == '0' {
        return None;
    }
    let idx = (ch as u8 - b'1') as usize;
    if idx < row_count(app) {
        Some(idx)
    } else {
        None
    }
}
