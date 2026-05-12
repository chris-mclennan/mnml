//! The editor pane body: a line-number gutter + the text, with tree-sitter
//! syntax colors, indent guides, current-line highlight, and selection. Renders
//! one leaf into `area`; with splits this is called per leaf. Returns the
//! on-screen cursor cell when `focused`, so `ui::draw` can place the caret.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw_pane(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::BG_DARK)),
        area,
    );

    let tab_w = app.config.editor.tab_width.max(1);
    let Some(Pane::Editor(buf)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let line_count = buf.editor.line_count();
    let gutter_w = (line_count.to_string().len().max(3) + 1) as u16; // "  12 "
    let text_x = area.x + gutter_w;
    let text_w = area.width.saturating_sub(gutter_w);
    let tw = text_w as usize;
    let text_h = area.height as usize;
    let (cur_row, cur_col) = buf.editor.row_col();

    // Vertical scroll — keep the cursor row in view.
    if cur_row < buf.scroll {
        buf.scroll = cur_row;
    } else if cur_row >= buf.scroll + text_h {
        buf.scroll = cur_row + 1 - text_h;
    }
    buf.scroll = buf
        .scroll
        .min(line_count.saturating_sub(text_h.min(line_count)));

    // Horizontal scroll — keep the cursor column in view.
    if tw > 0 {
        if cur_col < buf.h_scroll {
            buf.h_scroll = cur_col;
        } else if cur_col >= buf.h_scroll + tw {
            buf.h_scroll = cur_col + 1 - tw;
        }
    }

    let selection = buf.editor.selection();
    let gutter_num_w = gutter_w.saturating_sub(1) as usize;
    let sel_bg = theme::BASE16_02;
    let guide_fg = theme::BASE16_03;

    let mut lines: Vec<Line> = Vec::with_capacity(text_h);
    for r in 0..text_h {
        let line_no = buf.scroll + r;
        if line_no >= line_count {
            lines.push(Line::from(Span::styled(
                " ".repeat(area.width as usize),
                Style::default().bg(theme::BG_DARK),
            )));
            continue;
        }
        let is_cur = line_no == cur_row;
        let base_bg = if is_cur { theme::LINE } else { theme::BG_DARK };
        let gutter = format!("{:>gutter_num_w$} ", line_no + 1);
        let gutter_style = Style::default()
            .fg(if is_cur { theme::FG } else { theme::BASE16_03 })
            .bg(base_bg);

        // Selection columns on this line.
        let (ls, le) = buf.editor.line_byte_range(line_no);
        let (sel_lo, sel_hi, extend_eol) = match selection {
            Some((lo, hi)) if hi > ls && lo <= le => (
                buf.editor.byte_to_col(lo.clamp(ls, le)),
                buf.editor.byte_to_col(hi.clamp(ls, le)),
                hi > le,
            ),
            _ => (0, 0, false),
        };

        let raw = buf.editor.line_str(line_no);
        let chars: Vec<char> = raw.chars().collect();
        let n = chars.len();
        let indent_cols = chars.iter().take_while(|c| **c == ' ').count();
        let has_content = indent_cols < n;
        let spans_for_line = buf.line_spans(line_no);

        // Per-visible-cell (char, fg, bg), then coalesce into spans.
        let mut cells: Vec<(char, Color, Color)> = Vec::with_capacity(tw);
        for vc in 0..tw {
            let c = buf.h_scroll + vc;
            let in_sel =
                (sel_hi > sel_lo && c >= sel_lo && c < sel_hi) || (extend_eol && c >= sel_lo);
            let bg = if in_sel { sel_bg } else { base_bg };
            let (ch, fg) = if c < n {
                let raw_ch = chars[c];
                if raw_ch == ' ' && has_content && c >= tab_w && c % tab_w == 0 && c < indent_cols {
                    ('│', guide_fg)
                } else {
                    (raw_ch, syntax_color(spans_for_line, c).unwrap_or(theme::FG))
                }
            } else {
                (' ', theme::FG)
            };
            cells.push((ch, fg, bg));
        }

        let mut spans: Vec<Span> = vec![Span::styled(gutter, gutter_style)];
        let mut i = 0;
        while i < cells.len() {
            let (_, fg, bg) = cells[i];
            let mut s = String::new();
            while i < cells.len() && cells[i].1 == fg && cells[i].2 == bg {
                s.push(cells[i].0);
                i += 1;
            }
            spans.push(Span::styled(s, Style::default().fg(fg).bg(bg)));
        }
        lines.push(Line::from(spans));
    }
    frame.render_widget(Paragraph::new(lines), area);

    app.rects.editor_panes.push((
        Rect {
            x: text_x,
            y: area.y,
            width: text_w,
            height: area.height,
        },
        pane_id,
    ));

    if !focused {
        return None;
    }
    let cy = area.y + (cur_row.saturating_sub(buf.scroll)) as u16;
    let cx = text_x + (cur_col.saturating_sub(buf.h_scroll)) as u16;
    if cy < area.y + area.height && cx < area.x.saturating_add(area.width) {
        Some((cx, cy))
    } else {
        None
    }
}

/// Color for char column `c`, picking the innermost (last-pushed) covering span.
fn syntax_color(spans: &[crate::highlight::ColoredSpan], c: usize) -> Option<Color> {
    spans
        .iter()
        .rev()
        .find(|&&(s, e, _)| c >= s && c < e)
        .map(|&(_, _, color)| color)
}
