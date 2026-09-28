//! Configured tasks (`.tasks = .{ .build = .{ .cmd = "zig build" } }`):
//! each runs in a pty pane below the active one, at its `cwd` or the
//! workspace. `task.run` picks one; every task is also a dynamic
//! command `task.<name>` (palette / keybinding / `:task <name>`); the
//! `.startup.tasks` names run when the `startup` hook fires.
//!
//! The state owns its copies of the config strings: the config's arena
//! is replaced wholesale on reload, while a task list must outlive it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const hooks = @import("../core/hooks.zig");
const config = @import("../config/root.zig");
const runners = @import("runners.zig");
const cmd_picker = @import("cmd_picker.zig");

pub const table = .{
    .@"task.run" = &pickAndRun,
};

/// One task as the app keeps it. Owned strings.
pub const Task = struct {
    name: []u8,
    cmd: []u8,
    /// Absolute or workspace-relative; the workspace when null.
    cwd: ?[]u8,
};

/// What `install` takes — borrowed; the state dupes.
pub const Def = struct {
    name: []const u8,
    cmd: []const u8,
    cwd: ?[]const u8 = null,
};

pub const State = struct {
    list: std.ArrayListUnmanaged(Task) = .empty,
    /// Run when the `startup` hook fires, in order. Owned.
    startup: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.clear(gpa);
        self.list.deinit(gpa);
        self.startup.deinit(gpa);
    }

    fn clear(self: *State, gpa: Allocator) void {
        for (self.list.items) |task| {
            gpa.free(task.name);
            gpa.free(task.cmd);
            if (task.cwd) |c| gpa.free(c);
        }
        self.list.clearRetainingCapacity();
        for (self.startup.items) |s| gpa.free(s);
        self.startup.clearRetainingCapacity();
    }

    pub fn get(self: *const State, name: []const u8) ?*const Task {
        for (self.list.items) |*task| if (std.mem.eql(u8, task.name, name)) return task;
        return null;
    }
};

/// Replace the task list. Registers a `task.<name>` command per task
/// (an ex runner: `:task <name>`); the previous set's commands go.
pub fn install(app: *App, defs: []const Def, startup: []const []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    for (app.tasks.list.items) |task| {
        const id = try std.fmt.allocPrint(app.frame.allocator(), "task.{s}", .{task.name});
        _ = app.dyn_commands.unregister(id);
    }
    app.tasks.clear(gpa);
    for (defs) |d| {
        if (d.name.len == 0 or d.cmd.len == 0) continue;
        const name = try gpa.dupe(u8, d.name);
        errdefer gpa.free(name);
        const cmd = try gpa.dupe(u8, d.cmd);
        errdefer gpa.free(cmd);
        const cwd: ?[]u8 = if (d.cwd) |c| try gpa.dupe(u8, c) else null;
        errdefer if (cwd) |c| gpa.free(c);
        try app.tasks.list.append(gpa, .{ .name = name, .cmd = cmd, .cwd = cwd });
        const id = try std.fmt.allocPrint(app.frame.allocator(), "task.{s}", .{name});
        const title = try std.fmt.allocPrint(app.frame.allocator(), "Task: {s} — {s}", .{ name, cmd });
        const line = try std.fmt.allocPrint(app.frame.allocator(), "task {s}", .{name});
        _ = app.dyn_commands.register(.{ .id = id, .title = title, .group = "term", .runner = .{ .ex = line }, .owner = .{ .script = 0 } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ShadowsBuiltin => app.toast("task `{s}` shadows a built-in command; use :task {s}", .{ name, name }),
        };
    }
    for (startup) |s| try app.tasks.startup.append(gpa, try gpa.dupe(u8, s));
}

/// The typed config's `.tasks` and `.startup.tasks`.
pub fn installFromConfig(app: *App, cfg: *const config.Config) Allocator.Error!void {
    const arena = app.frame.allocator();
    var defs: std.ArrayListUnmanaged(Def) = .empty;
    var it = cfg.tasks.iterator();
    while (it.next()) |kv| try defs.append(arena, .{ .name = kv.key_ptr.*, .cmd = kv.value_ptr.cmd, .cwd = kv.value_ptr.cwd });
    try install(app, defs.items, cfg.startup.tasks);
}

/// `.startup` hook: run the configured startup tasks. Unknown names
/// toast and are skipped.
pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    var i: usize = 0;
    while (i < app.tasks.startup.items.len) : (i += 1) {
        const name = app.tasks.startup.items[i];
        runNamed(app, name) catch |err| switch (err) {
            else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("startup task {s}: {s}", .{ name, @errorName(err) }),
        };
    }
}

/// Run one task by name in a pane below.
pub fn runNamed(app: *App, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const task = app.tasks.get(std.mem.trim(u8, name, " \t")) orelse return app.diag.fail(arena, "unknown task: {s}", .{name});
    const cwd: []const u8 = if (task.cwd) |c| (if (std.fs.path.isAbsolute(c)) c else try std.fs.path.join(arena, &.{ app.workspace, c })) else app.workspace;
    const label = try arena.dupe(u8, task.name);
    const cmd = try arena.dupe(u8, task.cmd);
    _ = try runners.spawn(app, label, cmd, cwd, .task);
}

/// `task.run`: a picker over the configured tasks.
fn pickAndRun(app: *App) CommandError!void {
    const gpa = app.gpa;
    if (app.tasks.list.items.len == 0) return app.diag.fail(app.frame.allocator(), "no tasks configured (.tasks in config.zon)", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (app.tasks.list.items) |task| try labels.append(gpa, try gpa.dupe(u8, task.name));
    try cmd_picker.openPicker(app, "Run task", .tasks, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;
const pty_pane = @import("pty_pane.zig");

test "install registers task.<name> commands; :task and the picker run them; startup runs its list" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try install(&app, &.{
        .{ .name = "hello", .cmd = "printf task-hello" },
        .{ .name = "where", .cmd = "pwd", .cwd = "/" },
    }, &.{"hello"});
    try t.expect(app.dyn_commands.get("task.hello") != null);
    try t.expect(app.dyn_commands.get("task.where") != null);
    try t.expectEqualStrings("Task: hello — printf task-hello", app.dyn_commands.at(app.dyn_commands.get("task.hello").?).?.title);
    // Unknown names fail with a reason.
    try t.expectError(error.Failed, runNamed(&app, "nope"));
    try t.expectEqualStrings("unknown task: nope", app.diag.msg.?);
    // The task runs `printf`: POSIX from here on.
    if (builtin.os.tag == .windows) return;

    // The picker lists the names; Enter on the first runs it.
    try command.run(&app, .{ .static = .@"task.run" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try app.handle(.{ .key = Key.named(.enter) });
    const id = app.active.?;
    try t.expectEqualStrings("hello", app.panes.get(id).?.title());
    try t.expect(app.panes.pty(id).?.kind == .task);
    try t.expect(try pty_pane.tickUntilScreen(&app, "task-hello", 5000));

    // The dynamic command runs through `:task where` at its cwd.
    try command.runNamed(&app, "task.where");
    const where = app.active.?;
    try t.expect(where != id);
    try t.expectEqualStrings("/", app.panes.pty(where).?.cwd.?);

    // The startup hook runs the startup list.
    const before = app.panes.count();
    app.hooks.emit(&app, .startup);
    try t.expectEqual(before + 1, app.panes.count());

    // Reinstall replaces the set and drops the old commands.
    try install(&app, &.{.{ .name = "only", .cmd = "true" }}, &.{});
    try t.expect(app.dyn_commands.get("task.hello") == null);
    try t.expect(app.dyn_commands.get("task.only") != null);
    try t.expectEqual(@as(usize, 0), app.tasks.startup.items.len);
}

test "installFromConfig reads the typed config's tasks and startup list" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace });
    defer app.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg: config.Config = .{};
    try cfg.tasks.put(arena, "build", .{ .cmd = "zig build" });
    try cfg.tasks.put(arena, "serve", .{ .cmd = "python -m http.server", .cwd = "site" });
    cfg.startup.tasks = &.{"serve"};
    try installFromConfig(&app, &cfg);
    try t.expectEqual(@as(usize, 2), app.tasks.list.items.len);
    try t.expectEqualStrings("site", app.tasks.get("serve").?.cwd.?);
    try t.expectEqualStrings("serve", app.tasks.startup.items[0]);
}
