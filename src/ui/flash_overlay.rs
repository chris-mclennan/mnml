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

    // A one-line cue on the pane's last row.
    //
    // 2026-09-03 — a bug-hunt filed `s` as "dead: it does not
    // substitute and it does not jump", having pressed `s<a><b>` and
    // stopped there. It was working; flash needs the LABEL press next,
    // and nothing on screen said so. Anyone who does not already know
    // leap/flash sees their text apparently change (`gamma` -> `famma`)
    // and no way forward — so the cue names both the action and the way
    // out.
    let hint = format!(
        " {}{} \u{2192} press a label to jump \u{b7} Esc cancels ",
        state.pair.0, state.pair.1
    );
    let hw = hint.chars().count() as u16;
    if text_rect.width >= hw && text_rect.height > 0 {
        let hy = text_rect.y + text_rect.height - 1;
        let hx = text_rect.x + text_rect.width - hw;
        let hint_style = Style::default()
            .fg(t.bg_dark)
            .bg(t.yellow)
            .add_modifier(Modifier::BOLD);
        for (i, ch) in hint.chars().enumerate() {
            let x = hx + i as u16;
            if x >= area.x + area.width || hy >= area.y + area.height {
                break;
            }
            if let Some(dst) = buffer.cell_mut((x, hy)) {
                dst.set_char(ch);
                dst.set_style(hint_style);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::app::App;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    /// A bug-hunt filed `s` as "dead — it does not substitute and it
    /// does not jump", having pressed `s<a><b>` and stopped there.
    /// Flash was working; it needs the LABEL press next, and nothing on
    /// screen said so. Verified end-to-end afterwards: `s g a f` does
    /// jump to line 2 of `alpha beta / gamma delta / kappa omicron`.
    ///
    /// So the defect was the missing cue, not the jump. This asserts
    /// the cue is on screen whenever labels are.
    #[test]
    fn an_armed_flash_says_what_to_press() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("w.txt");
        std::fs::write(&f, "alpha beta\ngamma delta\nkappa omicron\n").unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_path(&f);

        let (w, h) = (120u16, 30u16);
        let render = |app: &mut App| -> String {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|fr| crate::ui::draw(fr, app)).unwrap();
            let buf = term.backend().buffer();
            (0..h)
                .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
                .collect::<Vec<_>>()
                .join("\n")
        };
        // Lay the panes out once so `editor_panes` rects exist.
        let _ = render(&mut app);
        app.flash_start('g', 'a');
        assert!(
            app.flash_state.is_some(),
            "flash did not arm on a pair that occurs in the buffer"
        );

        let screen = render(&mut app);
        assert!(
            screen.contains("press a label to jump"),
            "labels are painted with no cue for what to press"
        );
        assert!(
            screen.contains("Esc"),
            "the cue does not offer a way out of flash"
        );
    }

    /// The cue must not linger once flash is over, or it becomes noise
    /// that says the editor is in a mode it is not.
    #[test]
    fn the_cue_disappears_with_the_flash_state() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("w.txt");
        std::fs::write(&f, "alpha beta\ngamma delta\n").unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_path(&f);
        let (w, h) = (120u16, 30u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|fr| crate::ui::draw(fr, &mut app)).unwrap();
        app.flash_state = None;
        term.draw(|fr| crate::ui::draw(fr, &mut app)).unwrap();
        let buf = term.backend().buffer();
        let screen: String = (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            !screen.contains("press a label to jump"),
            "the flash cue outlived the flash state"
        );
    }
}
