//! Accent colours — the one palette every "tell them apart" surface
//! draws from: a Claude session's identity strip and tab glyph, the
//! SESSIONS card and table row, and — the git side — a repo's gutter
//! on the pill, the All-repos sub-headers, its panes and its tree row.
//!
//! The order is the auto-cycle order AND the menu order (Rust's
//! `session_color.rs`, user request 2026-08-23: "issue them in the
//! same order as shown in the list"); `auto(n)` hands the n-th thing
//! opened its slot, wrapping. A stored name resolves to the theme's
//! colour of that name, so a palette swap keeps every accent readable.
//! `none` is the sentinel a menu row writes to clear an override; it
//! resolves to nothing, and the caller falls back to its auto slot.

const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("theme.zig");

pub const Color = vaxis.Color;

/// Slot 0 is the first session's, slots 1.. rotate.
pub const palette = [_][]const u8{ "green", "blue", "yellow", "orange", "red", "purple", "cyan", "pink" };

/// What a menu row writes to clear an override.
pub const none = "none";

pub fn isNone(name: []const u8) bool {
    return name.len == 0 or std.mem.eql(u8, name, none);
}

/// The palette slot for the `index`-th thing, wrapping.
pub fn auto(index: usize) []const u8 {
    return palette[index % palette.len];
}

/// The slot a newly-opened thing takes: the first palette colour no
/// live thing is wearing, so two panes open at once are never the same
/// colour. `taken` is what the live ones wear (nulls and names outside
/// the palette ignored); once every colour is spoken for the ladder
/// cycles on `nth`, which the caller counts however it likes. A colour
/// a closed pane gave back is free again on the next call — the whole
/// reason this asks the live set instead of a counter.
pub fn firstFree(taken: []const ?[]const u8, nth: usize) []const u8 {
    for (palette) |name| {
        var used = false;
        for (taken) |t| if (t) |got| {
            if (std.mem.eql(u8, got, name)) {
                used = true;
                break;
            }
        };
        if (!used) return name;
    }
    return auto(nth);
}

/// The palette's own literal for `name` (so a caller can keep it
/// without owning bytes), or null for `none` / an unknown name.
pub fn canonical(name: []const u8) ?[]const u8 {
    for (palette) |p| if (std.mem.eql(u8, p, name)) return p;
    return null;
}

/// The theme colour a stored name means; null for `none` / unknown.
pub fn resolve(name: []const u8, theme: *const Theme) ?Color {
    const p = &theme.palette;
    const Slot = enum { green, blue, yellow, orange, red, purple, cyan, pink };
    const slot = std.meta.stringToEnum(Slot, name) orelse return null;
    return switch (slot) {
        .green => p.green,
        .blue => p.blue,
        .yellow => p.yellow,
        .orange => p.orange,
        .red => p.red,
        .purple => p.purple,
        .cyan => p.cyan,
        .pink => p.pink,
    };
}

/// The menu row's text: `Color: Green`; `Color: Auto` for the sentinel
/// (Rust's R15 M-10: the row clears the override and re-derives the
/// slot, so "None" read as "no colour at all" and was renamed).
pub fn label(name: []const u8) []const u8 {
    const Slot = enum { green, blue, yellow, orange, red, purple, cyan, pink };
    const slot = std.meta.stringToEnum(Slot, name) orelse return if (isNone(name)) "Color: Auto" else "Color: ?";
    return switch (slot) {
        .green => "Color: Green",
        .blue => "Color: Blue",
        .yellow => "Color: Yellow",
        .orange => "Color: Orange",
        .red => "Color: Red",
        .purple => "Color: Purple",
        .cyan => "Color: Cyan",
        .pink => "Color: Pink",
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "the palette is Rust's session_color.rs, in its order, and every name resolves to the theme's colour" {
    const rust = [_][]const u8{ "green", "blue", "yellow", "orange", "red", "purple", "cyan", "pink" };
    try testing.expectEqual(rust.len, palette.len);
    for (rust, palette) |want, got| try testing.expectEqualStrings(want, got);
    const t = &Theme.default;
    for (palette) |name| {
        const c = resolve(name, t) orelse return error.TestUnexpectedResult;
        try testing.expect(c == .rgb);
        try testing.expect(canonical(name) != null);
        try testing.expect(std.mem.startsWith(u8, label(name), "Color: "));
    }
    try testing.expect(Color.eql(resolve("green", t).?, t.palette.green));
    try testing.expect(Color.eql(resolve("pink", t).?, t.palette.pink));
    try testing.expectEqualStrings("Color: Orange", label("orange"));
}

test "none and an unknown name resolve to nothing; auto cycles the palette in order" {
    const t = &Theme.default;
    try testing.expect(resolve(none, t) == null);
    try testing.expect(resolve("", t) == null);
    try testing.expect(resolve("mauve", t) == null);
    try testing.expect(isNone(none) and isNone("") and !isNone("green"));
    try testing.expectEqualStrings("Color: Auto", label(none));
    try testing.expectEqualStrings("Color: ?", label("mauve"));
    try testing.expect(canonical("mauve") == null);
    try testing.expectEqualStrings("green", auto(0));
    try testing.expectEqualStrings("blue", auto(1));
    try testing.expectEqualStrings("pink", auto(7));
    try testing.expectEqualStrings("green", auto(8));
    try testing.expectEqualStrings("yellow", auto(10));
}

test "firstFree hands out the first colour nobody is wearing, reuses what was given back, and cycles when the ladder runs out" {
    try testing.expectEqualStrings("green", firstFree(&.{}, 0));
    try testing.expectEqualStrings("blue", firstFree(&.{"green"}, 1));
    // A gap is filled before the ladder moves on.
    try testing.expectEqualStrings("blue", firstFree(&.{ "green", "yellow" }, 2));
    // Nulls and names outside the palette hold nothing.
    try testing.expectEqualStrings("green", firstFree(&.{ null, "mauve", null }, 0));
    // Every colour taken: the ladder wraps on the caller's count.
    const all = [_]?[]const u8{ "green", "blue", "yellow", "orange", "red", "purple", "cyan", "pink" };
    try testing.expectEqualStrings("green", firstFree(&all, 8));
    try testing.expectEqualStrings("blue", firstFree(&all, 9));
    // A closed pane's colour is free again.
    try testing.expectEqualStrings("blue", firstFree(&.{ "green", null, "yellow" }, 3));
}
