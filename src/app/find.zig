//! Find state for one editor pane: the query, every match, and which
//! one is current. Literal matching with smart case by default; with
//! `regex` on, the query is a vim pattern compiled by `src/regex/`. In
//! literal mode the `\x` escapes a vim user types (`\[`, `\.`, `\/`)
//! fold to their literal char.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("../regex/regex.zig");
const Editor = @import("../editor/editor.zig").Editor;

/// The engine's own range type, so `findAll` can fill `matches` directly.
pub const Range = regex.Range;

/// A vim search offset (`:help search-offset`): `/pat/e+1` lands one
/// past the match's last char, `/pat/s-2` two before its start,
/// `/pat/+1` on the line below in column 1. `n` / `N` keep it.
pub const Offset = struct {
    kind: Kind = .none,
    delta: i64 = 0,

    pub const Kind = enum { none, start, end, line };

    /// `e`, `e+2`, `s-1`, `b3`, `+1`, `-`, `` (none); null when `s` is
    /// not an offset at all.
    pub fn parse(s: []const u8) ?Offset {
        if (s.len == 0) return .{};
        var kind: Kind = .line;
        var rest = s;
        switch (s[0]) {
            'e' => {
                kind = .end;
                rest = s[1..];
            },
            's', 'b' => {
                kind = .start;
                rest = s[1..];
            },
            else => {},
        }
        if (rest.len == 0) return .{ .kind = kind, .delta = if (kind == .line) 1 else 0 };
        const sign: i64 = switch (rest[0]) {
            '+' => 1,
            '-' => -1,
            else => 0,
        };
        const digits = if (sign != 0) rest[1..] else rest;
        if (digits.len == 0) return .{ .kind = kind, .delta = sign };
        const n = std.fmt.parseInt(i64, digits, 10) catch return null;
        return .{ .kind = kind, .delta = if (sign < 0) -n else n };
    }

    /// The byte to land on for a match `[start, end)`.
    pub fn landing(o: Offset, ed: *const Editor, start: usize, end: usize) usize {
        switch (o.kind) {
            .none => return start,
            .start => return stepChars(ed, start, o.delta),
            .end => return stepChars(ed, if (end > start) ed.prevBoundary(end) else start, o.delta),
            .line => {
                const row: i64 = @as(i64, @intCast(ed.lineOfByte(start))) + o.delta;
                const last: i64 = @intCast(ed.lineCount() - 1);
                return ed.lineStart(@intCast(std.math.clamp(row, 0, last)));
            },
        }
    }

    fn stepChars(ed: *const Editor, from: usize, delta: i64) usize {
        var b = from;
        var n: u64 = @abs(delta);
        while (n > 0) : (n -= 1) b = if (delta > 0) ed.nextBoundary(b) else ed.prevBoundary(b);
        return b;
    }
};

pub const FindState = struct {
    gpa: Allocator,
    query: std.ArrayListUnmanaged(u8) = .empty,
    matches: std.ArrayListUnmanaged(Range) = .empty,
    current: ?usize = null,
    regex: bool = false,
    /// How a regex query is written: vim's syntax, or the Perl-style one
    /// the standard profile's find bar takes (`cmd_find.dialectFor`).
    dialect: regex.Dialect = .vim,
    case_sensitive: bool = false,
    /// The last regex query did not compile; `matches` is empty.
    bad_pattern: ?regex.Error = null,
    /// The vim `/pat/e`-style offset the query carried.
    offset: Offset = .{},
    /// The document's edit-log head `matches` were last found against
    /// (`cmd_find.seedCtxMatches`); a key after an edit finds them again,
    /// so `gn` / `.` / `n` never act on the bytes a match used to cover.
    /// Null: just found against the current text by someone else.
    seen_edit: ?u64 = null,
    /// vim's `*` / `#`: only a match that is a whole keyword counts —
    /// the pattern `\<word\>` (`:help star`). `setQuery` clears it.
    whole_word: bool = false,

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
        out.dialect = self.dialect;
        out.case_sensitive = self.case_sensitive;
        out.bad_pattern = self.bad_pattern;
        out.offset = self.offset;
        out.seen_edit = self.seen_edit;
        out.whole_word = self.whole_word;
        return out;
    }

    pub fn isActive(self: *const FindState) bool {
        return self.query.items.len > 0;
    }

    pub fn clear(self: *FindState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.current = null;
        self.offset = .{};
        self.whole_word = false;
    }

    /// Replace the query and recompute every match in `text`. Smart case:
    /// case-sensitive iff the query has an uppercase letter, unless
    /// `case_sensitive` was forced by the caller.
    pub fn setQuery(self: *FindState, query: []const u8, text: []const u8, force_case: ?bool) Allocator.Error!void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.gpa, query);
        self.case_sensitive = force_case orelse if (self.regex and self.dialect == .vim) patternHasUpper(query) else hasUpper(query);
        self.whole_word = false;
        try self.recompute(text);
    }

    /// `*` / `#`: `word` as a whole keyword only (`\<word\>`).
    pub fn setWordQuery(self: *FindState, word: []const u8, text: []const u8, force_case: ?bool) Allocator.Error!void {
        try self.setQuery(word, text, force_case);
        self.whole_word = true;
        try self.recompute(text);
    }

    pub fn recompute(self: *FindState, text: []const u8) Allocator.Error!void {
        // Found against the text as it is now; the next seed stamps it.
        self.seen_edit = null;
        self.matches.clearRetainingCapacity();
        self.current = null;
        self.bad_pattern = null;
        if (self.query.items.len == 0) return;
        if (self.regex) {
            var re = regex.Regex.compile(self.query.items, .{ .ignore_case = !self.case_sensitive, .dialect = self.dialect }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    self.bad_pattern = err;
                    return;
                },
            };
            defer re.deinit();
            try re.findAll(self.gpa, &self.matches, text);
        } else {
            var needle_buf: [256]u8 = undefined;
            const needle = unescape(self.query.items, &needle_buf);
            if (needle.len == 0) return;
            try findAll(self.gpa, &self.matches, text, needle, self.case_sensitive);
        }
        if (self.whole_word) {
            var kept: usize = 0;
            for (self.matches.items) |m| {
                const glued_before = m.start > 0 and isWord(text[m.start - 1]);
                const glued_after = m.end < text.len and isWord(text[m.end]);
                if (glued_before or glued_after) continue;
                self.matches.items[kept] = m;
                kept += 1;
            }
            self.matches.shrinkRetainingCapacity(kept);
        }
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

/// Smart case over a vim pattern (Neovim's `pat_has_uppercase`): an
/// uppercase letter counts only outside an escape, so `\S`, `\A` and
/// `\%V` leave the search case-insensitive and `\cFoo` is decided by
/// its `\c`.
pub fn patternHasUpper(p: []const u8) bool {
    var i: usize = 0;
    while (i < p.len) {
        if (p[i] == '\\') {
            if (i + 2 < p.len and (p[i + 1] == '_' or p[i + 1] == '%')) {
                i += 3;
            } else i += 2;
        } else if (std.ascii.isUpper(p[i])) {
            return true;
        } else i += 1;
    }
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

test "find: a word query takes whole keywords only, and a plain query clears it" {
    const gpa = std.testing.allocator;
    var f = FindState.init(gpa);
    defer f.deinit();
    const text = "bar x\nbarfoo\nfoobar\nbar_1\nbar y";
    try f.setWordQuery("bar", text, null);
    try std.testing.expectEqual(@as(usize, 2), f.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.matches.items[0].start);
    try std.testing.expectEqual(@as(usize, 26), f.matches.items[1].start);
    // An edit's re-find keeps the rule.
    try f.recompute(text);
    try std.testing.expectEqual(@as(usize, 2), f.matches.items.len);
    try f.setQuery("bar", text, null);
    try std.testing.expectEqual(@as(usize, 5), f.matches.items.len);
}

test "find: regex mode compiles a vim pattern; a bad one reports and matches nothing" {
    const gpa = std.testing.allocator;
    var f = FindState.init(gpa);
    defer f.deinit();
    f.regex = true;
    try f.setQuery("\\<a\\w*", "alpha beta\nabc", null);
    try std.testing.expectEqual(@as(usize, 2), f.matches.items.len);
    try std.testing.expectEqual(@as(usize, 11), f.matches.items[1].start);
    try std.testing.expect(f.bad_pattern == null);
    try f.setQuery("\\(x", "x", null);
    try std.testing.expectEqual(@as(usize, 0), f.matches.items.len);
    try std.testing.expectEqual(regex.Error.InvalidPattern, f.bad_pattern.?);
    // Literal mode keeps its own escapes.
    f.regex = false;
    try f.setQuery("\\(x", "(x", null);
    try std.testing.expectEqual(@as(usize, 1), f.matches.items.len);
}

test "find: smart case over a vim pattern skips escaped letters" {
    try std.testing.expect(!patternHasUpper("\\Soo"));
    try std.testing.expect(!patternHasUpper("\\%Vx\\_Sy"));
    try std.testing.expect(patternHasUpper("\\SOO"));
    try std.testing.expect(patternHasUpper("\\cFoo"));
    try std.testing.expect(!patternHasUpper("abc\\"));
}
