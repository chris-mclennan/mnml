//! Shared visual language for the "primary" and "secondary" action
//! chips that sit at the top of every activity-bar panel — the
//! `+ New session`, `+ New note`, `+ from PR`, `+ New Cloud Run`
//! family.
//!
//! Before this module lived here the chips had drifted individually:
//! agents_panel used a solid green + solid cyan (the reference the
//! user liked), but sessions_panel and notes_panel used `bg2` (grey)
//! chips with green text — which visually blended into the filter
//! row's grey chip immediately above. User ask 2026-08-23:
//! "lets set a constant for these buttons and keep them in sync ...
//! primary and secondary buttons ... each of these areas in
//! activity bar should have same look and feel".
//!
//! Two roles, sourced from the active theme so a theme change flows
//! through every panel automatically:
//!
//! - **Primary** — the panel's main call-to-action ("+ New X").
//!   Green fill, dark text.
//! - **Secondary** — a peer action on the same row ("+ from PR",
//!   "Import…"). Purple fill, dark text.
//!
//! Callers wrap a label in [`chip_line`] to render a full padded
//! button, or grab [`primary`]/[`secondary`] directly if they need
//! to compose spans by hand.

use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span},
};

use crate::ui::theme::Theme;

/// Pure black used as the label fg on filled `primary` /
/// `secondary` chips. The theme's `bg_darker` isn't dark enough
/// against mid-brightness fills (soft-green / soft-purple) —
/// user report 2026-08-23: chip label unreadable when routed
/// through `bg_darker`. Rgb(0,0,0) guarantees max contrast
/// across every theme.
const CHIP_LABEL_FG: Color = Color::Rgb(0, 0, 0);

/// Primary action chip style — the panel's main call-to-action.
/// Solid green fill + black text. Use for toolbar-level actions
/// (`+ New session`, `+ New note`).
#[inline]
pub fn primary(t: &Theme) -> Style {
    Style::default()
        .fg(CHIP_LABEL_FG)
        .bg(t.green)
        .add_modifier(Modifier::BOLD)
}

/// Secondary action chip style — a peer action on the same row.
/// Solid purple fill + black text. Use next to a `primary` chip
/// when the panel has two peer create-flows (`+ from PR`).
#[inline]
pub fn secondary(t: &Theme) -> Style {
    Style::default()
        .fg(CHIP_LABEL_FG)
        .bg(t.purple)
        .add_modifier(Modifier::BOLD)
}

/// Text-link "add row" style — green text on the panel's own
/// background, no chip fill. Use for inline "+ New X" prompts
/// that sit at the end of a listed section (HTTP's per-section
/// `+ New request` / `+ New env` / `+ New chain` /
/// `+ New collection`) where a filled chip would read as a
/// heavy button in the middle of a list.
#[inline]
pub fn link(t: &Theme, bg: Color) -> Style {
    Style::default()
        .fg(t.green)
        .bg(bg)
        .add_modifier(Modifier::BOLD)
}

/// Render a full labeled chip: 1-cell pad + label + 1-cell pad, all
/// on the given `role_style`'s background. Returns a `Line` the
/// caller can drop into a `Paragraph` at a `Rect` sized to
/// [`chip_width`]. `role_style` is either [`primary`] or
/// [`secondary`].
pub fn chip_line(label: &str, role_style: Style) -> Line<'_> {
    Line::from(vec![
        Span::styled(" ", role_style),
        Span::styled(label.to_string(), role_style),
        Span::styled(" ", role_style),
    ])
}

/// Cell width of the chip [`chip_line`] renders — label plus the
/// two 1-cell pads.
#[inline]
pub fn chip_width(label: &str) -> u16 {
    (label.chars().count() as u16).saturating_add(2)
}
