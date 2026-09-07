//! SESSIONS — the AI sessions of this workspace, on the `todos.zig`
//! shape (D8). The rows are the Claude Code / Codex transcripts the
//! AGENTS dashboard already reads (`agents.scanInto` over `~/.claude/
//! projects` and `~/.codex/sessions`), narrowed to this workspace: a
//! scan worker posts `.sessions = *ScanResult`, the snapshot arena keeps
//! the rows, `handle` adopts the payload, a stale generation is dropped.
//!
//! A row is `<glyph> <badge> <name>  <age>`: the source glyph, the state
//! badge (live / tool / idle / ended), the session's name — an alias the
//! user gave it, else its last prompt, else the id — and how long ago
//! its transcript moved. Enter resumes the session in a pty pane to the
//! right (`claude --resume <id>`); the row menu opens the transcript,
//! renames, copies the id, deletes the transcript after a confirm.
//!
//! The `sort:` chip is SESSIONS' own axis — State (approval-shaped
//! first, then live, tool, idle, ended, newest within) or Manual (the
//! order `J` / `K` build, persisted in the session file with the
//! aliases). While the panel is shown it rescans every `refresh_ms`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const App = app_mod.App;
const auto_refresh = @import("app/auto_refresh.zig");
const side = @import("app/side.zig");
const Key = app_mod.Key;
const key_mod = @import("core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("core/alloc.zig");
const command = @import("core/command.zig");
const CommandError = command.CommandError;
const event = @import("core/event.zig");
const Rect = @import("ui/rect.zig");
const Ui = @import("ui/context.zig");
const Theme = @import("ui/theme.zig");
const hit = @import("ui/hit.zig");
const list_panel = @import("ui/list_panel.zig");
const todos = @import("todos.zig");
const agents = @import("app/agents.zig");
const cli = @import("ai/cli.zig");
const pty_pane = @import("app/pty_pane.zig");
const settings = @import("app/settings.zig");
const Config = @import("config/Config.zig");

pub const Source = agents.Source;
pub const AgentState = agents.AgentState;
pub const SessionsSort = Config.SessionsSort;

/// One session. Slices borrow from `ScanResult.arena` in flight and
/// from `State.snapshot` once adopted.
pub const Item = struct {
    source: Source,
    session_id: []const u8,
    /// The workspace label the transcript carries (a basename).
    workspace: []const u8,
    cwd: ?[]const u8,
    transcript_path: []const u8,
    state: AgentState,
    pid: ?u32,
    /// Unix seconds of the last transcript change.
    last_activity_s: i64,
    last_user_msg: ?[]const u8,
    /// Claude Code's confirmation prompt is waiting: the transcript's
    /// last tool use has no result yet and the file has gone quiet.
    needs_approval: bool,
};

/// What `paintRow` sees: the item plus its display name, resolved
/// against the aliases on the frame arena.
pub const RowView = struct { item: Item, name: []const u8 };

pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    generation: u32,

    pub fn create(gpa: Allocator, generation: u32) Allocator.Error!*ScanResult {
        const r = try gpa.create(ScanResult);
        r.* = .{ .arena = .init(gpa), .generation = generation };
        return r;
    }

    pub fn destroy(self: *ScanResult, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Panel = list_panel.ListPanel(RowView);

pub const table = .{
    .@"sessions.refresh" = &refreshCmd,
    .@"sessions.sort" = &sortCmd,
    .@"sessions.sort_auto" = &sortAutoCmd,
    .@"sessions.sort_manual" = &sortManualCmd,
    .@"sessions.cycle_state" = &cycleStateCmd,
    .@"sessions.open" = &openCmd,
    .@"sessions.open_transcript" = &openTranscriptCmd,
    .@"sessions.rename" = &renameCmd,
    .@"sessions.copy_id" = &copyIdCmd,
    .@"sessions.delete" = &deleteCmd,
    .@"sessions.move_up" = &moveUpCmd,
    .@"sessions.move_down" = &moveDownCmd,
    .@"sessions.all_workspaces" = &allWorkspacesCmd,
};

/// A shown panel rescans this often (the dashboard's cadence).
pub const refresh_ms: i64 = 3000;
const double_click_ms: i64 = 500;

pub const Alias = struct { id: []u8, name: []u8 };

pub const State = struct {
    group: Io.Group = .init,
    snapshot: alloc.SnapshotArena,
    items: []Item = &.{},
    filtered: std.ArrayListUnmanaged(u32) = .empty,
    list: Panel.State = .{},
    sort: SessionsSort = .auto,
    /// Null = every state.
    state_filter: ?AgentState = null,
    /// Every workspace's sessions, not just this one's.
    all_workspaces: bool = false,
    /// Manual order: session ids, first on top. Owned.
    order: std.ArrayListUnmanaged([]u8) = .empty,
    /// Display names by session id. Owned.
    aliases: std.ArrayListUnmanaged(Alias) = .empty,
    generation: u32 = 0,
    scanning: bool = false,
    scanned_once: bool = false,
    last_scan_ms: i64 = 0,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,
    /// A home directory to scan instead of the loader's `$HOME` —
    /// what a test points at a fixture. Owned.
    home: ?[]u8 = null,

    pub fn init(gpa: Allocator, sort: SessionsSort) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa), .sort = sort };
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        for (self.order.items) |id| gpa.free(id);
        self.order.deinit(gpa);
        for (self.aliases.items) |a| {
            gpa.free(a.id);
            gpa.free(a.name);
        }
        self.aliases.deinit(gpa);
        if (self.home) |h| gpa.free(h);
        self.filtered.deinit(gpa);
        self.list.deinit(gpa);
        self.snapshot.deinit();
    }

    pub fn selected(self: *const State) ?Item {
        if (self.list.cursor >= self.filtered.items.len) return null;
        return self.items[self.filtered.items[self.list.cursor]];
    }

    pub fn alias(self: *const State, id: []const u8) ?[]const u8 {
        for (self.aliases.items) |a| if (std.mem.eql(u8, a.id, id)) return a.name;
        return null;
    }

    /// Set, replace, or (empty name) drop the alias for `id`.
    pub fn setAlias(self: *State, gpa: Allocator, id: []const u8, name: []const u8) Allocator.Error!void {
        for (self.aliases.items, 0..) |*a, i| if (std.mem.eql(u8, a.id, id)) {
            if (name.len == 0) {
                const gone = self.aliases.orderedRemove(i);
                gpa.free(gone.id);
                gpa.free(gone.name);
                return;
            }
            const fresh = try gpa.dupe(u8, name);
            gpa.free(a.name);
            a.name = fresh;
            return;
        };
        if (name.len == 0) return;
        const id_owned = try gpa.dupe(u8, id);
        errdefer gpa.free(id_owned);
        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);
        try self.aliases.append(gpa, .{ .id = id_owned, .name = name_owned });
    }

    pub fn orderIndex(self: *const State, id: []const u8) ?usize {
        for (self.order.items, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
        return null;
    }
};

// ─── the scan worker (D1 + D3) ──────────────────────────────────────────

/// Cancel any scan in flight, bump the generation, start a new one over
/// the home directory. No home (the `.test` runner's apps) is an empty
/// list, not an error.
pub fn refresh(app: *App) CommandError!void {
    const st = &app.sessions;
    st.last_scan_ms = app.now_ms;
    st.scanned_once = true;
    const home = st.home orelse app.homeDir() orelse {
        st.scanning = false;
        st.snapshot.reset();
        st.items = &.{};
        try refilter(app);
        return;
    };
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.scanning = true;
    app.needs_render = true;
    st.group.concurrent(app.io, scanWorker, .{ &app.events, app.io, app.gpa, home, app.workspace, st.generation }) catch |err| {
        st.scanning = false;
        return app.diag.fail(app.frame.allocator(), "sessions: could not start the scan: {s}", .{@errorName(err)});
    };
}

fn scanWorker(events: *event.EventQueue, io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, generation: u32) Io.Cancelable!void {
    const result = ScanResult.create(gpa, generation) catch {
        postErr(events, io, gpa, "out of memory starting the scan");
        return;
    };
    errdefer result.destroy(gpa);
    scanInto(io, gpa, home, workspace, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => {
            postErr(events, io, gpa, "out of memory during the scan");
            return;
        },
    };
    events.post(io, .{ .sessions = result });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .sessions, .msg = owned } });
}

const ScanError = Io.Cancelable || Allocator.Error;

/// The dashboard's walk, its rows copied onto `r.arena` in this
/// module's shape. Every session is kept; `refilter` narrows to the
/// workspace, so the toggle needs no rescan.
pub fn scanInto(io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, r: *ScanResult) ScanError!void {
    const arena = r.arena.allocator();
    const inner = try agents.ScanResult.create(gpa, r.generation, 0);
    defer inner.destroy(gpa);
    try agents.scanInto(io, gpa, home, workspace, inner);
    const items = try arena.alloc(Item, inner.rows.len);
    for (inner.rows, 0..) |row, i| items[i] = .{
        .source = row.source,
        .session_id = try arena.dupe(u8, row.session_id),
        .workspace = try arena.dupe(u8, row.workspace),
        .cwd = if (row.cwd) |c| try arena.dupe(u8, c) else null,
        .transcript_path = try arena.dupe(u8, row.transcript_path),
        .state = row.state,
        .pid = row.pid,
        .last_activity_s = row.last_activity_s,
        .last_user_msg = if (row.last_user_msg) |m| try arena.dupe(u8, m) else null,
        .needs_approval = row.pid != null and row.pending_tool_uses > 0 and row.state != .streaming,
    };
    r.items = items;
}

// ─── the event handler (D1) ─────────────────────────────────────────────

pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    const st = &app.sessions;
    defer result.destroy(app.gpa);
    if (result.generation != st.generation) return;
    st.scanning = false;
    const keep: ?[]const u8 = if (st.selected()) |it| try app.frame.allocator().dupe(u8, it.session_id) else null;
    st.snapshot.reset();
    st.items = &.{};
    const arena = st.snapshot.allocator();
    const items = try arena.alloc(Item, result.items.len);
    for (result.items, 0..) |it, i| items[i] = .{
        .source = it.source,
        .session_id = try arena.dupe(u8, it.session_id),
        .workspace = try arena.dupe(u8, it.workspace),
        .cwd = if (it.cwd) |c| try arena.dupe(u8, c) else null,
        .transcript_path = try arena.dupe(u8, it.transcript_path),
        .state = it.state,
        .pid = it.pid,
        .last_activity_s = it.last_activity_s,
        .last_user_msg = if (it.last_user_msg) |m| try arena.dupe(u8, m) else null,
        .needs_approval = it.needs_approval,
    };
    st.items = items;
    try refilter(app);
    // The selection follows its session across a rescan.
    if (keep) |sid| for (st.filtered.items, 0..) |idx, vi| if (std.mem.eql(u8, st.items[idx].session_id, sid)) {
        st.list.cursor = vi;
        break;
    };
    app.needs_render = true;
}

/// State order: a session waiting on an approval first, then live,
/// tool, idle, ended; newest within a rank.
fn rank(it: Item) u8 {
    if (it.needs_approval) return 0;
    return 1 + it.state.rank();
}

/// Workspace, state filter and the `/` text narrow; then the axis
/// orders: State, or the manual list (ids not on it follow, newest first).
pub fn refilter(app: *App) Allocator.Error!void {
    const st = &app.sessions;
    st.filtered.clearRetainingCapacity();
    const q = st.list.filterText();
    const ws_name = std.fs.path.basename(app.workspace);
    for (st.items, 0..) |it, i| {
        if (!st.all_workspaces and !inWorkspace(it, app.workspace, ws_name)) continue;
        if (st.state_filter) |s| if (it.state != s) continue;
        if (q.len > 0 and !matches(app, it, q)) continue;
        try st.filtered.append(app.gpa, @intCast(i));
    }
    const Ctx = struct {
        st: *const State,
        fn lt(ctx: @This(), a: u32, b: u32) bool {
            const ia = ctx.st.items[a];
            const ib = ctx.st.items[b];
            switch (ctx.st.sort) {
                .auto => {
                    const ra = rank(ia);
                    const rb = rank(ib);
                    if (ra != rb) return ra < rb;
                },
                .manual => {
                    const oa = ctx.st.orderIndex(ia.session_id);
                    const ob = ctx.st.orderIndex(ib.session_id);
                    if (oa != null and ob != null) return oa.? < ob.?;
                    if (oa != null) return true;
                    if (ob != null) return false;
                },
            }
            if (ia.last_activity_s != ib.last_activity_s) return ia.last_activity_s > ib.last_activity_s;
            return std.mem.order(u8, ia.session_id, ib.session_id) == .lt;
        }
    };
    std.mem.sort(u32, st.filtered.items, Ctx{ .st = st }, Ctx.lt);
    if (st.list.cursor >= st.filtered.items.len) st.list.cursor = st.filtered.items.len -| 1;
}

fn inWorkspace(it: Item, workspace: []const u8, ws_name: []const u8) bool {
    if (it.cwd) |c| if (std.mem.startsWith(u8, c, workspace)) return true;
    return std.mem.eql(u8, it.workspace, ws_name);
}

fn matches(app: *App, it: Item, q: []const u8) bool {
    if (app.sessions.alias(it.session_id)) |a| if (todos.containsIgnoreCase(a, q)) return true;
    if (it.last_user_msg) |m| if (todos.containsIgnoreCase(m, q)) return true;
    return todos.containsIgnoreCase(it.session_id, q) or todos.containsIgnoreCase(it.workspace, q) or
        todos.containsIgnoreCase(it.source.label(), q) or todos.containsIgnoreCase(@tagName(it.state), q);
}

/// The alias, else the last prompt, else the id's first eight characters.
pub fn displayName(app: *App, it: Item) []const u8 {
    if (app.sessions.alias(it.session_id)) |a| return a;
    if (it.last_user_msg) |m| {
        const line = std.mem.trim(u8, m, " \t\r\n");
        if (line.len > 0) return line;
    }
    return it.session_id[0..@min(it.session_id.len, 8)];
}

pub fn setSort(app: *App, sort: SessionsSort) Allocator.Error!void {
    app.sessions.sort = sort;
    try refilter(app);
    app.needs_render = true;
}

/// Every tick: a shown panel rescans on the dashboard's cadence.
pub fn tick(app: *App, now: i64) void {
    const st = &app.sessions;
    if (!side.isShown(app, .sessions) or st.scanning or !st.scanned_once or !auto_refresh.on(app, .sessions)) return;
    if (now - st.last_scan_ms < refresh_ms) return;
    refresh(app) catch {};
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.sessions;
    if (!side.isShown(app, .sessions) or !st.scanned_once) return null;
    if (st.scanning) return app.now_ms + 80;
    return st.last_scan_ms + refresh_ms;
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn refreshCmd(app: *App) CommandError!void {
    return refresh(app);
}

/// The chip's click: the other axis, persisted as `ui.sessions_sort`.
fn sortCmd(app: *App) CommandError!void {
    return applySort(app, switch (app.sessions.sort) {
        .auto => .manual,
        .manual => .auto,
    });
}

fn sortAutoCmd(app: *App) CommandError!void {
    return applySort(app, .auto);
}

fn sortManualCmd(app: *App) CommandError!void {
    return applySort(app, .manual);
}

fn applySort(app: *App, sort: SessionsSort) CommandError!void {
    try setSort(app, sort);
    app.cfg.ui.sessions_sort = sort;
    _ = try settings.persist(app, .workspace, &.{ "ui", "sessions_sort" }, sort);
    app.toast("sessions: {s}", .{sortLabel(sort)});
}

pub fn sortLabel(s: SessionsSort) []const u8 {
    return switch (s) {
        .auto => "State",
        .manual => "Manual",
    };
}

pub const sort_widest: usize = 6;

/// `f`: the state filter cycles every → live → tool → idle → ended.
fn cycleStateCmd(app: *App) CommandError!void {
    const st = &app.sessions;
    st.state_filter = if (st.state_filter) |s| switch (s) {
        .streaming => .tool_call,
        .tool_call => .idle,
        .idle => .ended,
        .ended => null,
    } else .streaming;
    try refilter(app);
    app.needs_render = true;
}

/// `w`: this workspace's sessions, or every workspace's.
fn allWorkspacesCmd(app: *App) CommandError!void {
    app.sessions.all_workspaces = !app.sessions.all_workspaces;
    try refilter(app);
    app.needs_render = true;
    app.toast("sessions: {s}", .{if (app.sessions.all_workspaces) "every workspace" else "this workspace"});
}

/// Enter / double-click / the menu's first row: resume the session in
/// a pty pane to the right, in its own cwd.
fn openCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.sessions.selected() orelse return app.diag.fail(arena, "sessions: nothing selected", .{});
    const argv: []const []const u8 = switch (it.source) {
        .claude => try cli.claudeResumeArgv(arena, try arena.dupe(u8, it.session_id)),
        .codex => &.{cli.codex_binary},
    };
    const cwd: ?[]const u8 = if (it.cwd) |c| try arena.dupe(u8, c) else null;
    _ = try pty_pane.open(app, .{ .argv = argv, .cwd = cwd, .label = it.source.label(), .placement = .right, .kind = .command });
}

/// The transcript itself, in an editor.
fn openTranscriptCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.sessions.selected() orelse return app.diag.fail(arena, "sessions: nothing selected", .{});
    const path = try arena.dupe(u8, it.transcript_path);
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open transcript: {s}", .{@errorName(err)}),
    };
}

/// A prompt seeded with the current name; empty resets to the default.
fn renameCmd(app: *App) CommandError!void {
    const it = app.sessions.selected() orelse return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    const id = try app.gpa.dupe(u8, it.session_id);
    errdefer app.gpa.free(id);
    const current = app.sessions.alias(it.session_id) orelse "";
    const seed = try app.frame.allocator().dupe(u8, current);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Rename session (empty = reset to default)"), .purpose = .{ .sessions_rename = id } } };
    app.overlay.prompt.state.setText(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The rename prompt's accept.
pub fn acceptRename(app: *App, id: []const u8, text: []const u8) Allocator.Error!void {
    try app.sessions.setAlias(app.gpa, id, std.mem.trim(u8, text, " \t\r\n"));
    try refilter(app);
    app.needs_render = true;
}

fn copyIdCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.sessions.selected() orelse return app.diag.fail(arena, "sessions: nothing selected", .{});
    const text = try arena.dupe(u8, it.session_id);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// Delete the transcript after a confirm. A live session is refused:
/// its process would keep writing to a file that is gone.
fn deleteCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.sessions.selected() orelse return app.diag.fail(arena, "sessions: nothing selected", .{});
    if (it.pid != null) return app.diag.fail(arena, "sessions: {s} is running — end it first", .{displayName(app, it)});
    const path = try app.gpa.dupe(u8, it.transcript_path);
    errdefer app.gpa.free(path);
    const msg = try std.fmt.allocPrint(app.gpa, "  Delete the transcript of {s}?", .{displayName(app, it)});
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Delete session", .message = msg, .choices = &delete_choices },
        .purpose = .{ .delete_session = path },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const delete_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm's accept: the file goes, the alias and the manual slot
/// with it, and the panel rescans.
pub fn acceptDelete(app: *App, path: []const u8) Allocator.Error!void {
    Io.Dir.cwd().deleteFile(app.io, path) catch |err| {
        app.toast("delete {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        return;
    };
    const st = &app.sessions;
    for (st.items) |it| if (std.mem.eql(u8, it.transcript_path, path)) {
        try st.setAlias(app.gpa, it.session_id, "");
        if (st.orderIndex(it.session_id)) |i| app.gpa.free(st.order.orderedRemove(i));
        break;
    };
    app.toast("deleted {s}", .{std.fs.path.basename(path)});
    refresh(app) catch {};
}

/// `J` / `K`: move the selected row in the manual order. The visible
/// order is adopted as the manual list first, so the first move from
/// the State axis keeps everything else where it was.
fn moveUpCmd(app: *App) CommandError!void {
    return moveBy(app, -1);
}

fn moveDownCmd(app: *App) CommandError!void {
    return moveBy(app, 1);
}

fn moveBy(app: *App, delta: i32) CommandError!void {
    const st = &app.sessions;
    if (st.filtered.items.len == 0) return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    try adoptVisibleOrder(app);
    const cur: i32 = @intCast(st.list.cursor);
    const target = cur + delta;
    if (target < 0 or target >= @as(i32, @intCast(st.filtered.items.len))) return;
    const a = st.items[st.filtered.items[@intCast(cur)]].session_id;
    const b = st.items[st.filtered.items[@intCast(target)]].session_id;
    const ia = st.orderIndex(a).?;
    const ib = st.orderIndex(b).?;
    std.mem.swap([]u8, &st.order.items[ia], &st.order.items[ib]);
    if (st.sort != .manual) {
        st.sort = .manual;
        app.cfg.ui.sessions_sort = .manual;
        _ = try settings.persist(app, .workspace, &.{ "ui", "sessions_sort" }, SessionsSort.manual);
    }
    try refilter(app);
    st.list.cursor = @intCast(target);
    app.needs_render = true;
}

/// Every visible id joins the manual list, in the order shown, after
/// what is already on it.
fn adoptVisibleOrder(app: *App) Allocator.Error!void {
    const st = &app.sessions;
    for (st.filtered.items) |idx| {
        const id = st.items[idx].session_id;
        if (st.orderIndex(id) != null) continue;
        const owned = try app.gpa.dupe(u8, id);
        errdefer app.gpa.free(owned);
        try st.order.append(app.gpa, owned);
    }
}

// ─── keys ───────────────────────────────────────────────────────────────

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.sessions;
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed => return true,
        .filter_changed => {
            try refilter(app);
            return true;
        },
        .activate => |i| {
            st.list.cursor = i;
            runToast(app, openCmd(app));
            return true;
        },
        .new_activate => {},
        .ignored => {},
    }
    if (st.list.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'r' => runToast(app, refresh(app)),
                's' => runToast(app, sortCmd(app)),
                'f' => runToast(app, cycleStateCmd(app)),
                'w' => runToast(app, allWorkspacesCmd(app)),
                'o' => runToast(app, openTranscriptCmd(app)),
                'R' => runToast(app, renameCmd(app)),
                'y' => runToast(app, copyIdCmd(app)),
                'x' => runToast(app, deleteCmd(app)),
                'J' => runToast(app, moveDownCmd(app)),
                'K' => runToast(app, moveUpCmd(app)),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("sessions: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.sessions;
    switch (m.kind) {
        .press => {
            if (idx >= st.filtered.items.len) return;
            focusPanel(app);
            st.list.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                runToast(app, openCmd(app));
            }
        },
        .scroll_up => st.list.cursor -|= 3,
        .scroll_down => st.list.cursor = @min(st.list.cursor + 3, st.filtered.items.len -| 1),
        else => {},
    }
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.sessions.filtered.items.len) return;
    focusPanel(app);
    app.sessions.list.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, m.x, m.y) else runToast(app, sortCmd(app)),
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .sessions, m.x, m.y) else runToast(app, refresh(app)),
        .new, .view => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.sessions.list.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.sessions;
    const total = st.filtered.items.len;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            const off: usize = m.y -| bar.y;
            st.list.cursor = @min(off * total / bar.h, total - 1);
        },
        .scroll_up => st.list.cursor -|= 3,
        .scroll_down => st.list.cursor = @min(st.list.cursor + 3, total - 1),
        else => {},
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .sessions };
    app.needs_render = true;
}

fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Resume in a terminal", .action = .{ .command = .@"sessions.open" } },
        .{ .label = "Open transcript", .action = .{ .command = .@"sessions.open_transcript" } },
        .{ .label = "Rename…", .action = .{ .command = .@"sessions.rename" }, .separator_before = true },
        .{ .label = "Copy session id", .action = .{ .command = .@"sessions.copy_id" } },
        .{ .label = "Move up", .action = .{ .command = .@"sessions.move_up" }, .separator_before = true },
        .{ .label = "Move down", .action = .{ .command = .@"sessions.move_down" } },
        .{ .label = "Delete transcript…", .action = .{ .command = .@"sessions.delete" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Session", items, x, y);
}

/// SESSIONS' own axis: the two modes name their commands directly.
fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "State", .action = .{ .command = .@"sessions.sort_auto" }, .checked = app.sessions.sort == .auto },
        .{ .label = "Manual", .action = .{ .command = .@"sessions.sort_manual" }, .checked = app.sessions.sort == .manual },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Sort by", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.sessions;
    if (!st.scanned_once and !st.scanning) refresh(app) catch {};
    const rows = try ui.arena.alloc(RowView, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = .{ .item = st.items[idx], .name = displayName(app, st.items[idx]) };
    var in_ws: usize = 0;
    const ws_name = std.fs.path.basename(app.workspace);
    for (st.items) |it| if (st.all_workspaces or inWorkspace(it, app.workspace, ws_name)) {
        in_ws += 1;
    };
    const narrowed = st.list.filterText().len > 0 or st.state_filter != null;
    const subtitle = if (!narrowed)
        ui.fmt(" ({d})", .{in_ws})
    else if (st.state_filter) |s|
        ui.fmt(" ({d} of {d} · {s})", .{ rows.len, in_ws, @tagName(s) })
    else
        ui.fmt(" ({d} of {d})", .{ rows.len, in_ws });
    const no_home = st.home == null and app.homeDir() == null;
    const empty: list_panel.EmptyState = if (st.scanning and st.items.len == 0)
        .{ .message = "Scanning sessions…" }
    else if (no_home)
        .{ .message = "No home directory — nowhere to look for sessions." }
    else if (in_ws == 0 and st.items.len > 0)
        .{ .message = "No sessions for this workspace — w shows every workspace's." }
    else if (st.items.len == 0)
        .{ .message = "No sessions yet." }
    else
        .{ .message = "No matches — Esc clears" };
    now_s = Io.Timestamp.now(app.io, .real).toSeconds();
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .sessions,
        .label = "SESSIONS",
        .subtitle = subtitle,
        .sort_chip = sortLabel(st.sort),
        .sort_widest = sort_widest,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    if (st.scanning) list_panel.paintSpinner(ui, area, "SESSIONS", app.now_ms);
}

/// Set by `draw` (the paint callback has no `*App`).
var now_s: i64 = 0;

fn badgeStyle(t: *const Theme, it: Item, base: vaxis.Style) vaxis.Style {
    if (it.needs_approval) {
        var s = Theme.withFg(base, t.warn_fg.fg);
        s.bold = true;
        return s;
    }
    return Theme.withFg(base, switch (it.state) {
        .streaming => t.accent.fg,
        .tool_call => t.info_fg.fg,
        .idle => t.fg.fg,
        .ended => t.muted.fg,
    });
}

/// `<glyph> <badge> <name>  <age>`: the badge coloured by state (an
/// approval wait in the warning colour), the name in the text colour,
/// the age dim and right-aligned. The name gives way first.
fn paintRow(ui: Ui, r: Rect, row: RowView, selected: bool) void {
    const t = ui.theme;
    const it = row.item;
    const base = list_panel.rowStyle(t, selected);
    var x = r.x;
    const end = r.right();
    const age = list_panel.ageText(ui, now_s, it.last_activity_s);
    const age_w = ui.width(age);
    var body_end = end;
    if (age_w + 2 < end -| x) {
        _ = ui.putStr(end - age_w, r.y, age_w, age, Theme.onBg(t.muted, base.bg));
        body_end = end - age_w - 1;
    }
    x += ui.putStr(x, r.y, body_end -| x, it.source.glyph(ui.ascii), Theme.withFg(base, t.accent.fg));
    x += ui.putStr(x, r.y, body_end -| x, " ", base);
    const badge: []const u8 = if (it.needs_approval) (if (ui.ascii) "! wait" else "▲ wait") else it.state.badge(ui.ascii);
    x += ui.putStr(x, r.y, body_end -| x, badge, badgeStyle(t, it, base));
    if (body_end -| x > 3) {
        x += ui.putStr(x, r.y, body_end -| x, "  ", base);
        const name_style = if (it.state == .ended) Theme.onBg(t.muted, base.bg) else Theme.onBg(t.fg, base.bg);
        _ = ui.putStr(x, r.y, body_end -| x, ui.clipStr(row.name, body_end -| x), name_style);
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const transcript = @import("ai/transcript.zig");

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,

    fn init(cols: u16, rows: u16) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = cols, .rows = rows });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// A fixture home with one Claude and one Codex transcript, pointed
    /// at by `State.home`.
    fn seedHome(f: *Fixture) !void {
        try f.tmp.dir.createDirPath(testing.io, "home/.claude/projects/-Users-me-Projects-mnml");
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/projects/-Users-me-Projects-mnml/aaaaaaaa-0000-4000-8000-000000000001.jsonl", .data = transcript.claude_fixture });
        try f.tmp.dir.createDirPath(testing.io, "home/.codex/sessions/2026/09/04");
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.codex/sessions/2026/09/04/rollout-2026-09-04T10-00-00-bbbbbbbb-0000-4000-8000-000000000002.jsonl", .data = transcript.codex_fixture });
        f.app.sessions.home = try std.fs.path.join(testing.allocator, &.{ f.root, "home" });
    }

    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (f.app.sessions.scanning and i < max) : (i += 1) {
            try f.app.tick(App.nowMs(testing.io));
            if (f.app.sessions.scanning) testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }
};

fn item(id: []const u8, state: AgentState, at: i64, ws: []const u8, msg: ?[]const u8) Item {
    return .{ .source = .claude, .session_id = id, .workspace = ws, .cwd = null, .transcript_path = "/t", .state = state, .pid = null, .last_activity_s = at, .last_user_msg = msg, .needs_approval = false };
}

test "refilter: this workspace only unless toggled; State ranks approval, live, tool, idle, ended; Manual follows the order list then recency" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const st = &f.app.sessions;
    const ws = std.fs.path.basename(f.root);
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 5);
    items[0] = item("idle-old", .idle, 10, ws, "fix the tests");
    items[1] = item("ended", .ended, 50, ws, null);
    items[2] = item("live", .streaming, 20, ws, "ship it");
    items[3] = item("elsewhere", .streaming, 99, "other", null);
    items[4] = item("waiting", .idle, 30, ws, "approve?");
    items[4].needs_approval = true;
    r.items = items;
    st.generation = 1;
    try handle(&f.app, r);
    // Four in this workspace; the approval wait first, then live, idle, ended.
    try testing.expectEqual(@as(usize, 4), st.filtered.items.len);
    try testing.expectEqualStrings("waiting", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqualStrings("live", st.items[st.filtered.items[1]].session_id);
    try testing.expectEqualStrings("idle-old", st.items[st.filtered.items[2]].session_id);
    try testing.expectEqualStrings("ended", st.items[st.filtered.items[3]].session_id);
    // Every workspace: the other one joins, at its rank (live) by recency.
    st.all_workspaces = true;
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 5), st.filtered.items.len);
    try testing.expectEqualStrings("elsewhere", st.items[st.filtered.items[1]].session_id);
    st.all_workspaces = false;
    // The state filter.
    st.state_filter = .idle;
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 2), st.filtered.items.len);
    st.state_filter = null;
    // Manual: the order list first, the rest by recency.
    try st.order.append(testing.allocator, try testing.allocator.dupe(u8, "ended"));
    try st.order.append(testing.allocator, try testing.allocator.dupe(u8, "idle-old"));
    try setSort(&f.app, .manual);
    try testing.expectEqualStrings("ended", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqualStrings("idle-old", st.items[st.filtered.items[1]].session_id);
    try testing.expectEqualStrings("waiting", st.items[st.filtered.items[2]].session_id); // 30 > 20
    try testing.expectEqualStrings("live", st.items[st.filtered.items[3]].session_id);
    // The text filter matches the alias, the prompt and the id.
    try st.setAlias(testing.allocator, "live", "release train");
    try st.list.filter.appendSlice(testing.allocator, "TRAIN");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqualStrings("release train", displayName(&f.app, st.selected().?));
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "tests");
    try refilter(&f.app);
    try testing.expectEqualStrings("idle-old", st.selected().?.session_id);
    st.list.filter.clearRetainingCapacity();
    // An empty alias drops it; the name falls back to the prompt.
    try st.setAlias(testing.allocator, "live", "");
    try testing.expect(st.alias("live") == null);
    try refilter(&f.app);
    try testing.expectEqualStrings("ship it", displayName(&f.app, st.items[st.filtered.items[3]]));
    // A stale generation is dropped.
    const stale = try ScanResult.create(testing.allocator, 0);
    try handle(&f.app, stale);
    try testing.expectEqual(@as(usize, 5), st.items.len);
}

test "scanInto over a fixture home lists the dashboard's sessions in this module's shape" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.seedHome();
    const r = try ScanResult.create(testing.allocator, 1);
    defer r.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.app.sessions.home.?, f.root, r);
    try testing.expectEqual(@as(usize, 2), r.items.len);
    var claude_seen = false;
    for (r.items) |it| if (it.source == .claude) {
        claude_seen = true;
        try testing.expectEqualStrings("aaaaaaaa-0000-4000-8000-000000000001", it.session_id);
        try testing.expectEqualStrings("mnml", it.workspace);
        try testing.expect(std.mem.endsWith(u8, it.transcript_path, ".jsonl"));
        try testing.expectEqual(AgentState.ended, it.state);
    };
    try testing.expect(claude_seen);
}

test "headless: the panel lists every workspace's sessions after w, J adopts the visible order and flips to Manual, the menus name real ids, rename lands as an alias" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.seedHome();
    f.app.tree.visible = false;
    // The panel on the right, 56 wide (the chrome the test reads).
    f.app.side.of.set(.sessions, .right);
    f.app.side.right_width = 56;
    try command.run(&f.app, .{ .static = .@"view.activity_sessions" });
    try f.app.render();
    try f.settle(2000);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "SESSIONS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "sort: State") != null);
    // The fixtures belong to other workspaces: the empty state says so.
    try testing.expect(std.mem.indexOf(u8, txt, "No sessions for this workspace") != null);
    try f.app.handle(.{ .key = Key.char('w') });
    try testing.expect(f.app.sessions.all_workspaces);
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "ended") != null);
    try testing.expectEqual(@as(usize, 2), f.app.sessions.filtered.items.len);
    // J moves the top row down: the visible order becomes the manual list.
    const first = f.app.sessions.items[f.app.sessions.filtered.items[0]].session_id;
    try f.app.handle(.{ .key = Key.char('J') });
    try testing.expectEqual(SessionsSort.manual, f.app.sessions.sort);
    try testing.expectEqual(SessionsSort.manual, f.app.cfg.ui.sessions_sort);
    try testing.expectEqualStrings(first, f.app.sessions.items[f.app.sessions.filtered.items[1]].session_id);
    try testing.expectEqual(@as(usize, 1), f.app.sessions.list.cursor);
    try testing.expectEqual(@as(usize, 2), f.app.sessions.order.items.len);
    // The chip toggles back to State and persists.
    try f.app.handle(.{ .key = Key.char('s') });
    try testing.expectEqual(SessionsSort.auto, f.app.sessions.sort);
    const cfg = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/config.zon", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "sessions_sort") != null);
    // Menus.
    try f.app.render();
    var row0: ?Rect = null;
    var sort_chip: ?Rect = null;
    for (f.app.hits.items.items) |h| switch (h.target) {
        .row => |r| if (r.panel == .sessions and r.idx == 0) {
            row0 = h.rect;
        },
        .chip => |c| if (c.panel == .sessions and c.kind == .sort) {
            sort_chip = h.rect;
        },
        else => {},
    };
    try testing.expect(row0 != null and sort_chip != null);
    try f.app.handle(.{ .mouse = .{ .x = row0.?.x + 1, .y = row0.?.y, .kind = .press, .button = .right } });
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(@as(usize, 7), f.app.overlay.menu.items.len);
    for (f.app.overlay.menu.items) |it| try testing.expect(it.action == .command);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try f.app.handle(.{ .mouse = .{ .x = sort_chip.?.x + 1, .y = sort_chip.?.y, .kind = .press, .button = .right } });
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(@as(usize, 2), f.app.overlay.menu.items.len);
    try testing.expect(f.app.overlay.menu.items[0].checked);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // The Codex fixture can claim a real codex process on this machine
    // (the dashboard pairs the newest unclaimed one), so the rest acts
    // on the Claude row, whose pid is matched by session id alone.
    const claude_row = struct {
        fn find(st: *const State) usize {
            for (st.filtered.items, 0..) |idx, vi| if (st.items[idx].source == .claude) return vi;
            unreachable;
        }
    };
    f.app.sessions.list.cursor = claude_row.find(&f.app.sessions);
    // Rename through the prompt: the alias shows and survives a rescan.
    try f.app.handle(.{ .key = Key.char('R') });
    try testing.expect(f.app.overlay == .prompt);
    for ("nightly build") |c| try f.app.handle(.{ .key = Key.char(c) });
    try f.app.handle(.{ .key = Key.named(.enter) });
    const named = f.app.sessions.selected().?;
    try testing.expectEqualStrings("nightly build", f.app.sessions.alias(named.session_id).?);
    try command.run(&f.app, .{ .static = .@"sessions.refresh" });
    try f.settle(2000);
    const txt3 = try f.screen();
    defer testing.allocator.free(txt3);
    try testing.expect(std.mem.indexOf(u8, txt3, "nightly build") != null);
    // Delete through the confirm: the transcript goes and the row with it.
    focusPanel(&f.app); // the prompt handed focus back to the pane
    f.app.sessions.list.cursor = claude_row.find(&f.app.sessions);
    try testing.expect(f.app.sessions.selected().?.pid == null);
    try f.app.handle(.{ .key = Key.char('x') });
    try testing.expect(f.app.overlay == .confirm);
    try f.app.handle(.{ .key = Key.char('d') });
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 1), f.app.sessions.items.len);
    try testing.expect(f.app.sessions.alias(named.session_id) == null);
}

test "tick rescans a shown panel on the cadence and leaves a hidden one alone" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.seedHome();
    const st = &f.app.sessions;
    st.scanned_once = true;
    st.last_scan_ms = 0;
    tick(&f.app, refresh_ms + 1); // hidden: nothing
    try testing.expectEqual(@as(u32, 0), st.generation);
    side.place(&f.app, .sessions, false);
    f.app.now_ms = refresh_ms - 1;
    tick(&f.app, refresh_ms - 1);
    try testing.expectEqual(@as(u32, 0), st.generation);
    f.app.now_ms = refresh_ms + 1;
    tick(&f.app, refresh_ms + 1);
    try testing.expectEqual(@as(u32, 1), st.generation);
    try testing.expect(nextDeadlineMs(&f.app) != null);
    try f.settle(2000);
}
