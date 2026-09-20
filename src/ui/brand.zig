//! Brand colours — the ones that belong to somebody else and so are not
//! the theme's to choose. One definition each, because a brand painted
//! three shades in three places is not a brand.
//!
//! Anthropic's orange is `#D97757`. mnml carried `#D16D51` in three
//! copies (the statusline chip, the pty tab glyph, the first-party
//! integration row) — close enough to look right on its own and wrong
//! next to the real one.

const std = @import("std");
const Theme = @import("theme.zig");

pub const Color = Theme.Color;

/// Anthropic's orange, as the Claude Code mark wears it.
pub const claude: Color = Theme.rgb(0xD97757);

/// The same as a `#RRGGBB` literal, for a table that stores slot names.
pub const claude_hex = "#D97757";

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the Claude mark is #D97757, the one definition every surface paints" {
    try testing.expectEqual(Color{ .rgb = .{ 0xD9, 0x77, 0x57 } }, claude);
    try testing.expectEqualStrings("#D97757", claude_hex);
}
