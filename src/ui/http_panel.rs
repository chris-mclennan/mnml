//! HTTP activity-bar panel — sectioned sidebar for the workspace's
//! HTTP surface. Collapsible sections + bottom action row.
//!
//! Sections (in order):
//!   1. FILES     — `.http` / `.curl` / `.rest` / `.chain.json` under
//!      the workspace. Click → open as `Pane::Request`.
//!   2. RECENT    — most-recent entries from `.rqst/history.jsonl`.
//!      Click → rebuild curl via `history::entry_to_curl` and open a
//!      scratch `.curl` for re-firing.
//!   3. CAPTURED  — most-recent rows from `.rqst/captured/log.jsonl`
//!      (populated by `mnml proxy` / `http.capture_now`). Click →
//!      `CapturedRow::to_curl` + scratch (mirrors the
//!      `http.view_captured` picker's behavior).
//!
//! Bottom actions: `+ New request`, `↓ Paste curl…`.
//!
//! Caches live on `App` (`http_panel_files_cache`,
//! `http_panel_recent_cache`, `http_panel_captured_cache`) and refresh
//! lazily via `App::http_panel_refresh` on first activation.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

/// Names + collapse-index for the three sections. Indexes match
/// `App::http_panel_section_collapsed`.
const SECTIONS: [(u8, &str); 3] = [(0, "FILES"), (1, "RECENT"), (2, "CAPTURED")];

/// Max body rows per section. Anything past this is truncated; the
/// palette (`http.history`, `http.view_captured`) is the full-list
/// surface.
const SECTION_ROW_CAP: usize = 10;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    app.rects.http_panel_files.clear();
    app.rects.http_panel_recent_rows.clear();
    app.rects.http_panel_captured_rows.clear();
    app.rects.http_panel_section_headers.clear();
    app.rects.http_panel_new_chip = None;
    app.rects.http_panel_capture_chip = None;
    app.rects.http_panel_discover_chip = None;

    // Top header — matches the other activity panels' idiom.
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

    // Lazy first-scan populates all three caches at once.
    if !app.http_panel_scanned_once {
        app.http_panel_refresh();
    }
    let files_len = app.http_panel_files_cache.len();
    let recent_len = app.http_panel_recent_cache.len();
    let captured_len = app.http_panel_captured_cache.len();
    let ascii = app.config.ui.ascii_icons;

    let mut y = area.y + 2;
    let bottom = area.y + area.height;

    // Section 1 — FILES.
    y = draw_section_header(frame, app, y, area, bg, ascii, 0, files_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[0] {
        y = draw_files(frame, app, y, area, bg, ascii);
        if y >= bottom {
            return;
        }
    }
    y += 1; // spacer

    // Section 2 — RECENT.
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 1, recent_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[1] {
        y = draw_recent(frame, app, y, area, bg);
        if y >= bottom {
            return;
        }
    }
    y += 1;

    // Section 3 — CAPTURED.
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 2, captured_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[2] {
        y = draw_captured(frame, app, y, area, bg);
        if y >= bottom {
            return;
        }
    }
    y += 1;

    // Bottom action row — always visible, pinned at whatever y we've
    // reached. If the sections filled the whole panel we still tried
    // to reserve a row via the section renderers' clip-checks.
    if y + 1 < bottom {
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
        y += 1;
    }
    if y < bottom {
        let disc_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let arrow = if ascii { "v" } else { "\u{2193}" };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    format!("{arrow} Paste curl\u{2026}"),
                    Style::default().fg(t.cyan).bg(bg),
                ),
            ])),
            disc_rect,
        );
        app.rects.http_panel_discover_chip = Some(disc_rect);
    }
}

/// Render one section header (`▼ NAME (count)` + optional right-side
/// chip for CAPTURED's `⟳` start-capture). Returns the next `y`.
#[allow(clippy::too_many_arguments)]
fn draw_section_header(
    frame: &mut Frame,
    app: &mut App,
    y: u16,
    area: Rect,
    bg: ratatui::style::Color,
    ascii: bool,
    section: u8,
    count: usize,
) -> u16 {
    let t = theme::cur();
    let collapsed = app.http_panel_section_collapsed[section as usize];
    let chev = if ascii {
        if collapsed { "> " } else { "v " }
    } else if collapsed {
        "\u{25B6} "
    } else {
        "\u{25BC} "
    };
    let label = SECTIONS
        .iter()
        .find(|(i, _)| *i == section)
        .map(|(_, n)| *n)
        .unwrap_or("");
    let count_str = format!(" ({count})");
    let mut spans = vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(chev, Style::default().fg(t.comment).bg(bg)),
        Span::styled(
            label,
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(count_str, Style::default().fg(t.comment).bg(bg)),
    ];
    // CAPTURED gets a right-aligned "⟳ capture" chip that runs
    // `http.capture_now` on click.
    if section == 2 {
        let chip_text = if ascii { "capture" } else { "\u{27F3} capture" };
        // Pad so the chip aligns to the right edge (approximate — full
        // right-align would need width math on the label above).
        let used = 1
            + chev.chars().count()
            + label.chars().count()
            + format!(" ({count})").chars().count();
        let chip_len = chip_text.chars().count() + 2;
        // Reviewer catch: the `pad` computation is `area.width - used - chip_len - 1`,
        // which underflows on usize if the sidebar is resized narrower than the
        // header + chip need. Compute defensively so a mid-drag narrow sidebar
        // doesn't panic the render thread — just drops the chip in that frame.
        let area_w = area.width as usize;
        let need = used.saturating_add(chip_len).saturating_add(2);
        if need < area_w {
            let pad = area_w
                .saturating_sub(used)
                .saturating_sub(chip_len)
                .saturating_sub(1);
            spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
            spans.push(Span::styled(
                format!(" {chip_text} "),
                Style::default().fg(t.cyan).bg(bg),
            ));
            let chip_x = (used + pad) as u16;
            let chip_rect = Rect {
                x: area.x + chip_x,
                y,
                width: (chip_len as u16).min(area.width.saturating_sub(chip_x)),
                height: 1,
            };
            app.rects.http_panel_capture_chip = Some(chip_rect);
        }
    }
    let hdr_rect = Rect {
        x: area.x,
        y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(Paragraph::new(Line::from(spans)), hdr_rect);
    // Whole header row is the collapse-toggle target (minus the chip
    // rect, which mouse routing checks first).
    app.rects
        .http_panel_section_headers
        .push((hdr_rect, section));
    y + 1
}

/// FILES body — one row per `.http` / `.curl` (and friends) under the
/// workspace.
fn draw_files(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
    ascii: bool,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let files = app.http_panel_files_cache.clone();
    if files.is_empty() {
        if y < bottom {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled(
                        "No .http / .curl files.",
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
        }
        return y;
    }
    let icon = if ascii { "\u{2192}" } else { "\u{F1D8}" };
    for path in files.iter().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        let rel = path
            .strip_prefix(&app.workspace)
            .unwrap_or(path)
            .to_string_lossy()
            .into_owned();
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(format!("{icon} "), Style::default().fg(t.blue).bg(bg)),
                Span::styled(rel, Style::default().fg(t.fg).bg(bg)),
            ])),
            row_rect,
        );
        app.rects.http_panel_files.push((row_rect, path.clone()));
        y += 1;
    }
    y
}

/// RECENT body — one row per history entry (most-recent-first).
/// Format: `<status> <METHOD> <short-url>`.
fn draw_recent(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let recent = app.http_panel_recent_cache.clone();
    if recent.is_empty() {
        if y < bottom {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled("No history yet.", Style::default().fg(t.comment).bg(bg)),
                ])),
                Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                },
            );
            y += 1;
        }
        return y;
    }
    // Cache is oldest-first; reverse so newest shows at the top.
    for (idx, entry) in recent.iter().enumerate().rev().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        let status = entry.get("status").and_then(|s| s.as_u64()).unwrap_or(0);
        let method = entry
            .get("method")
            .and_then(|s| s.as_str())
            .unwrap_or("GET");
        let url = entry.get("url").and_then(|s| s.as_str()).unwrap_or("");
        let short = short_url(url);
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
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(status_str, Style::default().fg(status_fg).bg(bg)),
                Span::styled(
                    format!("{method:<4} "),
                    Style::default()
                        .fg(t.cyan)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(short, Style::default().fg(t.fg).bg(bg)),
            ])),
            row_rect,
        );
        app.rects.http_panel_recent_rows.push((row_rect, idx));
        y += 1;
    }
    y
}

/// CAPTURED body — one row per proxy-captured request.
fn draw_captured(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let captured = app.http_panel_captured_cache.clone();
    if captured.is_empty() {
        if y < bottom {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled(
                        "Nothing captured yet.",
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
        }
        return y;
    }
    for (idx, row) in captured.iter().enumerate().rev().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        let short = short_url(&row.url);
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(
                    format!("{:<4} ", row.method),
                    Style::default()
                        .fg(t.cyan)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(short, Style::default().fg(t.fg).bg(bg)),
            ])),
            row_rect,
        );
        app.rects.http_panel_captured_rows.push((row_rect, idx));
        y += 1;
    }
    y
}

/// Trim a URL to `host + path` (drop scheme + query + fragment) so
/// sidebar rows stay one line. Mirrors the browser pane's convention.
/// Shared with `http_home_view` so both surfaces render the same way.
pub(crate) fn short_url(url: &str) -> String {
    let s = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    s.split(['?', '#']).next().unwrap_or(s).to_string()
}
