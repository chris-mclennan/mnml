//! The recent-items cache: what the integrations have lately seen of
//! the tickets, pull requests, pipelines and releases they already
//! poll — one small typed record each, readable by the host and by any
//! pane (`docs/SDK.md`, "Cache"; `docs/design/recent-items-cache.md`).
//!
//! `http_cache` holds whole responses, one file per URL; this holds one
//! small typed record per item. One file per source and kind,
//! `recent/<source>/<kind>.json`, under the first of:
//!
//!   1. `$MNML_SHARED_STATE_DIR/recent/`
//!   2. `<MNML_DATA_ROOT>/recent/`
//!   3. `~/.config/mnml/recent/`
//!
//! Writers are the integrations, as a side effect of a poll they made
//! anyway — the cache never causes a request. A write takes
//! `<kind>.lock` (exclusive, given up after `lock_timeout_ms`), reads,
//! merges by id, evicts, writes `<kind>.json.tmp.<pid>` (0600) and
//! renames it over the file, so a reader — which never locks — sees the
//! whole old file or the whole new one. `$MNML_RECENT_ITEMS=0` (the
//! host's `recent_items.enabled = false`) turns every write off.
//!
//! A file that will not parse, or is over `read_limit`, reads as empty:
//! a cache is a hint, never an error.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("zig_compat.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Map = std.process.Environ.Map;

pub const Kind = enum {
    ticket,
    pr,
    pipeline,
    release,

    pub fn Record(comptime k: Kind) type {
        return switch (k) {
            .ticket => Ticket,
            .pr => Pr,
            .pipeline => Pipeline,
            .release => Release,
        };
    }
};

/// `ACME-123`. Display names only — never an account id or an email.
pub const Ticket = struct {
    id: []const u8,
    summary: []const u8 = "",
    status: []const u8 = "",
    status_category: []const u8 = "",
    assignee: []const u8 = "",
    priority: []const u8 = "",
    type: []const u8 = "",
    fix_versions: []const []const u8 = &.{},
    updated: []const u8 = "",
};

/// `acme/widget#45`.
pub const Pr = struct {
    id: []const u8,
    title: []const u8 = "",
    source_branch: []const u8 = "",
    dest_branch: []const u8 = "",
    author: []const u8 = "",
    state: []const u8 = "",
    draft: bool = false,
    updated: []const u8 = "",
};

/// `acme/widget!1234`.
pub const Pipeline = struct {
    id: []const u8,
    state: []const u8 = "",
    result: []const u8 = "",
    ref_name: []const u8 = "",
    created: []const u8 = "",
    updated: []const u8 = "",
};

/// `ACME/2026.10`. `role` is `current`, `next` or empty; a record with
/// a role is pinned through eviction.
pub const Release = struct {
    id: []const u8,
    name: []const u8 = "",
    project: []const u8 = "",
    state: []const u8 = "",
    release_date: []const u8 = "",
    role: []const u8 = "",
    keys: []const []const u8 = &.{},
};

/// The format's version, written as `version`.
pub const format_version = 1;
/// A write that would pass this drops its oldest unpinned records.
pub const write_cap: usize = 2 << 20;
/// A reader refuses a file over this.
pub const read_limit: usize = 4 << 20;
/// How long a writer tries for the lock before it skips the write.
pub const lock_timeout_ms: u32 = 2000;

/// How much of a kind a file keeps, oldest `seen_at` dropped first.
pub const Bounds = struct {
    keep: usize,
    /// Null: no age limit.
    max_age_secs: ?i64,
    /// `keep` counts per repo (the id before `!`), not per file.
    per_repo: bool = false,
};

pub fn bounds(k: Kind) Bounds {
    return switch (k) {
        .ticket => .{ .keep = 1000, .max_age_secs = 30 * 86400 },
        .pr => .{ .keep = 500, .max_age_secs = 30 * 86400 },
        .pipeline => .{ .keep = 20, .max_age_secs = 14 * 86400, .per_repo = true },
        // Pinned (`current`/`next`) are kept whatever their age, on top.
        .release => .{ .keep = 20, .max_age_secs = 180 * 86400 },
    };
}

// ─── where ──────────────────────────────────────────────────────────────

/// The `recent/` directory, in the module comment's order; null with no
/// home at all. Owned.
pub fn rootDir(gpa: Allocator, env: *const Map) Allocator.Error!?[]u8 {
    return sharedDir(gpa, env, "recent");
}

/// `<base>/<name>`, `<base>` being the first of `$MNML_SHARED_STATE_DIR`,
/// `$MNML_DATA_ROOT`, `~/.config/mnml` — the one rule every file shared
/// between processes resolves by (`recent/` here, `http-cache/` in
/// `http_cache.zig`). Null with no home at all. Owned.
pub fn sharedDir(gpa: Allocator, env: *const Map, name: []const u8) Allocator.Error!?[]u8 {
    if (nonEmpty(env.get("MNML_SHARED_STATE_DIR"))) |d| return try std.fs.path.join(gpa, &.{ d, name });
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |d| return try std.fs.path.join(gpa, &.{ d, name });
    const home = nonEmpty(env.get("HOME")) orelse nonEmpty(env.get("USERPROFILE")) orelse return null;
    return try std.fs.path.join(gpa, &.{ home, ".config", "mnml", name });
}

/// False when the host turned the cache off (`$MNML_RECENT_ITEMS=0`).
pub fn enabled(env: *const Map) bool {
    const v = env.get("MNML_RECENT_ITEMS") orelse return true;
    return !std.mem.eql(u8, v, "0");
}

/// `<root>/<source>/<kind>.json`. Owned.
pub fn filePath(gpa: Allocator, root: []const u8, source: []const u8, kind: Kind) Allocator.Error![]u8 {
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}.json", .{@tagName(kind)}) catch unreachable;
    return std.fs.path.join(gpa, &.{ root, sanitize(source), name });
}

fn sanitize(s: []const u8) []const u8 {
    // A source names a directory; one that could climb out is refused
    // by falling back to a fixed name rather than being rewritten.
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return "_";
    return if (s.len == 0) "_" else s;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ─── writing ────────────────────────────────────────────────────────────

pub const PutOptions = struct {
    source: []const u8,
    kind: Kind,
    /// Which poll this was (`assigned_open`).
    listing: []const u8 = "",
    /// The listing came back whole: a record that named it last time and
    /// is missing now turns `stale`.
    complete: bool = false,
    /// The writer's poll interval, doubled.
    stale_after_secs: u32 = 1800,
    /// Tests pin the clock; null is now.
    now: ?i64 = null,
    lock_timeout_ms: u32 = lock_timeout_ms,
};

/// What a write did. Callers ignore it; tests read it.
pub const Outcome = enum { written, disabled, no_home, locked, failed };

/// Merge `records` (a slice of the kind's record type) into the
/// source's file. Best effort: never an error to the caller.
pub fn put(gpa: Allocator, io: Io, env: *const Map, opts: PutOptions, records: anytype) Outcome {
    if (!enabled(env)) return .disabled;
    const root = (rootDir(gpa, env) catch return .failed) orelse return .no_home;
    defer gpa.free(root);
    return putAt(gpa, io, root, opts, records);
}

/// `put` with the `recent/` directory in hand — what a worker thread
/// with no environment calls.
pub fn putAt(gpa: Allocator, io: Io, root: []const u8, opts: PutOptions, records: anytype) Outcome {
    return update(gpa, io, root, opts, .{ .records = records });
}

/// The poll failed: `error_at` moves, the records do not.
pub fn failed(gpa: Allocator, io: Io, env: *const Map, source: []const u8, kind: Kind) Outcome {
    if (!enabled(env)) return .disabled;
    const root = (rootDir(gpa, env) catch return .failed) orelse return .no_home;
    defer gpa.free(root);
    return failedAt(gpa, io, root, source, kind, null);
}

pub fn failedAt(gpa: Allocator, io: Io, root: []const u8, source: []const u8, kind: Kind, now: ?i64) Outcome {
    return update(gpa, io, root, .{ .source = source, .kind = kind, .now = now }, .failure);
}

fn update(gpa: Allocator, io: Io, root: []const u8, opts: PutOptions, change: anytype) Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = filePath(a, root, opts.source, opts.kind) catch return .failed;
    const dir = std.fs.path.dirname(path).?;
    makeDir(io, dir);
    const lock_path = std.fmt.allocPrint(a, "{s}.lock", .{path[0 .. path.len - ".json".len]}) catch return .failed;
    const lock = takeLock(io, lock_path, opts.lock_timeout_ms) orelse return .locked;
    defer lock.close(io);

    const now = opts.now orelse nowSecs(io);
    var file = readFile(a, io, path) orelse File{};
    file.source = opts.source;
    file.kind = opts.kind;
    switch (@TypeOf(change)) {
        @TypeOf(.failure) => file.error_at = now,
        else => {
            merge(a, &file, opts, change.records, now) catch return .failed;
            file.fresh_at = now;
            file.stale_after_secs = opts.stale_after_secs;
        },
    }
    evict(&file, now);
    const text = render(a, &file) catch return .failed;
    return if (writeAtomic(a, io, path, text)) .written else .failed;
}

/// `dir` and its parents, 0700 where the platform has modes. Silent.
pub fn makeDir(io: Io, dir: []const u8) void {
    if (builtin.os.tag == .windows) {
        Io.Dir.cwd().createDirPath(io, dir) catch {};
    } else {
        _ = Io.Dir.cwd().createDirPathStatus(io, dir, .fromMode(0o700)) catch {};
    }
}

/// The lock file, held exclusively; null after `timeout_ms` of trying.
fn takeLock(io: Io, path: []const u8, timeout_ms: u32) ?Io.File {
    var waited: u32 = 0;
    while (true) {
        if (Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true })) |f| {
            return f;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return null,
        }
        if (waited >= timeout_ms) return null;
        io.sleep(.fromMilliseconds(50), .awake) catch return null;
        waited += 50;
    }
}

fn filePerms() @FieldType(Io.Dir.CreateFileOptions, "permissions") {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

/// `<path>.tmp.<pid>`, then a rename over `path` — three tries 50 ms
/// apart (a Windows reader holding the file open), then a silent skip.
fn writeAtomic(a: Allocator, io: Io, path: []const u8, text: []const u8) bool {
    const tmp = std.fmt.allocPrint(a, "{s}.tmp.{d}", .{ path, pid() }) catch return false;
    return writeVia(io, tmp, path, text);
}

/// Write `text` to `tmp` (0600), then rename it over `path`, so a
/// reader sees the whole old file or the whole new one and never a
/// part. `tmp` must be in `path`'s directory — a rename across
/// filesystems is not atomic. On Windows the rename replaces an
/// existing `path` (`Io.Dir.rename` sets `REPLACE_IF_EXISTS` with
/// POSIX semantics, `MoveFileEx`'s replace). False, with `tmp` gone,
/// on any failure.
pub fn writeVia(io: Io, tmp: []const u8, path: []const u8, text: []const u8) bool {
    {
        const f = Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true, .permissions = filePerms() }) catch return false;
        defer f.close(io);
        f.writePositionalAll(io, text, 0) catch {
            Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return false;
        };
    }
    var tries: u8 = 0;
    while (tries < 3) : (tries += 1) {
        if (Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), path, io)) |_| return true else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch break;
    }
    Io.Dir.cwd().deleteFile(io, tmp) catch {};
    return false;
}

/// This process's id — what a temp file is named after.
pub fn pid() i64 {
    if (comptime builtin.os.tag == .windows) return @intCast(std.os.windows.GetCurrentProcessId());
    return @intCast(std.c.getpid());
}

fn nowSecs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

// ─── the file ───────────────────────────────────────────────────────────

/// One file, parsed. `records` are JSON objects so that fields this
/// writer does not know (a newer writer's) survive its rewrite.
pub const File = struct {
    source: []const u8 = "",
    kind: Kind = .ticket,
    fresh_at: i64 = 0,
    error_at: i64 = 0,
    stale_after_secs: i64 = 1800,
    records: std.ArrayList(ObjectMap) = .empty,

    /// The file has gone stale as a whole: past `stale_after_secs`
    /// since the last good poll, or the last poll failed.
    pub fn staleAt(f: File, now: i64) bool {
        if (f.error_at > f.fresh_at) return true;
        return now - f.fresh_at > f.stale_after_secs;
    }
};

/// Parse a file's text; null when it is not the shape. On `a`.
pub fn parseFile(a: Allocator, text: []const u8) ?File {
    if (text.len > read_limit) return null;
    const root = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch return null;
    if (root != .object) return null;
    const o = root.object;
    var f: File = .{
        .source = str(o, "source"),
        .kind = std.meta.stringToEnum(Kind, str(o, "kind")) orelse return null,
        .fresh_at = int(o, "fresh_at"),
        .error_at = int(o, "error_at"),
        .stale_after_secs = int(o, "stale_after_secs"),
    };
    const recs = o.get("records") orelse return f;
    if (recs != .array) return f;
    for (recs.array.items) |r| {
        if (r != .object or str(r.object, "id").len == 0) continue;
        f.records.append(a, r.object) catch return null;
    }
    return f;
}

/// Read and parse `path`; null for a missing, oversized or broken file.
pub fn readFile(a: Allocator, io: Io, path: []const u8) ?File {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(read_limit)) catch return null;
    return parseFile(a, text);
}

fn str(o: ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn int(o: ObjectMap, key: []const u8) i64 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => 0,
    };
}

fn flag(o: ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn indexOf(f: *const File, id: []const u8) ?usize {
    for (f.records.items, 0..) |r, i| if (std.mem.eql(u8, str(r, "id"), id)) return i;
    return null;
}

fn merge(a: Allocator, f: *File, opts: PutOptions, records: anytype, now: i64) Allocator.Error!void {
    const touched = try a.alloc(bool, f.records.items.len + records.len);
    @memset(touched, false);
    for (records) |rec| {
        const i = indexOf(f, rec.id) orelse blk: {
            try f.records.append(a, .empty);
            break :blk f.records.items.len - 1;
        };
        touched[i] = true;
        const o = &f.records.items[i];
        inline for (compat.fields(@TypeOf(rec))) |fld| {
            const v = @field(rec, fld.name);
            const jv: Value = switch (fld.type) {
                []const u8 => .{ .string = try a.dupe(u8, v) },
                bool => .{ .bool = v },
                []const []const u8 => blk: {
                    var arr = std.json.Array.init(a);
                    for (v) |s| try arr.append(.{ .string = try a.dupe(u8, s) });
                    break :blk .{ .array = arr };
                },
                else => @compileError("sdk.cache: a record field must be a string, a bool or a string list"),
            };
            try o.put(a, fld.name, jv);
        }
        try o.put(a, "seen_at", .{ .integer = now });
        try o.put(a, "stale", .{ .bool = false });
        if (opts.listing.len > 0 and !hasListing(o.*, opts.listing)) {
            var arr = try listingsOf(a, o.*);
            try arr.append(.{ .string = try a.dupe(u8, opts.listing) });
            try o.put(a, "listings", .{ .array = arr });
        }
    }
    if (!opts.complete or opts.listing.len == 0) return;
    // Named this listing last time, missing from it now: it moved or
    // closed, and we no longer know its state.
    for (f.records.items, 0..) |*o, i| {
        if (touched[i] or !hasListing(o.*, opts.listing)) continue;
        var kept = std.json.Array.init(a);
        for ((try listingsOf(a, o.*)).items) |l| if (!std.mem.eql(u8, l.string, opts.listing)) try kept.append(l);
        try o.put(a, "listings", .{ .array = kept });
        try o.put(a, "stale", .{ .bool = true });
    }
}

fn listingsOf(a: Allocator, o: ObjectMap) Allocator.Error!std.json.Array {
    var arr = std.json.Array.init(a);
    const v = o.get("listings") orelse return arr;
    if (v != .array) return arr;
    for (v.array.items) |l| if (l == .string) try arr.append(l);
    return arr;
}

fn hasListing(o: ObjectMap, listing: []const u8) bool {
    const v = o.get("listings") orelse return false;
    if (v != .array) return false;
    for (v.array.items) |l| if (l == .string and std.mem.eql(u8, l.string, listing)) return true;
    return false;
}

fn pinned(kind: Kind, o: ObjectMap) bool {
    return kind == .release and str(o, "role").len > 0;
}

/// Drop what is past the kind's age, then keep the newest `keep` (per
/// repo for pipelines); pinned releases always stay.
fn evict(f: *File, now: i64) void {
    const b = bounds(f.kind);
    const kind = f.kind;
    var n: usize = 0;
    for (f.records.items) |o| {
        if (!pinned(kind, o)) if (b.max_age_secs) |age| if (now - int(o, "seen_at") > age) continue;
        f.records.items[n] = o;
        n += 1;
    }
    f.records.shrinkRetainingCapacity(n);
    std.mem.sort(ObjectMap, f.records.items, kind, newerFirst);
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    var fba_buf: [16 << 10]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    n = 0;
    var unpinned: usize = 0;
    for (f.records.items) |o| {
        if (!pinned(kind, o)) {
            if (b.per_repo) {
                const id = str(o, "id");
                const repo = id[0 .. std.mem.indexOfScalar(u8, id, '!') orelse id.len];
                const gop = counts.getOrPut(fba.allocator(), repo) catch null;
                if (gop) |g| {
                    if (!g.found_existing) g.value_ptr.* = 0;
                    if (g.value_ptr.* >= b.keep) continue;
                    g.value_ptr.* += 1;
                }
            } else {
                if (unpinned >= b.keep) continue;
                unpinned += 1;
            }
        }
        f.records.items[n] = o;
        n += 1;
    }
    f.records.shrinkRetainingCapacity(n);
}

/// Pinned first, then newest `seen_at`.
fn newerFirst(kind: Kind, x: ObjectMap, y: ObjectMap) bool {
    const px = pinned(kind, x);
    const py = pinned(kind, y);
    if (px != py) return px;
    return int(x, "seen_at") > int(y, "seen_at");
}

/// The file's JSON, under `write_cap`: the oldest unpinned records go
/// until it fits (records are newest first by now).
fn render(a: Allocator, f: *File) Allocator.Error![]u8 {
    const head = try std.fmt.allocPrint(a, "{{\"version\":{d},\"source\":{f},\"kind\":\"{s}\",\"fresh_at\":{d},\"error_at\":{d},\"stale_after_secs\":{d},\"records\":[", .{
        format_version, std.json.fmt(f.source, .{}), @tagName(f.kind), f.fresh_at, f.error_at, f.stale_after_secs,
    });
    const tail = "\n]}\n";
    const bodies = try a.alloc([]u8, f.records.items.len);
    var total = head.len + tail.len;
    for (f.records.items, bodies) |o, *b| {
        b.* = try std.json.Stringify.valueAlloc(a, Value{ .object = o }, .{});
        total += b.len + 2;
    }
    var keep = bodies.len;
    while (total > write_cap and keep > 0) {
        // The last unpinned one is the oldest.
        var i = keep;
        while (i > 0 and pinned(f.kind, f.records.items[i - 1])) i -= 1;
        if (i == 0) break;
        total -= bodies[i - 1].len + 2;
        _ = f.records.orderedRemove(i - 1);
        std.mem.copyForwards([]u8, bodies[i - 1 .. keep - 1], bodies[i..keep]);
        keep -= 1;
    }
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.writeAll(head) catch return error.OutOfMemory;
    for (bodies[0..keep], 0..) |b, i| {
        w.writeAll(if (i == 0) "\n " else ",\n ") catch return error.OutOfMemory;
        w.writeAll(b) catch return error.OutOfMemory;
    }
    w.writeAll(tail) catch return error.OutOfMemory;
    return out.written();
}

// ─── reading ────────────────────────────────────────────────────────────

/// One record as a reader sees it: the typed fields, where it came
/// from, when it was last seen, and whether to trust it as current.
pub fn Found(comptime T: type) type {
    return struct {
        record: T,
        source: []const u8,
        seen_at: i64,
        /// The record's own flag, or its file gone stale (`File.staleAt`).
        stale: bool,
    };
}

/// A record object as `T`; strings borrowed from the parsed file.
pub fn decode(comptime T: type, a: Allocator, o: ObjectMap) Allocator.Error!T {
    var out: T = .{ .id = str(o, "id") };
    inline for (compat.fields(T)) |fld| {
        if (comptime std.mem.eql(u8, fld.name, "id")) continue;
        switch (fld.type) {
            []const u8 => @field(out, fld.name) = str(o, fld.name),
            bool => @field(out, fld.name) = flag(o, fld.name),
            []const []const u8 => {
                var list: std.ArrayList([]const u8) = .empty;
                if (o.get(fld.name)) |v| if (v == .array) for (v.array.items) |s| if (s == .string) try list.append(a, s.string);
                @field(out, fld.name) = list.items;
            },
            else => @compileError("unsupported field"),
        }
    }
    return out;
}

/// The records of one file as a reader keeps them: past the kind's age
/// dropped, staleness computed. On `a`.
pub fn foundIn(comptime kind: Kind, a: Allocator, f: File, now: i64) Allocator.Error![]Found(kind.Record()) {
    const b = bounds(kind);
    var out: std.ArrayList(Found(kind.Record())) = .empty;
    const file_stale = f.staleAt(now);
    for (f.records.items) |o| {
        const seen = int(o, "seen_at");
        if (!pinned(kind, o)) if (b.max_age_secs) |age| if (now - seen > age) continue;
        try out.append(a, .{
            .record = try decode(kind.Record(), a, o),
            .source = f.source,
            .seen_at = seen,
            .stale = flag(o, "stale") or file_stale,
        });
    }
    return out.items;
}

/// Every source's file of `kind` under `root`. On `a`.
pub fn readAll(comptime kind: Kind, a: Allocator, io: Io, root: []const u8, now: i64) []Found(kind.Record()) {
    var out: std.ArrayList(Found(kind.Record())) = .empty;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const path = filePath(a, root, e.name, kind) catch continue;
        const f = readFile(a, io, path) orelse continue;
        if (f.kind != kind) continue;
        out.appendSlice(a, foundIn(kind, a, f, now) catch continue) catch {};
    }
    return out.items;
}

/// The record with this id, newest `seen_at` across sources. On `a`.
pub fn get(comptime kind: Kind, a: Allocator, io: Io, env: *const Map, id: []const u8) ?Found(kind.Record()) {
    const root = (rootDir(a, env) catch return null) orelse return null;
    return getAt(kind, a, io, root, id, nowSecs(io));
}

pub fn getAt(comptime kind: Kind, a: Allocator, io: Io, root: []const u8, id: []const u8, now: i64) ?Found(kind.Record()) {
    var best: ?Found(kind.Record()) = null;
    for (readAll(kind, a, io, root, now)) |r| {
        if (!std.mem.eql(u8, r.record.id, id)) continue;
        if (best == null or r.seen_at > best.?.seen_at) best = r;
    }
    return best;
}

/// A filter on the fixed fields — not a text search.
pub const Query = struct {
    source: []const u8 = "",
    /// The id before `#` / `!` (`acme/widget`) or before `-` (`ACME`).
    repo: []const u8 = "",
    /// `state` for a PR, pipeline or release; `status` for a ticket.
    state: []const u8 = "",
    /// Seen within this many seconds; 0 is any age.
    since_secs: i64 = 0,
    /// 0 is no limit.
    limit: usize = 0,
};

/// The matching records, newest `seen_at` first. On `a`.
pub fn query(comptime kind: Kind, a: Allocator, io: Io, env: *const Map, q: Query) []Found(kind.Record()) {
    const root = (rootDir(a, env) catch return &.{}) orelse return &.{};
    return queryAt(kind, a, io, root, q, nowSecs(io));
}

pub fn queryAt(comptime kind: Kind, a: Allocator, io: Io, root: []const u8, q: Query, now: i64) []Found(kind.Record()) {
    const all = readAll(kind, a, io, root, now);
    var n: usize = 0;
    for (all) |r| {
        if (q.source.len > 0 and !std.mem.eql(u8, r.source, q.source)) continue;
        if (q.since_secs > 0 and now - r.seen_at > q.since_secs) continue;
        if (q.repo.len > 0) {
            const id = r.record.id;
            const cut = std.mem.indexOfAny(u8, id, if (kind == .ticket) "-" else "#!/") orelse id.len;
            const repo = if (kind == .ticket or kind == .release) id[0..cut] else id[0 .. std.mem.indexOfAny(u8, id, "#!") orelse id.len];
            if (!std.mem.eql(u8, repo, q.repo)) continue;
        }
        if (q.state.len > 0) {
            const st = if (kind == .ticket) r.record.status else r.record.state;
            if (!std.ascii.eqlIgnoreCase(st, q.state)) continue;
        }
        all[n] = r;
        n += 1;
    }
    const out = all[0..n];
    std.mem.sort(Found(kind.Record()), out, {}, struct {
        fn lt(_: void, x: Found(kind.Record()), y: Found(kind.Record())) bool {
            return x.seen_at > y.seen_at;
        }
    }.lt);
    return if (q.limit > 0 and out.len > q.limit) out[0..q.limit] else out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Scratch = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Scratch {
        var tmp = t.tmpDir(.{});
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
        return .{ .tmp = tmp, .root = try std.fs.path.join(t.allocator, &.{ dir, "recent" }) };
    }
    fn deinit(s: *Scratch) void {
        t.allocator.free(s.root);
        s.tmp.cleanup();
    }
    fn read(s: *Scratch, a: Allocator) !File {
        const p = try filePath(a, s.root, "jira", .ticket);
        return readFile(a, t.io, p) orelse error.NoFile;
    }
};

const login: Ticket = .{ .id = "ACME-123", .summary = "Fix the login redirect", .status = "In Review", .status_category = "indeterminate", .assignee = "Pat Example", .priority = "High", .type = "Bug", .fix_versions = &.{"2026.10"}, .updated = "2026-10-01T09:12:00.000+0000" };
const basket: Ticket = .{ .id = "ACME-124", .summary = "Basket total", .status = "To Do" };

test "put merges by id and get reads it back, typed, with its source and seen_at" {
    var s = try Scratch.init();
    defer s.deinit();
    try t.expectEqual(Outcome.written, putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .complete = true, .now = 1000 }, &[_]Ticket{ login, basket }));
    // The same id again, moved: one record, the new status.
    var moved = login;
    moved.status = "Done";
    try t.expectEqual(Outcome.written, putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "qa_actionable", .now = 1100 }, &[_]Ticket{moved}));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try s.read(a);
    try t.expectEqual(@as(usize, 2), f.records.items.len);
    try t.expectEqual(@as(i64, 1100), f.fresh_at);
    const got = getAt(.ticket, a, t.io, s.root, "ACME-123", 1200).?;
    try t.expectEqualStrings("Done", got.record.status);
    try t.expectEqualStrings("Fix the login redirect", got.record.summary);
    try t.expectEqualStrings("Pat Example", got.record.assignee);
    try t.expectEqualStrings("2026.10", got.record.fix_versions[0]);
    try t.expectEqualStrings("jira", got.source);
    try t.expectEqual(@as(i64, 1100), got.seen_at);
    try t.expect(!got.stale);
    // Both listings it came back in.
    const ls = f.records.items[0].get("listings").?.array.items;
    try t.expectEqual(@as(usize, 2), ls.len);
    try t.expect(getAt(.ticket, a, t.io, s.root, "ACME-999", 1200) == null);
}

test "a complete listing marks a record it no longer names stale, never deletes it; seeing it again clears the flag" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .complete = true, .now = 1000 }, &[_]Ticket{ login, basket });
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .complete = true, .now = 1010 }, &[_]Ticket{basket});
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gone = getAt(.ticket, a, t.io, s.root, "ACME-123", 1020).?;
    try t.expect(gone.stale);
    try t.expectEqualStrings("Fix the login redirect", gone.record.summary);
    try t.expect(!getAt(.ticket, a, t.io, s.root, "ACME-124", 1020).?.stale);
    // An incomplete listing (a delta) says nothing about absence.
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .now = 1030 }, &[_]Ticket{});
    try t.expect(!getAt(.ticket, a, t.io, s.root, "ACME-124", 1040).?.stale);
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .complete = true, .now = 1050 }, &[_]Ticket{login});
    try t.expect(!getAt(.ticket, a, t.io, s.root, "ACME-123", 1060).?.stale);
}

test "failed moves error_at only, and the reader then calls every record stale; so does a file past stale_after_secs" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .stale_after_secs = 600, .now = 1000 }, &[_]Ticket{login});
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(!getAt(.ticket, a, t.io, s.root, "ACME-123", 1500).?.stale);
    try t.expect(getAt(.ticket, a, t.io, s.root, "ACME-123", 1700).?.stale);
    try t.expectEqual(Outcome.written, failedAt(t.allocator, t.io, s.root, "jira", .ticket, 1100));
    const f = try s.read(a);
    try t.expectEqual(@as(i64, 1000), f.fresh_at);
    try t.expectEqual(@as(i64, 1100), f.error_at);
    try t.expectEqual(@as(usize, 1), f.records.items.len);
    try t.expect(getAt(.ticket, a, t.io, s.root, "ACME-123", 1200).?.stale);
}

test "fields a newer writer added survive this one's rewrite" {
    var s = try Scratch.init();
    defer s.deinit();
    const path = try filePath(t.allocator, s.root, "jira", .ticket);
    defer t.allocator.free(path);
    try Io.Dir.cwd().createDirPath(t.io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data =
        \\{"version":1,"source":"jira","kind":"ticket","fresh_at":900,"error_at":0,"stale_after_secs":1800,
        \\ "records":[{"id":"ACME-123","seen_at":900,"stale":false,"summary":"old","sprint":"Sprint 9"}]}
    });
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1000 }, &[_]Ticket{login});
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const f = try s.read(arena.allocator());
    try t.expectEqualStrings("Sprint 9", str(f.records.items[0], "sprint"));
    try t.expectEqualStrings("Fix the login redirect", str(f.records.items[0], "summary"));
}

test "eviction: tickets past 30 days go, and past 1000 the oldest go first" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_now: i64 = 1_000_000;
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = old_now }, &[_]Ticket{login});
    const recs = try a.alloc(Ticket, 1001);
    for (recs, 0..) |*r, i| r.* = .{ .id = try std.fmt.allocPrint(a, "ACME-{d}", .{1000 + i}), .summary = "x" };
    // The first batch is older than the second by a second.
    const now = old_now + 31 * 86400;
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = now }, recs[0..1]);
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = now + 1 }, recs[1..]);
    const f = try s.read(a);
    try t.expectEqual(@as(usize, 1000), f.records.items.len);
    try t.expect(indexOf(&f, "ACME-123") == null); // past its age
    try t.expect(indexOf(&f, "ACME-1000") == null); // the oldest of the rest
    try t.expect(indexOf(&f, "ACME-2000") != null);
}

test "the write cap drops the oldest until the file fits; a reader refuses a file over the read limit" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, 4000);
    @memset(big, 'x');
    const recs = try a.alloc(Ticket, 800);
    for (recs, 0..) |*r, i| r.* = .{ .id = try std.fmt.allocPrint(a, "ACME-{d}", .{i}), .summary = big };
    for (recs, 0..) |r, i| _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1000 + @as(i64, @intCast(i)) }, &[_]Ticket{r});
    const path = try filePath(a, s.root, "jira", .ticket);
    const st = try Io.Dir.cwd().statFile(t.io, path, .{});
    try t.expect(st.size <= write_cap);
    const f = try s.read(a);
    try t.expect(f.records.items.len < 800 and f.records.items.len > 400);
    try t.expect(indexOf(&f, "ACME-799") != null);
    try t.expect(indexOf(&f, "ACME-0") == null);
    // Over the read limit: empty, not an error.
    const huge = try a.alloc(u8, read_limit + 10);
    @memset(huge, ' ');
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = huge });
    try t.expect(readFile(a, t.io, path) == null);
    try t.expect(getAt(.ticket, a, t.io, s.root, "ACME-799", 2000) == null);
}

test "a held lock is a skipped write after the timeout, never a wait; the file is untouched" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var s = try Scratch.init();
    defer s.deinit();
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1000 }, &[_]Ticket{login});
    const lock_path = try std.fmt.allocPrint(t.allocator, "{s}/jira/ticket.lock", .{s.root});
    defer t.allocator.free(lock_path);
    const held = try Io.Dir.cwd().createFile(t.io, lock_path, .{ .read = true, .truncate = false, .lock = .exclusive });
    try t.expectEqual(Outcome.locked, putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 2000, .lock_timeout_ms = 100 }, &[_]Ticket{basket}));
    held.close(t.io);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(usize, 1), (try s.read(arena.allocator())).records.items.len);
    try t.expectEqual(Outcome.written, putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 2000, .lock_timeout_ms = 100 }, &[_]Ticket{basket}));
}

test "the write is a temp file renamed over the old one, 0600, with no temp file left behind" {
    var s = try Scratch.init();
    defer s.deinit();
    const path = try filePath(t.allocator, s.root, "jira", .ticket);
    defer t.allocator.free(path);
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1000 }, &[_]Ticket{login});
    // A reader holding the old file's handle still reads the old whole
    // file after the write: a rename, not an in-place rewrite.
    const before = try Io.Dir.cwd().openFile(t.io, path, .{});
    defer before.close(t.io);
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1100 }, &[_]Ticket{ login, basket });
    var buf: [4096]u8 = undefined;
    const n = try before.readPositionalAll(t.io, &buf, 0);
    try t.expect(std.mem.indexOf(u8, buf[0..n], "ACME-124") == null);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(usize, 2), (try s.read(arena.allocator())).records.items.len);
    var dir = try Io.Dir.cwd().openDir(t.io, std.fs.path.dirname(path).?, .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    while (try it.next(t.io)) |e| try t.expect(std.mem.indexOf(u8, e.name, ".tmp.") == null);
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

/// The platform's separator: the paths under test are joined, so a test
/// spells its expectation with it.
const sep = std.fs.path.sep_str;

test "the directory: the shared state dir, then the data root, then ~/.config/mnml; MNML_RECENT_ITEMS=0 writes nothing" {
    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/h");
    const p1 = (try rootDir(t.allocator, &env)).?;
    defer t.allocator.free(p1);
    try t.expectEqualStrings("/h" ++ sep ++ ".config" ++ sep ++ "mnml" ++ sep ++ "recent", p1);
    try env.put("MNML_DATA_ROOT", "/d");
    const p2 = (try rootDir(t.allocator, &env)).?;
    defer t.allocator.free(p2);
    try t.expectEqualStrings("/d" ++ sep ++ "recent", p2);
    try env.put("MNML_SHARED_STATE_DIR", "/s");
    const p3 = (try rootDir(t.allocator, &env)).?;
    defer t.allocator.free(p3);
    try t.expectEqualStrings("/s" ++ sep ++ "recent", p3);
    try env.put("MNML_RECENT_ITEMS", "0");
    try t.expectEqual(Outcome.disabled, put(t.allocator, t.io, &env, .{ .source = "jira", .kind = .ticket }, &[_]Ticket{login}));
}

test "query filters on the fixed fields, newest first, and a source name cannot climb out of the directory" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1000 }, &[_]Ticket{login});
    _ = putAt(t.allocator, t.io, s.root, .{ .source = "jira", .kind = .ticket, .now = 1100 }, &[_]Ticket{basket});
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = queryAt(.ticket, a, t.io, s.root, .{ .repo = "ACME" }, 1200);
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings("ACME-124", all[0].record.id);
    try t.expectEqual(@as(usize, 1), queryAt(.ticket, a, t.io, s.root, .{ .state = "in review" }, 1200).len);
    try t.expectEqual(@as(usize, 1), queryAt(.ticket, a, t.io, s.root, .{ .since_secs = 150 }, 1200).len);
    try t.expectEqual(@as(usize, 1), queryAt(.ticket, a, t.io, s.root, .{ .limit = 1 }, 1200).len);
    const p = try filePath(a, "/r", "../x", .ticket);
    try t.expectEqualStrings("/r" ++ sep ++ "_" ++ sep ++ "ticket.json", p);
}
