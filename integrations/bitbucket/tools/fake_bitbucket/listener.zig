//! The socket around `server.zig`. A thread accepts, `std.http.Server`
//! parses, `server.handle` answers. `start` takes port 0 and reports
//! the one the OS gave, so a test never picks a number and two runs
//! never collide; `stop` wakes the accept with a connection of its own,
//! the way mnml's own mock server does.
//!
//! The `State` is shared: a test reads `srv.state` after driving the
//! client to see the approval that landed or the comment that was
//! posted, under `state_lock`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const bb = @import("server.zig");

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    listener: Io.net.Server,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    state: bb.State = .{},
    state_lock: Io.Mutex = .init,
    /// The arena the replies are built on, reset per request.
    arena: std.heap.ArenaAllocator,
    /// The clock has been taken. See `serveOne`.
    clock_set: bool = false,
    /// Where `--log-file` appends one JSON line per request served;
    /// null is no log. Borrowed from the argv, which outlives us.
    log_path: ?[]const u8 = null,
    /// `--delay-ms`: hold every reply this long before it goes out, so
    /// a pane can be caught with its fetch in flight — the one screen
    /// the loopback is otherwise too fast to paint.
    delay_ms: u32 = 0,

    pub fn start(gpa: Allocator, io: Io, port: u16) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var listener = try addr.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .port = listener.socket.address.getPort(),
            .listener = listener,
            .thread = undefined,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        self.thread.join();
        self.listener.deinit(self.io);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// `http://127.0.0.1:<port>/2.0` — an API root, the shape
    /// `BITBUCKET_BASE_URL` wants. Owned by the caller.
    pub fn baseUrl(self: *const Server, gpa: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/2.0", .{self.port});
    }

    /// Answer the next `n` requests with a 429.
    pub fn rateLimitNext(self: *Server, n: u32) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        self.state.rate_limit_next = n;
    }

    /// The `Retry-After` those 429s carry; 0 sends none.
    pub fn retryAfter(self: *Server, secs: u32) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        self.state.rate_limit_retry_after = secs;
    }

    /// Send `X-RateLimit-*` on every answer: `limit`, and a remaining
    /// that starts at `remaining` and drops by one per request.
    pub fn budgetHeaders(self: *Server, limit: u32, remaining: u32) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        self.state.budget_limit = limit;
        self.state.budget_remaining = remaining;
    }

    /// N more generated OPEN pull requests on `acme/api`, so a
    /// measurement runs against a workspace the size of a real one.
    pub fn setExtraPrs(self: *Server, n: u32) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        self.state.extra_prs = n;
    }

    /// Answer every request whose path contains `path` ("" = all) with
    /// a 500 until `failPaths(null)`.
    pub fn failPaths(self: *Server, path: ?[]const u8) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        if (path) |p| {
            const n = @min(p.len, self.state.fail_path_buf.len);
            @memcpy(self.state.fail_path_buf[0..n], p[0..n]);
            self.state.fail_path_len = @intCast(n);
            self.state.failing = true;
        } else self.state.failing = false;
    }

    /// When answers go out gzipped (`State.Gzip`).
    pub fn gzipAnswers(self: *Server, mode: bb.Gzip) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        self.state.gzip = mode;
    }

    /// Answer `/2.0/user` with a 403 from now on.
    pub fn denyUser(self: *Server, on: bool) void {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        self.state.deny_user = on;
    }

    /// A copy of the state as it stands — what the pane's writes did.
    pub fn snapshot(self: *Server) bb.State {
        self.state_lock.lockUncancelable(self.io);
        defer self.state_lock.unlock(self.io);
        return self.state;
    }

    fn loop(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            // A connection the client gave up on before it was taken
            // (ECONNABORTED under load), a moment out of descriptors:
            // the next accept may be fine. Breaking here stopped the
            // whole fake for the rest of the file, and every later
            // request of the pane under test failed.
            const stream = self.listener.accept(self.io) catch {
                if (self.stopping.load(.acquire)) break;
                self.io.sleep(.fromMilliseconds(10), .awake) catch {};
                continue;
            };
            defer stream.close(self.io);
            if (self.stopping.load(.acquire)) break;
            self.serveOne(stream) catch {};
        }
    }

    fn serveOne(self: *Server, stream: Io.net.Stream) !void {
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var writer = stream.writer(self.io, &wbuf);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http.receiveHead() catch return;

        // `head.target` and the header values point into the reader's
        // buffer, and reading the body refills it — copy both out
        // first or the routing walks freed bytes.
        var target_buf: [2048]u8 = undefined;
        const tlen = @min(request.head.target.len, target_buf.len);
        @memcpy(target_buf[0..tlen], request.head.target[0..tlen]);
        const target = target_buf[0..tlen];
        const method = bb.methodOf(@tagName(request.head.method));

        var auth_buf: [1024]u8 = undefined;
        var auth: []const u8 = "";
        var inm_buf: [256]u8 = undefined;
        var inm: []const u8 = "";
        var wants_gzip = false;
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) wants_gzip = acceptsGzip(h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "authorization") and h.value.len <= auth_buf.len) {
                @memcpy(auth_buf[0..h.value.len], h.value);
                auth = auth_buf[0..h.value.len];
            }
            if (std.ascii.eqlIgnoreCase(h.name, "if-none-match") and h.value.len <= inm_buf.len) {
                @memcpy(inm_buf[0..h.value.len], h.value);
                inm = inm_buf[0..h.value.len];
            }
        }
        var body_buf: [64 * 1024]u8 = undefined;
        var body: []const u8 = "";
        // Only read a body the method can actually carry. For a method
        // with none, `readerExpectNone` hands back `Reader.ending` — a
        // `@constCast` of a const global — and reading from it writes
        // `seek` back through that const pointer: a segfault on Linux,
        // silently tolerated on macOS.
        if (request.head.method.requestHasBody()) {
            if (request.head.content_length) |n| {
                if (n > 0 and n <= body_buf.len) {
                    const br = request.readerExpectContinue(&.{}) catch request.readerExpectNone(&.{});
                    const got = br.readSliceShort(body_buf[0..@intCast(n)]) catch 0;
                    body = body_buf[0..got];
                }
            }
        }

        self.state_lock.lockUncancelable(self.io);
        _ = self.arena.reset(.retain_capacity);
        // Every relative date is written against the clock as it stood
        // when the server answered its FIRST request, not against the
        // clock now.
        //
        // A pull request's `updated_on` does not move by itself, and a
        // fake whose bodies drift a second at a time can never be
        // answered `304 Not Modified` — which would make a conditional
        // GET untestable and, worse, quietly wrong in a measurement.
        if (!self.clock_set) {
            self.state.now_secs = Io.Timestamp.now(self.io, .real).toSeconds();
            self.clock_set = true;
        }
        var reply = bb.handle(self.arena.allocator(), &self.state, .{
            .method = method,
            .target = target,
            .body = body,
            .authorization = auth,
            .if_none_match = inm,
        }) catch bb.Reply{ .status = 500, .body = "{\"error\":{\"message\":\"out of memory\"}}" };
        const plain_len = reply.body.len;
        const gzip = switch (self.state.gzip) {
            .off => false,
            .when_asked => wants_gzip,
            .always => true,
        } and reply.body.len > 0;
        var gzipped = false;
        if (gzip) {
            if (gzipBody(self.arena.allocator(), reply.body)) |z| {
                reply.body = z;
                gzipped = true;
                self.state.gzipped += 1;
            } else |_| {}
        }
        self.state_lock.unlock(self.io);

        var extra: [7]std.http.Header = undefined;
        var n_extra: usize = 1;
        extra[0] = .{ .name = "content-type", .value = reply.content_type };
        if (gzipped) {
            extra[n_extra] = .{ .name = "content-encoding", .value = "gzip" };
            n_extra += 1;
        }
        var ra_buf: [8]u8 = undefined;
        if (reply.retry_after_secs) |secs| {
            extra[n_extra] = .{ .name = "retry-after", .value = std.fmt.bufPrint(&ra_buf, "{d}", .{secs}) catch "1" };
            n_extra += 1;
        }
        if (reply.etag.len > 0) {
            extra[n_extra] = .{ .name = "etag", .value = reply.etag };
            n_extra += 1;
        }
        var lim_buf: [12]u8 = undefined;
        var rem_buf: [12]u8 = undefined;
        if (reply.budget) |b| {
            extra[n_extra] = .{ .name = "x-ratelimit-limit", .value = std.fmt.bufPrint(&lim_buf, "{d}", .{b.limit}) catch "0" };
            extra[n_extra + 1] = .{ .name = "x-ratelimit-remaining", .value = std.fmt.bufPrint(&rem_buf, "{d}", .{b.remaining}) catch "0" };
            extra[n_extra + 2] = .{ .name = "x-ratelimit-nearlimit", .value = if (b.near) "true" else "false" };
            n_extra += 3;
        }
        // The log keeps the plain size, whatever went out on the wire.
        self.logRequest(method, target, reply.status, plain_len);
        if (self.delay_ms > 0) self.io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch {};
        request.respond(reply.body, .{
            .status = @enumFromInt(reply.status),
            .extra_headers = extra[0..n_extra],
            .keep_alive = false,
        }) catch {};
    }

    /// One JSON line appended to `--log-file`: what arrived on the
    /// wire, which is the only account of a tab's cost that owes
    /// nothing to what the client believes it sent. Best effort — a
    /// server that cannot write its log still serves.
    fn logRequest(self: *Server, method: bb.Method, target: []const u8, status: u16, bytes: usize) void {
        const path = self.log_path orelse return;
        const cut = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        var buf: [3072]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"method\":\"{s}\",\"path\":\"{f}\",\"query\":\"{f}\",\"status\":{d},\"bytes\":{d}}}\n", .{
            @tagName(method),
            std.zig.fmtString(target[0..cut]),
            std.zig.fmtString(if (cut < target.len) target[cut + 1 ..] else ""),
            status,
            bytes,
        }) catch return;
        const file = Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = false, .lock = .exclusive }) catch return;
        defer file.close(self.io);
        const end = file.length(self.io) catch 0;
        file.writePositionalAll(self.io, line, end) catch {};
    }
};

/// True when an `Accept-Encoding` value offers gzip: `gzip` (or
/// `x-gzip`, or `*`) in the list, and not refused with `q=0`.
pub fn acceptsGzip(value: []const u8) bool {
    var items = std.mem.tokenizeScalar(u8, value, ',');
    while (items.next()) |item| {
        var parts = std.mem.tokenizeScalar(u8, item, ';');
        const name = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (!std.ascii.eqlIgnoreCase(name, "gzip") and !std.ascii.eqlIgnoreCase(name, "x-gzip") and !std.mem.eql(u8, name, "*")) continue;
        var refused = false;
        while (parts.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (std.mem.startsWith(u8, p, "q=") and (std.fmt.parseFloat(f32, p[2..]) catch 1) == 0) refused = true;
        }
        if (!refused) return true;
    }
    return false;
}

/// `body` as a gzip stream, on `arena`.
pub fn gzipBody(arena: Allocator, body: []const u8) (Allocator.Error || Io.Writer.Error)![]const u8 {
    const flate = std.compress.flate;
    var out: Io.Writer.Allocating = try .initCapacity(arena, body.len + 64);
    const window = try arena.alloc(u8, flate.max_window_len);
    // The compressor's match tables run past a hundred kilobytes: on
    // the arena, not on the accept thread's stack.
    const z = try arena.create(flate.Compress);
    z.* = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try z.writer.writeAll(body);
    try z.finish();
    return out.written();
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the listener answers a real HTTP request on an ephemeral port" {
    const io = t.io;
    const srv = try Server.start(t.allocator, io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    try t.expect(std.mem.startsWith(u8, base, "http://127.0.0.1:"));
    try t.expect(std.mem.endsWith(u8, base, "/2.0"));

    const url = try std.fmt.allocPrint(t.allocator, "{s}/user", .{base});
    defer t.allocator.free(url);
    var client: std.http.Client = .{ .allocator = t.allocator, .io = io };
    defer client.deinit();
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &out.writer,
        .extra_headers = &.{.{ .name = "authorization", .value = "Basic dXNlcjp0b2tlbg==" }},
        .keep_alive = false,
    });
    try t.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try t.expect(std.mem.indexOf(u8, out.written(), "acct-max") != null);
}

test "a request with no credentials comes back 401 over the wire too" {
    const io = t.io;
    const srv = try Server.start(t.allocator, io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    const url = try std.fmt.allocPrint(t.allocator, "{s}/user", .{base});
    defer t.allocator.free(url);
    var client: std.http.Client = .{ .allocator = t.allocator, .io = io };
    defer client.deinit();
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const res = try client.fetch(.{ .location = .{ .url = url }, .method = .GET, .response_writer = &out.writer, .keep_alive = false });
    try t.expectEqual(@as(u16, 401), @intFromEnum(res.status));
    try t.expectEqual(@as(u32, 1), srv.snapshot().unauthorized);
}

test "--gzip: an Accept-Encoding that offers gzip is read as one, and the body round-trips through the std decompressor" {
    try t.expect(acceptsGzip("gzip, deflate"));
    try t.expect(acceptsGzip("deflate, GZIP;q=0.5"));
    try t.expect(acceptsGzip("*"));
    try t.expect(!acceptsGzip("identity"));
    try t.expect(!acceptsGzip("gzip;q=0"));

    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const plain = "{\"values\":[{\"id\":1234,\"title\":\"Fix the login redirect\"},{\"id\":1198,\"title\":\"Fix the login redirect again\"}]}";
    const z = try gzipBody(a.allocator(), plain);
    try t.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, z[0..2]);
    var in: Io.Reader = .fixed(z);
    const window = try a.allocator().alloc(u8, std.compress.flate.max_window_len);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    var back: Io.Writer.Allocating = .init(a.allocator());
    _ = try d.reader.streamRemaining(&back.writer);
    try t.expectEqualStrings(plain, back.written());
}

test "stop wakes an accept nobody ever connected to — what makes --lifetime-secs real" {
    const io = t.io;
    const srv = try Server.start(t.allocator, io, 0);
    // No client, ever: the accept thread is parked. `stop` knocks on the
    // port itself, so the join comes back instead of holding the process
    // open until someone kills it.
    const started = Io.Timestamp.now(io, .real).toMilliseconds();
    srv.stop();
    try t.expect(Io.Timestamp.now(io, .real).toMilliseconds() - started < 5000);
}
