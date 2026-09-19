//! One token bucket per service, shared by every process on the
//! machine.
//!
//! An integration is never the only thing spending a host's API budget:
//! three Jira panes, the statusline poller, a shell script and the Rust
//! app can all be drawing on the same per-IP allowance at once, and the
//! first any of them hears about it is a 429 that hits all of them. So
//! the bucket does not live in a process — it lives in a file, and
//! every process refills, spends and penalises it under an exclusive
//! advisory lock.
//!
//! The file is the one the Rust crate `mnml-ratelimit` and the Python
//! `bb_ratelimit.py` already share, key for key:
//!
//!     {"ts","tokens","rate","cooldown_until","throttles","last_429"}
//!
//! so a mixed fleet coordinates rather than racing. `Config.bitbucket`
//! and `Config.jira` carry that crate's constants exactly; a service it
//! has no preset for gets the Bitbucket one, as the crate does.
//!
//!   * `acquire` refills from the wall clock, waits out a cooldown,
//!     takes a token when there is one, and otherwise waits for one
//!     (jittered, so processes released together do not re-cluster).
//!     Past `max_block_secs` it gives up and returns false — the caller
//!     should send anyway and let its own 429 handling decide. A wedged
//!     state file must never take an integration offline.
//!   * `penalize` records a 429: the shared rate is cut, the tokens
//!     emptied, and every process parked until `Retry-After` is up.
//!
//! Where the file is, in order — the Rust crate's resolution, so both
//! sides find the same bucket:
//!
//!   1. `<SERVICE>_RATELIMIT_STATE` names the file outright
//!   2. `$TATTLE_ARTIFACTS_ROOT/<service>-ratelimit.json`
//!   3. `~/.tattle-claude-artifacts/<service>-ratelimit.json`, when
//!      that folder already exists
//!   4. `<MNML_DATA_ROOT>/ratelimit/<service>.json`
//!   5. `~/.config/mnml/ratelimit/<service>.json`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Config = struct {
    /// Tokens per second the bucket refills at. Set BELOW the service's
    /// sustained budget: the bucket is a budget, not a smoother.
    rate: f64 = 0.22,
    /// The burst: a fresh bucket holds this many.
    capacity: f64 = 40.0,
    /// The multiplicative cut on a 429, and the floor it stops at.
    penalty_factor: f64 = 0.5,
    min_rate: f64 = 0.05,
    /// The park when a 429 carries no `Retry-After`.
    default_cooldown_secs: f64 = 60.0,
    /// Eases the cut rate back toward `rate`, once per success.
    recover_factor: f64 = 1.02,
    /// The longest one `acquire` may block before failing open.
    max_block_secs: f64 = 120.0,

    /// Bitbucket Cloud's sustained budget is ~1000 requests an hour —
    /// 0.278/s across every process on this IP. 0.22 leaves headroom
    /// for an interactive pane while a loop runs.
    pub const bitbucket: Config = .{
        .rate = 0.22,
        .capacity = 40.0,
        .penalty_factor = 0.5,
        .min_rate = 0.05,
        .default_cooldown_secs = 60.0,
        .recover_factor = 1.02,
        .max_block_secs = 120.0,
    };

    /// Jira Cloud is easier on sustained load than Bitbucket and
    /// stricter on bursts, so: wider burst, comparable rate.
    pub const jira: Config = .{
        .rate = 0.33,
        .capacity = 60.0,
        .penalty_factor = 0.5,
        .min_rate = 0.08,
        .default_cooldown_secs = 45.0,
        .recover_factor = 1.02,
        .max_block_secs = 120.0,
    };
};

/// The preset for a service name, the Rust crate's mapping: anything
/// without one draws on Bitbucket's, which is the tighter of the two.
pub fn configFor(service: []const u8) Config {
    if (std.ascii.eqlIgnoreCase(service, "bitbucket")) return .bitbucket;
    if (std.ascii.eqlIgnoreCase(service, "jira")) return .jira;
    return .bitbucket;
}

/// The file's shape — the Python and Rust sides read and write the
/// same six keys.
pub const State = struct {
    ts: f64 = 0,
    tokens: f64 = 0,
    rate: f64 = 0,
    cooldown_until: f64 = 0,
    throttles: u32 = 0,
    last_429: f64 = 0,
};

/// What `acquire` was waiting on. An empty bucket and a 429 cooldown
/// are the same `loading…` on screen and very different problems, so
/// the limiter says which — and the request log writes it down.
pub const Wait = enum {
    /// It did not wait: there was a token.
    nothing,
    /// The bucket was empty; it refills at `rate`.
    tokens,
    /// A 429 had parked every process on this bucket until the
    /// cooldown was up.
    cooldown,
    /// `max_block_secs` passed and the limiter failed open. The caller
    /// sent anyway.
    gave_up,

    pub fn tag(w: Wait) []const u8 {
        return @tagName(w);
    }
};

/// One `acquire`, with what it cost. `ok` is the old boolean: false
/// means the limiter gave up and the caller should send anyway.
pub const Acquired = struct {
    ok: bool,
    /// Wall time the request was held before it went out.
    wait_ms: u64 = 0,
    waited_for: Wait = .nothing,
    /// Tokens left in the shared bucket after this one took its token;
    /// what the hover and the log both read.
    tokens_after: f64 = 0,
};

pub const Status = struct {
    tokens: f64,
    capacity: f64,
    rate: f64,
    baseline_rate: f64,
    throttles: u32,
    cooldown_remaining_secs: f64,
};

pub const Limiter = struct {
    gpa: Allocator,
    io: Io,
    /// Owned.
    path: []u8,
    cfg: Config,
    /// Requests the bucket let through, for the diagnostics.
    acquired: u32 = 0,

    pub fn init(gpa: Allocator, io: Io, path: []const u8, cfg: Config) Allocator.Error!Limiter {
        return .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path), .cfg = cfg };
    }

    /// The limiter for a service, at the shared path the environment
    /// resolves to and with that service's preset.
    pub fn forService(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error!Limiter {
        const p = try statePath(gpa, io, env, service);
        defer gpa.free(p);
        return init(gpa, io, p, configFor(service));
    }

    pub fn deinit(self: *Limiter) void {
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Block until a token is available. False when the limiter gave
    /// up (a wedged file, or `max_block_secs` passed); the caller
    /// should send anyway and let its own 429 handling decide.
    pub fn acquire(self: *Limiter) bool {
        return self.acquireDetailed().ok;
    }

    /// The same wait, with an account of it: how long, on what, and
    /// what was left afterwards. A pane that says `loading…` for three
    /// seconds can say WHY with this, and the request log writes it
    /// down for the run after.
    pub fn acquireDetailed(self: *Limiter) Acquired {
        const started = nowSecs(self.io);
        const deadline = started + self.cfg.max_block_secs;
        var jitter_seed: u32 = 0;
        // What the FIRST look found: a request held three seconds by an
        // empty bucket and one held three seconds by a cooldown are
        // different problems, and it is the first answer that names it.
        var cause: Wait = .nothing;
        var left: f64 = 0;
        while (true) {
            const now = nowSecs(self.io);
            var probe: Probe = .{ .cfg = self.cfg, .tokens_after = &left, .cooldown = undefined };
            var was_cooldown = false;
            probe.cooldown = &was_cooldown;
            const wait = self.withLockedState(now, probe) catch return .{ .ok = false, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = .gave_up };
            if (wait <= 0.0) {
                self.acquired += 1;
                return .{ .ok = true, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = cause, .tokens_after = left };
            }
            if (cause == .nothing) cause = if (was_cooldown) .cooldown else .tokens;
            jitter_seed +%= 1;
            const jittered = jitter(@min(wait, 5.0), jitter_seed);
            if (nowSecs(self.io) + jittered > deadline) return .{ .ok = false, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = .gave_up, .tokens_after = left };
            self.io.sleep(.fromMilliseconds(@intFromFloat(@max(jittered, 0.05) * 1000.0)), .awake) catch
                return .{ .ok = false, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = .gave_up, .tokens_after = left };
        }
    }

    /// One look at the bucket: take a token when there is one, else
    /// say how long until there is, and whether a cooldown is the
    /// reason there is not.
    const Probe = struct {
        cfg: Config,
        tokens_after: *f64,
        cooldown: *bool,

        fn apply(ctx: @This(), st: *State, at: f64) f64 {
            ctx.cooldown.* = st.cooldown_until > at;
            ctx.tokens_after.* = st.tokens;
            if (ctx.cooldown.*) return st.cooldown_until - at;
            if (st.tokens >= 1.0) {
                st.tokens -= 1.0;
                ctx.tokens_after.* = st.tokens;
                // Ease the shared rate back toward the baseline.
                st.rate = @min(ctx.cfg.rate, @max(st.rate * ctx.cfg.recover_factor, @max(st.rate, 0.0)));
                return 0.0;
            }
            const need = 1.0 - st.tokens;
            const cur = @max(st.rate, ctx.cfg.min_rate);
            return need / cur;
        }
    };

    /// Record a 429: park every process until `retry_after_secs` is
    /// up (the default cooldown when null) and cut the shared rate.
    pub fn penalize(self: *Limiter, retry_after_secs: ?f64) void {
        const now = nowSecs(self.io);
        _ = self.withLockedState(now, struct {
            cfg: Config,
            cd: f64,
            fn apply(ctx: @This(), st: *State, at: f64) f64 {
                st.rate = @max(ctx.cfg.min_rate, st.rate * ctx.cfg.penalty_factor);
                st.tokens = 0.0;
                st.cooldown_until = at + ctx.cd;
                st.throttles +|= 1;
                st.last_429 = at;
                return 0.0;
            }
        }{ .cfg = self.cfg, .cd = if (retry_after_secs) |s| (if (s > 0) s else self.cfg.default_cooldown_secs) else self.cfg.default_cooldown_secs }) catch {};
    }

    /// A snapshot for `--diag`; null when the file cannot be read.
    pub fn status(self: *Limiter) ?Status {
        const now = nowSecs(self.io);
        var snap: State = .{};
        _ = self.withLockedState(now, struct {
            out: *State,
            fn apply(ctx: @This(), st: *State, _: f64) f64 {
                ctx.out.* = st.*;
                return 0.0;
            }
        }{ .out = &snap }) catch return null;
        return .{
            .tokens = snap.tokens,
            .capacity = self.cfg.capacity,
            .rate = snap.rate,
            .baseline_rate = self.cfg.rate,
            .throttles = snap.throttles,
            .cooldown_remaining_secs = @max(snap.cooldown_until - now, 0.0),
        };
    }

    /// Open (creating), lock, read, refill, apply, write back.
    fn withLockedState(self: *Limiter, now: f64, ctx: anytype) !f64 {
        if (std.fs.path.dirname(self.path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        const file = try Io.Dir.cwd().createFile(self.io, self.path, .{ .read = true, .truncate = false, .lock = .exclusive });
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        const n = file.readPositionalAll(self.io, &buf, 0) catch 0;
        var st = parseState(buf[0..n]) orelse State{ .tokens = self.cfg.capacity, .rate = self.cfg.rate, .ts = now };
        const elapsed = @max(now - st.ts, 0.0);
        st.tokens = @min(self.cfg.capacity, st.tokens + elapsed * st.rate);
        if (st.rate <= 0.0) st.rate = self.cfg.rate;
        st.ts = now;
        const result = ctx.apply(&st, now);
        var out: [512]u8 = undefined;
        const text = renderState(&out, st);
        try file.setLength(self.io, 0);
        try file.writePositionalAll(self.io, text, 0);
        return result;
    }
};

/// The state file's JSON; null when it is empty or not the shape.
pub fn parseState(text: []const u8) ?State {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(State, arena_state.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed;
}

/// The state as the Python and Rust sides write it: six keys, floats as
/// decimals, ints as ints.
pub fn renderState(buf: []u8, st: State) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"ts\":{d},\"tokens\":{d},\"rate\":{d},\"cooldown_until\":{d},\"throttles\":{d},\"last_429\":{d}}}", .{
        st.ts, st.tokens, st.rate, st.cooldown_until, st.throttles, st.last_429,
    }) catch buf[0..0];
}

fn millisSince(start: f64, end: f64) u64 {
    const d = end - start;
    if (d <= 0) return 0;
    return @intFromFloat(d * 1000.0);
}

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

/// ±20% of `base`, from a counter rather than a random source — the
/// point is not to re-cluster after a shared cooldown, not secrecy.
fn jitter(base: f64, seed: u32) f64 {
    const noise: f64 = @as(f64, @floatFromInt(seed *% 2654435761 % 1000)) / 1000.0;
    return base * (0.8 + 0.4 * noise);
}

/// Longest service name the per-service environment override can be
/// spelled for; past it the override is simply not offered.
const max_service_len = 48;

/// `BITBUCKET_RATELIMIT_STATE`, `JIRA_RATELIMIT_STATE`, … — the
/// per-service override that names the file outright. Written into
/// `buf`; null when the service name will not fit.
pub fn stateEnvName(buf: []u8, service: []const u8) ?[]const u8 {
    const suffix = "_RATELIMIT_STATE";
    if (service.len == 0 or service.len + suffix.len > buf.len) return null;
    for (service, 0..) |c, i| buf[i] = std.ascii.toUpper(sanitizeByte(c));
    @memcpy(buf[service.len..][0..suffix.len], suffix);
    return buf[0 .. service.len + suffix.len];
}

/// The crate's own sanitiser: alphanumerics, `-` and `_` survive, the
/// rest becomes `_`, so a service name can never escape its directory.
fn sanitizeByte(c: u8) u8 {
    return if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
}

fn sanitize(buf: []u8, service: []const u8) []const u8 {
    const n = @min(service.len, buf.len);
    for (service[0..n], 0..) |c, i| buf[i] = sanitizeByte(c);
    return buf[0..n];
}

/// Where the shared bucket lives. Owned.
pub fn statePath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error![]u8 {
    var name_buf: [max_service_len + "_RATELIMIT_STATE".len]u8 = undefined;
    if (stateEnvName(&name_buf, service)) |name| {
        if (nonEmpty(env.get(name))) |p| return gpa.dupe(u8, p);
    }
    var svc_buf: [max_service_len]u8 = undefined;
    const svc = sanitize(&svc_buf, service);
    // The Python side's file name; a mixed fleet shares it.
    const shared_name = try std.fmt.allocPrint(gpa, "{s}-ratelimit.json", .{svc});
    defer gpa.free(shared_name);
    // mnml's own fallback lives under a `ratelimit/` directory instead.
    const own_name = try std.fmt.allocPrint(gpa, "{s}.json", .{svc});
    defer gpa.free(own_name);

    if (nonEmpty(env.get("TATTLE_ARTIFACTS_ROOT"))) |root| return std.fs.path.join(gpa, &.{ root, shared_name });
    if (nonEmpty(env.get("HOME"))) |home| {
        const shared = try std.fs.path.join(gpa, &.{ home, ".tattle-claude-artifacts" });
        defer gpa.free(shared);
        if (Io.Dir.cwd().access(io, shared, .{})) |_| {
            return std.fs.path.join(gpa, &.{ shared, shared_name });
        } else |_| {}
    }
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return std.fs.path.join(gpa, &.{ root, "ratelimit", own_name });
    if (nonEmpty(env.get("HOME"))) |home| return std.fs.path.join(gpa, &.{ home, ".config", "mnml", "ratelimit", own_name });
    return std.fs.path.join(gpa, &.{ "ratelimit", own_name });
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the presets are the Rust crate's constants, and an unknown service takes the tighter one" {
    try t.expectApproxEqAbs(@as(f64, 0.22), Config.bitbucket.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 40.0), Config.bitbucket.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.05), Config.bitbucket.min_rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 60.0), Config.bitbucket.default_cooldown_secs, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.33), Config.jira.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 60.0), Config.jira.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.08), Config.jira.min_rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 45.0), Config.jira.default_cooldown_secs, 1e-12);
    for ([_]Config{ Config.bitbucket, Config.jira }) |c| {
        try t.expectApproxEqAbs(@as(f64, 0.5), c.penalty_factor, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 1.02), c.recover_factor, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 120.0), c.max_block_secs, 1e-12);
    }
    try t.expectApproxEqAbs(Config.bitbucket.rate, configFor("bitbucket").rate, 1e-12);
    try t.expectApproxEqAbs(Config.jira.rate, configFor("Jira").rate, 1e-12);
    try t.expectApproxEqAbs(Config.bitbucket.rate, configFor("something-else").rate, 1e-12);
}

test "a state file written by the Rust crate reads back field for field" {
    // Written by hand from the crate's schema — six keys, serde's
    // spelling, the field order `State` declares them in.
    const fixture = @embedFile("testdata/rust-written-ratelimit.json");
    const st = parseState(fixture).?;
    try t.expectApproxEqAbs(@as(f64, 1789526218.009115), st.ts, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 12.5), st.tokens, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.11), st.rate, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1789526278.009115), st.cooldown_until, 1e-6);
    try t.expectEqual(@as(u32, 7), st.throttles);
    try t.expectApproxEqAbs(@as(f64, 1789526218.009115), st.last_429, 1e-6);
    // And what we write is what it reads: the same six keys, in the
    // same order, no others.
    var buf: [512]u8 = undefined;
    const text = renderState(&buf, st);
    for ([_][]const u8{ "\"ts\":", "\"tokens\":", "\"rate\":", "\"cooldown_until\":", "\"throttles\":", "\"last_429\":" }) |key| {
        try t.expect(std.mem.indexOf(u8, text, key) != null);
        try t.expect(std.mem.indexOf(u8, fixture, key) != null);
    }
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, text, "\":"));
    const back = parseState(text).?;
    try t.expectEqual(st.throttles, back.throttles);
    try t.expectApproxEqAbs(st.tokens, back.tokens, 1e-9);
    try t.expect(parseState("") == null);
    try t.expect(parseState("nonsense") == null);
    // A key the crate might add later is ignored, not fatal.
    try t.expect(parseState("{\"ts\":1,\"tokens\":2,\"rate\":0.2,\"cooldown_until\":0,\"throttles\":0,\"last_429\":0,\"future\":9}") != null);
}

test "two limiters on one file share the tokens, and one 429 parks both" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "bucket", "jira-ratelimit.json" });
    defer t.allocator.free(path);
    // Two independent limiters — stand-ins for two processes: a pane
    // and the statusline poller.
    var pane = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 3.0, .rate = 0.5, .max_block_secs = 0.2 });
    defer pane.deinit();
    var poller = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 3.0, .rate = 0.5, .max_block_secs = 0.2 });
    defer poller.deinit();

    // Three tokens between them, not three each.
    try t.expect(pane.acquire());
    try t.expect(poller.acquire());
    try t.expect(pane.acquire());
    try t.expect(!poller.acquire());
    try t.expectEqual(@as(u32, 2), pane.acquired);
    try t.expectEqual(@as(u32, 1), poller.acquired);

    // One 429 seen by one process parks the other.
    poller.penalize(30);
    try t.expect(!pane.acquire());
    const s = pane.status().?;
    try t.expectEqual(@as(u32, 1), s.throttles);
    try t.expectApproxEqAbs(@as(f64, 0.25), s.rate, 1e-9);
    try t.expect(s.cooldown_remaining_secs > 25.0);
    // The file is what any other process reads.
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"throttles\":1") != null);
}

test "acquire says what it waited on: nothing, an empty bucket, then a 429's cooldown" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "jira-ratelimit.json" });
    defer t.allocator.free(path);
    // Two tokens, and a refill slow enough that the third is a real
    // wait rather than a race with the clock.
    var l = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 2.0, .rate = 0.05, .max_block_secs = 0.3 });
    defer l.deinit();

    // A token in hand: no wait, and the count left is what the next
    // caller will find.
    const first = l.acquireDetailed();
    try t.expect(first.ok);
    try t.expectEqual(Wait.nothing, first.waited_for);
    try t.expectApproxEqAbs(@as(f64, 1.0), first.tokens_after, 0.01);
    const second = l.acquireDetailed();
    try t.expect(second.ok);
    try t.expectEqual(Wait.nothing, second.waited_for);
    try t.expectApproxEqAbs(@as(f64, 0.0), second.tokens_after, 0.01);

    // The bucket is empty and the refill is slower than the budget to
    // wait in: the limiter fails open rather than hanging the pane.
    const third = l.acquireDetailed();
    try t.expect(!third.ok);
    try t.expectEqual(Wait.gave_up, third.waited_for);

    // An empty bucket that WILL refill inside the budget: the request
    // goes out, having really waited, and the wait is blamed on the
    // tokens rather than on anything else.
    // On a bucket of its own: the refill rate lives in the FILE, so a
    // limiter pointed at the one above would inherit its 0.05.
    const quick_path = try std.fs.path.join(t.allocator, &.{ dir, "quick-ratelimit.json" });
    defer t.allocator.free(quick_path);
    var quick = try Limiter.init(t.allocator, t.io, quick_path, .{ .capacity = 1.0, .rate = 20.0, .max_block_secs = 5.0 });
    defer quick.deinit();
    try t.expect(quick.acquire());
    const waited = quick.acquireDetailed();
    try t.expect(waited.ok);
    try t.expectEqual(Wait.tokens, waited.waited_for);
    try t.expect(waited.wait_ms > 0);

    // A 429 is a different reason for the same silence, and the
    // account of the wait says so rather than blaming the refill.
    const parked_path = try std.fs.path.join(t.allocator, &.{ dir, "parked-ratelimit.json" });
    defer t.allocator.free(parked_path);
    var parked = try Limiter.init(t.allocator, t.io, parked_path, .{ .capacity = 4.0, .rate = 20.0, .max_block_secs = 5.0 });
    defer parked.deinit();
    try t.expect(parked.acquire());
    parked.penalize(0.05);
    const after_429 = parked.acquireDetailed();
    try t.expect(after_429.ok);
    try t.expectEqual(Wait.cooldown, after_429.waited_for);
    try t.expect(after_429.wait_ms > 0);

    // A cooldown longer than the budget fails open, and still names
    // the cooldown rather than pretending nothing happened.
    var impatient = try Limiter.init(t.allocator, t.io, parked_path, .{ .capacity = 4.0, .rate = 20.0, .max_block_secs = 0.0 });
    defer impatient.deinit();
    impatient.penalize(30);
    const gave_up = impatient.acquireDetailed();
    try t.expect(!gave_up.ok);
    try t.expectEqual(Wait.gave_up, gave_up.waited_for);
    // `acquire` is still the boolean every existing caller reads.
    try t.expect(!impatient.acquire());
}

test "the state path follows the Rust crate's resolution order, per service" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    for ([_][2][]const u8{
        .{ "bitbucket", "/data/ratelimit/bitbucket.json" },
        .{ "jira", "/data/ratelimit/jira.json" },
    }) |case| {
        const p = try statePath(t.allocator, t.io, &env, case[0]);
        defer t.allocator.free(p);
        try t.expectEqualStrings(case[1], p);
    }
    try env.put("TATTLE_ARTIFACTS_ROOT", "/shared");
    for ([_][2][]const u8{
        .{ "bitbucket", "/shared/bitbucket-ratelimit.json" },
        .{ "jira", "/shared/jira-ratelimit.json" },
    }) |case| {
        const p = try statePath(t.allocator, t.io, &env, case[0]);
        defer t.allocator.free(p);
        try t.expectEqualStrings(case[1], p);
    }
    // The per-service override wins, and only for its own service.
    try env.put("JIRA_RATELIMIT_STATE", "/tmp/j.json");
    {
        const p = try statePath(t.allocator, t.io, &env, "jira");
        defer t.allocator.free(p);
        try t.expectEqualStrings("/tmp/j.json", p);
        const other = try statePath(t.allocator, t.io, &env, "bitbucket");
        defer t.allocator.free(other);
        try t.expectEqualStrings("/shared/bitbucket-ratelimit.json", other);
    }
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("BITBUCKET_RATELIMIT_STATE", stateEnvName(&buf, "bitbucket").?);
    try t.expectEqualStrings("JIRA_RATELIMIT_STATE", stateEnvName(&buf, "jira").?);
    // A service name cannot walk out of the directory it is given.
    var svc_buf: [16]u8 = undefined;
    try t.expectEqualStrings("___x", sanitize(&svc_buf, "../x"));
}
