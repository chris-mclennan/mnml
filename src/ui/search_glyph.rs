//! Central source of truth for the "search / find / filter"
//! magnifier glyph used in filter rows across the UI.
//!
//! Before this module lived here, ~14 filter-row sites hard-coded
//! the glyph independently. Two had already drifted to a different
//! codepoint (nf-fa-search U+F002 instead of nf-md-magnify U+F0349)
//! so the visual was almost — but not quite — consistent. User ask
//! 2026-08-23: "make the search / find magnifying glass a constant
//! so it's consistent". Centralized here alongside
//! [`filter_placeholder`][crate::ui::filter_placeholder].
//!
//! Note: the `Find…` / `Find in files…` / `Go to file…` menu-bar
//! items and the Search activity-bar section use nf-fa-search
//! (U+F002) deliberately — those are section/menu icons, not
//! filter-row glyphs, so they intentionally stay on the FA variant.

/// nf-md-magnify — the canonical magnifier used in every filter row.
pub const NERD: &str = "\u{F0349}";

/// ASCII fallback for `--ascii` mode / terminals without a Nerd Font.
pub const ASCII: &str = "/";

/// Pick the right form for the current UI mode.
#[inline]
pub fn for_ascii(ascii: bool) -> &'static str {
    if ascii { ASCII } else { NERD }
}
