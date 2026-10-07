//! The token bucket every Bitbucket request passes through —
//! `mnml_sdk.ratelimit`, bound to this service.
//!
//! Bitbucket Cloud counts its rate limit per TOKEN, not per IP
//! (measured 2026-10-07: a second token on the same machine got 200s
//! while the first sat in a 429). So the bucket is the token's: the
//! pane and its statusline poller draw on `bitbucket-ratelimit-<id>.json`,
//! `<id>` the first 12 hex of a sha256 of the credential
//! (`mnml_sdk.ratelimit.tokenId`), beside the shared
//! `bitbucket-ratelimit.json` that anything with no credential to name
//! still uses. Every process spending the same token takes turns on
//! that one file with the same six JSON keys and the same rules, so
//! opening the pane while a poll is mid-flight never stacks requests
//! into a 429 for both. The draws file stays one for the service,
//! `bitbucket-draws.jsonl`; each line names its `token_id`.
//!
//! The directory is `$MNML_SHARED_STATE_DIR`, or `ratelimit/` under
//! mnml's data root; `BITBUCKET_RATELIMIT_STATE` names the file
//! outright and so wins over the per-token name. Everything else about
//! the mechanism is in `sdk/mnml-sdk/src/ratelimit.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const shared = @import("mnml_sdk").ratelimit;

pub const service = "bitbucket";

pub const Config = shared.Config;
pub const State = shared.State;
pub const Status = shared.Status;
pub const Limiter = shared.Limiter;
pub const Acquired = shared.Acquired;
pub const Notice = shared.Notice;
pub const Draws = shared.Draws;
pub const recentDraws = shared.recentDraws;
pub const Wait = shared.Wait;
pub const TokenId = shared.TokenId;
pub const parseState = shared.parseState;
pub const renderState = shared.renderState;

/// Bitbucket's preset: 1.2/s, 40 of burst, 30 s parked after a 429.
pub const config: Config = .bitbucket;

/// The preset, with the two knobs `config.zon`'s `.rate` block sets.
/// What the config says wins; the rest — the 30 s cooldown, the floor a
/// cut stops at — is the preset's.
pub fn configWith(rate_per_sec: f64, capacity: f64) Config {
    var c = config;
    c.rate = rate_per_sec;
    c.capacity = capacity;
    return c;
}

/// Where the shared bucket lives — the one with no credential. Owned.
pub fn statePath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    return shared.statePath(gpa, io, env, service);
}

/// Where this credential's bucket lives — a bare token or the
/// `Authorization` value it goes out as. Owned.
pub fn statePathFor(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, credential: ?[]const u8) Allocator.Error![]u8 {
    return shared.statePathFor(gpa, io, env, service, credential);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "the Bitbucket bucket is the SDK's, at this service's path, with the measured preset" {
    try t.expectApproxEqAbs(@as(f64, 1.2), config.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 40.0), config.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 30.0), config.default_cooldown_secs, 1e-12);
    // A config override wins over the preset's rate and burst, and
    // keeps its cooldown.
    const c = configWith(0.5, 10);
    try t.expectApproxEqAbs(@as(f64, 0.5), c.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 10.0), c.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 30.0), c.default_cooldown_secs, 1e-12);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/data/ratelimit/bitbucket.json", p);
    }
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/shared/bitbucket-ratelimit.json", p);
    }
    {
        // sha256("abc")[:12] — the SDK's pinned vector.
        const p = try statePathFor(t.allocator, t.io, &env, "Bearer abc");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/shared/bitbucket-ratelimit-ba7816bf8f01.json", p);
    }
    try env.put("BITBUCKET_RATELIMIT_STATE", "/tmp/x.json");
    const p = try statePath(t.allocator, t.io, &env);
    defer t.allocator.free(p);
    try t.expectEqualStrings("/tmp/x.json", p);
}
