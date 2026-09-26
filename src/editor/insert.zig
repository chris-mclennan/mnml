//! Insertions and the Replace-mode overwrite family.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const charLen = editor.charLen;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const delete = @import("delete.zig");
const mc = @import("multicursor.zig");

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

pub fn insertChar(ed: *Editor, c: u21, out: *EditOutcome) Allocator.Error!void {
    // A deleted selection already pushed a checkpoint; ride it so the
    // delete + this char — and the chars typed after it — undo together
    // (VS Code coalesces). The run is this view's: without the owner the
    // next char opened a group of its own and Ctrl+Z left the first one.
    if (try delete.deleteSelectionIfAny(ed, out)) {
        ed.doc.history.clearRedo();
        ed.in_insert_run = true;
        ed.doc.insert_run_owner = ed;
    } else {
        try ed.checkpointInsertRun();
    }
    var buf: [4]u8 = undefined;
    const s = encode(c, &buf);
    // smartindent: a `}` typed first on its line takes the indent of the
    // line that opened the block.
    if (ed.doc.auto_indent and c == '}' and !mc.hasExtras(ed)) try dedentClosingBrace(ed);
    if (mc.hasExtras(ed)) {
        // Every cursor types; auto-pair is skipped across N cursors.
        try mc.insertStrAll(ed, s);
        out.buffer_changed = true;
        return;
    }
    if (ed.doc.auto_pair) {
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
        ed.doc.history.clearRedo();
    } else {
        try ed.checkpoint();
    }
    if (mc.hasExtras(ed)) {
        try mc.insertStrAll(ed, s);
        out.buffer_changed = true;
        return;
    }
    try ed.splice(ed.cursor, ed.cursor, s);
    ed.cursor += s.len;
    out.buffer_changed = true;
}

/// The indent a line opened after `line` (cut at `limit`) gets under
/// `auto_indent`: the line's own leading blanks, one level deeper when
/// its last non-blank char is `{` (vim's `smartindent`). Copied into
/// `buf` — the source points into `text`, which is about to move.
fn newLineIndent(ed: *const Editor, line: usize, limit: ?usize, buf: *[256]u8) []const u8 {
    if (!ed.doc.auto_indent) return "";
    const src = ed.leadingIndent(line, limit);
    var n: usize = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    if (lastNonBlank(ed, line, limit) == '{') {
        const unit: []const u8 = if (ed.doc.use_tabs) "\t" else "        "[0..@min(ed.doc.tab_width, 8)];
        const room = @min(unit.len, buf.len - n);
        @memcpy(buf[n .. n + room], unit[0..room]);
        n += room;
    }
    return buf[0..n];
}

/// The last non-blank byte of `line` before `limit` (its end by default).
fn lastNonBlank(ed: *const Editor, line: usize, limit: ?usize) ?u8 {
    const start = ed.lineStart(line);
    var end = ed.lineEnd(line);
    if (limit) |l| end = @min(end, l);
    while (end > start) {
        end -= 1;
        const b = ed.doc.text.items[end];
        if (b != ' ' and b != '\t') return b;
    }
    return null;
}

/// smartindent's `}`: when the cursor's line holds only blanks so far,
/// re-indent it to the line of the `{` it closes.
fn dedentClosingBrace(ed: *Editor) Allocator.Error!void {
    const line = ed.currentLine();
    const bol = ed.lineStart(line);
    if (lastNonBlank(ed, line, ed.cursor) != null) return;
    // The unmatched `{` before the line.
    var depth: usize = 0;
    var i = bol;
    var open: ?usize = null;
    while (i > 0) {
        i -= 1;
        switch (ed.doc.text.items[i]) {
            '}' => depth += 1,
            '{' => if (depth == 0) {
                open = i;
                break;
            } else {
                depth -= 1;
            },
            else => {},
        }
    }
    const o = open orelse return;
    const want_src = ed.leadingIndent(ed.lineOfByte(o), null);
    var buf: [256]u8 = undefined;
    const want = buf[0..@min(want_src.len, buf.len)];
    @memcpy(want, want_src[0..want.len]);
    if (std.mem.eql(u8, want, ed.doc.text.items[bol..ed.cursor])) return;
    try ed.splice(bol, ed.cursor, want);
    ed.cursor = bol + want.len;
}

/// Enter. With `auto_indent`, carries the indent that precedes the
/// cursor, one level deeper after a `{`.
pub fn insertNewline(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try delete.deleteSelectionIfAny(ed, out)) {
        ed.doc.history.clearRedo();
    } else {
        try ed.checkpoint();
    }
    if (mc.hasExtras(ed)) {
        // Auto-indent is skipped: earlier inserts shift later lines.
        try mc.insertStrAll(ed, "\n");
        out.buffer_changed = true;
        return;
    }
    var ibuf: [256]u8 = undefined;
    const indent = newLineIndent(ed, ed.currentLine(), ed.cursor, &ibuf);
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
    var ibuf: [256]u8 = undefined;
    const indent = newLineIndent(ed, line, null, &ibuf);
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
    const indent_src = if (ed.doc.auto_indent) ed.leadingIndent(line, null) else "";
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
    const ed = try Editor.init(std.testing.allocator, "  ab");
    defer ed.deinit();
    ed.doc.auto_indent = true;
    ed.cursor = 4;
    var out: EditOutcome = .{};
    try insertChar(ed, 'c', &out);
    try insertChar(ed, 'é', &out);
    try std.testing.expectEqualStrings("  abcé", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    try std.testing.expectEqual(@as(usize, 1), ed.doc.history.undoLen()); // one coalesced run
    try insertNewline(ed, &out);
    try std.testing.expectEqualStrings("  abcé\n  ", ed.doc.text.items);
    try insertStr(ed, "zz", &out);
    try std.testing.expectEqualStrings("  abcé\n  zz", ed.doc.text.items);
    try std.testing.expect(out.buffer_changed);
}

test "smartindent: a `{` opens one level deeper on Enter and `o`; a `}` typed first steps back" {
    const ed = try Editor.init(std.testing.allocator, "fn f() {\n    if (x) {\n}");
    defer ed.deinit();
    ed.doc.auto_indent = true;
    var out: EditOutcome = .{};
    ed.cursor = ed.lineEnd(1);
    try insertNewline(ed, &out);
    try std.testing.expectEqualStrings("fn f() {\n    if (x) {\n        \n}", ed.doc.text.items);
    try insertChar(ed, '}', &out);
    try std.testing.expectEqualStrings("fn f() {\n    if (x) {\n    }\n}", ed.doc.text.items);
    try std.testing.expectEqual(ed.lineEnd(2), ed.cursor);
    // `o` on the `fn` line: one level in; Enter mid-line only looks left.
    ed.cursor = 0;
    try insertNewlineBelow(ed, &out);
    try std.testing.expectEqualStrings("fn f() {\n    \n    if (x) {\n    }\n}", ed.doc.text.items);
    ed.cursor = 3; // `fn |f() {`
    try insertNewline(ed, &out);
    try std.testing.expectEqualStrings("fn \nf() {\n    \n    if (x) {\n    }\n}", ed.doc.text.items);
    // Off: nothing of the sort.
    ed.doc.auto_indent = false;
    ed.cursor = ed.lineEnd(1);
    try insertNewline(ed, &out);
    try std.testing.expectEqualStrings("fn \nf() {\n\n    \n    if (x) {\n    }\n}", ed.doc.text.items);
}

test "o and O open lines with the line's indent" {
    const ed = try Editor.init(std.testing.allocator, "\tfoo\nbar");
    defer ed.deinit();
    ed.doc.auto_indent = true;
    ed.cursor = 2;
    var out: EditOutcome = .{};
    try insertNewlineBelow(ed, &out);
    try std.testing.expectEqualStrings("\tfoo\n\t\nbar", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    ed.cursor = 0;
    try insertNewlineAbove(ed, &out);
    try std.testing.expectEqualStrings("\t\n\tfoo\n\t\nbar", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}

test "auto-pair inserts a closer and skips over a typed closer" {
    const ed = try Editor.init(std.testing.allocator, "");
    defer ed.deinit();
    ed.doc.auto_pair = true;
    var out: EditOutcome = .{};
    try insertChar(ed, '(', &out);
    try std.testing.expectEqualStrings("()", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    try insertChar(ed, ')', &out);
    try std.testing.expectEqualStrings("()", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "replace mode overwrites, appends past EOL, and backspace restores" {
    const ed = try Editor.init(std.testing.allocator, "ab\n");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    replaceSessionBegin(ed);
    try overwriteCharAndAdvance(ed, 'X', &out);
    try overwriteCharAndAdvance(ed, 'Y', &out);
    try std.testing.expectEqualStrings("aXY\n", ed.doc.text.items);
    try replaceUndoOne(ed, &out);
    try replaceUndoOne(ed, &out);
    try std.testing.expectEqualStrings("ab\n", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}
