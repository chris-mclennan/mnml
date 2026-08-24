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
    style::{Modifier, Style},
    text::{Line, Span},
};

use crate::ui::theme::Theme;

/// Primary action chip style — the panel's main call-to-action.
#[inline]
pub fn primary(t: &Theme) -> Style {
    Style::default()
        .fg(t.bg_darker)
        .bg(t.green)
        .add_modifier(Modifier::BOLD)
}

/// Secondary action chip style — a peer action on the same row.
#[inline]
pub fn secondary(t: &Theme) -> Style {
    Style::default()
        .fg(t.bg_darker)
        .bg(t.purple)
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
