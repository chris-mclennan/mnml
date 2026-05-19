//! F1 discovery overlay — a centered floating panel listing every clickable
//! region category with live counts. Closes the discoverability loop for
//! mouse users without crowding the chrome with permanent hint text.
//!
//! Toggle with F1 (also `view.discovery`); Esc dismisses. While open the
//! rest of the UI keeps painting — the overlay's a translucent guide,
//! not modal-blocking.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

/// Render the overlay if toggled on. Sized + positioned in the center of
/// the screen, ~70 cols by ~22 rows; clamps to fit smaller terminals.
pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    if !app.show_discovery_overlay {
        return;
    }
    let t = theme::cur();
    // Build the rows — each is one clickable category with a live count.
    type Row = (&'static str, &'static str, usize);
    let rows: [Row; 11] = [
        ("Mode chip", "click: toggle vim/standard · right: input menu", 1),
        (
            "Branch chip",
            "click: commit graph · right: git ops menu",
            usize::from(app.rects.statusline_branch_chip.is_some()),
        ),
        (
            "Workspace chip",
            "click: switch repo · right: workspace menu",
            usize::from(app.rects.statusline_workspace_chip.is_some()),
        ),
        (
            "Clock chip",
            "click: local↔UTC · right: clock menu",
            usize::from(app.rects.statusline_clock_chip.is_some()),
        ),
        (
            "Bufferline tabs",
            "click: focus · middle: close · right: tab menu",
            app.rects.bufferline_tabs.len(),
        ),
        (
            "> GIT rail header",
            "Fetch / Pull / Push / Stage all / Commit / Graph",
            app.rects.rail_git_header_buttons.len(),
        ),
        (
            "Editor gutter",
            "right-click line: breakpoint / goto def / refs / blame…",
            app.rects.editor_gutters.len(),
        ),
        (
            "Diff toolbar",
            "Hunk / Inline / Split / Wrap / Close chips",
            app.rects.diff_toolbar_buttons.len(),
        ),
        (
            "Fold chips (⋯)",
            "click to expand the folded block",
            app.rects.fold_chips.len(),
        ),
        (
            "Code-lens chips (⚡)",
            "click to run the lens command",
            app.rects.code_lens_chips.len(),
        ),
        (
            "Split dividers",
            "hover turns yellow · drag to resize",
            app.rects.split_dividers.len(),
        ),
    ];

    let title = " Click Discovery — F1 / Esc to close ";
    // Inner content width: max of (label + 2 + detail + 6 for count chip).
    let inner_w = rows
        .iter()
        .map(|(label, detail, _)| label.chars().count() + 2 + detail.chars().count() + 6)
        .max()
        .unwrap_or(50)
        .max(title.chars().count() + 4);
    let w = (inner_w as u16 + 4).min(screen.width); // 2 borders + 2 padding
    let h = (rows.len() as u16 + 2 + 2).min(screen.height); // 2 borders + 2 padding row
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 3);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.yellow)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(rows.len() + 1);
    for (label, detail, count) in rows.iter() {
        let live = *count > 0;
        let count_chip = if live {
            format!("[{count}]")
        } else {
            "[ ]".into()
        };
        let count_style = if live {
            Style::default()
                .fg(t.bg_darker)
                .bg(t.green)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg2)
        };
        let label_style = if live {
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment)
        };
        let detail_style = if live {
            Style::default().fg(t.comment)
        } else {
            Style::default().fg(t.bg3)
        };
        let spans = vec![
            Span::styled(" ", Style::default().bg(t.bg2)),
            Span::styled(count_chip, count_style),
            Span::styled("  ", Style::default().bg(t.bg2)),
            Span::styled(label.to_string(), label_style),
            Span::styled("  ", Style::default().bg(t.bg2)),
            Span::styled(detail.to_string(), detail_style),
        ];
        lines.push(Line::from(spans));
    }
    lines.push(Line::from(Span::styled(
        " green count = at least one is visible right now ".to_string(),
        Style::default()
            .fg(t.comment)
            .bg(t.bg2)
            .add_modifier(Modifier::ITALIC),
    )));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}
