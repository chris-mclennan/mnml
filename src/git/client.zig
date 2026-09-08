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
const sequence_editor = @import("sequence_editor.zig");
const event = @import("../core/event.zig");

pub const ResetMode = enum {
    soft,
    mixed,
    hard,

    pub fn flag(m: ResetMode) []const u8 {
        return switch (m) {
            .soft => "--soft",
            .mixed => "--mixed",
            .hard => "--hard",
        };
    }
};

/// What a diff pane shows. `file` and `head` are against HEAD (staged
/// and unstaged together — what the gate's `git diff HEAD` names);
/// `worktree` is unstaged only; `staged` the index; `commit` a `show`.
/// `conflict` is a conflicted file's ours (`:2:`) against theirs (`:3:`)
/// — the diff pane's Split view beside the editor (`app/conflicts.zig`).
pub const DiffScope = enum { file, worktree, head, staged, commit, orig, conflict };

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

/// What an AI prompt is built from: the staged diff, or HEAD's patch
/// and message.
pub const AiContext = enum { staged, head };

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
    /// The stash to pop; null pops the most recent.
    stash_pop: ?[]u8,
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
    /// `commit --amend` with a new message (the AI recompose).
    amend: []u8,
    /// A commit's full message and the files it touched (the graph's
    /// detail panel).
    commit_detail: []u8,
    /// The text an AI commit-message prompt is built from.
    ai_context: AiContext,
    /// The branch rail: branches with tracking counts, worktrees with
    /// their lock and dirty state, remotes with their forge, stashes,
    /// tags, and open PRs through `gh` when the UI found it on PATH.
    rail: struct { gh: bool },
    // ── line verbs (git-lines) ── see the block at the end of the file.
    /// A stash of just `patch` (the diff pane's selection): built in a
    /// temporary index, stored, then reversed out of the worktree.
    /// `patch` is the forward form (what stages the lines onto HEAD's
    /// tree), `reverse` the form `apply -R` takes them out of the
    /// worktree with — the two differ when only some of a hunk's
    /// lines are selected (`parse.patchForLineMask`).
    stash_lines: struct { patch: []u8, reverse: []u8, msg: ?[]u8, desc: []u8 },
    /// A commit of just `patch`: HEAD's tree plus the patch, committed
    /// from a temporary index; the real index takes the patch after so
    /// the rest stays exactly as staged / unstaged.
    commit_lines: struct { patch: []u8, msg: []u8 },
    /// A conflicted file's three stages (`:1:` base, `:2:` ours, `:3:`
    /// theirs) as text, for the AI resolve prompt.
    conflict_text: []u8,
    /// `git <op> --continue` / `--abort` / `--skip` on the operation
    /// the status found in progress (`Status.in_progress`).
    op_continue: parse.InProgress,
    op_abort: parse.InProgress,
    op_skip: parse.InProgress,
    /// `rebase -i <base>` (or `--root` when `base` is null) with this
    /// executable as the sequence editor: `ops` is the todo, oldest
    /// first, reordered as the slice is. Undoable.
    rebase_plan: struct { base: ?[]u8, ops: []sequence_editor.Op },
    /// `commit --amend --no-edit`: the staged changes into HEAD. Undoable.
    amend_noedit,
    /// The staged changes into an older commit: `commit --fixup=<sha>`
    /// then `rebase -i --autosquash <sha>^` with the editor `true`. Undoable.
    amend_to: []u8,
    /// `reset --soft / --mixed / --hard <rev>`. Undoable: HEAD and, for
    /// mixed / hard, a `stash create` of the tree are recorded first.
    reset: struct { mode: ResetMode, rev: []u8 },

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
            .stash, .stash_pop => |s| if (s) |m| gpa.free(m),
            .blame, .stage, .unstage, .discard, .commit, .checkout, .new_branch, .delete_branch, .merge, .rebase, .stash_apply, .stash_drop, .tag, .tag_delete, .cherry_pick, .revert, .worktree_remove => |s| gpa.free(s),
            .commit_detail => |s| gpa.free(s),
            .amend => |s| gpa.free(s),
            .ai_context => {},
            .rail => {},
            .op_continue, .op_abort, .op_skip => {},
            .rebase_plan => |p| {
                if (p.base) |b| gpa.free(b);
                for (p.ops) |op| op.deinit(gpa);
                gpa.free(p.ops);
            },
            .amend_noedit => {},
            .amend_to => |s| gpa.free(s),
            .reset => |r| gpa.free(r.rev),
            .status, .branches, .list, .stage_all, .unstage_all, .fetch, .pull, .push, .push_tags, .undo, .redo, .head_sha => {},
            .stash_lines => |l| {
                gpa.free(l.patch);
                gpa.free(l.reverse);
                if (l.msg) |m| gpa.free(m);
                gpa.free(l.desc);
            },
            .commit_lines => |l| {
                gpa.free(l.patch);
                gpa.free(l.msg);
            },
            .conflict_text => |s| gpa.free(s),
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
        commit_detail: struct { sha: []const u8, message: []const u8, files: []parse.DetailFile },
        /// `diff` is empty when there is nothing to summarise; `message`
        /// is HEAD's current message for `.head`.
        ai_context: struct { what: AiContext, diff: []const u8, message: []const u8 },
        /// A conflicted file's stages; a side git does not have (an
        /// add/add conflict has no base) is empty.
        conflict_text: struct { path: []const u8, base: []const u8, ours: []const u8, theirs: []const u8 },
        rail: struct {
            branches: []parse.Branch,
            worktrees: []parse.Worktree,
            remotes: []parse.Remote,
            stashes: []parse.Stash,
            tags: []parse.Tag,
            prs: []parse.Pr,
            gh: bool,
        },
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
/// the branch back; `reset_hard` puts HEAD, the index and the tree
/// back to `sha` and re-applies the `stash create` taken before the
/// operation (a rebase, a fixup, a reset) touched the tree.
pub const Action = union(enum) {
    reset_soft: []u8,
    checkout: []u8,
    reset_hard: struct { sha: []u8, stash: ?[]u8 },

    fn deinit(a: Action, gpa: Allocator) void {
        switch (a) {
            .reset_soft, .checkout => |s| gpa.free(s),
            .reset_hard => |h| {
                gpa.free(h.sha);
                if (h.stash) |st| gpa.free(st);
            },
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
    /// Worker-owned: `rev-parse --absolute-git-dir`, asked once (a
    /// linked worktree's `.git` is a file pointing elsewhere).
    git_dir: ?[]u8 = null,

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
        if (self.git_dir) |d| gpa.free(d);
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
    return gitIn(repo, io, arena, args, stdin_text, if (repo.env) |*e| e else null);
}

/// `git` with an explicit environment (the line verbs point
/// `GIT_INDEX_FILE` at a temporary index).
fn gitIn(repo: *Repo, io: Io, arena: Allocator, args: []const []const u8, stdin_text: ?[]const u8, env: ?*const std.process.Environ.Map) JobError!Out {
    const prefix = [_][]const u8{ "git", "--no-pager", "-c", "color.ui=never" };
    const argv = try arena.alloc([]const u8, prefix.len + args.len);
    @memcpy(argv[0..prefix.len], &prefix);
    @memcpy(argv[prefix.len..], args);
    if (stdin_text) |text| return gitWithStdin(repo, io, arena, argv, text, env);
    const res = std.process.run(repo.gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = env,
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
fn gitWithStdin(repo: *Repo, io: Io, arena: Allocator, argv: []const []const u8, text: []const u8, env: ?*const std.process.Environ.Map) JobError!Out {
    const gpa = repo.gpa;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = env,
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
            // git's own untracked mode, as Rust reads it: a new directory is one
            // `requests/` entry, not every file under it.
            const st = try git(repo, io, arena, &.{ "status", "--porcelain=v2", "-b" }, null);
            if (!st.ok) {
                r.payload = .{ .op = .{ .desc = "status", .ok = false, .msg = st.reason(), .refresh = false } };
                events.post(io, .{ .git = r });
                return;
            }
            var status = try parse.parseStatus(arena, st.stdout);
            const prog = try readProgress(repo, io, arena);
            status.in_progress = prog.op;
            status.step = prog.step;
            status.total = prog.total;
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
            if (d.scope == .conflict) {
                const files = try conflictDiff(repo, io, arena, d.path orelse "", ctx);
                r.payload = .{ .diff = .{ .scope = d.scope, .path = if (d.path) |p| try arena.dupe(u8, p) else null, .rev = null, .files = files, .full = d.full } };
                events.post(io, .{ .git = r });
                return;
            }
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
                .conflict => unreachable,
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
            // Rust's order: `--date-order` — children before parents, newest first.
            try args.appendSlice(arena, &.{ "log", "--date-order", "--format=" ++ parse.log_format, try std.fmt.allocPrint(arena, "-n{d}", .{l.n}) });
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
        .branches => r.payload = .{ .branches = try allBranches(repo, io, arena) },
        .rail => |opts| {
            const branches = try allBranches(repo, io, arena);
            const worktrees = try worktreeList(repo, io, arena);
            const remotes_out = try git(repo, io, arena, &.{ "remote", "-v" }, null);
            const remotes = try parse.parseRemotes(arena, if (remotes_out.ok) remotes_out.stdout else "");
            const stash_out = try git(repo, io, arena, &.{ "stash", "list", "--format=%h%x1f%gd%x1f%s" }, null);
            const stashes = try parse.parseStashes(arena, if (stash_out.ok) stash_out.stdout else "");
            const tag_out = try git(repo, io, arena, &.{ "for-each-ref", "--sort=-version:refname", "--sort=-creatordate", "--format=" ++ parse.tag_format, "refs/tags" }, null);
            const tags = try parse.parseTags(arena, if (tag_out.ok) tag_out.stdout else "");
            var prs: []parse.Pr = &.{};
            if (opts.gh) {
                const out = run(repo, io, arena, &.{ "gh", "pr", "list", "--json", "number,title,headRefName,url", "--limit", "50" }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (out.ok) prs = try parse.parsePrs(arena, out.stdout);
            }
            r.payload = .{ .rail = .{ .branches = branches, .worktrees = worktrees, .remotes = remotes, .stashes = stashes, .tags = tags, .prs = prs, .gh = opts.gh } };
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
                    // `<path>\x1f<branch>` per entry, as the pickers read it.
                    for (try parse.parseWorktrees(arena, out.stdout)) |w| {
                        try items.append(arena, try std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ w.path, w.label() }));
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
        .commit_detail => |sha| {
            const msg = try git(repo, io, arena, &.{ "show", "-s", "--format=%B", sha }, null);
            const files = try git(repo, io, arena, &.{ "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-m", "--first-parent", sha }, null);
            r.payload = .{ .commit_detail = .{
                .sha = try arena.dupe(u8, sha),
                .message = if (msg.ok) trimmed(msg.stdout) else msg.reason(),
                .files = if (files.ok) try parse.parseNameStatus(arena, files.stdout) else &.{},
            } };
        },
        .ai_context => |what| switch (what) {
            .staged => {
                const d = try git(repo, io, arena, &.{ "diff", "--no-ext-diff", "--cached" }, null);
                r.payload = .{ .ai_context = .{ .what = what, .diff = if (d.ok) d.stdout else "", .message = "" } };
            },
            .head => {
                const d = try git(repo, io, arena, &.{ "show", "--no-ext-diff", "--format=", "HEAD" }, null);
                const m = try git(repo, io, arena, &.{ "log", "-1", "--format=%B" }, null);
                r.payload = .{ .ai_context = .{ .what = what, .diff = if (d.ok) d.stdout else "", .message = if (m.ok) trimmed(m.stdout) else "" } };
            },
        },
        .amend => |msg| {
            const before = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "commit", "-q", "--amend", "-m", msg }, null);
            if (out.ok) {
                const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
                if (before.ok and after.ok) {
                    const undo_sha = try gpa.dupe(u8, trimmed(before.stdout));
                    errdefer gpa.free(undo_sha);
                    const redo_sha = try gpa.dupe(u8, trimmed(after.stdout));
                    errdefer gpa.free(redo_sha);
                    try pushUndo(repo, try std.fmt.allocPrint(arena, "amend {s}", .{firstLine(msg)}), .{ .reset_soft = undo_sha }, .{ .reset_soft = redo_sha });
                }
            }
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "amended: {s}", .{firstLine(msg)}), .ok = out.ok, .msg = out.reason() } };
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
                if (before.ok and after.ok) {
                    // Own each string before the next fallible call: a
                    // cancel landing between the two dupes leaked the
                    // first one under load.
                    const undo_sha = try gpa.dupe(u8, trimmed(before.stdout));
                    errdefer gpa.free(undo_sha);
                    const redo_sha = try gpa.dupe(u8, trimmed(after.stdout));
                    errdefer gpa.free(redo_sha);
                    try pushUndo(repo, try std.fmt.allocPrint(arena, "commit {s}", .{firstLine(msg)}), .{ .reset_soft = undo_sha }, .{ .reset_soft = redo_sha });
                }
            }
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "committed: {s}", .{firstLine(msg)}), .ok = out.ok, .msg = out.reason() } };
        },
        .checkout => |b| {
            const from = try git(repo, io, arena, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "checkout", "-q", b }, null);
            if (out.ok and from.ok and trimmed(from.stdout).len > 0) {
                const undo_ref = try gpa.dupe(u8, trimmed(from.stdout));
                errdefer gpa.free(undo_ref);
                const redo_ref = try gpa.dupe(u8, b);
                errdefer gpa.free(redo_ref);
                try pushUndo(repo, try std.fmt.allocPrint(arena, "checkout {s}", .{b}), .{ .checkout = undo_ref }, .{ .checkout = redo_ref });
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
        .stash_pop => |ref| if (ref) |x| try simple(repo, io, r, &.{ "stash", "pop", "-q", x }, "stash popped") else try simple(repo, io, r, &.{ "stash", "pop", "-q" }, "stash popped"),
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
        .op_continue => |op| switch (op) {
            .none => r.payload = .{ .op = .{ .desc = "nothing in progress", .ok = false, .refresh = false } },
            .bisect => r.payload = .{ .op = .{ .desc = "bisect: mark a commit good or bad instead", .ok = false, .refresh = false } },
            else => try simple(repo, io, r, &.{ "-c", "core.editor=true", op.verb(), "--continue" }, try std.fmt.allocPrint(arena, "{s} continued", .{op.verb()})),
        },
        .op_abort => |op| switch (op) {
            .none => r.payload = .{ .op = .{ .desc = "nothing in progress", .ok = false, .refresh = false } },
            .bisect => try simple(repo, io, r, &.{ "bisect", "reset" }, "bisect reset"),
            else => try simple(repo, io, r, &.{ op.verb(), "--abort" }, try std.fmt.allocPrint(arena, "{s} aborted", .{op.verb()})),
        },
        .op_skip => |op| switch (op) {
            .none => r.payload = .{ .op = .{ .desc = "nothing in progress", .ok = false, .refresh = false } },
            .bisect => try simple(repo, io, r, &.{ "bisect", "skip" }, "bisect: skipped"),
            .merge => r.payload = .{ .op = .{ .desc = "merge: nothing to skip (abort or continue)", .ok = false, .refresh = false } },
            else => try simple(repo, io, r, &.{ "-c", "core.editor=true", op.verb(), "--skip" }, try std.fmt.allocPrint(arena, "{s}: step skipped", .{op.verb()})),
        },
        .amend_noedit => {
            const before = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "commit", "-q", "--amend", "--no-edit" }, null);
            if (out.ok) {
                const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
                if (before.ok and after.ok) try pushUndo(repo, "amend (staged changes into HEAD)", .{ .reset_soft = try gpa.dupe(u8, trimmed(before.stdout)) }, .{ .reset_soft = try gpa.dupe(u8, trimmed(after.stdout)) });
            }
            r.payload = .{ .op = .{ .desc = "amended HEAD with the staged changes", .ok = out.ok, .msg = out.reason() } };
        },
        .amend_to => |sha| {
            const short = sha[0..@min(7, sha.len)];
            const snap = try snapshot(repo, io, arena);
            const fix = try git(repo, io, arena, &.{ "commit", "-q", "--fixup", sha }, null);
            if (!fix.ok) {
                r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "amend to {s}", .{short}), .ok = false, .msg = fix.reason() } };
                events.post(io, .{ .git = r });
                return;
            }
            // The fixup rides an autosquash rebase from the commit's parent
            // — from the root when it has none — with `true` as the editor.
            const parent = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", try std.fmt.allocPrint(arena, "{s}^", .{sha}) }, null);
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            try args.appendSlice(arena, &.{ "-c", "sequence.editor=true", "-c", "core.editor=true", "rebase", "-i", "--autosquash", "--autostash" });
            if (parent.ok and trimmed(parent.stdout).len > 0) try args.append(arena, trimmed(parent.stdout)) else try args.append(arena, "--root");
            const out = try git(repo, io, arena, args.items, null);
            if (out.ok) try pushSnapshotUndo(repo, io, arena, try std.fmt.allocPrint(arena, "amend to {s}", .{short}), snap);
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "amended {s} with the staged changes", .{short}), .ok = out.ok, .msg = out.reason() } };
        },
        .reset => |rs| {
            const snap = try snapshot(repo, io, arena);
            const out = try git(repo, io, arena, &.{ "reset", "-q", rs.mode.flag(), rs.rev }, null);
            const desc = try std.fmt.allocPrint(arena, "reset {s} {s}", .{ rs.mode.flag(), rs.rev[0..@min(9, rs.rev.len)] });
            if (out.ok) {
                if (rs.mode == .soft) {
                    const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
                    if (snap.head) |h| if (after.ok) try pushUndo(repo, desc, .{ .reset_soft = try gpa.dupe(u8, h) }, .{ .reset_soft = try gpa.dupe(u8, trimmed(after.stdout)) });
                } else try pushSnapshotUndo(repo, io, arena, desc, snap);
            }
            r.payload = .{ .op = .{ .desc = desc, .ok = out.ok, .msg = out.reason() } };
        },
        .rebase_plan => |plan| {
            const dir = (try gitDir(repo, io, arena)) orelse {
                r.payload = .{ .op = .{ .desc = "rebase", .ok = false, .msg = "not a git repository", .refresh = false } };
                events.post(io, .{ .git = r });
                return;
            };
            const exe = std.process.executablePathAlloc(io, arena) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    r.payload = .{ .op = .{ .desc = "rebase", .ok = false, .msg = try std.fmt.allocPrint(arena, "cannot find this executable: {s}", .{@errorName(err)}), .refresh = false } };
                    events.post(io, .{ .git = r });
                    return;
                },
            };
            const plan_path = try std.fs.path.join(arena, &.{ dir, "mnml-rebase-plan" });
            const queue_path = try std.fs.path.join(arena, &.{ dir, "mnml-rebase-msgs" });
            const cwd = Io.Dir.cwd();
            cwd.writeFile(io, .{ .sub_path = plan_path, .data = try sequence_editor.todoText(arena, plan.ops) }) catch {
                r.payload = .{ .op = .{ .desc = "rebase", .ok = false, .msg = "cannot write the plan into the git dir", .refresh = false } };
                events.post(io, .{ .git = r });
                return;
            };
            cwd.writeFile(io, .{ .sub_path = queue_path, .data = try sequence_editor.queueText(arena, plan.ops) }) catch {};
            const snap = try snapshot(repo, io, arena);
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            try args.appendSlice(arena, &.{
                "-c",          try std.fmt.allocPrint(arena, "sequence.editor={s}", .{try sequence_editor.editorCommand(arena, exe, "--rebase-todo", plan_path)}),
                "-c",          try std.fmt.allocPrint(arena, "core.editor={s}", .{try sequence_editor.editorCommand(arena, exe, "--commit-msg", queue_path)}),
                "rebase",      "-i",
                "--autostash",
            });
            if (plan.base) |b| try args.append(arena, b) else try args.append(arena, "--root");
            const out = try git(repo, io, arena, args.items, null);
            var n_changed: usize = 0;
            for (plan.ops) |op| if (op.action != .pick) {
                n_changed += 1;
            };
            const desc = try std.fmt.allocPrint(arena, "rebased: {d} commit(s), {d} changed", .{ plan.ops.len, n_changed });
            if (out.ok) try pushSnapshotUndo(repo, io, arena, desc, snap);
            cwd.deleteFile(io, plan_path) catch {};
            cwd.deleteFile(io, queue_path) catch {};
            r.payload = .{ .op = .{ .desc = if (out.ok) desc else "rebase", .ok = out.ok, .msg = out.reason() } };
        },
        .head_sha => {
            const out = try git(repo, io, arena, &.{ "rev-parse", "HEAD" }, null);
            if (out.ok) r.payload = .{ .head_sha = trimmed(out.stdout) } else r.payload = .{ .op = .{ .desc = "no HEAD (not a git repo?)", .ok = false, .refresh = false } };
        },
        .stash_lines => |l| try stashLines(repo, io, r, l.patch, l.reverse, l.msg, l.desc),
        .commit_lines => |l| try commitLines(repo, io, r, l.patch, l.msg),
        .conflict_text => |path| {
            const base = try git(repo, io, arena, &.{ "show", try std.fmt.allocPrint(arena, ":1:{s}", .{path}) }, null);
            const ours = try git(repo, io, arena, &.{ "show", try std.fmt.allocPrint(arena, ":2:{s}", .{path}) }, null);
            const theirs = try git(repo, io, arena, &.{ "show", try std.fmt.allocPrint(arena, ":3:{s}", .{path}) }, null);
            r.payload = .{ .conflict_text = .{
                .path = try arena.dupe(u8, path),
                .base = if (base.ok) base.stdout else "",
                .ours = if (ours.ok) ours.stdout else "",
                .theirs = if (theirs.ok) theirs.stdout else "",
            } };
        },
    }
    events.post(io, .{ .git = r });
}

/// The repo's git dir, asked of git once and kept on the repo.
fn gitDir(repo: *Repo, io: Io, arena: Allocator) JobError!?[]const u8 {
    if (repo.git_dir) |d| return d;
    const out = try git(repo, io, arena, &.{ "rev-parse", "--absolute-git-dir" }, null);
    if (!out.ok) return null;
    const d = trimmed(out.stdout);
    if (d.len == 0) return null;
    repo.git_dir = try repo.gpa.dupe(u8, d);
    return repo.git_dir;
}

fn gitDirHas(io: Io, arena: Allocator, dir: []const u8, name: []const u8) Allocator.Error!bool {
    const p = try std.fs.path.join(arena, &.{ dir, name });
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

fn gitDirRead(io: Io, arena: Allocator, dir: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    const p = try std.fs.path.join(arena, &.{ dir, name });
    return Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64)) catch null;
}

/// The operation in progress, from the git dir's state files.
fn readProgress(repo: *Repo, io: Io, arena: Allocator) JobError!parse.Progress {
    const dir = (try gitDir(repo, io, arena)) orelse return .{};
    const flags: parse.GitDirFlags = .{
        .rebase_merge = try gitDirHas(io, arena, dir, "rebase-merge"),
        .rebase_apply = try gitDirHas(io, arena, dir, "rebase-apply"),
        .merge_head = try gitDirHas(io, arena, dir, "MERGE_HEAD"),
        .cherry_pick_head = try gitDirHas(io, arena, dir, "CHERRY_PICK_HEAD"),
        .revert_head = try gitDirHas(io, arena, dir, "REVERT_HEAD"),
        .bisect_log = try gitDirHas(io, arena, dir, "BISECT_LOG"),
    };
    var msgnum: ?[]const u8 = null;
    var end: ?[]const u8 = null;
    if (flags.rebase_merge) {
        msgnum = try gitDirRead(io, arena, dir, "rebase-merge/msgnum");
        end = try gitDirRead(io, arena, dir, "rebase-merge/end");
    } else if (flags.rebase_apply) {
        msgnum = try gitDirRead(io, arena, dir, "rebase-apply/next");
        end = try gitDirRead(io, arena, dir, "rebase-apply/last");
    }
    return parse.progressFrom(flags, msgnum, end);
}

/// Local branches then remote ones, newest first within each.
fn allBranches(repo: *Repo, io: Io, arena: Allocator) JobError![]parse.Branch {
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
    return all;
}

/// `git worktree list --porcelain`, each tree then asked whether it is
/// dirty (`status --porcelain` inside it says anything). A tree that
/// cannot be read — a stale entry, a bare one — counts as clean.
fn worktreeList(repo: *Repo, io: Io, arena: Allocator) JobError![]parse.Worktree {
    const out = try git(repo, io, arena, &.{ "worktree", "list", "--porcelain" }, null);
    if (!out.ok) return &.{};
    const trees = try parse.parseWorktrees(arena, out.stdout);
    for (trees) |*w| {
        if (w.bare) continue;
        const st = try git(repo, io, arena, &.{ "-C", w.path, "status", "--porcelain" }, null);
        w.dirty = st.ok and trimmed(st.stdout).len > 0;
    }
    return trees;
}

/// Run a non-git binary (`gh`) in the repo, the same way `git` runs.
fn run(repo: *Repo, io: Io, arena: Allocator, argv: []const []const u8) JobError!Out {
    const res = std.process.run(repo.gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = if (repo.env) |*e| e else null,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .ok = false, .stdout = "", .stderr = try std.fmt.allocPrint(arena, "cannot run {s}: {s}", .{ argv[0], @errorName(err) }) },
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
        .reset_hard => |h| {
            const out = try git(repo, io, arena, &.{ "reset", "-q", "--hard", h.sha }, null);
            if (!out.ok) return out;
            const st = h.stash orelse return out;
            // The index as it was, when that applies cleanly; the tree at least.
            const with_index = try git(repo, io, arena, &.{ "stash", "apply", "-q", "--index", st }, null);
            if (with_index.ok) return with_index;
            return git(repo, io, arena, &.{ "stash", "apply", "-q", st }, null);
        },
    };
}

/// What a tree-touching operation records before it runs: HEAD (null
/// before the first commit) and a `stash create` of the index and the
/// tree (null when both are clean — `stash create` prints nothing).
const Snapshot = struct { head: ?[]const u8, stash: ?[]const u8 };

fn snapshot(repo: *Repo, io: Io, arena: Allocator) JobError!Snapshot {
    const head = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
    const stash = try git(repo, io, arena, &.{ "stash", "create" }, null);
    return .{
        .head = if (head.ok and trimmed(head.stdout).len > 0) trimmed(head.stdout) else null,
        .stash = if (stash.ok and trimmed(stash.stdout).len > 0) trimmed(stash.stdout) else null,
    };
}

/// After a tree-touching operation succeeded: undo is `reset --hard`
/// to the snapshot's HEAD plus its stash, redo `reset --hard` to the
/// HEAD of now.
fn pushSnapshotUndo(repo: *Repo, io: Io, arena: Allocator, desc: []const u8, snap: Snapshot) JobError!void {
    const gpa = repo.gpa;
    const before = snap.head orelse return;
    const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
    if (!after.ok) return;
    const undo_sha = try gpa.dupe(u8, before);
    const undo_stash: ?[]u8 = if (snap.stash) |st| gpa.dupe(u8, st) catch |err| {
        gpa.free(undo_sha);
        return err;
    } else null;
    const redo_sha = gpa.dupe(u8, trimmed(after.stdout)) catch |err| {
        gpa.free(undo_sha);
        if (undo_stash) |st| gpa.free(st);
        return err;
    };
    // `pushUndo` owns both actions from here, failure included.
    try pushUndo(repo, desc, .{ .reset_hard = .{ .sha = undo_sha, .stash = undo_stash } }, .{ .reset_hard = .{ .sha = redo_sha, .stash = null } });
}

fn firstLine(s: []const u8) []const u8 {
    const t = trimmed(s);
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..nl];
}

// ─── line verbs (git-lines) ─────────────────────────────────────────────
// The diff pane's selection verbs that need more than `apply`: a stash
// or a commit of SOME lines. Both build the wanted tree in a temporary
// index (`GIT_INDEX_FILE` under the git dir — a linked worktree has its
// own) so the real index is never disturbed: `read-tree HEAD`, `apply
// --cached` the patch, `write-tree`. Nothing here is undoable through
// `git.undo` except the commit, which pushes the same `reset --soft`
// entry a plain commit does.

/// A temporary index, populated from HEAD's tree, and the environment
/// that points git at it. Removed by `deinit`.
const TempIndex = struct {
    path: []const u8,
    env: std.process.Environ.Map,

    fn init(repo: *Repo, io: Io, arena: Allocator) JobError!?TempIndex {
        const dir = try git(repo, io, arena, &.{ "rev-parse", "--absolute-git-dir" }, null);
        if (!dir.ok) return null;
        const path = try std.fmt.allocPrint(arena, "{s}/mnml-lines.index", .{trimmed(dir.stdout)});
        var env = if (repo.env) |*e| try e.clone(repo.gpa) else std.process.Environ.Map.init(repo.gpa);
        errdefer env.deinit();
        try env.put("GIT_INDEX_FILE", path);
        var t: TempIndex = .{ .path = path, .env = env };
        const seed = try t.run(repo, io, arena, &.{ "read-tree", "HEAD" }, null);
        if (!seed.ok) {
            t.deinit(io);
            return null;
        }
        return t;
    }

    fn run(t: *TempIndex, repo: *Repo, io: Io, arena: Allocator, args: []const []const u8, stdin_text: ?[]const u8) JobError!Out {
        return gitIn(repo, io, arena, args, stdin_text, &t.env);
    }

    fn deinit(t: *TempIndex, io: Io) void {
        std.Io.Dir.cwd().deleteFile(io, t.path) catch {};
        t.env.deinit();
    }
};

fn fail(r: *Result, desc: []const u8, out: Out) void {
    r.payload = .{ .op = .{ .desc = desc, .ok = false, .msg = out.reason() } };
}

/// The patch applied to HEAD's tree in a temporary index, written as a
/// tree object. Null (the result already says why) when a step failed.
fn treeWithPatch(repo: *Repo, io: Io, r: *Result, t: *TempIndex, patch: []const u8, desc: []const u8) JobError!?[]const u8 {
    const arena = r.arena.allocator();
    const applied = try t.run(repo, io, arena, &.{ "apply", "--cached", "--whitespace=nowarn", "-" }, patch);
    if (!applied.ok) {
        fail(r, desc, applied);
        return null;
    }
    const tree = try t.run(repo, io, arena, &.{"write-tree"}, null);
    if (!tree.ok) {
        fail(r, desc, tree);
        return null;
    }
    return trimmed(tree.stdout);
}

/// `stash_lines`: the stash commit is built by hand the way `stash
/// push` builds one — a tree with the lines, an index commit at HEAD's
/// tree — then the lines are reversed out of the worktree and the
/// commit stored. The order means a worktree that will not take the
/// reverse leaves nothing behind.
fn stashLines(repo: *Repo, io: Io, r: *Result, patch: []const u8, reverse: []const u8, msg: ?[]const u8, desc_in: []const u8) JobError!void {
    const arena = r.arena.allocator();
    // The job's strings die with the job; the result outlives it.
    const desc = try arena.dupe(u8, desc_in);
    var t = (try TempIndex.init(repo, io, arena)) orelse {
        r.payload = .{ .op = .{ .desc = desc, .ok = false, .msg = "no HEAD to stash against", .refresh = false } };
        return;
    };
    defer t.deinit(io);
    const tree = (try treeWithPatch(repo, io, r, &t, patch, desc)) orelse return;
    const head_tree = try git(repo, io, arena, &.{ "rev-parse", "HEAD^{tree}" }, null);
    const branch = try git(repo, io, arena, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, null);
    const subject = try git(repo, io, arena, &.{ "log", "-1", "--format=%h %s" }, null);
    const on: []const u8 = if (branch.ok and trimmed(branch.stdout).len > 0) trimmed(branch.stdout) else "(no branch)";
    const index_msg = try std.fmt.allocPrint(arena, "index on {s}: {s}", .{ on, trimmed(subject.stdout) });
    const stash_msg = if (msg) |m| try std.fmt.allocPrint(arena, "On {s}: {s}", .{ on, m }) else try std.fmt.allocPrint(arena, "WIP on {s}: {s}", .{ on, trimmed(subject.stdout) });
    const index_commit = try git(repo, io, arena, &.{ "commit-tree", trimmed(head_tree.stdout), "-p", "HEAD", "-m", index_msg }, null);
    if (!index_commit.ok) return fail(r, desc, index_commit);
    const stash_commit = try git(repo, io, arena, &.{ "commit-tree", tree, "-p", "HEAD", "-p", trimmed(index_commit.stdout), "-m", stash_msg }, null);
    if (!stash_commit.ok) return fail(r, desc, stash_commit);
    const dropped = try git(repo, io, arena, &.{ "apply", "--whitespace=nowarn", "-R", "-" }, reverse);
    if (!dropped.ok) return fail(r, desc, dropped);
    const stored = try git(repo, io, arena, &.{ "stash", "store", "-m", stash_msg, trimmed(stash_commit.stdout) }, null);
    if (!stored.ok) return fail(r, desc, stored);
    r.payload = .{ .op = .{ .desc = desc, .ok = true } };
}

/// `commit_lines`: HEAD's tree plus the patch becomes the new HEAD; the
/// real index then takes the same patch so what was staged stays
/// staged and what was not stays not. Undo is the plain commit's.
fn commitLines(repo: *Repo, io: Io, r: *Result, patch: []const u8, msg: []const u8) JobError!void {
    const arena = r.arena.allocator();
    const gpa = repo.gpa;
    const desc = try std.fmt.allocPrint(arena, "committed lines: {s}", .{firstLine(msg)});
    var t = (try TempIndex.init(repo, io, arena)) orelse {
        r.payload = .{ .op = .{ .desc = desc, .ok = false, .msg = "no HEAD to commit onto", .refresh = false } };
        return;
    };
    defer t.deinit(io);
    const tree = (try treeWithPatch(repo, io, r, &t, patch, desc)) orelse return;
    const before = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
    const commit = try git(repo, io, arena, &.{ "commit-tree", tree, "-p", "HEAD", "-m", msg }, null);
    if (!commit.ok) return fail(r, desc, commit);
    const after = trimmed(commit.stdout);
    const moved = try git(repo, io, arena, &.{ "update-ref", "-m", try std.fmt.allocPrint(arena, "commit: {s}", .{firstLine(msg)}), "HEAD", after }, null);
    if (!moved.ok) return fail(r, desc, moved);
    if (before.ok) try pushUndo(repo, try std.fmt.allocPrint(arena, "commit {s}", .{firstLine(msg)}), .{ .reset_soft = try gpa.dupe(u8, trimmed(before.stdout)) }, .{ .reset_soft = try gpa.dupe(u8, after) });
    // The real index catches up with HEAD for those lines only.
    const caught = try git(repo, io, arena, &.{ "apply", "--cached", "--whitespace=nowarn", "-" }, patch);
    if (!caught.ok) {
        r.payload = .{ .op = .{ .desc = desc, .ok = false, .msg = try std.fmt.allocPrint(arena, "committed, but the index did not take the lines: {s}", .{caught.reason()}) } };
        return;
    }
    r.payload = .{ .op = .{ .desc = desc, .ok = true } };
}

// ─── conflicts (git-lines) ──────────────────────────────────────────────

/// Ours (`:2:`) against theirs (`:3:`) of a conflicted `path`: the two
/// stages written under the git dir and diffed with `--no-index`, the
/// files then named `path` on both sides so the pane's banner and
/// headers read as the file. A stage git does not have (an add/add
/// conflict, a file no longer conflicted) diffs as empty.
fn conflictDiff(repo: *Repo, io: Io, arena: Allocator, path: []const u8, ctx: []const u8) JobError![]parse.FileDiff {
    const dir = try git(repo, io, arena, &.{ "rev-parse", "--absolute-git-dir" }, null);
    if (!dir.ok) return &.{};
    const ours = try git(repo, io, arena, &.{ "show", try std.fmt.allocPrint(arena, ":2:{s}", .{path}) }, null);
    const theirs = try git(repo, io, arena, &.{ "show", try std.fmt.allocPrint(arena, ":3:{s}", .{path}) }, null);
    const a = try std.fmt.allocPrint(arena, "{s}/mnml-conflict-ours", .{trimmed(dir.stdout)});
    const b = try std.fmt.allocPrint(arena, "{s}/mnml-conflict-theirs", .{trimmed(dir.stdout)});
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = a, .data = if (ours.ok) ours.stdout else "" }) catch return &.{};
    defer cwd.deleteFile(io, a) catch {};
    cwd.writeFile(io, .{ .sub_path = b, .data = if (theirs.ok) theirs.stdout else "" }) catch return &.{};
    defer cwd.deleteFile(io, b) catch {};
    // `--no-index` exits 1 when the two differ: the output is the diff.
    const out = try git(repo, io, arena, &.{ "diff", "--no-index", "--no-ext-diff", ctx, "--", a, b }, null);
    const files = try parse.parseDiff(arena, out.stdout);
    for (files) |*f| {
        f.old_path = try arena.dupe(u8, path);
        f.new_path = try arena.dupe(u8, path);
    }
    return files;
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
