//! Session worktrees — a Claude / Codex session in a git worktree of
//! its own. Opt-in, per launch (the chip menu's *New session in a
//! worktree…*, the `+ New session` menu, `ai.new_session_worktree`) or
//! per profile (`LaunchProfile.worktree`): the launch prompts for a
//! name, `git worktree add -b <name> <root>/<name> HEAD` makes the tree
//! and the session runs there with `MNML_WORKSPACE` pointing at it.
//!
//! The convention is this project's own: `<repo>-worktrees/<name>`
//! beside the repository, the branch named after the tree.
//! `ai.default_worktree_root` overrides the root (`rootFor`).
//!
//! The registry (`sessions.State.worktrees`, saved as `session.zon`
//! `sessions_worktrees`) is what ties a worktree to its session: an
//! entry is added at launch by path, and takes the session id once the
//! scan lists a transcript whose cwd is the tree (`Registry.learn`). The
//! SESSIONS card and table tag the row, the row menu offers *Open
//! worktree in tree* / *Merge into <branch>…* / *Remove worktree…*, the
//! git panel's WORKTREES row paints the session's accent, and a session
//! that ends with its tree still there toasts once with the count of
//! commits waiting (`sessions.announceEdges`).
//!
//! Every git child runs synchronously here (a worktree must exist
//! before the session spawns into it) and lands in the command log
//! like the worker's (`logLine`), so a failed merge's reason is one
//! `git.command_log` away.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const git = @import("git.zig");
const launch_profiles = @import("launch_profiles.zig");
const pty_pane = @import("pty_pane.zig");
const Config = @import("../config/Config.zig");

/// The registry's row: a tree mnml made for a session.
pub const Entry = struct {
    /// Absolute. Owned.
    path: []u8,
    /// The name given at the prompt — the directory's basename. Owned.
    name: []u8,
    /// The branch checked out there (`name` today). Owned.
    branch: []u8,
    /// The main repository's root, the tree's `HEAD` came from. Owned.
    repo: []u8,
    /// The transcript id of the session running there, once the scan
    /// has paired one (`learn`). Owned.
    session_id: ?[]u8 = null,

    pub fn deinit(e: Entry, gpa: Allocator) void {
        gpa.free(e.path);
        gpa.free(e.name);
        gpa.free(e.branch);
        gpa.free(e.repo);
        if (e.session_id) |s| gpa.free(s);
    }
};

/// The trees mnml made, by path. Owned by `sessions.State`.
pub const Registry = struct {
    items: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Registry, gpa: Allocator) void {
        for (self.items.items) |e| e.deinit(gpa);
        self.items.deinit(gpa);
    }

    /// Add a tree; a second entry at the same path replaces the first.
    pub fn add(self: *Registry, gpa: Allocator, path: []const u8, name: []const u8, branch: []const u8, repo: []const u8, session_id: ?[]const u8) Allocator.Error!void {
        var e: Entry = .{
            .path = try gpa.dupe(u8, path),
            .name = undefined,
            .branch = undefined,
            .repo = undefined,
        };
        errdefer gpa.free(e.path);
        e.name = try gpa.dupe(u8, name);
        errdefer gpa.free(e.name);
        e.branch = try gpa.dupe(u8, branch);
        errdefer gpa.free(e.branch);
        e.repo = try gpa.dupe(u8, repo);
        errdefer gpa.free(e.repo);
        e.session_id = if (session_id) |s| (if (s.len > 0) try gpa.dupe(u8, s) else null) else null;
        errdefer if (e.session_id) |s| gpa.free(s);
        for (self.items.items, 0..) |old, i| if (std.mem.eql(u8, old.path, path)) {
            old.deinit(gpa);
            self.items.items[i] = e;
            return;
        };
        try self.items.append(gpa, e);
    }

    pub fn byPath(self: *const Registry, path: []const u8) ?*const Entry {
        for (self.items.items) |*e| if (std.mem.eql(u8, e.path, path)) return e;
        return null;
    }

    pub fn bySession(self: *const Registry, session_id: []const u8) ?*const Entry {
        for (self.items.items) |*e| if (e.session_id) |s| if (std.mem.eql(u8, s, session_id)) return e;
        return null;
    }

    /// The entry a session belongs to: by its id, else by its cwd.
    pub fn of(self: *const Registry, session_id: []const u8, cwd: ?[]const u8) ?*const Entry {
        if (self.bySession(session_id)) |e| return e;
        if (cwd) |c| if (self.byPath(c)) |e| return e;
        return null;
    }

    /// A session listed with `cwd` on a tree that has no id yet takes
    /// it — the link the launch could not make (the transcript did not
    /// exist). True when something changed.
    pub fn learn(self: *Registry, gpa: Allocator, session_id: []const u8, cwd: ?[]const u8) Allocator.Error!bool {
        const c = cwd orelse return false;
        if (self.bySession(session_id) != null) return false;
        for (self.items.items) |*e| if (e.session_id == null and std.mem.eql(u8, e.path, c)) {
            e.session_id = try gpa.dupe(u8, session_id);
            return true;
        };
        return false;
    }

    /// Drop the entry at `path`; whether there was one.
    pub fn remove(self: *Registry, gpa: Allocator, path: []const u8) bool {
        for (self.items.items, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) {
            e.deinit(gpa);
            _ = self.items.orderedRemove(i);
            return true;
        };
        return false;
    }
};

// ─── names and paths ────────────────────────────────────────────────────

/// A name that is a directory name and a branch name at once: letters,
/// digits, `-`, `_`, `.`, `/`; not starting with `-`, `.` or `/`, not
/// ending with `/`, `.` or `.lock`, no `..`, `//` or `@{`, at most 80
/// bytes (the subset of `git check-ref-format` a session name needs).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 80) return false;
    if (name[0] == '-' or name[0] == '.' or name[0] == '/') return false;
    if (name[name.len - 1] == '/' or name[name.len - 1] == '.') return false;
    if (std.mem.endsWith(u8, name, ".lock")) return false;
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "//") != null or std.mem.indexOf(u8, name, "@{") != null) return false;
    if (std.mem.eql(u8, name, "@")) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    return true;
}

pub const name_rule = "letters, digits, `-`, `_`, `.`, `/`; no leading `-` or `.`, no `..`";

/// Where the trees of `repo_root` go: `<repo>-worktrees` beside it, or
/// `override` (`ai.default_worktree_root`) with `~` expanded and a
/// relative path taken under the repository.
pub fn rootFor(arena: Allocator, repo_root: []const u8, override: ?[]const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    const o = std.mem.trim(u8, override orelse "", " \t");
    if (o.len == 0) return std.fmt.allocPrint(arena, "{s}-worktrees", .{std.mem.trimEnd(u8, repo_root, "/")});
    if (o[0] == '~' and (o.len == 1 or o[1] == '/')) {
        const h = home orelse return try arena.dupe(u8, o);
        if (o.len == 1) return try arena.dupe(u8, h);
        return std.fs.path.join(arena, &.{ h, o[2..] });
    }
    if (std.fs.path.isAbsolute(o)) return try arena.dupe(u8, o);
    return std.fs.path.join(arena, &.{ repo_root, o });
}

pub fn pathFor(arena: Allocator, root: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ root, name });
}

/// `<base>-<n>` for the first `n` from 1 whose directory under `root`
/// does not exist — the prompt's seed (`session-1`, `work-3`).
pub fn suggestName(arena: Allocator, io: Io, root: []const u8, base: []const u8) Allocator.Error![]const u8 {
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
        const path = try pathFor(arena, root, name);
        _ = Io.Dir.cwd().statFile(io, path, .{}) catch return name;
    }
    return std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
}

/// `suggestName`, past a local branch of that name as well: accepting a
/// seed whose branch already exists fails, and a branch named
/// `session-1` with the user's own commit on it is not a tree to reuse.
/// Gives up asking git after a hundred taken names.
pub fn freeName(app: *App, arena: Allocator, repo: []const u8, root: []const u8, base: []const u8) CommandError![]const u8 {
    var name = try suggestName(arena, app.io, root, base);
    var tries: u32 = 0;
    while (tries < 100 and try branchExists(app, arena, repo, name)) : (tries += 1) {
        const dash = std.mem.lastIndexOfScalar(u8, name, '-').?;
        const n = std.fmt.parseInt(u32, name[dash + 1 ..], 10) catch break;
        var next = n + 1;
        // The next number whose directory is free too.
        while (next < 10_000) : (next += 1) {
            const cand = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, next });
            if (!exists(app.io, try pathFor(arena, root, cand))) {
                name = cand;
                break;
            }
        } else break;
    }
    return name;
}

pub fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

// ─── git, synchronously, into the command log ───────────────────────────

pub const Out = struct {
    ok: bool,
    exit: ?u8,
    stdout: []const u8,
    stderr: []const u8,

    /// stderr's first line, else stdout's, trimmed — what a toast says.
    pub fn reason(o: Out) []const u8 {
        const e = std.mem.trim(u8, o.stderr, " \t\r\n");
        const s = if (e.len > 0) e else std.mem.trim(u8, o.stdout, " \t\r\n");
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
        return s[0..nl];
    }

    pub fn text(o: Out) []const u8 {
        return std.mem.trim(u8, o.stdout, " \t\r\n");
    }
};

/// `git <args>` in `cwd`, the output on `arena`, the child logged as
/// the worker logs its own (`git.LogRing`).
pub fn run(app: *App, arena: Allocator, cwd: []const u8, args: []const []const u8) CommandError!Out {
    // A `status` only reads: `--no-optional-locks` keeps it from writing
    // the refreshed index back under `.git/index.lock`, the lock a
    // commit in the same tree needs (`git.client`'s `argvFor`).
    const base = [_][]const u8{ "git", "--no-pager", "-c", "color.ui=never" };
    const read_only = args.len > 0 and std.mem.eql(u8, args[0], "status");
    const prefix: []const []const u8 = if (read_only) &(base ++ [_][]const u8{"--no-optional-locks"}) else &base;
    const argv = try arena.alloc([]const u8, prefix.len + args.len);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);
    const started = App.nowMs(app.io);
    const res = std.process.run(app.gpa, app.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            const reason = try std.fmt.allocPrint(arena, "cannot run git: {s}", .{@errorName(err)});
            try logLine(app, cwd, argv, args, started, false, null, reason);
            return .{ .ok = false, .exit = null, .stdout = "", .stderr = reason };
        },
    };
    defer app.gpa.free(res.stdout);
    defer app.gpa.free(res.stderr);
    const out: Out = .{
        .ok = res.term == .exited and res.term.exited == 0,
        .exit = if (res.term == .exited) res.term.exited else null,
        .stdout = try arena.dupe(u8, res.stdout),
        .stderr = try arena.dupe(u8, res.stderr),
    };
    try logLine(app, cwd, argv, args, started, out.ok, out.exit, out.stderr);
    return out;
}

fn logLine(app: *App, cwd: []const u8, argv: []const []const u8, args: []const []const u8, started: i64, ok: bool, exit: ?u8, stderr: []const u8) Allocator.Error!void {
    const gs = &app.git;
    const gpa = app.gpa;
    var repo_id: u32 = 0;
    for (gs.repos.items) |r| if (std.mem.eql(u8, r.path, cwd)) {
        repo_id = r.id;
    };
    const line = try std.mem.join(gpa, " ", argv);
    errdefer gpa.free(line);
    const copy = try gpa.alloc([]u8, args.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |c| gpa.free(c);
        gpa.free(copy);
    }
    for (args) |a| {
        copy[filled] = try gpa.dupe(u8, a);
        filled += 1;
    }
    const cwd_owned = try gpa.dupe(u8, cwd);
    errdefer gpa.free(cwd_owned);
    const e = std.mem.trim(u8, stderr, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, e, '\n') orelse e.len;
    const err_owned = try gpa.dupe(u8, e[0..nl]);
    errdefer gpa.free(err_owned);
    const elapsed = App.nowMs(app.io) - started;
    const seq = gs.log_next_seq;
    gs.log_next_seq +%= 1;
    try gs.log.push(gpa, .{
        .seq = seq,
        .repo = repo_id,
        .argv = line,
        .args = copy,
        .cwd = cwd_owned,
        .ok = ok,
        .exit = exit,
        .ms = @intCast(std.math.clamp(elapsed, 0, std.math.maxInt(u32))),
        .stderr = err_owned,
    });
    if (!ok) gs.last_failed_seq = seq;
    try git.refillLogPane(app, null);
}

/// The repository root `dir` is in, null when it is in none.
pub fn repoRoot(app: *App, arena: Allocator, dir: []const u8) CommandError!?[]const u8 {
    const out = try run(app, arena, dir, &.{ "rev-parse", "--show-toplevel" });
    if (!out.ok or out.text().len == 0) return null;
    return out.text();
}

pub fn branchExists(app: *App, arena: Allocator, repo: []const u8, name: []const u8) CommandError!bool {
    const ref = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{name});
    const out = try run(app, arena, repo, &.{ "rev-parse", "--verify", "--quiet", ref });
    return out.ok;
}

pub fn currentBranch(app: *App, arena: Allocator, repo: []const u8) CommandError![]const u8 {
    const out = try run(app, arena, repo, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    return if (out.ok) out.text() else "HEAD";
}

/// Tracked changes in `repo`'s tree or index (untracked files are not
/// in a merge's way).
pub fn isDirty(app: *App, arena: Allocator, repo: []const u8) CommandError!bool {
    const out = try run(app, arena, repo, &.{ "status", "--porcelain", "--untracked-files=no" });
    return out.ok and out.text().len > 0;
}

/// Commits on `branch` that `repo`'s `HEAD` does not have; null when
/// git cannot say (the branch is gone).
pub fn commitsAhead(app: *App, arena: Allocator, repo: []const u8, branch: []const u8) CommandError!?u32 {
    const range = try std.fmt.allocPrint(arena, "HEAD..{s}", .{branch});
    const out = try run(app, arena, repo, &.{ "rev-list", "--count", range });
    if (!out.ok) return null;
    return std.fmt.parseInt(u32, out.text(), 10) catch null;
}

/// Whether every commit of `branch` is already in `repo`'s `HEAD`.
pub fn isMerged(app: *App, arena: Allocator, repo: []const u8, branch: []const u8) CommandError!bool {
    const out = try run(app, arena, repo, &.{ "merge-base", "--is-ancestor", branch, "HEAD" });
    return out.ok;
}

/// Where a new tree for `repo` goes, under the config's override.
pub fn rootOf(app: *App, arena: Allocator, repo: []const u8) Allocator.Error![]const u8 {
    return rootFor(arena, repo, app.cfg.ai.default_worktree_root, app.userHome());
}

/// `git worktree add -b <name> <root>/<name> HEAD` in `repo`; the path.
/// Refused, with the reason, when the name is not one, the directory
/// exists, or the branch does.
pub fn create(app: *App, arena: Allocator, repo: []const u8, name: []const u8) CommandError![]const u8 {
    if (!validName(name)) return app.diag.fail(arena, "worktree: `{s}` is not a branch name ({s})", .{ name, name_rule });
    const root = try rootOf(app, arena, repo);
    const path = try pathFor(arena, root, name);
    if (exists(app.io, path)) return app.diag.fail(arena, "worktree: {s} exists already", .{path});
    if (try branchExists(app, arena, repo, name)) return app.diag.fail(arena, "worktree: branch `{s}` exists already — pick another name", .{name});
    Io.Dir.cwd().createDirPath(app.io, root) catch |err| return app.diag.fail(arena, "worktree: cannot create {s}: {s}", .{ root, @errorName(err) });
    const out = try run(app, arena, repo, &.{ "worktree", "add", "-b", name, path, "HEAD" });
    if (!out.ok) return app.diag.fail(arena, "worktree add {s}: {s}", .{ name, out.reason() });
    return path;
}

/// `git merge --no-ff <branch>` on the main tree. Refused when the main
/// tree has changes; a failed merge opens the command log on its line
/// so the conflict is readable, and the reason is the toast's.
pub fn merge(app: *App, arena: Allocator, e: Entry) CommandError!void {
    if (try isDirty(app, arena, e.repo)) return app.diag.fail(arena, "merge {s}: the main tree ({s}) has uncommitted changes — commit or stash them first", .{ e.branch, std.fs.path.basename(e.repo) });
    const into = try currentBranch(app, arena, e.repo);
    const msg = try std.fmt.allocPrint(arena, "Merge branch '{s}' (session worktree)", .{e.branch});
    const out = try run(app, arena, e.repo, &.{ "merge", "--no-ff", "--no-edit", "-m", msg, e.branch });
    if (!out.ok) {
        git.openCommandLog(app, app.git.last_failed_seq) catch {};
        return app.diag.fail(arena, "merge {s} into {s} failed: {s}", .{ e.branch, into, out.reason() });
    }
    app.toast("merged {s} into {s}", .{ e.branch, into });
    refreshRepo(app, e.repo);
}

/// What a remove may throw away: `branch` deletes an unmerged branch
/// (`branch -D`), `tree` removes a tree that holds uncommitted or
/// untracked files (`worktree remove --force`). The two are asked
/// separately — a yes to one is never a yes to the other.
pub const RemoveForce = struct { branch: bool = false, tree: bool = false };

/// Changed, staged and untracked files in the tree at `path` (`git
/// status --porcelain` lines); 0 when git cannot say.
pub fn dirtyCount(app: *App, arena: Allocator, path: []const u8) CommandError!u32 {
    const out = try run(app, arena, path, &.{ "status", "--porcelain" });
    if (!out.ok) return 0;
    var n: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, out.stdout, '\n');
    while (it.next()) |line| if (std.mem.trim(u8, line, " \t\r").len > 0) {
        n += 1;
    };
    return n;
}

/// The live pane whose child works in the session's tree — started in
/// it (or under it), or running the session the row learned. Removing
/// the tree would delete that child's working directory under it.
pub fn livePaneIn(app: *App, e: Entry) ?app_mod.PaneId {
    if (e.session_id) |sid| if (pty_pane.liveSessionPane(app, sid)) |pid| return pid;
    const tree = std.mem.trimEnd(u8, e.path, "/");
    var pid: app_mod.PaneId = 0;
    while (pid < app.panes.capacity()) : (pid += 1) {
        const p = app.panes.pty(pid) orelse continue;
        if (p.exit != null) continue;
        const cwd = p.cwd orelse continue;
        if (!std.mem.startsWith(u8, cwd, tree)) continue;
        if (cwd.len == tree.len or cwd[tree.len] == '/') return pid;
    }
    return null;
}

fn refuseLive(app: *App, arena: Allocator, e: Entry) CommandError!void {
    if (livePaneIn(app, e) == null) return;
    return app.diag.fail(arena, "remove {s}: a session is still running in it — end the session first", .{e.name});
}

/// `git worktree remove` then `git branch -d`. An unmerged branch is
/// refused unless `force.branch` (`-D`); a tree with uncommitted or
/// untracked files is refused by git itself unless `force.tree`
/// (`--force`), which fails cleanly and keeps the files. A tree whose
/// directory is already gone has its own entry dropped — never a
/// repository-wide `git worktree prune`, which would take the user's
/// own worktrees that are only away for a moment with it. Refused
/// while a session runs in the tree. The registry row goes with the
/// tree, and an emptied root directory too.
pub fn remove(app: *App, arena: Allocator, e: Entry, force: RemoveForce) CommandError!void {
    try refuseLive(app, arena, e);
    if (!force.branch and exists(app.io, e.path) and !(try isMerged(app, arena, e.repo, e.branch))) {
        const n = (try commitsAhead(app, arena, e.repo, e.branch)) orelse 0;
        return app.diag.fail(arena, "remove {s}: branch `{s}` has {d} unmerged commit{s}", .{ e.name, e.branch, n, if (n == 1) "" else "s" });
    }
    if (exists(app.io, e.path)) {
        const out = if (force.tree)
            try run(app, arena, e.repo, &.{ "worktree", "remove", "--force", e.path })
        else
            try run(app, arena, e.repo, &.{ "worktree", "remove", e.path });
        if (!out.ok) {
            if (!force.tree) return app.diag.fail(arena, "kept worktree {s} — nothing removed: {s}", .{ e.name, out.reason() });
            return app.diag.fail(arena, "worktree remove {s}: {s}", .{ e.name, out.reason() });
        }
    } else {
        // The directory is gone: `worktree remove` on its path drops
        // this tree's own admin entry and nothing else. A path git no
        // longer knows is already what we want.
        _ = try run(app, arena, e.repo, &.{ "worktree", "remove", e.path });
    }
    if (try branchExists(app, arena, e.repo, e.branch)) {
        const out = try run(app, arena, e.repo, &.{ "branch", if (force.branch) "-D" else "-d", e.branch });
        if (!out.ok) return app.diag.fail(arena, "branch -d {s}: {s}", .{ e.branch, out.reason() });
    }
    const path = try arena.dupe(u8, e.path);
    const name = try arena.dupe(u8, e.name);
    const repo = try arena.dupe(u8, e.repo);
    _ = app.sessions.worktrees.remove(app.gpa, path);
    // The root goes when this was its last tree.
    if (std.fs.path.dirname(path)) |root| Io.Dir.cwd().deleteDir(app.io, root) catch {};
    app.toast("removed worktree {s}", .{name});
    refreshRepo(app, repo);
}

/// The panels of the repo at `path` re-read after a change.
fn refreshRepo(app: *App, path: []const u8) void {
    for (app.git.repos.items) |r| if (std.mem.eql(u8, r.path, path)) {
        git.afterChange(app, r) catch {};
        return;
    };
}

// ─── the launch: a name prompt, then the tree and the session ───────────

pub const prompt_title = "New session in a worktree — the branch name";

/// The name prompt for a session of `product` under launch profile
/// `profile`, seeded with `session-<n>` (`<profile>-<n>` for a named
/// one) — the first such directory that does not exist. Refused when
/// the workspace is in no repository.
pub fn openNamePrompt(app: *App, product: Config.AiProduct, profile: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const repo = (try repoRoot(app, arena, app.workspace)) orelse return app.diag.fail(arena, "worktree: {s} is not in a git repository", .{app.workspace});
    const root = try rootOf(app, arena, repo);
    const base: []const u8 = if (std.mem.eql(u8, profile, launch_profiles.builtin_name)) "session" else profile;
    const seed = try freeName(app, arena, repo, root, base);
    const owned = try app.gpa.dupe(u8, profile);
    errdefer app.gpa.free(owned);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, prompt_title), .purpose = .{ .session_worktree_name = .{ .product = product, .profile = owned } } } };
    app.overlay.prompt.state.setText(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's accept: the tree at `<root>/<name>` on branch `<name>`
/// from the workspace repository's `HEAD`, then the session there —
/// its cwd the tree, `MNML_WORKSPACE` pointing at it, the tab labelled
/// `<product> @ <name>` — and the registry row. The pane id.
pub fn acceptName(app: *App, product: Config.AiProduct, profile: []const u8, text: []const u8) CommandError!app_mod.PaneId {
    const arena = app.frame.allocator();
    const name = std.mem.trim(u8, text, " \t\r\n");
    if (name.len == 0) return app.diag.fail(arena, "worktree: a name is needed", .{});
    const repo = (try repoRoot(app, arena, app.workspace)) orelse return app.diag.fail(arena, "worktree: {s} is not in a git repository", .{app.workspace});
    const l = try launch_profiles.launch(app, arena, product, profile);
    const path = try create(app, arena, repo, name);
    const id = pty_pane.openSession(app, .{
        .argv = l.argv,
        .cwd = path,
        .label = try std.fmt.allocPrint(arena, "{s} @ {s}", .{ l.label, name }),
        .placement = .right,
        .kind = .command,
        .env_extra = &.{try std.fmt.allocPrint(arena, "MNML_WORKSPACE={s}", .{path})},
    }) catch |err| {
        // The tree stays (it is a plain worktree the user can see in
        // the git panel); the reason is the spawn's.
        return err;
    };
    try app.sessions.worktrees.add(app.gpa, path, name, name, repo, null);
    app.toast("worktree {s}: {s} on branch {s}", .{ name, path, name });
    return id;
}

/// `acceptName` for the prompt's dispatch (no id to keep).
pub fn acceptNameCmd(app: *App, product: Config.AiProduct, profile: []const u8, text: []const u8) CommandError!void {
    _ = try acceptName(app, product, profile, text);
}

// ─── merge / remove, behind a named confirm ─────────────────────────────

pub const merge_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'm', .label = "Merge" }, .{ .key = 'c', .label = "Cancel" } };
pub const remove_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'r', .label = "Remove" }, .{ .key = 'c', .label = "Cancel" } };
/// A tree with uncommitted or untracked files: *Keep the files* tries
/// the remove without `--force` (git refuses, nothing is lost), *Remove
/// anyway* throws them away.
pub const remove_dirty_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'k', .label = "Keep the files" }, .{ .key = 'r', .label = "Remove anyway" }, .{ .key = 'c', .label = "Cancel" } };
pub const force_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'f', .label = "Force" }, .{ .key = 'c', .label = "Cancel" } };

fn openConfirm(app: *App, title: []const u8, msg: []u8, choices: []const app_mod.Confirm.Choice, purpose: app_mod.ConfirmPurpose) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = title, .message = msg, .choices = choices },
        .purpose = purpose,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// *Merge into <branch>…*: `Merge feat into main? (N commits)`.
pub fn confirmMerge(app: *App, e: Entry) CommandError!void {
    const arena = app.frame.allocator();
    if (!exists(app.io, e.path) and !(try branchExists(app, arena, e.repo, e.branch))) return app.diag.fail(arena, "merge {s}: the worktree and its branch are gone", .{e.name});
    const into = try currentBranch(app, arena, e.repo);
    const n = (try commitsAhead(app, arena, e.repo, e.branch)) orelse 0;
    const path = try app.gpa.dupe(u8, e.path);
    errdefer app.gpa.free(path);
    const msg = try std.fmt.allocPrint(app.gpa, "Merge {s} into {s}? ({d} commit{s})", .{ e.branch, into, n, if (n == 1) "" else "s" });
    errdefer app.gpa.free(msg);
    openConfirm(app, "Merge worktree", msg, &merge_choices, .{ .session_worktree_merge = path });
}

pub fn acceptMerge(app: *App, path: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const e = app.sessions.worktrees.byPath(path) orelse return app.diag.fail(arena, "merge: {s} is no session worktree any more", .{path});
    return merge(app, arena, e.*);
}

/// *Remove worktree…*: `Remove worktree feat and branch feat?`. A tree
/// holding uncommitted or untracked files says how many and offers
/// *Keep the files* / *Remove anyway*. Refused while a session runs in
/// the tree.
pub fn confirmRemove(app: *App, e: Entry) CommandError!void {
    const arena = app.frame.allocator();
    try refuseLive(app, arena, e);
    const dirty: u32 = if (exists(app.io, e.path)) try dirtyCount(app, arena, e.path) else 0;
    const path = try app.gpa.dupe(u8, e.path);
    errdefer app.gpa.free(path);
    const msg = if (dirty > 0)
        try std.fmt.allocPrint(app.gpa, "Remove worktree {s} and branch {s}? {d} uncommitted file{s} in it — Remove anyway throws {s} away.", .{ e.name, e.branch, dirty, if (dirty == 1) "" else "s", if (dirty == 1) "it" else "them" })
    else
        try std.fmt.allocPrint(app.gpa, "Remove worktree {s} and branch {s}?", .{ e.name, e.branch });
    errdefer app.gpa.free(msg);
    openConfirm(app, "Remove worktree", msg, if (dirty > 0) &remove_dirty_choices else &remove_choices, .{ .session_worktree_remove = .{ .path = path, .stage = .tree, .dirty = dirty } });
}

/// The second confirm, past an unmerged branch. It names what its yes
/// throws away: the branch's commits, and the tree's files when the
/// first confirm's answer was *Remove anyway*.
fn confirmRemoveBranch(app: *App, e: Entry, force_tree: bool, dirty: u32) CommandError!void {
    const arena = app.frame.allocator();
    const n = (try commitsAhead(app, arena, e.repo, e.branch)) orelse 0;
    const path = try app.gpa.dupe(u8, e.path);
    errdefer app.gpa.free(path);
    const msg = if (force_tree and dirty > 0)
        try std.fmt.allocPrint(app.gpa, "Branch {s} is not merged ({d} commit{s}) and worktree {s} has {d} uncommitted file{s} — throw both away?", .{ e.branch, n, if (n == 1) "" else "s", e.name, dirty, if (dirty == 1) "" else "s" })
    else
        try std.fmt.allocPrint(app.gpa, "Branch {s} is not merged ({d} commit{s}) — remove worktree {s} and delete the branch anyway?", .{ e.branch, n, if (n == 1) "" else "s", e.name });
    errdefer app.gpa.free(msg);
    openConfirm(app, "Remove unmerged worktree", msg, &force_choices, .{ .session_worktree_remove = .{ .path = path, .stage = .branch, .force_tree = force_tree, .dirty = dirty } });
}

/// A remove confirm's answer, by stage: the first confirm's (Remove,
/// or Keep the files / Remove anyway), then the unmerged branch's.
pub fn acceptRemoveChoice(app: *App, r: app_mod.ConfirmPurpose.SessionWorktreeRemove, choice: usize) CommandError!void {
    switch (r.stage) {
        .tree => {
            const force_tree = if (r.dirty > 0) switch (choice) {
                0 => false,
                1 => true,
                else => return,
            } else if (choice == 0) false else return;
            return acceptRemove(app, r.path, .{ .tree = force_tree });
        },
        .branch => if (choice == 0) return acceptRemove(app, r.path, .{ .branch = true, .tree = r.force_tree }),
    }
}

/// Past the first confirm. A dirty tree the user keeps is removed
/// without `--force` straight away — git refuses and nothing is asked
/// about the branch; an unmerged branch asks once more.
pub fn acceptRemove(app: *App, path: []const u8, force: RemoveForce) CommandError!void {
    const arena = app.frame.allocator();
    const e = app.sessions.worktrees.byPath(path) orelse return app.diag.fail(arena, "remove: {s} is no session worktree any more", .{path});
    try refuseLive(app, arena, e.*);
    const here = exists(app.io, e.path);
    const dirty: u32 = if (here) try dirtyCount(app, arena, e.path) else 0;
    if (!force.tree and dirty > 0) {
        // No `--force`: git refuses a tree with changes, and says so.
        const out = try run(app, arena, e.repo, &.{ "worktree", "remove", e.path });
        if (!out.ok) return app.diag.fail(arena, "kept worktree {s} and its {d} uncommitted file{s} — nothing removed ({s})", .{ e.name, dirty, if (dirty == 1) "" else "s", out.reason() });
        // The files went meanwhile and git took the tree: the branch next.
    }
    if (!force.branch and here and !(try isMerged(app, arena, e.repo, e.branch))) return confirmRemoveBranch(app, e.*, force.tree, dirty);
    return remove(app, arena, e.*, force);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "validName: a directory name and a branch name at once" {
    try t.expect(validName("feat"));
    try t.expect(validName("session-1"));
    try t.expect(validName("feat/login"));
    try t.expect(validName("v1.2_rc"));
    try t.expect(!validName(""));
    try t.expect(!validName("-x"));
    try t.expect(!validName(".x"));
    try t.expect(!validName("/x"));
    try t.expect(!validName("x/"));
    try t.expect(!validName("x."));
    try t.expect(!validName("a..b"));
    try t.expect(!validName("a//b"));
    try t.expect(!validName("a b"));
    try t.expect(!validName("x.lock"));
    try t.expect(!validName("a@{b"));
    try t.expect(!validName("@"));
    try t.expect(!validName("a~b"));
}

test "rootFor: <repo>-worktrees beside the repo; the override with ~ expanded, relative under the repo, absolute as is" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("/p/mnml-zig-worktrees", try rootFor(a, "/p/mnml-zig", null, "/home/x"));
    try t.expectEqualStrings("/p/mnml-zig-worktrees", try rootFor(a, "/p/mnml-zig/", "  ", "/home/x"));
    try sdk_testing.expectPath("/home/x/wt", try rootFor(a, "/p/mnml-zig", "~/wt", "/home/x"));
    try t.expectEqualStrings("/home/x", try rootFor(a, "/p/mnml-zig", "~", "/home/x"));
    try t.expectEqualStrings("/p/mnml-zig/.worktrees", try rootFor(a, "/p/mnml-zig", ".worktrees", "/home/x"));
    try t.expectEqualStrings("/srv/trees", try rootFor(a, "/p/mnml-zig", "/srv/trees", "/home/x"));
    try t.expectEqualStrings("/p/mnml-zig-worktrees/feat", try pathFor(a, "/p/mnml-zig-worktrees", "feat"));
}

test "suggestName skips the directories that exist" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("session-1", try suggestName(a, t.io, root, "session"));
    try tmp.dir.createDirPath(t.io, "session-1");
    try tmp.dir.createDirPath(t.io, "session-2");
    try t.expectEqualStrings("session-3", try suggestName(a, t.io, root, "session"));
    try t.expectEqualStrings("work-1", try suggestName(a, t.io, root, "work"));
}

test "registry: add / replace by path, of() by id then cwd, learn takes the id once, remove" {
    var r: Registry = .{};
    defer r.deinit(t.allocator);
    try r.add(t.allocator, "/w/feat", "feat", "feat", "/w", null);
    try r.add(t.allocator, "/w/fix", "fix", "fix", "/w", "sid-2");
    try t.expectEqual(@as(usize, 2), r.items.items.len);
    try t.expect(r.of("nope", "/w/feat") != null);
    try t.expect(r.of("sid-2", null) != null);
    try t.expect(r.of("nope", "/elsewhere") == null);
    try t.expect(try r.learn(t.allocator, "sid-1", "/w/feat"));
    try t.expect(!try r.learn(t.allocator, "sid-1", "/w/feat"));
    try t.expect(!try r.learn(t.allocator, "sid-3", "/w/feat"));
    try t.expectEqualStrings("sid-1", r.bySession("sid-1").?.session_id.?);
    try r.add(t.allocator, "/w/feat", "feat", "feat2", "/w", null);
    try t.expectEqual(@as(usize, 2), r.items.items.len);
    try t.expectEqualStrings("feat2", r.byPath("/w/feat").?.branch);
    try t.expect(r.byPath("/w/feat").?.session_id == null);
    try t.expect(r.remove(t.allocator, "/w/fix"));
    try t.expect(!r.remove(t.allocator, "/w/fix"));
    try t.expectEqual(@as(usize, 1), r.items.items.len);
}

/// A repository under a tmp dir with one commit on `main`.
const RepoFixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    repo: []u8,
    app: App,

    fn init() !RepoFixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        const repo = try std.fs.path.join(t.allocator, &.{ root, "repo" });
        errdefer t.allocator.free(repo);
        try tmp.dir.createDirPath(t.io, "repo");
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = repo, .data_root = root, .cols = 100, .rows = 30 });
        errdefer app.deinit();
        var f: RepoFixture = .{ .tmp = tmp, .root = root, .repo = repo, .app = app };
        try f.sh(repo, &.{ "init", "-q", "-b", "main" });
        // The `-c` prefix below only reaches the test's own git. `merge`
        // makes a commit through a child process that carries none, so on
        // a machine with no global identity — a container, a CI runner —
        // git refused with "Author identity unknown". The repository gets
        // its own.
        try f.sh(repo, &.{ "config", "user.email", "t@mnml.dev" });
        try f.sh(repo, &.{ "config", "user.name", "t" });
        try f.sh(repo, &.{ "config", "commit.gpgsign", "false" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "repo/a.txt", .data = "one\n" });
        try f.sh(repo, &.{ "add", "a.txt" });
        try f.sh(repo, &.{ "commit", "-q", "-m", "first" });
        return f;
    }

    fn deinit(f: *RepoFixture) void {
        f.app.deinit();
        t.allocator.free(f.repo);
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// The test's own git, with an identity.
    fn sh(_: *RepoFixture, cwd: []const u8, args: []const []const u8) !void {
        const prefix = [_][]const u8{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=t", "-c", "commit.gpgsign=false" };
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(t.allocator);
        try argv.appendSlice(t.allocator, &prefix);
        try argv.appendSlice(t.allocator, args);
        const res = try std.process.run(t.allocator, t.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
        defer t.allocator.free(res.stdout);
        defer t.allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("git {s}: {s}\n", .{ args[0], res.stderr });
            return error.GitFailed;
        }
    }
};

test "create refuses a bad name, an existing directory and an existing branch; makes <repo>-worktrees/<name> on branch <name>, logged" {
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    try t.expectError(error.Failed, create(app, a, f.repo, "bad name"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "not a branch name") != null);
    try f.sh(f.repo, &.{ "branch", "taken" });
    try t.expectError(error.Failed, create(app, a, f.repo, "taken"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "branch `taken` exists") != null);
    const path = try create(app, a, f.repo, "feat");
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ f.root, "repo-worktrees", "feat" }), path);
    try t.expect(exists(t.io, path));
    try t.expect(try branchExists(app, a, f.repo, "feat"));
    try t.expectEqualStrings("feat", try currentBranch(app, a, path));
    // The directory is in the way now.
    try t.expectError(error.Failed, create(app, a, f.repo, "feat"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "exists already") != null);
    // Every child is a command-log line, the worktree add among them.
    var saw = false;
    for (app.git.log.items.items) |e| if (std.mem.indexOf(u8, e.argv, "worktree add -b feat") != null) {
        saw = true;
        try t.expect(e.ok);
    };
    try t.expect(saw);
    // The override: a relative root sits under the repo.
    app.cfg.ai.default_worktree_root = ".trees";
    const p2 = try create(app, a, f.repo, "other");
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ f.repo, ".trees", "other" }), p2);
}

test "merge refuses a dirty main tree, then lands the worktree's commit on main; remove refuses an unmerged branch unless forced" {
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    const path = try create(app, a, f.repo, "feat");
    try app.sessions.worktrees.add(app.gpa, path, "feat", "feat", f.repo, null);
    const e = app.sessions.worktrees.byPath(path).?.*;
    // A commit in the tree; the main tree edits a tracked file.
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "wt.txt" }), .data = "from the worktree\n" });
    try f.sh(path, &.{ "add", "wt.txt" });
    try f.sh(path, &.{ "commit", "-q", "-m", "from the worktree" });
    try t.expectEqual(@as(?u32, 1), try commitsAhead(app, a, f.repo, "feat"));
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "repo/a.txt", .data = "two\n" });
    try t.expect(try isDirty(app, a, f.repo));
    try t.expectError(error.Failed, merge(app, a, e));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "uncommitted changes") != null);
    try t.expect(!try isMerged(app, a, f.repo, "feat"));
    // An unmerged branch is not removed without force.
    try t.expectError(error.Failed, remove(app, a, e, .{}));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "1 unmerged commit") != null);
    try t.expect(exists(t.io, path));
    // Clean, the merge lands: main has the commit, the toast says so.
    try f.sh(f.repo, &.{ "checkout", "-q", "--", "a.txt" });
    try merge(app, a, e);
    try t.expectEqualStrings("merged feat into main", app.lastToast().?);
    try t.expect(try isMerged(app, a, f.repo, "feat"));
    const log = try run(app, a, f.repo, &.{ "log", "--oneline", "main" });
    try t.expect(std.mem.indexOf(u8, log.stdout, "from the worktree") != null);
    // Merged: the plain remove takes the tree, the branch and the row.
    try remove(app, a, e, .{});
    try t.expect(!exists(t.io, path));
    try t.expect(!try branchExists(app, a, f.repo, "feat"));
    try t.expect(app.sessions.worktrees.byPath(path) == null);
    try t.expect(!exists(t.io, std.fs.path.dirname(path).?));
    try t.expectEqualStrings("removed worktree feat", app.lastToast().?);
    // Unmerged + force: gone too.
    const p2 = try create(app, a, f.repo, "drop");
    try app.sessions.worktrees.add(app.gpa, p2, "drop", "drop", f.repo, "sid-9");
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ p2, "x.txt" }), .data = "x\n" });
    try f.sh(p2, &.{ "add", "x.txt" });
    try f.sh(p2, &.{ "commit", "-q", "-m", "dropped" });
    const e2 = app.sessions.worktrees.byPath(p2).?.*;
    try t.expectError(error.Failed, remove(app, a, e2, .{}));
    try remove(app, a, e2, .{ .branch = true, .tree = true });
    try t.expect(!exists(t.io, p2));
    try t.expect(!try branchExists(app, a, f.repo, "drop"));
    // A failed merge: a conflicting change on main opens the command log.
    const p3 = try create(app, a, f.repo, "clash");
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ p3, "a.txt" }), .data = "theirs\n" });
    try f.sh(p3, &.{ "commit", "-q", "-am", "theirs" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "repo/a.txt", .data = "ours\n" });
    try f.sh(f.repo, &.{ "commit", "-q", "-am", "ours" });
    try t.expectError(error.Failed, merge(app, a, .{ .path = @constCast(p3), .name = @constCast("clash"), .branch = @constCast("clash"), .repo = f.repo }));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "merge clash into main failed") != null);
    var log_pane = false;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.* == .list and p.list.kind == .git_log) {
        log_pane = true;
    };
    try t.expect(log_pane);
    try f.sh(f.repo, &.{ "merge", "--abort" });
}

test "the launch: the prompt is seeded with the first free session-<n>; accept makes the tree and opens the session there with MNML_WORKSPACE set" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    // A profile whose "claude" is a shell printing the workspace it was given.
    const profiles = [_]Config.LaunchProfile{.{ .name = "sh", .binary = "/bin/sh", .args = &.{ "-c", "if [ \"$MNML_WORKSPACE\" = \"$PWD\" ]; then echo WS=cwd; else echo WS=other; fi; sleep 30" } }};
    app.cfg.ai.launch_profiles = &profiles;
    try openNamePrompt(app, .claude, launch_profiles.builtin_name);
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings(prompt_title, app.overlay.prompt.state.title);
    try t.expectEqualStrings("session-1", app.overlay.prompt.state.buf.items);
    try t.expect(app.overlay.prompt.purpose == .session_worktree_name);
    try t.expectEqualStrings(launch_profiles.builtin_name, app.overlay.prompt.purpose.session_worktree_name.profile);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // A named profile seeds with its name.
    try openNamePrompt(app, .claude, "sh");
    try t.expectEqualStrings("sh-1", app.overlay.prompt.state.buf.items);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;

    const id = try acceptName(app, .claude, "sh", " feat ");
    const wt = try std.fs.path.join(app.frame.allocator(), &.{ f.root, "repo-worktrees", "feat" });
    const pane = app.panes.pty(id).?;
    try t.expectEqualStrings(wt, pane.cwd.?);
    try t.expectEqualStrings("claude (sh) @ feat", pane.label);
    try t.expectEqualStrings("feat", app.sessions.worktrees.byPath(wt).?.name);
    try t.expectEqualStrings(f.repo, app.sessions.worktrees.byPath(wt).?.repo);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "worktree feat: "));
    // The child ran in the tree with MNML_WORKSPACE naming that very
    // directory (the shell compares the two; a long tmp path would wrap).
    try t.expect(try pty_pane.tickUntilScreen(app, "WS=cwd", 4000));
    // A second accept with the same name is refused, the tree untouched.
    try t.expectError(error.Failed, acceptName(app, .claude, "sh", "feat"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "exists already") != null);
    try t.expectError(error.Failed, acceptName(app, .claude, "sh", "  "));
}

test "a profile with .worktree opens the name prompt from openSessionWith; the chip's worktree row does the same" {
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const profiles = [_]Config.LaunchProfile{.{ .name = "trees", .binary = "claude", .worktree = true }};
    app.cfg.ai.launch_profiles = &profiles;
    try t.expect((try launch_profiles.openSessionWith(app, .claude, "trees", .right)) == null);
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("trees-1", app.overlay.prompt.state.buf.items);
    try t.expectEqualStrings("trees", app.overlay.prompt.purpose.session_worktree_name.profile);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    const items = try launch_profiles.menuItems(app, t.allocator, .claude);
    defer {
        for (items) |it| t.allocator.free(it.label);
        t.allocator.free(items);
    }
    var row: ?command.AiProfileAction = null;
    for (items) |it| if (std.mem.eql(u8, it.label, launch_profiles.worktree_label)) {
        row = it.action.ai_profile;
    };
    try t.expect(row.?.worktree);
    try launch_profiles.menuAction(app, row.?);
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("session-1", app.overlay.prompt.state.buf.items);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // Where there is no work tree (a bare repository stands in for a
    // directory outside every repo — the test's tmp dir is under this
    // checkout) the prompt is refused with the reason.
    try f.tmp.dir.createDirPath(t.io, "bare.git");
    const bare_path = try std.fs.path.join(t.allocator, &.{ f.root, "bare.git" });
    defer t.allocator.free(bare_path);
    try f.sh(bare_path, &.{ "init", "-q", "--bare" });
    var bare = try App.initWith(t.allocator, t.io, .{ .workspace = bare_path, .cols = 80, .rows = 20 });
    defer bare.deinit();
    try t.expectError(error.Failed, openNamePrompt(&bare, .claude, launch_profiles.builtin_name));
    try t.expect(std.mem.indexOf(u8, bare.diag.msg.?, "not in a git repository") != null);
}

test "merge / remove go through a named confirm; an unmerged branch asks a second time with Force" {
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    const path = try create(app, a, f.repo, "feat");
    try app.sessions.worktrees.add(app.gpa, path, "feat", "feat", f.repo, "sid-1");
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "wt.txt" }), .data = "x\n" });
    try f.sh(path, &.{ "add", "wt.txt" });
    try f.sh(path, &.{ "commit", "-q", "-m", "one" });
    const e = app.sessions.worktrees.byPath(path).?.*;
    // Remove, unmerged: the first confirm, then the Force one.
    try confirmRemove(app, e);
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Remove worktree", app.overlay.confirm.state.title);
    try t.expectEqualStrings("Remove worktree feat and branch feat?", app.overlay.confirm.message);
    try t.expect(app.overlay.confirm.purpose.session_worktree_remove.stage == .tree);
    try acceptRemove(app, path, .{});
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Remove unmerged worktree", app.overlay.confirm.state.title);
    try t.expect(app.overlay.confirm.purpose.session_worktree_remove.stage == .branch);
    try t.expect(!app.overlay.confirm.purpose.session_worktree_remove.force_tree);
    try t.expectEqualStrings("Branch feat is not merged (1 commit) — remove worktree feat and delete the branch anyway?", app.overlay.confirm.message);
    try t.expectEqualStrings("Force", app.overlay.confirm.state.choices[0].label);
    try t.expect(exists(t.io, path));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // Merge: the confirm counts the commits; its yes lands them.
    try confirmMerge(app, e);
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Merge feat into main? (1 commit)", app.overlay.confirm.message);
    try t.expectEqualStrings(path, app.overlay.confirm.purpose.session_worktree_merge);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try acceptMerge(app, path);
    try t.expectEqualStrings("merged feat into main", app.lastToast().?);
    try t.expect(try isMerged(app, a, f.repo, "feat"));
    // Merged: the plain remove goes straight through.
    try acceptRemove(app, path, .{});
    try t.expect(app.overlay != .confirm);
    try t.expect(!exists(t.io, path));
    try t.expect(app.sessions.worktrees.byPath(path) == null);
    try t.expectError(error.Failed, acceptMerge(app, path));
}

test "remove: a dirty tree's confirm counts its files and offers Keep the files / Remove anyway; keeping fails cleanly, removing anyway names them again past an unmerged branch; a live session refuses it" {
    // sess-worktree-remove-destroys-uncommitted.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    const path = try create(app, a, f.repo, "feat");
    try app.sessions.worktrees.add(app.gpa, path, "feat", "feat", f.repo, null);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "wt.txt" }), .data = "x\n" });
    try f.sh(path, &.{ "add", "wt.txt" });
    try f.sh(path, &.{ "commit", "-q", "-m", "one" });
    // Mid-task: an untracked draft and an edit to a tracked file.
    const draft = try std.fs.path.join(a, &.{ path, "draft.txt" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = draft, .data = "half\n" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "a.txt" }), .data = "edit\n" });
    try t.expectEqual(@as(u32, 2), try dirtyCount(app, a, path));
    const e = app.sessions.worktrees.byPath(path).?.*;
    try confirmRemove(app, e);
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Remove worktree feat and branch feat? 2 uncommitted files in it — Remove anyway throws them away.", app.overlay.confirm.message);
    try t.expectEqualStrings("Keep the files", app.overlay.confirm.state.choices[0].label);
    try t.expectEqualStrings("Remove anyway", app.overlay.confirm.state.choices[1].label);
    const r = app.overlay.confirm.purpose.session_worktree_remove;
    try t.expectEqual(@as(u32, 2), r.dirty);
    // Keep the files: no `--force`, git refuses, everything is still there.
    try t.expectError(error.Failed, acceptRemoveChoice(app, r, 0));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "kept worktree feat and its 2 uncommitted files") != null);
    try t.expect(exists(t.io, draft));
    try t.expect(try branchExists(app, a, f.repo, "feat"));
    try t.expect(app.sessions.worktrees.byPath(path) != null);
    for (app.git.log.items.items) |le| try t.expect(std.mem.indexOf(u8, le.argv, "--force") == null);
    // Remove anyway: the branch is unmerged, so the second confirm, and
    // it says the files go as well.
    try acceptRemoveChoice(app, r, 1);
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Branch feat is not merged (1 commit) and worktree feat has 2 uncommitted files — throw both away?", app.overlay.confirm.message);
    const r2 = app.overlay.confirm.purpose.session_worktree_remove;
    try t.expect(r2.stage == .branch and r2.force_tree);
    try t.expect(exists(t.io, draft));
    // Cancel changes nothing; Force takes both.
    try acceptRemoveChoice(app, r2, 1);
    try t.expect(exists(t.io, draft));
    try acceptRemoveChoice(app, r2, 0);
    try t.expect(!exists(t.io, path));
    try t.expect(!try branchExists(app, a, f.repo, "feat"));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // A session running in the tree: the remove is refused, before any confirm.
    const p2 = try create(app, a, f.repo, "busy");
    try app.sessions.worktrees.add(app.gpa, p2, "busy", "busy", f.repo, null);
    const pid = try pty_pane.open(app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .cwd = p2, .label = "claude", .kind = .command, .placement = .tab });
    const e2 = app.sessions.worktrees.byPath(p2).?.*;
    try t.expectEqual(pid, livePaneIn(app, e2).?);
    try t.expectError(error.Failed, confirmRemove(app, e2));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "still running") != null);
    try t.expect(app.overlay != .confirm);
    try t.expectError(error.Failed, remove(app, a, e2, .{ .branch = true, .tree = true }));
    try t.expect(exists(t.io, p2));
}

test "remove: a session tree whose directory is gone drops its own entry — the user's worktree that is only away for a moment survives" {
    // sess-worktree-remove-prunes-user-worktrees.
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    const mine = try std.fs.path.join(a, &.{ f.root, "mine" });
    try f.sh(f.repo, &.{ "worktree", "add", "-q", "-b", "mine", mine });
    const path = try create(app, a, f.repo, "session-1");
    try app.sessions.worktrees.add(app.gpa, path, "session-1", "session-1", f.repo, null);
    try Io.Dir.cwd().deleteTree(t.io, path);
    const away = try std.fs.path.join(a, &.{ f.root, "mine-away" });
    try Io.Dir.cwd().rename(mine, Io.Dir.cwd(), away, t.io);
    try remove(app, a, app.sessions.worktrees.byPath(path).?.*, .{});
    try t.expectEqualStrings("removed worktree session-1", app.lastToast().?);
    const list = try run(app, a, f.repo, &.{ "worktree", "list", "--porcelain" });
    try t.expect(std.mem.indexOf(u8, list.stdout, "branch refs/heads/mine") != null);
    try t.expect(std.mem.indexOf(u8, list.stdout, "session-1") == null);
    for (app.git.log.items.items) |le| try t.expect(std.mem.indexOf(u8, le.argv, "prune") == null);
}

test "a session that ends with its worktree still there toasts once with the commit count; a tree that is gone, or a live session, toasts nothing" {
    const sessions = @import("../sessions.zig");
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    const path = try create(app, a, f.repo, "feat");
    try app.sessions.worktrees.add(app.gpa, path, "feat", "feat", f.repo, null);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "wt.txt" }), .data = "x\n" });
    try f.sh(path, &.{ "add", "wt.txt" });
    try f.sh(path, &.{ "commit", "-q", "-m", "one" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "wt2.txt" }), .data = "y\n" });
    try f.sh(path, &.{ "add", "wt2.txt" });
    try f.sh(path, &.{ "commit", "-q", "-m", "two" });
    const listing = struct {
        fn post(fx: *RepoFixture, wt: []const u8, state: @import("agents.zig").AgentState, gen: u32) !void {
            const r = try sessions.ScanResult.create(t.allocator, gen);
            const items = try r.arena.allocator().alloc(sessions.Item, 1);
            items[0] = sessions.testItem("sid-1", state, 30, "feat", "ship it");
            items[0].cwd = try r.arena.allocator().dupe(u8, wt);
            r.items = items;
            fx.app.sessions.generation = gen;
            try sessions.handle(&fx.app, r);
        }
    };
    const msgs = &app.messages.items;
    try listing.post(&f, path, .streaming, 1);
    const before = msgs.items.len;
    try listing.post(&f, path, .idle, 2);
    try t.expectEqual(before, msgs.items.len);
    try listing.post(&f, path, .done, 3);
    try t.expectEqual(before + 1, msgs.items.len);
    try t.expectEqualStrings("session ship it ended — its worktree feat has 2 commits: merge / remove / keep (row menu)", msgs.items[msgs.items.len - 1].text);
    try t.expectEqual(app_mod.ToastLevel.warn, msgs.items[msgs.items.len - 1].level);
    // The same listing again: quiet. Back to live and ended again: once more.
    try listing.post(&f, path, .done, 4);
    try t.expectEqual(before + 1, msgs.items.len);
    try listing.post(&f, path, .streaming, 5);
    try listing.post(&f, path, .failed, 6);
    try t.expectEqual(before + 3, msgs.items.len); // the failed toast, then the worktree's
    try t.expect(std.mem.indexOf(u8, msgs.items[msgs.items.len - 1].text, "its worktree feat") != null);
    // The tree removed: an ended session says nothing about it.
    try remove(app, a, app.sessions.worktrees.byPath(path).?.*, .{ .branch = true, .tree = true });
    const after_remove = msgs.items.len;
    try listing.post(&f, path, .streaming, 7);
    try listing.post(&f, path, .done, 8);
    try t.expectEqual(after_remove, msgs.items.len);
}

test "the name seed skips a local branch that already has the name, as it skips a directory" {
    // sess-small-drift (3).
    var f = try RepoFixture.init();
    defer f.deinit();
    const app = &f.app;
    const a = app.frame.allocator();
    const root = try rootOf(app, a, f.repo);
    try t.expectEqualStrings("session-1", try freeName(app, a, f.repo, root, "session"));
    // The user's own `session-1` branch, no tree: the seed moves past it.
    try f.sh(f.repo, &.{ "branch", "session-1" });
    try t.expectEqualStrings("session-2", try freeName(app, a, f.repo, root, "session"));
    // A tree at session-2 and a branch session-3: the next free is 4.
    _ = try create(app, a, f.repo, "session-2");
    try f.sh(f.repo, &.{ "branch", "session-3" });
    try t.expectEqualStrings("session-4", try freeName(app, a, f.repo, root, "session"));
    // The prompt is seeded with it.
    try openNamePrompt(app, .claude, launch_profiles.builtin_name);
    try t.expectEqualStrings("session-4", app.overlay.prompt.state.buf.items);
}
