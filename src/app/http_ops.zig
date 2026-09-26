//! The COLLECTIONS verbs (item 8) — rename / duplicate / delete / move
//! a request file, or one `###` block of a multi-block file, from the
//! panel's row menu or the palette — and the request picker (item 9):
//! `http.find_request`, one row per block of every listed file,
//! `METHOD · name · file` with the tags dimmed, Enter opening that
//! block in a request pane.
//!
//! A verb's target is the panel's selected row when the HTTP panel has
//! the keys, else the active request pane's source (its block when the
//! file has several). Rename edits the `###` line (the file name for a
//! single-request file); duplicate clones the block as `### name-copy`
//! (the file as `stem-copy.ext`); delete confirms, then removes the
//! block with the others intact (the file when it was the last one);
//! move offers the collection folders and appends the block to the
//! file of the same name there (moves the file whole). Open panes on
//! the source follow a rename or a move; the tree refreshes after each.

const std = @import("std");
const app_mod = @import("../app.zig");
const command = @import("../core/command.zig");
const parse = @import("../http/parse.zig");
const history = @import("../http/history.zig");
const http = @import("http.zig");
const http_panel = @import("http_panel.zig");
const cmd_picker = @import("cmd_picker.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const CommandError = command.CommandError;
const Prompt = app_mod.Prompt;

pub const table = .{
    .@"http.rename_request" = &renameCmd,
    .@"http.duplicate_request" = &duplicateCmd,
    .@"http.delete_request" = &deleteCmd,
    .@"http.move_request" = &moveCmd,
    .@"http.find_request" = &findCmd,
};

/// What a verb acts on: a file, or block `block` of it (its index in
/// `parse.blocks` of the file's text).
pub const Target = struct {
    /// Absolute, owned.
    path: []u8,
    block: ?u32,

    pub fn deinit(t: Target, gpa: Allocator) void {
        gpa.free(t.path);
    }

    pub fn clone(t: Target, gpa: Allocator) Allocator.Error!Target {
        return .{ .path = try gpa.dupe(u8, t.path), .block = t.block };
    }
};

/// The panel's selected COLLECTIONS row when the panel has the keys,
/// else the active request pane's source. Owned by the caller.
pub fn resolveTarget(app: *App) CommandError!Target {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const on_panel = switch (app.focus) {
        .panel => |p| p == .http,
        else => false,
    };
    if (on_panel) if (app.http_panel.selected()) |row| if (row.section == .collections) switch (row.kind) {
        .item => return .{ .path = try std.fs.path.join(gpa, &.{ app.workspace, app.http_panel.files[row.idx] }), .block = null },
        .block => {
            const b = app.http_panel.blocks[row.idx];
            return .{ .path = try std.fs.path.join(gpa, &.{ app.workspace, app.http_panel.files[b.file] }), .block = b.idx };
        },
        else => {},
    };
    if (http.activeRequest(app)) |rp| if (rp.source_path) |p| {
        const text = Io.Dir.cwd().readFileAlloc(app.io, p, arena, .limited(16 << 20)) catch return app.diag.fail(arena, "http: cannot read {s}", .{app.relPath(p)});
        const list = try parse.blocks(arena, text);
        if (list.len >= 2) {
            const idx = parse.resolveBlock(list, rp.block_index, rp.block_name) orelse return app.diag.fail(arena, "http: the pane's block is not in {s} any more", .{app.relPath(p)});
            return .{ .path = try gpa.dupe(u8, p), .block = @intCast(idx) };
        }
        return .{ .path = try gpa.dupe(u8, p), .block = null };
    };
    return app.diag.fail(arena, "http: select a request in COLLECTIONS or open one from a file", .{});
}

/// `block two of r.http` / `users.http`, for titles and toasts.
fn describe(app: *App, arena: Allocator, t: Target) Allocator.Error![]const u8 {
    if (t.block) |idx| {
        const name = blockName(app, arena, t.path, idx) orelse "?";
        return std.fmt.allocPrint(arena, "block `{s}` of {s}", .{ name, app.relPath(t.path) });
    }
    return app.relPath(t.path);
}

/// The block's `###` name (its label when it has none).
fn blockName(app: *App, arena: Allocator, path: []const u8, idx: u32) ?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(16 << 20)) catch return null;
    const list = parse.blocks(arena, text) catch return null;
    if (idx >= list.len) return null;
    const b = list[idx];
    if (b.name) |n| if (n.len > 0) return n;
    return b.summary orelse "(unnamed)";
}

fn readText(app: *App, arena: Allocator, path: []const u8) CommandError![]const u8 {
    return Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(16 << 20)) catch return app.diag.fail(arena, "http: cannot read {s}", .{app.relPath(path)});
}

fn writeText(app: *App, path: []const u8, data: []const u8) CommandError!void {
    if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = data }) catch |err| return app.diag.fail(app.frame.allocator(), "http: write {s}: {s}", .{ app.relPath(path), @errorName(err) });
}

fn refreshPanel(app: *App) Allocator.Error!void {
    if (app.http_panel.scanned_once) try http_panel.refresh(app);
    app.needs_render = true;
}

// ─── rename ─────────────────────────────────────────────────────────────

fn renameCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const t = try resolveTarget(app);
    errdefer t.deinit(gpa);
    const seed: []const u8 = if (t.block) |idx| (blockName(app, arena, t.path, idx) orelse "") else std.fs.path.basename(t.path);
    const title = try std.fmt.allocPrint(gpa, "Rename {s}:", .{try describe(app, arena, t)});
    errdefer gpa.free(title);
    var state = Prompt.init(gpa, title);
    errdefer Prompt.deinit(&state, gpa);
    try state.seed(gpa, seed);
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .http_rename = t }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's answer: the `###` line, or the file's name (a `/`
/// moves it; the extension is kept when none is typed).
pub fn acceptRename(app: *App, t: Target, text: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const name = std.mem.trim(u8, text, " \t");
    if (name.len == 0) return;
    if (t.block) |idx| {
        const src = readText(app, arena, t.path) catch |err| return toastFail(app, err);
        const old = blockName(app, arena, t.path, idx);
        const fresh = (try parse.renameBlock(gpa, src, idx, name)) orelse {
            app.toast("rename: no block {d} in {s}", .{ idx, app.relPath(t.path) });
            return;
        };
        defer gpa.free(fresh);
        writeText(app, t.path, fresh) catch |err| return toastFail(app, err);
        // The pane on that block follows the new name.
        const old_name: ?[]const u8 = blk: {
            const list = parse.blocks(arena, src) catch break :blk null;
            break :blk if (idx < list.len) list[idx].name else null;
        };
        if (http.findSource(app, t.path, idx, old_name)) |id| if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
            if (rp.block_name) |b| gpa.free(b);
            rp.block_name = try gpa.dupe(u8, name);
            try rp.refreshTitle();
        };
        app.toast("renamed block `{s}` → `{s}` in {s}", .{ old orelse "?", name, app.relPath(t.path) });
    } else {
        const with_ext = if (std.fs.path.extension(name).len == 0) try std.mem.concat(arena, u8, &.{ name, std.fs.path.extension(t.path) }) else name;
        const dir = std.fs.path.dirname(t.path) orelse app.workspace;
        const dest = if (std.fs.path.isAbsolute(with_ext)) with_ext else try std.fs.path.join(arena, &.{ dir, with_ext });
        if (std.fs.path.dirname(dest)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
        Io.Dir.rename(Io.Dir.cwd(), t.path, Io.Dir.cwd(), dest, app.io) catch |err| {
            app.toast("rename: {s}: {s}", .{ app.relPath(t.path), @errorName(err) });
            return;
        };
        try repointPanes(app, t.path, dest);
        app.toast("renamed {s} → {s}", .{ app.relPath(t.path), app.relPath(dest) });
    }
    try refreshPanel(app);
}

/// Every request pane on `from` now names `to`.
fn repointPanes(app: *App, from: []const u8, to: []const u8) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .request => |*rp| if (rp.source_path) |sp| if (std.mem.eql(u8, sp, from)) {
            app.gpa.free(sp);
            rp.source_path = try app.gpa.dupe(u8, to);
            try rp.refreshTitle();
        },
        else => {},
    };
}

fn toastFail(app: *App, err: CommandError) void {
    if (err == error.OutOfMemory) return;
    if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("http: {s}", .{@errorName(err)});
    app.diag.clear();
}

// ─── duplicate ──────────────────────────────────────────────────────────

fn duplicateCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const t = try resolveTarget(app);
    defer t.deinit(gpa);
    if (t.block) |idx| {
        const src = try readText(app, arena, t.path);
        const fresh = (try parse.duplicateBlock(gpa, src, idx)) orelse return app.diag.fail(arena, "duplicate: no block {d} in {s}", .{ idx, app.relPath(t.path) });
        defer gpa.free(fresh);
        try writeText(app, t.path, fresh);
        app.toast("duplicated {s}", .{try describe(app, arena, t)});
    } else {
        const dest = try copyPath(app, arena, t.path);
        const src = try readText(app, arena, t.path);
        try writeText(app, dest, src);
        app.toast("duplicated {s} → {s}", .{ app.relPath(t.path), app.relPath(dest) });
    }
    try refreshPanel(app);
}

/// `stem-copy.ext`, `stem-copy-2.ext`, … the first that is not there.
fn copyPath(app: *App, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const dir = std.fs.path.dirname(path) orelse app.workspace;
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const cand = if (n == 0) try std.fmt.allocPrint(arena, "{s}/{s}-copy{s}", .{ dir, stem, ext }) else try std.fmt.allocPrint(arena, "{s}/{s}-copy-{d}{s}", .{ dir, stem, n + 1, ext });
        Io.Dir.cwd().access(app.io, cand, .{}) catch return cand;
    }
    return try std.fmt.allocPrint(arena, "{s}/{s}-copy{s}", .{ dir, stem, ext });
}

// ─── delete ─────────────────────────────────────────────────────────────

pub const delete_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'c', .label = "Cancel" } };

fn deleteCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const t = try resolveTarget(app);
    errdefer t.deinit(gpa);
    const msg = try std.fmt.allocPrint(gpa, "Delete {s}?{s}", .{ try describe(app, arena, t), if (t.block != null) " The file's other blocks stay." else "" });
    errdefer gpa.free(msg);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Delete request", .message = msg, .choices = &delete_choices },
        .purpose = .{ .http_delete_request = t },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Confirmed: the block goes (the file when it was the last one), or
/// the file.
pub fn acceptDelete(app: *App, t: Target) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const what = try describe(app, arena, t);
    if (t.block) |idx| {
        const src = readText(app, arena, t.path) catch |err| return toastFail(app, err);
        const fresh = (try parse.deleteBlock(gpa, src, idx)) orelse {
            app.toast("delete: no block {d} in {s}", .{ idx, app.relPath(t.path) });
            return;
        };
        defer gpa.free(fresh);
        if (std.mem.trim(u8, fresh, " \t\r\n").len == 0) {
            Io.Dir.cwd().deleteFile(app.io, t.path) catch {};
        } else writeText(app, t.path, fresh) catch |err| return toastFail(app, err);
    } else {
        Io.Dir.cwd().deleteFile(app.io, t.path) catch |err| {
            app.toast("delete: {s}: {s}", .{ app.relPath(t.path), @errorName(err) });
            return;
        };
    }
    app.toast("deleted {s}", .{what});
    try refreshPanel(app);
}

// ─── move ───────────────────────────────────────────────────────────────

fn moveCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    const t = try resolveTarget(app);
    errdefer t.deinit(gpa);
    const st = &app.http_panel;
    if (!st.scanned_once) try http_panel.refresh(app);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (st.folders) |f| {
        try labels.append(gpa, try gpa.dupe(u8, f.rel));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{d} request file{s}{s}", .{ f.members.len, if (f.members.len == 1) "" else "s", if (f.hidden) " · hidden collection" else "" }));
    }
    try labels.append(gpa, try gpa.dupe(u8, "(workspace root)"));
    try details.append(gpa, try gpa.dupe(u8, ""));
    if (app.http.move_target) |old| old.deinit(gpa);
    app.http.move_target = t;
    try cmd_picker.openPickerWith(app, "Move to collection", .http_move_target, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

/// The picker's pick: the folder (`(workspace root)` for none).
pub fn acceptMove(app: *App, label: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const t = app.http.move_target orelse return;
    defer {
        t.deinit(gpa);
        app.http.move_target = null;
    }
    const folder: []const u8 = if (std.mem.eql(u8, label, "(workspace root)")) "" else label;
    const base = std.fs.path.basename(t.path);
    const dest = if (folder.len == 0) try std.fs.path.join(arena, &.{ app.workspace, base }) else try std.fs.path.join(arena, &.{ app.workspace, folder, base });
    if (t.block) |idx| {
        if (std.mem.eql(u8, dest, t.path)) {
            app.toast("move: {s} is already there", .{app.relPath(t.path)});
            return;
        }
        const src = readText(app, arena, t.path) catch |err| return toastFail(app, err);
        const piece = (try parse.extractBlock(gpa, src, idx)) orelse {
            app.toast("move: no block {d} in {s}", .{ idx, app.relPath(t.path) });
            return;
        };
        defer gpa.free(piece);
        const rest = (try parse.deleteBlock(gpa, src, idx)) orelse return;
        defer gpa.free(rest);
        const existing = Io.Dir.cwd().readFileAlloc(app.io, dest, arena, .limited(16 << 20)) catch "";
        const glue: []const u8 = if (existing.len == 0) "" else if (std.mem.endsWith(u8, existing, "\n\n")) "" else if (std.mem.endsWith(u8, existing, "\n")) "\n" else "\n\n";
        const joined = try std.mem.concat(arena, u8, &.{ existing, glue, piece });
        writeText(app, dest, joined) catch |err| return toastFail(app, err);
        if (std.mem.trim(u8, rest, " \t\r\n").len == 0) {
            Io.Dir.cwd().deleteFile(app.io, t.path) catch {};
        } else writeText(app, t.path, rest) catch |err| return toastFail(app, err);
        app.toast("moved block → {s}", .{app.relPath(dest)});
    } else {
        if (std.mem.eql(u8, dest, t.path)) {
            app.toast("move: {s} is already there", .{app.relPath(t.path)});
            return;
        }
        if (std.fs.path.dirname(dest)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
        Io.Dir.rename(Io.Dir.cwd(), t.path, Io.Dir.cwd(), dest, app.io) catch |err| {
            app.toast("move: {s}: {s}", .{ app.relPath(t.path), @errorName(err) });
            return;
        };
        try repointPanes(app, t.path, dest);
        app.toast("moved {s} → {s}", .{ app.relPath(t.path), app.relPath(dest) });
    }
    try refreshPanel(app);
}

// ─── the request picker (item 9) ────────────────────────────────────────

/// A picker row's target, on `http.State.picker_arena`.
pub const FindRow = struct { path: []const u8, idx: u32 };

fn findCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    const st = &app.http_panel;
    if (!st.scanned_once) try http_panel.refresh(app);
    if (st.blocks.len == 0) return app.diag.fail(app.frame.allocator(), "http.find_request: no request files in the workspace (.http / .rest / .curl)", .{});
    _ = app.http.picker_arena.reset(.retain_capacity);
    app.http.history_rows = &.{};
    app.http.captured_curls = &.{};
    const a = app.http.picker_arena.allocator();
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    var rows: std.ArrayListUnmanaged(FindRow) = .empty;
    for (st.blocks) |b| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} \u{00b7} {s} \u{00b7} {s}", .{ b.method, b.label, st.files[b.file] }));
        try details.append(gpa, try tagsText(gpa, b.tags));
        try rows.append(a, .{ .path = try std.fs.path.join(a, &.{ app.workspace, st.files[b.file] }), .idx = b.idx });
    }
    app.http.find_rows = rows.items;
    try cmd_picker.openPickerWith(app, "Find request", .http_find_request, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

/// `#a #b`, or empty.
pub fn tagsText(alloc: Allocator, tags: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (tags, 0..) |t, i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.append(alloc, '#');
        try out.appendSlice(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

pub fn acceptFind(app: *App, i: usize) Allocator.Error!void {
    const rows = app.http.find_rows;
    if (i >= rows.len) return;
    const r = rows[i];
    _ = http.openFileBlock(app, r.path, r.idx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("open: {s}", .{@errorName(err)});
            app.diag.clear();
        },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;
const Key = @import("../core/key.zig").Key;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 100, .rows = 40 });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn read(f: *Fixture, rel: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, rel, testing.allocator, .limited(1 << 16));
    }

    /// Put the panel's cursor on the first row of `kind` labelled `label`.
    fn select(f: *Fixture, kind: http_panel.Kind, label: []const u8) !void {
        http_panel.focusPanel(&f.app);
        for (f.app.http_panel.rows.items, 0..) |r, i| if (r.kind == kind and std.mem.eql(u8, r.label, label)) {
            f.app.http_panel.list.cursor = i;
            return;
        };
        return error.TestUnexpectedResult;
    }
};

const three = "### one\nGET https://x/one\n\n### two\n# @tags smoke users\nPOST https://x/two\n\n{}\n\n### three\nGET https://x/three\n";

test "rename: a block's ### line from the panel row (the open pane follows); a single-request file's name from the pane" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("api/r.http", three);
    try f.write("api/solo.http", "GET https://x/solo\n");
    try http_panel.refresh(&f.app);
    try testing.expectEqual(@as(usize, 4), f.app.http_panel.blocks.len);
    // The pane on block `two`, then the row's verb.
    const path = try std.fs.path.join(testing.allocator, &.{ f.root, "api/r.http" });
    defer testing.allocator.free(path);
    const id = try http.openFileBlock(&f.app, path, 1);
    const rp = f.app.panes.get(id).?.asRequest().?;
    try testing.expectEqualStrings("two", rp.block_name.?);
    try f.select(.block, "two");
    try command.run(&f.app, .{ .static = .@"http.rename_request" });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqualStrings("two", f.app.overlay.prompt.state.text());
    try testing.expect(sdk_testing.pathContains(f.app.overlay.prompt.state.title, "block `two` of api/r.http"));
    try f.app.handle(.{ .key = Key.char('d') });
    try f.app.handle(.{ .key = Key.char('u') });
    try f.app.handle(.{ .key = Key.char('o') });
    try f.app.handle(.{ .key = Key.named(.enter) });
    const out = try f.read("api/r.http");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("### one\nGET https://x/one\n\n### duo\n# @tags smoke users\nPOST https://x/two\n\n{}\n\n### three\nGET https://x/three\n", out);
    try testing.expectEqualStrings("duo", rp.block_name.?);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "renamed block `two` → `duo`"));
    // The tree refreshed: the row now says duo.
    try f.select(.block, "duo");
    // A single-request file from its pane: the name, the extension kept.
    const solo = try std.fs.path.join(testing.allocator, &.{ f.root, "api/solo.http" });
    defer testing.allocator.free(solo);
    _ = try f.app.openPath(solo);
    try command.run(&f.app, .{ .static = .@"http.rename_request" });
    try testing.expectEqualStrings("solo.http", f.app.overlay.prompt.state.text());
    try f.app.overlay.prompt.state.setText(testing.allocator, "alone");
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(f.tmp.dir.access(testing.io, "api/alone.http", .{}) != error.FileNotFound);
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "api/solo.http", .{}));
    try testing.expect(std.mem.endsWith(u8, http.activeRequest(&f.app).?.source_path.?, "/api/alone.http"));
}

test "duplicate and delete: the block cloned as name-copy, the delete confirmed and the others intact, the last block takes the file with it; the file forms" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("r.http", three);
    try f.write("solo.curl", "curl https://x/solo\n");
    try http_panel.refresh(&f.app);
    try f.select(.block, "one");
    try command.run(&f.app, .{ .static = .@"http.duplicate_request" });
    const dup = try f.read("r.http");
    defer testing.allocator.free(dup);
    try testing.expect(std.mem.indexOf(u8, dup, "### one\nGET https://x/one\n\n### one-copy\nGET https://x/one\n\n### two\n") != null);
    try f.select(.block, "one-copy");
    try command.run(&f.app, .{ .static = .@"http.delete_request" });
    try testing.expect(f.app.overlay == .confirm);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.confirm.message, "Delete block `one-copy` of r.http?") != null);
    // Cancel keeps it; Delete removes it.
    try f.app.handle(.{ .key = Key.char('c') });
    const kept = try f.read("r.http");
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.indexOf(u8, kept, "### one-copy") != null);
    try f.select(.block, "one-copy");
    try command.run(&f.app, .{ .static = .@"http.delete_request" });
    try f.app.handle(.{ .key = Key.char('d') });
    const after = try f.read("r.http");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(three, after);
    // The file forms: a copy beside it, then the delete of the file.
    try f.select(.item, "solo.curl");
    try command.run(&f.app, .{ .static = .@"http.duplicate_request" });
    const copy = try f.read("solo-copy.curl");
    defer testing.allocator.free(copy);
    try testing.expectEqualStrings("curl https://x/solo\n", copy);
    try f.select(.item, "solo-copy.curl");
    try command.run(&f.app, .{ .static = .@"http.delete_request" });
    try f.app.handle(.{ .key = Key.char('d') });
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "solo-copy.curl", .{}));
    // Deleting every block of a file removes the file.
    try f.write("pair.http", "### a\nGET https://x/a\n\n### b\nGET https://x/b\n");
    try http_panel.refresh(&f.app);
    try f.select(.block, "a");
    try command.run(&f.app, .{ .static = .@"http.delete_request" });
    try f.app.handle(.{ .key = Key.char('d') });
    const one_left = try f.read("pair.http");
    defer testing.allocator.free(one_left);
    try testing.expectEqualStrings("### b\nGET https://x/b\n", one_left);
    // A single block left: the file row is the request now.
    try f.select(.item, "pair.http");
    try command.run(&f.app, .{ .static = .@"http.delete_request" });
    try f.app.handle(.{ .key = Key.char('d') });
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "pair.http", .{}));
}

test "move: a block into another collection's file of the same name, a file into a folder; the picker lists the folders and the root" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("api/r.http", three);
    try f.write("smoke/r.http", "### ping\nGET https://x/ping\n");
    try f.write("loose.http", "GET https://x/loose\n");
    try http_panel.refresh(&f.app);
    try f.select(.block, "two");
    try command.run(&f.app, .{ .static = .@"http.move_request" });
    try testing.expect(f.app.overlay == .picker);
    try testing.expectEqualStrings("Move to collection", f.app.overlay.picker.state.title);
    try testing.expectEqual(@as(usize, 3), f.app.overlay.picker.labels.len);
    try testing.expectEqualStrings("api", f.app.overlay.picker.labels[0]);
    try testing.expectEqualStrings("smoke", f.app.overlay.picker.labels[1]);
    try testing.expectEqualStrings("(workspace root)", f.app.overlay.picker.labels[2]);
    try cmd_picker.accept(&f.app, 1);
    const src = try f.read("api/r.http");
    defer testing.allocator.free(src);
    try testing.expectEqualStrings("### one\nGET https://x/one\n\n### three\nGET https://x/three\n", src);
    const dst = try f.read("smoke/r.http");
    defer testing.allocator.free(dst);
    try testing.expectEqualStrings("### ping\nGET https://x/ping\n\n### two\n# @tags smoke users\nPOST https://x/two\n\n{}\n", dst);
    try testing.expectEqualStrings("moved block → smoke/r.http", f.app.lastToast().?);
    // The file: into `api`, the open pane following.
    const loose = try std.fs.path.join(testing.allocator, &.{ f.root, "loose.http" });
    defer testing.allocator.free(loose);
    _ = try f.app.openPath(loose);
    try f.select(.item, "loose.http");
    try command.run(&f.app, .{ .static = .@"http.move_request" });
    try cmd_picker.accept(&f.app, 0);
    try testing.expect(f.tmp.dir.access(testing.io, "api/loose.http", .{}) != error.FileNotFound);
    var moved = false;
    for (f.app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .request => |*rp| if (rp.source_path) |sp| if (std.mem.endsWith(u8, sp, "/api/loose.http")) {
            moved = true;
        },
        else => {},
    };
    try testing.expect(moved);
    // Nothing selected and no pane: the verb says what to do.
    f.app.focus = .tree;
    var i: usize = 0;
    while (i < f.app.panes.slots.items.len) : (i += 1) if (f.app.panes.slots.items[i] != null) try f.app.forceClosePane(@intCast(i));
    try testing.expectError(error.Failed, command.run(&f.app, .{ .static = .@"http.duplicate_request" }));
}

test "find: one row per block of every file, `METHOD · name · file`, the tags dimmed beside; Enter opens that block" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("api/r.http", three);
    try f.write("solo.curl", "# Solo one\ncurl https://x/solo\n");
    try command.run(&f.app, .{ .static = .@"http.find_request" });
    try testing.expect(f.app.overlay == .picker);
    const p = &f.app.overlay.picker;
    try testing.expectEqual(@as(usize, 4), p.labels.len);
    try testing.expectEqualStrings("GET \u{00b7} one \u{00b7} api/r.http", p.labels[0]);
    try testing.expectEqualStrings("POST \u{00b7} two \u{00b7} api/r.http", p.labels[1]);
    try testing.expectEqualStrings("#smoke #users", p.details[1]);
    try testing.expectEqualStrings("", p.details[0]);
    try testing.expectEqualStrings("GET \u{00b7} Solo one \u{00b7} solo.curl", p.labels[3]);
    try cmd_picker.accept(&f.app, 1);
    const rp = http.activeRequest(&f.app).?;
    try testing.expectEqualStrings("https://x/two", rp.url.items);
    try testing.expectEqualStrings("two", rp.block_name.?);
    try testing.expect(std.mem.endsWith(u8, rp.source_path.?, "/api/r.http"));
    // The same block again is the same pane.
    const before = f.app.panes.count();
    try command.run(&f.app, .{ .static = .@"http.find_request" });
    try cmd_picker.accept(&f.app, 1);
    try testing.expectEqual(before, f.app.panes.count());
}
