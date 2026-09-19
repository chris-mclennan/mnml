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
    const lock_path = try sdk.broker.lockPath(gpa, sock);
    defer gpa.free(lock_path);
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
        try std_.err.print("{s}: could not serve ({s})\n", .{ a.service, @errorName(err) });
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
