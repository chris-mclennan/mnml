//! The ready ring — the sessions that are ready for you, and nothing
//! else: `sessions.next_waiting` / `prev_waiting` walk it, so a run of
//! steps visits exactly the sessions that have something for you and
//! skips the ones still working or already looked at.
//!
//! **Ready.** A pane is ready when either
//!   * it needs you (`sessions.needsYou`: blocked on an approval or a
//!     question) — any pty, as the waiting jumps always took. It stays
//!     ready until it is answered: looking at a question does not
//!     answer it; or
//!   * it is a session pane (`launch_profiles.productOfPane`) with news
//!     you have not looked at (`PtyPane.unseen`): its turn ended — the
//!     last read found it working (a thinking row on its screen,
//!     `sessions.derive`'s `thinking`, the same signal the cards sort
//!     by) and this one does not, with no question up — or its child
//!     exited. An exit is news once.
//! A session still working is never ready: no edge has happened yet.
//!
//! **Seen.** A pane's news is seen when a frame is rendered with it as
//! `app.active`, on screen (`sessions_mode.onScreen`: the shown tab of
//! its leaf, the zoomed one when a pane is zoomed, the dock's while the
//! dock is open) and the terminal window focused (`app.host_focused`).
//! `markSeen` runs at the top of every render and asks that of the one
//! active pane. A turn that ends while you are looking at it is
//! therefore seen on the next frame, and never joins the ring. A later
//! edge — another turn ending, the child exiting — is news again.
//!
//! **Order.** Needs-you first, oldest wait first; then the newly
//! finished, oldest first. A session blocked on you is stalled until
//! you answer, and every minute it waits is a minute it does no work —
//! a finished one costs nothing by waiting — so the blocked ones lead;
//! within each kind, first come first served, so none starves behind a
//! busier neighbour. Ties go by pane id.
//!
//! **The walk.** Every pane that has ever been ready keeps its place
//! in that order (`ready_at_ms` outlives the look), so a step from a
//! pane you just looked at goes on to the next one rather than back to
//! the head. From a pane with no place — an editor, a session that has
//! had no news — forward starts at the head and backward at the tail.
//!
//! Nothing here scans per frame: readiness changes on the edges
//! `sessions.trackNeedsYou` already reads (a pane's output or the
//! listing moved, or the child exited) and seen on the one active pane
//! at render. The ring itself is built only when a command asks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const pty_pane = @import("pty_pane.zig");
const sessions = @import("../sessions.zig");
const sessions_mode = @import("sessions_mode.zig");
const launch_profiles = @import("launch_profiles.zig");

/// What a ring entry is ready with — the word its toast leads with.
pub const Kind = enum {
    needs_you,
    finished,
    ended,

    pub fn word(k: Kind) []const u8 {
        return switch (k) {
            .needs_you => "needs you",
            .finished => "finished",
            .ended => "ended",
        };
    }
};

/// A pane's place in the order: the kind's rank (needs-you 0, the
/// rest 1), then the clock it became ready on, then its id.
pub const Key = struct {
    rank: u1,
    at_ms: i64,
    pane: PaneId,

    pub fn lessThan(a: Key, b: Key) bool {
        if (a.rank != b.rank) return a.rank < b.rank;
        if (a.at_ms != b.at_ms) return a.at_ms < b.at_ms;
        return a.pane < b.pane;
    }
};

pub const Entry = struct { kind: Kind, key: Key };

/// The toast a step replaces, so a run of steps shows one line.
pub const toast_id = "ready-ring";

/// The pane is a session (`launch_profiles.productOfPane`): only those
/// carry finished news — a shell's prompt is not a turn.
fn isSession(app: *const App, p: *const pty_pane.PtyPane) bool {
    return launch_profiles.productOfPane(app, p) != null;
}

/// `sessions.trackNeedsYou`'s hook, on each re-read of a live pane —
/// after `needs_you` was read afresh. `rose` is its rising edge.
pub fn noteRead(app: *App, pid: PaneId, rose: bool) void {
    const p = app.panes.pty(pid) orelse return;
    if (!isSession(app, p)) {
        if (rose) p.needs_you_since_ms = @max(app.now_ms, 1);
        p.turn_working = false;
        return;
    }
    noteTurn(app, p, if (sessions.derive(app, pid)) |d| d.thinking else false, rose);
}

/// The edge itself, given what the read found: a session that was
/// working and is not — with no question up — has finished its turn.
pub fn noteTurn(app: *App, p: *pty_pane.PtyPane, working: bool, rose: bool) void {
    if (rose) p.needs_you_since_ms = @max(app.now_ms, 1);
    if (p.turn_working and !working and !p.needs_you) news(app, p, .finished);
    p.turn_working = working;
}

/// `sessions.trackNeedsYou`'s hook, once per run, when a session
/// pane's child has exited.
pub fn noteExit(app: *App, pid: PaneId) void {
    const p = app.panes.pty(pid) orelse return;
    p.turn_working = false;
    if (p.dormant or !isSession(app, p)) return;
    news(app, p, .ended);
}

/// A restarted pane (`trackNeedsYou` sees it live again): its exit is
/// no longer news.
pub fn noteRestart(p: *pty_pane.PtyPane) void {
    if (p.unseen == .ended) p.unseen = .none;
}

fn news(app: *App, p: *pty_pane.PtyPane, what: pty_pane.Unseen) void {
    p.unseen = what;
    p.ready_at_ms = @max(app.now_ms, 1);
    app.needs_render = true;
}

/// The top of every render: the active pane, on screen, in a focused
/// window, has been looked at — its news is seen.
pub fn markSeen(app: *App) void {
    if (!app.host_focused) return;
    const a = app.active orelse return;
    const p = app.panes.pty(a) orelse return;
    if (p.unseen == .none) return;
    if (!sessions_mode.onScreen(app, a)) return;
    p.unseen = .none;
}

/// Whether the pane carries finished / ended news the user has not
/// looked at — the SESSIONS card's gutter mark.
pub fn unseen(app: *App, pid: PaneId) bool {
    const p = app.panes.pty(pid) orelse return false;
    return p.unseen != .none;
}

/// The pane's entry when it is ready now, else null.
pub fn entryOf(app: *App, pid: PaneId) ?Entry {
    const p = app.panes.pty(pid) orelse return null;
    if (sessions.needsYou(app, pid)) return .{ .kind = .needs_you, .key = .{ .rank = 0, .at_ms = p.needs_you_since_ms, .pane = pid } };
    return switch (p.unseen) {
        .none => null,
        .finished => .{ .kind = .finished, .key = .{ .rank = 1, .at_ms = p.ready_at_ms, .pane = pid } },
        .ended => .{ .kind = .ended, .key = .{ .rank = 1, .at_ms = p.ready_at_ms, .pane = pid } },
    };
}

/// Where a pane sits in the order whether or not it is ready now: its
/// entry's key, else the place its last news gave it, else none.
pub fn placeOf(app: *App, pid: PaneId) ?Key {
    if (entryOf(app, pid)) |e| return e.key;
    const p = app.panes.pty(pid) orelse return null;
    if (p.ready_at_ms == 0) return null;
    return .{ .rank = 1, .at_ms = p.ready_at_ms, .pane = pid };
}

/// Every ready pane, in the ring's order, on `arena`.
pub fn ring(app: *App, arena: Allocator) Allocator.Error![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    var i: usize = 0;
    while (i < app.panes.slots.items.len) : (i += 1) {
        const pid: PaneId = @intCast(i);
        if (entryOf(app, pid)) |e| try out.append(arena, e);
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.key.lessThan(b.key);
        }
    }.lt);
    return out.items;
}

/// The entry to land on from `from` (the place of the pane the step
/// starts on, if it has one): the first past it — or before it,
/// `forward = false` — wrapping round; with no place, the head (or the
/// tail). Null for an empty ring. `from` itself when it is the only one.
pub fn step(entries: []const Entry, from: ?Key, forward: bool) ?usize {
    if (entries.len == 0) return null;
    const at = from orelse return if (forward) 0 else entries.len - 1;
    if (forward) {
        for (entries, 0..) |e, i| if (at.lessThan(e.key)) return i;
        return 0;
    }
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        if (entries[i].key.lessThan(at)) return i;
    }
    return entries.len - 1;
}

/// `sessions.next_waiting` / `prev_waiting`: show and focus the next /
/// previous ready session — in the sessions mode, swapped into the
/// focused column; on a zoomed page, into the zoom — and say what it is
/// ready with.
pub fn jump(app: *App, forward: bool) CommandError!void {
    const entries = try ring(app, app.frame.allocator());
    const from: ?Key = if (app.active) |a| placeOf(app, a) else null;
    const i = step(entries, from, forward) orelse {
        app.toastReplace(toast_id, "no session is ready for you", .{});
        return;
    };
    const e = entries[i];
    try sessions_mode.showReady(app, e.key.pane);
    app.focus = .{ .pane = e.key.pane };
    app.needs_render = true;
    app.toastReplace(toast_id, "{s}: {s} ({d} ready)", .{ e.kind.word(), sessions.announcedName(app, e.key.pane), entries.len });
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");

fn kindOf(app: *App, pid: PaneId) ?Kind {
    return if (entryOf(app, pid)) |e| e.kind else null;
}

fn atOf(app: *App, pid: PaneId) ?i64 {
    return if (entryOf(app, pid)) |e| e.key.at_ms else null;
}

fn testKey(rank: u1, at: i64, pane: PaneId) Key {
    return .{ .rank = rank, .at_ms = at, .pane = pane };
}

test "step: past the place it starts from, or before it, wrapping; no place starts at the head or the tail; the only one is itself; none is null" {
    const ring_ = [_]Entry{
        .{ .kind = .needs_you, .key = testKey(0, 10, 7) },
        .{ .kind = .needs_you, .key = testKey(0, 30, 2) },
        .{ .kind = .finished, .key = testKey(1, 5, 9) },
        .{ .kind = .ended, .key = testKey(1, 40, 4) },
    };
    try testing.expectEqual(@as(?usize, 1), step(&ring_, testKey(0, 10, 7), true));
    try testing.expectEqual(@as(?usize, 2), step(&ring_, testKey(0, 30, 2), true));
    try testing.expectEqual(@as(?usize, 0), step(&ring_, testKey(1, 40, 4), true));
    // A pane that was looked at keeps its place: the walk goes on past it.
    try testing.expectEqual(@as(?usize, 3), step(&ring_, testKey(1, 20, 5), true));
    try testing.expectEqual(@as(?usize, 2), step(&ring_, testKey(1, 20, 5), false));
    try testing.expectEqual(@as(?usize, 3), step(&ring_, testKey(0, 10, 7), false));
    try testing.expectEqual(@as(?usize, 0), step(&ring_, null, true));
    try testing.expectEqual(@as(?usize, 3), step(&ring_, null, false));
    const one = [_]Entry{.{ .kind = .finished, .key = testKey(1, 5, 9) }};
    try testing.expectEqual(@as(?usize, 0), step(&one, testKey(1, 5, 9), true));
    try testing.expectEqual(@as(?usize, 0), step(&one, testKey(1, 5, 9), false));
    try testing.expectEqual(@as(?usize, null), step(&.{}, null, true));
}

/// An app whose sessions are the shim's (`tools/shims/ai/claude`: a
/// pane that sleeps), their readiness driven by hand through `noteTurn`
/// — the grid's thinking row is the e2e's to prove.
const Fixture = struct {
    app: App,

    fn init() !Fixture {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const build_options = @import("build_options");
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 200, .rows = 50 });
        errdefer app.deinit();
        testing.allocator.free(app.data_root);
        app.data_root = try testing.allocator.dupe(u8, app.workspace);
        app.tree.visible = false;
        app.tree.loaded = true;
        app.cfg.ui.auto_show_sessions_on_ai_activate = false;
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/ai:{s}", .{ build_options.shims_dir, app.env.get("PATH") orelse "/usr/bin:/bin" });
        defer testing.allocator.free(path);
        try app.env.put("PATH", path);
        _ = try app.openScratch();
        return .{ .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
    }

    fn session(f: *Fixture) !PaneId {
        try command.run(&f.app, .{ .static = .@"ai.claude_code_new_tab" });
        return f.app.active.?;
    }

    fn shell(f: *Fixture) !PaneId {
        return pty_pane.open(&f.app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
    }

    /// The read `trackNeedsYou` makes, with the working state given
    /// rather than read off a grid.
    fn read(f: *Fixture, pid: PaneId, working: bool, needs_you: bool) void {
        const p = f.app.panes.pty(pid).?;
        const rose = needs_you and !p.needs_you;
        p.needs_you = needs_you;
        noteTurn(&f.app, p, working, rose);
    }

    fn look(f: *Fixture, pid: PaneId) void {
        f.app.showPane(pid);
        markSeen(&f.app);
    }

    fn tick(f: *Fixture, ms: i64) void {
        f.app.now_ms += ms;
    }

    fn expectToast(f: *Fixture, comptime fmt: []const u8, pid: PaneId, n: usize) !void {
        const want = try std.fmt.allocPrint(testing.allocator, fmt, .{ sessions.announcedName(&f.app, pid), n });
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, f.app.lastToast().?);
    }
};

test "readiness: needs you is ready; a turn ending after the last look is ready; looking clears it; another turn ending makes it ready again; working never is" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = try f.session();
    const other = try f.shell();
    app.showPane(other);
    f.tick(100);
    // Working: never ready.
    f.read(a, true, false);
    try testing.expect(entryOf(app, a) == null);
    // The turn ends while you look elsewhere: finished news.
    f.tick(100);
    f.read(a, false, false);
    try testing.expectEqual(@as(?Kind, .finished), kindOf(app, a));
    const first_at = app.now_ms;
    try testing.expectEqual(@as(?i64, first_at), atOf(app, a));
    // Still idle on a later read: no second edge, still the same news.
    f.tick(30);
    f.read(a, false, false);
    try testing.expectEqual(@as(?i64, first_at), atOf(app, a));
    // Looked at: seen.
    f.look(a);
    try testing.expect(entryOf(app, a) == null);
    // Another turn: ready again, at its new time.
    app.showPane(other);
    f.read(a, true, false);
    f.tick(50);
    f.read(a, false, false);
    try testing.expectEqual(@as(?i64, first_at + 80), atOf(app, a));
    f.look(a);
    // A question: ready, and looking at it does not answer it.
    app.showPane(other);
    f.read(a, false, true);
    try testing.expectEqual(@as(?Kind, .needs_you), kindOf(app, a));
    f.look(a);
    try testing.expectEqual(@as(?Kind, .needs_you), kindOf(app, a));
    // A turn ending on the pane you are looking at is seen at once.
    f.read(a, true, false);
    f.read(a, false, false);
    markSeen(app);
    try testing.expect(entryOf(app, a) == null);
    // The window in the background: the active pane is not being looked at.
    app.host_focused = false;
    f.read(a, true, false);
    f.read(a, false, false);
    markSeen(app);
    try testing.expectEqual(@as(?Kind, .finished), kindOf(app, a));
}

test "a shell's prompt is no turn; a session's exit is news once, and a restart takes it back" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const s = try f.session();
    const sh = try f.shell();
    const other = try f.session();
    app.showPane(other);
    // `noteRead` reads the working state off the grid, which a shell
    // never has; what matters is that a non-session never carries news.
    app.panes.pty(sh).?.turn_working = true;
    noteRead(app, sh, false);
    try testing.expect(entryOf(app, sh) == null);
    try testing.expect(!app.panes.pty(sh).?.turn_working);
    noteExit(app, sh);
    try testing.expect(entryOf(app, sh) == null);
    noteExit(app, s);
    try testing.expectEqual(@as(?Kind, .ended), kindOf(app, s));
    noteRestart(app.panes.pty(s).?);
    try testing.expect(entryOf(app, s) == null);
}

test "the ring: needs-you first, oldest wait first, then the newly finished oldest first; a step from a looked-at pane goes on; the toasts say what each is" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const quiet = try f.session();
    const fin_late = try f.session();
    const ask_late = try f.session();
    const fin_early = try f.session();
    const ask_early = try f.session();
    const ed = try f.shell();
    app.showPane(ed);
    f.read(quiet, false, false);
    for ([_]PaneId{ fin_late, fin_early }) |id| f.read(id, true, false);
    f.tick(10);
    f.read(ask_early, false, true);
    f.tick(10);
    f.read(fin_early, false, false);
    f.tick(10);
    f.read(ask_late, false, true);
    f.tick(10);
    f.read(fin_late, false, false);
    const r = try ring(app, app.frame.allocator());
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqual(ask_early, r[0].key.pane);
    try testing.expectEqual(ask_late, r[1].key.pane);
    try testing.expectEqual(fin_early, r[2].key.pane);
    try testing.expectEqual(fin_late, r[3].key.pane);

    const next: command.CommandRef = .{ .static = .@"sessions.next_waiting" };
    const prev: command.CommandRef = .{ .static = .@"sessions.prev_waiting" };
    try command.run(app, next);
    try testing.expectEqual(@as(?PaneId, ask_early), app.active);
    try f.expectToast("needs you: {s} ({d} ready)", ask_early, 4);
    try command.run(app, next);
    try testing.expectEqual(@as(?PaneId, ask_late), app.active);
    try command.run(app, next);
    try testing.expectEqual(@as(?PaneId, fin_early), app.active);
    try f.expectToast("finished: {s} ({d} ready)", fin_early, 4);
    // The frame shows it: seen. The next step goes on past it, not back to the head.
    try app.render();
    try command.run(app, next);
    try testing.expectEqual(@as(?PaneId, fin_late), app.active);
    try f.expectToast("finished: {s} ({d} ready)", fin_late, 3);
    try app.render();
    // Both finished ones looked at: the walk wraps over the questions only.
    try command.run(app, next);
    try testing.expectEqual(@as(?PaneId, ask_early), app.active);
    try f.expectToast("needs you: {s} ({d} ready)", ask_early, 2);
    try command.run(app, prev);
    try testing.expectEqual(@as(?PaneId, ask_late), app.active);
    try command.run(app, prev);
    try testing.expectEqual(@as(?PaneId, ask_early), app.active);
    // The quiet one never had news: never visited.
    try testing.expect(app.active != quiet);
    // Answered: nothing is ready.
    for ([_]PaneId{ ask_early, ask_late }) |id| app.panes.pty(id).?.needs_you = false;
    try command.run(app, next);
    try testing.expectEqualStrings("no session is ready for you", app.lastToast().?);
    try testing.expectEqual(@as(?PaneId, ask_early), app.active);
    // An exit is news, under its own word.
    app.showPane(ed);
    noteExit(app, quiet);
    try command.run(app, next);
    try testing.expectEqual(@as(?PaneId, quiet), app.active);
    try f.expectToast("ended: {s} ({d} ready)", quiet, 1);
}

test "in the sessions mode a step swaps the ready session into the focused column and the mode stays; outside it, a zoomed page takes the ready one into the zoom" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const s1 = try f.session();
    const s2 = try f.session();
    const s3 = try f.session();
    _ = s3;
    app.cfg.ai.session_columns = 2;
    app.showPane(s1);
    try sessions_mode.enter(app);
    try testing.expect(sessions_mode.showing(app));
    const layout = app.layouts.current();
    const mine = layout.leafOf(app.active.?).?;
    // The ready session sits in the OTHER column: the step must bring
    // it here, not hand the keys over to that column.
    const leaves = try layout.leaves(app.frame.allocator());
    try testing.expectEqual(@as(usize, 2), leaves.len);
    const theirs = if (leaves[0] == mine) leaves[1] else leaves[0];
    const target = layout.leaf(theirs).?.tabs.items[0];
    const was_here = layout.leaf(mine).?.active;
    f.read(target, true, false);
    f.read(target, false, false);
    try command.run(app, .{ .static = .@"sessions.next_waiting" });
    try testing.expect(sessions_mode.showing(app));
    try testing.expectEqual(@as(?PaneId, target), app.active);
    try testing.expectEqual(mine, layout.leafOf(target).?);
    try testing.expectEqual(target, layout.leaf(mine).?.active);
    // The one it covered traded places: no column emptied.
    try testing.expectEqual(theirs, layout.leafOf(was_here).?);
    sessions_mode.leave(app, false);
    try testing.expect(!sessions_mode.showing(app));

    // Outside the mode, zoomed, the ready session on another page: it
    // comes into the zoom here rather than taking you to its page.
    try command.run(app, .{ .static = .@"ai.claude_code_new_page" });
    const away = app.active.?;
    const away_page = app.layouts.active;
    @import("cmd_tab.zig").switchTab(app, 0);
    try testing.expect(app.layouts.active != away_page);
    app.showPane(s2);
    app.layouts.current().zoomed = s2;
    try testing.expectEqual(@as(?PaneId, s2), app.zoomedPane());
    f.read(away, true, false);
    f.read(away, false, false);
    for ([_]PaneId{ s1, target, was_here }) |id| app.panes.pty(id).?.unseen = .none;
    try command.run(app, .{ .static = .@"sessions.next_waiting" });
    try testing.expectEqual(@as(?PaneId, away), app.active);
    try testing.expectEqual(@as(usize, 0), app.layouts.active);
    try testing.expectEqual(@as(?PaneId, away), app.zoomedPane());
}
