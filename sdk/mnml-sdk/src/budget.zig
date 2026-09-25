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
//!
//! Nothing here holds a header value other than the numbers above, a
//! body, or a token.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const request_log = @import("request_log.zig");

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
        if (s.hasHeaders()) return std.fmt.bufPrint(buf, "{d}/{d}", .{ @max(s.remaining.?, 0), s.limit.? }) catch "";
        return std.fmt.bufPrint(buf, "{d}/h", .{s.hour_calls}) catch "";
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
        w.writeAll("Shift+N turns dry run on and off.") catch {};
        return w.buffered();
    }
};

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

    pub fn configure(b: *Budget, io: Io, opts: Options) void {
        b.io = io;
        b.configured = true;
        b.label = opts.label;
        b.backoff = opts.backoff;
        b.hourly_budget = opts.hourly_budget;
        b.prng = .init(opts.seed);
        b.dry_run.store(opts.dry_run, .release);
        b.tally_path_len = 0;
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
        const until = b.nowMs() + @as(i64, secs) * 1000;
        const prev = b.paused_until_ms.load(.acquire);
        if (until > prev) b.paused_until_ms.store(until, .release);
        return secs;
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
