//! The Claude Agents dashboard (`Pane.claude_agents`, `ai.dashboard`):
//! every Claude Code / Codex session on this machine, its state, its
//! workspace, its tokens and cost, its last exchange — rescanned every
//! three seconds while the pane is open and not paused.
//!
//!   D1  the scan lands as `*ScanResult` on the `.agents` event; the
//!       pane adopts it into its snapshot arena (`handle`);
//!   D3  one `Io.Group` per pane; a refresh cancels the scan in flight
//!       and bumps the generation so a stale result is dropped — the
//!       timer never races an in-progress scan;
//!   D6  `src/ui/agents_view.zig` paints; rows and chips register
//!       `.script_hit{pane, id}`, routed by `click` here.
//!
//! Sessions come from `~/.claude/projects/<encoded ws>/<sid>.jsonl`
//! and `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (the tail of
//! each, `transcript.zig`), with `ps -axo pid=,command=` telling which
//! are alive. No home directory (the `.test` runner) means no scan.

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
const text_field = @import("../ui/text_field.zig");
const pty_pane = @import("pty_pane.zig");
const cli = @import("../ai/cli.zig");
const layout_mod = @import("layout.zig");

pub const table = .{
    .@"ai.dashboard" = &openCmd,
    .@"agents.refresh" = &refreshCmd,
    .@"agents.new_from_pr" = &newFromPr,
    .@"ai.dashboard.open_transcript" = &openTranscriptCmd,
    .@"ai.dashboard.yank_session_id" = &yankSessionId,
    .@"ai.dashboard.yank_cwd" = &yankCwd,
    .@"ai.dashboard.export_markdown" = &exportMarkdown,
    .@"ai.dashboard.kill" = &killCmd,
    .@"ai.dashboard.resume_in_pty" = &resumeCmd,
};

/// Auto-refresh cadence while the pane is open and live.
pub const refresh_ms: i64 = 3000;
/// A file older than this is not listed (Rust: the 7-day window).
pub const max_age_s: i64 = 7 * 24 * 3600;
/// Bytes of a transcript's tail that are parsed.
pub const tail_cap: usize = 256 * 1024;
/// Transcripts past this are skipped outright.
pub const max_file_bytes: u64 = 256 * 1024 * 1024;
/// A session whose file moved within this many seconds is `streaming`.
pub const fresh_s: i64 = 60;

pub const Source = enum {
    claude,
    codex,

    pub fn label(s: Source) []const u8 {
        return @tagName(s);
    }
    pub fn glyph(s: Source, ascii: bool) []const u8 {
        return switch (s) {
            .claude => if (ascii) "*" else "✦",
            .codex => if (ascii) "#" else "◈",
        };
    }
};

pub const AgentState = enum {
    streaming,
    tool_call,
    idle,
    ended,

    pub fn badge(s: AgentState, ascii: bool) []const u8 {
        return switch (s) {
            .streaming => if (ascii) "* live" else "● live",
            .tool_call => if (ascii) "> tool" else "▸ tool",
            .idle => if (ascii) "o idle" else "○ idle",
            .ended => if (ascii) ". ended" else "· ended",
        };
    }
    pub fn rank(s: AgentState) u8 {
        return @intFromEnum(s);
    }
};

pub const Sort = enum {
    state,
    tokens,
    cost,
    recent,
    workspace,

    pub fn label(s: Sort) []const u8 {
        return switch (s) {
            .state => "state",
            .tokens => "tokens↓",
            .cost => "cost↓",
            .recent => "recent",
            .workspace => "workspace",
        };
    }
    pub fn next(s: Sort) Sort {
        return switch (s) {
            .state => .tokens,
            .tokens => .cost,
            .cost => .recent,
            .recent => .workspace,
            .workspace => .state,
        };
    }
};

/// One session. Slices borrow from the result's arena in flight and
/// from the pane's snapshot once adopted.
pub const Row = struct {
    source: Source,
    session_id: []const u8,
    workspace: []const u8,
    cwd: ?[]const u8,
    model: ?[]const u8,
    transcript_path: []const u8,
    state: AgentState,
    pid: ?u32,
    tokens: u64,
    cost_usd: f64,
    /// Unix seconds of the last file change.
    last_activity_s: i64,
    last_user_msg: ?[]const u8,
    last_assistant_msg: ?[]const u8,
    current_tool: ?[]const u8,
    pending_tool_uses: usize,
};

pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    generation: u32,
    /// Which pane asked; a pane that closed meanwhile drops it.
    pane: PaneId,

    pub fn create(gpa: Allocator, generation: u32, pane: PaneId) Allocator.Error!*ScanResult {
        const r = try gpa.create(ScanResult);
        r.* = .{ .arena = .init(gpa), .generation = generation, .pane = pane };
        return r;
    }

    pub fn destroy(self: *ScanResult, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Detail = enum {
    summary,
    todos,
    files,
    bash,
    agents,

    pub fn label(d: Detail) []const u8 {
        return switch (d) {
            .summary => "Summary",
            .todos => "Todos",
            .files => "Files",
            .bash => "Bash",
            .agents => "Agents",
        };
    }
    pub fn next(d: Detail) Detail {
        return switch (d) {
            .summary => .todos,
            .todos => .files,
            .files => .bash,
            .bash => .agents,
            .agents => .summary,
        };
    }
};

/// `Pane.claude_agents`.
pub const AgentsPane = struct {
    gpa: Allocator,
    group: Io.Group = .init,
    snapshot: alloc.SnapshotArena,
    rows: []Row = &.{},
    /// Indices into `rows` that pass the filters, in display order.
    visible: std.ArrayListUnmanaged(u32) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    query: text_field.Buf = .empty,
    query_caret: usize = 0,
    /// `/` is being typed: keys edit the query, the tail is paused.
    filter_mode: bool = false,
    paused_by_user: bool = false,
    state_filter: ?AgentState = null,
    source_filter: ?Source = null,
    workspace_only: bool = false,
    sort: Sort = .state,
    detail: Detail = .summary,
    help: bool = false,
    /// Session ids ticked with space. Owned keys.
    multi: std.StringHashMapUnmanaged(void) = .empty,
    generation: u32 = 0,
    scanning: bool = false,
    scanned_once: bool = false,
    last_scan_ms: i64 = 0,
    detail_scroll: usize = 0,
    /// The dashboard scans only when it has somewhere to look.
    home: ?[]u8 = null,

    pub fn init(gpa: Allocator, home: ?[]const u8) Allocator.Error!AgentsPane {
        return .{ .gpa = gpa, .snapshot = alloc.SnapshotArena.init(gpa), .home = if (home) |h| try gpa.dupe(u8, h) else null };
    }

    /// Cancels the scan in flight and waits for it (it posts into the
    /// app's queue and borrows `home`).
    pub fn deinit(self: *AgentsPane, io: Io) void {
        self.group.cancel(io);
        var it = self.multi.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.multi.deinit(self.gpa);
        self.visible.deinit(self.gpa);
        self.query.deinit(self.gpa);
        if (self.home) |h| self.gpa.free(h);
        self.snapshot.deinit();
    }

    /// Live tail is off while the user is typing a filter or has paused it.
    pub fn paused(self: *const AgentsPane) bool {
        return self.paused_by_user or self.filter_mode;
    }

    pub fn selected(self: *const AgentsPane) ?Row {
        if (self.cursor >= self.visible.items.len) return null;
        return self.rows[self.visible.items[self.cursor]];
    }

    pub fn anyFilter(self: *const AgentsPane) bool {
        return self.query.items.len > 0 or self.state_filter != null or self.source_filter != null or self.workspace_only;
    }

    pub const Aggregate = struct { live: usize, tool: usize, idle: usize, ended: usize, tokens: u64, cost: f64 };

    pub fn aggregate(self: *const AgentsPane) Aggregate {
        var a: Aggregate = .{ .live = 0, .tool = 0, .idle = 0, .ended = 0, .tokens = 0, .cost = 0 };
        for (self.rows) |r| {
            switch (r.state) {
                .streaming => a.live += 1,
                .tool_call => a.tool += 1,
                .idle => a.idle += 1,
                .ended => a.ended += 1,
            }
            a.tokens += r.tokens;
            a.cost += r.cost_usd;
        }
        return a;
    }
};

// ─── open / refresh ─────────────────────────────────────────────────────

/// The one dashboard pane, if open.
pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.claude_agents);
}

fn openCmd(app: *App) CommandError!void {
    if (find(app)) |id| {
        app.showPane(id);
        return refresh(app, id);
    }
    var pane = try AgentsPane.init(app.gpa, app.homeDir());
    errdefer pane.deinit(app.io);
    const id = try app.panes.add(.{ .claude_agents = pane });
    pane = undefined; // owned by the store
    app.showPane(id);
    try refresh(app, id);
}

fn activePane(app: *App) CommandError!struct { id: PaneId, p: *AgentsPane } {
    const id = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(id) orelse return error.NoActivePane;
    return switch (pane.*) {
        .claude_agents => |*p| .{ .id = id, .p = p },
        else => app.diag.fail(app.frame.allocator(), "not the Claude Agents pane", .{}),
    };
}

fn refreshCmd(app: *App) CommandError!void {
    const id = find(app) orelse return openCmd(app);
    try refresh(app, id);
}

/// Cancel the scan in flight, bump the generation, start another.
pub fn refresh(app: *App, id: PaneId) CommandError!void {
    const pane = app.panes.get(id) orelse return;
    const p = switch (pane.*) {
        .claude_agents => |*p| p,
        else => return,
    };
    p.last_scan_ms = app.now_ms;
    p.scanned_once = true;
    const home = p.home orelse {
        // Nowhere to look: an empty snapshot, no worker.
        p.scanning = false;
        p.snapshot.reset();
        p.rows = &.{};
        try refilter(app, p);
        return;
    };
    p.group.cancel(app.io);
    p.generation +%= 1;
    p.scanning = true;
    app.needs_render = true;
    p.group.concurrent(app.io, scanWorker, .{ &app.events, app.io, app.gpa, home, app.workspace, p.generation, id }) catch |err| {
        p.scanning = false;
        return app.diag.fail(app.frame.allocator(), "agents: could not start the scan: {s}", .{@errorName(err)});
    };
}

/// Every tick: a live dashboard rescans every `refresh_ms`.
pub fn tickAll(app: *App) Allocator.Error!void {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .claude_agents => |*p| {
            if (p.paused() or p.scanning or p.home == null) continue;
            if (app.now_ms - p.last_scan_ms < refresh_ms) continue;
            refresh(app, @intCast(i)) catch {};
        },
        else => {},
    };
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    var next: ?i64 = null;
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .claude_agents => |*p| {
            if (p.scanning) next = @min(next orelse std.math.maxInt(i64), app.now_ms + 80);
            if (!p.paused() and p.home != null) next = @min(next orelse std.math.maxInt(i64), p.last_scan_ms + refresh_ms);
        },
        else => {},
    };
    return next;
}

// ─── the scan worker (D1 + D3) ──────────────────────────────────────────

fn scanWorker(events: *event.EventQueue, io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, generation: u32, pane: PaneId) Io.Cancelable!void {
    const result = ScanResult.create(gpa, generation, pane) catch return;
    errdefer result.destroy(gpa);
    scanInto(io, gpa, home, workspace, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => {
            postErr(events, io, gpa, "out of memory during the session scan");
            return;
        },
    };
    events.post(io, .{ .agents = result });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .ai, .msg = owned } });
}

const ScanError = Io.Cancelable || Allocator.Error;

pub const Pid = struct { pid: u32, session_id: ?[]const u8, exe: Source };

/// `ps -axo pid=,command=` → the claude / codex processes, with the
/// `--session-id <uuid>` a Claude line carries.
pub fn parsePs(arena: Allocator, text: []const u8) Allocator.Error![]Pid {
    var out: std.ArrayListUnmanaged(Pid) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const pid = std.fmt.parseInt(u32, line[0..sp], 10) catch continue;
        const cmd = std.mem.trimStart(u8, line[sp + 1 ..], " ");
        const exe_end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
        const exe = std.fs.path.basename(cmd[0..exe_end]);
        const source: Source = if (std.mem.eql(u8, exe, "claude")) .claude else if (std.mem.eql(u8, exe, "codex")) .codex else continue;
        var sid: ?[]const u8 = null;
        if (std.mem.indexOf(u8, cmd, "--session-id ")) |at| {
            const rest = cmd[at + "--session-id ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            if (end == 36) sid = try arena.dupe(u8, rest[0..end]);
        } else if (std.mem.indexOf(u8, cmd, "--resume ")) |at| {
            const rest = cmd[at + "--resume ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            if (end == 36) sid = try arena.dupe(u8, rest[0..end]);
        }
        try out.append(arena, .{ .pid = pid, .session_id = sid, .exe = source });
    }
    return out.items;
}

fn runningPids(io: Io, gpa: Allocator, arena: Allocator) ScanError![]Pid {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "ps", "-axo", "pid=,command=" }, .stdout_limit = .limited(4 * 1024 * 1024) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return &.{},
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return parsePs(arena, result.stdout);
}

pub fn deriveState(has_pid: bool, age_s: i64, last_was_tool_call: bool) AgentState {
    if (!has_pid) return .ended;
    if (last_was_tool_call) return .tool_call;
    return if (age_s < fresh_s) .streaming else .idle;
}

/// Walk both roots and fill `r.rows` on `r.arena`.
pub fn scanInto(io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, r: *ScanResult) ScanError!void {
    const arena = r.arena.allocator();
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    const pids = try runningPids(io, gpa, arena);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    _ = workspace;
    // Claude: <home>/.claude/projects/<encoded>/<sid>.jsonl
    const projects = try std.fs.path.join(arena, &.{ home, ".claude", "projects" });
    if (Io.Dir.cwd().openDir(io, projects, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var dirs = root.iterate();
        while (dirs.next(io) catch null) |d| {
            if (d.kind != .directory) continue;
            try io.checkCancel();
            var sub = root.openDir(io, d.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const ws_label = try arena.dupe(u8, transcript.decodeWorkspaceLabel(d.name));
            var files = sub.iterate();
            while (files.next(io) catch null) |f| {
                if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".jsonl")) continue;
                const st = sub.statFile(io, f.name, .{}) catch continue;
                const mtime = st.mtime.toSeconds();
                if (now - mtime > max_age_s or st.size > max_file_bytes) continue;
                try io.checkCancel();
                const tail = transcript.readTail(gpa, io, sub, f.name, tail_cap) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                defer gpa.free(tail);
                const stats = try transcript.parseClaude(arena, tail);
                const sid = try arena.dupe(u8, f.name[0 .. f.name.len - ".jsonl".len]);
                var pid: ?u32 = null;
                for (pids) |p| if (p.session_id) |s| if (std.mem.eql(u8, s, sid)) {
                    pid = p.pid;
                };
                try rows.append(arena, .{
                    .source = .claude,
                    .session_id = sid,
                    .workspace = ws_label,
                    .cwd = stats.cwd,
                    .model = stats.model,
                    .transcript_path = try std.fs.path.join(arena, &.{ projects, d.name, f.name }),
                    .state = deriveState(pid != null, now - mtime, stats.last_was_tool_call),
                    .pid = pid,
                    .tokens = stats.tokens,
                    .cost_usd = stats.costUsd(),
                    .last_activity_s = mtime,
                    .last_user_msg = stats.last_user_msg,
                    .last_assistant_msg = stats.last_assistant_msg,
                    .current_tool = stats.last_tool_name,
                    .pending_tool_uses = stats.pending_tool_uses,
                });
            }
        }
    } else |_| {}
    // Codex: <home>/.codex/sessions/**/rollout-<ts>-<uuid>.jsonl
    const sessions = try std.fs.path.join(arena, &.{ home, ".codex", "sessions" });
    if (Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var walker = root.walk(gpa) catch return error.OutOfMemory;
        defer walker.deinit();
        var claimed: std.ArrayListUnmanaged(u32) = .empty;
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.basename, "rollout-") or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
            try io.checkCancel();
            const stem = entry.basename[0 .. entry.basename.len - ".jsonl".len];
            if (stem.len < 36) continue;
            const sid = try arena.dupe(u8, stem[stem.len - 36 ..]);
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const mtime = st.mtime.toSeconds();
            if (now - mtime > max_age_s or st.size > max_file_bytes) continue;
            const tail = transcript.readTail(gpa, io, entry.dir, entry.basename, tail_cap) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer gpa.free(tail);
            const stats = try transcript.parseCodex(arena, tail);
            // Codex carries no session id on its command line: the first
            // unclaimed codex process is this session's, newest file first.
            var pid: ?u32 = null;
            if (now - mtime < 3600) for (pids) |p| {
                if (p.exe != .codex) continue;
                if (std.mem.indexOfScalar(u32, claimed.items, p.pid) != null) continue;
                pid = p.pid;
                try claimed.append(arena, p.pid);
                break;
            };
            try rows.append(arena, .{
                .source = .codex,
                .session_id = sid,
                .workspace = if (stats.cwd) |c| std.fs.path.basename(c) else "?",
                .cwd = stats.cwd,
                .model = stats.model,
                .transcript_path = try std.fs.path.join(arena, &.{ sessions, entry.path }),
                .state = deriveState(pid != null, now - mtime, stats.last_was_tool_call),
                .pid = pid,
                .tokens = stats.tokens,
                .cost_usd = stats.costUsd(),
                .last_activity_s = mtime,
                .last_user_msg = stats.last_user_msg,
                .last_assistant_msg = stats.last_assistant_msg,
                .current_tool = stats.last_tool_name,
                .pending_tool_uses = stats.pending_tool_uses,
            });
        }
    } else |_| {}
    r.rows = rows.items;
}

// ─── the event handler (D1) ─────────────────────────────────────────────

/// `result` is destroyed on every path; a stale generation, or a pane
/// that closed, is dropped whole.
pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    defer result.destroy(app.gpa);
    const pane = app.panes.get(result.pane) orelse return;
    const p = switch (pane.*) {
        .claude_agents => |*p| p,
        else => return,
    };
    if (result.generation != p.generation) return;
    p.scanning = false;
    const keep_sid: ?[]const u8 = if (p.selected()) |row| try app.frame.allocator().dupe(u8, row.session_id) else null;
    p.snapshot.reset();
    p.rows = &.{};
    const arena = p.snapshot.allocator();
    const rows = try arena.alloc(Row, result.rows.len);
    for (result.rows, 0..) |src, i| {
        rows[i] = .{
            .source = src.source,
            .session_id = try arena.dupe(u8, src.session_id),
            .workspace = try arena.dupe(u8, src.workspace),
            .cwd = if (src.cwd) |c| try arena.dupe(u8, c) else null,
            .model = if (src.model) |m| try arena.dupe(u8, m) else null,
            .transcript_path = try arena.dupe(u8, src.transcript_path),
            .state = src.state,
            .pid = src.pid,
            .tokens = src.tokens,
            .cost_usd = src.cost_usd,
            .last_activity_s = src.last_activity_s,
            .last_user_msg = if (src.last_user_msg) |m| try arena.dupe(u8, m) else null,
            .last_assistant_msg = if (src.last_assistant_msg) |m| try arena.dupe(u8, m) else null,
            .current_tool = if (src.current_tool) |c| try arena.dupe(u8, c) else null,
            .pending_tool_uses = src.pending_tool_uses,
        };
    }
    p.rows = rows;
    try refilter(app, p);
    // The selection follows its session across refreshes.
    if (keep_sid) |sid| for (p.visible.items, 0..) |idx, vi| if (std.mem.eql(u8, p.rows[idx].session_id, sid)) {
        p.cursor = vi;
        break;
    };
    app.needs_render = true;
}

/// Filters then sort, into `visible`.
pub fn refilter(app: *App, p: *AgentsPane) Allocator.Error!void {
    p.visible.clearRetainingCapacity();
    const ws_name = std.fs.path.basename(app.workspace);
    const q = p.query.items;
    for (p.rows, 0..) |r, i| {
        if (p.state_filter) |s| if (r.state != s) continue;
        if (p.source_filter) |s| if (r.source != s) continue;
        if (p.workspace_only and !std.mem.eql(u8, r.workspace, ws_name)) continue;
        if (q.len > 0 and !matches(r, q)) continue;
        try p.visible.append(app.gpa, @intCast(i));
    }
    const Ctx = struct {
        rows: []const Row,
        sort: Sort,
        fn lt(ctx: @This(), a: u32, b: u32) bool {
            const ra = ctx.rows[a];
            const rb = ctx.rows[b];
            switch (ctx.sort) {
                .state => if (ra.state.rank() != rb.state.rank()) return ra.state.rank() < rb.state.rank(),
                .tokens => if (ra.tokens != rb.tokens) return ra.tokens > rb.tokens,
                .cost => if (ra.cost_usd != rb.cost_usd) return ra.cost_usd > rb.cost_usd,
                .recent => {},
                .workspace => {
                    const o = std.mem.order(u8, ra.workspace, rb.workspace);
                    if (o != .eq) return o == .lt;
                },
            }
            return ra.last_activity_s > rb.last_activity_s;
        }
    };
    std.mem.sort(u32, p.visible.items, Ctx{ .rows = p.rows, .sort = p.sort }, Ctx.lt);
    if (p.cursor >= p.visible.items.len) p.cursor = p.visible.items.len -| 1;
}

pub fn matches(r: Row, q: []const u8) bool {
    if (containsIgnoreCase(r.workspace, q) or containsIgnoreCase(r.session_id, q)) return true;
    if (r.model) |m| if (containsIgnoreCase(m, q)) return true;
    if (r.last_user_msg) |m| if (containsIgnoreCase(m, q)) return true;
    if (r.last_assistant_msg) |m| if (containsIgnoreCase(m, q)) return true;
    return false;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// `>` / `<`: all → claude → codex → all. Cloud sources are not in this
/// build, so the cycle has three stops.
pub fn cycleSource(cur: ?Source, forward: bool) ?Source {
    if (forward) return switch (cur orelse return .claude) {
        .claude => .codex,
        .codex => null,
    };
    return switch (cur orelse return .codex) {
        .codex => .claude,
        .claude => null,
    };
}

// ─── keys ───────────────────────────────────────────────────────────────

/// Keys on the dashboard. False lets the chord chain see the key.
pub fn handleKey(app: *App, id: PaneId, p: *AgentsPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    if (p.help) {
        const f1 = k.code == .f and k.code.f == 1;
        if (k.code == .esc or f1 or (k.code == .char and k.code.char == '?')) p.help = false;
        return true;
    }
    if (p.filter_mode) {
        switch (k.code) {
            .esc => {
                p.query.clearRetainingCapacity();
                p.query_caret = 0;
                p.filter_mode = false;
                try refilter(app, p);
                return true;
            },
            .enter => {
                p.filter_mode = false;
                return true;
            },
            .f => |n| if (n == 1) {
                p.help = true;
                return true;
            },
            .down => p.cursor = @min(p.cursor + 1, p.visible.items.len -| 1),
            .up => p.cursor -|= 1,
            else => switch (try text_field.handleKey(&p.query, &p.query_caret, app.gpa, k)) {
                .changed => {
                    p.cursor = 0;
                    try refilter(app, p);
                },
                else => {},
            },
        }
        return true;
    }
    const last = p.visible.items.len -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .page_down => if (k.mods.shift) {
            p.detail_scroll += 5;
        } else {
            p.cursor = @min(p.cursor + 10, last);
        },
        .page_up => if (k.mods.shift) {
            p.detail_scroll -|= 5;
        } else {
            p.cursor -|= 10;
        },
        .enter => runToast(app, openTranscript(app, p)),
        .esc => try app.forceClosePane(id),
        .f => |n| if (n == 1) {
            p.help = true;
        } else return false,
        .char => |c| {
            if (k.mods.ctrl and !k.mods.alt and !k.mods.super) switch (c) {
                'l' => {
                    p.query.clearRetainingCapacity();
                    p.query_caret = 0;
                    p.state_filter = null;
                    p.source_filter = null;
                    p.workspace_only = false;
                    try refilter(app, p);
                },
                'g' => app.toast("group by: sessions are listed by {s}", .{p.sort.label()}),
                else => return false,
            } else if (k.mods.alt or k.mods.super) return false else switch (c) {
                'j' => p.cursor = @min(p.cursor + 1, last),
                'k' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                '/' => p.filter_mode = true,
                '0' => p.state_filter = null,
                '1' => p.state_filter = .streaming,
                '2' => p.state_filter = .tool_call,
                '3' => p.state_filter = .idle,
                '4' => p.state_filter = .ended,
                '>' => p.source_filter = cycleSource(p.source_filter, true),
                '<' => p.source_filter = cycleSource(p.source_filter, false),
                'W' => p.workspace_only = !p.workspace_only,
                's' => p.sort = p.sort.next(),
                'v' => p.detail = p.detail.next(),
                'r' => runToast(app, refresh(app, id)),
                'p' => {
                    p.paused_by_user = !p.paused_by_user;
                    app.toast("agents: auto-refresh {s}", .{if (p.paused_by_user) "paused" else "resumed"});
                },
                '?' => p.help = true,
                ' ' => try toggleMulti(app, p),
                'R' => clearMulti(p),
                'y' => runToast(app, yankSessionId(app)),
                'c' => runToast(app, yankCwd(app)),
                't' => runToast(app, openTranscript(app, p)),
                'o' => runToast(app, resumeCmd(app)),
                'K' => runToast(app, killCmd(app)),
                'e' => runToast(app, exportMarkdown(app)),
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    switch (k.code) {
        .char => |c| switch (c) {
            '0', '1', '2', '3', '4', '>', '<', 'W', 's' => try refilter(app, p),
            else => {},
        },
        else => {},
    }
    return true;
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("agents: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

fn toggleMulti(app: *App, p: *AgentsPane) Allocator.Error!void {
    const row = p.selected() orelse return;
    if (p.multi.fetchRemove(row.session_id)) |kv| {
        app.gpa.free(kv.key);
        return;
    }
    const key = try app.gpa.dupe(u8, row.session_id);
    errdefer app.gpa.free(key);
    try p.multi.put(app.gpa, key, {});
}

fn clearMulti(p: *AgentsPane) void {
    var it = p.multi.keyIterator();
    while (it.next()) |k| p.gpa.free(k.*);
    p.multi.clearRetainingCapacity();
}

/// A click on a row / chip / the body (`.script_hit`). Ids: rows are
/// `row_base + visible index`, chips below that.
pub const hit_title: u32 = 0;
pub const hit_help: u32 = 1;
pub const hit_sort: u32 = 2;
pub const hit_source: u32 = 3;
pub const hit_pause: u32 = 4;
pub const hit_refresh: u32 = 5;
pub const hit_detail: u32 = 6;
pub const row_base: u32 = 0x1000;

/// A right-click on a session row: its verbs, titled by the session.
pub fn openRowMenu(app: *App, p: *AgentsPane, x: u16, y: u16) Allocator.Error!void {
    const row = p.selected() orelse return;
    const title = try std.fmt.allocPrint(app.frame.allocator(), "{s} · {s}", .{ row.source.label(), if (row.cwd) |c| std.fs.path.basename(c) else "?" });
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Open transcript", .action = .{ .command = .@"ai.dashboard.open_transcript" } },
        .{ .label = "Resume in a terminal", .action = .{ .command = .@"ai.dashboard.resume_in_pty" } },
        .{ .label = "Copy session id", .action = .{ .command = .@"ai.dashboard.yank_session_id" }, .separator_before = true },
        .{ .label = "Copy working directory", .action = .{ .command = .@"ai.dashboard.yank_cwd" } },
        .{ .label = "Export as markdown…", .action = .{ .command = .@"ai.dashboard.export_markdown" } },
        .{ .label = "Kill session…", .action = .{ .command = .@"ai.dashboard.kill" }, .separator_before = true },
        .{ .label = "Refresh", .action = .{ .command = .@"agents.refresh" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu(title, items, x, y);
}

pub fn click(app: *App, id: PaneId, p: *AgentsPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    if (hit_id >= row_base) {
        const vi: usize = hit_id - row_base;
        if (vi >= p.visible.items.len) return;
        const again = p.cursor == vi;
        p.cursor = vi;
        if (m.button == .right) {
            app.setActive(id);
            return openRowMenu(app, p, m.x, m.y);
        }
        if (m.button == .left and again) runToast(app, openTranscript(app, p));
        return;
    }
    switch (hit_id) {
        hit_help => p.help = !p.help,
        hit_sort => {
            p.sort = p.sort.next();
            try refilter(app, p);
        },
        hit_source => {
            p.source_filter = cycleSource(p.source_filter, m.button != .right);
            try refilter(app, p);
        },
        hit_pause => p.paused_by_user = !p.paused_by_user,
        hit_refresh => runToast(app, refresh(app, id)),
        hit_detail => p.detail = p.detail.next(),
        else => {},
    }
    app.needs_render = true;
}

pub fn scrollBy(p: *AgentsPane, delta: i64) void {
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(p.visible.items.len -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

// ─── row actions ────────────────────────────────────────────────────────

fn selectedRow(app: *App) CommandError!struct { p: *AgentsPane, row: Row } {
    const ap = try activePane(app);
    const row = ap.p.selected() orelse return app.diag.fail(app.frame.allocator(), "agents: no session selected", .{});
    return .{ .p = ap.p, .row = row };
}

fn openTranscriptCmd(app: *App) CommandError!void {
    const s = try selectedRow(app);
    return openTranscript(app, s.p);
}

/// `t` / Enter: the transcript in a split below — the file watcher
/// keeps it moving while the session runs.
fn openTranscript(app: *App, p: *AgentsPane) CommandError!void {
    const row = p.selected() orelse return app.diag.fail(app.frame.allocator(), "agents: no session selected", .{});
    const path = try app.frame.allocator().dupe(u8, row.transcript_path);
    const anchor = app.active;
    const id = app.openEditor(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ path, @errorName(err) }),
    };
    // Beside the dashboard, not on top of it.
    if (anchor) |a| if (a != id) {
        const layout = app.layouts.current();
        if (layout.leafOf(a) != null and layout.leafOf(id) != null and layout.leafOf(a).? == layout.leafOf(id).?) {
            _ = layout.removePane(id);
            _ = layout.split(a, .vertical, id) catch {};
            app.setActive(id);
        }
    };
    if (app.panes.editor(id)) |e| {
        const ed = &e.buf.editor;
        ed.placeCursor(ed.lineCount() -| 1, 0);
    }
}

fn yankSessionId(app: *App) CommandError!void {
    const s = try selectedRow(app);
    try app.clipboard.setYank(s.row.session_id, false);
    app.toast("copied {s}", .{s.row.session_id});
}

fn yankCwd(app: *App) CommandError!void {
    const s = try selectedRow(app);
    const cwd = s.row.cwd orelse return app.diag.fail(app.frame.allocator(), "agents: the session has no cwd", .{});
    try app.clipboard.setYank(cwd, false);
    app.toast("copied {s}", .{cwd});
}

/// `o`: `claude --resume <id>` (or `codex`) in a pty in the session's cwd.
fn resumeCmd(app: *App) CommandError!void {
    const s = try selectedRow(app);
    const arena = app.frame.allocator();
    const argv: []const []const u8 = switch (s.row.source) {
        .claude => try cli.claudeResumeArgv(arena, s.row.session_id),
        .codex => &.{cli.codex_binary},
    };
    _ = try pty_pane.open(app, .{ .argv = argv, .cwd = s.row.cwd, .label = s.row.source.label(), .placement = .right, .kind = .command });
}

/// `K`: SIGTERM the selected session (or every ticked one) after a confirm.
fn killCmd(app: *App) CommandError!void {
    const ap = try activePane(app);
    const p = ap.p;
    var pids: std.ArrayListUnmanaged(u32) = .empty;
    const arena = app.frame.allocator();
    if (p.multi.count() > 0) {
        for (p.rows) |r| if (r.pid) |pid| if (p.multi.contains(r.session_id)) try pids.append(arena, pid);
    } else {
        const row = p.selected() orelse return app.diag.fail(arena, "agents: no session selected", .{});
        if (row.pid) |pid| try pids.append(arena, pid);
    }
    if (pids.items.len == 0) return app.diag.fail(arena, "agents: nothing to kill (no live process)", .{});
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

/// The confirm's yes: `kill -TERM` each pid, then rescan.
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
    if (find(app)) |id| {
        if (app.panes.get(id)) |pane| switch (pane.*) {
            .claude_agents => |*p| clearMulti(p),
            else => {},
        };
        refresh(app, id) catch {};
    }
}

/// `e`: the transcript as markdown under `.mnml/claude-exports/`,
/// opened in an editor.
fn exportMarkdown(app: *App) CommandError!void {
    const s = try selectedRow(app);
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, s.row.transcript_path, gpa, .limited(64 * 1024 * 1024)) catch |err| return app.diag.fail(arena, "read {s}: {s}", .{ s.row.transcript_path, @errorName(err) });
    defer gpa.free(text);
    const md = try transcriptMarkdown(arena, s.row, text);
    const dir = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", "claude-exports" });
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    const short = s.row.session_id[0..@min(8, s.row.session_id.len)];
    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{d}.md", .{ dir, short, app.now_ms });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = md }) catch |err| return app.diag.fail(arena, "write {s}: {s}", .{ path, @errorName(err) });
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    app.toast("exported {s}", .{app.relPath(path)});
}

/// The transcript's user / assistant turns as markdown.
pub fn transcriptMarkdown(arena: Allocator, row: Row, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "# {s} session {s}\n\n_workspace: {s} · state: {s} · model: {s}_\n\n", .{ row.source.label(), row.session_id[0..@min(8, row.session_id.len)], row.workspace, @tagName(row.state), row.model orelse "?" });
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
        if (v != .object) continue;
        const ty = (v.object.get("type") orelse continue);
        if (ty != .string) continue;
        const msg = v.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        if (std.mem.eql(u8, ty.string, "user")) {
            const txt: ?[]const u8 = switch (content) {
                .string => |s| s,
                .array => |arr| blk: {
                    for (arr.items) |b| if (b == .object) if (b.object.get("type")) |bt| if (bt == .string and std.mem.eql(u8, bt.string, "text")) if (b.object.get("text")) |tx| if (tx == .string) break :blk tx.string;
                    break :blk null;
                },
                else => null,
            };
            const s = txt orelse continue;
            if (std.mem.startsWith(u8, s, "<system-reminder>")) continue;
            try out.print(arena, "## User\n\n{s}\n\n", .{s});
        } else if (std.mem.eql(u8, ty.string, "assistant")) {
            if (content != .array) continue;
            var header = false;
            for (content.array.items) |b| {
                if (b != .object) continue;
                const bt = b.object.get("type") orelse continue;
                if (bt != .string) continue;
                if (std.mem.eql(u8, bt.string, "text")) {
                    const tx = b.object.get("text") orelse continue;
                    if (tx != .string) continue;
                    if (!header) {
                        try out.appendSlice(arena, "## Assistant\n\n");
                        header = true;
                    }
                    try out.print(arena, "{s}\n\n", .{tx.string});
                } else if (std.mem.eql(u8, bt.string, "tool_use")) {
                    const name = b.object.get("name") orelse continue;
                    if (name != .string) continue;
                    if (!header) {
                        try out.appendSlice(arena, "## Assistant\n\n");
                        header = true;
                    }
                    try out.print(arena, "_tool: {s}_\n\n", .{name.string});
                }
            }
        }
    }
    return out.items;
}

fn newFromPr(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "agents: new session from a PR (Agent SDK) is not in this build yet", .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn fakeRow(arena: Allocator, sid: []const u8, ws: []const u8, source: Source, state: AgentState, tokens: u64, at: i64) !Row {
    return .{
        .source = source,
        .session_id = try arena.dupe(u8, sid),
        .workspace = try arena.dupe(u8, ws),
        .cwd = null,
        .model = "claude-sonnet-4-5",
        .transcript_path = "/nowhere",
        .state = state,
        .pid = null,
        .tokens = tokens,
        .cost_usd = @as(f64, @floatFromInt(tokens)) / 1000.0,
        .last_activity_s = at,
        .last_user_msg = "please fix the build",
        .last_assistant_msg = null,
        .current_tool = null,
        .pending_tool_uses = 0,
    };
}

test "parsePs picks claude / codex processes and the --session-id they carry" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ps =
        \\  123 /usr/bin/zsh -l
        \\  456 claude --session-id 11111111-2222-3333-4444-555555555555 -p hi
        \\  789 /opt/homebrew/bin/codex exec fix
        \\  790 node /x/claude-thing
        \\  791 claude --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    ;
    const pids = try parsePs(arena.allocator(), ps);
    try t.expectEqual(@as(usize, 3), pids.len);
    try t.expectEqual(@as(u32, 456), pids[0].pid);
    try t.expectEqualStrings("11111111-2222-3333-4444-555555555555", pids[0].session_id.?);
    try t.expectEqual(Source.codex, pids[1].exe);
    try t.expect(pids[1].session_id == null);
    try t.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", pids[2].session_id.?);
    try t.expectEqual(AgentState.ended, deriveState(false, 0, true));
    try t.expectEqual(AgentState.tool_call, deriveState(true, 0, true));
    try t.expectEqual(AgentState.streaming, deriveState(true, 10, false));
    try t.expectEqual(AgentState.idle, deriveState(true, 600, false));
    try t.expectEqual(@as(?Source, .claude), cycleSource(null, true));
    try t.expectEqual(@as(?Source, .codex), cycleSource(.claude, true));
    try t.expectEqual(@as(?Source, null), cycleSource(.codex, true));
    try t.expectEqual(@as(?Source, .codex), cycleSource(null, false));
}

test "scanInto reads a fixture home: claude and codex sessions, the tail stats, ended without a pid" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const home = buf[0..n];
    try tmp.dir.createDirPath(t.io, ".claude/projects/-Users-me-Projects-mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".claude/projects/-Users-me-Projects-mnml/aaaaaaaa-0000-4000-8000-000000000001.jsonl", .data = transcript.claude_fixture });
    try tmp.dir.createDirPath(t.io, ".codex/sessions/2026/09/04");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".codex/sessions/2026/09/04/rollout-2026-09-04T10-00-00-bbbbbbbb-0000-4000-8000-000000000002.jsonl", .data = transcript.codex_fixture });
    const r = try ScanResult.create(t.allocator, 1, 0);
    defer r.destroy(t.allocator);
    try scanInto(t.io, t.allocator, home, "/w", r);
    try t.expectEqual(@as(usize, 2), r.rows.len);
    var claude_seen = false;
    var codex_seen = false;
    for (r.rows) |row| switch (row.source) {
        .claude => {
            claude_seen = true;
            try t.expectEqualStrings("mnml", row.workspace);
            try t.expectEqualStrings("aaaaaaaa-0000-4000-8000-000000000001", row.session_id);
            try t.expectEqual(@as(u64, 1620), row.tokens);
            try t.expectEqual(AgentState.ended, row.state);
            try t.expectEqualStrings("fix the build", row.last_user_msg.?);
        },
        .codex => {
            codex_seen = true;
            try t.expectEqualStrings("app", row.workspace);
            try t.expectEqualStrings("bbbbbbbb-0000-4000-8000-000000000002", row.session_id);
            try t.expectEqualStrings("gpt-5", row.model.?);
        },
    };
    try t.expect(claude_seen and codex_seen);
}

test "filters and sort: state / source / workspace / query narrow the visible rows; the chips and title follow" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/Users/me/Projects/mnml", .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.dashboard" });
    const id = find(&app).?;
    const p = &app.panes.get(id).?.claude_agents;
    try t.expect(p.home == null); // the test app has no home: no scan
    const a = p.snapshot.allocator();
    const rows = try a.alloc(Row, 3);
    rows[0] = try fakeRow(a, "s-one", "mnml", .claude, .ended, 100, 10);
    rows[1] = try fakeRow(a, "s-two", "other", .codex, .streaming, 5000, 30);
    rows[2] = try fakeRow(a, "s-three", "mnml", .claude, .idle, 900, 20);
    p.rows = rows;
    try refilter(&app, p);
    // Sorted by state rank: live, idle, ended.
    try t.expectEqualSlices(u32, &.{ 1, 2, 0 }, p.visible.items);
    // A right-click on a row opens the session menu, titled by the row.
    try click(&app, id, p, row_base + 1, .{ .kind = .press, .button = .right, .x = 10, .y = 5 });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(@as(usize, 1), p.cursor);
    try t.expectEqual(@as(usize, 7), app.overlay.menu.items.len);
    try t.expectEqualStrings("Open transcript", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("Kill session…", app.overlay.menu.items[5].label);
    try t.expectEqual(command.CommandId.@"ai.dashboard.kill", app.overlay.menu.items[5].action.command);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.focus = .{ .pane = id };
    p.cursor = 0;
    try app.handle(.{ .key = Key.char('W') });
    try t.expectEqualSlices(u32, &.{ 2, 0 }, p.visible.items);
    try app.handle(.{ .key = Key.char('W') });
    try app.handle(.{ .key = Key.char('>') });
    try t.expectEqual(@as(?Source, .claude), p.source_filter);
    try t.expectEqualSlices(u32, &.{ 2, 0 }, p.visible.items);
    try app.handle(.{ .key = Key.char('>') });
    try t.expectEqualSlices(u32, &.{1}, p.visible.items);
    try app.handle(.{ .key = Key.char('>') });
    try t.expect(p.source_filter == null);
    try app.handle(.{ .key = Key.char('4') });
    try t.expectEqualSlices(u32, &.{0}, p.visible.items);
    try app.handle(.{ .key = Key.char('0') });
    try app.handle(.{ .key = Key.char('s') });
    try t.expectEqual(Sort.tokens, p.sort);
    try t.expectEqualSlices(u32, &.{ 1, 2, 0 }, p.visible.items);
    // The query: typed in filter mode, applied live, Enter keeps it, Esc clears it.
    try app.handle(.{ .key = Key.char('/') });
    try t.expect(p.filter_mode and p.paused());
    for ("other") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqualSlices(u32, &.{1}, p.visible.items);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "paused (filter)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "enter applies") != null);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(!p.filter_mode and !p.paused());
    try t.expectEqualStrings("other", p.query.items);
    try app.handle(.{ .key = Key.char('/') });
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(@as(usize, 0), p.query.items.len);
    try t.expectEqual(@as(usize, 3), p.visible.items.len);
    // Multi-select and clear.
    try app.handle(.{ .key = Key.char(' ') });
    try t.expectEqual(@as(usize, 1), p.multi.count());
    try app.handle(.{ .key = Key.char('R') });
    try t.expectEqual(@as(usize, 0), p.multi.count());
    // Help overlay and the source-filter row.
    try app.handle(.{ .key = Key.char('?') });
    try app.render();
    const help = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(help);
    try t.expect(std.mem.indexOf(u8, help, "Claude Agents — help") != null);
    try t.expect(std.mem.indexOf(u8, help, "all → claude → codex → all") != null);
    try app.handle(.{ .key = Key.char('?') });
    try t.expect(!p.help);
}

test "a scan result for a stale generation is dropped; the live one is adopted and the selection follows its session" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/w", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"ai.dashboard" });
    const id = find(&app).?;
    const p = &app.panes.get(id).?.claude_agents;
    p.generation = 5;
    const stale = try ScanResult.create(t.allocator, 4, id);
    stale.rows = try stale.arena.allocator().dupe(Row, &.{try fakeRow(stale.arena.allocator(), "old", "w", .claude, .idle, 1, 1)});
    try app.handle(.{ .agents = stale });
    try t.expectEqual(@as(usize, 0), p.rows.len);
    const live = try ScanResult.create(t.allocator, 5, id);
    const la = live.arena.allocator();
    live.rows = try la.dupe(Row, &.{ try fakeRow(la, "s-a", "w", .claude, .ended, 1, 1), try fakeRow(la, "s-b", "w", .claude, .streaming, 2, 2) });
    try app.handle(.{ .agents = live });
    try t.expectEqual(@as(usize, 2), p.rows.len);
    try t.expectEqualStrings("s-b", p.selected().?.session_id);
    try app.handle(.{ .key = Key.char('j') });
    try t.expectEqualStrings("s-a", p.selected().?.session_id);
    // A rescan that reorders keeps the cursor on s-a.
    const again = try ScanResult.create(t.allocator, 5, id);
    const aa = again.arena.allocator();
    again.rows = try aa.dupe(Row, &.{ try fakeRow(aa, "s-a", "w", .claude, .streaming, 1, 9), try fakeRow(aa, "s-b", "w", .claude, .idle, 2, 2), try fakeRow(aa, "s-c", "w", .codex, .ended, 3, 3) });
    try app.handle(.{ .agents = again });
    try t.expectEqualStrings("s-a", p.selected().?.session_id);
    try t.expectEqual(@as(usize, 0), p.cursor);
    // A result for a pane that is gone is freed, not adopted.
    const orphan = try ScanResult.create(t.allocator, 5, 99);
    try app.handle(.{ .agents = orphan });
}

test "transcriptMarkdown renders the turns" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const row = try fakeRow(arena.allocator(), "abcdefgh-1", "mnml", .claude, .ended, 0, 0);
    const md = try transcriptMarkdown(arena.allocator(), row, transcript.claude_fixture);
    try t.expect(std.mem.startsWith(u8, md, "# claude session abcdefgh"));
    try t.expect(std.mem.indexOf(u8, md, "## User\n\nfix the build") != null);
    try t.expect(std.mem.indexOf(u8, md, "## Assistant\n\nLooking now.") != null);
    try t.expect(std.mem.indexOf(u8, md, "_tool: Bash_") != null);
}
