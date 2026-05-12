//! The `git diff` pane (`Pane::Diff`). Renders parsed hunks — a `@@ … @@`
//! header per hunk (the cursor hunk highlighted), then context / `+` / `-`
//! lines (fg-coloured, with a `▏` marker). Read-only; `n`/`p` move the cursor
//! hunk, `s`/`u` stage/unstage it (handled in `tui.rs`). Long lines clip.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::git::diff::HunkLine;
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
    let Some(Pane::Diff(d)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    if d.hunks.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  (no changes)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ))),
            area,
        );
        app.rects.editor_panes.push((area, pane_id));
        return None;
    }
    d.cursor = d.cursor.min(d.hunks.len() - 1);

    // Build the flat row list + remember each hunk's first row (its header).
    let mut rows: Vec<Line> = Vec::new();
    let mut hunk_row: Vec<usize> = Vec::with_capacity(d.hunks.len());
    for (hi, h) in d.hunks.iter().enumerate() {
        hunk_row.push(rows.len());
        let on_cursor = hi == d.cursor;
        let head_bg = if on_cursor { t.bg2 } else { t.bg_dark };
        let mut head_style = Style::default().fg(t.cyan).bg(head_bg);
        if on_cursor {
            head_style = head_style.add_modifier(Modifier::BOLD);
        }
        rows.push(Line::from(vec![
            Span::styled(
                if on_cursor { "▶ " } else { "  " },
                Style::default().fg(t.yellow).bg(head_bg),
            ),
            Span::styled(format!("{}  ", h.header), head_style),
            Span::styled(h.file_rel.clone(), Style::default().fg(t.blue).bg(head_bg)),
        ]));
        for hl in &h.lines {
            let (marker, marker_color, body, fg) = match hl {
                HunkLine::Context(s) => (" ", t.grey, s.as_str(), t.fg),
                HunkLine::Added(s) => ("▏", t.green, s.as_str(), t.green),
                HunkLine::Removed(s) => ("▏", t.red, s.as_str(), t.red),
                HunkLine::NoNewline => (" ", t.grey, "\\ No newline at end of file", t.comment),
            };
            let sign = match hl {
                HunkLine::Added(_) => "+",
                HunkLine::Removed(_) => "-",
                _ => " ",
            };
            rows.push(Line::from(vec![
                Span::styled(marker, Style::default().fg(marker_color).bg(t.bg_dark)),
                Span::styled(
                    format!("{sign} {body}"),
                    Style::default().fg(fg).bg(t.bg_dark),
                ),
            ]));
        }
        rows.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        ))); // blank between hunks
    }

    // Keep the cursor hunk's header on screen.
    let h = area.height as usize;
    let target = hunk_row[d.cursor];
    if target < d.scroll {
        d.scroll = target;
    } else if target >= d.scroll + h {
        d.scroll = target + 1 - h;
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    d.scroll = d.scroll.min(max_scroll);

    let view: Vec<Line> = rows.into_iter().skip(d.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));
    None
}
