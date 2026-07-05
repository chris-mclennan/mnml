//! Renderer for `Pane::HttpHome` — the HTTP "hub" main pane.
//!
//! Layout (top-to-bottom, single scrollable column):
//!
//!   Quick actions row  (three inline chips, wrap if narrow)
//!   Recent   — up to `HOME_ROW_CAP` status-colored rows
//!   Captured — up to `HOME_ROW_CAP` method + short-url rows
//!   Files    — up to `HOME_ROW_CAP` relative paths
//!
//! Reads `App::http_panel_*_cache`; refreshes the caches lazily
//! (first activation) via `App::http_panel_refresh`. Row rects are
//! stashed under `App::http_home_*` for the mouse handler.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

/// Rows shown per section in the dashboard. The sidebar caps at 10;
/// the home pane has more room so it shows a longer list.
const HOME_ROW_CAP: usize = 20;

pub fn draw(frame: &mut Frame, app: &mut App, id: PaneId, area: Rect, focused: bool) {
    if !matches!(app.panes.get(id), Some(Pane::HttpHome(_))) {
        return;
    }
    let t = theme::cur();
    let border_style = if focused {
        Style::default().fg(t.blue)
    } else {
        Style::default().fg(t.bg3)
    };
    let title = format!(
        " HTTP  \u{00B7}  {}  \u{00B7}  r refresh  \u{00B7}  esc back ",
        app.workspace
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "workspace".to_string()),
    );
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 30 || inner.height < 6 {
        return;
    }
    // Register the body for wheel routing.
    app.rects.editor_panes.push((inner, id));

    // Clear per-pane rects; renderer is authoritative for them each
    // frame.
    app.rects.http_home_recent_rows.clear();
    app.rects.http_home_captured_rows.clear();
    app.rects.http_home_files_rows.clear();
    app.rects.http_home_new_chip = None;
    app.rects.http_home_capture_chip = None;
    app.rects.http_home_paste_chip = None;

    // Lazy first-scan populates all three caches at once.
    if !app.http_panel_scanned_once {
        app.http_panel_refresh();
    }

    let scroll = if let Some(Pane::HttpHome(p)) = app.panes.get(id) {
        p.scroll
    } else {
        0
    };
    let ascii = app.config.ui.ascii_icons;

    // We render into a virtual y-coord starting at 0 (relative to
    // `inner.y`) and only paint rows in `[scroll, scroll + inner.height)`.
    // Every rendered row goes through `screen_y` so a row that would
    // land at `bottom` (the y-cell just past the last visible one) is
    // dropped before it can register a rect outside `inner`.
    let mut y_virt: u16 = 0;

    // Quick actions row — three chips separated by "·".
    if let Some(y) = screen_y(inner, y_virt, scroll) {
        draw_quick_actions(frame, app, y, inner, ascii);
    }
    y_virt = y_virt.saturating_add(1);
    // Blank spacer.
    y_virt = y_virt.saturating_add(1);

    // Section: Recent.
    if let Some(y) = screen_y(inner, y_virt, scroll) {
        draw_section_label(frame, "Recent", y, inner);
    }
    y_virt = y_virt.saturating_add(1);
    let recent_snapshot = app.http_panel_recent_cache.clone();
    let taken: Vec<(usize, &serde_json::Value)> = recent_snapshot
        .iter()
        .enumerate()
        .rev()
        .take(HOME_ROW_CAP)
        .collect();
    if taken.is_empty() {
        if let Some(y) = screen_y(inner, y_virt, scroll) {
            draw_empty(frame, "No history yet.", y, inner);
        }
        y_virt = y_virt.saturating_add(1);
    } else {
        for (cache_idx, entry) in taken {
            if let Some(y) = screen_y(inner, y_virt, scroll) {
                let rect = draw_recent_row(frame, entry, y, inner);
                app.rects.http_home_recent_rows.push((rect, cache_idx));
            }
            y_virt = y_virt.saturating_add(1);
        }
    }
    y_virt = y_virt.saturating_add(1);

    // Section: Captured.
    if let Some(y) = screen_y(inner, y_virt, scroll) {
        draw_section_label(frame, "Captured", y, inner);
    }
    y_virt = y_virt.saturating_add(1);
    let captured_snapshot = app.http_panel_captured_cache.clone();
    let cap_taken: Vec<(usize, &crate::http::captured::CapturedRow)> = captured_snapshot
        .iter()
        .enumerate()
        .rev()
        .take(HOME_ROW_CAP)
        .collect();
    if cap_taken.is_empty() {
        if let Some(y) = screen_y(inner, y_virt, scroll) {
            draw_empty(frame, "Nothing captured yet.", y, inner);
        }
        y_virt = y_virt.saturating_add(1);
    } else {
        for (cache_idx, row) in cap_taken {
            if let Some(y) = screen_y(inner, y_virt, scroll) {
                let rect = draw_captured_row(frame, row, y, inner);
                app.rects.http_home_captured_rows.push((rect, cache_idx));
            }
            y_virt = y_virt.saturating_add(1);
        }
    }
    y_virt = y_virt.saturating_add(1);

    // Section: Files.
    if let Some(y) = screen_y(inner, y_virt, scroll) {
        draw_section_label(frame, "Files", y, inner);
    }
    y_virt = y_virt.saturating_add(1);
    let files_snapshot = app.http_panel_files_cache.clone();
    let ws = app.workspace.clone();
    if files_snapshot.is_empty() {
        if let Some(y) = screen_y(inner, y_virt, scroll) {
            draw_empty(frame, "No .http / .curl files.", y, inner);
        }
    } else {
        for path in files_snapshot.iter().take(HOME_ROW_CAP) {
            if let Some(y) = screen_y(inner, y_virt, scroll) {
                let rect = draw_file_row(frame, path, &ws, y, inner, ascii);
                app.rects.http_home_files_rows.push((rect, path.clone()));
            }
            y_virt = y_virt.saturating_add(1);
        }
    }
}

fn visible(y_virt: u16, scroll: u16, height: u16) -> bool {
    y_virt >= scroll && y_virt < scroll + height
}

/// Map a virtual `y_virt` (0 = first content row) into a screen y
/// inside `inner`. Returns `None` if the row would fall outside
/// `inner` — either scrolled off the top or below the last row.
/// Every render site should use this instead of the raw
/// `inner.y + (y_virt - scroll)` subtraction — the reviewer caught
/// that the untyped math + `visible()` guard drift apart when
/// `inner.height` and `bottom` compute rounding boundaries
/// differently.
fn screen_y(inner: Rect, y_virt: u16, scroll: u16) -> Option<u16> {
    if !visible(y_virt, scroll, inner.height) {
        return None;
    }
    let y = inner.y.saturating_add(y_virt.saturating_sub(scroll));
    if y >= inner.y.saturating_add(inner.height) {
        return None;
    }
    Some(y)
}

fn draw_quick_actions(frame: &mut Frame, app: &mut App, y: u16, inner: Rect, ascii: bool) {
    let t = theme::cur();
    let chip1 = "[ + New request ]";
    let cap_glyph = if ascii { "capture" } else { "\u{27F3} capture" };
    let chip2 = format!("[ {cap_glyph} ]");
    let paste_glyph = if ascii {
        "paste curl"
    } else {
        "\u{2193} paste curl"
    };
    let chip3 = format!("[ {paste_glyph} ]");
    let spans = vec![
        Span::styled("  ", Style::default().bg(t.bg)),
        Span::styled(chip1, Style::default().fg(t.green).bg(t.bg)),
        Span::styled("  ", Style::default().bg(t.bg)),
        Span::styled(chip2.clone(), Style::default().fg(t.cyan).bg(t.bg)),
        Span::styled("  ", Style::default().bg(t.bg)),
        Span::styled(chip3.clone(), Style::default().fg(t.cyan).bg(t.bg)),
    ];
    frame.render_widget(
        Paragraph::new(Line::from(spans)),
        Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        },
    );
    // Record clickable rects. Widths approximate — x-offsets follow
    // the "  " padding between spans.
    let mut x = inner.x + 2;
    let w1 = chip1.chars().count() as u16;
    app.rects.http_home_new_chip = Some(Rect {
        x,
        y,
        width: w1,
        height: 1,
    });
    x += w1 + 2;
    let w2 = chip2.chars().count() as u16;
    app.rects.http_home_capture_chip = Some(Rect {
        x,
        y,
        width: w2,
        height: 1,
    });
    x += w2 + 2;
    let w3 = chip3.chars().count() as u16;
    app.rects.http_home_paste_chip = Some(Rect {
        x,
        y,
        width: w3,
        height: 1,
    });
}

fn draw_section_label(frame: &mut Frame, label: &str, y: u16, inner: Rect) {
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(t.bg)),
            Span::styled(
                label.to_string(),
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg)
                    .add_modifier(Modifier::BOLD),
            ),
        ])),
        Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        },
    );
}

fn draw_empty(frame: &mut Frame, msg: &str, y: u16, inner: Rect) {
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("   ", Style::default().bg(t.bg)),
            Span::styled(msg.to_string(), Style::default().fg(t.comment).bg(t.bg)),
        ])),
        Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        },
    );
}

fn draw_recent_row(frame: &mut Frame, entry: &serde_json::Value, y: u16, inner: Rect) -> Rect {
    let t = theme::cur();
    let status = entry.get("status").and_then(|s| s.as_u64()).unwrap_or(0);
    let method = entry
        .get("method")
        .and_then(|s| s.as_str())
        .unwrap_or("GET");
    let url = entry.get("url").and_then(|s| s.as_str()).unwrap_or("");
    let dur = entry
        .get("duration_ms")
        .and_then(|s| s.as_u64())
        .unwrap_or(0);
    let short = super::http_panel::short_url(url);
    let (status_str, status_fg) = if status == 0 {
        ("err ".to_string(), t.red)
    } else if (200..300).contains(&status) {
        (format!("{status} "), t.green)
    } else if (300..400).contains(&status) {
        (format!("{status} "), t.cyan)
    } else if (400..500).contains(&status) {
        (format!("{status} "), t.yellow)
    } else {
        (format!("{status} "), t.red)
    };
    let row_rect = Rect {
        x: inner.x,
        y,
        width: inner.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("   ", Style::default().bg(t.bg)),
            Span::styled(status_str, Style::default().fg(status_fg).bg(t.bg)),
            Span::styled(
                format!("{method:<5} "),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(short, Style::default().fg(t.fg).bg(t.bg)),
            Span::styled(
                format!("   {dur}ms"),
                Style::default().fg(t.comment).bg(t.bg),
            ),
        ])),
        row_rect,
    );
    row_rect
}

fn draw_captured_row(
    frame: &mut Frame,
    row: &crate::http::captured::CapturedRow,
    y: u16,
    inner: Rect,
) -> Rect {
    let t = theme::cur();
    let short = super::http_panel::short_url(&row.url);
    let row_rect = Rect {
        x: inner.x,
        y,
        width: inner.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("   ", Style::default().bg(t.bg)),
            Span::styled(
                format!("{:<5} ", row.method),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(short, Style::default().fg(t.fg).bg(t.bg)),
        ])),
        row_rect,
    );
    row_rect
}

fn draw_file_row(
    frame: &mut Frame,
    path: &std::path::Path,
    workspace: &std::path::Path,
    y: u16,
    inner: Rect,
    ascii: bool,
) -> Rect {
    let t = theme::cur();
    let rel = path
        .strip_prefix(workspace)
        .unwrap_or(path)
        .to_string_lossy()
        .into_owned();
    let icon = if ascii { "\u{2192}" } else { "\u{F1D8}" };
    let row_rect = Rect {
        x: inner.x,
        y,
        width: inner.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("   ", Style::default().bg(t.bg)),
            Span::styled(format!("{icon} "), Style::default().fg(t.blue).bg(t.bg)),
            Span::styled(rel, Style::default().fg(t.fg).bg(t.bg)),
        ])),
        row_rect,
    );
    row_rect
}
