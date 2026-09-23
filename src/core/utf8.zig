//! Byte-safe text units for text that may not be valid UTF-8.
//!
//! A file on disk is bytes: a binary, a truncated download or a legacy
//! encoding puts stray continuation bytes, lone lead bytes, overlong
//! forms and surrogate halves in the buffer. vaxis' grapheme iterator
//! and `gwidth` assume valid UTF-8; handed an invalid sequence they
//! compute a cluster start past its end and panic (a stray `0x91`
//! followed by a combining mark is enough).
//!
//! So the rule here: every byte that does not begin a well-formed
//! sequence is a unit of its own — one step for the cursor, one cell
//! painted as U+FFFD — and only maximal runs of valid UTF-8 ever reach
//! vaxis. `Document.isBoundary`, the editor view's layout and the width
//! helpers all go through this file so they agree on where units are.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Grapheme = vaxis.unicode.Grapheme;

/// What an invalid byte paints as.
pub const replacement = "\u{FFFD}";

/// Length of the well-formed sequence starting at `s[i]`, or 0 when
/// `s[i]` does not begin one (a stray continuation byte, a lead byte
/// whose sequence is cut short or malformed, an overlong form, a
/// surrogate half, a code point past U+10FFFF). ASCII is 1.
pub fn seqLen(s: []const u8, i: usize) u3 {
    const c = s[i];
    if (c < 0x80) return 1;
    const n = std.unicode.utf8ByteSequenceLength(c) catch return 0;
    if (i + n > s.len) return 0;
    _ = std.unicode.utf8Decode(s[i .. i + n]) catch return 0;
    return n;
}

/// True when `b` starts a unit: anything but a continuation byte that
/// belongs to a well-formed sequence begun at most three bytes before.
pub fn isBoundary(s: []const u8, b: usize) bool {
    if (b >= s.len or (s[b] & 0xC0) != 0x80) return true;
    var k: usize = 1;
    while (k <= 3 and k <= b) : (k += 1) {
        const p = b - k;
        if ((s[p] & 0xC0) == 0x80) continue;
        return seqLen(s, p) <= k;
    }
    return true;
}

/// Byte length of the unit starting at boundary `i` (1 for an invalid
/// byte).
pub fn unitLen(s: []const u8, i: usize) usize {
    return @max(seqLen(s, i), 1);
}

/// True when `g` is a single invalid byte as yielded by `GraphemeIterator`.
pub fn isInvalidUnit(g: []const u8) bool {
    return g.len == 1 and g[0] >= 0x80;
}

/// What to paint for grapheme `g`: U+FFFD for an invalid byte, else `g`.
pub fn displayBytes(g: []const u8) []const u8 {
    return if (isInvalidUnit(g)) replacement else g;
}

/// How far one valid run is scanned ahead before vaxis is started on it;
/// keeps a caller that stops early (a clip, a visible window) from paying
/// for the whole of a megabyte line.
const chunk = 4096;

/// Extended grapheme clusters of `str`, like `vaxis.unicode.graphemeIterator`,
/// except that each byte that does not begin a well-formed sequence comes
/// out as a one-byte grapheme and never joins a cluster.
pub const GraphemeIterator = struct {
    str: []const u8,
    pos: usize = 0,
    /// The vaxis iterator over `str[run_start..run_end]`, all valid.
    inner: ?vaxis.unicode.GraphemeIterator = null,
    run_start: usize = 0,
    run_end: usize = 0,
    /// The run stops at `chunk`, not at an invalid byte or the end: its
    /// last cluster may continue past it.
    cut: bool = false,

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        while (true) {
            if (self.inner) |*it| {
                if (it.next()) |g| {
                    const start = self.run_start + g.start;
                    const end = start + g.len;
                    if (self.cut and end == self.run_end and start > self.run_start) {
                        // Re-scan from this cluster's start so it can take
                        // the bytes after the chunk.
                        self.inner = null;
                        self.pos = start;
                        continue;
                    }
                    self.pos = end;
                    return .{ .start = start, .len = g.len };
                }
                self.inner = null;
                self.pos = self.run_end;
            }
            if (self.pos >= self.str.len) return null;
            const s = self.str;
            // ASCII followed by ASCII is a cluster of its own (CR LF is
            // the one pair that joins) — the common case, without vaxis.
            const c = s[self.pos];
            if (c < 0x80 and c != '\r' and (self.pos + 1 >= s.len or s[self.pos + 1] < 0x80)) {
                const p = self.pos;
                self.pos += 1;
                return .{ .start = p, .len = 1 };
            }
            if (seqLen(s, self.pos) == 0) {
                const p = self.pos;
                self.pos += 1;
                return .{ .start = p, .len = 1 };
            }
            var e = self.pos;
            const lim = @min(s.len, self.pos + chunk);
            while (e < lim) {
                const n = seqLen(s, e);
                if (n == 0) break;
                e += n;
            }
            self.run_start = self.pos;
            self.run_end = e;
            self.cut = e < s.len and seqLen(s, e) != 0;
            self.inner = vaxis.unicode.graphemeIterator(s[self.pos..e]);
        }
    }
};

pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return .{ .str = str };
}

/// Cell width of one grapheme from `GraphemeIterator`: an invalid byte is
/// one cell (it paints as U+FFFD), anything else is vaxis' measure.
pub fn graphemeWidth(g: []const u8, method: vaxis.gwidth.Method) u16 {
    if (g.len == 1 and g[0] >= 0x20 and g[0] < 0x7f) return 1;
    if (isInvalidUnit(g)) return 1;
    return vaxis.gwidth.gwidth(g, method);
}

/// Cell width of `s`, saturating. Safe on any bytes, unlike
/// `vaxis.gwidth.gwidth`.
pub fn width(s: []const u8, method: vaxis.gwidth.Method) u16 {
    var total: u16 = 0;
    var it = graphemeIterator(s);
    while (it.next()) |g| total +|= graphemeWidth(g.bytes(s), method);
    return total;
}

// ─── tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "seqLen: valid sequences, and the invalid shapes are 0" {
    try testing.expectEqual(@as(u3, 1), seqLen("a", 0));
    try testing.expectEqual(@as(u3, 2), seqLen("\u{e9}", 0));
    try testing.expectEqual(@as(u3, 3), seqLen("\u{20ac}", 0));
    try testing.expectEqual(@as(u3, 4), seqLen("\u{1F600}", 0));
    try testing.expectEqual(@as(u3, 0), seqLen("\x98", 0)); // stray continuation
    try testing.expectEqual(@as(u3, 0), seqLen("\xC3", 0)); // cut short
    try testing.expectEqual(@as(u3, 0), seqLen("\xC3x", 0)); // malformed
    try testing.expectEqual(@as(u3, 0), seqLen("\xC0\x80", 0)); // overlong
    try testing.expectEqual(@as(u3, 0), seqLen("\xED\xA0\x80", 0)); // surrogate
    try testing.expectEqual(@as(u3, 0), seqLen("\xFF", 0));
}

test "isBoundary: a stray continuation byte is a unit, a real one is not" {
    try testing.expect(isBoundary("\x98abc", 0));
    try testing.expect(isBoundary("\x98\x98", 1));
    try testing.expect(!isBoundary("\u{e9}", 1));
    try testing.expect(isBoundary("\u{e9}\x98", 2)); // one past a full sequence
    try testing.expect(isBoundary("\xC3x\xA9", 2));
    try testing.expect(isBoundary("\xE2\x82", 1)); // truncated: both bytes stand alone
}

test "GraphemeIterator: invalid bytes are one-byte units, valid runs cluster" {
    // The hunter's crash: stray 0x91, then U+0360 (a combining mark).
    const s = "a\x91\xCD\xA0e\u{301}\xFF";
    var it = graphemeIterator(s);
    const want = [_][2]usize{ .{ 0, 1 }, .{ 1, 1 }, .{ 2, 2 }, .{ 4, 3 }, .{ 7, 1 } };
    for (want) |w| {
        const g = it.next().?;
        try testing.expectEqual(w[0], g.start);
        try testing.expectEqual(w[1], g.len);
    }
    try testing.expect(it.next() == null);
}

test "GraphemeIterator: a cluster straddling the scan chunk stays whole" {
    var buf: [chunk + 8]u8 = undefined;
    @memset(&buf, 'x');
    // "e" + U+0301 with the combining mark right at the chunk edge.
    buf[chunk - 1] = 'e';
    buf[chunk] = 0xCC;
    buf[chunk + 1] = 0x81;
    var it = graphemeIterator(&buf);
    var n: usize = 0;
    var covered: usize = 0;
    while (it.next()) |g| : (n += 1) {
        try testing.expectEqual(covered, g.start);
        covered += g.len;
        if (g.start == chunk - 1) try testing.expectEqual(@as(usize, 3), g.len);
    }
    try testing.expectEqual(buf.len, covered);
    try testing.expectEqual(buf.len - 2, n);
}

test "GraphemeIterator matches vaxis on valid text, ASCII fast path included" {
    const cases = [_][]const u8{
        "plain ascii, tabs\tand CR LF\r\nhere\r",
        "e\u{301}x\u{1F44D}\u{1F3FD}ab\u{1F1FA}\u{1F1F8}\u{200D}c\r\n",
        "a\u{301}\u{302}bc\u{0360}d",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}!",
    };
    for (cases) |s| {
        var ours = graphemeIterator(s);
        var theirs = vaxis.unicode.graphemeIterator(s);
        while (theirs.next()) |want| {
            const got = ours.next().?;
            try testing.expectEqual(want.start, got.start);
            try testing.expectEqual(want.len, got.len);
        }
        try testing.expect(ours.next() == null);
    }
}

test "GraphemeIterator + width survive any bytes (seeded fuzz)" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    const r = prng.random();
    var buf: [96]u8 = undefined;
    for (0..4000) |_| {
        const len = r.uintAtMost(usize, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.int(u8),
            1 => 0x80 + r.uintLessThan(u8, 0x40),
            2 => ([_]u8{ 0xCC, 0xCD, 0x81, 0xA0, 'e', '\n', 0xE2, 0xF0, 0x9F })[r.uintLessThan(usize, 9)],
            else => 'a' + r.uintLessThan(u8, 26),
        };
        var it = graphemeIterator(s);
        var covered: usize = 0;
        while (it.next()) |g| {
            try testing.expectEqual(covered, g.start);
            try testing.expect(g.len > 0);
            try testing.expect(isBoundary(s, g.start));
            covered += g.len;
        }
        try testing.expectEqual(s.len, covered);
        _ = width(s, .unicode);
        _ = width(s, .wcwidth);
    }
}
