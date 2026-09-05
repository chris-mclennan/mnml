//! Git state (D7): the repos the workspace knows, which one is active,
//! the status snapshot for the rail / statusline / gutter, blame per
//! editor pane, and the state of the three git panes. Everything that
//! talks to `git` goes through a `client.Repo` worker; this file only
//! submits jobs and adopts what comes back — no git on the UI thread.
//!
//! Written against `src/todos.zig` (D8): the worker posts an owned
//! payload, `handle` adopts or destroys it on every path, the status
//! snapshot is one arena replaced wholesale, and the rail is a
//! `ListPanel`. Where git needs more than TODOS did — several repos,
//! results routed to a pane, a picker whose meaning depends on the
//! command that asked — the extra lives here, not in the trunk.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const PaneId = app_mod.PaneId;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("../core/alloc.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const hooks = @import("../core/hooks.zig");
const client = @import("../git/client.zig");
const parse = @import("../git/parse.zig");
const remote_mod = @import("../git/remote.zig");
const ai_app = @import("ai.zig");
const cmd_app = @import("cmd_app.zig");
const builtin = @import("builtin");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const chip = @import("../ui/chip.zig");
const status_view = @import("../ui/git_status_view.zig");
const diff_view = @import("../ui/diff_view.zig");
const graph_view = @import("../ui/git_graph_view.zig");
const editor_view = @import("../ui/editor_view.zig");
const cmd_picker = @import("cmd_picker.zig");

pub const Row = status_view.Row;
pub const RailSection = status_view.RailSection;
pub const Panel = list_panel.ListPanel(Row);

/// How long a status snapshot is trusted before `tick` asks again.
pub const status_ttl_ms: i64 = 3000;
/// A second click on the selected row within this window opens it.
const double_click_ms: i64 = 500;
/// How many commits the graph asks for.
pub const graph_limit: u32 = 500;
/// Sub-repo discovery stops this deep.
const max_discover_depth: usize = 3;
const skip_dirs = [_][]const u8{ "node_modules", "target", "zig-out", "vendor", "dist", "build" };

/// What the one git picker is for; `acceptPick` switches on it.
pub const Pick = enum {
    none,
    checkout,
    recent,
    merge,
    rebase,
    delete_branch,
    graph_branch,
    stash_apply,
    stash_drop,
    tag_delete,
    reflog,
    worktree_open,
    worktree_remove,
    worktree_shell,
    switch_repo,
    file_history,
};

pub const PromptKind = enum {
    none,
    commit,
    stash,
    new_branch,
    tag,
    graph_author,
    graph_subject,
    graph_date,
    worktree_add,
    /// The graph's hash-jump.
    graph_hash,
    /// `commit --amend` with the AI's rewrite.
    amend,
};

/// A confirm box's payload; the path is owned.
pub const Confirm = union(enum) {
    none,
    discard: []u8,
    discard_hunk: struct { pane: PaneId },
    delete_branch: []u8,
    worktree_remove: []u8,
    /// A branch-rail row: checkout after a yes.
    checkout: []u8,

    pub fn deinit(c: Confirm, gpa: Allocator) void {
        switch (c) {
            .discard, .delete_branch, .worktree_remove, .checkout => |s| gpa.free(s),
            .none, .discard_hunk => {},
        }
    }
};

/// An AI commit-message job in flight: the `Pane.ai` it streams into
/// and what to do with the answer when the pane says done.
pub const AiWait = struct {
    pane: PaneId,
    what: enum { commit, recompose },
};

/// Blame for one editor pane: the worker's arena, adopted.
pub const Blame = struct {
    arena: std.heap.ArenaAllocator,
    lines: []parse.BlameLine,
};

// ─── the panes ──────────────────────────────────────────────────────────

/// `Pane.git_status`: the rail's rows as a pane. Rows come from
/// `State` (the active repo's), the cursor is the pane's own.
pub const StatusPane = struct {
    repo: u32,
    cursor: usize = 0,
    scroll: usize = 0,
};

/// `Pane.diff`: one diff — a file, the worktree, HEAD, the index, a
/// commit, or the buffer against the disk. The worker's arena is
/// adopted on every refresh.
pub const DiffPane = struct {
    gpa: Allocator,
    repo: u32,
    scope: client.DiffScope,
    path: ?[]u8 = null,
    rev: ?[]u8 = null,
    /// The tab label. Owned.
    title: []u8,
    arena: std.heap.ArenaAllocator,
    files: []parse.FileDiff = &.{},
    rows: []diff_view.Row = &.{},
    /// The split view's aligned rows; borrows `arena` like `rows`.
    split_rows: []diff_view.SplitRow = &.{},
    /// Indices into `rows` / `split_rows` that pass the filter. Owned.
    shown: []u32 = &.{},
    split_shown: []u32 = &.{},
    view: diff_view.State = .{},
    mode: diff_view.Mode = .hunk,
    /// The loaded diff carries every line (Inline / Split asked for it).
    full: bool = false,
    /// The old side's share of the split body, in percent.
    ratio: u16 = 50,
    /// Index into `rows` (Hunk / Inline) or `split_rows` (Split).
    cursor: usize = 0,
    pending: bool = true,
    /// `]` / `[` typed, waiting for `c` / `f`.
    bracket: ?u8 = null,
    /// The `/` filter: the needle, and whether keys go to it.
    filter: std.ArrayListUnmanaged(u8) = .empty,
    filter_mode: bool = false,
    /// What the last frame measured, for the divider drag and the strip.
    body: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    strip_cells: u16 = 0,

    pub fn deinit(self: *DiffPane) void {
        if (self.path) |p| self.gpa.free(p);
        if (self.rev) |r| self.gpa.free(r);
        self.gpa.free(self.title);
        self.gpa.free(self.shown);
        self.gpa.free(self.split_shown);
        self.filter.deinit(self.gpa);
        self.arena.deinit();
    }

    /// The row list the cursor walks in the current view.
    pub fn rowCount(self: *const DiffPane) usize {
        return if (self.mode == .split) self.split_rows.len else self.rows.len;
    }

    pub fn shownRows(self: *const DiffPane) []const u32 {
        return if (self.mode == .split) self.split_shown else self.shown;
    }
};

/// A commit's detail: the worker's arena, adopted into `detail_arena`.
pub const Detail = struct {
    sha: []const u8,
    message: []const u8,
    files: []parse.DetailFile,
};

/// `Pane.git_graph`: the commit DAG of one repo, with its filters, its
/// sort, the detail panel and the working-tree row. The cursor walks
/// the *virtual* rows: the WIP row first when there is one, then the
/// commits in display order.
pub const GraphPane = struct {
    gpa: Allocator,
    repo: u32,
    arena: std.heap.ArenaAllocator,
    commits: []parse.Commit = &.{},
    lanes: []graph_view.Lane = &.{},
    /// Display order: indices into `commits`; borrows `arena`.
    order: []u32 = &.{},
    sort: graph_view.Sort = .{},
    view: graph_view.State = .{},
    cursor: usize = 0,
    pending: bool = true,
    filter: client.LogFilter = .{},
    /// The detail panel.
    detail_arena: std.heap.ArenaAllocator,
    detail: ?Detail = null,
    detail_pending: bool = false,
    detail_open: bool = false,
    detail_focus: bool = false,
    detail_cursor: usize = 0,
    /// A drag override of the panel's width.
    detail_w: ?u16 = null,
    /// The working-tree row is shown (the status has changes).
    has_wip: bool = false,
    /// A status has been seen: from here a WIP row appearing or going
    /// shifts the cursor so it keeps its commit.
    wip_known: bool = false,
    /// What the last frame measured, for the divider drag.
    body: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn deinit(self: *GraphPane) void {
        self.filter.deinit(self.gpa);
        self.detail_arena.deinit();
        self.arena.deinit();
    }

    fn wipRows(self: *const GraphPane) usize {
        return if (self.has_wip) 1 else 0;
    }

    pub fn totalRows(self: *const GraphPane) usize {
        return self.commits.len + self.wipRows();
    }

    pub fn wipSelected(self: *const GraphPane) bool {
        return self.has_wip and self.cursor == 0;
    }

    /// The commit under the cursor (none on the WIP row).
    pub fn selected(self: *const GraphPane) ?parse.Commit {
        const i = self.selectedIndex() orelse return null;
        return self.commits[i];
    }

    /// Index into `commits` of the row under the cursor.
    pub fn selectedIndex(self: *const GraphPane) ?usize {
        if (self.cursor < self.wipRows()) return null;
        const pos = self.cursor - self.wipRows();
        if (pos >= self.order.len) return null;
        return self.order[pos];
    }

    /// The virtual row of commit `ci`.
    pub fn rowOfCommit(self: *const GraphPane, ci: usize) usize {
        for (self.order, 0..) |o, pos| if (o == ci) return pos + self.wipRows();
        return self.wipRows();
    }
};

// ─── state ──────────────────────────────────────────────────────────────

pub const State = struct {
    repos: std.ArrayListUnmanaged(*client.Repo) = .empty,
    next_id: u32 = 1,
    /// Index into `repos`.
    active: ?usize = null,
    discovered: bool = false,
    /// D1: the status snapshot — the worker's arena, adopted whole.
    snapshot: alloc.SnapshotArena,
    status: ?parse.Status = null,
    /// The repo `status` describes.
    status_repo: u32 = 0,
    /// Repo-relative path → gutter marks. Keys and values borrow the
    /// snapshot; the map itself is gpa and is cleared with it.
    marks: std.StringHashMapUnmanaged([]const parse.GutterMark) = .empty,
    status_at_ms: i64 = 0,
    status_pending: bool = false,
    /// Rail rows built from `status`; `path` borrows the snapshot.
    rows: std.ArrayListUnmanaged(Row) = .empty,
    filtered: std.ArrayListUnmanaged(u32) = .empty,
    rail: Panel.State = .{},
    collapsed: std.enums.EnumSet(parse.Group) = .initEmpty(),
    blames: std.AutoHashMapUnmanaged(PaneId, Blame) = .empty,
    /// The pane a blame was asked for, until it lands.
    blame_pending: ?PaneId = null,
    pick: Pick = .none,
    prompt: PromptKind = .none,
    confirm: Confirm = .none,
    /// Which command is waiting on the next `.branches` / `.list` /
    /// `.log` result to open its picker.
    awaiting: Pick = .none,
    /// Mutating jobs in flight (a spinner on the rail).
    busy: u32 = 0,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,
    /// The view the last diff pane was switched to; new panes open in it.
    diff_mode: diff_view.Mode = .hunk,
    /// `remote.origin.url` as the last status reported (borrows the
    /// snapshot) and the forge it names, for the badge.
    remote: []const u8 = "",
    provider: remote_mod.Provider = .none,
    /// The AI commit-message job whose pane `tick` watches.
    ai_wait: ?AiWait = null,
    ai_product: ai_app.Product = .claude,
    /// A message body the AI returned, appended to the prompt's subject
    /// line at accept. Owned.
    ai_body: ?[]u8 = null,
    /// The branch rail: open or folded, its own snapshot, and which of
    /// its sections are folded.
    rail_open: bool = false,
    rail_pending: bool = false,
    rail_snapshot: alloc.SnapshotArena,
    rail_branches: []parse.Branch = &.{},
    rail_worktrees: []const []const u8 = &.{},
    rail_prs: []parse.Pr = &.{},
    /// The rail was asked for without `gh`; said once.
    rail_gh_toasted: bool = false,
    rail_loaded: bool = false,
    rail_folded: std.enums.EnumSet(RailSection) = .initEmpty(),

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa), .rail_snapshot = alloc.SnapshotArena.init(gpa) };
    }

    /// Stops every worker first: they borrow `app.events` and post into it.
    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        for (self.repos.items) |r| r.destroy(io);
        self.repos.deinit(gpa);
        var it = self.blames.valueIterator();
        while (it.next()) |b| b.arena.deinit();
        self.blames.deinit(gpa);
        self.marks.deinit(gpa);
        self.rows.deinit(gpa);
        self.filtered.deinit(gpa);
        self.rail.deinit(gpa);
        self.confirm.deinit(gpa);
        if (self.ai_body) |b| gpa.free(b);
        self.rail_snapshot.deinit();
        self.snapshot.deinit();
    }

    pub fn activeRepo(self: *const State) ?*client.Repo {
        const i = self.active orelse return null;
        if (i >= self.repos.items.len) return null;
        return self.repos.items[i];
    }

    pub fn repoById(self: *const State, id: u32) ?*client.Repo {
        for (self.repos.items) |r| if (r.id == id) return r;
        return null;
    }

    pub fn indexOfId(self: *const State, id: u32) ?usize {
        for (self.repos.items, 0..) |r, i| if (r.id == id) return i;
        return null;
    }

    /// The rail row under the cursor, in display order.
    pub fn selectedRow(self: *const State) ?Row {
        if (self.rail.cursor >= self.filtered.items.len) return null;
        return self.rows.items[self.filtered.items[self.rail.cursor]];
    }

    /// The branch for the statusline: the name, `@sha` when detached,
    /// null outside a repo or before the first status lands.
    pub fn branchLabel(self: *const State) ?[]const u8 {
        const st = self.status orelse return null;
        if (st.branch) |b| return b;
        if (st.detached) return "(detached)";
        return null;
    }

    /// Changed files, for the activity badge.
    pub fn badge(self: *const State) u32 {
        const st = self.status orelse return 0;
        return st.changeCount();
    }
};

// ─── repos: discovery + switching ───────────────────────────────────────

/// Rust's rule: the workspace is a repo → that alone; otherwise every
/// repo up to three levels down, sorted by name. Existing `Repo`s are
/// kept (their worker and undo stack with them); repos gone are stopped.
pub fn discover(app: *App) Allocator.Error!void {
    const st = &app.git;
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    var found: std.ArrayListUnmanaged(Found) = .empty;
    if (hasDotGit(app.io, app.workspace)) {
        try found.append(arena, .{ .path = app.workspace, .name = std.fs.path.basename(app.workspace), .root = true });
    } else {
        try walkRepos(app, arena, app.workspace, 0, &found);
        std.mem.sort(Found, found.items, {}, struct {
            fn lt(_: void, a: Found, b: Found) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt);
    }
    // Every extra workspace root brings its repo (or the repos under it).
    for (app.tree.roots.items) |r| {
        if (hasDotGit(app.io, r.path)) {
            try found.append(arena, .{ .path = r.path, .name = r.name, .root = false });
        } else {
            try walkRepos(app, arena, r.path, 0, &found);
        }
    }
    const active_path: ?[]const u8 = if (st.activeRepo()) |r| try arena.dupe(u8, r.path) else null;
    var fresh: std.ArrayListUnmanaged(*client.Repo) = .empty;
    errdefer fresh.deinit(gpa);
    for (found.items) |f| {
        var kept: ?*client.Repo = null;
        for (st.repos.items, 0..) |r, i| if (std.mem.eql(u8, r.path, f.path)) {
            kept = r;
            _ = st.repos.orderedRemove(i);
            break;
        };
        const r = kept orelse blk: {
            const r = try client.Repo.create(gpa, f.path, f.name, st.next_id, f.root);
            st.next_id += 1;
            break :blk r;
        };
        errdefer if (kept == null) r.destroy(app.io);
        try fresh.append(gpa, r);
    }
    for (st.repos.items) |gone| gone.destroy(app.io);
    st.repos.deinit(gpa);
    st.repos = fresh;
    st.discovered = true;
    st.active = null;
    if (active_path) |p| for (st.repos.items, 0..) |r, i| if (std.mem.eql(u8, r.path, p)) {
        st.active = i;
    };
    if (st.active == null and st.repos.items.len > 0) st.active = 0;
    if (st.activeRepo()) |r| if (r.id != st.status_repo) clearStatus(app);
    if (st.repos.items.len == 0) clearStatus(app);
    app.needs_render = true;
}

const Found = struct { path: []const u8, name: []const u8, root: bool };

fn walkRepos(app: *App, arena: Allocator, dir_path: []const u8, depth: usize, out: *std.ArrayListUnmanaged(Found)) Allocator.Error!void {
    if (depth > max_discover_depth) return;
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (name.len > 0 and name[0] == '.') continue;
        var skip = false;
        for (skip_dirs) |s| if (std.mem.eql(u8, name, s)) {
            skip = true;
        };
        if (skip) continue;
        const sub = try std.fs.path.join(arena, &.{ dir_path, name });
        if (hasDotGit(app.io, sub)) {
            try out.append(arena, .{ .path = sub, .name = try arena.dupe(u8, name), .root = false });
            continue;
        }
        try walkRepos(app, arena, sub, depth + 1, out);
    }
}

/// `.git` may be a directory or, in a linked worktree, a file.
fn hasDotGit(io: Io, dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch return false;
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

/// The nearest ancestor of `path` (a file or directory) that is a repo
/// root, on the frame arena.
pub fn repoAbove(app: *App, path: []const u8) Allocator.Error!?[]const u8 {
    var dir: []const u8 = if (std.fs.path.dirname(path)) |d| d else path;
    while (true) {
        if (hasDotGit(app.io, dir)) return try app.frame.allocator().dupe(u8, dir);
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
}

/// The active repo, discovering on first use and — when the workspace
/// holds none — walking up from it (mnml opened on a sub-directory).
/// The one place a git command learns there is no repository.
pub fn requireRepo(app: *App) CommandError!*client.Repo {
    const st = &app.git;
    if (st.activeRepo()) |r| return r;
    try discover(app);
    if (st.activeRepo()) |r| return r;
    if (try repoAbove(app, app.workspace)) |root| {
        const r = try client.Repo.create(app.gpa, root, std.fs.path.basename(root), st.next_id, false);
        errdefer r.destroy(app.io);
        st.next_id += 1;
        try st.repos.append(app.gpa, r);
        st.active = st.repos.items.len - 1;
        return r;
    }
    return app.diag.fail(app.frame.allocator(), "not a git repository", .{});
}

/// Make `idx` the active repo: the rail, the statusline and the gutter
/// follow; the status pane retargets.
pub fn switchTo(app: *App, idx: usize) CommandError!void {
    const st = &app.git;
    if (idx >= st.repos.items.len) return;
    const was = st.active;
    st.active = idx;
    const r = st.repos.items[idx];
    if (was != idx) {
        clearStatus(app);
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .git_status => |*s| s.repo = r.id,
            else => {},
        };
        try requestStatus(app);
        app.toast("active repo → {s}", .{r.name});
    }
    app.needs_render = true;
}

/// D10.2: the file just opened may live in another discovered repo.
pub fn onOpen(app: *App, args: hooks.HookArgs) void {
    const st = &app.git;
    if (st.repos.items.len < 2) return;
    const abs = app.absPath(args.open.path) catch return;
    var best: ?usize = null;
    var best_len: usize = 0;
    for (st.repos.items, 0..) |r, i| {
        if (std.mem.startsWith(u8, abs, r.path) and abs.len > r.path.len and abs[r.path.len] == '/' and r.path.len > best_len) {
            best = i;
            best_len = r.path.len;
        }
    }
    if (best) |i| if (st.active != i) switchTo(app, i) catch {};
}

/// D10.2: a save changes the status and the gutter; a blamed buffer
/// is re-blamed so its gutter keeps up.
pub fn onSavePost(app: *App, args: hooks.HookArgs) void {
    const st = &app.git;
    if (st.activeRepo() == null) return;
    requestStatus(app) catch {};
    const pane: PaneId = args.save_post.pane;
    if (st.blames.contains(pane)) {
        if (app.panes.editor(pane)) |e| if (e.buf.path) |p| {
            requestBlame(app, pane, p) catch {};
        };
    }
}

// ─── submitting jobs ────────────────────────────────────────────────────

/// Queue `job` on `repo`, starting its worker if needed. The job's
/// strings are the worker's from here.
pub fn submit(app: *App, repo: *client.Repo, job: client.Job) CommandError!void {
    repo.start(app.io, &app.events, &app.env) catch |err| {
        job.deinit(app.gpa);
        return app.diag.fail(app.frame.allocator(), "git: could not start the worker: {s}", .{@errorName(err)});
    };
    if (!repo.submit(app.io, job)) return app.diag.fail(app.frame.allocator(), "git: the job queue is full", .{});
    app.needs_render = true;
}

/// A mutating job: counted for the spinner; its `op` result refreshes.
pub fn submitOp(app: *App, repo: *client.Repo, job: client.Job) CommandError!void {
    try submit(app, repo, job);
    app.git.busy += 1;
}

/// Ask the active repo for its status, unless one is already on the way.
pub fn requestStatus(app: *App) CommandError!void {
    const st = &app.git;
    const r = st.activeRepo() orelse return;
    if (st.status_pending) return;
    st.status_pending = true;
    st.status_at_ms = app.now_ms;
    submit(app, r, .status) catch |err| {
        st.status_pending = false;
        return err;
    };
}

pub fn requestBlame(app: *App, pane: PaneId, abs_path: []const u8) CommandError!void {
    const r = try requireRepo(app);
    const rel = relToRepo(r, abs_path);
    const owned = try app.gpa.dupe(u8, rel);
    app.git.blame_pending = pane;
    try submit(app, r, .{ .blame = owned });
}

/// Wall-clock seconds, for the age columns.
pub fn nowUnix(app: *App) i64 {
    return Io.Timestamp.now(app.io, .real).toSeconds();
}

/// Repo-relative path of an absolute one (the path itself when outside).
pub fn relToRepo(r: *const client.Repo, abs: []const u8) []const u8 {
    if (std.mem.startsWith(u8, abs, r.path) and abs.len > r.path.len and abs[r.path.len] == '/') return abs[r.path.len + 1 ..];
    return abs;
}

/// The 3 s TTL: a stale snapshot of the active repo is asked for again.
/// An AI commit-message pane that finished hands its answer over.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    const st = &app.git;
    try pollAiWait(app);
    if (st.activeRepo() == null or st.status_pending) return;
    if (now - st.status_at_ms >= status_ttl_ms) requestStatus(app) catch {};
}

// ─── the platform opener ────────────────────────────────────────────────

/// Hand a URL to the OS: `open` / `xdg-open` / `cmd /c start`. Only
/// plain http(s) goes out — anything else is a toast, not a spawn.
pub fn openExternal(app: *App, url: []const u8) void {
    if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) {
        app.toast("not a web URL: {s}", .{url});
        return;
    }
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    const res = std.process.run(app.gpa, app.io, .{ .argv = argv, .cwd = .{ .path = app.workspace }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch |err| {
        app.toast("could not open a browser: {s}", .{@errorName(err)});
        return;
    };
    app.gpa.free(res.stdout);
    app.gpa.free(res.stderr);
}

// ─── AI commit messages ─────────────────────────────────────────────────

/// Ask the repo for the text the prompt is built from; the answer lands
/// in `aiContextReady`, which starts the AI job.
pub fn askAi(app: *App, what: client.AiContext, product: ai_app.Product) CommandError!void {
    const st = &app.git;
    if (st.ai_wait != null) return app.diag.fail(app.frame.allocator(), "an AI commit message is already on its way", .{});
    const repo = try requireRepo(app);
    // Fail fast on a route that cannot run, before any git runs.
    switch (ai_app.route(app, if (product == .claude) .claude else .codex)) {
        .off => return app.diag.fail(app.frame.allocator(), "AI is routed off ([ai.routing.{s}] backend = \"off\")", .{@tagName(product)}),
        .api => if (product == .codex) return app.diag.fail(app.frame.allocator(), "Codex has no API backend in this build", .{}),
        .cli => {},
    }
    st.ai_product = product;
    try submit(app, repo, .{ .ai_context = what });
    app.toast("{s}: reading the {s}…", .{ if (product == .claude) "claude" else "codex", if (what == .staged) "staged diff" else "HEAD patch" });
}

const ai_diff_cap: usize = 24_000;

fn aiContextReady(app: *App, repo: *client.Repo, what: client.AiContext, diff: []const u8, message: []const u8) Allocator.Error!void {
    const st = &app.git;
    const arena = app.frame.allocator();
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        app.toast("{s}", .{if (what == .staged) "nothing staged — stage some changes first" else "HEAD has no patch to summarise"});
        return;
    }
    const cut = diff[0..@min(diff.len, ai_diff_cap)];
    const tail: []const u8 = if (diff.len > ai_diff_cap) "\n…(diff truncated)…" else "";
    const prompt = switch (what) {
        .staged => try std.fmt.allocPrint(arena, "Write a git commit message for the staged changes below. First line: imperative mood, ≤72 chars, no trailing period. Then a blank line and a short body ONLY if it adds something. Output ONLY the commit message — no preamble, no code fences.\n\n```diff\n{s}{s}\n```", .{ cut, tail }),
        .head => try std.fmt.allocPrint(arena, "Rewrite this commit's message based on what actually changed. First line: imperative mood, ≤72 chars, no trailing period. Then a blank line and a short body ONLY if it adds something the subject doesn't. Output ONLY the new message — no preamble, no code fences.\n\n{s}{s}{s}```diff\n{s}{s}\n```", .{ if (message.len > 0) "Current message:\n```\n" else "", message, if (message.len > 0) "\n```\n\n" else "", cut, tail }),
    };
    _ = repo;
    const title: []const u8 = if (what == .staged) "ai: commit message" else "ai: recompose HEAD";
    const pane = ai_app.askProduct(app, st.ai_product, title, prompt, .git, null) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        runToast(app, err);
        return;
    };
    st.ai_wait = .{ .pane = pane, .what = if (what == .staged) .commit else .recompose };
}

/// The AI pane finished: its answer becomes the commit prompt's text
/// (the subject on the line, the body kept for the accept), the pane
/// closes. A failed job toasts the AI track's reason.
fn pollAiWait(app: *App) Allocator.Error!void {
    const st = &app.git;
    const w = st.ai_wait orelse return;
    const pane = app.panes.get(w.pane) orelse {
        st.ai_wait = null;
        return;
    };
    const ap = switch (pane.*) {
        .ai => |*a| a,
        else => {
            st.ai_wait = null;
            return;
        },
    };
    switch (ap.status) {
        .running => return,
        .failed => {
            st.ai_wait = null;
            try app.toastLevel(.err, "AI: {s}", .{ap.err orelse "the job failed"});
            try app.closePane(w.pane, true);
        },
        .done => {
            st.ai_wait = null;
            const text = try app.gpa.dupe(u8, ap.answer.items);
            defer app.gpa.free(text);
            try app.closePane(w.pane, true);
            const msg = cleanCommitMessage(text);
            if (msg.subject.len == 0) {
                app.toast("AI returned an empty message", .{});
                return;
            }
            if (st.ai_body) |b| app.gpa.free(b);
            st.ai_body = if (msg.body.len > 0) try app.gpa.dupe(u8, msg.body) else null;
            const kind: PromptKind = if (w.what == .commit) .commit else .amend;
            const title: []const u8 = if (msg.body.len > 0)
                (if (kind == .commit) "Commit message (AI body attached)" else "Amend HEAD's message (AI body attached)")
            else
                (if (kind == .commit) "Commit message" else "Amend HEAD's message");
            openPrompt(app, kind, title);
            try app.overlay.prompt.state.setText(app.gpa, msg.subject);
        },
    }
}

/// The subject line and the body of what the model wrote, fences and
/// blank edges stripped.
pub fn cleanCommitMessage(text: []const u8) struct { subject: []const u8, body: []const u8 } {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "```")) {
        const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
        t = t[nl..];
    }
    if (std.mem.endsWith(u8, t, "```")) t = t[0 .. t.len - 3];
    t = std.mem.trim(u8, t, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    const subject = std.mem.trim(u8, t[0..nl], " \t\r");
    const body = std.mem.trim(u8, t[nl..], " \t\r\n");
    return .{ .subject = subject, .body = body };
}

/// The message a commit / amend prompt submits: the line typed, plus
/// the AI body when one is attached (consumed here).
fn takeMessage(app: *App, subject: []const u8) Allocator.Error![]u8 {
    const st = &app.git;
    defer {
        if (st.ai_body) |b| app.gpa.free(b);
        st.ai_body = null;
    }
    if (st.ai_body) |b| return std.fmt.allocPrint(app.gpa, "{s}\n\n{s}", .{ subject, b });
    return app.gpa.dupe(u8, subject);
}

// ─── the handler (D1) ───────────────────────────────────────────────────

/// `result` is ours: adopted into a snapshot / a pane, or destroyed —
/// on every path out of here. A result from a repo no longer known is
/// dropped whole.
pub fn handle(app: *App, result: *client.Result) Allocator.Error!void {
    const st = &app.git;
    const gpa = app.gpa;
    defer result.destroy(gpa);
    const repo = st.repoById(result.repo) orelse return;
    app.needs_render = true;
    switch (result.payload) {
        .status => |s| {
            const active = st.activeRepo() orelse return;
            if (active.id != repo.id) return;
            st.status_pending = false;
            st.status_at_ms = app.now_ms;
            adoptArena(&st.snapshot.arena, &result.arena, gpa);
            st.status = s.status;
            st.status_repo = repo.id;
            st.remote = s.remote;
            st.provider = remote_mod.providerOf(s.remote);
            st.marks.clearRetainingCapacity();
            for (s.signs) |f| {
                const marks = try parse.gutterMarks(st.snapshot.allocator(), f);
                try st.marks.put(gpa, f.path(), marks);
            }
            try rebuildRows(app);
            // Graph panes on this repo show or drop their WIP row now.
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .git_graph => |*g| if (g.repo == repo.id) syncWip(app, g),
                else => {},
            };
            app.hooks.emit(app, .{ .git_status = .{ .branch = s.status.branch orelse "", .dirty = s.status.changeCount() } });
        },
        .diff => |d| {
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .diff => |*dp| if (dp.repo == repo.id and dp.scope == d.scope and optEql(dp.path, d.path) and optEql(dp.rev, d.rev)) {
                    adoptArena(&dp.arena, &result.arena, gpa);
                    dp.files = d.files;
                    dp.rows = try diff_view.flatten(dp.arena.allocator(), d.files);
                    dp.split_rows = try diff_view.pairs(dp.arena.allocator(), d.files);
                    dp.full = d.full;
                    dp.pending = false;
                    try refilterDiff(app, dp);
                    // The result's arena is one pane's now; a second pane
                    // on the same diff refreshes on its own.
                    return;
                },
                else => {},
            };
        },
        .blame => |b| {
            const pane = st.blame_pending orelse return;
            st.blame_pending = null;
            if (b.lines.len == 0) {
                app.toast("git blame returned nothing (untracked file?)", .{});
                return;
            }
            const e = app.panes.editor(pane) orelse return;
            const abs = e.buf.path orelse return;
            if (!std.mem.eql(u8, relToRepo(repo, abs), b.path)) return;
            var blame: Blame = .{ .arena = .init(gpa), .lines = b.lines };
            adoptArena(&blame.arena, &result.arena, gpa);
            if (st.blames.fetchRemove(pane)) |old| {
                var o = old.value;
                o.arena.deinit();
            }
            try st.blames.put(gpa, pane, blame);
            app.toast("blame: on", .{});
        },
        .log => |l| {
            if (l.path != null and st.awaiting == .file_history) {
                st.awaiting = .none;
                try openCommitPicker(app, l.commits, .file_history);
                return;
            }
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .git_graph => |*g| if (g.repo == repo.id and g.pending) {
                    adoptArena(&g.arena, &result.arena, gpa);
                    g.commits = l.commits;
                    g.lanes = try graph_view.layout(g.arena.allocator(), l.commits);
                    g.order = try graph_view.sortOrder(g.arena.allocator(), l.commits, g.sort);
                    g.pending = false;
                    if (g.cursor >= g.totalRows()) g.cursor = g.totalRows() -| 1;
                    if (g.detail_open) requestDetail(app, g) catch {};
                    return;
                },
                else => {},
            };
        },
        .branches => |bs| {
            const what = st.awaiting;
            st.awaiting = .none;
            if (what == .none) return;
            try openBranchPicker(app, bs, what);
        },
        .list => |l| {
            const what = st.awaiting;
            st.awaiting = .none;
            if (what == .none) return;
            try openListPicker(app, l.kind, l.items, what);
        },
        .op => |op| {
            if (st.busy > 0) st.busy -= 1;
            if (op.ok) {
                app.toast("{s}", .{op.desc});
            } else if (op.msg.len > 0) {
                try app.toastLevel(.err, "{s}: {s}", .{ op.desc, op.msg });
            } else {
                app.toast("{s}", .{op.desc});
            }
            if (op.refresh) try afterChange(app, repo);
        },
        .url => |u| {
            openExternal(app, u);
            app.toast("{s}", .{u});
        },
        .commit_detail => |d| {
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .git_graph => |*g| if (g.repo == repo.id and g.detail_pending) {
                    g.detail_pending = false;
                    adoptArena(&g.detail_arena, &result.arena, gpa);
                    g.detail = .{ .sha = d.sha, .message = d.message, .files = d.files };
                    g.detail_cursor = 0;
                    g.view.detail_scroll = 0;
                    // The cursor moved on while this one was fetched.
                    if (g.selected()) |c| if (!std.mem.eql(u8, c.hash, d.sha)) requestDetail(app, g) catch {};
                    return;
                },
                else => {},
            };
        },
        .ai_context => |c| try aiContextReady(app, repo, c.what, c.diff, c.message),
        .rail => |rail| {
            st.rail_pending = false;
            const active = st.activeRepo() orelse return;
            if (active.id != repo.id) return;
            adoptArena(&st.rail_snapshot.arena, &result.arena, gpa);
            st.rail_branches = rail.branches;
            st.rail_worktrees = rail.worktrees;
            st.rail_prs = rail.prs;
            st.rail_loaded = true;
            if (!rail.gh and !st.rail_gh_toasted) {
                st.rail_gh_toasted = true;
                app.toast("open PRs need `gh` on PATH", .{});
            }
            try rebuildRows(app);
        },
        .head_sha => |sha| {
            if (sha.len == 0) return;
            try app.clipboard.setYank(sha, false);
            app.toast("copied {s}", .{sha});
        },
    }
}

/// Move `incoming`'s memory into `mine`; `incoming` is left empty so the
/// result's `destroy` frees nothing that is now ours.
fn adoptArena(mine: *std.heap.ArenaAllocator, incoming: *std.heap.ArenaAllocator, gpa: Allocator) void {
    mine.deinit();
    mine.* = incoming.*;
    incoming.* = .init(gpa);
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// After anything that changed the repo: a fresh status, and every
/// pane on that repo asks again.
pub fn afterChange(app: *App, repo: *client.Repo) Allocator.Error!void {
    const st = &app.git;
    if (st.activeRepo()) |a| if (a.id == repo.id) {
        st.status_pending = false;
        requestStatus(app) catch {};
        if (st.rail_open) requestRail(app) catch {};
    };
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .diff => |*dp| if (dp.repo == repo.id and dp.scope != .commit) refreshDiff(app, dp) catch {},
        .git_graph => |*g| if (g.repo == repo.id) refreshGraph(app, g) catch {},
        else => {},
    };
}

fn clearStatus(app: *App) void {
    const st = &app.git;
    st.status = null;
    st.status_pending = false;
    st.status_at_ms = 0;
    st.remote = "";
    st.provider = .none;
    st.rail_branches = &.{};
    st.rail_worktrees = &.{};
    st.rail_prs = &.{};
    st.rail_loaded = false;
    st.rail_pending = false;
    st.rail_snapshot.reset();
    st.marks.clearRetainingCapacity();
    st.rows.clearRetainingCapacity();
    st.filtered.clearRetainingCapacity();
    st.snapshot.reset();
    app.needs_render = true;
}

// ─── rail rows ──────────────────────────────────────────────────────────

/// Group headers then their entries, in the order the rail lists them.
/// A collapsed group keeps its header.
fn rebuildRows(app: *App) Allocator.Error!void {
    const st = &app.git;
    st.rows.clearRetainingCapacity();
    const status = st.status orelse return;
    for ([_]parse.Group{ .conflicted, .staged, .unstaged, .untracked }) |g| {
        var count: u32 = 0;
        for (status.entries) |e| if (e.group == g) {
            count += 1;
        };
        if (count == 0) continue;
        try st.rows.append(app.gpa, .{ .header = true, .group = g, .count = count });
        if (st.collapsed.contains(g)) continue;
        for (status.entries, 0..) |e, i| if (e.group == g) {
            try st.rows.append(app.gpa, .{ .header = false, .group = g, .code = e.code, .path = e.path, .entry = @intCast(i) });
        };
    }
    if (st.rail_open) try appendRailRows(app);
    try refilter(app);
}

/// The branch rail below the status groups: three section headers,
/// each folding its rows. Before the data lands the sections say so.
fn appendRailRows(app: *App) Allocator.Error!void {
    const st = &app.git;
    const gpa = app.gpa;
    const g: parse.Group = .unstaged;
    for ([_]RailSection{ .branches, .worktrees, .prs }) |sec| {
        const folded = st.rail_folded.contains(sec);
        const count: u32 = switch (sec) {
            .branches => @intCast(st.rail_branches.len),
            .worktrees => @intCast(st.rail_worktrees.len),
            .prs => @intCast(st.rail_prs.len),
        };
        try st.rows.append(gpa, .{ .header = true, .group = g, .kind = .section, .section = sec, .count = count, .folded = folded });
        if (folded) continue;
        if (!st.rail_loaded) {
            try st.rows.append(gpa, .{ .header = false, .group = g, .kind = .note, .section = sec, .path = if (st.rail_pending) "loading…" else "press r to load" });
            continue;
        }
        switch (sec) {
            .branches => for (st.rail_branches, 0..) |b, i| {
                const detail: []const u8 = if (b.gone) "gone" else if (b.ahead > 0 and b.behind > 0)
                    try std.fmt.allocPrint(st.rail_snapshot.allocator(), "↑{d} ↓{d}", .{ b.ahead, b.behind })
                else if (b.ahead > 0)
                    try std.fmt.allocPrint(st.rail_snapshot.allocator(), "↑{d}", .{b.ahead})
                else if (b.behind > 0)
                    try std.fmt.allocPrint(st.rail_snapshot.allocator(), "↓{d}", .{b.behind})
                else
                    "";
                try st.rows.append(gpa, .{ .header = false, .group = g, .kind = .branch, .section = sec, .path = b.name, .detail = detail, .current = b.current, .remote = b.remote, .entry = @intCast(i) });
            },
            .worktrees => for (st.rail_worktrees, 0..) |w, i| {
                const sep = std.mem.indexOfScalar(u8, w, '\x1f');
                const path = if (sep) |x| w[0..x] else w;
                const branch = if (sep) |x| w[x + 1 ..] else "";
                try st.rows.append(gpa, .{ .header = false, .group = g, .kind = .worktree, .section = sec, .path = path, .detail = branch, .current = i == 0, .entry = @intCast(i) });
            },
            .prs => {
                if (st.rail_prs.len == 0) {
                    try st.rows.append(gpa, .{ .header = false, .group = g, .kind = .note, .section = sec, .path = if (cmd_app.onPath(app, "gh")) "no open PRs" else "needs `gh` on PATH" });
                }
                for (st.rail_prs) |pr| {
                    try st.rows.append(gpa, .{ .header = false, .group = g, .kind = .pr, .section = sec, .path = pr.title, .detail = pr.branch, .entry = pr.number });
                }
            },
        }
    }
}

/// Ask the active repo for the rail's data, unless it is on the way.
pub fn requestRail(app: *App) CommandError!void {
    const st = &app.git;
    const r = st.activeRepo() orelse return;
    if (st.rail_pending) return;
    st.rail_pending = true;
    submit(app, r, .{ .rail = .{ .gh = cmd_app.onPath(app, "gh") } }) catch |err| {
        st.rail_pending = false;
        return err;
    };
    try rebuildRows(app);
}

/// Show or fold the branch rail; showing it fetches the data.
pub fn toggleRail(app: *App) CommandError!void {
    const st = &app.git;
    _ = try requireRepo(app);
    st.rail_open = !st.rail_open;
    if (st.rail_open) try requestRail(app) else try rebuildRows(app);
    app.needs_render = true;
}

/// The filter is a case-insensitive substring over the path; headers
/// stay while their group has a visible row.
pub fn refilter(app: *App) Allocator.Error!void {
    const st = &app.git;
    st.filtered.clearRetainingCapacity();
    const q = st.rail.filterText();
    var i: usize = 0;
    while (i < st.rows.items.len) : (i += 1) {
        const row = st.rows.items[i];
        if (row.header) {
            if (q.len == 0) {
                try st.filtered.append(app.gpa, @intCast(i));
                continue;
            }
            var any = false;
            var j = i + 1;
            while (j < st.rows.items.len and !st.rows.items[j].header) : (j += 1) {
                if (st.rows.items[j].kind != .note and containsIgnoreCase(st.rows.items[j].path, q)) any = true;
            }
            if (any) try st.filtered.append(app.gpa, @intCast(i));
            continue;
        }
        if (q.len == 0 or (row.kind != .note and containsIgnoreCase(row.path, q))) try st.filtered.append(app.gpa, @intCast(i));
    }
    if (st.rail.cursor >= st.filtered.items.len) st.rail.cursor = st.filtered.items.len -| 1;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .git_status => |*s| if (s.cursor >= st.rows.items.len) {
            s.cursor = st.rows.items.len -| 1;
        },
        else => {},
    };
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

/// Marks for the editor gutter of `abs_path`, from the active repo's
/// snapshot; empty outside it.
pub fn marksFor(app: *App, abs_path: []const u8) []const parse.GutterMark {
    const st = &app.git;
    const r = st.activeRepo() orelse return &.{};
    if (st.status_repo != r.id) return &.{};
    return st.marks.get(relToRepo(r, abs_path)) orelse &.{};
}

/// The active repo's marks for `abs_path` in the editor view's own type,
/// on the frame arena.
pub fn viewMarks(app: *App, abs_path: []const u8, arena: Allocator) Allocator.Error![]const editor_view.GutterMark {
    const marks = marksFor(app, abs_path);
    if (marks.len == 0) return &.{};
    const out = try arena.alloc(editor_view.GutterMark, marks.len);
    for (marks, 0..) |m, i| out[i] = .{ .line = m.line, .kind = switch (m.kind) {
        .added => .added,
        .modified => .modified,
        .deleted => .deleted,
    } };
    return out;
}

/// `<sha7> <author> <age>` per line for a blamed pane, on the frame
/// arena; null when blame is off.
pub fn blameLabels(app: *App, pane: PaneId, arena: Allocator) Allocator.Error!?[]const []const u8 {
    const b = app.git.blames.get(pane) orelse return null;
    const now = nowUnix(app);
    const out = try arena.alloc([]const u8, b.lines.len);
    for (b.lines, 0..) |l, i| {
        if (l.isUncommitted()) {
            out[i] = "• not committed";
            continue;
        }
        var age_buf: [16]u8 = undefined;
        const age = parse.relativeAge(&age_buf, l.time, now);
        out[i] = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ l.short(), l.author, age });
    }
    return out;
}

// ─── panes: opening + refreshing ────────────────────────────────────────

pub fn openDiff(app: *App, repo: *client.Repo, scope: client.DiffScope, rel: ?[]const u8, rev: ?[]const u8, text: ?[]const u8) CommandError!PaneId {
    const gpa = app.gpa;
    // An open pane on the same diff is revealed and refreshed.
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .diff => |*dp| if (dp.repo == repo.id and dp.scope == scope and optEql(dp.path, rel) and optEql(dp.rev, rev)) {
            const id: PaneId = @intCast(i);
            app.showPane(id);
            try refreshDiff(app, dp);
            return id;
        },
        else => {},
    };
    const title = switch (scope) {
        .file => try std.fmt.allocPrint(gpa, "diff: {s}", .{std.fs.path.basename(rel orelse "")}),
        .worktree => try gpa.dupe(u8, "diff: worktree"),
        .head => try gpa.dupe(u8, "diff: HEAD"),
        .staged => try gpa.dupe(u8, "diff: staged"),
        .commit => blk: {
            const r: []const u8 = rev orelse "HEAD";
            break :blk try std.fmt.allocPrint(gpa, "commit {s}", .{r[0..@min(7, r.len)]});
        },
        .orig => try std.fmt.allocPrint(gpa, "orig: {s}", .{std.fs.path.basename(rel orelse "")}),
    };
    errdefer gpa.free(title);
    var dp: DiffPane = .{ .gpa = gpa, .repo = repo.id, .scope = scope, .title = title, .arena = .init(gpa), .mode = app.git.diff_mode };
    errdefer dp.deinit();
    if (rel) |p| dp.path = try gpa.dupe(u8, p);
    if (rev) |v| dp.rev = try gpa.dupe(u8, v);
    const id = try app.panes.add(.{ .diff = dp });
    dp = undefined;
    app.showPane(id);
    const pane = app.panes.get(id).?;
    try refreshDiffWith(app, &pane.diff, text);
    return id;
}

pub fn refreshDiff(app: *App, dp: *DiffPane) CommandError!void {
    return refreshDiffWith(app, dp, null);
}

fn refreshDiffWith(app: *App, dp: *DiffPane, text: ?[]const u8) CommandError!void {
    const repo = app.git.repoById(dp.repo) orelse return error.NoRepo;
    const gpa = app.gpa;
    const path = if (dp.path) |p| try gpa.dupe(u8, p) else null;
    errdefer if (path) |p| gpa.free(p);
    const rev = if (dp.rev) |v| try gpa.dupe(u8, v) else null;
    errdefer if (rev) |v| gpa.free(v);
    const body = if (text) |t| try gpa.dupe(u8, t) else null;
    errdefer if (body) |b| gpa.free(b);
    dp.pending = true;
    try submit(app, repo, .{ .diff = .{ .scope = dp.scope, .path = path, .rev = rev, .text = body, .full = dp.mode.wantsFullContext() } });
}

/// Recompute the rows the filter lets through, in both row lists, and
/// keep the cursor on a shown row.
pub fn refilterDiff(app: *App, dp: *DiffPane) Allocator.Error!void {
    const gpa = app.gpa;
    gpa.free(dp.shown);
    dp.shown = &.{};
    gpa.free(dp.split_shown);
    dp.split_shown = &.{};
    dp.shown = try diff_view.filterRows(gpa, dp.files, dp.rows, dp.filter.items, dp.mode == .flat);
    dp.split_shown = try diff_view.filterSplitRows(gpa, dp.files, dp.split_rows, dp.filter.items);
    const shown = dp.shownRows();
    if (shown.len == 0) {
        dp.cursor = 0;
        return;
    }
    // A cursor on a hidden row moves to the nearest shown row before it.
    var best: usize = shown[0];
    for (shown) |r| {
        if (r == dp.cursor) return;
        if (r < dp.cursor) best = r;
    }
    dp.cursor = best;
}

/// Switch the view. Inline and Split need the whole file, so the diff
/// is fetched again with full context when the loaded one is not; the
/// cursor follows its hunk across the two row lists.
pub fn setDiffMode(app: *App, dp: *DiffPane, mode: diff_view.Mode) CommandError!void {
    if (dp.mode == mode) return;
    const at = hunkAtCursor(dp);
    const was_split = dp.mode == .split;
    dp.mode = mode;
    app.git.diff_mode = mode;
    if (was_split != (mode == .split)) {
        dp.cursor = 0;
        if (at) |h| {
            if (mode == .split) {
                for (dp.split_rows, 0..) |r, i| if (r == .pair and r.pair.file == h.file and r.pair.hunk == h.hunk) {
                    dp.cursor = i;
                    break;
                };
            } else {
                for (dp.rows, 0..) |r, i| if (r == .hunk and r.hunk.file == h.file and r.hunk.hunk == h.hunk) {
                    dp.cursor = i;
                    break;
                };
            }
        }
    }
    try refilterDiff(app, dp);
    app.needs_render = true;
    if (mode.wantsFullContext() != dp.full) try refreshDiff(app, dp);
}

/// Move the cursor `delta` shown rows.
pub fn stepDiff(dp: *DiffPane, delta: isize) void {
    const shown = dp.shownRows();
    if (shown.len == 0) return;
    var pos: usize = 0;
    for (shown, 0..) |r, i| {
        if (r == dp.cursor) {
            pos = i;
            break;
        }
        if (r < dp.cursor) pos = i;
    }
    const next: isize = @as(isize, @intCast(pos)) + delta;
    const clamped: usize = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(shown.len - 1))));
    dp.cursor = shown[clamped];
}

pub fn diffHome(dp: *DiffPane, end: bool) void {
    const shown = dp.shownRows();
    if (shown.len == 0) return;
    dp.cursor = if (end) shown[shown.len - 1] else shown[0];
}

pub fn openGraph(app: *App, repo: *client.Repo) CommandError!PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .git_graph => |*g| if (g.repo == repo.id) {
            const id: PaneId = @intCast(i);
            app.showPane(id);
            try refreshGraph(app, g);
            return id;
        },
        else => {},
    };
    var g: GraphPane = .{ .gpa = app.gpa, .repo = repo.id, .arena = .init(app.gpa), .detail_arena = .init(app.gpa) };
    errdefer g.deinit();
    const id = try app.panes.add(.{ .git_graph = g });
    g = undefined;
    app.showPane(id);
    try refreshGraph(app, &app.panes.get(id).?.git_graph);
    return id;
}

pub fn refreshGraph(app: *App, g: *GraphPane) CommandError!void {
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    const filter = try g.filter.dupe(app.gpa);
    g.pending = true;
    try submit(app, repo, .{ .log = .{ .n = graph_limit, .filter = filter } });
}

pub fn openStatusPane(app: *App, repo: *client.Repo) CommandError!PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .git_status => |*s| {
            s.repo = repo.id;
            const id: PaneId = @intCast(i);
            app.showPane(id);
            return id;
        },
        else => {},
    };
    const id = try app.panes.add(.{ .git_status = .{ .repo = repo.id } });
    app.showPane(id);
    return id;
}

/// The diff pane's current hunk, if the cursor is inside one.
pub fn hunkAtCursor(dp: *const DiffPane) ?struct { file: u32, hunk: u32 } {
    if (dp.mode == .split) {
        if (dp.cursor >= dp.split_rows.len) return null;
        return switch (dp.split_rows[dp.cursor]) {
            .pair => |p| .{ .file = p.file, .hunk = p.hunk },
            .file, .blank => null,
        };
    }
    if (dp.cursor >= dp.rows.len) return null;
    return switch (dp.rows[dp.cursor]) {
        .hunk => |h| .{ .file = h.file, .hunk = h.hunk },
        .line => |l| .{ .file = l.file, .hunk = l.hunk },
        .file, .blank => null,
    };
}

/// Stage / unstage / discard the hunk under the cursor with a
/// synthesized one-hunk patch.
pub fn applyHunk(app: *App, dp: *DiffPane, what: enum { stage, unstage, discard }) CommandError!void {
    const arena = app.frame.allocator();
    const at = hunkAtCursor(dp) orelse return app.diag.fail(arena, "diff: no hunk under the cursor", .{});
    const repo = app.git.repoById(dp.repo) orelse return error.NoRepo;
    const f = dp.files[at.file];
    const patch = try parse.patchForHunk(arena, f, at.hunk);
    const desc = switch (what) {
        .stage => try std.fmt.allocPrint(app.gpa, "staged hunk {d} of {s}", .{ at.hunk + 1, f.path() }),
        .unstage => try std.fmt.allocPrint(app.gpa, "unstaged hunk {d} of {s}", .{ at.hunk + 1, f.path() }),
        .discard => try std.fmt.allocPrint(app.gpa, "discarded hunk {d} of {s}", .{ at.hunk + 1, f.path() }),
    };
    errdefer app.gpa.free(desc);
    const owned = try app.gpa.dupe(u8, patch);
    errdefer app.gpa.free(owned);
    try submitOp(app, repo, .{ .apply_patch = .{ .patch = owned, .cached = what != .discard, .reverse = what != .stage, .desc = desc } });
}

// ─── pickers ────────────────────────────────────────────────────────────

/// Ask the repo for its branches; `pick` says what the picker will do.
pub fn askBranches(app: *App, repo: *client.Repo, pick: Pick) CommandError!void {
    app.git.awaiting = pick;
    try submit(app, repo, .branches);
}

pub fn askList(app: *App, repo: *client.Repo, kind: client.ListKind, pick: Pick) CommandError!void {
    app.git.awaiting = pick;
    try submit(app, repo, .{ .list = kind });
}

fn openBranchPicker(app: *App, bs: []const parse.Branch, what: Pick) Allocator.Error!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    const now = nowUnix(app);
    for (bs) |b| {
        // A delete / merge / rebase picker never offers the current branch.
        if (b.current and (what == .delete_branch or what == .merge or what == .rebase)) continue;
        if (what == .delete_branch and b.remote) continue;
        var age_buf: [16]u8 = undefined;
        const age = parse.relativeAge(&age_buf, b.time, now);
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (b.current) "* " else "", b.name }));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ age, if (b.remote) "  remote" else "" }));
    }
    if (labels.items.len == 0) {
        app.toast("no branches (not a git repo?)", .{});
        return;
    }
    const title: []const u8 = switch (what) {
        .checkout => "Checkout branch",
        .recent => "Recent branches (sorted by activity)",
        .merge => "Merge into current",
        .rebase => "Rebase onto",
        .delete_branch => "Delete branch (force)",
        .graph_branch => "Graph: filter by branch",
        else => "Branches",
    };
    app.git.pick = what;
    cmd_picker.openPickerWith(app, title, .git, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn openListPicker(app: *App, kind: client.ListKind, items: []const []const u8, what: Pick) Allocator.Error!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (items) |it| {
        // `<key>\x1f<text>`: the key is what the command acts on.
        const sep = std.mem.indexOfScalar(u8, it, '\x1f');
        const key_s = if (sep) |s| it[0..s] else it;
        const text = if (sep) |s| it[s + 1 ..] else "";
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ key_s, if (text.len > 0) "  " else "", text }));
        try details.append(gpa, try gpa.dupe(u8, key_s));
    }
    if (labels.items.len == 0) {
        app.toast("{s}", .{switch (kind) {
            .stashes => "no stashes",
            .tags => "no tags",
            .reflog => "empty reflog",
            .worktrees => "no worktrees (not a git repo?)",
        }});
        return;
    }
    const title: []const u8 = switch (what) {
        .stash_apply => "Stash list (Enter applies, keeps the stash)",
        .stash_drop => "Stash drop",
        .tag_delete => "Delete tag",
        .reflog => "Reflog (Enter opens the commit's diff)",
        .worktree_open => "Worktrees",
        .worktree_remove => "Remove worktree",
        .worktree_shell => "Worktrees → shell",
        else => "Git",
    };
    app.git.pick = what;
    cmd_picker.openPickerWith(app, title, .git, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn openCommitPicker(app: *App, commits: []const parse.Commit, what: Pick) Allocator.Error!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    const now = nowUnix(app);
    for (commits) |c| {
        var age_buf: [16]u8 = undefined;
        const age = parse.relativeAge(&age_buf, c.time, now);
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  {s}  {s} {s}", .{ c.short(), c.subject, c.author, age }));
        try details.append(gpa, try gpa.dupe(u8, c.hash));
    }
    if (labels.items.len == 0) {
        app.toast("no commits touch this file", .{});
        return;
    }
    app.git.pick = what;
    cmd_picker.openPickerWith(app, "File history", .git, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// Open the repo switcher.
pub fn openRepoPicker(app: *App) CommandError!void {
    const st = &app.git;
    if (!st.discovered) try discover(app);
    const gpa = app.gpa;
    if (st.repos.items.len == 0) return app.diag.fail(app.frame.allocator(), "no repos under {s}", .{app.workspace});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (st.repos.items, 0..) |r, i| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (st.active == i) "* " else "", r.name }));
        try details.append(gpa, try gpa.dupe(u8, app.relPath(r.path)));
    }
    st.pick = .switch_repo;
    try cmd_picker.openPickerWith(app, "Switch repo", .git, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

/// The git picker's pick. `label` is the row as shown, `detail` the
/// value the command acts on (a sha, a stash ref, a path).
pub fn acceptPick(app: *App, label_in: []const u8, detail_in: []const u8) CommandError!void {
    const st = &app.git;
    const gpa = app.gpa;
    const what = st.pick;
    st.pick = .none;
    const label = std.mem.trimStart(u8, label_in, "* ");
    const detail = detail_in;
    switch (what) {
        .none => {},
        .switch_repo => {
            for (st.repos.items, 0..) |r, i| if (std.mem.eql(u8, r.name, label)) return switchTo(app, i);
        },
        .checkout, .recent => {
            const repo = try requireRepo(app);
            // A remote branch checks out as a local tracking branch of
            // the same short name (git's own guess).
            const name = if (std.mem.indexOf(u8, detail, "remote") != null) (if (std.mem.indexOfScalar(u8, label, '/')) |s| label[s + 1 ..] else label) else label;
            try submitOp(app, repo, .{ .checkout = try gpa.dupe(u8, name) });
        },
        .merge => try submitOp(app, try requireRepo(app), .{ .merge = try gpa.dupe(u8, label) }),
        .rebase => try submitOp(app, try requireRepo(app), .{ .rebase = try gpa.dupe(u8, label) }),
        .delete_branch => try openConfirm(app, .{ .delete_branch = try gpa.dupe(u8, label) }, try std.fmt.allocPrint(gpa, "  Delete branch {s}? (git branch -D)", .{label})),
        .graph_branch => {
            const g = activeGraph(app) orelse return;
            if (g.filter.branch) |b| gpa.free(b);
            g.filter.branch = try gpa.dupe(u8, label);
            try refreshGraph(app, g);
        },
        .stash_apply => try submitOp(app, try requireRepo(app), .{ .stash_apply = try gpa.dupe(u8, detail) }),
        .stash_drop => try submitOp(app, try requireRepo(app), .{ .stash_drop = try gpa.dupe(u8, detail) }),
        .tag_delete => try submitOp(app, try requireRepo(app), .{ .tag_delete = try gpa.dupe(u8, detail) }),
        .reflog, .file_history => {
            const repo = try requireRepo(app);
            const rel: ?[]const u8 = if (what == .file_history) (if (app.activeEditor()) |e| (if (e.buf.path) |p| relToRepo(repo, p) else null) else null) else null;
            _ = try openDiff(app, repo, .commit, rel, detail, null);
        },
        .worktree_open, .worktree_shell => app.toast("worktree: {s}", .{detail}),
        .worktree_remove => try openConfirm(app, .{ .worktree_remove = try gpa.dupe(u8, detail) }, try std.fmt.allocPrint(gpa, "  Remove worktree {s}?", .{detail})),
    }
}

pub fn activeGraph(app: *App) ?*GraphPane {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .git_graph => |*g| g,
        else => null,
    };
}

pub fn activeDiff(app: *App) ?*DiffPane {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .diff => |*d| d,
        else => null,
    };
}

// ─── prompts + confirms ─────────────────────────────────────────────────

pub fn openPrompt(app: *App, kind: PromptKind, title: []const u8) void {
    app.overlay.deinit(app.gpa);
    if (kind != .commit and kind != .amend) if (app.git.ai_body) |b| {
        app.gpa.free(b);
        app.git.ai_body = null;
    };
    app.git.prompt = kind;
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, title), .purpose = .git } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptPrompt(app: *App, text_in: []const u8) CommandError!void {
    const st = &app.git;
    const gpa = app.gpa;
    const kind = st.prompt;
    st.prompt = .none;
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    switch (kind) {
        .none => {},
        .commit => {
            if (text.len == 0) return app.diag.fail(app.frame.allocator(), "commit: empty message", .{});
            try submitOp(app, try requireRepo(app), .{ .commit = try takeMessage(app, text) });
        },
        .amend => {
            if (text.len == 0) return app.diag.fail(app.frame.allocator(), "amend: empty message", .{});
            try submitOp(app, try requireRepo(app), .{ .amend = try takeMessage(app, text) });
        },
        .graph_hash => {
            const g = activeGraph(app) orelse return app.diag.fail(app.frame.allocator(), "graph: no graph pane is active", .{});
            if (text.len == 0) return;
            const idx = graph_view.findByHashPrefix(g.commits, text) orelse return app.diag.fail(app.frame.allocator(), "no commit starts with {s}", .{text});
            g.cursor = g.rowOfCommit(idx);
            if (g.detail_open) requestDetail(app, g) catch {};
            app.needs_render = true;
        },
        .stash => try submitOp(app, try requireRepo(app), .{ .stash = if (text.len == 0) null else try gpa.dupe(u8, text) }),
        .new_branch => {
            if (text.len == 0) return;
            try submitOp(app, try requireRepo(app), .{ .new_branch = try gpa.dupe(u8, text) });
        },
        .tag => {
            if (text.len == 0) return;
            try submitOp(app, try requireRepo(app), .{ .tag = try gpa.dupe(u8, text) });
        },
        .worktree_add => {
            if (text.len == 0) return;
            // `<path> [branch]`
            var it = std.mem.tokenizeScalar(u8, text, ' ');
            const path = it.next() orelse return;
            const branch = it.next();
            try submitOp(app, try requireRepo(app), .{ .worktree_add = .{ .path = try gpa.dupe(u8, path), .branch = if (branch) |b| try gpa.dupe(u8, b) else null } });
        },
        .graph_author, .graph_subject, .graph_date => {
            const g = activeGraph(app) orelse return app.diag.fail(app.frame.allocator(), "graph: no graph pane is active", .{});
            switch (kind) {
                .graph_author => {
                    if (g.filter.author) |a| gpa.free(a);
                    g.filter.author = if (text.len == 0) null else try gpa.dupe(u8, text);
                },
                .graph_subject => {
                    if (g.filter.subject) |s| gpa.free(s);
                    g.filter.subject = if (text.len == 0) null else try gpa.dupe(u8, text);
                },
                .graph_date => {
                    // `since..until`, either side optional.
                    if (g.filter.since) |s| gpa.free(s);
                    if (g.filter.until) |u| gpa.free(u);
                    g.filter.since = null;
                    g.filter.until = null;
                    if (std.mem.indexOf(u8, text, "..")) |dd| {
                        const a = std.mem.trim(u8, text[0..dd], " ");
                        const b = std.mem.trim(u8, text[dd + 2 ..], " ");
                        if (a.len > 0) g.filter.since = try gpa.dupe(u8, a);
                        if (b.len > 0) g.filter.until = try gpa.dupe(u8, b);
                    } else if (text.len > 0) g.filter.since = try gpa.dupe(u8, text);
                },
                else => unreachable,
            }
            try refreshGraph(app, g);
        },
    }
}

/// Open a yes / no box. Takes `payload` (owned) and `message` (owned).
pub fn openConfirm(app: *App, payload: Confirm, message: []u8) Allocator.Error!void {
    const st = &app.git;
    st.confirm.deinit(app.gpa);
    st.confirm = payload;
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Git", .message = message, .choices = &confirm_choices },
        .purpose = .git,
        .message = message,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const confirm_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'y', .label = "Yes" }, .{ .key = 'n', .label = "No" } };

pub fn acceptConfirm(app: *App, choice: usize) CommandError!void {
    const st = &app.git;
    const gpa = app.gpa;
    const payload = st.confirm;
    st.confirm = .none;
    defer payload.deinit(gpa);
    if (choice != 0) return;
    switch (payload) {
        .none => {},
        .discard => |p| try submitOp(app, try requireRepo(app), .{ .discard = try gpa.dupe(u8, p) }),
        .discard_hunk => |d| {
            const pane = app.panes.get(d.pane) orelse return;
            switch (pane.*) {
                .diff => |*dp| try applyHunk(app, dp, .discard),
                else => {},
            }
        },
        .delete_branch => |b| try submitOp(app, try requireRepo(app), .{ .delete_branch = try gpa.dupe(u8, b) }),
        .worktree_remove => |p| try submitOp(app, try requireRepo(app), .{ .worktree_remove = try gpa.dupe(u8, p) }),
        .checkout => |b| try submitOp(app, try requireRepo(app), .{ .checkout = try gpa.dupe(u8, b) }),
    }
}

/// A prompt or confirm box closing by any route: an AI body waiting
/// for a commit prompt that is gone is dropped.
pub fn overlayClosing(app: *App) void {
    const st = &app.git;
    if (st.prompt == .commit or st.prompt == .amend) {
        if (st.ai_body) |b| app.gpa.free(b);
        st.ai_body = null;
    }
}

// ─── row actions (rail + status pane) ───────────────────────────────────

pub const RowAction = enum { open, stage, unstage, discard };

/// Act on a rail / status-pane row. Headers toggle their group; a
/// branch checks out after a yes (`x` deletes after one); a worktree
/// row says where it is; a PR opens on the remote.
pub fn actOnRow(app: *App, row: Row, what: RowAction) CommandError!void {
    const st = &app.git;
    const gpa = app.gpa;
    if (row.header) {
        if (what == .open) {
            if (row.kind == .section) st.rail_folded.toggle(row.section) else st.collapsed.toggle(row.group);
            try rebuildRows(app);
        }
        return;
    }
    switch (row.kind) {
        .status => {},
        .branch => {
            if (row.entry >= st.rail_branches.len) return;
            const b = st.rail_branches[row.entry];
            switch (what) {
                .open => {
                    if (b.current) return app.diag.fail(app.frame.allocator(), "{s} is checked out", .{b.name});
                    // A remote branch checks out as a local one of the same short name.
                    const name = if (b.remote) (if (std.mem.indexOfScalar(u8, b.name, '/')) |x| b.name[x + 1 ..] else b.name) else b.name;
                    try openConfirm(app, .{ .checkout = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "  Checkout {s}?", .{name}));
                },
                .discard => {
                    if (b.current) return app.diag.fail(app.frame.allocator(), "cannot delete the checked-out branch", .{});
                    if (b.remote) return app.diag.fail(app.frame.allocator(), "remote branches are not deleted from here", .{});
                    try openConfirm(app, .{ .delete_branch = try gpa.dupe(u8, b.name) }, try std.fmt.allocPrint(gpa, "  Delete branch {s}? (git branch -D)", .{b.name}));
                },
                .stage, .unstage => {},
            }
            return;
        },
        .worktree => {
            if (what == .open) app.toast("worktree: {s}", .{row.path});
            return;
        },
        .pr => {
            if (what != .open) return;
            for (st.rail_prs) |pr| if (pr.number == row.entry) {
                openExternal(app, pr.url);
                app.toast("{s}", .{pr.url});
                return;
            };
            return;
        },
        .section, .note => return,
    }
    const repo = st.activeRepo() orelse return error.NoRepo;
    switch (what) {
        .open => _ = try openDiff(app, repo, if (row.group == .staged) .staged else .file, row.path, null, null),
        .stage => try submitOp(app, repo, .{ .stage = try gpa.dupe(u8, row.path) }),
        .unstage => try submitOp(app, repo, .{ .unstage = try gpa.dupe(u8, row.path) }),
        .discard => try openConfirm(app, .{ .discard = try gpa.dupe(u8, row.path) }, try std.fmt.allocPrint(gpa, "  Discard changes to {s}? This cannot be undone.", .{row.path})),
    }
}

/// Open the selected row's file in an editor (a double click / `o`).
pub fn openRowFile(app: *App, row: Row) CommandError!void {
    if (row.header) return;
    const repo = app.git.activeRepo() orelse return error.NoRepo;
    const arena = app.frame.allocator();
    const abs = try std.fs.path.join(arena, &.{ repo.path, row.path });
    _ = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ row.path, @errorName(err) }),
    };
}

// ─── keys ───────────────────────────────────────────────────────────────

/// The rail's keys: the list's own first, then `s u x a A c r o`.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.git;
    switch (try Panel.handleKey(&st.rail, app.gpa, k)) {
        .consumed => return true,
        .filter_changed => {
            try refilter(app);
            return true;
        },
        .activate => |i| {
            st.rail.cursor = i;
            if (st.selectedRow()) |row| runToast(app, actOnRow(app, row, .open));
            return true;
        },
        .ignored => {},
    }
    if (st.rail.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            return rowLetter(app, c, st.selectedRow());
        },
        else => return false,
    }
}

/// The letters the rail and the status pane share.
pub fn rowLetter(app: *App, c: u21, row: ?Row) Allocator.Error!bool {
    switch (c) {
        's' => if (row) |r| runToast(app, actOnRow(app, r, .stage)),
        'u' => if (row) |r| runToast(app, actOnRow(app, r, .unstage)),
        'x' => if (row) |r| runToast(app, actOnRow(app, r, .discard)),
        'o' => if (row) |r| runToast(app, openRowFile(app, r)),
        'a' => runToast(app, command.run(app, .{ .static = .@"git.stage_all" })),
        'A' => runToast(app, command.run(app, .{ .static = .@"git.unstage_all" })),
        'c' => runToast(app, command.run(app, .{ .static = .@"git.commit" })),
        'n' => runToast(app, command.run(app, .{ .static = .@"git.new_branch" })),
        'b' => runToast(app, toggleRail(app)),
        'r' => {
            runToast(app, requestStatus(app));
            if (app.git.rail_open) runToast(app, requestRail(app));
        },
        else => return false,
    }
    return true;
}

/// The status pane: j/k move over the rows, enter opens the diff, the
/// shared letters act; `q` / esc close.
pub fn statusPaneKey(app: *App, id: PaneId, sp: *StatusPane, k: Key) Allocator.Error!bool {
    const st = &app.git;
    const n = st.rows.items.len;
    const row: ?Row = if (sp.cursor < n) st.rows.items[sp.cursor] else null;
    switch (k.code) {
        .up => sp.cursor -|= 1,
        .down => sp.cursor = @min(sp.cursor + 1, n -| 1),
        .home => sp.cursor = 0,
        .end => sp.cursor = n -| 1,
        .enter => if (row) |r| runToast(app, actOnRow(app, r, .open)),
        .esc => try app.closePane(id, true),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => sp.cursor = @min(sp.cursor + 1, n -| 1),
                'k' => sp.cursor -|= 1,
                'g' => sp.cursor = 0,
                'G' => sp.cursor = n -| 1,
                'q' => try app.closePane(id, true),
                else => return rowLetter(app, c, row),
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// The diff pane: motion over the shown rows, `]c [c` / `n p` between
/// hunks, `]f [f` between files, `s u x` on the hunk, `v` cycles the
/// view, `/` filters, enter opens the file at the line. While the
/// filter takes keys, esc clears it and enter keeps it.
pub fn diffKey(app: *App, id: PaneId, dp: *DiffPane, k: Key) Allocator.Error!bool {
    if (dp.filter_mode) {
        switch (k.code) {
            .esc => {
                dp.filter.clearRetainingCapacity();
                dp.filter_mode = false;
                try refilterDiff(app, dp);
            },
            .enter => dp.filter_mode = false,
            .backspace => {
                if (dp.filter.items.len > 0) {
                    var n: usize = 1;
                    while (n < dp.filter.items.len and (dp.filter.items[dp.filter.items.len - n] & 0xC0) == 0x80) n += 1;
                    dp.filter.items.len -= n;
                }
                try refilterDiff(app, dp);
            },
            .char => |c| {
                if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return true;
                try dp.filter.appendSlice(app.gpa, buf[0..n]);
                try refilterDiff(app, dp);
            },
            else => return false,
        }
        app.needs_render = true;
        return true;
    }
    if (dp.bracket) |b| {
        dp.bracket = null;
        if (k.code == .char and k.mods.eql(.{})) {
            switch (k.code.char) {
                'c' => moveHunk(dp, b == ']'),
                'f' => moveFile(dp, b == ']'),
                else => {},
            }
            app.needs_render = true;
            return true;
        }
    }
    const page: isize = @intCast(@max(app.pane_rows, 1));
    switch (k.code) {
        .up => stepDiff(dp, -1),
        .down => stepDiff(dp, 1),
        .page_up => stepDiff(dp, -page),
        .page_down => stepDiff(dp, page),
        .home => diffHome(dp, false),
        .end => diffHome(dp, true),
        .enter => runToast(app, openDiffLine(app, dp)),
        .esc => {
            if (dp.filter.items.len > 0) {
                dp.filter.clearRetainingCapacity();
                try refilterDiff(app, dp);
            } else try app.closePane(id, true);
        },
        .char => |c| {
            if (k.mods.ctrl and (c == 'd' or c == 'u')) {
                stepDiff(dp, if (c == 'd') @divTrunc(page, 2) else -@divTrunc(page, 2));
                app.needs_render = true;
                return true;
            }
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => stepDiff(dp, 1),
                'k' => stepDiff(dp, -1),
                'g' => diffHome(dp, false),
                'G' => diffHome(dp, true),
                ']', '[' => dp.bracket = @intCast(c),
                'n' => moveHunk(dp, true),
                'p' => moveHunk(dp, false),
                'v' => runToast(app, setDiffMode(app, dp, dp.mode.next())),
                '/' => {
                    dp.filter_mode = true;
                    dp.filter.clearRetainingCapacity();
                    try refilterDiff(app, dp);
                },
                's' => runToast(app, applyHunk(app, dp, .stage)),
                'u' => runToast(app, applyHunk(app, dp, .unstage)),
                'x' => {
                    if (hunkAtCursor(dp) == null) {
                        app.toast("diff: no hunk under the cursor", .{});
                    } else try openConfirm(app, .{ .discard_hunk = .{ .pane = id } }, try app.gpa.dupe(u8, "  Discard this hunk from the worktree? This cannot be undone."));
                },
                'r' => runToast(app, refreshDiff(app, dp)),
                'q' => try app.closePane(id, true),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// True when the shown row at `pos` starts a change: a hunk header in
/// the Hunk view, the first changed row after a context row in the
/// Inline and Split views (which have no hunk rows).
fn startsChange(dp: *const DiffPane, pos: usize) bool {
    const shown = dp.shownRows();
    const ri = shown[pos];
    switch (dp.mode) {
        .hunk => return dp.rows[ri] == .hunk,
        .flat => {
            if (diff_view.rowKind(dp.files, dp.rows[ri]) == .none) return false;
            if (pos == 0) return true;
            return diff_view.rowKind(dp.files, dp.rows[shown[pos - 1]]) == .none;
        },
        .split => {
            if (diff_view.splitRowKind(dp.files, dp.split_rows[ri]) == .none) return false;
            if (pos == 0) return true;
            return diff_view.splitRowKind(dp.files, dp.split_rows[shown[pos - 1]]) == .none;
        },
    }
}

fn cursorPos(dp: *const DiffPane) usize {
    var pos: usize = 0;
    for (dp.shownRows(), 0..) |r, i| {
        if (r == dp.cursor) return i;
        if (r < dp.cursor) pos = i;
    }
    return pos;
}

/// The next / previous hunk among the shown rows.
pub fn moveHunk(dp: *DiffPane, forward: bool) void {
    const shown = dp.shownRows();
    if (shown.len == 0) return;
    var i = cursorPos(dp);
    while (true) {
        if (forward) {
            if (i + 1 >= shown.len) return;
            i += 1;
        } else {
            if (i == 0) return;
            i -= 1;
        }
        if (startsChange(dp, i)) {
            dp.cursor = shown[i];
            return;
        }
    }
}

pub fn moveFile(dp: *DiffPane, forward: bool) void {
    const shown = dp.shownRows();
    if (shown.len == 0) return;
    var i = cursorPos(dp);
    while (true) {
        if (forward) {
            if (i + 1 >= shown.len) return;
            i += 1;
        } else {
            if (i == 0) return;
            i -= 1;
        }
        const is_file = if (dp.mode == .split) dp.split_rows[shown[i]] == .file else dp.rows[shown[i]] == .file;
        if (is_file) {
            dp.cursor = shown[i];
            return;
        }
    }
}

/// Enter on a diff row: the file at that line.
fn openDiffLine(app: *App, dp: *DiffPane) CommandError!void {
    if (dp.cursor >= dp.rowCount()) return;
    const repo = app.git.repoById(dp.repo) orelse return error.NoRepo;
    const arena = app.frame.allocator();
    const fi: u32, const line: ?u32 = if (dp.mode == .split) switch (dp.split_rows[dp.cursor]) {
        .file => |f| .{ f, null },
        .pair => |p| blk: {
            const lines = dp.files[p.file].hunks[p.hunk].lines;
            const no: ?u32 = if (p.right) |r| lines[r].new_no else if (p.left) |l| lines[l].old_no else null;
            break :blk .{ p.file, no };
        },
        .blank => return,
    } else switch (dp.rows[dp.cursor]) {
        .file => |f| .{ f, null },
        .hunk => |h| .{ h.file, dp.files[h.file].hunks[h.hunk].new_start },
        .line => |l| blk: {
            const dl = dp.files[l.file].hunks[l.hunk].lines[l.line];
            break :blk .{ l.file, dl.new_no orelse dl.old_no };
        },
        .blank => return,
    };
    const rel = dp.files[fi].path();
    const abs = try std.fs.path.join(arena, &.{ repo.path, rel });
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
    if (line) |ln| if (app.panes.editor(id)) |e| {
        const ed = &e.buf.editor;
        ed.anchor = null;
        ed.placeCursor(@min(@as(usize, ln) -| 1, ed.lineCount() -| 1), 0);
        e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
    };
}

/// A click in the diff pane (`.script_hit`): a view chip switches the
/// view, the divider starts a drag, a strip cell jumps to its band, the
/// filter banner takes the keys, a row selects (a second click opens it).
pub fn diffClick(app: *App, id: PaneId, dp: *DiffPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    if (diff_view.chipOf(hit_id)) |mode| {
        if (m.button == .left) runToast(app, setDiffMode(app, dp, mode));
        return;
    }
    if (hit_id == diff_view.divider_id) {
        if (m.button == .left) app.drag = .{ .git_divider = id };
        return;
    }
    if (hit_id == diff_view.filter_id) {
        dp.filter_mode = true;
        app.needs_render = true;
        return;
    }
    if (diff_view.stripCellOf(hit_id)) |cell| {
        const shown = dp.shownRows();
        if (shown.len == 0) return;
        dp.cursor = shown[diff_view.stripCellRow(cell, dp.strip_cells, shown.len)];
        app.needs_render = true;
        return;
    }
    if (hit_id >= dp.rowCount()) return;
    if (dp.cursor == hit_id and m.button == .left) runToast(app, openDiffLine(app, dp)) else dp.cursor = hit_id;
    app.needs_render = true;
}

/// The split divider follows the pointer while it is held.
pub fn dragDivider(app: *App, id: PaneId, x: u16) void {
    const pane = app.panes.get(id) orelse return;
    const dp = switch (pane.*) {
        .diff => |*d| d,
        else => return,
    };
    const w: u32 = @max(dp.body.w -| 1, 1);
    const off: u32 = x -| dp.body.x;
    dp.ratio = @intCast(std.math.clamp(off * 100 / w, 15, 85));
    app.needs_render = true;
}

/// The working-tree row is there when the status of this pane's repo
/// has changes. Recomputed before keys, clicks and paints so the
/// virtual rows always match the status.
pub fn syncWip(app: *App, g: *GraphPane) void {
    const st = &app.git;
    if (st.status == null or st.status_repo != g.repo) return;
    const has = st.status.?.changeCount() > 0;
    if (has != g.has_wip) {
        // Keep the cursor on the same commit across the shift; the
        // first status a pane sees puts the cursor on the top row.
        if (g.wip_known) {
            if (has) g.cursor += 1 else g.cursor -|= 1;
        }
        g.has_wip = has;
    }
    g.wip_known = true;
    if (g.cursor >= g.totalRows()) g.cursor = g.totalRows() -| 1;
}

/// Fetch the selected commit's detail unless it is already here or on
/// its way. The result lands in `handle`'s `.commit_detail` prong.
pub fn requestDetail(app: *App, g: *GraphPane) CommandError!void {
    const c = g.selected() orelse return;
    if (g.detail_pending) return;
    if (g.detail) |d| if (std.mem.eql(u8, d.sha, c.hash)) return;
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    g.detail_pending = true;
    submit(app, repo, .{ .commit_detail = try app.gpa.dupe(u8, c.hash) }) catch |err| {
        g.detail_pending = false;
        return err;
    };
}

/// Open the detail panel on the selected row (the WIP row shows the
/// working tree).
pub fn openDetail(app: *App, g: *GraphPane) CommandError!void {
    g.detail_open = true;
    g.detail_cursor = 0;
    if (!g.wipSelected()) try requestDetail(app, g);
    app.needs_render = true;
}

pub fn setSort(app: *App, g: *GraphPane, sort: graph_view.Sort) Allocator.Error!void {
    const sel = g.selectedIndex();
    g.sort = sort;
    g.order = try graph_view.sortOrder(g.arena.allocator(), g.commits, sort);
    if (sel) |ci| g.cursor = g.rowOfCommit(ci);
    app.needs_render = true;
}

/// A click on a column chip: a new column sorts descending, the
/// active one flips; `s` cycles the columns.
pub fn clickSort(app: *App, g: *GraphPane, col: graph_view.SortCol) Allocator.Error!void {
    if (col == .none) return setSort(app, g, .{});
    if (g.sort.col == col) return setSort(app, g, .{ .col = col, .asc = !g.sort.asc });
    return setSort(app, g, .{ .col = col, .asc = false });
}

fn moveGraphCursor(app: *App, g: *GraphPane, to: usize) void {
    const total = g.totalRows();
    if (total == 0) return;
    g.cursor = @min(to, total - 1);
    if (g.detail_open) {
        g.detail_cursor = 0;
        if (!g.wipSelected()) requestDetail(app, g) catch {};
    }
}

/// The graph pane: motion over the virtual rows, enter opens the
/// detail panel (the WIP row's shows the working tree), tab moves the
/// focus into it, `d` opens the commit's diff, `s` cycles the sort,
/// `/` jumps to a hash, `c` cherry-picks, `v` reverts, `f` filters by
/// branch, `F` clears every filter. On the WIP row `a` / `A` / `c`
/// stage everything, unstage everything, commit.
pub fn graphKey(app: *App, id: PaneId, g: *GraphPane, k: Key) Allocator.Error!bool {
    syncWip(app, g);
    if (g.detail_open and g.detail_focus) return detailKey(app, id, g, k);
    const n = g.totalRows();
    switch (k.code) {
        .up => moveGraphCursor(app, g, g.cursor -| 1),
        .down => moveGraphCursor(app, g, g.cursor + 1),
        .page_up => moveGraphCursor(app, g, g.cursor -| app.pane_rows),
        .page_down => moveGraphCursor(app, g, g.cursor + app.pane_rows),
        .home => moveGraphCursor(app, g, 0),
        .end => moveGraphCursor(app, g, n -| 1),
        .enter => runToast(app, openDetail(app, g)),
        .tab => if (g.detail_open) {
            g.detail_focus = true;
        } else return false,
        .esc => {
            if (g.detail_open) {
                g.detail_open = false;
                g.detail_focus = false;
            } else try app.closePane(id, true);
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => moveGraphCursor(app, g, g.cursor + 1),
                'k' => moveGraphCursor(app, g, g.cursor -| 1),
                'g' => moveGraphCursor(app, g, 0),
                'G' => moveGraphCursor(app, g, n -| 1),
                'd' => runToast(app, showSelectedCommit(app, g)),
                's' => try setSort(app, g, .{ .col = g.sort.col.next(), .asc = false }),
                '/' => openPrompt(app, .graph_hash, "Jump to commit (hash prefix)"),
                'a' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.stage_all" })) else return false,
                'A' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.unstage_all" })) else return false,
                'c' => runToast(app, command.run(app, .{ .static = if (g.wipSelected()) .@"git.commit" else .@"git.cherry_pick" })),
                'v' => runToast(app, command.run(app, .{ .static = .@"git.revert" })),
                'f' => runToast(app, command.run(app, .{ .static = .@"git.graph_filter_branch" })),
                'F' => runToast(app, command.run(app, .{ .static = .@"git.graph_filter_reset_all" })),
                'r' => runToast(app, refreshGraph(app, g)),
                'q' => try app.closePane(id, true),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// The detail panel has the keys: j/k over the files, enter opens the
/// file's diff in this commit (the WIP row's file opens its worktree
/// diff), tab / esc hand the focus back, `q` closes the pane.
fn detailKey(app: *App, id: PaneId, g: *GraphPane, k: Key) Allocator.Error!bool {
    const n = detailRowCount(app, g);
    switch (k.code) {
        .up => g.detail_cursor -|= 1,
        .down => g.detail_cursor = @min(g.detail_cursor + 1, n -| 1),
        .home => g.detail_cursor = 0,
        .end => g.detail_cursor = n -| 1,
        .enter => runToast(app, openDetailRow(app, g)),
        .tab, .esc => g.detail_focus = false,
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => g.detail_cursor = @min(g.detail_cursor + 1, n -| 1),
                'k' => g.detail_cursor -|= 1,
                'g' => g.detail_cursor = 0,
                'G' => g.detail_cursor = n -| 1,
                'd' => runToast(app, showSelectedCommit(app, g)),
                'q' => try app.closePane(id, true),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

fn detailRowCount(app: *App, g: *GraphPane) usize {
    if (g.wipSelected()) return if (app.git.status) |st| st.entries.len else 0;
    const d = g.detail orelse return 0;
    return d.files.len;
}

/// Enter on a detail row: the file's diff — in the commit for a commit
/// row, in the working tree for the WIP row. Without files, the whole
/// commit.
fn openDetailRow(app: *App, g: *GraphPane) CommandError!void {
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    if (g.wipSelected()) {
        const st = app.git.status orelse return;
        if (g.detail_cursor >= st.entries.len) return;
        const e = st.entries[g.detail_cursor];
        _ = try openDiff(app, repo, if (e.group == .staged) .staged else .file, e.path, null, null);
        return;
    }
    const c = g.selected() orelse return;
    const d = g.detail orelse return showSelectedCommit(app, g);
    if (d.files.len == 0 or g.detail_cursor >= d.files.len) return showSelectedCommit(app, g);
    _ = try openDiff(app, repo, .commit, d.files[g.detail_cursor].path, c.hash, null);
}

pub fn showSelectedCommit(app: *App, g: *GraphPane) CommandError!void {
    if (g.wipSelected()) {
        const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
        _ = try openDiff(app, repo, .head, null, null, null);
        return;
    }
    const c = g.selected() orelse return app.diag.fail(app.frame.allocator(), "graph: no commit selected", .{});
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    _ = try openDiff(app, repo, .commit, null, c.hash, null);
}

/// A click in the graph pane (`.script_hit`): a column chip sorts, a
/// WIP button acts, the divider starts a drag, a detail row selects
/// (a second click opens it), a list row selects (a second click opens
/// its detail; right opens the row menu).
pub fn graphClick(app: *App, id: PaneId, g: *GraphPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    syncWip(app, g);
    if (graph_view.sortOf(hit_id)) |col| {
        if (m.button == .left) try clickSort(app, g, col);
        return;
    }
    if (graph_view.wipButtonOf(hit_id)) |b| {
        if (m.button != .left) return;
        runToast(app, command.run(app, .{ .static = switch (b) {
            .stage_all => .@"git.stage_all",
            .unstage_all => .@"git.unstage_all",
            .commit => .@"git.commit",
        } }));
        return;
    }
    if (hit_id == graph_view.divider_id) {
        if (m.button == .left) app.drag = .{ .graph_divider = id };
        return;
    }
    if (graph_view.detailRowOf(hit_id)) |row| {
        const was = g.detail_focus and g.detail_cursor == row;
        g.detail_focus = true;
        g.detail_cursor = row;
        if (was and m.button == .left) runToast(app, openDetailRow(app, g));
        app.needs_render = true;
        return;
    }
    if (hit_id >= g.totalRows()) return;
    const again = g.cursor == hit_id;
    g.detail_focus = false;
    moveGraphCursor(app, g, hit_id);
    if (m.button == .right) return openGraphMenu(app, m.x, m.y);
    if (again and m.button == .left) runToast(app, openDetail(app, g));
    app.needs_render = true;
}

fn openGraphMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Details", .action = .{ .command = .@"git.graph_detail" } },
        .{ .label = "Cherry-pick onto HEAD", .action = .{ .command = .@"git.cherry_pick" }, .separator_before = true },
        .{ .label = "Revert", .action = .{ .command = .@"git.revert" } },
        .{ .label = "Browse commit on remote", .action = .{ .command = .@"git.browse_commit" }, .separator_before = true },
        .{ .label = "Sort by next column", .action = .{ .command = .@"git.graph_sort" }, .separator_before = true },
        .{ .label = "Jump to hash…", .action = .{ .command = .@"git.graph_jump_hash" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Commit", items, x, y);
}

/// The detail divider follows the pointer while it is held.
pub fn dragGraphDivider(app: *App, id: PaneId, x: u16) void {
    const pane = app.panes.get(id) orelse return;
    const g = switch (pane.*) {
        .git_graph => |*gp| gp,
        else => return,
    };
    if (g.body.w == 0) return;
    const right = g.body.right();
    g.detail_w = @intCast(std.math.clamp(@as(u32, right -| x) -| 1, 20, @max(@as(u32, g.body.w / 2), 20)));
    app.needs_render = true;
}

/// A command reached outside `command.run`: toast the reason the same way.
pub fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("git: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.git;
    switch (m.kind) {
        .press => {
            if (idx >= st.filtered.items.len) return;
            focusPanel(app);
            st.rail.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                if (st.selectedRow()) |row| runToast(app, actOnRow(app, row, .open));
            }
        },
        .scroll_up => st.rail.cursor -|= 3,
        .scroll_down => st.rail.cursor = @min(st.rail.cursor + 3, st.filtered.items.len -| 1),
        else => {},
    }
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.git.filtered.items.len) return;
    focusPanel(app);
    app.git.rail.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => runToast(app, requestStatus(app)),
        .new => runToast(app, command.run(app, .{ .static = .@"git.commit" })),
        .sort, .view => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.git.rail.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.git;
    const total = st.filtered.items.len;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            const off: usize = m.y -| bar.y;
            st.rail.cursor = @min(off * total / bar.h, total - 1);
        },
        .scroll_up => st.rail.cursor -|= 3,
        .scroll_down => st.rail.cursor = @min(st.rail.cursor + 3, total - 1),
        else => {},
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .git };
    app.needs_render = true;
}

/// A status-pane row was clicked (`.script_hit`): select, a second
/// click opens the diff, right opens the row menu.
pub fn statusPaneClick(app: *App, sp: *StatusPane, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.git;
    if (idx == status_view.badge_id) {
        if (m.kind == .press and m.button == .left) runToast(app, command.run(app, .{ .static = .@"git.browse_commit" }));
        return;
    }
    if (idx >= st.rows.items.len) return;
    const was = sp.cursor;
    sp.cursor = idx;
    if (m.button == .right) return openRowMenu(app, m.x, m.y);
    if (was == idx) runToast(app, actOnRow(app, st.rows.items[idx], .open));
}

fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const st = &app.git;
    if (st.selectedRow()) |row| if (row.kind != .status) return openRailMenu(app, x, y);
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Open diff", .action = .{ .command = .@"git.diff_file" } },
        .{ .label = "Open file", .action = .{ .command = .@"git.open_file" } },
        .{ .label = "Stage", .action = .{ .command = .@"git.stage" }, .separator_before = true },
        .{ .label = "Unstage", .action = .{ .command = .@"git.unstage" } },
        .{ .label = "Discard changes…", .action = .{ .command = .@"git.discard" } },
        .{ .label = "Stage all", .action = .{ .command = .@"git.stage_all" }, .separator_before = true },
        .{ .label = "Unstage all", .action = .{ .command = .@"git.unstage_all" } },
        .{ .label = "Commit…", .action = .{ .command = .@"git.commit" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Git", items, x, y);
}

fn openRailMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Checkout…", .action = .{ .command = .@"git.checkout" } },
        .{ .label = "New branch…", .action = .{ .command = .@"git.new_branch" } },
        .{ .label = "Delete branch…", .action = .{ .command = .@"git.delete_branch" } },
        .{ .label = "Merge into current…", .action = .{ .command = .@"git.merge" }, .separator_before = true },
        .{ .label = "Rebase onto…", .action = .{ .command = .@"git.rebase" } },
        .{ .label = "Add worktree…", .action = .{ .command = .@"git.worktree_add" }, .separator_before = true },
        .{ .label = "Remove worktree…", .action = .{ .command = .@"git.worktree_remove" } },
        .{ .label = "Fetch", .action = .{ .command = .@"git.fetch" }, .separator_before = true },
        .{ .label = "Hide branch rail", .action = .{ .command = .@"git.branch_rail_toggle" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Branches", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };

/// The rail (the right panel's `.git`).
pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.git;
    if (!st.discovered) discover(app) catch {};
    if (st.activeRepo() != null and st.status == null and !st.status_pending) requestStatus(app) catch {};
    if (st.rail_open and !st.rail_loaded and !st.rail_pending and st.activeRepo() != null) requestRail(app) catch {};
    const rows = try ui.arena.alloc(Row, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = st.rows.items[idx];
    const repo_name: []const u8 = if (st.activeRepo()) |r| r.name else "";
    const branch = st.branchLabel() orelse "";
    const prov = st.provider.label();
    const subtitle = if (st.repos.items.len > 1)
        ui.fmt(" {s} · {s} ({d}){s}{s}", .{ repo_name, branch, st.badge(), if (prov.len > 0) " · " else "", prov })
    else
        ui.fmt(" {s} ({d}){s}{s}", .{ branch, st.badge(), if (prov.len > 0) " · " else "", prov });
    const empty: list_panel.EmptyState = if (st.activeRepo() == null)
        .{ .message = "Not a git repository.", .hint = "git init, or open a workspace with one." }
    else if (st.status == null)
        .{ .message = "Reading git status…", .hint = "" }
    else if (st.rows.items.len == 0)
        .{ .message = "Working tree clean.", .hint = "Nothing to stage or commit." }
    else
        .{ .message = "No matches — Esc clears" };
    const caret = Panel.draw(&st.rail, ui, area, .{
        .panel = .git,
        .label = "GIT",
        .subtitle = subtitle,
        .rows = rows,
        .paintRow = status_view.paintRow,
        .has_kebab = true,
        .empty = empty,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    if (st.busy > 0 or st.status_pending) paintSpinner(app, ui, area, 3);
}

/// The refresh chip's three cells show a spinner while git runs.
fn paintSpinner(app: *App, ui: Ui, area: Rect, label_w: u16) void {
    if (area.w < label_w + 3 + 3 or area.h == 0) return;
    const frames: []const []const u8 = if (ui.ascii) &spinner_ascii else &spinner_frames;
    const idx: usize = @intCast(@mod(@divFloor(app.now_ms, 80), @as(i64, @intCast(frames.len))));
    const style = chip.refreshStyle(ui.theme, ui.theme.panel_bg.bg);
    const x = area.right() - 3;
    _ = ui.putStr(x, area.y, 1, " ", style);
    _ = ui.putStr(x + 1, area.y, 1, frames[idx], style);
    _ = ui.putStr(x + 2, area.y, 1, " ", style);
}

/// `Pane.git_status`.
pub fn drawStatusPane(app: *App, ui: Ui, id: PaneId, sp: *StatusPane, area: Rect) Allocator.Error!void {
    const st = &app.git;
    if (st.activeRepo() != null and st.status == null and !st.status_pending) requestStatus(app) catch {};
    const repo_name: []const u8 = if (st.repoById(sp.repo)) |r| r.name else "";
    const branch = st.branchLabel() orelse "…";
    const header = ui.fmt(" {s} · {s} · {d} change{s}   ·   s stage · u unstage · x discard · a all · c commit · b branches · enter diff ", .{ repo_name, branch, st.badge(), if (st.badge() == 1) "" else "s" });
    const focused = app.active == id and app.focus == .pane;
    status_view.drawPane(ui, id, area, .{ .header = header, .rows = st.rows.items, .cursor = sp.cursor, .focused = focused, .empty = if (st.status == null) "Reading git status…" else "Working tree clean.", .badge = st.provider.label() }, &sp.scroll);
    if (app.active == id) app.pane_rows = @max(area.h -| 1, 1);
}

/// `Pane.diff`.
pub fn drawDiffPane(app: *App, ui: Ui, id: PaneId, dp: *DiffPane, area: Rect) void {
    const focused = app.active == id and app.focus == .pane;
    var hunks: usize = 0;
    for (dp.files) |f| hunks += f.hunks.len;
    const header = if (dp.pending and dp.rows.len == 0)
        ui.fmt(" {s} · loading… ", .{dp.title})
    else
        ui.fmt(" {s} · {d} file{s} · {d} hunk{s} ", .{ dp.title, dp.files.len, if (dp.files.len == 1) "" else "s", hunks, if (hunks == 1) "" else "s" });
    const painted = diff_view.draw(ui, id, area, &dp.view, .{
        .files = dp.files,
        .rows = dp.rows,
        .shown = dp.shown,
        .split_rows = dp.split_rows,
        .split_shown = dp.split_shown,
        .mode = dp.mode,
        .cursor = dp.cursor,
        .focused = focused,
        .header = header,
        .filter = dp.filter.items,
        .filter_mode = dp.filter_mode,
        .ratio = dp.ratio,
    });
    dp.body = painted.body;
    dp.strip_cells = painted.strip_cells;
    if (app.active == id) app.pane_rows = @max(area.h -| 1, 1);
}

/// `Pane.git_graph`.
pub fn drawGraphPane(app: *App, ui: Ui, id: PaneId, g: *GraphPane, area: Rect) void {
    const st = &app.git;
    syncWip(app, g);
    const focused = app.active == id and app.focus == .pane;
    const repo_name: []const u8 = if (st.repoById(g.repo)) |r| r.name else "";
    const filtered = g.filter.branch != null or g.filter.author != null or g.filter.subject != null or g.filter.since != null or g.filter.until != null;
    const header = if (g.pending and g.commits.len == 0)
        ui.fmt(" {s} · graph · loading… ", .{repo_name})
    else
        ui.fmt(" {s} · {d} commit{s}{s}   ·   enter detail · tab focus · d diff · s sort · / hash · c cherry-pick · v revert · f branch · F clear ", .{ repo_name, g.commits.len, if (g.commits.len == 1) "" else "s", if (filtered) " (filtered)" else "" });
    const now = nowUnix(app);
    const wip_label = if (g.has_wip) ui.fmt("WIP @ {s} · {d} change{s}", .{ st.branchLabel() orelse "…", st.badge(), if (st.badge() == 1) "" else "s" }) else "";
    var detail: ?graph_view.DetailDoc = null;
    if (g.detail_open) {
        if (g.wipSelected()) {
            detail = .{ .title = wip_label, .wip = true, .entries = if (st.status) |s| s.entries else &.{} };
        } else if (g.selected()) |c| {
            var age_buf: [16]u8 = undefined;
            const age = parse.relativeAge(&age_buf, c.time, now);
            const title = ui.fmt("{s} · {s} · {s}", .{ c.short(), c.author, age });
            if (g.detail) |d| if (std.mem.eql(u8, d.sha, c.hash)) {
                detail = .{ .title = title, .message = d.message, .files = d.files };
            };
            if (detail == null) detail = .{ .title = title, .pending = true };
        }
    }
    const detail_w: u16 = g.detail_w orelse (app.cfg.ui.git_graph_detail_col orelse 40);
    const painted = graph_view.draw(ui, id, area, &g.view, .{
        .commits = g.commits,
        .lanes = g.lanes,
        .order = g.order,
        .cursor = g.cursor,
        .focused = focused,
        .header = header,
        .lane_spacing = app.cfg.git_graph.lane_spacing,
        .now = now,
        .sort = g.sort,
        .has_wip = g.has_wip,
        .wip_label = wip_label,
        .detail = detail,
        .detail_w = detail_w,
        .detail_focus = g.detail_focus,
        .detail_cursor = g.detail_cursor,
    });
    g.body = painted.body;
    if (app.active == id) app.pane_rows = @max(area.h -| 2, 1);
}

/// The statusline segment: `main ↑2 ↓1 ●3`, on the frame arena.
pub fn statusSegment(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    const st = &app.git;
    const branch = st.branchLabel() orelse return null;
    const s = st.status.?;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const ascii = app.cfg.ui.ascii_icons;
    try out.print(arena, "{s}{s}", .{ if (ascii) "git:" else " ", branch });
    if (s.ahead > 0) try out.print(arena, " {s}{d}", .{ if (ascii) "^" else "↑", s.ahead });
    if (s.behind > 0) try out.print(arena, " {s}{d}", .{ if (ascii) "v" else "↓", s.behind });
    const n = s.changeCount();
    if (n > 0) try out.print(arena, " {s}{d}", .{ if (ascii) "*" else "●", n });
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    /// Run `git <args>` in the fixture's workspace (the test's own git,
    /// not the worker's).
    fn sh(f: *Fixture, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=tester" });
        try argv.appendSlice(testing.allocator, args);
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = f.root } });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], res.stderr });
            return error.GitFailed;
        }
    }

    /// Tick until no git job is outstanding (or `max` ticks pass).
    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (i < max) : (i += 1) {
            try f.app.tick(App.nowMs(testing.io));
            if (!f.app.git.status_pending and f.app.git.busy == 0 and f.app.git.blame_pending == null and !f.app.git.rail_pending and f.app.git.ai_wait == null and !anyPanePending(&f.app)) return;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn anyPanePending(app: *App) bool {
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .diff => |*d| if (d.pending) return true,
            .git_graph => |*g| if (g.pending or g.detail_pending) return true,
            else => {},
        };
        return false;
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("../ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }
};

test "discover: the workspace repo wins outright; otherwise sub-repos by name; a refresh keeps the Repo objects" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "beta/.git");
    try f.tmp.dir.createDirPath(testing.io, "Alpha/.git");
    try f.tmp.dir.createDirPath(testing.io, "node_modules/x/.git");
    try f.tmp.dir.createDirPath(testing.io, ".hidden/.git");
    try f.tmp.dir.createDirPath(testing.io, "plain/deeper/gamma/.git");
    try discover(&f.app);
    const st = &f.app.git;
    try testing.expectEqual(@as(usize, 3), st.repos.items.len);
    try testing.expectEqualStrings("Alpha", st.repos.items[0].name);
    try testing.expectEqualStrings("beta", st.repos.items[1].name);
    try testing.expectEqualStrings("gamma", st.repos.items[2].name);
    try testing.expectEqual(@as(?usize, 0), st.active);
    const beta = st.repos.items[1];
    try switchTo(&f.app, 1);
    try testing.expectEqual(@as(?usize, 1), st.active);
    // A second discovery keeps the same Repo (its worker, its undo stack).
    try discover(&f.app);
    try testing.expect(st.repos.items[1] == beta);
    try testing.expectEqual(@as(?usize, 1), st.active);
    // The workspace itself becoming a repo wins outright.
    try f.tmp.dir.createDirPath(testing.io, ".git");
    try discover(&f.app);
    try testing.expectEqual(@as(usize, 1), st.repos.items.len);
    try testing.expect(st.repos.items[0].is_workspace_root);
    try testing.expectEqualStrings(f.root, st.repos.items[0].path);
}

test "discover: every extra workspace root brings its repo, or the repos under it, after the primary's" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, ".git");
    try f.tmp.dir.createDirPath(testing.io, "other/.git");
    try f.tmp.dir.createDirPath(testing.io, "plain/deep/.git");
    const other = try std.fs.path.join(testing.allocator, &.{ f.root, "other" });
    defer testing.allocator.free(other);
    const plain = try std.fs.path.join(testing.allocator, &.{ f.root, "plain" });
    defer testing.allocator.free(plain);
    _ = try f.app.tree.addRoot(&f.app, other, "sibling");
    _ = try f.app.tree.addRoot(&f.app, plain, null);
    try discover(&f.app);
    const st = &f.app.git;
    // The workspace wins outright for its own tree; the roots still land.
    try testing.expectEqual(@as(usize, 3), st.repos.items.len);
    try testing.expect(st.repos.items[0].is_workspace_root);
    try testing.expectEqualStrings("sibling", st.repos.items[1].name);
    try testing.expectEqualStrings(other, st.repos.items[1].path);
    try testing.expect(!st.repos.items[1].is_workspace_root);
    try testing.expectEqualStrings("deep", st.repos.items[2].name);
    try testing.expectEqual(@as(?usize, 0), st.active);
    // Switching to a root's repo survives a rediscovery.
    try switchTo(&f.app, 1);
    try discover(&f.app);
    try testing.expectEqual(@as(?usize, 1), st.active);
    try testing.expectEqualStrings("sibling", st.activeRepo().?.name);
}

test "handle adopts a status result for the active repo, drops one from an unknown repo, and frees both" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, ".git");
    try discover(&f.app);
    const st = &f.app.git;
    const id = st.activeRepo().?.id;
    const r = try client.Result.create(testing.allocator, id);
    const text = "# branch.head main\n# branch.ab +1 -0\n1 .M N... 100644 100644 100644 a b src/a.zig\n? new.txt\n";
    r.payload = .{ .status = .{ .status = try parse.parseStatus(r.arena.allocator(), text), .signs = &.{} } };
    st.status_pending = true;
    try handle(&f.app, r);
    try testing.expect(!st.status_pending);
    try testing.expectEqualStrings("main", st.branchLabel().?);
    try testing.expectEqual(@as(u32, 2), st.badge());
    // Rows: Changes header, a.zig, Untracked header, new.txt.
    try testing.expectEqual(@as(usize, 4), st.rows.items.len);
    try testing.expect(st.rows.items[0].header);
    try testing.expectEqualStrings("src/a.zig", st.rows.items[1].path);
    try testing.expectEqualStrings("new.txt", st.rows.items[3].path);
    const seg = (try statusSegment(&f.app, f.app.frame.allocator())).?;
    try testing.expect(std.mem.indexOf(u8, seg, "main") != null);
    try testing.expect(std.mem.indexOf(u8, seg, "↑1") != null);
    try testing.expect(std.mem.indexOf(u8, seg, "●2") != null);
    // A result from a repo id nobody knows is dropped whole.
    const stale = try client.Result.create(testing.allocator, 999);
    stale.payload = .{ .status = .{ .status = try parse.parseStatus(stale.arena.allocator(), "# branch.head other\n"), .signs = &.{} } };
    try handle(&f.app, stale);
    try testing.expectEqualStrings("main", st.branchLabel().?);
}

test "the status TTL: tick asks again 3 s after the last snapshot, not before" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, ".git");
    try discover(&f.app);
    const st = &f.app.git;
    // A snapshot "landed" just now.
    st.status_at_ms = f.app.now_ms;
    st.status_pending = false;
    try tick(&f.app, f.app.now_ms + status_ttl_ms - 1);
    try testing.expect(!st.status_pending);
    try tick(&f.app, f.app.now_ms + status_ttl_ms);
    try testing.expect(st.status_pending);
    // The worker on a fake `.git` posts a failed `op`; whatever it says,
    // nothing here waited for it.
}

test "headless smoke: git init → the rail lists an untracked file; stage moves it; git.diff_file opens a pane with a + line; blame labels the gutter" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q" });
    try f.write("seed.txt", "seed\n");
    try f.sh(&.{ "add", "seed.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "initial" });
    try f.write("new.txt", "hello\n");
    f.app.tree.visible = false;
    const st = &f.app.git;

    // The status call never blocks: it returns with the job pending.
    try command.run(&f.app, .{ .static = .@"view.activity_git" });
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try testing.expect(st.status_pending);
    try testing.expect(st.status == null);
    try f.settle(2000);
    try testing.expect(st.status != null);
    try testing.expectEqual(@as(u32, 1), st.badge());
    var txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "GIT") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Untracked (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "new.txt") != null);
    testing.allocator.free(txt);

    // Stage everything: the file moves to the Staged group.
    try command.run(&f.app, .{ .static = .@"git.stage_all" });
    try f.settle(2000);
    try f.settle(2000);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "Staged (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Untracked") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "A new.txt") != null);
    testing.allocator.free(txt);

    // A modified tracked file: its diff pane shows the +/- lines and the
    // gutter mark lands on the editor.
    try f.write("seed.txt", "seed\nmore\n");
    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "seed.txt" });
    defer testing.allocator.free(abs);
    _ = try f.app.openPath(abs);
    try command.run(&f.app, .{ .static = .@"git.diff_file" });
    try f.settle(2000);
    const dp = activeDiff(&f.app).?;
    try testing.expect(!dp.pending);
    try testing.expectEqual(@as(usize, 1), dp.files.len);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "diff: seed.txt") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "+more") != null);
    testing.allocator.free(txt);
    try requestStatus(&f.app);
    try f.settle(2000);
    const marks = marksFor(&f.app, abs);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqual(parse.MarkKind.added, marks[0].kind);
    try testing.expectEqual(@as(u32, 1), marks[0].line);

    // Blame on the editor: the gutter carries the author.
    _ = try f.app.openPath(abs);
    try command.run(&f.app, .{ .static = .@"git.blame_toggle" });
    try f.settle(2000);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "tester") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "not committed") != null);
    testing.allocator.free(txt);
    try command.run(&f.app, .{ .static = .@"git.blame_toggle" });
    try testing.expectEqualStrings("blame: off", f.app.lastToast().?);
}

test "the graph pane lays out the log, and enter opens the commit's diff" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f.write("a.txt", "one\ntwo\n");
    try f.sh(&.{ "commit", "-q", "-am", "second commit" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(2000);
    const g = activeGraph(&f.app).?;
    try testing.expectEqual(@as(usize, 2), g.commits.len);
    try testing.expectEqualStrings("second commit", g.commits[0].subject);
    try testing.expectEqual(@as(u16, 0), g.lanes[1].lane);
    var txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "second commit") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "2 commits") != null);
    testing.allocator.free(txt);
    // Enter opens the detail panel: the message and the file list.
    try f.app.handle(.{ .key = Key.named(.enter) });
    try f.settle(2000);
    try testing.expect(g.detail_open);
    try testing.expect(g.detail != null);
    try testing.expectEqualStrings("second commit", g.detail.?.message);
    try testing.expectEqual(@as(usize, 1), g.detail.?.files.len);
    try testing.expectEqualStrings("a.txt", g.detail.?.files[0].path);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "files (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "M a.txt") != null);
    testing.allocator.free(txt);
    // Moving the cursor fetches the next commit's detail.
    try f.app.handle(.{ .key = Key.char('j') });
    try f.settle(2000);
    try testing.expectEqualStrings("first commit", g.detail.?.message);
    // `/` jumps by hash prefix; `d` opens the commit's diff.
    const target = g.commits[0].hash[0..4];
    try f.app.handle(.{ .key = Key.char('/') });
    for (target) |ch| try f.app.handle(.{ .key = Key.char(ch) });
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqual(@as(usize, 0), g.cursor);
    try f.app.handle(.{ .key = Key.char('d') });
    try f.settle(2000);
    const dp = activeDiff(&f.app).?;
    try testing.expectEqual(client.DiffScope.commit, dp.scope);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "+two") != null);
    testing.allocator.free(txt);
}

test "the WIP row: a dirty tree puts it first, its buttons stage / unstage through the worker, and the cursor keeps its commit" {
    var f = try Fixture.init(120, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f.write("b.txt", "new\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try requestStatus(&f.app);
    try f.settle(2000);
    const g = activeGraph(&f.app).?;
    try testing.expect(g.has_wip);
    try testing.expectEqual(@as(usize, 2), g.totalRows());
    try testing.expect(g.wipSelected());
    const txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "WIP @") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[stage all]") != null);
    testing.allocator.free(txt);
    // The stage-all button goes through the worker like the command.
    try graphClick(&f.app, f.app.active.?, g, graph_view.wipButtonId(.stage_all), .{ .x = 0, .y = 0, .kind = .press, .button = .left, .mods = .{} });
    try testing.expect(f.app.git.busy > 0);
    try f.settle(2000);
    try f.settle(2000);
    try testing.expectEqual(@as(u32, 1), f.app.git.status.?.staged);
    // Commit it: the WIP row goes and the cursor lands on the commit it
    // was above.
    try f.app.handle(.{ .key = Key.char('j') });
    try testing.expectEqual(@as(usize, 1), g.cursor);
    try f.sh(&.{ "commit", "-q", "-m", "second commit" });
    try requestStatus(&f.app);
    try f.settle(2000);
    syncWip(&f.app, g);
    try testing.expect(!g.has_wip);
    try testing.expectEqual(@as(usize, 0), g.cursor);
}

test "cleanCommitMessage strips fences and splits the subject from the body" {
    const m = cleanCommitMessage("```\nfix: the thing\n\nA body line.\n```\n");
    try testing.expectEqualStrings("fix: the thing", m.subject);
    try testing.expectEqualStrings("A body line.", m.body);
    const bare = cleanCommitMessage("  just a subject  ");
    try testing.expectEqualStrings("just a subject", bare.subject);
    try testing.expectEqual(@as(usize, 0), bare.body.len);
}

test "the branch rail: toggling it lists the branches with their tracking counts, worktrees and the PR note; a section folds; a branch row asks before checkout" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.sh(&.{ "branch", "feature" });
    f.app.tree.visible = false;
    const st = &f.app.git;
    try command.run(&f.app, .{ .static = .@"view.activity_git" });
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(2000);
    try testing.expect(!st.rail_open);
    try command.run(&f.app, .{ .static = .@"git.branch_rail_toggle" });
    try testing.expect(st.rail_open);
    try f.settle(2000);
    try testing.expect(st.rail_loaded);
    try testing.expectEqual(@as(usize, 2), st.rail_branches.len);
    try testing.expectEqual(@as(usize, 1), st.rail_worktrees.len);
    var txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "Branches (2)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "* main") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "feature") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Worktrees (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Pull requests (0)") != null);
    testing.allocator.free(txt);
    // Fold the branches section: its rows go, the header stays.
    var branches_row: ?usize = null;
    var feature_row: ?usize = null;
    for (st.rows.items, 0..) |r, i| {
        if (r.kind == .section and r.section == .branches) branches_row = i;
        if (r.kind == .branch and std.mem.eql(u8, r.path, "feature")) feature_row = i;
    }
    try testing.expect(feature_row != null);
    try actOnRow(&f.app, st.rows.items[branches_row.?], .open);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "▸ Branches (2)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "feature") == null);
    testing.allocator.free(txt);
    try actOnRow(&f.app, st.rows.items[branches_row.?], .open);
    // Enter on `feature` asks first; yes checks it out through the worker.
    feature_row = null;
    for (st.rows.items, 0..) |r, i| if (r.kind == .branch and std.mem.eql(u8, r.path, "feature")) {
        feature_row = i;
    };
    try actOnRow(&f.app, st.rows.items[feature_row.?], .open);
    try testing.expect(f.app.overlay == .confirm);
    try testing.expect(st.confirm == .checkout);
    try acceptConfirm(&f.app, 0);
    try f.settle(2000);
    try f.settle(2000);
    try testing.expectEqualStrings("feature", st.branchLabel().?);
    // Hiding the rail drops its rows.
    try command.run(&f.app, .{ .static = .@"git.branch_rail_toggle" });
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "Branches (") == null);
    testing.allocator.free(txt);
}

test "git.worktree_add: Tab completes the path — the first word — and leaves the branch after it alone" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q" });
    try f.tmp.dir.createDirPath(testing.io, "projects/alpha");
    try f.tmp.dir.createDirPath(testing.io, "projects/alps");
    try f.write("projects/alpha.txt", "x");
    try discover(&f.app);
    try command.run(&f.app, .{ .static = .@"git.worktree_add" });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqual(PromptKind.worktree_add, f.app.git.prompt);
    for ("projects/al feat") |c| try f.app.handle(.{ .key = Key.char(c) });
    try f.app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqualStrings("projects/alpha/ feat", f.app.overlay.prompt.state.buf.items);
    try f.app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqualStrings("projects/alps/ feat", f.app.overlay.prompt.state.buf.items);
    try f.app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqualStrings("projects/alpha/ feat", f.app.overlay.prompt.state.buf.items);
    // Any other key ends the cycle; the next Tab starts from the new text.
    try f.app.handle(.{ .key = Key.named(.backspace) });
    try f.app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqualStrings("projects/alpha/ fea", f.app.overlay.prompt.state.buf.items);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(f.app.overlay == .none);
}
