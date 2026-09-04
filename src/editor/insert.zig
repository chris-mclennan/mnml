//! Insertions and the Replace-mode overwrite family.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const charLen = editor.charLen;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const delete = @import("delete.zig");

pub fn autoPairClose(c: u21) ?u21 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        '`' => '`',
        else => null,
    };
}

fn isAutoPairClose(c: u21) bool {
    return switch (c) {
        ')', ']', '}', '"', '\'', '`' => true,
        else => false,
    };
}

/// A pair is only auto-closed when the next char is EOL, whitespace, or
/// another closer — never in the middle of a word.
fn nextCharAllowsPair(ed: *const Editor) bool {
    const c = ed.charAt(ed.cursor) orelse return true;
    return editor.isSpace(c) or switch (c) {
        ')', ']', '}', '>', ',', ';', ':' => true,
        else => false,
    };
}

fn encode(c: u21, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(c, buf) catch {
        buf[0] = '?';
        return buf[0..1];
    };
    return buf[0..n];
}

pub fn insertChar(ed: *Editor, c: u21, out: *EditOutcome) editor.Error!void {
    // A deleted selection already pushed a checkpoint; ride it so the
    // delete + this char undo together (VS Code coalesces).
    if (try delete.deleteSelectionIfAny(ed, out)) {
        ed.history.clearRedo();
        ed.in_insert_run = true;
    } else {
        try ed.checkpointInsertRun();
    }
    if (ed.extra_cursors.items.len != 0) return error.Unsupported; // TODO(vim-slice: multicursor) fan-out insert
    var buf: [4]u8 = undefined;
    const s = encode(c, &buf);
    if (ed.auto_pair) {
        if (autoPairClose(c)) |closer| {
            if (nextCharAllowsPair(ed)) {
                var cbuf: [4]u8 = undefined;
                const cs = encode(closer, &cbuf);
                try ed.splice(ed.cursor, ed.cursor, s);
                ed.cursor += s.len;
                try ed.splice(ed.cursor, ed.cursor, cs);
                out.buffer_changed = true;
                return;
            }
        }
        if (isAutoPairClose(c) and ed.charAt(ed.cursor) == c) {
            ed.cursor += s.len;
            return;
        }
    }
    try ed.splice(ed.cursor, ed.cursor, s);
    ed.cursor += s.len;
    out.buffer_changed = true;
}

pub fn insertStr(ed: *Editor, s: []const u8, out: *EditOutcome) Allocator.Error!void {
    if (s.len == 0) return;
    if (try delete.deleteSelectionIfAny(ed, out)) {
        ed.history.clearRedo();
    } else {
        try ed.checkpoint();
    }
    try ed.splice(ed.cursor, ed.cursor, s);
    ed.cursor += s.len;
    out.buffer_changed = true;
}

/// Enter. With `auto_indent`, carries the indent that precedes the cursor.
pub fn insertNewline(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try delete.deleteSelectionIfAny(ed, out)) {
        ed.history.clearRedo();
    } else {
        try ed.checkpoint();
    }
    const indent_src = if (ed.auto_indent) ed.leadingIndent(ed.currentLine(), ed.cursor) else "";
    // The indent slice points into `text`; copy before splicing.
    var ibuf: [256]u8 = undefined;
    const indent = ibuf[0..@min(indent_src.len, ibuf.len)];
    @memcpy(indent, indent_src[0..indent.len]);
    try ed.splice(ed.cursor, ed.cursor, "\n");
    ed.cursor += 1;
    if (indent.len > 0) {
        try ed.splice(ed.cursor, ed.cursor, indent);
        ed.cursor += indent.len;
    }
    out.buffer_changed = true;
}

/// vim `o`.
pub fn insertNewlineBelow(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    ed.anchor = null;
    try ed.checkpoint();
    const line = ed.currentLine();
    const eol = ed.lineEnd(line);
    const indent_src = if (ed.auto_indent) ed.leadingIndent(line, null) else "";
    var ibuf: [256]u8 = undefined;
    const indent = ibuf[0..@min(indent_src.len, ibuf.len)];
    @memcpy(indent, indent_src[0..indent.len]);
    try ed.splice(eol, eol, "\n");
    ed.cursor = eol + 1;
    if (indent.len > 0) {
        try ed.splice(ed.cursor, ed.cursor, indent);
        ed.cursor += indent.len;
    }
    out.buffer_changed = true;
}

/// vim `O`.
pub fn insertNewlineAbove(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    ed.anchor = null;
    try ed.checkpoint();
    const line = ed.currentLine();
    const bol = ed.lineStart(line);
    const indent_src = if (ed.auto_indent) ed.leadingIndent(line, null) else "";
    var ibuf: [256]u8 = undefined;
    const indent = ibuf[0..@min(indent_src.len, ibuf.len)];
    @memcpy(indent, indent_src[0..indent.len]);
    try ed.splice(bol, bol, "\n");
    ed.cursor = bol;
    if (indent.len > 0) {
        try ed.splice(bol, bol, indent);
        ed.cursor = bol + indent.len;
    }
    out.buffer_changed = true;
}

/// Insert `Ctrl+Y` / `Ctrl+E`: copy the char at this column from the
/// line above / below.
pub fn insertCharFromLine(ed: *Editor, above: bool, out: *EditOutcome) Allocator.Error!void {
    const pos = ed.rowCol();
    const target = if (above) blk: {
        if (pos.row == 0) return;
        break :blk pos.row - 1;
    } else blk: {
        if (pos.row + 1 >= ed.lineCount()) return;
        break :blk pos.row + 1;
    };
    const b = ed.byteAtCol(target, pos.col);
    if (b >= ed.lineEnd(target)) return;
    const c = ed.charAt(b) orelse return;
    try ed.checkpoint();
    var buf: [4]u8 = undefined;
    const s = encode(c, &buf);
    try ed.splice(ed.cursor, ed.cursor, s);
    ed.cursor += s.len;
    out.buffer_changed = true;
}

// ─── Replace mode (`R`) ─────────────────────────────────────────────────

pub fn replaceSessionBegin(ed: *Editor) void {
    ed.replace_stack.clearRetainingCapacity();
}

/// Overwrite the char under the cursor (or append past EOL) and advance.
pub fn overwriteCharAndAdvance(ed: *Editor, c: u21, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    var buf: [4]u8 = undefined;
    const s = encode(c, &buf);
    const cur = ed.cursor;
    const under = ed.charAt(cur);
    if (under != null and under.? != '\n') {
        const end = ed.nextBoundary(cur);
        try ed.replace_stack.append(ed.gpa, under.?);
        try ed.splice(cur, end, s);
    } else {
        try ed.replace_stack.append(ed.gpa, null);
        try ed.splice(cur, cur, s);
    }
    ed.cursor = cur + s.len;
    out.buffer_changed = true;
}

/// Backspace in Replace mode: restore the overwritten char.
pub fn replaceUndoOne(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const entry = ed.replace_stack.pop() orelse return;
    if (ed.cursor == 0) return;
    try ed.checkpoint();
    const prev = ed.prevBoundary(ed.cursor);
    if (entry) |orig| {
        var buf: [4]u8 = undefined;
        const s = encode(orig, &buf);
        try ed.splice(prev, ed.cursor, s);
    } else {
        try ed.splice(prev, ed.cursor, "");
    }
    ed.cursor = prev;
    out.buffer_changed = true;
}

pub fn appendChar(buf: *std.ArrayList(u8), gpa: Allocator, c: u21) Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    try buf.appendSlice(gpa, encode(c, &tmp));
}

// ─── tests ──────────────────────────────────────────────────────────────

test "insert char/str/newline with auto-indent, coalesced undo run" {
    var ed = try Editor.init(std.testing.allocator, "  ab");
    defer ed.deinit();
    ed.auto_indent = true;
    ed.cursor = 4;
    var out: EditOutcome = .{};
    try insertChar(&ed, 'c', &out);
    try insertChar(&ed, 'é', &out);
    try std.testing.expectEqualStrings("  abcé", ed.text.items);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    try std.testing.expectEqual(@as(usize, 1), ed.history.undoLen()); // one coalesced run
    try insertNewline(&ed, &out);
    try std.testing.expectEqualStrings("  abcé\n  ", ed.text.items);
    try insertStr(&ed, "zz", &out);
    try std.testing.expectEqualStrings("  abcé\n  zz", ed.text.items);
    try std.testing.expect(out.buffer_changed);
}

test "o and O open lines with the line's indent" {
    var ed = try Editor.init(std.testing.allocator, "\tfoo\nbar");
    defer ed.deinit();
    ed.auto_indent = true;
    ed.cursor = 2;
    var out: EditOutcome = .{};
    try insertNewlineBelow(&ed, &out);
    try std.testing.expectEqualStrings("\tfoo\n\t\nbar", ed.text.items);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    ed.cursor = 0;
    try insertNewlineAbove(&ed, &out);
    try std.testing.expectEqualStrings("\t\n\tfoo\n\t\nbar", ed.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}

test "auto-pair inserts a closer and skips over a typed closer" {
    var ed = try Editor.init(std.testing.allocator, "");
    defer ed.deinit();
    ed.auto_pair = true;
    var out: EditOutcome = .{};
    try insertChar(&ed, '(', &out);
    try std.testing.expectEqualStrings("()", ed.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    try insertChar(&ed, ')', &out);
    try std.testing.expectEqualStrings("()", ed.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "replace mode overwrites, appends past EOL, and backspace restores" {
    var ed = try Editor.init(std.testing.allocator, "ab\n");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    replaceSessionBegin(&ed);
    try overwriteCharAndAdvance(&ed, 'X', &out);
    try overwriteCharAndAdvance(&ed, 'Y', &out);
    try std.testing.expectEqualStrings("aXY\n", ed.text.items);
    try replaceUndoOne(&ed, &out);
    try replaceUndoOne(&ed, &out);
    try std.testing.expectEqualStrings("ab\n", ed.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}
