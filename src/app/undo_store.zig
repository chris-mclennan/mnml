//! Persistent undo — a file's undo and redo stacks outlive the buffer.
//! Behind `editor.persistent_undo`: a save writes
//! `<data root>/undo/<fnv1a(abs path)>.zon` with the newest `limit`
//! steps of each stack, pinned to a hash of the text they belong to; an
//! open reads it back when the hash still matches (a file edited by
//! anything else in between starts fresh — restoring offsets onto
//! other text would be worse than no history).
//!
//! A step is stored as the history keeps it in memory: a hull — the
//! bytes that step changed — spelled against the step above it, never a
//! copy of the file. A keystroke in a 2 MB file is a few bytes on disk.
//! The steps kept are also held under `max_bytes` of hull text, the
//! newest first, so a file whose history could never be read back is
//! never written; a history that still cannot be read says so.
//!
//! // changed: Rust kept these under `<workspace>/.mnml/undo/*.json`,
//! unconditionally. The data root keeps a repo's `.mnml/` free of
//! machine-local history, and the flag keeps a first launch free of it.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const hooks = @import("../core/hooks.zig");
const undo = @import("../editor/undo.zig");

/// Steps written per stack; the in-memory ring keeps 2000.
pub const limit: usize = 100;
/// Hull text written per stack at most. Escaped as ZON a byte can take
/// four, so the file stays under `read_limit` whatever the text is.
pub const max_bytes: usize = 16 * 1024 * 1024;
/// The most `load` reads.
pub const read_limit: usize = 4 * 2 * max_bytes + 1024 * 1024;
pub const dir_name = "undo";

/// A full state — how the first version of the file stored a step.
/// Still read, so a history written before the hulls is not lost.
pub const Snap = struct { text: []const u8 = "", cursor: usize = 0, anchor: ?usize = null };
pub const Hull = undo.History.Hull;
pub const Stored = struct {
    text_hash: u64 = 0,
    undo: []const Snap = &.{},
    redo: []const Snap = &.{},
    /// Oldest first; the newest is spelled against the text, each older
    /// one against the step above it.
    undo_hulls: []const Hull = &.{},
    redo_hulls: []const Hull = &.{},
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
    switch (load(app, e, file) catch return) {
        .restored, .none, .stale => {},
        // Said once, where the user can see it: the next save writes a
        // new history over this one.
        .unreadable => app.toast("undo history for {s} could not be read — this session starts a new one", .{std.fs.path.basename(file)}),
    }
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

pub const Loaded = enum {
    /// The history is back.
    restored,
    /// No history for this file.
    none,
    /// A history for other text (the file changed elsewhere): dropped.
    stale,
    /// A history that could not be read or does not fit the text.
    unreadable,
};

/// Read the history for `file` into `e`, if the text still matches.
pub fn load(app: *App, e: *EditorPane, file: []const u8) Allocator.Error!Loaded {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try pathFor(arena, app.data_root, file);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, target, arena, .limited(read_limit), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .none,
        else => return .unreadable,
    };
    const stored = compat.zonParse(Stored, arena, src, null, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return .unreadable,
    };
    return restore(e.buf.editor, stored);
}

/// The newest steps of each stack, oldest first, pinned to the text.
pub fn capture(arena: Allocator, ed: *const @import("../editor/editor.zig").Editor) Allocator.Error!Stored {
    return .{
        .text_hash = hash(ed.bytes()),
        .undo_hulls = try ed.doc.history.tailHulls(arena, .undo, limit, max_bytes),
        .redo_hulls = try ed.doc.history.tailHulls(arena, .redo, limit, max_bytes),
    };
}

/// Put `stored` under the editor's (empty) stacks when the hash matches
/// the text.
pub fn restore(ed: *@import("../editor/editor.zig").Editor, stored: Stored) Allocator.Error!Loaded {
    if (stored.text_hash != hash(ed.bytes())) return .stale;
    const h = &ed.doc.history;
    if (stored.undo_hulls.len > 0 or stored.redo_hulls.len > 0) {
        if (!try h.restoreHulls(.undo, stored.undo_hulls)) return .unreadable;
        if (!try h.restoreHulls(.redo, stored.redo_hulls)) {
            h.truncateUndo(0);
            return .unreadable;
        }
        return .restored;
    }
    // The first format: whole states.
    for (stored.undo) |st| try h.pushUndo(.{ .text = st.text, .cursor = st.cursor, .anchor = st.anchor });
    for (stored.redo) |st| try h.pushRedo(.{ .text = st.text, .cursor = st.cursor, .anchor = st.anchor });
    return if (stored.undo.len + stored.redo.len > 0) .restored else .none;
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

test "persistent undo: the store keeps the newest `limit` steps" {
    const Editor = @import("../editor/editor.zig").Editor;
    const ed = try Editor.init(t.allocator, "");
    defer ed.deinit();
    var i: usize = 0;
    while (i < limit + 20) : (i += 1) try ed.checkpoint();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const stored = try capture(arena_state.allocator(), ed);
    try t.expectEqual(limit, stored.undo_hulls.len);
    try t.expectEqual(hash(""), stored.text_hash);
}

test "persistent undo: a big file's history is its changes, not copies of the file, and it comes back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = try t.allocator.dupe(u8, pbuf[0..n]);
    defer t.allocator.free(root);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    // 2 MB over 40,000 lines, 40 one-character edits: the first version
    // wrote 86 MB here (a full copy per step) and could never read it back.
    const body = try t.allocator.alloc(u8, 40_000 * 50);
    defer t.allocator.free(body);
    for (0..40_000) |i| {
        const line = body[i * 50 ..][0..50];
        @memset(line[0..49], 'a' + @as(u8, @intCast(i % 26)));
        line[49] = '\n';
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "big.txt", .data = body });
    const file = try std.fs.path.join(t.allocator, &.{ root, "big.txt" });
    defer t.allocator.free(file);
    var cfg: app_mod.Config = .{};
    cfg.editor.persistent_undo = true;
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        const id = try app.openEditor(file);
        const e = app.panes.editor(id).?;
        for (0..40) |i| {
            const at = (i * 1000 + 1) * 50 - 1;
            try app.splice(e, at, at, "Z");
        }
        try @import("../core/command.zig").run(&app, .{ .static = .@"file.save" });
        const target = try pathFor(t.allocator, data, file);
        defer t.allocator.free(target);
        const st = try Io.Dir.cwd().statFile(t.io, target, .{});
        try t.expect(st.size < 64 * 1024);
    }
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        const id = try app.openEditor(file);
        const e = app.panes.editor(id).?;
        try t.expectEqual(@as(usize, 40), e.buf.doc.history.undoLen());
        _ = try app.applyOps(e, &.{.undo});
        try t.expectEqual(@as(usize, body.len + 39), e.buf.editor.len());
        for (0..39) |_| _ = try app.applyOps(e, &.{.undo});
        try t.expectEqualStrings(body, e.buf.editor.bytes());
    }
}

test "persistent undo: hulls that do not fit the text are refused, and an unreadable file says so" {
    const Editor = @import("../editor/editor.zig").Editor;
    const ed = try Editor.init(t.allocator, "short");
    defer ed.deinit();
    // A hull reaching past the text is not a state of it.
    const bad = [_]Hull{.{ .p = 3, .s = 9, .mid = "x" }};
    try t.expectEqual(Loaded.unreadable, try restore(ed, .{ .text_hash = hash("short"), .undo_hulls = &bad }));
    try t.expectEqual(@as(usize, 0), ed.doc.history.undoLen());
    // A hull for other text is stale, not an error.
    try t.expectEqual(Loaded.stale, try restore(ed, .{ .text_hash = hash("other"), .undo_hulls = &bad }));
    // The first format still reads.
    const snaps = [_]Snap{.{ .text = "shor", .cursor = 4 }};
    try t.expectEqual(Loaded.restored, try restore(ed, .{ .text_hash = hash("short"), .undo = &snaps }));
    try t.expectEqual(@as(usize, 1), ed.doc.history.undoLen());
}
