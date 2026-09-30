//! The prefetch cache — one file per GET, so a pane can paint before
//! its first request comes back.
//!
//! Under the shared bucket (0.22 requests/s) a thirteen-repo tree takes
//! minutes, and for those minutes the reference paints nothing. The
//! answer here is the reference's `--prefetch` idea moved one step
//! down: `mnml-bitbucket --prefetch` walks the configured tabs on a
//! schedule of its own and writes every 2xx body it gets to
//! `<config dir>/cache/`. The pane, on open, serves each GET from that
//! directory **once** — the startup fetch lands instantly, off the
//! network — and goes to the API for everything after, so a refresh is
//! never stale and the bucket is never double-spent.
//!
//! One file per URL, named by the first sixteen bytes of its SHA-256,
//! with the URL and the time it was written in a header line so the
//! directory can be read by eye and a stale entry can be recognised
//! without a stat:
//!
//! ```
//! # 1789526218 https://api.bitbucket.org/2.0/repositories/acme?…
//! {"values":[…]}
//! ```
//!
//! Nothing here is a secret: the bodies are the same JSON the API
//! hands anyone holding the token, and the token is not in them. The
//! directory is still written under the config dir, which is private
//! to the machine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const dir_name = "cache";
pub const max_entry_bytes = 8 * 1024 * 1024;
/// A prefetch older than this is ignored: better one slow first paint
/// than yesterday's pull requests presented as today's.
pub const default_max_age_secs: i64 = 60 * 60;

pub const Mode = enum {
    /// Neither read nor written (`--check`, `--values`, the tests).
    off,
    /// `--prefetch`: every 2xx GET body is written.
    fill,
    /// The pane: each URL may be served from the cache once.
    prime,
};

pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    /// `<config dir>/cache`, owned.
    dir: []u8,
    mode: Mode = .off,
    max_age_secs: i64 = default_max_age_secs,
    /// URLs already served in `.prime`, so a refresh goes to the API.
    served: std.StringHashMapUnmanaged(void) = .empty,
    /// What `--prefetch` wrote / what the pane served, for the summary.
    writes: u32 = 0,
    hits: u32 = 0,

    pub fn init(gpa: Allocator, io: Io, config_path: []const u8, mode: Mode) Allocator.Error!Cache {
        const parent = std.fs.path.dirname(config_path) orelse ".";
        return .{ .gpa = gpa, .io = io, .dir = try std.fs.path.join(gpa, &.{ parent, dir_name }), .mode = mode };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.served.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.served.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.* = undefined;
    }

    /// `<dir>/<16 bytes of sha256(url), hex>.json`, owned by `gpa`.
    pub fn entryPath(self: *const Cache, gpa: Allocator, url: []const u8) Allocator.Error![]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        var name: [37]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "{x}.json", .{digest[0..16]}) catch unreachable;
        return std.fs.path.join(gpa, &.{ self.dir, &name });
    }

    /// The cached body for `url`, or null. Only in `.prime`, only once
    /// per URL, only while the entry is younger than `max_age_secs`.
    /// Owned by the caller.
    pub fn take(self: *Cache, gpa: Allocator, url: []const u8, now_secs: i64) Allocator.Error!?[]u8 {
        if (self.mode != .prime) return null;
        if (self.served.contains(url)) return null;
        const path = try self.entryPath(gpa, url);
        defer gpa.free(path);
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, gpa, .limited(max_entry_bytes)) catch return null;
        defer gpa.free(text);
        // Mark it served whatever the outcome: a corrupt or stale entry
        // must not be retried on the next request for the same URL.
        const key = try gpa.dupe(u8, url);
        errdefer gpa.free(key);
        try self.served.put(self.gpa, key, {});
        const parsed = split(text) orelse return null;
        if (!std.mem.eql(u8, parsed.url, url)) return null;
        if (now_secs - parsed.written_secs > self.max_age_secs) return null;
        if (now_secs < parsed.written_secs - 60) return null; // a clock that went backwards
        self.hits += 1;
        return try gpa.dupe(u8, parsed.body);
    }

    /// Write `body` for `url`. Only in `.fill`; a failure is silent,
    /// because a prefetch that cannot cache is still a warm bucket and
    /// never a reason to fail the run.
    pub fn put(self: *Cache, url: []const u8, body: []const u8, now_secs: i64) void {
        if (self.mode != .fill) return;
        if (body.len > max_entry_bytes) return;
        const gpa = self.gpa;
        const path = self.entryPath(gpa, url) catch return;
        defer gpa.free(path);
        Io.Dir.cwd().createDirPath(self.io, self.dir) catch return;
        const text = std.fmt.allocPrint(gpa, "# {d} {s}\n{s}", .{ now_secs, url, body }) catch return;
        defer gpa.free(text);
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = text }) catch return;
        self.writes += 1;
    }

    /// Drop every entry — what `--prefetch` does before a fresh pass so
    /// a repo that left the config cannot keep answering.
    pub fn clear(self: *Cache) void {
        Io.Dir.cwd().deleteTree(self.io, self.dir) catch {};
    }
};

pub const Entry = struct { written_secs: i64, url: []const u8, body: []const u8 };

/// `# <secs> <url>\n<body>` → its three parts, or null when the header
/// is not there.
pub fn split(text: []const u8) ?Entry {
    if (!std.mem.startsWith(u8, text, "# ")) return null;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    const head = text[2..nl];
    const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return null;
    const secs = std.fmt.parseInt(i64, head[0..sp], 10) catch return null;
    return .{ .written_secs = secs, .url = head[sp + 1 ..], .body = text[nl + 1 ..] };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn tmpCache(dir: []const u8, mode: Mode) Allocator.Error!Cache {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg_path = std.fmt.bufPrint(&buf, "{s}/config.zon", .{dir}) catch unreachable;
    return Cache.init(t.allocator, t.io, cfg_path, mode);
}

test "a filled entry primes one pane request and then steps aside for the refresh" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const url = "https://api.bitbucket.org/2.0/repositories/acme?pagelen=100";

    var fill = try tmpCache(dir, .fill);
    defer fill.deinit();
    fill.put(url, "{\"values\":[]}", 1000);
    try t.expectEqual(@as(u32, 1), fill.writes);
    // `.fill` never serves: a prefetch must not answer itself.
    try t.expect((try fill.take(t.allocator, url, 1000)) == null);

    var prime = try tmpCache(dir, .prime);
    defer prime.deinit();
    const first = (try prime.take(t.allocator, url, 1010)).?;
    defer t.allocator.free(first);
    try t.expectEqualStrings("{\"values\":[]}", first);
    try t.expectEqual(@as(u32, 1), prime.hits);
    // The second ask for the same URL is the refresh: it must go out.
    try t.expect((try prime.take(t.allocator, url, 1020)) == null);
    try t.expectEqual(@as(u32, 1), prime.hits);
    // A URL that was never filled is a miss, not an error.
    try t.expect((try prime.take(t.allocator, "https://x/none", 1020)) == null);
}

test "a stale entry, a clock that went backwards and `off` all decline to serve" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const url = "https://api.bitbucket.org/2.0/user";
    var fill = try tmpCache(dir, .fill);
    defer fill.deinit();
    fill.put(url, "{\"account_id\":\"acct-max\"}", 1000);

    {
        var prime = try tmpCache(dir, .prime);
        defer prime.deinit();
        prime.max_age_secs = 30;
        try t.expect((try prime.take(t.allocator, url, 1_000_000)) == null);
    }
    {
        var prime = try tmpCache(dir, .prime);
        defer prime.deinit();
        try t.expect((try prime.take(t.allocator, url, 100)) == null);
    }
    {
        var off = try tmpCache(dir, .off);
        defer off.deinit();
        try t.expect((try off.take(t.allocator, url, 1000)) == null);
        off.put(url, "{}", 1000);
        try t.expectEqual(@as(u32, 0), off.writes);
    }
    // `clear` is what a fresh prefetch does first.
    fill.clear();
    var prime = try tmpCache(dir, .prime);
    defer prime.deinit();
    try t.expect((try prime.take(t.allocator, url, 1000)) == null);
}

test "the header carries the url and the time, and a body that is not one is refused" {
    const e = split("# 1789526218 https://x/y\n{\"a\":1}").?;
    try t.expectEqual(@as(i64, 1789526218), e.written_secs);
    try t.expectEqualStrings("https://x/y", e.url);
    try t.expectEqualStrings("{\"a\":1}", e.body);
    try t.expect(split("{\"a\":1}") == null);
    try t.expect(split("# nonsense\n{}") == null);
    try t.expect(split("# 12") == null);
    // Two URLs never share a file.
    var c = try tmpCache("/tmp/nope", .off);
    defer c.deinit();
    const a = try c.entryPath(t.allocator, "https://x/a");
    defer t.allocator.free(a);
    const b = try c.entryPath(t.allocator, "https://x/b");
    defer t.allocator.free(b);
    try t.expect(!std.mem.eql(u8, a, b));
    try t.expect(std.mem.endsWith(u8, a, ".json"));
}

test "an entry whose header names a different url is not served (a hash collision is not a hit)" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var prime = try tmpCache(dir, .prime);
    defer prime.deinit();
    const url = "https://api.bitbucket.org/2.0/user";
    const path = try prime.entryPath(t.allocator, url);
    defer t.allocator.free(path);
    try Io.Dir.cwd().createDirPath(t.io, prime.dir);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = "# 1000 https://api.bitbucket.org/2.0/other\n{}" });
    try t.expect((try prime.take(t.allocator, url, 1000)) == null);
}
