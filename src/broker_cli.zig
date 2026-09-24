//! `mnml-zig broker …` — the batch class, from a shell.
//!
//! The panes queue themselves. A capture script, a `curl` in a loop, a
//! nightly sweep does not — it goes straight at the API and takes a
//! token out from under whatever pane is open. This is how it queues
//! instead:
//!
//! ```sh
//! mnml-zig broker acquire --service bitbucket --reason capture && curl …
//! ```
//!
//! `batch` is the default class and the back of the queue on purpose:
//! nothing a pane does can reach it (`warm.classOf` maps no reason to
//! it), so a shell script waits behind every pane on the machine — and
//! the aging rule means it waits behind them for at most thirty
//! seconds per class, never forever.
//!
//! It works with no broker running, because `acquireVia` falls back to
//! the shared file bucket, which is the same bucket the broker fronts.
//! So a script written against this is correct whether or not mnml is
//! open, which is the only way a script is worth writing.
//!
//! Exit 0 means a token was granted and the caller should go. Exit 1
//! means it was not, inside the timeout asked for — the caller decides
//! whether to send anyway and wear its own 429, which is what the
//! limiter itself would do.
//!
//! `mnml-zig broker status` prints the same numbers the REQUESTS
//! header paints, for a service or for all of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const broker_app = @import("app/broker.zig");

pub const usage =
    \\usage: mnml-zig broker acquire [--service NAME] [--class interactive|refresh|warm|batch]
    \\                              [--reason WORD] [--timeout-ms N] [--json]
    \\       mnml-zig broker status  [--service NAME] [--json]
    \\       mnml-zig broker serve   [--service NAME] [--rate N] [--capacity N]
;

pub const Std = struct {
    out: *Io.Writer,
    err: *Io.Writer,
};

const Args = struct {
    service: []const u8 = "bitbucket",
    class: sdk.broker.Class = .batch,
    reason: []const u8 = "batch",
    /// 0 asks for the service's own `max_block_secs`, which is what a
    /// pane would wait.
    timeout_ms: u32 = 0,
    json: bool = false,
    help: bool = false,
    /// `serve` only: override the service's bucket preset. For a
    /// machine whose real budget is not one of the two mnml knows, and
    /// for measuring an ordering without waiting out a real one.
    rate: f64 = 0,
    capacity: f64 = 0,
};

fn parse(argv: []const []const u8, std_: Std) ?Args {
    var a: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            a.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            a.json = true;
            continue;
        }
        const value: []const u8 = blk: {
            if (i + 1 < argv.len) break :blk argv[i + 1];
            break :blk "";
        };
        if (std.mem.eql(u8, arg, "--service")) {
            if (value.len == 0) return miss(std_, "--service");
            a.service = value;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--class")) {
            if (value.len == 0) return miss(std_, "--class");
            a.class = sdk.broker.Class.parse(value) orelse {
                std_.err.print("broker: --class must be interactive, refresh, warm or batch\n", .{}) catch {};
                return null;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--reason")) {
            if (value.len == 0) return miss(std_, "--reason");
            a.reason = value;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--rate")) {
            if (value.len == 0) return miss(std_, "--rate");
            a.rate = std.fmt.parseFloat(f64, value) catch {
                std_.err.print("broker: --rate wants tokens per second\n", .{}) catch {};
                return null;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--capacity")) {
            if (value.len == 0) return miss(std_, "--capacity");
            a.capacity = std.fmt.parseFloat(f64, value) catch {
                std_.err.print("broker: --capacity wants a number of tokens\n", .{}) catch {};
                return null;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            if (value.len == 0) return miss(std_, "--timeout-ms");
            a.timeout_ms = std.fmt.parseInt(u32, value, 10) catch {
                std_.err.print("broker: --timeout-ms wants a number of milliseconds\n", .{}) catch {};
                return null;
            };
            i += 1;
        } else {
            std_.err.print("broker: unknown argument {s}\n{s}\n", .{ arg, usage }) catch {};
            return null;
        }
    }
    return a;
}

fn miss(std_: Std, name: []const u8) ?Args {
    std_.err.print("broker: {s} needs a value\n{s}\n", .{ name, usage }) catch {};
    return null;
}

/// `mnml-zig broker <verb> …`, or null when `verb` is not one of ours.
pub fn subcommand(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
    std_: Std,
) ?u8 {
    if (argv.len == 0) {
        std_.err.print("{s}\n", .{usage}) catch {};
        return 2;
    }
    const verb = argv[0];
    const rest = argv[1..];
    if (std.mem.eql(u8, verb, "acquire")) return acquire(gpa, io, env, rest, std_) catch 1;
    if (std.mem.eql(u8, verb, "status")) return status(gpa, io, env, rest, std_) catch 1;
    if (std.mem.eql(u8, verb, "serve")) return serve(gpa, io, env, rest, std_) catch 1;
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h")) {
        std_.out.print("{s}\n", .{usage}) catch {};
        return 0;
    }
    std_.err.print("broker: no such verb {s}\n{s}\n", .{ verb, usage }) catch {};
    return 2;
}

fn acquire(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const []const u8, std_: Std) !u8 {
    const a = parse(argv, std_) orelse return 2;
    if (a.help) {
        try std_.out.print("{s}\n", .{usage});
        return 0;
    }
    var limiter = try sdk.ratelimit.Limiter.forService(gpa, io, env, a.service);
    defer limiter.deinit();
    if (a.timeout_ms > 0) limiter.cfg.max_block_secs = @as(f64, @floatFromInt(a.timeout_ms)) / 1000.0;
    // Named, so the machine-wide draws file says a script spent this
    // one rather than leaving it to "other".
    try limiter.identify(a.service, "mnml-zig broker", sdk.warm.selfPid());
    limiter.reason = a.reason;

    const got = limiter.acquireVia(a.class);
    if (a.json) {
        try std_.out.print("{{\"ok\":{s},\"via\":\"{s}\",\"wait_ms\":{d},\"remaining\":{d:.3},\"class\":\"{s}\",\"service\":\"{s}\"}}\n", .{
            if (got.ok) "true" else "false",
            got.via.tag(),
            got.wait_ms,
            @max(got.tokens_after, 0),
            a.class.tag(),
            a.service,
        });
    } else if (got.ok) {
        try std_.out.print("{s}: token granted via the {s} after {d} ms · {d:.1} left\n", .{
            a.service, got.via.tag(), got.wait_ms, @max(got.tokens_after, 0),
        });
    } else {
        try std_.out.print("{s}: no token after {d} ms — send anyway and wear the 429, or try later\n", .{
            a.service, got.wait_ms,
        });
    }
    return if (got.ok) 0 else 1;
}

fn status(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const []const u8, std_: Std) !u8 {
    const a = parse(argv, std_) orelse return 2;
    if (a.help) {
        try std_.out.print("{s}\n", .{usage});
        return 0;
    }
    // `--service` names one; without it, every service mnml fronts.
    var only: [1][]const u8 = .{a.service};
    const wanted: []const []const u8 = if (named(argv, "--service")) &only else &broker_app.services;
    for (wanted) |service| {
        const path = try sdk.broker.socketPath(gpa, io, env, service);
        defer gpa.free(path);
        // A path nothing can connect to reads exactly like a broker
        // that is not running, and the reader goes looking for the
        // process instead of at their own environment. Say which.
        if (sdk.broker.pathTooLong(path)) {
            var buf: [sdk.broker.explain_max]u8 = undefined;
            const why = sdk.broker.explainPathTooLong(&buf, service, path);
            if (a.json) {
                try std_.out.print("{{\"service\":\"{s}\",\"broker\":false,\"socket\":\"{s}\",\"error\":\"{s}\"}}\n", .{ service, path, why });
            } else {
                try std_.err.print("{s}: {s}\n", .{ service, why });
            }
            continue;
        }
        const snap = sdk.broker.askStatus(io, path, service);
        if (a.json) {
            if (snap) |s| {
                try std_.out.print("{{\"service\":\"{s}\",\"broker\":true,\"queue\":{d},\"budget_pct\":{d},\"served\":{d},\"timed_out\":{d},\"uptime_secs\":{d},\"socket\":\"{s}\"}}\n", .{
                    service, s.total(), s.budgetPct(), s.served, s.timed_out, s.uptime_secs, path,
                });
            } else {
                try std_.out.print("{{\"service\":\"{s}\",\"broker\":false,\"socket\":\"{s}\"}}\n", .{ service, path });
            }
            continue;
        }
        if (snap) |s| {
            try std_.out.print("{s}: broker up · queue {d} · {d}% budget · {d} served · {d} timed out · up {d}s\n", .{
                service, s.total(), s.budgetPct(), s.served, s.timed_out, s.uptime_secs,
            });
        } else {
            try std_.out.print("{s}: no broker at {s} — every client is on the file bucket\n", .{ service, path });
        }
    }
    return 0;
}

/// `mnml-zig broker serve` — hold one service's broker until killed.
///
/// mnml hosts these itself while it is open, and that is the normal
/// way one runs. This is for the machine with no mnml on it: a CI box,
/// a headless sweep host, somebody measuring the ordering. It takes
/// the same election lock mnml's host does, so running it beside an
/// open mnml is safe — it simply says the broker is already up and
/// exits rather than binding a second one.
fn serve(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const []const u8, std_: Std) !u8 {
    const a = parse(argv, std_) orelse return 2;
    if (a.help) {
        try std_.out.print("{s}\n", .{usage});
        return 0;
    }
    if (!sdk.broker.supported) {
        try std_.err.print("broker: this platform has no Unix sockets; every client is on the file bucket\n", .{});
        return 1;
    }
    const sock = try sdk.broker.socketPath(gpa, io, env, a.service);
    defer gpa.free(sock);
    var why_buf: [sdk.broker.explain_max]u8 = undefined;
    // Up front, before the lock and the bucket: a path a `sockaddr_un`
    // cannot hold is the user's own setting, and the only thing that
    // helps is its length beside the limit.
    if (sdk.broker.pathTooLong(sock)) {
        try std_.err.print("{s}: {s}\n", .{ a.service, sdk.broker.explainPathTooLong(&why_buf, a.service, sock) });
        return 1;
    }
    const lock_path = try sdk.broker.lockPath(gpa, sock);
    defer gpa.free(lock_path);
    // Who the lock named BEFORE we take it: `acquire` overwrites the
    // file, so this is the only moment a leftover pid is readable, and
    // it is what turns a later "address in use" into a name.
    const prior: ?sdk.warm.Lock.Holder = sdk.warm.Lock.peek(gpa, io, lock_path) catch null;
    defer if (prior) |h| gpa.free(h.program);
    var lock = try sdk.warm.Lock.init(gpa, io, lock_path, sdk.warm.selfPid(), "mnml-zig broker");
    defer lock.deinit();
    if (!lock.acquire(nowSecs(io))) {
        try std_.err.print("{s}: a broker is already running (its lock is {s})\n", .{ a.service, lock_path });
        return 1;
    }
    var cfg = sdk.ratelimit.configFor(a.service);
    if (a.rate > 0) cfg.rate = a.rate;
    if (a.capacity > 0) cfg.capacity = a.capacity;
    const server = sdk.broker.Server.start(gpa, io, env, .{
        .service = a.service,
        .program = "mnml-zig broker",
        .pid = sdk.warm.selfPid(),
        .config = cfg,
    }) catch |err| {
        lock.release();
        const stale: ?i32 = if (prior) |h| (if (h.pid != sdk.warm.selfPid()) h.pid else null) else null;
        try std_.err.print("{s}: {s}\n", .{ a.service, sdk.broker.explainStart(&why_buf, sock, err, a.service, stale) });
        return 1;
    };
    defer {
        server.stop();
        server.destroy();
    }
    try std_.out.print("{s}: broker on {s} · {d:.3}/s · burst {d:.0} — ctrl-c to stop\n", .{
        a.service, server.path(), cfg.rate, cfg.capacity,
    });
    try std_.out.flush();
    // Nothing to do but stay alive and heartbeat, so a broker that was
    // killed does not keep the next one out for five minutes.
    while (true) {
        io.sleep(.fromMilliseconds(1000), .awake) catch break;
        lock.heartbeat(nowSecs(io));
    }
    return 0;
}

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

fn named(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const Captured = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    err: std.ArrayListUnmanaged(u8) = .empty,
};

test "the command line: defaults, every class by name, and a refusal rather than a guess" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const std_: Std = .{ .out = &w, .err = &w };

    // A shell user is a batch caller and does not have to say so.
    const bare = parse(&.{}, std_).?;
    try t.expectEqual(sdk.broker.Class.batch, bare.class);
    try t.expectEqualStrings("bitbucket", bare.service);
    try t.expectEqualStrings("batch", bare.reason);
    try t.expectEqual(@as(u32, 0), bare.timeout_ms);
    try t.expect(!bare.json);

    const full = parse(&.{ "--service", "jira", "--class", "warm", "--reason", "capture", "--timeout-ms", "2500", "--rate", "1.0", "--capacity", "2", "--json" }, std_).?;
    try t.expectEqualStrings("jira", full.service);
    try t.expectEqual(sdk.broker.Class.warm, full.class);
    try t.expectEqualStrings("capture", full.reason);
    try t.expectEqual(@as(u32, 2500), full.timeout_ms);
    try t.expectApproxEqAbs(@as(f64, 1.0), full.rate, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 2.0), full.capacity, 1e-9);
    try t.expect(full.json);

    // A class that is not one is refused, never rounded to the
    // nearest: a script that meant `interactive` and typed `urgent`
    // must not silently become a batch job.
    try t.expect(parse(&.{ "--class", "urgent" }, std_) == null);
    try t.expect(parse(&.{ "--timeout-ms", "soon" }, std_) == null);
    try t.expect(parse(&.{ "--rate", "fast" }, std_) == null);
    try t.expect(parse(&.{"--service"}, std_) == null);
    try t.expect(parse(&.{"--wat"}, std_) == null);
    try t.expect(parse(&.{"--help"}, std_).?.help);
}

test "acquire takes a real token off the file bucket when no broker is running, and says so" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const state = try std.fmt.allocPrint(t.allocator, "{s}/bitbucket-ratelimit.json", .{dir});
    defer t.allocator.free(state);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_RATELIMIT_STATE", state);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var ebuf: [1024]u8 = undefined;
    var e: Io.Writer = .fixed(&ebuf);
    const std_: Std = .{ .out = &w, .err = &e };

    const code = subcommand(t.allocator, t.io, &env, &.{ "acquire", "--reason", "capture", "--json" }, std_).?;
    try t.expectEqual(@as(u8, 0), code);
    const line = w.buffered();
    try t.expect(std.mem.indexOf(u8, line, "\"ok\":true") != null);
    // No broker in a test directory, so the file bucket answered —
    // and a script written against this is correct either way.
    try t.expect(std.mem.indexOf(u8, line, "\"via\":\"file\"") != null);
    try t.expect(std.mem.indexOf(u8, line, "\"class\":\"batch\"") != null);

    // It really spent one: the shared file says so, and the draw line
    // names the script rather than leaving it to "other".
    const text = try Io.Dir.cwd().readFileAlloc(t.io, state, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    const st = sdk.ratelimit.parseState(text).?;
    try t.expect(st.tokens < sdk.ratelimit.Config.bitbucket.capacity);
    const draws = try std.fmt.allocPrint(t.allocator, "{s}/bitbucket-draws.jsonl", .{dir});
    defer t.allocator.free(draws);
    const lines = try Io.Dir.cwd().readFileAlloc(t.io, draws, t.allocator, .limited(4096));
    defer t.allocator.free(lines);
    try t.expect(std.mem.indexOf(u8, lines, "\"reason\":\"capture\"") != null);
}

test "status says there is no broker rather than failing when nothing is listening" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("TATTLE_ARTIFACTS_ROOT", dir);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var ebuf: [1024]u8 = undefined;
    var e: Io.Writer = .fixed(&ebuf);
    const std_: Std = .{ .out = &w, .err = &e };

    const code = subcommand(t.allocator, t.io, &env, &.{ "status", "--json" }, std_).?;
    try t.expectEqual(@as(u8, 0), code);
    const text = w.buffered();
    // One line per service mnml fronts, each saying there is none.
    try t.expectEqual(@as(usize, broker_app.services.len), std.mem.count(u8, text, "\n"));
    try t.expect(std.mem.indexOf(u8, text, "\"service\":\"jira\",\"broker\":false") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"service\":\"bitbucket\",\"broker\":false") != null);

    // A verb that is not one is a usage error, not a silent nothing.
    var w2: Io.Writer = .fixed(&buf);
    const std2: Std = .{ .out = &w2, .err = &e };
    try t.expectEqual(@as(u8, 2), subcommand(t.allocator, t.io, &env, &.{"drain"}, std2).?);
}

/// A `<SERVICE>_BROKER_SOCKET` longer than any `sockaddr_un` holds,
/// under the test's own tmp dir so nothing near the real bucket is
/// touched. Owned by the caller.
fn longOverride(gpa: Allocator, dir: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, dir);
    while (out.items.len < sdk.broker.os_max_path_len + 1) try out.appendSlice(gpa, "/deeeeeeep");
    try out.appendSlice(gpa, "/bitbucket-broker.sock");
    return out.toOwnedSlice(gpa);
}

test "serve refuses a socket path the OS cannot hold, by length, before it binds anything" {
    if (!sdk.broker.supported) return error.SkipZigTest;
    // `.iterate`: the emptiness check below lists the dir, and on Linux a
    // handle opened without it is O_PATH — `getdents` on it is EBADF,
    // which a Debug build panics on.
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const state = try std.fmt.allocPrint(t.allocator, "{s}/bitbucket-ratelimit.json", .{dir});
    defer t.allocator.free(state);
    try env.put("BITBUCKET_RATELIMIT_STATE", state);
    const sock = try longOverride(t.allocator, dir);
    defer t.allocator.free(sock);
    try env.put("BITBUCKET_BROKER_SOCKET", sock);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var ebuf: [4096]u8 = undefined;
    var e: Io.Writer = .fixed(&ebuf);

    // `serve` exits 1 and says which setting and how long it is —
    // where it used to print `bitbucket: could not serve (BindFailed)`
    // and leave the reader with no way in.
    const code = subcommand(t.allocator, t.io, &env, &.{ "serve", "--service", "bitbucket" }, .{ .out = &w, .err = &e }).?;
    try t.expectEqual(@as(u8, 1), code);
    const said = e.buffered();
    try t.expect(std.mem.indexOf(u8, said, "BindFailed") == null);
    var expect_buf: [sdk.broker.explain_max]u8 = undefined;
    const want = try std.fmt.bufPrint(
        &expect_buf,
        "bitbucket: socket path is {d} bytes; the OS allows {d} — set BITBUCKET_BROKER_SOCKET shorter or unset it for the default\n",
        .{ sock.len, sdk.broker.os_max_path_len },
    );
    try t.expectEqualStrings(want, said);
    // Refused UP FRONT: no bucket, no election lock, and — the one a
    // later guard would not catch — none of the deep directory tree
    // that `Lock.acquire` would have made on the way to a socket
    // nothing can ever bind. The tmp dir is still empty.
    var it = tmp.dir.iterate();
    try t.expect((try it.next(t.io)) == null);

    // And `status` says the same thing rather than the indistinguishable
    // "no broker at <path>" it used to print.
    var w2: Io.Writer = .fixed(&buf);
    var e2: Io.Writer = .fixed(&ebuf);
    const scode = subcommand(t.allocator, t.io, &env, &.{ "status", "--service", "bitbucket" }, .{ .out = &w2, .err = &e2 }).?;
    try t.expectEqual(@as(u8, 0), scode);
    try t.expect(std.mem.indexOf(u8, e2.buffered(), "socket path is ") != null);
    try t.expect(std.mem.indexOf(u8, e2.buffered(), "BITBUCKET_BROKER_SOCKET shorter") != null);
    try t.expect(std.mem.indexOf(u8, w2.buffered(), "no broker at") == null);

    // `--json` keeps its one-object-per-line shape and carries the
    // reason in it, so a script sees the same thing a reader does.
    var w3: Io.Writer = .fixed(&buf);
    var e3: Io.Writer = .fixed(&ebuf);
    _ = subcommand(t.allocator, t.io, &env, &.{ "status", "--service", "bitbucket", "--json" }, .{ .out = &w3, .err = &e3 }).?;
    try t.expect(std.mem.indexOf(u8, w3.buffered(), "\"broker\":false") != null);
    try t.expect(std.mem.indexOf(u8, w3.buffered(), "\"error\":\"socket path is ") != null);
}
