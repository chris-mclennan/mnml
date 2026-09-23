//! Multi-cursor. `extra_cursors` / `extra_anchors` run parallel to the
//! primary `cursor` / `anchor`; a fan-out edits at every cursor in
//! descending byte order so earlier offsets stay valid, then re-sorts,
//! dedups, and drops any extra that landed on the primary.
//!
//! Motions fan out by standing each extra in as the cursor and running
//! the primary motion (`moveExtras`); edits go through a `Set` — the
//! cursors and anchors copied out, shifted as the text changes, and
//! committed back at the end.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const select = @import("select.zig");

pub fn hasExtras(ed: *const Editor) bool {
    return ed.extra_cursors.items.len != 0;
}

/// Some extra has a live, non-empty selection.
pub fn extrasHaveSelection(ed: *const Editor) bool {
    for (ed.extra_anchors.items, ed.extra_cursors.items) |a, c| {
        if (a) |av| if (av != c) return true;
    }
    return false;
}

pub fn clear(ed: *Editor) void {
    ed.extra_cursors.clearRetainingCapacity();
    ed.extra_anchors.clearRetainingCapacity();
}

pub fn clearExtraAnchors(ed: *Editor) void {
    for (ed.extra_anchors.items) |*a| a.* = null;
}

/// The anchor paired with cursor `idx` — 0 is the primary.
pub fn anchorOf(ed: *const Editor, idx: usize) ?usize {
    if (idx == 0) return ed.anchor;
    return ed.extra_anchors.items[idx - 1];
}

/// The `(lo, hi)` a cursor's own selection covers; `(p, p)` when it has none.
pub fn ownRange(_: void, ed: *const Editor, idx: usize, p: usize) [2]usize {
    const a = anchorOf(ed, idx) orelse return .{ p, p };
    return .{ @min(a, p), @max(a, p) };
}

const Pair = struct { c: usize, a: ?usize };

fn pairLessThan(_: void, x: Pair, y: Pair) bool {
    return x.c < y.c;
}

/// Replace the extras with `pairs`: sorted, deduped, never on the primary.
fn commitExtras(ed: *Editor, pairs: []Pair) Allocator.Error!void {
    std.mem.sort(Pair, pairs, {}, pairLessThan);
    ed.extra_cursors.clearRetainingCapacity();
    ed.extra_anchors.clearRetainingCapacity();
    var last: ?usize = null;
    for (pairs) |p| {
        if (p.c == ed.cursor or last == p.c) continue;
        try ed.extra_cursors.append(ed.gpa, p.c);
        try ed.extra_anchors.append(ed.gpa, p.a);
        last = p.c;
    }
}

fn sortExtras(ed: *Editor) Allocator.Error!void {
    const pairs = try ed.gpa.alloc(Pair, ed.extra_cursors.items.len);
    defer ed.gpa.free(pairs);
    for (ed.extra_cursors.items, ed.extra_anchors.items, 0..) |c, a, i| pairs[i] = .{ .c = c, .a = a };
    try commitExtras(ed, pairs);
}

/// Toggle an extra at `byte`: adding one that already exists removes it
/// (VS Code's alt+click); the primary's own position is never an extra.
/// While a selection is live the new extra is anchored at itself so the
/// next motion extends every selection in parallel.
pub fn addExtra(ed: *Editor, byte: usize) Allocator.Error!void {
    const b = ed.snapBoundary(byte);
    if (b == ed.cursor) return;
    if (std.mem.indexOfScalar(usize, ed.extra_cursors.items, b)) |i| {
        _ = ed.extra_cursors.orderedRemove(i);
        _ = ed.extra_anchors.orderedRemove(i);
        return;
    }
    try ed.extra_cursors.append(ed.gpa, b);
    errdefer _ = ed.extra_cursors.pop();
    try ed.extra_anchors.append(ed.gpa, if (ed.anchor != null) b else null);
    try sortExtras(ed);
}

fn bottomRow(ed: *const Editor) usize {
    var row = ed.currentLine();
    for (ed.extra_cursors.items) |b| row = @max(row, ed.lineOfByte(b));
    return row;
}

fn topRow(ed: *const Editor) usize {
    var row = ed.currentLine();
    for (ed.extra_cursors.items) |b| row = @min(row, ed.lineOfByte(b));
    return row;
}

/// A cursor on the line below the bottom-most cursor, at the goal column.
pub fn addCursorBelow(ed: *Editor) Allocator.Error!void {
    const bottom = bottomRow(ed);
    if (bottom + 1 >= ed.lineCount()) return;
    const gc = ed.goalCol();
    try addExtra(ed, ed.byteAtVcol(bottom + 1, gc));
}

pub fn addCursorAbove(ed: *Editor) Allocator.Error!void {
    const top = topRow(ed);
    if (top == 0) return;
    const gc = ed.goalCol();
    try addExtra(ed, ed.byteAtVcol(top - 1, gc));
}

fn isId(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// VS Code's Ctrl+D. The first press selects the identifier under the
/// primary cursor; each later press adds a cursor at the next whole-word
/// occurrence past the bottom-most cursor, selected the same way.
pub fn addCursorAtNextWord(ed: *Editor) Allocator.Error!void {
    const t = ed.bytes();
    const probe = if (ed.cursor < t.len and isId(t[ed.cursor])) ed.cursor else if (ed.cursor > 0 and isId(t[ed.cursor - 1])) ed.cursor - 1 else return;
    const wb = select.wordBoundsAt(ed, probe);
    if (wb[0] == wb[1]) return;
    const word = t[wb[0]..wb[1]];
    const first_press = !hasExtras(ed) and !(ed.anchor == wb[0] and ed.cursor == wb[1]);
    if (first_press) {
        ed.anchor = wb[0];
        ed.cursor = wb[1];
        return;
    }
    var bottom = ed.cursor;
    for (ed.extra_cursors.items) |b| bottom = @max(bottom, b);
    var start = bottom;
    while (std.mem.indexOfPos(u8, t, start, word)) |pos| {
        const after = pos + word.len;
        const before_ok = pos == 0 or !isId(t[pos - 1]);
        const after_ok = after == t.len or !isId(t[after]);
        if (before_ok and after_ok and after > bottom) {
            try addExtra(ed, after);
            if (std.mem.indexOfScalar(usize, ed.extra_cursors.items, after)) |i| ed.extra_anchors.items[i] = pos;
            return;
        }
        start = ed.nextBoundary(pos);
    }
}

/// VS Code's Ctrl+Shift+L: the identifier under the primary cursor (or
/// the one it has selected) and every other whole-word occurrence of it
/// in the buffer, before the cursor too, each selected. The primary keeps
/// the occurrence it is on. No cap: one scan and one sort.
pub fn selectAllWordOccurrences(ed: *Editor) Allocator.Error!void {
    const t = ed.bytes();
    const probe = if (ed.cursor < t.len and isId(t[ed.cursor])) ed.cursor else if (ed.cursor > 0 and isId(t[ed.cursor - 1])) ed.cursor - 1 else return;
    const wb = select.wordBoundsAt(ed, probe);
    if (wb[0] == wb[1]) return;
    const word = t[wb[0]..wb[1]];
    ed.anchor = wb[0];
    ed.cursor = wb[1];
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    defer pairs.deinit(ed.gpa);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, t, start, word)) |pos| {
        const after = pos + word.len;
        const before_ok = pos == 0 or !isId(t[pos - 1]);
        const after_ok = after == t.len or !isId(t[after]);
        if (before_ok and after_ok) {
            if (pos != wb[0]) try pairs.append(ed.gpa, .{ .c = after, .a = pos });
            start = after;
        } else start = ed.nextBoundary(pos);
    }
    try commitExtras(ed, pairs.items);
}

// ─── motions ────────────────────────────────────────────────────────────

/// Run the motion once per extra with the cursor standing in for it;
/// each extra keeps its own goal column. The primary is untouched.
pub fn moveExtras(ed: *Editor, comptime f: fn (*Editor) void) Allocator.Error!void {
    if (!hasExtras(ed)) return;
    const saved_cursor = ed.cursor;
    const saved_goal = ed.goal_col;
    const pairs = try ed.gpa.alloc(Pair, ed.extra_cursors.items.len);
    defer ed.gpa.free(pairs);
    for (ed.extra_cursors.items, ed.extra_anchors.items, 0..) |c, a, i| {
        ed.cursor = c;
        ed.goal_col = null;
        f(ed);
        pairs[i] = .{ .c = ed.cursor, .a = a };
    }
    ed.cursor = saved_cursor;
    ed.goal_col = saved_goal;
    try commitExtras(ed, pairs);
}

// ─── the working set for edits ──────────────────────────────────────────

/// Every cursor and anchor, primary first, copied out so a fan-out can
/// shift them as it splices and commit them back in one go.
pub const Set = struct {
    gpa: Allocator,
    cursors: []usize,
    anchors: []?usize,

    pub fn take(ed: *const Editor) Allocator.Error!Set {
        const n = ed.extra_cursors.items.len + 1;
        const cs = try ed.gpa.alloc(usize, n);
        errdefer ed.gpa.free(cs);
        const as = try ed.gpa.alloc(?usize, n);
        cs[0] = ed.cursor;
        as[0] = ed.anchor;
        @memcpy(cs[1..], ed.extra_cursors.items);
        @memcpy(as[1..], ed.extra_anchors.items);
        return .{ .gpa = ed.gpa, .cursors = cs, .anchors = as };
    }

    pub fn deinit(s: *Set) void {
        s.gpa.free(s.cursors);
        s.gpa.free(s.anchors);
    }

    /// `[0]` becomes the primary; the rest are re-sorted extras.
    pub fn commit(s: *Set, ed: *Editor) Allocator.Error!void {
        ed.cursor = ed.snapBoundary(s.cursors[0]);
        ed.anchor = if (s.anchors[0]) |a| ed.snapBoundary(a) else null;
        const pairs = try s.gpa.alloc(Pair, s.cursors.len - 1);
        defer s.gpa.free(pairs);
        for (pairs, 1..) |*p, i| p.* = .{ .c = ed.snapBoundary(s.cursors[i]), .a = if (s.anchors[i]) |a| ed.snapBoundary(a) else null };
        try commitExtras(ed, pairs);
    }

    /// Cursor indices, highest byte first — the order edits must land in.
    fn orderDesc(s: *const Set) Allocator.Error![]usize {
        const order = try s.gpa.alloc(usize, s.cursors.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, @as([]const usize, s.cursors), struct {
            fn lt(cs: []const usize, a: usize, b: usize) bool {
                return cs[a] > cs[b];
            }
        }.lt);
        return order;
    }

    /// `[lo, hi)` was removed: `owner` lands at `lo`; everything past the
    /// range shifts down, anything inside it collapses onto `lo`.
    fn shiftAfterDelete(s: *Set, owner: ?usize, lo: usize, hi: usize) void {
        const removed = hi - lo;
        for (s.cursors, 0..) |*c, j| {
            if (owner == j) c.* = lo else if (c.* >= hi) c.* -= removed else if (c.* > lo) c.* = lo;
        }
        for (s.anchors) |*a| if (a.*) |av| {
            if (av >= hi) a.* = av - removed else if (av > lo) a.* = lo;
        };
    }

    /// `n` bytes were inserted at `at`: `owner` lands after them; other
    /// cursors and anchors at-or-past `at` shift up.
    fn shiftAfterInsert(s: *Set, owner: ?usize, at: usize, n: usize) void {
        for (s.cursors, 0..) |*c, j| {
            if (owner == j) c.* = at + n else if (c.* >= at) c.* += n;
        }
        for (s.anchors) |*a| if (a.*) |av| {
            if (av >= at) a.* = av + n;
        };
    }
};

/// Insert `s` at every cursor; each cursor lands after its own copy and
/// a selection anchor stays left of text inserted at its position.
pub fn insertStrAll(ed: *Editor, s: []const u8) Allocator.Error!void {
    var set = try Set.take(ed);
    defer set.deinit();
    const points = try ed.gpa.dupe(usize, set.cursors);
    defer ed.gpa.free(points);
    std.mem.sort(usize, points, {}, std.sort.desc(usize));
    var n: usize = 0;
    for (points) |p| {
        if (n > 0 and points[n - 1] == p) continue;
        points[n] = p;
        n += 1;
    }
    const unique = points[0..n];
    for (unique) |p| try ed.splice(p, p, s);
    for (set.cursors) |*c| {
        var k: usize = 0;
        for (unique) |p| if (p <= c.*) {
            k += 1;
        };
        c.* += k * s.len;
    }
    for (set.anchors) |*a| if (a.*) |av| {
        var k: usize = 0;
        for (unique) |p| if (p < av) {
            k += 1;
        };
        a.* = av + k * s.len;
    };
    try set.commit(ed);
}

/// Backspace at every cursor. Auto-pair is skipped across N cursors.
pub fn deleteBackwardAll(ed: *Editor) Allocator.Error!void {
    var set = try Set.take(ed);
    defer set.deinit();
    const order = try set.orderDesc();
    defer ed.gpa.free(order);
    for (order) |i| {
        const p = set.cursors[i];
        if (p == 0) continue;
        const prev = ed.prevBoundary(p);
        try ed.splice(prev, p, "");
        set.shiftAfterDelete(i, prev, p);
    }
    try set.commit(ed);
}

/// Delete forward at every cursor.
pub fn deleteForwardAll(ed: *Editor) Allocator.Error!void {
    var set = try Set.take(ed);
    defer set.deinit();
    const order = try set.orderDesc();
    defer ed.gpa.free(order);
    for (order) |i| {
        const p = set.cursors[i];
        if (p >= ed.len()) continue;
        const next = ed.nextBoundary(p);
        try ed.splice(p, next, "");
        set.shiftAfterDelete(i, p, next);
    }
    try set.commit(ed);
}

const Range = struct { idx: usize, lo: usize, hi: usize };

fn rangeDesc(_: void, a: Range, b: Range) bool {
    return a.lo > b.lo;
}

/// Delete one range per cursor. `rangeFor(ctx, ed, idx, p)` names the
/// range from the cursor's position before any edit; ranges land highest
/// first and overlapping ones are trimmed so every splice stays in bounds.
pub fn deleteRangePerCursor(ed: *Editor, context: anytype, comptime rangeFor: fn (@TypeOf(context), *const Editor, usize, usize) [2]usize) Allocator.Error!void {
    var set = try Set.take(ed);
    defer set.deinit();
    const ranges = try ed.gpa.alloc(Range, set.cursors.len);
    defer ed.gpa.free(ranges);
    for (set.cursors, 0..) |p, i| {
        const r = rangeFor(context, ed, i, p);
        ranges[i] = .{ .idx = i, .lo = ed.snapBoundary(@min(r[0], r[1])), .hi = ed.snapBoundary(@max(r[0], r[1])) };
    }
    std.mem.sort(Range, ranges, {}, rangeDesc);
    for (ranges, 0..) |r, k| {
        if (r.hi <= r.lo) continue;
        try ed.splice(r.lo, r.hi, "");
        set.shiftAfterDelete(r.idx, r.lo, r.hi);
        // Lower ranges that reached into this one end where it began.
        for (ranges[k + 1 ..]) |*rest| {
            if (rest.hi > r.lo) rest.hi = if (rest.hi >= r.hi) rest.hi - (r.hi - r.lo) else r.lo;
        }
    }
    try set.commit(ed);
}

/// Block-paste convention: `parts[i]` goes to the i-th cursor top to
/// bottom, after the cursor (`p`) or at it (`P`).
pub fn pasteDistribute(ed: *Editor, parts: []const []const u8, after: bool) Allocator.Error!void {
    var set = try Set.take(ed);
    defer set.deinit();
    std.debug.assert(parts.len == set.cursors.len);
    const order = try set.orderDesc();
    defer ed.gpa.free(order);
    // `order` is highest-first, so the visual rank of `order[k]` is `n-1-k`.
    const n = order.len;
    for (order, 0..) |i, k| {
        const c = @min(set.cursors[i], ed.len());
        const on_newline = c >= ed.len() or ed.bytes()[c] == '\n';
        const at = if (after and !on_newline) @min(ed.nextBoundary(c), ed.len()) else c;
        const payload = parts[n - 1 - k];
        try ed.splice(at, at, payload);
        set.shiftAfterInsert(i, at, payload.len);
    }
    try set.commit(ed);
}

/// Every non-empty selection, lowest first, joined by `\n` — the yank a
/// multi-cursor `y` / `d` writes. Caller frees.
pub fn joinedSelections(ed: *const Editor) Allocator.Error!?[]u8 {
    var ranges: std.ArrayList([2]usize) = .empty;
    defer ranges.deinit(ed.gpa);
    const n = ed.extra_cursors.items.len + 1;
    for (0..n) |i| {
        const p = if (i == 0) ed.cursor else ed.extra_cursors.items[i - 1];
        const r = ownRange({}, ed, i, p);
        if (r[1] > r[0]) try ranges.append(ed.gpa, r);
    }
    if (ranges.items.len == 0) return null;
    std.mem.sort([2]usize, ranges.items, {}, struct {
        fn lt(_: void, a: [2]usize, b: [2]usize) bool {
            return a[0] < b[0];
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ed.gpa);
    for (ranges.items, 0..) |r, i| {
        if (i > 0) try out.append(ed.gpa, '\n');
        try out.appendSlice(ed.gpa, ed.bytes()[r[0]..r[1]]);
    }
    return try out.toOwnedSlice(ed.gpa);
}

/// The bounding byte range of every selection — the inc-yank flash.
pub fn selectionsExtent(ed: *const Editor) ?[2]usize {
    var lo: ?usize = null;
    var hi: usize = 0;
    const n = ed.extra_cursors.items.len + 1;
    for (0..n) |i| {
        const p = if (i == 0) ed.cursor else ed.extra_cursors.items[i - 1];
        const r = ownRange({}, ed, i, p);
        if (r[1] <= r[0]) continue;
        lo = @min(lo orelse r[0], r[0]);
        hi = @max(hi, r[1]);
    }
    return if (lo) |l| .{ l, hi } else null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "add below/above stack from the outermost cursor; toggling removes; never on the primary" {
    const ed = try Editor.init(testing.allocator, "ab\ncd\nef\ngh");
    defer ed.deinit();
    ed.cursor = 1;
    try addCursorBelow(ed);
    try addCursorBelow(ed);
    try testing.expectEqualSlices(usize, &.{ 4, 7 }, ed.extra_cursors.items);
    try addCursorAbove(ed); // the primary is already the top row
    try testing.expectEqual(@as(usize, 2), ed.extra_cursors.items.len);
    try addExtra(ed, 4); // toggle off
    try testing.expectEqualSlices(usize, &.{7}, ed.extra_cursors.items);
    try addExtra(ed, 1); // the primary
    try testing.expectEqualSlices(usize, &.{7}, ed.extra_cursors.items);
    ed.cursor = 10;
    try addCursorBelow(ed); // nothing below the bottom-most cursor
    try testing.expectEqualSlices(usize, &.{7}, ed.extra_cursors.items);
    clear(ed);
    try testing.expect(!hasExtras(ed));
}

test "ctrl+d: first press selects the word, later presses add anchored cursors at whole-word matches" {
    const ed = try Editor.init(testing.allocator, "foo bar foo baz foobar foo");
    defer ed.deinit();
    ed.cursor = 1;
    try addCursorAtNextWord(ed);
    try testing.expectEqual(@as(?usize, 0), ed.anchor);
    try testing.expectEqual(@as(usize, 3), ed.cursor);
    try testing.expect(!hasExtras(ed));
    try addCursorAtNextWord(ed);
    try testing.expectEqualSlices(usize, &.{11}, ed.extra_cursors.items);
    try testing.expectEqual(@as(?usize, 8), ed.extra_anchors.items[0]);
    try addCursorAtNextWord(ed); // skips `foobar`
    try testing.expectEqualSlices(usize, &.{ 11, 26 }, ed.extra_cursors.items);
    try addCursorAtNextWord(ed); // no more
    try testing.expectEqual(@as(usize, 2), ed.extra_cursors.items.len);
}

test "ctrl+shift+l: from a bare cursor every whole-word occurrence is selected, before the cursor too, with no cap" {
    const ed = try Editor.init(testing.allocator, "foo x foo\nfoobar foo\n");
    defer ed.deinit();
    ed.cursor = 7; // inside the second `foo`
    try selectAllWordOccurrences(ed);
    try testing.expectEqual(@as(?usize, 6), ed.anchor);
    try testing.expectEqual(@as(usize, 9), ed.cursor);
    try testing.expectEqualSlices(usize, &.{ 3, 20 }, ed.extra_cursors.items);
    try testing.expectEqualSlices(?usize, &.{ 0, 17 }, ed.extra_anchors.items);
    // Past the old 4 097-round cap: every one of 5 000 lines.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (0..5000) |_| try big.appendSlice(testing.allocator, "a foo b\n");
    const ed2 = try Editor.init(testing.allocator, big.items);
    defer ed2.deinit();
    ed2.cursor = 2;
    try selectAllWordOccurrences(ed2);
    try testing.expectEqual(@as(usize, 4999), ed2.extra_cursors.items.len);
    // Nothing under the cursor: nothing selected.
    const ed3 = try Editor.init(testing.allocator, "a  b");
    defer ed3.deinit();
    ed3.cursor = 2;
    try selectAllWordOccurrences(ed3);
    try testing.expect(ed3.anchor == null);
}

test "insert, backspace, forward delete and range delete fan out and keep offsets straight" {
    const ed = try Editor.init(testing.allocator, "ab\ncd\nef");
    defer ed.deinit();
    ed.cursor = 1;
    try addExtra(ed, 4);
    try addExtra(ed, 7);
    try insertStrAll(ed, "XY");
    try testing.expectEqualStrings("aXYb\ncXYd\neXYf", ed.doc.text.items);
    try testing.expectEqual(@as(usize, 3), ed.cursor);
    try testing.expectEqualSlices(usize, &.{ 8, 13 }, ed.extra_cursors.items);
    try deleteBackwardAll(ed);
    try deleteBackwardAll(ed);
    try testing.expectEqualStrings("ab\ncd\nef", ed.doc.text.items);
    try testing.expectEqualSlices(usize, &.{ 4, 7 }, ed.extra_cursors.items);
    try deleteForwardAll(ed);
    try testing.expectEqualStrings("a\nc\ne", ed.doc.text.items);
    try testing.expectEqualSlices(usize, &.{ 3, 5 }, ed.extra_cursors.items);
    // Selections: anchor each at its line start, then delete the ranges.
    ed.anchor = 0;
    ed.extra_anchors.items[0] = 2;
    ed.extra_anchors.items[1] = 4;
    ed.cursor = 1;
    ed.extra_cursors.items[0] = 3;
    ed.extra_cursors.items[1] = 5;
    const joined = (try joinedSelections(ed)).?;
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("a\nc\ne", joined);
    try deleteRangePerCursor(ed, {}, ownRange);
    try testing.expectEqualStrings("\n\n", ed.doc.text.items);
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, ed.extra_cursors.items);
}

test "distributed paste pairs parts with cursors top to bottom; motions fan out" {
    const ed = try Editor.init(testing.allocator, "A.\nB.\nC.");
    defer ed.deinit();
    ed.cursor = 6;
    try addExtra(ed, 0);
    try addExtra(ed, 3);
    try pasteDistribute(ed, &.{ "A", "B", "C" }, false);
    try testing.expectEqualStrings("AA.\nBB.\nCC.", ed.doc.text.items);
    try testing.expectEqual(@as(usize, 9), ed.cursor);
    try testing.expectEqualSlices(usize, &.{ 1, 5 }, ed.extra_cursors.items);
    const motion = @import("motion.zig");
    try moveExtras(ed, motion.right);
    try testing.expectEqualSlices(usize, &.{ 2, 6 }, ed.extra_cursors.items);
    ed.cursor = 0;
    try moveExtras(ed, motion.lineStart);
    try testing.expectEqualSlices(usize, &.{4}, ed.extra_cursors.items); // one collided with the primary
}
