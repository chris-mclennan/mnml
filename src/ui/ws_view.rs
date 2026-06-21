//! WebSocket pane renderer. Two-section layout:
//!   Top: scrolling log of `← incoming` / `→ outgoing` lines.
//!   Bottom: single-line input. Enter sends; Esc closes.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;
use crate::websocket::WsState;

pub fn draw(frame: &mut Frame, app: &mut App, id: PaneId, area: Rect, focused: bool) -> Option<(u16, u16)> {
    let Some(Pane::Websocket(p)) = app.panes.get(id) else {
        return None;
    };
    let t = theme::cur();

    let border_style = if focused {
        Style::default().fg(t.blue)
    } else {
        Style::default().fg(t.bg3)
    };
    let state_chip = match p.state {
        WsState::Connecting => ("connecting…", t.yellow),
        WsState::Open => ("● open", t.green),
        WsState::Closing => ("▼ closing", t.yellow),
        WsState::Closed => ("· closed", t.comment),
    };
    let header = format!(
        " ws · {} · {} · {} msgs · enter=send · ctrl+c=disconnect · esc=tree ",
        state_chip.0,
        p.url,
        p.log.len()
    );
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(Span::styled(
            header,
            Style::default()
                .fg(state_chip.1)
                .add_modifier(Modifier::BOLD),
        ));

    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 8 || inner.height < 3 {
        return None;
    }

    // Register the pane body so wheel events route here.
    app.rects.editor_panes.push((inner, id));

    // Vertical split: input takes the bottom row, log everything above.
    let log_h = inner.height.saturating_sub(1);
    let log_area = Rect::new(inner.x, inner.y, inner.width, log_h);
    let input_area = Rect::new(inner.x, inner.y + log_h, inner.width, 1);

    // Render log — newest at bottom. Scroll counts rows from bottom
    // so 0 = follow tail.
    let max = log_h as usize;
    let total = p.log.len();
    let scroll = p.scroll.min(total.saturating_sub(max.max(1)));
    let start = total.saturating_sub(max + scroll);
    let end = total.saturating_sub(scroll);
    let mut lines: Vec<Line> = Vec::new();
    for entry in &p.log[start..end] {
        let dir_glyph = if entry.outgoing { "→ " } else { "← " };
        let dir_color = if entry.outgoing { t.purple } else { t.green };
        // Strip newlines so multi-line messages don't wreck the layout.
        let mut compact = String::with_capacity(entry.text.len());
        let mut last_was_space = false;
        for c in entry.text.chars() {
            if c.is_whitespace() {
                if !last_was_space {
                    compact.push(' ');
                }
                last_was_space = true;
            } else {
                compact.push(c);
                last_was_space = false;
            }
        }
        lines.push(Line::from(vec![
            Span::styled(
                dir_glyph.to_string(),
                Style::default().fg(dir_color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(compact, Style::default().fg(t.fg)),
        ]));
    }
    let log_para = Paragraph::new(lines).style(Style::default().bg(t.bg_dark));
    frame.render_widget(log_para, log_area);

    // Render input row. Prompt + the user's typing buffer.
    let prompt = " ▸ ";
    let prompt_w = prompt.chars().count() as u16;
    let input_line = Line::from(vec![
        Span::styled(
            prompt.to_string(),
            Style::default()
                .fg(t.cyan)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            p.input.clone(),
            Style::default().fg(t.fg).bg(t.bg2),
        ),
        Span::styled(
            " ".repeat(
                (input_area.width as usize)
                    .saturating_sub(prompt.chars().count() + p.input.chars().count()),
            ),
            Style::default().bg(t.bg2),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(input_line).style(Style::default().bg(t.bg2)),
        input_area,
    );

    // Cursor on the input.
    if focused {
        let cursor_x =
            input_area.x + prompt_w + (p.input.chars().count() as u16).min(input_area.width);
        return Some((cursor_x, input_area.y));
    }
    None
}
