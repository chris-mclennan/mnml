//! Cheatsheet pane renderer. Walks `CheatsheetPane.visible_sections()` and
//! emits one row per chord binding under each group header.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, id: PaneId, area: Rect, focused: bool) {
    let Some(Pane::Cheatsheet(p)) = app.panes.get(id) else {
        return;
    };
    let t = theme::cur();

    let border_style = if focused {
        Style::default().fg(t.blue)
    } else {
        Style::default().fg(t.bg3)
    };

    let header_text = if p.filter_mode {
        format!(" Cheatsheet · /{} · esc clears · enter applies ", p.query)
    } else if p.query.is_empty() {
        " Cheatsheet · / filter · j/k · Esc → tree · Ctrl+W close ".to_string()
    } else {
        format!(
            " Cheatsheet · filter: {} · / to edit · esc clears ",
            p.query
        )
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(header_text);

    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 8 || inner.height < 1 {
        return;
    }

    let sections = p.visible_sections();
    if sections.is_empty() {
        let line = Line::from(Span::styled("  no matches", Style::default().fg(t.comment)));
        frame.render_widget(Paragraph::new(vec![line]), inner);
        return;
    }

    let dim = Style::default().fg(t.comment);
    let chord_style = Style::default().fg(t.yellow).add_modifier(Modifier::BOLD);
    let id_style = Style::default().fg(t.cyan);
    let title_style = Style::default().fg(t.fg);
    let header_style = Style::default().fg(t.purple).add_modifier(Modifier::BOLD);
    let sel_style = Style::default()
        .fg(t.bg_dark)
        .bg(t.yellow)
        .add_modifier(Modifier::BOLD);

    // Build a flat list of (is_header, render_line) rows; the selectable
    // cursor only tracks non-header rows.
    let mut lines: Vec<Line> = Vec::new();
    let mut selectable_index: usize = 0;
    let mut selected_screen_y: Option<usize> = None;
    // (lines.len() at push time, selectable_index) — so we can compute
    // the on-screen rect for each non-header row after we scroll.
    let mut row_line_indices: Vec<(usize, usize)> = Vec::new();
    // 2026-06-21 vscode-mouse SEV-2 cheatsheet-header-click — collect
    // (line_idx, group_name) for each header so the mouse dispatcher
    // can toggle the section's collapsed state.
    let mut header_line_indices: Vec<(usize, String)> = Vec::new();
    let chord_w: usize = sections
        .iter()
        .flat_map(|s| s.rows.iter().map(|r| r.chord.chars().count()))
        .max()
        .unwrap_or(8)
        .min(20);

    for sec in &sections {
        let is_collapsed = p.collapsed.contains(&sec.group);
        // Section header — `── group ──` styled. Collapsed sections
        // show a `▸` indicator instead of the row count.
        // #polish 2026-07-06 — collapsed sections now show the
        // hidden row count so users preview what's inside without
        // expanding.
        let header = if is_collapsed {
            Line::from(vec![
                Span::styled("▸ ", dim),
                Span::styled(sec.group.clone(), header_style),
                Span::styled(format!(" ({} · collapsed)", sec.rows.len()), dim),
            ])
        } else {
            Line::from(vec![
                Span::styled("── ", dim),
                Span::styled(sec.group.clone(), header_style),
                Span::styled(format!(" ({})", sec.rows.len()), dim),
            ])
        };
        header_line_indices.push((lines.len(), sec.group.clone()));
        lines.push(header);
        if is_collapsed {
            continue;
        }
        for row in &sec.rows {
            let is_selected = selectable_index == p.selected;
            if is_selected {
                selected_screen_y = Some(lines.len());
            }
            let chord_text = format!("  {:<w$}  ", row.chord, w = chord_w);
            let mut spans = vec![
                Span::styled(chord_text, chord_style),
                Span::styled(row.title.clone(), title_style),
                Span::raw("  "),
                Span::styled(format!("[{}]", row.command_id), id_style),
            ];
            if is_selected {
                spans = spans
                    .into_iter()
                    .map(|s| Span::styled(s.content.into_owned(), sel_style))
                    .collect();
            }
            row_line_indices.push((lines.len(), selectable_index));
            lines.push(Line::from(spans));
            selectable_index += 1;
        }
        // Spacer between sections.
        lines.push(Line::from(""));
    }

    // Auto-scroll so the selected line stays in view.
    let visible_h = inner.height as usize;
    let mut scroll = p.scroll;
    if let Some(sel_y) = selected_screen_y {
        if sel_y < scroll {
            scroll = sel_y;
        } else if sel_y >= scroll + visible_h {
            scroll = sel_y + 1 - visible_h;
        }
    }
    if scroll >= lines.len() {
        scroll = lines.len().saturating_sub(1);
    }
    // Register per-row click rects for the visible window.
    let scroll_u16 = scroll as u16;
    for (line_idx, sel_idx) in &row_line_indices {
        if *line_idx >= scroll && *line_idx < scroll + visible_h {
            let y = inner.y + (*line_idx as u16 - scroll_u16);
            app.rects.list_rows.push((
                ratatui::layout::Rect {
                    x: inner.x,
                    y,
                    width: inner.width,
                    height: 1,
                },
                id,
                *sel_idx,
            ));
        }
    }
    // Register per-header click rects so a click toggles collapse
    // (parity with the `C` chord). 2026-06-21 vscode-mouse SEV-2.
    for (line_idx, group) in &header_line_indices {
        if *line_idx >= scroll && *line_idx < scroll + visible_h {
            let y = inner.y + (*line_idx as u16 - scroll_u16);
            app.rects.cheatsheet_headers.push((
                ratatui::layout::Rect {
                    x: inner.x,
                    y,
                    width: inner.width,
                    height: 1,
                },
                group.clone(),
            ));
        }
    }
    let visible: Vec<Line> = lines.into_iter().skip(scroll).take(visible_h).collect();
    frame.render_widget(Paragraph::new(visible), inner);
}
