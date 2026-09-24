//! How a pane's table gives way when the pane is narrow — one rule, so
//! two integrations side by side in a split degrade the same way.
//!
//! Each column has a preferred width, a floor it may shrink to, a drop
//! rank, and at most one takes the rest. At a width where everything
//! fits, every column gets its preferred width and the `rest` column the
//! remainder. Narrower, the shrinkable columns give up cells together,
//! in proportion to what they can spare, down to their floors. Narrower
//! still, the lowest-ranked droppable column goes WHOLE (rank 1 first,
//! 0 never) and the widths are worked out again. Only when nothing is
//! left to drop does the `rest` column itself shrink — so the column a
//! row is known by (a ticket's key, a pull request's number) keeps
//! every cell it needs, and a long summary is what is elided.
//!
//! A column is never painted half-wide with its neighbour's header run
//! into it: it is either there at a readable width, or gone.

const std = @import("std");

pub const Spec = struct {
    /// Preferred width, cells (the `rest` column's: the least it wants
    /// before anything else gives way for it).
    w: u16,
    /// The narrowest this column is still readable at; 0 = `w` (it does
    /// not shrink).
    min: u16 = 0,
    /// Dropped in rank order when the width runs out: 1 first, 0 never.
    drop: u8 = 0,
    /// Takes what is left.
    rest: bool = false,

    fn floor(s: Spec) u16 {
        return if (s.min == 0 or s.min > s.w) s.w else s.min;
    }
};

/// Lay `cols` into `width` cells with `gap` cells between kept columns.
/// `out[i]` is column i's width; 0 means dropped. `out.len == cols.len`.
pub fn fit(out: []u16, cols: []const Spec, width: u16, gap: u16) void {
    std.debug.assert(out.len == cols.len);
    var kept_buf: [32]bool = undefined;
    std.debug.assert(cols.len <= kept_buf.len);
    const kept = kept_buf[0..cols.len];
    @memset(kept, true);
    while (true) {
        var pref: u32 = 0;
        var floor: u32 = 0;
        var n: u32 = 0;
        for (cols, kept) |c, k| if (k) {
            pref += c.w;
            floor += c.floor();
            n += 1;
        };
        const gaps: u32 = if (n > 0) (n - 1) * gap else 0;
        pref += gaps;
        floor += gaps;
        if (pref <= width) {
            for (cols, kept, out) |c, k, *o| o.* = if (k) c.w else 0;
            widenRest(out, cols, @intCast(width - pref));
            return;
        }
        if (floor <= width) {
            shrink(out, cols, kept, @intCast(pref - width));
            return;
        }
        // Drop the lowest-ranked droppable column still kept.
        var victim: ?usize = null;
        for (cols, kept, 0..) |c, k, i| if (k and c.drop > 0) {
            if (victim == null or c.drop < cols[victim.?].drop) victim = i;
        };
        if (victim) |v| {
            kept[v] = false;
            continue;
        }
        // Nothing left to drop: everything at its floor, and the rest
        // column gives up what is still missing.
        for (cols, kept, out) |c, k, *o| o.* = if (k) c.floor() else 0;
        var over: u32 = floor - width;
        for (cols, out) |c, *o| if (c.rest and o.* > 0) {
            const give: u16 = @intCast(@min(over, o.*));
            o.* -= give;
            over -= give;
        };
        return;
    }
}

fn widenRest(out: []u16, cols: []const Spec, extra: u16) void {
    for (cols, out) |c, *o| if (c.rest and o.* > 0) {
        o.* += extra;
        return;
    };
}

/// Take `excess` cells off the kept shrinkable columns, in proportion to
/// what each can spare above its floor. The rest column is not touched:
/// it is already at the least it asked for.
fn shrink(out: []u16, cols: []const Spec, kept: []const bool, excess: u32) void {
    var spare: u32 = 0;
    for (cols, kept, out) |c, k, *o| {
        o.* = if (k) c.w else 0;
        if (k and !c.rest) spare += c.w - c.floor();
    }
    if (spare == 0) return;
    var left = excess;
    var given: u32 = 0;
    for (cols, kept, out) |c, k, *o| if (k and !c.rest) {
        const can = c.w - c.floor();
        if (can == 0) continue;
        // Proportional, rounded down; the remainder is taken below.
        const take: u32 = @min(can, excess * can / spare);
        o.* -= @intCast(take);
        given += take;
    };
    left -= @min(left, given);
    // What rounding left over, one cell at a time from the left.
    while (left > 0) {
        var moved = false;
        for (cols, kept, out) |c, k, *o| if (k and !c.rest and o.* > c.floor() and left > 0) {
            o.* -= 1;
            left -= 1;
            moved = true;
        };
        if (!moved) break;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn sum(xs: []const u16) u32 {
    var n: u32 = 0;
    for (xs) |x| n += x;
    return n;
}

const tracker = [_]Spec{
    .{ .w = 18, .min = 12 }, // KEY — never dropped
    .{ .w = 14, .min = 8, .drop = 8 }, // STATUS
    .{ .w = 20, .min = 10, .drop = 6 }, // ASSIGNEE
    .{ .w = 12, .min = 11, .drop = 7 }, // UPDATED
    .{ .w = 20, .rest = true }, // SUMMARY
};

test "wide: every column at its width, the rest column takes the remainder" {
    var out: [tracker.len]u16 = undefined;
    fit(&out, &tracker, 118, 0);
    try testing.expectEqualSlices(u16, &.{ 18, 14, 20, 12, 54 }, &out);
}

test "a little narrower: the columns give up cells together, nothing is dropped" {
    var out: [tracker.len]u16 = undefined;
    fit(&out, &tracker, 78, 0);
    try testing.expectEqual(@as(u32, 78), sum(&out));
    for (out, tracker) |o, c| try testing.expect(o >= c.floor());
    try testing.expectEqual(@as(u16, 20), out[4]);
}

test "half a split: ASSIGNEE goes whole before the key loses a cell; narrower, UPDATED too" {
    var out: [tracker.len]u16 = undefined;
    fit(&out, &tracker, 58, 0);
    try testing.expectEqual(@as(u16, 0), out[2]);
    try testing.expect(out[0] >= 12 and out[3] >= 11);
    try testing.expectEqual(@as(u32, 58), sum(&out));
    fit(&out, &tracker, 41, 0);
    try testing.expectEqual(@as(u16, 0), out[2]);
    try testing.expectEqual(@as(u16, 0), out[3]);
    try testing.expect(out[0] >= 12);
    try testing.expectEqual(@as(u32, 41), sum(&out));
}

test "nothing left to drop: the key keeps its floor and the rest column is what shrinks" {
    var out: [tracker.len]u16 = undefined;
    fit(&out, &tracker, 16, 0);
    try testing.expectEqual(@as(u16, 12), out[0]);
    try testing.expectEqual(@as(u16, 0), out[1]);
    try testing.expectEqual(@as(u16, 4), out[4]);
}

test "columns that do not shrink are dropped whole in rank order, gaps counted (the forge table)" {
    const forge = [_]Spec{
        .{ .w = 28 },
        .{ .w = 10, .drop = 4 },
        .{ .w = 18, .drop = 2 },
        .{ .w = 22, .drop = 1 },
        .{ .w = 12, .drop = 3 },
        .{ .w = 20, .rest = true },
    };
    var out: [forge.len]u16 = undefined;
    fit(&out, &forge, 115, 1);
    try testing.expectEqualSlices(u16, &.{ 28, 10, 18, 22, 12, 20 }, &out);
    fit(&out, &forge, 80, 1);
    try testing.expectEqualSlices(u16, &.{ 28, 10, 0, 0, 12, 27 }, &out);
    fit(&out, &forge, 40, 1);
    try testing.expectEqualSlices(u16, &.{ 28, 0, 0, 0, 0, 11 }, &out);
}
