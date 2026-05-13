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
        // Intraline-diff pairing: a singleton Removed immediately followed
        // by a singleton Added (i.e. one-for-one swap, no neighbour of the
        // same kind) gets char-level highlighting. The common prefix +
        // suffix render in muted gray; the differing middle keeps the
        // bright red/green so the eye lands on the change. Multi-line
        // edits skip this — pairing them would require an LCS.
        let pair_partner: Vec<Option<usize>> = (0..h.lines.len())
            .map(|i| {
                if !matches!(h.lines.get(i), Some(HunkLine::Removed(_))) {
                    return None;
                }
                if !matches!(h.lines.get(i + 1), Some(HunkLine::Added(_))) {
                    return None;
                }
                if i > 0 && matches!(h.lines.get(i - 1), Some(HunkLine::Removed(_))) {
                    return None;
                }
                if matches!(h.lines.get(i + 2), Some(HunkLine::Added(_))) {
                    return None;
                }
                Some(i + 1)
            })
            .collect();
        for (li, hl) in h.lines.iter().enumerate() {
            let (marker, marker_color, body, fg, sign) = match hl {
                HunkLine::Context(s) => (" ", t.grey, s.as_str(), t.fg, " "),
                HunkLine::Added(s) => ("▏", t.green, s.as_str(), t.green, "+"),
                HunkLine::Removed(s) => ("▏", t.red, s.as_str(), t.red, "-"),
                HunkLine::NoNewline => {
                    (" ", t.grey, "\\ No newline at end of file", t.comment, " ")
                }
            };
            // Is this line one half of an intraline-paired Removed+Added swap?
            // If so, compute the char-range of the differing middle and split
            // the body into prefix / middle / suffix spans.
            let intraline_range: Option<(usize, usize)> = match hl {
                HunkLine::Removed(s) if pair_partner[li].is_some() => {
                    let partner_idx = pair_partner[li].unwrap();
                    if let Some(HunkLine::Added(p)) = h.lines.get(partner_idx) {
                        let ((a, b), _) = crate::git::diff::intraline_diff(s, p);
                        Some((a, b))
                    } else {
                        None
                    }
                }
                HunkLine::Added(s) if li > 0 && pair_partner[li - 1] == Some(li) => {
                    if let Some(HunkLine::Removed(p)) = h.lines.get(li - 1) {
                        let (_, (a, b)) = crate::git::diff::intraline_diff(p, s);
                        Some((a, b))
                    } else {
                        None
                    }
                }
                _ => None,
            };

            let mut spans = vec![Span::styled(
                marker,
                Style::default().fg(marker_color).bg(t.bg_dark),
            )];
            if let Some((mid_start, mid_end)) = intraline_range
                && mid_end > mid_start
            {
                let body_chars: Vec<char> = body.chars().collect();
                let prefix: String = body_chars[..mid_start].iter().collect();
                let middle: String = body_chars[mid_start..mid_end].iter().collect();
                let suffix: String = body_chars[mid_end..].iter().collect();
                spans.push(Span::styled(
                    format!("{sign} {prefix}"),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                ));
                spans.push(Span::styled(
                    middle,
                    Style::default()
                        .fg(fg)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(
                    suffix,
                    Style::default().fg(t.comment).bg(t.bg_dark),
                ));
            } else {
                spans.push(Span::styled(
                    format!("{sign} {body}"),
                    Style::default().fg(fg).bg(t.bg_dark),
                ));
            }
            rows.push(Line::from(spans));
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
