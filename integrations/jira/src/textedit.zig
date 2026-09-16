//! A one-line text field with a caret: the filter, the JQL editor, the
//! comment box and every picker's filter share it. Arrows, Home / End,
//! word jumps, forward delete, word delete, the readline kills, paste —
//! the affordances the reference gave its JQL editor, here for every
//! field (an append-only field is the gap the user hits every time).
//! The cursor is a byte offset on a code-point boundary.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TextEdit = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

    pub fn init(gpa: Allocator) TextEdit {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *TextEdit) void {
        t.buf.deinit(t.gpa);
        t.* = undefined;
    }

    pub fn text(t: *const TextEdit) []const u8 {
        return t.buf.items;
    }

    pub fn set(t: *TextEdit, s: []const u8) Allocator.Error!void {
        t.buf.clearRetainingCapacity();
        try t.buf.appendSlice(t.gpa, s);
        t.cursor = t.buf.items.len;
    }

    pub fn clear(t: *TextEdit) void {
        t.buf.clearRetainingCapacity();
        t.cursor = 0;
    }

    pub fn insert(t: *TextEdit, s: []const u8) Allocator.Error!void {
        try t.buf.insertSlice(t.gpa, t.cursor, s);
        t.cursor += s.len;
    }

    fn prevBoundary(t: *const TextEdit, from: usize) usize {
        if (from == 0) return 0;
        var i = from - 1;
        while (i > 0 and (t.buf.items[i] & 0xC0) == 0x80) : (i -= 1) {}
        return i;
    }

    fn nextBoundary(t: *const TextEdit, from: usize) usize {
        if (from >= t.buf.items.len) return t.buf.items.len;
        var i = from + 1;
        while (i < t.buf.items.len and (t.buf.items[i] & 0xC0) == 0x80) : (i += 1) {}
        return i;
    }

    pub fn backspace(t: *TextEdit) void {
        if (t.cursor == 0) return;
        const start = t.prevBoundary(t.cursor);
        t.buf.replaceRangeAssumeCapacity(start, t.cursor - start, &.{});
        t.cursor = start;
    }

    pub fn deleteForward(t: *TextEdit) void {
        if (t.cursor >= t.buf.items.len) return;
        const stop = t.nextBoundary(t.cursor);
        t.buf.replaceRangeAssumeCapacity(t.cursor, stop - t.cursor, &.{});
    }

    pub fn left(t: *TextEdit) void {
        t.cursor = t.prevBoundary(t.cursor);
    }

    pub fn right(t: *TextEdit) void {
        t.cursor = t.nextBoundary(t.cursor);
    }

    pub fn home(t: *TextEdit) void {
        t.cursor = 0;
    }

    pub fn end(t: *TextEdit) void {
        t.cursor = t.buf.items.len;
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    pub fn wordLeft(t: *TextEdit) void {
        var i = t.cursor;
        while (i > 0 and !isWord(t.buf.items[i - 1])) : (i -= 1) {}
        while (i > 0 and isWord(t.buf.items[i - 1])) : (i -= 1) {}
        t.cursor = i;
    }

    pub fn wordRight(t: *TextEdit) void {
        var i = t.cursor;
        const n = t.buf.items.len;
        while (i < n and isWord(t.buf.items[i])) : (i += 1) {}
        while (i < n and !isWord(t.buf.items[i])) : (i += 1) {}
        t.cursor = i;
    }

    pub fn deleteWordBack(t: *TextEdit) void {
        const end_at = t.cursor;
        t.wordLeft();
        if (t.cursor == end_at) return;
        t.buf.replaceRangeAssumeCapacity(t.cursor, end_at - t.cursor, &.{});
    }

    pub fn killToStart(t: *TextEdit) void {
        t.buf.replaceRangeAssumeCapacity(0, t.cursor, &.{});
        t.cursor = 0;
    }

    pub fn killToEnd(t: *TextEdit) void {
        t.buf.shrinkRetainingCapacity(t.cursor);
    }

    /// The caret's code-point index, for painting.
    pub fn cursorCodepoints(t: *const TextEdit) usize {
        return std.unicode.utf8CountCodepoints(t.buf.items[0..t.cursor]) catch t.cursor;
    }

    /// Place the caret at a code-point index (a click).
    pub fn setCursorCodepoints(t: *TextEdit, cp: usize) void {
        var i: usize = 0;
        var n: usize = 0;
        while (i < t.buf.items.len and n < cp) : (n += 1) i = t.nextBoundary(i);
        t.cursor = i;
    }

    /// A key spec the field handles itself; false means "not mine".
    pub fn key(t: *TextEdit, spec: []const u8) Allocator.Error!bool {
        if (std.mem.eql(u8, spec, "backspace")) {
            t.backspace();
        } else if (std.mem.eql(u8, spec, "delete")) {
            t.deleteForward();
        } else if (std.mem.eql(u8, spec, "left")) {
            t.left();
        } else if (std.mem.eql(u8, spec, "right")) {
            t.right();
        } else if (std.mem.eql(u8, spec, "home") or std.mem.eql(u8, spec, "ctrl+a") or std.mem.eql(u8, spec, "ctrl+left") or std.mem.eql(u8, spec, "super+left")) {
            t.home();
        } else if (std.mem.eql(u8, spec, "end") or std.mem.eql(u8, spec, "ctrl+e") or std.mem.eql(u8, spec, "ctrl+right") or std.mem.eql(u8, spec, "super+right")) {
            t.end();
        } else if (std.mem.eql(u8, spec, "alt+left")) {
            t.wordLeft();
        } else if (std.mem.eql(u8, spec, "alt+right")) {
            t.wordRight();
        } else if (std.mem.eql(u8, spec, "ctrl+w") or std.mem.eql(u8, spec, "alt+backspace") or std.mem.eql(u8, spec, "ctrl+backspace")) {
            t.deleteWordBack();
        } else if (std.mem.eql(u8, spec, "ctrl+u")) {
            t.killToStart();
        } else if (std.mem.eql(u8, spec, "ctrl+k")) {
            t.killToEnd();
        } else if (std.mem.eql(u8, spec, "space")) {
            try t.insert(" ");
        } else if (printable(spec)) |s| {
            try t.insert(s);
        } else return false;
        return true;
    }

    /// The text a key spec inserts: one code point, or `shift+x` → `X`.
    pub fn printable(spec: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, spec, "shift+") and spec.len > 6) {
            const rest = spec[6..];
            if (rest.len == 1 and std.ascii.isLower(rest[0])) return &upper_table[rest[0] - 'a'];
            return printable(rest);
        }
        if (spec.len == 0) return null;
        const cp_len = std.unicode.utf8ByteSequenceLength(spec[0]) catch return null;
        if (cp_len != spec.len) return null;
        if (spec.len == 1 and (spec[0] < 0x20 or spec[0] == 0x7f)) return null;
        return spec;
    }
};

const upper_table = blk: {
    var t: [26][1]u8 = undefined;
    for (&t, 0..) |*c, i| c.* = .{'A' + @as(u8, @intCast(i))};
    break :blk t;
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "insert, move, delete, words, kills and a click-placed caret" {
    var t = TextEdit.init(testing.allocator);
    defer t.deinit();
    try t.set("assignee = currentUser()");
    try testing.expectEqual(t.buf.items.len, t.cursor);
    _ = try t.key("space");
    try t.insert("AND x");
    try testing.expectEqualStrings("assignee = currentUser() AND x", t.text());
    t.home();
    t.wordRight();
    try testing.expectEqual(@as(usize, 11), t.cursor);
    t.wordLeft();
    try testing.expectEqual(@as(usize, 0), t.cursor);
    t.end();
    t.deleteWordBack();
    try testing.expectEqualStrings("assignee = currentUser() AND ", t.text());
    t.killToStart();
    try testing.expectEqualStrings("", t.text());
    try t.set("héllo wörld");
    t.left();
    t.left();
    try testing.expectEqual(@as(usize, 9), t.cursorCodepoints());
    t.backspace();
    try testing.expectEqualStrings("héllo wöld", t.text());
    t.home();
    t.deleteForward();
    try testing.expectEqualStrings("éllo wöld", t.text());
    _ = try t.key("ctrl+k");
    try testing.expectEqualStrings("", t.text());
    try t.set("abcdef");
    t.setCursorCodepoints(2);
    try testing.expectEqual(@as(usize, 2), t.cursor);
    t.setCursorCodepoints(99);
    try testing.expectEqual(@as(usize, 6), t.cursor);
    try testing.expect(try t.key("shift+q"));
    try testing.expectEqualStrings("abcdefQ", t.text());
    try testing.expect(!(try t.key("f5")));
    try testing.expect(!(try t.key("enter")));
    try testing.expectEqualStrings("Q", TextEdit.printable("shift+q").?);
    try testing.expectEqualStrings("é", TextEdit.printable("é").?);
    try testing.expect(TextEdit.printable("ctrl+x") == null);
}
