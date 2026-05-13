//! The outline panel (`Pane::Outline`) — the LSP `documentSymbol` reply
//! rendered as an indented, navigable list. Read-only; `↑↓`/`jk` select,
//! `Enter` jumps to the symbol's `(line, char)` in its target editor, `r`
//! refreshes, `Esc` → tree.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::lsp::DocumentSymbol;
use crate::pane::Pane;
use crate::ui::theme::{self, Theme};

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    _focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));

    let Some(Pane::Outline(o)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    o.clamp();

    let mut lines: Vec<Line> = Vec::new();
    let name = o
        .target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("outline");
    lines.push(Line::from(vec![
        Span::styled("  ⌥ ", Style::default().fg(t.purple).bg(t.bg_dark)),
        Span::styled(
            name.to_string(),
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "   {} symbol{}",
                o.items.len(),
                if o.items.len() == 1 { "" } else { "s" }
            ),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        "  ⏎ jump   r refresh   esc back",
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));

    if o.items.is_empty() {
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        lines.push(Line::from(Span::styled(
            "  (no symbols)",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        return None;
    }

    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));

    let mut selected_row = lines.len();
    for (idx, sym) in o.items.iter().enumerate() {
        let sel = idx == o.selected;
        if sel {
            selected_row = lines.len();
        }
        lines.push(item_line(&t, sym, sel));
    }

    // Keep selected on-screen — same shape as the other list panes.
    let h = area.height as usize;
    let total = lines.len();
    if total > h {
        let max_scroll = total.saturating_sub(h);
        let scroll = selected_row.saturating_sub(h / 2).min(max_scroll);
        o.scroll = scroll;
    } else {
        o.scroll = 0;
    }
    let visible: Vec<Line> = lines.into_iter().skip(o.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(visible).style(Style::default().bg(t.bg_dark)),
        area,
    );
    None
}

fn item_line(t: &Theme, sym: &DocumentSymbol, sel: bool) -> Line<'static> {
    let bg = if sel { t.bg2 } else { t.bg_dark };
    let arrow = if sel { "▶ " } else { "  " };
    let indent = "  ".repeat(sym.depth as usize);
    let mut name_style = Style::default().fg(t.fg).bg(bg);
    if sel {
        name_style = name_style.add_modifier(Modifier::BOLD);
    }
    let kind_color = match sym.kind {
        "fn" | "method" | "ctor" => t.blue,
        "struct" | "class" | "interface" | "enum" | "variant" | "type" => t.yellow,
        "const" | "var" | "field" | "property" => t.cyan,
        "module" | "namespace" | "package" => t.green,
        _ => t.comment,
    };
    Line::from(vec![
        Span::styled(arrow.to_string(), Style::default().fg(t.purple).bg(bg)),
        Span::styled(
            format!("{:>10} ", sym.kind),
            Style::default().fg(kind_color).bg(bg),
        ),
        Span::styled(indent, Style::default().bg(bg)),
        Span::styled(sym.name.clone(), name_style),
        Span::styled(
            format!(":{}", sym.line + 1),
            Style::default().fg(t.comment).bg(bg),
        ),
    ])
}
