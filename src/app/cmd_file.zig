//! `file.*` runners: save, save all, reload, new.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const table = .{
    .@"file.save" = &save,
    .@"file.save_all" = &saveAllCmd,
    .@"file.reload" = &reload,
    .@"file.new" = &new,
};

fn save(app: *App) CommandError!void {
    return saveCurrent(app);
}

/// Write the active editor to its path. Scratch buffers are refused
/// with a reason; `:w <path>` is how they get one.
pub fn saveCurrent(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    // A request pane writes itself back into its source block.
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.* == .request) return @import("http.zig").saveToSource(app);
    // A ZON tree writes its working text.
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.* == .zon) return @import("zon_pane.zig").save(app, id);
    const e = try app.requireEditor();
    if (e.buf.doc.path == null) return app.diag.fail(arena, "no file name — use :w <path>", .{});
    return savePane(app, app.active.?, e, .{});
}

pub const SaveOpts = struct {
    /// An autosave (`autosave.zig`): no format-on-save, no toast.
    auto: bool = false,
};

/// Write editor pane `id` to its path — the hooks either side, the
/// conflict check after. What `file.save` and autosave both run.
pub fn savePane(app: *App, id: app_mod.PaneId, e: *app_mod.EditorPane, opts: SaveOpts) CommandError!void {
    const arena = app.frame.allocator();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "no file name — use :w <path>", .{});
    const rel = app.relPath(path);
    app.hooks.emit(app, .{ .save_pre = .{ .path = rel, .pane = id, .auto = opts.auto } });
    e.buf.save(app.io) catch |err| {
        if (opts.auto) app.toast("autosave failed: {s}: {s}", .{ rel, @errorName(err) });
        return app.diag.fail(arena, "save failed: {s}: {s}", .{ rel, @errorName(err) });
    };
    app.hooks.emit(app, .{ .save_post = .{ .path = rel, .pane = id, .bytes = e.buf.editor.len() } });
    if (!opts.auto) app.toast("saved {s}", .{rel});
    // A conflicted file saved with no marker left is resolved: git add.
    @import("conflicts.zig").afterSave(app, e) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
    app.needs_render = true;
}

fn saveAllCmd(app: *App) CommandError!void {
    return saveAll(app);
}

/// Every dirty editor with a path. Returns after the first failure.
pub fn saveAll(app: *App) CommandError!void {
    var n: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .editor => |*e| if (e.buf.doc.dirty and e.buf.doc.path != null) {
            e.buf.save(app.io) catch |err| return app.diag.fail(app.frame.allocator(), "save failed: {s}: {s}", .{ app.relPath(e.buf.doc.path.?), @errorName(err) });
            n += 1;
        },
        else => {},
    };
    app.toast("saved {d} file(s)", .{n});
}

fn reload(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try app.requireEditor();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "reload — no file name", .{});
    if (e.buf.doc.dirty) return app.diag.fail(arena, "reload refused — unsaved changes", .{});
    const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(1 << 30)) catch |err| return app.diag.fail(arena, "reload — {s}", .{@errorName(err)});
    e.buf.editor.setText(text) catch return error.OutOfMemory;
    e.buf.markSaved() catch return error.OutOfMemory;
    e.syntax.dirty = true;
    app.needs_render = true;
    app.toast("reloaded {s}", .{app.relPath(path)});
}

/// A scratch buffer — or, with the tree focused, a prompt for a path
/// beside the selected row (the tree's `New file…`).
fn new(app: *App) CommandError!void {
    if (app.focus == .tree and app.tree.visible) return @import("tree.zig").promptNewFile(app);
    _ = app.openScratch() catch return error.OutOfMemory;
}

test "file.save writes the active buffer and clears dirty; a scratch buffer is refused" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try t.expectError(error.NoActivePane, command.run(&app, .{ .static = .@"file.save" }));
    _ = try app.openScratch();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"file.save" }));
    try t.expectEqualStrings("no file name — use :w <path>", app.lastToast().?);
    const path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(path);
    _ = try app.openPath(path);
    const e = app.activeEditor().?;
    try e.buf.editor.setText("hello");
    e.buf.doc.dirty = true;
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expect(!e.buf.doc.dirty);
    const back = try tmp.dir.readFileAlloc(t.io, "a.txt", t.allocator, .limited(64));
    defer t.allocator.free(back);
    try t.expectEqualStrings("hello\n", back); // save adds the terminating newline
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
