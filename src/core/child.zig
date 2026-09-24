//! The two things `std.process.Child` does not do for you in Zig 0.16.
//!
//! The contract, from `std/process/Child.zig`: `kill(io)` sends SIGTERM,
//! blocks until the child is gone, reaps it, closes its pipes and leaves
//! `id == null`; it is idempotent. `wait(io)` asserts `id != null` on
//! entry and reaps. So `kill` then `wait` aborts the process every time,
//! and `wait` then `kill` is a no-op — including when the `wait` was
//! CANCELLED, which clears `id` without reaping or killing anything.
//!
//! - Owned a child you never waited on: `child.kill(io)` and nothing else.
//! - Waited on a child you did not kill: fine; a `kill` after it does
//!   nothing, harmful or otherwise.
//! - A `wait` that came back `Canceled`: the child is still out there.
//!   Take `child.id` BEFORE the wait and hand it to `reapAbandoned`.
//!
//! `docs/CONTRIBUTING.md` — "Child processes" — is the prose version.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Child = std.process.Child;

/// Kill and reap a child whose `wait` was cancelled or failed — the one
/// case `Child.kill` cannot cover, because that wait already cleared
/// `child.id`. A no-op for a null pid, on Windows, and for a pid that
/// is already gone. Uncancelable; ignores the OS's opinion.
pub fn reapAbandoned(pid: ?Child.Id) void {
    if (builtin.os.tag == .windows) return;
    const p = pid orelse return;
    std.posix.kill(p, .KILL) catch return;
    reap(p);
}

/// `waitpid` until it answers: a cancelled task is still being
/// signalled. `Io.Group.cancel` keeps sending SIGIO to a worker's thread
/// until the task is seen to finish, and the one that lands here — after
/// the `wait` already returned `Canceled` — interrupts this `waitpid`
/// with EINTR. Taking that as done left the killed child a zombie, and
/// a zombie is a pid `kill(pid, 0)` still calls there: two tests failed
/// on it under load, one run in twenty, on a child that was long dead.
/// `ECHILD` is the one other answer — already reaped — and is done.
fn reap(pid: Child.Id) void {
    var status: u32 = undefined;
    while (true) {
        const rc = std.c.waitpid(pid, @ptrCast(&status), 0);
        if (rc == -1 and std.c.errno(rc) == .INTR) continue;
        return;
    }
}

/// How long `terminate` gives a child between SIGTERM and SIGKILL.
pub const default_grace: Io.Duration = .fromSeconds(2);

pub const TerminateOptions = struct {
    /// SIGTERM to SIGKILL.
    grace: Io.Duration = default_grace,
    /// The child leads its own process group (spawned with `.pgid = 0`):
    /// signal the whole group, so whatever it started goes with it.
    group: bool = false,
};

/// `Child.kill`, bounded: SIGTERM, up to `grace` for the child to act on
/// it, then SIGKILL, then reap. `Child.kill` alone sends SIGTERM and
/// blocks in `wait4` until the child exits — forever, for one that
/// ignores SIGTERM or is wedged before it can act on it (a Chrome stuck
/// on a keychain prompt froze `App.deinit` that way). Leaves the child
/// as `Child.kill` does: reaped, pipes closed, `id == null`. Idempotent,
/// uncancelable in effect (a cancel only cuts the grace short). On
/// Windows `Child.kill` already terminates outright; it is that.
pub fn terminate(io: Io, child: *Child, opts: TerminateOptions) void {
    if (builtin.os.tag == .windows) return child.kill(io);
    const pid = child.id orelse return child.kill(io);
    const target: std.posix.pid_t = if (opts.group) -pid else pid;
    std.posix.kill(target, .TERM) catch {};
    if (reapedWithin(io, pid, opts.grace)) {
        // Reaped here, so `Child.kill` must not run (its SIGTERM would
        // find no such process). Finish what it would have done. The
        // group's stragglers go too: a pid is not handed out again while
        // a group of that id still has members, so `-pid` is still ours.
        if (opts.group) std.posix.kill(-pid, .KILL) catch {};
        closePipes(io, child);
        return;
    }
    std.posix.kill(target, .KILL) catch {};
    // A child that left its group is still ours to stop.
    if (opts.group) std.posix.kill(pid, .KILL) catch {};
    // SIGKILL cannot be ignored: this `wait4` returns. Never a `wait`
    // after a kill (see the top of the file).
    child.kill(io);
}

/// Poll `waitpid(WNOHANG)` every 10 ms until `pid` has exited (and is
/// reaped by this call) or `limit` passed. `ECHILD` — somebody else
/// reaped it — counts as exited.
fn reapedWithin(io: Io, pid: Child.Id, limit: Io.Duration) bool {
    const start = Io.Timestamp.now(io, .awake);
    while (true) {
        var status: c_int = undefined;
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return true;
        if (rc == -1) switch (std.c.errno(rc)) {
            .INTR => continue,
            else => return true,
        };
        if (start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= limit.nanoseconds) return false;
        io.sleep(.fromMilliseconds(10), .awake) catch return false;
    }
}

fn closePipes(io: Io, child: *Child) void {
    if (child.stdin) |f| f.close(io);
    if (child.stdout) |f| f.close(io);
    if (child.stderr) |f| f.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    child.id = null;
}

/// False while `pid` names a live *or* unreaped (zombie) process; true
/// once it is gone for good (`kill(pid, 0)` → ESRCH). On Windows, where
/// there is no such probe, always true. Tests use it to hold a child
/// really was taken down.
pub fn gone(pid: Child.Id) bool {
    if (builtin.os.tag == .windows) return true;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err == error.ProcessNotFound;
    return false;
}

/// `gone`, waited for: true as soon as `pid` is gone, polling
/// `kill(pid, 0)` every 10 ms until `deadline` has passed on the awake
/// clock; false if the process is still there when it has. For a test
/// holding that a child was taken down: `Child.kill` and `reapAbandoned`
/// both return reaped, so `gone` is true the instant they do, and a
/// bounded poll costs a healthy run nothing — it fails on a real orphan
/// or an unreaped zombie, still there at the deadline, and never on the
/// scheduler. On Windows, always true, like `gone`.
pub fn goneWithin(io: Io, pid: Child.Id, deadline: Io.Duration) bool {
    if (builtin.os.tag == .windows) return true;
    const start = Io.Timestamp.now(io, .awake);
    while (!gone(pid)) {
        const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
        if (elapsed.nanoseconds >= deadline.nanoseconds) return false;
        io.sleep(.fromMilliseconds(10), .awake) catch return gone(pid);
    }
    return true;
}

test "a waited child is gone, on every platform: the Windows arm answers too" {
    // The POSIX tests below script `/bin/sleep` and skip on Windows;
    // this one runs the platform's own shell (`sh -c`, `cmd.exe /d /c`)
    // so the Windows build of this file has a test that executes.
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var buf: [4][]const u8 = undefined;
    var child = try std.process.spawn(io, .{
        .argv = @import("pty").shellArgv(&buf, &env, "exit 3"),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    try std.testing.expectEqual(Child.Term{ .exited = 3 }, try child.wait(io));
    try std.testing.expect(goneWithin(io, pid, .fromSeconds(10)));
    // Nothing to reap is a no-op, not a crash.
    reapAbandoned(null);
}

test "gone: a reaped child is gone, a live one is not" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    try std.testing.expect(!gone(pid));
    child.kill(io);
    try std.testing.expect(gone(pid));
}

test "reapAbandoned takes down a child whose wait was given up on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id;
    // The shape a cancelled `wait` leaves behind: `id` cleared, the
    // process untouched. (`wait` itself cannot be cancelled from here;
    // the field is cleared by hand and the pipes were never opened.)
    child.id = null;
    reapAbandoned(pid);
    try std.testing.expect(gone(pid.?));
    // Idempotent: a second call finds nothing.
    reapAbandoned(pid);
    reapAbandoned(null);
}

test "reap: a waitpid interrupted by the cancel signal is retried, not taken for done — the child is reaped, not left a zombie" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    try std.testing.expect(!gone(pid));
    // What `Io.Group.cancel` does to a worker's thread, only denser: a
    // SIGIO at the reaping thread every few microseconds, twenty
    // thousand of them into a `waitpid` on a child that is still alive
    // — every one an EINTR, since `Io.Threaded` installed the no-op
    // handler — and only then the kill. A reap that took an EINTR for
    // done returns before the child is dead and leaves it a zombie.
    const Storm = struct {
        target: std.c.pthread_t,
        child: Child.Id,
        reaping: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
        fn run(st: *@This()) void {
            while (!st.reaping.load(.acquire)) std.Thread.yield() catch {};
            var sent: usize = 0;
            while (!st.stop.load(.acquire)) : (sent += 1) {
                _ = std.c.pthread_kill(st.target, .IO);
                std.Thread.yield() catch {};
                if (sent == 20_000) std.posix.kill(st.child, .KILL) catch {};
            }
        }
    };
    var storm: Storm = .{ .target = std.c.pthread_self(), .child = pid };
    const th = try std.Thread.spawn(.{}, Storm.run, .{&storm});
    storm.reaping.store(true, .release);
    reap(pid);
    storm.stop.store(true, .release);
    th.join();
    try std.testing.expect(gone(pid));
}

test "goneWithin: a live child is still there at the deadline; a killed one is gone before it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    // Nobody killed it: the poll runs out its deadline and says so.
    try std.testing.expect(!goneWithin(io, pid, .fromMilliseconds(50)));
    child.kill(io);
    try std.testing.expect(goneWithin(io, pid, .fromSeconds(10)));
}

/// Runs `terminate` on its own thread so a test can hold it to a
/// deadline: a `terminate` that hangs (a SIGTERM-only kill waiting on a
/// child that ignores it) fails the test instead of wedging the run.
const Terminator = struct {
    child: *Child,
    opts: TerminateOptions,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Terminator, io: Io) void {
        terminate(io, self.child, self.opts);
        self.done.store(true, .release);
    }
    /// True when `terminate` returned within `limit`. Past it, the test
    /// SIGKILLs `pids` itself — unblocking the stuck reap — and says no.
    fn finishedWithin(self: *Terminator, io: Io, th: std.Thread, limit: Io.Duration, pids: []const Child.Id) bool {
        const start = Io.Timestamp.now(io, .awake);
        while (!self.done.load(.acquire)) {
            if (start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= limit.nanoseconds) {
                for (pids) |p| std.posix.kill(p, .KILL) catch {};
                th.join();
                return false;
            }
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        th.join();
        return true;
    }
};

test "terminate: a child that ignores SIGTERM is SIGKILLed after the grace and reaped — the close returns" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    // The wedged-Chrome shape: SIGTERM is ignored (and stays ignored
    // across the exec), so `Child.kill` alone waits forever.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 86400" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    const pid = child.id.?;
    // Let the shell install the trap and exec before the signal lands.
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    var t: Terminator = .{ .child = &child, .opts = .{ .grace = .fromMilliseconds(200) } };
    const th = try std.Thread.spawn(.{}, Terminator.run, .{ &t, io });
    try std.testing.expect(t.finishedWithin(io, th, .fromSeconds(5), &.{pid}));
    try std.testing.expect(gone(pid));
    try std.testing.expectEqual(@as(?Child.Id, null), child.id);
    try std.testing.expectEqual(@as(?Io.File, null), child.stderr);
    // Idempotent.
    terminate(io, &child, .{});
}

test "terminate: a group leader's SIGTERM-ignoring grandchild goes with it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pbuf);
    var abuf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const script = try std.fmt.bufPrint(&abuf, "trap '' TERM; /bin/sleep 86400 & echo $! > '{s}/gc.pid'; exec /bin/sleep 86400", .{pbuf[0..n]});
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    var gc: Child.Id = 0;
    var tries: usize = 0;
    while (tries < 300) : (tries += 1) {
        var gbuf: [32]u8 = undefined;
        if (tmp.dir.readFile(io, "gc.pid", &gbuf)) |txt| {
            if (std.fmt.parseInt(Child.Id, std.mem.trim(u8, txt, " \n"), 10)) |g| {
                gc = g;
                break;
            } else |_| {}
        } else |_| {}
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(gc != 0);
    defer std.posix.kill(gc, .KILL) catch {};
    var t: Terminator = .{ .child = &child, .opts = .{ .grace = .fromMilliseconds(200), .group = true } };
    const th = try std.Thread.spawn(.{}, Terminator.run, .{ &t, io });
    try std.testing.expect(t.finishedWithin(io, th, .fromSeconds(5), &.{ pid, gc }));
    try std.testing.expect(gone(pid));
    // Not our child — launchd / init reaps it — so poll.
    try std.testing.expect(goneWithin(io, gc, .fromSeconds(5)));
}

test "terminate: a child that exits on SIGTERM is reaped at once, not held for the grace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "86400" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    const start = Io.Timestamp.now(io, .awake);
    terminate(io, &child, .{ .grace = .fromSeconds(30) });
    try std.testing.expect(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds < std.time.ns_per_s * 10);
    try std.testing.expect(gone(pid));
    try std.testing.expectEqual(@as(?Io.File, null), child.stdout);
}
