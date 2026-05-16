//! The staging view (`Pane::GitStatus`). Two sections — "Unstaged changes" and
//! "Staged changes" — with the highlighted file's row inverted. Read-only render;
//! `s`/`u`/Space stage/unstage, `a`/`A` all, Enter → diff, `c`/`C` commit, all
//! wired in `tui.rs`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::git::stage::Entry;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme::{self, Theme};

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

    let Some(Pane::GitStatus(g)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    let n = g.flat_len();
    if n > 0 {
        g.selected = g.selected.min(n - 1);
    }

    let mut lines: Vec<Line> = Vec::new();

    // ── header ─────────────────────────────────────────────────────
    let branch = g.branch.clone().unwrap_or_else(|| "(detached)".to_string());
    lines.push(Line::from(vec![
        Span::styled("  on ", Style::default().fg(t.comment).bg(t.bg_dark)),
        Span::styled(
            branch,
            Style::default()
                .fg(t.blue)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "   {} unstaged · {} staged",
                g.unstaged.len(),
                g.staged.len()
            ),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ]));
    let hint = if g.ai_msg_job.is_some() {
        "  ✦ asking Claude for a commit message…".to_string()
    } else {
        "  s/u stage·unstage  space toggle  a/A all  ⏎ diff  c commit  C ai-commit  r refresh"
            .to_string()
    };
    lines.push(Line::from(Span::styled(
        hint,
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));

    if n == 0 {
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        lines.push(Line::from(Span::styled(
            "  ✓ working tree clean",
            Style::default().fg(t.green).bg(t.bg_dark),
        )));
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }

    // ── sections ───────────────────────────────────────────────────
    // Track which rendered-line index holds the selected entry so we can scroll.
    let mut selected_row: usize = 0;
    let u = g.unstaged.len();

    section_header(&mut lines, &t, &format!("Unstaged changes ({u})"), t.yellow);
    if g.unstaged.is_empty() {
        lines.push(empty_note(&t, "    (none)"));
    }
    let mut row_indices: Vec<(usize, usize)> =
        Vec::with_capacity(g.unstaged.len() + g.staged.len());
    for (idx, e) in g.unstaged.iter().enumerate() {
        let sel = idx == g.selected;
        if sel {
            selected_row = lines.len();
        }
        row_indices.push((lines.len(), idx));
        lines.push(entry_line(&t, e, sel));
    }

    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));
    let s = g.staged.len();
    section_header(&mut lines, &t, &format!("Staged changes ({s})"), t.green);
    if g.staged.is_empty() {
        lines.push(empty_note(&t, "    (none)"));
    }
    for (idx, e) in g.staged.iter().enumerate() {
        let flat = u + idx;
        let sel = flat == g.selected;
        if sel {
            selected_row = lines.len();
        }
        row_indices.push((lines.len(), flat));
        lines.push(entry_line(&t, e, sel));
    }

    let h = area.height as usize;
    if selected_row < g.scroll {
        g.scroll = selected_row;
    } else if selected_row >= g.scroll + h {
        g.scroll = selected_row + 1 - h;
    }
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    g.scroll = g.scroll.min(max_scroll);

    for (line_y, idx) in &row_indices {
        if *line_y < g.scroll || *line_y >= g.scroll + h {
            continue;
        }
        let visible_y = line_y - g.scroll;
        let screen_y = area.y.saturating_add(visible_y as u16);
        if screen_y < area.y.saturating_add(area.height) {
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: area.x,
                    y: screen_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                *idx,
            ));
        }
    }

    let view: Vec<Line> = lines.into_iter().skip(g.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    None
}

fn section_header(
    lines: &mut Vec<Line<'static>>,
    t: &Theme,
    label: &str,
    color: ratatui::style::Color,
) {
    lines.push(Line::from(Span::styled(
        format!("  {label}"),
        Style::default()
            .fg(color)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));
}

fn empty_note(t: &Theme, text: &str) -> Line<'static> {
    Line::from(Span::styled(
        text.to_string(),
        Style::default().fg(t.comment).bg(t.bg_dark),
    ))
}

fn entry_line(t: &Theme, e: &Entry, selected: bool) -> Line<'static> {
    let bg = if selected { t.bg2 } else { t.bg_dark };
    let status_color = match e.status {
        'A' => t.green,
        'M' => t.yellow,
        'D' => t.red,
        'R' => t.blue,
        'C' => t.cyan,
        'U' => t.red,
        _ => t.comment, // '?'
    };
    Line::from(vec![
        Span::styled(
            if selected { "  ▶ " } else { "    " },
            Style::default().fg(t.yellow).bg(bg),
        ),
        Span::styled(
            format!("{} ", e.status),
            Style::default()
                .fg(status_color)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(e.rel.clone(), Style::default().fg(t.fg).bg(bg)),
    ])
}
