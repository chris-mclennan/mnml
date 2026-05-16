//! Flash/leap label overlay. Walks `App.flash_state.targets` and paints each
//! label glyph at the target's screen cell, on top of whatever the editor
//! pane already rendered. Single-cell paint per label — keeps the syntax /
//! diff / find background visible immediately around each label.

use ratatui::Frame;
use ratatui::style::{Modifier, Style};

use crate::app::App;
use crate::flash::target_to_screen;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App) {
    let Some(state) = app.flash_state.as_ref() else {
        return;
    };
    // Locate the active editor's text rect via the recorded `editor_panes`.
    let Some((text_rect, _)) = app
        .rects
        .editor_panes
        .iter()
        .find(|(_, p)| *p == state.pane_id)
        .copied()
    else {
        return;
    };
    // Grab scroll + h_scroll from the buffer.
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
    let label_style = Style::default()
        .fg(t.bg_dark)
        .bg(t.yellow)
        .add_modifier(Modifier::BOLD);

    let area = frame.area();
    let buffer = frame.buffer_mut();
    for tgt in &state.targets {
        let Some((x, y)) = target_to_screen(tgt, text_rect, scroll, h_scroll, wrap_w) else {
            continue;
        };
        if x >= area.x + area.width || y >= area.y + area.height {
            continue;
        }
        if let Some(dst) = buffer.cell_mut((x, y)) {
            dst.set_char(tgt.label);
            dst.set_style(label_style);
        }
    }
}
