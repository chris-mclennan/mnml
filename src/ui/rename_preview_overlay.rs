//! Inline-rename preview overlay (inc-rename.nvim style). While an
//! `lsp.rename` prompt is open, paint the prompt's current text inline at
//! every whole-word occurrence of the original identifier in the active
//! editor. Single-file MVP — cross-file effect is still shown by the
//! post-accept `RenamePreview` picker.

use ratatui::Frame;
use ratatui::style::{Modifier, Style};

use crate::app::App;
use crate::flash::target_to_screen;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App) {
    let Some(state) = app.rename_preview_state.as_ref() else {
        return;
    };
    // Need an active rename prompt + a non-empty new name; otherwise this is
    // a no-op (the user is browsing or just opened the prompt).
    let Some(prompt) = app.prompt.as_ref() else {
        return;
    };
    if !matches!(prompt.kind, crate::prompt::PromptKind::LspRename) {
        return;
    }
    let new_text = prompt.input.trim();
    if new_text.is_empty() || new_text == state.original_word {
        return;
    }
    let Some((text_rect, _)) = app
        .rects
        .editor_panes
        .iter()
        .find(|(_, p)| *p == state.pane_id)
        .copied()
    else {
        return;
    };
    let buf = match app.panes.get(state.pane_id) {
        Some(crate::pane::Pane::Editor(b)) => b,
        _ => return,
    };
    let scroll = buf.scroll;
    let h_scroll = buf.h_scroll;
    let wrap_w = if app.config.ui.wrap {
        Some(text_rect.width as usize)
    } else {
        None
    };

    let t = theme::cur();
    let new_style = Style::default()
        .fg(t.bg_dark)
        .bg(t.green)
        .add_modifier(Modifier::BOLD);

    let buffer = frame.buffer_mut();
    let area = text_rect;
    let new_chars: Vec<char> = new_text.chars().collect();
    let new_len = new_chars.len();

    // Resolve every occurrence to screen coords up front, then sort
    // right-to-left so each paint operates on an unmodified region of
    // the buffer. This matters when the same identifier appears more
    // than once on a single visible line — the rightmost occurrence
    // shifts its trailing region (untouched) first; the next one to
    // its left then shifts a region that already includes the
    // rightmost paint, so the cumulative line-stretch lands
    // correctly. Without right-to-left order, the second paint would
    // bulldoze the first one's shifted content.
    let mut targets: Vec<(u16, u16, usize)> = state
        .occurrences
        .iter()
        .filter_map(|&(row, col_chars, orig_len)| {
            let target = crate::flash::FlashTarget {
                row,
                col_chars,
                label: ' ',
            };
            let (x, y) = target_to_screen(&target, area, scroll, h_scroll, wrap_w)?;
            Some((y, x, orig_len))
        })
        .collect();
    targets.sort_by_key(|t| std::cmp::Reverse((t.0, t.1)));

    for (y, x_start, orig_len) in targets {
        if y < area.y || y >= area.y.saturating_add(area.height) {
            continue;
        }
        let line_end = area.x.saturating_add(area.width);

        // 2026-06-08 nvchad hunt SEV-2 fix: when the replacement is
        // longer than the original, slide the trailing line content
        // right by the delta so the new identifier doesn't bulldoze
        // the chars after it. Walk right-to-left so each source cell
        // is read before being overwritten by an incoming shift.
        // Cells that would land past the viewport edge are dropped —
        // matches how the original line clips at the viewport.
        if new_len > orig_len {
            let delta = (new_len - orig_len) as u16;
            let trailing_start = x_start.saturating_add(orig_len as u16);
            for x in (trailing_start..line_end).rev() {
                let dst_x = x.saturating_add(delta);
                if dst_x >= line_end {
                    continue;
                }
                let src = buffer.cell((x, y)).cloned();
                if let Some(src) = src
                    && let Some(dst) = buffer.cell_mut((dst_x, y))
                {
                    *dst = src;
                }
            }
        }

        // Paint the new identifier.
        for (k, ch) in new_chars.iter().enumerate() {
            let px = x_start.saturating_add(k as u16);
            if px >= line_end {
                break;
            }
            if let Some(dst) = buffer.cell_mut((px, y)) {
                dst.set_char(*ch);
                dst.set_style(new_style);
            }
        }
        // Shorter replacement: paint spaces over the trailing chars
        // of the OLD identifier so they don't leak through. (The
        // proper visual — collapsing the line — would need a leftward
        // shift; deferred. The space-fill matches the original
        // behavior and is still strictly better than "no preview".)
        for k in new_len..orig_len {
            let px = x_start.saturating_add(k as u16);
            if px >= line_end {
                break;
            }
            if let Some(dst) = buffer.cell_mut((px, y)) {
                dst.set_char(' ');
                dst.set_style(new_style);
            }
        }
    }
}
