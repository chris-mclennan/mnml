//! `Editor` — a UTF-8 text buffer with a byte cursor, an optional
//! selection anchor, a line index and full-text undo history. Every
//! mutation goes through `splice`, so the line index is always current and
//! the cursor is always on a character boundary.
//!
//! Text is edited only through `apply`: one `EditOp` in, one `EditOutcome`
//! out. The exhaustive switch lives in `apply.zig`; the work is split by
//! family into `motion.zig`, `insert.zig`, `delete.zig`, `select.zig`,
//! `line.zig`, `register.zig` and `undo.zig`. Nothing else touches `text`.
//!
//! Columns are chars, not display cells (tabs / CJK width is a later
//! refinement — same as the Rust editor today).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const edit_op = @import("edit_op.zig");
const EditOp = edit_op.EditOp;
const EditOutcome = edit_op.EditOutcome;
const TextEdit = edit_op.TextEdit;
const undo = @import("undo.zig");
const apply_mod = @import("apply.zig");
pub const Clipboard = @import("clipboard.zig").Clipboard;

/// `Unsupported` is an op tag that has no implementation yet (the vim
/// slices fill them in); everything else is allocation.
pub const Error = error{Unsupported} || Allocator.Error;

pub const Pos = struct { row: usize, col: usize };

/// Cap for `change_list` — vim's `:changes` shows the last ~100.
pub const change_list_max = 100;

pub const CharClass = enum { word, punct, space };

pub fn classOf(c: u21) CharClass {
    if (isSpace(c)) return .space;
    if (isWordChar(c)) return .word;
    return .punct;
}

pub fn isSpace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// vim's `iskeyword` default: alphanumerics, `_`, and anything non-ASCII.
pub fn isWordChar(c: u21) bool {
    if (c < 0x80) return std.ascii.isAlphanumeric(@intCast(c)) or c == '_';
    return !isSpace(c);
}

pub fn charLen(c: u21) usize {
    return std.unicode.utf8CodepointSequenceLength(c) catch 1;
}

pub const Editor = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offset. Always on a char boundary.
    cursor: usize = 0,
    /// Selection start (byte). `null` = no selection.
    anchor: ?usize = null,
    /// Sticky column for vertical motion; `null` = recompute from the cursor.
    goal_col: ?usize = null,
    /// Byte offset of every line's first char; `[0] == 0`, one entry per
    /// `\n` + 1. Maintained incrementally by `splice`.
    line_starts: std.ArrayList(usize) = .empty,
    tab_width: usize = 4,
    /// Carry the previous line's indent on Enter / `o`.
    auto_indent: bool = false,
    /// Insert the matching closer after `(` `[` `{` `"` `'` `` ` ``.
    auto_pair: bool = false,
    /// The last selection that was closed — `gv` restores it.
    last_selection: ?[2]usize = null,
    /// Visual-block anchor. Independent of `anchor`.
    block_anchor: ?usize = null,
    /// Multi-cursor extras, sorted, distinct from `cursor`.
    extra_cursors: std.ArrayList(usize) = .empty,
    /// Parallel to `extra_cursors`.
    extra_anchors: std.ArrayList(?usize) = .empty,
    /// Replace-mode overwrite stack: the char that was overwritten, or
    /// null for a char typed past EOL.
    replace_stack: std.ArrayList(?u21) = .empty,
    /// AI ghost text painted after the cursor. Owned.
    ghost_suggestion: ?[]u8 = null,
    /// `:changes` — where each mutation left the cursor, newest last.
    change_list: std.ArrayList(Pos) = .empty,
    history: undo.History,
    /// A coalescing run of typed chars is open.
    in_insert_run: bool = false,

    pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!Editor {
        var ed: Editor = .{ .gpa = gpa, .history = .init(gpa) };
        errdefer ed.deinit();
        try ed.text.appendSlice(gpa, text);
        try ed.rebuildLineIndex();
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        const gpa = self.gpa;
        self.text.deinit(gpa);
        self.line_starts.deinit(gpa);
        self.extra_cursors.deinit(gpa);
        self.extra_anchors.deinit(gpa);
        self.replace_stack.deinit(gpa);
        if (self.ghost_suggestion) |g| gpa.free(g);
        self.change_list.deinit(gpa);
        self.history.deinit();
    }

    // ─── text access ────────────────────────────────────────────────

    pub fn bytes(self: *const Editor) []const u8 {
        return self.text.items;
    }

    pub fn len(self: *const Editor) usize {
        return self.text.items.len;
    }

    /// Replace the whole text (file reload, undo restore). Resets the
    /// selection and clamps the cursor.
    pub fn setText(self: *Editor, text: []const u8) Allocator.Error!void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, text);
        try self.rebuildLineIndex();
        self.anchor = null;
        self.goal_col = null;
        self.setCursor(self.cursor);
    }

    pub fn setGhostSuggestion(self: *Editor, s: ?[]const u8) Allocator.Error!void {
        if (self.ghost_suggestion) |g| self.gpa.free(g);
        self.ghost_suggestion = if (s) |v| try self.gpa.dupe(u8, v) else null;
    }

    /// THE mutation chokepoint. Replaces `[start, end)` with `new` and
    /// patches the line index in O(lines) without rescanning the text.
    /// Both ends must be char boundaries. Does not touch the cursor.
    pub fn splice(self: *Editor, start: usize, end: usize, new: []const u8) Allocator.Error!void {
        assert(start <= end and end <= self.text.items.len);
        assert(self.isBoundary(start) and self.isBoundary(end));
        const gpa = self.gpa;
        const nl_new = std.mem.count(u8, new, "\n");
        try self.line_starts.ensureUnusedCapacity(gpa, nl_new);
        try self.text.replaceRange(gpa, start, end - start, new);

        const ls = &self.line_starts;
        // Line starts strictly inside `(start, end]` belonged to newlines
        // that are gone; everything after shifts by the length delta.
        const lo = firstGreater(ls.items, start);
        const hi = firstGreater(ls.items, end);
        const removed = hi - lo;
        if (nl_new > removed) {
            _ = try ls.addManyAt(gpa, lo, nl_new - removed);
        } else if (nl_new < removed) {
            const n = removed - nl_new;
            std.mem.copyForwards(usize, ls.items[lo..], ls.items[lo + n ..]);
            ls.items.len -= n;
        }
        var k = lo;
        for (new, 0..) |b, i| {
            if (b == '\n') {
                ls.items[k] = start + i + 1;
                k += 1;
            }
        }
        const delta: isize = @as(isize, @intCast(new.len)) - @as(isize, @intCast(end - start));
        for (ls.items[lo + nl_new ..]) |*e| e.* = @intCast(@as(isize, @intCast(e.*)) + delta);
    }

    /// Full rescan — `init`, `setText`, and the property test that checks
    /// `splice` against it.
    pub fn rebuildLineIndex(self: *Editor) Allocator.Error!void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.gpa, 0);
        for (self.text.items, 0..) |b, i| {
            if (b == '\n') try self.line_starts.append(self.gpa, i + 1);
        }
    }

    fn firstGreater(items: []const usize, v: usize) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] <= v) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    // ─── char boundaries ────────────────────────────────────────────

    pub fn isBoundary(self: *const Editor, b: usize) bool {
        if (b >= self.text.items.len) return true;
        return (self.text.items[b] & 0xC0) != 0x80;
    }

    pub fn prevBoundary(self: *const Editor, b: usize) usize {
        if (b == 0) return 0;
        var i = @min(b, self.text.items.len) - 1;
        while (i > 0 and !self.isBoundary(i)) i -= 1;
        return i;
    }

    pub fn nextBoundary(self: *const Editor, b: usize) usize {
        const n = self.text.items.len;
        if (b >= n) return n;
        var i = b + 1;
        while (i < n and !self.isBoundary(i)) i += 1;
        return i;
    }

    /// Snap `b` down to the nearest boundary (and into range).
    pub fn snapBoundary(self: *const Editor, b: usize) usize {
        var i = @min(b, self.text.items.len);
        while (i > 0 and !self.isBoundary(i)) i -= 1;
        return i;
    }

    pub fn charAt(self: *const Editor, b: usize) ?u21 {
        const t = self.text.items;
        if (b >= t.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(t[b]) catch return t[b];
        if (b + n > t.len) return t[b];
        return std.unicode.utf8Decode(t[b .. b + n]) catch t[b];
    }

    pub fn charBefore(self: *const Editor, b: usize) ?u21 {
        if (b == 0) return null;
        return self.charAt(self.prevBoundary(b));
    }

    /// Clamp + snap, then move the cursor. Every cursor write funnels here
    /// or through a boundary-preserving helper.
    pub fn setCursor(self: *Editor, b: usize) void {
        self.cursor = self.snapBoundary(b);
    }

    // ─── lines ──────────────────────────────────────────────────────

    /// Lines as every editor counts them: a trailing `\n` terminates the
    /// last line rather than opening an empty one (`"a\nb\n"` is 2).
    /// The index still holds the phantom start so a cursor at EOF has a
    /// line (`lineOfByte` may return `lineCount()`).
    pub fn lineCount(self: *const Editor) usize {
        const nl = self.line_starts.items.len - 1;
        if (nl == 0) return 1;
        if (self.text.items[self.text.items.len - 1] == '\n') return nl;
        return nl + 1;
    }

    /// Byte offset of line `line`'s first char (clamped to the last line).
    pub fn lineStart(self: *const Editor, line: usize) usize {
        const ls = self.line_starts.items;
        return ls[@min(line, ls.len - 1)];
    }

    /// Byte offset of line `line`'s `\n` (or EOF on the last line).
    pub fn lineEnd(self: *const Editor, line: usize) usize {
        const ls = self.line_starts.items;
        const l = @min(line, ls.len - 1);
        if (l + 1 < ls.len) return ls[l + 1] - 1;
        return self.text.items.len;
    }

    pub fn lineOfByte(self: *const Editor, b: usize) usize {
        const v = @min(b, self.text.items.len);
        return firstGreater(self.line_starts.items, v) - 1;
    }

    pub fn currentLine(self: *const Editor) usize {
        return self.lineOfByte(self.cursor);
    }

    pub fn lineSlice(self: *const Editor, line: usize) []const u8 {
        return self.text.items[self.lineStart(line)..self.lineEnd(line)];
    }

    pub fn lineIsBlank(self: *const Editor, line: usize) bool {
        for (self.lineSlice(line)) |b| if (!std.ascii.isWhitespace(b)) return false;
        return true;
    }

    /// Byte of char column `col` on `line`, clamped to the line end.
    pub fn byteAtCol(self: *const Editor, line: usize, col: usize) usize {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        var b = start;
        var c: usize = 0;
        while (b < end and c < col) : (c += 1) b = self.nextBoundary(b);
        return b;
    }

    /// Char column of `b` within its line (`b` is clamped to the text).
    pub fn colAtByte(self: *const Editor, b_in: usize) usize {
        const b = @min(b_in, self.text.items.len);
        const line = self.lineOfByte(b);
        var i = self.lineStart(line);
        var c: usize = 0;
        while (i < b) : (c += 1) i = self.nextBoundary(i);
        return c;
    }

    pub fn rowCol(self: *const Editor) Pos {
        return .{ .row = self.currentLine(), .col = self.colAtByte(self.cursor) };
    }

    pub fn rowColAt(self: *const Editor, b: usize) Pos {
        return .{ .row = self.lineOfByte(b), .col = self.colAtByte(b) };
    }

    pub fn placeCursor(self: *Editor, row: usize, col: usize) void {
        self.cursor = self.byteAtCol(row, col);
        self.goal_col = null;
    }

    pub fn goalCol(self: *Editor) usize {
        if (self.goal_col) |c| return c;
        const c = self.colAtByte(self.cursor);
        self.goal_col = c;
        return c;
    }

    /// Byte offset of the first non-whitespace char on `line` (line end
    /// when blank).
    pub fn firstNonWs(self: *const Editor, line: usize) usize {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        var b = start;
        while (b < end) {
            const c = self.charAt(b) orelse break;
            if (!isSpace(c)) break;
            b = self.nextBoundary(b);
        }
        return b;
    }

    /// Leading `' '` / `'\t'` of `line`, optionally only up to `limit`.
    pub fn leadingIndent(self: *const Editor, line: usize, limit: ?usize) []const u8 {
        const start = self.lineStart(line);
        var end = self.lineEnd(line);
        if (limit) |l| end = @min(end, l);
        var b = start;
        while (b < end and (self.text.items[b] == ' ' or self.text.items[b] == '\t')) b += 1;
        return self.text.items[start..b];
    }

    // ─── selection ──────────────────────────────────────────────────

    /// `(lo, hi)` — never reversed.
    pub fn selection(self: *const Editor) ?[2]usize {
        const a = self.anchor orelse return null;
        return .{ @min(a, self.cursor), @max(a, self.cursor) };
    }

    pub fn hasSelection(self: *const Editor) bool {
        return self.anchor != null;
    }

    pub fn selectedText(self: *const Editor) []const u8 {
        const s = self.selection() orelse return "";
        return self.text.items[s[0]..s[1]];
    }

    pub fn rememberSelection(self: *Editor) void {
        if (self.anchor) |a| {
            if (a != self.cursor) self.last_selection = .{ a, self.cursor };
        }
    }

    pub fn setSelection(self: *Editor, start: usize, end: usize) void {
        self.anchor = self.snapBoundary(start);
        self.setCursor(end);
    }

    pub fn isAtLineEnd(self: *const Editor) bool {
        return self.cursor >= self.text.items.len or self.text.items[self.cursor] == '\n';
    }

    // ─── undo plumbing ──────────────────────────────────────────────

    /// Begin a fresh undo group for a mutation about to happen.
    pub fn checkpoint(self: *Editor) Allocator.Error!void {
        self.history.clearRedo();
        self.in_insert_run = false;
        try self.pushUndo();
    }

    /// Begin / continue the coalescing group for typed characters.
    pub fn checkpointInsertRun(self: *Editor) Allocator.Error!void {
        self.history.clearRedo();
        if (!self.in_insert_run) {
            try self.pushUndo();
            self.in_insert_run = true;
        }
    }

    pub fn pushUndo(self: *Editor) Allocator.Error!void {
        try self.history.pushUndo(self.snapshot());
    }

    /// Drop the most recent checkpoint — a "mutation" that turned out to be
    /// a no-op.
    pub fn popCheckpoint(self: *Editor) void {
        if (self.history.popUndo()) |s| self.history.freeSnapshot(s);
    }

    fn snapshot(self: *const Editor) undo.SnapshotSource {
        return .{ .text = self.text.items, .cursor = self.cursor, .anchor = self.anchor };
    }

    pub fn restore(self: *Editor, s: undo.Snapshot) Allocator.Error!void {
        try self.setText(s.text);
        self.setCursor(s.cursor);
        self.anchor = if (s.anchor) |a| self.snapBoundary(a) else null;
        self.in_insert_run = false;
    }

    /// Everything between `beginAtomic` and `endAtomic` undoes as one step.
    pub const AtomicToken = struct { target_len: usize };

    pub fn beginAtomic(self: *Editor) Allocator.Error!AtomicToken {
        self.history.clearRedo();
        self.in_insert_run = false;
        const before = self.history.undoLen();
        try self.pushUndo();
        return .{ .target_len = before + 1 };
    }

    pub fn endAtomic(self: *Editor, tok: AtomicToken) void {
        self.history.truncateUndo(tok.target_len);
        self.in_insert_run = false;
    }

    /// One checkpoint around `body(ctx, self)`; every checkpoint the body
    /// pushes collapses into it.
    pub fn atomicUndo(self: *Editor, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Editor) Error!void) Error!void {
        const tok = try self.beginAtomic();
        defer self.endAtomic(tok);
        try body(ctx, self);
    }

    pub fn canUndo(self: *const Editor) bool {
        return self.history.undoLen() > 0;
    }

    /// An op that did not fan out (a page motion, `dd`, undo) can leave
    /// an extra off a boundary or on the primary; keep both invariants.
    fn normalizeExtras(self: *Editor) void {
        var i: usize = 0;
        while (i < self.extra_cursors.items.len) {
            const c = self.snapBoundary(self.extra_cursors.items[i]);
            if (c == self.cursor) {
                _ = self.extra_cursors.orderedRemove(i);
                _ = self.extra_anchors.orderedRemove(i);
                continue;
            }
            self.extra_cursors.items[i] = c;
            if (self.extra_anchors.items[i]) |a| self.extra_anchors.items[i] = self.snapBoundary(a);
            i += 1;
        }
    }

    fn recordChange(self: *Editor) Allocator.Error!void {
        const pos = self.rowCol();
        if (self.change_list.items.len > 0) {
            const last = &self.change_list.items[self.change_list.items.len - 1];
            if (last.row == pos.row) {
                last.* = pos;
                return;
            }
        }
        try self.change_list.append(self.gpa, pos);
        if (self.change_list.items.len > change_list_max) _ = self.change_list.orderedRemove(0);
    }

    // ─── the interpreter ────────────────────────────────────────────

    /// Apply one op. `viewport_rows` sizes page motions; `arena` receives
    /// `text_edits` (frame lifetime).
    pub fn apply(self: *Editor, op: EditOp, viewport_rows: usize, clip: *Clipboard, arena: Allocator) Error!EditOutcome {
        const before_cursor = self.cursor;
        const before_len = self.text.items.len;
        const had_multi = self.extra_cursors.items.len != 0;
        const replace_range_info: ?[3]usize = switch (op) {
            .replace_range => |r| .{ r.start, r.end, r.text.len },
            else => null,
        };
        const keep_goal = op.preservesGoalCol();
        const is_undo_redo = op.isUndoOrRedo();
        if (!op.isInsertChar()) self.in_insert_run = false;

        var out: EditOutcome = .{};
        try apply_mod.applyOne(self, op, viewport_rows, clip, &out);
        assert(self.isBoundary(self.cursor));
        out.cursor_moved = out.cursor_moved or self.cursor != before_cursor;
        out.buffer_changed = out.buffer_changed or self.text.items.len != before_len;
        // A mutation under a live anchor (Replace mode, `~`, `D`) can leave
        // it past the end or mid-char; keep the selection invariant too.
        if (out.buffer_changed) {
            if (self.anchor) |a| self.anchor = self.snapBoundary(a);
            if (self.block_anchor) |a| self.block_anchor = self.snapBoundary(a);
        }
        if (self.extra_cursors.items.len != 0) self.normalizeExtras();
        if (out.buffer_changed and !is_undo_redo) try self.recordChange();
        if (!keep_goal) self.goal_col = null;

        if (out.buffer_changed and !had_multi and self.extra_cursors.items.len == 0 and out.text_edits.len == 0) {
            const edit: ?TextEdit = if (replace_range_info) |r| blk: {
                const n = self.text.items.len;
                const s = @min(r[0], n);
                const e = @max(@min(r[1], n), s);
                break :blk .{ .start_byte = s, .old_end_byte = e, .new_end_byte = s + r[2] };
            } else inferSingleEdit(before_len, self.text.items.len, before_cursor, self.cursor);
            if (edit) |e| out.text_edits = try arena.dupe(TextEdit, &.{e});
        }
        return out;
    }
};

/// Recover a single-extent edit from the before/after cursor + length.
/// Null when the shape is ambiguous — the caller then drops its parse tree.
fn inferSingleEdit(before_len: usize, after_len: usize, before_cursor: usize, after_cursor: usize) ?TextEdit {
    if (before_len == after_len) return null;
    const len_delta: isize = @as(isize, @intCast(after_len)) - @as(isize, @intCast(before_len));
    const cur_delta: isize = @as(isize, @intCast(after_cursor)) - @as(isize, @intCast(before_cursor));
    if (len_delta > 0) {
        if (cur_delta == len_delta) return .{ .start_byte = before_cursor, .old_end_byte = before_cursor, .new_end_byte = after_cursor };
        return null;
    }
    const n: usize = @intCast(-len_delta);
    if (cur_delta == len_delta) return .{ .start_byte = after_cursor, .old_end_byte = before_cursor, .new_end_byte = after_cursor };
    if (cur_delta == 0) return .{ .start_byte = before_cursor, .old_end_byte = before_cursor + n, .new_end_byte = before_cursor };
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

test "line index after init and splice matches a full rebuild" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "ab\ncd\n\nef");
    defer ed.deinit();
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 6, 7 }, ed.line_starts.items);
    try std.testing.expectEqual(@as(usize, 4), ed.lineCount());
    try ed.splice(9, 9, "\n");
    try std.testing.expectEqual(@as(usize, 4), ed.lineCount()); // trailing newline terminates
    try ed.splice(9, 10, "");
    try std.testing.expectEqual(@as(usize, 5), ed.lineEnd(1));
    try std.testing.expectEqual(@as(usize, 9), ed.lineEnd(3));
    try std.testing.expectEqual(@as(usize, 2), ed.lineOfByte(6));
    // Insert two newlines mid-buffer.
    try ed.splice(1, 1, "x\ny\n");
    try std.testing.expectEqualStrings("ax\ny\nb\ncd\n\nef", ed.text.items);
    var expect = std.ArrayList(usize).empty;
    defer expect.deinit(gpa);
    try expect.append(gpa, 0);
    for (ed.text.items, 0..) |b, i| if (b == '\n') try expect.append(gpa, i + 1);
    try std.testing.expectEqualSlices(usize, expect.items, ed.line_starts.items);
    // Remove a span containing newlines.
    try ed.splice(2, 8, "");
    try std.testing.expectEqualStrings("axd\n\nef", ed.text.items);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 5 }, ed.line_starts.items);
}

test "splice line index property: random edits equal a rebuild" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "");
    defer ed.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const alphabet = "ab\n\nc\n";
    var scratch: [16]u8 = undefined;
    var check = std.ArrayList(usize).empty;
    defer check.deinit(gpa);
    for (0..400) |_| {
        const n = ed.text.items.len;
        const s = if (n == 0) 0 else rnd.uintLessThan(usize, n + 1);
        const e = if (n == s) s else s + rnd.uintLessThan(usize, n - s + 1);
        const k = rnd.uintLessThan(usize, scratch.len);
        for (scratch[0..k]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        try ed.splice(s, e, scratch[0..k]);
        check.clearRetainingCapacity();
        try check.append(gpa, 0);
        for (ed.text.items, 0..) |b, i| if (b == '\n') try check.append(gpa, i + 1);
        try std.testing.expectEqualSlices(usize, check.items, ed.line_starts.items);
    }
}

test "boundaries, columns and rows on multibyte text" {
    var ed = try Editor.init(std.testing.allocator, "héllo\n世界x");
    defer ed.deinit();
    try std.testing.expect(ed.isBoundary(1));
    try std.testing.expect(!ed.isBoundary(2));
    try std.testing.expectEqual(@as(usize, 3), ed.nextBoundary(1));
    try std.testing.expectEqual(@as(usize, 1), ed.prevBoundary(3));
    try std.testing.expectEqual(@as(u21, 'é'), ed.charAt(1).?);
    try std.testing.expectEqual(@as(usize, 2), ed.colAtByte(3));
    try std.testing.expectEqual(@as(usize, 3), ed.byteAtCol(0, 2));
    ed.placeCursor(1, 1);
    try std.testing.expectEqual(@as(usize, 10), ed.cursor);
    try std.testing.expectEqual(Pos{ .row = 1, .col = 1 }, ed.rowCol());
    try std.testing.expectEqual(@as(usize, 14), ed.byteAtCol(1, 99));
    ed.setCursor(2);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}

test "colAtByte past EOF terminates; a stale block anchor is snapped after a shrink" {
    var ed = try Editor.init(std.testing.allocator, "ab\ncd");
    defer ed.deinit();
    try std.testing.expectEqual(@as(usize, 2), ed.colAtByte(99));
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    ed.cursor = 4;
    _ = try ed.apply(.block_select_start, 10, &clip, arena_state.allocator());
    ed.cursor = 0;
    _ = try ed.apply(.{ .replace_range = .{ .start = 1, .end = 5, .text = "" } }, 10, &clip, arena_state.allocator());
    try std.testing.expectEqual(@as(?usize, 1), ed.block_anchor);
}

test "inferSingleEdit covers insert, backspace, forward delete" {
    try std.testing.expectEqual(TextEdit{ .start_byte = 3, .old_end_byte = 3, .new_end_byte = 5 }, inferSingleEdit(10, 12, 3, 5).?);
    try std.testing.expectEqual(TextEdit{ .start_byte = 2, .old_end_byte = 3, .new_end_byte = 2 }, inferSingleEdit(10, 9, 3, 2).?);
    try std.testing.expectEqual(TextEdit{ .start_byte = 3, .old_end_byte = 5, .new_end_byte = 3 }, inferSingleEdit(10, 8, 3, 3).?);
    try std.testing.expect(inferSingleEdit(10, 10, 3, 3) == null);
    try std.testing.expect(inferSingleEdit(10, 8, 3, 9) == null);
}
