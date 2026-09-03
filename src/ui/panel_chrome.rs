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
pub fn mode_chip_text(key: &str, value: &str, widest: usize) -> String {
    // Pad to the WIDEST value the chip can ever hold, so the chip does
    // not resize when the mode changes.
    //
    // 2026-09-03 bug-hunt 2-B: the chip is right-anchored, so shrinking
    // the label moved its left edge rightward and out from under the
    // pointer. Clicking the word `sort:` advanced twice and then went
    // dead with no pointer movement — "the button works sometimes".
    // Same principle as the leaf tab strip's arrow slots: reserve the
    // space once so the affordance cannot move under the cursor.
    let pad = widest.saturating_sub(value.chars().count());
    format!(" {key}: {value}{} ", " ".repeat(pad))
}

/// The narrow form: an icon only, no key and no value.
///
/// The full chip needs ~38 cells with its panel title and count; the
/// shipped default sidebar is 26, so at stock settings the expanded
/// chip never appeared at all — the sorting the user asked for was
/// invisible for anyone who had not widened the rail (found by two
/// independent bug-hunts, 2026-09-03).
///
/// Dropping to an icon is what the refresh chip beside it already
/// does, so the narrow header reads as one family rather than one chip
/// vanishing. Right-click still opens the full menu with every mode
/// spelled out, which is where the words belong anyway.
pub fn mode_chip_icon(ascii: bool) -> &'static str {
    if ascii { " ~ " } else { " \u{f0dc} " }
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

    // The subtitle is DROPPABLE; the title and the refresh chip are not.
    //
    // 2026-09-03 bug-hunt 2-C: folding the subtitle into the
    // refresh-fits budget meant typing in the filter — which grows
    // `(N)` into `(N of M)` — could push the header over and delete the
    // refresh chip mid-interaction. The helper this replaced sized the
    // refresh chip against `label + refresh + 3` only and always
    // emitted the subtitle, so that was a regression.
    let refresh_fits = area.width >= label_w + refresh_w + 3;
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
    // Drop the subtitle rather than the refresh chip when both cannot
    // fit — the count is nice, the refresh button is functional.
    let sub_fits = area.width >= label_w + sub_w + refresh_w + 3;
    let subtitle = if sub_fits { subtitle } else { None };
    let sub_w = if sub_fits { sub_w } else { 0 };

    // Three chip widths, tried widest-first: the full ` key: value `,
    // then the icon-only form, then nothing. The middle rung is what
    // makes the chip exist at the shipped default sidebar width, where
    // the full form needs ~38 cells against 26 available.
    let full_w = chip.map(|c| c.chars().count() as u16).unwrap_or(0);
    let icon = mode_chip_icon(ascii);
    let icon_w = icon.chars().count() as u16;
    let (chip, chip_w) = if chip.is_none() {
        (None, 0)
    } else if area.width >= label_w + sub_w + refresh_w + full_w + 4 {
        (chip, full_w)
    } else if area.width >= label_w + sub_w + refresh_w + icon_w + 4 {
        (Some(icon), icon_w)
    } else {
        (None, 0)
    };
    let chip_fits = chip_w > 0;

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

    /// The whole point of the chip: the sort mode is VISIBLE.
    #[test]
    fn the_chip_paints_its_value_and_returns_a_hit_rect() {
        let (row, chip, refresh) = render(60, Some(&mode_chip_text("sort", "Newest first", 12)));
        assert!(row.contains("FINDINGS"), "title missing: {row:?}");
        assert!(
            row.contains("sort: Newest first"),
            "the chip's value is not on screen: {row:?}"
        );
        let chip = chip.expect("no chip rect returned — the chip would be unclickable");
        assert!(refresh.is_some(), "refresh chip lost");
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

    /// THE SHIPPED DEFAULT. `[ui] tree_width = 30` leaves the panel
    /// about 26 cells, and the full chip needs ~38 — so at stock
    /// settings the chip did not render AT ALL, and the sorting the
    /// user asked for was invisible to anyone who had not widened the
    /// rail. Two independent bug-hunts found it on the same day.
    ///
    /// The original tests here rendered at 60 and 24 — bracketing the
    /// default without ever testing it. This test exists because that
    /// gap is what let the feature ship broken.
    #[test]
    fn the_chip_is_reachable_at_the_default_sidebar_width() {
        for w in [26u16, 30, 34] {
            let (row, chip, refresh) = render(w, Some(&mode_chip_text("sort", "Newest first", 12)));
            assert!(
                chip.is_some(),
                "no sort affordance at all at width {w} (the shipped default \
                 leaves ~26): {row:?}"
            );
            assert!(refresh.is_some(), "refresh chip lost at width {w}");
            assert!(row.contains("FINDINGS"), "title lost at width {w}: {row:?}");
            // The rect must cover something painted, or it is a click
            // target over blank cells.
            let r = chip.unwrap();
            let painted: String = row
                .chars()
                .skip(r.x as usize)
                .take(r.width as usize)
                .collect();
            assert!(
                !painted.trim().is_empty(),
                "the chip rect at width {w} covers only blanks: {painted:?}"
            );
        }
    }

    /// The chip must not RESIZE when the mode changes: it is
    /// right-anchored, so a shorter label moves its left edge rightward
    /// and out from under a pointer that is repeat-clicking. Users saw
    /// two clicks land and the third do nothing.
    #[test]
    fn the_chip_keeps_a_fixed_width_across_modes() {
        let widest = crate::ui::list_sort::ListSort::all()
            .iter()
            .map(|m| m.label().chars().count())
            .max()
            .unwrap();
        let mut rects = Vec::new();
        for m in crate::ui::list_sort::ListSort::all() {
            let (_, chip, _) = render(60, Some(&mode_chip_text("sort", m.label(), widest)));
            rects.push(chip.expect("chip vanished for a mode"));
        }
        let first = rects[0];
        for (m, r) in crate::ui::list_sort::ListSort::all().iter().zip(&rects) {
            assert_eq!(
                (r.x, r.width),
                (first.x, first.width),
                "the chip moved or resized for {m:?} — a repeat-click would miss it"
            );
        }
    }

    /// A narrow chip that will not fit even as an icon is DROPPED, not
    /// clipped — a half-painted chip is a dead click target.
    #[test]
    fn a_chip_that_does_not_fit_is_dropped_not_clipped() {
        // 17 cells: title(8) + refresh(3) + icon(3) + gaps(4) = 18, so
        // even the icon form cannot fit and the chip must vanish
        // entirely rather than paint a partial target.
        let (row, chip, refresh) = render(17, Some(&mode_chip_text("sort", "Newest first", 12)));
        assert!(chip.is_none(), "a chip was returned at 17 cells: {row:?}");
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

    /// The subtitle is droppable; the refresh chip is not. Typing in a
    /// filter grows `(N)` into `(N of M)`, which used to push the
    /// header over budget and delete the refresh chip mid-interaction.
    #[test]
    fn a_long_subtitle_drops_itself_before_the_refresh_chip() {
        let t = crate::ui::theme::cur();
        let mut term = Terminal::new(TestBackend::new(22, 1)).unwrap();
        let mut got = (None, None);
        term.draw(|f| {
            got = draw_caps_header_with_chips(
                f,
                Rect {
                    x: 0,
                    y: 0,
                    width: 22,
                    height: 1,
                },
                "FINDINGS",
                Some("  (10 of 92)"),
                None,
                t.bg_darker,
                &t,
                true,
            );
        })
        .unwrap();
        let buf = term.backend().buffer();
        let row: String = (0..22).map(|x| buf[(x, 0)].symbol()).collect();
        assert!(
            got.1.is_some(),
            "the refresh chip was dropped to make room for a count: {row:?}"
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

#[cfg(test)]
mod drop_order_consistency_tests {
    /// One answer to "which chip survives narrowing", across every
    /// panel that has both a mode chip and a refresh chip.
    ///
    /// The four list panels dropped their `sort:` chip and kept
    /// refresh; AGENTS and CLOUD AGENTS did the opposite, because they
    /// folded the `view:` chip into the refresh budget. Two panels a
    /// rail apart gave opposite answers (design review 2026-09-03).
    ///
    /// Refresh wins: it is a functional button users reach for by
    /// position, while the mode chip is informational and its menu is
    /// reachable another way.
    ///
    /// Reads the source because the rule lives in three hand-rolled
    /// budgets. A render test would need each panel's full app state
    /// and would still only cover the widths it happened to pick.
    #[test]
    fn every_panel_drops_its_mode_chip_before_its_refresh_chip() {
        for f in ["src/ui/agents_panel.rs", "src/ui/cloud_agents_panel.rs"] {
            let src = std::fs::read_to_string(f).unwrap();
            assert!(
                src.contains("let show_view = ") && src.contains("let show_refresh = "),
                "{f} does not compute the two thresholds separately, so one \
                 chip cannot drop before the other"
            );
            // The refresh threshold must NOT include the view chip's
            // width — that is exactly the bug: it made refresh the
            // first thing to go.
            let refresh_line = src
                .lines()
                .find(|l| l.trim_start().starts_with("let show_refresh = "))
                .unwrap();
            assert!(
                !refresh_line.contains("view_w"),
                "{f}: the refresh threshold still counts the view chip, so \
                 refresh drops first: {refresh_line}"
            );
        }
    }
}
