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
    /// The header ladder's `?` — the key sheet's door for the pointer.
    /// The hint row's `? keys` says the same thing, and is the first
    /// entry a narrow pane drops.
    help,
    /// The toolbar's chips — the web bar's filters. A left click opens
    /// the chip's picker (`show` cycles), a right click lists every
    /// value with the live one ticked.
    status,
    author,
    target,
    show,
    run_by,
    branch,
    ptype,
    pstatus,
    trigger,
    /// The pipelines family's web-page actions.
    run_pipeline,
    schedules,
    caches,
    usage,
    /// The filter pill.
    filter,
    /// The header's API budget chip (`sdk.budget`): a click stops
    /// waiting out a 429's pause; the hover is the budget in full.
    budget,
};

pub const PrButton = enum { open, merge };

pub const Target = union(enum) {
    /// A tab on the strip.
    tab: usize,
    chip: Chip,
    /// A row of the list, by its index in this frame's `VisibleRow`s.
    row: usize,
    /// A build line under a pull request. Its own target rather than
    /// the row's, because the only thing a build line stands for is
    /// that run's page: a click on it goes there. The line is a table
    /// CELL in this pane and a free row in the tracker pane, and
    /// `sdk.pane.buildHit` is the one door both register.
    build_line: usize,
    /// The chevron at the head of a tree row — a repo header, or a
    /// pull request with builds to fold out. It is the row's own
    /// two cells, so a click there FOLDS while a click anywhere else
    /// on the row selects it, the way the tracker pane's tree works.
    chevron: usize,
    /// A chip on a pull-request row. A DIM `[ Merge ]` registers no
    /// target at all, so a stray click there cannot merge anything —
    /// but it does register `merge_blocked`, which is what lets a
    /// hover say why without letting a click do anything.
    pr_button: struct { row: usize, which: PrButton },
    merge_blocked: usize,
    /// The merge confirm's two chips and its body.
    confirm_ok,
    confirm_cancel,
    confirm_body,
    /// A key label on the hint row.
    hint: keymap.Action,
    /// A row of the open menu.
    menu_item: usize,
    /// A chip's picker: one of its rows, and its box (a click on the
    /// box is nothing; a click anywhere else closes it).
    picker_row: usize,
    picker_body,
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
