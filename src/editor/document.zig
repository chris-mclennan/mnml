//! `Document` — the text and everything that belongs to the text: the
//! line index, the edit log, the undo history, the change list, the
//! file it came from and the language's editing settings. One document
//! may be shown by several `Editor` views at once (vim's one buffer,
//! N windows); it is refcounted by them and knows each one, so a
//! `splice` through any view moves every other view's cursor along.
//!
//! Every mutation goes through `spliceBy` or `setTextBy`, so the line
//! index is always current and the other views are always told.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const editor_mod = @import("editor.zig");
const Editor = editor_mod.Editor;
const Pos = editor_mod.Pos;
const undo = @import("undo.zig");
const editorconfig = @import("editorconfig.zig");

/// A (row, byte column) position — what tree-sitter's `InputEdit` wants.
pub const Point = struct { row: u32, col: u32 };

/// One `splice`, in pre-edit byte coordinates plus the points on either
/// side of it. `seq` climbs by one per record, so a consumer that
/// remembers the last `seq` it applied can pull exactly the edits it
/// missed (`EditLog.since`).
pub const Splice = struct {
    start: usize,
    old_end: usize,
    new_end: usize,
    start_pt: Point,
    old_end_pt: Point,
    new_end_pt: Point,
    seq: u64,

    /// Where byte `p` of the pre-edit text sits afterwards: before the
    /// edit it stays, after it shifts by the length delta, inside the
    /// replaced range it lands on the edit's start (where vim leaves a
    /// cursor whose text went away).
    pub fn shift(self: Splice, p: usize) usize {
        if (p <= self.start) return p;
        if (p >= self.old_end) return p - self.old_end + self.new_end;
        return self.start;
    }

    /// Rows gained (or lost) by the edit.
    pub fn rowDelta(self: Splice) isize {
        return @as(isize, @intCast(self.new_end_pt.row)) - @as(isize, @intCast(self.old_end_pt.row));
    }
};

/// The incremental-parse contract, kept where the text changes. Every
/// `splice` appends a record; a wholesale replacement (`setText`, an
/// undo restore) has no record and instead bumps `lost_at`, telling a
/// consumer whose `seen` predates it to rebuild from scratch. The log
/// is trimmed by its slowest consumer (`trim`) and capped so a
/// consumer that never reads it cannot grow it without bound.
pub const EditLog = struct {
    items: std.ArrayList(Splice) = .empty,
    next_seq: u64 = 1,
    lost_at: u64 = 0,

    pub const cap = 4096;

    /// Records after `seen`, oldest first.
    pub fn since(self: *const EditLog, seen: u64) []const Splice {
        const items = self.items.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].seq <= seen) lo = mid + 1 else hi = mid;
        }
        return items[lo..];
    }

    /// True when the text changed in a way the records after `seen` do
    /// not describe.
    pub fn lostSince(self: *const EditLog, seen: u64) bool {
        return self.lost_at > seen;
    }

    /// The seq a consumer is current at once it has applied `since(seen)`.
    pub fn head(self: *const EditLog) u64 {
        return self.next_seq - 1;
    }

    /// Drop records at or before `seq` (every consumer has seen them).
    pub fn trim(self: *EditLog, seq: u64) void {
        const items = self.items.items;
        var n: usize = 0;
        while (n < items.len and items[n].seq <= seq) n += 1;
        if (n == 0) return;
        std.mem.copyForwards(Splice, items[0 .. items.len - n], items[n..]);
        self.items.items.len -= n;
    }

    fn markLost(self: *EditLog) void {
        self.items.clearRetainingCapacity();
        self.lost_at = self.next_seq;
        self.next_seq += 1;
    }
};

/// What the file watcher last saw on disk for the document's file.
pub const DiskStamp = struct { mtime_ns: i128, size: u64 };

/// Whoever hands out documents (the app's `DocStore`) can ask to be told
/// when the last view lets go, so its index and whatever it keeps per
/// document (the parse tree) go with it. Without an owner the document
/// frees itself.
pub const Owner = struct {
    ctx: *anyopaque,
    drop: *const fn (ctx: *anyopaque, doc: *Document) void,
};

/// Cap for `change_list` — vim's `:changes` shows the last ~100.
pub const change_list_max = 100;

pub const Document = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of every line's first char; `[0] == 0`, one entry per
    /// `\n` + 1. Maintained incrementally by `spliceBy`.
    line_starts: std.ArrayList(usize) = .empty,
    tab_width: usize = 4,
    /// `>>` / indent pad with one `\t` instead of `tab_width` spaces.
    use_tabs: bool = false,
    /// Carry the previous line's indent on Enter / `o`.
    auto_indent: bool = false,
    /// Insert the matching closer after `(` `[` `{` `"` `'` `` ` ``.
    auto_pair: bool = false,
    /// The language's line-comment token (`// `) and, for block styles
    /// (`<!-- ` … ` -->`), its closer. Static; empty = commentless file.
    comment_token: []const u8 = "",
    comment_token_close: []const u8 = "",
    /// `:changes` — where each mutation left the cursor, newest last.
    change_list: std.ArrayList(Pos) = .empty,
    history: undo.History,
    /// The view whose coalescing run of typed chars is open; another
    /// view's first char starts its own undo group.
    insert_run_owner: ?*const Editor = null,
    /// Every `spliceBy`, for incremental consumers (the highlighter's
    /// tree, the language server, a snippet session's tab stops).
    edits: EditLog = .{},

    // ─── the file ───

    /// Owned. Null for a scratch document.
    path: ?[]u8 = null,
    dirty: bool = false,
    /// The text as of the last load / save — `dirty` is a comparison.
    saved_text: []u8,
    /// `m<letter>` positions — a buffer's, in vim.
    marks: std.AutoHashMapUnmanaged(u8, Pos) = .empty,
    /// File extension used for language-specific behaviour. Owned.
    language: ?[]u8 = null,
    read_only: bool = false,
    /// Rust mnml's `[editor] ensure_trailing_newline`: a file gets its
    /// terminating newline on save.
    ensure_trailing_newline: bool = true,
    /// `[editor] trim_trailing_ws_on_save` / `.editorconfig`
    /// `trim_trailing_whitespace`.
    trim_trailing_ws_on_save: bool = false,
    /// What a save writes between lines. The text is LF in memory
    /// whatever the file had.
    eol: editorconfig.Eol = .lf,
    /// The indent unit the handler types on Tab.
    indent_unit: usize = 4,
    /// The file's mtime + size when it was last read or written; the
    /// watcher compares against it. Null for a scratch document.
    disk: ?DiskStamp = null,
    /// The edit-log seq the language server has been told about.
    lsp_seen: u64 = 0,

    // ─── views ───

    /// Every `Editor` showing this document. Stable pointers: editors are
    /// heap boxes. A splice through one is pushed to the others.
    views: std.ArrayListUnmanaged(*Editor) = .empty,
    /// Views plus any other holder (`retain`); `release` at zero drops.
    refs: u32 = 0,
    owner: ?Owner = null,

    pub fn create(gpa: Allocator, text: []const u8) Allocator.Error!*Document {
        const doc = try gpa.create(Document);
        errdefer gpa.destroy(doc);
        doc.* = .{ .gpa = gpa, .history = .init(gpa), .saved_text = try gpa.dupe(u8, text) };
        errdefer gpa.free(doc.saved_text);
        try doc.text.appendSlice(gpa, text);
        errdefer doc.text.deinit(gpa);
        try doc.rebuildLineIndex();
        return doc;
    }

    /// Frees the document's memory. Callers go through `release`.
    pub fn destroy(self: *Document) void {
        const gpa = self.gpa;
        self.text.deinit(gpa);
        self.line_starts.deinit(gpa);
        self.change_list.deinit(gpa);
        self.edits.items.deinit(gpa);
        self.history.deinit();
        if (self.path) |p| gpa.free(p);
        gpa.free(self.saved_text);
        self.marks.deinit(gpa);
        if (self.language) |l| gpa.free(l);
        self.views.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn retain(self: *Document) void {
        self.refs += 1;
    }

    /// One holder fewer; the last one out frees the document (through
    /// the owner when there is one).
    pub fn release(self: *Document) void {
        assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs > 0) return;
        if (self.owner) |o| o.drop(o.ctx, self) else self.destroy();
    }

    pub fn attachView(self: *Document, v: *Editor) Allocator.Error!void {
        try self.views.append(self.gpa, v);
        self.retain();
    }

    pub fn detachView(self: *Document, v: *Editor) void {
        if (std.mem.indexOfScalar(*Editor, self.views.items, v)) |i| _ = self.views.swapRemove(i);
        if (self.insert_run_owner == v) self.insert_run_owner = null;
        self.release();
    }

    /// Views other than `me`.
    pub fn viewCount(self: *const Document) usize {
        return self.views.items.len;
    }

    // ─── text access ────────────────────────────────────────────────

    pub fn bytes(self: *const Document) []const u8 {
        return self.text.items;
    }

    pub fn len(self: *const Document) usize {
        return self.text.items.len;
    }

    /// Replace the whole text (file reload, undo restore). No edit
    /// record: the log is marked lost. Every view but `by` clamps its
    /// positions into the new text.
    pub fn setTextBy(self: *Document, text: []const u8, by: ?*const Editor) Allocator.Error!void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, text);
        try self.rebuildLineIndex();
        self.edits.markLost();
        for (self.views.items) |v| if (v != by) v.onDocumentReplaced();
    }

    /// THE mutation chokepoint. Replaces `[start, end)` with `new` and
    /// patches the line index in O(lines) without rescanning the text.
    /// Both ends must be char boundaries. Does not touch `by`'s cursor;
    /// every other view's positions are shifted along.
    pub fn spliceBy(self: *Document, start: usize, end: usize, new: []const u8, by: ?*const Editor) Allocator.Error!void {
        assert(start <= end and end <= self.text.items.len);
        assert(self.isBoundary(start) and self.isBoundary(end));
        const gpa = self.gpa;
        const nl_new = std.mem.count(u8, new, "\n");
        try self.line_starts.ensureUnusedCapacity(gpa, nl_new);
        try self.edits.items.ensureUnusedCapacity(gpa, 1);
        const start_pt = self.pointAt(start);
        const old_end_pt = self.pointAt(end);
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

        if (self.edits.items.items.len >= EditLog.cap) self.edits.markLost();
        const new_end = start + new.len;
        const rec: Splice = .{
            .start = start,
            .old_end = end,
            .new_end = new_end,
            .start_pt = start_pt,
            .old_end_pt = old_end_pt,
            .new_end_pt = self.pointAt(new_end),
            .seq = self.edits.next_seq,
        };
        self.edits.items.appendAssumeCapacity(rec);
        self.edits.next_seq += 1;
        for (self.views.items) |v| if (v != by) v.onForeignSplice(rec);
    }

    /// `(row, byte column)` of byte `b` — the shape tree-sitter positions
    /// take. Infallible: the line index is always current.
    pub fn pointAt(self: *const Document, b: usize) Point {
        const row = self.lineOfByte(@min(b, self.text.items.len));
        return .{ .row = @intCast(row), .col = @intCast(@min(b, self.text.items.len) - self.lineStart(row)) };
    }

    /// Full rescan — `create`, `setTextBy`, and the property test that
    /// checks `spliceBy` against it.
    pub fn rebuildLineIndex(self: *Document) Allocator.Error!void {
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

    pub fn isBoundary(self: *const Document, b: usize) bool {
        if (b >= self.text.items.len) return true;
        return (self.text.items[b] & 0xC0) != 0x80;
    }

    pub fn prevBoundary(self: *const Document, b: usize) usize {
        if (b == 0) return 0;
        var i = @min(b, self.text.items.len) - 1;
        while (i > 0 and !self.isBoundary(i)) i -= 1;
        return i;
    }

    pub fn nextBoundary(self: *const Document, b: usize) usize {
        const n = self.text.items.len;
        if (b >= n) return n;
        var i = b + 1;
        while (i < n and !self.isBoundary(i)) i += 1;
        return i;
    }

    /// Snap `b` down to the nearest boundary (and into range).
    pub fn snapBoundary(self: *const Document, b: usize) usize {
        var i = @min(b, self.text.items.len);
        while (i > 0 and !self.isBoundary(i)) i -= 1;
        return i;
    }

    pub fn charAt(self: *const Document, b: usize) ?u21 {
        const t = self.text.items;
        if (b >= t.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(t[b]) catch return t[b];
        if (b + n > t.len) return t[b];
        return std.unicode.utf8Decode(t[b .. b + n]) catch t[b];
    }

    pub fn charBefore(self: *const Document, b: usize) ?u21 {
        if (b == 0) return null;
        return self.charAt(self.prevBoundary(b));
    }

    // ─── lines ──────────────────────────────────────────────────────

    /// Lines as every editor counts them: a trailing `\n` terminates the
    /// last line rather than opening an empty one (`"a\nb\n"` is 2).
    /// The index still holds the phantom start so a cursor at EOF has a
    /// line (`lineOfByte` may return `lineCount()`).
    pub fn lineCount(self: *const Document) usize {
        const nl = self.line_starts.items.len - 1;
        if (nl == 0) return 1;
        if (self.text.items[self.text.items.len - 1] == '\n') return nl;
        return nl + 1;
    }

    /// Byte offset of line `line`'s first char (clamped to the last line).
    pub fn lineStart(self: *const Document, line: usize) usize {
        const ls = self.line_starts.items;
        return ls[@min(line, ls.len - 1)];
    }

    /// Byte offset of line `line`'s `\n` (or EOF on the last line).
    pub fn lineEnd(self: *const Document, line: usize) usize {
        const ls = self.line_starts.items;
        const l = @min(line, ls.len - 1);
        if (l + 1 < ls.len) return ls[l + 1] - 1;
        return self.text.items.len;
    }

    pub fn lineOfByte(self: *const Document, b: usize) usize {
        const v = @min(b, self.text.items.len);
        return firstGreater(self.line_starts.items, v) - 1;
    }

    pub fn lineSlice(self: *const Document, line: usize) []const u8 {
        return self.text.items[self.lineStart(line)..self.lineEnd(line)];
    }

    pub fn lineIsBlank(self: *const Document, line: usize) bool {
        for (self.lineSlice(line)) |b| if (!std.ascii.isWhitespace(b)) return false;
        return true;
    }

    /// Byte of char column `col` on `line`, clamped to the line end.
    pub fn byteAtCol(self: *const Document, line: usize, col: usize) usize {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        var b = start;
        var c: usize = 0;
        while (b < end and c < col) : (c += 1) b = self.nextBoundary(b);
        return b;
    }

    /// Char column of `b` within its line (`b` is clamped to the text).
    pub fn colAtByte(self: *const Document, b_in: usize) usize {
        const b = @min(b_in, self.text.items.len);
        const line = self.lineOfByte(b);
        var i = self.lineStart(line);
        var c: usize = 0;
        while (i < b) : (c += 1) i = self.nextBoundary(i);
        return c;
    }

    pub fn rowColAt(self: *const Document, b: usize) Pos {
        return .{ .row = self.lineOfByte(b), .col = self.colAtByte(b) };
    }

    /// Byte offset of the first non-whitespace char on `line` (line end
    /// when blank).
    pub fn firstNonWs(self: *const Document, line: usize) usize {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        var b = start;
        while (b < end) {
            const c = self.charAt(b) orelse break;
            if (!editor_mod.isSpace(c)) break;
            b = self.nextBoundary(b);
        }
        return b;
    }

    /// Leading `' '` / `'\t'` of `line`, optionally only up to `limit`.
    pub fn leadingIndent(self: *const Document, line: usize, limit: ?usize) []const u8 {
        const start = self.lineStart(line);
        var end = self.lineEnd(line);
        if (limit) |l| end = @min(end, l);
        var b = start;
        while (b < end and (self.text.items[b] == ' ' or self.text.items[b] == '\t')) b += 1;
        return self.text.items[start..b];
    }

    // ─── the file ───────────────────────────────────────────────────

    /// Record the current text as the on-disk text.
    pub fn markSaved(self: *Document) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, self.text.items);
        self.gpa.free(self.saved_text);
        self.saved_text = copy;
        self.dirty = false;
    }

    pub fn recomputeDirty(self: *Document) void {
        self.dirty = !std.mem.eql(u8, self.text.items, self.saved_text);
    }

    /// True when `path` names this document's file.
    pub fn isAt(self: *const Document, path: []const u8) bool {
        const p = self.path orelse return false;
        return std.mem.eql(u8, p, path);
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "a document is shared by its views and dropped with the last one" {
    const gpa = testing.allocator;
    const doc = try Document.create(gpa, "ab\ncd");
    doc.retain();
    const a = try Editor.initOn(gpa, doc);
    const b = try Editor.initOn(gpa, doc);
    try testing.expectEqual(@as(usize, 2), doc.viewCount());
    try testing.expectEqual(@as(u32, 3), doc.refs);
    a.deinit();
    try testing.expectEqual(@as(usize, 1), doc.viewCount());
    try testing.expectEqualStrings("ab\ncd", b.bytes());
    b.deinit();
    try testing.expectEqual(@as(u32, 1), doc.refs);
    doc.release();
}

test "Splice.shift: before stays, after moves by the delta, inside lands on the start" {
    const sp: Splice = .{ .start = 4, .old_end = 6, .new_end = 9, .start_pt = .{ .row = 0, .col = 4 }, .old_end_pt = .{ .row = 0, .col = 6 }, .new_end_pt = .{ .row = 0, .col = 9 }, .seq = 1 };
    try testing.expectEqual(@as(usize, 2), sp.shift(2));
    try testing.expectEqual(@as(usize, 4), sp.shift(4));
    try testing.expectEqual(@as(usize, 4), sp.shift(5));
    try testing.expectEqual(@as(usize, 9), sp.shift(6));
    try testing.expectEqual(@as(usize, 13), sp.shift(10));
}
