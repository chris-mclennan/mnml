//! Stacked toasts overlay — paints `App.persistent_toasts` (pinned)
//! + `App.toast_stack` (ephemeral, TTL-expiring) as a vertical
//! column of bordered boxes at the top-right of the screen, newest
//! first.
//!
//! Level-driven border color per `ToastLevel`: info + warn use the
//! standard comment color (calm); error uses red so failures stand
//! out. Persistent toasts render slightly brighter (no fade) so
//! they read as pinned rather than about-to-expire.
//!
//! When both stacks are empty (or have 1 entry with nothing
//! persistent) the overlay paints nothing — the single-toast case
//! is handled by the statusline's middle segment.

use std::time::Duration;

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::{App, ToastEntry, ToastLevel};
use crate::ui::theme;

const MAX_WIDTH: u16 = 50;
const RIGHT_MARGIN: u16 = 1;
const BOTTOM_MARGIN: u16 = 2; // 1 statusline + 1 spacer
const FADE_TAIL: Duration = Duration::from_millis(800);

pub fn draw(frame: &mut Frame, app: &App) {
    let has_persistent = !app.persistent_toasts.is_empty();
    let has_stack = app.toast_stack.len() > 1;
    if !has_persistent && !has_stack {
        return;
    }
    let area = frame.area();
    if area.width < 20 || area.height < 6 {
        return;
    }
    let t = theme::cur();
    let max_x_right = area.x + area.width.saturating_sub(RIGHT_MARGIN);
    let mut y_bottom = area.y + area.height.saturating_sub(BOTTOM_MARGIN);

    // Bottom-up render: ephemeral stack first (newest closest to
    // statusline), then persistent toasts above them (pinned zone).
    let all: Vec<&ToastEntry> = app
        .toast_stack
        .iter()
        .chain(app.persistent_toasts.iter().rev())
        .collect();
    for entry in all {
        let text: String = entry.text.chars().take(MAX_WIDTH as usize - 4).collect();
        let inner_w = text.chars().count() as u16 + 2;
        let box_w = inner_w + 2;
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
        let is_persistent = entry.persistent_id.is_some();
        let age = entry.created_at.elapsed();
        let fading = !is_persistent && age + FADE_TAIL >= Duration::from_secs(4);
        // Per Call 1 design C: info + warn share the comment
        // border; error gets red. Persistent errors stay red even
        // when the ephemeral stack has faded.
        let border_fg = match entry.level {
            ToastLevel::Error => t.red,
            ToastLevel::Warn | ToastLevel::Info if fading => t.bg3,
            _ => t.comment,
        };
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
