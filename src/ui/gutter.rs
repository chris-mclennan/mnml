//! The selected-row gutter bar — one glyph, one width, one rule.
//!
//! User 2026-09-03: "why is there a space between the blue gutter here
//! and the a in auto-update, in other place we use gutter its right
//! next to the first char … what is standard or best practice and then
//! we should do that consistently."
//!
//! **The rule: no trailing space.** `▌` is U+258C LEFT HALF BLOCK — it
//! paints only the LEFT half of its cell, so the right half is already
//! background. The glyph carries its own optical gap. Adding a space
//! after it produces one and a half cells of air, which reads as the
//! bar having drifted away from the text it marks.
//!
//! This is not a majority-vote convention. Six of the eight call sites
//! already had it right; the two that appended a space (the picker and
//! the usage view) were the outliers, and they are what the user
//! noticed. Anything that needs MORE separation should widen the
//! content's own left pad, not pad the gutter — those are different
//! decisions and conflating them is how the two camps appeared.
//!
//! A row that is not selected paints [`BLANK`], never an empty string:
//! the column must be reserved on every row or the text jitters one
//! cell left and right as the cursor moves.

/// The bar itself. Left half-block, so it reads as a solid colour
/// column rather than the thin line `┃` gives.
pub const GLYPH: &str = "\u{258c}";

/// What an unselected row paints in the gutter column.
pub const BLANK: &str = " ";

/// Cells the gutter occupies. Always 1 — callers doing row-width
/// arithmetic should subtract this rather than a bare literal, so a
/// future change to the glyph cannot silently desync the budget from
/// the paint.
pub const WIDTH: u16 = 1;

/// The gutter cell for a row.
pub fn marker(selected: bool) -> &'static str {
    if selected { GLYPH } else { BLANK }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole point of this module. If a trailing space ever comes
    /// back, it comes back everywhere at once and this fails.
    #[test]
    fn the_gutter_carries_no_trailing_space() {
        assert_eq!(GLYPH, "\u{258c}", "the glyph changed");
        assert!(
            !GLYPH.ends_with(' '),
            "the gutter glyph regained a trailing space"
        );
        assert_eq!(
            GLYPH.chars().count() as u16,
            WIDTH,
            "WIDTH disagrees with the glyph — row budgets will desync"
        );
        assert_eq!(
            BLANK.chars().count() as u16,
            WIDTH,
            "an unselected row would not reserve the same column"
        );
    }

    #[test]
    fn selected_and_unselected_occupy_the_same_column() {
        assert_eq!(marker(true).chars().count(), marker(false).chars().count());
    }
}
