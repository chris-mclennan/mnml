//! The file clipboard: `file.cut` / `file.copy` stage a set of paths,
//! `file.paste` puts them into the directory the user means, and
//! `file.duplicate` makes a `-copy` beside each. The subject of every
//! verb is resolved here in one place — the marks of a FOCUSED Files
//! pane, else its cursor row, else the tree's cursor row — so the
//! keyboard chords, the palette and the menus cannot disagree.
//!
//! The paste never writes on this thread: the (source, destination)
//! pairs are resolved here — collision names, the same-directory rules,
//! the skips — and handed to one background transfer, so a paste of a
//! 4 GB tree behaves exactly like one of a 4 KB file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const files_pane = @import("files_pane.zig");
const transfers = @import("transfers.zig");

pub const table = .{
    .@"file.cut" = &cutCmd,
    .@"file.copy" = &copyCmd,
    .@"file.paste" = &pasteCmd,
    .@"file.duplicate" = &duplicateCmd,
};

pub const State = struct {
    /// Absolute, owned.
    paths: std.ArrayListUnmanaged([]u8) = .empty,
    /// A paste moves rather than copies.
    cut: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.clear(gpa);
        self.paths.deinit(gpa);
    }

    pub fn clear(self: *State, gpa: Allocator) void {
        for (self.paths.items) |p| gpa.free(p);
        self.paths.clearRetainingCapacity();
        self.cut = false;
    }
};

// ─── what the user means ────────────────────────────────────────────────

/// The paths a verb acts on: a focused Files pane's marks (or its cursor
/// row), else the tree's cursor row. Absolute, on `arena`. Empty when
/// nothing is selected anywhere.
pub fn targetPaths(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    if (files_pane.focused(app)) |fp| return fp.pane.actionPaths(arena);
    if (app.focus == .tree and app.tree.cursor < app.tree.rows.items.len) {
        const abs = try app.absPath(app.tree.rows.items[app.tree.cursor].rel);
        const one = try arena.alloc([]const u8, 1);
        one[0] = try arena.dupe(u8, abs);
        return one;
    }
    return &.{};
}

/// The DIRECTORY a paste lands in: the focused pane's directory (a
/// paste means "here", not "beside the selected file"), else the tree
/// row's directory.
pub fn targetDir(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (files_pane.focused(app)) |fp| return try arena.dupe(u8, fp.pane.cwd);
    if (app.focus == .tree) {
        if (app.tree.cursor >= app.tree.rows.items.len) return try arena.dupe(u8, app.workspace);
        const row = app.tree.rows.items[app.tree.cursor];
        const rel = if (row.is_dir) row.rel else (std.fs.path.dirname(row.rel) orelse "");
        return try arena.dupe(u8, try app.absPath(rel));
    }
    return null;
}

// ─── naming ─────────────────────────────────────────────────────────────

/// `name-copy.ext`, then `name-copy-2.ext`, `-copy-3`… — the first
/// that does not exist beside `path`.
pub fn copyName(app: *App, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const parent = std.fs.path.dirname(path) orelse "";
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |d| (if (d == 0) base else base[0..d]) else base;
    const ext = if (dot) |d| (if (d == 0) "" else base[d..]) else "";
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const name = if (n == 1) try std.fmt.allocPrint(arena, "{s}-copy{s}", .{ stem, ext }) else try std.fmt.allocPrint(arena, "{s}-copy-{d}{s}", .{ stem, n, ext });
        const cand = try std.fs.path.join(arena, &.{ parent, name });
        if (!exists(app, cand)) return cand;
    }
    return std.fs.path.join(arena, &.{ parent, try std.fmt.allocPrint(arena, "{s}-copy-{d}{s}", .{ stem, app.now_ms, ext }) });
}

fn exists(app: *App, path: []const u8) bool {
    Io.Dir.cwd().access(app.io, path, .{}) catch return false;
    return true;
}

// ─── staging ────────────────────────────────────────────────────────────

pub fn stage(app: *App, paths: []const []const u8, cut: bool) Allocator.Error!void {
    const st = &app.file_clipboard;
    st.clear(app.gpa);
    for (paths) |p| {
        const copy = try app.gpa.dupe(u8, p);
        errdefer app.gpa.free(copy);
        try st.paths.append(app.gpa, copy);
    }
    st.cut = cut;
    if (paths.len == 1) {
        app.toast("{s} {s}", .{ if (cut) "cut" else "copied", std.fs.path.basename(paths[0]) });
    } else {
        app.toast("{s} {d} items", .{ if (cut) "cut" else "copied", paths.len });
    }
}

fn cutCmd(app: *App) CommandError!void {
    const paths = try targetPaths(app, app.frame.allocator());
    if (paths.len == 0) return app.diag.fail(app.frame.allocator(), "nothing selected to cut", .{});
    try stage(app, paths, true);
}

fn copyCmd(app: *App) CommandError!void {
    const paths = try targetPaths(app, app.frame.allocator());
    if (paths.len == 0) return app.diag.fail(app.frame.allocator(), "nothing selected to copy", .{});
    try stage(app, paths, false);
}

/// Paste the clipboard into the target directory. A copy into its own
/// directory takes a `-copy` name; a cut into its own directory is a
/// no-op that KEEPS the clipboard; an existing destination is skipped.
fn pasteCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const st = &app.file_clipboard;
    if (st.paths.items.len == 0) return app.diag.fail(arena, "file clipboard is empty", .{});
    const dir = (try targetDir(app, arena)) orelse return app.diag.fail(arena, "no folder to paste into — focus the tree or a Files pane", .{});
    if (Io.Dir.cwd().statFile(app.io, dir, .{})) |s| {
        if (s.kind != .directory) return app.diag.fail(arena, "not a folder: {s}", .{app.relPath(dir)});
    } else |_| return app.diag.fail(arena, "not a folder: {s}", .{app.relPath(dir)});
    var items: std.ArrayListUnmanaged(transfers.Item) = .empty;
    for (st.paths.items) |owned| {
        // The clipboard may be cleared before the transfer starts; the
        // items keep their own copies.
        const src = try arena.dupe(u8, owned);
        const name = std.fs.path.basename(src);
        if (name.len == 0) continue;
        var dest: []const u8 = try std.fs.path.join(arena, &.{ dir, name });
        if (std.mem.eql(u8, dest, src)) {
            if (st.cut) continue;
            dest = try copyName(app, arena, src);
        } else if (exists(app, dest)) {
            app.toast("already exists: {s}", .{app.relPath(dest)});
            continue;
        }
        // A folder into itself is a loop.
        if (std.mem.startsWith(u8, dest, src) and dest.len > src.len and std.fs.path.isSep(dest[src.len])) {
            app.toast("cannot paste {s} into itself", .{name});
            continue;
        }
        try items.append(arena, .{ .src = src, .dst = dest });
    }
    if (items.items.len == 0) return app.diag.fail(arena, "nothing to paste here", .{});
    if (transfers.clash(app, items.items)) |busy| return app.diag.fail(arena, "already writing {s} — wait for it to finish", .{app.relPath(busy)});
    const kind: transfers.Kind = if (st.cut) .move else .copy;
    if (st.cut) st.clear(app.gpa);
    _ = try transfers.start(app, kind, items.items);
    app.toast("{s} {d} item{s} into {s}", .{ if (kind == .move) "moving" else "copying", items.items.len, if (items.items.len == 1) "" else "s", app.relPath(dir) });
}

/// `name-copy.ext` beside every target, on the transfer worker.
fn duplicateCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const paths = try targetPaths(app, arena);
    if (paths.len == 0) return app.diag.fail(arena, "nothing selected to duplicate", .{});
    var items: std.ArrayListUnmanaged(transfers.Item) = .empty;
    for (paths) |p| try items.append(arena, .{ .src = p, .dst = try copyName(app, arena, p) });
    if (transfers.clash(app, items.items)) |busy| return app.diag.fail(arena, "already writing {s} — wait for it to finish", .{app.relPath(busy)});
    _ = try transfers.start(app, .copy, items.items);
    if (items.items.len == 1) {
        app.toast("duplicating {s} → {s}", .{ app.relPath(items.items[0].src), std.fs.path.basename(items.items[0].dst) });
    } else app.toast("duplicating {d} items", .{items.items.len});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

fn realRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

/// Pump the app until no transfer runs (bounded).
fn settle(app: *App) !void {
    var i: usize = 0;
    while (transfers.running(app) > 0 and i < 4000) : (i += 1) {
        try app.tick(app.now_ms + 5);
        std.Io.sleep(app.io, .fromMilliseconds(2), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 0), transfers.running(app));
}

test "copyName: -copy, then -copy-2, keeping the extension; a dotfile keeps its name whole" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a-copy.txt", .data = "a" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".env", .data = "x" });
    const arena = app.frame.allocator();
    const a = try std.fs.path.join(arena, &.{ root, "a.txt" });
    try t.expectEqualStrings("a-copy-2.txt", std.fs.path.basename(try copyName(&app, arena, a)));
    const env = try std.fs.path.join(arena, &.{ root, ".env" });
    try t.expectEqualStrings(".env-copy", std.fs.path.basename(try copyName(&app, arena, env)));
    const dir = try std.fs.path.join(arena, &.{ root, "lib" });
    try t.expectEqualStrings("lib-copy", std.fs.path.basename(try copyName(&app, arena, dir)));
}

test "the tree: copy then paste into a folder copies; cut then paste moves and clears; a cut pasted home keeps the clipboard" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "aa" });
    try tmp.dir.createDirPath(t.io, "lib");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    app.tree.cursor = app.tree.rowOf("a.txt").?;
    try command.run(&app, .{ .static = .@"file.copy" });
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
    try t.expect(!app.file_clipboard.cut);
    app.tree.cursor = app.tree.rowOf("lib").?;
    try command.run(&app, .{ .static = .@"file.paste" });
    try settle(&app);
    const copied = try tmp.dir.readFileAlloc(t.io, "lib/a.txt", t.allocator, .limited(8));
    defer t.allocator.free(copied);
    try t.expectEqualStrings("aa", copied);
    // The clipboard survives a copy-paste; pasting beside the source bumps the name.
    app.tree.cursor = app.tree.rowOf("a.txt").?;
    try command.run(&app, .{ .static = .@"file.paste" });
    try settle(&app);
    try t.expect(app.tree.rowOf("a-copy.txt") != null);
    // Cut a.txt (the new a-copy.txt sorts before it, so re-point the
    // cursor), paste into its own directory: nothing happens, the
    // clipboard stays.
    app.tree.cursor = app.tree.rowOf("a.txt").?;
    try command.run(&app, .{ .static = .@"file.cut" });
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"file.paste" }));
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
    // Paste into lib: refused, lib/a.txt exists; the row is skipped and nothing pastes.
    app.tree.cursor = app.tree.rowOf("lib").?;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"file.paste" }));
    // Delete lib/a.txt, then the move goes through and the clipboard empties.
    try tmp.dir.deleteFile(t.io, "lib/a.txt");
    try command.run(&app, .{ .static = .@"file.paste" });
    try settle(&app);
    try t.expectEqual(@as(usize, 0), app.file_clipboard.paths.items.len);
    try t.expect(app.tree.rowOf("a.txt") == null);
    try app.tree.setExpanded("lib", true);
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf("lib/a.txt") != null);
    // Duplicate makes `-copy` beside the row.
    app.tree.cursor = app.tree.rowOf("lib/a.txt").?;
    try command.run(&app, .{ .static = .@"file.duplicate" });
    try settle(&app);
    try t.expect(app.tree.rowOf("lib/a-copy.txt") != null);
}

test "a Files pane's marks are the subject; the standard chords stage and paste; vim's yy / dd / P do the same" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b" });
    try tmp.dir.createDirPath(t.io, "out");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"files.open" });
    const id = app.active.?;
    const f = &app.panes.get(id).?.files;
    // Rows: out/, a.txt, b.txt. Mark both files, ctrl+c.
    try app.handle(.{ .key = Key.char('G') });
    try app.handle(.{ .key = Key.char(' ') });
    try app.handle(.{ .key = Key.char('k') });
    try app.handle(.{ .key = Key.char(' ') });
    try t.expectEqual(@as(usize, 2), f.marks.count());
    try app.handle(.{ .key = Key.ctrl('c') });
    try t.expectEqual(@as(usize, 2), app.file_clipboard.paths.items.len);
    // Into out/ and paste.
    try app.handle(.{ .key = Key.char('g') });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("out", f.title());
    try app.handle(.{ .key = Key.ctrl('v') });
    try settle(&app);
    try t.expectEqual(@as(usize, 2), f.count());
    // vim: dd cuts the cursor row, P pastes it — into a second folder,
    // since out/ already holds a copy.
    f.clearMarks();
    try tmp.dir.createDirPath(t.io, "out2");
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try app.handle(.{ .key = Key.char('h') });
    try app.handle(.{ .key = Key.char('G') }); // b.txt
    try app.handle(.{ .key = Key.char('d') });
    try t.expectEqual(@as(u8, 'd'), f.pending.?);
    try app.handle(.{ .key = Key.char('d') });
    try t.expect(app.file_clipboard.cut);
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
    try app.handle(.{ .key = Key.char('g') });
    try app.handle(.{ .key = Key.char('j') }); // out2/
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("out2", f.title());
    try app.handle(.{ .key = Key.char('P') });
    try settle(&app);
    try t.expectEqual(@as(usize, 0), app.file_clipboard.paths.items.len);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expectEqualStrings("b.txt", f.selected().?.name);
    // A stray key between the two d's cancels the pending verb.
    try app.handle(.{ .key = Key.char('d') });
    try app.handle(.{ .key = Key.char('j') });
    try t.expect(f.pending == null);
    try app.handle(.{ .key = Key.char('y') });
    try app.handle(.{ .key = Key.char('y') });
    try t.expect(!app.file_clipboard.cut);
}

test "the tree: Ctrl+X/C/V fire in both profiles; vim's yy / P are two-key (a stray key cancels), x cuts as nvim-tree's does" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.createDirPath(t.io, "lib");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    // vim profile: ctrl+c still copies from the tree (no editor wants it here).
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    app.tree.cursor = app.tree.rowOf("a.txt").?;
    try app.handle(.{ .key = Key.ctrl('c') });
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
    try t.expect(!app.file_clipboard.cut);
    // yy copies; a stray key between the two y's cancels.
    try app.handle(.{ .key = Key.char('y') });
    try t.expectEqual(@as(u8, 'y'), app.tree.pending.?);
    try app.handle(.{ .key = Key.char('j') });
    try t.expect(app.tree.pending == null);
    // `x` cuts (nvim-tree's key; `d` is its delete).
    app.tree.cursor = app.tree.rowOf("a.txt").?;
    try app.handle(.{ .key = Key.char('x') });
    try t.expect(app.file_clipboard.cut);
    // P pastes into lib.
    app.tree.cursor = app.tree.rowOf("lib").?;
    try app.handle(.{ .key = Key.char('P') });
    try settle(&app);
    try app.tree.setExpanded("lib", true);
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf("lib/a.txt") != null);
    try t.expect(app.tree.rowOf("a.txt") == null);
    // Standard profile: a bare y / d / P is not a verb (falls through).
    try command.run(&app, .{ .static = .@"editor.use_standard" });
    app.tree.cursor = app.tree.rowOf("lib/a.txt").?;
    try t.expect(!try app.tree.handleKey(&app, Key.char('y')));
    try t.expect(!try app.tree.handleKey(&app, Key.char('P')));
    try app.handle(.{ .key = Key.ctrl('x') });
    try t.expect(app.file_clipboard.cut);
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
}
