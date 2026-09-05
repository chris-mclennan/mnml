//! The stdio transport LSP and DAP share (Phase 5's serial leaf): a
//! child process with piped stdio, `Content-Length` framing, one reader
//! task in an `Io.Group` that parses every frame into an `Incoming` and
//! hands it to a `Sink`, and the request-id + pending map a client
//! routes responses with.
//!
//! The two protocols differ only in their envelopes (`jsonrpc`/`id`/
//! `method` versus `seq`/`type`/`command`), so the envelope stays with
//! the client that speaks it; what lives here is everything below it.
//!
//! Ownership (D1): an `Incoming` is built on the reader task and owned
//! by whoever the sink hands it to — the app event, then the handler,
//! which adopts what it keeps into its own snapshot and destroys the
//! box. Cancellation (D3): `shutdown` cancels the group, which
//! interrupts the blocked pipe read (SPIKE_RESULTS: within a second on
//! macOS + Linux), then kills the child — in that order, because the
//! kill closes the pipes the reader is sitting on.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const Value = std.json.Value;

/// Frames past this are refused — a bad header must not allocate the
/// machine away.
pub const max_body: usize = 64 * 1024 * 1024;

/// One parsed message. `parsed` owns an arena; `root()` is the document.
pub const Incoming = struct {
    parsed: std.json.Parsed(Value),

    pub fn create(gpa: Allocator, body: []const u8) (Allocator.Error || error{InvalidJson})!*Incoming {
        const inc = try gpa.create(Incoming);
        errdefer gpa.destroy(inc);
        inc.parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        return inc;
    }

    pub fn destroy(self: *Incoming, gpa: Allocator) void {
        self.parsed.deinit();
        gpa.destroy(self);
    }

    pub fn root(self: *const Incoming) Value {
        return self.parsed.value;
    }
};

/// Where the reader task delivers. Both callbacks run on the reader
/// task, so they must only post — never touch app state.
pub const Sink = struct {
    ctx: *anyopaque,
    /// A frame parsed; the sink owns `msg` from here.
    message: *const fn (ctx: *anyopaque, msg: *Incoming) void,
    /// The stream ended: EOF, a read error, or an unparseable frame.
    /// Not called when `shutdown` is what ended it.
    closed: *const fn (ctx: *anyopaque) void,
};

/// What a client remembers about a request in flight: its own method
/// tag and a word of context (a pane, a byte offset, a watch index).
pub const Pending = struct { kind: u16 = 0, ctx: u64 = 0 };

pub const SendError = error{ WriteFailed, Closed };

pub const Transport = struct {
    gpa: Allocator,
    io: Io,
    child: ?std.process.Child,
    /// Our end of the child's stdin (we write) and stdout (we read).
    stdin: Io.File,
    stdout: Io.File,
    write_lock: Io.Mutex = .init,
    group: Io.Group = .init,
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    /// Set by `shutdown` before the cancel so the reader does not report
    /// the EOF it is about to see as the server going away.
    closing: std.atomic.Value(bool) = .init(false),
    started: bool = false,
    /// Set once the stream ended; sends refuse from then on.
    dead: std.atomic.Value(bool) = .init(false),

    pub const SpawnError = std.process.SpawnError || Allocator.Error;

    /// Start `argv` with piped stdio. `cwd` null inherits; `env` null
    /// inherits the process environment. A missing binary fails here,
    /// synchronously — the caller toasts once and marks the server dead.
    pub fn spawn(gpa: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) SpawnError!*Transport {
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .environ_map = env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);
        const t = try gpa.create(Transport);
        t.* = .{ .gpa = gpa, .io = io, .child = child, .stdin = child.stdin.?, .stdout = child.stdout.? };
        return t;
    }

    /// A transport over two files already open (tests: a pipe pair to
    /// an in-process fake server). The transport closes both on
    /// `shutdown`.
    pub fn initFiles(gpa: Allocator, io: Io, stdin: Io.File, stdout: Io.File) Allocator.Error!*Transport {
        const t = try gpa.create(Transport);
        t.* = .{ .gpa = gpa, .io = io, .child = null, .stdin = stdin, .stdout = stdout };
        return t;
    }

    /// Start the reader task. `sink` outlives the transport.
    pub fn start(self: *Transport, sink: Sink) Io.ConcurrentError!void {
        std.debug.assert(!self.started);
        try self.group.concurrent(self.io, readerTask, .{ self, sink });
        self.started = true;
    }

    /// End everything: interrupt the reader, kill the child, close the
    /// pipes, drop the pending map, free the box. A client sends its
    /// protocol goodbye (`shutdown`/`exit`, `disconnect`) before this.
    pub fn shutdown(self: *Transport) void {
        self.closing.store(true, .release);
        self.group.cancel(self.io);
        if (self.child) |*c| {
            // `kill` closes the three pipes itself.
            c.kill(self.io);
        } else {
            self.stdin.close(self.io);
            self.stdout.close(self.io);
        }
        self.pending.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// True once the server's stream ended (it exited or broke).
    pub fn isDead(self: *const Transport) bool {
        return self.dead.load(.acquire);
    }

    // ─── ids + pending ───

    pub fn allocId(self: *Transport) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn expect(self: *Transport, id: i64, p: Pending) Allocator.Error!void {
        try self.pending.put(self.gpa, id, p);
    }

    /// The pending record for a response, removing it. Null for an id
    /// that was cancelled, already answered, or never ours.
    pub fn take(self: *Transport, id: i64) ?Pending {
        const kv = self.pending.fetchRemove(id) orelse return null;
        return kv.value;
    }

    /// Forget a request: its response, if it still comes, is dropped.
    /// The wire-level cancel (`$/cancelRequest`, DAP `cancel`) is the
    /// client's, since its shape is the envelope's.
    pub fn forget(self: *Transport, id: i64) ?Pending {
        return self.take(id);
    }

    pub fn pendingCount(self: *const Transport) usize {
        return self.pending.count();
    }

    // ─── the wire ───

    /// One frame out. Serialised: the UI thread and a worker may both
    /// send. Refused once the stream is dead.
    pub fn send(self: *Transport, body: []const u8) SendError!void {
        if (self.dead.load(.acquire) or self.closing.load(.acquire)) return error.Closed;
        self.write_lock.lockUncancelable(self.io);
        defer self.write_lock.unlock(self.io);
        writeFrame(self.io, self.stdin, body) catch return error.WriteFailed;
    }

    fn readerTask(self: *Transport, sink: Sink) Io.Cancelable!void {
        var buf: [16 * 1024]u8 = undefined;
        var fr = self.stdout.readerStreaming(self.io, &buf);
        while (true) {
            const body = readFrame(self.gpa, &fr.interface) catch |err| switch (err) {
                error.OutOfMemory, error.Closed, error.BadFrame => break,
            };
            defer self.gpa.free(body);
            const inc = Incoming.create(self.gpa, body) catch break;
            sink.message(sink.ctx, inc);
        }
        self.dead.store(true, .release);
        if (self.closing.load(.acquire)) return error.Canceled;
        sink.closed(sink.ctx);
    }
};

// ─── framing ────────────────────────────────────────────────────────────

pub const FrameError = error{ Closed, BadFrame } || Allocator.Error;

/// `Content-Length: N\r\n\r\n` then N bytes. Other headers are skipped.
/// Returns the body, gpa-owned. `Closed` on EOF or a read failure.
pub fn readFrame(gpa: Allocator, r: *Io.Reader) FrameError![]u8 {
    var len: ?usize = null;
    while (true) {
        // `takeDelimiter` consumes the newline (its `Exclusive` sibling
        // leaves it in the stream) and answers null at end of stream.
        const raw = (r.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.Closed,
            error.StreamTooLong => return error.BadFrame,
        }) orelse return error.Closed;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (len != null) break;
            continue; // a stray blank before the headers
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
            len = std.fmt.parseInt(usize, v, 10) catch return error.BadFrame;
        }
    }
    const n = len.?;
    if (n > max_body) return error.BadFrame;
    const body = try gpa.alloc(u8, n);
    errdefer gpa.free(body);
    r.readSliceAll(body) catch return error.Closed;
    return body;
}

pub fn writeFrame(io: Io, file: Io.File, body: []const u8) Io.Writer.Error!void {
    var buf: [4096]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
    try w.flush();
}

// ─── JSON helpers every client shares ───────────────────────────────────

/// Serialise `v` (any Stringify-able value) into a gpa-owned body.
pub fn stringify(gpa: Allocator, v: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, v, .{ .emit_null_optional_fields = false });
}

pub fn getField(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(v: Value, key: []const u8) ?i64 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

pub fn getBool(v: Value, key: []const u8) ?bool {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getArr(v: Value, key: []const u8) ?[]const Value {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn getObj(v: Value, key: []const u8) ?Value {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .object => f,
        else => null,
    };
}

pub fn asStr(v: Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn asInt(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

/// A JSON-RPC 2.0 envelope classified. `id` is the integer id when
/// there is one (string ids are not something we send).
pub const Kind = union(enum) {
    response: struct { id: i64, result: ?Value, err: ?Value },
    request: struct { id: i64, method: []const u8, params: ?Value },
    notification: struct { method: []const u8, params: ?Value },
    unknown,
};

pub fn classify(v: Value) Kind {
    const id = getInt(v, "id");
    const method = getStr(v, "method");
    if (method) |m| {
        if (id) |i| return .{ .request = .{ .id = i, .method = m, .params = getField(v, "params") } };
        return .{ .notification = .{ .method = m, .params = getField(v, "params") } };
    }
    if (id) |i| {
        const err = getField(v, "error");
        const result = getField(v, "result");
        if (err == null and result == null and getField(v, "id") == null) return .unknown;
        return .{ .response = .{ .id = i, .result = result, .err = err } };
    }
    return .unknown;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A pipe pair as two files: `[read, write]`.
fn pipeFiles() ![2]Io.File {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try Io.Threaded.pipe2(.{});
    return .{ .{ .handle = fds[0], .flags = .{ .nonblocking = false } }, .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
}

test "readFrame: the header, case-insensitive, other headers skipped; bad lengths refused" {
    const gpa = testing.allocator;
    var r = Io.Reader.fixed("Content-Type: x\r\ncontent-length: 5\r\n\r\nhelloContent-Length: 2\r\n\r\nhi");
    const a = try readFrame(gpa, &r);
    defer gpa.free(a);
    try testing.expectEqualStrings("hello", a);
    const b = try readFrame(gpa, &r);
    defer gpa.free(b);
    try testing.expectEqualStrings("hi", b);
    try testing.expectError(error.Closed, readFrame(gpa, &r));
    var bad = Io.Reader.fixed("Content-Length: nope\r\n\r\n");
    try testing.expectError(error.BadFrame, readFrame(gpa, &bad));
    var short = Io.Reader.fixed("Content-Length: 9\r\n\r\nabc");
    try testing.expectError(error.Closed, readFrame(gpa, &short));
}

test "classify: response / request / notification" {
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"a\":1}}", .{});
    defer parsed.deinit();
    const k = classify(parsed.value);
    try testing.expectEqual(@as(i64, 3), k.response.id);
    try testing.expectEqual(@as(i64, 1), getInt(k.response.result.?, "a").?);
    var p2 = try std.json.parseFromSlice(Value, testing.allocator, "{\"id\":7,\"method\":\"window/showMessageRequest\",\"params\":{}}", .{});
    defer p2.deinit();
    try testing.expectEqualStrings("window/showMessageRequest", classify(p2.value).request.method);
    var p3 = try std.json.parseFromSlice(Value, testing.allocator, "{\"method\":\"textDocument/publishDiagnostics\"}", .{});
    defer p3.deinit();
    try testing.expectEqualStrings("textDocument/publishDiagnostics", classify(p3.value).notification.method);
}

test "pending map: ids climb, take answers once, forget drops" {
    const gpa = testing.allocator;
    const files = try pipeFiles();
    const t = try Transport.initFiles(gpa, testing.io, files[1], files[0]);
    defer t.shutdown();
    const a = t.allocId();
    const b = t.allocId();
    try testing.expect(b == a + 1);
    try t.expect(a, .{ .kind = 4, .ctx = 99 });
    try t.expect(b, .{ .kind = 5 });
    try testing.expectEqual(@as(u64, 99), t.take(a).?.ctx);
    try testing.expect(t.take(a) == null);
    try testing.expectEqual(@as(u16, 5), t.forget(b).?.kind);
    try testing.expectEqual(@as(usize, 0), t.pendingCount());
}

/// The test sink: counts frames and remembers the last body's id.
const Collector = struct {
    gpa: Allocator,
    lock: Io.Mutex = .init,
    got: std.ArrayListUnmanaged(*Incoming) = .empty,
    closed: std.atomic.Value(bool) = .init(false),
    arrived: Io.Event = .unset,

    fn onMessage(ctx: *anyopaque, msg: *Incoming) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        c.lock.lockUncancelable(testing.io);
        defer c.lock.unlock(testing.io);
        c.got.append(c.gpa, msg) catch msg.destroy(c.gpa);
        c.arrived.set(testing.io);
    }
    fn onClosed(ctx: *anyopaque) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        c.closed.store(true, .release);
        c.arrived.set(testing.io);
    }
    fn sink(c: *Collector) Sink {
        return .{ .ctx = c, .message = onMessage, .closed = onClosed };
    }
    fn count(c: *Collector) usize {
        c.lock.lockUncancelable(testing.io);
        defer c.lock.unlock(testing.io);
        return c.got.items.len;
    }
    fn deinit(c: *Collector) void {
        for (c.got.items) |m| m.destroy(c.gpa);
        c.got.deinit(c.gpa);
    }
    /// Wait until `n` frames arrived or the stream closed.
    fn waitFor(c: *Collector, n: usize) !void {
        var spins: usize = 0;
        while (c.count() < n and !c.closed.load(.acquire)) : (spins += 1) {
            if (spins > 500) return error.Timeout;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
    }
};

/// An in-process fake server: echoes every request back as a response
/// with `result = {"echo": <method>}`, answers a `ping` notification
/// with a `pong` notification, and leaves on `exit`.
fn fakeEchoServer(io: Io, gpa: Allocator, in: Io.File, out: Io.File) Io.Cancelable!void {
    var buf: [4096]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    while (true) {
        const body = readFrame(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        switch (classify(parsed.value)) {
            .request => |rq| {
                const reply = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"echo\":\"{s}\"}}}}", .{ rq.id, rq.method }) catch return;
                defer gpa.free(reply);
                writeFrame(io, out, reply) catch return;
            },
            .notification => |n| {
                if (std.mem.eql(u8, n.method, "exit")) return;
                if (std.mem.eql(u8, n.method, "ping")) writeFrame(io, out, "{\"jsonrpc\":\"2.0\",\"method\":\"pong\"}") catch return;
            },
            else => {},
        }
    }
}

test "transport over a pipe pair: requests are answered by id, notifications flow both ways, EOF reports closed" {
    const gpa = testing.allocator;
    const io = testing.io;
    const c2s = try pipeFiles();
    const s2c = try pipeFiles();
    var server_group: Io.Group = .init;
    try server_group.concurrent(io, fakeEchoServer, .{ io, gpa, c2s[0], s2c[1] });
    const t = try Transport.initFiles(gpa, io, c2s[1], s2c[0]);
    var col: Collector = .{ .gpa = gpa };
    defer col.deinit();
    try t.start(col.sink());

    const id = t.allocId();
    try t.expect(id, .{ .kind = 1, .ctx = 42 });
    const req = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{}}}}", .{id});
    defer gpa.free(req);
    try t.send(req);
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}");
    try col.waitFor(2);
    try testing.expectEqual(@as(usize, 2), col.count());
    const first = classify(col.got.items[0].root());
    try testing.expectEqual(id, first.response.id);
    try testing.expectEqualStrings("initialize", getStr(first.response.result.?, "echo").?);
    try testing.expectEqual(@as(u64, 42), t.take(first.response.id).?.ctx);
    try testing.expectEqualStrings("pong", classify(col.got.items[1].root()).notification.method);

    // The server leaving is reported once, as `closed`.
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try server_group.await(io);
    // Our copy of the server's write end must go too, or the reader
    // never sees EOF.
    s2c[1].close(io);
    c2s[0].close(io);
    try col.waitFor(3);
    try testing.expect(col.closed.load(.acquire));
    try testing.expect(t.isDead());
    try testing.expectError(error.Closed, t.send("{}"));
    t.shutdown();
}

test "shutdown while the reader is blocked: no closed callback, no leak" {
    const gpa = testing.allocator;
    const io = testing.io;
    const c2s = try pipeFiles();
    const s2c = try pipeFiles();
    const t = try Transport.initFiles(gpa, io, c2s[1], s2c[0]);
    var col: Collector = .{ .gpa = gpa };
    defer col.deinit();
    try t.start(col.sink());
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"noop\"}");
    t.shutdown();
    try testing.expect(!col.closed.load(.acquire));
    c2s[0].close(io);
    s2c[1].close(io);
}

test "spawn: a missing binary fails synchronously; `cat` echoes frames back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    try testing.expectError(error.FileNotFound, Transport.spawn(gpa, io, &.{"/definitely/not/a/binary-mnml"}, null, null));
    const t = try Transport.spawn(gpa, io, &.{"cat"}, null, null);
    var col: Collector = .{ .gpa = gpa };
    defer col.deinit();
    try t.start(col.sink());
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}");
    try col.waitFor(1);
    try testing.expectEqualStrings("hello", classify(col.got.items[0].root()).notification.method);
    t.shutdown();
}
