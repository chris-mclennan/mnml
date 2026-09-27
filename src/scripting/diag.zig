//! Script errors as diagnostics. A syntax or runtime error that names a
//! line of one of the two `init.lua` files lands in that file's
//! diagnostics — the gutter dot, the squiggle, the DIAGNOSTICS row —
//! beside a language server's (`lsp.applyScriptDiagnostics`, a source
//! that is not a server), and in one persistent toast whose click jumps
//! to the line. There is one such diagnostic at a time: a later error
//! (a hook that fails at save, a segment that throws) replaces it, and
//! a reload that runs clean clears it.
//!
//! The line comes from the message itself — Lua spells every error
//! `<chunk>:<line>: <what>`, and the chunk of a file we loaded is its
//! path (`@` + path, `luaO_chunkid`'s short form: the whole path, or
//! `...` and its tail past 60 bytes). A chunk that names neither file
//! (`=lua`, the `:lua` line) is a toast and nothing else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const lua_mod = @import("lua.zig");
const Lua = lua_mod.Lua;
const lsp = @import("../app/lsp.zig");
const types = @import("../lsp/types.zig");

/// The persistent toast's id — one at a time, replaced by the next.
pub const toast_id = "script-error";
/// The diagnostic's `source`, the way a server names itself.
pub const source = "lua";

/// Where the last error landed.
pub const Report = struct {
    /// Absolute, gpa-owned.
    path: []u8,
    /// 0-based.
    line: u32,
};

pub const Parsed = struct {
    /// The chunk as the message spells it.
    chunk: []const u8,
    /// 1-based, as Lua counts.
    line: u32,
    message: []const u8,
};

/// `<chunk>:<line>: <message>` at the head of an error (the first line
/// of a traceback). The first `:<digits>:` wins.
pub fn parse(msg: []const u8) ?Parsed {
    const first = msg[0 .. std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len];
    var i: usize = 0;
    while (i < first.len) : (i += 1) {
        if (first[i] != ':' or i + 1 >= first.len or !std.ascii.isDigit(first[i + 1])) continue;
        var j = i + 1;
        while (j < first.len and std.ascii.isDigit(first[j])) j += 1;
        if (j >= first.len or first[j] != ':') continue;
        const line = std.fmt.parseInt(u32, first[i + 1 .. j], 10) catch continue;
        return .{ .chunk = first[0..i], .line = line, .message = std.mem.trim(u8, first[j + 1 ..], " \t\r") };
    }
    return null;
}

/// The two files a script error can name, absolute, on the frame
/// arena: the user's, then the workspace's. A missing data root drops
/// the first.
pub fn initPaths(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (app.data_root.len != 0) try out.append(arena, try std.fs.path.join(arena, &.{ app.data_root, lua_mod.init_file }));
    try out.append(arena, try std.fs.path.join(arena, &.{ app.workspace, ".mnml", lua_mod.init_file }));
    return out.items;
}

/// Whether `path` (absolute) is one of the two `init.lua` files.
pub fn isInitPath(app: *App, path: []const u8) bool {
    const paths = initPaths(app, app.frame.allocator()) catch return false;
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

/// The `init.lua` a chunk name means, or null when it is neither.
fn resolve(app: *App, arena: Allocator, chunk: []const u8) Allocator.Error!?[]const u8 {
    const tail = if (std.mem.startsWith(u8, chunk, "...")) chunk[3..] else chunk;
    if (tail.len == 0) return null;
    for (try initPaths(app, arena)) |p| {
        if (std.mem.startsWith(u8, chunk, "...")) {
            if (std.mem.endsWith(u8, p, tail)) return p;
        } else if (std.mem.eql(u8, p, chunk)) return p;
    }
    return null;
}

/// Land `msg` as the file's one diagnostic. False when the message
/// names no line of an `init.lua`; nothing changes then.
pub fn report(self: *Lua, msg: []const u8) Allocator.Error!bool {
    const app = self.app;
    const arena = app.frame.allocator();
    const parsed = parse(msg) orelse return false;
    const path = (try resolve(app, arena, parsed.chunk)) orelse return false;
    const line0 = parsed.line -| 1;
    // Only one script diagnostic at a time: the previous file's goes.
    if (self.report) |old| if (!std.mem.eql(u8, old.path, path)) try lsp.applyScriptDiagnostics(app, old.path, &.{});
    const d: types.Diagnostic = .{
        .range = .{ .start = .{ .line = line0, .character = 0 }, .end = .{ .line = line0, .character = std.math.maxInt(u32) } },
        .severity = .err,
        .message = parsed.message,
        .source = source,
        .code = null,
    };
    try lsp.applyScriptDiagnostics(app, path, &.{d});
    const owned = try self.gpa.dupe(u8, path);
    if (self.report) |old| self.gpa.free(old.path);
    self.report = .{ .path = owned, .line = line0 };
    return true;
}

/// The error's toast: persistent and clickable when it landed as a
/// diagnostic (`what: init.lua:3: …`), a plain error toast otherwise.
pub fn toast(self: *Lua, what: []const u8, msg: []const u8, landed: bool) void {
    const app = self.app;
    if (landed) if (self.report) |r| if (parse(msg)) |p| {
        const text = std.fmt.allocPrint(app.frame.allocator(), "{s}: {s}:{d}: {s}", .{ what, app.relPath(r.path), r.line + 1, p.message }) catch return;
        app.toastPersistent(toast_id, text, .err) catch {};
        return;
    };
    app.toastLevel(.err, "{s}: {s}", .{ what, msg }) catch {};
}

/// A clean run: the diagnostic and its toast go.
pub fn clear(self: *Lua) Allocator.Error!void {
    const r = self.report orelse return;
    try lsp.applyScriptDiagnostics(self.app, r.path, &.{});
    self.app.dismissToast(toast_id);
    self.gpa.free(r.path);
    self.report = null;
}

/// The toast's click: the file at the line.
pub fn jump(app: *App) Allocator.Error!void {
    const r = app.script().report orelse return;
    const path = try app.frame.allocator().dupe(u8, r.path);
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (app.panes.editor(id)) |e| {
        e.buf.editor.anchor = null;
        e.buf.editor.placeCursor(@min(r.line, e.buf.editor.lineCount() -| 1), 0);
    }
    app.showPane(id);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "parse: chunk, line and message; a traceback's first line; a chunk without a line is null" {
    const p = parse("/home/me/.mnml/init.lua:12: attempt to call a nil value (field 'nope')\nstack traceback:\n\t[C]: in ?").?;
    try testing.expectEqualStrings("/home/me/.mnml/init.lua", p.chunk);
    try testing.expectEqual(@as(u32, 12), p.line);
    try testing.expectEqualStrings("attempt to call a nil value (field 'nope')", p.message);
    const q = parse("...worktrees/lua-track/.mnml/init.lua:3: unexpected symbol near 'x'").?;
    try testing.expectEqualStrings("...worktrees/lua-track/.mnml/init.lua", q.chunk);
    try testing.expectEqual(@as(u32, 3), q.line);
    try testing.expect(parse("mnml: script budget exceeded") == null);
    try testing.expect(parse("lua:1: boom") != null);
}

test "report: an error naming the workspace init.lua lands as its diagnostic; a clean reload clears it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .workspace_trusted = true, .cols = 80, .rows = 20 });
    defer app.deinit();
    const lua = app.script();
    const ws_init = try std.fs.path.join(testing.allocator, &.{ root, ".mnml", "init.lua" });
    defer testing.allocator.free(ws_init);
    // Not an init.lua: a toast, no diagnostic.
    try testing.expect(!try report(lua, "lua:1: boom"));
    try testing.expect(lua.report == null);
    // The workspace file, a runtime error on line 2.
    const msg = try std.fmt.allocPrint(testing.allocator, "{s}:2: attempt to index a nil value\nstack traceback:", .{ws_init});
    defer testing.allocator.free(msg);
    try testing.expect(try report(lua, msg));
    try testing.expectEqualStrings(ws_init, lua.report.?.path);
    try testing.expectEqual(@as(u32, 1), lua.report.?.line);
    const list = lsp.diagnosticsFor(&app, ws_init);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(types.Severity.err, list[0].severity);
    try testing.expectEqualStrings("attempt to index a nil value", list[0].message);
    try testing.expectEqualStrings(source, list[0].source.?);
    toast(lua, "hook", msg, true);
    try sdk_testing.expectPath("hook: .mnml/init.lua:2: attempt to index a nil value", app.lastToast().?);
    try testing.expectEqualStrings(toast_id, app.toasts.items[app.toasts.items.len - 1].id.?);
    // A later error replaces the line; the same toast id, so one toast.
    const msg2 = try std.fmt.allocPrint(testing.allocator, "{s}:5: boom", .{ws_init});
    defer testing.allocator.free(msg2);
    try testing.expect(try report(lua, msg2));
    toast(lua, "hook", msg2, true);
    try testing.expectEqual(@as(u32, 4), lsp.diagnosticsFor(&app, ws_init)[0].range.start.line);
    var with_id: usize = 0;
    for (app.toasts.items) |t| if (t.id != null) {
        with_id += 1;
    };
    try testing.expectEqual(@as(usize, 1), with_id);
    // The click lands on the line.
    try jump(&app);
    const e = app.activeEditor().?;
    try testing.expectEqualStrings(ws_init, e.buf.doc.path.?);
    // Clear: the list is empty and the toast is gone.
    try clear(lua);
    try testing.expectEqual(@as(usize, 0), lsp.diagnosticsFor(&app, ws_init).len);
    try testing.expect(lua.report == null);
    for (app.toasts.items) |t| try testing.expect(t.id == null);
}
