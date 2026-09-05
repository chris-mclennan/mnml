//! Persisted macros — the registers `qa`…`q` fill outlive the process.
//! `<data root>/macros.zon` holds every register as key-spec text
//! (`buffer.zig`'s `parseKeys` notation: `ihello<esc>j`), written when a
//! recording stops and on the `exit` hook, read on `startup`. A register
//! whose text does not parse falls back to the chars it spells (the
//! notation has no failure mode); nothing is written
//! when the data root is empty (headless tests).
//!
//! // changed: Rust mnml kept macros in memory only. The registers live
//! on the `Clipboard` here (`clipboard.zig`), so one file covers every
//! buffer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const hooks = @import("../core/hooks.zig");
const buffer = @import("../editor/buffer.zig");
const Key = buffer.Key;

pub const file_name = "macros.zon";

pub const Entry = struct { reg: u8, keys: []const u8 };
pub const Stored = struct { macros: []const Entry = &.{} };

/// `<data root>/macros.zon`.
pub fn pathFor(arena: Allocator, data_root: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(arena, &.{ data_root, file_name });
}

// ─── hooks ───────────────────────────────────────────────────────────────

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    if (app.data_root.len == 0) return;
    _ = load(app) catch {};
}

pub fn onExit(app: *App, _: hooks.HookArgs) void {
    if (app.data_root.len == 0) return;
    store(app) catch {};
}

/// A recording just stopped (`dispatch.feedEditor` saw `isRecording`
/// flip): write the registers now, so a crash later loses nothing.
pub fn afterRecording(app: *App) void {
    if (app.data_root.len == 0) return;
    store(app) catch {};
}

// ─── store / load ────────────────────────────────────────────────────────

pub const StoreError = Allocator.Error || error{WriteFailed};

pub fn store(app: *App) StoreError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stored = try capture(arena, &app.clipboard);
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml macro registers — written when a recording stops and on quit.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(stored, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    const target = try pathFor(arena, app.data_root);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, app.data_root) catch return error.WriteFailed;
    cwd.writeFile(app.io, .{ .sub_path = target, .data = out.written() }) catch return error.WriteFailed;
}

/// Read the file into the clipboard's registers. Returns how many landed.
pub fn load(app: *App) Allocator.Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try pathFor(arena, app.data_root);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, target, arena, .limited(16 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    const stored = std.zon.parse.fromSliceAlloc(Stored, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return 0,
    };
    return restore(&app.clipboard, stored);
}

/// The registers as spec text, sorted by register.
pub fn capture(arena: Allocator, clip: *const buffer.Clipboard) Allocator.Error!Stored {
    var regs: std.ArrayListUnmanaged(u8) = .empty;
    var it = clip.macros.keyIterator();
    while (it.next()) |k| try regs.append(arena, k.*);
    std.mem.sort(u8, regs.items, {}, std.sort.asc(u8));
    const out = try arena.alloc(Entry, regs.items.len);
    for (regs.items, 0..) |reg, i| {
        out[i] = .{ .reg = reg, .keys = try buffer.keysToSpec(arena, clip.macros.get(reg).?) };
    }
    return .{ .macros = out };
}

/// Put every entry that parses into `clip`, replacing what is there.
pub fn restore(clip: *buffer.Clipboard, stored: Stored) Allocator.Error!usize {
    var n: usize = 0;
    for (stored.macros) |e| {
        const keys = try buffer.parseKeys(clip.gpa, e.keys);
        try clip.putMacro(e.reg, keys);
        n += 1;
    }
    return n;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn tmpRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    return gpa.dupe(u8, pbuf[0..n]);
}

test "macros: stopping a recording writes macros.zon; the next launch replays it in another file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "three\nfour\n" });
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    var cfg: app_mod.Config = .{};
    cfg.editor.input_style = .vim;
    const dispatch = @import("dispatch.zig");
    const target = try pathFor(t.allocator, data);
    defer t.allocator.free(target);
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        _ = try app.openEditor(a);
        const keys = try buffer.parseKeys(t.allocator, "qaA!<esc>jq");
        defer t.allocator.free(keys);
        for (keys) |k| try dispatch.key(&app, k);
        try t.expectEqualStrings("one!\ntwo\n", app.activeEditor().?.buf.editor.bytes());
        // Written the moment the recording stopped — no exit hook needed.
        const text = try Io.Dir.cwd().readFileAlloc(t.io, target, t.allocator, .limited(4096));
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, ".reg = 97") != null);
        try t.expect(std.mem.indexOf(u8, text, "\"A!<esc>j\"") != null);
    }
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        try t.expect(app.clipboard.macro('a') == null);
        app.hooks.emit(&app, .startup);
        try t.expectEqual(@as(usize, 4), app.clipboard.macro('a').?.len);
        _ = try app.openEditor(b);
        const keys = try buffer.parseKeys(t.allocator, "@a");
        defer t.allocator.free(keys);
        for (keys) |k| try dispatch.key(&app, k);
        try t.expectEqualStrings("three!\nfour\n", app.activeEditor().?.buf.editor.bytes());
    }
    // No data root: nothing is written.
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .cols = 80, .rows = 20 });
        defer app.deinit();
        const ks = try buffer.parseKeys(t.allocator, "qbxq");
        defer t.allocator.free(ks);
        try tmp.dir.deleteFile(t.io, "data/" ++ file_name);
        _ = try app.openEditor(a);
        for (ks) |k| try dispatch.key(&app, k);
        try t.expect(app.clipboard.macro('b') != null);
        try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, target, .{}));
    }
}

test "macros: capture / restore round-trip keeps every register" {
    var clip = buffer.Clipboard.init(t.allocator);
    defer clip.deinit();
    try clip.putMacro('a', try buffer.parseKeys(t.allocator, "ihi<esc><c-v>j<lt>"));
    try clip.putMacro('@', try buffer.parseKeys(t.allocator, "x"));
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const stored = try capture(arena_state.allocator(), &clip);
    try t.expectEqual(@as(usize, 2), stored.macros.len);
    try t.expectEqual(@as(u8, '@'), stored.macros[0].reg);
    try t.expectEqualStrings("ihi<esc><c-v>j<lt>", stored.macros[1].keys);
    var back = buffer.Clipboard.init(t.allocator);
    defer back.deinit();
    try t.expectEqual(@as(usize, 2), try restore(&back, stored));
    try t.expectEqual(@as(usize, 7), back.macro('a').?.len);
    try t.expectEqual(@as(usize, 1), back.macro('@').?.len);
}
