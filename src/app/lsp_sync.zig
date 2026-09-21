//! What a frame's edits look like on the wire.
//!
//! A frame can leave more than one splice behind — three characters
//! typed between two paints are three of them — and a `didChange` that
//! carries a range has to describe the document the server holds, not
//! the one the editor holds. The splices are already exactly that: each
//! one is in the coordinates of the text as it was just before it, so
//! folding them together, oldest first, gives ONE region — `old_start`
//! to `old_end` in the text the server last saw, `old_start` to
//! `new_end` in the text as it is now — and the new text is that
//! region, read straight out of the buffer.
//!
//! Folding rather than sending one change per splice is what makes the
//! positions computable at all: a splice after the first is in an
//! intermediate text nobody kept, so its `character` (a UTF-16 count on
//! most servers) cannot be recovered, while the folded region's start
//! sits in the untouched prefix and its end is carried through the fold.
//!
//! Typing folds to a pure insertion (`old_start == old_end`), which is
//! exact under any position encoding. A deletion needs the old end's
//! column, which is a byte column: under `utf-8` it is the answer, and
//! under `utf-16` the change goes out anchored to line starts instead —
//! whole lines replaced by whole lines, where every `character` is 0 and
//! the encoding cannot be got wrong. `null` is the caller's signal to
//! send the whole text.

const std = @import("std");
const types = @import("../lsp/types.zig");
const document = @import("../editor/document.zig");
const Editor = @import("../editor/editor.zig").Editor;

pub const Splice = document.Splice;

/// A burst of splices as one replacement.
pub const Composed = struct {
    /// Byte offsets into the text the server last saw.
    old_start: usize,
    old_end: usize,
    /// Where the same region ends in the text as it is now; it starts
    /// at `old_start` there too, the prefix being untouched.
    new_end: usize,
    /// `old_end`'s row in the old text. Always known: rows past the
    /// region only shift, and by exactly `row_delta`.
    old_end_row: u32,
    /// `old_end`'s BYTE column in the old text, when the fold did not
    /// cross the line it sits on. Null when it did — the bytes that
    /// would have been counted are gone.
    old_end_col: ?u32,
    /// Rows the whole burst gained (positive) or lost.
    row_delta: isize,
};

/// Fold `splices` (oldest first, as `EditLog.since` returns them).
pub fn compose(splices: []const Splice) ?Composed {
    if (splices.len == 0) return null;
    const first = splices[0];
    var c: Composed = .{
        .old_start = first.start,
        .old_end = first.old_end,
        .new_end = first.new_end,
        .old_end_row = first.old_end_pt.row,
        .old_end_col = first.old_end_pt.col,
        .row_delta = first.rowDelta(),
    };
    for (splices[1..]) |s| {
        // Left of the region: untouched, so the splice's offset is the
        // old text's offset as it stands.
        if (s.start < c.old_start) c.old_start = s.start;
        // Right of it: the region has to grow to reach the splice, and
        // the gap it swallows is the same width in both texts.
        if (s.old_end > c.new_end) {
            c.old_end += s.old_end - c.new_end;
            // The splice's old end is in the part of the document this
            // burst has not reached, so its row is its row now less
            // every row the burst has gained or lost; its column
            // survives only when its line begins past the region.
            const line_start = s.old_end - s.old_end_pt.col;
            c.old_end_row = @intCast(@as(isize, @intCast(s.old_end_pt.row)) - c.row_delta);
            c.old_end_col = if (line_start >= c.new_end) s.old_end_pt.col else null;
            c.new_end = s.old_end;
        }
        // Everything at or past the splice's old end moves by what the
        // splice changed in length; the region's end is one of them.
        c.new_end = c.new_end - s.old_end + s.new_end;
        c.row_delta += s.rowDelta();
    }
    return c;
}

/// One `didChange` content change: a range plus the buffer bytes that
/// replace it.
pub const Change = struct {
    range: types.Range,
    /// The new text, as a byte range of the CURRENT buffer.
    text_start: usize,
    text_end: usize,
};

/// The change `c` goes out as, or null when the position encoding
/// cannot be honoured and the whole text has to go instead.
pub fn changeFor(ed: *const Editor, c: Composed, enc: types.Encoding) ?Change {
    const text = ed.bytes();
    const start = positionAt(ed, text, c.old_start, enc);
    // Typing, a paste, an auto-indent: nothing was removed, so there is
    // no old column to count and every encoding agrees.
    if (c.old_start == c.old_end) return .{
        .range = .{ .start = start, .end = start },
        .text_start = @min(c.old_start, text.len),
        .text_end = @min(c.new_end, text.len),
    };
    // A byte column IS the character count under utf-8.
    if (enc == .utf8) {
        if (c.old_end_col) |col| return .{
            .range = .{ .start = start, .end = .{ .line = c.old_end_row, .character = col } },
            .text_start = @min(c.old_start, text.len),
            .text_end = @min(c.new_end, text.len),
        };
    }
    // Otherwise: whole lines for whole lines. Both ends sit at column
    // 0, which reads the same in every encoding. It needs a line after
    // the last one the edit touched to anchor the end on.
    // LSP's line count, which — unlike the editor's — gives a text
    // ending in a newline one last, empty line.
    const cur_lines = ed.lineOfByte(text.len) + 1;
    const old_lines = @as(isize, @intCast(cur_lines)) - c.row_delta;
    if (@as(isize, c.old_end_row) + 1 >= old_lines) return null;
    const start_row = ed.lineOfByte(@min(c.old_start, text.len));
    const new_end_row = ed.lineOfByte(@min(c.new_end, text.len));
    if (new_end_row + 1 >= cur_lines) return null;
    return .{
        .range = .{
            .start = .{ .line = @intCast(start_row), .character = 0 },
            .end = .{ .line = c.old_end_row + 1, .character = 0 },
        },
        .text_start = ed.lineStart(start_row),
        .text_end = ed.lineStart(new_end_row + 1),
    };
}

/// A byte offset's LSP position, off the document's line index rather
/// than a scan from the top — on a 100 MB file the scan was the sync.
fn positionAt(ed: *const Editor, text: []const u8, byte_in: usize, enc: types.Encoding) types.Position {
    const byte = @min(byte_in, text.len);
    const row = ed.lineOfByte(byte);
    const line_start = ed.lineStart(row);
    return .{ .line = @intCast(row), .character = types.units(text[line_start..byte], enc) };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The splices `text` collects as `edits` are applied to it, and the
/// text they leave behind — the editor's own recording, so the test
/// reads the same records `syncPane` does.
const Edit = struct { start: usize, del: usize, ins: []const u8 };

fn recorded(gpa: std.mem.Allocator, start_text: []const u8, edits: []const Edit) !struct { ed: *Editor, seen: u64 } {
    const ed = try Editor.init(gpa, start_text);
    errdefer ed.deinit();
    const seen = ed.doc.edits.head();
    for (edits) |e| try ed.splice(e.start, e.start + e.del, e.ins);
    return .{ .ed = ed, .seen = seen };
}

/// What the server would hold after applying `ch` to `before`.
fn applied(gpa: std.mem.Allocator, before: []const u8, ch: Change, now: []const u8, enc: types.Encoding) ![]u8 {
    const s = types.byteOf(before, ch.range.start, enc);
    const e = types.byteOf(before, ch.range.end, enc);
    return std.mem.concat(gpa, u8, &.{ before[0..s], now[ch.text_start..ch.text_end], before[e..] });
}

/// Fold the edits, build the change, apply it to the old text: the
/// server's copy has to come out byte-for-byte the editor's.
fn roundTrip(start_text: []const u8, edits: []const Edit, enc: types.Encoding) !void {
    const gpa = testing.allocator;
    var r = try recorded(gpa, start_text, edits);
    defer r.ed.deinit();
    const c = compose(r.ed.doc.edits.since(r.seen)).?;
    const ch = changeFor(r.ed, c, enc) orelse return error.WholeTextInstead;
    const out = try applied(gpa, start_text, ch, r.ed.bytes(), enc);
    defer gpa.free(out);
    try testing.expectEqualStrings(r.ed.bytes(), out);
}

test "three characters typed in one frame fold to one insertion, not the whole text" {
    const gpa = testing.allocator;
    var r = try recorded(gpa, "fn main() {}\n", &.{
        .{ .start = 3, .del = 0, .ins = "a" },
        .{ .start = 4, .del = 0, .ins = "b" },
        .{ .start = 5, .del = 0, .ins = "c" },
    });
    defer r.ed.deinit();
    const c = compose(r.ed.doc.edits.since(r.seen)).?;
    try testing.expectEqual(@as(usize, 3), c.old_start);
    try testing.expectEqual(@as(usize, 3), c.old_end); // a pure insertion
    try testing.expectEqual(@as(usize, 6), c.new_end);
    const ch = changeFor(r.ed, c, .utf16).?;
    try testing.expectEqual(types.Position{ .line = 0, .character = 3 }, ch.range.start);
    try testing.expectEqual(types.Position{ .line = 0, .character = 3 }, ch.range.end);
    try testing.expectEqualStrings("abc", r.ed.bytes()[ch.text_start..ch.text_end]);
}

test "a fold's payload is the region, never the file" {
    const gpa = testing.allocator;
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(gpa);
    while (big.items.len < 200_000) try big.appendSlice(gpa, "let x = 1;\n");
    var r = try recorded(gpa, big.items, &.{
        .{ .start = 4, .del = 1, .ins = "y" },
        .{ .start = 5, .del = 0, .ins = "z" },
    });
    defer r.ed.deinit();
    const c = compose(r.ed.doc.edits.since(r.seen)).?;
    const ch = changeFor(r.ed, c, .utf8).?;
    try testing.expect(ch.text_end - ch.text_start < 64);
}

test "typing on a line of astral characters counts utf-16 units, not bytes" {
    const gpa = testing.allocator;
    // "𝄞" is four bytes and two utf-16 units; "é" is two bytes and one.
    var r = try recorded(gpa, "let s = \"𝄞é\";\n", &.{
        .{ .start = 15, .del = 0, .ins = "!" },
        .{ .start = 16, .del = 0, .ins = "?" },
    });
    defer r.ed.deinit();
    const c = compose(r.ed.doc.edits.since(r.seen)).?;
    const ch = changeFor(r.ed, c, .utf16).?;
    // `let s = "` is 9, the clef 2, the e-acute 1 → 12.
    try testing.expectEqual(@as(u32, 12), ch.range.start.character);
    try testing.expectEqual(@as(u32, 12), ch.range.end.character);
    const u8ch = changeFor(r.ed, c, .utf8).?;
    try testing.expectEqual(@as(u32, 15), u8ch.range.start.character);
    try roundTrip("let s = \"𝄞é\";\n", &.{
        .{ .start = 15, .del = 0, .ins = "!" },
        .{ .start = 16, .del = 0, .ins = "?" },
    }, .utf16);
}

test "a delete on a non-ascii line goes out anchored to line starts under utf-16" {
    const gpa = testing.allocator;
    const src = "let a = 1;\nlet s = \"é𝄞\";\nlet b = 2;\n";
    var r = try recorded(gpa, src, &.{
        .{ .start = 15, .del = 2, .ins = "" },
        .{ .start = 15, .del = 0, .ins = "xy" },
    });
    defer r.ed.deinit();
    const c = compose(r.ed.doc.edits.since(r.seen)).?;
    const ch = changeFor(r.ed, c, .utf16).?;
    try testing.expectEqual(types.Position{ .line = 1, .character = 0 }, ch.range.start);
    try testing.expectEqual(types.Position{ .line = 2, .character = 0 }, ch.range.end);
    try roundTrip(src, &.{
        .{ .start = 15, .del = 2, .ins = "" },
        .{ .start = 15, .del = 0, .ins = "xy" },
    }, .utf16);
}

test "every shape of burst round-trips into the server's copy" {
    const src = "alpha one\nbeta two\ngamma three\ndelta four\nepsilon five\n";
    const cases = [_][]const Edit{
        // one insertion
        &.{.{ .start = 5, .del = 0, .ins = "XY" }},
        // one deletion
        &.{.{ .start = 5, .del = 3, .ins = "" }},
        // one replacement
        &.{.{ .start = 5, .del = 3, .ins = "Q" }},
        // backspaces, right to left
        &.{ .{ .start = 8, .del = 1, .ins = "" }, .{ .start = 7, .del = 1, .ins = "" }, .{ .start = 6, .del = 1, .ins = "" } },
        // two edits far apart, the later one first
        &.{ .{ .start = 2, .del = 1, .ins = "ZZ" }, .{ .start = 40, .del = 4, .ins = "k" } },
        // two edits far apart, the earlier one first
        &.{ .{ .start = 40, .del = 4, .ins = "k" }, .{ .start = 2, .del = 1, .ins = "ZZ" } },
        // an edit that spans lines, then one inside what it left
        &.{ .{ .start = 6, .del = 15, .ins = "mid\n" }, .{ .start = 8, .del = 0, .ins = "!" } },
        // a newline typed, then text on the new line
        &.{ .{ .start = 9, .del = 0, .ins = "\n" }, .{ .start = 10, .del = 0, .ins = "new" } },
        // a line joined away, then a word replaced past it
        &.{ .{ .start = 9, .del = 1, .ins = "" }, .{ .start = 25, .del = 5, .ins = "G" } },
        // a deletion reaching past an earlier insertion
        &.{ .{ .start = 10, .del = 0, .ins = "abc" }, .{ .start = 8, .del = 12, .ins = "" } },
        // everything but the last line
        &.{.{ .start = 0, .del = 41, .ins = "one\n" }},
    };
    for (cases, 0..) |edits, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        try roundTrip(src, edits, .utf8);
        try roundTrip(src, edits, .utf16);
    }
}

test "an edit on the document's last line has no line after it to anchor on" {
    const gpa = testing.allocator;
    const src = "one\ntwo\nthree";
    var r = try recorded(gpa, src, &.{.{ .start = 9, .del = 2, .ins = "" }});
    defer r.ed.deinit();
    const c = compose(r.ed.doc.edits.since(r.seen)).?;
    // utf-8 reads the byte column straight off the record.
    try testing.expect(changeFor(r.ed, c, .utf8) != null);
    try roundTrip(src, &.{.{ .start = 9, .del = 2, .ins = "" }}, .utf8);
    // utf-16 has neither a column it can trust nor a line to anchor on:
    // the caller sends the whole text.
    try testing.expect(changeFor(r.ed, c, .utf16) == null);
}

test "an empty burst composes to nothing" {
    try testing.expect(compose(&.{}) == null);
}
