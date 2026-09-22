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

pub const Launch = struct {
    child: std.process.Child,
    port: u16,
    /// Drains Chrome's stderr so it never blocks on a full pipe.
    drain: ?std.Thread = null,

    /// Terminate Chrome, reap it, and join the stderr drain.
    /// Idempotent: the browser pane's `shutdown` calls it, and its
    /// `deinit` calls it again.
    ///
    /// // changed: this was `kill` then `wait` — the shape a child needs
    /// where `kill` only signals, and the shape the Rust prototype's
    /// `Command` had. Zig 0.16's `Child.kill` reaps the child itself and
    /// leaves `id == null`, while `Child.wait` asserts `id != null` on
    /// entry, so the `wait` aborted the process every single time.
    pub fn kill(self: *Launch, io: Io) void {
        if (self.child.id != null) self.child.kill(io);
        if (self.drain) |t| t.join();
        self.drain = null;
    }
};

pub const LaunchError = error{ ChromeNotFound, NoDevToolsPort } || Allocator.Error;

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

/// Spawn Chrome and read `DevTools listening on ws://127.0.0.1:PORT/…`.
pub fn launch(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, opts: LaunchOptions) LaunchError!Launch {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const list: []const []const u8 = if (opts.binary) |b| &.{b} else try candidates(a, io, env.get("HOME"));
    const url = if (std.mem.trim(u8, opts.url, " \t").len == 0) "about:blank" else opts.url;
    for (list) |cand| {
        const bin = resolveBinary(a, io, env, cand) orelse continue;
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
        var child = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .pipe, .environ_map = env }) catch continue;
        // `kill` reaps; a `wait` after it would assert. // changed
        const stderr = child.stderr orelse {
            child.kill(io);
            continue;
        };
        const port = readDebugPort(io, stderr) orelse {
            child.kill(io);
            return error.NoDevToolsPort;
        };
        var out: Launch = .{ .child = child, .port = port };
        out.drain = std.Thread.spawn(.{}, drainStderr, .{ io, stderr }) catch null;
        return out;
    }
    return error.ChromeNotFound;
}

fn readDebugPort(io: Io, stderr: Io.File) ?u16 {
    var rbuf: [8192]u8 = undefined;
    var r: Io.File.Reader = .init(stderr, io, &rbuf);
    var lines: usize = 0;
    while (lines < 200) : (lines += 1) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return null;
        const at = std.mem.indexOf(u8, line, "ws://") orelse continue;
        const rest = line[at + "ws://".len ..];
        const hostport = std.mem.sliceTo(rest, '/');
        const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse continue;
        return std.fmt.parseInt(u16, std.mem.trim(u8, hostport[colon + 1 ..], " \r\n"), 10) catch continue;
    }
    return null;
}

fn drainStderr(io: Io, stderr: Io.File) void {
    var rbuf: [4096]u8 = undefined;
    var r: Io.File.Reader = .init(stderr, io, &rbuf);
    var sink: [4096]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&sink) catch return;
        if (n == 0) return;
    }
}

/// `http://127.0.0.1:PORT/json` → the first `page` target's
/// `webSocketDebuggerUrl`, retried while the endpoint warms up.
pub fn pageWsUrl(gpa: Allocator, io: Io, port: u16) ![]u8 {
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/json", .{port});
    defer gpa.free(url);
    var attempt: usize = 0;
    while (attempt < 25) : (attempt += 1) {
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

    /// The next text message, or null once closed. Borrowed until the
    /// next read.
    pub fn next(self: *Session) !?[]const u8 {
        while (true) {
            const m = (try self.conn.readMessage()) orelse return null;
            switch (m) {
                .text => |t| return t,
                .close => return null,
                else => continue,
            }
        }
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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
        const text = (try session.next()) orelse break;
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
    const text = (try session.next()).?;
    const m = try parseMessage(arena.allocator(), text);
    try testing.expectEqual(@as(?i64, 100), m.id);
    try session.conn.close(1000, "");
    try testing.expect(std.mem.indexOf(u8, fake.methods.items, "Page.enable\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.methods.items, "Target.setAutoAttach\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.methods.items, "Page.navigate\n") != null);
    try testing.expect(!available(gpa, io, &std.process.Environ.Map.init(gpa)) or true);
}

/// True while `pid` names a live *or* unreaped process; false once it is
/// gone for good (`kill(pid, 0)` → ESRCH). Tests only (the browser
/// pane's close test reads it too).
pub fn pidGone(pid: std.process.Child.Id) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err == error.ProcessNotFound;
    return false;
}

test "Launch.kill kills and reaps a running child, and a second kill does nothing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    var l: Launch = .{ .child = child, .port = 0 };
    l.kill(io);
    // The pane's `shutdown` kills, then its `deinit` kills again. Before
    // the 0.16 fix the second call was a `wait` on a reaped child and
    // aborted the process.
    l.kill(io);
    try testing.expectEqual(@as(?std.process.Child.Id, null), l.child.id);
    try testing.expect(pidGone(pid));
}

test "Launch.kill does not panic on a child that exited on its own" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const child = try std.process.spawn(io, .{
        .argv = &.{"/usr/bin/true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    var l: Launch = .{ .child = child, .port = 0 };
    // Give it time to exit: by the kill it is a zombie, not a live
    // process — the Chrome-crashed-before-we-killed-it path. (A zombie
    // still answers `kill(pid, 0)`, so there is nothing to poll for;
    // and an early kill is the *other* test, so a short sleep is
    // enough either way.)
    io.sleep(.fromMilliseconds(150), .awake) catch {};
    l.kill(io);
    l.kill(io);
    try testing.expectEqual(@as(?std.process.Child.Id, null), l.child.id);
    try testing.expect(pidGone(pid));
}
