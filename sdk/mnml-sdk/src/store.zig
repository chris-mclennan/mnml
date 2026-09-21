//! What an integration already knows, kept between runs.
//!
//! A pane that asks the server for everything every time is slow for
//! the same reason every time: the budget. `<data root>/cache/<service>/`
//! holds what the last run learned, each entry under the SERVER's own
//! idea of when the thing last changed:
//!
//! ```
//! {"version":1,"entries":[
//!   {"key":"ENG-2","stamp":"2026-09-15T08:30:00.000+0000","fetched_at":1789526218,"body":"{…}"}
//! ]}
//! ```
//!
//! `stamp` is Jira's `updated` / Bitbucket's `updated_on` — whatever
//! the API moves when anything about the thing moves. A caller that
//! has the stamp from a cheap listing can answer `fresh(key, stamp)`
//! without a request at all; that is the whole mechanism, and it is
//! why the listing is worth one request and the detail is not worth
//! twenty-five.
//!
//! `fetched_at` is ours, for the `as of 2m ago` a pane paints while it
//! revalidates, and for the eviction that keeps the file bounded.
//!
//! **A cache is a hint.** Every read failure, parse failure and write
//! failure here is silent and costs a request. It must never be the
//! reason a pane does not paint, and it must never hand back something
//! the server has since changed — which is what keying on the server's
//! own stamp buys.
//!
//! Nothing secret goes in: a body is a response an integration already
//! holds in memory, and the file sits under the data root with the
//! rest of the state. A response that carried a credential would be a
//! bug at the other end.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Entries kept per file. Past it the oldest `fetched_at` goes, so a
/// long-lived cache tracks the working set rather than growing.
pub const max_entries: usize = 2000;
/// The biggest cache file read back.
pub const max_bytes: usize = 32 * 1024 * 1024;

pub const Entry = struct {
    /// The thing's id — a ticket key, a `workspace/repo/id`.
    key: []const u8,
    /// The SERVER's stamp for it. Empty means "no stamp was known",
    /// which can only ever be revalidated, never trusted.
    stamp: []const u8 = "",
    /// Unix seconds when this was fetched.
    fetched_at: i64 = 0,
    /// The response, verbatim.
    body: []const u8 = "",
};

/// One named cache — `<data root>/cache/<service>/<name>.json`.
pub const Store = struct {
    /// Owns every string in `entries` and `path`.
    arena: std.heap.ArenaAllocator,
    io: Io,
    path: []const u8 = "",
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Answers off the file, and answers that cost a request — what a
    /// test asserts and what `--diag` prints.
    hits: u32 = 0,
    misses: u32 = 0,
    /// Set by any `put`; `save` is a no-op without it.
    dirty: bool = false,

    /// Read the cache for `name` under `<root>/cache/<service>`. Never
    /// fails: a cache that cannot be read is a cache that costs
    /// requests, not an error.
    pub fn open(gpa: Allocator, io: Io, root: []const u8, service: []const u8, name: []const u8) Allocator.Error!Store {
        // Every allocation goes through THIS arena before it moves into
        // the returned struct: an `ArenaAllocator`'s `allocator()` binds
        // to the address it was taken from, so a local one copied into
        // a field leaks everything allocated before the copy.
        var s: Store = .{ .arena = std.heap.ArenaAllocator.init(gpa), .io = io };
        const a = s.arena.allocator();
        s.path = try std.fmt.allocPrint(a, "{s}/cache/{s}/{s}.json", .{ root, service, name });
        const text = Io.Dir.cwd().readFileAlloc(io, s.path, a, .limited(max_bytes)) catch return s;
        s.parse(text) catch {};
        return s;
    }

    /// A store at an explicit file — what a test uses, so nothing ever
    /// writes into the user's real data root.
    pub fn openAt(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!Store {
        var s: Store = .{ .arena = std.heap.ArenaAllocator.init(gpa), .io = io };
        const a = s.arena.allocator();
        s.path = try a.dupe(u8, path);
        const text = Io.Dir.cwd().readFileAlloc(io, s.path, a, .limited(max_bytes)) catch return s;
        s.parse(text) catch {};
        return s;
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn parse(self: *Store, text: []const u8) !void {
        const a = self.arena.allocator();
        const File = struct { version: u32 = 1, entries: []const Entry = &.{} };
        const parsed = try std.json.parseFromSliceLeaky(File, a, text, .{ .ignore_unknown_fields = true });
        for (parsed.entries) |e| {
            if (e.key.len == 0) continue;
            try self.entries.append(a, e);
        }
    }

    /// The entry for `key`. **Every slice in it lives on the store's
    /// own arena**, so it is good for exactly as long as the `Store`
    /// is: a caller that keeps one past `deinit` has this file's
    /// lifetime rule backwards. `fresh` and `stale` hand back the same
    /// borrow.
    pub fn get(self: *const Store, key: []const u8) ?Entry {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }

    /// The body for `key` when the cache holds it under exactly
    /// `stamp` — the server's own word that nothing has changed. An
    /// empty `stamp` never matches: "no stamp" is not "unchanged".
    pub fn fresh(self: *Store, key: []const u8, stamp: []const u8) ?[]const u8 {
        if (stamp.len == 0) {
            self.misses += 1;
            return null;
        }
        const e = self.get(key) orelse {
            self.misses += 1;
            return null;
        };
        if (!std.mem.eql(u8, e.stamp, stamp)) {
            self.misses += 1;
            return null;
        }
        self.hits += 1;
        return e.body;
    }

    /// What the cache holds for `key` whatever its stamp — what a pane
    /// paints on open while it revalidates behind the paint. `null`
    /// when there is nothing at all; the entry carries `fetched_at`,
    /// so the header can say how old it is.
    pub fn stale(self: *const Store, key: []const u8) ?Entry {
        return self.get(key);
    }

    /// Record a body. Replaces the entry for `key` if there is one.
    pub fn put(self: *Store, key: []const u8, stamp: []const u8, body: []const u8, now: i64) Allocator.Error!void {
        const a = self.arena.allocator();
        const e: Entry = .{
            .key = try a.dupe(u8, key),
            .stamp = try a.dupe(u8, stamp),
            .fetched_at = now,
            .body = try a.dupe(u8, body),
        };
        for (self.entries.items) |*old| if (std.mem.eql(u8, old.key, key)) {
            old.* = e;
            self.dirty = true;
            return;
        };
        try self.entries.append(a, e);
        self.dirty = true;
    }

    /// Drop every entry whose key is not in `keep` — what a refresh
    /// does with the ids the listing came back with, so the file
    /// tracks the open set rather than growing forever.
    pub fn retain(self: *Store, keep: []const []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const k = self.entries.items[i].key;
            var found = false;
            for (keep) |want| if (std.mem.eql(u8, want, k)) {
                found = true;
            };
            if (found) {
                i += 1;
            } else {
                _ = self.entries.orderedRemove(i);
                self.dirty = true;
            }
        }
    }

    /// Write the file. Best effort: a cache that cannot be written is
    /// a cache that costs requests next time, not an error.
    pub fn save(self: *Store) void {
        if (!self.dirty) return;
        self.evict();
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var out: Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        w.writeAll("{\"version\":1,\"entries\":[") catch return;
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) w.writeByte(',') catch return;
            w.writeAll("{\"key\":") catch return;
            writeJsonString(w, e.key) catch return;
            w.writeAll(",\"stamp\":") catch return;
            writeJsonString(w, e.stamp) catch return;
            w.print(",\"fetched_at\":{d},\"body\":", .{e.fetched_at}) catch return;
            writeJsonString(w, e.body) catch return;
            w.writeAll("}") catch return;
        }
        w.writeAll("]}\n") catch return;
        if (std.fs.path.dirname(self.path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = out.written() }) catch return;
        self.dirty = false;
    }

    /// Oldest `fetched_at` first, down to `max_entries`.
    fn evict(self: *Store) void {
        if (self.entries.items.len <= max_entries) return;
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return a.fetched_at > b.fetched_at;
            }
        }.lt);
        self.entries.shrinkRetainingCapacity(max_entries);
    }
};

/// One JSON string, escaped as **JSON** — which is not what
/// `std.zig.fmtString` does. Public because `warm.zig`'s lock file had
/// the same confusion and now writes through this.
///
/// That was the bug this replaced: the file is JSON and the bodies were
/// escaped for a Zig literal, so a response carrying an apostrophe or a
/// control byte produced `\\'` or `\\x1b`, neither of which any JSON
/// parser will read. The cache then failed to load **silently**, which
/// is exactly the failure this module promises costs requests rather
/// than correctness — so it cost requests, every run, and nothing said
/// so.
pub fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        // Everything else below a space has to go out as \u00XX; the
        // bytes above are UTF-8 continuation bytes and pass through.
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// `42s` / `7m` / `4h` / `3d` before now — the `as of …` a pane paints
/// while it revalidates. Written into `buf`.
pub fn ageText(buf: []u8, fetched_at: i64, now: i64) []const u8 {
    const d = now - fetched_at;
    if (fetched_at <= 0 or d < 0) return "";
    if (d < 90) return std.fmt.bufPrint(buf, "{d}s", .{d}) catch "";
    if (d < 5400) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(d, 60)}) catch "";
    if (d < 172800) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(d, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(d, 86400)}) catch "";
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the server's own stamp decides: the same one is a hit, a moved one is a miss, no stamp is never a hit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "cache", "jira", "dev-status.json" });
    defer t.allocator.free(path);

    var s = try Store.openAt(t.allocator, t.io, path);
    defer s.deinit();
    try t.expect(s.fresh("ENG-2", "2026-09-15T08:30:00.000+0000") == null);
    try t.expectEqual(@as(u32, 1), s.misses);

    try s.put("ENG-2", "2026-09-15T08:30:00.000+0000", "{\"detail\":[{\"pullRequests\":[]}]}", 1789526218);
    // The stamp the listing already carried answers without a request.
    try t.expectEqualStrings("{\"detail\":[{\"pullRequests\":[]}]}", s.fresh("ENG-2", "2026-09-15T08:30:00.000+0000").?);
    try t.expectEqual(@as(u32, 1), s.hits);
    // The ticket moved: what is held is not what the server has.
    try t.expect(s.fresh("ENG-2", "2026-09-16T09:00:00.000+0000") == null);
    // "No stamp" is not "unchanged" — it can only ever be revalidated.
    try t.expect(s.fresh("ENG-2", "") == null);
    // But it is still paintable while that happens.
    try t.expectEqualStrings("{\"detail\":[{\"pullRequests\":[]}]}", s.stale("ENG-2").?.body);
    try t.expectEqual(@as(i64, 1789526218), s.stale("ENG-2").?.fetched_at);
    try t.expect(s.stale("ENG-999") == null);
}

test "a cache survives the run that wrote it, and a broken file costs requests rather than failing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "cache", "jira", "dev-status.json" });
    defer t.allocator.free(path);
    {
        var s = try Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        // A body with quotes and a newline in it: the file has to
        // round-trip a response, not a tidy fixture.
        try s.put("ENG-2", "s1", "{\"a\":\"b\\\"c\"}\n", 100);
        try s.put("ENG-5", "s2", "[]", 200);
        s.save();
        // A save with nothing new is not a rewrite.
        try t.expect(!s.dirty);
    }
    {
        var s = try Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        try t.expectEqual(@as(usize, 2), s.entries.items.len);
        try t.expectEqualStrings("{\"a\":\"b\\\"c\"}\n", s.fresh("ENG-2", "s1").?);
        try t.expectEqualStrings("[]", s.fresh("ENG-5", "s2").?);
        try t.expectEqual(@as(i64, 200), s.stale("ENG-5").?.fetched_at);
        // The ids the listing no longer names drop out, so the file
        // tracks the working set rather than growing forever.
        s.retain(&.{"ENG-5"});
        try t.expectEqual(@as(usize, 1), s.entries.items.len);
        try t.expect(s.stale("ENG-2") == null);
        s.save();
    }
    {
        var s = try Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        try t.expectEqual(@as(usize, 1), s.entries.items.len);
    }
    // Nonsense on disk is an empty cache, not an error — this is the
    // thing that must never stop a pane painting.
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = "not json at all" });
    {
        var s = try Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        try t.expectEqual(@as(usize, 0), s.entries.items.len);
        try t.expect(s.fresh("ENG-5", "s2") == null);
    }
    // A path nobody can write is a cache that costs requests, silently.
    var nowhere = try Store.openAt(t.allocator, t.io, "/nonexistent-root/x/y.json");
    defer nowhere.deinit();
    try nowhere.put("k", "s", "b", 1);
    nowhere.save();
    try t.expectEqualStrings("b", nowhere.fresh("k", "s").?);
}

test "the age a pane paints while it revalidates" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("42s", ageText(&buf, 1000, 1042));
    try t.expectEqualStrings("7m", ageText(&buf, 1000, 1000 + 7 * 60));
    try t.expectEqualStrings("4h", ageText(&buf, 0 + 1, 1 + 4 * 3600));
    try t.expectEqualStrings("3d", ageText(&buf, 1, 1 + 3 * 86400));
    // Never fetched: nothing to say about its age.
    try t.expectEqualStrings("", ageText(&buf, 0, 1000));
}

test "the file is JSON, so a body is escaped as JSON — an apostrophe or a control byte must not lose the cache" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "etags.json" });
    defer t.allocator.free(path);

    // A response as they actually arrive: an apostrophe (which a Zig
    // escaper writes `\'`, and no JSON parser will read), a control
    // byte, a tab, a backslash, a quote, and some UTF-8.
    const body = "{\"msg\":\"Robin's PR \x01\tsays \\\"ship\\\" \u{2014} caf\u{e9}\"}";
    {
        var s = try Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        try s.put("u1", "\"tag-'1'\"", body, 100);
        s.save();
    }
    // The whole point: the next run reads it back. Before this was
    // fixed the parse failed silently and the cache was simply empty —
    // a cost that never showed up anywhere.
    {
        var s = try Store.openAt(t.allocator, t.io, path);
        defer s.deinit();
        try t.expectEqual(@as(usize, 1), s.entries.items.len);
        try t.expectEqualStrings(body, s.fresh("u1", "\"tag-'1'\"").?);
    }
    // And it really is JSON, not merely something this parser accepts:
    // the bytes below 0x20 are `\u00XX` and nothing is `\x`.
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\\u0001") != null);
    try t.expect(std.mem.indexOf(u8, text, "\\x") == null);
    try t.expect(std.mem.indexOf(u8, text, "\\'") == null);
}
