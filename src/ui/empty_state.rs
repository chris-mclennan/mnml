//! Shared visual language for activity-panel empty-state
//! messages — the "No sessions yet" / "No matches — Esc clears"
//! / "No findings match /foo — 7 in workspace" family.
//!
//! Before this module lived here, each panel hand-rolled the
//! same two spans: an initial `"  "` pad on the panel bg, then
//! a comment-fg message on the panel bg. Some panels also
//! appended a second DIM hint row (e.g. "Stored under
//! .mnml/notes/*.md"). Centralized here alongside the other
//! shared visual constants so tone + spacing stay in sync as
//! new panels are added. User ask 2026-08-23: "think about
//! other ways we can set constants to keep ui look and feel".
//!
//! `draw(frame, area, message, hint, bg, t)`:
//! - Row 0: `"  " + message` (comment fg on panel bg).
//! - Row 1 (only if `hint` provided): `"  " + hint` (comment fg
//!   on panel bg, DIM).
//! - Advances `area.y` accordingly and returns the next y the
//!   caller should render at (so surrounding layout can keep
//!   composing rows).

use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
};

use crate::ui::theme::Theme;

/// Render an empty-state message (and optional dim hint below)
/// starting at `area.y`, clipped to `area.height`. Returns the
/// next y after the block (`area.y + rows_drawn`).
pub fn draw(
    frame: &mut Frame,
    area: Rect,
    message: &str,
    hint: Option<&str>,
    bg: Color,
    t: &Theme,
) -> u16 {
    let mut y = area.y;
    if y >= area.y + area.height {
        return y;
    }
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(message.to_string(), Style::default().fg(t.comment).bg(bg)),
        ])),
        Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        },
    );
    y += 1;
    if let Some(hint_text) = hint
        && y < area.y + area.height
    {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    hint_text.to_string(),
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
    }
    y
}
