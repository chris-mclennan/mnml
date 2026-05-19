//! The graphical-Git-GUI-style commit-DAG pane (`Pane::GitGraph`). Top region: a
//! columnar list — `<lane-bar> <sel-arrow> <branch/tag chips> <graph> <subject>
//! · <author> <age> <sha>` with right-aligned trailing columns and a per-row
//! colored "swimlane indicator" cell in the commit's lane color. Bottom region:
//! the selected commit's full message + changed-file list. Read-only — `↑↓`
//! select, `Enter` opens the commit's diff, `r` refreshes, `y` copies the hash,
//! `/` enters hash-filter mode (type a partial hash prefix to jump). All wired
//! in `tui.rs`.

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

/// Per-column widths for the commit list. Computed once per render from the
/// pane width; right-side columns shrink first when space is tight.
struct ColWidths {
    /// Branch/tag chip column (0 disables it on a very narrow pane).
    branch: usize,
    /// Author column.
    author: usize,
    /// Humanized age column.
    age: usize,
    /// Short hash column (kept on at any width — small enough).
    sha: usize,
}

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

    // ── reserve a header row for column labels + the (optional) hash filter chip
    let header_area = Rect::new(list_area.x, list_area.y, list_area.width, 1);
    let body_area = Rect::new(
        list_area.x,
        list_area.y + 1,
        list_area.width,
        list_area.height.saturating_sub(1),
    );

    // ── commit list ────────────────────────────────────────────────
    let h = body_area.height as usize;
    if g.selected < g.scroll {
        g.scroll = g.selected;
    } else if g.selected >= g.scroll + h {
        g.scroll = g.selected + 1 - h;
    }
    let max_scroll = g.commits.len().saturating_sub(h.min(g.commits.len()));
    g.scroll = g.scroll.min(max_scroll);

    // Pre-compute the max graph-cell count across the visible window so the
    // graph column has a stable width and the right-aligned columns line up.
    let graph_w = g
        .commits
        .iter()
        .enumerate()
        .skip(g.scroll)
        .take(h)
        .map(|(_, c)| c.graph.len())
        .max()
        .unwrap_or(0)
        .min(24);
    let cols = compute_column_widths(body_area.width as usize, graph_w);

    // Column header
    draw_header(frame, header_area, &t, &cols, graph_w, &g.hash_filter);

    let mut rows: Vec<Line> = Vec::with_capacity(h);
    let mut row_recordings: Vec<(u16, usize)> = Vec::with_capacity(h);
    for (i, c) in g.commits.iter().enumerate().skip(g.scroll).take(h) {
        row_recordings.push(((i - g.scroll) as u16, i));
        let selected = i == g.selected;
        let row_bg = if selected { t.bg2 } else { t.bg_dark };
        let lane_clr = lane_color(&t, (c.lane % LANE_COLORS) as u8);
        let mut spans: Vec<Span> = Vec::new();
        // 1) Lane-color swimlane indicator (1 cell)
        spans.push(Span::styled("▌", Style::default().fg(lane_clr).bg(row_bg)));
        // 2) Selection arrow (1 cell + space)
        spans.push(Span::styled(
            if selected { "▶ " } else { "  " },
            Style::default().fg(t.yellow).bg(row_bg),
        ));
        // 3) Branch/tag chip column (fixed width, ellipsis-truncated)
        if cols.branch > 0 {
            render_branch_chips(&mut spans, &c.refs, cols.branch, row_bg, &t);
        }
        // 4) Graph cells (padded to graph_w so right columns line up)
        for k in 0..graph_w {
            if let Some(cell) = c.graph.get(k) {
                spans.push(Span::styled(
                    cell.ch.to_string(),
                    Style::default().fg(lane_color(&t, cell.color)).bg(row_bg),
                ));
            } else {
                spans.push(Span::styled(" ", Style::default().bg(row_bg)));
            }
        }
        spans.push(Span::styled("  ", Style::default().bg(row_bg)));
        // 5) Subject (flex — pad / truncate to fit the remaining width)
        let fixed_used = 1            // swimlane
            + 2                        // arrow
            + cols.branch              // branch chips
            + graph_w                  // graph
            + 2                        // graph→subject gap
            + cols.author + (if cols.author > 0 { 2 } else { 0 })
            + cols.age + (if cols.age > 0 { 2 } else { 0 })
            + cols.sha + (if cols.sha > 0 { 2 } else { 0 });
        let subject_w = (body_area.width as usize).saturating_sub(fixed_used);
        let subject = pad_or_truncate(&c.subject, subject_w);
        spans.push(Span::styled(subject, Style::default().fg(t.fg).bg(row_bg)));
        // 6) Author (right-aligned in its column)
        if cols.author > 0 {
            spans.push(Span::styled("  ", Style::default().bg(row_bg)));
            let author = right_align(&c.author, cols.author);
            spans.push(Span::styled(
                author,
                Style::default().fg(t.comment).bg(row_bg),
            ));
        }
        // 7) Age (right-aligned)
        if cols.age > 0 {
            spans.push(Span::styled("  ", Style::default().bg(row_bg)));
            let age = right_align(&humanize_age(now - c.time), cols.age);
            spans.push(Span::styled(age, Style::default().fg(t.comment).bg(row_bg)));
        }
        // 8) Short SHA
        if cols.sha > 0 {
            spans.push(Span::styled("  ", Style::default().bg(row_bg)));
            let sha = right_align(&c.short, cols.sha);
            spans.push(Span::styled(sha, Style::default().fg(t.orange).bg(row_bg)));
        }
        rows.push(Line::from(spans));
    }
    frame.render_widget(
        Paragraph::new(rows).style(Style::default().bg(t.bg_dark)),
        body_area,
    );
    for (visible_y, idx) in row_recordings {
        let screen_y = body_area.y.saturating_add(visible_y);
        if screen_y < body_area.y.saturating_add(body_area.height) {
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: body_area.x,
                    y: screen_y,
                    width: body_area.width,
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

/// Pick column widths from the available pane width. Author/age/sha get
/// shrunk first when space is tight; the branch chips column collapses
/// last (it carries the most identifying info per row after the subject).
fn compute_column_widths(total: usize, graph_w: usize) -> ColWidths {
    // Reserved space we always want: swimlane (1) + arrow (2) + graph
    // + graph→subject gap (2) + minimum subject (20).
    let min_fixed = 1 + 2 + graph_w + 2 + 20;
    let mut remaining = total.saturating_sub(min_fixed);

    let mut w = ColWidths {
        branch: 0,
        author: 0,
        age: 0,
        sha: 0,
    };
    // Short hash first (smallest, highest-value-per-cell).
    if remaining >= 9 + 2 {
        w.sha = 9;
        remaining -= 9 + 2;
    }
    if remaining >= 6 + 2 {
        w.age = 6;
        remaining -= 6 + 2;
    }
    if remaining >= 14 + 2 {
        w.author = 14;
        remaining -= 14 + 2;
    } else if remaining >= 10 + 2 {
        // Half-width author for medium-narrow panes.
        w.author = 10;
        remaining -= 10 + 2;
    }
    if remaining >= 18 {
        w.branch = remaining.min(28);
    }
    w
}

/// Draw the column-header row (faint labels) and, when a hash filter is
/// active, a chip showing the typed prefix.
fn draw_header(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    cols: &ColWidths,
    graph_w: usize,
    hash_filter: &str,
) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let bg = t.bg_darker;
    let mut spans: Vec<Span> = Vec::new();
    // Lane bar + arrow gutter
    spans.push(Span::styled("   ", Style::default().bg(bg)));
    // Branch column header
    if cols.branch > 0 {
        spans.push(Span::styled(
            pad_or_truncate("BRANCH / TAG", cols.branch),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    // Graph column header
    spans.push(Span::styled(
        pad_or_truncate("GRAPH", graph_w),
        Style::default()
            .fg(t.comment)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled("  ", Style::default().bg(bg)));
    // Subject header (flex)
    let fixed_used = 1
        + 2
        + cols.branch
        + graph_w
        + 2
        + cols.author
        + (if cols.author > 0 { 2 } else { 0 })
        + cols.age
        + (if cols.age > 0 { 2 } else { 0 })
        + cols.sha
        + (if cols.sha > 0 { 2 } else { 0 });
    let subject_w = (area.width as usize).saturating_sub(fixed_used);
    let subject_label = if hash_filter.is_empty() {
        pad_or_truncate("COMMIT MESSAGE", subject_w)
    } else {
        pad_or_truncate(&format!("/{hash_filter}_"), subject_w)
    };
    let label_style = if hash_filter.is_empty() {
        Style::default()
            .fg(t.comment)
            .bg(bg)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default()
            .fg(t.yellow)
            .bg(bg)
            .add_modifier(Modifier::BOLD)
    };
    spans.push(Span::styled(subject_label, label_style));
    if cols.author > 0 {
        spans.push(Span::styled("  ", Style::default().bg(bg)));
        spans.push(Span::styled(
            right_align("AUTHOR", cols.author),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    if cols.age > 0 {
        spans.push(Span::styled("  ", Style::default().bg(bg)));
        spans.push(Span::styled(
            right_align("AGE", cols.age),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    if cols.sha > 0 {
        spans.push(Span::styled("  ", Style::default().bg(bg)));
        spans.push(Span::styled(
            right_align("SHA", cols.sha),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(bg)),
        area,
    );
}

/// Render the branch/tag chips inside a fixed-width column. HEAD wins first,
/// then local branches, then remotes, then tags. Ellipsis-truncates when full.
fn render_branch_chips(
    spans: &mut Vec<Span<'static>>,
    refs: &[crate::git::log::RefLabel],
    width: usize,
    row_bg: Color,
    t: &Theme,
) {
    if width == 0 {
        return;
    }
    let mut sorted: Vec<&crate::git::log::RefLabel> = refs.iter().collect();
    sorted.sort_by_key(|r| match r.kind {
        RefKind::Head => 0,
        RefKind::LocalBranch => 1,
        RefKind::RemoteBranch => 2,
        RefKind::Tag => 3,
    });
    // Build (text, color, bold) chips.
    let mut chips: Vec<(String, Color, bool)> = Vec::with_capacity(sorted.len());
    for r in &sorted {
        let entry = match r.kind {
            RefKind::Head => (r.name.clone(), t.cyan, true),
            RefKind::LocalBranch => (r.name.clone(), t.green, false),
            RefKind::RemoteBranch => (r.name.clone(), t.purple, false),
            RefKind::Tag => (format!("⊙{}", r.name), t.yellow, false),
        };
        chips.push(entry);
    }

    let mut used = 0usize;
    let mut emitted = 0usize;
    for (i, (label, color, bold)) in chips.iter().enumerate() {
        let needed = label.chars().count() + if i + 1 < chips.len() { 1 } else { 0 };
        if used + needed > width {
            // Drop in an ellipsis "+N" chip if there's room.
            let remaining = chips.len() - i;
            let tail = format!("+{remaining}");
            let tail_w = tail.chars().count();
            if used + tail_w <= width {
                spans.push(Span::styled(
                    tail.clone(),
                    Style::default().fg(t.comment).bg(row_bg),
                ));
                used += tail_w;
            }
            break;
        }
        let mut st = Style::default().fg(*color).bg(row_bg);
        if *bold {
            st = st.add_modifier(Modifier::BOLD);
        }
        spans.push(Span::styled(label.clone(), st));
        used += label.chars().count();
        if i + 1 < chips.len() {
            spans.push(Span::styled(" ", Style::default().bg(row_bg)));
            used += 1;
        }
        emitted += 1;
    }
    let _ = emitted;
    // Pad to column width
    if used < width {
        spans.push(Span::styled(
            " ".repeat(width - used),
            Style::default().bg(row_bg),
        ));
    }
}

/// Pad / truncate `s` to exactly `width` display chars.
/// Truncation uses a `…` glyph when it shortens.
fn pad_or_truncate(s: &str, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let n = s.chars().count();
    if n == width {
        s.to_string()
    } else if n < width {
        format!("{}{}", s, " ".repeat(width - n))
    } else if width == 1 {
        "…".to_string()
    } else {
        let mut out: String = s.chars().take(width - 1).collect();
        out.push('…');
        out
    }
}

/// Right-align `s` inside a `width`-char column, truncating from the left with
/// `…` when too long.
fn right_align(s: &str, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let n = s.chars().count();
    if n == width {
        s.to_string()
    } else if n < width {
        format!("{}{}", " ".repeat(width - n), s)
    } else if width == 1 {
        "…".to_string()
    } else {
        let take = width - 1;
        let skip = n - take;
        let out: String = s.chars().skip(skip).collect();
        format!("…{out}")
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

    #[test]
    fn pad_or_truncate_pads_short_strings() {
        assert_eq!(pad_or_truncate("ab", 5), "ab   ");
    }

    #[test]
    fn pad_or_truncate_truncates_with_ellipsis() {
        assert_eq!(pad_or_truncate("hello world", 8), "hello w…");
    }

    #[test]
    fn pad_or_truncate_exact_width_passthrough() {
        assert_eq!(pad_or_truncate("hello", 5), "hello");
    }

    #[test]
    fn right_align_pads_left() {
        assert_eq!(right_align("ab", 5), "   ab");
    }

    #[test]
    fn right_align_truncates_from_left() {
        // Long string: keep the trailing chars with a leading ellipsis.
        assert_eq!(right_align("Christopher McLennan", 12), "…er McLennan");
    }

    #[test]
    fn compute_column_widths_wide_pane_includes_everything() {
        let c = compute_column_widths(200, 10);
        assert!(c.sha >= 9);
        assert!(c.age >= 6);
        assert!(c.author >= 10);
        assert!(c.branch >= 18);
    }

    #[test]
    fn compute_column_widths_narrow_collapses_right_to_left() {
        // Just barely enough room for the swimlane+arrow+graph+subject+sha.
        let c = compute_column_widths(45, 6);
        assert!(c.sha > 0, "sha should be the last to collapse");
    }

    #[test]
    fn compute_column_widths_very_narrow_keeps_subject_only() {
        let c = compute_column_widths(28, 4);
        assert_eq!(c.branch, 0);
        assert_eq!(c.author, 0);
    }
}
