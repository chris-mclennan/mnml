//! Widths and fitting, counted the way `sdk.Frame` paints — one cell per
//! code point, two for the wide ranges — so a column that says 20 really
//! occupies 20 cells. Every pane that lays out a table needs these, and
//! two copies of them is how two panes end up one cell apart.

const std = @import("std");
const frame = @import("../frame.zig");

/// The noun that agrees with a count — `1 PR`, `3 PRs`, `0 repos` —
/// so no pane writes `1 PRs` on a row with one pull request.
pub fn noun(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// Cells `s` would take if it were painted whole.
pub fn width(s: []const u8) u16 {
    var w: u16 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        if (cp == '\n' or cp == '\r' or cp == '\t') continue;
        w +|= if (frame.isWide(cp)) 2 else 1;
    }
    return w;
}

/// The mark a cut ends in: `…` (one cell), or `...` under `--ascii`
/// — the same pair the host's own clipper paints, so a pane's cut and
/// the host's read the same.
pub fn ellipsis(ascii: bool) []const u8 {
    return if (ascii) "..." else "\u{2026}";
}

/// The longest prefix of `s` that fits in `max` cells, plus `…` when
/// something was cut. The result is written into `buf`, which wants
/// `max * 4 + 3` bytes to be safe.
pub fn fit(buf: []u8, s: []const u8, max: u16) []const u8 {
    return fitFor(buf, s, max, false);
}

/// `fit`, with the cut marked by `ellipsis(ascii)`. A budget no wider
/// than the mark gets the mark alone — `…` whole, `...` cut to the
/// budget — as the host's clipper does.
pub fn fitFor(buf: []u8, s: []const u8, max: u16, ascii: bool) []const u8 {
    if (max == 0) return "";
    if (width(s) <= max) {
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
    const ell = ellipsis(ascii);
    const ell_w = width(ell);
    if (ell_w >= max) {
        const take: usize = @min(if (ascii) max else ell.len, buf.len);
        @memcpy(buf[0..take], ell[0..take]);
        return buf[0..take];
    }
    const budget = max - ell_w;
    var used: u16 = 0;
    var out: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        if (cp == '\n' or cp == '\r' or cp == '\t') continue;
        const w: u16 = if (frame.isWide(cp)) 2 else 1;
        if (used + w > budget) break;
        if (out + bytes.len + ell.len > buf.len) break;
        @memcpy(buf[out..][0..bytes.len], bytes);
        out += bytes.len;
        used += w;
    }
    if (out + ell.len <= buf.len) {
        @memcpy(buf[out..][0..ell.len], ell);
        out += ell.len;
    }
    return buf[0..out];
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "width counts cells, not bytes; fit cuts with an ellipsis" {
    try testing.expectEqual(@as(u16, 3), width("abc"));
    try testing.expectEqual(@as(u16, 2), width("漢"));
    try testing.expectEqual(@as(u16, 0), width("\n\t"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", fit(&buf, "abc", 5));
    try testing.expectEqualStrings("ab\u{2026}", fit(&buf, "abcdef", 3));
    try testing.expectEqualStrings("", fit(&buf, "abc", 0));
}

test "fitFor: the --ascii twin cuts with `...`, and a budget under the mark gets the mark cut" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", fitFor(&buf, "abc", 3, true));
    try testing.expectEqualStrings("ab...", fitFor(&buf, "abcdefg", 5, true));
    try testing.expectEqualStrings("..", fitFor(&buf, "abcdefg", 2, true));
    try testing.expectEqualStrings("\u{2026}", fitFor(&buf, "abcdefg", 1, false));
    // A wide glyph is never torn to make room for the mark.
    try testing.expectEqualStrings("\u{6f22}\u{2026}", fitFor(&buf, "\u{6f22}\u{5b57}", 3, false));
}

test "noun: one is singular, every other count is plural" {
    try std.testing.expectEqualStrings("PR", noun(1, "PR", "PRs"));
    try std.testing.expectEqualStrings("PRs", noun(0, "PR", "PRs"));
    try std.testing.expectEqualStrings("PRs", noun(3, "PR", "PRs"));
}
