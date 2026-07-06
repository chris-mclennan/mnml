//! #20 Pattern B — the confirm-before-destroy modal. Small,
//! centered dialog with a title / message / [Cancel] / [Confirm]
//! button row. Default focus lands on Cancel (safer default);
//! Y/y fires Confirm, N/n / Esc / Cancel dismisses.
//!
//! Owned by `App.pending_confirm: Option<PendingConfirm>`. When
//! set, this module paints on top of everything and the tui
//! input loop routes all keys / mouse to `commit_pending_confirm`
//! / `dismiss_pending_confirm`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(c) = app.pending_confirm.clone() else {
        return;
    };
    let t = theme::cur();
    let cancel_label = " Cancel ";
    let confirm_label = format!(" {} ", c.confirm_label);
    let cancel_w = cancel_label.chars().count() as u16;
    let confirm_w = confirm_label.chars().count() as u16;
    let msg_w = c.message.chars().count() as u16;
    let hint = " Y = confirm · N = cancel · Tab = cycle · Space/Enter = fire focus";
    let hint_w = hint.chars().count() as u16;
    let inner_w = msg_w
        .max(hint_w)
        .max(cancel_w + confirm_w + 3)
        .max(c.title.chars().count() as u16 + 4)
        .max(40);
    let w = (inner_w + 4).min(screen.width.saturating_sub(2));
    let h = 7u16.min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(t.red).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker))
        .title(format!(" {} ", c.title))
        .title_style(
            Style::default()
                .fg(t.red)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        );
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }
    // Message row (row 1 of the inner area).
    let msg_padded = format!(" {}", c.message);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg_padded,
            Style::default().fg(t.fg).bg(t.bg_darker),
        ))),
        Rect::new(inner.x, inner.y + 1, inner.width, 1),
    );
    // Hint row (row 2) — surfaces the keyboard shortcuts so users
    // don't have to guess. Dimmed so it recedes visually.
    if inner.height >= 4 {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                hint,
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_darker)
                    .add_modifier(Modifier::DIM),
            ))),
            Rect::new(inner.x, inner.y + 2, inner.width, 1),
        );
    }
    // Buttons at the bottom-right of the inner area.
    let by = inner.y + inner.height - 1;
    let total_bw = cancel_w + confirm_w + 1;
    let mut bx = inner.x + inner.width.saturating_sub(total_bw + 1);
    let is_confirm_focused = c.focused == 1;
    // Cancel first.
    let cancel_style = if is_confirm_focused {
        Style::default().fg(t.fg).bg(t.bg2)
    } else {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.cyan)
            .add_modifier(Modifier::BOLD)
    };
    let cancel_rect = Rect::new(bx, by, cancel_w, 1);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(cancel_label, cancel_style))),
        cancel_rect,
    );
    app.rects.confirm_modal_cancel = Some(cancel_rect);
    bx += cancel_w + 1;
    // Confirm.
    let confirm_style = if is_confirm_focused {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.red)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.red).bg(t.bg2)
    };
    let confirm_rect = Rect::new(bx, by, confirm_w, 1);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(confirm_label, confirm_style))),
        confirm_rect,
    );
    app.rects.confirm_modal_confirm = Some(confirm_rect);
}
