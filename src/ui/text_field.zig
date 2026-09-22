//! Text field — the one editing core behind every single-line input:
//! the prompt, the find bar's two fields, the picker's query, a list
//! panel's filter. A field is a byte buffer plus a byte caret; this
//! module moves the caret by code point, edits with the readline set
//! (←/→, home/end, backspace/delete, ctrl+a/e/u/k/w, alt+b/f), inserts
//! a paste, and paints the text with the caret kept in view.
//!
//! The Rust mnml grew four copies of this, each missing something (one
//! could only append, one had no paste); a field here is complete on
//! its first day. Overlay text fields ship with cursor, arrows, paste
//! and paste-drop from day one — that gap gets hit every time.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const key_mod = @import("../core/key.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
pub const Key = key_mod.Key;
pub const Buf = std.ArrayListUnmanaged(u8);

/// A screen cell for the terminal cursor.
pub const Caret = struct { x: u16, y: u16 };

pub const Edit = enum {
    /// Not a field key — the caller routes it elsewhere.
    ignored,
    /// The caret moved; the text is the same.
    moved,
    /// The text changed.
    changed,
};

/// The editing keys. Byte `caret` is kept on a code point boundary.
pub fn handleKey(buf: *Buf, caret: *usize, gpa: Allocator, key: Key) Allocator.Error!Edit {
    const m = key.mods;
    const text = buf.items;
    if (caret.* > text.len) caret.* = text.len;
    switch (key.code) {
        .left => {
            if (m.ctrl or m.alt) caret.* = prevWord(text, caret.*) else caret.* = prevCp(text, caret.*);
            return .moved;
        },
        .right => {
            if (m.ctrl or m.alt) caret.* = nextWord(text, caret.*) else caret.* = nextCp(text, caret.*);
            return .moved;
        },
        .home => {
            caret.* = 0;
            return .moved;
        },
        .end => {
            caret.* = text.len;
            return .moved;
        },
        .backspace => {
            if (m.ctrl or m.alt) return deleteRange(buf, caret, prevWord(text, caret.*), caret.*);
            return deleteRange(buf, caret, prevCp(text, caret.*), caret.*);
        },
        .delete => {
            if (m.ctrl or m.alt) return deleteRange(buf, caret, caret.*, nextWord(text, caret.*));
            return deleteRange(buf, caret, caret.*, nextCp(text, caret.*));
        },
        .char => |c| {
            if (m.ctrl and !m.alt) switch (c) {
                'a' => {
                    caret.* = 0;
                    return .moved;
                },
                'e' => {
                    caret.* = text.len;
                    return .moved;
                },
                'b' => {
                    caret.* = prevCp(text, caret.*);
                    return .moved;
                },
                'f' => {
                    caret.* = nextCp(text, caret.*);
                    return .moved;
                },
                'u' => return deleteRange(buf, caret, 0, caret.*),
                'k' => return deleteRange(buf, caret, caret.*, text.len),
                'w', 'h' => {
                    if (c == 'h') return deleteRange(buf, caret, prevCp(text, caret.*), caret.*);
                    return deleteRange(buf, caret, prevWord(text, caret.*), caret.*);
                },
                'd' => return deleteRange(buf, caret, caret.*, nextCp(text, caret.*)),
                else => return .ignored,
            };
            if (m.alt and !m.ctrl) switch (c) {
                'b' => {
                    caret.* = prevWord(text, caret.*);
                    return .moved;
                },
                'f' => {
                    caret.* = nextWord(text, caret.*);
                    return .moved;
                },
                'd' => return deleteRange(buf, caret, caret.*, nextWord(text, caret.*)),
                else => return .ignored,
            };
            if (key.typed()) |cp| {
                if (cp < 0x20 or cp == 0x7f) return .ignored;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch return .ignored;
                try insert(buf, caret, gpa, tmp[0..n]);
                return .changed;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Inserts `text` at the caret (a paste). Control characters other
/// than tab are dropped and newlines become spaces: a single-line
/// field must never hold a line break.
pub fn insert(buf: *Buf, caret: *usize, gpa: Allocator, text: []const u8) Allocator.Error!void {
    return insertWith(buf, caret, gpa, text, ' ');
}

/// `insert` for a field that holds lines (the graph's commit box):
/// a line break stays a line break, a CRLF pair is one.
pub fn insertMultiline(buf: *Buf, caret: *usize, gpa: Allocator, text: []const u8) Allocator.Error!void {
    return insertWith(buf, caret, gpa, text, '\n');
}

fn insertWith(buf: *Buf, caret: *usize, gpa: Allocator, text: []const u8, newline: u8) Allocator.Error!void {
    if (caret.* > buf.items.len) caret.* = buf.items.len;
    try buf.ensureUnusedCapacity(gpa, text.len);
    var cleaned: [256]u8 = undefined;
    var i: usize = 0;
    while (i < text.len) {
        var n: usize = 0;
        while (i < text.len and n < cleaned.len) : (i += 1) {
            const c = text[i];
            if (c == '\n' or c == '\r') {
                // A CRLF pair is one break.
                if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
                cleaned[n] = newline;
                n += 1;
            } else if (c < 0x20 and c != '\t') {
                continue;
            } else if (c == 0x7f) {
                continue;
            } else {
                cleaned[n] = c;
                n += 1;
            }
        }
        buf.insertSliceAssumeCapacity(caret.*, cleaned[0..n]);
        caret.* += n;
    }
}

fn deleteRange(buf: *Buf, caret: *usize, lo: usize, hi: usize) Edit {
    if (lo >= hi) return .moved;
    buf.replaceRangeAssumeCapacity(lo, hi - lo, &.{});
    caret.* = lo;
    return .changed;
}

pub fn prevCp(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i > 0) {
        i -= 1;
        if (text[i] & 0xC0 != 0x80) break;
    }
    return i;
}

pub fn nextCp(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    var i = at + 1;
    while (i < text.len and text[i] & 0xC0 == 0x80) i += 1;
    return i;
}

fn isWordByte(c: u8) bool {
    return c != ' ' and c != '\t';
}

/// Start of the word before `at`: skip whitespace, then the word.
pub fn prevWord(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i > 0 and !isWordByte(text[i - 1])) i -= 1;
    while (i > 0 and isWordByte(text[i - 1])) i -= 1;
    return i;
}

/// End of the word after `at`: skip whitespace, then the word.
pub fn nextWord(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i < text.len and !isWordByte(text[i])) i += 1;
    while (i < text.len and isWordByte(text[i])) i += 1;
    return i;
}

pub const DrawOptions = struct {
    style: Style,
    placeholder: ?[]const u8 = null,
    placeholder_style: ?Style = null,
    /// Paint one bullet per code point instead of the text.
    secret: bool = false,
    /// Show the caret (return its cell). An unfocused field returns null.
    focused: bool = true,
};

/// Paints `text` into `r` (one row) so the caret is inside it, scrolling
/// the text left when needed. Returns the caret's cell when focused.
pub fn draw(ui: Ui, r: Rect, text: []const u8, caret: usize, opts: DrawOptions) ?Caret {
    if (r.isEmpty()) return null;
    ui.fill(r, opts.style);
    const w = r.w;
    if (text.len == 0) {
        if (opts.placeholder) |ph| {
            const ps = opts.placeholder_style orelse Theme.withFg(opts.style, ui.theme.muted.fg);
            _ = ui.putStr(r.x, r.y, w, ph, ps);
        }
        return if (opts.focused) .{ .x = r.x, .y = r.y } else null;
    }

    // Layout: one entry per grapheme with its byte start and width.
    const Cell = struct { start: usize, end: usize, w: u16 };
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        const cw: u16 = if (opts.secret) 1 else ui.canvas.cellWidth(bytes);
        if (cw == 0) continue;
        cells.append(ui.arena, .{ .start = g.start, .end = g.start + g.len, .w = @min(cw, 2) }) catch return null;
    }
    const c = @min(caret, text.len);
    // Display column of the caret.
    var caret_col: u32 = 0;
    for (cells.items) |cell| {
        if (cell.start >= c) break;
        caret_col += cell.w;
    }
    // First painted cell: scroll so the caret sits inside the row, with
    // one cell left free for the caret itself at the end of the text.
    var first: usize = 0;
    var skipped: u32 = 0;
    while (caret_col - skipped >= w and first < cells.items.len) : (first += 1) {
        skipped += cells.items[first].w;
    }
    var x = r.x;
    for (cells.items[first..]) |cell| {
        if (x + cell.w > r.right()) break;
        const g = if (opts.secret) "•" else text[cell.start..cell.end];
        ui.canvas.put(x, r.y, .{ .char = .{ .grapheme = g, .width = @intCast(cell.w) }, .style = opts.style });
        x += cell.w;
    }
    if (!opts.focused) return null;
    const cx: u32 = @as(u32, r.x) + (caret_col - skipped);
    return .{ .x = @intCast(@min(cx, r.right() - 1)), .y = r.y };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const Field = struct {
    buf: Buf = .empty,
    caret: usize = 0,

    fn deinit(f: *Field) void {
        f.buf.deinit(testing.allocator);
    }
    fn key(f: *Field, k: Key) !Edit {
        return handleKey(&f.buf, &f.caret, testing.allocator, k);
    }
    fn type_(f: *Field, s: []const u8) !void {
        for (s) |c| _ = try f.key(Key.char(c));
    }
    fn text(f: *Field) []const u8 {
        return f.buf.items;
    }
};

test "typing inserts at the caret; arrows, home and end move it" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("helo");
    try testing.expectEqualStrings("helo", f.text());
    try testing.expectEqual(@as(Edit, .moved), try f.key(Key.named(.left)));
    try testing.expectEqual(@as(Edit, .moved), try f.key(Key.named(.left)));
    try testing.expectEqual(@as(Edit, .changed), try f.key(Key.char('l')));
    try testing.expectEqualStrings("hello", f.text());
    try testing.expectEqual(@as(usize, 3), f.caret);
    _ = try f.key(Key.named(.home));
    try testing.expectEqual(@as(usize, 0), f.caret);
    _ = try f.key(Key.named(.end));
    try testing.expectEqual(@as(usize, 5), f.caret);
    _ = try f.key(Key.named(.right)); // at the end: stays
    try testing.expectEqual(@as(usize, 5), f.caret);
    try testing.expectEqual(@as(Edit, .ignored), try f.key(Key.named(.enter)));
    try testing.expectEqual(@as(Edit, .ignored), try f.key(Key.named(.esc)));
    try testing.expectEqual(@as(Edit, .ignored), try f.key(Key.ctrl('x')));
}

test "backspace and delete work by code point, ctrl variants by word" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("ab");
    _ = try insert(&f.buf, &f.caret, testing.allocator, "é");
    try f.type_("c");
    try testing.expectEqualStrings("abéc", f.text());
    _ = try f.key(Key.named(.left));
    try testing.expectEqual(@as(Edit, .changed), try f.key(Key.named(.backspace)));
    try testing.expectEqualStrings("abc", f.text());
    try testing.expectEqual(@as(usize, 2), f.caret);
    _ = try f.key(Key.named(.home));
    try testing.expectEqual(@as(Edit, .moved), try f.key(Key.named(.backspace))); // nothing before
    try testing.expectEqual(@as(Edit, .changed), try f.key(Key.named(.delete)));
    try testing.expectEqualStrings("bc", f.text());

    var g: Field = .{};
    defer g.deinit();
    try g.type_("one two  three");
    try testing.expectEqual(@as(Edit, .changed), try g.key(Key.ctrl('w')));
    try testing.expectEqualStrings("one two  ", g.text());
    _ = try g.key(.{ .code = .backspace, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("one ", g.text());
    _ = try g.key(Key.named(.home));
    _ = try g.key(.{ .code = .delete, .mods = .{ .alt = true } });
    try testing.expectEqualStrings(" ", g.text());
}

test "ctrl+a/e/u/k and word motions" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("alpha beta gamma");
    _ = try f.key(Key.ctrl('a'));
    try testing.expectEqual(@as(usize, 0), f.caret);
    _ = try f.key(.{ .code = .right, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 5), f.caret);
    _ = try f.key(.{ .code = .{ .char = 'f' }, .mods = .{ .alt = true } });
    try testing.expectEqual(@as(usize, 10), f.caret);
    _ = try f.key(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true } });
    try testing.expectEqual(@as(usize, 6), f.caret);
    _ = try f.key(Key.ctrl('k'));
    try testing.expectEqualStrings("alpha ", f.text());
    _ = try f.key(Key.ctrl('e'));
    try testing.expectEqual(@as(usize, 6), f.caret);
    _ = try f.key(Key.ctrl('u'));
    try testing.expectEqualStrings("", f.text());
    try testing.expectEqual(@as(usize, 0), f.caret);
}

test "paste inserts at the caret, folds line breaks, drops control bytes" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("ac");
    _ = try f.key(Key.named(.left));
    try insert(&f.buf, &f.caret, testing.allocator, "b\r\nx\x01y\tz");
    try testing.expectEqualStrings("ab xy\tzc", f.text());
    try testing.expectEqual(@as(usize, 7), f.caret);
    // A paste longer than the staging buffer still lands whole.
    var big: [700]u8 = undefined;
    @memset(&big, 'q');
    try insert(&f.buf, &f.caret, testing.allocator, &big);
    try testing.expectEqual(@as(usize, 708), f.text().len);
    try testing.expectEqual(@as(usize, 707), f.caret);
}

test "insertMultiline keeps line breaks (CRLF as one), still drops control bytes" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("ac");
    _ = try f.key(Key.named(.left));
    try insertMultiline(&f.buf, &f.caret, testing.allocator, "b\r\nx\x01y\n\nz");
    try testing.expectEqualStrings("ab\nxy\n\nzc", f.text());
    try testing.expectEqual(@as(usize, 8), f.caret);
}

test "draw paints the text, the placeholder, and keeps the caret in view" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    const ui = f.ui();
    const r = f.full();
    const style = f.theme.chip;
    var c = draw(ui, r, "", 0, .{ .style = style, .placeholder = "filter" });
    try f.expectRow(0, "filter");
    try testing.expect(f.fgEql(0, 0, f.theme.muted));
    try testing.expectEqual(Caret{ .x = 0, .y = 0 }, c.?);

    c = draw(ui, r, "abc", 1, .{ .style = style });
    try f.expectRow(0, "abc");
    try testing.expectEqual(Caret{ .x = 1, .y = 0 }, c.?);
    try testing.expect(draw(ui, r, "abc", 1, .{ .style = style, .focused = false }) == null);

    // Caret at the end of a long text: the tail scrolls into view.
    c = draw(ui, r, "0123456789", 10, .{ .style = style });
    try f.expectRow(0, "3456789");
    try testing.expectEqual(Caret{ .x = 7, .y = 0 }, c.?);
    // Caret in the middle: no scroll needed.
    c = draw(ui, r, "0123456789", 3, .{ .style = style });
    try f.expectRow(0, "01234567");
    try testing.expectEqual(Caret{ .x = 3, .y = 0 }, c.?);
    // Wide glyphs count two cells; secret paints bullets.
    c = draw(ui, r, "漢字a", 6, .{ .style = style });
    try f.expectRow(0, "漢字a");
    try testing.expectEqual(Caret{ .x = 4, .y = 0 }, c.?);
    _ = draw(ui, r, "hunter2", 7, .{ .style = style, .secret = true });
    try f.expectRow(0, "•••••••");
    try testing.expect(draw(ui, Rect.empty, "x", 0, .{ .style = style }) == null);
}
