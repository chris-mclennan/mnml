//! What did this session change — the review step for a machine running
//! a dozen Claude / Codex sessions at once.
//!
//! **The record.** When an AI session pane starts (`pty_pane.open`, a
//! command whose first word is `claude` / `codex` or one of their
//! profile shims) it gets a `Record`: the repo root above its cwd — a
//! session in a worktree (`ai.new_session_worktree`) is that worktree's
//! own root — the wall clock in milliseconds, and, through the git
//! worker (the `session_base` job, never a git call on this thread),
//! the repo's `HEAD` and the paths `status --porcelain -z` calls dirty.
//! The record rides in `session.zon` with its pane, so a restart keeps
//! the base the session actually started from.
//!
//! **The set** (`git/changes.zig`): the files dirty now that were not
//! dirty at the start, the ones whose mtime is after it, the ones in a
//! commit since the base — `ui.session_changes` = `mtime` / `git` /
//! `both` picks the rules. It is recomputed through the worker (the
//! `session_changes` job) when the base lands, when an op on that repo
//! finishes, when the active repo's status comes back DIFFERENT from the
//! last one this record saw, and on the SESSIONS refresh chip — never
//! per frame.
//!
//! **The view** (`sessions.changes`; the card's `N files` chip; the row
//! menu's *What did this session change*): a `Pane.session_changes`, the
//! git status pane's component in its scoped form — Unstaged / Staged
//! (what is uncommitted), Committed since start, a `Commit…` row seeded
//! with the session's title. Enter opens the file's diff (`.file` /
//! `.staged`, or the base-to-HEAD range for a committed one), `s` / `u`
//! / space stage and unstage as the status pane does, `c` or the row
//! commits. A file another session's set also holds names that session
//! after its path: two sessions on one file is the thing to notice.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const Mouse = @import("../core/key.zig").Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const client = @import("../git/client.zig");
const changes = @import("../git/changes.zig");
const parse = @import("../git/parse.zig");
const git_app = @import("git.zig");
const pty_pane = @import("pty_pane.zig");
const status_view = @import("../ui/git_status_view.zig");
const list_panel = @import("../ui/list_panel.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Config = @import("../config/Config.zig");
const sessions = @import("../sessions.zig");

pub const table = .{
    .@"sessions.changes" = &changesCmd,
};

// ─── the record ─────────────────────────────────────────────────────────

pub const BaseState = enum { pending, ready, failed };

/// A session's base and its latest set. Heap-owned by its pty pane
/// (`PtyPane.changes`), freed with it.
pub const Record = struct {
    /// Names the record across the worker's round trip.
    token: u32,
    /// The repo root above the session's cwd, absolute. Owned.
    root: []u8,
    /// The session's start, wall-clock milliseconds.
    since_ms: i64,
    /// The base `HEAD`; null on an unborn branch or before the base lands. Owned.
    head: ?[]u8 = null,
    /// Sorted. Owned.
    dirty0: [][]u8 = &.{},
    base: BaseState = .pending,
    /// The latest set; every slice borrows `snapshot`.
    snapshot: std.heap.ArenaAllocator,
    set: changes.Set = .{},
    branch: []const u8 = "",
    loaded: bool = false,
    /// A compute is out; `again` asks for one more when it lands.
    pending: bool = false,
    again: bool = false,
    /// The active repo's status the last compute was asked for.
    status_fp: u64 = 0,

    pub fn create(gpa: Allocator, token: u32, root: []const u8, since_ms: i64) Allocator.Error!*Record {
        const r = try gpa.create(Record);
        errdefer gpa.destroy(r);
        r.* = .{ .token = token, .root = try gpa.dupe(u8, root), .since_ms = since_ms, .snapshot = .init(gpa) };
        return r;
    }

    pub fn destroy(self: *Record, gpa: Allocator) void {
        gpa.free(self.root);
        if (self.head) |h| gpa.free(h);
        freeList(gpa, self.dirty0);
        self.snapshot.deinit();
        gpa.destroy(self);
    }

    /// The base landed: `head` empty is an unborn branch.
    pub fn setBase(self: *Record, gpa: Allocator, head: []const u8, dirty: []const []const u8) Allocator.Error!void {
        const h: ?[]u8 = if (head.len > 0) try gpa.dupe(u8, head) else null;
        errdefer if (h) |x| gpa.free(x);
        const d = try dupeList(gpa, dirty);
        if (self.head) |old| gpa.free(old);
        freeList(gpa, self.dirty0);
        self.head = h;
        self.dirty0 = d;
        self.base = .ready;
    }

    /// Files in the set, for the card's chip.
    pub fn count(self: *const Record) usize {
        return if (self.loaded) self.set.count() else 0;
    }
};

fn dupeList(gpa: Allocator, src: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (src) |s| {
        out[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn freeList(gpa: Allocator, list: [][]u8) void {
    for (list) |s| gpa.free(s);
    if (list.len > 0) gpa.free(list);
}

/// The app's side: the next token.
pub const State = struct {
    next_token: u32 = 1,
};

/// The record of the session in pane `id`, if it has one.
pub fn recordOf(app: *App, id: PaneId) ?*Record {
    const p = app.panes.pty(id) orelse return null;
    return p.changes;
}

fn byToken(app: *App, token: u32) ?*Record {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.changes) |r| if (r.token == token) return r,
        else => {},
    };
    return null;
}

fn wallMs(app: *App) i64 {
    return Io.Timestamp.now(app.io, .real).toMilliseconds();
}

/// Is `id` an AI session pane — the kind that gets a record?
pub fn isSession(app: *App, id: PaneId) bool {
    const p = app.panes.pty(id) orelse return false;
    return @import("launch_profiles.zig").productOfPane(app, p) != null;
}

/// The repo root above `dir` (itself included), on the frame arena.
fn rootAbove(app: *App, dir: []const u8) Allocator.Error!?[]const u8 {
    const probe = try std.fs.path.join(app.frame.allocator(), &.{ dir, "." });
    return git_app.repoAbove(app, probe);
}

/// A session pane just started: its record, and the base asked for.
/// A cwd in no repository gets none — there is nothing to diff against.
pub fn onSessionStart(app: *App, id: PaneId) Allocator.Error!void {
    const p = app.panes.pty(id) orelse return;
    if (p.changes != null) return;
    if (@import("launch_profiles.zig").productOfPane(app, p) == null) return;
    const root = (try rootAbove(app, p.cwd orelse app.workspace)) orelse return;
    // A repository made since the last walk (`git init` in the
    // workspace) is looked for once more, so the workspace's own repo
    // becomes the active one and its status poll is what refreshes this.
    if (!knows(app, root)) git_app.discover(app) catch {};
    const token = app.session_changes.next_token;
    app.session_changes.next_token += 1;
    const rec = try Record.create(app.gpa, token, root, wallMs(app));
    p.changes = rec;
    requestBase(app, rec);
}

/// What `session.zon` carries for a pane's record.
pub const Saved = struct {
    repo: []const u8,
    since_ms: i64,
    head: ?[]const u8,
    dirty: []const []const u8,
};

/// A restored session pane takes the base it was saved with — its
/// session started then, not now — and the set is computed afresh.
pub fn adopt(app: *App, id: PaneId, saved: Saved) Allocator.Error!void {
    const p = app.panes.pty(id) orelse return;
    if (p.changes) |old| old.destroy(app.gpa);
    p.changes = null;
    const token = app.session_changes.next_token;
    app.session_changes.next_token += 1;
    const rec = try Record.create(app.gpa, token, saved.repo, saved.since_ms);
    errdefer rec.destroy(app.gpa);
    try rec.setBase(app.gpa, saved.head orelse "", saved.dirty);
    p.changes = rec;
    requestCompute(app, rec);
}

fn knows(app: *App, root: []const u8) bool {
    for (app.git.repos.items) |r| if (std.mem.eql(u8, r.path, root)) return true;
    return false;
}

/// A worker that can run `git -C root`: the repo's own when the app
/// knows it, else the active one's, else one made for the root.
fn workerFor(app: *App, root: []const u8) ?*client.Repo {
    if (!app.git.discovered) git_app.discover(app) catch return null;
    for (app.git.repos.items) |r| if (std.mem.eql(u8, r.path, root)) return r;
    if (app.git.activeRepo()) |r| return r;
    return ensureRepo(app, root) catch null;
}

/// The repo at `root`, made (and kept across a re-discovery) when the
/// app does not know it — a session worktree beside the workspace.
/// The view's verbs need one: a diff pane and a stage are the repo's.
pub fn ensureRepo(app: *App, root: []const u8) Allocator.Error!*client.Repo {
    if (!app.git.discovered) try git_app.discover(app);
    for (app.git.repos.items) |r| if (std.mem.eql(u8, r.path, root)) return r;
    const st = &app.git;
    const r = try client.Repo.create(app.gpa, root, std.fs.path.basename(root), st.next_id, false);
    errdefer r.destroy(app.io);
    r.kept = true;
    st.next_id += 1;
    try st.repos.append(app.gpa, r);
    return r;
}

fn requestBase(app: *App, rec: *Record) void {
    const repo = workerFor(app, rec.root) orelse return;
    const dir = app.gpa.dupe(u8, rec.root) catch return;
    git_app.submit(app, repo, .{ .session_base = .{ .token = rec.token, .dir = dir } }) catch {
        app.diag.clear();
    };
}

fn modeOf(app: *App) changes.Mode {
    return switch (app.cfg.ui.session_changes) {
        .mtime => .mtime,
        .git => .git,
        .both => .both,
    };
}

/// Ask for the set again, unless one is out (then once more after it).
pub fn requestCompute(app: *App, rec: *Record) void {
    if (rec.base != .ready) return;
    if (rec.pending) {
        rec.again = true;
        return;
    }
    const repo = workerFor(app, rec.root) orelse return;
    const gpa = app.gpa;
    const dir = gpa.dupe(u8, rec.root) catch return;
    const base: ?[]u8 = if (rec.head) |h| (gpa.dupe(u8, h) catch {
        gpa.free(dir);
        return;
    }) else null;
    const dirty = dupeList(gpa, rec.dirty0) catch {
        gpa.free(dir);
        if (base) |b| gpa.free(b);
        return;
    };
    rec.pending = true;
    git_app.submit(app, repo, .{ .session_changes = .{
        .token = rec.token,
        .dir = dir,
        .base = base,
        .since_ms = rec.since_ms,
        .dirty_at_start = dirty,
        .mode = modeOf(app),
    } }) catch {
        rec.pending = false;
        app.diag.clear();
    };
}

/// Every record, again — the SESSIONS refresh chip.
pub fn refreshAll(app: *App) void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.changes) |r| requestCompute(app, r),
        else => {},
    };
}

/// An op on `repo` finished (`git.afterChange`): its sessions' sets.
pub fn onRepoChanged(app: *App, root: []const u8) void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.changes) |r| if (std.mem.eql(u8, r.root, root)) requestCompute(app, r),
        else => {},
    };
}

/// The active repo's status came back: the sessions on it recompute
/// when it is not the status they last saw. The 3 s status poll is
/// what notices a session's edits; an unchanged tree asks for nothing.
pub fn onStatus(app: *App, root: []const u8, st: parse.Status) void {
    var h = std.hash.Wyhash.init(0);
    for (st.entries) |e| {
        h.update(e.path);
        h.update(&.{ e.code, @intFromEnum(e.group) });
    }
    if (st.oid) |o| h.update(o);
    const fp = h.final();
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.changes) |r| if (std.mem.eql(u8, r.root, root) and r.status_fp != fp) {
            r.status_fp = fp;
            requestCompute(app, r);
        },
        else => {},
    };
}

/// The `session_base` result.
pub fn onBase(app: *App, token: u32, ok: bool, head: []const u8, dirty: []const []const u8) Allocator.Error!void {
    const rec = byToken(app, token) orelse return;
    if (!ok) {
        rec.base = .failed;
        return;
    }
    try rec.setBase(app.gpa, head, dirty);
    requestCompute(app, rec);
    app.needs_render = true;
}

/// The `session_changes` result: the record adopts the arena.
pub fn onChanges(app: *App, result: *client.Result) void {
    const c = result.payload.session_changes;
    const rec = byToken(app, c.token) orelse return;
    rec.pending = false;
    if (c.ok) {
        rec.snapshot.deinit();
        rec.snapshot = result.arena;
        result.arena = .init(app.gpa);
        rec.set = c.set;
        rec.branch = c.branch;
        rec.loaded = true;
    }
    app.needs_render = true;
    if (rec.again) {
        rec.again = false;
        requestCompute(app, rec);
    }
}

// ─── naming a session ───────────────────────────────────────────────────

/// The one name the session in pane `id` goes by — its card's and its
/// tab's (`sessions.nameOf`: the rename, the window title, the first
/// prompt, the CLI's label).
pub fn titleOf(app: *App, id: PaneId) []const u8 {
    if (sessions.paneName(app, id)) |n| return n.text;
    return if (app.panes.pty(id)) |p| p.label else "session";
}

// ─── the view (`Pane.session_changes`) ──────────────────────────────────

pub const ChangesPane = struct {
    /// The session's pty pane.
    session: PaneId,
    /// Its record's token: a pane id reused by another session is not this one.
    token: u32,
    /// The tab label. Owned.
    title: []u8,
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *ChangesPane, gpa: Allocator) void {
        gpa.free(self.title);
    }
};

/// The view's record, if its session pane is still there.
fn recordFor(app: *App, v: *const ChangesPane) ?*Record {
    const r = recordOf(app, v.session) orelse return null;
    return if (r.token == v.token) r else null;
}

/// Open (or bring back) the view of the session in pane `id`.
pub fn open(app: *App, id: PaneId) CommandError!PaneId {
    const rec = recordOf(app, id) orelse {
        if (isSession(app, id)) return app.diag.fail(app.frame.allocator(), "{s}: its directory is not in a git repository", .{titleOf(app, id)});
        return app.diag.fail(app.frame.allocator(), "not an AI session pane", .{});
    };
    requestCompute(app, rec);
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .session_changes => |*v| if (v.session == id and v.token == rec.token) {
            const vid: PaneId = @intCast(i);
            app.showPane(vid);
            return vid;
        },
        else => {},
    };
    const title = try std.fmt.allocPrint(app.gpa, "changes \u{B7} {s}", .{titleOf(app, id)});
    errdefer app.gpa.free(title);
    const vid = try app.panes.add(.{ .session_changes = .{ .session = id, .token = rec.token, .title = title } });
    git_app.showBeside(app, vid);
    return vid;
}

/// The session `sessions.changes` means: the SESSIONS cursor's card
/// when the panel has the keys, else the active pane when it is a
/// session, else the only session there is.
fn targetSession(app: *App) ?PaneId {
    if (app.focus == .panel and app.focus.panel == .sessions) if (sessions.currentCard(app)) |c| return c.pane;
    if (app.active) |a| if (isSession(app, a)) return a;
    if (sessions.currentCard(app)) |c| return c.pane;
    var found: ?PaneId = null;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.changes != null) {
            if (found != null) return null;
            found = @intCast(i);
        },
        else => {},
    };
    return found;
}

/// `sessions.changes`: what did this session change.
fn changesCmd(app: *App) CommandError!void {
    const id = targetSession(app) orelse return app.diag.fail(app.frame.allocator(), "no AI session to review \u{2014} pick a card in SESSIONS", .{});
    _ = try open(app, id);
}

/// The view's rows for this frame: the set split the way the status
/// pane splits a status, the overlaps named.
pub const Rows = struct {
    unstaged: []const status_view.Entry = &.{},
    staged: []const status_view.Entry = &.{},
    committed: []const status_view.Entry = &.{},

    pub fn len(r: Rows) usize {
        const n = r.unstaged.len + r.staged.len + r.committed.len;
        return if (n == 0) 0 else n + 1;
    }

    /// What flat index `i` is.
    pub fn at(r: Rows, i: usize) union(enum) { unstaged: status_view.Entry, staged: status_view.Entry, committed: status_view.Entry, commit, none } {
        if (i < r.unstaged.len) return .{ .unstaged = r.unstaged[i] };
        var j = i - r.unstaged.len;
        if (j < r.staged.len) return .{ .staged = r.staged[j] };
        j -= r.staged.len;
        if (j < r.committed.len) return .{ .committed = r.committed[j] };
        if (r.len() > 0 and i == r.len() - 1) return .commit;
        return .none;
    }
};

/// The other sessions' sets, for the overlap marker.
fn others(app: *App, arena: Allocator, mine: *const Record) Allocator.Error![]const changes.Other {
    var out: std.ArrayListUnmanaged(changes.Other) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.changes) |r| if (r != mine and r.loaded) {
            try out.append(arena, .{ .root = r.root, .title = titleOf(app, @intCast(i)), .set = r.set });
        },
        else => {},
    };
    return out.items;
}

pub fn rows(app: *App, arena: Allocator, rec: *const Record) Allocator.Error!Rows {
    const marks = try changes.overlaps(arena, rec.root, rec.set, try others(app, arena, rec));
    var un: std.ArrayListUnmanaged(status_view.Entry) = .empty;
    var st: std.ArrayListUnmanaged(status_view.Entry) = .empty;
    var co: std.ArrayListUnmanaged(status_view.Entry) = .empty;
    for (rec.set.files, marks) |f, m| {
        const note = m orelse "";
        if (f.unstaged()) try un.append(arena, .{ .path = f.path, .letter = if (f.x == '?') '?' else f.y, .staged = false, .note = note });
        if (f.staged()) try st.append(arena, .{ .path = f.path, .letter = f.x, .staged = true, .note = note });
        if (f.committed) try co.append(arena, .{ .path = f.path, .letter = f.c, .staged = false, .note = note });
    }
    return .{ .unstaged = un.items, .staged = st.items, .committed = co.items };
}

/// `<title> · since 5m ago · 3 files · +12 −4` — or what the record
/// is waiting for.
pub fn header(app: *App, arena: Allocator, id: PaneId, rec: *const Record) Allocator.Error![]const u8 {
    const title = titleOf(app, id);
    const now_s = @divFloor(wallMs(app), 1000);
    const d = now_s - @divFloor(rec.since_ms, 1000);
    const age: []const u8 = if (d < 60) "since just now" else try std.fmt.allocPrint(arena, "since {s} ago", .{ageWord(arena, d) catch "a while"});
    if (rec.base == .failed) return std.fmt.allocPrint(arena, "{s} \u{B7} {s} \u{B7} not a git repository any more", .{ title, age });
    if (!rec.loaded) return std.fmt.allocPrint(arena, "{s} \u{B7} {s} \u{B7} reading git\u{2026}", .{ title, age });
    const n = rec.set.count();
    return std.fmt.allocPrint(arena, "{s} \u{B7} {s} \u{B7} {d} file{s} \u{B7} +{d} \u{2212}{d}", .{ title, age, n, if (n == 1) "" else "s", rec.set.added, rec.set.deleted });
}

/// `ageText`'s words, without a `Ui`.
fn ageWord(arena: Allocator, d: i64) Allocator.Error![]const u8 {
    if (d < 3600) return std.fmt.allocPrint(arena, "{d}m", .{@divFloor(d, 60)});
    if (d < 86_400) return std.fmt.allocPrint(arena, "{d}h", .{@divFloor(d, 3600)});
    return std.fmt.allocPrint(arena, "{d}d", .{@divFloor(d, 86_400)});
}

pub fn draw(app: *App, ui: Ui, id: PaneId, v: *ChangesPane, full: Rect) Allocator.Error!void {
    const rec = recordFor(app, v) orelse {
        status_view.draw(ui, id, full, .{
            .branch = null,
            .unstaged = &.{},
            .staged = &.{},
            .cursor = 0,
            .scope = .{ .header = "session closed", .empty = .{ .message = "This session's pane is closed \u{2014} its record went with it." } },
        }, &v.scroll);
        return;
    };
    const rs = try rows(app, ui.arena, rec);
    const n = rs.len();
    if (n > 0) v.cursor = @min(v.cursor, n - 1) else v.cursor = 0;
    status_view.draw(ui, id, full, .{
        .branch = null,
        .unstaged = rs.unstaged,
        .staged = rs.staged,
        .cursor = v.cursor,
        .scope = .{
            .header = try header(app, ui.arena, v.session, rec),
            .committed = rs.committed,
            .empty = if (rec.loaded)
                .{ .message = "Nothing changed since this session started.", .hint = "r refreshes \u{00B7} the set follows the git status" }
            else
                .{ .message = "Reading what the session changed\u{2026}" },
        },
    }, &v.scroll);
    if (app.active == id) app.pane_rows = @max(full.h, 1);
}

// ─── the verbs ──────────────────────────────────────────────────────────

pub const Act = status_view.Action;

fn runToast(app: *App, result: CommandError!void) void {
    git_app.runToast(app, result);
}

/// The view's repo, made when the app does not know it.
fn repoOf(app: *App, rec: *const Record) CommandError!*client.Repo {
    return ensureRepo(app, rec.root);
}

/// The commit prompt, seeded with the session's title (Enter keeps it,
/// typing replaces it), committing in the session's repo.
pub fn openCommit(app: *App, v: *const ChangesPane) CommandError!void {
    const rec = recordFor(app, v) orelse return app.diag.fail(app.frame.allocator(), "the session's pane is closed", .{});
    const repo = try repoOf(app, rec);
    const staged = (try rows(app, app.frame.allocator(), rec)).staged.len;
    const title = if (staged == 0) "Commit message (nothing staged \u{2014} `s` stages a row)" else "Commit message (the session's staged files and anything else staged)";
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, title), .purpose = .{ .session_commit = repo.id } } };
    try app.overlay.prompt.state.seed(app.gpa, titleOf(app, v.session));
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's accept: `git commit -m` in the session's repo.
pub fn acceptCommit(app: *App, repo_id: u32, text_in: []const u8) CommandError!void {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return app.diag.fail(app.frame.allocator(), "commit: empty message", .{});
    const repo = app.git.repoById(repo_id) orelse return error.NoRepo;
    try git_app.submitOp(app, repo, .{ .commit = try app.gpa.dupe(u8, text) });
}

pub fn act(app: *App, v: *ChangesPane, a: Act) CommandError!void {
    const rec = recordFor(app, v) orelse return app.diag.fail(app.frame.allocator(), "the session's pane is closed", .{});
    const rs = try rows(app, app.frame.allocator(), rec);
    const row = rs.at(v.cursor);
    switch (a) {
        .refresh => {
            requestCompute(app, rec);
            app.toast("refreshing what {s} changed", .{titleOf(app, v.session)});
        },
        .commit => try openCommit(app, v),
        .stage_all, .unstage_all, .ai_commit => {},
        .stage, .unstage, .toggle => {
            const repo = try repoOf(app, rec);
            var entry: status_view.Entry = undefined;
            var staged = false;
            switch (row) {
                .unstaged => |e| entry = e,
                .staged => |e| {
                    entry = e;
                    staged = true;
                },
                .committed => return app.toast("committed since the start \u{2014} nothing to stage", .{}),
                .commit, .none => return,
            }
            const want_stage = switch (a) {
                .stage => true,
                .unstage => false,
                else => !staged,
            };
            if (want_stage and staged) return app.toast("already staged \u{2014} `u` to unstage", .{});
            if (!want_stage and !staged) return app.toast("not staged \u{2014} `s` to stage", .{});
            const row_val: git_app.Row = .{ .path = entry.path, .letter = entry.letter, .staged = staged };
            try git_app.actOnRowIn(app, repo, row_val, if (want_stage) .stage else .unstage);
        },
        .diff => switch (row) {
            .unstaged => |e| {
                if (e.letter == '?') return app.toast("no diff for that file (untracked? \u{2014} stage it to see it)", .{});
                _ = try git_app.openDiff(app, try repoOf(app, rec), .file, e.path, null, null);
            },
            .staged => |e| _ = try git_app.openDiff(app, try repoOf(app, rec), .staged, e.path, null, null),
            .committed => |e| {
                const arena = app.frame.allocator();
                const rev = try client.rangeRev(arena, rec.head orelse changes.empty_tree, "HEAD");
                _ = try git_app.openDiff(app, try repoOf(app, rec), .range, e.path, rev, null);
            },
            .commit => try openCommit(app, v),
            .none => {},
        },
    }
}

/// What flat row `idx` of view `v` is — the hover help's question.
pub const RowKind = enum { unstaged, staged, committed, commit, none };

pub fn rowKind(app: *App, v: *const ChangesPane, idx: u32) RowKind {
    const rec = recordFor(app, v) orelse return .none;
    const rs = rows(app, app.frame.allocator(), rec) catch return .none;
    return switch (rs.at(idx)) {
        .unstaged => .unstaged,
        .staged => .staged,
        .committed => .committed,
        .commit => .commit,
        .none => .none,
    };
}

/// The file under the cursor, for `git.open_file` off the row menu.
pub fn openFile(app: *App, v: *ChangesPane) CommandError!void {
    const rec = recordFor(app, v) orelse return;
    const rs = try rows(app, app.frame.allocator(), rec);
    const path = switch (rs.at(v.cursor)) {
        .unstaged, .staged, .committed => |e| e.path,
        .commit, .none => return,
    };
    const abs = try std.fs.path.join(app.frame.allocator(), &.{ rec.root, path });
    _ = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ path, @errorName(err) }),
    };
}

/// The active pane, when it is a changes view.
pub fn activeView(app: *App) ?*ChangesPane {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .session_changes => |*v| v,
        else => null,
    };
}

/// A `git.*` verb run while a changes view is active acts on the view's
/// row and repo (the row menu's `Open diff` / `Stage` / `Commit…`).
/// True when it did.
pub fn gitVerb(app: *App, verb: enum { diff, stage, unstage, open_file, commit }) CommandError!bool {
    const v = activeView(app) orelse return false;
    switch (verb) {
        .diff => try act(app, v, .diff),
        .stage => try act(app, v, .stage),
        .unstage => try act(app, v, .unstage),
        .commit => try act(app, v, .commit),
        .open_file => try openFile(app, v),
    }
    return true;
}

fn moveCursor(v: *ChangesPane, n: usize, delta: isize) void {
    if (n == 0) return;
    const cur: isize = @intCast(v.cursor);
    const max: isize = @intCast(n - 1);
    v.cursor = @intCast(std.math.clamp(cur +| delta, 0, max));
}

fn rowCount(app: *App, v: *const ChangesPane) usize {
    const rec = recordFor(app, v) orelse return 0;
    return (rows(app, app.frame.allocator(), rec) catch return 0).len();
}

/// The status pane's keys, minus the whole-repo ones: `j k ↑ ↓` and the
/// pages / ends move, `space s u` stage and unstage, Enter opens the
/// diff (or commits on the `Commit…` row), `c` commits, `r` refreshes.
pub fn key(app: *App, id: PaneId, v: *ChangesPane, k: Key) Allocator.Error!bool {
    _ = id;
    const n = rowCount(app, v);
    const page: isize = @intCast(@max(app.pane_rows, 1));
    const top = std.math.minInt(isize) / 2;
    const bottom = std.math.maxInt(isize) / 2;
    switch (k.code) {
        .up => moveCursor(v, n, -1),
        .down => moveCursor(v, n, 1),
        .page_up => moveCursor(v, n, -page),
        .page_down => moveCursor(v, n, page),
        .home => moveCursor(v, n, top),
        .end => moveCursor(v, n, bottom),
        .enter => runToast(app, act(app, v, .diff)),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => moveCursor(v, n, 1),
                'k' => moveCursor(v, n, -1),
                'g' => moveCursor(v, n, top),
                'G' => moveCursor(v, n, bottom),
                ' ' => runToast(app, act(app, v, .toggle)),
                's' => runToast(app, act(app, v, .stage)),
                'u' => runToast(app, act(app, v, .unstage)),
                'c' => runToast(app, act(app, v, .commit)),
                'r' => runToast(app, act(app, v, .refresh)),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

pub fn wheel(app: *App, v: *ChangesPane, down: bool, n: usize) void {
    const d: isize = @intCast(n);
    moveCursor(v, rowCount(app, v), if (down) d else -d);
}

/// A click (`.script_hit{ pane, id }`): a hint word runs its verb; a row
/// takes the cursor, a second click on it acts, a right click opens the
/// row menu.
pub fn click(app: *App, v: *ChangesPane, idx: u32, m: Mouse) Allocator.Error!void {
    if (status_view.hintOf(idx)) |a| {
        if (m.button == .left) runToast(app, act(app, v, a));
        return;
    }
    if (idx >= rowCount(app, v)) return;
    const was = v.cursor;
    v.cursor = idx;
    app.needs_render = true;
    if (m.button == .right) return openRowMenu(app, m.x, m.y);
    if (was == idx) runToast(app, act(app, v, .diff));
}

pub fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Open diff", .action = .{ .command = .@"git.diff_file" } },
        .{ .label = "Open file", .action = .{ .command = .@"git.open_file" } },
        .{ .label = "Stage", .action = .{ .command = .@"git.stage" }, .separator_before = true },
        .{ .label = "Unstage", .action = .{ .command = .@"git.unstage" } },
        .{ .label = "Commit\u{2026}", .action = .{ .command = .@"git.commit" }, .separator_before = true },
        .{ .label = "Refresh", .action = .{ .command = .@"sessions.refresh" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Session changes", items, x, y);
}

// ─── the card's chip ────────────────────────────────────────────────────

/// ` 3 files ` on a card, when the set is not empty.
pub fn chipText(arena: Allocator, n: usize) Allocator.Error!?[]const u8 {
    if (n == 0) return null;
    return try std.fmt.allocPrint(arena, " {d} file{s} ", .{ n, if (n == 1) "" else "s" });
}

/// The chip's press: the view.
pub fn chipMouse(app: *App, pane: PaneId, m: Mouse) Allocator.Error!void {
    if (m.button != .left) return;
    _ = open(app, pane) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (app.diag.msg) |msg| app.toast("{s}", .{msg});
        app.diag.clear();
    };
}

/// The `Config` enum the worker's mode comes from, for the docs.
pub const ConfigMode = Config.SessionChanges;

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");
const session_file = @import("session.zig");

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,
    claude: []u8,

    /// A git repo for a workspace and a fake `claude` that only waits.
    fn init() !Fixture {
        if (builtin.os.tag == .windows or !pty_pane.supported) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        try sh(root, &.{ "git", "init", "-q", "-b", "main" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "bin/\n.mnml/\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "old.txt", .data = "old\n" });
        try sh(root, &.{ "git", "add", "-A" });
        try sh(root, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first" });
        // Dirty before any session, and dated long before it.
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "old.txt", .data = "old, edited\n" });
        try sh(root, &.{ "touch", "-t", "202001010000", "old.txt" });
        try tmp.dir.createDirPath(testing.io, "bin");
        const claude = try std.fs.path.join(testing.allocator, &.{ root, "bin", "claude" });
        errdefer testing.allocator.free(claude);
        const perms: Io.File.Permissions = .fromMode(0o755);
        const file = try Io.Dir.cwd().createFile(testing.io, claude, .{ .truncate = true, .permissions = perms });
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "#!/bin/sh\nsleep 30\n");
        try file.setPermissions(testing.io, perms);
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 120, .rows = 30 });
        return .{ .tmp = tmp, .root = root, .app = app, .claude = claude };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.claude);
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn sh(dir: []const u8, argv: []const []const u8) !void {
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv, .cwd = .{ .path = dir } });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return error.CommandFailed;
    }

    fn open(f: *Fixture, sid: []const u8, label: []const u8) !PaneId {
        return pty_pane.open(&f.app, .{ .argv = &.{ f.claude, "--session-id", sid }, .label = label, .kind = .command, .placement = .tab });
    }

    /// Ticks until the record of `pid` has a set of `n` files, or 5 s.
    fn settle(f: *Fixture, pid: PaneId, n: usize) !bool {
        var waited: u32 = 0;
        while (waited <= 5000) : (waited += 10) {
            try f.app.tick(App.nowMs(testing.io));
            if (recordOf(&f.app, pid)) |r| if (r.loaded and !r.pending and r.set.count() == n) return true;
            testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        return false;
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("../ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }
};

test "a session pane records its base through the worker; the set follows what it changed; the view lists it; the base rides in session.zon" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const pid = try f.open("e2e00000-0000-4000-8000-00000000c001", "claude");
    const rec = recordOf(app, pid) orelse return error.TestNoRecord;
    try testing.expectEqualStrings(f.root, rec.root);
    try testing.expect(try f.settle(pid, 0));
    try testing.expectEqual(BaseState.ready, rec.base);
    try testing.expectEqual(@as(usize, 1), rec.dirty0.len);
    try testing.expectEqualStrings("old.txt", rec.dirty0[0]);
    // A shell gets no record.
    const shell = try pty_pane.open(app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
    try testing.expect(recordOf(app, shell) == null);

    // The session writes a file; the refresh reads git again.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "new.txt", .data = "a\nb\n" });
    refreshAll(app);
    try testing.expect(try f.settle(pid, 1));
    try testing.expect(rec.set.find("new.txt") != null);
    try testing.expect(rec.set.find("old.txt") == null);
    try testing.expectEqual(@as(u64, 2), rec.set.added);

    // The view, through the command, on the active session. (The tree
    // is put away: it lists every file, `old.txt` included.)
    app.tree.visible = false;
    app.setActive(pid);
    try command.run(app, .{ .static = .@"sessions.changes" });
    const vid = app.active.?;
    try testing.expect(app.panes.get(vid).?.* == .session_changes);
    const text = try f.screen();
    defer testing.allocator.free(text);
    var arena_h: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_h.deinit();
    try testing.expect(std.mem.indexOf(u8, text, "Unstaged changes (1)") != null);
    const head_line = try header(app, arena_h.allocator(), pid, rec);
    try testing.expect(std.mem.endsWith(u8, head_line, " \u{B7} since just now \u{B7} 1 file \u{B7} +2 \u{2212}0"));
    try testing.expect(std.mem.indexOf(u8, text, "? new.txt") != null);
    try testing.expect(std.mem.indexOf(u8, text, "old.txt") == null);
    // Again: the same view comes back, not a second one.
    app.setActive(pid);
    try command.run(app, .{ .static = .@"sessions.changes" });
    try testing.expectEqual(vid, app.active.?);

    // The base rides in session.zon with the pane, and a restore adopts it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const saved = try session_file.capture(app, arena_state.allocator());
    var found = false;
    for (saved.panes) |sp| if (sp.changes_repo) |repo| {
        found = true;
        try testing.expectEqualStrings(f.root, repo);
        try testing.expectEqual(rec.since_ms, sp.changes_since_ms);
        try testing.expectEqualStrings(rec.head.?, sp.changes_head.?);
        try testing.expectEqual(@as(usize, 1), sp.changes_dirty.len);
        try adopt(app, shell, .{ .repo = repo, .since_ms = sp.changes_since_ms, .head = sp.changes_head, .dirty = sp.changes_dirty });
    };
    try testing.expect(found);
    const adopted = recordOf(app, shell).?;
    try testing.expectEqual(rec.since_ms, adopted.since_ms);
    try testing.expect(adopted.token != rec.token);
    try testing.expect(try f.settle(shell, 1));
}

test "two sessions on one file: each view names the other; a closed session's view says so; the command needs a session" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    // Two names, so the mark can only be the OTHER session's.
    const a = try f.open("e2e00000-0000-4000-8000-00000000c00a", "alpha");
    const b = try f.open("e2e00000-0000-4000-8000-00000000c00b", "beta");
    try testing.expect(try f.settle(a, 0));
    try testing.expect(try f.settle(b, 0));
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "both\n" });
    refreshAll(app);
    try testing.expect(try f.settle(a, 1));
    try testing.expect(try f.settle(b, 1));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const rs = try rows(app, arena_state.allocator(), recordOf(app, a).?);
    try testing.expectEqual(@as(usize, 1), rs.unstaged.len);
    try testing.expectEqualStrings("beta", titleOf(app, b));
    try testing.expectEqualStrings("beta", rs.unstaged[0].note);
    const theirs = try rows(app, arena_state.allocator(), recordOf(app, b).?);
    try testing.expectEqualStrings("alpha", theirs.unstaged[0].note);
    // A rename is the name the view uses too — the card's and the tab's
    // (`sessions.nameOf`), not a second lookup of its own.
    try testing.expect(try sessions.renamePaneTo(app, b, "beta renamed"));
    try testing.expectEqualStrings("beta renamed", titleOf(app, b));
    const renamed = try rows(app, arena_state.allocator(), recordOf(app, a).?);
    try testing.expectEqualStrings("beta renamed", renamed.unstaged[0].note);
    // Row 1 is the Commit… row.
    try testing.expectEqual(@as(usize, 2), rs.len());
    try testing.expect(rs.at(1) == .commit);

    const vid = try open(app, a);
    try app.closePane(a, true);
    app.setActive(vid);
    const text = try f.screen();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "This session's pane is closed") != null);

    // No session to point at: the command says so rather than guessing.
    try app.closePane(b, true);
    app.setActive(null);
    try testing.expectError(error.Failed, command.run(app, .{ .static = .@"sessions.changes" }));
    app.diag.clear();
}
