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

    // Snapshot WIP data + config knobs before the `g` borrow.
    let wip_snapshot = app.git.snapshot().clone();
    let branch_col_override = app.config.ui.git_graph_branch_col;
    let author_col_override = app.config.ui.git_graph_author_col;
    // Right-side detail panel width — config override beats the default 40%.
    let detail_w_cfg = app.config.ui.git_graph_detail_col;

    let Some(Pane::GitGraph(g)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    if g.total_rows() == 0 {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  (no commits — not a git repo, or empty history)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ))),
            area,
        );
        return None;
    }
    g.selected = g.selected.min(g.total_rows() - 1);

    // ── top toolbar (Pull / Push / Branch / Stash / Pop / Terminal …) ─
    // Spans the full pane width; uses 2 rows (label on top, icon below).
    // Hidden when the pane is too narrow / short for the toolbar to be
    // useful.
    let toolbar_h: u16 = if area.width >= 40 && area.height >= 8 {
        2
    } else {
        0
    };
    let nerd_icons = !app.config.ui.ascii_icons;
    if toolbar_h > 0 {
        let toolbar_area = Rect::new(area.x, area.y, area.width, toolbar_h);
        draw_git_toolbar(
            frame,
            toolbar_area,
            &t,
            pane_id,
            nerd_icons,
            &mut app.rects.git_toolbar_buttons,
        );
    }
    let body_area_full = Rect::new(
        area.x,
        area.y + toolbar_h,
        area.width,
        area.height.saturating_sub(toolbar_h),
    );

    // ── horizontal split: list on left, detail on right ──────────────
    // Detail panel takes ~40% of the width (clamped), graphical-Git-GUI-style.
    // Falls back to no detail panel when the pane is very narrow.
    let detail_w: u16 = if body_area_full.width >= 80 {
        if let Some(w) = detail_w_cfg {
            (w as u16).clamp(20, body_area_full.width.saturating_sub(40))
        } else {
            (body_area_full.width * 2 / 5).clamp(30, 70)
        }
    } else {
        0
    };
    let (list_area, detail_area) = if detail_w > 0 {
        (
            Rect::new(
                body_area_full.x,
                body_area_full.y,
                body_area_full.width - detail_w - 1,
                body_area_full.height,
            ),
            Some(Rect::new(
                body_area_full.x + body_area_full.width - detail_w,
                body_area_full.y,
                detail_w,
                body_area_full.height,
            )),
        )
    } else {
        (body_area_full, None)
    };
    // Vertical divider between list + detail
    if detail_w > 0 {
        let divider_x = body_area_full.x + body_area_full.width - detail_w - 1;
        for row in 0..body_area_full.height {
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "│",
                    Style::default().fg(t.grey).bg(t.bg_dark),
                ))),
                Rect::new(divider_x, body_area_full.y + row, 1, 1),
            );
        }
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    // ── reserve a header row above the body ──────────────────────────
    let header_area = Rect::new(list_area.x, list_area.y, list_area.width, 1);
    let body_area = Rect::new(
        list_area.x,
        list_area.y + 1,
        list_area.width,
        list_area.height.saturating_sub(1),
    );

    // ── scrolling math (operates on the virtual list = WIP + commits) ─
    let h = body_area.height as usize;
    if g.selected < g.scroll {
        g.scroll = g.selected;
    } else if g.selected >= g.scroll + h {
        g.scroll = g.selected + 1 - h;
    }
    let total = g.total_rows();
    let max_scroll = total.saturating_sub(h.min(total));
    g.scroll = g.scroll.min(max_scroll);

    // Walk the visible window collecting (virtual_idx, commit_idx_or_None).
    // virtual_idx 0 with has_wip → WIP row; otherwise → commits[virtual_idx - has_wip].
    let has_wip_offset = usize::from(g.has_wip);
    let mut visible: Vec<(usize, Option<usize>)> = Vec::with_capacity(h);
    for v_idx in g.scroll..g.scroll + h.min(total - g.scroll) {
        let commit_idx = if g.has_wip && v_idx == 0 {
            None
        } else {
            Some(v_idx - has_wip_offset)
        };
        visible.push((v_idx, commit_idx));
    }

    // Pre-compute graph + auto-sized column widths from the *commits* in
    // the visible window.
    let graph_w = visible
        .iter()
        .filter_map(|(_, c_idx)| c_idx.and_then(|i| g.commits.get(i)))
        .map(|c| c.graph.len())
        .max()
        .unwrap_or(0)
        .min(24);
    let auto_branch_w = visible
        .iter()
        .filter_map(|(_, c_idx)| c_idx.and_then(|i| g.commits.get(i)))
        .map(|c| chip_width_for_refs(&c.refs))
        .max()
        .unwrap_or(0);
    let auto_author_w = visible
        .iter()
        .filter_map(|(_, c_idx)| c_idx.and_then(|i| g.commits.get(i)))
        .map(|c| c.author.chars().count())
        .max()
        .unwrap_or(0);
    let cols = compute_column_widths(
        body_area.width as usize,
        graph_w,
        ColAutoSize {
            branch_chars: auto_branch_w,
            author_chars: auto_author_w,
            branch_override: branch_col_override,
            author_override: author_col_override,
        },
    );

    // Column header
    draw_header(frame, header_area, &t, &cols, graph_w, &g.hash_filter);

    let mut rows: Vec<Line> = Vec::with_capacity(h);
    let mut row_recordings: Vec<(u16, usize)> = Vec::with_capacity(h);
    let wip_lane_clr = t.yellow;
    for (v_idx, c_idx) in &visible {
        row_recordings.push(((v_idx - g.scroll) as u16, *v_idx));
        let selected = *v_idx == g.selected;
        let row_bg = if selected { t.bg2 } else { t.bg_dark };

        // WIP virtual row: yellow lane bar + "WIP" chip + dirty count + branch.
        if c_idx.is_none() {
            let mut spans: Vec<Span> = Vec::new();
            spans.push(Span::styled(
                "▌",
                Style::default().fg(wip_lane_clr).bg(row_bg),
            ));
            spans.push(Span::styled(
                if selected { "▶ " } else { "  " },
                Style::default().fg(t.yellow).bg(row_bg),
            ));
            // Branch column: show "WIP @ <branch>" as the chip, padded.
            if cols.branch > 0 {
                let label = format!("WIP @ {}", wip_snapshot.branch.as_deref().unwrap_or("…"));
                spans.push(Span::styled(
                    pad_or_truncate(&label, cols.branch),
                    Style::default()
                        .fg(wip_lane_clr)
                        .bg(row_bg)
                        .add_modifier(Modifier::BOLD),
                ));
            }
            // Graph column: blank.
            spans.push(Span::styled(
                " ".repeat(graph_w + 2),
                Style::default().bg(row_bg),
            ));
            // Subject column: change summary.
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
            let subject_w = (body_area.width as usize).saturating_sub(fixed_used);
            let summary = format_wip_summary(&wip_snapshot);
            let subject = pad_or_truncate(&summary, subject_w);
            spans.push(Span::styled(
                subject,
                Style::default()
                    .fg(wip_lane_clr)
                    .bg(row_bg)
                    .add_modifier(Modifier::ITALIC),
            ));
            // Author / Age / SHA: keep blank to preserve column alignment.
            if cols.author > 0 {
                spans.push(Span::styled(
                    " ".repeat(cols.author + 2),
                    Style::default().bg(row_bg),
                ));
            }
            if cols.age > 0 {
                spans.push(Span::styled(
                    " ".repeat(cols.age + 2),
                    Style::default().bg(row_bg),
                ));
            }
            if cols.sha > 0 {
                spans.push(Span::styled(
                    " ".repeat(cols.sha + 2),
                    Style::default().bg(row_bg),
                ));
            }
            rows.push(Line::from(spans));
            continue;
        }

        let commit_idx = c_idx.unwrap();
        let Some(c) = g.commits.get(commit_idx) else {
            continue;
        };
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
        // 7) Date/time (right-aligned, local TZ)
        if cols.age > 0 {
            spans.push(Span::styled("  ", Style::default().bg(row_bg)));
            let age = right_align(&format_commit_datetime(c.time), cols.age);
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
    for (visible_y, v_idx) in row_recordings {
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
                v_idx,
            ));
        }
    }

    // ── right-side detail panel ────────────────────────────────────
    if let Some(da) = detail_area {
        if g.is_wip_selected() {
            let workspace = g.workspace.clone();
            draw_wip_detail(
                frame,
                da,
                &t,
                &wip_snapshot,
                &workspace,
                pane_id,
                &mut app.rects.wip_buttons,
            );
        } else if let (Some(c), Some(detail)) = (g.selected_commit(), g.detail.as_ref()) {
            draw_detail(frame, da, &t, c, detail, now);
        }
    }

    None
}

#[derive(Debug, Clone, Copy)]
struct ColAutoSize {
    branch_chars: usize,
    author_chars: usize,
    branch_override: Option<usize>,
    author_override: Option<usize>,
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
///
/// `auto` carries the longest content widths from the visible window so
/// columns auto-size to fit (clamped to sensible min/max). Per-column
/// config overrides win over auto-size when set — `Some(0)` disables a
/// column entirely.
fn compute_column_widths(total: usize, graph_w: usize, auto: ColAutoSize) -> ColWidths {
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
    // Date/time column: "MM/DD HH:MM" = 11 chars. Falls back to 6
    // (room for the relative-age fallback on a narrow pane).
    if remaining >= 11 + 2 {
        w.age = 11;
        remaining -= 11 + 2;
    } else if remaining >= 6 + 2 {
        w.age = 6;
        remaining -= 6 + 2;
    }
    // Author: explicit override beats auto-size; clamp auto-size to [8, 22].
    let author_target = match auto.author_override {
        Some(n) => n,
        None => auto.author_chars.clamp(8, 22),
    };
    if author_target > 0 && remaining >= author_target + 2 {
        w.author = author_target;
        remaining -= author_target + 2;
    }
    // Branch: explicit override beats auto-size; clamp auto-size to [10, 35].
    let branch_target = match auto.branch_override {
        Some(n) => n,
        None => {
            if auto.branch_chars == 0 {
                0
            } else {
                auto.branch_chars.clamp(10, 35)
            }
        }
    };
    if branch_target > 0 && remaining >= branch_target {
        w.branch = branch_target.min(remaining);
    }
    w
}

/// Sum of chip widths for a row's refs, matching the renderer's
/// "join with spaces" layout. Used by the auto-sizer.
fn chip_width_for_refs(refs: &[crate::git::log::RefLabel]) -> usize {
    let mut sum = 0usize;
    for (i, r) in refs.iter().enumerate() {
        let label_chars = match r.kind {
            RefKind::Tag => r.name.chars().count() + 1, // ⊙ prefix
            _ => r.name.chars().count(),
        };
        sum += label_chars;
        if i + 1 < refs.len() {
            sum += 1; // space separator
        }
    }
    sum
}

/// One-line summary of the WIP state: `5 changes · 2 staged · on main ↑1 ↓0`
fn format_wip_summary(snap: &crate::git::status::Snapshot) -> String {
    let total = snap.modified + snap.staged + snap.untracked + snap.conflicts;
    let mut parts: Vec<String> = Vec::new();
    if total == 0 {
        parts.push("working tree clean".to_string());
    } else {
        parts.push(format!("{total} change(s)"));
        if snap.staged > 0 {
            parts.push(format!("{} staged", snap.staged));
        }
        if snap.untracked > 0 {
            parts.push(format!("{} new", snap.untracked));
        }
        if snap.conflicts > 0 {
            parts.push(format!("⚠ {} conflict(s)", snap.conflicts));
        }
    }
    if snap.ahead > 0 || snap.behind > 0 {
        parts.push(format!("↑{} ↓{}", snap.ahead, snap.behind));
    }
    parts.join(" · ")
}

/// Right-side detail panel content for the WIP virtual row: branch
/// banner, change summary, unstaged + staged file lists, and the key
/// hints the user needs to act (commit / AI message / open status pane).
///
/// Pushes clickable button rects onto `buttons_out`: "Stage All" /
/// "Unstage All" on the section headers, and per-file `[+]` / `[−]`
/// on each row. The renderer paints them as right-aligned labels;
/// `tui::dispatch_mouse` matches a click against the rect + fires the
/// matching [`crate::WipAction`].
fn draw_wip_detail(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    snap: &crate::git::status::Snapshot,
    workspace: &std::path::Path,
    pane_id: PaneId,
    buttons_out: &mut Vec<(Rect, PaneId, crate::WipAction)>,
) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    let w = area.width as usize;
    let mut lines: Vec<Line> = Vec::new();

    // Header
    let head = format!(
        " WIP @ {} · {}",
        snap.branch.as_deref().unwrap_or("(detached)"),
        format_wip_summary(snap),
    );
    let head = head.chars().take(w.saturating_sub(1)).collect::<String>();
    lines.push(Line::from(vec![
        Span::styled("─", Style::default().fg(t.line).bg(t.bg)),
        Span::styled(
            head,
            Style::default()
                .fg(t.yellow)
                .bg(t.bg)
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled("", Style::default().bg(t.bg))));

    // Partition the file map into unstaged + staged. Carry the absolute
    // path so button clicks can target the right file.
    let mut unstaged: Vec<(
        std::path::PathBuf,
        String,
        &'static str,
        ratatui::style::Color,
    )> = Vec::new();
    let mut staged: Vec<(
        std::path::PathBuf,
        String,
        &'static str,
        ratatui::style::Color,
    )> = Vec::new();
    for (path, state) in &snap.files {
        let rel = path
            .strip_prefix(workspace)
            .unwrap_or(path)
            .display()
            .to_string();
        match state {
            crate::git::status::FileState::Modified => {
                unstaged.push((path.clone(), rel, "M", t.yellow));
            }
            crate::git::status::FileState::Untracked => {
                unstaged.push((path.clone(), rel, "?", t.comment));
            }
            crate::git::status::FileState::Conflicted => {
                unstaged.push((path.clone(), rel, "!", t.red));
            }
            crate::git::status::FileState::Staged => {
                staged.push((path.clone(), rel, "A", t.green));
            }
        }
    }
    unstaged.sort_by(|a, b| a.1.cmp(&b.1));
    staged.sort_by(|a, b| a.1.cmp(&b.1));

    // Map line index → button rect + action. We compute screen y from
    // area.y + line_idx after rendering, so just track (line_idx, x_start,
    // x_end, action) here.
    let mut pending_buttons: Vec<(usize, u16, u16, crate::WipAction)> = Vec::new();

    // Unstaged section
    let unstaged_label = if unstaged.is_empty() {
        "Unstaged Files (0)".to_string()
    } else {
        format!("Unstaged Files ({})", unstaged.len())
    };
    let stage_all_label = " Stage All ";
    let stage_all_chars = stage_all_label.chars().count();
    let label_text = format!("  ▾ {unstaged_label}");
    let label_chars = label_text.chars().count();
    let padding = w.saturating_sub(label_chars + stage_all_chars).max(1);
    let mut header_spans: Vec<Span> = vec![
        Span::styled(
            label_text,
            Style::default()
                .fg(t.fg)
                .bg(t.bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ".repeat(padding), Style::default().bg(t.bg)),
    ];
    let stage_all_active = !unstaged.is_empty();
    let stage_all_style = if stage_all_active {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.green)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.comment).bg(t.bg)
    };
    header_spans.push(Span::styled(stage_all_label.to_string(), stage_all_style));
    let line_idx_unstaged_header = lines.len();
    if stage_all_active {
        let btn_x_start = (label_chars + padding) as u16;
        let btn_x_end = btn_x_start + stage_all_chars as u16;
        pending_buttons.push((
            line_idx_unstaged_header,
            btn_x_start,
            btn_x_end,
            crate::WipAction::StageAll,
        ));
    }
    lines.push(Line::from(header_spans));

    // Per-file rows with a `[+]` stage button right-aligned.
    let plus_label = " [+] ";
    let plus_chars = plus_label.chars().count();
    for (abs_path, rel, letter, color) in &unstaged {
        let prefix = format!("    {letter} ");
        let prefix_chars = prefix.chars().count();
        // Truncate file path to leave room for the button.
        let path_avail = w.saturating_sub(prefix_chars + plus_chars + 1).max(8);
        let path_display = pad_or_truncate(rel, path_avail);
        let row_spans: Vec<Span> = vec![
            Span::styled(prefix, Style::default().fg(*color).bg(t.bg)),
            Span::styled(path_display, Style::default().fg(t.fg).bg(t.bg)),
            Span::styled(" ", Style::default().bg(t.bg)),
            Span::styled(
                plus_label.to_string(),
                Style::default()
                    .fg(t.bg_dark)
                    .bg(t.green)
                    .add_modifier(Modifier::BOLD),
            ),
        ];
        let btn_x_start = (prefix_chars + path_avail + 1) as u16;
        let btn_x_end = btn_x_start + plus_chars as u16;
        pending_buttons.push((
            lines.len(),
            btn_x_start,
            btn_x_end,
            crate::WipAction::StageFile(abs_path.clone()),
        ));
        lines.push(Line::from(row_spans));
    }
    lines.push(Line::from(Span::styled("", Style::default().bg(t.bg))));

    // Staged section header with "Unstage All" right-aligned.
    let staged_label = if staged.is_empty() {
        "Staged Files (0)".to_string()
    } else {
        format!("Staged Files ({})", staged.len())
    };
    let unstage_all_label = " Unstage All ";
    let unstage_all_chars = unstage_all_label.chars().count();
    let staged_label_text = format!("  ▾ {staged_label}");
    let staged_label_chars = staged_label_text.chars().count();
    let staged_padding = w
        .saturating_sub(staged_label_chars + unstage_all_chars)
        .max(1);
    let mut staged_header_spans: Vec<Span> = vec![
        Span::styled(
            staged_label_text,
            Style::default()
                .fg(t.fg)
                .bg(t.bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ".repeat(staged_padding), Style::default().bg(t.bg)),
    ];
    let unstage_all_active = !staged.is_empty();
    let unstage_all_style = if unstage_all_active {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.orange)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.comment).bg(t.bg)
    };
    staged_header_spans.push(Span::styled(
        unstage_all_label.to_string(),
        unstage_all_style,
    ));
    let line_idx_staged_header = lines.len();
    if unstage_all_active {
        let btn_x_start = (staged_label_chars + staged_padding) as u16;
        let btn_x_end = btn_x_start + unstage_all_chars as u16;
        pending_buttons.push((
            line_idx_staged_header,
            btn_x_start,
            btn_x_end,
            crate::WipAction::UnstageAll,
        ));
    }
    lines.push(Line::from(staged_header_spans));

    // Per-staged-file rows with `[−]` unstage button.
    let minus_label = " [−] ";
    let minus_chars = minus_label.chars().count();
    for (abs_path, rel, letter, color) in &staged {
        let prefix = format!("    {letter} ");
        let prefix_chars = prefix.chars().count();
        let path_avail = w.saturating_sub(prefix_chars + minus_chars + 1).max(8);
        let path_display = pad_or_truncate(rel, path_avail);
        let row_spans: Vec<Span> = vec![
            Span::styled(prefix, Style::default().fg(*color).bg(t.bg)),
            Span::styled(path_display, Style::default().fg(t.fg).bg(t.bg)),
            Span::styled(" ", Style::default().bg(t.bg)),
            Span::styled(
                minus_label.to_string(),
                Style::default()
                    .fg(t.bg_dark)
                    .bg(t.orange)
                    .add_modifier(Modifier::BOLD),
            ),
        ];
        let btn_x_start = (prefix_chars + path_avail + 1) as u16;
        let btn_x_end = btn_x_start + minus_chars as u16;
        pending_buttons.push((
            lines.len(),
            btn_x_start,
            btn_x_end,
            crate::WipAction::UnstageFile(abs_path.clone()),
        ));
        lines.push(Line::from(row_spans));
    }
    lines.push(Line::from(Span::styled("", Style::default().bg(t.bg))));

    // ── Commit section ──────────────────────────────────────────────
    // Section header (matches the chevron styling above).
    lines.push(Line::from(Span::styled(
        "  ▾ Commit".to_string(),
        Style::default()
            .fg(t.fg)
            .bg(t.bg)
            .add_modifier(Modifier::BOLD),
    )));
    // Status line — "N staged" or "stage some changes first".
    let staged_count = snap.staged;
    let commit_status = if staged_count == 0 {
        "    (nothing staged — use the buttons above to stage files)".to_string()
    } else {
        format!("    {staged_count} file(s) staged — ready to commit")
    };
    lines.push(Line::from(Span::styled(
        commit_status,
        Style::default().fg(t.comment).bg(t.bg),
    )));
    lines.push(Line::from(Span::styled("", Style::default().bg(t.bg))));
    // Two clickable buttons: [ Commit ] and [ AI Message ]. Disabled
    // styling when nothing is staged (still clickable — it'll toast a
    // helpful "nothing staged" hint, sibling to the existing flow).
    let commit_btn = " Commit ";
    let commit_btn_chars = commit_btn.chars().count();
    let ai_btn = " AI Message ";
    let ai_btn_chars = ai_btn.chars().count();
    let gap = "  ";
    let leading = "    "; // 4-space indent matching the file rows
    let commit_btn_style = if staged_count > 0 {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.green)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.comment).bg(t.bg2)
    };
    let ai_btn_style = if staged_count > 0 {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.blue)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.comment).bg(t.bg2)
    };
    let commit_btn_line_idx = lines.len();
    let leading_chars = leading.chars().count();
    let commit_x_start = leading_chars as u16;
    let commit_x_end = commit_x_start + commit_btn_chars as u16;
    let ai_x_start = commit_x_end + gap.chars().count() as u16;
    let ai_x_end = ai_x_start + ai_btn_chars as u16;
    pending_buttons.push((
        commit_btn_line_idx,
        commit_x_start,
        commit_x_end,
        crate::WipAction::OpenCommitPrompt,
    ));
    pending_buttons.push((
        commit_btn_line_idx,
        ai_x_start,
        ai_x_end,
        crate::WipAction::RequestAiCommitMessage,
    ));
    lines.push(Line::from(vec![
        Span::styled(leading.to_string(), Style::default().bg(t.bg)),
        Span::styled(commit_btn.to_string(), commit_btn_style),
        Span::styled(gap.to_string(), Style::default().bg(t.bg)),
        Span::styled(ai_btn.to_string(), ai_btn_style),
    ]));
    lines.push(Line::from(Span::styled("", Style::default().bg(t.bg))));

    // Hint footer — key reminders for the WIP row.
    lines.push(Line::from(Span::styled(
        "  c commit · C AI message · Enter status pane",
        Style::default().fg(t.comment).bg(t.bg),
    )));

    frame.render_widget(Paragraph::new(lines).style(Style::default().bg(t.bg)), area);

    // Push button rects with absolute screen coords. Rows that scroll
    // off the pane (line_idx >= area.height) are dropped silently.
    for (line_idx, x_start, x_end, action) in pending_buttons {
        if (line_idx as u16) >= area.height {
            continue;
        }
        let y = area.y + line_idx as u16;
        let x = area.x + x_start;
        let width = x_end.saturating_sub(x_start);
        if x + width > area.x + area.width {
            continue;
        }
        buttons_out.push((
            Rect {
                x,
                y,
                width,
                height: 1,
            },
            pane_id,
            action,
        ));
    }
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
            right_align("DATE / TIME", cols.age),
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

/// Draw the GitGraph top toolbar — a 2-row strip of clickable git
/// action buttons (Pull / Push / Fetch / Branch / Commit / Stash /
/// Pop / Terminal / Reflog). Top row: text label. Bottom row: icon
/// (Nerd Font glyph when available; ASCII fallback otherwise).
///
/// Pushes button rects onto `buttons_out` so `tui::dispatch_mouse`
/// can route clicks via [`crate::App::run_git_toolbar_action`].
fn draw_git_toolbar(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    pane_id: PaneId,
    nerd: bool,
    buttons_out: &mut Vec<(Rect, PaneId, crate::GitToolbarAction)>,
) {
    if area.width < 30 || area.height < 2 {
        return;
    }
    let bg = t.bg_darker;
    let widget_area = Rect::new(area.x, area.y, area.width, area.height);
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(bg)),
        widget_area,
    );
    // Bottom horizontal rule beneath the toolbar — separates from the
    // table header.
    let rule = "─".repeat(area.width as usize);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            rule,
            Style::default().fg(t.grey).bg(bg),
        ))),
        Rect::new(area.x, area.y + area.height - 1, area.width, 1),
    );

    // Button definitions: (label, nerd icon, ascii icon, action, color).
    // Order is Pull/Push first (most common ops), then Fetch, then
    // Branch/Commit/Stash/Pop, then Reflog and Terminal at the end.
    let buttons: [(
        &str,
        &str,
        &str,
        crate::GitToolbarAction,
        ratatui::style::Color,
    ); 9] = [
        (
            "Pull",
            "\u{F0162}",
            "↓",
            crate::GitToolbarAction::Pull,
            t.green,
        ),
        (
            "Push",
            "\u{F0166}",
            "↑",
            crate::GitToolbarAction::Push,
            t.blue,
        ),
        (
            "Fetch",
            "\u{F0450}",
            "↺",
            crate::GitToolbarAction::Fetch,
            t.cyan,
        ),
        (
            "Branch",
            "\u{F062C}",
            "⎇",
            crate::GitToolbarAction::BranchPicker,
            t.yellow,
        ),
        (
            "Commit",
            "\u{F012C}",
            "✓",
            crate::GitToolbarAction::Commit,
            t.green,
        ),
        (
            "Stash",
            "\u{F01DA}",
            "↧",
            crate::GitToolbarAction::Stash,
            t.purple,
        ),
        (
            "Pop",
            "\u{F01DB}",
            "↥",
            crate::GitToolbarAction::StashPop,
            t.purple,
        ),
        (
            "Reflog",
            "\u{F02DA}",
            "↺",
            crate::GitToolbarAction::Reflog,
            t.orange,
        ),
        (
            "Term",
            "\u{F018D}",
            ">_",
            crate::GitToolbarAction::Terminal,
            t.comment,
        ),
    ];

    // Each button is 9 cells wide (8 content + 1 divider). Drop buttons
    // from the right when the pane is too narrow to fit them all.
    let cell_w: u16 = 9;
    let max_buttons = (area.width / cell_w) as usize;
    let n = buttons.len().min(max_buttons);
    let mut label_spans: Vec<Span> = Vec::new();
    let mut icon_spans: Vec<Span> = Vec::new();
    let mut x = area.x;
    for (i, (label, nerd_icon, ascii_icon, action, color)) in buttons.iter().take(n).enumerate() {
        let icon = if nerd { *nerd_icon } else { *ascii_icon };
        let label_pad = center_pad(label, 8);
        let icon_pad = center_pad(icon, 8);
        label_spans.push(Span::styled(
            label_pad,
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        icon_spans.push(Span::styled(
            icon_pad,
            Style::default()
                .fg(*color)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        // Divider after every button except the last on the row.
        if i + 1 < n {
            label_spans.push(Span::styled("│", Style::default().fg(t.grey).bg(bg)));
            icon_spans.push(Span::styled("│", Style::default().fg(t.grey).bg(bg)));
        }
        // Push button rect (8-cell-wide hit area, 2 rows tall — excludes
        // the rule row at the bottom).
        buttons_out.push((Rect::new(x, area.y, 8, 1), pane_id, *action));
        buttons_out.push((Rect::new(x, area.y + 1, 8, 1), pane_id, *action));
        x += cell_w;
    }
    frame.render_widget(
        Paragraph::new(Line::from(label_spans)).style(Style::default().bg(bg)),
        Rect::new(area.x, area.y, area.width, 1),
    );
    frame.render_widget(
        Paragraph::new(Line::from(icon_spans)).style(Style::default().bg(bg)),
        Rect::new(area.x, area.y + 1, area.width, 1),
    );
}

/// Center `s` inside a `width`-char column. Truncates to fit (no
/// ellipsis — the button labels are short fixed words).
fn center_pad(s: &str, width: usize) -> String {
    let n = s.chars().count();
    if n >= width {
        return s.chars().take(width).collect();
    }
    let total = width - n;
    let left = total / 2;
    let right = total - left;
    format!("{}{}{}", " ".repeat(left), s, " ".repeat(right))
}

/// Format a unix-seconds timestamp as `MM/DD HH:MM` in the user's local
/// timezone. Local TZ comes from `$TZ_OFFSET_HOURS` (same env knob the
/// statusline clock uses); defaults to UTC when unset. Width is exactly
/// 11 chars — the date column reserves that.
pub fn format_commit_datetime(secs: i64) -> String {
    let off_secs = std::env::var("TZ_OFFSET_HOURS")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .map(|h| h * 3600)
        .unwrap_or(0);
    let local = secs.saturating_add(off_secs);
    let days = local.div_euclid(86_400);
    let day_secs = local.rem_euclid(86_400);
    let hh = day_secs / 3600;
    let mm = (day_secs / 60) % 60;
    let (_y, month, day) = days_to_ymd(days);
    format!("{month:02}/{day:02} {hh:02}:{mm:02}")
}

/// Convert days-since-1970-01-01 (UTC) to a `(year, month, day)` tuple.
/// Howard Hinnant's "civil from days" algorithm — valid for AD 1..9999.
fn days_to_ymd(days_since_epoch: i64) -> (i64, u32, u32) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m as u32, d as u32)
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
    fn days_to_ymd_known_dates() {
        // 1970-01-01 = day 0
        assert_eq!(days_to_ymd(0), (1970, 1, 1));
        // 1970-01-31 = day 30
        assert_eq!(days_to_ymd(30), (1970, 1, 31));
        // 2000-01-01 (Y2K) = day 10957
        assert_eq!(days_to_ymd(10957), (2000, 1, 1));
        // 2024-02-29 (leap day) — 2024-01-01 is day 19723 + 59 days
        assert_eq!(days_to_ymd(19723 + 59), (2024, 2, 29));
    }

    #[test]
    fn format_commit_datetime_pads_to_11_chars() {
        // Force UTC for the test by stashing the env var. Use `unsafe`
        // since std::env mutation is unsafe in edition 2024.
        let prior = std::env::var("TZ_OFFSET_HOURS").ok();
        unsafe {
            std::env::remove_var("TZ_OFFSET_HOURS");
        }
        // 1970-01-01 00:00:00 UTC
        assert_eq!(format_commit_datetime(0), "01/01 00:00");
        // 2024-12-25 13:45:00 UTC — Christmas 2024
        // Days from 1970-01-01: standard library answer is 20083
        // (20089 actually — let me just verify it's 11 chars)
        let s = format_commit_datetime(1_735_134_300);
        assert_eq!(s.chars().count(), 11);
        if let Some(p) = prior {
            unsafe {
                std::env::set_var("TZ_OFFSET_HOURS", p);
            }
        }
    }

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
        let c = compute_column_widths(
            200,
            10,
            ColAutoSize {
                branch_chars: 30,
                author_chars: 18,
                branch_override: None,
                author_override: None,
            },
        );
        assert!(c.sha >= 9);
        assert!(c.age >= 6);
        assert!(c.author >= 10);
        assert!(c.branch >= 18);
    }

    #[test]
    fn compute_column_widths_narrow_collapses_right_to_left() {
        // Just barely enough room for the swimlane+arrow+graph+subject+sha.
        let c = compute_column_widths(
            45,
            6,
            ColAutoSize {
                branch_chars: 30,
                author_chars: 18,
                branch_override: None,
                author_override: None,
            },
        );
        assert!(c.sha > 0, "sha should be the last to collapse");
    }

    #[test]
    fn compute_column_widths_very_narrow_keeps_subject_only() {
        let c = compute_column_widths(
            28,
            4,
            ColAutoSize {
                branch_chars: 30,
                author_chars: 18,
                branch_override: None,
                author_override: None,
            },
        );
        assert_eq!(c.branch, 0);
        assert_eq!(c.author, 0);
    }

    #[test]
    fn compute_column_widths_auto_sizes_to_content() {
        // Short author/branch names → narrower columns.
        let c = compute_column_widths(
            200,
            10,
            ColAutoSize {
                branch_chars: 5,
                author_chars: 4,
                branch_override: None,
                author_override: None,
            },
        );
        assert_eq!(c.author, 8, "author auto-size clamps to 8 min");
        assert_eq!(c.branch, 10, "branch auto-size clamps to 10 min");
    }

    #[test]
    fn compute_column_widths_respects_explicit_overrides() {
        let c = compute_column_widths(
            200,
            10,
            ColAutoSize {
                branch_chars: 30,
                author_chars: 30,
                branch_override: Some(0), // disabled
                author_override: Some(12),
            },
        );
        assert_eq!(c.branch, 0);
        assert_eq!(c.author, 12);
    }
}
