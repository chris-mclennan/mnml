//! Terminal input as a worker, POSIX: bytes from the tty → `vaxis.Parser`
//! → `std.Io.Queue(vaxis.Event)`. A second task turns SIGWINCH into
//! `.winsize` events through a self-pipe, so the signal handler does one
//! async-signal-safe `write` and never touches a lock (vaxis's own handler
//! takes an `Io.Mutex` inside the signal — we do not use it).
//!
//! Both tasks live in one `Io.Group`; `stop` cancels the group, which makes
//! `Io.Threaded` interrupt the blocked reads. The parse loop and the fold
//! of parsed events into the queue and into `*vaxis.Vaxis` are shared with
//! the Windows worker (`input_common.zig`).
//!
//! Terminals without mode 2048 (Terminal.app) resize via the pipe; ghostty
//! reports in-band and the pipe path is skipped once vaxis has seen one.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const common = @import("input_common.zig");

const Io = std.Io;
const posix = std.posix;

pub const Event = common.Event;
pub const Key = common.Key;
pub const keyName = common.keyName;
pub const writeKeyName = common.writeKeyName;

const Input = @This();

io: Io,
gpa: std.mem.Allocator,
vx: *vaxis.Vaxis,
/// Where key bytes come from: stdin when it is a tty, else /dev/tty.
tty: Io.File,
buffer: [common.queue_len]Event = undefined,
queue: Io.Queue(Event),
group: Io.Group = .init,
cache: vaxis.GraphemeCache = .{},
/// How this terminal spells a shifted function key when it does not use
/// xterm's modifier parameter (`legacy_fkeys.zig`); the terminal sets it
/// from `$TERM_PROGRAM` / `$TERM` before `start`.
fkeys: common.legacy_fkeys.Style = .xterm,
/// A bracketed paste being collected (`input_common.fold`): the bytes
/// between the terminal's paste fences, delivered as one `.paste`.
paste: common.PasteBuffer = .{},
winch_pipe: [2]posix.fd_t = .{ -1, -1 },
old_winch: ?posix.Sigaction = null,
started: bool = false,

/// The write end of the self-pipe, read by the signal handler.
var winch_fd: std.atomic.Value(posix.fd_t) = .init(-1);

/// Intrusive: the queue points at `self.buffer`, so `self` must not move.
pub fn init(self: *Input, io: Io, gpa: std.mem.Allocator, vx: *vaxis.Vaxis, tty: Io.File) void {
    self.* = .{
        .io = io,
        .gpa = gpa,
        .vx = vx,
        .tty = tty,
        .queue = undefined,
    };
    self.queue = .init(&self.buffer);
}

/// Spawns the reader and the resize task. Call BEFORE `queryTerminal`: the
/// probe blocks on a futex that only the reader wakes (on DA1).
pub fn start(self: *Input) !void {
    if (self.started) return;
    if (std.c.pipe(&self.winch_pipe) != 0) return error.PipeFailed;
    winch_fd.store(self.winch_pipe[1], .release);

    var act: posix.Sigaction = .{
        .handler = .{ .handler = handleWinch },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            else => posix.sigemptyset(),
        },
        .flags = 0,
    };
    var old: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.WINCH, &act, &old);
    self.old_winch = old;

    try self.group.concurrent(self.io, readerTask, .{self});
    try self.group.concurrent(self.io, winchTask, .{self});
    self.started = true;
}

/// Cancels both tasks (interrupting their blocked reads) and restores the
/// SIGWINCH disposition. Safe to call twice.
pub fn stop(self: *Input) void {
    if (!self.started) return;
    self.started = false;
    self.group.cancel(self.io);
    if (self.old_winch) |*old| posix.sigaction(posix.SIG.WINCH, old, null);
    winch_fd.store(-1, .release);
    for (self.winch_pipe) |fd| {
        if (fd >= 0) (Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(self.io);
    }
    self.winch_pipe = .{ -1, -1 };
    self.paste.deinit(self.gpa);
}

/// Called by the fold for every event it decides to deliver.
pub fn postEvent(self: *Input, event: Event) !void {
    try self.queue.putOne(self.io, event);
}

/// Blocks for the next event.
pub fn next(self: *Input) (Io.QueueClosedError || Io.Cancelable)!Event {
    return self.queue.getOne(self.io);
}

/// Drains whatever is queued without blocking. Returns the count.
pub fn drain(self: *Input, buf: []Event) (Io.QueueClosedError || Io.Cancelable)!usize {
    return self.queue.get(self.io, buf, 0);
}

pub fn getWinsize(self: *Input) !vaxis.Winsize {
    return winsizeOf(self.tty.handle);
}

pub fn winsizeOf(fd: posix.fd_t) !vaxis.Winsize {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS) return error.IoctlError;
    return .{ .rows = ws.row, .cols = ws.col, .x_pixel = ws.xpixel, .y_pixel = ws.ypixel };
}

fn handleWinch(_: posix.SIG) callconv(.c) void {
    const fd = winch_fd.load(.acquire);
    if (fd < 0) return;
    _ = std.c.write(fd, "w", 1);
}

fn readerTask(self: *Input) Io.Cancelable!void {
    // The initial size, like vaxis's loop, so the app can allocate its screen.
    if (self.getWinsize()) |ws| {
        self.postEvent(.{ .winsize = ws }) catch |err| return common.mapQueueErr(err);
    } else |_| {}

    var parser: vaxis.Parser = .{};
    var buf: [1024]u8 = undefined;
    var carry: usize = 0;
    while (true) {
        const n = self.tty.readStreaming(self.io, &.{buf[carry..]}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        if (n == 0) return;
        carry = common.parse(self, &parser, &buf, carry + n) catch |err| return common.mapQueueErr(err);
    }
}

fn winchTask(self: *Input) Io.Cancelable!void {
    const pipe_r: Io.File = .{ .handle = self.winch_pipe[0], .flags = .{ .nonblocking = false } };
    var byte: [16]u8 = undefined;
    while (true) {
        _ = pipe_r.readStreaming(self.io, &.{&byte}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        // Once the terminal reports sizes in-band the signal is redundant.
        if (self.vx.state.in_band_resize) continue;
        const ws = self.getWinsize() catch continue;
        self.postEvent(.{ .winsize = ws }) catch |err| return common.mapQueueErr(err);
    }
}
