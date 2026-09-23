//! Undo history: two stacks of text STATES, each kept as what differs
//! from its neighbour rather than as a copy of the text. The undo stack
//! is a ring capped at `limit` — pushing past the cap frees the oldest
//! entry in O(1) instead of shifting (the Rust editor's `Vec::remove(0)`).
//!
//! An entry is a hull: `state = base[0..p] ++ mid ++ base[len - s..]`.
//! The top entry's base is the live text; every other entry's base is
//! the state above it. The document tells the history about each splice
//! BEFORE it happens (`beforeSplice`), so the two tops keep describing
//! their states as the text moves under them, and an entry costs the
//! bytes its own change touched — a keystroke in a 100 MB file is a few
//! bytes of history, where a copy of the text per entry was 100 MB.
//!
//! The model is unchanged: an entry IS a state (`popUndo` hands back the
//! full text), entries can be dropped from the top without restoring
//! (`truncateUndo`, a no-op checkpoint), and arbitrary states can be
//! pushed (a persisted history read back). The property test at the
//! bottom holds this representation to a stack of full copies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("editor.zig").Editor;
const EditOutcome = @import("edit_op.zig").EditOutcome;

/// A state handed out whole. Caller-owned text.
pub const Snapshot = struct {
    text: []u8,
    cursor: usize,
    anchor: ?usize,
    /// Monotonic sequence number — `:earlier` / `:later` walk by it.
    seq: u64,
};

/// Borrowed view the editor hands in.
pub const SnapshotSource = struct {
    text: []const u8,
    cursor: usize,
    anchor: ?usize,
};

/// One state, as a hull against its base. `mid` is gpa-owned.
pub const Entry = struct {
    p: usize,
    s: usize,
    mid: []u8,
    cursor: usize,
    anchor: ?usize,
    seq: u64,

    pub fn view(e: *const Entry, base: []const u8) View {
        return .{ .base = base, .p = e.p, .s = e.s, .mid = e.mid };
    }
};

/// A state read through its hull, without building it.
pub const View = struct {
    base: []const u8,
    p: usize,
    s: usize,
    mid: []const u8,

    pub fn len(v: View) usize {
        return v.p + v.mid.len + v.s;
    }

    pub fn at(v: View, i: usize) u8 {
        if (i < v.p) return v.base[i];
        if (i < v.p + v.mid.len) return v.mid[i - v.p];
        return v.base[v.base.len - v.s + (i - v.p - v.mid.len)];
    }

    /// Append the state's bytes `[from, to)`.
    pub fn appendRange(v: View, gpa: Allocator, out: *std.ArrayList(u8), from: usize, to: usize) Allocator.Error!void {
        std.debug.assert(from <= to and to <= v.len());
        const m0 = v.p;
        const m1 = v.p + v.mid.len;
        if (from < m0) try out.appendSlice(gpa, v.base[from..@min(to, m0)]);
        if (to > m0 and from < m1) try out.appendSlice(gpa, v.mid[@max(from, m0) - m0 .. @min(to, m1) - m0]);
        if (to > m1) {
            const tail = v.base[v.base.len - v.s ..];
            try out.appendSlice(gpa, tail[@max(from, m1) - m1 .. to - m1]);
        }
    }

    pub fn toOwned(v: View, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacityPrecise(gpa, v.len());
        try v.appendRange(gpa, &out, 0, v.len());
        return out.toOwnedSlice(gpa);
    }

    /// Index of the last `c` in the state's `[0, end)`.
    pub fn lastIndexOfScalar(v: View, end_in: usize, c: u8) ?usize {
        const end = @min(end_in, v.len());
        const m0 = v.p;
        const m1 = v.p + v.mid.len;
        if (end > m1) {
            const tail = v.base[v.base.len - v.s ..];
            if (std.mem.lastIndexOfScalar(u8, tail[0 .. end - m1], c)) |i| return m1 + i;
        }
        if (end > m0) {
            if (std.mem.lastIndexOfScalar(u8, v.mid[0 .. @min(end, m1) - m0], c)) |i| return m0 + i;
        }
        return std.mem.lastIndexOfScalar(u8, v.base[0..@min(end, m0)], c);
    }
};

/// The hull of two texts: common prefix, then common suffix of the rest.
fn hullOf(state: []const u8, base: []const u8) struct { p: usize, s: usize } {
    const n = @min(state.len, base.len);
    const p = std.mem.indexOfDiff(u8, state[0..n], base[0..n]) orelse n;
    var s: usize = 0;
    while (s < n - p and state[state.len - 1 - s] == base[base.len - 1 - s]) s += 1;
    return .{ .p = p, .s = s };
}

/// Bounded deque used as a stack: push at the tail, evict at the head.
/// `head` walks forward on eviction; the backing list compacts once head
/// passes `compact_at`, so eviction is amortised O(1).
const Ring = struct {
    items: std.ArrayList(Entry) = .empty,
    head: usize = 0,

    const compact_at = 512;

    fn len(self: *const Ring) usize {
        return self.items.items.len - self.head;
    }

    fn top(self: *Ring) ?*Entry {
        if (self.len() == 0) return null;
        return &self.items.items[self.items.items.len - 1];
    }

    fn push(self: *Ring, gpa: Allocator, e: Entry, limit: usize) Allocator.Error!void {
        try self.items.append(gpa, e);
        if (self.len() > limit) {
            // The oldest state: nothing is spelled against it.
            gpa.free(self.items.items[self.head].mid);
            self.head += 1;
            if (self.head >= compact_at) self.compact();
        }
    }

    fn compact(self: *Ring) void {
        const live = self.items.items[self.head..];
        std.mem.copyForwards(Entry, self.items.items[0..live.len], live);
        self.items.items.len = live.len;
        self.head = 0;
    }

    fn clear(self: *Ring, gpa: Allocator) void {
        for (self.items.items[self.head..]) |e| gpa.free(e.mid);
        self.items.clearRetainingCapacity();
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
    /// The document's text — the base of both top entries. Null for a
    /// history on its own (a test): the live text is then empty.
    live: ?*const std.ArrayList(u8) = null,
    /// Set while `u` / Ctrl-R restores a state taken from that stack. The
    /// entry under the one taken is spelled against the state being
    /// restored, not the live text, so the restoring splice is not its
    /// business — and once the splice lands the live text IS that state.
    /// Re-spelling it through the hop instead would fold two changes at
    /// opposite ends of a file into one hull the size of the file.
    hopping: enum { none, undo, redo } = .none,

    pub const default_limit = 2000;

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        self.undo.deinit(self.gpa);
        self.redo.deinit(self.gpa);
    }

    fn liveText(self: *const History) []const u8 {
        return if (self.live) |l| l.items else "";
    }

    // ─── the text is about to change ────────────────────────────────

    /// The live text's `[a, b)` is about to be replaced. Both top
    /// entries widen their hulls over it first, taking the bytes they
    /// were sharing with the text, so each still spells its state
    /// afterwards. Nothing else in either stack refers to the live text.
    pub fn beforeSplice(self: *History, a: usize, b: usize) Allocator.Error!void {
        const live = self.liveText();
        if (self.hopping != .undo) if (self.undo.top()) |e| try widen(self.gpa, e, live, a, b);
        if (self.hopping != .redo) if (self.redo.top()) |e| try widen(self.gpa, e, live, a, b);
    }

    fn widen(gpa: Allocator, e: *Entry, live: []const u8, a: usize, b: usize) Allocator.Error!void {
        const n = live.len;
        std.debug.assert(a <= b and b <= n and e.p + e.s <= n);
        // A state equal to the text shares all of it; where the shared
        // run is cut is free, so cut it at the edit.
        if (e.mid.len == 0 and e.p + e.s == n) {
            const mid = try gpa.dupe(u8, live[a..b]);
            gpa.free(e.mid);
            e.p = a;
            e.s = n - b;
            e.mid = mid;
            return;
        }
        const np = @min(e.p, a);
        const ns = @min(e.s, n - b);
        if (np == e.p and ns == e.s) return;
        const mid = try gpa.alloc(u8, (e.p - np) + e.mid.len + (e.s - ns));
        @memcpy(mid[0 .. e.p - np], live[np..e.p]);
        @memcpy(mid[e.p - np ..][0..e.mid.len], e.mid);
        @memcpy(mid[e.p - np + e.mid.len ..], live[n - e.s .. n - ns]);
        gpa.free(e.mid);
        e.p = np;
        e.s = ns;
        e.mid = mid;
    }

    // ─── push ───────────────────────────────────────────────────────

    fn pushOn(self: *History, ring: *Ring, src: SnapshotSource) Allocator.Error!void {
        const live = self.liveText();
        var e: Entry = .{ .p = live.len, .s = 0, .mid = &.{}, .cursor = src.cursor, .anchor = src.anchor, .seq = self.seq + 1 };
        const is_live = src.text.ptr == live.ptr and src.text.len == live.len;
        if (!is_live) {
            // An arbitrary state X (a persisted history read back). It is
            // spelled against the live text, and the entry under it — so
            // far spelled against the live text too — against X.
            const h = hullOf(src.text, live);
            const mid = try self.gpa.dupe(u8, src.text[h.p .. src.text.len - h.s]);
            errdefer self.gpa.free(mid);
            try ring.items.ensureUnusedCapacity(self.gpa, 1);
            if (ring.top()) |below| {
                const state = try below.view(live).toOwned(self.gpa);
                defer self.gpa.free(state);
                const hb = hullOf(state, src.text);
                const bmid = try self.gpa.dupe(u8, state[hb.p .. state.len - hb.s]);
                self.gpa.free(below.mid);
                below.p = hb.p;
                below.s = hb.s;
                below.mid = bmid;
            }
            e.p = h.p;
            e.s = h.s;
            e.mid = mid;
        }
        // (When X is the live text the entry under it is already spelled
        // against it: nothing to do.)
        try ring.push(self.gpa, e, self.limit);
        self.seq += 1;
    }

    pub fn pushUndo(self: *History, src: SnapshotSource) Allocator.Error!void {
        return self.pushOn(&self.undo, src);
    }

    pub fn pushRedo(self: *History, src: SnapshotSource) Allocator.Error!void {
        return self.pushOn(&self.redo, src);
    }

    // ─── pop ────────────────────────────────────────────────────────

    /// Take the top entry, still spelled against the live text. The
    /// entry under it is re-spelled against the live text in its place.
    /// Should that run out of memory the rest of the stack is dropped —
    /// states that can no longer be spelled are not kept as lies.
    fn take(self: *History, ring: *Ring) ?Entry {
        if (ring.len() == 0) return null;
        var t = ring.items.pop().?;
        const live = self.liveText();
        if (ring.top()) |below| {
            if (rebase(self.gpa, below, &t, live, true)) |_| tighten(self.gpa, below, live) else |_| ring.clear(self.gpa);
        }
        tighten(self.gpa, &t, live);
        return t;
    }

    /// Shrink a hull spelled against `live` to what really differs: a
    /// re-spelled entry spans its own change AND the one it was spelled
    /// through, and most of that span is text the two share. Restoring a
    /// tight hull is a small splice. Out of memory leaves it wide — still
    /// true, only larger.
    fn tighten(gpa: Allocator, e: *Entry, live: []const u8) void {
        const region = live[e.p .. live.len - e.s];
        const n = @min(e.mid.len, region.len);
        const cp = std.mem.indexOfDiff(u8, e.mid[0..n], region[0..n]) orelse n;
        var cs: usize = 0;
        while (cs < n - cp and e.mid[e.mid.len - 1 - cs] == region[region.len - 1 - cs]) cs += 1;
        if (cp == 0 and cs == 0) return;
        const mid = gpa.dupe(u8, e.mid[cp .. e.mid.len - cs]) catch return;
        gpa.free(e.mid);
        e.mid = mid;
        e.p += cp;
        e.s += cs;
    }

    /// `below` is spelled against `t`'s state; spell it against `live`.
    /// `free_old` says `below.mid` is gpa-owned (false on an arena).
    fn rebase(gpa: Allocator, below: *Entry, t: *const Entry, live: []const u8, free_old: bool) Allocator.Error!void {
        // Its hull already covers `t`'s: the runs it shares with `t`'s
        // state are runs of the live text too, at the same offsets from
        // either end.
        if (below.p <= t.p and below.s <= t.s) return;
        const tv = t.view(live);
        const tl = tv.len();
        const np = @min(below.p, t.p);
        const ns = @min(below.s, t.s);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacityPrecise(gpa, (below.p - np) + below.mid.len + (below.s - ns));
        try tv.appendRange(gpa, &out, np, below.p);
        try out.appendSlice(gpa, below.mid);
        try tv.appendRange(gpa, &out, tl - below.s, tl - ns);
        const mid = try out.toOwnedSlice(gpa);
        if (free_old) gpa.free(below.mid);
        below.p = np;
        below.s = ns;
        below.mid = mid;
    }

    /// The top entry, to be RESTORED by the caller: nothing under it is
    /// re-spelled (see `hopping`). Caller frees `mid`.
    fn takeToRestore(self: *History, ring: *Ring) ?Entry {
        if (ring.len() == 0) return null;
        var t = ring.items.pop().?;
        tighten(self.gpa, &t, self.liveText());
        return t;
    }

    /// The top state, whole. Caller owns the snapshot: `freeSnapshot` it.
    pub fn popUndo(self: *History) Allocator.Error!?Snapshot {
        return self.popWhole(&self.undo);
    }

    pub fn popRedo(self: *History) Allocator.Error!?Snapshot {
        return self.popWhole(&self.redo);
    }

    fn popWhole(self: *History, ring: *Ring) Allocator.Error!?Snapshot {
        const t = ring.top() orelse return null;
        const text = try t.view(self.liveText()).toOwned(self.gpa);
        const e = self.take(ring).?;
        self.gpa.free(e.mid);
        return .{ .text = text, .cursor = e.cursor, .anchor = e.anchor, .seq = e.seq };
    }

    pub fn freeSnapshot(self: *History, s: Snapshot) void {
        self.gpa.free(s.text);
    }

    /// Drop the top undo state without restoring it.
    pub fn dropUndo(self: *History) void {
        if (self.take(&self.undo)) |e| self.gpa.free(e.mid);
    }

    pub fn clearRedo(self: *History) void {
        self.redo.clear(self.gpa);
    }

    /// Undo entry `index` (oldest first) as a hull against the live text
    /// — what that entry would restore, read without building it. The
    /// returned view's `mid` is `gpa`-owned by the caller.
    pub fn undoViewAt(self: *const History, gpa: Allocator, index: usize) Allocator.Error!?View {
        return self.viewAt(&self.undo, gpa, index);
    }

    /// The same for the redo stack (oldest first).
    pub fn redoViewAt(self: *const History, gpa: Allocator, index: usize) Allocator.Error!?View {
        return self.viewAt(&self.redo, gpa, index);
    }

    fn viewAt(self: *const History, ring: *const Ring, gpa: Allocator, index: usize) Allocator.Error!?View {
        const items = ring.items.items;
        const at = ring.head + index;
        if (at >= items.len) return null;
        const live = self.liveText();
        // Walk down from the top, spelling each state against the text.
        var k = items.len - 1;
        var cur: Entry = items[k];
        cur.mid = try gpa.dupe(u8, items[k].mid);
        errdefer gpa.free(cur.mid);
        while (k > at) {
            k -= 1;
            var below: Entry = items[k];
            below.mid = try gpa.dupe(u8, items[k].mid);
            {
                errdefer gpa.free(below.mid);
                try rebase(gpa, &below, &cur, live, true);
            }
            gpa.free(cur.mid);
            cur = below;
        }
        return cur.view(live);
    }

    /// The newest `max` states of a stack, oldest first, whole — what a
    /// persisted history writes. On `arena`.
    pub fn tailStates(self: *const History, arena: Allocator, which: enum { undo, redo }, max: usize) Allocator.Error![]Snapshot {
        const ring = if (which == .undo) &self.undo else &self.redo;
        const items = ring.items.items[ring.head..];
        const n = @min(max, items.len);
        const out = try arena.alloc(Snapshot, n);
        const live = self.liveText();
        var above: ?Entry = null;
        var i: usize = items.len;
        var left = n;
        while (left > 0) {
            i -= 1;
            left -= 1;
            var e: Entry = items[i];
            if (above) |*t| try rebase(arena, &e, t, live, false);
            out[left] = .{ .text = try e.view(live).toOwned(arena), .cursor = e.cursor, .anchor = e.anchor, .seq = e.seq };
            above = e;
        }
        return out;
    }

    /// One entry as a persisted history stores it: the hull and the
    /// cursor, spelled against the live text (the newest entry) or the
    /// state above it (every older one) — the stack as it is in memory.
    pub const Hull = struct { p: usize = 0, s: usize = 0, mid: []const u8 = "", cursor: usize = 0, anchor: ?usize = null };

    /// The newest entries of a stack, oldest first, holding no more than
    /// `max` entries and `max_bytes` of hull text between them — a
    /// suffix of the stack, so each still spells its state against the
    /// one above it. Borrowed from the history; valid until it changes.
    pub fn tailHulls(self: *const History, arena: Allocator, which: enum { undo, redo }, max: usize, max_bytes: usize) Allocator.Error![]Hull {
        const ring = if (which == .undo) &self.undo else &self.redo;
        const items = ring.items.items[ring.head..];
        var n: usize = 0;
        var bytes_used: usize = 0;
        while (n < @min(max, items.len)) : (n += 1) {
            const e = items[items.len - 1 - n];
            if (bytes_used + e.mid.len > max_bytes) break;
            bytes_used += e.mid.len;
        }
        const out = try arena.alloc(Hull, n);
        for (items[items.len - n ..], out) |e, *o| o.* = .{ .p = e.p, .s = e.s, .mid = e.mid, .cursor = e.cursor, .anchor = e.anchor };
        return out;
    }

    /// Put persisted `hulls` (oldest first, as `tailHulls` gave them) on
    /// an EMPTY stack. False, and nothing changed, when the stack is not
    /// empty or the hulls do not spell states of the live text — each
    /// must fit inside the state above it, the newest inside the text.
    pub fn restoreHulls(self: *History, which: enum { undo, redo }, hulls: []const Hull) Allocator.Error!bool {
        const ring = if (which == .undo) &self.undo else &self.redo;
        if (ring.len() != 0) return false;
        var base_len = self.liveText().len;
        var k = hulls.len;
        while (k > 0) {
            k -= 1;
            const h = hulls[k];
            if (h.p > base_len or h.s > base_len - h.p) return false;
            const state_len = h.p + h.mid.len + h.s;
            if (h.cursor > state_len) return false;
            if (h.anchor) |a| if (a > state_len) return false;
            base_len = state_len;
        }
        for (hulls) |h| {
            const mid = try self.gpa.dupe(u8, h.mid);
            errdefer self.gpa.free(mid);
            try ring.push(self.gpa, .{ .p = h.p, .s = h.s, .mid = mid, .cursor = h.cursor, .anchor = h.anchor, .seq = self.seq + 1 }, self.limit);
            self.seq += 1;
        }
        return true;
    }

    /// Re-stamp the cursor of undo entry `index` (oldest first). The
    /// buffer uses it once per key: the snapshot an op took mid-way —
    /// after the handler's own motions — remembers the cursor the key
    /// started from, vim's `uh_cursor`.
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

    /// Bytes the two stacks hold.
    pub fn bytes(self: *const History) usize {
        var n: usize = 0;
        for (self.undo.items.items[self.undo.head..]) |e| n += e.mid.len;
        for (self.redo.items.items[self.redo.head..]) |e| n += e.mid.len;
        return n;
    }

    /// Drop the newest states until `new_len` are left.
    pub fn truncateUndo(self: *History, new_len: usize) void {
        while (self.undo.len() > new_len) self.dropUndo();
    }
};

// ─── ops ────────────────────────────────────────────────────────────────

pub fn undoOp(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const h = &ed.doc.history;
    if (h.undoLen() == 0) return;
    try h.pushRedo(.{ .text = ed.doc.text.items, .cursor = ed.cursor, .anchor = ed.anchor });
    const e = h.takeToRestore(&h.undo).?;
    defer h.gpa.free(e.mid);
    h.hopping = .undo;
    defer h.hopping = .none;
    try hop(ed, e);
    out.buffer_changed = true;
}

pub fn redoOp(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const h = &ed.doc.history;
    if (h.redoLen() == 0) return;
    try h.pushUndo(.{ .text = ed.doc.text.items, .cursor = ed.cursor, .anchor = ed.anchor });
    const e = h.takeToRestore(&h.redo).?;
    defer h.gpa.free(e.mid);
    h.hopping = .redo;
    defer h.hopping = .none;
    try hop(ed, e);
    out.buffer_changed = true;
}

/// Put the text into `e`'s state — one splice of what differs — and
/// leave the cursor where vim would.
fn hop(ed: *Editor, e: Entry) Allocator.Error!void {
    const gpa = ed.gpa;
    const live = ed.doc.text.items;
    const n = live.len;
    // The hull is in bytes; a splice is in chars. Pull both ends out to
    // char boundaries, taking the bytes in between from the text.
    var start = e.p;
    var end = n - e.s;
    while (start > 0 and !ed.isBoundary(start)) start -= 1;
    while (end < n and !ed.isBoundary(end)) end += 1;
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(gpa);
    try new.ensureTotalCapacityPrecise(gpa, (e.p - start) + e.mid.len + (end - (n - e.s)));
    new.appendSliceAssumeCapacity(live[start..e.p]);
    new.appendSliceAssumeCapacity(e.mid);
    new.appendSliceAssumeCapacity(live[n - e.s .. end]);
    const removed = try gpa.dupe(u8, live[start..end]);
    defer gpa.free(removed);
    if (removed.len != 0 or new.items.len != 0) try ed.doc.replaceSpanBy(start, end, new.items, ed);
    ed.anchor = null;
    ed.goal_col = null;
    ed.setCursor(e.cursor);
    ed.anchor = if (e.anchor) |a| ed.snapBoundary(a) else null;
    ed.in_insert_run = false;
    const before: View = .{ .base = ed.bytes(), .p = start, .s = n - end, .mid = removed };
    placeAfterHistoryHop(ed, before, e.cursor);
    ed.extra_cursors.clearRetainingCapacity();
    ed.extra_anchors.clearRetainingCapacity();
}

/// Where `u` / `Ctrl-R` leave the cursor (vim's `u_undoredo`, probed
/// with `vim -es`): the snapshot's own cursor when its line lies within
/// the changed block — the line above the first change through the line
/// below the last (`4Gddu` → 4:1, `12Gddggu` → 12:1) — else the first
/// changed line's first non-blank (`:'a,'bd` from line 24, then `u` →
/// line 5). `before` is the text the hop replaced, read through its hull
/// against the restored text; the block is the lines where the two
/// differ.
fn placeAfterHistoryHop(ed: *Editor, before: View, saved_cursor: usize) void {
    const after = ed.bytes();
    const bl = before.len();
    const n = @min(bl, after.len);
    // The hull's shared runs are equal by construction: start past them.
    var prefix: usize = @min(before.p, n);
    while (prefix < n and before.at(prefix) == after[prefix]) prefix += 1;
    if (prefix == bl and prefix == after.len) return;
    const room = n - @min(prefix, n);
    var suffix: usize = @min(before.s, room);
    while (suffix < room and before.at(bl - 1 - suffix) == after[after.len - 1 - suffix]) suffix += 1;
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

const testing = std.testing;

test "ring evicts the oldest past the limit without shifting every push" {
    const gpa = testing.allocator;
    var h = History.init(gpa);
    defer h.deinit();
    h.limit = 3;
    for (0..1000) |i| {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
        try h.pushUndo(.{ .text = s, .cursor = i, .anchor = null });
    }
    try testing.expectEqual(@as(usize, 3), h.undoLen());
    // The backing list was compacted, never grew to 1000.
    try testing.expect(h.undo.items.items.len <= 3 + Ring.compact_at);
    const top = (try h.popUndo()).?;
    defer h.freeSnapshot(top);
    try testing.expectEqualStrings("999", top.text);
    try testing.expectEqual(@as(usize, 999), top.cursor);
    const next = (try h.popUndo()).?;
    defer h.freeSnapshot(next);
    try testing.expectEqualStrings("998", next.text);
    h.truncateUndo(0);
    try testing.expectEqual(@as(usize, 0), h.undoLen());
}

test "a view reads a state through its hull: bytes, ranges, the last newline" {
    const gpa = testing.allocator;
    const v: View = .{ .base = "ab\ncd\nef", .p = 2, .s = 3, .mid = "X\nY" };
    const whole = try v.toOwned(gpa);
    defer gpa.free(whole);
    try testing.expectEqualStrings("abX\nY\nef", whole);
    for (whole, 0..) |c, i| try testing.expectEqual(c, v.at(i));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..whole.len + 1) |from| for (from..whole.len + 1) |to| {
        out.clearRetainingCapacity();
        try v.appendRange(gpa, &out, from, to);
        try testing.expectEqualStrings(whole[from..to], out.items);
    };
    for (0..whole.len + 2) |end| {
        try testing.expectEqual(std.mem.lastIndexOfScalar(u8, whole[0..@min(end, whole.len)], '\n'), v.lastIndexOfScalar(end, '\n'));
    }
}

test "a keystroke's undo entry costs the bytes it touched, not a copy of the text" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big);
    @memset(big, 'a');
    const ed = try Editor.init(gpa, big);
    defer ed.deinit();
    var out: EditOutcome = .{};
    for (0..50) |i| {
        try ed.checkpoint();
        try ed.splice(i * 1000, i * 1000 + 1, "bc");
    }
    try testing.expectEqual(@as(usize, 50), ed.doc.history.undoLen());
    try testing.expect(ed.doc.history.bytes() < 4096);
    for (0..50) |_| {
        try undoOp(ed, &out);
        try testing.expect(ed.doc.history.bytes() < 4096);
    }
    try testing.expectEqualSlices(u8, big, ed.bytes());
    for (0..50) |_| {
        try redoOp(ed, &out);
        try testing.expect(ed.doc.history.bytes() < 4096);
    }
    try testing.expectEqual(@as(usize, (1 << 20) + 50), ed.len());
    // One at the top, one at the very end, and back: two small entries
    // and two small splices — never the file between them.
    try ed.checkpoint();
    try ed.splice(0, 0, "ZQJ");
    try ed.checkpoint();
    try ed.splice(ed.len(), ed.len(), "QJZ\n");
    const seq_before = ed.doc.edits.head();
    try undoOp(ed, &out);
    try undoOp(ed, &out);
    try testing.expect(ed.doc.history.bytes() < 4096);
    for (ed.doc.edits.since(seq_before)) |sp| try testing.expect(sp.old_end - sp.start < 16);
    try redoOp(ed, &out);
    try redoOp(ed, &out);
    try testing.expect(ed.doc.history.bytes() < 4096);
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "ZQJ") and std.mem.endsWith(u8, ed.bytes(), "QJZ\n"));
}

/// The history as it was: a stack of whole copies. The oracle.
const Model = struct {
    gpa: Allocator,
    undo: std.ArrayList([]u8) = .empty,
    redo: std.ArrayList([]u8) = .empty,

    fn deinit(m: *Model) void {
        for (m.undo.items) |t| m.gpa.free(t);
        for (m.redo.items) |t| m.gpa.free(t);
        m.undo.deinit(m.gpa);
        m.redo.deinit(m.gpa);
    }

    fn clearRedo(m: *Model) void {
        for (m.redo.items) |t| m.gpa.free(t);
        m.redo.clearRetainingCapacity();
    }

    /// Every entry of both stacks, read through its hull, is the copy
    /// the model kept.
    fn expectSame(m: *const Model, ed: *const Editor) !void {
        const h = &ed.doc.history;
        try testing.expectEqual(m.undo.items.len, h.undoLen());
        try testing.expectEqual(m.redo.items.len, h.redoLen());
        for (m.undo.items, 0..) |want, i| {
            const v = (try h.undoViewAt(m.gpa, i)).?;
            defer m.gpa.free(v.mid);
            const text = try v.toOwned(m.gpa);
            defer m.gpa.free(text);
            try testing.expectEqualStrings(want, text);
        }
        for (m.redo.items, 0..) |want, i| {
            const v = (try h.redoViewAt(m.gpa, i)).?;
            defer m.gpa.free(v.mid);
            const text = try v.toOwned(m.gpa);
            defer m.gpa.free(text);
            try testing.expectEqualStrings(want, text);
        }
    }

    fn truncate(m: *Model, n: usize) void {
        while (m.undo.items.len > n) m.gpa.free(m.undo.pop().?);
    }
};

test "undo property: a random script of edits, groups, no-op checkpoints, replacements, undos and redos leaves the text a stack of whole copies would" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x756e646f);
    const rand = prng.random();
    const bits = [_][]const u8{ "x", "hello", "\n", "é", "日本", "  ", "fn f() {}\n", "🦀", "", "0123456789" };
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        const ed = try Editor.init(gpa, "alpha\nbeta é\ngamma 日本語\n\ndelta\n");
        defer ed.deinit();
        var m: Model = .{ .gpa = gpa };
        defer m.deinit();
        var out: EditOutcome = .{};
        var step: usize = 0;
        while (step < 120) : (step += 1) {
            switch (rand.uintLessThan(u8, 10)) {
                // One edit, one undo group.
                0...3 => {
                    m.clearRedo();
                    try m.undo.append(gpa, try gpa.dupe(u8, ed.bytes()));
                    try ed.checkpoint();
                    try randomSplice(ed, rand, &bits);
                },
                // A group: several checkpoints collapse into the first.
                4 => {
                    m.clearRedo();
                    try m.undo.append(gpa, try gpa.dupe(u8, ed.bytes()));
                    const keep = m.undo.items.len;
                    const tok = try ed.beginAtomic();
                    const inner = 1 + rand.uintLessThan(usize, 4);
                    var k: usize = 0;
                    while (k < inner) : (k += 1) {
                        try m.undo.append(gpa, try gpa.dupe(u8, ed.bytes()));
                        try ed.checkpoint();
                        try randomSplice(ed, rand, &bits);
                    }
                    ed.endAtomic(tok);
                    m.truncate(keep);
                },
                // A checkpoint that turned out to be a no-op.
                5 => {
                    m.clearRedo();
                    try ed.checkpoint();
                    ed.popCheckpoint();
                },
                // A wholesale replacement inside a group of its own.
                6 => {
                    m.clearRedo();
                    try m.undo.append(gpa, try gpa.dupe(u8, ed.bytes()));
                    try ed.checkpoint();
                    const cut = ed.snapBoundary(rand.uintLessThan(usize, ed.len() + 1));
                    const fresh = try std.mem.concat(gpa, u8, &.{ ed.bytes()[cut..], bits[rand.uintLessThan(usize, bits.len)], ed.bytes()[0..cut] });
                    defer gpa.free(fresh);
                    try ed.setText(fresh);
                },
                7, 8 => if (m.undo.items.len > 0) {
                    try m.redo.append(gpa, try gpa.dupe(u8, ed.bytes()));
                    const want = m.undo.pop().?;
                    defer gpa.free(want);
                    try undoOp(ed, &out);
                    try testing.expectEqualStrings(want, ed.bytes());
                },
                else => if (m.redo.items.len > 0) {
                    try m.undo.append(gpa, try gpa.dupe(u8, ed.bytes()));
                    const want = m.redo.pop().?;
                    defer gpa.free(want);
                    try redoOp(ed, &out);
                    try testing.expectEqualStrings(want, ed.bytes());
                },
            }
            try testing.expectEqual(m.undo.items.len, ed.doc.history.undoLen());
            try testing.expectEqual(m.redo.items.len, ed.doc.history.redoLen());
            try testing.expect(ed.isBoundary(ed.cursor) and ed.cursor <= ed.len());
            try m.expectSame(ed);
        }
        // The persisted tail is the model's tail, whole.
        {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const tail = try ed.doc.history.tailStates(arena.allocator(), .undo, 7);
            const from = m.undo.items.len - tail.len;
            for (tail, 0..) |s, i| try testing.expectEqualStrings(m.undo.items[from + i], s.text);
            const rtail = try ed.doc.history.tailStates(arena.allocator(), .redo, 7);
            const rfrom = m.redo.items.len - rtail.len;
            for (rtail, 0..) |s, i| try testing.expectEqualStrings(m.redo.items[rfrom + i], s.text);
        }
        // Undo everything: the first state. Redo everything: the last —
        // the oldest state still on the redo stack when there is one (the
        // script ended on an undo), else the text as it stands.
        const final = try gpa.dupe(u8, if (m.redo.items.len > 0) m.redo.items[0] else ed.bytes());
        defer gpa.free(final);
        while (m.undo.items.len > 0) {
            try m.redo.append(gpa, try gpa.dupe(u8, ed.bytes()));
            const want = m.undo.pop().?;
            defer gpa.free(want);
            try undoOp(ed, &out);
            try testing.expectEqualStrings(want, ed.bytes());
            try m.expectSame(ed);
        }
        try testing.expectEqualStrings("alpha\nbeta é\ngamma 日本語\n\ndelta\n", ed.bytes());
        while (m.redo.items.len > 0) {
            const want = m.redo.pop().?;
            defer gpa.free(want);
            try m.undo.append(gpa, try gpa.dupe(u8, ed.bytes()));
            try redoOp(ed, &out);
            try testing.expectEqualStrings(want, ed.bytes());
            try m.expectSame(ed);
        }
        try testing.expectEqualStrings(final, ed.bytes());
    }
}

fn randomSplice(ed: *Editor, rand: std.Random, bits: []const []const u8) !void {
    const a = ed.snapBoundary(rand.uintLessThan(usize, ed.len() + 1));
    var b = ed.snapBoundary(@min(ed.len(), a + rand.uintLessThan(usize, 12)));
    if (b < a) b = a;
    try ed.splice(a, b, bits[rand.uintLessThan(usize, bits.len)]);
    // A bare splice leaves this view's cursor alone; an op would place it.
    ed.setCursor(ed.cursor);
}
