//! The API budget: how close an integration is to the limit its API
//! sets, and how the client behaves near it. One object per pane
//! process, shared by the client (which writes it on every request)
//! and the paint loop (which reads it for the header's budget chip and
//! its hover). Both first-party integrations hold one and draw the
//! chip from it through `pane.chrome`, so the Jira pane and the
//! Bitbucket pane say the same thing in the same place.
//!
//! What it keeps:
//!
//!   * **The latest rate-limit headers** (`request_log.RateLimit`:
//!     `X-RateLimit-Limit` / `-Remaining` / `-Reset` / `-NearLimit`,
//!     `Retry-After`), as the server last sent them. The chip reads
//!     `812/1000` off them; with none it reads `37/h`, the calls this
//!     process made in the last sixty minutes.
//!   * **A pause.** A 429 parks the client until `Retry-After` (or, with
//!     none, an exponential backoff with jitter, capped — `Backoff`).
//!     The chip says `paused until 14:03:22` rather than the pane
//!     retrying blindly; a request made while the pause runs waits it
//!     out (when it is short) or is refused without going out (when it
//!     is long). `cancelWait` — a click on the chip, or the pane's key —
//!     stops the wait. Only a read is ever retried automatically: a
//!     write that met a 429 goes back to the pane as a failure.
//!   * **Cache hits and misses.** A read answered without a body over
//!     the wire — a local cache, or a 304 to a conditional GET — is a
//!     hit; a read that carried a body back is a miss. Writes are
//!     neither.
//!   * **A daily tally**, persisted as `<data root>/budget/<service>.tally`
//!     under an exclusive lock, so every process on the machine that
//!     spends the same service's budget adds to the same count:
//!     `2026-09-25 120` per line, newest first, eight days kept.
//!   * **Dry run.** When on, the client writes the request it WOULD have
//!     made into the request log (`"dry":true`, no status) and answers
//!     from what it already holds instead of calling out. The chip says
//!     `DRY`.
//!   * **A shared bucket file**, when `budget.shared_bucket` names one:
//!     a machine-wide token bucket every caller on the machine draws
//!     from, read-modify-written under an exclusive advisory lock. One
//!     token per request; an empty bucket refuses the request (the pane
//!     skips that round rather than calling), and a 429 is written into
//!     it as a cooldown every other caller honours. A missing or
//!     unreadable file is no bucket — it never takes the API away. The
//!     file's shape is a contract (`docs/SDK.md`, `Bucket`).
//!   * **What the poller is doing** — the feed seam's state
//!     (`feed.State`), set by the pane, so the chip can say `feed` or
//!     the interval and the hover can say why.
//!
//! Nothing here holds a header value other than the numbers above, a
//! body, or a token.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const request_log = @import("request_log.zig");
const feed = @import("feed.zig");
const ratelimit = @import("ratelimit.zig");

pub const RateLimit = request_log.RateLimit;
pub const Cache = request_log.Cache;
/// The one header reader — an allow-list of names, numbers only.
pub const parseHeader = request_log.rateLimitHeader;

// ─── the tiers the chip wears ────────────────────────────────────────────

/// The chip's colour, on the host usage meter's thresholds: under 60 %
/// spent is fine, 60 % is worth a look, 85 % is the alarm.
pub const Tier = enum { ok, warn, alarm };

pub fn tierOf(used_pct: u32) Tier {
    return if (used_pct >= 85) .alarm else if (used_pct >= 60) .warn else .ok;
}

// ─── backoff ─────────────────────────────────────────────────────────────

/// What a 429 costs. `Retry-After` is honoured as sent (up to
/// `max_retry_after_secs` — a server asking for a day is a server
/// misbehaving); without it the pause is `base_secs` doubling per
/// attempt, jittered ±`jitter_pct`, never past `cap_secs`.
pub const Backoff = struct {
    base_secs: u32 = 15,
    cap_secs: u32 = 120,
    /// Attempts per read, the first included.
    max_attempts: u32 = 3,
    jitter_pct: u32 = 20,
    max_retry_after_secs: u32 = 3600,
    /// A pause longer than this is not waited out inside a request:
    /// the 429 goes back to the pane, which says until when, and a
    /// request made before it is up is refused (nothing goes out).
    /// Shorter ones are waited — visibly, cancellably — and the read
    /// asked again. Thirty seconds: the longest the forge pane ever
    /// slept through before, so no pane waits longer than it did.
    wait_in_request_secs: u32 = 30,

    /// Seconds to pause after attempt `attempt` (from 1) met a 429.
    pub fn delaySecs(b: Backoff, attempt: u32, retry_after: ?u32, rng: std.Random) u32 {
        if (retry_after) |ra| return @min(ra, b.max_retry_after_secs);
        const shift: u6 = @intCast(@min(attempt -| 1, 32));
        const exp: u64 = @min(@as(u64, b.base_secs) << shift, @as(u64, b.cap_secs));
        if (b.jitter_pct == 0 or exp == 0) return @intCast(exp);
        const span = exp * @min(b.jitter_pct, 100) / 100;
        const j = rng.uintAtMost(u64, 2 * span);
        return @intCast(@min(exp - span + j, @as(u64, b.cap_secs)));
    }

    /// May attempt `attempt` be followed by another? Only a read may.
    pub fn retries(b: Backoff, attempt: u32, idempotent: bool) bool {
        return idempotent and attempt < @max(b.max_attempts, 1);
    }
};

// ─── the last hour ───────────────────────────────────────────────────────

/// Calls in the last sixty minutes, in one-minute buckets.
pub const Hour = struct {
    minute: [60]i64 = @splat(-1),
    count: [60]u32 = @splat(0),

    pub fn bump(h: *Hour, now_secs: i64) void {
        const m = @divFloor(now_secs, 60);
        const slot: usize = @intCast(@mod(m, 60));
        if (h.minute[slot] != m) {
            h.minute[slot] = m;
            h.count[slot] = 0;
        }
        h.count[slot] += 1;
    }

    pub fn total(h: *const Hour, now_secs: i64) u32 {
        const m = @divFloor(now_secs, 60);
        var n: u32 = 0;
        for (h.minute, h.count) |at, c| {
            if (at >= 0 and at <= m and m - at < 60) n += c;
        }
        return n;
    }
};

// ─── the daily tally ─────────────────────────────────────────────────────

/// Days since the epoch on the local calendar: `now` shifted by the
/// zone's offset, so the tally rolls over at the reader's midnight.
pub fn dayOf(now_secs: i64, offset_secs: i64) i64 {
    return @divFloor(now_secs + offset_secs, 86400);
}

/// Seconds east of UTC at `secs`, from libc's `localtime_r`; 0 where
/// there is no zone reader (Windows).
pub fn localOffset(secs: i64) i64 {
    if (builtin.os.tag == .windows or !builtin.link_libc) return 0;
    var tm: Tm = undefined;
    const at: i64 = secs;
    if (localtime_r(&at, &tm) == null) return 0;
    return @intCast(tm.tm_gmtoff);
}

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

pub const Tally = struct {
    pub const kept = 8;
    pub const Day = struct { day: i64 = std.math.minInt(i64), n: u32 = 0 };
    /// Newest first.
    days: [kept]Day = @splat(.{}),

    pub fn bump(t: *Tally, day: i64) void {
        if (t.days[0].day == day) {
            t.days[0].n += 1;
            return;
        }
        // A clock that went backwards finds its day further down.
        for (t.days[1..]) |*d| if (d.day == day) {
            d.n += 1;
            return;
        };
        std.mem.copyBackwards(Day, t.days[1..], t.days[0 .. kept - 1]);
        t.days[0] = .{ .day = day, .n = 1 };
    }

    pub fn on(t: *const Tally, day: i64) u32 {
        for (t.days) |d| if (d.day == day) return d.n;
        return 0;
    }

    /// Today, yesterday, and the seven days ending today.
    pub const Counts = struct { today: u32, yesterday: u32, week: u32 };

    pub fn counts(t: *const Tally, today: i64) Counts {
        var week: u32 = 0;
        for (t.days) |d| if (d.n > 0 and d.day <= today and today - d.day < 7) {
            week += d.n;
        };
        return .{ .today = t.on(today), .yesterday = t.on(today - 1), .week = week };
    }

    /// `2026-09-25 120` per line, newest first. Anything else is
    /// skipped: a torn file costs a day's count, never the pane.
    pub fn parse(text: []const u8) Tally {
        var out: Tally = .{};
        var it = std.mem.splitScalar(u8, text, '\n');
        var i: usize = 0;
        while (it.next()) |raw| {
            if (i >= kept) break;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len < 12 or line[10] != ' ') continue;
            const day = dayOfIso(line[0..10]) orelse continue;
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, line[11..], " "), 10) catch continue;
            out.days[i] = .{ .day = day, .n = n };
            i += 1;
        }
        return out;
    }

    pub fn render(t: *const Tally, buf: []u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        for (t.days) |d| {
            if (d.day == std.math.minInt(i64)) continue;
            var date: [10]u8 = undefined;
            w.print("{s} {d}\n", .{ isoDate(&date, d.day), d.n }) catch break;
        }
        return w.buffered();
    }
};

fn dayOfIso(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return request_log.daysFromCivil(y, m, d);
}

/// `YYYY-MM-DD` for a day number (Hinnant's `civil_from_days`).
pub fn isoDate(buf: *[10]u8, day: i64) []const u8 {
    const z = day + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(y, 0))), @as(u64, @intCast(m)), @as(u64, @intCast(d)) }) catch {};
    return buf;
}

/// `14:03:22` for a Unix time on the local clock.
pub fn clockText(buf: *[8]u8, secs: i64, offset_secs: i64) []const u8 {
    const s = @mod(secs + offset_secs, 86400);
    _ = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(s, 3600))), @as(u64, @intCast(@mod(@divFloor(s, 60), 60))), @as(u64, @intCast(@mod(s, 60))) }) catch {};
    return buf;
}

// ─── the shared bucket file ──────────────────────────────────────────────

/// The `budget` block both first-party integrations carry in their
/// `config.zon`.
pub const Settings = struct {
    /// A machine-wide token bucket file (`Bucket`). Empty is none. A
    /// relative path is taken against the config file's directory.
    shared_bucket: []const u8 = "",
};

/// The shared token bucket: one JSON document in one file, which any
/// number of processes on the machine refill, spend and penalise under
/// an exclusive advisory lock (`flock` on Unix, `LockFileEx` on
/// Windows — `Io.File.Lock`):
///
///     { "rate_per_sec": 0.25, "burst": 40, "tokens": 12.5,
///       "updated_at": 1790000000.25, "cooldown_until": null,
///       "last_429_at": null }
///
/// `rate_per_sec` and `burst` are the bucket's settings; `tokens` is
/// what was left at `updated_at` (epoch seconds, fractional); a
/// `cooldown_until` in the future refuses every caller until then;
/// `last_429_at` is when one last hit. Keys this SDK does not know are
/// kept as they were.
///
/// The file `ratelimit` already shares with the Rust crate and
/// `bb_ratelimit.py` (`{"ts","tokens","rate","cooldown_until",
/// "throttles","last_429"}`) is read too, as the same bucket under
/// older names — `ts` is `updated_at`, `rate` is `rate_per_sec`,
/// `last_429` is `last_429_at`, a `0` time is none — and written back
/// in its own names, so the processes already on it keep reading it.
/// That dialect carries no burst: the caller supplies one (the
/// service's `ratelimit.Config.capacity`). This code never creates the file: a missing one,
/// or one that does not parse, is no bucket at all, so a bad file can
/// slow a pane but never take its API away.
pub const Bucket = struct {
    pub const State = struct {
        rate_per_sec: f64 = 0,
        burst: u32 = 0,
        tokens: f64 = 0,
        updated_at: f64 = 0,
        cooldown_until: ?f64 = null,
        last_429_at: ?f64 = null,

        /// Tokens as of `now`: refilled at `rate_per_sec` since
        /// `updated_at`, never past `burst`. A clock behind the file's
        /// refills nothing.
        pub fn refill(st: *State, now: f64) void {
            const cap: f64 = @floatFromInt(st.burst);
            if (now > st.updated_at) {
                st.tokens += (now - st.updated_at) * st.rate_per_sec;
                st.updated_at = now;
            }
            st.tokens = std.math.clamp(st.tokens, 0, cap);
        }

        pub fn coolingDown(st: State, now: f64) bool {
            return if (st.cooldown_until) |c| now < c else false;
        }
    };

    pub const Take = enum {
        /// A token was taken.
        go,
        /// The bucket is empty: skip this round.
        empty,
        /// A 429 parked every caller until `cooldown_until`.
        cooldown,
        /// No bucket: no file, or not one this reads. Go ahead.
        none,
    };

    pub const Op = enum { take, penalize, peek };

    pub const Outcome = struct { take: Take = .none, state: ?State = null };

    /// Which names the file spells the bucket in; it is written back in
    /// the same ones.
    pub const Dialect = enum {
        /// `rate_per_sec`, `burst`, `updated_at`, `last_429_at`.
        spec,
        /// `ratelimit`'s file: `rate`, `ts`, `last_429`, `throttles`.
        legacy,
    };

    /// The burst a `.legacy` file stands for when the caller names none.
    pub const default_legacy_burst: u32 = @intFromFloat(ratelimit.Config.bitbucket.capacity);

    /// The biggest file read. A bucket is a few hundred bytes.
    pub const max_bytes = 16 * 1024;

    /// Read `text` as a bucket; null when it is not one.
    pub fn parse(a: Allocator, text: []const u8, legacy_burst: u32) ?struct { obj: std.json.ObjectMap, state: State, dialect: Dialect } {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return null;
        const o = switch (v) {
            .object => |o| o,
            else => return null,
        };
        var st: State = .{};
        if (o.get("rate_per_sec") == null and o.get("rate") != null) {
            st.rate_per_sec = num(o.get("rate").?) orelse return null;
            if (!(st.rate_per_sec >= 0)) return null;
            st.burst = legacy_burst;
            st.tokens = num(o.get("tokens") orelse return null) orelse return null;
            st.updated_at = num(o.get("ts") orelse return null) orelse return null;
            const zeroNone = struct {
                fn f(x: ?std.json.Value) ?f64 {
                    const n = num(x orelse return null) orelse return null;
                    return if (n > 0) n else null;
                }
            }.f;
            st.cooldown_until = zeroNone(o.get("cooldown_until"));
            st.last_429_at = zeroNone(o.get("last_429"));
            return .{ .obj = o, .state = st, .dialect = .legacy };
        }
        st.rate_per_sec = num(o.get("rate_per_sec") orelse return null) orelse return null;
        const burst = num(o.get("burst") orelse return null) orelse return null;
        if (!(burst >= 0) or burst > 1e9 or !(st.rate_per_sec >= 0)) return null;
        st.burst = @intFromFloat(burst);
        st.tokens = num(o.get("tokens") orelse return null) orelse return null;
        st.updated_at = num(o.get("updated_at") orelse return null) orelse return null;
        st.cooldown_until = if (o.get("cooldown_until")) |c| num(c) else null;
        st.last_429_at = if (o.get("last_429_at")) |c| num(c) else null;
        return .{ .obj = o, .state = st, .dialect = .spec };
    }

    fn num(v: std.json.Value) ?f64 {
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| if (std.math.isFinite(f)) f else null,
            else => null,
        };
    }

    /// One read-modify-write under the file's exclusive lock. `now` is
    /// epoch seconds; `cooldown_secs` is a 429's pause (`penalize`).
    pub fn apply(io: Io, path: []const u8, op: Op, now: f64, cooldown_secs: f64) Outcome {
        return applyWith(io, path, op, now, cooldown_secs, default_legacy_burst);
    }

    /// `apply`, naming the burst a `.legacy` file stands for.
    pub fn applyWith(io: Io, path: []const u8, op: Op, now: f64, cooldown_secs: f64, legacy_burst: u32) Outcome {
        const file = Io.Dir.cwd().openFile(io, path, .{
            .mode = if (op == .peek) .read_only else .read_write,
            .lock = if (op == .peek) .shared else .exclusive,
        }) catch return .{};
        defer file.close(io);
        var raw: [max_bytes]u8 = undefined;
        const n = file.readPositionalAll(io, &raw, 0) catch return .{};
        if (n == raw.len) return .{};
        // The document's own keys and values live here; 64 KB is ample
        // for a document capped at 16.
        var heap: [64 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&heap);
        const a = fba.allocator();
        var got = parse(a, raw[0..n], legacy_burst) orelse return .{};
        var st = got.state;
        st.refill(now);
        var out: Outcome = .{ .state = st };
        switch (op) {
            .peek => {
                out.take = if (st.coolingDown(now)) .cooldown else if (st.tokens >= 1) .go else .empty;
                return out;
            },
            .take => {
                if (st.coolingDown(now)) {
                    out.take = .cooldown;
                } else if (st.tokens >= 1) {
                    st.tokens -= 1;
                    out.take = .go;
                } else out.take = .empty;
            },
            .penalize => {
                const until = now + @max(cooldown_secs, 0);
                st.cooldown_until = if (st.cooldown_until) |c| @max(c, until) else until;
                st.last_429_at = now;
                st.tokens = 0;
                out.take = .cooldown;
            },
        }
        out.state = st;
        const put = struct {
            fn f(obj: *std.json.ObjectMap, al: Allocator, key: []const u8, val: std.json.Value) bool {
                obj.put(al, key, val) catch return false;
                return true;
            }
        }.f;
        const ok = switch (got.dialect) {
            .spec => put(&got.obj, a, "tokens", .{ .float = st.tokens }) and
                put(&got.obj, a, "updated_at", .{ .float = st.updated_at }) and
                put(&got.obj, a, "cooldown_until", if (st.cooldown_until) |c| .{ .float = c } else .null) and
                put(&got.obj, a, "last_429_at", if (st.last_429_at) |c| .{ .float = c } else .null),
            // Its own names, its own "none" (0), and its throttle count.
            .legacy => blk: {
                const throttles: i64 = if (got.obj.get("throttles")) |x| (if (x == .integer) x.integer else 0) else 0;
                break :blk put(&got.obj, a, "ts", .{ .float = st.updated_at }) and
                    put(&got.obj, a, "tokens", .{ .float = st.tokens }) and
                    put(&got.obj, a, "cooldown_until", .{ .float = st.cooldown_until orelse 0 }) and
                    put(&got.obj, a, "last_429", .{ .float = st.last_429_at orelse 0 }) and
                    (op != .penalize or put(&got.obj, a, "throttles", .{ .integer = throttles + 1 }));
            },
        };
        if (!ok) return out;
        var wbuf: [max_bytes]u8 = undefined;
        var w: Io.Writer = .fixed(&wbuf);
        std.json.Stringify.value(std.json.Value{ .object = got.obj }, .{}, &w) catch return out;
        w.writeByte('\n') catch return out;
        file.setLength(io, 0) catch return out;
        file.writePositionalAll(io, w.buffered(), 0) catch {};
        return out;
    }
};

/// The failure text a request refused by the shared bucket goes back
/// with. A pane tells a skipped round from a failed one by it
/// (`isBucketRefusal`) — the first is quiet, the second is a toast.
pub const bucket_empty_text = "the shared rate-limit bucket is empty — skipped this round";
pub const bucket_cooldown_text = "the shared rate-limit bucket is cooling down after a 429 — skipped this round";

/// Does `msg` — a failure's text, however a pane has wrapped it — say
/// the shared bucket refused?
pub fn isBucketRefusal(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "the shared rate-limit bucket") != null;
}

/// What the chip's hover says about the shared bucket.
pub const BucketView = struct {
    configured: bool = false,
    /// The file was there and parsed at the last look.
    readable: bool = false,
    tokens: f64 = 0,
    burst: u32 = 0,
    /// Unix seconds; 0 when not cooling down.
    cooldown_until: i64 = 0,
    /// Requests this process skipped because it was empty or cooling.
    refused: u32 = 0,
};

// ─── the object ──────────────────────────────────────────────────────────

pub const Options = struct {
    /// `Jira` / `Bitbucket` — what the hover calls the API.
    label: []const u8,
    /// `jira` / `bitbucket` — the tally's file name.
    service: []const u8,
    /// `<data root>`; null keeps the tally in memory (a test, a dump).
    data_root: ?[]const u8 = null,
    /// The pace the chip measures `n/h` against when the API sends no
    /// headers: the integration's own bucket rate × 3600. 0: unknown.
    hourly_budget: u32 = 0,
    dry_run: bool = false,
    backoff: Backoff = .{},
    /// Seeds the jitter. A test passes its own for a fixed schedule.
    seed: u64 = 0x5eed_b0d6,
    /// The shared bucket file (`Bucket`), already resolved to a path;
    /// empty is none.
    shared_bucket: []const u8 = "",
};

/// What a request did, as `record` takes it.
pub const Call = struct {
    now_secs: i64,
    /// The request reached the wire (a status, or a transport failure
    /// after sending). False for a cache answer and for a dry run.
    on_wire: bool = true,
    rate_limit: RateLimit = .{},
    cache: Cache = .none,
};

/// Before a request: may it go?
pub const Gate = enum {
    /// Yes — no pause, or the pause was waited out.
    go,
    /// No: a pause longer than `wait_in_request_secs` is running. The
    /// caller answers a failure; nothing goes out.
    paused,
    /// No: the reader cancelled the wait.
    cancelled,
    /// No: the shared bucket file is empty. Skip this round; the
    /// caller answers `bucket_empty_text` and nothing goes out.
    bucket_empty,
    /// No: the shared bucket file is cooling down after somebody's
    /// 429. `bucket_cooldown_text`, nothing sent.
    bucket_cooldown,
};

/// What the chip and its hover read, taken under the lock in one go.
pub const Snapshot = struct {
    label: []const u8 = "",
    limit: ?i64 = null,
    remaining: ?i64 = null,
    reset: ?i64 = null,
    near_limit: bool = false,
    hour_calls: u32 = 0,
    hourly_budget: u32 = 0,
    hits: u32 = 0,
    misses: u32 = 0,
    today: u32 = 0,
    yesterday: u32 = 0,
    week: u32 = 0,
    dry: bool = false,
    /// Unix seconds; 0 when not paused.
    paused_until: i64 = 0,
    /// The zone the clock texts are written in.
    offset_secs: i64 = 0,
    /// The feed seam: polling (and at what interval), a live event
    /// feed, or a feed that died and left the poller in charge.
    feed: ?feed.State = null,
    bucket: BucketView = .{},

    pub fn hasHeaders(s: Snapshot) bool {
        return s.limit != null and s.remaining != null and s.limit.? > 0;
    }

    /// Percent of the budget spent: off the headers when the API sent
    /// them, else this hour's calls against the pane's own pace.
    pub fn usedPct(s: Snapshot) ?u32 {
        if (s.hasHeaders()) {
            const lim: u64 = @intCast(s.limit.?);
            const rem: u64 = @intCast(std.math.clamp(s.remaining.?, 0, s.limit.?));
            return @intCast((lim - rem) * 100 / lim);
        }
        if (s.hourly_budget > 0) return @intCast(@as(u64, s.hour_calls) * 100 / s.hourly_budget);
        return null;
    }

    pub fn tier(s: Snapshot) Tier {
        if (s.paused_until > 0) return .alarm;
        var t: Tier = if (s.usedPct()) |p| tierOf(p) else .ok;
        if ((s.near_limit or s.dry) and t == .ok) t = .warn;
        return t;
    }

    /// Hits of reads, as a percent; null before the first read.
    pub fn hitPct(s: Snapshot) ?u32 {
        const reads = s.hits + s.misses;
        if (reads == 0) return null;
        return @intCast(@as(u64, s.hits) * 100 / reads);
    }

    /// The chip's words after its glyph: `paused until 14:03:22`,
    /// `DRY`, `812/1000`, `37/h`.
    pub fn chipWords(s: Snapshot, buf: []u8) []const u8 {
        if (s.paused_until > 0) {
            var c: [8]u8 = undefined;
            return std.fmt.bufPrint(buf, "paused until {s}", .{clockText(&c, s.paused_until, s.offset_secs)}) catch "paused";
        }
        if (s.dry) return "DRY";
        var w: Io.Writer = .fixed(buf);
        if (s.hasHeaders()) {
            w.print("{d}/{d}", .{ @max(s.remaining.?, 0), s.limit.? }) catch {};
        } else w.print("{d}/h", .{s.hour_calls}) catch {};
        // What the seam is doing: `feed` while an event file is live,
        // else the poll interval in force — so a pane that has backed
        // off to two minutes says so where the reader already looks.
        if (s.feed) |f| {
            if (f.mode == .feed) {
                w.writeAll(" · feed") catch {};
            } else if (f.interval_secs > 0) {
                var ib: [16]u8 = undefined;
                w.print(" · {s}", .{secsText(&ib, f.interval_secs)}) catch {};
            }
        }
        return w.buffered();
    }

    /// The hover's body: the budget, the hour, the cache, the tally,
    /// the state, and what the chip and the keys do about it.
    pub fn helpBody(s: Snapshot, buf: []u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        if (s.hasHeaders()) {
            w.print("{s} says {d} of {d} requests left", .{ s.label, @max(s.remaining.?, 0), s.limit.? }) catch {};
            if (s.reset) |r| {
                var c: [8]u8 = undefined;
                w.print(", resetting at {s}", .{clockText(&c, r, s.offset_secs)}) catch {};
            }
            w.writeAll(". ") catch {};
        } else {
            w.print("{s} sends no rate-limit numbers, so this counts calls: ", .{s.label}) catch {};
        }
        w.print("{d} in the last hour", .{s.hour_calls}) catch {};
        if (s.hourly_budget > 0) w.print(" (the pane paces itself to {d}/h)", .{s.hourly_budget}) catch {};
        w.writeAll(". ") catch {};
        if (s.near_limit) w.writeAll("The API says it is near its limit. ") catch {};
        if (s.hitPct()) |p| {
            w.print("Cache: {d} of {d} reads answered without a body ({d}%). ", .{ s.hits, s.hits + s.misses, p }) catch {};
        } else w.writeAll("Cache: no reads yet. ") catch {};
        w.print("Calls today {d} · yesterday {d} · last 7 days {d}. ", .{ s.today, s.yesterday, s.week }) catch {};
        if (s.paused_until > 0) {
            var c: [8]u8 = undefined;
            w.print("Paused until {s} after a 429 — click (or Ctrl+X) stops waiting. ", .{clockText(&c, s.paused_until, s.offset_secs)}) catch {};
        }
        if (s.dry) w.writeAll("Dry run: nothing is sent; the pane shows what it already holds. ") catch {};
        if (s.feed) |f| writeFeed(&w, f);
        if (s.bucket.configured) writeBucket(&w, s.bucket, s.offset_secs);
        w.writeAll("Shift+N turns dry run on and off.") catch {};
        return w.buffered();
    }
};

/// `45s`, `2m`, `2m30s`, `1h`.
pub fn secsText(buf: []u8, secs: u32) []const u8 {
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "";
    if (secs < 3600) {
        if (secs % 60 == 0) return std.fmt.bufPrint(buf, "{d}m", .{secs / 60}) catch "";
        return std.fmt.bufPrint(buf, "{d}m{d}s", .{ secs / 60, secs % 60 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}h", .{secs / 3600}) catch "";
}

fn writeFeed(w: *Io.Writer, f: feed.State) void {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    var c: [16]u8 = undefined;
    switch (f.mode) {
        .feed => {
            w.print("Live event feed ({d} event{s} so far): only the items it names are fetched, and the listing is still swept every {s}. ", .{ f.feed_events, if (f.feed_events == 1) "" else "s", secsText(&a, f.interval_secs) }) catch {};
            return;
        },
        .degraded => if (f.feed_missing) {
            w.writeAll("The event feed file is missing, so the pane polls instead. ") catch {};
        } else {
            w.print("The event feed has been quiet for {s} (no event, no heartbeat), so the pane polls instead. ", .{secsText(&a, @intCast(@min(@max(f.feed_quiet_secs, 0), std.math.maxInt(u32))))}) catch {};
        },
        .poll => {},
    }
    if (f.interval_secs == 0) return;
    if (f.max_secs > f.base_secs) {
        w.print("Polls every {s} (from {s}, doubling to {s} while nothing changes", .{ secsText(&a, f.interval_secs), secsText(&b, f.base_secs), secsText(&c, f.max_secs) }) catch {};
        if (f.quiet_polls > 0) w.print("; {d} quiet in a row", .{f.quiet_polls}) catch {};
        w.writeAll("); a change, a key or a click brings it back. ") catch {};
    } else w.print("Polls every {s}. ", .{secsText(&a, f.interval_secs)}) catch {};
}

fn writeBucket(w: *Io.Writer, v: BucketView, offset_secs: i64) void {
    if (!v.readable) {
        w.writeAll("Shared bucket: the file is missing or unreadable, so it is not used. ") catch {};
        return;
    }
    w.print("Shared bucket: {d:.1} of {d} tokens", .{ v.tokens, v.burst }) catch {};
    if (v.cooldown_until > 0) {
        var c: [8]u8 = undefined;
        w.print(", cooling down until {s} after a 429", .{clockText(&c, v.cooldown_until, offset_secs)}) catch {};
    }
    if (v.refused > 0) w.print("; {d} request{s} skipped waiting on it", .{ v.refused, if (v.refused == 1) "" else "s" }) catch {};
    w.writeAll(". ") catch {};
}

pub const Budget = struct {
    io: Io = undefined,
    configured: bool = false,
    lock: Io.Mutex = .init,
    label: []const u8 = "",
    backoff: Backoff = .{},
    hourly_budget: u32 = 0,
    /// `<data root>/budget/<service>.tally`; empty keeps it in memory.
    tally_path_buf: [1024]u8 = undefined,
    tally_path_len: usize = 0,
    prng: std.Random.DefaultPrng = .init(0x5eed_b0d6),

    dry_run: std.atomic.Value(bool) = .init(false),
    cancel_flag: std.atomic.Value(bool) = .init(false),
    paused_until_ms: std.atomic.Value(i64) = .init(0),

    // Under `lock`:
    last: RateLimit = .{},
    hits: u32 = 0,
    misses: u32 = 0,
    hour: Hour = .{},
    tally: Tally = .{},
    /// Requests that reached the wire, this process — what a test counts.
    wire_calls: u32 = 0,
    /// The clock `waitOut` reads, in ms. Null is the real one; a test
    /// sets its own.
    clock: ?*const fn () i64 = null,
    /// The shared bucket file; empty is none.
    bucket_path_buf: [1024]u8 = undefined,
    bucket_path_len: usize = 0,
    /// What the file said at the last take, penalty or peek, for the
    /// hover (under `lock`).
    bucket_state: ?Bucket.State = null,
    bucket_seen_ms: i64 = 0,
    bucket_refused: u32 = 0,
    /// The burst a bucket file in `ratelimit`'s dialect stands for:
    /// this service's capacity.
    bucket_legacy_burst: u32 = Bucket.default_legacy_burst,
    /// The feed seam's state, as the pane last set it (under `lock`).
    feed_state: ?feed.State = null,

    pub fn configure(b: *Budget, io: Io, opts: Options) void {
        b.io = io;
        b.configured = true;
        b.label = opts.label;
        b.backoff = opts.backoff;
        b.hourly_budget = opts.hourly_budget;
        b.prng = .init(opts.seed);
        b.dry_run.store(opts.dry_run, .release);
        b.tally_path_len = 0;
        b.bucket_path_len = 0;
        b.bucket_legacy_burst = @intFromFloat(ratelimit.configFor(opts.service).capacity);
        if (opts.shared_bucket.len > 0 and opts.shared_bucket.len <= b.bucket_path_buf.len) {
            @memcpy(b.bucket_path_buf[0..opts.shared_bucket.len], opts.shared_bucket);
            b.bucket_path_len = opts.shared_bucket.len;
        }
        if (opts.data_root) |root| {
            if (std.fmt.bufPrint(&b.tally_path_buf, "{s}/budget/{s}.tally", .{ root, opts.service })) |p| {
                b.tally_path_len = p.len;
            } else |_| {}
        }
        b.reloadTally();
    }

    fn tallyPath(b: *const Budget) ?[]const u8 {
        return if (b.tally_path_len == 0) null else b.tally_path_buf[0..b.tally_path_len];
    }

    fn nowMs(b: *Budget) i64 {
        if (b.clock) |f| return f();
        return Io.Timestamp.now(b.io, .real).toMilliseconds();
    }

    /// Re-read the tally another process may have added to.
    pub fn reloadTally(b: *Budget) void {
        const p = b.tallyPath() orelse return;
        var buf: [1024]u8 = undefined;
        const text = Io.Dir.cwd().readFile(b.io, p, &buf) catch return;
        const t = Tally.parse(text);
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.tally = t;
    }

    // ── what a request did ──

    pub fn record(b: *Budget, c: Call) void {
        if (!b.configured) return;
        b.lock.lockUncancelable(b.io);
        if (c.on_wire) {
            b.wire_calls += 1;
            b.hour.bump(c.now_secs);
        }
        if (c.rate_limit.limit) |v| b.last.limit = v;
        if (c.rate_limit.remaining) |v| b.last.remaining = v;
        if (c.rate_limit.reset) |v| b.last.reset = v;
        if (c.rate_limit.near_limit) |v| b.last.near_limit = v;
        switch (c.cache) {
            .hit => b.hits += 1,
            .miss => b.misses += 1,
            .none => {},
        }
        b.lock.unlock(b.io);
        if (c.on_wire) b.bumpTally(c.now_secs);
    }

    /// A read a local cache answered, recorded where no request was
    /// made at all (the Jira pane's pull-request store).
    pub fn noteHit(b: *Budget) void {
        b.record(.{ .now_secs = 0, .on_wire = false, .cache = .hit });
    }

    /// Today's count, in the shared file when there is one: read it,
    /// add one, write it back, all under one exclusive lock — so every
    /// process on the service adds to the same number.
    fn bumpTally(b: *Budget, now_secs: i64) void {
        const day = dayOf(now_secs, localOffset(now_secs));
        const p = b.tallyPath() orelse {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            b.tally.bump(day);
            return;
        };
        var t: Tally = .{};
        blk: {
            if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(b.io, dir) catch {};
            const file = Io.Dir.cwd().createFile(b.io, p, .{ .read = true, .truncate = false, .lock = .exclusive }) catch {
                t = b.tally;
                t.bump(day);
                break :blk;
            };
            defer file.close(b.io);
            var buf: [1024]u8 = undefined;
            const n = file.readPositionalAll(b.io, &buf, 0) catch 0;
            t = Tally.parse(buf[0..n]);
            t.bump(day);
            var out: [1024]u8 = undefined;
            const text = t.render(&out);
            file.setLength(b.io, 0) catch {};
            file.writePositionalAll(b.io, text, 0) catch {};
        }
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.tally = t;
    }

    // ── the pause ──

    /// A 429 on attempt `attempt`: pause for what the server asked (or
    /// the backoff), and hand back how long, in seconds.
    pub fn throttled(b: *Budget, attempt: u32, retry_after: ?u32) u32 {
        b.lock.lockUncancelable(b.io);
        const secs = b.backoff.delaySecs(attempt, retry_after, b.prng.random());
        b.lock.unlock(b.io);
        const now_ms = b.nowMs();
        const until = now_ms + @as(i64, secs) * 1000;
        const prev = b.paused_until_ms.load(.acquire);
        if (until > prev) b.paused_until_ms.store(until, .release);
        // Every other caller on the machine honours it too.
        if (b.bucketPath()) |p| b.noteBucket(Bucket.applyWith(b.io, p, .penalize, msSecs(now_ms), @floatFromInt(secs), b.bucket_legacy_burst), now_ms);
        return secs;
    }

    fn msSecs(ms: i64) f64 {
        return @as(f64, @floatFromInt(ms)) / 1000.0;
    }

    pub fn bucketPath(b: *const Budget) ?[]const u8 {
        return if (b.bucket_path_len == 0) null else b.bucket_path_buf[0..b.bucket_path_len];
    }

    fn noteBucket(b: *Budget, out: Bucket.Outcome, now_ms: i64) void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.bucket_state = out.state;
        b.bucket_seen_ms = now_ms;
        if (out.take == .empty or out.take == .cooldown) {
            if (out.state != null) b.bucket_refused +|= 1;
        }
    }

    /// One token from the shared bucket file, when there is one. The
    /// file answers `.none` when it is missing or unreadable, and that
    /// is a yes.
    fn takeShared(b: *Budget) Gate {
        const p = b.bucketPath() orelse return .go;
        const now_ms = b.nowMs();
        const out = Bucket.applyWith(b.io, p, .take, msSecs(now_ms), 0, b.bucket_legacy_burst);
        b.noteBucket(out, now_ms);
        return switch (out.take) {
            .go, .none => .go,
            .empty => .bucket_empty,
            .cooldown => .bucket_cooldown,
        };
    }

    /// The failure text for a gate that refused.
    pub fn refusalText(g: Gate) []const u8 {
        return switch (g) {
            .bucket_empty => bucket_empty_text,
            .bucket_cooldown => bucket_cooldown_text,
            .paused => "paused after a 429",
            .cancelled => "stopped waiting out the rate limit",
            .go => "",
        };
    }

    /// Requests this process skipped because the shared bucket was
    /// empty or cooling down. A worker reads it before and after a job
    /// to tell a skipped round from a failed one.
    pub fn refusedCount(b: *Budget) u32 {
        if (!b.configured) return 0;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        return b.bucket_refused;
    }

    /// Set by the pane from its feed seam, once per tick.
    pub fn setFeed(b: *Budget, st: ?feed.State) void {
        if (!b.configured) return;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.feed_state = st;
    }

    /// What the shared bucket last said, re-read when the last look is
    /// older than two seconds — the paint loop asks every frame.
    fn bucketView(b: *Budget) BucketView {
        const p = b.bucketPath() orelse return .{};
        const now_ms = b.nowMs();
        b.lock.lockUncancelable(b.io);
        const seen = b.bucket_seen_ms;
        b.lock.unlock(b.io);
        if (now_ms - seen >= 2000) {
            const out = Bucket.applyWith(b.io, p, .peek, msSecs(now_ms), 0, b.bucket_legacy_burst);
            b.lock.lockUncancelable(b.io);
            b.bucket_state = out.state;
            b.bucket_seen_ms = now_ms;
            b.lock.unlock(b.io);
        }
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        var v: BucketView = .{ .configured = true, .refused = b.bucket_refused };
        if (b.bucket_state) |st| {
            v.readable = true;
            v.tokens = st.tokens;
            v.burst = st.burst;
            if (st.coolingDown(msSecs(now_ms))) v.cooldown_until = @intFromFloat(@ceil(st.cooldown_until.?));
        }
        return v;
    }

    /// Unix ms the pause runs to, or 0.
    pub fn pausedUntilMs(b: *Budget) i64 {
        const until = b.paused_until_ms.load(.acquire);
        if (until == 0) return 0;
        if (until <= b.nowMs()) return 0;
        return until;
    }

    /// Before a request goes out. A short pause is waited here in
    /// tenths of a second, so a cancel lands at once; a long one is
    /// refused outright so the pane's worker is never parked for an
    /// hour behind one tab's 429.
    pub fn waitOut(b: *Budget) Gate {
        if (!b.configured) return .go;
        const g = b.waitPause();
        if (g != .go) return g;
        return b.takeShared();
    }

    fn waitPause(b: *Budget) Gate {
        var until = b.pausedUntilMs();
        if (until == 0) {
            b.cancel_flag.store(false, .release);
            return .go;
        }
        if (until - b.nowMs() > @as(i64, b.backoff.wait_in_request_secs) * 1000) return .paused;
        while (until > 0) {
            if (b.cancel_flag.swap(false, .acq_rel)) return .cancelled;
            const left = until - b.nowMs();
            if (left <= 0) break;
            b.io.sleep(.fromMilliseconds(@min(left, 100)), .awake) catch return .cancelled;
            until = b.pausedUntilMs();
        }
        // A cancel clears the pause as well as raising the flag, so the
        // loop can end on either; the flag says which it was.
        if (b.cancel_flag.swap(false, .acq_rel)) return .cancelled;
        return .go;
    }

    /// Stop waiting: the pause is dropped and a request waiting it out
    /// returns `.cancelled`. True when there was a pause to cancel.
    pub fn cancelWait(b: *Budget) bool {
        if (b.pausedUntilMs() == 0) return false;
        // The flag first: a waiter that sees the pause gone must also
        // see why.
        b.cancel_flag.store(true, .release);
        b.paused_until_ms.store(0, .release);
        return true;
    }

    // ── dry run ──

    pub fn isDry(b: *const Budget) bool {
        return b.dry_run.load(.acquire);
    }

    /// Flip it; the new value.
    pub fn toggleDry(b: *Budget) bool {
        const now = !b.dry_run.load(.acquire);
        b.dry_run.store(now, .release);
        return now;
    }

    // ── what the chip reads ──

    pub fn snapshot(b: *Budget, now_secs: i64) Snapshot {
        if (!b.configured) return .{};
        const until = b.pausedUntilMs();
        const offset = localOffset(now_secs);
        const bucket = b.bucketView();
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        const c = b.tally.counts(dayOf(now_secs, offset));
        return .{
            .label = b.label,
            .limit = b.last.limit,
            .remaining = b.last.remaining,
            .reset = b.last.reset,
            .near_limit = b.last.near_limit orelse false,
            .hour_calls = b.hour.total(now_secs),
            .hourly_budget = b.hourly_budget,
            .hits = b.hits,
            .misses = b.misses,
            .today = c.today,
            .yesterday = c.yesterday,
            .week = c.week,
            .dry = b.isDry(),
            .paused_until = if (until > 0) @divFloor(until + 999, 1000) else 0,
            .offset_secs = offset,
            .feed = b.feed_state,
            .bucket = bucket,
        };
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const tst = std.testing;

test "the backoff honours Retry-After, else doubles from the base with jitter, and never passes the cap" {
    const b: Backoff = .{ .base_secs = 2, .cap_secs = 30, .jitter_pct = 0, .max_attempts = 3 };
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    try tst.expectEqual(@as(u32, 7), b.delaySecs(1, 7, r));
    try tst.expectEqual(@as(u32, 3600), b.delaySecs(1, 999_999, r));
    try tst.expectEqual(@as(u32, 2), b.delaySecs(1, null, r));
    try tst.expectEqual(@as(u32, 4), b.delaySecs(2, null, r));
    try tst.expectEqual(@as(u32, 8), b.delaySecs(3, null, r));
    try tst.expectEqual(@as(u32, 30), b.delaySecs(9, null, r));
    try tst.expectEqual(@as(u32, 30), b.delaySecs(200, null, r));

    // Jittered: inside ±20 %, never past the cap, and the same seed
    // gives the same schedule — which is what makes it testable.
    const j: Backoff = .{ .base_secs = 10, .cap_secs = 45, .jitter_pct = 20 };
    var p1 = std.Random.DefaultPrng.init(42);
    var p2 = std.Random.DefaultPrng.init(42);
    var attempt: u32 = 1;
    while (attempt <= 6) : (attempt += 1) {
        const a = j.delaySecs(attempt, null, p1.random());
        try tst.expectEqual(a, j.delaySecs(attempt, null, p2.random()));
        const exp: u32 = @min(@as(u32, 10) << @intCast(attempt - 1), 45);
        try tst.expect(a >= exp - exp / 5 and a <= @min(exp + exp / 5, 45));
    }

    // Only a read is retried, and only within its attempts.
    try tst.expect(b.retries(1, true));
    try tst.expect(b.retries(2, true));
    try tst.expect(!b.retries(3, true));
    try tst.expect(!b.retries(1, false));
}

test "the last hour counts sixty minutes of calls and forgets the sixty-first" {
    var h: Hour = .{};
    const t0: i64 = 1_790_000_000;
    h.bump(t0);
    h.bump(t0 + 1);
    h.bump(t0 + 30 * 60);
    try tst.expectEqual(@as(u32, 3), h.total(t0 + 30 * 60));
    try tst.expectEqual(@as(u32, 1), h.total(t0 + 61 * 60));
    try tst.expectEqual(@as(u32, 0), h.total(t0 + 91 * 60));
    // The slot a minute an hour later lands in starts over.
    h.bump(t0 + 60 * 60);
    try tst.expectEqual(@as(u32, 2), h.total(t0 + 60 * 60));
}

test "the tally rolls over at local midnight, keeps a week, and reads back what it wrote" {
    // 23:59:59 and 00:00:01 in a zone seven hours west of UTC.
    const offset: i64 = -7 * 3600;
    const midnight_local: i64 = 1_790_319_600; // 2026-09-25T07:00:00Z
    const before = midnight_local - 1;
    const after = midnight_local + 1;
    try tst.expectEqual(dayOf(before, offset) + 1, dayOf(after, offset));
    // In UTC the same two instants are the same day.
    try tst.expectEqual(dayOf(before, 0), dayOf(after, 0));

    var tally: Tally = .{};
    tally.bump(dayOf(before, offset));
    tally.bump(dayOf(before, offset));
    tally.bump(dayOf(after, offset));
    const today = dayOf(after, offset);
    try tst.expectEqual(Tally.Counts{ .today = 1, .yesterday = 2, .week = 3 }, tally.counts(today));

    var d: [10]u8 = undefined;
    try tst.expectEqualStrings("2026-09-25", isoDate(&d, today));
    var buf: [512]u8 = undefined;
    const text = tally.render(&buf);
    try tst.expectEqualStrings("2026-09-25 1\n2026-09-24 2\n", text);
    try tst.expectEqual(tally.counts(today), Tally.parse(text).counts(today));

    // Eight days kept; the week is the seven ending today.
    var long: Tally = .{};
    var day: i64 = today - 9;
    while (day <= today) : (day += 1) long.bump(day);
    try tst.expectEqual(@as(u32, 7), long.counts(today).week);
    try tst.expectEqual(@as(u32, 0), long.on(today - 8));
    try tst.expectEqual(@as(u32, 1), long.on(today - 7));
    // A torn line costs that line.
    try tst.expectEqual(@as(u32, 5), Tally.parse("2026-09-25 5\ngarbage\n2026-09-2").on(today));
}

test "the tally file is shared: two budgets on one data root add to one count" {
    var tmp = tst.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [1024]u8 = undefined;
    const root_len = try tmp.dir.realPath(tst.io, &root_buf);
    const root = root_buf[0..root_len];
    var a: Budget = .{};
    a.configure(tst.io, .{ .label = "Jira", .service = "jira", .data_root = root });
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Jira", .service = "jira", .data_root = root });
    const now = Io.Timestamp.now(tst.io, .real).toSeconds();
    a.record(.{ .now_secs = now });
    b.record(.{ .now_secs = now });
    a.record(.{ .now_secs = now });
    try tst.expectEqual(@as(u32, 3), a.snapshot(now).today);
    // A cache answer and a dry run are not calls.
    a.record(.{ .now_secs = now, .on_wire = false, .cache = .hit });
    try tst.expectEqual(@as(u32, 3), a.snapshot(now).today);
    var fresh: Budget = .{};
    fresh.configure(tst.io, .{ .label = "Jira", .service = "jira", .data_root = root });
    try tst.expectEqual(@as(u32, 3), fresh.snapshot(now).today);
}

test "hits and misses make the ratio; a write is neither, and no read yet is no ratio" {
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    try tst.expectEqual(@as(?u32, null), b.snapshot(0).hitPct());
    b.record(.{ .now_secs = 0, .cache = .miss });
    b.record(.{ .now_secs = 0, .cache = .hit });
    b.record(.{ .now_secs = 0, .cache = .hit });
    b.record(.{ .now_secs = 0, .cache = .miss });
    b.record(.{ .now_secs = 0 }); // a write
    b.noteHit();
    const s = b.snapshot(0);
    try tst.expectEqual(@as(u32, 3), s.hits);
    try tst.expectEqual(@as(u32, 2), s.misses);
    try tst.expectEqual(@as(?u32, 60), s.hitPct());
    var buf: [512]u8 = undefined;
    try tst.expect(std.mem.indexOf(u8, s.helpBody(&buf), "3 of 5 reads answered without a body (60%)") != null);
}

test "the chip reads the headers when the API sends them, the hour when it does not, and wears the usage meter's tiers" {
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Bitbucket", .service = "bitbucket", .hourly_budget = 100 });
    var buf: [64]u8 = undefined;
    const now: i64 = 1_790_000_000;
    var s = b.snapshot(now);
    try tst.expectEqualStrings("0/h", s.chipWords(&buf));
    try tst.expectEqual(Tier.ok, s.tier());
    for (0..61) |_| b.record(.{ .now_secs = now, .cache = .miss });
    s = b.snapshot(now);
    try tst.expectEqualStrings("61/h", s.chipWords(&buf));
    try tst.expectEqual(Tier.warn, s.tier());

    b.record(.{ .now_secs = now, .rate_limit = .{ .limit = 1000, .remaining = 812 } });
    s = b.snapshot(now);
    try tst.expectEqualStrings("812/1000", s.chipWords(&buf));
    try tst.expectEqual(Tier.ok, s.tier());
    b.record(.{ .now_secs = now, .rate_limit = .{ .remaining = 100 } });
    try tst.expectEqual(Tier.alarm, b.snapshot(now).tier());
    b.record(.{ .now_secs = now, .rate_limit = .{ .remaining = 990, .near_limit = true } });
    try tst.expectEqual(Tier.warn, b.snapshot(now).tier());
    var hb: [512]u8 = undefined;
    try tst.expect(std.mem.indexOf(u8, b.snapshot(now).helpBody(&hb), "Bitbucket says 990 of 1000 requests left") != null);
}

test "dry run switches on and off, and the chip says DRY while it is on" {
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Jira", .service = "jira", .dry_run = true });
    try tst.expect(b.isDry());
    var buf: [64]u8 = undefined;
    try tst.expectEqualStrings("DRY", b.snapshot(0).chipWords(&buf));
    try tst.expectEqual(Tier.warn, b.snapshot(0).tier());
    try tst.expect(!b.toggleDry());
    try tst.expect(!b.isDry());
    try tst.expectEqualStrings("0/h", b.snapshot(0).chipWords(&buf));
    try tst.expect(b.toggleDry());
    try tst.expect(b.isDry());
}

var test_clock_ms: i64 = 0;
fn testClock() i64 {
    return test_clock_ms;
}

test "a 429 pauses: the chip says until when, a long pause is refused rather than waited, and a cancel ends the wait" {
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Jira", .service = "jira", .backoff = .{ .wait_in_request_secs = 60 } });
    b.clock = &testClock;
    test_clock_ms = 1_790_000_000_000;
    try tst.expectEqual(Gate.go, b.waitOut());
    try tst.expectEqual(@as(u32, 300), b.throttled(1, 300));
    const s = b.snapshot(1_790_000_000);
    try tst.expectEqual(@as(i64, 1_790_000_300), s.paused_until);
    try tst.expectEqual(Tier.alarm, s.tier());
    var buf: [64]u8 = undefined;
    var c: [8]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "paused until {s}", .{clockText(&c, 1_790_000_300, s.offset_secs)});
    var got: [64]u8 = undefined;
    try tst.expectEqualStrings(want, s.chipWords(&got));
    // Longer than a request may wait: refused, nothing sent.
    try tst.expectEqual(Gate.paused, b.waitOut());
    // Past it, the way is clear again.
    test_clock_ms += 301_000;
    try tst.expectEqual(Gate.go, b.waitOut());
    try tst.expectEqual(@as(i64, 0), b.snapshot(1_790_000_301).paused_until);

    // A short pause is waited — on another thread here, the way the
    // pane's worker waits — and a cancel lands inside the wait.
    _ = b.throttled(1, 30);
    const Waiter = struct {
        fn run(bb: *Budget, out: *Gate) void {
            out.* = bb.waitOut();
        }
    };
    var got_gate: Gate = .go;
    const th = try std.Thread.spawn(.{}, Waiter.run, .{ &b, &got_gate });
    tst.io.sleep(.fromMilliseconds(250), .awake) catch {};
    try tst.expect(b.cancelWait());
    th.join();
    try tst.expectEqual(Gate.cancelled, got_gate);
    // Nothing left to cancel, and the next request goes.
    try tst.expect(!b.cancelWait());
    try tst.expectEqual(Gate.go, b.waitOut());
}

test "a short pause is waited out on the real clock, then the request may go" {
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    _ = b.throttled(1, 0);
    b.paused_until_ms.store(Io.Timestamp.now(tst.io, .real).toMilliseconds() + 250, .release);
    const t0 = Io.Timestamp.now(tst.io, .real).toMilliseconds();
    try tst.expectEqual(Gate.go, b.waitOut());
    try tst.expect(Io.Timestamp.now(tst.io, .real).toMilliseconds() - t0 >= 200);
}

// ─── the shared bucket file ──────────────────────────────────────────────

fn bucketFile(tmp: *std.testing.TmpDir, buf: []u8, name: []const u8, text: []const u8) ![]const u8 {
    try tmp.dir.writeFile(tst.io, .{ .sub_path = name, .data = text });
    var root: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(tst.io, &root);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root[0..n], name });
}

test "the bucket file round-trips under its lock: refilled, one token per take, refused when empty, unknown keys kept" {
    var tmp = tst.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [1100]u8 = undefined;
    const p = try bucketFile(&tmp, &pb, "bucket.json",
        \\{"rate_per_sec":0.5,"burst":3,"tokens":1,"updated_at":1000,"cooldown_until":null,"last_429_at":null,"owner":"fleet"}
    );
    // Four seconds on at 0.5/s: 1 + 2 = 3, the burst.
    var out = Bucket.apply(tst.io, p, .take, 1004, 0);
    try tst.expectEqual(Bucket.Take.go, out.take);
    try tst.expectEqual(@as(f64, 2), out.state.?.tokens);
    // A ten-second gap cannot overfill: still capped at the burst.
    out = Bucket.apply(tst.io, p, .take, 1100, 0);
    try tst.expectEqual(@as(f64, 2), out.state.?.tokens);
    _ = Bucket.apply(tst.io, p, .take, 1100, 0);
    _ = Bucket.apply(tst.io, p, .take, 1100, 0);
    out = Bucket.apply(tst.io, p, .take, 1100, 0);
    try tst.expectEqual(Bucket.Take.empty, out.take);
    // Peeking takes nothing.
    try tst.expectEqual(Bucket.Take.empty, Bucket.apply(tst.io, p, .peek, 1100, 0).take);
    try tst.expectEqual(Bucket.Take.go, Bucket.apply(tst.io, p, .peek, 1102, 0).take);
    // What is on disk: the numbers this wrote, and the key it did not know.
    var rb: [1024]u8 = undefined;
    const text = try tmp.dir.readFile(tst.io, "bucket.json", &rb);
    try tst.expect(std.mem.indexOf(u8, text, "\"owner\":\"fleet\"") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"updated_at\":1100") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"tokens\":0") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"cooldown_until\":null") != null);
}

test "a missing or unreadable bucket file is no bucket: the request goes, and nothing is created" {
    var tmp = tst.tmpDir(.{});
    defer tmp.cleanup();
    var root: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(tst.io, &root);
    var pb: [1100]u8 = undefined;
    const missing = try std.fmt.bufPrint(&pb, "{s}/nope.json", .{root[0..n]});
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Jira", .service = "jira", .shared_bucket = missing });
    try tst.expectEqual(Gate.go, b.waitOut());
    try tst.expectError(error.FileNotFound, tmp.dir.statFile(tst.io, "nope.json", .{}));
    var hb: [1024]u8 = undefined;
    try tst.expect(std.mem.indexOf(u8, b.snapshot(0).helpBody(&hb), "missing or unreadable") != null);
    // Not JSON, the wrong shape, a key missing: all no bucket.
    for ([_][]const u8{ "not json", "[1]", "{\"rate_per_sec\":1,\"burst\":1,\"tokens\":0}", "{\"rate_per_sec\":-1,\"burst\":1,\"tokens\":0,\"updated_at\":0}" }) |bad| {
        var qb: [1100]u8 = undefined;
        const p = try bucketFile(&tmp, &qb, "bad.json", bad);
        var c: Budget = .{};
        c.configure(tst.io, .{ .label = "Jira", .service = "jira", .shared_bucket = p });
        try tst.expectEqual(Gate.go, c.waitOut());
        try tst.expectEqual(Bucket.Take.none, Bucket.apply(tst.io, p, .take, 0, 0).take);
    }
}

test "an empty shared bucket refuses the request, and says so; a 429 is a cooldown a second reader honours" {
    var tmp = tst.tmpDir(.{});
    defer tmp.cleanup();
    const now_s = Io.Timestamp.now(tst.io, .real).toSeconds();
    var doc: [256]u8 = undefined;
    var pb: [1100]u8 = undefined;
    const p = try bucketFile(&tmp, &pb, "bucket.json", try std.fmt.bufPrint(&doc, "{{\"rate_per_sec\":0,\"burst\":2,\"tokens\":2,\"updated_at\":{d},\"cooldown_until\":null,\"last_429_at\":null}}", .{now_s}));
    var a: Budget = .{};
    a.configure(tst.io, .{ .label = "Bitbucket", .service = "bitbucket", .shared_bucket = p, .backoff = .{ .wait_in_request_secs = 0 } });
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Bitbucket", .service = "bitbucket", .shared_bucket = p, .backoff = .{ .wait_in_request_secs = 0 } });
    try tst.expectEqual(Gate.go, a.waitOut());
    try tst.expectEqual(Gate.go, b.waitOut());
    // Two tokens, two takers: the third request is refused, not sent.
    try tst.expectEqual(Gate.bucket_empty, a.waitOut());
    try tst.expectEqualStrings(bucket_empty_text, Budget.refusalText(.bucket_empty));
    try tst.expect(isBucketRefusal(Budget.refusalText(.bucket_empty)));
    try tst.expect(!isBucketRefusal("HTTP 500"));
    var hb: [1024]u8 = undefined;
    const help = a.snapshot(now_s).helpBody(&hb);
    try tst.expect(std.mem.indexOf(u8, help, "Shared bucket: 0.0 of 2 tokens") != null);
    try tst.expect(std.mem.indexOf(u8, help, "1 request skipped") != null);

    // Refill it, then `a` meets a 429: every caller on the file cools
    // down, `b` included, and `b`'s own pause is none of it.
    _ = try bucketFile(&tmp, &pb, "bucket.json", try std.fmt.bufPrint(&doc, "{{\"rate_per_sec\":0,\"burst\":2,\"tokens\":2,\"updated_at\":{d},\"cooldown_until\":null,\"last_429_at\":null}}", .{now_s}));
    _ = a.throttled(1, 120);
    try tst.expectEqual(@as(i64, 0), b.pausedUntilMs());
    try tst.expectEqual(Gate.bucket_cooldown, b.waitOut());
    const snap = b.snapshot(now_s);
    try tst.expect(snap.bucket.cooldown_until >= now_s + 119);
    try tst.expect(std.mem.indexOf(u8, snap.helpBody(&hb), "cooling down until") != null);
    var rb: [1024]u8 = undefined;
    const text = try tmp.dir.readFile(tst.io, "bucket.json", &rb);
    try tst.expect(std.mem.indexOf(u8, text, "\"last_429_at\":null") == null);
}

test "two processes drawing on one bucket file never take more than its burst between them" {
    if (builtin.os.tag == .windows or !builtin.link_libc) return error.SkipZigTest;
    var tmp = tst.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [1100]u8 = undefined;
    // No refill: whatever the two take together, it is at most 20.
    const p = try bucketFile(&tmp, &pb, "bucket.json",
        \\{"rate_per_sec":0,"burst":20,"tokens":20,"updated_at":1000,"cooldown_until":null,"last_429_at":null}
    );
    const tries = 40;
    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        // The child: its own single-threaded Io, the same file, the same
        // race — and an exit status that is how many it got.
        var th: Io.Threaded = .init_single_threaded;
        const io = th.io();
        var got: u8 = 0;
        for (0..tries) |_| {
            if (Bucket.apply(io, p, .take, 1000, 0).take == .go) got += 1;
        }
        std.c._exit(got);
    }
    var mine: u32 = 0;
    for (0..tries) |_| {
        if (Bucket.apply(tst.io, p, .take, 1000, 0).take == .go) mine += 1;
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const theirs: u32 = @intCast((@as(u32, @bitCast(status)) >> 8) & 0xff);
    try tst.expectEqual(@as(u32, 20), mine + theirs);
    try tst.expectEqual(Bucket.Take.empty, Bucket.apply(tst.io, p, .peek, 1000, 0).take);
}

test "the chip says feed while an event file is live and the interval while polling; the hover says why" {
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    var buf: [64]u8 = undefined;
    var hb: [1024]u8 = undefined;
    try tst.expectEqualStrings("0/h", b.snapshot(0).chipWords(&buf));
    b.setFeed(.{ .mode = .poll, .interval_secs = 20, .base_secs = 5, .max_secs = 120, .quiet_polls = 2 });
    try tst.expectEqualStrings("0/h · 20s", b.snapshot(0).chipWords(&buf));
    try tst.expect(std.mem.indexOf(u8, b.snapshot(0).helpBody(&hb), "Polls every 20s (from 5s, doubling to 2m while nothing changes; 2 quiet in a row)") != null);
    b.setFeed(.{ .mode = .feed, .interval_secs = 600, .base_secs = 5, .max_secs = 120, .configured = true, .feed_events = 3 });
    try tst.expectEqualStrings("0/h · feed", b.snapshot(0).chipWords(&buf));
    try tst.expect(std.mem.indexOf(u8, b.snapshot(0).helpBody(&hb), "Live event feed (3 events so far)") != null);
    b.setFeed(.{ .mode = .degraded, .interval_secs = 5, .base_secs = 5, .max_secs = 120, .configured = true, .feed_quiet_secs = 420 });
    try tst.expectEqualStrings("0/h · 5s", b.snapshot(0).chipWords(&buf));
    try tst.expect(std.mem.indexOf(u8, b.snapshot(0).helpBody(&hb), "quiet for 7m") != null);
    b.setFeed(.{ .mode = .degraded, .interval_secs = 5, .base_secs = 5, .max_secs = 120, .configured = true, .feed_missing = true });
    try tst.expect(std.mem.indexOf(u8, b.snapshot(0).helpBody(&hb), "feed file is missing") != null);
    // Polling off: the chip is what it always was.
    b.setFeed(.{ .mode = .poll });
    try tst.expectEqualStrings("0/h", b.snapshot(0).chipWords(&buf));
    // A pause and a dry run keep their own words.
    b.dry_run.store(true, .release);
    b.setFeed(.{ .mode = .poll, .interval_secs = 20, .base_secs = 5, .max_secs = 120 });
    try tst.expectEqualStrings("DRY", b.snapshot(0).chipWords(&buf));
    var tb: [8]u8 = undefined;
    try tst.expectEqualStrings("2m30s", secsText(&tb, 150));
    try tst.expectEqualStrings("1h", secsText(&tb, 3600));
}

test "the bucket file is read in either dialect and written back in the one it came in" {
    var tmp = tst.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [1100]u8 = undefined;
    var rb: [1024]u8 = undefined;
    // The spec's names.
    const sp = try bucketFile(&tmp, &pb, "spec.json",
        \\{"rate_per_sec":0,"burst":5,"tokens":2,"updated_at":1000,"cooldown_until":null,"last_429_at":null}
    );
    var out = Bucket.applyWith(tst.io, sp, .take, 1000, 0, 60);
    try tst.expectEqual(Bucket.Take.go, out.take);
    try tst.expectEqual(@as(u32, 5), out.state.?.burst);
    var text = try tmp.dir.readFile(tst.io, "spec.json", &rb);
    try tst.expect(std.mem.indexOf(u8, text, "\"updated_at\":1000") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"ts\"") == null);

    // `ratelimit`'s names: the same bucket, its burst the caller's, a
    // 0 time none, and every key written back as it was spelled.
    var pb2: [1100]u8 = undefined;
    const lg = try bucketFile(&tmp, &pb2, "legacy.json",
        \\{"ts":1000,"tokens":100,"rate":0.5,"cooldown_until":0,"throttles":2,"last_429":0}
    );
    out = Bucket.applyWith(tst.io, lg, .take, 1004, 0, 60);
    try tst.expectEqual(Bucket.Take.go, out.take);
    // 100 is clamped to the burst of 60, then one taken.
    try tst.expectEqual(@as(f64, 59), out.state.?.tokens);
    try tst.expectEqual(@as(f64, 0.5), out.state.?.rate_per_sec);
    text = try tmp.dir.readFile(tst.io, "legacy.json", &rb);
    try tst.expect(std.mem.indexOf(u8, text, "\"ts\":1004") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"tokens\":59") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"cooldown_until\":0") != null);
    try tst.expect(std.mem.indexOf(u8, text, "updated_at") == null);
    try tst.expect(std.mem.indexOf(u8, text, "last_429_at") == null);
    // `ratelimit` itself still reads it, key for key.
    const back = ratelimit.parseState(text).?;
    try tst.expectEqual(@as(f64, 59), back.tokens);
    try tst.expectEqual(@as(f64, 1004), back.ts);
    // A 429 in that dialect: its cooldown, its last_429, its count.
    out = Bucket.applyWith(tst.io, lg, .penalize, 1005, 30, 60);
    try tst.expectEqual(Bucket.Take.cooldown, out.take);
    text = try tmp.dir.readFile(tst.io, "legacy.json", &rb);
    try tst.expect(std.mem.indexOf(u8, text, "\"cooldown_until\":1035") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"last_429\":1005") != null);
    try tst.expect(std.mem.indexOf(u8, text, "\"throttles\":3") != null);
    try tst.expectEqual(Bucket.Take.cooldown, Bucket.applyWith(tst.io, lg, .take, 1010, 0, 60).take);
    // A Budget on the Jira service stands a legacy file for Jira's burst.
    var b: Budget = .{};
    b.configure(tst.io, .{ .label = "Jira", .service = "jira", .shared_bucket = lg });
    try tst.expectEqual(@as(u32, 60), b.bucket_legacy_burst);
}
