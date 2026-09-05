//! clipCells — truncate a string to a cell budget with an ellipsis.
//!
//! Cell-aware, not char-aware: a CJK glyph costs two cells, a combining
//! mark none, so `"漢字漢字"` clipped to 5 cells is `"漢字…"`, never a torn
//! glyph. (Rust mnml's `clip_to_cells` counts chars despite its name — a
//! backport candidate.) The result is always freshly allocated, so callers
//! on the frame arena never think about ownership.

const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;
const Method = vaxis.gwidth.Method;

pub const Ellipsis = enum {
    /// `…` (U+2026), one cell.
    unicode,
    /// `...`, three cells — for `--ascii` terminals.
    ascii,
    /// Plain cut.
    none,

    fn text(e: Ellipsis) []const u8 {
        return switch (e) {
            .unicode => "…",
            .ascii => "...",
            .none => "",
        };
    }

    fn cells(e: Ellipsis) u16 {
        return switch (e) {
            .unicode => 1,
            .ascii => 3,
            .none => 0,
        };
    }
};

pub const Options = struct {
    method: Method = .unicode,
    ellipsis: Ellipsis = .unicode,
};

pub fn width(s: []const u8, method: Method) u16 {
    return vaxis.gwidth.gwidth(s, method);
}

/// Returns `s` copied when it fits in `max_cells`; otherwise as many leading
/// graphemes as fit beside the ellipsis, then the ellipsis. A budget smaller
/// than the ellipsis yields the ellipsis itself cut to the budget.
pub fn clipCells(alloc: Allocator, s: []const u8, max_cells: u16, opts: Options) Allocator.Error![]u8 {
    if (width(s, opts.method) <= max_cells) return alloc.dupe(u8, s);
    if (max_cells == 0) return alloc.alloc(u8, 0);

    const ell = opts.ellipsis.text();
    const ell_w = opts.ellipsis.cells();
    if (ell_w >= max_cells) {
        // Only the ellipsis fits — "…" whole, "..." cut to the budget.
        const take: usize = if (opts.ellipsis == .ascii) max_cells else ell.len;
        return alloc.dupe(u8, ell[0..take]);
    }

    const budget = max_cells - ell_w;
    var used: u16 = 0;
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const bytes = g.bytes(s);
        const w = width(bytes, opts.method);
        if (used + w > budget) break;
        used += w;
        end = g.start + g.len;
    }

    const out = try alloc.alloc(u8, end + ell.len);
    @memcpy(out[0..end], s[0..end]);
    @memcpy(out[end..], ell);
    return out;
}

/// Byte length of the longest grapheme prefix of `s` that fits in
/// `max_cells` — no ellipsis, never past `s.len`. The wrap primitive:
/// `clipCells` marks a cut with "…", which can make the clipped form
/// longer in bytes than the text it came from, so a caller slicing the
/// original by the clipped length walks off its end.
pub fn fitCells(s: []const u8, max_cells: u16, method: Method) usize {
    var used: u16 = 0;
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const bytes = g.bytes(s);
        const w = width(bytes, method);
        if (used + w > max_cells) break;
        used += w;
        end = g.start + g.len;
    }
    return end;
}

fn expectClip(expected: []const u8, s: []const u8, max: u16, opts: Options) !void {
    const got = try clipCells(std.testing.allocator, s, max, opts);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "fits: returned whole" {
    try expectClip("hello", "hello", 5, .{});
    try expectClip("hello", "hello", 40, .{});
    try expectClip("", "", 0, .{});
    try expectClip("漢字", "漢字", 4, .{});
}

test "fitCells: the prefix that fits, in bytes, never past the text" {
    try std.testing.expectEqual(@as(usize, 5), fitCells("hello world", 5, .unicode));
    try std.testing.expectEqual(@as(usize, 3), fitCells("abc", 10, .unicode));
    try std.testing.expectEqual(@as(usize, 0), fitCells("abc", 0, .unicode));
    // A wide glyph is never torn: 3 cells hold one 漢 (3 bytes), not half of 字.
    try std.testing.expectEqual(@as(usize, 3), fitCells("漢字", 3, .unicode));
    try std.testing.expectEqual(@as(usize, 6), fitCells("漢字", 4, .unicode));
    // The case that panicked the commit detail: 41 cells at width 40 is
    // 40 bytes, where the "…"-clipped form is 42.
    const line = "x" ** 41;
    try std.testing.expectEqual(@as(usize, 40), fitCells(line, 40, .unicode));
}

test "ascii clip with each ellipsis" {
    try expectClip("hell…", "hello world", 5, .{});
    try expectClip("he...", "hello world", 5, .{ .ellipsis = .ascii });
    try expectClip("hello", "hello world", 5, .{ .ellipsis = .none });
    try expectClip("…", "hello", 1, .{});
    try expectClip("", "hello", 0, .{});
}

test "budget smaller than the ascii ellipsis cuts the ellipsis" {
    try expectClip(".", "hello", 1, .{ .ellipsis = .ascii });
    try expectClip("..", "hello", 2, .{ .ellipsis = .ascii });
    try expectClip("...", "hello", 3, .{ .ellipsis = .ascii });
    try expectClip("h...", "hello", 4, .{ .ellipsis = .ascii });
}

test "wide glyphs count two cells and are never torn" {
    try expectClip("漢字…", "漢字漢字", 5, .{});
    try expectClip("漢…", "漢字漢字", 4, .{}); // 字 would need cells 3-4 of a 3-cell budget
    try expectClip("漢…", "漢字漢字", 3, .{});
    try expectClip("…", "漢字漢字", 2, .{});
    try expectClip("ab漢…", "ab漢字", 5, .{});
    try expectClip("ab…", "ab漢字", 4, .{});
}

test "emoji and combining marks measure as cells" {
    try expectClip("👋🏿…", "👋🏿👋🏿", 3, .{}); // one 2-cell grapheme + ellipsis
    try expectClip("…", "👋🏿👋🏿", 2, .{});
    // NFD "é" is two codepoints, one cell.
    try expectClip("e\u{0301}a…", "e\u{0301}abc", 3, .{});
}

test "width helper agrees with vaxis" {
    try std.testing.expectEqual(@as(u16, 4), width("漢字", .unicode));
    try std.testing.expectEqual(@as(u16, 1), width("…", .unicode));
    try std.testing.expectEqual(@as(u16, 3), width("...", .unicode));
}
