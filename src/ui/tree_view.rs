//! The left rail. Two stacked sections, each with a collapsible header:
//!
//! * `> WORKSPACE-NAME` — the file tree (VS-Code Explorer-style).
//! * `> GIT` — local branches (`●` marks the current one) followed by linked
//!   worktrees (`⤿` marks the one we're in). Click a branch ⇒ checkout; click
//!   a worktree ⇒ open a shell pane there. Right-click for the per-row menu.
//!
//! The rail itself is independently toggled by `Ctrl+B` (`tree_visible`). Both
//! section-expand states are persisted in session.json.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::{App, RailSection};
use crate::focus::Focus;
use crate::git::rail::GitRailHit;
use crate::git::status::FileState;
use crate::ui::{icons, theme};

const CHEVRON_OPEN: &str = "\u{f107}"; //  (angle-down)
const CHEVRON_CLOSED: &str = "\u{f105}"; //  (angle-right)

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let rail_bg = theme::cur().bg_darker;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(rail_bg)), area);
    app.rects.tree = None;
    app.rects.tree_toggle = None;
    app.rects.git_section_toggle = None;
    app.rects.git_rail_rows.clear();
    app.rects.extra_workspace_bodies.clear();
    app.rects.extra_workspace_toggles.clear();
    if area.height == 0 || area.width == 0 {
        return;
    }

    let nerd = !app.config.ui.ascii_icons;
    let width = area.width as usize;
    if area.height < 2 {
        return;
    }

    // ── row 0: blank for breathing room above the first section header.
    // ── row 1: WORKSPACE header.
    let ws_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace")
        .to_string();
    let chev = section_chev(app.tree_root_expanded, nerd);
    // Leading space + chevron in muted grey + name in bold fg. The leading
    // space keeps the chevron off the rail's left border; coloring the
    // chevron with `comment` matches the row-level chevrons inside the
    // tree (so all `>` glyphs share one shade).
    let chev_str = format!(" {chev} ");
    let header_used = chev_str.chars().count() + ws_name.chars().count();
    let header_pad = width.saturating_sub(header_used);
    let header_rect = Rect {
        x: area.x,
        y: area.y + 1,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                chev_str,
                Style::default().fg(theme::cur().comment).bg(rail_bg),
            ),
            Span::styled(
                ws_name.clone(),
                Style::default()
                    .fg(theme::cur().fg)
                    .bg(rail_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ".repeat(header_pad), Style::default().bg(rail_bg)),
        ])),
        header_rect,
    );
    app.rects.tree_toggle = Some(header_rect);

    // ── workspace file list (only when expanded). Returns the row past the
    //    last one it drew, so the GIT section can render below.
    let mut next_y = area.y + 2;
    if app.tree_root_expanded && area.height >= 3 {
        next_y = draw_workspace_files(frame, app, area, next_y, nerd);
    }

    // ── extra workspace sections (from `[[workspaces]]` config). Each gets
    //    a blank separator + collapsible header; expanded sections show a
    //    bounded file-list slot below the header.
    for ws_idx in 0..app.extra_workspaces.len() {
        if next_y + 1 >= area.y + area.height {
            return;
        }
        next_y = draw_extra_workspace_section(frame, app, area, next_y, ws_idx, nerd);
    }

    // ── GIT section: blank separator + header. Skip if it'd run off the
    //    bottom — the rail's never tall enough is unusual but we don't want
    //    to paint past `area`.
    if next_y + 1 >= area.y + area.height {
        return;
    }
    let git_header_y = next_y + 1; // one blank row of breathing room
    if git_header_y >= area.y + area.height {
        return;
    }
    let chev = section_chev(app.git_section_expanded, nerd);
    // Multi-repo workspaces append `· <repo-name>` to the GIT header so
    // the user knows which repo the rail is currently scoped to. Single-
    // repo case keeps the bare "GIT" label.
    let multi_repo_chip = if app.repos.len() > 1 {
        app.repos
            .get(app.active_repo)
            .map(|r| format!("  · {}", r.name))
            .unwrap_or_default()
    } else {
        String::new()
    };
    let chev_str = format!(" {chev} ");
    let label_str = format!("GIT{multi_repo_chip}");
    let header_used = chev_str.chars().count() + label_str.chars().count();
    let header_pad = width.saturating_sub(header_used);
    let git_header_rect = Rect {
        x: area.x,
        y: git_header_y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                chev_str,
                Style::default().fg(theme::cur().comment).bg(rail_bg),
            ),
            Span::styled(
                label_str,
                Style::default()
                    .fg(theme::cur().fg)
                    .bg(rail_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ".repeat(header_pad), Style::default().bg(rail_bg)),
        ])),
        git_header_rect,
    );
    app.rects.git_section_toggle = Some(git_header_rect);

    if !app.git_section_expanded {
        return;
    }
    let body_y = git_header_y + 1;
    if body_y >= area.y + area.height {
        return;
    }
    draw_git_section(frame, app, area, body_y, nerd);
}

fn section_chev(expanded: bool, nerd: bool) -> &'static str {
    if expanded {
        if nerd { CHEVRON_OPEN } else { "▾" }
    } else if nerd {
        CHEVRON_CLOSED
    } else {
        "▸"
    }
}

/// Draw the WORKSPACE section's file list starting at `start_y`; returns the
/// row immediately past the last one drawn (so the GIT section follows on).
fn draw_workspace_files(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    start_y: u16,
    nerd: bool,
) -> u16 {
    let rail_bg = theme::cur().bg_darker;
    let width = area.width as usize;
    let avail = (area.y + area.height).saturating_sub(start_y);
    if avail == 0 {
        return start_y;
    }
    // The file list takes UP TO half the rail height when the GIT section is
    // expanded (so the rail doesn't become a wall of files crowding out git);
    // otherwise it can claim everything below it.
    let reserve_for_git = if app.git_section_expanded {
        let need = 2 + app.git_rail.row_count().min(8) as u16;
        need.min(avail.saturating_sub(2))
    } else {
        0
    };
    let h = (avail - reserve_for_git) as usize;
    if h == 0 {
        return start_y;
    }
    let mut inner = Rect {
        x: area.x,
        y: start_y,
        width: area.width,
        height: h as u16,
    };

    // Filter line — when the tree's in filter mode or has a sticky filter,
    // reserve the top row of the tree section for a `/ <query>` input.
    let show_filter = app.tree.filter_mode || !app.tree.filter.is_empty();
    if show_filter && inner.height >= 2 {
        let t = theme::cur();
        let cursor_glyph = if app.tree.filter_mode { "█" } else { "" };
        let line = Line::from(vec![
            Span::styled(" / ", Style::default().fg(t.yellow).bg(rail_bg)),
            Span::styled(
                app.tree.filter.clone(),
                Style::default().fg(t.fg).bg(rail_bg),
            ),
            Span::styled(
                cursor_glyph.to_string(),
                Style::default().fg(t.yellow).bg(rail_bg),
            ),
        ]);
        let filter_rect = Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(rail_bg)),
            filter_rect,
        );
        inner = Rect {
            x: inner.x,
            y: inner.y + 1,
            width: inner.width,
            height: inner.height - 1,
        };
    }
    app.rects.tree = Some(inner);
    let h = inner.height as usize;
    if h == 0 {
        return start_y + inner.height + if show_filter { 1 } else { 0 };
    }

    let rows = app.tree.visible_rows();
    let cursor = app.tree.cursor();

    if cursor < app.tree.scroll {
        app.tree.scroll = cursor;
    } else if cursor >= app.tree.scroll + h {
        app.tree.scroll = cursor + 1 - h;
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    app.tree.scroll = app.tree.scroll.min(max_scroll);
    app.rects.tree_scroll = app.tree.scroll;

    let git_files = &app.git.snapshot().files;
    let focused = app.focus == Focus::Tree && app.rail_section == RailSection::Workspace;

    // Pre-compute a per-row "is this a repo dir?" lookup for the multi-repo
    // case. Only check depth-0 dirs (sub-repos aren't supported by
    // discover_repos and matching wouldn't fire), and only when there's
    // more than one repo (single-repo workspaces — including ones where
    // the workspace itself is the repo — don't get repo decoration so
    // the tree looks unchanged).
    let multi_repo = app.repos.len() > 1;
    let active_repo_path = app.repos.get(app.active_repo).map(|r| r.path.clone());

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    const ROOT_INDENT: &str = "  ";
    for (vi, row) in rows.iter().enumerate().skip(app.tree.scroll).take(h) {
        let is_cursor = vi == cursor;
        let is_repo_row = multi_repo
            && row.is_dir
            && row.depth == 0
            && app.repos.iter().any(|r| r.path == row.path);
        let is_active_repo = is_repo_row && active_repo_path.as_ref() == Some(&row.path);
        let (glyph, icon_color) = if is_repo_row {
            if nerd {
                if row.is_expanded {
                    icons::REPO_OPEN
                } else {
                    icons::REPO_CLOSED
                }
            } else if row.is_expanded {
                icons::REPO_OPEN_ASCII
            } else {
                icons::REPO_CLOSED_ASCII
            }
        } else {
            icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd)
        };
        let indent = format!("{ROOT_INDENT}{}", "  ".repeat(row.depth));
        // Split chevron + icon so the chevron renders in a muted grey
        // (VS Code / NvChad tree style) while the folder/file icon keeps
        // its devicon color.
        let (chev_part, icon_part) = if nerd && row.is_dir {
            let c = if row.is_expanded {
                CHEVRON_OPEN
            } else {
                CHEVRON_CLOSED
            };
            (format!("{indent}{c} "), format!("{glyph} "))
        } else if nerd {
            // File row — pad the chevron column with spaces so icons
            // align with sibling dir rows.
            (format!("{indent}  "), format!("{glyph} "))
        } else {
            (indent.clone(), format!("{glyph} "))
        };
        let prefix_width = chev_part.chars().count() + icon_part.chars().count();
        let git_state = if row.is_dir {
            None
        } else {
            git_files.get(&row.path).copied()
        };
        let name_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            theme::cur().blue
        } else {
            match git_state {
                Some(FileState::Modified) => theme::cur().yellow,
                Some(FileState::Staged | FileState::Untracked) => theme::cur().green,
                Some(FileState::Conflicted) => theme::cur().red,
                None => theme::cur().fg,
            }
        };
        let bg = row_bg(is_cursor, focused, rail_bg);
        let mut name_style = Style::default().fg(name_color).bg(bg);
        if row.is_dir || (is_cursor && focused) {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        // Non-active repo dirs render slightly dimmed to make the active
        // one pop visually (matches the `●` / `○` convention).
        if is_repo_row && !is_active_repo {
            name_style = name_style.add_modifier(Modifier::DIM);
        }
        let prefix_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            theme::cur().blue
        } else {
            icon_color
        };
        // Right-aligned 1-char git-state badge (vim-fugitive style): M / A / ? / !.
        // Reserves 2 trailing cells (`<letter> `) when there's a state to show.
        let (badge, badge_color) = match git_state {
            Some(FileState::Modified) => ("M", theme::cur().yellow),
            Some(FileState::Staged) => ("A", theme::cur().green),
            Some(FileState::Untracked) => ("?", theme::cur().green),
            Some(FileState::Conflicted) => ("!", theme::cur().red),
            None => ("", theme::cur().fg),
        };
        let badge_width = if badge.is_empty() { 0 } else { 2 };
        // Repo dirs get a leading `● ` (active) or `○ ` (non-active) marker
        // before the name — same convention the git rail uses for branches.
        // Reserves 2 cells regardless of state so name columns align across
        // active and non-active repo rows.
        let (repo_marker, repo_marker_color) = if is_repo_row {
            if is_active_repo {
                ("● ", theme::cur().green)
            } else {
                ("○ ", theme::cur().comment)
            }
        } else {
            ("", theme::cur().fg)
        };
        let repo_marker_width = repo_marker.chars().count();
        let used = prefix_width + repo_marker_width + row.name.chars().count() + badge_width;
        let pad = width.saturating_sub(used);
        let mut spans = vec![
            Span::styled(chev_part, Style::default().fg(theme::cur().comment).bg(bg)),
            Span::styled(icon_part, Style::default().fg(prefix_color).bg(bg)),
        ];
        if !repo_marker.is_empty() {
            spans.push(Span::styled(
                repo_marker,
                Style::default().fg(repo_marker_color).bg(bg),
            ));
        }
        spans.push(Span::styled(row.name.clone(), name_style));
        spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
        if !badge.is_empty() {
            spans.push(Span::styled(
                format!("{badge} "),
                Style::default().fg(badge_color).bg(bg),
            ));
        }
        lines.push(Line::from(spans));
    }
    let drew = lines.len() as u16;
    frame.render_widget(Paragraph::new(lines), inner);
    start_y + drew
}

/// Draw one extra-workspace section starting at `start_y`. Renders a 1-row
/// blank separator + a collapsible `> name` header; if the section is
/// expanded, renders a bounded file-list slot beneath it (capped at
/// `EXTRA_TREE_MAX_ROWS` so a deep tree can't crowd out siblings + the GIT
/// section). Returns the row past the last drawn.
const EXTRA_TREE_MAX_ROWS: usize = 12;

fn draw_extra_workspace_section(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    start_y: u16,
    ws_idx: usize,
    nerd: bool,
) -> u16 {
    let rail_bg = theme::cur().bg_darker;
    let width = area.width as usize;
    let area_end = area.y + area.height;
    if start_y + 1 >= area_end {
        return start_y;
    }
    let header_y = start_y + 1; // blank separator row above
    if header_y >= area_end {
        return start_y;
    }
    let (name, expanded) = {
        let ws = &app.extra_workspaces[ws_idx];
        (ws.name.clone(), ws.expanded)
    };
    let chev = section_chev(expanded, nerd);
    let chev_str = format!(" {chev} ");
    let used = chev_str.chars().count() + name.chars().count();
    let pad = width.saturating_sub(used);
    let header_rect = Rect {
        x: area.x,
        y: header_y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                chev_str,
                Style::default().fg(theme::cur().comment).bg(rail_bg),
            ),
            Span::styled(
                name.clone(),
                Style::default()
                    .fg(theme::cur().fg)
                    .bg(rail_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ".repeat(pad), Style::default().bg(rail_bg)),
        ])),
        header_rect,
    );
    app.rects
        .extra_workspace_toggles
        .push((header_rect, ws_idx));

    if !expanded {
        return header_y + 1;
    }
    let body_y = header_y + 1;
    if body_y >= area_end {
        return header_y + 1;
    }
    let avail = (area_end - body_y) as usize;
    // Reserve a bit for the GIT section that follows (4 rows = blank + header
    // + at least 2 body rows) when applicable. Cap at EXTRA_TREE_MAX_ROWS so
    // a 200-line tree can't swallow the rail.
    let h = avail.saturating_sub(4).min(EXTRA_TREE_MAX_ROWS);
    if h == 0 {
        return body_y;
    }
    let body_rect = Rect {
        x: area.x,
        y: body_y,
        width: area.width,
        height: h as u16,
    };
    app.rects.extra_workspace_bodies.push((
        body_rect,
        ws_idx,
        app.extra_workspaces[ws_idx].tree.scroll,
    ));

    // Clamp the tree's scroll so the cursor stays in view. We're not the
    // focused tree (filter mode is a primary-only feature for now), so we
    // just paint top-down with the saved scroll.
    let rows = app.extra_workspaces[ws_idx].tree.visible_rows();
    let scroll = app.extra_workspaces[ws_idx].tree.scroll;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    let scroll = scroll.min(max_scroll);
    app.extra_workspaces[ws_idx].tree.scroll = scroll;

    let multi_repo = app.repos.len() > 1;
    let active_repo_path = app.repos.get(app.active_repo).map(|r| r.path.clone());

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    const ROOT_INDENT: &str = "  ";
    for row in rows.iter().skip(scroll).take(h) {
        let is_repo_row = multi_repo
            && row.is_dir
            && row.depth == 0
            && app.repos.iter().any(|r| r.path == row.path);
        let is_active_repo = is_repo_row && active_repo_path.as_ref() == Some(&row.path);
        let (glyph, icon_color) = if is_repo_row {
            if nerd {
                if row.is_expanded {
                    icons::REPO_OPEN
                } else {
                    icons::REPO_CLOSED
                }
            } else if row.is_expanded {
                icons::REPO_OPEN_ASCII
            } else {
                icons::REPO_CLOSED_ASCII
            }
        } else {
            icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd)
        };
        let indent = format!("{ROOT_INDENT}{}", "  ".repeat(row.depth));
        let (chev_part, icon_part) = if nerd && row.is_dir {
            let c = if row.is_expanded {
                CHEVRON_OPEN
            } else {
                CHEVRON_CLOSED
            };
            (format!("{indent}{c} "), format!("{glyph} "))
        } else if nerd {
            (format!("{indent}  "), format!("{glyph} "))
        } else {
            (indent.clone(), format!("{glyph} "))
        };
        let prefix_width = chev_part.chars().count() + icon_part.chars().count();
        let name_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            theme::cur().blue
        } else {
            theme::cur().fg
        };
        let mut name_style = Style::default().fg(name_color).bg(rail_bg);
        if row.is_dir {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        if is_repo_row && !is_active_repo {
            name_style = name_style.add_modifier(Modifier::DIM);
        }
        let prefix_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            theme::cur().blue
        } else {
            icon_color
        };
        let (repo_marker, repo_marker_color) = if is_repo_row {
            if is_active_repo {
                ("● ", theme::cur().green)
            } else {
                ("○ ", theme::cur().comment)
            }
        } else {
            ("", theme::cur().fg)
        };
        let used = prefix_width + repo_marker.chars().count() + row.name.chars().count();
        let pad_n = width.saturating_sub(used);
        let mut spans = vec![
            Span::styled(
                chev_part,
                Style::default().fg(theme::cur().comment).bg(rail_bg),
            ),
            Span::styled(
                icon_part,
                Style::default().fg(prefix_color).bg(rail_bg),
            ),
        ];
        if !repo_marker.is_empty() {
            spans.push(Span::styled(
                repo_marker,
                Style::default().fg(repo_marker_color).bg(rail_bg),
            ));
        }
        spans.push(Span::styled(row.name.clone(), name_style));
        spans.push(Span::styled(
            " ".repeat(pad_n),
            Style::default().bg(rail_bg),
        ));
        lines.push(Line::from(spans));
    }
    let drew = lines.len() as u16;
    frame.render_widget(Paragraph::new(lines), body_rect);
    body_y + drew
}

/// Draw the GIT section: a "branches" sub-label, the branch rows, a
/// "worktrees" sub-label, the worktree rows. Sub-labels are dim, not
/// selectable. Records click-rects in `app.rects.git_rail_rows`.
fn draw_git_section(frame: &mut Frame, app: &mut App, area: Rect, start_y: u16, _nerd: bool) {
    let rail_bg = theme::cur().bg_darker;
    let width = area.width as usize;
    let avail = (area.y + area.height).saturating_sub(start_y) as usize;
    if avail == 0 {
        return;
    }
    let focused = app.focus == Focus::Tree && app.rail_section == RailSection::Git;
    let cursor_row = app.git_rail.cursor;
    let nb = app.git_rail.branches.len();

    let mut lines: Vec<Line> = Vec::with_capacity(avail);
    let mut row_y = start_y;
    let mut row_count_drawn: usize = 0; // counts only selectable rows
    const INDENT: &str = "  ";

    // ── branches sub-section ──
    if !app.git_rail.branches.is_empty() {
        // Sub-label (dim, not selectable).
        push_sublabel(&mut lines, "branches", width, rail_bg);
        row_y += 1;
        if (row_y - area.y) as usize >= avail {
            frame.render_widget(Paragraph::new(lines), git_body_rect(area, start_y));
            return;
        }
        for (i, br) in app.git_rail.branches.iter().enumerate() {
            if (row_y - area.y) as usize >= avail {
                break;
            }
            let is_cur_row = row_count_drawn == cursor_row;
            let bg = row_bg(is_cur_row, focused, rail_bg);
            let marker = if br.is_current { "●" } else { "○" };
            let marker_color = if br.is_current {
                theme::cur().green
            } else {
                theme::cur().fg
            };
            let name = &br.name;
            let prefix = format!("{INDENT}{marker} ");
            let used = prefix.chars().count() + name.chars().count();
            let pad = width.saturating_sub(used);
            let mut name_style = Style::default().fg(theme::cur().fg).bg(bg);
            if br.is_current {
                name_style = name_style.add_modifier(Modifier::BOLD);
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(marker_color).bg(bg)),
                Span::styled(name.clone(), name_style),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::Branch(i),
            ));
            row_y += 1;
            row_count_drawn += 1;
        }
    }

    // ── worktrees sub-section ──
    if !app.git_rail.worktrees.is_empty() && ((row_y - area.y) as usize) < avail {
        push_sublabel(&mut lines, "worktrees", width, rail_bg);
        row_y += 1;
        for (i, wt) in app.git_rail.worktrees.iter().enumerate() {
            if (row_y - area.y) as usize >= avail {
                break;
            }
            let row_idx = nb + i;
            let is_cur_row = row_idx == cursor_row;
            let bg = row_bg(is_cur_row, focused, rail_bg);
            let marker = if wt.is_current { "⤿" } else { "·" };
            let marker_color = if wt.is_current {
                theme::cur().yellow
            } else {
                theme::cur().fg
            };
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
            let prefix = format!("{INDENT}{marker} ");
            let used = prefix.chars().count() + shown.chars().count();
            let pad = width.saturating_sub(used);
            let mut name_style = Style::default().fg(theme::cur().fg).bg(bg);
            if wt.is_current {
                name_style = name_style.add_modifier(Modifier::BOLD);
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(marker_color).bg(bg)),
                Span::styled(shown, name_style),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::Worktree(i),
            ));
            row_y += 1;
        }
    }

    // ── pulls sub-section (open PRs / MRs for the current repo) ──
    if !app.git_rail.pulls.is_empty() && ((row_y - area.y) as usize) < avail {
        push_sublabel(&mut lines, "open prs", width, rail_bg);
        row_y += 1;
        let nb_and_nw = nb + app.git_rail.worktrees.len();
        for (i, pr) in app.git_rail.pulls.iter().enumerate() {
            if (row_y - area.y) as usize >= avail {
                break;
            }
            let row_idx = nb_and_nw + i;
            let is_cur_row = row_idx == cursor_row;
            let bg = row_bg(is_cur_row, focused, rail_bg);
            // Pick a per-host color so the glyph telegraphs which host the
            // PR came from.
            let host_color = match pr.host_tag {
                "BB" => theme::cur().blue,
                "GH" => theme::cur().fg,
                "GL" => theme::cur().orange,
                "AZ" => theme::cur().cyan,
                _ => theme::cur().fg,
            };
            // The branch-marker convention: ● for the PR on the current branch,
            // ○ otherwise — mirrors the branches sub-section.
            let marker = if pr.is_current_branch { "●" } else { "○" };
            // Truncate the title hard so wide titles don't blow out the row.
            let avail_for_title =
                width.saturating_sub(2 + 1 + 1 + pr.number_label.chars().count() + 1);
            let title_disp = truncate_chars(&pr.title, avail_for_title);
            let prefix = format!("  {marker} ");
            let head = format!("{} ", pr.number_label);
            let used = prefix.chars().count() + head.chars().count() + title_disp.chars().count();
            let pad = width.saturating_sub(used);
            let mut title_style = Style::default().fg(theme::cur().fg).bg(bg);
            if pr.is_current_branch {
                title_style = title_style.add_modifier(Modifier::BOLD);
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(host_color).bg(bg)),
                Span::styled(head, Style::default().fg(host_color).bg(bg)),
                Span::styled(title_disp, title_style),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::Pull(i),
            ));
            row_y += 1;
        }
    }

    if app.git_rail.is_empty() {
        // Friendly placeholder so the user sees the section even outside a repo.
        push_sublabel(&mut lines, "no git repo here", width, rail_bg);
    }

    let body = git_body_rect(area, start_y);
    frame.render_widget(Paragraph::new(lines), body);
}

fn truncate_chars(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    let count = s.chars().count();
    if count <= max {
        return s.to_string();
    }
    if max <= 1 {
        return s.chars().take(max).collect();
    }
    let mut out: String = s.chars().take(max - 1).collect();
    out.push('…');
    out
}

fn git_body_rect(area: Rect, start_y: u16) -> Rect {
    Rect {
        x: area.x,
        y: start_y,
        width: area.width,
        height: area.height.saturating_sub(start_y - area.y),
    }
}

fn push_sublabel(lines: &mut Vec<Line>, text: &str, width: usize, bg: ratatui::style::Color) {
    let s = format!("  {text}");
    let pad = width.saturating_sub(s.chars().count());
    lines.push(Line::from(vec![
        Span::styled(s, Style::default().fg(theme::cur().comment).bg(bg)),
        Span::styled(" ".repeat(pad), Style::default().bg(bg)),
    ]));
}

fn row_bg(is_cursor: bool, focused: bool, rail_bg: ratatui::style::Color) -> ratatui::style::Color {
    if is_cursor {
        if focused {
            theme::cur().bg2
        } else {
            theme::cur().bg
        }
    } else {
        rail_bg
    }
}
