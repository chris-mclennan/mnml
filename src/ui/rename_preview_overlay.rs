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
    for &(row, col_chars, orig_len) in &state.occurrences {
        // Bridge to flash's screen-mapper by faking a FlashTarget — the cell
        // (row, col_chars) maps the same way regardless of which feature owns it.
        let target = crate::flash::FlashTarget {
            row,
            col_chars,
            label: ' ',
        };
        let Some((x_start, y)) = target_to_screen(&target, area, scroll, h_scroll, wrap_w) else {
            continue;
        };
        // Paint the new identifier char-by-char. Stop at the right edge of
        // the text rect. Overlay up to max(orig_len, new_chars) cells so a
        // shorter replacement clears the trailing chars of the old word too
        // (paint a space over those cells).
        //
        // 2026-06-08 nvchad hunt SEV-2: when `new_chars > orig_len` the
        // preview used to bulldoze the cells AFTER the identifier — a
        // rename like `x → xfoo` rendered `let xfoo42;` instead of
        // `let xfoo = 42;`, making users think the actual rename would
        // mangle their code (the real rename is correct, only the
        // preview lied). Cheapest "correct enough" fix: skip the
        // preview overlay when the replacement is longer than the
        // original. Better-looking fix (shift the rest of the line
        // right by the delta) is a v2 — needs cooperation from the
        // editor renderer that's beyond the scope of this pass.
        if new_text.chars().count() > orig_len {
            continue;
        }
        let new_chars: Vec<char> = new_text.chars().collect();
        let span = new_chars.len().max(orig_len);
        for k in 0..span {
            let px = x_start.saturating_add(k as u16);
            if px >= area.x + area.width {
                break;
            }
            if y >= area.y + area.height {
                break;
            }
            let ch = if k < new_chars.len() {
                new_chars[k]
            } else {
                ' '
            };
            if let Some(dst) = buffer.cell_mut((px, y)) {
                dst.set_char(ch);
                dst.set_style(new_style);
            }
        }
    }
}
