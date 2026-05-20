//! AI ghost-text overlay — paints the active editor's pending inline
//! suggestion (`Editor.ghost_suggestion`) in dim grey starting at the
//! cursor cell. A post-process pass like `md_inline_overlay`: the main
//! editor render already happened; this just tints cells on top.
//!
//! First line of the suggestion is painted from the cursor column;
//! subsequent lines from the editor pane's left text edge on the rows
//! below. Everything clips to the pane + screen.

use ratatui::Frame;
use ratatui::style::{Modifier, Style};
use ratatui::text::Span;
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, cursor_pos: Option<(u16, u16)>) {
    let Some((cx, cy)) = cursor_pos else {
        return;
    };
    // The active editor must be a buffer with a pending suggestion.
    let Some(pane_id) = app.active else {
        return;
    };
    let suggestion = match app.panes.get(pane_id) {
        Some(Pane::Editor(b)) => match &b.editor.ghost_suggestion {
            Some(s) if !s.is_empty() => s.clone(),
            _ => return,
        },
        _ => return,
    };
    // Editor pane rect — for the continuation-line left edge + width clamp.
    let Some(&(area, _)) = app
        .rects
        .editor_panes
        .iter()
        .find(|(_, pid)| *pid == pane_id)
    else {
        return;
    };
    let t = theme::cur();
    let style = Style::default()
        .fg(t.comment)
        .add_modifier(Modifier::ITALIC);

    let right_edge = area.x + area.width;
    let bottom_edge = area.y + area.height;
    for (line_idx, line) in suggestion.lines().enumerate() {
        let y = cy + line_idx as u16;
        if y >= bottom_edge {
            break;
        }
        // First line starts at the cursor column; the rest at the
        // pane's text-area left edge.
        let x = if line_idx == 0 { cx } else { area.x };
        if x >= right_edge {
            continue;
        }
        let avail = (right_edge - x) as usize;
        let shown: String = line.chars().take(avail).collect();
        if shown.is_empty() {
            continue;
        }
        let w = shown.chars().count() as u16;
        frame.render_widget(
            Paragraph::new(Span::styled(shown, style)),
            ratatui::layout::Rect {
                x,
                y,
                width: w,
                height: 1,
            },
        );
    }
}
