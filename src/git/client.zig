//! The git worker (D3). One `Repo` per repository the workspace knows;
//! each runs one task in its own `Io.Group` that takes `Job`s off a
//! queue, shells `git` for each, and posts the outcome as `.git = *Result`.
//! Nothing here touches `App`: the UI thread submits jobs and adopts
//! results, and that is the whole contract.
//!
//! Serialising a repo's jobs through one queue is what makes the
//! operation-level undo stack simple: the stack lives with the worker,
//! so `commit` then `undo` cannot race, and the UI thread never holds a
//! sha it has to keep level with the repo.
//!
//! D1: a `Job` owns its strings until the worker has run it; a `Result`
//! owns its arena until the handler adopts or destroys it. Workers never
//! toast — a failure is an `op` result with `ok = false`, or `.err`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const remote_mod = @import("remote.zig");
const event = @import("../core/event.zig");

/// What a diff pane shows. `file` and `head` are against HEAD (staged
/// and unstaged together — what the gate's `git diff HEAD` names);
/// `worktree` is unstaged only; `staged` the index; `commit` a `show`.
pub const DiffScope = enum { file, worktree, head, staged, commit, orig };

pub const LogFilter = struct {
    branch: ?[]u8 = null,
    author: ?[]u8 = null,
    subject: ?[]u8 = null,
    since: ?[]u8 = null,
    until: ?[]u8 = null,
    /// A file's history.
    path: ?[]u8 = null,

    pub fn deinit(f: LogFilter, gpa: Allocator) void {
        inline for (.{ f.branch, f.author, f.subject, f.since, f.until, f.path }) |s| if (s) |x| gpa.free(x);
    }

    pub fn dupe(f: LogFilter, gpa: Allocator) Allocator.Error!LogFilter {
        var out: LogFilter = .{};
        errdefer out.deinit(gpa);
        if (f.branch) |s| out.branch = try gpa.dupe(u8, s);
        if (f.author) |s| out.author = try gpa.dupe(u8, s);
        if (f.subject) |s| out.subject = try gpa.dupe(u8, s);
        if (f.since) |s| out.since = try gpa.dupe(u8, s);
        if (f.until) |s| out.until = try gpa.dupe(u8, s);
        if (f.path) |s| out.path = try gpa.dupe(u8, s);
        return out;
    }
};

pub const ListKind = enum { stashes, tags, reflog, worktrees };

/// What `browse` opens: the file, the file at a line, or a commit.
pub const BrowseKind = enum { file, line, commit };

/// One unit of work. Strings are gpa-owned by the job (`deinit`).
pub const Job = union(enum) {
    /// `status --porcelain=v2 -b` plus `diff -U0 HEAD` for the gutter.
    status,
    /// `full` asks for every line of the file (the Inline / Split views)
    /// instead of three lines of context.
    diff: struct { scope: DiffScope, path: ?[]u8 = null, rev: ?[]u8 = null, text: ?[]u8 = null, full: bool = false },
    blame: []u8,
    log: struct { n: u32, filter: LogFilter },
    branches,
    list: ListKind,
    stage: []u8,
    unstage: []u8,
    stage_all,
    unstage_all,
    discard: []u8,
    apply_patch: struct { patch: []u8, cached: bool, reverse: bool, desc: []u8 },
    commit: []u8,
    checkout: []u8,
    new_branch: []u8,
    delete_branch: []u8,
    merge: []u8,
    rebase: []u8,
    fetch,
    pull,
    push,
    push_tags,
    stash: ?[]u8,
    stash_pop,
    stash_apply: []u8,
    stash_drop: []u8,
    tag: []u8,
    tag_delete: []u8,
    cherry_pick: []u8,
    revert: []u8,
    undo,
    redo,
    browse: struct { kind: BrowseKind, path: ?[]u8 = null, line: u32 = 0, rev: ?[]u8 = null },
    worktree_add: struct { path: []u8, branch: ?[]u8 },
    worktree_remove: []u8,
    head_sha,

    pub fn deinit(j: Job, gpa: Allocator) void {
        switch (j) {
            .diff => |d| {
                if (d.path) |p| gpa.free(p);
                if (d.rev) |r| gpa.free(r);
                if (d.text) |t| gpa.free(t);
            },
            .log => |l| l.filter.deinit(gpa),
            .apply_patch => |a| {
                gpa.free(a.patch);
                gpa.free(a.desc);
            },
            .browse => |b| {
                if (b.path) |p| gpa.free(p);
                if (b.rev) |v| gpa.free(v);
            },
            .worktree_add => |w| {
                gpa.free(w.path);
                if (w.branch) |b| gpa.free(b);
            },
            .stash => |s| if (s) |m| gpa.free(m),
            .blame, .stage, .unstage, .discard, .commit, .checkout, .new_branch, .delete_branch, .merge, .rebase, .stash_apply, .stash_drop, .tag, .tag_delete, .cherry_pick, .revert, .worktree_remove => |s| gpa.free(s),
            .status, .branches, .list, .stage_all, .unstage_all, .fetch, .pull, .push, .push_tags, .stash_pop, .undo, .redo, .head_sha => {},
        }
    }
};

/// A finished job. Owned by the `.git` event; every slice in `payload`
/// borrows `arena`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// `Repo.id` of the worker that produced it.
    repo: u32,
    payload: Payload,

    pub const Payload = union(enum) {
        status: struct { status: parse.Status, signs: []parse.FileDiff, remote: []const u8 = "" },
        diff: struct { scope: DiffScope, path: ?[]const u8, rev: ?[]const u8, files: []parse.FileDiff, full: bool = false },
        blame: struct { path: []const u8, lines: []parse.BlameLine },
        log: struct { commits: []parse.Commit, path: ?[]const u8 },
        branches: []parse.Branch,
        list: struct { kind: ListKind, items: []const []const u8 },
        /// A mutating command finished. `desc` is the past-tense toast
        /// (`staged src/a.zig`); `msg` is git's own words when it failed.
        op: struct { desc: []const u8, ok: bool, msg: []const u8 = "", refresh: bool = true },
        url: []const u8,
        head_sha: []const u8,
    };

    pub fn create(gpa: Allocator, repo: u32) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .repo = repo, .payload = .{ .head_sha = "" } };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// An operation the worker can reverse. `reset_soft` moves HEAD and
/// keeps the index (a commit undone stays staged); `checkout` flips
/// the branch back.
const Action = union(enum) {
    reset_soft: []u8,
    checkout: []u8,

    fn deinit(a: Action, gpa: Allocator) void {
        switch (a) {
            .reset_soft, .checkout => |s| gpa.free(s),
        }
    }
};

const UndoEntry = struct {
    desc: []u8,
    undo: Action,
    redo: Action,

    fn deinit(e: UndoEntry, gpa: Allocator) void {
        gpa.free(e.desc);
        e.undo.deinit(gpa);
        e.redo.deinit(gpa);
    }
};

pub const queue_capacity = 64;

/// One repository: where it is, its job queue and the worker's group.
/// Heap-allocated so the worker's pointer stays put while the list of
/// repos is rebuilt around it.
pub const Repo = struct {
    gpa: Allocator,
    /// Absolute root (the directory holding `.git`). Owned.
    path: []u8,
    /// Its basename, or `.` for the workspace itself. Owned.
    name: []u8,
    /// Unique for the process; results name it.
    id: u32,
    is_workspace_root: bool,
    jobs: Io.Queue(Job),
    jobs_buf: []Job,
    group: Io.Group = .init,
    started: bool = false,
    /// The children's environment: the app's, plus no credential prompts.
    env: ?std.process.Environ.Map = null,
    /// Worker-owned: touched only by the worker task.
    undo: std.ArrayListUnmanaged(UndoEntry) = .empty,
    redo: std.ArrayListUnmanaged(UndoEntry) = .empty,
    /// Jobs submitted; the handler compares against `finished` to know
    /// whether the repo is busy (a spinner, a "pending" status).
    submitted: u32 = 0,

    pub fn create(gpa: Allocator, path: []const u8, name: []const u8, id: u32, is_workspace_root: bool) Allocator.Error!*Repo {
        const r = try gpa.create(Repo);
        errdefer gpa.destroy(r);
        const p = try gpa.dupe(u8, path);
        errdefer gpa.free(p);
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        const buf = try gpa.alloc(Job, queue_capacity);
        r.* = .{ .gpa = gpa, .path = p, .name = n, .id = id, .is_workspace_root = is_workspace_root, .jobs = .init(buf), .jobs_buf = buf };
        return r;
    }

    /// Stops the worker (waiting for it), drops queued jobs, frees the
    /// stacks. The worker borrows `events`, so the caller runs this
    /// before the queue closes.
    pub fn destroy(self: *Repo, io: Io) void {
        const gpa = self.gpa;
        self.group.cancel(io);
        self.jobs.close(io);
        var buf: [8]Job = undefined;
        while (true) {
            const n = self.jobs.getUncancelable(io, &buf, 0) catch 0;
            if (n == 0) break;
            for (buf[0..n]) |j| j.deinit(gpa);
        }
        for (self.undo.items) |e| e.deinit(gpa);
        self.undo.deinit(gpa);
        for (self.redo.items) |e| e.deinit(gpa);
        self.redo.deinit(gpa);
        if (self.env) |*e| e.deinit();
        gpa.free(self.jobs_buf);
        gpa.free(self.name);
        gpa.free(self.path);
        gpa.destroy(self);
    }

    /// Start the worker if it is not running. `env` is cloned once.
    pub fn start(self: *Repo, io: Io, events: *event.EventQueue, env: ?*const std.process.Environ.Map) (Allocator.Error || Io.ConcurrentError)!void {
        if (self.started) return;
        if (self.env == null) {
            var m = if (env) |e| try e.clone(self.gpa) else std.process.Environ.Map.init(self.gpa);
            errdefer m.deinit();
            try m.put("GIT_TERMINAL_PROMPT", "0");
            self.env = m;
        }
        try self.group.concurrent(io, worker, .{ self, events, io });
        self.started = true;
    }

    /// Queue a job. Takes ownership of its strings; a closed queue frees
    /// them. Returns false when the queue is full or closed.
    pub fn submit(self: *Repo, io: Io, job: Job) bool {
        self.jobs.putOneUncancelable(io, job) catch {
            job.deinit(self.gpa);
            return false;
        };
        self.submitted += 1;
        return true;
    }
};

// ─── the worker ─────────────────────────────────────────────────────────

fn worker(repo: *Repo, events: *event.EventQueue, io: Io) Io.Cancelable!void {
    var buf: [1]Job = undefined;
    while (true) {
        const n = repo.jobs.get(io, &buf, 1) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
        if (n == 0) continue;
        const job = buf[0];
        defer job.deinit(repo.gpa);
        runJob(repo, events, io, job) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => postErr(events, io, repo.gpa, "out of memory running git"),
        };
    }
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .git, .msg = owned } });
}

const JobError = Io.Cancelable || Allocator.Error;

/// What one `git` invocation left behind, on the result's arena.
const Out = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,

    /// git's explanation, one line, for a toast.
    fn reason(o: Out) []const u8 {
        const e = std.mem.trim(u8, o.stderr, " \t\r\n");
        const s = std.mem.trim(u8, o.stdout, " \t\r\n");
        const pick = if (e.len > 0) e else s;
        // The first line is the one that says what went wrong.
        const nl = std.mem.indexOfScalar(u8, pick, '\n') orelse pick.len;
        return pick[0..nl];
    }
};

/// Run `git --no-pager -c color.ui=never <args>` in the repo. Output
/// lands on `arena`. A spawn failure (no `git` on PATH) is `ok = false`
/// with the error name in `stderr`.
fn git(repo: *Repo, io: Io, arena: Allocator, args: []const []const u8, stdin_text: ?[]const u8) JobError!Out {
    const prefix = [_][]const u8{ "git", "--no-pager", "-c", "color.ui=never" };
    const argv = try arena.alloc([]const u8, prefix.len + args.len);
    @memcpy(argv[0..prefix.len], &prefix);
    @memcpy(argv[prefix.len..], args);
    if (stdin_text) |text| return gitWithStdin(repo, io, arena, argv, text);
    const res = std.process.run(repo.gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = if (repo.env) |*e| e else null,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .ok = false, .stdout = "", .stderr = try std.fmt.allocPrint(arena, "cannot run git: {s}", .{@errorName(err)}) },
    };
    defer repo.gpa.free(res.stdout);
    defer repo.gpa.free(res.stderr);
    return .{
        .ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        },
        .stdout = try arena.dupe(u8, res.stdout),
        .stderr = try arena.dupe(u8, res.stderr),
    };
}

/// `git apply` reads the patch from stdin: spawn by hand, write the
/// patch, close the pipe, then drain the output the way `process.run`
/// does.
fn gitWithStdin(repo: *Repo, io: Io, arena: Allocator, argv: []const []const u8, text: []const u8) JobError!Out {
    const gpa = repo.gpa;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = if (repo.env) |*e| e else null,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .ok = false, .stdout = "", .stderr = try std.fmt.allocPrint(arena, "cannot run git: {s}", .{@errorName(err)}) },
    };
    defer child.kill(io);
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, text) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Canceled => return error.Canceled,
        else => {},
    }
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return .{ .ok = false, .stdout = "", .stderr = try std.fmt.allocPrint(arena, "git: {s}", .{@errorName(err)}) },
    };
    const stdout = try arena.dupe(u8, multi_reader.reader(0).buffered());
    const stderr = try arena.dupe(u8, multi_reader.reader(1).buffered());
    return .{
        .ok = switch (term) {
            .exited => |c| c == 0,
            else => false,
        },
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Run one job and post its result. The result is owned here until
/// the post; every early return destroys it.
fn runJob(repo: *Repo, events: *event.EventQueue, io: Io, job: Job) JobError!void {
    const gpa = repo.gpa;
    const r = try Result.create(gpa, repo.id);
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    switch (job) {
        .status => {
            const st = try git(repo, io, arena, &.{ "status", "--porcelain=v2", "-b", "--untracked-files=all" }, null);
            if (!st.ok) {
                r.payload = .{ .op = .{ .desc = "status", .ok = false, .msg = st.reason(), .refresh = false } };
                events.post(io, .{ .git = r });
                return;
            }
            const status = try parse.parseStatus(arena, st.stdout);
            // Signs against HEAD; an initial repo has no HEAD and no signs.
            var signs: []parse.FileDiff = &.{};
            if (status.oid != null) {
                const d = try git(repo, io, arena, &.{ "diff", "--no-ext-diff", "-U0", "HEAD", "--" }, null);
                if (d.ok) signs = try parse.parseDiff(arena, d.stdout);
            }
            const remote = try git(repo, io, arena, &.{ "config", "--get", "remote.origin.url" }, null);
            r.payload = .{ .status = .{ .status = status, .signs = signs, .remote = if (remote.ok) trimmed(remote.stdout) else "" } };
        },
        .diff => |d| {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            const ctx: []const u8 = if (d.full) "-U999999" else "-U3";
            switch (d.scope) {
                .file => try args.appendSlice(arena, &.{ "diff", "--no-ext-diff", ctx, "HEAD", "--", d.path orelse "" }),
                .head => try args.appendSlice(arena, &.{ "diff", "--no-ext-diff", ctx, "HEAD", "--" }),
                .worktree => try args.appendSlice(arena, &.{ "diff", "--no-ext-diff", ctx, "--" }),
                .staged => {
                    try args.appendSlice(arena, &.{ "diff", "--no-ext-diff", ctx, "--cached", "--" });
                    if (d.path) |p| try args.append(arena, p);
                },
                .commit => {
                    try args.appendSlice(arena, &.{ "show", "--no-ext-diff", ctx, "--format=", d.rev orelse "HEAD", "--" });
                    if (d.path) |p| try args.append(arena, p);
                },
                .orig => {
                    // The buffer against the file on disk: `--no-index`
                    // with the buffer piped in as `-`.
                    try args.appendSlice(arena, &.{ "diff", "--no-index", "--no-ext-diff", ctx, "--", d.path orelse "", "-" });
                },
            }
            var out = try git(repo, io, arena, args.items, if (d.scope == .orig) (d.text orelse "") else null);
            // `diff HEAD -- untracked` is empty; show the file as new so
            // the pane has something to say.
            if (d.scope == .file and out.ok and trimmed(out.stdout).len == 0) {
                out = try git(repo, io, arena, &.{ "diff", "--no-ext-diff", ctx, "--no-index", "--", "/dev/null", d.path orelse "" }, null);
            }
            const files = try parse.parseDiff(arena, out.stdout);
            r.payload = .{ .diff = .{ .scope = d.scope, .path = if (d.path) |p| try arena.dupe(u8, p) else null, .rev = if (d.rev) |v| try arena.dupe(u8, v) else null, .files = files, .full = d.full } };
        },
        .blame => |path| {
            const out = try git(repo, io, arena, &.{ "blame", "--porcelain", "--", path }, null);
            const lines: []parse.BlameLine = if (out.ok) try parse.parseBlame(arena, out.stdout) else &.{};
            r.payload = .{ .blame = .{ .path = try arena.dupe(u8, path), .lines = lines } };
        },
        .log => |l| {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            try args.appendSlice(arena, &.{ "log", "--topo-order", "--format=" ++ parse.log_format, try std.fmt.allocPrint(arena, "-n{d}", .{l.n}) });
            if (l.filter.branch) |b| try args.append(arena, b) else try args.append(arena, "--all");
            if (l.filter.author) |a| try args.append(arena, try std.fmt.allocPrint(arena, "--author={s}", .{a}));
            if (l.filter.subject) |s| try args.append(arena, try std.fmt.allocPrint(arena, "--grep={s}", .{s}));
            if (l.filter.since) |s| try args.append(arena, try std.fmt.allocPrint(arena, "--since={s}", .{s}));
            if (l.filter.until) |s| try args.append(arena, try std.fmt.allocPrint(arena, "--until={s}", .{s}));
            if (l.filter.path) |p| try args.appendSlice(arena, &.{ "--follow", "--", p });
            const out = try git(repo, io, arena, args.items, null);
            const commits: []parse.Commit = if (out.ok) try parse.parseLog(arena, out.stdout) else &.{};
            r.payload = .{ .log = .{ .commits = commits, .path = if (l.filter.path) |p| try arena.dupe(u8, p) else null } };
        },
        .branches => {
            const local = try git(repo, io, arena, &.{ "for-each-ref", "--sort=-committerdate", "--format=" ++ parse.ref_format, "refs/heads" }, null);
            const remote = try git(repo, io, arena, &.{ "for-each-ref", "--sort=-committerdate", "--format=" ++ parse.ref_format, "refs/remotes" }, null);
            const ls = try parse.parseBranches(arena, if (local.ok) local.stdout else "");
            const rs = try parse.parseBranches(arena, if (remote.ok) remote.stdout else "");
            const all = try arena.alloc(parse.Branch, ls.len + rs.len);
            @memcpy(all[0..ls.len], ls);
            for (rs, ls.len..) |b, i| {
                all[i] = b;
                all[i].remote = true;
            }
            r.payload = .{ .branches = all };
        },
        .list => |kind| {
            const out = switch (kind) {
                .stashes => try git(repo, io, arena, &.{ "stash", "list", "--format=%gd%x1f%s" }, null),
                .tags => try git(repo, io, arena, &.{ "tag", "--list", "--sort=-creatordate" }, null),
                .reflog => try git(repo, io, arena, &.{ "reflog", "--format=%h%x1f%gs", "-n", "200" }, null),
                .worktrees => try git(repo, io, arena, &.{ "worktree", "list", "--porcelain" }, null),
            };
            var items: std.ArrayListUnmanaged([]const u8) = .empty;
            if (out.ok) {
                if (kind == .worktrees) {
                    // `worktree <path>` / `branch refs/heads/x` / blank per entry.
                    var path: ?[]const u8 = null;
                    var it = std.mem.splitScalar(u8, out.stdout, '\n');
                    while (it.next()) |line| {
                        if (std.mem.startsWith(u8, line, "worktree ")) {
                            path = line["worktree ".len..];
                        } else if (std.mem.startsWith(u8, line, "branch ")) {
                            const b = line["branch ".len..];
                            const short = if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else b;
                            try items.append(arena, try std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ path orelse "", short }));
                            path = null;
                        } else if (line.len == 0 and path != null) {
                            try items.append(arena, try std.fmt.allocPrint(arena, "{s}\x1f(detached)", .{path.?}));
                            path = null;
                        }
                    }
                } else {
                    var it = std.mem.splitScalar(u8, out.stdout, '\n');
                    while (it.next()) |line| {
                        const t = std.mem.trimEnd(u8, line, "\r");
                        if (t.len > 0) try items.append(arena, t);
                    }
                }
            }
            r.payload = .{ .list = .{ .kind = kind, .items = items.items } };
        },
        .stage => |p| try simple(repo, io, r, &.{ "add", "--", p }, try std.fmt.allocPrint(arena, "staged {s}", .{p})),
        .unstage => |p| {
            // `restore --staged` needs HEAD; before the first commit the
            // index is emptied with `rm --cached`.
            const head = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            if (head.ok) {
                try simple(repo, io, r, &.{ "restore", "--staged", "--", p }, try std.fmt.allocPrint(arena, "unstaged {s}", .{p}));
            } else {
                try simple(repo, io, r, &.{ "rm", "--cached", "-q", "--", p }, try std.fmt.allocPrint(arena, "unstaged {s}", .{p}));
            }
        },
        .stage_all => try simple(repo, io, r, &.{ "add", "-A" }, "staged everything"),
        .unstage_all => {
            const head = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            if (head.ok) {
                try simple(repo, io, r, &.{ "reset", "-q" }, "unstaged everything");
            } else {
                try simple(repo, io, r, &.{ "rm", "--cached", "-q", "-r", "--", "." }, "unstaged everything");
            }
        },
        .discard => |p| {
            // A tracked file goes back to HEAD; an untracked one is removed.
            const tracked = try git(repo, io, arena, &.{ "ls-files", "--error-unmatch", "--", p }, null);
            if (tracked.ok) {
                try simple(repo, io, r, &.{ "checkout", "--", p }, try std.fmt.allocPrint(arena, "discarded {s}", .{p}));
            } else {
                try simple(repo, io, r, &.{ "clean", "-f", "-q", "--", p }, try std.fmt.allocPrint(arena, "removed {s}", .{p}));
            }
        },
        .apply_patch => |a| {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            try args.appendSlice(arena, &.{ "apply", "--whitespace=nowarn" });
            if (a.cached) try args.append(arena, "--cached");
            if (a.reverse) try args.append(arena, "-R");
            try args.append(arena, "-");
            const out = try git(repo, io, arena, args.items, a.patch);
            r.payload = .{ .op = .{ .desc = try arena.dupe(u8, a.desc), .ok = out.ok, .msg = out.reason() } };
        },
        .commit => |msg| {
            const before = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "commit", "-q", "-m", msg }, null);
            if (out.ok) {
                const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
                if (before.ok and after.ok) try pushUndo(repo, try std.fmt.allocPrint(arena, "commit {s}", .{firstLine(msg)}), .{ .reset_soft = try gpa.dupe(u8, trimmed(before.stdout)) }, .{ .reset_soft = try gpa.dupe(u8, trimmed(after.stdout)) });
            }
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "committed: {s}", .{firstLine(msg)}), .ok = out.ok, .msg = out.reason() } };
        },
        .checkout => |b| {
            const from = try git(repo, io, arena, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "checkout", "-q", b }, null);
            if (out.ok and from.ok and trimmed(from.stdout).len > 0) {
                try pushUndo(repo, try std.fmt.allocPrint(arena, "checkout {s}", .{b}), .{ .checkout = try gpa.dupe(u8, trimmed(from.stdout)) }, .{ .checkout = try gpa.dupe(u8, b) });
            }
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "checked out {s}", .{b}), .ok = out.ok, .msg = out.reason() } };
        },
        .new_branch => |b| try simple(repo, io, r, &.{ "checkout", "-q", "-b", b }, try std.fmt.allocPrint(arena, "created branch {s}", .{b})),
        .delete_branch => |b| try simple(repo, io, r, &.{ "branch", "-D", b }, try std.fmt.allocPrint(arena, "deleted branch {s}", .{b})),
        .merge => |b| try simple(repo, io, r, &.{ "merge", "--no-edit", b }, try std.fmt.allocPrint(arena, "merged {s}", .{b})),
        .rebase => |b| try simple(repo, io, r, &.{ "rebase", b }, try std.fmt.allocPrint(arena, "rebased onto {s}", .{b})),
        .fetch => try simple(repo, io, r, &.{ "fetch", "--all", "--prune", "-q" }, "fetched"),
        .pull => try simple(repo, io, r, &.{ "pull", "--ff-only", "-q" }, "pulled (ff-only)"),
        .push => {
            const out = try git(repo, io, arena, &.{ "push", "-q" }, null);
            if (out.ok) {
                r.payload = .{ .op = .{ .desc = "pushed", .ok = true } };
            } else if (std.mem.indexOf(u8, out.stderr, "no upstream") != null or std.mem.indexOf(u8, out.stderr, "has no upstream") != null) {
                const branch = try git(repo, io, arena, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, null);
                const again = try git(repo, io, arena, &.{ "push", "-q", "--set-upstream", "origin", trimmed(branch.stdout) }, null);
                r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "pushed, upstream set to origin/{s}", .{trimmed(branch.stdout)}), .ok = again.ok, .msg = again.reason() } };
            } else {
                r.payload = .{ .op = .{ .desc = "push", .ok = false, .msg = out.reason() } };
            }
        },
        .push_tags => try simple(repo, io, r, &.{ "push", "-q", "--tags" }, "pushed tags"),
        .stash => |m| {
            if (m) |msg| {
                try simple(repo, io, r, &.{ "stash", "push", "-u", "-q", "-m", msg }, try std.fmt.allocPrint(arena, "stashed: {s}", .{msg}));
            } else try simple(repo, io, r, &.{ "stash", "push", "-u", "-q" }, "stashed");
        },
        .stash_pop => try simple(repo, io, r, &.{ "stash", "pop", "-q" }, "stash popped"),
        .stash_apply => |ref| try simple(repo, io, r, &.{ "stash", "apply", "-q", ref }, try std.fmt.allocPrint(arena, "applied {s}", .{ref})),
        .stash_drop => |ref| try simple(repo, io, r, &.{ "stash", "drop", "-q", ref }, try std.fmt.allocPrint(arena, "dropped {s}", .{ref})),
        .tag => |name| try simple(repo, io, r, &.{ "tag", "-a", name, "-m", name }, try std.fmt.allocPrint(arena, "tagged {s}", .{name})),
        .tag_delete => |name| try simple(repo, io, r, &.{ "tag", "-d", name }, try std.fmt.allocPrint(arena, "deleted tag {s}", .{name})),
        .cherry_pick => |sha| try simple(repo, io, r, &.{ "cherry-pick", sha }, try std.fmt.allocPrint(arena, "cherry-picked {s}", .{sha[0..@min(7, sha.len)]})),
        .revert => |sha| try simple(repo, io, r, &.{ "revert", "--no-edit", sha }, try std.fmt.allocPrint(arena, "reverted {s}", .{sha[0..@min(7, sha.len)]})),
        .undo => {
            if (repo.undo.pop()) |entry| {
                const out = try applyAction(repo, io, arena, entry.undo);
                if (out.ok) {
                    try repo.redo.append(gpa, entry);
                    r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "undid: {s}", .{entry.desc}), .ok = true } };
                } else {
                    entry.deinit(gpa);
                    r.payload = .{ .op = .{ .desc = "undo failed", .ok = false, .msg = out.reason() } };
                }
            } else {
                r.payload = .{ .op = .{ .desc = "undo: nothing to undo", .ok = false, .refresh = false } };
            }
        },
        .redo => {
            if (repo.redo.pop()) |entry| {
                const out = try applyAction(repo, io, arena, entry.redo);
                if (out.ok) {
                    try repo.undo.append(gpa, entry);
                    r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "redid: {s}", .{entry.desc}), .ok = true } };
                } else {
                    entry.deinit(gpa);
                    r.payload = .{ .op = .{ .desc = "redo failed", .ok = false, .msg = out.reason() } };
                }
            } else {
                r.payload = .{ .op = .{ .desc = "redo: nothing to redo", .ok = false, .refresh = false } };
            }
        },
        .browse => |b| {
            const remote = try git(repo, io, arena, &.{ "config", "--get", "remote.origin.url" }, null);
            if (!remote.ok or trimmed(remote.stdout).len == 0) {
                r.payload = .{ .op = .{ .desc = "browse: no origin remote", .ok = false, .refresh = false } };
            } else switch (b.kind) {
                .commit => {
                    const rev = try git(repo, io, arena, &.{ "rev-parse", b.rev orelse "HEAD" }, null);
                    if (!rev.ok) {
                        r.payload = .{ .op = .{ .desc = "browse", .ok = false, .msg = rev.reason(), .refresh = false } };
                    } else {
                        r.payload = .{ .url = try remote_mod.commitUrl(arena, trimmed(remote.stdout), trimmed(rev.stdout)) };
                    }
                },
                .file, .line => {
                    const branch = try git(repo, io, arena, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, null);
                    const head = try git(repo, io, arena, &.{ "rev-parse", "HEAD" }, null);
                    const ref = if (branch.ok and trimmed(branch.stdout).len > 0) trimmed(branch.stdout) else trimmed(head.stdout);
                    r.payload = .{ .url = try remote_mod.fileUrl(arena, trimmed(remote.stdout), ref, b.path orelse "", if (b.kind == .line) b.line else null) };
                },
            }
        },
        .worktree_add => |w| {
            if (w.branch) |b| {
                try simple(repo, io, r, &.{ "worktree", "add", w.path, "-b", b }, try std.fmt.allocPrint(arena, "worktree added at {s} on {s}", .{ w.path, b }));
            } else try simple(repo, io, r, &.{ "worktree", "add", w.path }, try std.fmt.allocPrint(arena, "worktree added at {s}", .{w.path}));
        },
        .worktree_remove => |p| try simple(repo, io, r, &.{ "worktree", "remove", "--force", p }, try std.fmt.allocPrint(arena, "worktree removed: {s}", .{p})),
        .head_sha => {
            const out = try git(repo, io, arena, &.{ "rev-parse", "HEAD" }, null);
            if (out.ok) r.payload = .{ .head_sha = trimmed(out.stdout) } else r.payload = .{ .op = .{ .desc = "no HEAD (not a git repo?)", .ok = false, .refresh = false } };
        },
    }
    events.post(io, .{ .git = r });
}

/// Run `args` and post `desc` as the toast on success, git's reason on
/// failure. The result is posted here.
fn simple(repo: *Repo, io: Io, r: *Result, args: []const []const u8, desc: []const u8) JobError!void {
    const arena = r.arena.allocator();
    const out = try git(repo, io, arena, args, null);
    r.payload = .{ .op = .{ .desc = desc, .ok = out.ok, .msg = out.reason() } };
}

fn pushUndo(repo: *Repo, desc: []const u8, undo: Action, redo: Action) Allocator.Error!void {
    const gpa = repo.gpa;
    errdefer undo.deinit(gpa);
    errdefer redo.deinit(gpa);
    const d = try gpa.dupe(u8, desc);
    errdefer gpa.free(d);
    try repo.undo.append(gpa, .{ .desc = d, .undo = undo, .redo = redo });
    // A new operation forks history: what was undone is gone.
    for (repo.redo.items) |e| e.deinit(gpa);
    repo.redo.clearRetainingCapacity();
}

fn applyAction(repo: *Repo, io: Io, arena: Allocator, a: Action) JobError!Out {
    return switch (a) {
        .reset_soft => |rev| git(repo, io, arena, &.{ "reset", "-q", "--soft", rev }, null),
        .checkout => |b| git(repo, io, arena, &.{ "checkout", "-q", b }, null),
    };
}

fn firstLine(s: []const u8) []const u8 {
    const t = trimmed(s);
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..nl];
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "a Repo's queue takes jobs, and destroy frees what was never run" {
    const io = testing.io;
    const repo = try Repo.create(testing.allocator, "/tmp", ".", 1, true);
    const msg = try testing.allocator.dupe(u8, "hello");
    try testing.expect(repo.submit(io, .{ .commit = msg }));
    try testing.expect(repo.submit(io, .status));
    try testing.expectEqual(@as(u32, 2), repo.submitted);
    repo.destroy(io);
}
