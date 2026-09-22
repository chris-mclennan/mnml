//! Workspace grep (`Pane.grep`): `find.grep` prompts for a query and
//! runs it on a worker — `rg --json` when ripgrep is on PATH, else an
//! in-process walk (the `.gitignore` matcher + `src/regex/`) — whose
//! hits stream into the pane in batches. The same worker, `git grep`
//! first, serves the SEARCH section (`search_section.zig`), which
//! reaches this pane through *Open as pane* — the pane is Zig's own
//! door, kept for the replace and the per-hit toggles. Results are grouped by file
//! with expand / collapse; Enter opens a hit, `n` / `N` step through
//! them, `/` narrows with a vim pattern, Space toggles a hit for
//! `find.grep_replace`, which rewrites every enabled hit across every
//! file: open clean buffers through `EditOp`s (then saved), closed
//! files on disk, dirty buffers refused with a toast.
//!
//! D1: a batch (`Result`) is owned by the event; `handle` copies its
//! hits onto the pane's snapshot arena and destroys it. D3: one
//! `Io.Group` per pane, cancel-on-rerun, stale batches dropped by
//! generation. Workers never toast.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const alloc = @import("../core/alloc.zig");
const regex = @import("../regex/regex.zig");
const find_mod = @import("find.zig");
const gitignore = @import("gitignore.zig");
const text_field = @import("../ui/text_field.zig");
const EditOp = @import("../editor/edit_op.zig").EditOp;

pub const table = .{
    .@"find.grep" = &grepCmd,
    .@"find.grep_replace" = &grepReplaceCmd,
    .@"grep.open" = &openRowCmd,
    .@"grep.toggle_hit" = &toggleHitCmd,
    .@"grep.copy" = &copyCmd,
    .@"grep.enable_all" = &enableAllCmd,
    .@"grep.disable_all" = &disableAllCmd,
    .@"grep.expand_all" = &expandAllCmd,
    .@"grep.collapse_all" = &collapseAllCmd,
    .@"grep.refresh" = &refreshCmd,
};

/// Hits past this are dropped; the pane says so.
pub const max_hits: usize = 5000;
/// A file the walk backend will not read past.
pub const max_file_bytes: usize = 1024 * 1024;
/// Hits per posted batch.
pub const batch_size: usize = 64;

pub const Backend = enum {
    /// `git grep -n --column`: the tracked files only, so `.gitignore`
    /// and untracked scratch never answer. The SEARCH section's first
    /// choice in a repo (Rust's `16 hits (git grep)`).
    git_grep,
    rg,
    walk,

    pub fn label(b: Backend) []const u8 {
        return switch (b) {
            .git_grep => "git grep",
            .rg => "rg",
            .walk => "walk",
        };
    }
};

/// The `Result.pane` the SEARCH section's runs carry: no pane owns
/// them, `handle` hands them to `search_section.handle`.
pub const section_target: PaneId = std.math.maxInt(PaneId);

pub const Flags = struct {
    /// Off = smart case (upper-case in the query turns it on).
    case_sensitive: bool = false,
    whole_word: bool = false,
    /// On: the query is a pattern (rg's syntax under rg, a vim pattern
    /// under the walk). Off: a literal.
    regex: bool = false,
};

pub const Hit = struct {
    /// Absolute path. Borrowed from the pane's snapshot arena.
    path: []const u8,
    /// Root-relative, for display.
    rel: []const u8,
    /// 1-based.
    line: u32,
    /// 0-based byte column of the match on the line.
    col: u32,
    /// Match length in bytes.
    len: u32,
    /// The line, newline stripped — or a window of it around the match
    /// (`windowLine`) when the line is long. `col` is the line's column
    /// either way; `col - text_off` is the match's offset in `text`.
    text: []const u8,
    /// Byte offset of `text` on the line; 0 when `text` is the whole line.
    text_off: u32 = 0,

    /// The match's byte offset within `text`.
    pub fn textCol(h: Hit) usize {
        return h.col -| h.text_off;
    }
};

/// Bytes of the line kept ahead of a match and past its end. A minified
/// file has lines of half a megabyte; a hit stores what a row can show
/// (`grep_view` paints `…` + ~40 cells before the match) plus a tail
/// that survives the `/` filter. Both edges land on UTF-8 boundaries.
pub const window_before: usize = 128;
pub const window_after: usize = 512;

pub const Window = struct { text: []const u8, off: u32 };

pub fn windowLine(line: []const u8, col: u32, len: u32) Window {
    if (line.len <= window_before + window_after) return .{ .text = line, .off = 0 };
    var start: usize = @as(usize, col) -| window_before;
    while (start > 0 and start < line.len and (line[start] & 0xC0) == 0x80) start -= 1;
    var end: usize = @min(line.len, @as(usize, col) + len + window_after);
    while (end < line.len and (line[end] & 0xC0) == 0x80) end += 1;
    if (start >= end) return .{ .text = line, .off = 0 };
    return .{ .text = line[start..end], .off = @intCast(start) };
}

/// One batch from the worker. Owned by the event until `handle`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    hits: std.ArrayListUnmanaged(Hit) = .empty,
    generation: u32,
    pane: PaneId,
    backend: Backend,
    /// The last batch of the run.
    done: bool = false,
    /// The run stopped at `max_hits`.
    truncated: bool = false,
    /// Why the run produced nothing (no rg, unreadable root).
    err: ?[]const u8 = null,

    pub fn create(gpa: Allocator, generation: u32, pane: PaneId, backend: Backend) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .generation = generation, .pane = pane, .backend = backend };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The generation the worker was started with; it stops between
/// batches (and between files) when the pane has moved on.
pub const Abort = struct { generation: std.atomic.Value(u32) = .init(0) };

pub const Group = struct {
    rel: []const u8,
    /// Index of the first hit of this file in `hits`.
    first: u32,
    count: u32,
    collapsed: bool,
};

pub const Row = union(enum) { file: u32, hit: u32 };

/// `Pane.grep`.
pub const GrepPane = struct {
    gpa: Allocator,
    /// Heap-allocated, like `abort` and for the same reason: a pane
    /// lives in `PaneStore.slots`, which is an ArrayList, so opening
    /// ANY other pane while a run is in flight moves this struct. An
    /// `Io.Group` cannot be moved once it has a task — the task holds
    /// its address — and a moved one made `cancel` wait forever, which
    /// is a wedged quit. // changed (session-kinds): a session restore
    /// opens a Search pane and then keeps opening panes behind it, so
    /// the move is the ordinary case rather than a rare race.
    group: *Io.Group,
    snapshot: alloc.SnapshotArena,
    /// Owned. The worker reads it; a rerun cancels the worker first.
    query: []u8,
    /// Owned: the workspace root the run is scoped to.
    root: []u8,
    flags: Flags = .{},
    backend: ?Backend = null,
    hits: std.ArrayListUnmanaged(Hit) = .empty,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// Hit indices `find.grep_replace` skips.
    disabled: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Files folded shut, by rel path (owned keys).
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    filter: text_field.Buf = .empty,
    filter_caret: usize = 0,
    filter_active: bool = false,
    loading: bool = false,
    truncated: bool = false,
    /// The last run's reason for nothing, toasted once and shown.
    err: ?[]u8 = null,
    /// Heap-allocated: the worker holds it past the pane's moves.
    abort: *Abort,
    generation: u32 = 0,
    /// // changed (session-kinds): the row a restored Search pane was
    /// on. The hits arrive batch by batch long after the pane opens,
    /// and every batch clamps the cursor to the rows it has, so the
    /// saved row is put back once — when the run says it is done.
    restore_cursor: ?usize = null,

    pub fn init(gpa: Allocator, root: []const u8, query: []const u8) Allocator.Error!GrepPane {
        const abort = try gpa.create(Abort);
        errdefer gpa.destroy(abort);
        abort.* = .{};
        const grp = try gpa.create(Io.Group);
        errdefer gpa.destroy(grp);
        grp.* = .init;
        const q = try gpa.dupe(u8, query);
        errdefer gpa.free(q);
        const r = try gpa.dupe(u8, root);
        errdefer gpa.free(r);
        return .{ .gpa = gpa, .snapshot = alloc.SnapshotArena.init(gpa), .abort = abort, .group = grp, .query = q, .root = r };
    }

    pub fn deinit(self: *GrepPane, io: Io) void {
        self.abort.generation.store(std.math.maxInt(u32), .release);
        self.group.cancel(io);
        self.gpa.destroy(self.group);
        self.gpa.destroy(self.abort);
        self.gpa.free(self.query);
        self.gpa.free(self.root);
        self.hits.deinit(self.gpa);
        self.groups.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.disabled.deinit(self.gpa);
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.collapsed.deinit(self.gpa);
        self.filter.deinit(self.gpa);
        if (self.err) |e| self.gpa.free(e);
        self.snapshot.deinit();
    }

    pub fn enabledCount(self: *const GrepPane) usize {
        return self.hits.items.len - self.disabled.count();
    }

    pub fn fileCount(self: *const GrepPane) usize {
        return self.groups.items.len;
    }

    /// The hit under the cursor, if the cursor row is one.
    pub fn selectedHit(self: *const GrepPane) ?u32 {
        if (self.cursor >= self.rows.items.len) return null;
        return switch (self.rows.items[self.cursor]) {
            .hit => |i| i,
            .file => null,
        };
    }

    pub fn isDisabled(self: *const GrepPane, hit: u32) bool {
        return self.disabled.contains(hit);
    }

    pub fn toggleHit(self: *GrepPane, hit: u32) Allocator.Error!void {
        if (self.disabled.fetchRemove(hit) == null) try self.disabled.put(self.gpa, hit, {});
    }

    /// Whether `hit` survives the `/` filter (a vim pattern, or a
    /// case-insensitive substring when it does not compile).
    fn passesFilter(self: *const GrepPane, re: ?*regex.Regex, hit: Hit) bool {
        const f = self.filter.items;
        if (f.len == 0) return true;
        if (re) |r| return r.find(hit.text, 0) != null or r.find(hit.rel, 0) != null;
        return containsIgnoreCase(hit.text, f) or containsIgnoreCase(hit.rel, f);
    }

    /// A case-insensitive substring test (ASCII folding).
    fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > hay.len) return false;
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Groups and rows from `hits`, the filter and the folds.
    pub fn rebuild(self: *GrepPane) Allocator.Error!void {
        self.groups.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        var re: ?regex.Regex = if (self.filter.items.len > 0) regex.Regex.compile(self.filter.items, .{ .ignore_case = !find_mod.hasUpper(self.filter.items) }) catch null else null;
        defer if (re) |*r| r.deinit();
        var i: usize = 0;
        while (i < self.hits.items.len) {
            const rel = self.hits.items[i].rel;
            var j = i;
            var kept: u32 = 0;
            var group_idx: ?usize = null;
            while (j < self.hits.items.len and std.mem.eql(u8, self.hits.items[j].rel, rel)) : (j += 1) {
                if (!self.passesFilter(if (re) |*r| r else null, self.hits.items[j])) continue;
                if (group_idx == null) {
                    group_idx = self.groups.items.len;
                    try self.groups.append(self.gpa, .{ .rel = rel, .first = @intCast(j), .count = 0, .collapsed = self.collapsed.contains(rel) });
                    try self.rows.append(self.gpa, .{ .file = @intCast(group_idx.?) });
                }
                kept += 1;
                if (!self.groups.items[group_idx.?].collapsed) try self.rows.append(self.gpa, .{ .hit = @intCast(j) });
            }
            if (group_idx) |g| self.groups.items[g].count = kept;
            i = j;
        }
        if (self.cursor >= self.rows.items.len) self.cursor = self.rows.items.len -| 1;
    }

    pub fn setCollapsed(self: *GrepPane, rel: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (self.collapsed.contains(rel)) return;
            const key = try self.gpa.dupe(u8, rel);
            errdefer self.gpa.free(key);
            try self.collapsed.put(self.gpa, key, {});
        } else if (self.collapsed.fetchRemove(rel)) |kv| self.gpa.free(kv.key);
    }

    /// A new run: everything from the last one goes.
    fn clearResults(self: *GrepPane) void {
        self.hits.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.disabled.clearRetainingCapacity();
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.collapsed.clearRetainingCapacity();
        self.snapshot.reset();
        self.cursor = 0;
        self.scroll = 0;
        self.truncated = false;
        self.backend = null;
        if (self.err) |e| self.gpa.free(e);
        self.err = null;
    }
};

// ─── open / run ─────────────────────────────────────────────────────────

pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.grep);
}

/// `search.toggle_regex` with no SEARCH section shown
/// (`search_section.zig` owns the ids): flip the Search pane's regex
/// flag and rerun the query. The flag was inherited from the editor's
/// find bar and could not be changed in the pane.
pub fn paneToggleRegex(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = find(app) orelse return app.diag.fail(arena, "no Search pane — find.grep opens one", .{});
    const pane = app.panes.get(id) orelse return error.Failed;
    pane.grep.flags.regex = !pane.grep.flags.regex;
    app.toast("search regex: {s}", .{if (pane.grep.flags.regex) "on" else "off"});
    try refresh(app, id);
}

/// `search.toggle_case_sensitive` with no SEARCH section shown: flip
/// the Search pane's flag and rerun; `app.search_case` follows it so
/// the find bar and `:s` agree (`:set ic` / `noic` write the same
/// slot). With no Search pane the editor-wide flag alone flips — smart
/// case (null) counts as off.
pub fn paneToggleCase(app: *App) CommandError!void {
    const on = !(app.search_case orelse false);
    app.search_case = on;
    if (find(app)) |id| {
        const pane = app.panes.get(id) orelse return error.Failed;
        pane.grep.flags.case_sensitive = on;
        app.toast("search: case-sensitive {s}", .{if (on) "on" else "off"});
        return refresh(app, id);
    }
    app.toast("search: case-sensitive {s}", .{if (on) "on" else "off"});
}

/// `search.toggle_whole_word` with no SEARCH section shown: the Search
/// pane's whole-word flag, rerun. Nothing else holds the flag, so no
/// pane is a failure — as `search.toggle_regex`.
pub fn paneToggleWholeWord(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = find(app) orelse return app.diag.fail(arena, "no Search pane — find.grep opens one", .{});
    const pane = app.panes.get(id) orelse return error.Failed;
    pane.grep.flags.whole_word = !pane.grep.flags.whole_word;
    app.toast("search: whole-word {s}", .{if (pane.grep.flags.whole_word) "on" else "off"});
    try refresh(app, id);
}

/// `find.grep`: the query prompt, prefilled with the active find query
/// — seeded as a selection, so typing replaces it (VS Code's search box
/// keeps the last query selected) and Enter reruns it.
fn grepCmd(app: *App) CommandError!void {
    try openQueryPrompt(app);
}

pub fn openQueryPrompt(app: *App) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, "Find in files");
    state.placeholder = "pattern — rg when installed, else a vim pattern";
    if (app.activeEditor()) |e| if (e.find.query.items.len > 0) try state.seed(app.gpa, e.find.query.items);
    if (find(app)) |id| if (app.panes.get(id)) |p| if (state.buf.items.len == 0) try state.seed(app.gpa, p.grep.query);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .grep_query } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The query prompt's accept.
pub fn acceptQuery(app: *App, text: []const u8) Allocator.Error!void {
    const q = std.mem.trim(u8, text, " \t");
    if (q.len == 0) return;
    runGrep(app, q) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
}

/// Run `query` (the pane's flags kept). One grep pane per app: an
/// existing one reruns in place and is revealed; a new one opens
/// beside the active pane. Scoped to the primary workspace, as VS
/// Code's Ctrl+Shift+F is.
pub fn runGrep(app: *App, query: []const u8) CommandError!void {
    if (find(app)) |id| {
        const p = &app.panes.get(id).?.grep;
        if (!std.mem.eql(u8, p.query, query)) {
            // The worker reads `query`: stop it before the swap.
            p.abort.generation.store(std.math.maxInt(u32), .release);
            p.group.cancel(app.io);
            const q = try app.gpa.dupe(u8, query);
            app.gpa.free(p.query);
            p.query = q;
        }
        app.showPane(id);
        app.focus = .{ .pane = id };
        try refresh(app, id);
        return;
    }
    var pane = try GrepPane.init(app.gpa, app.workspace, query);
    errdefer pane.deinit(app.io);
    if (app.activeEditor()) |e| pane.flags.regex = e.find.regex;
    const id = try app.panes.add(.{ .grep = pane });
    pane = undefined; // moved into the store
    const layout = app.layouts.current();
    if (app.active) |cur| if (layout.leafOf(cur) != null) {
        _ = layout.split(cur, .horizontal, id) catch {};
    };
    app.showPane(id);
    app.focus = .{ .pane = id };
    try refresh(app, id);
}

/// A saved Search pane back (`session.zig`): the query re-run with the
/// options it was run with, landing on the row it was on. One pane per
/// app as `runGrep` has it, so a restore into a live app re-uses the
/// Search pane that is already open rather than opening a second.
/// Placement is not this function's business — the restore replaces
/// every split tree wholesale once the panes are back.
/// // changed (session-kinds).
pub fn restorePane(app: *App, query: []const u8, flags: Flags, cursor: usize) Allocator.Error!?PaneId {
    if (query.len == 0) return null;
    const id = if (find(app)) |existing| blk: {
        const p = &app.panes.get(existing).?.grep;
        // The worker reads `query`: stop it before the swap.
        p.abort.generation.store(std.math.maxInt(u32), .release);
        p.group.cancel(app.io);
        const q = try app.gpa.dupe(u8, query);
        app.gpa.free(p.query);
        p.query = q;
        break :blk existing;
    } else blk: {
        var pane = try GrepPane.init(app.gpa, app.workspace, query);
        errdefer pane.deinit(app.io);
        const fresh = try app.panes.add(.{ .grep = pane });
        pane = undefined; // moved into the store
        break :blk fresh;
    };
    const p = &app.panes.get(id).?.grep;
    p.flags = flags;
    p.restore_cursor = cursor;
    refresh(app, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    return id;
}

/// Restart the worker for the pane's query.
pub fn refresh(app: *App, id: PaneId) CommandError!void {
    const pane = app.panes.get(id) orelse return;
    const p = switch (pane.*) {
        .grep => |*p| p,
        else => return,
    };
    p.abort.generation.store(std.math.maxInt(u32), .release);
    p.group.cancel(app.io);
    p.generation +%= 1;
    p.abort.generation.store(p.generation, .release);
    p.clearResults();
    p.loading = true;
    app.needs_render = true;
    var flags = p.flags;
    if (!flags.case_sensitive and find_mod.hasUpper(p.query)) flags.case_sensitive = true;
    if (app.search_case) |c| flags.case_sensitive = c;
    p.group.concurrent(app.io, worker, .{ &app.events, app.io, app.gpa, @as([]const u8, p.root), @as([]const u8, p.query), flags, p.generation, id, p.abort, false }) catch |err| {
        p.loading = false;
        return app.diag.fail(app.frame.allocator(), "grep: could not start the worker: {s}", .{@errorName(err)});
    };
}

// ─── the worker ─────────────────────────────────────────────────────────

const WorkerError = Io.Cancelable || Allocator.Error;

/// The backends in order: `git grep` first when `git_first` (the SEARCH
/// section — a workspace that is no repo falls through), then `rg`,
/// then the in-process walk.
pub fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, root: []const u8, query: []const u8, flags: Flags, generation: u32, pane: PaneId, abort: *Abort, git_first: bool) Io.Cancelable!void {
    var ctx: Ctx = .{ .events = events, .io = io, .gpa = gpa, .generation = generation, .pane = pane, .abort = abort };
    if (git_first) {
        const git = runGitGrep(&ctx, root, query, flags) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return postOom(events, io, gpa),
        };
        if (git == .ran) return;
    }
    const outcome = runRg(&ctx, root, query, flags) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return postOom(events, io, gpa),
    };
    switch (outcome) {
        .ran => {},
        .no_rg => runWalk(&ctx, root, query, flags) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return postOom(events, io, gpa),
        },
    }
}

fn postOom(events: *event.EventQueue, io: Io, gpa: Allocator) void {
    const owned = gpa.dupe(u8, "out of memory during the search") catch return;
    events.post(io, .{ .err = .{ .source = .grep, .msg = owned } });
}

/// What a worker carries between batches.
const Ctx = struct {
    events: *event.EventQueue,
    io: Io,
    gpa: Allocator,
    generation: u32,
    pane: PaneId,
    abort: *Abort,
    batch: ?*Result = null,
    total: usize = 0,
    truncated: bool = false,
    /// The ripgrep binary; a test points it at a stand-in.
    rg_bin: []const u8 = "rg",
    /// The git binary, likewise.
    git_bin: []const u8 = "git",

    fn stale(c: *const Ctx) bool {
        return c.abort.generation.load(.acquire) != c.generation;
    }

    /// The open batch, started when needed.
    fn open(c: *Ctx, backend: Backend) Allocator.Error!*Result {
        if (c.batch) |b| return b;
        const b = try Result.create(c.gpa, c.generation, c.pane, backend);
        c.batch = b;
        return b;
    }

    /// Add one hit; a full batch is posted at once.
    fn push(c: *Ctx, backend: Backend, path: []const u8, rel: []const u8, line: u32, col: u32, len: u32, text: []const u8) Allocator.Error!void {
        if (c.total >= max_hits) {
            c.truncated = true;
            return;
        }
        const b = try c.open(backend);
        const arena = b.arena.allocator();
        const win = windowLine(text, col, len);
        try b.hits.append(arena, .{
            .path = try arena.dupe(u8, path),
            .rel = try arena.dupe(u8, rel),
            .line = line,
            .col = col,
            .len = len,
            .text = try arena.dupe(u8, win.text),
            .text_off = win.off,
        });
        c.total += 1;
        if (b.hits.items.len >= batch_size) c.flush(false);
    }

    fn flush(c: *Ctx, done: bool) void {
        const b = c.batch orelse return;
        c.batch = null;
        b.done = done;
        b.truncated = c.truncated;
        c.events.post(c.io, .{ .grep = b });
    }

    /// The final post: an empty `done` batch when nothing is open.
    fn finish(c: *Ctx, backend: Backend, err: ?[]const u8) Allocator.Error!void {
        const b = try c.open(backend);
        if (err) |e| b.err = try b.arena.allocator().dupe(u8, e);
        c.flush(true);
    }
};

const RgOutcome = enum { ran, no_rg };

/// rg's `--json` stream: one object per line; `match` objects carry
/// the path, the line and its submatches.
const RgText = struct { text: ?[]const u8 = null };
const RgSub = struct { start: u32 = 0, end: u32 = 0 };
const RgData = struct {
    path: RgText = .{},
    lines: RgText = .{},
    line_number: ?u32 = null,
    submatches: []const RgSub = &.{},
};
const RgMsg = struct { type: []const u8, data: RgData = .{} };

/// Spawn `rg --json` in `root`. `.no_rg` when the binary is missing.
fn runRg(c: *Ctx, root: []const u8, query: []const u8, flags: Flags) WorkerError!RgOutcome {
    const io = c.io;
    const gpa = c.gpa;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ c.rg_bin, "--json", "--no-config", "--no-require-git", "--max-filesize", "1M" });
    try argv.append(gpa, if (flags.case_sensitive) "--case-sensitive" else "--ignore-case");
    if (flags.whole_word) try argv.append(gpa, "--word-regexp");
    if (!flags.regex) try argv.append(gpa, "--fixed-strings");
    try argv.appendSlice(gpa, &.{ "-e", query, "." });
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .no_rg,
    };
    defer child.kill(io);
    const buf = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(buf);
    var fr = child.stdout.?.readerStreaming(io, buf);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var saw_line = false;
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(gpa);
    while (true) {
        if (c.stale()) return .ran;
        const raw = (fr.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => break,
            error.StreamTooLong => break,
        }) orelse break;
        saw_line = true;
        _ = scratch.reset(.retain_capacity);
        const msg = std.json.parseFromSliceLeaky(RgMsg, scratch.allocator(), raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, msg.type, "match")) continue;
        const rel_raw = msg.data.path.text orelse continue;
        const rel = if (std.mem.startsWith(u8, rel_raw, "./")) rel_raw[2..] else rel_raw;
        const text = std.mem.trimEnd(u8, msg.data.lines.text orelse continue, "\r\n");
        const line = msg.data.line_number orelse continue;
        path_buf.clearRetainingCapacity();
        try path_buf.appendSlice(gpa, root);
        try path_buf.append(gpa, '/');
        try path_buf.appendSlice(gpa, rel);
        for (msg.data.submatches) |sm| {
            if (sm.end < sm.start) continue;
            try c.push(.rg, path_buf.items, rel, line, sm.start, sm.end - sm.start, text);
        }
    }
    // rg exits 1 for "no matches" and 2 for a bad pattern — the stream
    // says what happened either way; a process that never spoke and
    // exited with 2 is a pattern rg refused.
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => null,
    };
    if (c.stale()) return .ran;
    var err_msg: ?[]const u8 = null;
    if (!saw_line) if (term) |tm| switch (tm) {
        .exited => |code| if (code == 2) {
            err_msg = "rg refused the pattern";
        },
        else => {},
    };
    try c.finish(.rg, err_msg);
    return .ran;
}

const GitOutcome = enum { ran, no_git };

/// Whether `root` is a repository `git grep` would search: a `.git`
/// entry at the root (a directory, or a worktree's file), else — a
/// directory inside a repository — one `git check-ignore` says it is
/// not ignored (a scratch directory under an ignored `.zig-cache/`
/// would otherwise "run" with nothing, and the next backend never
/// answer). Exit 128 is no repository at all.
fn inRepo(c: *Ctx, root: []const u8) WorkerError!bool {
    const io = c.io;
    var dir = Io.Dir.cwd().openDir(io, root, .{}) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return false;
    };
    defer dir.close(io);
    if (dir.statFile(io, ".git", .{})) |_| return true else |err| if (err == error.Canceled) return error.Canceled;
    var child = std.process.spawn(io, .{
        .argv = &.{ c.git_bin, "check-ignore", "-q", "." },
        .cwd = .{ .path = root },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return term == .exited and term.exited == 1;
}

/// Spawn `git grep -n --column -z` in `root`. `.no_git` when git is
/// missing or the directory is no repository (exit 128), so the next
/// backend answers instead. One hit per line (the first match, as
/// `--column` reports it — Rust counts the same way); the highlight
/// length is the literal's, or the pattern's own match when the walk's
/// engine agrees with git's at that column, else nothing.
fn runGitGrep(c: *Ctx, root: []const u8, query: []const u8, flags: Flags) WorkerError!GitOutcome {
    const io = c.io;
    const gpa = c.gpa;
    if (!(try inRepo(c, root))) return .no_git;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ c.git_bin, "grep", "-n", "--column", "-z", "-I", "--no-color" });
    if (!flags.case_sensitive) try argv.append(gpa, "-i");
    if (flags.whole_word) try argv.append(gpa, "-w");
    try argv.append(gpa, if (flags.regex) "-E" else "-F");
    try argv.appendSlice(gpa, &.{ "-e", query, "--", "." });
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .no_git,
    };
    defer child.kill(io);
    var re: ?regex.Regex = if (flags.regex) regex.Regex.compile(query, .{ .ignore_case = !flags.case_sensitive }) catch null else null;
    defer if (re) |*r| r.deinit();
    const buf = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(buf);
    var fr = child.stdout.?.readerStreaming(io, buf);
    var saw_line = false;
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(gpa);
    while (true) {
        if (c.stale()) return .ran;
        // `-z`: every separator is NUL — `path\0line\0col\0text\n`.
        const rel_raw = (fr.interface.takeDelimiter(0) catch |err| switch (err) {
            error.ReadFailed => break,
            error.StreamTooLong => break,
        }) orelse break;
        const rel = if (std.mem.startsWith(u8, rel_raw, "./")) rel_raw[2..] else rel_raw;
        path_buf.clearRetainingCapacity();
        try path_buf.appendSlice(gpa, root);
        try path_buf.append(gpa, '/');
        try path_buf.appendSlice(gpa, rel);
        const line_s = (fr.interface.takeDelimiter(0) catch break) orelse break;
        const line = std.fmt.parseInt(u32, line_s, 10) catch break;
        const col_s = (fr.interface.takeDelimiter(0) catch break) orelse break;
        const col1 = std.fmt.parseInt(u32, col_s, 10) catch break;
        const rest = (fr.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => break,
            error.StreamTooLong => break,
        }) orelse break;
        saw_line = true;
        const text = std.mem.trimEnd(u8, rest, "\r");
        const col = col1 -| 1;
        const len: u32 = blk: {
            if (re) |*r| {
                if (col < text.len) if (r.find(text, col)) |m| if (m.start == col) break :blk @intCast(m.end - m.start);
                break :blk 0;
            }
            break :blk @intCast(@min(query.len, text.len -| col));
        };
        try c.push(.git_grep, path_buf.items, rel, line, col, len, text);
        if (c.truncated) break;
    }
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => null,
    };
    if (c.stale()) return .ran;
    // 0 hits, 1 none, 128 no repository (or git's own refusal): the
    // first two are answers, the last is not.
    if (!saw_line) if (term) |tm| switch (tm) {
        .exited => |code| if (code != 0 and code != 1) return .no_git,
        else => return .no_git,
    } else return .no_git;
    try c.finish(.git_grep, null);
    return .ran;
}

/// The in-process backend: every file under `root` that the
/// `.gitignore`s allow, matched line by line with `src/regex/`.
fn runWalk(c: *Ctx, root: []const u8, query: []const u8, flags: Flags) WorkerError!void {
    const io = c.io;
    const gpa = c.gpa;
    // A literal query is a `\V` (very nomagic) pattern: only `\` is
    // special, so the user's text means itself.
    var pat: std.ArrayListUnmanaged(u8) = .empty;
    defer pat.deinit(gpa);
    if (flags.whole_word) try pat.appendSlice(gpa, "\\<");
    if (!flags.regex) {
        try pat.appendSlice(gpa, "\\V");
        for (query) |ch| {
            if (ch == '\\') try pat.append(gpa, '\\');
            try pat.append(gpa, ch);
        }
    } else try pat.appendSlice(gpa, query);
    if (flags.whole_word) try pat.appendSlice(gpa, "\\>");
    var re = regex.Regex.compile(pat.items, .{ .ignore_case = !flags.case_sensitive }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern => return c.finish(.walk, "invalid pattern"),
        error.Unsupported => return c.finish(.walk, "pattern uses an item this build does not support"),
        error.TooLong => return c.finish(.walk, "pattern too long"),
    };
    defer re.deinit();
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return c.finish(.walk, "cannot open the workspace");
    };
    defer dir.close(io);
    var ignores = gitignore.Stack.init(gpa);
    defer ignores.deinit();
    try loadIgnore(&ignores, io, gpa, dir, "");
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(gpa);
    while (true) {
        const entry = walker.next(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        } orelse break;
        if (c.stale()) return;
        if (c.truncated) break;
        ignores.popBelow(std.fs.path.dirname(entry.path) orelse "");
        switch (entry.kind) {
            .directory => {
                if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
                if (isArtifactDir(entry.basename)) continue;
                if (ignores.ignored(entry.path, true)) continue;
                walker.enter(io, entry) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    continue;
                };
                var sub = entry.dir.openDir(io, entry.basename, .{}) catch continue;
                defer sub.close(io);
                try loadIgnore(&ignores, io, gpa, sub, entry.path);
            },
            .file => {
                if (ignores.ignored(entry.path, false)) continue;
                try io.checkCancel();
                path_buf.clearRetainingCapacity();
                try path_buf.appendSlice(gpa, root);
                try path_buf.append(gpa, '/');
                try path_buf.appendSlice(gpa, entry.path);
                try grepFile(c, &re, entry.dir, entry.basename, entry.path, path_buf.items);
            },
            else => {},
        }
    }
    try c.finish(.walk, null);
}

/// Push `<dir>/.gitignore` when there is one.
fn loadIgnore(stack: *gitignore.Stack, io: Io, gpa: Allocator, dir: Io.Dir, rel: []const u8) WorkerError!void {
    const text = dir.readFileAlloc(io, ".gitignore", gpa, .limited(256 * 1024)) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    defer gpa.free(text);
    try stack.push(try gitignore.Rules.parse(gpa, rel, text));
}

const artifact_dirs = [_][]const u8{ "node_modules", "__pycache__", "target", "zig-out", "dist", "build", ".git" };

fn isArtifactDir(name: []const u8) bool {
    for (artifact_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

fn grepFile(c: *Ctx, re: *regex.Regex, dir: Io.Dir, basename: []const u8, rel: []const u8, abs: []const u8) WorkerError!void {
    const io = c.io;
    const gpa = c.gpa;
    const content = dir.readFileAlloc(io, basename, gpa, .limited(max_file_bytes)) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    defer gpa.free(content);
    if (std.mem.indexOfScalar(u8, content[0..@min(content.len, 8192)], 0) != null) return;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        var from: usize = 0;
        while (from <= line.len) {
            const m = re.find(line, from) orelse break;
            try c.push(.walk, abs, rel, line_no, @intCast(m.start), @intCast(m.end - m.start), line);
            if (c.truncated) return;
            from = if (m.end > m.start) m.end else m.end + 1;
        }
    }
}

// ─── the handler ────────────────────────────────────────────────────────

pub fn handle(app: *App, result: *Result) Allocator.Error!void {
    if (result.pane == section_target) return @import("search_section.zig").handle(app, result);
    if (result.pane == @import("grep_picker.zig").target) return @import("grep_picker.zig").handle(app, result);
    defer result.destroy(app.gpa);
    const pane = app.panes.get(result.pane) orelse return;
    const p = switch (pane.*) {
        .grep => |*p| p,
        else => return,
    };
    if (result.generation != p.generation) return;
    const arena = p.snapshot.allocator();
    for (result.hits.items) |h| {
        try p.hits.append(p.gpa, .{
            .path = try arena.dupe(u8, h.path),
            .rel = try arena.dupe(u8, h.rel),
            .line = h.line,
            .col = h.col,
            .len = h.len,
            .text = try arena.dupe(u8, h.text),
            .text_off = h.text_off,
        });
    }
    p.backend = result.backend;
    if (result.truncated) p.truncated = true;
    if (result.err) |e| {
        if (p.err) |old| p.gpa.free(old);
        p.err = try p.gpa.dupe(u8, e);
    }
    try p.rebuild();
    if (result.done) {
        p.loading = false;
        if (p.restore_cursor) |row| {
            p.restore_cursor = null;
            p.cursor = @min(row, p.rows.items.len -| 1);
        }
        const n = p.hits.items.len;
        if (p.err) |e| {
            app.toast("{s}: {s}", .{ result.backend.label(), e });
        } else if (n == 0) {
            app.toast("{s}: no matches for \"{s}\"", .{ result.backend.label(), p.query });
        } else {
            app.toast("{s}: {d} match{s} in {d} file{s}{s}", .{ result.backend.label(), n, if (n == 1) "" else "es", p.groups.items.len, if (p.groups.items.len == 1) "" else "s", if (p.truncated) " (capped)" else "" });
        }
    }
    app.needs_render = true;
}

// ─── keys + mouse ───────────────────────────────────────────────────────

pub const hit_title: u32 = 0;
pub const hit_filter: u32 = 1;
pub const row_base: u32 = 0x1000;

fn moveCursor(p: *GrepPane, delta: i64) void {
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(p.rows.items.len -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

pub fn scrollBy(p: *GrepPane, delta: i64) void {
    moveCursor(p, delta);
}

/// `n` / `N`: the next / previous hit in file order, folded files
/// opened on the way, then the hit itself.
fn stepHit(app: *App, id: PaneId, p: *GrepPane, delta: i32) Allocator.Error!void {
    if (p.hits.items.len == 0) return;
    const n: i64 = @intCast(p.hits.items.len);
    var target: i64 = if (p.selectedHit()) |h| @as(i64, h) + delta else if (delta > 0) blk: {
        // From a file row, the first hit of that file.
        if (p.cursor < p.rows.items.len) if (p.rows.items[p.cursor] == .file) break :blk @as(i64, p.groups.items[p.rows.items[p.cursor].file].first);
        break :blk 0;
    } else n - 1;
    target = @mod(target, n);
    const hit: u32 = @intCast(target);
    const rel = p.hits.items[hit].rel;
    if (p.collapsed.contains(rel)) {
        try p.setCollapsed(rel, false);
        try p.rebuild();
    }
    for (p.rows.items, 0..) |r, i| if (r == .hit and r.hit == hit) {
        p.cursor = i;
        break;
    };
    try openHit(app, id, p, hit);
}

/// Open the hit's file in an editor at its line and column (an editor
/// even for markdown — a rendered preview has no cursor to place); the
/// grep pane stays.
pub fn openHit(app: *App, id: PaneId, p: *GrepPane, hit: u32) Allocator.Error!void {
    if (hit >= p.hits.items.len) return;
    const h = p.hits.items[hit];
    const path = try app.frame.allocator().dupe(u8, h.path);
    try app.noteRecent(path);
    const eid = app.openEditor(path) catch |err| {
        app.toast("open {s}: {s}", .{ h.rel, @errorName(err) });
        return;
    };
    if (app.panes.editor(eid)) |e| {
        e.buf.editor.placeCursor(@min(@as(usize, h.line) -| 1, e.buf.editor.lineCount() - 1), h.col);
        e.buf.editor.goal_col = null;
    }
    _ = id;
    app.needs_render = true;
}

fn copySelected(app: *App, p: *GrepPane) Allocator.Error!void {
    const hit = p.selectedHit() orelse return;
    const h = p.hits.items[hit];
    const s = try std.fmt.allocPrint(app.frame.allocator(), "{s}:{d}", .{ h.rel, h.line });
    try app.clipboard.set(s, false);
    app.toast("copied {s}", .{s});
}

fn toggleGroup(p: *GrepPane, g: u32) Allocator.Error!void {
    const grp = p.groups.items[g];
    try p.setCollapsed(grp.rel, !grp.collapsed);
    try p.rebuild();
}

fn setAllCollapsed(p: *GrepPane, on: bool) Allocator.Error!void {
    for (p.groups.items) |g| try p.setCollapsed(g.rel, on);
    try p.rebuild();
}

pub fn handleKey(app: *App, id: PaneId, p: *GrepPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    if (p.filter_active) {
        switch (k.code) {
            .esc => {
                p.filter_active = false;
                p.filter.clearRetainingCapacity();
                p.filter_caret = 0;
                try p.rebuild();
                return true;
            },
            .enter => {
                p.filter_active = false;
                return true;
            },
            else => {},
        }
        switch (try text_field.handleKey(&p.filter, &p.filter_caret, app.gpa, k)) {
            .changed => {
                try p.rebuild();
                return true;
            },
            .moved => return true,
            .ignored => return false,
        }
    }
    const page: i64 = @intCast(@max(app.pane_rows, 1));
    switch (k.code) {
        .down => moveCursor(p, 1),
        .up => moveCursor(p, -1),
        .page_down => moveCursor(p, page),
        .page_up => moveCursor(p, -page),
        .home => p.cursor = 0,
        .end => p.cursor = p.rows.items.len -| 1,
        .enter => try activateRow(app, id, p),
        .right => try foldRow(p, false),
        .left => try foldRow(p, true),
        .esc => {
            if (app.tree.visible) app.focus = .tree;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => moveCursor(p, 1),
                'k' => moveCursor(p, -1),
                'g' => p.cursor = 0,
                'G' => p.cursor = p.rows.items.len -| 1,
                'l' => try foldRow(p, false),
                'h' => try foldRow(p, true),
                'n' => try stepHit(app, id, p, 1),
                'N' => try stepHit(app, id, p, -1),
                ' ' => if (p.selectedHit()) |h| try p.toggleHit(h),
                'A' => p.disabled.clearRetainingCapacity(),
                'D' => {
                    var i: u32 = 0;
                    while (i < p.hits.items.len) : (i += 1) try p.disabled.put(p.gpa, i, {});
                },
                'E' => try setAllCollapsed(p, false),
                'C' => try setAllCollapsed(p, true),
                'r' => refresh(app, id) catch {},
                'R' => try openReplacePrompt(app, id),
                'y' => try copySelected(app, p),
                '/' => p.filter_active = true,
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

fn activateRow(app: *App, id: PaneId, p: *GrepPane) Allocator.Error!void {
    if (p.cursor >= p.rows.items.len) return;
    switch (p.rows.items[p.cursor]) {
        .file => |g| try toggleGroup(p, g),
        .hit => |h| try openHit(app, id, p, h),
    }
}

/// `←` / `h` folds the file under the cursor (from a hit, its file);
/// `→` / `l` opens it.
fn foldRow(p: *GrepPane, on: bool) Allocator.Error!void {
    if (p.cursor >= p.rows.items.len) return;
    const g: u32 = switch (p.rows.items[p.cursor]) {
        .file => |g| g,
        .hit => |h| blk: {
            for (p.groups.items, 0..) |grp, i| if (h >= grp.first and std.mem.eql(u8, grp.rel, p.hits.items[h].rel)) break :blk @intCast(i);
            return;
        },
    };
    const rel = p.groups.items[g].rel;
    if (p.collapsed.contains(rel) == on) return;
    try p.setCollapsed(rel, on);
    try p.rebuild();
    for (p.rows.items, 0..) |r, i| if (r == .file and r.file == g) {
        p.cursor = i;
        break;
    };
}

// ─── the row menu and its commands ──────────────────────────────────────

/// The grep pane the row commands act on: the active one, else the
/// one open.
fn targetPane(app: *App) CommandError!struct { id: PaneId, p: *GrepPane } {
    const id = blk: {
        if (app.active) |a| if (app.panes.get(a)) |pane| if (pane.* == .grep) break :blk a;
        break :blk find(app) orelse return app.diag.fail(app.frame.allocator(), "no grep pane — run find.grep first", .{});
    };
    return .{ .id = id, .p = &app.panes.get(id).?.grep };
}

fn openRowCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    try activateRow(app, tg.id, tg.p);
}

fn toggleHitCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    const h = tg.p.selectedHit() orelse return app.diag.fail(app.frame.allocator(), "grep: the cursor is on a file row", .{});
    try tg.p.toggleHit(h);
    app.needs_render = true;
}

fn copyCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    try copySelected(app, tg.p);
}

fn enableAllCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    tg.p.disabled.clearRetainingCapacity();
    app.needs_render = true;
}

fn disableAllCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    var i: u32 = 0;
    while (i < tg.p.hits.items.len) : (i += 1) try tg.p.disabled.put(tg.p.gpa, i, {});
    app.needs_render = true;
}

fn expandAllCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    try setAllCollapsed(tg.p, false);
    app.needs_render = true;
}

fn collapseAllCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    try setAllCollapsed(tg.p, true);
    app.needs_render = true;
}

fn refreshCmd(app: *App) CommandError!void {
    const tg = try targetPane(app);
    try refresh(app, tg.id);
}

/// A right-click on a row: the row's verbs, titled by the row — the
/// hit's `path:line`, or the file's path.
pub fn openRowMenu(app: *App, p: *GrepPane, x: u16, y: u16) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (p.cursor >= p.rows.items.len) return;
    const is_hit = p.rows.items[p.cursor] == .hit;
    const title: []const u8 = switch (p.rows.items[p.cursor]) {
        .hit => |h| try std.fmt.allocPrint(arena, "{s}:{d}", .{ p.hits.items[h].rel, p.hits.items[h].line }),
        .file => |g| p.groups.items[g].rel,
    };
    var rows: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    try rows.append(app.gpa, .{ .label = if (is_hit) "Open" else "Fold / unfold", .action = .{ .command = .@"grep.open" } });
    if (is_hit) {
        const enabled = if (p.selectedHit()) |h| !p.disabled.contains(h) else true;
        try rows.append(app.gpa, .{ .label = if (enabled) "Skip this hit on replace" else "Include this hit on replace", .action = .{ .command = .@"grep.toggle_hit" } });
        try rows.append(app.gpa, .{ .label = "Copy path:line + text", .action = .{ .command = .@"grep.copy" } });
    }
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Include every hit", .action = .{ .command = .@"grep.enable_all" }, .separator_before = true },
        .{ .label = "Skip every hit", .action = .{ .command = .@"grep.disable_all" } },
        .{ .label = "Replace in files…", .action = .{ .command = .@"find.grep_replace" } },
        .{ .label = "Expand all", .action = .{ .command = .@"grep.expand_all" }, .separator_before = true },
        .{ .label = "Collapse all", .action = .{ .command = .@"grep.collapse_all" } },
        .{ .label = "Search again", .action = .{ .command = .@"grep.refresh" }, .separator_before = true },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(title, owned, x, y);
}

/// A click on a row selects it; a second click on the selected row
/// activates it (opens the hit, folds the file); a right-click opens
/// the row menu. The title toggles nothing; the filter row focuses the
/// filter.
pub fn click(app: *App, id: PaneId, p: *GrepPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    app.needs_render = true;
    if (hit_id >= row_base) {
        const i: usize = hit_id - row_base;
        if (i >= p.rows.items.len) return;
        if (m.button == .right) {
            p.cursor = i;
            app.setActive(id);
            return openRowMenu(app, p, m.x, m.y);
        }
        if (m.button != .left) return;
        if (p.cursor == i) {
            try activateRow(app, id, p);
        } else {
            p.cursor = i;
            if (p.rows.items[i] == .file) try activateRow(app, id, p);
        }
        return;
    }
    switch (hit_id) {
        hit_filter => p.filter_active = true,
        else => {},
    }
}

// ─── replace ────────────────────────────────────────────────────────────

fn grepReplaceCmd(app: *App) CommandError!void {
    const id = find(app) orelse return app.diag.fail(app.frame.allocator(), "no grep pane — run find.grep first", .{});
    try openReplacePrompt(app, id);
}

pub fn openReplacePrompt(app: *App, id: PaneId) Allocator.Error!void {
    const p = &(app.panes.get(id) orelse return).grep;
    const n = p.enabledCount();
    if (n == 0) {
        app.toast("no grep hits to replace", .{});
        return;
    }
    const title = try std.fmt.allocPrint(app.gpa, "Replace {d}× \"{s}\" in {d} file{s} with", .{ n, p.query, p.groups.items.len, if (p.groups.items.len == 1) "" else "s" });
    errdefer app.gpa.free(title);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, title), .purpose = .grep_replace, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const ReplaceReport = struct {
    replaced: usize = 0,
    files: usize = 0,
    skipped_dirty: usize = 0,
    stale: usize = 0,
    io_errors: usize = 0,
};

/// One enabled hit re-located in the live text: the byte range it
/// still occupies, or null when the text under it moved.
fn locate(text: []const u8, line_starts: []const usize, h: Hit) ?regex.Range {
    if (h.line == 0 or h.line > line_starts.len) return null;
    const start = line_starts[h.line - 1] + h.col;
    const end = start + h.len;
    if (end > text.len) return null;
    if (h.col < h.text_off) return null;
    const tc = h.textCol();
    if (tc + h.len > h.text.len) return null;
    if (!std.mem.eql(u8, text[start..end], h.text[tc .. tc + h.len])) return null;
    return .{ .start = start, .end = end };
}

fn lineStarts(gpa: Allocator, text: []const u8) Allocator.Error![]usize {
    var out: std.ArrayListUnmanaged(usize) = .empty;
    try out.append(gpa, 0);
    for (text, 0..) |ch, i| if (ch == '\n') try out.append(gpa, i + 1);
    return out.toOwnedSlice(gpa);
}

/// The text a hit becomes: `replacement` expanded with the groups of
/// the pattern re-matched at the hit when the query is a vim pattern
/// this build can compile, else the literal.
fn expanded(arena: Allocator, re: ?*regex.Regex, replacement: []const u8, text: []const u8, r: regex.Range) Allocator.Error![]const u8 {
    if (re) |rx| if (rx.find(text, r.start)) |m| if (m.start == r.start) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try regex.expandReplacement(arena, &out, replacement, text, m);
        return out.items;
    };
    return replacement;
}

/// `find.grep_replace`'s accept: every enabled hit, file by file.
pub fn acceptReplace(app: *App, replacement: []const u8) Allocator.Error!void {
    const id = find(app) orelse return;
    const p = &app.panes.get(id).?.grep;
    const report = try replaceAll(app, id, p, replacement);
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    const arena = app.frame.allocator();
    try appendf(&msg, arena, "replaced {d} in {d} file{s}", .{ report.replaced, report.files, if (report.files == 1) "" else "s" });
    if (report.skipped_dirty > 0) try appendf(&msg, arena, " · {d} unsaved buffer{s} skipped — save first", .{ report.skipped_dirty, if (report.skipped_dirty == 1) "" else "s" });
    if (report.stale > 0) try appendf(&msg, arena, " · {d} stale hit{s}", .{ report.stale, if (report.stale == 1) "" else "s" });
    if (report.io_errors > 0) try appendf(&msg, arena, " · {d} file{s} not written", .{ report.io_errors, if (report.io_errors == 1) "" else "s" });
    try app.toastLevel(if (report.skipped_dirty > 0 or report.io_errors > 0) .warn else .info, "{s}", .{msg.items});
    refresh(app, id) catch {};
}

fn appendf(out: *std.ArrayListUnmanaged(u8), arena: Allocator, comptime f: []const u8, args: anytype) Allocator.Error!void {
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, f, args));
}

pub fn replaceAll(app: *App, id: PaneId, p: *GrepPane, replacement: []const u8) Allocator.Error!ReplaceReport {
    _ = id;
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    var report: ReplaceReport = .{};
    var re: ?regex.Regex = if (p.flags.regex) regex.Regex.compile(p.query, .{ .ignore_case = !(p.flags.case_sensitive or find_mod.hasUpper(p.query)) }) catch null else null;
    defer if (re) |*r| r.deinit();
    var i: usize = 0;
    while (i < p.hits.items.len) {
        const path = p.hits.items[i].path;
        var j = i;
        var enabled: std.ArrayListUnmanaged(u32) = .empty;
        defer enabled.deinit(gpa);
        while (j < p.hits.items.len and std.mem.eql(u8, p.hits.items[j].path, path)) : (j += 1) {
            if (!p.isDisabled(@intCast(j))) try enabled.append(gpa, @intCast(j));
        }
        i = j;
        if (enabled.items.len == 0) continue;
        if (app.panes.findPath(path)) |eid| {
            const e = app.panes.editor(eid) orelse continue;
            if (e.buf.doc.dirty) {
                report.skipped_dirty += 1;
                continue;
            }
            const text = e.buf.editor.bytes();
            const starts = try lineStarts(gpa, text);
            defer gpa.free(starts);
            var ops: std.ArrayListUnmanaged(EditOp) = .empty;
            var k = enabled.items.len;
            while (k > 0) {
                k -= 1;
                const h = p.hits.items[enabled.items[k]];
                const r = locate(text, starts, h) orelse {
                    report.stale += 1;
                    continue;
                };
                try ops.append(arena, .{ .replace_range = .{ .start = r.start, .end = r.end, .text = try expanded(arena, if (re) |*rx| rx else null, replacement, text, r) } });
            }
            if (ops.items.len == 0) continue;
            const atomic: EditOp = .{ .atomic = ops.items };
            if (!try app.applyOps(e, &.{atomic})) continue;
            report.replaced += ops.items.len;
            report.files += 1;
            // Saved, so the rerun and the LSP see the new text.
            const rel = app.relPath(path);
            app.hooks.emit(app, .{ .save_pre = .{ .path = rel, .pane = eid } });
            e.buf.save(app.io) catch {
                report.io_errors += 1;
                continue;
            };
            app.hooks.emit(app, .{ .save_post = .{ .path = rel, .pane = eid, .bytes = e.buf.editor.len() } });
        } else {
            const text = Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(16 * 1024 * 1024)) catch {
                report.io_errors += 1;
                continue;
            };
            defer gpa.free(text);
            const starts = try lineStarts(gpa, text);
            defer gpa.free(starts);
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(gpa);
            var copied: usize = 0;
            var n_here: usize = 0;
            for (enabled.items) |hi| {
                const h = p.hits.items[hi];
                const r = locate(text, starts, h) orelse {
                    report.stale += 1;
                    continue;
                };
                if (r.start < copied) continue;
                try out.appendSlice(gpa, text[copied..r.start]);
                try out.appendSlice(gpa, try expanded(arena, if (re) |*rx| rx else null, replacement, text, r));
                copied = r.end;
                n_here += 1;
            }
            if (n_here == 0) continue;
            try out.appendSlice(gpa, text[copied..]);
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {
                report.io_errors += 1;
                continue;
            };
            report.replaced += n_here;
            report.files += 1;
        }
    }
    return report;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

const Fixture = struct {
    app: App,
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "src/deep");
        try tmp.dir.createDirPath(t.io, "build");
        try tmp.dir.writeFile(t.io, .{ .sub_path = "src/a.zig", .data = "const alpha = 1;\nconst beta = alpha + alpha;\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "src/deep/b.txt", .data = "Alpha at the top\nnothing here\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "build/out.log", .data = "alpha alpha alpha\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.md", .data = "# alpha\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 30 });
        errdefer app.deinit();
        app.tree.visible = false;
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// Tick until the run lands (or `max` ticks pass).
    fn settle(f: *Fixture, id: PaneId, max: usize) !void {
        var i: usize = 0;
        while (i < max) : (i += 1) {
            try f.app.tick(App.nowMs(t.io));
            const p = &f.app.panes.get(id).?.grep;
            if (!p.loading) return;
            t.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return screen_mod.toTestText(t.allocator, &f.app.screen);
    }

    fn read(f: *Fixture, rel: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(t.io, rel, t.allocator, .limited(1 << 20));
    }
};

/// The walk backend, driven directly (no rg on PATH needed).
fn walkInto(f: *Fixture, query: []const u8, flags: Flags) !*Result {
    var abort: Abort = .{};
    abort.generation.store(1, .release);
    var ctx: Ctx = .{ .events = &f.app.events, .io = t.io, .gpa = t.allocator, .generation = 1, .pane = 0, .abort = &abort };
    try runWalk(&ctx, f.root, query, flags);
    var buf: [8]event.AppEvent = undefined;
    var merged = try Result.create(t.allocator, 1, 0, .walk);
    errdefer merged.destroy(t.allocator);
    while (true) {
        const n = f.app.events.drain(t.io, &buf);
        if (n == 0) break;
        for (buf[0..n]) |ev| {
            defer event.freeEvent(t.allocator, ev);
            if (ev != .grep) continue;
            const b = ev.grep;
            const arena = merged.arena.allocator();
            for (b.hits.items) |h| try merged.hits.append(arena, .{ .path = try arena.dupe(u8, h.path), .rel = try arena.dupe(u8, h.rel), .line = h.line, .col = h.col, .len = h.len, .text = try arena.dupe(u8, h.text), .text_off = h.text_off });
            if (b.err) |e| merged.err = try arena.dupe(u8, e);
            merged.done = b.done;
        }
    }
    return merged;
}

test "walk backend: literal + smart case, .gitignore honoured, whole word, a vim pattern, a bad one" {
    var f = try Fixture.init();
    defer f.deinit();
    // Literal, smart case off: 3 hits in src/a.zig, 1 in b.txt (Alpha), 1 in notes.md; build/out.log is ignored.
    var r = try walkInto(&f, "alpha", .{});
    defer r.destroy(t.allocator);
    try t.expectEqual(@as(usize, 5), r.hits.items.len);
    try t.expect(r.done);
    for (r.hits.items) |h| try t.expect(std.mem.indexOf(u8, h.rel, ".log") == null);
    // Case-sensitive: `Alpha` alone.
    var r2 = try walkInto(&f, "Alpha", .{ .case_sensitive = true });
    defer r2.destroy(t.allocator);
    try t.expectEqual(@as(usize, 1), r2.hits.items.len);
    try t.expectEqualStrings("src/deep/b.txt", r2.hits.items[0].rel);
    try t.expectEqual(@as(u32, 1), r2.hits.items[0].line);
    try t.expectEqual(@as(u32, 0), r2.hits.items[0].col);
    try t.expectEqual(@as(u32, 5), r2.hits.items[0].len);
    try t.expectEqualStrings("Alpha at the top", r2.hits.items[0].text);
    // Whole word: `alpha` inside `alphabet` would not count — and `# alpha` does.
    var r3 = try walkInto(&f, "alph", .{ .whole_word = true });
    defer r3.destroy(t.allocator);
    try t.expectEqual(@as(usize, 0), r3.hits.items.len);
    // A vim pattern: `\<\a\+ = ` (an identifier followed by ` = `).
    var r4 = try walkInto(&f, "\\<\\a\\+ = ", .{ .regex = true });
    defer r4.destroy(t.allocator);
    try t.expectEqual(@as(usize, 2), r4.hits.items.len);
    try t.expectEqual(@as(u32, 6), r4.hits.items[0].col);
    // A literal with a regex metachar means itself.
    var r5 = try walkInto(&f, "alpha + alpha", .{});
    defer r5.destroy(t.allocator);
    try t.expectEqual(@as(usize, 1), r5.hits.items.len);
    // A bad pattern says so and matches nothing.
    var r6 = try walkInto(&f, "\\(x", .{ .regex = true });
    defer r6.destroy(t.allocator);
    try t.expectEqual(@as(usize, 0), r6.hits.items.len);
    try t.expectEqualStrings("invalid pattern", r6.err.?);
}

test "rg backend: the same tree through `rg --json` (skipped without rg on PATH)" {
    var f = try Fixture.init();
    defer f.deinit();
    var abort: Abort = .{};
    abort.generation.store(1, .release);
    var ctx: Ctx = .{ .events = &f.app.events, .io = t.io, .gpa = t.allocator, .generation = 1, .pane = 0, .abort = &abort };
    const outcome = try runRg(&ctx, f.root, "alpha", .{});
    if (outcome == .no_rg) return error.SkipZigTest;
    var buf: [8]event.AppEvent = undefined;
    var n_hits: usize = 0;
    var done = false;
    var backend: ?Backend = null;
    while (true) {
        const n = f.app.events.drain(t.io, &buf);
        if (n == 0) break;
        for (buf[0..n]) |ev| {
            defer event.freeEvent(t.allocator, ev);
            if (ev != .grep) continue;
            n_hits += ev.grep.hits.items.len;
            done = done or ev.grep.done;
            backend = ev.grep.backend;
            for (ev.grep.hits.items) |h| {
                try t.expect(std.mem.indexOf(u8, h.rel, ".log") == null);
                try t.expect(std.fs.path.isAbsolute(h.path));
                try t.expect(!std.mem.startsWith(u8, h.rel, "./"));
            }
        }
    }
    try t.expect(done);
    try t.expectEqual(Backend.rg, backend.?);
    try t.expectEqual(@as(usize, 5), n_hits);
}

test "rg backend: a stand-in rg proves the --json stream is parsed, `./` stripped, exit 2 reported" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(t.io, "bin");
    // A script that speaks rg's --json for `alpha` and refuses `BAD` with exit 2.
    const script =
        \\#!/bin/sh
        \\case "$*" in *BAD*) exit 2;; esac
        \\printf '%s\n' '{"type":"begin","data":{"path":{"text":"./src/a.zig"}}}'
        \\printf '%s\n' '{"type":"match","data":{"path":{"text":"./src/a.zig"},"lines":{"text":"const alpha = 1;\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"alpha"},"start":6,"end":11}]}}'
        \\printf '%s\n' '{"type":"match","data":{"path":{"text":"./src/a.zig"},"lines":{"text":"const beta = alpha + alpha;\n"},"line_number":2,"absolute_offset":17,"submatches":[{"match":{"text":"alpha"},"start":13,"end":18},{"match":{"text":"alpha"},"start":21,"end":26}]}}'
        \\printf '%s\n' '{"type":"end","data":{"path":{"text":"./src/a.zig"},"binary_offset":null,"stats":{}}}'
        \\printf '%s\n' '{"type":"match","data":{"path":{"text":"./src/deep/b.txt"},"lines":{"text":"Alpha at the top\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"Alpha"},"start":0,"end":5}]}}'
        \\printf '%s\n' '{"type":"summary","data":{"elapsed_total":{},"stats":{}}}'
        \\exit 0
        \\
    ;
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/rg", .data = script, .flags = .{ .permissions = .executable_file } });
    const bin = try std.fs.path.join(t.allocator, &.{ f.root, "bin/rg" });
    defer t.allocator.free(bin);
    var abort: Abort = .{};
    abort.generation.store(1, .release);
    var ctx: Ctx = .{ .events = &f.app.events, .io = t.io, .gpa = t.allocator, .generation = 1, .pane = 0, .abort = &abort, .rg_bin = bin };
    try t.expectEqual(RgOutcome.ran, try runRg(&ctx, f.root, "alpha", .{}));
    var buf: [8]event.AppEvent = undefined;
    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    defer hits.deinit(t.allocator);
    var keep = std.heap.ArenaAllocator.init(t.allocator);
    defer keep.deinit();
    var done = false;
    while (true) {
        const n = f.app.events.drain(t.io, &buf);
        if (n == 0) break;
        for (buf[0..n]) |ev| {
            defer event.freeEvent(t.allocator, ev);
            if (ev != .grep) continue;
            for (ev.grep.hits.items) |h| try hits.append(t.allocator, .{ .path = try keep.allocator().dupe(u8, h.path), .rel = try keep.allocator().dupe(u8, h.rel), .line = h.line, .col = h.col, .len = h.len, .text = try keep.allocator().dupe(u8, h.text) });
            done = done or ev.grep.done;
            try t.expectEqual(Backend.rg, ev.grep.backend);
        }
    }
    try t.expect(done);
    try t.expectEqual(@as(usize, 4), hits.items.len);
    try t.expectEqualStrings("src/a.zig", hits.items[0].rel);
    try t.expect(std.mem.endsWith(u8, hits.items[0].path, "/src/a.zig"));
    try t.expect(std.fs.path.isAbsolute(hits.items[0].path));
    try t.expectEqual(@as(u32, 2), hits.items[2].line);
    try t.expectEqual(@as(u32, 21), hits.items[2].col);
    try t.expectEqual(@as(u32, 5), hits.items[2].len);
    try t.expectEqualStrings("const beta = alpha + alpha;", hits.items[2].text);
    try t.expectEqualStrings("src/deep/b.txt", hits.items[3].rel);
    // Exit 2 with no output: the run reports the refusal.
    try t.expectEqual(RgOutcome.ran, try runRg(&ctx, f.root, "BAD", .{}));
    var said: ?[]const u8 = null;
    while (true) {
        const n = f.app.events.drain(t.io, &buf);
        if (n == 0) break;
        for (buf[0..n]) |ev| {
            defer event.freeEvent(t.allocator, ev);
            if (ev == .grep) if (ev.grep.err) |e| {
                said = try keep.allocator().dupe(u8, e);
            };
        }
    }
    try t.expectEqualStrings("rg refused the pattern", said.?);
}

test "find.grep opens the pane beside the editor; hits land grouped by file; n steps, fold, filter, toggle" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try app.openScratch();
    try runGrep(app, "alpha");
    const id = find(app).?;
    try f.settle(id, 400);
    const p = &app.panes.get(id).?.grep;
    try t.expect(!p.loading);
    try t.expectEqual(@as(usize, 5), p.hits.items.len);
    try t.expectEqual(@as(usize, 3), p.groups.items.len);
    // Rows: three headers + five hits.
    try t.expectEqual(@as(usize, 8), p.rows.items.len);
    try t.expect(p.rows.items[0] == .file);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "5 matches in 3 files") != null);
    const txt = try f.screen();
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "src/a.zig") != null);
    try t.expect(std.mem.indexOf(u8, txt, "5 matches") != null);
    try t.expect(std.mem.indexOf(u8, txt, "alpha") != null);
    // `n` opens the first hit in an editor at its line; the grep pane keeps its rows.
    const first_rel = try t.allocator.dupe(u8, p.hits.items[0].rel);
    defer t.allocator.free(first_rel);
    const first_line = p.hits.items[0].line;
    try app.handle(.{ .key = Key.char('n') });
    const e = app.activeEditor().?;
    try t.expect(std.mem.endsWith(u8, e.buf.doc.path.?, first_rel));
    try t.expectEqual(@as(usize, first_line - 1), e.buf.editor.currentLine());
    // The store may have moved when the editor was added: fetch the pane again.
    const p2 = &app.panes.get(id).?.grep;
    try t.expectEqual(@as(usize, 8), p2.rows.items.len);
    // Back on the pane: fold the first file, its hits leave the rows.
    app.setActive(id);
    app.focus = .{ .pane = id };
    p2.cursor = 0;
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(@as(usize, 8 - p2.groups.items[0].count), p2.rows.items.len);
    try app.handle(.{ .key = Key.char('E') });
    try t.expectEqual(@as(usize, 8), p2.rows.items.len);
    // The filter is a vim pattern over the line and the path.
    try app.handle(.{ .key = Key.char('/') });
    for ("\\<Alpha") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqual(@as(usize, 2), p2.rows.items.len); // one file, one hit
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(@as(usize, 8), p2.rows.items.len);
    // Space toggles the hit under the cursor for the replace.
    p2.cursor = 1;
    try app.handle(.{ .key = Key.char(' ') });
    try t.expectEqual(@as(usize, 4), p2.enabledCount());
    try app.handle(.{ .key = Key.char('A') });
    try t.expectEqual(@as(usize, 5), p2.enabledCount());
    // A rerun with a new query replaces everything.
    try runGrep(app, "nothing here");
    try f.settle(id, 400);
    try t.expectEqual(@as(usize, 1), p2.hits.items.len);
    try t.expectEqualStrings("nothing here", p2.query);
}

test "grep replace: open clean buffer through EditOps and saved, closed file on disk, dirty buffer refused, disabled hit kept" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    // a.zig is open and clean; notes.md is open and dirty; b.txt stays closed.
    const a_path = try std.fs.path.join(t.allocator, &.{ f.root, "src/a.zig" });
    defer t.allocator.free(a_path);
    const a_id = try app.openPath(a_path);
    const notes_path = try std.fs.path.join(t.allocator, &.{ f.root, "notes.md" });
    defer t.allocator.free(notes_path);
    // `openEditor`, not `openPath`: a markdown file would open rendered.
    const notes_id = try app.openEditor(notes_path);
    {
        const notes = app.panes.editor(notes_id).?;
        try notes.buf.editor.setText("# alpha (edited)\n");
        notes.buf.doc.dirty = true;
    }
    app.setActive(a_id);
    try runGrep(app, "alpha");
    const id = find(app).?;
    try f.settle(id, 400);
    // The grep pane was added after the editors: fetch them again.
    const notes = app.panes.editor(notes_id).?;
    const p = &app.panes.get(id).?.grep;
    try t.expectEqual(@as(usize, 5), p.hits.items.len);
    // Disable the third hit of a.zig (the last `alpha` on line 2).
    var third: ?u32 = null;
    var seen: usize = 0;
    for (p.hits.items, 0..) |h, i| if (std.mem.eql(u8, h.rel, "src/a.zig")) {
        seen += 1;
        if (seen == 3) third = @intCast(i);
    };
    try p.toggleHit(third.?);
    try acceptReplace(app, "omega");
    const toast = app.lastToast().?;
    try t.expect(std.mem.indexOf(u8, toast, "replaced 3 in 2 files") != null);
    try t.expect(std.mem.indexOf(u8, toast, "1 unsaved buffer skipped") != null);
    const a = app.panes.editor(a_id).?;
    try t.expectEqualStrings("const omega = 1;\nconst beta = omega + alpha;\n", a.buf.editor.bytes());
    try t.expect(!a.buf.doc.dirty);
    const a_disk = try f.read("src/a.zig");
    defer t.allocator.free(a_disk);
    try t.expectEqualStrings("const omega = 1;\nconst beta = omega + alpha;\n", a_disk);
    const b_disk = try f.read("src/deep/b.txt");
    defer t.allocator.free(b_disk);
    try t.expectEqualStrings("omega at the top\nnothing here\n", b_disk);
    // The dirty buffer and its file are untouched.
    try t.expectEqualStrings("# alpha (edited)\n", notes.buf.editor.bytes());
    const notes_disk = try f.read("notes.md");
    defer t.allocator.free(notes_disk);
    try t.expectEqualStrings("# alpha\n", notes_disk);
    // Undo puts a.zig back in one step.
    app.setActive(a_id);
    _ = try app.applyOps(a, &.{.undo});
    try t.expectEqualStrings("const alpha = 1;\nconst beta = alpha + alpha;\n", a.buf.editor.bytes());
    try f.settle(id, 400);
}

test "grep replace: a vim-pattern query expands group references" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try app.openScratch();
    // The pane's query is a vim pattern; the hits come from the walk
    // backend directly so the test does not depend on rg's syntax.
    try runGrep(app, "\\(al\\)\\(pha\\)");
    const id = find(app).?;
    try f.settle(id, 400);
    const p = &app.panes.get(id).?.grep;
    p.flags.regex = true;
    p.clearResults();
    const walked = try walkInto(&f, "\\(al\\)\\(pha\\)", .{ .regex = true });
    walked.generation = p.generation;
    walked.pane = id;
    walked.done = true;
    try app.handle(.{ .grep = walked });
    try t.expect(p.hits.items.len >= 1);
    try acceptReplace(app, "\\2-\\1");
    const a_disk = try f.read("src/a.zig");
    defer t.allocator.free(a_disk);
    try t.expectEqualStrings("const pha-al = 1;\nconst beta = pha-al + pha-al;\n", a_disk);
    try f.settle(id, 400);
}

test "search toggles: whole-word needs the pane; case-sensitive flips the pane's flag and app.search_case together, or the latter alone" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    // No pane: whole-word fails, case flips the editor-wide flag only.
    try t.expectError(error.Failed, command.run(app, .{ .static = .@"search.toggle_whole_word" }));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "no Search pane") != null);
    try t.expect(app.search_case == null);
    try command.run(app, .{ .static = .@"search.toggle_case_sensitive" });
    try t.expectEqual(@as(?bool, true), app.search_case);
    try t.expectEqualStrings("search: case-sensitive on", app.lastToast().?);
    try command.run(app, .{ .static = .@"search.toggle_case_sensitive" });
    try t.expectEqual(@as(?bool, false), app.search_case);
    try t.expectEqualStrings("search: case-sensitive off", app.lastToast().?);
    // With the pane: `alpha` matches 5 (smart case); case-sensitive drops the `Alpha`.
    _ = try app.openScratch();
    try runGrep(app, "alpha");
    const id = find(app).?;
    try f.settle(id, 400);
    try t.expectEqual(@as(usize, 5), app.panes.get(id).?.grep.hits.items.len);
    try command.run(app, .{ .static = .@"search.toggle_case_sensitive" });
    try t.expectEqualStrings("search: case-sensitive on", app.lastToast().?);
    try t.expect(app.panes.get(id).?.grep.flags.case_sensitive);
    try t.expectEqual(@as(?bool, true), app.search_case);
    try f.settle(id, 400);
    try t.expectEqual(@as(usize, 4), app.panes.get(id).?.grep.hits.items.len);
    // Whole word: `alph` matched as a substring before, nothing after.
    try runGrep(app, "alph");
    try f.settle(id, 400);
    try t.expectEqual(@as(usize, 4), app.panes.get(id).?.grep.hits.items.len);
    try command.run(app, .{ .static = .@"search.toggle_whole_word" });
    try t.expectEqualStrings("search: whole-word on", app.lastToast().?);
    try t.expect(app.panes.get(id).?.grep.flags.whole_word);
    try f.settle(id, 400);
    try t.expectEqual(@as(usize, 0), app.panes.get(id).?.grep.hits.items.len);
    try command.run(app, .{ .static = .@"search.toggle_whole_word" });
    try t.expectEqualStrings("search: whole-word off", app.lastToast().?);
}

test "grep: a stale batch is dropped; the pane's deinit cancels a worker mid-run" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try app.openScratch();
    try runGrep(app, "alpha");
    const id = find(app).?;
    const p = &app.panes.get(id).?.grep;
    const old = p.generation;
    const stale = try Result.create(t.allocator, old -% 1, id, .walk);
    try stale.hits.append(stale.arena.allocator(), .{ .path = "/x", .rel = "x", .line = 1, .col = 0, .len = 1, .text = "x" });
    try app.handle(.{ .grep = stale });
    for (p.hits.items) |h| try t.expect(!std.mem.eql(u8, h.rel, "x"));
    // Closing the pane while the worker may still be running must not leak or crash.
    try app.forceClosePane(id);
    try t.expect(find(app) == null);
}
