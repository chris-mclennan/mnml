//! `Pane::GithubPullRequests` renderer. Sibling of
//! [`crate::ui::bitbucket_pull_requests_view`].

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::github::{PullRequestRecord, PullRequestState};
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

    let mode = app.gh_prs_view_mode;
    let collapsed_set = app.gh_prs_collapsed.clone();
    let flat = match mode {
        crate::github::GhPrViewMode::PerRepo => flatten_prs(app),
        crate::github::GhPrViewMode::Mine => flatten_my_prs(app),
    };
    let total = flat.iter().filter(|r| r.kind == RowKind::Pr).count();
    let cache_empty = match mode {
        crate::github::GhPrViewMode::PerRepo => app.github_pull_requests.is_empty(),
        crate::github::GhPrViewMode::Mine => app.github_my_pull_requests.is_empty(),
    };
    let loading = !app.github_connected && cache_empty;
    let last_error = app.github_last_error.clone();
    let poll_secs = app.config.github.poll_secs_or_default();
    let nerd = !app.config.ui.ascii_icons;

    let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();
    let mut header = vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "⇄ ",
            Style::default()
                .fg(t.purple)
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

    if total == 0 && !loading && last_error.is_none() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                "(no open PRs)",
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

    // Auto-fit the title column. +25 in Mine for the repo prefix.
    let fixed_w = 100
        + if matches!(mode, crate::github::GhPrViewMode::Mine) {
            25
        } else {
            0
        };
    let title_w = (area.width as usize).saturating_sub(fixed_w).clamp(20, 120);

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
            RowKind::Pr => {
                let pr = row.pr.as_ref().expect("data row carries PR");
                let selected = i == p.selected;
                let row_bg = if selected { t.bg2 } else { t.bg_dark };

                let pr_num = format!("#{:<5}", pr.number);
                let title = truncate(&pr.title, title_w);
                let branches = format!(
                    "{} → {}",
                    truncate(pr.source_branch.as_deref().unwrap_or("?"), 18),
                    truncate(pr.dest_branch.as_deref().unwrap_or("?"), 10),
                );
                let author = truncate(pr.author.as_deref().unwrap_or(""), 18);
                let age = pr
                    .updated_at_ms
                    .or(pr.created_at_ms)
                    .map(|ms| humanize_age((now_ms - ms).max(0)))
                    .unwrap_or_default();
                let total_comments = pr.comment_count + pr.review_comment_count;

                let (state_glyph, state_color) = match pr.state {
                    PullRequestState::Open => ("○", t.green),
                    PullRequestState::Draft => ("◐", t.comment),
                    PullRequestState::Merged => ("●", t.purple),
                    PullRequestState::Closed => ("⊘", t.red),
                    PullRequestState::Unknown => ("?", t.fg),
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
                    Span::styled(pr_num, Style::default().fg(t.fg).bg(row_bg)),
                ];
                if matches!(mode, crate::github::GhPrViewMode::Mine) {
                    let repo_label = truncate(&format!("{}/{}", pr.owner, pr.repo), 24);
                    spans.push(Span::styled(
                        format!("{repo_label:<25}"),
                        Style::default().fg(t.purple).bg(row_bg),
                    ));
                }
                spans.push(Span::styled(
                    format!("{title:<width$}  ", width = title_w),
                    Style::default().fg(t.fg).bg(row_bg),
                ));
                spans.push(Span::styled(
                    format!("👀{:<2}", pr.reviewer_count),
                    Style::default().fg(t.fg).bg(row_bg),
                ));
                if pr.approved_count > 0 {
                    spans.push(Span::styled(
                        format!(" ✓{}", pr.approved_count),
                        Style::default()
                            .fg(t.green)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ));
                }
                if pr.changes_count > 0 {
                    spans.push(Span::styled(
                        format!(" ✗{}", pr.changes_count),
                        Style::default()
                            .fg(t.red)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ));
                }
                spans.extend([
                    Span::styled(
                        format!(" · 💬{:<3}", total_comments),
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

// ─── Flattening (sibling of the BB version) ────────────────────────────

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
    let pane_collapsed = active_gh_pr_collapsed(app);
    let mut out: Vec<FlatRow> = Vec::new();
    for repo in &app.config.github.repos {
        let key = (repo.owner.clone(), repo.repo.clone());
        let prs = app.github_pull_requests.get(&key);
        let count = prs.map(|v| v.len()).unwrap_or(0);
        let header_label = format!("{}/{}", repo.owner, repo.repo);
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

fn active_gh_pr_collapsed(app: &App) -> Option<std::collections::HashSet<String>> {
    Some(app.gh_prs_collapsed.clone())
}

pub fn flatten_my_prs(app: &App) -> Vec<FlatRow> {
    let mut out: Vec<FlatRow> = Vec::new();
    let prs = &app.github_my_pull_requests;
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
    pane: &crate::github::GithubPullRequestsPane,
) -> Option<PullRequestRecord> {
    let flat = match app.gh_prs_view_mode {
        crate::github::GhPrViewMode::PerRepo => flatten_prs(app),
        crate::github::GhPrViewMode::Mine => flatten_my_prs(app),
    };
    flat.get(pane.selected).and_then(|r| r.pr.clone())
}

#[allow(dead_code)] // headers are now selectable; kept for revisit.
fn snap_selection_to_data(pane: &mut crate::github::GithubPullRequestsPane, flat: &[FlatRow]) {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke test for the flattener: with an empty cache, every
    /// configured project / repo produces exactly one header row, in
    /// config order. Guards the config-order ↔ render-order contract
    /// (a mismatch there was a real bug — see 87ffef2).
    #[test]
    fn flatten_prs_orders_headers_by_config() {
        let mut cfg = crate::config::Config::default();
        cfg.github.repos.push(crate::config::GithubRepo {
            owner: "o".into(),
            repo: "aaa".into(),
            branches: Vec::new(),
        });
        cfg.github.repos.push(crate::config::GithubRepo {
            owner: "o".into(),
            repo: "zzz".into(),
            branches: Vec::new(),
        });
        let dir = tempfile::tempdir().unwrap();
        let app = App::new(dir.path().to_path_buf(), cfg).expect("app new");
        let flat = flatten_prs(&app);
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

    #[test]
    fn flatten_my_prs_empty_cache_is_a_lone_header() {
        let cfg = crate::config::Config::default();
        let dir = tempfile::tempdir().unwrap();
        let app = App::new(dir.path().to_path_buf(), cfg).expect("app new");
        let flat = flatten_my_prs(&app);
        assert_eq!(flat.len(), 1);
        assert!(matches!(flat[0].kind, RowKind::Header));
        assert_eq!(flat[0].header_label, "mine (cross-repo)");
        assert_eq!(flat[0].repo_count, 0);
    }
}
