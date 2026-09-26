//! `Editor` — one window's view of a `Document`: the byte cursor, the
//! selection anchor, the goal column, the multi-cursor extras, the
//! visual block, the replace stack and the closed folds. The text, its
//! line index and its undo history live on the document, which several
//! editors may share (`:vsplit`); a splice through one editor moves the
//! others' positions along (`onForeignSplice`).
//!
//! Text is edited only through `apply`: one `EditOp` in, one `EditOutcome`
//! out. The exhaustive switch lives in `apply.zig`; the work is split by
//! family into `motion.zig`, `insert.zig`, `delete.zig`, `select.zig`,
//! `line.zig`, `register.zig` and `undo.zig`. Nothing else touches the
//! document's text.
//!
//! An `Editor` is a heap box (`init` returns `*Editor`) so the document
//! can keep a stable pointer to every view while the pane that owns the
//! editor moves around its store.
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
const document = @import("document.zig");
pub const Document = document.Document;
pub const Point = document.Point;
pub const Splice = document.Splice;
pub const EditLog = document.EditLog;
pub const change_list_max = document.change_list_max;
pub const Clipboard = @import("clipboard.zig").Clipboard;

/// `Unsupported` is an op tag that has no implementation yet (the vim
/// slices fill them in); everything else is allocation.
pub const Error = error{Unsupported} || Allocator.Error;

pub const Pos = struct { row: usize, col: usize };

/// Which structural object a text-object op asks for. The editor knows
/// nothing about syntax trees; the app installs an `ObjectProvider`
/// backed by the pane's highlighter, and `select_inner_function` & co.
/// ask it.
pub const ObjectKind = enum { function, class };

pub const ObjectProvider = struct {
    ctx: *anyopaque,
    /// Byte range `[start, end)` of the innermost object of `kind`
    /// containing `byte`, or null. `around` spans the whole definition;
    /// otherwise just its body.
    lookup: *const fn (ctx: *anyopaque, ed: *const Editor, kind: ObjectKind, byte: usize, around: bool) ?[2]usize,
};

/// A foreign edit added or removed rows at `row`; a pane's scroll offset
/// past it moves by `delta` (`takeLineShifts`).
pub const LineShift = struct { row: usize, delta: isize };

/// vim's word classes (`:help word`, `utf_class` in Neovim's
/// `mbyte.c`): a run of CJK splits where the script changes — kanji,
/// hiragana, katakana and hangul are words of their own kinds, CJK
/// punctuation is punctuation — so `w` from `日本語の…` stops at `の`.
pub const CharClass = enum { word, punct, space, ideograph, hiragana, katakana, hangul };

pub fn classOf(c: u21) CharClass {
    if (isSpace(c)) return .space;
    switch (c) {
        0x3001...0x3020, 0x3030, 0x303d, 0xff01...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => return .punct,
        0x3040...0x309f => return .hiragana,
        0x30a0...0x30ff => return .katakana,
        0x3300...0x9fff, 0xf900...0xfaff, 0x20000...0x2fa1f => return .ideograph,
        0xac00...0xd7a3 => return .hangul,
        else => {},
    }
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
    /// The shared text. Retained for as long as this view exists.
    doc: *Document,
    /// Byte offset. Always on a char boundary.
    cursor: usize = 0,
    /// Selection start (byte). `null` = no selection.
    anchor: ?usize = null,
    /// Sticky column for vertical motion; `null` = recompute from the cursor.
    goal_col: ?usize = null,
    /// The last selection that was closed — `gv` restores it.
    last_selection: ?[2]usize = null,
    /// The find matches nearest the cursor (`gn` / `gN`), byte ranges.
    /// The find state lives with the app; it seeds these before a key,
    /// and `select_find_match` reads them when it is applied.
    find_next: ?[2]usize = null,
    find_prev: ?[2]usize = null,
    /// The match `n` / `N` would go to as a motion: the first one that
    /// starts after the cursor, the last one that starts before it, both
    /// wrapping (`:help n`). Seeded with `find_next`; `move_to_find_match`.
    find_after: ?usize = null,
    find_before: ?usize = null,
    /// The last bracket object chose whole lines (`select.bracketCount`);
    /// `if_lines_object` reads it.
    object_lines: bool = false,
    /// `mark_operator_start`: where an operator's range began and the
    /// column the cursor wanted there. `select_start` forgets both.
    op_start: ?usize = null,
    op_goal: ?usize = null,
    /// Visual-block anchor. Independent of `anchor`.
    block_anchor: ?usize = null,
    /// The block runs to each line's end (`$` in V-BLOCK).
    block_eol: bool = false,
    /// Multi-cursor extras, sorted, distinct from `cursor`.
    extra_cursors: std.ArrayList(usize) = .empty,
    /// Parallel to `extra_cursors`.
    extra_anchors: std.ArrayList(?usize) = .empty,
    /// Replace-mode overwrite stack: the char that was overwritten, or
    /// null for a char typed past EOL.
    replace_stack: std.ArrayList(?u21) = .empty,
    /// AI ghost text painted after the cursor. Owned.
    ghost_suggestion: ?[]u8 = null,
    /// The cursor the ghost was set at. It belongs there and nowhere
    /// else: a cursor that moves (a click, a motion, a jump) takes the
    /// ghost down with it (`ghostMoved`) rather than dragging it into
    /// the middle of a word, where the next Tab would insert it.
    ghost_at: usize = 0,
    /// Closed folds: start line → end line. A window's, in vim.
    folds: std.AutoArrayHashMapUnmanaged(usize, usize) = .empty,
    /// Row shifts from other views' edits, for the pane's scroll offset.
    line_shifts: std.ArrayListUnmanaged(LineShift) = .empty,
    /// A coalescing run of typed chars is open (and is this view's —
    /// `doc.insert_run_owner`).
    in_insert_run: bool = false,
    /// Where the Insert session now open began (the buffer sets it when
    /// a modal handler enters Insert, clears it when it leaves): vim's
    /// Insert `Ctrl-W` / `Ctrl-U` stop there once (`:help i_CTRL-U`).
    insert_start: ?usize = null,
    /// vim's `U` (`:help U`): the line the latest run of changes was
    /// made on and its text before them (owned). A change on another
    /// line starts a new run; one that adds or removes lines, an undo or
    /// a redo ends it.
    uline_row: ?usize = null,
    uline_text: std.ArrayListUnmanaged(u8) = .empty,
    /// Tree-sitter text objects, installed by the app; null = the ops
    /// that need one are no-ops.
    objects: ?ObjectProvider = null,

    /// A view on a fresh document holding `text`.
    pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!*Editor {
        const doc = try Document.create(gpa, text);
        errdefer doc.destroy();
        return initOn(gpa, doc);
    }

    /// A view on `doc` (retained; released by `deinit`).
    pub fn initOn(gpa: Allocator, doc: *Document) Allocator.Error!*Editor {
        const ed = try gpa.create(Editor);
        errdefer gpa.destroy(ed);
        ed.* = .{ .gpa = gpa, .doc = doc };
        try doc.attachView(ed);
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        const gpa = self.gpa;
        self.extra_cursors.deinit(gpa);
        self.extra_anchors.deinit(gpa);
        self.replace_stack.deinit(gpa);
        if (self.ghost_suggestion) |g| gpa.free(g);
        self.folds.deinit(gpa);
        self.line_shifts.deinit(gpa);
        self.uline_text.deinit(gpa);
        self.doc.detachView(self);
        gpa.destroy(self);
    }

    // ─── text access (the document's, through the view) ─────────────

    pub fn bytes(self: *const Editor) []const u8 {
        return self.doc.text.items;
    }

    pub fn len(self: *const Editor) usize {
        return self.doc.text.items.len;
    }

    /// Replace the whole text (a file reload). Resets the selection and
    /// clamps the cursor; the other views' positions shift along
    /// (`Document.setTextBy`).
    pub fn setText(self: *Editor, text: []const u8) Allocator.Error!void {
        try self.doc.setTextBy(text, self);
        self.anchor = null;
        self.goal_col = null;
        self.setCursor(self.cursor);
    }

    pub fn setGhostSuggestion(self: *Editor, s: ?[]const u8) Allocator.Error!void {
        if (self.ghost_suggestion) |g| self.gpa.free(g);
        self.ghost_suggestion = if (s) |v| try self.gpa.dupe(u8, v) else null;
        self.ghost_at = self.cursor;
    }

    /// A ghost is showing and the cursor is no longer where it was set.
    pub fn ghostMoved(self: *const Editor) bool {
        return self.ghost_suggestion != null and self.cursor != self.ghost_at;
    }

    /// The mutation chokepoint for this view: the document splices and
    /// tells every other view. Does not touch this view's cursor.
    pub fn splice(self: *Editor, start: usize, end: usize, new: []const u8) Allocator.Error!void {
        try self.doc.spliceBy(start, end, new, self);
        // `gv` reselects the text the selection covered, moved with this
        // view's own edits too (`Vj>gv>` indents the same lines again).
        if (self.last_selection) |ls| {
            const sh = struct {
                fn f(p: usize, s: usize, e: usize, n: usize) usize {
                    if (p <= s) return p;
                    if (p >= e) return p - e + s + n;
                    return s;
                }
            }.f;
            self.last_selection = .{ sh(ls[0], start, end, new.len), sh(ls[1], start, end, new.len) };
        }
    }

    pub fn pointAt(self: *const Editor, b: usize) Point {
        return self.doc.pointAt(b);
    }

    pub fn rebuildLineIndex(self: *Editor) Allocator.Error!void {
        return self.doc.rebuildLineIndex();
    }

    // ─── another view edited the document ───────────────────────────

    fn shiftOpt(sp: Splice, p: ?usize) ?usize {
        return if (p) |v| sp.shift(v) else null;
    }

    /// Move every position this view keeps across a splice it did not
    /// make, so the cursor stays on the same text. Folds move by rows;
    /// a fold the edit ate closes up or goes.
    pub fn onForeignSplice(self: *Editor, sp: Splice) void {
        const before = self.cursor;
        self.cursor = sp.shift(self.cursor);
        if (self.cursor != before) self.goal_col = null;
        self.anchor = shiftOpt(sp, self.anchor);
        self.block_anchor = shiftOpt(sp, self.block_anchor);
        if (self.last_selection) |ls| self.last_selection = .{ sp.shift(ls[0]), sp.shift(ls[1]) };
        for (self.extra_cursors.items) |*c| c.* = sp.shift(c.*);
        for (self.extra_anchors.items) |*a| a.* = shiftOpt(sp, a.*);
        if (self.extra_cursors.items.len != 0) self.normalizeExtras();
        const row_delta = sp.rowDelta();
        if (row_delta == 0) return;
        const start_row: usize = sp.start_pt.row;
        const old_end_row: usize = sp.old_end_pt.row;
        var i: usize = 0;
        while (i < self.folds.count()) {
            const s = self.folds.keys()[i];
            const e = self.folds.values()[i];
            if (s > old_end_row) {
                self.folds.keys()[i] = @intCast(@as(isize, @intCast(s)) + row_delta);
                self.folds.values()[i] = @intCast(@as(isize, @intCast(e)) + row_delta);
                i += 1;
            } else if (e >= start_row) {
                const ne: isize = @as(isize, @intCast(e)) + row_delta;
                if (ne <= @as(isize, @intCast(s))) {
                    self.folds.orderedRemoveAt(i);
                    continue;
                }
                self.folds.values()[i] = @intCast(ne);
                i += 1;
            } else i += 1;
        }
        self.folds.reIndex(self.gpa) catch {};
        self.line_shifts.append(self.gpa, .{ .row = start_row, .delta = row_delta }) catch {};
    }

    /// The row shifts since the last call, oldest first. Frame arena.
    pub fn takeLineShifts(self: *Editor, arena: Allocator) Allocator.Error![]const LineShift {
        if (self.line_shifts.items.len == 0) return &.{};
        const out = try arena.dupe(LineShift, self.line_shifts.items);
        self.line_shifts.clearRetainingCapacity();
        return out;
    }

    // ─── char boundaries ────────────────────────────────────────────

    pub fn isBoundary(self: *const Editor, b: usize) bool {
        return self.doc.isBoundary(b);
    }

    pub fn prevBoundary(self: *const Editor, b: usize) usize {
        return self.doc.prevBoundary(b);
    }

    pub fn nextBoundary(self: *const Editor, b: usize) usize {
        return self.doc.nextBoundary(b);
    }

    /// Snap `b` down to the nearest boundary (and into range).
    pub fn snapBoundary(self: *const Editor, b: usize) usize {
        return self.doc.snapBoundary(b);
    }

    pub fn charAt(self: *const Editor, b: usize) ?u21 {
        return self.doc.charAt(b);
    }

    pub fn charBefore(self: *const Editor, b: usize) ?u21 {
        return self.doc.charBefore(b);
    }

    /// Clamp + snap, then move the cursor. Every cursor write funnels here
    /// or through a boundary-preserving helper.
    pub fn setCursor(self: *Editor, b: usize) void {
        self.cursor = self.snapBoundary(b);
    }

    // ─── lines ──────────────────────────────────────────────────────

    pub fn lineCount(self: *const Editor) usize {
        return self.doc.lineCount();
    }

    pub fn lineStart(self: *const Editor, line: usize) usize {
        return self.doc.lineStart(line);
    }

    pub fn lineEnd(self: *const Editor, line: usize) usize {
        return self.doc.lineEnd(line);
    }

    pub fn lineOfByte(self: *const Editor, b: usize) usize {
        return self.doc.lineOfByte(b);
    }

    pub fn currentLine(self: *const Editor) usize {
        return self.doc.lineOfByte(self.cursor);
    }

    pub fn lineSlice(self: *const Editor, line: usize) []const u8 {
        return self.doc.lineSlice(line);
    }

    pub fn lineIsBlank(self: *const Editor, line: usize) bool {
        return self.doc.lineIsBlank(line);
    }

    pub fn byteAtCol(self: *const Editor, line: usize, col: usize) usize {
        return self.doc.byteAtCol(line, col);
    }

    pub fn colAtByte(self: *const Editor, b_in: usize) usize {
        return self.doc.colAtByte(b_in);
    }

    pub fn rowCol(self: *const Editor) Pos {
        return .{ .row = self.currentLine(), .col = self.colAtByte(self.cursor) };
    }

    pub fn rowColAt(self: *const Editor, b: usize) Pos {
        return self.doc.rowColAt(b);
    }

    pub fn placeCursor(self: *Editor, row: usize, col: usize) void {
        self.cursor = self.byteAtCol(row, col);
        self.goal_col = null;
    }

    /// As `placeCursor`, with `byte` a BYTE offset on the line (what a
    /// search backend reports), clamped to the line and snapped onto a
    /// character boundary.
    pub fn placeCursorByte(self: *Editor, row: usize, byte: usize) void {
        const start = self.lineStart(row);
        const end = self.lineEnd(row);
        self.cursor = self.doc.snapBoundary(start + @min(byte, end - start));
        self.goal_col = null;
    }

    /// The display column `j` / `k` aim for: the cells before the
    /// cursor, tabs and wide glyphs at their width, so the cursor keeps
    /// its place on screen from line to line.
    pub fn goalCol(self: *Editor) usize {
        if (self.goal_col) |c| return c;
        const c = self.doc.vcolAtByte(self.cursor);
        self.goal_col = c;
        return c;
    }

    pub fn byteAtVcol(self: *const Editor, line: usize, vcol: usize) usize {
        return self.doc.byteAtVcol(line, vcol);
    }

    pub fn vcolAtByte(self: *const Editor, b: usize) usize {
        return self.doc.vcolAtByte(b);
    }

    pub fn firstNonWs(self: *const Editor, line: usize) usize {
        return self.doc.firstNonWs(line);
    }

    pub fn leadingIndent(self: *const Editor, line: usize, limit: ?usize) []const u8 {
        return self.doc.leadingIndent(line, limit);
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
        return self.doc.text.items[s[0]..s[1]];
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
        return self.cursor >= self.doc.text.items.len or self.doc.text.items[self.cursor] == '\n';
    }

    // ─── undo plumbing (the document's history, this view's cursor) ─

    /// Begin a fresh undo group for a mutation about to happen.
    pub fn checkpoint(self: *Editor) Allocator.Error!void {
        self.doc.history.clearRedo();
        self.in_insert_run = false;
        try self.pushUndo();
    }

    /// Begin / continue the coalescing group for typed characters. A run
    /// another view opened is not this view's to continue.
    pub fn checkpointInsertRun(self: *Editor) Allocator.Error!void {
        self.doc.history.clearRedo();
        if (!self.in_insert_run or self.doc.insert_run_owner != self) {
            try self.pushUndo();
            self.in_insert_run = true;
            self.doc.insert_run_owner = self;
        }
    }

    pub fn pushUndo(self: *Editor) Allocator.Error!void {
        try self.doc.history.pushUndo(self.snapshot());
        try self.doc.history.saveMarks(&self.doc.marks);
    }

    /// Drop the most recent checkpoint — a "mutation" that turned out to be
    /// a no-op.
    pub fn popCheckpoint(self: *Editor) void {
        self.doc.history.dropUndo();
    }

    fn snapshot(self: *const Editor) undo.SnapshotSource {
        return .{ .text = self.doc.text.items, .cursor = self.cursor, .anchor = self.anchor };
    }

    /// Everything between `beginAtomic` and `endAtomic` undoes as one step.
    pub const AtomicToken = struct { target_len: usize };

    pub fn beginAtomic(self: *Editor) Allocator.Error!AtomicToken {
        self.doc.history.clearRedo();
        self.in_insert_run = false;
        const before = self.doc.history.undoLen();
        try self.pushUndo();
        return .{ .target_len = before + 1 };
    }

    pub fn endAtomic(self: *Editor, tok: AtomicToken) void {
        self.doc.history.truncateUndo(tok.target_len);
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
        return self.doc.history.undoLen() > 0;
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

    /// `typed`: a typed character just went in before the cursor — the
    /// change is AT that character, where `g;` lands (Neovim: `AX<Esc>`
    /// then `g;` is on the `X`, not past it).
    fn recordChange(self: *Editor, typed: bool) Allocator.Error!void {
        const at = if (typed and self.cursor > 0) self.prevBoundary(self.cursor) else self.cursor;
        const pos = self.rowColAt(at);
        if (typed) self.doc.last_insert = self.rowCol();
        const list = &self.doc.change_list;
        if (list.items.len > 0) {
            const last = &list.items[list.items.len - 1];
            if (last.row == pos.row) {
                last.* = pos;
                return;
            }
        }
        try list.append(self.gpa, pos);
        if (list.items.len > change_list_max) _ = list.orderedRemove(0);
    }

    // ─── the interpreter ────────────────────────────────────────────

    /// Apply one op. `viewport_rows` sizes page motions; `arena` receives
    /// `text_edits` (frame lifetime).
    pub fn apply(self: *Editor, op: EditOp, viewport_rows: usize, clip: *Clipboard, arena: Allocator) Error!EditOutcome {
        const before_cursor = self.cursor;
        const before_len = self.doc.text.items.len;
        const had_multi = self.extra_cursors.items.len != 0;
        const replace_range_info: ?[3]usize = switch (op) {
            .replace_range => |r| .{ r.start, r.end, r.text.len },
            else => null,
        };
        const keep_goal = op.preservesGoalCol();
        const is_undo_redo = op.isUndoOrRedo();
        if (!op.isInsertChar()) self.in_insert_run = false;

        // `U`'s line: a change starting on a line the run is not on
        // copies that line first, kept if the change stays on it.
        const tracks_line = op.isMutation() and !is_undo_redo and op != .undo_line;
        const row_before = self.currentLine();
        const lines_before = self.lineCount();
        const uline_candidate: ?[]u8 = if (tracks_line and self.uline_row != row_before) try arena.dupe(u8, self.lineSlice(row_before)) else null;

        var out: EditOutcome = .{};
        // A view the other side of a foreign splice can sit mid-char when
        // that splice joined a lone lead byte to the continuation bytes
        // after it (invalid UTF-8 turned valid); step back onto the char.
        self.cursor = self.snapBoundary(self.cursor);
        try apply_mod.applyOne(self, op, viewport_rows, clip, &out);
        // Same for this view's own deletion.
        if (self.doc.text.items.len != before_len) self.cursor = self.snapBoundary(self.cursor);
        assert(self.isBoundary(self.cursor));
        out.cursor_moved = out.cursor_moved or self.cursor != before_cursor;
        out.buffer_changed = out.buffer_changed or self.doc.text.items.len != before_len;
        // A mutation under a live anchor (Replace mode, `~`, `D`) can leave
        // it past the end or mid-char; keep the selection invariant too.
        if (out.buffer_changed) {
            if (self.anchor) |a| self.anchor = self.snapBoundary(a);
            if (self.block_anchor) |a| self.block_anchor = self.snapBoundary(a);
        }
        if (self.extra_cursors.items.len != 0) self.normalizeExtras();
        if (out.buffer_changed and !is_undo_redo) try self.recordChange(op.isInsertChar() and self.doc.text.items.len > before_len);
        if (out.buffer_changed) {
            if (is_undo_redo or (tracks_line and self.lineCount() != lines_before)) {
                self.uline_row = null;
            } else if (uline_candidate) |text| {
                self.uline_text.clearRetainingCapacity();
                try self.uline_text.appendSlice(self.gpa, text);
                self.uline_row = row_before;
            }
        }
        if (!keep_goal) self.goal_col = null;
        // `$` sticks to the end: the `j` / `k` after it land on each
        // line's last character (`:help $`, curswant = MAXCOL).
        if (op == .move_line_last_char) self.goal_col = std.math.maxInt(usize);

        // `'[` / `']` (`:help '[`): the text a put inserted or a yank
        // took, else a single-extent change's new text.
        const bracket_range: ?[2]usize = out.changed_range orelse if (!out.buffer_changed) out.yanked_range else null;
        if (bracket_range) |r| {
            try self.doc.marks.put(self.gpa, '[', @min(r[0], self.len()));
            try self.doc.marks.put(self.gpa, ']', @min(if (r[1] > r[0]) self.prevBoundary(r[1]) else r[0], self.len()));
        }
        if (out.buffer_changed and !had_multi and self.extra_cursors.items.len == 0 and out.text_edits.len == 0) {
            const edit: ?TextEdit = if (out.changed_range) |r| .{ .start_byte = r[0], .old_end_byte = r[0], .new_end_byte = r[1] } else if (replace_range_info) |r| blk: {
                const n = self.doc.text.items.len;
                const s = @min(r[0], n);
                const e = @max(@min(r[1], n), s);
                break :blk .{ .start_byte = s, .old_end_byte = e, .new_end_byte = s + r[2] };
            } else inferSingleEdit(before_len, self.doc.text.items.len, before_cursor, self.cursor);
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
    const ed = try Editor.init(gpa, "ab\ncd\n\nef");
    defer ed.deinit();
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 6, 7 }, ed.doc.line_starts.items);
    try std.testing.expectEqual(@as(usize, 4), ed.lineCount());
    try ed.splice(9, 9, "\n");
    try std.testing.expectEqual(@as(usize, 4), ed.lineCount()); // trailing newline terminates
    try ed.splice(9, 10, "");
    try std.testing.expectEqual(@as(usize, 5), ed.lineEnd(1));
    try std.testing.expectEqual(@as(usize, 9), ed.lineEnd(3));
    try std.testing.expectEqual(@as(usize, 2), ed.lineOfByte(6));
    // Insert two newlines mid-buffer.
    try ed.splice(1, 1, "x\ny\n");
    try std.testing.expectEqualStrings("ax\ny\nb\ncd\n\nef", ed.doc.text.items);
    var expect = std.ArrayList(usize).empty;
    defer expect.deinit(gpa);
    try expect.append(gpa, 0);
    for (ed.doc.text.items, 0..) |b, i| if (b == '\n') try expect.append(gpa, i + 1);
    try std.testing.expectEqualSlices(usize, expect.items, ed.doc.line_starts.items);
    // Remove a span containing newlines.
    try ed.splice(2, 8, "");
    try std.testing.expectEqualStrings("axd\n\nef", ed.doc.text.items);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 5 }, ed.doc.line_starts.items);
}

test "splice line index property: random edits equal a rebuild" {
    const gpa = std.testing.allocator;
    const ed = try Editor.init(gpa, "");
    defer ed.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const alphabet = "ab\n\nc\n";
    var scratch: [16]u8 = undefined;
    var check = std.ArrayList(usize).empty;
    defer check.deinit(gpa);
    for (0..400) |_| {
        const n = ed.doc.text.items.len;
        const s = if (n == 0) 0 else rnd.uintLessThan(usize, n + 1);
        const e = if (n == s) s else s + rnd.uintLessThan(usize, n - s + 1);
        const k = rnd.uintLessThan(usize, scratch.len);
        for (scratch[0..k]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        try ed.splice(s, e, scratch[0..k]);
        check.clearRetainingCapacity();
        try check.append(gpa, 0);
        for (ed.doc.text.items, 0..) |b, i| if (b == '\n') try check.append(gpa, i + 1);
        try std.testing.expectEqualSlices(usize, check.items, ed.doc.line_starts.items);
    }
}

test "boundaries, columns and rows on multibyte text" {
    const ed = try Editor.init(std.testing.allocator, "héllo\n世界x");
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
    const ed = try Editor.init(std.testing.allocator, "ab\ncd");
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

test "the edit log records every splice with points, a wholesale replacement as one stamped record, and trims" {
    const ed = try Editor.init(std.testing.allocator, "ab\ncd");
    defer ed.deinit();
    try ed.splice(1, 1, "X\nY");
    try ed.splice(0, 2, "");
    const recs = ed.doc.edits.since(0);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    try std.testing.expectEqual(Point{ .row = 0, .col = 1 }, recs[0].start_pt);
    try std.testing.expectEqual(Point{ .row = 0, .col = 1 }, recs[0].old_end_pt);
    try std.testing.expectEqual(Point{ .row = 1, .col = 1 }, recs[0].new_end_pt);
    try std.testing.expectEqual(@as(usize, 4), recs[0].new_end);
    try std.testing.expectEqual(@as(u64, 2), ed.doc.edits.head());
    try std.testing.expectEqual(@as(usize, 1), ed.doc.edits.since(1).len);
    try std.testing.expect(!ed.doc.edits.lostSince(0));
    ed.doc.edits.trim(1);
    try std.testing.expectEqual(@as(usize, 1), ed.doc.edits.items.items.len);
    // A wholesale replacement is one precise record — what differs
    // between the two texts — stamped as a replacement for the consumers
    // that must not map positions across one. Nothing is lost.
    try ed.setText("fresh");
    try std.testing.expect(!ed.doc.edits.lostSince(2));
    try std.testing.expect(ed.doc.edits.replacedSince(2));
    try std.testing.expect(!ed.doc.edits.replacedSince(ed.doc.edits.head()));
    try std.testing.expectEqual(@as(usize, 1), ed.doc.edits.since(2).len);
    // The same text again changes nothing, not even the seq.
    const head = ed.doc.edits.head();
    try ed.setText("fresh");
    try std.testing.expectEqual(head, ed.doc.edits.head());
    // Only a log that overflowed (or was marked so) is lost.
    ed.doc.edits.markLost();
    try std.testing.expect(ed.doc.edits.lostSince(head));
    try std.testing.expect(ed.doc.edits.replacedSince(head));
    try std.testing.expectEqual(@as(usize, 0), ed.doc.edits.since(0).len);
}

test "a splice through one view moves the other view's cursor, anchor, extras and folds; so does a replacement" {
    const gpa = std.testing.allocator;
    const a = try Editor.init(gpa, "one\ntwo\nthree\nfour\n");
    defer a.deinit();
    const b = try Editor.initOn(gpa, a.doc);
    defer b.deinit();
    b.setCursor(9); // "three"
    b.anchor = 4; // "two"
    try b.extra_cursors.append(gpa, 14); // "four"
    try b.extra_anchors.append(gpa, null);
    try b.folds.put(gpa, 2, 3);
    // A inserts a line at the top: everything in B moves down one row.
    try a.splice(0, 0, "zero\n");
    try std.testing.expectEqual(@as(usize, 14), b.cursor);
    try std.testing.expectEqual(@as(?usize, 9), b.anchor);
    try std.testing.expectEqual(@as(usize, 19), b.extra_cursors.items[0]);
    try std.testing.expectEqual(@as(?usize, 4), b.folds.get(3));
    try std.testing.expectEqual(@as(usize, 1), b.line_shifts.items.len);
    try std.testing.expectEqual(@as(isize, 1), b.line_shifts.items[0].delta);
    // An edit after B's cursor leaves it alone; the fold containing the
    // deleted row shrinks.
    try a.splice(19, 24, "");
    try std.testing.expectEqual(@as(usize, 14), b.cursor);
    try std.testing.expectEqual(@as(usize, 19), b.extra_cursors.items[0]);
    try std.testing.expectEqual(@as(usize, 0), b.folds.count());
    // A deletes the text under B's cursor: B lands on the edit's start.
    try a.splice(13, 19, "");
    try std.testing.expectEqual(@as(usize, 13), b.cursor);
    try std.testing.expectEqual(@as(usize, 0), b.extra_cursors.items.len);
    // A replaces the document wholesale — one splice of what differs — and
    // B's cursor, past the end of it, lands on the new end.
    try a.setText("ab");
    try std.testing.expectEqual(@as(usize, 2), b.cursor);
    try std.testing.expectEqual(@as(usize, 0), b.folds.count());
    try std.testing.expectEqualStrings("ab", b.bytes());
}

test "a typed run in one view does not join another view's undo group" {
    const gpa = std.testing.allocator;
    const a = try Editor.init(gpa, "");
    defer a.deinit();
    const b = try Editor.initOn(gpa, a.doc);
    defer b.deinit();
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try a.apply(.{ .insert_char = 'x' }, 10, &clip, arena);
    _ = try a.apply(.{ .insert_char = 'y' }, 10, &clip, arena);
    try std.testing.expectEqual(@as(usize, 1), a.doc.history.undoLen());
    b.setCursor(2);
    _ = try b.apply(.{ .insert_char = 'z' }, 10, &clip, arena);
    try std.testing.expectEqual(@as(usize, 2), a.doc.history.undoLen());
    try std.testing.expectEqualStrings("xyz", a.bytes());
    // B undoes A's group after its own: the cursor follows the change.
    _ = try b.apply(.undo, 10, &clip, arena);
    try std.testing.expectEqualStrings("xy", b.bytes());
    _ = try b.apply(.undo, 10, &clip, arena);
    try std.testing.expectEqualStrings("", b.bytes());
    try std.testing.expectEqual(@as(usize, 0), a.cursor);
}

test "cursor motion and small edits never trip on invalid UTF-8 (seeded fuzz over random bytes)" {
    // A file is bytes: stray continuation bytes (first byte of the file
    // included), cut-short sequences and combining marks after garbage
    // must step one unit at a time in both directions, at both ends.
    const gpa = std.testing.allocator;
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x7fe1_0002);
    const r = prng.random();
    const ops = [_]EditOp{
        .move_left,                .move_right,        .move_up,           .move_down,
        .move_word_left,           .move_word_right,   .move_word_end,     .move_big_word_right,
        .move_big_word_left,       .move_line_start,   .move_line_end,     .move_line_last_char,
        .move_line_first_non_ws,   .move_buffer_start, .move_buffer_end,   .page_up,
        .page_down,                .half_page_up,      .half_page_down,    .backspace,
        .delete_forward,           .delete_word_left,  .delete_word_right, .{ .insert_char = 'x' },
        .{ .insert_char = 0x301 },
    };
    var buf: [48]u8 = undefined;
    for (0..3000) |_| {
        const len = r.uintAtMost(usize, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = switch (r.uintLessThan(u8, 5)) {
            0 => r.int(u8),
            1 => 0x80 + r.uintLessThan(u8, 0x40),
            2 => ([_]u8{ 0xCC, 0xCD, 0x81, 0xA0, 0xC3, 0xE2, 0xF0, 0x9F, 0x98 })[r.uintLessThan(usize, 9)],
            3 => ([_]u8{ '\n', ' ', '\t', '\r' })[r.uintLessThan(usize, 4)],
            else => 'a' + r.uintLessThan(u8, 26),
        };
        const ed = try Editor.init(gpa, s);
        defer ed.deinit();
        ed.cursor = if (r.boolean()) 0 else ed.doc.text.items.len;
        for (0..24) |_| {
            _ = arena_state.reset(.retain_capacity);
            const op = ops[r.uintLessThan(usize, ops.len)];
            _ = try ed.apply(op, 5, &clip, arena_state.allocator());
            const t = ed.doc.text.items;
            try std.testing.expect(ed.cursor <= t.len);
            try std.testing.expect(ed.isBoundary(ed.cursor));
            // Every step lands on a boundary and moves.
            if (ed.cursor < t.len) {
                const nb = ed.nextBoundary(ed.cursor);
                try std.testing.expect(nb > ed.cursor and ed.isBoundary(nb));
            }
            if (ed.cursor > 0) {
                const pb = ed.prevBoundary(ed.cursor);
                try std.testing.expect(pb < ed.cursor and ed.isBoundary(pb));
            }
            _ = ed.doc.vcolAtByte(ed.cursor);
            _ = ed.rowCol();
        }
    }
}
