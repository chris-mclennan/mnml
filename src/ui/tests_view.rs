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
use crate::playwright::{TestStatus, TestsState};
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
                "  ⟳ running…",
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
            if r.tests.is_empty() {
                tally.push(Span::styled("(no tests)", dim));
            }
            rows.push(Line::from(tally));
            rows.push(Line::from(Span::styled(
                "  ↵ open · t trace · ↑↓ select · h heal (Claude) · r re-run · a all · f file · R last-failed · esc → tree",
                dim,
            )));
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

            let mut last_file = String::new();
            for (i, tc) in r.tests.iter().enumerate() {
                if tc.file != last_file {
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
                test_row.push(rows.len());
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
    let view: Vec<Line> = rows.into_iter().skip(tp.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));
    None
}
