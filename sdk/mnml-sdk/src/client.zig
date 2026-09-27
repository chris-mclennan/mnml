//! Mount — the sibling's end of a mount socket. `connect` reads the
//! host's `hello`; `next` yields one host message at a time; `send`
//! ships a `Frame` (a whole screen the first time, the dirty rows after
//! that); the small senders cover title, cursor, toast, command, bye.
//!
//! Blocking, single-threaded by design: a sibling is usually
//! `while (try mount.next(arena)) |msg| { react; try mount.send(&frame); }`.
//! Sends are serialised by a mutex so a worker thread may also toast.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");
const frame_mod = @import("frame.zig");

pub const Hello = wire.Hello;
pub const HostMessage = wire.HostMessage;
pub const SiblingMessage = wire.SiblingMessage;
pub const Geometry = wire.Geometry;
pub const Frame = frame_mod.Frame;

pub const socket_env = "MNML_MOUNT_SOCKET";

pub const ConnectError = error{
    /// `MNML_MOUNT_SOCKET` is not set: not launched by mnml as a mount.
    NoSocket,
    /// The first message was not a `hello`, or the stream ended first.
    NotAHello,
    /// `hello.protocol` is one this SDK does not speak.
    UnsupportedProtocol,
    ConnectFailed,
} || Allocator.Error || wire.ReadError || wire.DecodeError;

pub const SendError = error{ Closed, WriteFailed } || Allocator.Error;

pub const Mount = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    rbuf: []u8,
    wbuf: []u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    /// Owns the strings in `hello`.
    hello_arena: std.heap.ArenaAllocator,
    hello: Hello,
    /// What `hover` last sent, so a pointer move over the same element
    /// costs nothing.
    hover_sig: u64 = 0,
    hover_sent: bool = false,
    /// The current pane size — the last `hello` or `resize`.
    geometry: Geometry,
    write_lock: Io.Mutex = .init,
    /// Set after `goodbye`, end of stream, or `bye`.
    done: bool = false,

    pub const buffer_len = 64 * 1024;

    /// Connect to `path` and read the host's `hello`.
    pub fn connect(gpa: Allocator, io: Io, path: []const u8) ConnectError!*Mount {
        if (!Io.net.has_unix_sockets) return error.ConnectFailed;
        const addr = Io.net.UnixAddress.init(path) catch return error.ConnectFailed;
        const stream = addr.connect(io) catch return error.ConnectFailed;
        errdefer stream.close(io);
        const m = try gpa.create(Mount);
        errdefer gpa.destroy(m);
        const rbuf = try gpa.alloc(u8, buffer_len);
        errdefer gpa.free(rbuf);
        const wbuf = try gpa.alloc(u8, buffer_len);
        errdefer gpa.free(wbuf);
        m.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .rbuf = rbuf,
            .wbuf = wbuf,
            .reader = .init(stream, io, rbuf),
            .writer = .init(stream, io, wbuf),
            .hello_arena = .init(gpa),
            .hello = undefined,
            .geometry = undefined,
        };
        errdefer m.hello_arena.deinit();
        const first = (try wire.receive(HostMessage, gpa, m.hello_arena.allocator(), &m.reader.interface)) orelse return error.NotAHello;
        switch (first) {
            .hello => |h| {
                if (h.protocol != wire.protocol) return error.UnsupportedProtocol;
                m.hello = h;
                m.geometry = h.geometry;
            },
            else => return error.NotAHello,
        }
        return m;
    }

    /// `connect` on `MNML_MOUNT_SOCKET`.
    pub fn connectEnv(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) ConnectError!*Mount {
        const path = env.get(socket_env) orelse return error.NoSocket;
        if (path.len == 0) return error.NoSocket;
        return connect(gpa, io, path);
    }

    /// End the stream without closing the handle: a read already in
    /// flight returns end-of-stream instead of hanging on, and the fd
    /// stays valid while it does.
    ///
    /// A pane that reads the mount on a task of its own has to call
    /// this before it stops that task and before `destroy`. `close`
    /// alone pulls the descriptor out from under a read that is still
    /// parked in the kernel, and the read then fails with `EBADF` —
    /// which a Debug build treats as a programmer bug and panics on,
    /// so the child dies at teardown and the host, which can only see
    /// the socket end, reports `[connection closed]`. A shipped build
    /// returns the error instead, which is why this only ever showed
    /// up in Debug.
    pub fn shutdown(m: *Mount) void {
        m.done = true;
        m.stream.shutdown(m.io, .both) catch {};
    }

    /// Close the socket and free everything. Does not send `bye` — call
    /// `bye` first for a clean exit, and `shutdown` first if anything
    /// else may still be reading.
    pub fn destroy(m: *Mount) void {
        m.stream.close(m.io);
        m.hello_arena.deinit();
        m.gpa.free(m.rbuf);
        m.gpa.free(m.wbuf);
        m.gpa.destroy(m);
    }

    /// The next host message, on `arena`; null once the host said
    /// goodbye or the stream ended. A `resize` updates `geometry`
    /// before it is returned.
    ///
    /// **Every slice in it lives on `arena` and nothing else.** A pane
    /// that resets that arena per iteration — both shipped ones do —
    /// must `dupe` anything it keeps: a pasted string, a `focus_item`
    /// key, a session id. See `docs/SDK.md` → "Results outlive the
    /// job"; this is the same rule with the host at the other end.
    pub fn next(m: *Mount, arena: Allocator) (wire.ReadError || wire.DecodeError)!?HostMessage {
        if (m.done) return null;
        const msg = (wire.receive(HostMessage, m.gpa, arena, &m.reader.interface) catch |err| switch (err) {
            error.ReadFailed, error.Truncated => {
                m.done = true;
                return null;
            },
            else => return err,
        }) orelse {
            m.done = true;
            return null;
        };
        switch (msg) {
            .resize => |r| m.geometry = r.geometry,
            .goodbye => m.done = true,
            else => {},
        }
        return msg;
    }

    /// One sibling message out.
    pub fn sendMessage(m: *Mount, msg: SiblingMessage) SendError!void {
        if (m.done) return error.Closed;
        const body = try wire.encode(m.gpa, msg);
        defer m.gpa.free(body);
        m.write_lock.lockUncancelable(m.io);
        defer m.write_lock.unlock(m.io);
        wire.writeMessage(&m.writer.interface, body) catch return error.WriteFailed;
    }

    /// Ship what changed in `frame`: the whole screen the first time
    /// (and after a resize), the dirty rows otherwise, nothing when
    /// nothing moved.
    pub fn send(m: *Mount, frame: *Frame) SendError!void {
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        switch (try frame.take(arena_state.allocator())) {
            .full => |rows| try m.sendMessage(.{ .frame = .{ .cells = rows } }),
            .dirty => |rows| try m.sendMessage(.{ .frame_dirty = .{ .rows = rows } }),
            .nothing => {},
        }
    }

    pub fn setTitle(m: *Mount, title: []const u8) SendError!void {
        return m.sendMessage(.{ .title = title });
    }

    pub fn setCursor(m: *Mount, cursor: ?wire.Cursor) SendError!void {
        return m.sendMessage(.{ .cursor = cursor });
    }

    pub fn toast(m: *Mount, level: wire.ToastLevel, text: []const u8) SendError!void {
        return m.sendMessage(.{ .toast = .{ .level = level, .text = text } });
    }

    /// A toast with something to DO about it — a label and either a
    /// command the host runs or a page it opens
    /// (`wire.ToastAction`). Use it when the message reports
    /// something whose only door goes with the box: a merge that
    /// takes its own row off the list, a refresh that failed and left
    /// a stale one.
    ///
    /// An action that is not one (no label, or neither/both of the two
    /// doors) is sent as a plain toast rather than a button that does
    /// nothing.
    pub fn toastWithAction(m: *Mount, level: wire.ToastLevel, text: []const u8, act: wire.ToastAction) SendError!void {
        if (!act.isValid()) return m.toast(level, text);
        return m.sendMessage(.{ .toast = .{ .level = level, .text = text, .action = act } });
    }

    /// "I started this session; keep me posted." `key` is the pane's
    /// own name for the button that started it — `sdk.pane.action`'s
    /// `watchKey` builds one — and comes back on every `session_state`
    /// line so the answer lands on the right button.
    pub fn watchSession(m: *Mount, key: []const u8, selector: wire.SessionSelector) SendError!void {
        return m.sendMessage(.{ .watch_session = .{ .key = key, .selector = selector } });
    }

    /// Ask the host to run a command by id.
    /// Name the element under the pointer for the host's info view:
    /// its title and what it does. Sent only to a host that shows it
    /// (`hello.capabilities.hover_help`), and only when it changed, so
    /// a pane may call this on every pointer move. `""` clears it.
    pub fn hover(m: *Mount, title: []const u8, body: []const u8) SendError!void {
        if (!m.hello.capabilities.hover_help) return;
        var h = std.hash.Wyhash.init(0);
        h.update(title);
        h.update("\x00");
        h.update(body);
        const sig = h.final();
        if (m.hover_sent and sig == m.hover_sig) return;
        m.hover_sig = sig;
        m.hover_sent = true;
        try m.sendMessage(.{ .hover = .{ .title = title, .body = body } });
    }

    pub fn command(m: *Mount, id: []const u8) SendError!void {
        return m.sendMessage(.{ .command = .{ .id = id } });
    }

    /// A clean exit: the host paints its banner and stops routing input.
    pub fn bye(m: *Mount) void {
        m.sendMessage(.bye) catch {};
        m.done = true;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

/// The other end: accept, say `hello`, then say nothing at all — which
/// is what a host does between keystrokes, and the state a pane's
/// reader task spends nearly all of its life in.
fn silentHost(io: Io, server: *Io.net.Server, accepted: *Io.Event) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var buf: [4096]u8 = undefined;
    var w: Io.net.Stream.Writer = .init(stream, io, &buf);
    const body = wire.encode(t.allocator, wire.HostMessage{ .hello = .{ .geometry = .{ .cols = 80, .rows = 24 } } }) catch return;
    defer t.allocator.free(body);
    wire.writeMessage(&w.interface, body) catch return;
    accepted.set(io);
    // Hold the socket open. The reader below is now parked in a read
    // that only the client's own shutdown can end.
    io.sleep(.fromMilliseconds(30_000), .awake) catch {};
}

/// Parks in `next` until the mount ends.
fn parkedReader(io: Io, m: *Mount, ended: *Io.Event, got_null: *std.atomic.Value(bool)) void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const msg = m.next(arena.allocator()) catch null;
    got_null.store(msg == null, .release);
    ended.set(io);
}

test "shutdown ends a read that is already parked, so the close after it cannot pull the descriptor away" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    // Windows: `shutdown(SD_BOTH)` does not wake a receive already
    // parked on an AF_UNIX socket (the read sat out the whole 5 s on the
    // first Windows run). What ends it there is cancelling the reading
    // task — an open Windows gap, not a behavior this test can assert.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    // The host's own rule (`bridge/host.zig` socketPath): a name that would
    // not fit a sockaddr_un (104 bytes on macOS) moves to a short /tmp
    // name. A worktree under a long path is exactly that case.
    const long = try std.fmt.allocPrint(t.allocator, "{s}/m.sock", .{dir});
    defer t.allocator.free(long);
    const path = if (long.len < Io.net.UnixAddress.max_len - 4) long else try std.fmt.allocPrint(t.allocator, "/tmp/mnml-sdk-test-{s}.sock", .{&tmp.sub_path});
    defer if (path.ptr != long.ptr) t.allocator.free(path);
    defer if (path.ptr != long.ptr) Io.Dir.cwd().deleteFile(io, path) catch {};
    const addr = try Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var hosts: Io.Group = .init;
    defer hosts.cancel(io);
    var accepted: Io.Event = .unset;
    try hosts.concurrent(io, silentHost, .{ io, &server, &accepted });

    const m = try Mount.connect(t.allocator, io, path);
    // `destroy` closes the socket. Before this, the reader below was
    // still in the kernel on that descriptor and the close failed the
    // read with `EBADF` — a programmer bug a Debug build panics on, and
    // a shipped build merely returns, which is the whole reason this
    // only ever showed up in Debug.
    defer m.destroy();

    var readers: Io.Group = .init;
    defer readers.cancel(io);
    var ended: Io.Event = .unset;
    var got_null: std.atomic.Value(bool) = .init(false);
    try readers.concurrent(io, parkedReader, .{ io, m, &ended, &got_null });

    // The reader has the hello behind it and is parked on the next
    // message, which the host will never send.
    try accepted.wait(io);
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    try t.expect(!got_null.load(.acquire));

    m.shutdown();
    // It comes back on its own, and with end-of-stream rather than an
    // error — so a pane that reads the mount on a task can join that
    // task before it closes anything.
    ended.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return error.@"the parked read never came back",
        error.Canceled => return error.SkipZigTest,
    };
    try t.expect(got_null.load(.acquire));
}
