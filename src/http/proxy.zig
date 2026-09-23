//! `mnml-zig proxy --url URL`: a headless Chrome, driven over CDP,
//! every `Network.requestWillBeSent` appended to
//! `<ws>/.rqst/captured/log.jsonl` — the same lines the browser pane
//! writes, so `http.view_captured` reads either. Stops after
//! `max_seconds`, or once no network event has arrived for `idle_ms`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cdp = @import("../cdp/client.zig");
const captured = @import("captured.zig");
const history = @import("history.zig");
const parse = @import("parse.zig");

pub const Options = struct {
    workspace: []const u8,
    url: []const u8,
    max_seconds: ?u64 = null,
    idle_ms: u64 = 2000,
    verbose: bool = true,
    /// Only this binary (tests point it at nothing to prove the error path).
    binary: ?[]const u8 = null,
};

pub const Error = error{ ChromeNotFound, NoDevToolsPort, NoPageTarget, ConnectFailed } || Allocator.Error;

const Shared = struct {
    io: Io,
    lock: Io.Mutex = .init,
    last_event_ms: i64,
    written: usize = 0,
    done: bool = false,
};

/// Returns how many requests were written.
pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, opts: Options, err_w: ?*Io.Writer) Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const log_path = try captured.logPath(a, opts.workspace);
    if (std.fs.path.dirname(log_path)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch {};
    const profile = try std.fmt.allocPrint(a, "{s}/.mnml/chrome-profile-proxy-{d}", .{ opts.workspace, Io.Timestamp.now(io, .real).toMilliseconds() });
    Io.Dir.cwd().createDirPath(io, profile) catch {};
    defer Io.Dir.cwd().deleteTree(io, profile) catch {};
    // Chrome starts on about:blank and is sent to the URL once Network
    // is enabled: a URL on the command line loads before any CDP client
    // is listening, and its document request is never seen.
    const launch = cdp.launch(gpa, io, env, .{ .url = "about:blank", .profile_dir = profile, .headless = true, .binary = opts.binary }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ChromeNotFound => error.ChromeNotFound,
        error.NoDevToolsPort, error.ConcurrencyUnavailable => error.NoDevToolsPort,
    };
    defer launch.destroy(io);
    const ws_url = cdp.pageWsUrl(gpa, io, launch.port, null) catch return error.NoPageTarget;
    defer gpa.free(ws_url);
    var session = cdp.Session.connect(gpa, io, ws_url) catch return error.ConnectFailed;
    defer session.deinit();
    if (err_w) |w| if (opts.verbose) w.print("mnml-zig proxy: attached to {s}\n", .{ws_url}) catch {};
    session.enableAll() catch return error.ConnectFailed;
    const target = try cdp.normalizeUrl(a, opts.url);
    if (!std.mem.eql(u8, target, "about:blank")) {
        const params = try std.fmt.allocPrint(a, "{{\"url\":{f}}}", .{std.json.fmt(target, .{})});
        _ = session.send("Page.navigate", params, null) catch return error.ConnectFailed;
    }
    var shared: Shared = .{ .io = io, .last_event_ms = nowMs(io) };
    const reader = std.Thread.spawn(.{}, readerLoop, .{ gpa, io, &session, &shared, log_path, opts.verbose, err_w }) catch return error.ConnectFailed;
    const started = nowMs(io);
    while (true) {
        Io.sleep(io, .fromMilliseconds(100), .awake) catch break;
        shared.lock.lockUncancelable(io);
        const done = shared.done;
        const last = shared.last_event_ms;
        shared.lock.unlock(io);
        if (done) break;
        const now = nowMs(io);
        if (opts.max_seconds) |s| if (now - started >= @as(i64, @intCast(s)) * 1000) break;
        if (now - last >= @as(i64, @intCast(opts.idle_ms)) and now - started >= 1000) break;
    }
    session.conn.close(1000, "") catch {};
    session.conn.stream.shutdown(io, .both) catch {};
    reader.join();
    return shared.written;
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn readerLoop(gpa: Allocator, io: Io, session: *cdp.Session, shared: *Shared, log_path: []const u8, verbose: bool, err_w: ?*Io.Writer) void {
    defer {
        shared.lock.lockUncancelable(io);
        shared.done = true;
        shared.lock.unlock(io);
    }
    while (true) {
        const text = switch (session.next() catch return orelse return) {
            .text => |t| t,
            // A reply too large to take (a huge eval, a DOM dump) is not
            // a request line; skip it and keep reading.
            .too_long => continue,
        };
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const m = cdp.parseMessage(a, text) catch continue;
        const method = m.method orelse continue;
        if (!std.mem.startsWith(u8, method, "Network.")) continue;
        shared.lock.lockUncancelable(io);
        shared.last_event_ms = nowMs(io);
        shared.lock.unlock(io);
        if (!std.mem.eql(u8, method, "Network.requestWillBeSent")) continue;
        const request_id = cdp.str(m.params, &.{"requestId"}) orelse continue;
        const url = cdp.str(m.params, &.{ "request", "url" }) orelse continue;
        const meth = cdp.str(m.params, &.{ "request", "method" }) orelse "GET";
        var headers: std.ArrayListUnmanaged(parse.Header) = .empty;
        if (cdp.get(m.params, &.{ "request", "headers" })) |hs| if (hs == .object) {
            var it = hs.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .string) headers.append(a, .{ .name = @constCast(e.key_ptr.*), .value = @constCast(e.value_ptr.string) }) catch {};
        };
        const body = cdp.str(m.params, &.{ "request", "postData" });
        const ts: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_ms));
        const line = captured.renderLine(gpa, ts, request_id, meth, url, headers.items, body) catch continue;
        defer gpa.free(line);
        history.appendLine(gpa, io, log_path, line) catch continue;
        shared.lock.lockUncancelable(io);
        shared.written += 1;
        shared.lock.unlock(io);
        if (verbose) if (err_w) |w| w.print("  {s} {s}\n", .{ meth, url }) catch {};
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "no Chrome at the named binary is a clean error" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.ChromeNotFound, run(testing.allocator, testing.io, &env, .{ .workspace = "/tmp", .url = "about:blank", .binary = "/nope/chrome" }, null));
}
