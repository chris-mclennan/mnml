//! Notes activity-bar panel — persistent workspace scratch notes
//! (`.mnml/notes/*.md`). (#8)
//!
//! v1 scope: flat list of note files under the workspace's
//! `.mnml/notes/` directory + a `+ New note` action. Click a row →
//! opens the file in an editor pane (goes through the same markdown
//! preview path as any other `.md`). Notes gitignore themselves by
//! default (the `.mnml/` prefix is already common for mnml-scoped
//! files); users can check them in per-workspace by removing them
//! from `.gitignore`.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    app.rects.notes_panel_files.clear();
    app.rects.notes_panel_new_chip = None;
    app.rects.notes_panel_filter_input = None;

    // Files come from the cache — populated on first activation.
    // Keeps per-frame stat() calls off the render path.
    if !app.notes_panel_scanned_once {
        app.notes_panel_refresh();
    }
    let filter_lc = app.notes_panel_filter.to_ascii_lowercase();
    let all_files = app.notes_panel_files_cache.clone();
    let files: Vec<std::path::PathBuf> = if filter_lc.is_empty() {
        all_files.clone()
    } else {
        all_files
            .iter()
            .filter(|p| {
                p.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase()
                    .contains(&filter_lc)
            })
            .cloned()
            .collect()
    };

    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "NOTES",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                if filter_lc.is_empty() {
                    String::new()
                } else {
                    format!("  ({} of {})", files.len(), all_files.len())
                },
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
        ])),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );
    // Filter row (row 1). Same idiom as HTTP / Agents / TODOs.
    {
        let y_filter = area.y + 1;
        if y_filter < area.y + area.height {
            let focused = app.notes_panel_filter_focused;
            let bg_chip = t.bg2;
            let fg_chip = if app.notes_panel_filter.is_empty() && !focused {
                t.comment
            } else {
                t.fg
            };
            let display = if app.notes_panel_filter.is_empty() {
                if focused {
                    "type to filter\u{2026}".to_string()
                } else {
                    "/ filter".to_string()
                }
            } else {
                app.notes_panel_filter.clone()
            };
            let cursor = if focused { "\u{258F}" } else { " " };
            let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
            let line = Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled("\u{F0349} ", Style::default().fg(t.comment).bg(bg_chip)),
                Span::styled(display, Style::default().fg(fg_chip).bg(bg_chip)),
                Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_chip)),
                Span::styled(" ".repeat(pad), Style::default().bg(bg_chip)),
                Span::styled(" ", Style::default().bg(bg)),
            ]);
            let row_rect = Rect {
                x: area.x,
                y: y_filter,
                width: area.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects.notes_panel_filter_input = Some(row_rect);
        }
    }
    let mut y = area.y + 3;

    if files.is_empty() && !filter_lc.is_empty() {
        let empty = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                "No matches — try clearing the filter (Esc).",
                Style::default().fg(t.comment).bg(bg),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(empty),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    } else if files.is_empty() {
        let empty = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                "No notes yet — click + New note below.",
                Style::default().fg(t.comment).bg(bg),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(empty),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
        let hint = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                "Stored under .mnml/notes/*.md",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(hint),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    } else {
        // #polish 2026-07-06 — right-aligned age column. Users
        // reported it was hard to find "the note I edited yesterday"
        // among many notes — surfacing mtime does that at a glance.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        for path in files.iter().take(area.height.saturating_sub(4) as usize) {
            if y >= area.y + area.height {
                break;
            }
            let name = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("note")
                .to_string();
            let icon = if app.config.ui.ascii_icons {
                "◧"
            } else {
                "\u{F249}"
            };
            // Age string from file mtime — falls back to empty on
            // any I/O error (rare; usually missing metadata).
            let age_str: String = std::fs::metadata(path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| {
                    let secs = now.saturating_sub(d.as_secs() as i64);
                    crate::ui::git_graph_view::humanize_age(secs)
                })
                .unwrap_or_default();
            let name_width = (area.width as usize)
                .saturating_sub(4)
                .saturating_sub(age_str.chars().count())
                .saturating_sub(1);
            let name_clipped: String = name.chars().take(name_width).collect();
            let name_padded = format!("{name_clipped:<width$}", width = name_width);
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("  ", Style::default().bg(bg)),
                    Span::styled(format!("{icon} "), Style::default().fg(t.yellow).bg(bg)),
                    Span::styled(name_padded, Style::default().fg(t.fg).bg(bg)),
                    Span::styled(format!(" {age_str}"), Style::default().fg(t.comment).bg(bg)),
                ])),
                row_rect,
            );
            app.rects.notes_panel_files.push((row_rect, path.clone()));
            y += 1;
        }
        y += 1;
    }

    if y < area.y + area.height {
        let new_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "+ New note",
                    Style::default()
                        .fg(t.green)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            new_rect,
        );
        app.rects.notes_panel_new_chip = Some(new_rect);
    }
}

pub fn notes_dir(workspace: &std::path::Path) -> std::path::PathBuf {
    workspace.join(".mnml").join("notes")
}
