//! What the unresolved-comment count costs, and how it is kept down.
//!
//! The second figure on the Bitbucket chip is "review threads still
//! waiting on someone across my open pull requests". Getting it means
//! `GET …/pullrequests/{id}/comments` **per pull request** — one more
//! request each, every poll, on a bucket that refills at 0.22/s. With
//! a dozen open PRs that is a minute of the machine's whole Bitbucket
//! budget spent re-reading comment threads that did not change.
//!
//! Bitbucket already says what changed: a pull request's `updated_on`
//! moves when anything on it does, a comment included. So the count is
//! cached against it. A poll costs one comments request per pull
//! request whose `updated_on` differs from the cached one — O(changed
//! PRs), not O(all PRs) — and on a quiet morning, none at all.
//!
//! The file is `<config dir>/cache/pr-comments.json`, one line of JSON:
//!
//! ```
//! {"entries":[{"key":"acme/api/1198","updated_on":"2026-09-17T…","unresolved":2}]}
//! ```
//!
//! A pull request that is no longer open drops out on the next write,
//! so the file tracks the open set rather than growing forever. Nothing
//! in it is a secret — a count and a timestamp — but it lives under the
//! config dir with the rest.
//!
//! A cache is a hint: every read failure, parse failure and write
//! failure is silent and simply costs a request. It must never be the
//! reason a chip does not paint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "pr-comments.json";
pub const max_bytes = 1 << 20;
/// More open pull requests than one person has; past it the tail is not
/// cached rather than letting the file grow without bound.
pub const max_entries = 512;

pub const Entry = struct {
    /// `<workspace>/<repo>/<id>`.
    key: []const u8,
    /// The pull request's `updated_on` when the count was taken.
    updated_on: []const u8,
    unresolved: usize,
};

pub const Cache = struct {
    /// Everything borrows this.
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Counts answered off the file, and counts that cost a request —
    /// what `--values` prints when asked and what a test asserts.
    hits: u32 = 0,
    misses: u32 = 0,

    pub fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Read the file beside `config_path`, or an empty cache. Never
    /// fails: a cache that cannot be read is a cache that costs
    /// requests, not an error.
    pub fn open(gpa: Allocator, io: Io, config_path: []const u8) Allocator.Error!Cache {
        // Every allocation happens through THIS arena before it is
        // moved into the returned struct: an `ArenaAllocator`'s
        // `allocator()` binds to the address it was taken from, so an
        // allocation made through a copy's stale handle is a leak the
        // eventual `deinit` never reaches.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const parent = std.fs.path.dirname(config_path) orelse ".";
        const path = try std.fs.path.join(a, &.{ parent, "cache", file_name });
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes))) |text| {
            if (std.json.parseFromSliceLeaky(struct { entries: []const Entry = &.{} }, a, text, .{ .ignore_unknown_fields = true })) |parsed| {
                entries.appendSlice(a, parsed.entries) catch {};
            } else |_| {}
        } else |_| {}
        return .{ .arena = arena, .path = path, .entries = entries };
    }

    pub fn key(self: *Cache, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}/{d}", .{ workspace, repo, id });
    }

    /// The cached count for this pull request AT this `updated_on`. A
    /// pull request that has moved since is a miss, which is the whole
    /// mechanism.
    pub fn get(self: *Cache, k: []const u8, updated_on: []const u8) ?usize {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, k)) {
                if (updated_on.len > 0 and std.mem.eql(u8, e.updated_on, updated_on)) {
                    self.hits += 1;
                    return e.unresolved;
                }
                return null;
            }
        }
        return null;
    }

    pub fn put(self: *Cache, k: []const u8, updated_on: []const u8, unresolved: usize) Allocator.Error!void {
        self.misses += 1;
        const a = self.arena.allocator();
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, k)) {
                e.updated_on = try a.dupe(u8, updated_on);
                e.unresolved = unresolved;
                return;
            }
        }
        if (self.entries.items.len >= max_entries) return;
        try self.entries.append(a, .{ .key = try a.dupe(u8, k), .updated_on = try a.dupe(u8, updated_on), .unresolved = unresolved });
    }

    /// Write back only the keys still in `live`, so a merged pull
    /// request leaves the file instead of sitting in it forever.
    pub fn save(self: *Cache, io: Io, live: []const []const u8) void {
        if (std.fs.path.dirname(self.path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch return;
        var buf: std.Io.Writer.Allocating = .init(self.arena.child_allocator);
        defer buf.deinit();
        const w = &buf.writer;
        w.writeAll("{\"entries\":[") catch return;
        var n: usize = 0;
        for (self.entries.items) |e| {
            var kept = false;
            for (live) |l| if (std.mem.eql(u8, l, e.key)) {
                kept = true;
            };
            if (!kept) continue;
            if (n > 0) w.writeByte(',') catch return;
            n += 1;
            w.print("{{\"key\":\"{s}\",\"updated_on\":\"{s}\",\"unresolved\":{d}}}", .{ e.key, e.updated_on, e.unresolved }) catch return;
        }
        w.writeAll("]}\n") catch return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = buf.written() }) catch return;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "a count is answered off the file only while the pull request has not moved" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const config_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
    defer t.allocator.free(config_path);

    var c = try Cache.open(t.allocator, t.io, config_path);
    defer c.deinit();
    // Nothing cached yet: every pull request costs its request.
    const k = try c.key("acme", "api", 1198);
    try t.expect(c.get(k, "2026-09-17T10:00:00Z") == null);
    try c.put(k, "2026-09-17T10:00:00Z", 2);
    try t.expectEqual(@as(?usize, 2), c.get(k, "2026-09-17T10:00:00Z"));
    // A pull request that has moved is a miss, which is the point: its
    // comments may have.
    try t.expect(c.get(k, "2026-09-17T11:00:00Z") == null);
    // …and an unknown `updated_on` is never a hit, so a reply that
    // arrives cannot be missed by a stale count.
    try t.expect(c.get(k, "") == null);
    try t.expectEqual(@as(u32, 1), c.hits);

    // Across processes: what one run wrote, the next reads.
    const other = try c.key("acme", "web", 820);
    try c.put(other, "2026-09-16T09:00:00Z", 0);
    c.save(t.io, &.{ k, other });
    var again = try Cache.open(t.allocator, t.io, config_path);
    defer again.deinit();
    try t.expectEqual(@as(?usize, 2), again.get(try again.key("acme", "api", 1198), "2026-09-17T10:00:00Z"));
    try t.expectEqual(@as(?usize, 0), again.get(try again.key("acme", "web", 820), "2026-09-16T09:00:00Z"));

    // A pull request that is no longer open leaves the file.
    again.save(t.io, &.{other});
    var third = try Cache.open(t.allocator, t.io, config_path);
    defer third.deinit();
    try t.expectEqual(@as(usize, 1), third.entries.items.len);
    try t.expect(third.get(try third.key("acme", "api", 1198), "2026-09-17T10:00:00Z") == null);
}

test "a cache that cannot be read or parsed costs requests, never an error" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const config_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
    defer t.allocator.free(config_path);
    // No file at all.
    {
        var c = try Cache.open(t.allocator, t.io, config_path);
        defer c.deinit();
        try t.expectEqual(@as(usize, 0), c.entries.items.len);
    }
    // A file that is not the shape.
    try tmp.dir.createDirPath(t.io, "cache");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "cache/" ++ file_name, .data = "not json at all" });
    var c = try Cache.open(t.allocator, t.io, config_path);
    defer c.deinit();
    try t.expectEqual(@as(usize, 0), c.entries.items.len);
    try t.expect(c.get(try c.key("acme", "api", 1), "x") == null);
}
