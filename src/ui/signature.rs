//! Renders the LSP signature-help popup ([`crate::signature::SignaturePopup`])
//! — a small bordered overlay anchored near the cursor with the function
//! prototype and the active parameter highlighted. Read-only; Esc dismisses
//! (handled in `tui.rs`), as does any cursor jump.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

const MAX_WIDTH: u16 = 80;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect, cursor: Option<(u16, u16)>) {
    let Some(p) = &app.signature else {
        return;
    };
    if screen.width < 8 || screen.height < 4 {
        return;
    }
    let t = theme::cur();
    let sig = p.active_sig();
    let label = &sig.label;

    let label_chars: Vec<char> = label.chars().collect();
    let label_count = label_chars.len() as u16;
    let content_w = label_count.clamp(8, MAX_WIDTH);
    let w = (content_w + 2).min(screen.width.saturating_sub(2));
    // 1 line of label + (if multi-sig) 1 line of "n/m" indicator.
    let multi = p.signatures.len() > 1;
    let inner_h: u16 = if multi { 2 } else { 1 };
    let hgt = (inner_h + 2).min(screen.height.saturating_sub(2));

    let (cx, cy) = cursor.unwrap_or((screen.x + 2, screen.y + 1));
    // Anchor *above* the cursor — signature help typically sits above the
    // function call line. Flip below if there isn't room.
    let above_y = cy.saturating_sub(hgt);
    let y = if cy >= screen.y + hgt {
        above_y
    } else if cy + 1 + hgt <= screen.y + screen.height {
        cy + 1
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

    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t.purple).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker));
    frame.render_widget(block, area);

    let inner = Rect {
        x: area.x + 1,
        y: area.y + 1,
        width: area.width.saturating_sub(2),
        height: area.height.saturating_sub(2),
    };

    // Render the label with the active-parameter range bolded + yellow.
    let active_range = sig
        .active_parameter
        .and_then(|i| sig.parameters.get(i).copied());
    let mut spans: Vec<Span> = Vec::new();
    let max = inner.width as usize;
    let take = label_chars.len().min(max);
    for (i, ch) in label_chars.iter().take(take).enumerate() {
        let in_active = active_range.is_some_and(|(s, e)| i >= s && i < e);
        let style = if in_active {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(t.bg_darker)
        };
        spans.push(Span::styled(ch.to_string(), style));
    }
    let mut lines = vec![Line::from(spans)];
    if multi {
        lines.push(Line::from(Span::styled(
            format!(" {}/{} signatures", p.active + 1, p.signatures.len()),
            Style::default().fg(t.comment).bg(t.bg_darker),
        )));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg_darker)),
        inner,
    );
}
