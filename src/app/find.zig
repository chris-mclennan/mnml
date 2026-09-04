//! Find state for one editor pane: the query, every match, and which
//! one is current. Literal matching with smart case; the `\x` escapes a
//! vim user types (`\[`, `\.`, `\/`) fold to their literal char, so the
//! common `:%s` shapes work without a regex engine. TODO(find-regex).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Range = struct { start: usize, end: usize };

pub const FindState = struct {
    gpa: Allocator,
    query: std.ArrayListUnmanaged(u8) = .empty,
    matches: std.ArrayListUnmanaged(Range) = .empty,
    current: ?usize = null,
    regex: bool = false,
    case_sensitive: bool = false,

    pub fn init(gpa: Allocator) FindState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FindState) void {
        self.query.deinit(self.gpa);
        self.matches.deinit(self.gpa);
    }

    pub fn clone(self: *const FindState) Allocator.Error!FindState {
        var out = FindState.init(self.gpa);
        errdefer out.deinit();
        try out.query.appendSlice(self.gpa, self.query.items);
        try out.matches.appendSlice(self.gpa, self.matches.items);
        out.current = self.current;
        out.regex = self.regex;
        out.case_sensitive = self.case_sensitive;
        return out;
    }

    pub fn isActive(self: *const FindState) bool {
        return self.query.items.len > 0;
    }

    pub fn clear(self: *FindState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.current = null;
    }

    /// Replace the query and recompute every match in `text`. Smart case:
    /// case-sensitive iff the query has an uppercase letter, unless
    /// `case_sensitive` was forced by the caller.
    pub fn setQuery(self: *FindState, query: []const u8, text: []const u8, force_case: ?bool) Allocator.Error!void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.gpa, query);
        self.case_sensitive = force_case orelse hasUpper(query);
        try self.recompute(text);
    }

    pub fn recompute(self: *FindState, text: []const u8) Allocator.Error!void {
        self.matches.clearRetainingCapacity();
        self.current = null;
        if (self.query.items.len == 0) return;
        var needle_buf: [256]u8 = undefined;
        const needle = unescape(self.query.items, &needle_buf);
        if (needle.len == 0) return;
        try findAll(self.gpa, &self.matches, text, needle, self.case_sensitive);
    }

    /// The first match starting at or after `byte`, wrapping to 0.
    pub fn indexAtOrAfter(self: *const FindState, byte: usize) ?usize {
        if (self.matches.items.len == 0) return null;
        for (self.matches.items, 0..) |m, i| if (m.start >= byte) return i;
        return 0;
    }

    /// The last match starting before `byte`, wrapping to the last.
    pub fn indexBefore(self: *const FindState, byte: usize) ?usize {
        const n = self.matches.items.len;
        if (n == 0) return null;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (self.matches.items[i].start < byte) return i;
        }
        return n - 1;
    }

    pub fn step(self: *FindState, delta: i32) ?Range {
        const n = self.matches.items.len;
        if (n == 0) return null;
        const cur: i64 = @intCast(self.current orelse 0);
        const next = @mod(cur + delta, @as(i64, @intCast(n)));
        self.current = @intCast(next);
        return self.matches.items[@intCast(next)];
    }
};

pub fn hasUpper(s: []const u8) bool {
    for (s) |c| if (std.ascii.isUpper(c)) return true;
    return false;
}

/// `\[` → `[`, `\.` → `.`, `\/` → `/`, `\\` → `\`, `\n` → newline, `\t` → tab.
/// Anything else after a backslash is kept verbatim (the backslash goes).
pub fn unescape(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            out[n] = switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                else => s[i],
            };
        } else out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

/// Every non-overlapping occurrence of `needle` in `text`.
pub fn findAll(gpa: Allocator, out: *std.ArrayListUnmanaged(Range), text: []const u8, needle: []const u8, case_sensitive: bool) Allocator.Error!void {
    if (needle.len == 0 or needle.len > text.len) return;
    var i: usize = 0;
    while (i + needle.len <= text.len) {
        const hay = text[i .. i + needle.len];
        const hit = if (case_sensitive) std.mem.eql(u8, hay, needle) else std.ascii.eqlIgnoreCase(hay, needle);
        if (hit) {
            try out.append(gpa, .{ .start = i, .end = i + needle.len });
            i += needle.len;
        } else i += 1;
    }
}

/// Identifier under `byte`: `[start, end)`, or null when not on one.
pub fn wordAt(text: []const u8, byte: usize) ?Range {
    if (text.len == 0) return null;
    var s = @min(byte, text.len);
    if (s == text.len or !isWord(text[s])) return null;
    while (s > 0 and isWord(text[s - 1])) s -= 1;
    var e = s;
    while (e < text.len and isWord(text[e])) e += 1;
    if (e == s) return null;
    return .{ .start = s, .end = e };
}

pub fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

test "find: smart case, escapes, wrap-around stepping" {
    const gpa = std.testing.allocator;
    var f = FindState.init(gpa);
    defer f.deinit();
    try f.setQuery("alpha", "alpha\nbeta\nALPHA\ngamma\nalpha", null);
    try std.testing.expectEqual(@as(usize, 3), f.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.indexAtOrAfter(0).?);
    try std.testing.expectEqual(@as(usize, 1), f.indexAtOrAfter(1).?);
    try std.testing.expectEqual(@as(usize, 2), f.indexBefore(0).?);
    f.current = 2;
    try std.testing.expectEqual(@as(usize, 0), f.step(1).?.start);
    try std.testing.expectEqual(@as(usize, 0), f.current.?);
    try f.setQuery("Alpha", "alpha Alpha", null);
    try std.testing.expectEqual(@as(usize, 1), f.matches.items.len);
    try f.setQuery("\\[drop\\] ", "keep [drop] keep", null);
    try std.testing.expectEqual(@as(usize, 5), f.matches.items[0].start);
    try std.testing.expectEqual(@as(usize, 6), wordAt("hello world", 8).?.start);
    try std.testing.expect(wordAt("a b", 1) == null);
}
