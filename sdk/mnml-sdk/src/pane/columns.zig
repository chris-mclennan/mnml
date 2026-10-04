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
//!
//! Wider than every preferred width, the spare goes first to the
//! columns whose cells are being cut — each column's `need`, the
//! longest visible cell, past its width — in proportion to what each is
//! short of and never past its need. A `fixed` column (a number, a
//! date) never grows. What is left after that is the `rest` column's,
//! or empty at the right: a table never ends a name in `…` with blank
//! cells beside it. Narrower than the preferred widths nothing changes:
//! a pane that had to shrink or drop a column lays out as it always has.

const std = @import("std");
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const text_mod = @import("text.zig");

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
    /// Cells the column's longest visible cell wants, header included;
    /// 0 = not measured. A column whose need is past its width is being
    /// cut, and is handed spare width before anything is left empty.
    need: u16 = 0,
    /// A number or a date: never wider than `w`, whatever its need.
    fixed: bool = false,

    fn floor(s: Spec) u16 {
        return if (s.min == 0 or s.min > s.w) s.w else s.min;
    }

    /// The cells this column is still short of at width `at`.
    fn short(s: Spec, at: u16) u16 {
        return if (s.fixed or s.need <= at) 0 else s.need - at;
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
    var dropped = false;
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
            // Spare cells go to the cut columns only when every column
            // is there: once one has been dropped the pane is narrow,
            // and lays out as it always has.
            const spare: u16 = @intCast(width - pref);
            widenRest(out, cols, if (dropped) spare else grow(out, cols, spare));
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
            dropped = true;
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

/// The column header row: each kept column's name in `Theme.label()`
/// (muted, bold), left-aligned in its width, with `gap` cells of air
/// between — the header the forge pane's tables wear, and every table
/// in the family with them. `cols` is any slice whose items carry
/// `name` and `w` (a pane's own column type, after `fit`). Each cell
/// of a column and its gap is painted, so the row is the header's
/// ground edge to edge rather than whatever was under it. Clipped at
/// `x0 + max_w`. Returns the cells painted.
///
/// A name that does not fit its column — squeezed by `fit`, or cut at
/// the row's end — ends in `…` (`text.fit`, the clipper list rows
/// use), never a bare `STAT`. `headerFor` is the `--ascii` twin.
///
/// A column of width 0 (a `rest` column with nothing left) paints its
/// name at its natural width, as far as the row allows.
pub fn header(f: *frame_mod.Frame, x0: u16, y: u16, max_w: u16, cols: anytype, gap: u16, th: theme_mod.Theme) u16 {
    return headerFor(f, x0, y, max_w, cols, gap, th, false);
}

/// `header`, with a cut name marked by `text.ellipsis(ascii)` — `...`
/// under `--ascii`.
pub fn headerFor(f: *frame_mod.Frame, x0: u16, y: u16, max_w: u16, cols: anytype, gap: u16, th: theme_mod.Theme, ascii: bool) u16 {
    const style = headerStyle(th);
    var x = x0;
    const end = x0 +| max_w;
    var buf: [256]u8 = undefined;
    for (cols, 0..) |c, i| {
        if (i > 0 and gap > 0) {
            if (x >= end) break;
            const w = @min(gap, end - x);
            f.fill(x, y, w, 1, style);
            _ = f.text(x, y, w, " ", style);
            x += w;
        }
        if (x >= end) break;
        const room = end - x;
        const cw: u16 = c.w;
        if (cw == 0) {
            x += f.text(x, y, room, text_mod.fitFor(&buf, c.name, room, ascii), style);
        } else {
            const w = @min(cw, room);
            f.fill(x, y, w, 1, style);
            _ = f.text(x, y, w, text_mod.fitFor(&buf, c.name, w, ascii), style);
            x += w;
        }
    }
    return x - x0;
}

/// The header's ink: `Theme.label()`.
pub fn headerStyle(th: theme_mod.Theme) frame_mod.Style {
    return th.label();
}

/// Hand `extra` spare cells to the kept columns being cut (`Spec.need`
/// past their width), in proportion to what each is short of, never
/// past its need. Returns what is left over: the `rest` column's, or
/// empty at the right.
fn grow(out: []u16, cols: []const Spec, extra: u16) u16 {
    var total: u32 = 0;
    for (cols, out) |c, o| if (o > 0) {
        total += c.short(o);
    };
    if (total == 0 or extra == 0) return extra;
    if (total <= extra) {
        for (cols, out) |c, *o| if (o.* > 0) {
            o.* += c.short(o.*);
        };
        return @intCast(extra - total);
    }
    var left: u32 = extra;
    for (cols, out) |c, *o| if (o.* > 0) {
        // Proportional, rounded down; the remainder is handed out below.
        const give: u16 = @intCast(@as(u32, extra) * c.short(o.*) / total);
        o.* += give;
        left -= give;
    };
    // What rounding left over, one cell at a time from the left, to the
    // columns still short.
    while (left > 0) {
        var moved = false;
        for (cols, out) |c, *o| if (o.* > 0 and left > 0 and c.short(o.*) > 0) {
            o.* += 1;
            left -= 1;
            moved = true;
        };
        if (!moved) break;
    }
    return @intCast(left);
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

// The loops table from a private pane: no rest column, the spare used
// to sit empty at the right while ITEM / KIND / RUNNER / USER were cut.
const loops = [_]Spec{
    .{ .w = 14, .min = 8 }, // ITEM
    .{ .w = 14, .min = 8, .drop = 4 }, // KIND
    .{ .w = 13, .min = 8, .drop = 3 }, // RUNNER
    .{ .w = 10, .min = 6, .drop = 2 }, // USER
    .{ .w = 10, .drop = 1 }, // LANE
    .{ .w = 6, .fixed = true }, // HELD
    .{ .w = 12, .fixed = true }, // EXPIRES
    .{ .w = 9, .fixed = true }, // ACTIVITY
};

fn withNeeds(comptime base: []const Spec, needs: []const u16) [base.len]Spec {
    var out: [base.len]Spec = undefined;
    for (base, needs, &out) |b, n, *o| {
        o.* = b;
        o.need = n;
    }
    return out;
}

test "wide: a cut column grows to its need, and what is left stays empty at the right" {
    const cols = withNeeds(&loops, &.{ 24, 22, 18, 12, 4, 6, 12, 9 });
    var out: [loops.len]u16 = undefined;
    fit(&out, &cols, 200, 1);
    try testing.expectEqualSlices(u16, &.{ 24, 22, 18, 12, 10, 6, 12, 9 }, &out);
    try testing.expect(sum(&out) + 7 < 200);
}

test "wide but short of every need: the spare is shared by what each is short of, none past its need" {
    const cols = withNeeds(&loops, &.{ 34, 24, 23, 10, 4, 6, 12, 9 });
    var out: [loops.len]u16 = undefined;
    // Preferred 88 + 7 gaps = 95; 15 spare against 20 + 10 + 10 short.
    fit(&out, &cols, 110, 1);
    try testing.expectEqual(@as(u32, 110 - 7), sum(&out));
    try testing.expectEqualSlices(u16, &.{ 22, 18, 16, 10, 10, 6, 12, 9 }, &out);
    for (out, cols) |o, c| if (c.need > c.w) try testing.expect(o <= c.need);
}

test "with a rest column, the cut columns are fed first and the rest column takes what is left" {
    var cols = tracker;
    cols[1].need = 22; // STATUS: "Waiting for review" and its air
    cols[2].need = 15; // ASSIGNEE: shorter than its width — never shrinks for it
    var out: [tracker.len]u16 = undefined;
    fit(&out, &cols, 118, 0);
    try testing.expectEqualSlices(u16, &.{ 18, 22, 20, 12, 46 }, &out);
}

test "a fixed column never grows, whatever it needs" {
    var cols = withNeeds(&loops, &.{ 14, 14, 13, 10, 10, 40, 40, 40 });
    var out: [loops.len]u16 = undefined;
    fit(&out, &cols, 200, 1);
    try testing.expectEqualSlices(u16, &.{ 14, 14, 13, 10, 10, 6, 12, 9 }, &out);
    cols[6].fixed = false;
    fit(&out, &cols, 200, 1);
    try testing.expectEqual(@as(u16, 40), out[6]);
}

fn expectSameNarrow(comptime n: usize, plain: []const Spec, measured: []const Spec, pref: u16, gap: u16) !void {
    var a: [n]u16 = undefined;
    var b: [n]u16 = undefined;
    var w: u16 = 0;
    while (w < pref) : (w += 1) {
        fit(&a, plain, w, gap);
        fit(&b, measured, w, gap);
        try testing.expectEqualSlices(u16, &a, &b);
    }
}

test "narrow: measured needs change nothing — every width short of the preferred lays out as before" {
    const measured = withNeeds(&loops, &.{ 34, 24, 23, 12, 10, 20, 20, 20 });
    try expectSameNarrow(loops.len, &loops, &measured, 95, 1);
    var tr = tracker;
    for (&tr) |*c| c.need = 60;
    try expectSameNarrow(tracker.len, &tracker, &tr, 84, 0);
}

test "the column header: names in label ink, fitted to their widths, air between, cut at the row's end" {
    const Col = struct { name: []const u8, w: u16 };
    var f = try frame_mod.Frame.init(testing.allocator, 30, 1);
    defer f.deinit();
    const th = theme_mod.Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } } });
    const cols = [_]Col{ .{ .name = "KEY", .w = 6 }, .{ .name = "STATUS", .w = 4 }, .{ .name = "SUMMARY", .w = 20 } };
    try testing.expectEqual(@as(u16, 28), header(&f, 1, 0, 28, &cols, 1, th));
    var row: [64]u8 = undefined;
    var n: usize = 0;
    for (f.slots[0..30]) |s| {
        const g = s.symbol();
        @memcpy(row[n..][0..g.len], g);
        n += g.len;
    }
    // STATUS is fitted to its four cells with an ellipsis; SUMMARY fits
    // whole before the row's end.
    try testing.expectEqualStrings(" KEY    STA\u{2026} SUMMARY          ", row[0..n]);
    for (1..29) |x| try testing.expect(std.meta.eql(f.slots[x].style, th.label()));
    try testing.expect(!std.meta.eql(f.slots[29].style, th.label()));
}

fn rowText(buf: []u8, f: *const frame_mod.Frame, y: u16) []const u8 {
    var n: usize = 0;
    for (f.slots[@as(usize, y) * f.cols ..][0..f.cols]) |s| {
        const g = s.symbol();
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

test "a squeezed header ends in an ellipsis, `...` under --ascii; a header that fits is unchanged" {
    const Col = struct { name: []const u8, w: u16 };
    const th = theme_mod.Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } } });
    var row: [256]u8 = undefined;
    // At 30 columns the last column is squeezed: the Bitbucket PR
    // table's CI and STATUS at the tail of a narrow pane.
    const squeezed = [_]Col{ .{ .name = "PR", .w = 5 }, .{ .name = "TITLE", .w = 14 }, .{ .name = "STATUS", .w = 8 } };
    {
        var f = try frame_mod.Frame.init(testing.allocator, 30, 2);
        defer f.deinit();
        _ = header(&f, 0, 0, 25, &squeezed, 1, th);
        _ = headerFor(&f, 0, 1, 25, &squeezed, 1, th, true);
        // STATUS gets the row's last four cells: `STA…`, not `STAT`.
        try testing.expectEqualStrings("PR    TITLE          STA\u{2026}", std.mem.trimEnd(u8, rowText(&row, &f, 0), " "));
        try testing.expectEqualStrings("PR    TITLE          S...", std.mem.trimEnd(u8, rowText(&row, &f, 1), " "));
        // The mark is header ink, like the rest of the name.
        try testing.expect(std.meta.eql(f.slots[24].style, th.label()));
    }
    {
        // A column narrower than its name, mid-row.
        const cols = [_]Col{ .{ .name = "UPDATED", .w = 5 }, .{ .name = "CA", .w = 2 } };
        var f = try frame_mod.Frame.init(testing.allocator, 12, 2);
        defer f.deinit();
        _ = header(&f, 0, 0, 12, &cols, 1, th);
        _ = headerFor(&f, 0, 1, 12, &cols, 1, th, true);
        try testing.expectEqualStrings("UPDA\u{2026} CA    ", rowText(&row, &f, 0));
        try testing.expectEqualStrings("UP... CA    ", rowText(&row, &f, 1));
    }
    {
        // Wide enough: every name whole, no mark anywhere, either twin.
        var f = try frame_mod.Frame.init(testing.allocator, 40, 2);
        defer f.deinit();
        _ = header(&f, 0, 0, 40, &squeezed, 1, th);
        _ = headerFor(&f, 0, 1, 40, &squeezed, 1, th, true);
        var row2: [256]u8 = undefined;
        try testing.expectEqualStrings("PR    TITLE          STATUS", std.mem.trimEnd(u8, rowText(&row, &f, 0), " "));
        try testing.expectEqualStrings(rowText(&row, &f, 0), rowText(&row2, &f, 1));
    }
}
