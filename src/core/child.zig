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
