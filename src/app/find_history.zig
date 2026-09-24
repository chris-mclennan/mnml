//! Find history — the queries the find bar accepted, oldest first,
//! de-duplicated against the newest and capped. `↑` / `↓` on the bar
//! recall them (past the newest is the empty query, as in vim). The
//! ring lives at `<data root>/find_history.zon`: written on every
//! accept and on the `exit` hook, read on `startup`; nothing is written
//! when the data root is empty (headless tests).
//!
//! // changed: Rust mnml kept the ring in the per-workspace session
//! file. A query is not a workspace concern — `TODO` is what you look
//! for everywhere — so one file per data root serves every workspace.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const hooks = @import("../core/hooks.zig");
const cmd_find = @import("cmd_find.zig");

pub const file_name = "find_history.zon";
pub const max_entries = 50;

pub const Stored = struct { queries: []const []const u8 = &.{} };

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

// ─── the ring ────────────────────────────────────────────────────────────

/// An accepted query joins the ring (unless it repeats the newest) and
/// the file is written. Empty queries are not remembered.
pub fn push(app: *App, query: []const u8) Allocator.Error!void {
    // The bar stays open across Enter in the standard profile, so the
    // recall position moves to "past the newest" on every push, not
    // only when the bar opens.
    defer endWalk(app);
    if (query.len == 0) return;
    const gpa = app.gpa;
    const items = app.find_history.items;
    if (items.len > 0 and std.mem.eql(u8, items[items.len - 1], query)) return;
    const copy = try gpa.dupe(u8, query);
    errdefer gpa.free(copy);
    try app.find_history.append(gpa, copy);
    while (app.find_history.items.len > max_entries) gpa.free(app.find_history.orderedRemove(0));
    if (app.data_root.len > 0) store(app) catch {};
}

/// `↑` (`dir = -1`) / `↓` (`dir = 1`) on the open bar: the neighbouring
/// entry replaces the query, and the matches follow. Older than the
/// oldest stays; newer than the newest is the empty query. The vim
/// profile's `/` recalls only the entries that start with what was
/// typed before the walk began, and past the newest gives it back
/// (`:help c_<Up>`); the standard bar walks every entry (VS Code).
pub fn recall(app: *App, dir: i8) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const n = app.find_history.items.len;
    if (app.input_style == .vim) return recallPrefixed(app, fb, dir);
    if (dir < 0) {
        if (fb.hist_cursor == 0 or n == 0) return;
        fb.hist_cursor -= 1;
    } else {
        if (fb.hist_cursor >= n) return;
        fb.hist_cursor += 1;
    }
    const q: []const u8 = if (fb.hist_cursor >= n) "" else app.find_history.items[fb.hist_cursor];
    try fb.state.setQuery(app.gpa, q);
    try cmd_find.liveUpdate(app);
}

fn recallPrefixed(app: *App, fb: *app_mod.FindBarState, dir: i8) Allocator.Error!void {
    const n = app.find_history.items.len;
    if (fb.hist_cursor > n) fb.hist_cursor = n;
    if (fb.hist_prefix == null) {
        if (dir > 0) return;
        fb.hist_prefix = try app.gpa.dupe(u8, fb.state.queryText());
        fb.hist_cursor = n;
    }
    const prefix = fb.hist_prefix.?;
    var found: ?usize = null;
    if (dir < 0) {
        var i = fb.hist_cursor;
        while (i > 0) {
            i -= 1;
            if (std.mem.startsWith(u8, app.find_history.items[i], prefix)) {
                found = i;
                break;
            }
        }
        const at = found orelse return;
        fb.hist_cursor = at;
        try fb.state.setQuery(app.gpa, app.find_history.items[at]);
    } else {
        var i = fb.hist_cursor + 1;
        while (i < n) : (i += 1) if (std.mem.startsWith(u8, app.find_history.items[i], prefix)) {
            found = i;
            break;
        };
        if (found) |at| {
            fb.hist_cursor = at;
            try fb.state.setQuery(app.gpa, app.find_history.items[at]);
        } else {
            // Past the newest match: the typed text again.
            try fb.state.setQuery(app.gpa, prefix);
            endWalk(app);
        }
    }
    try cmd_find.liveUpdate(app);
}

/// The query was edited: the next `↑` starts a walk from it.
pub fn endWalk(app: *App) void {
    const fb = &(app.find_bar orelse return);
    if (fb.hist_prefix) |pfx| app.gpa.free(pfx);
    fb.hist_prefix = null;
    fb.hist_cursor = app.find_history.items.len;
}

// ─── store / load ────────────────────────────────────────────────────────

pub const StoreError = Allocator.Error || error{WriteFailed};

pub fn store(app: *App) StoreError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const queries = try arena.alloc([]const u8, app.find_history.items.len);
    for (app.find_history.items, 0..) |q, i| queries[i] = q;
    const stored: Stored = .{ .queries = queries };
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml find history — the find bar's ↑ / ↓, newest last.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(stored, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    const target = try pathFor(arena, app.data_root);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, app.data_root) catch return error.WriteFailed;
    cwd.writeFile(app.io, .{ .sub_path = target, .data = out.written() }) catch return error.WriteFailed;
}

/// Read the file into the ring, replacing it. Returns how many landed.
pub fn load(app: *App) Allocator.Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try pathFor(arena, app.data_root);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, target, arena, .limited(1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    const stored = std.zon.parse.fromSliceAlloc(Stored, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return 0,
    };
    for (app.find_history.items) |q| app.gpa.free(q);
    app.find_history.clearRetainingCapacity();
    const from = stored.queries.len -| max_entries;
    for (stored.queries[from..]) |q| try app.find_history.append(app.gpa, try app.gpa.dupe(u8, q));
    return app.find_history.items.len;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = @import("../core/key.zig").Key;
const command = @import("../core/command.zig");

fn tmpRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    return gpa.dupe(u8, pbuf[0..n]);
}

fn typeQuery(app: *App, q: []const u8) !void {
    try command.run(app, .{ .static = .@"find.find" });
    for (q) |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
}

test "find history: Enter remembers the query (de-duped, a miss too); ↑ / ↓ walk the ring and past the newest is empty; the file round-trips" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\nbeta\nalpha\n" });
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        _ = try app.openEditor(a);
        try typeQuery(&app, "alpha");
        try typeQuery(&app, "zzz"); // a miss is still recallable
        try typeQuery(&app, "zzz"); // not twice in a row
        try typeQuery(&app, "beta");
        try t.expectEqual(@as(usize, 3), app.find_history.items.len);
        try t.expectEqualStrings("alpha", app.find_history.items[0]);
        try t.expectEqualStrings("beta", app.find_history.items[2]);
        // The bar: ↑ recalls newest first, the matches follow; ↓ past the newest clears.
        try command.run(&app, .{ .static = .@"find.find" });
        const e = app.activeEditor().?;
        try app.handle(.{ .key = Key.named(.up) });
        try t.expectEqualStrings("beta", app.find_bar.?.state.queryText());
        try t.expectEqual(@as(usize, 1), e.find.matches.items.len);
        try app.handle(.{ .key = Key.named(.up) });
        try app.handle(.{ .key = Key.named(.up) });
        try t.expectEqualStrings("alpha", app.find_bar.?.state.queryText());
        try t.expectEqual(@as(usize, 2), e.find.matches.items.len);
        try app.handle(.{ .key = Key.named(.up) }); // older than the oldest: stays
        try t.expectEqualStrings("alpha", app.find_bar.?.state.queryText());
        try app.handle(.{ .key = Key.named(.down) });
        try t.expectEqualStrings("zzz", app.find_bar.?.state.queryText());
        try app.handle(.{ .key = Key.named(.down) });
        try app.handle(.{ .key = Key.named(.down) });
        try t.expectEqualStrings("", app.find_bar.?.state.queryText());
        try t.expectEqual(@as(usize, 0), e.find.matches.items.len);
        try app.handle(.{ .key = Key.named(.esc) });
        // Written on every accept.
        const target = try pathFor(t.allocator, data);
        defer t.allocator.free(target);
        const text = try Io.Dir.cwd().readFileAlloc(t.io, target, t.allocator, .limited(4096));
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "\"beta\"") != null);
    }
    // The next launch reads it back on the startup hook.
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 80, .rows = 20 });
        defer app.deinit();
        try t.expectEqual(@as(usize, 0), app.find_history.items.len);
        app.hooks.emit(&app, .startup);
        try t.expectEqual(@as(usize, 3), app.find_history.items.len);
        try t.expectEqualStrings("zzz", app.find_history.items[1]);
    }
    // No data root: the ring works in memory and nothing is written.
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
        defer app.deinit();
        _ = try app.openEditor(a);
        try typeQuery(&app, "gamma");
        try t.expectEqual(@as(usize, 1), app.find_history.items.len);
        try t.expectError(error.FileNotFound, tmp.dir.access(t.io, file_name, .{}));
    }
}

test "find history: vim's / recalls only the entries that start with the typed text; Down past the newest gives it back" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("foo bar\nbaz\nqux\nbar\n");
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try typeQuery(&app, "baz");
    try typeQuery(&app, "bar");
    try typeQuery(&app, "qux");
    try command.run(&app, .{ .static = .@"find.find" });
    try app.handle(.{ .key = Key.char('b') });
    try app.handle(.{ .key = Key.named(.up) });
    try t.expectEqualStrings("bar", app.find_bar.?.state.queryText());
    try app.handle(.{ .key = Key.named(.up) });
    try t.expectEqualStrings("baz", app.find_bar.?.state.queryText());
    try app.handle(.{ .key = Key.named(.up) }); // nothing older starts with `b`
    try t.expectEqualStrings("baz", app.find_bar.?.state.queryText());
    try app.handle(.{ .key = Key.named(.down) });
    try t.expectEqualStrings("bar", app.find_bar.?.state.queryText());
    try app.handle(.{ .key = Key.named(.down) });
    try t.expectEqualStrings("b", app.find_bar.?.state.queryText());
    // Typing starts a new walk from the new text.
    try app.handle(.{ .key = Key.named(.backspace) });
    try app.handle(.{ .key = Key.char('q') });
    try app.handle(.{ .key = Key.named(.up) });
    try t.expectEqualStrings("qux", app.find_bar.?.state.queryText());
    try app.handle(.{ .key = Key.named(.esc) });
}
