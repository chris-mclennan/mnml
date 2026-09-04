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

fn cycle(app: *App, delta: i32) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const tabs = tabsOfActive(app) orelse return error.NoActivePane;
    if (tabs.len < 2) return;
    const idx = std.mem.indexOfScalar(PaneId, tabs, id) orelse return;
    const n: i64 = @intCast(tabs.len);
    const target: usize = @intCast(@mod(@as(i64, @intCast(idx)) + delta, n));
    app.showPane(tabs[target]);
}

fn next(app: *App) CommandError!void {
    return cycle(app, 1);
}

fn prev(app: *App) CommandError!void {
    return cycle(app, -1);
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
