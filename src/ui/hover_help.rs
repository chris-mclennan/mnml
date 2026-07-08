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
///
/// Fallback ladder when no chip is hovered:
///   1. Active pane summary (file / URL / kind) — Ableton-style
///      "here's what you're looking at".
///   2. Focus hint pointing at the palette.
fn pick_help_text(app: &App) -> (String, Option<String>) {
    if let Some((chip, _)) = app.hover_chip
        && let Some((primary, secondary)) = crate::ui::tooltip::describe_text(chip, app)
    {
        return (primary, secondary);
    }
    // Active-pane summary — reads out the file / request / diff
    // that has focus so the strip is useful when the mouse is idle.
    if let Some(cur) = app.active
        && let Some(pane) = app.panes.get(cur)
        && let Some(pair) = describe_active_pane(pane)
    {
        return pair;
    }
    // Last-resort — steer users toward the palette.
    let hint = match app.focus {
        crate::focus::Focus::Tree => {
            "sidebar focus — arrows / j/k walk rows · Enter opens · Ctrl+Shift+P palette"
        }
        crate::focus::Focus::Pane => {
            "hover a chip / tab / tree row for help · Ctrl+Shift+P palette"
        }
    };
    (hint.to_string(), None)
}

fn describe_active_pane(pane: &crate::pane::Pane) -> Option<(String, Option<String>)> {
    use crate::pane::Pane;
    match pane {
        Pane::Editor(b) => {
            let title = pane.title();
            let lang = b
                .language_ext
                .as_deref()
                .map(|e| e.to_ascii_uppercase())
                .unwrap_or_else(|| "TEXT".to_string());
            let lines = b.editor.text().lines().count().max(1);
            let dirty = if b.dirty { " · unsaved" } else { "" };
            let primary = format!("{title}  ·  {lang}  ·  {lines} lines{dirty}");
            let secondary = if b.is_preview {
                Some("preview tab — first edit or double-click promotes it".to_string())
            } else if b.is_pinned {
                Some("pinned — stays at front of the bufferline".to_string())
            } else {
                None
            };
            Some((primary, secondary))
        }
        Pane::Request(_) => Some((
            pane.title(),
            Some("Request pane — Enter to send · Ctrl+S saves as .http/.curl".into()),
        )),
        Pane::Pty(_) => Some((
            pane.title(),
            Some("terminal pane — Ctrl+Alt+H to detach, Ctrl+Alt+K to kill".into()),
        )),
        Pane::MdPreview(_) => Some((
            pane.title(),
            Some("rendered markdown preview — click header chip to jump back to source".into()),
        )),
        Pane::Ai(_) => Some((
            pane.title(),
            Some("Claude / Codex session — type at the bottom prompt".into()),
        )),
        _ => Some((pane.title(), None)),
    }
}
