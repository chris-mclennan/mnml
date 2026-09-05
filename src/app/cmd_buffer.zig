//! `buffer.*` runners: cycle the focused leaf's tabs, close, reopen.

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

fn prev(app: *App) CommandError!void {
    return cycle(app, -1, true);
}

/// `:bn!` / `:bp!`: every tab, terminals included.
pub fn cycleAny(app: *App, delta: i32) CommandError!void {
    return cycle(app, delta, false);
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
