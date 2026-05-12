//! The file-tree rail. Background matches the editor; folders (icon + name) are
//! blue, NvChad-style; git-touched files take a status tint.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::focus::Focus;
use crate::git::status::FileState;
use crate::ui::{icons, theme};

/// The rail's background — same as the editor body so they blend.
const RAIL_BG: ratatui::style::Color = theme::BG_DARK;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(RAIL_BG)), area);
    if area.height == 0 || area.width == 0 {
        return;
    }
    let width = area.width as usize;

    // Header — a subtle title line (NvChad's nvim-tree shows the root, not a loud bar).
    let ws_name = app.workspace.file_name().and_then(|n| n.to_str()).unwrap_or("workspace");
    let header_glyph = if app.config.ui.ascii_icons { "*" } else { "\u{f07b}" };
    let header = Line::from(vec![
        Span::styled(format!(" {header_glyph} "), Style::default().fg(theme::BLUE).bg(RAIL_BG)),
        Span::styled(
            pad_to(format!("{ws_name} "), width.saturating_sub(3)),
            Style::default().fg(theme::BLUE).bg(RAIL_BG).add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(Paragraph::new(header), Rect { height: 1, ..area });

    let body = Rect { y: area.y + 1, height: area.height.saturating_sub(1), ..area };
    if body.height == 0 {
        return;
    }
    let rows = app.tree.visible_rows();
    let cursor = app.tree.cursor();
    let h = body.height as usize;

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

        // Folders are blue (icon + name). Files take a git tint if any, else default fg.
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

        let prefix = format!("{indent}{glyph} ");
        let used = prefix.chars().count() + row.name.chars().count();
        let pad = width.saturating_sub(used);
        lines.push(Line::from(vec![
            Span::styled(prefix, Style::default().fg(icon_color).bg(bg)),
            Span::styled(row.name.clone(), name_style),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]));
    }
    frame.render_widget(Paragraph::new(lines), body);
}

fn pad_to(mut s: String, width: usize) -> String {
    let n = s.chars().count();
    if n < width {
        s.push_str(&" ".repeat(width - n));
    } else if n > width {
        s = s.chars().take(width).collect();
    }
    s
}
