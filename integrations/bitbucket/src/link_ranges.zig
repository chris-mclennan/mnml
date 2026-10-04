//! Which numbers each repo is using — what lets mnml link a bare
//! `Pull request 5505` or `pipeline 10554`, which names no repo.
//!
//! Every repo numbers its pull requests and its pipelines from 1, but a
//! workspace's repos sit at different heights: one is in the 5000s,
//! another in the 7000s. The table keeps, per repo and kind, the lowest
//! and highest number this integration has seen; mnml looks a bare
//! number up in it (the manifest's `.range` links) and adds its own
//! slack above the high, so a number opened since the last poll still
//! resolves.
//!
//! The `--values` poll feeds it — every pull request its listing
//! returns, and each repo's newest pipelines at most once an hour (one
//! request per repo, on a bucket that refills slowly) — and publishes
//! it whole over the IPC channel after each poll.
//!
//! The file is `<config dir>/cache/link-ranges.json`, so a restart
//! keeps the low watermark the open listing alone no longer shows. A
//! cache is a hint: every read or write failure is silent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

pub const file_name = "link-ranges.json";
pub const max_bytes = 1 << 20;
/// More repos × kinds than a workspace has; past it new rows are not kept.
pub const max_rows = 512;
/// How long a repo's pipeline numbers are trusted before the poll asks
/// again.
pub const pipeline_probe_secs: i64 = 3600;

pub const Row = struct {
    /// `<workspace>/<repo>`.
    repo: []const u8,
    /// `pr` / `pipeline`.
    kind: []const u8,
    low: u64,
    high: u64,
    /// When the poll last asked for this row's numbers itself (the
    /// pipeline probe); 0 for a row only listings fed.
    probed_at: i64 = 0,
};

pub const Table = struct {
    /// Everything borrows this.
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Read the file beside `config_path`, or an empty table. Never fails
    /// short of memory.
    pub fn open(gpa: Allocator, io: Io, config_path: []const u8) Allocator.Error!Table {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const parent = std.fs.path.dirname(config_path) orelse ".";
        const path = try std.fs.path.join(a, &.{ parent, "cache", file_name });
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes))) |text| {
            if (std.json.parseFromSliceLeaky(struct { rows: []const Row = &.{} }, a, text, .{ .ignore_unknown_fields = true })) |parsed| {
                for (parsed.rows) |r| {
                    if (rows.items.len >= max_rows) break;
                    if (r.repo.len == 0 or r.kind.len == 0 or r.low > r.high) continue;
                    rows.append(a, r) catch {};
                }
            } else |_| {}
        } else |_| {}
        return .{ .arena = arena, .path = path, .rows = rows };
    }

    fn find(self: *Table, repo: []const u8, kind: []const u8) ?*Row {
        for (self.rows.items) |*r| if (std.mem.eql(u8, r.repo, repo) and std.mem.eql(u8, r.kind, kind)) return r;
        return null;
    }

    /// Widen `repo`'s `kind` row to hold `n` — the low only ever falls,
    /// the high only ever rises. A zero is no number.
    pub fn observe(self: *Table, repo: []const u8, kind: []const u8, n: u64) Allocator.Error!void {
        if (n == 0 or repo.len == 0) return;
        if (self.find(repo, kind)) |r| {
            r.low = @min(r.low, n);
            r.high = @max(r.high, n);
            return;
        }
        if (self.rows.items.len >= max_rows) return;
        const a = self.arena.allocator();
        try self.rows.append(a, .{ .repo = try a.dupe(u8, repo), .kind = try a.dupe(u8, kind), .low = n, .high = n });
    }

    /// Whether the poll should ask for `repo`'s `kind` numbers itself:
    /// never asked, or asked more than `every` seconds ago.
    pub fn due(self: *Table, repo: []const u8, kind: []const u8, now: i64, every: i64) bool {
        const r = self.find(repo, kind) orelse return true;
        return now - r.probed_at >= every;
    }

    /// Stamp `repo`'s `kind` row as asked at `now` (made empty-handed
    /// when the answer had no numbers, so the next poll does not ask).
    pub fn probed(self: *Table, repo: []const u8, kind: []const u8, now: i64) Allocator.Error!void {
        if (self.find(repo, kind)) |r| {
            r.probed_at = now;
            return;
        }
        if (self.rows.items.len >= max_rows) return;
        const a = self.arena.allocator();
        try self.rows.append(a, .{ .repo = try a.dupe(u8, repo), .kind = try a.dupe(u8, kind), .low = 0, .high = 0, .probed_at = now });
    }

    /// The rows worth publishing: those with a number in them.
    pub fn published(self: *const Table, arena: Allocator) Allocator.Error![]const sdk.ipc.LinkRange {
        var out: std.ArrayListUnmanaged(sdk.ipc.LinkRange) = .empty;
        for (self.rows.items) |r| {
            if (r.high == 0) continue;
            try out.append(arena, .{ .repo = r.repo, .kind = r.kind, .low = r.low, .high = r.high });
        }
        return out.items;
    }

    /// Send the whole table to mnml for manifest `id`'s `.range` links.
    pub fn publish(self: *const Table, ipc: *const sdk.Ipc, arena: Allocator, id: []const u8) sdk.ipc.Error!void {
        try ipc.linkRanges(id, try self.published(arena));
    }

    pub fn save(self: *Table, io: Io) void {
        if (std.fs.path.dirname(self.path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch return;
        var buf: std.Io.Writer.Allocating = .init(self.arena.child_allocator);
        defer buf.deinit();
        std.json.Stringify.value(.{ .rows = self.rows.items }, .{}, &buf.writer) catch return;
        buf.writer.writeByte('\n') catch return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = buf.written() }) catch return;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the table widens per repo and kind, survives a reopen, and publishes only rows with a number" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const config_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
    defer t.allocator.free(config_path);
    {
        var tb = try Table.open(t.allocator, t.io, config_path);
        defer tb.deinit();
        try tb.observe("acme/widget", "pr", 5505);
        try tb.observe("acme/widget", "pr", 5490);
        try tb.observe("acme/widget", "pr", 5500);
        try tb.observe("acme/gadget", "pr", 7166);
        try tb.observe("acme/widget", "pr", 0);
        try t.expect(tb.due("acme/widget", "pipeline", 10_000, pipeline_probe_secs));
        try tb.probed("acme/widget", "pipeline", 10_000);
        try t.expect(!tb.due("acme/widget", "pipeline", 10_000 + 60, pipeline_probe_secs));
        try t.expect(tb.due("acme/widget", "pipeline", 10_000 + pipeline_probe_secs, pipeline_probe_secs));
        tb.save(t.io);
    }
    // A restart: the low the listing no longer shows is still there.
    var tb = try Table.open(t.allocator, t.io, config_path);
    defer tb.deinit();
    try tb.observe("acme/widget", "pr", 5512);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const rows = try tb.published(arena_state.allocator());
    // The probed pipeline row has no number yet: not published.
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("acme/widget", rows[0].repo);
    try t.expectEqual(@as(u64, 5490), rows[0].low);
    try t.expectEqual(@as(u64, 5512), rows[0].high);
    try t.expectEqualStrings("acme/gadget", rows[1].repo);
    try t.expect(!tb.due("acme/widget", "pipeline", 10_000 + 60, pipeline_probe_secs));
}
