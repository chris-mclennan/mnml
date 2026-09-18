//! The pane's hit map — what the frame's cells mean to a click, written
//! by the painter in the same statement as the cells. A target covers
//! exactly what it paints: a row is its row, a chip its cells, a chevron
//! its one cell, a hint entry its `key label`. Dispatch is one lookup;
//! the last thing painted wins, so an overlay drawn after the body takes
//! the click.
//!
//! `Map` is generic over the pane's own target union, so an integration
//! keeps its vocabulary and shares the bookkeeping.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(r: Rect, x: u16, y: u16) bool {
        return x >= r.x and x < r.x +| r.w and y >= r.y and y < r.y +| r.h;
    }

    pub fn right(r: Rect) u16 {
        return r.x +| r.w;
    }

    pub fn bottom(r: Rect) u16 {
        return r.y +| r.h;
    }

    pub fn isEmpty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }
};

pub fn Map(comptime Target: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { rect: Rect, target: Target };

        items: std.ArrayList(Entry) = .empty,

        pub fn deinit(m: *Self, gpa: Allocator) void {
            m.items.deinit(gpa);
        }

        /// The top of a frame: nothing is registered yet.
        pub fn reset(m: *Self) void {
            m.items.clearRetainingCapacity();
        }

        pub fn add(m: *Self, gpa: Allocator, rect: Rect, target: Target) Allocator.Error!void {
            if (rect.isEmpty()) return;
            try m.items.append(gpa, .{ .rect = rect, .target = target });
        }

        /// Back to front: the last painted wins.
        pub fn at(m: *const Self, x: u16, y: u16) ?Target {
            var i = m.items.items.len;
            while (i > 0) {
                i -= 1;
                const e = m.items.items[i];
                if (e.rect.contains(x, y)) return e.target;
            }
            return null;
        }

        /// Where a target painted, for a test that clicks by meaning.
        pub fn rectOf(m: *const Self, target: Target) ?Rect {
            var i = m.items.items.len;
            while (i > 0) {
                i -= 1;
                const e = m.items.items[i];
                if (std.meta.eql(e.target, target)) return e.rect;
            }
            return null;
        }

        pub fn count(m: *const Self) usize {
            return m.items.items.len;
        }
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const Demo = union(enum) { row: u32, chevron: u32 };

test "the last thing painted wins, an empty rect is never a target, rectOf finds a target by meaning" {
    var m: Map(Demo) = .{};
    defer m.deinit(testing.allocator);
    try m.add(testing.allocator, .{ .x = 0, .y = 2, .w = 40, .h = 1 }, .{ .row = 1 });
    try m.add(testing.allocator, .{ .x = 4, .y = 2, .w = 1, .h = 1 }, .{ .chevron = 1 });
    try m.add(testing.allocator, .{ .x = 0, .y = 3, .w = 0, .h = 1 }, .{ .row = 2 });
    try testing.expectEqual(Demo{ .chevron = 1 }, m.at(4, 2).?);
    try testing.expectEqual(Demo{ .row = 1 }, m.at(5, 2).?);
    try testing.expect(m.at(5, 3) == null);
    try testing.expect(m.at(39, 2) != null and m.at(40, 2) == null);
    try testing.expectEqual(@as(u16, 4), m.rectOf(.{ .chevron = 1 }).?.x);
    try testing.expect(m.rectOf(.{ .row = 9 }) == null);
    try testing.expectEqual(@as(usize, 2), m.count());
    m.reset();
    try testing.expect(m.at(5, 2) == null);
}
