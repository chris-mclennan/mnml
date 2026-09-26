//! What changed, and when to ask. One seam, two sources.
//!
//! A pane that lists things from a remote API has to find out when one
//! of them moved. The default is to ask: poll the listing on an
//! interval. That is expensive when nothing moves — a pane polling a
//! quiet listing every five seconds spends nine hundred calls a day to
//! learn nothing — so the poller here is **adaptive**: every poll that
//! comes back unchanged (a `304`, the same `ETag`, the same content
//! hash) doubles the interval, from the configured base up to a cap,
//! and anything that suggests somebody cares — a change, a key, a
//! click, a focus, a manual refresh — snaps it back to the base.
//!
//! Some machines have something better than asking: a process that
//! already knows what changed (a webhook relay, a gateway, a script
//! watching a queue). `FileFeed` is the door for it — a JSONL file
//! anything can append to, one event per line:
//!
//! ```
//! {"kind":"pr","key":"api#1234","at":1790000000,"source":"relay"}
//! {"kind":"issue","key":"ENG-12","at":1790000003.5,"source":"relay"}
//! {"kind":"heartbeat","at":1790000060,"source":"relay"}
//! ```
//!
//! The pane reads the lines it has not seen (by byte offset, like the
//! IPC channel's reader), coalesces them by key, and fetches only those
//! items. While the file is live the poller does not stop — it drops to
//! a slow safety sweep, because an event feed that silently loses one
//! event must not leave a row wrong forever. When the file goes missing
//! or quiet (no line of any kind for `stale_secs`) the pane falls back
//! to adaptive polling and says so. The format is a public contract,
//! written up in `docs/SDK.md`.
//!
//!   * `Schedule`  — the adaptive interval, on an injected clock.
//!   * `Feed`      — the interface: "what changed since my last look".
//!   * `PollFeed`  — a `Schedule` behind that interface: it never knows
//!                   WHICH items moved, only that a sweep is due.
//!   * `FileFeed`  — the JSONL reader behind the same interface.
//!   * `Watcher`   — the two together, and the rule between them: the
//!                   file when it is live, the poller always, and the
//!                   poller's pace set by which of those holds.
//!
//! Nothing here makes a request. The pane asks `Watcher.look`, gets a
//! `Look` back (`sweep`: refresh the listing; `changed`: fetch these
//! keys), does the fetching through its own client and budget, and
//! reports back with `settled` (did the sweep find a change?) and
//! `touch` (the reader did something).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ─── configuration ───────────────────────────────────────────────────────

/// The `feed` block both first-party integrations carry in their
/// `config.zon`, spelled the same in each.
pub const Config = struct {
    /// The JSONL file an external process appends events to. Empty is
    /// off: the pane polls. A relative path is taken against the
    /// directory the config file lives in; `~/` is the home directory.
    file: []const u8 = "",
    /// No line of any kind — an event or a heartbeat — for this long,
    /// and the file is treated as dead: the pane goes back to adaptive
    /// polling and the budget chip's hover says why.
    stale_secs: u32 = 300,
    /// While the file is live, the listing is still swept this often,
    /// in case an event was lost on the way.
    sweep_secs: u32 = 600,
};

/// Which events a pane wants. A line of any other kind still proves
/// the writer is alive.
pub const Kind = enum {
    /// A pull request, keyed `<repo>#<id>` (or `<workspace>/<repo>#<id>`).
    pr,
    /// A tracker issue, keyed by its own key (`ENG-12`).
    issue,

    pub fn tag(k: Kind) []const u8 {
        return @tagName(k);
    }
};

/// The longest key a line may carry. A longer one is not a key.
pub const max_key_len: usize = 200;

// ─── the adaptive interval ───────────────────────────────────────────────

/// When the next poll is due. Every value is milliseconds on whatever
/// clock the caller hands in, so a test drives it deterministically.
///
///   * `due(now)` — has `current` passed since the last poll started?
///   * `started(now)` — a poll went out.
///   * `settled(changed)` — it came back: a change resets the interval
///     to the base, no change doubles it (capped at `max`).
///   * `touch()` — the reader did something: back to the base, so the
///     next poll is at most `base` after the last one.
///   * `override_ms` — a fixed pace that wins over the adaptive one
///     (the safety sweep while an event feed is live); null is none.
pub const Schedule = struct {
    base_ms: i64 = 0,
    max_ms: i64 = 0,
    current_ms: i64 = 0,
    /// When the last poll started; 0 before the first.
    last_ms: i64 = 0,
    override_ms: ?i64 = null,
    /// Polls that came back unchanged in a row — what the hover says
    /// the interval is backing off from.
    quiet: u32 = 0,

    /// `base_secs = 0` turns polling off. A `max_secs` at or below the
    /// base (0 included) keeps the interval fixed at the base.
    pub fn init(base_secs: u32, max_secs: u32) Schedule {
        const base: i64 = @as(i64, base_secs) * 1000;
        const max: i64 = @max(base, @as(i64, max_secs) * 1000);
        return .{ .base_ms = base, .max_ms = max, .current_ms = base };
    }

    pub fn enabled(s: *const Schedule) bool {
        return s.base_ms > 0;
    }

    /// The interval in force, the override included.
    pub fn intervalMs(s: *const Schedule) i64 {
        return s.override_ms orelse s.current_ms;
    }

    pub fn intervalSecs(s: *const Schedule) u32 {
        return @intCast(@divFloor(@max(s.intervalMs(), 0), 1000));
    }

    /// Is a poll due at `now_ms`? Never before the first `started`:
    /// the pane's own first load is not the poller's to make.
    pub fn due(s: *const Schedule, now_ms: i64) bool {
        if (!s.enabled() or s.last_ms == 0) return false;
        return now_ms - s.last_ms >= s.intervalMs();
    }

    pub fn started(s: *Schedule, now_ms: i64) void {
        s.last_ms = now_ms;
    }

    /// A poll came back. `changed`: the listing moved (a new body, a
    /// different hash) — back to the base. Otherwise one step slower.
    pub fn settled(s: *Schedule, changed: bool) void {
        if (!s.enabled()) return;
        if (changed) {
            s.current_ms = s.base_ms;
            s.quiet = 0;
            return;
        }
        s.quiet +|= 1;
        s.current_ms = @min(s.current_ms *| 2, s.max_ms);
    }

    /// The reader did something: a key, a click, a focus, `r`.
    pub fn touch(s: *Schedule) void {
        s.current_ms = s.base_ms;
        s.quiet = 0;
    }

    /// Is the interval backed off past the base?
    pub fn backedOff(s: *const Schedule) bool {
        return s.override_ms == null and s.current_ms > s.base_ms;
    }
};

// ─── the interface ───────────────────────────────────────────────────────

/// One item that moved, keyed the way the pane keys its rows.
pub const Change = struct {
    key: []const u8,
    /// The newest `at` any line for this key carried — seconds since
    /// the epoch, as the writer said it.
    at: f64 = 0,
};

/// What a look found.
pub const Look = struct {
    /// Refresh the listing: the poller is due (or the safety sweep is).
    sweep: bool = false,
    /// Fetch just these, once each. On the caller's allocator.
    changed: []const Change = &.{},
};

/// "What changed since my last look?" — the question a pane asks every
/// source the same way. `look` may allocate the answer on `a`.
pub const Feed = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        look: *const fn (ptr: *anyopaque, a: Allocator, now_ms: i64) Allocator.Error!Look,
    };

    pub fn look(f: Feed, a: Allocator, now_ms: i64) Allocator.Error!Look {
        return f.vtable.look(f.ptr, a, now_ms);
    }
};

// ─── the poller ──────────────────────────────────────────────────────────

/// The poller as a `Feed`: it never knows WHICH items moved, only that
/// it is time to ask again.
pub const PollFeed = struct {
    schedule: Schedule,

    pub fn init(base_secs: u32, max_secs: u32) PollFeed {
        return .{ .schedule = .init(base_secs, max_secs) };
    }

    pub fn feed(p: *PollFeed) Feed {
        return .{ .ptr = p, .vtable = &.{ .look = lookErased } };
    }

    pub fn look(p: *PollFeed, now_ms: i64) Look {
        return .{ .sweep = p.schedule.due(now_ms) };
    }

    fn lookErased(ptr: *anyopaque, a: Allocator, now_ms: i64) Allocator.Error!Look {
        _ = a;
        const p: *PollFeed = @ptrCast(@alignCast(ptr));
        return p.look(now_ms);
    }
};

// ─── the file ────────────────────────────────────────────────────────────

/// The JSONL file. Reads what was appended since the last look —
/// complete lines only, from a byte offset — and hands back the keys of
/// the wanted kind, coalesced.
pub const FileFeed = struct {
    io: Io,
    kind: Kind,
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,
    stale_ms: i64,
    /// Bytes of the file already read. The first look starts at the
    /// end: what was in the file before the pane opened is history the
    /// pane's own first load already covers.
    offset: u64 = 0,
    opened: bool = false,
    missing: bool = true,
    /// When the writer last proved it was alive: a line of any kind,
    /// or — at the first look — the file's own modification time, so a
    /// file nobody has written to in a day is stale from the start
    /// rather than for the first `stale_secs`.
    last_line_ms: i64 = 0,
    /// For the hover: events of the wanted kind taken so far, and who
    /// wrote the last line.
    events: u64 = 0,
    source_buf: [48]u8 = undefined,
    source_len: usize = 0,
    /// At most this much is read per look; the rest waits for the next.
    pub const max_read: usize = 1 << 20;

    pub fn init(io: Io, file_path: []const u8, kind: Kind, stale_secs: u32) FileFeed {
        var f: FileFeed = .{ .io = io, .kind = kind, .stale_ms = @as(i64, @max(stale_secs, 1)) * 1000 };
        const n = @min(file_path.len, f.path_buf.len);
        @memcpy(f.path_buf[0..n], file_path[0..n]);
        f.path_len = n;
        return f;
    }

    pub fn path(f: *const FileFeed) []const u8 {
        return f.path_buf[0..f.path_len];
    }

    pub fn source(f: *const FileFeed) []const u8 {
        return f.source_buf[0..f.source_len];
    }

    pub fn feed(f: *FileFeed) Feed {
        return .{ .ptr = f, .vtable = &.{ .look = lookErased } };
    }

    fn lookErased(ptr: *anyopaque, a: Allocator, now_ms: i64) Allocator.Error!Look {
        const f: *FileFeed = @ptrCast(@alignCast(ptr));
        return .{ .changed = try f.look(a, now_ms) };
    }

    pub const Status = enum {
        /// A line (or the file's mtime, before any) inside `stale_secs`.
        live,
        /// No file at the path.
        missing,
        /// A file, and nobody has written to it for `stale_secs`.
        stale,
    };

    pub fn status(f: *const FileFeed, now_ms: i64) Status {
        if (f.missing) return .missing;
        if (now_ms - f.last_line_ms > f.stale_ms) return .stale;
        return .live;
    }

    /// How long since the writer was last heard from, in seconds.
    pub fn quietSecs(f: *const FileFeed, now_ms: i64) i64 {
        if (f.last_line_ms == 0) return 0;
        return @divFloor(@max(now_ms - f.last_line_ms, 0), 1000);
    }

    /// The keys appended since the last look, coalesced: one `Change`
    /// per key, in the order they first appeared, carrying the newest
    /// `at`. On `a`.
    pub fn look(f: *FileFeed, a: Allocator, now_ms: i64) Allocator.Error![]const Change {
        const io = f.io;
        const file = Io.Dir.cwd().openFile(io, f.path(), .{}) catch {
            f.missing = true;
            // A file that comes back is read from its first byte: it
            // is a new file, and everything in it is news.
            f.offset = 0;
            f.opened = true;
            return &.{};
        };
        defer file.close(io);
        const st = file.stat(io) catch return &.{};
        const was_missing = f.missing;
        f.missing = false;
        if (!f.opened) {
            // The first look: history is skipped, and the writer is
            // as alive as the file's last write says.
            f.opened = true;
            f.offset = st.size;
            f.last_line_ms = st.mtime.toMilliseconds();
            return &.{};
        }
        if (was_missing and f.last_line_ms == 0) f.last_line_ms = st.mtime.toMilliseconds();
        // Truncated or replaced: start over.
        if (st.size < f.offset) f.offset = 0;
        if (st.size == f.offset) return &.{};
        const want: usize = @intCast(@min(st.size - f.offset, max_read));
        const buf = try a.alloc(u8, want);
        const n = file.readPositionalAll(io, buf, f.offset) catch return &.{};
        const text = buf[0..n];
        const end = std.mem.lastIndexOfScalar(u8, text, '\n') orelse {
            // No complete line yet. One longer than a whole read is not
            // a line anybody will finish: skip it rather than wedge.
            if (n == max_read) f.offset += n;
            return &.{};
        };
        f.offset += end + 1;
        return f.take(a, text[0 .. end + 1], now_ms);
    }

    /// Parse and coalesce complete lines. Public for the tests.
    pub fn take(f: *FileFeed, a: Allocator, text: []const u8, now_ms: i64) Allocator.Error![]const Change {
        var out: std.ArrayList(Change) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const ev = parseLine(a, line) orelse continue;
            // Any well-formed line proves the writer is alive.
            f.last_line_ms = now_ms;
            if (ev.source.len > 0) {
                const n = @min(ev.source.len, f.source_buf.len);
                @memcpy(f.source_buf[0..n], ev.source[0..n]);
                f.source_len = n;
            }
            const kind = ev.kind orelse continue;
            if (kind != f.kind or ev.key.len == 0) continue;
            f.events += 1;
            const seen = for (out.items) |*c| {
                if (std.mem.eql(u8, c.key, ev.key)) break c;
            } else null;
            if (seen) |c| {
                c.at = @max(c.at, ev.at);
            } else try out.append(a, .{ .key = ev.key, .at = ev.at });
        }
        return out.items;
    }
};

/// One line of the file, read. `kind` null: a heartbeat, or a kind
/// this SDK does not know — liveness, and nothing to fetch.
pub const Line = struct {
    kind: ?Kind,
    key: []const u8 = "",
    at: f64 = 0,
    source: []const u8 = "",
};

/// `{"kind":…,"key":…,"at":…,"source":…}`, or null for a line that is
/// not one (not JSON, not an object, no string `kind`, a key that is
/// too long or carries a control byte).
pub fn parseLine(a: Allocator, line: []const u8) ?Line {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const kind_s = switch (o.get("kind") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    var out: Line = .{ .kind = std.meta.stringToEnum(Kind, kind_s) };
    if (o.get("source")) |s| if (s == .string) {
        out.source = s.string;
    };
    if (o.get("at")) |at| out.at = switch (at) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => 0,
    };
    if (out.kind != null) {
        const key = switch (o.get("key") orelse return null) {
            .string => |s| std.mem.trim(u8, s, " \t"),
            else => return null,
        };
        if (key.len == 0 or key.len > max_key_len) return null;
        for (key) |c| if (c < 0x20 or c == 0x7f) return null;
        out.key = key;
    }
    return out;
}

// ─── the two together ────────────────────────────────────────────────────

/// Which source is answering, for the chip.
pub const Mode = enum {
    /// No feed configured: adaptive polling.
    poll,
    /// The feed file is live: its events, and a slow safety sweep.
    feed,
    /// A feed is configured and missing or quiet: adaptive polling, and
    /// the hover says why.
    degraded,
};

/// What the budget chip reads about the seam — plain numbers, copied
/// into the budget's snapshot.
pub const State = struct {
    mode: Mode = .poll,
    /// The poll interval in force, seconds; 0 with polling off.
    interval_secs: u32 = 0,
    base_secs: u32 = 0,
    max_secs: u32 = 0,
    /// Unchanged polls in a row.
    quiet_polls: u32 = 0,
    /// Degraded: why — the file is missing, or quiet this long.
    feed_missing: bool = false,
    feed_quiet_secs: i64 = 0,
    feed_events: u64 = 0,
    /// Set by `Watcher.state`; describes the file for the hover.
    configured: bool = false,
};

/// The seam a pane holds: the poller, and the file when one is
/// configured. `look` answers for both.
pub const Watcher = struct {
    poll: PollFeed,
    file: ?FileFeed = null,
    sweep_ms: i64 = 600_000,
    /// The poll interval before the file took over, restored when it
    /// dies.
    was_live: bool = false,

    /// `base_secs`/`max_secs` are the poller's; `cfg` the feed block,
    /// its `file` already resolved to a path (`resolvePath`) or empty.
    pub fn init(io: Io, kind: Kind, base_secs: u32, max_secs: u32, cfg: Config, file_path: []const u8) Watcher {
        var w: Watcher = .{ .poll = .init(base_secs, max_secs), .sweep_ms = @as(i64, @max(cfg.sweep_secs, 1)) * 1000 };
        if (file_path.len > 0) w.file = .init(io, file_path, kind, cfg.stale_secs);
        return w;
    }

    pub fn mode(w: *const Watcher, now_ms: i64) Mode {
        const f = &(w.file orelse return .poll);
        return if (f.status(now_ms) == .live) .feed else .degraded;
    }

    /// Both sources, once. The file first, so its liveness decides the
    /// poller's pace for the same look.
    pub fn look(w: *Watcher, a: Allocator, now_ms: i64) Allocator.Error!Look {
        var out: Look = .{};
        if (w.file) |*f| {
            out.changed = try f.look(a, now_ms);
            const live = f.status(now_ms) == .live;
            if (live) {
                w.poll.schedule.override_ms = w.sweep_ms;
            } else {
                w.poll.schedule.override_ms = null;
                // Coming back from the feed to polling: start at the
                // base, not wherever the interval was left.
                if (w.was_live) w.poll.schedule.touch();
            }
            w.was_live = live;
        }
        out.sweep = w.poll.look(now_ms).sweep;
        return out;
    }

    /// The listing refresh the poller asked for went out.
    pub fn started(w: *Watcher, now_ms: i64) void {
        w.poll.schedule.started(now_ms);
    }

    pub fn settled(w: *Watcher, changed: bool) void {
        w.poll.schedule.settled(changed);
    }

    pub fn touch(w: *Watcher) void {
        w.poll.schedule.touch();
    }

    pub fn state(w: *const Watcher, now_ms: i64) State {
        const s = &w.poll.schedule;
        var out: State = .{
            .mode = w.mode(now_ms),
            .interval_secs = if (s.enabled()) s.intervalSecs() else 0,
            .base_secs = @intCast(@divFloor(s.base_ms, 1000)),
            .max_secs = @intCast(@divFloor(s.max_ms, 1000)),
            .quiet_polls = s.quiet,
        };
        if (w.file) |*f| {
            out.configured = true;
            out.feed_missing = f.missing;
            out.feed_quiet_secs = f.quietSecs(now_ms);
            out.feed_events = f.events;
        }
        return out;
    }
};

/// A configured path as a file path: `~/` is `$HOME` (`USERPROFILE` on
/// Windows), a relative path is taken against `base_dir` (the config
/// file's directory), an absolute one is itself. Empty stays empty.
pub fn resolvePath(a: Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, p_in: []const u8) Allocator.Error![]const u8 {
    const p = std.mem.trim(u8, p_in, " \t");
    if (p.len == 0) return "";
    if (std.mem.startsWith(u8, p, "~/") or std.mem.eql(u8, p, "~")) {
        const home = env.get("HOME") orelse env.get("USERPROFILE") orelse "";
        if (home.len > 0) return std.fs.path.join(a, &.{ home, if (p.len > 2) p[2..] else "" });
    }
    if (std.fs.path.isAbsolute(p) or base_dir.len == 0) return a.dupe(u8, p);
    return std.fs.path.join(a, &.{ base_dir, p });
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the schedule backs off geometrically on quiet polls, to the cap, and snaps back on a change or a touch" {
    var s: Schedule = .init(5, 120);
    try t.expect(!s.due(10_000)); // never before the first poll
    s.started(1_000);
    try t.expect(!s.due(5_999));
    try t.expect(s.due(6_000));
    // 5 → 10 → 20 → 40 → 80 → 120 → 120.
    const want = [_]u32{ 10, 20, 40, 80, 120, 120 };
    for (want) |w| {
        s.settled(false);
        try t.expectEqual(w, s.intervalSecs());
    }
    try t.expect(s.backedOff());
    try t.expectEqual(@as(u32, 6), s.quiet);
    // The due time follows the interval in force.
    s.started(100_000);
    try t.expect(!s.due(100_000 + 119_999));
    try t.expect(s.due(100_000 + 120_000));
    // A change: back to the base.
    s.settled(true);
    try t.expectEqual(@as(u32, 5), s.intervalSecs());
    try t.expectEqual(@as(u32, 0), s.quiet);
    // A touch after backing off: back to the base, due five seconds
    // after the last poll — which may already be now.
    s.settled(false);
    s.settled(false);
    try t.expectEqual(@as(u32, 20), s.intervalSecs());
    s.started(200_000);
    try t.expect(!s.due(210_000));
    s.touch();
    try t.expect(s.due(210_000));
    // No cap above the base: fixed.
    var fixed: Schedule = .init(60, 0);
    fixed.settled(false);
    try t.expectEqual(@as(u32, 60), fixed.intervalSecs());
    // Off is off.
    var off: Schedule = .init(0, 120);
    off.started(1);
    try t.expect(!off.due(1_000_000));
    off.settled(false);
    try t.expectEqual(@as(u32, 0), off.intervalSecs());
}

test "an override pace wins over the adaptive one and leaves it where it was" {
    var s: Schedule = .init(5, 120);
    s.started(1_000);
    s.settled(false);
    s.override_ms = 600_000;
    try t.expectEqual(@as(u32, 600), s.intervalSecs());
    try t.expect(!s.due(1_000 + 10_000));
    try t.expect(!s.backedOff());
    s.override_ms = null;
    try t.expectEqual(@as(u32, 10), s.intervalSecs());
}

test "PollFeed and FileFeed answer through the same interface" {
    var pf: PollFeed = .init(5, 60);
    pf.schedule.started(1);
    const f = pf.feed();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expect(!(try f.look(arena.allocator(), 2)).sweep);
    try t.expect((try f.look(arena.allocator(), 5_001)).sweep);
}

test "a line is read for its kind, key, time and source; anything else is not a line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pr = parseLine(a, "{\"kind\":\"pr\",\"key\":\"api#1234\",\"at\":1790000000,\"source\":\"relay\"}").?;
    try t.expectEqual(Kind.pr, pr.kind.?);
    try t.expectEqualStrings("api#1234", pr.key);
    try t.expectEqual(@as(f64, 1790000000), pr.at);
    try t.expectEqualStrings("relay", pr.source);
    const iss = parseLine(a, "{\"kind\":\"issue\",\"key\":\"ENG-2\",\"at\":1790000000.5}").?;
    try t.expectEqual(Kind.issue, iss.kind.?);
    try t.expectEqual(@as(f64, 1790000000.5), iss.at);
    // A heartbeat, and a kind from the future, are liveness only.
    try t.expectEqual(@as(?Kind, null), parseLine(a, "{\"kind\":\"heartbeat\",\"at\":1}").?.kind);
    try t.expectEqual(@as(?Kind, null), parseLine(a, "{\"kind\":\"build\",\"key\":\"x\"}").?.kind);
    // Not lines.
    try t.expect(parseLine(a, "not json") == null);
    try t.expect(parseLine(a, "[1,2]") == null);
    try t.expect(parseLine(a, "{\"key\":\"api#1\"}") == null);
    try t.expect(parseLine(a, "{\"kind\":\"pr\"}") == null);
    try t.expect(parseLine(a, "{\"kind\":\"pr\",\"key\":\"\"}") == null);
    try t.expect(parseLine(a, "{\"kind\":\"pr\",\"key\":\"a\\u0007b\"}") == null);
}

fn appendTo(dir: Io.Dir, name: []const u8, text: []const u8) !void {
    const file = try dir.createFile(t.io, name, .{ .truncate = false });
    defer file.close(t.io);
    const end = try file.length(t.io);
    try file.writePositionalAll(t.io, text, end);
}

fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8, name: []const u8) ![]const u8 {
    var root: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &root);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root[0..n], name });
}

test "the file feed skips history, reads complete lines by offset, coalesces by key, and restarts after a truncation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [1100]u8 = undefined;
    const p = try tmpPath(&tmp, &pbuf, "feed.jsonl");
    try appendTo(tmp.dir, "feed.jsonl", "{\"kind\":\"pr\",\"key\":\"old#1\",\"at\":1}\n");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = Io.Timestamp.now(t.io, .real).toMilliseconds();

    var f: FileFeed = .init(t.io, p, .pr, 300);
    // The first look is the end of the file: what was there is history.
    try t.expectEqual(@as(usize, 0), (try f.look(a, now)).len);
    try t.expectEqual(FileFeed.Status.live, f.status(now));

    // Three lines about two PRs, an issue (not this pane's), and half a
    // fourth line with no newline yet.
    try appendTo(tmp.dir, "feed.jsonl",
        \\{"kind":"pr","key":"api#12","at":10,"source":"relay"}
        \\{"kind":"issue","key":"ENG-1","at":11}
        \\{"kind":"pr","key":"web#3","at":12}
        \\{"kind":"pr","key":"api#12","at":13}
        \\{"kind":"pr","key":"api#
    );
    const got = try f.look(a, now + 1);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("api#12", got[0].key);
    try t.expectEqual(@as(f64, 13), got[0].at);
    try t.expectEqualStrings("web#3", got[1].key);
    try t.expectEqualStrings("relay", f.source());
    try t.expectEqual(@as(u64, 3), f.events);
    // Nothing new: nothing.
    try t.expectEqual(@as(usize, 0), (try f.look(a, now + 2)).len);
    // The half line is finished: it arrives whole, once.
    try appendTo(tmp.dir, "feed.jsonl", "99\",\"at\":14}\n");
    const tail = try f.look(a, now + 3);
    try t.expectEqual(@as(usize, 1), tail.len);
    try t.expectEqualStrings("api#99", tail[0].key);

    // Truncated and rewritten: read from the start.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "feed.jsonl", .data = "{\"kind\":\"pr\",\"key\":\"api#5\",\"at\":1}\n" });
    const again = try f.look(a, now + 4);
    try t.expectEqual(@as(usize, 1), again.len);
    try t.expectEqualStrings("api#5", again[0].key);
}

test "the file feed goes stale when nobody writes, comes back on a heartbeat, and is missing when the file is" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [1100]u8 = undefined;
    const p = try tmpPath(&tmp, &pbuf, "feed.jsonl");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var f: FileFeed = .init(t.io, p, .issue, 60);
    // No file yet.
    _ = try f.look(a, 1_000);
    try t.expectEqual(FileFeed.Status.missing, f.status(1_000));
    // It appears: everything in it is news, and it is live.
    try appendTo(tmp.dir, "feed.jsonl", "{\"kind\":\"issue\",\"key\":\"ENG-7\",\"at\":1}\n");
    const now = Io.Timestamp.now(t.io, .real).toMilliseconds();
    const first = try f.look(a, now);
    try t.expectEqual(@as(usize, 1), first.len);
    try t.expectEqual(FileFeed.Status.live, f.status(now));
    // A minute and a second of silence: stale.
    try t.expectEqual(FileFeed.Status.stale, f.status(now + 61_000));
    try t.expectEqual(@as(i64, 61), f.quietSecs(now + 61_000));
    // A heartbeat is a line: live again, and nothing to fetch.
    try appendTo(tmp.dir, "feed.jsonl", "{\"kind\":\"heartbeat\",\"at\":2,\"source\":\"gw\"}\n");
    try t.expectEqual(@as(usize, 0), (try f.look(a, now + 61_000)).len);
    try t.expectEqual(FileFeed.Status.live, f.status(now + 61_000));
    // Garbage is not a heartbeat.
    try appendTo(tmp.dir, "feed.jsonl", "garbage\n");
    _ = try f.look(a, now + 200_000);
    try t.expectEqual(FileFeed.Status.stale, f.status(now + 200_000));
    // Gone: missing.
    try tmp.dir.deleteFile(t.io, "feed.jsonl");
    _ = try f.look(a, now + 200_001);
    try t.expectEqual(FileFeed.Status.missing, f.status(now + 200_001));

    // A file whose last write is older than the window is stale from the
    // first look, not for the first `stale_secs`.
    try appendTo(tmp.dir, "old.jsonl", "{\"kind\":\"heartbeat\"}\n");
    var obuf: [1100]u8 = undefined;
    var old: FileFeed = .init(t.io, try tmpPath(&tmp, &obuf, "old.jsonl"), .issue, 60);
    const later = Io.Timestamp.now(t.io, .real).toMilliseconds() + 3_600_000;
    _ = try old.look(a, later);
    try t.expectEqual(FileFeed.Status.stale, old.status(later));
}

test "the watcher: a live feed slows the poller to the sweep, a dead one degrades to adaptive polling from the base" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [1100]u8 = undefined;
    const p = try tmpPath(&tmp, &pbuf, "feed.jsonl");
    try appendTo(tmp.dir, "feed.jsonl", "{\"kind\":\"heartbeat\"}\n");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = Io.Timestamp.now(t.io, .real).toMilliseconds();

    var w: Watcher = .init(t.io, .pr, 5, 120, .{ .stale_secs = 60, .sweep_secs = 600 }, p);
    w.started(now);
    var look = try w.look(a, now);
    try t.expectEqual(Mode.feed, w.mode(now));
    try t.expect(!look.sweep);
    try t.expectEqual(@as(u32, 600), w.state(now).interval_secs);
    // Ten seconds in: a poller at the base would be due; the sweep is not.
    look = try w.look(a, now + 10_000);
    try t.expect(!look.sweep);
    // An event: the key, and still no sweep.
    try appendTo(tmp.dir, "feed.jsonl", "{\"kind\":\"pr\",\"key\":\"api#1\",\"at\":1}\n");
    look = try w.look(a, now + 11_000);
    try t.expectEqual(@as(usize, 1), look.changed.len);
    try t.expect(!look.sweep);
    // Silence past the window: degraded, the base interval, a poll due.
    look = try w.look(a, now + 11_000 + 61_000);
    try t.expectEqual(Mode.degraded, w.mode(now + 72_000));
    try t.expect(look.sweep);
    const st = w.state(now + 72_000);
    try t.expectEqual(@as(u32, 5), st.interval_secs);
    try t.expect(st.configured and !st.feed_missing);
    try t.expectEqual(@as(i64, 61), st.feed_quiet_secs);
    // The file goes: degraded, and says it is missing.
    try tmp.dir.deleteFile(t.io, "feed.jsonl");
    _ = try w.look(a, now + 80_000);
    try t.expect(w.state(now + 80_000).feed_missing);
    // No file configured at all: plain polling.
    var plain: Watcher = .init(t.io, .pr, 5, 120, .{}, "");
    try t.expectEqual(Mode.poll, plain.mode(now));
}

test "a configured path: home, relative to the config's directory, absolute, empty" {
    // The separators below are POSIX ones.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/me");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/home/me/feeds/bb.jsonl", try resolvePath(a, &env, "/cfg", "~/feeds/bb.jsonl"));
    try t.expectEqualStrings("/cfg/feed.jsonl", try resolvePath(a, &env, "/cfg", "feed.jsonl"));
    try t.expectEqualStrings("/abs/feed.jsonl", try resolvePath(a, &env, "/cfg", "/abs/feed.jsonl"));
    try t.expectEqualStrings("", try resolvePath(a, &env, "/cfg", "  "));
}
