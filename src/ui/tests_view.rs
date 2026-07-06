//! Renders a `Pane::Tests` — a Playwright run's results: a header with the
//! command + a ✓/✗/⊘ tally, then the tests grouped by file (the highlighted one
//! marked), with a failure's error shown beneath it. Read-only; ↑/↓ move the
//! selection, Enter jumps to the test's source, `r` re-runs, `a`/`f`/`R` run
//! all/file/last-failed (handled in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::playwright::{TestStatus, TestsSort, TestsState};
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
    let want_sb = area.width >= 8;
    let sb_w = if want_sb { 1 } else { 0 };
    let body_area = Rect::new(area.x, area.y, area.width - sb_w, area.height);
    let sb_area = Rect::new(area.x + area.width - sb_w, area.y, sb_w, area.height);
    let area = body_area;
    // Take a peek at the test history first — we'll need it (mutable borrow of
    // `tp` below blocks reading other fields of `app`).
    let history = app.test_history.clone();
    let Some(Pane::Tests(tp)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let body = Style::default().fg(t.fg).bg(t.bg_dark);
    let mut rows: Vec<Line> = Vec::new();
    // Track which rendered row each test maps to, so we can keep the selection on screen.
    let mut test_row: Vec<usize> = Vec::new();

    let cmd = match &tp.state {
        TestsState::Running | TestsState::Failed(_) => format!(
            "npx playwright test --reporter=json{}{}",
            if tp.last_args.is_empty() { "" } else { " " },
            tp.last_args.join(" ")
        ),
        TestsState::Done(r) => r.command.clone(),
    };
    rows.push(Line::from(Span::styled(
        format!("▸ {cmd}"),
        Style::default()
            .fg(t.green)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));

    match &tp.state {
        TestsState::Running => {
            rows.push(Line::from(Span::styled(
                "  ⟳  running…",
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )));
        }
        TestsState::Failed(e) => {
            rows.push(Line::from(Span::styled(
                "  ✗ playwright errored:",
                Style::default()
                    .fg(t.red)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )));
            for l in e.lines() {
                rows.push(Line::from(Span::styled(format!("    {l}"), dim)));
            }
        }
        TestsState::Done(r) => {
            // Tally line.
            let mut tally: Vec<Span> = vec![Span::styled("  ", body)];
            if r.passed() > 0 {
                tally.push(Span::styled(
                    format!("✓ {} ", r.passed()),
                    Style::default().fg(t.green).bg(t.bg_dark),
                ));
            }
            if r.failed() > 0 {
                tally.push(Span::styled(
                    format!("✗ {} ", r.failed()),
                    Style::default()
                        .fg(t.red)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ));
            }
            if r.flaky() > 0 {
                tally.push(Span::styled(
                    format!("≈ {} ", r.flaky()),
                    Style::default().fg(t.orange).bg(t.bg_dark),
                ));
            }
            if r.skipped() > 0 {
                tally.push(Span::styled(format!("⊘ {} ", r.skipped()), dim));
            }
            let wobbly = history.wobbly_count(r);
            if wobbly > 0 {
                tally.push(Span::styled(
                    format!("≋ {wobbly} "),
                    Style::default().fg(t.purple).bg(t.bg_dark),
                ));
            }
            if r.tests.is_empty() {
                tally.push(Span::styled("(no tests)", dim));
            }
            rows.push(Line::from(tally));
            // render-reviewer N-3 2026-06-28: width-aware help.
            // Long form is ~110 chars; in a 24-cell right panel
            // none of it was visible. Degrades gracefully.
            let help_text = if area.width >= 110 {
                format!(
                    "  ↵ open · t trace · h heal (Claude) · r re-run · a all · f file · R last-failed · s sort [{}] · esc → tree",
                    tp.sort.label(),
                )
            } else if area.width >= 60 {
                format!(
                    "  ↵ open · t trace · r re-run · a all · R last-failed · s [{}]",
                    tp.sort.label(),
                )
            } else if area.width >= 32 {
                "  ↵ open · r re-run · esc".to_string()
            } else {
                "  ↵ open · r run".to_string()
            };
            rows.push(Line::from(Span::styled(help_text, dim)));
            rows.push(Line::from(Span::styled(
                "─".repeat(area.width as usize),
                Style::default().fg(t.line).bg(t.bg_dark),
            )));
            for ge in &r.global_errors {
                rows.push(Line::from(Span::styled(
                    format!("  ! {ge}"),
                    Style::default().fg(t.red).bg(t.bg_dark),
                )));
            }

            let order = tp.sorted_indices(r);
            let group_by_file = tp.sort == TestsSort::FileLine;
            // `test_row` must align with `r.tests` indices, not with the
            // rendered order — the selection is still a raw `r.tests` index.
            test_row.resize(r.tests.len(), 0);
            let mut last_file = String::new();
            for i in &order {
                let i = *i;
                let tc = &r.tests[i];
                if group_by_file && tc.file != last_file {
                    rows.push(Line::from(Span::styled(String::new(), body)));
                    rows.push(Line::from(Span::styled(
                        tc.file.clone(),
                        Style::default()
                            .fg(t.blue)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
                    )));
                    last_file = tc.file.clone();
                }
                let selected = i == tp.selected;
                test_row[i] = rows.len();
                let (glyph_color, name_style) = match tc.status {
                    TestStatus::Passed => (t.green, body),
                    TestStatus::Failed => (t.red, body.add_modifier(Modifier::BOLD)),
                    TestStatus::Flaky => (t.orange, body),
                    TestStatus::Skipped => (t.comment, dim),
                };
                let row_bg = if selected { t.bg2 } else { t.bg_dark };
                let mut spans = vec![
                    Span::styled(
                        if selected { " ▶ " } else { "   " },
                        Style::default().fg(t.yellow).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{} ", tc.status.glyph()),
                        Style::default().fg(glyph_color).bg(row_bg),
                    ),
                ];
                if history.is_wobbly(&tc.file, &tc.suite_path, &tc.title) {
                    spans.push(Span::styled(
                        "≋ ",
                        Style::default()
                            .fg(t.purple)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ));
                }
                if !tc.suite_path.is_empty() {
                    spans.push(Span::styled(
                        format!("{} › ", tc.suite_path),
                        Style::default().fg(t.comment).bg(row_bg),
                    ));
                }
                spans.push(Span::styled(tc.title.clone(), name_style.bg(row_bg)));
                if tc.duration_ms > 0 {
                    spans.push(Span::styled(
                        format!("  {} ms", tc.duration_ms),
                        Style::default().fg(t.comment).bg(row_bg),
                    ));
                }
                // When the file grouping is off (duration sort), show where the
                // test lives — otherwise the file column is implicit in the header.
                if !group_by_file {
                    spans.push(Span::styled(
                        format!("  {}:{}", tc.file, tc.line),
                        Style::default().fg(t.comment).bg(row_bg),
                    ));
                }
                rows.push(Line::from(spans));
                if let Some(err) = &tc.error {
                    for l in err.lines() {
                        rows.push(Line::from(Span::styled(
                            format!("      {l}"),
                            Style::default().fg(t.red).bg(t.bg_dark),
                        )));
                    }
                }
            }
        }
    }

    // Keep the selected test on screen.
    let h = area.height as usize;
    if let TestsState::Done(_) = &tp.state
        && let Some(&target) = test_row.get(tp.selected)
    {
        if target < tp.scroll {
            tp.scroll = target;
        } else if target >= tp.scroll + h {
            tp.scroll = target + 1 - h;
        }
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    tp.scroll = tp.scroll.min(max_scroll);

    // Record per-test row rects so mouse click can select a test.
    // `test_row[i]` is the rendered line number for test index `i`; a
    // value of 0 means "not rendered this pass" (init default) unless
    // it's actually the first row, which it can't be because rows[0]
    // is always the header banner.
    for (i, &line_y) in test_row.iter().enumerate() {
        if line_y == 0 {
            continue; // not rendered
        }
        if line_y < tp.scroll || line_y >= tp.scroll + h {
            continue;
        }
        let visible_y = line_y - tp.scroll;
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
                i,
            ));
        }
    }

    let total_rows = rows.len();
    let scroll = tp.scroll;
    let view: Vec<Line> = rows.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    // render-reviewer 2026-06-28 SEV-2: skip editor_panes when
    // hosted in right panel (same fix as diagnostics_view +
    // grep_view).
    if !app.right_panel_panes.contains(&pane_id) {
        app.rects.editor_panes.push((area, pane_id));
    }
    if sb_w > 0 {
        crate::ui::scrollbar::paint_simple_scrollbar(frame, sb_area, &t, total_rows, h, scroll);
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id,
            total: total_rows,
            viewport: h,
            kind: crate::app::ScrollbarKind::Tests,
        });
    }
    None
}
