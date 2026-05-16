//! `Pane::GitlabMergeRequests` renderer. Mirror of the BB/GH PR
//! renderers — PerProject grouped + Mine flat list.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::gitlab::{MergeRequestRecord, MergeRequestState};
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

    let mode = app.gl_mrs_view_mode;
    let collapsed_set = app.gl_mrs_collapsed.clone();
    let flat = match mode {
        crate::gitlab::GlMrViewMode::PerProject => flatten_mrs(app),
        crate::gitlab::GlMrViewMode::Mine => flatten_my_mrs(app),
    };
    let total = flat.iter().filter(|r| r.kind == RowKind::Mr).count();
    let loading = !app.gitlab_connected && app.gitlab_merge_requests.is_empty();
    let last_error = app.gitlab_last_error.clone();
    let poll_secs = app.config.gitlab.poll_secs_or_default();
    let nerd = !app.config.ui.ascii_icons;

    let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⇄ ",
            Style::default()
                .fg(t.orange)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{total} open MR{}", if total == 1 { "" } else { "s" }),
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

    if total == 0 && !loading && last_error.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no open MRs)",
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
            RowKind::Mr => {
                let mr = row.mr.as_ref().expect("data row carries MR");
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };
                let mr_num = format!("!{:<5}", mr.iid);
                let title = truncate(&mr.title, 50);
                let branches = format!(
                    "{} → {}",
                    truncate(mr.source_branch.as_deref().unwrap_or("?"), 18),
                    truncate(mr.dest_branch.as_deref().unwrap_or("?"), 10),
                );
                let author = truncate(mr.author.as_deref().unwrap_or(""), 18);
                let age = mr
                    .updated_at_ms
                    .or(mr.created_at_ms)
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();
                let (state_glyph, state_color) = match mr.state {
                    MergeRequestState::Opened => ("○", t.green),
                    MergeRequestState::Draft => ("◐", t.comment),
                    MergeRequestState::Merged => ("●", t.purple),
                    MergeRequestState::Closed => ("⊘", t.red),
                    MergeRequestState::Unknown => ("?", t.fg),
                };
                let mut spans = vec![
                    Span::styled("    ", Style::default().bg(row_bg)),
                    Span::styled(
                        format!("{state_glyph}  "),
                        Style::default()
                            .fg(state_color)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(mr_num, Style::default().fg(t.fg).bg(row_bg)),
                ];
                if matches!(mode, crate::gitlab::GlMrViewMode::Mine) {
                    let proj = truncate(&mr.project, 22);
                    spans.push(Span::styled(
                        format!("{proj:<23}"),
                        Style::default().fg(t.purple).bg(row_bg),
                    ));
                }
                spans.push(Span::styled(
                    format!("{title:<50}  "),
                    Style::default().fg(t.fg).bg(row_bg),
                ));
                spans.extend([
                    Span::styled(
                        format!("👀{:<2}", mr.reviewer_count),
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                    Span::styled(
                        format!(" · 💬{:<3}", mr.comment_count),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                    Span::styled(
                        format!("  {branches:<32}  "),
                        Style::default().fg(t.cyan).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{age:<10}  "),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                    Span::styled(author, Style::default().fg(t.fg).bg(row_bg)),
                ]);
                lines.push(Line::from(spans));
            }
        }
    }

    frame.render_widget(Paragraph::new(lines), area);
    None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Header,
    Mr,
}

#[derive(Debug, Clone)]
pub struct FlatRow {
    pub kind: RowKind,
    pub header_label: String,
    pub repo_count: usize,
    pub mr: Option<MergeRequestRecord>,
}

pub fn flatten_mrs(app: &App) -> Vec<FlatRow> {
    let collapsed = &app.gl_mrs_collapsed;
    let mut out: Vec<FlatRow> = Vec::new();
    for project in &app.config.gitlab.projects {
        let mrs = app.gitlab_merge_requests.get(&project.project);
        let count = mrs.map(|v| v.len()).unwrap_or(0);
        let header_label = project.project.clone();
        let is_collapsed = collapsed.contains(&header_label);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            mr: None,
        });
        if is_collapsed {
            continue;
        }
        if let Some(v) = mrs {
            for rec in v {
                out.push(FlatRow {
                    kind: RowKind::Mr,
                    header_label: String::new(),
                    repo_count: 0,
                    mr: Some(rec.clone()),
                });
            }
        }
    }
    out
}

pub fn flatten_my_mrs(app: &App) -> Vec<FlatRow> {
    let mut out: Vec<FlatRow> = Vec::new();
    let mrs = &app.gitlab_my_merge_requests;
    out.push(FlatRow {
        kind: RowKind::Header,
        header_label: "mine (cross-project)".to_string(),
        repo_count: mrs.len(),
        mr: None,
    });
    for rec in mrs {
        out.push(FlatRow {
            kind: RowKind::Mr,
            header_label: String::new(),
            repo_count: 0,
            mr: Some(rec.clone()),
        });
    }
    out
}

pub fn selected_mr(
    app: &App,
    pane: &crate::gitlab::GitlabMergeRequestsPane,
) -> Option<MergeRequestRecord> {
    let flat = match app.gl_mrs_view_mode {
        crate::gitlab::GlMrViewMode::PerProject => flatten_mrs(app),
        crate::gitlab::GlMrViewMode::Mine => flatten_my_mrs(app),
    };
    flat.get(pane.selected).and_then(|r| r.mr.clone())
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
