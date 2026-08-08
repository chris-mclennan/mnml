//! Findings activity-bar panel — workspace-scoped tester / review
//! report archive (`.mnml/findings/*.md`).
//!
//! Zero-config cross-project: `cd ~/Projects/mixr && mnml .` picks up
//! `~/Projects/mixr/.mnml/findings/` automatically. Testers write into
//! that dir; the panel surfaces the results for review.
//!
//! v1 scope: flat list of finding files sorted by mtime desc + a
//! filter row. Click a row → opens the markdown in an editor pane.
//! v2 will add right-click actions (archive / delete / mark reviewed).
//!
//! Structurally mirrors `notes_panel` — same file-cache lifecycle,
//! same filter idiom, same click routing.

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
    app.rects.findings_panel_files.clear();
    app.rects.findings_panel_filter_input = None;

    if !app.findings_panel_scanned_once {
        app.findings_panel_refresh();
    }
    let all_files = app.findings_panel_files_cache.clone();
    // No dedicated filter state (v1) — reuse the panel's own filter
    // buffer if we add one later. For now, always show everything.
    let files: Vec<std::path::PathBuf> = all_files.clone();

    // Header — "FINDINGS   (N)" — count is cheap + useful.
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "FINDINGS",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  ({})", files.len()),
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

    if files.is_empty() {
        let empty = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled("No findings yet.", Style::default().fg(t.comment).bg(bg)),
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
                "Stored under .mnml/findings/*.md",
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
        return;
    }

    // Rows — icon + name + right-aligned age (mtime).
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    for path in files.iter().take(area.height.saturating_sub(3) as usize) {
        if y >= area.y + area.height {
            break;
        }
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("finding")
            .to_string();
        let icon = if app.config.ui.ascii_icons {
            "◧"
        } else {
            // nf-md-magnify_scan — same glyph as the activity-bar icon.
            "\u{F1391}"
        };
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
                Span::styled(format!("{icon} "), Style::default().fg(t.cyan).bg(bg)),
                Span::styled(name_padded, Style::default().fg(t.fg).bg(bg)),
                Span::styled(format!(" {age_str}"), Style::default().fg(t.comment).bg(bg)),
            ])),
            row_rect,
        );
        app.rects
            .findings_panel_files
            .push((row_rect, path.clone()));
        y += 1;
    }
}

/// The findings directory for a workspace. Not created eagerly —
/// only when something writes there (test agent, or a future
/// `+ New finding` action).
pub fn findings_dir(workspace: &std::path::Path) -> std::path::PathBuf {
    workspace.join(".mnml").join("findings")
}
