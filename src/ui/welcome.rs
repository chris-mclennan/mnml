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
    let path_style = Style::default()
        .fg(theme::cur().fg)
        .bg(theme::cur().bg_dark);

    let mut body: Vec<Line> = vec![
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
            Span::styled("↑/↓     ", key),
            Span::styled("navigate the tree", dim),
        ]),
        Line::from(vec![
            Span::styled("⏎       ", key),
            Span::styled("open file / toggle folder", dim),
        ]),
        Line::from(vec![
            Span::styled("^P / ^R ", key),
            Span::styled("file picker / recent files", dim),
        ]),
        Line::from(vec![
            Span::styled("^N      ", key),
            Span::styled("new file (workspace-relative)", dim),
        ]),
        Line::from(vec![
            Span::styled("^E / ^B ", key),
            Span::styled("cycle focus / toggle tree", dim),
        ]),
        Line::from(vec![
            Span::styled("^Q      ", key),
            Span::styled("quit", dim),
        ]),
    ];

    // Recent files — up to 6 newest, with workspace-relative paths. Only if
    // there's room (the splash should still center cleanly on small windows).
    if !app.recent_files.is_empty() && area.height >= 16 {
        body.push(Line::from(""));
        body.push(Line::from(Span::styled("recent files", dim)));
        for p in app.recent_files.iter().take(6) {
            let rel = p
                .strip_prefix(&app.workspace)
                .unwrap_or(p)
                .to_string_lossy()
                .into_owned();
            body.push(Line::from(Span::styled(rel, path_style)));
        }
    }

    let n = body.len() as u16;
    let top = area.y + area.height.saturating_sub(n) / 2;
    let inner = Rect {
        y: top,
        height: n.min(area.height),
        ..area
    };
    frame.render_widget(Paragraph::new(body).alignment(Alignment::Center), inner);
}
