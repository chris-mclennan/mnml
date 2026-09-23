//! `file.*` runners: save, save all, reload, new.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const format_app = @import("lsp_format.zig");

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
    return savePane(app, app.active.?, e, .{ .may_hold = true });
}

pub const SaveOpts = struct {
    /// An autosave (`autosave.zig`): no format-on-save, no toast.
    auto: bool = false,
    /// No `saved <file>` toast: a save-all toasts once for the lot.
    quiet: bool = false,
    /// What a failure's message starts with: `save failed:`, `:w —`.
    fail_prefix: []const u8 = "save failed:",
    /// The saver can wait for the language server's edits
    /// (`lsp_format.Hold`): `file.save` and `:w` / `:wq` / `:x`. A caller
    /// that acts on the file right after the call — a save-all, a close
    /// or quit confirm's Save, autosave — cannot, and is never held.
    may_hold: bool = false,
    /// `lsp_format.finishHold` writing a held save: `save_pre` already
    /// ran for it.
    resume_held: bool = false,
};

/// Write editor pane `id` to its path — the `save_pre` / `save_post`
/// hooks either side, the conflict check after (a resolved conflict is
/// `git add`ed). THE save: `file.save`, `file.save_all`, autosave,
/// `:w` / `:wq` / `:x` / `ZZ`, `:wa` / `:wqa` and the close / quit
/// confirms' Save all come through here, so a save never skips what
/// happens after one.
///
/// A caller that can wait (`opts.may_hold`: `file.save`, `:w`) may have
/// its save held for the language server's edits (`lsp_format.Hold`):
/// `save_pre` sends willSaveWaitUntil / format-on-save, this returns
/// without writing, and the reply comes back through here
/// (`opts.resume_held`, from `lsp_format.finishHold`) to write once,
/// with the edits in it — so the hooks and the conflict check still run
/// once per real write. `lsp_format.held` tells the caller which it was.
pub fn savePane(app: *App, id: app_mod.PaneId, e: *app_mod.EditorPane, opts: SaveOpts) CommandError!void {
    const arena = app.frame.allocator();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "no file name — use :w <path>", .{});
    const rel = app.relPath(path);
    if (!opts.resume_held) {
        if (format_app.held(app, id)) {
            // A save already waiting on the server is this one: it
            // writes the text as it is when the reply lands. A caller
            // that cannot wait (a save-all, a close confirm) writes now
            // and the hold is let go — its reply finds none.
            if (opts.may_hold) return;
            format_app.forgetPane(app, id);
        }
        app.hooks.emit(app, .{ .save_pre = .{ .path = rel, .pane = id, .auto = opts.auto, .may_hold = opts.may_hold and !opts.auto } });
        // The server is formatting: `lsp_format` comes back here once
        // its edits land (or `save_wait_ms` runs out).
        if (format_app.held(app, id)) return;
    }
    // A hook may have opened a pane and moved the store: look again.
    const ed = app.panes.editor(id) orelse return;
    ed.buf.save(app.io) catch |err| {
        if (opts.auto) app.toast("autosave failed: {s}: {s}", .{ rel, @errorName(err) });
        return app.diag.fail(arena, "{s} {s}: {s}{s}", .{ opts.fail_prefix, rel, @errorName(err), ed.buf.saveFailNote() });
    };
    app.hooks.emit(app, .{ .save_post = .{ .path = rel, .pane = id, .bytes = ed.buf.editor.len() } });
    if (!opts.auto and !opts.quiet) app.toast("saved {s}", .{rel});
    // A conflicted file saved with no marker left is resolved: git add.
    if (app.panes.editor(id)) |after| @import("conflicts.zig").afterSave(app, after) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
    app.needs_render = true;
}

fn saveAllCmd(app: *App) CommandError!void {
    return saveAll(app);
}

/// Every dirty editor with a path, each through `savePane` — the one
/// save path, so `save_pre` / `save_post` (and every consumer of them:
/// a script's hook, the file watcher's own-write note, the LSP's
/// didSave) and the conflict check run for a save-all exactly as for
/// `:w`. Returns after the first failure. By index, re-fetched each
/// time: a save hook may open or close panes.
pub fn saveAll(app: *App) CommandError!void {
    return saveAllWith(app, "save failed:");
}

/// `saveAll` with the failure worded for its caller (`:wa —`). Each
/// file goes through `savePane`, hooks and conflict check included.
pub fn saveAllWith(app: *App, fail_prefix: []const u8) CommandError!void {
    var n: usize = 0;
    var i: usize = 0;
    // By index, fetched each time: a save hook may add panes.
    while (i < app.panes.slots.items.len) : (i += 1) {
        const id: app_mod.PaneId = @intCast(i);
        const e = app.panes.editor(id) orelse continue;
        if (!e.buf.doc.dirty or e.buf.doc.path == null) continue;
        try savePane(app, id, e, .{ .quiet = true, .fail_prefix = fail_prefix });
        n += 1;
    }
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

test "file.save_all and :wa go through the one save path: save_pre and save_post fire for every file" {
    // Both used to call `buf.save` in a loop of their own: the bytes
    // reached disk and no hook heard of it — a script's on-save, the
    // file watcher's note of mnml's own write, the LSP's didSave.
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.script().runString(
        \\PRE, POST = {}, {}
        \\mnml.on('save_pre', function(a) PRE[#PRE + 1] = a.path end)
        \\mnml.on('save_post', function(a) POST[#POST + 1] = a.path end)
    );
    var editors: [2]*app_mod.EditorPane = undefined;
    for ([_][]const u8{ "a.txt", "b.txt" }, 0..) |name, k| {
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        _ = try app.openPath(path);
        editors[k] = app.activeEditor().?;
    }
    for (editors) |e| {
        try e.buf.editor.setText("one");
        e.buf.doc.dirty = true;
    }
    try command.run(&app, .{ .static = .@"file.save_all" });
    try app.script().runString("assert(#PRE == 2 and #POST == 2, #PRE .. '/' .. #POST); assert(POST[1] == 'a.txt' and POST[2] == 'b.txt', POST[1])");
    for (editors) |e| {
        try t.expect(!e.buf.doc.dirty);
        try e.buf.editor.setText("two");
        e.buf.doc.dirty = true;
    }
    try @import("dispatch.zig").runExLine(&app, "wa");
    try app.script().runString("assert(#PRE == 4 and #POST == 4, #PRE .. '/' .. #POST)");
    const back = try tmp.dir.readFileAlloc(t.io, "b.txt", t.allocator, .limited(64));
    defer t.allocator.free(back);
    try t.expectEqualStrings("two\n", back);
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
