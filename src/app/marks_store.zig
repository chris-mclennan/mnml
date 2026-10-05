//! Global marks — `mA`…`mZ` name a `(file, row, col)` on the App, not
//! the buffer, so `'A` / `` `A `` reach across files: the target is
//! opened when it is not, activated, and the cursor placed (first
//! non-blank of the line for `'`, the exact column for `` ` ``).
//! Lowercase marks stay on the `Buffer` (`buffer.zig`) and in the
//! session file; uppercase ones live in `<data root>/marks.zon`,
//! written on every set / delete (cheap, and a crash loses nothing) and
//! on the `exit` hook, read on `startup`. A mark whose file is gone is
//! dropped on load. Nothing is written without a data root.
//!
//! // changed: Rust mnml kept `global_marks` in the per-workspace
//! session file. Uppercase marks are the user's, not the project's —
//! `'A` should reach the same place from any workspace — so they sit
//! beside `macros.zon` under the data root.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const hooks = @import("../core/hooks.zig");

pub const file_name = "marks.zon";

/// One global mark. `path` is absolute and gpa-owned by the map.
pub const GlobalMark = struct { path: []u8, row: usize, col: usize };
pub const Map = std.AutoHashMapUnmanaged(u8, GlobalMark);

pub const Entry = struct { letter: u8, path: []const u8, row: usize, col: usize };
pub const Stored = struct { marks: []const Entry = &.{} };

pub fn isGlobal(letter: u8) bool {
    return letter >= 'A' and letter <= 'Z';
}

pub fn deinitMap(gpa: Allocator, map: *Map) void {
    var it = map.valueIterator();
    while (it.next()) |m| gpa.free(m.path);
    map.deinit(gpa);
}

/// `<data root>/marks.zon`.
pub fn pathFor(arena: Allocator, data_root: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(arena, &.{ data_root, file_name });
}

// ─── the commands ────────────────────────────────────────────────────────

/// `m<A-Z>` on `e`: a scratch buffer has nowhere to point.
pub fn set(app: *App, e: *const EditorPane, letter: u8) Allocator.Error!void {
    const path = e.buf.doc.path orelse {
        app.toast("global marks need a saved file", .{});
        return;
    };
    const pos = e.buf.editor.rowCol();
    const copy = try app.gpa.dupe(u8, path);
    errdefer app.gpa.free(copy);
    if (app.global_marks.fetchRemove(letter)) |old| app.gpa.free(old.value.path);
    try app.global_marks.put(app.gpa, letter, .{ .path = copy, .row = pos.row, .col = pos.col });
    app.toast("mark '{c} set", .{letter});
    persist(app);
}

/// `'<A-Z>` (line) / `` `<A-Z> `` (exact): open the file when it is not,
/// activate it, place the cursor.
pub fn jump(app: *App, letter: u8, exact: bool) Allocator.Error!void {
    const m = app.global_marks.get(letter) orelse {
        app.toast("no mark '{c}", .{letter});
        return;
    };
    const here_path: ?[]const u8 = if (app.activeEditor()) |e| e.buf.doc.path else null;
    if (here_path == null or !std.mem.eql(u8, here_path.?, m.path)) {
        try app.noteRecent(m.path);
        _ = app.openEditor(m.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                app.toast("'{c}: cannot open {s}", .{ letter, app.relPath(m.path) });
                return;
            },
        };
    }
    const e = app.activeEditor() orelse return;
    const ed = e.buf.editor;
    const row = @min(m.row, ed.lineCount() - 1);
    if (exact) ed.placeCursor(row, m.col) else {
        ed.cursor = ed.firstNonWs(row);
        ed.goal_col = null;
    }
    ed.anchor = null;
    const p = ed.rowCol();
    app.toast("→ '{c} {d}:{d}", .{ letter, p.row + 1, p.col + 1 });
    app.needs_render = true;
}

/// `:delmarks A`. Returns whether there was one.
pub fn remove(app: *App, letter: u8) bool {
    const kv = app.global_marks.fetchRemove(letter) orelse return false;
    app.gpa.free(kv.value.path);
    persist(app);
    return true;
}

/// The row of `letter` when it points into `path`; null otherwise.
pub fn rowIn(app: *const App, letter: u8, path: ?[]const u8) ?usize {
    const m = app.global_marks.get(letter) orelse return null;
    const p = path orelse return null;
    return if (std.mem.eql(u8, p, m.path)) m.row else null;
}

/// The letters set, sorted, on `arena`.
pub fn letters(app: *const App, arena: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = app.global_marks.keyIterator();
    while (it.next()) |k| try out.append(arena, k.*);
    std.mem.sort(u8, out.items, {}, std.sort.asc(u8));
    return out.items;
}

fn persist(app: *App) void {
    if (app.data_root.len == 0) return;
    store(app) catch {};
}

// ─── hooks ───────────────────────────────────────────────────────────────

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    if (app.data_root.len == 0) return;
    _ = load(app) catch {};
}

pub fn onExit(app: *App, _: hooks.HookArgs) void {
    persist(app);
}

// ─── store / load ────────────────────────────────────────────────────────

pub const StoreError = Allocator.Error || error{WriteFailed};

pub fn store(app: *App) StoreError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stored = try capture(app, arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml global marks (mA–mZ) — written on every change and on quit.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(stored, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    const target = try pathFor(arena, app.data_root);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, app.data_root) catch return error.WriteFailed;
    cwd.writeFile(app.io, .{ .sub_path = target, .data = out.written() }) catch return error.WriteFailed;
}

/// Read the file into `app.global_marks` (replacing what is there). A
/// mark whose file no longer exists is dropped. Returns how many landed.
pub fn load(app: *App) Allocator.Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try pathFor(arena, app.data_root);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, target, arena, .limited(16 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    const stored = compat.zonParse(Stored, arena, src, null, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return 0,
    };
    var n: usize = 0;
    for (stored.marks) |m| {
        if (!isGlobal(m.letter) or !std.fs.path.isAbsolute(m.path)) continue;
        _ = Io.Dir.cwd().statFile(app.io, m.path, .{}) catch continue;
        const copy = try app.gpa.dupe(u8, m.path);
        errdefer app.gpa.free(copy);
        if (app.global_marks.fetchRemove(m.letter)) |old| app.gpa.free(old.value.path);
        try app.global_marks.put(app.gpa, m.letter, .{ .path = copy, .row = m.row, .col = m.col });
        n += 1;
    }
    return n;
}

pub fn capture(app: *const App, arena: Allocator) Allocator.Error!Stored {
    const ls = try letters(app, arena);
    const out = try arena.alloc(Entry, ls.len);
    for (ls, 0..) |c, i| {
        const m = app.global_marks.get(c).?;
        out[i] = .{ .letter = c, .path = m.path, .row = m.row, .col = m.col };
    }
    return .{ .marks = out };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const buffer = @import("../editor/buffer.zig");
const dispatch = @import("dispatch.zig");

fn tmpRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    return gpa.dupe(u8, pbuf[0..n]);
}

fn feed(app: *App, spec: []const u8) !void {
    const keys = try buffer.parseKeys(t.allocator, spec);
    defer t.allocator.free(keys);
    for (keys) |k| try dispatch.key(app, k);
}

test "global marks: `mA` in one file, `'A` from another opens it and lands on the line; `` `A `` is exact" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\n  two words\nthree\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b1\nb2\n" });
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    var cfg: app_mod.Config = .{};
    cfg.editor.input_style = .vim;
    const target = try pathFor(t.allocator, data);
    defer t.allocator.free(target);
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        _ = try app.openEditor(a);
        try feed(&app, "jwwmA");
        try t.expectEqualStrings("mark 'A set", app.lastToast().?);
        try t.expectEqual(@as(usize, 1), app.global_marks.count());
        try t.expectEqualStrings(a, app.global_marks.get('A').?.path);
        try t.expectEqual(@as(usize, 6), app.global_marks.get('A').?.col);
        // Written at once.
        const text = try Io.Dir.cwd().readFileAlloc(t.io, target, t.allocator, .limited(4096));
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, ".letter = 65") != null);
        // The buffer never saw it as a local mark.
        try t.expect(!app.activeEditor().?.buf.doc.marks.contains('A'));
        // From another file: `'A` opens a.txt, lands on the first non-blank.
        _ = try app.openEditor(b);
        try feed(&app, "'A");
        const e = app.activeEditor().?;
        try t.expectEqualStrings(a, e.buf.doc.path.?);
        try t.expectEqual(@as(usize, 1), e.buf.editor.rowCol().row);
        try t.expectEqual(@as(usize, 2), e.buf.editor.rowCol().col);
        try t.expectEqualStrings("→ 'A 2:3", app.lastToast().?);
        // Exact.
        _ = try app.openEditor(b);
        try feed(&app, "`A");
        try t.expectEqual(@as(usize, 6), app.activeEditor().?.buf.editor.rowCol().col);
        try t.expectEqualStrings(a, app.activeEditor().?.buf.doc.path.?);
        // Not set.
        try feed(&app, "'Z");
        try t.expectEqualStrings("no mark 'Z", app.lastToast().?);
        // A scratch buffer cannot take one.
        _ = try app.openScratch();
        try feed(&app, "mB");
        try t.expectEqualStrings("global marks need a saved file", app.lastToast().?);
        try t.expect(!app.global_marks.contains('B'));
        // `'A` as an ex address works in the file it points at, E20 elsewhere.
        _ = try app.openEditor(a);
        try dispatch.runExLine(&app, "'Ad");
        try t.expectEqualStrings("one\nthree\n", app.activeEditor().?.buf.editor.bytes());
        _ = try app.openEditor(b);
        try dispatch.runExLine(&app, "'Ad");
        try t.expectEqualStrings("E20: mark 'A not set", app.lastToast().?);
        try t.expectEqualStrings("b1\nb2\n", app.activeEditor().?.buf.editor.bytes());
        // `:marks` lists it; `:delmarks A` removes it and rewrites the file.
        try dispatch.runExLine(&app, "marks");
        try t.expect(std.mem.indexOf(u8, app.lastToast().?, "'A  a.txt:2:7") != null);
        try dispatch.runExLine(&app, "delmarks A");
        try t.expect(!app.global_marks.contains('A'));
        const after = try Io.Dir.cwd().readFileAlloc(t.io, target, t.allocator, .limited(4096));
        defer t.allocator.free(after);
        try t.expect(std.mem.indexOf(u8, after, ".letter") == null);
        // Set two more for the next launch; one will point at a deleted file.
        // (`'Ad` left a.txt two lines long in the buffer, so `G` is row 1.)
        try feed(&app, "mB");
        _ = try app.openEditor(a);
        try feed(&app, "GmC");
    }
    try tmp.dir.deleteFile(t.io, "b.txt");
    {
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        try t.expectEqual(@as(usize, 0), app.global_marks.count());
        app.hooks.emit(&app, .startup);
        try t.expectEqual(@as(usize, 1), app.global_marks.count());
        try t.expect(!app.global_marks.contains('B'));
        try t.expectEqual(@as(usize, 1), app.global_marks.get('C').?.row);
        // From a scratch buffer, `'C` opens the file.
        try t.expect(app.activeEditor() == null);
        _ = try app.openScratch();
        try feed(&app, "'C");
        try t.expectEqualStrings(a, app.activeEditor().?.buf.doc.path.?);
        try t.expectEqual(@as(usize, 1), app.activeEditor().?.buf.editor.rowCol().row);
    }
    // No data root: nothing is written.
    {
        try tmp.dir.deleteFile(t.io, "data/" ++ file_name);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .cols = 80, .rows = 20 });
        defer app.deinit();
        _ = try app.openEditor(a);
        try feed(&app, "mD");
        try t.expect(app.global_marks.contains('D'));
        try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, target, .{}));
    }
}
