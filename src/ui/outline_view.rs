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

    // Reserve a 1-cell scrollbar on the right edge.
    let want_sb = area.width >= 8;
    let sb_w = if want_sb { 1 } else { 0 };
    let body_area = Rect::new(area.x, area.y, area.width - sb_w, area.height);
    let sb_area = Rect::new(area.x + area.width - sb_w, area.y, sb_w, area.height);
    let area = body_area;

    // The cursor's current file row in the outline's target editor — used
    // to highlight the closest enclosing symbol. Take this BEFORE the
    // mutable borrow of the outline pane.
    let target_cursor_row: Option<u32> = {
        let target = match app.panes.get(pane_id) {
            Some(Pane::Outline(o)) => o.target.clone(),
            _ => return None,
        };
        app.panes.iter().find_map(|p| match p {
            Pane::Editor(b) if b.path.as_deref() == Some(target.as_path()) => {
                Some(b.editor.row_col().0 as u32)
            }
            _ => None,
        })
    };

    let Some(Pane::Outline(o)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    o.clamp();
    let visible = o.visible_indices();
    let total_items = o.items.len();
    let visible_count = visible.len();

    // The closest enclosing symbol — the last item whose `line` is at-or-
    // before the cursor row. Approximation: documentSymbol doesn't carry
    // an end-line in mnml's struct, so we use the next symbol's start as
    // the implicit end. The result is the symbol the cursor is "inside"
    // most of the time.
    let current_item: Option<usize> = target_cursor_row.and_then(|row| {
        let mut best: Option<usize> = None;
        for (i, sym) in o.items.iter().enumerate() {
            if sym.line <= row {
                best = Some(i);
            }
        }
        best
    });

    let mut lines: Vec<Line> = Vec::new();
    let name = o
        .target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("outline");
    let count_label = if !o.query.is_empty() {
        format!("   {visible_count}/{total_items} symbol(s)")
    } else {
        format!(
            "   {total_items} symbol{}",
            if total_items == 1 { "" } else { "s" }
        )
    };
    lines.push(Line::from(vec![
        Span::styled("  ⌥ ", Style::default().fg(t.purple).bg(t.bg_dark)),
        Span::styled(
            name.to_string(),
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(count_label, Style::default().fg(t.comment).bg(t.bg_dark)),
    ]));
    // design-critic-round-5 SEV-2 2026-07-12 — was a single fixed
    // hint (~44 chars) that clipped mid-word at the right-panel
    // default width of 32. Port the width-tiered pattern from
    // `diagnostics_view` so the pane degrades gracefully in the
    // Right Panel host.
    let hint = if o.filter_mode {
        if area.width >= 52 {
            "  filter — type to narrow, ⏎ apply, esc clear"
        } else if area.width >= 30 {
            "  type · ⏎ apply · esc clear"
        } else {
            "  ⏎ / esc"
        }
    } else if area.width >= 52 {
        "  ⏎ jump   r refresh   / filter   esc back"
    } else if area.width >= 30 {
        "  ⏎ jump · / filter · esc back"
    } else {
        "  ⏎ / r / esc"
    };
    lines.push(Line::from(Span::styled(
        hint,
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));
    // Filter input line — shown whenever a query is present or filter mode
    // is on (so the user can see what's narrowing the list).
    if o.filter_mode || !o.query.is_empty() {
        let cursor = if o.filter_mode { "█" } else { "" };
        lines.push(Line::from(vec![
            Span::styled("  / ", Style::default().fg(t.yellow).bg(t.bg_dark)),
            Span::styled(o.query.clone(), Style::default().fg(t.fg).bg(t.bg_dark)),
            Span::styled(
                cursor.to_string(),
                Style::default().fg(t.yellow).bg(t.bg_dark),
            ),
        ]));
    }

    if total_items == 0 {
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
    if visible_count == 0 {
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
        lines.push(Line::from(Span::styled(
            "  (no matches)",
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
    let mut row_indices: Vec<(usize, usize)> = Vec::with_capacity(visible.len());
    for (vi, &idx) in visible.iter().enumerate() {
        let sym = &o.items[idx];
        let sel = vi == o.selected;
        let current = current_item == Some(idx);
        if sel {
            selected_row = lines.len();
        }
        row_indices.push((lines.len(), vi));
        lines.push(item_line(&t, sym, sel, current));
        let _ = sym;
    }

    let h = area.height as usize;
    let total = lines.len();
    if total > h {
        let max_scroll = total.saturating_sub(h);
        let scroll = selected_row.saturating_sub(h / 2).min(max_scroll);
        o.scroll = scroll;
    } else {
        o.scroll = 0;
    }

    // Record click rects (mapping visible row idx in the outline →
    // screen y after scroll has been resolved).
    for (line_y, vi) in &row_indices {
        if *line_y < o.scroll || *line_y >= o.scroll + h {
            continue;
        }
        let visible_y = line_y - o.scroll;
        let screen_y = area.y.saturating_add(visible_y as u16);
        if screen_y < area.y.saturating_add(area.height) {
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: area.x,
                    y: screen_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                *vi,
            ));
        }
    }

    let total_lines = lines.len();
    let scroll = o.scroll;
    let visible: Vec<Line> = lines.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(visible).style(Style::default().bg(t.bg_dark)),
        area,
    );
    if sb_w > 0 {
        crate::ui::scrollbar::paint_simple_scrollbar(frame, sb_area, &t, total_lines, h, scroll);
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb_area,
            pane_id,
            total: total_lines,
            viewport: h,
            kind: crate::app::ScrollbarKind::Outline,
        });
    }
    None
}

fn item_line(t: &Theme, sym: &DocumentSymbol, sel: bool, current: bool) -> Line<'static> {
    let bg = if sel { t.bg2 } else { t.bg_dark };
    // Selected wins; current-but-not-selected gets a yellow `●` so the
    // user can see where the cursor sits in the file at a glance.
    let arrow = if sel {
        "▶ "
    } else if current {
        "● "
    } else {
        "  "
    };
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
    let arrow_fg = if !sel && current { t.yellow } else { t.purple };
    Line::from(vec![
        Span::styled(arrow.to_string(), Style::default().fg(arrow_fg).bg(bg)),
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
