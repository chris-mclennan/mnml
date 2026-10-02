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
const utf8 = @import("../core/utf8.zig");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const key_mod = @import("../core/key.zig");
const hit = @import("hit.zig");

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

/// A field's live text, caret and selection anchor, as its owner keeps
/// them — what a press edits (`dispatch.fieldRef`). A field with a
/// whole-text selection flag of its own (the prompt's seeded name, the
/// find bar's second Ctrl+F) hands that over too, so a press clears it.
/// Built at the press and used at once: never stored.
pub const Ref = struct {
    buf: *Buf,
    caret: *usize,
    anchor: *?usize,
    select_all: ?*bool = null,
};

// ── selection and the pointer ──
//
// A field's selection is a byte `anchor` beside its caret: the range
// between them, either way round. The owner keeps it (`?usize`, null
// for none) next to the buffer and the caret, hands it to `editKey` /
// `insertSel` so typing replaces it, and to `draw` so it is painted.
// A click lands through `byteAtCol` and `clickSelect`: one press puts
// the caret there, a double the word under it, a triple the line —
// and a field is one line, so the whole text.

/// The selection's byte range, low first; null when there is none.
pub fn selRange(caret: usize, anchor: ?usize) ?[2]usize {
    const a = anchor orelse return null;
    if (a == caret) return null;
    return .{ @min(a, caret), @max(a, caret) };
}

/// `handleKey` over a selection: a typed character, a paste or an
/// erase replaces the selected text; any other key drops the selection
/// and edits as usual.
pub fn editKey(buf: *Buf, caret: *usize, anchor: *?usize, gpa: Allocator, key: Key) Allocator.Error!Edit {
    // Shift with a motion grows the selection from where it started.
    if (key.mods.shift and !key.mods.super) switch (key.code) {
        .left, .right, .home, .end => {
            const from = caret.*;
            const e = try handleKey(buf, caret, gpa, key);
            if (anchor.* == null) anchor.* = from;
            if (anchor.* == caret.*) anchor.* = null;
            return e;
        },
        else => {},
    };
    if (selRange(caret.*, anchor.*)) |r| {
        const typed = if (key.typed()) |cp| cp >= 0x20 and cp != 0x7f and !key.mods.ctrl and !key.mods.alt else false;
        const erase = (key.code == .backspace or key.code == .delete) and !key.mods.ctrl and !key.mods.alt;
        if (typed or erase) {
            anchor.* = null;
            _ = deleteRange(buf, caret, @min(r[0], buf.items.len), @min(r[1], buf.items.len));
            if (erase) return .changed;
            _ = try handleKey(buf, caret, gpa, key);
            return .changed;
        }
    }
    const e = try handleKey(buf, caret, gpa, key);
    if (e != .ignored) anchor.* = null;
    return e;
}

/// `insert` over a selection: the paste replaces it.
pub fn insertSel(buf: *Buf, caret: *usize, anchor: *?usize, gpa: Allocator, text: []const u8) Allocator.Error!void {
    if (selRange(caret.*, anchor.*)) |r| _ = deleteRange(buf, caret, @min(r[0], buf.items.len), @min(r[1], buf.items.len));
    anchor.* = null;
    try insert(buf, caret, gpa, text);
}

const Class = enum { word, space, punct };

fn classOf(c: u8) Class {
    if (c == ' ' or c == '\t') return .space;
    if (std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80) return .word;
    return .punct;
}

/// The run of one class around `at` — letters, digits and `_` (and any
/// non-ASCII byte) are a word, blanks a run of blanks, the rest a run
/// of punctuation — the editor's double-click word.
pub fn wordBoundsAt(text: []const u8, at_in: usize) [2]usize {
    if (text.len == 0) return .{ 0, 0 };
    const at = @min(at_in, text.len - 1);
    const k = classOf(text[at]);
    var lo = at;
    while (lo > 0 and classOf(text[lo - 1]) == k) lo -= 1;
    var hi = at + 1;
    while (hi < text.len and classOf(text[hi]) == k) hi += 1;
    while (lo > 0 and (text[lo] & 0xC0) == 0x80) lo -= 1;
    while (hi < text.len and (text[hi] & 0xC0) == 0x80) hi += 1;
    return .{ lo, hi };
}

/// A shift-press at `byte`: the selection runs from where it started
/// (the caret, when there was none) to the press.
pub fn extendTo(text: []const u8, caret: *usize, anchor: *?usize, byte: usize) void {
    const b = @min(byte, text.len);
    if (anchor.* == null) anchor.* = caret.*;
    caret.* = b;
    if (anchor.* == b) anchor.* = null;
}

/// A press `clicks` deep (1, 2, 3 — `dispatch.clickCount`) at byte
/// `byte`: the caret there; the word; the whole line.
pub fn clickSelect(text: []const u8, caret: *usize, anchor: *?usize, byte: usize, clicks: u8) void {
    const b = @min(byte, text.len);
    switch (clicks) {
        0, 1 => {
            caret.* = b;
            anchor.* = null;
        },
        2 => {
            const w = wordBoundsAt(text, b);
            anchor.* = w[0];
            caret.* = w[1];
        },
        else => {
            anchor.* = 0;
            caret.* = text.len;
        },
    }
}

/// The byte a click `col` cells into a field `w` wide lands on, with
/// the text scrolled as `draw` scrolls it for `caret` — the grapheme
/// under the cell, the text's end past it.
pub fn byteAtCol(text: []const u8, caret: usize, w: u16, col: u16, method: vaxis.gwidth.Method) usize {
    if (text.len == 0 or w == 0) return 0;
    const c = @min(caret, text.len);
    var caret_col: u32 = 0;
    var it = utf8.graphemeIterator(text);
    while (it.next()) |g| {
        if (g.start >= c) break;
        caret_col += @min(cellW(g.bytes(text), method), 2);
    }
    // The same first painted cell as `draw`.
    var skipped: u32 = 0;
    var it2 = utf8.graphemeIterator(text);
    while (caret_col - skipped >= w) {
        const g = it2.next() orelse break;
        skipped += @min(cellW(g.bytes(text), method), 2);
    }
    var x: u32 = 0;
    while (it2.next()) |g| {
        const gw = @min(cellW(g.bytes(text), method), 2);
        if (gw == 0) continue;
        if (col < x + gw) return g.start;
        x += gw;
    }
    return text.len;
}

fn cellW(g: []const u8, method: vaxis.gwidth.Method) u16 {
    if (g.len == 1 and g[0] >= 0x20 and g[0] < 0x7f) return 1;
    return utf8.width(g, method);
}

/// The selection on a chip-grey field (a filter pill, the find bar):
/// the theme's selection ground — and its match grey — are a step off
/// that grey and all but vanish on it (measured on the real window), so
/// these take the accent as the ground under the editor's own ink.
pub fn chipSelStyle(ui: Ui) Style {
    return .{ .fg = ui.theme.bg.bg, .bg = ui.theme.accent.fg };
}

pub const DrawOptions = struct {
    style: Style,
    placeholder: ?[]const u8 = null,
    placeholder_style: ?Style = null,
    /// Paint one bullet per code point instead of the text.
    secret: bool = false,
    /// Show the caret (return its cell). An unfocused field returns null.
    focused: bool = true,
    /// The selection's anchor (`selRange`): the range between it and
    /// the caret paints in `sel_style`, the theme's selection by default.
    anchor: ?usize = null,
    sel_style: ?Style = null,
    /// What a press on the text edits (`hit.FieldId`): registered with
    /// the rect, so a click, a double and a triple land through the
    /// same layout this paint used (`HitMap.fieldAt`, `byteAtCol`).
    field: ?hit.FieldId = null,
};

/// Paints `text` into `r` (one row) so the caret is inside it, scrolling
/// the text left when needed. Returns the caret's cell when focused.
pub fn draw(ui: Ui, r: Rect, text: []const u8, caret: usize, opts: DrawOptions) ?Caret {
    if (r.isEmpty()) return null;
    if (opts.field) |id| ui.hits.addField(ui.arena, r, id) catch {};
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
    var it = utf8.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        const cw: u16 = if (opts.secret) 1 else ui.canvas.cellWidth(bytes);
        if (cw == 0) continue;
        cells.append(ui.arena, .{ .start = g.start, .end = g.start + g.len, .w = @min(cw, 2) }) catch return null;
    }
    const c = @min(caret, text.len);
    // An anchor past the text is left over from text replaced under it.
    const sel = if (opts.anchor) |a| (if (a <= text.len) selRange(c, a) else null) else null;
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
        const in_sel = if (sel) |rg| cell.start >= rg[0] and cell.start < rg[1] else false;
        const st = if (in_sel) (opts.sel_style orelse Theme.onBg(ui.theme.fg, ui.theme.selection.bg)) else opts.style;
        ui.canvas.put(x, r.y, .{ .char = .{ .grapheme = g, .width = @intCast(cell.w) }, .style = st });
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

test "a double-click takes the word under it — letters and digits and _, a blank run, a punctuation run — a triple the line; a single press drops the selection" {
    const s = "git log --oneline foo_bar2";
    try testing.expectEqual([2]usize{ 0, 3 }, wordBoundsAt(s, 1));
    try testing.expectEqual([2]usize{ 18, 26 }, wordBoundsAt(s, 22));
    try testing.expectEqual([2]usize{ 8, 10 }, wordBoundsAt(s, 9));
    try testing.expectEqual([2]usize{ 3, 4 }, wordBoundsAt(s, 3));
    try testing.expectEqual([2]usize{ 18, 26 }, wordBoundsAt(s, 99));
    // A word with a non-ASCII letter is one word, cut on code points.
    try testing.expectEqual([2]usize{ 0, 6 }, wordBoundsAt("caf\u{e9}s x", 2));
    var caret: usize = 0;
    var anchor: ?usize = null;
    clickSelect(s, &caret, &anchor, 5, 2);
    try testing.expectEqual([2]usize{ 4, 7 }, selRange(caret, anchor).?);
    clickSelect(s, &caret, &anchor, 5, 3);
    try testing.expectEqual([2]usize{ 0, s.len }, selRange(caret, anchor).?);
    clickSelect(s, &caret, &anchor, 5, 1);
    try testing.expect(selRange(caret, anchor) == null);
    try testing.expectEqual(@as(usize, 5), caret);
}

test "over a selection a typed character or a paste replaces it, an erase deletes it, an arrow drops it" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("hello brave world");
    var anchor: ?usize = null;
    clickSelect(f.text(), &f.caret, &anchor, 7, 2);
    try testing.expectEqual(Edit.changed, try editKey(&f.buf, &f.caret, &anchor, testing.allocator, Key.char('X')));
    try testing.expectEqualStrings("hello X world", f.text());
    try testing.expect(anchor == null);
    clickSelect(f.text(), &f.caret, &anchor, 9, 2);
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, Key.named(.backspace));
    try testing.expectEqualStrings("hello X ", f.text());
    clickSelect(f.text(), &f.caret, &anchor, 0, 3);
    try insertSel(&f.buf, &f.caret, &anchor, testing.allocator, "pasted");
    try testing.expectEqualStrings("pasted", f.text());
    clickSelect(f.text(), &f.caret, &anchor, 0, 2);
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, Key.named(.left));
    try testing.expect(anchor == null);
    try testing.expectEqualStrings("pasted", f.text());
}

test "byteAtCol reads the same scrolled layout draw paints; the selection paints in the theme's selection" {
    // Unscrolled: column = byte for ASCII, past the end = the end.
    try testing.expectEqual(@as(usize, 3), byteAtCol("abcdef", 0, 10, 3, .unicode));
    try testing.expectEqual(@as(usize, 6), byteAtCol("abcdef", 0, 10, 9, .unicode));
    // The caret at the end of a long line scrolls it: the field is
    // 5 wide, so the first painted byte is 6 of "abcdefghij".
    try testing.expectEqual(@as(usize, 6), byteAtCol("abcdefghij", 10, 5, 0, .unicode));
    var f = try Fixture.init(12, 1);
    defer f.deinit();
    const ui = f.ui();
    _ = draw(ui, f.full(), "one two", 7, .{ .style = f.theme.fg, .anchor = 4 });
    try f.expectRow(0, "one two");
    try testing.expect(f.bgEql(5, 0, f.theme.selection));
    try testing.expect(!f.bgEql(2, 0, f.theme.selection));
}

test "shift with an arrow, Home or End grows a selection from the caret; a plain arrow drops it; a shift-press extends to the press" {
    var f: Field = .{};
    defer f.deinit();
    try f.type_("one two");
    var anchor: ?usize = null;
    const shift_left: Key = .{ .code = .left, .mods = .{ .shift = true } };
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, shift_left);
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, shift_left);
    try testing.expectEqual([2]usize{ 5, 7 }, selRange(f.caret, anchor).?);
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, .{ .code = .home, .mods = .{ .shift = true } });
    try testing.expectEqual([2]usize{ 0, 7 }, selRange(f.caret, anchor).?);
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, Key.char('x'));
    try testing.expectEqualStrings("x", f.text());
    try testing.expect(anchor == null);
    // Back to where it started: no selection left.
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, shift_left);
    _ = try editKey(&f.buf, &f.caret, &anchor, testing.allocator, .{ .code = .right, .mods = .{ .shift = true } });
    try testing.expect(anchor == null);
    // A shift-press.
    f.caret = 1;
    extendTo(f.text(), &f.caret, &anchor, 0);
    try testing.expectEqual([2]usize{ 0, 1 }, selRange(f.caret, anchor).?);
}

test "a field with an id registers its rect for the pointer; one without does not" {
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    const ui = f.ui();
    _ = draw(ui, Rect.init(2, 0, 8, 1), "abc", 3, .{ .style = f.theme.fg, .field = .find_query });
    _ = draw(ui, Rect.init(2, 1, 8, 1), "abc", 3, .{ .style = f.theme.fg });
    try testing.expectEqual(hit.FieldId.find_query, f.hits.fieldAt(4, 0).?.id);
    try testing.expect(f.hits.fieldAt(1, 0) == null);
    try testing.expect(f.hits.fieldAt(4, 1) == null);
}
