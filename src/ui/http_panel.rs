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

/// Names + collapse-index for the sidebar sections. Indexes match
/// `App::http_panel_section_collapsed`.
const SECTIONS: [(u8, &str); 7] = [
    (0, "FILES"),
    (1, "RECENT"),
    (2, "CAPTURED"),
    (3, "ENVS"),
    (4, "CHAINS"),
    (5, "MOCKS"),
    (6, "COLLECTIONS"),
];

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
    app.rects.http_panel_captured_clear_chip = None;
    app.rects.http_panel_recent_clear_chip = None;
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
    app.rects.http_panel_env_rows.clear();
    app.rects.http_panel_env_new_chip = None;
    app.rects.http_panel_chain_rows.clear();
    app.rects.http_panel_chain_new_chip = None;
    app.rects.http_panel_mock_rows.clear();
    app.rects.http_panel_collection_rows.clear();
    app.rects.http_panel_collection_folder_rows.clear();
    app.rects.http_panel_collection_new_chip = None;
    app.rects.http_panel_import_chip = None;

    let files_len = app.http_panel_files_cache.len();
    let recent_len = app.http_panel_recent_cache.len();
    let captured_len = app.http_panel_captured_cache.len();
    let envs_len = app.http_panel_envs_cache.len();
    let chains_len = app.http_panel_chains_cache.len();
    let mocks_len = app.http_panel_mocks_cache.len();
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

    // Section 4 — ENVS.
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 3, envs_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[3] {
        y = draw_envs(frame, app, y, area, bg);
        if y >= bottom {
            return;
        }
    }
    y += 1;

    // Section 5 — CHAINS.
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 4, chains_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[4] {
        y = draw_chains(frame, app, y, area, bg);
        if y >= bottom {
            return;
        }
    }
    y += 1;

    // Section 6 — MOCKS.
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 5, mocks_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[5] {
        y = draw_mocks(frame, app, y, area, bg);
        if y >= bottom {
            return;
        }
    }
    y += 1;

    // Section 7 — COLLECTIONS.
    let collections_len = app.http_panel_collections_cache.len();
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 6, collections_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[6] {
        y = draw_collections(frame, app, y, area, bg);
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
        y += 1;
    }
    if y < bottom {
        let imp_rect = Rect {
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
                    format!("{arrow} Import\u{2026}"),
                    Style::default().fg(t.cyan).bg(bg),
                ),
            ])),
            imp_rect,
        );
        app.rects.http_panel_import_chip = Some(imp_rect);
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
    ];
    // CAPTURED — prefix with a browser glyph since these come from
    // the browser pane's network log. Ascii mode falls back to no
    // glyph (label alone reads fine).
    let mut label_prefix = String::new();
    if section == 2 && !ascii {
        // Codicon browser — same glyph as the palette-bar's
        // browser-integration chip (`browser.open`). Was Nerd
        // Font firefox (\u{F0239}) which shows a Firefox logo
        // and reads inconsistent with the rest of the app.
        label_prefix = "\u{EB01}  ".to_string();
    }
    spans.push(Span::styled(
        format!("{label_prefix}{label}"),
        Style::default()
            .fg(t.fg)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(
        count_str,
        Style::default().fg(t.comment).bg(bg),
    ));
    // CAPTURED gets two right-aligned chips: "⟳ capture" (start
    // capture) + "✕ clear" (truncate captured.jsonl). RECENT gets
    // one: "✕ clear" (truncate history.jsonl).
    let (capture_chip_text, clear_chip_text) = if ascii {
        (Some("capture"), Some("clear"))
    } else {
        (Some("\u{27F3}  capture"), Some("\u{2715} clear"))
    };
    let has_capture_chip = section == 2;
    let has_clear_chip = section == 1 || section == 2;
    if has_capture_chip || has_clear_chip {
        // Base "used" width: leading pad + chevron + optional glyph
        // prefix + label + count.
        let used = 1
            + chev.chars().count()
            + label_prefix.chars().count()
            + label.chars().count()
            + format!(" ({count})").chars().count();
        let cap_len = if has_capture_chip {
            capture_chip_text
                .map(|s| s.chars().count() + 2)
                .unwrap_or(0)
        } else {
            0
        };
        let clr_len = if has_clear_chip {
            clear_chip_text.map(|s| s.chars().count() + 2).unwrap_or(0)
        } else {
            0
        };
        let chip_gap = if has_capture_chip && has_clear_chip {
            1
        } else {
            0
        };
        let area_w = area.width as usize;
        let need = used
            .saturating_add(cap_len)
            .saturating_add(clr_len)
            .saturating_add(chip_gap)
            .saturating_add(2);
        if need < area_w {
            let pad = area_w
                .saturating_sub(used)
                .saturating_sub(cap_len)
                .saturating_sub(clr_len)
                .saturating_sub(chip_gap)
                .saturating_sub(1);
            spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
            let mut chip_x = (used + pad) as u16;
            if has_capture_chip && let Some(text) = capture_chip_text {
                spans.push(Span::styled(
                    format!(" {text} "),
                    Style::default().fg(t.cyan).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (cap_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                app.rects.http_panel_capture_chip = Some(chip_rect);
                chip_x += cap_len as u16;
                if chip_gap > 0 {
                    spans.push(Span::styled(" ", Style::default().bg(bg)));
                    chip_x += chip_gap as u16;
                }
            }
            if has_clear_chip && let Some(text) = clear_chip_text {
                spans.push(Span::styled(
                    format!(" {text} "),
                    Style::default().fg(t.red).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (clr_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                if section == 1 {
                    app.rects.http_panel_recent_clear_chip = Some(chip_rect);
                } else {
                    app.rects.http_panel_captured_clear_chip = Some(chip_rect);
                }
            }
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
                    Span::styled(
                        "No requests yet — sent requests land here.",
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
                        "Nothing captured — click ⟳ capture with a browser pane focused.",
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

/// ENVS body — one row per env file under `.mnml/env/` +
/// `.rqst/env/`. The currently-active env (either the runtime
/// override or `$MNML_ENV`) renders with a `●` marker; others
/// with `○`. Click a row → set as active. `+ New env` chip at
/// the bottom → prompt for a new env name and create the file.
fn draw_envs(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let envs = app.http_panel_envs_cache.clone();
    let current = app.http_env_override.clone().or_else(|| {
        std::env::var("MNML_ENV")
            .ok()
            .filter(|s| !s.trim().is_empty())
    });
    if envs.is_empty() {
        if y < bottom {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled("No env files yet.", Style::default().fg(t.comment).bg(bg)),
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
    } else {
        for name in envs.iter().take(SECTION_ROW_CAP) {
            if y >= bottom {
                break;
            }
            let is_current = Some(name) == current.as_ref();
            let marker = if is_current { "●" } else { "○" };
            let marker_fg = if is_current { t.green } else { t.comment };
            let name_style = if is_current {
                Style::default()
                    .fg(t.fg)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(t.fg).bg(bg)
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
                    Span::styled(format!("{marker} "), Style::default().fg(marker_fg).bg(bg)),
                    Span::styled(name.clone(), name_style),
                ])),
                row_rect,
            );
            app.rects.http_panel_env_rows.push((row_rect, name.clone()));
            y += 1;
        }
    }
    // `+ New env` action row at the bottom of the section.
    if y < bottom {
        let new_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(
                    "+ New env",
                    Style::default()
                        .fg(t.green)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            new_rect,
        );
        app.rects.http_panel_env_new_chip = Some(new_rect);
        y += 1;
    }
    y
}

/// CHAINS body — one row per `.chain.json` under `.mnml/chains/`.
/// Click a row → run that chain.
fn draw_chains(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let chains = app.http_panel_chains_cache.clone();
    if chains.is_empty() && y < bottom {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled("No chains yet.", Style::default().fg(t.comment).bg(bg)),
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
    for path in chains.iter().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("?")
            .trim_end_matches(".chain.json")
            .to_string();
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled("\u{f085} ", Style::default().fg(t.cyan).bg(bg)),
                Span::styled(name, Style::default().fg(t.fg).bg(bg)),
            ])),
            row_rect,
        );
        app.rects
            .http_panel_chain_rows
            .push((row_rect, path.clone()));
        y += 1;
    }
    // `+ New chain` action row — mirrors the ENVS section idiom so
    // creating a chain is discoverable without palette hunting.
    if y < bottom {
        let new_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(
                    "+ New chain",
                    Style::default()
                        .fg(t.green)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            new_rect,
        );
        app.rects.http_panel_chain_new_chip = Some(new_rect);
        y += 1;
    }
    y
}

/// MOCKS body — one row per `.mock.json` picked up under the
/// workspace (sibling of `.http`/`.curl` files, or under
/// `.mnml/mocks` / `.rqst/mocks`). Click a row → replay that mock
/// into the active Request pane.
fn draw_mocks(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let mocks = app.http_panel_mocks_cache.clone();
    if mocks.is_empty() {
        if y < bottom {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled(
                        "No mocks — `:http.save_mock` on a response.",
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
    for path in mocks.iter().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        let rel = path
            .strip_prefix(&app.workspace)
            .unwrap_or(path)
            .to_string_lossy()
            .into_owned();
        let short = rel.trim_end_matches(".mock.json").to_string();
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled("\u{f0c0} ", Style::default().fg(t.orange).bg(bg)),
                Span::styled(short, Style::default().fg(t.fg).bg(bg)),
            ])),
            row_rect,
        );
        app.rects
            .http_panel_mock_rows
            .push((row_rect, path.clone()));
        y += 1;
    }
    y
}

/// #22 v2 — COLLECTIONS section body. Renders as an expandable
/// tree: folder rows show `▸ auth/` / `▾ auth/` chevrons, files
/// nest under their parent folder with a leading `·` indent per
/// depth level. Left-click a folder row → toggle collapse.
/// Left-click a file row → open as Request pane.
fn draw_collections(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let files = app.http_panel_collections_cache.clone();
    let empty = files.is_empty();
    if empty && y < bottom {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled("No collections yet.", Style::default().fg(t.comment).bg(bg)),
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
    if empty {
        if y < bottom {
            let new_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled(
                        "+ New collection",
                        Style::default()
                            .fg(t.green)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                ])),
                new_rect,
            );
            app.rects.http_panel_collection_new_chip = Some(new_rect);
            y += 1;
        }
        return y;
    }
    let coll_root = app.workspace.join(".mnml").join("collections");
    // Build tree: walk each file's parent chain, register unique
    // dirs, emit rows in depth-first sorted order.
    let mut dir_children: std::collections::BTreeMap<std::path::PathBuf, Vec<std::path::PathBuf>> =
        std::collections::BTreeMap::new();
    let mut dir_subdirs: std::collections::BTreeMap<
        std::path::PathBuf,
        std::collections::BTreeSet<std::path::PathBuf>,
    > = std::collections::BTreeMap::new();
    for path in &files {
        let mut ancestor = path.parent().unwrap_or(&coll_root).to_path_buf();
        dir_children
            .entry(ancestor.clone())
            .or_default()
            .push(path.clone());
        while ancestor != coll_root {
            let parent = ancestor.parent().unwrap_or(&coll_root).to_path_buf();
            dir_subdirs
                .entry(parent.clone())
                .or_default()
                .insert(ancestor.clone());
            if parent == coll_root {
                break;
            }
            ancestor = parent;
        }
    }
    // Walk from root, emitting rows.
    let mut stack: Vec<(std::path::PathBuf, u16)> = vec![(coll_root.clone(), 0)];
    let mut visited: std::collections::HashSet<std::path::PathBuf> =
        std::collections::HashSet::new();
    // Emit in a controlled loop; cap total rows to SECTION_ROW_CAP * 3
    // since the tree has folders + files interleaved.
    let cap = SECTION_ROW_CAP * 3;
    let mut emitted = 0usize;
    while let Some((dir, depth)) = stack.pop() {
        if !visited.insert(dir.clone()) {
            continue;
        }
        if emitted >= cap || y >= bottom {
            break;
        }
        // Emit folder row (skip the root — its label is the section header).
        if dir != coll_root {
            let collapsed = app.http_panel_collections_collapsed_dirs.contains(&dir);
            let chev = if collapsed { "\u{25B8}" } else { "\u{25BE}" };
            let indent = "  ".repeat((depth.saturating_sub(1)) as usize);
            let name = dir
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(format!("   {indent}"), Style::default().bg(bg)),
                    Span::styled(format!("{chev} "), Style::default().fg(t.comment).bg(bg)),
                    Span::styled(
                        format!("\u{f07b} {name}/"),
                        Style::default()
                            .fg(t.yellow)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                ])),
                row_rect,
            );
            app.rects
                .http_panel_collection_folder_rows
                .push((row_rect, dir.clone()));
            y += 1;
            emitted += 1;
            if collapsed || y >= bottom {
                continue;
            }
        }
        // Push subdirs onto stack (reverse for DFS order-preservation).
        if let Some(subs) = dir_subdirs.get(&dir) {
            let mut items: Vec<_> = subs.iter().cloned().collect();
            items.reverse();
            for sub in items {
                stack.push((sub, depth + 1));
            }
        }
        // Emit files in this dir.
        if let Some(kids) = dir_children.get(&dir) {
            for path in kids {
                if emitted >= cap || y >= bottom {
                    break;
                }
                let file_depth = if dir == coll_root { 0 } else { depth };
                let indent = "  ".repeat(file_depth as usize);
                let name = path
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_string();
                let row_rect = Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                };
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled(format!("     {indent}"), Style::default().bg(bg)),
                        Span::styled("\u{f15c} ", Style::default().fg(t.blue).bg(bg)),
                        Span::styled(name, Style::default().fg(t.fg).bg(bg)),
                    ])),
                    row_rect,
                );
                app.rects
                    .http_panel_collection_rows
                    .push((row_rect, path.clone()));
                y += 1;
                emitted += 1;
            }
        }
    }
    if y < bottom {
        let new_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(
                    "+ New collection",
                    Style::default()
                        .fg(t.green)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            new_rect,
        );
        app.rects.http_panel_collection_new_chip = Some(new_rect);
        y += 1;
    }
    y
}

/// Trim a URL to `host + path` (drop scheme + query + fragment) so
/// sidebar rows stay one line. Mirrors the browser pane's convention.
/// Kept `pub(crate)` in case another surface wants to share the
/// same short-form URL rendering.
pub(crate) fn short_url(url: &str) -> String {
    let s = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    s.split(['?', '#']).next().unwrap_or(s).to_string()
}
