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
        ])),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );
    let mut y = area.y + 2;

    // Files come from the cache — populated on first activation.
    // Keeps per-frame stat() calls off the render path.
    if !app.notes_panel_scanned_once {
        app.notes_panel_refresh();
    }
    let files = app.notes_panel_files_cache.clone();
    if files.is_empty() {
        let empty = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled("No notes yet.", Style::default().fg(t.comment).bg(bg)),
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
    } else {
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
                    Span::styled(name, Style::default().fg(t.fg).bg(bg)),
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
