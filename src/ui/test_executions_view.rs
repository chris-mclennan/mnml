//! `Pane::TestExecutions` renderer (the private integration build only) — phase 5
//! side-by-side env columns.
//!
//! Layout: a one-line top banner (total · loading? · error?), then three
//! equal-width columns (dev | staging | prod) separated by single-cell
//! divider columns. Each column shows its env's records newest-first as
//! a two-line block (tally + branch/age). Active column header is bold
//! + tinted in the env color; inactive columns dim.
//!
//! Key dispatch lives in `tui.rs`: `↑`/`↓`/`k`/`j` move within the
//! active column, `←`/`→`/`h`/`l` cycle the active column.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::private::the private integrationEnv;
use crate::ui::theme::{self, Theme};

/// Sentinel `row_in_env_filter` value recorded for column headers. The mouse
/// handler interprets this as "click changes the active env but doesn't
/// select a record."
pub const HEADER_ROW_SENTINEL: usize = usize::MAX;

/// Map a `the private integrationEnv` to the 0/1/2 index used in `app.rects.test_executions_rows`.
pub fn env_to_idx(env: the private integrationEnv) -> u8 {
    match env {
        the private integrationEnv::Dev => 0,
        the private integrationEnv::Staging => 1,
        the private integrationEnv::Prod => 2,
    }
}

/// Inverse of `env_to_idx` — the mouse handler in `tui.rs` calls this.
pub fn idx_to_env(idx: u8) -> Option<the private integrationEnv> {
    match idx {
        0 => Some(the private integrationEnv::Dev),
        1 => Some(the private integrationEnv::Staging),
        2 => Some(the private integrationEnv::Prod),
        _ => None,
    }
}

/// Two visible text rows per record (tally + branch/age).
const ROWS_PER_RECORD: usize = 2;

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

    // ── header banner ─────────────────────────────────────────────
    let total = p.records.len();
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⏵ ",
            Style::default()
                .fg(t.teal)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{total} execution{}", if total == 1 { "" } else { "s" }),
            Style::default()
                .fg(if total > 0 { t.fg } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    if p.loading {
        header.push(Span::styled(
            "  · loading…",
            Style::default().fg(t.comment).bg(t.bg_dark),
        ));
    }
    if let Some(err) = &p.last_error {
        header.push(Span::styled(
            format!("  · err: {err}"),
            Style::default().fg(t.red).bg(t.bg_dark),
        ));
    }
    header.push(Span::styled(
        "    (←/→ change env · ↑/↓ row)",
        Style::default().fg(t.comment).bg(t.bg_dark),
    ));
    let header_area = Rect { height: 1, ..area };
    frame.render_widget(Paragraph::new(Line::from(header)), header_area);

    // ── three columns + dividers ──────────────────────────────────
    if area.height < 3 {
        return None;
    }
    let body_h = area.height as usize - 2; // top banner + spacing row
    let body_y = area.y + 2;
    let envs = [the private integrationEnv::Dev, the private integrationEnv::Staging, the private integrationEnv::Prod];

    // Width per column. Reserve 2 cells for dividers (one between dev/staging
    // and one between staging/prod). Each column gets the remainder / 3.
    let inner_w = area.width.saturating_sub(2);
    let col_w = inner_w / 3;
    if col_w < 8 {
        // Pane too narrow for three columns — degenerate gracefully.
        frame.render_widget(
            Paragraph::new("(pane too narrow)").style(Style::default().fg(t.comment).bg(t.bg_dark)),
            Rect {
                x: area.x,
                y: body_y,
                width: area.width,
                height: 1,
            },
        );
        return None;
    }
    let leftover = inner_w - col_w * 3;
    let mut x = area.x;
    let active = p.selected_env;

    // Collect row rects as draw_column runs; push to app.rects after the
    // borrow on `p` releases.
    let mut row_rects: Vec<(Rect, u8, usize)> = Vec::new();
    for (i, &env) in envs.iter().enumerate() {
        // First column gets any leftover from integer division.
        let w = col_w + if i == 0 { leftover } else { 0 };
        let col_rect = Rect {
            x,
            y: body_y,
            width: w,
            height: body_h as u16,
        };
        p.clamp_scroll(env, body_h.saturating_sub(1), ROWS_PER_RECORD);
        draw_column(frame, p, env, env == active, col_rect, &t, &mut row_rects);
        x += w;
        if i < 2 {
            // Vertical divider.
            let div_rect = Rect {
                x,
                y: body_y,
                width: 1,
                height: body_h as u16,
            };
            frame.render_widget(
                Paragraph::new("│").style(Style::default().fg(t.bg2).bg(t.bg_dark)),
                div_rect,
            );
            x += 1;
        }
    }
    for (rect, env_idx, row_idx) in row_rects {
        app.rects
            .test_executions_rows
            .push((rect, pane_id, env_idx, row_idx));
    }
    None
}

fn draw_column(
    frame: &mut Frame,
    p: &super::super::private::private_executions_pane::TestExecutionsPane,
    env: the private integrationEnv,
    is_active: bool,
    area: Rect,
    t: &Theme,
    row_rects: &mut Vec<(Rect, u8, usize)>,
) {
    let env_color = match env {
        the private integrationEnv::Dev => t.green,
        the private integrationEnv::Staging => t.yellow,
        the private integrationEnv::Prod => t.red,
    };
    let records = p.records_for(env);
    let scroll = p.scroll_for(env);
    let selected_row = p.selected_row_in(env);

    let mut lines: Vec<Line> = Vec::new();

    // Column header.
    let header_style = if is_active {
        Style::default()
            .fg(env_color)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD | Modifier::UNDERLINED)
    } else {
        Style::default().fg(t.comment).bg(t.bg_dark)
    };
    let arrow = if is_active { "▶ " } else { "  " };
    lines.push(Line::from(vec![
        Span::styled(arrow, Style::default().fg(env_color).bg(t.bg_dark)),
        Span::styled(
            format!("{}  ({})", env.label().to_uppercase(), records.len()),
            header_style,
        ),
    ]));
    // Record the column-header rect so a click on it just flips the active env.
    let header_rect = Rect {
        x: area.x,
        y: area.y,
        width: area.width,
        height: 1,
    };
    row_rects.push((header_rect, env_to_idx(env), HEADER_ROW_SENTINEL));

    if records.is_empty() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no runs)",
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::ITALIC),
            ),
        ]));
    } else {
        let records_visible = (area.height as usize).saturating_sub(1) / ROWS_PER_RECORD;
        let env_idx = env_to_idx(env);
        for (idx_in_view, rec) in records
            .iter()
            .enumerate()
            .skip(scroll)
            .take(records_visible)
        {
            let i = idx_in_view; // absolute index in records_for(env)
            let selected = is_active && i == selected_row;
            let row_bg = if selected { t.bg2 } else { t.bg_dark };

            let tally = format!(
                "✓{}  ✗{}  ⊘{}  ≈{}",
                rec.passed, rec.failed, rec.skipped, rec.flaky
            );
            let dur = match rec.duration_ms {
                Some(d) => format_duration(d),
                None => "running…".to_string(),
            };

            // The record block is 2 rows starting at this on-screen Y.
            // Each rendered logical row inside the column = `lines.len() - 1`
            // (the header is at index 0). We're about to push 2 more lines,
            // so the row block starts at `area.y + lines.len()` and ends at
            // `area.y + lines.len() + ROWS_PER_RECORD - 1`.
            let row_y = area.y + lines.len() as u16;
            row_rects.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: ROWS_PER_RECORD as u16,
                },
                env_idx,
                i,
            ));
            lines.push(Line::from(vec![
                Span::styled(" ", Style::default().bg(row_bg)),
                Span::styled(
                    tally,
                    Style::default()
                        .fg(if rec.failed > 0 { t.red } else { t.green })
                        .bg(row_bg),
                ),
                Span::styled("  ", Style::default().bg(row_bg)),
                Span::styled(
                    truncate(&rec.branch, area.width.saturating_sub(20) as usize),
                    Style::default().fg(t.fg).bg(row_bg),
                ),
            ]));
            lines.push(Line::from(vec![
                Span::styled(" ", Style::default().bg(row_bg)),
                Span::styled(
                    format!("  {}", dur),
                    Style::default().fg(t.comment).bg(row_bg),
                ),
            ]));
        }
    }

    frame.render_widget(Paragraph::new(lines), area);
}

fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let head_len = max_chars.saturating_sub(1);
    let mut out: String = s.chars().take(head_len).collect();
    out.push('…');
    out
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
