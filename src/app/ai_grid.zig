//! Where a new Claude session lands when `ui.ai_layout_mode` is
//! `.grid`: by the count of Claude panes already on the page,
//!
//!   0, 1  a split to the right of the active leaf
//!   2     the two, side by side and alone in their leaves, become the
//!         top row of a 2×2; the third goes bottom-left and an `.empty`
//!         placeholder holds bottom-right
//!   3, 5, 7 with the placeholder live: the new session fills it
//!   4     the 2×2 grows to 3×2 (five sessions and a placeholder)
//!   6     the 3×2 grows to 4×2 (seven and a placeholder)
//!   8     the page is full: the session goes to the first other page
//!         of sessions with room (the rule runs there), else to a new,
//!         empty page after the last one, and the count starts over
//!
//! Each grid step needs the layout to hold a pure cluster of exactly
//! those Claudes (`Layout.findPureCluster`); a layout the user has
//! rearranged falls back to the plain split, and so does a count the
//! table has no row for. Every step gives the splits equal shares. A
//! placeholder the user emptied (a session closed, a pane dragged in)
//! is forgotten as soon as the tree holds no `.empty` slot.
//!
//! The batch (`Open ×2 / ×4 / ×8`) runs the same rule N times and
//! reports the pages it needed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const layout_mod = @import("layout.zig");
const pty_pane = @import("pty_pane.zig");
const launch_profiles = @import("launch_profiles.zig");

/// Claude sessions a page holds before the next one opens a new page.
pub const cap: usize = 8;

/// One new session with the default profile, placed by the rule. Null:
/// the profile starts its sessions in a worktree, and the name prompt
/// opened instead.
pub fn open(app: *App) CommandError!?PaneId {
    var pages: usize = 0;
    return openCounting(app, &pages);
}

/// `n` sessions, one page per eight; one toast for the lot.
pub fn openBatch(app: *App, n: usize) CommandError!void {
    var spawned: usize = 0;
    var pages: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = (try openCounting(app, &pages)) orelse break;
        spawned += 1;
    }
    if (spawned > 1) {
        if (pages > 0) {
            app.toast("opened {d} Claude sessions across {d} screens", .{ spawned, pages + 1 });
        } else {
            app.toast("opened {d} Claude sessions", .{spawned});
        }
    }
}

fn openCounting(app: *App, pages: *usize) CommandError!?PaneId {
    const name = launch_profiles.defaultName(app, .claude);
    // A worktree profile prompts for a name first; the session opens
    // from the prompt, beside the active pane.
    if (launch_profiles.find(app, .claude, name)) |p| if (p.worktree) return launch_profiles.openSessionWith(app, .claude, name, .right);
    if (app.ai.placeholder and !app.layouts.current().containsEmpty()) app.ai.placeholder = false;
    if (countOnPage(app) >= cap) {
        // A full page sends the session to the first page of sessions
        // with room; only with none does it make a page, after the
        // last, so the tabs keep the order the sessions came in.
        if (pageWithRoom(app)) |page| goToPage(app, page) else try appendPage(app);
        pages.* += 1;
    }
    const arena = app.frame.allocator();
    const claudes = try onPage(app, arena);
    const placed: ?PaneId = switch (claudes.len) {
        2 => try third(app, claudes[0], claudes[1]),
        3, 5, 7 => if (app.ai.placeholder) try fillPlaceholder(app) else null,
        4 => try grow(app, arena, claudes, 3),
        6 => try grow(app, arena, claudes, 4),
        else => null,
    };
    if (placed) |id| return id;
    return launch_profiles.openSessionWith(app, .claude, name, .right);
}

/// The first page other than this one that holds Claude sessions and
/// fewer than `cap` of them. A page with none is the user's own (their
/// files), not a page of the grid, and is left alone.
fn pageWithRoom(app: *App) ?usize {
    const ls = &app.layouts;
    for (ls.layouts.items, 0..) |*l, i| {
        if (i == ls.active) continue;
        const n = countOn(app, l);
        if (n > 0 and n < cap) return i;
    }
    return null;
}

/// Make page `idx` the one on screen, its first leaf's pane active —
/// no toast: the session that lands there is the follow. Its `.empty`
/// slot, if it has one, is the grid's placeholder.
fn goToPage(app: *App, idx: usize) void {
    const ls = &app.layouts;
    app.setActive(null);
    ls.active = idx;
    const layout = ls.current();
    app.setActive(if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null);
    app.ai.placeholder = layout.containsEmpty();
}

/// A fresh, empty page after the LAST one, made current.
fn appendPage(app: *App) Allocator.Error!void {
    const ls = &app.layouts;
    try ls.layouts.append(ls.gpa, layout_mod.Layout.init(ls.gpa));
    app.setActive(null);
    ls.active = ls.layouts.items.len - 1;
    app.ai.placeholder = false;
    app.needs_render = true;
}

/// Claude panes on the current page, in pane order.
pub fn countOnPage(app: *App) usize {
    return countOn(app, app.layouts.current());
}

/// Claude panes in `layout`'s split tree.
fn countOn(app: *App, layout: *layout_mod.Layout) usize {
    var n: usize = 0;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| if (pty_pane.productOf(app, p) == .claude and layout.leafOf(@intCast(i)) != null) {
            n += 1;
        },
        else => {},
    };
    return n;
}

fn onPage(app: *App, arena: Allocator) Allocator.Error![]PaneId {
    var out: std.ArrayListUnmanaged(PaneId) = .empty;
    const layout = app.layouts.current();
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| if (pty_pane.productOf(app, p) == .claude and layout.leafOf(@intCast(i)) != null) try out.append(arena, @intCast(i)),
        else => {},
    };
    return out.items;
}

/// A session in no leaf, for a grid step to hang.
fn spawn(app: *App) CommandError!PaneId {
    return (try launch_profiles.openSessionWith(app, .claude, launch_profiles.defaultName(app, .claude), .detached)) orelse
        app.diag.fail(app.frame.allocator(), "the default Claude profile prompts for a worktree", .{});
}

fn land(app: *App, id: PaneId) void {
    app.setActive(id);
    app.focus = .{ .pane = id };
    app.afterSplitChange();
    app.needs_render = true;
}

/// Two Claudes side by side, each alone in its leaf → the 2×2: the two
/// on top in their order, the third bottom-left, a placeholder
/// bottom-right. Any other shape is null (the plain split follows).
fn third(app: *App, c1: PaneId, c2: PaneId) CommandError!?PaneId {
    const layout = app.layouts.current();
    const pair = layout.findLeafPairSplit(c1, c2) orelse return null;
    if (pair.dir != .horizontal) return null;
    const s = layout.node(pair.split).split;
    const left = layout.leaf(s.first).?.active;
    const right = layout.leaf(s.second).?.active;
    const id = try spawn(app);
    try layout.buildGrid(pair.split, &.{ &.{ left, right }, &.{ id, null } });
    app.ai.placeholder = true;
    land(app, id);
    return id;
}

/// The new session takes the `.empty` slot.
fn fillPlaceholder(app: *App) CommandError!?PaneId {
    const layout = app.layouts.current();
    if (!layout.containsEmpty()) return null;
    const id = try spawn(app);
    if ((try layout.fillFirstEmpty(id)) == null) try pty_pane.place(app, id, .right);
    app.ai.placeholder = false;
    land(app, id);
    return id;
}

/// `cols - 1` × 2 → `cols` × 2: the first `cols` Claudes across the
/// top, the rest, the new one and a placeholder across the bottom.
/// Needs exactly `cols * 2 - 2` Claudes forming a pure cluster.
fn grow(app: *App, arena: Allocator, claudes: []const PaneId, cols: usize) CommandError!?PaneId {
    if (claudes.len != cols * 2 - 2) return null;
    const layout = app.layouts.current();
    const cluster = (try layout.findPureCluster(arena, claudes)) orelse return null;
    const id = try spawn(app);
    const top = try arena.alloc(?PaneId, cols);
    for (top, claudes[0..cols]) |*slot, c| slot.* = c;
    const bottom = try arena.alloc(?PaneId, cols);
    for (bottom[0 .. cols - 2], claudes[cols..]) |*slot, c| slot.* = c;
    bottom[cols - 2] = id;
    bottom[cols - 1] = null;
    try layout.buildGrid(cluster, &.{ top, bottom });
    app.ai.placeholder = true;
    land(app, id);
    return id;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const builtin = @import("builtin");
const build_options = @import("build_options");
const Rect = @import("../ui/rect.zig");
const screen_mod = @import("../ipc/screen.zig");
const dispatch = @import("dispatch.zig");
const side = @import("side.zig");

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    app: App,

    /// A headless app whose `claude` and `codex` are `tools/shims/ai/`'s
    /// (they sleep).
    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 200, .rows = 60 });
        errdefer app.deinit();
        app.tree.visible = false;
        const path = try std.fmt.allocPrint(t.allocator, "{s}/ai:{s}", .{ build_options.shims_dir, app.env.get("PATH") orelse "/usr/bin:/bin" });
        defer t.allocator.free(path);
        try app.env.put("PATH", path);
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn open(f: *Fixture) !PaneId {
        try command.run(&f.app, .{ .static = .@"ai.claude_code_new" });
        return f.app.active.?;
    }

    fn rects(f: *Fixture) !layout_mod.Rects {
        return f.app.layouts.current().computeRects(Rect.init(0, 1, 200, 58), f.app.frame.allocator());
    }

    fn rectOf(f: *Fixture, pane: PaneId) !Rect {
        for ((try f.rects()).panes) |pr| if (pr.pane == pane) return pr.rect;
        return error.NotInTree;
    }

    fn empties(f: *Fixture) !usize {
        return (try f.rects()).empties.len;
    }

    fn claudesOn(f: *Fixture, page: usize) usize {
        var n: usize = 0;
        const layout = &f.app.layouts.layouts.items[page];
        for (f.app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
            .pty => |*p| if (pty_pane.productOf(&f.app, p) == .claude and layout.leafOf(@intCast(i)) != null) {
                n += 1;
            },
            else => {},
        };
        return n;
    }
};

/// The rows and columns the panes occupy, from their rects.
fn shape(f: *Fixture, ids: []const PaneId) !struct { rows: usize, cols: usize } {
    var ys: [16]u16 = undefined;
    var xs: [16]u16 = undefined;
    var ny: usize = 0;
    var nx: usize = 0;
    for (ids) |id| {
        const r = try f.rectOf(id);
        if (std.mem.indexOfScalar(u16, ys[0..ny], r.y) == null) {
            ys[ny] = r.y;
            ny += 1;
        }
        if (std.mem.indexOfScalar(u16, xs[0..nx], r.x) == null) {
            xs[nx] = r.x;
            nx += 1;
        }
    }
    return .{ .rows = ny, .cols = nx };
}

/// Every pane in `ids` within a cell of the same width.
fn sameWidth(f: *Fixture, ids: []const PaneId) !void {
    const first = (try f.rectOf(ids[0])).w;
    for (ids[1..]) |id| {
        const w = (try f.rectOf(id)).w;
        try t.expect(@max(w, first) - @min(w, first) <= 1);
    }
}

test "the grid: sessions 1..9 go side by side, 2×2 with a slot, filled, 3×2, 4×2, then a second page with the first holding eight" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    var ids: [9]PaneId = undefined;
    // 1: alone. 2: side by side.
    ids[0] = try f.open();
    try t.expectEqual(@as(usize, 1), (try f.rects()).panes.len);
    ids[1] = try f.open();
    try t.expectEqual((try f.rectOf(ids[0])).y, (try f.rectOf(ids[1])).y);
    try t.expect((try f.rectOf(ids[1])).x > (try f.rectOf(ids[0])).x);
    try t.expectEqual(@as(usize, 0), try f.empties());
    // 3: the 2×2 with the slot bottom-right, the third bottom-left.
    ids[2] = try f.open();
    try t.expect(app.ai.placeholder);
    try t.expectEqual(@as(usize, 1), try f.empties());
    const slot = (try f.rects()).empties[0].rect;
    try t.expectEqual((try f.rectOf(ids[2])).y, slot.y);
    try t.expectEqual((try f.rectOf(ids[1])).x, slot.x);
    try t.expectEqual((try f.rectOf(ids[0])).x, (try f.rectOf(ids[2])).x);
    try t.expect((try f.rectOf(ids[2])).y > (try f.rectOf(ids[0])).y);
    try t.expectEqual(@as(u16, 29), (try f.rectOf(ids[0])).h);
    try t.expectEqual(@as(u16, 28), (try f.rectOf(ids[2])).h);
    // 4: the slot is filled, same place.
    ids[3] = try f.open();
    try t.expect(!app.ai.placeholder);
    try t.expectEqual(@as(usize, 0), try f.empties());
    try t.expect((try f.rectOf(ids[3])).eql(slot));
    try t.expectEqual(@as(usize, 2), (try shape(&f, ids[0..4])).rows);
    try t.expectEqual(@as(usize, 2), (try shape(&f, ids[0..4])).cols);
    // 5: 3×2 — three across the top, the fifth bottom-middle, a slot bottom-right.
    ids[4] = try f.open();
    try t.expect(app.ai.placeholder);
    try t.expectEqual(@as(usize, 1), try f.empties());
    try t.expectEqual(@as(usize, 3), (try shape(&f, ids[0..5])).cols);
    try t.expectEqual(@as(usize, 2), (try shape(&f, ids[0..5])).rows);
    try t.expectEqual((try f.rectOf(ids[3])).y, (try f.rectOf(ids[4])).y);
    try t.expectEqual((try f.rectOf(ids[1])).x, (try f.rectOf(ids[4])).x);
    try t.expectEqual((try f.rectOf(ids[2])).x, (try f.rects()).empties[0].rect.x);
    try sameWidth(&f, ids[0..5]);
    // 6: filled. 7: 4×2 with a slot. 8: full.
    ids[5] = try f.open();
    try t.expectEqual(@as(usize, 0), try f.empties());
    ids[6] = try f.open();
    try t.expectEqual(@as(usize, 1), try f.empties());
    try t.expectEqual(@as(usize, 4), (try shape(&f, ids[0..7])).cols);
    try t.expectEqual(@as(usize, 2), (try shape(&f, ids[0..7])).rows);
    try sameWidth(&f, ids[0..7]);
    ids[7] = try f.open();
    try t.expectEqual(@as(usize, 0), try f.empties());
    try t.expect(!app.ai.placeholder);
    try t.expectEqual(@as(usize, 8), countOnPage(app));
    try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
    // 9: a second page, alone on it; the first page keeps its eight.
    ids[8] = try f.open();
    try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    try t.expectEqual(@as(usize, 1), countOnPage(app));
    try t.expectEqual(@as(usize, 8), f.claudesOn(0));
    try t.expectEqual(@as(usize, 1), (try f.rects()).panes.len);
    try t.expectEqual(ids[8], app.active.?);
}

test "the grid: a closed session takes the slot with it and the marker clears; a rearranged pair or cluster falls back to the plain split" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try f.open();
    _ = try f.open();
    const c3 = try f.open();
    try t.expect(app.ai.placeholder);
    // Closing the third: its split — slot included — goes; the marker
    // is stale until the next grid open reads the tree. A session
    // placed by hand (`…_new_right`) makes three again without a slot,
    // so that open clears the marker and is a plain split.
    try app.closePane(c3, true);
    try t.expect(!app.layouts.current().containsEmpty());
    try t.expect(app.ai.placeholder);
    try command.run(app, .{ .static = .@"ai.claude_code_new_right" });
    try t.expectEqual(@as(usize, 3), countOnPage(app));
    const c4 = try f.open();
    try t.expect(!app.ai.placeholder);
    try t.expectEqual(@as(usize, 0), try f.empties());
    try t.expectEqual(@as(usize, 4), countOnPage(app));
    try t.expectEqual(c4, app.active.?);
    // Two again, side by side: the third makes the 2×2 once more.
    var h = try Fixture.init();
    defer h.deinit();
    const e1 = try h.open();
    const e2 = try h.open();
    const e3 = try h.open();
    try h.app.closePane(e3, true);
    const e3b = try h.open();
    try t.expect(h.app.ai.placeholder);
    try t.expectEqual(@as(usize, 1), try h.empties());
    try t.expectEqual((try h.rectOf(e1)).x, (try h.rectOf(e3b)).x);
    // A scratch tabbed into the cluster: the fourth fills the slot (the
    // slot is there), but with the cluster impure the fifth is a plain
    // split — no 3×2, no new slot.
    _ = try h.open();
    try t.expectEqual(@as(usize, 0), try h.empties());
    h.app.setActive(e2);
    _ = try h.app.openScratch();
    _ = try h.open();
    try t.expectEqual(@as(usize, 0), try h.empties());
    try t.expect(!h.app.ai.placeholder);
    try t.expectEqual(@as(usize, 5), countOnPage(&h.app));
    // A pair that is not side by side: the third is a plain split too.
    var g = try Fixture.init();
    defer g.deinit();
    const d1 = try g.open();
    _ = try g.open();
    try command.run(&g.app, .{ .static = .@"view.split_down" });
    const d3 = try g.open();
    try t.expect(!g.app.ai.placeholder);
    try t.expectEqual(@as(usize, 0), try g.empties());
    try t.expectEqual(@as(usize, 3), g.claudesOn(0));
    try t.expect((try g.rectOf(d3)).x > (try g.rectOf(d1)).x);
}

test "the grid: tabs mode stacks every session on one strip; the batch spills to a second page and says so" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    app.cfg.ui.ai_layout_mode = .tabs;
    _ = try f.open();
    _ = try f.open();
    const c3 = try f.open();
    try t.expectEqual(@as(usize, 1), (try f.rects()).panes.len);
    try t.expectEqual(@as(usize, 3), app.layouts.current().leaf(app.layouts.current().leafOf(c3).?).?.tabs.items.len);
    try t.expect(!app.ai.placeholder);
    // The batch in grid mode: ×4 is a 2×2; ×8 more fills the page and
    // opens a second for the rest.
    var g = try Fixture.init();
    defer g.deinit();
    try command.run(&g.app, .{ .static = .@"ai.claude_code_new_x4" });
    try t.expectEqualStrings("opened 4 Claude sessions", g.app.lastToast().?);
    try t.expectEqual(@as(usize, 4), countOnPage(&g.app));
    try t.expectEqual(@as(usize, 0), try g.empties());
    try command.run(&g.app, .{ .static = .@"ai.claude_code_new_x8" });
    try t.expectEqualStrings("opened 8 Claude sessions across 2 screens", g.app.lastToast().?);
    try t.expectEqual(@as(usize, 2), g.app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 8), g.claudesOn(0));
    try t.expectEqual(@as(usize, 4), g.claudesOn(1));
    try t.expectEqual(@as(usize, 0), try g.empties());
}

test "the grid: the open slot paints the Add Claude Code card over the whole quadrant, and a press on it opens the fourth session there" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try f.open();
    _ = try f.open();
    _ = try f.open();
    try app.render();
    const before = try screen_mod.toTestText(app.gpa, &app.screen);
    defer app.gpa.free(before);
    try t.expect(std.mem.indexOf(u8, before, "Add Claude Code") != null);
    // The hit covers the slot's rect, not just the chip.
    const slot = (try app.layouts.current().computeRects(app.panes_area, app.frame.allocator())).empties[0].rect;
    var hit: ?Rect = null;
    for (app.hits.items.items) |e| if (e.target == .ai_placeholder) {
        hit = e.rect;
    };
    try t.expect(hit.?.eql(slot));
    try dispatch.mouse(app, .{ .x = slot.x + 2, .y = slot.y + 1, .kind = .press, .button = .left }, 1);
    try t.expectEqual(@as(usize, 4), countOnPage(app));
    try t.expectEqual(@as(usize, 0), try f.empties());
    try t.expect((try app.layouts.current().computeRects(app.panes_area, app.frame.allocator())).panes[3].rect.eql(slot));
    try app.render();
    const after = try screen_mod.toTestText(app.gpa, &app.screen);
    defer app.gpa.free(after);
    try t.expect(std.mem.indexOf(u8, after, "Add Claude Code") == null);
}

test "ai.claude_code_focus toggles the running session — shown, then back to the pane before it — and starts one only when none runs; ai.claude_code always starts one" {
    // sess-chip-toggle-existing-opens-new.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const ed = try app.openScratch();
    try command.run(app, .{ .static = .@"ai.claude_code_focus" });
    try t.expectEqual(@as(usize, 1), countOnPage(app));
    const c1 = app.active.?;
    try t.expect(c1 != ed);
    // On it: back to the scratch; off it: the session again. Never a second.
    try command.run(app, .{ .static = .@"ai.claude_code_focus" });
    try t.expectEqual(ed, app.active.?);
    try command.run(app, .{ .static = .@"ai.claude_code_focus" });
    try t.expectEqual(c1, app.active.?);
    try t.expectEqual(@as(usize, 1), countOnPage(app));
    // Two sessions: the one focused last is the one toggled.
    const c2 = try f.open();
    try t.expectEqual(@as(usize, 2), countOnPage(app));
    app.showPane(ed);
    try command.run(app, .{ .static = .@"ai.claude_code_focus" });
    try t.expectEqual(c2, app.active.?);
    app.showPane(c1);
    app.showPane(ed);
    try command.run(app, .{ .static = .@"ai.claude_code_focus" });
    try t.expectEqual(c1, app.active.?);
    try t.expectEqual(@as(usize, 2), countOnPage(app));
    // The plain command is a new session every time (the user's
    // 2026-09-02 ask), a session already up or not.
    try command.run(app, .{ .static = .@"ai.claude_code" });
    try t.expectEqual(@as(usize, 3), countOnPage(app));
}

test "ui.auto_show_sessions_on_ai_activate: a new Claude or Codex session, single or batch, shows SESSIONS and keeps the keys on the pane; off, the column is left alone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try t.expect(!side.isShown(&f.app, .sessions));
    try command.run(&f.app, .{ .static = .@"ai.claude_code" });
    try t.expect(side.isShown(&f.app, .sessions));
    try t.expect(f.app.focus == .pane);
    try t.expectEqual(f.app.active.?, f.app.focus.pane);
    // Codex, and the batch, the same.
    var g = try Fixture.init();
    defer g.deinit();
    try command.run(&g.app, .{ .static = .@"ai.codex_new" });
    try t.expect(side.isShown(&g.app, .sessions));
    var h = try Fixture.init();
    defer h.deinit();
    try command.run(&h.app, .{ .static = .@"ai.claude_code_new_x2" });
    try t.expect(side.isShown(&h.app, .sessions));
    try t.expectEqual(@as(usize, 2), countOnPage(&h.app));
    // Off: the column stays as it was.
    var k = try Fixture.init();
    defer k.deinit();
    k.app.cfg.ui.auto_show_sessions_on_ai_activate = false;
    try command.run(&k.app, .{ .static = .@"ai.claude_code_new" });
    try t.expect(!side.isShown(&k.app, .sessions));
    try command.run(&k.app, .{ .static = .@"ai.codex_new" });
    try t.expect(!side.isShown(&k.app, .sessions));
    try command.run(&k.app, .{ .static = .@"ai.claude_code_new_x2" });
    try t.expect(!side.isShown(&k.app, .sessions));
}
