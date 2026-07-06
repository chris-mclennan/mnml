//! TODOs activity-bar panel — surfaces `TODO` / `FIXME` / `XXX` /
//! `HACK` / `REVIEW` markers found in source-code comments across
//! the workspace. (#9)
//!
//! v1 scope: workspace-wide scan on activation + rescan via
//! `todos.refresh`. One row per hit: `TAG  path:line  title`.
//! Click → jump to the file at that line. Deletion / test-tags /
//! `.mnml/notes/` markdown checkbox integration are follow-ups.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

/// One found marker. Populated by `App::todos_panel_refresh`.
#[derive(Debug, Clone)]
pub struct TodoHit {
    pub tag: &'static str,
    pub path: std::path::PathBuf,
    pub line: u32,
    pub title: String,
}

/// Marker patterns scanned in comments. Case-sensitive, matched
/// followed by non-alphanumeric so `TODOLIST` doesn't false-trip.
pub const MARKERS: &[&str] = &["TODO", "FIXME", "XXX", "HACK", "REVIEW"];

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    app.rects.todos_panel_rows.clear();
    app.rects.todos_panel_refresh_chip = None;

    // Trigger a background rescan the first time this panel appears
    // in a session (todos_hits is empty and no scan yet).
    if !app.todos_panel_scanned_once {
        app.todos_panel_scanned_once = true;
        app.todos_panel_refresh();
    }

    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "TODOs",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  ({} hits)", app.todos_hits.len()),
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
    let mut y = area.y + 2;

    if app.todos_hits.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "No markers found — click ⟳ Rescan below.",
                    Style::default().fg(t.comment).bg(bg),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "Scans for TODO / FIXME / XXX / HACK / REVIEW.",
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    } else {
        for (idx, hit) in app
            .todos_hits
            .iter()
            .enumerate()
            .take(area.height.saturating_sub(4) as usize)
        {
            if y >= area.y + area.height {
                break;
            }
            let rel = hit
                .path
                .strip_prefix(&app.workspace)
                .unwrap_or(&hit.path)
                .to_string_lossy()
                .into_owned();
            let tag_fg = match hit.tag {
                "TODO" => t.blue,
                "FIXME" => t.orange,
                "XXX" | "HACK" => t.red,
                "REVIEW" => t.purple,
                _ => t.comment,
            };
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            let path_line = format!(" {rel}:{}", hit.line);
            let title: String = hit.title.chars().take(40).collect();
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(" ", Style::default().bg(bg)),
                    Span::styled(
                        hit.tag,
                        Style::default()
                            .fg(tag_fg)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(path_line, Style::default().fg(t.comment).bg(bg)),
                    Span::styled(" ", Style::default().bg(bg)),
                    Span::styled(title, Style::default().fg(t.fg).bg(bg)),
                ])),
                row_rect,
            );
            app.rects.todos_panel_rows.push((row_rect, idx));
            y += 1;
        }
        y += 1;
    }

    if y < area.y + area.height {
        let refresh_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    // `⟳` eats its right sidebearing in Nerd Font +
                    // CoreText; a 2-space gap keeps it visually
                    // matched to other action rows in the app.
                    "⟳  Rescan",
                    Style::default()
                        .fg(t.cyan)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            refresh_rect,
        );
        app.rects.todos_panel_refresh_chip = Some(refresh_rect);
    }
}

/// Scan a file for marker patterns in comments. Cheap enough per
/// file for a workspace-wide scan (~200 typical), but skips large
/// files, binaries, and generated dirs.
pub fn scan_file(path: &std::path::Path) -> Vec<TodoHit> {
    let Ok(meta) = std::fs::metadata(path) else {
        return Vec::new();
    };
    if meta.len() > 1024 * 1024 {
        return Vec::new(); // skip huge files
    }
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new(); // non-UTF-8 → binary → skip
    };
    let mut out = Vec::new();
    for (i, line) in content.lines().enumerate() {
        for &tag in MARKERS {
            if let Some(pos) = line.find(tag) {
                // Rough "is this in a comment?" heuristic: at least
                // one comment char (`//`, `#`, `/*`, `--`, `<!--`)
                // appears BEFORE the marker on the same line.
                let prefix = &line[..pos];
                let looks_like_comment = prefix.contains("//")
                    || prefix.contains('#')
                    || prefix.contains("/*")
                    || prefix.contains("--")
                    || prefix.contains("<!--");
                if !looks_like_comment {
                    continue;
                }
                // Confirm word-boundary on the right so `TODOLIST`
                // doesn't match `TODO`.
                let after = line[pos + tag.len()..].chars().next();
                if let Some(c) = after
                    && (c.is_alphanumeric() || c == '_')
                {
                    continue;
                }
                let title: String = line[pos + tag.len()..]
                    .trim_start_matches([':', '(', ')', ' '])
                    .trim()
                    .chars()
                    .take(120)
                    .collect();
                out.push(TodoHit {
                    tag,
                    path: path.to_path_buf(),
                    line: (i + 1) as u32,
                    title,
                });
                break; // one marker per line
            }
        }
    }
    out
}
