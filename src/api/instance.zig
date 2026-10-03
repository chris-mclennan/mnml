//! One running instance's API presence: the socket bound in the shared
//! directory, and the `<pid>.zon` marker beside it (§4.1–§4.2). The
//! terminal loop starts it when `.api.enabled` (the default) and stops it
//! on the way out, whatever the exit. Headless binds nothing.
//!
//! A `--sandbox` run puts both under its sandbox directory, so nothing
//! outside it finds the instance; its own panes are told the path.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const paths = @import("paths.zig");
const server_mod = @import("server.zig");
const marker = @import("../tui/marker.zig");
const sandbox = @import("../config/root.zig").sandbox;

pub const Instance = struct {
    gpa: Allocator,
    io: Io,
    /// Owned.
    marker_path: []u8,
    server: *server_mod.Server,

    /// Bind and write the marker; the App's panes are told the socket
    /// from now on.
    pub fn start(app: *App, env: *const std.process.Environ.Map) !Instance {
        const gpa = app.gpa;
        const io = app.io;
        const dir = if (app.sandboxState() != .off and env.get(paths.env_dir) == null)
            try std.fs.path.join(gpa, &.{ env.get(sandbox.env_var) orelse ".", "api" })
        else
            try paths.dir(gpa, env);
        defer gpa.free(dir);
        try paths.ensureDir(io, dir);
        const pid = paths.selfPid();
        const sock = try paths.socketPath(gpa, dir, pid);
        defer gpa.free(sock);
        const server = try server_mod.Server.start(gpa, io, app.events, sock);
        errdefer {
            server.stop();
            server.destroy();
        }
        const mpath = try paths.markerPath(gpa, dir, pid);
        errdefer gpa.free(mpath);
        try marker.writeInstance(gpa, io, mpath, .{
            .pid = pid,
            .version = @import("build_options").version,
            .workspace = app.workspace,
            .roots = &.{app.workspace},
            .socket = server.path(),
            .started_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
        });
        app.api.server = server;
        app.api.socket = server.path();
        return .{ .gpa = gpa, .io = io, .marker_path = mpath, .server = server };
    }

    pub fn stop(self: *Instance, app: *App) void {
        app.api.server = null;
        app.api.socket = "";
        Io.Dir.cwd().deleteFile(self.io, self.marker_path) catch {};
        self.server.stop();
        self.server.destroy();
        self.gpa.free(self.marker_path);
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const event = @import("../core/event.zig");
const gate = @import("../app/ipc_gate.zig");
const api_app = @import("../app/api.zig");
const remote = @import("remote.zig");

/// One `mnml remote` on its own thread while this one plays the loop:
/// handle what arrives, and say no to anything that asks. (The App's
/// hooks hold it to the thread that made it.)
const Call = struct {
    env: *std.process.Environ.Map,
    cwd: []const u8,
    argv: []const []const u8,
    out: *Io.Writer.Allocating,
    err: *Io.Writer.Allocating,
    code: u8 = 255,
    done: std.atomic.Value(bool) = .init(false),

    fn run(c: *Call) void {
        c.code = remote.run(t.allocator, t.io, c.env, c.cwd, c.argv, .{ .out = &c.out.writer, .err = &c.err.writer });
        c.done.store(true, .release);
    }
};

fn remoteRun(app: *App, env: *std.process.Environ.Map, cwd: []const u8, argv: []const []const u8, out: *Io.Writer.Allocating, err: *Io.Writer.Allocating) !u8 {
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    var call: Call = .{ .env = env, .cwd = cwd, .argv = argv, .out = out, .err = err };
    const th = try std.Thread.spawn(.{}, Call.run, .{&call});
    var buf: [16]event.AppEvent = undefined;
    while (!call.done.load(.acquire)) {
        app.events.wake.waitTimeout(app.io, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch {};
        app.events.wake.reset();
        const n = app.events.drain(app.io, &buf);
        for (buf[0..n]) |ev| try app.handle(ev);
        while (app.ipc_gate.pending.items.len > 0) try gate.answer(app, app.ipc_gate.pending.items[0].id, 2);
    }
    th.join();
    return call.code;
}

test "mnml remote finds the instance by the directory it runs in, acts as its pane by token, and says why in its exit code" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "1\n2\n3\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 80, .rows = 24 });
    defer app.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const api_dir = try std.fs.path.join(t.allocator, &.{ ws, "api" });
    defer t.allocator.free(api_dir);
    try env.put(paths.env_dir, api_dir);
    var inst = try Instance.start(&app, &env);
    defer inst.stop(&app);
    // Pane 3's token, as its spawn would mint it.
    const tok = (try api_app.mintToken(&app, 3)).?;

    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    const sub = try std.fs.path.join(t.allocator, &.{ ws, "deep", "er" });
    defer t.allocator.free(sub);

    // Outside any pane: found by the directory, and only reads.
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, sub, &.{ "status", "--json" }, &out, &err));
    try t.expect(std.mem.indexOf(u8, out.written(), "\"focus\"") != null);
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, sub, &.{"instances"}, &out, &err));
    try t.expect(std.mem.indexOf(u8, out.written(), ws) != null);
    try t.expectEqual(@as(u8, 4), try remoteRun(&app, &env, sub, &.{"panes"}, &out, &err));
    try t.expectEqual(@as(u8, 4), try remoteRun(&app, &env, sub, &.{ "run", "view.toggle_tree" }, &out, &err));
    try t.expectEqual(@as(u8, 3), try remoteRun(&app, &env, sub, &.{ "--instance", "1", "status" }, &out, &err));
    // A second instance elsewhere (pid 1 is alive, so its marker stays):
    // the directory decides, and outside both nothing does.
    const other = try std.fs.path.join(t.allocator, &.{ api_dir, "1.zon" });
    defer t.allocator.free(other);
    try marker.writeInstance(t.allocator, t.io, other, .{ .pid = 1, .workspace = "/elsewhere", .roots = &.{"/elsewhere"}, .socket = "/elsewhere/1.sock" });
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, sub, &.{"ping"}, &out, &err));
    try t.expectEqual(@as(u8, 3), try remoteRun(&app, &env, "/nowhere", &.{"ping"}, &out, &err));
    try t.expect(std.mem.indexOf(u8, err.written(), "several mnml are running") != null);
    try t.expectEqual(@as(u8, 1), try remoteRun(&app, &env, sub, &.{ "call", "commands.run", "{\"id\":\"no.such.command\"}" }, &out, &err));

    // Inside pane 3: its socket and token from the environment.
    try env.put(paths.env_socket, inst.server.path());
    try env.put(paths.env_token, &tok);
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, ws, &.{ "open", "a.txt:2" }, &out, &err));
    try t.expect(std.mem.startsWith(u8, out.written(), "opened a.txt:2 in pane "));
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, ws, &.{"panes"}, &out, &err));
    try t.expect(std.mem.indexOf(u8, out.written(), "a.txt") != null);
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, ws, &.{ "run", "view.toggle_tree" }, &out, &err));
    // An edit command asks; the pump says no.
    try t.expectEqual(@as(u8, 5), try remoteRun(&app, &env, ws, &.{ "run", "scratch.new" }, &out, &err));
    try t.expectEqual(@as(u8, 0), try remoteRun(&app, &env, ws, &.{"ping"}, &out, &err));
    try t.expectEqualStrings("pong\n", out.written());
}
