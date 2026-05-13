//! The workspace-grep results list (`Pane::Grep`) — every match for the active
//! query, grouped under a small per-file header (`▸ rel.path  (N)`). The
//! selected match is inverted; `Enter` opens its file + jumps. Read-only;
//! `↑↓`/`jk`/PgUp/PgDn/g/G select, `r` re-runs the same query, `Esc` → tree
//! (all wired in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::grep_pane::GrepHit;
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

    let Some(Pane::Grep(g)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    g.clamp();

    let mut lines: Vec<Line> = Vec::new();

    // ── header ─────────────────────────────────────────────────────
    let n = g.hits.len();
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            format!("{n} match{}", if n == 1 { "" } else { "es" }),
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("   ·   ", Style::default().fg(t.comment).bg(t.bg_dark)),
        Span::styled(
            format!("{}: ", g.used),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
        Span::styled(
            g.query.clone(),
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        "  ⏎ jump   r re-run   R replace-all   esc back",
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));

    if g.hits.is_empty() {
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        lines.push(Line::from(Span::styled(
            "  · no matches",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }

    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));

    let mut selected_row = lines.len();
    let mut last_rel: Option<&str> = None;
    // For the per-file header, pre-count adjacent hits with the same `rel` so
    // the header can show `(N)`.
    let mut counts_iter = group_counts(&g.hits).into_iter();
    for (idx, hit) in g.hits.iter().enumerate() {
        if last_rel != Some(hit.rel.as_str()) {
            last_rel = Some(hit.rel.as_str());
            let cnt = counts_iter.next().unwrap_or(0);
            lines.push(file_header_line(&t, &hit.rel, cnt));
        }
        let sel = idx == g.selected;
        if sel {
            selected_row = lines.len();
        }
        lines.push(hit_line(&t, hit, sel));
    }

    // ── scroll to keep the selected row visible ────────────────────
    let h = area.height as usize;
    if selected_row < g.scroll {
        g.scroll = selected_row;
    } else if selected_row >= g.scroll + h {
        g.scroll = selected_row + 1 - h;
    }
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    g.scroll = g.scroll.min(max_scroll);

    let view: Vec<Line> = lines.into_iter().skip(g.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    None
}

/// For each *run* of adjacent hits with the same `rel`, the size of that run.
/// (The grep tool's output is already grouped by file, so a single pass is fine.)
fn group_counts(hits: &[GrepHit]) -> Vec<usize> {
    let mut out = Vec::new();
    let mut last: Option<&str> = None;
    for h in hits {
        if last == Some(h.rel.as_str()) {
            *out.last_mut().unwrap() += 1;
        } else {
            out.push(1);
            last = Some(h.rel.as_str());
        }
    }
    out
}

fn file_header_line(t: &Theme, rel: &str, count: usize) -> Line<'static> {
    Line::from(vec![
        Span::styled("  ▸ ", Style::default().fg(t.blue).bg(t.bg_dark)),
        Span::styled(
            rel.to_string(),
            Style::default()
                .fg(t.blue)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  ({count})"),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ])
}

fn hit_line(t: &Theme, h: &GrepHit, selected: bool) -> Line<'static> {
    let bg = if selected { t.bg2 } else { t.bg_dark };
    Line::from(vec![
        Span::styled(
            if selected { "  ▶ " } else { "      " },
            Style::default().fg(t.yellow).bg(bg),
        ),
        Span::styled(
            format!("{}:{}", h.line + 1, h.col + 1),
            Style::default().fg(t.comment).bg(bg),
        ),
        Span::styled("  ", Style::default().bg(bg)),
        Span::styled(h.text.clone(), Style::default().fg(t.fg).bg(bg)),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn hit(rel: &str) -> GrepHit {
        GrepHit {
            path: PathBuf::from(format!("/ws/{rel}")),
            rel: rel.into(),
            line: 0,
            col: 0,
            text: "t".into(),
        }
    }

    #[test]
    fn group_counts_collapses_runs() {
        let hits = vec![hit("a"), hit("a"), hit("b"), hit("a"), hit("c"), hit("c")];
        assert_eq!(group_counts(&hits), vec![2, 1, 1, 2]);
    }
}
