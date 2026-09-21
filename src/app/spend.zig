//! The AI spend report (`Pane.spend_report`, `ai.spend_today`): tokens
//! and estimated cost across every Claude / Codex transcript touched in
//! the last 24 hours, by workspace — and the same numbers behind the
//! statusline meter (`ai.refresh_usage`).
//!
//!   D1  the worker's `*Result` rides the `.spend` event; the pane (or
//!       the app's meter) adopts it;
//!   D3  one `Io.Group` per pane plus `ai.State.spend_group` for the
//!       meter; a refresh bumps the generation — the worker reads it
//!       between files through an atomic and stops early, so a closed or
//!       refreshed pane never waits on a multi-MB read to finish;
//!   D2  the toast (`computing spend… (background)`) is the command's,
//!       fired before the worker could possibly have answered.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("../core/alloc.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const transcript = @import("../ai/transcript.zig");
const layout_mod = @import("layout.zig");

pub const table = .{
    .@"ai.spend_today" = &openCmd,
};

/// The window the report covers.
pub const window_s: i64 = 24 * 3600;
/// A transcript past this is read only to the cap (the totals are then
/// a lower bound, as the Rust report's were).
pub const max_read: usize = 10 * 1024 * 1024;

pub const WsRow = struct { workspace: []const u8, tokens: u64, cost_usd: f64, sessions: usize };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    rows: []WsRow = &.{},
    claude_sessions: usize = 0,
    codex_sessions: usize = 0,
    total_tokens: u64 = 0,
    total_cost_usd: f64 = 0,
    generation: u32,
    /// The pane that asked; null is the meter.
    pane: ?PaneId,
    /// The worker stopped early (its generation moved).
    aborted: bool = false,

    pub fn create(gpa: Allocator, generation: u32, pane: ?PaneId) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .generation = generation, .pane = pane };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn sessions(self: *const Result) usize {
        return self.claude_sessions + self.codex_sessions;
    }
};

pub const SortKey = enum {
    workspace,
    tokens,
    cost,

    pub fn label(k: SortKey) []const u8 {
        return @tagName(k);
    }
    pub fn next(k: SortKey) SortKey {
        return switch (k) {
            .workspace => .tokens,
            .tokens => .cost,
            .cost => .workspace,
        };
    }
};

/// A worker's cooperative abort: it compares this against the
/// generation it was started with, between files.
pub const Abort = struct { generation: std.atomic.Value(u32) = .init(0) };

/// `Pane.spend_report`.
pub const SpendPane = struct {
    gpa: Allocator,
    /// Heap-allocated, like `abort` and for the same reason: a pane
    /// lives in `PaneStore.slots`, which is an ArrayList, so opening
    /// ANY other pane while a run is in flight moves this struct. An
    /// `Io.Group` cannot be moved once it has a task — the task holds
    /// its address — and a moved one makes `cancel` wait forever,
    /// which is a wedged quit.
    group: *Io.Group,
    snapshot: alloc.SnapshotArena,
    rows: []WsRow = &.{},
    claude_sessions: usize = 0,
    codex_sessions: usize = 0,
    total_tokens: u64 = 0,
    total_cost_usd: f64 = 0,
    sort: SortKey = .cost,
    desc: bool = true,
    cursor: usize = 0,
    scroll: usize = 0,
    loading: bool = false,
    /// Heap-allocated: the worker holds a pointer past the pane's moves.
    abort: *Abort,
    generation: u32 = 0,
    home: ?[]u8 = null,

    pub fn init(gpa: Allocator, home: ?[]const u8) Allocator.Error!SpendPane {
        const abort = try gpa.create(Abort);
        errdefer gpa.destroy(abort);
        abort.* = .{};
        const grp = try gpa.create(Io.Group);
        errdefer gpa.destroy(grp);
        grp.* = .init;
        return .{ .gpa = gpa, .snapshot = alloc.SnapshotArena.init(gpa), .abort = abort, .group = grp, .home = if (home) |h| try gpa.dupe(u8, h) else null };
    }

    pub fn deinit(self: *SpendPane, io: Io) void {
        self.abort.generation.store(std.math.maxInt(u32), .release);
        self.group.cancel(io);
        self.gpa.destroy(self.group);
        self.gpa.destroy(self.abort);
        if (self.home) |h| self.gpa.free(h);
        self.snapshot.deinit();
    }

    pub fn sessions(self: *const SpendPane) usize {
        return self.claude_sessions + self.codex_sessions;
    }
};

// ─── open / refresh ─────────────────────────────────────────────────────

pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.spend_report);
}

/// `ai.spend_today`: the one report pane, beside the active pane; a
/// refresh when it is already open. The toast fires before the worker
/// could have answered, so the user sees the action land.
fn openCmd(app: *App) CommandError!void {
    if (find(app)) |id| {
        app.showPane(id);
        try refresh(app, id);
    } else {
        var pane = try SpendPane.init(app.gpa, app.homeDir());
        errdefer pane.deinit(app.io);
        const id = try app.panes.add(.{ .spend_report = pane });
        pane = undefined;
        const layout = app.layouts.current();
        if (app.active) |cur| if (layout.leafOf(cur) != null) {
            _ = layout.split(cur, .horizontal, id) catch {};
        };
        app.showPane(id);
        try refresh(app, id);
    }
    app.toast("computing spend… (background)", .{});
}

pub fn open(app: *App) CommandError!void {
    return openCmd(app);
}

/// Restart the worker: the old one sees its generation move and stops.
pub fn refresh(app: *App, id: PaneId) CommandError!void {
    const pane = app.panes.get(id) orelse return;
    const p = switch (pane.*) {
        .spend_report => |*p| p,
        else => return,
    };
    p.generation +%= 1;
    p.abort.generation.store(p.generation, .release);
    p.loading = true;
    app.needs_render = true;
    const home = p.home orelse {
        // Nothing to read: an empty result, at once.
        const r = try Result.create(app.gpa, p.generation, id);
        app.events.post(app.io, .{ .spend = r });
        return;
    };
    p.group.concurrent(app.io, worker, .{ &app.events, app.io, app.gpa, home, p.generation, @as(?PaneId, id), p.abort }) catch |err| {
        p.loading = false;
        return app.diag.fail(app.frame.allocator(), "spend: could not start the worker: {s}", .{@errorName(err)});
    };
}

/// `ai.refresh_usage`: the meter's numbers, no pane.
pub fn refreshMeter(app: *App) CommandError!void {
    const home = app.homeDir() orelse return app.diag.fail(app.frame.allocator(), "AI usage: no home directory to read transcripts from", .{});
    app.ai.meter_generation +%= 1;
    app.ai.spend_group.concurrent(app.io, worker, .{ &app.events, app.io, app.gpa, home, app.ai.meter_generation, @as(?PaneId, null), @as(*Abort, &meter_abort) }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "AI usage: could not start the worker: {s}", .{@errorName(err)});
    };
    app.toast("computing AI usage… (background)", .{});
}

/// The meter never aborts a worker early; it just drops stale results.
var meter_abort: Abort = .{};

pub fn anyLoading(app: *const App) bool {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .spend_report => |*p| if (p.loading) return true,
        else => {},
    };
    return false;
}

// ─── the worker ─────────────────────────────────────────────────────────

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, home: []const u8, generation: u32, pane: ?PaneId, abort: *Abort) Io.Cancelable!void {
    const result = Result.create(gpa, generation, pane) catch return;
    errdefer result.destroy(gpa);
    compute(io, gpa, home, result, abort) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => {
            const owned = gpa.dupe(u8, "out of memory computing the spend") catch return;
            events.post(io, .{ .err = .{ .source = .ai, .msg = owned } });
            return;
        },
    };
    events.post(io, .{ .spend = result });
}

const ComputeError = Io.Cancelable || Allocator.Error;

const Bucket = struct { tokens: u64 = 0, cost: f64 = 0, sessions: usize = 0 };

/// Sum every transcript touched inside the window into `r`. Reads the
/// whole file up to `max_read` — the tail would undercount a long
/// session. Stops between files when the generation has moved on.
pub fn compute(io: Io, gpa: Allocator, home: []const u8, r: *Result, abort: *Abort) ComputeError!void {
    const arena = r.arena.allocator();
    var buckets: std.StringArrayHashMapUnmanaged(Bucket) = .empty;
    defer buckets.deinit(gpa);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const cutoff = now - window_s;
    const stale = struct {
        fn f(a: *Abort, g: u32) bool {
            const cur = a.generation.load(.acquire);
            return cur != 0 and cur != g;
        }
    };
    // Claude.
    const projects = try std.fs.path.join(arena, &.{ home, ".claude", "projects" });
    if (Io.Dir.cwd().openDir(io, projects, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var dirs = root.iterate();
        while (dirs.next(io) catch null) |d| {
            if (d.kind != .directory) continue;
            if (stale.f(abort, r.generation)) {
                r.aborted = true;
                break;
            }
            try io.checkCancel();
            var sub = root.openDir(io, d.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const ws = try arena.dupe(u8, transcript.decodeWorkspaceLabel(d.name));
            var files = sub.iterate();
            while (files.next(io) catch null) |f| {
                if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".jsonl")) continue;
                const st = sub.statFile(io, f.name, .{}) catch continue;
                if (st.mtime.toSeconds() < cutoff) continue;
                if (stale.f(abort, r.generation)) {
                    r.aborted = true;
                    break;
                }
                try io.checkCancel();
                const text = sub.readFileAlloc(io, f.name, gpa, .limited(max_read)) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                defer gpa.free(text);
                var scratch = std.heap.ArenaAllocator.init(gpa);
                defer scratch.deinit();
                const stats = try transcript.parseClaude(scratch.allocator(), text);
                const cost = stats.costUsd();
                r.claude_sessions += 1;
                r.total_tokens += stats.tokens;
                r.total_cost_usd += cost;
                const gop = try buckets.getOrPut(gpa, ws);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.tokens += stats.tokens;
                gop.value_ptr.cost += cost;
                gop.value_ptr.sessions += 1;
            }
        }
    } else |_| {}
    // Codex.
    const sessions = try std.fs.path.join(arena, &.{ home, ".codex", "sessions" });
    if (!r.aborted) if (Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var walker = root.walk(gpa) catch return error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            if (st.mtime.toSeconds() < cutoff) continue;
            if (stale.f(abort, r.generation)) {
                r.aborted = true;
                break;
            }
            try io.checkCancel();
            const text = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_read)) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer gpa.free(text);
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const stats = try transcript.parseCodex(scratch.allocator(), text);
            const cost = stats.costUsd();
            const ws = try arena.dupe(u8, if (stats.cwd) |c| std.fs.path.basename(c) else "?");
            r.codex_sessions += 1;
            r.total_tokens += stats.tokens;
            r.total_cost_usd += cost;
            const gop = try buckets.getOrPut(gpa, ws);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.tokens += stats.tokens;
            gop.value_ptr.cost += cost;
            gop.value_ptr.sessions += 1;
        }
    } else |_| {};
    const rows = try arena.alloc(WsRow, buckets.count());
    for (buckets.keys(), buckets.values(), 0..) |k, v, i| rows[i] = .{ .workspace = k, .tokens = v.tokens, .cost_usd = v.cost, .sessions = v.sessions };
    r.rows = rows;
}

// ─── the event handler (D1) ─────────────────────────────────────────────

/// `result` is destroyed on every path. A pane's stale generation, or a
/// pane that closed, is dropped; the meter keeps the newest.
pub fn handle(app: *App, result: *Result) Allocator.Error!void {
    defer result.destroy(app.gpa);
    if (result.pane) |id| {
        const pane = app.panes.get(id) orelse return;
        const p = switch (pane.*) {
            .spend_report => |*p| p,
            else => return,
        };
        if (result.generation != p.generation or result.aborted) return;
        p.loading = false;
        p.snapshot.reset();
        p.rows = &.{};
        const arena = p.snapshot.allocator();
        const rows = try arena.alloc(WsRow, result.rows.len);
        for (result.rows, 0..) |src, i| rows[i] = .{ .workspace = try arena.dupe(u8, src.workspace), .tokens = src.tokens, .cost_usd = src.cost_usd, .sessions = src.sessions };
        p.rows = rows;
        p.claude_sessions = result.claude_sessions;
        p.codex_sessions = result.codex_sessions;
        p.total_tokens = result.total_tokens;
        p.total_cost_usd = result.total_cost_usd;
        sortRows(p);
        if (p.cursor >= p.rows.len) p.cursor = p.rows.len -| 1;
        app.ai.meter = .{ .tokens = result.total_tokens, .cost_usd = result.total_cost_usd, .sessions = result.sessions(), .at_ms = app.now_ms };
        var buf: [16]u8 = undefined;
        app.toast("AI spend (24h): {s} tokens · ${d:.4} · {d} sessions", .{ transcript.fmtTokens(&buf, result.total_tokens), result.total_cost_usd, result.sessions() });
    } else {
        if (result.generation != app.ai.meter_generation) return;
        app.ai.meter = .{ .tokens = result.total_tokens, .cost_usd = result.total_cost_usd, .sessions = result.sessions(), .at_ms = app.now_ms };
        var buf: [16]u8 = undefined;
        app.toast("AI usage (24h): {s} tokens · ${d:.4} · {d} sessions", .{ transcript.fmtTokens(&buf, result.total_tokens), result.total_cost_usd, result.sessions() });
    }
    app.needs_render = true;
}

pub fn sortRows(p: *SpendPane) void {
    const Ctx = struct {
        key: SortKey,
        desc: bool,
        fn lt(ctx: @This(), a: WsRow, b: WsRow) bool {
            const less = switch (ctx.key) {
                .workspace => std.mem.order(u8, a.workspace, b.workspace) == .lt,
                .tokens => a.tokens < b.tokens,
                .cost => a.cost_usd < b.cost_usd,
            };
            const greater = switch (ctx.key) {
                .workspace => std.mem.order(u8, a.workspace, b.workspace) == .gt,
                .tokens => a.tokens > b.tokens,
                .cost => a.cost_usd > b.cost_usd,
            };
            return if (ctx.desc) greater else less;
        }
    };
    std.mem.sort(WsRow, p.rows, Ctx{ .key = p.sort, .desc = p.desc }, Ctx.lt);
}

// ─── keys / mouse ───────────────────────────────────────────────────────

pub const hit_title: u32 = 0;
pub const hit_head_workspace: u32 = 1;
pub const hit_head_tokens: u32 = 2;
pub const hit_head_cost: u32 = 3;
pub const hit_refresh: u32 = 4;
pub const row_base: u32 = 0x1000;

pub fn handleKey(app: *App, id: PaneId, p: *SpendPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    const last = p.rows.len -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .esc => try app.forceClosePane(id),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.cursor = @min(p.cursor + 1, last),
                'k' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                'r' => refresh(app, id) catch {},
                's' => {
                    p.sort = p.sort.next();
                    sortRows(p);
                },
                'S' => {
                    p.desc = !p.desc;
                    sortRows(p);
                },
                'e' => exportMarkdown(app, p) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
                },
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

/// A click on a header cycles the key (same key flips the direction);
/// on a row selects it.
pub fn click(app: *App, id: PaneId, p: *SpendPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    if (hit_id >= row_base) {
        const i: usize = hit_id - row_base;
        if (i < p.rows.len) p.cursor = i;
        app.needs_render = true;
        return;
    }
    const key: ?SortKey = switch (hit_id) {
        hit_head_workspace => .workspace,
        hit_head_tokens => .tokens,
        hit_head_cost => .cost,
        hit_refresh => {
            refresh(app, id) catch {};
            return;
        },
        else => null,
    };
    if (key) |k| {
        if (p.sort == k) p.desc = !p.desc else p.sort = k;
        sortRows(p);
        app.needs_render = true;
    }
}

pub fn scrollBy(p: *SpendPane, delta: i64) void {
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(p.rows.len -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

/// `e`: the table as markdown under `.mnml/`, opened in an editor.
fn exportMarkdown(app: *App, p: *SpendPane) CommandError!void {
    const arena = app.frame.allocator();
    const md = try markdown(arena, p);
    const dir = try std.fs.path.join(arena, &.{ app.workspace, ".mnml" });
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    const path = try std.fmt.allocPrint(arena, "{s}/ai-spend-{d}.md", .{ dir, app.now_ms });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = md }) catch |err| return app.diag.fail(arena, "write {s}: {s}", .{ path, @errorName(err) });
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    app.toast("exported {s}", .{app.relPath(path)});
}

pub fn markdown(arena: Allocator, p: *const SpendPane) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [16]u8 = undefined;
    try out.print(arena, "# AI spend (24h)\n\n{d} sessions · {s} tokens · ${d:.4}\n\n| workspace | sessions | tokens | cost |\n|---|---:|---:|---:|\n", .{ p.sessions(), transcript.fmtTokens(&buf, p.total_tokens), p.total_cost_usd });
    for (p.rows) |r| try out.print(arena, "| {s} | {d} | {d} | ${d:.4} |\n", .{ r.workspace, r.sessions, r.tokens, r.cost_usd });
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

test "compute: sums the transcripts inside the window, buckets by workspace, stops when the generation moves" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const home = buf[0..n];
    try tmp.dir.createDirPath(t.io, ".claude/projects/-Users-me-Projects-mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".claude/projects/-Users-me-Projects-mnml/a.jsonl", .data = transcript.claude_fixture });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".claude/projects/-Users-me-Projects-mnml/b.jsonl", .data = transcript.claude_fixture });
    try tmp.dir.createDirPath(t.io, ".codex/sessions/2026/09/04");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".codex/sessions/2026/09/04/rollout-x.jsonl", .data = transcript.codex_fixture });
    var abort: Abort = .{};
    const r = try Result.create(t.allocator, 1, null);
    defer r.destroy(t.allocator);
    try compute(t.io, t.allocator, home, r, &abort);
    try t.expectEqual(@as(usize, 2), r.claude_sessions);
    try t.expectEqual(@as(usize, 1), r.codex_sessions);
    try t.expectEqual(@as(u64, 1620 * 2 + 540), r.total_tokens);
    try t.expectEqual(@as(usize, 2), r.rows.len);
    try t.expect(r.total_cost_usd > 0.02);
    // The generation moved: the worker gives up before reading.
    abort.generation.store(9, .release);
    const r2 = try Result.create(t.allocator, 1, null);
    defer r2.destroy(t.allocator);
    try compute(t.io, t.allocator, home, r2, &abort);
    try t.expect(r2.aborted);
    try t.expectEqual(@as(usize, 0), r2.claude_sessions);
}

test "ai.spend_today opens the pane beside the editor, toasts, and a stale result is dropped while the live one lands" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/w", .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.spend_today" });
    const id = find(&app).?;
    try t.expect(id != ed);
    try t.expectEqualStrings("computing spend… (background)", app.lastToast().?);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    const p = &app.panes.get(id).?.spend_report;
    try t.expect(p.loading);
    // No home: the empty result was posted at once and lands on the tick.
    try app.tick(app.now_ms);
    try t.expect(!p.loading);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "AI spend (24h)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "sort:") != null);
    // `r` restarts: loading again, generation moved.
    const g = p.generation;
    try app.handle(.{ .key = Key.char('r') });
    try t.expect(p.generation != g);
    try app.tick(app.now_ms);
    try t.expect(!p.loading);
    // A hand-made result for an old generation is dropped; the live one is adopted and sorted.
    const stale = try Result.create(t.allocator, g, id);
    stale.total_tokens = 999;
    try app.handle(.{ .spend = stale });
    try t.expectEqual(@as(u64, 0), p.total_tokens);
    const live = try Result.create(t.allocator, p.generation, id);
    const la = live.arena.allocator();
    live.rows = try la.dupe(WsRow, &.{ .{ .workspace = "a", .tokens = 10, .cost_usd = 0.1, .sessions = 1 }, .{ .workspace = "b", .tokens = 50, .cost_usd = 0.5, .sessions = 2 } });
    live.total_tokens = 60;
    live.total_cost_usd = 0.6;
    live.claude_sessions = 3;
    try app.handle(.{ .spend = live });
    try t.expectEqual(@as(u64, 60), p.total_tokens);
    try t.expectEqualStrings("b", p.rows[0].workspace);
    try app.handle(.{ .key = Key.char('s') });
    try t.expectEqual(SortKey.workspace, p.sort);
    try t.expectEqualStrings("b", p.rows[0].workspace); // desc
    try app.handle(.{ .key = Key.char('S') });
    try t.expectEqualStrings("a", p.rows[0].workspace);
    try t.expect(app.ai.meter != null);
    try t.expectEqual(@as(u64, 60), app.ai.meter.?.tokens);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const md = try markdown(arena.allocator(), p);
    try t.expect(std.mem.indexOf(u8, md, "| a | 1 | 10 | $0.1000 |") != null);
    // The pane closes with the worker cancelled and nothing leaked.
    try app.handle(.{ .key = Key.char('q') });
    try t.expect(find(&app) == null);
}

// ─── the group must not move ────────────────────────────────────────────

/// A worker parked on a pipe nobody writes to — `e2e/cancel_probe.zig`'s
/// shape, and the worst case for `Io.Group.cancel`.
const MoveProbe = struct {
    io: Io,
    fd: std.posix.fd_t,
    /// Set once the worker is about to block.
    entered: Io.Event = .unset,

    fn run(p: *MoveProbe) Io.Cancelable!void {
        const f: Io.File = .{ .handle = p.fd, .flags = .{ .nonblocking = false } };
        var buf: [16]u8 = undefined;
        p.entered.set(p.io);
        _ = f.readStreaming(p.io, &.{&buf}) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
};

/// `SpendPane.deinit` on a thread of its own, so a `cancel` that never
/// returns is a failing test rather than a hung suite.
const Closer = struct {
    pane: *SpendPane,
    io: Io,
    done: Io.Event = .unset,

    fn run(c: *Closer) void {
        c.pane.deinit(c.io);
        c.done.set(c.io);
    }
};

// `tools/break-check.sh` cannot grade this one: with the break in
// place the test FAILS by name (the watchdog, at ~10 s), but the
// abandoned worker then touches the group it was started with — the
// memory the moved pane no longer owns — and the binary dies before
// the runner prints its per-binary summary, which is the line the
// script counts. Break-check it by hand, under a hard timeout, and
// read the `FAIL … (SpendGroupMovedAndCancelWedged)` verdict line.
test "the spend pane's group survives the pane store moving it under a live worker" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = t.io;
    // `NoRemap` so the store's growth really relocates the panes — the
    // whole point of the test (`core/alloc.zig`).
    var nr = alloc.NoRemap.init(t.allocator);
    const gpa = nr.allocator();

    const fds = try Io.Threaded.pipe2(.{});
    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);
    defer write_end.close(io);

    // No `defer store.deinit()`: past the watchdog the pane is wedged
    // inside the closer thread's `deinit` and must not be deinit'd twice.
    var store = app_mod.PaneStore.init(gpa, io);
    const id = try store.add(.{ .spend_report = try SpendPane.init(gpa, null) });

    var probe: MoveProbe = .{ .io = io, .fd = fds[0] };
    try store.get(id).?.spend_report.group.concurrent(io, MoveProbe.run, .{&probe});
    try probe.entered.wait(io);
    try io.sleep(.fromMilliseconds(50), .awake);

    // Open panes until `slots` reallocates: the pane — and anything
    // living inside it — moves, which is what opening any pane during a
    // run does in the app.
    const capacity_before = store.slots.capacity;
    const addr_before = @intFromPtr(&store.slots.items[id].?.spend_report);
    while (store.slots.capacity == capacity_before) _ = try store.add(.{ .git_status = .{ .repo = 0 } });
    try t.expect(@intFromPtr(&store.slots.items[id].?.spend_report) != addr_before);

    var closer: Closer = .{ .pane = &store.slots.items[id].?.spend_report, .io = io };
    const th = try std.Thread.spawn(.{}, Closer.run, .{&closer});
    closer.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } }) catch |err| switch (err) {
        // The group moved with the pane: the running task holds the
        // address the group had before, and `cancel` waits forever on a
        // task the group at the new address cannot see.
        error.Timeout => return error.SpendGroupMovedAndCancelWedged,
        error.Canceled => return error.Canceled,
    };
    th.join();
    store.slots.items[id] = null; // `Closer` has already deinit'd it
    store.deinit();
}
