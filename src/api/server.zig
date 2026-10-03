//! The API socket's listener (`docs/research/api-design.md` §4.1, §8).
//!
//! An accept task parked in `accept`, and one reader task per connection
//! that reads a line (one JSON-RPC object, NDJSON), hands it to the UI
//! thread as an `.api` event, and waits for the reply the UI thread gives
//! back before it reads the next — so one connection is answered in
//! order, and the UI thread never touches a socket. A request held for
//! the person (`app/ipc_gate.zig`) keeps its connection waiting; nothing
//! else waits behind it.
//!
//! With nobody connected nothing here runs and nothing reaches the loop:
//! the accept task is parked in the kernel, no event is posted, and
//! `App.handle` never sees an `.api` arm. `posted` counts every event this
//! listener has ever handed the loop — the number the loop test holds at
//! zero.
//!
//! The socket's directory is 0700 (`paths.ensureDir`) and the socket 0600.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const event = @import("../core/event.zig");

/// A line over this is read, dropped and answered with an error
/// (`jsonrpc.max_body`).
pub const max_line: usize = @import("../rpc/jsonrpc.zig").max_body;

pub const supported = Io.net.has_unix_sockets;

/// One line from a connection, or its end. Owned by the event.
pub const Incoming = struct {
    conn: u32,
    /// The request line (empty for `closed`). Owned.
    line: []u8,
    /// The client hung up: the UI forgets the connection.
    closed: bool = false,

    pub fn destroy(self: *Incoming, gpa: Allocator) void {
        gpa.free(self.line);
        gpa.destroy(self);
    }
};

const Conn = struct {
    id: u32,
    stream: Io.net.Stream,
    /// The UI thread's answer to the line in flight: a JSON line without
    /// its newline, or empty for a notification. Owned; guarded by `mu`.
    reply: ?[]u8 = null,
    ready: Io.Event = .unset,
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    events: *event.EventQueue,
    /// Owned.
    socket_path: []u8,
    listener: ?Io.net.Server = null,
    group: Io.Group = .init,
    mu: Io.Mutex = .init,
    conns: std.ArrayListUnmanaged(*Conn) = .empty,
    next_id: u32 = 1,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Events handed to the loop, ever.
    posted: std.atomic.Value(u64) = .init(0),

    pub const StartError = error{ Unsupported, BindFailed, ListenFailed } || Allocator.Error;

    /// Bind `socket_path` (its directory already made, 0700), hold the
    /// socket to its owner, and park the accept task.
    pub fn start(gpa: Allocator, io: Io, events: *event.EventQueue, socket_path: []const u8) StartError!*Server {
        if (!supported) return error.Unsupported;
        // A socket file a crashed instance of this pid left behind.
        Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        const addr = Io.net.UnixAddress.init(socket_path) catch return error.BindFailed;
        var listener = addr.listen(io, .{}) catch return error.BindFailed;
        errdefer listener.deinit(io);
        if (builtin.os.tag != .windows) Io.Dir.cwd().setFilePermissions(io, socket_path, .fromMode(0o600), .{}) catch {};
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .events = events, .socket_path = try gpa.dupe(u8, socket_path), .listener = listener };
        errdefer gpa.free(s.socket_path);
        s.group.concurrent(io, accept, .{s}) catch return error.ListenFailed;
        return s;
    }

    pub fn path(s: *const Server) []const u8 {
        return s.socket_path;
    }

    /// Connections open now.
    pub fn connected(s: *Server) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.conns.items.len;
    }

    /// The UI thread's answer for connection `conn`'s line in flight
    /// (`line` empty: a notification, nothing written). Copied. A
    /// connection that has gone is nothing to answer.
    pub fn reply(s: *Server, conn: u32, line: []const u8) Allocator.Error!void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (s.conns.items) |c| if (c.id == conn) {
            if (c.reply) |old| s.gpa.free(old);
            c.reply = try s.gpa.dupe(u8, line);
            c.ready.set(s.io);
            return;
        };
    }

    /// Stop serving: wake the accept task with a connection of our own,
    /// cancel every task and take the socket file away.
    pub fn stop(s: *Server) void {
        const io = s.io;
        s.stopping.store(true, .release);
        if (Io.net.UnixAddress.init(s.socket_path)) |addr| {
            if (addr.connect(io)) |c| c.close(io) else |_| {}
        } else |_| {}
        s.group.cancel(io);
        if (s.listener) |*l| l.deinit(io);
        s.listener = null;
        Io.Dir.cwd().deleteFile(io, s.socket_path) catch {};
    }

    /// `stop` first.
    pub fn destroy(s: *Server) void {
        const gpa = s.gpa;
        for (s.conns.items) |c| {
            if (c.reply) |r| gpa.free(r);
            gpa.destroy(c);
        }
        s.conns.deinit(gpa);
        gpa.free(s.socket_path);
        gpa.destroy(s);
    }

    fn add(s: *Server, stream: Io.net.Stream) Allocator.Error!*Conn {
        const c = try s.gpa.create(Conn);
        errdefer s.gpa.destroy(c);
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        c.* = .{ .id = s.next_id, .stream = stream };
        s.next_id +%= 1;
        if (s.next_id == 0) s.next_id = 1;
        try s.conns.append(s.gpa, c);
        return c;
    }

    fn remove(s: *Server, c: *Conn) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (s.conns.items, 0..) |x, i| if (x == c) {
            _ = s.conns.swapRemove(i);
            break;
        };
        if (c.reply) |r| s.gpa.free(r);
        s.gpa.destroy(c);
    }

    fn take(s: *Server, c: *Conn) ?[]u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const r = c.reply;
        c.reply = null;
        return r;
    }

    fn post(s: *Server, conn: u32, line: []const u8, closed: bool) Allocator.Error!void {
        const inc = try s.gpa.create(Incoming);
        errdefer s.gpa.destroy(inc);
        inc.* = .{ .conn = conn, .line = try s.gpa.dupe(u8, line), .closed = closed };
        _ = s.posted.fetchAdd(1, .monotonic);
        s.events.post(s.io, .{ .api = inc });
    }
};

/// The accept loop: one reader task per connection.
fn accept(s: *Server) Io.Cancelable!void {
    while (!s.stopping.load(.acquire)) {
        const listener = if (s.listener) |*l| l else return;
        const stream = listener.accept(s.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        if (s.stopping.load(.acquire)) {
            stream.close(s.io);
            return;
        }
        const c = s.add(stream) catch {
            stream.close(s.io);
            continue;
        };
        s.group.concurrent(s.io, serve, .{ s, c }) catch {
            s.remove(c);
            stream.close(s.io);
        };
    }
}

const too_long = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"request line over 16 MiB\"}}\n";

/// One connection: a line in, the UI's reply out, until it hangs up. A
/// cancel is answered as a cancel — a group task that swallows
/// `error.Canceled` parks forever and `group.cancel` never returns.
fn serve(s: *Server, c: *Conn) Io.Cancelable!void {
    const io = s.io;
    const conn = c.id;
    defer {
        c.stream.close(io);
        s.remove(c);
        if (!s.stopping.load(.acquire)) s.post(conn, "", true) catch {};
    }
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var r = c.stream.reader(io, &rbuf);
    var w = c.stream.writer(io, &wbuf);
    var line: Io.Writer.Allocating = .init(s.gpa);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        var over = false;
        _ = r.interface.streamDelimiterLimit(&line.writer, '\n', .limited(max_line)) catch |err| switch (err) {
            error.ReadFailed => return cancelOrEnd(r.err),
            error.WriteFailed => return,
            error.StreamTooLong => blk: {
                over = true;
                break :blk 0;
            },
        };
        if (over) {
            _ = r.interface.discardDelimiterInclusive('\n') catch |err| switch (err) {
                error.ReadFailed => return cancelOrEnd(r.err),
                error.EndOfStream => return,
            };
            w.interface.writeAll(too_long) catch return cancelOrEnd(w.err);
            w.interface.flush() catch return cancelOrEnd(w.err);
            continue;
        }
        // The delimiter, or the end of the stream.
        const eof = blk: {
            _ = r.interface.peekByte() catch |err| switch (err) {
                error.EndOfStream => break :blk true,
                error.ReadFailed => return cancelOrEnd(r.err),
            };
            r.interface.toss(1);
            break :blk false;
        };
        const text = std.mem.trim(u8, line.written(), " \t\r");
        if (text.len > 0) {
            s.post(conn, text, false) catch return;
            try c.ready.wait(io);
            c.ready.reset();
            if (s.stopping.load(.acquire)) return;
            if (s.take(c)) |out| {
                defer s.gpa.free(out);
                if (out.len > 0) {
                    w.interface.writeAll(out) catch return cancelOrEnd(w.err);
                    w.interface.writeByte('\n') catch return cancelOrEnd(w.err);
                    w.interface.flush() catch return cancelOrEnd(w.err);
                }
            }
        }
        if (eof) return;
    }
}

fn cancelOrEnd(err: ?anyerror) Io.Cancelable!void {
    if (err) |e| if (e == error.Canceled) return error.Canceled;
}

// ─── a client, for `mnml remote` and the tests ──────────────────────────

pub const Client = struct {
    io: Io,
    stream: Io.net.Stream,
    rbuf: [64 * 1024]u8 = undefined,
    wbuf: [16 * 1024]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,

    pub fn connect(io: Io, socket_path: []const u8) !*Client {
        const addr = try Io.net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        const c = try std.heap.page_allocator.create(Client);
        c.* = .{ .io = io, .stream = stream };
        c.reader = stream.reader(io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        return c;
    }

    pub fn close(c: *Client) void {
        c.stream.close(c.io);
        std.heap.page_allocator.destroy(c);
    }

    /// Send one request line; read one reply line into `gpa`. Owned.
    pub fn call(c: *Client, gpa: Allocator, line: []const u8) ![]u8 {
        try c.send(line);
        return c.recv(gpa);
    }

    pub fn send(c: *Client, line: []const u8) !void {
        try c.writer.interface.writeAll(line);
        try c.writer.interface.writeByte('\n');
        try c.writer.interface.flush();
    }

    /// One reply line into `gpa`. Owned.
    pub fn recv(c: *Client, gpa: Allocator) ![]u8 {
        var a: Io.Writer.Allocating = .init(gpa);
        errdefer a.deinit();
        _ = try c.reader.interface.streamDelimiterLimit(&a.writer, '\n', .limited(max_line));
        // The newline, or a server that hung up before one.
        _ = c.reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => if (a.written().len == 0) return error.EndOfStream,
            else => return err,
        };
        return a.toOwnedSlice();
    }
};
