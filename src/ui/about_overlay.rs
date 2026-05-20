//! About overlay — a centered floating panel with build + workspace
//! metadata. Sibling to the welcome / discovery overlays. Triggered via
//! `view.about` / `:about`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    if !app.show_about {
        return;
    }
    let t = theme::cur();
    type Row = (&'static str, String);
    let editor_count = app
        .panes
        .iter()
        .filter(|p| matches!(p, crate::pane::Pane::Editor(_)))
        .count();
    let workspace_label = app
        .workspace
        .to_str()
        .map(|s| s.to_string())
        .unwrap_or_else(|| app.workspace.display().to_string());
    let rows: Vec<Row> = vec![
        ("version", env!("MNML_GIT_SHA").to_string()),
        ("theme", t.name.to_string()),
        ("workspace", workspace_label),
        ("repos", format!("{}", app.repos.len())),
        ("lsp servers", format!("{}", app.lsp.server_count())),
        (
            "tab pages",
            format!("{}/{}", app.active_layout + 1, app.layouts.len()),
        ),
        ("editor buffers", format!("{editor_count}")),
        ("total panes", format!("{}", app.panes.len())),
        (
            "input style",
            app.config.editor.input_style.clone(),
        ),
        (
            "recent files",
            format!("{}", app.recent_files.len()),
        ),
    ];

    let title = " About mnml — Esc / click outside to dismiss ";
    let key_w = rows
        .iter()
        .map(|(k, _)| k.chars().count())
        .max()
        .unwrap_or(8);
    let val_w = rows
        .iter()
        .map(|(_, v)| v.chars().count())
        .max()
        .unwrap_or(20);
    let inner_w = (key_w + 4 + val_w).max(title.chars().count() + 2);
    let w = (inner_w as u16 + 4).min(screen.width);
    let h = (rows.len() as u16 + 2 + 2).min(screen.height);
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 3);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.blue)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(rows.len() + 1);
    for (k, v) in rows {
        let key_padded = format!(" {k:<w$}  ", w = key_w);
        lines.push(Line::from(vec![
            Span::styled(
                key_padded,
                Style::default().fg(t.comment),
            ),
            Span::styled(
                v,
                Style::default()
                    .fg(t.yellow)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        " :welcome reopens the new-user overlay · F1 shows clickable rects ".to_string(),
        Style::default().fg(t.comment).add_modifier(Modifier::ITALIC),
    )));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}
