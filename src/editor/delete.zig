//! Deletions and in-place replacements. Deletes that vim would yank
//! (`dd`, `d{motion}`) write the clipboard through `pushDelete` first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Clipboard = editor.Clipboard;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const motion = @import("motion.zig");

/// Delete the active selection if there is one. True when it deleted.
pub fn deleteSelectionIfAny(ed: *Editor, out: *EditOutcome) Allocator.Error!bool {
    const sel = ed.selection() orelse return false;
    if (sel[1] <= sel[0]) {
        ed.anchor = null;
        return false;
    }
    ed.rememberSelection();
    try ed.checkpoint();
    try ed.splice(sel[0], sel[1], "");
    ed.cursor = sel[0];
    ed.anchor = null;
    out.buffer_changed = true;
    return true;
}

pub fn backspace(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    if (ed.cursor == 0) return;
    try ed.checkpoint();
    const prev = ed.prevBoundary(ed.cursor);
    // Smart pair-backspace: `(|)` → empty in one keystroke.
    if (ed.auto_pair) {
        const before = ed.charAt(prev);
        if (before != null) {
            if (@import("insert.zig").autoPairClose(before.?)) |closer| {
                if (ed.charAt(ed.cursor) == closer) {
                    const next = ed.nextBoundary(ed.cursor);
                    try ed.splice(prev, next, "");
                    ed.cursor = prev;
                    out.buffer_changed = true;
                    return;
                }
            }
        }
    }
    try ed.splice(prev, ed.cursor, "");
    ed.cursor = prev;
    out.buffer_changed = true;
}

pub fn deleteForward(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    if (ed.cursor >= ed.len()) return;
    try ed.checkpoint();
    const next = ed.nextBoundary(ed.cursor);
    try ed.splice(ed.cursor, next, "");
    out.buffer_changed = true;
}

pub fn deleteWordLeft(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    const target = motion.wordLeftFrom(ed, ed.cursor);
    if (target == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(target, ed.cursor, "");
    ed.cursor = target;
    out.buffer_changed = true;
}

pub fn deleteWordRight(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    const target = motion.wordRightFrom(ed, ed.cursor);
    if (target == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(ed.cursor, target, "");
    out.buffer_changed = true;
}

pub fn deleteToLineStart(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const bol = ed.lineStart(ed.currentLine());
    if (bol == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(bol, ed.cursor, "");
    ed.cursor = bol;
    out.buffer_changed = true;
}

pub fn deleteToLineEnd(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const eol = ed.lineEnd(ed.currentLine());
    if (eol == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(ed.cursor, eol, "");
    out.buffer_changed = true;
}

/// `dd`: yank the line linewise, then remove it (including its `\n`, or
/// the previous line's `\n` when it is the last line).
pub fn deleteLine(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const line = ed.currentLine();
    const start = ed.lineStart(line);
    const end = ed.lineEnd(line);
    const yanked = try std.mem.concat(ed.gpa, u8, &.{ ed.text.items[start..end], "\n" });
    defer ed.gpa.free(yanked);
    try clip.pushDelete(yanked, true);
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    ed.anchor = null;
    try ed.checkpoint();
    if (end < ed.len()) {
        try ed.splice(start, end + 1, "");
        ed.cursor = @min(start, ed.len());
    } else if (start > 0) {
        const prev_line_start = ed.lineStart(line - 1);
        try ed.splice(ed.prevBoundary(start), ed.len(), "");
        ed.cursor = @min(prev_line_start, ed.len());
    } else {
        try ed.splice(0, ed.len(), "");
        ed.cursor = 0;
    }
    out.buffer_changed = true;
}

/// `d{motion}` after a `select_start` + motion: yank then delete.
pub fn deleteSelection(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    if (ed.selection()) |s| {
        if (s[1] > s[0]) {
            try clip.pushDelete(ed.text.items[s[0]..s[1]], false);
            out.clipboard_set = clip.lastWritten();
        }
    }
    _ = try deleteSelectionIfAny(ed, out);
}

pub fn replaceSelection(ed: *Editor, s: []const u8, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    if (ed.selection()) |sel| {
        try ed.splice(sel[0], sel[1], s);
        ed.cursor = sel[0] + s.len;
    } else {
        try ed.splice(ed.cursor, ed.cursor, s);
        ed.cursor += s.len;
    }
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `r<c>`: replace the char under the cursor (every non-newline char of
/// a selection in visual mode). Cursor stays put.
pub fn replaceCharAtCursor(ed: *Editor, c: u21, out: *EditOutcome) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch return;
    const s = buf[0..n];
    if (ed.selection()) |sel| {
        try ed.checkpoint();
        var new = std.ArrayList(u8).empty;
        defer new.deinit(ed.gpa);
        var i = sel[0];
        while (i < sel[1]) : (i = ed.nextBoundary(i)) {
            if (ed.text.items[i] == '\n') try new.append(ed.gpa, '\n') else try new.appendSlice(ed.gpa, s);
        }
        try ed.splice(sel[0], sel[1], new.items);
        ed.cursor = sel[0];
        ed.anchor = null;
        out.buffer_changed = true;
        return;
    }
    const under = ed.charAt(ed.cursor) orelse return;
    if (under == '\n') return;
    try ed.checkpoint();
    const end = ed.nextBoundary(ed.cursor);
    try ed.splice(ed.cursor, end, s);
    out.buffer_changed = true;
}

pub fn replaceRange(ed: *Editor, start_in: usize, end_in: usize, text: []const u8, out: *EditOutcome) Allocator.Error!void {
    const n = ed.len();
    const start = @min(start_in, n);
    const end = @max(@min(end_in, n), start);
    if (!ed.isBoundary(start) or !ed.isBoundary(end)) return;
    try ed.checkpoint();
    try ed.splice(start, end, text);
    ed.cursor = start + text.len;
    ed.anchor = null;
    out.buffer_changed = true;
}

pub fn cutSelection(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    try clip.pushDelete(ed.text.items[sel[0]..sel[1]], false);
    out.clipboard_set = clip.lastWritten();
    try ed.checkpoint();
    try ed.splice(sel[0], sel[1], "");
    ed.cursor = sel[0];
    ed.anchor = null;
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

test "backspace / delete forward / word deletes across a multibyte char" {
    var ed = try Editor.init(std.testing.allocator, "aé bc");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 3;
    try backspace(&ed, &out);
    try std.testing.expectEqualStrings("a bc", ed.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    try deleteForward(&ed, &out);
    try std.testing.expectEqualStrings("abc", ed.text.items);
    ed.cursor = 3;
    try deleteWordLeft(&ed, &out);
    try std.testing.expectEqualStrings("", ed.text.items);
    try std.testing.expectEqual(@as(usize, 3), ed.history.undoLen());
}

test "dd on middle, last and only line" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    var ed = try Editor.init(std.testing.allocator, "a\nb\nc");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 2;
    try deleteLine(&ed, &clip, &out);
    try std.testing.expectEqualStrings("a\nc", ed.text.items);
    try std.testing.expectEqualStrings("b\n", out.clipboard_set.?);
    try std.testing.expect(out.clipboard_linewise);
    ed.cursor = 2;
    try deleteLine(&ed, &clip, &out);
    try std.testing.expectEqualStrings("a", ed.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try deleteLine(&ed, &clip, &out);
    try std.testing.expectEqualStrings("", ed.text.items);
    try std.testing.expectEqualStrings("a\n", clip.text());
}

test "selection delete yanks, replace/cut/replace_range" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    var ed = try Editor.init(std.testing.allocator, "hello world");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = 6;
    try deleteSelection(&ed, &clip, &out);
    try std.testing.expectEqualStrings("world", ed.text.items);
    try std.testing.expectEqualStrings("hello ", clip.text());
    ed.anchor = 0;
    ed.cursor = 5;
    try replaceSelection(&ed, "W", &out);
    try std.testing.expectEqualStrings("W", ed.text.items);
    try replaceRange(&ed, 0, 1, "xyz", &out);
    try std.testing.expectEqualStrings("xyz", ed.text.items);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    ed.anchor = 1;
    ed.cursor = 3;
    try cutSelection(&ed, &clip, &out);
    try std.testing.expectEqualStrings("x", ed.text.items);
    try std.testing.expectEqualStrings("yz", clip.text());
    ed.cursor = 0;
    try replaceCharAtCursor(&ed, 'Q', &out);
    try std.testing.expectEqualStrings("Q", ed.text.items);
}
