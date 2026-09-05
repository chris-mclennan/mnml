//! One pty session: a child process on a pseudo-terminal, a reader thread
//! that moves its output into a `Ring`, and a ghostty-vt `Terminal` the UI
//! thread feeds from that ring.
//!
//! Threads and ownership
//! ---------------------
//! The reader thread is *detached*, not joined. A blocking `read(2)` on a
//! pty master only returns EOF once every fd on the slave side is closed —
//! and a grandchild that inherited the slave (an editor's `:!sh`, a stuck
//! `ssh`) can hold it open long after our child died. Joining would wedge
//! the UI thread on close. So `Session.deinit` never waits: it hangs up on
//! the child, marks the shared block `closing`, drops its reference, and
//! returns. The reader notices within one poll interval, closes the master,
//! reaps if nobody else did, and drops the last reference. Whoever releases
//! last frees the block. Everything the reader touches lives in `Shared`;
//! it never dereferences `Session`.
//!
//! Query replies (DSR, DA, XTVERSION, mode 2048 …)
//! ---------------------------------------------
//! The terminal answers those through `Handler.effects.write_pty`. The
//! callback fires in the middle of `stream.nextSlice`, while the parser is
//! mid-flight, so the bytes are only *stashed* there and written to the
//! master once the drain finishes. The handler has no userdata pointer: the
//! `Stream` is stored by value in the `Session`, and the callback walks
//! `handler → stream → Session` with `@fieldParentPtr` — the reason a
//! `Session` is always heap-allocated and never moved.
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
    /// How long the reader blocks in poll before re-checking `closing`.
    poll_interval_ms: i32 = 250,
};

pub const SpawnError = error{
    OpenptyFailed,
    ForkFailed,
    NoShell,
    ArgvEmpty,
} || Allocator.Error || std.Thread.SpawnError || Io.Cancelable;

/// A test-and-set lock for the two-line critical sections in `Shared`.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};

/// State the reader thread and the session both reach. Refcounted; see the
/// module doc for why it is not simply owned by the session.
const Shared = struct {
    ring: Ring,
    master: posix.fd_t,
    child: posix.pid_t,
    notify: Notify,
    /// Guards `notify`: the reader calls it under the lock, `Session.deinit`
    /// clears it under the lock. After `deinit` returns the callback is
    /// never entered again, whatever the reader is doing. A spinlock —
    /// both critical sections are a handful of instructions, and the
    /// reader is a raw thread with no `Io` to park on.
    notify_lock: SpinLock = .{},
    poll_interval_ms: i32,
    /// Set by `Session.deinit`. The reader exits at its next poll wakeup.
    closing: std.atomic.Value(bool) = .init(false),
    /// Set by the reader when the pty returned EOF / EIO.
    eof: std.atomic.Value(bool) = .init(false),
    /// The child has been waited for (by whichever side got there first).
    reaped: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(2), // the session + the reader

    fn release(self: *Shared, gpa: Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.ring.deinit();
        gpa.destroy(self);
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
    /// Query replies stashed by `onWritePty`, flushed at the end of `pump`.
    responses: std.ArrayList(u8) = .empty,
    shared: *Shared,
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

        var term: vt.Terminal = try .init(io, gpa, .{ .cols = opts.cols, .rows = opts.rows });
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

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) childExec(master, slave, exe, argvp, envp, cwd_z, path_z);
        _ = c.close(slave);

        // ── wire the session ──
        shared.* = .{
            .ring = ring,
            .master = master,
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
        self.stream = .init(.{ .handler = handler, .allocator = gpa });

        const th = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerMain, .{ shared, gpa });
        th.detach();
        return self;
    }

    /// Hang up on the child and let go. Returns immediately (see module doc).
    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        self.shared.disarmNotify();
        self.shared.closing.store(true, .release);
        // The child called setsid, so its pid is its process group: hang up on
        // everything it started, not just the shell.
        if (!self.shared.reaped.load(.acquire)) _ = c.kill(-self.child, .HUP);
        self.stream.deinit();
        self.term.deinit(gpa);
        self.responses.deinit(gpa);
        self.shared.release(gpa);
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Feed everything the reader has ringed into the terminal, then send
    /// any query replies back to the child. Call from the UI thread on
    /// every `.pty_readable` and once per frame. Returns true when the
    /// terminal state changed (something to render).
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
        if (self.responses.items.len > 0) {
            writeAll(self.master, self.responses.items);
            self.responses.clearRetainingCapacity();
        }
        self.reap(false);
        return fed;
    }

    /// Bytes from the user (keystrokes, paste) to the child.
    pub fn write(self: *Session, bytes: []const u8) void {
        writeAll(self.master, bytes);
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

    fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        const self = fromHandler(handler);
        // Mid-parse: stash only. `pump` flushes after the drain.
        self.responses.appendSlice(self.gpa, data) catch |err| {
            log.warn("dropping {d}-byte query reply: {t}", .{ data.len, err });
        };
    }

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
    defer shared.release(gpa);
    var fds = [_]posix.pollfd{.{ .fd = shared.master, .events = posix.POLL.IN, .revents = 0 }};
    outer: while (!shared.closing.load(.acquire)) {
        fds[0].revents = 0;
        const n = posix.poll(&fds, shared.poll_interval_ms) catch break;
        if (n == 0) continue;
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) break;
        // HUP without IN means the slave side is gone; with IN, drain first.
        if (fds[0].revents & posix.POLL.IN == 0) {
            if (fds[0].revents & posix.POLL.HUP != 0) break;
            continue;
        }
        // Back-pressure: a full ring means the UI is more than 256 KiB
        // behind; give it a moment rather than spinning.
        var dst = shared.ring.writable();
        while (dst.len == 0) {
            if (shared.closing.load(.acquire)) break :outer;
            sleepMs(1);
            dst = shared.ring.writable();
        }
        const got = posix.read(shared.master, dst) catch |err| switch (err) {
            // macOS delivers EIO (mapped to InputOutput) once the slave is
            // closed; Linux too. Either way the child is finished with us.
            error.InputOutput => break,
            error.WouldBlock => continue,
            else => break,
        };
        if (got == 0) break;
        if (shared.ring.commit(got)) shared.callNotify();
    }
    shared.eof.store(true, .release);
    _ = c.close(shared.master);
    // If the session already let go, nobody else will reap the child.
    if (shared.closing.load(.acquire) and !shared.reaped.load(.acquire)) {
        var status: c_int = 0;
        _ = c.waitpid(shared.child, &status, 0);
        shared.reaped.store(true, .release);
    }
    shared.callNotify();
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

/// Blocking write that rides out EINTR/EAGAIN. Bytes to a child that has
/// gone away are dropped silently; the reader will report EOF.
fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => {
                    sleepMs(1);
                    continue;
                },
                else => return,
            }
        }
        off += @intCast(rc);
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
    s.deinit();
    // The detached reader owns the rest; give it a beat so the leak
    // checker sees the shared block freed on this run rather than later.
    sleepMs(100);
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
    // The reader wakes within one poll interval, sees `closing`, closes
    // the master and reaches its final notify — which must be a no-op now.
    sleepMs(150);
    try testing.expectEqual(before, counter.n.load(.acquire));
}
