//! HTTP activity-bar panel — vertical list of `.http` / `.curl`
//! files under the workspace + a `+ New request` action row.
//!
//! Rendered when `ActivitySection::Http` is active (#10). v1 scope:
//!   - Header + workspace-scoped file discovery (bounded, gitignore-aware
//!     is a follow-up).
//!   - Row click routes through `open_path`, which opens the file as a
//!     `Pane::Request` via the extension → pane-kind mapping.
//!   - `+ New request` action creates a stub `.http` in the workspace
//!     root and opens it.

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
    app.rects.http_panel_files.clear();
    app.rects.http_panel_new_chip = None;

    // Header.
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "HTTP",
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

    // Files come from the cache — populated lazily on first
    // activation, refreshed via a future `http.refresh` command.
    // Keeps per-frame FS syscalls off the render path.
    if !app.http_panel_scanned_once {
        app.http_panel_refresh();
    }
    let files = app.http_panel_files_cache.clone();
    if files.is_empty() {
        let empty = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                "No .http / .curl files.",
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
    } else {
        for path in files.iter().take(area.height.saturating_sub(4) as usize) {
            if y >= area.y + area.height {
                break;
            }
            let rel = path
                .strip_prefix(&app.workspace)
                .unwrap_or(path)
                .to_string_lossy()
                .into_owned();
            let icon = if app.config.ui.ascii_icons {
                "⚡"
            } else {
                "\u{F0E7}"
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
                    Span::styled(rel, Style::default().fg(t.fg).bg(bg)),
                ])),
                row_rect,
            );
            app.rects.http_panel_files.push((row_rect, path.clone()));
            y += 1;
        }
        y += 1;
    }

    // `+ New request` action row.
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
                    "+ New request",
                    Style::default()
                        .fg(t.green)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            new_rect,
        );
        app.rects.http_panel_new_chip = Some(new_rect);
    }
}
