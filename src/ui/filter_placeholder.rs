//! Filter-row placeholder strings — one source of truth for the
//! `/ filter` (unfocused) / `type to filter…` (focused-empty)
//! pair that shows up on every activity-bar panel + settings +
//! Jira/BB toolbars.
//!
//! Before this module the same pair was inlined in ~13 files.
//! User ask 2026-08-23: "the color system and the find
//! placeholders should be constants". Centralized here so a
//! wording change lands in every surface at once.
//!
//! Panels that need extra qualifier text (e.g. cloud agents:
//! `"type to filter (ticket / runId / state)…"`) build off
//! [`focused_hint`] with their own suffix.

/// Shown when the filter is empty and the row is NOT focused.
/// Signals "press `/` (or click) to search". Ends with the
/// literal word "filter" — noun-form, matches the icon.
pub const UNFOCUSED: &str = "/ filter";

/// Shown when the filter is empty AND focused, ready for input.
/// Verb-form — the row is now waiting for you to type. Ellipsis
/// is the single U+2026 codepoint so widths stay identical to
/// what an actual "…" span would occupy.
pub const FOCUSED: &str = "type to filter\u{2026}";

/// Convenience: returns the appropriate placeholder given the two
/// pieces of state every call site already computes. Rows that
/// need a scope hint after "filter" (e.g. "(ticket / runId /
/// state)") should hand-roll instead — those extra tokens carry
/// panel-specific context that doesn't belong in the shared const.
pub fn for_state(focused: bool) -> &'static str {
    if focused { FOCUSED } else { UNFOCUSED }
}
