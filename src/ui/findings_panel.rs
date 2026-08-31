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
    style::Style,
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
    // 2026-08-23 (user ask) — apply the `/` filter against each
    // file's rendered relative name (same string the row shows),
    // case-insensitive. Empty filter passes everything through.
    let root = findings_dir(&app.workspace);
    let filter_lc = app.findings_panel_filter.to_ascii_lowercase();
    let files: Vec<std::path::PathBuf> = all_files
        .iter()
        .filter(|p| {
            if filter_lc.is_empty() {
                return true;
            }
            let rel = p.strip_prefix(&root).unwrap_or(p);
            let name = rel.with_extension("").to_string_lossy().into_owned();
            name.to_ascii_lowercase().contains(&filter_lc)
        })
        .cloned()
        .collect();

    // Header — "FINDINGS  (N)" — count is cheap + useful. When
    // the filter is active, show `M of N` (mirrors Notes / TODOs).
    // 2026-08-24 (user ask) — refresh chip in top-right, matching
    // git + todos + notes.
    let subtitle = if filter_lc.is_empty() {
        format!("  ({})", all_files.len())
    } else {
        format!("  ({} of {})", files.len(), all_files.len())
    };
    app.rects.findings_panel_refresh_chip = crate::ui::panel_chrome::draw_caps_header_with_refresh(
        frame,
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
        "FINDINGS",
        Some(&subtitle),
        bg,
        &t,
        app.config.ui.ascii_icons,
    );

    // Filter row (row 1) — mirrors todos_panel exactly: chip bg,
    // magnifier glyph, `/ filter` placeholder, `▏` cursor when
    // focused, `type to filter…` placeholder while focused-empty.
    {
        let y_filter = area.y + 1;
        if y_filter < area.y + area.height {
            let focused = app.findings_panel_filter_focused;
            let bg_chip = crate::ui::panel_chrome::filter_chip_bg(&t);
            let fg_chip = if app.findings_panel_filter.is_empty() && !focused {
                t.comment
            } else {
                t.fg
            };
            let display = if app.findings_panel_filter.is_empty() {
                crate::ui::filter_placeholder::for_state(focused).to_string()
            } else {
                app.findings_panel_filter.clone()
            };
            let cursor = if focused { "\u{258F}" } else { " " };
            let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
            let line = Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    format!("{} ", crate::ui::search_glyph::NERD),
                    Style::default().fg(t.comment).bg(bg_chip),
                ),
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
            app.rects.findings_panel_filter_input = Some(row_rect);
        }
    }

    // R16 design-critic (2026-08-24) — content starts at `area.y + 3`
    // (one blank row under the filter) rather than the `area.y + 2`
    // that NOTES/SESSIONS use. FINDINGS has no `+ New finding` CTA
    // chip to occupy that row, so the blank is deliberate breathing
    // room instead of a missing button. Same call in `todos_panel.rs`.
    let mut y = area.y + 3;

    if files.is_empty() {
        // Distinguish "no files at all" from "filter matched nothing"
        // so the user knows whether the filter is what's hiding rows.
        let empty_msg = if filter_lc.is_empty() {
            "No findings yet.".to_string()
        } else {
            format!(
                "No findings match /{} — {} in workspace",
                app.findings_panel_filter,
                all_files.len()
            )
        };
        crate::ui::empty_state::draw(
            frame,
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: area.height.saturating_sub(y - area.y),
            },
            &empty_msg,
            Some("Stored under .mnml/findings/*.md"),
            bg,
            &t,
        );
        return;
    }

    // Rows — icon + name + right-aligned age (mtime).
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    // `root` computed above alongside the filter — reused here so
    // nested tester-round dirs render `round/foo` instead of
    // losing all context to file_stem.
    #[allow(clippy::explicit_counter_loop)]
    for path in files.iter().take(area.height.saturating_sub(3) as usize) {
        if y >= area.y + area.height {
            break;
        }
        // Relative-to-findings-root name so nested rows keep their
        // round-dir context. Strip the `.md` extension for compactness.
        let rel = path.strip_prefix(&root).unwrap_or(path);
        let name = rel.with_extension("").to_string_lossy().into_owned();
        let name = if name.is_empty() {
            path.file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("finding")
                .to_string()
        } else {
            name
        };
        let icon = if app.config.ui.ascii_icons {
            "◧"
        } else {
            // nf-md-file-search — same glyph as the activity-bar icon.
            "\u{F1623}"
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
                // 3-cell gutter — kept in step across TODOS / FINDINGS
                // / NOTES. Widening one alone is what put TODOS out of
                // line with its siblings before.
                Span::styled("   ", Style::default().bg(bg)),
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
