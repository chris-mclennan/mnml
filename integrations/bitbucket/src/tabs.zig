//! A tab's state and the rows it shows. `TabSpec` is a config tab
//! resolved against the workspace and the account; `TabData` is what
//! the last fetch loaded, in one of five shapes (the two trees and the
//! three flat lists); `visibleRows` flattens a tree into the rows the
//! screen paints and the cursor walks, applying the reference's
//! visibility rules on the way:
//!
//! * a PR tab shows only the state it advertises (an Open tab never
//!   leaks a merged row in through a mine-only peek);
//! * a workspace tab keeps pull requests updated in the last 24 hours
//!   and hides the rest behind a `Show more (N)` row under that repo's
//!   pull requests, which lifts the fold for that repo (`show_all`
//!   lifts every repo's) — up to twenty merged rows per repo;
//! * a mine-only tab shows every open PR plus one merged peek.
//!
//! One list of `VisibleRow`, built once per frame, is what both the
//! painter and the hit map register, so a click on a row selects that
//! row and not its neighbour — the index is the same on both sides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cfg = @import("config.zig");
const model = @import("model.zig");
const filters = @import("filters.zig");

pub const TabSpec = struct {
    kind: cfg.Kind,
    name: []const u8,
    workspace: []const u8,
    repo: []const u8 = "",
    /// `OPEN` / … for a `pull_requests` tab; "" on the other kinds.
    state: []const u8 = "",
    mode: cfg.Mode = .none,
    q: []const u8 = "",
    mine_only: bool = false,
    /// The API states a PR listing is fetched with — the Status chip's
    /// `apiStates()` at the time the refresh was queued. Null is the
    /// kind's own (`apiStates`); the app sets it before a refetch the
    /// chip asked for.
    states: ?filters.ApiStates = null,

    pub fn resolve(c: cfg.Config, tab: cfg.Tab) TabSpec {
        return .{
            .kind = tab.kind,
            .name = tab.name,
            .workspace = c.tabWorkspace(tab),
            .repo = tab.repo,
            .state = if (tab.kind == .pull_requests) @tagName(tab.state) else "",
            .mode = if (tab.kind == .pull_requests) tab.mode else .none,
            .q = if (tab.kind == .pull_requests) tab.q else "",
            .mine_only = tab.mine_only and tab.kind.isWorkspaceWide(),
        };
    }

    /// The states this spec asks the API for: what the chip set, else
    /// what the kind lists on its own.
    pub fn apiStates(s: TabSpec) filters.ApiStates {
        return s.states orelse filters.PrStatus.defaultFor(s.kind, s.state).apiStates();
    }

    /// The PR state this tab advertises, or null when it lists
    /// something other than pull requests of one state.
    pub fn impliedPrState(s: TabSpec) ?[]const u8 {
        return switch (s.kind) {
            .workspace_open_prs => "OPEN",
            .workspace_merged_prs => "MERGED",
            .pull_requests => if (s.state.len > 0) s.state else null,
            else => null,
        };
    }

    pub fn isTree(s: TabSpec) bool {
        return s.kind == .workspace_open_prs or s.kind == .workspace_merged_prs or s.kind == .workspace_pipelines;
    }
};

pub const TabData = union(enum) {
    pull_requests: []const model.PullRequest,
    pipelines: []const model.Pipeline,
    branches: []const model.BranchRef,
    repo_pr_tree: []const model.RepoPrs,
    repo_tree: []const model.RepoPipelines,

    pub fn emptyFor(kind: cfg.Kind) TabData {
        return switch (kind) {
            .pull_requests => .{ .pull_requests = &.{} },
            .pipelines => .{ .pipelines = &.{} },
            .branches => .{ .branches = &.{} },
            .workspace_open_prs, .workspace_merged_prs => .{ .repo_pr_tree = &.{} },
            .workspace_pipelines => .{ .repo_tree = &.{} },
        };
    }

    /// Repo count for a tree, row count for a list.
    pub fn len(d: TabData) usize {
        return switch (d) {
            .pull_requests => |v| v.len,
            .pipelines => |v| v.len,
            .branches => |v| v.len,
            .repo_pr_tree => |v| v.len,
            .repo_tree => |v| v.len,
        };
    }
};

/// The slugs of the repos a tree has open, and the merged PRs opened
/// to their post-merge pipeline. Keys are owned copies, so they
/// survive the fetch that replaces the data.
pub const Expanded = struct {
    gpa: Allocator,
    repos: std.StringHashMapUnmanaged(void) = .empty,
    prs: std.StringHashMapUnmanaged(void) = .empty,
    /// The repos whose `Show more (N)` was pressed: every row the
    /// tab's window hid under that repo shows. A fetch folds them again.
    more: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator) Expanded {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Expanded) void {
        freeKeys(e.gpa, &e.repos);
        freeKeys(e.gpa, &e.prs);
        freeKeys(e.gpa, &e.more);
        e.* = undefined;
    }

    fn freeKeys(gpa: Allocator, m: *std.StringHashMapUnmanaged(void)) void {
        var it = m.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        m.deinit(gpa);
    }

    pub fn hasRepo(e: *const Expanded, slug: []const u8) bool {
        return e.repos.contains(slug);
    }

    pub fn setRepo(e: *Expanded, slug: []const u8, open: bool) Allocator.Error!void {
        if (open) {
            if (e.repos.contains(slug)) return;
            const k = try e.gpa.dupe(u8, slug);
            errdefer e.gpa.free(k);
            try e.repos.put(e.gpa, k, {});
        } else if (e.repos.fetchRemove(slug)) |kv| {
            e.gpa.free(kv.key);
        }
    }

    pub fn toggleRepo(e: *Expanded, slug: []const u8) Allocator.Error!void {
        try e.setRepo(slug, !e.hasRepo(slug));
    }

    pub fn hasMore(e: *const Expanded, slug: []const u8) bool {
        return e.more.contains(slug);
    }

    /// Lift (or put back) the window that folds `slug`'s older rows.
    pub fn setMore(e: *Expanded, slug: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (e.more.contains(slug)) return;
            const k = try e.gpa.dupe(u8, slug);
            errdefer e.gpa.free(k);
            try e.more.put(e.gpa, k, {});
        } else if (e.more.fetchRemove(slug)) |kv| {
            e.gpa.free(kv.key);
        }
    }

    pub fn clearMore(e: *Expanded) void {
        var it = e.more.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.more.clearRetainingCapacity();
    }

    pub fn clearRepos(e: *Expanded) void {
        var it = e.repos.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.repos.clearRetainingCapacity();
    }

    fn prKey(buf: []u8, slug: []const u8, id: i64) []const u8 {
        return std.fmt.bufPrint(buf, "{s}#{d}", .{ slug, id }) catch buf[0..0];
    }

    pub fn hasPr(e: *const Expanded, slug: []const u8, id: i64) bool {
        var buf: [256]u8 = undefined;
        return e.prs.contains(prKey(&buf, slug, id));
    }

    pub fn setPr(e: *Expanded, slug: []const u8, id: i64, open: bool) Allocator.Error!void {
        var buf: [256]u8 = undefined;
        const key = prKey(&buf, slug, id);
        if (open) {
            if (e.prs.contains(key)) return;
            const k = try e.gpa.dupe(u8, key);
            errdefer e.gpa.free(k);
            try e.prs.put(e.gpa, k, {});
        } else if (e.prs.fetchRemove(key)) |kv| {
            e.gpa.free(kv.key);
        }
    }

    /// Keep only the repos in `slugs` (a fetch replaced the rows), and
    /// open every one when nothing was open before — the reference
    /// auto-expands the tree on its first fetch.
    pub fn carryOver(e: *Expanded, slugs: []const []const u8) Allocator.Error!void {
        var it = e.repos.keyIterator();
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(e.gpa);
        while (it.next()) |k| if (!cfg.contains(slugs, k.*)) try gone.append(e.gpa, k.*);
        for (gone.items) |k| try e.setRepo(k, false);
        if (e.repos.count() == 0) for (slugs) |s| try e.setRepo(s, true);
    }
};

/// The reference's cap on merged rows revealed by `Show more (N)`.
pub const show_all_merged_cap: usize = 20;

pub const VisibleRow = union(enum) {
    /// A tree's repo header; `repo` indexes the tree's rows.
    repo_header: struct { repo: usize },
    /// A PR under an expanded repo. `open` says its builds are folded
    /// out below it.
    pr: struct { repo: usize, idx: usize, open: bool },
    /// One build under an expanded PR — the runs on the commit it is
    /// about, newest first.
    build: struct { repo: usize, idx: usize, run: usize },
    /// Where a build line would be when there is not one: still
    /// fetching, none ran, or the fetch failed.
    build_note: struct { repo: usize, idx: usize, kind: NoteKind },
    /// A branch under an expanded repo of the pipelines tree.
    branch: struct { repo: usize, idx: usize },
    /// `Show more (N)`, over the rows the cap hid in repo `repo` — the
    /// row after that repo's last pull request, so it reads as the
    /// repo's and not as the next header's.
    show_more: struct { repo: usize, hidden: usize, merged: bool },
    /// A row of a flat list.
    flat: usize,

    /// Every row is one cell tall. The builds under a pull request
    /// used to be a second cell on the PR's own row — one line, never
    /// clickable, never reachable by the cursor. They are rows now.
    pub fn height(_: VisibleRow) u16 {
        return 1;
    }
};

pub const NoteKind = enum { loading, none, failed };

pub const View = struct {
    rows: []const VisibleRow,
    /// Cells the rows take in total. One per row now that a build is a
    /// row of its own; kept so the scroll window keeps speaking in
    /// cells rather than growing a second unit.
    cells: usize,
};

/// What the app has fetched for one expanded pull request's builds —
/// all `visibleRows` needs to know to lay the rows out. The app fills
/// one of these per expanded PR each frame; there are never many.
pub const BuildsOf = struct {
    slug: []const u8,
    id: i64,
    /// The runs on the pull request's commit; null while the fetch is
    /// still in flight.
    runs: ?usize = null,
    /// The fetch came back with a reason instead of runs.
    failed: bool = false,
};

pub const VisibleCtx = struct {
    spec: TabSpec,
    data: TabData,
    expanded: *const Expanded,
    show_all: bool,
    now_secs: i64,
    /// One entry per expanded pull request; an expanded PR missing from
    /// it is still being fetched.
    builds: []const BuildsOf = &.{},
    /// The toolbar's chips — Status, Author, Target branch, Show on a
    /// PR tab; Run by, Branch, Pipeline type, Status, Trigger type on a
    /// pipelines tab. Every one a predicate over `participants`,
    /// `dest_branch`, a run's facts — what the listing already
    /// carries, so none of them costs a request here. Null is the
    /// spec's kind on its own defaults.
    filters: ?filters.Filters = null,
    /// The account the `me` author and the Show values are about.
    me: []const u8 = "",

    /// The chips in force: what was given, else the kind's own.
    pub fn effective(c: VisibleCtx) filters.Filters {
        return c.filters orelse filters.Filters.defaultFor(c.spec.kind, c.spec.state, c.spec.mine_only);
    }

    pub fn buildsOf(c: VisibleCtx, slug: []const u8, id: i64) ?BuildsOf {
        for (c.builds) |b| if (b.id == id and std.mem.eql(u8, b.slug, slug)) return b;
        return null;
    }
};

/// The PRs of one repo that show under its header, as indices into
/// `prs`, per the tab's policy. `hidden` gets the count the policy hid.
pub fn visiblePrs(arena: Allocator, c: VisibleCtx, prs: []const model.PullRequest, hidden: *usize) Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var eligible: usize = 0;
    var merged_kept: usize = 0;
    var merged_peeked = false;
    const f = c.effective();
    // A chip is an explicit ask, so it lifts the 24-hour window the
    // tree otherwise hides old rows behind: what has been waiting on
    // you for three days is exactly what `awaiting me` is for, and a
    // target branch nobody merged to this week is still the one asked
    // for. The kind's own scope (`me` on a mine-only tab) is not a
    // chip and keeps the window.
    const lifted = f.prNarrowedFrom(filters.Filters.defaultFor(c.spec.kind, c.spec.state, c.spec.mine_only));
    for (prs, 0..) |pr, i| {
        // The chips narrow before anything else counts: a row they
        // hide was never eligible, so the fold row does not offer to
        // reveal rows a chip is deliberately keeping out. The Status
        // chip is what keeps an Open tab from leaking a merged row in
        // through a mine-only peek.
        if (!f.prMatches(pr, c.me)) continue;
        eligible += 1;
        if (lifted) {
            try out.append(arena, i);
        } else if (c.show_all) {
            if (pr.isMerged()) {
                if (merged_kept >= show_all_merged_cap) continue;
                merged_kept += 1;
            }
            try out.append(arena, i);
        } else if (c.spec.mine_only) {
            if (pr.isOpen()) {
                try out.append(arena, i);
            } else if (pr.isMerged() and !merged_peeked) {
                merged_peeked = true;
                try out.append(arena, i);
            }
        } else if (model.isRecent(c.now_secs, pr)) {
            try out.append(arena, i);
        }
    }
    hidden.* += eligible - out.items.len;
    return out.toOwnedSlice(arena);
}

/// The rows the tab shows, top to bottom.
pub fn visibleRows(arena: Allocator, c: VisibleCtx) Allocator.Error!View {
    var out: std.ArrayList(VisibleRow) = .empty;
    var cells: usize = 0;
    const f = c.effective();
    switch (c.data) {
        .repo_pr_tree => |repos| {
            for (repos, 0..) |r, ri| {
                try out.append(arena, .{ .repo_header = .{ .repo = ri } });
                cells += 1;
                if (!c.expanded.hasRepo(r.slug)) continue;
                // Each repo folds its own older rows, and its own
                // `Show more (N)` lifts them: one footer at the end of
                // the tab read as the LAST repo's.
                var rc = c;
                rc.show_all = c.show_all or c.expanded.hasMore(r.slug);
                var hidden: usize = 0;
                for (try visiblePrs(arena, rc, r.prs, &hidden)) |pi| {
                    const pr = r.prs[pi];
                    // Every pull request folds out to its builds — an
                    // open one to the runs on its branch head, a merged
                    // one to the runs on what landed.
                    const open = pr.buildCommit().len > 0 and c.expanded.hasPr(r.slug, pr.id);
                    try out.append(arena, .{ .pr = .{ .repo = ri, .idx = pi, .open = open } });
                    cells += 1;
                    if (!open) continue;
                    const b = c.buildsOf(r.slug, pr.id) orelse {
                        try out.append(arena, .{ .build_note = .{ .repo = ri, .idx = pi, .kind = .loading } });
                        cells += 1;
                        continue;
                    };
                    if (b.failed) {
                        try out.append(arena, .{ .build_note = .{ .repo = ri, .idx = pi, .kind = .failed } });
                        cells += 1;
                    } else if ((b.runs orelse 0) == 0) {
                        try out.append(arena, .{ .build_note = .{ .repo = ri, .idx = pi, .kind = .none } });
                        cells += 1;
                    } else {
                        var k: usize = 0;
                        while (k < b.runs.?) : (k += 1) {
                            try out.append(arena, .{ .build = .{ .repo = ri, .idx = pi, .run = k } });
                            cells += 1;
                        }
                    }
                }
                if (!rc.show_all and hidden > 0) {
                    try out.append(arena, .{ .show_more = .{ .repo = ri, .hidden = hidden, .merged = c.spec.mine_only } });
                    cells += 1;
                }
            }
        },
        .repo_tree => |repos| {
            for (repos, 0..) |r, ri| {
                try out.append(arena, .{ .repo_header = .{ .repo = ri } });
                cells += 1;
                if (!c.expanded.hasRepo(r.slug)) continue;
                for (r.branches, 0..) |b, bi| {
                    if (!f.branchMatches(b.name, b.latest)) continue;
                    try out.append(arena, .{ .branch = .{ .repo = ri, .idx = bi } });
                    cells += 1;
                }
            }
        },
        .pull_requests => |list| {
            for (list, 0..) |pr, i| {
                if (!f.prMatches(pr, c.me)) continue;
                try out.append(arena, .{ .flat = i });
                cells += 1;
            }
        },
        .pipelines => |list| {
            for (list, 0..) |run, i| {
                if (!f.runMatches(run)) continue;
                try out.append(arena, .{ .flat = i });
                cells += 1;
            }
        },
        .branches => |list| {
            for (list, 0..) |_, i| try out.append(arena, .{ .flat = i });
            cells += list.len;
        },
    }
    return .{ .rows = try out.toOwnedSlice(arena), .cells = cells };
}

/// The repo header a row sits under (its own index for a header).
pub fn parentHeader(rows: []const VisibleRow, idx: usize) ?usize {
    var i = idx + 1;
    while (i > 0) : (i -= 1) {
        if (rows[i - 1] == .repo_header) return i - 1;
    }
    return null;
}

/// The row of `repo`'s header.
pub fn headerRowOf(rows: []const VisibleRow, repo: usize) ?usize {
    for (rows, 0..) |r, i| switch (r) {
        .repo_header => |h| if (h.repo == repo) return i,
        else => {},
    };
    return null;
}

/// The repo index a row belongs to, for any tree row.
pub fn repoOf(r: VisibleRow) ?usize {
    return switch (r) {
        .repo_header => |h| h.repo,
        .pr => |p| p.repo,
        .build => |b| b.repo,
        .build_note => |b| b.repo,
        .branch => |b| b.repo,
        else => null,
    };
}

/// The pull request a row belongs to — its own, or the one its build
/// line hangs under.
pub fn prOf(r: VisibleRow) ?struct { repo: usize, idx: usize } {
    return switch (r) {
        .pr => |p| .{ .repo = p.repo, .idx = p.idx },
        .build => |b| .{ .repo = b.repo, .idx = b.idx },
        .build_note => |b| .{ .repo = b.repo, .idx = b.idx },
        else => null,
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn mkPr(id: i64, state: []const u8, updated: []const u8) model.PullRequest {
    return .{ .id = id, .state = state, .updated_on = updated, .merge_commit = if (std.mem.eql(u8, state, "MERGED")) "abc" else "" };
}

const now: i64 = 1_789_500_000; // 2026-09-15T19:20Z
const fresh_iso = "2026-09-15T10:00:00+00:00";
const stale_iso = "2026-09-13T10:00:00+00:00";

test "a workspace Open tab drops merged rows even with a mine peek, and hides the old behind a footer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ex = Expanded.init(t.allocator);
    defer ex.deinit();
    try ex.setRepo("api", true);
    const prs = [_]model.PullRequest{ mkPr(1, "OPEN", fresh_iso), mkPr(2, "OPEN", stale_iso), mkPr(3, "MERGED", fresh_iso), mkPr(4, "MERGED", fresh_iso) };
    const repos = [_]model.RepoPrs{.{ .slug = "api", .prs = &prs }};
    const spec: TabSpec = .{ .kind = .workspace_open_prs, .name = "Open", .workspace = "acme" };
    const v = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    // header, #1, footer (the stale #2 hidden; the merged never
    // eligible: the Status chip starts on Open + Draft).
    try t.expectEqual(@as(usize, 3), v.rows.len);
    try t.expectEqual(@as(usize, 0), v.rows[1].pr.idx);
    try t.expectEqual(@as(usize, 1), v.rows[2].show_more.hidden);
    try t.expect(!v.rows[2].show_more.merged);
    // show_all lifts the footer.
    const all = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = true, .now_secs = now });
    try t.expectEqual(@as(usize, 3), all.rows.len);
    try t.expect(all.rows[2] == .pr);
    // Collapsed: the header alone, and nothing counts as hidden.
    try ex.setRepo("api", false);
    const closed = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 1), closed.rows.len);
}

test "each repo's `Show more (N)` sits under that repo's pull requests, counts its own, and lifts its own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ex = Expanded.init(t.allocator);
    defer ex.deinit();
    try ex.setRepo("api", true);
    try ex.setRepo("web", true);
    const api = [_]model.PullRequest{ mkPr(1, "OPEN", fresh_iso), mkPr(2, "OPEN", stale_iso) };
    const web = [_]model.PullRequest{ mkPr(7, "OPEN", fresh_iso), mkPr(8, "OPEN", stale_iso), mkPr(9, "OPEN", stale_iso) };
    const repos = [_]model.RepoPrs{ .{ .slug = "api", .prs = &api }, .{ .slug = "web", .prs = &web } };
    const spec: TabSpec = .{ .kind = .workspace_open_prs, .name = "Open", .workspace = "acme" };
    const ctx: VisibleCtx = .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now };
    // api, #1, api's footer (1), web, #7, web's footer (2) — the footer
    // that belongs to api is not after web's header.
    var v = try visibleRows(a, ctx);
    try t.expectEqual(@as(usize, 6), v.rows.len);
    try t.expectEqual(@as(usize, 0), v.rows[2].show_more.repo);
    try t.expectEqual(@as(usize, 1), v.rows[2].show_more.hidden);
    try t.expectEqual(@as(usize, 1), v.rows[3].repo_header.repo);
    try t.expectEqual(@as(usize, 1), v.rows[5].show_more.repo);
    try t.expectEqual(@as(usize, 2), v.rows[5].show_more.hidden);
    // Lifting api's leaves web's fold where it is.
    try ex.setMore("api", true);
    v = try visibleRows(a, ctx);
    try t.expectEqual(@as(usize, 6), v.rows.len);
    try t.expect(v.rows[1] == .pr and v.rows[2] == .pr);
    try t.expectEqual(@as(usize, 1), v.rows[5].show_more.repo);
    // A fetch folds every repo again.
    ex.clearMore();
    v = try visibleRows(a, ctx);
    try t.expect(v.rows[2] == .show_more);
}

test "a mine tab shows every open PR and one merged peek; show_all caps merged at twenty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ex = Expanded.init(t.allocator);
    defer ex.deinit();
    try ex.setRepo("api", true);
    var prs: [30]model.PullRequest = undefined;
    for (&prs, 0..) |*p, i| p.* = mkPr(@intCast(i), if (i < 3) "OPEN" else "MERGED", stale_iso);
    const repos = [_]model.RepoPrs{.{ .slug = "api", .prs = &prs }};
    const mine: TabSpec = .{ .kind = .pull_requests, .name = "Mine", .workspace = "acme", .state = "", .mine_only = true };
    _ = mine;
    const spec: TabSpec = .{ .kind = .workspace_open_prs, .name = "Mine", .workspace = "acme", .mine_only = true };
    // An Open tab: the merged peek is not eligible, so 3 open rows and no footer.
    const v = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 4), v.rows.len);
    // A per-repo tab with no state — its Status chip starts with every
    // box ticked: 3 open + 1 peek + a `Show more (26)` footer.
    const any: TabSpec = .{ .kind = .pull_requests, .name = "Mine", .workspace = "acme", .state = "", .mine_only = true };
    const peek = try visibleRows(a, .{ .spec = any, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 6), peek.rows.len);
    try t.expectEqual(@as(usize, 26), peek.rows[5].show_more.hidden);
    try t.expect(peek.rows[5].show_more.merged);
    const lifted = try visibleRows(a, .{ .spec = any, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = true, .now_secs = now });
    // header + 3 open + 20 merged, and no footer under show_all.
    try t.expectEqual(@as(usize, 24), lifted.rows.len);
}

test "an expanded PR's builds are rows of their own, one per run, open or merged" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ex = Expanded.init(t.allocator);
    defer ex.deinit();
    try ex.setRepo("api", true);
    try ex.setPr("api", 3, true);
    const prs = [_]model.PullRequest{ mkPr(3, "MERGED", fresh_iso), mkPr(4, "MERGED", fresh_iso) };
    const repos = [_]model.RepoPrs{.{ .slug = "api", .prs = &prs }};
    const spec: TabSpec = .{ .kind = .workspace_merged_prs, .name = "Merged", .workspace = "acme" };
    // Nothing fetched yet: the expanded PR shows that it is fetching,
    // rather than an empty gap that reads as "no builds".
    const loading = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 4), loading.rows.len);
    try t.expect(loading.rows[1].pr.open);
    try t.expectEqual(NoteKind.loading, loading.rows[2].build_note.kind);
    try t.expect(!loading.rows[3].pr.open);

    // Two runs: two rows, each one cell tall and each its own row for
    // the cursor and the pointer.
    const two = [_]BuildsOf{.{ .slug = "api", .id = 3, .runs = 2 }};
    const v = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now, .builds = &two });
    try t.expectEqual(@as(usize, 5), v.rows.len);
    try t.expectEqual(@as(usize, 0), v.rows[2].build.run);
    try t.expectEqual(@as(usize, 1), v.rows[3].build.run);
    try t.expectEqual(@as(usize, 5), v.cells);
    try t.expectEqual(@as(usize, 1), v.rows[0].height());
    try t.expectEqual(@as(usize, 0), prOf(v.rows[3]).?.repo);
    // None, and failed, each say so in their own words.
    const none = [_]BuildsOf{.{ .slug = "api", .id = 3, .runs = 0 }};
    const nv = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now, .builds = &none });
    try t.expectEqual(NoteKind.none, nv.rows[2].build_note.kind);
    const bad = [_]BuildsOf{.{ .slug = "api", .id = 3, .runs = 0, .failed = true }};
    const bv = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now, .builds = &bad });
    try t.expectEqual(NoteKind.failed, bv.rows[2].build_note.kind);

    // An OPEN pull request folds out the same way — on its branch head.
    const open_prs = [_]model.PullRequest{.{ .id = 3, .state = "OPEN", .updated_on = fresh_iso, .source_commit = "head1234" }};
    const open_repos = [_]model.RepoPrs{.{ .slug = "api", .prs = &open_prs }};
    const ospec: TabSpec = .{ .kind = .workspace_open_prs, .name = "Open", .workspace = "acme" };
    const ov = try visibleRows(a, .{ .spec = ospec, .data = .{ .repo_pr_tree = &open_repos }, .expanded = &ex, .show_all = false, .now_secs = now, .builds = &two });
    try t.expect(ov.rows[1].pr.open);
    try t.expectEqual(@as(usize, 4), ov.rows.len);
    // …and one that names no commit at all has nothing to fold out.
    const bare = [_]model.PullRequest{.{ .id = 3, .state = "OPEN", .updated_on = fresh_iso }};
    const bare_repos = [_]model.RepoPrs{.{ .slug = "api", .prs = &bare }};
    const bare_v = try visibleRows(a, .{ .spec = ospec, .data = .{ .repo_pr_tree = &bare_repos }, .expanded = &ex, .show_all = false, .now_secs = now, .builds = &two });
    try t.expectEqual(@as(usize, 2), bare_v.rows.len);
    try t.expect(!bare_v.rows[1].pr.open);

    try t.expectEqual(@as(?usize, 0), parentHeader(v.rows, 2));
    try t.expectEqual(@as(?usize, 0), headerRowOf(v.rows, 0));

    const branches = [_]model.BranchWithPipeline{ .{ .name = "main" }, .{ .name = "develop" } };
    const tree = [_]model.RepoPipelines{ .{ .slug = "api", .branches = &branches }, .{ .slug = "web", .branches = &branches } };
    try ex.setRepo("web", false);
    const pspec: TabSpec = .{ .kind = .workspace_pipelines, .name = "Pipelines", .workspace = "acme" };
    const p = try visibleRows(a, .{ .spec = pspec, .data = .{ .repo_tree = &tree }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 4), p.rows.len);
    try t.expectEqual(@as(usize, 1), p.rows[2].branch.idx);
    try t.expectEqual(@as(?usize, 1), repoOf(p.rows[3]));
}

test "carryOver keeps the open repos that still exist and opens everything on a first fetch" {
    var ex = Expanded.init(t.allocator);
    defer ex.deinit();
    try ex.carryOver(&.{ "api", "web" });
    try t.expect(ex.hasRepo("api") and ex.hasRepo("web"));
    try ex.setRepo("web", false);
    try ex.carryOver(&.{ "api", "cli" });
    try t.expect(ex.hasRepo("api"));
    try t.expect(!ex.hasRepo("cli"));
    try t.expect(!ex.hasRepo("web"));
    ex.clearRepos();
    try t.expectEqual(@as(u32, 0), ex.repos.count());
    try ex.toggleRepo("cli");
    try t.expect(ex.hasRepo("cli"));
}

test "a config tab resolves to a spec: state only on pull_requests, mine_only only on workspace kinds" {
    const c: cfg.Config = .{ .email = "e", .workspace = "acme" };
    const s = TabSpec.resolve(c, .{ .name = "api", .kind = .pull_requests, .repo = "api", .state = .MERGED });
    try t.expectEqualStrings("MERGED", s.state);
    try t.expectEqualStrings("acme", s.workspace);
    try t.expectEqualStrings("MERGED", s.impliedPrState().?);
    const w = TabSpec.resolve(c, .{ .name = "Open", .kind = .workspace_open_prs, .state = .MERGED, .workspace = "other", .mine_only = true });
    try t.expectEqualStrings("", w.state);
    try t.expectEqualStrings("OPEN", w.impliedPrState().?);
    try t.expectEqualStrings("other", w.workspace);
    try t.expect(w.mine_only and w.isTree());
    const p = TabSpec.resolve(c, .{ .name = "b", .kind = .pipelines, .repo = "api", .mine_only = true });
    try t.expect(p.impliedPrState() == null);
    try t.expect(!p.mine_only);
}
