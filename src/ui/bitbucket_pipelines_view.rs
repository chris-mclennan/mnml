//! `Pane::BitbucketPipelines` renderer. Flat list grouped by repo:
//!
//! ```text
//!  ⌥ 24 pipelines · polling every 30s · (r refresh · Enter open · y copy url · Esc tree)
//!
//!  ▸ exampleorg/example-api
//!  ✓  #4521  main             5m02s   2m ago    Chris McLennan       PUSH
//!  ⏵  #4522  feature/login    —       just now  Tal Doron            PUSH
//!  ✗  #4520  develop          1m38s   15m ago   Pipelines (bot)      SCHEDULE
//!
//!  ▸ exampleorg/private-playwright
//!  ✓  #312   main             8m15s   1h ago    Chris McLennan       PUSH
//! ```
//!
//! Reads from `App.bitbucket_pipelines` (the per-tick-updated cache) at
//! render time — no per-pane data store. The flatten order follows
//! `App.config.bitbucket.repos` so the user's config-file order is what
//! they see.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::bitbucket::{PipelineRecord, PipelineState};
use crate::layout::PaneId;
use crate::pane::Pane;
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

    // Flatten before borrowing the pane — keeps the borrow scope clean.
    let flat = flatten_pipelines(app);
    let total_pipelines = flat.iter().filter(|r| r.kind == RowKind::Pipeline).count();
    let loading = !app.bitbucket_connected && app.bitbucket_pipelines.is_empty();
    let last_error = app.bitbucket_last_error.clone();
    let poll_secs = app.config.bitbucket.poll_secs_or_default();
    let configured = app.config.bitbucket.any_configured();

    let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();

    // ── header banner ─────────────────────────────────────────────
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⌥ ",
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "{total_pipelines} pipeline{}",
                if total_pipelines == 1 { "" } else { "s" }
            ),
            Style::default()
                .fg(if total_pipelines > 0 { t.fg } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" · polling every {poll_secs}s"),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ];
    if loading {
        header.push(Span::styled(
            "  · loading…",
            Style::default().fg(t.yellow).bg(t.bg_dark),
        ));
    }
    if let Some(err) = &last_error {
        header.push(Span::styled(
            format!("  · err: {err}"),
            Style::default().fg(t.red).bg(t.bg_dark),
        ));
    }
    header.push(Span::styled(
        "    (r refresh · Enter open · y copy url · Esc tree)",
        Style::default().fg(t.comment).bg(t.bg_dark),
    ));
    lines.push(Line::from(header));
    lines.push(Line::from(""));

    // ── empty / configure hints ───────────────────────────────────
    if !configured {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "Add a [[bitbucket.repos]] entry to ~/.config/mnml/config.toml \
                 and export $BITBUCKET_TOKEN to start polling.",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    } else if total_pipelines == 0 && !loading && last_error.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no pipelines yet — waiting for the first poll to land)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    }

    // ── selection clamp + scroll ──────────────────────────────────
    let n = flat.len();
    if n > 0 && p.selected >= n {
        p.selected = n - 1;
    }
    // The selection cursor should land on data rows only — skip headers.
    snap_selection_to_data(p, &flat);

    let body_h = (area.height as usize).saturating_sub(2);
    if body_h > 0 && n > 0 {
        if p.selected < p.scroll {
            p.scroll = p.selected;
        }
        if p.selected >= p.scroll + body_h {
            p.scroll = p.selected + 1 - body_h;
        }
    }

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    for (i, row) in flat.iter().enumerate().skip(p.scroll).take(body_h) {
        match row.kind {
            RowKind::Header => {
                lines.push(Line::from(vec![
                    Span::raw(" "),
                    Span::styled(
                        "▸ ",
                        Style::default()
                            .fg(t.purple)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        row.header_label.clone(),
                        Style::default()
                            .fg(t.purple)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        format!("  ({})", row.repo_count),
                        Style::default().fg(t.comment).bg(t.bg_dark),
                    ),
                ]));
            }
            RowKind::Pipeline => {
                let pipe = row.pipeline.as_ref().expect("pipeline row carries record");
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };

                let (glyph, status_color) = match pipe.state {
                    PipelineState::Successful => (pipe.state.glyph(), t.green),
                    PipelineState::Failed | PipelineState::Error => (pipe.state.glyph(), t.red),
                    PipelineState::InProgress => (pipe.state.glyph(), t.yellow),
                    PipelineState::Pending | PipelineState::Paused => {
                        (pipe.state.glyph(), t.cyan)
                    }
                    PipelineState::Stopped | PipelineState::Halted | PipelineState::Expired => {
                        (pipe.state.glyph(), t.comment)
                    }
                    PipelineState::Unknown => (pipe.state.glyph(), t.fg),
                };

                let build_num = if pipe.build_number > 0 {
                    format!("#{}", pipe.build_number)
                } else {
                    "#?".to_string()
                };
                let target = truncate(
                    pipe.target_ref.as_deref().unwrap_or("(no ref)"),
                    16,
                );
                let dur = pipe
                    .duration_secs
                    .map(format_duration_secs)
                    .unwrap_or_else(|| "—".to_string());
                let age = pipe
                    .created_on_ms
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();
                let creator = truncate(pipe.creator.as_deref().unwrap_or(""), 22);
                let trigger = pipe.trigger.as_deref().unwrap_or("");

                lines.push(Line::from(vec![
                    Span::styled(" ", Style::default().bg(row_bg)),
                    Span::styled(
                        format!("{glyph}  "),
                        Style::default()
                            .fg(status_color)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        format!("{build_num:<7}"),
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{target:<17}"),
                        Style::default().fg(t.cyan).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{dur:>7}  "),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{age:<10}  "),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{creator:<24}"),
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                    Span::styled(
                        trigger.to_string(),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ]));
            }
        }
    }

    frame.render_widget(Paragraph::new(lines), area);
    None
}

// ─── Flattening (header rows + pipeline rows) ──────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Header,
    Pipeline,
}

#[derive(Debug, Clone)]
pub struct FlatRow {
    pub kind: RowKind,
    pub header_label: String,
    pub repo_count: usize,
    pub pipeline: Option<PipelineRecord>,
}

/// Walk the configured repos in config order; emit a `Header` row for each
/// repo that has at least one pipeline (or for which we have no cache yet —
/// so the user sees the repo listed even before its first poll), followed
/// by `Pipeline` rows for that repo's cached pipelines.
pub fn flatten_pipelines(app: &App) -> Vec<FlatRow> {
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.bitbucket.repos {
        let key = (repo.workspace.clone(), repo.slug.clone());
        let pipelines = app.bitbucket_pipelines.get(&key);
        let count = pipelines.map(|v| v.len()).unwrap_or(0);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label: format!("{}/{}", repo.workspace, repo.slug),
            repo_count: count,
            pipeline: None,
        });
        if let Some(v) = pipelines {
            for rec in v {
                out.push(FlatRow {
                    kind: RowKind::Pipeline,
                    header_label: String::new(),
                    repo_count: 0,
                    pipeline: Some(rec.clone()),
                });
            }
        }
    }
    out
}

/// Resolve the selected index to a `PipelineRecord`, skipping over header
/// rows. Used by the `Enter` / `y` key handlers in tui.rs.
pub fn selected_pipeline(app: &App, pane: &crate::bitbucket::BitbucketPipelinesPane) -> Option<PipelineRecord> {
    let flat = flatten_pipelines(app);
    flat.get(pane.selected)
        .and_then(|r| r.pipeline.clone())
}

/// Skip past header rows so j/k feel right (vim convention — don't park
/// the cursor on a heading row). Picks the nearest data row in the
/// direction of last travel (we don't track direction yet, so go forward
/// then back).
fn snap_selection_to_data(pane: &mut crate::bitbucket::BitbucketPipelinesPane, flat: &[FlatRow]) {
    if flat.is_empty() {
        return;
    }
    if flat
        .get(pane.selected)
        .map(|r| r.kind == RowKind::Pipeline)
        .unwrap_or(false)
    {
        return;
    }
    // Search forward, then back.
    for (i, row) in flat.iter().enumerate().skip(pane.selected) {
        if row.kind == RowKind::Pipeline {
            pane.selected = i;
            return;
        }
    }
    for (i, row) in flat.iter().enumerate().take(pane.selected).rev() {
        if row.kind == RowKind::Pipeline {
            pane.selected = i;
            return;
        }
    }
}

// ─── Small renderer helpers ────────────────────────────────────────────

fn humanize_age(ms: i64) -> String {
    let s = ms / 1000;
    if s < 30 {
        "just now".to_string()
    } else if s < 60 {
        format!("{s}s ago")
    } else if s < 3600 {
        format!("{}m ago", s / 60)
    } else if s < 86_400 {
        format!("{}h ago", s / 3600)
    } else {
        format!("{}d ago", s / 86_400)
    }
}

fn format_duration_secs(secs: u64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        let m = secs / 60;
        let s = secs % 60;
        format!("{m}m{s:02}s")
    } else {
        let h = secs / 3600;
        let m = (secs % 3600) / 60;
        format!("{h}h{m:02}m")
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
        assert_eq!(humanize_age(5_000), "just now");
        assert_eq!(humanize_age(45_000), "45s ago");
        assert_eq!(humanize_age(120_000), "2m ago");
        assert_eq!(humanize_age(3_700_000), "1h ago");
        assert_eq!(humanize_age(90_000_000), "1d ago");
    }

    #[test]
    fn format_duration_secs_buckets() {
        assert_eq!(format_duration_secs(45), "45s");
        assert_eq!(format_duration_secs(302), "5m02s");
        assert_eq!(format_duration_secs(3725), "1h02m");
    }

    #[test]
    fn truncate_short_returns_input() {
        assert_eq!(truncate("hi", 10), "hi");
    }

    #[test]
    fn truncate_long_adds_ellipsis() {
        assert_eq!(truncate("0123456789ab", 8), "0123456…");
    }

    #[test]
    fn snap_selection_walks_forward_to_first_data_row() {
        let flat = vec![
            FlatRow {
                kind: RowKind::Header,
                header_label: "h0".into(),
                repo_count: 0,
                pipeline: None,
            },
            FlatRow {
                kind: RowKind::Pipeline,
                header_label: String::new(),
                repo_count: 0,
                pipeline: None,
            },
        ];
        let mut p = crate::bitbucket::BitbucketPipelinesPane::new();
        p.selected = 0;
        snap_selection_to_data(&mut p, &flat);
        assert_eq!(p.selected, 1);
    }

    #[test]
    fn snap_selection_walks_back_when_only_earlier_data_rows() {
        let flat = vec![
            FlatRow {
                kind: RowKind::Pipeline,
                header_label: String::new(),
                repo_count: 0,
                pipeline: None,
            },
            FlatRow {
                kind: RowKind::Header,
                header_label: "h".into(),
                repo_count: 0,
                pipeline: None,
            },
        ];
        let mut p = crate::bitbucket::BitbucketPipelinesPane::new();
        p.selected = 1;
        snap_selection_to_data(&mut p, &flat);
        assert_eq!(p.selected, 0);
    }
}
