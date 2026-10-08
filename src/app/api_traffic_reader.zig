//! The API TRAFFIC reader: who is spending an API's budget, read out of
//! the files every process on the machine already writes. No network,
//! no App — `api_traffic.zig` runs it on a worker on the dashboard
//! cadence and hands the view the `Snapshot` it builds.
//!
//! Three files per service, all documented contracts (`docs/SDK.md`):
//!
//!   * `<interop dir>/<service>-draws.jsonl` (and its `.1`): one line per
//!     token drawn from the shared bucket, by ANY process — mnml's
//!     panes, the statusline poller, the fleet's Python loops. This is
//!     the cross-process signal, so when it exists it is the source the
//!     Timeline and the Who table count.
//!   * `<data root>/requests/<service>.jsonl` (and `<service>.1.jsonl`):
//!     mnml's own request log — the statuses (`304`, `429`) and cache
//!     hits the draws file cannot say. With no draws file at all, it is
//!     the source instead (its lines that reached the wire).
//!   * `<interop dir>/<service>-ratelimit.json`: the six-key bucket —
//!     and, for a service whose limit is counted per token, one more
//!     per token, `<service>-ratelimit-<id>.json` beside it. A draw out
//!     of one of those names its `token_id`.
//!
//! Both logs are tailed by byte offset, complete lines only (the
//! feed's and the IPC reader's rule). A file smaller than the offset
//! was rotated: the rest of the old generation is read out of `.1`
//! from the old offset, then the new file from its start. The `.1`
//! generation is read whole once, on the first look. What is kept is a
//! bounded window — `keep_secs` (7 days) and at most `max_events` lines
//! per log — so a machine that has been up for a month costs the same
//! as one that started this morning.
//!
//!   D1  every string the snapshot holds lives on the snapshot's own
//!       arena; nothing points into the reader's tables, which the next
//!       look may grow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

/// How far back anything is kept: the widest window the pane offers.
pub const keep_secs: f64 = 7 * 86400;
/// Lines kept per log per service, oldest dropped first.
pub const max_events: usize = 50_000;
/// The most one look reads from one file. The logs rotate at 4 MB, so
/// this is a whole generation with room to spare.
pub const max_read: usize = 8 * 1024 * 1024;
/// Series the timeline draws one colour each for; the rest are `other`.
pub const max_series: usize = 7;
/// Reasons a Who row keeps for its hover.
pub const max_reasons: usize = 8;
/// Pids a Who row keeps.
pub const max_pids: usize = 8;
/// Bucket files a service shows: the shared one and the tokens'.
pub const max_buckets: usize = 8;

/// The windows the pane offers: the header, the timeline and the Who
/// table all read the selected one.
pub const Window = enum(u8) {
    hour,
    day,
    week,

    pub const all = [_]Window{ .hour, .day, .week };

    pub fn secs(w: Window) u32 {
        return switch (w) {
            .hour => 3600,
            .day => 86400,
            .week => 7 * 86400,
        };
    }

    /// One bucket per minute for the hour and the day; ten minutes for
    /// the week, which would otherwise be ten thousand buckets for a
    /// strip a hundred cells wide.
    pub fn bucketSecs(w: Window) u32 {
        return switch (w) {
            .hour, .day => 60,
            .week => 600,
        };
    }

    pub fn buckets(w: Window) usize {
        return w.secs() / w.bucketSecs();
    }

    pub fn label(w: Window) []const u8 {
        return switch (w) {
            .hour => "1h",
            .day => "24h",
            .week => "7d",
        };
    }

    pub fn next(w: Window) Window {
        return switch (w) {
            .hour => .day,
            .day => .week,
            .week => .hour,
        };
    }
};

/// Which log the Timeline and the Who table count.
pub const Source = enum {
    /// `<service>-draws.jsonl`: every process on the machine.
    draws,
    /// mnml's own request log, because no draws file exists.
    requests,
    /// Neither has a line.
    none,
};

/// One line of either log, compact. Strings are interned per service.
pub const Event = struct {
    ts: f64,
    pid: i32 = 0,
    program: u16 = 0,
    reason: u16 = 0,
    wait_ms: u32 = 0,
    /// The request log's status; 0 for none (a failure, a draw line).
    status: u16 = 0,
    /// The draw's `token_id`, interned; `no_token` for a draw out of
    /// the shared bucket (and every request-log line).
    token: u16 = no_token,
    /// The request log only: a line that never reached the wire (a
    /// `cache_hit`, a dry run).
    off_wire: bool = false,
    cache_hit: bool = false,
};

/// `Event.token` for a draw that names no token of its own.
pub const no_token: u16 = std.math.maxInt(u16);

/// A `token_id` as the SDK writes one: `token_id_len` lowercase hex.
pub fn validTokenId(id: []const u8) bool {
    if (id.len != sdk.ratelimit.token_id_len) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Strings seen in one service's logs, each kept once. A program that
/// shows up ten thousand times is one entry here and a `u16` per line.
pub const Names = struct {
    list: std.ArrayListUnmanaged([]u8) = .empty,
    map: std.StringHashMapUnmanaged(u16) = .empty,

    /// Past this many distinct strings everything new is `other`: a
    /// log full of unique programs is a broken writer, not a machine.
    pub const cap: usize = 4096;

    pub fn deinit(n: *Names, gpa: Allocator) void {
        for (n.list.items) |s| gpa.free(s);
        n.list.deinit(gpa);
        n.map.deinit(gpa);
    }

    pub fn intern(n: *Names, gpa: Allocator, name: []const u8) Allocator.Error!u16 {
        if (n.map.get(name)) |id| return id;
        // Full: everything new is `other`, which gets the one slot past
        // the cap the first time it is needed — never a second lookup
        // of a name that is not there yet.
        const s = if (n.list.items.len >= cap) "other" else name;
        if (n.map.get(s)) |id| return id;
        const owned = try gpa.dupe(u8, s);
        errdefer gpa.free(owned);
        const id: u16 = @intCast(n.list.items.len);
        try n.list.append(gpa, owned);
        try n.map.put(gpa, owned, id);
        return id;
    }

    pub fn get(n: *const Names, id: u16) []const u8 {
        if (id >= n.list.items.len) return "";
        return n.list.items[id];
    }
};

/// One log, tailed by byte offset.
pub const Tail = struct {
    /// The live file. Owned.
    path: []u8 = &.{},
    /// The rotated generation. Owned.
    older: []u8 = &.{},
    offset: u64 = 0,
    started: bool = false,
    /// Some generation of this log has existed at some look.
    seen: bool = false,

    pub fn deinit(tl: *Tail, gpa: Allocator) void {
        gpa.free(tl.path);
        gpa.free(tl.older);
        tl.* = .{};
    }

    /// Every complete line written since the last look, oldest first,
    /// handed to `sink.line`. A missing file is no lines; a file that
    /// comes back is read from its first byte.
    pub fn look(tl: *Tail, io: Io, gpa: Allocator, sink: anytype) Allocator.Error!void {
        if (!tl.started) {
            tl.started = true;
            tl.offset = 0;
            // The older generation, once and whole: it is the start of
            // the window, and nothing will ever be appended to it.
            if (readFrom(io, gpa, tl.older, 0)) |text| {
                defer gpa.free(text);
                tl.seen = true;
                try feedLines(text, sink);
            }
        }
        const file = Io.Dir.cwd().openFile(io, tl.path, .{}) catch {
            tl.offset = 0;
            return;
        };
        defer file.close(io);
        tl.seen = true;
        const size = file.length(io) catch return;
        if (size < tl.offset) {
            // Rotated since the last look: what was appended after our
            // offset went over with the old file into `.1`.
            if (readFrom(io, gpa, tl.older, tl.offset)) |text| {
                defer gpa.free(text);
                try feedLines(text, sink);
            }
            tl.offset = 0;
        }
        if (size == tl.offset) return;
        const want: usize = @intCast(@min(size - tl.offset, max_read));
        const buf = try gpa.alloc(u8, want);
        defer gpa.free(buf);
        const n = file.readPositionalAll(io, buf, tl.offset) catch return;
        const text = buf[0..n];
        const end = std.mem.lastIndexOfScalar(u8, text, '\n') orelse {
            // A line longer than a whole read is not one anybody will
            // finish: skip it rather than wedge on it.
            if (n == max_read) tl.offset += n;
            return;
        };
        tl.offset += end + 1;
        try feedLines(text[0 .. end + 1], sink);
    }
};

/// The bytes of `path` from `from` to its end, complete lines or not.
/// Null for a missing file or one shorter than `from`.
fn readFrom(io: Io, gpa: Allocator, path: []const u8, from: u64) ?[]u8 {
    if (path.len == 0) return null;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const size = file.length(io) catch return null;
    if (size <= from) return null;
    const want: usize = @intCast(@min(size - from, max_read));
    const buf = gpa.alloc(u8, want) catch return null;
    const n = file.readPositionalAll(io, buf, from) catch {
        gpa.free(buf);
        return null;
    };
    if (n < buf.len) {
        // Shrunk under us: keep what came back.
        const out = gpa.realloc(buf, n) catch return buf[0..n];
        return out;
    }
    return buf;
}

fn feedLines(text: []const u8, sink: anytype) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 2 or line[0] != '{') continue;
        try sink.line(line);
    }
}

// ─── the two line shapes ─────────────────────────────────────────────────

/// `"key":<number>` out of one line, `"key": <number>` too — a Python
/// writer puts a space after the colon.
pub fn jsonNumber(line: []const u8, key: []const u8) ?f64 {
    const rest = valueAfter(line, key) orelse return null;
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.' or rest[end] == '-' or rest[end] == 'e' or rest[end] == 'E' or rest[end] == '+')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// `"key":"…"`, escapes left as written.
pub fn jsonString(line: []const u8, key: []const u8) ?[]const u8 {
    const rest = valueAfter(line, key) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '\\') {
            i += 1;
            continue;
        }
        if (rest[i] == '"') return rest[1..i];
    }
    return null;
}

fn valueAfter(line: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [40]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, needle)) |at| {
        var i = at + needle.len;
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i < line.len and line[i] == ':') {
            i += 1;
            while (i < line.len and line[i] == ' ') : (i += 1) {}
            return line[i..];
        }
        from = at + 1;
    }
    return null;
}

// ─── numbers out of a file anybody can write ─────────────────────────────
//
// Every number below came out of a file another program wrote, so none
// of them is trusted: a float becomes an integer only through one of
// these, which reject NaN and infinity and saturate instead of trapping.

fn clampU32(v: f64) u32 {
    if (!(v > 0)) return 0;
    if (v >= 4_294_967_295) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// The latest stamp the reader places: 2100-01-01. Far past any clock
/// skew between two processes, near enough that a bucket index or a
/// clock label always fits its integer.
pub const max_ts: f64 = 4_102_444_800;

/// How far ahead of the clock a line may be stamped and still be kept:
/// another process's clock can run fast, not a day fast.
pub const future_secs: f64 = 86400;

/// A stamp read from a file, or null for one the reader cannot place:
/// not finite, negative, or past `max_ts`.
pub fn saneTs(v: f64) ?f64 {
    if (!std.math.isFinite(v) or v < 0 or v > max_ts) return null;
    return v;
}

/// Whole seconds of a span: NaN and negatives are 0, anything past
/// 10^15 (thirty million years) is 10^15.
pub fn wholeSecs(v: f64) u64 {
    if (!(v > 0)) return 0;
    if (v >= 1e15) return 1_000_000_000_000_000;
    return @intFromFloat(v);
}

/// `@floor(v)` as an i64, clamped to ±10^15; NaN is 0.
pub fn floorI64(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(std.math.clamp(@floor(v), -1e15, 1e15));
}

/// `v` inside `[lo, hi]`; NaN is `lo`.
pub fn clampF(v: f64, lo: f64, hi: f64) f64 {
    if (std.math.isNan(v)) return lo;
    return std.math.clamp(v, lo, hi);
}

// ─── one service ─────────────────────────────────────────────────────────

pub const ServiceReader = struct {
    /// Owned.
    service: []u8,
    draws: Tail = .{},
    requests: Tail = .{},
    draw_events: std.ArrayListUnmanaged(Event) = .empty,
    req_events: std.ArrayListUnmanaged(Event) = .empty,
    /// Every 429 on the machine for this API: the fleet's throttles
    /// file, and mnml's own request log's 429s folded in. `program` is
    /// the caller.
    throttles: std.ArrayListUnmanaged(Event) = .empty,
    /// The 429s this look found that were not there at the last one —
    /// empty on the reader's first look, which reads history, not news.
    fresh: std.ArrayListUnmanaged(Event) = .empty,
    names: Names = .{},

    pub fn deinit(s: *ServiceReader, gpa: Allocator) void {
        gpa.free(s.service);
        s.draws.deinit(gpa);
        s.requests.deinit(gpa);
        s.draw_events.deinit(gpa);
        s.req_events.deinit(gpa);
        s.throttles.deinit(gpa);
        s.fresh.deinit(gpa);
        s.names.deinit(gpa);
    }

    /// One 429 for this API, by `caller`; news when `fresh`.
    pub fn noteThrottle(s: *ServiceReader, gpa: Allocator, ts: f64, caller: []const u8, fresh: bool) Allocator.Error!void {
        const ev: Event = .{ .ts = ts, .program = try s.names.intern(gpa, caller), .status = 429 };
        try s.throttles.append(gpa, ev);
        if (fresh) try s.fresh.append(gpa, ev);
    }

    const DrawSink = struct {
        s: *ServiceReader,
        gpa: Allocator,
        fn line(k: DrawSink, l: []const u8) Allocator.Error!void {
            const ts = saneTs(jsonNumber(l, "ts") orelse return) orelse return;
            try k.s.draw_events.append(k.gpa, .{
                .ts = ts,
                .pid = @intCast(@min(clampU32(jsonNumber(l, "pid") orelse 0), std.math.maxInt(i32))),
                .program = try k.s.names.intern(k.gpa, jsonString(l, "program") orelse "unknown"),
                .reason = try k.s.names.intern(k.gpa, jsonString(l, "reason") orelse ""),
                .wait_ms = clampU32(jsonNumber(l, "wait_ms") orelse 0),
                .token = if (jsonString(l, "token_id")) |id| (if (validTokenId(id)) try k.s.names.intern(k.gpa, id) else no_token) else no_token,
            });
        }
    };

    const ReqSink = struct {
        s: *ServiceReader,
        gpa: Allocator,
        /// Whether a 429 read now is news (`fresh`).
        news: bool,
        fn line(k: ReqSink, l: []const u8) Allocator.Error!void {
            const ts = saneTs(jsonNumber(l, "ts") orelse return) orelse return;
            if (jsonString(l, "path") == null) return;
            const reason = jsonString(l, "reason") orelse "";
            const cache = jsonString(l, "cache") orelse "none";
            const hit = std.mem.eql(u8, reason, "cache_hit");
            const dry = std.mem.indexOf(u8, l, "\"dry\":true") != null;
            const status = jsonNumber(l, "status");
            try k.s.req_events.append(k.gpa, .{
                .ts = ts,
                .program = try k.s.names.intern(k.gpa, jsonString(l, "integration") orelse "mnml"),
                .reason = try k.s.names.intern(k.gpa, reason),
                .wait_ms = clampU32(jsonNumber(l, "wait_ms") orelse 0),
                .status = if (status) |st| @intCast(@min(clampU32(st), std.math.maxInt(u16))) else 0,
                .off_wire = hit or dry,
                .cache_hit = hit or std.mem.eql(u8, cache, "hit"),
            });
            // mnml's own 429s: the fleet's throttles file is the rest
            // of the machine's, so the view is only whole with these.
            if (status) |st| if (st == 429) try k.s.noteThrottle(k.gpa, ts, jsonString(l, "integration") orelse "mnml", k.news);
        }
    };

    /// Read what both logs gained, then drop what fell out of the
    /// window. Lines arrive oldest first per file but not across the
    /// two generations' seam, so the lists are sorted once a look adds
    /// anything out of order.
    pub fn look(s: *ServiceReader, io: Io, gpa: Allocator, now: f64, news: bool) Allocator.Error!void {
        const d0 = s.draw_events.items.len;
        try s.draws.look(io, gpa, DrawSink{ .s = s, .gpa = gpa });
        settle(&s.draw_events, d0, now);
        const r0 = s.req_events.items.len;
        try s.requests.look(io, gpa, ReqSink{ .s = s, .gpa = gpa, .news = news });
        settle(&s.req_events, r0, now);
    }

    pub fn source(s: *const ServiceReader) Source {
        if (s.draws.seen) return .draws;
        if (s.req_events.items.len > 0) return .requests;
        return .none;
    }
};

fn byTs(_: void, a: Event, b: Event) bool {
    return a.ts < b.ts;
}

/// Keep `list` sorted, inside the window and under the cap. A line
/// stamped more than `future_secs` ahead is dropped too: it would
/// otherwise outlive every window.
fn settle(list: *std.ArrayListUnmanaged(Event), added_from: usize, now: f64) void {
    const items = list.items;
    if (items.len > added_from) {
        var sorted = true;
        var i: usize = @max(added_from, 1);
        while (i < items.len) : (i += 1) if (items[i].ts < items[i - 1].ts) {
            sorted = false;
            break;
        };
        if (!sorted) std.mem.sort(Event, items, {}, byTs);
    }
    // Oldest first, so the far future is a suffix and the cut a
    // prefix: the window's edge, or the cap, whichever removes more.
    var end = items.len;
    while (end > 0 and items[end - 1].ts - now > future_secs) : (end -= 1) {}
    var cut: usize = 0;
    while (cut < end and now - items[cut].ts > keep_secs) : (cut += 1) {}
    if (end - cut > max_events) cut = end - max_events;
    if (cut == 0 and end == items.len) return;
    std.mem.copyForwards(Event, items[0 .. end - cut], items[cut..end]);
    list.shrinkRetainingCapacity(end - cut);
}

// ─── where the files are ─────────────────────────────────────────────────

/// What the reader needs from the environment, resolved by the caller
/// (the App, on the main thread) and owned by the worker's job.
pub const Paths = struct {
    /// `<data root>`: the request logs and the budget's day tally.
    data_root: []const u8,
    /// The workspace, for the integration's own config (its `feed`).
    workspace: []const u8 = "",
    /// The environment the SDK resolves the interop directory from.
    env: *const std.process.Environ.Map,
};

/// `<data root>/requests/<service>.jsonl`, and its `.1` twin.
pub fn requestLogPaths(gpa: Allocator, data_root: []const u8, service: []const u8) Allocator.Error![2][]u8 {
    const live_name = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{service});
    defer gpa.free(live_name);
    const older_name = try std.fmt.allocPrint(gpa, "{s}.1.jsonl", .{service});
    defer gpa.free(older_name);
    const live = try std.fs.path.join(gpa, &.{ data_root, "requests", live_name });
    errdefer gpa.free(live);
    const older = try std.fs.path.join(gpa, &.{ data_root, "requests", older_name });
    return .{ live, older };
}

/// `<interop dir>/<service>-draws.jsonl`, and its `.1` twin — beside
/// the state file `ratelimit.statePath` resolves, exactly where the
/// limiter writes it.
pub fn drawsPaths(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error![2][]u8 {
    const state = try sdk.ratelimit.statePath(gpa, io, env, service);
    defer gpa.free(state);
    const dir = std.fs.path.dirname(state) orelse ".";
    const name = try std.fmt.allocPrint(gpa, "{s}-draws.jsonl", .{service});
    defer gpa.free(name);
    const live = try std.fs.path.join(gpa, &.{ dir, name });
    errdefer gpa.free(live);
    const older = try std.fmt.allocPrint(gpa, "{s}.1", .{live});
    return .{ live, older };
}

/// The services that have any of the files, the two mnml fronts first.
/// Listing two directories is the whole cost.
pub fn discover(gpa: Allocator, io: Io, paths: Paths, known: []const []const u8, out: *std.ArrayListUnmanaged([]u8)) Allocator.Error!void {
    for (known) |k| try addService(gpa, out, k);
    // The interop directory: every `<service>-draws.jsonl` and
    // `<service>-ratelimit.json` names a service somebody spends on.
    const probe = try sdk.ratelimit.statePath(gpa, io, paths.env, "probe");
    defer gpa.free(probe);
    if (std.fs.path.dirname(probe)) |dir| try scanDir(gpa, io, dir, &.{ "-draws.jsonl", "-draws.jsonl.1", "-ratelimit.json" }, out);
    const req_dir = try std.fs.path.join(gpa, &.{ paths.data_root, "requests" });
    defer gpa.free(req_dir);
    try scanDir(gpa, io, req_dir, &.{".jsonl"}, out);
}

fn scanDir(gpa: Allocator, io: Io, dir_path: []const u8, suffixes: []const []const u8, out: *std.ArrayListUnmanaged([]u8)) Allocator.Error!void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var seen: usize = 0;
    while (it.next(io) catch null) |entry| {
        seen += 1;
        // A directory with thousands of files is not an interop
        // directory anybody meant; stop looking rather than stall.
        if (seen > 2000) break;
        if (entry.kind != .file) continue;
        for (suffixes) |suf| {
            if (!std.mem.endsWith(u8, entry.name, suf)) continue;
            var name = entry.name[0 .. entry.name.len - suf.len];
            // `jira.1.jsonl` is jira's older generation.
            if (std.mem.endsWith(u8, name, ".1")) name = name[0 .. name.len - 2];
            if (validService(name)) try addService(gpa, out, name);
            break;
        }
    }
}

fn validService(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return !std.mem.eql(u8, name, "probe");
}

fn addService(gpa: Allocator, out: *std.ArrayListUnmanaged([]u8), name: []const u8) Allocator.Error!void {
    for (out.items) |s| if (std.mem.eql(u8, s, name)) return;
    try out.append(gpa, try gpa.dupe(u8, name));
}

// ─── the reader ──────────────────────────────────────────────────────────

pub const Reader = struct {
    services: std.ArrayListUnmanaged(ServiceReader) = .empty,
    /// `api-usage/<UTC day>.throttles.jsonl`, today's and yesterday's —
    /// a line written just before midnight lands in a file that is
    /// already yesterday's by the time it is read.
    throttle_files: std.ArrayListUnmanaged(ThrottleFile) = .empty,
    /// A look has completed: what the next one finds is news.
    looked: bool = false,

    pub fn deinit(r: *Reader, gpa: Allocator) void {
        for (r.services.items) |*s| s.deinit(gpa);
        r.services.deinit(gpa);
        for (r.throttle_files.items) |*f| f.tail.deinit(gpa);
        r.throttle_files.deinit(gpa);
    }

    /// The service named `name`, made when it has no entry yet — a
    /// throttles line can name an API no other file mentions.
    fn ensure(r: *Reader, io: Io, gpa: Allocator, paths: Paths, name: []const u8) Allocator.Error!*ServiceReader {
        if (r.find(name)) |s| return s;
        var s: ServiceReader = .{ .service = try gpa.dupe(u8, name) };
        errdefer s.deinit(gpa);
        const d = try drawsPaths(gpa, io, paths.env, name);
        s.draws.path = d[0];
        s.draws.older = d[1];
        const q = try requestLogPaths(gpa, paths.data_root, name);
        s.requests.path = q[0];
        s.requests.older = q[1];
        try r.services.append(gpa, s);
        return &r.services.items[r.services.items.len - 1];
    }

    pub fn find(r: *Reader, service: []const u8) ?*ServiceReader {
        for (r.services.items) |*s| if (std.mem.eql(u8, s.service, service)) return s;
        return null;
    }

    /// Find the services, then read what every log gained.
    pub fn look(r: *Reader, io: Io, gpa: Allocator, paths: Paths, known: []const []const u8, now: f64) Allocator.Error!void {
        var names: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        try discover(gpa, io, paths, known, &names);
        for (names.items) |name| _ = try r.ensure(io, gpa, paths, name);
        const news = r.looked;
        for (r.services.items) |*s| s.fresh.clearRetainingCapacity();
        for (r.services.items) |*s| try s.look(io, gpa, now, news);
        try r.lookThrottles(io, gpa, paths, now, news);
        for (r.services.items) |*s| settle(&s.throttles, 0, now);
        r.looked = true;
    }

    const ThrottleSink = struct {
        r: *Reader,
        io: Io,
        gpa: Allocator,
        paths: Paths,
        news: bool,
        fn line(k: ThrottleSink, l: []const u8) Allocator.Error!void {
            const th = parseThrottle(l) orelse return;
            if (!validService(th.api)) return;
            const s = try k.r.ensure(k.io, k.gpa, k.paths, th.api);
            try s.noteThrottle(k.gpa, th.ts, th.caller, k.news);
        }
    };

    fn lookThrottles(r: *Reader, io: Io, gpa: Allocator, paths: Paths, now: f64, news: bool) Allocator.Error!void {
        const today: i64 = floorI64(now / 86400);
        // Drop the days past yesterday; open today's and yesterday's.
        var i: usize = 0;
        while (i < r.throttle_files.items.len) {
            if (r.throttle_files.items[i].day < today - 1) {
                var gone = r.throttle_files.orderedRemove(i);
                gone.tail.deinit(gpa);
            } else i += 1;
        }
        const dir = (try throttlesDir(gpa, io, paths.env)) orelse return;
        defer gpa.free(dir);
        for ([_]i64{ today - 1, today }) |day| {
            var have = false;
            for (r.throttle_files.items) |f| have = have or f.day == day;
            if (have) continue;
            var date: [10]u8 = undefined;
            const name = try std.fmt.allocPrint(gpa, "{s}.throttles.jsonl", .{sdk.budget.isoDate(&date, day)});
            defer gpa.free(name);
            const path = try std.fs.path.join(gpa, &.{ dir, name });
            errdefer gpa.free(path);
            // Nothing rotates these: one file a day is the rotation.
            try r.throttle_files.append(gpa, .{ .day = day, .tail = .{ .path = path, .older = try gpa.dupe(u8, "") } });
        }
        for (r.throttle_files.items) |*f| try f.tail.look(io, gpa, ThrottleSink{ .r = r, .io = io, .gpa = gpa, .paths = paths, .news = news });
    }
};

pub const ThrottleFile = struct { day: i64, tail: Tail };

/// `<interop dir>/api-usage` — beside the shared buckets, wherever the
/// SDK resolves them. Owned; null when the directory cannot be named.
pub fn throttlesDir(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    const probe = try sdk.ratelimit.statePath(gpa, io, env, "probe");
    defer gpa.free(probe);
    const dir = std.fs.path.dirname(probe) orelse return null;
    return try std.fs.path.join(gpa, &.{ dir, "api-usage" });
}

/// The request the old Bitbucket test suite leaked into the file; it
/// was never a real 429.
pub const leakage_where = "api.bitbucket.org/2.0/x";

pub const Throttle = struct { ts: f64, api: []const u8, caller: []const u8 };

/// One throttles line, or null for one that is not a usable 429: no
/// stamp, no API, or the test leakage.
pub fn parseThrottle(l: []const u8) ?Throttle {
    if (jsonString(l, "where")) |w| if (std.mem.eql(u8, w, leakage_where)) return null;
    const raw = jsonNumber(l, "ts") orelse (if (jsonString(l, "ts")) |iso| parseIso(iso) else null) orelse return null;
    const ts = saneTs(raw) orelse return null;
    const api = jsonString(l, "api") orelse return null;
    return .{ .ts = ts, .api = api, .caller = jsonString(l, "caller") orelse "unknown" };
}

/// `2026-10-07T14:03:22Z`, `…22.418+00:00`, `…22-05:00` as epoch
/// seconds. Null for anything else.
pub fn parseIso(s: []const u8) ?f64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var frac: f64 = 0;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        const start = i;
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        frac = std.fmt.parseFloat(f64, s[start..i]) catch 0;
    }
    var offset: i64 = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-') and s.len >= i + 6) {
        const oh = std.fmt.parseInt(i64, s[i + 1 .. i + 3], 10) catch return null;
        const om = std.fmt.parseInt(i64, s[i + 4 .. i + 6], 10) catch return null;
        offset = (oh * 3600 + om * 60) * @as(i64, if (s[i] == '-') -1 else 1);
    }
    const days = sdk.request_log.daysFromCivil(y, mo, d);
    const secs = days * 86400 + h * 3600 + mi * 60 + se - offset;
    return @as(f64, @floatFromInt(secs)) + frac;
}

// ─── the snapshot the view paints ────────────────────────────────────────

pub const Bucket = struct {
    /// Tokens now: the file's, refilled to `now` at its rate.
    tokens: f64 = 0,
    capacity: f64 = 0,
    /// Tokens a second, as the file has it (a 429 cuts it).
    rate: f64 = 0,
    /// Seconds of cooldown left; 0 for none.
    cooldown_secs: f64 = 0,
    /// Seconds since the last 429; null for none on record.
    last_429_age: ?f64 = null,
    throttles: u32 = 0,
};

/// One bucket file of a service, as NOW shows it.
pub const BucketRow = struct {
    /// Empty for the shared `<service>-ratelimit.json`; else the token
    /// id its file is named by.
    token: []const u8 = "",
    /// The file's base name.
    file: []const u8 = "",
    bucket: Bucket = .{},
};

/// This hour's requests out of one bucket: the draws naming `token`,
/// or naming none for the shared one (`token` empty).
pub const HourRow = struct {
    token: []const u8 = "",
    requests: u32 = 0,
};

pub const BrokerWhere = enum { unknown, off, hosted, client };

pub const Broker = struct {
    where: BrokerWhere = .unknown,
    /// Queued per class: interactive, refresh, warm, batch.
    queue: [4]u32 = .{ 0, 0, 0, 0 },

    pub fn total(b: Broker) u32 {
        return b.queue[0] + b.queue[1] + b.queue[2] + b.queue[3];
    }
};

pub const FeedState = enum {
    /// The integration's config names no event file: it polls.
    polling,
    /// The file has a line or a heartbeat inside `stale_secs`.
    live,
    /// It has gone quiet past `stale_secs`: the pane is back to polling.
    stale,
    /// The config names a file that is not there.
    missing,
};

pub const Feed = struct {
    state: FeedState = .polling,
    /// Seconds since the file was last written; 0 when there is none.
    quiet_secs: f64 = 0,
    stale_secs: u32 = 300,
    /// The file the config names; empty when it names none.
    path: []const u8 = "",
};

pub const Now = struct {
    /// Every bucket file of the service, the shared one first, then the
    /// tokens' by id. Empty: no bucket file (or none that is one).
    buckets: []const BucketRow = &.{},
    /// Requests the source counts in the last hour, every program.
    hour_requests: u32 = 0,
    /// The same hour per bucket: one row per bucket file and per token
    /// the hour's draws name, the shared one first. Its limit is each
    /// bucket's own, because the limit is counted per token.
    hour_by: []const HourRow = &.{},
    /// The shared bucket's refill an hour — what an integration's
    /// `budget.hourly_budget` is set from (`rate_per_sec × 3600`).
    hourly_limit: u32 = 0,
    /// mnml's own day tally (`<data root>/budget/<service>.tally`).
    tally_today: ?u32 = null,
    broker: Broker = .{},
    feed: Feed = .{},
    /// Entries under `$MNML_SHARED_STATE_DIR/http-cache/<service>/`;
    /// null when there is no such directory.
    cache_entries: ?u32 = null,
    throttles: Throttles = .{},
};

/// The 429s for one API in a span: how many, the newest's age, and who
/// met them, the most first.
pub const Throttles = struct {
    n: u32 = 0,
    /// Seconds since the newest one; null with none.
    last_age: ?f64 = null,
    by: []const Reason = &.{},
};

/// `events` inside the last `span` seconds, counted by caller.
pub fn throttlesIn(arena: Allocator, gpa: Allocator, s: *const ServiceReader, events: []const Event, span: f64, now: f64) Allocator.Error!Throttles {
    var out: Throttles = .{};
    var counts: std.AutoArrayHashMapUnmanaged(u16, u32) = .empty;
    defer counts.deinit(gpa);
    var newest: f64 = 0;
    for (events) |e| {
        if (now - e.ts > span) continue;
        out.n += 1;
        newest = @max(newest, e.ts);
        const gop = try counts.getOrPut(gpa, e.program);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    if (out.n > 0) out.last_age = @max(now - newest, 0);
    const by = try arena.alloc(Reason, counts.count());
    for (counts.keys(), counts.values(), 0..) |k, v, i| by[i] = .{ .reason = try arena.dupe(u8, s.names.get(k)), .n = v };
    std.mem.sort(Reason, by, {}, struct {
        fn lt(_: void, a: Reason, b: Reason) bool {
            if (a.n != b.n) return a.n > b.n;
            return std.mem.order(u8, a.reason, b.reason) == .lt;
        }
    }.lt);
    out.by = by;
    return out;
}

pub const Reason = struct { reason: []const u8, n: u32 };

/// How many of `events` are stamped inside the last `span` seconds —
/// the same test `throttlesIn` counts by.
pub fn countWithin(events: []const Event, span: f64, now: f64) u32 {
    var n: u32 = 0;
    for (events) |e| {
        if (now - e.ts > span) continue;
        n +|= 1;
    }
    return n;
}

pub const WhoRow = struct {
    program: []const u8,
    /// mnml's own: `mnml-…`, or the request log's integration names.
    mnml: bool = false,
    requests: u32 = 0,
    /// Of the window's requests, 0…100.
    share_pct: f64 = 0,
    reasons: []const Reason = &.{},
    worst_wait_ms: u32 = 0,
    last_seen: f64 = 0,
    /// Distinct, newest first.
    pids: []const i32 = &.{},
    /// Its timeline series (and colour): `< max_series`, or
    /// `max_series` for `other`.
    series: u8 = 0,

    pub fn topReason(w: WhoRow) []const u8 {
        return if (w.reasons.len > 0) w.reasons[0].reason else "";
    }
};

pub const Series = struct {
    /// A program's name, or `other`.
    label: []const u8,
    mnml: bool = false,
};

pub const WinSnap = struct {
    window: Window = .hour,
    requests: u32 = 0,
    /// Of mnml's own requests that came back with a status, how many
    /// were `304`; null with no such request.
    not_modified_pct: ?f64 = null,
    throttled: u32 = 0,
    cache_hits: u32 = 0,
    /// The programs the strip stacks, busiest first, `other` last.
    series: []const Series = &.{},
    /// `buckets() × series.len`, bucket-major: bucket `b`'s count for
    /// series `s` is `counts[b * series.len + s]`.
    counts: []const u32 = &.{},
    /// Bucket 0's start, epoch seconds.
    start: f64 = 0,
    who: []const WhoRow = &.{},

    pub fn at(w: WinSnap, b: usize, s: usize) u32 {
        const i = b * w.series.len + s;
        return if (i < w.counts.len) w.counts[i] else 0;
    }

    pub fn total(w: WinSnap, b: usize) u32 {
        var n: u32 = 0;
        for (0..w.series.len) |s| n += w.at(b, s);
        return n;
    }
};

pub const ServiceSnap = struct {
    service: []const u8,
    source: Source = .none,
    now: Now = .{},
    /// 429s this look found that the last one had not: what a toast is
    /// about. Empty on the first look after start.
    fresh: u32 = 0,
    /// The last five minutes' 429s, by caller — the toast's words.
    last5: Throttles = .{},
    windows: [Window.all.len]WinSnap = .{ .{ .window = .hour }, .{ .window = .day }, .{ .window = .week } },

    pub fn win(s: *const ServiceSnap, w: Window) *const WinSnap {
        return &s.windows[@intFromEnum(w)];
    }
};

/// Whether a program is one of mnml's own: an integration mnml starts
/// names itself `mnml-<service>`, and this host `mnml-zig`.
pub fn isMnml(program: []const u8) bool {
    return std.mem.startsWith(u8, program, "mnml");
}

const PidAt = struct { pid: i32, ts: f64 };

/// One window of one service, on `arena`. `gpa` is scratch.
pub fn buildWindow(arena: Allocator, gpa: Allocator, s: *const ServiceReader, w: Window, now: f64) Allocator.Error!WinSnap {
    var out: WinSnap = .{ .window = w };
    const span: f64 = @floatFromInt(w.secs());
    const bsecs: f64 = @floatFromInt(w.bucketSecs());
    const nb = w.buckets();
    // Buckets on the wall clock's own boundaries, the last one holding
    // `now`: a minute is 14:07:00–14:08:00, never 14:07:23–14:08:23.
    const end = (@floor(now / bsecs) + 1) * bsecs;
    out.start = end - @as(f64, @floatFromInt(nb)) * bsecs;
    const cutoff = now - span;

    // mnml's own request log: the statuses and the cache.
    var with_status: u32 = 0;
    var not_modified: u32 = 0;
    for (s.req_events.items) |e| {
        if (e.ts < cutoff) continue;
        if (e.cache_hit) out.cache_hits += 1;
        if (e.off_wire) continue;
        if (e.status != 0) {
            with_status += 1;
            if (e.status == 304) not_modified += 1;
            if (e.status == 429) out.throttled += 1;
        }
    }
    if (with_status > 0) out.not_modified_pct = @as(f64, @floatFromInt(not_modified)) * 100.0 / @as(f64, @floatFromInt(with_status));

    const src = s.source();
    const events: []const Event = switch (src) {
        .draws => s.draw_events.items,
        .requests => s.req_events.items,
        .none => &.{},
    };

    // Per program: count, worst wait, last seen, reasons, pids.
    const n_names = s.names.list.items.len;
    const Acc = struct {
        n: u32 = 0,
        worst: u32 = 0,
        last: f64 = 0,
    };
    const acc = try gpa.alloc(Acc, n_names);
    defer gpa.free(acc);
    @memset(acc, .{});
    // reason counts, program-major: `n_names × n_names` would be large
    // for a log with many reasons; a map keyed by (program, reason)
    // stays proportional to what was seen.
    var reasons: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer reasons.deinit(gpa);
    var pids: std.AutoArrayHashMapUnmanaged(u64, f64) = .empty;
    defer pids.deinit(gpa);
    for (events) |e| {
        if (e.ts < cutoff) continue;
        if (src == .requests and e.off_wire) continue;
        out.requests += 1;
        const a = &acc[e.program];
        a.n += 1;
        a.worst = @max(a.worst, e.wait_ms);
        a.last = @max(a.last, e.ts);
        const rk = (@as(u32, e.program) << 16) | e.reason;
        const gop = try reasons.getOrPut(gpa, rk);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (e.pid != 0) {
            const pk = (@as(u64, e.program) << 32) | @as(u32, @bitCast(e.pid));
            const pg = try pids.getOrPut(gpa, pk);
            if (!pg.found_existing or pg.value_ptr.* < e.ts) pg.value_ptr.* = e.ts;
        }
    }

    // The Who rows, busiest first; ties by name so the order holds
    // still between two looks that changed nothing.
    var rows: std.ArrayListUnmanaged(WhoRow) = .empty;
    for (acc, 0..) |a, id| {
        if (a.n == 0) continue;
        const name = try arena.dupe(u8, s.names.get(@intCast(id)));
        try rows.append(arena, .{
            .program = name,
            .mnml = isMnml(name) or src == .requests,
            .requests = a.n,
            .share_pct = if (out.requests > 0) @as(f64, @floatFromInt(a.n)) * 100.0 / @as(f64, @floatFromInt(out.requests)) else 0,
            .worst_wait_ms = a.worst,
            .last_seen = a.last,
        });
    }
    std.mem.sort(WhoRow, rows.items, {}, struct {
        fn lt(_: void, a: WhoRow, b: WhoRow) bool {
            if (a.requests != b.requests) return a.requests > b.requests;
            return std.mem.order(u8, a.program, b.program) == .lt;
        }
    }.lt);

    // Each row's reasons and pids, and its series.
    const ids = try gpa.alloc(u16, rows.items.len);
    defer gpa.free(ids);
    for (rows.items, 0..) |*row, i| {
        const id = s.names.map.get(row.program) orelse 0;
        ids[i] = id;
        row.series = @intCast(@min(i, max_series));
        var rl: std.ArrayListUnmanaged(Reason) = .empty;
        var rit = reasons.iterator();
        while (rit.next()) |kv| {
            if ((kv.key_ptr.* >> 16) != id) continue;
            const reason_name = s.names.get(@intCast(kv.key_ptr.* & 0xffff));
            try rl.append(arena, .{ .reason = try arena.dupe(u8, if (reason_name.len == 0) "unspecified" else reason_name), .n = kv.value_ptr.* });
        }
        std.mem.sort(Reason, rl.items, {}, struct {
            fn lt(_: void, a: Reason, b: Reason) bool {
                if (a.n != b.n) return a.n > b.n;
                return std.mem.order(u8, a.reason, b.reason) == .lt;
            }
        }.lt);
        row.reasons = rl.items[0..@min(rl.items.len, max_reasons)];
        var pl: std.ArrayListUnmanaged(PidAt) = .empty;
        defer pl.deinit(gpa);
        var pit = pids.iterator();
        while (pit.next()) |kv| {
            if ((kv.key_ptr.* >> 32) != id) continue;
            try pl.append(gpa, .{ .pid = @bitCast(@as(u32, @truncate(kv.key_ptr.*))), .ts = kv.value_ptr.* });
        }
        std.mem.sort(PidAt, pl.items, {}, struct {
            fn lt(_: void, a: PidAt, b: PidAt) bool {
                if (a.ts != b.ts) return a.ts > b.ts;
                return a.pid < b.pid;
            }
        }.lt);
        const keep: usize = @min(pl.items.len, max_pids);
        const pout = try arena.alloc(i32, keep);
        for (pout, pl.items[0..keep]) |*d, p| d.* = p.pid;
        row.pids = pout;
    }
    out.who = rows.items;

    // The series: the busiest `max_series` programs, then `other` when
    // anybody is left over.
    const named: usize = @min(rows.items.len, max_series);
    const has_other = rows.items.len > max_series;
    const series = try arena.alloc(Series, named + @intFromBool(has_other));
    for (series[0..named], rows.items[0..named]) |*sr, row| sr.* = .{ .label = row.program, .mnml = row.mnml };
    if (has_other) series[named] = .{ .label = "other" };
    out.series = series;

    // Which series each interned program lands in.
    const series_of = try gpa.alloc(u8, n_names);
    defer gpa.free(series_of);
    @memset(series_of, @intCast(max_series));
    for (rows.items, ids) |row, id| series_of[id] = row.series;

    const counts = try arena.alloc(u32, nb * series.len);
    @memset(counts, 0);
    if (series.len > 0) for (events) |e| {
        if (e.ts < out.start or e.ts < cutoff or e.ts >= end) continue;
        if (src == .requests and e.off_wire) continue;
        const bi: usize = @intFromFloat(@floor((e.ts - out.start) / bsecs));
        if (bi >= nb) continue;
        const si: usize = @min(series_of[e.program], series.len - 1);
        counts[bi * series.len + si] += 1;
    };
    out.counts = counts;
    return out;
}

/// The bucket file as it stands now: refilled to `now` at its own rate,
/// up to the service's capacity (the file carries no burst).
pub fn readBucket(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, service: []const u8, now: f64) ?Bucket {
    const path = sdk.ratelimit.statePath(gpa, io, env, service) catch return null;
    defer gpa.free(path);
    return readBucketAt(io, gpa, path, service, now);
}

fn readBucketAt(io: Io, gpa: Allocator, path: []const u8, service: []const u8, now: f64) ?Bucket {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return null;
    defer gpa.free(text);
    return bucketOf(text, sdk.ratelimit.configFor(service).capacity, now);
}

/// Every bucket file of `service`, on `arena`: the shared
/// `<service>-ratelimit.json`, then each token's
/// `<service>-ratelimit-<id>.json` beside it, by id — where the SDK
/// puts them (`statePathForId`). A service the SDK keeps one bucket for
/// (not counted per token, or `<SERVICE>_RATELIMIT_STATE` naming the
/// file outright) has only the one. At most `max_buckets`.
pub fn readBuckets(io: Io, arena: Allocator, gpa: Allocator, env: *const std.process.Environ.Map, service: []const u8, now: f64) Allocator.Error![]const BucketRow {
    var out: std.ArrayListUnmanaged(BucketRow) = .empty;
    const shared = try sdk.ratelimit.statePath(gpa, io, env, service);
    defer gpa.free(shared);
    if (readBucketAt(io, gpa, shared, service, now)) |b| try out.append(arena, .{ .file = try arena.dupe(u8, std.fs.path.basename(shared)), .bucket = b });
    // Where a token's file would go: the SDK's own answer, with an id
    // that names nobody. The same path back means one bucket only.
    const probe = try sdk.ratelimit.statePathForId(gpa, io, env, service, @as(sdk.ratelimit.TokenId, @splat('0')));
    defer gpa.free(probe);
    if (std.mem.eql(u8, probe, shared)) return out.items;
    const dir_path = std.fs.path.dirname(probe) orelse return out.items;
    // `<svc>-ratelimit-` and `.json` around the id, as the SDK spells
    // the service (`sanitize`).
    const probe_name = std.fs.path.basename(probe);
    const prefix = probe_name[0 .. probe_name.len - sdk.ratelimit.token_id_len - ".json".len];
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var ids: std.ArrayListUnmanaged([sdk.ratelimit.token_id_len]u8) = .empty;
    defer ids.deinit(gpa);
    var it = dir.iterate();
    var seen: usize = 0;
    while (it.next(io) catch null) |entry| {
        seen += 1;
        if (seen > 2000) break;
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len != prefix.len + sdk.ratelimit.token_id_len + ".json".len) continue;
        if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".json")) continue;
        const id = name[prefix.len..][0..sdk.ratelimit.token_id_len];
        if (!validTokenId(id)) continue;
        try ids.append(gpa, id.*);
    }
    std.mem.sort([sdk.ratelimit.token_id_len]u8, ids.items, {}, struct {
        fn lt(_: void, a: [sdk.ratelimit.token_id_len]u8, b: [sdk.ratelimit.token_id_len]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lt);
    for (ids.items) |id| {
        if (out.items.len >= max_buckets) break;
        const path = try std.fs.path.join(gpa, &.{ dir_path, try std.fmt.allocPrint(arena, "{s}{s}.json", .{ prefix, &id }) });
        defer gpa.free(path);
        const b = readBucketAt(io, gpa, path, service, now) orelse continue;
        try out.append(arena, .{ .token = try arena.dupe(u8, &id), .file = try arena.dupe(u8, std.fs.path.basename(path)), .bucket = b });
    }
    return out.items;
}

/// This hour's draws per bucket, on `arena`: one row per bucket file
/// (zero when nothing drew on it) and one per token the draws name
/// that has no file; the shared one first, then by id. With the
/// request log as the source every line is the shared bucket's.
pub fn hourByBucket(arena: Allocator, gpa: Allocator, s: *const ServiceReader, buckets: []const BucketRow, now: f64) Allocator.Error![]const HourRow {
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);
    for (buckets) |b| try counts.put(gpa, b.token, 0);
    const src = s.source();
    const events: []const Event = switch (src) {
        .draws => s.draw_events.items,
        .requests => s.req_events.items,
        .none => &.{},
    };
    for (events) |e| {
        if (now - e.ts > 3600) continue;
        if (src == .requests and e.off_wire) continue;
        const key = if (e.token == no_token) "" else s.names.get(e.token);
        const gop = try counts.getOrPut(gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    const rows = try arena.alloc(HourRow, counts.count());
    for (counts.keys(), counts.values(), rows) |k, v, *r| r.* = .{ .token = try arena.dupe(u8, k), .requests = v };
    std.mem.sort(HourRow, rows, {}, struct {
        fn lt(_: void, a: HourRow, b: HourRow) bool {
            return std.mem.order(u8, a.token, b.token) == .lt;
        }
    }.lt);
    return rows;
}

/// The file's six keys, each one bounded: a stamp the reader cannot
/// place (`saneTs`) counts as none, and a rate or a token count outside
/// what a bucket can hold is clamped to it.
pub fn bucketOf(text: []const u8, capacity: f64, now: f64) ?Bucket {
    const st = sdk.ratelimit.parseState(text) orelse return null;
    const cap = clampF(capacity, 0, 1e9);
    const rate = clampF(st.rate, 0, 1e6);
    const elapsed = if (saneTs(st.ts)) |ts| clampF(now - ts, 0, max_ts) else 0;
    return .{
        .tokens = clampF(clampF(st.tokens, 0, cap) + elapsed * rate, 0, cap),
        .capacity = cap,
        .rate = rate,
        .cooldown_secs = if (saneTs(st.cooldown_until)) |c| clampF(c - now, 0, max_ts) else 0,
        .last_429_age = if (saneTs(st.last_429)) |l| (if (l > 0) clampF(now - l, 0, max_ts) else null) else null,
        .throttles = st.throttles,
    };
}

/// The bucket's refill an hour, what an integration's
/// `budget.hourly_budget` is configured from: `rate × 3600`.
pub fn hourlyLimit(service: []const u8) u32 {
    return @intFromFloat(sdk.ratelimit.configFor(service).rate * 3600.0);
}

/// Today's count in `<data root>/budget/<service>.tally`.
pub fn readTally(io: Io, gpa: Allocator, data_root: []const u8, service: []const u8, now: f64) ?u32 {
    const name = std.fmt.allocPrint(gpa, "{s}.tally", .{service}) catch return null;
    defer gpa.free(name);
    const path = std.fs.path.join(gpa, &.{ data_root, "budget", name }) catch return null;
    defer gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024)) catch return null;
    defer gpa.free(text);
    const tally = sdk.budget.Tally.parse(text);
    const secs: i64 = floorI64(now);
    return tally.counts(sdk.budget.dayOf(secs, sdk.budget.localOffset(secs))).today;
}

/// Entries in `$MNML_SHARED_STATE_DIR/http-cache/<service>/`, null with
/// no such directory. Files only; the count stops at a hundred thousand.
pub fn countCache(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, service: []const u8) ?u32 {
    const shared = env.get("MNML_SHARED_STATE_DIR") orelse return null;
    if (shared.len == 0) return null;
    const path = std.fs.path.join(gpa, &.{ shared, "http-cache", service }) catch return null;
    defer gpa.free(path);
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    var n: u32 = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file) n += 1;
        if (n >= 100_000) break;
    }
    return n;
}

/// The integration's own `feed` block, out of its config file — the
/// same file it reads (`$MNML_<SERVICE>_CONFIG`, else the workspace's
/// `.mnml/integrations/<service>/config.zon`, else the data root's) —
/// and the file it names, judged by its mtime against `stale_secs`.
pub fn readFeed(io: Io, arena: Allocator, paths: Paths, service: []const u8, now: f64) Feed {
    const cfg_path = configPath(io, arena, paths, service) orelse return .{};
    const text = Io.Dir.cwd().readFileAllocOptions(io, cfg_path, arena, .limited(256 * 1024), .of(u8), 0) catch return .{};
    const Shape = struct { feed: sdk.feed.Config = .{} };
    const parsed = std.zon.parse.fromSliceAlloc(Shape, arena, text, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch return .{};
    const base = std.fs.path.dirname(cfg_path) orelse "";
    const file = sdk.feed.resolvePath(arena, paths.env, base, parsed.feed.file) catch return .{};
    if (file.len == 0) return .{ .stale_secs = parsed.feed.stale_secs };
    const st = Io.Dir.cwd().statFile(io, file, .{}) catch return .{ .state = .missing, .stale_secs = parsed.feed.stale_secs, .path = file };
    const mtime: f64 = @as(f64, @floatFromInt(st.mtime.toNanoseconds())) / 1e9;
    const quiet = @max(now - mtime, 0);
    return .{
        .state = if (quiet > @as(f64, @floatFromInt(parsed.feed.stale_secs))) .stale else .live,
        .quiet_secs = quiet,
        .stale_secs = parsed.feed.stale_secs,
        .path = file,
    };
}

fn configPath(io: Io, arena: Allocator, paths: Paths, service: []const u8) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    const upper = std.ascii.upperString(name_buf[0..@min(service.len, 32)], service[0..@min(service.len, 32)]);
    var env_buf: [96]u8 = undefined;
    const env_name = std.fmt.bufPrint(&env_buf, "MNML_{s}_CONFIG", .{upper}) catch return null;
    if (paths.env.get(env_name)) |p| if (p.len > 0) return p;
    if (paths.workspace.len > 0) {
        const p = std.fs.path.join(arena, &.{ paths.workspace, ".mnml", "integrations", service, "config.zon" }) catch return null;
        if (exists(io, p)) return p;
    }
    const p = std.fs.path.join(arena, &.{ paths.data_root, "integrations", service, "config.zon" }) catch return null;
    if (exists(io, p)) return p;
    return null;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const Collect = struct {
    lines: *std.ArrayListUnmanaged([]u8),
    gpa: Allocator,
    fn line(c: Collect, l: []const u8) Allocator.Error!void {
        try c.lines.append(c.gpa, try c.gpa.dupe(u8, l));
    }
};

fn freeLines(lines: *std.ArrayListUnmanaged([]u8)) void {
    for (lines.items) |l| t.allocator.free(l);
    lines.clearRetainingCapacity();
}

fn appendFile(dir: std.Io.Dir, sub: []const u8, data: []const u8) !void {
    const f = try dir.createFile(t.io, sub, .{ .read = true, .truncate = false });
    defer f.close(t.io);
    try f.writePositionalAll(t.io, data, try f.length(t.io));
}

test "the tail reads complete lines by offset, keeps a half-written line for the next look, and follows a rotation through .1" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var tail: Tail = .{
        .path = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl" }),
        .older = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl.1" }),
    };
    defer tail.deinit(t.allocator);
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        freeLines(&lines);
        lines.deinit(t.allocator);
    }
    const sink: Collect = .{ .lines = &lines, .gpa = t.allocator };

    // Nothing there yet: no lines, and nothing seen.
    try tail.look(t.io, t.allocator, sink);
    try t.expectEqual(@as(usize, 0), lines.items.len);
    try t.expect(!tail.seen);

    // The older generation is read whole on the first look only, before
    // the live file. (A fresh tail, so `started` is false again.)
    try tmp.dir.writeFile(t.io, .{ .sub_path = "acme-draws.jsonl.1", .data = "{\"ts\":1,\"n\":\"old\"}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "acme-draws.jsonl", .data = "{\"ts\":2,\"n\":\"a\"}\n{\"ts\":3,\"n\":\"b" });
    tail.started = false;
    try tail.look(t.io, t.allocator, sink);
    try t.expectEqual(@as(usize, 2), lines.items.len);
    try t.expectEqualStrings("{\"ts\":1,\"n\":\"old\"}", lines.items[0]);
    try t.expectEqualStrings("{\"ts\":2,\"n\":\"a\"}", lines.items[1]);
    freeLines(&lines);

    // The half line finishes; only it comes back, and only once.
    try appendFile(tmp.dir, "acme-draws.jsonl", "\"}\n");
    try tail.look(t.io, t.allocator, sink);
    try t.expectEqual(@as(usize, 1), lines.items.len);
    try t.expectEqualStrings("{\"ts\":3,\"n\":\"b\"}", lines.items[0]);
    freeLines(&lines);
    try tail.look(t.io, t.allocator, sink);
    try t.expectEqual(@as(usize, 0), lines.items.len);

    // A line lands, then the writer rotates before we look: the live
    // file goes to `.1` (its tail past our offset is the new line) and a
    // fresh live file starts. Both lines come back, in order, once.
    try appendFile(tmp.dir, "acme-draws.jsonl", "{\"ts\":4,\"n\":\"c\"}\n");
    try tmp.dir.deleteFile(t.io, "acme-draws.jsonl.1");
    try tmp.dir.rename("acme-draws.jsonl", tmp.dir, "acme-draws.jsonl.1", t.io);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "acme-draws.jsonl", .data = "{\"ts\":5,\"n\":\"d\"}\n" });
    try tail.look(t.io, t.allocator, sink);
    try t.expectEqual(@as(usize, 2), lines.items.len);
    try t.expectEqualStrings("{\"ts\":4,\"n\":\"c\"}", lines.items[0]);
    try t.expectEqualStrings("{\"ts\":5,\"n\":\"d\"}", lines.items[1]);
    freeLines(&lines);
    try tail.look(t.io, t.allocator, sink);
    try t.expectEqual(@as(usize, 0), lines.items.len);
}

test "a line from Python's json.dumps — spaces after the colons — reads the same as a Zig one" {
    const zig_line = "{\"ts\":1789526218.411,\"pid\":48123,\"program\":\"widget.py\",\"reason\":\"poll\",\"wait_ms\":3030}";
    const py_line = "{\"ts\": 1789526218.411, \"pid\": 48123, \"program\": \"widget.py\", \"reason\": \"poll\", \"wait_ms\": 3030}";
    for ([_][]const u8{ zig_line, py_line }) |l| {
        try t.expectApproxEqAbs(@as(f64, 1789526218.411), jsonNumber(l, "ts").?, 1e-6);
        try t.expectEqual(@as(f64, 48123), jsonNumber(l, "pid").?);
        try t.expectEqualStrings("widget.py", jsonString(l, "program").?);
        try t.expectEqualStrings("poll", jsonString(l, "reason").?);
    }
    // A key that is only a prefix of another key is not that key.
    try t.expect(jsonNumber("{\"wait_ms_total\":9}", "wait_ms") == null);
    try t.expect(jsonString("{\"program\":42}", "program") == null);
}

/// A draws line for the fixtures: invented programs and pids only.
fn draw(out: *std.ArrayListUnmanaged(u8), ts: f64, pid: i32, program: []const u8, reason: []const u8, wait_ms: u32) !void {
    try out.print(t.allocator, "{{\"ts\":{d:.3},\"pid\":{d},\"program\":\"{s}\",\"service\":\"acme\",\"reason\":\"{s}\",\"wait_ms\":{d},\"tokens_after\":3.5}}\n", .{ ts, pid, program, reason, wait_ms });
}

test "the Who table counts every program on the bucket, busiest first, with its shares, top reason, worst wait and pids" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const now: f64 = 1_790_000_000;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    // In the last hour: widget.py 6 (two pids), mnml-acme 3, a cron
    // script 1. Two hours ago: one more widget.py — inside the day, not
    // the hour.
    for (0..4) |i| try draw(&text, now - 600 + @as(f64, @floatFromInt(i)), 4100, "widget.py", "poll", 10);
    for (0..2) |i| try draw(&text, now - 300 + @as(f64, @floatFromInt(i)), 4200, "widget.py", "user", 900);
    for (0..3) |i| try draw(&text, now - 100 + @as(f64, @floatFromInt(i)), 77, "mnml-acme", "pane_open", 0);
    try draw(&text, now - 50, 9, "cron.sh", "batch", 5);
    try draw(&text, now - 7200, 4100, "widget.py", "poll", 0);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "acme-draws.jsonl", .data = text.items });

    var s: ServiceReader = .{ .service = try t.allocator.dupe(u8, "acme") };
    defer s.deinit(t.allocator);
    s.draws.path = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl" });
    s.draws.older = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl.1" });
    s.requests.path = try std.fs.path.join(t.allocator, &.{ root, "requests", "acme.jsonl" });
    s.requests.older = try std.fs.path.join(t.allocator, &.{ root, "requests", "acme.1.jsonl" });
    try s.look(t.io, t.allocator, now, false);
    try t.expectEqual(Source.draws, s.source());

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hour = try buildWindow(a, t.allocator, &s, .hour, now);
    try t.expectEqual(@as(u32, 10), hour.requests);
    try t.expectEqual(@as(usize, 3), hour.who.len);
    try t.expectEqualStrings("widget.py", hour.who[0].program);
    try t.expectEqual(@as(u32, 6), hour.who[0].requests);
    try t.expectApproxEqAbs(@as(f64, 60), hour.who[0].share_pct, 1e-9);
    try t.expectEqualStrings("poll", hour.who[0].topReason());
    try t.expectEqual(@as(usize, 2), hour.who[0].reasons.len);
    try t.expectEqual(@as(u32, 900), hour.who[0].worst_wait_ms);
    // Two pids, the one seen last first.
    try t.expectEqualSlices(i32, &.{ 4200, 4100 }, hour.who[0].pids);
    try t.expect(!hour.who[0].mnml);
    try t.expectEqualStrings("mnml-acme", hour.who[1].program);
    try t.expect(hour.who[1].mnml);
    try t.expectApproxEqAbs(@as(f64, 30), hour.who[1].share_pct, 1e-9);
    try t.expectEqualStrings("cron.sh", hour.who[2].program);
    try t.expectApproxEqAbs(@as(f64, 10), hour.who[2].share_pct, 1e-9);
    // The shares add up to the whole.
    var sum: f64 = 0;
    for (hour.who) |w| sum += w.share_pct;
    try t.expectApproxEqAbs(@as(f64, 100), sum, 1e-9);

    // The day sees the older line too.
    const day = try buildWindow(a, t.allocator, &s, .day, now);
    try t.expectEqual(@as(u32, 11), day.requests);
    try t.expectEqual(@as(u32, 7), day.who[0].requests);
}

test "the timeline buckets per minute on the wall clock and stacks by program — never one merged series" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    // 14:07:30 on some day: the last bucket is 14:07:00–14:08:00.
    const now: f64 = 1_790_000_000 - @mod(1_790_000_000, 60) + 30;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    // This minute: widget.py twice, mnml-acme once.
    try draw(&text, now - 20, 1, "widget.py", "poll", 0);
    try draw(&text, now - 10, 1, "widget.py", "poll", 0);
    try draw(&text, now - 5, 2, "mnml-acme", "pane_open", 0);
    // The minute before: mnml-acme once.
    try draw(&text, now - 70, 2, "mnml-acme", "poll", 0);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "acme-draws.jsonl", .data = text.items });
    var s: ServiceReader = .{ .service = try t.allocator.dupe(u8, "acme") };
    defer s.deinit(t.allocator);
    s.draws.path = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl" });
    s.draws.older = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl.1" });
    s.requests.path = try std.fs.path.join(t.allocator, &.{ root, "none.jsonl" });
    s.requests.older = try std.fs.path.join(t.allocator, &.{ root, "none.1.jsonl" });
    try s.look(t.io, t.allocator, now, false);

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const w = try buildWindow(arena_state.allocator(), t.allocator, &s, .hour, now);
    try t.expectEqual(@as(usize, 60), Window.hour.buckets());
    try t.expectEqual(@as(f64, 0), @mod(w.start, 60));
    // Two series: the stacking is by program.
    try t.expectEqual(@as(usize, 2), w.series.len);
    // widget.py and mnml-acme tie at 2; the name breaks it.
    try t.expectEqualStrings("mnml-acme", w.series[0].label);
    try t.expectEqualStrings("widget.py", w.series[1].label);
    const last = Window.hour.buckets() - 1;
    try t.expectEqual(@as(u32, 1), w.at(last, 0));
    try t.expectEqual(@as(u32, 2), w.at(last, 1));
    try t.expectEqual(@as(u32, 3), w.total(last));
    try t.expectEqual(@as(u32, 1), w.at(last - 1, 0));
    try t.expectEqual(@as(u32, 0), w.at(last - 1, 1));
}

test "past seven programs the rest stack as one `other`, and the Who table still lists every one" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const now: f64 = 1_790_000_000;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..9) |p| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "tool{d}", .{p});
        // tool0 draws 10 times, tool1 9, … so the order is fixed.
        // Inside the newest minute, so the last bucket holds it all.
        for (0..10 - p) |_| try draw(&text, now - 5, @intCast(p + 1), name, "poll", 0);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "acme-draws.jsonl", .data = text.items });
    var s: ServiceReader = .{ .service = try t.allocator.dupe(u8, "acme") };
    defer s.deinit(t.allocator);
    s.draws.path = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl" });
    s.draws.older = try std.fs.path.join(t.allocator, &.{ root, "x.1" });
    s.requests.path = try std.fs.path.join(t.allocator, &.{ root, "y.jsonl" });
    s.requests.older = try std.fs.path.join(t.allocator, &.{ root, "y.1.jsonl" });
    try s.look(t.io, t.allocator, now, false);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const w = try buildWindow(arena_state.allocator(), t.allocator, &s, .hour, now);
    try t.expectEqual(@as(usize, 9), w.who.len);
    try t.expectEqual(@as(usize, max_series + 1), w.series.len);
    try t.expectEqualStrings("other", w.series[max_series].label);
    try t.expectEqual(@as(u8, max_series), w.who[8].series);
    // tool7 (3) and tool8 (2) are `other`'s 5.
    try t.expectEqual(@as(u32, 5), w.at(Window.hour.buckets() - 1, max_series));
}

test "with no draws file the request log is the source — its lines on the wire; and the 304 share is mnml's own" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const now: f64 = 1_790_000_000;
    try tmp.dir.createDirPath(t.io, "requests");
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..8) |_| try text.print(t.allocator, "{{\"ts\":{d},\"service\":\"acme\",\"integration\":\"mnml-acme\",\"method\":\"GET\",\"host\":\"api.example.org\",\"path\":\"/2.0/widgets\",\"status\":304,\"reason\":\"poll\",\"wait_ms\":0,\"cache\":\"miss\"}}\n", .{now - 100});
    try text.print(t.allocator, "{{\"ts\":{d},\"service\":\"acme\",\"integration\":\"mnml-acme\",\"method\":\"GET\",\"host\":\"api.example.org\",\"path\":\"/2.0/widgets\",\"status\":200,\"reason\":\"pane_open\",\"wait_ms\":0,\"cache\":\"miss\"}}\n", .{now - 90});
    try text.print(t.allocator, "{{\"ts\":{d},\"service\":\"acme\",\"integration\":\"mnml-acme\",\"method\":\"GET\",\"host\":\"api.example.org\",\"path\":\"/2.0/widgets\",\"status\":429,\"reason\":\"refresh\",\"wait_ms\":3000,\"cache\":\"none\"}}\n", .{now - 80});
    // A cache hit is a line, not a request.
    try text.print(t.allocator, "{{\"ts\":{d},\"service\":\"acme\",\"integration\":\"mnml-acme\",\"method\":\"GET\",\"host\":\"api.example.org\",\"path\":\"/2.0/widgets\",\"status\":null,\"reason\":\"cache_hit\",\"wait_ms\":0,\"cache\":\"hit\"}}\n", .{now - 70});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "requests/acme.jsonl", .data = text.items });
    var s: ServiceReader = .{ .service = try t.allocator.dupe(u8, "acme") };
    defer s.deinit(t.allocator);
    s.draws.path = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl" });
    s.draws.older = try std.fs.path.join(t.allocator, &.{ root, "acme-draws.jsonl.1" });
    const q = try requestLogPaths(t.allocator, root, "acme");
    s.requests.path = q[0];
    s.requests.older = q[1];
    try s.look(t.io, t.allocator, now, false);
    try t.expectEqual(Source.requests, s.source());
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const w = try buildWindow(arena_state.allocator(), t.allocator, &s, .hour, now);
    try t.expectEqual(@as(u32, 10), w.requests);
    try t.expectEqual(@as(u32, 1), w.cache_hits);
    try t.expectEqual(@as(u32, 1), w.throttled);
    try t.expectApproxEqAbs(@as(f64, 80), w.not_modified_pct.?, 1e-9);
    try t.expectEqualStrings("mnml-acme", w.who[0].program);
    try t.expect(w.who[0].mnml);
}

test "the window keeps seven days and at most max_events lines, oldest dropped" {
    var list: std.ArrayListUnmanaged(Event) = .empty;
    defer list.deinit(t.allocator);
    const now: f64 = 1_790_000_000;
    try list.append(t.allocator, .{ .ts = now - keep_secs - 10 });
    try list.append(t.allocator, .{ .ts = now - 5 });
    try list.append(t.allocator, .{ .ts = now - 50 });
    settle(&list, 0, now);
    // Sorted, and the eight-day-old line is gone.
    try t.expectEqual(@as(usize, 2), list.items.len);
    try t.expectEqual(now - 50, list.items[0].ts);
    try t.expectEqual(now - 5, list.items[1].ts);
    list.clearRetainingCapacity();
    for (0..max_events + 3) |i| try list.append(t.allocator, .{ .ts = now - 1000 + @as(f64, @floatFromInt(i)) * 0.001 });
    settle(&list, 0, now);
    try t.expectEqual(max_events, list.items.len);
    try t.expectApproxEqAbs(now - 1000 + 0.003, list.items[0].ts, 1e-6);
}

test "the Now numbers: the bucket refilled to now, its cooldown and last 429, the hourly limit and the day tally" {
    const now: f64 = 1_790_000_000;
    // Ten seconds ago it held 2 tokens, refilling at 0.2/s; cooling for
    // 30 s more; a 429 four minutes ago.
    const text = "{\"ts\":1789999990,\"tokens\":2,\"rate\":0.2,\"cooldown_until\":1790000030,\"throttles\":3,\"last_429\":1789999760}";
    const b = bucketOf(text, 40, now).?;
    try t.expectApproxEqAbs(@as(f64, 4), b.tokens, 1e-9);
    try t.expectEqual(@as(f64, 40), b.capacity);
    try t.expectApproxEqAbs(@as(f64, 30), b.cooldown_secs, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 240), b.last_429_age.?, 1e-9);
    try t.expectEqual(@as(u32, 3), b.throttles);
    // A full bucket stays at its capacity however long it sat.
    try t.expectEqual(@as(f64, 40), bucketOf("{\"ts\":1,\"tokens\":39,\"rate\":1,\"cooldown_until\":0,\"throttles\":0,\"last_429\":0}", 40, now).?.tokens);
    try t.expect(bucketOf("{\"ts\":1}", 40, now).?.last_429_age == null);
    try t.expect(bucketOf("not json", 40, now) == null);
    // The limit is the bucket's own refill an hour.
    try t.expectEqual(@as(u32, @intFromFloat(sdk.ratelimit.Config.bitbucket.rate * 3600.0)), hourlyLimit("bitbucket"));
    try t.expectEqual(@as(u32, @intFromFloat(sdk.ratelimit.Config.jira.rate * 3600.0)), hourlyLimit("jira"));

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "budget");
    const secs: i64 = @intFromFloat(now);
    var date: [10]u8 = undefined;
    const today = sdk.budget.isoDate(&date, sdk.budget.dayOf(secs, sdk.budget.localOffset(secs)));
    const tally = try std.fmt.allocPrint(t.allocator, "{s} 1204\n", .{today});
    defer t.allocator.free(tally);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "budget/acme.tally", .data = tally });
    try t.expectEqual(@as(?u32, 1204), readTally(t.io, t.allocator, root, "acme", now));
    try t.expect(readTally(t.io, t.allocator, root, "nobody", now) == null);
}

test "discovery finds the services that have files, mnml's two first, and nothing from a stray name" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "shared");
    try tmp.dir.createDirPath(t.io, "data/requests");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shared/widgets-draws.jsonl", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shared/gadgets-ratelimit.json", .data = "{}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shared/notes.txt", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/requests/sprockets.1.jsonl", .data = "" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const shared = try std.fs.path.join(t.allocator, &.{ root, "shared" });
    defer t.allocator.free(shared);
    try env.put("MNML_SHARED_STATE_DIR", shared);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (out.items) |s| t.allocator.free(s);
        out.deinit(t.allocator);
    }
    try discover(t.allocator, t.io, .{ .data_root = data, .env = &env }, &.{ "jira", "bitbucket" }, &out);
    try t.expectEqualStrings("jira", out.items[0]);
    try t.expectEqualStrings("bitbucket", out.items[1]);
    var found = [_]bool{ false, false, false };
    for (out.items[2..]) |s| {
        if (std.mem.eql(u8, s, "widgets")) found[0] = true;
        if (std.mem.eql(u8, s, "gadgets")) found[1] = true;
        if (std.mem.eql(u8, s, "sprockets")) found[2] = true;
        try t.expect(!std.mem.eql(u8, s, "notes"));
    }
    try t.expect(found[0] and found[1] and found[2]);
}

test "the feed reads the integration's own config: no file is polling, a fresh one live, an old one stale" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "integrations/acme");
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const paths: Paths = .{ .data_root = root, .env = &env };
    // No config at all: polling.
    try t.expectEqual(FeedState.polling, readFeed(t.io, a, paths, "acme", 0).state);
    // A config with other keys and no feed: still polling.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/acme/config.zon", .data = ".{ .base_url = \"https://api.example.org/\", .refresh_interval_secs = 5 }" });
    try t.expectEqual(FeedState.polling, readFeed(t.io, a, paths, "acme", 0).state);
    // A feed file named relative to the config, not there yet.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/acme/config.zon", .data = ".{ .base_url = \"https://api.example.org/\", .feed = .{ .file = \"events.jsonl\", .stale_secs = 120 } }" });
    const missing = readFeed(t.io, a, paths, "acme", 0);
    try t.expectEqual(FeedState.missing, missing.state);
    try t.expectEqual(@as(u32, 120), missing.stale_secs);
    // Written now: live. Read three minutes on: stale.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/acme/events.jsonl", .data = "{\"kind\":\"heartbeat\",\"at\":1}\n" });
    const st = try tmp.dir.statFile(t.io, "integrations/acme/events.jsonl", .{});
    const mtime: f64 = @as(f64, @floatFromInt(st.mtime.toNanoseconds())) / 1e9;
    try t.expectEqual(FeedState.live, readFeed(t.io, a, paths, "acme", mtime + 5).state);
    try t.expectEqual(FeedState.stale, readFeed(t.io, a, paths, "acme", mtime + 180).state);
}

test "the throttles file: today's and yesterday's are read, the test leakage skipped, mnml's own 429s folded in; the first look is history and a later line is news" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "shared/api-usage");
    try tmp.dir.createDirPath(t.io, "data/requests");
    // Ten minutes into a UTC day `d`.
    const d: i64 = 20_700;
    const now: f64 = @as(f64, @floatFromInt(d * 86400)) + 600;
    var y_buf: [10]u8 = undefined;
    var t_buf: [10]u8 = undefined;
    const yesterday = sdk.budget.isoDate(&y_buf, d - 1);
    const today = sdk.budget.isoDate(&t_buf, d);
    const y_path = try std.fmt.allocPrint(t.allocator, "shared/api-usage/{s}.throttles.jsonl", .{yesterday});
    defer t.allocator.free(y_path);
    const t_path = try std.fmt.allocPrint(t.allocator, "shared/api-usage/{s}.throttles.jsonl", .{today});
    defer t.allocator.free(t_path);
    // Yesterday, ten seconds before midnight — an ISO stamp, the way a
    // Python writer may put it.
    const y_line = try std.fmt.allocPrint(t.allocator, "{{\"ts\": \"{s}T23:59:50Z\", \"api\": \"bitbucket\", \"caller\": \"widget.py\", \"status\": 429, \"where\": \"api.example.org/2.0/widgets\", \"reason\": null, \"headers\": {{}}}}\n", .{yesterday});
    defer t.allocator.free(y_line);
    try tmp.dir.writeFile(t.io, .{ .sub_path = y_path, .data = y_line });
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.print(t.allocator, "{{\"ts\":{d},\"api\":\"bitbucket\",\"caller\":\"widget.py\",\"status\":429,\"where\":\"api.example.org/2.0/widgets\"}}\n", .{now - 300});
    try text.print(t.allocator, "{{\"ts\":{d},\"api\":\"jira\",\"caller\":\"sync-bot\",\"status\":429,\"where\":\"acme.example.org/rest/api/3/search\",\"reason\":\"jira-quota-tenant-based\"}}\n", .{now - 200});
    // The old test suite's leakage: never a real 429.
    try text.print(t.allocator, "{{\"ts\":{d},\"api\":\"bitbucket\",\"caller\":\"pytest\",\"status\":429,\"where\":\"api.bitbucket.org/2.0/x\"}}\n", .{now - 100});
    try tmp.dir.writeFile(t.io, .{ .sub_path = t_path, .data = text.items });
    // mnml's own 429, in its request log.
    const req = try std.fmt.allocPrint(t.allocator, "{{\"ts\":{d},\"service\":\"bitbucket\",\"integration\":\"mnml-bitbucket\",\"method\":\"GET\",\"host\":\"api.example.org\",\"path\":\"/2.0/widgets\",\"status\":429,\"reason\":\"poll\",\"wait_ms\":0}}\n", .{now - 50});
    defer t.allocator.free(req);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/requests/bitbucket.jsonl", .data = req });

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const shared = try std.fs.path.join(t.allocator, &.{ root, "shared" });
    defer t.allocator.free(shared);
    try env.put("MNML_SHARED_STATE_DIR", shared);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const paths: Paths = .{ .data_root = data, .env = &env };
    var rd: Reader = .{};
    defer rd.deinit(t.allocator);

    try rd.look(t.io, t.allocator, paths, &.{ "jira", "bitbucket" }, now);
    const bb = rd.find("bitbucket").?;
    // Yesterday's, today's, and mnml's own — not the leakage.
    try t.expectEqual(@as(usize, 3), bb.throttles.items.len);
    try t.expectEqual(@as(usize, 1), rd.find("jira").?.throttles.items.len);
    // History, not news.
    try t.expectEqual(@as(usize, 0), bb.fresh.items.len);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hour = try throttlesIn(a, t.allocator, bb, bb.throttles.items, 3600, now);
    try t.expectEqual(@as(u32, 3), hour.n);
    try t.expectApproxEqAbs(@as(f64, 50), hour.last_age.?, 1e-6);
    try t.expectEqualStrings("widget.py", hour.by[0].reason);
    try t.expectEqual(@as(u32, 2), hour.by[0].n);
    try t.expectEqualStrings("mnml-bitbucket", hour.by[1].reason);

    // A line lands: the next look calls it news.
    const more = try std.fmt.allocPrint(t.allocator, "{{\"ts\":{d},\"api\":\"bitbucket\",\"caller\":\"widget.py\",\"status\":429,\"where\":\"api.example.org/2.0/widgets\"}}\n", .{now + 5});
    defer t.allocator.free(more);
    try appendFile(tmp.dir, t_path, more);
    try rd.look(t.io, t.allocator, paths, &.{ "jira", "bitbucket" }, now + 10);
    try t.expectEqual(@as(usize, 1), bb.fresh.items.len);
    try t.expectEqual(@as(usize, 4), bb.throttles.items.len);

    // Across midnight: a line written late into what is now yesterday's
    // file, and one in the new day's file — both news, neither twice.
    const next_now = @as(f64, @floatFromInt((d + 1) * 86400)) + 30;
    var n_buf: [10]u8 = undefined;
    const n_path = try std.fmt.allocPrint(t.allocator, "shared/api-usage/{s}.throttles.jsonl", .{sdk.budget.isoDate(&n_buf, d + 1)});
    defer t.allocator.free(n_path);
    const late = try std.fmt.allocPrint(t.allocator, "{{\"ts\":{d},\"api\":\"bitbucket\",\"caller\":\"cron.sh\",\"status\":429,\"where\":\"api.example.org/2.0/widgets\"}}\n", .{next_now - 40});
    defer t.allocator.free(late);
    try appendFile(tmp.dir, t_path, late);
    const fresh_day = try std.fmt.allocPrint(t.allocator, "{{\"ts\":{d},\"api\":\"bitbucket\",\"caller\":\"cron.sh\",\"status\":429,\"where\":\"api.example.org/2.0/widgets\"}}\n", .{next_now - 10});
    defer t.allocator.free(fresh_day);
    try tmp.dir.writeFile(t.io, .{ .sub_path = n_path, .data = fresh_day });
    try rd.look(t.io, t.allocator, paths, &.{ "jira", "bitbucket" }, next_now);
    try t.expectEqual(@as(usize, 2), bb.fresh.items.len);
    try t.expectEqual(@as(usize, 6), bb.throttles.items.len);
    // The day before yesterday is let go.
    for (rd.throttle_files.items) |f| try t.expect(f.day >= d);
}

test "an ISO stamp reads as epoch seconds, with or without an offset or a fraction" {
    try t.expectEqual(@as(f64, 0), parseIso("1970-01-01T00:00:00Z").?);
    try t.expectApproxEqAbs(@as(f64, 86400.25), parseIso("1970-01-02T00:00:00.25+00:00").?, 1e-9);
    try t.expectEqual(@as(f64, 3600), parseIso("1970-01-01T00:00:00-01:00").?);
    try t.expect(parseIso("yesterday") == null);
    try t.expect(parseThrottle("{\"ts\":5,\"api\":\"bitbucket\",\"where\":\"api.bitbucket.org/2.0/x\"}") == null);
    try t.expectEqualStrings("unknown", parseThrottle("{\"ts\":5,\"api\":\"jira\"}").?.caller);
}

/// Numbers a writer outside mnml can put in any numeric field: huge,
/// negative, infinite (JSON's `1e400` parses as inf), subnormal, past
/// every integer type, and the half-numbers a broken writer leaves.
const hostile_numbers = [_][]const u8{
    "1e30",                    "-1e30",                 "1e400",  "-1e400", "1e-400", "0",          "-0",          "-1",
    "4294967296",              "1.8446744073709552e19", "9.3e18", "1e21",   "5e19",   "1e+20",      "2e9",         "1.7976931348623157e308",
    "-1.7976931348623157e308", "1e",                    "-",      "+5",     "",       "nan",        "inf",         "1.2.3",
    "--1",                     "0.0000001",             "65536",  "429",    "-429",   "2147483648", "-2147483649",
};

test "nothing a shared file holds can panic the reader: every numeric field at its extremes, every window, the throttles and the bucket" {
    const gpa = t.allocator;
    const now: f64 = 1_790_000_000;
    var s: ServiceReader = .{ .service = try gpa.dupe(u8, "acme") };
    defer s.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const draws: ServiceReader.DrawSink = .{ .s = &s, .gpa = gpa };
    const reqs: ServiceReader.ReqSink = .{ .s = &s, .gpa = gpa, .news = true };
    const draw_keys = [_][]const u8{ "ts", "pid", "wait_ms", "tokens_after" };
    const req_keys = [_][]const u8{ "ts", "status", "wait_ms", "ms", "bytes" };
    for (hostile_numbers) |v| {
        for (draw_keys) |k| {
            var buf: [512]u8 = undefined;
            // Every other field ordinary, this one hostile.
            const l = try std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"pid\":7,\"program\":\"p\",\"reason\":\"poll\",\"wait_ms\":3,\"tokens_after\":1,\"{s}\":{s}}}", .{ now - 30, k, v });
            // The duplicate key is the hostile one: `valueAfter` reads
            // the first, so put it first as well.
            const l2 = try std.fmt.bufPrint(buf[l.len..], "{{\"{s}\":{s},\"ts\":{d},\"pid\":7,\"program\":\"p\",\"wait_ms\":3}}", .{ k, v, now - 30 });
            try draws.line(l);
            try draws.line(l2);
        }
        for (req_keys) |k| {
            var buf: [512]u8 = undefined;
            const l = try std.fmt.bufPrint(&buf, "{{\"{s}\":{s},\"ts\":{d},\"path\":\"/x\",\"status\":200,\"wait_ms\":1,\"integration\":\"mnml-acme\"}}", .{ k, v, now - 20 });
            try reqs.line(l);
        }
        var buf: [256]u8 = undefined;
        if (parseThrottle(try std.fmt.bufPrint(&buf, "{{\"ts\":{s},\"api\":\"acme\",\"caller\":\"c\"}}", .{v}))) |th| try s.noteThrottle(gpa, th.ts, th.caller, true);
    }
    // Lines no writer meant: random bytes and JSON-shaped fragments.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const frags = [_][]const u8{ "{", "}", "\"ts\":", "\"pid\":", "\"wait_ms\":", "\"status\":", "\"program\":\"", "\"", "\\", "\\u", "d83d", "1e999", "-", "9", ".", ",", ":", " ", "\x00", "\xff", "\"path\":\"/\"", "\"reason\":\"" };
    for (0..3000) |_| {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(gpa);
        try line.append(gpa, '{');
        for (0..rnd.intRangeAtMost(usize, 0, 24)) |_| {
            if (rnd.boolean()) try line.appendSlice(gpa, frags[rnd.uintLessThan(usize, frags.len)]) else try line.append(gpa, rnd.int(u8));
        }
        try draws.line(line.items);
        try reqs.line(line.items);
        if (parseThrottle(line.items)) |th| try s.noteThrottle(gpa, th.ts, th.caller, true);
    }
    settle(&s.draw_events, 0, now);
    settle(&s.req_events, 0, now);
    settle(&s.throttles, 0, now);
    // Every kept stamp is one the windows can place.
    for ([_][]const Event{ s.draw_events.items, s.req_events.items, s.throttles.items }) |list| for (list) |e| {
        try t.expect(saneTs(e.ts) != null);
        try t.expect(e.ts - now <= future_secs);
    };
    s.draws.seen = true;
    for (Window.all) |w| {
        _ = try buildWindow(a, gpa, &s, w, now);
        // A clock far off either way builds too.
        _ = try buildWindow(a, gpa, &s, w, 0);
        _ = try buildWindow(a, gpa, &s, w, max_ts);
    }
    s.draws.seen = false;
    for (Window.all) |w| _ = try buildWindow(a, gpa, &s, w, now);
    _ = try throttlesIn(a, gpa, &s, s.throttles.items, 3600, now);
    _ = try throttlesIn(a, gpa, &s, s.fresh.items, 300, now);

    // The bucket: each of the six keys hostile in turn.
    const keys = [_][]const u8{ "ts", "tokens", "rate", "cooldown_until", "throttles", "last_429" };
    for (hostile_numbers) |v| for (keys) |k| {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"ts\":1789999990,\"tokens\":2,\"rate\":0.2,\"cooldown_until\":0,\"throttles\":1,\"last_429\":0,\"{s}\":{s}}}", .{ k, v });
        const b = bucketOf(text, 40, now) orelse continue;
        for ([_]f64{ b.tokens, b.capacity, b.rate, b.cooldown_secs, b.last_429_age orelse 0 }) |f| {
            try t.expect(std.math.isFinite(f));
            try t.expect(f >= 0);
        }
        try t.expect(b.tokens <= b.capacity);
        try t.expect(b.cooldown_secs <= max_ts);
    };
    // The integer helpers saturate rather than trap.
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e300, -1e300, -1, 0 }) |f| {
        _ = wholeSecs(f);
        _ = floorI64(f);
        _ = clampU32(f);
        _ = clampF(f, 0, 1);
    }
}

test "the two reproductions: a draw stamped 1e30 is dropped, not a bucket index; a cooldown_until of 1e20 is no cooldown" {
    const gpa = t.allocator;
    const now: f64 = 1_790_000_000;
    var s: ServiceReader = .{ .service = try gpa.dupe(u8, "jira") };
    defer s.deinit(gpa);
    s.draws.seen = true;
    const draws: ServiceReader.DrawSink = .{ .s = &s, .gpa = gpa };
    try draws.line("{\"ts\":1e30,\"pid\":7,\"program\":\"clock-skew\",\"service\":\"jira\",\"reason\":\"poll\",\"wait_ms\":0,\"tokens_after\":1}");
    try t.expectEqual(@as(usize, 0), s.draw_events.items.len);
    // Inside `max_ts` but days ahead: kept by the parse, dropped by the
    // window's edge, so it never outlives every window either.
    try draws.line("{\"ts\":1790500000,\"pid\":7,\"program\":\"clock-skew\"}");
    try draws.line("{\"ts\":1789999990,\"pid\":7,\"program\":\"widget.py\"}");
    settle(&s.draw_events, 0, now);
    try t.expectEqual(@as(usize, 1), s.draw_events.items.len);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const w = try buildWindow(arena_state.allocator(), gpa, &s, .hour, now);
    try t.expectEqual(@as(u32, 1), w.requests);

    const b = bucketOf("{\"ts\":1789999990,\"tokens\":5,\"rate\":0.33,\"cooldown_until\":1e+20,\"throttles\":1,\"last_429\":1789999995}", 60, now).?;
    try t.expectEqual(@as(f64, 0), b.cooldown_secs);
    try t.expectApproxEqAbs(@as(f64, 5), b.last_429_age.?, 1e-6);
}

test "past the names cap everything new is `other`, once, without recursing" {
    var n: Names = .{};
    defer n.deinit(t.allocator);
    for (0..Names.cap) |i| {
        var buf: [16]u8 = undefined;
        _ = try n.intern(t.allocator, try std.fmt.bufPrint(&buf, "p{d}", .{i}));
    }
    const a = try n.intern(t.allocator, "one-more");
    const b = try n.intern(t.allocator, "and-another");
    try t.expectEqual(a, b);
    try t.expectEqualStrings("other", n.get(a));
    try t.expectEqual(Names.cap + 1, n.list.items.len);
}

test "a per-token service lists every bucket file, the shared one first and the tokens' by id; the hour counts each bucket's own draws" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const now: f64 = 1_790_000_000;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bitbucket-ratelimit.json", .data = "{\"ts\":1790000000,\"tokens\":7.5,\"rate\":1.2,\"cooldown_until\":1790000090,\"throttles\":4,\"last_429\":1789999760}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bitbucket-ratelimit-fedcba987654.json", .data = "{\"ts\":1790000000,\"tokens\":9,\"rate\":1.2,\"cooldown_until\":0,\"throttles\":0,\"last_429\":0}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bitbucket-ratelimit-0123456789ab.json", .data = "{\"ts\":1790000000,\"tokens\":2,\"rate\":0.6,\"cooldown_until\":0,\"throttles\":9,\"last_429\":1789999970}" });
    // Not a token's bucket: the wrong length, not hex, another
    // service, a file that is not a bucket. (No upper-case twin: on a
    // case-blind file system it would be the same file.)
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bitbucket-ratelimit-0123.json", .data = "{\"ts\":1}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bitbucket-ratelimit-0123456789zz.json", .data = "{\"ts\":1}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "jira-ratelimit-0123456789ab.json", .data = "{\"ts\":1}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bitbucket-ratelimit-aaaaaaaaaaaa.json", .data = "not a bucket" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_SHARED_STATE_DIR", root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const rows = try readBuckets(t.io, a, t.allocator, &env, "bitbucket", now);
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqualStrings("", rows[0].token);
    try t.expectEqualStrings("bitbucket-ratelimit.json", rows[0].file);
    try t.expectEqual(@as(u32, 4), rows[0].bucket.throttles);
    try t.expectEqualStrings("0123456789ab", rows[1].token);
    try t.expectEqualStrings("bitbucket-ratelimit-0123456789ab.json", rows[1].file);
    try t.expectEqual(@as(u32, 9), rows[1].bucket.throttles);
    try t.expectApproxEqAbs(@as(f64, 30), rows[1].bucket.last_429_age.?, 1e-6);
    try t.expectEqualStrings("fedcba987654", rows[2].token);
    // Jira keeps one bucket: its limits are not counted per token.
    try t.expectEqual(@as(usize, 0), (try readBuckets(t.io, a, t.allocator, &env, "jira", now)).len);
    // A file named outright is the only bucket, as the SDK has it.
    try env.put("BITBUCKET_RATELIMIT_STATE", try std.fs.path.join(a, &.{ root, "bitbucket-ratelimit.json" }));
    try t.expectEqual(@as(usize, 1), (try readBuckets(t.io, a, t.allocator, &env, "bitbucket", now)).len);

    // The hour per bucket: draws naming a token count against its
    // bucket, the rest against the shared one; a token with draws and
    // no file still has its row; a bad id is the shared bucket's.
    var s: ServiceReader = .{ .service = try t.allocator.dupe(u8, "bitbucket") };
    defer s.deinit(t.allocator);
    s.draws.seen = true;
    const sink: ServiceReader.DrawSink = .{ .s = &s, .gpa = t.allocator };
    try sink.line("{\"ts\":1789999990,\"program\":\"mnml-bitbucket\",\"token_id\":\"0123456789ab\"}");
    try sink.line("{\"ts\":1789999991,\"program\":\"mnml-bitbucket\",\"token_id\":\"0123456789ab\"}");
    try sink.line("{\"ts\":1789999992,\"program\":\"widget.py\"}");
    try sink.line("{\"ts\":1789999993,\"program\":\"widget.py\",\"token_id\":\"not-an-id\"}");
    try sink.line("{\"ts\":1789999994,\"program\":\"cron.sh\",\"token_id\":\"999999999999\"}");
    // Two hours ago: outside the hour.
    try sink.line("{\"ts\":1789992800,\"program\":\"cron.sh\",\"token_id\":\"0123456789ab\"}");
    settle(&s.draw_events, 0, now);
    const hour = try hourByBucket(a, t.allocator, &s, rows, now);
    try t.expectEqual(@as(usize, 4), hour.len);
    try t.expectEqualStrings("", hour[0].token);
    try t.expectEqual(@as(u32, 2), hour[0].requests);
    try t.expectEqualStrings("0123456789ab", hour[1].token);
    try t.expectEqual(@as(u32, 2), hour[1].requests);
    try t.expectEqualStrings("999999999999", hour[2].token);
    try t.expectEqual(@as(u32, 1), hour[2].requests);
    try t.expectEqualStrings("fedcba987654", hour[3].token);
    try t.expectEqual(@as(u32, 0), hour[3].requests);
}
