//! The sessions mode — the Sessions row of the activity bar puts the
//! editor layout aside and shows only the Claude Code / Codex sessions,
//! in `ai.session_columns` columns side by side (1..4; 1 is one session
//! maximised). Every open session goes into a column, round-robin in
//! the rail's order, so the first N on the rail are the ones on show
//! and the rest are stacked behind them as tabs. Leaving the mode — the
//! rail again, or any other section — puts the layout back exactly:
//! git mode's shape (`git_palette.enter` / `leave`), with the layout
//! held in `State.pre` while the mode owns the page.
//!
//! A session on another tab page is lifted off it for the mode (the
//! page's tree is kept whole in `State.others` and comes back on
//! leave); a docked session stays in the dock, which is still on
//! screen; one in no tree joins the columns and goes back to none.
//!
//! Inside the mode the chords are the sessions' (`interceptKey`):
//! `Ctrl+Tab` / `Ctrl+Shift+Tab` swap the focused column's visible
//! session for the next / previous one stacked behind it, `Ctrl+1` …
//! `Ctrl+9` show session N of the rail in the focused column, and
//! `Ctrl+N` starts a new Claude Code session as the focused column's
//! visible one. Everywhere else those chords keep their meaning.
//!
//! The shape holds (`reconcile`, run after every command and event): a
//! session started in the mode by any other way joins the emptiest
//! column; a column whose last session closes is refilled — the
//! survivors shift left and the next session stacked behind one of
//! them takes the last column — never by a session started for it.
//! A zoomed session closing hands the zoom to the next session, in the
//! mode or out of it (`zoomSuccessor` / `takeZoom`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const keymap = @import("../core/keymap.zig");
const Chord = @import("../core/key.zig").Chord;
const session_cycle = @import("session_cycle.zig");
const side = @import("side.zig");
const settings = @import("settings.zig");
const Config = @import("../config/Config.zig");

pub const table = .{
    .@"sessions.mode" = &toggleCmd,
    .@"sessions.mode_new" = &newCmd,
    .@"sessions.column_next" = &columnNextCmd,
    .@"sessions.column_prev" = &columnPrevCmd,
    .@"sessions.show_1" = showRunner(1),
    .@"sessions.show_2" = showRunner(2),
    .@"sessions.show_3" = showRunner(3),
    .@"sessions.show_4" = showRunner(4),
    .@"sessions.show_5" = showRunner(5),
    .@"sessions.show_6" = showRunner(6),
    .@"sessions.show_7" = showRunner(7),
    .@"sessions.show_8" = showRunner(8),
    .@"sessions.show_9" = showRunner(9),
    .@"sessions.columns_1" = columnsRunner(1),
    .@"sessions.columns_2" = columnsRunner(2),
    .@"sessions.columns_3" = columnsRunner(3),
    .@"sessions.columns_4" = columnsRunner(4),
};

/// The toast a step replaces, so a run of steps shows one line.
const step_toast = "sessions-mode";

const Other = struct { page: usize, layout: Layout };

pub const State = struct {
    active: bool = false,
    /// The tab page the mode owns.
    page: usize = 0,
    /// That page's layout as it was, and the pane that had the keys.
    pre: ?Layout = null,
    pre_active: ?PaneId = null,
    /// The other pages that held a session, whole, as they were.
    others: std.ArrayListUnmanaged(Other) = .empty,
    /// What the sessions' column showed before the mode, if anything.
    pre_column: ?side.Section = null,
    /// The sessions the mode has placed — a session not in here is one
    /// started since, which `reconcile` puts in a column.
    known: std.ArrayListUnmanaged(PaneId) = .empty,
    /// The sessions the mode took at enter: each goes back where it was
    /// (a tree put aside, or none); the rest of `known` started since.
    entered: std.ArrayListUnmanaged(PaneId) = .empty,
    /// The columns as the last `reconcile` left them: each column's
    /// tabs. What tells a closed column from a moved one.
    snapshot: std.ArrayListUnmanaged(std.ArrayListUnmanaged(PaneId)) = .empty,
    /// The pane that had the keys at the snapshot.
    snap_active: ?PaneId = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.pre) |*p| p.deinit();
        for (self.others.items) |*o| o.layout.deinit();
        self.others.deinit(gpa);
        self.known.deinit(gpa);
        self.entered.deinit(gpa);
        clearSnapshot(self, gpa);
        self.snapshot.deinit(gpa);
        self.* = .{};
    }
};

fn clearSnapshot(st: *State, gpa: Allocator) void {
    for (st.snapshot.items) |*c| c.deinit(gpa);
    st.snapshot.clearRetainingCapacity();
}

/// Whether the mode is showing: on, and its page on screen.
pub fn showing(app: *const App) bool {
    return app.sessions_mode.active and app.layouts.active == app.sessions_mode.page;
}

// ─── the order ──────────────────────────────────────────────────────────

/// The sessions the mode takes, in the rail's order: SESSIONS' cards as
/// sorted and filtered, then any session the rail does not list (an
/// ended one behind the history chip, one the filter hides) in ring
/// order. A docked session stays in the dock. On `arena`.
pub fn railOrder(app: *App, arena: Allocator) Allocator.Error![]PaneId {
    const sessions = @import("../sessions.zig");
    const bottom = @import("bottom.zig");
    try sessions.refilter(app);
    var out: std.ArrayListUnmanaged(PaneId) = .empty;
    const st = &app.sessions;
    for (st.filtered.items) |idx| {
        const id = st.cards.items[idx].pane;
        if (!session_cycle.isSession(app, id) or bottom.hosts(app, id)) continue;
        try out.append(arena, id);
    }
    for (try session_cycle.list(app, arena)) |id| {
        if (bottom.hosts(app, id)) continue;
        if (std.mem.indexOfScalar(PaneId, out.items, id) == null) try out.append(arena, id);
    }
    return out.items;
}

/// `order` dealt round-robin into `n` columns (fewer when there are
/// fewer sessions): column `i` leads with `order[i]`.
pub fn deal(arena: Allocator, order: []const PaneId, n: usize) Allocator.Error![][]PaneId {
    const k = @min(n, order.len);
    const cols = try arena.alloc(std.ArrayListUnmanaged(PaneId), k);
    for (cols) |*c| c.* = .empty;
    for (order, 0..) |id, j| try cols[j % k].append(arena, id);
    const out = try arena.alloc([]PaneId, k);
    for (cols, 0..) |c, i| out[i] = c.items;
    return out;
}

// ─── entering and leaving ───────────────────────────────────────────────

/// `sessions.mode`: in, or — already in — out.
fn toggleCmd(app: *App) CommandError!void {
    if (app.sessions_mode.active) {
        leave(app, true);
        return;
    }
    try enter(app);
}

pub fn enter(app: *App) CommandError!void {
    const st = &app.sessions_mode;
    if (st.active) {
        if (!showing(app)) @import("cmd_tab.zig").switchTab(app, st.page);
        return;
    }
    // Every other section's mode goes first: git mode's layout is its
    // own, and this one puts aside what is under it.
    @import("activity_bar.zig").enter(app, .sessions);
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const order = try arena.dupe(PaneId, try railOrder(app, arena));
    const ls = &app.layouts;
    st.page = ls.active;
    // The other pages that hold a session: kept whole, then lifted.
    errdefer {
        for (st.others.items) |*o| o.layout.deinit();
        st.others.clearRetainingCapacity();
    }
    for (ls.layouts.items, 0..) |*l, page| {
        if (page == st.page) continue;
        var holds = false;
        for (order) |id| if (l.leafOf(id) != null) {
            holds = true;
        };
        if (!holds) continue;
        var copy = try l.clone();
        errdefer copy.deinit();
        try st.others.append(gpa, .{ .page = page, .layout = copy });
    }
    for (st.others.items) |o| {
        const l = &ls.layouts.items[o.page];
        for (order) |id| while (l.leafOf(id) != null) {
            _ = l.removePane(id);
        };
    }
    try st.known.appendSlice(gpa, order);
    try st.entered.appendSlice(gpa, order);
    const sec_side = side.sideOf(app, .sessions);
    st.pre_column = if (sec_side == .bottom) null else side.shown(app, sec_side);
    const cur = ls.current();
    st.pre = cur.*;
    st.pre_active = app.active;
    cur.* = Layout.init(gpa);
    app.active = null;
    st.active = true;
    try build(app, try deal(arena, order, app.cfg.ai.session_columns));
    side.place(app, .sessions, false);
    // The session that had the keys keeps them, in its column.
    const keep: ?PaneId = if (st.pre_active) |a| (if (std.mem.indexOfScalar(PaneId, order, a) != null) a else null) else null;
    if (keep orelse cur.landing()) |id| {
        if (cur.leafOf(id)) |lid| cur.leaf(lid).?.active = id;
        app.setActive(id);
    } else app.setActive(null);
    try snap(app);
    if (order.len == 0) app.toast("sessions: none open — Ctrl+N starts one", .{});
    app.needs_render = true;
}

/// Lay the current page out as `cols`: side by side, equal shares, each
/// column's first session the one on show.
fn build(app: *App, cols: []const []const PaneId) Allocator.Error!void {
    const layout = app.layouts.current();
    var gone = layout.*;
    layout.* = Layout.init(app.gpa);
    gone.deinit();
    var prev: ?PaneId = null;
    for (cols) |col| {
        if (col.len == 0) continue;
        const lid: layout_mod.NodeId = if (prev) |p| (try layout.split(p, .horizontal, col[0])).? else try layout.showIn(null, col[0]);
        for (col[1..]) |id| _ = try layout.showIn(lid, id);
        layout.leaf(lid).?.active = col[0];
        prev = col[0];
    }
    layout.equalize();
}

/// Leave the mode: the layout put aside comes back, the other pages
/// get their sessions back where they were. `restore_column` puts the
/// sessions' column back to what it showed (the rail's own toggle);
/// a section taking the column over passes false. A no-op outside.
pub fn leave(app: *App, restore_column: bool) void {
    const st = &app.sessions_mode;
    if (!st.active) return;
    st.active = false;
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const ls = &app.layouts;
    // Sessions started in the mode, which the layout put aside never
    // held: kept as background tabs of the restored page, not lost.
    var fresh: std.ArrayListUnmanaged(PaneId) = .empty;
    for (st.known.items) |id| {
        if (app.panes.get(id) == null) continue;
        if (std.mem.indexOfScalar(PaneId, st.entered.items, id) != null) continue;
        fresh.append(arena, id) catch {};
    }
    if (st.page < ls.layouts.items.len) {
        const page = &ls.layouts.items[st.page];
        var mode_layout = page.*;
        page.* = st.pre orelse Layout.init(gpa);
        st.pre = null;
        // Anything opened in the mode that is not a session (a file
        // dropped into a column) stays open, as a background tab.
        for (mode_layout.allPanes(arena) catch &.{}) |id| {
            if (page.leafOf(id) != null or session_cycle.isSession(app, id)) continue;
            if (page.firstLeaf()) |l| _ = page.showIn(l, id) catch {};
        }
        mode_layout.deinit();
        for (fresh.items) |id| if (page.leafOf(id) == null) {
            const target: ?layout_mod.NodeId = if (st.pre_active) |a| page.leafOf(a) else null;
            const where = target orelse page.firstLeaf();
            if (where) |w| {
                const keep = page.leaf(w).?.active;
                _ = page.showIn(w, id) catch {};
                page.leaf(w).?.active = keep;
            } else _ = page.showIn(null, id) catch {};
        };
    } else if (st.pre) |*p| {
        p.deinit();
        st.pre = null;
    }
    for (st.others.items) |*o| {
        if (o.page >= ls.layouts.items.len or o.page == st.page) {
            o.layout.deinit();
            continue;
        }
        const live = &ls.layouts.items[o.page];
        var was = live.*;
        live.* = o.layout;
        // What the page gained in the mode stays on it.
        for (was.allPanes(arena) catch &.{}) |id| if (live.leafOf(id) == null) {
            if (live.firstLeaf()) |l| {
                const keep = live.leaf(l).?.active;
                _ = live.showIn(l, id) catch {};
                live.leaf(l).?.active = keep;
            } else _ = live.showIn(null, id) catch {};
        };
        was.deinit();
    }
    st.others.clearRetainingCapacity();
    dedupe(app);
    st.known.clearRetainingCapacity();
    st.entered.clearRetainingCapacity();
    clearSnapshot(st, gpa);
    const cur = ls.current();
    const now = cur.allPanes(arena) catch &.{};
    const keep: ?PaneId = if (st.pre_active) |a| (if (std.mem.indexOfScalar(PaneId, now, a) != null) a else null) else null;
    app.active = null;
    app.setActive(keep orelse cur.landing());
    st.pre_active = null;
    app.afterSplitChange();
    if (restore_column) {
        const sec_side = side.sideOf(app, .sessions);
        if (st.pre_column) |prev| {
            if (prev != .sessions) side.place(app, prev, false);
        } else if (sec_side != .bottom and side.shown(app, sec_side) == .sessions) side.hideColumn(app, sec_side);
    }
    st.pre_column = null;
    app.needs_render = true;
}

/// A pane on two pages (only an editor may be) or twice on one: the
/// later copy goes. Restoring trees kept whole can meet a pane that
/// moved while the mode held them.
fn dedupe(app: *App) void {
    const ls = &app.layouts;
    const arena = app.frame.allocator();
    for (ls.layouts.items, 0..) |*l, page| {
        for (l.allPanes(arena) catch &.{}) |id| {
            if (app.sharedAcrossPages(id)) continue;
            const first = ls.pageOf(id) orelse continue;
            if (first != page) while (l.leafOf(id) != null) {
                _ = l.removePane(id);
            };
        }
    }
    while (ls.violation()) |v| _ = ls.layouts.items[v.page].removePane(v.pane);
}

/// A pane closing while the mode holds leaves every tree put aside, so
/// leaving brings back only panes that exist.
pub fn forgetPane(app: *App, id: PaneId) void {
    const st = &app.sessions_mode;
    if (!st.active) return;
    if (st.pre) |*p| while (p.leafOf(id) != null) {
        _ = p.removePane(id);
    };
    for (st.others.items) |*o| while (o.layout.leafOf(id) != null) {
        _ = o.layout.removePane(id);
    };
    if (st.pre_active == id) st.pre_active = null;
}

// ─── keeping the shape ──────────────────────────────────────────────────

/// After every command and event, while the mode's page is on screen: a
/// session the mode has not placed joins the emptiest column (and has
/// the keys); a column whose sessions all closed is refilled from the
/// sessions stacked behind the others. The columns are then snapshot.
pub fn reconcile(app: *App) Allocator.Error!void {
    if (!showing(app)) return;
    const st = &app.sessions_mode;
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const layout = app.layouts.current();
    // Closed panes leave `known`.
    var i: usize = 0;
    while (i < st.known.items.len) {
        if (app.panes.get(st.known.items[i]) == null) _ = st.known.orderedRemove(i) else i += 1;
    }
    // Sessions started since: into the emptiest column.
    const bottom = @import("bottom.zig");
    for (try session_cycle.list(app, arena)) |id| {
        if (bottom.hosts(app, id)) continue;
        if (std.mem.indexOfScalar(PaneId, st.known.items, id) != null) continue;
        try st.known.append(gpa, id);
        for (app.layouts.layouts.items) |*l| while (l.leafOf(id) != null) {
            _ = l.removePane(id);
        };
        const zoom = layout.zoomed;
        if (emptiest(layout, arena)) |lid| _ = try layout.showIn(lid, id) else _ = try layout.showIn(null, id);
        layout.zoomed = zoom;
        app.ai.placeholder = false;
        app.setActive(id);
    }
    // A column gone because its sessions closed: refill it.
    const leaves = try layout.leaves(arena);
    if (leaves.len < st.snapshot.items.len and leaves.len > 0) {
        const vacated: ?usize = for (st.snapshot.items, 0..) |col, k| {
            var dead = true;
            for (col.items) |id| if (app.panes.get(id) != null) {
                dead = false;
            };
            if (dead) break k;
        } else null;
        if (vacated) |k| if (nextHidden(layout, leaves, @min(k, leaves.len - 1))) |h| {
            const zoom = layout.zoomed;
            const from = layout.leafOf(h).?;
            const lf = layout.leaf(from).?;
            const at = std.mem.indexOfScalar(PaneId, lf.tabs.items, h).?;
            _ = lf.tabs.orderedRemove(at);
            const last = leaves[leaves.len - 1];
            _ = try layout.split(layout.leaf(last).?.active, .horizontal, h);
            layout.equalize();
            if (zoom) |z| if (layout.leafOf(z) != null) {
                layout.zoomed = z;
            };
            // The keys were in the column that closed: they stay in
            // that place, with the session that fills it.
            const had_keys = if (st.snap_active) |a| std.mem.indexOfScalar(PaneId, st.snapshot.items[k].items, a) != null else false;
            if (had_keys or app.active == null or layout.leafOf(app.active.?) == null) app.setActive(h);
        };
    }
    try snap(app);
}

/// The leaf with the fewest tabs, the leftmost of a tie.
fn emptiest(layout: *Layout, arena: Allocator) ?layout_mod.NodeId {
    var best: ?layout_mod.NodeId = null;
    var best_n: usize = std.math.maxInt(usize);
    for (layout.leaves(arena) catch return null) |lid| {
        const n = layout.leaf(lid).?.tabs.items.len;
        if (n < best_n) {
            best = lid;
            best_n = n;
        }
    }
    return best;
}

/// The next session stacked behind a column's visible one, looking from
/// column `from` rightwards and round: the first column with more than
/// one tab gives its first hidden one.
fn nextHidden(layout: *Layout, leaves: []const layout_mod.NodeId, from: usize) ?PaneId {
    for (0..leaves.len) |step| {
        const lf = layout.leaf(leaves[(from + step) % leaves.len]) orelse continue;
        if (lf.tabs.items.len < 2) continue;
        for (lf.tabs.items) |id| if (id != lf.active) return id;
    }
    return null;
}

fn snap(app: *App) Allocator.Error!void {
    const st = &app.sessions_mode;
    clearSnapshot(st, app.gpa);
    st.snap_active = app.active;
    const layout = app.layouts.current();
    for (try layout.leaves(app.frame.allocator())) |lid| {
        var col: std.ArrayListUnmanaged(PaneId) = .empty;
        errdefer col.deinit(app.gpa);
        try col.appendSlice(app.gpa, layout.leaf(lid).?.tabs.items);
        try st.snapshot.append(app.gpa, col);
    }
}

// ─── the zoom on a close ────────────────────────────────────────────────

/// Before `id` closes: the session that takes the zoom from it, when
/// `id` is the zoomed session of the page on screen — the next session
/// in the ring after it (a docked one excepted). Null otherwise.
pub fn zoomSuccessor(app: *App, id: PaneId) ?PaneId {
    const layout = app.layouts.current();
    if (layout.zoomed != id or !session_cycle.isSession(app, id)) return null;
    const bottom = @import("bottom.zig");
    const ring = session_cycle.list(app, app.frame.allocator()) catch return null;
    const at = std.mem.indexOfScalar(PaneId, ring, id) orelse return null;
    for (1..ring.len) |k| {
        const cand = ring[(at + k) % ring.len];
        if (cand != id and !bottom.hosts(app, cand)) return cand;
    }
    return null;
}

/// After the close: `next` takes the zoom — shown where it is on this
/// page, else brought into the leaf that now has the keys.
pub fn takeZoom(app: *App, next: PaneId) void {
    if (app.panes.get(next) == null) return;
    const layout = app.layouts.current();
    if (layout.leafOf(next) == null) {
        for (app.layouts.layouts.items) |*l| while (l.leafOf(next) != null) {
            _ = l.removePane(next);
        };
        const where: ?layout_mod.NodeId = if (app.active) |a| layout.leafOf(a) else layout.firstLeaf();
        _ = layout.showIn(where, next) catch return;
    }
    layout.leaf(layout.leafOf(next).?).?.active = next;
    layout.zoomed = next;
    app.setActive(next);
}

// ─── the chords ─────────────────────────────────────────────────────────

const Intercept = struct { chord: []const Chord, id: command.CommandId };

const intercept_specs = [_][]const u8{ "ctrl+tab", "ctrl+shift+tab", "ctrl+n", "ctrl+1", "ctrl+2", "ctrl+3", "ctrl+4", "ctrl+5", "ctrl+6", "ctrl+7", "ctrl+8", "ctrl+9" };

const intercepts = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [_]Intercept{
        .{ .chord = keymap.parseKeySeqComptime("ctrl+tab").?, .id = .@"sessions.column_next" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+shift+tab").?, .id = .@"sessions.column_prev" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+n").?, .id = .@"sessions.mode_new" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+1").?, .id = .@"sessions.show_1" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+2").?, .id = .@"sessions.show_2" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+3").?, .id = .@"sessions.show_3" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+4").?, .id = .@"sessions.show_4" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+5").?, .id = .@"sessions.show_5" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+6").?, .id = .@"sessions.show_6" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+7").?, .id = .@"sessions.show_7" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+8").?, .id = .@"sessions.show_8" },
        .{ .chord = keymap.parseKeySeqComptime("ctrl+9").?, .id = .@"sessions.show_9" },
    };
};

/// The command a chord means in the mode, or null — outside it, or a
/// chord the mode leaves alone.
pub fn chordCommand(app: *const App, k: Key) ?command.CommandId {
    if (!showing(app)) return null;
    const c = Chord.of(k);
    for (intercepts) |ic| if (ic.chord[0].eql(c)) return ic.id;
    return null;
}

/// The chord a sessions-mode verb answers to while the mode shows —
/// what a menu row or the hover copy prints for it — or null.
pub fn contextualSpec(app: *const App, id: command.CommandId) ?[]const u8 {
    if (!showing(app)) return null;
    for (intercepts, 0..) |ic, i| if (ic.id == id) return intercept_specs[i];
    return null;
}

/// Whether the mode has taken `spec` from whatever it is bound to — a
/// menu row must not print `Ctrl+N` beside *New file* while Ctrl+N
/// starts a session.
pub fn takesSpec(app: *const App, spec: []const u8) bool {
    if (!showing(app)) return false;
    var buf: [keymap.max_seq]Chord = undefined;
    const seq = keymap.parseKeySeqBuf(spec, &buf) orelse return false;
    if (seq.len != 1) return false;
    for (intercepts) |ic| if (ic.chord[0].eql(seq[0])) return true;
    return false;
}

/// `dispatch.keyInner`'s hook, ahead of every pane and panel: in the
/// mode the session chords run their session commands. True when taken.
pub fn interceptKey(app: *App, k: Key) Allocator.Error!bool {
    const id = chordCommand(app, k) orelse return false;
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    return true;
}

// ─── the column verbs ───────────────────────────────────────────────────

/// The column with the keys: the leaf of the active pane on the mode's
/// page, else its first.
fn focusedLeaf(app: *App) ?layout_mod.NodeId {
    const layout = app.layouts.current();
    if (app.active) |a| if (layout.leafOf(a)) |lid| return lid;
    return layout.firstLeaf();
}

fn requireMode(app: *App) CommandError!void {
    if (!showing(app)) return app.diag.fail(app.frame.allocator(), "sessions: not in the sessions mode — the Sessions row of the activity bar enters it", .{});
}

/// `sessions.column_next` / `_prev`: the focused column's visible
/// session gives way to the next / previous one stacked behind it,
/// wrapping. The keys stay in the column.
pub fn stepColumn(app: *App, forward: bool) CommandError!void {
    try requireMode(app);
    const layout = app.layouts.current();
    const lid = focusedLeaf(app) orelse return;
    const lf = layout.leaf(lid).?;
    const n = lf.tabs.items.len;
    const at = std.mem.indexOfScalar(PaneId, lf.tabs.items, lf.active) orelse 0;
    const to = lf.tabs.items[if (forward) (at + 1) % n else (at + n - 1) % n];
    lf.active = to;
    app.setActive(to);
    announce(app, to);
}

fn columnNextCmd(app: *App) CommandError!void {
    return stepColumn(app, true);
}

fn columnPrevCmd(app: *App) CommandError!void {
    return stepColumn(app, false);
}

fn announce(app: *App, id: PaneId) void {
    const pos = (stackPosition(app, id) catch null) orelse return;
    const sessions = @import("../sessions.zig");
    if (sessions.paneName(app, id)) |name| {
        app.toastReplace(step_toast, "session {d}/{d} in this column · {s}", .{ pos.index + 1, pos.count, name.text });
    } else app.toastReplace(step_toast, "session {d}/{d} in this column", .{ pos.index + 1, pos.count });
}

/// `id`'s place in its column's stack while the mode shows — what its
/// strip's ` ‹ n/m › ` reads there. Null outside the mode.
pub fn stackPosition(app: *App, id: PaneId) Allocator.Error!?session_cycle.Position {
    if (!showing(app)) return null;
    const layout = app.layouts.current();
    const lid = layout.leafOf(id) orelse return null;
    var n: usize = 0;
    var at: ?usize = null;
    for (layout.leaf(lid).?.tabs.items) |tab| if (session_cycle.isSession(app, tab)) {
        if (tab == id) at = n;
        n += 1;
    };
    return .{ .index = at orelse return null, .count = n };
}

/// `sessions.show_N`: the rail's Nth session in the focused column. One
/// in another column trades places with the focused column's visible
/// session, so no column is emptied.
pub fn showNth(app: *App, n: usize) CommandError!void {
    try requireMode(app);
    const arena = app.frame.allocator();
    const order = try railOrder(app, arena);
    if (n == 0 or n > order.len) return app.diag.fail(arena, "sessions: there is no session {d} — {d} open", .{ n, order.len });
    try placeInFocused(app, order[n - 1]);
    announce(app, order[n - 1]);
}

/// `target` becomes the focused column's visible session and gets the
/// keys. One in another column trades places with the one on show
/// there, so no column empties; one elsewhere is brought in.
fn placeInFocused(app: *App, target: PaneId) Allocator.Error!void {
    const layout = app.layouts.current();
    const mine = focusedLeaf(app) orelse {
        _ = try layout.showIn(null, target);
        app.setActive(target);
        return;
    };
    const lf = layout.leaf(mine).?;
    if (layout.leafOf(target)) |theirs| {
        if (theirs != mine) {
            const other = layout.leaf(theirs).?;
            const cur = lf.active;
            const ia = std.mem.indexOfScalar(PaneId, lf.tabs.items, cur).?;
            const ib = std.mem.indexOfScalar(PaneId, other.tabs.items, target).?;
            lf.tabs.items[ia] = target;
            other.tabs.items[ib] = cur;
            if (other.active == target) other.active = cur;
        }
    } else {
        for (app.layouts.layouts.items) |*l| while (l.leafOf(target) != null) {
            _ = l.removePane(target);
        };
        _ = try layout.showIn(mine, target);
    }
    layout.leaf(layout.leafOf(target).?).?.active = target;
    app.setActive(target);
}

/// A single click on a SESSIONS card: on a page where a click could
/// not otherwise show it — the sessions mode, or a zoomed page — the
/// card's session is shown: in the focused column, or swapped into the
/// zoom. The keys stay on the rail (a double-click takes them). False
/// anywhere else, where every session is on show already.
pub fn previewCard(app: *App, id: PaneId) Allocator.Error!bool {
    const bottom = @import("bottom.zig");
    if (app.panes.get(id) == null or bottom.hosts(app, id)) return false;
    if (showing(app)) {
        try placeInFocused(app, id);
    } else {
        if (app.zoomedPane() == null) return false;
        try intoZoom(app, id);
    }
    @import("../sessions.zig").focusPanel(app);
    return true;
}

/// `id` takes the zoom of the page on screen: shown in the zoomed
/// pane's leaf (brought there from wherever it was) and zoomed, with
/// the keys. The caller knows a pane is zoomed.
fn intoZoom(app: *App, id: PaneId) Allocator.Error!void {
    const layout = app.layouts.current();
    const z = app.zoomedPane().?;
    if (layout.leafOf(id) == null) {
        const zl = layout.leafOf(z).?;
        for (app.layouts.layouts.items) |*l| while (l.leafOf(id) != null) {
            _ = l.removePane(id);
        };
        _ = try layout.showIn(zl, id);
    }
    layout.leaf(layout.leafOf(id).?).?.active = id;
    layout.zoomed = id;
    app.setActive(id);
}

/// The ready ring's step (`app/session_ready.zig`): `id` on show with
/// the keys, by the same rule a card's click uses — in the mode,
/// swapped into the focused column (`Ctrl+1..9`'s primitive), so the
/// mode stays; on a zoomed page, into the zoom; else wherever
/// `showPane` puts it. A docked session is shown in the dock.
pub fn showReady(app: *App, id: PaneId) Allocator.Error!void {
    const bottom = @import("bottom.zig");
    if (app.panes.get(id) == null) return;
    if (!bottom.hosts(app, id)) {
        if (showing(app)) return placeInFocused(app, id);
        if (app.zoomedPane()) |z| if (z != id) return intoZoom(app, id);
    }
    app.showPane(id);
}

fn showRunner(comptime n: usize) command.CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            return showNth(app, n);
        }
    }.run;
}

/// `sessions.mode_new` (`Ctrl+N` in the mode): a new Claude Code session
/// as the focused column's visible one, the one it covers stacked
/// behind; on a zoomed page it takes the zoom. Outside the mode, the
/// plain `ai.claude_code_new`.
fn newCmd(app: *App) CommandError!void {
    if (!showing(app)) return command.run(app, .{ .static = .@"ai.claude_code_new" });
    const layout = app.layouts.current();
    const zoom = layout.zoomed;
    if (layout.isEmpty()) {
        try command.run(app, .{ .static = .@"ai.claude_code_new" });
    } else {
        if (focusedLeaf(app)) |lid| if (app.active == null or layout.leafOf(app.active.?) != lid) app.setActive(layout.leaf(lid).?.active);
        try command.run(app, .{ .static = .@"ai.claude_code_new_tab" });
    }
    const id = app.active orelse return;
    if (!session_cycle.isSession(app, id)) return;
    if (std.mem.indexOfScalar(PaneId, app.sessions_mode.known.items, id) == null) try app.sessions_mode.known.append(app.gpa, id);
    if (zoom != null and layout.leafOf(id) != null) layout.zoomed = id;
    try snap(app);
}

/// `sessions.columns_N`: `ai.session_columns`, written home; in the mode
/// the sessions are dealt again into the new count.
fn columnsRunner(comptime n: u8) command.CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            return setColumns(app, n);
        }
    }.run;
}

pub fn setColumns(app: *App, n: u8) CommandError!void {
    const v = std.math.clamp(n, Config.session_columns_min, Config.session_columns_max);
    app.cfg.ai.session_columns = v;
    if ((try settings.configPath(app, .home)) != null) _ = try settings.persist(app, .home, &.{ "ai", "session_columns" }, v);
    if (showing(app)) {
        const arena = app.frame.allocator();
        const keep = app.active;
        try build(app, try deal(arena, try railOrder(app, arena), v));
        const layout = app.layouts.current();
        const to = if (keep) |k| (if (layout.leafOf(k) != null) k else layout.landing()) else layout.landing();
        app.active = null;
        if (to) |id| {
            layout.leaf(layout.leafOf(id).?).?.active = id;
            app.setActive(id);
        } else app.setActive(null);
        try snap(app);
    }
    app.toast("sessions: {d} side by side{s}", .{ v, if (v == 1) " — one maximised" else "" });
    app.needs_render = true;
}

/// The *Show side by side* submenu the AI chips' menus carry: one row a
/// count, the current one ticked.
pub fn columnsMenuRows(app: *const App, arena: Allocator) Allocator.Error![]const command.MenuItem {
    const ids = [_]command.CommandId{ .@"sessions.columns_1", .@"sessions.columns_2", .@"sessions.columns_3", .@"sessions.columns_4" };
    const labels = [_][]const u8{ "1 — one maximised", "2 side by side", "3 side by side", "4 side by side" };
    const rows = try arena.alloc(command.MenuItem, ids.len);
    for (ids, labels, 0..) |id, label, i| rows[i] = .{ .label = label, .action = .{ .command = id }, .checked = app.cfg.ai.session_columns == i + 1 };
    return rows;
}

/// Whether `id` is on screen right now: the shown tab of a leaf on the
/// page on screen (the zoomed one alone on a zoomed page), or the
/// dock's shown pane — what the rail's on-screen mark reads.
pub fn onScreen(app: *App, id: PaneId) bool {
    const bottom = @import("bottom.zig");
    if (bottom.hosts(app, id)) return bottom.activePane(app) == id and bottom.open(app);
    const layout = app.layouts.current();
    const lid = layout.leafOf(id) orelse return false;
    if (layout.leaf(lid).?.active != id) return false;
    if (app.zoomedPane()) |z| return z == id;
    return true;
}

/// The tree page `page` comes back to when the mode ends — the one
/// the session file writes down while the mode holds it.
pub fn restingLayout(app: *const App, page: usize, live: *const Layout) *const Layout {
    const st = &app.sessions_mode;
    if (!st.active) return live;
    if (page == st.page) if (st.pre) |*p| return p;
    for (st.others.items) |*o| if (o.page == page) return &o.layout;
    return live;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "deal: round-robin in the rail's order, so the first N are on show; fewer sessions than columns make fewer columns" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = try deal(a, &.{ 1, 2, 3, 4, 5 }, 2);
    try t.expectEqual(@as(usize, 2), two.len);
    try t.expectEqualSlices(PaneId, &.{ 1, 3, 5 }, two[0]);
    try t.expectEqualSlices(PaneId, &.{ 2, 4 }, two[1]);
    const four = try deal(a, &.{ 7, 8 }, 4);
    try t.expectEqual(@as(usize, 2), four.len);
    try t.expectEqual(@as(usize, 0), (try deal(a, &.{}, 3)).len);
}

/// A headless app whose `claude` / `codex` are the sleeping shims.
const Fx = struct {
    app: App,
    fn init() !Fx {
        const build_options = @import("build_options");
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 200, .rows = 50 });
        errdefer app.deinit();
        t.allocator.free(app.data_root);
        app.data_root = try t.allocator.dupe(u8, app.workspace);
        app.tree.visible = false;
        app.tree.loaded = true;
        app.cfg.ui.auto_show_sessions_on_ai_activate = false;
        const path = try std.fmt.allocPrint(t.allocator, "{s}/ai:{s}", .{ build_options.shims_dir, app.env.get("PATH") orelse "/usr/bin:/bin" });
        defer t.allocator.free(path);
        try app.env.put("PATH", path);
        _ = try app.openScratch();
        return .{ .app = app };
    }
    fn run(f: *Fx, id: command.CommandId) !PaneId {
        try command.run(&f.app, .{ .static = id });
        return f.app.active.?;
    }
};

test "enter and leave: the columns hold every session — this page's and another page's — and leaving puts every tree back as it was" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init();
    defer f.app.deinit();
    const app = &f.app;
    const file = app.active.?;
    const s1 = try f.run(.@"ai.claude_code_new_right");
    const s2 = try f.run(.@"ai.claude_code_new_right");
    const ratio_before = app.layouts.current().nodes.items[app.layouts.current().root.?].split.ratio;
    const p2 = try f.run(.@"ai.claude_code_new_page");
    const p2b = try f.run(.@"ai.claude_code_new_tab");
    @import("cmd_tab.zig").switchTab(app, 0);
    app.setActive(file);
    const arena = app.frame.allocator();
    const page0 = try arena.dupe(PaneId, try app.layouts.layouts.items[0].allPanes(arena));
    const page1 = try arena.dupe(PaneId, try app.layouts.layouts.items[1].allPanes(arena));
    app.cfg.ai.session_columns = 2;
    try command.run(app, .{ .static = .@"sessions.mode" });
    try t.expect(app.sessions_mode.active);
    try t.expect(app.layoutFault() == null);
    // Two columns on page 0, every session in one; page 1 lent its two.
    const cur = app.layouts.current();
    const leaves = try cur.leaves(arena);
    try t.expectEqual(@as(usize, 2), leaves.len);
    var n: usize = 0;
    for (leaves) |lid| n += cur.leaf(lid).?.tabs.items.len;
    try t.expectEqual(@as(usize, 4), n);
    for ([_]PaneId{ s1, s2, p2, p2b }) |s| try t.expect(cur.leafOf(s) != null);
    try t.expect(cur.leafOf(file) == null);
    try t.expectEqual(@as(usize, 0), (try app.layouts.layouts.items[1].allPanes(arena)).len);
    // The strip reads the column's stack, not the ring.
    try t.expectEqual(@as(usize, 2), (try stackPosition(app, cur.leaf(leaves[0]).?.active)).?.count);
    // Out: both pages as they were, the ratio too, the file with the keys.
    try command.run(app, .{ .static = .@"sessions.mode" });
    try t.expect(!app.sessions_mode.active);
    try t.expect(app.layoutFault() == null);
    try t.expectEqualSlices(PaneId, page0, try app.layouts.layouts.items[0].allPanes(arena));
    try t.expectEqualSlices(PaneId, page1, try app.layouts.layouts.items[1].allPanes(arena));
    try t.expectEqual(ratio_before, app.layouts.current().nodes.items[app.layouts.current().root.?].split.ratio);
    try t.expectEqual(file, app.active.?);
}

test "a zoomed session closing hands the zoom to the next session, out of the mode too; a stacked session is not on screen" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init();
    defer f.app.deinit();
    const app = &f.app;
    const s1 = try f.run(.@"ai.claude_code_new_right");
    const s2 = try f.run(.@"ai.claude_code_new_right");
    const s3 = try f.run(.@"ai.claude_code_new_tab");
    // s3 is on show, s2 stacked behind it.
    try t.expect(onScreen(app, s3));
    try t.expect(!onScreen(app, s2));
    try t.expect(onScreen(app, s1));
    try command.run(app, .{ .static = .@"view.toggle_zoom" });
    try t.expectEqual(@as(?PaneId, s3), app.zoomedPane());
    try t.expect(!onScreen(app, s1));
    try app.forceClosePane(s3);
    // The next in the ring after s3 wraps to s1: it takes the zoom.
    try t.expectEqual(@as(?PaneId, s1), app.zoomedPane());
    try t.expectEqual(s1, app.active.?);
    try t.expect(app.layoutFault() == null);
}

test "menus print the mode's chords in the mode: Ctrl+N is the new session's there and no longer New file's; outside, the other way round" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fx.init();
    defer f.app.deinit();
    const app = &f.app;
    try app.setInputStyle(.standard);
    const chordOf = @import("info_view_copy.zig").chordOf;
    const arena = app.frame.allocator();
    _ = try f.run(.@"ai.claude_code_new_right");
    const new_file = (try chordOf(app, arena, .@"file.new")).?;
    try t.expect(std.mem.indexOf(u8, new_file, "N") != null);
    try t.expect((try chordOf(app, arena, .@"sessions.mode_new")) == null);
    try command.run(app, .{ .static = .@"sessions.mode" });
    try t.expect((try chordOf(app, arena, .@"file.new")) == null);
    try t.expectEqualStrings(new_file, (try chordOf(app, arena, .@"sessions.mode_new")).?);
    try t.expect((try chordOf(app, arena, .@"sessions.column_next")) != null);
    try t.expect((try chordOf(app, arena, .@"buffer.last")) == null);
    // The standard input handler's own keys go through the same mask;
    // the mode takes none of them, so Cut keeps Ctrl+X.
    try t.expectEqualStrings("Ctrl+X", (try chordOf(app, arena, .@"editor.cut")).?);
    try command.run(app, .{ .static = .@"sessions.mode" });
    try t.expectEqualStrings(new_file, (try chordOf(app, arena, .@"file.new")).?);
}
