//! The agent face's listener: one loopback WebSocket server per Claude
//! Code session pane (`docs/research/api-design.md` §6.2, `docs/API.md`
//! "Agent face"). Claude Code finds it through the lock file named by
//! its port and presents the lock file's token in the
//! `x-claude-code-ide-authorization` header; an upgrade without it is
//! answered 401 and closed.
//!
//! An accept task parked in `accept`; per connection a reader task (the
//! upgrade, then whole messages, each handed to the UI thread as an
//! `.ide` event) and a writer task that drains what the UI thread queued
//! (`send`). The UI thread never touches a socket, and a request held
//! for the person — an `openDiff` under review, a `saveDocument` asking —
//! keeps nothing else on the connection waiting.
//!
//! With nobody connected nothing here runs: the accept task is parked in
//! the kernel and `posted` (every event handed to the loop, ever) stays
//! at zero — the number the loop test holds.

const std = @import("std");
const repeat = @import("mnml_sdk").zig_compat.repeat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const event = @import("../core/event.zig");
const ws = @import("../http/ws.zig");

/// The header Claude Code carries the lock file's token in.
pub const auth_header = "x-claude-code-ide-authorization";
pub const token_len = 32;
pub const Token = [token_len]u8;

/// A message, or a connection's start or end. Owned by the event.
pub const Incoming = struct {
    /// The session pane the listener belongs to.
    pane: u32,
    conn: u32,
    kind: Kind = .message,
    /// The message text (empty for `opened` / `closed`). Owned.
    text: []u8,

    pub const Kind = enum { opened, message, closed };

    pub fn destroy(self: *Incoming, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.destroy(self);
    }
};

/// Connection ids are unique across every listener, and kept clear of
/// the API socket's (`api/server.zig` counts up from 1), so a held
/// request names its connection without naming its listener.
var next_conn: std.atomic.Value(u32) = .init(1 << 31);

const Conn = struct {
    id: u32,
    stream: Io.net.Stream,
    /// Encoded frames waiting for the writer. Owned; guarded by the
    /// listener's `mu`.
    outbox: std.ArrayListUnmanaged([]u8) = .empty,
    ready: Io.Event = .unset,
    /// The reader has ended: the writer drains and goes.
    done: bool = false,
    /// The reader and the writer; the last one out frees the connection.
    refs: std.atomic.Value(u8) = .init(2),
};

pub const Listener = struct {
    gpa: Allocator,
    io: Io,
    events: *event.EventQueue,
    pane: u32,
    port: u16,
    token: Token,
    server: ?Io.net.Server = null,
    group: Io.Group = .init,
    mu: Io.Mutex = .init,
    conns: std.ArrayListUnmanaged(*Conn) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Events handed to the loop, ever.
    posted: std.atomic.Value(u64) = .init(0),

    pub const StartError = error{ BindFailed, ListenFailed } || Allocator.Error;

    /// Bind `127.0.0.1:<a port the OS picks>` and park the accept task.
    pub fn start(gpa: Allocator, io: Io, events: *event.EventQueue, pane: u32, token: Token) StartError!*Listener {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = addr.listen(io, .{ .reuse_address = true }) catch return error.BindFailed;
        errdefer server.deinit(io);
        const s = try gpa.create(Listener);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .events = events, .pane = pane, .port = server.socket.address.getPort(), .token = token, .server = server };
        s.group.concurrent(io, accept, .{s}) catch return error.ListenFailed;
        return s;
    }

    /// Connections open now (upgraded or not).
    pub fn connected(s: *Listener) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.conns.items.len;
    }

    /// Queue `text` as one text message on connection `conn`. A
    /// connection that has gone is nothing to send to.
    pub fn send(s: *Listener, conn: u32, text: []const u8) Allocator.Error!void {
        const frame = try ws.encodeFrame(s.gpa, .text, text, true, null);
        s.queue(conn, frame) catch |err| {
            s.gpa.free(frame);
            return err;
        };
    }

    fn queue(s: *Listener, conn: u32, frame: []u8) Allocator.Error!void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (s.conns.items) |c| if (c.id == conn and !c.done) {
            try c.outbox.append(s.gpa, frame);
            c.ready.set(s.io);
            return;
        };
        s.gpa.free(frame);
    }

    /// Stop serving: wake the accept task with a connection of our own
    /// and cancel every task.
    pub fn stop(s: *Listener) void {
        const io = s.io;
        s.stopping.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(s.port) };
        if (addr.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
        s.group.cancel(io);
        if (s.server) |*l| l.deinit(io);
        s.server = null;
    }

    /// `stop` first.
    pub fn destroy(s: *Listener) void {
        s.conns.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn add(s: *Listener, stream: Io.net.Stream) Allocator.Error!*Conn {
        const c = try s.gpa.create(Conn);
        errdefer s.gpa.destroy(c);
        c.* = .{ .id = next_conn.fetchAdd(1, .monotonic) | (1 << 31), .stream = stream };
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        try s.conns.append(s.gpa, c);
        return c;
    }

    /// One of the connection's two tasks is done with it.
    fn release(s: *Listener, c: *Conn) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        c.stream.close(s.io);
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (s.conns.items, 0..) |x, i| if (x == c) {
            _ = s.conns.swapRemove(i);
            break;
        };
        for (c.outbox.items) |f| s.gpa.free(f);
        c.outbox.deinit(s.gpa);
        s.gpa.destroy(c);
    }

    /// The reader has ended: the writer finishes what is queued, then goes.
    fn finish(s: *Listener, c: *Conn) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        c.done = true;
        c.ready.set(s.io);
    }

    fn take(s: *Listener, c: *Conn) struct { frames: std.ArrayListUnmanaged([]u8), done: bool } {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const frames = c.outbox;
        c.outbox = .empty;
        return .{ .frames = frames, .done = c.done };
    }

    fn post(s: *Listener, conn: u32, kind: Incoming.Kind, text: []const u8) Allocator.Error!void {
        const inc = try s.gpa.create(Incoming);
        errdefer s.gpa.destroy(inc);
        inc.* = .{ .pane = s.pane, .conn = conn, .kind = kind, .text = try s.gpa.dupe(u8, text) };
        _ = s.posted.fetchAdd(1, .monotonic);
        s.events.post(s.io, .{ .ide = inc });
    }
};

fn accept(s: *Listener) Io.Cancelable!void {
    while (!s.stopping.load(.acquire)) {
        const server = if (s.server) |*l| l else return;
        const stream = server.accept(s.io) catch |err| switch (err) {
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
        s.group.concurrent(s.io, writeLoop, .{ s, c }) catch {
            // Neither task runs: both references go here.
            s.release(c);
            s.release(c);
            continue;
        };
        s.group.concurrent(s.io, readLoop, .{ s, c }) catch {
            s.finish(c);
            s.release(c);
        };
    }
}

fn cancelOrEnd(err: ?anyerror) Io.Cancelable!void {
    if (err) |e| if (e == error.Canceled) return error.Canceled;
}

/// The upgrade, then one `.ide` event per whole message until the peer
/// closes. A cancel is answered as a cancel — a group task that swallows
/// `error.Canceled` parks forever and `group.cancel` never returns.
fn readLoop(s: *Listener, c: *Conn) Io.Cancelable!void {
    const io = s.io;
    const gpa = s.gpa;
    var upgraded = false;
    defer {
        s.finish(c);
        if (upgraded and !s.stopping.load(.acquire)) s.post(c.id, .closed, "") catch {};
        s.release(c);
    }
    var rbuf: [64 * 1024]u8 = undefined;
    var hbuf: [1024]u8 = undefined;
    var r = c.stream.reader(io, &rbuf);
    {
        var w = c.stream.writer(io, &hbuf);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        _ = ws.serverAcceptChecked(&r.interface, &w.interface, scratch.allocator(), .{ .name = auth_header, .value = &s.token }) catch |err| switch (err) {
            error.ReadFailed => return cancelOrEnd(r.err),
            error.WriteFailed => return cancelOrEnd(w.err),
            else => return,
        };
    }
    upgraded = true;
    s.post(c.id, .opened, "") catch return;
    var frame_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_buf.deinit(gpa);
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    defer msg.deinit(gpa);
    while (true) {
        const f = ws.readFrame(&r.interface, gpa, &frame_buf) catch |err| switch (err) {
            error.ReadFailed => return cancelOrEnd(r.err),
            else => return,
        };
        switch (f.opcode) {
            .text, .binary => {
                msg.clearRetainingCapacity();
                msg.appendSlice(gpa, f.payload) catch return;
                if (f.fin) s.post(c.id, .message, msg.items) catch return;
            },
            .continuation => {
                msg.appendSlice(gpa, f.payload) catch return;
                if (f.fin) s.post(c.id, .message, msg.items) catch return;
            },
            .ping => {
                const pong = ws.encodeFrame(gpa, .pong, f.payload, true, null) catch return;
                s.queue(c.id, pong) catch return;
            },
            .close => {
                // Echo it, and end.
                const echo = ws.encodeFrame(gpa, .close, f.payload[0..@min(f.payload.len, 2)], true, null) catch return;
                s.queue(c.id, echo) catch {};
                return;
            },
            else => {},
        }
    }
}

fn writeLoop(s: *Listener, c: *Conn) Io.Cancelable!void {
    const io = s.io;
    defer s.release(c);
    var wbuf: [16 * 1024]u8 = undefined;
    var w = c.stream.writer(io, &wbuf);
    while (true) {
        try c.ready.wait(io);
        // Reset before taking: a set that lands after this finds its
        // frame taken below or waits for the next round.
        c.ready.reset();
        var batch = s.take(c);
        defer {
            for (batch.frames.items) |f| s.gpa.free(f);
            batch.frames.deinit(s.gpa);
        }
        for (batch.frames.items) |f| w.interface.writeAll(f) catch return cancelOrEnd(w.err);
        if (batch.frames.items.len > 0) w.interface.flush() catch return cancelOrEnd(w.err);
        if (batch.done) return;
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// Wait up to two seconds for an event, as the loop would.
pub fn awaitEvent(q: *event.EventQueue, io: Io, buf: []event.AppEvent) usize {
    var n: usize = 0;
    var waited: usize = 0;
    while (n == 0 and waited < 200) : (waited += 1) {
        q.wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        q.wake.reset();
        n = q.drain(io, buf);
    }
    return n;
}

test "the listener refuses an upgrade without the token, takes one with it, and carries messages both ways" {
    var q = try event.EventQueue.init(t.allocator, 64);
    defer q.deinit(t.io);
    var tok: Token = undefined;
    @memset(&tok, 'a');
    const l = try Listener.start(t.allocator, t.io, &q, 5, tok);
    defer {
        l.stop();
        l.destroy();
    }
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/", .{l.port});

    // No header, and a wrong one: refused at the upgrade, nothing posted.
    try t.expectError(error.BadStatus, ws.Conn.connect(t.allocator, t.io, url, .{}));
    try t.expectError(error.BadStatus, ws.Conn.connect(t.allocator, t.io, url, .{ .headers = &.{.{ auth_header, repeat("b", token_len) }} }));
    try t.expectEqual(@as(u64, 0), l.posted.load(.monotonic));

    const c = try ws.Conn.connect(t.allocator, t.io, url, .{ .headers = &.{.{ auth_header, &tok }} });
    defer c.deinit();
    var buf: [4]event.AppEvent = undefined;
    try t.expectEqual(@as(usize, 1), awaitEvent(&q, t.io, &buf));
    try t.expect(buf[0] == .ide and buf[0].ide.kind == .opened and buf[0].ide.pane == 5);
    const conn = buf[0].ide.conn;
    event.freeEvent(t.allocator, buf[0]);

    try c.sendText("{\"x\":1}");
    try t.expectEqual(@as(usize, 1), awaitEvent(&q, t.io, &buf));
    try t.expect(buf[0] == .ide and buf[0].ide.kind == .message);
    try t.expectEqualStrings("{\"x\":1}", buf[0].ide.text);
    event.freeEvent(t.allocator, buf[0]);

    try l.send(conn, "{\"y\":2}");
    const m = (try c.readMessage()).?;
    try t.expectEqualStrings("{\"y\":2}", m.text);
}
