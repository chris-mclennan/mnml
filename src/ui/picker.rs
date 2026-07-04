//! The fuzzy-picker / command-palette overlay — a centered floating box with a
//! query line on top and the filtered list below. Records hitboxes + the caret
//! position in `app.rects` so the event loop can route mouse + place the cursor.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout as RLayout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    // Geometry: capped (clamps may exceed a tiny screen — it'll clip, fine).
    let w = screen.width.saturating_sub(8).clamp(30, 90);
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
    let h = compact.min(generous);
    let x = screen.x + (screen.width.saturating_sub(w)) / 2;
    // `[ui] picker_position` — `"top"` drops the box flush with the top
    // edge (the common modern quick-open convention); anything else
    // floats it a third of the way down (the historic default).
    let y = if app.config.ui.picker_position.eq_ignore_ascii_case("top") {
        screen.y
    } else {
        screen.y + (screen.height.saturating_sub(h)) / 3
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
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(
            Style::default()
                .fg(theme::cur().blue)
                .bg(theme::cur().bg_darker),
        )
        .style(Style::default().bg(theme::cur().bg_darker));
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

    // ── title + query line ──
    let count = picker.len();
    let title = format!(" {} ", picker.title);
    let counter = format!(" {count} ");
    let prompt = format!("  {}", picker.query);
    let title_cols = title.chars().count();
    let avail = query_area.width as usize;
    let pad = avail.saturating_sub(title_cols + counter.chars().count() + prompt.chars().count());
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                title,
                Style::default()
                    .fg(theme::cur().bg_darker)
                    .bg(theme::cur().blue)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ", Style::default().bg(theme::cur().bg_darker)),
            Span::styled(
                prompt.clone(),
                Style::default()
                    .fg(theme::cur().fg)
                    .bg(theme::cur().bg_darker),
            ),
            Span::styled(" ".repeat(pad), Style::default().bg(theme::cur().bg_darker)),
            Span::styled(
                counter,
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg_darker),
            ),
        ])),
        query_area,
    );
    // Caret: just after the prompt text. The query line renders as
    // [title][" "][prompt="  "+query][pad][counter], so the caret must skip the
    // title span + separator space + the prompt's leading indent, not just "  ".
    let caret_offset = title_cols as u16 + 1 + prompt.chars().count() as u16;
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
            theme::cur().bg_darker
        };
        let marker = if is_sel { "▌ " } else { "  " };
        // render-reviewer N-1 + drive-mnml 2026-06-28: cap detail
        // too — was uncapped, so a long command id like
        // `view.toggle_brackets` got ratatui-clipped mid-word
        // (palette truncation finding). Reserve at least 12 cells
        // for label; let detail use up to half the remaining row.
        let min_label: usize = 12;
        let detail_orig = item.detail.clone();
        let detail_orig_w = detail_orig.chars().count();
        let detail_budget = lw.saturating_sub(2 + min_label + 1);
        let detail: String = if detail_orig_w > detail_budget && detail_budget >= 2 {
            let take = detail_budget.saturating_sub(1);
            detail_orig.chars().take(take).collect::<String>() + "…"
        } else if detail_orig_w > detail_budget {
            String::new()
        } else {
            detail_orig
        };
        let dw = detail.chars().count();
        // label gets whatever's left after the marker (2) and the detail + a space.
        let label_avail = lw.saturating_sub(2 + if dw > 0 { dw + 1 } else { 0 });
        let label: String = item.label.chars().take(label_avail).collect();
        let used = 2 + label.chars().count() + if dw > 0 { dw + 1 } else { 0 };
        let gap = lw.saturating_sub(used);
        let mut label_style = Style::default().fg(theme::cur().fg).bg(bg);
        if is_sel {
            label_style = label_style.add_modifier(Modifier::BOLD);
        }
        let mut spans = vec![
            Span::styled(marker, Style::default().fg(theme::cur().blue).bg(bg)),
            Span::styled(label, label_style),
            Span::styled(" ".repeat(gap), Style::default().bg(bg)),
        ];
        if dw > 0 {
            spans.push(Span::styled(
                format!("{detail} "),
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
                .bg(theme::cur().bg_darker),
        )));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(theme::cur().bg_darker)),
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
                Style::default().bg(theme::cur().bg_darker),
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
                    .bg(t.bg_darker)
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
