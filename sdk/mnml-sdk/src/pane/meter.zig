//! A fill meter — how full a bucket, a quota or a budget is, in one
//! row of cells: full cells in the budget chip's tier ink, the rest a
//! dim track. The same tiers as `chrome.budgetStyle` (`budget.Tier`), so
//! a meter and the header's budget chip that describe one bucket can
//! never disagree about how worried to look.
//!
//! The fraction is what the meter shows full; the tier is what it is
//! worth worrying about — separate, because a bucket that shows its
//! REMAINING tokens is full when all is well, and colours by what is
//! USED. `tierOfFraction` gives the budget chip's thresholds for a
//! fraction used.
//!
//! Every glyph has its `--ascii` twin: `█` / `#` full, `░` / `-` empty.

const std = @import("std");
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const budget = @import("../budget.zig");

pub const Frame = frame_mod.Frame;
pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;
pub const Tier = budget.Tier;

pub const full_glyph = "\u{2588}"; // █
pub const full_ascii = "#";
pub const empty_glyph = "\u{2591}"; // ░
pub const empty_ascii = "-";

/// The full cells `frac` (clamped to 0..1) makes of `width`, rounded to
/// the nearest cell.
pub fn fullCells(frac: f64, width: u16) u16 {
    const f = if (std.math.isNan(frac)) 0 else std.math.clamp(frac, 0, 1);
    return @intFromFloat(@round(f * @as(f64, @floatFromInt(width))));
}

/// The budget chip's thresholds for a fraction USED (0..1).
pub fn tierOfFraction(used: f64) Tier {
    const f = if (std.math.isNan(used)) 0 else std.math.clamp(used, 0, 1);
    return budget.tierOf(@intFromFloat(@floor(f * 100)));
}

/// The full cells' ink: good, warn, bad — the tier's colour.
pub fn ink(th: Theme, tier: Tier) Style {
    return switch (tier) {
        .ok => th.good(),
        .warn => th.warn(),
        .alarm => th.bad(),
    };
}

/// The track's ink.
pub fn trackInk(th: Theme) Style {
    return th.dimText();
}

/// Paint the meter at `(x, y)`, `width` cells; returns the cells used
/// (`width`, or fewer at the frame's edge).
pub fn paint(f: *Frame, x: u16, y: u16, width: u16, frac: f64, tier: Tier, th: Theme, ascii: bool) u16 {
    const full = fullCells(frac, width);
    const on = ink(th, tier);
    const off = trackInk(th);
    var used: u16 = 0;
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        const g = if (i < full) (if (ascii) full_ascii else full_glyph) else (if (ascii) empty_ascii else empty_glyph);
        used += f.text(x + i, y, 1, g, if (i < full) on else off);
    }
    return used;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn sym(f: *const Frame, x: u16, y: u16) []const u8 {
    return f.slots[@as(usize, y) * f.cols + x].symbol();
}

test "a meter fills by the fraction, rounded, clamped; the track takes the rest" {
    try testing.expectEqual(@as(u16, 0), fullCells(0, 20));
    try testing.expectEqual(@as(u16, 3), fullCells(5.0 / 40.0, 20)); // 2.5 → 3
    try testing.expectEqual(@as(u16, 20), fullCells(1.7, 20));
    try testing.expectEqual(@as(u16, 0), fullCells(-1, 20));
    try testing.expectEqual(@as(u16, 0), fullCells(std.math.nan(f64), 20));
    try testing.expectEqual(Tier.ok, tierOfFraction(0.1));
    try testing.expectEqual(Tier.warn, tierOfFraction(0.6));
    try testing.expectEqual(Tier.alarm, tierOfFraction(0.875));

    var f = try Frame.init(testing.allocator, 24, 2);
    defer f.deinit();
    const th = Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } } });
    try testing.expectEqual(@as(u16, 10), paint(&f, 2, 0, 10, 0.3, .warn, th, false));
    for (0..10) |i| {
        const x: u16 = @intCast(2 + i);
        const want: []const u8 = if (i < 3) full_glyph else empty_glyph;
        try testing.expectEqualStrings(want, sym(&f, x, 0));
        const st = f.slots[x].style;
        try testing.expect(std.meta.eql(st.fg, (if (i < 3) th.warn() else th.dimText()).fg));
    }
    // The ascii twin, same shape.
    _ = paint(&f, 2, 1, 10, 0.3, .alarm, th, true);
    try testing.expectEqualStrings("#", sym(&f, 2, 1));
    try testing.expectEqualStrings("-", sym(&f, 11, 1));
    try testing.expect(std.meta.eql(f.slots[24 + 2].style.fg, th.bad().fg));
    // Clipped at the frame's edge, never past it.
    try testing.expectEqual(@as(u16, 4), paint(&f, 20, 0, 10, 1, .ok, th, false));
}
