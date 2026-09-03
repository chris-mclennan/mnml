//! The fuzzy-picker / command-palette overlay — a centered floating box with a
//! query line on top and the filtered list below. Records hitboxes + the caret
//! position in `app.rects` so the event loop can route mouse + place the cursor.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout as RLayout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    // Geometry.
    //
    // The comment here used to say "clamps may exceed a tiny screen —
    // it'll clip, fine". It does NOT clip: ratatui panics when a widget
    // is rendered outside the buffer, so every picker — `Ctrl+P`
    // included — crashed the process on a terminal under 30 columns
    // (bug-hunt 2026-09-03, measured: 30 ok, 29 and below panic).
    //
    // The 30 floor is a readability preference; the screen width is a
    // hard limit. Take whichever is smaller, and give up the side
    // margin before giving up the box.
    let w = screen
        .width
        .saturating_sub(8)
        .clamp(30, 90)
        .min(screen.width);
    // Height picks between:
    //   · a compact size that just fits the picker's items when small
    //     (3-line action chooser shouldn't be 22 rows tall)
    //   · a generous cap for large lists (12k-glyph icon picker wants
    //     as much screen as it can get)
    // Item count doesn't include the icon-glyphs "+ Create" banner
    // header — but the fudge factor here forgives that small drift.
    let item_count = app.picker.as_ref().map(|p| p.len()).unwrap_or(0);
    let border_and_query_rows: u16 = 3; // borders (2) + query (1)
    let compact = (item_count as u16 + border_and_query_rows).clamp(7, 22);
    let generous = screen
        .height
        .saturating_sub(4)
        .min((screen.height * 4) / 5)
        .max(7);
    // Same hard limit vertically — `generous` has a `.max(7)` floor
    // that can exceed a very short screen for the same reason.
    let h = compact.min(generous).min(screen.height);
    let x = screen.x + (screen.width.saturating_sub(w)) / 2;
    // `[ui] picker_position` — `"top"` drops the box flush with the top
    // edge (the common modern quick-open convention); anything else
    // centers vertically so pickers land in the same spot as every
    // other panel overlay (settings, help, integration edit, glyph
    // builder). Prior default was 1/3 down; the drift between "1/3
    // for pickers, 1/2 for other modals" was the "things appear in
    // different areas" complaint.
    let y = if app.config.ui.picker_position.eq_ignore_ascii_case("top") {
        screen.y
    } else {
        screen.y + (screen.height.saturating_sub(h)) / 2
    };
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    app.rects.picker_box = Some(area);
    app.rects.picker_items.clear();

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::modal_panel(
        app.picker
            .as_ref()
            .map(|p| p.title.as_str())
            .unwrap_or("Picker"),
    );
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let Some(picker) = app.picker.as_mut() else {
        return;
    };
    let rows = RLayout::vertical([Constraint::Length(1), Constraint::Min(1)]).split(inner);
    let (query_area, list_area) = (rows[0], rows[1]);

    // ── query line ──
    // Title moved to the block's title bar; the query row is just
    // the input + item count.
    // #polish 2026-07-06 — counter shows N of M when a filter is
    // narrowing the list; bare N when nothing's filtered.
    let count = picker.len();
    let total = picker.total_len();
    let counter = if picker.query.is_empty() || count == total {
        format!(" {count} ")
    } else {
        format!(" {count} of {total} ")
    };
    let prompt = format!("  {}", picker.query);
    let avail = query_area.width as usize;
    let pad = avail.saturating_sub(counter.chars().count() + prompt.chars().count());
    let panel_bg = theme::cur().bg_dark;
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                prompt.clone(),
                Style::default().fg(theme::cur().fg).bg(panel_bg),
            ),
            Span::styled(" ".repeat(pad), Style::default().bg(panel_bg)),
            Span::styled(
                counter,
                Style::default().fg(theme::cur().comment).bg(panel_bg),
            ),
        ])),
        query_area,
    );
    // Caret sits right after the query text — the row is just
    // [prompt="  "+query][pad][counter], so the caret is at the
    // end of the prompt span.
    let caret_offset = prompt.chars().count() as u16;
    let caret_x = query_area.x + caret_offset.min(query_area.width.saturating_sub(1));
    app.rects.picker_caret = Some((caret_x, query_area.y));

    // ── grid mode (icon glyphs) ──
    if matches!(picker.kind, crate::picker::PickerKind::IconGlyphs) {
        draw_glyph_grid(frame, app, list_area);
        return;
    }

    // ── list mode ──
    // List rendering leaves grid mode off; grid renderer sets it fresh.
    picker.grid_cols = 0;
    let visible = list_area.height as usize;
    // Reserve the scrollbar column BEFORE laying out any row.
    //
    // It used to be reserved after, by narrowing the render rect — so
    // every row was laid out for the full width and then had its last
    // cell clipped. On the message history that ate the final digit of
    // the clock: `04:4` (user report).
    let total_items = picker.items_view().count();
    let needs_sb = total_items > visible && visible > 0;
    let list_area = if needs_sb {
        Rect {
            width: list_area.width.saturating_sub(1),
            ..list_area
        }
    } else {
        list_area
    };
    if picker.selected < picker.scroll {
        picker.scroll = picker.selected;
    } else if picker.selected >= picker.scroll + visible {
        picker.scroll = picker.selected + 1 - visible;
    }
    let scroll = picker.scroll;
    let lw = list_area.width as usize;
    let mut lines: Vec<Line> = Vec::with_capacity(visible);
    for (row, item) in picker.items_view().enumerate().skip(scroll).take(visible) {
        let is_sel = row == picker.selected;
        let bg = if is_sel {
            theme::cur().bg2
        } else {
            theme::cur().bg_dark
        };
        // One cell, no trailing space — see `ui::gutter`. This used
        // to be `"▌ "` / `"  "`, which put a cell and a half of air
        // between the bar and the first character while every panel
        // put none (user report 2026-09-03).
        let marker = crate::ui::gutter::marker(is_sel);
        let marker_w = crate::ui::gutter::WIDTH as usize;
        // render-reviewer N-1 + drive-mnml 2026-06-28: cap detail
        // too — was uncapped, so a long command id like
        // `view.toggle_brackets` got ratatui-clipped mid-word
        // (palette truncation finding). Reserve at least 12 cells
        // for label; let detail use up to half the remaining row.
        let min_label: usize = 12;
        let detail_orig = item.detail.clone();
        let detail_orig_w = detail_orig.chars().count();
        let detail_budget = lw.saturating_sub(marker_w + min_label + 1);
        let detail: String = if detail_orig_w > detail_budget && detail_budget >= 2 {
            let take = detail_budget.saturating_sub(1);
            detail_orig.chars().take(take).collect::<String>() + "…"
        } else if detail_orig_w > detail_budget {
            String::new()
        } else {
            detail_orig
        };
        let dw = detail.chars().count();
        // A detail costs `dw + 2`: one leading space (so the label never
        // butts into the `ⓘ` icon) and one TRAILING space, so the value
        // does not sit flush against the scrollbar or the right border
        // (user 2026-09-03: "can i get an empty char on right side of
        // time and scrollbar too").
        let detail_cost = if dw > 0 { dw + 2 } else { 0 };
        // label gets whatever's left after the marker (2) and the detail.
        let label_avail = lw.saturating_sub(marker_w + detail_cost);
        let label: String = item.label.chars().take(label_avail).collect();
        let used = marker_w + label.chars().count() + detail_cost;
        let gap = lw.saturating_sub(used);
        let mut label_style = Style::default().fg(theme::cur().fg).bg(bg);
        if is_sel {
            label_style = label_style.add_modifier(Modifier::BOLD);
        }
        // #1113 (2026-08-20) — split the label into per-char spans
        // so the fuzzy-match hits paint bold+cyan while everything
        // else keeps the base style. Matched indices are into the
        // ORIGINAL label — intersect with the visible-truncated
        // range so a wide row that got clipped doesn't out-index.
        // Empty hits (no query, or picker kind without match data)
        // fall through to a single-span label — same visual as
        // before this change.
        let hits = picker.matched_indices(row);
        let hit_style = Style::default()
            .fg(theme::cur().cyan)
            .bg(bg)
            .add_modifier(Modifier::BOLD);
        let mut spans: Vec<Span> = Vec::with_capacity(2 + label.chars().count() + 2);
        spans.push(Span::styled(
            marker,
            Style::default().fg(theme::cur().blue).bg(bg),
        ));
        if hits.is_empty() {
            spans.push(Span::styled(label, label_style));
        } else {
            let hit_set: std::collections::HashSet<usize> = hits.iter().copied().collect();
            let mut run = String::new();
            let mut run_hit = false;
            for (idx, ch) in label.chars().enumerate() {
                let is_hit = hit_set.contains(&idx);
                if is_hit != run_hit && !run.is_empty() {
                    spans.push(Span::styled(
                        std::mem::take(&mut run),
                        if run_hit { hit_style } else { label_style },
                    ));
                }
                run_hit = is_hit;
                run.push(ch);
            }
            if !run.is_empty() {
                spans.push(Span::styled(
                    run,
                    if run_hit { hit_style } else { label_style },
                ));
            }
        }
        spans.push(Span::styled(" ".repeat(gap), Style::default().bg(bg)));
        if dw > 0 {
            // A space on BOTH sides. The leading one keeps the label
            // off the `ⓘ` icon (user: "dont let lines run up to the
            // information icon, leave at least 1 col char blank
            // there"); the trailing one keeps the value off the
            // scrollbar and the right border.
            spans.push(Span::styled(
                format!(" {detail} "),
                Style::default().fg(theme::cur().comment).bg(bg),
            ));
        }
        let scr_y = list_area.y + (row - scroll) as u16;
        app.rects.picker_items.push((
            Rect {
                x: list_area.x,
                y: scr_y,
                width: list_area.width,
                height: 1,
            },
            row,
        ));
        lines.push(Line::from(spans));
    }
    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (no matches)",
            Style::default()
                .fg(theme::cur().comment)
                .bg(theme::cur().bg_dark),
        )));
    }
    // A picker SCROLLS but said nothing about it — the list simply ended
    // at whatever fit, exactly like the three activity panels did. The
    // message history is the one that shows it: 200 entries in a
    // 15-row popup, with no cue that 185 more exist (user: "rows go
    // beyond visible length").
    let total = total_items;
    if needs_sb {
        let sb = Rect {
            x: list_area.x + list_area.width,
            y: list_area.y,
            width: 1,
            height: list_area.height,
        };
        crate::ui::scrollbar::paint_simple_scrollbar(
            frame,
            sb,
            &theme::cur(),
            total,
            visible,
            scroll,
        );
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb,
            pane_id: 0,
            total,
            viewport: visible,
            kind: crate::app::ScrollbarKind::Picker,
        });
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(theme::cur().bg_dark)),
        list_area,
    );
}

/// Grid renderer for `PickerKind::IconGlyphs`. Cells are 4 cells wide
/// (1 space + 1 glyph + 2 spaces), so a ~86-col picker fits ~21 glyphs
/// per row and shows hundreds per screen. Below the grid, a footer row
/// prints the selected glyph's full name + `\u{XXXX}` escape.
fn draw_glyph_grid(frame: &mut Frame, app: &mut App, list_area: Rect) {
    let Some(picker) = app.picker.as_mut() else {
        return;
    };
    let t = theme::cur();
    // Cell = ` <glyph> ` — 3 cells wide, symmetric pad. Highlight
    // extends one cell to the LEFT and RIGHT of the glyph.
    let cell_w: usize = 3;
    let cols = (list_area.width as usize / cell_w).max(1);
    picker.grid_cols = cols;

    // Check for the "+ Create custom glyph" pseudo-item at position 0.
    // When present we render it as a full-width banner at the top so
    // it's visually distinct — the grid at 3 cells/tile hides labels
    // and a lone "+" reads as just another glyph tile among 12k.
    let has_new_banner = picker
        .items_view()
        .next()
        .map(|it| it.id == "new")
        .unwrap_or(false);

    // Reserve the bottom row for the "selected: <name>" footer when
    // there's height for it; otherwise use every row for glyphs.
    let has_footer = list_area.height >= 3;
    let banner_rows: u16 = if has_new_banner { 2 } else { 0 };
    let footer_rows: u16 = if has_footer { 1 } else { 0 };
    let grid_h = list_area.height.saturating_sub(banner_rows + footer_rows) as usize;
    let grid_top_y = list_area.y + banner_rows;

    // Grid iterates the picker's items but skips index 0 when the
    // banner is present. `grid_offset` is the index into
    // `items_view()` where the grid starts painting.
    let grid_offset = if has_new_banner { 1 } else { 0 };
    let total = picker.len().saturating_sub(grid_offset);
    let sel_idx_grid = picker.selected.saturating_sub(grid_offset);
    let scroll_grid = picker.scroll.saturating_sub(grid_offset);
    let scroll_rows = scroll_grid / cols;
    let sel_row = sel_idx_grid / cols;
    let scroll_rows = if picker.selected < grid_offset {
        // Selection is on the banner — keep the grid parked at 0.
        0
    } else if sel_row < scroll_rows {
        sel_row
    } else if sel_row >= scroll_rows + grid_h {
        sel_row + 1 - grid_h
    } else {
        scroll_rows
    };
    picker.scroll = scroll_rows * cols + grid_offset;
    let scroll = picker.scroll;
    app.rects.picker_items.clear();

    // Paint the "+ Create custom glyph" banner.
    if has_new_banner {
        let banner_rect = Rect {
            x: list_area.x,
            y: list_area.y,
            width: list_area.width,
            height: 1,
        };
        let is_sel = picker.selected == 0;
        let (fg, bg, marker) = if is_sel {
            (t.bg_dark, t.cyan, "▶")
        } else {
            (t.cyan, t.bg2, " ")
        };
        let style = Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD);
        let label = format!(" {marker} + Create custom glyph…");
        let hint = "Ctrl+N new · Ctrl+E edit existing";
        let inner_w = list_area.width as usize;
        let mid_pad = inner_w.saturating_sub(label.chars().count() + hint.chars().count() + 1);
        let banner_text = format!("{label}{}{hint} ", " ".repeat(mid_pad));
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(banner_text, style))),
            banner_rect,
        );
        // Hitbox for click.
        app.rects.picker_items.push((banner_rect, 0));
        // Blank spacer row so the banner reads distinct from the grid.
        let spacer_rect = Rect {
            x: list_area.x,
            y: list_area.y + 1,
            width: list_area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                " ".repeat(list_area.width as usize),
                Style::default().bg(theme::cur().bg_dark),
            ))),
            spacer_rect,
        );
    }

    // Render each grid cell.
    for row_i in 0..grid_h {
        let row_y = grid_top_y + row_i as u16;
        for col_i in 0..cols {
            let idx = scroll + row_i * cols + col_i;
            if idx >= total + grid_offset {
                break;
            }
            let cell_x = list_area.x + (col_i * cell_w) as u16;
            let cell_rect = Rect {
                x: cell_x,
                y: row_y,
                width: cell_w as u16,
                height: 1,
            };
            let picker_ref = app.picker.as_ref().unwrap();
            let item = picker_ref.items_view().nth(idx).unwrap();
            let glyph_ch = item.label.chars().next().unwrap_or(' ');
            let glyph = glyph_ch.to_string();
            let is_sel = idx == picker_ref.selected;
            // NO background paint. Dim every unselected glyph to the
            // comment color; paint the selected one in bright yellow
            // + bold. The visual contrast comes from the rest of the
            // grid being muted, not from a highlight rectangle. This
            // sidesteps every padding-width alignment trap.
            let (fg, modifier) = if is_sel {
                (ratatui::style::Color::Rgb(255, 255, 255), Modifier::BOLD)
            } else {
                (t.comment, Modifier::empty())
            };
            let style = Style::default().fg(fg).add_modifier(modifier);
            let cell_text = format!(" {glyph} ");
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(cell_text, style))),
                cell_rect,
            );
            app.rects.picker_items.push((cell_rect, idx));
        }
    }

    // Footer with the selected item's name + codepoint.
    if has_footer {
        let picker_ref = app.picker.as_ref().unwrap();
        let footer_y = list_area.y + list_area.height - 1;
        let footer_rect = Rect {
            x: list_area.x,
            y: footer_y,
            width: list_area.width,
            height: 1,
        };
        let footer_text = picker_ref
            .selected_item()
            .map(|it| {
                let g = it.label.chars().next().unwrap_or(' ');
                format!(" {g}  {}   {}", strip_leading_glyph(&it.label), it.detail)
            })
            .unwrap_or_else(|| " (no matches) ".to_string());
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                footer_text,
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::ITALIC),
            ))),
            footer_rect,
        );
    }
}

/// Strip the leading glyph + whitespace from a label like
/// `"  cloud-outline  [cloud]"` → `"cloud-outline  [cloud]"`. The
/// icon picker's `PickerItem.label` is built as
/// `"{glyph}  {name}  [{category}]"` in `open_icon_picker`.
fn strip_leading_glyph(label: &str) -> String {
    let mut chars = label.chars();
    let _glyph = chars.next();
    chars.as_str().trim_start().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::picker::{Picker, PickerItem, PickerKind};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    /// Regression: the query caret must land *after* the typed query, not over
    /// the title. The query line renders `[title][" "]["  "+query]…`, so the
    /// cell immediately left of the caret should be the last query char — never
    /// a character of the "Command palette" title. (Bug: caret was computed as
    /// `x + 2 + query.len`, ignoring the title width, so it sat on the title.)
    #[test]
    fn caret_sits_after_the_query_not_on_the_title() {
        let ws = std::env::temp_dir();
        let mut app = App::new(ws, crate::config::Config::default()).unwrap();
        let mut picker = Picker::new(
            PickerKind::Commands,
            "Command palette",
            vec![PickerItem::new("file.save", "Save file", "ctrl+s")],
        );
        picker.type_char('s');
        app.picker = Some(picker);

        let mut term = Terminal::new(TestBackend::new(100, 30)).unwrap();
        term.draw(|f| draw(f, &mut app, f.area())).unwrap();

        let (cx, cy) = app.rects.picker_caret.expect("picker caret recorded");
        let buf = term.backend().buffer();
        // The cell just before the caret holds the last typed query char.
        assert_eq!(buf[(cx - 1, cy)].symbol(), "s");
    }

    /// render-reviewer N-1 + drive-mnml 2026-06-28: picker detail
    /// column used to overflow as a mid-glyph clip (`view.toggle_brack`
    /// instead of `view.toggle_brackets`). The fix added a budget-
    /// aware `…` cap. Lock the cap so a future refactor can't
    /// regress.
    #[test]
    fn picker_detail_truncates_with_ellipsis_when_overflow() {
        let ws = std::env::temp_dir();
        let mut app = App::new(ws, crate::config::Config::default()).unwrap();
        let picker = Picker::new(
            PickerKind::Commands,
            "Command palette",
            vec![PickerItem::new(
                "view.toggle_brackets",
                "T",
                "view.toggle_brackets_very_long_detail_string",
            )],
        );
        app.picker = Some(picker);

        // 40-cell width — too narrow for the full detail.
        let mut term = Terminal::new(TestBackend::new(40, 10)).unwrap();
        term.draw(|f| draw(f, &mut app, f.area())).unwrap();
        let buf = term.backend().buffer();

        // Scan all rows for "…" — if the cap fired we should see one.
        let mut found_ellipsis = false;
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                if buf[(x, y)].symbol() == "…" {
                    found_ellipsis = true;
                }
            }
        }
        assert!(
            found_ellipsis,
            "expected `…` truncation marker when detail overflows row width"
        );

        // The last few cells of any row must NOT be a non-… char
        // that's a continuation of the detail. (Soft check — the
        // explicit assertion above is the hard one.)
    }
}

#[cfg(test)]
mod detail_gap_tests {
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;

    /// USER REPORT — "dont let lines run up to the information icon,
    /// leave at least 1 col char blank there."
    ///
    /// The Messages popup is a picker whose `detail` is `ⓘ  HH:MM`. The
    /// row budgeted a cell for the gap but emitted it AFTER the detail,
    /// so a full-width label ran flush into the icon.
    #[test]
    fn a_full_width_label_keeps_a_gap_before_its_detail() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let icon = '\u{f05a}';
        // A label far longer than the row, so it is truncated to exactly
        // fill its budget — the case that used to collide.
        let items = vec![crate::picker::PickerItem::new(
            "0".to_string(),
            "x".repeat(400),
            format!("{icon}  18:45"),
        )];
        app.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Messages,
            "Messages (1)".to_string(),
            items,
        ));

        let (w, h) = (80u16, 20u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();

        let mut checked = false;
        for y in 0..h {
            let line: String = (0..w).map(|x| buf[(x, y)].symbol()).collect();
            // CHAR index, not the byte index `find` returns — the row
            // contains multi-byte box-drawing characters, so mixing the
            // two silently compares the wrong cell.
            if let Some(i) = line.chars().position(|c| c == icon) {
                let before: String = line.chars().take(i).collect();
                assert!(
                    before.ends_with(' '),
                    "the label runs flush into the ⓘ icon — no blank cell \
                     before it:\n{line:?}"
                );
                checked = true;
            }
        }
        assert!(checked, "no row carrying the ⓘ icon was rendered at all");
    }
}

#[cfg(test)]
mod picker_scrollbar_tests {
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;

    fn app_with_items(n: usize) -> (tempfile::TempDir, crate::app::App) {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let items: Vec<crate::picker::PickerItem> = (0..n)
            .map(|i| {
                crate::picker::PickerItem::new(
                    i.to_string(),
                    format!("message number {i}"),
                    String::new(),
                )
            })
            .collect();
        app.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Messages,
            format!("Messages ({n})"),
            items,
        ));
        (d, app)
    }

    fn render(app: &mut crate::app::App) {
        let (w, h) = (100u16, 24u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
    }

    /// USER REPORT — "rows go beyond visible length". The picker
    /// scrolled but painted no bar, so 200 messages in a 15-row popup
    /// looked like 15. Same defect the three activity panels had.
    #[test]
    fn a_long_picker_registers_a_scrollbar() {
        let (_d, mut app) = app_with_items(200);
        render(&mut app);
        let hit = app
            .rects
            .scrollbars
            .iter()
            .find(|s| matches!(s.kind, crate::app::ScrollbarKind::Picker))
            .expect("no scrollbar for 200 items — the list just ends");
        assert_eq!(hit.total, 200);
        assert!(
            hit.viewport > 0 && hit.viewport < hit.total,
            "viewport {} vs total {} — a bar that cannot move",
            hit.viewport,
            hit.total
        );
    }

    /// USER REPORT — "the scrollbar is covering up the minutes".
    ///
    /// The bar's column was reserved by narrowing the RENDER rect after
    /// the rows had already been laid out for the full width, so every
    /// row lost its last cell. On the message history, whose detail is
    /// `⚠ HH:MM`, that ate the final digit of the clock: `04:4`.
    #[test]
    fn the_scrollbar_does_not_clip_the_detail_column() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        // Rows shaped like the message log: a long label, and a detail
        // whose LAST character carries meaning — the clock's final digit.
        let items: Vec<crate::picker::PickerItem> = (0..200)
            .map(|i| {
                crate::picker::PickerItem::new(
                    i.to_string(),
                    format!("sonos: install the loopback driver first {i}"),
                    "\u{f071}  04:47".to_string(),
                )
            })
            .collect();
        app.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Messages,
            "Messages (200)".to_string(),
            items,
        ));
        let (w, h) = (100u16, 24u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        let rows: Vec<String> = (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect())
            .collect();
        let hit = rows
            .iter()
            .find(|r| r.contains("04:4"))
            .expect("no row carrying a clock rendered");
        assert!(
            hit.contains("04:47"),
            "the last digit of the clock was clipped by the scrollbar:\n{hit}"
        );
    }

    /// USER 2026-09-03 — "can i get an empty char on right side of time
    /// and scrollbar too". The detail ran flush to the row's right edge,
    /// so the clock touched the scrollbar.
    ///
    /// Checks BOTH cases in one test, because the fix has to hold with
    /// and without a bar: the scrollbar must not be the only thing
    /// providing the gap.
    #[test]
    fn the_detail_never_sits_flush_against_the_right_edge() {
        for (n, bar) in [(200usize, true), (3usize, false)] {
            let d = tempfile::tempdir().unwrap();
            let mut app =
                crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default())
                    .unwrap();
            let items: Vec<crate::picker::PickerItem> = (0..n)
                .map(|i| {
                    crate::picker::PickerItem::new(
                        i.to_string(),
                        format!("sonos: install the loopback driver first {i}"),
                        "\u{f071}  04:47".to_string(),
                    )
                })
                .collect();
            app.open_picker(crate::picker::Picker::new(
                crate::picker::PickerKind::Messages,
                format!("Messages ({n})"),
                items,
            ));
            let (w, h) = (100u16, 24u16);
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                super::draw(
                    f,
                    &mut app,
                    Rect {
                        x: 0,
                        y: 0,
                        width: w,
                        height: h,
                    },
                )
            })
            .unwrap();
            let buf = term.backend().buffer();
            let rows: Vec<String> = (0..h)
                .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect())
                .collect();
            let hit = rows
                .iter()
                .find(|r| r.contains("04:47"))
                .unwrap_or_else(|| panic!("no clock row rendered (bar={bar})"));
            let after: String = hit.split("04:47").nth(1).unwrap_or("").to_string();
            assert!(
                after.starts_with(' '),
                "the clock is flush against what follows it (bar={bar}): {:?}",
                after.chars().take(6).collect::<String>()
            );
        }
    }

    /// USER 2026-09-03 — "why is there a space between the blue gutter
    /// here and the a in auto-update ... in other place we use gutter
    /// its right next to the first char".
    ///
    /// The picker's marker was `"▌ "` while every panel used `"▌"`.
    /// Asserts the label starts in the very next cell after the bar.
    #[test]
    fn the_selected_rows_gutter_touches_the_first_character() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let items: Vec<crate::picker::PickerItem> = (0..5)
            .map(|i| {
                crate::picker::PickerItem::new(
                    i.to_string(),
                    "auto-update: nothing eligible".to_string(),
                    String::new(),
                )
            })
            .collect();
        app.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Messages,
            "Messages (5)".to_string(),
            items,
        ));
        let (w, h) = (80u16, 20u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        let row = (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .find(|r| r.contains(crate::ui::gutter::GLYPH))
            .expect("no selected row rendered");
        // CHAR position, not `str::find`'s byte offset — the row is
        // full of multi-byte box-drawing glyphs, so the two differ.
        let bar = row
            .chars()
            .position(|c| c.to_string() == crate::ui::gutter::GLYPH)
            .expect("gutter glyph vanished");
        let after: String = row.chars().skip(bar + 1).take(12).collect::<String>();
        assert!(
            after.starts_with("auto-update"),
            "the gutter does not touch the first character: {after:?}"
        );
    }

    /// SEV-1, bug-hunt 2026-09-03 — every picker, `Ctrl+P` included,
    /// PANICKED the process on a terminal narrower than 30 columns.
    ///
    /// `w` was clamped to a 30 minimum with a comment claiming a tiny
    /// screen would "clip, fine". ratatui does not clip: rendering
    /// outside the buffer panics.
    ///
    /// ```text
    /// index outside of buffer: the area is Rect { width: 29, .. }
    /// but index is (29, 2)
    /// ```
    #[test]
    fn a_narrow_or_short_terminal_does_not_panic_the_picker() {
        for (w, h) in [
            (29u16, 14u16),
            (26, 14),
            (20, 14),
            (10, 14),
            (1, 14),
            (80, 6),
            (80, 3),
            (80, 1),
            (1, 1),
        ] {
            let d = tempfile::tempdir().unwrap();
            let mut app =
                crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default())
                    .unwrap();
            let items: Vec<crate::picker::PickerItem> = (0..40)
                .map(|i| {
                    crate::picker::PickerItem::new(
                        i.to_string(),
                        format!("some reasonably long entry label {i}"),
                        "detail".to_string(),
                    )
                })
                .collect();
            app.open_picker(crate::picker::Picker::new(
                crate::picker::PickerKind::Files,
                "Files".to_string(),
                items,
            ));
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            // The assertion IS that this does not panic.
            term.draw(|f| {
                super::draw(
                    f,
                    &mut app,
                    Rect {
                        x: 0,
                        y: 0,
                        width: w,
                        height: h,
                    },
                )
            })
            .unwrap_or_else(|e| panic!("picker draw failed at {w}x{h}: {e}"));
        }
    }

    /// The picker's scrollbar was DECORATIVE — it painted, registered
    /// a `ScrollbarHit { kind: Picker }`, and `set_pane_scroll` had a
    /// `ScrollbarKind::Picker` arm — but the picker's mouse branch
    /// handled only `picker_items` and `picker_box` and swallowed
    /// everything else, so `begin_scrollbar_drag` could never run
    /// while a picker was open. Every piece existed; none connected.
    ///
    /// Drives the real mouse dispatcher, not the drag helper — the
    /// defect was entirely in the routing, so calling the helper
    /// directly would pass against the broken build.
    #[test]
    fn dragging_the_picker_scrollbar_scrolls_the_list() {
        use ratatui::crossterm::event::{KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let items: Vec<crate::picker::PickerItem> = (0..300)
            .map(|i| {
                crate::picker::PickerItem::new(i.to_string(), format!("entry {i}"), String::new())
            })
            .collect();
        app.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Files,
            "Files".to_string(),
            items,
        ));
        let (w, h) = (100u16, 30u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();

        let bar = app
            .rects
            .scrollbars
            .iter()
            .find(|hit| matches!(hit.kind, crate::app::ScrollbarKind::Picker))
            .copied()
            .expect("the picker registered no scrollbar hit");
        let before = app.picker.as_ref().unwrap().scroll;

        let ev = |kind, y| MouseEvent {
            kind,
            column: bar.area.x,
            row: y,
            modifiers: KeyModifiers::NONE,
        };
        // Press near the BOTTOM of the bar — that is a large jump from
        // the top, so a no-op is unmistakable.
        let bottom = bar.area.y + bar.area.height - 1;
        crate::tui::mouse::dispatch_mouse(
            &mut app,
            ev(MouseEventKind::Down(MouseButton::Left), bottom),
        );
        assert!(
            app.picker.is_some(),
            "clicking the scrollbar dismissed the picker — it was treated \
             as a click outside the box"
        );
        let after_press = app.picker.as_ref().unwrap().scroll;
        assert_ne!(
            after_press, before,
            "pressing the scrollbar did not scroll the list"
        );

        // A drag back to the top must steer it, and the release end it.
        crate::tui::mouse::dispatch_mouse(
            &mut app,
            ev(MouseEventKind::Drag(MouseButton::Left), bar.area.y),
        );
        assert_eq!(
            app.picker.as_ref().unwrap().scroll,
            0,
            "dragging to the top of the bar did not scroll back to the top"
        );
        crate::tui::mouse::dispatch_mouse(
            &mut app,
            ev(MouseEventKind::Up(MouseButton::Left), bar.area.y),
        );
        assert!(
            app.dragging_scrollbar.is_none(),
            "the scrollbar drag never ended — the bar stays grabbed"
        );
    }

    /// A picker that FITS must not grow a bar.
    #[test]
    fn a_short_picker_has_no_scrollbar() {
        let (_d, mut app) = app_with_items(3);
        render(&mut app);
        assert!(
            !app.rects
                .scrollbars
                .iter()
                .any(|s| matches!(s.kind, crate::app::ScrollbarKind::Picker)),
            "a 3-item picker painted a scrollbar"
        );
    }
}
