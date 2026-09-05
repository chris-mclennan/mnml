//! `buffer.*` runners: cycle the focused leaf's tabs, close, reopen —
//! and `:b`, which reaches a buffer by the number `:ls` shows or by
//! (a unique part of) its name.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const table = .{
    .@"buffer.next" = &next,
    .@"buffer.prev" = &prev,
    .@"buffer.close" = &close,
    .@"buffer.reopen" = &reopen,
    .@"buffer.last" = &alternate,
};

/// The tabs of the leaf showing the active pane, in tab order.
fn tabsOfActive(app: *App) ?[]const PaneId {
    const id = app.active orelse return null;
    const layout = app.layouts.current();
    const leaf = layout.leafOf(id) orelse return null;
    return layout.leaf(leaf).?.tabs.items;
}

/// `:bn` / `:bp`: the next tab of the leaf. With `skip_pty` the pty
/// tabs are stepped over — a vim user cycling buffers is looking for a
/// file, and a leaf full of terminals would otherwise trap the cycle.
/// When every other tab is a pty the cycle stays put.
fn cycle(app: *App, delta: i32, skip_pty: bool) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const tabs = tabsOfActive(app) orelse return error.NoActivePane;
    if (tabs.len < 2) return;
    const idx = std.mem.indexOfScalar(PaneId, tabs, id) orelse return;
    const n: i64 = @intCast(tabs.len);
    var target: usize = @intCast(@mod(@as(i64, @intCast(idx)) + delta, n));
    if (skip_pty) {
        var tries: usize = 0;
        while (tries < tabs.len and target != idx) : (tries += 1) {
            if (app.panes.pty(tabs[target]) == null) break;
            target = @intCast(@mod(@as(i64, @intCast(target)) + delta, n));
        }
        if (target == idx) return;
    }
    app.showPane(tabs[target]);
}

fn next(app: *App) CommandError!void {
    return cycle(app, 1, true);
}

/// `:b#` / `Ctrl-^`: the pane that was active before this one.
fn alternate(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = app.prev_active orelse return app.diag.fail(arena, "E23: no alternate buffer", .{});
    if (app.panes.get(id) == null) return app.diag.fail(arena, "E23: no alternate buffer", .{});
    app.showPane(id);
}

/// `:bfirst` / `:blast`: the ends of the leaf's tab strip.
pub fn firstTab(app: *App) CommandError!void {
    const tabs = tabsOfActive(app) orelse return error.NoActivePane;
    if (tabs.len > 0) app.showPane(tabs[0]);
}

pub fn lastTab(app: *App) CommandError!void {
    const tabs = tabsOfActive(app) orelse return error.NoActivePane;
    if (tabs.len > 0) app.showPane(tabs[tabs.len - 1]);
}

fn prev(app: *App) CommandError!void {
    return cycle(app, -1, true);
}

/// `:bn!` / `:bp!`: every tab, terminals included.
pub fn cycleAny(app: *App, delta: i32) CommandError!void {
    return cycle(app, delta, false);
}

/// The buffers in `:ls` order — tab order across every leaf of the
/// current layout, then anything open in the background. `:b N`
/// counts from 1 along this list. Frame arena.
pub fn listOrder(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error![]const PaneId {
    var out: std.ArrayListUnmanaged(PaneId) = .empty;
    const ordered = try app.layouts.current().allPanes(arena);
    for (ordered) |id| if (app.panes.get(id) != null) try out.append(arena, id);
    for (app.panes.slots.items, 0..) |*slot, i| {
        if (slot.* == null) continue;
        const id: PaneId = @intCast(i);
        if (std.mem.indexOfScalar(PaneId, out.items, id) != null) continue;
        try out.append(arena, id);
    }
    return out.items;
}

/// `:b N` / `:b name` / `:b#` (`:help :buffer`): the N-th buffer of
/// `:ls`, the one whose title (or path) the name matches — exactly,
/// else as a unique substring — or the alternate.
pub fn switchTo(app: *App, args_in: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const args = std.mem.trim(u8, args_in, " \t");
    if (args.len == 0) return;
    if (std.mem.eql(u8, args, "#")) return command.run(app, .{ .static = .@"buffer.last" });
    const order = try listOrder(app, arena);
    if (std.fmt.parseInt(usize, args, 10)) |n| {
        if (n == 0 or n > order.len) return app.diag.fail(arena, ":b — no buffer {d} (:ls shows {d})", .{ n, order.len });
        app.showPane(order[n - 1]);
        return;
    } else |_| {}
    for (order) |id| if (std.mem.eql(u8, app.panes.get(id).?.title(), args)) {
        app.showPane(id);
        return;
    };
    var found: ?PaneId = null;
    var hits: usize = 0;
    for (order) |id| {
        const title = app.panes.get(id).?.title();
        var hit = std.mem.indexOf(u8, title, args) != null;
        if (!hit) if (app.panes.editor(id)) |e| if (e.buf.path) |p| {
            hit = std.mem.indexOf(u8, app.relPath(p), args) != null;
        };
        if (hit) {
            hits += 1;
            found = id;
        }
    }
    if (hits == 0) return app.diag.fail(arena, ":b — no matching buffer for \"{s}\"", .{args});
    if (hits > 1) return app.diag.fail(arena, ":b — E93: more than one buffer matches \"{s}\"", .{args});
    app.showPane(found.?);
}

fn close(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    try app.closePane(id, false);
}

/// The most recently closed file comes back where its cursor was.
fn reopen(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const last = app.closed.getLastOrNull() orelse return app.diag.fail(arena, "no recently closed buffer", .{});
    const path = try arena.dupe(u8, last.path);
    _ = app.openPath(path) catch |err| return app.diag.fail(arena, "reopen {s}: {s}", .{ app.relPath(path), @errorName(err) });
    // An editor drops its entry as it loads; a preview does not, so the
    // entry that was just used goes here — a second reopen must not
    // hand back the same file.
    if (app.closed.getLastOrNull()) |still| if (std.mem.eql(u8, still.path, path)) {
        app.gpa.free(app.closed.pop().?.path);
    };
}

test "close others: the Undo chip puts the tabs back in order, the markdown preview among them, the kept tab active" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const names = [_][]const u8{ "a.txt", "b.txt", "c.md", "d.txt" };
    var ids: [4]PaneId = undefined;
    for (names, 0..) |name, i| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        ids[i] = try app.openPath(path);
    }
    try t.expect(app.panes.get(ids[2]).?.* == .md_preview);
    try command.run(&app, .{ .static = .@"buffer.close_others" });
    try t.expectEqualStrings("closed 3 tab(s)", app.undo_chip.?.label);
    try t.expectEqual(@as(usize, 3), app.closed.items.len);
    try app.takeUndo();
    try t.expectEqualStrings("reopened 3 tab(s)", app.lastToast().?);
    try t.expectEqual(@as(usize, 0), app.closed.items.len);
    const layout = app.layouts.current();
    const tabs = layout.leaf(layout.leafOf(app.active.?).?).?.tabs.items;
    try t.expectEqual(@as(usize, 4), tabs.len);
    for (names, 0..) |name, i| try t.expectEqualStrings(name, app.panes.get(tabs[i]).?.title());
    try t.expect(app.panes.get(tabs[2]).?.* == .md_preview);
    try t.expectEqualStrings("d.txt", app.panes.get(app.active.?).?.title());
}

test "buffer.next/prev cycle the leaf's tabs; close + reopen round-trip through the closed list" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        _ = try app.openPath(path);
    }
    const title = struct {
        fn of(a: *App) []const u8 {
            return a.panes.get(a.active.?).?.title();
        }
    };
    try t.expectEqualStrings("c.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.prev" });
    try t.expectEqualStrings("b.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.prev" });
    try t.expectEqualStrings("a.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.prev" });
    try t.expectEqualStrings("c.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.next" });
    try t.expectEqualStrings("a.txt", title.of(&app));
    // Close a (clean) → next tab b; reopen brings a back.
    try command.run(&app, .{ .static = .@"buffer.close" });
    try t.expectEqualStrings("b.txt", title.of(&app));
    try t.expectEqual(@as(usize, 2), app.panes.count());
    try command.run(&app, .{ .static = .@"buffer.reopen" });
    try t.expectEqualStrings("a.txt", title.of(&app));
    try t.expectEqual(@as(usize, 0), app.closed.items.len);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"buffer.reopen" }));
}

test ":b reaches a buffer by :ls number, by name, by a unique part of it, and by #" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    for ([_][]const u8{ "alpha.txt", "bravo.txt", "brew.md" }) |name| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        _ = try app.openPath(path);
    }
    const title = struct {
        fn of(a: *App) []const u8 {
            return a.panes.get(a.active.?).?.title();
        }
    };
    try app.runEx("b 1");
    try t.expectEqualStrings("alpha.txt", title.of(&app));
    try app.runEx("buffer brew");
    try t.expectEqualStrings("brew.md", title.of(&app));
    try app.runEx("b#");
    try t.expectEqualStrings("alpha.txt", title.of(&app));
    try app.runEx("b bravo.txt");
    try t.expectEqualStrings("bravo.txt", title.of(&app));
    // Ambiguous, missing, out of range: an error each, the pane unchanged.
    try t.expectError(error.Failed, app.runEx("b br"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "E93") != null);
    try t.expectError(error.Failed, app.runEx("b zzz"));
    try t.expectError(error.Failed, app.runEx("b 9"));
    try t.expectEqualStrings("bravo.txt", title.of(&app));
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "buffer.next/prev step over pty tabs; :bn! does not; a leaf of nothing but ptys stays put" {
    // A real pty: POSIX.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    var files: [2]PaneId = undefined;
    for ([_][]const u8{ "a.txt", "b.txt" }, 0..) |name, i| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        files[i] = try app.openPath(path);
    }
    // Two ptys as tabs on the same leaf, between the files: [a, b, sh1, sh2].
    const pty_pane = @import("pty_pane.zig");
    const sh1 = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh1", .placement = .tab, .kind = .command });
    const sh2 = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh2", .placement = .tab, .kind = .command });
    const title = struct {
        fn of(a: *App) []const u8 {
            return a.panes.get(a.active.?).?.title();
        }
    };
    try t.expectEqualStrings("sh2", title.of(&app));
    // From a pty, next wraps to the first file; from the last file it skips both ptys.
    try command.run(&app, .{ .static = .@"buffer.next" });
    try t.expectEqualStrings("a.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.next" });
    try t.expectEqualStrings("b.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.next" });
    try t.expectEqualStrings("a.txt", title.of(&app));
    try command.run(&app, .{ .static = .@"buffer.prev" });
    try t.expectEqualStrings("b.txt", title.of(&app));
    // The bang form walks every tab.
    try cycleAny(&app, 1);
    try t.expectEqualStrings("sh1", title.of(&app));
    try app.runEx("bn!");
    try t.expectEqualStrings("sh2", title.of(&app));
    try app.runEx("bp");
    try t.expectEqualStrings("b.txt", title.of(&app));
    // Only ptys left: the cycle stays where it is.
    try app.forceClosePane(files[0]);
    try app.forceClosePane(files[1]);
    app.showPane(sh1);
    try command.run(&app, .{ .static = .@"buffer.next" });
    try t.expectEqual(sh1, app.active.?);
    try cycleAny(&app, 1);
    try t.expectEqual(sh2, app.active.?);
}
