//! One pty session: a child process on a pseudo-terminal, a reader thread
//! that moves its output into a `Ring`, and a ghostty-vt `Terminal` the UI
//! thread feeds from that ring.
//!
//! Threads and ownership
//! ---------------------
//! The reader thread is *detached*, not joined: its lifetime is the child's,
//! and a child that shrugs off SIGHUP (or a grandchild that inherited the
//! slave — an editor's `:!sh`, a stuck `ssh`) can outlive the pane by a lot.
//! What `Session.deinit` does wait for is the reader to *let go of the
//! shared block* — which is never long, because the reader only ever
//! sleeps in `poll`, and `deinit` pops that with a byte down a wake pipe.
//! `deinit` hangs up on the child, marks the block `closing`, wakes the
//! reader, waits for it to drop its reference, and then drops the last one
//! itself. Whoever releases last frees the block; after `deinit` returns
//! that is always `deinit`, so the block never outlives the session and a
//! leak-checked caller can tear down the allocator right after. The reader
//! copies out the one thing it needs afterwards (the pid, to reap a child
//! nobody else will) before its release, and touches nothing shared after
//! it. Everything the reader touches lives in `Shared`; it never
//! dereferences `Session`. The one allocation the two share — the outbox
//! buffer — is only ever grown by the UI side; the reader copies out of it.
//!
//! Input: the outbox
//! -----------------
//! Nothing on the UI thread writes to the master. `write` (keys, pastes)
//! and the terminal's query replies (DSR, DA, XTVERSION, mode 2048 …,
//! answered through `Handler.effects.write_pty` in the middle of
//! `stream.nextSlice`) all `push` onto the shared `Outbox` and return; the
//! reader thread, which already sleeps in `poll` on the master, asks for
//! POLLOUT while the box is pending and writes what the child has room
//! for. The master is non-blocking, so neither side ever waits on a child
//! that stopped reading — the UI thread would otherwise freeze on the
//! first kilobyte of a paste into `sleep`, Ctrl+C included. A push that
//! finds the box empty pops the reader's poll through the wake pipe.
//!
//! The handler has no userdata pointer: the `Stream` is stored by value in
//! the `Session`, and the callback walks `handler → stream → Session` with
//! `@fieldParentPtr` — the reason a `Session` is always heap-allocated and
//! never moved.
//!
//! TERM
//! ----
//! The emulator *is* ghostty's, so advertising `xterm-ghostty` is truthful —
//! but only if the child can find that terminfo entry, otherwise ncurses
//! programs die with "Error opening terminal". The entry ships inside
//! Ghostty.app and in ghostty's Linux packages, not in stock ncurses, so
//! `spawn` probes the usual terminfo directories: found → `TERM=xterm-ghostty`
//! with `TERMINFO_DIRS` prepended so the child resolves it; not found →
//! `TERM=xterm-256color`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vt = @import("ghostty-vt");
const Ring = @import("ring.zig").Ring;
const common = @import("common.zig");
const Outbox = @import("outbox.zig").Outbox;

const log = std.log.scoped(.pty);

// std.c declares TIOCGWINSZ for macOS but neither TIOCSCTTY nor TIOCSWINSZ;
// Linux has all three under std.c.T. These are the BSD values shared by
// every Apple platform.
const T = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const IOCSCTTY: c_int = 0x20007461;
        pub const IOCGWINSZ: c_int = 0x40087468;
        pub const IOCSWINSZ: c_int = @bitCast(@as(c_uint, 0x80087467));
    },
    else => struct {
        pub const IOCSCTTY: c_int = @intCast(c.T.IOCSCTTY);
        pub const IOCGWINSZ: c_int = @intCast(c.T.IOCGWINSZ);
        pub const IOCSWINSZ: c_int = @intCast(c.T.IOCSWINSZ);
    },
};

// Zig 0.16's std declares neither openpty nor the posix_openpt family, so
// this is our own extern. It lives in libc on macOS and glibc ≥ 2.34; older
// glibc keeps it in libutil (build.zig can add `linkSystemLibrary("util")`
// if a cross target ever needs it).
extern "c" fn tcflush(fd: posix.fd_t, queue: c_int) c_int;
extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;
/// Both queues — the BSD and Linux values differ.
const TCIOFLUSH: c_int = if (builtin.os.tag.isDarwin()) 3 else 2;

extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*:0]u8,
    termp: ?*const c.termios,
    winp: ?*const posix.winsize,
) c_int;

/// The reader's wakeup and the child's end, shared with the Windows
/// backend (`common.zig`, where the callback contract is spelled out).
/// Here the call is made under `Shared.notify_lock`.
pub const Notify = common.Notify;
pub const Exit = common.Exit;

pub const Options = struct {
    cols: u16,
    rows: u16,
    /// The parent's environment; the child gets a copy with TERM et al.
    /// overlaid. Not modified.
    env: *const std.process.Environ.Map,
    /// Program to run. `null` → the user's `$SHELL` as a login shell
    /// (argv0 prefixed with `-`, the POSIX convention every shell honours).
    argv: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    notify: Notify = .none,
    /// Ring size; must be a power of two.
    ring_capacity: usize = Ring.default_capacity,
    /// Scrollback kept above the screen, in lines.
    scrollback_lines: usize = common.default_scrollback_lines,
    /// Take the child's clipboard writes (OSC 52 and the kitty protocol)
    /// for `takeClipboard`. Off: they are dropped, as before.
    clipboard_write: bool = false,
    /// How long the reader blocks in poll before re-checking `closing` on
    /// its own. `deinit` wakes it directly; this is the fallback cadence.
    poll_interval_ms: i32 = 250,
};

pub const SpawnError = error{
    OpenptyFailed,
    PipeFailed,
    ForkFailed,
    NoShell,
    ArgvEmpty,
} || Allocator.Error || std.Thread.SpawnError || Io.Cancelable;

const SpinLock = common.SpinLock;

/// State the reader thread and the session both reach. Refcounted; see the
/// module doc for why it is not simply owned by the session.
const Shared = struct {
    ring: Ring,
    /// What the session wants written to the child; the reader drains it.
    outbox: Outbox = .{},
    /// Non-blocking. Closed with the block, not at EOF: the session may
    /// still ioctl it after the child is gone, and an fd closed early
    /// could be reused under it.
    master: posix.fd_t,
    /// The pipe that pops the reader's poll: a byte from `deinit`
    /// (`closing` is set), or from a push onto an empty outbox. Both ends
    /// non-blocking — a full pipe already means the reader has a wakeup
    /// waiting. `[0]` is polled and drained by the reader. Closed with
    /// the block.
    wake: [2]posix.fd_t,
    child: posix.pid_t,
    notify: Notify,
    /// Guards `notify`: the reader calls it under the lock, `Session.deinit`
    /// clears it under the lock. After `deinit` returns the callback is
    /// never entered again, whatever the reader is doing. A spinlock —
    /// both critical sections are a handful of instructions, and the
    /// reader is a raw thread with no `Io` to park on.
    notify_lock: SpinLock = .{},
    poll_interval_ms: i32,
    /// Set by `Session.deinit`, which then wakes the reader; the reader
    /// exits its loop as soon as it sees this.
    closing: std.atomic.Value(bool) = .init(false),
    /// Set by the reader when the pty returned EOF / EIO.
    eof: std.atomic.Value(bool) = .init(false),
    /// The claim on `waitpid`: whoever swaps this from false to true is
    /// the one that reaps the child, so the pid is never waited for twice
    /// (a second wait could land on a recycled pid — another pane's child).
    /// The session claims it in `reap` while it lives; on close, the reader
    /// claims it if the session never did — that wait may block, and it
    /// happens after the reader's release, on a copied pid.
    reaped: std.atomic.Value(bool) = .init(false),
    /// The session + the reader. `deinit` waits for the reader's release
    /// before its own, so the block is always freed by `deinit`, before
    /// it returns — the last touch the reader makes is its `fetchSub`.
    refs: std.atomic.Value(u32) = .init(2),

    fn release(self: *Shared, gpa: Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = c.close(self.master);
        _ = c.close(self.wake[0]);
        _ = c.close(self.wake[1]);
        self.ring.deinit();
        self.outbox.deinit(gpa);
        gpa.destroy(self);
    }

    /// Session side: pop the reader's poll. One byte is enough; a full
    /// pipe (EAGAIN) means a wakeup is already waiting, so it never blocks.
    fn wakeReader(self: *Shared) void {
        const byte = [_]u8{0};
        _ = c.write(self.wake[1], &byte, 1);
    }

    /// Session side: block until the reader has dropped its reference.
    /// Bounded by the reader's wake-up latency — nothing on its way out
    /// blocks — so a short spin, then 1 ms naps.
    fn awaitReader(self: *Shared) void {
        var spins: u32 = 0;
        while (self.refs.load(.acquire) > 1) : (spins += 1) {
            if (spins < 256) std.atomic.spinLoopHint() else sleepMs(1);
        }
    }

    /// Reader side: fire the callback unless the session has let go.
    fn callNotify(self: *Shared) void {
        self.notify_lock.lock();
        defer self.notify_lock.unlock();
        self.notify.call();
    }

    /// Session side: no callback fires after this returns.
    fn disarmNotify(self: *Shared) void {
        self.notify_lock.lock();
        defer self.notify_lock.unlock();
        self.notify = .none;
    }
};

pub const Session = struct {
    gpa: Allocator,
    term: vt.Terminal,
    /// By value: the write_pty callback recovers `Session` from
    /// `&stream.handler` via `@fieldParentPtr`. Never move a Session.
    stream: vt.TerminalStream,
    shared: *Shared,
    /// The child's last clipboard write, until `takeClipboard`.
    clipboard: ?[]u8 = null,
    master: posix.fd_t,
    child: posix.pid_t,
    exit: ?Exit = null,
    cols: u16,
    rows: u16,

    pub fn spawn(gpa: Allocator, io: Io, opts: Options) SpawnError!*Session {
        // ── everything that allocates happens here, before fork ──
        var env = try opts.env.clone(gpa);
        defer env.deinit();
        try applyTerm(gpa, &env);
        const envp = try env.createPosixBlock(gpa, .{});
        defer envp.deinit(gpa);

        var argv_buf: std.ArrayList(?[*:0]const u8) = .empty;
        defer {
            for (argv_buf.items) |a| if (a) |p| gpa.free(std.mem.span(p));
            argv_buf.deinit(gpa);
        }
        var exe: [:0]const u8 = undefined;
        if (opts.argv) |argv| {
            if (argv.len == 0) return error.ArgvEmpty;
            for (argv) |a| try argv_buf.append(gpa, try gpa.dupeZ(u8, a));
            exe = std.mem.span(argv_buf.items[0].?);
        } else {
            const shell = env.get("SHELL") orelse defaultShell();
            if (shell.len == 0) return error.NoShell;
            const base = std.fs.path.basename(shell);
            const argv0 = try std.fmt.allocPrintSentinel(gpa, "-{s}", .{base}, 0);
            try argv_buf.append(gpa, argv0);
            exe = try gpa.dupeZ(u8, shell);
        }
        defer if (opts.argv == null) gpa.free(exe);
        try argv_buf.append(gpa, null);
        const argvp: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);

        const cwd_z: ?[:0]const u8 = if (opts.cwd) |d| try gpa.dupeZ(u8, d) else null;
        defer if (cwd_z) |d| gpa.free(d);
        const path_z: ?[:0]const u8 = if (env.get("PATH")) |p| try gpa.dupeZ(u8, p) else null;
        defer if (path_z) |p| gpa.free(p);

        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        var ring = try Ring.init(opts.ring_capacity);
        errdefer ring.deinit();

        var term: vt.Terminal = try .init(io, gpa, common.terminalOptions(opts.cols, opts.rows, opts.scrollback_lines));
        errdefer term.deinit(gpa);

        // ── pty + child ──
        const ws: posix.winsize = .{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
        var master: posix.fd_t = undefined;
        var slave: posix.fd_t = undefined;
        if (openpty(&master, &slave, null, null, &ws) < 0) return error.OpenptyFailed;
        errdefer {
            _ = c.close(master);
            _ = c.close(slave);
        }
        setCloexec(master);
        var wake: [2]posix.fd_t = undefined;
        if (c.pipe(&wake) < 0) return error.PipeFailed;
        errdefer {
            _ = c.close(wake[0]);
            _ = c.close(wake[1]);
        }
        setCloexec(wake[0]);
        setCloexec(wake[1]);
        setNonblock(wake[0]);
        setNonblock(wake[1]);

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) childExec(master, slave, exe, argvp, envp, cwd_z, path_z);
        _ = c.close(slave);
        // After the fork: the child's stdio is the slave, and must stay
        // blocking; only our end is polled.
        setNonblock(master);

        // ── wire the session ──
        shared.* = .{
            .ring = ring,
            .master = master,
            .wake = wake,
            .child = pid,
            .notify = opts.notify,
            .poll_interval_ms = opts.poll_interval_ms,
        };
        self.* = .{
            .gpa = gpa,
            .term = term,
            .stream = undefined,
            .shared = shared,
            .master = master,
            .child = pid,
            .cols = opts.cols,
            .rows = opts.rows,
        };
        var handler = self.term.vtHandler();
        handler.effects = .readonly;
        handler.effects.write_pty = onWritePty;
        if (opts.clipboard_write) handler.effects.clipboard_write = onClipboardWrite;
        self.stream = .init(.{ .handler = handler, .allocator = gpa });

        // 1 MiB, not the 256 KiB this once asked for: glibc rejects a
        // thread stack smaller than its static TLS block plus a few pages,
        // and on Debian 13 (both x86_64 and aarch64) that floor sits
        // between 256 KiB and 320 KiB — well above `PTHREAD_STACK_MIN`.
        // `pthread_create` then returns EINVAL, which std treats as
        // `unreachable`, so every pty pane aborted the process on Linux.
        // The reader needs a few KiB; the number only has to clear glibc.
        const th = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, readerMain, .{ shared, gpa });
        th.detach();
        return self;
    }

    /// Hang up on the child and let go. Waits only for the reader to drop
    /// the shared block — microseconds — never for the child (see module
    /// doc). When this returns nothing of the session is left allocated.
    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        const shared = self.shared;
        shared.disarmNotify();
        shared.closing.store(true, .release);
        // The child called setsid, so its pid is its process group: hang up
        // on everything it started, not just the shell. `exit` is this
        // thread's own knowledge of a wait that already happened; the
        // reader's claim on the reap is not consulted, so it can never
        // talk us out of the hangup.
        if (self.exit == null) _ = c.kill(-self.child, .HUP);
        shared.wakeReader();
        self.stream.deinit();
        self.term.deinit(gpa);
        if (self.clipboard) |text| gpa.free(text);
        shared.awaitReader();
        // The reader is gone from the block. If neither side has claimed
        // the reap — the reader reached EOF on its own before `closing`
        // was set — take it now, without blocking: a child that closed the
        // pty has almost always exited; one that has not was just hung up
        // on and is left to init.
        if (!shared.reaped.swap(true, .acq_rel)) {
            var status: c_int = 0;
            _ = c.waitpid(self.child, &status, c.W.NOHANG);
        }
        shared.release(gpa);
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Feed everything the reader has ringed into the terminal (its query
    /// replies go onto the outbox as they are parsed). Call from the UI
    /// thread on every `.pty_readable` and once per frame. Returns true
    /// when the terminal state changed (something to render).
    pub fn pump(self: *Session) bool {
        const ring = &self.shared.ring;
        ring.beginDrain();
        var fed = false;
        while (true) {
            const chunk = ring.readableSlice();
            if (chunk.len == 0) break;
            self.stream.nextSlice(chunk);
            ring.consume(chunk.len);
            fed = true;
        }
        self.reap(false);
        return fed;
    }

    /// Bytes from the user (keystrokes, paste) to the child. Queued, never
    /// written here: returns at once whether or not the child is reading.
    /// Bytes to a child that has gone away are dropped.
    pub fn write(self: *Session, bytes: []const u8) void {
        self.queue(bytes);
    }

    /// Ctrl+C. A ^C queued behind input the child is not reading would
    /// never reach the line discipline — the tty's input queue is full —
    /// so while input is pending this does what the line discipline does
    /// on its interrupt character: drop the queued input (ours, and the
    /// tty's queues unless `NOFLSH`) and signal the foreground process
    /// group. With nothing pending, or a child that has `ISIG` off (vim,
    /// a raw-mode TUI), the byte is simply sent.
    pub fn interrupt(self: *Session) void {
        if (self.shared.outbox.pending() > 0 and !self.eof()) {
            self.shared.outbox.discard();
            var tio: c.termios = undefined;
            if (c.tcgetattr(self.master, &tio) == 0 and tio.lflag.ISIG and
                tio.cc[@intFromEnum(posix.V.INTR)] == 0x03)
            {
                if (!tio.lflag.NOFLSH) _ = tcflush(self.master, TCIOFLUSH);
                const pgrp = tcgetpgrp(self.master);
                if (pgrp > 0) _ = c.kill(-pgrp, .INT);
                return;
            }
        }
        self.queue("\x03");
    }

    /// Bytes still waiting for the child to read them.
    pub fn pendingInput(self: *Session) usize {
        return self.shared.outbox.pending();
    }

    fn queue(self: *Session, bytes: []const u8) void {
        if (self.eof()) return;
        const edge = self.shared.outbox.push(self.gpa, bytes) catch |err| {
            log.warn("dropping {d} bytes of input: {t}", .{ bytes.len, err });
            return;
        };
        if (edge) self.shared.wakeReader();
    }

    /// Resize both the pty (SIGWINCH to the child) and the terminal grid.
    /// No-op when the size is unchanged, so callers may spam it.
    pub fn resize(self: *Session, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return error.InvalidValue;
        if (cols == self.cols and rows == self.rows) return;
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        // After EOF the reader has closed the master; only the grid is left to size.
        if (!self.eof() and c.ioctl(self.master, T.IOCSWINSZ, @intFromPtr(&ws)) < 0)
            log.warn("TIOCSWINSZ failed: {t}", .{c.errno(-1)});
        try self.stream.handler.resize(.{ .cols = cols, .rows = rows });
        self.cols = cols;
        self.rows = rows;
    }

    /// The child's exit, once known. `null` while it is still running or
    /// its output has not yet drained.
    pub fn exited(self: *Session) ?Exit {
        if (self.exit == null) self.reap(false);
        return self.exit;
    }

    /// True once the pty reported EOF: the child (and anyone it handed the
    /// slave to) has gone away.
    pub fn eof(self: *const Session) bool {
        return self.shared.eof.load(.acquire);
    }

    /// The Session's stream is the only writer of `term`; readers of the
    /// grid (`grid.zig`) go through here.
    pub fn terminal(self: *Session) *vt.Terminal {
        return &self.term;
    }

    /// Recover the Session that owns `handler` — see the struct field doc.
    fn fromHandler(handler: *vt.TerminalStream.Handler) *Session {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// The text the child last copied, gpa-owned — the caller frees it.
    /// Null when it copied nothing since the last call.
    pub fn takeClipboard(self: *Session) ?[]u8 {
        const text = self.clipboard orelse return null;
        self.clipboard = null;
        return text;
    }

    fn onClipboardWrite(handler: *vt.TerminalStream.Handler, w: vt.clipboard.Write) void {
        const self = fromHandler(handler);
        const text = common.clipboardText(w) orelse return w.reply(.unsupported);
        const copy = self.gpa.dupe(u8, text) catch return w.reply(.io_error);
        if (self.clipboard) |old| self.gpa.free(old);
        self.clipboard = copy;
        w.reply(.{ .success = .{} });
    }

    fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        // Mid-parse is fine: a push only copies.
        fromHandler(handler).queue(data);
    }

    /// The session's side of the reap. Only the session waits while it
    /// lives (the reader claims the pid only once `closing` is set), so a
    /// successful wait here is the one that sets `exit`.
    fn reap(self: *Session, block: bool) void {
        if (self.exit != null) return;
        if (self.shared.reaped.load(.acquire)) return;
        var status: c_int = 0;
        const rc = c.waitpid(self.child, &status, if (block) 0 else c.W.NOHANG);
        if (rc != self.child) return;
        self.shared.reaped.store(true, .release);
        self.exit = exitFromStatus(@bitCast(status));
    }
};

fn exitFromStatus(status: u32) Exit {
    if (c.W.IFEXITED(status)) return .{ .code = c.W.EXITSTATUS(status) };
    if (c.W.IFSIGNALED(status)) return .{ .signal = @intFromEnum(c.W.TERMSIG(status)) };
    return .{ .code = 255 };
}

// ── reader thread ───────────────────────────────────────────────────

fn readerMain(shared: *Shared, gpa: Allocator) void {
    var fds = [_]posix.pollfd{
        .{ .fd = shared.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = shared.wake[0], .events = posix.POLL.IN, .revents = 0 },
    };
    // What one drain step copies out of the outbox; the tty takes about
    // a kilobyte at a time anyway.
    var chunk: [16 * 1024]u8 = undefined;
    while (!shared.closing.load(.acquire)) {
        // Back-pressure: a full ring means the UI is more than 256 KiB
        // behind. Stop asking for input and look again in a moment; the
        // outbox keeps draining meanwhile.
        const room = shared.ring.writable().len > 0;
        const out = shared.outbox.pending() > 0;
        const want_in: i16 = if (room) posix.POLL.IN else 0;
        const want_out: i16 = if (out) posix.POLL.OUT else 0;
        fds[0].events = want_in | want_out;
        fds[0].revents = 0;
        fds[1].revents = 0;
        const n = posix.poll(&fds, if (room) shared.poll_interval_ms else 1) catch break;
        if (fds[1].revents != 0) drainWake(shared.wake[0]);
        // `deinit`'s byte: there is no reason to touch the pty again.
        if (shared.closing.load(.acquire)) break;
        if (n == 0) continue;
        const rev = fds[0].revents;
        if (rev & (posix.POLL.ERR | posix.POLL.NVAL) != 0) break;
        if (rev & posix.POLL.OUT != 0) flushOutbox(shared, &chunk);
        if (rev & posix.POLL.IN != 0) {
            const got = posix.read(shared.master, shared.ring.writable()) catch |err| switch (err) {
                // macOS delivers EIO (mapped to InputOutput) once the slave is
                // closed; Linux too. Either way the child is finished with us.
                error.InputOutput => break,
                error.WouldBlock => continue,
                else => break,
            };
            if (got == 0) break;
            if (shared.ring.commit(got)) shared.callNotify();
            continue;
        }
        // HUP without IN means the slave side is gone — but only when IN
        // was asked for: with the ring full, output may still be waiting.
        if (rev & posix.POLL.HUP != 0) {
            if (room) break;
            sleepMs(1);
        }
    }
    shared.outbox.close();
    shared.eof.store(true, .release);
    shared.callNotify();
    // Everything needed after the release is decided and copied out here.
    // If the session has let go, nobody else will wait for the child:
    // claim the reap unless the session already did. (A session still
    // alive reaps in `pump`, and must — it is where `exited()` comes from.)
    const child = shared.child;
    const reap = shared.closing.load(.acquire) and !shared.reaped.swap(true, .acq_rel);
    shared.release(gpa);
    // From here on `shared` may be freed: `deinit` was waiting on exactly
    // that release. The child was hung up on; a wait that blocks anyway
    // (SIGHUP ignored, a grandchild holding the pty) wedges only this
    // thread, which is what a detached reader is for.
    if (reap) {
        var status: c_int = 0;
        _ = c.waitpid(child, &status, 0);
    }
}

// ── child side ──────────────────────────────────────────────────────

/// Runs in the forked child: no allocation, no logging, ends in exec or
/// `_exit`. Mirrors the sequence ghostty's Pty.childPreExec + Command.exec
/// perform: default signals → new session → controlling tty → stdio → exec.
fn childExec(
    master: posix.fd_t,
    slave: posix.fd_t,
    exe: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: std.process.Environ.PosixBlock,
    cwd: ?[:0]const u8,
    path: ?[:0]const u8,
) noreturn {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    inline for (.{ .ABRT, .ALRM, .BUS, .CHLD, .FPE, .HUP, .ILL, .INT, .PIPE, .SEGV, .TRAP, .TERM, .QUIT, .WINCH }) |sig| {
        posix.sigaction(@field(posix.SIG, @tagName(sig)), &sa, null);
    }
    var mask = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &mask, null);

    if (c.setsid() < 0) c._exit(126);
    if (c.ioctl(slave, T.IOCSCTTY, @as(c_ulong, 0)) < 0) c._exit(126);
    if (c.dup2(slave, 0) < 0 or c.dup2(slave, 1) < 0 or c.dup2(slave, 2) < 0) c._exit(126);
    if (slave > 2) _ = c.close(slave);
    _ = c.close(master);
    if (cwd) |d| _ = c.chdir(d.ptr);

    const env_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(envp.slice.ptr);
    // A bare name is looked up on the child's PATH; execve itself does
    // not. Stack buffer only — no allocation after fork.
    if (std.mem.indexOfScalar(u8, exe, '/') == null) {
        if (path) |p| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            var it = std.mem.splitScalar(u8, p, ':');
            while (it.next()) |dir| {
                if (dir.len == 0) continue;
                const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, exe }) catch continue;
                _ = c.execve(full.ptr, argv, env_ptr);
                // ENOENT / ENOTDIR / EACCES: try the next directory.
            }
        }
        c._exit(127);
    }
    _ = c.execve(exe.ptr, argv, env_ptr);
    c._exit(127);
}

// ── helpers ─────────────────────────────────────────────────────────

fn defaultShell() []const u8 {
    return "/bin/sh";
}

/// poll(2) with no descriptors is a portable sleep that needs no `Io`.
fn sleepMs(ms: i32) void {
    var none: [0]posix.pollfd = .{};
    _ = posix.poll(&none, ms) catch {};
}

fn setCloexec(fd: posix.fd_t) void {
    const flags = c.fcntl(fd, posix.F.GETFD);
    if (flags < 0) return;
    _ = c.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}

fn setNonblock(fd: posix.fd_t) void {
    const flags = c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return;
    _ = c.fcntl(fd, posix.F.SETFL, flags | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })));
}

/// Reader side: empty the wake pipe (non-blocking) so the next poll
/// sleeps again.
fn drainWake(fd: posix.fd_t) void {
    var sink: [64]u8 = undefined;
    while (c.read(fd, &sink, sink.len) > 0) {}
}

/// Reader side: write what the child has room for, never waiting. A
/// write the kernel refuses for good (the slave is gone) closes the box,
/// so nothing keeps asking for POLLOUT on a dead pty.
fn flushOutbox(shared: *Shared, chunk: []u8) void {
    while (true) {
        const taken = shared.outbox.peek(chunk);
        if (taken.n == 0) return;
        const rc = c.write(shared.master, chunk.ptr, taken.n);
        if (rc < 0) switch (c.errno(rc)) {
            .INTR => continue,
            .AGAIN => return,
            else => {
                shared.outbox.close();
                return;
            },
        };
        const wrote: usize = @intCast(rc);
        shared.outbox.consume(wrote, taken.gen);
        if (wrote < taken.n) return;
    }
}

/// The terminfo directories where an `xterm-ghostty` entry may live, most
/// specific first. Ghostty.app bundles one; ghostty's Linux packages
/// install into the system database.
const terminfo_candidates = [_][]const u8{
    "/Applications/Ghostty.app/Contents/Resources/terminfo",
    "/opt/homebrew/share/terminfo",
    "/usr/local/share/terminfo",
    "/usr/share/terminfo",
    "/etc/terminfo",
    "/lib/terminfo",
};

/// Find a directory containing the `xterm-ghostty` terminfo entry. Checks
/// `$TERMINFO`, then `$TERMINFO_DIRS`, then the well-known locations.
/// Returns a slice into `env` or into `terminfo_candidates`.
pub fn findGhosttyTerminfo(env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("TERMINFO")) |d| if (hasGhosttyEntry(d)) return d;
    if (env.get("TERMINFO_DIRS")) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |d| if (d.len > 0 and hasGhosttyEntry(d)) return d;
    }
    for (terminfo_candidates) |d| if (hasGhosttyEntry(d)) return d;
    return null;
}

fn hasGhosttyEntry(dir: []const u8) bool {
    // ncurses stores entries under the first letter; macOS's terminfo uses
    // the hex code of that letter ("78" for 'x'). Check both.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "x", "78" }) |sub| {
        const p = std.fmt.bufPrintZ(&buf, "{s}/{s}/xterm-ghostty", .{ dir, sub }) catch continue;
        if (c.access(p.ptr, c.F_OK) == 0) return true;
    }
    return false;
}

/// Overlay the terminal identity on the child's environment.
fn applyTerm(gpa: Allocator, env: *std.process.Environ.Map) Allocator.Error!void {
    if (findGhosttyTerminfo(env)) |dir| {
        try env.put("TERM", "xterm-ghostty");
        // Prepend so the entry resolves even when the system database
        // lacks it; keep the inherited list (or ncurses' defaults) after.
        const inherited = env.get("TERMINFO_DIRS") orelse "/usr/share/terminfo:/etc/terminfo:/lib/terminfo";
        const joined = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ dir, inherited });
        defer gpa.free(joined);
        try env.put("TERMINFO_DIRS", joined);
    } else {
        try env.put("TERM", "xterm-256color");
    }
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "mnml-zig");
    // A shell inherits these from the parent terminal and they would lie.
    _ = env.swapRemove("TERM_PROGRAM_VERSION");
    _ = env.swapRemove("GHOSTTY_RESOURCES_DIR");
    _ = env.swapRemove("GHOSTTY_BIN_DIR");
}

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// Pump until the child has exited and the pty has drained, or `ms` pass.
fn pumpUntilExit(s: *Session, ms: u32) ?Exit {
    var waited: u32 = 0;
    while (waited < ms) {
        _ = s.pump();
        if (s.eof()) {
            _ = s.pump(); // whatever landed between the last drain and EOF
            s.reap(true);
            return s.exit;
        }
        sleepMs(5);
        waited += 5;
    }
    return null;
}

fn testEnv() !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", "/tmp");
    return env;
}

test "a short command's output reaches the terminal and its exit is reaped" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 4,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "printf 'hi from the pty\\n'; exit 3" },
    });
    defer s.deinit();

    const exit = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;
    try testing.expectEqual(Exit{ .code = 3 }, exit);
    try testing.expectEqual(exit, s.exited().?);

    const text = try s.terminal().plainString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hi from the pty") != null);
}

test "the child sees the TERM the probe chose and a truecolor COLORTERM" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 60,
        .rows = 4,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "printf '%s|%s' \"$TERM\" \"$COLORTERM\"" },
    });
    defer s.deinit();
    _ = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;

    const text = try s.terminal().plainString(testing.allocator);
    defer testing.allocator.free(text);
    const expected = if (findGhosttyTerminfo(&env) != null) "xterm-ghostty|truecolor" else "xterm-256color|truecolor";
    try testing.expect(std.mem.indexOf(u8, text, expected) != null);
}

test "a cursor position report is answered back through the pty" {
    // The child asks DSR 6 and reads the six-byte reply ESC [ 1 ; 1 R in raw
    // mode, then prints it as octal so the assertion is on visible text.
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 60,
        .rows = 4,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -c" },
    });
    defer s.deinit();
    _ = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;

    const text = try s.terminal().plainString(testing.allocator);
    defer testing.allocator.free(text);
    // od prints "033   [   1   ;   1   R" — squeeze the spacing.
    var squeezed: std.ArrayList(u8) = .empty;
    defer squeezed.deinit(testing.allocator);
    var it = std.mem.tokenizeAny(u8, text, " \n\r");
    while (it.next()) |tok| try squeezed.appendSlice(testing.allocator, tok);
    try testing.expect(std.mem.indexOf(u8, squeezed.items, "033[1;1R") != null);
}

test "resize reaches the child as a new window size" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 10,
        .env = &env,
        // Wait for the resize to land, then report what the tty says.
        .argv = &.{ "/bin/sh", "-c", "sleep 0.3; stty size" },
    });
    defer s.deinit();
    try s.resize(100, 25);
    try testing.expectEqual(@as(u16, 100), s.terminal().cols);
    try testing.expectEqual(@as(u16, 25), s.terminal().rows);
    _ = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;

    const text = try s.terminal().plainString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "25 100") != null);
}

test "a bare program name is resolved on the child's PATH" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 4,
        .env = &env,
        .argv = &.{ "sh", "-c", "echo found-on-path" },
    });
    defer s.deinit();
    const exit = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;
    try testing.expectEqual(Exit{ .code = 0 }, exit);
    const text = try s.terminal().plainString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "found-on-path") != null);
}

test "deinit while the child is still running does not hang" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 4,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .poll_interval_ms = 20,
    });
    _ = s.pump();
    // The reader is mid-poll; `deinit` pops it and takes the block back
    // before returning, so the leak check that follows this test sees it
    // freed. No beat needed.
    s.deinit();
}

test "no notify fires after deinit — the reader's EOF wakeup is disarmed under the lock" {
    var env = try testEnv();
    defer env.deinit();
    const Counter = struct {
        n: std.atomic.Value(u32) = .init(0),
        fn bump(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.n.fetchAdd(1, .acq_rel);
        }
    };
    var counter: Counter = .{};
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 4,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "echo one; sleep 30" },
        .poll_interval_ms = 20,
        .notify = .{ .ctx = &counter, .fn_ptr = &Counter.bump },
    });
    // The first line's wakeup lands.
    var waited: u32 = 0;
    while (counter.n.load(.acquire) == 0 and waited < 5000) : (waited += 5) sleepMs(5);
    try testing.expect(counter.n.load(.acquire) >= 1);
    const before = counter.n.load(.acquire);
    s.deinit();
    // By the time `deinit` returned the reader had seen `closing`, made
    // its final notify — a no-op, disarmed — and let go of the block.
    try testing.expectEqual(before, counter.n.load(.acquire));
}

test "stress: the reader has let go of the block by the time deinit returns" {
    // The shape every leak-checked caller has: an allocator that is torn
    // down the moment `deinit` returns. Nothing may still be outstanding
    // on it — not the block, and not a reader about to free the block
    // through an allocator that no longer exists. Even iterations close
    // the session before the reader has even polled; odd ones let the
    // child exit and the reader reach EOF first.
    var env = try testEnv();
    defer env.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var dbg: std.heap.DebugAllocator(.{}) = .{};
        const s = try Session.spawn(dbg.allocator(), testing.io, .{
            .cols = 20,
            .rows = 2,
            .env = &env,
            .argv = &.{"true"},
            .poll_interval_ms = 20,
        });
        if (i % 2 == 1) _ = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;
        s.deinit();
        try testing.expectEqual(std.heap.Check.ok, dbg.deinit());
    }
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

test "1 MiB written to a child that never reads returns at once; the child lives and an interrupt still reaches it" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 4,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .poll_interval_ms = 20,
    });
    defer s.deinit();
    const payload = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');
    for (0..payload.len / 64) |i| payload[i * 64 + 63] = '\n';

    const t0 = nowMs(testing.io);
    s.write(payload);
    const took = nowMs(testing.io) - t0;
    // A blocking write would sit here until `sleep` exits, 30 s from now.
    try testing.expect(took < 500);
    sleepMs(200);
    _ = s.pump();
    try testing.expectEqual(@as(?Exit, null), s.exited());
    // The tty took its kilobyte; the rest waits in the outbox.
    try testing.expect(s.pendingInput() > 0);

    // Ctrl+C: behind a full tty queue the ^C byte could never be read,
    // so the interrupt is delivered as the line discipline would.
    s.interrupt();
    const exit = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;
    try testing.expect(exit == .signal or exit.code != 0);
}

test "type-ahead a child reads later arrives whole and in order" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 60,
        .rows = 4,
        .env = &env,
        // Not reading for a while, then all of it: 256 KiB and a marker.
        .argv = &.{ "/bin/sh", "-c", "stty -echo -icanon min 1; echo ready; sleep 0.5; head -c 262150 | tail -c 6; echo; echo got" },
        .poll_interval_ms = 20,
    });
    defer s.deinit();
    // Raw input first, or the tty's canonical line limit eats the bytes.
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 10) {
        _ = s.pump();
        const t = try s.terminal().plainString(testing.allocator);
        defer testing.allocator.free(t);
        if (std.mem.indexOf(u8, t, "ready") != null) break;
        sleepMs(10);
    }
    const payload = try testing.allocator.alloc(u8, 262144);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    const t0 = nowMs(testing.io);
    s.write(payload);
    s.write("<END>!");
    try testing.expect(nowMs(testing.io) - t0 < 500);
    const exit = pumpUntilExit(s, 10_000) orelse return error.ChildDidNotExit;
    try testing.expectEqual(Exit{ .code = 0 }, exit);
    const text = try s.terminal().plainString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "<END>!") != null);
    try testing.expect(std.mem.indexOf(u8, text, "got") != null);
}

test "the scrollback keeps what the line limit says: 3000 lines of seq, line 1 still at the top" {
    var env = try testEnv();
    defer env.deinit();
    const s = try Session.spawn(testing.allocator, testing.io, .{
        .cols = 40,
        .rows = 10,
        .env = &env,
        .argv = &.{ "/bin/sh", "-c", "seq 1 3000" },
    });
    defer s.deinit();
    _ = pumpUntilExit(s, 10_000) orelse return error.ChildDidNotExit;
    s.terminal().scrollViewport(.top);
    var g: @import("grid.zig").Grid = .{};
    defer g.deinit(testing.allocator);
    try g.update(testing.allocator, s.terminal());
    try testing.expectEqual(@as(u21, '1'), g.cell(0, 0).cp);
    try testing.expect(g.cell(1, 0).isEmpty());
    try testing.expectEqual(@as(u21, '2'), g.cell(0, 1).cp);
}

test "a child's OSC 52 copy is taken when clipboard writes are on, dropped when off" {
    var env = try testEnv();
    defer env.deinit();
    for ([_]bool{ true, false }) |on| {
        const s = try Session.spawn(testing.allocator, testing.io, .{
            .cols = 40,
            .rows = 4,
            .env = &env,
            // "osc52-payload", base64.
            .argv = &.{ "/bin/sh", "-c", "printf '\\033]52;c;b3NjNTItcGF5bG9hZA==\\007'" },
            .clipboard_write = on,
        });
        defer s.deinit();
        _ = pumpUntilExit(s, 5000) orelse return error.ChildDidNotExit;
        const got = s.takeClipboard();
        defer if (got) |g| testing.allocator.free(g);
        if (on) {
            try testing.expectEqualStrings("osc52-payload", got.?);
            try testing.expect(s.takeClipboard() == null);
        } else try testing.expect(got == null);
    }
}
