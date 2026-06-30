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
    app.rects.git_palette_filter_input = None;
    app.rects.git_palette_section_headers.clear();
    app.rects.git_palette_folder_headers.clear();
    // qa-feature 2026-06-30 — clear BEFORE rendering so the
    // (possibly stale) rect from a previous frame doesn't survive
    // when the palette stops rendering (e.g. user switched to a
    // different activity section). The previous clear-in-ui::mod
    // ran AFTER this draw() — silently wiping my own rect.
    app.rects.git_graph_repo_switch = None;

    let mut y = area.y;
    let snap = app.git.snapshot().clone();
    // Lower-cased filter for case-insensitive substring matching
    // throughout the palette.
    let filter_lc = app.git_palette_filter.to_ascii_lowercase();
    let matches_filter =
        |s: &str| -> bool { filter_lc.is_empty() || s.to_ascii_lowercase().contains(&filter_lc) };

    // ── repo header ───────────────────────────────────────────
    // qa-feature 2026-06-30 — when the workspace contains multiple
    // repos, the active one (which the git pane is showing) is the
    // truthful label; falling back to the workspace name only when
    // there is no active repo.
    let repo_name = app
        .repos
        .get(app.active_repo)
        .map(|r| r.name.clone())
        .unwrap_or_else(|| {
            app.workspace
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("repo")
                .to_string()
        });
    // qa-feature 2026-06-30 — render the repo name as a clickable
    // pill `[ name ▾ ]` that opens the workspace picker. The whole
    // pill is the click target so a mis-click on the chevron still
    // triggers the action.
    let header_rect = Rect {
        x: area.x,
        y,
        width: area.width,
        height: 1,
    };
    let pill_text = format!(" {repo_name} ▾ ");
    let pill_w = pill_text.chars().count() as u16;
    let header_line = Line::from(vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(
            pill_text,
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(Paragraph::new(header_line), header_rect);
    // Click rect covers the whole pill (after the 1-cell leading
    // space). Capped at the header width so resizing the pane
    // narrower doesn't register a rect that runs off-screen.
    let pill_x = area.x.saturating_add(1);
    let pill_end = pill_x.saturating_add(pill_w).min(area.x + area.width);
    if pill_end > pill_x {
        app.rects.git_graph_repo_switch = Some(Rect {
            x: pill_x,
            y,
            width: pill_end - pill_x,
            height: 1,
        });
    }
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
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
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

    // 1-row separator before the filter input.
    y += 1;

    // ── filter input ──────────────────────────────────────────
    // A single-row text input prefixed with a magnifier glyph.
    // Click to focus + type → updates `git_palette_filter`. Esc
    // unfocuses + clears (handled in tui dispatch_key).
    if y < area.y + area.height {
        let focused = app.git_palette_filter_focused;
        let bg_chip = t.bg2;
        let fg_chip = if app.git_palette_filter.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        let filter_text = if app.git_palette_filter.is_empty() {
            "Filter…".to_string()
        } else {
            app.git_palette_filter.clone()
        };
        let max_text = (area.width as usize).saturating_sub(5);
        let display = if filter_text.chars().count() > max_text {
            let mut s: String = filter_text
                .chars()
                .skip(filter_text.chars().count() - max_text)
                .collect();
            s.insert(0, '…');
            s
        } else {
            filter_text
        };
        let cursor = if focused { "▏" } else { " " };
        let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled("\u{F0349} ", Style::default().fg(t.comment).bg(bg_chip)),
            Span::styled(display, Style::default().fg(fg_chip).bg(bg_chip)),
            Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_chip)),
            Span::styled(" ".repeat(pad), Style::default().bg(bg_chip)),
            Span::styled(" ", Style::default().bg(bg)),
        ]);
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(line), row_rect);
        app.rects.git_palette_filter_input = Some(row_rect);
        y += 1;
    }

    // 1-row separator before sections start.
    if y < area.y + area.height {
        y += 1;
    }

    // ── LOCAL section ─────────────────────────────────────────
    // Pre-filter local branches before grouping so empty folder
    // rows don't appear when the filter excludes all their items.
    // Cloning the names avoids holding an immutable borrow on
    // `app.git_rail.branches` while we later mutate `app.rects`.
    let local_filtered: Vec<(usize, String)> = app
        .git_rail
        .branches
        .iter()
        .enumerate()
        .filter(|(_, b)| matches_filter(&b.name))
        .map(|(i, b)| (i, b.name.clone()))
        .collect();
    if y < area.y + area.height && !local_filtered.is_empty() {
        y = draw_section_header(frame, app, area, y, "LOCAL", local_filtered.len(), bg);
    }
    // qa-feature 2026-06-30 — skip body when LOCAL collapsed.
    let local_collapsed = app.git_palette_collapsed_sections.contains("LOCAL");
    if local_collapsed {
        // Add the gap between sections so the next header doesn't
        // butt up against this one.
        if y < area.y + area.height {
            y += 1;
        }
    }
    // Folder-group local branches by their `/` prefix so a repo
    // with `bugfix/*`, `chore/*`, `feature/*` collapses into a
    // few folder rows instead of dumping 50+ branches flat.
    let local_filtered_names: Vec<&str> = local_filtered.iter().map(|(_, n)| n.as_str()).collect();
    let local_groups_indirect = group_by_folder(&local_filtered_names);
    // Re-map the inner indices from "index into filtered list" →
    // "index into git_rail.branches".
    let local_groups: Vec<(String, Vec<usize>)> = local_groups_indirect
        .into_iter()
        .map(|(folder, inner_idxs)| {
            (
                folder,
                inner_idxs
                    .into_iter()
                    .map(|inner| local_filtered[inner].0)
                    .collect(),
            )
        })
        .collect();
    if !local_collapsed {
        for (folder, idxs) in &local_groups {
            if y >= area.y + area.height {
                break;
            }
            let folder_collapsed = !folder.is_empty()
                && app
                    .git_palette_collapsed_folders
                    .contains(&format!("LOCAL:{folder}"));
            let indent_branch = if folder.is_empty() {
                "   "
            } else {
                // Folder header row, e.g. `▾ bugfix (2)`.
                let chev = if folder_collapsed { "▸ " } else { "▾ " };
                let folder_line = Line::from(vec![
                    Span::styled("  ", Style::default().bg(bg)),
                    Span::styled(chev, Style::default().fg(t.comment).bg(bg)),
                    Span::styled(folder.clone(), Style::default().fg(t.fg).bg(bg)),
                    Span::styled(
                        format!("  ({})", idxs.len()),
                        Style::default().fg(t.comment).bg(bg),
                    ),
                ]);
                let folder_rect = Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                };
                frame.render_widget(Paragraph::new(folder_line), folder_rect);
                app.rects
                    .git_palette_folder_headers
                    .push((folder_rect, format!("LOCAL:{folder}")));
                y += 1;
                if folder_collapsed {
                    continue;
                }
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
                // qa-feature 2026-06-30 — highlight the row when its
                // name matches `git_palette_selected` (the last
                // clicked ref). Provides visual feedback for what's
                // currently selected in the palette.
                let is_selected = app
                    .git_palette_selected
                    .as_ref()
                    .is_some_and(|s| s == &br.name);
                let row_bg = if is_selected { t.bg2 } else { bg };
                let name_style =
                    Style::default()
                        .fg(t.fg)
                        .bg(row_bg)
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
                // Paint the whole row bg first when selected so the
                // highlight extends past the rendered text to the
                // right edge.
                if is_selected {
                    frame.render_widget(
                        Block::default().style(Style::default().bg(row_bg)),
                        row_rect,
                    );
                }
                let line = Line::from(vec![
                    Span::styled(indent_branch, Style::default().bg(row_bg)),
                    Span::styled(marker, Style::default().fg(marker_color).bg(row_bg)),
                    Span::styled(" ", Style::default().bg(row_bg)),
                    Span::styled(display_name, name_style),
                ]);
                frame.render_widget(Paragraph::new(line), row_rect);
                app.rects
                    .git_palette_rows
                    .push((row_rect, GitPaletteHit::Branch(i)));
                y += 1;
            }
        }
    } // end if !local_collapsed

    // 1-row gap between sections.
    if y < area.y + area.height {
        y += 1;
    }

    // ── REMOTE section ────────────────────────────────────────
    // Pre-filter remote branches (filter applies to the full
    // remote ref, including the `origin/` host prefix). Collect
    // owned data so the rest of the section doesn't keep an
    // immutable borrow on `app.git_rail.remote_branches` while
    // we mutate `app.rects` to push click rects.
    let remote_filtered_idxs_and_names: Vec<(usize, String)> = app
        .git_rail
        .remote_branches
        .iter()
        .enumerate()
        .filter(|(_, r)| matches_filter(r))
        .map(|(i, r)| (i, r.clone()))
        .collect();
    if !remote_filtered_idxs_and_names.is_empty() && y < area.y + area.height {
        y = draw_section_header(
            frame,
            app,
            area,
            y,
            "REMOTE",
            remote_filtered_idxs_and_names.len(),
            bg,
        );
        if app.git_palette_collapsed_sections.contains("REMOTE") {
            if y < area.y + area.height {
                y += 1;
            }
        } else {
            // Same folder grouping shape as LOCAL — remotes like
            // `origin/bugfix/foo` collapse under `bugfix/` after the
            // `origin/` prefix is stripped.
            let remote_stripped: Vec<String> = remote_filtered_idxs_and_names
                .iter()
                .map(|(_, r)| {
                    if let Some(slash) = r.find('/') {
                        r[slash + 1..].to_string()
                    } else {
                        r.clone()
                    }
                })
                .collect();
            let stripped_refs: Vec<&str> = remote_stripped.iter().map(|s| s.as_str()).collect();
            let remote_groups_indirect = group_by_folder(&stripped_refs);
            let remote_groups: Vec<(String, Vec<usize>)> = remote_groups_indirect
                .into_iter()
                .map(|(folder, inner_idxs)| {
                    (
                        folder,
                        inner_idxs
                            .into_iter()
                            .map(|inner| remote_filtered_idxs_and_names[inner].0)
                            .collect(),
                    )
                })
                .collect();
            for (folder, idxs) in &remote_groups {
                if y >= area.y + area.height {
                    break;
                }
                let indent = if folder.is_empty() {
                    "   "
                } else {
                    let folder_line = Line::from(vec![
                        Span::styled("  ", Style::default().bg(bg)),
                        Span::styled("▾ ", Style::default().fg(t.comment).bg(bg)),
                        Span::styled(folder.clone(), Style::default().fg(t.fg).bg(bg)),
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
                    // Strip the host prefix (`origin/`, `upstream/`)
                    // for display, then optionally strip the folder
                    // prefix too.
                    let stripped = full
                        .find('/')
                        .map(|s| &full[s + 1..])
                        .unwrap_or(full.as_str());
                    let display = if folder.is_empty() {
                        stripped.to_string()
                    } else {
                        stripped
                            .strip_prefix(&format!("{folder}/"))
                            .unwrap_or(stripped)
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
                        Span::styled(display, Style::default().fg(t.fg).bg(bg)),
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
        } // end !collapsed REMOTE
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
        if app.git_palette_collapsed_sections.contains("WORKTREES") {
            if y < area.y + area.height {
                y += 1;
            }
        } else {
            for (i, wt) in app.git_rail.worktrees.iter().enumerate() {
                if y >= area.y + area.height {
                    break;
                }
                let dir_match = wt
                    .path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(&matches_filter)
                    .unwrap_or(false);
                if !matches_filter(&wt.label) && !dir_match {
                    continue;
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
                        Style::default()
                            .fg(t.fg)
                            .bg(bg)
                            .add_modifier(if wt.is_current {
                                Modifier::BOLD
                            } else {
                                Modifier::empty()
                            }),
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
        } // end !collapsed WORKTREES
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
        if app.git_palette_collapsed_sections.contains("PULL REQUESTS") {
            if y < area.y + area.height {
                y += 1;
            }
        } else {
            for (i, pr) in app.git_rail.pulls.iter().enumerate() {
                if y >= area.y + area.height {
                    break;
                }
                if !matches_filter(&pr.title) && !matches_filter(&pr.number_label) {
                    continue;
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
                    let mut s: String =
                        pr.title.chars().take(title_max.saturating_sub(1)).collect();
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
                        Style::default()
                            .fg(t.fg)
                            .bg(bg)
                            .add_modifier(if pr.is_current_branch {
                                Modifier::BOLD
                            } else {
                                Modifier::empty()
                            }),
                    ),
                ]);
                frame.render_widget(Paragraph::new(line), row_rect);
                app.rects
                    .git_palette_rows
                    .push((row_rect, GitPaletteHit::Pull(i)));
                y += 1;
            }
            if y < area.y + area.height {
                y += 1;
            }
        } // end !collapsed PULL REQUESTS
    }

    // ── STASHES section ───────────────────────────────────────
    if !app.git_rail.stashes.is_empty() && y < area.y + area.height {
        y = draw_section_header(
            frame,
            app,
            area,
            y,
            "STASHES",
            app.git_rail.stashes.len(),
            bg,
        );
        if app.git_palette_collapsed_sections.contains("STASHES") {
            if y < area.y + area.height {
                y += 1;
            }
        } else {
            for (i, st) in app.git_rail.stashes.iter().enumerate() {
                if y >= area.y + area.height {
                    break;
                }
                if !matches_filter(&st.summary) {
                    continue;
                }
                // The summary is `WIP on branch: <hash> <message>`.
                // We display just the trailing message for compactness;
                // the full summary is in the row's hover tooltip target.
                let summary_short = st
                    .summary
                    .split_once(':')
                    .map(|(_, rest)| rest.trim().to_string())
                    .unwrap_or_else(|| st.summary.clone());
                let width = area.width as usize;
                let avail = width.saturating_sub(5);
                let display = if summary_short.chars().count() > avail {
                    let mut s: String = summary_short
                        .chars()
                        .take(avail.saturating_sub(1))
                        .collect();
                    s.push('…');
                    s
                } else {
                    summary_short
                };
                let row_rect = Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                };
                let line = Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled("◆ ", Style::default().fg(t.purple).bg(bg)),
                    Span::styled(display, Style::default().fg(t.fg).bg(bg)),
                ]);
                frame.render_widget(Paragraph::new(line), row_rect);
                app.rects
                    .git_palette_rows
                    .push((row_rect, GitPaletteHit::Stash(i)));
                y += 1;
            }
            if y < area.y + area.height {
                y += 1;
            }
        } // end !collapsed STASHES
    }

    // ── TAGS section ──────────────────────────────────────────
    if !app.git_rail.tags.is_empty() && y < area.y + area.height {
        y = draw_section_header(frame, app, area, y, "TAGS", app.git_rail.tags.len(), bg);
        // TAGS is the last section; if collapsed, no body and no
        // further y bookkeeping is needed (the trailing gap would
        // be off the bottom of the rail anyway).
        if !app.git_palette_collapsed_sections.contains("TAGS") {
            for (i, tag) in app.git_rail.tags.iter().enumerate() {
                if y >= area.y + area.height {
                    break;
                }
                if !matches_filter(tag) {
                    continue;
                }
                let row_rect = Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                };
                let line = Line::from(vec![
                    Span::styled("   ", Style::default().bg(bg)),
                    Span::styled("⊙ ", Style::default().fg(t.orange).bg(bg)),
                    Span::styled(tag.clone(), Style::default().fg(t.fg).bg(bg)),
                ]);
                frame.render_widget(Paragraph::new(line), row_rect);
                app.rects
                    .git_palette_rows
                    .push((row_rect, GitPaletteHit::Tag(i)));
                y += 1;
            }
        }
    }
}

/// Paint a section header (`LOCAL`, `WORKTREES`, …) with a count
/// chip on the right and a `▾`/`▸` chevron at the left signalling
/// collapse state. Click on the row toggles collapse — header rect
/// is pushed onto `app.rects.git_palette_section_headers`.
/// Returns the next-y to draw at.
fn draw_section_header(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    y: u16,
    label: &str,
    count: usize,
    bg: ratatui::style::Color,
) -> u16 {
    let t = theme::cur();
    let collapsed = app.git_palette_collapsed_sections.contains(label);
    let chev = if collapsed { "▸ " } else { "▾ " };
    let count_str = format!("{count}");
    let label_w = label.chars().count();
    let chev_w = chev.chars().count();
    let count_w = count_str.chars().count();
    let pad = (area.width as usize).saturating_sub(1 + chev_w + label_w + 1 + count_w + 1);
    let line = Line::from(vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(chev, Style::default().fg(t.comment).bg(bg)),
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
    let header_rect = Rect {
        x: area.x,
        y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(Paragraph::new(line), header_rect);
    app.rects
        .git_palette_section_headers
        .push((header_rect, label.to_string()));
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
    /// Stash — index into `git_rail.stashes`.
    Stash(usize),
    /// Tag — index into `git_rail.tags`.
    Tag(usize),
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
