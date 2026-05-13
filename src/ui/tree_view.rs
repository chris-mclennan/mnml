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
    let header_label = format!("{chev} {ws_name}");
    let header_pad = width.saturating_sub(header_label.chars().count());
    let header_rect = Rect {
        x: area.x,
        y: area.y + 1,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                header_label,
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
    let header_label = format!("{chev} GIT");
    let header_pad = width.saturating_sub(header_label.chars().count());
    let git_header_rect = Rect {
        x: area.x,
        y: git_header_y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                header_label,
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
    let inner = Rect {
        x: area.x,
        y: start_y,
        width: area.width,
        height: h as u16,
    };
    app.rects.tree = Some(inner);

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

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    const ROOT_INDENT: &str = "  ";
    for (vi, row) in rows.iter().enumerate().skip(app.tree.scroll).take(h) {
        let is_cursor = vi == cursor;
        let (glyph, icon_color) = icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd);
        let indent = format!("{ROOT_INDENT}{}", "  ".repeat(row.depth));
        let prefix = if nerd {
            let chev = if row.is_dir {
                if row.is_expanded {
                    CHEVRON_OPEN
                } else {
                    CHEVRON_CLOSED
                }
            } else {
                " "
            };
            format!("{indent}{chev} {glyph} ")
        } else {
            format!("{indent}{glyph} ")
        };
        let git_state = if row.is_dir {
            None
        } else {
            git_files.get(&row.path).copied()
        };
        let name_color = if row.is_dir {
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
        let prefix_color = if row.is_dir {
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
        let used = prefix.chars().count() + row.name.chars().count() + badge_width;
        let pad = width.saturating_sub(used);
        let mut spans = vec![
            Span::styled(prefix, Style::default().fg(prefix_color).bg(bg)),
            Span::styled(row.name.clone(), name_style),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ];
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

    if app.git_rail.is_empty() {
        // Friendly placeholder so the user sees the section even outside a repo.
        push_sublabel(&mut lines, "no git repo here", width, rail_bg);
    }

    let body = git_body_rect(area, start_y);
    frame.render_widget(Paragraph::new(lines), body);
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
