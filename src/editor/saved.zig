//! The text as it was last loaded or saved, kept as what differs from
//! the live text: a sorted list of stretches of the live text and the
//! bytes the saved text has there instead. Nothing while the text is as
//! saved; an edit at the top of a file and another at the bottom are two
//! small entries, not the file between them. `dirty` stays what it has
//! always been — a comparison of the two texts — made over those
//! stretches alone.
//!
//! The document tells it about each splice BEFORE it happens
//! (`beforeSplice`), the same contract the undo history's tops have.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Saved = struct {
    diffs: std.ArrayList(Diff) = .empty,

    /// The saved text has `bytes` where the live text has
    /// `[pos, pos + len)`. Sorted by `pos`; no two touch.
    pub const Diff = struct { pos: usize, len: usize, bytes: []u8 };

    pub fn deinit(self: *Saved, gpa: Allocator) void {
        self.reset(gpa);
        self.diffs.deinit(gpa);
    }

    /// The live text is the saved text.
    pub fn reset(self: *Saved, gpa: Allocator) void {
        for (self.diffs.items) |d| gpa.free(d.bytes);
        self.diffs.clearRetainingCapacity();
    }

    /// Bytes held.
    pub fn bytes(self: *const Saved) usize {
        var n: usize = 0;
        for (self.diffs.items) |d| n += d.bytes.len;
        return n;
    }

    /// `live[a..b)` is about to become `new_len` bytes. Every entry the
    /// edit overlaps or touches folds into one with it, taking from the
    /// live text what lies between them; entries after it move along.
    pub fn beforeSplice(self: *Saved, gpa: Allocator, live: []const u8, a: usize, b: usize, new_len: usize) Allocator.Error!void {
        const items = self.diffs.items;
        var i: usize = 0;
        while (i < items.len and items[i].pos + items[i].len < a) i += 1;
        var j = i;
        while (j < items.len and items[j].pos <= b) j += 1;
        // `[i, j)` touch the edit.
        var lo = a;
        var hi = b;
        if (j > i) {
            lo = @min(lo, items[i].pos);
            hi = @max(hi, items[j - 1].pos + items[j - 1].len);
        }
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        var at = lo;
        for (items[i..j]) |d| {
            try buf.appendSlice(gpa, live[at..d.pos]);
            try buf.appendSlice(gpa, d.bytes);
            at = d.pos + d.len;
        }
        try buf.appendSlice(gpa, live[at..hi]);
        if (j == i) try self.diffs.ensureUnusedCapacity(gpa, 1);
        const merged: Diff = .{ .pos = lo, .len = (hi - lo) - (b - a) + new_len, .bytes = try buf.toOwnedSlice(gpa) };
        // Nothing below can fail.
        for (self.diffs.items[i..j]) |d| gpa.free(d.bytes);
        if (j == i) {
            self.diffs.insertAssumeCapacity(i, merged);
        } else {
            self.diffs.items[i] = merged;
            self.diffs.replaceRangeAssumeCapacity(i + 1, j - i - 1, &.{});
        }
        const delta: isize = @as(isize, @intCast(new_len)) - @as(isize, @intCast(b - a));
        for (self.diffs.items[i + 1 ..]) |*d| d.pos = @intCast(@as(isize, @intCast(d.pos)) + delta);
    }

    /// Whether the live text differs from the saved text. Entries the
    /// text has come back to (type a char, take it out again) are let go.
    pub fn differs(self: *Saved, gpa: Allocator, live: []const u8) bool {
        var out: usize = 0;
        for (self.diffs.items) |d| {
            if (d.bytes.len == d.len and std.mem.eql(u8, d.bytes, live[d.pos .. d.pos + d.len])) {
                gpa.free(d.bytes);
                continue;
            }
            self.diffs.items[out] = d;
            out += 1;
        }
        self.diffs.items.len = out;
        return out != 0;
    }

    /// The saved text, whole. Caller owns it.
    pub fn text(self: *const Saved, gpa: Allocator, live: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var at: usize = 0;
        for (self.diffs.items) |d| {
            try out.appendSlice(gpa, live[at..d.pos]);
            try out.appendSlice(gpa, d.bytes);
            at = d.pos + d.len;
        }
        try out.appendSlice(gpa, live[at..]);
        return out.toOwnedSlice(gpa);
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "saved property: through a random script of splices the entries spell the saved text, and differs() is the comparison" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x73617665);
    const rand = prng.random();
    const bits = [_][]const u8{ "x", "", "hello", "\n", "0123456789", "ab" };
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        const original = "alpha beta gamma delta epsilon zeta eta theta iota kappa\n";
        var live: std.ArrayList(u8) = .empty;
        defer live.deinit(gpa);
        try live.appendSlice(gpa, original);
        var saved: Saved = .{};
        defer saved.deinit(gpa);
        // What was typed and where, to take some of it back out again.
        var step: usize = 0;
        while (step < 80) : (step += 1) {
            const a = rand.uintLessThan(usize, live.items.len + 1);
            const b = @min(live.items.len, a + rand.uintLessThan(usize, 6));
            // One time in four, put back what the saved text has there.
            var new: []const u8 = bits[rand.uintLessThan(usize, bits.len)];
            var back: ?[]u8 = null;
            defer if (back) |t| gpa.free(t);
            if (rand.uintLessThan(u8, 4) == 0) {
                back = try saved.text(gpa, live.items);
                // Restore the whole saved text through one splice.
                try saved.beforeSplice(gpa, live.items, 0, live.items.len, back.?.len);
                try live.replaceRange(gpa, 0, live.items.len, back.?);
                try testing.expect(!saved.differs(gpa, live.items));
                try testing.expectEqual(@as(usize, 0), saved.diffs.items.len);
                continue;
            }
            if (a == b and new.len == 0) new = "q";
            try saved.beforeSplice(gpa, live.items, a, b, new.len);
            try live.replaceRange(gpa, a, b - a, new);
            const spelled = try saved.text(gpa, live.items);
            defer gpa.free(spelled);
            try testing.expectEqualStrings(original, spelled);
            try testing.expectEqual(!std.mem.eql(u8, live.items, original), saved.differs(gpa, live.items));
            // Sorted, apart, inside the text.
            var prev_end: usize = 0;
            for (saved.diffs.items, 0..) |d, k| {
                if (k > 0) try testing.expect(d.pos > prev_end);
                prev_end = d.pos + d.len;
                try testing.expect(prev_end <= live.items.len);
            }
        }
    }
}

test "an edit at the top of a file and one at the bottom are two small entries, not the file between them" {
    const gpa = testing.allocator;
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(gpa);
    try live.appendNTimes(gpa, 'a', 1 << 20);
    var saved: Saved = .{};
    defer saved.deinit(gpa);
    try saved.beforeSplice(gpa, live.items, 0, 0, 3);
    try live.replaceRange(gpa, 0, 0, "ZQJ");
    try saved.beforeSplice(gpa, live.items, live.items.len, live.items.len, 4);
    try live.replaceRange(gpa, live.items.len, 0, "QJZ\n");
    try testing.expect(saved.differs(gpa, live.items));
    try testing.expectEqual(@as(usize, 2), saved.diffs.items.len);
    try testing.expectEqual(@as(usize, 0), saved.bytes());
    // Take both back out: clean, and nothing held.
    try saved.beforeSplice(gpa, live.items, 0, 3, 0);
    try live.replaceRange(gpa, 0, 3, "");
    try saved.beforeSplice(gpa, live.items, live.items.len - 4, live.items.len, 0);
    try live.replaceRange(gpa, live.items.len - 4, 4, "");
    try testing.expect(!saved.differs(gpa, live.items));
    try testing.expectEqual(@as(usize, 0), saved.diffs.items.len);
}
