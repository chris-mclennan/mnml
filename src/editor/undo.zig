//! Undo history: two stacks of full-text snapshots. The undo stack is a
//! ring capped at `limit` — pushing past the cap frees the oldest entry in
//! O(1) instead of shifting (the Rust editor's `Vec::remove(0)`).
//!
//! Snapshot text is gpa-owned per entry. // changed: D4 said "snapshot
//! arena + ring"; an arena cannot release an evicted entry on its own, so
//! each snapshot owns its text and the ring frees it on eviction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("editor.zig").Editor;
const EditOutcome = @import("edit_op.zig").EditOutcome;

pub const Snapshot = struct {
    text: []u8,
    cursor: usize,
    anchor: ?usize,
    /// Monotonic sequence number — `:earlier` / `:later` walk by it.
    seq: u64,
};

/// Borrowed view the editor hands in; the history dupes the text.
pub const SnapshotSource = struct {
    text: []const u8,
    cursor: usize,
    anchor: ?usize,
};

/// Bounded deque used as a stack: push at the tail, evict at the head.
/// `head` walks forward on eviction; the backing list compacts once head
/// passes `compact_at`, so eviction is amortised O(1).
const Ring = struct {
    items: std.ArrayList(Snapshot) = .empty,
    head: usize = 0,

    const compact_at = 512;

    fn len(self: *const Ring) usize {
        return self.items.items.len - self.head;
    }

    fn push(self: *Ring, gpa: Allocator, s: Snapshot, limit: usize) Allocator.Error!void {
        try self.items.append(gpa, s);
        if (self.len() > limit) {
            gpa.free(self.items.items[self.head].text);
            self.head += 1;
            if (self.head >= compact_at) self.compact();
        }
    }

    fn compact(self: *Ring) void {
        const live = self.items.items[self.head..];
        std.mem.copyForwards(Snapshot, self.items.items[0..live.len], live);
        self.items.items.len = live.len;
        self.head = 0;
    }

    fn pop(self: *Ring) ?Snapshot {
        if (self.len() == 0) return null;
        return self.items.pop();
    }

    fn truncate(self: *Ring, gpa: Allocator, new_len: usize) void {
        while (self.len() > new_len) {
            const s = self.items.pop().?;
            gpa.free(s.text);
        }
    }

    fn clear(self: *Ring, gpa: Allocator) void {
        self.truncate(gpa, 0);
        self.head = 0;
    }

    fn deinit(self: *Ring, gpa: Allocator) void {
        self.clear(gpa);
        self.items.deinit(gpa);
    }
};

pub const History = struct {
    gpa: Allocator,
    undo: Ring = .{},
    redo: Ring = .{},
    seq: u64 = 0,
    limit: usize = default_limit,

    pub const default_limit = 2000;

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        self.undo.deinit(self.gpa);
        self.redo.deinit(self.gpa);
    }

    fn take(self: *History, src: SnapshotSource) Allocator.Error!Snapshot {
        self.seq += 1;
        return .{ .text = try self.gpa.dupe(u8, src.text), .cursor = src.cursor, .anchor = src.anchor, .seq = self.seq };
    }

    pub fn pushUndo(self: *History, src: SnapshotSource) Allocator.Error!void {
        const s = try self.take(src);
        errdefer self.gpa.free(s.text);
        try self.undo.push(self.gpa, s, self.limit);
    }

    pub fn pushRedo(self: *History, src: SnapshotSource) Allocator.Error!void {
        const s = try self.take(src);
        errdefer self.gpa.free(s.text);
        try self.redo.push(self.gpa, s, self.limit);
    }

    /// Caller owns the returned snapshot: `freeSnapshot` it.
    pub fn popUndo(self: *History) ?Snapshot {
        return self.undo.pop();
    }

    pub fn popRedo(self: *History) ?Snapshot {
        return self.redo.pop();
    }

    pub fn freeSnapshot(self: *History, s: Snapshot) void {
        self.gpa.free(s.text);
    }

    pub fn clearRedo(self: *History) void {
        self.redo.clear(self.gpa);
    }

    /// Re-stamp the cursor of undo entry `index` (oldest first). The
    /// buffer uses it once per key: the snapshot an op took mid-way —
    /// after the handler's own motions — remembers the cursor the key
    /// started from, vim's `uh_cursor`.
    /// The text undo entry `index` (oldest first) would restore.
    pub fn undoTextAt(self: *const History, index: usize) ?[]const u8 {
        const at = self.undo.head + index;
        return if (at < self.undo.items.items.len) self.undo.items.items[at].text else null;
    }

    pub fn setUndoCursor(self: *History, index: usize, cursor: usize) void {
        const at = self.undo.head + index;
        if (at < self.undo.items.items.len) self.undo.items.items[at].cursor = cursor;
    }

    pub fn undoLen(self: *const History) usize {
        return self.undo.len();
    }

    pub fn redoLen(self: *const History) usize {
        return self.redo.len();
    }

    pub fn truncateUndo(self: *History, new_len: usize) void {
        self.undo.truncate(self.gpa, new_len);
    }
};

// ─── ops ────────────────────────────────────────────────────────────────

pub fn undoOp(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const s = ed.doc.history.popUndo() orelse return;
    defer ed.doc.history.freeSnapshot(s);
    try ed.doc.history.pushRedo(.{ .text = ed.doc.text.items, .cursor = ed.cursor, .anchor = ed.anchor });
    const before = try ed.gpa.dupe(u8, ed.doc.text.items);
    defer ed.gpa.free(before);
    try ed.restore(s);
    placeAfterHistoryHop(ed, before, s.cursor);
    ed.extra_cursors.clearRetainingCapacity();
    ed.extra_anchors.clearRetainingCapacity();
    out.buffer_changed = true;
}

pub fn redoOp(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const s = ed.doc.history.popRedo() orelse return;
    defer ed.doc.history.freeSnapshot(s);
    try ed.doc.history.pushUndo(.{ .text = ed.doc.text.items, .cursor = ed.cursor, .anchor = ed.anchor });
    const before = try ed.gpa.dupe(u8, ed.doc.text.items);
    defer ed.gpa.free(before);
    try ed.restore(s);
    placeAfterHistoryHop(ed, before, s.cursor);
    ed.extra_cursors.clearRetainingCapacity();
    ed.extra_anchors.clearRetainingCapacity();
    out.buffer_changed = true;
}

/// Where `u` / `Ctrl-R` leave the cursor (vim's `u_undoredo`, probed
/// with `vim -es`): the snapshot's own cursor when its line lies within
/// the changed block — the line above the first change through the line
/// below the last (`4Gddu` → 4:1, `12Gddggu` → 12:1) — else the first
/// changed line's first non-blank (`:'a,'bd` from line 24, then `u` →
/// line 5). `before` is the text the hop replaced; the block is the
/// lines where it and the restored text differ.
fn placeAfterHistoryHop(ed: *Editor, before: []const u8, saved_cursor: usize) void {
    const after = ed.bytes();
    const n = @min(before.len, after.len);
    var prefix: usize = 0;
    while (prefix < n and before[prefix] == after[prefix]) prefix += 1;
    if (prefix == before.len and prefix == after.len) return;
    var suffix: usize = 0;
    while (suffix < n - @min(prefix, n) and before[before.len - 1 - suffix] == after[after.len - 1 - suffix]) suffix += 1;
    const first_line = ed.lineOfByte(@min(prefix, after.len));
    const changed_end = after.len - @min(suffix, after.len);
    const last_line = ed.lineOfByte(@max(changed_end, @min(prefix, after.len)));
    const saved_line = ed.lineOfByte(@min(saved_cursor, after.len));
    const lo = first_line -| 1;
    const hi = last_line + 1;
    if (saved_line >= lo and saved_line <= hi) {
        ed.cursor = ed.snapBoundary(@min(saved_cursor, after.len));
        return;
    }
    ed.cursor = ed.firstNonWs(@min(first_line, ed.lineCount() - 1));
}

// ─── tests ──────────────────────────────────────────────────────────────

test "ring evicts the oldest past the limit without shifting every push" {
    const gpa = std.testing.allocator;
    var h = History.init(gpa);
    defer h.deinit();
    h.limit = 3;
    for (0..1000) |i| {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
        try h.pushUndo(.{ .text = s, .cursor = i, .anchor = null });
    }
    try std.testing.expectEqual(@as(usize, 3), h.undoLen());
    // The backing list was compacted, never grew to 1000.
    try std.testing.expect(h.undo.items.items.len <= 3 + Ring.compact_at);
    const top = h.popUndo().?;
    defer h.freeSnapshot(top);
    try std.testing.expectEqualStrings("999", top.text);
    try std.testing.expectEqual(@as(usize, 999), top.cursor);
    h.truncateUndo(0);
    try std.testing.expectEqual(@as(usize, 0), h.undoLen());
}
