//! `Pane::CodeBuilds` renderer (`aws-codebuild` feature). One row per
//! build: status glyph (colored by status) · build number · short SHA ·
//! branch · duration · age · initiator. Header banner with
//! loading/error chips.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::aws::codebuild::BuildStatus;
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

    // Extract everything we need from the pane up front, then drop the
    // mut borrow so `app.match_test_executions_for_build` (immut) can run.
    let (items_window, p_selected, items_count, loading, last_error_msg) = {
        let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(pane_id) else {
            return None;
        };
        let body_h = (area.height as usize).saturating_sub(2);
        if body_h > 0 {
            if p.selected < p.scroll {
                p.scroll = p.selected;
            }
            if p.selected >= p.scroll + body_h {
                p.scroll = p.selected + 1 - body_h;
            }
        }
        let items_window: Vec<(usize, crate::aws::codebuild::CodeBuildRecord)> = p
            .items
            .iter()
            .enumerate()
            .skip(p.scroll)
            .take(body_h)
            .map(|(i, r)| (i, r.clone()))
            .collect();
        (
            items_window,
            p.selected,
            p.items.len(),
            p.loading,
            p.last_error.clone(),
        )
    };

    // Per-build test-execution stat tuples — left as Nones in the lean
    // build (mnml has no test-results data source of its own). A future
    // blit-host integration (or a Cargo feature that provides its own
    // correlator) can fill these in by re-introducing the lookup.
    let stats_per_visible: Vec<Option<(u32, u32, u32, u32)>> =
        items_window.iter().map(|_| None).collect();

    let n = items_count;
    let mut lines: Vec<Line> = Vec::new();

    // ── header banner ─────────────────────────────────────────────
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⚒ ",
            Style::default()
                .fg(t.orange)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{n} build{}", if n == 1 { "" } else { "s" }),
            Style::default()
                .fg(if n > 0 { t.fg } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    if loading {
        header.push(Span::styled(
            "  · loading…",
            Style::default().fg(t.comment).bg(t.bg_dark),
        ));
    }
    if let Some(err) = &last_error_msg {
        header.push(Span::styled(
            format!("  · err: {err}"),
            Style::default().fg(t.red).bg(t.bg_dark),
        ));
    }
    header.push(Span::styled(
        "    (r refresh · Enter open · y copy url · t/T tail · x jump to TE · Esc tree)",
        Style::default().fg(t.comment).bg(t.bg_dark),
    ));
    lines.push(Line::from(header));
    lines.push(Line::from(""));

    if n == 0 && !loading && last_error_msg.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no builds yet — press `r` to refresh)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    }

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    for (visible_i, ((i, rec), stats)) in items_window
        .iter()
        .zip(stats_per_visible.iter())
        .enumerate()
    {
        let row_y = area.y.saturating_add(2 + visible_i as u16);
        if row_y < area.y.saturating_add(area.height) {
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                *i,
            ));
        }
        let selected = *i == p_selected;
        let row_bg = if selected { t.bg2 } else { t.bg_dark };
        let (glyph, status_color) = match rec.status {
            BuildStatus::Succeeded => (rec.status.glyph(), t.green),
            BuildStatus::Failed | BuildStatus::Fault | BuildStatus::TimedOut => {
                (rec.status.glyph(), t.red)
            }
            BuildStatus::InProgress => (rec.status.glyph(), t.yellow),
            BuildStatus::Stopped => (rec.status.glyph(), t.comment),
            BuildStatus::Unknown => (rec.status.glyph(), t.fg),
        };

        let build_num = if rec.build_number > 0 {
            format!("#{}", rec.build_number)
        } else {
            "#?".to_string()
        };

        let sha = rec
            .source_version
            .as_deref()
            .filter(|s| !s.starts_with("arn:"))
            .map(|s| {
                if s.len() >= 8 && s.chars().all(|c| c.is_ascii_hexdigit()) {
                    s[..8].to_string()
                } else {
                    truncate(s, 24)
                }
            })
            .unwrap_or_default();

        let dur = rec.duration_ms.map(format_duration).unwrap_or_default();
        let age = rec
            .started_at_ms
            .map(|t| humanize_age((now_ms - t).max(0)))
            .unwrap_or_default();
        let initiator = rec
            .initiator
            .as_deref()
            .map(|s| truncate(s, 28))
            .unwrap_or_default();

        let mut spans = vec![
            Span::styled(" ", Style::default().bg(row_bg)),
            Span::styled(
                format!("{glyph}  "),
                Style::default()
                    .fg(status_color)
                    .bg(row_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{build_num:<8}"),
                Style::default().fg(t.fg).bg(row_bg),
            ),
            Span::styled(
                format!("{sha:<10}"),
                Style::default().fg(t.purple).bg(row_bg),
            ),
            Span::styled(
                format!("{dur:>8}  "),
                Style::default().fg(t.comment).bg(row_bg),
            ),
            Span::styled(
                format!("{age:<10}  "),
                Style::default().fg(t.comment).bg(row_bg),
            ),
            Span::styled(initiator, Style::default().fg(t.fg).bg(row_bg)),
        ];
        // Phase 8: append per-build test-execution chip when one matches.
        if let Some((passed, failed, skipped, flaky)) = stats {
            spans.push(Span::styled(
                "  · ",
                Style::default().fg(t.comment).bg(row_bg),
            ));
            spans.push(Span::styled(
                format!("✓{passed}"),
                Style::default().fg(t.green).bg(row_bg),
            ));
            if *failed > 0 {
                spans.push(Span::styled(
                    format!(" ✗{failed}"),
                    Style::default().fg(t.red).bg(row_bg),
                ));
            }
            if *flaky > 0 {
                spans.push(Span::styled(
                    format!(" ≈{flaky}"),
                    Style::default().fg(t.purple).bg(row_bg),
                ));
            }
            if *skipped > 0 {
                spans.push(Span::styled(
                    format!(" ⊘{skipped}"),
                    Style::default().fg(t.comment).bg(row_bg),
                ));
            }
        }
        lines.push(Line::from(spans));
    }

    frame.render_widget(Paragraph::new(lines), area);
    None
}

fn humanize_age(ms: i64) -> String {
    let s = ms / 1000;
    if s < 60 {
        format!("{s}s ago")
    } else if s < 3600 {
        format!("{}m ago", s / 60)
    } else if s < 86_400 {
        format!("{}h ago", s / 3600)
    } else {
        format!("{}d ago", s / 86_400)
    }
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

fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn humanize_age_buckets() {
        assert_eq!(humanize_age(5_000), "5s ago");
        assert_eq!(humanize_age(120_000), "2m ago");
        assert_eq!(humanize_age(3_700_000), "1h ago");
        assert_eq!(humanize_age(90_000_000), "1d ago");
    }
}
