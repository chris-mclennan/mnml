//! A token bucket in front of every Jira call — the shape
//! `crates/mnml-ratelimit` gives the Rust tracker, in one file.
//!
//! Atlassian Cloud answers `429` with a `Retry-After` and expects a
//! client to pace itself; a refresh that fans out over a dozen tabs can
//! trip that in a second. `Limiter` hands out permits at a steady rate
//! with a burst allowance, so a burst of tab requests goes straight
//! through and a long grind is spread out. A `429` (or a 5xx) folds in a
//! server-directed pause on top: `penalise` pushes the next permit out
//! by what the header asked for, doubling per consecutive failure up to
//! `max_backoff_ms`, and `succeeded` clears it.
//!
//! The clock is a parameter (`nowMs`), so the tests run in no time at
//! all and the caller decides whether a wait actually sleeps.

const std = @import("std");

pub const Options = struct {
    /// Permits per second, steady state. 0 disables the limiter.
    rate_per_sec: f64 = 5.0,
    /// How many permits may be spent at once after an idle spell.
    burst: u32 = 5,
    /// The ceiling on the server-directed pause.
    max_backoff_ms: u64 = 60_000,
    /// The pause a `429` with no `Retry-After` gets.
    default_retry_after_ms: u64 = 1_000,
};

pub const Limiter = struct {
    opts: Options,
    /// Permits in the bucket, as a float so a fractional refill counts.
    tokens: f64,
    /// When the bucket was last refilled.
    last_ms: u64,
    /// No permit before this instant — a `Retry-After`, or our backoff.
    blocked_until_ms: u64 = 0,
    /// Consecutive failures; the backoff doubles with it.
    strikes: u32 = 0,

    pub fn init(opts: Options, now_ms: u64) Limiter {
        return .{ .opts = opts, .tokens = @floatFromInt(opts.burst), .last_ms = now_ms };
    }

    /// How long the caller must wait before its next call, in ms. 0 means
    /// go now — and spends the permit. A non-zero answer spends nothing:
    /// sleep that long and ask again.
    pub fn acquire(l: *Limiter, now_ms: u64) u64 {
        if (l.opts.rate_per_sec <= 0) return 0;
        if (now_ms < l.blocked_until_ms) return l.blocked_until_ms - now_ms;
        l.refill(now_ms);
        if (l.tokens >= 1.0) {
            l.tokens -= 1.0;
            return 0;
        }
        const need = 1.0 - l.tokens;
        const ms = need / l.opts.rate_per_sec * 1000.0;
        return @max(@as(u64, @intFromFloat(@ceil(ms))), 1);
    }

    fn refill(l: *Limiter, now_ms: u64) void {
        if (now_ms <= l.last_ms) {
            l.last_ms = now_ms;
            return;
        }
        const elapsed: f64 = @floatFromInt(now_ms - l.last_ms);
        l.tokens = @min(@as(f64, @floatFromInt(l.opts.burst)), l.tokens + elapsed / 1000.0 * l.opts.rate_per_sec);
        l.last_ms = now_ms;
    }

    /// The server pushed back. `retry_after_ms` is the header's value
    /// when it sent one. The pause doubles per consecutive strike.
    pub fn penalise(l: *Limiter, now_ms: u64, retry_after_ms: ?u64) void {
        l.strikes +|= 1;
        const base = retry_after_ms orelse l.opts.default_retry_after_ms;
        const shift: u6 = @intCast(@min(l.strikes - 1, 16));
        const scaled = std.math.mul(u64, base, @as(u64, 1) << shift) catch l.opts.max_backoff_ms;
        const wait = @min(scaled, l.opts.max_backoff_ms);
        l.blocked_until_ms = @max(l.blocked_until_ms, now_ms + wait);
        l.tokens = 0;
    }

    /// A call came back fine: forget the strikes.
    pub fn succeeded(l: *Limiter) void {
        l.strikes = 0;
    }

    /// Whether a status is worth a `penalise` — the two Jira answers that
    /// mean "slow down", never a 4xx we caused.
    pub fn shouldPenalise(status: u16) bool {
        return status == 429 or (status >= 500 and status <= 599);
    }
};

/// `Retry-After` as milliseconds. Jira sends whole seconds; a date form
/// (RFC 7231 allows one) is not parsed — the caller's default stands.
pub fn parseRetryAfter(value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const secs = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return @as(u64, secs) * 1000;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the burst goes straight through, then the rate paces the rest" {
    var l = Limiter.init(.{ .rate_per_sec = 2.0, .burst = 3 }, 0);
    try testing.expectEqual(@as(u64, 0), l.acquire(0));
    try testing.expectEqual(@as(u64, 0), l.acquire(0));
    try testing.expectEqual(@as(u64, 0), l.acquire(0));
    // The bucket is empty: the fourth waits half a second at 2/s.
    try testing.expectEqual(@as(u64, 500), l.acquire(0));
    // Waiting that long makes the permit available and spends it.
    try testing.expectEqual(@as(u64, 0), l.acquire(500));
    try testing.expectEqual(@as(u64, 500), l.acquire(500));
    // A long idle refills to the burst, never past it.
    try testing.expectEqual(@as(u64, 0), l.acquire(60_000));
    try testing.expectEqual(@as(u64, 0), l.acquire(60_000));
    try testing.expectEqual(@as(u64, 0), l.acquire(60_000));
    try testing.expectEqual(@as(u64, 500), l.acquire(60_000));
}

test "rate 0 disables the limiter" {
    var l = Limiter.init(.{ .rate_per_sec = 0 }, 0);
    var i: usize = 0;
    while (i < 100) : (i += 1) try testing.expectEqual(@as(u64, 0), l.acquire(0));
}

test "a 429 pauses for Retry-After and doubles per strike; a success clears it" {
    var l = Limiter.init(.{ .rate_per_sec = 100, .burst = 10, .max_backoff_ms = 8_000 }, 0);
    l.penalise(0, 2_000);
    try testing.expectEqual(@as(u64, 2_000), l.acquire(0));
    try testing.expectEqual(@as(u64, 1_000), l.acquire(1_000));
    // A second strike doubles: 4 s from now, which is past the first pause.
    l.penalise(1_000, 2_000);
    try testing.expectEqual(@as(u64, 4_000), l.acquire(1_000));
    l.succeeded();
    l.penalise(10_000, 2_000);
    try testing.expectEqual(@as(u64, 2_000), l.acquire(10_000));
    // The ceiling holds however many strikes pile up.
    var i: usize = 0;
    while (i < 20) : (i += 1) l.penalise(10_000, 2_000);
    try testing.expectEqual(@as(u64, 8_000), l.acquire(10_000));
}

test "a 429 with no header takes the default pause" {
    var l = Limiter.init(.{ .default_retry_after_ms = 750 }, 0);
    l.penalise(0, null);
    try testing.expectEqual(@as(u64, 750), l.acquire(0));
}

test "only 429 and 5xx are worth a penalty" {
    try testing.expect(Limiter.shouldPenalise(429));
    try testing.expect(Limiter.shouldPenalise(500));
    try testing.expect(Limiter.shouldPenalise(503));
    try testing.expect(!Limiter.shouldPenalise(200));
    try testing.expect(!Limiter.shouldPenalise(401));
    try testing.expect(!Limiter.shouldPenalise(404));
}

test "Retry-After: whole seconds; a date form is not parsed" {
    try testing.expectEqual(@as(?u64, 3_000), parseRetryAfter("3"));
    try testing.expectEqual(@as(?u64, 0), parseRetryAfter(" 0 "));
    try testing.expect(parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == null);
    try testing.expect(parseRetryAfter("") == null);
}
