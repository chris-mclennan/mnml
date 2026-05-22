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

// Same Nerd Font chevrons the file tree uses — `f107` is angle-down
// (expanded), `f105` is angle-right (collapsed). Falls back to the
// Unicode triangles when `[ui] ascii_icons = true` so non-Nerd-Font
// terminals still show a sensible glyph.
const CHEVRON_OPEN_NERD: &str = "\u{f107}";
const CHEVRON_CLOSED_NERD: &str = "\u{f105}";
const CHEVRON_OPEN_ASCII: &str = "▾";
const CHEVRON_CLOSED_ASCII: &str = "▸";

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

    // Pick the active view's flatten function up front. The pane's
    // view_mode is on App, but flatten functions take &App — read the
    // mode via a short borrow before pivoting.
    let mode = app.bb_pipelines_view_mode;
    let collapsed_set = app.bb_pipelines_collapsed.clone();
    let flat = match mode {
        crate::bitbucket::PipelineViewMode::Recent => flatten_pipelines(app),
        crate::bitbucket::PipelineViewMode::PerBranch => flatten_branch_pipelines(app),
    };
    let total_pipelines = flat.iter().filter(|r| r.kind == RowKind::Pipeline).count();
    let cache_empty = match mode {
        crate::bitbucket::PipelineViewMode::Recent => app.bitbucket_pipelines.is_empty(),
        crate::bitbucket::PipelineViewMode::PerBranch => app.bitbucket_branch_pipelines.is_empty(),
    };
    let loading = !app.bitbucket_connected && cache_empty;
    let last_error = app.bitbucket_last_error.clone();
    let poll_secs = app.config.bitbucket.poll_secs_or_default();
    let configured = app.config.bitbucket.any_configured();
    let nerd = !app.config.ui.ascii_icons;

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
            format!(" · view: {} (v to flip)", mode.label()),
            Style::default()
                .fg(t.yellow)
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
    // Headers are now selectable (Enter toggles their collapse state).
    // No auto-snap-to-data — let users navigate every row.

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

    // Auto-fit the branch/ref column. Other columns are fixed width:
    // indent 4 · glyph 3 · #N 7 · dur 9 · age 12 · creator 24 ·
    // trigger 10 = 69 fixed. Long refs like `PR #4545 TE-13216-…` now
    // stretch into the spare horizontal real estate instead of being
    // chopped at 17.
    let ref_w = (area.width as usize).saturating_sub(69).clamp(15, 80);

    // Per-row screen position so mouse clicks can map back to a flat
    // row index. lines.len() is the y-offset where the *next* line
    // lands inside `area`.
    let body_start_offset = lines.len() as u16;
    for (visible_i, (i, row)) in flat
        .iter()
        .enumerate()
        .skip(p.scroll)
        .take(body_h)
        .enumerate()
    {
        let row_y = area.y.saturating_add(body_start_offset + visible_i as u16);
        if row_y < area.y.saturating_add(area.height) {
            let row_rect = ratatui::layout::Rect {
                x: area.x,
                y: row_y,
                width: area.width,
                height: 1,
            };
            app.rects.list_rows.push((row_rect, pane_id, i));
        }
        match row.kind {
            RowKind::Header => {
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };
                let collapsed = collapsed_set.contains(&row.header_label);
                let arrow = match (collapsed, nerd) {
                    (true, true) => format!("{CHEVRON_CLOSED_NERD} "),
                    (false, true) => format!("{CHEVRON_OPEN_NERD} "),
                    (true, false) => format!("{CHEVRON_CLOSED_ASCII} "),
                    (false, false) => format!("{CHEVRON_OPEN_ASCII} "),
                };
                // Tree-style: 2-space indent, arrow, label. Not bold —
                // matches user preference. Purple instead of the tree's
                // blue keeps the SCM pane visually distinguishable.
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default().bg(row_bg)),
                    Span::styled(arrow, Style::default().fg(t.purple).bg(row_bg)),
                    Span::styled(
                        row.header_label.clone(),
                        Style::default().fg(t.purple).bg(row_bg),
                    ),
                    Span::styled(
                        format!("  ({})", row.repo_count),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ]));
            }
            RowKind::Pipeline => {
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };

                // PerBranch rows always carry a branch_label; if the
                // pipeline is None we render a "never run" placeholder
                // row using just the branch label.
                let Some(pipe) = row.pipeline.as_ref() else {
                    let branch = row.branch_label.as_deref().unwrap_or("?");
                    lines.push(Line::from(vec![
                        Span::styled("    ", Style::default().bg(row_bg)),
                        Span::styled("·  ", Style::default().fg(t.comment).bg(row_bg)),
                        Span::styled(
                            format!("{:<7}", "—"),
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                        Span::styled(
                            format!("{branch:<17}"),
                            Style::default().fg(t.cyan).bg(row_bg),
                        ),
                        Span::styled(
                            "(no pipeline runs yet)",
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                    ]));
                    continue;
                };

                let (glyph, status_color) = match pipe.state {
                    PipelineState::Successful => (pipe.state.glyph(), t.green),
                    PipelineState::Failed | PipelineState::Error => (pipe.state.glyph(), t.red),
                    PipelineState::InProgress => (pipe.state.glyph(), t.yellow),
                    PipelineState::Pending | PipelineState::Paused => (pipe.state.glyph(), t.cyan),
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
                // In PerBranch mode prefer the row's branch_label (canonical
                // — that's the branch we *asked* about). In Recent mode use
                // the pipeline's target_ref. Either way, truncate to 16.
                let ref_text = row
                    .branch_label
                    .as_deref()
                    .or(pipe.target_ref.as_deref())
                    .unwrap_or("(no ref)");
                let target = truncate(ref_text, ref_w.saturating_sub(1));
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

                // In-progress pipelines: show the running step name
                // instead of (or alongside) the trigger. James's bbwatch
                // shows `▶ <step>` in the RESULT column.
                let step_or_trigger = match (pipe.state, &pipe.running_step) {
                    (PipelineState::InProgress, Some(step)) => {
                        format!("▶ {step}")
                    }
                    _ => trigger.to_string(),
                };

                lines.push(Line::from(vec![
                    Span::styled("    ", Style::default().bg(row_bg)),
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
                        format!("{target:<width$}", width = ref_w),
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
                    Span::styled(step_or_trigger, Style::default().fg(t.comment).bg(row_bg)),
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
    /// Set on PerBranch data rows — the branch this row represents.
    /// May be `Some` with `pipeline = None` when an explicitly-configured
    /// branch has no pipelines yet (so the user can see it's tracked).
    pub branch_label: Option<String>,
}

/// Walk the configured repos in config order; emit a `Header` row for each
/// repo that has at least one pipeline (or for which we have no cache yet —
/// so the user sees the repo listed even before its first poll), followed
/// by `Pipeline` rows for that repo's cached pipelines.
pub fn flatten_pipelines(app: &App) -> Vec<FlatRow> {
    let pane_collapsed = active_pipelines_collapsed(app);
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.bitbucket.repos {
        let key = (repo.workspace.clone(), repo.slug.clone());
        let pipelines = app.bitbucket_pipelines.get(&key);
        let count = pipelines.map(|v| v.len()).unwrap_or(0);
        let header_label = format!("{}/{}", repo.workspace, repo.slug);
        let collapsed = pane_collapsed
            .as_ref()
            .map(|c| c.contains(&header_label))
            .unwrap_or(false);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            pipeline: None,
            branch_label: None,
        });
        if collapsed {
            continue;
        }
        if let Some(v) = pipelines {
            for rec in v {
                out.push(FlatRow {
                    kind: RowKind::Pipeline,
                    header_label: String::new(),
                    repo_count: 0,
                    pipeline: Some(rec.clone()),
                    branch_label: None,
                });
            }
        }
    }
    out
}

/// Look up the active BB pipelines pane (if any) and return a clone of
/// its `collapsed_repos` set. Used by the flatten functions to honor
/// per-pane collapse state without taking a mutable borrow.
fn active_pipelines_collapsed(app: &App) -> Option<std::collections::HashSet<String>> {
    // State lives on `App` now — same value regardless of whether a
    // pane is currently open.
    Some(app.bb_pipelines_collapsed.clone())
}

/// Walk the configured repos and emit one Header + one data row per
/// branch (from the cached `App.bitbucket_branch_pipelines`). Used when
/// the pane's `view_mode == PerBranch`.
pub fn flatten_branch_pipelines(app: &App) -> Vec<FlatRow> {
    let pane_collapsed = active_pipelines_collapsed(app);
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.bitbucket.repos {
        let key = (repo.workspace.clone(), repo.slug.clone());
        let per_branch = app.bitbucket_branch_pipelines.get(&key);
        let count = per_branch.map(|v| v.len()).unwrap_or(0);
        let header_label = format!("{}/{}", repo.workspace, repo.slug);
        let collapsed = pane_collapsed
            .as_ref()
            .map(|c| c.contains(&header_label))
            .unwrap_or(false);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            pipeline: None,
            branch_label: None,
        });
        if collapsed {
            continue;
        }
        if let Some(v) = per_branch {
            for (branch, pipeline_opt) in v {
                out.push(FlatRow {
                    kind: RowKind::Pipeline,
                    header_label: String::new(),
                    repo_count: 0,
                    pipeline: pipeline_opt.clone(),
                    branch_label: Some(branch.clone()),
                });
            }
        }
    }
    out
}

/// Resolve the selected index to a `PipelineRecord`, skipping over header
/// rows. Dispatches to the right flatten function based on the pane's
/// view_mode. Used by the `Enter` / `y` key handlers in tui.rs.
pub fn selected_pipeline(
    app: &App,
    pane: &crate::bitbucket::BitbucketPipelinesPane,
) -> Option<PipelineRecord> {
    let flat = match app.bb_pipelines_view_mode {
        crate::bitbucket::PipelineViewMode::Recent => flatten_pipelines(app),
        crate::bitbucket::PipelineViewMode::PerBranch => flatten_branch_pipelines(app),
    };
    flat.get(pane.selected).and_then(|r| r.pipeline.clone())
}

/// Skip past header rows so j/k feel right (vim convention — don't park
/// the cursor on a heading row). Picks the nearest data row in the
/// direction of last travel (we don't track direction yet, so go forward
/// then back).
#[allow(dead_code)] // kept for the tests below; no longer called from draw.
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
                branch_label: None,
            },
            FlatRow {
                kind: RowKind::Pipeline,
                header_label: String::new(),
                repo_count: 0,
                pipeline: None,
                branch_label: None,
            },
        ];
        let mut p = crate::bitbucket::BitbucketPipelinesPane::new();
        p.selected = 0;
        snap_selection_to_data(&mut p, &flat);
        assert_eq!(p.selected, 1);
    }

    #[test]
    fn flatten_branch_pipelines_emits_header_then_branch_rows() {
        let mut cfg = crate::config::Config::default();
        cfg.bitbucket.repos.push(crate::config::BitbucketRepo {
            workspace: "ws".into(),
            slug: "r".into(),
            branches: Vec::new(),
        });
        let dir = tempfile::tempdir().unwrap();
        let mut app = App::new(dir.path().to_path_buf(), cfg).expect("app new");
        app.bitbucket_branch_pipelines
            .insert(("ws".into(), "r".into()), vec![("main".into(), None)]);
        let flat = flatten_branch_pipelines(&app);
        // One header + one per-branch data row.
        assert_eq!(flat.len(), 2);
        assert!(matches!(flat[0].kind, RowKind::Header));
        assert_eq!(flat[0].repo_count, 1);
        assert!(matches!(flat[1].kind, RowKind::Pipeline));
        assert_eq!(flat[1].branch_label.as_deref(), Some("main"));
    }

    #[test]
    fn snap_selection_walks_back_when_only_earlier_data_rows() {
        let flat = vec![
            FlatRow {
                kind: RowKind::Pipeline,
                header_label: String::new(),
                repo_count: 0,
                pipeline: None,
                branch_label: None,
            },
            FlatRow {
                kind: RowKind::Header,
                header_label: "h".into(),
                repo_count: 0,
                pipeline: None,
                branch_label: None,
            },
        ];
        let mut p = crate::bitbucket::BitbucketPipelinesPane::new();
        p.selected = 1;
        snap_selection_to_data(&mut p, &flat);
        assert_eq!(p.selected, 0);
    }
}
