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
//! The bottom dock's hosted panes (`bottom.zig`) are out of every
//! page's tree but still on screen, so the ring takes them too, after
//! the pages, in the dock strip's order; a step to one shows it in the
//! dock rather than pulling it back into the splits. Last come the
//! sessions in no tree at all, in the order they were opened: a split
//! closed with `view.close_split` leaves its tabs alive in the
//! background, and a session there is still a card in SESSIONS — the
//! ring once skipped it, so a strip read ` ‹ 1/1 › ` beside a rail of
//! eight. A step to one shows it in the focused leaf, as its card does.

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
    return @import("launch_profiles.zig").productOfPane(app, p) != null;
}

/// Every session pane, in ring order: page by page, each page's leaves
/// in tree order, each leaf's tabs in strip order; then the bottom
/// dock's, in its strip's order; then the ones in no tree, by pane id.
/// On `arena`. The same set SESSIONS lists as cards (`sessions.refilter`
/// walks the pane store), so the two counts agree.
pub fn list(app: *App, arena: Allocator) Allocator.Error![]PaneId {
    var out: std.ArrayListUnmanaged(PaneId) = .empty;
    for (app.layouts.layouts.items) |*layout| {
        for (try layout.leaves(arena)) |lid| {
            const leaf = layout.leaf(lid) orelse continue;
            for (leaf.tabs.items) |id| try addSession(app, arena, &out, id);
        }
    }
    for (app.bottom.panes.items) |id| try addSession(app, arena, &out, id);
    for (app.panes.slots.items, 0..) |slot, i| if (slot != null) try addSession(app, arena, &out, @intCast(i));
    return out.items;
}

fn addSession(app: *App, arena: Allocator, out: *std.ArrayListUnmanaged(PaneId), id: PaneId) Allocator.Error!void {
    if (!isSession(app, id)) return;
    // A pane lives in one leaf of one page, or in the dock; the check
    // keeps the ring honest if that ever stops holding.
    if (std.mem.indexOfScalar(PaneId, out.items, id) != null) return;
    try out.append(arena, id);
}

/// Where a session sits in the ring: `index` counts from zero.
pub const Position = struct { index: usize, count: usize };

/// `id`'s place in the ring, or null when it is not a session.
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
    // A docked session is shown where it lives: the dock's strip
    // switches to it. `showPane` would take it out of the dock.
    const bottom = @import("bottom.zig");
    if (bottom.hosts(app, to)) try bottom.host(app, to) else app.showPane(to);
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

test "vim terminal-normal: `]a` / `[a` step the ring as in an editor, with a count, and an unknown second key cancels the pair rather than leaving T-NORMAL" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(120, 40);
    defer f.deinit();
    const app = &f.app;
    try app.setInputStyle(.vim);
    const a = try f.run(.@"ai.claude_code_new_right");
    const b = try f.run(.@"ai.codex_new_tab");
    const c = try f.run(.@"ai.claude_code_new_page");
    try t.expectEqualSlices(PaneId, &.{ a, b, c }, try list(app, app.frame.allocator()));
    const Key = @import("../core/key.zig").Key;
    const pty = @import("pty_pane.zig");
    const Probe = struct {
        fn tnormal(ap: *App) !*pty.PtyPane {
            try ap.handle(.{ .key = Key.ctrl('x') });
            const p = ap.panes.pty(ap.active.?).?;
            try t.expect(p.term_normal);
            return p;
        }
    };
    f.focus(b);
    // `]a`: one step on, from T-NORMAL.
    _ = try Probe.tnormal(app);
    try app.handle(.{ .key = Key.char(']') });
    try app.handle(.{ .key = Key.char('a') });
    try t.expectEqual(c, app.active.?);
    // `2[a`: two steps back, wrapping.
    _ = try Probe.tnormal(app);
    try app.handle(.{ .key = Key.char('2') });
    try app.handle(.{ .key = Key.char('[') });
    try app.handle(.{ .key = Key.char('a') });
    try t.expectEqual(a, app.active.?);
    // `]x` is no pair: nothing steps and the pane stays in T-NORMAL;
    // the `a` after it is terminal-normal's own again.
    const p = try Probe.tnormal(app);
    try app.handle(.{ .key = Key.char(']') });
    try app.handle(.{ .key = Key.char('x') });
    try t.expectEqual(a, app.active.?);
    try t.expect(p.term_normal);
    try app.handle(.{ .key = Key.char('a') });
    try t.expect(!p.term_normal);
    try t.expectEqual(a, app.active.?);
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

test "the strip's ` ‹ 2/3 › ` on every session pane, none on a file; its arrows step the ring from the session they sit on" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(160, 40);
    defer f.deinit();
    const app = &f.app;
    const file = app.active.?;
    const s1 = try f.run(.@"ai.claude_code_new_right");
    const s2 = try f.run(.@"ai.codex_new_right");
    const s3 = try f.run(.@"ai.claude_code_new_page");
    @import("cmd_tab.zig").switchTab(app, 0);
    f.focus(file);
    const text = try f.screenText();
    try t.expect(std.mem.indexOf(u8, text, "\u{2039} 1/3 \u{203A}") != null);
    try t.expect(std.mem.indexOf(u8, text, "\u{2039} 2/3 \u{203A}") != null);
    // One nav per session strip on this page, none on the file's — and
    // the statusline's chip, the third.
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\u{2039}"));
    const render = @import("render.zig");
    // s2's `›` (the rightmost leaf's): the ring goes on to page 2's s3,
    // though the file had the keys.
    var right_next: ?[2]u16 = null;
    try f.app.render();
    var y: u16 = 0;
    while (y < app.screen.height) : (y += 1) {
        var x: u16 = 0;
        while (x < app.screen.width) : (x += 1) if (app.hits.at(x, y)) |h| if (h == .button and h.button == @intFromEnum(render.Button.session_next)) {
            right_next = .{ x, y };
        };
    }
    try f.click(right_next.?);
    try t.expectEqual(s3, app.active.?);
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    // s3's `‹`: back to s2 on page 1.
    try f.click((try f.hitOn(.{ .button = @intFromEnum(render.Button.session_prev) })).?);
    try t.expectEqual(s2, app.active.?);
    try t.expectEqual(@as(usize, 0), app.layouts.active);
    // s1's `‹` (the leftmost nav): before the first is the last, s3.
    try f.click((try f.hitOn(.{ .button = @intFromEnum(render.Button.session_prev) })).?);
    try t.expectEqual(s3, app.active.?);
    try t.expectEqual(@as(usize, 0), (try position(app, app.frame.allocator(), s1)).?.index);
}

test "the statusline's sessions chip: ` ‹ ▣ 2/2 › ` while sessions are open, a bare count off them; the arrows and the chip click through" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(160, 40);
    defer f.deinit();
    const app = &f.app;
    const statusline = @import("statusline.zig");
    const bar: u16 = 38;
    const file = app.active.?;
    // No session: no chip.
    try t.expect((try f.hitOn(.{ .statusline_seg = statusline.SegId.sessions.raw() })) == null);
    const s1 = try f.run(.@"ai.claude_code_new_right");
    const s2 = try f.run(.@"ai.codex_new_page");
    try t.expectEqual(s2, app.active.?);
    var text = try f.screenText();
    try t.expect(std.mem.indexOf(u8, text, " \u{2039} ") != null);
    try t.expect(std.mem.indexOf(u8, text, " 2/2 \u{203A} ") != null);
    // Off the ring: the count alone.
    @import("cmd_tab.zig").switchTab(app, 0);
    f.focus(file);
    text = try f.screenText();
    try t.expect(std.mem.indexOf(u8, text, " 2 \u{203A} ") != null);
    // The arrows step the ring; the chip opens SESSIONS.
    const next_at = (try f.hitOn(.{ .statusline_seg = statusline.SegId.session_next.raw() })).?;
    try t.expectEqual(bar, next_at[1]);
    try f.click(next_at);
    try t.expectEqual(s1, app.active.?);
    try f.click((try f.hitOn(.{ .statusline_seg = statusline.SegId.session_prev.raw() })).?);
    try t.expectEqual(s2, app.active.?);
    try f.click((try f.hitOn(.{ .statusline_seg = statusline.SegId.sessions.raw() })).?);
    try t.expect(@import("side.zig").isShown(app, .sessions));
}

test "the statusline's sessions chip wears its own ground — `statusline_pager`, else `sun` — with the arrows and the count in the dark ink, not the bar's grey" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(160, 40);
    defer f.deinit();
    const app = &f.app;
    const statusline = @import("statusline.zig");
    _ = try f.run(.@"ai.claude_code_new_right");
    const p = &app.theme.palette;
    try t.expect(!std.meta.eql(p.seg.pager, p.bg2));
    try t.expect(std.meta.eql(p.seg.pager, p.sun));
    for ([_]statusline.SegId{ .session_prev, .sessions, .session_next }) |id| {
        const at = (try f.hitOn(.{ .statusline_seg = id.raw() })).?;
        // The cell the hit starts on is the chip's padding; the next
        // one carries the arrow (or the glyph) itself.
        for ([_]u16{ at[0], at[0] + 1 }) |x| {
            const cell = app.screen.readCell(x, at[1]).?;
            try t.expectEqual(p.seg.pager, cell.style.bg);
            try t.expectEqual(p.bg_darker, cell.style.fg);
        }
    }
}

test "a session in the bottom dock stays in the ring: its strip and the statusline read 2/2, the steps reach it there and leave it docked" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(120, 40);
    defer f.deinit();
    const app = &f.app;
    const bottom = @import("bottom.zig");
    const s1 = try f.run(.@"ai.claude_code_new_right");
    const s2 = try f.run(.@"ai.codex_new_right");
    try command.run(app, .{ .static = .@"view.host_active_in_bottom_panel" });
    try t.expect(bottom.hosts(app, s2));
    try t.expectEqual(s2, app.active.?);
    try t.expectEqualSlices(PaneId, &.{ s1, s2 }, try list(app, app.frame.allocator()));
    // The claude strip reads 1/2, the dock's 2/2, and the statusline's
    // chip the focused session's place, not the bare count.
    const text = try f.screenText();
    try t.expect(std.mem.indexOf(u8, text, "\u{2039} 1/2 \u{203A}") != null);
    try t.expect(std.mem.indexOf(u8, text, "\u{2039} 2/2 \u{203A}") != null);
    try t.expect(std.mem.indexOf(u8, text, " 2/2 \u{203A} ") != null);
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\u{2039}"));
    // The steps go round both sessions; the docked one is shown in the
    // dock, never pulled back into the splits.
    try command.run(app, .{ .static = .@"ai.focus_next_session" });
    try t.expectEqual(s1, app.active.?);
    try command.run(app, .{ .static = .@"ai.focus_next_session" });
    try t.expectEqual(s2, app.active.?);
    try t.expectEqual(s2, app.focus.pane);
    try t.expect(bottom.hosts(app, s2));
    try t.expect(app.layouts.current().leafOf(s2) == null);
    try t.expectEqualStrings("session 2/2", app.lastToast().?[0.."session 2/2".len]);
}

test "a session left in the background is still in the ring: its split closed, the count matches SESSIONS' cards, and a step brings it back into the focused leaf" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(200, 40);
    defer f.deinit();
    const app = &f.app;
    const s1 = try f.run(.@"ai.claude_code_new_right");
    const s2 = try f.run(.@"ai.claude_code_new_right");
    const s3 = try f.run(.@"ai.claude_code_new_right");
    // `view.close_split` drops s3's leaf; its tab lives on in the
    // background, in no page's tree.
    try command.run(app, .{ .static = .@"view.close_split" });
    try t.expect(app.panes.get(s3) != null);
    try t.expect(app.layouts.pageOf(s3) == null);
    try t.expectEqualSlices(PaneId, &.{ s1, s2, s3 }, try list(app, app.frame.allocator()));
    // The strip's count and the rail's are one number.
    try @import("../sessions.zig").refilter(app);
    try t.expectEqual(app.sessions.cards.items.len, (try position(app, app.frame.allocator(), s1)).?.count);
    const text = try f.screenText();
    try t.expect(std.mem.indexOf(u8, text, "\u{2039} 1/3 \u{203A}") != null);
    // From s2 the next is s3: shown in s2's leaf, with the keys.
    f.focus(s2);
    const lid = app.layouts.current().leafOf(s2).?;
    try command.run(app, .{ .static = .@"ai.focus_next_session" });
    try t.expectEqual(s3, app.active.?);
    try t.expectEqual(lid, app.layouts.current().leafOf(s3).?);
    try t.expect(app.layoutFault() == null);
}

test "the statusline's sessions chip narrows in order: the whole ` ‹ ▣ 2/2 › `, then ` ‹ ▣ › `, then ` ▣ ` — never back to a wider form on a narrower row" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init(160, 30);
    defer f.deinit();
    const app = &f.app;
    _ = try f.run(.@"ai.claude_code_new_right");
    _ = try f.run(.@"ai.codex_new_tab");
    const glyph = comptime @import("../ui/activity_bar.zig").Section.sessions.meta().glyph;
    const Form = enum(u8) { full, arrows, bare, gone };
    var last: Form = .full;
    var seen = std.EnumSet(Form).empty;
    var w: u16 = 160;
    while (w >= 40) : (w -= 2) {
        try app.resize(w, 30);
        const text = try f.screenText();
        var rows = std.mem.splitScalar(u8, text, '\n');
        var i: usize = 0;
        const bar = while (rows.next()) |line| : (i += 1) {
            if (i == 28) break line;
        } else "";
        const form: Form = if (std.mem.indexOf(u8, bar, "\u{2039} " ++ glyph ++ " 2/2 \u{203A}") != null)
            .full
        else if (std.mem.indexOf(u8, bar, "\u{2039} " ++ glyph ++ " \u{203A}") != null)
            .arrows
        else if (std.mem.indexOf(u8, bar, " " ++ glyph ++ " ") != null)
            .bare
        else
            .gone;
        try t.expect(@intFromEnum(form) >= @intFromEnum(last));
        last = form;
        seen.insert(form);
    }
    try t.expect(seen.contains(.full));
    try t.expect(seen.contains(.arrows));
    try t.expect(seen.contains(.bare));
}
