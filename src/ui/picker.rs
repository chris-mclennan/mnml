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
    let h = screen.height.saturating_sub(4).clamp(7, 22);
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

    // ── list ──
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
        let detail = item.detail.clone();
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
}
