//! Design tokens — the app-wide "style guide" for overlay chrome.
//!
//! Two overlay shapes are recognized:
//!
//! - **Modal** — big-panel style, input-stealing. Picker, settings,
//!   help, integration edit, glyph builder. Square borders,
//!   `fg`-colored border stroke, `bg_dark` background, cyan title bar.
//!   Used by ~30 of the ~35 overlays in the app; this is the default
//!   for anything that reads as "a real panel."
//!
//! - **Popup** — transient / anchored / non-input-stealing. Hover
//!   tooltip, signature-help, right-click menu, cmdline popup,
//!   whichkey, close-prompt. Rounded borders, blue border stroke,
//!   `bg_darker` background, no strong title bar. Reads visually as
//!   "a floating chip" rather than a page.
//!
//! To change the app-wide look, edit these functions. Overlays that
//! call `modal_panel(title)` / `popup_panel(title)` automatically
//! pick up the change; overlays that still hand-roll their Block
//! stay put (migrate them opportunistically).

use ratatui::style::{Modifier, Style};
use ratatui::text::Span;
use ratatui::widgets::{Block, BorderType, Borders};

use crate::ui::theme;

/// Modal-panel chrome. Returns a configured `Block` ready to render.
/// The caller emits the widget + uses `block.inner()` for its content.
pub fn modal_panel(title: impl AsRef<str>) -> Block<'static> {
    let t = theme::cur();
    let title = format!(" {} ", title.as_ref().trim());
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .border_style(Style::default().fg(t.fg).bg(t.bg_dark))
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_dark)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg_dark))
}

/// Popup-style chrome for anchored / transient overlays. Rounded
/// border, subtle color accent, `bg_darker` fill.
pub fn popup_panel(title: impl AsRef<str>) -> Block<'static> {
    let t = theme::cur();
    let title = format!(" {} ", title.as_ref().trim());
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t.blue).bg(t.bg_darker))
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.blue)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg_darker))
}

/// Style for the hint line at the bottom of a modal panel — the
/// `↵ save · esc cancel · …` help row that every panel-form uses.
pub fn hint_style() -> Style {
    let t = theme::cur();
    Style::default().fg(t.comment).bg(t.bg_dark)
}

/// Style for a section-label row inside a modal — the dim italic
/// tag above a group of related fields (e.g. `preview` label above
/// the preview area). Optional; use where visual grouping helps.
pub fn section_label_style() -> Style {
    let t = theme::cur();
    Style::default()
        .fg(t.comment)
        .bg(t.bg_dark)
        .add_modifier(Modifier::ITALIC)
}
