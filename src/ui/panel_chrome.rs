//! Shared visual chrome that every activity-bar panel wears —
//! the caps section title (`SESSIONS`, `NOTES`, `GIT`, …), the
//! optional dim `(N of M)` subtitle that follows when a filter is
//! active, and the background of the filter-row pill that sits
//! directly below it.
//!
//! Before this module lived here, each panel hand-rolled the same
//! spans: `fg=t.comment · bg=t.bg_darker · BOLD` for the title,
//! `bg=t.bg2` for the filter chip. Any tweak (weight, contrast,
//! chip color) had to be applied identically across ~8 files.
//! Centralized here alongside the other shared visual constants
//! (`session_color`, `search_glyph`, `filter_placeholder`,
//! `action_button`) so a design change flows through every panel
//! automatically. User ask 2026-08-23: "think about other ways we
//! can set constants to keep ui look and feel and if we change
//! 1 thing we can see it carry over all over".
//!
//! The functions return `Style`s and `Color`s rather than complete
//! `Line`s because panels compose extra pieces onto the header
//! (git adds a ↻ refresh chip on the right; sessions appends a
//! `(N of M)` filter count). Callers keep control of the row
//! layout — only the shared style values live here.

use ratatui::style::{Color, Modifier, Style};

use crate::ui::theme::Theme;

/// Background color of the filter-row input pill (the `\u{F0349} / filter`
/// chip that every panel renders on row 1). One source of truth so a
/// palette change lands in every panel at once.
#[inline]
pub fn filter_chip_bg(t: &Theme) -> Color {
    t.bg2
}

/// Style of the caps section title (`SESSIONS`, `NOTES`, `GIT`, …).
/// `bg` is the panel's own background — the header sits directly on
/// the panel bg, not on a chip.
#[inline]
pub fn caps_label_style(t: &Theme, bg: Color) -> Style {
    Style::default()
        .fg(t.comment)
        .bg(bg)
        .add_modifier(Modifier::BOLD)
}

/// Style of the dim `(N of M)` subtitle that follows the caps
/// label when a filter is active. Same `bg` as the caps label —
/// they render on the same row.
#[inline]
pub fn caps_subtitle_style(t: &Theme, bg: Color) -> Style {
    Style::default()
        .fg(t.comment)
        .bg(bg)
        .add_modifier(Modifier::DIM)
}
