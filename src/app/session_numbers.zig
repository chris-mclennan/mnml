//! Session numbers — `sessions.focus_1` … `sessions.focus_9`: the Nth
//! session as the SESSIONS panel lists it, top to bottom (its sort, its
//! pins, its filter — `sessions.refilter`'s `filtered`), shown and
//! focused. The number is on the card (`sessions.RowView.number`), in
//! the gutter column left of the accent bar, a row under the
//! on-screen / ready / link mark, so the chord a card
//! answers to is read off the card itself; the sessions table carries
//! it in its `#` column.
//!
//! The step is the ready ring's (`sessions_mode.showReady`): in the
//! sessions mode the session is swapped into the focused column, on a
//! zoomed page it takes the zoom, a session on another tab page brings
//! that page up — as `view.focus_tab_N` does for tabs — and a docked one
//! is shown in the dock. A number past the last card toasts.
//!
//! Chords: vim `Space a 1` … `Space a 9` (the sessions leader group,
//! beside `Space a j` / `k`; `Space s` is the splits'), standard
//! `Ctrl+Alt+1` … `Ctrl+Alt+9` (`Ctrl+1…9` are the tabs', `Alt+1…9`
//! the tab pages'). In the sessions view — the sessions mode on screen,
//! or the SESSIONS panel with the keys (`sessions_mode.viewing`) —
//! plain `Ctrl+1` … `Ctrl+9` are these too, in either profile.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const sessions = @import("../sessions.zig");
const sessions_mode = @import("sessions_mode.zig");

/// The highest number a card wears — the commands stop at nine.
pub const max: usize = 9;

/// The toast a run of steps replaces.
pub const toast_id = "session-number";

pub const table = .{
    .@"sessions.focus_1" = focusRunner(1),
    .@"sessions.focus_2" = focusRunner(2),
    .@"sessions.focus_3" = focusRunner(3),
    .@"sessions.focus_4" = focusRunner(4),
    .@"sessions.focus_5" = focusRunner(5),
    .@"sessions.focus_6" = focusRunner(6),
    .@"sessions.focus_7" = focusRunner(7),
    .@"sessions.focus_8" = focusRunner(8),
    .@"sessions.focus_9" = focusRunner(9),
};

/// The pane the panel lists `n`th (1-based), as of the last
/// `refilter`; null past the end.
pub fn nth(app: *const App, n: usize) ?PaneId {
    const st = &app.sessions;
    if (n == 0 or n > st.filtered.items.len) return null;
    return st.cards.items[st.filtered.items[n - 1]].pane;
}

/// The number `pid`'s card wears (1 … 9), as of the last `refilter`;
/// null for a pane the panel does not list, or lists past nine.
pub fn numberOf(app: *const App, pid: PaneId) ?u8 {
    const st = &app.sessions;
    for (st.filtered.items[0..@min(st.filtered.items.len, max)], 0..) |idx, i| {
        if (st.cards.items[idx].pane == pid) return @intCast(i + 1);
    }
    return null;
}

/// The digit a number paints as.
pub fn digit(n: u8) []const u8 {
    const digits = "0123456789";
    return digits[n .. n + 1];
}

/// `sessions.focus_N`.
pub fn focus(app: *App, n: usize) CommandError!void {
    try sessions.refilter(app);
    const pid = nth(app, n) orelse {
        const listed = app.sessions.filtered.items.len;
        if (listed == 0)
            app.toastReplace(toast_id, "no session {d} — no sessions listed", .{n})
        else
            app.toastReplace(toast_id, "no session {d} — {d} listed", .{ n, listed });
        return;
    };
    try sessions_mode.showReady(app, pid);
    app.focus = .{ .pane = pid };
    app.needs_render = true;
}

fn focusRunner(comptime n: usize) command.CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            return focus(app, n);
        }
    }.run;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");

/// Sessions are the shim's (`tools/shims/ai/claude`: a pane that sleeps).
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
};

test "focus_N: the Nth session the panel lists, its card numbered N; another tab page is brought up; past the end toasts and moves nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    // Manual order, so the listing is the pane order.
    app.sessions.sort = .manual;
    const a = try f.session();
    const b = try f.session();
    try command.run(app, .{ .static = .@"tab.new" });
    const c = try f.session();
    try testing.expectEqual(@as(usize, 1), app.layouts.active);
    try sessions.refilter(app);
    try testing.expectEqual(@as(?u8, 1), numberOf(app, a));
    try testing.expectEqual(@as(?u8, 2), numberOf(app, b));
    try testing.expectEqual(@as(?u8, 3), numberOf(app, c));

    try command.run(app, .{ .static = .@"sessions.focus_2" });
    try testing.expectEqual(b, app.active.?);
    try testing.expectEqual(@as(usize, 0), app.layouts.active);
    try testing.expect(app.focus == .pane and app.focus.pane == b);

    try command.run(app, .{ .static = .@"sessions.focus_3" });
    try testing.expectEqual(c, app.active.?);
    try testing.expectEqual(@as(usize, 1), app.layouts.active);

    try command.run(app, .{ .static = .@"sessions.focus_1" });
    try testing.expectEqual(a, app.active.?);

    try command.run(app, .{ .static = .@"sessions.focus_7" });
    try testing.expectEqualStrings("no session 7 — 3 listed", app.lastToast().?);
    try testing.expectEqual(a, app.active.?);
}

test "focus_N follows the panel's order, pins first, not the pane order" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    app.sessions.sort = .manual;
    _ = try f.session();
    const b = try f.session();
    try sessions.refilter(app);
    const key = app.sessions.cards.items[app.sessions.filtered.items[1]].key;
    _ = try app.sessions.togglePin(app.gpa, key);
    try command.run(app, .{ .static = .@"sessions.focus_1" });
    try testing.expectEqual(b, app.active.?);
    try testing.expectEqual(@as(?u8, 1), numberOf(app, b));
}

// ─── Ctrl+1…9 in the sessions view ─────────────────────────────────────

const Key = @import("../core/key.zig").Key;
const dispatch = @import("dispatch.zig");

fn ctrlAlt(c: u21) Key {
    return .{ .code = .{ .char = c }, .mods = .{ .ctrl = true, .alt = true } };
}

/// A docked session first (its card is 1; the mode's columns skip it),
/// then two in the editor: `b` wears 2, `c` 3. Returns the scratch pane,
/// tab 1 of the leaf.
fn dockedFirst(f: *Fixture) !struct { scratch: PaneId, a: PaneId, b: PaneId, c: PaneId } {
    const app = &f.app;
    app.sessions.sort = .manual;
    const scratch = app.active.?;
    const a = try f.session();
    try command.run(app, .{ .static = .@"view.host_active_in_bottom_panel" });
    const b = try f.session();
    const c = try f.session();
    try testing.expect(@import("bottom.zig").hosts(app, a));
    try sessions.refilter(app);
    try testing.expectEqual(@as(?u8, 1), numberOf(app, a));
    try testing.expectEqual(@as(?u8, 2), numberOf(app, b));
    try testing.expectEqual(@as(?u8, 3), numberOf(app, c));
    return .{ .scratch = scratch, .a = a, .b = b, .c = c };
}

test "sessions view: in the sessions mode Ctrl+2 is the card numbered 2, a docked session first; out of it Ctrl+1 is tab 1" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const s = try dockedFirst(&f);

    try command.run(app, .{ .static = .@"sessions.mode" });
    try testing.expect(sessions_mode.viewing(app));
    try dispatch.key(app, Key.ctrl('2'));
    try testing.expectEqual(s.b, app.active.?);
    try dispatch.key(app, Key.ctrl('3'));
    try testing.expectEqual(s.c, app.active.?);
    try dispatch.key(app, Key.ctrl('2'));
    try testing.expectEqual(s.b, app.active.?);
    try testing.expect(sessions_mode.showing(app));

    try command.run(app, .{ .static = .@"sessions.mode" });
    try testing.expect(!sessions_mode.viewing(app));
    try dispatch.key(app, Key.ctrl('1'));
    try testing.expectEqual(s.scratch, app.active.?);
    // Ctrl+Alt+N reaches the numbers outside the view.
    try dispatch.key(app, ctrlAlt('3'));
    try testing.expectEqual(s.c, app.active.?);
}

test "sessions view: the SESSIONS panel with the keys takes Ctrl+N as the card number, and gives the keys to that session" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const s = try dockedFirst(&f);
    const side = @import("side.zig");
    side.place(app, side.sectionOfPanel(.sessions), true);
    try testing.expect(sessions_mode.viewing(app));
    // Card 1 is the docked session; tab 1 would be the scratch.
    try dispatch.key(app, Key.ctrl('1'));
    try testing.expectEqual(s.a, app.active.?);
    try testing.expect(app.focus == .pane and app.focus.pane == s.a);
    // The keys left the panel: the view is over.
    try testing.expect(!sessions_mode.viewing(app));
    side.place(app, side.sectionOfPanel(.sessions), true);
    try dispatch.key(app, Key.ctrl('3'));
    try testing.expectEqual(s.c, app.active.?);
}

test "sessions view: vim keeps Space a N everywhere, and takes Ctrl+N as the number only in the view" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    try app.setInputStyle(.vim);
    const s = try dockedFirst(&f);
    // From the editor (a terminal pane types its Space).
    app.setActive(s.scratch);
    app.focus = .{ .pane = s.scratch };
    const keys = try @import("../editor/buffer.zig").parseKeys(testing.allocator, "<space>a2");
    defer testing.allocator.free(keys);
    for (keys) |k| try dispatch.key(app, k);
    try testing.expectEqual(s.b, app.active.?);

    try command.run(app, .{ .static = .@"sessions.mode" });
    try dispatch.key(app, Key.ctrl('3'));
    try testing.expectEqual(s.c, app.active.?);
    try command.run(app, .{ .static = .@"sessions.mode" });
    app.setActive(s.scratch);
    app.focus = .{ .pane = s.scratch };
    try dispatch.key(app, Key.ctrl('1'));
    try testing.expectEqual(s.scratch, app.active.?);
    for (keys) |k| try dispatch.key(app, k);
    try testing.expectEqual(s.b, app.active.?);
}
