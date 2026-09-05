//! Harpoon — nine pinned files. `harpoon.add` pins the active file into
//! the lowest free slot, `harpoon.goto_N` jumps to slot N, `harpoon.menu`
//! is a picker over the occupied slots. Paths are absolute and
//! gpa-owned; the set rides along in `session.zon`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");

pub const slots: usize = 9;

pub const State = struct {
    paths: [slots]?[]u8 = @splat(null),

    pub fn deinit(self: *State, gpa: Allocator) void {
        for (&self.paths) |*p| if (p.*) |s| {
            gpa.free(s);
            p.* = null;
        };
    }

    pub fn clear(self: *State, gpa: Allocator) void {
        self.deinit(gpa);
    }

    pub fn indexOf(self: *const State, path: []const u8) ?usize {
        for (self.paths, 0..) |p, i| if (p != null and std.mem.eql(u8, p.?, path)) return i;
        return null;
    }

    pub fn count(self: *const State) usize {
        var n: usize = 0;
        for (self.paths) |p| n += @intFromBool(p != null);
        return n;
    }

    /// Pin `path` (absolute) into `slot`, replacing what was there.
    pub fn set(self: *State, gpa: Allocator, slot: usize, path: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, path);
        if (self.paths[slot]) |old| gpa.free(old);
        self.paths[slot] = copy;
    }
};

/// The active editor's file, or the reason there is none.
fn activePath(app: *App) CommandError![]const u8 {
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "harpoon: no file", .{});
    return e.buf.doc.path orelse app.diag.fail(app.frame.allocator(), "harpoon: the buffer has no file", .{});
}

pub fn add(app: *App) CommandError!void {
    const path = try activePath(app);
    const st = &app.harpoon;
    if (st.indexOf(path)) |i| {
        app.toast("harpoon: already pinned (slot {d} = {s})", .{ i + 1, app.relPath(path) });
        return;
    }
    for (st.paths, 0..) |p, i| if (p == null) {
        try st.set(app.gpa, i, path);
        app.toast("harpoon: slot {d} = {s}", .{ i + 1, app.relPath(path) });
        return;
    };
    return app.diag.fail(app.frame.allocator(), "harpoon: all 9 slots full (harpoon.menu frees one)", .{});
}

/// `harpoon.goto_N` (1-based).
pub fn goto(app: *App, slot1: usize) CommandError!void {
    if (slot1 == 0 or slot1 > slots) return error.Failed;
    const path = app.harpoon.paths[slot1 - 1] orelse return app.diag.fail(app.frame.allocator(), "harpoon: slot {d} is empty", .{slot1});
    // The path is the store's; opening may reallocate nothing here, but
    // a frame copy keeps the call independent of the slot's lifetime.
    const copy = try app.frame.allocator().dupe(u8, path);
    _ = app.openPath(copy) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "harpoon: slot {d} → {s}: {s}", .{ slot1, app.relPath(copy), @errorName(err) }),
    };
}

/// `harpoon.menu`: the occupied slots, `N  <path>`; Enter jumps.
pub fn menu(app: *App) CommandError!void {
    const gpa = app.gpa;
    const st = &app.harpoon;
    if (st.count() == 0) return app.diag.fail(app.frame.allocator(), "harpoon: nothing pinned (harpoon.add pins the active file)", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (st.paths, 0..) |p, i| {
        const path = p orelse continue;
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{d}  {s}", .{ i + 1, app.relPath(path) }));
        const exists = if (std.Io.Dir.cwd().access(app.io, path, .{})) true else |_| false;
        try details.append(gpa, try gpa.dupe(u8, if (exists) "" else "missing"));
    }
    try cmd_picker.openPickerWith(app, "Harpoon", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &accept;
}

fn accept(app: *App, idx: usize, label: []const u8) Allocator.Error!void {
    _ = idx;
    const slot1 = std.fmt.parseInt(usize, label[0..1], 10) catch return;
    goto(app, slot1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
}

pub fn clearCmd(app: *App) CommandError!void {
    app.harpoon.clear(app.gpa);
    app.toast("harpoon: cleared", .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "harpoon: add pins into the lowest free slot, goto opens it, the menu lists the rest" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"harpoon.add" }));
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    _ = try app.openPath(a);
    try command.run(&app, .{ .static = .@"harpoon.add" });
    try t.expectEqualStrings("harpoon: slot 1 = a.txt", app.lastToast().?);
    try command.run(&app, .{ .static = .@"harpoon.add" });
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "harpoon: already pinned"));
    _ = try app.openPath(b);
    try command.run(&app, .{ .static = .@"harpoon.add" });
    try t.expectEqual(@as(usize, 2), app.harpoon.count());
    try command.run(&app, .{ .static = .@"harpoon.goto_1" });
    try t.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"harpoon.goto_3" }));
    try command.run(&app, .{ .static = .@"harpoon.menu" });
    try t.expect(app.overlay == .picker);
    try t.expectEqualStrings("2  b.txt", app.overlay.picker.labels[1]);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expectEqualStrings("b.txt", app.panes.get(app.active.?).?.title());
    try command.run(&app, .{ .static = .@"harpoon.clear" });
    try t.expectEqual(@as(usize, 0), app.harpoon.count());
}
