//! HitMap — the pane's click targets, registered by the painter that
//! drew them, in the same statement as the cells. Mouse dispatch is
//! then one `switch` on `at(col, row)`; there is no second bookkeeping
//! to keep in step with the paint, which is how the reference came to
//! select the row under the one you clicked. `at` scans back to front,
//! so an overlay painted after the list wins the click.

const std = @import("std");
const Allocator = std.mem.Allocator;
const keymap = @import("keymap.zig");

pub const Chip = enum {
    refresh,
    /// The PR family's `author:` chip (mine ↔ all).
    author,
    /// The pipelines family's web-page actions.
    run_pipeline,
    schedules,
    caches,
    usage,
    /// The filter pill.
    filter,
};

pub const Target = union(enum) {
    /// A tab on the strip.
    tab: usize,
    chip: Chip,
    /// A row of the list, by its index in this frame's `VisibleRow`s.
    row: usize,
    /// A key label on the hint row.
    hint: keymap.Action,
    /// A row of the open menu.
    menu_item: usize,
    /// The detail panel's body (a wheel there scrolls it).
    detail,
    /// The key sheet (any click closes it).
    sheet,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(r: Rect, col: u16, row: u16) bool {
        return col >= r.x and col < r.x +| r.w and row >= r.y and row < r.y +| r.h;
    }
};

pub const Entry = struct { rect: Rect, target: Target };

pub const HitMap = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) HitMap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *HitMap) void {
        m.entries.deinit(m.gpa);
        m.* = undefined;
    }

    /// The top of a frame: nothing is registered yet.
    pub fn reset(m: *HitMap) void {
        m.entries.clearRetainingCapacity();
    }

    /// Register `target` over `rect`; an empty rect registers nothing.
    pub fn add(m: *HitMap, rect: Rect, target: Target) void {
        if (rect.w == 0 or rect.h == 0) return;
        m.entries.append(m.gpa, .{ .rect = rect, .target = target }) catch {};
    }

    /// The target under a cell — the last one painted there.
    pub fn at(m: *const HitMap, col: u16, row: u16) ?Target {
        var i = m.entries.items.len;
        while (i > 0) : (i -= 1) {
            const e = m.entries.items[i - 1];
            if (e.rect.contains(col, row)) return e.target;
        }
        return null;
    }

    /// Where a target was painted (its first rect), for a test.
    pub fn rectOf(m: *const HitMap, target: Target) ?Rect {
        for (m.entries.items) |e| if (std.meta.eql(e.target, target)) return e.rect;
        return null;
    }

    pub fn count(m: *const HitMap) usize {
        return m.entries.items.len;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the last thing painted over a cell owns the click; an empty rect is not a target" {
    var m = HitMap.init(t.allocator);
    defer m.deinit();
    m.add(.{ .x = 0, .y = 4, .w = 80, .h = 1 }, .{ .row = 0 });
    m.add(.{ .x = 0, .y = 5, .w = 80, .h = 1 }, .{ .row = 1 });
    m.add(.{ .x = 10, .y = 3, .w = 20, .h = 4 }, .sheet);
    m.add(.{ .x = 0, .y = 9, .w = 0, .h = 1 }, .{ .row = 9 });
    try t.expectEqual(Target{ .row = 1 }, m.at(0, 5).?);
    try t.expectEqual(Target.sheet, m.at(12, 5).?);
    try t.expect(m.at(0, 9) == null);
    try t.expect(m.at(79, 4) != null);
    try t.expect(m.at(80, 4) == null);
    try t.expectEqual(@as(u16, 5), m.rectOf(.{ .row = 1 }).?.y);
    m.reset();
    try t.expectEqual(@as(usize, 0), m.count());
    try t.expect(m.at(0, 4) == null);
}
