//! The "this buffer has unsaved changes" confirm overlay: a small centered modal
//! with Save / Discard / Cancel buttons. Driven by `App::close_prompt_info()`;
//! key + mouse handling lives in `tui.rs` (it records button hitboxes here).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some((name, has_path)) = app.close_prompt_info() else {
        return;
    };
    app.rects.close_prompt_buttons.clear();

    // Buttons: Save (only if the buffer has a path), Discard, Cancel. The label
    // capitalises the hotkey letter (s/d/c).
    let mut buttons: Vec<(&str, u8)> = Vec::new();
    if has_path {
        buttons.push((" [S]ave ", 0));
    }
    buttons.push((" [D]iscard ", 1));
    buttons.push((" [C]ancel ", 2));

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
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(theme::ORANGE).bg(theme::BG_DARKER))
        .title(Span::styled(
            " Unsaved changes ",
            Style::default()
                .fg(theme::BG_DARKER)
                .bg(theme::ORANGE)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(theme::BG_DARKER));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 3 {
        return;
    }

    // Row 0: the message. Row 1: blank. Last row: the buttons.
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg,
            Style::default().fg(theme::FG).bg(theme::BG_DARKER),
        ))),
        Rect::new(inner.x, inner.y, inner.width, 1),
    );

    let by = inner.y + inner.height - 1;
    let mut bx = inner.x + 1;
    for (i, (label, choice)) in buttons.iter().enumerate() {
        // The default (first) button gets a brighter style.
        let style = if i == 0 {
            Style::default()
                .fg(theme::BG_DARKER)
                .bg(theme::BLUE)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme::FG).bg(theme::BG2)
        };
        let bw = label.chars().count() as u16;
        if bx + bw > inner.x + inner.width {
            break;
        }
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(label.to_string(), style))),
            Rect::new(bx, by, bw, 1),
        );
        app.rects
            .close_prompt_buttons
            .push((Rect::new(bx, by, bw, 1), *choice));
        bx += bw + 2;
    }
}
