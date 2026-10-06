//! What a statusline segment is allowed to say.
//!
//! An integration shows ONE chip on the statusline. The chip is two or
//! three cells of glyph and then a number, and the number is the only
//! thing a reader can act on from across the room. The rule:
//!
//!   **one named figure, a bracketed subset only when the pane
//!   genuinely has one, and every further count named by its own glyph
//!   after a ` · ` — a count of zero left off.**
//!
//! So the forge pane's `󰂨 12(11) · <bubble> 3 · <eye> 2` is twelve pull requests of
//! mine open, eleven of them not yet approved, three review threads on
//! them and two pull requests waiting on my review. The tracker pane's
//! `󰌃 43` is forty-three items assigned to me and nothing in brackets,
//! because a tracker has no second number that is a subset of the
//! first; its QA tab rides after a dot as `󰌃 43 · <clipboard> 14`. Inventing a
//! subset to match the other pane's shape would be the worse drift: a
//! figure a reader can believe is worth more than one there for
//! symmetry.
//!
//! Two bare figures side by side (`󰂨 12 3`) are refused, because a
//! reader has no way to learn which is which; a further count says what
//! it counts with its glyph, and the chip's hover says it in words, one
//! line per number. Three chips that all hover as the same app were the
//! old answer, and the owner read them as one thing said three times.
//!
//! `Figure` makes the rule true by construction: one `n`, one optional
//! `subset`, named `parts`. `check` makes it true of a string, for a
//! pane that formats its own and for the assertion both integration
//! suites call.

const std = @import("std");

pub const Error = error{
    /// Nothing countable in the segment at all.
    FigureMissing,
    /// A second bare figure after the first, with no glyph naming it.
    FigureTwo,
    /// Something after the figure that is neither a subset nor nothing.
    FigureTail,
    /// `()`, or brackets that never close.
    FigureSubsetEmpty,
    /// A subset larger than the figure it is a subset of.
    FigureSubsetTooBig,
    /// A ` · ` part with no glyph to say what it counts, or no count.
    FigurePartUnnamed,
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
    /// Further counts on the same chip, each named by its own glyph:
    /// ` · <glyph> 3`. One whose `n` is zero is left off, so a quiet chip is
    /// the figure alone.
    parts: []const Part = &.{},
};

/// One further count on a chip: the glyph that says what it counts,
/// and the count.
pub const Part = struct {
    glyph: []const u8,
    n: usize,
};

/// What goes between the figure and each part: a space, a middle dot,
/// a space.
pub const part_sep = " \u{b7} ";

/// `󰂨 12(11)`, `󰌃 43`, or `󰂨 12(11) · <glyph> 3`, written into `buf`. A
/// buffer too small for the whole thing falls back to the glyph alone
/// rather than to a half-written number.
pub fn text(buf: []u8, f: Figure) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, f) catch return f.glyph;
    return w.buffered();
}

fn write(w: *std.Io.Writer, f: Figure) std.Io.Writer.Error!void {
    if (f.subset) |s| try w.print("{s} {d}({d})", .{ f.glyph, f.n, s }) else try w.print("{s} {d}", .{ f.glyph, f.n });
    for (f.parts) |p| {
        if (p.n == 0) continue;
        try w.print(part_sep ++ "{s} {d}", .{ p.glyph, p.n });
    }
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
    // Then each named part: ` · `, a glyph, a space, a count.
    while (std.mem.startsWith(u8, s[i..], part_sep)) {
        i += part_sep.len;
        const g_start = i;
        while (i < s.len and s[i] != ' ' and !std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == g_start) return Error.FigurePartUnnamed;
        if (i == s.len or s[i] != ' ') return Error.FigurePartUnnamed;
        i += 1;
        const p_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == p_start) return Error.FigurePartUnnamed;
    }
    // Past the figure, only air.
    while (i < s.len) : (i += 1) {
        if (std.ascii.isDigit(s[i])) return Error.FigureTwo;
        if (s[i] != ' ') return Error.FigureTail;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// The two official panes' chip glyphs, for the tests below. Named
/// with their ascii twins beside them so `zig build glyph-audit` reads
/// the fallback off the site rather than calling it a glyph with none.
const forge_glyph = "\u{f00a8}"; // md-bitbucket
const forge_ascii = "BB";
const tracker_glyph = "\u{f0303}"; // md-jira
const tracker_ascii = "J";

test "a segment says one figure, and a subset only when it has one" {
    var buf: [64]u8 = undefined;
    // The forge pane: open pull requests of mine, of which N are not
    // yet approved.
    try testing.expectEqualStrings(forge_glyph ++ " 12(11)", text(&buf, .{ .glyph = forge_glyph, .n = 12, .subset = 11 }));
    // The tracker pane: one figure, and no invented second one.
    try testing.expectEqualStrings(tracker_glyph ++ " 43", text(&buf, .{ .glyph = tracker_glyph, .n = 43 }));
    // Saying nothing about a subset is the default, so a pane that has
    // none cannot accidentally grow one.
    try testing.expectEqual(@as(?usize, null), (Figure{ .glyph = "x", .n = 1 }).subset);
    try testing.expectEqualStrings("x 0", text(&buf, .{ .glyph = "x", .n = 0 }));
    try testing.expectEqualStrings("x 0(0)", text(&buf, .{ .glyph = "x", .n = 0, .subset = 0 }));
    // A buffer that cannot hold the number keeps the glyph rather than
    // printing half a figure.
    // The ascii forms are the same shape, which is the point of the
    // fallback: a terminal with no Nerd Font still reads the figure.
    try testing.expectEqualStrings(forge_ascii ++ " 12(11)", text(&buf, .{ .glyph = forge_ascii, .n = 12, .subset = 11 }));
    try testing.expectEqualStrings(tracker_ascii ++ " 43", text(&buf, .{ .glyph = tracker_ascii, .n = 43 }));
    var tiny: [2]u8 = undefined;
    try testing.expectEqualStrings(forge_glyph, text(&tiny, .{ .glyph = forge_glyph, .n = 12, .subset = 11 }));
}

test "the rule refuses a second figure, a tail, and a subset that is not one" {
    try check(forge_glyph ++ " 12(11)");
    try check(tracker_glyph ++ " 43");
    try check("x 0");
    // Trailing air is air.
    try check("x 7  ");

    // Nothing to read.
    try testing.expectError(Error.FigureMissing, check(forge_glyph));
    try testing.expectError(Error.FigureMissing, check(""));
    try testing.expectError(Error.FigureMissing, check(forge_glyph ++ " !"));
    // Two bare figures: two segments, not one — a reader cannot learn
    // which of `12 3` is which.
    try testing.expectError(Error.FigureTwo, check(forge_glyph ++ " 12 3"));
    try testing.expectError(Error.FigureTwo, check(forge_glyph ++ " 12(11) 3"));
    // Words after the figure.
    try testing.expectError(Error.FigureTail, check(forge_glyph ++ " 12 open"));
    try testing.expectError(Error.FigureTail, check(forge_glyph ++ " 12/34"));
    // Brackets with nothing in them, or that never close.
    try testing.expectError(Error.FigureSubsetEmpty, check("x 12()"));
    try testing.expectError(Error.FigureSubsetEmpty, check("x 12(11"));
    try testing.expectError(Error.FigureSubsetEmpty, check("x 12(a)"));
    // A "subset" bigger than the figure is not a subset of it.
    try testing.expectError(Error.FigureSubsetTooBig, check("x 12(13)"));
}

test "one chip, several counts: each further count is named by its glyph after a dot, and a zero is left off" {
    var buf: [96]u8 = undefined;
    const bubble = "\u{f075}"; // fa-comment
    const bubble_ascii = "RT";
    const eye = "\u{f06e}"; // fa-eye
    const eye_ascii = "RV";
    const parts = [_]Part{ .{ .glyph = bubble, .n = 1 }, .{ .glyph = eye, .n = 2 } };
    try testing.expectEqualStrings(forge_glyph ++ " 3(2) \u{b7} " ++ bubble ++ " 1 \u{b7} " ++ eye ++ " 2", text(&buf, .{ .glyph = forge_glyph, .n = 3, .subset = 2, .parts = &parts }));
    // A zero part is left off; all zero is the figure alone.
    try testing.expectEqualStrings(forge_glyph ++ " 3 \u{b7} " ++ eye ++ " 2", text(&buf, .{ .glyph = forge_glyph, .n = 3, .parts = &.{ .{ .glyph = bubble, .n = 0 }, .{ .glyph = eye, .n = 2 } } }));
    try testing.expectEqualStrings(forge_glyph ++ " 0", text(&buf, .{ .glyph = forge_glyph, .n = 0, .parts = &.{ .{ .glyph = bubble, .n = 0 }, .{ .glyph = eye, .n = 0 } } }));
    // The twins read the same shape.
    try testing.expectEqualStrings(forge_ascii ++ " 3 \u{b7} " ++ bubble_ascii ++ " 1 \u{b7} " ++ eye_ascii ++ " 2", text(&buf, .{ .glyph = forge_ascii, .n = 3, .parts = &.{ .{ .glyph = bubble_ascii, .n = 1 }, .{ .glyph = eye_ascii, .n = 2 } } }));
    // Too small for the parts: the glyph alone, never half a part.
    var small: [12]u8 = undefined;
    try testing.expectEqualStrings(forge_glyph, text(&small, .{ .glyph = forge_glyph, .n = 3, .parts = &parts }));

    try check(forge_glyph ++ " 3(2) \u{b7} " ++ bubble ++ " 1 \u{b7} " ++ eye ++ " 2");
    try check(tracker_glyph ++ " 10 \u{b7} QA 14");
    // A dot with nothing named after it, or a name with no count.
    try testing.expectError(Error.FigurePartUnnamed, check("x 3 \u{b7} 4"));
    try testing.expectError(Error.FigurePartUnnamed, check("x 3 \u{b7} QA"));
    try testing.expectError(Error.FigurePartUnnamed, check("x 3 \u{b7} QA "));
    // A part's count is still one count.
    try testing.expectError(Error.FigureTwo, check("x 3 \u{b7} QA 4 5"));
}

test "what the helper writes is what the rule accepts" {
    var buf: [64]u8 = undefined;
    for ([_]Figure{
        .{ .glyph = forge_glyph, .n = 12, .subset = 11 },
        .{ .glyph = tracker_glyph, .n = 43 },
        .{ .glyph = tracker_glyph, .n = 0 },
        .{ .glyph = "A", .n = 999_999 },
        .{ .glyph = forge_glyph, .n = 3, .subset = 1, .parts = &.{ .{ .glyph = "RT", .n = 1 }, .{ .glyph = "RV", .n = 0 } } },
    }) |f| try check(text(&buf, f));
}
