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
    app.rects.git_palette_refresh_chip = None;
    app.rects.git_palette_section_headers.clear();
    app.rects.git_palette_folder_headers.clear();
    // qa-feature 2026-06-30 — clear BEFORE rendering so the
    // (possibly stale) rect from a previous frame doesn't survive
    // when the palette stops rendering (e.g. user switched to a
    // different activity section). The previous clear-in-ui::mod
    // ran AFTER this draw() — silently wiping my own rect.
    app.rects.git_graph_repo_switch = None;

    // ── "GIT" caps header — activity-bar panels each carry a
    // caps-name header (SESSIONS / FINDINGS / TODOS / …). The
    // shared `panel_chrome::draw_caps_header_with_refresh` also
    // paints the right-aligned ↻ chip that re-runs `git status`
    // + branch/tag enumeration.
    let ascii = app.config.ui.ascii_icons;
    let y = area.y;
    app.rects.git_palette_refresh_chip = crate::ui::panel_chrome::draw_caps_header_with_refresh(
        frame,
        Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        },
        "GIT",
        // R16 (2026-08-24) — no top-level count-in-parens: GIT is a
        // multi-section panel (LOCAL / REMOTE / WORKTREES / PRS /
        // STASHES / TAGS) and each section already carries its own
        // count below. A single top-level `(N)` would be ambiguous.
        None,
        bg,
        &t,
        ascii,
    );
    let mut y = y + 1;
    let snap = app.git.snapshot().clone();
    // Lower-cased filter for case-insensitive substring matching
    // throughout the palette.
    let filter_lc = app.git_palette_filter.to_ascii_lowercase();
    let matches_filter =
        |s: &str| -> bool { filter_lc.is_empty() || s.to_ascii_lowercase().contains(&filter_lc) };

    // #1229 — scroll by trimming the front of each section's item list,
    // in draw order (WORKTREES → LOCAL → REMOTE → PRS → STASHES → TAGS).
    // `enumerate()` runs BEFORE the skip everywhere below, so the `i`
    // that feeds each click-rect hit id stays the index into the
    // UNTRIMMED list — a scrolled row must still act on the right branch.
    // Total item rows across every section, and the clamp. Without the
    // clamp a wheel spin past the end would scroll the panel blank —
    // "scrolled into no man's land", the same failure mode as #1237's
    // PageDown-past-EOF.
    //
    // Filters applied, since a filtered panel has fewer rows to scroll.
    let total_items = app
        .git_rail
        .branches
        .iter()
        .filter(|b| matches_filter(&b.name))
        .count()
        + app
            .git_rail
            .remote_branches
            .iter()
            .filter(|r| matches_filter(r))
            .count()
        + app.git_rail.worktrees.len()
        + app.git_rail.pulls.len()
        + app.git_rail.stashes.len()
        + app.git_rail.tags.len();
    // Rows the body can show, minus the caps header and filter row. Used
    // for the scrollbar's viewport ratio.
    let body_rows = area.height.saturating_sub(2) as usize;
    // The clamp stops one short of the end, NOT one viewport short.
    //
    // First cut used `total_items - body_rows`, reasoning that it would
    // "only ever leave more on screen". That was wrong in the way that
    // matters: section headers and inter-section gaps also consume rows,
    // so fewer than `body_rows` items fit — and the tail of the last
    // section stayed unreachable, which is the exact bug being fixed.
    // Caught by `scrolling_reveals_rows_that_were_off_the_bottom`.
    //
    // Allowing scroll up to the last item can leave a sparse view at the
    // very bottom. That is the standard trade (every list view does it)
    // and far better than items you cannot reach at all.
    let max_scroll = total_items.saturating_sub(1);
    if app.git_palette_scroll > max_scroll {
        app.git_palette_scroll = max_scroll;
    }

    let mut skip_budget = app.git_palette_scroll;
    let mut take_skip = move |n: usize| -> usize {
        let k = skip_budget.min(n);
        skip_budget -= k;
        k
    };

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
    let pill_text = format!(" {repo_name} \u{F0140} ");
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
        let bg_chip = crate::ui::panel_chrome::filter_chip_bg(&t);
        let fg_chip = if app.git_palette_filter.is_empty() && !focused {
            t.comment
        } else {
            t.fg
        };
        // 2026-08-23 user ask — normalize filter placeholder to
        // the two-state pattern used by http/agents/todos/notes/
        // sessions/findings/integrations/menu-bar/settings:
        //   unfocused-empty → "/ filter"
        //   focused-empty   → "type to filter…"
        // Consistent verbiage across every activity-bar section.
        let filter_text = if app.git_palette_filter.is_empty() {
            crate::ui::filter_placeholder::for_state(focused).to_string()
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
            Span::styled(
                format!("{} ", crate::ui::search_glyph::NERD),
                Style::default().fg(t.comment).bg(bg_chip),
            ),
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

    // ── WORKTREES section ─────────────────────────────────────
    // qa-feature 2026-06-30 — moved above LOCAL. Worktrees are
    // navigational (current work context) so they deserve top
    // billing over the branch list.
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
            let skip_n = take_skip(app.git_rail.worktrees.len());
            for (i, wt) in app.git_rail.worktrees.iter().enumerate().skip(skip_n) {
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
                // qa-feature 2026-06-30 — `⌂` (house) reads as
                // "you are here" for the current worktree; less
                // ambiguous than the arrow-in-circle `⤿` glyph
                // it replaced.
                let marker = if wt.is_current { "⌂" } else { "·" };
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
        }
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
    // #1229 — the header must report the FULL count, not the trimmed one.
    // User report: "i see the count next to remote decrease but its
    // collapsed it shouldnt reduce on scroll".
    let local_collapsed = app.git_palette_collapsed_sections.contains("LOCAL");
    let local_total = local_filtered.len();
    // #1229 — scroll. Each tuple keeps its ORIGINAL branch index, so a
    // trimmed list still resolves clicks correctly.
    //
    // A COLLAPSED section consumes no scroll budget: none of its rows are
    // on screen, so scrolling "past" them would burn the budget on
    // nothing and the panel would appear not to scroll at all.
    let local_filtered = if local_collapsed {
        local_filtered
    } else {
        let k = take_skip(local_filtered.len());
        local_filtered.into_iter().skip(k).collect::<Vec<_>>()
    };
    if y < area.y + area.height && !local_filtered.is_empty() {
        y = draw_section_header(frame, app, area, y, "LOCAL", local_total, bg);
    }
    // qa-feature 2026-06-30 — skip body when LOCAL collapsed.
    // The trailing "1-row gap between sections" below handles the
    // spacer; no extra add here (was doubling the gap on collapsed
    // LOCAL — visible as a bigger gap than WORKTREES/REMOTE/etc.).
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
                // Paint the row bg first when selected so the highlight
                // extends past the rendered text to the right edge — but
                // INSET BY ONE CELL on the left.
                //
                // #1229 (user report) — the highlight used to start at
                // `area.x`, i.e. the column immediately right of the
                // activity bar, so a selected branch read as "stuck onto
                // the activity bar". Same bug tree_view fixed under #970
                // f/u (2026-08-20); this panel never got the treatment.
                // The activity-bar-adjacent column is off limits: it
                // always keeps the panel's own bg.
                //
                // Only the FIRST cell is given up, matching the #970
                // follow-up where pulling two cells looked over-trimmed.
                // `row_rect` itself is unchanged so the click target
                // still covers the full row.
                if is_selected {
                    let hl = Rect {
                        x: row_rect.x.saturating_add(1),
                        y: row_rect.y,
                        width: row_rect.width.saturating_sub(1),
                        height: 1,
                    };
                    frame.render_widget(Block::default().style(Style::default().bg(bg)), row_rect);
                    frame.render_widget(Block::default().style(Style::default().bg(row_bg)), hl);
                }
                // Leading cell of the indent keeps the PANEL bg so the
                // highlight cannot touch the activity bar; the rest of
                // the indent carries the row bg.
                let (indent_head, indent_tail) = indent_branch
                    .char_indices()
                    .nth(1)
                    .map(|(i, _)| indent_branch.split_at(i))
                    .unwrap_or((indent_branch, ""));
                let line = Line::from(vec![
                    Span::styled(indent_head, Style::default().bg(bg)),
                    Span::styled(indent_tail, Style::default().bg(row_bg)),
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
    let remote_total = remote_filtered_idxs_and_names.len();
    let remote_filtered_idxs_and_names = if app.git_palette_collapsed_sections.contains("REMOTE") {
        remote_filtered_idxs_and_names
    } else {
        let k = take_skip(remote_filtered_idxs_and_names.len());
        remote_filtered_idxs_and_names
            .into_iter()
            .skip(k)
            .collect::<Vec<_>>()
    };
    if !remote_filtered_idxs_and_names.is_empty() && y < area.y + area.height {
        y = draw_section_header(frame, app, area, y, "REMOTE", remote_total, bg);
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
                        // qa-feature 2026-06-30 — `☁` (cloud) is
                        // the universal glyph for a remote; the
                        // previous `⎈` (helm) read as a snowflake
                        // in this font.
                        Span::styled("☁ ", Style::default().fg(t.blue).bg(bg)),
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
            let skip_n = take_skip(app.git_rail.pulls.len());
            for (i, pr) in app.git_rail.pulls.iter().enumerate().skip(skip_n) {
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
            let skip_n = take_skip(app.git_rail.stashes.len());
            for (i, st) in app.git_rail.stashes.iter().enumerate().skip(skip_n) {
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
            let skip_n = take_skip(app.git_rail.tags.len());
            for (i, tag) in app.git_rail.tags.iter().enumerate().skip(skip_n) {
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

    // #1229 — scrollbar, painted last so it sits on top of the rows'
    // right-edge padding. Only when the panel actually overflows: a
    // permanent gutter on a short list is noise, and the user asked for
    // it precisely as an overflow signal — "we should probably show
    // scrollbar if there are items out of view".
    //
    // Overpaints the rightmost body column rather than reserving one.
    // Reserving would mean narrowing every row in an ~800-line draw
    // function; the rows already pad to full width with the panel bg, so
    // the last column is padding in practice.
    if total_items > body_rows && area.width >= 4 && area.height > 2 {
        let sb = Rect {
            x: area.x + area.width - 1,
            y: area.y + 2,
            width: 1,
            height: area.height.saturating_sub(2),
        };
        crate::ui::scrollbar::paint_simple_scrollbar(
            frame,
            sb,
            &t,
            total_items,
            body_rows,
            app.git_palette_scroll,
        );
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb,
            pane_id: 0,
            total: total_items,
            viewport: body_rows,
            kind: crate::app::ScrollbarKind::GitPalette,
        });
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

    /// Seed a rail with more rows than any sane panel height, so the
    /// panel genuinely overflows.
    #[allow(clippy::type_complexity)]
    fn app_with_a_long_rail() -> (tempfile::TempDir, App, std::sync::MutexGuard<'static, ()>) {
        // #1229 f/u — hold the env lock and pin the collapse state.
        //
        // Without this, `App::new` picked up the developer's REAL session
        // and config: on my machine REMOTE happened to be collapsed, which
        // changed how the scroll budget was spent and failed two of these
        // tests for reasons unrelated to the code under test. A render test
        // that reads ambient user state is not a test. Same class as the
        // 141 unguarded `App::new` sites noted in a1636035.
        let lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let _ = std::fs::create_dir(d.path().join(".git"));
        let mut app = App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        // Every section expanded, explicitly — the scroll budget's
        // distribution across sections depends on it.
        app.git_palette_collapsed_sections.clear();
        app.active_section = crate::app::ActivitySection::Git;
        app.git_rail.branches = (0..14)
            .map(|i| crate::git::rail::BranchRow {
                name: format!("branch-{i:02}"),
                is_current: i == 0,
            })
            .collect();
        app.git_rail.remote_branches = (0..10).map(|i| format!("origin/rb-{i:02}")).collect();
        app.git_rail.tags = (0..29).map(|i| format!("v0.{i}.0")).collect();
        app.git_rail.current_branch = Some("branch-00".to_string());
        (d, app, lk)
    }

    fn render(app: &mut App, w: u16, h: u16) -> Vec<String> {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            draw(
                f,
                app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect()
    }

    /// #1229 — SAFETY NET for the scroll retrofit. At offset 0 the panel
    /// must render exactly as it did before scrolling existed. Captured
    /// against the pre-refactor implementation; if a later change to the
    /// scroll plumbing shifts the unscrolled view, this fails.
    #[test]
    fn the_unscrolled_panel_still_starts_with_the_git_header_and_first_rows() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        let rows = render(&mut app, 28, 20);
        assert!(rows[0].contains("GIT"), "row0: {:?}", rows[0]);
        // The first branch must be on screen and the LAST tag must not —
        // that is what makes this a meaningful overflow fixture.
        let joined = rows.join("\n");
        assert!(
            joined.contains("branch-00"),
            "first branch missing:\n{joined}"
        );
        assert!(
            !joined.contains("v0.28.0"),
            "the fixture does not actually overflow — nothing to scroll:\n{joined}"
        );
    }

    /// #1229 f/u — user report: "when remote section is collapsed and i
    /// scroll i see the count next to remote decrease but its collapsed
    /// it shouldnt reduce on scroll as its collapsed".
    ///
    /// Two distinct bugs behind that one sentence, and this pins both.
    /// #1229 f/u — the OTHER half of the count bug, which the collapsed
    /// case cannot observe.
    ///
    /// The user saw a collapsed REMOTE's count fall while scrolling. The
    /// direct cause was that collapsed sections were being trimmed at all
    /// (fixed separately) — but the header ALSO read its count from the
    /// trimmed list, which is wrong for an EXPANDED section too: a section
    /// header states how many branches the repo has, not how many survived
    /// the viewport. That is invisible in the collapsed case, because an
    /// untrimmed list's length already equals the total.
    #[test]
    fn an_expanded_sections_count_is_the_repo_total_not_the_visible_rows() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        // LOCAL expanded (the default) with 14 branches.
        let unscrolled = render(&mut app, 28, 20).join("\n");
        assert!(
            unscrolled
                .lines()
                .any(|l| l.contains("LOCAL") && l.contains("14")),
            "setup: LOCAL should report 14:\n{unscrolled}"
        );

        // Scroll into the middle of LOCAL — its header stays on screen
        // because headers are always drawn.
        app.git_palette_scroll = 6;
        let scrolled = render(&mut app, 28, 20).join("\n");
        let local_line = scrolled
            .lines()
            .find(|l| l.contains("LOCAL"))
            .unwrap_or("")
            .to_string();
        assert!(
            local_line.contains("14"),
            "LOCAL's count fell to the visible-row count while scrolling: \
             {local_line:?}"
        );
        // And prove the scroll actually happened, or the assertion above
        // is trivially satisfied.
        assert!(
            !scrolled.contains("branch-00"),
            "nothing scrolled, so the count assertion proves nothing:\n{scrolled}"
        );
    }

    #[test]
    fn a_collapsed_sections_count_is_stable_and_it_eats_no_scroll() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        // Both collapsed: LOCAL so REMOTE's header is on screen at all,
        // REMOTE because it is what the user reported.
        app.git_palette_collapsed_sections
            .insert("LOCAL".to_string());
        app.git_palette_collapsed_sections
            .insert("REMOTE".to_string());

        let unscrolled = render(&mut app, 28, 20).join("\n");
        assert!(
            unscrolled
                .lines()
                .any(|l| l.contains("REMOTE") && l.contains("10")),
            "collapsed REMOTE should report its full count of 10:\n{unscrolled}"
        );

        // MUST exceed LOCAL's 14 items, or the scroll budget never reaches
        // REMOTE and neither half of this test can fail. An earlier
        // version used 12 and was vacuous — it passed with both bugs
        // deliberately reintroduced.
        app.git_palette_scroll = 20;
        let scrolled = render(&mut app, 28, 20).join("\n");

        // (1) The count is a property of the repo, not the viewport. With
        // the bug, LOCAL would eat 14 and REMOTE 6, so this read "4".
        let remote_line = scrolled
            .lines()
            .find(|l| l.contains("REMOTE"))
            .unwrap_or("")
            .to_string();
        assert!(
            remote_line.contains("10"),
            "collapsed REMOTE's count changed on scroll: {remote_line:?}"
        );

        // (2) Collapsed sections consume no budget, so all 20 rows of
        // scroll land on TAGS and the view starts at v0.20.0. With the
        // bug, LOCAL+REMOTE would swallow all 20 and TAGS would still
        // start at v0.0.0 — so assert the SPECIFIC tag, not just "a tag".
        assert!(
            scrolled.contains("v0.20.0"),
            "hidden rows of collapsed sections are still eating the scroll \
             budget — TAGS did not advance:\n{scrolled}"
        );
        assert!(
            !scrolled.contains("v0.0.0"),
            "TAGS is still showing its first row, so nothing scrolled:\n{scrolled}"
        );
    }

    /// #1229 — the reported bug: "i have no way to scroll down to see
    /// more branches or tags if they go too long". With 29 tags the last
    /// ones were simply unreachable.
    #[test]
    fn scrolling_reveals_rows_that_were_off_the_bottom() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        let before = render(&mut app, 28, 20).join("\n");
        assert!(
            !before.contains("v0.20.0") && !before.contains("v0.28.0"),
            "fixture must start with the tag tail off-screen:\n{before}"
        );

        // Mid-scroll: rows that were off the bottom come into view and the
        // top rows leave.
        app.git_palette_scroll = 40;
        let mid = render(&mut app, 28, 20).join("\n");
        assert!(
            mid.contains("v0.20.0"),
            "scrolling did not reveal rows that were off the bottom:\n{mid}"
        );
        assert!(
            !mid.contains("branch-00"),
            "the first branch is still on screen, so nothing scrolled:\n{mid}"
        );

        // And the LAST item must be reachable. This is the actual promise
        // — a clamp that stops a viewport short of the end leaves the tail
        // permanently unreachable, which is the bug being fixed. The
        // over-large value is clamped by the render.
        app.git_palette_scroll = usize::MAX / 2;
        let end = render(&mut app, 28, 20).join("\n");
        assert!(
            end.contains("v0.28.0"),
            "the last tag is STILL unreachable at maximum scroll:\n{end}"
        );
    }

    /// Scrolling must not be able to run off the end and leave the panel
    /// blank — the same failure mode as #1237's PageDown-past-EOF.
    #[test]
    fn scroll_is_clamped_so_the_panel_never_goes_blank() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        app.git_palette_scroll = 100_000;
        let rows = render(&mut app, 28, 20);
        let joined = rows.join("\n");

        assert!(
            app.git_palette_scroll < 100_000,
            "scroll was not clamped: {}",
            app.git_palette_scroll
        );
        // Something from the LAST section must still be visible.
        assert!(
            joined.contains("v0.2") || joined.contains("v0.1"),
            "panel scrolled into empty space:\n{joined}"
        );
    }

    /// A scrolled row must still act on the right item. The hit ids come
    /// from `enumerate()` BEFORE the skip, so index 28 stays index 28.
    #[test]
    fn click_targets_survive_a_scroll() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        app.git_palette_scroll = 40;
        let _ = render(&mut app, 28, 20);

        let tag_hits: Vec<usize> = app
            .rects
            .git_palette_rows
            .iter()
            .filter_map(|(_, hit)| match hit {
                GitPaletteHit::Tag(i) => Some(*i),
                _ => None,
            })
            .collect();
        assert!(!tag_hits.is_empty(), "no tag rows rendered after scrolling");
        assert!(
            tag_hits.iter().any(|&i| i > 10),
            "tag hit ids look re-based after the skip ({tag_hits:?}) — a \
             scrolled row would open the wrong tag"
        );
    }

    /// The scrollbar is an overflow signal, so it must appear only when
    /// the panel actually overflows.
    #[test]
    fn the_scrollbar_appears_only_when_content_overflows() {
        let (_d, mut app, _lk) = app_with_a_long_rail();
        let _ = render(&mut app, 28, 20);
        assert!(
            app.rects
                .scrollbars
                .iter()
                .any(|sb| matches!(sb.kind, crate::app::ScrollbarKind::GitPalette)),
            "no scrollbar on a panel with 50+ items in 20 rows"
        );

        // Now a rail that fits.
        app.git_rail.branches.truncate(1);
        app.git_rail.remote_branches.clear();
        app.git_rail.tags.truncate(1);
        app.rects.scrollbars.clear();
        let _ = render(&mut app, 28, 20);
        assert!(
            !app.rects
                .scrollbars
                .iter()
                .any(|sb| matches!(sb.kind, crate::app::ScrollbarKind::GitPalette)),
            "scrollbar painted on a panel that fits — permanent gutter noise"
        );
    }

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
