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
const alloc_mod = @import("../core/alloc.zig");
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
const sequence_editor = @import("../git/sequence_editor.zig");
const remote_mod = @import("../git/remote.zig");
const ai_app = @import("ai.zig");
const api = @import("../ai/api_client.zig");
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
const cmd_view = @import("cmd_view.zig");
const context_menus = @import("context_menus.zig");
const git_palette = @import("git_palette.zig");
const conflicts = @import("conflicts.zig");
const clock = @import("clock.zig");

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
    /// `git.diff_against_current` off the branches panel: pick the branch.
    diff_current,
    /// `git.set_upstream`: pick the remote branch `State.verb_branch` tracks.
    set_upstream,
    /// `git.stash_show` / `_branch` / `_rename` off the panel: pick the stash.
    stash_show,
    stash_branch,
    stash_rename,
    /// `git.checkout_force` / `git.delete_remote_branch` off the panel: pick the branch.
    checkout_force,
    delete_remote,
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
    /// The plan modal's `r`: the new message for the row at its cursor.
    plan_reword,
    /// `git.reword` on the graph's selected commit: the message, then
    /// a one-line plan runs.
    reword,
    /// `git.reset_*` outside the graph and the branches panel: a rev.
    reset_soft,
    reset_mixed,
    reset_hard,
    /// `git.branch_rename`: the new name for `State.verb_branch`.
    branch_rename,
    /// A tag on the branches panel's row (`State.verb_start` is its
    /// ref): lightweight, or annotated with the name as its message.
    tag_at,
    tag_annotated_at,
    /// `stash branch <name> <State.verb_branch>`.
    stash_branch,
    /// A stash's new message (`State.verb_branch` is its ref).
    stash_rename,
    /// // changed (git-menus): `worktree lock --reason` — the note, if
    /// any (`State.verb_branch` holds the tree's path).
    worktree_lock,
};

/// What the next stash prompt pushes (`git.stash_staged` / `_file` /
/// `_keep_index` set one before opening it; a plain `git.stash` none).
pub const StashVariant = struct {
    staged_only: bool = false,
    keep_index: bool = false,
    /// Owned.
    path: ?[]u8 = null,
};

/// The stash whose files the `stash_files` list pane shows. Owned.
pub const StashView = struct { repo: u32, ref: []u8, message: []u8 };

/// One child the worker ran (git-more2), as `client.LogLine` said,
/// owned by the ring.
pub const LogEntry = struct {
    seq: u32,
    repo: u32,
    /// The whole line, for the row; `args` the part after `git`, for a re-run.
    argv: []u8,
    args: [][]u8,
    cwd: []u8,
    ok: bool,
    exit: ?u8,
    ms: u32,
    stderr: []u8,

    pub fn deinit(e: LogEntry, gpa: Allocator) void {
        gpa.free(e.argv);
        for (e.args) |a| gpa.free(a);
        gpa.free(e.args);
        gpa.free(e.cwd);
        gpa.free(e.stderr);
    }
};

/// The command log: the last `cap` children, oldest first; a push past
/// the cap drops the oldest.
pub const LogRing = struct {
    pub const cap: usize = 200;
    items: std.ArrayListUnmanaged(LogEntry) = .empty,

    pub fn push(self: *LogRing, gpa: Allocator, e: LogEntry) Allocator.Error!void {
        errdefer e.deinit(gpa);
        try self.items.append(gpa, e);
        while (self.items.items.len > cap) self.items.orderedRemove(0).deinit(gpa);
    }

    pub fn deinit(self: *LogRing, gpa: Allocator) void {
        for (self.items.items) |e| e.deinit(gpa);
        self.items.deinit(gpa);
    }

    pub fn find(self: *const LogRing, seq: u32) ?*const LogEntry {
        for (self.items.items) |*e| if (e.seq == seq) return e;
        return null;
    }
};

/// The failed-op toast's id: a click on it opens the command log at
/// the entry (`dispatch`'s toast arm; the toast menu's row).
pub const log_toast_id = "git-log";

/// A confirm box's payload; the path is owned.
pub const Confirm = union(enum) {
    none,
    discard: []u8,
    discard_hunk: struct { pane: PaneId },
    delete_branch: []u8,
    worktree_remove: []u8,
    /// // changed (git-menus): a WORKTREES row's *Remove worktree and
    /// delete branch* — the plain Remove refuses a dirty tree, the
    /// confirm's Force choice takes it anyway (`worktree remove
    /// --force` + `branch -D`).
    worktree_remove_branch: struct { path: []u8, branch: []u8, dirty_files: u32 },
    /// A palette row: checkout after a yes (a tag lands detached).
    checkout: []u8,
    tag_delete: []u8,
    /// `reset --hard <rev>` after a yes.
    reset_hard: []u8,
    /// `checkout -f <branch>` after a yes: the tree's changes go.
    checkout_force: []u8,
    /// `push <remote> --delete <branch>` after a yes.
    delete_remote: struct { remote: []u8, branch: []u8 },
    /// `push --force-with-lease` after a yes.
    push_force,

    pub fn deinit(c: Confirm, gpa: Allocator) void {
        switch (c) {
            .discard, .delete_branch, .worktree_remove, .checkout, .tag_delete, .reset_hard, .checkout_force => |s| gpa.free(s),
            .worktree_remove_branch => |w| {
                gpa.free(w.path);
                gpa.free(w.branch);
            },
            .delete_remote => |d| {
                gpa.free(d.remote);
                gpa.free(d.branch);
            },
            .none, .discard_hunk, .push_force => {},
        }
    }
};

/// An AI commit-message job in flight: the `Pane.ai` it streams into
/// and what to do with the answer when the pane says done.
pub const AiWait = struct {
    pane: PaneId,
    what: enum { commit, recompose },
    /// The graph pane whose commit box takes the answer (its WIP row was
    /// selected when the job was asked for); null = the prompt.
    wip: ?PaneId = null,
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
    /// `/`: the hash prefix typed into the header chip (Rust's
    /// `hash_filter`); every hex digit jumps to the first commit it
    /// prefixes. A full SHA is 40 hex digits.
    hash_filter: [40]u8 = undefined,
    hash_filter_len: u8 = 0,
    hash_filter_mode: bool = false,
    /// A drag override of the panel's width.
    detail_w: ?u16 = null,
    /// The working-tree row is shown (the status has changes).
    has_wip: bool = false,
    /// A status has been seen: from here a WIP row appearing or going
    /// shifts the cursor so it keeps its commit.
    wip_known: bool = false,
    /// What the last frame measured, for the divider drag.
    body: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Multi-select: indices into `commits`. Dropped with the log.
    marks: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// A `v` range in progress: the virtual row it started on.
    anchor: ?usize = null,
    /// The rebase plan while its modal is open.
    plan: ?Plan = null,
    /// `W`: the commit a `d` on another row diffs from (`base..row`).
    /// Owned; a sha, so it survives a log reload.
    compare_base: ?[]u8 = null,

    pub fn deinit(self: *GraphPane) void {
        self.gpa.free(self.name);
        if (self.compare_base) |b| self.gpa.free(b);
        self.wip_text.deinit(self.gpa);
        self.filter.deinit(self.gpa);
        self.marks.deinit(self.gpa);
        if (self.plan) |*p| p.deinit(self.gpa);
        self.detail_arena.deinit();
        self.arena.deinit();
    }

    pub fn isMarked(self: *const GraphPane, ci: usize) bool {
        return self.marks.contains(@intCast(ci));
    }

    /// The virtual rows of the `v` range, both ends in.
    pub fn range(self: *const GraphPane) ?[2]usize {
        const a = self.anchor orelse return null;
        return .{ a, self.cursor };
    }

    /// Fold the range into the marks and drop the anchor.
    pub fn commitRange(self: *GraphPane) Allocator.Error!void {
        const rg = self.range() orelse return;
        var v = @min(rg[0], rg[1]);
        while (v <= @max(rg[0], rg[1])) : (v += 1) {
            if (v < self.wipRows()) continue;
            const pos = v - self.wipRows();
            if (pos >= self.order.len) break;
            try self.marks.put(self.gpa, self.order[pos], {});
        }
        self.anchor = null;
    }

    pub fn clearSelection(self: *GraphPane) void {
        self.marks.clearRetainingCapacity();
        self.anchor = null;
    }

    pub fn closePlan(self: *GraphPane) void {
        if (self.plan) |*p| p.deinit(self.gpa);
        self.plan = null;
    }

    fn wipRows(self: *const GraphPane) usize {
        return if (self.has_wip) 1 else 0;
    }

    pub fn totalRows(self: *const GraphPane) usize {
        return self.commits.len + self.wipRows();
    }

    pub fn hashFilter(self: *const GraphPane) []const u8 {
        return self.hash_filter[0..self.hash_filter_len];
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

/// One line of the rebase plan: a commit of the graph and what the
/// rebase does with it. `message` (owned) is a reword's new text.
pub const PlanRow = struct {
    ci: u32,
    action: parse.TodoAction = .pick,
    /// One the user selected; the others are the commits in between.
    marked: bool = false,
    message: ?[]u8 = null,
};

/// The plan modal's state: the todo, oldest first, and the parent the
/// rebase starts from (null = `--root`).
pub const Plan = struct {
    rows: std.ArrayListUnmanaged(PlanRow) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    base: ?[]u8 = null,

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        for (self.rows.items) |r| if (r.message) |m| gpa.free(m);
        self.rows.deinit(gpa);
        if (self.base) |b| gpa.free(b);
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
    /// Set by `askAi` while the repo reads the diff: the graph pane whose
    /// commit box is waiting (`wip_ai`), handed to `AiWait` when the job
    /// starts.
    ai_wip_target: ?PaneId = null,
    ai_product: ai_app.Product = .claude,
    /// A message body the AI returned, appended to the prompt's subject
    /// line at accept. Owned.
    ai_body: ?[]u8 = null,
    /// The patch a `commit_lines` prompt will commit, and its repo.
    /// Owned; taken by the accept, dropped by a cancel.
    line_patch: ?[]u8 = null,
    line_repo: u32 = 0,
    /// The branch verbs (git-more2): the branch a rename prompt or the
    /// set-upstream picker acts on, and the commit / tag a new branch
    /// or worktree prompt starts from. Owned; replaced by the next verb.
    verb_branch: ?[]u8 = null,
    verb_start: ?[]u8 = null,
    /// The stash prompt's variant, and the stash the files pane shows.
    stash_variant: StashVariant = .{},
    stash_view: ?StashView = null,
    /// The command log (git-more2): every child the workers ran, the
    /// seq of the last one that failed, and the entry the failed-op
    /// toast's `log` link opens at.
    log: LogRing = .{},
    log_next_seq: u32 = 1,
    last_failed_seq: ?u32 = null,
    log_link_seq: ?u32 = null,
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
    /// The commit prompt's title: the prompt keeps the slice.
    commit_title: [64]u8 = undefined,

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
        if (self.verb_branch) |b| gpa.free(b);
        if (self.verb_start) |b| gpa.free(b);
        if (self.stash_variant.path) |p| gpa.free(p);
        if (self.stash_view) |v| {
            gpa.free(v.ref);
            gpa.free(v.message);
        }
        self.log.deinit(gpa);
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
    runArgv(app, argv, "a browser");
}

/// Hand `argv` to the OS the way `openExternal` does — `open` and its
/// kin return at once, so the wait is short; a failure to start it is
/// toasted as "could not open <what>".
pub fn runArgv(app: *App, argv: []const []const u8, what: []const u8) void {
    const res = std.process.run(app.gpa, app.io, .{ .argv = argv, .cwd = .{ .path = app.workspace }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch |err| {
        app.toast("could not open {s}: {s}", .{ what, @errorName(err) });
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
    // Rust routes the answer into the graph's commit box when its WIP
    // row is selected; the prompt otherwise.
    st.ai_wip_target = null;
    if (what == .staged) if (activeGraph(app)) |g| if (g.wipSelected()) {
        st.ai_wip_target = app.active;
        g.wip_ai = true;
    };
    try submit(app, repo, .{ .ai_context = what });
    app.toast("{s}: reading the {s}…", .{ if (product == .claude) "claude" else "codex", if (what == .staged) "staged diff" else "HEAD patch" });
}

/// `git.explain_branch` (git-menus): the commits a branch has that its
/// base does not, summarised by the AI into a read-only pane titled
/// `explain: <branch>`. The base is the checked-out branch, or — on the
/// checked-out branch itself — its upstream. The git runs on the
/// worker; the answer streams into the pane, so neither blocks a frame.
pub fn explainBranch(app: *App, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const gpa = app.gpa;
    const repo = try requireRepo(app);
    const head = app.git.branchLabel() orelse "";
    var base: []const u8 = "";
    if (head.len > 0 and !std.mem.eql(u8, name, head)) {
        base = head;
    } else if (railBranch(app, name)) |b| {
        base = b.upstream;
    }
    if (base.len == 0) return app.diag.fail(arena, "explain {s}: it is the checked-out branch and has no upstream \u{2014} nothing to compare it against", .{name});
    // Fail on a route that cannot run before any git does.
    switch (ai_app.route(app, .claude)) {
        .off => return app.diag.fail(arena, "AI is routed off ([ai.routing.claude] backend = \"off\")", .{}),
        .api => if (app.env.get(api.env_key) == null) return app.diag.fail(arena, "AI: ${s} not set (the API backend needs it)", .{api.env_key}),
        .cli => {},
    }
    const branch = try gpa.dupe(u8, name);
    errdefer gpa.free(branch);
    const b = try gpa.dupe(u8, base);
    errdefer gpa.free(b);
    try submit(app, repo, .{ .branch_explain = .{ .branch = branch, .base = b } });
    app.toast("explain {s}: reading {s}..{s}\u{2026}", .{ name, base, name });
}

const explain_log_cap: usize = 24_000;

/// The worker read the range: the prompt goes to the AI, whose pane is
/// the answer.
fn branchExplainReady(app: *App, branch: []const u8, base: []const u8, text: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        app.toast("explain {s}: nothing {s} does not already have", .{ branch, base });
        return;
    }
    const cut = text[0..@min(text.len, explain_log_cap)];
    const tail: []const u8 = if (text.len > explain_log_cap) "\n\u{2026}(log truncated)\u{2026}" else "";
    const prompt = try std.fmt.allocPrint(arena, "Summarise what the branch `{s}` changes relative to `{s}`, for a reviewer who has not read the commits. Lead with one sentence saying what the branch is for. Then the themes of the work, grouped, largest first, each naming the files it touches. End with anything risky or surprising. No preamble, no code fences.\n\n```\n{s}{s}\n```", .{ branch, base, cut, tail });
    const title = try std.fmt.allocPrint(arena, "explain: {s}", .{branch});
    _ = ai_app.askProduct(app, .claude, title, prompt, .git, null) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        runToast(app, err);
    };
}

const ai_diff_cap: usize = 24_000;

fn aiContextReady(app: *App, repo: *client.Repo, what: client.AiContext, diff: []const u8, message: []const u8) Allocator.Error!void {
    const st = &app.git;
    const arena = app.frame.allocator();
    const wip_target = st.ai_wip_target;
    st.ai_wip_target = null;
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        clearWipAi(app, wip_target);
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
        clearWipAi(app, wip_target);
        runToast(app, err);
        return;
    };
    st.ai_wait = .{ .pane = pane, .what = if (what == .staged) .commit else .recompose, .wip = wip_target };
}

/// The commit box stops waiting (the job never started, or ended).
fn clearWipAi(app: *App, target: ?PaneId) void {
    const id = target orelse return;
    const pane = app.panes.get(id) orelse return;
    if (pane.* == .git_graph) pane.git_graph.wip_ai = false;
}

/// The graph pane a waiting job's answer goes to, when it still exists
/// and still has a working-tree row to put it under.
fn wipTarget(app: *App, w: AiWait) ?*GraphPane {
    const id = w.wip orelse return null;
    const pane = app.panes.get(id) orelse return null;
    if (pane.* != .git_graph) return null;
    return &pane.git_graph;
}

/// The AI's answer lands: in the graph's commit box when the job was
/// asked from its WIP row (Rust `set_text` + focus — the box then reads
/// as typed, `c` commits it), else in the commit / amend prompt with
/// the body kept for the accept.
pub fn deliverAiAnswer(app: *App, w: AiWait, text: []const u8) Allocator.Error!void {
    const st = &app.git;
    const msg = cleanCommitMessage(text);
    if (wipTarget(app, w)) |g| {
        g.wip_ai = false;
        if (msg.subject.len == 0) {
            app.toast("AI returned an empty commit message", .{});
            return;
        }
        g.wip_text.clearRetainingCapacity();
        try g.wip_text.appendSlice(app.gpa, msg.subject);
        if (msg.body.len > 0) {
            try g.wip_text.appendSlice(app.gpa, "\n\n");
            try g.wip_text.appendSlice(app.gpa, msg.body);
        }
        g.wip_cursor = g.wip_text.items.len;
        g.wip_focused = true;
        app.needs_render = true;
        return;
    }
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
            clearWipAi(app, w.wip);
            try app.toastLevel(.err, "AI: {s}", .{ap.err orelse "the job failed"});
            try app.closePane(w.pane, true);
        },
        .done => {
            st.ai_wait = null;
            const text = try app.gpa.dupe(u8, ap.answer.items);
            defer app.gpa.free(text);
            try app.closePane(w.pane, true);
            try deliverAiAnswer(app, w, text);
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
                    // The indices the selection and the plan name are the
                    // old log's.
                    g.clearSelection();
                    g.closePlan();
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
                // The `log` link: the toast carries the id a click opens
                // the command log through, at the child that failed.
                st.log_link_seq = st.last_failed_seq;
                // The box wraps `toast.max_lines` rows of `max_text`
                // chars and drops what is past them: the reason is cut
                // (eight cells of wrap slack a row) so the link at the
                // end stays visible. It was cut to ONE row, which lost
                // the half of a rejected push's sentence that says what
                // to do.
                const toast_mod = @import("../ui/toast.zig");
                const cut = clipReason(op.msg, (toast_mod.max_text -| 8) * toast_mod.max_lines -| (op.desc.len + 8));
                app.toastReplace(log_toast_id, "{s}: {s}{s} \u{B7} log", .{ op.desc, cut, if (cut.len < op.msg.len) "\u{2026}" else "" });
                if (app.toasts.items.len > 0) app.toasts.items[app.toasts.items.len - 1].level = .err;
            } else {
                app.toast("{s}", .{op.desc});
            }
            // git-menus: *Push and start PR* — the forge's page opens
            // once the push landed, never before it.
            if (op.ok and op.url.len > 0) {
                openExternal(app, op.url);
                app.toast("{s}", .{op.url});
            }
            if (op.refresh) try afterChange(app, repo);
        },
        .log_line => |l| {
            const args = try gpa.alloc([]u8, l.args.len);
            var filled: usize = 0;
            errdefer {
                for (args[0..filled]) |a| gpa.free(a);
                gpa.free(args);
            }
            for (l.args) |a| {
                args[filled] = try gpa.dupe(u8, a);
                filled += 1;
            }
            const argv = try gpa.dupe(u8, l.argv);
            errdefer gpa.free(argv);
            const cwd = try gpa.dupe(u8, l.cwd);
            errdefer gpa.free(cwd);
            const stderr = try gpa.dupe(u8, l.stderr);
            errdefer gpa.free(stderr);
            // One sequence over every repo, in the order the lines land.
            const seq = st.log_next_seq;
            st.log_next_seq +%= 1;
            try st.log.push(gpa, .{ .seq = seq, .repo = repo.id, .argv = argv, .args = args, .cwd = cwd, .ok = l.ok, .exit = l.exit, .ms = l.ms, .stderr = stderr });
            if (!l.ok) st.last_failed_seq = seq;
            try refillLogPane(app, null);
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
        .stash_show => |s| {
            // The files pane: `M  path` rows, the path on the entry for Enter.
            var entries: std.ArrayListUnmanaged(app_mod.ListPane.Entry) = .empty;
            errdefer {
                app_mod.ListPane.freeEntries(gpa, entries.items);
                entries.deinit(gpa);
            }
            for (s.files) |fl| {
                const text = try std.fmt.allocPrint(gpa, "{c}  {s}", .{ fl.status, fl.path });
                errdefer gpa.free(text);
                try entries.append(gpa, .{ .text = text, .path = try gpa.dupe(u8, fl.path) });
            }
            const ref = try gpa.dupe(u8, s.ref);
            errdefer gpa.free(ref);
            const message = try gpa.dupe(u8, s.message);
            errdefer gpa.free(message);
            if (st.stash_view) |v| {
                gpa.free(v.ref);
                gpa.free(v.message);
            }
            st.stash_view = .{ .repo = repo.id, .ref = ref, .message = message };
            cmd_view.openListPane(app, .stash_files, try entries.toOwnedSlice(gpa)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            // A list pane opens on its last row; a stash's files read top-down.
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .list => |*l| if (l.kind == .stash_files) {
                    l.cursor = 0;
                },
                else => {},
            };
        },
        .file_text => |ft| {
            _ = app.openScratchWith(ft.text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            app.toast("{s} at {s} (a scratch copy)", .{ ft.path, ft.rev[0..@min(7, ft.rev.len)] });
        },
        .ai_context => |c| try aiContextReady(app, repo, c.what, c.diff, c.message),
        .branch_explain => |e| try branchExplainReady(app, e.branch, e.base, e.text),
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
///
/// // changed: the pane's conflicts LEAD the unstaged list. The pane
/// draws them first, in a section of their own, and the flat index the
/// cursor walks is this list's — when the two disagreed (a conflict
/// after `.gitignore` in porcelain order, drawn above it) the cursor
/// opened on the row below the conflict, `g` / `k` / Home could not
/// reach it, `j` moved UP onto it and Enter opened the wrong diff.
fn collectFiles(app: *App, arena: Allocator, for_graph: bool) Allocator.Error!Files {
    var un: std.ArrayListUnmanaged(Row) = .empty;
    var st: std.ArrayListUnmanaged(Row) = .empty;
    if (app.git.status) |status| {
        if (!for_graph) for (status.entries) |e| if (e.group == .conflicted) try un.append(arena, .{ .path = e.path, .letter = 'U', .staged = false });
        for (status.entries) |e| switch (e.group) {
            .staged => try st.append(arena, .{ .path = e.path, .letter = e.code, .staged = true }),
            .unstaged => try un.append(arena, .{ .path = e.path, .letter = e.code, .staged = false }),
            .untracked => try un.append(arena, .{ .path = if (for_graph) std.mem.trimEnd(u8, e.path, "/") else e.path, .letter = '?', .staged = false }),
            .conflicted => if (for_graph) try un.append(arena, .{ .path = e.path, .letter = '!', .staged = false }),
        };
    }
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
    }, .priority = editor_view.mark_priority.git_change };
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

/// Where a new pane goes: a tab of the focused leaf (Rust
/// `reveal_pane`), or a leaf of its own beside it (`split_leaf_with`).
pub const Placement = enum { tab, beside };

/// Rust `split_leaf_with`: a new pane opens in a leaf to the right of
/// the active one, the active leaf's tabs staying on the left, when
/// that leaf has the room — forty cells each — and as a tab of it when
/// it has not. A pane already in the layout is revealed where it is;
/// with no active leaf the pane is the layout.
pub fn showBeside(app: *App, id: PaneId) void {
    const layout = app.layouts.current();
    if (layout.leafOf(id) != null) return app.showPane(id);
    const cur = app.active orelse return app.showPane(id);
    if (layout.leafOf(cur) == null or activePaneWidth(app) < 2 * min_split_w) return app.showPane(id);
    _ = layout.split(cur, .horizontal, id) catch return app.showPane(id);
    app.afterSplitChange();
    app.setActive(id);
}

/// A half of a split needs this much: the graph's toolbar, a diff's hunk row.
const min_split_w: usize = 40;

pub fn openDiff(app: *App, repo: *client.Repo, scope: client.DiffScope, rel: ?[]const u8, rev: ?[]const u8, text: ?[]const u8) CommandError!PaneId {
    return openDiffPlaced(app, repo, scope, rel, rev, text, .tab);
}

pub fn openDiffPlaced(app: *App, repo: *client.Repo, scope: client.DiffScope, rel: ?[]const u8, rev: ?[]const u8, text: ?[]const u8, placement: Placement) CommandError!PaneId {
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
        .range => blk: {
            const t = try client.rangeTitle(gpa, rev orelse "");
            if (rel == null) break :blk t;
            defer gpa.free(t);
            break :blk try std.fmt.allocPrint(gpa, "{s} {s}", .{ t, std.fs.path.basename(rel.?) });
        },
    };
    errdefer gpa.free(title);
    var dp: DiffPane = .{ .gpa = gpa, .repo = repo.id, .scope = scope, .title = title, .arena = .init(gpa), .mode = app.git.diff_mode };
    errdefer dp.deinit();
    if (rel) |p| dp.path = try gpa.dupe(u8, p);
    if (rev) |v| dp.rev = try gpa.dupe(u8, v);
    const id = try app.panes.add(.{ .diff = dp });
    dp = undefined;
    switch (placement) {
        .tab => app.showPane(id),
        .beside => showBeside(app, id),
    }
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

/// The repo whose root is `root`, discovering them first if nothing
/// has yet (a session restore runs before anything asks git anything).
/// Null when that directory is not one of this workspace's repos any
/// more — the "subject gone" answer for every saved git pane.
/// // changed (session-kinds).
pub fn repoByPath(app: *App, root: []const u8) Allocator.Error!?*client.Repo {
    if (!app.git.discovered) try discover(app);
    for (app.git.repos.items) |r| if (std.mem.eql(u8, r.path, root)) return r;
    return null;
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
    // Rust `open_git_status`: a split to the right of the focused leaf.
    showBeside(app, id);
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
    try openPromptOwned(app, .commit_lines, try std.fmt.allocPrint(arena, "Commit message for the {s}", .{vp.desc["staged ".len..]}));
}

test "openPromptOwned: a title built on the frame arena survives the next frame — the overlay owns a copy" {
    var frame_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&frame_buf);
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    app.frame.deinit();
    app.frame = alloc_mod.FrameArena.init(fba.allocator());
    const title = try std.fmt.allocPrint(app.frame.allocator(), "Commit message for the {d} lines of code.txt", .{2});
    try openPromptOwned(&app, .commit_lines, title);
    // The next frame reuses the arena from offset zero.
    app.frame.begin();
    for (0..1024) |_| {
        const chunk = try app.frame.allocator().alloc(u8, 16);
        @memset(chunk, 'X');
    }
    try std.testing.expect(app.overlay == .prompt);
    try std.testing.expect(app.overlay.prompt.title_owned != null);
    try std.testing.expectEqualStrings("Commit message for the 2 lines of code.txt", app.overlay.prompt.state.title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.frame.deinit();
    app.frame = alloc_mod.FrameArena.init(app.gpa);
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
        try std.fmt.allocPrint(app.gpa, "Discard the {d} selected line{s} from the worktree? This cannot be undone.", .{ sel.?.count, if (sel.?.count == 1) "" else "s" })
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
    // Every row names the scope, so the labels are built for this open:
    // they go on an arena the menu owns, not the frame's, which the next
    // paint hands back from offset zero.
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    switch (dp.scope) {
        .file, .worktree, .head => {
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Stage {s}", .{what}), .action = .{ .command = .@"git.diff_stage_lines" } });
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Discard {s}\u{2026}", .{what}), .action = .{ .command = .@"git.diff_discard_lines" } });
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Stash {s}", .{what}), .action = .{ .command = .@"git.diff_stash_lines" }, .separator_before = true });
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Commit {s}\u{2026}", .{what}), .action = .{ .command = .@"git.diff_commit_lines" } });
        },
        .staged => try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Unstage {s}", .{what}), .action = .{ .command = .@"git.diff_unstage_lines" } }),
        .commit, .orig, .conflict, .range => {},
    }
    try items.append(app.gpa, .{ .label = if (has_sel) "Clear selection" else "Select lines from here", .action = .{ .command = .@"git.diff_select" }, .separator_before = items.items.len > 0 });
    try items.append(app.gpa, .{ .label = "Open file at line", .action = .{ .command = .@"git.diff_open_line" } });
    const owned = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, "Diff", owned, x, y, mem);
}

test "openDiffRowMenu: the row labels survive the next frame — the menu owns them" {
    var frame_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&frame_buf);
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    // A fixed buffer, where a reset hands the SAME bytes back: a
    // DebugAllocator-backed arena would give the next frame fresh pages
    // and the scribble would never reach the dead ones.
    app.frame.deinit();
    app.frame = alloc_mod.FrameArena.init(fba.allocator());
    defer {
        app.overlay.deinit(app.gpa);
        app.overlay = .none;
        app.frame.deinit();
        app.frame = alloc_mod.FrameArena.init(app.gpa);
    }
    var dp: DiffPane = .{ .gpa = app.gpa, .repo = 0, .scope = .worktree, .title = try app.gpa.dupe(u8, "diff"), .arena = .init(app.gpa) };
    defer dp.deinit();
    try openDiffRowMenu(&app, &dp, 4, 4);
    // The next frame reuses the arena from offset zero.
    app.frame.begin();
    for (0..1024) |_| {
        const chunk = try app.frame.allocator().alloc(u8, 16);
        @memset(chunk, 'X');
    }
    try std.testing.expect(app.overlay == .menu);
    try std.testing.expectEqualStrings("Stage hunk", app.overlay.menu.items[0].label);
    try std.testing.expectEqualStrings("Discard hunk\u{2026}", app.overlay.menu.items[1].label);
    try std.testing.expectEqualStrings("Stash hunk", app.overlay.menu.items[2].label);
    try std.testing.expectEqualStrings("Commit hunk\u{2026}", app.overlay.menu.items[3].label);
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
        // A delete / merge / rebase / diff picker never offers the current branch.
        if (b.current and (what == .delete_branch or what == .merge or what == .rebase or what == .diff_current)) continue;
        if (what == .delete_branch and b.remote) continue;
        // An upstream is a remote branch; a force checkout a local one.
        if (what == .set_upstream and !b.remote) continue;
        if (what == .checkout_force and (b.remote or b.current)) continue;
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
        .diff_current => "Diff a branch against the current one",
        .set_upstream => "Set upstream: the remote branch to track",
        .checkout_force => "Force checkout (the tree's changes go)",
        .delete_remote => "Delete a branch on the remote",
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
        .stash_show => "Stash: show the files",
        .stash_branch => "Stash: branch from",
        .stash_rename => "Stash: rename",
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
        .diff_current => try diffAgainstCurrent(app, try requireRepo(app), label),
        .set_upstream => {
            const branch = st.verb_branch orelse return app.diag.fail(app.frame.allocator(), "set upstream: the branch is gone", .{});
            try submitOp(app, try requireRepo(app), .{ .set_upstream = .{ .branch = try gpa.dupe(u8, branch), .upstream = try gpa.dupe(u8, label) } });
        },
        .checkout_force => try checkoutForce(app, label),
        .delete_remote => try deleteRemote(app, label, null),
        .delete_branch => try openConfirm(app, .{ .delete_branch = try gpa.dupe(u8, label) }, try std.fmt.allocPrint(gpa, "Delete branch {s}? (git branch -D)", .{label})),
        .graph_branch => {
            const g = activeGraph(app) orelse return;
            if (g.filter.branch) |b| gpa.free(b);
            g.filter.branch = try gpa.dupe(u8, label);
            try refreshGraph(app, g);
        },
        .stash_apply => try submitOp(app, try requireRepo(app), .{ .stash_apply = try gpa.dupe(u8, detail) }),
        .stash_drop => try submitOp(app, try requireRepo(app), .{ .stash_drop = try gpa.dupe(u8, detail) }),
        .stash_show => try stashShow(app, detail),
        .stash_branch => try stashBranchPrompt(app, detail),
        .stash_rename => {
            // The picker's label is `<ref>  <message>`.
            const note = if (std.mem.indexOf(u8, label, "  ")) |s| label[s + 2 ..] else "";
            try stashRenamePrompt(app, detail, note);
        },
        .tag_delete => try submitOp(app, try requireRepo(app), .{ .tag_delete = try gpa.dupe(u8, detail) }),
        .reflog, .file_history => {
            const repo = try requireRepo(app);
            const rel: ?[]const u8 = if (what == .file_history) (if (app.activeEditor()) |e| (if (e.buf.doc.path) |p| relToRepo(repo, p) else null) else null) else null;
            _ = try openDiff(app, repo, .commit, rel, detail, null);
        },
        .worktree_open, .worktree_shell => app.toast("worktree: {s}", .{detail}),
        .worktree_remove => try openConfirm(app, .{ .worktree_remove = try gpa.dupe(u8, detail) }, try std.fmt.allocPrint(gpa, "Remove worktree {s}?", .{detail})),
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

/// The graph paints its detail column — the commit box with it — from
/// eighty cells (`git_graph_view.draw`); narrower, the box is nowhere
/// to be typed into. Judged by the active repo's graph when it has been
/// painted, else by the active pane's width.
pub fn graphPaintsBox(app: *App) bool {
    const repo = app.git.activeRepo() orelse return false;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .git_graph => |*g| if (g.repo == repo.id and g.body.w > 0) return g.body.w >= 80,
        else => {},
    };
    return activePaneWidth(app) >= 80;
}

/// The active pane's painted width at the last render — the git panes
/// keep their own rect; the rest is the editor's column count.
fn activePaneWidth(app: *App) usize {
    const id = app.active orelse return app.pane_cols;
    const p = app.panes.get(id) orelse return app.pane_cols;
    return switch (p.*) {
        .git_graph => |*g| if (g.body.w > 0) g.body.w else app.pane_cols,
        .diff => |*d| if (d.body.w > 0) d.body.w else app.pane_cols,
        else => app.pane_cols,
    };
}

/// Rust `open_commit_prompt`'s title: what is staged, or that nothing is.
pub fn commitPromptTitle(app: *App) []const u8 {
    const staged: u32 = if (app.git.status) |st| st.staged else 0;
    if (staged == 0) return "Commit message (nothing staged \u{2014} stage hunks first)";
    return std.fmt.bufPrint(&app.git.commit_title, "Commit message ({d} staged)", .{staged}) catch "Commit message";
}

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

/// `openPrompt` with a title built for this open — the overlay owns it
/// and frees it on close. A title on the frame arena would read as
/// garbage on the next frame (the prompt outlives it).
pub fn openPromptOwned(app: *App, kind: PromptKind, title: []const u8) Allocator.Error!void {
    const owned = try app.gpa.dupe(u8, title);
    openPrompt(app, kind, owned);
    app.overlay.prompt.title_owned = owned;
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
        .plan_reword => {
            const g = activeGraph(app) orelse return;
            const plan = if (g.plan) |*p| p else return;
            if (plan.cursor >= plan.rows.items.len) return;
            const row = &plan.rows.items[plan.cursor];
            if (row.message) |m| gpa.free(m);
            row.message = if (text.len == 0) null else try gpa.dupe(u8, text_in);
            row.action = if (row.message != null) .reword else .pick;
            app.needs_render = true;
        },
        .reword => {
            if (text.len == 0) return app.diag.fail(app.frame.allocator(), "reword: empty message", .{});
            const g = activeGraph(app) orelse return app.diag.fail(app.frame.allocator(), "graph: no graph pane is active", .{});
            try directVerb(app, g, .reword, text_in);
        },
        .reset_soft, .reset_mixed, .reset_hard => {
            if (text.len == 0) return;
            const mode: client.ResetMode = switch (kind) {
                .reset_soft => .soft,
                .reset_mixed => .mixed,
                else => .hard,
            };
            try resetTo(app, mode, text);
        },
        .graph_hash => {
            const g = activeGraph(app) orelse return app.diag.fail(app.frame.allocator(), "graph: no graph pane is active", .{});
            if (text.len == 0) return;
            const idx = graph_view.findByHashPrefix(g.commits, text) orelse return app.diag.fail(app.frame.allocator(), "no commit starts with {s}", .{text});
            g.cursor = g.rowOfCommit(idx);
            if (!g.wipSelected()) requestDetail(app, g) catch {};
            app.needs_render = true;
        },
        .stash => {
            const v = st.stash_variant;
            st.stash_variant = .{};
            var push: client.StashPush = .{ .staged_only = v.staged_only, .keep_index = v.keep_index };
            if (v.path) |p| {
                const ps = gpa.alloc([]u8, 1) catch |err| {
                    gpa.free(p);
                    return err;
                };
                ps[0] = p;
                push.paths = ps;
            }
            errdefer push.deinit(gpa);
            if (text.len > 0) push.msg = try gpa.dupe(u8, text);
            try submitOp(app, try requireRepo(app), .{ .stash = push });
        },
        .stash_branch => {
            if (text.len == 0) return;
            const ref = st.verb_branch orelse return app.diag.fail(app.frame.allocator(), "stash branch: the stash is gone", .{});
            try submitOp(app, try requireRepo(app), .{ .stash_branch = .{ .ref = try gpa.dupe(u8, ref), .name = try gpa.dupe(u8, text) } });
        },
        .stash_rename => {
            if (text.len == 0) return;
            const ref = st.verb_branch orelse return app.diag.fail(app.frame.allocator(), "stash rename: the stash is gone", .{});
            try submitOp(app, try requireRepo(app), .{ .stash_rename = .{ .ref = try gpa.dupe(u8, ref), .msg = try gpa.dupe(u8, text) } });
        },
        .worktree_lock => {
            // The reason is optional: an empty box locks the tree plain.
            const path = st.verb_branch orelse return app.diag.fail(app.frame.allocator(), "lock worktree: the tree is gone", .{});
            const p_owned = try gpa.dupe(u8, path);
            errdefer gpa.free(p_owned);
            try submitOp(app, try requireRepo(app), .{ .worktree_lock = .{ .path = p_owned, .reason = try gpa.dupe(u8, text) } });
        },
        .new_branch => {
            if (text.len == 0) return;
            const start: ?[]u8 = if (takeVerbStart(app)) |s| s else null;
            errdefer if (start) |s| gpa.free(s);
            try submitOp(app, try requireRepo(app), .{ .new_branch = .{ .name = try gpa.dupe(u8, text), .start = start } });
        },
        .branch_rename => {
            if (text.len == 0) return;
            const from = st.verb_branch orelse return app.diag.fail(app.frame.allocator(), "rename: the branch is gone", .{});
            if (std.mem.eql(u8, from, text)) return;
            try submitOp(app, try requireRepo(app), .{ .branch_rename = .{ .from = try gpa.dupe(u8, from), .to = try gpa.dupe(u8, text) } });
        },
        .tag => {
            if (text.len == 0) return;
            try submitOp(app, try requireRepo(app), .{ .tag = try gpa.dupe(u8, text) });
        },
        .tag_at, .tag_annotated_at => {
            if (text.len == 0) return;
            const start = takeVerbStart(app) orelse return app.diag.fail(app.frame.allocator(), "tag: the row is gone", .{});
            errdefer gpa.free(start);
            try submitOp(app, try requireRepo(app), .{ .tag_at = .{ .name = try gpa.dupe(u8, text), .start = start, .annotated = kind == .tag_annotated_at } });
        },
        .worktree_add => {
            if (text.len == 0) return;
            // `<path> [branch]`
            var it = std.mem.tokenizeScalar(u8, text, ' ');
            const path = it.next() orelse return;
            const branch = it.next();
            const start: ?[]u8 = if (takeVerbStart(app)) |s| s else null;
            errdefer if (start) |s| gpa.free(s);
            try submitOp(app, try requireRepo(app), .{ .worktree_add = .{ .path = try gpa.dupe(u8, path), .branch = if (branch) |b| try gpa.dupe(u8, b) else null, .start = start } });
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

/// // changed (git-menus): a confirm whose choices are not yes / no —
/// *Remove worktree and delete branch*'s Remove / Force / Cancel. Takes
/// `payload` and `message` the same way; `choices` is a static.
pub fn openConfirmWith(app: *App, payload: Confirm, title: []const u8, message: []u8, choices: []const app_mod.Confirm.Choice) Allocator.Error!void {
    const st = &app.git;
    st.confirm.deinit(app.gpa);
    st.confirm = payload;
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = title, .message = message, .choices = choices },
        .purpose = .git,
        .message = message,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const remove_branch_choices = [_]app_mod.Confirm.Choice{
    .{ .key = 'r', .label = "Remove" },
    .{ .key = 'f', .label = "Force" },
    .{ .key = 'c', .label = "Cancel" },
};

pub fn acceptConfirm(app: *App, choice: usize) CommandError!void {
    const st = &app.git;
    const gpa = app.gpa;
    const payload = st.confirm;
    st.confirm = .none;
    defer payload.deinit(gpa);
    // git-menus: the only three-way confirm — Remove (0), Force (1),
    // Cancel (2). A dirty tree is refused unless Force was taken.
    if (payload == .worktree_remove_branch) {
        const w = payload.worktree_remove_branch;
        if (choice > 1) return;
        const force = choice == 1;
        if (!force and w.dirty_files > 0) return app.diag.fail(app.frame.allocator(), "remove worktree: {s} has {d} uncommitted file{s} \u{2014} pick Force to throw {s} away", .{ w.path, w.dirty_files, if (w.dirty_files == 1) "" else "s", if (w.dirty_files == 1) "it" else "them" });
        const path = try gpa.dupe(u8, w.path);
        errdefer gpa.free(path);
        const branch = try gpa.dupe(u8, w.branch);
        errdefer gpa.free(branch);
        return submitOp(app, try requireRepo(app), .{ .worktree_remove_branch = .{ .path = path, .branch = branch, .force = force } });
    }
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
        .reset_hard => |rev| try submitOp(app, try requireRepo(app), .{ .reset = .{ .mode = .hard, .rev = try gpa.dupe(u8, rev) } }),
        .checkout_force => |b| try submitOp(app, try requireRepo(app), .{ .checkout_force = try gpa.dupe(u8, b) }),
        .delete_remote => |d| {
            const remote = try gpa.dupe(u8, d.remote);
            errdefer gpa.free(remote);
            try submitOp(app, try requireRepo(app), .{ .delete_remote = .{ .remote = remote, .branch = try gpa.dupe(u8, d.branch) } });
        },
        .push_force => {
            app.toast("pushing (--force-with-lease)\u{2026}", .{});
            try submitOp(app, try requireRepo(app), .push_force);
        },
        // Handled above: its choices are not yes / no.
        .worktree_remove_branch => unreachable,
    }
}

// ─── stash depth (git-more2) ────────────────────────────────────────────

/// The stash prompt with a variant: the index only, one file, or the
/// tree with the index kept.
pub fn stashWith(app: *App, v: StashVariant, title: []const u8) CommandError!void {
    _ = try requireRepo(app);
    if (app.git.stash_variant.path) |p| app.gpa.free(p);
    app.git.stash_variant = v;
    openPrompt(app, .stash, title);
}

/// Enter on a STASHES row: its files in a list pane.
pub fn stashShow(app: *App, ref: []const u8) CommandError!void {
    const repo = try requireRepo(app);
    try submit(app, repo, .{ .stash_show = try app.gpa.dupe(u8, ref) });
}

/// The files pane's header: `stash@{0} · On main: note`.
pub fn stashViewTitle(app: *App) []const u8 {
    const v = app.git.stash_view orelse return "stash";
    return std.fmt.allocPrint(app.frame.allocator(), "{s} \u{B7} {s}", .{ v.ref, v.message }) catch v.ref;
}

/// Enter on a stash file: the file's diff against the stash's parent
/// (`ref^..ref`), the same range diff the graph's base uses.
pub fn stashFileEnter(app: *App, e: app_mod.ListPane.Entry) CommandError!void {
    const arena = app.frame.allocator();
    const v = app.git.stash_view orelse return app.diag.fail(arena, "stash: no stash is shown", .{});
    const repo = app.git.repoById(v.repo) orelse return error.NoRepo;
    const path = e.path orelse return;
    const rev = try std.fmt.allocPrint(arena, "{s}^..{s}", .{ v.ref, v.ref });
    _ = try openDiff(app, repo, .range, path, rev, null);
}

/// `Branch from stash…`: the name, then `stash branch`.
pub fn stashBranchPrompt(app: *App, ref: []const u8) CommandError!void {
    _ = try requireRepo(app);
    try setVerbBranch(app, ref);
    openPrompt(app, .stash_branch, "Branch from the stash: the new branch's name");
}

/// `Rename…`: the prompt opens with the stash's note (its message
/// without the `On <branch>: ` half, which the rename keeps).
pub fn stashRenamePrompt(app: *App, ref: []const u8, message: []const u8) CommandError!void {
    _ = try requireRepo(app);
    try setVerbBranch(app, ref);
    openPrompt(app, .stash_rename, "Rename the stash");
    try app.overlay.prompt.state.setText(app.gpa, parse.stashNote(message));
}

/// The command log (item 10) fills this in; a stash file row has no
/// second verb, so the menu offers the copy every list row has.
pub fn openListRowMenu(app: *App, l: *app_mod.ListPane, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const e = (try l.entryAt(arena, l.cursor)) orelse return;
    const text: []const u8 = try arena.dupe(u8, if (e.path) |p| p else e.text);
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    switch (l.kind) {
        .stash_files => try items.append(app.gpa, .{ .label = "Diff this file (Enter)", .action = .{ .command = .@"git.stash_show_diff" } }),
        .git_log => {
            const can = if (logEntryOf(app, e.*)) |le| client.isReadOnly(le.args) else false;
            try items.append(app.gpa, .{ .label = if (can) "Re-run (Enter)" else "Re-run (Enter) \u{2014} writes, not offered", .action = .{ .command = .@"git.command_log_rerun" } });
            const cmd = try arena.dupe(u8, logCommand(app, e.*) orelse text);
            try items.append(app.gpa, .{ .label = "Copy the command", .action = .{ .copy_text = cmd } });
            const rows = try items.toOwnedSlice(app.gpa);
            errdefer app.gpa.free(rows);
            try context_menus.openOwned(app, l.title(), rows, x, y, mem);
            return;
        },
        else => {},
    }
    try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Copy ({s})", .{text[0..@min(text.len, 40)]}), .action = .{ .copy_text = text } });
    const rows = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(rows);
    try context_menus.openOwned(app, l.title(), rows, x, y, mem);
}

// ─── the command log (git-more2) ────────────────────────────────────────

/// `msg` cut to `max` characters with an ellipsis, on a UTF-8 edge.
fn clipReason(msg: []const u8, max: usize) []const u8 {
    if (max < 4 or msg.len <= max) return msg;
    var end = max - 1;
    while (end > 0 and (msg[end] & 0xC0) == 0x80) end -= 1;
    return msg[0..end];
}

fn logEntryText(arena: Allocator, e: LogEntry) Allocator.Error![]u8 {
    const mark: []const u8 = if (e.ok) "\u{2713}" else "\u{2717}";
    if (e.stderr.len > 0 and !e.ok) return std.fmt.allocPrint(arena, "{s} {d: >5}ms  {s}  \u{2014} {s}", .{ mark, e.ms, e.argv, e.stderr });
    if (e.exit != null and e.exit.? != 0) return std.fmt.allocPrint(arena, "{s} {d: >5}ms  {s}  \u{2014} exit {d}", .{ mark, e.ms, e.argv, e.exit.? });
    return std.fmt.allocPrint(arena, "{s} {d: >5}ms  {s}", .{ mark, e.ms, e.argv });
}

/// The log pane's rows, newest first; `line` carries the entry's seq.
fn logEntries(app: *App) Allocator.Error![]app_mod.ListPane.Entry {
    const gpa = app.gpa;
    var entries: std.ArrayListUnmanaged(app_mod.ListPane.Entry) = .empty;
    errdefer {
        app_mod.ListPane.freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }
    const items = app.git.log.items.items;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        try entries.append(gpa, .{ .text = try logEntryText(gpa, items[i]), .line = items[i].seq });
    }
    return entries.toOwnedSlice(gpa);
}

/// `git.command_log`: the pane, newest first, the cursor on `at`'s
/// row (the failed-op toast's entry) or the newest.
pub fn openCommandLog(app: *App, at: ?u32) CommandError!void {
    try cmd_view.openListPane(app, .git_log, try logEntries(app));
    try refillLogPane(app, at orelse app.git.log_link_seq);
    app.git.log_link_seq = null;
}

/// An open log pane takes the ring as it is now; the cursor stays on
/// its entry (or lands on `at`).
pub fn refillLogPane(app: *App, at: ?u32) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .list => |*l| if (l.kind == .git_log) {
            const arena = app.frame.allocator();
            const keep: ?u32 = at orelse (if (try l.entryAt(arena, l.cursor)) |e| e.line else null);
            const fresh = try logEntries(app);
            app_mod.ListPane.freeEntries(l.gpa, l.entries.items);
            l.entries.deinit(l.gpa);
            l.entries = .fromOwnedSlice(fresh);
            l.cursor = 0;
            if (keep) |seq| {
                for (try l.shown(arena), 0..) |ei, row| if (l.entries.items[ei].line == seq) {
                    l.cursor = row;
                    break;
                };
            }
            app.needs_render = true;
            return;
        },
        else => {},
    };
}

/// The entry a log row names.
pub fn logEntryOf(app: *App, e: app_mod.ListPane.Entry) ?*const LogEntry {
    return app.git.log.find(e.line);
}

/// `y` on a log row: the command line, not the row's decoration.
pub fn logCommand(app: *App, e: app_mod.ListPane.Entry) ?[]const u8 {
    const le = logEntryOf(app, e) orelse return null;
    return le.argv;
}

/// Enter on a command-log row: the read-only commands run again
/// through the same worker; a writing one says why not.
pub fn logEnter(app: *App, e: app_mod.ListPane.Entry) CommandError!void {
    const arena = app.frame.allocator();
    const le = logEntryOf(app, e) orelse return app.diag.fail(arena, "command log: that entry is gone", .{});
    if (le.args.len == 0) return app.diag.fail(arena, "command log: not a git command \u{2014} nothing to re-run", .{});
    if (!client.isReadOnly(le.args)) return app.diag.fail(arena, "command log: `git {s}` writes \u{2014} run it from the palette, not the log", .{le.args[0]});
    const repo = app.git.repoById(le.repo) orelse return error.NoRepo;
    const gpa = app.gpa;
    const argv = try gpa.alloc([]u8, le.args.len);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |a| gpa.free(a);
        gpa.free(argv);
    }
    for (le.args) |a| {
        argv[filled] = try gpa.dupe(u8, a);
        filled += 1;
    }
    try submitOp(app, repo, .{ .rerun = argv });
}

// ─── the branch verbs (git-more2) ───────────────────────────────────────

/// A WORKTREES row's *Lock worktree…* (git-menus): the reason box, whose
/// accept locks the tree (an empty box locks it plain). A locked tree
/// refuses `worktree remove` and `worktree prune`, and the panel paints
/// the lock the porcelain reports.
pub fn lockWorktreePrompt(app: *App, path: []const u8, label: []const u8) CommandError!void {
    _ = try requireRepo(app);
    try setVerbBranch(app, path);
    try openPromptOwned(app, .worktree_lock, try std.fmt.allocPrint(app.frame.allocator(), "Lock {s} \u{2014} a reason (optional)", .{label}));
}

/// *Unlock worktree*: no prompt, nothing to lose.
pub fn unlockWorktree(app: *App, path: []const u8) CommandError!void {
    const repo = try requireRepo(app);
    try submitOp(app, repo, .{ .worktree_unlock = try app.gpa.dupe(u8, path) });
}

fn setVerbBranch(app: *App, name: []const u8) Allocator.Error!void {
    if (app.git.verb_branch) |b| app.gpa.free(b);
    app.git.verb_branch = try app.gpa.dupe(u8, name);
}

fn setVerbStart(app: *App, rev: []const u8) Allocator.Error!void {
    if (app.git.verb_start) |s| app.gpa.free(s);
    app.git.verb_start = try app.gpa.dupe(u8, rev);
}

/// The start a new-branch / worktree prompt was opened with, taken
/// (the prompt's accept owns it from here).
fn takeVerbStart(app: *App) ?[]u8 {
    const s = app.git.verb_start orelse return null;
    app.git.verb_start = null;
    return s;
}

/// The rail's entry for `name`, local or remote.
fn railBranch(app: *App, name: []const u8) ?parse.Branch {
    for (app.git.rail_branches) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

/// `Rename…`: the prompt opens with the old name.
pub fn branchRename(app: *App, name: []const u8) CommandError!void {
    try setVerbBranch(app, name);
    openPrompt(app, .branch_rename, "Rename branch");
    try app.overlay.prompt.state.setText(app.gpa, name);
}

/// Fast-forward `name` to its upstream — `merge --ff-only` when it is
/// checked out, `fetch remote ref:name` otherwise. The upstream comes
/// off the rail (`for-each-ref`'s `%(upstream)`), so the rail must have
/// loaded; a branch without one says so.
pub fn fastForward(app: *App, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const repo = try requireRepo(app);
    const b = railBranch(app, name) orelse return app.diag.fail(arena, "fast-forward: `{s}` is not in the branches panel (open it, or refresh)", .{name});
    if (b.upstream.len == 0) return app.diag.fail(arena, "fast-forward: {s} has no upstream \u{2014} set one first", .{name});
    const gpa = app.gpa;
    const branch = try gpa.dupe(u8, name);
    errdefer gpa.free(branch);
    try submitOp(app, repo, .{ .fast_forward = .{ .branch = branch, .upstream = try gpa.dupe(u8, b.upstream), .checked_out = b.current } });
}

/// `Set upstream…`: a picker of the remote branches.
pub fn setUpstream(app: *App, name: []const u8) CommandError!void {
    const repo = try requireRepo(app);
    try setVerbBranch(app, name);
    try askBranches(app, repo, .set_upstream);
}

/// `Force checkout…`: a confirm that says what goes.
pub fn checkoutForce(app: *App, name: []const u8) CommandError!void {
    const gpa = app.gpa;
    try openConfirm(app, .{ .checkout_force = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "Force checkout {s}? Uncommitted changes in the tree are discarded (git checkout -f; undo restores them)", .{name}));
}

/// `Delete on the remote…`: `remote/name` splits into the two; a local
/// branch deletes its upstream's ref (or `origin/<name>` without one).
pub fn deleteRemote(app: *App, name: []const u8, remote_hint: ?[]const u8) CommandError!void {
    const gpa = app.gpa;
    var remote: []const u8 = remote_hint orelse "origin";
    var branch: []const u8 = name;
    if (railBranch(app, name)) |b| {
        if (b.remote) {
            if (std.mem.indexOfScalar(u8, name, '/')) |s| {
                remote = name[0..s];
                branch = name[s + 1 ..];
            }
        } else if (b.upstream.len > 0) {
            if (std.mem.indexOfScalar(u8, b.upstream, '/')) |s| {
                remote = b.upstream[0..s];
                branch = b.upstream[s + 1 ..];
            }
        }
    } else if (std.mem.indexOfScalar(u8, name, '/')) |s| {
        remote = name[0..s];
        branch = name[s + 1 ..];
    }
    const r = try gpa.dupe(u8, remote);
    errdefer gpa.free(r);
    const b = try gpa.dupe(u8, branch);
    errdefer gpa.free(b);
    try openConfirm(app, .{ .delete_remote = .{ .remote = r, .branch = b } }, try std.fmt.allocPrint(gpa, "Delete {s}/{s} on the remote? (git push {s} --delete {s})", .{ remote, branch, remote, branch }));
}

/// `New branch from here…`: the prompt, the start kept for its accept.
pub fn newBranchFrom(app: *App, start: []const u8) CommandError!void {
    _ = try requireRepo(app);
    try setVerbStart(app, start);
    // The prompt borrows its title for as long as it is open: a static one.
    openPrompt(app, .new_branch, if (std.mem.eql(u8, start, "HEAD")) "New branch" else "New branch from the selected commit / ref");
}

/// `New worktree from here…`: as `git.worktree_add`, starting at `start`.
pub fn worktreeFrom(app: *App, start: []const u8) CommandError!void {
    _ = try requireRepo(app);
    try setVerbStart(app, start);
    openPrompt(app, .worktree_add, if (std.mem.eql(u8, start, "HEAD")) "Worktree: <path> [new-branch]" else "Worktree from the selected commit / ref: <path> [new-branch]");
}

/// `Create tag here…` / `Create annotated tag here…` on a branches
/// panel row: the prompt for the name, the row's ref kept for its
/// accept (git-panel).
pub fn tagAt(app: *App, start: []const u8, annotated: bool) CommandError!void {
    _ = try requireRepo(app);
    try setVerbStart(app, start);
    openPrompt(app, if (annotated) .tag_annotated_at else .tag_at, if (annotated) "Annotated tag on the selected ref (the name is the message)" else "Tag on the selected ref");
}

/// `Push` on a branch that is not checked out: `push -u <remote>
/// <branch>` — its upstream's remote, else the first remote (git-panel).
/// The checked-out branch takes `git.push`.
pub fn pushBranch(app: *App, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const repo = try requireRepo(app);
    var remote: []const u8 = "";
    if (railBranch(app, name)) |b| if (b.upstream.len > 0) if (std.mem.indexOfScalar(u8, b.upstream, '/')) |sl| {
        remote = b.upstream[0..sl];
    };
    if (remote.len == 0 and app.git.rail_remotes.len > 0) remote = app.git.rail_remotes[0].name;
    if (remote.len == 0) return app.diag.fail(arena, "push {s}: no remote \u{2014} add one first", .{name});
    const gpa = app.gpa;
    const r = try gpa.dupe(u8, remote);
    errdefer gpa.free(r);
    app.toast("pushing {s} to {s}\u{2026}", .{ name, remote });
    try submitOp(app, repo, .{ .push_branch = .{ .remote = r, .branch = try gpa.dupe(u8, name) } });
}

/// `git.push_start_pr` (git-menus): the branch goes up (`push -u`, never
/// a force), and when the remote's host has a new-pull-request page the
/// push's success opens it in the browser. A host with no shape on file
/// is pushed and said — never sent to a guessed URL.
pub const PrTarget = struct { remote: []const u8, url: []const u8 };

/// Which remote *Push and start PR* pushes to, and the forge's new-PR
/// page it opens after — both read off the rail. `url` is empty when
/// the remote's host has no shape on file (`git/remote.zig`), and the
/// verb then pushes and says so rather than guessing one. Allocates on
/// `arena`.
pub fn prTarget(app: *App, arena: Allocator, name: []const u8) CommandError!PrTarget {
    const b = railBranch(app, name);
    if (b) |br| if (br.remote) return app.diag.fail(arena, "push and start PR: {s} is a remote branch \u{2014} start from the local one", .{name});
    var remote: []const u8 = "";
    if (b) |br| if (br.upstream.len > 0) if (std.mem.indexOfScalar(u8, br.upstream, '/')) |sl| {
        remote = br.upstream[0..sl];
    };
    if (remote.len == 0 and app.git.rail_remotes.len > 0) remote = app.git.rail_remotes[0].name;
    if (remote.len == 0) return app.diag.fail(arena, "push and start PR: {s} has no remote \u{2014} add one first", .{name});
    var url: []const u8 = "";
    for (app.git.rail_remotes) |r| if (std.mem.eql(u8, r.name, remote)) {
        url = (try remote_mod.newPrUrl(arena, r.url, name)) orelse "";
    };
    return .{ .remote = remote, .url = url };
}

pub fn pushStartPr(app: *App, name: []const u8) CommandError!void {
    const gpa = app.gpa;
    const repo = try requireRepo(app);
    const t = try prTarget(app, app.frame.allocator(), name);
    const r_owned = try gpa.dupe(u8, t.remote);
    errdefer gpa.free(r_owned);
    const b_owned = try gpa.dupe(u8, name);
    errdefer gpa.free(b_owned);
    const u_owned = try gpa.dupe(u8, t.url);
    errdefer gpa.free(u_owned);
    if (t.url.len == 0) {
        app.toast("pushing {s} to {s}\u{2026} (no new-PR page for that host \u{2014} open it yourself)", .{ name, t.remote });
    } else {
        app.toast("pushing {s} to {s}, then the new PR page\u{2026}", .{ name, t.remote });
    }
    try submitOp(app, repo, .{ .push_start_pr = .{ .remote = r_owned, .branch = b_owned, .url = u_owned } });
}

/// `Push --force-with-lease…`: the confirm names the risk. Rust refused
/// a force push outright; this is the deliberate change — the lease
/// refuses when the remote moved past the last fetch, and the text
/// says what a yes rewrites.
pub fn pushForce(app: *App) CommandError!void {
    _ = try requireRepo(app);
    const branch = app.git.branchLabel() orelse "HEAD";
    try openConfirm(app, .push_force, try std.fmt.allocPrint(app.gpa, "Push {s} with --force-with-lease? The remote branch is rewritten to match this one; commits only the remote has since your last fetch would be lost (git refuses if it moved past that fetch)", .{branch}));
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
        .discard => try openConfirm(app, .{ .discard = try gpa.dupe(u8, row.path) }, try std.fmt.allocPrint(gpa, "Discard changes to {s}? This cannot be undone.", .{row.path})),
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
    _ = id;
    leaveToTree(app);
}

/// Esc's way out of a git pane: the keys go to the tree when it is
/// shown, and stay on the pane otherwise. A pane never closes on Esc —
/// `q` and the tab's × do that.
fn leaveToTree(app: *App) void {
    if (!app.tree.visible) return;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
}

test "esc never closes a git pane: the graph, the diff and the status pane keep their tabs, with the tree shown or hidden" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "initial" });
    const app = &f.app;
    try discover(app);
    try command.run(app, .{ .static = .@"git.graph" });
    const graph_id = app.active.?;
    const before = app.panes.count();
    // Tree shown: Esc hands the keys to the column, the tab stays.
    app.tree.visible = true;
    app.setActive(graph_id);
    app.focus = .{ .pane = graph_id };
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expectEqual(before, app.panes.count());
    try testing.expect(app.layouts.current().leafOf(graph_id) != null);
    // The keys left the pane (in git mode the column is the branches
    // panel, so the focus is a panel, not the file tree).
    try testing.expect(app.focus != .pane);
    // Tree hidden: Esc is a no-op on the pane, still no close.
    app.tree.visible = false;
    app.setActive(graph_id);
    app.focus = .{ .pane = graph_id };
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expectEqual(before, app.panes.count());
    try testing.expect(app.layouts.current().leafOf(graph_id) != null);
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
            // Esc leaves states, never the pane: a selection, then the
            // filter, then the keys go back to the tree (the tab stays —
            // it used to close, and one Esc per pane emptied a strip).
            if (dp.anchor != null) {
                dp.anchor = null;
            } else if (dp.filter.items.len > 0) {
                dp.filter.clearRetainingCapacity();
                try refilterDiff(app, dp);
            } else leaveToTree(app);
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
    if (g.plan != null) return planKey(app, g, k);
    if (g.hash_filter_mode) return hashFilterKey(app, g, k);
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
        .esc => {
            // A selection in progress goes first; then the keys go back
            // to the tree. The pane stays: `q` closes it.
            if (g.anchor != null or g.marks.count() > 0) g.clearSelection() else leaveToTree(app);
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => moveGraphCursor(app, g, g.cursor + 1),
                'k' => moveGraphCursor(app, g, g.cursor -| 1),
                'g' => moveGraphCursor(app, g, 0),
                'G' => moveGraphCursor(app, g, n -| 1),
                'd' => runToast(app, diffSelected(app, g)),
                'W' => runToast(app, toggleCompareBase(app, g)),
                's' => try setSort(app, g, .{ .col = g.sort.col.next(), .asc = false }),
                '/' => {
                    g.hash_filter_mode = true;
                    g.hash_filter_len = 0;
                },
                'a' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.stage_all" })) else return false,
                'A' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.amend" })) else runToast(app, command.run(app, .{ .static = .@"git.amend_to" })),
                'U' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.unstage_all" })) else return false,
                'c' => if (g.wipSelected()) runToast(app, commitFromTextarea(app, g)) else runToast(app, command.run(app, .{ .static = .@"git.cherry_pick" })),
                'C' => if (g.wipSelected()) runToast(app, command.run(app, .{ .static = .@"git.ai_commit" })) else return false,
                'V' => runToast(app, command.run(app, .{ .static = .@"git.revert" })),
                'f' => runToast(app, command.run(app, .{ .static = .@"git.graph_filter_branch" })),
                'F' => runToast(app, command.run(app, .{ .static = .@"git.graph_filter_reset_all" })),
                'R' => runToast(app, refreshGraph(app, g)),
                'q' => try app.closePane(id, true),
                // Multi-select and the plan.
                ' ' => try toggleMark(app, g),
                'v' => {
                    if (g.wipSelected()) return false;
                    if (g.anchor != null) try g.commitRange() else g.anchor = g.cursor;
                },
                '*' => runToast(app, command.run(app, .{ .static = .@"git.select_branch" })),
                'r' => runToast(app, command.run(app, .{ .static = .@"git.rebase_plan" })),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// The header chip has the keys (Rust's `hash_filter_mode`): a hex digit
/// joins the prefix and jumps to the first commit it names — none
/// toasts; Backspace drops one and jumps again; Enter keeps the place
/// and leaves; Esc clears and leaves. Everything else is swallowed.
fn hashFilterKey(app: *App, g: *GraphPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => {
            g.hash_filter_len = 0;
            g.hash_filter_mode = false;
        },
        .enter => g.hash_filter_mode = false,
        .backspace => {
            g.hash_filter_len -|= 1;
            if (g.hash_filter_len > 0) _ = jumpToHashPrefix(app, g);
        },
        .char => |c| if (c < 128 and std.ascii.isHex(@intCast(c)) and !k.mods.ctrl and !k.mods.alt and !k.mods.super) {
            if (g.hash_filter_len < g.hash_filter.len) {
                g.hash_filter[g.hash_filter_len] = std.ascii.toLower(@intCast(c));
                g.hash_filter_len += 1;
            }
            if (!jumpToHashPrefix(app, g)) app.toast("no commit ~ {s}", .{g.hashFilter()});
        },
        else => {},
    }
    app.needs_render = true;
    return true;
}

/// The cursor to the first commit the typed prefix names; false when none.
fn jumpToHashPrefix(app: *App, g: *GraphPane) bool {
    const idx = graph_view.findByHashPrefix(g.commits, g.hashFilter()) orelse return false;
    g.cursor = g.rowOfCommit(idx);
    if (!g.wipSelected()) requestDetail(app, g) catch {};
    return true;
}

/// Space: the cursor's commit in or out of the selection (a range in
/// progress is folded in first).
fn toggleMark(app: *App, g: *GraphPane) Allocator.Error!void {
    _ = app;
    if (g.anchor != null) return g.commitRange();
    const ci: u32 = @intCast(g.selectedIndex() orelse return);
    if (g.marks.remove(ci)) return;
    try g.marks.put(g.gpa, ci, {});
}

/// The plan modal has the keys: `↑↓` / `j k` walk the rows, `←→` /
/// `h l` cycle the action, `p r e s f d` set it (`r` asks for the
/// message), `J` / `K` (or alt+`↑↓`) move the row, Enter runs, Esc
/// cancels.
fn planKey(app: *App, g: *GraphPane, k: Key) Allocator.Error!bool {
    const plan = &g.plan.?;
    const n = plan.rows.items.len;
    app.needs_render = true;
    switch (k.code) {
        .esc => g.closePlan(),
        .enter => runToast(app, runPlan(app, g)),
        .up => if (k.mods.alt) movePlanRow(plan, false) else {
            plan.cursor -|= 1;
        },
        .down => if (k.mods.alt) movePlanRow(plan, true) else {
            plan.cursor = @min(plan.cursor + 1, n -| 1);
        },
        .left => cyclePlanAction(plan, false),
        .right => cyclePlanAction(plan, true),
        .home => plan.cursor = 0,
        .end => plan.cursor = n -| 1,
        .char => |c| {
            if (k.mods.ctrl or k.mods.super) return true;
            switch (c) {
                'j' => plan.cursor = @min(plan.cursor + 1, n -| 1),
                'k' => plan.cursor -|= 1,
                'h' => cyclePlanAction(plan, false),
                'l' => cyclePlanAction(plan, true),
                'J' => movePlanRow(plan, true),
                'K' => movePlanRow(plan, false),
                'r' => {
                    if (plan.cursor < n) openPrompt(app, .plan_reword, "Reword: the new commit message");
                },
                'p', 'e', 's', 'f', 'd' => if (plan.cursor < n) {
                    const row = &plan.rows.items[plan.cursor];
                    row.action = parse.TodoAction.fromLetter(@intCast(c)).?;
                    if (row.message) |m| app.gpa.free(m);
                    row.message = null;
                },
                'q' => g.closePlan(),
                else => {},
            }
        },
        else => {},
    }
    return true;
}

fn cyclePlanAction(plan: *Plan, forward: bool) void {
    if (plan.cursor >= plan.rows.items.len) return;
    const row = &plan.rows.items[plan.cursor];
    row.action = if (forward) row.action.next() else row.action.prev();
}

/// Swap the cursor's row with its neighbour, the cursor following.
fn movePlanRow(plan: *Plan, down: bool) void {
    const n = plan.rows.items.len;
    if (n < 2 or plan.cursor >= n) return;
    const to = if (down) plan.cursor + 1 else plan.cursor -| 1;
    if (to == plan.cursor or to >= n) return;
    std.mem.swap(PlanRow, &plan.rows.items[plan.cursor], &plan.rows.items[to]);
    plan.cursor = to;
}

// ─── the rebase plan ────────────────────────────────────────────────────

/// The commit HEAD points at, by the last status's oid, else the row
/// whose refs carry `HEAD`.
fn headIndex(app: *App, g: *const GraphPane) ?usize {
    const st = &app.git;
    if (st.status_repo == g.repo) if (st.status) |s| if (s.oid) |oid| {
        for (g.commits, 0..) |c, i| if (std.mem.eql(u8, c.hash, oid)) return i;
    };
    for (g.commits, 0..) |c, i| {
        if (std.mem.startsWith(u8, c.refs, "HEAD") and (c.refs.len == 4 or c.refs[4] == ' ' or c.refs[4] == ',')) return i;
    }
    return null;
}

/// The index of the commit `sha` names, when the graph has it.
fn indexOfSha(g: *const GraphPane, sha: []const u8) ?usize {
    for (g.commits, 0..) |c, i| if (std.mem.eql(u8, c.hash, sha)) return i;
    return null;
}

/// The commits on HEAD's first-parent line, as a set over the commit
/// indices (on the frame arena).
fn firstParentLine(app: *App, g: *GraphPane) Allocator.Error![]bool {
    const on = try app.frame.allocator().alloc(bool, g.commits.len);
    @memset(on, false);
    var at = headIndex(app, g) orelse return on;
    while (true) {
        on[at] = true;
        const c = g.commits[at];
        if (c.parents.len == 0) break;
        at = indexOfSha(g, c.parents[0]) orelse break;
    }
    return on;
}

/// The commits the user selected: the marks with any range folded in,
/// else the cursor's commit. On the frame arena, in graph order.
///
/// A `v` range is the first-parent line between its ends: a side
/// branch's row drawn between two of ours is not part of it. A mark
/// set by hand on such a row stays, and the plan refuses it.
fn selection(app: *App, g: *GraphPane) Allocator.Error![]const usize {
    if (g.range()) |rg| {
        const on = try firstParentLine(app, g);
        var v = @min(rg[0], rg[1]);
        while (v <= @max(rg[0], rg[1])) : (v += 1) {
            if (v < g.wipRows()) continue;
            const pos = v - g.wipRows();
            if (pos >= g.order.len) break;
            const ci = g.order[pos];
            if (on[ci]) try g.marks.put(g.gpa, ci, {});
        }
        g.anchor = null;
    }
    var out: std.ArrayListUnmanaged(usize) = .empty;
    const arena = app.frame.allocator();
    if (g.marks.count() == 0) {
        if (g.selectedIndex()) |ci| try out.append(arena, ci);
        return out.items;
    }
    for (g.order) |ci| if (g.isMarked(ci)) try out.append(arena, ci);
    return out.items;
}

/// `*`: the current branch's commits since its upstream — HEAD down the
/// first-parent line to the upstream's commit (or `ahead` steps); the
/// whole line when there is no upstream.
pub fn selectBranchCommits(app: *App, g: *GraphPane) CommandError!void {
    const arena = app.frame.allocator();
    const st = &app.git;
    var head = headIndex(app, g) orelse return app.diag.fail(arena, "graph: HEAD is not in the list", .{});
    const upstream: ?[]const u8 = if (st.status_repo == g.repo) (if (st.status) |s| s.upstream else null) else null;
    const ahead: u32 = if (st.status_repo == g.repo) (if (st.status) |s| s.ahead else 0) else 0;
    g.clearSelection();
    var steps: u32 = 0;
    while (true) {
        const c = g.commits[head];
        if (upstream) |u| if (refsName(c.refs, u)) break;
        if (upstream != null and ahead > 0 and steps >= ahead) break;
        try g.marks.put(g.gpa, @intCast(head), {});
        steps += 1;
        if (c.parents.len == 0) break;
        head = indexOfSha(g, c.parents[0]) orelse break;
    }
    if (upstream == null) app.toast("no upstream: selected the whole first-parent line ({d})", .{steps}) else app.toast("selected {d} commit(s) since {s}", .{ steps, upstream.? });
    app.needs_render = true;
}

/// Whether `HEAD -> main, origin/main, tag: v1` names `name`.
fn refsName(refs: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, refs, ", ");
    while (it.next()) |tok_raw| {
        var tok = tok_raw;
        if (std.mem.startsWith(u8, tok, "HEAD -> ")) tok = tok["HEAD -> ".len..];
        if (std.mem.eql(u8, tok, name)) return true;
    }
    return false;
}

/// A fresh plan for `sel` (indices into the commits): the first-parent
/// line from HEAD down to the oldest selected commit, oldest first,
/// every row `pick`, the selected ones marked. Every selected commit
/// must lie on that line.
fn buildPlan(app: *App, g: *GraphPane, sel: []const usize) CommandError!Plan {
    const arena = app.frame.allocator();
    const gpa = app.gpa;
    if (sel.len == 0) return app.diag.fail(arena, "rebase: select a commit first (space, v, *)", .{});
    const head = headIndex(app, g) orelse return app.diag.fail(arena, "rebase: HEAD is not in the list", .{});
    // Walk down from HEAD until every selected commit has been passed.
    var chain: std.ArrayListUnmanaged(usize) = .empty;
    var remaining: usize = sel.len;
    var at = head;
    while (true) {
        try chain.append(arena, at);
        for (sel) |ci| if (ci == at) {
            remaining -= 1;
        };
        if (remaining == 0) break;
        const c = g.commits[at];
        if (c.parents.len == 0) break;
        at = indexOfSha(g, c.parents[0]) orelse break;
    }
    if (remaining != 0) return app.diag.fail(arena, "rebase: a selected commit is not on the current branch's first-parent line from HEAD", .{});
    var plan: Plan = .{};
    errdefer plan.deinit(gpa);
    const oldest = g.commits[chain.items[chain.items.len - 1]];
    if (oldest.parents.len > 0) plan.base = try gpa.dupe(u8, oldest.parents[0]);
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        const ci = chain.items[i];
        var marked = false;
        for (sel) |s| if (s == ci) {
            marked = true;
        };
        try plan.rows.append(gpa, .{ .ci = @intCast(ci), .marked = marked });
    }
    for (plan.rows.items, 0..) |r, idx| if (r.marked) {
        plan.cursor = idx;
        break;
    };
    return plan;
}

/// `git.rebase_plan`: the modal over the selection.
pub fn openPlan(app: *App, g: *GraphPane) CommandError!void {
    if (g.wipSelected() and g.marks.count() == 0) return app.diag.fail(app.frame.allocator(), "rebase: the working tree is not a commit — select commits first", .{});
    const sel = try selection(app, g);
    const plan = try buildPlan(app, g, sel);
    g.closePlan();
    g.plan = plan;
    g.detail_focus = false;
    g.wip_focused = false;
    app.needs_render = true;
}

/// The commit `onto` names: a ref on one of the graph's rows
/// (`feature`, `origin/feature`, `v1.0`) first, then a hash prefix.
fn ontoIndex(g: *const GraphPane, onto: []const u8) ?usize {
    for (g.commits, 0..) |c, i| if (refsName(c.refs, onto)) return i;
    return graph_view.findByHashPrefix(g.commits, onto);
}

/// `git.rebase_interactive_onto`: the same plan modal `git.rebase_plan`
/// opens, over the commits between `onto` and HEAD rather than over
/// whatever is selected — the branches panel's *Interactive rebase HEAD
/// onto <branch>* and the graph's *Interactive rebase onto this
/// commit*. `onto` itself stays put and becomes the plan's base, so
/// Enter runs `rebase -i <onto>` with the todo the modal holds.
pub fn openPlanOnto(app: *App, g: *GraphPane, onto: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const base = ontoIndex(g, onto) orelse return app.diag.fail(arena, "rebase: `{s}` is not in the open graph", .{onto});
    const head = headIndex(app, g) orelse return app.diag.fail(arena, "rebase: HEAD is not in the list", .{});
    if (base == head) return app.diag.fail(arena, "rebase: `{s}` is HEAD \u{2014} there is nothing to replay onto it", .{onto});
    var sel: std.ArrayListUnmanaged(usize) = .empty;
    var at = head;
    while (at != base) {
        try sel.append(arena, at);
        const c = g.commits[at];
        const parent = if (c.parents.len > 0) indexOfSha(g, c.parents[0]) else null;
        at = parent orelse return app.diag.fail(arena, "rebase: `{s}` is not on HEAD's first-parent line", .{onto});
    }
    const plan = try buildPlan(app, g, sel.items);
    g.closePlan();
    g.plan = plan;
    g.detail_focus = false;
    g.wip_focused = false;
    // Asked from the branches panel, the focus is the panel's: the modal
    // would paint and take no keys. The graph's pane takes it back.
    if (app.active) |id| if (activeGraph(app)) |ag| if (ag == g) {
        app.focus = .{ .pane = id };
    };
    app.needs_render = true;
}

/// A direct verb on the selection — no modal. `fixup` / `squash` fold
/// each selected commit into the commit before it (the plan reaches
/// one commit further down for that); `drop` drops; `reword` takes
/// `message` for the one selected commit.
pub fn directVerb(app: *App, g: *GraphPane, action: parse.TodoAction, message: ?[]const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (g.wipSelected() and g.marks.count() == 0) return app.diag.fail(arena, "{s}: the working tree is not a commit", .{action.word()});
    const sel = try selection(app, g);
    if (sel.len == 0) return app.diag.fail(arena, "{s}: select a commit first", .{action.word()});
    if (action == .reword and sel.len != 1) return app.diag.fail(arena, "reword: one commit at a time", .{});
    var want: std.ArrayListUnmanaged(usize) = .empty;
    try want.appendSlice(arena, sel);
    if (action == .fixup or action == .squash) {
        // The parent of the oldest selected must be in the plan too.
        for (sel) |ci| {
            const c = g.commits[ci];
            if (c.parents.len == 0) return app.diag.fail(arena, "{s}: {s} has no parent to fold into", .{ action.word(), c.short() });
            const pi = indexOfSha(g, c.parents[0]) orelse return app.diag.fail(arena, "{s}: the parent of {s} is not in the list", .{ action.word(), c.short() });
            var seen = false;
            for (want.items) |w| if (w == pi) {
                seen = true;
            };
            if (!seen) try want.append(arena, pi);
        }
    }
    var plan = try buildPlan(app, g, want.items);
    errdefer plan.deinit(app.gpa);
    for (plan.rows.items) |*row| {
        var selected = false;
        for (sel) |ci| if (ci == row.ci) {
            selected = true;
        };
        if (!selected) continue;
        row.action = action;
        if (action == .reword) if (message) |m| {
            row.message = try app.gpa.dupe(u8, m);
        };
    }
    g.closePlan();
    g.plan = plan;
    try runPlan(app, g);
}

/// Enter on the plan: the todo goes to the worker as `Job.rebase_plan`.
pub fn runPlan(app: *App, g: *GraphPane) CommandError!void {
    const arena = app.frame.allocator();
    const gpa = app.gpa;
    const plan = if (g.plan) |*p| p else return;
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    if (plan.rows.items.len == 0) return app.diag.fail(arena, "rebase: an empty plan", .{});
    const first = plan.rows.items[0].action;
    if (first == .squash or first == .fixup) return app.diag.fail(arena, "rebase: the first commit has nothing before it to {s} into", .{first.word()});
    var n_changed: usize = 0;
    for (plan.rows.items) |r| if (r.action != .pick) {
        n_changed += 1;
    };
    var ops = try gpa.alloc(sequence_editor.Op, plan.rows.items.len);
    var built: usize = 0;
    errdefer {
        for (ops[0..built]) |op| op.deinit(gpa);
        gpa.free(ops);
    }
    for (plan.rows.items, 0..) |r, i| {
        const c = g.commits[r.ci];
        ops[i] = .{
            .sha = try gpa.dupe(u8, c.hash),
            .action = r.action,
            .subject = try gpa.dupe(u8, c.subject),
            .new_message = if (r.message) |m| try gpa.dupe(u8, m) else null,
        };
        built += 1;
    }
    const base: ?[]u8 = if (plan.base) |b| try gpa.dupe(u8, b) else null;
    errdefer if (base) |b| gpa.free(b);
    const job: client.Job = .{ .rebase_plan = .{ .base = base, .ops = ops } };
    g.closePlan();
    g.clearSelection();
    app.toast("rebasing {d} commit(s), {d} to change\u{2026}", .{ ops.len, n_changed });
    // `submitOp` owns the job from here, failure included.
    try submitOp(app, repo, job);
}

/// `git.reset_*`: `rev` through the worker, the hard one behind a
/// confirm.
pub fn resetTo(app: *App, mode: client.ResetMode, rev: []const u8) CommandError!void {
    const gpa = app.gpa;
    const repo = try requireRepo(app);
    if (mode == .hard) {
        return openConfirm(app, .{ .reset_hard = try gpa.dupe(u8, rev) }, try std.fmt.allocPrint(gpa, "reset --hard {s}? The index and the working tree follow (undo restores them).", .{rev[0..@min(12, rev.len)]}));
    }
    try submitOp(app, repo, .{ .reset = .{ .mode = mode, .rev = try gpa.dupe(u8, rev) } });
}

/// The commit box has the keys: text edits, Enter (Shift+Enter too) a
/// newline as its hint row says, Esc blurs, Ctrl+Enter commits. The
/// break goes in through `insertMultiline`: the single-line field's
/// `insert` turns a newline into a space, and every Enter landed as one
/// — `git log --format=%b` never saw a body.
fn textareaKey(app: *App, g: *GraphPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => g.wip_focused = false,
        .enter => {
            if (k.mods.ctrl) {
                runToast(app, commitFromTextarea(app, g));
            } else try text_field.insertMultiline(&g.wip_text, &g.wip_cursor, app.gpa, "\n");
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

/// A paste while the graph's commit box has the keys lands in the box,
/// line breaks kept; false when no focused box takes it.
pub fn pasteIntoCommitBox(app: *App, text: []const u8) Allocator.Error!bool {
    const id = app.active orelse return false;
    if (app.focus != .pane) return false;
    const pane = app.panes.get(id) orelse return false;
    if (pane.* != .git_graph) return false;
    const g = &pane.git_graph;
    if (!g.wip_focused) return false;
    try text_field.insertMultiline(&g.wip_text, &g.wip_cursor, app.gpa, text);
    app.needs_render = true;
    return true;
}

/// Commit what the box holds; an empty box opens the prompt instead
/// (Rust `commit_from_active_wip_textarea_or_prompt`).
pub fn commitFromTextarea(app: *App, g: *GraphPane) CommandError!void {
    if (g.wip_ai) return app.diag.fail(app.frame.allocator(), "AI message still streaming — wait for it to finish", .{});
    const text = std.mem.trim(u8, g.wip_text.items, " \t\r\n");
    if (text.len == 0) {
        openPrompt(app, .commit, commitPromptTitle(app));
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

// ─── the compare base (W) ───────────────────────────────────────────────

/// `W`: the selected commit becomes the compare base — `d` on another
/// row then diffs `base..row`; `W` on the base clears it.
pub fn toggleCompareBase(app: *App, g: *GraphPane) CommandError!void {
    const c = g.selected() orelse return app.diag.fail(app.frame.allocator(), "graph: select a commit to compare from", .{});
    if (g.compare_base) |b| {
        const was = std.mem.eql(u8, b, c.hash);
        app.gpa.free(b);
        g.compare_base = null;
        if (was) {
            app.toast("compare base cleared", .{});
            app.needs_render = true;
            return;
        }
    }
    g.compare_base = try app.gpa.dupe(u8, c.hash);
    app.toast("compare base: {s} \u{2014} `d` on another row diffs base..row", .{c.short()});
    app.needs_render = true;
}

/// The base's index in `commits`, when the graph has it.
pub fn compareBaseIndex(g: *const GraphPane) ?usize {
    const b = g.compare_base orelse return null;
    return indexOfSha(g, b);
}

/// `d`: the selected commit against the compare base when one is set
/// (and is not this row), else the commit's own diff.
pub fn diffSelected(app: *App, g: *GraphPane) CommandError!void {
    if (g.compare_base != null and !g.wipSelected()) if (g.selected()) |c| {
        if (!std.mem.eql(u8, c.hash, g.compare_base.?)) return diffAgainstBase(app, g);
    };
    return showSelectedCommit(app, g);
}

/// The diff pane on `base..selected`.
pub fn diffAgainstBase(app: *App, g: *GraphPane) CommandError!void {
    const arena = app.frame.allocator();
    const base = g.compare_base orelse return app.diag.fail(arena, "graph: no compare base \u{2014} `W` marks one", .{});
    const c = g.selected() orelse return app.diag.fail(arena, "graph: select the commit to diff against the base", .{});
    if (std.mem.eql(u8, c.hash, base)) return app.diag.fail(arena, "graph: that is the base itself", .{});
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    const rev = try client.rangeRev(arena, base, c.hash);
    _ = try openDiff(app, repo, .range, null, rev, null);
}

/// A branch against the checked-out one: `current..branch` (HEAD when
/// detached) — what the branch has that the current one does not.
pub fn diffAgainstCurrent(app: *App, repo: *client.Repo, branch: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const cur: []const u8 = app.git.branchLabel() orelse "HEAD";
    const from: []const u8 = if (std.mem.eql(u8, cur, "(detached)")) "HEAD" else cur;
    if (std.mem.eql(u8, from, branch)) return app.diag.fail(arena, "diff: {s} is the current branch", .{branch});
    _ = try openDiff(app, repo, .range, null, try client.rangeRev(arena, from, branch), null);
}

/// The commits in `base..HEAD` — reachable from HEAD, not from the
/// base — as a set over the commit indices (on the frame arena), the
/// tint the graph paints while a base is set. Null without a base.
pub fn rangeSet(app: *App, g: *GraphPane) Allocator.Error!?[]bool {
    const bi = compareBaseIndex(g) orelse return null;
    const arena = app.frame.allocator();
    const head = headIndex(app, g) orelse return null;
    const n = g.commits.len;
    const from_base = try reachable(arena, g, bi);
    const from_head = try reachable(arena, g, head);
    const out = try arena.alloc(bool, n);
    for (out, from_head, from_base) |*o, h, b| o.* = h and !b;
    return out;
}

/// The commits reachable from `start` through the loaded parents,
/// `start` included.
fn reachable(arena: Allocator, g: *const GraphPane, start: usize) Allocator.Error![]bool {
    const on = try arena.alloc(bool, g.commits.len);
    @memset(on, false);
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    try stack.append(arena, start);
    while (stack.pop()) |at| {
        if (on[at]) continue;
        on[at] = true;
        for (g.commits[at].parents) |p| if (indexOfSha(g, p)) |pi| {
            if (!on[pi]) try stack.append(arena, pi);
        };
    }
    return on;
}

pub fn showSelectedCommit(app: *App, g: *GraphPane) CommandError!void {
    if (g.wipSelected()) {
        const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
        _ = try openDiff(app, repo, .head, null, null, null);
        return;
    }
    const c = g.selected() orelse return app.diag.fail(app.frame.allocator(), "graph: no commit selected", .{});
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    // Rust `open_selected_commit_diff`: a split to the right of the graph.
    _ = try openDiffPlaced(app, repo, .commit, null, c.hash, null, .beside);
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
    if (graph_view.planRowOf(hit_id)) |row| {
        const plan = if (g.plan) |*p| p else return;
        if (row >= plan.rows.items.len) return;
        // A click takes the cursor; one on the cursor's row cycles the action.
        if (m.button == .left and plan.cursor == row) cyclePlanAction(plan, true);
        if (m.button == .right and plan.cursor == row) cyclePlanAction(plan, false);
        plan.cursor = row;
        return;
    }
    if (g.plan != null) return;
    if (hit_id == graph_view.divider_id) {
        if (m.button == .left) app.drag = .{ .graph_divider = id };
        return;
    }
    if (graph_view.wipFileOf(hit_id)) |wf| {
        const files = try wipFiles(app, app.frame.allocator());
        const list = if (wf.staged) files.staged else files.unstaged;
        if (wf.idx >= list.len) return;
        const repo = app.git.repoById(g.repo) orelse return;
        // // right-click (git-more2, audit #101): the working tree's file
        // rows — the graph's embedded diff rows — open the row's menu.
        if (m.button == .right) {
            g.detail_focus = true;
            g.detail_cursor = wf.idx + @as(usize, if (wf.staged) files.unstaged.len else 0);
            return openDetailRowMenu(app, g, m.x, m.y);
        }
        if (m.button != .left) return;
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
        if (m.button == .right) return openDetailRowMenu(app, g, m.x, m.y);
        if (was and m.button == .left) runToast(app, openDetailRow(app, g));
        return;
    }
    if (hit_id >= g.totalRows()) return;
    g.detail_focus = false;
    moveGraphCursor(app, g, hit_id);
    if (m.button == .right) return openGraphMenu(app, m.x, m.y);
}

/// The working-tree file the graph's detail column has the cursor on,
/// for the `git.stage` family off the graph (the status pane's row
/// otherwise); null when the graph is not on its WIP row.
pub fn wipDetailRow(app: *App) Allocator.Error!?Row {
    const g = activeGraph(app) orelse return null;
    if (!g.wipSelected() or !g.detail_focus) return null;
    return wipRow(app, g, g.detail_cursor);
}

/// Enter's twin for the detail rows' menu.
pub fn openDetailRowCmd(app: *App, g: *GraphPane) CommandError!void {
    return openDetailRow(app, g);
}

/// A commit file row's "Open file at this revision": the file's text
/// as that commit had it, in a scratch buffer.
pub fn showDetailFileAtRev(app: *App, g: *GraphPane) CommandError!void {
    const arena = app.frame.allocator();
    if (g.wipSelected()) return app.diag.fail(arena, "graph: the working tree's file is on disk already", .{});
    const c = g.selected() orelse return app.diag.fail(arena, "graph: no commit selected", .{});
    const d = g.detail orelse return app.diag.fail(arena, "graph: the detail has not loaded", .{});
    if (g.detail_cursor >= d.files.len) return app.diag.fail(arena, "graph: no file row selected", .{});
    const repo = app.git.repoById(g.repo) orelse return error.NoRepo;
    const rev = try app.gpa.dupe(u8, c.hash);
    errdefer app.gpa.free(rev);
    try submit(app, repo, .{ .show_file = .{ .rev = rev, .path = try app.gpa.dupe(u8, d.files[g.detail_cursor].path) } });
}

/// The detail column's file rows' menu (audit #101 — Rust's embedded
/// diff rows): a working-tree row offers the diff, the file, stage /
/// unstage, discard and the path; a commit's row the diff in that
/// commit, the file at that revision, the hash, the path and the
/// remote.
fn openDetailRowMenu(app: *App, g: *GraphPane, x: u16, y: u16) Allocator.Error!void {
    // The labels and the copy_text rows live on the menu's own arena:
    // the frame's is gone by the time the menu paints again.
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    if (g.wipSelected()) {
        const row = (try wipRow(app, g, g.detail_cursor)) orelse return;
        try items.append(app.gpa, .{ .label = "Open diff (Enter)", .action = .{ .command = .@"git.graph_detail_open" } });
        try items.append(app.gpa, .{ .label = "Open file", .action = .{ .command = .@"git.open_file" } });
        if (row.staged) {
            try items.append(app.gpa, .{ .label = "Unstage", .action = .{ .command = .@"git.unstage" }, .separator_before = true });
        } else {
            try items.append(app.gpa, .{ .label = "Stage", .action = .{ .command = .@"git.stage" }, .separator_before = true });
        }
        try items.append(app.gpa, .{ .label = "Discard changes\u{2026}", .action = .{ .command = .@"git.discard" } });
        try items.append(app.gpa, .{ .label = "Stash this file\u{2026}", .action = .{ .command = .@"git.stash_file" } });
        const path = try arena.dupe(u8, row.path);
        try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Copy path ({s})", .{path}), .action = .{ .copy_text = path }, .separator_before = true });
        const rows = try items.toOwnedSlice(app.gpa);
        errdefer app.gpa.free(rows);
        try context_menus.openOwned(app, std.fs.path.basename(path), rows, x, y, mem);
        return;
    }
    const c = g.selected() orelse return;
    const d = g.detail orelse return;
    if (g.detail_cursor >= d.files.len) return;
    const path = d.files[g.detail_cursor].path;
    try items.append(app.gpa, .{ .label = "Open the file's diff in this commit (Enter)", .action = .{ .command = .@"git.graph_detail_open" } });
    try items.append(app.gpa, .{ .label = "Open file at this revision", .action = .{ .command = .@"git.graph_file_at_rev" } });
    try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Copy commit hash ({s})", .{c.short()}), .action = .{ .copy_text = c.hash }, .separator_before = true });
    try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Copy path ({s})", .{path}), .action = .{ .copy_text = path } });
    try items.append(app.gpa, .{ .label = "Browse commit on remote", .action = .{ .command = .@"git.browse_commit" }, .separator_before = true });
    const rows = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(rows);
    try context_menus.openOwned(app, std.fs.path.basename(path), rows, x, y, mem);
}

fn openGraphMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const g = activeGraph(app);
    const has_base = if (g) |gp| gp.compare_base != null else false;
    const on_base = if (g) |gp| (if (compareBaseIndex(gp)) |bi| gp.selectedIndex() == bi else false) else false;
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Details", .action = .{ .command = .@"git.graph_detail" } },
        .{ .label = "Diff this commit", .action = .{ .command = .@"git.graph_diff" } },
        .{ .label = if (on_base) "Clear the compare base (W)" else "Mark as compare base (W)", .action = .{ .command = .@"git.compare_base" }, .separator_before = true },
        .{ .label = if (has_base) "Diff against \u{2691}" else "Diff against \u{2691} (no base set)", .action = .{ .command = .@"git.diff_against_base" } },
        .{ .label = "Cherry-pick onto HEAD", .action = .{ .command = .@"git.cherry_pick" }, .separator_before = true },
        .{ .label = "Revert", .action = .{ .command = .@"git.revert" } },
        .{ .label = "Rebase plan\u{2026}", .action = .{ .command = .@"git.rebase_plan" }, .separator_before = true },
        .{ .label = "Interactive rebase onto this commit\u{2026}", .action = .{ .command = .@"git.rebase_interactive_onto" } },
        .{ .label = "Fixup into the commit before", .action = .{ .command = .@"git.fixup" } },
        .{ .label = "Squash into the commit before", .action = .{ .command = .@"git.squash" } },
        .{ .label = "Reword\u{2026}", .action = .{ .command = .@"git.reword" } },
        .{ .label = "Drop", .action = .{ .command = .@"git.drop" } },
        .{ .label = "Amend with the staged changes", .action = .{ .command = .@"git.amend_to" }, .separator_before = true },
        .{ .label = "Reset --soft here", .action = .{ .command = .@"git.reset_soft" } },
        .{ .label = "Reset --mixed here", .action = .{ .command = .@"git.reset_mixed" } },
        .{ .label = "Reset --hard here\u{2026}", .action = .{ .command = .@"git.reset_hard" } },
        .{ .label = "Select the branch's commits (*)", .action = .{ .command = .@"git.select_branch" }, .separator_before = true },
        .{ .label = "New branch from here\u{2026}", .action = .{ .command = .@"git.new_branch_from" }, .separator_before = true },
        .{ .label = "New worktree from here\u{2026}", .action = .{ .command = .@"git.worktree_add_from" } },
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
        .{ .label = "Stash this file\u{2026}", .action = .{ .command = .@"git.stash_file" }, .separator_before = true },
        .{ .label = "Stash staged only\u{2026}", .action = .{ .command = .@"git.stash_staged" } },
        .{ .label = "Stash keeping the index\u{2026}", .action = .{ .command = .@"git.stash_keep_index" } },
        .{ .label = "Stash everything\u{2026}", .action = .{ .command = .@"git.stash" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Git", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

/// `Pane.git_status`.
pub fn drawStatusPane(app: *App, ui: Ui, id: PaneId, sp: *StatusPane, full: Rect) Allocator.Error!void {
    const st = &app.git;
    // colors: the repo's gutter down the left edge.
    const area = git_palette.repoGutter(app, ui, sp.repo, full);
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
pub fn drawDiffPane(app: *App, ui: Ui, id: PaneId, dp: *DiffPane, full: Rect) void {
    const focused = app.active == id and app.focus == .pane;
    // colors: the repo's gutter down the left edge.
    const area = git_palette.repoGutter(app, ui, dp.repo, full);
    // Rust's `chip_actions_for_scope`: a worktree / file / HEAD diff
    // stages or discards, a staged one unstages, a commit's shows none.
    const actions: diff_view.Actions = switch (dp.scope) {
        .file, .worktree, .head => .unstaged,
        .staged => .staged,
        .commit, .orig, .conflict, .range => .none,
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
pub fn drawGraphPane(app: *App, ui: Ui, id: PaneId, g: *GraphPane, full: Rect) void {
    const st = &app.git;
    // colors: the repo's gutter down the left edge.
    const area = git_palette.repoGutter(app, ui, g.repo, full);
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
    var marks: ?[]const bool = null;
    if (g.marks.count() > 0) {
        const m = arena.alloc(bool, g.commits.len) catch return;
        @memset(m, false);
        var it = g.marks.keyIterator();
        while (it.next()) |ci| if (ci.* < m.len) {
            m[ci.*] = true;
        };
        marks = m;
    }
    const tinted: ?[]const bool = rangeSet(app, g) catch null;
    var plan_actions: ?[]const u8 = null;
    if (g.plan) |*plan| {
        const pa = arena.alloc(u8, g.commits.len) catch return;
        @memset(pa, 0);
        for (plan.rows.items) |r| if (r.ci < pa.len) {
            pa[r.ci] = @intFromEnum(r.action) + 1;
        };
        plan_actions = pa;
    }
    const painted = graph_view.draw(ui, id, area, &g.view, .{
        .commits = g.commits,
        .lanes = g.lanes,
        .order = g.order,
        .cursor = g.cursor,
        .focused = focused,
        .lane_spacing = app.cfg.git_graph.lane_spacing,
        .now = now,
        .utc = clock.inUtc(app),
        .sort = g.sort,
        .filter_label = filterLabel(app, g) catch null,
        .hash_filter = if (g.hash_filter_mode) g.hashFilter() else null,
        .has_wip = g.has_wip,
        .wip = wip,
        .detail = detail,
        .detail_w = g.detail_w orelse app.cfg.ui.git_graph_detail_col,
        .branch_col = app.cfg.ui.git_graph_branch_col,
        .author_col = app.cfg.ui.git_graph_author_col,
        .in_progress = inProgressOf(app, g.repo),
        .marks = marks,
        .range = g.range(),
        .plan_actions = plan_actions,
        .compare_base = compareBaseIndex(g),
        .tinted = tinted,
    });
    if (g.plan) |*plan| {
        const rows = arena.alloc(graph_view.PlanRowDoc, plan.rows.items.len) catch return;
        for (rows, plan.rows.items) |*o, r| {
            const c = g.commits[r.ci];
            o.* = .{ .action = r.action, .sha = c.hash, .subject = c.subject, .marked = r.marked, .has_message = r.message != null };
        }
        plan.scroll = graph_view.drawPlan(ui, id, painted.list, .{ .rows = rows, .cursor = plan.cursor, .base = plan.base, .scroll = plan.scroll });
    }
    // The drag measures against the whole body under the toolbar.
    g.body = Rect.init(painted.list.x, painted.list.y, painted.list.w + painted.detail.w + @as(u16, if (painted.detail.w > 0) 1 else 0), painted.list.h);
    if (painted.caret) |c| if (focused) {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
    if (app.active == id) app.pane_rows = @max(painted.body.h, 1);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    // The painters and the editor child this module drives; neither is
    // on the root's list, so their tests ride with this file's.
    _ = @import("../ui/git_toolbar.zig");
    _ = @import("../git/sequence_editor.zig");
}

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
        if (std.mem.eql(u8, args[0], "init")) try f.identify();
    }

    /// Give the fixture's repository an identity of its own. The `-c`
    /// prefix above only reaches the test's own git; the app commits
    /// through a child process that carries none, so on a machine with no
    /// global identity — a container, a CI runner, anything but the
    /// developer's own Mac — git refused with "Author identity unknown"
    /// and the toast under test came back with that sentence appended.
    fn identify(f: *Fixture) !void {
        const settings = [_][2][]const u8{
            .{ "user.email", "t@mnml.dev" },
            .{ "user.name", "tester" },
            .{ "commit.gpgsign", "false" },
        };
        for (settings) |kv| {
            const res = std.process.run(testing.allocator, testing.io, .{
                .argv = &.{ "git", "config", kv[0], kv[1] },
                .cwd = .{ .path = f.root },
            }) catch continue;
            testing.allocator.free(res.stdout);
            testing.allocator.free(res.stderr);
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
    // A tracked file that sorts BEFORE the conflict in porcelain order,
    // clean until a test dirties it.
    try f.write("a.txt", "alpha\n");
    try f.sh(&.{ "add", "a.txt", "c.txt" });
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

test "conflicts: with another change that sorts before it, the conflict still leads the flat list — the cursor opens on it and Enter opens the editor on it, not the other file's diff" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    try seedConflict(&f);
    // ` M a.txt` comes before `UU c.txt` in `git status --porcelain`.
    try f.write("a.txt", "alpha changed\n");
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(2000);
    const files = try statusFiles(&f.app, f.app.frame.allocator());
    try testing.expectEqual(@as(usize, 2), files.unstaged.len);
    try testing.expectEqual(@as(u8, 'U'), files.unstaged[0].letter);
    try testing.expectEqualStrings("c.txt", files.unstaged[0].path);
    try testing.expectEqualStrings("a.txt", files.unstaged[1].path);
    // The graph's detail column keeps its A–Z order with `!` on the conflict.
    const wip = try collectFiles(&f.app, f.app.frame.allocator(), true);
    try testing.expectEqualStrings("a.txt", wip.unstaged[0].path);
    try testing.expectEqual(@as(u8, '!'), wip.unstaged[1].letter);
    try command.run(&f.app, .{ .static = .@"git.status_pane" });
    try f.settle(2000);
    const sp = &f.app.panes.get(f.app.active.?).?.git_status;
    try testing.expectEqual(@as(usize, 0), sp.cursor);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{25B6} U c.txt") != null);
    try statusAct(&f.app, sp, .diff);
    try testing.expect(f.app.activeEditor() != null);
    const after = try f.screen();
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "c.txt: 2 conflict blocks") != null);
    try testing.expect(std.mem.indexOf(u8, after, "diff: a.txt") == null);
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
    const regions = try conflicts.regionsOf(&f.app, f.app.frame.allocator(), e);
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
    try testing.expect((try conflicts.regionsOf(&f.app, f.app.frame.allocator(), e)).len == 0);
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

test "git.status_pane opens beside the graph — Rust's split to the right, the graph's tabs kept on the left — a second call reveals it there, a pane too narrow for two makes it a tab, and with nothing open it is the only leaf; git.diff_file from an editor splits the same way and the worktree diff stays a tab" {
    var f = try Fixture.init(140, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f.write("a.txt", "one\ntwo\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(2000);
    const graph_id = f.app.active.?;
    testing.allocator.free(try f.screen());
    try command.run(&f.app, .{ .static = .@"git.status_pane" });
    const status_id = f.app.active.?;
    try testing.expect(f.app.panes.get(status_id).?.* == .git_status);
    const layout = f.app.layouts.current();
    const graph_leaf = layout.leafOf(graph_id).?;
    const status_leaf = layout.leafOf(status_id).?;
    try testing.expect(graph_leaf != status_leaf);
    const parent = layout.parentOf(status_leaf).?;
    try testing.expectEqual(parent, layout.parentOf(graph_leaf).?);
    const split = layout.nodes.items[parent].split;
    try testing.expect(split.dir == .horizontal);
    try testing.expectEqual(graph_leaf, split.first);
    try testing.expectEqual(status_leaf, split.second);
    try testing.expectEqual(graph_id, layout.leaf(graph_leaf).?.active);
    // Again: revealed where it is, no second split.
    f.app.setActive(graph_id);
    try command.run(&f.app, .{ .static = .@"git.status_pane" });
    try testing.expectEqual(status_id, f.app.active.?);
    try testing.expectEqual(status_leaf, layout.leafOf(status_id).?);
    // Too narrow for two: a tab of the graph's leaf.
    try f.app.closePane(status_id, true);
    f.app.setActive(graph_id);
    activeGraph(&f.app).?.body.w = 60;
    try command.run(&f.app, .{ .static = .@"git.status_pane" });
    try testing.expectEqual(layout.leafOf(graph_id).?, layout.leafOf(f.app.active.?).?);
    try testing.expect(f.app.panes.get(f.app.active.?).?.* == .git_status);

    // Nothing open: the pane is the layout.
    var f2 = try Fixture.init(140, 30);
    defer f2.deinit();
    try f2.sh(&.{ "init", "-q", "-b", "main" });
    try f2.write("a.txt", "one\n");
    try f2.sh(&.{ "add", "a.txt" });
    try f2.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f2.write("a.txt", "one\ntwo\n");
    f2.app.tree.visible = false;
    try testing.expect(f2.app.active == null);
    try command.run(&f2.app, .{ .static = .@"git.status_pane" });
    const l2 = f2.app.layouts.current();
    const only = l2.leafOf(f2.app.active.?).?;
    try testing.expectEqual(only, l2.root.?);
    try f2.app.closePane(f2.app.active.?, true);
    // git.diff_file from the editor: a split beside it; git.diff stays a tab.
    const abs = try std.fs.path.join(testing.allocator, &.{ f2.root, "a.txt" });
    defer testing.allocator.free(abs);
    const ed = try f2.app.openPath(abs);
    testing.allocator.free(try f2.screen());
    try command.run(&f2.app, .{ .static = .@"git.diff_file" });
    try f2.settle(2000);
    const df = f2.app.active.?;
    try testing.expect(f2.app.panes.get(df).?.* == .diff);
    try testing.expect(l2.leafOf(df).? != l2.leafOf(ed).?);
    try testing.expectEqual(l2.parentOf(l2.leafOf(ed).?).?, l2.parentOf(l2.leafOf(df).?).?);
    try command.run(&f2.app, .{ .static = .@"git.diff" });
    try f2.settle(2000);
    const wt = f2.app.active.?;
    try testing.expect(wt != df);
    try testing.expectEqual(l2.leafOf(df).?, l2.leafOf(wt).?);
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

test "git.commit in git mode lands on the graph's commit box — from an editor tab too — focused on the WIP row, and Ctrl+Enter sends the typed message to git commit -m; a box with a message commits it outright; outside git mode, or under eighty cells, it is the modal titled with the staged count" {
    var f = try Fixture.init(140, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f.write("a.txt", "one\ntwo\n");
    try f.sh(&.{ "add", "a.txt" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try requestStatus(&f.app);
    try f.settle(2000);
    const graph_id = f.app.active.?;
    testing.allocator.free(try f.screen());
    // An editor tab beside the graph has the focus: the command still
    // lands on the box, no modal.
    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "a.txt" });
    defer testing.allocator.free(abs);
    _ = try f.app.openPath(abs);
    try testing.expect(f.app.active.? != graph_id);
    try command.run(&f.app, .{ .static = .@"git.commit" });
    try testing.expect(f.app.overlay == .none);
    try testing.expectEqual(graph_id, f.app.active.?);
    const g = activeGraph(&f.app).?;
    try testing.expect(g.wip_focused);
    try testing.expect(g.wipSelected());
    try testing.expect(f.app.focus == .pane and f.app.focus.pane == graph_id);
    // The typed message goes to the box, and Ctrl+Enter to git.
    for ("walk: test") |ch| try f.app.handle(.{ .key = Key.char(ch) });
    try testing.expectEqualStrings("walk: test", g.wip_text.items);
    try f.app.handle(.{ .key = .{ .code = .enter, .mods = .{ .ctrl = true } } });
    try f.settle(2000);
    try f.settle(2000);
    const subject = try f.out(&.{ "log", "-1", "--format=%s" });
    defer testing.allocator.free(subject);
    try testing.expectEqualStrings("walk: test", subject);
    try testing.expectEqualStrings("", g.wip_text.items);
    // A box already holding a message: `git.commit` commits it (Rust
    // `commit_from_active_wip_textarea_or_prompt`).
    try f.write("a.txt", "one\ntwo\nthree\n");
    try f.sh(&.{ "add", "a.txt" });
    try requestStatus(&f.app);
    try f.settle(2000);
    syncWip(&f.app, g);
    g.cursor = 0;
    try testing.expect(g.wipSelected());
    try g.wip_text.appendSlice(testing.allocator, "second: typed");
    try command.run(&f.app, .{ .static = .@"git.commit" });
    try f.settle(2000);
    try f.settle(2000);
    const second = try f.out(&.{ "log", "-1", "--format=%s" });
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("second: typed", second);
    // Under eighty cells the graph paints no detail column, so no box:
    // the modal, titled with what is staged.
    try f.write("a.txt", "one\ntwo\nthree\nfour\n");
    try f.sh(&.{ "add", "a.txt" });
    try requestStatus(&f.app);
    try f.settle(2000);
    g.body.w = 70;
    try command.run(&f.app, .{ .static = .@"git.commit" });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqualStrings("Commit message (1 staged)", f.app.overlay.prompt.state.title);
    f.app.overlay.deinit(f.app.gpa);
    f.app.overlay = .none;
    try f.sh(&.{ "reset", "-q" });
    try requestStatus(&f.app);
    try f.settle(2000);
    // Outside git mode: the modal, nothing staged.
    git_palette.leave(&f.app);
    try command.run(&f.app, .{ .static = .@"git.commit" });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqualStrings("Commit message (nothing staged \u{2014} stage hunks first)", f.app.overlay.prompt.state.title);
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

test "git mode: entering lists the branches and the worktree in the palette, one graph tab per repo; one click on a branch row selects nothing; leaving puts the layout back" {
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
    // + 1 worktree), the filter, LOCAL with the checked-out glyph on
    // main, WORKTREES with the house.
    try testing.expect(std.mem.indexOf(u8, txt, " GIT ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Viewing 3") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "/ filter") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F47C} \u{F0322} LOCAL") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  \u{F062C} feature") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  \u{F14CF} main") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F47C} \u{F0405} WORKTREES") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  \u{F02DC} main") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F03D7} STASHES") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F04FB} TAGS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "git graph") == null);
    testing.allocator.free(txt);
    // One click on the feature row hands the palette the keys and
    // selects nothing (the double-click acts — `git_palette.zig`).
    const rows = try git_palette.rows(&f.app, f.app.frame.allocator());
    var feature_row: ?usize = null;
    for (rows, 0..) |r, i| if (r == .branch and std.mem.eql(u8, r.branch.name, "feature")) {
        feature_row = i;
    };
    try git_palette.rowMouse(&f.app, @intCast(feature_row.?), .{ .x = 4, .y = 8, .kind = .press, .button = .left });
    try testing.expect(f.app.git_palette.selected == null);
    try testing.expect(f.app.focus == .panel and f.app.focus.panel == .git);
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

test "the plan modal: space and v select rows, * takes the branch, r opens the plan oldest-first, keys set / cycle / move the actions, esc closes; a row off the first-parent line refuses" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    // The app's own files under `.mnml/` must not dirty the tree.
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.write("b.txt", "two\n");
    try f.sh(&.{ "add", "b.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "second" });
    try f.write("c.txt", "three\n");
    try f.sh(&.{ "add", "c.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "third" });
    // A side branch: not on main's first-parent line.
    try f.sh(&.{ "checkout", "-q", "-b", "side", "HEAD~1" });
    try f.write("d.txt", "four\n");
    try f.sh(&.{ "add", "d.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "aside" });
    try f.sh(&.{ "checkout", "-q", "main" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(4000);
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    const g = activeGraph(&f.app).?;
    const id = f.app.active.?;
    try testing.expectEqual(@as(usize, 4), g.commits.len);
    try testing.expect(!g.has_wip);

    // Space marks the cursor's commit; a second space unmarks it.
    _ = try graphKey(&f.app, id, g, Key.char(' '));
    try testing.expectEqual(@as(usize, 1), g.marks.count());
    _ = try graphKey(&f.app, id, g, Key.char(' '));
    try testing.expectEqual(@as(usize, 0), g.marks.count());
    // `*`: the branch's first-parent line (no upstream → the whole line).
    _ = try graphKey(&f.app, id, g, Key.char('*'));
    try testing.expectEqual(@as(usize, 3), g.marks.count());
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "no upstream"));
    // Esc clears the selection before it closes the pane.
    _ = try graphKey(&f.app, id, g, Key.named(.esc));
    try testing.expectEqual(@as(usize, 0), g.marks.count());
    try testing.expect(f.app.active == id);

    // `v` from HEAD down one row, then `r`: the plan is second, third —
    // oldest first — with the cursor on the oldest marked row.
    const head_row = g.rowOfCommit(headIndex(&f.app, g).?);
    moveGraphCursor(&f.app, g, head_row);
    _ = try graphKey(&f.app, id, g, Key.char('v'));
    try testing.expect(g.anchor != null);
    // The next first-parent commit down the list (the side branch may sit between).
    const second_ci = indexOfSha(g, g.commits[headIndex(&f.app, g).?].parents[0]).?;
    moveGraphCursor(&f.app, g, g.rowOfCommit(second_ci));
    _ = try graphKey(&f.app, id, g, Key.char('r'));
    try testing.expect(g.plan != null);
    const plan = &g.plan.?;
    // When `aside` sorts between the two rows the range covers it; the
    // selection is the first-parent line, so the plan is still second, third.
    try testing.expectEqualStrings("second", g.commits[plan.rows.items[0].ci].subject);
    try testing.expectEqualStrings("third", g.commits[plan.rows.items[1].ci].subject);
    try testing.expectEqual(@as(usize, 2), plan.rows.items.len);
    try testing.expectEqualStrings(g.commits[plan.rows.items[0].ci].parents[0], plan.base.?);
    try testing.expectEqual(@as(usize, 0), plan.cursor);
    var txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "Rebase plan \u{B7} 2 commits onto") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{25B6} pick   ") != null);
    testing.allocator.free(txt);
    // Keys: j down, s squash, ← back to fixup, → to squash again, K moves it up.
    _ = try graphKey(&f.app, id, g, Key.char('j'));
    try testing.expectEqual(@as(usize, 1), plan.cursor);
    _ = try graphKey(&f.app, id, g, Key.char('s'));
    try testing.expectEqual(parse.TodoAction.squash, plan.rows.items[1].action);
    _ = try graphKey(&f.app, id, g, Key.named(.right));
    try testing.expectEqual(parse.TodoAction.fixup, plan.rows.items[1].action);
    _ = try graphKey(&f.app, id, g, Key.named(.left));
    try testing.expectEqual(parse.TodoAction.squash, plan.rows.items[1].action);
    _ = try graphKey(&f.app, id, g, Key.char('K'));
    try testing.expectEqual(@as(usize, 0), plan.cursor);
    try testing.expectEqualStrings("third", g.commits[plan.rows.items[0].ci].subject);
    try testing.expectEqual(parse.TodoAction.squash, plan.rows.items[0].action);
    // The graph rows behind carry the letters; the cursor row's marker
    // sits in the cell before its letter.
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "\u{258C} s") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{258C}\u{25B6}p") != null or std.mem.indexOf(u8, txt, "\u{258C} p") != null);
    testing.allocator.free(txt);
    // Enter with a squash first refuses: nothing before it.
    try testing.expectError(error.Failed, runPlan(&f.app, g));
    try testing.expect(g.plan != null);
    _ = try graphKey(&f.app, id, g, Key.char('J'));
    _ = try graphKey(&f.app, id, g, Key.char('d'));
    try testing.expectEqual(parse.TodoAction.drop, plan.rows.items[1].action);
    _ = try graphKey(&f.app, id, g, Key.named(.esc));
    try testing.expect(g.plan == null);
    try testing.expect(f.app.active == id);

    // A range over the whole list covers `aside` wherever it sorts; the
    // plan is first, second, third — the root has no base — and not `aside`.
    g.clearSelection();
    moveGraphCursor(&f.app, g, g.wipRows());
    _ = try graphKey(&f.app, id, g, Key.char('v'));
    moveGraphCursor(&f.app, g, g.wipRows() + g.order.len - 1);
    _ = try graphKey(&f.app, id, g, Key.char('r'));
    try testing.expect(g.plan != null);
    try testing.expectEqual(@as(usize, 3), g.plan.?.rows.items.len);
    try testing.expectEqualStrings("first", g.commits[g.plan.?.rows.items[0].ci].subject);
    try testing.expectEqualStrings("second", g.commits[g.plan.?.rows.items[1].ci].subject);
    try testing.expectEqualStrings("third", g.commits[g.plan.?.rows.items[2].ci].subject);
    try testing.expect(g.plan.?.base == null);
    _ = try graphKey(&f.app, id, g, Key.named(.esc));
    try testing.expect(g.plan == null);

    // A commit off the first-parent line, marked by hand: the plan refuses.
    g.clearSelection();
    var aside: usize = 0;
    for (g.commits, 0..) |c, i| if (std.mem.eql(u8, c.subject, "aside")) {
        aside = i;
    };
    try g.marks.put(g.gpa, @intCast(aside), {});
    try testing.expectError(error.Failed, openPlan(&f.app, g));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "first-parent") != null);
    f.app.diag.clear();
    try testing.expect(refsName("HEAD -> main, origin/main, tag: v1", "origin/main"));
    try testing.expect(refsName("HEAD -> main", "main"));
    try testing.expect(!refsName("HEAD -> main, origin/main", "main2"));
}

test "openPlanOnto: a branch row's interactive rebase plans everything HEAD has that the row does not, oldest first, with the row as the base; a hash reaches the same plan; HEAD itself, an unknown ref and a commit off the first-parent line each refuse by name" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    // `base` stays on the first commit: the plan replays what came after.
    try f.sh(&.{ "branch", "base" });
    try f.write("b.txt", "two\n");
    try f.sh(&.{ "add", "b.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "second" });
    try f.write("c.txt", "three\n");
    try f.sh(&.{ "add", "c.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "third" });
    // A side branch, off main's first-parent line.
    try f.sh(&.{ "checkout", "-q", "-b", "side", "HEAD~1" });
    try f.write("d.txt", "four\n");
    try f.sh(&.{ "add", "d.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "aside" });
    try f.sh(&.{ "checkout", "-q", "main" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(4000);
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    const g = activeGraph(&f.app).?;

    try openPlanOnto(&f.app, g, "base");
    try testing.expect(g.plan != null);
    try testing.expectEqual(@as(usize, 2), g.plan.?.rows.items.len);
    try testing.expectEqualStrings("second", g.commits[g.plan.?.rows.items[0].ci].subject);
    try testing.expectEqualStrings("third", g.commits[g.plan.?.rows.items[1].ci].subject);
    // The base is `base`'s own commit — `rebase -i <base>` replays the two.
    const base_ci = ontoIndex(g, "base").?;
    try testing.expectEqualStrings(g.commits[base_ci].hash, g.plan.?.base.?);
    for (g.plan.?.rows.items) |r| try testing.expect(r.marked);
    g.closePlan();

    // The same commit by hash prefix.
    try openPlanOnto(&f.app, g, g.commits[base_ci].hash[0..7]);
    try testing.expectEqual(@as(usize, 2), g.plan.?.rows.items.len);
    g.closePlan();

    // HEAD itself: nothing to replay.
    try testing.expectError(error.Failed, openPlanOnto(&f.app, g, "main"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "is HEAD") != null);
    f.app.diag.clear();
    // A ref the graph does not carry.
    try testing.expectError(error.Failed, openPlanOnto(&f.app, g, "no-such-branch"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "not in the open graph") != null);
    f.app.diag.clear();
    // `side` is off main's first-parent line.
    try testing.expectError(error.Failed, openPlanOnto(&f.app, g, "side"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "first-parent") != null);
    f.app.diag.clear();
    try testing.expect(g.plan == null);
}

test "explainBranch: the base is the checked-out branch, or its upstream on the checked-out branch itself; with neither it refuses by name, and an empty range says so instead of asking the model" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.sh(&.{ "branch", "feature" });
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);

    // The checked-out branch with no upstream: nothing to compare against.
    try testing.expectError(error.Failed, explainBranch(&f.app, "main"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "no upstream") != null);
    f.app.diag.clear();

    // A range the worker found empty: said, not sent to the model — no
    // AI pane opens.
    const before = f.app.panes.count();
    try branchExplainReady(&f.app, "feature", "main", "");
    try testing.expect(std.mem.indexOf(u8, f.app.lastToast().?, "nothing main does not already have") != null);
    try testing.expectEqual(before, f.app.panes.count());
}

test "push and start PR: the remote and the forge page come off the rail, a remote row is refused, an unknown host has no page; the page opens only once the push landed" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    const app = &f.app;
    const arena = app.frame.allocator();
    var branches = [_]parse.Branch{
        .{ .name = "main", .time = 0, .current = true, .remote = false, .sha = "aaaa111" },
        .{ .name = "feat/eng-12", .time = 0, .current = false, .remote = false, .sha = "bbbb222", .upstream = "fork/feat/eng-12" },
        .{ .name = "origin/main", .time = 0, .current = false, .remote = true, .sha = "aaaa111" },
    };
    var remotes = [_]parse.Remote{
        .{ .name = "origin", .url = "git@github.com:acme/widget.git", .provider = .github },
        .{ .name = "fork", .url = "https://git.acme-corp.example/~me/widget", .provider = .other },
    };
    app.git.rail_branches = &branches;
    app.git.rail_remotes = &remotes;

    // No upstream: the first remote, and its forge's page.
    const main_t = try prTarget(app, arena, "main");
    try testing.expectEqualStrings("origin", main_t.remote);
    try testing.expectEqualStrings("https://github.com/acme/widget/compare/main?expand=1", main_t.url);
    // An upstream names the remote — here one whose host has no shape.
    const feat_t = try prTarget(app, arena, "feat/eng-12");
    try testing.expectEqualStrings("fork", feat_t.remote);
    try testing.expectEqualStrings("", feat_t.url);
    // A remote row is not a branch to push.
    try testing.expectError(error.Failed, prTarget(app, arena, "origin/main"));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "is a remote branch") != null);
    app.diag.clear();
    // With no remote at all there is nowhere to push.
    app.git.rail_remotes = &.{};
    try testing.expectError(error.Failed, prTarget(app, arena, "main"));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "no remote") != null);
    app.diag.clear();
    app.git.rail_remotes = &remotes;

    // The page opens on the push's own result, never before it. A
    // browser that cannot start says so — which is the proof it was
    // reached; a failed push carries no page at all.
    app.cfg.ui.external_browser = "mnml-test-no-such-browser";
    const repo = try requireRepo(app);
    const failed = try client.Result.create(testing.allocator, repo.id);
    failed.payload = .{ .op = .{ .desc = "pushed main to origin", .ok = false, .msg = "rejected", .url = "https://github.com/acme/widget/compare/main?expand=1" } };
    try handle(app, failed);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "github.com") == null);
    const landed = try client.Result.create(testing.allocator, repo.id);
    landed.payload = .{ .op = .{ .desc = "pushed main to origin", .ok = true, .url = "https://github.com/acme/widget/compare/main?expand=1" } };
    try handle(app, landed);
    try testing.expectEqualStrings("https://github.com/acme/widget/compare/main?expand=1", app.lastToast().?);
    app.git.rail_branches = &.{};
    app.git.rail_remotes = &.{};
}

test "the compare base: W marks the row (⚑ in the mark cell), rangeSet tints base..HEAD, d on another row opens the range diff titled base..row, W on the base clears it; a branch diffs against the current one" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.write("b.txt", "two\n");
    try f.sh(&.{ "add", "b.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "second" });
    try f.write("c.txt", "three\n");
    try f.sh(&.{ "add", "c.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "third" });
    try f.sh(&.{ "branch", "-q", "other", "HEAD~1" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(4000);
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    const g = activeGraph(&f.app).?;
    const id = f.app.active.?;
    try testing.expectEqual(@as(usize, 3), g.commits.len);
    try testing.expect(!g.has_wip);

    // The base: `first`, the bottom row.
    const first_ci = for (g.commits, 0..) |c, i| {
        if (std.mem.eql(u8, c.subject, "first")) break i;
    } else unreachable;
    moveGraphCursor(&f.app, g, g.rowOfCommit(first_ci));
    _ = try graphKey(&f.app, id, g, Key.char('W'));
    try testing.expectEqualStrings(g.commits[first_ci].hash, g.compare_base.?);
    try testing.expectEqual(first_ci, compareBaseIndex(g).?);
    // base..HEAD is second + third: two tinted rows, the base not among them.
    const tint = (try rangeSet(&f.app, g)).?;
    var n_tint: usize = 0;
    for (tint) |t| if (t) {
        n_tint += 1;
    };
    try testing.expectEqual(@as(usize, 2), n_tint);
    try testing.expect(!tint[first_ci]);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{2691}") != null);

    // `d` on HEAD (third): the range pane, titled base..row with short shas.
    moveGraphCursor(&f.app, g, g.rowOfCommit(headIndex(&f.app, g).?));
    _ = try graphKey(&f.app, id, g, Key.char('d'));
    try f.settle(4000);
    const dp = activeDiff(&f.app).?;
    try testing.expectEqual(client.DiffScope.range, dp.scope);
    const want = try std.fmt.allocPrint(testing.allocator, "{s}..{s}", .{ g.commits[first_ci].hash[0..7], g.commits[headIndex(&f.app, g).?].hash[0..7] });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, dp.title);
    // b.txt and c.txt were added between the two.
    try testing.expectEqual(@as(usize, 2), dp.files.len);

    // Back on the graph: W on the base clears it; the tint goes with it.
    f.app.showPane(id);
    moveGraphCursor(&f.app, g, g.rowOfCommit(first_ci));
    _ = try graphKey(&f.app, id, g, Key.char('W'));
    try testing.expect(g.compare_base == null);
    try testing.expect((try rangeSet(&f.app, g)) == null);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "compare base cleared"));
    // Without a base `git.diff_against_base` says so.
    try testing.expectError(error.Failed, command.run(&f.app, .{ .static = .@"git.diff_against_base" }));
    f.app.diag.clear();

    // A branch against the current one: `main..other` is the two trees'
    // diff — other lacks c.txt, so one file, titled by name.
    try diffAgainstCurrent(&f.app, f.app.git.activeRepo().?, "other");
    try f.settle(4000);
    const dp2 = activeDiff(&f.app).?;
    try testing.expectEqualStrings("main..other", dp2.title);
    try testing.expectEqual(@as(usize, 1), dp2.files.len);
    try testing.expectEqualStrings("c.txt", dp2.files[0].path());
    // The current branch against itself refuses.
    try testing.expectError(error.Failed, diffAgainstCurrent(&f.app, f.app.git.activeRepo().?, "main"));
    f.app.diag.clear();
}

test "the branch verbs on a seeded remote: fast-forward fetches ref:branch when not checked out, rename, set upstream, a new branch from a commit, force checkout (confirm), delete on the remote (confirm), push --force-with-lease (confirm)" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\norigin.git/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    const first = try f.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(first);
    try f.write("b.txt", "two\n");
    try f.sh(&.{ "add", "b.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "second" });
    try f.sh(&.{ "init", "-q", "--bare", "origin.git" });
    try f.sh(&.{ "remote", "add", "origin", "./origin.git" });
    try f.sh(&.{ "push", "-q", "-u", "origin", "main" });
    // feat: one commit past main on the remote, the local ref behind it.
    try f.sh(&.{ "checkout", "-q", "-b", "feat" });
    try f.write("c.txt", "three\n");
    try f.sh(&.{ "add", "c.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "feat work" });
    try f.sh(&.{ "push", "-q", "-u", "origin", "feat" });
    try f.sh(&.{ "checkout", "-q", "main" });
    try f.sh(&.{ "update-ref", "refs/heads/feat", first });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(4000);
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    try testing.expect(f.app.git.rail_loaded);

    // Fast-forward feat (not checked out): fetch origin feat:feat.
    try fastForward(&f.app, "feat");
    try f.settle(4000);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "fast-forwarded feat to origin/feat"));
    const feat_now = try f.out(&.{ "rev-parse", "feat" });
    defer testing.allocator.free(feat_now);
    const feat_remote = try f.out(&.{ "rev-parse", "origin/feat" });
    defer testing.allocator.free(feat_remote);
    try testing.expectEqualStrings(feat_remote, feat_now);
    // A branch without an upstream says so instead of guessing one.
    try f.sh(&.{ "branch", "-q", "lonely" });
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    try testing.expectError(error.Failed, fastForward(&f.app, "lonely"));
    f.app.diag.clear();

    // Rename: the prompt opens with the old name; the accept runs branch -m.
    try branchRename(&f.app, "lonely");
    try testing.expectEqual(PromptKind.branch_rename, f.app.git.prompt);
    try testing.expectEqualStrings("lonely", f.app.overlay.prompt.state.text());
    try acceptPrompt(&f.app, "renamed");
    try f.settle(4000);
    const renamed = try f.out(&.{ "branch", "--list", "renamed" });
    defer testing.allocator.free(renamed);
    try testing.expect(std.mem.indexOf(u8, renamed, "renamed") != null);

    // Set upstream: the picker offers the remote branches; the pick runs branch -u.
    try setUpstream(&f.app, "renamed");
    // The picker waits on the `.branches` result, which no busy count covers.
    var spins: usize = 0;
    while (f.app.git.pick != .set_upstream and spins < 800) : (spins += 1) {
        try f.app.tick(App.nowMs(testing.io));
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expectEqual(Pick.set_upstream, f.app.git.pick);
    try acceptPick(&f.app, "origin/main", "remote");
    try f.settle(4000);
    const up = try f.out(&.{ "rev-parse", "--abbrev-ref", "renamed@{upstream}" });
    defer testing.allocator.free(up);
    try testing.expectEqualStrings("origin/main", up);

    // A new branch from the first commit: checkout -b name <sha>.
    try newBranchFrom(&f.app, first);
    try acceptPrompt(&f.app, "fromfirst");
    try f.settle(4000);
    const ff = try f.out(&.{ "rev-parse", "fromfirst" });
    defer testing.allocator.free(ff);
    try testing.expectEqualStrings(first, ff);
    try testing.expect(f.app.git.verb_start == null);

    // Force checkout main with a dirty tree: the confirm, then the tree is clean on main.
    try f.write("a.txt", "dirty\n");
    try checkoutForce(&f.app, "main");
    try testing.expectEqual(std.meta.Tag(Confirm).checkout_force, std.meta.activeTag(f.app.git.confirm));
    try acceptConfirm(&f.app, 0);
    try f.settle(4000);
    const on = try f.out(&.{ "symbolic-ref", "--short", "HEAD" });
    defer testing.allocator.free(on);
    try testing.expectEqualStrings("main", on);
    const clean = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(clean);
    try testing.expectEqualStrings("", clean);

    // Delete on the remote: origin/feat splits into the remote and the ref.
    try deleteRemote(&f.app, "origin/feat", null);
    try testing.expectEqualStrings("origin", f.app.git.confirm.delete_remote.remote);
    try testing.expectEqualStrings("feat", f.app.git.confirm.delete_remote.branch);
    try acceptConfirm(&f.app, 0);
    try f.settle(4000);
    const heads = try f.out(&.{ "ls-remote", "--heads", "origin", "feat" });
    defer testing.allocator.free(heads);
    try testing.expectEqualStrings("", heads);

    // Push --force-with-lease after rewriting main: the confirm names the
    // risk; origin/main then matches.
    try f.sh(&.{ "commit", "-q", "--amend", "-m", "second, reworded" });
    try pushForce(&f.app);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.confirm.message, "force-with-lease") != null);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.confirm.message, "would be lost") != null);
    try acceptConfirm(&f.app, 0);
    try f.settle(4000);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "pushed (--force-with-lease)"));
    const local = try f.out(&.{ "rev-parse", "main" });
    defer testing.allocator.free(local);
    const remote = try f.out(&.{ "rev-parse", "origin/main" });
    defer testing.allocator.free(remote);
    try testing.expectEqualStrings(local, remote);
}

test "stash depth: staged only leaves the tree's change, a file alone, keep-index; the files pane lists a stash's files and Enter opens the range diff; rename keeps the branch half; branch from stash" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.write("b.txt", "two\n");
    try f.sh(&.{ "add", "a.txt", "b.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);

    // Staged only: a.txt staged, b.txt changed in the tree — the stash
    // takes the index, b.txt's change stays.
    try f.write("a.txt", "one-staged\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.write("b.txt", "two-tree\n");
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    try command.run(&f.app, .{ .static = .@"git.stash_staged" });
    try testing.expectEqual(PromptKind.stash, f.app.git.prompt);
    try testing.expect(f.app.git.stash_variant.staged_only);
    try acceptPrompt(&f.app, "index bits");
    try f.settle(4000);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "stashed the index: index bits"));
    // (`out` trims the porcelain's leading column.)
    const st1 = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st1);
    try testing.expectEqualStrings("M b.txt", st1);
    const list1 = try f.out(&.{ "stash", "list", "--format=%gs" });
    defer testing.allocator.free(list1);
    try testing.expectEqualStrings("On main: index bits", list1);
    // Pop brings a.txt's change back (into the tree: a plain pop does
    // not restore the index).
    _ = try f.op(.{ .stash_pop = null });
    const st2 = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st2);
    try testing.expect(std.mem.indexOf(u8, st2, "M a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, st2, "M b.txt") != null);

    // One file: the argv narrows the push to it.
    try f.sh(&.{ "reset", "-q" });
    const path = try testing.allocator.dupe(u8, "b.txt");
    try stashWith(&f.app, .{ .path = path }, "x");
    try acceptPrompt(&f.app, "");
    try f.settle(4000);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "stashed b.txt"));
    const st3 = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st3);
    try testing.expectEqualStrings("M a.txt", st3);
    try testing.expect(f.app.git.stash_variant.path == null);

    // The files pane: stash@{0} holds b.txt; Enter diffs it as a range.
    try stashShow(&f.app, "stash@{0}");
    var spins: usize = 0;
    while (f.app.git.stash_view == null and spins < 800) : (spins += 1) {
        try f.app.tick(App.nowMs(testing.io));
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expect(f.app.git.stash_view != null);
    try testing.expectEqualStrings("stash@{0}", f.app.git.stash_view.?.ref);
    const lp = switch (f.app.panes.get(f.app.active.?).?.*) {
        .list => |*l| l,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(app_mod.ListPane.Kind.stash_files, lp.kind);
    try testing.expectEqual(@as(usize, 1), lp.entries.items.len);
    try testing.expectEqualStrings("M  b.txt", lp.entries.items[0].text);
    try stashFileEnter(&f.app, lp.entries.items[0]);
    try f.settle(4000);
    const dp = activeDiff(&f.app).?;
    try testing.expectEqual(client.DiffScope.range, dp.scope);
    try testing.expectEqualStrings("b.txt", dp.path.?);
    try testing.expectEqual(@as(usize, 1), dp.files.len);

    // Rename: the prompt opens with the note; the branch half stays.
    try stashRenamePrompt(&f.app, "stash@{0}", "WIP on main: abc first");
    try testing.expectEqualStrings("abc first", f.app.overlay.prompt.state.text());
    try acceptPrompt(&f.app, "b only");
    try f.settle(4000);
    // `%gs`: the reflog subject is what a rename changes (and what the panel lists).
    const list2 = try f.out(&.{ "stash", "list", "--format=%gs" });
    defer testing.allocator.free(list2);
    try testing.expectEqualStrings("On main: b only", list2);

    // Keep-index: a.txt staged again and the tree changed; the index survives.
    try f.sh(&.{ "add", "a.txt" });
    try f.write("b.txt", "two-again\n");
    try stashWith(&f.app, .{ .keep_index = true }, "x");
    try acceptPrompt(&f.app, "");
    try f.settle(4000);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "stashed (index kept)"));
    const st4 = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st4);
    try testing.expectEqualStrings("M  a.txt", st4);

    // Branch from the b-only stash: the branch exists with the change applied.
    try f.sh(&.{ "reset", "-q", "--hard" });
    try stashBranchPrompt(&f.app, "stash@{1}");
    try acceptPrompt(&f.app, "from-stash");
    try f.settle(4000);
    const on = try f.out(&.{ "symbolic-ref", "--short", "HEAD" });
    defer testing.allocator.free(on);
    try testing.expectEqualStrings("from-stash", on);
    const st5 = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st5);
    try testing.expectEqualStrings("M b.txt", st5);
}

test "the command log's ring keeps the last 200, oldest out first, and finds an entry by seq" {
    var ring: LogRing = .{};
    defer ring.deinit(testing.allocator);
    var i: u32 = 1;
    while (i <= 205) : (i += 1) {
        try ring.push(testing.allocator, .{
            .seq = i,
            .repo = 1,
            .argv = try testing.allocator.dupe(u8, "git status"),
            .args = try testing.allocator.alloc([]u8, 0),
            .cwd = try testing.allocator.dupe(u8, "/r"),
            .ok = true,
            .exit = 0,
            .ms = 1,
            .stderr = try testing.allocator.dupe(u8, ""),
        });
    }
    try testing.expectEqual(@as(usize, 200), ring.items.items.len);
    try testing.expectEqual(@as(u32, 6), ring.items.items[0].seq);
    try testing.expectEqual(@as(u32, 205), ring.items.items[199].seq);
    try testing.expect(ring.find(5) == null);
    try testing.expectEqual(@as(u32, 100), ring.find(100).?.seq);
}

test "the command log: every child lands as a line; a failed op's toast carries the log link and the pane opens at that entry; Enter re-runs a read-only line and refuses a writing one" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    // The status job ran `status --porcelain=v2 -b` and more: all in the ring, timed.
    try testing.expect(f.app.git.log.items.items.len >= 2);
    const first = f.app.git.log.items.items[0];
    try testing.expect(std.mem.indexOf(u8, first.argv, "git --no-pager -c color.ui=never status --porcelain=v2 -b") != null);
    try testing.expectEqualStrings("status", first.args[0]);
    try testing.expect(first.ok);
    try testing.expectEqual(@as(?u8, 0), first.exit);
    try testing.expectEqualStrings(f.root, first.cwd);

    // A failing op: `pull` with no remote. Its line is the last failed
    // one; the toast ends in the link; the pane opens on that row.
    _ = try f.op(.pull);
    const toast = f.app.lastToast().?;
    try testing.expect(std.mem.startsWith(u8, toast, "pull"));
    try testing.expect(std.mem.endsWith(u8, toast, "\u{B7} log"));
    try testing.expectEqualStrings(log_toast_id, f.app.toasts.items[f.app.toasts.items.len - 1].id.?);
    // The link names the pull's own line, not a later child's failure
    // (the status refresh after it runs `config --get` on a repo with no
    // remote, which fails on its own).
    const failed_seq = f.app.git.log_link_seq.?;
    try testing.expect(std.mem.indexOf(u8, f.app.git.log.find(failed_seq).?.argv, "pull") != null);
    try openCommandLog(&f.app, null);
    const lp = switch (f.app.panes.get(f.app.active.?).?.*) {
        .list => |*l| l,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(app_mod.ListPane.Kind.git_log, lp.kind);
    // Newest first: row 0 is the last child; the cursor is on the pull.
    try testing.expectEqual(f.app.git.log.items.items[f.app.git.log.items.items.len - 1].seq, lp.entries.items[0].line);
    const at = lp.entries.items[lp.cursor];
    try testing.expectEqual(failed_seq, at.line);
    try testing.expect(std.mem.startsWith(u8, at.text, "\u{2717}"));
    try testing.expect(std.mem.indexOf(u8, at.text, "pull") != null);
    try testing.expect(f.app.git.log_link_seq == null);
    // Enter on the pull refuses; on a status line it re-runs, and the
    // re-run's own line joins the ring — the pane refills.
    try testing.expectError(error.Failed, logEnter(&f.app, at));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "writes") != null);
    f.app.diag.clear();
    const n_before = f.app.git.log.items.items.len;
    var status_row: ?app_mod.ListPane.Entry = null;
    for (lp.entries.items) |e| if (std.mem.indexOf(u8, e.text, "status --porcelain") != null) {
        status_row = e;
        break;
    };
    try logEnter(&f.app, status_row.?);
    try f.settle(4000);
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "re-ran: git status"));
    try testing.expect(f.app.git.log.items.items.len > n_before);
    try testing.expectEqual(f.app.git.log.items.items.len, lp.entries.items.len);
    // The `/` filter narrows the shown rows; `y` copies the command line.
    try lp.filter.appendSlice(lp.gpa, "PULL");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const shown = try lp.shown(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expectEqualStrings("git --no-pager -c color.ui=never pull --ff-only -q", logCommand(&f.app, lp.entries.items[shown[0]]).?);
}

test "the detail rows' menu (audit #101): a working-tree row offers stage / discard / the path and the git.stage family reads it; a commit's file row offers the file at that revision, which opens as a scratch copy, and the hash" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.write(".gitignore", ".mnml/\n");
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt", ".gitignore" });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.write("a.txt", "one\ntwo\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try f.settle(4000);
    try command.run(&f.app, .{ .static = .@"git.refresh" });
    try f.settle(4000);
    const g = activeGraph(&f.app).?;
    const id = f.app.active.?;
    try testing.expect(g.has_wip);
    try testing.expect(g.wipSelected());
    // A right press on the WIP file row: the cursor, then the menu.
    try graphClick(&f.app, id, g, graph_view.wipFileId(.{ .idx = 0, .staged = false, .button = false }), .{ .kind = .press, .button = .right, .x = 90, .y = 6 });
    try testing.expect(f.app.overlay == .menu);
    const rows = f.app.overlay.menu.items;
    try testing.expectEqualStrings("Open diff (Enter)", rows[0].label);
    try testing.expectEqualStrings("Stage", rows[2].label);
    try testing.expectEqualStrings("Copy path (a.txt)", rows[rows.len - 1].label);
    // The stage family reads the graph's row: git.stage stages a.txt.
    f.app.overlay.deinit(f.app.gpa);
    try testing.expectEqualStrings("a.txt", (try wipDetailRow(&f.app)).?.path);
    try command.run(&f.app, .{ .static = .@"git.stage" });
    try f.settle(4000);
    const st = try f.out(&.{ "status", "--porcelain" });
    defer testing.allocator.free(st);
    try testing.expectEqualStrings("M  a.txt", st);

    // The commit's file row: the menu names the hash; the file at that
    // revision opens as a scratch copy with the committed text.
    moveGraphCursor(&f.app, g, g.rowOfCommit(headIndex(&f.app, g).?));
    try f.settle(4000);
    try testing.expect(g.detail != null);
    // The files sort by path: .gitignore first, a.txt after it.
    const a_row: u32 = for (g.detail.?.files, 0..) |fl, i| {
        if (std.mem.eql(u8, fl.path, "a.txt")) break @intCast(i);
    } else return error.TestUnexpectedResult;
    try graphClick(&f.app, id, g, graph_view.detailRowId(a_row), .{ .kind = .press, .button = .right, .x = 90, .y = 8 });
    try testing.expect(f.app.overlay == .menu);
    const rows2 = f.app.overlay.menu.items;
    try testing.expectEqualStrings("Open the file's diff in this commit (Enter)", rows2[0].label);
    try testing.expectEqualStrings("Open file at this revision", rows2[1].label);
    const want = try std.fmt.allocPrint(testing.allocator, "Copy commit hash ({s})", .{g.selected().?.short()});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, rows2[2].label);
    f.app.overlay.deinit(f.app.gpa);
    try command.run(&f.app, .{ .static = .@"git.graph_file_at_rev" });
    var spins: usize = 0;
    while (f.app.panes.editor(f.app.active.?) == null and spins < 800) : (spins += 1) {
        try f.app.tick(App.nowMs(testing.io));
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    const e = f.app.panes.editor(f.app.active.?) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("one\n", e.buf.editor.bytes());
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "a.txt at"));
}

test "the hash-typing chip: `/` arms the header, each hex digit jumps to the first commit it prefixes and paints `/<prefix>_`, a miss toasts, Backspace steps back, Esc clears and leaves, Enter keeps the place" {
    var f = try Fixture.init(140, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f.write("a.txt", "two\n");
    try f.sh(&.{ "commit", "-q", "-am", "second commit" });
    try f.write("b.txt", "new\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try requestStatus(&f.app);
    try f.settle(2000);
    f.app.focus = .{ .pane = f.app.active.? };
    const g = activeGraph(&f.app).?;
    try testing.expect(g.wipSelected());
    try testing.expectEqual(@as(usize, 2), g.commits.len);
    // The oldest commit is the one to reach: its first hex digit.
    const target = g.commits[g.order[g.order.len - 1]].hash;
    try f.app.handle(.{ .key = Key.char('/') });
    try testing.expect(g.hash_filter_mode);
    var txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "/_") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "COMMIT MESSAGE") == null);
    // A non-hex key is swallowed, not a jump and not a graph chord.
    try f.app.handle(.{ .key = Key.char('q') });
    try testing.expect(activeGraph(&f.app) != null);
    try testing.expectEqual(@as(u8, 0), g.hash_filter_len);
    // Enough of the target's hash to name it alone.
    var typed: usize = 0;
    while (typed < target.len) : (typed += 1) {
        try f.app.handle(.{ .key = Key.char(std.ascii.toUpper(target[typed])) });
        if (graph_view.findByHashPrefix(g.commits, g.hashFilter()).? == g.order[g.order.len - 1]) break;
    }
    try testing.expectEqualStrings(target[0 .. typed + 1], g.hashFilter());
    try testing.expectEqual(g.rowOfCommit(g.order[g.order.len - 1]), g.cursor);
    testing.allocator.free(txt);
    txt = try f.screen();
    const typed_chip = try std.fmt.allocPrint(testing.allocator, "/{s}_", .{g.hashFilter()});
    defer testing.allocator.free(typed_chip);
    try testing.expect(std.mem.indexOf(u8, txt, typed_chip) != null);
    // A digit no hash continues with: the prefix grows, the toast says so.
    const before = g.cursor;
    try f.app.handle(.{ .key = Key.char('z') });
    try testing.expectEqual(before, g.cursor);
    var miss: u8 = 0;
    for ("0123456789abcdef") |h| {
        var probe: [41]u8 = undefined;
        @memcpy(probe[0..g.hash_filter_len], g.hashFilter());
        probe[g.hash_filter_len] = h;
        if (graph_view.findByHashPrefix(g.commits, probe[0 .. g.hash_filter_len + 1]) == null) {
            miss = h;
            break;
        }
    }
    try f.app.handle(.{ .key = Key.char(miss) });
    try testing.expect(std.mem.startsWith(u8, f.app.lastToast().?, "no commit ~ "));
    // Backspace drops it; Esc clears and leaves; the header is back.
    try f.app.handle(.{ .key = Key.named(.backspace) });
    try testing.expectEqualStrings(target[0 .. typed + 1], g.hashFilter());
    try f.app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(!g.hash_filter_mode);
    try testing.expectEqual(@as(u8, 0), g.hash_filter_len);
    try testing.expect(activeGraph(&f.app) != null);
    testing.allocator.free(txt);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, "COMMIT MESSAGE") != null);
    // Enter keeps the prefix's place and leaves the mode.
    try f.app.handle(.{ .key = Key.char('/') });
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(!g.hash_filter_mode);
}

test "the AI answer lands in the graph's commit box when its WIP row asked: the box reads subject and body, focused, the wait flag cleared; without a target it is the prompt as before" {
    var f = try Fixture.init(140, 24);
    defer f.deinit();
    try f.sh(&.{ "init", "-q" });
    try f.write("a.txt", "one\n");
    try f.sh(&.{ "add", "a.txt" });
    try f.sh(&.{ "commit", "-q", "-m", "first commit" });
    try f.write("b.txt", "new\n");
    try f.sh(&.{ "add", "b.txt" });
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"git.graph" });
    try requestStatus(&f.app);
    try f.settle(2000);
    f.app.focus = .{ .pane = f.app.active.? };
    const id = f.app.active.?;
    const g = activeGraph(&f.app).?;
    try testing.expect(g.wipSelected());
    g.wip_ai = true;
    try deliverAiAnswer(&f.app, .{ .pane = id, .what = .commit, .wip = id }, "```\nfeat: add b\n\nThe body line.\n```\n");
    try testing.expect(!g.wip_ai);
    try testing.expect(g.wip_focused);
    try testing.expectEqualStrings("feat: add b\n\nThe body line.", g.wip_text.items);
    try testing.expectEqual(g.wip_text.items.len, g.wip_cursor);
    try testing.expect(f.app.overlay == .none);
    // The box paints it; `c` commits it (the trailing dot is the body's).
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "feat: add b") != null);
    // An empty answer clears the wait and says so, the box untouched.
    g.wip_ai = true;
    try deliverAiAnswer(&f.app, .{ .pane = id, .what = .commit, .wip = id }, "   \n");
    try testing.expect(!g.wip_ai);
    try testing.expectEqualStrings("feat: add b\n\nThe body line.", g.wip_text.items);
    try testing.expectEqualStrings("AI returned an empty commit message", f.app.lastToast().?);
    // No target: the prompt opens with the subject, the body kept.
    try deliverAiAnswer(&f.app, .{ .pane = id, .what = .commit }, "fix: thing\n\nwhy");
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqualStrings("fix: thing", f.app.overlay.prompt.state.text());
    try testing.expectEqualStrings("why", f.app.git.ai_body.?);
}
