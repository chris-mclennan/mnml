//! Persistent undo — a file's undo and redo stacks outlive the buffer.
//! Behind `editor.persistent_undo`: a save writes
//! `<data root>/undo/<fnv1a(abs path)>.zon` with the newest `limit`
//! snapshots of each stack, pinned to a hash of the text they belong
//! to; an open reads it back when the hash still matches (a file edited
//! by anything else in between silently starts fresh — restoring
//! offsets onto other text would be worse than no history).
//!
//! // changed: Rust kept these under `<workspace>/.mnml/undo/*.json`,
//! unconditionally. The data root keeps a repo's `.mnml/` free of
//! machine-local history, and the flag keeps a first launch free of it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const hooks = @import("../core/hooks.zig");
const undo = @import("../editor/undo.zig");

/// Snapshots written per stack; the in-memory ring keeps 2000.
pub const limit: usize = 100;
pub const dir_name = "undo";

pub const Snap = struct { text: []const u8 = "", cursor: usize = 0, anchor: ?usize = null };
pub const Stored = struct {
    text_hash: u64 = 0,
    undo: []const Snap = &.{},
    redo: []const Snap = &.{},
};

pub fn hash(text: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(text);
}

/// `<data root>/undo/<16 hex>.zon` for `file` (absolute).
pub fn pathFor(arena: Allocator, data_root: []const u8, file: []const u8) Allocator.Error![]u8 {
    var name: [16 + ".zon".len]u8 = undefined;
    const n = std.fmt.bufPrint(&name, "{x:0>16}.zon", .{hash(file)}) catch unreachable;
    return std.fs.path.join(arena, &.{ data_root, dir_name, n });
}

// ─── hooks ───────────────────────────────────────────────────────────────

pub fn onOpen(app: *App, args: hooks.HookArgs) void {
    if (!app.cfg.editor.persistent_undo or app.data_root.len == 0) return;
    const e = app.panes.editor(args.open.pane) orelse return;
    const file = e.buf.doc.path orelse return;
    _ = load(app, e, file) catch {};
}

pub fn onSavePost(app: *App, args: hooks.HookArgs) void {
    if (!app.cfg.editor.persistent_undo or app.data_root.len == 0) return;
    const e = app.panes.editor(args.save_post.pane) orelse return;
    const file = e.buf.doc.path orelse return;
    store(app, e, file) catch {};
}

// ─── store / load ────────────────────────────────────────────────────────

pub const StoreError = Allocator.Error || error{WriteFailed};

/// Write `e`'s history for `file`.
pub fn store(app: *App, e: *EditorPane, file: []const u8) StoreError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stored = try capture(arena, e.buf.editor);
    var out: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(stored, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    const target = try pathFor(arena, app.data_root, file);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, std.fs.path.dirname(target) orelse return error.WriteFailed) catch return error.WriteFailed;
    cwd.writeFile(app.io, .{ .sub_path = target, .data = out.written() }) catch return error.WriteFailed;
}

/// Read the history for `file` into `e`, if the text still matches.
/// Returns whether anything landed.
pub fn load(app: *App, e: *EditorPane, file: []const u8) Allocator.Error!bool {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try pathFor(arena, app.data_root, file);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, target, arena, .limited(64 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const stored = std.zon.parse.fromSliceAlloc(Stored, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return false,
    };
    return restore(e.buf.editor, stored);
}

/// The newest `limit` of each stack, oldest first, pinned to the text.
pub fn capture(arena: Allocator, ed: *const @import("../editor/editor.zig").Editor) Allocator.Error!Stored {
    return .{
        .text_hash = hash(ed.bytes()),
        .undo = try tail(arena, ed.doc.history.undo),
        .redo = try tail(arena, ed.doc.history.redo),
    };
}

fn tail(arena: Allocator, ring: anytype) Allocator.Error![]const Snap {
    const live = ring.items.items[ring.head..];
    const start = live.len -| limit;
    const out = try arena.alloc(Snap, live.len - start);
    for (live[start..], 0..) |s, i| out[i] = .{ .text = s.text, .cursor = s.cursor, .anchor = s.anchor };
    return out;
}

/// Push `stored` under the editor's current stacks when the hash
/// matches the text. False (and nothing changed) otherwise.
pub fn restore(ed: *@import("../editor/editor.zig").Editor, stored: Stored) Allocator.Error!bool {
    if (stored.text_hash != hash(ed.bytes())) return false;
    for (stored.undo) |s| try ed.doc.history.pushUndo(.{ .text = s.text, .cursor = s.cursor, .anchor = s.anchor });
    for (stored.redo) |s| try ed.doc.history.pushRedo(.{ .text = s.text, .cursor = s.cursor, .anchor = s.anchor });
    return true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "persistent undo: a saved file's history comes back on reopen; a file changed elsewhere starts fresh" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = try t.allocator.dupe(u8, pbuf[0..n]);
    defer t.allocator.free(root);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f.txt", .data = "one" });
    const file = try std.fs.path.join(t.allocator, &.{ root, "f.txt" });
    defer t.allocator.free(file);
    var cfg: app_mod.Config = .{};
    cfg.editor.persistent_undo = true;
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        const id = try app.openEditor(file);
        const e = app.panes.editor(id).?;
        try app.splice(e, 3, 3, " two");
        try app.splice(e, 7, 7, " three");
        try t.expectEqual(@as(usize, 2), e.buf.doc.history.undoLen());
        // The save's trailing-newline fix is an undo step of its own, so
        // the store holds three.
        try @import("../core/command.zig").run(&app, .{ .static = .@"file.save" });
        try t.expectEqual(@as(usize, 3), e.buf.doc.history.undoLen());
        const target = try pathFor(t.allocator, data, file);
        defer t.allocator.free(target);
        _ = try Io.Dir.cwd().statFile(t.io, target, .{});
    }
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        const id = try app.openEditor(file);
        const e = app.panes.editor(id).?;
        try t.expectEqual(@as(usize, 3), e.buf.doc.history.undoLen());
        _ = try app.applyOps(e, &.{.undo});
        try t.expectEqualStrings("one two three", e.buf.editor.bytes());
        _ = try app.applyOps(e, &.{.undo});
        try t.expectEqualStrings("one two", e.buf.editor.bytes());
        _ = try app.applyOps(e, &.{.undo});
        try t.expectEqualStrings("one", e.buf.editor.bytes());
    }
    // Edited outside mnml: the hash no longer matches, nothing is restored.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f.txt", .data = "one two three\nchanged elsewhere\n" });
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        const id = try app.openEditor(file);
        try t.expectEqual(@as(usize, 0), app.panes.editor(id).?.buf.doc.history.undoLen());
    }
    // Off by default: nothing is written.
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        try tmp.dir.writeFile(t.io, .{ .sub_path = "g.txt", .data = "g" });
        const g = try std.fs.path.join(t.allocator, &.{ root, "g.txt" });
        defer t.allocator.free(g);
        const id = try app.openEditor(g);
        try app.splice(app.panes.editor(id).?, 1, 1, "!");
        try @import("../core/command.zig").run(&app, .{ .static = .@"file.save" });
        const target = try pathFor(t.allocator, data, g);
        defer t.allocator.free(target);
        try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, target, .{}));
    }
}

test "persistent undo: the store keeps the newest `limit` snapshots" {
    const Editor = @import("../editor/editor.zig").Editor;
    const ed = try Editor.init(t.allocator, "");
    defer ed.deinit();
    var i: usize = 0;
    while (i < limit + 20) : (i += 1) try ed.checkpoint();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const stored = try capture(arena_state.allocator(), ed);
    try t.expectEqual(limit, stored.undo.len);
    try t.expectEqual(hash(""), stored.text_hash);
}
