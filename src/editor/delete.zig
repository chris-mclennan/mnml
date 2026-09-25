//! Deletions and in-place replacements. Deletes that vim would yank
//! (`dd`, `d{motion}`) write the clipboard through `pushDelete` first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Clipboard = editor.Clipboard;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const motion = @import("motion.zig");
const mc = @import("multicursor.zig");

/// Delete the active selection if there is one. True when it deleted.
pub fn deleteSelectionIfAny(ed: *Editor, out: *EditOutcome) Allocator.Error!bool {
    if (mc.hasExtras(ed)) return deleteSelectionsAll(ed, out);
    const sel = ed.selection() orelse return false;
    if (sel[1] <= sel[0]) {
        ed.anchor = null;
        return false;
    }
    ed.rememberSelection();
    // The snapshot parks the cursor where the text began with no live
    // selection: `xu` / `dwu` come back to the deleted spot, as in vim.
    ed.cursor = sel[0];
    ed.anchor = null;
    try ed.checkpoint();
    const linewise = ed.bytes()[sel[1] - 1] == '\n';
    try ed.splice(sel[0], sel[1], "");
    if (linewise) clampOffPhantomLine(ed);
    out.buffer_changed = true;
    return true;
}

/// A linewise delete that took the last line's `\n` leaves the cursor
/// at EOF, past the new last line's own `\n` — the phantom line the
/// gutter never numbers. Vim lands on the new last line (`:help dd`);
/// so does `dd` here.
pub fn clampOffPhantomLine(ed: *Editor) void {
    const n = ed.len();
    if (ed.cursor >= n and n > 0 and ed.bytes()[n - 1] == '\n') ed.cursor = ed.lineStart(ed.lineCount() - 1);
}

/// Multi-cursor: every cursor drops its own range in one undo step.
fn deleteSelectionsAll(ed: *Editor, out: *EditOutcome) Allocator.Error!bool {
    const primary_has = if (ed.anchor) |a| a != ed.cursor else false;
    if (!primary_has and !mc.extrasHaveSelection(ed)) {
        ed.anchor = null;
        return false;
    }
    ed.rememberSelection();
    try ed.checkpoint();
    try mc.deleteRangePerCursor(ed, {}, mc.ownRange);
    ed.anchor = null;
    mc.clearExtraAnchors(ed);
    out.buffer_changed = true;
    return true;
}

pub fn backspace(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    if (mc.hasExtras(ed)) {
        try ed.checkpoint();
        try mc.deleteBackwardAll(ed);
        out.buffer_changed = true;
        return;
    }
    if (ed.cursor == 0) return;
    try ed.checkpoint();
    const prev = ed.prevBoundary(ed.cursor);
    // Smart pair-backspace: `(|)` → empty in one keystroke.
    if (ed.doc.auto_pair) {
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
    if (mc.hasExtras(ed)) {
        try ed.checkpoint();
        try mc.deleteForwardAll(ed);
        out.buffer_changed = true;
        return;
    }
    if (ed.cursor >= ed.len()) return;
    try ed.checkpoint();
    const next = ed.nextBoundary(ed.cursor);
    try ed.splice(ed.cursor, next, "");
    out.buffer_changed = true;
}

fn wordLeftRange(_: void, ed: *const Editor, _: usize, p: usize) [2]usize {
    return .{ motion.wordLeftFrom(ed, p), p };
}
fn wordRightRange(_: void, ed: *const Editor, _: usize, p: usize) [2]usize {
    return .{ p, motion.wordRightFrom(ed, p) };
}
fn toLineStartRange(_: void, ed: *const Editor, _: usize, p: usize) [2]usize {
    return .{ ed.lineStart(ed.lineOfByte(p)), p };
}
fn toLineEndRange(_: void, ed: *const Editor, _: usize, p: usize) [2]usize {
    return .{ p, ed.lineEnd(ed.lineOfByte(p)) };
}

/// A per-cursor range delete when extras exist. True when it ran.
fn deleteRangeAllIfMulti(ed: *Editor, comptime rangeFor: fn (void, *const Editor, usize, usize) [2]usize, out: *EditOutcome) Allocator.Error!bool {
    if (!mc.hasExtras(ed)) return false;
    try ed.checkpoint();
    try mc.deleteRangePerCursor(ed, {}, rangeFor);
    out.buffer_changed = true;
    return true;
}

pub fn deleteWordLeft(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    if (try deleteRangeAllIfMulti(ed, wordLeftRange, out)) return;
    const target = motion.wordLeftFrom(ed, ed.cursor);
    if (target == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(target, ed.cursor, "");
    ed.cursor = target;
    out.buffer_changed = true;
}

/// vim's Insert `Ctrl-W` (`.word`) / `Ctrl-U` (`.line`), with
/// 'backspace' at Neovim's `indent,eol,start`: at a line start the line
/// break goes; otherwise `Ctrl-W` takes the word before the cursor on
/// its line and `Ctrl-U` goes back to the indent, or from inside the
/// indent to the line start. Either stops once at the Insert start —
/// what this Insert typed goes first, and the next press carries on
/// into the text that was there (`:help i_CTRL-U`).
pub fn deleteBackInInsert(ed: *Editor, what: enum { word, line }, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    // Several cursors: each deletes back as the plain ops do (no Insert
    // start is kept per cursor).
    switch (what) {
        .word => if (try deleteRangeAllIfMulti(ed, wordLeftRange, out)) return,
        .line => if (try deleteRangeAllIfMulti(ed, toLineStartRange, out)) return,
    }
    const cur = ed.cursor;
    if (cur == 0) return;
    const line = ed.currentLine();
    const bol = ed.lineStart(line);
    var target: usize = if (cur == bol) ed.prevBoundary(cur) else switch (what) {
        .word => @max(motion.wordLeftFrom(ed, cur), bol),
        .line => blk: {
            const indent_end = ed.firstNonWs(line);
            break :blk if (cur > indent_end) indent_end else bol;
        },
    };
    if (ed.insert_start) |s| if (cur > s and target < s) {
        target = s;
    };
    if (target >= cur) return;
    try ed.checkpoint();
    try ed.splice(target, cur, "");
    ed.cursor = target;
    // Past the start: the text before it is this Insert's to take now.
    if (ed.insert_start) |s| if (s > target) {
        ed.insert_start = target;
    };
    out.buffer_changed = true;
}

pub fn deleteWordRight(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteSelectionIfAny(ed, out)) return;
    if (try deleteRangeAllIfMulti(ed, wordRightRange, out)) return;
    const target = motion.wordRightFrom(ed, ed.cursor);
    if (target == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(ed.cursor, target, "");
    out.buffer_changed = true;
}

pub fn deleteToLineStart(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteRangeAllIfMulti(ed, toLineStartRange, out)) return;
    const bol = ed.lineStart(ed.currentLine());
    if (bol == ed.cursor) return;
    try ed.checkpoint();
    try ed.splice(bol, ed.cursor, "");
    ed.cursor = bol;
    out.buffer_changed = true;
}

pub fn deleteToLineEnd(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (try deleteRangeAllIfMulti(ed, toLineEndRange, out)) return;
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
    // The column the cursor wants, read once: a counted `3dd` lands on
    // it too, not on where a short line in between clamped it.
    const gc = ed.goalCol();
    const yanked = try std.mem.concat(ed.gpa, u8, &.{ ed.doc.text.items[start..end], "\n" });
    defer ed.gpa.free(yanked);
    try clip.pushDelete(yanked, true);
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    ed.anchor = null;
    try ed.checkpoint();
    if (end < ed.len()) {
        try ed.splice(start, end + 1, "");
        ed.cursor = @min(start, ed.len());
        clampOffPhantomLine(ed);
    } else if (start > 0) {
        const prev_line_start = ed.lineStart(line - 1);
        try ed.splice(ed.prevBoundary(start), ed.len(), "");
        ed.cursor = @min(prev_line_start, ed.len());
    } else {
        try ed.splice(0, ed.len(), "");
        ed.cursor = 0;
    }
    // The line that takes its place keeps that column, clamped to it —
    // vim's `nostartofline` (Neovim's default, `:help 'sol'`) and VS
    // Code's Ctrl+Shift+K alike.
    ed.cursor = ed.byteAtVcol(ed.currentLine(), gc);
    out.buffer_changed = true;
}

/// `d{motion}` after a `select_start` + motion: yank then delete.
pub fn deleteSelection(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    if (mc.hasExtras(ed)) {
        // Every cursor's range, joined by `\n`, is the yank.
        if (try mc.joinedSelections(ed)) |text| {
            defer ed.gpa.free(text);
            try clip.pushDelete(text, false);
            out.clipboard_set = clip.lastWritten();
        }
        _ = try deleteSelectionIfAny(ed, out);
        return;
    }
    if (ed.selection()) |s| {
        if (s[1] > s[0]) {
            try clip.pushDelete(ed.doc.text.items[s[0]..s[1]], false);
            out.clipboard_set = clip.lastWritten();
        }
    }
    _ = try deleteSelectionIfAny(ed, out);
}

/// `dj` / `Vjd` / `dip` after `normalize_linewise_selection`: the lines
/// go to the register linewise and leave the buffer; the cursor takes
/// the line now at their place, at the column `mark_operator_start`
/// kept (vim's `nostartofline`, `:help 'sol'`), else its start. A range
/// that runs to the end of a buffer with no final `\n` takes the line
/// break before it too, so no empty line is left behind (`Gdd`).
pub fn deleteSelectionLinewise(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    if (mc.hasExtras(ed)) return deleteSelection(ed, clip, out);
    const sel = ed.selection() orelse return;
    const goal = ed.op_goal;
    ed.op_start = null;
    ed.op_goal = null;
    var start = sel[0];
    const end = sel[1];
    const body = ed.bytes()[start..end];
    if (body.len > 0 and body[body.len - 1] == '\n') {
        try clip.pushDelete(body, true);
    } else {
        const s = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
        defer ed.gpa.free(s);
        try clip.pushDelete(s, true);
    }
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    ed.rememberSelection();
    // A closed fold inside the lines goes with them (the widening took
    // it whole); `Buffer.applyOps` shifts the ones after.
    const lo_line = ed.lineOfByte(start);
    const hi_line = ed.lineOfByte(if (end > start) end - 1 else start);
    var fi: usize = 0;
    while (fi < ed.folds.count()) {
        const fs = ed.folds.keys()[fi];
        if (fs >= lo_line and fs <= hi_line) ed.folds.orderedRemoveAt(fi) else fi += 1;
    }
    try ed.folds.reIndex(ed.gpa);
    ed.cursor = start;
    ed.anchor = null;
    try ed.checkpoint();
    if (end >= ed.len() and start > 0 and (end == start or ed.bytes()[end - 1] != '\n')) start = ed.prevBoundary(start);
    try ed.splice(start, end, "");
    ed.cursor = @min(start, ed.len());
    clampOffPhantomLine(ed);
    const line = ed.currentLine();
    ed.cursor = if (goal) |g| ed.byteAtVcol(line, g) else ed.lineStart(line);
    out.buffer_changed = true;
}

/// A change's text into the registers, as its delete would put it
/// there (`register_selection_delete`).
pub fn registerSelectionDelete(ed: *Editor, linewise: bool, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const body = ed.bytes()[sel[0]..sel[1]];
    if (!linewise and body.len == 0) return;
    if (linewise and (body.len == 0 or body[body.len - 1] != '\n')) {
        const s = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
        defer ed.gpa.free(s);
        try clip.pushDelete(s, true);
    } else try clip.pushDelete(body, linewise);
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = linewise;
}

pub fn replaceSelection(ed: *Editor, s: []const u8, out: *EditOutcome) Allocator.Error!void {
    if (mc.hasExtras(ed)) {
        try ed.checkpoint();
        try mc.deleteRangePerCursor(ed, {}, mc.ownRange);
        if (s.len > 0) try mc.insertStrAll(ed, s);
        ed.anchor = null;
        mc.clearExtraAnchors(ed);
        out.buffer_changed = true;
        return;
    }
    if (ed.selection()) |sel| {
        // Snapshot at the range's start with no selection: undoing a
        // `cw` lands where the word began.
        ed.cursor = sel[0];
        ed.anchor = null;
        try ed.checkpoint();
        try ed.splice(sel[0], sel[1], s);
        ed.cursor = sel[0] + s.len;
    } else {
        try ed.checkpoint();
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
            if (ed.doc.text.items[i] == '\n') try new.append(ed.gpa, '\n') else try new.appendSlice(ed.gpa, s);
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
    try clip.pushDelete(ed.doc.text.items[sel[0]..sel[1]], false);
    out.clipboard_set = clip.lastWritten();
    try ed.checkpoint();
    try ed.splice(sel[0], sel[1], "");
    ed.cursor = sel[0];
    ed.anchor = null;
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

test "backspace / delete forward / word deletes across a multibyte char" {
    const ed = try Editor.init(std.testing.allocator, "aé bc");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 3;
    try backspace(ed, &out);
    try std.testing.expectEqualStrings("a bc", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    try deleteForward(ed, &out);
    try std.testing.expectEqualStrings("abc", ed.doc.text.items);
    ed.cursor = 3;
    try deleteWordLeft(ed, &out);
    try std.testing.expectEqualStrings("", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 3), ed.doc.history.undoLen());
}

test "dd on middle, last and only line" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "a\nb\nc");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 2;
    try deleteLine(ed, &clip, &out);
    try std.testing.expectEqualStrings("a\nc", ed.doc.text.items);
    try std.testing.expectEqualStrings("b\n", out.clipboard_set.?);
    try std.testing.expect(out.clipboard_linewise);
    ed.cursor = 2;
    try deleteLine(ed, &clip, &out);
    try std.testing.expectEqualStrings("a", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try deleteLine(ed, &clip, &out);
    try std.testing.expectEqualStrings("", ed.doc.text.items);
    try std.testing.expectEqualStrings("a\n", clip.text());
}

test "selection delete yanks, replace/cut/replace_range" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "hello world");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = 6;
    try deleteSelection(ed, &clip, &out);
    try std.testing.expectEqualStrings("world", ed.doc.text.items);
    try std.testing.expectEqualStrings("hello ", clip.text());
    ed.anchor = 0;
    ed.cursor = 5;
    try replaceSelection(ed, "W", &out);
    try std.testing.expectEqualStrings("W", ed.doc.text.items);
    try replaceRange(ed, 0, 1, "xyz", &out);
    try std.testing.expectEqualStrings("xyz", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    ed.anchor = 1;
    ed.cursor = 3;
    try cutSelection(ed, &clip, &out);
    try std.testing.expectEqualStrings("x", ed.doc.text.items);
    try std.testing.expectEqualStrings("yz", clip.text());
    ed.cursor = 0;
    try replaceCharAtCursor(ed, 'Q', &out);
    try std.testing.expectEqualStrings("Q", ed.doc.text.items);
}
