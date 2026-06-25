//! The NvDash-style splash shown when no pane is open.
//!
//! Centered ASCII logo + workspace name + git branch chip + clickable
//! recent-files list + shortcut hints. Records click targets in
//! `app.rects.dashboard_rows` so the tui mouse dispatcher can route a row
//! click to `open_path` without coupling back through the renderer.

use ratatui::Frame;
use ratatui::layout::{Alignment, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::ui::theme;

// figlet "Standard" with `-W` (full kerning) — each letter rendered
// at its native width with a 2-cell gutter between letters so the
// glyphs read independently (the smushed default packed them so
// tight the eye couldn't separate m / n / m / l).
// Every row is the same width so the centered Paragraph aligns them
// column-for-column. The `l` is intentionally one row taller than
// m/n — row 0 carries only the `l`'s top serif, and the m/n/m
// underscores live on row 1. That makes the `l` glyph 5 rows tall
// (top, 3 body strokes, bottom) vs m/n's 4 rows (top underscores,
// 2 body rows, bottom), mirroring how lowercase `l` ascends in
// proper typography.
const LOGO: &[&str] = &[
    "                                 _ ",
    " _ __ ___    _ __    _ __ ___   | |",
    "| '_ ` _ \\  | '_ \\  | '_ ` _ \\  | |",
    "| | | | | | | | | | | | | | | | | |",
    "|_| |_| |_| |_| |_| |_| |_| |_| |_|",
];

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().bg_dark)),
        area,
    );
    // Reset click targets — the renderer is the source of truth each frame.
    app.rects.dashboard_rows.clear();
    if area.height < 6 {
        return;
    }

    let t = theme::cur();
    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let key = Style::default()
        .fg(t.yellow)
        .bg(t.bg_dark)
        .add_modifier(Modifier::BOLD);
    let logo_style = Style::default()
        .fg(t.blue)
        .bg(t.bg_dark)
        .add_modifier(Modifier::BOLD);
    let header_style = Style::default()
        .fg(t.purple)
        .bg(t.bg_dark)
        .add_modifier(Modifier::BOLD);
    let path_style = Style::default().fg(t.fg).bg(t.bg_dark);
    let branch_style = Style::default()
        .fg(t.green)
        .bg(t.bg_dark)
        .add_modifier(Modifier::BOLD);

    let ws = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace");

    let (branch, changed_total) = {
        let s = app.git.snapshot();
        (s.branch.clone(), s.line_changes.len())
    };

    let mut body: Vec<Line> = Vec::new();
    // Logo (skip if the window is too short to fit both logo and content).
    let show_logo = area.height >= (LOGO.len() as u16 + 14);
    if show_logo {
        for line in LOGO {
            body.push(Line::from(Span::styled(*line, logo_style)));
        }
        body.push(Line::from(""));
    } else {
        body.push(Line::from(Span::styled("mnml", logo_style)));
    }

    // Workspace name + optional git branch.
    body.push(Line::from(Span::styled(
        format!("workspace · {ws}"),
        path_style,
    )));
    if let Some(b) = branch.as_deref() {
        let mut spans = vec![
            Span::styled("on ", dim),
            Span::styled(b.to_string(), branch_style),
        ];
        if changed_total > 0 {
            spans.push(Span::styled(
                format!(
                    " · {changed_total} changed file{}",
                    if changed_total == 1 { "" } else { "s" }
                ),
                dim,
            ));
        }
        body.push(Line::from(spans));
    }
    body.push(Line::from(""));

    // Install-to-PATH hint — shown only when `mnml` isn't on
    // PATH. One-line nudge plus a palette-command suggestion;
    // safe to ignore.
    if !crate::app::mnml_on_path() {
        body.push(Line::from(vec![
            Span::styled(
                " Tip ",
                Style::default()
                    .fg(t.bg_dark)
                    .bg(t.yellow)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "  install mnml to PATH so ",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
            Span::styled(
                "mnml .",
                Style::default()
                    .fg(t.fg)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                " works anywhere — palette: ",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
            Span::styled(
                "setup.install_to_path",
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
        body.push(Line::from(""));
    }

    // Recent Files — only if we have any, and the screen has room.
    // Capture the screen Y of each row so clicks can route.
    let mut recent_rect_starts: Vec<(usize, std::path::PathBuf)> = Vec::new();
    let recent_room = area.height >= (body.len() as u16 + 12);
    if !app.recent_files.is_empty() && recent_room {
        body.push(Line::from(Span::styled("Recent Files", header_style)));
        body.push(Line::from(Span::styled("──────────────", dim)));
        let n = (area.height as usize)
            .saturating_sub(body.len() + 10)
            .min(8);
        for p in app.recent_files.iter().take(n) {
            let rel = p
                .strip_prefix(&app.workspace)
                .unwrap_or(p)
                .to_string_lossy()
                .into_owned();
            recent_rect_starts.push((body.len(), p.clone()));
            body.push(Line::from(Span::styled(format!("  {rel}"), path_style)));
        }
        body.push(Line::from(""));
    }

    // Shortcuts.
    body.push(Line::from(Span::styled("Shortcuts", header_style)));
    body.push(Line::from(Span::styled("──────────────", dim)));
    body.push(Line::from(vec![
        Span::styled("  ^P     ", key),
        Span::styled("find file", dim),
    ]));
    body.push(Line::from(vec![
        Span::styled("  ^R     ", key),
        Span::styled("recent files", dim),
    ]));
    body.push(Line::from(vec![
        Span::styled("  ^K     ", key),
        Span::styled("which-key menu", dim),
    ]));
    body.push(Line::from(vec![
        Span::styled("  ^N     ", key),
        Span::styled("new file", dim),
    ]));
    body.push(Line::from(vec![
        Span::styled("  ^B     ", key),
        Span::styled("toggle tree", dim),
    ]));
    body.push(Line::from(vec![
        Span::styled("  ^Q     ", key),
        Span::styled("quit", dim),
    ]));
    body.push(Line::from(""));
    body.push(Line::from(Span::styled(
        format!("mnml · {}", env!("MNML_GIT_SHA")),
        dim,
    )));

    let n = body.len() as u16;
    let top = area.y + area.height.saturating_sub(n) / 2;
    let inner = Rect {
        y: top,
        height: n.min(area.height),
        ..area
    };
    frame.render_widget(Paragraph::new(body).alignment(Alignment::Center), inner);

    // Register click rects. The paragraph is center-aligned, so each row's
    // actual painted width depends on the line content. For click routing we
    // make the click target full-width (the user clicks anywhere on the row).
    for (line_idx, path) in recent_rect_starts {
        let row_y = top + line_idx as u16;
        if row_y >= area.y + area.height {
            break;
        }
        app.rects.dashboard_rows.push((
            Rect {
                x: area.x,
                y: row_y,
                width: area.width,
                height: 1,
            },
            path,
        ));
    }
}
