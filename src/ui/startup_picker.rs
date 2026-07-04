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
use ratatui::widgets::{Clear, Paragraph};

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
    // Immediate subdirectories of `[ui] projects_dir`, one row each.
    // Number keys keep ticking up; once we run out (>9 total rows),
    // they show as ` ` so the user knows they have to use ↑↓ + Enter.
    let configured_count = app.config.workspaces.len().min(6);
    for (i, sub) in project_subdirs(app).into_iter().enumerate() {
        let row_idx = 3 + configured_count + i;
        let key = if row_idx < 9 {
            ((b'1' + row_idx as u8) as char).to_string()
        } else {
            " ".to_string()
        };
        let name = sub
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("?")
            .to_string();
        rows.push((key, format!("Open project: {name}")));
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
    let block = crate::ui::design_tokens::modal_panel(title);
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

/// Up to N immediate subdirectories of `[ui] projects_dir`, sorted
/// alphabetically. Empty when the config is unset or the path can't
/// be read. Capped at 6 so the picker doesn't grow unbounded.
pub(crate) fn project_subdirs(app: &App) -> Vec<std::path::PathBuf> {
    const CAP: usize = 6;
    let root = app.config.ui.projects_dir.trim();
    if root.is_empty() {
        return Vec::new();
    }
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out: Vec<std::path::PathBuf> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter(|e| {
            // Skip dotfiles + standard dev clutter the user wouldn't
            // open as a workspace anyway.
            e.file_name()
                .to_str()
                .is_some_and(|n| !n.starts_with('.') && n != "node_modules" && n != "target")
        })
        .map(|e| e.path())
        .collect();
    out.sort();
    out.truncate(CAP);
    out
}

/// How many rows the picker is currently showing — used by key
/// handling to clamp `selected` on up/down.
pub fn row_count(app: &App) -> usize {
    let configured = app.config.workspaces.len().min(6);
    let projects = project_subdirs(app).len();
    3 + configured + projects
}

/// Resolve `selected` index into the action to fire.
pub fn action_for(app: &App, idx: usize) -> Option<StartupPickerAction> {
    let configured = app.config.workspaces.len();
    let configured_capped = configured.min(6);
    match idx {
        0 => Some(StartupPickerAction::NewFile),
        1 => Some(StartupPickerAction::OpenFile),
        2 => Some(StartupPickerAction::OpenFolder),
        n if n < 3 + configured_capped => {
            let ws = n - 3;
            // The user-facing workspace switcher uses 1-based indices
            // where 0 = primary / 1+ = extras. The configured rows in
            // `[[workspaces]]` map to 1-based extras, so add 1.
            Some(StartupPickerAction::SwitchWorkspace(ws + 1))
        }
        n => {
            let proj_idx = n - 3 - configured_capped;
            let subs = project_subdirs(app);
            subs.get(proj_idx)
                .cloned()
                .map(StartupPickerAction::OpenProject)
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
