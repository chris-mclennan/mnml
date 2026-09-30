//! Session cycling: `ai.focus_next_session` / `ai.focus_prev_session`
//! step through every Claude Code and Codex session pane — splits,
//! tabs stacked in a leaf and sessions on tab pages of their own — in
//! one stable ring, crossing pages to reach the next one.
//!
//! The ring's order is the tab pages' order, then each page's layout
//! order (leaves in tree order, left / top first), then each leaf's
//! tabs in strip order. It is the one order everything that numbers a
//! session reads: the `‹ 3/7 ›` on a session's tab strip
//! (`render.drawStrip`) and the statusline's sessions chip
//! (`statusline.zig`) both come from `position` here.
//!
//! A session is a pty pane running an AI product — the bare `claude` /
//! `codex` or one of their profile shims (`pty_pane.productOf`) —
//! running or exited: an ended session still has a pane to look at.
//! A pane that sits in no page's tree is not in the ring.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const pty_pane = @import("pty_pane.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const table = .{
    .@"ai.focus_next_session" = &focusNext,
    .@"ai.focus_prev_session" = &focusPrev,
};

/// The one toast id a step replaces, so a run of steps shows one line.
const step_toast = "session-cycle";

/// Is `id` an AI session pane?
pub fn isSession(app: *App, id: PaneId) bool {
    const p = app.panes.pty(id) orelse return false;
    return pty_pane.productOf(app, p) != null;
}

/// Every session pane, in ring order: page by page, each page's leaves
/// in tree order, each leaf's tabs in strip order. On `arena`.
pub fn list(app: *App, arena: Allocator) Allocator.Error![]PaneId {
    var out: std.ArrayListUnmanaged(PaneId) = .empty;
    for (app.layouts.layouts.items) |*layout| {
        for (try layout.leaves(arena)) |lid| {
            const leaf = layout.leaf(lid) orelse continue;
            for (leaf.tabs.items) |id| {
                if (!isSession(app, id)) continue;
                // A pane lives in one leaf of one page; the check keeps
                // the ring honest if that ever stops holding.
                if (std.mem.indexOfScalar(PaneId, out.items, id) != null) continue;
                try out.append(arena, id);
            }
        }
    }
    return out.items;
}

/// Where a session sits in the ring: `index` counts from zero.
pub const Position = struct { index: usize, count: usize };

/// `id`'s place in the ring, or null when it is not a session in any
/// page's tree.
pub fn position(app: *App, arena: Allocator, id: PaneId) Allocator.Error!?Position {
    const ring = try list(app, arena);
    const at = std.mem.indexOfScalar(PaneId, ring, id) orelse return null;
    return .{ .index = at, .count = ring.len };
}

/// How many sessions the ring holds.
pub fn count(app: *App, arena: Allocator) Allocator.Error!usize {
    return (try list(app, arena)).len;
}

pub const Dir = enum { next, prev };

/// The session a step lands on, from `from`: its neighbour in the ring,
/// wrapping at both ends. From a pane that is not a session, `next` is
/// the first session and `prev` the last. Null when there are none.
pub fn target(ring: []const PaneId, from: ?PaneId, dir: Dir) ?PaneId {
    if (ring.len == 0) return null;
    const n = ring.len;
    const at = if (from) |f| std.mem.indexOfScalar(PaneId, ring, f) else null;
    const i = at orelse return if (dir == .next) ring[0] else ring[n - 1];
    return ring[if (dir == .next) (i + 1) % n else (i + n - 1) % n];
}

/// One step: the session is shown on the page that holds it — that page
/// comes on screen — and gets the keys. A toast names where the step
/// landed (`session 3/7 · name`), replacing the last step's.
pub fn step(app: *App, dir: Dir) CommandError!void {
    const arena = app.frame.allocator();
    const ring = try list(app, arena);
    const to = target(ring, app.active, dir) orelse {
        app.toastReplace(step_toast, "no Claude Code or Codex sessions open", .{});
        return;
    };
    app.showPane(to);
    app.focus = .{ .pane = to };
    app.needs_render = true;
    const at = std.mem.indexOfScalar(PaneId, ring, to).?;
    const sessions = @import("../sessions.zig");
    if (sessions.paneName(app, to)) |name| {
        app.toastReplace(step_toast, "session {d}/{d} · {s}", .{ at + 1, ring.len, name.text });
    } else app.toastReplace(step_toast, "session {d}/{d}", .{ at + 1, ring.len });
}

fn focusNext(app: *App) CommandError!void {
    return step(app, .next);
}

fn focusPrev(app: *App) CommandError!void {
    return step(app, .prev);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the ring's step: neighbours both ways, wrap at the ends, a non-session enters at the first (next) or last (prev), none is null" {
    const ring = [_]PaneId{ 4, 9, 2 };
    try t.expectEqual(@as(?PaneId, 9), target(&ring, 4, .next));
    try t.expectEqual(@as(?PaneId, 2), target(&ring, 9, .next));
    try t.expectEqual(@as(?PaneId, 4), target(&ring, 2, .next));
    try t.expectEqual(@as(?PaneId, 2), target(&ring, 4, .prev));
    try t.expectEqual(@as(?PaneId, 4), target(&ring, 9, .prev));
    try t.expectEqual(@as(?PaneId, 4), target(&ring, 7, .next));
    try t.expectEqual(@as(?PaneId, 2), target(&ring, 7, .prev));
    try t.expectEqual(@as(?PaneId, 4), target(&ring, null, .next));
    try t.expectEqual(@as(?PaneId, 4), target(ring[0..1], 4, .next));
    try t.expectEqual(@as(?PaneId, null), target(&.{}, 4, .next));
}

/// A headless app on a scratch workspace whose `claude` and `codex` are
/// `tools/shims/ai/`'s (they sleep), with a scratch file open. The
/// grid, the SESSIONS column and the tree stay out of the way.
const Fx = struct {
    app: App,

    fn init(cols: u16, rows: u16) !Fx {
        const build_options = @import("build_options");
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = cols, .rows = rows });
        errdefer app.deinit();
        // Anything a session writes stays in the scratch workspace.
        t.allocator.free(app.data_root);
        app.data_root = try t.allocator.dupe(u8, app.workspace);
        app.tree.visible = false;
        app.tree.loaded = true;
        app.cfg.ui.auto_show_sessions_on_ai_activate = false;
        const path = try std.fmt.allocPrint(t.allocator, "{s}/ai:{s}", .{ build_options.shims_dir, app.env.get("PATH") orelse "/usr/bin:/bin" });
        defer t.allocator.free(path);
        try app.env.put("PATH", path);
        _ = try app.openScratch();
        return .{ .app = app };
    }

    fn deinit(f: *Fx) void {
        f.app.deinit();
    }

    fn run(f: *Fx, id: command.CommandId) !PaneId {
        try command.run(&f.app, .{ .static = id });
        return f.app.active.?;
    }

    fn focus(f: *Fx, id: PaneId) void {
        f.app.showPane(id);
        f.app.focus = .{ .pane = id };
    }

    /// A frame, then the first cell on row `y` whose hit is `target`.
    fn hitOn(f: *Fx, want: @import("../ui/hit.zig").HitTarget) !?[2]u16 {
        try f.app.render();
        var y: u16 = 0;
        while (y < f.app.screen.height) : (y += 1) {
            var x: u16 = 0;
            while (x < f.app.screen.width) : (x += 1) if (f.app.hits.at(x, y)) |h| if (std.meta.eql(h, want)) return .{ x, y };
        }
        return null;
    }

    fn screenText(f: *Fx) ![]const u8 {
        try f.app.render();
        return @import("../ipc/screen.zig").toTestText(f.app.frame.allocator(), &f.app.screen);
    }

    /// A press and its release: a strip button fires on the release.
    fn click(f: *Fx, at: [2]u16) !void {
        try f.app.handle(.{ .mouse = .{ .x = at[0], .y = at[1], .kind = .press, .button = .left } });
        try f.app.handle(.{ .mouse = .{ .x = at[0], .y = at[1], .kind = .release, .button = .left } });
    }
};

test "the ring is page order then layout order — splits, stacked tabs, a page of its own; the step wraps both ways and crosses pages; from a file, next is the first" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(160, 40);
    defer f.deinit();
    const app = &f.app;
    const file = app.active.?;
    // Page 1: a Claude session right of the file, a Codex one left of it.
    const right = try f.run(.@"ai.claude_code_new_right");
    f.focus(file);
    const left = try f.run(.@"ai.codex_new_left");
    // Page 2: a session alone on a page, and one stacked beside it.
    const paged = try f.run(.@"ai.claude_code_new_page");
    try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
    const stacked = try f.run(.@"ai.codex_new_tab");
    try t.expectEqualSlices(PaneId, &.{ left, right, paged, stacked }, try list(app, app.frame.allocator()));
    try t.expectEqual(Position{ .index = 3, .count = 4 }, (try position(app, app.frame.allocator(), stacked)).?);
    try t.expect((try position(app, app.frame.allocator(), file)) == null);

    // From the file on page 1: the first session, then on through the
    // ring, onto page 2, and round to the start of page 1 again.
    @import("cmd_tab.zig").switchTab(app, 0);
    f.focus(file);
    const expect = [_]struct { pane: PaneId, page: usize }{
        .{ .pane = left, .page = 0 },
        .{ .pane = right, .page = 0 },
        .{ .pane = paged, .page = 1 },
        .{ .pane = stacked, .page = 1 },
        .{ .pane = left, .page = 0 },
    };
    for (expect) |e| {
        try command.run(app, .{ .static = .@"ai.focus_next_session" });
        try t.expectEqual(e.pane, app.active.?);
        try t.expectEqual(e.pane, app.focus.pane);
        try t.expectEqual(e.page, app.layouts.active);
    }
    try t.expectEqualStrings("session 1/4", app.lastToast().?[0.."session 1/4".len]);
    // Backwards: before the first is the last, on page 2.
    try command.run(app, .{ .static = .@"ai.focus_prev_session" });
    try t.expectEqual(stacked, app.active.?);
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    try command.run(app, .{ .static = .@"ai.focus_prev_session" });
    try t.expectEqual(paged, app.active.?);
    try command.run(app, .{ .static = .@"ai.focus_prev_session" });
    try t.expectEqual(right, app.active.?);
    try t.expectEqual(@as(usize, 0), app.layouts.active);
    // From a file, previous is the last session.
    f.focus(file);
    try command.run(app, .{ .static = .@"ai.focus_prev_session" });
    try t.expectEqual(stacked, app.active.?);
}

test "no session open: the step toasts so and leaves the focus where it was" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 20 });
    defer app.deinit();
    const file = try app.openScratch();
    for ([_]command.CommandId{ .@"ai.focus_next_session", .@"ai.focus_prev_session" }) |id| {
        try command.run(&app, .{ .static = id });
        try t.expectEqualStrings("no Claude Code or Codex sessions open", app.lastToast().?);
        try t.expectEqual(file, app.active.?);
        try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
    }
}

test "new session in a new tab: the active leaf's strip, right after the current tab, no split; on a new tab page: inserted after this page, alone there" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(160, 40);
    defer f.deinit();
    const app = &f.app;
    const a = app.active.?;
    const b = try app.openScratch();
    const c = try app.openScratch();
    const layout = app.layouts.current();
    const lid = layout.leafOf(a).?;
    try t.expectEqualSlices(PaneId, &.{ a, b, c }, layout.leaf(lid).?.tabs.items);
    // From the first tab: the session lands second, not at the end.
    f.focus(a);
    const s = try f.run(.@"ai.claude_code_new_tab");
    try t.expect(isSession(app, s));
    try t.expectEqualSlices(PaneId, &.{ a, s, b, c }, layout.leaf(lid).?.tabs.items);
    try t.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
    // Codex the same, beside the session now current.
    const x = try f.run(.@"ai.codex_new_tab");
    try t.expectEqualSlices(PaneId, &.{ a, s, x, b, c }, layout.leaf(lid).?.tabs.items);

    // A new page for a session: after page 1 (a page 2 already there
    // stays page 3), shown, the session alone on it, page 1 unchanged.
    try command.run(app, .{ .static = .@"tab.new" });
    @import("cmd_tab.zig").switchTab(app, 0);
    const p = try f.run(.@"ai.claude_code_new_page");
    try t.expectEqual(@as(usize, 3), app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    try t.expectEqualSlices(PaneId, &.{p}, try app.layouts.current().allPanes(app.frame.allocator()));
    try t.expectEqual(@as(usize, 5), (try app.layouts.layouts.items[0].allPanes(app.frame.allocator())).len);
    const q = try f.run(.@"ai.codex_new_page");
    try t.expect(isSession(app, q));
    try t.expectEqual(@as(usize, 2), app.layouts.active);
    try t.expectEqual(@as(usize, 4), app.layouts.layouts.items.len);

    // Nothing opened (Codex routed off): the empty page is taken back
    // and the page and pane that were showing return.
    @import("cmd_tab.zig").switchTab(app, 0);
    f.focus(s);
    app.cfg.ai.routing.codex.backend = .off;
    try t.expectError(error.Failed, command.run(app, .{ .static = .@"ai.codex_new_page" }));
    try t.expectEqual(@as(usize, 4), app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 0), app.layouts.active);
    try t.expectEqual(s, app.active.?);
}
