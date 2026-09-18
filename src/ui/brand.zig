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

/// The mark when no session is live — the brand pulled toward the
/// theme's muted, so it reads as off rather than as another colour. A
/// theme whose muted is a palette index has no channels to mix, so the
/// brand is dimmed against black instead.
pub fn claudeIdle(theme: *const Theme) Color {
    const muted = theme.muted.fg;
    return switch (muted) {
        .rgb => |m| blend(rgbOf(claude), m, 45),
        else => blend(rgbOf(claude), .{ 0, 0, 0 }, 45),
    };
}

fn rgbOf(c: Color) [3]u8 {
    return switch (c) {
        .rgb => |v| v,
        else => .{ 0xD9, 0x77, 0x57 },
    };
}

/// `pct` percent of `b` mixed into `a`.
fn blend(a: [3]u8, b: [3]u8, pct: u8) Color {
    var out: [3]u8 = undefined;
    for (&out, a, b) |*o, av, bv| {
        const mixed = (@as(u16, av) * (100 - @as(u16, pct)) + @as(u16, bv) * @as(u16, pct)) / 100;
        o.* = @intCast(mixed);
    }
    return .{ .rgb = out };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the Claude mark is #D97757, and its idle shade sits between the brand and the theme's muted" {
    try testing.expectEqual(Color{ .rgb = .{ 0xD9, 0x77, 0x57 } }, claude);
    var th = Theme.default;
    th.muted.fg = Theme.rgb(0x5c6370);
    const idle = claudeIdle(&th);
    const v = idle.rgb;
    // Pulled toward the muted on every channel, never past it.
    try testing.expect(v[0] < 0xD9 and v[0] > 0x5c);
    try testing.expect(v[1] > 0x63 and v[1] < 0x77);
    try testing.expect(v[2] > 0x57 and v[2] < 0x70);
    // A themed muted with no channels still yields a darker brand.
    th.muted.fg = .{ .index = 8 };
    const fallback = claudeIdle(&th).rgb;
    try testing.expect(fallback[0] < 0xD9 and fallback[0] > 0);
}
