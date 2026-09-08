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
const git_toolbar = @import("../ui/git_toolbar.zig");
const graph_view = @import("../ui/git_graph_view.zig");
const text_field = @import("../ui/text_field.zig");
const editor_view = @import("../ui/editor_view.zig");
const cmd_picker = @import("cmd_picker.zig");
const git_palette = @import("git_palette.zig");
const conflicts = @import("conflicts.zig");

/// A file the status pane lists (`ui/git_status_view.zig`): its
/// porcelain letter and which section it sits in.
pub const Row = status_view.Entry;

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
    /// The palette's closed-repo picker.
    reopen_repo,
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
    /// The diff pane's `Commit these lines`: the message for
    /// `State.line_patch`.
    commit_lines,
};

/// A confirm box's payload; the path is owned.
pub const Confirm = union(enum) {
    none,
    discard: []u8,
    discard_hunk: struct { pane: PaneId },
    delete_branch: []u8,
    worktree_remove: []u8,
    /// A palette row: checkout after a yes (a tag lands detached).
    checkout: []u8,
    tag_delete: []u8,

    pub fn deinit(c: Confirm, gpa: Allocator) void {
        switch (c) {
            .discard, .delete_branch, .worktree_remove, .checkout, .tag_delete => |s| gpa.free(s),
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
    mode: diff_view.Mode = .flat,
    /// The loaded diff carries every line (Inline / Split asked for it).
    full: bool = false,
    /// The toolbar's Wrap: long lines continue on the next row.
    wrap: bool = false,
    /// Index into `rows` (Hunk / Inline) or `split_rows` (Split).
    cursor: usize = 0,
    /// The line selection's other end (`v`, shift+arrows, a drag); the
    /// verbs act on the selected lines while one is set. Cleared when
    /// the rows are rebuilt.
    anchor: ?usize = null,
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
    /// The repo's name — the tab's title. Owned.
    name: []u8,
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
    /// The detail column has the keys (tab), walking its file rows.
    detail_focus: bool = false,
    detail_cursor: usize = 0,
    /// The commit box: its text (owned), caret, focus, and whether an
    /// AI message is on its way into it.
    wip_text: text_field.Buf = .empty,
    wip_cursor: usize = 0,
    wip_focused: bool = false,
    wip_ai: bool = false,
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
        self.gpa.free(self.name);
        self.wip_text.deinit(self.gpa);
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

/// A repo's rail as `State.rails` parks it: the worker's arena, adopted
/// whole, and the lists into it.
pub const RepoRail = struct {
    snapshot: alloc.SnapshotArena,
    branches: []parse.Branch = &.{},
    worktrees: []parse.Worktree = &.{},
    remotes: []parse.Remote = &.{},
    stashes: []parse.Stash = &.{},
    tags: []parse.Tag = &.{},
    prs: []parse.Pr = &.{},
    loaded: bool = false,
    pending: bool = false,
};

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
    diff_mode: diff_view.Mode = .flat,
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
    /// The patch a `commit_lines` prompt will commit, and its repo.
    /// Owned; taken by the accept, dropped by a cancel.
    line_patch: ?[]u8 = null,
    line_repo: u32 = 0,
    /// Conflicts (`app/conflicts.zig`): vim's `c` inside a block is
    /// waiting for `o` / `t` / `b`; and the editor pane + block an AI
    /// resolve was asked for, until the three stages land.
    conflict_c_pending: bool = false,
    conflict_ai: ?struct { pane: PaneId, region: u32 } = null,
    /// The palette's data (`app/git_palette.zig`): its own snapshot.
    rail_pending: bool = false,
    rail_snapshot: alloc.SnapshotArena,
    rail_branches: []parse.Branch = &.{},
    rail_worktrees: []parse.Worktree = &.{},
    rail_remotes: []parse.Remote = &.{},
    rail_stashes: []parse.Stash = &.{},
    rail_tags: []parse.Tag = &.{},
    rail_prs: []parse.Pr = &.{},
    /// The rail was asked for without `gh`; said once.
    rail_gh_toasted: bool = false,
    rail_loaded: bool = false,
    /// All repos (`app/git_palette.zig`): the rails of the repos that
    /// are NOT the active one, by repo id, each on its own arena. The
    /// active repo's stays in `rail_*` — every consumer reads it there
    /// — and `switchTo` MOVES a rail between the two rather than
    /// copying, so the palette's rows stay valid across the switch.
    rails: std.AutoHashMapUnmanaged(u32, RepoRail) = .empty,

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
        self.confirm.deinit(gpa);
        if (self.ai_body) |b| gpa.free(b);
        if (self.line_patch) |b| gpa.free(b);
        var rit = self.rails.valueIterator();
        while (rit.next()) |r| r.snapshot.deinit();
        self.rails.deinit(gpa);
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
    // The rails parked for repos that are gone go with them.
    {
        var gone_ids: std.ArrayListUnmanaged(u32) = .empty;
        var it = st.rails.keyIterator();
        while (it.next()) |k| if (st.repoById(k.*) == null) try gone_ids.append(arena, k.*);
        for (gone_ids.items) |id| if (st.rails.fetchRemove(id)) |kv| {
            var r = kv.value;
            r.snapshot.deinit();
        };
    }
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
        parkRail(app, was);
        clearStatus(app);
        unparkRail(app, r.id);
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .git_status => |*s| s.repo = r.id,
            else => {},
        };
        try requestStatus(app);
        app.toast("active repo → {s}", .{r.name});
    }
    app.needs_render = true;
}

/// The `rails` entry for `id`, made empty when there is none.
pub fn railEntry(app: *App, id: u32) Allocator.Error!*RepoRail {
    const st = &app.git;
    const gop = try st.rails.getOrPut(app.gpa, id);
    if (!gop.found_existing) gop.value_ptr.* = .{ .snapshot = alloc.SnapshotArena.init(app.gpa) };
    return gop.value_ptr;
}

/// The active repo's rail (index `was`) moves into `rails` — its arena
/// with it, so nothing that borrows it is freed — ahead of the
/// `clearStatus` that empties `rail_*`. Nothing to park before the
/// first rail lands; a request in flight follows the repo.
fn parkRail(app: *App, was: ?usize) void {
    const st = &app.git;
    const i = was orelse return;
    if (i >= st.repos.items.len) return;
    if (!st.rail_loaded) return;
    const e = railEntry(app, st.repos.items[i].id) catch return;
    e.snapshot.arena.deinit();
    e.snapshot.arena = st.rail_snapshot.arena;
    st.rail_snapshot.arena = std.heap.ArenaAllocator.init(app.gpa);
    e.branches = st.rail_branches;
    e.worktrees = st.rail_worktrees;
    e.remotes = st.rail_remotes;
    e.stashes = st.rail_stashes;
    e.tags = st.rail_tags;
    e.prs = st.rail_prs;
    e.loaded = true;
    e.pending = st.rail_pending;
}

/// A rail parked under `id` becomes the active one's, arena and all.
fn unparkRail(app: *App, id: u32) void {
    const st = &app.git;
    const kv = st.rails.fetchRemove(id) orelse return;
    var r = kv.value;
    st.rail_pending = r.pending;
    if (!r.loaded) {
        r.snapshot.deinit();
        return;
    }
    st.rail_snapshot.arena.deinit();
    st.rail_snapshot.arena = r.snapshot.arena;
    st.rail_branches = r.branches;
    st.rail_worktrees = r.worktrees;
    st.rail_remotes = r.remotes;
    st.rail_stashes = r.stashes;
    st.rail_tags = r.tags;
    st.rail_prs = r.prs;
    st.rail_loaded = true;
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
        if (app.panes.editor(pane)) |e| if (e.buf.doc.path) |p| {
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
    // The statusline's branch chip is the first git surface most
    // sessions show: the repos are looked up on the first tick, not
    // the first git pane.
    if (!st.discovered) try discover(app);
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
    // `ui.external_browser` names the application (trust-stripped upstream).
    const argv = @import("browser_open.zig").argv(app, app.frame.allocator(), url) catch return;
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
                    dp.anchor = null;
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
            const abs = e.buf.doc.path orelse return;
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
                    if (!g.wipSelected()) requestDetail(app, g) catch {};
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
        .conflict_text => |c| try conflicts.aiContextReady(app, c.path, c.base, c.ours, c.theirs),
        .rail => |rail| {
            const active = st.activeRepo();
            if (active == null or active.?.id != repo.id) {
                // Another repo's, asked for by All repos: parked on its own arena.
                const e = try railEntry(app, repo.id);
                e.pending = false;
                adoptArena(&e.snapshot.arena, &result.arena, gpa);
                e.branches = rail.branches;
                e.worktrees = rail.worktrees;
                e.remotes = rail.remotes;
                e.stashes = rail.stashes;
                e.tags = rail.tags;
                e.prs = rail.prs;
                e.loaded = true;
                return;
            }
            st.rail_pending = false;
            adoptArena(&st.rail_snapshot.arena, &result.arena, gpa);
            st.rail_branches = rail.branches;
            st.rail_worktrees = rail.worktrees;
            st.rail_remotes = rail.remotes;
            st.rail_stashes = rail.stashes;
            st.rail_tags = rail.tags;
            st.rail_prs = rail.prs;
            st.rail_loaded = true;
            if (!rail.gh and !st.rail_gh_toasted) {
                st.rail_gh_toasted = true;
                app.toast("open PRs need `gh` on PATH", .{});
            }
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
    if (st.activeRepo()) |a| {
        if (a.id == repo.id) {
            st.status_pending = false;
            requestStatus(app) catch {};
            if (app.git_palette.active) requestRail(app) catch {};
        } else if (app.git_palette.active and app.git_palette.all) requestRailFor(app, repo, true) catch {};
    }
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
    st.rail_remotes = &.{};
    st.rail_stashes = &.{};
    st.rail_tags = &.{};
    st.rail_prs = &.{};
    st.rail_loaded = false;
    st.rail_pending = false;
    st.rail_snapshot.reset();
    st.marks.clearRetainingCapacity();
    st.snapshot.reset();
    app.needs_render = true;
}

// ─── the status pane's lists ────────────────────────────────────────────

pub const Files = struct {
    unstaged: []Row,
    staged: []Row,

    pub fn len(f: Files) usize {
        return f.unstaged.len + f.staged.len;
    }

    /// The `flat`-th row: the unstaged first, then the staged.
    pub fn at(f: Files, flat: usize) ?Row {
        if (flat < f.unstaged.len) return f.unstaged[flat];
        if (flat - f.unstaged.len < f.staged.len) return f.staged[flat - f.unstaged.len];
        return null;
    }
};

/// Rust `git::stage::lists`: the snapshot's entries in porcelain order,
/// untracked (`?`) and conflicted (`U`) files unstaged, a file changed
/// on both sides in both lists. The graph's detail column (`wipFiles`)
/// wants the same split with the untracked directory's slash dropped,
/// `!` on a conflict and each list A–Z.
fn collectFiles(app: *App, arena: Allocator, for_graph: bool) Allocator.Error!Files {
    var un: std.ArrayListUnmanaged(Row) = .empty;
    var st: std.ArrayListUnmanaged(Row) = .empty;
    if (app.git.status) |status| for (status.entries) |e| {
        switch (e.group) {
            .staged => try st.append(arena, .{ .path = e.path, .letter = e.code, .staged = true }),
            .unstaged => try un.append(arena, .{ .path = e.path, .letter = e.code, .staged = false }),
            .untracked => try un.append(arena, .{ .path = if (for_graph) std.mem.trimEnd(u8, e.path, "/") else e.path, .letter = '?', .staged = false }),
            .conflicted => try un.append(arena, .{ .path = e.path, .letter = if (for_graph) '!' else 'U', .staged = false }),
        }
    };
    if (for_graph) {
        std.mem.sort(Row, un.items, {}, byPath);
        std.mem.sort(Row, st.items, {}, byPath);
    }
    return .{ .unstaged = un.items, .staged = st.items };
}

fn byPath(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The status pane's two lists.
pub fn statusFiles(app: *App, arena: Allocator) Allocator.Error!Files {
    return collectFiles(app, arena, false);
}

/// Every entry of the snapshot is one row of the pane.
pub fn statusFlatLen(app: *App) usize {
    return if (app.git.status) |s| s.entries.len else 0;
}

/// The status pane's cursor row.
pub fn statusPaneRow(app: *App, sp: *const StatusPane) Allocator.Error!?Row {
    return (try statusFiles(app, app.frame.allocator())).at(sp.cursor);
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
}

/// Ask `repo` for its rail: the active repo's lands in `rail_*`, any
/// other's in `rails` (All repos). `force` asks again for one that has
/// landed; without it a parked rail is kept.
pub fn requestRailFor(app: *App, repo: *client.Repo, force: bool) CommandError!void {
    const st = &app.git;
    if (st.activeRepo()) |a| if (a.id == repo.id) {
        if (!force and st.rail_loaded) return;
        return requestRail(app);
    };
    const e = try railEntry(app, repo.id);
    if (e.pending or (!force and e.loaded)) return;
    e.pending = true;
    submit(app, repo, .{ .rail = .{ .gh = cmd_app.onPath(app, "gh") } }) catch |err| {
        e.pending = false;
        return err;
    };
}

/// A rail on the way for any repo but the active one (the spinner).
pub fn anyRailPending(st: *const State) bool {
    var it = st.rails.valueIterator();
    while (it.next()) |r| if (r.pending) return true;
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
        .conflict => try std.fmt.allocPrint(gpa, "conflict: {s}", .{std.fs.path.basename(rel orelse "")}),
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
    dp.anchor = null;
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

/// The graph pane on `repo`, made when there is none, its log asked
/// for again. The layout is left alone: git mode places the tabs.
pub fn ensureGraphPane(app: *App, repo: *client.Repo) CommandError!PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .git_graph => |*g| if (g.repo == repo.id) {
            try refreshGraph(app, g);
            return @intCast(i);
        },
        else => {},
    };
    var g: GraphPane = .{ .gpa = app.gpa, .repo = repo.id, .name = try app.gpa.dupe(u8, repo.name), .arena = .init(app.gpa), .detail_arena = .init(app.gpa) };
    errdefer g.deinit();
    const id = try app.panes.add(.{ .git_graph = g });
    g = undefined;
    try refreshGraph(app, &app.panes.get(id).?.git_graph);
    return id;
}

pub fn openGraph(app: *App, repo: *client.Repo) CommandError!PaneId {
    const id = try ensureGraphPane(app, repo);
    app.showPane(id);
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
        const h = diff_view.splitRowHunk(dp.split_rows[dp.cursor]) orelse return null;
        return .{ .file = h.file, .hunk = h.hunk };
    }
    if (dp.cursor >= dp.rows.len) return null;
    const h = diff_view.rowHunk(dp.rows[dp.cursor]) orelse return null;
    return .{ .file = h.file, .hunk = h.hunk };
}

pub const LineVerb = enum { stage, unstage, discard };

/// The selected lines of the diff pane: the hunk and, per line of it,
/// whether it is selected; `count` the changed lines among them. Null
/// when there is no selection. In the split view a selected pair
/// selects both of its lines.
pub const LineSelection = struct { file: u32, hunk: u32, mask: []bool, count: usize };

pub fn selectedLines(dp: *const DiffPane, arena: Allocator) Allocator.Error!?LineSelection {
    const sel = diff_view.selectionOf(diffDoc(dp)) orelse return null;
    const h = dp.files[sel.hunk.file].hunks[sel.hunk.hunk];
    const mask = try arena.alloc(bool, h.lines.len);
    @memset(mask, false);
    var count: usize = 0;
    for (dp.shownRows()) |ri| {
        if (ri < sel.lo or ri > sel.hi) continue;
        if (dp.mode == .split) {
            const row = dp.split_rows[ri];
            if (row != .pair or row.pair.file != sel.hunk.file or row.pair.hunk != sel.hunk.hunk) continue;
            if (row.pair.left) |l| mask[l] = true;
            if (row.pair.right) |r| mask[r] = true;
        } else {
            const row = dp.rows[ri];
            if (row != .line or row.line.file != sel.hunk.file or row.line.hunk != sel.hunk.hunk) continue;
            mask[row.line.line] = true;
        }
    }
    for (h.lines, 0..) |l, i| if (mask[i] and (l.kind == .add or l.kind == .del)) {
        count += 1;
    };
    return .{ .file = sel.hunk.file, .hunk = sel.hunk.hunk, .mask = mask, .count = count };
}

/// The view's document without the paint: what the selection helpers
/// read.
fn diffDoc(dp: *const DiffPane) diff_view.Doc {
    return .{ .files = dp.files, .rows = dp.rows, .shown = dp.shown, .split_rows = dp.split_rows, .split_shown = dp.split_shown, .mode = dp.mode, .cursor = dp.cursor, .anchor = dp.anchor, .focused = true };
}

/// The patch a verb applies: the selected lines when there is a
/// selection (`parse.patchForLineMask`, reversed for an unstage or a
/// discard), else the hunk under the cursor. `desc` is the toast.
pub const VerbPatch = struct { patch: []const u8, desc: []const u8, file: u32, hunk: u32 };

pub fn verbPatch(app: *App, dp: *const DiffPane, what: LineVerb, arena: Allocator) CommandError!VerbPatch {
    const past: []const u8 = switch (what) {
        .stage => "staged",
        .unstage => "unstaged",
        .discard => "discarded",
    };
    if (try selectedLines(dp, arena)) |sel| {
        const f = dp.files[sel.file];
        if (sel.count == 0) return app.diag.fail(arena, "diff: the selection holds no changed line", .{});
        const patch = (try parse.patchForLineMask(arena, f, sel.hunk, sel.mask, what != .stage)) orelse return app.diag.fail(arena, "diff: the selection holds no changed line", .{});
        return .{ .patch = patch, .desc = try std.fmt.allocPrint(arena, "{s} {d} line{s} of {s}", .{ past, sel.count, if (sel.count == 1) "" else "s", f.path() }), .file = sel.file, .hunk = sel.hunk };
    }
    const at = hunkAtCursor(dp) orelse return app.diag.fail(arena, "diff: no hunk under the cursor", .{});
    const f = dp.files[at.file];
    return .{ .patch = try parse.patchForHunk(arena, f, at.hunk), .desc = try std.fmt.allocPrint(arena, "{s} hunk {d} of {s}", .{ past, at.hunk + 1, f.path() }), .file = at.file, .hunk = at.hunk };
}

/// Stage / unstage / discard the selected lines, else the hunk under
/// the cursor, with a synthesized patch.
pub fn applyHunk(app: *App, dp: *DiffPane, what: LineVerb) CommandError!void {
    const arena = app.frame.allocator();
    const repo = app.git.repoById(dp.repo) orelse return error.NoRepo;
    const vp = try verbPatch(app, dp, what, arena);
    const desc = try app.gpa.dupe(u8, vp.desc);
    errdefer app.gpa.free(desc);
    const owned = try app.gpa.dupe(u8, vp.patch);
    errdefer app.gpa.free(owned);
    dp.anchor = null;
    try submitOp(app, repo, .{ .apply_patch = .{ .patch = owned, .cached = what != .discard, .reverse = what != .stage, .desc = desc } });
}

/// `Stash these lines`: the selection (else the hunk) becomes a stash
/// of its own and leaves the worktree (`client.stashLines`).
pub fn stashLines(app: *App, dp: *DiffPane) CommandError!void {
    const arena = app.frame.allocator();
    const repo = app.git.repoById(dp.repo) orelse return error.NoRepo;
    if (dp.scope == .staged or dp.scope == .commit or dp.scope == .orig or dp.scope == .conflict) return app.diag.fail(arena, "stash lines: only worktree changes can be stashed", .{});
    // Two forms of the same selection: forward for the stash's tree,
    // reverse for taking the lines out of the worktree.
    const fwd = try verbPatch(app, dp, .stage, arena);
    const rev = try verbPatch(app, dp, .discard, arena);
    const desc = try std.fmt.allocPrint(app.gpa, "stashed {s}", .{fwd.desc["staged ".len..]});
    errdefer app.gpa.free(desc);
    const patch = try app.gpa.dupe(u8, fwd.patch);
    errdefer app.gpa.free(patch);
    const reverse = try app.gpa.dupe(u8, rev.patch);
    errdefer app.gpa.free(reverse);
    dp.anchor = null;
    try submitOp(app, repo, .{ .stash_lines = .{ .patch = patch, .reverse = reverse, .msg = null, .desc = desc } });
}

/// `Commit these lines`: the selection (else the hunk) is held while
/// the message prompt is up; the accept commits it (`client.commitLines`).
pub fn commitLinesPrompt(app: *App, dp: *DiffPane) CommandError!void {
    const arena = app.frame.allocator();
    const st = &app.git;
    if (dp.scope == .commit or dp.scope == .orig or dp.scope == .conflict) return app.diag.fail(arena, "commit lines: not a working-tree diff", .{});
    const vp = try verbPatch(app, dp, .stage, arena);
    if (st.line_patch) |b| app.gpa.free(b);
    st.line_patch = try app.gpa.dupe(u8, vp.patch);
    st.line_repo = dp.repo;
    dp.anchor = null;
    openPrompt(app, .commit_lines, try std.fmt.allocPrint(arena, "Commit message for the {s}", .{vp.desc["staged ".len..]}));
}

/// `v` / `git.diff_select`: anchor a selection at the cursor, or drop
/// the one there is.
pub fn toggleDiffSelect(dp: *DiffPane) void {
    dp.anchor = if (dp.anchor == null and dp.cursor < dp.rowCount()) dp.cursor else null;
}

/// Shift+arrow: the selection grows from the cursor.
fn extendDiffSelect(dp: *DiffPane, delta: isize) void {
    if (dp.anchor == null and dp.cursor < dp.rowCount()) dp.anchor = dp.cursor;
    stepDiff(dp, delta);
}

/// The discard confirm for the selection or the hunk (`x`, the chip,
/// the menu).
pub fn askDiscard(app: *App, id: PaneId, dp: *DiffPane) Allocator.Error!void {
    if (hunkAtCursor(dp) == null) return app.toast("diff: no hunk under the cursor", .{});
    const arena = app.frame.allocator();
    const sel = selectedLines(dp, arena) catch null;
    const msg: []const u8 = if (sel != null and sel.?.count > 0)
        try std.fmt.allocPrint(app.gpa, "  Discard the {d} selected line{s} from the worktree? This cannot be undone.", .{ sel.?.count, if (sel.?.count == 1) "" else "s" })
    else
        try app.gpa.dupe(u8, "  Discard this hunk from the worktree? This cannot be undone.");
    try openConfirm(app, .{ .discard_hunk = .{ .pane = id } }, @constCast(msg));
}

/// The row menu of a diff pane: the verbs for its scope, worded for
/// the selection when there is one. Every row is a `git.diff_*` command
/// on the active pane — the keys and the palette run the same ids.
pub fn openDiffRowMenu(app: *App, dp: *DiffPane, x: u16, y: u16) Allocator.Error!void {
    const has_sel = (selectedLines(dp, app.frame.allocator()) catch null) != null;
    const what: []const u8 = if (has_sel) "selected lines" else "hunk";
    const arena = app.frame.allocator();
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    switch (dp.scope) {
        .file, .worktree, .head => {
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Stage {s}", .{what}), .action = .{ .command = .@"git.diff_stage_lines" } });
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Discard {s}\u{2026}", .{what}), .action = .{ .command = .@"git.diff_discard_lines" } });
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Stash {s}", .{what}), .action = .{ .command = .@"git.diff_stash_lines" }, .separator_before = true });
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Commit {s}\u{2026}", .{what}), .action = .{ .command = .@"git.diff_commit_lines" } });
        },
        .staged => try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Unstage {s}", .{what}), .action = .{ .command = .@"git.diff_unstage_lines" } }),
        .commit, .orig, .conflict => {},
    }
    try items.append(app.gpa, .{ .label = if (has_sel) "Clear selection" else "Select lines from here", .action = .{ .command = .@"git.diff_select" }, .separator_before = items.items.len > 0 });
    try items.append(app.gpa, .{ .label = "Open file at line", .action = .{ .command = .@"git.diff_open_line" } });
    const owned = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu("Diff", owned, x, y);
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
        .reopen_repo => try git_palette.acceptReopen(app, detail),
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
            const rel: ?[]const u8 = if (what == .file_history) (if (app.activeEditor()) |e| (if (e.buf.doc.path) |p| relToRepo(repo, p) else null) else null) else null;
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
    // The held line patch lives until its own accept or another prompt
    // (the close runs before the accept, so it cannot go on close).
    if (kind != .commit_lines) if (app.git.line_patch) |b| {
        app.gpa.free(b);
        app.git.line_patch = null;
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
        .commit_lines => {
            const patch = st.line_patch orelse return app.diag.fail(app.frame.allocator(), "commit lines: the selection is gone", .{});
            if (text.len == 0) return app.diag.fail(app.frame.allocator(), "commit: empty message", .{});
            const repo = st.repoById(st.line_repo) orelse return error.NoRepo;
            st.line_patch = null;
            errdefer gpa.free(patch);
            try submitOp(app, repo, .{ .commit_lines = .{ .patch = patch, .msg = try gpa.dupe(u8, text) } });
        },
        .graph_hash => {
            const g = activeGraph(app) orelse return app.diag.fail(app.frame.allocator(), "graph: no graph pane is active", .{});
            if (text.len == 0) return;
            const idx = graph_view.findByHashPrefix(g.commits, text) orelse return app.diag.fail(app.frame.allocator(), "no commit starts with {s}", .{text});
            g.cursor = g.rowOfCommit(idx);
            if (!g.wipSelected()) requestDetail(app, g) catch {};
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
        .tag_delete => |t| try submitOp(app, try requireRepo(app), .{ .tag_delete = try gpa.dupe(u8, t) }),
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

/// Open the row's diff (the index side for a staged row), or stage /
/// unstage / discard its file through the worker.
pub fn actOnRow(app: *App, row: Row, what: RowAction) CommandError!void {
    const st = &app.git;
    const gpa = app.gpa;
    const repo = st.activeRepo() orelse return error.NoRepo;
    switch (what) {
        .open => _ = try openDiff(app, repo, if (row.staged) .staged else .file, row.path, null, null),
        .stage => try submitOp(app, repo, .{ .stage = try gpa.dupe(u8, row.path) }),
        .unstage => try submitOp(app, repo, .{ .unstage = try gpa.dupe(u8, row.path) }),
        .discard => try openConfirm(app, .{ .discard = try gpa.dupe(u8, row.path) }, try std.fmt.allocPrint(gpa, "  Discard changes to {s}? This cannot be undone.", .{row.path})),
    }
}

/// Open the selected row's file in an editor (`git.open_file`).
pub fn openRowFile(app: *App, row: Row) CommandError!void {
    const repo = app.git.activeRepo() orelse return error.NoRepo;
    const arena = app.frame.allocator();
    const abs = try std.fs.path.join(arena, &.{ repo.path, row.path });
    _ = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ row.path, @errorName(err) }),
    };
}

// ─── keys ───────────────────────────────────────────────────────────────

pub const StatusAction = status_view.Action;

/// What the status pane's keys and hint words do (Rust
/// `git_stage_selected` and friends): `s` on a staged row and `u` on an
/// unstaged one only say so, space picks the side, enter opens the
/// diff — which an untracked file does not have yet.
pub fn statusAct(app: *App, sp: *StatusPane, a: StatusAction) CommandError!void {
    const row = try statusPaneRow(app, sp);
    switch (a) {
        .stage => if (row) |r| {
            if (r.staged) return app.toast("already staged \u{2014} `u` to unstage", .{});
            try actOnRow(app, r, .stage);
        },
        .unstage => if (row) |r| {
            if (!r.staged) return app.toast("not staged \u{2014} `s` to stage", .{});
            try actOnRow(app, r, .unstage);
        },
        .toggle => if (row) |r| try actOnRow(app, r, if (r.staged) .unstage else .stage),
        .stage_all => try command.run(app, .{ .static = .@"git.stage_all" }),
        .unstage_all => try command.run(app, .{ .static = .@"git.unstage_all" }),
        .diff => if (row) |r| {
            if (r.letter == '?') return app.toast("no diff for that file (untracked? \u{2014} stage it to see it)", .{});
            // A conflicted file resolves in the editor (`app/conflicts.zig`).
            if (r.letter == 'U') return conflicts.openConflicted(app, r.path);
            try actOnRow(app, r, .open);
        },
        .commit => try command.run(app, .{ .static = .@"git.commit" }),
        .ai_commit => try command.run(app, .{ .static = .@"git.ai_commit" }),
        .refresh => {
            app.git.status_pending = false;
            try requestStatus(app);
        },
    }
}

/// Rust `move_selection`: `delta` rows, clamped into the flat list.
pub fn moveStatusCursor(sp: *StatusPane, n: usize, delta: isize) void {
    if (n == 0) return;
    const cur: isize = @intCast(sp.cursor);
    const max: isize = @intCast(n - 1);
    sp.cursor = @intCast(std.math.clamp(cur +| delta, 0, max));
}

/// The wheel over the pane moves the cursor `n` rows.
pub fn statusPaneWheel(app: *App, sp: *StatusPane, down: bool, n: usize) void {
    const d: isize = @intCast(n);
    moveStatusCursor(sp, statusFlatLen(app), if (down) d else -d);
}

/// Esc: back to the tree when it is showing, else the pane closes.
fn leaveStatusPane(app: *App, id: PaneId) Allocator.Error!void {
    if (app.tree.visible) {
        if (app.activeBuffer()) |b| b.input.onBlur();
        app.focus = .tree;
    } else try app.closePane(id, true);
}

/// The status pane's keys, Rust's `Pane::GitStatus` arm: `j k ↑ ↓`
/// move, page up / down by the pane, `g G home end` to the ends,
/// `space s u a A ⏎ c C r` act, `b B w` open the checkout / new-branch
/// / worktree pickers, esc goes back to the tree.
pub fn statusPaneKey(app: *App, id: PaneId, sp: *StatusPane, k: Key) Allocator.Error!bool {
    const n = statusFlatLen(app);
    const page: isize = @intCast(@max(app.pane_rows, 1));
    const top = std.math.minInt(isize) / 2;
    const bottom = std.math.maxInt(isize) / 2;
    switch (k.code) {
        .up => moveStatusCursor(sp, n, -1),
        .down => moveStatusCursor(sp, n, 1),
        .page_up => moveStatusCursor(sp, n, -page),
        .page_down => moveStatusCursor(sp, n, page),
        .home => moveStatusCursor(sp, n, top),
        .end => moveStatusCursor(sp, n, bottom),
        .enter => runToast(app, statusAct(app, sp, .diff)),
        .esc => try leaveStatusPane(app, id),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => moveStatusCursor(sp, n, 1),
                'k' => moveStatusCursor(sp, n, -1),
                'g' => moveStatusCursor(sp, n, top),
                'G' => moveStatusCursor(sp, n, bottom),
                ' ' => runToast(app, statusAct(app, sp, .toggle)),
                's' => runToast(app, statusAct(app, sp, .stage)),
                'u' => runToast(app, statusAct(app, sp, .unstage)),
                'a' => runToast(app, statusAct(app, sp, .stage_all)),
                'A' => runToast(app, statusAct(app, sp, .unstage_all)),
                'c' => runToast(app, statusAct(app, sp, .commit)),
                'C' => runToast(app, statusAct(app, sp, .ai_commit)),
                'r' => runToast(app, statusAct(app, sp, .refresh)),
                'b' => runToast(app, command.run(app, .{ .static = .@"git.checkout" })),
                'B' => runToast(app, command.run(app, .{ .static = .@"git.new_branch" })),
                'w' => runToast(app, command.run(app, .{ .static = .@"git.worktrees" })),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// The diff pane: motion over the shown rows, `]c [c` / `n p` between
/// hunks, `]f [f` between files, `s u x` on the selected lines (else the
/// hunk), `v` anchors / drops a selection and shift+↑↓ (`J` / `K`)
/// grow one, `t` cycles the view, `/` filters, enter opens the file at
/// the line. Esc drops the selection, then the filter, then the pane.
/// While the filter takes keys, esc clears it and enter keeps it.
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
        .up => if (k.mods.shift) extendDiffSelect(dp, -1) else stepDiff(dp, -1),
        .down => if (k.mods.shift) extendDiffSelect(dp, 1) else stepDiff(dp, 1),
        .page_up => stepDiff(dp, -page),
        .page_down => stepDiff(dp, page),
        .home => diffHome(dp, false),
        .end => diffHome(dp, true),
        .enter => runToast(app, openDiffLine(app, dp)),
        .esc => {
            if (dp.anchor != null) {
                dp.anchor = null;
            } else if (dp.filter.items.len > 0) {
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
                'v', 'V' => toggleDiffSelect(dp),
                'J' => extendDiffSelect(dp, 1),
                'K' => extendDiffSelect(dp, -1),
                't' => runToast(app, setDiffMode(app, dp, dp.mode.next())),
                '/' => {
                    dp.filter_mode = true;
                    dp.filter.clearRetainingCapacity();
                    try refilterDiff(app, dp);
                },
                's' => runToast(app, applyHunk(app, dp, .stage)),
                'u' => runToast(app, applyHunk(app, dp, .unstage)),
                'x' => try askDiscard(app, id, dp),
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
    const from = fileOfShown(dp, i);
    while (true) {
        if (forward) {
            if (i + 1 >= shown.len) return;
            i += 1;
        } else {
            if (i == 0) return;
            i -= 1;
        }
        const fi = fileOfShown(dp, i) orelse continue;
        if (from != null and fi == from.?) continue;
        // Backwards: land on the file's first shown row.
        if (!forward) {
            while (i > 0 and fileOfShown(dp, i - 1) == fi) i -= 1;
        }
        dp.cursor = shown[i];
        return;
    }
}

/// The file the shown row at `pos` belongs to.
fn fileOfShown(dp: *const DiffPane, pos: usize) ?u32 {
    const ri = dp.shownRows()[pos];
    const h = (if (dp.mode == .split) diff_view.splitRowHunk(dp.split_rows[ri]) else diff_view.rowHunk(dp.rows[ri])) orelse return null;
    return h.file;
}

/// Enter on a diff row: the file at that line.
pub fn openDiffLine(app: *App, dp: *DiffPane) CommandError!void {
    if (dp.cursor >= dp.rowCount()) return;
    const repo = app.git.repoById(dp.repo) orelse return error.NoRepo;
    const arena = app.frame.allocator();
    const fi: u32, const line: ?u32 = if (dp.mode == .split) switch (dp.split_rows[dp.cursor]) {
        .hunk => |h| .{ h.file, dp.files[h.file].hunks[h.hunk].new_start },
        .pair => |p| blk: {
            const lines = dp.files[p.file].hunks[p.hunk].lines;
            const no: ?u32 = if (p.right) |r| lines[r].new_no else if (p.left) |l| lines[l].old_no else null;
            break :blk .{ p.file, no };
        },
        .blank => return,
    } else switch (dp.rows[dp.cursor]) {
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
        const ed = e.buf.editor;
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
    if (m.button == .right) {
        // A row's menu: the cursor moves there first (the verbs act on
        // the cursor's hunk when nothing is selected).
        if (hit_id < dp.rowCount()) {
            if (!diff_view.isSelected(diffDoc(dp), hit_id)) {
                dp.anchor = null;
                dp.cursor = hit_id;
            }
            try openDiffRowMenu(app, dp, m.x, m.y);
        }
        return;
    }
    if (m.button != .left) return;
    app.needs_render = true;
    if (git_toolbar.actionOf(hit_id)) |action| {
        // The git toolbar: each button is a `git.*` command; Refresh
        // re-reads this diff.
        const cmd: command.CommandId = switch (action) {
            .undo => .@"git.undo",
            .redo => .@"git.redo",
            .pull => .@"git.pull",
            .push => .@"git.push",
            .fetch => .@"git.fetch",
            .branch => .@"git.branch_menu",
            .commit => .@"git.commit",
            .stash => .@"git.stash",
            .pop => .@"git.stash_pop",
            .reflog => .@"git.reflog",
            .cont => .@"git.op_continue",
            .abort => .@"git.op_abort",
            .skip => .@"git.op_skip",
            .refresh => return runToast(app, refreshDiff(app, dp)),
        };
        command.run(app, .{ .static = cmd }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (app.diag.msg) |msg| app.toast("{s}", .{msg}),
        };
        return;
    }
    if (diff_view.chipOf(hit_id)) |mode| return runToast(app, setDiffMode(app, dp, mode));
    if (hit_id == diff_view.wrap_id) {
        dp.wrap = !dp.wrap;
        return;
    }
    if (hit_id == diff_view.close_id) return app.closePane(id, true);
    if (diff_view.actionOf(hit_id)) |a| return diffAction(app, id, dp, a);
    if (diff_view.hunkChipOf(hit_id)) |hc| {
        // A hunk header's own chip acts on that hunk, whatever is selected.
        dp.anchor = null;
        if (hc.row < dp.rows.len) dp.cursor = hc.row;
        return diffAction(app, id, dp, hc.action);
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
    if (m.mods.shift) {
        // Shift+click grows the selection from the cursor.
        if (dp.anchor == null) dp.anchor = dp.cursor;
        dp.cursor = hit_id;
        return;
    }
    if (dp.cursor == hit_id and dp.anchor == null) return runToast(app, openDiffLine(app, dp));
    dp.anchor = null;
    dp.cursor = hit_id;
    // A drag from here selects rows; a plain release leaves none.
    app.drag = .{ .diff_select = .{ .pane = id, .anchor = hit_id } };
}

/// The drag a row press started: the cursor follows the row under the
/// pointer and the anchor is the pressed row; a release on the same row
/// is a click and selects nothing.
pub fn dragDiffSelect(app: *App, id: PaneId, anchor: usize, m: Mouse) void {
    const pane = app.panes.get(id) orelse return;
    const dp = switch (pane.*) {
        .diff => |*d| d,
        else => return,
    };
    if (m.kind == .drag) {
        const under = app.hits.at(m.x, m.y) orelse return;
        if (under != .script_hit or under.script_hit.pane != id) return;
        const row = under.script_hit.id;
        if (row >= dp.rowCount()) return;
        if (row != anchor or dp.anchor != null) {
            dp.anchor = anchor;
            dp.cursor = row;
        }
        return;
    }
    if (dp.anchor != null and dp.anchor.? == dp.cursor) dp.anchor = null;
}

/// A Stage / Discard / Unstage chip: Discard asks first, as `x` does.
fn diffAction(app: *App, id: PaneId, dp: *DiffPane, a: diff_view.Action) Allocator.Error!void {
    switch (a) {
        .stage => runToast(app, applyHunk(app, dp, .stage)),
        .unstage => runToast(app, applyHunk(app, dp, .unstage)),
        .discard => try askDiscard(app, id, dp),
    }
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

/// The detail column follows the cursor: the selected commit's detail
/// is asked for (the WIP row shows the working tree).
pub fn openDetail(app: *App, g: *GraphPane) CommandError!void {
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
    g.detail_cursor = 0;
    if (!g.wipSelected()) requestDetail(app, g) catch {};
}

/// The graph pane: motion over the virtual rows, enter opens the
/// selected commit's diff (the WIP row's: the worktree's), tab moves
/// the focus into the detail column, `d` opens the diff, `s` cycles
/// the sort, `/` jumps to a hash, `c` cherry-picks, `v` reverts, `f`
/// filters by branch, `F` clears every filter. On the WIP row `a` /
/// `A` stage and unstage everything, `c` commits what the commit box
/// holds (the prompt when it is empty), `C` asks for an AI message.
pub fn graphKey(app: *App, id: PaneId, g: *GraphPane, k: Key) Allocator.Error!bool {
    syncWip(app, g);
    if (g.wip_focused) {
        if (g.wipSelected()) return textareaKey(app, g, k);
        g.wip_focused = false;
    }
    if (g.detail_focus) return detailKey(app, id, g, k);
    const n = g.totalRows();
    switch (k.code) {
        .up => moveGraphCursor(app, g, g.cursor -| 1),
        .down => moveGraphCursor(app, g, g.cursor + 1),
        .page_up => moveGraphCursor(app, g, g.cursor -| app.pane_rows),
        .page_down => moveGraphCursor(app, g, g.cursor + app.pane_rows),
        .home => moveGraphCursor(app, g, 0),
        .end => moveGraphCursor(app, g, n -| 1),
        .enter => runToast(app, showSelectedCommit(app, g)),
        .tab => g.detail_focus = true,
        .esc => try app.closePane(id, true),
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
                'c' => if (g.wipSelected()) runToast(app, commitFromTextarea(app, g)) else runToast(app, command.run(app, .{ .static = .@"git.cherry_pick" })),
                'C' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.ai_commit" })) else return false,
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

/// The commit box has the keys: text edits, Enter a newline, Esc
/// blurs, Ctrl+Enter commits.
fn textareaKey(app: *App, g: *GraphPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => g.wip_focused = false,
        .enter => {
            if (k.mods.ctrl) {
                runToast(app, commitFromTextarea(app, g));
            } else try text_field.insert(&g.wip_text, &g.wip_cursor, app.gpa, "\n");
        },
        .tab => g.wip_focused = false,
        .up, .down => {
            // A row up or down: the same column on the neighbouring row.
            const rows = graph_view.textareaRows(app.frame.allocator(), g.wip_text.items, @max(g.body.w / 3, 8) -| 4) catch return true;
            const at = graph_view.locateCursor(rows, g.wip_text.items, g.wip_cursor);
            const target = if (k.code == .up) at.row -| 1 else @min(at.row + 1, rows.len - 1);
            if (target == at.row) return true;
            const r = rows[target];
            var col: usize = 0;
            var i = r[0];
            while (i < r[1] and col < at.col) : (col += 1) i += std.unicode.utf8ByteSequenceLength(g.wip_text.items[i]) catch 1;
            g.wip_cursor = i;
        },
        else => {
            if (try text_field.handleKey(&g.wip_text, &g.wip_cursor, app.gpa, k) == .ignored) return false;
        },
    }
    app.needs_render = true;
    return true;
}

/// Commit what the box holds; an empty box opens the prompt instead
/// (Rust `commit_from_active_wip_textarea_or_prompt`).
pub fn commitFromTextarea(app: *App, g: *GraphPane) CommandError!void {
    if (g.wip_ai) return app.diag.fail(app.frame.allocator(), "AI message still streaming — wait for it to finish", .{});
    const text = std.mem.trim(u8, g.wip_text.items, " \t\r\n");
    if (text.len == 0) {
        openPrompt(app, .commit, "Commit message");
        return;
    }
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    try submitOp(app, repo, .{ .commit = try app.gpa.dupe(u8, text) });
    g.wip_text.clearRetainingCapacity();
    g.wip_cursor = 0;
    g.wip_focused = false;
}

/// The detail column has the keys: j/k over the files, enter opens
/// the file's diff in this commit (the WIP row's file opens its
/// worktree diff), tab / esc hand the focus back, `q` closes the pane.
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
                's' => if (g.wipSelected()) runToast(app, stageDetailRow(app, g, true)) else return false,
                'u' => if (g.wipSelected()) runToast(app, stageDetailRow(app, g, false)) else return false,
                'q' => try app.closePane(id, true),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// A working-tree file as the detail column lists it.
pub const WipRef = Row;

/// The working tree's files in the detail column's order: unstaged
/// (modified, untracked, conflicted) then staged, each A–Z by path.
pub fn wipFiles(app: *App, arena: Allocator) Allocator.Error!Files {
    return collectFiles(app, arena, true);
}

fn wipRow(app: *App, g: *GraphPane, idx: usize) Allocator.Error!?WipRef {
    const files = try wipFiles(app, app.frame.allocator());
    if (idx < files.unstaged.len) return files.unstaged[idx];
    if (idx - files.unstaged.len < files.staged.len) return files.staged[idx - files.unstaged.len];
    _ = g;
    return null;
}

/// `s` / `u` on a working-tree row: stage or unstage that file.
fn stageDetailRow(app: *App, g: *GraphPane, stage: bool) CommandError!void {
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    const row = (try wipRow(app, g, g.detail_cursor)) orelse return;
    try stagePath(app, repo, row.path, stage);
}

fn stagePath(app: *App, repo: *client.Repo, path: []const u8, stage: bool) CommandError!void {
    const copy = try app.gpa.dupe(u8, path);
    try submitOp(app, repo, if (stage) .{ .stage = copy } else .{ .unstage = copy });
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
        const row = (try wipRow(app, g, g.detail_cursor)) orelse return;
        _ = try openDiff(app, repo, if (row.staged) .staged else .file, row.path, null, null);
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

/// A click in the graph pane (`.script_hit`): a toolbar button runs
/// its command, a column header sorts, the divider starts a drag, the
/// detail column's buttons stage / unstage / commit / ask / clear, its
/// textarea takes the keys, a file row opens its diff, a commit file
/// row selects (a second click opens it), a list row selects (right
/// opens the row menu). Any other press blurs the commit box.
pub fn graphClick(app: *App, id: PaneId, g: *GraphPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    syncWip(app, g);
    app.needs_render = true;
    if (git_toolbar.actionOf(hit_id)) |action| {
        if (m.button != .left) return;
        g.wip_focused = false;
        const cmd: command.CommandId = switch (action) {
            .undo => .@"git.undo",
            .redo => .@"git.redo",
            .pull => .@"git.pull",
            .push => .@"git.push",
            .fetch => .@"git.fetch",
            .branch => .@"git.branch_menu",
            .commit => .@"git.commit",
            .stash => .@"git.stash",
            .pop => .@"git.stash_pop",
            .reflog => .@"git.reflog",
            .cont => .@"git.op_continue",
            .abort => .@"git.op_abort",
            .skip => .@"git.op_skip",
            .refresh => return runToast(app, refreshGraph(app, g)),
        };
        return runToast(app, command.run(app, .{ .static = cmd }));
    }
    if (graph_view.sortOf(hit_id)) |col| {
        g.wip_focused = false;
        if (m.button == .left) try clickSort(app, g, col);
        return;
    }
    if (graph_view.wipButtonOf(hit_id)) |b| {
        if (m.button != .left) return;
        switch (b) {
            .textarea => {
                g.wip_focused = true;
                g.detail_focus = false;
                return;
            },
            .stage_all => runToast(app, command.run(app, .{ .static = .@"git.stage_all" })),
            .unstage_all => runToast(app, command.run(app, .{ .static = .@"git.unstage_all" })),
            .commit => runToast(app, commitFromTextarea(app, g)),
            .ai_message => runToast(app, command.run(app, .{ .static = .@"git.ai_commit" })),
            .clear => {
                g.wip_text.clearRetainingCapacity();
                g.wip_cursor = 0;
            },
        }
        return;
    }
    g.wip_focused = false;
    if (hit_id == graph_view.divider_id) {
        if (m.button == .left) app.drag = .{ .graph_divider = id };
        return;
    }
    if (graph_view.wipFileOf(hit_id)) |wf| {
        if (m.button != .left) return;
        const files = try wipFiles(app, app.frame.allocator());
        const list = if (wf.staged) files.staged else files.unstaged;
        if (wf.idx >= list.len) return;
        const repo = app.git.repoById(g.repo) orelse return;
        if (wf.button) return runToast(app, stagePath(app, repo, list[wf.idx].path, !wf.staged));
        g.detail_focus = true;
        g.detail_cursor = wf.idx + @as(usize, if (wf.staged) files.unstaged.len else 0);
        runToast(app, voidOf(openDiff(app, repo, if (wf.staged) .staged else .file, list[wf.idx].path, null, null)));
        return;
    }
    if (graph_view.detailRowOf(hit_id)) |row| {
        const was = g.detail_focus and g.detail_cursor == row;
        g.detail_focus = true;
        g.detail_cursor = row;
        if (was and m.button == .left) runToast(app, openDetailRow(app, g));
        return;
    }
    if (hit_id >= g.totalRows()) return;
    g.detail_focus = false;
    moveGraphCursor(app, g, hit_id);
    if (m.button == .right) return openGraphMenu(app, m.x, m.y);
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
    // Rust's clamp: twenty cells at least, forty left for the list.
    const right = g.body.right();
    g.detail_w = @intCast(std.math.clamp(@as(u32, right -| x) -| 1, 20, @max(@as(u32, g.body.w -| 40), 20)));
    app.needs_render = true;
}

fn voidOf(r: CommandError!PaneId) CommandError!void {
    _ = try r;
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

/// A click in the status pane (`.script_hit`): a hint word runs its
/// action; a row takes the cursor, a second click on it opens the
/// diff, a right click opens the row menu.
pub fn statusPaneClick(app: *App, sp: *StatusPane, idx: u32, m: Mouse) Allocator.Error!void {
    if (status_view.hintOf(idx)) |a| {
        if (m.button == .left) runToast(app, statusAct(app, sp, a));
        return;
    }
    if (idx >= statusFlatLen(app)) return;
    const was = sp.cursor;
    sp.cursor = idx;
    if (m.button == .right) return openRowMenu(app, m.x, m.y);
    if (was == idx) runToast(app, statusAct(app, sp, .diff));
}

fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
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

// ─── draw (D6) ──────────────────────────────────────────────────────────

/// `Pane.git_status`.
pub fn drawStatusPane(app: *App, ui: Ui, id: PaneId, sp: *StatusPane, area: Rect) Allocator.Error!void {
    const st = &app.git;
    if (st.activeRepo() != null and st.status == null and !st.status_pending) requestStatus(app) catch {};
    const files = try statusFiles(app, ui.arena);
    if (files.len() > 0) sp.cursor = @min(sp.cursor, files.len() - 1);
    status_view.draw(ui, id, area, .{
        .branch = if (st.status) |s| s.branch else null,
        .unstaged = files.unstaged,
        .staged = files.staged,
        .cursor = sp.cursor,
        .ai_pending = if (st.ai_wait) |w| w.what == .commit else false,
    }, &sp.scroll);
    if (app.active == id) app.pane_rows = @max(area.h, 1);
}

/// `Pane.diff`.
pub fn drawDiffPane(app: *App, ui: Ui, id: PaneId, dp: *DiffPane, area: Rect) void {
    const focused = app.active == id and app.focus == .pane;
    // Rust's `chip_actions_for_scope`: a worktree / file / HEAD diff
    // stages or discards, a staged one unstages, a commit's shows none.
    const actions: diff_view.Actions = switch (dp.scope) {
        .file, .worktree, .head => .unstaged,
        .staged => .staged,
        .commit, .orig, .conflict => .none,
    };
    const painted = diff_view.draw(ui, id, area, &dp.view, .{
        .files = dp.files,
        .rows = dp.rows,
        .shown = dp.shown,
        .split_rows = dp.split_rows,
        .split_shown = dp.split_shown,
        .mode = dp.mode,
        .cursor = dp.cursor,
        .anchor = dp.anchor,
        .focused = focused,
        .filter = dp.filter.items,
        .filter_mode = dp.filter_mode,
        .wrap = dp.wrap,
        .actions = actions,
        .pending = dp.pending and dp.rows.len == 0,
        .triangle = app.cfg.ui.expand_indicator == .triangle,
    });
    dp.body = painted.body;
    dp.strip_cells = painted.strip_cells;
    if (app.active == id) app.pane_rows = @max(area.h -| 1, 1);
}

/// Rust `format_wip_summary`: `N change(s) · S staged · U new · ⚠ C
/// conflict(s) · ↑a ↓b`, or `working tree clean`.
pub fn wipSummary(arena: Allocator, st: parse.Status) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const total = st.changeCount();
    if (total == 0) try out.appendSlice(arena, "working tree clean") else {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d} change(s)", .{total}));
        if (st.staged > 0) try out.appendSlice(arena, try std.fmt.allocPrint(arena, " \u{B7} {d} staged", .{st.staged}));
        if (st.untracked > 0) try out.appendSlice(arena, try std.fmt.allocPrint(arena, " \u{B7} {d} new", .{st.untracked}));
        if (st.conflicted > 0) try out.appendSlice(arena, try std.fmt.allocPrint(arena, " \u{B7} \u{26A0} {d} conflict(s)", .{st.conflicted}));
    }
    if (st.ahead > 0 or st.behind > 0) try out.appendSlice(arena, try std.fmt.allocPrint(arena, " \u{B7} \u{2191}{d} \u{2193}{d}", .{ st.ahead, st.behind }));
    return out.items;
}

/// The filter chip over the subject column (Rust's `filter_label`).
fn filterLabel(app: *App, g: *const GraphPane) Allocator.Error!?[]const u8 {
    const f = g.filter;
    if (f.branch == null and f.author == null and f.subject == null and f.since == null and f.until == null) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const arena = app.frame.allocator();
    var n: usize = 0;
    const parts = [_]?[]const u8{
        if (f.branch) |b| try std.fmt.allocPrint(arena, "\u{2387} {s}", .{b}) else null,
        if (f.author) |a| try std.fmt.allocPrint(arena, "@{s}", .{a}) else null,
        if (f.subject) |s| try std.fmt.allocPrint(arena, "~{s}", .{s}) else null,
        if (f.since != null and f.until != null) try std.fmt.allocPrint(arena, "{s}..{s}", .{ f.since.?, f.until.? }) else if (f.since) |s| try std.fmt.allocPrint(arena, "since {s}", .{s}) else if (f.until) |u| try std.fmt.allocPrint(arena, "until {s}", .{u}) else null,
    };
    for (parts) |p| if (p) |text| {
        if (n > 0) try out.appendSlice(arena, " \u{B7} ");
        try out.appendSlice(arena, text);
        n += 1;
    };
    try out.appendSlice(arena, " \u{B7} F clears");
    return out.items;
}

/// The operation repo `id` is in the middle of, as the last status saw it.
pub fn inProgressOf(app: *App, id: u32) parse.InProgress {
    const st = &app.git;
    if (st.status_repo != id) return .none;
    const s = st.status orelse return .none;
    return s.in_progress;
}

/// `Pane.git_graph`.
pub fn drawGraphPane(app: *App, ui: Ui, id: PaneId, g: *GraphPane, area: Rect) void {
    const st = &app.git;
    syncWip(app, g);
    if (st.activeRepo() != null and st.status == null and !st.status_pending) requestStatus(app) catch {};
    const focused = app.active == id and app.focus == .pane;
    const now = nowUnix(app);
    const arena = ui.arena;
    var wip: ?graph_view.WipDoc = null;
    if (g.has_wip or st.status != null) {
        const files = wipFiles(app, arena) catch return;
        const un = arena.alloc(graph_view.WipFile, files.unstaged.len) catch return;
        for (un, files.unstaged) |*o, f| o.* = .{ .path = f.path, .letter = f.letter };
        const sd = arena.alloc(graph_view.WipFile, files.staged.len) catch return;
        for (sd, files.staged) |*o, f| o.* = .{ .path = f.path, .letter = f.letter };
        wip = .{
            .branch = st.branchLabel(),
            .summary = if (st.status) |s| (wipSummary(arena, s) catch "") else "",
            .unstaged = un,
            .staged = sd,
            .commit = .{ .text = g.wip_text.items, .cursor = g.wip_cursor, .focused = g.wip_focused and focused, .ai_streaming = g.wip_ai },
        };
    }
    var detail: ?graph_view.DetailDoc = null;
    if (!g.wipSelected()) if (g.selected()) |c| {
        var age_buf: [16]u8 = undefined;
        const age = arena.dupe(u8, graph_view.humanizeAge(&age_buf, now - c.time)) catch "";
        detail = .{ .short = c.hash[0..@min(9, c.hash.len)], .author = c.author, .age = age, .parents = c.parents, .pending = true };
        if (g.detail) |d| if (std.mem.eql(u8, d.sha, c.hash)) {
            detail.?.message = d.message;
            detail.?.files = d.files;
            detail.?.pending = false;
        };
    };
    const painted = graph_view.draw(ui, id, area, &g.view, .{
        .commits = g.commits,
        .lanes = g.lanes,
        .order = g.order,
        .cursor = g.cursor,
        .focused = focused,
        .lane_spacing = app.cfg.git_graph.lane_spacing,
        .now = now,
        .sort = g.sort,
        .filter_label = filterLabel(app, g) catch null,
        .has_wip = g.has_wip,
        .wip = wip,
        .detail = detail,
        .detail_w = g.detail_w orelse app.cfg.ui.git_graph_detail_col,
        .branch_col = app.cfg.ui.git_graph_branch_col,
        .author_col = app.cfg.ui.git_graph_author_col,
        .in_progress = inProgressOf(app, g.repo),
    });
    // The drag measures against the whole body under the toolbar.
    g.body = Rect.init(painted.list.x, painted.list.y, painted.list.w + painted.detail.w + @as(u16, if (painted.detail.w > 0) 1 else 0), painted.list.h);
    if (painted.caret) |c| if (focused) {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
    if (app.active == id) app.pane_rows = @max(painted.body.h, 1);
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

    /// `git <args>` in the workspace, its trimmed stdout on `testing.allocator`.
    fn out(f: *Fixture, args: []const []const u8) ![]u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=tester" });
        try argv.appendSlice(testing.allocator, args);
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = f.root } });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        return testing.allocator.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    }

    /// `git <args>`'s stdout as is, on the test allocator.
    fn outRaw(f: *Fixture, args: []const []const u8) ![]u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=tester" });
        try argv.appendSlice(testing.allocator, args);
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = f.root } });
        defer testing.allocator.free(res.stderr);
        return res.stdout;
    }

    /// A repo with `code.txt` committed as five lines and two of them
    /// changed in the worktree, its diff pane open in the Inline view
    /// with the cursor on the first `-` row.
    fn seedTwoChanges(f: *Fixture) !*DiffPane {
        try f.sh(&.{ "init", "-q", "-b", "main" });
        try f.write("code.txt", "one\ntwo\nthree\nfour\nfive\n");
        try f.sh(&.{ "add", "code.txt" });
        try f.sh(&.{ "commit", "-q", "-m", "initial" });
        try f.write("code.txt", "one\ntwo-x\nthree\nfour-x\nfive\n");
        f.app.tree.visible = false;
        const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "code.txt" });
        defer testing.allocator.free(abs);
        _ = try f.app.openPath(abs);
        try command.run(&f.app, .{ .static = .@"git.diff_file" });
        try f.settle(2000);
        const dp = activeDiff(&f.app).?;
        try testing.expectEqual(@as(usize, 1), dp.files.len);
        // Inline rows: ` one` `-two` `+two-x` ` three` `-four` `+four-x` ` five`.
        stepDiff(dp, 1);
        return dp;
    }

    /// The job through the worker, settled; the last toast.
    fn op(f: *Fixture, job: client.Job) ![]const u8 {
        try submitOp(&f.app, f.app.git.activeRepo().?, job);
        try f.settle(4000);
        return f.app.lastToast() orelse "";
    }
};

/// A repo whose `c.txt` is in a merge conflict with two blocks: `main`
/// and `feature` each changed lines 2 and 9 of a ten-line file (git
/// folds closer changes into one block).
fn seedConflict(f: *Fixture) !void {
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("c.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n");
    try f.sh(&.{ "add", "c.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "initial" });
    try f.sh(&.{ "checkout", "-q", "-b", "feature" });
    try f.write("c.txt", "one\ntwo-theirs\nthree\nfour\nfive\nsix\nseven\neight\nnine-theirs\nten\n");
    try f.sh(&.{ "commit", "-q", "-am", "theirs" });
    try f.sh(&.{ "checkout", "-q", "main" });
    try f.write("c.txt", "one\ntwo-ours\nthree\nfour\nfive\nsix\nseven\neight\nnine-ours\nten\n");
    try f.sh(&.{ "commit", "-q", "-am", "ours" });
    // The merge fails on purpose: the conflict is the fixture.
    testing.allocator.free(try f.outRaw(&.{ "merge", "-q", "feature" }));
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(2000);
}

test "conflicts: the status pane lists the file under Conflicts; its row opens the editor with a header of chips per block, each chip a hit; the picks rewrite the blocks; the save stages the file" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    try seedConflict(&f);
    try command.run(&f.app, .{ .static = .@"git.status_pane" });
    try f.settle(2000);
    try testing.expectEqual(@as(u32, 1), f.app.git.status.?.conflicted);
    var txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "Conflicts (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "U c.txt") != null);
    testing.allocator.free(txt);
    // Enter on the row: the editor, not a diff.
    const sp = &f.app.panes.get(f.app.active.?).?.git_status;
    try statusAct(&f.app, sp, .diff);
    const e = f.app.activeEditor().?;
    const id = f.app.active.?;
    const regions = try conflicts.regionsOf(f.app.frame.allocator(), e);
    try testing.expectEqual(@as(usize, 2), regions.len);
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "conflict 1/2") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Ours  Theirs  Both  Edit  Split  AI resolve") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "<<<<<<< HEAD") != null);
    testing.allocator.free(txt);
    // The chips are hits that decode to their block and action.
    var found: [2]bool = .{ false, false };
    for (f.app.hits.items.items) |h| if (h.target == .script_hit and h.target.script_hit.pane == id) {
        if (conflicts.actionOf(h.target.script_hit.id)) |a| {
            if (a.region == 0 and a.action == .ours) found[0] = true;
            if (a.region == 1 and a.action == .theirs) found[1] = true;
        }
    };
    try testing.expect(found[0] and found[1]);
    // Block 1 → ours, block 2 → theirs (through the chip route).
    try conflicts.click(&f.app, id, conflicts.hitId(0, .ours));
    try conflicts.click(&f.app, id, conflicts.hitId(0, .theirs));
    try testing.expectEqualStrings("one\ntwo-ours\nthree\nfour\nfive\nsix\nseven\neight\nnine-theirs\nten\n", e.buf.editor.bytes());
    try testing.expect((try conflicts.regionsOf(f.app.frame.allocator(), e)).len == 0);
    // The save stages it: the status's conflicted count drops to zero.
    try command.run(&f.app, .{ .static = .@"file.save" });
    try f.settle(2000);
    try testing.expect(std.mem.indexOf(u8, f.app.lastToast().?, "staged c.txt") != null);
    try requestStatus(&f.app);
    try f.settle(2000);
    try testing.expectEqual(@as(u32, 0), f.app.git.status.?.conflicted);
    try testing.expectEqual(@as(u32, 1), f.app.git.status.?.staged);
}

test "conflicts: both keeps ours then theirs; the split job diffs :2: against :3: under the file's name" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    try seedConflict(&f);
    try conflicts.openConflicted(&f.app, "c.txt");
    const e = f.app.activeEditor().?;
    const id = f.app.active.?;
    try conflicts.resolve(&f.app, id, e, 1, .both);
    try testing.expect(std.mem.indexOf(u8, e.buf.editor.bytes(), "eight\nnine-ours\nnine-theirs\nten\n") != null);
    // `]x` from the top lands on the remaining block.
    e.buf.editor.placeCursor(0, 0);
    try conflicts.jump(&f.app, true);
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
    // Split: a diff pane on ours vs theirs, in the Split view.
    try conflicts.openSplit(&f.app, e);
    try f.settle(2000);
    const dp = activeDiff(&f.app).?;
    try testing.expectEqual(client.DiffScope.conflict, dp.scope);
    try testing.expectEqual(diff_view.Mode.split, dp.mode);
    try testing.expectEqual(@as(usize, 1), dp.files.len);
    try testing.expectEqualStrings("c.txt", dp.files[0].path());
    const lines = dp.files[0].hunks[0].lines;
    var del: usize = 0;
    var add: usize = 0;
    for (lines) |l| switch (l.kind) {
        .del => del += 1,
        .add => add += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), del);
    try testing.expectEqual(@as(usize, 2), add);
    try testing.expect(std.mem.indexOf(u8, dp.title, "conflict: c.txt") != null);
}

test "stage lines: the selection's two rows land in the index alone; the other change stays unstaged" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const dp = try f.seedTwoChanges();
    toggleDiffSelect(dp);
    stepDiff(dp, 1);
    const sel = (try selectedLines(dp, f.app.frame.allocator())).?;
    try testing.expectEqual(@as(usize, 2), sel.count);
    try applyHunk(&f.app, dp, .stage);
    try testing.expect(dp.anchor == null);
    try f.settle(2000);
    try testing.expectEqualStrings("staged 2 lines of code.txt", f.app.lastToast().?);
    const staged = try f.outRaw(&.{ "diff", "--cached" });
    defer testing.allocator.free(staged);
    try testing.expect(std.mem.indexOf(u8, staged, "-two\n+two-x\n") != null);
    try testing.expect(std.mem.indexOf(u8, staged, "four-x") == null);
    const unstaged = try f.outRaw(&.{"diff"});
    defer testing.allocator.free(unstaged);
    try testing.expect(std.mem.indexOf(u8, unstaged, "+four-x") != null);
    try testing.expect(std.mem.indexOf(u8, unstaged, "+two-x") == null);
    // A selection of context only is refused before any git runs.
    diffHome(dp, false);
    toggleDiffSelect(dp);
    try testing.expectError(error.Failed, applyHunk(&f.app, dp, .stage));
}

test "stash lines: the selection becomes its own stash, leaves the worktree, and pops back" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const dp = try f.seedTwoChanges();
    toggleDiffSelect(dp);
    stepDiff(dp, 1);
    try stashLines(&f.app, dp);
    try f.settle(2000);
    try testing.expectEqualStrings("stashed 2 lines of code.txt", f.app.lastToast().?);
    const file = try f.tmp.dir.readFileAlloc(testing.io, "code.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(file);
    try testing.expectEqualStrings("one\ntwo\nthree\nfour-x\nfive\n", file);
    const list = try f.outRaw(&.{ "stash", "list" });
    defer testing.allocator.free(list);
    try testing.expect(std.mem.indexOf(u8, list, "WIP on main") != null);
    const show = try f.outRaw(&.{ "stash", "show", "-p" });
    defer testing.allocator.free(show);
    try testing.expect(std.mem.indexOf(u8, show, "+two-x") != null);
    try testing.expect(std.mem.indexOf(u8, show, "four-x") == null);
    const staged = try f.outRaw(&.{ "diff", "--cached" });
    defer testing.allocator.free(staged);
    try testing.expectEqualStrings("", staged);
    // The pop needs a clean file (git's rule, not ours): drop the other
    // change first, then the stashed lines come back alone.
    try f.sh(&.{ "checkout", "--", "code.txt" });
    try f.sh(&.{ "stash", "pop", "-q" });
    const back = try f.tmp.dir.readFileAlloc(testing.io, "code.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("one\ntwo-x\nthree\nfour\nfive\n", back);
}

test "commit lines: HEAD gains the selection only; the other change is still unstaged and a staged file stays staged; undo is a soft reset" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const dp = try f.seedTwoChanges();
    try f.write("other.txt", "keep\n");
    try f.sh(&.{ "add", "other.txt" });
    toggleDiffSelect(dp);
    stepDiff(dp, 1);
    try commitLinesPrompt(&f.app, dp);
    try testing.expect(f.app.git.prompt == .commit_lines);
    try testing.expect(f.app.git.line_patch != null);
    try acceptPrompt(&f.app, "just two");
    try testing.expect(f.app.git.line_patch == null);
    try f.settle(2000);
    try testing.expectEqualStrings("committed lines: just two", f.app.lastToast().?);
    const head = try f.outRaw(&.{ "show", "--format=%s", "HEAD" });
    defer testing.allocator.free(head);
    try testing.expect(std.mem.startsWith(u8, head, "just two"));
    try testing.expect(std.mem.indexOf(u8, head, "+two-x") != null);
    try testing.expect(std.mem.indexOf(u8, head, "four-x") == null);
    try testing.expect(std.mem.indexOf(u8, head, "other.txt") == null);
    const st = try f.outRaw(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st);
    try testing.expect(std.mem.indexOf(u8, st, " M code.txt") != null);
    try testing.expect(std.mem.indexOf(u8, st, "A  other.txt") != null);
    // Undo: the commit is unmade and its lines are back in the index.
    try command.run(&f.app, .{ .static = .@"git.undo" });
    try f.settle(2000);
    const after = try f.outRaw(&.{ "show", "--format=%s", "-s", "HEAD" });
    defer testing.allocator.free(after);
    try testing.expect(std.mem.startsWith(u8, after, "initial"));
    const staged = try f.outRaw(&.{ "diff", "--cached" });
    defer testing.allocator.free(staged);
    try testing.expect(std.mem.indexOf(u8, staged, "+two-x") != null);
}

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
    var f = try Fixture.init(120, 20);
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
    // The status pane's lists: a.zig then new.txt unstaged, nothing staged.
    const files = try statusFiles(&f.app, f.app.frame.allocator());
    try testing.expectEqual(@as(usize, 2), files.unstaged.len);
    try testing.expectEqual(@as(usize, 0), files.staged.len);
    try testing.expectEqualStrings("src/a.zig", files.unstaged[0].path);
    try testing.expectEqual(@as(u8, 'M'), files.unstaged[0].letter);
    try testing.expectEqualStrings("new.txt", files.unstaged[1].path);
    try testing.expectEqual(@as(u8, '?'), files.unstaged[1].letter);
    try testing.expectEqual(@as(usize, 2), statusFlatLen(&f.app));
    // The statusline's branch chip (`app/statusline.zig`): the branch,
    // the ahead count, then one changed file and one added.
    try f.app.render();
    const row = try @import("../ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    defer testing.allocator.free(row);
    try testing.expect(std.mem.indexOf(u8, row, " \u{f126} main  ⇡1  \u{f0419} 1  \u{f06d5} 1 ") != null);
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
    try testing.expect(std.mem.indexOf(u8, txt, "Viewing ") != null);
    // The WIP row: at this width the summary is all the list shows.
    try testing.expect(std.mem.indexOf(u8, txt, "1 change(s) \u{B7} 1 new") != null);
    testing.allocator.free(txt);

    // Stage everything: the status says so.
    try command.run(&f.app, .{ .static = .@"git.stage_all" });
    try f.settle(2000);
    try f.settle(2000);
    try testing.expectEqual(@as(u32, 1), st.status.?.staged);
    try testing.expectEqual(@as(u32, 0), st.status.?.untracked);

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
    // Rust's row: `<old> <new> ▏+ text`.
    try testing.expect(std.mem.indexOf(u8, txt, "+ more") != null);
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
    var f = try Fixture.init(140, 30);
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
    f.app.focus = .{ .pane = f.app.active.? };
    const g = activeGraph(&f.app).?;
    try testing.expectEqual(@as(usize, 2), g.commits.len);
    try testing.expectEqualStrings("second commit", g.commits[0].subject);
    try testing.expectEqual(@as(u16, 0), g.lanes[1].lane);
    // The detail column follows the cursor: the newest commit's message
    // and file list are there without a keystroke.
    try testing.expect(g.detail != null);
    try testing.expectEqualStrings("second commit", g.detail.?.message);
    try testing.expectEqual(@as(usize, 1), g.detail.?.files.len);
    try testing.expectEqualStrings("a.txt", g.detail.?.files[0].path);
    var txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "second commit") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "COMMIT MESSAGE") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "changed files (1):") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  M a.txt") != null);
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
    try testing.expect(std.mem.indexOf(u8, txt, "+ two") != null);
    testing.allocator.free(txt);
}

test "the WIP row: a dirty tree puts it first, its buttons stage / unstage through the worker, and the cursor keeps its commit" {
    var f = try Fixture.init(140, 24);
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
    f.app.focus = .{ .pane = f.app.active.? };
    const g = activeGraph(&f.app).?;
    try testing.expect(g.has_wip);
    try testing.expectEqual(@as(usize, 2), g.totalRows());
    try testing.expect(g.wipSelected());
    const txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "WIP @") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "1 change(s) \u{B7} 1 new") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Unstaged Files (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, " Stage All ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "? b.txt") != null);
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

test "git mode: entering lists the branches and the worktree in the palette, one graph tab per repo; a branch row asks nothing and jumps; leaving puts the layout back" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.sh(&.{ "branch", "feature" });
    const st = &f.app.git;
    try f.write("b.txt", "two\n");
    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "b.txt" });
    defer testing.allocator.free(abs);
    const editor = try f.app.openPath(abs);
    try command.run(&f.app, .{ .static = .@"view.activity_git" });
    try testing.expect(f.app.git_palette.active);
    try testing.expect(f.app.focus == .pane);
    try f.settle(2000);
    try testing.expect(st.rail_loaded);
    try testing.expectEqual(@as(usize, 2), st.rail_branches.len);
    try testing.expectEqual(@as(usize, 1), st.rail_worktrees.len);
    // The sidebar snapped to a fifth of the screen; the layout is the one graph tab.
    try testing.expectEqual(@as(u16, 24), f.app.tree.width);
    const panes = try f.app.layouts.current().allPanes(f.app.frame.allocator());
    try testing.expectEqual(@as(usize, 1), panes.len);
    try testing.expect(f.app.panes.get(panes[0]).?.* == .git_graph);
    var txt = try f.screen();
    // The branches panel: the caps header, the pill, Viewing N (2 locals
    // + 1 worktree), the filter, LOCAL with the check on main, WORKTREES
    // with the house.
    try testing.expect(std.mem.indexOf(u8, txt, " GIT ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Viewing 3") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "/ filter") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F0140} \u{F0322} LOCAL") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  \u{F062C} feature") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F012C} \u{F062C} main") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F0140} \u{F0405} WORKTREES") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F012C} \u{F02DC} main") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F03D7} STASHES") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F04FB} TAGS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "git graph") == null);
    testing.allocator.free(txt);
    // A click on the feature row selects it and keeps the palette's focus.
    const rows = try git_palette.rows(&f.app, f.app.frame.allocator());
    var feature_row: ?usize = null;
    for (rows, 0..) |r, i| if (r == .branch and std.mem.eql(u8, r.branch.name, "feature")) {
        feature_row = i;
    };
    try git_palette.select(&f.app, feature_row.?);
    try testing.expectEqualStrings("feature", f.app.git_palette.selected.?);
    try testing.expect(f.app.focus == .pane);
    // Leaving through another section restores the editor.
    try command.run(&f.app, .{ .static = .@"view.activity_explorer" });
    try testing.expect(!f.app.git_palette.active);
    try testing.expectEqual(editor, f.app.active.?);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "LOCAL") == null);
    testing.allocator.free(txt);
    // Back in: the same pane, no second one.
    try command.run(&f.app, .{ .static = .@"git.graph" });
    const again = try f.app.layouts.current().allPanes(f.app.frame.allocator());
    try testing.expectEqualSlices(PaneId, panes, again);
}

test "the rail carries the worker's data: a stash, two tags newest first, a remote with its forge, and each worktree's lock and dirty state" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    // The app's own `.mnml/` and the nested trees must not dirty main.
    try f.write(".gitignore", ".mnml/\n.wt-*/\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.sh(&.{ "tag", "v1.0" });
    try f.write("a.txt", "two\n");
    try f.sh(&.{ "commit", "-q", "-am", "second" });
    try f.sh(&.{ "tag", "-a", "v2.0", "-m", "release two" });
    try f.sh(&.{ "remote", "add", "origin", "git@github.com:me/thing.git" });
    try f.write("a.txt", "three\n");
    try f.sh(&.{ "stash", "push", "-q", "-m", "half done" });
    const locked = try std.fs.path.join(testing.allocator, &.{ f.root, ".wt-locked" });
    defer testing.allocator.free(locked);
    const dirty = try std.fs.path.join(testing.allocator, &.{ f.root, ".wt-dirty" });
    defer testing.allocator.free(dirty);
    try f.sh(&.{ "worktree", "add", "-q", "-b", "locked-branch", locked });
    try f.sh(&.{ "worktree", "lock", "--reason", "keep", locked });
    try f.sh(&.{ "worktree", "add", "-q", "-b", "dirty-branch", dirty });
    try f.write(".wt-dirty/new.txt", "x\n");
    try command.run(&f.app, .{ .static = .@"view.activity_git" });
    try f.settle(4000);
    const st = &f.app.git;
    try testing.expect(st.rail_loaded);
    // Stash: one, with the note.
    try testing.expectEqual(@as(usize, 1), st.rail_stashes.len);
    try testing.expectEqualStrings("stash@{0}", st.rail_stashes[0].ref);
    try testing.expect(std.mem.endsWith(u8, st.rail_stashes[0].message, "half done"));
    try testing.expect(st.rail_stashes[0].sha.len >= 7);
    // Tags newest first; the annotated one peels to a commit sha.
    try testing.expectEqual(@as(usize, 2), st.rail_tags.len);
    try testing.expectEqualStrings("v2.0", st.rail_tags[0].name);
    try testing.expect(st.rail_tags[0].annotated);
    try testing.expectEqualStrings("v1.0", st.rail_tags[1].name);
    try testing.expect(!st.rail_tags[1].annotated);
    // The remote and its forge.
    try testing.expectEqual(@as(usize, 1), st.rail_remotes.len);
    try testing.expectEqualStrings("origin", st.rail_remotes[0].name);
    try testing.expectEqual(remote_mod.Provider.github, st.rail_remotes[0].provider);
    // Worktrees: main first and clean, the locked one with its reason,
    // the dirty one flagged.
    try testing.expectEqual(@as(usize, 3), st.rail_worktrees.len);
    try testing.expect(st.rail_worktrees[0].main);
    try testing.expectEqualStrings("main", st.rail_worktrees[0].branch);
    try testing.expect(!st.rail_worktrees[0].dirty);
    try testing.expect(!st.rail_worktrees[0].locked);
    var seen_locked = false;
    var seen_dirty = false;
    for (st.rail_worktrees[1..]) |w| {
        try testing.expect(!w.main);
        if (std.mem.eql(u8, w.branch, "locked-branch")) {
            seen_locked = true;
            try testing.expect(w.locked);
            try testing.expectEqualStrings("keep", w.lock_reason);
            try testing.expect(!w.dirty);
        } else if (std.mem.eql(u8, w.branch, "dirty-branch")) {
            seen_dirty = true;
            try testing.expect(w.dirty);
            try testing.expect(!w.locked);
        }
    }
    try testing.expect(seen_locked and seen_dirty);
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

test "undo restores each tree-touching op: amend --no-edit, reset --hard with a dirty tree, amend_to (fixup + autosquash)" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.write("b.txt", "two\n");
    try f.sh(&.{ "add", "b.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "second" });
    try discover(&f.app);
    const first = try f.out(&.{ "rev-parse", "HEAD~1" });
    defer testing.allocator.free(first);
    const second = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(second);

    // amend --no-edit: the staged file joins HEAD; undo leaves it staged again.
    try f.write("c.txt", "three\n");
    try f.sh(&.{ "add", "c.txt" });
    try testing.expectEqualStrings("amended HEAD with the staged changes", try f.op(.amend_noedit));
    const amended = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(amended);
    try testing.expect(!std.mem.eql(u8, amended, second));
    const files = try f.out(&.{ "show", "--format=", "--name-only", "HEAD" });
    defer testing.allocator.free(files);
    try testing.expect(std.mem.indexOf(u8, files, "c.txt") != null);
    try testing.expectEqualStrings("undid: amend (staged changes into HEAD)", try f.op(.undo));
    const back = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(second, back);
    const staged = try f.out(&.{ "diff", "--cached", "--name-only" });
    defer testing.allocator.free(staged);
    try testing.expectEqualStrings("c.txt", staged);
    try testing.expectEqualStrings("redid: amend (staged changes into HEAD)", try f.op(.redo));
    try testing.expectEqualStrings("undid: amend (staged changes into HEAD)", try f.op(.undo));

    // reset --hard to the first commit with c.txt staged and a.txt dirty:
    // both go, and undo brings HEAD, the index and the tree back.
    try f.write("a.txt", "one\nedited\n");
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.app.frame.allocator(), "reset --hard {s}", .{first[0..9]}), try f.op(.{ .reset = .{ .mode = .hard, .rev = try testing.allocator.dupe(u8, first) } }));
    const at_first = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(at_first);
    try testing.expectEqualStrings(first, at_first);
    const clean = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(clean);
    try testing.expectEqualStrings("", clean);
    try testing.expect(std.mem.startsWith(u8, try f.op(.undo), "undid: reset --hard"));
    const restored = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(second, restored);
    const porcelain = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(porcelain);
    try testing.expect(std.mem.indexOf(u8, porcelain, "A  c.txt") != null);
    try testing.expect(std.mem.indexOf(u8, porcelain, "M a.txt") != null);

    // reset --soft: HEAD moves, the index keeps b.txt; undo puts HEAD back.
    try testing.expect(std.mem.startsWith(u8, try f.op(.{ .reset = .{ .mode = .soft, .rev = try testing.allocator.dupe(u8, first) } }), "reset --soft"));
    const soft_staged = try f.out(&.{ "diff", "--cached", "--name-only" });
    defer testing.allocator.free(soft_staged);
    try testing.expect(std.mem.indexOf(u8, soft_staged, "b.txt") != null);
    try testing.expect(std.mem.startsWith(u8, try f.op(.undo), "undid: reset --soft"));
    const soft_back = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(soft_back);
    try testing.expectEqualStrings(second, soft_back);

    // amend_to: c.txt (staged) folds into the FIRST commit; the dirty
    // a.txt survives the autostash; undo puts every sha back.
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.app.frame.allocator(), "amended {s} with the staged changes", .{first[0..7]}), try f.op(.{ .amend_to = try testing.allocator.dupe(u8, first) }));
    const first_files = try f.out(&.{ "show", "--format=", "--name-only", "HEAD~1" });
    defer testing.allocator.free(first_files);
    try testing.expect(std.mem.indexOf(u8, first_files, "c.txt") != null);
    const count = try f.out(&.{ "rev-list", "--count", "HEAD" });
    defer testing.allocator.free(count);
    try testing.expectEqualStrings("2", count);
    const dirty = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(dirty);
    try testing.expectEqualStrings("M a.txt", dirty);
    try testing.expect(std.mem.startsWith(u8, try f.op(.undo), "undid: amend to"));
    const undone = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(undone);
    try testing.expectEqualStrings(second, undone);
    const again = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "A  c.txt") != null);
    try testing.expect(std.mem.indexOf(u8, again, "M a.txt") != null);
}
