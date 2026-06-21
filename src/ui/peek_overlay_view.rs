//! Floating "peek definition" overlay — bordered box centered
//! horizontally near the top of the editor area, showing N lines
//! of source around an LSP-resolved definition.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let Some(po) = app.peek_overlay.as_ref() else {
        return;
    };
    let t = theme::cur();

    // Size: 80% of area width (capped 50..120), height = lines + 2
    // (border) + 1 (title) capped to ~70% of area.
    let width = area.width.saturating_sub(area.width / 5).clamp(50, 120);
    let target_h = po.lines.len() as u16 + 3;
    let max_h = area.height.saturating_sub(area.height / 4);
    let height = target_h.min(max_h).max(8);
    let x = area.x + (area.width.saturating_sub(width)) / 2;
    let y = area.y + 2;
    let overlay = Rect::new(x, y, width, height);
    // 2026-06-21 vscode SEV-2: store the overlay rect so the mouse
    // dispatcher can treat clicks INSIDE as "consumed" (don't bleed
    // through to the editor) and clicks OUTSIDE as "dismiss".
    app.rects.peek_overlay = Some(overlay);

    frame.render_widget(Clear, overlay);

    let border_style = Style::default().fg(t.cyan);
    let title = format!(" ✦ peek · {} · Esc closes ", po.title());
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(Span::styled(
            title,
            Style::default().fg(t.cyan).add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(overlay);
    frame.render_widget(block, overlay);

    let bg = t.bg_dark;
    let body_h = inner.height as usize;
    let scroll = po.scroll.min(po.lines.len().saturating_sub(body_h.max(1)));
    let mut lines: Vec<Line> = Vec::new();
    for (i, src) in po.lines.iter().enumerate().skip(scroll).take(body_h) {
        let is_anchor = i == po.highlight_idx;
        let style = if is_anchor {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(bg)
        };
        let gutter_style = Style::default().fg(t.comment).bg(bg);
        let line_num = po.anchor_line as usize + i - po.highlight_idx + 1;
        let prefix = if is_anchor {
            format!("{:>4} ▸ ", line_num)
        } else {
            format!("{:>4}   ", line_num)
        };
        lines.push(Line::from(vec![
            Span::styled(prefix, gutter_style),
            Span::styled(src.clone(), style),
        ]));
    }
    let para = Paragraph::new(lines).style(Style::default().bg(bg));
    frame.render_widget(para, inner);
}
