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
const Child = std.process.Child;

/// Kill and reap a child whose `wait` was cancelled or failed — the one
/// case `Child.kill` cannot cover, because that wait already cleared
/// `child.id`. A no-op for a null pid, on Windows, and for a pid that
/// is already gone. Uncancelable; ignores the OS's opinion.
pub fn reapAbandoned(pid: ?Child.Id) void {
    if (builtin.os.tag == .windows) return;
    const p = pid orelse return;
    std.posix.kill(p, .KILL) catch return;
    var status: u32 = undefined;
    _ = std.c.waitpid(p, @ptrCast(&status), 0);
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
