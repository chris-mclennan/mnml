//! Knowing before you ask: the pacing, the one warmer, and the windows.
//!
//! `ratelimit` says how much of an API's allowance is left and
//! `store` says what is already known. Between them sits the part
//! neither owns: **when** a request may go, **who** is allowed to make
//! the speculative ones, and **how little** of the listing has to be
//! asked for. That is this module, and it lives in the SDK because
//! two integrations drawing on one bucket have to agree about it or
//! the agreement is worth nothing.
//!
//! **Pacing.** A tab that fires twenty requests at once drains a
//! bucket that refills at 0.22/s, and the pane that opens a second
//! later waits two minutes for a token that a background sweep
//! already spent. So a service's requests are spaced at one per
//! `1/rate + margin` — `Gate`, which hands out send times rather than
//! blocking, so a caller can decide what to do while it holds one.
//!
//! **Priority.** Spacing alone would still let a warm sweep sit in
//! front of a click. Every request carries a `request_log.Reason`,
//! and `priorityOf` sorts those into the two that matter: someone is
//! waiting, or nobody is. A background reservation yields a whole gap
//! per interactive request already queued, so the reader is never
//! behind the warmer.
//!
//! **One warmer.** Speculative work is worth doing once on a machine,
//! not once per process: three panes, a poller and a `--prefetch` all
//! warming the same cache is five times the cost for one answer. A
//! lock file beside the ratelimit state names the process doing it;
//! everyone else reads the cache. A lock whose holder is gone — no
//! such pid, or a heartbeat older than `Lock.stale_secs` — is taken,
//! because a warmer that was killed must not stop the next one
//! forever.
//!
//! **Windows.** A full listing is the expensive answer to a question
//! that is usually "nothing moved". `sinceText` and `isoStamp` render
//! the window since the last successful sync in the two dialects the
//! two services speak, always reaching back `overlap_secs` further
//! than the gap, because two clocks are never the same clock.
//!
//! **Budget.** Under `budget_floor` of the bucket, speculative work
//! stops entirely and says so in the log (`poll_skipped_budget`):
//! what is left belongs to whoever is actually looking at something.

const std = @import("std");
const compat = @import("zig_compat.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const broker = @import("broker.zig");
const ratelimit = @import("ratelimit.zig");
const request_log = @import("request_log.zig");
const store_mod = @import("store.zig");

// ─── priority ────────────────────────────────────────────────────────────

/// Is anybody waiting on this request?
pub const Priority = enum {
    /// A person is looking at the thing this answers.
    interactive,
    /// Nobody is: a warm, a delta sweep, a poll, a revalidation.
    background,

    pub fn tag(p: Priority) []const u8 {
        return @tagName(p);
    }
};

/// The priority a reason implies. One mapping, so two integrations
/// queueing against one bucket agree about which of them yields.
pub fn priorityOf(r: request_log.Reason) Priority {
    return if (r.interactive()) .interactive else .background;
}

/// The broker CLASS a reason queues in — the same ordering as
/// `priorityOf`, told apart one step further because the broker can
/// afford four queues where a pacer can only afford "yield or do not".
///
///   * `interactive` — a person is waiting on this pane: `pane_open`,
///     `detail`, `user`, `dispatch`, `readiness`.
///   * `refresh` — wanted soon, nobody watching a spinner: the `r`
///     key and the interval (`refresh`), the statusline poller's
///     `--values` run (`poll`), the runs on a row already on screen
///     (`builds`), and a conditional round trip standing in for one of
///     those (`revalidate`).
///   * `warm` — speculative: `warm`, `delta`, `prefetch`.
///   * `batch` is reached by nothing here on purpose. It is the class
///     a shell script names on the command line; no pane ever queues
///     in it, and that is what makes it the back of the queue.
///
/// `cache_hit` never takes a token, so its class is only ever the
/// default a caller would not use — `warm`, the cheapest thing it
/// could be mistaken for.
pub fn classOf(r: request_log.Reason) broker.Class {
    return switch (r) {
        .pane_open, .detail, .user, .dispatch, .readiness => .interactive,
        .refresh, .poll, .builds, .revalidate => .refresh,
        .warm, .delta, .prefetch, .cache_hit => .warm,
    };
}

/// The class a `Priority` alone implies, for a caller that has a
/// priority and no reason: the coarse mapping, so a background job
/// with nothing more to say queues as `warm` rather than as a pane.
pub fn classOfPriority(p: Priority) broker.Class {
    return switch (p) {
        .interactive => .interactive,
        .background => .warm,
    };
}

// ─── pacing ──────────────────────────────────────────────────────────────

/// Added to the bucket's own `1/rate` so a paced sender spends
/// slightly slower than the bucket refills, rather than exactly as
/// fast: exactly as fast leaves nothing for anyone else on the
/// machine, which is the whole problem this module exists for.
pub const default_margin: f64 = 0.15;

/// The gap between two requests to one service, in milliseconds.
/// `1/rate`, widened by `margin`. A nonsense rate gets one second
/// rather than a divide by zero.
pub fn minGapMs(rate_per_sec: f64, margin: f64) u64 {
    if (!(rate_per_sec > 0.0)) return 1000;
    const secs = (1.0 / rate_per_sec) * (1.0 + @max(margin, 0.0));
    const ms = secs * 1000.0;
    if (!(ms > 0.0)) return 1000;
    return @intFromFloat(@min(ms, 60_000.0));
}

/// Who may send, and when.
///
/// `reserve` does not sleep and does not block: it takes the next
/// slot for a request of the given priority and answers how long the
/// caller must hold it. A caller that decides not to send anyway has
/// only cost the service one idle gap, which is the safe direction.
///
/// Every field is atomic because the two callers are a worker thread
/// and the loop that paints, and paint takes no locks.
pub const Gate = struct {
    /// The spacing this gate enforces.
    gap_ms: u64,
    /// The last slot handed out, in the caller's own millisecond
    /// clock. 0 means none yet.
    last_ms: std.atomic.Value(i64) = .init(0),
    /// Interactive requests queued but not yet sent. A background
    /// reservation yields one whole gap for each.
    interactive_waiting: std.atomic.Value(u32) = .init(0),
    /// Slots handed out, by priority — what a test counts.
    reserved_interactive: std.atomic.Value(u32) = .init(0),
    reserved_background: std.atomic.Value(u32) = .init(0),

    pub fn init(rate_per_sec: f64, margin: f64) Gate {
        return .{ .gap_ms = minGapMs(rate_per_sec, margin) };
    }

    /// The gate for a service's own bucket preset.
    pub fn forConfig(cfg: ratelimit.Config) Gate {
        return init(cfg.rate, default_margin);
    }

    /// Take the next slot and say how long to hold the request, in
    /// milliseconds. Slots never move backwards, so two threads
    /// reserving at once are spaced rather than simultaneous.
    pub fn reserve(self: *Gate, p: Priority, now_ms: i64) u64 {
        const gap: i64 = @intCast(self.gap_ms);
        while (true) {
            const last = self.last_ms.load(.acquire);
            var at = if (last == 0) now_ms else @max(now_ms, last + gap);
            if (p == .background) {
                // Someone is waiting on an answer. Step behind every
                // one of them rather than in front.
                const ahead: i64 = @intCast(self.interactive_waiting.load(.acquire));
                at += ahead * gap;
            }
            if (self.last_ms.cmpxchgWeak(last, at, .acq_rel, .acquire) == null) {
                switch (p) {
                    .interactive => _ = self.reserved_interactive.fetchAdd(1, .monotonic),
                    .background => _ = self.reserved_background.fetchAdd(1, .monotonic),
                }
                return @intCast(@max(at - now_ms, 0));
            }
        }
    }

    /// The slot, and what the caller actually waits for it.
    ///
    /// A background caller waits the whole hold: nobody is watching,
    /// and spacing is the entire point. An interactive caller waits
    /// **nothing** — a person is looking at the pane, the token bucket
    /// already bounds how fast they can spend, and holding them on top
    /// of it makes the pane slower without saving a single token. The
    /// reservation still happens, so background work steps behind them
    /// exactly as if they had waited.
    pub fn hold(self: *Gate, p: Priority, now_ms: i64) u64 {
        const ms = self.reserve(p, now_ms);
        return if (p == .interactive) 0 else ms;
    }

    /// An interactive request is queued: background reservations step
    /// behind it until `leave`.
    pub fn enter(self: *Gate) void {
        _ = self.interactive_waiting.fetchAdd(1, .acq_rel);
    }

    /// It has gone out (or been abandoned).
    pub fn leave(self: *Gate) void {
        while (true) {
            const n = self.interactive_waiting.load(.acquire);
            if (n == 0) return;
            if (self.interactive_waiting.cmpxchgWeak(n, n - 1, .acq_rel, .acquire) == null) return;
        }
    }
};

// ─── the budget floor ────────────────────────────────────────────────────

/// Below this share of the bucket, speculative work stops: what is
/// left belongs to whoever is actually looking at something.
pub const budget_floor: f64 = 0.25;

/// The reason a skipped cycle writes down, so the REQUESTS pane can
/// say why a chip stopped moving rather than leaving it mysterious.
/// Not a `Reason` — nothing was requested; it is a status word for a
/// `--values` run and for a toast.
pub const skipped_budget = "poll_skipped_budget";

/// Whether the bucket has too little left for speculative work. A
/// cooldown counts: a parked bucket has nothing to spare by
/// definition. `null` (the state file could not be read) is NOT under
/// budget — a warmer must not be taken offline by a missing file.
pub fn underBudget(st: ?ratelimit.Status) bool {
    const s = st orelse return false;
    if (s.cooldown_remaining_secs > 0.5) return true;
    if (!(s.capacity > 0)) return false;
    return (s.tokens / s.capacity) < budget_floor;
}

// ─── intervals by kind ───────────────────────────────────────────────────

/// What kind of thing is being kept fresh. The three move at three
/// speeds because they change at three speeds: a listing drifts, a
/// pipeline mid-run does not wait, and whether a pull request may
/// merge is only ever asked about the row under the cursor.
pub const Kind = enum { listing, builds, readiness };

/// Neither the config nor a manifest may poll a service faster than
/// this.
pub const min_interval_secs: u32 = 30;
/// A listing an hour stale is worse than no listing.
pub const max_interval_secs: u32 = 3600;

/// The longest holder name a lock file hands back. A program name is
/// `mnml-jira` sized; anything past this is another writer's nonsense
/// and is truncated rather than trusted.
pub const max_program: usize = 128;
pub const default_listing_secs: u32 = 300;
/// A pipeline that is still running: 90 s is the shortest wait that
/// still reads as "watching it" without being a spin.
pub const default_builds_secs: u32 = 90;

/// The per-kind cadence, as an integration's config states it.
/// `readiness_secs = 0` is the default and means what it says: never
/// on a timer, only when a reader is on the row.
pub const Intervals = struct {
    listing_secs: u32 = default_listing_secs,
    builds_secs: u32 = default_builds_secs,
    readiness_secs: u32 = 0,

    /// The interval for a kind, clamped. 0 stays 0 — "on demand only"
    /// is a real answer and must survive the clamp.
    pub fn secsFor(iv: Intervals, k: Kind) u32 {
        const raw = switch (k) {
            .listing => iv.listing_secs,
            .builds => iv.builds_secs,
            .readiness => iv.readiness_secs,
        };
        return clamp(raw);
    }

    /// Whether this kind runs on a timer at all.
    pub fn onTimer(iv: Intervals, k: Kind) bool {
        return iv.secsFor(k) > 0;
    }
};

/// A stated interval, bounded. Zero is "on demand"; anything else is
/// pulled into `[min_interval_secs, max_interval_secs]`.
pub fn clamp(secs: u32) u32 {
    if (secs == 0) return 0;
    return std.math.clamp(secs, min_interval_secs, max_interval_secs);
}

// ─── delta windows ───────────────────────────────────────────────────────

/// How much further back than the last sync a window always reaches.
/// Two clocks are never the same clock, and a ticket that moved in the
/// second between the query and the answer must not fall through the
/// gap between two windows.
pub const overlap_secs: i64 = 120;

/// The oldest thing a delta poll must ask about, given when the last
/// one succeeded. `0` — never synced, or a clock that went backwards —
/// means there is no window: ask for everything.
pub fn windowStart(last_sync_secs: i64, now_secs: i64) i64 {
    if (last_sync_secs <= 0) return 0;
    if (last_sync_secs > now_secs) return 0;
    return @max(last_sync_secs - overlap_secs, 0);
}

/// Jira's dialect: `-15m` / `-3d`, for `updated >= -15m`. Minutes up
/// to two days, days past that — the coarser unit reads better and
/// JQL rounds it the same way either side. Always at least a minute:
/// `-0m` is a window that catches nothing.
pub fn sinceText(buf: []u8, secs: i64) []const u8 {
    const s = @max(secs, 60);
    if (s < 172_800) {
        const mins = @divTrunc(s + 59, 60);
        return std.fmt.bufPrint(buf, "-{d}m", .{mins}) catch "-30m";
    }
    const days = @divTrunc(s + 86_399, 86_400);
    return std.fmt.bufPrint(buf, "-{d}d", .{days}) catch "-30d";
}

/// Bitbucket's dialect: `2026-09-19T08:30:00+00:00`, for
/// `updated_on > "…"`. UTC always — a window in a local zone is a
/// window that is wrong twice a year.
pub fn isoStamp(buf: []u8, unix_secs: i64) []const u8 {
    const secs = @max(unix_secs, 0);
    const c = civilFromDays(@divFloor(secs, 86_400));
    const rem = @mod(secs, 86_400);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        @as(u32, @intCast(@max(c.y, 0))),
        @as(u32, @intCast(c.m)),
        @as(u32, @intCast(c.d)),
        @as(u32, @intCast(@divTrunc(rem, 3600))),
        @as(u32, @intCast(@divTrunc(@mod(rem, 3600), 60))),
        @as(u32, @intCast(@mod(rem, 60))),
    }) catch "";
}

/// Howard Hinnant's `civil_from_days`: days since the epoch to a
/// year/month/day, with no leap-second table and no locale. The same
/// arithmetic the Bitbucket integration's `dates.zig` does, written
/// again here because the SDK may not import an integration.
fn civilFromDays(days: i64) struct { y: i64, m: u32, d: u32 } {
    const z = days + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y0 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y0 + 1 else y0, .m = @intCast(m), .d = @intCast(d) };
}

/// When a keyed listing last came back whole, kept in an ordinary
/// `Store`: the entry's `fetched_at` IS the mark, so nothing new has
/// to be written to disk or read back.
///
/// **The query is part of the key.** A window is only ever valid
/// against the question it was measured for: change the JQL, the
/// fixVersion, the filter — and "what moved since" answers about a
/// listing nobody is looking at any more. The query goes in the
/// entry's `stamp`, where the store already does exactly this kind of
/// comparison, so a changed question silently becomes a full refetch
/// instead of silently becoming a wrong one.
pub const SyncMarks = struct {
    store: *store_mod.Store,

    /// Unix seconds of the last successful sync of `key` UNDER
    /// `query`, or 0 — never synced, or synced under a different
    /// question.
    pub fn lastSync(self: SyncMarks, key: []const u8, query: []const u8) i64 {
        const e = self.store.stale(key) orelse return 0;
        if (!std.mem.eql(u8, e.stamp, query)) return 0;
        return e.fetched_at;
    }

    /// Record one. The body is the mark's own reason for existing, so
    /// a person reading the file can tell what it is.
    pub fn mark(self: SyncMarks, key: []const u8, query: []const u8, now_secs: i64) Allocator.Error!void {
        try self.store.put(key, query, "sync", now_secs);
    }

    /// The window for `key` in Jira's dialect, or null when there has
    /// been no successful sync of this question and the whole listing
    /// is owed.
    pub fn jiraSince(self: SyncMarks, buf: []u8, key: []const u8, query: []const u8, now_secs: i64) ?[]const u8 {
        const start = windowStart(self.lastSync(key, query), now_secs);
        if (start == 0) return null;
        return sinceText(buf, now_secs - start);
    }

    /// The same window as a Bitbucket timestamp.
    pub fn bitbucketSince(self: SyncMarks, buf: []u8, key: []const u8, query: []const u8, now_secs: i64) ?[]const u8 {
        const start = windowStart(self.lastSync(key, query), now_secs);
        if (start == 0) return null;
        return isoStamp(buf, start);
    }
};

// ─── the freshness a pane paints ─────────────────────────────────────────

/// `as of 4m ago`, the line both families wear above a listing so a
/// screenful of rows says how old it is rather than implying it is
/// now. Empty when nothing has ever been fetched — an empty pane says
/// `loading…`, not `as of 0s ago`.
pub fn asOfText(buf: []u8, fetched_at: i64, now_secs: i64) []const u8 {
    if (fetched_at <= 0) return "";
    var age: [16]u8 = undefined;
    const a = store_mod.ageText(&age, fetched_at, now_secs);
    if (a.len == 0) return "";
    return std.fmt.bufPrint(buf, "as of {s} ago", .{a}) catch "";
}

// ─── one warmer per service ──────────────────────────────────────────────

/// The lock that says which process is doing the speculative work for
/// a service. It sits beside the ratelimit state, in the same shared
/// directory every process on the machine already agrees about, and
/// it holds one JSON object:
///
/// ```
/// {"pid":48123,"program":"mnml-bitbucket","ts":1789526218.411}
/// ```
///
/// `ts` is a heartbeat, not a start time: a warmer that runs for
/// minutes rewrites it, and a lock nobody has touched for
/// `stale_secs` is taken whatever its pid says — which is what covers
/// a pid that was reused and a platform with no liveness probe.
pub const Lock = struct {
    /// Owned.
    path: []u8,
    gpa: Allocator,
    io: Io,
    pid: i32,
    /// Borrowed from the caller, which owns argv.
    program: []const u8,
    /// True between a successful `acquire` and `release`.
    held: bool = false,

    /// A heartbeat older than this means the holder is gone, whatever
    /// the pid says. Generous: a warm sweep of a big workspace is
    /// paced, and pacing is slow on purpose.
    pub const stale_secs: f64 = 300.0;

    /// `<dir of the state file>/<service>-warm.lock`. Owned by the
    /// caller.
    pub fn pathFor(gpa: Allocator, state_path: []const u8, service: []const u8) Allocator.Error![]u8 {
        const dir = std.fs.path.dirname(state_path) orelse ".";
        return std.fmt.allocPrint(gpa, "{s}/{s}-warm.lock", .{ dir, service });
    }

    pub fn init(gpa: Allocator, io: Io, path: []const u8, pid: i32, program: []const u8) Allocator.Error!Lock {
        return .{ .path = try gpa.dupe(u8, path), .gpa = gpa, .io = io, .pid = pid, .program = program };
    }

    /// The lock for a service, beside the bucket every process on this
    /// machine already shares.
    pub fn forService(
        gpa: Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        service: []const u8,
        pid: i32,
        program: []const u8,
    ) Allocator.Error!Lock {
        const state = try ratelimit.statePath(gpa, io, env, service);
        defer gpa.free(state);
        const p = try pathFor(gpa, state, service);
        defer gpa.free(p);
        return init(gpa, io, p, pid, program);
    }

    pub fn deinit(self: *Lock) void {
        if (self.held) self.release();
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Who holds it, as the file says. Null when it is free, missing,
    /// or nonsense — nonsense is free, because a warmer must never be
    /// stopped forever by a byte that got scribbled.
    pub const Holder = struct { pid: i32 = 0, program: []const u8 = "", ts: f64 = 0 };

    /// Take it, or say who has it. The whole read-decide-write happens
    /// under the file's own exclusive lock, so two processes starting
    /// together do not both win.
    pub fn acquire(self: *Lock, now_secs: f64) bool {
        if (std.fs.path.dirname(self.path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        const file = Io.Dir.cwd().createFile(self.io, self.path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        }) catch return false;
        defer file.close(self.io);
        var buf: [512]u8 = undefined;
        var name: [max_program]u8 = undefined;
        const n = file.readPositionalAll(self.io, &buf, 0) catch 0;
        if (parseHolder(buf[0..n], &name)) |h| {
            if (h.pid != self.pid and !isStale(h, now_secs)) return false;
        }
        writeHolder(self.io, file, self.pid, self.program, now_secs) catch return false;
        self.held = true;
        return true;
    }

    /// Say the warmer is still alive. A long sweep that never does
    /// this is judged dead and its lock taken out from under it.
    pub fn heartbeat(self: *Lock, now_secs: f64) void {
        if (!self.held) return;
        const file = Io.Dir.cwd().createFile(self.io, self.path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        }) catch return;
        defer file.close(self.io);
        writeHolder(self.io, file, self.pid, self.program, now_secs) catch {};
    }

    /// Give it up. Only ours is ever deleted: a lock someone else took
    /// (because ours went stale) is theirs now.
    pub fn release(self: *Lock) void {
        self.held = false;
        const file = Io.Dir.cwd().createFile(self.io, self.path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        }) catch return;
        var mine = false;
        {
            defer file.close(self.io);
            var buf: [512]u8 = undefined;
            var name: [max_program]u8 = undefined;
            const n = file.readPositionalAll(self.io, &buf, 0) catch 0;
            if (parseHolder(buf[0..n], &name)) |h| mine = h.pid == self.pid;
        }
        if (mine) Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
    }

    /// Who holds it right now, without taking it — what `--diag`
    /// prints and what a pane's hover says.
    pub fn peek(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?Holder {
        var buf: [512]u8 = undefined;
        var name: [max_program]u8 = undefined;
        const text = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
        const h = parseHolder(text, &name) orelse return null;
        return .{ .pid = h.pid, .program = try gpa.dupe(u8, h.program), .ts = h.ts };
    }
};

/// Is anybody holding the lock at `path` right now? Read-only, no
/// allocator, and false for a file that is missing, unreadable or
/// nonsense — the same "nonsense is free" rule `acquire` follows.
///
/// What this is for: a socket file outlives the process that bound it,
/// so "the file is there" is not "somebody is serving". Asking the
/// lock first is both cheaper than a connect and quieter — a refused
/// connect to a dead socket is an undeclared errno, which a safe build
/// answers with a stack trace on the user's terminal.
pub fn heldBySomeone(io: Io, path: []const u8, now_secs: f64) bool {
    var buf: [512]u8 = undefined;
    var name: [max_program]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, path, &buf) catch return false;
    const h = parseHolder(text, &name) orelse return false;
    return !isStale(h, now_secs);
}

/// A holder that is gone: no such process, or a heartbeat nobody has
/// touched for `Lock.stale_secs`. The age test is the one that holds
/// everywhere — `pidAlive` cannot answer on Windows and can be wrong
/// anywhere once a pid is reused.
pub fn isStale(h: Lock.Holder, now_secs: f64) bool {
    if (h.pid <= 0) return true;
    if (now_secs - h.ts > Lock.stale_secs) return true;
    if (h.ts > now_secs + Lock.stale_secs) return true; // a clock that ran ahead
    return !pidAlive(h.pid);
}

/// This process, as a lock names it. On Windows it is the process id
/// too: `pidAlive` cannot probe it there, so the heartbeat's age decides
/// whether the holder is gone — but a zero would have made every lock
/// stale on sight (`isStale`), and two warmers would both have taken it.
pub fn selfPid() i32 {
    if (@import("builtin").os.tag == .windows) return @intCast(std.os.windows.GetCurrentProcessId());
    return @intCast(std.c.getpid());
}

/// Is that process still there? Signal 0 is the POSIX liveness probe:
/// it delivers nothing and answers ESRCH when there is nobody. Windows
/// has no equivalent here, so it answers "yes" and leaves the whole
/// decision to the heartbeat's age.
pub fn pidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    if (@import("builtin").os.tag == .windows) return true;
    const rc = std.c.kill(pid, @enumFromInt(0));
    if (rc == 0) return true;
    return std.c._errno().* != @intFromEnum(std.c.E.SRCH);
}

/// The holder line, escaped as **JSON** — which is not what
/// `std.zig.fmtString` does.
///
/// It rendered a control byte as `\xNN`, which no JSON parser accepts,
/// so `parseHolder` answered `null`, `acquire`'s "nonsense is free"
/// rule fired, and the lock read as FREE while it was held — two
/// warmers on one bucket. `store.zig` fixed the same confusion in the
/// cache file and left `writeJsonString` behind for it; this is the
/// second caller.
fn writeHolder(io: Io, file: Io.File, pid: i32, program: []const u8, now_secs: f64) !void {
    var out: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    w.print("{{\"pid\":{d},\"program\":", .{pid}) catch return error.NoSpaceLeft;
    store_mod.writeJsonString(&w, program) catch return error.NoSpaceLeft;
    w.print(",\"ts\":{d:.3}}}", .{now_secs}) catch return error.NoSpaceLeft;
    try file.setLength(io, 0);
    try file.writePositionalAll(io, w.buffered(), 0);
}

/// The holder named in `text`, with `program` copied into `name_out`
/// — never handed back pointing at this function's own scratch.
///
/// `parseFromSliceLeaky` defaults to `.alloc_if_needed`: a name with no
/// escape in it comes back as a subslice of `text`, but one WITH an
/// escape is allocated on the allocator it was given, which here is a
/// fixed buffer on this stack frame. Returning that slice is the
/// family's own bug — a string handed to something that outlives the
/// arena it was made on — and `Lock.peek` then `dupe`s out of the dead
/// frame, which the `dupe` call itself is free to have reused.
///
/// The name is copied out the way `recentDraws` copies its winner: the
/// caller owns the buffer, so what comes back is as long-lived as the
/// caller is.
fn parseHolder(text: []const u8, name_out: []u8) ?Lock.Holder {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    // A fixed buffer rather than an allocator: this runs under a file
    // lock on a path a pane is waiting on, and a holder is three
    // numbers and a name.
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const Row = struct { pid: i32 = 0, program: []const u8 = "", ts: f64 = 0 };
    const row = std.json.parseFromSliceLeaky(Row, fba.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return null;
    if (row.pid == 0) return null;
    const n = @min(row.program.len, name_out.len);
    @memcpy(name_out[0..n], row.program[0..n]);
    return .{ .pid = row.pid, .program = name_out[0..n], .ts = row.ts };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("testing.zig");

test "the gap is the bucket's own rate, widened — and a nonsense rate is a second, not a crash" {
    // Bitbucket's 0.22/s is 4.55 s between requests; the margin makes
    // it 5.2.
    try t.expectEqual(@as(u64, 5227), minGapMs(0.22, default_margin));
    // Jira's 0.33/s.
    try t.expectEqual(@as(u64, 3484), minGapMs(0.33, default_margin));
    // No margin is exactly the refill.
    try t.expectEqual(@as(u64, 5000), minGapMs(0.2, 0.0));
    try t.expectEqual(@as(u64, 1000), minGapMs(0, 0.1));
    try t.expectEqual(@as(u64, 1000), minGapMs(-3, 0.1));
    // A rate so slow the gap would be an hour is capped: a paced
    // sender that never sends is not pacing.
    try t.expectEqual(@as(u64, 60_000), minGapMs(0.000001, 0.0));
}

test "a burst is spread one per gap, and an interactive request never queues behind a warm sweep" {
    var g: Gate = .init(0.2, 0.0); // a 5 s gap, so the arithmetic is readable
    try t.expectEqual(@as(u64, 5000), g.gap_ms);

    // The first goes now; the next four are spread.
    try t.expectEqual(@as(u64, 0), g.reserve(.background, 1_000_000));
    try t.expectEqual(@as(u64, 5000), g.reserve(.background, 1_000_000));
    try t.expectEqual(@as(u64, 10_000), g.reserve(.background, 1_000_000));
    // Time passing is credited: a caller that waited does not wait twice.
    try t.expectEqual(@as(u64, 5000), g.reserve(.background, 1_010_000));

    // Someone clicks. The interactive request takes the next slot…
    g.enter();
    try t.expectEqual(@as(u64, 10_000), g.reserve(.interactive, 1_010_000));
    // …and while it is queued, a background reservation steps a whole
    // gap behind it rather than in front.
    try t.expectEqual(@as(u64, 20_000), g.reserve(.background, 1_010_000));
    g.leave();
    // Once it has gone out, background work is spaced normally again.
    try t.expectEqual(@as(u64, 25_000), g.reserve(.background, 1_010_000));

    // A person waits for nothing: their reservation moves the slot so
    // background work steps behind them, and then they go.
    g.enter();
    try t.expectEqual(@as(u64, 0), g.hold(.interactive, 1_010_000));
    g.leave();
    // A background caller waits the whole thing.
    try t.expect(g.hold(.background, 1_010_000) > 0);

    try t.expectEqual(@as(u32, 2), g.reserved_interactive.load(.acquire));
    try t.expectEqual(@as(u32, 7), g.reserved_background.load(.acquire));
    // `leave` under a zero count is a no-op, not an underflow.
    g.leave();
    try t.expectEqual(@as(u32, 0), g.interactive_waiting.load(.acquire));
}

test "the reason decides who yields" {
    try t.expectEqual(Priority.interactive, priorityOf(.pane_open));
    try t.expectEqual(Priority.interactive, priorityOf(.detail));
    try t.expectEqual(Priority.interactive, priorityOf(.user));
    try t.expectEqual(Priority.interactive, priorityOf(.readiness));
    try t.expectEqual(Priority.interactive, priorityOf(.dispatch));
    try t.expectEqual(Priority.interactive, priorityOf(.refresh));
    try t.expectEqual(Priority.background, priorityOf(.poll));
    try t.expectEqual(Priority.background, priorityOf(.prefetch));
    try t.expectEqual(Priority.background, priorityOf(.warm));
    try t.expectEqual(Priority.background, priorityOf(.delta));
    try t.expectEqual(Priority.background, priorityOf(.revalidate));
    try t.expectEqual(Priority.background, priorityOf(.builds));
}

test "under a quarter of the bucket the speculative work stops — and a missing state file does not stop it" {
    const full: ratelimit.Status = .{ .tokens = 40, .capacity = 40, .rate = 0.22, .baseline_rate = 0.22, .throttles = 0, .cooldown_remaining_secs = 0 };
    try t.expect(!underBudget(full));
    var low = full;
    low.tokens = 10.0; // exactly a quarter is still enough
    try t.expect(!underBudget(low));
    low.tokens = 9.99;
    try t.expect(underBudget(low));
    // A parked bucket has nothing to spare whatever the tokens say.
    var parked = full;
    parked.cooldown_remaining_secs = 30;
    try t.expect(underBudget(parked));
    // Unreadable is not "empty": a warmer must not be taken offline by
    // a missing file.
    try t.expect(!underBudget(null));
}

test "intervals by kind, with `on demand` surviving the clamp" {
    const iv: Intervals = .{};
    try t.expectEqual(@as(u32, 300), iv.secsFor(.listing));
    try t.expectEqual(@as(u32, 90), iv.secsFor(.builds));
    try t.expectEqual(@as(u32, 0), iv.secsFor(.readiness));
    try t.expect(iv.onTimer(.listing));
    try t.expect(!iv.onTimer(.readiness));

    // A config that asks for something silly is pulled into range …
    const eager: Intervals = .{ .listing_secs = 1, .builds_secs = 99999, .readiness_secs = 60 };
    try t.expectEqual(@as(u32, min_interval_secs), eager.secsFor(.listing));
    try t.expectEqual(@as(u32, max_interval_secs), eager.secsFor(.builds));
    // … but "on demand only" is a real answer and stays one.
    try t.expectEqual(@as(u32, 60), eager.secsFor(.readiness));
    try t.expectEqual(@as(u32, 0), clamp(0));
}

test "a delta window always reaches back past the last sync, in both dialects" {
    const now: i64 = 1_789_526_218;
    // Never synced: there is no window, the whole listing is owed.
    try t.expectEqual(@as(i64, 0), windowStart(0, now));
    // A clock that went backwards is the same answer, rather than a
    // window into the future that matches nothing.
    try t.expectEqual(@as(i64, 0), windowStart(now + 10, now));
    // A sync five minutes ago: the window reaches two minutes further.
    try t.expectEqual(now - 300 - overlap_secs, windowStart(now - 300, now));

    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("-7m", sinceText(&buf, 420));
    // Rounded up, never down: half a minute of window is a minute.
    try t.expectEqualStrings("-8m", sinceText(&buf, 421));
    // Never zero — `-0m` catches nothing.
    try t.expectEqualStrings("-1m", sinceText(&buf, 0));
    try t.expectEqualStrings("-1m", sinceText(&buf, -500));
    try t.expectEqualStrings("-2880m", sinceText(&buf, 172_799));
    try t.expectEqualStrings("-2d", sinceText(&buf, 172_800));
    try t.expectEqualStrings("-31d", sinceText(&buf, 30 * 86_400 + 1));

    // Bitbucket wants a timestamp, and it is UTC whatever the machine
    // thinks the time is.
    try t.expectEqualStrings("1970-01-01T00:00:00+00:00", isoStamp(&buf, 0));
    try t.expectEqualStrings("2026-09-15T00:00:00+00:00", isoStamp(&buf, 1_789_430_400));
    try t.expectEqualStrings("2026-09-15T02:36:58+00:00", isoStamp(&buf, 1_789_439_818));
    try t.expectEqualStrings("1970-01-01T00:00:00+00:00", isoStamp(&buf, -99));
}

test "the sync mark is the store's own fetched_at, so a delta window survives a restart" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "sync.json" });
    defer t.allocator.free(path);
    const now: i64 = 1_789_526_218;
    const q = "assignee = currentUser() ORDER BY updated DESC";

    {
        var s = try store_mod.Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        const marks: SyncMarks = .{ .store = &s };
        // Nothing synced: no window, so the caller asks for everything.
        try t.expectEqual(@as(i64, 0), marks.lastSync("work_open", q));
        var b: [32]u8 = undefined;
        try t.expect(marks.jiraSince(&b, "work_open", q, now) == null);
        try t.expect(marks.bitbucketSince(&b, "work_open", q, now) == null);
        try marks.mark("work_open", q, now - 300);
        s.save();
    }
    {
        var s = try store_mod.Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        const marks: SyncMarks = .{ .store = &s };
        try t.expectEqual(now - 300, marks.lastSync("work_open", q));
        var b: [32]u8 = undefined;
        // 300 s plus the 120 s overlap, rounded up: seven minutes.
        try t.expectEqualStrings("-7m", marks.jiraSince(&b, "work_open", q, now).?);
        try t.expectEqualStrings("2026-09-16T02:29:58+00:00", marks.bitbucketSince(&b, "work_open", q, now).?);
        // A key nobody synced still has no window of its own.
        try t.expect(marks.jiraSince(&b, "reported", q, now) == null);
        // And neither has the same tab asking a DIFFERENT question:
        // "what moved since" is only ever an answer about the listing
        // it was measured for. A picker that rewrites the query gets a
        // full refetch, not a window onto the last one.
        try t.expect(marks.jiraSince(&b, "work_open", "project = ENG AND fixVersion = \"2.3.0\"", now) == null);
        try t.expectEqual(@as(i64, 0), marks.lastSync("work_open", ""));
    }
}

test "the freshness a listing wears, and the nothing an empty one wears" {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("as of 4m ago", asOfText(&buf, 1000, 1000 + 4 * 60));
    try t.expectEqualStrings("as of 42s ago", asOfText(&buf, 1000, 1042));
    try t.expectEqualStrings("as of 3d ago", asOfText(&buf, 1, 1 + 3 * 86400));
    // Never fetched: a pane says `loading…`, not `as of 0s ago`.
    try t.expectEqualStrings("", asOfText(&buf, 0, 1000));
    try t.expectEqualStrings("", asOfText(&buf, -5, 1000));
}

test "one warmer per service: the second process reads the cache, and a dead holder's lock is taken" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const state = try std.fs.path.join(t.allocator, &.{ dir, "bitbucket-ratelimit.json" });
    defer t.allocator.free(state);
    const path = try Lock.pathFor(t.allocator, state, "bitbucket");
    defer t.allocator.free(path);
    try t.expect(sdk_testing.pathEndsWith(path, "/bitbucket-warm.lock"));

    // This process: a lock whose pid is alive is a lock that is held,
    // and only a real pid proves that.
    const me: i32 = selfPid();
    const now: f64 = 1_789_526_218.0;

    var a = try Lock.init(t.allocator, t.io, path, me, "mnml-bitbucket");
    defer a.deinit();
    try t.expect(a.acquire(now));
    try t.expect(a.held);
    // Taking it again is not a deadlock: it is the same warmer.
    try t.expect(a.acquire(now + 1));

    // A second process on the same machine reads the cache instead.
    var b = try Lock.init(t.allocator, t.io, path, 1, "mnml-jira");
    defer b.deinit();
    try t.expect(!b.acquire(now + 2));
    const who = (try Lock.peek(t.allocator, t.io, path)).?;
    defer t.allocator.free(who.program);
    try t.expectEqual(me, who.pid);
    try t.expectEqualStrings("mnml-bitbucket", who.program);

    // A heartbeat keeps a long sweep alive past the staleness window.
    a.heartbeat(now + Lock.stale_secs);
    try t.expect(!b.acquire(now + Lock.stale_secs + 1));
    // Without one, the holder is judged gone and the lock is taken.
    try t.expect(b.acquire(now + 2 * Lock.stale_secs + 10));
    try t.expect(b.held);

    // Releasing a lock somebody else now holds leaves theirs alone.
    a.release();
    const still = (try Lock.peek(t.allocator, t.io, path)).?;
    t.allocator.free(still.program);
    b.release();
    try t.expect((try Lock.peek(t.allocator, t.io, path)) == null);
    // A free lock is free.
    try t.expect(a.acquire(now + 3 * Lock.stale_secs));
}

test "the holder line is JSON, and the name it carries belongs to the caller" {
    var name: [max_program]u8 = undefined;

    // `\"` is a JSON escape, so `parseFromSliceLeaky` cannot hand back a
    // subslice of the input — it ALLOCATES, on the allocator it was
    // given, which inside `parseHolder` is a fixed buffer on that
    // function's own frame. Returning that slice was the family's own
    // bug: a string handed to something that outlives the arena it was
    // made on, and `Lock.peek` then duping out of a dead frame.
    const h = parseHolder("{\"pid\":7,\"program\":\"mnml\\\"jira\",\"ts\":1.0}", &name).?;
    try t.expectEqualStrings("mnml\"jira", h.program);
    // What comes back lives in the CALLER's buffer. This is the
    // assertion the old shape fails deterministically — the frame it
    // used to point into is not inside `name`.
    const base = @intFromPtr(&name);
    const at = @intFromPtr(h.program.ptr);
    try t.expect(at >= base and at + h.program.len <= base + name.len);

    // And the writer's half: a name with a control byte in it used to
    // be rendered `\xNN` (escaped for a Zig literal, not for JSON), so
    // the line came back UNPARSEABLE and `acquire`'s "nonsense is free"
    // rule read a held lock as free — two warmers on one bucket.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "odd-warm.lock" });
    defer t.allocator.free(path);
    const odd = "mnml\x1b\"jira";
    var lock = try Lock.init(t.allocator, t.io, path, selfPid(), odd);
    defer lock.deinit();
    const now: f64 = 1_789_526_218.0;
    try t.expect(lock.acquire(now));
    // Read it back the way a second process would: the lock is HELD,
    // and the name on it is the name that was written.
    try t.expect(heldBySomeone(t.io, path, now + 1));
    const who = (try Lock.peek(t.allocator, t.io, path)).?;
    defer t.allocator.free(who.program);
    try t.expectEqualStrings(odd, who.program);
    lock.release();
}

test "a lock whose holder is a pid nobody is, or nonsense on disk, is free" {
    const now: f64 = 1_789_526_218.0;
    // A live pid with a fresh heartbeat is held.
    const me: i32 = 1; // pid 1 exists everywhere a test runs
    try t.expect(!isStale(.{ .pid = me, .program = "x", .ts = now }, now));
    // A heartbeat from the far future is a clock that ran away, not a
    // lock to respect forever.
    try t.expect(isStale(.{ .pid = me, .program = "x", .ts = now + 10 * Lock.stale_secs }, now));
    // No pid at all.
    try t.expect(isStale(.{ .pid = 0, .program = "x", .ts = now }, now));
    // Scribble on disk is a free lock, not a warmer stopped forever.
    var name: [max_program]u8 = undefined;
    try t.expect(parseHolder("not json", &name) == null);
    try t.expect(parseHolder("", &name) == null);
    try t.expect(parseHolder("{\"program\":\"x\"}", &name) == null);
    const h = parseHolder("{\"pid\":7,\"program\":\"mnml-jira\",\"ts\":12.5}", &name).?;
    try t.expectEqual(@as(i32, 7), h.pid);
    try t.expectEqualStrings("mnml-jira", h.program);
    try t.expectEqual(@as(f64, 12.5), h.ts);
    if (@import("builtin").os.tag != .windows) {
        // A pid nothing is: free, heartbeat or no heartbeat.
        try t.expect(!pidAlive(0x7FFF_FFFE));
        try t.expect(isStale(.{ .pid = 0x7FFF_FFFE, .program = "x", .ts = now }, now));
    }
}

test "every reason has a broker class, and the classes agree with the pacer's two priorities" {
    // The reasons a person is waiting on go to the front.
    for ([_]request_log.Reason{ .pane_open, .detail, .user, .dispatch, .readiness }) |r| {
        try t.expectEqual(broker.Class.interactive, classOf(r));
        try t.expectEqual(Priority.interactive, priorityOf(r));
    }
    // A pane refresh and the `--values` poller share a class: wanted
    // soon, nobody watching a spinner.
    for ([_]request_log.Reason{ .refresh, .poll, .builds, .revalidate }) |r| {
        try t.expectEqual(broker.Class.refresh, classOf(r));
    }
    // Speculative work is last of the four that panes use.
    for ([_]request_log.Reason{ .warm, .delta, .prefetch }) |r| {
        try t.expectEqual(broker.Class.warm, classOf(r));
        try t.expectEqual(Priority.background, priorityOf(r));
    }
    // `refresh` is the one place the two mappings differ, and on
    // purpose: the pacer lets a refresh through as interactive because
    // the user pressed `r`; the broker has a class between them.
    try t.expectEqual(Priority.interactive, priorityOf(.refresh));
    try t.expectEqual(broker.Class.refresh, classOf(.refresh));

    // Nothing a pane does ever queues as `batch`. That class is what a
    // shell script names on the command line, and it is the back of
    // the queue because nothing else can reach it.
    inline for (compat.enumFields(request_log.Reason)) |f| {
        try t.expect(classOf(@field(request_log.Reason, f.name)) != .batch);
    }

    try t.expectEqual(broker.Class.interactive, classOfPriority(.interactive));
    try t.expectEqual(broker.Class.warm, classOfPriority(.background));
}
