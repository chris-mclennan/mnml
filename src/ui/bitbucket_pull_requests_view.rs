//! `Pane::BitbucketPullRequests` renderer. Same flat-grouped layout as
//! the pipelines pane:
//!
//! ```text
//!  ⇄ 5 open PRs · polling every 30s · (r refresh · Enter open · y copy · Esc tree)
//!
//!  ▸ exampleorg/example-api  (3)
//!  #4521 Add Safari fallback for auth middleware           👀 3 ✓1 ✗1 · 💬 7 · feature/safari-auth → main · 1h ago · Chris McLennan
//!  #4499 Reward eligibility refactor                        👀 2 ✓2     · 💬 3 · refactor/rewards    → main · 1d ago · Tal Doron
//! ```

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::bitbucket::{PullRequestRecord, PullRequestState};
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

    let mode = match app.panes.get(pane_id) {
        Some(Pane::BitbucketPullRequests(p)) => p.view_mode,
        _ => return None,
    };
    let flat = match mode {
        crate::bitbucket::PrViewMode::PerRepo => flatten_prs(app),
        crate::bitbucket::PrViewMode::Mine => flatten_my_prs(app),
    };
    let total = flat.iter().filter(|r| r.kind == RowKind::Pr).count();
    let cache_empty = match mode {
        crate::bitbucket::PrViewMode::PerRepo => app.bitbucket_pull_requests.is_empty(),
        crate::bitbucket::PrViewMode::Mine => app.bitbucket_my_pull_requests.is_empty(),
    };
    let loading = !app.bitbucket_connected && cache_empty;
    let last_error = app.bitbucket_last_error.clone();
    let poll_secs = app.config.bitbucket.poll_secs_or_default();

    let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⇄ ",
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{total} open PR{}", if total == 1 { "" } else { "s" }),
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

    if total == 0 && !loading && last_error.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no open PRs — nothing waiting on review)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]));
    }

    let n = flat.len();
    if n > 0 && p.selected >= n {
        p.selected = n - 1;
    }
    // Headers selectable (Enter toggles collapse). No auto-snap.

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
                let arrow = if collapsed { "▸ " } else { "▾ " };
                lines.push(Line::from(vec![
                    Span::styled(" ", Style::default().bg(row_bg)),
                    Span::styled(
                        arrow,
                        Style::default()
                            .fg(t.purple)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        row.header_label.clone(),
                        Style::default()
                            .fg(t.purple)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        format!("  ({})", row.repo_count),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ]));
            }
            RowKind::Pr => {
                let pr = row.pr.as_ref().expect("data row carries PR");
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };

                let pr_num = format!("#{:<5}", pr.id);
                let title = truncate(&pr.title, 50);
                let branches = format!(
                    "{} → {}",
                    truncate(pr.source_branch.as_deref().unwrap_or("?"), 18),
                    truncate(pr.dest_branch.as_deref().unwrap_or("?"), 10),
                );
                let author = truncate(pr.author.as_deref().unwrap_or(""), 18);
                let age = pr
                    .updated_on_ms
                    .or(pr.created_on_ms)
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();

                // Review chip: 👀 N total · ✓A — green when approved == reviewers,
                // ✗C — red when any reviewer requested changes.
                let mut review_spans: Vec<Span> = Vec::new();
                review_spans.push(Span::styled(
                    format!("👀{:<2}", pr.reviewer_count),
                    Style::default().fg(t.fg).bg(row_bg),
                ));
                if pr.approved_count > 0 {
                    review_spans.push(Span::styled(
                        format!(" ✓{}", pr.approved_count),
                        Style::default()
                            .fg(t.green)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ));
                }
                if pr.changes_count > 0 {
                    review_spans.push(Span::styled(
                        format!(" ✗{}", pr.changes_count),
                        Style::default()
                            .fg(t.red)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ));
                }
                let state_glyph = match pr.state {
                    PullRequestState::Open => "○",
                    PullRequestState::Merged => "●",
                    PullRequestState::Declined => "⊘",
                    PullRequestState::Superseded => "↩",
                    PullRequestState::Unknown => "?",
                };
                let state_color = match pr.state {
                    PullRequestState::Open => t.green,
                    PullRequestState::Merged => t.purple,
                    PullRequestState::Declined => t.red,
                    PullRequestState::Superseded => t.comment,
                    PullRequestState::Unknown => t.fg,
                };

                let mut spans = vec![
                    Span::styled(" ", Style::default().bg(row_bg)),
                    Span::styled(
                        format!("{state_glyph}  "),
                        Style::default()
                            .fg(state_color)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        pr_num,
                        Style::default().fg(t.fg).bg(row_bg),
                    ),
                ];
                // In Mine mode the data is cross-repo with no per-repo
                // header grouping — surface the repo name inline so the
                // user can tell rows apart.
                if matches!(mode, crate::bitbucket::PrViewMode::Mine) {
                    let repo_label = truncate(&format!("{}/{}", pr.workspace, pr.slug), 22);
                    spans.push(Span::styled(
                        format!("{repo_label:<23}"),
                        Style::default().fg(t.purple).bg(row_bg),
                    ));
                }
                spans.push(Span::styled(
                    format!("{title:<50}  "),
                    Style::default().fg(t.fg).bg(row_bg),
                ));
                spans.extend(review_spans);
                spans.extend([
                    Span::styled(
                        format!(" · 💬{:<3}", pr.comment_count),
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

// ─── Flattening ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Header,
    Pr,
}

#[derive(Debug, Clone)]
pub struct FlatRow {
    pub kind: RowKind,
    pub header_label: String,
    pub repo_count: usize,
    pub pr: Option<PullRequestRecord>,
}

pub fn flatten_prs(app: &App) -> Vec<FlatRow> {
    let pane_collapsed = active_pr_collapsed(app);
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.bitbucket.repos {
        let key = (repo.workspace.clone(), repo.slug.clone());
        let prs = app.bitbucket_pull_requests.get(&key);
        let count = prs.map(|v| v.len()).unwrap_or(0);
        let header_label = format!("{}/{}", repo.workspace, repo.slug);
        let collapsed = pane_collapsed
            .as_ref()
            .map(|c| c.contains(&header_label))
            .unwrap_or(false);
        out.push(FlatRow {
            kind: RowKind::Header,
            header_label,
            repo_count: count,
            pr: None,
        });
        if collapsed {
            continue;
        }
        if let Some(v) = prs {
            for rec in v {
                out.push(FlatRow {
                    kind: RowKind::Pr,
                    header_label: String::new(),
                    repo_count: 0,
                    pr: Some(rec.clone()),
                });
            }
        }
    }
    out
}

fn active_pr_collapsed(app: &App) -> Option<std::collections::HashSet<String>> {
    app.panes.iter().find_map(|p| match p {
        Pane::BitbucketPullRequests(pane) => Some(pane.collapsed_repos.clone()),
        _ => None,
    })
}

/// Cross-repo flat list — one header row labeled "mine" + every PR I
/// authored across every accessible repo. The PR data carries its own
/// `workspace` and `slug` so the renderer can inline the REPO column
/// rather than rely on per-repo grouping.
pub fn flatten_my_prs(app: &App) -> Vec<FlatRow> {
    let mut out: Vec<FlatRow> = Vec::new();
    let prs = &app.bitbucket_my_pull_requests;
    out.push(FlatRow {
        kind: RowKind::Header,
        header_label: "mine (cross-repo)".to_string(),
        repo_count: prs.len(),
        pr: None,
    });
    for rec in prs {
        out.push(FlatRow {
            kind: RowKind::Pr,
            header_label: String::new(),
            repo_count: 0,
            pr: Some(rec.clone()),
        });
    }
    out
}

pub fn selected_pr(
    app: &App,
    pane: &crate::bitbucket::BitbucketPullRequestsPane,
) -> Option<PullRequestRecord> {
    let flat = match pane.view_mode {
        crate::bitbucket::PrViewMode::PerRepo => flatten_prs(app),
        crate::bitbucket::PrViewMode::Mine => flatten_my_prs(app),
    };
    flat.get(pane.selected).and_then(|r| r.pr.clone())
}

#[allow(dead_code)] // headers are now selectable; kept in case we revisit.
fn snap_selection_to_data(
    pane: &mut crate::bitbucket::BitbucketPullRequestsPane,
    flat: &[FlatRow],
) {
    if flat.is_empty() {
        return;
    }
    if flat
        .get(pane.selected)
        .map(|r| r.kind == RowKind::Pr)
        .unwrap_or(false)
    {
        return;
    }
    for (i, row) in flat.iter().enumerate().skip(pane.selected) {
        if row.kind == RowKind::Pr {
            pane.selected = i;
            return;
        }
    }
    for (i, row) in flat.iter().enumerate().take(pane.selected).rev() {
        if row.kind == RowKind::Pr {
            pane.selected = i;
            return;
        }
    }
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
