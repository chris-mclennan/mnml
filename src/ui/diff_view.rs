//! The `git diff` pane (`Pane::Diff`). Renders parsed hunks in one of
//! three layout modes (chosen by clickable toolbar buttons at the top
//! of the pane):
//! * `Hunk` — focused, expanded-by-default hunks with their
//!   `@@ -X,Y +Z,W @@` banner and a `<old> <new>` line-number gutter
//!   (a popular Git GUI's "Hunk" view).
//! * `Inline` — entire file as one continuous column, line-number
//!   gutter, green for additions, red for removals (a popular Git GUI's
//!   "Inline").
//! * `Split` — whole file with old on the left, new on the right;
//!   a 1-cell change-density minimap on the far right shows where
//!   additions / removals fall through the file (a popular Git GUI's "Split").
//!
//! Plus a `[Wrap]` toggle that wraps long lines to the pane width
//! (default off — long lines clip). Up/Down jump between hunks (or
//! scroll in Split). `n`/`p` keep working for muscle memory.
//!
//! Read-only; `s`/`u` stage/unstage the cursor hunk (handled in
//! `tui.rs`). The toolbar button clicks live in `app.rects.diff_toolbar_buttons`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::git::diff::HunkLine;
use crate::layout::PaneId;
use crate::pane::{DiffViewMode, Pane};
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

    // Two stacked toolbars at the top of the pane:
    //   row 0: Git toolbar (Pull / Push / Fetch / Branch / Commit /
    //          Stash / Pop / Reflog / Term) — same widget the
    //          GitGraph pane shows, so git ops stay reachable when
    //          the user lands on a Diff from a file click.
    //   row 1: Diff toolbar (Hunk / Inline / Split / Wrap).
    let nerd_icons = !app.config.ui.ascii_icons;
    let git_toolbar_h: u16 = if area.height >= 8 && area.width >= 40 {
        1
    } else {
        0
    };
    let diff_toolbar_h: u16 = if area.height >= 5 { 1 } else { 0 };
    let mut top = area.y;
    if git_toolbar_h > 0 {
        crate::ui::git_graph_view::draw_git_toolbar(
            frame,
            Rect::new(area.x, top, area.width, git_toolbar_h),
            &t,
            pane_id,
            nerd_icons,
            &mut app.rects.git_toolbar_buttons,
        );
        top += git_toolbar_h;
    }
    if diff_toolbar_h > 0 {
        let (view_mode, wrap_on) = match app.panes.get(pane_id) {
            Some(Pane::Diff(d)) => (d.view_mode, d.wrap),
            _ => return None,
        };
        draw_diff_toolbar(
            frame,
            Rect::new(area.x, top, area.width, diff_toolbar_h),
            &t,
            pane_id,
            view_mode,
            wrap_on,
            &mut app.rects.diff_toolbar_buttons,
        );
        top += diff_toolbar_h;
    }
    let body_area = Rect::new(
        area.x,
        top,
        area.width,
        area.height.saturating_sub(top - area.y),
    );

    // For Inline + Split, lazy-fetch full-file-context hunks BEFORE
    // borrowing `d` mutably (the renderer no longer reaches into App).
    // Inline now renders the entire file as one continuous view (matches
    // a popular Git GUI's Inline column) so it needs the same full-context
    // payload Split uses. Hunk view stays at `d.hunks` (focused regions).
    let needs_full = matches!(
        app.panes.get(pane_id),
        Some(Pane::Diff(d)) if matches!(d.view_mode, DiffViewMode::Split | DiffViewMode::Inline)
            && d.full_hunks.is_none()
    );
    if needs_full {
        let scope = match app.panes.get(pane_id) {
            Some(Pane::Diff(d)) => d.scope.clone(),
            _ => return None,
        };
        let full = app.fetch_diff_full(&scope);
        if let Some(Pane::Diff(d)) = app.panes.get_mut(pane_id) {
            d.full_hunks = Some(full);
        }
    }

    // Split-borrow: get `d` AND the rect registries simultaneously.
    let rects = &mut app.rects;
    let Some(Pane::Diff(d)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    if d.hunks.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  (no changes)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ))),
            body_area,
        );
        rects.editor_panes.push((area, pane_id));
        return None;
    }
    d.cursor = d.cursor.min(d.hunks.len() - 1);

    let kind = crate::app::ScrollbarKind::Diff;
    match d.view_mode {
        DiffViewMode::Inline => render_inline(
            frame,
            d,
            &t,
            body_area,
            &mut rects.list_rows,
            &mut rects.scrollbars,
            &mut rects.diff_hunk_buttons,
            kind,
            pane_id,
        ),
        DiffViewMode::Hunk => render_hunk(
            frame,
            d,
            &t,
            body_area,
            &mut rects.list_rows,
            &mut rects.scrollbars,
            &mut rects.diff_hunk_buttons,
            kind,
            pane_id,
        ),
        DiffViewMode::Split => render_split(
            frame,
            d,
            &t,
            body_area,
            &mut rects.list_rows,
            &mut rects.scrollbars,
            &mut rects.diff_hunk_buttons,
            kind,
            pane_id,
        ),
    }
    rects.editor_panes.push((area, pane_id));
    None
}

/// `[Inline] [Hunk] [Split]  ·  [Wrap]` — single-row clickable
/// toolbar at the top of the diff pane. Public so the GitGraph
/// embedded-diff path can render the same toolbar above its
/// embedded diff.
pub fn draw_diff_toolbar(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    pane_id: PaneId,
    view_mode: DiffViewMode,
    wrap_on: bool,
    buttons_out: &mut Vec<(Rect, PaneId, crate::DiffToolbarAction)>,
) {
    let bg = t.bg_darker;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);

    // Each button gets a fixed 9-cell width and renders ` <label> ` —
    // active mode shown with a green bg.
    let buttons: [(&str, crate::DiffToolbarAction, bool); 4] = [
        (
            " Hunk ",
            crate::DiffToolbarAction::ViewHunk,
            view_mode == DiffViewMode::Hunk,
        ),
        (
            " Inline ",
            crate::DiffToolbarAction::ViewInline,
            view_mode == DiffViewMode::Inline,
        ),
        (
            " Split ",
            crate::DiffToolbarAction::ViewSplit,
            view_mode == DiffViewMode::Split,
        ),
        (" Wrap ", crate::DiffToolbarAction::ToggleWrap, wrap_on),
    ];
    let mut spans: Vec<Span> = Vec::new();
    spans.push(Span::styled(" ", Style::default().bg(bg)));
    let mut x = area.x + 1;
    for (i, (label, action, on)) in buttons.iter().enumerate() {
        // Insert a thin divider between the view-mode group and the Wrap toggle.
        if i == 3 {
            spans.push(Span::styled(" │ ", Style::default().fg(t.grey).bg(bg)));
            x += 3;
        }
        let style = if *on {
            Style::default()
                .fg(t.bg_dark)
                .bg(t.green)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD)
        };
        let w = label.chars().count() as u16;
        spans.push(Span::styled(label.to_string(), style));
        buttons_out.push((
            Rect {
                x,
                y: area.y,
                width: w,
                height: 1,
            },
            pane_id,
            *action,
        ));
        x += w;
        // 1-cell gap between adjacent buttons (within the view group).
        if i < 2 {
            spans.push(Span::styled(" ", Style::default().bg(bg)));
            x += 1;
        }
    }
    // Right-edge `[ × ]` close chip — clear visual gesture for
    // dismissing the diff (Esc still works; this is the discoverable
    // form). Painted in red so it stands out from the view-mode
    // chips.
    let close_label = " × ";
    let close_w = close_label.chars().count() as u16;
    let area_right = area.x + area.width;
    if area_right > close_w + 1 {
        let close_x = area_right - close_w - 1;
        // Pad between the existing run and the close chip.
        while x < close_x {
            spans.push(Span::styled(" ", Style::default().bg(bg)));
            x += 1;
        }
        spans.push(Span::styled(
            close_label.to_string(),
            Style::default()
                .fg(t.bg_dark)
                .bg(t.red)
                .add_modifier(Modifier::BOLD),
        ));
        buttons_out.push((
            Rect {
                x: close_x,
                y: area.y,
                width: close_w,
                height: 1,
            },
            pane_id,
            crate::DiffToolbarAction::Close,
        ));
    }
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(bg)),
        area,
    );
}

/// Inline view — show the **whole file** in one continuous column
/// (matches a popular Git GUI's Inline view). Uses `d.full_hunks` (lazy-fetched
/// in `draw`) for the full-file context. Falls back to `d.hunks`
/// (with per-hunk headers) if full-context isn't available.
///
/// Each row gets a `<old_no> <new_no>` line-number gutter, then a
/// sign + body. Added lines tint green; Removed lines tint red.
#[allow(clippy::too_many_arguments)]
pub fn render_inline(
    frame: &mut Frame,
    d: &mut crate::pane::DiffView,
    t: &Theme,
    area: Rect,
    list_rows: &mut Vec<(Rect, PaneId, usize)>,
    scrollbars: &mut Vec<crate::app::ScrollbarHit>,
    hunk_chips_out: &mut Vec<(Rect, PaneId, usize, crate::DiffHunkAction)>,
    sb_kind: crate::app::ScrollbarKind,
    pane_id: PaneId,
) {
    // Reserve three columns on the right edge: a 1-cell padding (so
    // body text isn't flush against the change strip), the inner
    // change-density indicator (`▎` glyphs in green/red/yellow), and
    // the outer scrollbar (track + thumb).
    const SB_W: u16 = 1;
    const CHANGE_W: u16 = 1;
    const PAD_W: u16 = 1;
    let want_sb = area.width >= 18;
    let sb_w = if want_sb { SB_W } else { 0 };
    let change_w = if want_sb { CHANGE_W } else { 0 };
    let pad_w = if want_sb { PAD_W } else { 0 };
    let reserved = sb_w + change_w + pad_w;
    let body_area = Rect::new(area.x, area.y, area.width - reserved, area.height);
    let change_area = Rect::new(
        area.x + area.width - sb_w - change_w,
        area.y,
        change_w,
        area.height,
    );
    let sb_area = Rect::new(area.x + area.width - sb_w, area.y, sb_w, area.height);
    let area = body_area; // shadow so the rest of this fn renders into body

    // Prefer full-file hunks (whole file) when available; fall back to
    // the focused hunks if not.
    let render_hunks: &Vec<crate::git::diff::Hunk> = d
        .full_hunks
        .as_ref()
        .filter(|v| !v.is_empty())
        .unwrap_or(&d.hunks);
    let show_headers = !d
        .full_hunks
        .as_ref()
        .map(|v| !v.is_empty())
        .unwrap_or(false);

    let wrap = d.wrap;
    let gutter_w = compute_gutter_width(render_hunks);
    let content_w = area.width as usize;
    let body_w = content_w.saturating_sub(gutter_w + 2); // gutter + marker + sign

    let mut rows: Vec<Line> = Vec::new();
    let mut row_kinds: Vec<RowKind> = Vec::new();
    // Active-hunk chip banner — sticky top-of-body Stage / Discard /
    // Unstage chips that act on `d.cursor`'s hunk. Hunk view skips
    // this (its per-header chips cover the same gesture).
    if let Some(line) = active_hunk_chips_row(
        d,
        t,
        area.y + rows.len() as u16,
        area.x,
        area.width,
        pane_id,
        hunk_chips_out,
    ) {
        rows.push(line);
        row_kinds.push(RowKind::Header);
    }
    if let Some(line) = filter_status_line(d, t) {
        rows.push(line);
        row_kinds.push(RowKind::Header);
    }
    let mut hunk_row: Vec<usize> = Vec::with_capacity(render_hunks.len());

    for (hi, h) in render_hunks.iter().enumerate() {
        hunk_row.push(rows.len());
        if show_headers {
            // Focused-hunk fallback only: paint the `@@ -X,Y +Z,W @@`
            // banner so the user knows where they are. Full-file mode
            // is one continuous file — no per-hunk header.
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
            row_kinds.push(RowKind::Header);
        }

        let (old_start, new_start) = hunk_start_lines(h);
        let pair_partner = compute_intraline_partners(&h.lines);
        let nos = pair_line_nos(&h.lines, old_start, new_start);
        let added_bg = added_row_bg(t);
        let removed_bg = removed_row_bg(t);

        for (li, hl) in h.lines.iter().enumerate() {
            // graphical-Git-GUI-style: row bg tints added / removed; body fg
            // stays `t.fg` (so the code reads naturally); only the
            // `+`/`-` marker + the left chip carry the change color.
            let (marker, marker_color, body, fg, sign, row_bg, kind) = match hl {
                HunkLine::Context(s) => (
                    " ",
                    t.grey,
                    s.as_str(),
                    t.fg,
                    " ",
                    t.bg_dark,
                    RowKind::Context,
                ),
                HunkLine::Added(s) => (
                    "▏",
                    t.green,
                    s.as_str(),
                    t.fg,
                    "+",
                    added_bg,
                    RowKind::Added,
                ),
                HunkLine::Removed(s) => (
                    "▏",
                    t.red,
                    s.as_str(),
                    t.fg,
                    "-",
                    removed_bg,
                    RowKind::Removed,
                ),
                HunkLine::NoNewline => (
                    " ",
                    t.grey,
                    "\\ No newline at end of file",
                    t.comment,
                    " ",
                    t.bg_dark,
                    RowKind::Context,
                ),
            };
            let intraline_range = intraline_range_for(&h.lines, li, &pair_partner, hl);
            let (old_no, new_no) = nos[li];
            let gutter = gutter_text_pair(old_no, new_no, gutter_w);

            let mut line_spans = vec![
                Span::styled(gutter, Style::default().fg(t.comment).bg(row_bg)),
                Span::styled(marker, Style::default().fg(marker_color).bg(row_bg)),
            ];
            if let Some((mid_start, mid_end)) = intraline_range
                && mid_end > mid_start
            {
                let body_chars: Vec<char> = body.chars().collect();
                let prefix: String = body_chars[..mid_start].iter().collect();
                let middle: String = body_chars[mid_start..mid_end].iter().collect();
                let suffix: String = body_chars[mid_end..].iter().collect();
                line_spans.push(Span::styled(
                    format!("{sign} {prefix}"),
                    Style::default().fg(t.comment).bg(row_bg),
                ));
                line_spans.push(Span::styled(
                    middle,
                    Style::default()
                        .fg(fg)
                        .bg(row_bg)
                        .add_modifier(Modifier::BOLD),
                ));
                line_spans.push(Span::styled(
                    suffix,
                    Style::default().fg(t.comment).bg(row_bg),
                ));
                rows.push(Line::from(line_spans));
                row_kinds.push(kind);
            } else if wrap && body_w > 0 {
                let chunk_w = body_w;
                let body_chars: Vec<char> = body.chars().collect();
                if body_chars.is_empty() {
                    line_spans.push(Span::styled(
                        format!("{sign} "),
                        Style::default().fg(fg).bg(row_bg),
                    ));
                    rows.push(Line::from(line_spans));
                    row_kinds.push(kind);
                } else {
                    let mut first = true;
                    let mut idx = 0;
                    while idx < body_chars.len() {
                        let end = (idx + chunk_w).min(body_chars.len());
                        let chunk: String = body_chars[idx..end].iter().collect();
                        let prefix = if first {
                            first = false;
                            format!("{sign} ")
                        } else {
                            "  ".to_string()
                        };
                        let blank_gutter = " ".repeat(gutter_w);
                        rows.push(Line::from(vec![
                            Span::styled(
                                if first {
                                    gutter_text_pair(old_no, new_no, gutter_w)
                                } else {
                                    blank_gutter
                                },
                                Style::default().fg(t.comment).bg(row_bg),
                            ),
                            Span::styled(marker, Style::default().fg(marker_color).bg(row_bg)),
                            Span::styled(
                                format!("{prefix}{chunk}"),
                                Style::default().fg(fg).bg(row_bg),
                            ),
                        ]));
                        row_kinds.push(kind);
                        idx = end;
                    }
                }
            } else {
                let base = Style::default().fg(fg).bg(row_bg);
                let highlighted =
                    highlight_filter_spans(format!("{sign} {body}"), &d.filter, base, t.yellow);
                line_spans.extend(highlighted);
                rows.push(Line::from(line_spans));
                row_kinds.push(kind);
            }
        }
        if show_headers {
            rows.push(Line::from(Span::styled(
                " ",
                Style::default().bg(t.bg_dark),
            )));
            row_kinds.push(RowKind::Spacer);
        }
    }

    // Inline view: decouple scroll from cursor (full-file is a single
    // logical document; the user scrolls freely).
    let h = area.height as usize;
    if show_headers {
        // Focused fallback: keep cursor hunk on screen (it's the only
        // way to know which one is selected without a per-hunk banner).
        let target = hunk_row[d.cursor.min(hunk_row.len().saturating_sub(1))];
        if target < d.scroll {
            d.scroll = target;
        } else if target >= d.scroll + h {
            d.scroll = target + 1 - h;
        }
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    d.scroll = d.scroll.min(max_scroll);

    for (hi, &line_y) in hunk_row.iter().enumerate() {
        let next_y = hunk_row.get(hi + 1).copied().unwrap_or(rows.len());
        for row_y in line_y..next_y {
            if row_y < d.scroll || row_y >= d.scroll + h {
                continue;
            }
            let visible_y = row_y - d.scroll;
            let screen_y = area.y.saturating_add(visible_y as u16);
            if screen_y < area.y.saturating_add(area.height) {
                list_rows.push((
                    ratatui::layout::Rect {
                        x: area.x,
                        y: screen_y,
                        width: area.width,
                        height: 1,
                    },
                    pane_id,
                    hi,
                ));
            }
        }
    }

    let scroll = d.scroll;
    let view: Vec<Line> = rows.iter().skip(scroll).take(h).cloned().collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );

    if sb_w > 0 {
        if change_w > 0 {
            draw_change_strip(frame, change_area, t, &row_kinds);
        }
        draw_diff_scrollbar(frame, sb_area, t, rows.len(), scroll, h);
        scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id,
            total: rows.len(),
            viewport: h,
            kind: sb_kind,
        });
    }
}

/// `Hunk` view: focused, expanded-by-default chevron-fold hunks
/// (a popular Git GUI's "Hunk" view). Each hunk shows its `@@ -X,Y +Z,W @@`
/// banner + the changed lines with a `<old_no> <new_no>` line-number
/// gutter. Click a chevron to collapse one you don't need.
#[allow(clippy::too_many_arguments)]
pub fn render_hunk(
    frame: &mut Frame,
    d: &mut crate::pane::DiffView,
    t: &Theme,
    area: Rect,
    list_rows: &mut Vec<(Rect, PaneId, usize)>,
    scrollbars: &mut Vec<crate::app::ScrollbarHit>,
    hunk_chips_out: &mut Vec<(Rect, PaneId, usize, crate::DiffHunkAction)>,
    sb_kind: crate::app::ScrollbarKind,
    pane_id: PaneId,
) {
    // Reserve two columns on the right edge: inner = thin change
    // indicator (`▏` glyphs), outer = scrollbar.
    const SB_W: u16 = 1;
    const CHANGE_W: u16 = 1;
    let want_sb = area.width >= 17;
    let sb_w = if want_sb { SB_W } else { 0 };
    let change_w = if want_sb { CHANGE_W } else { 0 };
    let reserved = sb_w + change_w;
    let body_area = Rect::new(area.x, area.y, area.width - reserved, area.height);
    let change_area = Rect::new(
        area.x + area.width - reserved,
        area.y,
        change_w,
        area.height,
    );
    let sb_area = Rect::new(area.x + area.width - sb_w, area.y, sb_w, area.height);
    let area = body_area;

    let chip_actions = chip_actions_for_scope(&d.scope, t);
    let chips_total_w = chips_total_width(chip_actions);

    let gutter_w = compute_gutter_width(&d.hunks);
    let mut rows: Vec<Line> = Vec::new();
    let mut row_kinds: Vec<RowKind> = Vec::new();
    // Sticky active-hunk chip banner — same gesture surface as
    // Inline + Split views. Hunk additionally embeds per-header
    // chips inside each `@@` row (below); the sticky row gives a
    // consistent always-visible Stage/Discard for the cursor hunk.
    if let Some(line) = active_hunk_chips_row(
        d,
        t,
        area.y + rows.len() as u16,
        area.x,
        area.width,
        pane_id,
        hunk_chips_out,
    ) {
        rows.push(line);
        row_kinds.push(RowKind::Header);
    }
    if let Some(line) = filter_status_line(d, t) {
        rows.push(line);
        row_kinds.push(RowKind::Header);
    }
    let mut hunk_row: Vec<usize> = Vec::with_capacity(d.hunks.len());
    // Per-hunk: list of `(col, width, action)` for each chip in the
    // header row. Resolved to screen rects after scroll is finalized.
    let mut hunk_chip_positions: Vec<Vec<(usize, usize, crate::DiffHunkAction)>> =
        Vec::with_capacity(d.hunks.len());
    let row_w = area.width as usize;
    for (hi, h) in d.hunks.iter().enumerate() {
        hunk_row.push(rows.len());
        let on_cursor = hi == d.cursor;
        // Hunks default to expanded; the user collapses ones they
        // don't care about (sibling of file-tree directory collapse).
        let expanded = !d.hunk_collapsed.contains(&hi);
        let chevron = if expanded { "▾ " } else { "▸ " };
        let head_bg = if on_cursor { t.bg2 } else { t.bg_dark };
        let mut head_style = Style::default().fg(t.cyan).bg(head_bg);
        if on_cursor {
            head_style = head_style.add_modifier(Modifier::BOLD);
        }
        // Per-hunk summary: +N -M.
        let mut added = 0usize;
        let mut removed = 0usize;
        for l in &h.lines {
            match l {
                HunkLine::Added(_) => added += 1,
                HunkLine::Removed(_) => removed += 1,
                _ => {}
            }
        }
        let summary = format!(" +{added} -{removed}");
        // Build the header row. Chips are right-aligned with a
        // pad-filler span between the summary and the chips.
        let prefix_w = 2 // cursor mark
            + chevron.chars().count()
            + h.header.chars().count() + 2
            + h.file_rel.chars().count()
            + summary.chars().count();
        let mut header_spans: Vec<Span> = vec![
            Span::styled(
                if on_cursor { "▶ " } else { "  " },
                Style::default().fg(t.yellow).bg(head_bg),
            ),
            Span::styled(chevron, Style::default().fg(t.purple).bg(head_bg)),
            Span::styled(format!("{}  ", h.header), head_style),
            Span::styled(h.file_rel.clone(), Style::default().fg(t.blue).bg(head_bg)),
            Span::styled(summary, Style::default().fg(t.comment).bg(head_bg)),
        ];
        let chip_start_col = if chips_total_w > 0 && row_w > prefix_w + chips_total_w {
            // Pad between summary and the chip group.
            let pad = row_w - prefix_w - chips_total_w;
            header_spans.push(Span::styled(" ".repeat(pad), Style::default().bg(head_bg)));
            Some(row_w - chips_total_w)
        } else {
            None
        };
        // Painted-chip x-positions per hunk; converted into screen
        // rects after `d.scroll` is finalized (so visible_y is right).
        let mut chip_positions_for_hunk: Vec<(usize, usize, crate::DiffHunkAction)> = Vec::new();
        if let Some(col) = chip_start_col {
            push_chip_spans(
                &mut header_spans,
                &mut chip_positions_for_hunk,
                chip_actions,
                t,
                head_bg,
                col,
            );
        }
        hunk_chip_positions.push(chip_positions_for_hunk);
        rows.push(Line::from(header_spans));
        row_kinds.push(RowKind::Header);
        if expanded {
            let (old_start, new_start) = hunk_start_lines(h);
            let nos = pair_line_nos(&h.lines, old_start, new_start);
            let added_bg = added_row_bg(t);
            let removed_bg = removed_row_bg(t);
            for (li, hl) in h.lines.iter().enumerate() {
                // Tinted row bg + normal-fg body text (a popular Git GUI's
                // styling). The `+`/`-` marker + the left `▏` chip
                // stay saturated as the change indicators.
                let (marker, marker_color, body, sign, row_bg, body_fg, kind) = match hl {
                    HunkLine::Context(s) => (
                        " ",
                        t.grey,
                        s.as_str(),
                        " ",
                        t.bg_dark,
                        t.fg,
                        RowKind::Context,
                    ),
                    HunkLine::Added(s) => (
                        "▏",
                        t.green,
                        s.as_str(),
                        "+",
                        added_bg,
                        t.fg,
                        RowKind::Added,
                    ),
                    HunkLine::Removed(s) => (
                        "▏",
                        t.red,
                        s.as_str(),
                        "-",
                        removed_bg,
                        t.fg,
                        RowKind::Removed,
                    ),
                    HunkLine::NoNewline => (
                        " ",
                        t.grey,
                        "\\ No newline at end of file",
                        " ",
                        t.bg_dark,
                        t.comment,
                        RowKind::Context,
                    ),
                };
                let (old_no, new_no) = nos[li];
                let gutter = gutter_text_pair(old_no, new_no, gutter_w);
                let mut line_spans = vec![
                    Span::styled(gutter, Style::default().fg(t.comment).bg(row_bg)),
                    Span::styled(marker, Style::default().fg(marker_color).bg(row_bg)),
                ];
                let base = Style::default().fg(body_fg).bg(row_bg);
                line_spans.extend(highlight_filter_spans(
                    format!("{sign} {body}"),
                    &d.filter,
                    base,
                    t.yellow,
                ));
                rows.push(Line::from(line_spans));
                row_kinds.push(kind);
            }
        }
        rows.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        row_kinds.push(RowKind::Spacer);
    }

    let h = area.height as usize;
    let target = hunk_row[d.cursor];
    if target < d.scroll {
        d.scroll = target;
    } else if target >= d.scroll + h {
        d.scroll = target + 1 - h;
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    d.scroll = d.scroll.min(max_scroll);

    for (hi, &line_y) in hunk_row.iter().enumerate() {
        let next_y = hunk_row.get(hi + 1).copied().unwrap_or(rows.len());
        for row_y in line_y..next_y {
            if row_y < d.scroll || row_y >= d.scroll + h {
                continue;
            }
            let visible_y = row_y - d.scroll;
            let screen_y = area.y.saturating_add(visible_y as u16);
            if screen_y < area.y.saturating_add(area.height) {
                list_rows.push((
                    ratatui::layout::Rect {
                        x: area.x,
                        y: screen_y,
                        width: area.width,
                        height: 1,
                    },
                    pane_id,
                    hi,
                ));
            }
        }
        // Per-hunk chip click rects (now that scroll is final).
        let header_row = hunk_row[hi];
        if header_row >= d.scroll && header_row < d.scroll + h {
            let visible_y = header_row - d.scroll;
            let screen_y = area.y.saturating_add(visible_y as u16);
            if let Some(positions) = hunk_chip_positions.get(hi) {
                for (col, chip_w, action) in positions {
                    hunk_chips_out.push((
                        Rect {
                            x: area.x + *col as u16,
                            y: screen_y,
                            width: *chip_w as u16,
                            height: 1,
                        },
                        pane_id,
                        hi,
                        *action,
                    ));
                }
            }
        }
    }

    let scroll = d.scroll;
    let view: Vec<Line> = rows.iter().skip(scroll).take(h).cloned().collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );

    if sb_w > 0 {
        if change_w > 0 {
            draw_change_strip(frame, change_area, t, &row_kinds);
        }
        draw_diff_scrollbar(frame, sb_area, t, rows.len(), scroll, h);
        scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id,
            total: rows.len(),
            viewport: h,
            kind: sb_kind,
        });
    }
}

/// graphical-Git-GUI-style split view — old text on the left, new on
/// the right with a `│` divider. Each side gets a 4-cell line-number
/// gutter. Removed lines render on the left with a subtle red bg;
/// Added on the right with a subtle green bg. Context lines appear
/// on both sides. Where one side has nothing, a striped "empty"
/// row visually separates the two sides (no line number).
///
/// Refactored to take `&mut DiffView` directly. Callers must
/// populate `d.full_hunks` (via `App::fetch_diff_full(&d.scope)`)
/// BEFORE calling this — the renderer doesn't reach into App.
#[allow(clippy::too_many_arguments)]
pub fn render_split(
    frame: &mut Frame,
    d: &mut crate::pane::DiffView,
    t: &Theme,
    area: Rect,
    list_rows: &mut Vec<(Rect, PaneId, usize)>,
    scrollbars: &mut Vec<crate::app::ScrollbarHit>,
    hunk_chips_out: &mut Vec<(Rect, PaneId, usize, crate::DiffHunkAction)>,
    sb_kind: crate::app::ScrollbarKind,
    pane_id: PaneId,
) {
    let total_full = area.width as usize;
    if total_full < 16 {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                " pane too narrow for split view ",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ))),
            area,
        );
        return;
    }
    // Reserve a 1-cell scrollbar / change-minimap on the right edge —
    // matches the editor pane's scrollbar + the Hunk / Inline views.
    const SB_W: u16 = 1;
    const CHANGE_W: u16 = 1;
    const PAD_W: u16 = 1;
    let want_sb = area.width >= 34;
    let sb_w = if want_sb { SB_W } else { 0 };
    let change_w = if want_sb { CHANGE_W } else { 0 };
    let pad_w = if want_sb { PAD_W } else { 0 };
    let reserved = sb_w + change_w + pad_w;
    let total = total_full.saturating_sub(reserved as usize);
    let body_area = Rect::new(area.x, area.y, area.width - reserved, area.height);
    let change_area = Rect::new(
        area.x + area.width - sb_w - change_w,
        area.y,
        change_w,
        area.height,
    );
    let sb_area = Rect::new(area.x + area.width - sb_w, area.y, sb_w, area.height);

    let gutter_w: usize = 5;
    let divider_w: usize = 3;
    let avail = total.saturating_sub(gutter_w * 2 + divider_w);
    let col_w = avail / 2;
    let mut rows: Vec<Line> = Vec::new();
    // Per-row change-kind tag, parallel to `rows`. Drives the minimap.
    let mut row_kinds: Vec<RowKind> = Vec::new();
    if let Some(line) = active_hunk_chips_row(
        d,
        t,
        body_area.y + rows.len() as u16,
        body_area.x,
        body_area.width,
        pane_id,
        hunk_chips_out,
    ) {
        rows.push(line);
        row_kinds.push(RowKind::Header);
    }
    if let Some(line) = filter_status_line(d, t) {
        rows.push(line);
        row_kinds.push(RowKind::Header);
    }
    // Prefer the full-file-context hunks (lazily fetched above) so
    // the user sees the whole before/after of each file, not just the
    // 3-line context around changes. Falls back to the normal hunks
    // when the fetch returns empty (binary files, unparseable diff).
    let render_hunks: &Vec<crate::git::diff::Hunk> = d
        .full_hunks
        .as_ref()
        .filter(|v| !v.is_empty())
        .unwrap_or(&d.hunks);
    let mut hunk_row: Vec<usize> = Vec::with_capacity(render_hunks.len());
    for (hi, h) in render_hunks.iter().enumerate() {
        hunk_row.push(rows.len());
        let on_cursor = hi == d.cursor;
        // ── Hunk header (spans both columns) ──
        let head_bg = if on_cursor { t.bg2 } else { t.bg_darker };
        let header_text = format!(
            "{}{}  {}",
            if on_cursor { "▶ " } else { "  " },
            h.header,
            h.file_rel
        );
        let mut head_style = Style::default().fg(t.cyan).bg(head_bg);
        if on_cursor {
            head_style = head_style.add_modifier(Modifier::BOLD);
        }
        rows.push(Line::from(Span::styled(
            pad_or_truncate(&header_text, total),
            head_style,
        )));
        row_kinds.push(RowKind::Header);
        // ── Per-line side-by-side rows ──
        let ((old_start, _), (new_start, _)) = crate::git::diff::parse_hunk_header(
            h.header
                .trim_start_matches("@@")
                .trim()
                .trim_end_matches('@'),
        )
        .unwrap_or(((1, 0), (1, 0)));
        let pairs = pair_hunk_lines_with_nos(&h.lines, old_start, new_start);
        for pair in pairs {
            let kind = pair_row_kind(&pair);
            rows.push(Line::from(side_by_side_spans_v2(t, col_w, gutter_w, &pair)));
            row_kinds.push(kind);
        }
        // Subtle spacer between hunks.
        rows.push(Line::from(Span::styled(
            " ".repeat(total),
            Style::default().bg(t.bg_dark),
        )));
        row_kinds.push(RowKind::Spacer);
    }

    // Split mode decouples scroll from the hunk cursor: each file's
    // full-context render covers the whole file, so snap-to-cursor
    // would otherwise pull `d.scroll` back to 0 every frame. The
    // user scrolls freely with j/k/PgUp/PgDn/Home/End.
    let h = body_area.height as usize;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    d.scroll = d.scroll.min(max_scroll);

    for (hi, &line_y) in hunk_row.iter().enumerate() {
        let next_y = hunk_row.get(hi + 1).copied().unwrap_or(rows.len());
        for row_y in line_y..next_y {
            if row_y < d.scroll || row_y >= d.scroll + h {
                continue;
            }
            let visible_y = row_y - d.scroll;
            let screen_y = body_area.y.saturating_add(visible_y as u16);
            if screen_y < body_area.y.saturating_add(body_area.height) {
                list_rows.push((
                    ratatui::layout::Rect {
                        x: body_area.x,
                        y: screen_y,
                        width: body_area.width,
                        height: 1,
                    },
                    pane_id,
                    hi,
                ));
            }
        }
    }

    let scroll = d.scroll;
    let view: Vec<Line> = rows.iter().skip(scroll).take(h).cloned().collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        body_area,
    );

    // ── Paint the unified scrollbar / change-minimap on the right edge ──
    if sb_w > 0 {
        if change_w > 0 {
            draw_change_strip(frame, change_area, t, &row_kinds);
        }
        draw_diff_scrollbar(frame, sb_area, t, rows.len(), scroll, h);
        scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id,
            total: rows.len(),
            viewport: h,
            kind: sb_kind,
        });
    }
}

/// 1-cell scrollbar — `bg2` track + `comment` thumb. No change
/// markers (those live in the sibling `draw_change_strip` column to
/// the left). Skipped when `area.height == 0`.
fn draw_diff_scrollbar(
    frame: &mut Frame,
    area: Rect,
    t: &Theme,
    total: usize,
    scroll: usize,
    viewport_h: usize,
) {
    if area.height == 0 || area.width == 0 {
        return;
    }
    let cells = area.height as usize;
    // Track.
    for cy in 0..cells {
        let cell_area = Rect::new(area.x, area.y + cy as u16, area.width, 1);
        frame.render_widget(
            Paragraph::new(" ".repeat(area.width as usize)).style(Style::default().bg(t.bg2)),
            cell_area,
        );
    }
    // Thumb — only when content overflows the viewport.
    if total > viewport_h && viewport_h > 0 {
        let thumb_h = ((cells * viewport_h) / total).max(1);
        let max_scroll = total - viewport_h;
        let max_thumb_top = cells.saturating_sub(thumb_h);
        let thumb_top = (scroll * max_thumb_top)
            .checked_div(max_scroll)
            .unwrap_or(0);
        for cy in thumb_top..(thumb_top + thumb_h).min(cells) {
            let cell_area = Rect::new(area.x, area.y + cy as u16, area.width, 1);
            frame.render_widget(
                Paragraph::new(" ".repeat(area.width as usize))
                    .style(Style::default().bg(t.comment)),
                cell_area,
            );
        }
    }
}

/// 1-cell change-density indicator (sits to the left of the
/// scrollbar with a padding column between it and the body text).
/// Each cell paints a `▎` glyph (1/4-block vertical bar — thicker
/// than `▏` so it actually reads as a tick, thinner than `▌` so it
/// doesn't compete with the scrollbar thumb) in green / red /
/// yellow based on the change mix in that file-row range.
fn draw_change_strip(frame: &mut Frame, area: Rect, t: &Theme, row_kinds: &[RowKind]) {
    if area.height == 0 || area.width == 0 || row_kinds.is_empty() {
        return;
    }
    let cells = area.height as usize;
    let total = row_kinds.len();
    for cy in 0..cells {
        let lo = cy * total / cells;
        let hi = ((cy + 1) * total / cells).max(lo + 1).min(total);
        let mut has_added = false;
        let mut has_removed = false;
        for k in &row_kinds[lo..hi] {
            match k {
                RowKind::Added => has_added = true,
                RowKind::Removed => has_removed = true,
                RowKind::Both => {
                    has_added = true;
                    has_removed = true;
                }
                _ => {}
            }
        }
        let color = match (has_added, has_removed) {
            (true, true) => Some(t.yellow),
            (true, false) => Some(t.green),
            (false, true) => Some(t.red),
            (false, false) => None,
        };
        let cell_area = Rect::new(area.x, area.y + cy as u16, area.width, 1);
        let (glyph, style) = if let Some(c) = color {
            (
                "▎".repeat(area.width as usize),
                Style::default().fg(c).bg(t.bg_dark),
            )
        } else {
            (
                " ".repeat(area.width as usize),
                Style::default().bg(t.bg_dark),
            )
        };
        frame.render_widget(Paragraph::new(glyph).style(style), cell_area);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RowKind {
    Header,
    Spacer,
    Context,
    Added,
    Removed,
    Both,
}

fn pair_row_kind(pair: &PairRow) -> RowKind {
    let l = pair.left.kind;
    let r = pair.right.kind;
    let has_rem = matches!(l, SideKind::Removed);
    let has_add = matches!(r, SideKind::Added);
    match (has_rem, has_add) {
        (true, true) => RowKind::Both,
        (true, false) => RowKind::Removed,
        (false, true) => RowKind::Added,
        (false, false) => RowKind::Context,
    }
}

/// Find the next (forward) / previous (backward) hunk index whose
/// body text (any line) contains `d.filter` (case-insensitive,
/// substring). Wraps. Returns None when no hunk matches.
pub fn next_filter_match(d: &crate::pane::DiffView, forward: bool) -> Option<usize> {
    if d.filter.is_empty() || d.hunks.is_empty() {
        return None;
    }
    let needle = d.filter.to_lowercase();
    let n = d.hunks.len();
    let start = d.cursor;
    let matches = |h: &crate::git::diff::Hunk| -> bool {
        for l in &h.lines {
            let text = match l {
                HunkLine::Context(s) | HunkLine::Added(s) | HunkLine::Removed(s) => s,
                _ => continue,
            };
            if text.to_lowercase().contains(&needle) {
                return true;
            }
        }
        false
    };
    if forward {
        for off in 1..=n {
            let i = (start + off) % n;
            if matches(&d.hunks[i]) {
                return Some(i);
            }
        }
    } else {
        for off in 1..=n {
            let i = (start + n - off) % n;
            if matches(&d.hunks[i]) {
                return Some(i);
            }
        }
    }
    None
}

/// Build one or more spans for a diff body text run, highlighting
/// case-insensitive substring matches of `filter` with a yellow bg.
/// Empty filter ⇒ a single un-highlighted span. The fg color stays
/// as-is over the matched run; only the bg switches (the diff's row
/// bg tint is preserved on non-match cells).
fn highlight_filter_spans(
    text: String,
    filter: &str,
    base_style: Style,
    match_bg: Color,
) -> Vec<Span<'static>> {
    if filter.is_empty() {
        return vec![Span::styled(text, base_style)];
    }
    let needle = filter.to_lowercase();
    let lc = text.to_lowercase();
    let mut spans: Vec<Span<'static>> = Vec::new();
    // Walk char-aligned: we match in lowercased *char* indices and
    // slice the original `text` by chars accordingly.
    let chars: Vec<char> = text.chars().collect();
    let lc_chars: Vec<char> = lc.chars().collect();
    let needle_chars: Vec<char> = needle.chars().collect();
    if needle_chars.is_empty() {
        return vec![Span::styled(text, base_style)];
    }
    let mut i = 0;
    let mut last = 0;
    while i + needle_chars.len() <= lc_chars.len() {
        if lc_chars[i..i + needle_chars.len()] == needle_chars[..] {
            if last < i {
                let chunk: String = chars[last..i].iter().collect();
                spans.push(Span::styled(chunk, base_style));
            }
            let chunk: String = chars[i..i + needle_chars.len()].iter().collect();
            spans.push(Span::styled(
                chunk,
                base_style.bg(match_bg).add_modifier(Modifier::BOLD),
            ));
            i += needle_chars.len();
            last = i;
        } else {
            i += 1;
        }
    }
    if last < chars.len() {
        let chunk: String = chars[last..].iter().collect();
        spans.push(Span::styled(chunk, base_style));
    }
    if spans.is_empty() {
        vec![Span::styled(text, base_style)]
    } else {
        spans
    }
}

/// One entry per chip — `(label, action, theme-color-picker)`.
type ChipAction = (&'static str, crate::DiffHunkAction, fn(&Theme) -> Color);

/// Per-scope chip-action set for the diff toolbar (Stage / Unstage /
/// Discard). Returns `&[]` for commit / buffer-vs-disk scopes (no
/// staging applicable). Used by all three renderers — keeps the chip
/// set consistent.
fn chip_actions_for_scope(scope: &crate::pane::DiffScope, t: &Theme) -> &'static [ChipAction] {
    let _ = t;
    use crate::pane::DiffScope;
    match scope {
        DiffScope::Unstaged(_) | DiffScope::AllVsHead => &[
            (" Stage ", crate::DiffHunkAction::Stage, |t| t.green),
            (" Discard ", crate::DiffHunkAction::Discard, |t| t.red),
        ],
        DiffScope::Staged | DiffScope::StagedFile(_) => {
            &[(" Unstage ", crate::DiffHunkAction::Unstage, |t| t.orange)]
        }
        _ => &[],
    }
}

/// Total width (chars) of the chip-group including the 1-cell gap
/// between adjacent chips. Useful for right-aligning the chips on a
/// header row.
fn chips_total_width(actions: &[ChipAction]) -> usize {
    actions.iter().map(|(l, _, _)| l.chars().count() + 1).sum()
}

/// Push the chip spans into `header_spans` AND record their
/// `(col, width, action)` triples into `chip_positions` (col is the
/// absolute screen column, computed against `prefix_w` + `chip_start`).
/// The chip rect's `y` is filled in later, once the scroll is final.
fn push_chip_spans(
    header_spans: &mut Vec<Span<'static>>,
    chip_positions: &mut Vec<(usize, usize, crate::DiffHunkAction)>,
    actions: &[ChipAction],
    t: &Theme,
    head_bg: Color,
    mut col: usize,
) {
    for (label, action, color_fn) in actions {
        header_spans.push(Span::styled(" ", Style::default().bg(head_bg)));
        col += 1;
        header_spans.push(Span::styled(
            label.to_string(),
            Style::default()
                .fg(t.bg_dark)
                .bg(color_fn(t))
                .add_modifier(Modifier::BOLD),
        ));
        let chip_w = label.chars().count();
        chip_positions.push((col, chip_w, *action));
        col += chip_w;
    }
}

/// 1-row banner showing the current hunk (`Hunk N/M  src/file.rs`)
/// plus right-aligned action chips for the cursor hunk. Used by
/// Inline + Split views where there's no per-hunk header to attach
/// chips to (the full-file mode renders one continuous body). Hunk
/// view skips this because its per-header chips already cover the
/// gesture. Returns `None` when chip actions don't apply to the
/// current scope.
///
/// Chip rects are pushed into `chips_out` (`y` = `body_y`, the row
/// the caller is about to render). When the row is non-empty, the
/// caller should both render it AND increment its body Y by 1.
fn active_hunk_chips_row(
    d: &crate::pane::DiffView,
    t: &Theme,
    body_y: u16,
    body_x: u16,
    body_w: u16,
    pane_id: PaneId,
    chips_out: &mut Vec<(Rect, PaneId, usize, crate::DiffHunkAction)>,
) -> Option<Line<'static>> {
    let actions = chip_actions_for_scope(&d.scope, t);
    if actions.is_empty() || d.hunks.is_empty() {
        return None;
    }
    let cursor = d.cursor.min(d.hunks.len() - 1);
    let h = &d.hunks[cursor];
    let label = format!(" Hunk {}/{}  {}", cursor + 1, d.hunks.len(), h.file_rel);
    let chips_w = chips_total_width(actions);
    let row_w = body_w as usize;
    let label_w = label.chars().count();
    let chip_start_col_in_row = if row_w > label_w + chips_w {
        Some(row_w - chips_w)
    } else {
        None
    };
    let mut spans: Vec<Span<'static>> = vec![Span::styled(
        label,
        Style::default()
            .fg(t.cyan)
            .bg(t.bg_darker)
            .add_modifier(Modifier::BOLD),
    )];
    if let Some(chip_start_col_in_row) = chip_start_col_in_row {
        // Pad between label and chips.
        let pad = chip_start_col_in_row - label_w;
        spans.push(Span::styled(
            " ".repeat(pad),
            Style::default().bg(t.bg_darker),
        ));
        // Push chip spans + capture absolute screen rects.
        let mut positions: Vec<(usize, usize, crate::DiffHunkAction)> = Vec::new();
        push_chip_spans(
            &mut spans,
            &mut positions,
            actions,
            t,
            t.bg_darker,
            chip_start_col_in_row,
        );
        for (col, w, action) in positions {
            chips_out.push((
                Rect {
                    x: body_x + col as u16,
                    y: body_y,
                    width: w as u16,
                    height: 1,
                },
                pane_id,
                cursor,
                action,
            ));
        }
    }
    Some(Line::from(spans))
}

/// Build a 1-row status banner for the diff's `/` filter — shown
/// at the top of the body when the filter is active or being typed.
/// Returns None when there's no filter to show (the renderers then
/// skip the row).
fn filter_status_line(d: &crate::pane::DiffView, t: &Theme) -> Option<Line<'static>> {
    if d.filter.is_empty() && !d.filter_mode {
        return None;
    }
    let chip_fg = t.bg_dark;
    let chip_bg = t.yellow;
    let label = if d.filter_mode {
        format!(" / {}_  ", d.filter)
    } else {
        format!(" filter: {}  ", d.filter)
    };
    let hint = if d.filter_mode {
        " Backspace · Enter · Esc clears ".to_string()
    } else {
        " Esc clears ".to_string()
    };
    Some(Line::from(vec![
        Span::styled(
            label,
            Style::default()
                .fg(chip_fg)
                .bg(chip_bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(hint, Style::default().fg(t.comment).bg(t.bg_darker)),
    ]))
}

/// Mix `fg` over `bg` at `alpha / 255` opacity. Used to derive the
/// subtle green / red row-background tints for added / removed lines
/// (graphical-Git-GUI-style) from the theme's own green / red colors. When
/// either input isn't an `Rgb` variant (named / indexed colors don't
/// have a known palette here) the function falls back to `fallback`
/// — picks a sensible muted tint for the typical dark-bg case.
fn blend_over(fg: Color, bg: Color, alpha: u8, fallback: Color) -> Color {
    match (fg, bg) {
        (Color::Rgb(fr, fg2, fb), Color::Rgb(br, bg2, bb)) => {
            let a = alpha as u16;
            let inv = 255u16 - a;
            let r = ((fr as u16 * a + br as u16 * inv) / 255) as u8;
            let g = ((fg2 as u16 * a + bg2 as u16 * inv) / 255) as u8;
            let b = ((fb as u16 * a + bb as u16 * inv) / 255) as u8;
            Color::Rgb(r, g, b)
        }
        _ => fallback,
    }
}

/// Subtle green tint for added rows — derived from the theme's
/// `green` blended over `bg_dark` at ~18%. Falls back to a muted
/// dark-green for indexed-color themes.
fn added_row_bg(t: &Theme) -> Color {
    blend_over(t.green, t.bg_dark, 45, Color::Rgb(20, 48, 28))
}

/// Subtle red tint for removed rows — symmetric with `added_row_bg`.
fn removed_row_bg(t: &Theme) -> Color {
    blend_over(t.red, t.bg_dark, 45, Color::Rgb(56, 22, 26))
}

/// Parse a `@@ -X,Y +Z,W @@` hunk header back into `(old_start,
/// new_start)`. Falls back to `(1, 1)` when the header isn't
/// parseable (shouldn't happen for hunks `git diff` emits, but keeps
/// the renderer infallible).
fn hunk_start_lines(h: &crate::git::diff::Hunk) -> (usize, usize) {
    let stripped = h
        .header
        .trim_start_matches("@@")
        .trim()
        .trim_end_matches('@');
    crate::git::diff::parse_hunk_header(stripped)
        .map(|((o, _), (n, _))| (o, n))
        .unwrap_or((1, 1))
}

/// Walk `lines` from `(old_start, new_start)` and emit a per-line
/// `(Option<old_no>, Option<new_no>)` so the gutter knows which sides
/// to label.
fn pair_line_nos(
    lines: &[HunkLine],
    old_start: usize,
    new_start: usize,
) -> Vec<(Option<usize>, Option<usize>)> {
    let mut out = Vec::with_capacity(lines.len());
    let mut old_no = old_start;
    let mut new_no = new_start;
    for l in lines {
        match l {
            HunkLine::Context(_) => {
                out.push((Some(old_no), Some(new_no)));
                old_no += 1;
                new_no += 1;
            }
            HunkLine::Removed(_) => {
                out.push((Some(old_no), None));
                old_no += 1;
            }
            HunkLine::Added(_) => {
                out.push((None, Some(new_no)));
                new_no += 1;
            }
            HunkLine::NoNewline => out.push((None, None)),
        }
    }
    out
}

/// Width of the `<old> <new> ` line-number gutter — sized to fit the
/// largest line number across every hunk's body. Always ≥ 7 (3 + 1 + 3
/// for two 3-digit numbers and a space) so it doesn't look pinched.
fn compute_gutter_width(hunks: &[crate::git::diff::Hunk]) -> usize {
    let mut max_old = 1usize;
    let mut max_new = 1usize;
    for h in hunks {
        let (os, ns) = hunk_start_lines(h);
        let nos = pair_line_nos(&h.lines, os, ns);
        for (o, n) in nos {
            if let Some(v) = o {
                max_old = max_old.max(v);
            }
            if let Some(v) = n {
                max_new = max_new.max(v);
            }
        }
    }
    let w_old = digits(max_old).max(3);
    let w_new = digits(max_new).max(3);
    w_old + 1 + w_new + 1 // <old> <new>·
}

fn digits(n: usize) -> usize {
    if n == 0 {
        return 1;
    }
    let mut n = n;
    let mut d = 0;
    while n > 0 {
        d += 1;
        n /= 10;
    }
    d
}

/// Render `<old> <new> ` clamped to `gutter_w`. Empty slots show as
/// blank space — never as `─` (matches a popular Git GUI's quieter style).
fn gutter_text_pair(old_no: Option<usize>, new_no: Option<usize>, gutter_w: usize) -> String {
    // Reserve trailing space for separation from the marker; split the
    // remaining width evenly across the two columns.
    if gutter_w == 0 {
        return String::new();
    }
    let inner = gutter_w.saturating_sub(1); // trailing space
    let w_each = inner.saturating_sub(1) / 2; // one space between
    let render = |n: Option<usize>| -> String {
        match n {
            Some(v) => {
                let s = v.to_string();
                let pad = w_each.saturating_sub(s.chars().count());
                format!("{}{}", " ".repeat(pad), s)
            }
            None => " ".repeat(w_each),
        }
    };
    format!("{} {} ", render(old_no), render(new_no))
}

/// Same intraline-partner walk inline-mode used inline. Returns a
/// per-line `Some(partner_idx)` when `Removed[i]` should pair with
/// `Added[i+1]`.
fn compute_intraline_partners(lines: &[HunkLine]) -> Vec<Option<usize>> {
    (0..lines.len())
        .map(|i| {
            if !matches!(lines.get(i), Some(HunkLine::Removed(_))) {
                return None;
            }
            if !matches!(lines.get(i + 1), Some(HunkLine::Added(_))) {
                return None;
            }
            if i > 0 && matches!(lines.get(i - 1), Some(HunkLine::Removed(_))) {
                return None;
            }
            if matches!(lines.get(i + 2), Some(HunkLine::Added(_))) {
                return None;
            }
            Some(i + 1)
        })
        .collect()
}

/// Compute the intraline-diff range for `hl` at index `li`, given
/// `pair_partner`. Returns the (start, end) char range of the
/// differing middle, or None when this line has no paired partner.
fn intraline_range_for(
    lines: &[HunkLine],
    li: usize,
    pair_partner: &[Option<usize>],
    hl: &HunkLine,
) -> Option<(usize, usize)> {
    match hl {
        HunkLine::Removed(s) if pair_partner[li].is_some() => {
            let partner_idx = pair_partner[li].unwrap();
            if let Some(HunkLine::Added(p)) = lines.get(partner_idx) {
                let ((a, b), _) = crate::git::diff::intraline_diff(s, p);
                Some((a, b))
            } else {
                None
            }
        }
        HunkLine::Added(s) if li > 0 && pair_partner[li - 1] == Some(li) => {
            if let Some(HunkLine::Removed(p)) = lines.get(li - 1) {
                let (_, (a, b)) = crate::git::diff::intraline_diff(p, s);
                Some((a, b))
            } else {
                None
            }
        }
        _ => None,
    }
}

/// Side-by-side row payload: each side has its content cell + a
/// 1-based line number (or `None` for an empty/filler half).
#[derive(Debug, Clone, Default)]
struct PairRow {
    left: SideCell,
    left_no: Option<usize>,
    right: SideCell,
    right_no: Option<usize>,
}

/// Walk `lines` from the hunk's `(old_start, new_start)` line numbers
/// and emit aligned (left, right, lineno) pairs. Context lines appear
/// on both sides; Removed-then-Added runs are zipped; orphan
/// Removed/Added rows leave the opposite side as a `SideKind::Empty`
/// filler with no line number.
fn pair_hunk_lines_with_nos(
    lines: &[HunkLine],
    old_start: usize,
    new_start: usize,
) -> Vec<PairRow> {
    let mut out: Vec<PairRow> = Vec::new();
    let mut i = 0;
    let mut old_no = old_start;
    let mut new_no = new_start;
    while i < lines.len() {
        match &lines[i] {
            HunkLine::Context(s) => {
                out.push(PairRow {
                    left: SideCell {
                        text: s.clone(),
                        kind: SideKind::Context,
                    },
                    left_no: Some(old_no),
                    right: SideCell {
                        text: s.clone(),
                        kind: SideKind::Context,
                    },
                    right_no: Some(new_no),
                });
                old_no += 1;
                new_no += 1;
                i += 1;
            }
            HunkLine::Removed(_) => {
                let mut removed: Vec<String> = Vec::new();
                while let Some(HunkLine::Removed(s)) = lines.get(i) {
                    removed.push(s.clone());
                    i += 1;
                }
                let mut added: Vec<String> = Vec::new();
                while let Some(HunkLine::Added(s)) = lines.get(i) {
                    added.push(s.clone());
                    i += 1;
                }
                let max_len = removed.len().max(added.len());
                for k in 0..max_len {
                    let left =
                        removed
                            .get(k)
                            .cloned()
                            .map_or((SideCell::default(), None), |text| {
                                let r = (
                                    SideCell {
                                        text,
                                        kind: SideKind::Removed,
                                    },
                                    Some(old_no),
                                );
                                old_no += 1;
                                r
                            });
                    let right = added
                        .get(k)
                        .cloned()
                        .map_or((SideCell::default(), None), |text| {
                            let r = (
                                SideCell {
                                    text,
                                    kind: SideKind::Added,
                                },
                                Some(new_no),
                            );
                            new_no += 1;
                            r
                        });
                    out.push(PairRow {
                        left: left.0,
                        left_no: left.1,
                        right: right.0,
                        right_no: right.1,
                    });
                }
            }
            HunkLine::Added(_) => {
                let mut added: Vec<String> = Vec::new();
                while let Some(HunkLine::Added(s)) = lines.get(i) {
                    added.push(s.clone());
                    i += 1;
                }
                for s in added {
                    out.push(PairRow {
                        left: SideCell::default(),
                        left_no: None,
                        right: SideCell {
                            text: s,
                            kind: SideKind::Added,
                        },
                        right_no: Some(new_no),
                    });
                    new_no += 1;
                }
            }
            HunkLine::NoNewline => {
                let text = "\\ No newline at end of file".to_string();
                out.push(PairRow {
                    left: SideCell {
                        text: text.clone(),
                        kind: SideKind::Context,
                    },
                    left_no: None,
                    right: SideCell {
                        text,
                        kind: SideKind::Context,
                    },
                    right_no: None,
                });
                i += 1;
            }
        }
    }
    out
}

fn side_by_side_spans_v2(
    t: &Theme,
    col_w: usize,
    gutter_w: usize,
    pair: &PairRow,
) -> Vec<Span<'static>> {
    // Tinted backgrounds for added/removed (graphical-Git-GUI-style); bg_dark
    // for everything else. `bg2` for empty filler so it visually reads
    // as "nothing here" without disappearing into the surrounding bg.
    let added_bg = added_row_bg(t);
    let removed_bg = removed_row_bg(t);
    let bg_for = |kind: SideKind, has_no: bool| -> Color {
        match kind {
            SideKind::Empty => {
                if has_no {
                    t.bg_dark
                } else {
                    t.bg2
                }
            }
            SideKind::Context => t.bg_dark,
            SideKind::Added => added_bg,
            SideKind::Removed => removed_bg,
        }
    };
    // Body fg stays `t.fg` for changed lines (the row bg tint is the
    // change indicator). Only the sign cell carries the green/red.
    let body_fg_for = |kind: SideKind| -> Color {
        match kind {
            SideKind::Empty => t.comment,
            _ => t.fg,
        }
    };
    let sign_fg_for = |kind: SideKind| -> Color {
        match kind {
            SideKind::Added => t.green,
            SideKind::Removed => t.red,
            SideKind::Context => t.fg,
            SideKind::Empty => t.comment,
        }
    };
    let sign_for = |kind: SideKind, has_no: bool| -> &'static str {
        match kind {
            SideKind::Added => "+",
            SideKind::Removed => "-",
            SideKind::Context => " ",
            SideKind::Empty => {
                if has_no {
                    " "
                } else {
                    "·"
                }
            }
        }
    };
    // Both arms must emit exactly `width + 1` chars — the Some path
    // appends a trailing space to separate the number from the sign
    // cell, so the None path has to match width to keep the body
    // aligned across numbered + empty-filler rows.
    let gutter_text = |no: Option<usize>, width: usize| -> String {
        match no {
            Some(n) => {
                let s = n.to_string();
                let pad = width.saturating_sub(s.chars().count());
                format!("{}{} ", " ".repeat(pad), s)
            }
            None => " ".repeat(width + 1),
        }
    };

    let left_bg = bg_for(pair.left.kind, pair.left_no.is_some());
    let right_bg = bg_for(pair.right.kind, pair.right_no.is_some());

    // Intraline char ranges — when this row pairs a Removed (left)
    // with an Added (right) and both have non-empty text, compute
    // the differing middle so the user can see what *within* the
    // line actually changed (the existing prefix/suffix common run
    // dims; the middle bolds).
    let intraline: Option<((usize, usize), (usize, usize))> = if matches!(
        (pair.left.kind, pair.right.kind),
        (SideKind::Removed, SideKind::Added)
    ) && !pair.left.text.is_empty()
        && !pair.right.text.is_empty()
    {
        Some(crate::git::diff::intraline_diff(
            &pair.left.text,
            &pair.right.text,
        ))
    } else {
        None
    };

    let body_w = col_w.saturating_sub(1);
    let left_text = pad_or_truncate(&pair.left.text, body_w);
    let right_text = pad_or_truncate(&pair.right.text, body_w);

    let mut spans = vec![
        // Left gutter (line number).
        Span::styled(
            gutter_text(pair.left_no, gutter_w.saturating_sub(1)),
            Style::default().fg(t.comment).bg(left_bg),
        ),
        // Left sign cell.
        Span::styled(
            sign_for(pair.left.kind, pair.left_no.is_some()).to_string(),
            Style::default()
                .fg(sign_fg_for(pair.left.kind))
                .bg(left_bg)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    // Left content — split into 3 spans when intraline range is set.
    if let Some(((ls, le), _)) = intraline
        && le > ls
    {
        push_intraline_spans(
            &mut spans,
            &left_text,
            ls,
            le,
            body_w,
            body_fg_for(pair.left.kind),
            left_bg,
            t.comment,
        );
    } else {
        spans.push(Span::styled(
            format!(" {left_text}"),
            Style::default().fg(body_fg_for(pair.left.kind)).bg(left_bg),
        ));
    }
    // Divider.
    spans.push(Span::styled(
        " │ ",
        Style::default().fg(t.grey).bg(t.bg_dark),
    ));
    spans.push(Span::styled(
        gutter_text(pair.right_no, gutter_w.saturating_sub(1)),
        Style::default().fg(t.comment).bg(right_bg),
    ));
    spans.push(Span::styled(
        sign_for(pair.right.kind, pair.right_no.is_some()).to_string(),
        Style::default()
            .fg(sign_fg_for(pair.right.kind))
            .bg(right_bg)
            .add_modifier(Modifier::BOLD),
    ));
    if let Some((_, (rs, re))) = intraline
        && re > rs
    {
        push_intraline_spans(
            &mut spans,
            &right_text,
            rs,
            re,
            body_w,
            body_fg_for(pair.right.kind),
            right_bg,
            t.comment,
        );
    } else {
        spans.push(Span::styled(
            format!(" {right_text}"),
            Style::default()
                .fg(body_fg_for(pair.right.kind))
                .bg(right_bg),
        ));
    }
    spans
}

/// Emit three spans for one side of a side-by-side row: the leading
/// space + matched prefix in `dim_fg`, the differing middle in `fg` +
/// bold, and the matched suffix again in `dim_fg`. All over the same
/// `bg`. The middle char range `(start, end)` is in chars (matching
/// `intraline_diff`'s output) so we slice the padded text by chars.
#[allow(clippy::too_many_arguments)]
fn push_intraline_spans(
    spans: &mut Vec<Span<'static>>,
    padded_text: &str,
    start: usize,
    end: usize,
    body_w: usize,
    fg: Color,
    bg: Color,
    dim_fg: Color,
) {
    let chars: Vec<char> = padded_text.chars().collect();
    let end = end.min(chars.len());
    let start = start.min(end);
    let prefix: String = chars[..start].iter().collect();
    let middle: String = chars[start..end].iter().collect();
    let suffix: String = chars[end..].iter().collect();
    spans.push(Span::styled(
        format!(" {prefix}"),
        Style::default().fg(dim_fg).bg(bg),
    ));
    spans.push(Span::styled(
        middle,
        Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(suffix, Style::default().fg(dim_fg).bg(bg)));
    let _ = body_w; // padding already applied
}

#[derive(Debug, Clone, Default)]
struct SideCell {
    text: String,
    kind: SideKind,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum SideKind {
    #[default]
    Empty,
    Context,
    Added,
    Removed,
}

fn pad_or_truncate(s: &str, width: usize) -> String {
    let n = s.chars().count();
    if n >= width {
        s.chars().take(width).collect()
    } else {
        let mut out = s.to_string();
        out.extend(std::iter::repeat_n(' ', width - n));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digits_counts_decimal_digits() {
        assert_eq!(digits(0), 1);
        assert_eq!(digits(7), 1);
        assert_eq!(digits(10), 2);
        assert_eq!(digits(99), 2);
        assert_eq!(digits(100), 3);
        assert_eq!(digits(123_456), 6);
    }

    #[test]
    fn pad_or_truncate_always_hits_exact_width() {
        assert_eq!(pad_or_truncate("ab", 5), "ab   ");
        assert_eq!(pad_or_truncate("abc", 3), "abc");
        assert_eq!(pad_or_truncate("abcdef", 3), "abc");
        assert_eq!(pad_or_truncate("ab", 0), "");
        // Char-counted, not byte-counted — multi-byte stays exact.
        assert_eq!(pad_or_truncate("\u{273d}\u{273d}", 4).chars().count(), 4);
        assert_eq!(
            pad_or_truncate("\u{273d}\u{273d}\u{273d}", 3)
                .chars()
                .count(),
            3
        );
    }

    #[test]
    fn gutter_text_pair_fits_the_gutter_and_shows_both_numbers() {
        // Zero-width gutter ⇒ nothing.
        assert_eq!(gutter_text_pair(None, None, 0), "");
        // A normal gutter never overflows and shows both line numbers.
        let g = gutter_text_pair(Some(7), Some(42), 10);
        assert!(g.chars().count() <= 10, "overflowed the gutter: {g:?}");
        assert!(
            g.contains('7') && g.contains("42"),
            "missing a number: {g:?}"
        );
        // An empty slot renders as blank, not a stray digit.
        let only_new = gutter_text_pair(None, Some(3), 10);
        assert!(only_new.contains('3'));
        assert!(only_new.chars().count() <= 10);
    }

    #[test]
    fn blend_over_interpolates_rgb_and_falls_back_otherwise() {
        let white = Color::Rgb(255, 255, 255);
        let black = Color::Rgb(0, 0, 0);
        let fb = Color::Rgb(9, 9, 9);
        // Full alpha ⇒ the foreground; zero alpha ⇒ the background.
        assert_eq!(blend_over(white, black, 255, fb), white);
        assert_eq!(blend_over(white, black, 0, fb), black);
        // Half alpha ⇒ a mid-grey between the two.
        match blend_over(white, black, 128, fb) {
            Color::Rgb(r, _, _) => assert!((120..=135).contains(&r), "mid blend r={r}"),
            other => panic!("expected Rgb, got {other:?}"),
        }
        // A non-RGB input (indexed-color theme) ⇒ the fallback.
        assert_eq!(blend_over(Color::Green, black, 128, fb), fb);
    }

    fn mk_hunk(header: &str, lines: Vec<HunkLine>) -> crate::git::diff::Hunk {
        crate::git::diff::Hunk {
            file: std::path::PathBuf::from("/tmp/foo.rs"),
            file_rel: "foo.rs".to_string(),
            header: header.to_string(),
            new_start: 1,
            lines,
            body: String::new(),
        }
    }

    #[test]
    fn hunk_start_lines_parses_the_at_at_header() {
        // `@@ -10,3 +20,4 @@ fn foo` ⇒ old starts at 10, new at 20.
        assert_eq!(
            hunk_start_lines(&mk_hunk("@@ -10,3 +20,4 @@ fn foo", vec![])),
            (10, 20)
        );
        // Single-count form (no `,B`) still parses.
        assert_eq!(hunk_start_lines(&mk_hunk("@@ -1 +1 @@", vec![])), (1, 1));
        // A garbage header falls back to (1, 1) rather than panicking.
        assert_eq!(
            hunk_start_lines(&mk_hunk("not a hunk header", vec![])),
            (1, 1)
        );
    }

    #[test]
    fn pair_line_nos_advances_each_side_independently() {
        let lines = vec![
            HunkLine::Context("ctx".into()),
            HunkLine::Removed("gone".into()),
            HunkLine::Added("new".into()),
            HunkLine::Context("ctx".into()),
        ];
        let nos = pair_line_nos(&lines, 10, 20);
        assert_eq!(
            nos,
            vec![
                (Some(10), Some(20)), // context bumps both
                (Some(11), None),     // removed: old side only
                (None, Some(21)),     // added: new side only
                (Some(12), Some(22)), // context resumes from each running count
            ]
        );
    }

    #[test]
    fn compute_gutter_width_sizes_to_the_largest_line_number() {
        // No hunks ⇒ the 3+1+3+1 minimum.
        assert_eq!(compute_gutter_width(&[]), 8);
        // A hunk whose new side reaches 1234 needs a 4-wide new column.
        let h = mk_hunk(
            "@@ -1,1 +1230,5 @@",
            vec![
                HunkLine::Added("a".into()),
                HunkLine::Added("b".into()),
                HunkLine::Added("c".into()),
                HunkLine::Added("d".into()),
                HunkLine::Added("e".into()),
            ],
        );
        // 3 (old, min) + 1 + 4 (new) + 1 = 9.
        assert_eq!(compute_gutter_width(&[h]), 9);
    }

    #[test]
    fn highlight_filter_spans_splits_around_matches() {
        let base = Style::default();
        let bg = Color::Yellow;
        // Empty filter ⇒ exactly one un-highlighted span.
        let s = highlight_filter_spans("hello world".into(), "", base, bg);
        assert_eq!(s.len(), 1);
        // A mid-string match ⇒ prefix / match / suffix.
        let s = highlight_filter_spans("a FOO b".into(), "foo", base, bg);
        assert_eq!(s.len(), 3);
        assert_eq!(s[0].content.as_ref(), "a ");
        assert_eq!(s[1].content.as_ref(), "FOO"); // original casing preserved
        assert_eq!(s[1].style.bg, Some(bg));
        assert_eq!(s[2].content.as_ref(), " b");
        // No match ⇒ a single span, no highlight bg.
        let s = highlight_filter_spans("nothing here".into(), "zzz", base, bg);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].style.bg, None);
    }

    #[test]
    fn chip_actions_match_the_diff_scope() {
        use crate::pane::DiffScope;
        let t = theme::onedark();
        // Unstaged ⇒ Stage + Discard.
        let a = chip_actions_for_scope(&DiffScope::Unstaged(None), &t);
        assert_eq!(a.len(), 2);
        assert_eq!(a[0].1, crate::DiffHunkAction::Stage);
        assert_eq!(a[1].1, crate::DiffHunkAction::Discard);
        // Staged ⇒ just Unstage.
        let a = chip_actions_for_scope(&DiffScope::Staged, &t);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].1, crate::DiffHunkAction::Unstage);
        // A commit diff is read-only ⇒ no chips.
        assert!(chip_actions_for_scope(&DiffScope::Commit("abc".into()), &t).is_empty());
        // AllVsHead behaves like Unstaged.
        assert_eq!(chip_actions_for_scope(&DiffScope::AllVsHead, &t).len(), 2);
    }

    #[test]
    fn chips_total_width_sums_labels_plus_gaps() {
        use crate::pane::DiffScope;
        let t = theme::onedark();
        let unstaged = chip_actions_for_scope(&DiffScope::Unstaged(None), &t);
        // " Stage "(7)+1 + " Discard "(9)+1 = 18.
        assert_eq!(chips_total_width(unstaged), 18);
        assert_eq!(chips_total_width(&[]), 0);
    }

    fn mk_diff_view(
        hunks: Vec<crate::git::diff::Hunk>,
        filter: &str,
        cursor: usize,
    ) -> crate::pane::DiffView {
        crate::pane::DiffView {
            scope: crate::pane::DiffScope::AllVsHead,
            hunks,
            scroll: 0,
            cursor,
            view_mode: DiffViewMode::Hunk,
            wrap: false,
            hunk_collapsed: std::collections::HashSet::new(),
            full_hunks: None,
            filter: filter.to_string(),
            filter_mode: false,
        }
    }

    #[test]
    fn next_filter_match_wraps_both_directions() {
        let hunks = vec![
            mk_hunk("@@ -1 +1 @@", vec![HunkLine::Context("alpha".into())]),
            mk_hunk("@@ -2 +2 @@", vec![HunkLine::Added("beta".into())]),
            mk_hunk("@@ -3 +3 @@", vec![HunkLine::Removed("FIND me".into())]),
        ];
        let d = mk_diff_view(hunks, "find", 0);
        // Forward from hunk 0 lands on the matching hunk 2.
        assert_eq!(next_filter_match(&d, true), Some(2));
        // Backward from hunk 0 wraps around to hunk 2.
        assert_eq!(next_filter_match(&d, false), Some(2));
        // An empty filter never matches.
        let empty = mk_diff_view(vec![mk_hunk("@@ -1 +1 @@", vec![])], "", 0);
        assert_eq!(next_filter_match(&empty, true), None);
        // A filter with no hit returns None.
        let miss = mk_diff_view(
            vec![mk_hunk("@@ -1 +1 @@", vec![HunkLine::Context("x".into())])],
            "zzz",
            0,
        );
        assert_eq!(next_filter_match(&miss, true), None);
    }

    #[test]
    fn pair_row_kind_classifies_each_side_combination() {
        let cell = |k: SideKind| SideCell {
            text: String::new(),
            kind: k,
        };
        let row = |l: SideKind, r: SideKind| PairRow {
            left: cell(l),
            right: cell(r),
            left_no: None,
            right_no: None,
        };
        assert_eq!(
            pair_row_kind(&row(SideKind::Removed, SideKind::Added)),
            RowKind::Both
        );
        assert_eq!(
            pair_row_kind(&row(SideKind::Removed, SideKind::Empty)),
            RowKind::Removed
        );
        assert_eq!(
            pair_row_kind(&row(SideKind::Empty, SideKind::Added)),
            RowKind::Added
        );
        assert_eq!(
            pair_row_kind(&row(SideKind::Context, SideKind::Context)),
            RowKind::Context
        );
    }
}
