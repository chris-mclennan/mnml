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
//!
//! Outbound frames go through a writer task too: `send` copies the body
//! onto a queue and returns, so the UI thread never sits on the pipe —
//! a full-text `didChange` of a large file to a server that reads
//! slowly used to stall the frame that produced it. Frames leave in the
//! order they were sent. `shutdown` closes the queue before cancelling
//! (the D3 rule for a queue-fed worker) and gives the writer a moment
//! to drain, so a goodbye sent just before it still reaches the child.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const Value = std.json.Value;

/// The most one message may be. Not the memory it costs — the memory it
/// MULTIPLIES: a JSON body parses into a `Value` tree several times its
/// own size, so a frame this big is already the largest allocation the
/// process will make for one message. rust-analyzer answered a 100 MB
/// source file with a 75 MB frame and a 196 MB one; nothing a server has
/// to say about a file mnml will even attach to (`editor.lsp_max_bytes`,
/// 50 MiB) needs a fraction of this, and a frame that does is a server
/// in trouble rather than an answer worth having.
///
/// Over it the body is READ AND THROWN AWAY rather than refused: the
/// stream stays in step and the server stays up, where the old refusal
/// killed the transport mid-frame and said nothing.
pub const max_body: usize = 16 * 1024 * 1024;

/// How much of an over-sized frame is kept, to name it by.
pub const head_peek: usize = 512;

/// What `readFrame` got.
pub const Frame = union(enum) {
    /// The body, gpa-owned.
    body: []u8,
    /// A frame over `max_body`, discarded. `head` is its first
    /// `head_peek` bytes, gpa-owned, so the caller can say what was
    /// dropped.
    oversize: struct { len: usize, head: []u8 },
};

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
    /// A frame over `max_body` was dropped. `head` is borrowed for the
    /// call only. Null leaves the drop to the log alone.
    oversize: ?*const fn (ctx: *anyopaque, len: usize, head: []const u8) void = null,
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
    /// Outbound frames (gpa-owned bodies) for the writer task, and the
    /// ring behind the queue.
    out: Io.Queue([]u8),
    out_ring: [][]u8,
    /// Set by the writer once the closed queue is drained.
    drained: std.atomic.Value(bool) = .init(false),
    /// Frames the writer has put on the pipe (the tests read it).
    frames_out: std.atomic.Value(u32) = .init(0),

    pub const SpawnError = std.process.SpawnError || Allocator.Error;

    /// Frames that may wait for the writer before `send` blocks.
    pub const out_capacity = 64;
    /// How long `shutdown` waits for the writer to drain the queue.
    pub const drain_grace_ms: u32 = 100;

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
        errdefer gpa.destroy(t);
        const ring = try gpa.alloc([]u8, out_capacity);
        t.* = .{ .gpa = gpa, .io = io, .child = child, .stdin = child.stdin.?, .stdout = child.stdout.?, .out = .init(ring), .out_ring = ring };
        return t;
    }

    /// A transport over two files already open (tests: a pipe pair to
    /// an in-process fake server). The transport closes both on
    /// `shutdown`.
    pub fn initFiles(gpa: Allocator, io: Io, stdin: Io.File, stdout: Io.File) Allocator.Error!*Transport {
        const t = try gpa.create(Transport);
        errdefer gpa.destroy(t);
        const ring = try gpa.alloc([]u8, out_capacity);
        t.* = .{ .gpa = gpa, .io = io, .child = null, .stdin = stdin, .stdout = stdout, .out = .init(ring), .out_ring = ring };
        return t;
    }

    /// Start the reader and writer tasks. `sink` outlives the transport.
    pub fn start(self: *Transport, sink: Sink) Io.ConcurrentError!void {
        std.debug.assert(!self.started);
        try self.group.concurrent(self.io, readerTask, .{ self, sink });
        try self.group.concurrent(self.io, writerTask, .{self});
        self.started = true;
    }

    /// End everything: close the queue and let the writer drain it,
    /// interrupt the reader, kill the child, close the pipes, drop the
    /// pending map, free the box. A client sends its protocol goodbye
    /// (`shutdown`/`exit`, `disconnect`) before this.
    pub fn shutdown(self: *Transport) void {
        self.closing.store(true, .release);
        self.out.close(self.io);
        if (self.started) {
            var waited: u32 = 0;
            while (!self.drained.load(.acquire) and !self.dead.load(.acquire) and waited < drain_grace_ms) : (waited += 5) {
                self.io.sleep(.fromMilliseconds(5), .awake) catch break;
            }
        }
        self.group.cancel(self.io);
        // Whatever the writer did not get to.
        while (true) {
            const body = self.out.getOneUncancelable(self.io) catch break;
            self.gpa.free(body);
        }
        self.gpa.free(self.out_ring);
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

    /// One frame out, queued for the writer task: returns once the body
    /// is copied, blocking only when `out_capacity` frames already wait
    /// (backpressure on a server that stopped reading). The UI thread
    /// and a worker may both send. Refused once the stream is dead.
    pub fn send(self: *Transport, body: []const u8) SendError!void {
        if (self.dead.load(.acquire) or self.closing.load(.acquire)) return error.Closed;
        const copy = self.gpa.dupe(u8, body) catch return error.WriteFailed;
        self.out.putOneUncancelable(self.io, copy) catch {
            self.gpa.free(copy);
            return error.Closed;
        };
    }

    /// Write the frame now, on the calling thread. Serialised with the
    /// writer task; what the writer task itself calls.
    fn writeNow(self: *Transport, body: []const u8) SendError!void {
        self.write_lock.lockUncancelable(self.io);
        defer self.write_lock.unlock(self.io);
        writeFrame(self.io, self.stdin, body) catch return error.WriteFailed;
    }

    fn writerTask(self: *Transport) Io.Cancelable!void {
        var broken = false;
        while (true) {
            const body = self.out.getOne(self.io) catch |err| switch (err) {
                error.Closed => break,
                error.Canceled => return error.Canceled,
            };
            defer self.gpa.free(body);
            if (broken) continue;
            self.writeNow(body) catch {
                // The child is gone (EPIPE): the reader reports it; the
                // rest of the queue is dropped as `send` would refuse it.
                broken = true;
                self.dead.store(true, .release);
                continue;
            };
            _ = self.frames_out.fetchAdd(1, .release);
        }
        self.drained.store(true, .release);
    }

    fn readerTask(self: *Transport, sink: Sink) Io.Cancelable!void {
        var buf: [16 * 1024]u8 = undefined;
        var fr = self.stdout.readerStreaming(self.io, &buf);
        while (true) {
            const frame = readFrame(self.gpa, &fr.interface) catch |err| switch (err) {
                error.OutOfMemory, error.Closed, error.BadFrame => break,
            };
            switch (frame) {
                .body => |body| {
                    defer self.gpa.free(body);
                    const inc = Incoming.create(self.gpa, body) catch break;
                    sink.message(sink.ctx, inc);
                },
                .oversize => |o| {
                    defer self.gpa.free(o.head);
                    std.log.warn("jsonrpc: dropped a {d}-byte frame (over {d}): {s}", .{ o.len, max_body, o.head });
                    if (sink.oversize) |cb| cb(sink.ctx, o.len, o.head);
                },
            }
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
pub fn readFrame(gpa: Allocator, r: *Io.Reader) FrameError!Frame {
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
    if (n > max_body) {
        // Read the whole body anyway — the next frame's header is
        // behind it — but keep only enough to say what it was.
        const keep = @min(n, head_peek);
        const head = try gpa.alloc(u8, keep);
        errdefer gpa.free(head);
        r.readSliceAll(head) catch return error.Closed;
        r.discardAll64(n - keep) catch return error.Closed;
        return .{ .oversize = .{ .len = n, .head = head } };
    }
    const body = try gpa.alloc(u8, n);
    errdefer gpa.free(body);
    r.readSliceAll(body) catch return error.Closed;
    return .{ .body = body };
}

/// The `"method"` of a frame from its first bytes alone — what is left
/// to go on when the body was too big to parse. Null when the head does
/// not hold one (a response carries an `id` instead).
pub fn peekMethod(head: []const u8) ?[]const u8 {
    const key = "\"method\":\"";
    const at = std.mem.indexOf(u8, head, key) orelse return null;
    const rest = head[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0 or end > 128) return null;
    return rest[0..end];
}

/// The `"id"` of a frame from its first bytes alone, for the same
/// reason. Only a plain integer id — the ids mnml allocates.
pub fn peekId(head: []const u8) ?i64 {
    const key = "\"id\":";
    const at = std.mem.indexOf(u8, head, key) orelse return null;
    var rest = head[at + key.len ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    var n: usize = 0;
    while (n < rest.len and (std.ascii.isDigit(rest[n]) or (n == 0 and rest[n] == '-'))) n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(i64, rest[0..n], 10) catch null;
}

/// `readFrame` for a caller with no interest in the oversize case (the
/// test fakes, which never send one): a dropped frame reads as a bad
/// frame.
pub fn readBody(gpa: Allocator, r: *Io.Reader) FrameError![]u8 {
    switch (try readFrame(gpa, r)) {
        .body => |b| return b,
        .oversize => |o| {
            gpa.free(o.head);
            return error.BadFrame;
        },
    }
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

/// A request id as the wire carries it: JSON-RPC allows `integer |
/// string`, and zls asks its client with strings (`workspace/
/// configuration` comes as `"id":"i_haz_configuration"`). The ids WE
/// send are integers, so a response is matched on those alone; a
/// server's request keeps whichever kind it used, and the reply echoes
/// it back verbatim — a request answered under a different id is a
/// request never answered.
pub const Id = union(enum) {
    int: i64,
    str: []const u8,

    /// The id as JSON: the integer, or the string quoted and escaped.
    pub fn json(self: Id, gpa: Allocator) Allocator.Error![]u8 {
        switch (self) {
            .int => |i| return std.fmt.allocPrint(gpa, "{d}", .{i}),
            .str => |s| {
                var w: Io.Writer.Allocating = .init(gpa);
                errdefer w.deinit();
                std.json.Stringify.encodeJsonString(s, .{}, &w.writer) catch return error.OutOfMemory;
                return w.toOwnedSlice();
            },
        }
    }

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .int => |x| b == .int and b.int == x,
            .str => |x| b == .str and std.mem.eql(u8, b.str, x),
        };
    }
};

/// `key` as a request id: an integer (a float that is one), or a
/// string. Anything else — `null`, an object — is no id.
pub fn getId(v: Value, key: []const u8) ?Id {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .integer => |i| .{ .int = i },
        .float => |x| .{ .int = @intFromFloat(x) },
        .string => |s| .{ .str = s },
        else => null,
    };
}

/// A JSON-RPC 2.0 envelope classified. A response's `id` is the integer
/// we sent; a server's request carries its own `Id`, string or integer.
pub const Kind = union(enum) {
    response: struct { id: i64, result: ?Value, err: ?Value },
    request: struct { id: Id, method: []const u8, params: ?Value },
    notification: struct { method: []const u8, params: ?Value },
    unknown,
};

pub fn classify(v: Value) Kind {
    const id = getInt(v, "id");
    const method = getStr(v, "method");
    if (method) |m| {
        if (getId(v, "id")) |i| return .{ .request = .{ .id = i, .method = m, .params = getField(v, "params") } };
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
    const a = try readBody(gpa, &r);
    defer gpa.free(a);
    try testing.expectEqualStrings("hello", a);
    const b = try readBody(gpa, &r);
    defer gpa.free(b);
    try testing.expectEqualStrings("hi", b);
    try testing.expectError(error.Closed, readBody(gpa, &r));
    var bad = Io.Reader.fixed("Content-Length: nope\r\n\r\n");
    try testing.expectError(error.BadFrame, readBody(gpa, &bad));
    var short = Io.Reader.fixed("Content-Length: 9\r\n\r\nabc");
    try testing.expectError(error.Closed, readBody(gpa, &short));
}

test "a frame over max_body is dropped whole, named by its head, and the frame behind it still reads" {
    const gpa = testing.allocator;
    const n = max_body + 1;
    // The head carries the method, as a real notification's does.
    const head = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"x\":\"";
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.print(gpa, "Content-Length: {d}\r\n\r\n", .{n});
    try stream.appendSlice(gpa, head);
    try stream.appendNTimes(gpa, 'y', n - head.len);
    try stream.appendSlice(gpa, "Content-Length: 2\r\n\r\nhi");
    var r = Io.Reader.fixed(stream.items);
    const first = try readFrame(gpa, &r);
    try testing.expect(first == .oversize);
    defer gpa.free(first.oversize.head);
    try testing.expectEqual(n, first.oversize.len);
    try testing.expectEqual(head_peek, first.oversize.head.len);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", peekMethod(first.oversize.head).?);
    try testing.expect(peekId(first.oversize.head) == null);
    try testing.expectEqual(@as(i64, 41), peekId("{\"jsonrpc\":\"2.0\",\"id\":41,\"result\":[").?);
    // The stream is still in step: the next frame reads.
    const second = try readBody(gpa, &r);
    defer gpa.free(second);
    try testing.expectEqualStrings("hi", second);
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
    try testing.expectEqual(@as(i64, 7), classify(p2.value).request.id.int);
    var p3 = try std.json.parseFromSlice(Value, testing.allocator, "{\"method\":\"textDocument/publishDiagnostics\"}", .{});
    defer p3.deinit();
    try testing.expectEqualStrings("textDocument/publishDiagnostics", classify(p3.value).notification.method);
}

test "classify: a server's request with a STRING id is a request, not a notification, and the id echoes back as JSON" {
    // zls asks `workspace/configuration` with `"id":"i_haz_configuration"`;
    // read as an integer it was null, so the request was filed as a
    // notification and never answered — and zls, waiting on that reply
    // for its `zig_lib_path`, answered null for everything in std.
    var p = try std.json.parseFromSlice(Value, testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"i_haz_configuration\",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"zls\"}]}}", .{});
    defer p.deinit();
    const k = classify(p.value);
    try testing.expect(k == .request);
    try testing.expectEqualStrings("workspace/configuration", k.request.method);
    try testing.expectEqualStrings("i_haz_configuration", k.request.id.str);
    const echoed = try k.request.id.json(testing.allocator);
    defer testing.allocator.free(echoed);
    try testing.expectEqualStrings("\"i_haz_configuration\"", echoed);
    // The escape is JSON's: a quote or a backslash in the id survives.
    const tricky: Id = .{ .str = "a\"b\\c" };
    const esc = try tricky.json(testing.allocator);
    defer testing.allocator.free(esc);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", esc);
    const num: Id = .{ .int = 41 };
    const plain = try num.json(testing.allocator);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("41", plain);
    try testing.expect(Id.eql(.{ .str = "x" }, .{ .str = "x" }));
    try testing.expect(!Id.eql(.{ .str = "1" }, .{ .int = 1 }));
    // A null id with a method is still a notification.
    var q = try std.json.parseFromSlice(Value, testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}", .{});
    defer q.deinit();
    try testing.expect(classify(q.value) == .notification);
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
    /// The last frame the transport dropped for being over `max_body`.
    dropped: std.atomic.Value(usize) = .init(0),
    dropped_method: std.ArrayListUnmanaged(u8) = .empty,

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
    fn onOversize(ctx: *anyopaque, len: usize, head: []const u8) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        c.lock.lockUncancelable(testing.io);
        defer c.lock.unlock(testing.io);
        if (peekMethod(head)) |m| c.dropped_method.appendSlice(c.gpa, m) catch {};
        c.dropped.store(len, .release);
        c.arrived.set(testing.io);
    }
    fn sink(c: *Collector) Sink {
        return .{ .ctx = c, .message = onMessage, .closed = onClosed, .oversize = onOversize };
    }
    fn count(c: *Collector) usize {
        c.lock.lockUncancelable(testing.io);
        defer c.lock.unlock(testing.io);
        return c.got.items.len;
    }
    fn deinit(c: *Collector) void {
        for (c.got.items) |m| m.destroy(c.gpa);
        c.got.deinit(c.gpa);
        c.dropped_method.deinit(c.gpa);
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
    return fakeEchoServerPaced(io, gpa, in, out, 0);
}

/// The same, taking `pause_ms` over each frame — a server that reads
/// slower than the client sends.
fn fakeEchoServerPaced(io: Io, gpa: Allocator, in: Io.File, out: Io.File, pause_ms: u64) Io.Cancelable!void {
    var buf: [4096]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    while (true) {
        const body = readBody(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        if (pause_ms > 0) try io.sleep(.fromMilliseconds(@intCast(pause_ms)), .awake);
        var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        switch (classify(parsed.value)) {
            .request => |rq| {
                const reply = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"echo\":\"{s}\"}}}}", .{ rq.id.int, rq.method }) catch return;
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

/// A server whose first frame is far over `max_body`, followed by one
/// that is not.
fn fakeFloodServer(io: Io, gpa: Allocator, out: Io.File) Io.Cancelable!void {
    const n = max_body + 4096;
    const head = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":\"";
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    body.appendSlice(gpa, head) catch return;
    body.appendNTimes(gpa, 'y', n - head.len) catch return;
    writeFrame(io, out, body.items) catch return;
    writeFrame(io, out, "{\"jsonrpc\":\"2.0\",\"method\":\"pong\"}") catch return;
}

test "a reply over max_body is dropped and named; the server stays up and the next frame arrives" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s2c = try pipeFiles();
    const c2s = try pipeFiles();
    var server_group: Io.Group = .init;
    try server_group.concurrent(io, fakeFloodServer, .{ io, gpa, s2c[1] });
    const t = try Transport.initFiles(gpa, io, c2s[1], s2c[0]);
    defer t.shutdown();
    var col: Collector = .{ .gpa = gpa };
    defer col.deinit();
    try t.start(col.sink());
    // The frame behind the dropped one lands, which is the whole point:
    // the stream stayed in step and the reader task is still running.
    try col.waitFor(1);
    try testing.expectEqualStrings("pong", classify(col.got.items[0].root()).notification.method);
    try testing.expectEqual(max_body + 4096, col.dropped.load(.acquire));
    try testing.expectEqualStrings("textDocument/publishDiagnostics", col.dropped_method.items);
    try testing.expect(!t.isDead());
    try server_group.await(io);
    s2c[1].close(io);
    c2s[0].close(io);
}

test "the writer task: 200 frames leave in order and `send` never touches the pipe; a goodbye queued just before shutdown still lands" {
    const gpa = testing.allocator;
    const io = testing.io;
    const c2s = try pipeFiles();
    const s2c = try pipeFiles();
    var server_group: Io.Group = .init;
    try server_group.concurrent(io, fakeEchoServerPaced, .{ io, gpa, c2s[0], s2c[1], 1 });
    const t = try Transport.initFiles(gpa, io, c2s[1], s2c[0]);
    var col: Collector = .{ .gpa = gpa };
    defer col.deinit();
    try t.start(col.sink());
    // More frames than the ring holds, 1.6 MB against a server that
    // takes a millisecond over each: `send` returns as the bodies are
    // copied, and the loop is out while the writer task is still
    // pushing them through — a synchronous send would have sat on the
    // pipe until the server had read all but the last few.
    const pad = try gpa.alloc(u8, 8 * 1024);
    defer gpa.free(pad);
    @memset(pad, 'x');
    var ids: [200]i64 = undefined;
    for (&ids) |*id| {
        id.* = t.allocId();
        try t.expect(id.*, .{ .kind = 1 });
        const req = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"m{d}\",\"params\":{{\"pad\":\"{s}\"}}}}", .{ id.*, id.*, pad });
        defer gpa.free(req);
        try t.send(req);
    }
    try testing.expect(t.frames_out.load(.acquire) < ids.len);
    var spins: usize = 0;
    while (col.count() < ids.len and !col.closed.load(.acquire)) : (spins += 1) {
        if (spins > 1000) return error.Timeout;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(ids.len, col.count());
    try testing.expectEqual(@as(u32, ids.len), t.frames_out.load(.acquire));
    for (col.got.items, 0..) |m, i| try testing.expectEqual(ids[i], classify(m.root()).response.id);
    // `exit` is queued and the transport shut down at once: the writer
    // drains it before the cancel, and the server leaves on it.
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    t.shutdown();
    try server_group.await(io);
    c2s[0].close(io);
    s2c[1].close(io);
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
