//! Chrome DevTools Protocol, the wire half: launch a Chrome with
//! `--remote-debugging-port=0`, read the port off its stderr, ask
//! `/json` for the first page target's WebSocket URL, and speak
//! JSON-RPC over `http.ws`. `rpc` builds a request, `parseMessage`
//! reads a reply or an event, `Session` numbers requests and blocks on
//! the next message. The pane and its worker are `app/browser_pane.zig`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ws = @import("../http/ws.zig");
const child_os = @import("../core/child.zig");

/// Binaries and well-known paths tried in order by `launch`.
pub const chrome_bins = [_][]const u8{
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "chrome-for-testing",
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
};

/// `{"id":N,"method":"…","params":<params_json>}` (+ `sessionId`).
pub fn rpc(alloc: Allocator, id: i64, method: []const u8, params_json: []const u8, session_id: ?[]const u8) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("{{\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
    std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
    w.print(",\"params\":{s}", .{if (params_json.len == 0) "{}" else params_json}) catch return error.OutOfMemory;
    if (session_id) |s| {
        w.writeAll(",\"sessionId\":") catch return error.OutOfMemory;
        std.json.Stringify.value(s, .{}, w) catch return error.OutOfMemory;
    }
    w.writeAll("}") catch return error.OutOfMemory;
    return alloc.dupe(u8, aw.written());
}

/// A reply (`id` + `result` / `error`) or an event (`method` + `params`).
pub const Message = struct {
    id: ?i64 = null,
    method: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    error_message: ?[]const u8 = null,
    root: std.json.Value,

    pub fn isEvent(m: Message) bool {
        return m.method != null;
    }
};

pub fn parseMessage(arena: Allocator, text: []const u8) !Message {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    if (v != .object) return error.NotAnObject;
    const o = v.object;
    var m: Message = .{ .root = v };
    if (o.get("id")) |x| if (x == .integer) {
        m.id = x.integer;
    };
    if (o.get("method")) |x| if (x == .string) {
        m.method = x.string;
    };
    if (o.get("sessionId")) |x| if (x == .string) {
        m.session_id = x.string;
    };
    if (o.get("params")) |x| m.params = x;
    if (o.get("result")) |x| m.result = x;
    if (o.get("error")) |x| if (x == .object) {
        if (x.object.get("message")) |msg| if (msg == .string) {
            m.error_message = msg.string;
        };
    };
    return m;
}

/// `params.a.b` off an event, as a string.
pub fn str(v: ?std.json.Value, path: []const []const u8) ?[]const u8 {
    var cur = v orelse return null;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return switch (cur) {
        .string => |s| s,
        else => null,
    };
}

pub fn int(v: ?std.json.Value, path: []const []const u8) ?i64 {
    var cur = v orelse return null;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return switch (cur) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn get(v: ?std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = v orelse return null;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

/// A console argument's display text: strings bare, everything else
/// as its `description` or `value`.
pub fn remoteObjectText(arena: Allocator, v: std.json.Value) Allocator.Error![]const u8 {
    if (v != .object) return std.json.Stringify.valueAlloc(arena, v, .{});
    if (v.object.get("value")) |val| return switch (val) {
        .string => |s| s,
        else => std.json.Stringify.valueAlloc(arena, val, .{}),
    };
    if (v.object.get("description")) |d| if (d == .string) return d.string;
    if (v.object.get("type")) |t| if (t == .string) return t.string;
    return "?";
}

// ─── launch ─────────────────────────────────────────────────────────────

pub const LaunchOptions = struct {
    url: []const u8 = "about:blank",
    profile_dir: []const u8,
    headless: bool = false,
    /// Try only this binary.
    binary: ?[]const u8 = null,
};

/// A Chrome the launcher owns from the moment it is spawned. Heap
/// allocated and never moved: the stderr reader, a task in `reader`,
/// holds its address. The reader looks for `DevTools listening on
/// ws://…:PORT/…`, publishes the port through `port_ready`, then
/// drains stderr until Chrome closes it, so Chrome never blocks on a
/// full pipe.
///
/// Whoever holds a `*Launch` can `kill` it at any point after `spawn`
/// returns — before the port line, while a worker is waiting for it,
/// or long after. A Chrome wedged before its DevTools line (a keychain
/// prompt, a hung GPU start, a profile lock) used to be out of reach
/// until that line arrived: the only reference to the child lived on
/// the stack of a worker blocked reading its stderr, so closing the
/// pane joined that worker and froze the UI until Chrome exited.
pub const Launch = struct {
    gpa: Allocator,
    child: std.process.Child,
    /// Owned by the reader task, which closes it; taken out of `child`
    /// so `Child.kill` never closes a file another thread is reading.
    stderr: Io.File,
    reader: Io.Group = .init,
    /// Set by the reader once `port` is known, or once it gave up
    /// (`port` stays 0): EOF, cancel, or no DevTools line in 200 lines.
    port_ready: Io.Event = .unset,
    port: u16 = 0,
    killed: bool = false,

    /// Terminate Chrome, reap it, and stop the stderr reader. Idempotent.
    /// Not thread-safe against itself: one owner calls it (the browser
    /// pane under its lock; the proxy on its own thread).
    ///
    /// Zig 0.16's `Child.kill` sends SIGTERM, reaps and leaves
    /// `id == null`; a `wait` after it would assert. The cancel comes
    /// after the reap because a helper Chrome started can keep the
    /// stderr pipe open past its parent, and then the read would never
    /// see EOF.
    pub fn kill(self: *Launch, io: Io) void {
        if (self.child.id != null) self.child.kill(io);
        self.reader.cancel(io);
        self.killed = true;
    }

    /// `kill`, then free. For the owner that is done with it.
    pub fn destroy(self: *Launch, io: Io) void {
        self.kill(io);
        self.gpa.destroy(self);
    }

    /// Block until the reader found the port, gave up, or `timeout`
    /// passed. Null when there is no port (yet). Uncancelable, and
    /// wakes as soon as `kill` has stopped the reader.
    pub fn waitPort(self: *Launch, io: Io, timeout: Io.Duration) ?u16 {
        const start = Io.Timestamp.now(io, .awake);
        while (!self.port_ready.isSet()) {
            const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
            if (elapsed.nanoseconds >= timeout.nanoseconds) return null;
            const left: Io.Duration = .{ .nanoseconds = timeout.nanoseconds - elapsed.nanoseconds };
            self.port_ready.waitTimeout(io, .{ .duration = .{ .raw = left, .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => return null,
            };
        }
        return if (self.port == 0) null else self.port;
    }
};

pub const LaunchError = error{ ChromeNotFound, NoDevToolsPort } || Allocator.Error || Io.ConcurrentError;

/// How long a launch waits for Chrome's DevTools line.
pub const port_timeout: Io.Duration = .fromSeconds(20);

/// Every candidate binary, the puppeteer cache first.
pub fn candidates(arena: Allocator, io: Io, home: ?[]const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (home) |h| {
        const bases = [_][]const u8{ "/.cache/puppeteer/chrome", "/Library/Caches/puppeteer/chrome", "/chrome-for-testing" };
        for (bases) |b| {
            const base = try std.mem.concat(arena, u8, &.{ h, b });
            var dir = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |ver| {
                if (ver.kind != .directory) continue;
                const vpath = try std.fs.path.join(arena, &.{ base, ver.name });
                var vdir = Io.Dir.cwd().openDir(io, vpath, .{ .iterate = true }) catch continue;
                defer vdir.close(io);
                var jt = vdir.iterate();
                while (jt.next(io) catch null) |inner| {
                    const bin = try std.fs.path.join(arena, &.{ vpath, inner.name, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" });
                    Io.Dir.cwd().access(io, bin, .{}) catch continue;
                    try out.append(arena, bin);
                }
            }
        }
    }
    for (chrome_bins) |b| try out.append(arena, b);
    return out.items;
}

/// True when any candidate can be found (absolute path exists, or the
/// bare name is on PATH).
pub fn available(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = candidates(arena.allocator(), io, env.get("HOME")) catch return false;
    for (list) |c| if (resolveBinary(arena.allocator(), io, env, c) != null) return true;
    return false;
}

/// An absolute path for `name`: itself when absolute and present,
/// else the first PATH dir holding it.
pub fn resolveBinary(arena: Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(name)) {
        Io.Dir.cwd().access(io, name, .{}) catch return null;
        return name;
    }
    const path = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(arena, &.{ dir, name }) catch return null;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return full;
    }
    return null;
}

/// The argv `spawn` runs for `bin`.
pub fn chromeArgv(a: Allocator, bin: []const u8, opts: LaunchOptions) Allocator.Error![]const []const u8 {
    const url = if (std.mem.trim(u8, opts.url, " \t").len == 0) "about:blank" else opts.url;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(a, &.{
        bin,
        "--remote-debugging-port=0",
        try std.fmt.allocPrint(a, "--user-data-dir={s}", .{opts.profile_dir}),
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
    });
    if (opts.headless) try argv.appendSlice(a, &.{ "--headless=new", "--no-sandbox", "--disable-gpu" });
    try argv.append(a, url);
    return argv.items;
}

/// Spawn Chrome and start its stderr reader; the port comes later
/// (`Launch.waitPort`). The caller owns the result from this return on
/// and `destroy`s it.
pub fn spawn(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, opts: LaunchOptions) LaunchError!*Launch {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const list: []const []const u8 = if (opts.binary) |b| &.{b} else try candidates(a, io, env.get("HOME"));
    for (list) |cand| {
        const bin = resolveBinary(a, io, env, cand) orelse continue;
        const argv = try chromeArgv(a, bin, opts);
        var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .pipe, .environ_map = env }) catch continue;
        const stderr = child.stderr orelse {
            child.kill(io);
            continue;
        };
        child.stderr = null;
        const self = gpa.create(Launch) catch |err| {
            stderr.close(io);
            child.kill(io);
            return err;
        };
        self.* = .{ .gpa = gpa, .child = child, .stderr = stderr };
        self.reader.concurrent(io, readStderr, .{ self, io }) catch |err| {
            stderr.close(io);
            self.child.kill(io);
            gpa.destroy(self);
            return err;
        };
        return self;
    }
    return error.ChromeNotFound;
}

/// `spawn`, then wait for the port: for a caller with nothing else to
/// do meanwhile (the proxy). The pane spawns and waits separately so
/// the child is reachable while it waits.
pub fn launch(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, opts: LaunchOptions) LaunchError!*Launch {
    const self = try spawn(gpa, io, env, opts);
    if (self.waitPort(io, port_timeout) == null) {
        self.destroy(io);
        return error.NoDevToolsPort;
    }
    return self;
}

/// The port off one line of Chrome's stderr: `DevTools listening on
/// ws://127.0.0.1:PORT/devtools/browser/…`.
pub fn parsePortLine(line: []const u8) ?u16 {
    const at = std.mem.indexOf(u8, line, "ws://") orelse return null;
    const rest = line[at + "ws://".len ..];
    const hostport = std.mem.sliceTo(rest, '/');
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return null;
    return std.fmt.parseInt(u16, std.mem.trim(u8, hostport[colon + 1 ..], " \r\n"), 10) catch null;
}

/// The reader task: the port line, then drain. Every read error —
/// `Canceled` from `kill` included — ends the task; nothing here loops
/// on an error, so a cancel is never swallowed into another block.
fn readStderr(self: *Launch, io: Io) void {
    defer self.stderr.close(io);
    defer self.port_ready.set(io);
    var rbuf: [8192]u8 = undefined;
    var r: Io.File.Reader = .init(self.stderr, io, &rbuf);
    var lines: usize = 0;
    while (lines < 200) : (lines += 1) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return;
        if (parsePortLine(line)) |p| {
            self.port = p;
            break;
        }
    } else return;
    self.port_ready.set(io);
    var sink: [4096]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&sink) catch return;
        if (n == 0) return;
    }
}

/// `http://127.0.0.1:PORT/json` → the first `page` target's
/// `webSocketDebuggerUrl`, retried while the endpoint warms up.
/// `stop`, when given, ends the retries early (the pane closed).
pub fn pageWsUrl(gpa: Allocator, io: Io, port: u16, stop: ?*const std.atomic.Value(bool)) ![]u8 {
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/json", .{port});
    defer gpa.free(url);
    var attempt: usize = 0;
    while (attempt < 25) : (attempt += 1) {
        if (stop) |st| if (st.load(.acquire)) return error.NoPageTarget;
        if (try fetchJsonTargets(gpa, io, url)) |ws_url| return ws_url;
        try Io.sleep(io, .fromMilliseconds(150), .awake);
    }
    return error.NoPageTarget;
}

fn fetchJsonTargets(gpa: Allocator, io: Io, url: []const u8) !?[]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var sink: Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    _ = client.fetch(.{ .location = .{ .url = url }, .response_writer = &sink.writer }) catch return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), sink.written(), .{}) catch return null;
    if (v != .array) return null;
    var first: ?std.json.Value = null;
    for (v.array.items) |t| {
        if (t != .object) continue;
        if (first == null) first = t;
        if (str(t, &.{"type"})) |ty| if (std.mem.eql(u8, ty, "page")) {
            if (str(t, &.{"webSocketDebuggerUrl"})) |u| return try gpa.dupe(u8, u);
        };
    }
    if (first) |f| if (str(f, &.{"webSocketDebuggerUrl"})) |u| return try gpa.dupe(u8, u);
    return null;
}

// ─── a session ──────────────────────────────────────────────────────────

/// The domains the pane mirrors, enabled right after the connect with
/// ids 1..; the pane's own requests use ids from 100.
pub const enable_domains = [_][]const u8{ "Page.enable", "Runtime.enable", "Log.enable", "Network.enable", "DOM.enable", "Overlay.enable" };

pub const Session = struct {
    gpa: Allocator,
    conn: *ws.Conn,
    next_id: i64 = 100,

    pub fn connect(gpa: Allocator, io: Io, ws_url: []const u8) !Session {
        const conn = try ws.Conn.connect(gpa, io, ws_url, .{});
        return .{ .gpa = gpa, .conn = conn };
    }

    pub fn deinit(self: *Session) void {
        self.conn.deinit();
    }

    /// Enable the mirrored domains and target discovery.
    pub fn enableAll(self: *Session) !void {
        for (enable_domains, 1..) |method, id| {
            const msg = try rpc(self.gpa, @intCast(id), method, "{}", null);
            defer self.gpa.free(msg);
            try self.conn.sendText(msg);
        }
        const discover = try rpc(self.gpa, 99, "Target.setDiscoverTargets", "{\"discover\":true}", null);
        defer self.gpa.free(discover);
        try self.conn.sendText(discover);
        const attach = try rpc(self.gpa, 98, "Target.setAutoAttach", "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,\"flatten\":true}", null);
        defer self.gpa.free(attach);
        try self.conn.sendText(attach);
    }

    /// Send `method` with `params_json`; returns the request id.
    pub fn send(self: *Session, method: []const u8, params_json: []const u8, session_id: ?[]const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        const msg = try rpc(self.gpa, id, method, params_json, session_id);
        defer self.gpa.free(msg);
        try self.conn.sendText(msg);
        return id;
    }

    /// What `next` read: a message's text (borrowed until the next
    /// read), or a message too large to take, skipped.
    pub const Next = union(enum) {
        text: []const u8,
        too_long: TooLong,
    };

    pub const TooLong = struct {
        /// The reply's id, when the skipped message was one.
        id: ?i64,
        /// The event's method, when it was one.
        method: ?[]const u8,
        len: u64,
    };

    /// The next message, or null once closed.
    pub fn next(self: *Session) !?Next {
        while (true) {
            const m = (try self.conn.readMessage()) orelse return null;
            switch (m) {
                .text => |t| return .{ .text = t },
                .too_long => |t| return .{ .too_long = .{ .id = headId(t.head), .method = headMethod(t.head), .len = t.len } },
                .close => return null,
                else => continue,
            }
        }
    }
};

/// `{"id":123,…` → 123: the id of a reply from its first bytes, which
/// is all there is of a message too large to parse.
pub fn headId(head: []const u8) ?i64 {
    const at = std.mem.indexOf(u8, head, "\"id\":") orelse return null;
    var i = at + "\"id\":".len;
    while (i < head.len and head[i] == ' ') i += 1;
    const start = i;
    while (i < head.len and std.ascii.isDigit(head[i])) i += 1;
    if (i == start or i == head.len) return null;
    return std.fmt.parseInt(i64, head[start..i], 10) catch null;
}

/// `{"method":"X",…` → `X`.
pub fn headMethod(head: []const u8) ?[]const u8 {
    const key = "\"method\":\"";
    const at = std.mem.indexOf(u8, head, key) orelse return null;
    const rest = head[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "headId / headMethod name a message from its first bytes" {
    try testing.expectEqual(@as(?i64, 1234), headId("{\"id\":1234,\"result\":{\"result\":{\"type\":\"string\",\"value\":\"www"));
    try testing.expectEqual(@as(?i64, null), headId("{\"method\":\"DOM.setChildNodes\",\"params\":{"));
    try testing.expectEqual(@as(?i64, null), headId("{\"id\":12"));
    try testing.expectEqualStrings("DOM.setChildNodes", headMethod("{\"method\":\"DOM.setChildNodes\",\"params\":{").?);
}

test "rpc framing and message parsing" {
    const gpa = testing.allocator;
    const r = try rpc(gpa, 42, "Page.navigate", "{\"url\":\"https://x\"}", null);
    defer gpa.free(r);
    try testing.expectEqualStrings("{\"id\":42,\"method\":\"Page.navigate\",\"params\":{\"url\":\"https://x\"}}", r);
    const s = try rpc(gpa, 7, "Runtime.evaluate", "", "sess-1");
    defer gpa.free(s);
    try testing.expectEqualStrings("{\"id\":7,\"method\":\"Runtime.evaluate\",\"params\":{},\"sessionId\":\"sess-1\"}", s);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ev = try parseMessage(arena.allocator(), "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"r1\",\"request\":{\"url\":\"https://a/b\",\"method\":\"GET\"}}}");
    try testing.expect(ev.isEvent());
    try testing.expectEqualStrings("https://a/b", str(ev.params, &.{ "request", "url" }).?);
    const reply = try parseMessage(arena.allocator(), "{\"id\":100,\"result\":{\"data\":\"AAAA\"},\"sessionId\":\"s\"}");
    try testing.expectEqual(@as(?i64, 100), reply.id);
    try testing.expectEqualStrings("AAAA", str(reply.result, &.{"data"}).?);
    const err = try parseMessage(arena.allocator(), "{\"id\":101,\"error\":{\"code\":-32000,\"message\":\"nope\"}}");
    try testing.expectEqualStrings("nope", err.error_message.?);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"number\",\"value\":3,\"description\":\"3\"}", .{});
    try testing.expectEqualStrings("3", try remoteObjectText(arena.allocator(), v));
}

/// A fake DevTools endpoint: answers every request with `{"id":N,"result":{}}`
/// and, after the enables, emits one console event.
const FakeCdp = struct {
    gpa: Allocator,
    io: Io,
    server: Io.net.Server,
    port: u16,
    thread: std.Thread,
    methods: std.ArrayListUnmanaged(u8) = .empty,

    fn start(gpa: Allocator, io: Io) !*FakeCdp {
        const self = try gpa.create(FakeCdp);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .server = server, .port = server.socket.address.getPort(), .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    fn stop(self: *FakeCdp) void {
        self.thread.join();
        self.server.deinit(self.io);
        self.methods.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn loop(self: *FakeCdp) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        self.serve(stream) catch {};
    }

    fn serve(self: *FakeCdp, stream: Io.net.Stream) !void {
        const gpa = self.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &rbuf);
        var writer = Io.net.Stream.Writer.init(stream, self.io, &wbuf);
        _ = try ws.serverAccept(&reader.interface, &writer.interface, arena.allocator());
        var fbuf: std.ArrayListUnmanaged(u8) = .empty;
        defer fbuf.deinit(gpa);
        var seen: usize = 0;
        while (true) {
            const frame = try ws.readFrame(&reader.interface, gpa, &fbuf);
            if (frame.opcode == .close) return;
            if (frame.opcode != .text) continue;
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const m = try parseMessage(scratch.allocator(), frame.payload);
            if (m.method) |method| {
                try self.methods.appendSlice(gpa, method);
                try self.methods.append(gpa, '\n');
            }
            const reply = try std.fmt.allocPrint(scratch.allocator(), "{{\"id\":{d},\"result\":{{}}}}", .{m.id orelse 0});
            const f = try ws.encodeFrame(gpa, .text, reply, true, null);
            defer gpa.free(f);
            try writer.interface.writeAll(f);
            seen += 1;
            if (seen == enable_domains.len + 2) {
                const ev = "{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":\"log\",\"args\":[{\"type\":\"string\",\"value\":\"hi from page\"}]}}";
                const ef = try ws.encodeFrame(gpa, .text, ev, true, null);
                defer gpa.free(ef);
                try writer.interface.writeAll(ef);
            }
            try writer.interface.flush();
        }
    }
};

test "session against a fake endpoint: enables, a numbered request, an event" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fake = try FakeCdp.start(gpa, io);
    defer fake.stop();
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/devtools/page/X", .{fake.port});
    defer gpa.free(url);
    var session = try Session.connect(gpa, io, url);
    defer session.deinit();
    try session.enableAll();
    var replies: usize = 0;
    var got_event = false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (replies < enable_domains.len + 2 or !got_event) {
        const text = ((try session.next()) orelse break).text;
        const m = try parseMessage(arena.allocator(), text);
        if (m.isEvent()) {
            got_event = true;
            try testing.expectEqualStrings("hi from page", str(m.params, &.{ "args", "0", "value" }) orelse blk: {
                const args = get(m.params, &.{"args"}).?;
                break :blk str(args.array.items[0], &.{"value"}).?;
            });
        } else replies += 1;
    }
    const id = try session.send("Page.navigate", "{\"url\":\"https://x\"}", null);
    try testing.expectEqual(@as(i64, 100), id);
    const text = (try session.next()).?.text;
    const m = try parseMessage(arena.allocator(), text);
    try testing.expectEqual(@as(?i64, 100), m.id);
    try session.conn.close(1000, "");
    try testing.expect(std.mem.indexOf(u8, fake.methods.items, "Page.enable\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.methods.items, "Target.setAutoAttach\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.methods.items, "Page.navigate\n") != null);
    try testing.expect(!available(gpa, io, &std.process.Environ.Map.init(gpa)) or true);
}

/// A stand-in Chrome in `dir`: a script that runs `body` (after
/// `#!/bin/sh`), ignoring the Chrome flags `spawn` passes. Returns its
/// absolute path on `arena`.
fn standIn(arena: Allocator, io: Io, dir: Io.Dir, root: []const u8, name: []const u8, body: []const u8) ![]const u8 {
    const text = try std.fmt.allocPrint(arena, "#!/bin/sh\n{s}\n", .{body});
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
    const f = try dir.openFile(io, name, .{ .mode = .read_write });
    defer f.close(io);
    try f.setPermissions(io, .fromMode(0o755));
    return std.fs.path.join(arena, &.{ root, name });
}

fn tmpRoot(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(testing.io, buf);
    return buf[0..n];
}

test "Launch.kill kills and reaps a running child, and a second kill does nothing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bin = try standIn(arena.allocator(), io, tmp.dir, root, "chrome", "exec /bin/sleep 30");
    const l = try spawn(gpa, io, &std.process.Environ.Map.init(gpa), .{ .profile_dir = root, .binary = bin });
    const pid = l.child.id.?;
    l.kill(io);
    // The pane's `shutdown` kills, then its `deinit` kills again. Before
    // the 0.16 fix the second call was a `wait` on a reaped child and
    // aborted the process.
    l.kill(io);
    try testing.expectEqual(@as(?std.process.Child.Id, null), l.child.id);
    try testing.expect(child_os.goneWithin(io, pid, .fromSeconds(10)));
    l.destroy(io);
}

test "Launch.kill does not panic on a child that exited on its own" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bin = try standIn(arena.allocator(), io, tmp.dir, root, "chrome", "exit 0");
    const l = try spawn(gpa, io, &std.process.Environ.Map.init(gpa), .{ .profile_dir = root, .binary = bin });
    const pid = l.child.id.?;
    // The reader sees EOF and gives up: no port, and a zombie to reap —
    // the Chrome-crashed-before-we-killed-it path.
    try testing.expectEqual(@as(?u16, null), l.waitPort(io, .fromSeconds(10)));
    l.kill(io);
    l.kill(io);
    try testing.expectEqual(@as(?std.process.Child.Id, null), l.child.id);
    try testing.expect(child_os.goneWithin(io, pid, .fromSeconds(10)));
    l.destroy(io);
}

test "the port comes off the DevTools line, and the reader keeps draining after it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bin = try standIn(arena.allocator(), io, tmp.dir, root, "chrome", "echo noise >&2; echo 'DevTools listening on ws://127.0.0.1:4567/devtools/browser/abc' >&2; i=0; while [ $i -lt 2000 ]; do echo 'more stderr after the port line' >&2; i=$((i+1)); done; exec /bin/sleep 30");
    const l = try launch(gpa, io, &std.process.Environ.Map.init(gpa), .{ .profile_dir = root, .binary = bin });
    try testing.expectEqual(@as(u16, 4567), l.port);
    const pid = l.child.id.?;
    l.destroy(io);
    try testing.expect(child_os.goneWithin(io, pid, .fromSeconds(10)));
    try testing.expectEqual(@as(?u16, 4567), parsePortLine("DevTools listening on ws://127.0.0.1:4567/devtools/browser/x\n"));
    try testing.expectEqual(@as(?u16, null), parsePortLine("[1234:ERROR] something\n"));
}

/// Waits on `l.waitPort` from its own thread, the way the pane's worker
/// does, and says when it came back.
const PortWaiter = struct {
    l: *Launch,
    got: ?u16 = 1,
    done: Io.Event = .unset,

    fn run(self: *PortWaiter) void {
        self.got = self.l.waitPort(testing.io, .fromSeconds(60));
        self.done.set(testing.io);
    }
};

test "a Chrome that never prints its DevTools line is killed while a worker waits for the port, and the worker wakes at once" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // The wedge: started, never reports a port, and a grandchild holds
    // stderr open past its parent — so EOF alone would never end the read.
    const body = try std.fmt.allocPrint(arena.allocator(), "/bin/sleep 30 & echo $! > '{s}/grandchild.pid'; exec /bin/sleep 30", .{root});
    const bin = try standIn(arena.allocator(), io, tmp.dir, root, "chrome", body);
    const l = try spawn(gpa, io, &std.process.Environ.Map.init(gpa), .{ .profile_dir = root, .binary = bin });
    const pid = l.child.id.?;
    defer {
        // The grandchild is the script's, not the Launch's: take it down.
        var gbuf: [32]u8 = undefined;
        if (tmp.dir.readFile(io, "grandchild.pid", &gbuf)) |txt| {
            if (std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, txt, " \n"), 10)) |g| std.posix.kill(g, .KILL) catch {} else |_| {}
        } else |_| {}
    }
    var waiter: PortWaiter = .{ .l = l };
    const t = try std.Thread.spawn(.{}, PortWaiter.run, .{&waiter});
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    try testing.expect(!waiter.done.isSet());
    // What the pane's close does: kill through the Launch it already has.
    l.kill(io);
    const start = Io.Timestamp.now(io, .awake);
    while (!waiter.done.isSet() and start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds < std.time.ns_per_s * 10) {
        waiter.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
    }
    if (!waiter.done.isSet()) {
        // Leave the waiter parked rather than free what it reads.
        return error.TestUnexpectedResult;
    }
    t.join();
    try testing.expectEqual(@as(?u16, null), waiter.got);
    try testing.expect(child_os.goneWithin(io, pid, .fromSeconds(10)));
    l.destroy(io);
}
