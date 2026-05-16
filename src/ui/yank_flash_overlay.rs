//! Highlight-on-yank overlay. After any yank op, paints the yanked byte
//! range yellow on top of the editor body for ~200ms (TTL cleared by
//! `App::expire_yank_flashes`). Mirrors Neovim's `vim.highlight.on_yank()`.

use ratatui::Frame;
use ratatui::style::Style;

use crate::app::App;
use crate::flash::{FlashTarget, target_to_screen};
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App) {
    let t = theme::cur();
    let flash_style = Style::default().fg(t.bg_dark).bg(t.yellow);
    let panes: Vec<(ratatui::layout::Rect, crate::layout::PaneId)> =
        app.rects.editor_panes.to_vec();
    for (text_rect, pid) in panes {
        let Some(Pane::Editor(buf)) = app.panes.get(pid) else {
            continue;
        };
        let Some((lo, hi, _)) = buf.yank_flash else {
            continue;
        };
        if lo >= hi {
            continue;
        }
        paint_range(frame, app, buf, text_rect, lo, hi, flash_style);
    }
}

fn paint_range(
    frame: &mut Frame,
    app: &App,
    buf: &crate::buffer::Buffer,
    text_rect: ratatui::layout::Rect,
    lo: usize,
    hi: usize,
    style: Style,
) {
    let scroll = buf.scroll;
    let h_scroll = buf.h_scroll;
    let wrap_w = if app.config.ui.wrap {
        Some(text_rect.width as usize)
    } else {
        None
    };
    let text = buf.editor.text();
    let hi = hi.min(text.len());
    if lo >= hi {
        return;
    }
    let area_right = text_rect.x + text_rect.width;
    let area_bottom = text_rect.y + text_rect.height;
    // Walk char by char in the range; paint each cell at its target screen
    // coords. Newlines advance the row + reset the column.
    let mut row = byte_to_row(text, lo);
    let mut col = byte_to_col(text, lo);
    let buffer = frame.buffer_mut();
    let mut i = lo;
    while i < hi {
        let ch = match text[i..].chars().next() {
            Some(c) => c,
            None => break,
        };
        if ch == '\n' {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }
        let tgt = FlashTarget {
            row,
            col_chars: col,
            label: ch,
        };
        if let Some((x, y)) = target_to_screen(&tgt, text_rect, scroll, h_scroll, wrap_w)
            && x < area_right
            && y < area_bottom
            && let Some(dst) = buffer.cell_mut((x, y))
        {
            // Keep the existing char (don't overwrite the syntax-colored
            // glyph). Just tint the bg.
            let prev_style = dst.style();
            dst.set_style(
                prev_style.bg(style
                    .bg
                    .unwrap_or(prev_style.bg.unwrap_or(ratatui::style::Color::Reset))),
            );
        }
        col += 1;
        i += ch.len_utf8();
    }
}

fn byte_to_row(text: &str, byte: usize) -> usize {
    text[..byte.min(text.len())]
        .bytes()
        .filter(|&b| b == b'\n')
        .count()
}

fn byte_to_col(text: &str, byte: usize) -> usize {
    let byte = byte.min(text.len());
    let line_start = text[..byte].rfind('\n').map(|p| p + 1).unwrap_or(0);
    text[line_start..byte].chars().count()
}
