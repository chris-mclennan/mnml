//! The REQUESTS view (`Pane.requests`, `integrations.requests`): what
//! every integration on this machine has been asking an API for, and
//! what it cost.
//!
//! The complaint this exists to answer is "the Jira tabs are slow and
//! I cannot tell whether it is 429ing". The panes and the poller write
//! the answer down as they go — one JSON line per request under
//! `<data root>/requests/<service>.jsonl` (`mnml_sdk.request_log`) —
//! and this reads it back, newest first, with a header that says what
//! the last hour cost per service.
//!
//! Beside it, `<service>-draws.jsonl` in the rate bucket's own interop
//! directory says who has been spending the budget, mnml's panes and
//! everything else on the machine alike (the Rust crate and the Python
//! script share that directory and the contract in `docs/SDK.md`). A
//! bucket that is empty because a script is holding it looks exactly
//! like one that is empty because mnml is, and the `by program` line
//! is the difference.
//!
//! Nothing here is written: the view opens files, parses lines and
//! paints. A file that is missing, truncated or nonsense is a view
//! with fewer rows, never an error — this is the thing a person opens
//! when something is already going wrong.
//!
//!   D1  every string a row points at lives on the pane's snapshot
//!       arena, which is reset on each reload; nothing is on the frame
//!       arena, because a row outlives the frame that painted it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const alloc = @import("../core/alloc.zig");
const broker_app = @import("broker.zig");
const sdk = @import("mnml_sdk");

pub const table = .{
    .@"integrations.requests" = &showCmd,
};

/// The window the header's totals cover.
pub const window_secs: f64 = 3600;
/// Rows kept in memory. Newest first, so the cut is the oldest.
pub const max_rows: usize = 4000;
/// The biggest log file read in one go. Past this only the tail
/// matters, and the tail is what a diagnosis is about.
pub const max_bytes: usize = 8 * 1024 * 1024;

/// One request, as the view holds it. Every slice points into the
/// pane's snapshot arena.
pub const Row = struct {
    ts: f64 = 0,
    service: []const u8 = "",
    integration: []const u8 = "",
    reason: []const u8 = "",
    method: []const u8 = "",
    host: []const u8 = "",
    path: []const u8 = "",
    /// Null for a request that never reached a status.
    status: ?u16 = null,
    ms: u64 = 0,
    bytes: u64 = 0,
    wait_ms: u64 = 0,
    waited_for: []const u8 = "",
    tokens_after: f64 = 0,
    retry_of: u32 = 0,
    cache: []const u8 = "none",
    /// Which side handed the token over — `broker` or `file`
    /// (`mnml_sdk.ratelimit.Via`). Reason-agnostic: every line has it,
    /// so `/broker` narrows the view to what queued and `/file` to
    /// what went straight at the bucket. A line written before the
    /// broker existed has none and reads as `file`, which is what it
    /// was.
    via: []const u8 = "file",
    /// The line as it was written — what a click shows and what the
    /// right-click copies.
    raw: []const u8 = "",

    /// What the filter matches against, one field at a time, so a
    /// filter never has to allocate a joined string.
    pub fn matches(r: Row, needle: []const u8) bool {
        if (needle.len == 0) return true;
        for ([_][]const u8{ r.service, r.integration, r.reason, r.method, r.host, r.path, r.cache, r.waited_for, r.via }) |f| {
            if (containsIgnoreCase(f, needle)) return true;
        }
        var buf: [8]u8 = undefined;
        if (r.status) |st| {
            if (containsIgnoreCase(std.fmt.bufPrint(&buf, "{d}", .{st}) catch "", needle)) return true;
        } else if (containsIgnoreCase("failed", needle)) return true;
        return false;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

/// What one service spent in the window.
pub const ServiceTotals = struct {
    service: []const u8 = "",
    requests: u32 = 0,
    throttled: u32 = 0,
    cache_hits: u32 = 0,
    /// Milliseconds waited on the bucket across every request.
    wait_total_ms: u64 = 0,

    pub fn avgWaitMs(s: ServiceTotals) u64 {
        if (s.requests == 0) return 0;
        return s.wait_total_ms / s.requests;
    }
};

/// Where each service's broker stands, as the header paints it.
/// Filled on every reload from `app/broker.zig` — from memory for a
/// broker this mnml hosts, and over its own socket for one another
/// process is holding.
pub const BrokerLine = broker_app.Line;

/// What one program drew from a bucket in the window — mnml's panes,
/// the poller, and anything else on the machine that appends to the
/// draws file.
pub const ProgramDraws = struct {
    program: []const u8 = "",
    draws: u32 = 0,
};

pub const RequestsPane = struct {
    snapshot: alloc.SnapshotArena,
    rows: []const Row = &.{},
    /// Indices into `rows` that pass the filter, newest first.
    shown: []const u32 = &.{},
    totals: []const ServiceTotals = &.{},
    programs: []const ProgramDraws = &.{},
    /// One per service. Empty only before the first reload.
    brokers: []const BrokerLine = &.{},
    /// Requests read, before the filter — what the header counts.
    cursor: usize = 0,
    scroll: usize = 0,
    /// The `/` filter. Owned by the pane's gpa, not the snapshot: it
    /// survives a reload, which is the whole point of `r`.
    filter: std.ArrayListUnmanaged(u8) = .empty,
    filtering: bool = false,
    /// A row's whole line, opened by a click or `⏎`.
    detail: ?u32 = null,
    /// Where the files were read from, for the empty state's sentence.
    dir: []const u8 = "",

    pub fn init(gpa: Allocator) RequestsPane {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa) };
    }

    pub fn deinit(self: *RequestsPane) void {
        self.filter.deinit(self.snapshot.arena.child_allocator);
        self.snapshot.deinit();
    }

    pub fn title(self: *const RequestsPane) []const u8 {
        _ = self;
        return "requests";
    }

    pub fn selectedRow(self: *const RequestsPane) ?*const Row {
        if (self.cursor >= self.shown.len) return null;
        return &self.rows[self.shown[self.cursor]];
    }
};

// ─── reading the files ───────────────────────────────────────────────────

/// `"key":<number>` out of one JSON line. The files have one shape and
/// can run to millions of lines, so this beats parsing each one into a
/// tree.
pub fn jsonNumber(line: []const u8, key: []const u8) ?f64 {
    var kbuf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    const rest = line[at + needle.len ..];
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.' or rest[end] == '-')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// `"key":"…"` out of one JSON line. No escapes are decoded — the
/// writer escapes them, and a path that needed decoding to be read
/// would be one nobody could search for anyway.
pub fn jsonString(line: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    const rest = line[at + needle.len ..];
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '\\') {
            i += 1;
            continue;
        }
        if (rest[i] == '"') return rest[0..i];
    }
    return null;
}

/// One log line as a row, on `arena`. Null when it carries no path at
/// all, which is the one field a row is useless without.
pub fn parseRow(arena: Allocator, line: []const u8) Allocator.Error!?Row {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 2 or trimmed[0] != '{') return null;
    const path = jsonString(trimmed, "path") orelse return null;
    const status_num = jsonNumber(trimmed, "status");
    return .{
        .ts = jsonNumber(trimmed, "ts") orelse 0,
        .service = try arena.dupe(u8, jsonString(trimmed, "service") orelse ""),
        .integration = try arena.dupe(u8, jsonString(trimmed, "integration") orelse ""),
        .reason = try arena.dupe(u8, jsonString(trimmed, "reason") orelse ""),
        .method = try arena.dupe(u8, jsonString(trimmed, "method") orelse ""),
        .host = try arena.dupe(u8, jsonString(trimmed, "host") orelse ""),
        .path = try arena.dupe(u8, path),
        .status = if (status_num) |s| @intFromFloat(@max(s, 0)) else null,
        .ms = @intFromFloat(@max(jsonNumber(trimmed, "ms") orelse 0, 0)),
        .bytes = @intFromFloat(@max(jsonNumber(trimmed, "bytes") orelse 0, 0)),
        .wait_ms = @intFromFloat(@max(jsonNumber(trimmed, "wait_ms") orelse 0, 0)),
        .waited_for = try arena.dupe(u8, jsonString(trimmed, "waited_for") orelse ""),
        .tokens_after = jsonNumber(trimmed, "tokens_after") orelse 0,
        .retry_of = @intFromFloat(@max(jsonNumber(trimmed, "retry_of") orelse 0, 0)),
        .cache = try arena.dupe(u8, jsonString(trimmed, "cache") orelse "none"),
        .via = try arena.dupe(u8, jsonString(trimmed, "via") orelse "file"),
        .raw = try arena.dupe(u8, trimmed),
    };
}

/// Every row in `text`, appended to `out`. The file is oldest first;
/// the caller sorts.
pub fn parseInto(arena: Allocator, out: *std.ArrayListUnmanaged(Row), text: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (try parseRow(arena, line)) |r| try out.append(arena, r);
    }
}

/// `<data root>/requests`. Owned by `arena`.
pub fn requestsDir(arena: Allocator, data_root: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ data_root, "requests" });
}

/// The per-service totals of the rows inside the window, newest first
/// in the rows, busiest first here.
pub fn totalsOf(arena: Allocator, rows: []const Row, now: f64) Allocator.Error![]ServiceTotals {
    var out: std.ArrayListUnmanaged(ServiceTotals) = .empty;
    for (rows) |r| {
        if (r.ts > 0 and now - r.ts > window_secs) continue;
        const slot = blk: {
            for (out.items) |*s| if (std.mem.eql(u8, s.service, r.service)) break :blk s;
            try out.append(arena, .{ .service = r.service });
            break :blk &out.items[out.items.len - 1];
        };
        slot.requests += 1;
        slot.wait_total_ms += r.wait_ms;
        if (std.mem.eql(u8, r.cache, "hit")) slot.cache_hits += 1;
        if (r.status) |st| {
            if (st == 429) slot.throttled += 1;
        }
    }
    std.mem.sort(ServiceTotals, out.items, {}, struct {
        fn lt(_: void, a: ServiceTotals, b: ServiceTotals) bool {
            if (a.requests != b.requests) return a.requests > b.requests;
            return std.mem.order(u8, a.service, b.service) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// Who drew on the buckets inside the window, busiest first, out of
/// the machine-wide draws files. This is the line that makes a drained
/// bucket attributable: a Python script holding the budget and mnml
/// holding it look identical from inside mnml.
pub fn programsOf(arena: Allocator, text: []const u8, now: f64) Allocator.Error![]ProgramDraws {
    var out: std.ArrayListUnmanaged(ProgramDraws) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ts = jsonNumber(line, "ts") orelse continue;
        if (now - ts > window_secs) continue;
        const prog = jsonString(line, "program") orelse "other";
        const slot = blk: {
            for (out.items) |*p| if (std.mem.eql(u8, p.program, prog)) break :blk p;
            try out.append(arena, .{ .program = try arena.dupe(u8, prog) });
            break :blk &out.items[out.items.len - 1];
        };
        slot.draws += 1;
    }
    std.mem.sort(ProgramDraws, out.items, {}, struct {
        fn lt(_: void, a: ProgramDraws, b: ProgramDraws) bool {
            if (a.draws != b.draws) return a.draws > b.draws;
            return std.mem.order(u8, a.program, b.program) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// Re-read every log file and rebuild the rows. Best effort: a missing
/// directory is an empty view, which is what a machine that has made
/// no requests should look like.
pub fn reload(app: *App, p: *RequestsPane) Allocator.Error!void {
    p.snapshot.reset();
    const arena = p.snapshot.allocator();
    p.rows = &.{};
    p.shown = &.{};
    p.totals = &.{};
    p.programs = &.{};
    p.brokers = &.{};
    p.detail = null;
    const dir_path = try requestsDir(arena, app.data_root);
    p.dir = dir_path;

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch {
        try finish(app, p, arena, &rows);
        return;
    };
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const full = std.fs.path.join(arena, &.{ dir_path, entry.name }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(app.io, full, arena, .limited(max_bytes)) catch continue;
        try parseInto(arena, &rows, text);
    }
    try finish(app, p, arena, &rows);
}

fn finish(app: *App, p: *RequestsPane, arena: Allocator, rows: *std.ArrayListUnmanaged(Row)) Allocator.Error!void {
    // Newest first: a diagnosis starts at the thing that just
    // happened, not at whatever the oldest kept file begins with.
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.ts > b.ts;
        }
    }.lt);
    if (rows.items.len > max_rows) rows.shrinkRetainingCapacity(max_rows);
    p.rows = rows.items;
    const now = nowSecs(app.io);
    p.totals = try totalsOf(arena, p.rows, now);
    p.programs = try programsOf(arena, try readDraws(app, arena), now);
    // Who is handing the tokens out, and how much is left to hand.
    // Read here rather than painted from live state, so the whole
    // header is one snapshot of one moment.
    p.brokers = try broker_app.lines(app, arena);
    try applyFilter(p);
    app.needs_render = true;
}

/// Every `<service>-draws.jsonl` the rate buckets resolve to, joined.
/// The directory is the bucket's, not mnml's: it is shared with
/// everything else on the machine that spends from the same allowance.
fn readDraws(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (broker_app.services) |service| {
        const state = sdk.ratelimit.statePath(arena, app.io, &app.env, service) catch continue;
        const dir = std.fs.path.dirname(state) orelse continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}-draws.jsonl", .{ dir, service }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(max_bytes)) catch continue;
        try out.appendSlice(arena, text);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// The rows the filter lets through, newest first. Keeps the cursor on
/// the row it was on where it still shows.
pub fn applyFilter(p: *RequestsPane) Allocator.Error!void {
    const arena = p.snapshot.allocator();
    const was: ?u32 = if (p.cursor < p.shown.len) p.shown[p.cursor] else null;
    var out: std.ArrayListUnmanaged(u32) = .empty;
    for (p.rows, 0..) |r, i| {
        if (r.matches(p.filter.items)) try out.append(arena, @intCast(i));
    }
    p.shown = try out.toOwnedSlice(arena);
    p.cursor = 0;
    if (was) |w| for (p.shown, 0..) |idx, i| if (idx == w) {
        p.cursor = i;
    };
    if (p.cursor >= p.shown.len) p.cursor = p.shown.len -| 1;
}

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

// ─── the pane ────────────────────────────────────────────────────────────

pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.requests);
}

/// `integrations.requests`: the one view, below the active pane; a
/// reload when it is already open.
fn showCmd(app: *App) CommandError!void {
    if (find(app)) |id| {
        app.showPane(id);
        try reload(app, &app.panes.get(id).?.requests);
        return;
    }
    const id = try app.panes.add(.{ .requests = RequestsPane.init(app.gpa) });
    const layout = app.layouts.current();
    if (app.active) |cur| if (layout.leafOf(cur) != null) {
        _ = layout.split(cur, .horizontal, id) catch {};
    };
    app.showPane(id);
    try reload(app, &app.panes.get(id).?.requests);
}

/// Open it already filtered to one service — what a statusline chip's
/// `Requests…` menu row does.
pub fn showFiltered(app: *App, service: []const u8) CommandError!void {
    try showCmd(app);
    const id = find(app) orelse return;
    const p = &app.panes.get(id).?.requests;
    p.filter.clearRetainingCapacity();
    try p.filter.appendSlice(app.gpa, service);
    try applyFilter(p);
    app.needs_render = true;
}

pub fn handleKey(app: *App, id: PaneId, p: *RequestsPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    // Typing in the filter: every printable goes in, and nothing else
    // in this table gets a look at it. A filter that swallowed `r`
    // would be a filter you could not type "refresh" into.
    if (p.filtering) {
        switch (k.code) {
            .esc => {
                p.filtering = false;
                p.filter.clearRetainingCapacity();
                try applyFilter(p);
            },
            .enter => p.filtering = false,
            .backspace => {
                if (p.filter.items.len > 0) {
                    _ = p.filter.pop().?;
                    try applyFilter(p);
                }
            },
            .char => |c| {
                if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return true;
                try p.filter.appendSlice(app.gpa, buf[0..n]);
                try applyFilter(p);
            },
            else => return false,
        }
        return true;
    }
    const last = p.shown.len -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .enter => toggleDetail(p),
        .esc => {
            if (p.detail != null) p.detail = null else if (p.filter.items.len > 0) {
                p.filter.clearRetainingCapacity();
                try applyFilter(p);
            } else try app.forceClosePane(id);
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.cursor = @min(p.cursor + 1, last),
                'k' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                'r' => try reload(app, p),
                '/' => p.filtering = true,
                'y' => copyPath(app, p),
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

fn toggleDetail(p: *RequestsPane) void {
    if (p.cursor >= p.shown.len) return;
    const idx = p.shown[p.cursor];
    p.detail = if (p.detail != null and p.detail.? == idx) null else idx;
}

/// The path of the row under the cursor, on the clipboard — the one
/// thing you want out of this view and into a terminal.
pub fn copyPath(app: *App, p: *RequestsPane) void {
    const r = p.selectedRow() orelse return;
    app.clipboard.copy(r.path) catch {};
    app.toast("copied {s}", .{r.path});
}

/// A click focuses the row; a second click on it opens the whole line.
pub fn click(app: *App, p: *RequestsPane, row: u32, m: Mouse) void {
    if (row >= p.shown.len) return;
    if (m.kind != .press) return;
    if (m.button == .right) {
        p.cursor = row;
        copyPath(app, p);
        app.needs_render = true;
        return;
    }
    if (m.button != .left) return;
    if (p.cursor == row) toggleDetail(p) else {
        p.cursor = row;
        p.detail = null;
    }
    app.needs_render = true;
}

pub fn scrollBy(p: *RequestsPane, delta: i64) void {
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(p.shown.len -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "a log line becomes a row, and a line that is not one is skipped rather than fatal" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line =
        \\{"ts":1789526218.411,"service":"jira","integration":"mnml-jira","method":"GET","host":"acme.atlassian.net","path":"/rest/api/3/search/jql?jql=assignee%20%3D%20currentUser()","status":200,"ms":412,"bytes":18244,"reason":"pane_open","wait_ms":3030,"waited_for":"tokens","tokens_after":0.240,"retry_of":0,"cache":"miss","via":"broker"}
    ;
    const r = (try parseRow(a, line)).?;
    try t.expectEqualStrings("jira", r.service);
    try t.expectEqualStrings("mnml-jira", r.integration);
    try t.expectEqualStrings("GET", r.method);
    try t.expectEqualStrings("acme.atlassian.net", r.host);
    try t.expectEqualStrings("/rest/api/3/search/jql?jql=assignee%20%3D%20currentUser()", r.path);
    try t.expectEqual(@as(?u16, 200), r.status);
    try t.expectEqual(@as(u64, 412), r.ms);
    try t.expectEqual(@as(u64, 18244), r.bytes);
    try t.expectEqualStrings("pane_open", r.reason);
    try t.expectEqual(@as(u64, 3030), r.wait_ms);
    try t.expectEqualStrings("tokens", r.waited_for);
    try t.expectEqualStrings("miss", r.cache);
    try t.expectEqualStrings("broker", r.via);
    try t.expectApproxEqAbs(@as(f64, 0.24), r.tokens_after, 1e-9);

    // A transport failure has no status; the row says so rather than
    // inventing a zero.
    const failed = (try parseRow(a, "{\"ts\":1,\"service\":\"jira\",\"method\":\"GET\",\"host\":\"h\",\"path\":\"/p\",\"status\":null,\"reason\":\"poll\"}")).?;
    try t.expect(failed.status == null);
    // A line written before the broker existed says nothing about
    // which side served it, and reads as `file` — which is what it was.
    try t.expectEqualStrings("file", failed.via);
    // Nothing that is not a line.
    try t.expect((try parseRow(a, "")) == null);
    try t.expect((try parseRow(a, "not json")) == null);
    try t.expect((try parseRow(a, "{\"ts\":1}")) == null);

    // The filter looks at every field a person would type, and at the
    // status as a number.
    try t.expect(r.matches(""));
    try t.expect(r.matches("jira"));
    try t.expect(r.matches("PANE_OPEN"));
    try t.expect(r.matches("search/jql"));
    try t.expect(r.matches("200"));
    // `/broker` narrows the view to what queued, `/file` to what went
    // straight at the bucket.
    try t.expect(r.matches("broker"));
    try t.expect(!r.matches("file"));
    try t.expect(failed.matches("file"));
    try t.expect(!r.matches("bitbucket"));
    try t.expect(failed.matches("failed"));
}

test "the header's totals are the last hour's, per service, and an old line is outside them" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now: f64 = 1_000_000;
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    // Four jira requests inside the window: one 429, one cache hit,
    // waits of 3000 and 1000 ms.
    try rows.append(a, .{ .ts = now - 10, .service = "jira", .status = 200, .wait_ms = 3000, .cache = "miss" });
    try rows.append(a, .{ .ts = now - 20, .service = "jira", .status = 429, .wait_ms = 1000, .cache = "miss" });
    try rows.append(a, .{ .ts = now - 30, .service = "jira", .status = 200, .wait_ms = 0, .cache = "hit" });
    try rows.append(a, .{ .ts = now - 40, .service = "jira", .status = 200, .wait_ms = 0, .cache = "none" });
    try rows.append(a, .{ .ts = now - 50, .service = "bitbucket", .status = 200, .wait_ms = 0, .cache = "none" });
    // Outside the window: counted nowhere.
    try rows.append(a, .{ .ts = now - window_secs - 1, .service = "jira", .status = 429, .wait_ms = 99999, .cache = "none" });

    const tot = try totalsOf(a, rows.items, now);
    try t.expectEqual(@as(usize, 2), tot.len);
    // Busiest first.
    try t.expectEqualStrings("jira", tot[0].service);
    try t.expectEqual(@as(u32, 4), tot[0].requests);
    try t.expectEqual(@as(u32, 1), tot[0].throttled);
    try t.expectEqual(@as(u32, 1), tot[0].cache_hits);
    try t.expectEqual(@as(u64, 1000), tot[0].avgWaitMs());
    try t.expectEqualStrings("bitbucket", tot[1].service);
    try t.expectEqual(@as(u32, 1), tot[1].requests);
    try t.expectEqual(@as(u64, 0), tot[1].avgWaitMs());
}

test "the by-program summary counts every draw on the bucket, mnml's and everything else's" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now: f64 = 1_000_000;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    // The case the file exists for: a script outside mnml holding the
    // budget the pane is waiting on.
    var i: usize = 0;
    while (i < 30) : (i += 1) try text.print(a, "{{\"ts\":{d},\"pid\":9,\"program\":\"bb.py\",\"service\":\"bitbucket\",\"reason\":\"user\",\"wait_ms\":0,\"tokens_after\":1}}\n", .{now - 100});
    i = 0;
    while (i < 41) : (i += 1) try text.print(a, "{{\"ts\":{d},\"pid\":1,\"program\":\"mnml-jira\",\"service\":\"jira\",\"reason\":\"pane_open\",\"wait_ms\":0,\"tokens_after\":1}}\n", .{now - 50});
    i = 0;
    while (i < 12) : (i += 1) try text.print(a, "{{\"ts\":{d},\"pid\":2,\"program\":\"mnml-bitbucket\",\"service\":\"bitbucket\",\"reason\":\"poll\",\"wait_ms\":0,\"tokens_after\":1}}\n", .{now - 20});
    // An hour and a half ago: outside the window.
    try text.print(a, "{{\"ts\":{d},\"pid\":3,\"program\":\"ancient\",\"service\":\"jira\",\"reason\":\"user\",\"wait_ms\":0,\"tokens_after\":1}}\n", .{now - 5400});

    const progs = try programsOf(a, text.items, now);
    try t.expectEqual(@as(usize, 3), progs.len);
    try t.expectEqualStrings("mnml-jira", progs[0].program);
    try t.expectEqual(@as(u32, 41), progs[0].draws);
    try t.expectEqualStrings("bb.py", progs[1].program);
    try t.expectEqual(@as(u32, 30), progs[1].draws);
    try t.expectEqualStrings("mnml-bitbucket", progs[2].program);
    try t.expectEqual(@as(u32, 12), progs[2].draws);
    for (progs) |p| try t.expect(!std.mem.eql(u8, p.program, "ancient"));
}

test "integrations.requests reads the log files, newest first, and / filters them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "data/requests");
    // Written moments ago, because the header's totals are the last
    // hour's: a fixture stamped in 1970 would prove nothing about them.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now = nowSecs(t.io);
    const jira_lines = try std.fmt.allocPrint(a,
        \\{{"ts":{d:.3},"service":"jira","integration":"mnml-jira","method":"GET","host":"acme.atlassian.net","path":"/rest/api/3/myself","status":200,"ms":120,"bytes":83,"reason":"pane_open","wait_ms":0,"waited_for":"nothing","tokens_after":12.0,"retry_of":0,"cache":"none"}}
        \\{{"ts":{d:.3},"service":"jira","integration":"mnml-jira","method":"GET","host":"acme.atlassian.net","path":"/rest/dev-status/latest/issue/detail?issueId=10002","status":429,"ms":90,"bytes":40,"reason":"refresh","wait_ms":3100,"waited_for":"tokens","tokens_after":0.2,"retry_of":1,"cache":"none"}}
        \\
    , .{ now - 30, now - 10 });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/requests/jira.jsonl", .data = jira_lines });
    const bb_lines = try std.fmt.allocPrint(a,
        \\{{"ts":{d:.3},"service":"bitbucket","integration":"mnml-bitbucket","method":"GET","host":"api.bitbucket.org","path":"/2.0/repositories/acme/api/pullrequests","status":200,"ms":300,"bytes":900,"reason":"poll","wait_ms":0,"waited_for":"nothing","tokens_after":8.0,"retry_of":0,"cache":"hit"}}
        \\
    , .{now - 20});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/requests/bitbucket.jsonl", .data = bb_lines });
    const data_root = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data_root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 140, .rows = 30, .data_root = data_root });
    defer app.deinit();
    app.tree.visible = false;

    try showCmd(&app);
    const id = find(&app).?;
    const p = &app.panes.get(id).?.requests;
    // Every file in the directory, newest first.
    try t.expectEqual(@as(usize, 3), p.rows.len);
    try t.expectEqual(@as(usize, 3), p.shown.len);
    try t.expectEqualStrings("/rest/dev-status/latest/issue/detail?issueId=10002", p.rows[0].path);
    try t.expectEqualStrings("/2.0/repositories/acme/api/pullrequests", p.rows[1].path);
    try t.expectEqualStrings("/rest/api/3/myself", p.rows[2].path);
    try t.expectEqual(@as(?u16, 429), p.rows[0].status);
    try t.expectEqual(@as(u32, 1), p.rows[0].retry_of);
    // Two services in the header, over the last hour, busiest first.
    try t.expectEqual(@as(usize, 2), p.totals.len);
    try t.expectEqualStrings("jira", p.totals[0].service);
    try t.expectEqual(@as(u32, 2), p.totals[0].requests);
    try t.expectEqual(@as(u32, 1), p.totals[0].throttled);
    try t.expectEqual(@as(u64, 1550), p.totals[0].avgWaitMs());
    try t.expectEqualStrings("bitbucket", p.totals[1].service);
    try t.expectEqual(@as(u32, 1), p.totals[1].cache_hits);

    // `/` filters, and only the rows that match remain.
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = '/' } });
    try t.expect(p.filtering);
    for ("bitbucket") |c| _ = try handleKey(&app, id, p, .{ .code = .{ .char = c } });
    try t.expectEqual(@as(usize, 1), p.shown.len);
    try t.expectEqualStrings("/2.0/repositories/acme/api/pullrequests", p.selectedRow().?.path);
    // `r` inside the filter is a letter, not a reload — a filter you
    // cannot type "refresh" into is not a filter.
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = 'r' } });
    try t.expectEqualStrings("bitbucketr", p.filter.items);
    try t.expectEqual(@as(usize, 0), p.shown.len);
    _ = try handleKey(&app, id, p, .{ .code = .backspace });
    try t.expectEqual(@as(usize, 1), p.shown.len);
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    try t.expect(!p.filtering);
    // Esc with a filter on clears it before it closes anything.
    _ = try handleKey(&app, id, p, .{ .code = .esc });
    try t.expectEqual(@as(usize, 0), p.filter.items.len);
    try t.expectEqual(@as(usize, 3), p.shown.len);
    try t.expect(find(&app) != null);

    // Enter opens the whole line, under the row the cursor is on.
    // `g` first, because clearing the filter left the cursor on the
    // row it had been holding rather than at the top.
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = 'g' } });
    try t.expectEqual(@as(usize, 0), p.cursor);
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    try t.expectEqual(@as(?u32, 0), p.detail);
    try t.expect(std.mem.indexOf(u8, p.rows[p.detail.?].raw, "\"waited_for\":\"tokens\"") != null);
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    try t.expect(p.detail == null);

    // Opening it filtered is what a chip's `Requests…` row does.
    try showFiltered(&app, "bitbucket");
    try t.expectEqual(@as(usize, 1), p.shown.len);
    try t.expectEqualStrings("bitbucket", p.filter.items);
    // The same command again refocuses the one view rather than
    // opening a second.
    try showCmd(&app);
    try t.expectEqual(id, find(&app).?);
}

test "a machine that has made no requests opens an empty view rather than an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 24, .data_root = root });
    defer app.deinit();
    app.tree.visible = false;
    try showCmd(&app);
    const p = &app.panes.get(find(&app).?).?.requests;
    try t.expectEqual(@as(usize, 0), p.rows.len);
    try t.expectEqual(@as(usize, 0), p.totals.len);
    try t.expect(p.selectedRow() == null);
    // And a reload on the empty view is still empty rather than a
    // crash on an absent directory.
    try reload(&app, p);
    try t.expectEqual(@as(usize, 0), p.rows.len);
}
