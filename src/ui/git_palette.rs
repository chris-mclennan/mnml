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
    // Folder-group local branches by their `/` prefix so a repo
    // with `bugfix/*`, `chore/*`, `feature/*` collapses into a
    // few folder rows instead of dumping 50+ branches flat.
    let local_names: Vec<&str> = app
        .git_rail
        .branches
        .iter()
        .map(|b| b.name.as_str())
        .collect();
    let local_groups = group_by_folder(&local_names);
    for (folder, idxs) in &local_groups {
        if y >= area.y + area.height {
            break;
        }
        let indent_branch = if folder.is_empty() {
            "   "
        } else {
            // Folder header row, e.g. `▾ bugfix (2)`.
            let folder_line = Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "▾ ",
                    Style::default().fg(t.comment).bg(bg),
                ),
                Span::styled(
                    folder.clone(),
                    Style::default().fg(t.fg).bg(bg),
                ),
                Span::styled(
                    format!("  ({})", idxs.len()),
                    Style::default().fg(t.comment).bg(bg),
                ),
            ]);
            frame.render_widget(
                Paragraph::new(folder_line),
                Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                },
            );
            y += 1;
            "     " // 5-cell indent under folder
        };
        for &i in idxs {
            if y >= area.y + area.height {
                break;
            }
            let br = &app.git_rail.branches[i];
            let marker = if br.is_current { "●" } else { "○" };
            let marker_color = if br.is_current { t.green } else { t.fg };
            // Strip the folder/ prefix when inside a folder.
            let display_name = if folder.is_empty() {
                br.name.clone()
            } else {
                br.name
                    .strip_prefix(&format!("{folder}/"))
                    .unwrap_or(&br.name)
                    .to_string()
            };
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
                Span::styled(indent_branch, Style::default().bg(bg)),
                Span::styled(marker, Style::default().fg(marker_color).bg(bg)),
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(display_name, name_style),
            ]);
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects
                .git_palette_rows
                .push((row_rect, GitPaletteHit::Branch(i)));
            y += 1;
        }
    }

    // 1-row gap between sections.
    if y < area.y + area.height {
        y += 1;
    }

    // ── REMOTE section ────────────────────────────────────────
    if !app.git_rail.remote_branches.is_empty() && y < area.y + area.height {
        y = draw_section_header(
            frame,
            app,
            area,
            y,
            "REMOTE",
            app.git_rail.remote_branches.len(),
            bg,
        );
        // Same folder grouping shape as LOCAL — remotes like
        // `origin/bugfix/foo` collapse under `bugfix/` after the
        // `origin/` prefix is stripped.
        let remote_stripped: Vec<String> = app
            .git_rail
            .remote_branches
            .iter()
            .map(|r| {
                // Strip the first path component (`origin/`,
                // `upstream/`, etc.) so the folder grouping keys
                // off the meaningful prefix.
                if let Some(slash) = r.find('/') {
                    r[slash + 1..].to_string()
                } else {
                    r.clone()
                }
            })
            .collect();
        let stripped_refs: Vec<&str> = remote_stripped.iter().map(|s| s.as_str()).collect();
        let remote_groups = group_by_folder(&stripped_refs);
        for (folder, idxs) in &remote_groups {
            if y >= area.y + area.height {
                break;
            }
            let indent = if folder.is_empty() {
                "   "
            } else {
                let folder_line = Line::from(vec![
                    Span::styled("  ", Style::default().bg(bg)),
                    Span::styled(
                        "▾ ",
                        Style::default().fg(t.comment).bg(bg),
                    ),
                    Span::styled(
                        folder.clone(),
                        Style::default().fg(t.fg).bg(bg),
                    ),
                    Span::styled(
                        format!("  ({})", idxs.len()),
                        Style::default().fg(t.comment).bg(bg),
                    ),
                ]);
                frame.render_widget(
                    Paragraph::new(folder_line),
                    Rect {
                        x: area.x,
                        y,
                        width: area.width,
                        height: 1,
                    },
                );
                y += 1;
                "     "
            };
            for &i in idxs {
                if y >= area.y + area.height {
                    break;
                }
                let full = &app.git_rail.remote_branches[i];
                // The full string is what we'd checkout; the
                // display is the within-folder leaf.
                let display = if folder.is_empty() {
                    remote_stripped[i].clone()
                } else {
                    remote_stripped[i]
                        .strip_prefix(&format!("{folder}/"))
                        .unwrap_or(&remote_stripped[i])
                        .to_string()
                };
                let row_rect = Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                };
                let line = Line::from(vec![
                    Span::styled(indent, Style::default().bg(bg)),
                    Span::styled("⎈ ", Style::default().fg(t.blue).bg(bg)),
                    Span::styled(
                        display,
                        Style::default().fg(t.fg).bg(bg),
                    ),
                ]);
                let _ = full;
                frame.render_widget(Paragraph::new(line), row_rect);
                app.rects
                    .git_palette_rows
                    .push((row_rect, GitPaletteHit::RemoteBranch(i)));
                y += 1;
            }
        }
        if y < area.y + area.height {
            y += 1;
        }
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
    /// Remote branch — index into `git_rail.remote_branches`.
    RemoteBranch(usize),
    Worktree(usize),
    Pull(usize),
}

/// Group branch names by their `/` prefix into a tree:
///   - `"bugfix/foo"`  → folder `"bugfix"` containing `"foo"`
///   - `"main"`        → root entry `"main"`
///
/// Returns `(folder_name, indices_into_input)` pairs. Folder name
/// is empty (`""`) for root-level entries. Order: folders first
/// (alphabetical), then root entries (alphabetical).
fn group_by_folder(names: &[&str]) -> Vec<(String, Vec<usize>)> {
    use std::collections::BTreeMap;
    let mut folders: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    let mut roots: Vec<usize> = Vec::new();
    for (i, n) in names.iter().enumerate() {
        if let Some(slash) = n.find('/') {
            let folder = n[..slash].to_string();
            folders.entry(folder).or_default().push(i);
        } else {
            roots.push(i);
        }
    }
    let mut out: Vec<(String, Vec<usize>)> = folders.into_iter().collect();
    if !roots.is_empty() {
        out.push((String::new(), roots));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_by_folder_groups_prefixed_branches() {
        let names = vec!["main", "bugfix/foo", "bugfix/bar", "chore/x", "develop"];
        let groups = group_by_folder(&names);
        // Expected order: bugfix folder, chore folder, root (main, develop).
        let labels: Vec<&str> = groups.iter().map(|(l, _)| l.as_str()).collect();
        assert_eq!(labels, vec!["bugfix", "chore", ""]);
        // bugfix should contain indices 1, 2
        assert_eq!(groups[0].1, vec![1, 2]);
        assert_eq!(groups[1].1, vec![3]);
        // root has main (0) + develop (4) in input order
        assert_eq!(groups[2].1, vec![0, 4]);
    }

    #[test]
    fn group_by_folder_no_prefix_all_root() {
        let names = vec!["main", "develop"];
        let groups = group_by_folder(&names);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].0, "");
        assert_eq!(groups[0].1, vec![0, 1]);
    }
}
