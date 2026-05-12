//! The splash shown when no pane is open. (A proper dashboard/greeter with
//! recents + shortcuts is a "later".)

use ratatui::Frame;
use ratatui::layout::{Alignment, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().bg_dark)),
        area,
    );
    if area.height < 6 {
        return;
    }
    let ws = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace");
    let dim = Style::default()
        .fg(theme::cur().comment)
        .bg(theme::cur().bg_dark);
    let key = Style::default()
        .fg(theme::cur().yellow)
        .bg(theme::cur().bg_dark)
        .add_modifier(Modifier::BOLD);

    let body = vec![
        Line::from(Span::styled(
            "mnml",
            Style::default()
                .fg(theme::cur().blue)
                .bg(theme::cur().bg_dark)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(Span::styled(format!("workspace · {ws}"), dim)),
        Line::from(""),
        Line::from(vec![
            Span::styled("↑/↓  ", key),
            Span::styled("navigate the tree", dim),
        ]),
        Line::from(vec![
            Span::styled("⏎    ", key),
            Span::styled("open file / toggle folder", dim),
        ]),
        Line::from(vec![
            Span::styled("^E   ", key),
            Span::styled("cycle focus (tree ⇄ editor)", dim),
        ]),
        Line::from(vec![
            Span::styled("^B   ", key),
            Span::styled("toggle the file tree", dim),
        ]),
        Line::from(vec![Span::styled("^Q   ", key), Span::styled("quit", dim)]),
    ];
    let n = body.len() as u16;
    let top = area.y + area.height.saturating_sub(n) / 2;
    let inner = Rect {
        y: top,
        height: n.min(area.height),
        ..area
    };
    frame.render_widget(Paragraph::new(body).alignment(Alignment::Center), inner);
}
