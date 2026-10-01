//! clipCells — truncate a string to a cell budget with an ellipsis.
//!
//! Cell-aware, not char-aware: a CJK glyph costs two cells, a combining
//! mark none, so `"漢字漢字"` clipped to 5 cells is `"漢字…"`, never a torn
//! glyph. (Rust mnml's `clip_to_cells` counts chars despite its name — a
//! backport candidate.) The result is always freshly allocated, so callers
//! on the frame arena never think about ownership.

const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../core/utf8.zig");

const Allocator = std.mem.Allocator;
const Method = vaxis.gwidth.Method;

pub const Ellipsis = enum {
    /// `…` (U+2026), one cell.
    unicode,
    /// `...`, three cells — for `--ascii` terminals.
    ascii,
    /// Plain cut.
    none,

    pub fn text(e: Ellipsis) []const u8 {
        return switch (e) {
            .unicode => "…",
            .ascii => "...",
            .none => "",
        };
    }

    pub fn cells(e: Ellipsis) u16 {
        return switch (e) {
            .unicode => 1,
            .ascii => 3,
            .none => 0,
        };
    }
};

/// The ellipsis a terminal gets: the one-cell glyph where the font has
/// it, `...` under `--ascii`. A painter that cuts a string itself — a
/// column header, a toast's last line, a grep row's tail — asks here
/// instead of spelling the pair again. Nine sites did spell it, which
/// is nine chances for one to disagree with what `clipStr` paints.
pub fn ellipsisFor(ascii: bool) Ellipsis {
    return if (ascii) .ascii else .unicode;
}

/// `ellipsisFor(ascii).text()` — the glyph itself, for a `fmt` or a `putStr`.
pub fn ellipsisText(ascii: bool) []const u8 {
    return ellipsisFor(ascii).text();
}

pub const Options = struct {
    method: Method = .unicode,
    ellipsis: Ellipsis = .unicode,
};

/// Cell width of one grapheme. The ASCII fast path skips the table walk.
pub fn graphemeWidth(g: []const u8, method: Method) u16 {
    if (g.len == 1 and g[0] >= 0x20 and g[0] < 0x7f) return 1;
    return utf8.width(g, method);
}

/// Cell width of `s`, saturating at 65535. vaxis' `gwidth` sums into a
/// `u16` and overflows past that — a single-line 545k JSON file did it
/// through the grep pane — so the sum is ours, one grapheme at a time.
pub fn width(s: []const u8, method: Method) u16 {
    var total: u16 = 0;
    var it = utf8.graphemeIterator(s);
    while (it.next()) |g| total +|= graphemeWidth(g.bytes(s), method);
    return total;
}

/// True when `s` fits in `max_cells`. Stops at the first grapheme past
/// the budget, so a whole file line costs `max_cells` of work, not its
/// length — the measure every clip does first.
pub fn fits(s: []const u8, max_cells: u16, method: Method) bool {
    if (s.len <= max_cells) return true; // a byte is at most one cell
    var used: u32 = 0;
    var it = utf8.graphemeIterator(s);
    while (it.next()) |g| {
        used += graphemeWidth(g.bytes(s), method);
        if (used > max_cells) return false;
    }
    return true;
}

/// Returns `s` copied when it fits in `max_cells`; otherwise as many leading
/// graphemes as fit beside the ellipsis, then the ellipsis. A budget smaller
/// than the ellipsis yields the ellipsis itself cut to the budget.
pub fn clipCells(alloc: Allocator, s: []const u8, max_cells: u16, opts: Options) Allocator.Error![]u8 {
    if (fits(s, max_cells, opts.method)) return alloc.dupe(u8, s);
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
    var it = utf8.graphemeIterator(s);
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

/// `clipCells` from the other end: the ellipsis, then as many TRAILING
/// graphemes as fit beside it — for a path, whose end (the file, the
/// folder) is the part worth keeping. `s` copied when it fits.
pub fn clipCellsLeft(alloc: Allocator, s: []const u8, max_cells: u16, opts: Options) Allocator.Error![]u8 {
    if (fits(s, max_cells, opts.method)) return alloc.dupe(u8, s);
    if (max_cells == 0) return alloc.alloc(u8, 0);
    const ell = opts.ellipsis.text();
    const ell_w = opts.ellipsis.cells();
    if (ell_w >= max_cells) {
        const take: usize = if (opts.ellipsis == .ascii) max_cells else ell.len;
        return alloc.dupe(u8, ell[0..take]);
    }
    const start = tailStart(s, max_cells - ell_w, opts.method);
    const out = try alloc.alloc(u8, ell.len + s.len - start);
    @memcpy(out[0..ell.len], ell);
    @memcpy(out[ell.len..], s[start..]);
    return out;
}

/// `clipCellsLeft` for a path: the cut lands on a separator when one is
/// in reach, so what is left reads `…/parent/name` rather than a torn
/// `…ent/name`. A last component wider than the budget is cut mid-name,
/// as `clipCellsLeft` would. A trailing `/` (a directory's spelling) is
/// part of the name, not a cut point.
pub fn clipPathLeft(alloc: Allocator, s: []const u8, max_cells: u16, opts: Options) Allocator.Error![]u8 {
    if (fits(s, max_cells, opts.method)) return alloc.dupe(u8, s);
    const ell_w = opts.ellipsis.cells();
    if (ell_w < max_cells) {
        const start = tailStart(s, max_cells - ell_w, opts.method);
        const body = std.mem.trimEnd(u8, s, "/\\");
        if (start < body.len) {
            if (std.mem.indexOfAnyPos(u8, s, start, "/\\")) |sep| if (sep < body.len) {
                const ell = opts.ellipsis.text();
                const out = try alloc.alloc(u8, ell.len + s.len - sep);
                @memcpy(out[0..ell.len], ell);
                @memcpy(out[ell.len..], s[sep..]);
                return out;
            };
        }
    }
    return clipCellsLeft(alloc, s, max_cells, opts);
}

/// The byte where the longest grapheme SUFFIX of `s` that fits in
/// `budget` cells starts.
fn tailStart(s: []const u8, budget: u16, method: Method) usize {
    // Grapheme starts, walked once forward; then the suffix is grown
    // from the end until the next grapheme would not fit.
    var starts: [512]usize = undefined;
    var n: usize = 0;
    var it = utf8.graphemeIterator(s);
    var start: usize = s.len;
    var overflowed = false;
    while (it.next()) |g| {
        if (n == starts.len) {
            overflowed = true;
            break;
        }
        starts[n] = g.start;
        n += 1;
    }
    if (overflowed) {
        // A very long string: keep the last `budget` bytes' worth as a
        // bound, then measure within it (a byte is at most one cell).
        const lo = s.len -| @as(usize, budget) * 4;
        var j = lo;
        while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
        return j + tailStart(s[j..], budget, method);
    }
    var used: u16 = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        const end = if (i + 1 < n) starts[i + 1] else s.len;
        const w = width(s[starts[i]..end], method);
        if (used + w > budget) break;
        used += w;
        start = starts[i];
    }
    return start;
}

/// Byte length of the longest grapheme prefix of `s` that fits in
/// `max_cells` — no ellipsis, never past `s.len`. The wrap primitive:
/// `clipCells` marks a cut with "…", which can make the clipped form
/// longer in bytes than the text it came from, so a caller slicing the
/// original by the clipped length walks off its end.
pub fn fitCells(s: []const u8, max_cells: u16, method: Method) usize {
    var used: u16 = 0;
    var end: usize = 0;
    var it = utf8.graphemeIterator(s);
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

test "a 100k-char line measures without overflowing and clips in budget-bounded time" {
    const testing = std.testing;
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'y');
    try testing.expectEqual(@as(u16, 65535), width(long, .unicode));
    try testing.expect(!fits(long, 65535, .unicode));
    try testing.expect(fits(long[0..40], 40, .unicode));
    try testing.expect(!fits(long[0..41], 40, .unicode));
    try expectClip("yyyy…", long, 5, .{});
    // Wide glyphs past the budget are never measured: 70k of them would
    // be 140k cells.
    const wide = try testing.allocator.alloc(u8, 3 * 70_000);
    defer testing.allocator.free(wide);
    var i: usize = 0;
    while (i < wide.len) : (i += 3) @memcpy(wide[i .. i + 3], "漢");
    try testing.expectEqual(@as(u16, 65535), width(wide, .unicode));
    try expectClip("漢漢…", wide, 5, .{});
}

test "width helper agrees with vaxis" {
    try std.testing.expectEqual(@as(u16, 4), width("漢字", .unicode));
    try std.testing.expectEqual(@as(u16, 1), width("…", .unicode));
    try std.testing.expectEqual(@as(u16, 3), width("...", .unicode));
}

test "clipCellsLeft keeps the end; clipPathLeft cuts at a separator, keeps a trailing slash, and falls back mid-name" {
    const a = std.testing.allocator;
    const o: Options = .{};
    const c1 = try clipCellsLeft(a, "abcdefgh", 5, o);
    defer a.free(c1);
    try std.testing.expectEqualStrings("…efgh", c1);
    const c2 = try clipCellsLeft(a, "abc", 5, o);
    defer a.free(c2);
    try std.testing.expectEqualStrings("abc", c2);
    const c3 = try clipCellsLeft(a, "漢字漢字", 6, o);
    defer a.free(c3);
    try std.testing.expectEqualStrings("…漢字", c3);
    const p1 = try clipPathLeft(a, "/Users/me/Projects/mnml-zig-worktrees/sidecar", 30, o);
    defer a.free(p1);
    try std.testing.expectEqualStrings("…/mnml-zig-worktrees/sidecar", p1);
    const p2 = try clipPathLeft(a, "~/Projects/mnml-zig-worktrees/sidecar/", 20, o);
    defer a.free(p2);
    try std.testing.expectEqualStrings("…/sidecar/", p2);
    // The name alone is wider than the budget: cut inside it.
    const p3 = try clipPathLeft(a, "/var/folders/a-very-long-folder-name", 10, o);
    defer a.free(p3);
    try std.testing.expectEqualStrings("…lder-name", p3);
    const p4 = try clipPathLeft(a, "/var/x", 10, o);
    defer a.free(p4);
    try std.testing.expectEqualStrings("/var/x", p4);
    const p5 = try clipPathLeft(a, "/var/folders/xy/T/mnml-e2e-bac773/", 14, .{ .ellipsis = .ascii });
    defer a.free(p5);
    try std.testing.expectEqualStrings("...e2e-bac773/", p5);
}
