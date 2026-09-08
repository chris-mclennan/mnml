//! The `script.*` commands: reload every `init.lua` (by hand, and on
//! every save of one), open the user's.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const hooks = @import("../core/hooks.zig");
const lua_mod = @import("../scripting/lua.zig");
const script_diag = @import("../scripting/diag.zig");

pub const table = .{
    .@"script.reload" = &reload,
    .@"script.edit_init" = &editInit,
};

/// `script.reload`: everything script-owned goes, the state reopens,
/// every `init.lua` runs again. The toast counts what came back; a file
/// that failed has toasted its error instead (and landed it as a
/// diagnostic), so the summary is not painted over it.
fn reload(app: *App) CommandError!void {
    const lua = app.script();
    try lua.reset();
    try lua.loadInitFiles();
    if (!lua.last_load_ok) return;
    const s = lua.summary();
    app.toast("scripts: reloaded — {d} command{s}, {d} hook{s} · {d} file(s) loaded", .{ s.commands, plural(s.commands), s.hooks, plural(s.hooks), lua.loaded_files });
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

/// `save_post` subscriber: a saved `init.lua` (either of the two) is
/// reloaded on the spot — the file is the config, and a config edit
/// lands when it is written.
pub fn onSavePost(app: *App, args: hooks.HookArgs) void {
    const e = app.panes.editor(args.save_post.pane) orelse return;
    const path = e.buf.doc.path orelse return;
    if (!script_diag.isInitPath(app, path)) return;
    reload(app) catch {};
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
    try t.expectEqualStrings("scripts: reloaded — 1 command, 0 hooks · 1 file(s) loaded", app.lastToast().?);
    try command.run(&app, .{ .static = .@"script.edit_init" });
    try t.expectEqualStrings("init.lua", app.panes.get(app.active.?).?.title());
}

test "saving a workspace init.lua reloads it: a new command lands, an error is a diagnostic on its line, the fix clears it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/init.lua", .data = "mnml.command{ id = 'one', run = function() end }\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .workspace_trusted = true, .cols = 80, .rows = 20 });
    defer app.deinit();
    try t.expect(app.dyn_commands.get("user.one") != null);
    // Edit the file in a pane and save: the reload is the hook's doing.
    const path = try std.fs.path.join(t.allocator, &.{ root, ".mnml", "init.lua" });
    defer t.allocator.free(path);
    const id = try app.openEditor(path);
    const e = app.panes.editor(id).?;
    try app.splice(e, 0, e.buf.editor.len(), "mnml.command{ id = 'two', run = function() end }\nmnml.on('save_post', function() end)\n");
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expect(app.dyn_commands.get("user.one") == null);
    try t.expect(app.dyn_commands.get("user.two") != null);
    // `file.save` toasts `saved …` after the hook ran; the summary is the one before.
    try t.expect(hasToast(&app, "scripts: reloaded — 1 command, 1 hook · 1 file(s) loaded"));
    // The origins carry the file and the line of each registration.
    const lua = app.script();
    try t.expectEqual(@as(usize, 2), lua.origins.items.len);
    try t.expectEqualStrings("user.two", lua.origins.items[0].name);
    try t.expectEqualStrings(path, lua.origins.items[0].file);
    try t.expectEqual(@as(u32, 1), lua.origins.items[0].line);
    try t.expectEqual(lua_mod.OriginKind.hook, lua.origins.items[1].kind);
    try t.expectEqual(@as(u32, 2), lua.origins.items[1].line);
    // A runtime error on line 2: the diagnostic and the clickable toast, no summary.
    app.dismissToasts();
    try app.splice(e, 0, e.buf.editor.len(), "mnml.command{ id = 'two', run = function() end }\nmnml.nope()\n");
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expect(!lua.last_load_ok);
    const lsp = @import("lsp.zig");
    const list = lsp.diagnosticsFor(&app, path);
    try t.expectEqual(@as(usize, 1), list.len);
    try t.expectEqual(@as(u32, 1), list[0].range.start.line);
    try t.expect(std.mem.indexOf(u8, list[0].message, "nil value") != null);
    try t.expect(hasToast(&app, "init.lua: .mnml/init.lua:2:"));
    try t.expect(!hasToast(&app, "scripts: reloaded"));
    var with_id: usize = 0;
    for (app.toasts.items) |tt| if (tt.id) |tid| {
        try t.expectEqualStrings(script_diag.toast_id, tid);
        with_id += 1;
    };
    try t.expectEqual(@as(usize, 1), with_id);
    // A syntax error lands the same way.
    try app.splice(e, 0, e.buf.editor.len(), "mnml.command{ id = 'two', run = function() end }\n\nlocal x = = 1\n");
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expectEqual(@as(u32, 2), lsp.diagnosticsFor(&app, path)[0].range.start.line);
    // The fix clears it.
    try app.splice(e, 0, e.buf.editor.len(), "mnml.command{ id = 'two', run = function() end }\n");
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expect(lua.last_load_ok);
    try t.expectEqual(@as(usize, 0), lsp.diagnosticsFor(&app, path).len);
    try t.expect(lua.report == null);
    for (app.toasts.items) |tt| try t.expect(tt.id == null);
    // A hook that errors later updates the same diagnostic.
    try app.splice(e, 0, e.buf.editor.len(), "mnml.command{ id = 'two', run = function() end }\nmnml.on('save_post', function(a) error('late') end)\n");
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expect(lua.last_load_ok);
    // That save also fired the hook — the reload happened first, so the new subscriber saw it.
    try t.expectEqual(@as(usize, 1), lsp.diagnosticsFor(&app, path).len);
    try t.expectEqual(@as(u32, 1), lsp.diagnosticsFor(&app, path)[0].range.start.line);
    try t.expect(hasToast(&app, "hook: .mnml/init.lua:2:"));
}

/// Whether a toast up right now starts with `prefix`.
fn hasToast(app: *App, prefix: []const u8) bool {
    for (app.toasts.items) |tt| if (std.mem.startsWith(u8, tt.text, prefix)) return true;
    return false;
}
