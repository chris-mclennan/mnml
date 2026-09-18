//! HitMap — the pane's click targets, registered by the painter that
//! drew them, in the same statement as the cells. Mouse dispatch is
//! then one `switch` on `at(col, row)`; there is no second bookkeeping
//! to keep in step with the paint, which is how the reference came to
//! select the row under the one you clicked. `at` scans back to front,
//! so an overlay painted after the list wins the click.

const std = @import("std");
const Allocator = std.mem.Allocator;
const keymap = @import("keymap.zig");
const sdk = @import("mnml_sdk");

pub const Chip = enum {
    refresh,
    /// The PR family's `author:` chip (mine ↔ all).
    author,
    /// `awaiting: N` — the open pull requests waiting on YOUR review.
    awaiting,
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
    /// The detail panel's body (a wheel there scrolls it), its `\u{d7}`
    /// and its scrollbar (a press or a drag on the track scrolls it).
    detail,
    detail_close,
    detail_bar,
    /// The key sheet, and one of its rows — clicking a row runs what
    /// its chord runs.
    sheet,
    sheet_row: keymap.Action,
};

pub const Rect = sdk.pane.Rect;

/// The map itself is the SDK's (`sdk.pane.HitMap`), generic over the
/// targets above — the same implementation the Jira pane registers into,
/// so "the last thing painted wins" means the same thing in both.
pub const Inner = sdk.pane.HitMap(Target);
pub const Entry = Inner.Entry;

/// The pane keeps its own handle so a painter can `add` without passing
/// an allocator at every call site, the way this pane has always done.
pub const HitMap = struct {
    gpa: Allocator,
    inner: Inner = .{},

    pub fn init(gpa: Allocator) HitMap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *HitMap) void {
        m.inner.deinit(m.gpa);
        m.* = undefined;
    }

    pub fn reset(m: *HitMap) void {
        m.inner.reset();
    }

    pub fn add(m: *HitMap, rect: Rect, target: Target) void {
        m.inner.add(m.gpa, rect, target) catch {};
    }

    pub fn at(m: *const HitMap, col: u16, row: u16) ?Target {
        return m.inner.at(col, row);
    }

    pub fn rectOf(m: *const HitMap, target: Target) ?Rect {
        return m.inner.rectOf(target);
    }

    pub fn count(m: *const HitMap) usize {
        return m.inner.count();
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
