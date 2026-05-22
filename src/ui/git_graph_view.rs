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
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::git::log::{Commit, LANE_COLORS, RefKind};
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme::{self, Theme};

/// Cells of empty space reserved at the right edge of each commit
/// row after the SHA column — so the hash isn't flush against the
/// detail-panel divider / pane edge.
const SHA_RIGHT_PAD: usize = 2;

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
    // Right-side detail panel width. Precedence: runtime drag override
    // (drag the divider) → config override → auto-size to 40%.
    let detail_w_cfg = app
        .git_graph_detail_col_override
        .map(|n| n as usize)
        .or(app.config.ui.git_graph_detail_col);

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
    // Spans the full pane width; single row with `<icon> <label>` per
    // button. Hidden when the pane is too narrow / short.
    let toolbar_h: u16 = if area.width >= 40 && area.height >= 6 {
        1
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
    // Vertical divider between list + detail — clickable +
    // drag-resizable. A 2-row centered grip glyph advertises the
    // handle, mirroring the file-tree edge.
    if detail_w > 0 {
        let divider_x = body_area_full.x + body_area_full.width - detail_w - 1;
        let grip_h: u16 = 2;
        let grip_y = body_area_full.y + body_area_full.height.saturating_sub(grip_h) / 2;
        let grip_glyph = if app.config.ui.ascii_icons {
            "|"
        } else {
            "┃"
        };
        for row in 0..body_area_full.height {
            let abs_y = body_area_full.y + row;
            let is_grip = abs_y >= grip_y && abs_y < grip_y + grip_h;
            let (glyph, color) = if is_grip {
                (grip_glyph, t.comment)
            } else {
                ("│", t.grey)
            };
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    glyph,
                    Style::default().fg(color).bg(t.bg_dark),
                ))),
                Rect::new(divider_x, abs_y, 1, 1),
            );
        }
        app.rects.git_graph_detail_dividers.push((
            Rect::new(divider_x, body_area_full.y, 1, body_area_full.height),
            pane_id,
        ));
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
    // Reserve 2 cells of right padding after the SHA column so the
    // hash isn't flush against the detail-panel divider / pane edge.
    let cols = compute_column_widths(
        (body_area.width as usize).saturating_sub(SHA_RIGHT_PAD),
        graph_w,
        ColAutoSize {
            branch_chars: auto_branch_w,
            author_chars: auto_author_w,
            branch_override: branch_col_override,
            author_override: author_col_override,
        },
    );

    // Column header — build a chip label from every active LogFilter
    // field so users can see the narrowing scope at a glance.
    let mut chips: Vec<String> = Vec::new();
    if let Some(b) = &g.filter.branch {
        chips.push(format!("⎇ {b}"));
    }
    if let Some(a) = &g.filter.author {
        chips.push(format!("@{a}"));
    }
    if let Some(grep) = &g.filter.grep {
        chips.push(format!("~{grep}"));
    }
    match (&g.filter.since, &g.filter.until) {
        (Some(s), Some(u)) => chips.push(format!("{s}..{u}")),
        (Some(s), None) => chips.push(format!("since {s}")),
        (None, Some(u)) => chips.push(format!("until {u}")),
        _ => {}
    }
    let filter_label = if chips.is_empty() {
        None
    } else {
        Some(format!("{} · F clears", chips.join(" · ")))
    };
    let sort = g.sort;
    let mut header_clickables: Vec<(Rect, crate::git::graph::SortColumn)> = Vec::new();
    draw_header(
        frame,
        header_area,
        &t,
        &cols,
        graph_w,
        &g.hash_filter,
        filter_label.as_deref(),
        sort,
        &mut header_clickables,
    );
    app.rects.git_graph_column_headers = header_clickables;

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
            let sep_style = Style::default().fg(t.line).bg(row_bg);
            let body_sep = |spans: &mut Vec<Span>| {
                spans.push(Span::styled(" │ ", sep_style));
            };
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
                body_sep(&mut spans);
            } else {
                spans.push(Span::styled("  ", Style::default().bg(row_bg)));
            }
            // Graph column: blank.
            spans.push(Span::styled(
                " ".repeat(graph_w),
                Style::default().bg(row_bg),
            ));
            body_sep(&mut spans);
            // Subject column: change summary.
            let branch_section = if cols.branch > 0 { cols.branch + 3 } else { 2 };
            let fixed_used = 1
                + 2
                + branch_section
                + graph_w
                + 3
                + (if cols.author > 0 { cols.author + 3 } else { 0 })
                + (if cols.age > 0 { cols.age + 3 } else { 0 })
                + (if cols.sha > 0 { cols.sha + 3 } else { 0 })
                + SHA_RIGHT_PAD;
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
                body_sep(&mut spans);
                spans.push(Span::styled(
                    " ".repeat(cols.author),
                    Style::default().bg(row_bg),
                ));
            }
            if cols.age > 0 {
                body_sep(&mut spans);
                spans.push(Span::styled(
                    " ".repeat(cols.age),
                    Style::default().bg(row_bg),
                ));
            }
            if cols.sha > 0 {
                body_sep(&mut spans);
                spans.push(Span::styled(
                    " ".repeat(cols.sha),
                    Style::default().bg(row_bg),
                ));
            }
            if SHA_RIGHT_PAD > 0 {
                spans.push(Span::styled(
                    " ".repeat(SHA_RIGHT_PAD),
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
        // 3-cell column separator " │ " in a muted line color — same
        // spacing the header uses so columns line up vertically.
        let sep_style = Style::default().fg(t.line).bg(row_bg);
        let body_sep = |spans: &mut Vec<Span>| {
            spans.push(Span::styled(" │ ", sep_style));
        };
        // 3) Branch/tag chip column (fixed width, ellipsis-truncated)
        if cols.branch > 0 {
            render_branch_chips(&mut spans, &c.refs, cols.branch, row_bg, &t);
            body_sep(&mut spans);
        } else {
            spans.push(Span::styled("  ", Style::default().bg(row_bg)));
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
        body_sep(&mut spans);
        // 5) Subject (flex — pad / truncate to fit the remaining width).
        // The SHA right-pad cells eat into available width so they
        // actually render (Paragraph clips past `body_area.width`).
        let branch_section = if cols.branch > 0 { cols.branch + 3 } else { 2 };
        let fixed_used = 1
            + 2
            + branch_section
            + graph_w
            + 3
            + (if cols.author > 0 { cols.author + 3 } else { 0 })
            + (if cols.age > 0 { cols.age + 3 } else { 0 })
            + (if cols.sha > 0 { cols.sha + 3 } else { 0 })
            + SHA_RIGHT_PAD;
        let subject_w = (body_area.width as usize).saturating_sub(fixed_used);
        let subject = pad_or_truncate(&c.subject, subject_w);
        spans.push(Span::styled(subject, Style::default().fg(t.fg).bg(row_bg)));
        // 6) Author (right-aligned in its column)
        if cols.author > 0 {
            body_sep(&mut spans);
            let author = right_align(&c.author, cols.author);
            spans.push(Span::styled(
                author,
                Style::default().fg(t.comment).bg(row_bg),
            ));
        }
        // 7) Date/time (right-aligned, local TZ)
        if cols.age > 0 {
            body_sep(&mut spans);
            let age = right_align(&format_commit_datetime(c.time), cols.age);
            spans.push(Span::styled(age, Style::default().fg(t.comment).bg(row_bg)));
        }
        // 8) Short SHA
        if cols.sha > 0 {
            body_sep(&mut spans);
            let sha = right_align(&c.short, cols.sha);
            spans.push(Span::styled(sha, Style::default().fg(t.orange).bg(row_bg)));
        }
        // Right-edge padding so the SHA doesn't kiss the divider.
        if SHA_RIGHT_PAD > 0 {
            spans.push(Span::styled(
                " ".repeat(SHA_RIGHT_PAD),
                Style::default().bg(row_bg),
            ));
        }
        rows.push(Line::from(spans));
    }
    frame.render_widget(
        Paragraph::new(rows).style(Style::default().bg(t.bg_dark)),
        body_area,
    );
    // Skip registering commit-row click rects when an embedded diff
    // is overlaying the list area — otherwise clicks inside the diff
    // body fall through to the commit-row handler and change the
    // selected commit (re-rendering the right detail panel with the
    // newly-picked commit's files). The user expects the right panel
    // to remain pinned to whatever commit was already selected while
    // the embedded diff is open.
    let suppress_commit_clicks = g.embedded_diff.is_some();
    for (visible_y, v_idx) in row_recordings {
        if suppress_commit_clicks {
            continue;
        }
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
    let mut textarea_cursor: Option<(u16, u16)> = None;
    if let Some(da) = detail_area {
        if g.is_wip_selected() {
            let workspace = g.workspace.clone();
            // Borrow the textarea state out separately so the `g` borrow
            // doesn't extend across the renderer call.
            let commit = g.wip_commit.clone();
            textarea_cursor = draw_wip_detail(
                frame,
                da,
                &t,
                &wip_snapshot,
                &workspace,
                pane_id,
                &commit,
                &mut app.rects.wip_buttons,
                &mut app.rects.wip_file_rows,
                &mut app.rects.wip_commit_textarea,
            );
        } else if let (Some(c), Some(detail)) = (g.selected_commit(), g.detail.as_ref()) {
            draw_detail(
                frame,
                da,
                &t,
                c,
                detail,
                now,
                pane_id,
                &mut app.rects.commit_file_rows,
            );
        }
    }

    // ── Commit-list scrollbar (right edge of the list body) ─────────
    // Only paint when no embedded diff is showing (the embedded diff
    // brings its own scrollbar). Plain grey track + thumb — no change
    // markers on the commit list.
    if g.embedded_diff.is_none() && body_area.width >= 8 && body_area.height > 0 {
        let bar_x = body_area.x + body_area.width - 1;
        let bar_area = Rect::new(bar_x, body_area.y, 1, body_area.height);
        let cells = bar_area.height as usize;
        let total = g.total_rows();
        // Track.
        for cy in 0..cells {
            let cell = Rect::new(bar_area.x, bar_area.y + cy as u16, 1, 1);
            frame.render_widget(Paragraph::new(" ").style(Style::default().bg(t.bg2)), cell);
        }
        // Thumb — same proportional placement as the diff scrollbar.
        if total > cells && cells > 0 {
            let thumb_h = ((cells * cells) / total).max(1);
            let max_scroll = total - cells;
            let max_thumb_top = cells.saturating_sub(thumb_h);
            let thumb_top = (g.scroll * max_thumb_top)
                .checked_div(max_scroll)
                .unwrap_or(0);
            for cy in thumb_top..(thumb_top + thumb_h).min(cells) {
                let cell = Rect::new(bar_area.x, bar_area.y + cy as u16, 1, 1);
                frame.render_widget(
                    Paragraph::new(" ").style(Style::default().bg(t.comment)),
                    cell,
                );
            }
        }
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: bar_area,
            pane_id,
            total,
            viewport: cells,
            kind: crate::app::ScrollbarKind::GitGraphCommits,
        });
    }

    // ── Embedded diff (overpaint list_area) ─────────────────────────
    // When `g.embedded_diff` is Some, the commit-list area is
    // replaced by the embedded diff for the file the user clicked
    // in the right detail panel. The right detail panel above stays
    // intact. Esc closes the embedded diff (handled in tui.rs).
    let has_embedded =
        matches!(app.panes.get(pane_id), Some(Pane::GitGraph(g)) if g.embedded_diff.is_some());
    if has_embedded {
        // Lazy-fetch full-file context for Inline + Split before
        // borrowing (Inline now renders the whole file like Split).
        let needs_full = matches!(
            app.panes.get(pane_id),
            Some(Pane::GitGraph(g)) if g.embedded_diff.as_ref().map(|d| {
                matches!(
                    d.view_mode,
                    crate::pane::DiffViewMode::Split | crate::pane::DiffViewMode::Inline
                ) && d.full_hunks.is_none()
            }).unwrap_or(false)
        );
        if needs_full {
            let scope = match app.panes.get(pane_id) {
                Some(Pane::GitGraph(g)) => g.embedded_diff.as_ref().map(|d| d.scope.clone()),
                _ => None,
            };
            if let Some(scope) = scope {
                let full = app.fetch_diff_full(&scope);
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(pane_id)
                    && let Some(d) = g.embedded_diff.as_mut()
                {
                    d.full_hunks = Some(full);
                }
            }
        }
        // Wipe the commit-list cells first — the list rendered above
        // left chars + author names behind, and a bare
        // `Paragraph::new("")` only re-styles the cells, it doesn't
        // overwrite their contents. Without this, the embedded-diff
        // body lines (shorter than the full pane width) bleed through
        // to commit-list trailing text on the right edge. `Clear`
        // resets every cell in `list_area` to a space with default
        // style; the styled bg fill that follows tints them bg_dark.
        frame.render_widget(Clear, list_area);
        frame.render_widget(
            Paragraph::new("").style(Style::default().bg(t.bg_dark)),
            list_area,
        );
        let diff_tb_h: u16 = if list_area.height >= 4 { 1 } else { 0 };
        if diff_tb_h > 0
            && let Some(Pane::GitGraph(g)) = app.panes.get(pane_id)
            && let Some(d) = g.embedded_diff.as_ref()
        {
            let (view_mode, wrap_on) = (d.view_mode, d.wrap);
            crate::ui::diff_view::draw_diff_toolbar(
                frame,
                Rect::new(list_area.x, list_area.y, list_area.width, diff_tb_h),
                &t,
                pane_id,
                view_mode,
                wrap_on,
                &mut app.rects.diff_toolbar_buttons,
            );
        }
        let diff_body = Rect::new(
            list_area.x,
            list_area.y + diff_tb_h,
            list_area.width,
            list_area.height.saturating_sub(diff_tb_h),
        );
        // Render the embedded diff body via the shared renderers.
        // Scrollbar rects flow through `rects.scrollbars` tagged
        // `EmbeddedDiff` so the drag dispatcher knows to update
        // `g.embedded_diff.scroll`.
        let rects = &mut app.rects;
        if let Some(Pane::GitGraph(g)) = app.panes.get_mut(pane_id)
            && let Some(d) = g.embedded_diff.as_mut()
        {
            d.cursor = d.cursor.min(d.hunks.len().saturating_sub(1));
            let kind = crate::app::ScrollbarKind::EmbeddedDiff;
            match d.view_mode {
                crate::pane::DiffViewMode::Inline => crate::ui::diff_view::render_inline(
                    frame,
                    d,
                    &t,
                    diff_body,
                    &mut rects.list_rows,
                    &mut rects.scrollbars,
                    &mut rects.diff_hunk_buttons,
                    kind,
                    pane_id,
                ),
                crate::pane::DiffViewMode::Hunk => crate::ui::diff_view::render_hunk(
                    frame,
                    d,
                    &t,
                    diff_body,
                    &mut rects.list_rows,
                    &mut rects.scrollbars,
                    &mut rects.diff_hunk_buttons,
                    kind,
                    pane_id,
                ),
                crate::pane::DiffViewMode::Split => crate::ui::diff_view::render_split(
                    frame,
                    d,
                    &t,
                    diff_body,
                    &mut rects.list_rows,
                    &mut rects.scrollbars,
                    &mut rects.diff_hunk_buttons,
                    kind,
                    pane_id,
                ),
            }
        }
    }

    textarea_cursor
}

#[derive(Debug, Clone, Copy)]
struct ColAutoSize {
    branch_chars: usize,
    author_chars: usize,
    branch_override: Option<usize>,
    author_override: Option<usize>,
}

#[allow(clippy::too_many_arguments)]
fn draw_detail(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    c: &Commit,
    detail: &crate::git::graph::CommitDetail,
    now: i64,
    pane_id: PaneId,
    file_rows_out: &mut Vec<(Rect, PaneId, usize)>,
) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    let w = area.width as usize;
    let mut lines: Vec<Line> = Vec::new();
    let mut pending_file_rows: Vec<(usize, usize, usize, usize)> = Vec::new();

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

    // changed files header
    let total = detail.files.len();
    lines.push(Line::from(Span::styled(
        format!("  changed files ({total}):"),
        Style::default()
            .fg(t.comment)
            .bg(t.bg)
            .add_modifier(Modifier::BOLD),
    )));

    let avail = (area.height as usize).saturating_sub(lines.len() + 1);
    let shown = total.min(avail.saturating_sub(1));
    for (idx, (status, path)) in detail.files.iter().take(shown).enumerate() {
        let letter = status.chars().next().unwrap_or('?');
        let color = match letter {
            'A' => t.green,
            'M' => t.yellow,
            'D' => t.red,
            'R' => t.blue,
            'C' => t.cyan,
            _ => t.comment,
        };
        let prefix = format!("  {letter} ");
        let prefix_chars = prefix.chars().count();
        let row_chars = prefix_chars + path.chars().count();
        lines.push(Line::from(vec![
            Span::styled(prefix, Style::default().fg(color).bg(t.bg)),
            Span::styled(path.clone(), Style::default().fg(t.fg).bg(t.bg)),
            Span::styled(
                " ".repeat(w.saturating_sub(row_chars)),
                Style::default().bg(t.bg),
            ),
        ]));
        pending_file_rows.push((lines.len() - 1, 0, w, idx));
    }
    if shown < total {
        lines.push(Line::from(Span::styled(
            format!("  … and {} more", total - shown),
            Style::default().fg(t.comment).bg(t.bg),
        )));
    }

    frame.render_widget(Paragraph::new(lines).style(Style::default().bg(t.bg)), area);

    for (line_idx, x_start, x_end, file_idx) in pending_file_rows {
        if (line_idx as u16) >= area.height {
            continue;
        }
        let y = area.y + line_idx as u16;
        let x = area.x + x_start as u16;
        let width = x_end.saturating_sub(x_start) as u16;
        let max_w = (area.x + area.width).saturating_sub(x);
        let clamped_w = width.min(max_w);
        if clamped_w == 0 {
            continue;
        }
        file_rows_out.push((
            Rect {
                x,
                y,
                width: clamped_w,
                height: 1,
            },
            pane_id,
            file_idx,
        ));
    }
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
    // Each column gap is `" │ "` = 3 cells (the visible separator).
    // Reserved: swimlane(1) + arrow(2) + graph + sep(3) + min subject(20).
    let min_fixed = 1 + 2 + graph_w + 3 + 20;
    let mut remaining = total.saturating_sub(min_fixed);

    let mut w = ColWidths {
        branch: 0,
        author: 0,
        age: 0,
        sha: 0,
    };
    if remaining >= 9 + 3 {
        w.sha = 9;
        remaining -= 9 + 3;
    }
    if remaining >= 11 + 3 {
        w.age = 11;
        remaining -= 11 + 3;
    } else if remaining >= 6 + 3 {
        w.age = 6;
        remaining -= 6 + 3;
    }
    let author_target = match auto.author_override {
        Some(n) => n,
        None => auto.author_chars.clamp(8, 22),
    };
    if author_target > 0 && remaining >= author_target + 3 {
        w.author = author_target;
        remaining -= author_target + 3;
    }
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
    // Branch column also costs a trailing separator (3 cells), since
    // header + body always render `" │ "` after the branch chips.
    if branch_target > 0 && remaining >= branch_target + 3 {
        w.branch = branch_target.min(remaining.saturating_sub(3));
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
#[allow(clippy::too_many_arguments)]
fn draw_wip_detail(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    snap: &crate::git::status::Snapshot,
    workspace: &std::path::Path,
    pane_id: PaneId,
    commit: &crate::git::graph::WipCommitInput,
    buttons_out: &mut Vec<(Rect, PaneId, crate::WipAction)>,
    file_rows_out: &mut Vec<(Rect, PaneId, std::path::PathBuf, bool)>,
    textarea_out: &mut Option<(Rect, PaneId)>,
) -> Option<(u16, u16)> {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    // Reserve a fixed-height bottom region for the commit section
    // (header + textarea + buttons + footer hint). When the pane is
    // too short for the full layout, the textarea shrinks first and
    // then drops entirely.
    let commit_h: u16 = {
        // Target 10 rows; shrink when the pane is small. Below 8 rows
        // total we fall back to a buttons-only strip (no textarea).
        let h = area.height;
        if h >= 14 {
            10
        } else if h >= 10 {
            8
        } else if h >= 6 {
            4
        } else {
            0
        }
    };
    let files_area = Rect::new(
        area.x,
        area.y,
        area.width,
        area.height.saturating_sub(commit_h),
    );
    let commit_area = if commit_h > 0 {
        Rect::new(
            area.x,
            area.y + area.height.saturating_sub(commit_h),
            area.width,
            commit_h,
        )
    } else {
        Rect::new(area.x, area.y + area.height, area.width, 0)
    };

    let w = files_area.width as usize;
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
    // Per-file row click rects: (line_idx, x_start, x_end, abs_path, staged).
    // Resolved to absolute screen coords after the lines vector is laid
    // out (so a row that scrolls off the visible files area drops its rect).
    let mut pending_file_rows: Vec<(usize, u16, u16, std::path::PathBuf, bool)> = Vec::new();

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
        // Clickable row covering the prefix + filename — opens the
        // file's diff. The `[+]` button at the right edge keeps its
        // higher-priority click (registered above via pending_buttons).
        pending_file_rows.push((
            lines.len(),
            0,
            (prefix_chars + path_avail) as u16,
            abs_path.clone(),
            false,
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
        pending_file_rows.push((
            lines.len(),
            0,
            (prefix_chars + path_avail) as u16,
            abs_path.clone(),
            true,
        ));
        lines.push(Line::from(row_spans));
    }
    lines.push(Line::from(Span::styled("", Style::default().bg(t.bg))));

    // Drop the previously-inline commit section — it now lives in
    // its own sticky bottom region (rendered by `draw_commit_section`
    // below). Truncate the file-list lines to the files-area height
    // so the Paragraph doesn't bleed into the commit area.
    let files_max = files_area.height as usize;
    if lines.len() > files_max && files_max > 0 {
        // Replace the last visible line with an "… N more" hint so
        // the user knows the list overflowed.
        let dropped = lines.len() - files_max + 1;
        lines.truncate(files_max - 1);
        lines.push(Line::from(Span::styled(
            format!("  … and {dropped} more"),
            Style::default().fg(t.comment).bg(t.bg),
        )));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg)),
        files_area,
    );

    // Push file-list button rects with absolute screen coords. Rows
    // that scroll off the visible files area are dropped silently
    // (they were truncated above; their button rects shouldn't be
    // clickable).
    for (line_idx, x_start, x_end, action) in pending_buttons {
        if (line_idx as u16) >= files_area.height {
            continue;
        }
        let y = files_area.y + line_idx as u16;
        let x = files_area.x + x_start;
        let width = x_end.saturating_sub(x_start);
        if x + width > files_area.x + files_area.width {
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
    // Per-file row click rects (covers the prefix + filename, NOT the
    // `[+]` / `[−]` buttons which keep their stage/unstage action).
    for (line_idx, x_start, x_end, abs_path, staged) in pending_file_rows {
        if (line_idx as u16) >= files_area.height {
            continue;
        }
        let y = files_area.y + line_idx as u16;
        let x = files_area.x + x_start;
        let width = x_end.saturating_sub(x_start);
        if x + width > files_area.x + files_area.width {
            continue;
        }
        file_rows_out.push((
            Rect {
                x,
                y,
                width,
                height: 1,
            },
            pane_id,
            abs_path,
            staged,
        ));
    }

    // ── Sticky commit section at the bottom ─────────────────────────
    if commit_h == 0 {
        return None;
    }
    draw_commit_section(
        frame,
        commit_area,
        t,
        snap,
        pane_id,
        commit,
        buttons_out,
        textarea_out,
    )
}

/// Draw the sticky commit section pinned to the bottom of the WIP
/// detail panel: header row · textarea box · `[Commit] [AI Message]
/// [Clear]` buttons · hint footer. Returns the cursor's absolute
/// `(x, y)` on screen when the textarea is focused so the caller can
/// place the terminal cursor.
#[allow(clippy::too_many_arguments)]
fn draw_commit_section(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    snap: &crate::git::status::Snapshot,
    pane_id: PaneId,
    commit: &crate::git::graph::WipCommitInput,
    buttons_out: &mut Vec<(Rect, PaneId, crate::WipAction)>,
    textarea_out: &mut Option<(Rect, PaneId)>,
) -> Option<(u16, u16)> {
    // Background fill for the whole commit area so the textarea bg
    // doesn't bleed into the files area.
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);

    // Layout split:
    //   row 0:           header `▾ Commit · N file(s) staged`
    //   rows 1..=N-3:    textarea (N-3 rows; min 1)
    //   row N-2:         buttons
    //   row N-1:         hint footer (only when height >= 5)
    let staged_count = snap.staged;
    let h = area.height;
    let header_row = area.y;
    let textarea_rows: u16 = h.saturating_sub(if h >= 5 { 3 } else { 2 }).max(1);
    let textarea_y0 = header_row + 1;
    let buttons_y = textarea_y0 + textarea_rows;
    let hint_y = buttons_y + 1;

    // ── Header row ──
    let header_text = if staged_count == 0 {
        "  ▾ Commit  · (nothing staged)".to_string()
    } else {
        format!("  ▾ Commit  · {staged_count} file(s) staged")
    };
    let header_truncated = pad_or_truncate(&header_text, area.width as usize);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            header_truncated,
            Style::default()
                .fg(t.fg)
                .bg(t.bg)
                .add_modifier(Modifier::BOLD),
        )))
        .style(Style::default().bg(t.bg)),
        Rect::new(area.x, header_row, area.width, 1),
    );

    // ── Textarea ──
    // Box content inset: 2 cells left/right indent so the textarea
    // visually nests under the header. Border drawn at the indent
    // edges via theme grey.
    let pad_x: u16 = 2;
    let content_w = area.width.saturating_sub(pad_x * 2);
    if content_w >= 4 && textarea_rows >= 1 {
        let ta_rect = Rect::new(area.x + pad_x, textarea_y0, content_w, textarea_rows);
        let cursor = draw_textarea(frame, ta_rect, t, commit);
        *textarea_out = Some((ta_rect, pane_id));
        // Buttons row
        draw_commit_buttons(
            frame,
            Rect::new(area.x, buttons_y, area.width, 1),
            t,
            pane_id,
            staged_count,
            commit,
            buttons_out,
        );
        // Hint footer (when room)
        if h >= 5 {
            let hint = if commit.focused {
                "  Enter newline · Esc unfocus · Ctrl+Enter commit"
            } else {
                "  Click textarea to type · c commit · C AI message"
            };
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    pad_or_truncate(hint, area.width as usize),
                    Style::default().fg(t.comment).bg(t.bg),
                )))
                .style(Style::default().bg(t.bg)),
                Rect::new(area.x, hint_y, area.width, 1),
            );
        }
        return cursor;
    }
    // Pane too narrow for the textarea — fall back to buttons-only.
    draw_commit_buttons(
        frame,
        Rect::new(area.x, area.y + 1, area.width, 1),
        t,
        pane_id,
        staged_count,
        commit,
        buttons_out,
    );
    None
}

/// Draw the multi-line textarea content + caret. Returns the
/// absolute screen `(x, y)` for the caret when `commit.focused` is
/// true; otherwise `None`. Char-wraps overlong lines at the box
/// width (no word boundaries — commit subjects rarely span lines).
fn draw_textarea(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    commit: &crate::git::graph::WipCommitInput,
) -> Option<(u16, u16)> {
    let bg = if commit.focused { t.bg_dark } else { t.bg2 };
    // Fill background so empty rows still show the box.
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);

    let content_w = area.width as usize;
    if content_w == 0 || area.height == 0 {
        return None;
    }
    // Compute visual rows by char-wrapping each logical line. Each
    // entry is (start_byte, end_byte) into commit.text.
    let rows = layout_textarea_rows(&commit.text, content_w);
    // Find cursor row + column.
    let (cur_row, cur_col) = locate_cursor(&rows, &commit.text, commit.cursor);

    // Scroll: keep cursor on screen (caller-side state is stored on
    // commit.scroll but we recompute here from the cursor — the
    // commit struct is `&` so this is purely render-side).
    let visible_h = area.height as usize;
    let scroll = if cur_row >= visible_h {
        cur_row + 1 - visible_h
    } else {
        0
    };

    // Render visible rows.
    let mut out: Vec<Line> = Vec::new();
    for vrow in 0..visible_h {
        let actual = scroll + vrow;
        let line: String = if let Some(&(s, e)) = rows.get(actual) {
            commit.text[s..e].to_string()
        } else {
            String::new()
        };
        // Pad to width so the bg fills.
        let padded = pad_or_truncate(&line, content_w);
        out.push(Line::from(Span::styled(
            padded,
            Style::default().fg(t.fg).bg(bg),
        )));
    }

    // Placeholder when empty + unfocused — render dim italic over the
    // first row.
    if commit.text.is_empty() && !commit.focused {
        let placeholder = if commit.ai_streaming {
            " (asking Claude for a commit message…) "
        } else {
            " click here · then type a commit message "
        };
        let row0 = pad_or_truncate(placeholder, content_w);
        out[0] = Line::from(Span::styled(
            row0,
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::ITALIC),
        ));
    }

    frame.render_widget(Paragraph::new(out).style(Style::default().bg(bg)), area);

    if commit.focused {
        let visual_row = cur_row.saturating_sub(scroll);
        if visual_row < visible_h && cur_col <= content_w {
            let x = area.x + cur_col as u16;
            let y = area.y + visual_row as u16;
            return Some((x, y));
        }
    }
    None
}

/// Char-wrap `text` at `width` cells per row, respecting `\n`
/// boundaries. Each output entry is `(start_byte, end_byte)` —
/// half-open, exclusive of the trailing newline when one bounded the
/// row. Always returns at least one row (empty text ⇒ `[(0, 0)]`).
fn layout_textarea_rows(text: &str, width: usize) -> Vec<(usize, usize)> {
    if width == 0 {
        return vec![(0, text.len())];
    }
    let mut rows: Vec<(usize, usize)> = Vec::new();
    let mut row_start = 0usize;
    let mut cols = 0usize;
    for (idx, ch) in text.char_indices() {
        if ch == '\n' {
            rows.push((row_start, idx));
            row_start = idx + 1;
            cols = 0;
            continue;
        }
        if cols >= width {
            rows.push((row_start, idx));
            row_start = idx;
            cols = 0;
        }
        cols += 1;
    }
    rows.push((row_start, text.len()));
    rows
}

/// Locate the cursor at byte offset `cursor` within the wrapped
/// `rows` view of `text`. Returns `(row, col)` in cells.
fn locate_cursor(rows: &[(usize, usize)], text: &str, cursor: usize) -> (usize, usize) {
    // Find the last row whose start <= cursor.
    let mut idx = 0;
    for (i, &(s, e)) in rows.iter().enumerate() {
        if cursor >= s && cursor <= e {
            idx = i;
            break;
        }
        idx = i;
    }
    let (s, _e) = rows.get(idx).copied().unwrap_or((0, 0));
    let col = text[s..cursor.min(text.len())].chars().count();
    (idx, col)
}

fn draw_commit_buttons(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    pane_id: PaneId,
    staged_count: usize,
    commit: &crate::git::graph::WipCommitInput,
    buttons_out: &mut Vec<(Rect, PaneId, crate::WipAction)>,
) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    // Button labels.
    let commit_btn = " Commit ";
    let ai_btn = " AI Message ";
    let clear_btn = " Clear ";
    let gap = "  ";
    let leading = "  ";

    let commit_active = staged_count > 0 && !commit.is_blank() && !commit.ai_streaming;
    let ai_active = staged_count > 0 && !commit.ai_streaming;
    let clear_active = !commit.text.is_empty() && !commit.ai_streaming;

    let style_active = |fg, bg, on: bool| {
        if on {
            Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg2)
        }
    };
    let commit_style = style_active(t.bg_dark, t.green, commit_active);
    let ai_style = if commit.ai_streaming {
        Style::default()
            .fg(t.bg_dark)
            .bg(t.yellow)
            .add_modifier(Modifier::BOLD)
    } else {
        style_active(t.bg_dark, t.blue, ai_active)
    };
    let clear_style = style_active(t.bg_dark, t.red, clear_active);

    // Layout the row's spans + collect button rects in screen coords.
    let mut spans: Vec<Span> = Vec::new();
    spans.push(Span::styled(leading.to_string(), Style::default().bg(t.bg)));
    let mut x = area.x + leading.chars().count() as u16;

    let commit_w = commit_btn.chars().count() as u16;
    spans.push(Span::styled(commit_btn.to_string(), commit_style));
    buttons_out.push((
        Rect {
            x,
            y: area.y,
            width: commit_w,
            height: 1,
        },
        pane_id,
        crate::WipAction::OpenCommitPrompt,
    ));
    x += commit_w;

    spans.push(Span::styled(gap.to_string(), Style::default().bg(t.bg)));
    x += gap.chars().count() as u16;

    let ai_w = ai_btn.chars().count() as u16;
    let ai_label = if commit.ai_streaming {
        " AI writing… "
    } else {
        ai_btn
    };
    spans.push(Span::styled(ai_label.to_string(), ai_style));
    buttons_out.push((
        Rect {
            x,
            y: area.y,
            width: ai_label.chars().count() as u16,
            height: 1,
        },
        pane_id,
        crate::WipAction::RequestAiCommitMessage,
    ));
    x += ai_w;

    spans.push(Span::styled(gap.to_string(), Style::default().bg(t.bg)));
    x += gap.chars().count() as u16;

    let clear_w = clear_btn.chars().count() as u16;
    spans.push(Span::styled(clear_btn.to_string(), clear_style));
    buttons_out.push((
        Rect {
            x,
            y: area.y,
            width: clear_w,
            height: 1,
        },
        pane_id,
        crate::WipAction::ClearCommitDraft,
    ));

    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(t.bg)),
        area,
    );
}

/// Draw the column-header row (faint labels) and, when a hash filter is
/// active, a chip showing the typed prefix.
#[allow(clippy::too_many_arguments)]
fn draw_header(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    cols: &ColWidths,
    graph_w: usize,
    hash_filter: &str,
    // Combined filter chip label (`⎇ feat · @alice · since 1 week ago …`)
    // — `None` means no active filter, so the column shows "COMMIT MESSAGE".
    filter_label: Option<&str>,
    sort: Option<(crate::git::graph::SortColumn, bool)>,
    column_clickables: &mut Vec<(Rect, crate::git::graph::SortColumn)>,
) {
    use crate::git::graph::SortColumn;
    let sort_glyph = |c: SortColumn| -> &'static str {
        match sort {
            Some((sc, true)) if sc == c => " ▲",
            Some((sc, false)) if sc == c => " ▼",
            _ => "  ",
        }
    };
    let header_style = |c: SortColumn| -> Style {
        let mut st = Style::default().fg(t.comment).bg(t.bg_darker);
        if matches!(sort, Some((sc, _)) if sc == c) {
            st = st.fg(t.yellow).add_modifier(Modifier::BOLD);
        } else {
            st = st.add_modifier(Modifier::BOLD);
        }
        st
    };
    // Cumulative cell-x within the header lane — used to register the
    // per-column clickable rects.
    let mut cell_x: u16 = 0;
    if area.width == 0 || area.height == 0 {
        return;
    }
    let bg = t.bg_darker;
    let mut spans: Vec<Span> = Vec::new();
    // Lane bar + arrow gutter
    spans.push(Span::styled("   ", Style::default().bg(bg)));
    cell_x += 3;
    // Visible `│` column separators replace the previous bare 2-space
    // gaps between columns. Drag to resize is a follow-up — for now
    // they're purely visual cues advertising column boundaries
    // (mirrors a popular Git GUI).
    let sep_style = Style::default().fg(t.grey).bg(bg);
    let sep_span = || Span::styled(" │ ", sep_style);
    // Branch column header
    if cols.branch > 0 {
        spans.push(Span::styled(
            pad_or_truncate("BRANCH / TAG", cols.branch),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        cell_x += cols.branch as u16;
        spans.push(sep_span());
        cell_x += 3;
    } else {
        spans.push(Span::styled("  ", Style::default().bg(bg)));
        cell_x += 2;
    }
    // Graph column header
    spans.push(Span::styled(
        pad_or_truncate("GRAPH", graph_w),
        Style::default()
            .fg(t.comment)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    cell_x += graph_w as u16;
    spans.push(sep_span());
    cell_x += 3;
    // Subject header (flex). Reserve SHA right-pad too — otherwise
    // the trailing space spans land past `area.width` and clip.
    let branch_section = if cols.branch > 0 { cols.branch + 3 } else { 2 };
    let fixed_used = 1
        + 2
        + branch_section
        + graph_w
        + 3
        + (if cols.author > 0 { cols.author + 3 } else { 0 })
        + (if cols.age > 0 { cols.age + 3 } else { 0 })
        + (if cols.sha > 0 { cols.sha + 3 } else { 0 })
        + SHA_RIGHT_PAD;
    let subject_w = (area.width as usize).saturating_sub(fixed_used);
    let (subject_label, label_style) = if !hash_filter.is_empty() {
        // Hash-typing filter wins (active keyboard interaction).
        (
            pad_or_truncate(&format!("/{hash_filter}_"), subject_w),
            Style::default()
                .fg(t.yellow)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        )
    } else if let Some(chip) = filter_label {
        // Active filter (branch / author / grep / since-until) — chip
        // the combined label in yellow so the narrowed scope is obvious.
        (
            pad_or_truncate(chip, subject_w),
            Style::default()
                .fg(t.bg_darker)
                .bg(t.yellow)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        (
            pad_or_truncate("COMMIT MESSAGE", subject_w),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        )
    };
    spans.push(Span::styled(subject_label, label_style));
    cell_x += subject_w as u16;
    if cols.author > 0 {
        spans.push(sep_span());
        cell_x += 3;
        let label = format!("AUTHOR{}", sort_glyph(SortColumn::Author));
        spans.push(Span::styled(
            right_align(&label, cols.author),
            header_style(SortColumn::Author),
        ));
        column_clickables.push((
            Rect {
                x: area.x + cell_x,
                y: area.y,
                width: cols.author as u16,
                height: 1,
            },
            SortColumn::Author,
        ));
        cell_x += cols.author as u16;
    }
    if cols.age > 0 {
        spans.push(sep_span());
        cell_x += 3;
        let label = format!("DATE / TIME{}", sort_glyph(SortColumn::Date));
        spans.push(Span::styled(
            right_align(&label, cols.age),
            header_style(SortColumn::Date),
        ));
        column_clickables.push((
            Rect {
                x: area.x + cell_x,
                y: area.y,
                width: cols.age as u16,
                height: 1,
            },
            SortColumn::Date,
        ));
        cell_x += cols.age as u16;
    }
    if cols.sha > 0 {
        spans.push(sep_span());
        cell_x += 3;
        let label = format!("SHA{}", sort_glyph(SortColumn::Sha));
        spans.push(Span::styled(
            right_align(&label, cols.sha),
            header_style(SortColumn::Sha),
        ));
        column_clickables.push((
            Rect {
                x: area.x + cell_x,
                y: area.y,
                width: cols.sha as u16,
                height: 1,
            },
            SortColumn::Sha,
        ));
        cell_x += cols.sha as u16;
    }
    let _ = cell_x;
    if SHA_RIGHT_PAD > 0 {
        spans.push(Span::styled(
            " ".repeat(SHA_RIGHT_PAD),
            Style::default().bg(bg),
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

/// Draw the GitGraph top toolbar — a single-row strip of clickable
/// git action buttons (Pull / Push / Fetch / Branch / Commit / Stash
/// / Pop / Terminal / Reflog). Each button renders as ` <icon>
/// <label> ` with the icon in the action's accent color and the
/// label in the foreground. Dividers separate adjacent buttons.
///
/// Pushes button rects onto `buttons_out` so `tui::dispatch_mouse`
/// can route clicks via [`crate::App::run_git_toolbar_action`].
pub fn draw_git_toolbar(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    pane_id: PaneId,
    nerd: bool,
    buttons_out: &mut Vec<(Rect, PaneId, crate::GitToolbarAction)>,
) {
    if area.width < 20 || area.height < 1 {
        return;
    }
    let bg = t.bg_darker;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);

    // Button definitions: (label, nerd icon, ascii icon, action, color).
    // Order: Undo/Redo first (a popular Git GUI puts them at the left edge of
    // the toolbar), then Pull/Push, Fetch, Branch/Commit/Stash/Pop,
    // Reflog, Terminal.
    let buttons: [(
        &str,
        &str,
        &str,
        crate::GitToolbarAction,
        ratatui::style::Color,
    ); 11] = [
        (
            "Undo",
            "\u{F054C}",
            "↶",
            crate::GitToolbarAction::Undo,
            t.comment,
        ),
        (
            "Redo",
            "\u{F044E}",
            "↷",
            crate::GitToolbarAction::Redo,
            t.comment,
        ),
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
            ">",
            crate::GitToolbarAction::Terminal,
            t.comment,
        ),
    ];

    // Each button: ` <icon> <label_padded_to_6> ` = 1 + 1 + 1 + 6 + 1 = 10 chars content.
    // Divider " │ " between buttons. Drop buttons from the right when the pane
    // is too narrow to fit them all.
    let btn_w: u16 = 10;
    let div_w: u16 = 3;
    // Solve for n: n*btn_w + (n-1)*div_w <= area.width
    // → n <= (area.width + div_w) / (btn_w + div_w)
    let max_buttons = ((area.width + div_w) / (btn_w + div_w)) as usize;
    let n = buttons.len().min(max_buttons.max(1));
    let mut spans: Vec<Span> = Vec::new();
    let mut x = area.x;
    for (i, (label, nerd_icon, ascii_icon, action, color)) in buttons.iter().take(n).enumerate() {
        let icon = if nerd { *nerd_icon } else { *ascii_icon };
        // ` <icon> ` — icon column in the accent color.
        spans.push(Span::styled(
            format!(" {icon} "),
            Style::default()
                .fg(*color)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        // `<label> ` left-padded to 7 chars (6 label + 1 trailing space) —
        // bold foreground.
        spans.push(Span::styled(
            format!("{label:<6} "),
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        // Button hit area covers the full 10-char content (icon + label).
        buttons_out.push((Rect::new(x, area.y, btn_w, 1), pane_id, *action));
        x += btn_w;
        // Divider " │ " between buttons (omit after the last).
        if i + 1 < n {
            spans.push(Span::styled(" │ ", Style::default().fg(t.grey).bg(bg)));
            x += div_w;
        }
    }
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(bg)),
        Rect::new(area.x, area.y, area.width, 1),
    );
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

    #[test]
    fn format_wip_summary_clean_and_dirty_trees() {
        use crate::git::status::Snapshot;
        let clean = Snapshot::default();
        assert_eq!(format_wip_summary(&clean), "working tree clean");

        // total = 3 + 1 + 2 + 0 conflicts = 6
        let dirty = Snapshot {
            modified: 3,
            staged: 1,
            untracked: 2,
            ..Snapshot::default()
        };
        assert_eq!(format_wip_summary(&dirty), "6 change(s) · 1 staged · 2 new");

        // Ahead/behind appends an `↑N ↓N` segment even on a clean tree.
        let ahead = Snapshot {
            ahead: 2,
            behind: 1,
            ..Snapshot::default()
        };
        assert_eq!(format_wip_summary(&ahead), "working tree clean · ↑2 ↓1");

        // Conflicts carry the ⚠ marker.
        let conflict = Snapshot {
            conflicts: 1,
            ..Snapshot::default()
        };
        assert_eq!(
            format_wip_summary(&conflict),
            "1 change(s) · ⚠ 1 conflict(s)"
        );
    }

    #[test]
    fn layout_textarea_rows_wraps_and_splits_on_newline() {
        // Zero width ⇒ the whole text is one row.
        assert_eq!(layout_textarea_rows("hello", 0), vec![(0, 5)]);
        // An explicit newline ends a row; the `\n` itself isn't in either.
        assert_eq!(layout_textarea_rows("ab\ncd", 10), vec![(0, 2), (3, 5)]);
        // A line longer than `width` hard-wraps at the column boundary.
        assert_eq!(layout_textarea_rows("abcdef", 3), vec![(0, 3), (3, 6)]);
        // An empty string still yields one (empty) row.
        assert_eq!(layout_textarea_rows("", 5), vec![(0, 0)]);
    }

    #[test]
    fn locate_cursor_maps_byte_offset_to_row_col() {
        let text = "abcdef";
        let rows = layout_textarea_rows(text, 3); // [(0,3),(3,6)]
        // Start of the buffer.
        assert_eq!(locate_cursor(&rows, text, 0), (0, 0));
        // Offset 4 sits on the second row, one char in.
        assert_eq!(locate_cursor(&rows, text, 4), (1, 1));
        // End-of-buffer offset lands at the end of the last row.
        assert_eq!(locate_cursor(&rows, text, 6), (1, 3));
    }

    #[test]
    fn chip_width_for_refs_sums_names_seps_and_tag_glyph() {
        use crate::git::log::{RefKind, RefLabel};
        // No refs ⇒ zero width.
        assert_eq!(chip_width_for_refs(&[]), 0);
        // "main"(4) + sep(1) + ⊙ + "v1.0"(4) = 4 + 1 + 5 = 10.
        let refs = vec![
            RefLabel {
                kind: RefKind::LocalBranch,
                name: "main".into(),
            },
            RefLabel {
                kind: RefKind::Tag,
                name: "v1.0".into(),
            },
        ];
        assert_eq!(chip_width_for_refs(&refs), 10);
    }

    #[test]
    fn lane_color_cycles_through_the_palette() {
        let t = theme::onedark();
        // The palette repeats every LANE_COLORS lanes.
        assert_eq!(lane_color(&t, 0), lane_color(&t, LANE_COLORS as u8));
        // Lane 0 and lane 1 are distinct hues.
        assert_ne!(lane_color(&t, 0), lane_color(&t, 1));
        // The 6th slot is the orange fallback.
        assert_eq!(lane_color(&t, 5), t.orange);
    }
}
