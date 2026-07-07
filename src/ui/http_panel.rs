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
    app.rects.http_panel_filter_input = None;
    app.rects.http_panel_capture_chip = None;
    app.rects.http_panel_captured_clear_chip = None;
    app.rects.http_panel_captured_refresh_chip = None;
    app.rects.http_panel_section_chips.clear();
    app.rects.http_panel_recent_clear_chip = None;
    app.rects.http_panel_discover_chip = None;
    app.rects.http_panel_icon_buttons.clear();
    app.rects.http_panel_collection_new_request_chips.clear();

    // Top header — HTTP label on the left, toolbar chips on the
    // right (mirrors the file-tree pattern). Order left→right:
    // ↺ refresh · ↕ collapse/expand all.
    let all_collapsed = app.http_panel_section_collapsed.iter().all(|c| *c);
    let toolbar_chips: [(&str, &str, &str); 2] = [
        ("\u{EB37}", "↺", "http.refresh"),
        (
            if all_collapsed {
                "\u{F0AB4}"
            } else {
                "\u{EAC5}"
            },
            if all_collapsed { "↧" } else { "↕" },
            "http.toggle_collapse_all",
        ),
    ];
    const CHIP_W: usize = 3;
    let width = area.width as usize;
    let label = "HTTP";
    let label_used = 1 + label.chars().count(); // leading space + "HTTP"
    let chip_count = toolbar_chips.len();
    let chips_used = chip_count * CHIP_W;
    let pad = width.saturating_sub(label_used + chips_used);
    let mut header_spans: Vec<Span<'static>> = Vec::new();
    header_spans.push(Span::styled(" ", Style::default().bg(bg)));
    header_spans.push(Span::styled(
        label,
        Style::default()
            .fg(t.comment)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    header_spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
    let cluster_start_x = area.x + (label_used + pad) as u16;
    for (i, (glyph_nerd, glyph_ascii, cmd_id)) in toolbar_chips.iter().enumerate() {
        let glyph = if app.config.ui.ascii_icons {
            *glyph_ascii
        } else {
            *glyph_nerd
        };
        header_spans.push(Span::styled(
            format!(" {glyph} "),
            Style::default().fg(t.cyan).bg(bg),
        ));
        app.rects.http_panel_icon_buttons.push((
            Rect {
                x: cluster_start_x + (i * CHIP_W) as u16,
                y: area.y,
                width: CHIP_W as u16,
                height: 1,
            },
            *cmd_id,
        ));
    }
    frame.render_widget(
        Paragraph::new(Line::from(header_spans)),
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

    // Filter input on row 1 (immediately under the HTTP header).
    // Matches the Agents / Cloud Agents panel treatment — same
    // "`/ filter`" placeholder, same focus / typing / Esc idiom.
    let mut y = area.y + 1;
    let bottom = area.y + area.height;
    if y < bottom {
        let focused = app.http_panel_filter_focused;
        let bg_chip = t.bg2;
        let fg_chip = if app.http_panel_filter.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        let display = if app.http_panel_filter.is_empty() {
            if focused {
                "type to filter\u{2026}".to_string()
            } else {
                "/ filter".to_string()
            }
        } else {
            app.http_panel_filter.clone()
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
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(line), row_rect);
        app.rects.http_panel_filter_input = Some(row_rect);
        y += 1;
    }

    // #polish 2026-07-06 — sections reordered so the primary
    // surface (COLLECTIONS) is at the top and runtime history
    // (RECENT / CAPTURED) is at the bottom. Section indices in
    // `http_panel_section_collapsed` are unchanged — this only
    // affects render order.

    // Section (idx=6) — COLLECTIONS. Primary surface.
    let collections_len = app.http_panel_collection_roots.len();
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

    // Section (idx=0) — FILES (stragglers). Only rendered when
    // there are loose `.http` files not in any collection.
    if files_len > 0 {
        if y >= bottom {
            return;
        }
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
        y += 1;
    }

    // Section (idx=3) — ENVS.
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

    // Section (idx=4) — CHAINS.
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

    // Section (idx=5) — MOCKS.
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

    // Section (idx=1) — RECENT (runtime activity).
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

    // Section (idx=2) — CAPTURED (runtime activity).
    if y >= bottom {
        return;
    }
    y = draw_section_header(frame, app, y, area, bg, ascii, 2, captured_len);
    if y >= bottom {
        return;
    }
    if !app.http_panel_section_collapsed[2] {
        y = draw_captured(frame, app, y, area, bg, ascii);
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
    // #polish 2026-07-07 — dropped the decorative browser glyph
    // that used to prefix the CAPTURED label. User read it as
    // "click here to launch a browser" — the actual action lives
    // on the `capture` chip to the right of the label, so a
    // pre-label glyph implied an action that wasn't there.
    let label_prefix = String::new();
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
    // #polish 2026-07-07 — swapped the ⟳ (refresh) glyph for the
    // codicon browser globe. `⟳` implied re-fetch / retry semantics,
    // but the chip's job is "open a browser pane and start
    // capturing its network log" — a globe reads that more
    // directly.
    // #polish 2026-07-07 — always render as icons; the panel is
    // usually 24–32 cells wide so labeled chips crowded the row and
    // the width-dependent degradation read inconsistently. Tooltips
    // (see HoverChip::HttpCapture* variants) surface the label on
    // hover, matching VS Code's file-tree toolbar convention.
    // Order left→right on CAPTURED: filter · refresh · capture · clear.
    // Codicon glyphs — larger + more consistent stroke weight than
    // the small nerd-font/unicode versions that shipped first.
    //   filter  → EB83 codicon filter
    //   refresh → EB37 codicon refresh (same glyph used up in the
    //             panel-wide HTTP header toolbar)
    //   capture → EB01 codicon browser
    //   clear   → EA76 codicon close
    let (filter_icon, refresh_icon, capture_icon, clear_icon, new_icon) = if ascii {
        ("/", "r", "c", "x", "+")
    } else {
        ("\u{EB83}", "\u{EB37}", "\u{EB01}", "\u{EA76}", "\u{EA60}")
    };
    // Per-section chip layout (2026-07-07 user request):
    //   CHAINS       (4) — filter
    //   MOCKS        (5) — filter + refresh + clear-filter
    //   COLLECTIONS  (6) — filter + refresh + clear-filter + new
    //   RECENT       (1) — filter + refresh + clear-log
    //   CAPTURED     (2) — filter + refresh + capture + clear-log
    let has_capture_chip = section == 2;
    // `+ new` chip on any create-capable section — COLLECTIONS (6)
    // gets it as of 7637a67; ENVS (3) gets it in this polish pass so
    // all create-capable sections converge on the header-chip pattern
    // (2026-07-07 design-critic finding #1). CHAINS (4) stays filter-
    // only per earlier user ask.
    let has_new_chip = matches!(section, 3 | 6);
    let has_clear_chip = matches!(section, 1 | 2 | 5 | 6);
    let has_refresh_chip = matches!(section, 1 | 2 | 5 | 6);
    let has_filter_chip = matches!(section, 1..=6);
    if has_capture_chip || has_clear_chip || has_refresh_chip || has_filter_chip || has_new_chip {
        // Base "used" width: leading pad + chevron + optional glyph
        // prefix + label + count.
        let used = 1
            + chev.chars().count()
            + label_prefix.chars().count()
            + label.chars().count()
            + format!(" ({count})").chars().count();
        // Each chip renders as ` <text> ` (text + 2 pad) with a 1-cell
        // gap between adjacent pairs.
        let chip_len = |text: &str| text.chars().count() + 2;
        let area_w = area.width as usize;
        // Progressive drop-order when the full cluster doesn't fit
        // (SEV-2 2026-07-07): drop lowest-priority chip first
        // (Clear → Refresh → Filter → New → Capture) so the
        // section's primary action always survives. Was: all-or-
        // nothing hide, so 4-chip sections (CAPTURED / COLLECTIONS)
        // silently lost `🌐 capture` / `+ new` — the whole point of
        // those sections — at default panel widths.
        let mut want_filter = has_filter_chip;
        let mut want_refresh = has_refresh_chip;
        let mut want_capture = has_capture_chip;
        let mut want_clear = has_clear_chip;
        let mut want_new = has_new_chip;
        let compute_need = |wf: bool, wr: bool, wc: bool, wx: bool, wn: bool| -> usize {
            let n = [wf, wr, wc, wx, wn].iter().filter(|b| **b).count();
            let gaps = n.saturating_sub(1);
            let mut sum = used + gaps + 2;
            if wf {
                sum += chip_len(filter_icon);
            }
            if wr {
                sum += chip_len(refresh_icon);
            }
            if wc {
                sum += chip_len(capture_icon);
            }
            if wx {
                sum += chip_len(clear_icon);
            }
            if wn {
                sum += chip_len(new_icon);
            }
            sum
        };
        // Drop order priority — least-important first. Uses indices
        // over the (filter, refresh, capture, clear, new) tuple to
        // avoid the borrow-checker headache of aliased `&mut bool`s
        // in a single array literal.
        let drop_order: &[u8] = &[3, 1, 0, 4, 2]; // Clear, Refresh, Filter, New, Capture
        for &kind in drop_order {
            if compute_need(
                want_filter,
                want_refresh,
                want_capture,
                want_clear,
                want_new,
            ) < area_w
            {
                break;
            }
            match kind {
                0 => want_filter = false,
                1 => want_refresh = false,
                2 => want_capture = false,
                3 => want_clear = false,
                4 => want_new = false,
                _ => {}
            }
        }
        let (filter_text, refresh_text, capture_text, clear_text, new_text) = (
            if want_filter { filter_icon } else { "" },
            if want_refresh { refresh_icon } else { "" },
            if want_capture { capture_icon } else { "" },
            if want_clear { clear_icon } else { "" },
            if want_new { new_icon } else { "" },
        );
        // Recompute gap_count for what actually renders (some chips
        // may have been dropped above); the pad computation later
        // uses this.
        let gap_count = [
            want_filter,
            want_refresh,
            want_capture,
            want_clear,
            want_new,
        ]
        .iter()
        .filter(|b| **b)
        .count()
        .saturating_sub(1);
        // Shadow the earlier has_* so downstream render code checks
        // what we ACTUALLY draw.
        let has_filter_chip = want_filter;
        let has_refresh_chip = want_refresh;
        let has_capture_chip = want_capture;
        let has_clear_chip = want_clear;
        let has_new_chip = want_new;
        if !refresh_text.is_empty()
            || !capture_text.is_empty()
            || !clear_text.is_empty()
            || !new_text.is_empty()
        {
            let ref_len = if has_refresh_chip {
                chip_len(refresh_text)
            } else {
                0
            };
            let cap_len = if has_capture_chip {
                chip_len(capture_text)
            } else {
                0
            };
            let clr_len = if has_clear_chip {
                chip_len(clear_text)
            } else {
                0
            };
            let filt_len = if has_filter_chip {
                chip_len(filter_text)
            } else {
                0
            };
            let new_len = if has_new_chip { chip_len(new_text) } else { 0 };
            let pad = area_w
                .saturating_sub(used)
                .saturating_sub(filt_len)
                .saturating_sub(ref_len)
                .saturating_sub(cap_len)
                .saturating_sub(clr_len)
                .saturating_sub(new_len)
                .saturating_sub(gap_count)
                .saturating_sub(1);
            spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
            let mut chip_x = (used + pad) as u16;
            if has_filter_chip {
                spans.push(Span::styled(
                    format!(" {filter_text} "),
                    Style::default().fg(t.cyan).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (filt_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                app.rects.http_panel_section_chips.push((
                    chip_rect,
                    section,
                    crate::app::HttpChipKind::Filter,
                ));
                chip_x += filt_len as u16;
                if has_refresh_chip || has_capture_chip || has_clear_chip {
                    spans.push(Span::styled(" ", Style::default().bg(bg)));
                    chip_x += 1;
                }
            }
            if has_refresh_chip {
                spans.push(Span::styled(
                    format!(" {refresh_text} "),
                    Style::default().fg(t.cyan).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (ref_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                app.rects.http_panel_section_chips.push((
                    chip_rect,
                    section,
                    crate::app::HttpChipKind::Refresh,
                ));
                chip_x += ref_len as u16;
                if has_capture_chip || has_clear_chip {
                    spans.push(Span::styled(" ", Style::default().bg(bg)));
                    chip_x += 1;
                }
            }
            if has_capture_chip {
                spans.push(Span::styled(
                    format!(" {capture_text} "),
                    Style::default().fg(t.cyan).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (cap_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                app.rects.http_panel_capture_chip = Some(chip_rect);
                app.rects.http_panel_section_chips.push((
                    chip_rect,
                    section,
                    crate::app::HttpChipKind::Capture,
                ));
                chip_x += cap_len as u16;
                if has_clear_chip {
                    spans.push(Span::styled(" ", Style::default().bg(bg)));
                    chip_x += 1;
                }
            }
            if has_clear_chip {
                // #polish 2026-07-07 (design-critic #4) — red ✕
                // reserved for the two sections where "clear" is
                // genuinely destructive (truncate the .jsonl log).
                // MOCKS / COLLECTIONS wire ✕ to a safe "clear the
                // panel filter" fallback; painting it in cyan (same
                // as filter/refresh) removes the false "danger"
                // signal red carries elsewhere in the app.
                let clear_fg = match section {
                    1 | 2 => t.red,
                    _ => t.cyan,
                };
                spans.push(Span::styled(
                    format!(" {clear_text} "),
                    Style::default().fg(clear_fg).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (clr_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                if section == 1 {
                    app.rects.http_panel_recent_clear_chip = Some(chip_rect);
                } else if section == 2 {
                    app.rects.http_panel_captured_clear_chip = Some(chip_rect);
                }
                app.rects.http_panel_section_chips.push((
                    chip_rect,
                    section,
                    crate::app::HttpChipKind::Clear,
                ));
                chip_x += clr_len as u16;
                if has_new_chip {
                    spans.push(Span::styled(" ", Style::default().bg(bg)));
                    chip_x += 1;
                }
            }
            if has_new_chip {
                spans.push(Span::styled(
                    format!(" {new_text} "),
                    Style::default().fg(t.green).bg(bg),
                ));
                let chip_rect = Rect {
                    x: area.x + chip_x,
                    y,
                    width: (new_len as u16).min(area.width.saturating_sub(chip_x)),
                    height: 1,
                };
                app.rects.http_panel_section_chips.push((
                    chip_rect,
                    section,
                    crate::app::HttpChipKind::New,
                ));
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
    let filter_lc = app.http_panel_filter.to_ascii_lowercase();
    for path in files.iter().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        let rel = path
            .strip_prefix(&app.workspace)
            .unwrap_or(path)
            .to_string_lossy()
            .into_owned();
        if !filter_lc.is_empty() && !rel.to_ascii_lowercase().contains(&filter_lc) {
            continue;
        }
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
    let filter_lc = app.http_panel_filter.to_ascii_lowercase();
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
        if !filter_lc.is_empty() {
            let hay = format!("{method} {url}").to_ascii_lowercase();
            if !hay.contains(&filter_lc) {
                continue;
            }
        }
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
    ascii: bool,
) -> u16 {
    let t = theme::cur();
    let bottom = area.y + area.height;
    let captured = app.http_panel_captured_cache.clone();
    if captured.is_empty() {
        if y < bottom {
            // #polish 2026-07-07 (design-critic #9) — mirror the
            // chip-glyph degrade: ascii mode shows the same letter
            // (`c`) the CAPTURED chip renders, so users on a font
            // without codicon glyphs aren't told to click a tofu.
            let capture_hint = if ascii { "c" } else { "\u{EB01}" };
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled(
                        format!(
                            "Nothing captured yet — click {capture_hint} capture on this row to dump entries from the browser pane."
                        ),
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
    let filter_lc = app.http_panel_filter.to_ascii_lowercase();
    for (idx, row) in captured.iter().enumerate().rev().take(SECTION_ROW_CAP) {
        if y >= bottom {
            break;
        }
        if !filter_lc.is_empty() {
            let hay = format!("{} {}", row.method, row.url).to_ascii_lowercase();
            if !hay.contains(&filter_lc) {
                continue;
            }
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
        let filter_lc = app.http_panel_filter.to_ascii_lowercase();
        for name in envs.iter().take(SECTION_ROW_CAP) {
            if y >= bottom {
                break;
            }
            if !filter_lc.is_empty() && !name.to_ascii_lowercase().contains(&filter_lc) {
                continue;
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
    let filter_lc = app.http_panel_filter.to_ascii_lowercase();
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
        if !filter_lc.is_empty() && !name.to_ascii_lowercase().contains(&filter_lc) {
            continue;
        }
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                // Extra space after the `\u{f085}` cogs glyph — it
                // renders wide + tight against the following char in
                // Nerd Font / CoreText combos, eating the single-space
                // gap other rows use. Doubled here so the chain name
                // isn't glued to the icon. 2026-07-07.
                Span::styled("\u{f085}  ", Style::default().fg(t.cyan).bg(bg)),
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
    let filter_lc = app.http_panel_filter.to_ascii_lowercase();
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
        if !filter_lc.is_empty() && !short.to_ascii_lowercase().contains(&filter_lc) {
            continue;
        }
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

/// #polish 2026-07-06 — COLLECTIONS section body. Walks
/// `http_panel_collection_roots` and paints one collapsible row
/// per collection (🗂 hidden or 📁 in-tree), then the collection's
/// request files indented below when expanded. Left-click a
/// collection row → toggle collapse. Left-click a file row →
/// open as Request pane.
fn draw_collections(
    frame: &mut Frame,
    app: &mut App,
    mut y: u16,
    area: Rect,
    bg: ratatui::style::Color,
) -> u16 {
    use crate::app::HttpCollectionKind;
    let t = theme::cur();
    let bottom = area.y + area.height;
    let roots = app.http_panel_collection_roots.clone();
    let files = app.http_panel_collections_cache.clone();
    if roots.is_empty() {
        if y < bottom {
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
    // Emit each collection root. In-tree first (what teammates
    // share via git), then hidden (per-user scratches).
    let mut order: Vec<(std::path::PathBuf, HttpCollectionKind)> = roots.clone();
    order.sort_by(|a, b| match (a.1, b.1) {
        (HttpCollectionKind::InTree, HttpCollectionKind::Hidden) => std::cmp::Ordering::Less,
        (HttpCollectionKind::Hidden, HttpCollectionKind::InTree) => std::cmp::Ordering::Greater,
        _ => a.0.cmp(&b.0),
    });
    let cap = SECTION_ROW_CAP * 3;
    let mut emitted = 0usize;
    let filter_lc = app.http_panel_filter.to_ascii_lowercase();
    for (root, kind) in &order {
        if emitted >= cap || y >= bottom {
            break;
        }
        // Collection row: chevron + icon + name + (count).
        let mut collapsed = app.http_panel_collections_collapsed_dirs.contains(root);
        let name = root
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        // Filter shape (VS Code-style): if the collection name
        // matches, show all its members; otherwise show only members
        // that themselves match. Skip the collection entirely when
        // nothing matches. An active filter also force-expands the
        // collection so hits are visible without an extra click.
        let name_hits = filter_lc.is_empty() || name.to_ascii_lowercase().contains(&filter_lc);
        let all_members: Vec<&std::path::PathBuf> =
            files.iter().filter(|p| p.starts_with(root)).collect();
        let members: Vec<&std::path::PathBuf> = if name_hits {
            all_members.clone()
        } else {
            all_members
                .iter()
                .copied()
                .filter(|p| {
                    p.strip_prefix(root)
                        .map(|r| r.to_string_lossy().to_ascii_lowercase())
                        .unwrap_or_default()
                        .contains(&filter_lc)
                })
                .collect()
        };
        if !filter_lc.is_empty() && !name_hits && members.is_empty() {
            continue;
        }
        if !filter_lc.is_empty() {
            collapsed = false;
        }
        let chev = if collapsed { "\u{25B8}" } else { "\u{25BE}" };
        let icon = match kind {
            HttpCollectionKind::InTree => "\u{f07b}", // nf-fa-folder
            HttpCollectionKind::Hidden => "\u{f114}", // nf-fa-folder-o (hollow)
        };
        let icon_fg = match kind {
            HttpCollectionKind::InTree => t.yellow,
            HttpCollectionKind::Hidden => t.comment,
        };
        let count = members.len();
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        // Reserve trailing 3 cells for the `+ new request` chip.
        // Compute the visible width taken by the row content so we
        // pad correctly. Everything before the chip:
        //   "   " (3) + chev (2) + icon (2) + name (chars) + " (N)"
        let used = 3 + 2 + 2 + name.chars().count() + format!(" ({count})").chars().count();
        let chip_w: usize = 3;
        let pad = (area.width as usize).saturating_sub(used + chip_w);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(format!("{chev} "), Style::default().fg(t.comment).bg(bg)),
                Span::styled(format!("{icon} "), Style::default().fg(icon_fg).bg(bg)),
                Span::styled(
                    name.clone(),
                    Style::default()
                        .fg(t.fg)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!(" ({count})"), Style::default().fg(t.comment).bg(bg)),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
                Span::styled(" + ", Style::default().fg(t.green).bg(bg)),
            ])),
            row_rect,
        );
        // Registered rects: the ROW itself for click-to-collapse
        // AND the `+` chip zone at the row's right edge. Order
        // matters — mouse dispatch checks the chip vec first.
        let chip_x = area.x + area.width.saturating_sub(chip_w as u16);
        app.rects.http_panel_collection_new_request_chips.push((
            Rect {
                x: chip_x,
                y,
                width: chip_w as u16,
                height: 1,
            },
            root.clone(),
        ));
        app.rects
            .http_panel_collection_folder_rows
            .push((row_rect, root.clone()));
        y += 1;
        emitted += 1;
        if collapsed || y >= bottom {
            continue;
        }
        // Files under this root — one row each, indented. Relative
        // paths shown when the file's in a nested subdir.
        for path in &members {
            if emitted >= cap || y >= bottom {
                break;
            }
            let rel = path
                .strip_prefix(root)
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| {
                    path.file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("")
                        .to_string()
                });
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("       ", Style::default().bg(bg)),
                    Span::styled("\u{f15c} ", Style::default().fg(t.blue).bg(bg)),
                    Span::styled(rel, Style::default().fg(t.fg).bg(bg)),
                ])),
                row_rect,
            );
            app.rects
                .http_panel_collection_rows
                .push((row_rect, (*path).clone()));
            y += 1;
            emitted += 1;
        }
    }
    // #polish 2026-07-07 — bottom "+ New collection" row removed;
    // the header `+` chip now hosts the same action for populated
    // COLLECTIONS. The empty-state branch above still paints its own
    // hint row with a `+ New collection` fallback so users landing on
    // an empty section still see the affordance.
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
