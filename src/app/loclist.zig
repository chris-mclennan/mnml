//! Location lists: vim's per-window quickfix. Every `EditorPane` owns
//! one (`loclist` + `loc_idx`, `src/app/pane.zig`). `:lexpr` fills the
//! active editor's from `path:line:col:text` lines, `:lopen` /
//! `:lwindow` shows it in the `.location` list pane — an empty list is
//! seeded from the file's LSP diagnostics first — `:lclose` drops the
//! pane, and `:lnext` / `:lprev` / `:lfirst` / `:llast` walk it: the
//! entry's file opens, the cursor lands on its line and column, and the
//! toast reads `(i of n) text`. Off the end is vim's `E553: No more
//! items`; no list at all is `E776: No location list`.
//!
//! The verbs live in `ex.zig`'s table; this file is their runners.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const PaneId = app_mod.PaneId;
const ListPane = app_mod.ListPane;
const Entry = ListPane.Entry;
const command = @import("../core/command.zig");
const os_path = @import("../core/os_path.zig");
const CommandError = command.CommandError;
const cmd_view = @import("cmd_view.zig");
const lsp = @import("lsp.zig");

pub const Where = enum { first, last, next, prev };

/// The editor whose list a verb acts on: the active one, else the
/// editor focused last — so `:lnext` typed while the list pane has
/// focus still walks the list that pane shows.
fn owner(app: *App) CommandError!*EditorPane {
    if (app.activeEditor()) |e| return e;
    if (app.last_editor) |id| if (app.panes.editor(id)) |e| return e;
    return app.diag.fail(app.frame.allocator(), "no active editor", .{});
}

/// The one `.location` list pane, if it is open.
fn listPane(app: *App) ?struct { id: PaneId, list: *ListPane } {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .list => |*l| if (l.kind == .location) return .{ .id = @intCast(i), .list = l },
        else => {},
    };
    return null;
}

/// `path:line:col:text`, one entry per line; a line without colons is
/// its own path and text (the shape `:cexpr` reads too).
fn parseEntries(gpa: Allocator, args: []const u8) Allocator.Error![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, args, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // The path ends at its first colon — after a drive letter on
        // Windows (`C:\src\a.zig:12:3: msg`).
        const loc = os_path.splitLocation(line, .native);
        const path = loc.path;
        var parts = std.mem.splitScalar(u8, loc.rest, ':');
        const ln = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
        const col = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
        const text = parts.rest();
        const owned_text = try gpa.dupe(u8, if (text.len > 0) text else line);
        errdefer gpa.free(owned_text);
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        try entries.append(gpa, .{ .text = owned_text, .path = owned_path, .line = ln, .col = col });
    }
    return entries.toOwnedSlice(gpa);
}

/// Owned copies of `entries` — what the list pane takes, so the
/// editor's own list survives the pane closing.
fn copies(gpa: Allocator, entries: []const Entry) Allocator.Error![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, out.items);
        out.deinit(gpa);
    }
    for (entries) |e| {
        const text = try gpa.dupe(u8, e.text);
        errdefer gpa.free(text);
        const path: ?[]u8 = if (e.path) |p| try gpa.dupe(u8, p) else null;
        errdefer if (path) |p| gpa.free(p);
        try out.append(gpa, .{ .text = text, .path = path, .line = e.line, .col = e.col });
    }
    return out.toOwnedSlice(gpa);
}

/// `:lexpr <lines>`: the active editor's list is replaced. An open
/// location pane refills in place (focus stays where it is).
pub fn lexpr(app: *App, args: []const u8) CommandError!void {
    const e = try owner(app);
    const gpa = app.gpa;
    const entries = try parseEntries(gpa, args);
    ListPane.freeEntries(gpa, e.loclist.items);
    e.loclist.deinit(gpa);
    e.loclist = .fromOwnedSlice(entries);
    e.loc_idx = null;
    if (listPane(app)) |lp| {
        const fresh = try copies(gpa, e.loclist.items);
        lp.list.deinit();
        lp.list.entries = .fromOwnedSlice(fresh);
        lp.list.cursor = 0;
        lp.list.scroll = 0;
    }
    app.toast("location list: {d} entr{s}", .{ entries.len, if (entries.len == 1) "y" else "ies" });
    app.needs_render = true;
}

/// An empty list takes the file's LSP diagnostics, in their sorted
/// order, as `path:line:col:message` entries.
fn seedFromDiagnostics(app: *App, e: *EditorPane) Allocator.Error!void {
    const path = e.buf.doc.path orelse return;
    const diags = lsp.diagnosticsFor(app, path);
    if (diags.len == 0) return;
    const gpa = app.gpa;
    const rel = app.relPath(path);
    for (diags) |d| {
        const text = try gpa.dupe(u8, d.message);
        errdefer gpa.free(text);
        const p = try gpa.dupe(u8, rel);
        errdefer gpa.free(p);
        try e.loclist.append(gpa, .{ .text = text, .path = p, .line = d.range.start.line + 1, .col = d.range.start.character + 1 });
    }
    e.loc_idx = null;
}

/// `:lopen` / `:lwindow`: the active editor's list in the location
/// pane, the cursor on the current entry.
pub fn open(app: *App) CommandError!void {
    const e = try owner(app);
    if (e.loclist.items.len == 0) try seedFromDiagnostics(app, e);
    if (e.loclist.items.len == 0) return app.diag.fail(app.frame.allocator(), "E776: No location list", .{});
    const cursor = e.loc_idx orelse 0;
    const entries = try copies(app.gpa, e.loclist.items);
    try cmd_view.openListPane(app, .location, entries);
    if (listPane(app)) |lp| lp.list.cursor = cursor;
}

/// `:lclose`: the location pane goes; nothing open is not an error.
pub fn close(app: *App) CommandError!void {
    const lp = listPane(app) orelse return;
    try app.forceClosePane(lp.id);
}

/// Enter on a location row: the owning editor's index follows it.
pub fn noteEnter(app: *App, idx: usize) void {
    const e = owner(app) catch return;
    if (idx < e.loclist.items.len) e.loc_idx = idx;
}

/// `:lfirst` / `:llast` / `:lnext` / `:lprev`: the entry opens the way
/// Enter on its row does. A fresh list has no current entry, so the
/// first `:lnext` lands on entry 1 and `:lprev` is already off the
/// front.
pub fn go(app: *App, where: Where) CommandError!void {
    const arena = app.frame.allocator();
    const e = try owner(app);
    const n = e.loclist.items.len;
    if (n == 0) return app.diag.fail(arena, "E776: No location list", .{});
    const idx: usize = switch (where) {
        .first => 0,
        .last => n - 1,
        .next => if (e.loc_idx) |i| (if (i + 1 < n) i + 1 else return app.diag.fail(arena, "E553: No more items", .{})) else 0,
        .prev => if (e.loc_idx) |i| (if (i > 0) i - 1 else return app.diag.fail(arena, "E553: No more items", .{})) else return app.diag.fail(arena, "E553: No more items", .{}),
    };
    e.loc_idx = idx;
    // Opening a file may add a pane and move the pane store: copy what
    // the jump needs out of `e` first and never touch it again.
    const entry = e.loclist.items[idx];
    const text = try arena.dupe(u8, entry.text);
    const rel = try arena.dupe(u8, entry.path orelse return app.diag.fail(arena, "E42: entry {d} names no file", .{idx + 1}));
    const line = entry.line;
    const col = entry.col;
    const abs = try app.absPath(rel);
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
    if (app.panes.editor(id)) |ed| ed.buf.editor.placeCursor(line -| 1, col -| 1);
    if (listPane(app)) |lp| lp.list.cursor = idx;
    app.toast("({d} of {d}) {s}", .{ idx + 1, n, text });
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    app: App,
    tmp: testing.TmpDir,
    root: []u8,

    fn init(src: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 60, .rows = 12 });
        errdefer app.deinit();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "doc.txt", .data = src });
        _ = try app.openPath(try pathOf(&app, root, "doc.txt"));
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn pathOf(app: *App, root: []const u8, rel: []const u8) ![]const u8 {
        return std.fs.path.join(app.frame.allocator(), &.{ root, rel });
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn ex(f: *Fixture, line: []const u8) !void {
        f.app.frame.begin();
        try @import("ex.zig").run(&f.app, line);
    }

    fn row(f: *Fixture) usize {
        return f.app.activeEditor().?.buf.editor.rowCol().row;
    }
};

test "the location list pane paints a 100k-char entry clipped without overflowing the cell sum" {
    var f = try Fixture.init("one\ntwo\n");
    defer f.deinit();
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'q');
    const expr = try std.fmt.allocPrint(testing.allocator, "lexpr doc.txt:2:1:{s}", .{long});
    defer testing.allocator.free(expr);
    try f.ex(expr);
    try f.ex("lopen");
    try f.app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "location list") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "doc.txt:2:1 qqqq") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "qqqq…") != null);
}

test "loclist: lexpr fills the active editor's list; lnext/lprev/lfirst/llast walk it and E553 at both ends" {
    var f = try Fixture.init("one\ntwo\nthree\nfour\n");
    defer f.deinit();
    try f.ex("lexpr doc.txt:2:1:two here\ndoc.txt:4:3:four here");
    try testing.expectEqual(@as(usize, 2), f.app.activeEditor().?.loclist.items.len);
    try testing.expect(f.app.activeEditor().?.loc_idx == null);
    // No current entry yet: back is off the front, forward is entry 1.
    try testing.expectError(error.Failed, f.ex("lprev"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E553") != null);
    try f.ex("lnext");
    try testing.expectEqual(@as(usize, 1), f.row());
    try testing.expectEqualStrings("(1 of 2) two here", f.app.lastToast().?);
    try f.ex("lne");
    try testing.expectEqual(@as(usize, 3), f.row());
    try testing.expectEqual(@as(usize, 2), f.app.activeEditor().?.buf.editor.rowCol().col);
    try testing.expectEqualStrings("(2 of 2) four here", f.app.lastToast().?);
    try testing.expectError(error.Failed, f.ex("lnext"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E553") != null);
    try testing.expectEqual(@as(usize, 3), f.row()); // the cursor did not move
    try f.ex("lprevious");
    try testing.expectEqual(@as(usize, 1), f.row());
    try f.ex("llast");
    try testing.expectEqual(@as(usize, 3), f.row());
    try f.ex("lfirst");
    try testing.expectEqual(@as(usize, 1), f.row());
    // The jump stays in the one pane: the file was already open.
    try testing.expectEqual(@as(usize, 1), f.app.panes.count());
}

test "loclist: each editor pane has its own list; lopen shows the active one, lclose drops the pane" {
    var f = try Fixture.init("alpha\nbeta\n");
    defer f.deinit();
    const a = f.app.active.?;
    try f.ex("lexpr doc.txt:2:1:beta");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "other.txt", .data = "x\ny\nz\n" });
    const b = try f.app.openPath(try Fixture.pathOf(&f.app, f.root, "other.txt"));
    try testing.expect(a != b);
    try testing.expectEqual(@as(usize, 0), f.app.panes.editor(b).?.loclist.items.len);
    try f.ex("lexpr other.txt:3:1:z\nother.txt:1:1:x");
    try testing.expectEqual(@as(usize, 2), f.app.panes.editor(b).?.loclist.items.len);
    try testing.expectEqual(@as(usize, 1), f.app.panes.editor(a).?.loclist.items.len);
    // Walking b's list never touches a's.
    try f.ex("lnext");
    try testing.expectEqual(b, f.app.active.?);
    try testing.expectEqual(@as(usize, 2), f.row());
    try testing.expect(f.app.panes.editor(a).?.loc_idx == null);
    // :lopen shows b's two entries under the Location title, cursor on the current one.
    try f.ex("lopen");
    const lp = f.app.panes.get(f.app.active.?).?;
    try testing.expect(lp.* == .list);
    try testing.expectEqualStrings("Location", lp.title());
    try testing.expectEqual(@as(usize, 2), lp.list.entries.items.len);
    try testing.expectEqual(@as(usize, 0), lp.list.cursor);
    try testing.expectEqualStrings("z", lp.list.entries.items[0].text);
    // With the list pane focused, the verbs still act on b's list.
    try f.ex("lnext");
    try testing.expectEqual(b, f.app.active.?);
    try testing.expectEqual(@as(usize, 0), f.row());
    try testing.expectEqual(@as(usize, 1), listPane(&f.app).?.list.cursor);
    try f.ex("lclose");
    try testing.expect(listPane(&f.app) == null);
    try testing.expectEqual(b, f.app.active.?);
    try f.ex("lclose"); // nothing open: silent
    // Back on a: its own single entry, untouched.
    f.app.setActive(a);
    try f.ex("lnext");
    try testing.expectEqualStrings("(1 of 1) beta", f.app.lastToast().?);
}

test "loclist: lopen with nothing is E776; an empty list seeds from the file's LSP diagnostics" {
    var f = try Fixture.init("let a = 1;\nlet b = 2;\nlet c = 3;\n");
    defer f.deinit();
    try testing.expectError(error.Failed, f.ex("lopen"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E776") != null);
    try testing.expectError(error.Failed, f.ex("lnext"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E776") != null);
    try testing.expectEqual(@as(usize, 1), f.app.panes.count());
    // Diagnostics land for the file; :lopen seeds the list from them.
    const path = f.app.activeEditor().?.buf.doc.path.?;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[{\"range\":{\"start\":{\"line\":2,\"character\":4},\"end\":{\"line\":2,\"character\":5}},\"severity\":2,\"message\":\"c unused\"},{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":5}},\"severity\":1,\"message\":\"a unused\"}]", .{});
    defer parsed.deinit();
    try lsp.applyDiagnostics(&f.app, path, parsed.value.array.items);
    try f.ex("lopen");
    const lp = listPane(&f.app).?;
    try testing.expectEqual(@as(usize, 2), lp.list.entries.items.len);
    try testing.expectEqualStrings("a unused", lp.list.entries.items[0].text); // sorted by line
    try testing.expectEqual(@as(u32, 1), lp.list.entries.items[0].line);
    try testing.expectEqual(@as(u32, 5), lp.list.entries.items[0].col);
    try testing.expectEqualStrings("doc.txt", lp.list.entries.items[0].path.?);
    try f.ex("llast");
    try testing.expectEqual(@as(usize, 2), f.row());
    try testing.expectEqual(@as(usize, 4), f.app.activeEditor().?.buf.editor.rowCol().col);
    try testing.expectEqualStrings("(2 of 2) c unused", f.app.lastToast().?);
}
