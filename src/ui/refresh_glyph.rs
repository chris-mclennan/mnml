//! Central source of truth for the "refresh / re-scan / reload"
//! glyph used across mnml — activity-panel refresh chips, git-graph
//! toolbar, tree headers, and every place a spinner is not the
//! right affordance.
//!
//! Before this module lived here, ~6 sites hard-coded the glyph
//! separately and had already drifted three ways:
//! codicon-refresh `\u{EB37}`, `↺` (U+21BA), `↻` (U+21BB), and `r`.
//! User ask 2026-08-23: same treatment as `search_glyph` —
//! centralize + provide two rendered forms (icon-only, icon + word)
//! so a caller can pick the tighter or wider chip without every
//! site inventing its own layout.

/// codicon-refresh — the canonical glyph across mnml.
pub const NERD: &str = "\u{EB37}";

/// ASCII fallback for `--ascii` mode / terminals without a Nerd
/// Font. Uses `↺` (U+21BA, ANTICLOCKWISE OPEN CIRCLE ARROW) which
/// nearly every unicode-capable terminal renders — the same
/// fallback the tree-header + git-graph chips already used.
pub const ASCII: &str = "\u{21BA}";

/// Just the glyph, matching the current UI mode.
#[inline]
pub fn for_ascii(ascii: bool) -> &'static str {
    if ascii { ASCII } else { NERD }
}

/// Icon-only chip content: ` <glyph> ` — three cells, ready to
/// drop into a `Span::styled` at the caller's Rect.
#[inline]
pub fn chip_icon_only(ascii: bool) -> String {
    format!(" {} ", for_ascii(ascii))
}

/// Icon-plus-word chip content: ` <glyph> <word> ` — width =
/// 3 + word chars + 1 trailing pad. Use when the chip has room
/// for a visible label (Jira/BB toolbars, wide-panel headers).
#[inline]
pub fn chip_with_word(ascii: bool, word: &str) -> String {
    format!(" {} {word} ", for_ascii(ascii))
}
