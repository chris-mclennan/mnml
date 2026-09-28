//! The shared token bucket every Jira call passes through —
//! `mnml_sdk.ratelimit`, bound to this service.
//!
//! It used to be a bucket per process, which is the wrong unit: three
//! Jira panes and the statusline poller each held their own idea of the
//! budget, so four processes pacing themselves perfectly still spent
//! four times the allowance and Atlassian answered all four with a 429.
//! The bucket now lives in one file — `jira-ratelimit.json` in
//! `$MNML_SHARED_STATE_DIR`, or `ratelimit/jira.json` under mnml's data root
//! (`statePath` in the SDK module) — flock'd, with the same six keys the Bitbucket bucket and the Rust
//! crate use — so every pane, the poller and anything else on the
//! machine take turns on ONE allowance, and one 429 parks all of them.
//!
//! The mechanism is the SDK module's; this file says which service it
//! is, turns the user's `rate` block into the bucket's numbers, and
//! keeps the two HTTP-shaped helpers that are about Jira's replies
//! rather than about the bucket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const shared = @import("mnml_sdk").ratelimit;
const config = @import("config.zig");

pub const service = "jira";

pub const Config = shared.Config;
pub const State = shared.State;
pub const Status = shared.Status;
pub const Limiter = shared.Limiter;
pub const Acquired = shared.Acquired;
pub const Notice = shared.Notice;
pub const Draws = shared.Draws;
pub const recentDraws = shared.recentDraws;
pub const Wait = shared.Wait;
pub const parseState = shared.parseState;
pub const renderState = shared.renderState;

/// Jira's preset — the Rust crate's constants.
pub const default_config: Config = .jira;

/// The user's `rate` block as the bucket's numbers. The two names that
/// differ do so because the file is shared: `burst` is the bucket's
/// capacity, `cooldown_secs` the park a 429 with no `Retry-After` gets.
pub fn configFrom(rate: config.Rate) Config {
    var c = default_config;
    if (rate.per_sec > 0) c.rate = rate.per_sec;
    if (rate.burst > 0) c.capacity = @floatFromInt(rate.burst);
    if (rate.cooldown_secs > 0) c.default_cooldown_secs = @floatFromInt(rate.cooldown_secs);
    if (rate.max_block_secs > 0) c.max_block_secs = @floatFromInt(rate.max_block_secs);
    return c;
}

/// Where the shared bucket lives. Owned.
pub fn statePath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    return shared.statePath(gpa, io, env, service);
}

/// Whether a status is worth a `penalize` — the two Jira answers that
/// mean "slow down", never a 4xx we caused.
pub fn shouldPenalise(status: u16) bool {
    return status == 429 or (status >= 500 and status <= 599);
}

/// `Retry-After` as seconds, which is what `penalize` takes. Jira sends
/// whole seconds; a date form (RFC 7231 allows one) is not parsed — the
/// caller's default cooldown stands.
pub fn parseRetryAfter(value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const secs = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return @floatFromInt(secs);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "the Jira bucket is the SDK's, at this service's own file" {
    try testing.expectApproxEqAbs(@as(f64, 0.33), default_config.rate, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 60.0), default_config.capacity, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 45.0), default_config.default_cooldown_secs, 1e-12);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    {
        const p = try statePath(testing.allocator, testing.io, &env);
        defer testing.allocator.free(p);
        try sdk_testing.expectPath("/data/ratelimit/jira.json", p);
    }
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    const p = try statePath(testing.allocator, testing.io, &env);
    defer testing.allocator.free(p);
    // The format contract's file name, so a pane, a poller and any
    // other tool that agrees to the format all land on one file.
    try sdk_testing.expectPath("/shared/jira-ratelimit.json", p);
}

test "the user's rate block becomes the bucket's numbers, and an unset field keeps the preset" {
    const tuned = configFrom(.{ .per_sec = 1.5, .burst = 10, .cooldown_secs = 20, .max_block_secs = 30 });
    try testing.expectApproxEqAbs(@as(f64, 1.5), tuned.rate, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10.0), tuned.capacity, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 20.0), tuned.default_cooldown_secs, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 30.0), tuned.max_block_secs, 1e-12);
    // The penalty shape is never the user's to set — it is what the
    // other processes on the file expect.
    try testing.expectApproxEqAbs(default_config.penalty_factor, tuned.penalty_factor, 1e-12);
    try testing.expectApproxEqAbs(default_config.min_rate, tuned.min_rate, 1e-12);
    const zeroed = configFrom(.{ .per_sec = 0, .burst = 0, .cooldown_secs = 0, .max_block_secs = 0 });
    try testing.expectApproxEqAbs(default_config.rate, zeroed.rate, 1e-12);
    try testing.expectApproxEqAbs(default_config.capacity, zeroed.capacity, 1e-12);
}

test "a pane and the poller share one Jira bucket: three tokens between them, and one 429 parks both" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "jira-ratelimit.json" });
    defer testing.allocator.free(path);
    const cfg = configFrom(.{ .per_sec = 0.5, .burst = 3, .max_block_secs = 1 });
    var pane = try Limiter.init(testing.allocator, testing.io, path, .{ .capacity = cfg.capacity, .rate = cfg.rate, .max_block_secs = 0.2 });
    defer pane.deinit();
    var poller = try Limiter.init(testing.allocator, testing.io, path, .{ .capacity = cfg.capacity, .rate = cfg.rate, .max_block_secs = 0.2 });
    defer poller.deinit();
    try testing.expect(pane.acquire());
    try testing.expect(poller.acquire());
    try testing.expect(pane.acquire());
    try testing.expect(!poller.acquire());
    poller.penalize(30);
    try testing.expect(!pane.acquire());
    try testing.expectEqual(@as(u32, 1), pane.status().?.throttles);
}

test "only 429 and 5xx are worth a penalty" {
    try testing.expect(shouldPenalise(429));
    try testing.expect(shouldPenalise(500));
    try testing.expect(shouldPenalise(503));
    try testing.expect(!shouldPenalise(200));
    try testing.expect(!shouldPenalise(401));
    try testing.expect(!shouldPenalise(404));
}

test "Retry-After: whole seconds, which is what penalize takes; a date form is not parsed" {
    try testing.expectEqual(@as(?f64, 3), parseRetryAfter("3"));
    try testing.expectEqual(@as(?f64, 0), parseRetryAfter(" 0 "));
    try testing.expect(parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == null);
    try testing.expect(parseRetryAfter("") == null);
}
