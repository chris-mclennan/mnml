//! The file-tree rail. Background matches the editor; folders show a collapse
//! chevron + a blue folder icon + a blue name (NvChad-style); git-touched files
//! take a status tint. (The workspace name lives in the statusline now, not a
//! header here — the rail just starts with the first entry.)

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::focus::Focus;
use crate::git::status::FileState;
use crate::ui::{icons, theme};

/// The rail's background — NvChad's `darker_black`, a touch darker than the
/// editor body (`black`) so the panels read as distinct.
const RAIL_BG: Color = theme::BG_DARKER;
const CHEVRON_OPEN: &str = "\u{f107}"; //  (angle-down)
const CHEVRON_CLOSED: &str = "\u{f105}"; //  (angle-right)

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(RAIL_BG)), area);
    app.rects.tree = None;
    if area.height < 2 || area.width == 0 {
        return;
    }
    // A blank line above the first entry (NvChad leaves the tree a little breathing
    // room at the top). Everything below — and the mouse hitbox — uses `inner`.
    let inner = Rect {
        x: area.x,
        y: area.y + 1,
        width: area.width,
        height: area.height - 1,
    };
    app.rects.tree = Some(inner);
    let area = inner;
    let width = area.width as usize;
    let rows = app.tree.visible_rows();
    let cursor = app.tree.cursor();
    let h = area.height as usize;

    // Keep the cursor on screen.
    if cursor < app.tree.scroll {
        app.tree.scroll = cursor;
    } else if cursor >= app.tree.scroll + h {
        app.tree.scroll = cursor + 1 - h;
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    app.tree.scroll = app.tree.scroll.min(max_scroll);
    app.rects.tree_scroll = app.tree.scroll;

    let nerd = !app.config.ui.ascii_icons;
    let git_files = &app.git.snapshot().files;
    let focused = app.focus == Focus::Tree;

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    for (vi, row) in rows.iter().enumerate().skip(app.tree.scroll).take(h) {
        let is_cursor = vi == cursor;
        let (glyph, icon_color) = icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd);
        let indent = "  ".repeat(row.depth);

        // In Nerd-Font mode, folders get an explicit collapse chevron; files get a
        // blank placeholder so their icons line up under folders' icons. In ASCII
        // mode the ▶/▼ folder glyph already conveys state, so no separate chevron.
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

        // Folders are blue (chevron + icon + name). Files: git tint, else default fg.
        let name_color = if row.is_dir {
            theme::BLUE
        } else {
            match git_files.get(&row.path).copied() {
                Some(FileState::Modified) => theme::YELLOW,
                Some(FileState::Staged | FileState::Untracked) => theme::GREEN,
                Some(FileState::Conflicted) => theme::RED,
                None => theme::FG,
            }
        };
        let bg = if is_cursor {
            if focused { theme::BG2 } else { theme::BG }
        } else {
            RAIL_BG
        };
        let mut name_style = Style::default().fg(name_color).bg(bg);
        if row.is_dir || (is_cursor && focused) {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        // The chevron+icon prefix is blue for folders, the devicon color for files.
        let prefix_color = if row.is_dir { theme::BLUE } else { icon_color };

        let used = prefix.chars().count() + row.name.chars().count();
        let pad = width.saturating_sub(used);
        lines.push(Line::from(vec![
            Span::styled(prefix, Style::default().fg(prefix_color).bg(bg)),
            Span::styled(row.name.clone(), name_style),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]));
    }
    frame.render_widget(Paragraph::new(lines), area);
}
