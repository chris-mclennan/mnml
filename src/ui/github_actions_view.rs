//! `Pane::GithubActions` renderer. Symmetric to
//! [`crate::ui::bitbucket_pipelines_view`] — flat list grouped by repo,
//! same selection skip-headers behavior, same color mapping idea.
//!
//! Reads from `App.github_workflow_runs` at render time. The flatten
//! order follows `App.config.github.repos` so config order = display
//! order.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::github::{WorkflowRunRecord, WorkflowRunState};
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

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

    let mode = match app.panes.get(pane_id) {
        Some(Pane::GithubActions(p)) => p.view_mode,
        _ => return None,
    };
    let flat = match mode {
        crate::github::ActionsViewMode::Recent => flatten_runs(app),
        crate::github::ActionsViewMode::PerBranch => flatten_branch_runs(app),
    };
    let total = flat.iter().filter(|r| r.kind == RowKind::Run).count();
    let cache_empty = match mode {
        crate::github::ActionsViewMode::Recent => app.github_workflow_runs.is_empty(),
        crate::github::ActionsViewMode::PerBranch => app.github_branch_runs.is_empty(),
    };
    let loading = !app.github_connected && cache_empty;
    let last_error = app.github_last_error.clone();
    let poll_secs = app.config.github.poll_secs_or_default();
    let configured = app.config.github.any_configured();
    let nerd = !app.config.ui.ascii_icons;

    let Some(Pane::GithubActions(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();

    // ── header banner ─────────────────────────────────────────────
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⚙ ",
            Style::default()
                .fg(t.purple)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{total} run{}", if total == 1 { "" } else { "s" }),
            Style::default()
                .fg(if total > 0 { t.fg } else { t.comment })
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" · view: {} (v to flip)", p.view_mode.label()),
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

    if !configured {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "Add a [[github.repos]] entry to ~/.config/mnml/config.toml \
                 and export $GITHUB_TOKEN to start polling.",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    } else if total == 0 && !loading && last_error.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no workflow runs yet — waiting for the first poll to land)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    }

    let n = flat.len();
    if n > 0 && p.selected >= n {
        p.selected = n - 1;
    }
    // Headers selectable; Enter toggles collapse. No auto-snap.

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
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };
                let collapsed = p.is_collapsed(&row.header_label);
                let arrow = match (collapsed, nerd) {
                    (true, true) => format!("{CHEVRON_CLOSED_NERD} "),
                    (false, true) => format!("{CHEVRON_OPEN_NERD} "),
                    (true, false) => format!("{CHEVRON_CLOSED_ASCII} "),
                    (false, false) => format!("{CHEVRON_OPEN_ASCII} "),
                };
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
            RowKind::Run => {
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };

                let Some(run) = row.run.as_ref() else {
                    // PerBranch row with no runs yet — show the branch with a placeholder.
                    let branch = row.branch_label.as_deref().unwrap_or("?");
                    lines.push(Line::from(vec![
                        Span::styled("    ", Style::default().bg(row_bg)),
                        Span::styled(
                            "·  ",
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                        Span::styled(
                            format!("{:<6}", "—"),
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                        Span::styled(
                            format!("{:<15}", ""),
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                        Span::styled(
                            format!("{branch:<17}"),
                            Style::default().fg(t.cyan).bg(row_bg),
                        ),
                        Span::styled(
                            "(no runs yet)",
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                    ]));
                    continue;
                };

                let (glyph, status_color) = match run.state {
                    WorkflowRunState::Success => (run.state.glyph(), t.green),
                    WorkflowRunState::Failed
                    | WorkflowRunState::TimedOut
                    | WorkflowRunState::ActionRequired => (run.state.glyph(), t.red),
                    WorkflowRunState::InProgress => (run.state.glyph(), t.yellow),
                    WorkflowRunState::Queued | WorkflowRunState::Pending => {
                        (run.state.glyph(), t.cyan)
                    }
                    WorkflowRunState::Cancelled
                    | WorkflowRunState::Skipped
                    | WorkflowRunState::Neutral
                    | WorkflowRunState::Stale => (run.state.glyph(), t.comment),
                    WorkflowRunState::Unknown => (run.state.glyph(), t.fg),
                };

                let run_num = if run.run_number > 0 {
                    format!("#{}", run.run_number)
                } else {
                    "#?".to_string()
                };
                let workflow = truncate(&run.workflow_name, 14);
                // Prefer the row's branch_label (canonical in PerBranch
                // mode) over the run's head_branch (Recent mode).
                let ref_text = row
                    .branch_label
                    .as_deref()
                    .or(run.target_ref.as_deref())
                    .unwrap_or("(no ref)");
                let target = truncate(ref_text, 16);
                let dur = run
                    .duration_secs
                    .map(format_duration_secs)
                    .unwrap_or_else(|| "—".to_string());
                let age = run
                    .started_at_ms
                    .or(run.created_at_ms)
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();
                let creator = truncate(run.creator.as_deref().unwrap_or(""), 20);
                let event_or_step = match (run.state, &run.running_step) {
                    (WorkflowRunState::InProgress, Some(step)) => format!("▶ {step}"),
                    _ => run.event.as_deref().unwrap_or("").to_string(),
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
                        format!("{run_num:<6}"),
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{workflow:<15}"),
                        Style::default().fg(t.yellow).bg(row_bg),
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
                        format!("{creator:<22}"),
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                    Span::styled(
                        event_or_step.clone(),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ]));
            }
        }
    }

    frame.render_widget(Paragraph::new(lines), area);
    None
}

// ─── Flattening (header rows + run rows) ───────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Header,
    Run,
}

#[derive(Debug, Clone)]
pub struct FlatRow {
    pub kind: RowKind,
    pub header_label: String,
    pub repo_count: usize,
    pub run: Option<WorkflowRunRecord>,
    /// Set on PerBranch data rows — the branch this row represents.
    pub branch_label: Option<String>,
}

pub fn flatten_runs(app: &App) -> Vec<FlatRow> {
    let pane_collapsed = active_actions_collapsed(app);
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.github.repos {
        let key = (repo.owner.clone(), repo.repo.clone());
        let runs = app.github_workflow_runs.get(&key);
        let count = runs.map(|v| v.len()).unwrap_or(0);
        let header_label = format!("{}/{}", repo.owner, repo.repo);
        let collapsed = pane_collapsed
            .as_ref()
            .map(|c| c.contains(&header_label))
            .unwrap_or(false);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            run: None,
            branch_label: None,
        });
        if collapsed {
            continue;
        }
        if let Some(v) = runs {
            for rec in v {
                out.push(FlatRow {
                    kind: RowKind::Run,
                    header_label: String::new(),
                    repo_count: 0,
                    run: Some(rec.clone()),
                    branch_label: None,
                });
            }
        }
    }
    out
}

fn active_actions_collapsed(app: &App) -> Option<std::collections::HashSet<String>> {
    app.panes.iter().find_map(|p| match p {
        Pane::GithubActions(pane) => Some(pane.collapsed_repos.clone()),
        _ => None,
    })
}

/// Walk the configured repos and emit one Header + one data row per
/// branch. Used when `view_mode == PerBranch`.
pub fn flatten_branch_runs(app: &App) -> Vec<FlatRow> {
    let pane_collapsed = active_actions_collapsed(app);
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.github.repos {
        let key = (repo.owner.clone(), repo.repo.clone());
        let per_branch = app.github_branch_runs.get(&key);
        let count = per_branch.map(|v| v.len()).unwrap_or(0);
        let header_label = format!("{}/{}", repo.owner, repo.repo);
        let collapsed = pane_collapsed
            .as_ref()
            .map(|c| c.contains(&header_label))
            .unwrap_or(false);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            run: None,
            branch_label: None,
        });
        if collapsed {
            continue;
        }
        if let Some(v) = per_branch {
            for (branch, run_opt) in v {
                out.push(FlatRow {
                    kind: RowKind::Run,
                    header_label: String::new(),
                    repo_count: 0,
                    run: run_opt.clone(),
                    branch_label: Some(branch.clone()),
                });
            }
        }
    }
    out
}

pub fn selected_run(
    app: &App,
    pane: &crate::github::GithubActionsPane,
) -> Option<WorkflowRunRecord> {
    let flat = match pane.view_mode {
        crate::github::ActionsViewMode::Recent => flatten_runs(app),
        crate::github::ActionsViewMode::PerBranch => flatten_branch_runs(app),
    };
    flat.get(pane.selected).and_then(|r| r.run.clone())
}

#[allow(dead_code)] // headers are now selectable; kept for revisit.
fn snap_selection_to_data(pane: &mut crate::github::GithubActionsPane, flat: &[FlatRow]) {
    if flat.is_empty() {
        return;
    }
    if flat
        .get(pane.selected)
        .map(|r| r.kind == RowKind::Run)
        .unwrap_or(false)
    {
        return;
    }
    for (i, row) in flat.iter().enumerate().skip(pane.selected) {
        if row.kind == RowKind::Run {
            pane.selected = i;
            return;
        }
    }
    for (i, row) in flat.iter().enumerate().take(pane.selected).rev() {
        if row.kind == RowKind::Run {
            pane.selected = i;
            return;
        }
    }
}

// ─── Small renderer helpers (duplicated from the BB sibling to keep the
// two modules independent — they may diverge as host-specific quirks
// emerge). ─────────────────────────────────────────────────────────────

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
    fn flatten_runs_orders_by_config() {
        // Smoke test for the flattener — config-order ⇒ header order.
        let mut cfg = crate::config::Config::default();
        cfg.github.repos.push(crate::config::GithubRepo {
            owner: "a".into(),
            repo: "1".into(),
            branches: Vec::new(),
        });
        cfg.github.repos.push(crate::config::GithubRepo {
            owner: "a".into(),
            repo: "2".into(),
            branches: Vec::new(),
        });
        // Empty cache — just headers.
        let ws = std::env::temp_dir();
        let app = App::new(ws, cfg).expect("app new");
        let flat = flatten_runs(&app);
        assert_eq!(flat.len(), 2);
        assert_eq!(flat[0].header_label, "a/1");
        assert_eq!(flat[1].header_label, "a/2");
    }
}
