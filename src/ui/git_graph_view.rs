//! The graphical-Git-GUI-style commit-DAG pane (`Pane::GitGraph`). Top region: the lane
//! graph + a commit per row (`<graph> <hash> <refs> <subject>  <age> <author>`),
//! the selected row highlighted; bottom region: that commit's full message +
//! changed-file list. Read-only — `↑↓` select, `Enter` opens the commit's diff,
//! `r` refreshes, `y` copies the hash (all wired in `tui.rs`).

use std::time::{SystemTime, UNIX_EPOCH};

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::git::log::{Commit, LANE_COLORS, RefKind};
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

    let Some(Pane::GitGraph(g)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    if g.commits.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  (no commits — not a git repo, or empty history)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ))),
            area,
        );
        return None;
    }
    g.selected = g.selected.min(g.commits.len() - 1);

    // Split: a detail panel along the bottom when there's room.
    let detail_h: u16 = if area.height >= 12 {
        (area.height / 3).clamp(5, 14)
    } else {
        0
    };
    let (list_area, detail_area) = if detail_h > 0 {
        (
            Rect::new(area.x, area.y, area.width, area.height - detail_h),
            Some(Rect::new(
                area.x,
                area.y + area.height - detail_h,
                area.width,
                detail_h,
            )),
        )
    } else {
        (area, None)
    };

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    // ── commit list ────────────────────────────────────────────────
    let h = list_area.height as usize;
    if g.selected < g.scroll {
        g.scroll = g.selected;
    } else if g.selected >= g.scroll + h {
        g.scroll = g.selected + 1 - h;
    }
    let max_scroll = g.commits.len().saturating_sub(h.min(g.commits.len()));
    g.scroll = g.scroll.min(max_scroll);

    let mut rows: Vec<Line> = Vec::with_capacity(h);
    let mut row_recordings: Vec<(u16, usize)> = Vec::with_capacity(h);
    for (i, c) in g.commits.iter().enumerate().skip(g.scroll).take(h) {
        row_recordings.push(((i - g.scroll) as u16, i));
        let selected = i == g.selected;
        let row_bg = if selected { t.bg2 } else { t.bg_dark };
        let mut spans: Vec<Span> = Vec::new();
        // selection gutter
        spans.push(Span::styled(
            if selected { "▶" } else { " " },
            Style::default().fg(t.yellow).bg(row_bg),
        ));
        // graph cells
        for cell in &c.graph {
            spans.push(Span::styled(
                cell.ch.to_string(),
                Style::default().fg(lane_color(&t, cell.color)).bg(row_bg),
            ));
        }
        spans.push(Span::styled(" ", Style::default().bg(row_bg)));
        // short hash
        spans.push(Span::styled(
            format!("{} ", c.short),
            Style::default().fg(t.orange).bg(row_bg),
        ));
        // refs (chips)
        for r in &c.refs {
            let (label, color, bold) = match r.kind {
                RefKind::Head => (format!("{} ", r.name), t.cyan, true),
                RefKind::LocalBranch => (format!("[{}] ", r.name), t.green, false),
                RefKind::RemoteBranch => (format!("[{}] ", r.name), t.purple, false),
                RefKind::Tag => (format!("⊙{} ", r.name), t.yellow, false),
            };
            let mut st = Style::default().fg(color).bg(row_bg);
            if bold {
                st = st.add_modifier(Modifier::BOLD);
            }
            spans.push(Span::styled(label, st));
        }
        // subject
        spans.push(Span::styled(
            c.subject.clone(),
            Style::default().fg(t.fg).bg(row_bg),
        ));
        // age · author (dimmed, clips if narrow)
        spans.push(Span::styled(
            format!("  · {} · {}", humanize_age(now - c.time), c.author),
            Style::default().fg(t.comment).bg(row_bg),
        ));
        rows.push(Line::from(spans));
    }
    frame.render_widget(
        Paragraph::new(rows).style(Style::default().bg(t.bg_dark)),
        list_area,
    );
    for (visible_y, idx) in row_recordings {
        let screen_y = list_area.y.saturating_add(visible_y);
        if screen_y < list_area.y.saturating_add(list_area.height) {
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: list_area.x,
                    y: screen_y,
                    width: list_area.width,
                    height: 1,
                },
                pane_id,
                idx,
            ));
        }
    }

    // ── detail panel ───────────────────────────────────────────────
    if let (Some(da), Some(c), Some(detail)) =
        (detail_area, g.commits.get(g.selected), g.detail.as_ref())
    {
        draw_detail(frame, da, &t, c, detail, now);
    }

    None
}

fn draw_detail(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    c: &Commit,
    detail: &crate::git::graph::CommitDetail,
    now: i64,
) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    let w = area.width as usize;
    let mut lines: Vec<Line> = Vec::new();

    // header: ───── <hash> · <author> · <age> ─────
    let head = format!(
        " {} · {} · {} ",
        c.short,
        c.author,
        humanize_age(now - c.time)
    );
    let dashes = w.saturating_sub(head.chars().count() + 1);
    lines.push(Line::from(vec![
        Span::styled("─", Style::default().fg(t.line).bg(t.bg)),
        Span::styled(head, Style::default().fg(t.orange).bg(t.bg)),
        Span::styled("─".repeat(dashes), Style::default().fg(t.line).bg(t.bg)),
    ]));

    // commit message body
    for raw in detail.message.lines() {
        lines.push(Line::from(Span::styled(
            format!("  {raw}"),
            Style::default().fg(t.fg).bg(t.bg),
        )));
    }
    if !c.parents.is_empty() {
        lines.push(Line::from(Span::styled(
            format!(
                "  parents: {}",
                c.parents
                    .iter()
                    .map(|p| p.chars().take(9).collect::<String>())
                    .collect::<Vec<_>>()
                    .join("  ")
            ),
            Style::default().fg(t.comment).bg(t.bg),
        )));
    }
    lines.push(Line::from(Span::styled(" ", Style::default().bg(t.bg))));

    // changed files
    let avail = (area.height as usize).saturating_sub(lines.len() + 1);
    let total = detail.files.len();
    lines.push(Line::from(Span::styled(
        format!("  changed files ({total}):"),
        Style::default()
            .fg(t.comment)
            .bg(t.bg)
            .add_modifier(Modifier::BOLD),
    )));
    let shown = total.min(avail.saturating_sub(1));
    for (status, path) in detail.files.iter().take(shown) {
        let letter = status.chars().next().unwrap_or('?');
        let color = match letter {
            'A' => t.green,
            'M' => t.yellow,
            'D' => t.red,
            'R' => t.blue,
            'C' => t.cyan,
            _ => t.comment,
        };
        lines.push(Line::from(vec![
            Span::styled(format!("  {letter} "), Style::default().fg(color).bg(t.bg)),
            Span::styled(path.clone(), Style::default().fg(t.fg).bg(t.bg)),
        ]));
    }
    if shown < total {
        lines.push(Line::from(Span::styled(
            format!("  … and {} more", total - shown),
            Style::default().fg(t.comment).bg(t.bg),
        )));
    }

    frame.render_widget(Paragraph::new(lines).style(Style::default().bg(t.bg)), area);
}

/// Map a lane-colour index (`0..LANE_COLORS`) to a palette colour. The arms cover
/// `LANE_COLORS == 6`; the modulo keeps any future widening safe.
fn lane_color(t: &Theme, idx: u8) -> Color {
    match idx as usize % LANE_COLORS {
        0 => t.blue,
        1 => t.green,
        2 => t.yellow,
        3 => t.purple,
        4 => t.cyan,
        _ => t.orange,
    }
}

/// "3m" / "5h" / "2d" / "7w" / "4mo" / "2y" from a delta in seconds (≥0).
pub fn humanize_age(secs: i64) -> String {
    let s = secs.max(0);
    if s < 60 {
        return "now".to_string();
    }
    let m = s / 60;
    if m < 60 {
        return format!("{m}m");
    }
    let h = m / 60;
    if h < 24 {
        return format!("{h}h");
    }
    let d = h / 24;
    if d < 14 {
        return format!("{d}d");
    }
    let w = d / 7;
    if w < 9 {
        return format!("{w}w");
    }
    let mo = d / 30;
    if mo < 24 {
        return format!("{mo}mo");
    }
    format!("{}y", d / 365)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ages_humanize() {
        assert_eq!(humanize_age(10), "now");
        assert_eq!(humanize_age(120), "2m");
        assert_eq!(humanize_age(3 * 3600), "3h");
        assert_eq!(humanize_age(2 * 86400), "2d");
        assert_eq!(humanize_age(21 * 86400), "3w");
        assert_eq!(humanize_age(90 * 86400), "3mo");
        assert_eq!(humanize_age(800 * 86400), "2y");
    }
}
