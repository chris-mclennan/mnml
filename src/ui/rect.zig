//! Rect — an axis-aligned cell rectangle in absolute screen coordinates.
//!
//! Layout is the parent's job: a component receives a Rect and carves it
//! with `splitTop` / `splitLeft` / `rightCells` / `inset`. Every split is
//! saturating, so an area that is too small yields empty rects instead of
//! panicking — a 20-column terminal must never take the process down.

const std = @import("std");

const Rect = @This();

x: u16 = 0,
y: u16 = 0,
w: u16 = 0,
h: u16 = 0,

pub const empty: Rect = .{};

pub fn init(x: u16, y: u16, w: u16, h: u16) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn isEmpty(r: Rect) bool {
    return r.w == 0 or r.h == 0;
}

pub fn area(r: Rect) u32 {
    return @as(u32, r.w) * r.h;
}

/// One past the last column.
pub fn right(r: Rect) u16 {
    return r.x +| r.w;
}

/// One past the last row.
pub fn bottom(r: Rect) u16 {
    return r.y +| r.h;
}

pub fn contains(r: Rect, x: u16, y: u16) bool {
    return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
}

pub fn eql(a: Rect, b: Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

/// The overlap of two rects; empty (w = h = 0) when they do not touch.
pub fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.right(), b.right());
    const y1 = @min(a.bottom(), b.bottom());
    if (x1 <= x0 or y1 <= y0) return .{ .x = x0, .y = y0 };
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Shrinks by `n` cells on every side. Collapses to empty when too small.
pub fn inset(r: Rect, n: u16) Rect {
    const dx = @min(n, r.w / 2);
    const dy = @min(n, r.h / 2);
    return .{
        .x = r.x + dx,
        .y = r.y + dy,
        .w = r.w -| (2 * n),
        .h = r.h -| (2 * n),
    };
}

pub const HSplit = struct { top: Rect, rest: Rect };
pub const VSplit = struct { left: Rect, rest: Rect };

/// Takes `n` rows off the top.
pub fn splitTop(r: Rect, n: u16) HSplit {
    const take = @min(n, r.h);
    return .{
        .top = .{ .x = r.x, .y = r.y, .w = r.w, .h = take },
        .rest = .{ .x = r.x, .y = r.y + take, .w = r.w, .h = r.h - take },
    };
}

/// Takes `n` rows off the bottom; `.top` is what remains above.
pub fn splitBottom(r: Rect, n: u16) HSplit {
    const take = @min(n, r.h);
    return .{
        .top = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - take },
        .rest = .{ .x = r.x, .y = r.y + (r.h - take), .w = r.w, .h = take },
    };
}

/// Takes `n` columns off the left.
pub fn splitLeft(r: Rect, n: u16) VSplit {
    const take = @min(n, r.w);
    return .{
        .left = .{ .x = r.x, .y = r.y, .w = take, .h = r.h },
        .rest = .{ .x = r.x + take, .y = r.y, .w = r.w - take, .h = r.h },
    };
}

/// Takes `n` columns off the right; `.left` is what remains.
pub fn splitRight(r: Rect, n: u16) VSplit {
    const take = @min(n, r.w);
    return .{
        .left = .{ .x = r.x, .y = r.y, .w = r.w - take, .h = r.h },
        .rest = .{ .x = r.x + (r.w - take), .y = r.y, .w = take, .h = r.h },
    };
}

/// The rightmost `n` columns (a chip slot on a header row).
pub fn rightCells(r: Rect, n: u16) Rect {
    return r.splitRight(n).rest;
}

/// Row `i` of the rect as a one-row rect; empty when out of range.
pub fn row(r: Rect, i: u16) Rect {
    if (i >= r.h) return .{ .x = r.x, .y = r.y +| i };
    return .{ .x = r.x, .y = r.y + i, .w = r.w, .h = 1 };
}

test "contains and edges" {
    const r = Rect.init(2, 3, 4, 2);
    try std.testing.expect(r.contains(2, 3));
    try std.testing.expect(r.contains(5, 4));
    try std.testing.expect(!r.contains(6, 4));
    try std.testing.expect(!r.contains(5, 5));
    try std.testing.expect(!r.contains(1, 3));
    try std.testing.expectEqual(@as(u16, 6), r.right());
    try std.testing.expectEqual(@as(u16, 5), r.bottom());
    try std.testing.expect(!r.isEmpty());
    try std.testing.expect(Rect.empty.isEmpty());
    try std.testing.expect(!Rect.empty.contains(0, 0));
}

test "intersect" {
    const a = Rect.init(0, 0, 10, 10);
    const b = Rect.init(5, 5, 10, 10);
    try std.testing.expect(a.intersect(b).eql(Rect.init(5, 5, 5, 5)));
    try std.testing.expect(a.intersect(Rect.init(10, 0, 5, 5)).isEmpty());
    try std.testing.expect(a.intersect(Rect.init(2, 2, 3, 3)).eql(Rect.init(2, 2, 3, 3)));
    try std.testing.expect(b.intersect(a).eql(a.intersect(b)));
}

test "inset collapses instead of underflowing" {
    const r = Rect.init(1, 1, 10, 4);
    try std.testing.expect(r.inset(1).eql(Rect.init(2, 2, 8, 2)));
    try std.testing.expect(r.inset(2).eql(Rect.init(3, 3, 6, 0)));
    try std.testing.expect(r.inset(2).isEmpty());
    try std.testing.expect(Rect.init(0, 0, 1, 1).inset(1).isEmpty());
    try std.testing.expect(Rect.empty.inset(3).isEmpty());
}

test "splitTop / splitBottom saturate" {
    const r = Rect.init(0, 0, 10, 5);
    const s = r.splitTop(1);
    try std.testing.expect(s.top.eql(Rect.init(0, 0, 10, 1)));
    try std.testing.expect(s.rest.eql(Rect.init(0, 1, 10, 4)));
    const big = r.splitTop(9);
    try std.testing.expect(big.top.eql(r));
    try std.testing.expect(big.rest.isEmpty());
    try std.testing.expectEqual(@as(u16, 5), big.rest.y);

    const b = r.splitBottom(2);
    try std.testing.expect(b.top.eql(Rect.init(0, 0, 10, 3)));
    try std.testing.expect(b.rest.eql(Rect.init(0, 3, 10, 2)));
    const bb = r.splitBottom(9);
    try std.testing.expect(bb.top.isEmpty());
    try std.testing.expect(bb.rest.eql(r));
}

test "splitLeft / splitRight / rightCells" {
    const r = Rect.init(3, 0, 10, 2);
    const l = r.splitLeft(4);
    try std.testing.expect(l.left.eql(Rect.init(3, 0, 4, 2)));
    try std.testing.expect(l.rest.eql(Rect.init(7, 0, 6, 2)));
    const rr = r.splitRight(3);
    try std.testing.expect(rr.left.eql(Rect.init(3, 0, 7, 2)));
    try std.testing.expect(rr.rest.eql(Rect.init(10, 0, 3, 2)));
    try std.testing.expect(r.rightCells(3).eql(rr.rest));
    try std.testing.expect(r.rightCells(20).eql(r));
    try std.testing.expect(r.splitLeft(20).rest.isEmpty());
}

test "row" {
    const r = Rect.init(1, 2, 5, 3);
    try std.testing.expect(r.row(0).eql(Rect.init(1, 2, 5, 1)));
    try std.testing.expect(r.row(2).eql(Rect.init(1, 4, 5, 1)));
    try std.testing.expect(r.row(3).isEmpty());
}
