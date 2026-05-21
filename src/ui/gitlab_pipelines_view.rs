//! `Pane::GitlabPipelines` renderer. Same shape as the BB/GH pipeline
//! panes — flat list grouped by project header, view-mode toggle,
//! collapsible headers.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::gitlab::{PipelineRecord, PipelineState};
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

    let mode = app.gl_pipelines_view_mode;
    let collapsed_set = app.gl_pipelines_collapsed.clone();
    let flat = match mode {
        crate::gitlab::GlPipelineViewMode::Recent => flatten_pipelines(app),
        crate::gitlab::GlPipelineViewMode::PerBranch => flatten_branch_pipelines(app),
    };
    let total = flat.iter().filter(|r| r.kind == RowKind::Pipeline).count();
    let loading = !app.gitlab_connected && app.gitlab_pipelines.is_empty();
    let last_error = app.gitlab_last_error.clone();
    let poll_secs = app.config.gitlab.poll_secs_or_default();
    let configured = app.config.gitlab.any_configured();
    let nerd = !app.config.ui.ascii_icons;

    let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "▴ ",
            Style::default()
                .fg(t.orange)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{total} pipeline{}", if total == 1 { "" } else { "s" }),
            Style::default()
                .fg(if total > 0 { t.fg } else { t.comment })
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
        "    (r refresh · Enter open · y copy · v flip · Esc tree)",
        Style::default().fg(t.comment).bg(t.bg_dark),
    ));
    lines.push(Line::from(header));
    lines.push(Line::from(""));

    if !configured {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "Add a [[gitlab.projects]] entry to ~/.config/mnml/config.toml \
                 and export $GITLAB_TOKEN to start polling.",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    } else if total == 0 && !loading && last_error.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no pipelines yet — waiting for first poll)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    }

    let n = flat.len();
    if n > 0 && p.selected >= n {
        p.selected = n - 1;
    }
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

    // Auto-fit the ref column: fixed cols ~55 (indent 4 · glyph 3 ·
    // #N 7 · sha 10 · dur 9 · age 10 · trailing slack 12).
    let ref_w = (area.width as usize).saturating_sub(55).clamp(15, 80);
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
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                i,
            ));
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
                let Some(pipe) = row.pipeline.as_ref() else {
                    let branch = row.branch_label.as_deref().unwrap_or("?");
                    lines.push(Line::from(vec![
                        Span::styled("    ", Style::default().bg(row_bg)),
                        Span::styled("·  ", Style::default().fg(t.comment).bg(row_bg)),
                        Span::styled(
                            format!("{branch:<17}"),
                            Style::default().fg(t.cyan).bg(row_bg),
                        ),
                        Span::styled(
                            "(no pipelines yet)",
                            Style::default().fg(t.comment).bg(row_bg),
                        ),
                    ]));
                    continue;
                };
                let (glyph, status_color) = match pipe.state {
                    PipelineState::Success => (pipe.state.glyph(), t.green),
                    PipelineState::Failed => (pipe.state.glyph(), t.red),
                    PipelineState::Running => (pipe.state.glyph(), t.yellow),
                    PipelineState::Pending | PipelineState::Created | PipelineState::Preparing => {
                        (pipe.state.glyph(), t.cyan)
                    }
                    PipelineState::Canceled
                    | PipelineState::Skipped
                    | PipelineState::WaitingForResource
                    | PipelineState::Scheduled => (pipe.state.glyph(), t.comment),
                    PipelineState::Manual => (pipe.state.glyph(), t.orange),
                    PipelineState::Unknown => (pipe.state.glyph(), t.fg),
                };
                let pipe_num = if pipe.iid > 0 {
                    format!("#{}", pipe.iid)
                } else {
                    "#?".to_string()
                };
                let ref_text = row
                    .branch_label
                    .as_deref()
                    .or(pipe.target_ref.as_deref())
                    .unwrap_or("(no ref)");
                let dur = pipe
                    .duration_secs
                    .map(format_duration_secs)
                    .unwrap_or_else(|| "—".to_string());
                let age = pipe
                    .created_at_ms
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();
                let sha = pipe
                    .commit_hash
                    .as_deref()
                    .map(|s| s.chars().take(8).collect::<String>())
                    .unwrap_or_default();
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
                        format!("{pipe_num:<7}"),
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                    Span::styled(
                        format!(
                            "{:<width$}",
                            truncate(ref_text, ref_w.saturating_sub(1)),
                            width = ref_w,
                        ),
                        Style::default().fg(t.cyan).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{sha:<10}"),
                        Style::default().fg(t.purple).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{dur:>7}  "),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{age:<10}"),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ]));
            }
        }
    }

    frame.render_widget(Paragraph::new(lines), area);
    None
}

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
    pub branch_label: Option<String>,
}

pub fn flatten_pipelines(app: &App) -> Vec<FlatRow> {
    let collapsed = &app.gl_pipelines_collapsed;
    let mut out: Vec<FlatRow> = Vec::new();
    for project in &app.config.gitlab.projects {
        let pipelines = app.gitlab_pipelines.get(&project.project);
        let count = pipelines.map(|v| v.len()).unwrap_or(0);
        let header_label = project.project.clone();
        let is_collapsed = collapsed.contains(&header_label);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            pipeline: None,
            branch_label: None,
        });
        if is_collapsed {
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

pub fn flatten_branch_pipelines(app: &App) -> Vec<FlatRow> {
    let collapsed = &app.gl_pipelines_collapsed;
    let mut out: Vec<FlatRow> = Vec::new();
    for project in &app.config.gitlab.projects {
        let per_branch = app.gitlab_branch_pipelines.get(&project.project);
        let count = per_branch.map(|v| v.len()).unwrap_or(0);
        let header_label = project.project.clone();
        let is_collapsed = collapsed.contains(&header_label);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            pipeline: None,
            branch_label: None,
        });
        if is_collapsed {
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

pub fn selected_pipeline(
    app: &App,
    pane: &crate::gitlab::GitlabPipelinesPane,
) -> Option<PipelineRecord> {
    let flat = match app.gl_pipelines_view_mode {
        crate::gitlab::GlPipelineViewMode::Recent => flatten_pipelines(app),
        crate::gitlab::GlPipelineViewMode::PerBranch => flatten_branch_pipelines(app),
    };
    flat.get(pane.selected).and_then(|r| r.pipeline.clone())
}

fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
}

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
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke test for the flattener: with an empty cache, every
    /// configured project / repo produces exactly one header row, in
    /// config order. Guards the config-order ↔ render-order contract
    /// (a mismatch there was a real bug — see 87ffef2).
    #[test]
    fn flatten_pipelines_orders_headers_by_config() {
        let mut cfg = crate::config::Config::default();
        cfg.gitlab.projects.push(crate::config::GitlabProject {
            project: "grp/aaa".into(),
            branches: Vec::new(),
        });
        cfg.gitlab.projects.push(crate::config::GitlabProject {
            project: "grp/zzz".into(),
            branches: Vec::new(),
        });
        let dir = tempfile::tempdir().unwrap();
        let app = App::new(dir.path().to_path_buf(), cfg).expect("app new");
        let flat = flatten_pipelines(&app);
        assert_eq!(flat.len(), 2, "two entries, empty cache => two headers");
        assert!(matches!(flat[0].kind, RowKind::Header));
        assert!(matches!(flat[1].kind, RowKind::Header));
        assert!(
            flat[0].header_label.contains("aaa"),
            "first header out of order: {:?}",
            flat[0].header_label
        );
        assert!(
            flat[1].header_label.contains("zzz"),
            "second header out of order: {:?}",
            flat[1].header_label
        );
    }
}
