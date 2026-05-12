//! The editor pane body: a line-number gutter + the (h-scrolled, truncated)
//! text. P0 renders plain text; P2 overlays tree-sitter spans, indent guides,
//! LSP diagnostics, etc. Returns the on-screen cursor cell so `ui::draw` can
//! place the terminal caret.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    frame.render_widget(Paragraph::new("").style(Style::default().bg(theme::BG_DARK)), area);

    let idx = app.active?;
    let buf = match app.panes.get_mut(idx)? {
        Pane::Editor(b) => b,
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
    let max_scroll = line_count.saturating_sub(text_h.min(line_count));
    buf.scroll = buf.scroll.min(max_scroll);

    // Horizontal scroll — keep the cursor column in view.
    if tw > 0 {
        if cur_col < buf.h_scroll {
            buf.h_scroll = cur_col;
        } else if cur_col >= buf.h_scroll + tw {
            buf.h_scroll = cur_col + 1 - tw;
        }
    }

    let gutter_num_w = gutter_w.saturating_sub(1) as usize;
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
        let bg = if is_cur { theme::LINE } else { theme::BG_DARK };
        let gutter = format!("{:>gutter_num_w$} ", line_no + 1);
        let gutter_style =
            Style::default().fg(if is_cur { theme::FG } else { theme::BASE16_03 }).bg(bg);

        let raw = buf.editor.line_str(line_no);
        let visible: String = raw.chars().skip(buf.h_scroll).take(tw).collect();
        let pad = tw.saturating_sub(visible.chars().count());
        lines.push(Line::from(vec![
            Span::styled(gutter, gutter_style),
            Span::styled(visible, Style::default().fg(theme::FG).bg(bg)),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]));
    }
    frame.render_widget(Paragraph::new(lines), area);

    app.rects.editor_text = Some(Rect { x: text_x, y: area.y, width: text_w, height: area.height });

    // On-screen cursor cell.
    let cy = area.y + (cur_row.saturating_sub(buf.scroll)) as u16;
    let cx = text_x + (cur_col.saturating_sub(buf.h_scroll)) as u16;
    if cy < area.y + area.height && cx < area.x.saturating_add(area.width) {
        Some((cx, cy))
    } else {
        None
    }
}
