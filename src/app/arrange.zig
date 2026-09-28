//! Where a newly-opened pane lands, and how big it is. One rule, so
//! that an integration, a terminal and a session pane all arrange the
//! same way — they used to differ: an integration evened its splits
//! out (`integrations.equalize_on_open`), a terminal halved whatever
//! pane had the focus and left the rest alone, so the third terminal
//! took a quarter of the screen and the fourth an eighth.
//!
//! `integrations.arrange` picks the rule:
//!
//! - `.context` — an empty editor area takes the pane FULL (a grid's
//!   `.empty` slot is filled rather than split around), and otherwise
//!   the pane splits the active one and `equalizeAxis` evens every
//!   sibling along that split's axis. A stack across the axis keeps
//!   its own proportions.
//! - `.fixed` — what the two paths did before, each in its own way:
//!   the new pane halves the active one, and the caller's legacy
//!   equalize (an integration's `equalize_on_open`, else
//!   `ui.auto_equalize_splits` through `App.afterSplitChange`) has the
//!   last word.
//!
//! Direction is the caller's: `term.shell_left` means left. There is
//! no direction knob to read, so none is invented here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const layout_mod = @import("layout.zig");

pub const Opts = struct {
    dir: layout_mod.SplitDir,
    /// The new leaf goes BEFORE the anchor (left / above) instead of
    /// after it.
    before: bool = false,
    /// `.fixed` only: equalize the whole tree whatever
    /// `ui.auto_equalize_splits` says. An integration's
    /// `equalize_on_open` is the one caller that asks for it.
    fixed_equalize: bool = false,
};

/// Put `id` beside the active pane. Returns the new leaf, or null when
/// the pane took the area whole (nothing to split against) — the
/// caller's own fallbacks (`.tab`, a failed split) never reach here.
pub fn splitActive(app: *App, id: PaneId, opts: Opts) Allocator.Error!?layout_mod.NodeId {
    const layout = app.layouts.current();
    const anchor: ?PaneId = if (app.active) |a| (if (layout.leafOf(a) != null) a else null) else null;
    // Nothing to split against: the pane opens full. A grid slot held
    // open for it is filled — never split against a placeholder.
    if (anchor == null) {
        if ((try layout.fillFirstEmpty(id)) != null) app.setActive(id) else app.showPane(id);
        return null;
    }
    const new_leaf = (try layout.split(anchor.?, opts.dir, id)) orelse {
        app.showPane(id);
        return null;
    };
    const parent = layout.parentOf(new_leaf);
    if (opts.before) if (parent) |p| {
        // `split` puts the new leaf second; swap the halves.
        const s = &layout.node(p).split;
        std.mem.swap(layout_mod.NodeId, &s.first, &s.second);
    };
    switch (app.cfg.integrations.arrange) {
        .context => if (parent) |p| layout.equalizeAxis(p),
        .fixed => if (opts.fixed_equalize) layout.equalize() else app.afterSplitChange(),
    }
    app.setActive(id);
    return new_leaf;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Rect = @import("../ui/rect.zig");

/// A pane in the store but in no leaf — what every "open a new pane"
/// path has in its hand when it calls `splitActive`.
fn spare(app: *App) !PaneId {
    const keep = app.active;
    const id = try app.openScratch();
    _ = app.layouts.current().removePane(id);
    app.setActive(keep);
    return id;
}

/// The pane widths (or heights) left to right / top to bottom.
fn spans(app: *App, horizontal: bool) ![]u16 {
    const a = app.frame.allocator();
    const rects = try app.layouts.current().computeRects(Rect.init(0, 0, 120, 40), a);
    const out = try a.alloc(u16, rects.panes.len);
    for (rects.panes, out) |pr, *o| o.* = if (horizontal) pr.rect.w else pr.rect.h;
    return out;
}

fn openFour(app: *App, opts: Opts) !void {
    var n: usize = 0;
    while (n < 4) : (n += 1) _ = try splitActive(app, try spare(app), opts);
}

test "arrange .context: the empty area takes the pane full, then the axis is halves, thirds, quarters" {
    inline for (.{ true, false }) |horizontal| {
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
        defer app.deinit();
        app.tree.visible = false;
        try testing.expectEqual(@import("../config/Config.zig").SplitArrange.context, app.cfg.integrations.arrange);
        const opts: Opts = .{ .dir = if (horizontal) .horizontal else .vertical };
        const layout = app.layouts.current();

        // Nothing there: full, and no split at all.
        const first = try spare(&app);
        try testing.expect((try splitActive(&app, first, opts)) == null);
        try testing.expectEqual(@as(?NodeIdT, layout.leafOf(first).?), layout.root);
        try testing.expectEqualSlices(u16, if (horizontal) &.{120} else &.{40}, try spans(&app, horizontal));

        _ = try splitActive(&app, try spare(&app), opts);
        try testing.expectEqualSlices(u16, if (horizontal) &.{ 60, 59 } else &.{ 20, 19 }, try spans(&app, horizontal));
        _ = try splitActive(&app, try spare(&app), opts);
        try testing.expectEqualSlices(u16, if (horizontal) &.{ 39, 40, 39 } else &.{ 13, 13, 12 }, try spans(&app, horizontal));
        _ = try splitActive(&app, try spare(&app), opts);
        try testing.expectEqualSlices(u16, if (horizontal) &.{ 30, 29, 29, 29 } else &.{ 10, 9, 9, 9 }, try spans(&app, horizontal));
    }
}

const NodeIdT = layout_mod.NodeId;

test "arrange .fixed: the old rects, cell for cell — half the active pane, the rest untouched" {
    // The integration path: `.fixed` plus `equalize_on_open`, which is
    // what `mount_pane.place` did before there was a rule.
    {
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
        defer app.deinit();
        app.tree.visible = false;
        app.cfg.integrations.arrange = .fixed;
        try openFour(&app, .{ .dir = .horizontal, .fixed_equalize = true });
        try testing.expectEqualSlices(u16, &.{ 30, 29, 29, 29 }, try spans(&app, true));
    }
    // The terminal path: `.fixed` with `ui.auto_equalize_splits` off,
    // which is why the third shell took a quarter and the fourth an
    // eighth.
    inline for (.{ true, false }) |horizontal| {
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
        defer app.deinit();
        app.tree.visible = false;
        app.cfg.integrations.arrange = .fixed;
        try testing.expect(!app.cfg.ui.auto_equalize_splits);
        try openFour(&app, .{ .dir = if (horizontal) .horizontal else .vertical });
        try testing.expectEqualSlices(u16, if (horizontal) &.{ 60, 29, 14, 14 } else &.{ 20, 9, 4, 4 }, try spans(&app, horizontal));
    }
}

test "arrange: `before` puts the new pane first, a grid slot is filled rather than split around" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    const layout = app.layouts.current();
    const a = try spare(&app);
    _ = try splitActive(&app, a, .{ .dir = .horizontal });
    const b = try spare(&app);
    _ = try splitActive(&app, b, .{ .dir = .horizontal, .before = true });
    const rects = try layout.computeRects(Rect.init(0, 0, 120, 40), app.frame.allocator());
    try testing.expectEqual(b, rects.panes[0].pane);
    try testing.expectEqual(a, rects.panes[1].pane);

    // A layout that is nothing but a held-open slot: the pane fills it,
    // so the slot is not left beside a half-width newcomer.
    var grid = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer grid.deinit();
    grid.tree.visible = false;
    const gl = grid.layouts.current();
    const only = try spare(&grid);
    _ = try splitActive(&grid, only, .{ .dir = .horizontal });
    const filled = try spare(&grid);
    const slot = gl.leafOf(only).?;
    gl.node(slot).leaf.tabs.deinit(gl.gpa);
    gl.node(slot).* = .empty;
    grid.setActive(null);
    try testing.expect((try splitActive(&grid, filled, .{ .dir = .horizontal })) == null);
    try testing.expectEqual(slot, gl.leafOf(filled).?);
    try testing.expectEqualSlices(u16, &.{120}, try spans(&grid, true));
}
