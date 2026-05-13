//! Renders the as-you-type LSP completion popup ([`crate::completion::CompletionPopup`])
//! — a small borderless list of candidates anchored just below the cursor (flipped
//! above if it won't fit, clamped to the screen). The selected row is highlighted;
//! a dim right-hand column shows each item's `detail`. Up/Down/Ctrl-N·P move the
//! selection, Tab/Enter accept, Esc dismisses, typing keeps filtering — all handled
//! in `tui.rs`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

const MAX_ROWS: usize = 10;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect, cursor: Option<(u16, u16)>) {
    let Some(p) = &mut app.completion else { return };
    let n = p.len();
    if n == 0 || screen.width < 14 || screen.height < 4 {
        return;
    }
    let t = theme::cur();

    // Vertical window; keep the selection inside it.
    let rows = n.min(MAX_ROWS);
    if p.selected < p.scroll {
        p.scroll = p.selected;
    } else if p.selected >= p.scroll + rows {
        p.scroll = p.selected + 1 - rows;
    }
    p.scroll = p.scroll.min(n.saturating_sub(rows));

    let visible: Vec<(usize, &crate::completion::CompletionItem)> =
        p.rows().skip(p.scroll).take(rows).collect();
    let selected = p.selected;

    let label_w = visible
        .iter()
        .map(|(_, it)| it.label.chars().count())
        .max()
        .unwrap_or(1);
    let detail_w = visible
        .iter()
        .map(|(_, it)| it.detail.chars().count())
        .max()
        .unwrap_or(0);
    let inner_w = label_w + if detail_w > 0 { detail_w + 2 } else { 0 } + 2; // 1-col pad each side
    let w = (inner_w as u16).clamp(14, screen.width.saturating_sub(2));
    let h = rows as u16;

    let (cx, cy) = cursor.unwrap_or((screen.x + 2, screen.y + 1));
    let below = cy.saturating_add(1);
    let y = if below + h <= screen.y + screen.height {
        below
    } else if cy >= screen.y + h {
        cy - h
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
        height: h,
    };

    frame.render_widget(Clear, area);

    let usable = area.width.saturating_sub(2) as usize; // drop the 1-col pad each side
    let mut lines: Vec<Line> = Vec::with_capacity(rows);
    for (row, it) in &visible {
        let sel = *row == selected;
        let (bg, fg, dfg) = if sel {
            (t.cyan, t.bg_darker, t.bg_darker)
        } else {
            (t.bg_darker, t.fg, t.grey_fg)
        };
        let mut label: String = it.label.chars().take(usable).collect();
        if it.label.chars().count() > usable && usable >= 1 {
            label = it.label.chars().take(usable - 1).collect::<String>() + "…";
        }
        let used = label.chars().count();
        let mut left = usable.saturating_sub(used);
        let mut detail_span = None;
        if !it.detail.is_empty() && left > 3 {
            let avail = left - 2; // gap before the detail
            let dc = it.detail.chars().count();
            let shown: String = if dc > avail {
                it.detail
                    .chars()
                    .take(avail.saturating_sub(1))
                    .collect::<String>()
                    + "…"
            } else {
                it.detail.clone()
            };
            left = left.saturating_sub(shown.chars().count());
            detail_span = Some(shown);
        }
        let mut spans = vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                label,
                if sel {
                    Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(fg).bg(bg)
                },
            ),
        ];
        if let Some(d) = detail_span {
            spans.push(Span::styled(" ".repeat(left), Style::default().bg(bg)));
            spans.push(Span::styled(d, Style::default().fg(dfg).bg(bg)));
        } else {
            spans.push(Span::styled(" ".repeat(left), Style::default().bg(bg)));
        }
        spans.push(Span::styled(" ", Style::default().bg(bg)));
        lines.push(Line::from(spans));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg_darker)),
        area,
    );
}
