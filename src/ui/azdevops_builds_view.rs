//! `Pane::AzDevOpsBuilds` renderer.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::azdevops::{BuildRecord, BuildState};
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

const CHEVRON_OPEN_NERD: &str = "\u{f107}";
const CHEVRON_CLOSED_NERD: &str = "\u{f105}";

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

    let mode = app.az_builds_view_mode;
    let collapsed_set = app.az_builds_collapsed.clone();
    let flat = match mode {
        crate::azdevops::AzBuildsViewMode::Recent => flatten_builds(app),
        crate::azdevops::AzBuildsViewMode::PerBranch => flatten_branch_builds(app),
    };
    let total = flat.iter().filter(|r| r.kind == RowKind::Build).count();
    let loading = !app.azdevops_connected && app.azdevops_builds.is_empty();
    let last_error = app.azdevops_last_error.clone();
    let poll_secs = app.config.azdevops.poll_secs_or_default();
    let nerd = !app.config.ui.ascii_icons;

    let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⚡ ",
            Style::default()
                .fg(t.blue)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{total} build{}", if total == 1 { "" } else { "s" }),
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
        "    (r refresh · Enter open · y copy · Esc tree)",
        Style::default().fg(t.comment).bg(t.bg_dark),
    ));
    lines.push(Line::from(header));
    lines.push(Line::from(""));

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

    // Auto-fit the ref column: fixed cols ~75 (indent 4 · glyph 3 ·
    // build# 14 · dur 9 · age 12 · creator 24 · trailing reason 10).
    let ref_w = (area.width as usize).saturating_sub(75).clamp(15, 80);
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
                let arrow = if nerd {
                    if collapsed {
                        CHEVRON_CLOSED_NERD
                    } else {
                        CHEVRON_OPEN_NERD
                    }
                } else if collapsed {
                    "▸"
                } else {
                    "▾"
                };
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default().bg(row_bg)),
                    Span::styled(
                        format!("{arrow} "),
                        Style::default().fg(t.purple).bg(row_bg),
                    ),
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
            RowKind::Build => {
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };
                let Some(b) = row.build.as_ref() else {
                    let branch = row.branch_label.as_deref().unwrap_or("?");
                    lines.push(Line::from(vec![
                        Span::styled("    ", Style::default().bg(row_bg)),
                        Span::styled("·  ", Style::default().fg(t.comment).bg(row_bg)),
                        Span::styled(
                            format!("{branch:<17}"),
                            Style::default().fg(t.cyan).bg(row_bg),
                        ),
                        Span::styled("(no builds)", Style::default().fg(t.comment).bg(row_bg)),
                    ]));
                    continue;
                };
                let (glyph, color) = match b.state {
                    BuildState::Succeeded => (b.state.glyph(), t.green),
                    BuildState::Failed => (b.state.glyph(), t.red),
                    BuildState::Canceled => (b.state.glyph(), t.comment),
                    BuildState::PartiallySucceeded => (b.state.glyph(), t.orange),
                    BuildState::InProgress => (b.state.glyph(), t.yellow),
                    BuildState::NotStarted => (b.state.glyph(), t.cyan),
                    BuildState::Unknown => (b.state.glyph(), t.fg),
                };
                let build_num = if !b.build_number.is_empty() {
                    format!("#{}", b.build_number)
                } else {
                    "#?".to_string()
                };
                let ref_text = row
                    .branch_label
                    .as_deref()
                    .or(b.target_ref.as_deref())
                    .unwrap_or("(no ref)");
                let target = truncate(ref_text, ref_w.saturating_sub(1));
                let dur = b
                    .duration_secs
                    .map(format_duration_secs)
                    .unwrap_or_else(|| "—".to_string());
                let age = b
                    .started_at_ms
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();
                let creator = truncate(b.creator.as_deref().unwrap_or(""), 22);
                let reason = b.reason.as_deref().unwrap_or("");
                lines.push(Line::from(vec![
                    Span::styled("    ", Style::default().bg(row_bg)),
                    Span::styled(
                        format!("{glyph}  "),
                        Style::default()
                            .fg(color)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        format!("{build_num:<14}"),
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
                    Span::styled(
                        reason.to_string(),
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
    Build,
}

#[derive(Debug, Clone)]
pub struct FlatRow {
    pub kind: RowKind,
    pub header_label: String,
    pub repo_count: usize,
    pub build: Option<BuildRecord>,
    pub branch_label: Option<String>,
}

pub fn flatten_builds(app: &App) -> Vec<FlatRow> {
    let collapsed = &app.az_builds_collapsed;
    let mut out: Vec<FlatRow> = Vec::new();
    for project in &app.config.azdevops.projects {
        let label = crate::azdevops::project_label(project);
        let builds = app.azdevops_builds.get(&label);
        let count = builds.map(|v| v.len()).unwrap_or(0);
        let is_collapsed = collapsed.contains(&label);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label: label.clone(),
            repo_count: count,
            build: None,
            branch_label: None,
        });
        if is_collapsed {
            continue;
        }
        if let Some(v) = builds {
            for rec in v {
                out.push(FlatRow {
                    kind: RowKind::Build,
                    header_label: String::new(),
                    repo_count: 0,
                    build: Some(rec.clone()),
                    branch_label: None,
                });
            }
        }
    }
    out
}

pub fn flatten_branch_builds(app: &App) -> Vec<FlatRow> {
    let collapsed = &app.az_builds_collapsed;
    let mut out: Vec<FlatRow> = Vec::new();
    for project in &app.config.azdevops.projects {
        let label = crate::azdevops::project_label(project);
        let per_branch = app.azdevops_branch_builds.get(&label);
        let count = per_branch.map(|v| v.len()).unwrap_or(0);
        let is_collapsed = collapsed.contains(&label);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label: label.clone(),
            repo_count: count,
            build: None,
            branch_label: None,
        });
        if is_collapsed {
            continue;
        }
        if let Some(v) = per_branch {
            for (branch, build_opt) in v {
                out.push(FlatRow {
                    kind: RowKind::Build,
                    header_label: String::new(),
                    repo_count: 0,
                    build: build_opt.clone(),
                    branch_label: Some(branch.clone()),
                });
            }
        }
    }
    out
}

pub fn selected_build(
    app: &App,
    pane: &crate::azdevops::AzDevOpsBuildsPane,
) -> Option<BuildRecord> {
    let flat = match app.az_builds_view_mode {
        crate::azdevops::AzBuildsViewMode::Recent => flatten_builds(app),
        crate::azdevops::AzBuildsViewMode::PerBranch => flatten_branch_builds(app),
    };
    flat.get(pane.selected).and_then(|r| r.build.clone())
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

fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
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
