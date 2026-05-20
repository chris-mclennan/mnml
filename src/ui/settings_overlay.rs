//! Settings overlay — a clickable list of the most-edited `[ui]` and
//! `[editor]` flags. Each row is a checkbox that flips the flag via
//! the existing `:set <name>!` ex command path so persistence /
//! validation lives in one place. Sibling to the About / Welcome /
//! Discovery overlays.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

/// `(flag_name, label, accessor)` — the accessor returns the current
/// boolean state given the App. Adding a row here is the cheap path to
/// a new toggle (any flag with a `:set <name>!` ex command works).
type SettingRow = (&'static str, &'static str, fn(&App) -> bool);

fn settings_rows() -> Vec<SettingRow> {
    vec![
        ("wrap", "Word wrap", |a| a.config.ui.wrap),
        ("scrollbar", "Editor scrollbar", |a| a.config.ui.scrollbar),
        ("rendermarkdown", "Inline-render markdown", |a| {
            a.config.ui.render_markdown
        }),
        ("stickycontext", "Sticky scope context", |a| {
            a.config.ui.sticky_context
        }),
        ("relativenumber", "Relative line numbers", |a| {
            a.config.ui.relative_line_numbers
        }),
        ("number", "Show line numbers", |a| a.config.ui.line_numbers),
        ("cursorline", "Highlight cursor line", |a| {
            a.config.ui.cursor_line
        }),
        ("hlword", "Highlight word under cursor", |a| {
            a.config.ui.highlight_word_under_cursor
        }),
        ("trailing", "Highlight trailing whitespace", |a| {
            a.config.ui.highlight_trailing_ws
        }),
        ("rainbow", "Rainbow brackets", |a| {
            a.config.ui.bracket_rainbow
        }),
        ("syntax", "Tree-sitter syntax", |a| a.config.ui.syntax),
        ("todohl", "Highlight TODO/FIXME/HACK", |a| {
            a.config.ui.highlight_todo_keywords
        }),
        ("clock", "Statusline clock", |a| a.config.ui.clock),
        ("bufferline", "Show bufferline tab strip", |a| {
            a.bufferline_visible
        }),
        ("autoindent", "Auto-indent on Enter", |a| {
            a.config.editor.auto_indent
        }),
        ("trim", "Trim trailing whitespace on save", |a| {
            a.config.editor.trim_trailing_ws_on_save
        }),
        ("eol", "Ensure trailing newline on save", |a| {
            a.config.editor.ensure_trailing_newline
        }),
    ]
}

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    if !app.show_settings {
        app.rects.settings_rows.clear();
        return;
    }
    let t = theme::cur();
    let rows = settings_rows();
    let title = " Settings — click row to toggle · Esc closes ";
    let key_w = rows
        .iter()
        .map(|(_, label, _)| label.chars().count())
        .max()
        .unwrap_or(20);
    let inner_w = (4 + key_w + 12).max(title.chars().count() + 2); // [x] label  + state
    let w = (inner_w as u16 + 4).min(screen.width);
    let h = (rows.len() as u16 + 2 + 2).min(screen.height);
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 6);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);

    // Register per-row click rects.
    app.rects.settings_rows.clear();
    let inner_x = area.x + 1;
    let inner_w_cells = area.width.saturating_sub(2);
    for (i, (flag, _, _)) in rows.iter().enumerate() {
        let row_y = area.y + 1 + i as u16;
        if row_y >= area.y + area.height.saturating_sub(2) {
            break;
        }
        app.rects.settings_rows.push((
            Rect {
                x: inner_x,
                y: row_y,
                width: inner_w_cells,
                height: 1,
            },
            *flag,
        ));
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.purple)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(rows.len() + 1);
    for (_flag, label, accessor) in rows.iter() {
        let on = accessor(app);
        let (chip, chip_fg) = if on {
            ("[x]", t.green)
        } else {
            ("[ ]", t.comment)
        };
        let label_style = if on {
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment)
        };
        lines.push(Line::from(vec![
            Span::styled(" ", Style::default().bg(t.bg2)),
            Span::styled(
                chip,
                Style::default()
                    .fg(chip_fg)
                    .bg(t.bg2)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("  ", Style::default().bg(t.bg2)),
            Span::styled(label.to_string(), label_style),
        ]));
    }
    lines.push(Line::from(Span::styled(
        " runtime only — :set <flag> persists / writes config.toml ".to_string(),
        Style::default()
            .fg(t.comment)
            .bg(t.bg2)
            .add_modifier(Modifier::ITALIC),
    )));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}
