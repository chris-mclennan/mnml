//! A signal ends `--sandbox` and `--demo` the way a quit does: the
//! installed binary is started as a process — headless, and in a pty for
//! the terminal loop — sent SIGTERM, and must exit 143 with the sandbox
//! directory gone and (`--demo`) its fake servers stopped.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const pty = @import("pty");
const sandbox = @import("sandbox.zig");
const demo = @import("demo.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    base: []const u8,
    /// `TMPDIR` for the child: the sandbox is made in here.
    tmp_root: []const u8,
    ipc: []const u8,
    env: Map,

    fn init(self: *Fixture) !void {
        self.tmp = t.tmpDir(.{});
        self.arena_state = .init(t.allocator);
        const arena = self.arena_state.allocator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(t.io, &buf);
        self.base = try arena.dupe(u8, buf[0..n]);
        self.tmp_root = try std.fs.path.join(arena, &.{ self.base, "t" });
        self.ipc = try std.fs.path.join(arena, &.{ self.base, "ipc" });
        const home = try std.fs.path.join(arena, &.{ self.base, "home" });
        try Io.Dir.cwd().createDirPath(t.io, self.tmp_root);
        try Io.Dir.cwd().createDirPath(t.io, home);
        // Only what the run needs: a HOME outside the temp root (else
        // `--sandbox` would run in it as it is), no real config, no
        // credentials, no update check, no browser.
        self.env = .init(t.allocator);
        if (std.c.getenv("PATH")) |p| try self.env.put("PATH", std.mem.span(p));
        try self.env.put("HOME", home);
        try self.env.put("TMPDIR", self.tmp_root);
        try self.env.put("MNML_IPC_DIR", self.ipc);
        try self.env.put("MNML_NO_UPDATE_CHECK", "1");
        try self.env.put("MNML_OPEN_URL", "none");
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    /// The `mnml-sandbox-*` directories under the temp root.
    fn sandboxes(self: *Fixture) !usize {
        var dir = try Io.Dir.cwd().openDir(t.io, self.tmp_root, .{ .iterate = true });
        defer dir.close(t.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (try it.next(t.io)) |e| {
            if (std.mem.startsWith(u8, e.name, sandbox.dir_prefix)) n += 1;
        }
        return n;
    }

    fn sandboxRoot(self: *Fixture) ![]const u8 {
        var dir = try Io.Dir.cwd().openDir(t.io, self.tmp_root, .{ .iterate = true });
        defer dir.close(t.io);
        var it = dir.iterate();
        while (try it.next(t.io)) |e| {
            if (std.mem.startsWith(u8, e.name, sandbox.dir_prefix)) return std.fs.path.join(self.arena_state.allocator(), &.{ self.tmp_root, e.name });
        }
        return error.NoSandbox;
    }

    fn events(self: *Fixture) []const u8 {
        const p = std.fs.path.join(self.arena_state.allocator(), &.{ self.ipc, "events.jsonl" }) catch return "";
        return Io.Dir.cwd().readFileAlloc(t.io, p, self.arena_state.allocator(), .limited(1 << 20)) catch "";
    }
};

fn sleepMs(ms: u64) void {
    t.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Reap `pid` within `ms`, else SIGKILL it and fail. Returns the exit
/// status (a death by signal is an error: the handler did not run).
fn waitExit(pid: std.posix.pid_t, ms: u64) !u8 {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 20) {
        var st: c_int = 0;
        const r = std.c.waitpid(pid, &st, std.c.W.NOHANG);
        if (r == pid) {
            const s: u32 = @bitCast(st);
            if (std.c.W.IFEXITED(s)) return std.c.W.EXITSTATUS(s);
            return error.KilledBySignal;
        }
        sleepMs(20);
    }
    _ = std.c.kill(pid, std.c.SIG.KILL);
    var st: c_int = 0;
    _ = std.c.waitpid(pid, &st, 0);
    return error.DidNotExit;
}

/// The fake servers running for the sandbox at `root`: a command line
/// naming a fake's binary and a path under `root` (its `--url-file`).
fn fakesRunning(arena: Allocator, root: []const u8) !usize {
    const r = try std.process.run(arena, t.io, .{ .argv = &.{ "ps", "-Ao", "args=" } });
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |l| {
        if (std.mem.indexOf(u8, l, root) == null) continue;
        for (demo.fakes) |f| if (std.mem.indexOf(u8, l, f.name) != null) {
            n += 1;
            break;
        };
    }
    return n;
}

/// Start the installed binary headless with `flag`, wait until its loop
/// runs, SIGTERM it; the status and the fixture say the rest.
fn headlessRun(f: *Fixture, flag: []const u8, ready_ms: u64, before_kill: ?*const fn (*Fixture) anyerror!void) !u8 {
    const child = try std.process.spawn(t.io, .{
        .argv = &.{ build_options.mnml_exe, flag, "--headless" },
        .environ_map = &f.env,
        .cwd = .{ .path = f.base },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    var waited: u64 = 0;
    while (std.mem.indexOf(u8, f.events(), "\"event\":\"start\"") == null) : (waited += 50) {
        if (waited >= ready_ms) {
            _ = waitExit(pid, 0) catch {};
            return error.NeverStarted;
        }
        sleepMs(50);
    }
    if (before_kill) |cb| cb(f) catch |err| {
        _ = std.c.kill(pid, std.c.SIG.KILL);
        _ = waitExit(pid, 5000) catch {};
        return err;
    };
    try t.expectEqual(@as(usize, 1), try f.sandboxes());
    _ = std.c.kill(pid, std.c.SIG.TERM);
    return waitExit(pid, 20_000);
}

test "a signal: `--sandbox --headless` exits 143 on SIGTERM and the sandbox directory is gone" {
    if (comptime !sandbox.supported) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try t.expectEqual(@as(u8, 143), try headlessRun(&f, "--sandbox", 20_000, null));
    try t.expectEqual(@as(usize, 0), try f.sandboxes());
    try t.expect(std.mem.indexOf(u8, f.events(), "\"reason\":\"signal\"") != null);
}

var demo_root: []const u8 = "";

fn fakesUp(f: *Fixture) !void {
    demo_root = try f.sandboxRoot();
    try t.expectEqual(@as(usize, demo.fakes.len), try fakesRunning(f.arena_state.allocator(), demo_root));
}

test "a signal: `--demo --headless` exits 143 on SIGTERM, its fake servers are stopped and the sandbox directory is gone" {
    if (comptime !sandbox.supported) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try t.expectEqual(@as(u8, 143), try headlessRun(&f, demo.flag, 90_000, &fakesUp));
    try t.expectEqual(@as(usize, 0), try f.sandboxes());
    try t.expectEqual(@as(usize, 0), try fakesRunning(f.arena_state.allocator(), demo_root));
}

test "a signal: `--sandbox` in a terminal exits 143 on SIGTERM and the sandbox directory is gone" {
    if (comptime !sandbox.supported) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The pty's terminal logs what it does not implement of mnml's
    // capability probe; not this test's business.
    const level = t.log_level;
    t.log_level = .err;
    defer t.log_level = level;
    const s = try pty.Session.spawn(t.allocator, t.io, .{
        .cols = 100,
        .rows = 30,
        .env = &f.env,
        .argv = &.{ build_options.mnml_exe, "--sandbox" },
        .cwd = f.base,
    });
    defer s.deinit();
    // The IPC directory is made once the app is up: the terminal is
    // taken and the handler long installed.
    var waited: u64 = 0;
    while (true) : (waited += 20) {
        _ = s.pump();
        if (Io.Dir.cwd().access(t.io, f.ipc, .{})) |_| break else |_| {}
        if (waited >= 30_000 or s.exited() != null) return error.NeverStarted;
        sleepMs(20);
    }
    // A few frames in, so the loop is parked on its queue.
    for (0..25) |_| {
        _ = s.pump();
        sleepMs(20);
    }
    try t.expectEqual(@as(usize, 1), try f.sandboxes());
    _ = std.c.kill(s.child, std.c.SIG.TERM);
    waited = 0;
    const exit = while (true) : (waited += 20) {
        _ = s.pump();
        if (s.exited()) |e| break e;
        if (waited >= 20_000) {
            _ = std.c.kill(s.child, std.c.SIG.KILL);
            return error.DidNotExit;
        }
        sleepMs(20);
    };
    switch (exit) {
        .code => |c| try t.expectEqual(@as(u8, 143), c),
        .signal => return error.KilledBySignal,
    }
    try t.expectEqual(@as(usize, 0), try f.sandboxes());
}
