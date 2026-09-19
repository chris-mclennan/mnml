//! Hosting the API broker: one per service, while mnml is running.
//!
//! `mnml_sdk.broker` is the queue that puts the pane you are looking at
//! in front of the warmers and the batch scripts drawing on the same
//! API budget. Somebody has to hold it, and mnml is the obvious
//! somebody: it is the thing already on screen, it knows when it is
//! quitting, and every client falls back to the shared file bucket
//! when it is not there — so hosting it is an improvement, never a
//! dependency.
//!
//! **Exactly one per service on the machine.** Two mnml windows are
//! normal; two brokers on one bucket would be two queues, which is no
//! queue at all. So each service has an election lock beside its
//! socket — `<service>-broker.lock`, the same file shape and the same
//! pid-plus-heartbeat rules as `warm.Lock`'s one-warmer lock. The
//! process that takes it serves; the second becomes a client of the
//! first, exactly as an integration is. A broker that was killed
//! leaves a lock nobody heartbeats, and the next mnml takes it.
//!
//! **Off is a real setting.** `integrations.broker = false` hosts
//! nothing and tells every integration mnml starts not to look for one
//! (`MNML_BROKER=0`), so the whole machine is back to the file bucket
//! and its first-come order. The default is on.
//!
//! **A test App hosts nothing** — a corpus run must not bind a socket
//! beside the user's real bucket — unless it asks with `MNML_BROKER=1`,
//! which is what an `.test` script that wants to prove the REQUESTS
//! header does. The same shape `integration_poll` uses for its
//! workers, for the same reason.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const app_mod = @import("../app.zig");
const App = app_mod.App;

/// The services mnml fronts. Every one of them has a shared bucket
/// under `mnml_sdk.ratelimit`, and the REQUESTS view reads the same
/// list for the draws files.
pub const services = [_][]const u8{ "jira", "bitbucket" };

/// How this process names itself in a lock file and in the bucket's
/// draw lines.
pub const program = "mnml-zig";

/// How often a slot that is not hosting looks again. The lock's holder
/// may have quit; twenty seconds is far inside the five minutes a
/// stale lock takes to expire, and far outside anything that would
/// show up as work.
pub const recheck_ms: i64 = 20_000;

/// `MNML_BROKER` — `0` / `off` / `false` / `no` turns the whole thing
/// off for a child; anything else leaves it on. The same spelling
/// `MNML_REQUEST_LOG` uses, because it is the same kind of switch.
pub const enabled_env = "MNML_BROKER";

/// Where the broker for one service stands.
pub const Where = enum {
    /// Nothing is listening: every client is on the file bucket.
    off,
    /// This mnml is serving it.
    hosted,
    /// Another process is — a second mnml window, usually.
    client,
};

/// One service's broker, as the REQUESTS header paints it.
pub const Line = struct {
    service: []const u8,
    where: Where = .off,
    /// Callers queued right now, every class together.
    queue: u32 = 0,
    /// The share of the shared bucket left, 0…100.
    budget_pct: u8 = 0,
};

const Slot = struct {
    service: []const u8,
    /// Where the socket is, resolved once. Owned; empty until `sync`.
    path: []u8 = &.{},
    /// Held only while this process is the one serving.
    lock: ?sdk.warm.Lock = null,
    server: ?*sdk.broker.Server = null,
};

pub const State = struct {
    slots: [services.len]Slot = blk: {
        var out: [services.len]Slot = undefined;
        for (&out, services) |*s, name| s.* = .{ .service = name };
        break :blk out;
    },
    /// When a slot that is not hosting looks again.
    next_check_ms: i64 = 0,

    /// Stop serving and give the locks back. A broker that goes down
    /// releases everyone queued to the file bucket rather than to
    /// their timeouts, which `Server.stop` does.
    pub fn stop(self: *State, gpa: Allocator, io: Io) void {
        _ = io;
        for (&self.slots) |*s| {
            if (s.server) |srv| {
                srv.stop();
                srv.destroy();
                s.server = null;
            }
            if (s.lock) |*l| {
                l.deinit();
                s.lock = null;
            }
            gpa.free(s.path);
            s.path = &.{};
        }
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.stop(gpa, io);
    }

    pub fn slotFor(self: *const State, service: []const u8) ?*const Slot {
        for (&self.slots) |*s| {
            if (std.mem.eql(u8, s.service, service)) return s;
        }
        return null;
    }
};

/// Whether this App hosts brokers at all: the user's setting, and —
/// because a corpus run must not bind a socket beside the real bucket
/// — either a real terminal or an explicit opt-in.
pub fn hosting(app: *const App) bool {
    if (!app.cfg.integrations.broker) return false;
    if (!sdk.broker.supported) return false;
    return app.native_notify or optedIn(app);
}

fn optedIn(app: *const App) bool {
    const v = app.env.get(enabled_env) orelse return false;
    return v.len > 0 and !off(v);
}

/// The `0` / `off` / `false` / `no` spelling every mnml switch shares.
pub fn off(v: []const u8) bool {
    return std.mem.eql(u8, v, "0") or
        std.ascii.eqlIgnoreCase(v, "off") or
        std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "no");
}

/// Take what can be taken: resolve each service's socket, win its
/// election lock if it is free, and start serving. Idempotent — a slot
/// already hosting is left alone — so this is both the start and the
/// re-check.
pub fn sync(app: *App) void {
    const st = &app.broker;
    if (!hosting(app)) return;
    const now = nowSecs(app.io);
    for (&st.slots) |*s| {
        if (s.path.len == 0) {
            s.path = sdk.broker.socketPath(app.gpa, app.io, &app.env, s.service) catch continue;
        }
        if (s.server != null) {
            // Still ours: say so, or a lock nobody has touched for
            // five minutes is taken out from under us.
            if (s.lock) |*l| l.heartbeat(now);
            continue;
        }
        if (s.lock == null) {
            const lock_path = sdk.broker.lockPath(app.gpa, s.path) catch continue;
            defer app.gpa.free(lock_path);
            s.lock = sdk.warm.Lock.init(app.gpa, app.io, lock_path, sdk.warm.selfPid(), program) catch continue;
        }
        const l = if (s.lock) |*l| l else continue;
        // Somebody else is serving this bucket. That is the right
        // answer, not a failure: this process is a client of theirs,
        // exactly as an integration is.
        if (!l.acquire(now)) continue;
        s.server = sdk.broker.Server.start(app.gpa, app.io, &app.env, .{
            .service = s.service,
            .program = program,
            .pid = sdk.warm.selfPid(),
        }) catch {
            // The lock without the socket would lock everybody out of
            // a broker nobody is running.
            l.release();
            continue;
        };
    }
}

/// Start on the first tick, then look again every `recheck_ms` — the
/// mnml that was holding a lock may have quit, and the next pane open
/// should find a broker rather than the file bucket.
pub fn tick(app: *App, now_ms: i64) void {
    const st = &app.broker;
    if (now_ms < st.next_check_ms) return;
    st.next_check_ms = now_ms + recheck_ms;
    sync(app);
}

/// The socket for a service — what a child is told, and what the
/// header asks for a status on. Empty when nothing has resolved one.
pub fn socketFor(app: *const App, service: []const u8) []const u8 {
    const s = app.broker.slotFor(service) orelse return "";
    return s.path;
}

/// The broker contract, in the environment of every integration mnml
/// starts: which socket per service, and whether to look at all.
///
/// A child would derive the same path from the same environment by
/// itself — `broker.socketPath` is a pure function of it — so naming
/// it here is not what makes the two agree. What it does is make the
/// setting real: with `integrations.broker = false` the child is told
/// `MNML_BROKER=0` and never opens a socket, instead of quietly
/// deriving one that nobody is listening on.
pub fn putEnv(app: *App, env: *std.process.Environ.Map) Allocator.Error!void {
    const on = app.cfg.integrations.broker;
    try env.put(enabled_env, if (on) "1" else "0");
    if (!on) return;
    for (services) |service| {
        const path = socketFor(app, service);
        if (path.len == 0) continue;
        var name_buf: [64]u8 = undefined;
        const name = sdk.broker.socketEnvName(&name_buf, service) orelse continue;
        try env.put(name, path);
    }
}

/// What the REQUESTS header paints, one per service. A broker this
/// process hosts answers from memory; one somebody else hosts is asked
/// over its socket, which is a local round trip on a view that is
/// already reading files.
pub fn lines(app: *App, arena: Allocator) Allocator.Error![]const Line {
    const out = try arena.alloc(Line, services.len);
    for (out, &app.broker.slots) |*line, *s| {
        line.* = .{ .service = s.service };
        if (s.server) |srv| {
            const snap = srv.snapshot();
            line.where = .hosted;
            line.queue = snap.total();
            line.budget_pct = snap.budgetPct();
            continue;
        }
        if (!app.cfg.integrations.broker) continue;
        // Not ours — but a second mnml may be serving it, and an
        // integration of ours is queueing there.
        const path = if (s.path.len > 0) s.path else blk: {
            s.path = sdk.broker.socketPath(app.gpa, app.io, &app.env, s.service) catch break :blk "";
            break :blk s.path;
        };
        if (path.len == 0) continue;
        const snap = sdk.broker.askStatus(app.io, path, s.service) orelse continue;
        line.where = .client;
        line.queue = snap.total();
        line.budget_pct = snap.budgetPct();
    }
    return out;
}

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "hosting is the setting, and a test App hosts nothing unless it asks" {
    var tmp0 = testing.tmpDir(.{});
    defer tmp0.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp0.dir.realPath(testing.io, &rbuf)];
    var a = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 24 });
    defer a.deinit();
    const app = &a;
    // The default is on — but a corpus run is not a terminal, so it
    // hosts nothing and binds no socket beside the user's own bucket.
    try testing.expect(app.cfg.integrations.broker);
    try testing.expect(!app.native_notify);
    try testing.expect(!hosting(app));
    // An `.test` script that wants a broker says so.
    try app.env.put(enabled_env, "1");
    try testing.expectEqual(sdk.broker.supported, hosting(app));
    // And the setting still wins over the opt-in.
    app.cfg.integrations.broker = false;
    try testing.expect(!hosting(app));
    app.cfg.integrations.broker = true;
    // `MNML_BROKER=0` is the same word every other mnml switch uses.
    for ([_][]const u8{ "0", "off", "false", "no", "OFF", "No" }) |v| {
        try app.env.put(enabled_env, v);
        try testing.expect(!hosting(app));
    }
}

test "one broker per service: a lock another process holds means this mnml serves nothing" {
    if (!sdk.broker.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];

    var a = try App.initWith(testing.allocator, testing.io, .{ .workspace = dir, .data_root = dir, .cols = 80, .rows = 24 });
    defer a.deinit();
    const app = &a;
    try app.env.put(enabled_env, "1");
    for (services) |service| {
        var nbuf: [64]u8 = undefined;
        const state = try std.fmt.allocPrint(testing.allocator, "{s}/{s}-ratelimit.json", .{ dir, service });
        defer testing.allocator.free(state);
        try app.env.put(sdk.ratelimit.stateEnvName(&nbuf, service).?, state);
    }

    // Another mnml already serves Jira. Its lock names a pid that is
    // alive and a heartbeat nobody would call stale — pid 1 is there
    // on every machine this runs on — so the election is decided
    // before this process asks.
    const jira_sock = try sdk.broker.socketPath(testing.allocator, testing.io, &app.env, "jira");
    defer testing.allocator.free(jira_sock);
    const jira_lock = try sdk.broker.lockPath(testing.allocator, jira_sock);
    defer testing.allocator.free(jira_lock);
    if (std.fs.path.dirname(jira_lock)) |d| Io.Dir.cwd().createDirPath(testing.io, d) catch {};
    {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"pid\":1,\"program\":\"mnml-zig\",\"ts\":{d:.3}}}", .{nowSecs(testing.io)});
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = jira_lock, .data = text });
    }

    sync(app);
    defer app.broker.stop(app.gpa, app.io);
    // Jira is somebody else's; Bitbucket was free and is ours now.
    try testing.expect(app.broker.slotFor("jira").?.server == null);
    try testing.expect(app.broker.slotFor("bitbucket").?.server != null);
    // The lock we did not win is still theirs — an mnml that loses an
    // election must not delete the winner's lock on the way past.
    try Io.Dir.cwd().access(testing.io, jira_lock, .{});
    // And the socket is still resolved, because our integrations
    // queue on THEIR broker: losing makes this process a client.
    try testing.expectEqualStrings(jira_sock, socketFor(app, "jira"));

    // They quit. The next look takes the lock and serves it.
    try Io.Dir.cwd().deleteFile(testing.io, jira_lock);
    sync(app);
    try testing.expect(app.broker.slotFor("jira").?.server != null);
    // Still idempotent: a second look heartbeats, it does not rebind.
    const before = app.broker.slotFor("jira").?.server.?;
    sync(app);
    try testing.expectEqual(before, app.broker.slotFor("jira").?.server.?);
}

test "the header says which brokers are up, and an integration is told where they are" {
    if (!sdk.broker.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];

    var a = try App.initWith(testing.allocator, testing.io, .{ .workspace = dir, .data_root = dir, .cols = 80, .rows = 24 });
    defer a.deinit();
    const app = &a;
    try app.env.put(enabled_env, "1");
    for (services) |service| {
        var nbuf: [64]u8 = undefined;
        const state = try std.fmt.allocPrint(testing.allocator, "{s}/{s}-ratelimit.json", .{ dir, service });
        defer testing.allocator.free(state);
        try app.env.put(sdk.ratelimit.stateEnvName(&nbuf, service).?, state);
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing running yet: every service is off, and a pane says so
    // rather than leaving it blank.
    for (try lines(app, arena)) |l| try testing.expectEqual(Where.off, l.where);

    sync(app);
    defer app.broker.stop(app.gpa, app.io);
    const up = try lines(app, arena);
    for (up) |l| {
        try testing.expectEqual(Where.hosted, l.where);
        try testing.expectEqual(@as(u32, 0), l.queue);
        // A fresh bucket is full.
        try testing.expectEqual(@as(u8, 100), l.budget_pct);
    }
    try testing.expectEqualStrings("jira", up[0].service);

    // The child's environment carries the switch and the sockets.
    var env = try app.env.clone(testing.allocator);
    defer env.deinit();
    try putEnv(app, &env);
    try testing.expectEqualStrings("1", env.get(enabled_env).?);
    try testing.expectEqualStrings(socketFor(app, "jira"), env.get("JIRA_BROKER_SOCKET").?);
    try testing.expectEqualStrings(socketFor(app, "bitbucket"), env.get("BITBUCKET_BROKER_SOCKET").?);

    // Turned off, a child is told not to look at all — otherwise it
    // would derive the same path and open a socket the user asked
    // mnml not to run.
    app.cfg.integrations.broker = false;
    var env_off = try app.env.clone(testing.allocator);
    defer env_off.deinit();
    try putEnv(app, &env_off);
    try testing.expectEqualStrings("0", env_off.get(enabled_env).?);
    for (try lines(app, arena)) |l| try testing.expect(l.where != .client);
}
