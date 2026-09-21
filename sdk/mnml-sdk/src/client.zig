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

    /// Close the socket and free everything. Does not send `bye` — call
    /// `bye` first for a clean exit.
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
    pub fn command(m: *Mount, id: []const u8) SendError!void {
        return m.sendMessage(.{ .command = .{ .id = id } });
    }

    /// A clean exit: the host paints its banner and stops routing input.
    pub fn bye(m: *Mount) void {
        m.sendMessage(.bye) catch {};
        m.done = true;
    }
};
