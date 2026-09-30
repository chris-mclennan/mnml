//! SIGTERM, SIGHUP and SIGINT as an orderly exit, for both loops.
//!
//! The handler does two async-signal-safe things: it records which
//! signal came, and writes one byte to a self-pipe when a loop has
//! opened one. The loop notices, leaves the way a quit does — the
//! terminal given back, the session saved, the exit hook run — and
//! `main` returns `128 + signal`, so the defers there stop `--demo`'s
//! fakes and remove the `--sandbox` directory. Nothing that allocates,
//! locks or touches the file system runs inside the handler.
//!
//! The headless loop polls `caught` every turn (it never sleeps longer
//! than `poll_ms`); the terminal loop parks on its event queue, so a
//! task there blocks on `wakeFd` and posts an event (`tui/loop.zig`).
//!
//! A second signal while the first is being handled exits at once
//! (`_exit(128 + signal)`): a loop wedged somewhere a wakeup cannot
//! reach still dies on the next `kill`, as it did before.
//!
//! In a terminal, ctrl-c is a key (raw mode turns ISIG off), so SIGINT
//! only arrives from `kill -INT` or a shell running `--headless`.
//!
//! POSIX only; on Windows `install` does nothing and `caught` is null.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const supported = builtin.os.tag != .windows;

/// The signal that ended the run; 0 while none has.
var caught_sig: std.atomic.Value(u8) = .init(0);
/// The write end of the self-pipe, or -1.
var wake_w: std.atomic.Value(i32) = .init(-1);
var wake_r: i32 = -1;

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const n: u8 = @intCast(@intFromEnum(sig));
    if (caught_sig.cmpxchgStrong(0, n, .acq_rel, .acquire) != null) std.c._exit(128 + @as(c_int, n));
    const fd = wake_w.load(.acquire);
    if (fd >= 0) _ = std.c.write(fd, "s", 1);
}

/// Route SIGTERM, SIGHUP and SIGINT here. Idempotent.
pub fn install() void {
    if (comptime !supported) return;
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &sa, null);
    posix.sigaction(.HUP, &sa, null);
    posix.sigaction(.INT, &sa, null);
}

/// The signal that asked this process to end, if one has.
pub fn caught() ?u8 {
    const n = caught_sig.load(.acquire);
    return if (n == 0) null else n;
}

/// The conventional status for a run ended by `sig`: 143 for SIGTERM.
pub fn status(sig: u8) u8 {
    return 128 +| sig;
}

/// The read end of the self-pipe the handler writes to — made on the
/// first call, then the same fd. Null on Windows or when `pipe` fails
/// (the loop then only sees a signal on its next wakeup).
pub fn wakeFd() ?posix.fd_t {
    if (comptime !supported) return null;
    if (wake_r >= 0) return wake_r;
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return null;
    wake_r = fds[0];
    wake_w.store(fds[1], .release);
    // A signal that came before the pipe existed wrote nothing.
    if (caught() != null) _ = std.c.write(fds[1], "s", 1);
    return wake_r;
}

/// Tests only: forget a caught signal.
pub fn resetForTest() void {
    caught_sig.store(0, .release);
}

test "a signal is recorded and wakes the pipe; the status is 128 + signal" {
    if (comptime !supported) return error.SkipZigTest;
    defer resetForTest();
    resetForTest();
    try std.testing.expect(caught() == null);
    const fd = wakeFd() orelse return error.SkipZigTest;
    try std.testing.expectEqual(fd, wakeFd().?);
    onSignal(.TERM);
    try std.testing.expectEqual(@as(u8, 15), caught().?);
    try std.testing.expectEqual(@as(u8, 143), status(caught().?));
    try std.testing.expectEqual(@as(u8, 129), status(1));
    var b: [4]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fd, &b, b.len));
}
