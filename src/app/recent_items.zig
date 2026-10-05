//! The host's read of the shared recent-items cache (`sdk.cache`,
//! `docs/SDK.md` "Cache"): what the integrations last polled, so a link
//! to `ACME-123` can say what ACME-123 is. Read-only — the host never
//! writes the cache.
//!
//! A file is read again only when its mtime (or size) moves, looked at
//! on the stat tick (`refresh_cadence.stat_tick_off_ms`) — no read per
//! frame, no timer of its own, and none of it under `ui.dashboard_refresh
//! = manual` either way, since a local stat costs nothing.
//!
//! A link finds its record by the last path segment of its address —
//! `…/browse/ACME-123` is `ACME-123` — so a key a link rule matched and
//! an OSC 8 hyperlink to the same page both get it. The hover shows
//! `ACME-123 · Fix the login redirect · In Review`; a stale record keeps
//! its title and adds `as of 3h ago`. Nothing is painted inline.
//!
//! `recent_items.enabled = false` drops what was read and tells the
//! integrations mnml starts not to write (`MNML_RECENT_ITEMS=0`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const cache = sdk.cache;
const App = @import("../app.zig").App;
const refresh_cadence = @import("refresh_cadence.zig");
const pty_pane = @import("pty_pane.zig");
const Tip = @import("../ui/tooltip.zig").Tip;

pub const Entry = struct {
    ticket: cache.Ticket,
    source: []const u8,
    seen_at: i64,
    /// The record's own flag, or its file's last poll failed.
    flagged: bool,
    fresh_at: i64,
    stale_after_secs: i64,

    pub fn staleAt(e: Entry, now: i64) bool {
        return e.flagged or now - e.fresh_at > e.stale_after_secs;
    }
};

pub const State = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    tickets: std.StringHashMapUnmanaged(Entry) = .empty,
    /// What the files looked like at the last read: their names, mtimes
    /// and sizes, hashed.
    stamp: u64 = 0,
    last_check_ms: ?i64 = null,
    /// Reads since start — what a test reads to see an unmoved file was
    /// not read again.
    loads: u32 = 0,
    /// This set `MNML_RECENT_ITEMS=0` in the children's environment.
    env_set: bool = false,
    /// Tests pin the clock; null is the wall clock.
    now_secs: ?i64 = null,

    pub fn deinit(st: *State) void {
        st.arena.deinit();
        st.* = .{};
    }

    fn clear(st: *State) void {
        st.tickets = .empty;
        _ = st.arena.reset(.free_all);
        st.stamp = 0;
    }
};

fn nowSecs(app: *const App) i64 {
    return app.recent_items.now_secs orelse Io.Timestamp.now(app.io, .real).toSeconds();
}

/// The stat tick: read the files again when one moved.
pub fn tick(app: *App, now_ms: i64) void {
    const st = &app.recent_items;
    syncEnv(app);
    if (!app.cfg.recent_items.enabled) {
        if (st.stamp != 0) st.clear();
        return;
    }
    if (st.last_check_ms) |last| if (now_ms - last < refresh_cadence.stat_tick_off_ms) return;
    st.last_check_ms = now_ms;
    reloadIfMoved(app);
}

fn syncEnv(app: *App) void {
    const st = &app.recent_items;
    const on = app.cfg.recent_items.enabled;
    if (!on and !st.env_set) {
        app.env.put("MNML_RECENT_ITEMS", "0") catch return;
        st.env_set = true;
    } else if (on and st.env_set) {
        _ = app.env.swapRemove("MNML_RECENT_ITEMS");
        st.env_set = false;
    }
}

/// Stat every source's ticket file; read them all when any moved.
pub fn reloadIfMoved(app: *App) void {
    const st = &app.recent_items;
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const root = (cache.rootDir(sa, &app.env) catch return) orelse return;
    var h = std.hash.Wyhash.init(0);
    var files: std.ArrayList([]const u8) = .empty;
    if (Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |e| {
            if (e.kind != .directory) continue;
            const path = cache.filePath(sa, root, e.name, .ticket) catch continue;
            const stat = Io.Dir.cwd().statFile(app.io, path, .{}) catch continue;
            h.update(path);
            h.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            h.update(std.mem.asBytes(&stat.size));
            files.append(sa, path) catch continue;
        }
    } else |_| {}
    const stamp = h.final() | 1;
    if (files.items.len == 0) {
        if (st.stamp != 0) st.clear();
        return;
    }
    if (stamp == st.stamp) return;
    st.clear();
    st.stamp = stamp;
    st.loads += 1;
    const a = st.arena.allocator();
    for (files.items) |path| {
        const f = cache.readFile(a, app.io, path) orelse continue;
        if (f.kind != .ticket) continue;
        // Staleness by age is the reader's to decide at hover time, so
        // the records are taken as of the file's own last poll.
        const found = cache.foundIn(.ticket, a, f, f.fresh_at) catch continue;
        for (found) |r| {
            const e: Entry = .{
                .ticket = r.record,
                .source = r.source,
                .seen_at = r.seen_at,
                .flagged = r.stale,
                .fresh_at = f.fresh_at,
                .stale_after_secs = f.stale_after_secs,
            };
            const gop = st.tickets.getOrPut(a, r.record.id) catch continue;
            if (!gop.found_existing or gop.value_ptr.seen_at < e.seen_at) gop.value_ptr.* = e;
        }
    }
}

/// The record a link's address names — its last path segment.
pub fn forUrl(app: *const App, url: []const u8) ?Entry {
    if (!app.cfg.recent_items.enabled) return null;
    var end = url.len;
    if (std.mem.indexOfAny(u8, url, "?#")) |q| end = q;
    const path = std.mem.trimEnd(u8, url[0..end], "/");
    const seg = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1 ..];
    if (seg.len == 0) return null;
    return app.recent_items.tickets.get(seg);
}

/// `ACME-123 · Fix the login redirect · In Review`. On `arena`.
pub fn label(arena: Allocator, e: Entry) Allocator.Error![]const u8 {
    const k = e.ticket;
    if (k.status.len == 0) return std.fmt.allocPrint(arena, "{s} \u{b7} {s}", .{ k.id, k.summary });
    return std.fmt.allocPrint(arena, "{s} \u{b7} {s} \u{b7} {s}", .{ k.id, k.summary, k.status });
}

/// `as of 3h ago` for a stale record, null for a current one. On `arena`.
pub fn staleNote(arena: Allocator, e: Entry, now: i64) Allocator.Error!?[]const u8 {
    if (!e.staleAt(now)) return null;
    var buf: [16]u8 = undefined;
    const age = sdk.store.ageText(&buf, e.seen_at, now);
    if (age.len == 0) return "as of an earlier poll";
    return try std.fmt.allocPrint(arena, "as of {s} ago", .{age});
}

/// The link's menu's first row: the label, and `(as of 3h ago)` when
/// stale. Null when the cache knows nothing of the link.
pub fn menuInfo(app: *const App, arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    const e = forUrl(app, url) orelse return null;
    const l = try label(arena, e);
    const note = (try staleNote(arena, e, nowSecs(app))) orelse return l;
    return try std.fmt.allocPrint(arena, "{s} ({s})", .{ l, note });
}

/// The address of the link under the pointer: a `.link` hit's, or the
/// one in a terminal pane's text (`pty_pane.linkUnder`). On `arena`.
pub fn linkUnderPointer(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (!app.hover_live) return null;
    const h = app.hover orelse return null;
    const target = app.hits.at(h.x, h.y) orelse return null;
    return switch (target) {
        .link => |l| l.url,
        .pane => |id| if (app.panes.pty(id)) |p| try pty_pane.linkUnder(app, arena, p, h.x, h.y) else null,
        else => null,
    };
}

/// The hover for a link the cache knows: its label, and how old it is
/// when stale. Shown whatever `ui.hover_tooltip` says — it is the
/// link's content, not help about it.
pub fn linkTip(app: *App, arena: Allocator) Allocator.Error!?Tip {
    if (app.recent_items.tickets.count() == 0) return null;
    const url = (try linkUnderPointer(app, arena)) orelse return null;
    const e = forUrl(app, url) orelse return null;
    return .{ .title = try label(arena, e), .detail = try staleNote(arena, e, nowSecs(app)) };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    shared: []u8,
    app: App,

    fn init(f: *Fixture) !void {
        f.tmp = t.tmpDir(.{});
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = pbuf[0..try f.tmp.dir.realPath(t.io, &pbuf)];
        f.shared = try t.allocator.dupe(u8, dir);
        f.root = try std.fs.path.join(t.allocator, &.{ dir, "recent" });
        f.app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
        try f.app.env.put("MNML_SHARED_STATE_DIR", f.shared);
        f.app.recent_items.now_secs = 10_000;
    }
    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        t.allocator.free(f.shared);
        f.tmp.cleanup();
    }
    fn put(f: *Fixture, recs: []const cache.Ticket, now: i64) !void {
        try t.expectEqual(cache.Outcome.written, cache.putAt(t.allocator, t.io, f.root, .{ .source = "jira", .kind = .ticket, .listing = "assigned_open", .complete = true, .stale_after_secs = 600, .now = now }, recs));
    }
};

const login: cache.Ticket = .{ .id = "ACME-123", .summary = "Fix the login redirect", .status = "In Review", .assignee = "Pat Example" };

test "the file is read on the stat tick, again only when its mtime moves, and a link's address finds its ticket" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.put(&.{login}, 9_900);
    tick(&f.app, 0);
    try t.expectEqual(@as(u32, 1), f.app.recent_items.loads);
    const e = forUrl(&f.app, "https://tracker.example.com/browse/ACME-123").?;
    try t.expectEqualStrings("Fix the login redirect", e.ticket.summary);
    try t.expect(forUrl(&f.app, "https://tracker.example.com/browse/ACME-9") == null);
    // Unmoved: no read, however many ticks.
    tick(&f.app, 5_000);
    tick(&f.app, 10_000);
    try t.expectEqual(@as(u32, 1), f.app.recent_items.loads);
    // Moved: read again — but not before the tick's interval.
    var moved = login;
    moved.status = "Done";
    try f.put(&.{moved}, 9_950);
    tick(&f.app, 10_500);
    try t.expectEqual(@as(u32, 1), f.app.recent_items.loads);
    tick(&f.app, 12_100);
    try t.expectEqual(@as(u32, 2), f.app.recent_items.loads);
    try t.expectEqualStrings("Done", forUrl(&f.app, "https://tracker.example.com/browse/ACME-123?x=1").?.ticket.status);
    // Off: forgotten, and the children are told not to write.
    f.app.cfg.recent_items.enabled = false;
    tick(&f.app, 20_000);
    try t.expect(forUrl(&f.app, "https://tracker.example.com/browse/ACME-123") == null);
    try t.expectEqualStrings("0", f.app.env.get("MNML_RECENT_ITEMS").?);
    f.app.cfg.recent_items.enabled = true;
    tick(&f.app, 30_000);
    try t.expect(f.app.env.get("MNML_RECENT_ITEMS") == null);
    try t.expect(forUrl(&f.app, "https://tracker.example.com/browse/ACME-123") != null);
}

test "the hover text: id · summary · status; a stale record keeps its title and says how old it is; the menu row too" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.put(&.{login}, 9_900);
    tick(&f.app, 0);
    const a = f.app.frame.allocator();
    const e = forUrl(&f.app, "https://t.example/browse/ACME-123").?;
    try t.expectEqualStrings("ACME-123 \u{b7} Fix the login redirect \u{b7} In Review", try label(a, e));
    try t.expect((try staleNote(a, e, 10_000)) == null);
    try t.expectEqualStrings("ACME-123 \u{b7} Fix the login redirect \u{b7} In Review", (try menuInfo(&f.app, a, "https://t.example/browse/ACME-123")).?);
    // Three hours on, past stale_after_secs.
    f.app.recent_items.now_secs = 9_900 + 3 * 3600;
    try t.expectEqualStrings("as of 3h ago", (try staleNote(a, e, f.app.recent_items.now_secs.?)).?);
    try t.expectEqualStrings("ACME-123 \u{b7} Fix the login redirect \u{b7} In Review (as of 3h ago)", (try menuInfo(&f.app, a, "https://t.example/browse/ACME-123")).?);
    try t.expect((try menuInfo(&f.app, a, "https://t.example/browse/ACME-1")) == null);
}
