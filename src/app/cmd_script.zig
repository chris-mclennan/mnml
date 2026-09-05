//! The `script.*` commands: reload every `init.lua`, open the user's.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const lua_mod = @import("../scripting/lua.zig");

pub const table = .{
    .@"script.reload" = &reload,
    .@"script.edit_init" = &editInit,
};

/// `script.reload`: everything script-owned goes, the state reopens,
/// every `init.lua` runs again.
fn reload(app: *App) CommandError!void {
    const lua = app.script();
    try lua.reset();
    try lua.loadInitFiles();
    app.toast("init.lua: {d} file(s) loaded", .{lua.loaded_files});
}

/// `script.edit_init`: the data root's `init.lua` in an editor — a new
/// buffer at that path when it does not exist yet.
fn editInit(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (app.data_root.len == 0) return app.diag.fail(arena, "no data root (run with a config)", .{});
    const path = try std.fs.path.join(arena, &.{ app.data_root, lua_mod.init_file });
    _ = app.openEditor(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "{s}: {s}", .{ path, @errorName(err) }),
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "script.reload runs the data root's init.lua; script.edit_init opens it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "init.lua", .data = "mnml.command{ id = 'from_init', run = function() end }" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .data_root = root, .cols = 60, .rows = 12 });
    defer app.deinit();
    // Loaded at init.
    try t.expect(app.dyn_commands.get("user.from_init") != null);
    // A changed file lands on reload.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "init.lua", .data = "mnml.command{ id = 'second', run = function() end }" });
    try command.run(&app, .{ .static = .@"script.reload" });
    try t.expect(app.dyn_commands.get("user.from_init") == null);
    try t.expect(app.dyn_commands.get("user.second") != null);
    try t.expectEqualStrings("init.lua: 1 file(s) loaded", app.lastToast().?);
    try command.run(&app, .{ .static = .@"script.edit_init" });
    try t.expectEqualStrings("init.lua", app.panes.get(app.active.?).?.title());
}
