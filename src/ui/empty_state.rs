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
///
/// Narrow panels (mouse-r16 SEV-3): messages that don't fit inside
/// `area.width - 2` cells (2-cell leading pad) get truncated with
/// an ellipsis rather than clipped mid-word by ratatui's default
/// span cropping. Below ~10 usable cells the message is dropped
/// entirely — an ellipsis alone teaches nothing.
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
    let usable = area.width.saturating_sub(2) as usize;
    if let Some(msg) = fit(message, usable) {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(msg, Style::default().fg(t.comment).bg(bg)),
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
    if let Some(hint_text) = hint
        && y < area.y + area.height
        && let Some(hint_str) = fit(hint_text, usable)
    {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    hint_str,
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

/// Fit `s` into `usable` chars. `None` when there isn't room for
/// even a meaningful stub (<6 chars — an ellipsis alone teaches
/// nothing). Returns the string unchanged when it fits; otherwise
/// truncates and appends `…`.
fn fit(s: &str, usable: usize) -> Option<String> {
    const MIN: usize = 6;
    if usable < MIN {
        return None;
    }
    if s.chars().count() <= usable {
        return Some(s.to_string());
    }
    let take = usable.saturating_sub(1); // room for the ellipsis
    let truncated: String = s.chars().take(take).collect();
    Some(format!("{truncated}\u{2026}"))
}

#[cfg(test)]
mod tests {
    use super::fit;

    #[test]
    fn returns_string_when_it_fits() {
        assert_eq!(fit("short", 20), Some("short".to_string()));
    }

    #[test]
    fn truncates_with_ellipsis_when_over_budget() {
        assert_eq!(fit("hello world", 8), Some("hello w\u{2026}".to_string()));
    }

    #[test]
    fn drops_the_message_entirely_below_min_cells() {
        assert_eq!(fit("hello world", 5), None);
    }
}
