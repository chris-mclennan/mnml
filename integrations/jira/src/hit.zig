//! The pane's hit map — what the frame's cells mean to a click, written
//! by the painter in the same statement as the cells (the shape of
//! mnml's own `ui/hit.zig`). A target covers exactly what it paints: a
//! row is its row, a chip its cells, a chevron its one cell, a picker
//! entry its line. Dispatch is one lookup; the last thing painted wins,
//! so an overlay drawn after the body takes the click.

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

/// The header and toolbar chips. One enum for both families' toolbars.
pub const Chip = enum {
    refresh,
    help,
    basic,
    jql,
    search,
    space,
    assignee,
    type,
    status,
    more_filters,
    save_filter,
    fixv_pill,
    fixv_remove,
    board,
    sprint,
    version,
    epic,
    label,
    quick_filters,
    unassigned,
    overflow,
    settings,
};

pub const PrButton = enum { review, merge, open };

pub const Target = union(enum) {
    /// A list / tree row, by its index in the row list.
    row: u32,
    /// The row's chevron — folds without selecting the row's URL.
    chevron: u32,
    /// A `Show all N PRs` row.
    show_more: u32,
    /// A `[ Review ]` / `[ Merge ]` / `[ Open ]` chip on a PR row.
    pr_button: struct { row: u32, which: PrButton },
    /// An action button on a ticket row / card.
    action: struct { issue: u32, button: u8 },
    tab: u8,
    chip: Chip,
    /// An avatar in the kanban toolbar's cluster, by cache index.
    avatar: u32,
    /// The filter pill.
    filter,
    /// A kanban card's body / chevron, by ticket index.
    card: u32,
    card_chevron: u32,
    /// A kanban column's body, for the wheel.
    column: u8,
    /// A picker's rows and its box.
    picker_row: u32,
    picker_body,
    /// The detail modal's close chip and body.
    modal_close,
    modal_body,
    /// The JQL editor's text: the cell index the click maps to.
    jql_text: struct { col: u16, row: u16 },
    jql_body,
    /// The key sheet.
    help_body,
    /// The detail pane's body (the wheel scrolls it).
    detail,
    /// The comment editor.
    comment,
};

pub const Entry = struct { rect: Rect, target: Target };

pub const Map = struct {
    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(m: *Map, gpa: Allocator) void {
        m.items.deinit(gpa);
    }

    pub fn reset(m: *Map) void {
        m.items.clearRetainingCapacity();
    }

    pub fn add(m: *Map, gpa: Allocator, rect: Rect, target: Target) Allocator.Error!void {
        if (rect.isEmpty()) return;
        try m.items.append(gpa, .{ .rect = rect, .target = target });
    }

    /// Back to front: the last painted wins.
    pub fn at(m: *const Map, x: u16, y: u16) ?Target {
        var i = m.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = m.items.items[i];
            if (e.rect.contains(x, y)) return e.target;
        }
        return null;
    }

    /// Where a target painted, for a test that clicks by meaning.
    pub fn rectOf(m: *const Map, target: Target) ?Rect {
        var i = m.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = m.items.items[i];
            if (std.meta.eql(e.target, target)) return e.rect;
        }
        return null;
    }

    pub fn count(m: *const Map) usize {
        return m.items.items.len;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the last thing painted wins, an empty rect is never a target, rectOf finds a target by meaning" {
    var m: Map = .{};
    defer m.deinit(testing.allocator);
    try m.add(testing.allocator, .{ .x = 0, .y = 2, .w = 40, .h = 1 }, .{ .row = 1 });
    try m.add(testing.allocator, .{ .x = 4, .y = 2, .w = 1, .h = 1 }, .{ .chevron = 1 });
    try m.add(testing.allocator, .{ .x = 0, .y = 3, .w = 0, .h = 1 }, .{ .row = 2 });
    try testing.expectEqual(Target{ .chevron = 1 }, m.at(4, 2).?);
    try testing.expectEqual(Target{ .row = 1 }, m.at(5, 2).?);
    try testing.expect(m.at(5, 3) == null);
    try testing.expect(m.at(39, 2) != null and m.at(40, 2) == null);
    try testing.expectEqual(@as(u16, 4), m.rectOf(.{ .chevron = 1 }).?.x);
    try testing.expect(m.rectOf(.{ .row = 9 }) == null);
    try testing.expectEqual(@as(usize, 2), m.count());
    m.reset();
    try testing.expect(m.at(5, 2) == null);
}
