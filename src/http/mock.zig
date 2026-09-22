//! Mocks: a frozen response saved beside a request file as
//! `<source>.mock.json` (`status`, `status_text`, `headers` as
//! `[[name, value]]`, `body`, `ts`), replayed into the pane as if the
//! server had answered. And `Server`: a tiny HTTP/1.1 server on a
//! local port that answers every request with one mock and remembers
//! the last request it saw — the client's round-trip test and the
//! `mock.serve` command run on it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");

pub const Header = parse.Header;

pub const Mock = struct {
    status: u16,
    status_text: []u8,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Mock, gpa: Allocator) void {
        gpa.free(self.status_text);
        for (self.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.headers);
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// `<source>.mock.json`.
pub fn sidecarPath(alloc: Allocator, source: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(alloc, u8, &.{ source, ".mock.json" });
}

pub const LoadError = error{ MissingStatus, NotJson } || Allocator.Error || Io.File.OpenError || Io.File.ReadError || error{ StreamTooLong, FileTooBig };

/// Read a mock file. Everything but `status` is optional.
pub fn load(gpa: Allocator, io: Io, path: []const u8) !Mock {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(text);
    return loadText(gpa, text);
}

pub fn loadText(gpa: Allocator, text: []const u8) !Mock {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.NotJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotJson,
    };
    const status_v = obj.get("status") orelse return error.MissingStatus;
    const status: u16 = switch (status_v) {
        .integer => |i| @intCast(std.math.clamp(i, 0, 999)),
        else => return error.MissingStatus,
    };
    const text_of = struct {
        fn f(v: ?std.json.Value) []const u8 {
            return if (v) |x| switch (x) {
                .string => |s| s,
                else => "",
            } else "";
        }
    }.f;
    var mock: Mock = .{ .status = status, .status_text = try gpa.dupe(u8, text_of(obj.get("status_text"))), .headers = &.{}, .body = undefined };
    errdefer gpa.free(mock.status_text);
    mock.body = try gpa.dupe(u8, text_of(obj.get("body")));
    errdefer gpa.free(mock.body);
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        headers.deinit(gpa);
    }
    if (obj.get("headers")) |hv| switch (hv) {
        .array => |arr| for (arr.items) |pair| switch (pair) {
            .array => |p| if (p.items.len >= 2) {
                const n = try gpa.dupe(u8, text_of(p.items[0]));
                errdefer gpa.free(n);
                const v = try gpa.dupe(u8, text_of(p.items[1]));
                errdefer gpa.free(v);
                try headers.append(gpa, .{ .name = n, .value = v });
            },
            .object => |o| {
                const n = try gpa.dupe(u8, text_of(o.get("name")));
                errdefer gpa.free(n);
                const v = try gpa.dupe(u8, text_of(o.get("value")));
                errdefer gpa.free(v);
                try headers.append(gpa, .{ .name = n, .value = v });
            },
            else => {},
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const n = try gpa.dupe(u8, e.key_ptr.*);
                errdefer gpa.free(n);
                const v = try gpa.dupe(u8, text_of(e.value_ptr.*));
                errdefer gpa.free(v);
                try headers.append(gpa, .{ .name = n, .value = v });
            }
        },
        else => {},
    };
    mock.headers = try headers.toOwnedSlice(gpa);
    return mock;
}

/// Serialise a mock, pretty-printed, `ts` = now in ms.
pub fn render(gpa: Allocator, status: u16, status_text: []const u8, headers: []const Header, body: []const u8, ts_ms: i64) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    js.beginObject() catch return error.OutOfMemory;
    js.objectField("status") catch return error.OutOfMemory;
    js.write(status) catch return error.OutOfMemory;
    js.objectField("status_text") catch return error.OutOfMemory;
    js.write(status_text) catch return error.OutOfMemory;
    js.objectField("headers") catch return error.OutOfMemory;
    js.beginArray() catch return error.OutOfMemory;
    for (headers) |h| {
        js.beginArray() catch return error.OutOfMemory;
        js.write(h.name) catch return error.OutOfMemory;
        js.write(h.value) catch return error.OutOfMemory;
        js.endArray() catch return error.OutOfMemory;
    }
    js.endArray() catch return error.OutOfMemory;
    js.objectField("body") catch return error.OutOfMemory;
    js.write(body) catch return error.OutOfMemory;
    js.objectField("ts") catch return error.OutOfMemory;
    js.write(ts_ms) catch return error.OutOfMemory;
    js.endObject() catch return error.OutOfMemory;
    return gpa.dupe(u8, aw.written());
}

pub fn save(gpa: Allocator, io: Io, path: []const u8, status: u16, status_text: []const u8, headers: []const Header, body: []const u8) !void {
    const ts: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_ms));
    const text = try render(gpa, status, status_text, headers, body, ts);
    defer gpa.free(text);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

// ─── the local server ───────────────────────────────────────────────────

pub const Canned = struct {
    status: u16 = 200,
    status_text: []const u8 = "OK",
    headers: []const struct { name: []const u8, value: []const u8 } = &.{},
    body: []const u8 = "",
    /// When set, the body is these pieces written one at a time with
    /// `chunk_delay_ms` between them — no `content-length`, the socket
    /// closes at the end (an SSE server's shape), or `chunked` framing
    /// when `chunked` is set.
    chunks: ?[]const []const u8 = null,
    chunk_delay_ms: u32 = 0,
    chunked: bool = false,
    /// The first chunk goes out in the head's own write, no delay — a
    /// server whose first event shares a packet with its head.
    first_with_head: bool = false,
    /// The answer to the request after this one (a redirect hop, then
    /// its target). The last link of the chain answers every request
    /// from then on.
    next: ?*const Canned = null,
    /// The body is the request as it arrived — the request line, the
    /// headers, a blank line, the body — as `text/plain`; `body` and
    /// `chunks` are ignored. What a test reads to see what went out.
    echo: bool = false,
};

/// One accept loop on its own thread. Every connection gets the canned
/// response; the last request's head + body are kept for inspection.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    server: Io.net.Server,
    canned: Canned,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Requests served so far.
    served: std.atomic.Value(u32) = .init(0),
    last: std.ArrayListUnmanaged(u8) = .empty,
    last_lock: Io.Mutex = .init,

    /// Listen on 127.0.0.1:`port` (0 = any free port) and start serving.
    pub fn start(gpa: Allocator, io: Io, canned: Canned) !*Server {
        return startOn(gpa, io, 0, canned);
    }

    pub fn startOn(gpa: Allocator, io: Io, port: u16, canned: Canned) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .port = server.socket.address.getPort(), .server = server, .canned = canned, .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, loop, .{ self, io });
        return self;
    }

    /// Stop accepting, wake the loop, join, free.
    pub fn stop(self: *Server, io: Io) void {
        self.stopping.store(true, .release);
        // A connection of our own unblocks `accept`.
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        self.thread.join();
        self.server.deinit(io);
        self.last.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The last request as it arrived (head + body). Borrowed; valid
    /// until the next request lands.
    pub fn lastRequest(self: *Server) []const u8 {
        self.last_lock.lockUncancelable(self.io);
        defer self.last_lock.unlock(self.io);
        return self.last.items;
    }

    fn loop(self: *Server, io: Io) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.accept(io) catch break;
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                break;
            }
            self.serveOne(io, stream) catch {};
            stream.close(io);
        }
    }

    fn serveOne(self: *Server, io: Io, stream: Io.net.Stream) !void {
        var rbuf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
        const r = &reader.interface;
        var req: std.ArrayListUnmanaged(u8) = .empty;
        defer req.deinit(self.gpa);
        // Head: up to the blank line.
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch break;
            try req.appendSlice(self.gpa, line);
            if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        }
        // Body: Content-Length bytes.
        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, req.items, "\r\n");
        while (lines.next()) |l| {
            if (std.ascii.startsWithIgnoreCase(l, "content-length:")) {
                content_length = std.fmt.parseInt(usize, std.mem.trim(u8, l["content-length:".len..], " \t"), 10) catch 0;
            }
        }
        if (content_length > 0) {
            const body = try self.gpa.alloc(u8, content_length);
            defer self.gpa.free(body);
            r.readSliceAll(body) catch {};
            try req.appendSlice(self.gpa, body);
        }
        {
            self.last_lock.lockUncancelable(io);
            defer self.last_lock.unlock(io);
            self.last.clearRetainingCapacity();
            try self.last.appendSlice(self.gpa, req.items);
        }
        const nth = self.served.fetchAdd(1, .monotonic);
        var canned: *const Canned = &self.canned;
        for (0..nth) |_| canned = canned.next orelse break;
        var wbuf: [16 * 1024]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
        const w = &writer.interface;
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ canned.status, canned.status_text });
        for (canned.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        if (canned.echo) {
            try w.print("content-type: text/plain\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{req.items.len});
            try w.writeAll(req.items);
            try w.flush();
            return;
        }
        if (canned.chunks) |chunks| {
            if (canned.chunked) try w.writeAll("transfer-encoding: chunked\r\n");
            try w.writeAll("connection: close\r\n\r\n");
            if (!canned.first_with_head) try w.flush();
            for (chunks, 0..) |c, ci| {
                if (self.stopping.load(.acquire)) return;
                if (canned.chunk_delay_ms > 0 and !(ci == 0 and canned.first_with_head)) Io.sleep(io, .fromMilliseconds(canned.chunk_delay_ms), .awake) catch {};
                if (canned.chunked) try w.print("{x}\r\n{s}\r\n", .{ c.len, c }) else try w.writeAll(c);
                try w.flush();
            }
            if (canned.chunked) try w.writeAll("0\r\n\r\n");
            try w.flush();
            return;
        }
        try w.print("content-length: {d}\r\nconnection: close\r\n\r\n", .{canned.body.len});
        try w.writeAll(canned.body);
        try w.flush();
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "mock file: render then load round-trips; the three header shapes load" {
    const gpa = testing.allocator;
    const hs = [_]Header{.{ .name = @constCast("content-type"), .value = @constCast("application/json") }};
    const text = try render(gpa, 418, "I'm a teapot", &hs, "{\"name\":42}", 1);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"status\": 418") != null);
    var m = try loadText(gpa, text);
    defer m.deinit(gpa);
    try testing.expectEqual(@as(u16, 418), m.status);
    try testing.expectEqualStrings("I'm a teapot", m.status_text);
    try testing.expectEqualStrings("application/json", m.headers[0].value);
    try testing.expectEqualStrings("{\"name\":42}", m.body);
    var m2 = try loadText(gpa, "{\"status\":200,\"headers\":{\"a\":\"1\"},\"body\":\"x\"}");
    defer m2.deinit(gpa);
    try testing.expectEqualStrings("a", m2.headers[0].name);
    var m3 = try loadText(gpa, "{\"status\":200,\"headers\":[{\"name\":\"b\",\"value\":\"2\"}]}");
    defer m3.deinit(gpa);
    try testing.expectEqualStrings("2", m3.headers[0].value);
    try testing.expectError(error.MissingStatus, loadText(gpa, "{}"));
    try testing.expectError(error.NotJson, loadText(gpa, "nope"));
    const side = try sidecarPath(gpa, "/w/a.curl");
    defer gpa.free(side);
    try testing.expectEqualStrings("/w/a.curl.mock.json", side);
}

test "server: start, answer a raw request, stop" {
    const io = testing.io;
    var server = try Server.start(testing.allocator, io, .{ .status = 201, .status_text = "Created", .body = "made" });
    defer server.stop(io);
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(server.port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
    try writer.interface.writeAll("GET /x HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try writer.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
    var sink: Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    _ = try reader.interface.streamRemaining(&sink.writer);
    try testing.expect(std.mem.startsWith(u8, sink.written(), "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.endsWith(u8, sink.written(), "\r\n\r\nmade"));
    try testing.expectEqual(@as(u32, 1), server.served.load(.monotonic));
    try testing.expect(std.mem.startsWith(u8, server.lastRequest(), "GET /x HTTP/1.1"));
}
