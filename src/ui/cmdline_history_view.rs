//! The cmdline-history pane (`Pane::CmdlineHistory`) — vim's `q:` window.
//! Renders the recent `:` command history newest-first; `↑↓`/`jk` move the
//! selection; `Enter` re-fires the selected entry; `Esc` → tree (all wired
//! in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    _focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));

    let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    // Keep selection in the visible window.
    let body_h = (area.height as usize).saturating_sub(2).max(1);
    if h.selected < h.scroll {
        h.scroll = h.selected;
    } else if h.selected >= h.scroll + body_h {
        h.scroll = h.selected + 1 - body_h;
    }
    h.scroll = h.scroll.min(h.entries.len().saturating_sub(body_h));

    let mut lines: Vec<Line> = Vec::new();
    let n = h.entries.len();
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            format!(
                "cmdline history · {n} entry{}",
                if n == 1 { "" } else { "ies" }
            ),
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        " ".repeat(area.width as usize),
        Style::default().bg(t.bg_dark),
    )));

    let mut cursor: Option<(u16, u16)> = None;
    for (offset, entry) in h.entries.iter().enumerate().skip(h.scroll).take(body_h) {
        let is_sel = offset == h.selected;
        let bg = if is_sel { t.bg2 } else { t.bg_dark };
        let prompt_style = if is_sel {
            Style::default()
                .fg(t.cyan)
                .bg(bg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(bg)
        };
        let text_style = if is_sel {
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(bg)
        };
        let pad = (area.width as usize).saturating_sub(entry.chars().count() + 3);
        lines.push(Line::from(vec![
            Span::styled(" :", prompt_style),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(entry.clone(), text_style),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]));
        if is_sel {
            cursor = Some((
                area.x + 1 + 2 + entry.chars().count() as u16,
                area.y + 2 + (offset - h.scroll) as u16,
            ));
        }
    }

    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
        area,
    );
    cursor
}
