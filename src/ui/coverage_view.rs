//! Renderer for `Pane::Coverage` — per-surface Tattle feature-coverage
//! trends. Reads `App::coverage_trends` (populated lazily via
//! `App::ensure_coverage_loaded`). Each row shows: surface name ·
//! features · API sparkline + current% + Δ · UI sparkline + current% + Δ.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::coverage::{AppSeries, braille_sparkline};
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

const DELTA_WINDOW_DAYS: u32 = 7;
const SPARK_WIDTH: usize = 12;

pub fn draw(frame: &mut Frame, app: &mut App, id: PaneId, area: Rect, focused: bool) {
    let t = theme::cur();
    let border_style = if focused {
        Style::default().fg(t.blue)
    } else {
        Style::default().fg(t.bg3)
    };
    // Trigger a lazy load if we don't have data yet.
    app.ensure_coverage_loaded();
    let trends = app.coverage_trends.clone();

    let (title_extra, latest_date) = match &trends {
        Some(f) => (
            format!(" · {} surfaces · latest {}", f.apps.len(), f.latest_date),
            f.latest_date.clone(),
        ),
        None => (
            " · no data — run render_trends.py".to_string(),
            String::new(),
        ),
    };
    let header_text = format!(" Coverage{title_extra} · r refresh · esc close ");
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(header_text);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 40 || inner.height < 4 {
        return;
    }
    app.rects.editor_panes.push((inner, id));

    let Some(trends) = trends else {
        let hint = Paragraph::new(Line::from(vec![Span::styled(
            "  no trends.json at ~/.tattle-claude-artifacts/feature-coverage/_trends/",
            Style::default().fg(t.comment),
        )]));
        let r = Rect {
            x: inner.x,
            y: inner.y + 1,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(hint, r);
        return;
    };

    let overall = trends.overall_current();
    let overall_prev = trends.overall_at(DELTA_WINDOW_DAYS);
    let overall_delta = match (overall, overall_prev) {
        (Some(now), Some(prev)) => Some(now - prev),
        _ => None,
    };

    // Header summary line.
    let mut hdr_spans: Vec<Span> = Vec::new();
    hdr_spans.push(Span::styled(
        "  Overall  ",
        Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
    ));
    if let Some(now) = overall {
        hdr_spans.push(Span::styled(
            format!("{now:.1}%"),
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
        ));
    } else {
        hdr_spans.push(Span::styled("N/A", Style::default().fg(t.comment)));
    }
    if let Some(d) = overall_delta {
        hdr_spans.push(Span::raw("  "));
        hdr_spans.push(delta_span(d, &t));
        hdr_spans.push(Span::styled(
            format!(" vs {DELTA_WINDOW_DAYS}d ago"),
            Style::default().fg(t.comment),
        ));
    }
    if !latest_date.is_empty() {
        hdr_spans.push(Span::styled(
            format!("   refreshed {latest_date}"),
            Style::default().fg(t.comment),
        ));
    }
    let hdr_line = Line::from(hdr_spans);
    frame.render_widget(
        Paragraph::new(hdr_line),
        Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width,
            height: 1,
        },
    );

    // Column layout for per-surface rows. Widths are fixed so
    // on a wide pane the content stays compact on the left instead
    // of spreading edge-to-edge — user reported the spread reads as
    // "weird" at 250+ cols. axis_w picks the smaller of "the room
    // there is" or 32 (enough for the 12-cell sparkline + 5-wide %
    // + delta arrow + small pad).
    let name_w: u16 = 22;
    let axis_ideal: u16 = 28;
    let axis_room = inner.width.saturating_sub(name_w + 4) / 2;
    let axis_w: u16 = axis_ideal.min(axis_room).max(18);
    let total_content_w: u16 = name_w + axis_w * 2 + 4;

    // Sub-header row.
    let sub_y = inner.y + 2;
    if sub_y < inner.y + inner.height {
        let sub = Line::from(vec![
            Span::styled(
                pad_right("  Surface", name_w as usize),
                Style::default().fg(t.comment),
            ),
            Span::styled(
                pad_right("API", axis_w as usize),
                Style::default().fg(t.comment),
            ),
            Span::styled(
                pad_right("UI", axis_w as usize),
                Style::default().fg(t.comment),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(sub),
            Rect {
                x: inner.x,
                y: sub_y,
                width: total_content_w.min(inner.width),
                height: 1,
            },
        );
    }

    // Rows.
    let Some(Pane::Coverage(pane)) = app.panes.get(id) else {
        return;
    };
    let scroll = pane.scroll;
    let first_row_y = inner.y + 4;
    let visible = inner.height.saturating_sub(4);
    // 2 lines per row: text + 1-line breather. User feedback:
    // "maybe not let them get too far apart" — vertical padding
    // reads more calmly than tight rows.
    const ROW_STRIDE: u16 = 2;
    let max_rows = (visible / ROW_STRIDE) as usize;
    for (i, surface) in trends.apps.iter().skip(scroll).take(max_rows).enumerate() {
        let row_y = first_row_y + (i as u16) * ROW_STRIDE;
        if row_y >= inner.y + inner.height {
            break;
        }
        let (api_span_group, ui_span_group) = axis_spans(surface, &t, axis_w as usize);
        let line = Line::from(
            [
                vec![Span::styled(
                    pad_right(&format!("  {}", surface.name), name_w as usize),
                    Style::default().fg(t.fg),
                )],
                api_span_group,
                ui_span_group,
            ]
            .concat(),
        );
        frame.render_widget(
            Paragraph::new(line),
            Rect {
                x: inner.x,
                y: row_y,
                width: total_content_w.min(inner.width),
                height: 1,
            },
        );
    }
}

fn axis_spans<'a>(
    surface: &'a AppSeries,
    t: &'a theme::Theme,
    total_w: usize,
) -> (Vec<Span<'a>>, Vec<Span<'a>>) {
    let api_series: Vec<Option<f64>> = surface.series.iter().map(|p| p.api).collect();
    let ui_series: Vec<Option<f64>> = surface.series.iter().map(|p| p.ui).collect();
    let api_latest = surface.latest().and_then(|p| p.api);
    let ui_latest = surface.latest().and_then(|p| p.ui);
    let api_prev = surface
        .point_n_days_ago(DELTA_WINDOW_DAYS)
        .and_then(|p| p.api);
    let ui_prev = surface
        .point_n_days_ago(DELTA_WINDOW_DAYS)
        .and_then(|p| p.ui);
    (
        one_axis_spans(&api_series, api_latest, api_prev, t, total_w),
        one_axis_spans(&ui_series, ui_latest, ui_prev, t, total_w),
    )
}

fn one_axis_spans<'a>(
    series: &[Option<f64>],
    latest: Option<f64>,
    prev: Option<f64>,
    t: &'a theme::Theme,
    total_w: usize,
) -> Vec<Span<'a>> {
    if latest.is_none() {
        return vec![Span::styled(
            pad_right("  N/A", total_w),
            Style::default().fg(t.comment),
        )];
    }
    let spark = braille_sparkline(series, SPARK_WIDTH);
    let now = latest.unwrap();
    let delta = prev.map(|p| now - p);
    let value_str = format!("{now:5.1}%");
    let delta_str = delta
        .map(|d| format!(" {}", delta_glyph(d)))
        .unwrap_or_default();
    let content = format!("  {spark}  {value_str}{delta_str}");
    let mut spans = vec![Span::styled(
        content.clone(),
        Style::default().fg(delta_color(delta, t)),
    )];
    // pad to total_w
    let used = content.chars().count();
    if used < total_w {
        spans.push(Span::raw(" ".repeat(total_w - used)));
    }
    spans
}

fn delta_span(d: f64, t: &theme::Theme) -> Span<'_> {
    Span::styled(
        format!("{} {:.1}pp", delta_glyph(d), d.abs()),
        Style::default().fg(delta_color(Some(d), t)),
    )
}

fn delta_glyph(d: f64) -> &'static str {
    if d.abs() < 0.05 {
        "±"
    } else if d > 0.0 {
        "▲"
    } else {
        "▼"
    }
}

fn delta_color(d: Option<f64>, t: &theme::Theme) -> ratatui::style::Color {
    match d {
        None => t.comment,
        Some(v) if v.abs() < 0.05 => t.comment,
        Some(v) if v > 0.0 => t.green,
        Some(_) => t.red,
    }
}

fn pad_right(s: &str, w: usize) -> String {
    let count = s.chars().count();
    if count >= w {
        s.to_string()
    } else {
        format!("{s}{}", " ".repeat(w - count))
    }
}
