//! GitKraken-style left-rail palette shown when `ActivitySection::Git`
//! is the active activity-bar section.
//!
//! Replaces the older `SOURCE CONTROL` placeholder (still defined in
//! `draw_git_section_content` for the in-flight migration). The
//! palette shows a structured navigation of the active repo:
//!
//!   - Header: repo name + active branch (click branch → checkout
//!     picker)
//!   - LOCAL: local branches grouped by `/` prefix (e.g. `bugfix/`,
//!     `chore/` become collapsible folders). Click a branch →
//!     checkout. Right-click → context menu (delete / rename /
//!     merge / rebase…).
//!   - REMOTE: remote branches. Same shape; click → checkout +
//!     track.
//!   - WORKTREES: `git worktree list` entries with a marker on the
//!     current worktree.
//!   - PRS: open PRs for the active repo (`git_rail.pulls`).
//!   - STASHES: `git stash list` (v2 — needs a new query).
//!   - TAGS: `git tag` (v2 — needs a new query).
//!
//! MVP (this commit) ships: Header + LOCAL + WORKTREES + PRS. The
//! data is already populated on `app.git_rail`. Remote split,
//! folder grouping, stashes, tags, and a filter input land in
//! follow-up commits.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

/// Paint the git palette into `area`. Called from `ui::mod` when
/// `app.active_section == ActivitySection::Git`.
pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }

    // Cursor / click rect tracking — each rendered row pushes a hit
    // entry so the mouse handler can resolve a click to the right
    // action. Cleared on entry so the previous frame's rects don't
    // steal clicks at cells we're no longer painting.
    app.rects.git_palette_rows.clear();

    let mut y = area.y;
    let snap = app.git.snapshot().clone();

    // ── repo header ───────────────────────────────────────────
    let repo_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("repo")
        .to_string();
    let header_line = Line::from(vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(
            repo_name,
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(header_line),
        Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        },
    );
    y += 1;

    // Branch + ahead/behind row.
    let branch = snap
        .branch
        .clone()
        .unwrap_or_else(|| "(no branch)".to_string());
    let mut spans = vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled("⎇ ", Style::default().fg(t.purple).bg(bg)),
        Span::styled(
            branch.clone(),
            Style::default().fg(t.fg).bg(bg).add_modifier(Modifier::BOLD),
        ),
    ];
    if snap.ahead > 0 {
        spans.push(Span::styled(
            format!("  ↑{}", snap.ahead),
            Style::default().fg(t.green).bg(bg),
        ));
    }
    if snap.behind > 0 {
        spans.push(Span::styled(
            format!("  ↓{}", snap.behind),
            Style::default().fg(t.orange).bg(bg),
        ));
    }
    frame.render_widget(
        Paragraph::new(Line::from(spans)),
        Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        },
    );
    y += 1;

    // 1-row separator before sections start.
    y += 1;

    // ── LOCAL section ─────────────────────────────────────────
    if y < area.y + area.height {
        y = draw_section_header(
            frame,
            app,
            area,
            y,
            "LOCAL",
            app.git_rail.branches.len(),
            bg,
        );
    }
    for (i, br) in app.git_rail.branches.iter().enumerate() {
        if y >= area.y + area.height {
            break;
        }
        let marker = if br.is_current { "●" } else { "○" };
        let marker_color = if br.is_current { t.green } else { t.fg };
        let name_style = Style::default()
            .fg(t.fg)
            .bg(bg)
            .add_modifier(if br.is_current {
                Modifier::BOLD
            } else {
                Modifier::empty()
            });
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled("   ", Style::default().bg(bg)),
            Span::styled(marker, Style::default().fg(marker_color).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(br.name.clone(), name_style),
        ]);
        frame.render_widget(Paragraph::new(line), row_rect);
        app.rects
            .git_palette_rows
            .push((row_rect, GitPaletteHit::Branch(i)));
        y += 1;
    }

    // 1-row gap between sections.
    if y < area.y + area.height {
        y += 1;
    }

    // ── WORKTREES section ─────────────────────────────────────
    if !app.git_rail.worktrees.is_empty() && y < area.y + area.height {
        y = draw_section_header(
            frame,
            app,
            area,
            y,
            "WORKTREES",
            app.git_rail.worktrees.len(),
            bg,
        );
        for (i, wt) in app.git_rail.worktrees.iter().enumerate() {
            if y >= area.y + area.height {
                break;
            }
            let marker = if wt.is_current { "⤿" } else { "·" };
            let marker_color = if wt.is_current { t.yellow } else { t.fg };
            let label = if wt.label.is_empty() {
                "(detached)".to_string()
            } else {
                wt.label.clone()
            };
            let dir = wt
                .path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("?")
                .to_string();
            let shown = if label == dir || label.starts_with('(') {
                label.clone()
            } else {
                format!("{label} ({dir})")
            };
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            let line = Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(marker, Style::default().fg(marker_color).bg(bg)),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    shown,
                    Style::default().fg(t.fg).bg(bg).add_modifier(
                        if wt.is_current {
                            Modifier::BOLD
                        } else {
                            Modifier::empty()
                        },
                    ),
                ),
            ]);
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects
                .git_palette_rows
                .push((row_rect, GitPaletteHit::Worktree(i)));
            y += 1;
        }
        if y < area.y + area.height {
            y += 1;
        }
    }

    // ── PRS section ───────────────────────────────────────────
    if !app.git_rail.pulls.is_empty() && y < area.y + area.height {
        y = draw_section_header(
            frame,
            app,
            area,
            y,
            "PULL REQUESTS",
            app.git_rail.pulls.len(),
            bg,
        );
        for (i, pr) in app.git_rail.pulls.iter().enumerate() {
            if y >= area.y + area.height {
                break;
            }
            let host_color = match pr.host_tag {
                "BB" => t.blue,
                "GH" => t.fg,
                "GL" => t.orange,
                "AZ" => t.cyan,
                _ => t.fg,
            };
            let marker = if pr.is_current_branch { "●" } else { "○" };
            // Title fits the remaining width after `   ● #1234 `.
            let width = area.width as usize;
            let pre_w = 3 + 1 + 1 + pr.number_label.chars().count() + 1;
            let title_max = width.saturating_sub(pre_w);
            let title_disp = if pr.title.chars().count() > title_max {
                let mut s: String = pr.title.chars().take(title_max.saturating_sub(1)).collect();
                s.push('…');
                s
            } else {
                pr.title.clone()
            };
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            let line = Line::from(vec![
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(marker, Style::default().fg(host_color).bg(bg)),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    pr.number_label.clone(),
                    Style::default().fg(host_color).bg(bg),
                ),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    title_disp,
                    Style::default().fg(t.fg).bg(bg).add_modifier(
                        if pr.is_current_branch {
                            Modifier::BOLD
                        } else {
                            Modifier::empty()
                        },
                    ),
                ),
            ]);
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects
                .git_palette_rows
                .push((row_rect, GitPaletteHit::Pull(i)));
            y += 1;
        }
    }
}

/// Paint a section header (`LOCAL`, `WORKTREES`, …) with a count
/// chip on the right. Returns the next-y to draw at.
fn draw_section_header(
    frame: &mut Frame,
    _app: &mut App,
    area: Rect,
    y: u16,
    label: &str,
    count: usize,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let count_str = format!("{count}");
    let label_w = label.chars().count();
    let count_w = count_str.chars().count();
    let pad = (area.width as usize)
        .saturating_sub(1 + label_w + 1 + count_w + 1);
    let line = Line::from(vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(
            label.to_string(),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        Span::styled(count_str, Style::default().fg(t.cyan).bg(bg)),
        Span::styled(" ", Style::default().bg(bg)),
    ]);
    frame.render_widget(
        Paragraph::new(line),
        Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        },
    );
    y + 1
}

/// Per-row click target: which kind of row was hit + its index
/// into the underlying `git_rail` collection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitPaletteHit {
    Branch(usize),
    Worktree(usize),
    Pull(usize),
}
