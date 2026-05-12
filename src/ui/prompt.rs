//! The single-line text-input overlay (commit message, …) — a small centered
//! box with a title and one editable line. State lives in `crate::prompt`; key
//! handling lives in `tui.rs`. Records the caret cell in `app.rects.prompt_caret`
//! so `ui::draw` can place the terminal cursor here.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(p) = &app.prompt else { return };
    let title = format!(" {} ", p.title);
    let input = p.input.clone();
    let caret_col = p.caret_col();

    let w = (title.chars().count().max(48) as u16 + 4).min(screen.width.saturating_sub(2));
    let h = 5u16.min(screen.height.saturating_sub(2));
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
        .border_style(
            Style::default()
                .fg(theme::cur().green)
                .bg(theme::cur().bg_darker),
        )
        .title(Span::styled(
            title,
            Style::default()
                .fg(theme::cur().bg_darker)
                .bg(theme::cur().green)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(theme::cur().bg_darker));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }

    // The input line: blank row, then the text on the next row (left-padded one cell).
    let field_y = inner.y + inner.height / 2;
    let pad = 1u16;
    let avail = inner.width.saturating_sub(pad) as usize;
    // Scroll the text so the caret stays visible.
    let chars: Vec<char> = input.chars().collect();
    let start = caret_col.saturating_sub(avail.saturating_sub(1));
    let shown: String = chars.iter().skip(start).take(avail).collect();
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            shown,
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2),
        )))
        .style(Style::default().bg(theme::cur().bg2)),
        Rect::new(inner.x + pad, field_y, inner.width.saturating_sub(pad), 1),
    );
    // A dim hint below the field.
    if field_y + 1 < inner.y + inner.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  enter to commit · esc to cancel",
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg_darker),
            ))),
            Rect::new(inner.x, field_y + 1, inner.width, 1),
        );
    }

    let cx = inner.x + pad + (caret_col - start) as u16;
    app.rects.prompt_caret = Some((cx.min(inner.x + inner.width.saturating_sub(1)), field_y));
}
