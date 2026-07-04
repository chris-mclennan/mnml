//! The "this buffer has unsaved changes" confirm overlay: a small centered modal
//! with Save / Discard / Cancel buttons. Driven by `App::close_prompt_info()`;
//! key + mouse handling lives in `tui.rs` (it records button hitboxes here).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some((name, has_path)) = app.close_prompt_info() else {
        return;
    };
    app.rects.close_prompt_buttons.clear();

    // Buttons: Save (only if the buffer has a path), Discard, Cancel.
    // Use plain labels — the bg-color box treatment below already
    // signals "clickable button", and the bracket-mnemonic look
    // (` [S]ave `) was reading as text instead.
    // vscode-mouse-2026-06-10 SEV-3 #5. The keyboard hotkey is
    // surfaced as an underline on the first letter (drawn below).
    let mut buttons: Vec<(&str, u8)> = Vec::new();
    if has_path {
        buttons.push(("  Save  ", 0));
    }
    buttons.push(("  Discard  ", 1));
    buttons.push(("  Cancel  ", 2));

    let msg = format!("  {name} has unsaved changes.");
    let buttons_w: usize = buttons.iter().map(|(t, _)| t.chars().count() + 2).sum();
    let inner_w = msg.chars().count().max(buttons_w + 2).max(28);
    let w = (inner_w as u16 + 2).min(screen.width.saturating_sub(2));
    let h = 6u16.min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_panel("Unsaved changes");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 3 {
        return;
    }

    // Row 0: the message. Row 1: blank. Last row: the buttons.
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg,
            Style::default()
                .fg(theme::cur().fg)
                .bg(theme::cur().bg_darker),
        ))),
        Rect::new(inner.x, inner.y, inner.width, 1),
    );

    let by = inner.y + inner.height - 1;
    let mut bx = inner.x + 1;
    for (i, (label, choice)) in buttons.iter().enumerate() {
        // The default (first) button gets a brighter style.
        let style = if i == 0 {
            Style::default()
                .fg(theme::cur().bg_darker)
                .bg(theme::cur().blue)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2)
        };
        let bw = label.chars().count() as u16;
        if bx + bw > inner.x + inner.width {
            break;
        }
        // Underline the hotkey letter (capital S/D/C — index 2 in the
        // padded label) so the user can find the keyboard shortcut
        // without having to read the bracket-mnemonic that the
        // pre-2026-06-13 version surfaced.
        let mut spans: Vec<Span> = Vec::new();
        let chars: Vec<char> = label.chars().collect();
        // Padding before the hotkey letter.
        spans.push(Span::styled(chars[..2].iter().collect::<String>(), style));
        // The hotkey letter, underlined.
        if let Some(&hk) = chars.get(2) {
            spans.push(Span::styled(
                hk.to_string(),
                style.add_modifier(Modifier::UNDERLINED),
            ));
        }
        // Rest of the label.
        spans.push(Span::styled(chars[3..].iter().collect::<String>(), style));
        frame.render_widget(Paragraph::new(Line::from(spans)), Rect::new(bx, by, bw, 1));
        app.rects
            .close_prompt_buttons
            .push((Rect::new(bx, by, bw, 1), *choice));
        bx += bw + 2;
    }
}
