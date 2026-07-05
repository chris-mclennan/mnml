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

    // Discover `.http` / `.curl` files under the workspace. Bounded
    // walk (depth-limited so an unexpectedly-deep tree doesn't stall
    // the render loop). A gitignore-respecting walk lands in a
    // follow-up.
    let files = discover_http_files(&app.workspace);
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

/// Walk the workspace root looking for `.http` / `.curl` files.
/// Depth-bounded to 4 levels — deeper trees are common but hitting
/// them would stall the render loop. A future refactor swaps this
/// for a background-cached list.
fn discover_http_files(root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    walk(root, 0, &mut out);
    out.sort();
    out
}

fn walk(dir: &std::path::Path, depth: u32, out: &mut Vec<std::path::PathBuf>) {
    if depth > 4 || out.len() > 200 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with('.') || name_str == "target" || name_str == "node_modules" {
            continue;
        }
        if path.is_dir() {
            walk(&path, depth + 1, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str())
            && (ext == "http" || ext == "curl" || ext == "rest")
        {
            out.push(path);
        }
    }
}
