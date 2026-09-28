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
const scripts = @import("scripts.zig");

pub const table = .{
    .@"script.reload" = &reload,
    .@"script.edit_init" = &editInit,
    .@"script.run_selection" = &runSelection,
};

/// `script.run_selection`: the selected lines — whole lines, however
/// the selection sits in them — or the cursor line, run in the script
/// state as they are; what they return is the toast (`2`, `hello`,
/// `nil`), a run that returns nothing says how many lines ran.
fn runSelection(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = app.activeEditor() orelse return app.diag.fail(arena, "no active editor", .{});
    const ed = e.buf.editor;
    const text = ed.bytes();
    const range = ed.selection() orelse [2]usize{ ed.cursor, ed.cursor };
    const first = ed.lineOfByte(range[0]);
    // A selection ending at a line's first byte does not take that line.
    const last_byte = if (range[1] > range[0] and range[1] > 0) range[1] - 1 else range[1];
    const last = @max(first, ed.lineOfByte(last_byte));
    const src = text[ed.lineStart(first)..ed.lineEnd(last)];
    if (std.mem.trim(u8, src, " \t\r\n").len == 0) return app.diag.fail(arena, "lua: nothing to run", .{});
    const lua = app.script();
    const result = lua.eval(src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return app.diag.fail(arena, "lua: {s}", .{lua.last_error orelse "error"}),
    };
    if (result) |r| {
        app.toast("lua: {s}", .{r});
    } else {
        const n = last - first + 1;
        app.toast("lua: ran {d} line{s}", .{ n, if (n == 1) "" else "s" });
    }
}

/// `script.reload`: everything script-owned goes, the state reopens,
/// every `init.lua` runs again. The toast counts what came back; a file
/// that failed has toasted its error instead (and landed it as a
/// diagnostic), so the summary is not painted over it.
fn reload(app: *App) CommandError!void {
    const lua = app.script();
    try lua.reset();
    try lua.loadInitFiles();
    // // changed (lua-install): every installed script goes off and on
    // again with the `init.lua` files — each in its own state, so one
    // that errors is one disabled row and not a failed reload.
    try scripts.reloadAll(app);
    if (!lua.last_load_ok) return;
    const s = lua.summary();
    const n = app.scripts.entries.items.len;
    if (n == 0) {
        app.toast("scripts: reloaded — {d} command{s}, {d} hook{s} · {d} file(s) loaded", .{ s.commands, plural(s.commands), s.hooks, plural(s.hooks), lua.loaded_files });
    } else {
        app.toast("scripts: reloaded — {d} command{s}, {d} hook{s} · {d} file(s) loaded · {d} installed script{s}", .{ s.commands, plural(s.commands), s.hooks, plural(s.hooks), lua.loaded_files, n, plural(@intCast(n)) });
    }
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
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 60, .rows = 12 });
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

test "script.run_selection: the cursor line, an expression's value, the selected lines, an error" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"script.run_selection" }));
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try app.splice(e, 0, 0, "x = 20\nmnml.toast('from ' .. x)\nx + 1\nerror('nope')\n");
    // Line 1 sets a global; nothing comes back.
    e.buf.editor.placeCursor(0, 0);
    try command.run(&app, .{ .static = .@"script.run_selection" });
    try t.expectEqualStrings("lua: ran 1 line", app.lastToast().?);
    // Line 3 is an expression: its value.
    e.buf.editor.placeCursor(2, 3);
    try command.run(&app, .{ .static = .@"script.run_selection" });
    try t.expectEqualStrings("lua: 21", app.lastToast().?);
    // Lines 1–2 selected (the selection ends mid-line 2): the toast the script made, then the count.
    e.buf.editor.setSelection(2, e.buf.editor.lineStart(1) + 4);
    try command.run(&app, .{ .static = .@"script.run_selection" });
    try t.expectEqualStrings("lua: ran 2 lines", app.lastToast().?);
    try t.expect(hasToast(&app, "from 20"));
    // Line 4 errors: the message names the chunk and the line.
    e.buf.editor.anchor = null;
    e.buf.editor.placeCursor(3, 0);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"script.run_selection" }));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "lua: selection:1: nope") != null);
    try t.expectEqual(@as(i32, 0), app.script().L.getTop());
}

/// Whether a toast up right now starts with `prefix`.
/// A toast starting with `prefix`; a path in it reads with the
/// platform's separator.
fn hasToast(app: *App, prefix: []const u8) bool {
    for (app.toasts.items) |tt| if (@import("mnml_sdk").testing.pathStartsWith(tt.text, prefix)) return true;
    return false;
}
