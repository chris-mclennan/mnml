//! What the worker thread does: one `Job` in, one `Result` out. The
//! pane never blocks on the network — the reference freezes for the
//! minutes a thirteen-repo prefetch takes under the shared bucket, and
//! paints nothing but `loading…` until it is done — so every fetch
//! runs here, with a `Progress` the main loop reads to say how far it
//! is, and lands as a `Result` the app commits on its own thread.
//!
//! The fetches are the reference's, endpoint for endpoint: a
//! workspace tab resolves its repos from the scope (the `repos`
//! allow-list short-circuits the enumeration), fans out one list per
//! repo, fills an empty repo's row with its last merge, and keeps an
//! erroring repo as a row with a short label instead of dropping it;
//! the pipelines tree pairs each branch with the newest pipeline that
//! ran on it and curates the branches; the detail is the PR plus its
//! comments; the statusline values are the reference's `--values`
//! predicate.
//!
//! A job owns an arena for its inputs; a result owns one for its data,
//! which the tab keeps until the next refresh replaces it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const api = @import("api.zig");
const cfg = @import("config.zig");
const model = @import("model.zig");
const tabs = @import("tabs.zig");
const filters = @import("filters.zig");
const dates = @import("dates.zig");
const review_cache = @import("review_cache.zig");
const link_ranges = @import("link_ranges.zig");
const sdk = @import("mnml_sdk");
const merge = sdk.pane.merge;
const j = @import("json.zig");

/// What the workspace-wide fetches need to know, copied onto the job.
pub const ScopeInputs = struct {
    workspace: []const u8,
    scope: cfg.Scope,
    recent_window_days: u32,
    explicit_repos: []const []const u8,
    hidden_repos: []const []const u8,
    repo_order: []const []const u8,
    repos: []const []const u8,
    /// Bumped by the app when any of the above changes; the worker's
    /// scope cache is keyed by it.
    generation: u32,
};

pub const PrKey = struct { workspace: []const u8, repo: []const u8, id: i64 };

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    now_secs: i64,
    /// What the request log calls the requests this job makes. A job
    /// IS a reason, so the kind supplies one; the caller overrides it
    /// only where the kind cannot tell — the first load of a tab and a
    /// refetch of one are both `.refresh` jobs.
    reason: ?api.Reason = null,
    /// Ask the server outright rather than `If-None-Match`, and ignore
    /// the prefetch cache. What `R` means.
    full: bool = false,

    pub const Kind = union(enum) {
        whoami,
        refresh: struct { tab: usize, spec: tabs.TabSpec, scope: ScopeInputs },
        detail: PrKey,
        pr_pipelines: struct { tab: usize, workspace: []const u8, slug: []const u8, id: i64, hash: []const u8, updated_on: []const u8 = "" },
        approve: struct { key: PrKey, withdraw: bool },
        /// May this pull request merge? One cached look per open PR,
        /// keyed by its `updated_on`.
        readiness: struct {
            tab: usize,
            key: PrKey,
            updated_on: []const u8,
            /// The commit the build has to be green on.
            source_commit: []const u8,
            /// Approvals the repo asks for.
            required: usize = 1,
            /// The pane already has fresh runs for this commit and
            /// says whether the newest is green, so the pipelines list
            /// is not asked for twice.
            known_build: ?bool = null,
        },
        values: struct { scope: ScopeInputs, stale_after_days: u32, excluded_branch_patterns: []const []const u8 },
        /// One pull request an event feed said moved (`sdk.feed`): the
        /// one GET for it, and the row is replaced in place.
        pr_changed: struct { tab: usize, key: PrKey },
    };

    pub fn deinit(job: *Job) void {
        job.arena.deinit();
        job.* = undefined;
    }

    /// The reason a kind means on its own.
    pub fn reasonOf(job: *const Job) api.Reason {
        if (job.reason) |r| return r;
        return switch (job.kind) {
            .whoami => .pane_open,
            .refresh => .refresh,
            .detail => .detail,
            .pr_pipelines => .builds,
            .approve => .user,
            .readiness => .readiness,
            .values => .poll,
            .pr_changed => .delta,
        };
    }
};

pub const Whoami = struct {
    account_id: []const u8 = "",
    display_name: []const u8 = "",
    error_text: []const u8 = "",
    /// Which question was asked. An access token has no `/2.0/user` to
    /// answer, so the probe is `/2.0/workspaces/<slug>` instead and no
    /// `account_id` comes back — the `mine` / `reviewing` tabs then
    /// need `account_id` set in `config.zon`.
    via: Via = .account,

    pub const Via = enum { account, workspace };
};

pub const RefreshResult = struct {
    tab: usize,
    data: ?tabs.TabData = null,
    /// The fetch failed as a whole.
    error_text: []const u8 = "",
    /// The reference's status line: `Open + Draft · 4 repos, 64 PRs (1 errored)`.
    status: []const u8 = "",
    repos: usize = 0,
    /// Rows on a flat list, PRs on a tree.
    items: usize = 0,
    errored: usize = 0,
    /// The scope the tree used, for the header's count.
    scope_repos: []const []const u8 = &.{},
    /// The API states the listing was fetched with — what the Status
    /// chip compares its ask against before deciding a refetch is due.
    states: filters.ApiStates = .{},
    /// Every GET's answer folded together: the same listing is the same
    /// digest, which is how the adaptive poller knows nothing moved.
    digest: u64 = 0,
    /// The shared bucket refused at least one request in this refresh:
    /// a skipped round, not a failure.
    refused: bool = false,
};

pub const PrChangedResult = struct {
    tab: usize,
    key: PrKey,
    pr: ?model.PullRequest = null,
    error_text: []const u8 = "",
    refused: bool = false,
};

pub const DetailResult = struct { key: PrKey, pr: ?model.PullRequest = null, comments: []const model.Comment = &.{}, error_text: []const u8 = "" };

pub const PrPipelinesResult = struct {
    tab: usize,
    slug: []const u8,
    id: i64,
    pipelines: []const model.Pipeline = &.{},
    /// The `updated_on` the caller asked on behalf of, echoed back so
    /// the app can key what it stores by it.
    updated_on: []const u8 = "",
    error_text: []const u8 = "",
};

pub const ApproveResult = struct { key: PrKey, withdrew: bool, error_text: []const u8 = "" };

pub const ReadinessResult = struct {
    tab: usize,
    key: PrKey,
    /// The `updated_on` this was true at — the cache key.
    updated_on: []const u8 = "",
    readiness: merge.Readiness = .{},
    error_text: []const u8 = "",
};

/// The three titles a segment's hover text names. A count with no
/// names behind it makes the reader open the pane to find out which
/// four; three titles answer it where the pointer already is.
pub const tooltip_titles: usize = 3;

/// How many of the things behind a figure `--values` hands over for
/// the statusline hover to list. The host caps again at
/// `statusline.hover_items`; this is what the wire carries.
pub const hover_items: usize = 8;

/// One of the things behind a figure: a pull request. `sub` is where
/// it lives and what state it is in — the hover paints it muted at
/// the right of the row.
pub const ValuesItem = struct {
    text: []const u8,
    sub: []const u8 = "",
    /// // changed (focus-row): which pull request this row is, in
    /// `prRowKey`'s shape (`repo#id`) — what a press on the row hands
    /// the pane as `--focus`, so it lands on this one rather than
    /// leaving the reader to find it. Empty for a row that names none.
    key: []const u8 = "",
};

pub const ValuesResult = struct {
    open_mine: usize = 0,
    unapproved_mine: usize = 0,
    approved_mine: usize = 0,
    /// Open pull requests where the account is a reviewer and has not
    /// voted — what is waiting on YOU rather than on someone else.
    /// Counted out of the same listing as `open_mine`: one BBQL asks
    /// for both sets, so the third figure costs no extra request.
    reviews_pending: usize = 0,
    /// The pull requests behind each figure, newest first — the rows
    /// the statusline hover lists, and the first few by name in the
    /// one-line tooltip.
    open_items: []const ValuesItem = &.{},
    comment_items: []const ValuesItem = &.{},
    awaiting_items: []const ValuesItem = &.{},
    /// Review threads across those pull requests that are still waiting
    /// on someone — not resolved and not replied to. Null when the
    /// count was not asked for (`review_cache` absent) or when every
    /// comments request for it failed, which is not the same as zero.
    unresolved_comments: ?usize = null,
    /// How the count was paid for: answered off the cache, or a
    /// request. `--values` says so, so the cadence can be judged.
    comment_hits: u32 = 0,
    comment_requests: u32 = 0,
    error_text: []const u8 = "",
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    payload: Payload,

    pub const Payload = union(enum) {
        whoami: Whoami,
        refresh: RefreshResult,
        detail: DetailResult,
        pr_pipelines: PrPipelinesResult,
        approve: ApproveResult,
        readiness: ReadinessResult,
        values: ValuesResult,
        pr_changed: PrChangedResult,
    };

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

/// How far the running job is; the main loop paints it.
pub const Progress = struct {
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
    /// Requests the client has sent, for the diagnostics.
    busy: std.atomic.Value(bool) = .init(false),

    pub fn set(p: *Progress, done: u32, total: u32) void {
        p.done.store(done, .release);
        p.total.store(total, .release);
    }
};

/// The worker's own state: the account and the scope it resolved,
/// so a chain of jobs (whoami, then three tabs) needs no round trip
/// through the app between them.
pub const Worker = struct {
    gpa: Allocator,
    io: Io,
    client: *api.Client,
    progress: *Progress,
    me_account_id: []u8 = &.{},
    me_display_name: []u8 = &.{},
    /// A configured `account_id` wins over whoami.
    configured_account_id: []const u8 = "",
    /// The default workspace slug. Only the access-token whoami stand-in
    /// reads it — `/2.0/workspaces/<slug>` is what that token can answer.
    workspace: []const u8 = "",
    /// Hands `--values` the second figure: review threads still waiting
    /// on someone. Null leaves it uncounted — the pane does not want a
    /// comments request per pull request on every refresh, only the
    /// statusline run does. The caller owns it.
    review_cache: ?*review_cache.Cache = null,
    /// The `--values` poll's link range table: every pull request the
    /// listing returns widens it, and each repo's pipelines are asked
    /// for when `link_ranges.pipeline_probe_secs` has passed.
    link_ranges: ?*link_ranges.Table = null,
    scope_gen: ?u32 = null,
    scope_arena: ?std.heap.ArenaAllocator = null,
    scope_repos: []const []const u8 = &.{},
    /// A scope failure's text lives as long as the worker's last
    /// failure — the result copies it.
    failure_buf: [512]u8 = undefined,

    pub fn init(gpa: Allocator, io: Io, client: *api.Client, progress: *Progress, configured_account_id: []const u8, workspace: []const u8) Worker {
        return .{ .gpa = gpa, .io = io, .client = client, .progress = progress, .configured_account_id = configured_account_id, .workspace = workspace };
    }

    pub fn deinit(w: *Worker) void {
        w.gpa.free(w.me_account_id);
        w.gpa.free(w.me_display_name);
        if (w.scope_arena) |*a| a.deinit();
        w.* = undefined;
    }

    pub fn accountId(w: *const Worker) []const u8 {
        return if (w.configured_account_id.len > 0) w.configured_account_id else w.me_account_id;
    }

    /// Run one job to its result.
    pub fn run(w: *Worker, job: *Job) Allocator.Error!Result {
        w.progress.busy.store(true, .release);
        defer w.progress.busy.store(false, .release);
        var arena = std.heap.ArenaAllocator.init(w.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        // Every request this job makes is written down under this
        // reason — a job is a reason, so it is set once, here.
        w.client.reason = job.reasonOf();
        // `R` asks outright; everything else lets a held tag make the ask
        // cheap.
        w.client.conditional = !job.full;
        const payload: Result.Payload = switch (job.kind) {
            .whoami => .{ .whoami = try w.whoami(a) },
            .refresh => |r| blk: {
                // Everything the refresh reads, folded into one digest,
                // and whether the shared bucket skipped any of it.
                var h = std.hash.Wyhash.init(0);
                w.client.digest = &h;
                defer w.client.digest = null;
                const refused_before = w.refusedCount();
                var res = try w.refresh(a, r.tab, r.spec, r.scope, job.now_secs);
                res.digest = h.final();
                res.refused = w.refusedCount() != refused_before;
                break :blk .{ .refresh = res };
            },
            .pr_changed => |c| .{ .pr_changed = try w.prChanged(a, c.tab, c.key) },
            .detail => |k| .{ .detail = try w.detail(a, k) },
            .pr_pipelines => |p| .{ .pr_pipelines = try w.prPipelines(a, p.tab, p.workspace, p.slug, p.id, p.hash, p.updated_on) },
            .approve => |ap| .{ .approve = try w.approve(a, ap.key, ap.withdraw) },
            .readiness => |r| .{ .readiness = try w.readiness(a, r.tab, r.key, r.updated_on, r.source_commit, r.required, r.known_build) },
            .values => |v| .{ .values = try w.values(a, v.scope, v.stale_after_days, v.excluded_branch_patterns, job.now_secs) },
        };
        return .{ .arena = arena, .payload = payload };
    }

    // ─── the account ─────────────────────────────────────────────────

    fn whoami(w: *Worker, a: Allocator) Allocator.Error!Whoami {
        // An access token belongs to a repository, a project or a
        // workspace, so `/2.0/user` 401s for it however good it is.
        // Ask the workspace instead: it proves the token reaches
        // Bitbucket, which is all `--check` needs to say.
        if (w.client.read_kind == .access_token) return w.workspaceProbe(a);
        var reply = try w.client.whoami(w.gpa);
        defer reply.deinit(w.gpa);
        switch (reply) {
            .ok => |body| {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return .{ .error_text = "whoami: the reply is not JSON" };
                const id = j.str(v, "account_id");
                const name = j.str(v, "display_name");
                w.gpa.free(w.me_account_id);
                w.me_account_id = try w.gpa.dupe(u8, id);
                w.gpa.free(w.me_display_name);
                w.me_display_name = try w.gpa.dupe(u8, name);
                return .{ .account_id = try a.dupe(u8, id), .display_name = try a.dupe(u8, name) };
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                return .{ .error_text = try std.fmt.allocPrint(a, "whoami failed: {s}", .{f.describe(&buf)}) };
            },
        }
    }

    /// The access-token stand-in for `whoami`: `GET /2.0/workspaces/
    /// <slug>`. It answers with the workspace, never an account, so
    /// `account_id` stays empty on purpose.
    fn workspaceProbe(w: *Worker, a: Allocator) Allocator.Error!Whoami {
        if (w.workspace.len == 0) {
            return .{ .via = .workspace, .error_text = "this is an access token, which has no account — set `workspace` in config.zon so the token can be checked against it" };
        }
        var reply = try w.client.workspaceProbe(w.gpa, w.workspace);
        defer reply.deinit(w.gpa);
        switch (reply) {
            .ok => |body| {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return .{ .via = .workspace, .error_text = "the workspace probe's reply is not JSON" };
                const name = j.str(v, "name");
                const slug = j.str(v, "slug");
                const shown = if (name.len > 0) name else if (slug.len > 0) slug else w.workspace;
                return .{ .via = .workspace, .display_name = try a.dupe(u8, shown) };
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                return .{ .via = .workspace, .error_text = try std.fmt.allocPrint(a, "workspace {s} failed: {s}", .{ w.workspace, f.describe(&buf) }) };
            },
        }
    }

    // ─── the scope ───────────────────────────────────────────────────

    /// The repos a workspace tab reads: `repos` when set, else the
    /// explicit list, else the workspace's repos filtered to the
    /// recent window (or all of them), minus the hidden, ordered by
    /// `repo_order` first. Cached per generation.
    pub fn resolveScope(w: *Worker, s: ScopeInputs, now_secs: i64) Allocator.Error!union(enum) { ok: []const []const u8, failed: []const u8 } {
        if (w.scope_gen == s.generation) return .{ .ok = w.scope_repos };
        var arena = std.heap.ArenaAllocator.init(w.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var raw: std.ArrayList([]const u8) = .empty;
        if (s.repos.len > 0) {
            for (s.repos) |r| try raw.append(a, try a.dupe(u8, r));
        } else if (s.scope == .explicit) {
            for (s.explicit_repos) |r| try raw.append(a, try a.dupe(u8, r));
        } else {
            var reply = try w.client.listReposWithActivity(w.gpa, s.workspace);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch {
                        arena.deinit();
                        return .{ .failed = "the repo list is not JSON" };
                    };
                    const cutoff = now_secs - @as(i64, s.recent_window_days) * 86_400;
                    for (try model.parseRepos(a, v)) |r| {
                        if (s.scope == .recent) {
                            const ts = dates.parseEpoch(r.updated_on) orelse continue;
                            if (ts < cutoff) continue;
                        }
                        try raw.append(a, r.slug);
                    }
                },
                .failed => |f| {
                    var buf: [256]u8 = undefined;
                    const why = try w.gpa.dupe(u8, f.describe(&buf));
                    arena.deinit();
                    // Leaked on purpose? No — hand it to the caller's arena.
                    defer w.gpa.free(why);
                    return .{ .failed = try w.failedText(why) };
                },
            }
        }
        var after_hide: std.ArrayList([]const u8) = .empty;
        for (raw.items) |slug| if (!cfg.contains(s.hidden_repos, slug)) try after_hide.append(a, slug);
        var ordered: std.ArrayList([]const u8) = .empty;
        for (s.repo_order) |slug| if (cfg.contains(after_hide.items, slug)) try ordered.append(a, try a.dupe(u8, slug));
        for (after_hide.items) |slug| if (!cfg.contains(s.repo_order, slug)) try ordered.append(a, slug);
        if (w.scope_arena) |*old| old.deinit();
        w.scope_arena = arena;
        w.scope_repos = try ordered.toOwnedSlice(a);
        w.scope_gen = s.generation;
        return .{ .ok = w.scope_repos };
    }

    fn failedText(w: *Worker, why: []const u8) Allocator.Error![]const u8 {
        const n = @min(why.len, w.failure_buf.len);
        @memcpy(w.failure_buf[0..n], why[0..n]);
        return w.failure_buf[0..n];
    }

    // ─── the tabs ────────────────────────────────────────────────────

    fn refresh(w: *Worker, a: Allocator, tab: usize, spec: tabs.TabSpec, scope: ScopeInputs, now_secs: i64) Allocator.Error!RefreshResult {
        w.progress.set(0, 0);
        switch (spec.kind) {
            .pull_requests => return w.flatPrs(a, tab, spec, scope),
            .pipelines => {
                var reply = try w.client.listPipelines(w.gpa, spec.workspace, spec.repo, 50);
                defer reply.deinit(w.gpa);
                return switch (reply) {
                    .ok => |body| blk: {
                        const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch break :blk failed(a, tab, spec.name, "the reply is not JSON");
                        const list = try model.parsePipelines(a, v);
                        break :blk .{ .tab = tab, .data = .{ .pipelines = list }, .items = list.len, .status = try std.fmt.allocPrint(a, "{s} · {d} {s}", .{ spec.name, list.len, sdk.pane.text.noun(list.len, "pipeline", "pipelines") }) };
                    },
                    .failed => |f| blk: {
                        var buf: [256]u8 = undefined;
                        break :blk failed(a, tab, spec.name, f.describe(&buf));
                    },
                };
            },
            .branches => {
                var reply = try w.client.listBranches(w.gpa, spec.workspace, spec.repo, 50);
                defer reply.deinit(w.gpa);
                return switch (reply) {
                    .ok => |body| blk: {
                        const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch break :blk failed(a, tab, spec.name, "the reply is not JSON");
                        const list = try model.parseBranches(a, v);
                        break :blk .{ .tab = tab, .data = .{ .branches = list }, .items = list.len, .status = try std.fmt.allocPrint(a, "{s} · {d} {s}", .{ spec.name, list.len, sdk.pane.text.noun(list.len, "branch", "branches") }) };
                    },
                    .failed => |f| blk: {
                        var buf: [256]u8 = undefined;
                        break :blk failed(a, tab, spec.name, f.describe(&buf));
                    },
                };
            },
            .workspace_open_prs, .workspace_merged_prs => {
                const repos = switch (try w.resolveScope(scope, now_secs)) {
                    .ok => |r| r,
                    .failed => |why| return failed(a, tab, spec.name, try std.fmt.allocPrint(a, "scope-resolve error: {s}", .{why})),
                };
                // The states are the Status chip's, not the kind's: an
                // Open tab whose chip gained Merged asks for both in the
                // one request, which is the one fetch that chip costs.
                var sbuf: [3][]const u8 = undefined;
                const api_states = spec.apiStates();
                const states = api_states.list(&sbuf);
                var bbql: []const u8 = "";
                var per_page: u32 = 25;
                if (spec.mine_only) {
                    const me = w.accountId();
                    if (me.len > 0) {
                        // The mine-only ask has always peeked at the
                        // account's merged pull requests beside its open
                        // ones; the chip's own states join that.
                        var want = api_states;
                        want.open = true;
                        want.merged = true;
                        var mbuf: [3][]const u8 = undefined;
                        bbql = try std.fmt.allocPrint(a, "({s}) AND author.account_id = \"{s}\"", .{ try stateClause(a, want.list(&mbuf)), me });
                        per_page = 20;
                    }
                }
                // An empty open repo shows its last merge inline — unless
                // merged rows are being fetched anyway.
                const fallback_merged = spec.kind == .workspace_open_prs and !api_states.merged;
                var rows = try w.prsByRepo(a, spec.workspace, repos, states, bbql, per_page, fallback_merged);
                if (spec.mine_only) {
                    var kept: std.ArrayList(model.RepoPrs) = .empty;
                    for (rows) |r| if (r.prs.len > 0 or r.error_label.len > 0) try kept.append(a, r);
                    rows = try kept.toOwnedSlice(a);
                }
                var total: usize = 0;
                var errored: usize = 0;
                for (rows) |r| {
                    total += r.prs.len;
                    errored += @intFromBool(r.error_label.len > 0);
                }
                const status = if (errored > 0)
                    try std.fmt.allocPrint(a, "{s} · {d} {s}, {d} {s} ({d} errored)", .{ spec.name, rows.len, sdk.pane.text.noun(rows.len, "repo", "repos"), total, sdk.pane.text.noun(total, "PR", "PRs"), errored })
                else
                    try std.fmt.allocPrint(a, "{s} · {d} {s}, {d} {s}", .{ spec.name, rows.len, sdk.pane.text.noun(rows.len, "repo", "repos"), total, sdk.pane.text.noun(total, "PR", "PRs") });
                return .{ .tab = tab, .data = .{ .repo_pr_tree = rows }, .repos = rows.len, .items = total, .errored = errored, .status = status, .scope_repos = try dupeList(a, repos), .states = api_states };
            },
            .workspace_pipelines => {
                const repos = switch (try w.resolveScope(scope, now_secs)) {
                    .ok => |r| r,
                    .failed => |why| return failed(a, tab, spec.name, try std.fmt.allocPrint(a, "scope-resolve error: {s}", .{why})),
                };
                const rows = try w.pipelinesTree(a, spec.workspace, repos, now_secs);
                var errored: usize = 0;
                for (rows) |r| errored += @intFromBool(r.error_label.len > 0);
                return .{ .tab = tab, .data = .{ .repo_tree = rows }, .repos = rows.len, .errored = errored, .status = try std.fmt.allocPrint(a, "{s} · {d} {s}", .{ spec.name, rows.len, sdk.pane.text.noun(rows.len, "repo", "repos") }), .scope_repos = try dupeList(a, repos) };
            },
        }
    }

    fn failed(a: Allocator, tab: usize, name: []const u8, why: []const u8) Allocator.Error!RefreshResult {
        return .{ .tab = tab, .error_text = try a.dupe(u8, why), .status = try std.fmt.allocPrint(a, "{s}: {s}", .{ name, why }) };
    }

    /// `state = "OPEN" OR state = "MERGED"` for a BBQL predicate.
    fn stateClause(a: Allocator, states: []const []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (states, 0..) |st, i| {
            if (i > 0) try out.appendSlice(a, " OR ");
            try out.appendSlice(a, try std.fmt.allocPrint(a, "state = \"{s}\"", .{st}));
        }
        return out.toOwnedSlice(a);
    }

    /// A `pull_requests` tab: one repo's list, or `mode = mine` /
    /// `reviewing` fanned out over the workspace's repos.
    fn flatPrs(w: *Worker, a: Allocator, tab: usize, spec: tabs.TabSpec, scope: ScopeInputs) Allocator.Error!RefreshResult {
        // A `pull_requests` tab with no state named lists every state
        // (the API's own `state=` is optional); one with a state, or a
        // Status chip set, lists those.
        var sbuf: [3][]const u8 = undefined;
        const api_states = spec.apiStates();
        const states: []const []const u8 = if (spec.state.len == 0 and spec.states == null) &.{} else api_states.list(&sbuf);
        if (spec.mode == .none) {
            var reply = try w.client.listPrs(w.gpa, spec.workspace, spec.repo, states, spec.q, 50);
            defer reply.deinit(w.gpa);
            return switch (reply) {
                .ok => |body| blk: {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch break :blk failed(a, tab, spec.name, "the reply is not JSON");
                    const list = try model.parsePullRequests(a, v);
                    break :blk .{ .tab = tab, .data = .{ .pull_requests = list }, .items = list.len, .status = try std.fmt.allocPrint(a, "{s} · {d} {s}", .{ spec.name, list.len, sdk.pane.text.noun(list.len, "PR", "PRs") }), .states = api_states };
                },
                .failed => |f| blk: {
                    var buf: [256]u8 = undefined;
                    break :blk failed(a, tab, spec.name, f.describe(&buf));
                },
            };
        }
        const me = w.accountId();
        if (me.len == 0) return failed(a, tab, spec.name, "mode=\"mine\" needs Account:Read on the token (or `account_id` in config.zon)");
        const predicate = if (spec.mode == .mine)
            try std.fmt.allocPrint(a, "author.account_id = \"{s}\"", .{me})
        else
            try std.fmt.allocPrint(a, "reviewers.account_id = \"{s}\"", .{me});
        const bbql = if (spec.q.len > 0) try std.fmt.allocPrint(a, "({s}) AND ({s})", .{ predicate, spec.q }) else predicate;
        // The reference enumerates every repo of the workspace here;
        // the `repos` allow-list is honoured when set.
        var repos: []const []const u8 = scope.repos;
        if (repos.len == 0) {
            var reply = try w.client.listReposWithActivity(w.gpa, spec.workspace);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return failed(a, tab, spec.name, "the repo list is not JSON");
                    var slugs: std.ArrayList([]const u8) = .empty;
                    for (try model.parseRepos(a, v)) |r| try slugs.append(a, r.slug);
                    repos = try slugs.toOwnedSlice(a);
                },
                .failed => |f| {
                    var buf: [256]u8 = undefined;
                    return failed(a, tab, spec.name, f.describe(&buf));
                },
            }
        }
        var all: std.ArrayList(model.PullRequest) = .empty;
        var errors: usize = 0;
        w.progress.set(0, @intCast(repos.len));
        for (repos, 0..) |slug, i| {
            defer w.progress.set(@intCast(i + 1), @intCast(repos.len));
            var reply = try w.client.listPrs(w.gpa, spec.workspace, slug, states, bbql, 50);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch continue;
                    for (try model.parsePullRequests(a, v)) |pr| try all.append(a, pr);
                },
                .failed => errors += 1,
            }
        }
        if (errors > 0 and errors == repos.len) return failed(a, tab, spec.name, try std.fmt.allocPrint(a, "all {d} repo requests failed", .{errors}));
        std.mem.sort(model.PullRequest, all.items, {}, newestFirst);
        const list = try all.toOwnedSlice(a);
        return .{ .tab = tab, .data = .{ .pull_requests = list }, .items = list.len, .errored = errors, .status = try std.fmt.allocPrint(a, "{s} · {d} {s}", .{ spec.name, list.len, sdk.pane.text.noun(list.len, "PR", "PRs") }), .states = api_states };
    }

    fn newestFirst(_: void, x: model.PullRequest, y: model.PullRequest) bool {
        return std.mem.order(u8, x.updated_on, y.updated_on) == .gt;
    }

    /// One `RepoPrs` per slug, in the slugs' order; an erroring repo
    /// keeps its row with a label, an empty open repo shows its last
    /// merge.
    fn prsByRepo(w: *Worker, a: Allocator, workspace: []const u8, repos: []const []const u8, states: []const []const u8, bbql: []const u8, per_page: u32, fallback_merged: bool) Allocator.Error![]model.RepoPrs {
        var rows: std.ArrayList(model.RepoPrs) = .empty;
        w.progress.set(0, @intCast(repos.len));
        for (repos, 0..) |slug, i| {
            defer w.progress.set(@intCast(i + 1), @intCast(repos.len));
            var reply = try w.client.listPrs(w.gpa, workspace, slug, states, bbql, per_page);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch {
                        try rows.append(a, .{ .slug = try a.dupe(u8, slug), .error_label = "bad JSON" });
                        continue;
                    };
                    const prs = try model.parsePullRequests(a, v);
                    std.mem.sort(model.PullRequest, @constCast(prs), {}, newestFirst);
                    var row: model.RepoPrs = .{ .slug = try a.dupe(u8, slug), .prs = prs };
                    if (prs.len == 0 and fallback_merged) {
                        // Best effort, one request, no retry. Under a
                        // BBQL predicate the state clause has to move too.
                        const merged_q = if (bbql.len > 0) try replaceAll(a, bbql, "state = \"OPEN\"", "state = \"MERGED\"") else "";
                        var fb = try w.client.listPrs(w.gpa, workspace, slug, &.{"MERGED"}, merged_q, 1);
                        defer fb.deinit(w.gpa);
                        if (fb == .ok) {
                            if (std.json.parseFromSliceLeaky(j.Value, a, fb.ok.bytes, .{})) |fv| {
                                const one = try model.parsePullRequests(a, fv);
                                if (one.len > 0) row.fallback_merged = one[0];
                            } else |_| {}
                        }
                    }
                    try rows.append(a, row);
                },
                .failed => |f| {
                    var buf: [96]u8 = undefined;
                    try rows.append(a, .{ .slug = try a.dupe(u8, slug), .error_label = try a.dupe(u8, f.shortLabel(&buf)) });
                },
            }
        }
        return rows.toOwnedSlice(a);
    }

    /// Each repo's branches paired with the newest pipeline on each,
    /// curated, repos sorted by their newest pipeline.
    fn pipelinesTree(w: *Worker, a: Allocator, workspace: []const u8, repos: []const []const u8, now_secs: i64) Allocator.Error![]model.RepoPipelines {
        var rows: std.ArrayList(model.RepoPipelines) = .empty;
        w.progress.set(0, @intCast(repos.len));
        for (repos, 0..) |slug, i| {
            defer w.progress.set(@intCast(i + 1), @intCast(repos.len));
            var branches: []const model.BranchRef = &.{};
            var pipelines: []const model.Pipeline = &.{};
            var label: []const u8 = "";
            {
                var reply = try w.client.listBranches(w.gpa, workspace, slug, 100);
                defer reply.deinit(w.gpa);
                switch (reply) {
                    .ok => |body| if (std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{})) |v| {
                        branches = try model.parseBranches(a, v);
                    } else |_| {},
                    .failed => |f| {
                        var buf: [96]u8 = undefined;
                        label = try a.dupe(u8, f.shortLabel(&buf));
                    },
                }
            }
            {
                var reply = try w.client.listPipelines(w.gpa, workspace, slug, 100);
                defer reply.deinit(w.gpa);
                if (reply == .ok) if (std.json.parseFromSliceLeaky(j.Value, a, reply.ok.bytes, .{})) |v| {
                    pipelines = try model.parsePipelines(a, v);
                } else |_| {};
            }
            var paired: std.ArrayList(model.BranchWithPipeline) = .empty;
            for (branches) |b| {
                var latest: ?model.Pipeline = null;
                for (pipelines) |p| if (std.mem.eql(u8, p.ref_name, b.name)) {
                    latest = p;
                    break;
                };
                try paired.append(a, .{
                    .name = b.name,
                    .latest = latest,
                    .last_activity_on = if (latest) |p| (if (p.created_on.len > 0) p.created_on else b.date) else b.date,
                });
            }
            try rows.append(a, .{ .slug = try a.dupe(u8, slug), .branches = try model.curateBranches(a, now_secs, paired.items), .error_label = label });
        }
        std.mem.sort(model.RepoPipelines, rows.items, {}, newestPipelineFirst);
        return rows.toOwnedSlice(a);
    }

    fn newestPipelineFirst(_: void, x: model.RepoPipelines, y: model.RepoPipelines) bool {
        return std.mem.order(u8, x.newestPipeline(), y.newestPipeline()) == .gt;
    }

    fn refusedCount(w: *Worker) u32 {
        return if (w.client.budget) |b| b.refusedCount() else 0;
    }

    /// One pull request, asked for because an event feed named it.
    fn prChanged(w: *Worker, a: Allocator, tab: usize, key: PrKey) Allocator.Error!PrChangedResult {
        const k: PrKey = .{ .workspace = try a.dupe(u8, key.workspace), .repo = try a.dupe(u8, key.repo), .id = key.id };
        var reply = try w.client.prDetail(w.gpa, key.workspace, key.repo, key.id);
        defer reply.deinit(w.gpa);
        switch (reply) {
            .ok => |body| {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return .{ .tab = tab, .key = k, .error_text = "the pull request is not JSON" };
                return .{ .tab = tab, .key = k, .pr = try model.parsePullRequest(a, v) };
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                return .{ .tab = tab, .key = k, .error_text = try std.fmt.allocPrint(a, "{s}#{d}: {s}", .{ key.repo, key.id, f.describe(&buf) }), .refused = sdk.budget.isBucketRefusal(f.message) };
            },
        }
    }

    // ─── the detail, the merged PR's pipeline, approve ───────────────

    fn detail(w: *Worker, a: Allocator, key: PrKey) Allocator.Error!DetailResult {
        const k: PrKey = .{ .workspace = try a.dupe(u8, key.workspace), .repo = try a.dupe(u8, key.repo), .id = key.id };
        var reply = try w.client.prDetail(w.gpa, key.workspace, key.repo, key.id);
        defer reply.deinit(w.gpa);
        const pr = switch (reply) {
            .ok => |body| blk: {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return .{ .key = k, .error_text = "the detail is not JSON" };
                break :blk try model.parsePullRequest(a, v);
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                return .{ .key = k, .error_text = try std.fmt.allocPrint(a, "detail fetch failed: {s}", .{f.describe(&buf)}) };
            },
        };
        var comments: []const model.Comment = &.{};
        var creply = try w.client.prComments(w.gpa, key.workspace, key.repo, key.id);
        defer creply.deinit(w.gpa);
        if (creply == .ok) if (std.json.parseFromSliceLeaky(j.Value, a, creply.ok.bytes, .{})) |v| {
            comments = try model.parseComments(a, v);
        } else |_| {};
        return .{ .key = k, .pr = pr, .comments = comments };
    }

    fn prPipelines(w: *Worker, a: Allocator, tab: usize, workspace: []const u8, slug: []const u8, id: i64, hash: []const u8, updated_on: []const u8) Allocator.Error!PrPipelinesResult {
        const out: PrPipelinesResult = .{ .tab = tab, .slug = try a.dupe(u8, slug), .id = id, .updated_on = try a.dupe(u8, updated_on) };
        var reply = try w.client.listPipelines(w.gpa, workspace, slug, 60);
        defer reply.deinit(w.gpa);
        switch (reply) {
            .ok => |body| {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return out;
                const all = try model.parsePipelines(a, v);
                var r = out;
                r.pipelines = try model.pipelinesOnCommit(a, all, hash);
                return r;
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                var r = out;
                r.error_text = try std.fmt.allocPrint(a, "pipeline fetch failed: {s}", .{f.describe(&buf)});
                return r;
            },
        }
    }

    fn approve(w: *Worker, a: Allocator, key: PrKey, withdraw: bool) Allocator.Error!ApproveResult {
        const k: PrKey = .{ .workspace = try a.dupe(u8, key.workspace), .repo = try a.dupe(u8, key.repo), .id = key.id };
        var reply = if (withdraw) try w.client.unapprove(w.gpa, key.workspace, key.repo, key.id) else try w.client.approve(w.gpa, key.workspace, key.repo, key.id);
        defer reply.deinit(w.gpa);
        return switch (reply) {
            .ok => .{ .key = k, .withdrew = withdraw },
            .failed => |f| blk: {
                var buf: [256]u8 = undefined;
                break :blk .{ .key = k, .withdrew = withdraw, .error_text = try std.fmt.allocPrint(a, "approval toggle failed: {s}", .{f.describe(&buf)}) };
            },
        };
    }

    // ─── may it merge? ───────────────────────────────────────────────

    /// The five conditions, in one cached look: the pull request's own
    /// detail (approvals, open tasks), its diffstat (a 555 is a
    /// conflict), its comments (through the review cache, so a pull
    /// request that has not moved costs nothing), and — only when the
    /// caller has no fresh runs of its own — the pipelines list.
    ///
    /// Never called from `--values`: the statusline run counts, it does
    /// not judge, and readiness would multiply its request budget by
    /// the number of open pull requests.
    fn readiness(w: *Worker, a: Allocator, tab: usize, key: PrKey, updated_on: []const u8, source_commit: []const u8, required: usize, known_build: ?bool) Allocator.Error!ReadinessResult {
        const k: PrKey = .{ .workspace = try a.dupe(u8, key.workspace), .repo = try a.dupe(u8, key.repo), .id = key.id };
        var out: ReadinessResult = .{ .tab = tab, .key = k, .updated_on = try a.dupe(u8, updated_on) };
        var r: merge.Readiness = .{ .required = @max(required, 1), .checked = true };

        var reply = try w.client.prDetail(w.gpa, key.workspace, key.repo, key.id);
        defer reply.deinit(w.gpa);
        switch (reply) {
            .ok => |body| {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch {
                    out.error_text = "the detail is not JSON";
                    return out;
                };
                const pr = try model.parsePullRequest(a, v);
                r.approvals = pr.approvalCount();
                for (pr.participants) |p| if (std.ascii.eqlIgnoreCase(p.state, "changes_requested")) {
                    r.changes_requested = true;
                };
                r.open_tasks = @intCast(@max(j.int(v, "task_count", 0), 0));
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                out.error_text = try std.fmt.allocPrint(a, "readiness: {s}", .{f.describe(&buf)});
                return out;
            },
        }

        // The diffstat's STATUS is the answer; its body is not read.
        var dreply = try w.client.prDiffstat(w.gpa, key.workspace, key.repo, key.id);
        defer dreply.deinit(w.gpa);
        r.conflicts = dreply != .ok;

        // The comments, through the same cache the statusline figure
        // uses: a pull request that has not moved costs no request.
        var counted = false;
        if (w.review_cache) |rc| {
            const ck = try rc.key(key.workspace, key.repo, key.id);
            if (rc.get(ck, updated_on)) |n| {
                r.unanswered_comments = n;
                counted = true;
            }
        }
        if (!counted) {
            var creply = try w.client.prComments(w.gpa, key.workspace, key.repo, key.id);
            defer creply.deinit(w.gpa);
            if (creply == .ok) {
                if (std.json.parseFromSliceLeaky(j.Value, a, creply.ok.bytes, .{})) |v| {
                    const n = model.unresolvedThreads(try model.parseComments(a, v));
                    r.unanswered_comments = n;
                    if (w.review_cache) |rc| try rc.put(try rc.key(key.workspace, key.repo, key.id), updated_on, n);
                } else |_| {}
            } else {
                // A comments request that failed is not "no comments":
                // say so rather than calling the pull request ready.
                out.error_text = "readiness: the comments could not be read";
                r.unanswered_comments = 1;
            }
        }

        if (known_build) |green| {
            r.build_green = green;
        } else {
            var preply = try w.client.listPipelines(w.gpa, key.workspace, key.repo, 60);
            defer preply.deinit(w.gpa);
            if (preply == .ok) {
                if (std.json.parseFromSliceLeaky(j.Value, a, preply.ok.bytes, .{})) |v| {
                    const on = try model.pipelinesOnCommit(a, try model.parsePipelines(a, v), source_commit);
                    r.build_green = on.len > 0 and std.ascii.eqlIgnoreCase(on[0].stateLabel(), "SUCCESSFUL");
                } else |_| {}
            }
        }
        out.readiness = r;
        return out;
    }

    // ─── the statusline values ───────────────────────────────────────

    /// Each repo's newest pipelines, for the link range table — only a
    /// repo whose numbers are older than `pipeline_probe_secs`, so the
    /// poll pays one request per repo an hour, not one per poll. A
    /// failed answer is left for the next poll.
    fn probePipelines(w: *Worker, a: Allocator, lr: *link_ranges.Table, workspace: []const u8, repos: []const []const u8, now_secs: i64) Allocator.Error!void {
        for (repos) |slug| {
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ workspace, slug });
            if (!lr.due(full, "pipeline", now_secs, link_ranges.pipeline_probe_secs)) continue;
            var reply = try w.client.listPipelines(w.gpa, workspace, slug, 10);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch continue;
                    for (try model.parsePipelines(a, v)) |p| try lr.observe(full, "pipeline", @intCast(@max(p.build_number, 0)));
                    try lr.probed(full, "pipeline", now_secs);
                },
                .failed => {},
            }
        }
    }

    /// The reference's `--values`: OPEN PRs the account authored, updated
    /// in the last `stale_after_days`, not on an excluded branch, across
    /// `repos` (or every repo of the workspace); how many, and how many
    /// have no approval yet.
    fn values(w: *Worker, a: Allocator, scope: ScopeInputs, stale_after_days: u32, patterns: []const []const u8, now_secs: i64) Allocator.Error!ValuesResult {
        if (w.accountId().len == 0) {
            const me = try w.whoami(a);
            if (me.error_text.len > 0) return .{ .error_text = me.error_text };
        }
        const me = w.accountId();
        if (me.len == 0) return .{
            .error_text = if (w.client.read_kind == .access_token)
                "an access token has no account: set `account_id` in config.zon so --values knows whose pull requests to count"
            else
                "/2.0/user returned no account_id",
        };
        // One predicate for both sets: the pull requests the account
        // authored AND the ones it is a reviewer on. Asking separately
        // would double the requests for a figure that is already in the
        // payload.
        var q: Io.Writer.Allocating = .init(a);
        q.writer.print("state = \"OPEN\" AND (author.account_id = \"{s}\" OR reviewers.account_id = \"{s}\")", .{ me, me }) catch return error.OutOfMemory;
        if (stale_after_days > 0) {
            var buf: [10]u8 = undefined;
            q.writer.print(" AND updated_on >= {s}", .{dates.writeDate(&buf, now_secs - @as(i64, stale_after_days) * 86_400)}) catch return error.OutOfMemory;
        }
        var repos: []const []const u8 = scope.repos;
        if (repos.len == 0) {
            var reply = try w.client.listReposWithActivity(w.gpa, scope.workspace);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch return .{ .error_text = "the repo list is not JSON" };
                    var slugs: std.ArrayList([]const u8) = .empty;
                    for (try model.parseRepos(a, v)) |r| try slugs.append(a, r.slug);
                    repos = try slugs.toOwnedSlice(a);
                },
                .failed => |f| {
                    var buf: [256]u8 = undefined;
                    return .{ .error_text = try std.fmt.allocPrint(a, "counting open PRs authored by you: {s}", .{f.describe(&buf)}) };
                },
            }
        }
        var open: usize = 0;
        var approved: usize = 0;
        var failures: usize = 0;
        // The pull requests kept, so the comment pass can walk them
        // without a second listing.
        const Mine = struct { repo: []const u8, id: i64, updated_on: []const u8, title: []const u8 };
        var mine: std.ArrayList(Mine) = .empty;
        var open_items: std.ArrayList(ValuesItem) = .empty;
        var awaiting_items: std.ArrayList(ValuesItem) = .empty;
        var awaiting: usize = 0;
        w.progress.set(0, @intCast(repos.len));
        for (repos, 0..) |slug, i| {
            defer w.progress.set(@intCast(i + 1), @intCast(repos.len));
            var reply = try w.client.listPrs(w.gpa, scope.workspace, slug, &.{"OPEN"}, q.written(), 50);
            defer reply.deinit(w.gpa);
            switch (reply) {
                .ok => |body| {
                    const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch continue;
                    for (try model.parsePullRequests(a, v)) |pr| {
                        if (w.link_ranges) |lr| try lr.observe(try std.fmt.allocPrint(a, "{s}/{s}", .{ scope.workspace, slug }), "pr", @intCast(@max(pr.id, 0)));
                        var excluded = false;
                        for (patterns) |p| if (model.branchMatches(p, pr.source_branch)) {
                            excluded = true;
                        };
                        if (excluded) continue;
                        // The one listing carries both sets; which
                        // figure a row belongs to is the author's id.
                        if (std.mem.eql(u8, pr.author_id, me)) {
                            open += 1;
                            approved += @intFromBool(pr.approvalCount() > 0);
                            if (open_items.items.len < hover_items) try open_items.append(a, .{
                                .text = pr.title,
                                .sub = try std.fmt.allocPrint(a, "{s}/{s} · {s}", .{ scope.workspace, slug, if (pr.approvalCount() > 0) "approved" else "unapproved" }),
                                .key = try std.fmt.allocPrint(a, "{s}#{d}", .{ slug, pr.id }),
                            });
                            try mine.append(a, .{ .repo = slug, .id = pr.id, .updated_on = pr.updated_on, .title = pr.title });
                        } else if (pr.awaitingApproval(me)) {
                            awaiting += 1;
                            if (awaiting_items.items.len < hover_items) try awaiting_items.append(a, .{
                                .text = pr.title,
                                .sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ scope.workspace, slug }),
                                .key = try std.fmt.allocPrint(a, "{s}#{d}", .{ slug, pr.id }),
                            });
                        }
                    }
                },
                .failed => failures += 1,
            }
        }
        if (failures > 0 and failures == repos.len) return .{ .error_text = try std.fmt.allocPrint(a, "all {d} repo requests failed", .{failures}) };
        if (w.link_ranges) |lr| try w.probePipelines(a, lr, scope.workspace, repos, now_secs);
        var out: ValuesResult = .{
            .open_mine = open,
            .unapproved_mine = open - approved,
            .approved_mine = approved,
            .reviews_pending = awaiting,
            .open_items = try open_items.toOwnedSlice(a),
            .awaiting_items = try awaiting_items.toOwnedSlice(a),
        };
        // The second figure, when a cache was handed over to pay for it.
        if (w.review_cache) |rc| {
            var unresolved: usize = 0;
            var counted: usize = 0;
            var live: std.ArrayList([]const u8) = .empty;
            var comment_items: std.ArrayList(ValuesItem) = .empty;
            for (mine.items) |m| {
                const k = try rc.key(scope.workspace, m.repo, m.id);
                try live.append(a, k);
                if (rc.get(k, m.updated_on)) |n| {
                    unresolved += n;
                    counted += 1;
                    if (n > 0 and comment_items.items.len < hover_items) try comment_items.append(a, .{
                        .text = m.title,
                        .sub = try std.fmt.allocPrint(a, "{s}/{s} · {d} waiting", .{ scope.workspace, m.repo, n }),
                        .key = try std.fmt.allocPrint(a, "{s}#{d}", .{ m.repo, m.id }),
                    });
                    continue;
                }
                var reply = try w.client.prComments(w.gpa, scope.workspace, m.repo, m.id);
                defer reply.deinit(w.gpa);
                switch (reply) {
                    .ok => |body| {
                        const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch continue;
                        const n = model.unresolvedThreads(try model.parseComments(a, v));
                        unresolved += n;
                        counted += 1;
                        if (n > 0 and comment_items.items.len < hover_items) try comment_items.append(a, .{
                            .text = m.title,
                            .sub = try std.fmt.allocPrint(a, "{s}/{s} · {d} waiting", .{ scope.workspace, m.repo, n }),
                            .key = try std.fmt.allocPrint(a, "{s}#{d}", .{ m.repo, m.id }),
                        });
                        try rc.put(k, m.updated_on, n);
                    },
                    // One repo's comments failing is not a reason to
                    // drop the whole figure; every one failing is.
                    .failed => {},
                }
            }
            rc.save(w.io, live.items);
            out.comment_items = try comment_items.toOwnedSlice(a);
            out.comment_hits = rc.hits;
            out.comment_requests = rc.misses;
            if (mine.items.len == 0 or counted > 0) out.unresolved_comments = unresolved;
        }
        return out;
    }
};

fn dupeList(a: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

fn replaceAll(a: Allocator, s: []const u8, needle: []const u8, with: []const u8) Allocator.Error![]const u8 {
    const n = std.mem.replacementSize(u8, s, needle, with);
    const out = try a.alloc(u8, n);
    _ = std.mem.replace(u8, s, needle, with, out);
    return out;
}

/// A job with its inputs copied onto its own arena.
pub fn makeJob(gpa: Allocator, now_secs: i64, kind: Job.Kind) Allocator.Error!Job {
    return makeJobFor(gpa, now_secs, kind, null);
}

/// The same, with the reason the caller wants the log to record.
pub fn makeJobFor(gpa: Allocator, now_secs: i64, kind: Job.Kind, reason: ?api.Reason) Allocator.Error!Job {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const copied: Job.Kind = switch (kind) {
        .whoami => .whoami,
        .refresh => |r| .{ .refresh = .{ .tab = r.tab, .spec = try dupeSpec(a, r.spec), .scope = try dupeScope(a, r.scope) } },
        .detail => |k| .{ .detail = try dupeKey(a, k) },
        .pr_pipelines => |p| .{ .pr_pipelines = .{ .tab = p.tab, .workspace = try a.dupe(u8, p.workspace), .slug = try a.dupe(u8, p.slug), .id = p.id, .hash = try a.dupe(u8, p.hash), .updated_on = try a.dupe(u8, p.updated_on) } },
        .approve => |ap| .{ .approve = .{ .key = try dupeKey(a, ap.key), .withdraw = ap.withdraw } },
        .readiness => |r| .{ .readiness = .{
            .tab = r.tab,
            .key = try dupeKey(a, r.key),
            .updated_on = try a.dupe(u8, r.updated_on),
            .source_commit = try a.dupe(u8, r.source_commit),
            .required = r.required,
            .known_build = r.known_build,
        } },
        .values => |v| .{ .values = .{ .scope = try dupeScope(a, v.scope), .stale_after_days = v.stale_after_days, .excluded_branch_patterns = try dupeList(a, v.excluded_branch_patterns) } },
        .pr_changed => |c| .{ .pr_changed = .{ .tab = c.tab, .key = try dupeKey(a, c.key) } },
    };
    return .{ .arena = arena, .kind = copied, .now_secs = now_secs, .reason = reason };
}

fn dupeKey(a: Allocator, k: PrKey) Allocator.Error!PrKey {
    return .{ .workspace = try a.dupe(u8, k.workspace), .repo = try a.dupe(u8, k.repo), .id = k.id };
}

fn dupeSpec(a: Allocator, s: tabs.TabSpec) Allocator.Error!tabs.TabSpec {
    var out = s;
    out.name = try a.dupe(u8, s.name);
    out.workspace = try a.dupe(u8, s.workspace);
    out.repo = try a.dupe(u8, s.repo);
    out.state = try a.dupe(u8, s.state);
    out.q = try a.dupe(u8, s.q);
    return out;
}

fn dupeScope(a: Allocator, s: ScopeInputs) Allocator.Error!ScopeInputs {
    var out = s;
    out.workspace = try a.dupe(u8, s.workspace);
    out.explicit_repos = try dupeList(a, s.explicit_repos);
    out.hidden_repos = try dupeList(a, s.hidden_repos);
    out.repo_order = try dupeList(a, s.repo_order);
    out.repos = try dupeList(a, s.repos);
    return out;
}

/// The scope inputs for a config, at a generation.
pub fn scopeOf(c: cfg.Config, workspace: []const u8, generation: u32) ScopeInputs {
    return .{
        .workspace = workspace,
        .scope = c.scope,
        .recent_window_days = c.recent_window_days,
        .explicit_repos = c.explicit_repos,
        .hidden_repos = c.hidden_repos,
        .repo_order = c.repo_order,
        .repos = c.repos,
        .generation = generation,
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const listener = @import("../tools/fake_bitbucket/listener.zig");
const server = @import("../tools/fake_bitbucket/server.zig");

const Rig = struct {
    srv: *listener.Server,
    client: api.Client,
    progress: Progress = .{},
    worker: Worker,

    fn init() !*Rig {
        const r = try t.allocator.create(Rig);
        r.* = .{ .srv = undefined, .client = undefined, .worker = undefined };
        r.srv = try listener.Server.start(t.allocator, t.io, 0);
        const base = try r.srv.baseUrl(t.allocator);
        defer t.allocator.free(base);
        r.client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{});
        r.worker = Worker.init(t.allocator, t.io, &r.client, &r.progress, "", "acme");
        return r;
    }

    fn deinit(r: *Rig) void {
        r.worker.deinit();
        r.client.deinit();
        r.srv.stop();
        t.allocator.destroy(r);
    }

    fn run(r: *Rig, kind: Job.Kind) !Result {
        var job = try makeJob(t.allocator, realNow(), kind);
        defer job.deinit();
        return r.worker.run(&job);
    }
};

fn realNow() i64 {
    return Io.Timestamp.now(t.io, .real).toSeconds();
}

const acme_scope: ScopeInputs = .{ .workspace = "acme", .scope = .recent, .recent_window_days = 14, .explicit_repos = &.{}, .hidden_repos = &.{}, .repo_order = &.{}, .repos = &.{ "api", "web" }, .generation = 1 };

test "the open tree: one row per repo, a 24-hour-old PR still in the data, the merged tree with its merge commits" {
    const r = try Rig.init();
    defer r.deinit();
    var who = try r.run(.whoami);
    defer who.deinit();
    try t.expectEqualStrings("acct-max", who.payload.whoami.account_id);
    try t.expectEqualStrings("acct-max", r.worker.accountId());

    var open = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .workspace_open_prs, .name = "Open + Draft", .workspace = "acme" }, .scope = acme_scope } });
    defer open.deinit();
    const o = open.payload.refresh;
    try t.expectEqualStrings("Open + Draft · 2 repos, 3 PRs", o.status);
    try t.expectEqual(@as(usize, 2), o.data.?.repo_pr_tree.len);
    try t.expectEqualStrings("api", o.data.?.repo_pr_tree[0].slug);
    try t.expectEqual(@as(usize, 2), o.data.?.repo_pr_tree[0].prs.len);
    // Newest first: #1234 (2h) before #1198 (30h).
    try t.expectEqual(@as(i64, 1234), o.data.?.repo_pr_tree[0].prs[0].id);
    try t.expectEqual(@as(u32, 2), r.progress.done.load(.acquire));

    var merged = try r.run(.{ .refresh = .{ .tab = 1, .spec = .{ .kind = .workspace_merged_prs, .name = "Merged", .workspace = "acme" }, .scope = acme_scope } });
    defer merged.deinit();
    const m = merged.payload.refresh;
    try t.expectEqualStrings("Merged · 2 repos, 2 PRs", m.status);
    try t.expectEqualStrings("9999mergecommit", m.data.?.repo_pr_tree[0].prs[0].merge_commit);
    // The scope was resolved once and cached for the second tab.
    try t.expectEqual(@as(?u32, 1), r.worker.scope_gen);
}

test "the open tree off a server that gzips every answer: the same rows as plain" {
    const r = try Rig.init();
    defer r.deinit();
    r.srv.gzipAnswers(.always);
    var who = try r.run(.whoami);
    defer who.deinit();
    try t.expectEqualStrings("acct-max", who.payload.whoami.account_id);

    var open = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .workspace_open_prs, .name = "Open + Draft", .workspace = "acme" }, .scope = acme_scope } });
    defer open.deinit();
    const o = open.payload.refresh;
    try t.expectEqualStrings("Open + Draft · 2 repos, 3 PRs", o.status);
    try t.expectEqual(@as(usize, 2), o.data.?.repo_pr_tree.len);
    try t.expectEqualStrings("api", o.data.?.repo_pr_tree[0].slug);
    try t.expectEqual(@as(usize, 2), o.data.?.repo_pr_tree[0].prs.len);
    try t.expectEqual(@as(i64, 1234), o.data.?.repo_pr_tree[0].prs[0].id);
    // The answers really went out compressed.
    try t.expect(r.srv.snapshot().gzipped >= 3);
}

test "an unknown repo keeps its row with a label, and a mine-only tree drops the repos with nothing" {
    const r = try Rig.init();
    defer r.deinit();
    const scope: ScopeInputs = .{ .workspace = "acme", .scope = .all, .recent_window_days = 14, .explicit_repos = &.{}, .hidden_repos = &.{}, .repo_order = &.{}, .repos = &.{ "api", "ghost" }, .generation = 2 };
    var open = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .workspace_open_prs, .name = "Open", .workspace = "acme" }, .scope = scope } });
    defer open.deinit();
    const rows = open.payload.refresh.data.?.repo_pr_tree;
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("no such repo", rows[1].error_label);
    try t.expectEqualStrings("Open · 2 repos, 2 PRs (1 errored)", open.payload.refresh.status);

    var who = try r.run(.whoami);
    who.deinit();
    var mine = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .workspace_open_prs, .name = "Mine", .workspace = "acme", .mine_only = true }, .scope = acme_scope } });
    defer mine.deinit();
    const mrows = mine.payload.refresh.data.?.repo_pr_tree;
    // api: #1234 open (mine) + #1100 merged (not mine) → only #1234; web: #820 (mine, draft) + #801 merged by Dana → #820.
    try t.expectEqual(@as(usize, 2), mrows.len);
    for (mrows) |row| for (row.prs) |pr| try t.expectEqualStrings("acct-max", pr.author_id);
}

test "the scope: recent filters on updated_on, hidden subtracts, repo_order leads, explicit needs no enumeration" {
    const r = try Rig.init();
    defer r.deinit();
    const now = realNow();
    // No allow-list: api (1 h ago) and web (a day ago) are both recent.
    var all: ScopeInputs = .{ .workspace = "acme", .scope = .recent, .recent_window_days = 14, .explicit_repos = &.{}, .hidden_repos = &.{}, .repo_order = &.{"web"}, .repos = &.{}, .generation = 5 };
    const got = try r.worker.resolveScope(all, now);
    try t.expectEqual(@as(usize, 2), got.ok.len);
    try t.expectEqualStrings("web", got.ok[0]);
    // A day's window drops web (a day old, on the edge) only when the cutoff passes it.
    all.recent_window_days = 0;
    all.generation = 6;
    try t.expectEqual(@as(usize, 0), (try r.worker.resolveScope(all, now)).ok.len);
    all.scope = .explicit;
    all.explicit_repos = &.{ "web", "api" };
    all.hidden_repos = &.{"api"};
    all.generation = 7;
    const ex = try r.worker.resolveScope(all, now);
    try t.expectEqual(@as(usize, 1), ex.ok.len);
    try t.expectEqualStrings("web", ex.ok[0]);
}

test "the pipelines tree pairs branches with their newest run and curates them" {
    const r = try Rig.init();
    defer r.deinit();
    var res = try r.run(.{ .refresh = .{ .tab = 2, .spec = .{ .kind = .workspace_pipelines, .name = "Pipelines", .workspace = "acme" }, .scope = acme_scope } });
    defer res.deinit();
    const rows = res.payload.refresh.data.?.repo_tree;
    try t.expectEqualStrings("Pipelines · 2 repos", res.payload.refresh.status);
    // api has the newer pipeline (1 h) so it sorts first.
    try t.expectEqualStrings("api", rows[0].slug);
    // main, develop, release/1.2 (10 days: kept), and the newest feature (bug/fix-login); dana/timeout (30 h) loses to it; old/experiment (40 days) is stale.
    const names = rows[0].branches;
    try t.expectEqual(@as(usize, 4), names.len);
    try t.expectEqualStrings("main", names[0].name);
    try t.expectEqualStrings("develop", names[1].name);
    try t.expectEqualStrings("release/1.2", names[2].name);
    try t.expectEqualStrings("bug/fix-login", names[3].name);
    try t.expectEqual(@as(i64, 412), names[0].latest.?.build_number);
    try t.expectEqualStrings("FAILED", names[1].latest.?.result_name);
    try t.expectEqual(@as(i64, 413), names[3].latest.?.build_number);
    // web: main, staging, feature/empty-state.
    try t.expectEqual(@as(usize, 3), rows[1].branches.len);
}

test "flat tabs: a repo's list, a mine list across the allow-list, pipelines and branches" {
    const r = try Rig.init();
    defer r.deinit();
    var api_tab = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .pull_requests, .name = "api", .workspace = "acme", .repo = "api", .state = "OPEN" }, .scope = acme_scope } });
    defer api_tab.deinit();
    try t.expectEqual(@as(usize, 2), api_tab.payload.refresh.data.?.pull_requests.len);
    try t.expectEqualStrings("api · 2 PRs", api_tab.payload.refresh.status);
    // Without an account a mine tab explains itself.
    var no_me = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .pull_requests, .name = "Mine", .workspace = "acme", .mode = .mine, .state = "OPEN" }, .scope = acme_scope } });
    defer no_me.deinit();
    try t.expect(std.mem.indexOf(u8, no_me.payload.refresh.error_text, "Account:Read") != null);
    var who = try r.run(.whoami);
    who.deinit();
    var mine = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .pull_requests, .name = "Mine", .workspace = "acme", .mode = .mine, .state = "OPEN" }, .scope = acme_scope } });
    defer mine.deinit();
    try t.expectEqual(@as(usize, 2), mine.payload.refresh.data.?.pull_requests.len);
    var reviewing = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .pull_requests, .name = "Review", .workspace = "acme", .mode = .reviewing, .state = "OPEN" }, .scope = acme_scope } });
    defer reviewing.deinit();
    try t.expectEqual(@as(usize, 1), reviewing.payload.refresh.data.?.pull_requests.len);
    try t.expectEqual(@as(i64, 1198), reviewing.payload.refresh.data.?.pull_requests[0].id);
    var pl = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .pipelines, .name = "builds", .workspace = "acme", .repo = "api" }, .scope = acme_scope } });
    defer pl.deinit();
    try t.expectEqual(@as(usize, 5), pl.payload.refresh.data.?.pipelines.len);
    try t.expectEqualStrings("builds · 5 pipelines", pl.payload.refresh.status);
    var br = try r.run(.{ .refresh = .{ .tab = 0, .spec = .{ .kind = .branches, .name = "heads", .workspace = "acme", .repo = "web" }, .scope = acme_scope } });
    defer br.deinit();
    try t.expectEqual(@as(usize, 3), br.payload.refresh.data.?.branches.len);
}

test "the detail, the merged PR's pipeline, approve and withdraw, and the statusline values" {
    const r = try Rig.init();
    defer r.deinit();
    var d = try r.run(.{ .detail = .{ .workspace = "acme", .repo = "api", .id = 1234 } });
    defer d.deinit();
    try t.expectEqualStrings("Fix the login redirect", d.payload.detail.pr.?.title);
    try t.expectEqual(@as(usize, 1), d.payload.detail.pr.?.approvalCount());
    var gone = try r.run(.{ .detail = .{ .workspace = "acme", .repo = "api", .id = 42 } });
    defer gone.deinit();
    try t.expect(std.mem.indexOf(u8, gone.payload.detail.error_text, "404") != null);

    var pp = try r.run(.{ .pr_pipelines = .{ .tab = 1, .workspace = "acme", .slug = "api", .id = 1100, .hash = "9999mergecommit" } });
    defer pp.deinit();
    try t.expectEqual(@as(usize, 1), pp.payload.pr_pipelines.pipelines.len);
    try t.expectEqual(@as(i64, 412), pp.payload.pr_pipelines.pipelines[0].build_number);

    var ap = try r.run(.{ .approve = .{ .key = .{ .workspace = "acme", .repo = "api", .id = 1198 }, .withdraw = false } });
    defer ap.deinit();
    try t.expectEqualStrings("", ap.payload.approve.error_text);
    try t.expectEqual(server.State.Vote.approved, r.srv.snapshot().voteFor(1198));
    var un = try r.run(.{ .approve = .{ .key = .{ .workspace = "acme", .repo = "api", .id = 1198 }, .withdraw = true } });
    defer un.deinit();
    try t.expect(un.payload.approve.withdrew);
    try t.expectEqual(server.State.Vote.none, r.srv.snapshot().voteFor(1198));

    // Values: my OPEN PRs across api + web — #1234 (Dana approved) and #820 (no reviewers) → 2 open, 1 unapproved.
    var vals = try r.run(.{ .values = .{ .scope = acme_scope, .stale_after_days = 90, .excluded_branch_patterns = &.{ "^release/", "^hotfix/" } } });
    defer vals.deinit();
    try t.expectEqualStrings("", vals.payload.values.error_text);
    try t.expectEqual(@as(usize, 2), vals.payload.values.open_mine);
    try t.expectEqual(@as(usize, 1), vals.payload.values.unapproved_mine);
    // Excluding bug/* and feature/* branches counts nothing.
    var none = try r.run(.{ .values = .{ .scope = acme_scope, .stale_after_days = 0, .excluded_branch_patterns = &.{ "^bug/", "^feature/" } } });
    defer none.deinit();
    try t.expectEqual(@as(usize, 0), none.payload.values.open_mine);
}

test "the review figure: threads waiting on someone, counted once and then answered off the cache" {
    const r = try Rig.init();
    defer r.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const config_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
    defer t.allocator.free(config_path);

    // Without a cache the figure is not asked for at all: the pane does
    // not want a comments request per pull request on every refresh.
    var plain = try r.run(.{ .values = .{ .scope = acme_scope, .stale_after_days = 90, .excluded_branch_patterns = &.{} } });
    defer plain.deinit();
    try t.expect(plain.payload.values.unresolved_comments == null);

    var rc = try review_cache.Cache.open(t.allocator, t.io, config_path);
    defer rc.deinit();
    r.worker.review_cache = &rc;
    // My two open PRs: #1234 has three comments — one unreplied
    // (Dana's), one that Max answered, and that answer — so one
    // thread is waiting. #820 has none.
    var first = try r.run(.{ .values = .{ .scope = acme_scope, .stale_after_days = 90, .excluded_branch_patterns = &.{} } });
    defer first.deinit();
    try t.expectEqual(@as(?usize, 1), first.payload.values.unresolved_comments);
    try t.expectEqual(@as(u32, 0), first.payload.values.comment_hits);
    try t.expectEqual(@as(u32, 2), first.payload.values.comment_requests);
    const sent_after_first = r.client.sent;

    // Nothing moved, so the second run pays for no comments request at
    // all — the whole reason the cache exists. It still sends the PR
    // listings.
    var second = try r.run(.{ .values = .{ .scope = acme_scope, .stale_after_days = 90, .excluded_branch_patterns = &.{} } });
    defer second.deinit();
    try t.expectEqual(@as(?usize, 1), second.payload.values.unresolved_comments);
    try t.expectEqual(@as(u32, 2), second.payload.values.comment_hits);
    try t.expectEqual(@as(u32, 2), second.payload.values.comment_requests);
    // Two repo listings, and not one comments request.
    try t.expectEqual(@as(u32, 2), r.client.sent - sent_after_first);
}
