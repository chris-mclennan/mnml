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
const builtin = @import("builtin");
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
/// `range` is any two refs: `rev` holds `from..to` (`rangeRev`) and
/// `path` narrows it to one file — the graph's compare base against a
/// row, a branch against the current one, a stash against its parent.
pub const DiffScope = enum { file, worktree, head, staged, commit, orig, conflict, range };

/// `from..to` for a `.range` diff's `rev`.
pub fn rangeRev(allocator: Allocator, from: []const u8, to: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}..{s}", .{ from, to });
}

/// A range's two sides, each shortened to seven cells when it is a
/// full sha (a branch name stays whole) — the diff pane's title.
pub fn rangeTitle(allocator: Allocator, rev: []const u8) Allocator.Error![]u8 {
    const dd = std.mem.indexOf(u8, rev, "..") orelse return allocator.dupe(u8, rev);
    return std.fmt.allocPrint(allocator, "{s}..{s}", .{ shortRef(rev[0..dd]), shortRef(rev[dd + 2 ..]) });
}

fn shortRef(s: []const u8) []const u8 {
    if (s.len < 20) return s;
    for (s) |c| if (!std.ascii.isHex(c)) return s;
    return s[0..7];
}

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

/// What `Job.stash` pushes. `paths` narrows it to those files; a
/// `staged_only` push has no untracked files to take (git refuses
/// `--staged` with `-u`).
pub const StashPush = struct {
    msg: ?[]u8 = null,
    paths: ?[][]u8 = null,
    staged_only: bool = false,
    keep_index: bool = false,

    pub fn deinit(s: StashPush, gpa: Allocator) void {
        if (s.msg) |m| gpa.free(m);
        if (s.paths) |ps| {
            for (ps) |p| gpa.free(p);
            gpa.free(ps);
        }
    }
};

/// `stash push -q [-u] [--staged] [--keep-index] [-m msg] [-- paths]`.
pub fn stashArgs(arena: Allocator, s: StashPush) Allocator.Error![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "stash", "push", "-q" });
    if (!s.staged_only) try args.append(arena, "-u");
    if (s.staged_only) try args.append(arena, "--staged");
    if (s.keep_index) try args.append(arena, "--keep-index");
    if (s.msg) |m| try args.appendSlice(arena, &.{ "-m", m });
    if (s.paths) |ps| {
        try args.append(arena, "--");
        for (ps) |p| try args.append(arena, p);
    }
    return args.items;
}

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
    /// `checkout -b name [start]`: from HEAD, or from a commit / tag.
    new_branch: struct { name: []u8, start: ?[]u8 = null },
    delete_branch: []u8,
    merge: []u8,
    rebase: []u8,
    fetch,
    pull,
    push,
    push_tags,
    /// `push -u remote branch`: a branch that is not checked out, to its
    /// remote (git-panel).
    push_branch: struct { remote: []u8, branch: []u8 },
    /// // changed (git-menus): *Push and start PR* — the same `push -u`
    /// as `push_branch`, and on success the forge's new-PR page, which
    /// the handler opens in the browser. Never a force push.
    push_start_pr: struct { remote: []u8, branch: []u8, url: []u8 },
    /// `stash push`: everything (with untracked files), the index only,
    /// some paths, or the tree with the index kept (`stashArgs`).
    stash: StashPush,
    /// The stash to pop; null pops the most recent.
    stash_pop: ?[]u8,
    /// `stash show --name-status <ref>`: the files a stash touched.
    stash_show: []u8,
    /// `stash branch <name> <ref>`: a branch from the stash's parent
    /// with the stash applied and dropped.
    stash_branch: struct { ref: []u8, name: []u8 },
    /// A stash renamed: dropped, then `stash store -m` of the same
    /// commit under the new message (`parse.stashRenameMessage` keeps
    /// the `On <branch>: ` half).
    stash_rename: struct { ref: []u8, msg: []u8 },
    stash_apply: []u8,
    stash_drop: []u8,
    tag: []u8,
    /// `tag [-a -m name] name start`: a tag on the branches panel's row
    /// (its tip), lightweight or annotated (git-panel).
    tag_at: struct { name: []u8, start: []u8, annotated: bool },
    tag_delete: []u8,
    cherry_pick: []u8,
    revert: []u8,
    undo,
    redo,
    browse: struct { kind: BrowseKind, path: ?[]u8 = null, line: u32 = 0, rev: ?[]u8 = null },
    /// `worktree add path [-b branch] [start]`.
    worktree_add: struct { path: []u8, branch: ?[]u8, start: ?[]u8 = null },
    worktree_remove: []u8,
    /// // changed (git-menus): a WORKTREES row's *Remove worktree and
    /// delete branch* — `worktree remove` then `branch -d`, or both
    /// forced when the confirm's Force choice was taken.
    worktree_remove_branch: struct { path: []u8, branch: []u8, force: bool },
    /// // changed (git-menus): `worktree lock [--reason <r>]` /
    /// `worktree unlock` — a locked tree refuses `worktree remove` and
    /// `prune`, and the panel paints the lock the porcelain reports.
    worktree_lock: struct { path: []u8, reason: []u8 },
    worktree_unlock: []u8,
    // ── branch verbs (git-more2) ──
    /// `branch -m from to`.
    branch_rename: struct { from: []u8, to: []u8 },
    /// The branch to its upstream: `merge --ff-only <upstream>` when it
    /// is checked out (undoable), else `fetch <remote> <ref>:<branch>`.
    fast_forward: struct { branch: []u8, upstream: []u8, checked_out: bool },
    /// `branch -u upstream branch`.
    set_upstream: struct { branch: []u8, upstream: []u8 },
    /// `checkout -f`: the tree's changes are thrown away (behind a confirm).
    checkout_force: []u8,
    /// `push <remote> --delete <branch>` (behind a confirm).
    delete_remote: struct { remote: []u8, branch: []u8 },
    /// `push --force-with-lease` (behind a confirm that names the risk).
    push_force,
    /// A command-log row's Enter: `git <argv>` again, for the read-only
    /// commands (`isReadOnly`); the first output line is the toast.
    rerun: [][]u8,
    /// `show <rev>:<path>` — the file as that commit had it (a detail
    /// row's "Open file at this revision").
    show_file: struct { rev: []u8, path: []u8 },
    head_sha,
    /// `commit --amend` with a new message (the AI recompose).
    amend: []u8,
    /// A commit's full message and the files it touched (the graph's
    /// detail panel).
    commit_detail: []u8,
    /// The text an AI commit-message prompt is built from.
    ai_context: AiContext,
    /// // changed (git-menus): the text *Explain branch changes* builds
    /// its prompt from — `log --stat base..branch`, capped by the
    /// worker so a long-lived branch cannot flood the model.
    branch_explain: struct { branch: []u8, base: []u8 },
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
    /// Test only (`void` outside a test build): the worker stores 1 in
    /// the gate on arrival, sleeps 2 s, and drops the sleep's error on the
    /// floor — a job that swallows its cancellation, the shape `gitDirHas`
    /// had (see `Repo.destroy`).
    test_swallow: if (builtin.is_test) *std.atomic.Value(u32) else void,

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
                if (w.start) |s| gpa.free(s);
            },
            .new_branch => |b| {
                gpa.free(b.name);
                if (b.start) |s| gpa.free(s);
            },
            .branch_rename => |b| {
                gpa.free(b.from);
                gpa.free(b.to);
            },
            .fast_forward => |b| {
                gpa.free(b.branch);
                gpa.free(b.upstream);
            },
            .set_upstream => |b| {
                gpa.free(b.branch);
                gpa.free(b.upstream);
            },
            .delete_remote => |b| {
                gpa.free(b.remote);
                gpa.free(b.branch);
            },
            .worktree_remove_branch => |w| {
                gpa.free(w.path);
                gpa.free(w.branch);
            },
            .worktree_lock => |w| {
                gpa.free(w.path);
                gpa.free(w.reason);
            },
            .worktree_unlock => |p| gpa.free(p),
            .checkout_force => |s| gpa.free(s),
            .push_force => {},
            .rerun => |argv| {
                for (argv) |a| gpa.free(a);
                gpa.free(argv);
            },
            .show_file => |s| {
                gpa.free(s.rev);
                gpa.free(s.path);
            },
            .stash => |s| s.deinit(gpa),
            .stash_pop => |s| if (s) |m| gpa.free(m),
            .stash_show => |s| gpa.free(s),
            .stash_branch => |s| {
                gpa.free(s.ref);
                gpa.free(s.name);
            },
            .stash_rename => |s| {
                gpa.free(s.ref);
                gpa.free(s.msg);
            },
            .blame, .stage, .unstage, .discard, .commit, .checkout, .delete_branch, .merge, .rebase, .stash_apply, .stash_drop, .tag, .tag_delete, .cherry_pick, .revert, .worktree_remove => |s| gpa.free(s),
            .tag_at => |t| {
                gpa.free(t.name);
                gpa.free(t.start);
            },
            .push_branch => |p| {
                gpa.free(p.remote);
                gpa.free(p.branch);
            },
            .push_start_pr => |p| {
                gpa.free(p.remote);
                gpa.free(p.branch);
                gpa.free(p.url);
            },
            .commit_detail => |s| gpa.free(s),
            .amend => |s| gpa.free(s),
            .ai_context => {},
            .branch_explain => |e| {
                gpa.free(e.branch);
                gpa.free(e.base);
            },
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
            .test_swallow => {},
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
        /// `url` (git-menus) is a page a successful op opens in the
        /// browser — *Push and start PR*'s new-pull-request page.
        op: struct { desc: []const u8, ok: bool, msg: []const u8 = "", refresh: bool = true, url: []const u8 = "" },
        url: []const u8,
        head_sha: []const u8,
        commit_detail: struct { sha: []const u8, message: []const u8, files: []parse.DetailFile },
        /// A stash's files (`stash show --name-status`) and its message.
        stash_show: struct { ref: []const u8, message: []const u8, files: []parse.DetailFile },
        /// A file's text at a revision (`show rev:path`).
        file_text: struct { rev: []const u8, path: []const u8, text: []const u8 },
        /// One line of the command log (git-more2): what the worker ran,
        /// where, how it ended and how long it took. Posted from `gitIn`
        /// and `run` for every child; the handler keeps the last 200.
        log_line: LogLine,
        /// `diff` is empty when there is nothing to summarise; `message`
        /// is HEAD's current message for `.head`.
        ai_context: struct { what: AiContext, diff: []const u8, message: []const u8 },
        /// `log --stat base..branch`; `text` is empty when the branch has
        /// nothing the base does not.
        branch_explain: struct { branch: []const u8, base: []const u8, text: []const u8 },
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

/// One child the worker ran. `argv` is the whole line (`git --no-pager
/// … status`), `args` the part after `git` (what a re-run needs);
/// `exit` is null when the child did not exit normally (a spawn
/// failure, a signal); `stderr` is its first line.
pub const LogLine = struct {
    seq: u32,
    argv: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    ok: bool,
    exit: ?u8,
    ms: u32,
    stderr: []const u8,
};

/// The commands a log row's Enter may run again: they read the repo
/// and change nothing. A verb with writing forms (`branch`, `stash`,
/// `remote`, `worktree`, `config`) is read-only only in its listing
/// form.
pub fn isReadOnly(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const verb = args[0];
    const plain = [_][]const u8{ "status", "diff", "log", "show", "rev-parse", "for-each-ref", "ls-files", "ls-remote", "blame", "diff-tree", "symbolic-ref", "cat-file", "name-rev", "describe", "rev-list", "reflog", "shortlog", "ls-tree", "merge-base", "check-ignore", "var", "version" };
    for (plain) |p| if (std.mem.eql(u8, verb, p)) return true;
    const rest = args[1..];
    if (std.mem.eql(u8, verb, "branch")) {
        for (rest) |a| if (!std.mem.startsWith(u8, a, "-") or std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "-D") or std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "-M") or std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "-C") or std.mem.startsWith(u8, a, "--set-upstream") or std.mem.eql(u8, a, "--unset-upstream") or std.mem.eql(u8, a, "--delete") or std.mem.eql(u8, a, "--move") or std.mem.eql(u8, a, "--copy") or std.mem.eql(u8, a, "--edit-description")) return false;
        return true;
    }
    if (std.mem.eql(u8, verb, "stash")) return rest.len > 0 and (std.mem.eql(u8, rest[0], "list") or std.mem.eql(u8, rest[0], "show"));
    if (std.mem.eql(u8, verb, "remote")) return rest.len == 0 or std.mem.eql(u8, rest[0], "-v") or std.mem.eql(u8, rest[0], "show") or std.mem.eql(u8, rest[0], "get-url");
    if (std.mem.eql(u8, verb, "worktree")) return rest.len > 0 and std.mem.eql(u8, rest[0], "list");
    if (std.mem.eql(u8, verb, "config")) {
        for (rest) |a| if (std.mem.eql(u8, a, "--get") or std.mem.eql(u8, a, "--get-all") or std.mem.eql(u8, a, "--get-regexp") or std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list")) return true;
        return false;
    }
    return false;
}

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
    /// The queue the worker posts into — kept from `start` so every
    /// child it runs can post its command-log line (git-more2).
    events: ?*event.EventQueue = null,
    /// Worker-owned: the command log's sequence number.
    log_seq: u32 = 0,

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
    ///
    /// The queue closes *before* the group is cancelled. A worker parked
    /// on `get` leaves on the close (a plain futex wake, `error.Closed`)
    /// whatever its cancel state; the cancel is for a job in flight. The
    /// other order hung the suite: a cancel that lands while the worker
    /// is between syscalls is only *requested*, the runtime marks the
    /// task `canceled` at its next syscall — and if that syscall's
    /// `error.Canceled` is dropped (`gitDirHas` did), every later wait
    /// of the task is uninterruptible and `cancel` is not told, so the
    /// worker parks on `get` for good and `cancel` waits on it for good.
    pub fn destroy(self: *Repo, io: Io) void {
        const gpa = self.gpa;
        self.jobs.close(io);
        self.group.cancel(io);
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
        self.events = events;
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
    /// The exit code; null when the child did not exit normally.
    exit: ?u8 = null,

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

pub const EnvPair = struct { key: []const u8, value: []const u8 };

/// `git` with `extra` set in the child's environment on top of the
/// repo's. The editors are set this way — `GIT_EDITOR` /
/// `GIT_SEQUENCE_EDITOR` — because the variables beat `core.editor`
/// and `sequence.editor`, and the app's own environment may carry one
/// (`GIT_EDITOR=true` under a test harness).
fn gitEnv(repo: *Repo, io: Io, arena: Allocator, args: []const []const u8, stdin_text: ?[]const u8, extra: []const EnvPair) JobError!Out {
    if (extra.len == 0) return git(repo, io, arena, args, stdin_text);
    var m = if (repo.env) |*e| try e.clone(repo.gpa) else std.process.Environ.Map.init(repo.gpa);
    defer m.deinit();
    for (extra) |kv| try m.put(kv.key, kv.value);
    return gitIn(repo, io, arena, args, stdin_text, &m);
}

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
    const started = nowMs(io);
    if (stdin_text) |text| {
        const out = try gitWithStdin(repo, io, arena, argv, text, env);
        try postLogLine(repo, io, argv, args, started, out.ok, out.exit, out.stderr);
        return out;
    }
    const res = std.process.run(repo.gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = env,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const reason = try std.fmt.allocPrint(arena, "cannot run git: {s}", .{@errorName(err)});
            try postLogLine(repo, io, argv, args, started, false, null, reason);
            return .{ .ok = false, .stdout = "", .stderr = reason };
        },
    };
    defer repo.gpa.free(res.stdout);
    defer repo.gpa.free(res.stderr);
    const out: Out = .{
        .ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        },
        .exit = switch (res.term) {
            .exited => |c| c,
            else => null,
        },
        .stdout = try arena.dupe(u8, res.stdout),
        .stderr = try arena.dupe(u8, res.stderr),
    };
    try postLogLine(repo, io, argv, args, started, out.ok, out.exit, out.stderr);
    return out;
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// The command log (git-more2): one `.log_line` result per child,
/// posted as its own event so the log reads in order with the results
/// — a job's line lands before the job's outcome. Nothing is posted
/// before `start` (a test running the argv builders alone).
fn postLogLine(repo: *Repo, io: Io, argv: []const []const u8, args: []const []const u8, started: i64, ok: bool, exit: ?u8, stderr: []const u8) Allocator.Error!void {
    const events = repo.events orelse return;
    const gpa = repo.gpa;
    const r = try Result.create(gpa, repo.id);
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    var line: std.ArrayListUnmanaged(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i > 0) try line.append(arena, ' ');
        try line.appendSlice(arena, a);
    }
    const copy = try arena.alloc([]const u8, args.len);
    for (copy, args) |*c, a| c.* = try arena.dupe(u8, a);
    const e = std.mem.trim(u8, stderr, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, e, '\n') orelse e.len;
    repo.log_seq += 1;
    const elapsed = nowMs(io) - started;
    r.payload = .{ .log_line = .{
        .seq = repo.log_seq,
        .argv = line.items,
        .args = copy,
        .cwd = try arena.dupe(u8, repo.path),
        .ok = ok,
        .exit = exit,
        .ms = @intCast(std.math.clamp(elapsed, 0, std.math.maxInt(u32))),
        .stderr = try arena.dupe(u8, e[0..nl]),
    } };
    events.post(io, .{ .git = r });
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
        stdin.writeStreamingAll(io, text) catch |err| keepCancel(io, err);
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
        .exit = switch (term) {
            .exited => |c| c,
            else => null,
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
                // One file, index → worktree (`git diff -- <rel>`, Rust's
                // `diff_file`): the unstaged change, what stage / discard
                // act on. Against HEAD the staged lines painted as if
                // unstaged, and a discard on one wrote HEAD's line back
                // over an index that kept the edit.
                .file => try args.appendSlice(arena, &.{ "diff", "--no-ext-diff", ctx, "--", d.path orelse "" }),
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
                .range => {
                    try args.appendSlice(arena, &.{ "diff", "--no-ext-diff", ctx, d.rev orelse "HEAD..HEAD", "--" });
                    if (d.path) |p| try args.append(arena, p);
                },
                .conflict => unreachable,
            }
            var used_args: []const []const u8 = args.items;
            var out = try git(repo, io, arena, used_args, if (d.scope == .orig) (d.text orelse "") else null);
            // `diff -- untracked` is empty; show the file as new so the
            // pane has something to say. A TRACKED file with nothing
            // unstaged (all of it staged) stays empty — `(no changes)`,
            // not the whole file as an addition.
            if (d.scope == .file and out.ok and trimmed(out.stdout).len == 0) {
                const tracked = try git(repo, io, arena, &.{ "ls-files", "--error-unmatch", "--", d.path orelse "" }, null);
                if (!tracked.ok) {
                    used_args = &.{ "diff", "--no-ext-diff", ctx, "--no-index", "--", "/dev/null", d.path orelse "" };
                    out = try git(repo, io, arena, used_args, null);
                }
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
            // `%gs`, the reflog subject: a renamed stash (`stash store -m`)
            // changes that, not its commit's `%s`.
            const stash_out = try git(repo, io, arena, &.{ "stash", "list", "--format=%h%x1f%gd%x1f%gs" }, null);
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
                .stashes => try git(repo, io, arena, &.{ "stash", "list", "--format=%gd%x1f%gs" }, null),
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
        .branch_explain => |e| {
            const range = try std.fmt.allocPrint(arena, "{s}..{s}", .{ e.base, e.branch });
            const out = try git(repo, io, arena, &.{ "log", "--no-color", "--stat", "--date=short", "--format=%h %ad %an%n%s%n%b", "-n", "60", range }, null);
            r.payload = .{ .branch_explain = .{
                .branch = try arena.dupe(u8, e.branch),
                .base = try arena.dupe(u8, e.base),
                .text = if (out.ok) trimmed(out.stdout) else "",
            } };
        },
        .amend => |msg| {
            const before = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "commit", "-q", "--amend", "-m", msg }, null);
            if (out.ok) {
                const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
                if (before.ok and after.ok) {
                    const desc = try std.fmt.allocPrint(arena, "amend {s}", .{firstLine(msg)});
                    const pair = try dupe2(gpa, trimmed(before.stdout), trimmed(after.stdout));
                    try pushUndo(repo, desc, .{ .reset_soft = pair[0] }, .{ .reset_soft = pair[1] });
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
                    // dupe2 covers the window between the two dupes (a
                    // cancel there leaked the first under load); past
                    // it, pushUndo owns both and frees them on failure.
                    const desc = try std.fmt.allocPrint(arena, "commit {s}", .{firstLine(msg)});
                    const pair = try dupe2(gpa, trimmed(before.stdout), trimmed(after.stdout));
                    try pushUndo(repo, desc, .{ .reset_soft = pair[0] }, .{ .reset_soft = pair[1] });
                }
            }
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "committed: {s}", .{firstLine(msg)}), .ok = out.ok, .msg = out.reason() } };
        },
        .checkout => |b| {
            const from = try git(repo, io, arena, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "checkout", "-q", b }, null);
            if (out.ok and from.ok and trimmed(from.stdout).len > 0) {
                const desc = try std.fmt.allocPrint(arena, "checkout {s}", .{b});
                const pair = try dupe2(gpa, trimmed(from.stdout), b);
                try pushUndo(repo, desc, .{ .checkout = pair[0] }, .{ .checkout = pair[1] });
            }
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "checked out {s}", .{b}), .ok = out.ok, .msg = out.reason() } };
        },
        .new_branch => |b| try simple(repo, io, r, try newBranchArgs(arena, b.name, b.start), if (b.start) |s| try std.fmt.allocPrint(arena, "created branch {s} from {s}", .{ b.name, shortRef(s) }) else try std.fmt.allocPrint(arena, "created branch {s}", .{b.name})),
        .branch_rename => |b| try simple(repo, io, r, &.{ "branch", "-m", b.from, b.to }, try std.fmt.allocPrint(arena, "renamed {s} to {s}", .{ b.from, b.to })),
        .fast_forward => |b| {
            const args = try fastForwardArgs(arena, b.branch, b.upstream, b.checked_out) orelse {
                r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "fast-forward {s}", .{b.branch}), .ok = false, .msg = try std.fmt.allocPrint(arena, "`{s}` is not a remote branch (remote/name)", .{b.upstream}), .refresh = false } };
                events.post(io, .{ .git = r });
                return;
            };
            const desc = try std.fmt.allocPrint(arena, "fast-forwarded {s} to {s}", .{ b.branch, b.upstream });
            if (b.checked_out) {
                // The tree moves with HEAD: undo puts both back.
                const snap = try snapshot(repo, io, arena);
                const out = try git(repo, io, arena, args, null);
                if (out.ok) try pushSnapshotUndo(repo, io, arena, desc, snap);
                r.payload = .{ .op = .{ .desc = desc, .ok = out.ok, .msg = out.reason() } };
            } else try simple(repo, io, r, args, desc);
        },
        .set_upstream => |b| try simple(repo, io, r, &.{ "branch", "-q", "-u", b.upstream, b.branch }, try std.fmt.allocPrint(arena, "{s} tracks {s}", .{ b.branch, b.upstream })),
        .checkout_force => |b| {
            const snap = try snapshot(repo, io, arena);
            const out = try git(repo, io, arena, &.{ "checkout", "-q", "-f", b }, null);
            const desc = try std.fmt.allocPrint(arena, "checked out {s} (forced)", .{b});
            if (out.ok) try pushSnapshotUndo(repo, io, arena, desc, snap);
            r.payload = .{ .op = .{ .desc = desc, .ok = out.ok, .msg = out.reason() } };
        },
        .delete_remote => |b| try simple(repo, io, r, &.{ "push", "-q", b.remote, "--delete", b.branch }, try std.fmt.allocPrint(arena, "deleted {s}/{s} on the remote", .{ b.remote, b.branch })),
        .push_force => try simple(repo, io, r, &.{ "push", "-q", "--force-with-lease" }, "pushed (--force-with-lease)"),
        .show_file => |s| {
            const out = try git(repo, io, arena, &.{ "show", try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.rev, s.path }) }, null);
            if (!out.ok) {
                r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "show {s} at {s}", .{ s.path, shortRef(s.rev) }), .ok = false, .msg = out.reason(), .refresh = false } };
            } else {
                r.payload = .{ .file_text = .{ .rev = try arena.dupe(u8, s.rev), .path = try arena.dupe(u8, s.path), .text = out.stdout } };
            }
        },
        .rerun => |argv| {
            const out = try git(repo, io, arena, argv, null);
            var line: std.ArrayListUnmanaged(u8) = .empty;
            try line.appendSlice(arena, "re-ran: git");
            for (argv) |a| {
                try line.append(arena, ' ');
                try line.appendSlice(arena, a);
            }
            // The first output line rides in the toast.
            const first = firstLine(out.stdout);
            if (out.ok and first.len > 0) {
                try line.appendSlice(arena, " \u{2192} ");
                try line.appendSlice(arena, first[0..@min(first.len, 60)]);
            }
            r.payload = .{ .op = .{ .desc = line.items, .ok = out.ok, .msg = out.reason(), .refresh = false } };
        },
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
        .stash => |s| {
            const what: []const u8 = if (s.staged_only) "stashed the index" else if (s.paths != null) (if (s.paths.?.len == 1) try std.fmt.allocPrint(arena, "stashed {s}", .{s.paths.?[0]}) else try std.fmt.allocPrint(arena, "stashed {d} files", .{s.paths.?.len})) else if (s.keep_index) "stashed (index kept)" else "stashed";
            const desc = if (s.msg) |m| try std.fmt.allocPrint(arena, "{s}: {s}", .{ what, m }) else what;
            try simple(repo, io, r, try stashArgs(arena, s), desc);
        },
        .stash_show => |ref| {
            // `--include-untracked` lists the third parent's files (git
            // 2.32+); an older git refuses the flag, so ask without it then.
            var out = try git(repo, io, arena, &.{ "stash", "show", "--name-status", "--include-untracked", ref }, null);
            if (!out.ok) out = try git(repo, io, arena, &.{ "stash", "show", "--name-status", ref }, null);
            if (!out.ok) {
                r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "show {s}", .{ref}), .ok = false, .msg = out.reason(), .refresh = false } };
            } else {
                r.payload = .{ .stash_show = .{ .ref = try arena.dupe(u8, ref), .message = try stashMessage(repo, io, arena, ref), .files = try parse.parseNameStatus(arena, out.stdout) } };
            }
        },
        .stash_branch => |s| try simple(repo, io, r, &.{ "stash", "branch", s.name, s.ref }, try std.fmt.allocPrint(arena, "branch {s} from {s}", .{ s.name, s.ref })),
        .stash_rename => |s| {
            const desc = try std.fmt.allocPrint(arena, "renamed {s}", .{s.ref});
            const sha = try git(repo, io, arena, &.{ "rev-parse", s.ref }, null);
            if (!sha.ok) return fail(r, desc, sha);
            const msg = try parse.stashRenameMessage(arena, try stashMessage(repo, io, arena, s.ref), s.msg);
            const dropped = try git(repo, io, arena, &.{ "stash", "drop", "-q", s.ref }, null);
            if (!dropped.ok) return fail(r, desc, dropped);
            const stored = try git(repo, io, arena, &.{ "stash", "store", "-m", msg, trimmed(sha.stdout) }, null);
            r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "renamed {s}: {s}", .{ s.ref, msg }), .ok = stored.ok, .msg = stored.reason() } };
        },
        .stash_pop => |ref| if (ref) |x| try simple(repo, io, r, &.{ "stash", "pop", "-q", x }, "stash popped") else try simple(repo, io, r, &.{ "stash", "pop", "-q" }, "stash popped"),
        .stash_apply => |ref| try simple(repo, io, r, &.{ "stash", "apply", "-q", ref }, try std.fmt.allocPrint(arena, "applied {s}", .{ref})),
        .stash_drop => |ref| try simple(repo, io, r, &.{ "stash", "drop", "-q", ref }, try std.fmt.allocPrint(arena, "dropped {s}", .{ref})),
        .tag => |name| try simple(repo, io, r, &.{ "tag", "-a", name, "-m", name }, try std.fmt.allocPrint(arena, "tagged {s}", .{name})),
        .tag_at => |t| if (t.annotated)
            try simple(repo, io, r, &.{ "tag", "-a", t.name, "-m", t.name, t.start }, try std.fmt.allocPrint(arena, "tagged {s} at {s}", .{ t.name, t.start }))
        else
            try simple(repo, io, r, &.{ "tag", t.name, t.start }, try std.fmt.allocPrint(arena, "tagged {s} at {s}", .{ t.name, t.start })),
        .push_branch => |p| try simple(repo, io, r, &.{ "push", "-u", p.remote, p.branch }, try std.fmt.allocPrint(arena, "pushed {s} to {s}", .{ p.branch, p.remote })),
        .push_start_pr => |p| {
            const out = try git(repo, io, arena, &.{ "push", "-u", p.remote, p.branch }, null);
            r.payload = .{ .op = .{
                .desc = try std.fmt.allocPrint(arena, "pushed {s} to {s}", .{ p.branch, p.remote }),
                .ok = out.ok,
                .msg = out.reason(),
                .url = if (out.ok) try arena.dupe(u8, p.url) else "",
            } };
        },
        .tag_delete => |name| try simple(repo, io, r, &.{ "tag", "-d", name }, try std.fmt.allocPrint(arena, "deleted tag {s}", .{name})),
        .cherry_pick => |sha| try simple(repo, io, r, &.{ "cherry-pick", sha }, try std.fmt.allocPrint(arena, "cherry-picked {s}", .{sha[0..@min(7, sha.len)]})),
        .revert => |sha| try simple(repo, io, r, &.{ "revert", "--no-edit", sha }, try std.fmt.allocPrint(arena, "reverted {s}", .{sha[0..@min(7, sha.len)]})),
        .undo => {
            if (repo.undo.pop()) |entry| {
                // Popped and not yet on the other list: a step that fails
                // part-way (the child cancelled at shutdown) frees it.
                errdefer entry.deinit(gpa);
                const out = try applyAction(repo, io, arena, entry.undo);
                if (out.ok) {
                    const desc = try std.fmt.allocPrint(arena, "undid: {s}", .{entry.desc});
                    try repo.redo.append(gpa, entry);
                    r.payload = .{ .op = .{ .desc = desc, .ok = true } };
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
                // Popped and not yet on the other list: a step that fails
                // part-way (the child cancelled at shutdown) frees it.
                errdefer entry.deinit(gpa);
                const out = try applyAction(repo, io, arena, entry.redo);
                if (out.ok) {
                    const desc = try std.fmt.allocPrint(arena, "redid: {s}", .{entry.desc});
                    try repo.undo.append(gpa, entry);
                    r.payload = .{ .op = .{ .desc = desc, .ok = true } };
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
            const args = try worktreeAddArgs(arena, w.path, w.branch, w.start);
            if (w.branch) |b| {
                try simple(repo, io, r, args, try std.fmt.allocPrint(arena, "worktree added at {s} on {s}", .{ w.path, b }));
            } else try simple(repo, io, r, args, try std.fmt.allocPrint(arena, "worktree added at {s}", .{w.path}));
        },
        .worktree_remove => |p| try simple(repo, io, r, &.{ "worktree", "remove", "--force", p }, try std.fmt.allocPrint(arena, "worktree removed: {s}", .{p})),
        .worktree_lock => |w| {
            if (w.reason.len > 0) {
                try simple(repo, io, r, &.{ "worktree", "lock", "--reason", w.reason, w.path }, try std.fmt.allocPrint(arena, "worktree locked: {s} ({s})", .{ w.path, w.reason }));
            } else {
                try simple(repo, io, r, &.{ "worktree", "lock", w.path }, try std.fmt.allocPrint(arena, "worktree locked: {s}", .{w.path}));
            }
        },
        .worktree_unlock => |p| try simple(repo, io, r, &.{ "worktree", "unlock", p }, try std.fmt.allocPrint(arena, "worktree unlocked: {s}", .{p})),
        .worktree_remove_branch => |w| {
            const rm = if (w.force)
                try git(repo, io, arena, &.{ "worktree", "remove", "--force", w.path }, null)
            else
                try git(repo, io, arena, &.{ "worktree", "remove", w.path }, null);
            if (!rm.ok) {
                r.payload = .{ .op = .{ .desc = try std.fmt.allocPrint(arena, "remove worktree {s}", .{w.path}), .ok = false, .msg = rm.reason() } };
            } else {
                const br = try git(repo, io, arena, &.{ "branch", if (w.force) "-D" else "-d", w.branch }, null);
                r.payload = .{ .op = .{
                    .desc = if (br.ok)
                        try std.fmt.allocPrint(arena, "worktree removed: {s}, branch {s} deleted", .{ w.path, w.branch })
                    else
                        try std.fmt.allocPrint(arena, "worktree removed: {s}; branch {s} kept", .{ w.path, w.branch }),
                    .ok = br.ok,
                    .msg = br.reason(),
                } };
            }
        },
        .op_continue => |op| switch (op) {
            .none => r.payload = .{ .op = .{ .desc = "nothing in progress", .ok = false, .refresh = false } },
            .bisect => r.payload = .{ .op = .{ .desc = "bisect: mark a commit good or bad instead", .ok = false, .refresh = false } },
            else => try simpleEnv(repo, io, r, &.{ op.verb(), "--continue" }, try std.fmt.allocPrint(arena, "{s} continued", .{op.verb()}), &no_editor),
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
            else => try simpleEnv(repo, io, r, &.{ op.verb(), "--skip" }, try std.fmt.allocPrint(arena, "{s}: step skipped", .{op.verb()}), &no_editor),
        },
        .amend_noedit => {
            const before = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
            const out = try git(repo, io, arena, &.{ "commit", "-q", "--amend", "--no-edit" }, null);
            if (out.ok) {
                const after = try git(repo, io, arena, &.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
                if (before.ok and after.ok) {
                    const pair = try dupe2(gpa, trimmed(before.stdout), trimmed(after.stdout));
                    try pushUndo(repo, "amend (staged changes into HEAD)", .{ .reset_soft = pair[0] }, .{ .reset_soft = pair[1] });
                }
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
            try args.appendSlice(arena, &.{ "rebase", "-i", "--autosquash", "--autostash" });
            if (parent.ok and trimmed(parent.stdout).len > 0) try args.append(arena, trimmed(parent.stdout)) else try args.append(arena, "--root");
            const out = try gitEnv(repo, io, arena, args.items, null, &no_editor);
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
                    if (snap.head) |h| if (after.ok) {
                        const pair = try dupe2(gpa, h, trimmed(after.stdout));
                        try pushUndo(repo, desc, .{ .reset_soft = pair[0] }, .{ .reset_soft = pair[1] });
                    };
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
            cwd.writeFile(io, .{ .sub_path = plan_path, .data = try sequence_editor.todoText(arena, plan.ops) }) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                r.payload = .{ .op = .{ .desc = "rebase", .ok = false, .msg = "cannot write the plan into the git dir", .refresh = false } };
                events.post(io, .{ .git = r });
                return;
            };
            cwd.writeFile(io, .{ .sub_path = queue_path, .data = try sequence_editor.queueText(arena, plan.ops) }) catch |err| keepCancel(io, err);
            const snap = try snapshot(repo, io, arena);
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            try args.appendSlice(arena, &.{ "rebase", "-i", "--autostash" });
            if (plan.base) |b| try args.append(arena, b) else try args.append(arena, "--root");
            const editors = [_]EnvPair{
                .{ .key = "GIT_SEQUENCE_EDITOR", .value = try sequence_editor.editorCommand(arena, exe, "--rebase-todo", plan_path) },
                .{ .key = "GIT_EDITOR", .value = try sequence_editor.editorCommand(arena, exe, "--commit-msg", queue_path) },
            };
            const out = try gitEnv(repo, io, arena, args.items, null, &editors);
            var n_changed: usize = 0;
            for (plan.ops) |op| if (op.action != .pick) {
                n_changed += 1;
            };
            const desc = try std.fmt.allocPrint(arena, "rebased: {d} commit(s), {d} changed", .{ plan.ops.len, n_changed });
            if (out.ok) try pushSnapshotUndo(repo, io, arena, desc, snap);
            cwd.deleteFile(io, plan_path) catch |err| keepCancel(io, err);
            cwd.deleteFile(io, queue_path) catch |err| keepCancel(io, err);
            r.payload = .{ .op = .{ .desc = if (out.ok) desc else "rebase", .ok = out.ok, .msg = out.reason() } };
        },
        .test_swallow => |gate| if (builtin.is_test) {
            gate.store(1, .release);
            // The cancel's signal interrupts the sleep: `error.Canceled`,
            // acknowledged by the runtime — and dropped here.
            io.sleep(.fromMilliseconds(2000), .awake) catch {};
            r.destroy(gpa);
            return;
        } else unreachable,
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

/// A stash's message as the list shows it — the reflog subject, which
/// a rename changes; empty when `ref` is not in the list.
fn stashMessage(repo: *Repo, io: Io, arena: Allocator, ref: []const u8) JobError![]const u8 {
    const out = try git(repo, io, arena, &.{ "stash", "list", "--format=%gd%x1f%gs" }, null);
    if (!out.ok) return "";
    for (try parse.parseStashes(arena, try prefixShas(arena, out.stdout))) |s| if (std.mem.eql(u8, s.ref, ref)) return s.message;
    return "";
}

/// `parseStashes` reads three fields; the two-field list gets an empty
/// sha column in front.
fn prefixShas(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.appendSlice(arena, "-\x1f");
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

// ─── branch verbs (git-more2): the argv builders ────────────────────────

/// `checkout -q -b name [start]`.
pub fn newBranchArgs(arena: Allocator, name: []const u8, start: ?[]const u8) Allocator.Error![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "checkout", "-q", "-b", name });
    if (start) |s| try args.append(arena, s);
    return args.items;
}

/// `worktree add path [-b branch] [start]`: a detached tree at `start`
/// when there is no branch to make.
pub fn worktreeAddArgs(arena: Allocator, path: []const u8, branch: ?[]const u8, start: ?[]const u8) Allocator.Error![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "worktree", "add", path });
    if (branch) |b| try args.appendSlice(arena, &.{ "-b", b });
    if (start) |s| {
        if (branch == null) try args.append(arena, "--detach");
        try args.append(arena, s);
    }
    return args.items;
}

/// `merge --ff-only upstream` for the checked-out branch; for another,
/// `fetch remote ref:branch` — git refuses a non-fast-forward there
/// too. Null when `upstream` has no `remote/` half.
pub fn fastForwardArgs(arena: Allocator, branch: []const u8, upstream: []const u8, checked_out: bool) Allocator.Error!?[]const []const u8 {
    if (checked_out) return try arena.dupe([]const u8, &.{ "merge", "-q", "--ff-only", upstream });
    const slash = std.mem.indexOfScalar(u8, upstream, '/') orelse return null;
    if (slash == 0 or slash + 1 >= upstream.len) return null;
    return try arena.dupe([]const u8, &.{ "fetch", "-q", upstream[0..slash], try std.fmt.allocPrint(arena, "{s}:{s}", .{ upstream[slash + 1 ..], branch }) });
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

// A missing state file is `false` / `null`; a cancellation is a
// cancellation (dropping it here is what wedged `Repo.destroy`).
fn gitDirHas(io: Io, arena: Allocator, dir: []const u8, name: []const u8) JobError!bool {
    const p = try std.fs.path.join(arena, &.{ dir, name });
    Io.Dir.cwd().access(io, p, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return true;
}

fn gitDirRead(io: Io, arena: Allocator, dir: []const u8, name: []const u8) JobError!?[]const u8 {
    const p = try std.fs.path.join(arena, &.{ dir, name });
    return Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
}

/// For a job path that cannot propagate `error.Canceled` (a `defer`, a
/// best-effort cleanup): re-arm it. The runtime marks a task `canceled`
/// the moment a syscall reports it; a task that drops that error is
/// never told again and its next wait cannot be interrupted.
fn keepCancel(io: Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
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
        const body = if (st.ok) trimmed(st.stdout) else "";
        w.dirty = body.len > 0;
        if (w.dirty) {
            var lines = std.mem.splitScalar(u8, body, '\n');
            while (lines.next()) |line| if (std.mem.trim(u8, line, " \t\r").len > 0) {
                w.dirty_files += 1;
            };
        }
    }
    return trees;
}

/// Run a non-git binary (`gh`) in the repo, the same way `git` runs.
/// Its line in the command log has no re-run (`args` is empty).
fn run(repo: *Repo, io: Io, arena: Allocator, argv: []const []const u8) JobError!Out {
    const started = nowMs(io);
    const res = std.process.run(repo.gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = repo.path },
        .environ_map = if (repo.env) |*e| e else null,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const reason = try std.fmt.allocPrint(arena, "cannot run {s}: {s}", .{ argv[0], @errorName(err) });
            try postLogLine(repo, io, argv, &.{}, started, false, null, reason);
            return .{ .ok = false, .stdout = "", .stderr = reason };
        },
    };
    defer repo.gpa.free(res.stdout);
    defer repo.gpa.free(res.stderr);
    const out: Out = .{
        .ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        },
        .exit = switch (res.term) {
            .exited => |c| c,
            else => null,
        },
        .stdout = try arena.dupe(u8, res.stdout),
        .stderr = try arena.dupe(u8, res.stderr),
    };
    try postLogLine(repo, io, argv, &.{}, started, out.ok, out.exit, out.stderr);
    return out;
}

/// Run `args` and post `desc` as the toast on success, git's reason on
/// failure. The result is posted here.
fn simple(repo: *Repo, io: Io, r: *Result, args: []const []const u8, desc: []const u8) JobError!void {
    return simpleEnv(repo, io, r, args, desc, &.{});
}

fn simpleEnv(repo: *Repo, io: Io, r: *Result, args: []const []const u8, desc: []const u8, extra: []const EnvPair) JobError!void {
    const arena = r.arena.allocator();
    const out = try gitEnv(repo, io, arena, args, null, extra);
    r.payload = .{ .op = .{ .desc = desc, .ok = out.ok, .msg = out.reason() } };
}

/// No editor ever opens: git takes the message it has.
const no_editor = [_]EnvPair{ .{ .key = "GIT_EDITOR", .value = "true" }, .{ .key = "GIT_SEQUENCE_EDITOR", .value = "true" } };

/// Both strings or neither: the first is freed when the second fails.
/// The pair goes straight into `pushUndo`, which owns its actions from
/// the call on, failure included — so nothing is outstanding at the
/// call site and nothing is freed twice.
fn dupe2(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error![2][]u8 {
    const x = try gpa.dupe(u8, a);
    errdefer gpa.free(x);
    return .{ x, try gpa.dupe(u8, b) };
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
        std.Io.Dir.cwd().deleteFile(io, t.path) catch |err| keepCancel(io, err);
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
    cwd.writeFile(io, .{ .sub_path = a, .data = if (ours.ok) ours.stdout else "" }) catch |err| {
        keepCancel(io, err);
        return &.{};
    };
    defer cwd.deleteFile(io, a) catch |err| keepCancel(io, err);
    cwd.writeFile(io, .{ .sub_path = b, .data = if (theirs.ok) theirs.stdout else "" }) catch |err| {
        keepCancel(io, err);
        return &.{};
    };
    defer cwd.deleteFile(io, b) catch |err| keepCancel(io, err);
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

test "rangeRev joins two refs; rangeTitle shortens a full sha on either side and leaves a name whole" {
    const rev = try rangeRev(testing.allocator, "0123456789abcdef0123456789abcdef01234567", "feature");
    defer testing.allocator.free(rev);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567..feature", rev);
    const title = try rangeTitle(testing.allocator, rev);
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("0123456..feature", title);
    const plain = try rangeTitle(testing.allocator, "main");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("main", plain);
}

test "isReadOnly: the listing verbs re-run; the writing ones and the writing forms of branch / stash / remote / config do not" {
    try testing.expect(isReadOnly(&.{ "status", "--porcelain=v2", "-b" }));
    try testing.expect(isReadOnly(&.{ "diff", "--no-ext-diff", "-U3", "HEAD", "--" }));
    try testing.expect(isReadOnly(&.{ "log", "--date-order", "-n500", "--all" }));
    try testing.expect(isReadOnly(&.{ "branch", "--list" }));
    try testing.expect(isReadOnly(&.{"branch"}));
    try testing.expect(isReadOnly(&.{ "stash", "list", "--format=%gs" }));
    try testing.expect(isReadOnly(&.{ "remote", "-v" }));
    try testing.expect(isReadOnly(&.{ "worktree", "list", "--porcelain" }));
    try testing.expect(isReadOnly(&.{ "config", "--get", "remote.origin.url" }));
    try testing.expect(!isReadOnly(&.{ "push", "-q" }));
    try testing.expect(!isReadOnly(&.{ "commit", "-q", "-m", "x" }));
    try testing.expect(!isReadOnly(&.{ "branch", "-m", "a", "b" }));
    try testing.expect(!isReadOnly(&.{ "branch", "-D", "a" }));
    try testing.expect(!isReadOnly(&.{ "branch", "feat" }));
    try testing.expect(!isReadOnly(&.{ "stash", "push", "-q" }));
    try testing.expect(!isReadOnly(&.{ "remote", "add", "x", "y" }));
    try testing.expect(!isReadOnly(&.{ "worktree", "add", "p" }));
    try testing.expect(!isReadOnly(&.{ "config", "user.name", "x" }));
    try testing.expect(!isReadOnly(&.{}));
}

test "stashArgs: everything takes -u; staged only drops -u for --staged; keep-index and a message and paths ride along" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "stash", "push", "-q", "-u" }), try stashArgs(arena, .{}));
    const msg = try arena.dupe(u8, "wip");
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "stash", "push", "-q", "--staged", "-m", "wip" }), try stashArgs(arena, .{ .msg = msg, .staged_only = true }));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "stash", "push", "-q", "-u", "--keep-index" }), try stashArgs(arena, .{ .keep_index = true }));
    const paths = try arena.alloc([]u8, 2);
    paths[0] = try arena.dupe(u8, "a.txt");
    paths[1] = try arena.dupe(u8, "dir/b.txt");
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "stash", "push", "-q", "-u", "-m", "wip", "--", "a.txt", "dir/b.txt" }), try stashArgs(arena, .{ .msg = msg, .paths = paths }));
}

test "the branch verbs' argv: a new branch from a start, a detached worktree at one, ff-only when checked out, fetch ref:branch otherwise, null without a remote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "checkout", "-q", "-b", "feat" }), try newBranchArgs(arena, "feat", null));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "checkout", "-q", "-b", "feat", "v1.0" }), try newBranchArgs(arena, "feat", "v1.0"));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "worktree", "add", "../wt", "-b", "feat", "abc" }), try worktreeAddArgs(arena, "../wt", "feat", "abc"));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "worktree", "add", "../wt", "--detach", "abc" }), try worktreeAddArgs(arena, "../wt", null, "abc"));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "worktree", "add", "../wt" }), try worktreeAddArgs(arena, "../wt", null, null));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "merge", "-q", "--ff-only", "origin/main" }), (try fastForwardArgs(arena, "main", "origin/main", true)).?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "fetch", "-q", "origin", "main:main" }), (try fastForwardArgs(arena, "main", "origin/main", false)).?);
    try testing.expect((try fastForwardArgs(arena, "main", "main", false)) == null);
    try testing.expect((try fastForwardArgs(arena, "main", "origin/", false)) == null);
}

test "a Repo's queue takes jobs, and destroy frees what was never run" {
    const io = testing.io;
    const repo = try Repo.create(testing.allocator, "/tmp", ".", 1, true);
    const msg = try testing.allocator.dupe(u8, "hello");
    try testing.expect(repo.submit(io, .{ .commit = msg }));
    try testing.expect(repo.submit(io, .status));
    try testing.expectEqual(@as(u32, 2), repo.submitted);
    repo.destroy(io);
}

test "destroy returns when the worker swallowed its cancellation and parked on the queue (the suite hang)" {
    // The interleaving that wedged `zig build test`: a job in flight when
    // `destroy` runs consumes the cancel and drops it, then parks on
    // `get` — an uninterruptible wait, and one `cancel` is never told
    // about. `destroy` runs on its own thread so a wedge is a failure
    // here, not a hung suite.
    const io = testing.io;
    var events = try event.EventQueue.init(testing.allocator, 8);
    defer events.deinit(io);
    const repo = try Repo.create(testing.allocator, "/tmp", ".", 1, true);
    try repo.start(io, &events, null);
    var gate: std.atomic.Value(u32) = .init(0);
    try testing.expect(repo.submit(io, .{ .test_swallow = &gate }));
    while (gate.load(.acquire) == 0) try io.sleep(.fromMilliseconds(1), .awake);
    const Destroyer = struct {
        repo: *Repo,
        io: Io,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.repo.destroy(self.io);
            self.done.store(true, .release);
        }
    };
    var d: Destroyer = .{ .repo = repo, .io = io };
    const th = try std.Thread.spawn(.{}, Destroyer.run, .{&d});
    var waited: u32 = 0;
    while (!d.done.load(.acquire) and waited < 5000) : (waited += 10) try io.sleep(.fromMilliseconds(10), .awake);
    const returned = d.done.load(.acquire);
    // Unwedge by hand — the close `destroy` owes the worker — so the
    // thread can finish and the test can fail rather than hang.
    if (!returned) repo.jobs.close(io);
    th.join();
    try testing.expect(returned);
}
