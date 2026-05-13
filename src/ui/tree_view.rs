//! The file-tree rail. VS-Code Explorer style: a `> WORKSPACE-NAME` section
//! header sits at the top of the rail; when the section is collapsed (the
//! `>` chevron form), only the header shows and the file list is hidden;
//! when expanded (`v` chevron), the file list appears below. The whole rail
//! itself is independently toggled by `Ctrl+B` (`tree_visible`). Folders
//! show a collapse chevron + a blue folder icon + a blue name (NvChad-style);
//! git-touched files take a status tint. (Future sibling sections — OUTLINE,
//! TIMELINE-like — would render under the workspace one with their own header.)

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::focus::Focus;
use crate::git::status::FileState;
use crate::ui::{icons, theme};

const CHEVRON_OPEN: &str = "\u{f107}"; //  (angle-down)
const CHEVRON_CLOSED: &str = "\u{f105}"; //  (angle-right)

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let rail_bg = theme::cur().bg_darker;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(rail_bg)), area);
    app.rects.tree = None;
    app.rects.tree_toggle = None;
    if area.height == 0 || area.width == 0 {
        return;
    }

    // ── workspace section header (always visible, click-to-toggle) ─
    let nerd = !app.config.ui.ascii_icons;
    let width = area.width as usize;
    let ws_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.to_uppercase())
        .unwrap_or_else(|| "WORKSPACE".to_string());
    let chev = if app.tree_root_expanded {
        if nerd { CHEVRON_OPEN } else { "▾" }
    } else if nerd {
        CHEVRON_CLOSED
    } else {
        "▸"
    };
    let header_label = format!(" {chev} {ws_name}");
    let header_pad = width.saturating_sub(header_label.chars().count());
    let header_rect = Rect {
        x: area.x,
        y: area.y,
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

    // ── file list (only when the section is expanded) ──────────────
    if !app.tree_root_expanded || area.height < 2 {
        return;
    }
    let inner = Rect {
        x: area.x,
        y: area.y + 1,
        width: area.width,
        height: area.height - 1,
    };
    app.rects.tree = Some(inner);

    let rows = app.tree.visible_rows();
    let cursor = app.tree.cursor();
    let h = inner.height as usize;

    if cursor < app.tree.scroll {
        app.tree.scroll = cursor;
    } else if cursor >= app.tree.scroll + h {
        app.tree.scroll = cursor + 1 - h;
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    app.tree.scroll = app.tree.scroll.min(max_scroll);
    app.rects.tree_scroll = app.tree.scroll;

    let git_files = &app.git.snapshot().files;
    let focused = app.focus == Focus::Tree;

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    for (vi, row) in rows.iter().enumerate().skip(app.tree.scroll).take(h) {
        let is_cursor = vi == cursor;
        let (glyph, icon_color) = icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd);
        let indent = "  ".repeat(row.depth);

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

        let name_color = if row.is_dir {
            theme::cur().blue
        } else {
            match git_files.get(&row.path).copied() {
                Some(FileState::Modified) => theme::cur().yellow,
                Some(FileState::Staged | FileState::Untracked) => theme::cur().green,
                Some(FileState::Conflicted) => theme::cur().red,
                None => theme::cur().fg,
            }
        };
        let bg = if is_cursor {
            if focused {
                theme::cur().bg2
            } else {
                theme::cur().bg
            }
        } else {
            rail_bg
        };
        let mut name_style = Style::default().fg(name_color).bg(bg);
        if row.is_dir || (is_cursor && focused) {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        let prefix_color = if row.is_dir {
            theme::cur().blue
        } else {
            icon_color
        };

        let used = prefix.chars().count() + row.name.chars().count();
        let pad = width.saturating_sub(used);
        lines.push(Line::from(vec![
            Span::styled(prefix, Style::default().fg(prefix_color).bg(bg)),
            Span::styled(row.name.clone(), name_style),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}
