//! Intraline highlighting for a removed / added line pair: which bytes
//! of each line are not part of the longest common subsequence, so the
//! diff pane can brighten only the words that changed.
//!
//! The common prefix and suffix are peeled first — that is the whole
//! answer for the usual one-word edit — and the LCS table runs over what
//! is left. The table is `O(m·n)`; past `max_cells` the middle is
//! reported as one changed span per side instead, which is what the
//! prefix / suffix peel gives on its own. Ranges never split a UTF-8
//! sequence: an edge inside a multi-byte character is moved back to the
//! character's first byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte range, `start` inclusive, `end` exclusive.
pub const Range = struct { start: u32, end: u32 };

pub const Ranges = struct {
    old: []const Range,
    new: []const Range,

    pub const none: Ranges = .{ .old = &.{}, .new = &.{} };
};

/// The DP table stops here; beyond it the peeled middle is one span.
pub const max_cells: usize = 64 * 1024;

/// Bytes of `old` and `new` that are not common — the changed spans of
/// each side, on `arena`. Two identical lines give no ranges.
pub fn diff(arena: Allocator, old: []const u8, new: []const u8) Allocator.Error!Ranges {
    const pre = commonPrefix(old, new);
    const suf = commonSuffix(old[pre..], new[pre..]);
    const o = old[pre .. old.len - suf];
    const n = new[pre .. new.len - suf];
    if (o.len == 0 and n.len == 0) return Ranges.none;
    if (o.len == 0 or n.len == 0 or o.len * n.len > max_cells) {
        return .{
            .old = if (o.len == 0) &.{} else try single(arena, old, pre, pre + o.len),
            .new = if (n.len == 0) &.{} else try single(arena, new, pre, pre + n.len),
        };
    }
    // LCS lengths, one row of the table per byte of `o`.
    const w = n.len + 1;
    const table = try arena.alloc(u16, (o.len + 1) * w);
    @memset(table, 0);
    for (o, 0..) |oc, i| for (n, 0..) |nc, j| {
        table[(i + 1) * w + (j + 1)] = if (oc == nc)
            table[i * w + j] + 1
        else
            @max(table[i * w + (j + 1)], table[(i + 1) * w + j]);
    };
    // Walk back, marking the bytes that are in the subsequence.
    const in_old = try arena.alloc(bool, o.len);
    const in_new = try arena.alloc(bool, n.len);
    @memset(in_old, false);
    @memset(in_new, false);
    var i = o.len;
    var j = n.len;
    while (i > 0 and j > 0) {
        if (o[i - 1] == n[j - 1]) {
            in_old[i - 1] = true;
            in_new[j - 1] = true;
            i -= 1;
            j -= 1;
        } else if (table[(i - 1) * w + j] >= table[i * w + (j - 1)]) {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    return .{
        .old = try runs(arena, old, in_old, pre),
        .new = try runs(arena, new, in_new, pre),
    };
}

fn single(arena: Allocator, s: []const u8, start: usize, end: usize) Allocator.Error![]const Range {
    const out = try arena.alloc(Range, 1);
    out[0] = .{ .start = @intCast(snapBack(s, start)), .end = @intCast(snapForward(s, end)) };
    return out;
}

/// Maximal runs of `false` in `common`, offset by `base`, snapped to
/// character edges and merged where the snap made them touch.
fn runs(arena: Allocator, s: []const u8, common: []const bool, base: usize) Allocator.Error![]const Range {
    var out: std.ArrayListUnmanaged(Range) = .empty;
    var k: usize = 0;
    while (k < common.len) {
        if (common[k]) {
            k += 1;
            continue;
        }
        var e = k;
        while (e < common.len and !common[e]) e += 1;
        const start: u32 = @intCast(snapBack(s, base + k));
        const end: u32 = @intCast(snapForward(s, base + e));
        if (out.items.len > 0 and out.items[out.items.len - 1].end >= start) {
            out.items[out.items.len - 1].end = @max(out.items[out.items.len - 1].end, end);
        } else {
            try out.append(arena, .{ .start = start, .end = end });
        }
        k = e;
    }
    return out.items;
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    var p: usize = 0;
    while (p < a.len and p < b.len and a[p] == b[p]) p += 1;
    return p;
}

fn commonSuffix(a: []const u8, b: []const u8) usize {
    var s: usize = 0;
    while (s < a.len and s < b.len and a[a.len - 1 - s] == b[b.len - 1 - s]) s += 1;
    return s;
}

/// `i` moved back to the first byte of the character it sits in.
fn snapBack(s: []const u8, i: usize) usize {
    var k = @min(i, s.len);
    while (k > 0 and k < s.len and (s[k] & 0xC0) == 0x80) k -= 1;
    return k;
}

/// `i` moved forward past any continuation bytes.
fn snapForward(s: []const u8, i: usize) usize {
    var k = @min(i, s.len);
    while (k < s.len and (s[k] & 0xC0) == 0x80) k += 1;
    return k;
}

/// True when `b` lies in one of `ranges`.
pub fn contains(ranges: []const Range, b: usize) bool {
    for (ranges) |r| if (b >= r.start and b < r.end) return true;
    return false;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectRanges(expected: []const Range, got: []const Range) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
        try testing.expectEqual(e.start, g.start);
        try testing.expectEqual(e.end, g.end);
    }
}

test "intraline: a one-word edit is the word on each side" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // The common suffix starts at the `a` both words end in: `alph` / `bet`.
    const r = try diff(a.allocator(), "fn alpha() {}", "fn beta() {}");
    try expectRanges(&.{.{ .start = 3, .end = 7 }}, r.old);
    try expectRanges(&.{.{ .start = 3, .end = 6 }}, r.new);
}

test "intraline: identical lines have no ranges; a pure insertion marks only the new side" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const same = try diff(a.allocator(), "let x = 1;", "let x = 1;");
    try testing.expectEqual(@as(usize, 0), same.old.len);
    try testing.expectEqual(@as(usize, 0), same.new.len);
    const ins = try diff(a.allocator(), "let x = 1;", "let mut x = 1;");
    try testing.expectEqual(@as(usize, 0), ins.old.len);
    try expectRanges(&.{.{ .start = 4, .end = 8 }}, ins.new);
}

test "intraline: two edits on one line give two ranges (the LCS keeps the middle)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const r = try diff(a.allocator(), "aa MID bb", "cc MID dd");
    try expectRanges(&.{ .{ .start = 0, .end = 2 }, .{ .start = 7, .end = 9 } }, r.old);
    try expectRanges(&.{ .{ .start = 0, .end = 2 }, .{ .start = 7, .end = 9 } }, r.new);
    try testing.expect(contains(r.old, 1));
    try testing.expect(!contains(r.old, 4));
}

test "intraline: ranges snap to UTF-8 boundaries" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // é is 0xC3 0xA9; è is 0xC3 0xA8 — they share the lead byte.
    const r = try diff(a.allocator(), "caf\xc3\xa9", "caf\xc3\xa8");
    try expectRanges(&.{.{ .start = 3, .end = 5 }}, r.old);
    try expectRanges(&.{.{ .start = 3, .end = 5 }}, r.new);
}

test "intraline: past the cap the peeled middle is one span per side" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const big = try a.allocator().alloc(u8, 400);
    @memset(big, 'x');
    const big2 = try a.allocator().alloc(u8, 400);
    @memset(big2, 'y');
    const old = try std.mem.concat(a.allocator(), u8, &.{ "pre ", big, " post" });
    const new = try std.mem.concat(a.allocator(), u8, &.{ "pre ", big2, " post" });
    const r = try diff(a.allocator(), old, new);
    try expectRanges(&.{.{ .start = 4, .end = 404 }}, r.old);
    try expectRanges(&.{.{ .start = 4, .end = 404 }}, r.new);
}
