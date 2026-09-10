//! SESSIONS — the AI sessions of this workspace, on the `todos.zig`
//! shape (D8). One row model, `Item`, behind two views: this sidebar
//! section (the cards, scoped to the workspace) and the sessions table
//! (`app/sessions_table.zig`, every row on the machine, grouped by
//! workspace). Three scanners feed it — the Claude Code / Codex
//! transcripts (`app/agents.zig` over `~/.claude/projects` and
//! `~/.codex/sessions`) and, when the API is configured, the cloud runs
//! (`app/cloud_agents.zig`) — from one worker that posts `.sessions =
//! *ScanResult`; the snapshot arena keeps the rows, `handle` adopts the
//! payload (and notices state edges: a session that starts `waiting`
//! toasts once, badges its tab, rings the bell when `ui.session_bell`),
//! a stale generation is dropped.
//!
//! // changed (sessions-merge): the AGENTS dashboard and the CLOUD
//! AGENTS section folded into this model; `waiting` / `done` / `failed`
//! are states; `dirty` is the cwd's `git status` count.
//!
//! A row is Rust's card (`src/ui/sessions_panel.rs`), cell for cell:
//! four rows and a blank one — the accent `▌` down its left, the name
//! (an alias the user gave it, else its last prompt, else the id) after
//! a pin, then the transcript's last exchange as `you: …` / `claude: …`
//! (`exited` alone once the session has ended). Above the cards the
//! panel is the Zig idiom: the caps header with the sort and refresh
//! chips, the filter pill, a blank, the green `+ New session` row (a
//! fresh Claude Code session, `ai.claude_code_new`), a blank. Enter
//! resumes the session in a pty pane to the right (`claude --resume
//! <id>`); the row menu pins, moves, renames, opens the transcript,
//! copies the id, deletes the transcript after a confirm.
//!
//! The `sort:` chip is SESSIONS' own axis — State (approval-shaped
//! first, then live, tool, idle, ended, newest within) or Manual (the
//! order `J` / `K` build, persisted in the session file with the
//! aliases); pinned sessions lead on either. While the panel is shown
//! it rescans every `refresh_ms`.

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
const cloud_agents = @import("app/cloud_agents.zig");
const sessions_table = @import("app/sessions_table.zig");
const pty_pane_mod = @import("app/pty_pane.zig");
const cli = @import("ai/cli.zig");
const pty_pane = @import("app/pty_pane.zig");
const settings = @import("app/settings.zig");
const Config = @import("config/Config.zig");
const accent_color = @import("ui/accent_color.zig");
const session_worktree = @import("app/session_worktree.zig");

pub const Source = agents.Source;
pub const AgentState = agents.AgentState;
pub const SessionsSort = Config.SessionsSort;

/// Where a session runs.
pub const Where = enum {
    local,
    cloud,

    pub fn label(w: Where) []const u8 {
        return @tagName(w);
    }
};

/// What a cloud row carries beyond the common columns.
pub const CloudInfo = struct {
    ticket: []const u8 = "",
    flow: []const u8 = "",
    /// The runner's own word (`started`, `staged`, `shipped`, …).
    raw_state: []const u8 = "",
    task_arn: ?[]const u8 = null,
    pr_url: ?[]const u8 = null,
};

/// One session — the one row model. Slices borrow from
/// `ScanResult.arena` in flight and from `State.snapshot` once adopted.
pub const Item = struct {
    source: Source,
    where: Where = .local,
    session_id: []const u8,
    /// The workspace label the transcript carries (a basename).
    workspace: []const u8,
    cwd: ?[]const u8,
    model: ?[]const u8 = null,
    transcript_path: []const u8,
    state: AgentState,
    pid: ?u32,
    tokens: u64 = 0,
    cost_usd: f64 = 0,
    /// Unix seconds of the last transcript change.
    last_activity_s: i64,
    last_user_msg: ?[]const u8,
    last_assistant_msg: ?[]const u8,
    current_tool: ?[]const u8 = null,
    pending_tool_uses: usize = 0,
    git_branch: ?[]const u8 = null,
    /// `git status --porcelain` entries in the cwd; null = not asked,
    /// or the cwd is gone or no repository.
    dirty: ?u32 = null,
    cloud: ?CloudInfo = null,

    /// The table groups on this: the cwd, else the workspace label;
    /// every cloud row under the cloud label.
    pub fn groupKey(it: Item) []const u8 {
        if (it.where == .cloud) return it.workspace;
        return it.cwd orelse it.workspace;
    }

    /// The group's row: the cwd's basename, else the label.
    pub fn groupLabel(it: Item) []const u8 {
        if (it.where == .cloud) return it.workspace;
        if (it.cwd) |c| {
            const base = std.fs.path.basename(c);
            if (base.len > 0) return base;
        }
        return it.workspace;
    }

    /// Ended with uncommitted work in its cwd.
    pub fn dirtyEnded(it: Item) bool {
        return it.state.ended() and (it.dirty orelse 0) > 0;
    }
};

/// Every slice of `it` copied onto `arena`.
pub fn dupeItem(arena: Allocator, it: Item) Allocator.Error!Item {
    var out = it;
    out.session_id = try arena.dupe(u8, it.session_id);
    out.workspace = try arena.dupe(u8, it.workspace);
    out.cwd = if (it.cwd) |c| try arena.dupe(u8, c) else null;
    out.model = if (it.model) |m| try arena.dupe(u8, m) else null;
    out.transcript_path = try arena.dupe(u8, it.transcript_path);
    out.last_user_msg = if (it.last_user_msg) |m| try arena.dupe(u8, m) else null;
    out.last_assistant_msg = if (it.last_assistant_msg) |m| try arena.dupe(u8, m) else null;
    out.current_tool = if (it.current_tool) |c| try arena.dupe(u8, c) else null;
    out.git_branch = if (it.git_branch) |b| try arena.dupe(u8, b) else null;
    if (it.cloud) |c| out.cloud = .{
        .ticket = try arena.dupe(u8, c.ticket),
        .flow = try arena.dupe(u8, c.flow),
        .raw_state = try arena.dupe(u8, c.raw_state),
        .task_arn = if (c.task_arn) |a| try arena.dupe(u8, a) else null,
        .pr_url = if (c.pr_url) |u| try arena.dupe(u8, u) else null,
    };
    return out;
}

/// A bare local Claude row for tests (`transcript_path` `/t`).
pub fn testItem(id: []const u8, state: AgentState, at: i64, ws: []const u8, msg: ?[]const u8) Item {
    return .{ .source = .claude, .session_id = id, .workspace = ws, .cwd = null, .transcript_path = "/t", .state = state, .pid = null, .last_activity_s = at, .last_user_msg = msg, .last_assistant_msg = null };
}

/// What `paintRow` sees: the item and the card's view of it, resolved
/// on the frame arena — the name (against the aliases), the pin,
/// whether its pty pane is the active one, the summary rows and the
/// ticket chip.
pub const RowView = struct {
    item: Item,
    name: []const u8,
    pinned: bool = false,
    active: bool = false,
    /// `exited` alone, the last exchange, or `—`.
    lines: []const []const u8 = &.{},
    kind: Summary = .none,
    ticket: ?[]const u8 = null,
    /// // changed (colors): the accent's palette name — the user's pick
    /// for the session, else its open pane's; null paints the cursor /
    /// active cue.
    color: ?[]const u8 = null,
};

pub const Summary = enum { exited, none, text };

pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    generation: u32,
    /// Wall-clock seconds when the scan ran — the clock `last_activity_s`
    /// is on. `App.now_ms` is the awake clock, so an age or the
    /// hidden-ended rule must not read it (`wallNowS`).
    at_s: i64 = 0,

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
    .@"sessions.move_top" = &moveTopCmd,
    .@"sessions.move_bottom" = &moveBottomCmd,
    .@"sessions.all_workspaces" = &allWorkspacesCmd,
    .@"sessions.pin" = &pinCmd,
    .@"sessions.copy_cwd" = &copyCwdCmd,
    .@"sessions.export" = &exportCmd,
    .@"sessions.kill" = &killCmd,
    .@"sessions.new_menu" = &newMenuCmd,
    // The dashboard's ids keep resolving (corpus scripts name them).
    .@"agents.refresh" = &refreshCmd,
    .@"ai.dashboard.open_transcript" = &openTranscriptCmd,
    .@"ai.dashboard.yank_session_id" = &copyIdCmd,
    .@"ai.dashboard.yank_cwd" = &copyCwdCmd,
    .@"ai.dashboard.export_markdown" = &exportCmd,
    .@"ai.dashboard.kill" = &killCmd,
    .@"ai.dashboard.resume_in_pty" = &openCmd,
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
    /// Pinned session ids, in memory for this launch (as Rust's). Owned.
    pinned: std.ArrayListUnmanaged([]u8) = .empty,
    /// // changed (colors): accent colours by session id (`name` is the
    /// palette name), saved with the session file. Owned.
    colors: std.ArrayListUnmanaged(Alias) = .empty,
    /// // changed (sessions-worktree): the trees mnml made for sessions,
    /// by path, the session id learned from the scan; saved with the
    /// session file (`app/session_worktree.zig`). Owned.
    worktrees: session_worktree.Registry = .{},
    generation: u32 = 0,
    scanning: bool = false,
    scanned_once: bool = false,
    last_scan_ms: i64 = 0,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,
    /// A home directory to scan instead of the loader's `$HOME` —
    /// what a test points at a fixture. Owned.
    home: ?[]u8 = null,
    /// The cloud scanner's settings, duped from the config for the
    /// worker in flight (`refresh` renews them). Owned.
    cloud: ?cloud_agents.Opts = null,
    /// The first adoption has no edges to report.
    adopted_once: bool = false,
    /// The snapshot's wall clock and the awake clock it was adopted at:
    /// `wallNowS` extrapolates the wall clock from the two.
    snapshot_at_s: i64 = 0,
    snapshot_at_ms: i64 = 0,

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
        for (self.pinned.items) |id| gpa.free(id);
        self.pinned.deinit(gpa);
        for (self.colors.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
        }
        self.colors.deinit(gpa);
        self.worktrees.deinit(gpa);
        if (self.home) |h| gpa.free(h);
        if (self.cloud) |*c| c.deinit(gpa);
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

    /// The accent chosen for `id`, a palette name.
    pub fn color(self: *const State, id: []const u8) ?[]const u8 {
        for (self.colors.items) |c| if (std.mem.eql(u8, c.id, id)) return c.name;
        return null;
    }

    /// Set, replace, or (`none` / empty / unknown) drop the colour for `id`.
    pub fn setColor(self: *State, gpa: Allocator, id: []const u8, name: []const u8) Allocator.Error!void {
        const canon = accent_color.canonical(name);
        for (self.colors.items, 0..) |*c, i| if (std.mem.eql(u8, c.id, id)) {
            if (canon == null) {
                const gone = self.colors.orderedRemove(i);
                gpa.free(gone.id);
                gpa.free(gone.name);
                return;
            }
            const fresh = try gpa.dupe(u8, canon.?);
            gpa.free(c.name);
            c.name = fresh;
            return;
        };
        const want = canon orelse return;
        const id_owned = try gpa.dupe(u8, id);
        errdefer gpa.free(id_owned);
        const name_owned = try gpa.dupe(u8, want);
        errdefer gpa.free(name_owned);
        try self.colors.append(gpa, .{ .id = id_owned, .name = name_owned });
    }

    pub fn orderIndex(self: *const State, id: []const u8) ?usize {
        for (self.order.items, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
        return null;
    }

    pub fn isPinned(self: *const State, id: []const u8) bool {
        for (self.pinned.items) |p| if (std.mem.eql(u8, p, id)) return true;
        return false;
    }

    /// Pin, or unpin; the new state.
    pub fn togglePin(self: *State, gpa: Allocator, id: []const u8) Allocator.Error!bool {
        for (self.pinned.items, 0..) |p, i| if (std.mem.eql(u8, p, id)) {
            gpa.free(self.pinned.orderedRemove(i));
            return false;
        };
        const owned = try gpa.dupe(u8, id);
        errdefer gpa.free(owned);
        try self.pinned.append(gpa, owned);
        return true;
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
    const home = try homeFor(app) orelse {
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
    // The cloud settings the worker reads, renewed while no worker runs.
    if (st.cloud) |*c| c.deinit(app.gpa);
    st.cloud = try cloud_agents.Opts.fromConfig(app.gpa, &app.cfg.cloud_agents, &app.env);
    st.group.concurrent(app.io, scanWorker, .{ &app.events, app.io, app.gpa, home, app.workspace, st.cloud, st.generation }) catch |err| {
        st.scanning = false;
        return app.diag.fail(app.frame.allocator(), "sessions: could not start the scan: {s}", .{@errorName(err)});
    };
}

/// `$HOME` as the config loader saw it, else as the children see it (a
/// `.test` file's `# env:` lines land there; the runner loads no file).
pub fn envHome(app: *const App) ?[]const u8 {
    return app.homeDir() orelse app.env.get("HOME");
}

/// The test override, else `$HOME`. A relative HOME — a `.test` file's
/// `# env: HOME=home` — is under the workspace, and is kept as the
/// override so the worker's slice outlives the frame.
fn homeFor(app: *App) Allocator.Error!?[]const u8 {
    const st = &app.sessions;
    if (st.home) |h| return h;
    const h = envHome(app) orelse return null;
    if (std.fs.path.isAbsolute(h)) return h;
    st.home = try std.fs.path.join(app.gpa, &.{ app.workspace, h });
    return st.home.?;
}

fn scanWorker(events: *event.EventQueue, io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, cloud: ?cloud_agents.Opts, generation: u32) Io.Cancelable!void {
    const result = ScanResult.create(gpa, generation) catch {
        postErr(events, io, gpa, "out of memory starting the scan");
        return;
    };
    errdefer result.destroy(gpa);
    scanInto(io, gpa, home, workspace, cloud, result) catch |err| switch (err) {
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

/// The three scanners into `r.items` on `r.arena`: the local
/// transcripts, the cloud runs when configured, then one `git status`
/// per distinct cwd. Every session is kept; `refilter` narrows to the
/// workspace, so the toggle needs no rescan.
pub fn scanInto(io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, cloud: ?cloud_agents.Opts, r: *ScanResult) ScanError!void {
    _ = workspace;
    const arena = r.arena.allocator();
    var rows: std.ArrayListUnmanaged(Item) = .empty;
    try agents.scanInto(io, gpa, arena, home, &rows);
    if (cloud) |c| try cloud_agents.scanInto(io, gpa, arena, c, &rows);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    try agents.dirtyScan(io, gpa, arena, rows.items, now);
    r.items = rows.items;
    r.at_s = now;
}

// ─── the event handler (D1) ─────────────────────────────────────────────

pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    const st = &app.sessions;
    defer result.destroy(app.gpa);
    if (result.generation != st.generation) return;
    st.scanning = false;
    const frame = app.frame.allocator();
    const keep: ?[]const u8 = if (st.selected()) |it| try frame.dupe(u8, it.session_id) else null;
    try sessions_table.noteSelection(app);
    // The edges: what each session was, before the old snapshot goes.
    const edges = try stateEdges(frame, st.items, result.items);
    st.snapshot.reset();
    st.items = &.{};
    st.snapshot_at_s = result.at_s;
    st.snapshot_at_ms = app.now_ms;
    const arena = st.snapshot.allocator();
    const items = try arena.alloc(Item, result.items.len);
    for (result.items, 0..) |it, i| items[i] = try dupeItem(arena, it);
    st.items = items;
    try refilter(app);
    // The selection follows its session across a rescan.
    if (keep) |sid| for (st.filtered.items, 0..) |idx, vi| if (std.mem.eql(u8, st.items[idx].session_id, sid)) {
        st.list.cursor = vi;
        break;
    };
    if (st.adopted_once) try announceEdges(app, edges);
    st.adopted_once = true;
    try sessions_table.onSnapshot(app);
    app.needs_render = true;
}

pub const Edge = struct { session_id: []const u8, from: AgentState, to: AgentState };

/// The sessions whose state changed between two listings (a session
/// new to the listing is no edge). Slices borrow `new`.
pub fn stateEdges(arena: Allocator, old: []const Item, new: []const Item) Allocator.Error![]Edge {
    var out: std.ArrayListUnmanaged(Edge) = .empty;
    for (new) |n| for (old) |o| if (std.mem.eql(u8, o.session_id, n.session_id)) {
        if (o.state != n.state) try out.append(arena, .{ .session_id = n.session_id, .from = o.state, .to = n.state });
        break;
    };
    return out.items;
}

/// Once per edge: a session that starts `waiting` toasts (warn), badges
/// its pty tab and rings the bell under `ui.session_bell`; one that
/// `failed` toasts (err). The other edges are quiet — the rows show them.
fn announceEdges(app: *App, edges: []const Edge) Allocator.Error!void {
    for (edges) |e| {
        const it = findItem(app, e.session_id) orelse continue;
        switch (e.to) {
            .waiting => {
                try app.toastLevel(.warn, "session needs input: {s}", .{displayName(app, it)});
                if (ptyPaneOf(app, e.session_id)) |id| if (app.panes.get(id)) |pane| if (pane.* == .pty) {
                    pane.pty.attention = true;
                };
                if (app.cfg.ui.session_bell) app.bell_pending = true;
            },
            .failed => try app.toastLevel(.err, "session failed: {s}", .{displayName(app, it)}),
            else => {},
        }
    }
}

/// Wall-clock seconds now, the clock `Item.last_activity_s` is on: the
/// snapshot's, moved on by the awake clock since. `App.now_ms` alone is
/// the awake clock — seconds since boot — and reads every session as
/// `now` (// changed: the table's age column and hidden-ended rule
/// compared the two clocks and hid nothing).
pub fn wallNowS(app: *App) i64 {
    const st = &app.sessions;
    return st.snapshot_at_s + @divFloor(app.now_ms - st.snapshot_at_ms, 1000);
}

pub fn findItem(app: *App, session_id: []const u8) ?Item {
    for (app.sessions.items) |it| if (std.mem.eql(u8, it.session_id, session_id)) return it;
    return null;
}

/// State order: the state's own rank (waiting first, then live, tool,
/// idle, failed, done); newest within a rank.
fn rank(it: Item) u8 {
    return it.state.rank();
}

/// Workspace, state filter and the `/` text narrow; then pinned
/// sessions lead, and the axis orders: State, or the manual list (ids
/// not on it follow, newest first).
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
            const pa = ctx.st.isPinned(ia.session_id);
            const pb = ctx.st.isPinned(ib.session_id);
            if (pa != pb) return pa;
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
        todos.containsIgnoreCase(it.source.label(), q) or todos.containsIgnoreCase(it.state.label(), q) or
        todos.containsIgnoreCase(it.where.label(), q);
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

/// Whether a view of the rows is on screen and wants the cadence: the
/// section shown with auto-refresh on, or a table pane not paused.
pub fn wantsScan(app: *const App) bool {
    if (side.isShown(app, .sessions) and auto_refresh.on(app, .sessions)) return true;
    return sessions_table.wantsScan(app);
}

/// Every tick: a shown view rescans on the cadence.
pub fn tick(app: *App, now: i64) void {
    const st = &app.sessions;
    if (st.scanning or !st.scanned_once or !wantsScan(app)) return;
    if (now - st.last_scan_ms < refresh_ms) return;
    refresh(app) catch {};
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.sessions;
    if (!st.scanned_once or !wantsScan(app)) return null;
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

/// `f`: the state filter cycles every → waiting → live → tool → idle
/// → failed → done → every. The table has its own filter.
fn cycleStateCmd(app: *App) CommandError!void {
    if (sessions_table.focused(app)) |tp| return sessions_table.cycleState(app, tp);
    const st = &app.sessions;
    st.state_filter = AgentState.next(st.state_filter);
    try refilter(app);
    app.needs_render = true;
}

/// The row a session command acts on: the table's cursor when the
/// table pane has the keys, else the section's.
pub fn current(app: *App) ?Item {
    if (sessions_table.focused(app)) |tp| return tp.selectedItem(app);
    return app.sessions.selected();
}

fn currentOrFail(app: *App) CommandError!Item {
    return current(app) orelse app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
}

/// `w`: this workspace's sessions, or every workspace's.
fn allWorkspacesCmd(app: *App) CommandError!void {
    app.sessions.all_workspaces = !app.sessions.all_workspaces;
    try refilter(app);
    app.needs_render = true;
    app.toast("sessions: {s}", .{if (app.sessions.all_workspaces) "every workspace" else "this workspace"});
}

/// `p` / the menu's first row: pin or unpin the selected session;
/// pinned sessions lead the list on either axis. In memory, as Rust's.
fn pinCmd(app: *App) CommandError!void {
    const st = &app.sessions;
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    const id = try arena.dupe(u8, it.session_id);
    const pinned = try st.togglePin(app.gpa, id);
    try refilter(app);
    for (st.filtered.items, 0..) |idx, vi| if (std.mem.eql(u8, st.items[idx].session_id, id)) {
        st.list.cursor = vi;
        break;
    };
    try sessions_table.onSnapshot(app);
    app.needs_render = true;
    app.toast("{s} {s}", .{ if (pinned) "pinned" else "unpinned", displayName(app, it) });
}

/// The `+ New session` row (Enter, a click) and `sessions.new_menu`:
/// the choices — a local session, a batch of them, a cloud run — as a
/// menu under the row.
/// // changed (sessions-merge): was `ai.claude_code_new` outright; the
/// cloud wizards are choices here now.
fn newCmd(app: *App) CommandError!void {
    const at = newRowAnchor(app);
    return openNewMenu(app, at.x, at.y);
}

fn newMenuCmd(app: *App) CommandError!void {
    return newCmd(app);
}

/// Where the New row painted last frame, else the top-left.
fn newRowAnchor(app: *App) struct { x: u16, y: u16 } {
    for (app.hits.items.items) |h| switch (h.target) {
        .chip => |c| if (c.panel == .sessions and c.kind == .new) return .{ .x = h.rect.x, .y = h.rect.y + 1 },
        .script_hit => |sh| if (sh.id == hit.ListHit.chip(.new)) {
            if (app.panes.get(sh.pane)) |p| if (p.* == .sessions_table) return .{ .x = h.rect.x, .y = h.rect.y + 1 };
        },
        else => {},
    };
    return .{ .x = 0, .y = 1 };
}

/// Enter / double-click / the menu's Resume row: resume the session in
/// a pty pane to the right, in its own cwd. A cloud row opens its run.
fn openCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    if (it.where == .cloud) return cloud_agents.openRun(app, it);
    const argv: []const []const u8 = switch (it.source) {
        .claude => try cli.claudeResumeArgv(arena, try arena.dupe(u8, it.session_id)),
        .codex => &.{cli.codex_binary},
    };
    const cwd: ?[]const u8 = if (it.cwd) |c| try arena.dupe(u8, c) else null;
    // The session's chosen colour follows it into the pane.
    _ = try pty_pane.open(app, .{ .argv = argv, .cwd = cwd, .label = it.source.label(), .placement = .right, .kind = .command, .accent_color = app.sessions.color(it.session_id) });
}

// ─── the accent (colors) ────────────────────────────────────────────────

/// The palette name a session's surfaces paint: the user's pick for the
/// id first, else its open pane's accent (a new session's auto slot);
/// null when neither.
pub fn colorNameOf(app: *App, sid: []const u8) ?[]const u8 {
    if (app.sessions.color(sid)) |c| return c;
    const pid = ptyPaneOf(app, sid) orelse return null;
    const p = app.panes.pty(pid) orelse return null;
    return p.accent_color;
}

/// The `Color: …` rows of a session's menu (Rust's
/// `session_color_menu_items_with_active`): one per palette entry in
/// the palette's order, then `Color: Auto`, the current one checked.
/// On `arena` — the menu's own.
pub fn colorMenuRows(arena: Allocator, target: command.SessionColorAct, active: ?[]const u8) Allocator.Error![]command.MenuItem {
    const rows = try arena.alloc(command.MenuItem, accent_color.palette.len + 1);
    for (accent_color.palette, 0..) |name, i| rows[i] = .{
        .label = accent_color.label(name),
        .action = .{ .session_color = .{ .target = target.target, .name = name } },
        .checked = if (active) |c| std.mem.eql(u8, c, name) else false,
    };
    rows[accent_color.palette.len] = .{
        .label = accent_color.label(accent_color.none),
        .action = .{ .session_color = .{ .target = target.target, .name = accent_color.none } },
        .checked = active == null,
        .separator_before = true,
    };
    return rows;
}

/// A `Color: …` row was chosen: the SESSIONS row under the cursor keeps
/// the colour by its id and its open pane takes it; a pane takes it,
/// and its session id keeps it when the command names one.
pub fn setColorAction(app: *App, a: command.SessionColorAct) Allocator.Error!void {
    switch (a.target) {
        .row => {
            const it = current(app) orelse return;
            try app.sessions.setColor(app.gpa, it.session_id, a.name);
            if (ptyPaneOf(app, it.session_id)) |pid| try pty_pane.setAccent(app, pid, a.name);
        },
        .pane => |pid| {
            try pty_pane.setAccent(app, pid, a.name);
            const p = app.panes.pty(pid) orelse return;
            for (app.sessions.items) |it| for (p.argv) |arg| if (std.mem.eql(u8, arg, it.session_id)) {
                try app.sessions.setColor(app.gpa, it.session_id, a.name);
            };
        },
    }
    app.needs_render = true;
}

/// The transcript itself, in an editor.
fn openTranscriptCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    if (it.where == .cloud) return cloud_agents.tailLog(app, it);
    const path = try arena.dupe(u8, it.transcript_path);
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open transcript: {s}", .{@errorName(err)}),
    };
}

/// A prompt seeded with the current name; empty resets to the default.
fn renameCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    const id = try app.gpa.dupe(u8, it.session_id);
    errdefer app.gpa.free(id);
    const seed = try app.frame.allocator().dupe(u8, app.sessions.alias(it.session_id) orelse "");
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
    try sessions_table.onSnapshot(app);
    app.needs_render = true;
}

fn copyIdCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    const text = try arena.dupe(u8, it.session_id);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// `c`: the session's working directory to the clipboard.
fn copyCwdCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    const cwd = it.cwd orelse return app.diag.fail(arena, "sessions: the session has no cwd", .{});
    const text = try arena.dupe(u8, cwd);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// `e`: the transcript as markdown under `.mnml/claude-exports/`,
/// opened in an editor.
fn exportCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    if (it.where == .cloud) return app.diag.fail(app.frame.allocator(), "sessions: a cloud run has no transcript to export — tail its log", .{});
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, it.transcript_path, gpa, .limited(64 * 1024 * 1024)) catch |err| return app.diag.fail(arena, "read {s}: {s}", .{ it.transcript_path, @errorName(err) });
    defer gpa.free(text);
    const md = try agents.transcriptMarkdown(arena, it, text);
    const dir = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", "claude-exports" });
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    const short = it.session_id[0..@min(8, it.session_id.len)];
    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{d}.md", .{ dir, short, app.now_ms });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = md }) catch |err| return app.diag.fail(arena, "write {s}: {s}", .{ path, @errorName(err) });
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    app.toast("exported {s}", .{app.relPath(path)});
}

/// `K`: SIGTERM the current session — or, from the table, every ticked
/// one — after a confirm. A cloud row cancels its run instead.
fn killCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    var pids: std.ArrayListUnmanaged(u32) = .empty;
    if (sessions_table.focused(app)) |tp| {
        if (tp.multi.count() > 0) {
            for (app.sessions.items) |r| if (r.pid) |pid| if (tp.multi.contains(r.session_id)) try pids.append(arena, pid);
        }
    }
    if (pids.items.len == 0) {
        const it = try currentOrFail(app);
        if (it.where == .cloud) return cloud_agents.cancelRun(app, it);
        if (it.pid) |pid| try pids.append(arena, pid);
    }
    if (pids.items.len == 0) return app.diag.fail(arena, "sessions: nothing to kill (no live process)", .{});
    const owned = try app.gpa.dupe(u32, pids.items);
    errdefer app.gpa.free(owned);
    const msg = try std.fmt.allocPrint(app.gpa, "  SIGTERM {d} session{s}?", .{ owned.len, if (owned.len == 1) "" else "s" });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Kill sessions", .message = msg, .choices = &kill_choices },
        .purpose = .{ .kill_pids = owned },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const kill_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'k', .label = "Kill" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm's yes: `kill -TERM` each pid, the ticks cleared, a rescan.
pub fn killAccept(app: *App, pids: []const u32) Allocator.Error!void {
    var n: usize = 0;
    for (pids) |pid| {
        const arg = try std.fmt.allocPrint(app.frame.allocator(), "{d}", .{pid});
        const result = std.process.run(app.gpa, app.io, .{ .argv = &.{ "kill", "-TERM", arg } }) catch continue;
        app.gpa.free(result.stdout);
        app.gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) n += 1;
    }
    app.toast("sent SIGTERM to {d} of {d}", .{ n, pids.len });
    sessions_table.clearAllMulti(app);
    refresh(app) catch {};
}

/// Delete the transcript after a confirm. A live session is refused:
/// its process would keep writing to a file that is gone.
fn deleteCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    if (it.where == .cloud) return app.diag.fail(arena, "sessions: a cloud run has no transcript here — cancel it instead", .{});
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
    try adoptManualAxis(app);
    try refilter(app);
    st.list.cursor = @intCast(target);
    app.needs_render = true;
}

/// The row menu's Move to top / Move to bottom (Rust's
/// `SessionMoveToTop` / `SessionMoveToBottom`): the selected row leads,
/// or ends, the manual order — pins still lead the list.
fn moveTopCmd(app: *App) CommandError!void {
    return moveTo(app, .top);
}

fn moveBottomCmd(app: *App) CommandError!void {
    return moveTo(app, .bottom);
}

fn moveTo(app: *App, end: enum { top, bottom }) CommandError!void {
    const st = &app.sessions;
    if (st.filtered.items.len == 0) return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    try adoptVisibleOrder(app);
    const id = st.items[st.filtered.items[st.list.cursor]].session_id;
    const owned = st.order.orderedRemove(st.orderIndex(id).?);
    errdefer app.gpa.free(owned);
    switch (end) {
        .top => try st.order.insert(app.gpa, 0, owned),
        .bottom => try st.order.append(app.gpa, owned),
    }
    try adoptManualAxis(app);
    try refilter(app);
    for (st.filtered.items, 0..) |idx, vi| if (std.mem.eql(u8, st.items[idx].session_id, owned)) {
        st.list.cursor = vi;
        break;
    };
    app.needs_render = true;
}

/// A move lands on the manual axis; the switch persists like the chip's.
fn adoptManualAxis(app: *App) Allocator.Error!void {
    const st = &app.sessions;
    if (st.sort == .manual) return;
    st.sort = .manual;
    app.cfg.ui.sessions_sort = .manual;
    _ = try settings.persist(app, .workspace, &.{ "ui", "sessions_sort" }, SessionsSort.manual);
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
        .new_activate => {
            runToast(app, newCmd(app));
            return true;
        },
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
                'p' => runToast(app, pinCmd(app)),
                'f' => runToast(app, cycleStateCmd(app)),
                'w' => runToast(app, allWorkspacesCmd(app)),
                'o' => runToast(app, openTranscriptCmd(app)),
                'R' => runToast(app, renameCmd(app)),
                'y' => runToast(app, copyIdCmd(app)),
                'c' => runToast(app, copyCwdCmd(app)),
                'e' => runToast(app, exportCmd(app)),
                'S' => runToast(app, killCmd(app)),
                't' => runToast(app, sessions_table.openCmd(app)),
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
        else => {},
    }
}

/// The wheel over the list: `rows` rows (the batch, budgeted and
/// clamped by `dispatch.panelWheel`); the window follows the cursor.
pub fn wheel(app: *App, down: bool, rows: usize) void {
    const st = &app.sessions;
    const total = st.filtered.items.len;
    st.list.cursor = if (down) @min(st.list.cursor + rows, total -| 1) else st.list.cursor -| rows;
    app.needs_render = true;
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
        .new => try openNewMenu(app, m.x, m.y + 1),
        .view => runToast(app, sessions_table.openCmd(app)),
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
        else => {},
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .sessions };
    app.needs_render = true;
}

/// Rust's row menu leads with Pin, Move up / down / to top / to bottom,
/// the Auto sort tick, Rename…; the transcript rows are this module's.
/// The section's and the table's rows share it (`sessions_table` calls
/// it with `.table`; the table has no manual order, so no move rows).
/// A cloud row is titled by its run (Rust's `workspace · runId`) and
/// offers the run's links: CloudWatch when the account, region and log
/// group are configured, the PR when the record names one.
/// // right-click (#11, #15): the to-top / to-bottom / Auto sort rows
/// and the two links. Rust's colour rows tint a pty pane's card; these
/// rows are transcripts with no colour model, so there are none.
pub fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    return openRowMenuFor(app, .section, x, y);
}

pub const MenuHost = enum { section, table };

pub fn openRowMenuFor(app: *App, host: MenuHost, x: u16, y: u16) Allocator.Error!void {
    const it = current(app);
    const pinned = if (it) |i| app.sessions.isPinned(i.session_id) else false;
    const cloud = if (it) |i| i.where == .cloud else false;
    const live = if (it) |i| i.pid != null else false;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    try items.append(app.gpa, .{ .label = if (pinned) "Unpin" else "Pin", .action = .{ .command = .@"sessions.pin" } });
    if (host == .section) {
        try items.append(app.gpa, .{ .label = "Move up", .action = .{ .command = .@"sessions.move_up" } });
        try items.append(app.gpa, .{ .label = "Move down", .action = .{ .command = .@"sessions.move_down" } });
        try items.append(app.gpa, .{ .label = "Move to top", .action = .{ .command = .@"sessions.move_top" } });
        try items.append(app.gpa, .{ .label = "Move to bottom", .action = .{ .command = .@"sessions.move_bottom" } });
        try items.append(app.gpa, .{ .label = "Auto sort", .action = .{ .command = .@"sessions.sort_auto" }, .checked = app.sessions.sort == .auto });
    }
    try items.append(app.gpa, .{ .label = "Rename…", .action = .{ .command = .@"sessions.rename" } });
    // colors: the accent, as Rust's rail row menu offers it.
    if (it) |i| if (i.where != .cloud) try items.append(app.gpa, .{
        .label = "Color",
        .action = .none,
        .submenu = try colorMenuRows(arena, .{ .target = .row, .name = accent_color.none }, colorNameOf(app, i.session_id)),
    });
    var title: []const u8 = "Session";
    if (cloud) {
        const i = it.?;
        title = try std.fmt.allocPrint(arena, "{s} · {s}", .{ i.workspace, i.session_id });
        try items.append(app.gpa, .{ .label = "Open run", .action = .{ .command = .@"sessions.cloud_open" }, .separator_before = true });
        try items.append(app.gpa, .{ .label = "Tail log", .action = .{ .command = .@"sessions.cloud_tail" } });
        try items.append(app.gpa, .{ .label = "Copy run id", .action = .{ .command = .@"sessions.copy_id" } });
        const cfg = &app.cfg.cloud_agents;
        if (try cloud_agents.cloudwatchUrl(arena, cloud_agents.regionOf(cfg, &app.env), cfg.account_id, cfg.log_group, i.session_id)) |url| {
            try items.append(app.gpa, .{ .label = "Open CloudWatch in browser", .action = .{ .open_url = url }, .separator_before = true });
        }
        if (i.cloud) |c| if (c.pr_url) |pr| {
            try items.append(app.gpa, .{ .label = "Open PR", .action = .{ .open_url = try arena.dupe(u8, pr) } });
        };
        try items.append(app.gpa, .{ .label = "Cancel run…", .action = .{ .command = .@"sessions.cloud_cancel" }, .separator_before = true });
    } else {
        try items.append(app.gpa, .{ .label = "Resume in a terminal", .action = .{ .command = .@"sessions.open" }, .separator_before = true });
        try items.append(app.gpa, .{ .label = "Open transcript", .action = .{ .command = .@"sessions.open_transcript" } });
        try items.append(app.gpa, .{ .label = "Copy session id", .action = .{ .command = .@"sessions.copy_id" } });
        try items.append(app.gpa, .{ .label = "Copy working directory", .action = .{ .command = .@"sessions.copy_cwd" } });
        try items.append(app.gpa, .{ .label = "Export as markdown…", .action = .{ .command = .@"sessions.export" } });
        if (live) try items.append(app.gpa, .{ .label = "Kill session…", .action = .{ .command = .@"sessions.kill" }, .separator_before = true });
        try items.append(app.gpa, .{ .label = "Delete transcript…", .action = .{ .command = .@"sessions.delete" }, .separator_before = !live });
    }
    if (host == .section) try items.append(app.gpa, .{ .label = "Open as a table", .action = .{ .command = .@"sessions.table" }, .separator_before = true });
    const owned = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(title, owned, x, y);
    app.overlay.menu.mem = mem;
}

/// The `+ New session` menu: a local session, a batch (Rust's ×2 / ×4
/// / ×8), and — the cloud wizards' new home — a cloud run by ticket or
/// through the wizard. The cloud rows say when the API is not
/// configured rather than hide.
pub fn openNewMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const cloud_ok = cloud_agents.configured(&app.cfg.cloud_agents, &app.env);
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "New local session", .action = .{ .command = .@"ai.claude_code_new" } },
        .{ .label = "New session in a worktree…", .action = .{ .command = .@"ai.new_session_worktree" } },
        .{ .label = "Open ×2", .action = .{ .command = .@"ai.claude_code_new_x2" } },
        .{ .label = "Open ×4", .action = .{ .command = .@"ai.claude_code_new_x4" } },
        .{ .label = "Open ×8", .action = .{ .command = .@"ai.claude_code_new_x8" } },
        .{ .label = if (cloud_ok) "New cloud run…" else "New cloud run… (not configured)", .action = .{ .command = .@"cloud_agents.new_run" }, .separator_before = true },
        .{ .label = if (cloud_ok) "New cloud run (wizard)…" else "New cloud run (wizard)… (not configured)", .action = .{ .command = .@"cloud_agents.new_run_wizard" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("New session", items, x, y);
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

/// Rust's card: four rows and a blank one (`sessions_panel.rs`, `TAB_H`).
pub const card_h: u16 = 4;
pub const card_gap: u16 = 1;
pub const new_label = "+ New session";
/// The menu's first row — what Rust's chip runs outright.
pub const new_command: command.CommandId = .@"ai.claude_code_new";

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.sessions;
    if (!st.scanned_once and !st.scanning) refresh(app) catch {};
    const rows = try ui.arena.alloc(RowView, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = try rowView(app, ui.arena, st.items[idx]);
    var in_ws: usize = 0;
    const ws_name = std.fs.path.basename(app.workspace);
    for (st.items) |it| if (st.all_workspaces or inWorkspace(it, app.workspace, ws_name)) {
        in_ws += 1;
    };
    const narrowed = st.list.filterText().len > 0 or st.state_filter != null;
    const subtitle = if (!narrowed)
        ui.fmt(" ({d})", .{in_ws})
    else if (st.state_filter) |s|
        ui.fmt(" ({d} of {d} · {s})", .{ rows.len, in_ws, s.label() })
    else
        ui.fmt(" ({d} of {d})", .{ rows.len, in_ws });
    const no_home = st.home == null and envHome(app) == null;
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
        .new_label = new_label,
        .row_h = card_h,
        .row_gap = card_gap,
        .own_marker = true,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    if (st.scanning) list_panel.paintSpinner(ui, area, "SESSIONS", app.now_ms);
}

/// The card's view of an item, on the frame arena. The summary rows are
/// Rust's `session_lines_for_card` at rest: `exited` alone for an ended
/// session, else the transcript's last exchange, else `—`.
pub fn rowView(app: *App, arena: Allocator, it: Item) Allocator.Error!RowView {
    const name = displayName(app, it);
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var kind: Summary = .text;
    if (it.state.ended()) {
        kind = .exited;
        try lines.append(arena, if (it.state == .failed) "failed" else "exited");
    } else {
        if (it.last_user_msg) |m| if (try collapseWs(arena, m)) |c| try lines.append(arena, try std.fmt.allocPrint(arena, "you: {s}", .{c}));
        if (it.last_assistant_msg) |m| if (try collapseWs(arena, m)) |c| try lines.append(arena, try std.fmt.allocPrint(arena, "claude: {s}", .{c}));
        if (lines.items.len == 0) {
            kind = .none;
            try lines.append(arena, "—");
        }
    }
    const aliased = app.sessions.alias(it.session_id) != null;
    return .{
        .item = it,
        .name = name,
        .pinned = app.sessions.isPinned(it.session_id),
        .active = isActive(app, it.session_id),
        .lines = lines.items,
        .kind = kind,
        .ticket = if (aliased) null else detectTicket(app.cfg.ui.ticket_prefixes, &.{name}),
        .color = colorNameOf(app, it.session_id),
    };
}

/// Newlines and runs of whitespace collapsed to one space, as Rust keeps
/// a row readable in a narrow card; null when nothing is left.
fn collapseWs(arena: Allocator, s: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, w);
    }
    return if (out.items.len == 0) null else out.items;
}

/// The session's resumed pty pane is the active pane: its argv names the id.
fn isActive(app: *App, sid: []const u8) bool {
    const a = app.active orelse return false;
    return ptyPaneOf(app, sid) == a;
}

/// The pty pane hosting this session — its argv names the id.
pub fn ptyPaneOf(app: *App, sid: []const u8) ?app_mod.PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| for (p.argv) |arg| {
            if (std.mem.eql(u8, arg, sid)) return @intCast(i);
        },
        else => {},
    };
    return null;
}

/// Rust's `detect_ticket`: the first `<prefix><digits>` in `candidates`
/// for the configured `[ui] ticket_prefixes`, the prefix matched without
/// case; null when there are no prefixes.
pub fn detectTicket(prefixes: []const []const u8, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |cand| {
        if (cand.len == 0) continue;
        for (prefixes) |p| {
            if (p.len == 0) continue;
            var from: usize = 0;
            while (std.ascii.indexOfIgnoreCasePos(cand, from, p)) |start| {
                const after = start + p.len;
                var end = after;
                while (end < cand.len and std.ascii.isDigit(cand[end])) : (end += 1) {}
                if (end > after) return cand[start..end];
                from = after;
            }
        }
    }
    return null;
}

/// Rust's card, cell for cell (`sessions_panel.rs`): the accent `▌` down
/// `x + 1` — the session's chosen colour first (`RowView.color`), else
/// cyan on the cursor's card while the panel has focus, green on the
/// card whose pty pane is the active one, else the ground — then at `x + 3`
/// the name after a pin `󰐃 ` (bold when active, clipped hard at the
/// edge), and up to three summary rows clipped to `width − 6` with `…`,
/// the first with ` · TICKET` when one was detected. No bell, no ports.
fn paintRow(ui: Ui, r: Rect, row: RowView, selected: bool) void {
    const t = ui.theme;
    const bg = t.panel_bg;
    if (r.w < 3 or r.h == 0) return;
    const focused = ui.isFocused(.{ .panel = .sessions });
    const chosen: ?vaxis.Color = if (row.color) |c| accent_color.resolve(c, t) else null;
    const accent = chosen orelse if (selected and focused) t.palette.cyan else if (row.active) t.palette.green else bg.bg;
    const bar = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
    var y: u16 = 0;
    while (y < r.h) : (y += 1) _ = ui.putStr(r.x + 1, r.y + y, 1, bar, Theme.withFg(bg, accent));
    const end = r.right();
    var x = r.x + 2;
    x += ui.putStr(x, r.y, end -| x, " ", bg);
    if (row.pinned) x += ui.putStr(x, r.y, end -| x, if (ui.ascii) "📌 " else "\u{F0403} ", Theme.withFg(bg, t.palette.orange));
    var name_style = Theme.withFg(bg, t.fg.fg);
    name_style.bold = row.active;
    _ = ui.putStr(x, r.y, end -| x, row.name, name_style);
    const max_cells: u16 = @max(4, r.w -| 6);
    const color = switch (row.kind) {
        .exited => t.palette.red,
        .none => t.palette.grey,
        .text => t.muted.fg,
    };
    for (row.lines, 0..) |line, i| {
        if (i >= 3 or i + 1 >= r.h) break;
        const yy = r.y + 1 + @as(u16, @intCast(i));
        var xx = r.x + 2;
        xx += ui.putStr(xx, yy, end -| xx, " ", bg);
        xx += ui.putStr(xx, yy, end -| xx, ui.clipStr(line, max_cells), Theme.withFg(bg, color));
        if (i == 0) if (row.ticket) |tk| {
            xx += ui.putStr(xx, yy, end -| xx, " · ", Theme.withFg(bg, t.muted.fg));
            _ = ui.putStr(xx, yy, end -| xx, tk, Theme.withFg(bg, t.palette.cyan));
        };
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

const item = testItem;

test "refilter: this workspace only unless toggled; State ranks waiting, live, tool, idle, ended; Manual follows the order list then recency" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const st = &f.app.sessions;
    const ws = std.fs.path.basename(f.root);
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 5);
    items[0] = item("idle-old", .idle, 10, ws, "fix the tests");
    items[1] = item("ended", .done, 50, ws, null);
    items[2] = item("live", .streaming, 20, ws, "ship it");
    items[3] = item("elsewhere", .streaming, 99, "other", null);
    items[4] = item("waiting", .waiting, 30, ws, "approve?");
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
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    st.state_filter = .waiting;
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
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
    try scanInto(testing.io, testing.allocator, f.app.sessions.home.?, f.root, null, r);
    try testing.expectEqual(@as(usize, 2), r.items.len);
    var claude_seen = false;
    for (r.items) |it| if (it.source == .claude) {
        claude_seen = true;
        try testing.expectEqualStrings("aaaaaaaa-0000-4000-8000-000000000001", it.session_id);
        try testing.expectEqualStrings("mnml", it.workspace);
        try testing.expect(std.mem.endsWith(u8, it.transcript_path, ".jsonl"));
        try testing.expectEqual(AgentState.done, it.state);
        try testing.expectEqualStrings("/Users/me/Projects/mnml", it.groupKey());
        try testing.expectEqualStrings("mnml", it.groupLabel());
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
    // The ended Claude fixture is a card: its prompt as the name, `exited` under it.
    try testing.expect(std.mem.indexOf(u8, txt2, "fix the build") != null);
    try testing.expect(std.mem.indexOf(u8, txt2, "exited") != null);
    try testing.expect(std.mem.indexOf(u8, txt2, "+ New session") != null);
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
    try testing.expectEqual(@as(usize, 15), f.app.overlay.menu.items.len);
    // colors: every row is a command but the Color parent, whose nine
    // children each name a palette entry (or the sentinel) that resolves.
    var color_rows: usize = 0;
    for (f.app.overlay.menu.items) |it| {
        if (it.submenu.len > 0) {
            try testing.expectEqualStrings("Color", it.label);
            try testing.expectEqual(accent_color.palette.len + 1, it.submenu.len);
            for (it.submenu, 0..) |row, i| {
                try testing.expect(row.action == .session_color);
                try testing.expect(row.action.session_color.target == .row);
                if (i < accent_color.palette.len) {
                    try testing.expectEqualStrings(accent_color.palette[i], row.action.session_color.name);
                    try testing.expect(accent_color.resolve(row.action.session_color.name, &f.app.theme) != null);
                } else {
                    try testing.expectEqualStrings(accent_color.none, row.action.session_color.name);
                    try testing.expect(row.checked);
                }
                try testing.expectEqualStrings(accent_color.label(row.action.session_color.name), row.label);
            }
            color_rows += 1;
        } else try testing.expect(it.action == .command);
    }
    try testing.expectEqual(@as(usize, 1), color_rows);
    try testing.expectEqualStrings("Open as a table", f.app.overlay.menu.items[14].label);
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

// ─── the card against the spec ──────────────────────────────────────────

const UiFixture = @import("ui/test_fixture.zig");
const spec_120x40 = @embedFile("ui_spec_rust_sessions_120x40");

/// Screen row `y` of the Rust dump, the sidebar's 26 cells between the
/// rail's `│` and the divider's, trailing spaces trimmed.
fn specRow(y: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, spec_120x40, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) if (i == y) {
        const bar = "│";
        const first = std.mem.indexOf(u8, line, bar).? + bar.len;
        const second = std.mem.indexOfPos(u8, line, first, bar).?;
        return std.mem.trimEnd(u8, line[first..second], " ");
    };
    unreachable;
}

fn cardProps(rows: []const RowView) Panel.Props {
    return .{
        .panel = .sessions,
        .label = "SESSIONS",
        .subtitle = " (3)",
        .sort_chip = sortLabel(.auto),
        .sort_widest = sort_widest,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = .{ .message = "No sessions yet." },
        .new_label = new_label,
        .row_h = card_h,
        .row_gap = card_gap,
        .own_marker = true,
    };
}

/// The three cards of `rust-sessions-120x40.txt`, as `rowView` builds them.
fn specCards() [3]RowView {
    return .{
        .{ .item = item("5e551011-0000-4000-8000-000000000003", .done, 1, "ws", "write the release notes for 0.3"), .name = "write the release notes for 0.3", .pinned = true, .lines = &.{"exited"}, .kind = .exited },
        .{ .item = item("5e551011-0000-4000-8000-000000000001", .streaming, 3, "ws", "fix the failing tests in src/main.rs"), .name = "fix the failing tests in src/main.rs", .lines = &.{ "you: fix the failing tests in src/main.rs", "claude: Running the suite first to see which ones fail." }, .kind = .text },
        .{ .item = item("5e551011-0000-4000-8000-000000000002", .idle, 2, "ws", "add a --json flag to the CLI"), .name = "release train", .lines = &.{ "you: add a --json flag to the CLI", "claude: Added the flag and a test for it. Anything else?" }, .kind = .text },
    };
}

test "the card at 26 cells is Rust's, cell for cell: rows 3–18 of rust-sessions-120x40.txt, the top block per the user above them" {
    var f = try UiFixture.init(26, 20);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    const rows = specCards();
    _ = Panel.draw(&st, f.ui(), f.full(), cardProps(&rows));
    // The top block: the header, the pill, a blank, the New row, a blank.
    try f.expectRow(1, "  \u{F0349} / filter");
    try f.expectRow(2, "");
    try f.expectRow(3, "  + New session");
    try f.expectRow(4, "");
    // Rust's rows 3–18 land on the same screen rows: the chip row, the
    // blank, the pinned ended card, the live card, the renamed idle card.
    var buf: [256]u8 = undefined;
    var y: u16 = 3;
    while (y <= 18) : (y += 1) try testing.expectEqualStrings(specRow(y), f.row(y, &buf));
    // Hits: the New chip alone on its row, the blanks take none, a card's
    // hit covers its four rows and the gap none.
    try testing.expectEqual(hit.ChipKind.new, f.hits.at(3, 3).?.chip.kind);
    try testing.expect(f.hits.at(5, 2) == null);
    try testing.expect(f.hits.at(5, 4) == null);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 5).?.row.idx);
    try testing.expectEqual(@as(u32, 0), f.hits.at(20, 8).?.row.idx);
    try testing.expect(f.hits.at(5, 9) == null);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 10).?.row.idx);
    try testing.expectEqual(@as(u32, 2), f.hits.at(5, 15).?.row.idx);
    try testing.expectEqual(hit.PanelId.sessions, f.hits.at(10, 1).?.filter_input);
    // The selected card keeps the ground; its accent is the cursor's
    // cyan only while the panel has focus (the fixture focuses a pane).
    try testing.expect(f.bgEql(10, 5, f.theme.panel_bg));
    try testing.expect(vaxis.Color.eql(f.style(1, 5).fg, f.theme.panel_bg.bg));
    try testing.expect(vaxis.Color.eql(f.style(3, 5).fg, f.theme.palette.orange));
    try testing.expect(vaxis.Color.eql(f.style(3, 6).fg, f.theme.palette.red));
    try testing.expect(vaxis.Color.eql(f.style(3, 11).fg, f.theme.muted.fg));
}

test "the card at 30 and 34 cells: the name clips hard at the edge, the summary keeps width − 6 with the ellipsis" {
    const rows = specCards();
    var f = try UiFixture.init(30, 20);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    _ = Panel.draw(&st, f.ui(), f.full(), cardProps(&rows));
    try f.expectRow(5, " \u{258c} \u{F0403} write the release notes f");
    try f.expectRow(10, " \u{258c} fix the failing tests in sr");
    try f.expectRow(11, " \u{258c} you: fix the failing te…");
    try f.expectRow(12, " \u{258c} claude: Running the sui…");
    var g = try UiFixture.init(34, 20);
    defer g.deinit();
    _ = Panel.draw(&st, g.ui(), g.full(), cardProps(&rows));
    try g.expectRow(10, " \u{258c} fix the failing tests in src/ma");
    try g.expectRow(11, " \u{258c} you: fix the failing tests …");
    try g.expectRow(17, " \u{258c} claude: Added the flag and …");
    // Narrow: nothing off-screen, and a card too narrow for a name is bare.
    var h = try UiFixture.init(3, 12);
    defer h.deinit();
    _ = Panel.draw(&st, h.ui(), h.full(), cardProps(&rows));
    for (h.hits.items.items) |e| try testing.expect(h.full().intersect(e.rect).eql(e.rect));
}

test "the summary rows: the last exchange collapsed, exited alone for an ended session, — for none; the ticket chip from ui.ticket_prefixes, hidden by an alias" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const arena = f.app.frame.allocator();
    var live = item("live", .streaming, 1, "ws", "fix  the   tests\r\n");
    live.last_assistant_msg = "On it.\nRunning them now.";
    const v = try rowView(&f.app, arena, live);
    try testing.expectEqual(Summary.text, v.kind);
    try testing.expectEqual(@as(usize, 2), v.lines.len);
    try testing.expectEqualStrings("you: fix the tests", v.lines[0]);
    try testing.expectEqualStrings("claude: On it. Running them now.", v.lines[1]);
    try testing.expectEqualStrings("fix  the   tests", v.name);
    try testing.expect(!v.pinned and !v.active and v.ticket == null);
    const ended = try rowView(&f.app, arena, item("gone", .done, 1, "ws", "anything"));
    try testing.expectEqual(Summary.exited, ended.kind);
    try testing.expectEqualStrings("exited", ended.lines[0]);
    const failed = try rowView(&f.app, arena, item("bad", .failed, 1, "ws", "anything"));
    try testing.expectEqual(Summary.exited, failed.kind);
    try testing.expectEqualStrings("failed", failed.lines[0]);
    const bare = try rowView(&f.app, arena, item("bare", .idle, 1, "ws", "   "));
    try testing.expectEqual(Summary.none, bare.kind);
    try testing.expectEqualStrings("—", bare.lines[0]);
    try testing.expectEqualStrings("bare", bare.name);
    // The ticket: the prefix without case, digits required, the first hit.
    try testing.expect(detectTicket(&.{}, &.{"TE-9"}) == null);
    try testing.expectEqualStrings("ENG-1234", detectTicket(&.{ "TKT-", "TE-" }, &.{"Review ENG-1234 and te-5"}).?);
    try testing.expectEqualStrings("te-5", detectTicket(&.{"TE-"}, &.{ "", "TE-foo te-5" }).?);
    try testing.expect(detectTicket(&.{"TE-"}, &.{"TE-foo"}) == null);
    f.app.cfg.ui.ticket_prefixes = &.{"TE-"};
    const ticketed = try rowView(&f.app, arena, item("t", .idle, 1, "ws", "review TE-77 today"));
    try testing.expectEqualStrings("TE-77", ticketed.ticket.?);
    try f.app.sessions.setAlias(testing.allocator, "t", "the review");
    const aliased = try rowView(&f.app, arena, item("t", .idle, 1, "ws", "review TE-77 today"));
    try testing.expect(aliased.ticket == null);
    try testing.expectEqualStrings("the review", aliased.name);
    try testing.expect(aliased.pinned == false);
    _ = try f.app.sessions.togglePin(testing.allocator, "t");
    try testing.expect((try rowView(&f.app, arena, item("t", .idle, 1, "ws", "x"))).pinned);
}

test "pins lead the list on either axis; p toggles and follows the session; the row menu leads with Pin / Unpin; the New chip's right click is the batch menu" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const st = &f.app.sessions;
    const ws = std.fs.path.basename(f.root);
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 3);
    items[0] = item("live", .streaming, 30, ws, "ship it");
    items[1] = item("idle", .idle, 20, ws, "fix the tests");
    items[2] = item("gone", .done, 10, ws, "notes");
    r.items = items;
    st.generation = 1;
    try handle(&f.app, r);
    st.scanned_once = true; // the panel must not rescan the real home over these
    try testing.expectEqualStrings("live", st.items[st.filtered.items[0]].session_id);
    // p on the ended session pins it to the top and keeps it selected.
    f.app.side.of.set(.sessions, .right);
    f.app.side.right_width = 40;
    try command.run(&f.app, .{ .static = .@"view.activity_sessions" });
    focusPanel(&f.app);
    st.list.cursor = 2;
    try f.app.handle(.{ .key = Key.char('p') });
    try testing.expect(st.isPinned("gone"));
    try testing.expectEqualStrings("gone", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqual(@as(usize, 0), st.list.cursor);
    try testing.expectEqualStrings("live", st.items[st.filtered.items[1]].session_id);
    // On the manual axis too, ahead of the order list.
    try st.order.append(testing.allocator, try testing.allocator.dupe(u8, "idle"));
    try setSort(&f.app, .manual);
    try testing.expectEqualStrings("gone", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqualStrings("idle", st.items[st.filtered.items[1]].session_id);
    try setSort(&f.app, .auto);
    // The card shows the pin; the menu offers Unpin first, Pin on another.
    try f.app.render();
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F0403} notes") != null);
    var row0: ?Rect = null;
    var new_chip: ?Rect = null;
    for (f.app.hits.items.items) |h| switch (h.target) {
        .row => |pr| if (pr.panel == .sessions and pr.idx == 0) {
            row0 = h.rect;
        },
        .chip => |c| if (c.panel == .sessions and c.kind == .new) {
            new_chip = h.rect;
        },
        else => {},
    };
    try testing.expect(row0 != null and new_chip != null);
    try testing.expectEqual(card_h, row0.?.h);
    try f.app.handle(.{ .mouse = .{ .x = row0.?.x + 3, .y = row0.?.y + 2, .kind = .press, .button = .right } });
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqualStrings("Unpin", f.app.overlay.menu.items[0].label);
    try testing.expectEqual(command.CommandId.@"sessions.pin", f.app.overlay.menu.items[0].action.command);
    try testing.expectEqualStrings("Move up", f.app.overlay.menu.items[1].label);
    try testing.expectEqualStrings("Move to bottom", f.app.overlay.menu.items[4].label);
    try testing.expect(f.app.overlay.menu.items[5].checked);
    try testing.expectEqualStrings("Rename…", f.app.overlay.menu.items[6].label);
    // An ended session offers no Kill row; the separator sits on Delete.
    for (f.app.overlay.menu.items) |mi| try testing.expect(!std.mem.eql(u8, mi.label, "Kill session…"));
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(!st.isPinned("gone"));
    try testing.expectEqualStrings("live", st.items[st.filtered.items[0]].session_id);
    try f.app.render();
    try f.app.handle(.{ .mouse = .{ .x = row0.?.x + 3, .y = row0.?.y, .kind = .press, .button = .right } });
    try testing.expectEqualStrings("Pin", f.app.overlay.menu.items[0].label);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // The New row's click — either button — is the choice menu: Rust's
    // command first, the batch rows, then the cloud wizards (naming
    // their missing config here).
    try testing.expectEqual(command.CommandId.@"ai.claude_code_new", new_command);
    try f.app.handle(.{ .mouse = .{ .x = new_chip.?.x + 1, .y = new_chip.?.y, .kind = .press, .button = .right } });
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(@as(usize, 6), f.app.overlay.menu.items.len);
    try testing.expectEqual(command.CommandId.@"ai.claude_code_new", f.app.overlay.menu.items[0].action.command);
    try testing.expectEqual(command.CommandId.@"ai.claude_code_new_x8", f.app.overlay.menu.items[3].action.command);
    try testing.expectEqual(command.CommandId.@"cloud_agents.new_run", f.app.overlay.menu.items[4].action.command);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.menu.items[4].label, "not configured") != null);
    try testing.expectEqual(command.CommandId.@"cloud_agents.new_run_wizard", f.app.overlay.menu.items[5].action.command);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try f.app.handle(.{ .mouse = .{ .x = new_chip.?.x + 1, .y = new_chip.?.y, .kind = .press, .button = .left } });
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(@as(usize, 6), f.app.overlay.menu.items.len);
    try f.app.handle(.{ .key = Key.named(.esc) });
}

test "Move to top / bottom lead or end the manual order under the pins; a cloud row's menu is titled by its run and links CloudWatch and the PR when configured" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const st = &f.app.sessions;
    const ws = std.fs.path.basename(f.root);
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 4);
    items[0] = item("live", .streaming, 30, ws, "ship it");
    items[1] = item("idle", .idle, 20, ws, "fix the tests");
    items[2] = item("gone", .done, 10, ws, "notes");
    items[3] = item("run-1", .streaming, 40, "cloud", "TE-1");
    items[3].where = .cloud;
    items[3].cloud = .{ .ticket = "TE-1", .pr_url = "https://example.test/pr/1" };
    r.items = items;
    st.generation = 1;
    try handle(&f.app, r);
    st.scanned_once = true;
    try testing.expectEqualStrings("live", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqualStrings("gone", st.items[st.filtered.items[2]].session_id);
    // The ended row to the top: the axis flips to Manual and the row
    // stays selected; then to the bottom.
    st.list.cursor = 2;
    try command.run(&f.app, .{ .static = .@"sessions.move_top" });
    try testing.expectEqual(SessionsSort.manual, st.sort);
    try testing.expectEqualStrings("gone", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqual(@as(usize, 0), st.list.cursor);
    try command.run(&f.app, .{ .static = .@"sessions.move_bottom" });
    try testing.expectEqualStrings("gone", st.items[st.filtered.items[2]].session_id);
    try testing.expectEqual(@as(usize, 2), st.list.cursor);
    try testing.expectEqualStrings("live", st.items[st.filtered.items[0]].session_id);
    // A pin still leads: idle pinned, then live to the top sits under it.
    _ = try st.togglePin(testing.allocator, "idle");
    try refilter(&f.app);
    st.list.cursor = 1;
    try testing.expectEqualStrings("live", st.items[st.filtered.items[1]].session_id);
    try command.run(&f.app, .{ .static = .@"sessions.move_top" });
    try testing.expectEqualStrings("idle", st.items[st.filtered.items[0]].session_id);
    try testing.expectEqualStrings("live", st.items[st.filtered.items[1]].session_id);
    // The menu's Auto sort row is unticked on the manual axis.
    try openRowMenuFor(&f.app, .section, 0, 0);
    try testing.expectEqualStrings("Auto sort", f.app.overlay.menu.items[5].label);
    try testing.expect(!f.app.overlay.menu.items[5].checked);
    try testing.expectEqual(command.CommandId.@"sessions.sort_auto", f.app.overlay.menu.items[5].action.command);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // The cloud row shows under `w`; its menu is the run's, with the PR
    // link and — unconfigured — no CloudWatch row.
    st.all_workspaces = true;
    try refilter(&f.app);
    for (st.filtered.items, 0..) |idx, vi| if (st.items[idx].where == .cloud) {
        st.list.cursor = vi;
    };
    try openRowMenuFor(&f.app, .section, 0, 0);
    try testing.expectEqualStrings("cloud · run-1", f.app.overlay.menu.title);
    var saw_pr = false;
    var saw_cw = false;
    for (f.app.overlay.menu.items) |mi| {
        if (std.mem.eql(u8, mi.label, "Open PR")) {
            saw_pr = true;
            try testing.expectEqualStrings("https://example.test/pr/1", mi.action.open_url);
        }
        if (std.mem.eql(u8, mi.label, "Open CloudWatch in browser")) saw_cw = true;
        try testing.expect(!std.mem.eql(u8, mi.label, "Resume in a terminal"));
    }
    try testing.expect(saw_pr and !saw_cw);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // Configured, the CloudWatch row names the run's query.
    f.app.cfg.cloud_agents.region = "eu-west-1";
    f.app.cfg.cloud_agents.account_id = "123456789012";
    f.app.cfg.cloud_agents.log_group = "/ecs/runner";
    try openRowMenuFor(&f.app, .section, 0, 0);
    saw_cw = false;
    for (f.app.overlay.menu.items) |mi| if (std.mem.eql(u8, mi.label, "Open CloudWatch in browser")) {
        saw_cw = true;
        try testing.expect(std.mem.startsWith(u8, mi.action.open_url, "https://eu-west-1.console.aws.amazon.com/cloudwatch/"));
        try testing.expect(std.mem.indexOf(u8, mi.action.open_url, "run-1") != null);
        try testing.expect(std.mem.endsWith(u8, mi.action.open_url, "?account=123456789012"));
    };
    try testing.expect(saw_cw);
    try f.app.handle(.{ .key = Key.named(.esc) });
}

test "state edges: the first listing is no edge; live → waiting toasts once (warn) and rings the bell only under ui.session_bell; the same listing again is quiet; failed toasts err" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const st = &f.app.sessions;
    const ws = std.fs.path.basename(f.root);
    const msgs = &f.app.messages.items;
    const listing = struct {
        fn post(fx: *Fixture, a: AgentState, b: AgentState) !void {
            const r = try ScanResult.create(testing.allocator, 1);
            const items = try r.arena.allocator().alloc(Item, 2);
            items[0] = item("a", a, 30, std.fs.path.basename(fx.root), "approve?");
            items[1] = item("b", b, 20, std.fs.path.basename(fx.root), "ship it");
            r.items = items;
            fx.app.sessions.generation = 1;
            try handle(&fx.app, r);
        }
    };
    _ = ws;
    const before = msgs.items.len;
    // A session that is already waiting when first listed is no edge.
    try listing.post(&f, .waiting, .streaming);
    try testing.expectEqual(before, msgs.items.len);
    try testing.expect(!f.app.bell_pending);
    // b goes waiting: one warn toast naming it; the bell is off by default.
    try listing.post(&f, .waiting, .waiting);
    try testing.expectEqual(before + 1, msgs.items.len);
    try testing.expectEqualStrings("session needs input: ship it", msgs.items[msgs.items.len - 1].text);
    try testing.expectEqual(app_mod.ToastLevel.warn, msgs.items[msgs.items.len - 1].level);
    try testing.expect(!f.app.bell_pending);
    // The same listing on the next tick: nothing new.
    try listing.post(&f, .waiting, .waiting);
    try listing.post(&f, .waiting, .waiting);
    try testing.expectEqual(before + 1, msgs.items.len);
    // Quiet edges say nothing; a → failed toasts err; b back to waiting
    // rings the bell once the config asks.
    try listing.post(&f, .streaming, .idle);
    try testing.expectEqual(before + 1, msgs.items.len);
    f.app.cfg.ui.session_bell = true;
    try listing.post(&f, .failed, .waiting);
    try testing.expectEqual(before + 3, msgs.items.len);
    try testing.expectEqualStrings("session failed: approve?", msgs.items[msgs.items.len - 2].text);
    try testing.expectEqual(app_mod.ToastLevel.err, msgs.items[msgs.items.len - 2].level);
    try testing.expect(f.app.bell_pending);
    // Sorted first in the section on either axis.
    try testing.expectEqualStrings("b", st.items[st.filtered.items[0]].session_id);
}

test "a relative HOME is under the workspace: what a .test file seeds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    var vars = std.process.Environ.Map.init(testing.allocator);
    defer vars.deinit();
    try vars.put("HOME", "home");
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 80, .rows = 20, .env = &vars });
    defer app.deinit();
    const home = (try homeFor(&app)).?;
    try testing.expect(std.fs.path.isAbsolute(home));
    try testing.expectEqualStrings("home", std.fs.path.basename(home));
    try testing.expect(std.mem.startsWith(u8, home, root));
    try testing.expectEqualStrings(home, app.sessions.home.?);
}

test "colors: a card's `▌` takes the session's chosen colour over the cursor and active cues; the row menu's Color rows resolve" {
    var f = try UiFixture.init(26, 20);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    var rows = specCards();
    rows[1].color = "blue";
    rows[1].active = true;
    rows[2].color = "bogus";
    _ = Panel.draw(&st, f.ui(), f.full(), cardProps(&rows));
    // Card 0 (no colour, not active, the cursor's while a pane has
    // focus): the ground. Card 1: blue, though active. Card 2: an
    // unknown name is no colour.
    try testing.expect(vaxis.Color.eql(f.style(1, 5).fg, f.theme.panel_bg.bg));
    try testing.expect(vaxis.Color.eql(f.style(1, 10).fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.style(1, 13).fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.style(1, 15).fg, f.theme.panel_bg.bg));
    // The rows a menu shows: the palette in order, then Auto, one checked.
    var mem = std.heap.ArenaAllocator.init(testing.allocator);
    defer mem.deinit();
    const items = try colorMenuRows(mem.allocator(), .{ .target = .row, .name = "" }, "yellow");
    try testing.expectEqual(accent_color.palette.len + 1, items.len);
    try testing.expectEqualStrings("Color: Green", items[0].label);
    try testing.expect(items[2].checked and !items[0].checked and !items[items.len - 1].checked);
    try testing.expectEqualStrings("Color: Auto", items[items.len - 1].label);
    try testing.expectEqualStrings(accent_color.none, items[items.len - 1].action.session_color.name);
}

test "colors: the state keeps a colour per session id — set, replace, none drops, unknown drops" {
    var f = try Fixture.init(40, 10);
    defer f.deinit();
    const st = &f.app.sessions;
    try st.setColor(testing.allocator, "s1", "green");
    try st.setColor(testing.allocator, "s2", "pink");
    try testing.expectEqualStrings("green", st.color("s1").?);
    try testing.expectEqualStrings("pink", st.color("s2").?);
    try st.setColor(testing.allocator, "s1", "red");
    try testing.expectEqualStrings("red", st.color("s1").?);
    try st.setColor(testing.allocator, "s2", accent_color.none);
    try testing.expect(st.color("s2") == null);
    try st.setColor(testing.allocator, "s3", "mauve");
    try testing.expect(st.color("s3") == null);
    try testing.expectEqual(@as(usize, 1), st.colors.items.len);
    try testing.expectEqualStrings("red", colorNameOf(&f.app, "s1").?);
    try testing.expect(colorNameOf(&f.app, "s2") == null);
}
