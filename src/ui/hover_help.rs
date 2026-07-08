//! Ableton-style hover-help footer strip. A 1-row band at the very
//! bottom of the screen (below the cmdline bar) that describes
//! whatever the mouse is over — chip, menu item, tree row, tab —
//! in plain English, updated on every move.
//!
//! Zero-delay unlike the popup tooltip (`src/ui/tooltip.rs`), which
//! waits `HOVER_TOOLTIP_DELAY_MS`. When nothing's under the mouse,
//! the strip shows a subtle hint about the current focus so it
//! never goes blank-and-purposeless.
//!
//! Toggled by `view.toggle_hover_help` and the `[ui] hover_help`
//! config key. When off, the layout doesn't reserve a row at all.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::ui::theme;

/// Paint the 1-row hover-help footer over `area`. Caller reserves
/// the row only when `app.config.ui.hover_help` is on.
pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let t = theme::cur();
    // Solid background band so it reads as a distinct strip, not
    // an accidental line of body text.
    let bg = t.bg_darker;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);
    let (primary, secondary) = pick_help_text(app);
    let mut spans: Vec<Span<'static>> = Vec::new();
    // Left gutter + a static `?` marker so users learn what the
    // strip is showing them. Cyan so it visually pairs with mnml's
    // accent color.
    spans.push(Span::styled(
        " ? ",
        Style::default()
            .fg(t.cyan)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(
        primary,
        Style::default()
            .fg(t.fg)
            .bg(bg)
            .add_modifier(Modifier::BOLD),
    ));
    if let Some(sub) = secondary {
        spans.push(Span::styled("  ·  ", Style::default().fg(t.comment).bg(bg)));
        spans.push(Span::styled(sub, Style::default().fg(t.comment).bg(bg)));
    }
    // Right-side hint: toggle key discovery so users learn how to
    // dismiss the strip without palette-hunting. Skipped if the
    // primary line already crowds the row.
    let hint = "toggle: view.toggle_hover_help";
    let used: usize = spans.iter().map(|s| s.content.chars().count()).sum();
    let hint_len = hint.chars().count();
    let room = (area.width as usize).saturating_sub(used).saturating_sub(2);
    if room >= hint_len {
        let pad = room.saturating_sub(hint_len);
        spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
        spans.push(Span::styled(
            hint,
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::DIM),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// The hover-help text pair: primary (bold) + optional secondary.
/// Delegates to the same describe logic as `ui::tooltip::describe`
/// but stripped down to just the text (no anchor rect needed here).
fn pick_help_text(app: &App) -> (String, Option<String>) {
    if let Some((chip, _)) = app.hover_chip
        && let Some((primary, secondary)) = crate::ui::tooltip::describe_text(chip, app)
    {
        return (primary, secondary);
    }
    // Nothing hovered — steer users toward the palette so the strip
    // stays useful when the mouse is idle. Kept short.
    let hint = match app.focus {
        crate::focus::Focus::Tree => {
            "sidebar focus — arrows / j/k walk rows · Enter opens · Ctrl+Shift+P palette"
        }
        crate::focus::Focus::Pane => {
            "editor focus — hover a chip / tab / tree row for help · Ctrl+Shift+P palette"
        }
    };
    (hint.to_string(), None)
}
