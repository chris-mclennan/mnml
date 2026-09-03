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

/// A header "mode chip" — ` <key>: <value> `, dark-fg on pale cyan.
///
/// The idiom started on CLOUD AGENTS / AGENTS as ` view: Compact `:
/// click to cycle, right-click for the full list with a ✓ on the
/// current one. User ask 2026-09-03 — TODOS / NOTES / FINDINGS needed
/// the same thing for sort order, "styled like the view buttons on
/// cloud agents area". That is the fifth use, so it lives here rather
/// than being pasted a third time.
///
/// The chip carries its own label because a bare value (` Newest `)
/// does not say what it controls; `view:` and `sort:` are what make
/// two chips in one header distinguishable.
pub fn mode_chip_text(key: &str, value: &str) -> String {
    format!(" {key}: {value} ")
}

/// The chip's style. Split out so a caller painting the chip inside a
/// larger `Line` (the way CLOUD AGENTS builds its header) matches a
/// caller using [`draw_caps_header_with_chips`].
pub fn mode_chip_style(t: &Theme) -> Style {
    Style::default()
        .fg(t.bg)
        .bg(t.cyan)
        .add_modifier(Modifier::BOLD)
}

/// Caps header with a right-aligned cluster: an optional mode chip
/// followed by the refresh chip. Returns `(chip_rect, refresh_rect)`.
///
/// Widths are resolved right-to-left, and each chip is dropped rather
/// than clipped when it will not fit — a half-painted chip is a dead
/// click target, which is worse than an absent one. The refresh chip
/// wins the last cells because it is the older affordance and users
/// already reach for it by position.
// Eight parameters, one over clippy's threshold. Bundling them into a
// config struct would add a type whose only job is to be destructured
// at the single call shape all three panels already use — the
// parameters are the panel's own header fields, not a reusable set.
#[allow(clippy::too_many_arguments)]
pub fn draw_caps_header_with_chips(
    frame: &mut Frame,
    area: Rect,
    label: &str,
    subtitle: Option<&str>,
    chip: Option<&str>,
    bg: Color,
    t: &Theme,
    ascii: bool,
) -> (Option<Rect>, Option<Rect>) {
    let refresh_text = crate::ui::refresh_glyph::chip_icon_only(ascii);
    let refresh_w = refresh_text.chars().count() as u16;
    let label_w = label.chars().count() as u16;
    let sub_w = subtitle.map(|s| s.chars().count() as u16).unwrap_or(0);
    let chip_w = chip.map(|c| c.chars().count() as u16).unwrap_or(0);

    // 1 leading pad + label + subtitle + a gap before each chip.
    let refresh_fits = area.width >= label_w + sub_w + refresh_w + 3;
    if !refresh_fits {
        // Too narrow for any chip — fall back to the plain header so
        // the title still paints.
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(label.to_string(), caps_label_style(t, bg)),
            ])),
            area,
        );
        return (None, None);
    }
    let chip_fits = chip_w > 0 && area.width >= label_w + sub_w + refresh_w + chip_w + 4;

    let refresh_x = area.x + area.width.saturating_sub(refresh_w);
    // The chip sits immediately left of the refresh chip, with one
    // cell of air between them.
    let chip_x = refresh_x.saturating_sub(chip_w + 1);

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
            width: if chip_fits {
                chip_x.saturating_sub(area.x)
            } else {
                area.width.saturating_sub(refresh_w)
            },
            ..area
        },
    );

    let chip_rect = if chip_fits {
        let r = Rect {
            x: chip_x,
            y: area.y,
            width: chip_w,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                chip.unwrap_or("").to_string(),
                mode_chip_style(t),
            ))),
            r,
        );
        Some(r)
    } else {
        None
    };

    let refresh_rect = Rect {
        x: refresh_x,
        y: area.y,
        width: refresh_w,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            refresh_text,
            Style::default().fg(t.cyan).bg(bg),
        ))),
        refresh_rect,
    );
    (chip_rect, Some(refresh_rect))
}

/// Scroll window for a simple list panel: clamp `scroll` so `cursor`
/// stays visible, and report `(first_visible, visible_rows, needs_bar)`.
///
/// Shared because TODOS / NOTES / FINDINGS each grew the same list and
/// each shipped WITHOUT scrolling — they drew one screenful and dropped
/// the rest silently. Keeping the arithmetic in one place is what stops
/// the fourth such panel repeating it.
pub fn list_scroll_window(
    scroll: &mut usize,
    cursor: usize,
    total: usize,
    visible_rows: usize,
) -> (usize, usize, bool) {
    if visible_rows == 0 || total == 0 {
        *scroll = 0;
        return (0, 0, false);
    }
    // Follow the cursor in both directions.
    if cursor < *scroll {
        *scroll = cursor;
    } else if cursor >= *scroll + visible_rows {
        *scroll = cursor + 1 - visible_rows;
    }
    // Never leave blank rows below a full list.
    let max_scroll = total.saturating_sub(visible_rows);
    if *scroll > max_scroll {
        *scroll = max_scroll;
    }
    (
        *scroll,
        visible_rows.min(total - *scroll),
        total > visible_rows,
    )
}

#[cfg(test)]
mod mode_chip_tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn render(w: u16, chip: Option<&str>) -> (String, Option<Rect>, Option<Rect>) {
        let t = crate::ui::theme::cur();
        let mut term = Terminal::new(TestBackend::new(w, 1)).unwrap();
        let mut got = (None, None);
        term.draw(|f| {
            got = draw_caps_header_with_chips(
                f,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: 1,
                },
                "FINDINGS",
                Some("  (38)"),
                chip,
                t.bg_darker,
                &t,
                true,
            );
        })
        .unwrap();
        let buf = term.backend().buffer();
        let row: String = (0..w).map(|x| buf[(x, 0)].symbol()).collect();
        (row, got.0, got.1)
    }

    /// The whole point of the chip: the sort mode is VISIBLE. It was
    /// previously reachable only by right-clicking the refresh chip,
    /// which is why the user reported the panels as having no sorting
    /// options at all.
    #[test]
    fn the_chip_paints_its_value_and_returns_a_hit_rect() {
        let (row, chip, refresh) = render(60, Some(&mode_chip_text("sort", "Newest first")));
        assert!(row.contains("FINDINGS"), "title missing: {row:?}");
        assert!(
            row.contains("sort: Newest first"),
            "the chip's value is not on screen: {row:?}"
        );
        let chip = chip.expect("no chip rect returned — the chip would be unclickable");
        assert!(refresh.is_some(), "refresh chip lost");
        // The rect must actually cover the painted text, or the click
        // target and the pixels disagree.
        let painted: String = row
            .chars()
            .skip(chip.x as usize)
            .take(chip.width as usize)
            .collect();
        assert!(
            painted.contains("Newest first"),
            "the returned rect does not cover the chip text: {painted:?}"
        );
    }

    /// A chip that will not fit must be DROPPED, not clipped — a
    /// half-painted chip is a dead click target, and worse than none.
    /// The refresh chip wins the last cells because users already
    /// reach for it by position.
    #[test]
    fn a_chip_that_does_not_fit_is_dropped_not_clipped() {
        let (row, chip, refresh) = render(24, Some(&mode_chip_text("sort", "Newest first")));
        assert!(chip.is_none(), "a chip was returned at 24 cells: {row:?}");
        assert!(
            !row.contains("sort:"),
            "the chip painted anyway, clipped: {row:?}"
        );
        assert!(
            refresh.is_some(),
            "the refresh chip was dropped before the sort chip: {row:?}"
        );
        assert!(row.contains("FINDINGS"), "title lost: {row:?}");
    }

    /// Passing no chip must behave exactly like the old
    /// refresh-only header — the panels that never grow a chip keep
    /// their layout.
    #[test]
    fn no_chip_leaves_the_refresh_only_header_intact() {
        let (row, chip, refresh) = render(60, None);
        assert!(chip.is_none());
        assert!(refresh.is_some(), "refresh chip missing with no mode chip");
        assert!(row.contains("FINDINGS"));
    }
}
