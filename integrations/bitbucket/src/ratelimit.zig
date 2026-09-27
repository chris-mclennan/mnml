//! The shared token bucket every Bitbucket request passes through —
//! `mnml_sdk.ratelimit`, bound to this service.
//!
//! Bitbucket counts per account and per IP, so the pane is one of
//! several things on this machine drawing on one budget: another pane,
//! the statusline poller, the Rust reference, the Python
//! `bb_ratelimit` scripts. They all take turns on ONE state file with
//! the same six JSON keys and the same rules, so opening the pane while
//! a script is mid-report never stacks requests into a 429 for both.
//! The SDK module holds the bucket; this file only says which service
//! it is.
//!
//! The file is `bitbucket-ratelimit.json` in a shared folder, or
//! `ratelimit/bitbucket.json` under mnml's data root; which one, and
//! everything else about the mechanism, is in
//! `sdk/mnml-sdk/src/ratelimit.zig` (`statePath`).

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
pub const parseState = shared.parseState;
pub const renderState = shared.renderState;

/// Bitbucket's preset — the Rust crate's constants.
pub const config: Config = .bitbucket;

/// Where the shared bucket lives. Owned.
pub fn statePath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    return shared.statePath(gpa, io, env, service);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "the Bitbucket bucket is the SDK's, at this service's path" {
    try t.expectApproxEqAbs(@as(f64, 0.22), config.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 40.0), config.capacity, 1e-12);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/data/ratelimit/bitbucket.json", p);
    }
    try env.put("TATTLE_ARTIFACTS_ROOT", "/shared");
    {
        const p = try statePath(t.allocator, t.io, &env);
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/shared/bitbucket-ratelimit.json", p);
    }
    try env.put("BITBUCKET_RATELIMIT_STATE", "/tmp/x.json");
    const p = try statePath(t.allocator, t.io, &env);
    defer t.allocator.free(p);
    try t.expectEqualStrings("/tmp/x.json", p);
}
