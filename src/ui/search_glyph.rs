//! Central source of truth for the "search / find / filter"
//! magnifier glyph used EVERYWHERE in the UI — filter rows, menu
//! items, activity-bar sections, dropdown headers, all of it.
//!
//! Before this module lived here, ~14 filter-row sites hard-coded
//! the glyph independently and had drifted to two different code-
//! points (nf-fa-search U+F002 vs nf-md-magnify U+F0349). User ask
//! 2026-08-23: "make the search / find magnifying glass a constant
//! so it's consistent". Centralized here alongside
//! [`filter_placeholder`][crate::ui::filter_placeholder].
//!
//! 2026-08-24: the earlier "section/menu icons deliberately stay on
//! nf-fa (U+F002)" carve-out was reversed at user request — ONE
//! magnifier everywhere, no exceptions. The Find… / Find in files… /
//! Go to file… menu items and the Search activity-bar section all
//! flow through [`NERD`] now.

/// nf-md-magnify — the canonical magnifier used in every filter row.
pub const NERD: &str = "\u{F0349}";

/// ASCII fallback for `--ascii` mode / terminals without a Nerd Font.
pub const ASCII: &str = "/";

/// Pick the right form for the current UI mode.
#[inline]
pub fn for_ascii(ascii: bool) -> &'static str {
    if ascii { ASCII } else { NERD }
}
