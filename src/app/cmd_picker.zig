//! `picker.*` runners: the buffer switcher and the workspace file picker.
//! Both fill the one picker overlay; `dispatch.refilterPicker` scores
//! the labels against the query and `accept` opens the pick.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Picker = app_mod.Picker;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const dispatch = @import("dispatch.zig");

pub const table = .{
    .@"picker.buffers" = &buffers,
    .@"picker.files" = &files,
};

/// Directories a workspace walk never enters.
const skip_dirs = [_][]const u8{ ".git", "node_modules", "target", "zig-out", ".zig-cache", "zig-cache", ".mnml", "vendor", "dist", "build" };
/// Cap so a huge tree does not stall the UI thread; the picker says so.
pub const max_files = 5000;

fn buffers(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var panes: std.ArrayListUnmanaged(PaneId) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        panes.deinit(gpa);
    }
    // Tab order first (every leaf of the current layout), then anything
    // open in the background.
    const layout = app.layouts.current();
    const ordered = try layout.allPanes(app.frame.allocator());
    for (ordered) |id| try pushBuffer(app, &labels, &panes, id);
    for (app.panes.slots.items, 0..) |*slot, i| {
        if (slot.* == null) continue;
        const id: PaneId = @intCast(i);
        if (std.mem.indexOfScalar(PaneId, panes.items, id) != null) continue;
        try pushBuffer(app, &labels, &panes, id);
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no open buffers", .{});
    try openPicker(app, "Buffers", .buffers, try labels.toOwnedSlice(gpa), try panes.toOwnedSlice(gpa));
}

fn pushBuffer(app: *App, labels: *std.ArrayListUnmanaged([]u8), panes: *std.ArrayListUnmanaged(PaneId), id: PaneId) CommandError!void {
    const gpa = app.gpa;
    const p = app.panes.get(id) orelse return;
    const label = switch (p.*) {
        .editor => |*e| try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (e.buf.path) |path| app.relPath(path) else "[scratch]", if (e.buf.dirty) " ●" else "" }),
        .pty => |*term| try std.fmt.allocPrint(gpa, "{s} [term]", .{term.label}),
    };
    errdefer gpa.free(label);
    try labels.append(gpa, label);
    try panes.append(gpa, id);
}

fn files(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    const truncated = try walk(app, &labels);
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no files under {s}", .{app.workspace});
    std.mem.sort([]u8, labels.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try openPicker(app, if (truncated) "Files (first 5000)" else "Files", .files, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// Every regular file under the workspace, workspace-relative, hidden
/// entries and the usual build dirs skipped. Returns whether the cap hit.
fn walk(app: *App, out: *std.ArrayListUnmanaged([]u8)) CommandError!bool {
    const gpa = app.gpa;
    var dir = std.Io.Dir.cwd().openDir(app.io, app.workspace, .{ .iterate = true }) catch |err| return app.diag.fail(app.frame.allocator(), "cannot open {s}: {s}", .{ app.workspace, @errorName(err) });
    defer dir.close(app.io);
    var walker = dir.walk(gpa) catch return error.OutOfMemory;
    defer walker.deinit();
    while (walker.next(app.io) catch null) |entry| {
        if (entry.basename.len > 0 and entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(app.io);
            continue;
        }
        if (entry.kind == .directory) {
            for (skip_dirs) |s| if (std.mem.eql(u8, entry.basename, s)) {
                walker.leave(app.io);
                break;
            };
            continue;
        }
        if (entry.kind != .file) continue;
        if (out.items.len >= max_files) return true;
        const rel = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(rel);
        try out.append(gpa, rel);
    }
    return false;
}

fn openPicker(app: *App, title: []const u8, kind: app_mod.PickerKind, labels: [][]u8, panes: []PaneId) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .picker = .{ .state = .{ .title = title }, .kind = kind, .labels = labels, .panes = panes, .filtered = .empty } };
    try dispatch.refilterPicker(app);
    app.focus = .overlay;
    app.needs_render = true;
}

/// The pick at `idx` (an index into the filtered order) is chosen.
pub fn accept(app: *App, idx: usize) !void {
    const p = &app.overlay.picker;
    if (idx >= p.filtered.items.len) return;
    const i = p.filtered.items[idx];
    switch (p.kind) {
        .buffers => {
            const pane = p.panes[i];
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            if (app.panes.get(pane) != null) app.showPane(pane);
        },
        .files => {
            const rel = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            const abs = try app.absPath(rel);
            _ = app.openPath(abs) catch |err| {
                app.toast("open {s}: {s}", .{ rel, @errorName(err) });
                return;
            };
        },
    }
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

test "picker.buffers lists every open buffer, filters, and Enter switches; picker.files walks the workspace" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src/.hidden");
    try tmp.dir.createDirPath(t.io, "node_modules/x");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.zig", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/.hidden/no.zig", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "node_modules/x/no.js", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "x" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        _ = try app.openPath(path);
    }
    try command.run(&app, .{ .static = .@"picker.buffers" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(@as(usize, 3), app.overlay.picker.labels.len);
    try t.expectEqualStrings("a.txt", app.overlay.picker.labels[0]);
    // Type "a" — a.txt scores highest and sorts first; Enter switches.
    try app.handle(.{ .key = Key.char('a') });
    try t.expectEqualStrings("a.txt", app.overlay.picker.labels[app.overlay.picker.filtered.items[0]]);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());

    try command.run(&app, .{ .static = .@"picker.files" });
    const labels = app.overlay.picker.labels;
    try t.expectEqual(@as(usize, 5), labels.len);
    try t.expectEqualStrings("README.md", labels[0]);
    try t.expectEqualStrings("src/main.zig", labels[4]);
    for ("main") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("main.zig", app.panes.get(app.active.?).?.title());
    try t.expectEqual(@as(usize, 4), app.panes.count());
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
