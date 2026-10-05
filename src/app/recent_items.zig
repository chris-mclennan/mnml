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
//! A link finds its record by its address: a Bitbucket pull request's
//! `…/<workspace>/<repo>/pull-requests/45` is `<workspace>/<repo>#45`,
//! a pipeline's `…/pipelines/results/1234` is `<workspace>/<repo>!1234`,
//! anything else its last path segment — `…/browse/ACME-123` is
//! `ACME-123` — so a key a link rule matched, a `widget#45`, a `PR 45`
//! the link ranges resolved and an OSC 8 hyperlink to the same page all
//! get it. The hover shows `ACME-123 · Fix the login redirect · In
//! Review`, or `acme/widget#45 · Redesign the empty state · OPEN · Max
//! Orr`; a stale record keeps its title and adds `as of 3h ago`.
//! Nothing is painted inline.
//!
//! `picker.recent_items` lists the cached tickets and pull requests,
//! newest first; Enter opens the one picked the way a click on its link
//! would.
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
const command = @import("../core/command.zig");
const cmd_picker = @import("cmd_picker.zig");
const PaneId = @import("../app.zig").PaneId;

/// Jira's `recent.current_release_env`.
pub const current_release_env = "MNML_RECENT_CURRENT_RELEASE";

/// The kinds a link can name.
const kinds = [_]cache.Kind{ .ticket, .pr, .pipeline };

/// One record, whatever its kind, as the hover and the picker read it.
pub const Entry = struct {
    kind: cache.Kind,
    id: []const u8,
    /// A ticket's summary, a pull request's title, a run's ref.
    title: []const u8,
    /// Its status, state, or a run's result (else its state).
    status: []const u8,
    /// A pull request's author; empty for the rest.
    who: []const u8 = "",
    /// The record's own `updated` stamp, for the picker's order.
    updated: []const u8 = "",
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
    /// Every ticket, pull request and pipeline run read, by id — the
    /// three id grammars (`ACME-123`, `acme/widget#45`, `acme/widget!1234`)
    /// never collide.
    items: std.StringHashMapUnmanaged(Entry) = .empty,
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
        st.items = .empty;
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

/// What the integrations mnml starts read: `MNML_RECENT_ITEMS=0` when
/// the cache is off, `MNML_RECENT_CURRENT_RELEASE` when the config
/// names the current release.
fn syncEnv(app: *App) void {
    const st = &app.recent_items;
    const forced = app.cfg.recent_items.current_release;
    const had = app.env.get(current_release_env) orelse "";
    if (!std.mem.eql(u8, had, forced)) {
        if (forced.len == 0) {
            _ = app.env.swapRemove(current_release_env);
        } else app.env.put(current_release_env, forced) catch {};
    }
    const on = app.cfg.recent_items.enabled;
    if (!on and !st.env_set) {
        app.env.put("MNML_RECENT_ITEMS", "0") catch return;
        st.env_set = true;
    } else if (on and st.env_set) {
        _ = app.env.swapRemove("MNML_RECENT_ITEMS");
        st.env_set = false;
    }
}

/// Stat every source's ticket, pull-request and pipeline file; read
/// them all when any moved.
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
            for (kinds) |k| {
                const path = cache.filePath(sa, root, e.name, k) catch continue;
                const stat = Io.Dir.cwd().statFile(app.io, path, .{}) catch continue;
                h.update(path);
                h.update(std.mem.asBytes(&stat.mtime.nanoseconds));
                h.update(std.mem.asBytes(&stat.size));
                files.append(sa, path) catch continue;
            }
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
        switch (f.kind) {
            inline .ticket, .pr, .pipeline => |k| {
                // Staleness by age is the reader's to decide at hover
                // time, so the records are taken as of the file's own
                // last poll.
                const found = cache.foundIn(k, a, f, f.fresh_at) catch continue;
                for (found) |r| {
                    const e = entryOf(k, r.record, r.source, r.seen_at, r.stale, f);
                    const gop = st.items.getOrPut(a, e.id) catch continue;
                    if (!gop.found_existing or gop.value_ptr.seen_at < e.seen_at) gop.value_ptr.* = e;
                }
            },
            .release => {},
        }
    }
}

fn entryOf(comptime k: cache.Kind, rec: k.Record(), source: []const u8, seen_at: i64, stale: bool, f: cache.File) Entry {
    var e: Entry = .{ .kind = k, .id = rec.id, .title = "", .status = "", .source = source, .seen_at = seen_at, .flagged = stale, .fresh_at = f.fresh_at, .stale_after_secs = f.stale_after_secs };
    switch (k) {
        .ticket => {
            e.title = rec.summary;
            e.status = rec.status;
            e.updated = rec.updated;
        },
        .pr => {
            e.title = rec.title;
            e.status = rec.state;
            e.who = rec.author;
            e.updated = rec.updated;
        },
        .pipeline => {
            e.title = rec.ref_name;
            e.status = if (rec.result.len > 0) rec.result else rec.state;
            e.updated = if (rec.updated.len > 0) rec.updated else rec.created;
        },
        .release => unreachable,
    }
    return e;
}

/// The cache id a link's address names, on `buf`: a Bitbucket pull
/// request's or pipeline run's `<workspace>/<repo>#45` / `!1234`, else
/// the last path segment. Null when the address has no path.
pub fn idOf(buf: []u8, url: []const u8) ?[]const u8 {
    var end = url.len;
    if (std.mem.indexOfAny(u8, url, "?#")) |q| end = q;
    const path = std.mem.trimEnd(u8, url[0..end], "/");
    inline for (.{ .{ "/pull-requests/", "#" }, .{ "/pipelines/results/", "!" } }) |shape| {
        if (std.mem.indexOf(u8, path, shape[0])) |at| {
            const head = path[0..at];
            const tail = path[at + shape[0].len ..];
            const n = tail[0 .. std.mem.indexOfNone(u8, tail, "0123456789") orelse tail.len];
            const slash = std.mem.lastIndexOfScalar(u8, head, '/');
            const ws_slash = if (slash) |sl| std.mem.lastIndexOfScalar(u8, head[0..sl], '/') else null;
            if (n.len > 0 and ws_slash != null) {
                const repo = head[ws_slash.? + 1 ..];
                return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ repo, shape[1], n }) catch null;
            }
        }
    }
    const seg = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1 ..];
    if (seg.len == 0) return null;
    return seg;
}

/// The record a link's address names — its last path segment.
pub fn forUrl(app: *const App, url: []const u8) ?Entry {
    if (!app.cfg.recent_items.enabled) return null;
    var buf: [512]u8 = undefined;
    return app.recent_items.items.get(idOf(&buf, url) orelse return null);
}

/// `ACME-123 · Fix the login redirect · In Review`, `acme/widget#45 ·
/// Redesign the empty state · OPEN · Max Orr`. On `arena`.
pub fn label(arena: Allocator, e: Entry) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, e.id);
    for ([_][]const u8{ e.title, e.status, e.who }) |part| if (part.len > 0) {
        try out.appendSlice(arena, " \u{b7} ");
        try out.appendSlice(arena, part);
    };
    return out.items;
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
    if (app.recent_items.items.count() == 0) return null;
    const url = (try linkUnderPointer(app, arena)) orelse return null;
    const e = forUrl(app, url) orelse return null;
    return .{ .title = try label(arena, e), .detail = try staleNote(arena, e, nowSecs(app)) };
}

// ─── the picker ─────────────────────────────────────────────────────────

pub const table = .{
    .@"picker.recent_items" = &pick,
};

fn newerFirst(_: void, a: Entry, b: Entry) bool {
    if (a.seen_at != b.seen_at) return a.seen_at > b.seen_at;
    const c = std.mem.order(u8, a.updated, b.updated);
    if (c != .eq) return c == .gt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// The cached tickets and pull requests, newest first (last seen, then
/// last updated). On `arena`.
pub fn rows(app: *const App, arena: Allocator) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    if (!app.cfg.recent_items.enabled) return out.items;
    var it = app.recent_items.items.valueIterator();
    while (it.next()) |e| if (e.kind == .ticket or e.kind == .pr) try out.append(arena, e.*);
    std.mem.sort(Entry, out.items, {}, newerFirst);
    return out.items;
}

/// A row's text: the label, and `· stale` when it is.
pub fn rowLabel(arena: Allocator, e: Entry, now: i64) Allocator.Error![]const u8 {
    const l = try label(arena, e);
    if (!e.staleAt(now)) return l;
    return std.fmt.allocPrint(arena, "{s} \u{b7} stale", .{l});
}

/// `picker.recent_items`: the cached tickets and pull requests. Enter
/// opens the item where its link would.
pub fn pick(app: *App) command.CommandError!void {
    reloadIfMoved(app);
    const fa = app.frame.allocator();
    const list = try rows(app, fa);
    if (list.len == 0) return app.diag.fail(fa, "no recent tickets or pull requests yet — the integrations fill this as they poll", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    const now = nowSecs(app);
    for (list) |e| {
        try labels.append(gpa, try gpa.dupe(u8, try rowLabel(fa, e, now)));
        var buf: [16]u8 = undefined;
        const age = sdk.store.ageText(&buf, e.seen_at, now);
        try details.append(gpa, if (age.len > 0) try std.fmt.allocPrint(gpa, "{s} \u{b7} {s} ago", .{ e.source, age }) else try gpa.dupe(u8, e.source));
    }
    try cmd_picker.openPickerWith(app, "Recent items", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &accept;
}

/// The id is the row's first ` · ` segment.
fn accept(app: *App, _: usize, row: []const u8) Allocator.Error!void {
    const id = row[0 .. std.mem.indexOf(u8, row, " \u{b7} ") orelse row.len];
    const url = (try urlFor(app, app.frame.allocator(), id)) orelse {
        app.toast("no link rule names {s}", .{id});
        return;
    };
    @import("git.zig").openExternal(app, url);
}

/// Where a click on a link to `id` would go: the link rules' address
/// for the id as written, or for a pull request's `<repo>#<n>` (the
/// shape the workspace's own rule matches). On `arena`.
pub fn urlFor(app: *App, arena: Allocator, id: []const u8) Allocator.Error!?[]const u8 {
    app.link_rules.setHome(app.gpa, app.git.remote);
    var texts: [2][]const u8 = .{ id, "" };
    if (std.mem.indexOfScalar(u8, id, '#')) |hash| if (std.mem.lastIndexOfScalar(u8, id[0..hash], '/')) |sl| {
        texts[1] = id[sl + 1 ..];
    };
    for (texts) |text| {
        if (text.len == 0) continue;
        for (app.link_rules.spans(app.gpa, text)) |sp| if (sp.start == 0 and sp.end == text.len) return try arena.dupe(u8, sp.url);
    }
    return null;
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

test "recent items: the file is read on the stat tick, again only when its mtime moves, and a link's address finds its ticket" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.put(&.{login}, 9_900);
    tick(&f.app, 0);
    try t.expectEqual(@as(u32, 1), f.app.recent_items.loads);
    const e = forUrl(&f.app, "https://tracker.example.com/browse/ACME-123").?;
    try t.expectEqualStrings("Fix the login redirect", e.title);
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
    try t.expectEqualStrings("Done", forUrl(&f.app, "https://tracker.example.com/browse/ACME-123?x=1").?.status);
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

test "recent items: the hover text: id · summary · status; a stale record keeps its title and says how old it is; the menu row too" {
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

test "recent items: a Bitbucket pull request's and pipeline run's address names its cache id; anything else its last segment" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("acme/widget#45", idOf(&buf, "https://bitbucket.org/acme/widget/pull-requests/45").?);
    try t.expectEqualStrings("acme/widget#45", idOf(&buf, "https://bitbucket.org/acme/widget/pull-requests/45/diff?w=1").?);
    try t.expectEqualStrings("acme/widget!1234", idOf(&buf, "https://bitbucket.org/acme/widget/pipelines/results/1234").?);
    try t.expectEqualStrings("ACME-123", idOf(&buf, "https://t.example/browse/ACME-123/").?);
    // No number after the shape: the last segment, as before.
    try t.expectEqualStrings("pull-requests", idOf(&buf, "https://bitbucket.org/acme/widget/pull-requests/").?);
    try t.expect(idOf(&buf, "nopath") == null);
}

test "recent items: a pull request's hover: id · title · state · author; the picker lists tickets and pull requests newest first, stale marked" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.put(&.{login}, 9_000);
    const pr: cache.Pr = .{ .id = "acme/widget#45", .title = "Redesign the empty state", .state = "OPEN", .author = "Max Orr", .updated = "2026-10-01T09:00:00Z" };
    const older: cache.Pr = .{ .id = "acme/widget#44", .title = "Bump the client timeout", .state = "MERGED", .author = "Max Orr", .updated = "2026-09-30T09:00:00Z" };
    try t.expectEqual(cache.Outcome.written, cache.putAt(t.allocator, t.io, f.root, .{ .source = "bitbucket", .kind = .pr, .listing = "authored", .stale_after_secs = 600, .now = 9_900 }, &[_]cache.Pr{ older, pr }));
    const run: cache.Pipeline = .{ .id = "acme/widget!1234", .state = "COMPLETED", .result = "FAILED", .ref_name = "main" };
    try t.expectEqual(cache.Outcome.written, cache.putAt(t.allocator, t.io, f.root, .{ .source = "bitbucket", .kind = .pipeline, .stale_after_secs = 600, .now = 9_900 }, &[_]cache.Pipeline{run}));
    tick(&f.app, 0);
    const a = f.app.frame.allocator();
    try t.expectEqualStrings("acme/widget#45 \u{b7} Redesign the empty state \u{b7} OPEN \u{b7} Max Orr", (try menuInfo(&f.app, a, "https://bitbucket.org/acme/widget/pull-requests/45")).?);
    try t.expectEqualStrings("acme/widget!1234 \u{b7} main \u{b7} FAILED", (try menuInfo(&f.app, a, "https://bitbucket.org/acme/widget/pipelines/results/1234")).?);
    // The picker: the two pull requests (seen at 9 900, the newer
    // update first), then the ticket (seen at 9 000, past its file's
    // stale_after_secs by now); no pipeline run.
    const list = try rows(&f.app, a);
    try t.expectEqual(@as(usize, 3), list.len);
    try t.expectEqualStrings("acme/widget#45", list[0].id);
    try t.expectEqualStrings("acme/widget#44", list[1].id);
    try t.expectEqualStrings("ACME-123", list[2].id);
    try t.expectEqualStrings("acme/widget#45 \u{b7} Redesign the empty state \u{b7} OPEN \u{b7} Max Orr", try rowLabel(a, list[0], 10_000));
    try t.expectEqualStrings("ACME-123 \u{b7} Fix the login redirect \u{b7} In Review \u{b7} stale", try rowLabel(a, list[2], 10_000));
    // Off: no rows.
    f.app.cfg.recent_items.enabled = false;
    try t.expectEqual(@as(usize, 0), (try rows(&f.app, a)).len);
}

test "recent items: the configured current release reaches the integrations mnml starts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.cfg.recent_items.current_release = "ACME/2026.10";
    tick(&f.app, 0);
    try t.expectEqualStrings("ACME/2026.10", f.app.env.get(current_release_env).?);
    f.app.cfg.recent_items.current_release = "";
    tick(&f.app, 10_000);
    try t.expect(f.app.env.get(current_release_env) == null);
}
