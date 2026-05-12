//! Renders the LSP hover popup ([`crate::hover::HoverPopup`]) — a small bordered
//! box anchored just below the cursor (flipped above if it won't fit, clamped to
//! the screen) with the language server's docs. j/k/arrows scroll it, any other
//! key dismisses it (handled in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect, cursor: Option<(u16, u16)>) {
    let Some(h) = &mut app.hover else {
        return;
    };
    if screen.width < 8 || screen.height < 5 || h.lines.is_empty() {
        return;
    }
    let t = theme::cur();

    let content_w = h.width().max(8) as u16;
    let w = (content_w + 2).min(screen.width.saturating_sub(2));
    let max_h = screen.height.saturating_sub(2).min(18);
    let hgt = (h.lines.len() as u16 + 2).min(max_h);
    let inner_rows = hgt.saturating_sub(2) as usize;

    // Anchor below the cursor; flip above if it doesn't fit; clamp to the screen.
    let (cx, cy) = cursor.unwrap_or((screen.x + 2, screen.y + 1));
    let below_y = cy.saturating_add(1);
    let y = if below_y + hgt <= screen.y + screen.height {
        below_y
    } else if cy >= screen.y + hgt {
        cy - hgt
    } else {
        screen.y
    };
    let x = cx
        .min(screen.x + screen.width.saturating_sub(w))
        .max(screen.x);
    let area = Rect {
        x,
        y,
        width: w,
        height: hgt,
    };

    let max_scroll = h.lines.len().saturating_sub(inner_rows);
    if h.scroll > max_scroll {
        h.scroll = max_scroll;
    }

    frame.render_widget(Clear, area);
    let title = if h.lines.len() > inner_rows {
        format!(
            " hover  {}–{}/{} ",
            h.scroll + 1,
            (h.scroll + inner_rows).min(h.lines.len()),
            h.lines.len()
        )
    } else {
        " hover ".to_string()
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t.grey_fg).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker))
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }
    let view: Vec<Line> = h
        .lines
        .iter()
        .skip(h.scroll)
        .take(inner.height as usize)
        .map(|l| {
            Line::from(Span::styled(
                l.clone(),
                Style::default().fg(t.fg).bg(t.bg_darker),
            ))
        })
        .collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_darker)),
        inner,
    );
}
