//! The shutdown model, checked (D3). Every subsystem's workers run as
//! `io.concurrent` tasks inside an `Io.Group`, and shutdown is
//! `group.cancel(io)`. That only works if a worker blocked in a read can
//! be interrupted: `Io.Threaded` sends the worker thread a signal so the
//! read fails with EINTR, notices the cancel request there, and returns
//! `error.Canceled`. A pipe nobody writes to is the worst case — the read
//! would otherwise block forever.
//!
//! This is the probe the runner's own timeout path relies on the inverse
//! of (a thread it *cannot* cancel is abandoned instead), and the check
//! the pty reader, LSP client and every other pipe consumer depend on.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;

const Probe = struct {
    io: Io,
    fd: posix.fd_t,
    /// What the blocked read returned.
    result: enum { pending, data, canceled, other } = .pending,
    /// Set once the worker is about to block.
    entered: Io.Event = .unset,
};

fn blockedRead(p: *Probe) Io.Cancelable!void {
    const file: Io.File = .{ .handle = p.fd, .flags = .{ .nonblocking = false } };
    var buf: [16]u8 = undefined;
    p.entered.set(p.io);
    if (file.readStreaming(p.io, &.{&buf})) |_| {
        p.result = .data;
    } else |e| switch (e) {
        error.Canceled => {
            p.result = .canceled;
            return error.Canceled;
        },
        else => p.result = .other,
    }
}

test "Io.Group.cancel returns a worker blocked on a pipe read within 1 s" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const fds = try Io.Threaded.pipe2(.{});
    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);
    defer write_end.close(io);

    var probe: Probe = .{ .io = io, .fd = fds[0] };
    var group: Io.Group = .init;
    try group.concurrent(io, blockedRead, .{&probe});

    // Wait until the worker has reached the read, then give it a moment
    // to actually block in the syscall.
    try probe.entered.wait(io);
    try io.sleep(.fromMilliseconds(50), .awake);

    const t0 = Io.Timestamp.now(io, .awake);
    group.cancel(io);
    const elapsed_ms = t0.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();

    try std.testing.expectEqual(.canceled, probe.result);
    try std.testing.expect(elapsed_ms < 1000);
}
