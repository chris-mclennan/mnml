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

use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
};

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

/// Render the caps title (`GIT` / `TODOS` / …) on the left of
/// `area` plus a right-aligned refresh ↻ chip. Returns the
/// refresh chip's `Rect` for the caller to stash as a click
/// target; `None` when the panel is too narrow (< `label + 4`
/// cells) to fit the chip without clipping the title.
///
/// The chip is icon-only (3 cells: ` glyph `) and cyan-fg to
/// match the file-tree Fetch chip + HTTP's refresh chip. User
/// ask 2026-08-23: refresh buttons across panels should sit
/// in the same place and look the same. This helper is the
/// canonical shape — new panels call it instead of hand-rolling.
pub fn draw_caps_header_with_refresh(
    frame: &mut Frame,
    area: Rect,
    label: &str,
    subtitle: Option<&str>,
    bg: Color,
    t: &Theme,
    ascii: bool,
) -> Option<Rect> {
    let refresh_text = crate::ui::refresh_glyph::chip_icon_only(ascii);
    let refresh_w = refresh_text.chars().count() as u16;
    let refresh_x = area.x.saturating_add(area.width.saturating_sub(refresh_w));
    let label_w = label.chars().count() as u16;
    // 1 leading pad + label + trailing gap + refresh chip.
    let fits = area.width >= label_w + refresh_w + 3;
    let mut spans = vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(label.to_string(), caps_label_style(t, bg)),
    ];
    if let Some(sub) = subtitle
        && !sub.is_empty()
    {
        spans.push(Span::styled(sub.to_string(), caps_subtitle_style(t, bg)));
    }
    frame.render_widget(
        Paragraph::new(Line::from(spans)),
        Rect {
            x: area.x,
            y: area.y,
            width: if fits {
                area.width.saturating_sub(refresh_w)
            } else {
                area.width
            },
            height: 1,
        },
    );
    if !fits {
        return None;
    }
    let refresh_rect = Rect {
        x: refresh_x,
        y: area.y,
        width: refresh_w,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![Span::styled(
            refresh_text,
            Style::default().fg(t.cyan).bg(bg),
        )])),
        refresh_rect,
    );
    Some(refresh_rect)
}
