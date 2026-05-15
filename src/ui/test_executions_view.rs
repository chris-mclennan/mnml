//! `Pane::TestExecutions` renderer (the private integration build only).
//!
//! Three-column layout per row: env chip · pass/fail/skip/flaky tally ·
//! branch + age. Header banner shows total + a "loading…" chip while the
//! backfill streams in. Selection highlights one row; `↑↓`/`jk` move, `Esc`
//! → tree (wired in tui.rs).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::private::the private integrationEnv;
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
    app.rects.editor_panes.push((area, pane_id));

    let Some(Pane::TestExecutions(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    let n = p.records.len();

    let mut lines: Vec<Line> = Vec::new();

    // ── header ─────────────────────────────────────────────────────
    let mut header_spans = vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⏵ ",
            Style::default()
                .fg(t.teal)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{n} test execution{}", if n == 1 { "" } else { "s" }),
            Style::default()
                .fg(if n > 0 { t.fg } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    if p.loading {
        header_spans.push(Span::styled(
            "  · loading…",
            Style::default().fg(t.comment).bg(t.bg_dark),
        ));
    }
    if let Some(err) = &p.last_error {
        header_spans.push(Span::styled(
            format!("  · err: {err}"),
            Style::default().fg(t.red).bg(t.bg_dark),
        ));
    }
    lines.push(Line::from(header_spans));
    lines.push(Line::from(""));

    // ── rows ───────────────────────────────────────────────────────
    if n == 0 {
        lines.push(Line::from(vec![
            Span::styled("  ", Style::default().bg(t.bg_dark)),
            Span::styled(
                "(no executions yet — phase 4 wires the real DocDB feed)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    }

    // Simple scroll: top of viewport = p.scroll. Selection visible by
    // clamping scroll so `selected` is within [scroll, scroll + body_h).
    let body_h = (area.height as usize).saturating_sub(2);
    if p.selected < p.scroll {
        p.scroll = p.selected;
    }
    if body_h > 0 && p.selected >= p.scroll + body_h {
        p.scroll = p.selected + 1 - body_h;
    }

    for (i, rec) in p.records.iter().enumerate().skip(p.scroll).take(body_h) {
        let selected = i == p.selected;
        let row_bg = if selected { t.bg2 } else { t.bg_dark };

        let env_color = match rec.env {
            the private integrationEnv::Dev => t.green,
            the private integrationEnv::Staging => t.yellow,
            the private integrationEnv::Prod => t.red,
        };
        let env_chip = format!("[{:^7}]", rec.env.label());

        let tally = format!(
            "✓{}  ✗{}  ⊘{}  ≈{}",
            rec.passed, rec.failed, rec.skipped, rec.flaky
        );

        let dur = match rec.duration_ms {
            Some(d) => format_duration(d),
            None => "running…".to_string(),
        };

        lines.push(Line::from(vec![
            Span::styled(" ", Style::default().bg(row_bg)),
            Span::styled(
                env_chip,
                Style::default()
                    .fg(env_color)
                    .bg(row_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("  ", Style::default().bg(row_bg)),
            Span::styled(
                tally,
                Style::default()
                    .fg(if rec.failed > 0 { t.red } else { t.green })
                    .bg(row_bg),
            ),
            Span::styled("  ", Style::default().bg(row_bg)),
            Span::styled(rec.branch.clone(), Style::default().fg(t.fg).bg(row_bg)),
            Span::styled("  ", Style::default().bg(row_bg)),
            Span::styled(dur, Style::default().fg(t.comment).bg(row_bg)),
            Span::styled(" ", Style::default().bg(row_bg)),
        ]));
    }

    frame.render_widget(Paragraph::new(lines), area);
    None
}

fn format_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        format!("{:.1}s", ms as f64 / 1000.0)
    } else {
        let mins = ms / 60_000;
        let secs = (ms % 60_000) / 1000;
        format!("{mins}m{secs:02}s")
    }
}
