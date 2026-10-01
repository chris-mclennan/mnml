//! Switching the workspace — `view.switch_workspace`, a section's `○`,
//! *Switch to this workspace* on its header — Rust's
//! `promote_to_primary_workspace` (`workspace_methods.rs`): an extra
//! root of the tree becomes the workspace. `app.workspace` changes, so
//! what reads it follows: the title, the statusline's folder, `Ctrl+P`,
//! the HTTP panel. The repos are discovered again with the new
//! workspace's repo active, so the statusline's branch, git mode, the
//! rail and the status pane retarget. The old workspace takes the root's
//! slot in the tree (`Tree.swapPrimary`): the sections keep their order
//! and only the `●` moves; switching back restores it.
//!
//! What stays with the LAUNCH workspace: the file-IPC channel (an
//! integration was told where it listens), the config layers (read once
//! at launch, as in Rust) and the scratch folder a test made. The trust
//! that gates exec-bearing files is the new workspace's own. The session
//! follows `app.workspace`, as Rust's did: a quit after a switch writes
//! the promoted root's `.mnml/session.zon`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const config = @import("../config/root.zig");
const git = @import("git.zig");
const git_palette = @import("git_palette.zig");
const http = @import("http.zig");
const http_panel = @import("http_panel.zig");
const tree_mod = @import("tree.zig");

/// Extra root `idx` (1-based, `Tree.roots[idx - 1]`) becomes the
/// workspace. The tree's own fold and cursor are `Tree.switchTo`'s.
pub fn promote(app: *App, idx: usize) Allocator.Error!void {
    const tree = &app.tree;
    if (idx == 0 or idx > tree.roots.items.len) return;
    const gpa = app.gpa;
    const old_ws = app.workspace;
    try app.retired_workspaces.ensureUnusedCapacity(gpa, 1);
    const leaving_launch = std.mem.eql(u8, old_ws, app.launch_workspace);
    const path = try tree.swapPrimary(idx, old_ws);
    if (leaving_launch) app.launch_trusted = app.workspace_trusted;
    // A spelling a worker may still hold is reused, so switching back
    // and forth keeps one string per root.
    var new_ws = path;
    for (app.retired_workspaces.items, 0..) |w, i| if (std.mem.eql(u8, w, path)) {
        new_ws = app.retired_workspaces.swapRemove(i);
        gpa.free(path);
        break;
    };
    app.workspace = new_ws;
    app.retired_workspaces.appendAssumeCapacity(old_ws);
    app.workspace_trusted = try trustOf(app, new_ws);
    app.probeWorkspaceToml();
    try retargetGit(app);
    // Rust: an env picked for one workspace's requests does not carry
    // into another's.
    if (app.http.env_override) |e| {
        gpa.free(e);
        app.http.env_override = null;
    }
    // The env watch takes the new workspace's files as its baseline: a
    // switch is not an env file edited, and says nothing of the kind.
    http.restampEnvWatch(app);
    if (app.http_panel.scanned_once) try http_panel.refresh(app);
    const base = std.fs.path.basename(new_ws);
    const name = tree.primary_name orelse (if (base.len > 0) base else new_ws);
    app.toastReplace("workspace-opened", "workspace opened: {s}", .{name});
    app.needs_render = true;
}

/// The repo list again, primary first; the new workspace's first repo
/// becomes the active one without the `active repo →` toast, and git
/// mode's tabs follow.
fn retargetGit(app: *App) Allocator.Error!void {
    try git.discover(app);
    var pick: ?usize = null;
    for (app.git.repos.items, 0..) |r, i| if (std.mem.eql(u8, r.path, app.workspace) or tree_mod.underRoot(app.workspace, r.path) != null) {
        pick = i;
        break;
    };
    if (pick) |i| {
        git.switchToHow(app, i, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    } else git.clearActive(app);
    git_palette.followActiveRepo(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// Whether `ws`'s exec-bearing files (its `.mnml/config.zon` claims,
/// `init.lua`, manifests) may run: the launch workspace keeps the answer
/// it launched with; another is asked the way a launch on it would ask
/// (`.ask`: nothing to distrust, or a fingerprint the store remembers).
pub fn trustOf(app: *App, ws: []const u8) Allocator.Error!bool {
    if (std.mem.eql(u8, ws, app.launch_workspace)) return app.launch_trusted orelse app.workspace_trusted;
    var opts: config.load.Options = if (app.loaded) |l| l.opts else .{
        .workspace = ws,
        .data_root = if (app.data_root.len > 0) app.data_root else null,
        .env = .{ .vars = &app.env },
    };
    if (opts.trust == .untrusted) return false;
    opts.workspace = ws;
    opts.trust = .ask;
    opts.explicit = null;
    var probe = try config.load.load(app.gpa, app.io, opts);
    defer probe.deinit();
    return probe.workspace_trusted;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const command = @import("../core/command.zig");
const mount_pane = @import("mount_pane.zig");

/// `<tmp>/<name>` folders for the roots, made, with a file each.
const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        return .{ .tmp = tmp, .root = try t.allocator.dupe(u8, buf[0..n]) };
    }

    fn deinit(f: *Fixture) void {
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn path(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ f.root, rel });
    }

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    /// A repo at `<tmp>/<rel>` on branch `branch`.
    fn repo(f: *Fixture, rel: []const u8, branch: []const u8) !void {
        const dir = try f.path(rel);
        defer t.allocator.free(dir);
        const res = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "-C", dir, "init", "-q", "-b", branch } });
        t.allocator.free(res.stdout);
        t.allocator.free(res.stderr);
        try t.expect(res.term == .exited and res.term.exited == 0);
    }
};

/// Tick until the git status the switch asked for has landed.
fn settle(app: *App) !void {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try app.tick(App.nowMs(t.io));
        if (!app.git.status_pending and app.git.busy == 0 and app.git.status != null) return;
        t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return error.GitNeverSettled;
}

/// `Ctrl+P`'s rows: whether one names `name`.
fn pickerOffers(app: *App, name: []const u8) !bool {
    try command.run(app, .{ .static = .@"picker.files" });
    defer app.overlay.deinit(app.gpa);
    for (app.overlay.picker.labels) |l| if (std.mem.endsWith(u8, l, name)) return true;
    return false;
}

/// The section headers top to bottom, by folder name.
fn headerOrder(app: *App, buf: *[4][]const u8) [][]const u8 {
    var n: usize = 0;
    for (app.tree.rows.items) |r| if (r.header) {
        const p = if (r.root == 0) app.workspace else app.tree.roots.items[r.root - 1].path;
        buf[n] = std.fs.path.basename(p);
        n += 1;
    };
    return buf[0..n];
}

fn screenRow(app: *App, arena: Allocator, y: u16) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var x: u16 = 0;
    while (x < app.screen.width) : (x += 1) {
        const c = app.screen.readCell(x, y) orelse continue;
        try out.appendSlice(arena, c.char.grapheme);
    }
    return out.items;
}

test "a switch moves the workspace: the title, the statusline's folder and branch, git's repo and Ctrl+P follow; the IPC dir stays; switching back restores them" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("main/src/a.zig", "a");
    try f.write("main/only_primary.txt", "p");
    try f.write("side/only_extra.txt", "e");
    try f.repo("main", "trunk");
    try f.repo("side", "feature");
    const main_ws = try f.path("main");
    defer t.allocator.free(main_ws);
    const side_ws = try f.path("side");
    defer t.allocator.free(side_ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = main_ws, .cols = 160, .rows = 40 });
    defer app.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ipc = try arena.dupe(u8, try mount_pane.ipcDir(&app));
    _ = try app.tree.addRoot(&app, side_ws, null);
    try git.discover(&app);
    try git.requestStatus(&app);
    try settle(&app);
    try t.expectEqualStrings("trunk", app.git.headLabel().?);
    try app.tree.refresh(&app);
    try app.tree.setExpanded("src", true);
    try t.expect(try pickerOffers(&app, "only_primary.txt"));

    try app.tree.switchTo(&app, 1);
    try settle(&app);
    try t.expectEqualStrings(side_ws, app.workspace);
    try t.expectEqualStrings(side_ws, app.git.activeRepo().?.path);
    try t.expectEqualStrings("feature", app.git.headLabel().?);
    try t.expectEqualStrings("workspace opened: side", app.lastToast().?);
    try app.render();
    // The top bar names the workspace; the statusline its repo and branch.
    try t.expect(std.mem.indexOf(u8, try screenRow(&app, arena, 0), "side") != null);
    // The statusline is the row above the message line.
    const status = try screenRow(&app, arena, app.screen.height - 2);
    try t.expect(std.mem.indexOf(u8, status, "feature") != null);
    try t.expect(std.mem.indexOf(u8, status, "trunk") == null);
    // Ctrl+P walks the new workspace, not the old.
    try t.expect(try pickerOffers(&app, "only_extra.txt"));
    try t.expect(!try pickerOffers(&app, "only_primary.txt"));
    // The old workspace's fold travels with its section, absolute now.
    try t.expect(!app.tree.isExpanded("src"));
    const main_src = try std.fs.path.join(arena, &.{ main_ws, "src" });
    try t.expect(app.tree.isExpanded(main_src));
    // The channel an integration was told about does not move.
    try t.expectEqualStrings(ipc, try mount_pane.ipcDir(&app));

    // Back: the old workspace's `○` is root 1 now.
    try t.expectEqualStrings(main_ws, app.tree.roots.items[0].path);
    try app.tree.switchTo(&app, 1);
    try settle(&app);
    try t.expectEqualStrings(main_ws, app.workspace);
    try t.expectEqualStrings("trunk", app.git.headLabel().?);
    try t.expect(try pickerOffers(&app, "only_primary.txt"));
    // Its folds came back with it, spelled workspace-relative again.
    try t.expect(app.tree.isExpanded("src"));
    try t.expectEqual(@as(u8, 0), app.tree.primary_slot);
}

test "a switch keeps the sections in their order — only the `●` moves — across three roots and back" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("ws/w.txt", "w");
    try f.write("aa/a.txt", "a");
    try f.write("bb/b.txt", "b");
    const ws = try f.path("ws");
    defer t.allocator.free(ws);
    const aa = try f.path("aa");
    defer t.allocator.free(aa);
    const bb = try f.path("bb");
    defer t.allocator.free(bb);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.tree.addRoot(&app, aa, null);
    _ = try app.tree.addRoot(&app, bb, null);
    try app.tree.refresh(&app);
    var buf: [4][]const u8 = undefined;
    const want = [_][]const u8{ "ws", "aa", "bb" };
    try t.expectEqualDeep(@as([]const []const u8, &want), headerOrder(&app, &buf));
    // To the last, then the middle, then the first: the order holds and
    // the primary is the section switched to, each time.
    for ([_][]const u8{ bb, aa, ws }) |target| {
        const idx = app.tree.indexOfRoot(&app, target).?;
        try app.tree.switchTo(&app, idx);
        try t.expectEqualStrings(target, app.workspace);
        try t.expectEqualDeep(@as([]const []const u8, &want), headerOrder(&app, &buf));
        // The primary's section is the open one, its header the cursor's.
        try t.expectEqual(app.tree.headerRow(0).?, app.tree.cursor);
    }
    try t.expectEqual(@as(u8, 0), app.tree.primary_slot);
    // One spelling per root, however often it is switched to.
    try t.expect(app.retired_workspaces.items.len <= 2);
}

test "a switch drops the HTTP env picked for the old workspace and takes the new one's trust; switching back restores the launch trust" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("ws/w.txt", "w");
    // An init.lua is a claim to run code: untrusted until answered.
    try f.write("wild/.mnml/init.lua", "print('x')");
    const ws = try f.path("ws");
    defer t.allocator.free(ws);
    const wild = try f.path("wild");
    defer t.allocator.free(wild);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .workspace_trusted = true });
    defer app.deinit();
    _ = try app.tree.addRoot(&app, wild, null);
    app.http.env_override = try t.allocator.dupe(u8, "dev");
    try app.tree.switchTo(&app, 1);
    try t.expect(app.http.env_override == null);
    try t.expect(!app.workspace_trusted);
    try app.tree.switchTo(&app, 1);
    try t.expectEqualStrings(ws, app.workspace);
    try t.expect(app.workspace_trusted);
}
