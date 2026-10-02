//! The sessions table — `Pane.sessions_table`, `sessions.table`: every
//! row of `sessions.State` (this machine's Claude Code / Codex sessions
//! and, configured, the cloud runs) as a `ListPanel` hosted by a pane,
//! grouped by workspace. The rows are the section's; this pane holds
//! the view — the cursor, the ticks, the filters, the collapsed groups,
//! the pause — and rebuilds `visible` whenever the snapshot changes
//! (`onSnapshot`, called by `sessions.handle`).
//!
//! Ended sessions older than a day are hidden by default (the header's
//! `ended:` chip shows them); the last message is shown ONLY in the
//! summary block under the list, never on a row; the chord hints live
//! in `? help`, like the other panes'. The painter is
//! `ui/sessions_table_view.zig`.
//!
//! // changed (sessions-merge): replaces the Claude Agents dashboard
//! (`Pane.claude_agents`). `ai.dashboard` and `view.activity_agents`
//! open this pane; the dashboard's row ids resolve to the session
//! commands (`sessions.zig`'s table).

const std = @import("std");
/// The one "does this pane have the keys" (`render.paneFocused`).
const paneFocused = @import("render.zig").paneFocused;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const view = @import("../ui/sessions_table_view.zig");
const sessions = @import("../sessions.zig");
const agents = @import("agents.zig");
const cloud_agents = @import("cloud_agents.zig");
const auto_refresh = @import("auto_refresh.zig");
const todos = @import("../todos.zig");

pub const Item = sessions.Item;
pub const AgentState = agents.AgentState;
pub const Where = sessions.Where;

pub const table = .{
    .@"sessions.table" = &openCmd,
    .@"ai.dashboard" = &openCmd,
    .@"sessions.show_ended" = &showEndedCmd,
    .@"sessions.pause" = &pauseCmd,
    .@"sessions.select" = &selectCmd,
    .@"sessions.select_clear" = &selectClearCmd,
    .@"sessions.toggle_group" = &toggleGroupCmd,
    .@"sessions.where" = &whereCmd,
    .@"sessions.table_sort" = &sortCmd,
    .@"agents.new_from_pr" = &newFromPr,
};

/// An ended session older than this is hidden unless the chip shows it.
pub const hide_ended_s: i64 = 24 * 3600;

pub const Sort = enum {
    state,
    tokens,
    cost,
    recent,

    pub fn label(s: Sort) []const u8 {
        return @tagName(s);
    }
    pub fn next(s: Sort) Sort {
        return switch (s) {
            .state => .tokens,
            .tokens => .cost,
            .cost => .recent,
            .recent => .state,
        };
    }
    pub const widest: usize = 6;
};

/// A group row's view.
pub const GroupView = struct {
    key: []const u8,
    label: []const u8,
    where: Where,
    /// Rows shown under it.
    count: usize,
    /// Ended rows the chip hides.
    hidden: usize,
    collapsed: bool,
};

/// A session row's view.
pub const ItemView = struct {
    it: Item,
    name: []const u8,
    ticked: bool,
    /// Its pty pane is the active one.
    active: bool,
    pinned: bool,
    /// // changed (colors): the session's accent, a palette name.
    color: ?[]const u8 = null,
    /// // changed (sessions-worktree): the session worktree's name — a
    /// muted `⑂ <name>` after the label.
    worktree: ?[]const u8 = null,
};

/// What `ListPanel` paints: a group header or a session.
pub const Row = union(enum) { group: GroupView, item: ItemView };

pub const Panel = list_panel.ListPanel(Row);

/// What `visible` holds: an index into `groups`, or into the section's items.
pub const Entry = union(enum) { group: u32, item: u32 };

pub const Group = struct {
    /// Borrowed from the section's snapshot until the next `onSnapshot`.
    key: []const u8,
    label: []const u8,
    where: Where,
    count: usize = 0,
    hidden: usize = 0,
    best_rank: u8 = 255,
    latest_s: i64 = 0,
    is_workspace: bool = false,
};

/// The header chips' `.script_hit` ids (below `hit.ListHit.chip_base`).
pub const hit_ended: u32 = 1;
pub const hit_where: u32 = 2;
pub const hit_pause: u32 = 3;
pub const hit_help: u32 = 4;
pub const hit_summary: u32 = 5;

pub const TablePane = struct {
    gpa: Allocator,
    list: Panel.State = .{},
    visible: std.ArrayListUnmanaged(Entry) = .empty,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    /// Session ids ticked with space. Owned keys.
    multi: std.StringHashMapUnmanaged(void) = .empty,
    /// Group keys folded away. Owned.
    collapsed: std.ArrayListUnmanaged([]u8) = .empty,
    show_ended: bool = false,
    paused: bool = false,
    help: bool = false,
    state_filter: ?AgentState = null,
    where_filter: ?Where = null,
    sort: Sort = .state,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,
    /// `onSnapshot` ran at least once.
    built: bool = false,
    /// The session under the cursor before a snapshot swap, so the
    /// cursor can follow it (`noteSelection` → `refilter`). Owned.
    keep: ?[]u8 = null,

    pub fn init(gpa: Allocator) TablePane {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TablePane) void {
        var it = self.multi.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.multi.deinit(self.gpa);
        for (self.collapsed.items) |k| self.gpa.free(k);
        self.collapsed.deinit(self.gpa);
        self.visible.deinit(self.gpa);
        self.groups.deinit(self.gpa);
        self.list.deinit(self.gpa);
        if (self.keep) |k| self.gpa.free(k);
    }

    pub fn selectedEntry(self: *const TablePane) ?Entry {
        if (self.list.on_new or self.list.cursor >= self.visible.items.len) return null;
        return self.visible.items[self.list.cursor];
    }

    /// The session under the cursor (a group row has none).
    pub fn selectedItem(self: *const TablePane, app: *App) ?Item {
        const e = self.selectedEntry() orelse return null;
        return switch (e) {
            .item => |i| if (i < app.sessions.items.len) app.sessions.items[i] else null,
            .group => null,
        };
    }

    pub fn isCollapsed(self: *const TablePane, key: []const u8) bool {
        for (self.collapsed.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    pub fn anyFilter(self: *const TablePane) bool {
        return self.list.filterText().len > 0 or self.state_filter != null or self.where_filter != null;
    }
};

pub const Aggregate = struct {
    waiting: usize = 0,
    live: usize = 0,
    tool: usize = 0,
    idle: usize = 0,
    failed: usize = 0,
    done: usize = 0,
    dirty_ended: usize = 0,
    hidden: usize = 0,
    cloud: usize = 0,
    tokens: u64 = 0,
    cost: f64 = 0,
};

/// The counts over every row the section holds (not just the visible
/// ones): the summary block's first line.
pub fn aggregate(app: *App, tp: *const TablePane, now_s: i64) Aggregate {
    var a: Aggregate = .{};
    for (app.sessions.items) |r| {
        switch (r.state) {
            .waiting => a.waiting += 1,
            .streaming => a.live += 1,
            .tool_call => a.tool += 1,
            .idle => a.idle += 1,
            .failed => a.failed += 1,
            .done => a.done += 1,
        }
        if (r.dirtyEnded()) a.dirty_ended += 1;
        if (r.where == .cloud) a.cloud += 1;
        if (!tp.show_ended and hiddenByDefault(r, now_s)) a.hidden += 1;
        a.tokens += r.tokens;
        a.cost += r.cost_usd;
    }
    return a;
}

/// The hidden-ended rule: ended, and quiet for over a day.
pub fn hiddenByDefault(it: Item, now_s: i64) bool {
    return it.state.ended() and now_s - it.last_activity_s > hide_ended_s;
}

// ─── open / find ────────────────────────────────────────────────────────

/// The one table pane, if open.
pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.sessions_table);
}

pub fn get(app: *App, id: PaneId) ?*TablePane {
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .sessions_table => |*tp| tp,
        else => null,
    };
}

/// The table pane when it is the active pane with the keys.
pub fn focused(app: *App) ?*TablePane {
    if (app.focus != .pane) return null;
    const id = app.active orelse return null;
    return get(app, id);
}

/// A table pane is open and not paused: the sessions cadence runs.
pub fn wantsScan(app: *const App) bool {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .sessions_table => |*tp| if (!tp.paused and !tp.list.filter_focused) return true,
        else => {},
    };
    return false;
}

/// `sessions.table` / `ai.dashboard` / `view.activity_agents`: show the
/// table (opening it beside the active pane), and rescan.
pub fn openCmd(app: *App) CommandError!void {
    if (find(app)) |id| {
        app.showPane(id);
        app.focus = .{ .pane = id };
        return sessions.refresh(app);
    }
    const id = try app.panes.add(.{ .sessions_table = TablePane.init(app.gpa) });
    app.showPane(id);
    app.focus = .{ .pane = id };
    try onSnapshot(app);
    try sessions.refresh(app);
}

/// `focus-session` over the IPC channel: show the table and put the
/// cursor on the session a pane named. A pane that dispatched a session
/// can only say what a `term` line could carry — the directory it runs
/// in and the first line of its prompt — so those match too, newest
/// first. Returns the id it landed on, or null when nothing matched.
pub fn focusSession(app: *App, sel: Selector) CommandError!?[]const u8 {
    try openCmd(app);
    const tp = find(app) orelse return null;
    const pane = get(app, tp) orelse return null;
    var best: ?Item = null;
    for (app.sessions.items) |it| {
        if (!sel.matches(it)) continue;
        // Several can match a cwd + prompt pair; the newest is the one
        // the press just started.
        if (best) |b| if (b.last_activity_s >= it.last_activity_s) continue;
        best = it;
    }
    const want = best orelse return null;
    for (pane.visible.items, 0..) |e, i| {
        const it = switch (e) {
            .item => |idx| if (idx < app.sessions.items.len) app.sessions.items[idx] else continue,
            else => continue,
        };
        if (!std.mem.eql(u8, it.session_id, want.session_id)) continue;
        pane.list.cursor = i;
        pane.list.on_new = false;
        app.needs_render = true;
        return it.session_id;
    }
    return null;
}

/// How a pane names the session it wants focused.
pub const Selector = struct {
    id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    prompt_line: ?[]const u8 = null,

    pub fn matches(sel: Selector, it: Item) bool {
        if (sel.id) |id| return std.mem.eql(u8, it.session_id, id);
        var ok = false;
        if (sel.cwd) |c| {
            const have = it.cwd orelse return false;
            if (!std.mem.eql(u8, have, c)) return false;
            ok = true;
        }
        if (sel.prompt_line) |line| {
            const msg = it.last_user_msg orelse return false;
            if (std.mem.indexOf(u8, msg, line) == null) return false;
            ok = true;
        }
        return ok;
    }
};

/// Before the section swaps its snapshot: every table pane notes the
/// session under its cursor (the indices in `visible` go stale).
pub fn noteSelection(app: *App) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .sessions_table => |*tp| {
            if (tp.keep) |k| app.gpa.free(k);
            tp.keep = if (tp.selectedItem(app)) |it| try app.gpa.dupe(u8, it.session_id) else null;
        },
        else => {},
    };
}

/// The snapshot changed (or a filter did): every table pane rebuilds.
pub fn onSnapshot(app: *App) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .sessions_table => |*tp| try refilter(app, tp),
        else => {},
    };
}

/// Groups by `Item.groupKey`, the workspace's own group first, then the
/// group holding the most urgent state, then the most recent; within a
/// group the sort axis, newest first on a tie. The filters (state,
/// where, the text) and the hidden-ended rule narrow the rows; a group
/// with nothing left is not painted; a collapsed one keeps its row.
pub fn refilter(app: *App, tp: *TablePane) Allocator.Error!void {
    const gpa = app.gpa;
    const keep: ?[]const u8 = if (tp.keep) |k| try app.frame.allocator().dupe(u8, k) else if (tp.selectedItem(app)) |it| try app.frame.allocator().dupe(u8, it.session_id) else null;
    if (tp.keep) |k| gpa.free(k);
    tp.keep = null;
    tp.visible.clearRetainingCapacity();
    tp.groups.clearRetainingCapacity();
    tp.built = true;
    const now_s = sessions.wallNowS(app);
    const q = tp.list.filterText();
    const items = app.sessions.items;
    // Pass 1: the groups and each row's membership.
    const member = try app.frame.allocator().alloc(?u32, items.len);
    for (items, 0..) |it, i| {
        member[i] = null;
        const key = it.groupKey();
        var gi: ?usize = null;
        for (tp.groups.items, 0..) |g, j| if (std.mem.eql(u8, g.key, key)) {
            gi = j;
            break;
        };
        if (gi == null) {
            try tp.groups.append(gpa, .{ .key = key, .label = it.groupLabel(), .where = it.where, .is_workspace = it.where == .local and isWorkspace(app, it) });
            gi = tp.groups.items.len - 1;
        }
        const g = &tp.groups.items[gi.?];
        if (!tp.show_ended and hiddenByDefault(it, now_s)) {
            g.hidden += 1;
            continue;
        }
        if (tp.state_filter) |s| if (it.state != s) continue;
        if (tp.where_filter) |w| if (it.where != w) continue;
        if (q.len > 0 and !matches(app, it, q)) continue;
        member[i] = @intCast(gi.?);
        g.count += 1;
        g.best_rank = @min(g.best_rank, it.state.rank());
        g.latest_s = @max(g.latest_s, it.last_activity_s);
    }
    // Pass 2: the group order.
    const order = try app.frame.allocator().alloc(u32, tp.groups.items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const GroupCtx = struct {
        groups: []const Group,
        fn lt(ctx: @This(), a: u32, b: u32) bool {
            const ga = ctx.groups[a];
            const gb = ctx.groups[b];
            if (ga.is_workspace != gb.is_workspace) return ga.is_workspace;
            if (ga.best_rank != gb.best_rank) return ga.best_rank < gb.best_rank;
            if (ga.latest_s != gb.latest_s) return ga.latest_s > gb.latest_s;
            return std.mem.order(u8, ga.label, gb.label) == .lt;
        }
    };
    std.mem.sort(u32, order, GroupCtx{ .groups = tp.groups.items }, GroupCtx.lt);
    // Pass 3: the rows, sorted within their group.
    var idx: std.ArrayListUnmanaged(u32) = .empty;
    defer idx.deinit(gpa);
    for (order) |gi| {
        const g = tp.groups.items[gi];
        // // changed: a group whose every session is hidden is not painted
        // either — the summary counts them and, with nothing else listed,
        // the empty state points at E.
        if (g.count == 0) continue;
        try tp.visible.append(gpa, .{ .group = gi });
        if (tp.isCollapsed(g.key)) continue;
        idx.clearRetainingCapacity();
        for (member, 0..) |m, i| if (m != null and m.? == gi) try idx.append(gpa, @intCast(i));
        const RowCtx = struct {
            st: *const sessions.State,
            sort: Sort,
            fn lt(ctx: @This(), a: u32, b: u32) bool {
                const ia = ctx.st.items[a];
                const ib = ctx.st.items[b];
                const pa = ctx.st.isPinned(ia.session_id);
                const pb = ctx.st.isPinned(ib.session_id);
                if (pa != pb) return pa;
                switch (ctx.sort) {
                    .state => if (ia.state.rank() != ib.state.rank()) return ia.state.rank() < ib.state.rank(),
                    .tokens => if (ia.tokens != ib.tokens) return ia.tokens > ib.tokens,
                    .cost => if (ia.cost_usd != ib.cost_usd) return ia.cost_usd > ib.cost_usd,
                    .recent => {},
                }
                if (ia.last_activity_s != ib.last_activity_s) return ia.last_activity_s > ib.last_activity_s;
                return std.mem.order(u8, ia.session_id, ib.session_id) == .lt;
            }
        };
        std.mem.sort(u32, idx.items, RowCtx{ .st = &app.sessions, .sort = tp.sort }, RowCtx.lt);
        for (idx.items) |i| try tp.visible.append(gpa, .{ .item = i });
    }
    // The cursor follows its session; else it is clamped.
    if (keep) |sid| for (tp.visible.items, 0..) |e, vi| switch (e) {
        .item => |i| if (std.mem.eql(u8, items[i].session_id, sid)) {
            tp.list.cursor = vi;
            break;
        },
        .group => {},
    };
    // `ListPanel.handleKey` reads `total` — set by `draw`, and here so
    // a key between two frames sees the rows too.
    tp.list.total = tp.visible.items.len;
    if (tp.list.cursor >= tp.visible.items.len) tp.list.cursor = tp.visible.items.len -| 1;
    // A fresh cursor lands on the first session, not its group's row.
    if (keep == null and tp.list.cursor == 0 and tp.visible.items.len > 1 and tp.visible.items[0] == .group) tp.list.cursor = 1;
    app.needs_render = true;
}

fn isWorkspace(app: *App, it: Item) bool {
    if (it.cwd) |c| if (std.mem.eql(u8, c, app.workspace)) return true;
    return std.mem.eql(u8, it.workspace, std.fs.path.basename(app.workspace));
}

fn matches(app: *App, it: Item, q: []const u8) bool {
    if (app.sessions.alias(it.session_id)) |a| if (todos.containsIgnoreCase(a, q)) return true;
    if (it.last_user_msg) |m| if (todos.containsIgnoreCase(m, q)) return true;
    if (it.model) |m| if (todos.containsIgnoreCase(m, q)) return true;
    if (it.cwd) |c| if (todos.containsIgnoreCase(c, q)) return true;
    return todos.containsIgnoreCase(it.session_id, q) or todos.containsIgnoreCase(it.workspace, q) or
        todos.containsIgnoreCase(it.source.label(), q) or todos.containsIgnoreCase(it.state.label(), q) or
        todos.containsIgnoreCase(it.where.label(), q);
}

// ─── commands ───────────────────────────────────────────────────────────

fn activeTable(app: *App) CommandError!*TablePane {
    const id = app.active orelse return error.NoActivePane;
    return get(app, id) orelse app.diag.fail(app.frame.allocator(), "not the sessions table", .{});
}

/// `E` / the `ended:` chip: show the ended sessions older than a day, or hide them.
fn showEndedCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    tp.show_ended = !tp.show_ended;
    try refilter(app, tp);
    app.toast("sessions: ended {s}", .{if (tp.show_ended) "shown" else "hidden past a day"});
}

/// `p` / the pause chip: the live tail stops rescanning until resumed.
fn pauseCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    tp.paused = !tp.paused;
    app.toast("sessions: auto-refresh {s}", .{if (tp.paused) "paused" else "resumed"});
    app.needs_render = true;
}

/// Space: tick the row for a batch action.
fn selectCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    const it = tp.selectedItem(app) orelse return app.diag.fail(app.frame.allocator(), "sessions: no session under the cursor", .{});
    try toggleMulti(app, tp, it.session_id);
    app.needs_render = true;
}

fn selectClearCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    clearMulti(tp);
    app.needs_render = true;
}

fn toggleMulti(app: *App, tp: *TablePane, sid: []const u8) Allocator.Error!void {
    if (tp.multi.fetchRemove(sid)) |kv| {
        app.gpa.free(kv.key);
        return;
    }
    const key = try app.gpa.dupe(u8, sid);
    errdefer app.gpa.free(key);
    try tp.multi.put(app.gpa, key, {});
}

fn clearMulti(tp: *TablePane) void {
    var it = tp.multi.keyIterator();
    while (it.next()) |k| tp.gpa.free(k.*);
    tp.multi.clearRetainingCapacity();
}

pub fn clearAllMulti(app: *App) void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .sessions_table => |*tp| clearMulti(tp),
        else => {},
    };
}

/// `z` / Enter on a group row: fold the group or open it.
fn toggleGroupCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    const e = tp.selectedEntry() orelse return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    const gi: u32 = switch (e) {
        .group => |g| g,
        .item => |i| blk: {
            const key = app.sessions.items[i].groupKey();
            for (tp.groups.items, 0..) |g, j| if (std.mem.eql(u8, g.key, key)) break :blk @intCast(j);
            return;
        },
    };
    try toggleGroup(app, tp, gi);
}

fn toggleGroup(app: *App, tp: *TablePane, gi: u32) Allocator.Error!void {
    const key = tp.groups.items[gi].key;
    for (tp.collapsed.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
        app.gpa.free(tp.collapsed.orderedRemove(i));
        try refilter(app, tp);
        return;
    };
    const owned = try app.gpa.dupe(u8, key);
    errdefer app.gpa.free(owned);
    try tp.collapsed.append(app.gpa, owned);
    try refilter(app, tp);
    // The cursor lands on the group's row.
    for (tp.visible.items, 0..) |e, vi| switch (e) {
        .group => |g| if (g == gi) {
            tp.list.cursor = vi;
            break;
        },
        .item => {},
    };
}

/// `w` / the `where:` chip: all → local → cloud → all.
fn whereCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    tp.where_filter = if (tp.where_filter) |w| switch (w) {
        .local => .cloud,
        .cloud => null,
    } else .local;
    try refilter(app, tp);
}

/// `s` / the sort chip: state → tokens → cost → recent.
fn sortCmd(app: *App) CommandError!void {
    const tp = try activeTable(app);
    tp.sort = tp.sort.next();
    try refilter(app, tp);
    app.toast("sessions: sort by {s}", .{tp.sort.label()});
}

/// `f`: the state filter, the section's cycle.
pub fn cycleState(app: *App, tp: *TablePane) CommandError!void {
    tp.state_filter = AgentState.next(tp.state_filter);
    try refilter(app, tp);
}

fn newFromPr(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "sessions: a new session from a PR (Agent SDK) is not in this build yet", .{});
}

// ─── keys ───────────────────────────────────────────────────────────────

/// Keys on the table. False lets the chord chain see the key.
pub fn handleKey(app: *App, id: PaneId, tp: *TablePane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    if (tp.help) {
        const f1 = k.code == .f and k.code.f == 1;
        if (k.code == .esc or f1 or (k.code == .char and k.code.char == '?')) tp.help = false;
        return true;
    }
    switch (try Panel.handleKey(&tp.list, app.gpa, k)) {
        .consumed => return true,
        .filter_changed => {
            try refilter(app, tp);
            return true;
        },
        .activate => |i| {
            tp.list.cursor = i;
            switch (tp.visible.items[i]) {
                .group => |g| try toggleGroup(app, tp, g),
                .item => runToast(app, command.run(app, .{ .static = .@"sessions.open" })),
            }
            return true;
        },
        .new_activate => {
            runToast(app, command.run(app, .{ .static = .@"sessions.new_menu" }));
            return true;
        },
        .ignored => {},
    }
    if (tp.list.filter_focused) return false;
    switch (k.code) {
        .esc => try app.forceClosePane(id),
        .f => |n| if (n == 1) {
            tp.help = true;
        } else return false,
        .char => |c| {
            if (k.mods.ctrl and !k.mods.alt and !k.mods.super) switch (c) {
                'l' => {
                    tp.list.filter.clearRetainingCapacity();
                    tp.list.filter_caret = 0;
                    tp.list.filter_anchor = null;
                    tp.state_filter = null;
                    tp.where_filter = null;
                    try refilter(app, tp);
                },
                else => return false,
            } else if (k.mods.alt or k.mods.super) return false else switch (c) {
                '?' => tp.help = true,
                'q' => try app.forceClosePane(id),
                ' ' => runToast(app, selectCmd(app)),
                'U' => runToast(app, selectClearCmd(app)),
                'z' => runToast(app, toggleGroupCmd(app)),
                'E' => runToast(app, showEndedCmd(app)),
                'w' => runToast(app, whereCmd(app)),
                'f' => runToast(app, cycleState(app, tp)),
                's' => runToast(app, sortCmd(app)),
                'p' => runToast(app, pauseCmd(app)),
                'r' => runToast(app, sessions.refresh(app)),
                'o' => runToast(app, command.run(app, .{ .static = .@"sessions.open" })),
                't' => runToast(app, command.run(app, .{ .static = .@"sessions.open_transcript" })),
                'y' => runToast(app, command.run(app, .{ .static = .@"sessions.copy_id" })),
                'c' => runToast(app, command.run(app, .{ .static = .@"sessions.copy_cwd" })),
                'e' => runToast(app, command.run(app, .{ .static = .@"sessions.export" })),
                'K', 'S' => runToast(app, command.run(app, .{ .static = .@"sessions.kill" })),
                'x' => runToast(app, command.run(app, .{ .static = .@"sessions.delete" })),
                'R' => runToast(app, command.run(app, .{ .static = .@"sessions.rename" })),
                'P' => runToast(app, command.run(app, .{ .static = .@"sessions.pin" })),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("sessions: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

const double_click_ms: i64 = 500;

/// A press on a row, a chip, the filter (`.script_hit{pane, id}`).
pub fn click(app: *App, id: PaneId, tp: *TablePane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    app.needs_render = true;
    if (hit_id >= hit.ListHit.kebab_base) {
        const vi = hit_id - hit.ListHit.kebab_base;
        if (vi >= tp.visible.items.len) return;
        tp.list.cursor = vi;
        tp.list.on_new = false;
        return openRowMenu(app, tp, m.x, m.y);
    }
    if (hit_id >= hit.ListHit.row_base) {
        const vi = hit_id - hit.ListHit.row_base;
        if (vi >= tp.visible.items.len) return;
        tp.list.on_new = false;
        tp.list.cursor = vi;
        if (m.button == .right) return openRowMenu(app, tp, m.x, m.y);
        if (m.button != .left) return;
        switch (tp.visible.items[vi]) {
            .group => |g| try toggleGroup(app, tp, g),
            .item => {
                const again = if (tp.last_click) |lc| lc.idx == vi and app.now_ms - lc.at_ms <= double_click_ms else false;
                tp.last_click = .{ .idx = vi, .at_ms = app.now_ms };
                if (again) {
                    tp.last_click = null;
                    runToast(app, command.run(app, .{ .static = .@"sessions.open" }));
                }
            },
        }
        return;
    }
    if (hit_id == hit.ListHit.filter_id) {
        tp.list.filter_focused = true;
        return;
    }
    if (hit.ListHit.chipOf(hit_id)) |kind| switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, tp, m.x, m.y) else runToast(app, sortCmd(app)),
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .sessions, m.x, m.y) else runToast(app, sessions.refresh(app)),
        .new => try sessions.openNewMenu(app, m.x, m.y + 1),
        .history => {},
    };
    switch (hit_id) {
        hit_ended => runToast(app, showEndedCmd(app)),
        hit_where => runToast(app, whereCmd(app)),
        hit_pause => runToast(app, pauseCmd(app)),
        hit_help => tp.help = !tp.help,
        hit_summary => {},
        else => {},
    }
    _ = id;
}

fn openRowMenu(app: *App, tp: *TablePane, x: u16, y: u16) Allocator.Error!void {
    const e = tp.selectedEntry() orelse return;
    switch (e) {
        .group => |g| {
            const folded = tp.isCollapsed(tp.groups.items[g].key);
            const items = try app.gpa.dupe(command.MenuItem, &.{
                .{ .label = if (folded) "Expand" else "Collapse", .action = .{ .command = .@"sessions.toggle_group" } },
                .{ .label = "New local session", .action = .{ .command = .@"ai.claude_code_new" }, .separator_before = true },
                .{ .label = "New session in a worktree…", .action = .{ .command = .@"ai.new_session_worktree" } },
            });
            errdefer app.gpa.free(items);
            try app.openMenu(tp.groups.items[g].label, items, x, y);
        },
        .item => try sessions.openRowMenuFor(app, .table, x, y),
    }
}

fn openSortMenu(app: *App, tp: *TablePane, x: u16, y: u16) Allocator.Error!void {
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    inline for (@typeInfo(Sort).@"enum".fields) |f| {
        const s: Sort = @enumFromInt(f.value);
        try items.append(app.gpa, .{ .label = s.label(), .action = .{ .command = .@"sessions.table_sort" }, .checked = tp.sort == s });
    }
    const owned = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu("Sort by", owned, x, y);
}

pub fn scrollBy(tp: *TablePane, delta: i64) void {
    const cur: i64 = @intCast(tp.list.cursor);
    const last: i64 = @intCast(tp.visible.items.len -| 1);
    tp.list.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

pub fn scrollbarMouse(tp: *TablePane, bar: Rect, m: Mouse) void {
    const total = tp.visible.items.len;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            const off: usize = m.y -| bar.y;
            tp.list.cursor = @min(off * total / bar.h, total - 1);
        },
        .scroll_up => tp.list.cursor -|= 3,
        .scroll_down => tp.list.cursor = @min(tp.list.cursor + 3, total - 1),
        else => {},
    }
}

// ─── draw glue (D6) ─────────────────────────────────────────────────────

/// The rows in display order on the frame arena, then the painter.
pub fn drawPane(app: *App, ui: Ui, id: PaneId, tp: *TablePane, rect: Rect) Allocator.Error!void {
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    if (!tp.built) try refilter(app, tp);
    const st = &app.sessions;
    if (!st.scanned_once and !st.scanning) sessions.refresh(app) catch {};
    const rows = try ui.arena.alloc(Row, tp.visible.items.len);
    for (tp.visible.items, 0..) |e, i| rows[i] = switch (e) {
        .group => |g| .{ .group = .{
            .key = tp.groups.items[g].key,
            .label = tp.groups.items[g].label,
            .where = tp.groups.items[g].where,
            .count = tp.groups.items[g].count,
            .hidden = tp.groups.items[g].hidden,
            .collapsed = tp.isCollapsed(tp.groups.items[g].key),
        } },
        .item => |ii| .{ .item = try itemView(app, st.items[ii]) },
    };
    const now_s = sessions.wallNowS(app);
    const focused_pane = paneFocused(app, id);
    const caret = view.draw(ui, id, rect, tp, .{
        .rows = rows,
        .focused = focused_pane,
        .now_s = now_s,
        .agg = aggregate(app, tp, now_s),
        .selected = if (tp.selectedItem(app)) |it| try itemView(app, it) else null,
        .total = st.items.len,
        .scanning = st.scanning,
        .cloud_configured = cloud_agents.configured(&app.cfg.cloud_agents, &app.env) or hasCloud(app),
        .home_missing = st.home == null and sessions.envHome(app) == null,
        .now_ms = app.now_ms,
        .claude_mark = @import("claude_mark.zig").mark(app),
    });
    if (focused_pane) if (caret) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

fn hasCloud(app: *App) bool {
    for (app.sessions.items) |it| if (it.where == .cloud) return true;
    return false;
}

fn itemView(app: *App, it: Item) Allocator.Error!ItemView {
    const tp_multi = if (find(app)) |id| get(app, id) else null;
    return .{
        .it = it,
        .name = sessions.itemName(app, it),
        .ticked = if (tp_multi) |tp| tp.multi.contains(it.session_id) else false,
        .active = if (sessions.ptyPaneOf(app, it.session_id)) |pid| app.active == pid else false,
        .pinned = app.sessions.isPinned(it.session_id),
        .color = sessions.colorNameOf(app, it.session_id),
        .worktree = if (sessions.worktreeOf(app, it)) |e| e.name else null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn seed(app: *App, items: []const Item) !void {
    const r = try sessions.ScanResult.create(t.allocator, app.sessions.generation);
    const a = r.arena.allocator();
    const rows = try a.alloc(Item, items.len);
    for (items, 0..) |it, i| rows[i] = try sessions.dupeItem(a, it);
    r.items = rows;
    r.at_s = @divFloor(app.now_ms, 1000); // the tests' rows sit on the awake clock
    try sessions.handle(app, r);
    app.sessions.scanned_once = true; // no rescan of the real home over these
}

fn row(id: []const u8, state: AgentState, at: i64, ws: []const u8, cwd: ?[]const u8, msg: ?[]const u8) Item {
    var it = sessions.testItem(id, state, at, ws, msg);
    it.cwd = cwd;
    return it;
}

test "a focus-session selector matches the host's id, else the cwd and the prompt line together" {
    const it = sessions.testItem("s1", .streaming, 100, "ws", "/agents:developer ENG-2 — please");
    var with_cwd = it;
    with_cwd.cwd = "/w/acme";
    // The id alone decides when there is one.
    try std.testing.expect((Selector{ .id = "s1" }).matches(with_cwd));
    try std.testing.expect(!(Selector{ .id = "s2" }).matches(with_cwd));
    // Without one: the cwd must match, and the prompt line must be in
    // the session's first user message.
    try std.testing.expect((Selector{ .cwd = "/w/acme" }).matches(with_cwd));
    try std.testing.expect(!(Selector{ .cwd = "/w/other" }).matches(with_cwd));
    try std.testing.expect((Selector{ .cwd = "/w/acme", .prompt_line = "/agents:developer ENG-2" }).matches(with_cwd));
    try std.testing.expect(!(Selector{ .cwd = "/w/acme", .prompt_line = "/agents:developer ENG-9" }).matches(with_cwd));
    // Nothing to go on matches nothing, rather than the first row.
    try std.testing.expect(!(Selector{}).matches(with_cwd));
    // A session with no cwd cannot be matched by one.
    try std.testing.expect(!(Selector{ .cwd = "/w/acme" }).matches(it));
}

test "the table groups by cwd with the workspace first, sorts by state within, hides ended past a day until the chip, follows the session under the cursor" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/w/mnml", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    app.now_ms = 1_000_000 * 1000;
    const now: i64 = 1_000_000;
    try command.run(&app, .{ .static = .@"sessions.table" });
    const id = find(&app).?;
    const tp = get(&app, id).?;
    try t.expect(app.focus == .pane and app.active.? == id);
    try seed(&app, &.{
        row("old-done", .done, now - 2 * 86400, "mnml", "/w/mnml", "an old one"),
        row("other-live", .streaming, now - 10, "other", "/w/other", "ship"),
        row("ws-idle", .idle, now - 100, "mnml", "/w/mnml", "fix"),
        row("ws-wait", .waiting, now - 400, "mnml", "/w/mnml", "approve?"),
        row("fresh-done", .done, now - 60, "other", "/w/other", "notes"),
    });
    // Two groups; the workspace's first; the old ended row hidden.
    try t.expectEqual(@as(usize, 2), tp.groups.items.len);
    try t.expectEqual(@as(usize, 6), tp.visible.items.len);
    try t.expect(tp.visible.items[0] == .group);
    try t.expectEqualStrings("mnml", tp.groups.items[tp.visible.items[0].group].label);
    try t.expectEqual(@as(usize, 1), tp.groups.items[tp.visible.items[0].group].hidden);
    try t.expectEqualStrings("ws-wait", app.sessions.items[tp.visible.items[1].item].session_id);
    try t.expectEqualStrings("ws-idle", app.sessions.items[tp.visible.items[2].item].session_id);
    try t.expect(tp.visible.items[3] == .group);
    try t.expectEqualStrings("other-live", app.sessions.items[tp.visible.items[4].item].session_id);
    try t.expectEqualStrings("fresh-done", app.sessions.items[tp.visible.items[5].item].session_id);
    const agg = aggregate(&app, tp, now);
    try t.expectEqual(@as(usize, 1), agg.waiting);
    try t.expectEqual(@as(usize, 2), agg.done);
    try t.expectEqual(@as(usize, 1), agg.hidden);
    // E shows the old one, under its group, last.
    try app.handle(.{ .key = Key.char('E') });
    try t.expect(tp.show_ended);
    try t.expectEqual(@as(usize, 7), tp.visible.items.len);
    try t.expectEqualStrings("old-done", app.sessions.items[tp.visible.items[3].item].session_id);
    try app.handle(.{ .key = Key.char('E') });
    try t.expectEqual(@as(usize, 6), tp.visible.items.len);
    // The cursor on ws-idle stays on it across a reorder.
    tp.list.cursor = 2;
    try t.expectEqualStrings("ws-idle", tp.selectedItem(&app).?.session_id);
    try seed(&app, &.{
        row("ws-idle", .waiting, now - 5, "mnml", "/w/mnml", "fix"),
        row("ws-wait", .idle, now - 400, "mnml", "/w/mnml", "approve?"),
    });
    try t.expectEqualStrings("ws-idle", tp.selectedItem(&app).?.session_id);
    try t.expectEqual(@as(usize, 1), tp.list.cursor);
    // Space ticks, U clears; z folds the group to its row.
    try app.handle(.{ .key = Key.char(' ') });
    try t.expectEqual(@as(usize, 1), tp.multi.count());
    try app.handle(.{ .key = Key.char('U') });
    try t.expectEqual(@as(usize, 0), tp.multi.count());
    try app.handle(.{ .key = Key.char('z') });
    try t.expectEqual(@as(usize, 1), tp.visible.items.len);
    try t.expectEqual(@as(usize, 0), tp.list.cursor);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(@as(usize, 3), tp.visible.items.len);
    // The state filter and the where filter narrow; Ctrl+L clears both.
    try app.handle(.{ .key = Key.char('f') });
    try t.expectEqual(@as(?AgentState, .waiting), tp.state_filter);
    try t.expectEqual(@as(usize, 2), tp.visible.items.len);
    try app.handle(.{ .key = Key.char('w') });
    try app.handle(.{ .key = Key.char('w') });
    try t.expectEqual(@as(?Where, .cloud), tp.where_filter);
    try t.expectEqual(@as(usize, 0), tp.visible.items.len);
    try app.handle(.{ .key = Key.ctrl('l') });
    try t.expect(tp.state_filter == null and tp.where_filter == null);
    try t.expectEqual(@as(usize, 3), tp.visible.items.len);
    // Help swaps the body; ? again puts it back. q closes the pane.
    try app.handle(.{ .key = Key.char('?') });
    try app.render();
    const help = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(help);
    try t.expect(std.mem.indexOf(u8, help, view.help_title) != null);
    try app.handle(.{ .key = Key.char('?') });
    try t.expect(!tp.help);
    try app.handle(.{ .key = Key.char('q') });
    try t.expect(find(&app) == null);
}

test "the table's hits: rows, the kebab, the header chips and the filter route as the pane's script hits; the summary block holds the last message, the rows do not" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/w/mnml", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    app.now_ms = 1_000_000 * 1000;
    const now: i64 = 1_000_000;
    try command.run(&app, .{ .static = .@"ai.dashboard" });
    const id = find(&app).?;
    const tp = get(&app, id).?;
    var live = row("live-1", .streaming, now - 10, "mnml", "/w/mnml", "fix the failing tests in src/main.zig please");
    live.last_assistant_msg = "Running the suite first to see which ones fail.";
    live.tokens = 12_500;
    live.cost_usd = 0.42;
    live.dirty = 3;
    live.pid = 4242;
    try seed(&app, &.{ live, row("done-1", .done, now - 100, "mnml", "/w/mnml", "notes") });
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "SESSIONS") != null);
    try t.expect(std.mem.indexOf(u8, txt, "ended: hidden") != null);
    try t.expect(std.mem.indexOf(u8, txt, "? help") != null);
    try t.expect(std.mem.indexOf(u8, txt, "12.5k") != null);
    // The summary holds the exchange; the row shows the name only.
    try t.expect(std.mem.indexOf(u8, txt, "claude: Running the suite") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, txt, "Running the suite"));
    var row1: ?Rect = null;
    var ended_chip: ?Rect = null;
    var filter: ?Rect = null;
    var new_chip: ?Rect = null;
    for (app.hits.items.items) |h| switch (h.target) {
        .script_hit => |sh| if (sh.pane == id) {
            if (sh.id == hit.ListHit.row(1)) row1 = h.rect;
            if (sh.id == hit_ended) ended_chip = h.rect;
            if (sh.id == hit.ListHit.filter_id) filter = h.rect;
            if (sh.id == hit.ListHit.chip(.new)) new_chip = h.rect;
        },
        else => {},
    };
    try t.expect(row1 != null and ended_chip != null and filter != null and new_chip != null);
    // A right click on the live row: the session menu with Kill.
    try app.handle(.{ .mouse = .{ .x = row1.?.x + 2, .y = row1.?.y, .kind = .press, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(@as(usize, 1), tp.list.cursor);
    var kill_seen = false;
    for (app.overlay.menu.items) |mi| if (std.mem.eql(u8, mi.label, "Kill session…")) {
        kill_seen = true;
    };
    try t.expect(kill_seen);
    try app.handle(.{ .key = Key.named(.esc) });
    // The ended chip toggles; the New row opens the choice menu.
    try app.handle(.{ .mouse = .{ .x = ended_chip.?.x + 1, .y = ended_chip.?.y, .kind = .press, .button = .left } });
    try t.expect(tp.show_ended);
    try app.handle(.{ .mouse = .{ .x = new_chip.?.x + 1, .y = new_chip.?.y, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("New local session", app.overlay.menu.items[0].label);
    try app.handle(.{ .key = Key.named(.esc) });
    // The filter pill takes the keys; typing narrows.
    try app.handle(.{ .mouse = .{ .x = filter.?.x + 3, .y = filter.?.y, .kind = .press, .button = .left } });
    try t.expect(tp.list.filter_focused);
    for ("notes") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqual(@as(usize, 2), tp.visible.items.len); // the group and done-1
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!tp.list.filter_focused);
    // K on the live row asks; the confirm carries its pid.
    tp.list.cursor = 1;
    try app.handle(.{ .key = Key.char('K') });
    try t.expect(app.overlay == .confirm);
    try t.expectEqualSlices(u32, &.{4242}, app.overlay.confirm.purpose.kill_pids);
}
