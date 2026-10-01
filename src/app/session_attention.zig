//! A session waiting on you, from wherever it is announced: the
//! `session needs input: NAME` toast is an offer whose click goes to
//! that session, and the bell's menu lists every session waiting right
//! now, each row going to it.
//!
//! "Going to a session" is the SESSIONS card's own path
//! (`sessions.focusCardPane`) when a pane here runs it; a session the
//! listing knows but no pane here runs — another terminal's — is shown
//! selected in the sessions table (`sessions_table.focusSession`, the
//! IPC `focus-session` path), since there is no pane to give the keys.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const sessions = @import("../sessions.zig");
const sessions_table = @import("sessions_table.zig");

/// The toast's button and the bell rows' prefix.
pub const toast_label = "Focus";
pub const bell_row_prefix = "Needs input: ";

/// Raise the warn toast for a session that started waiting, carrying
/// the offer to go to it. `pane` when a pane here runs it, else the
/// listing's `session_id`.
pub fn announce(app: *App, pane: ?PaneId, session_id: ?[]const u8, name: []const u8) Allocator.Error!void {
    const label = try app.gpa.dupe(u8, toast_label);
    errdefer app.gpa.free(label);
    const sid: ?[]u8 = if (session_id) |s| try app.gpa.dupe(u8, s) else null;
    errdefer if (sid) |s| app.gpa.free(s);
    try app.toastWithAction(.warn, .{ .focus_session = .{ .label = label, .pane = pane, .session_id = sid } }, "session needs input: {s}", .{name});
}

/// Go to the session: its pane when one here runs it (the one named,
/// or — for a listing's id — the pane whose command names the id now),
/// else its row in the sessions table. A session that has gone from
/// both says so.
pub fn focus(app: *App, pane: ?PaneId, session_id: ?[]const u8) CommandError!void {
    if (pane) |pid| if (app.panes.get(pid) != null) {
        sessions.focusCardPane(app, pid);
        return;
    };
    const sid = session_id orelse {
        app.toast("that session's pane is gone", .{});
        return;
    };
    if (sessions.ptyPaneOf(app, sid)) |pid| {
        sessions.focusCardPane(app, pid);
        return;
    }
    if (try sessions_table.focusSession(app, .{ .id = sid }) == null)
        app.toast("session {s} is no longer listed", .{sid[0..@min(8, sid.len)]});
}

/// A session waiting on you right now.
pub const Waiting = struct {
    pane: ?PaneId = null,
    session_id: ?[]const u8 = null,
    name: []const u8,
};

/// Every session waiting on you, on `arena`: the panes here that need
/// you (pane order), then the listing's waiting sessions of this
/// workspace no pane here runs (the EXTERNAL ones), newest first.
pub fn waiting(app: *App, arena: Allocator) Allocator.Error![]Waiting {
    var out: std.ArrayListUnmanaged(Waiting) = .empty;
    for (try sessions.waitingPanes(app, arena)) |pid|
        try out.append(arena, .{ .pane = pid, .name = try arena.dupe(u8, sessions.announcedName(app, pid)) });
    const st = &app.sessions;
    const ws_name = std.fs.path.basename(app.workspace);
    var listed: std.ArrayListUnmanaged(sessions.Item) = .empty;
    for (st.items) |it| {
        if (it.state != .waiting or st.isCleared(it.session_id)) continue;
        if (!st.all_workspaces and !sessions.isHere(app, it, ws_name)) continue;
        if (sessions.ptyPaneOf(app, it.session_id) != null) continue;
        try listed.append(arena, it);
    }
    std.mem.sort(sessions.Item, listed.items, {}, struct {
        fn lt(_: void, a: sessions.Item, b: sessions.Item) bool {
            return a.last_activity_s > b.last_activity_s;
        }
    }.lt);
    for (listed.items) |it| try out.append(arena, .{
        .session_id = try arena.dupe(u8, it.session_id),
        .name = try arena.dupe(u8, sessions.itemName(app, it)),
    });
    return out.items;
}

/// The bell menu's leading rows: one per waiting session, on `arena`
/// (the menu's own `mem`, which owns the ids the rows carry).
pub fn bellRows(app: *App, arena: Allocator) Allocator.Error![]MenuItem {
    const list = try waiting(app, arena);
    const rows = try arena.alloc(MenuItem, list.len);
    for (list, rows) |w, *r| r.* = .{
        .label = try std.fmt.allocPrint(arena, bell_row_prefix ++ "{s}", .{w.name}),
        .action = .{ .session_focus = .{ .pane = w.pane, .id = w.session_id orelse "" } },
    };
    return rows;
}

/// The toast a toast button id (`ui/toast.zig`'s body, offer or close
/// ranges) belongs to carries the go-to-session offer — what the hover
/// copy asks before it describes the box.
pub fn isSessionToast(app: *const App, id: u32) bool {
    const toast_ui = @import("../ui/toast.zig");
    if (id < toast_ui.button_base) return false;
    const i = if (id >= toast_ui.close_base) id - toast_ui.close_base else if (id >= toast_ui.action_base) id - toast_ui.action_base else id - toast_ui.button_base;
    if (i >= app.toasts.items.len) return false;
    const a = app.toasts.items[app.toasts.items.len - 1 - i].action orelse return false;
    return a == .focus_session;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const toast_mod = @import("../ui/toast.zig");
const dispatch = @import("dispatch.zig");
const context_menus = @import("context_menus.zig");
const pty_pane = @import("pty_pane.zig");
const builtin = @import("builtin");
const Io = std.Io;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 120, .rows = 40 });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// A listing adopted as the snapshot, every row in this workspace.
    fn adopt(f: *Fixture, rows: []const struct { []const u8, sessions.AgentState, i64 }) !void {
        const r = try sessions.ScanResult.create(testing.allocator, 1);
        const copy = try r.arena.allocator().alloc(sessions.Item, rows.len);
        for (rows, 0..) |row, i| {
            var it = sessions.testItem(row[0], row[1], row[2], std.fs.path.basename(f.root), row[0]);
            it.cwd = f.root;
            copy[i] = try sessions.dupeItem(r.arena.allocator(), it);
        }
        r.items = copy;
        r.at_s = Io.Timestamp.now(testing.io, .real).toSeconds();
        f.app.sessions.generation = 1;
        try sessions.handle(&f.app, r);
        f.app.sessions.scanned_once = true;
    }

    /// A plain pty pane — its `needs_you` set by hand stands in for
    /// the tracker's answer.
    fn shell(f: *Fixture) !PaneId {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        return pty_pane.open(&f.app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
    }

    /// Paint, then the first cell whose hit is button `id`.
    fn buttonAt(f: *Fixture, id: u32) !?[2]u16 {
        try f.app.render();
        var y: u16 = 0;
        while (y < f.app.screen.height) : (y += 1) {
            var x: u16 = 0;
            while (x < f.app.screen.width) : (x += 1) if (f.app.hits.at(x, y)) |h| if (h == .button and h.button == id) return .{ x, y };
        }
        return null;
    }

    /// A button arms on the press and fires on the release.
    fn click(f: *Fixture, at: [2]u16) !void {
        try f.app.handle(.{ .mouse = .{ .x = at[0], .y = at[1], .kind = .press, .button = .left } });
        try f.app.handle(.{ .mouse = .{ .x = at[0], .y = at[1], .kind = .release, .button = .left } });
    }
};

test "the needs-input toast offers Focus: clicking the toast's body goes to the session's pane — the card's path — and so does its Focus button" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const waiting_pid = try f.shell();
    const other = try f.shell();
    app.showPane(other);
    app.focus = .{ .pane = other };
    try announce(app, waiting_pid, null, "ship it");
    const t = app.toasts.items[app.toasts.items.len - 1];
    try testing.expectEqualStrings("session needs input: ship it", t.text);
    try testing.expectEqualStrings(toast_label, t.action.?.label());
    // The body: not a bare dismiss — the session comes forward.
    const body = (try f.buttonAt(toast_mod.button_base)).?;
    try f.click(body);
    try testing.expectEqual(@as(?PaneId, waiting_pid), app.active);
    try testing.expect(app.focus == .pane and app.focus.pane == waiting_pid);
    try testing.expectEqual(@as(usize, 0), app.toasts.items.len);
    // The Focus button too.
    app.showPane(other);
    app.focus = .{ .pane = other };
    try announce(app, waiting_pid, null, "ship it");
    const button = (try f.buttonAt(toast_mod.action_base)).?;
    try f.click(button);
    try testing.expectEqual(@as(?PaneId, waiting_pid), app.active);
}

test "a listing session's toast — no pane here runs it — selects its row in the sessions table; once a pane runs it, the pane" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    try f.adopt(&.{ .{ "aaaa-1", .streaming, 30 }, .{ "bbbb-2", .streaming, 20 } });
    try f.adopt(&.{ .{ "aaaa-1", .streaming, 30 }, .{ "bbbb-2", .waiting, 20 } });
    try testing.expectEqualStrings("session needs input: bbbb-2", app.lastToast().?);
    const body = (try f.buttonAt(toast_mod.button_base)).?;
    try f.click(body);
    const tp = sessions_table.focused(app).?;
    try testing.expectEqualStrings("bbbb-2", tp.selectedItem(app).?.session_id);
    // A session gone from the listing says so.
    try focus(app, null, "zzzz-9");
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "no longer listed") != null);
}

test "the bell menu leads with every waiting session — panes first, then the listing's — and a row goes to it; with none waiting the menu is the history's two rows" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    try context_menus.openBellMenu(app, 5, 5);
    try testing.expectEqual(@as(usize, 2), app.overlay.menu.items.len);
    try testing.expectEqualStrings("Show messages", app.overlay.menu.items[0].label);
    try app.handle(.{ .key = @import("../core/key.zig").Key.named(.esc) });

    const pid = try f.shell();
    const other = try f.shell();
    app.panes.pty(pid).?.needs_you = true;
    try f.adopt(&.{ .{ "old-1", .waiting, 10 }, .{ "new-2", .waiting, 40 }, .{ "busy-3", .streaming, 50 } });
    app.showPane(other);
    app.focus = .{ .pane = other };
    try context_menus.openBellMenu(app, 5, 5);
    const rows = app.overlay.menu.items;
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expect(std.mem.startsWith(u8, rows[0].label, bell_row_prefix));
    try testing.expectEqual(@as(?u32, pid), rows[0].action.session_focus.pane);
    try testing.expectEqualStrings(bell_row_prefix ++ "new-2", rows[1].label);
    try testing.expectEqualStrings(bell_row_prefix ++ "old-1", rows[2].label);
    try testing.expectEqualStrings("Show messages", rows[3].label);
    try testing.expect(rows[3].separator_before);
    // The pane's row: the pane, with the keys.
    try dispatch.runMenuActionForTest(app, rows[0].action);
    try testing.expectEqual(@as(?PaneId, pid), app.active);
    // The listing's row: its row in the table — the menu's bytes are
    // gone by the time the row runs, so this proves the copy too.
    try context_menus.openBellMenu(app, 5, 5);
    try app.handle(.{ .key = @import("../core/key.zig").Key.named(.down) });
    try app.handle(.{ .key = @import("../core/key.zig").Key.named(.enter) });
    try testing.expectEqualStrings("new-2", sessions_table.focused(app).?.selectedItem(app).?.session_id);
}
