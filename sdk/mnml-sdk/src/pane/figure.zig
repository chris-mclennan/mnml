//! What a statusline segment is allowed to say.
//!
//! A chip on the statusline is two or three cells of glyph and then a
//! number, and the number is the only thing a reader can act on from
//! across the room. The rule, one line:
//!
//!   **one named figure per segment, plus a bracketed subset only when
//!   the pane genuinely has one.**
//!
//! So the forge pane's `󰂨 12(11)` is twelve pull requests of mine open,
//! of which eleven are not yet approved — one figure, and a subset OF
//! that figure. The tracker pane's `󰌃 43` is forty-three items assigned
//! to me and nothing in brackets, because a tracker has no second
//! number that is a subset of the first. Inventing one to match the
//! other pane's shape would be the worse drift: a figure a reader can
//! believe is worth more than a figure that is there for symmetry.
//!
//! Two figures side by side (`󰂨 12 3`) are refused rather than allowed,
//! because a reader has no way to learn which is which — a segment with
//! two things to say publishes two segments, each named for its own
//! figure, which is what the forge pane already does for its review and
//! awaiting chips.
//!
//! `Figure` makes the rule true by construction: one `n`, one optional
//! `subset`. `check` makes it true of a string, for a pane that formats
//! its own and for the assertion both integration suites call.

const std = @import("std");

pub const Error = error{
    /// Nothing countable in the segment at all.
    FigureMissing,
    /// A second bare figure after the first. Two segments, not one.
    FigureTwo,
    /// Something after the figure that is neither a subset nor nothing.
    FigureTail,
    /// `()`, or brackets that never close.
    FigureSubsetEmpty,
    /// A subset larger than the figure it is a subset of.
    FigureSubsetTooBig,
};

/// What one segment says. The glyph names the thing; `n` counts it;
/// `subset` is the part of `n` the pane can name, when it has one.
pub const Figure = struct {
    glyph: []const u8,
    n: usize,
    /// A subset OF `n` — never a second, unrelated count. Null is the
    /// honest answer for a pane with no such subset, and is the
    /// default so that saying nothing says nothing.
    subset: ?usize = null,
};

/// `󰂨 12(11)`, or `󰌃 43`, written into `buf`. A buffer too small for
/// the whole thing falls back to the glyph alone rather than to a
/// half-written number.
pub fn text(buf: []u8, f: Figure) []const u8 {
    if (f.subset) |s| {
        return std.fmt.bufPrint(buf, "{s} {d}({d})", .{ f.glyph, f.n, s }) catch f.glyph;
    }
    return std.fmt.bufPrint(buf, "{s} {d}", .{ f.glyph, f.n }) catch f.glyph;
}

/// Does `s` obey the rule? The glyph run is whatever leads up to the
/// first digit; after the figure only a `(subset)` may follow, and
/// after that nothing.
pub fn check(s: []const u8) Error!void {
    var i: usize = 0;
    while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i == s.len) return Error.FigureMissing;
    const n_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    const n = std.fmt.parseInt(usize, s[n_start..i], 10) catch return Error.FigureMissing;
    if (i < s.len and s[i] == '(') {
        i += 1;
        const sub_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == sub_start) return Error.FigureSubsetEmpty;
        const sub = std.fmt.parseInt(usize, s[sub_start..i], 10) catch return Error.FigureSubsetEmpty;
        if (i == s.len or s[i] != ')') return Error.FigureSubsetEmpty;
        i += 1;
        if (sub > n) return Error.FigureSubsetTooBig;
    }
    // Past the figure, only air.
    while (i < s.len) : (i += 1) {
        if (std.ascii.isDigit(s[i])) return Error.FigureTwo;
        if (s[i] != ' ') return Error.FigureTail;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a segment says one figure, and a subset only when it has one" {
    var buf: [64]u8 = undefined;
    // The forge pane: open pull requests of mine, of which N are not
    // yet approved.
    try testing.expectEqualStrings("\u{f00a8} 12(11)", text(&buf, .{ .glyph = "\u{f00a8}", .n = 12, .subset = 11 }));
    // The tracker pane: one figure, and no invented second one.
    try testing.expectEqualStrings("\u{f0303} 43", text(&buf, .{ .glyph = "\u{f0303}", .n = 43 }));
    // Saying nothing about a subset is the default, so a pane that has
    // none cannot accidentally grow one.
    try testing.expectEqual(@as(?usize, null), (Figure{ .glyph = "x", .n = 1 }).subset);
    try testing.expectEqualStrings("x 0", text(&buf, .{ .glyph = "x", .n = 0 }));
    try testing.expectEqualStrings("x 0(0)", text(&buf, .{ .glyph = "x", .n = 0, .subset = 0 }));
    // A buffer that cannot hold the number keeps the glyph rather than
    // printing half a figure.
    var tiny: [2]u8 = undefined;
    try testing.expectEqualStrings("\u{f00a8}", text(&tiny, .{ .glyph = "\u{f00a8}", .n = 12, .subset = 11 }));
}

test "the rule refuses a second figure, a tail, and a subset that is not one" {
    try check("\u{f00a8} 12(11)");
    try check("\u{f0303} 43");
    try check("x 0");
    // Trailing air is air.
    try check("x 7  ");

    // Nothing to read.
    try testing.expectError(Error.FigureMissing, check("\u{f00a8}"));
    try testing.expectError(Error.FigureMissing, check(""));
    try testing.expectError(Error.FigureMissing, check("\u{f00a8} !"));
    // Two bare figures: two segments, not one — a reader cannot learn
    // which of `12 3` is which.
    try testing.expectError(Error.FigureTwo, check("\u{f00a8} 12 3"));
    try testing.expectError(Error.FigureTwo, check("\u{f00a8} 12(11) 3"));
    // Words after the figure.
    try testing.expectError(Error.FigureTail, check("\u{f00a8} 12 open"));
    try testing.expectError(Error.FigureTail, check("\u{f00a8} 12/34"));
    // Brackets with nothing in them, or that never close.
    try testing.expectError(Error.FigureSubsetEmpty, check("x 12()"));
    try testing.expectError(Error.FigureSubsetEmpty, check("x 12(11"));
    try testing.expectError(Error.FigureSubsetEmpty, check("x 12(a)"));
    // A "subset" bigger than the figure is not a subset of it.
    try testing.expectError(Error.FigureSubsetTooBig, check("x 12(13)"));
}

test "what the helper writes is what the rule accepts" {
    var buf: [64]u8 = undefined;
    for ([_]Figure{
        .{ .glyph = "\u{f00a8}", .n = 12, .subset = 11 },
        .{ .glyph = "\u{f0303}", .n = 43 },
        .{ .glyph = "\u{f0303}", .n = 0 },
        .{ .glyph = "A", .n = 999_999 },
    }) |f| try check(text(&buf, f));
}
