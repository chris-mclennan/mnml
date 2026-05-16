//! Stacked toasts overlay — paints `App.toast_stack` as a vertical column
//! of dim bordered boxes at the top-right of the screen, newest first.
//!
//! When the stack has 0 or 1 entries the overlay paints nothing — the
//! single-toast case is already handled by the statusline's middle
//! segment, so a separate overlay would just duplicate.

use std::time::Duration;

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

const MAX_WIDTH: u16 = 50;
const RIGHT_MARGIN: u16 = 1;
const BOTTOM_MARGIN: u16 = 2; // 1 statusline + 1 spacer
const FADE_TAIL: Duration = Duration::from_millis(800);

pub fn draw(frame: &mut Frame, app: &App) {
    if app.toast_stack.len() <= 1 {
        return;
    }
    let area = frame.area();
    if area.width < 20 || area.height < 6 {
        return;
    }
    let t = theme::cur();
    // Stack entries newest first; render bottom-up so the newest sits
    // closest to the user's eye (just above the statusline).
    let max_x_right = area.x + area.width.saturating_sub(RIGHT_MARGIN);
    let mut y_bottom = area.y + area.height.saturating_sub(BOTTOM_MARGIN);
    for (msg, created) in &app.toast_stack {
        // Truncate and trim.
        let text: String = msg.chars().take(MAX_WIDTH as usize - 4).collect();
        let inner_w = text.chars().count() as u16 + 2;
        let box_w = inner_w + 2; // borders
        let box_w = box_w.min(MAX_WIDTH).min(area.width.saturating_sub(2));
        let box_h: u16 = 3;
        if y_bottom < area.y + box_h {
            break;
        }
        let y = y_bottom - box_h;
        let x = max_x_right.saturating_sub(box_w);
        let rect = Rect {
            x,
            y,
            width: box_w,
            height: box_h,
        };
        // Fade the border as the toast nears expiry — last FADE_TAIL of
        // the TTL goes from comment color (dim) to dim. Approximated.
        let age = created.elapsed();
        let fading = age + FADE_TAIL >= Duration::from_secs(4);
        let border_fg = if fading { t.bg3 } else { t.comment };
        frame.render_widget(Clear, rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(border_fg).bg(t.bg_darker))
            .style(Style::default().bg(t.bg_darker));
        let inner = block.inner(rect);
        frame.render_widget(block, rect);
        let line = Line::from(vec![
            Span::raw(" "),
            Span::styled(
                text,
                Style::default()
                    .fg(t.fg)
                    .bg(t.bg_darker)
                    .add_modifier(if fading {
                        Modifier::DIM
                    } else {
                        Modifier::empty()
                    }),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(t.bg_darker)),
            inner,
        );
        y_bottom = y;
    }
}
