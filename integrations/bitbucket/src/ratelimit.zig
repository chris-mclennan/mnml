//! The shared token bucket every Bitbucket request passes through.
//! Bitbucket counts per account and per IP, so the pane is one of
//! several things on this machine drawing on one budget — the Rust
//! reference and the Python `bb_ratelimit` scripts already take turns
//! on ONE state file, and this is the same file, the same JSON keys and
//! the same rules, so opening the pane while a script is mid-report
//! never stacks requests into a 429 for both:
//!
//!   * `acquire` refills the bucket from the wall clock, waits out a
//!     cooldown, takes a token when there is one, and otherwise waits
//!     for one to refill (jittered, so processes released together do
//!     not re-cluster). Past `max_block_secs` it gives up and lets the
//!     request go — a wedged state file must never take the pane
//!     offline.
//!   * `penalize` records a 429: the shared rate is cut, the tokens
//!     emptied, and every process parked until `Retry-After` is up.
//!
//! The file is `<root>/bitbucket-ratelimit.json` with
//! `{"ts","tokens","rate","cooldown_until","throttles","last_429"}`,
//! read-modify-written under an exclusive advisory lock. Where the
//! root is: `BITBUCKET_RATELIMIT_STATE` names the file outright (the
//! corpus), else `TATTLE_ARTIFACTS_ROOT`, else `~/.tattle-claude-artifacts`
//! when that folder exists, else `<MNML_DATA_ROOT>/ratelimit/bitbucket.json`,
//! else `~/.config/mnml/ratelimit/bitbucket.json` — the reference's
//! resolution order, so both sides find the same bucket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Config = struct {
    /// Tokens per second the bucket refills at. Bitbucket's sustained
    /// budget is ~1000 requests an hour; 0.22 leaves headroom.
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
};

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

    pub fn deinit(self: *Limiter) void {
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Block until a token is available. False when the limiter gave
    /// up (a wedged file, or `max_block_secs` passed); the caller
    /// should send anyway and let its own 429 handling decide.
    pub fn acquire(self: *Limiter) bool {
        const deadline = nowSecs(self.io) + self.cfg.max_block_secs;
        var jitter_seed: u32 = 0;
        while (true) {
            const now = nowSecs(self.io);
            const wait = self.withLockedState(now, struct {
                cfg: Config,
                fn apply(ctx: @This(), st: *State, at: f64) f64 {
                    if (st.cooldown_until > at) return st.cooldown_until - at;
                    if (st.tokens >= 1.0) {
                        st.tokens -= 1.0;
                        // Ease the shared rate back toward the baseline.
                        st.rate = @min(ctx.cfg.rate, @max(st.rate * ctx.cfg.recover_factor, @max(st.rate, 0.0)));
                        return 0.0;
                    }
                    const need = 1.0 - st.tokens;
                    const cur = @max(st.rate, ctx.cfg.min_rate);
                    return need / cur;
                }
            }{ .cfg = self.cfg }) catch return false;
            if (wait <= 0.0) {
                self.acquired += 1;
                return true;
            }
            jitter_seed +%= 1;
            const jittered = jitter(@min(wait, 5.0), jitter_seed);
            if (nowSecs(self.io) + jittered > deadline) return false;
            self.io.sleep(.fromMilliseconds(@intFromFloat(@max(jittered, 0.05) * 1000.0)), .awake) catch return false;
        }
    }

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

/// The state as the Python side writes it: six keys, floats as
/// decimals, ints as ints.
pub fn renderState(buf: []u8, st: State) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"ts\":{d},\"tokens\":{d},\"rate\":{d},\"cooldown_until\":{d},\"throttles\":{d},\"last_429\":{d}}}", .{
        st.ts, st.tokens, st.rate, st.cooldown_until, st.throttles, st.last_429,
    }) catch buf[0..0];
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

/// Where the shared bucket lives, the reference's resolution order.
/// Owned.
pub fn statePath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    if (nonEmpty(env.get("BITBUCKET_RATELIMIT_STATE"))) |p| return gpa.dupe(u8, p);
    if (nonEmpty(env.get("TATTLE_ARTIFACTS_ROOT"))) |root| return std.fs.path.join(gpa, &.{ root, "bitbucket-ratelimit.json" });
    if (nonEmpty(env.get("HOME"))) |home| {
        const shared = try std.fs.path.join(gpa, &.{ home, ".tattle-claude-artifacts" });
        defer gpa.free(shared);
        if (Io.Dir.cwd().access(io, shared, .{})) |_| {
            return std.fs.path.join(gpa, &.{ shared, "bitbucket-ratelimit.json" });
        } else |_| {}
    }
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return std.fs.path.join(gpa, &.{ root, "ratelimit", "bitbucket.json" });
    if (nonEmpty(env.get("HOME"))) |home| return std.fs.path.join(gpa, &.{ home, ".config", "mnml", "ratelimit", "bitbucket.json" });
    return gpa.dupe(u8, "ratelimit/bitbucket.json");
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the state round-trips through the Python side's spelling" {
    const st = parseState("{\"ts\": 1789526218.009115, \"tokens\": 0.0044, \"rate\": 0.22, \"cooldown_until\": 1789507367.8, \"throttles\": 36, \"last_429\": 1789507307.8}").?;
    try t.expectEqual(@as(u32, 36), st.throttles);
    try t.expectApproxEqAbs(@as(f64, 0.22), st.rate, 1e-9);
    var buf: [512]u8 = undefined;
    const text = renderState(&buf, st);
    const back = parseState(text).?;
    try t.expectApproxEqAbs(st.tokens, back.tokens, 1e-9);
    try t.expectEqual(st.throttles, back.throttles);
    try t.expect(parseState("") == null);
    try t.expect(parseState("nonsense") == null);
}

test "a fresh bucket lets a burst through, then a 429 parks it and cuts the rate" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "bucket", "bitbucket-ratelimit.json" });
    defer t.allocator.free(path);
    var lim = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 3.0, .rate = 0.5, .max_block_secs = 0.2 });
    defer lim.deinit();
    try t.expect(lim.acquire());
    try t.expect(lim.acquire());
    try t.expect(lim.acquire());
    try t.expectEqual(@as(u32, 3), lim.acquired);
    var s = lim.status().?;
    try t.expect(s.tokens < 1.0);
    // Empty: the next acquire would wait two seconds for a token and
    // gives up at the 0.2 s ceiling instead — failing open.
    try t.expect(!lim.acquire());
    lim.penalize(30);
    s = lim.status().?;
    try t.expectEqual(@as(u32, 1), s.throttles);
    try t.expectApproxEqAbs(@as(f64, 0.25), s.rate, 1e-9);
    try t.expect(s.cooldown_remaining_secs > 25.0);
    // The file is what the other processes read.
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"throttles\":1") != null);
}

test "the state path follows the reference's resolution order" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try t.expectEqualStrings("/data/ratelimit/bitbucket.json", p);
    }
    try env.put("TATTLE_ARTIFACTS_ROOT", "/shared");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try t.expectEqualStrings("/shared/bitbucket-ratelimit.json", p);
    }
    try env.put("BITBUCKET_RATELIMIT_STATE", "/tmp/x.json");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try t.expectEqualStrings("/tmp/x.json", p);
    }
}
