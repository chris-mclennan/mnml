//! Whole-line ops: join, indent, outdent, duplicate, move, case.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const edit_op = @import("edit_op.zig");
const EditOutcome = edit_op.EditOutcome;
const CaseTransform = edit_op.CaseTransform;

/// vim `J` (`keep_space`) / `gJ`.
pub fn joinLines(ed: *Editor, keep_space: bool, out: *EditOutcome) Allocator.Error!void {
    const line = ed.currentLine();
    if (line + 1 >= ed.lineCount()) return;
    try ed.checkpoint();
    const t = ed.bytes();
    const bol = ed.lineStart(line);
    const eol = ed.lineEnd(line);
    var trim_end = eol;
    if (keep_space) {
        while (trim_end > bol and (t[trim_end - 1] == ' ' or t[trim_end - 1] == '\t')) trim_end -= 1;
    }
    const next_bol = eol + 1;
    const next_eol = ed.lineEnd(line + 1);
    var next_first = next_bol;
    if (keep_space) {
        while (next_first < next_eol and (t[next_first] == ' ' or t[next_first] == '\t')) next_first += 1;
    }
    const sep: []const u8 = if (!keep_space or trim_end == bol) "" else " ";
    try ed.splice(trim_end, next_first, sep);
    ed.cursor = trim_end;
    ed.anchor = null;
    out.buffer_changed = true;
}

/// The lines a selection (or the cursor) touches, first..last inclusive.
/// A selection ending exactly at a line start does not include that line.
pub fn selectedLineRange(ed: *const Editor) [2]usize {
    if (ed.selection()) |s| {
        const fl = ed.lineOfByte(s[0]);
        const hl = ed.lineOfByte(s[1]);
        const ll = if (s[1] > s[0] and s[1] == ed.lineStart(hl) and hl > fl) hl - 1 else hl;
        return .{ fl, ll };
    }
    const l = ed.currentLine();
    return .{ l, l };
}

fn restoreCursorAfterLineOp(ed: *Editor, pos: editor.Pos) void {
    ed.cursor = ed.byteAtCol(@min(pos.row, ed.lineCount() - 1), pos.col);
    ed.anchor = null;
}

pub fn indent(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const pos = ed.rowCol();
    const range = selectedLineRange(ed);
    var pad_buf: [64]u8 = undefined;
    const pad = pad_buf[0..@min(ed.tab_width, pad_buf.len)];
    @memset(pad, ' ');
    var line = range[0];
    while (line <= range[1]) : (line += 1) {
        const bol = ed.lineStart(line);
        try ed.splice(bol, bol, pad);
    }
    // The cursor keeps its (row, col) — Rust mnml parity; vim would go
    // to the first non-blank.
    restoreCursorAfterLineOp(ed, pos);
    out.buffer_changed = true;
}

pub fn outdent(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const pos = ed.rowCol();
    const range = selectedLineRange(ed);
    var changed = false;
    var line = range[0];
    while (line <= range[1]) : (line += 1) {
        const bol = ed.lineStart(line);
        const eol = ed.lineEnd(line);
        var remove: usize = 0;
        var i = bol;
        while (i < eol and remove < ed.tab_width) : (i += 1) {
            if (ed.bytes()[i] == ' ') {
                remove += 1;
            } else if (ed.bytes()[i] == '\t') {
                remove += 1;
                break;
            } else break;
        }
        if (remove > 0) {
            try ed.splice(bol, bol + remove, "");
            changed = true;
        }
    }
    if (changed) {
        restoreCursorAfterLineOp(ed, pos);
        out.buffer_changed = true;
    } else {
        ed.popCheckpoint();
        ed.anchor = null;
    }
}

/// Copy the current line below itself; cursor moves to the copy.
pub fn duplicateLine(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const pos = ed.rowCol();
    const line = pos.row;
    const bol = ed.lineStart(line);
    const eol = ed.lineEnd(line);
    const copy = try std.mem.concat(ed.gpa, u8, &.{ "\n", ed.bytes()[bol..eol] });
    defer ed.gpa.free(copy);
    try ed.splice(eol, eol, copy);
    ed.cursor = ed.byteAtCol(line + 1, pos.col);
    ed.anchor = null;
    out.buffer_changed = true;
}

/// Swap the current line with its neighbour (`alt+↑` / `alt+↓`).
pub fn moveLine(ed: *Editor, dir: i2, out: *EditOutcome) Allocator.Error!void {
    const pos = ed.rowCol();
    const line = pos.row;
    const other = if (dir < 0) blk: {
        if (line == 0) return;
        break :blk line - 1;
    } else blk: {
        if (line + 1 >= ed.lineCount()) return;
        break :blk line + 1;
    };
    try ed.checkpoint();
    const a = @min(line, other);
    const b = @max(line, other);
    const a_s = ed.lineStart(a);
    const a_e = ed.lineEnd(a);
    const b_s = ed.lineStart(b);
    const b_e = ed.lineEnd(b);
    const joined = try std.mem.concat(ed.gpa, u8, &.{ ed.bytes()[b_s..b_e], "\n", ed.bytes()[a_s..a_e] });
    defer ed.gpa.free(joined);
    try ed.splice(a_s, b_e, joined);
    ed.cursor = ed.byteAtCol(other, pos.col);
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `gu` / `gU` / `g~` over the selection. ASCII-only case mapping; the
/// cursor parks at the range start.
pub fn transformSelectionCase(ed: *Editor, kind: CaseTransform, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const src = ed.bytes()[sel[0]..sel[1]];
    const buf = try ed.gpa.alloc(u8, src.len);
    defer ed.gpa.free(buf);
    var changed = false;
    for (src, buf) |c, *o| {
        o.* = switch (kind) {
            .lower => std.ascii.toLower(c),
            .upper => std.ascii.toUpper(c),
            .toggle => if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c),
        };
        if (o.* != c) changed = true;
    }
    if (changed) {
        try ed.checkpoint();
        try ed.splice(sel[0], sel[1], buf);
        out.buffer_changed = true;
    }
    ed.cursor = sel[0];
    ed.anchor = null;
}

/// vim `~`: toggle the ASCII letter under the cursor and advance.
pub fn toggleCaseChar(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (ed.cursor >= ed.len()) return;
    const b = ed.bytes()[ed.cursor];
    if (std.ascii.isAlphabetic(b)) {
        try ed.checkpoint();
        const t = [_]u8{if (std.ascii.isUpper(b)) std.ascii.toLower(b) else std.ascii.toUpper(b)};
        try ed.splice(ed.cursor, ed.cursor + 1, &t);
        out.buffer_changed = true;
    }
    ed.cursor = ed.nextBoundary(ed.cursor);
}

// ─── tests ──────────────────────────────────────────────────────────────

test "J trims and inserts one space; gJ keeps whitespace" {
    var ed = try Editor.init(std.testing.allocator, "ab  \n   cd\nef");
    defer ed.deinit();
    var out: EditOutcome = .{};
    try joinLines(&ed, true, &out);
    try std.testing.expectEqualStrings("ab cd\nef", ed.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    try joinLines(&ed, false, &out);
    try std.testing.expectEqualStrings("ab cdef", ed.text.items);
    try joinLines(&ed, true, &out); // last line: no-op
    try std.testing.expectEqualStrings("ab cdef", ed.text.items);
}

test "indent / outdent over a selection keep the cursor column" {
    var ed = try Editor.init(std.testing.allocator, "a\nb\nc");
    defer ed.deinit();
    ed.tab_width = 2;
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = 4; // start of line 2 → only lines 0-1
    try indent(&ed, &out);
    try std.testing.expectEqualStrings("  a\n  b\nc", ed.text.items);
    try std.testing.expect(ed.anchor == null);
    ed.cursor = 3;
    try outdent(&ed, &out);
    try std.testing.expectEqualStrings("a\n  b\nc", ed.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    ed.cursor = 0;
    try outdent(&ed, &out); // nothing to remove → no undo entry
    try std.testing.expectEqual(@as(usize, 2), ed.history.undoLen());
}

test "duplicate, move line, case ops" {
    var ed = try Editor.init(std.testing.allocator, "ab\ncd");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    try duplicateLine(&ed, &out);
    try std.testing.expectEqualStrings("ab\nab\ncd", ed.text.items);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    try moveLine(&ed, 1, &out);
    try std.testing.expectEqualStrings("ab\ncd\nab", ed.text.items);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    try moveLine(&ed, 1, &out);
    try std.testing.expectEqualStrings("ab\ncd\nab", ed.text.items);
    ed.anchor = 0;
    ed.cursor = 5;
    try transformSelectionCase(&ed, .upper, &out);
    try std.testing.expectEqualStrings("AB\nCD\nab", ed.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try toggleCaseChar(&ed, &out);
    try std.testing.expectEqualStrings("aB\nCD\nab", ed.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}
