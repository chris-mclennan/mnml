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
//!   and hides the rest behind a `[ Show N more older ]` footer row,
//!   which `show_all` lifts — up to twenty merged rows per repo;
//! * a mine-only tab shows every open PR plus one merged peek.
//!
//! One list of `VisibleRow`, built once per frame, is what both the
//! painter and the hit map register, so a click on a row selects that
//! row and not its neighbour — the index is the same on both sides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cfg = @import("config.zig");
const model = @import("model.zig");

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

    pub fn init(gpa: Allocator) Expanded {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Expanded) void {
        freeKeys(e.gpa, &e.repos);
        freeKeys(e.gpa, &e.prs);
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

/// The reference's cap on merged rows revealed by `[ Show N more ]`.
pub const show_all_merged_cap: usize = 20;

pub const VisibleRow = union(enum) {
    /// A tree's repo header; `repo` indexes the tree's rows.
    repo_header: struct { repo: usize },
    /// A PR under an expanded repo; `sub` when its post-merge pipeline
    /// line is open (the row is two cells tall).
    pr: struct { repo: usize, idx: usize, sub: bool },
    /// A branch under an expanded repo of the pipelines tree.
    branch: struct { repo: usize, idx: usize },
    /// `[ Show N more older ]` / `[ Show N more merged ]`.
    show_more: struct { hidden: usize, merged: bool },
    /// A row of a flat list.
    flat: usize,

    pub fn height(r: VisibleRow) u16 {
        return switch (r) {
            .pr => |p| if (p.sub) 2 else 1,
            else => 1,
        };
    }
};

pub const View = struct {
    rows: []const VisibleRow,
    /// Cells the rows take in total (a PR with its sub-line is two).
    cells: usize,
};

pub const VisibleCtx = struct {
    spec: TabSpec,
    data: TabData,
    expanded: *const Expanded,
    show_all: bool,
    now_secs: i64,
};

/// The PRs of one repo that show under its header, as indices into
/// `prs`, per the tab's policy. `hidden` gets the count the policy hid.
pub fn visiblePrs(arena: Allocator, c: VisibleCtx, prs: []const model.PullRequest, hidden: *usize) Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    const want = c.spec.impliedPrState();
    var eligible: usize = 0;
    var merged_kept: usize = 0;
    var merged_peeked = false;
    for (prs, 0..) |pr, i| {
        if (want) |s| if (!std.ascii.eqlIgnoreCase(pr.state, s)) continue;
        eligible += 1;
        if (c.show_all) {
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
    switch (c.data) {
        .repo_pr_tree => |repos| {
            var hidden: usize = 0;
            for (repos, 0..) |r, ri| {
                try out.append(arena, .{ .repo_header = .{ .repo = ri } });
                cells += 1;
                if (!c.expanded.hasRepo(r.slug)) continue;
                for (try visiblePrs(arena, c, r.prs, &hidden)) |pi| {
                    const pr = r.prs[pi];
                    const sub = pr.isMerged() and pr.merge_commit.len > 0 and c.expanded.hasPr(r.slug, pr.id);
                    try out.append(arena, .{ .pr = .{ .repo = ri, .idx = pi, .sub = sub } });
                    cells += if (sub) 2 else 1;
                }
            }
            if (!c.show_all and hidden > 0) {
                try out.append(arena, .{ .show_more = .{ .hidden = hidden, .merged = c.spec.mine_only } });
                cells += 1;
            }
        },
        .repo_tree => |repos| {
            for (repos, 0..) |r, ri| {
                try out.append(arena, .{ .repo_header = .{ .repo = ri } });
                cells += 1;
                if (!c.expanded.hasRepo(r.slug)) continue;
                for (r.branches, 0..) |_, bi| {
                    try out.append(arena, .{ .branch = .{ .repo = ri, .idx = bi } });
                    cells += 1;
                }
            }
        },
        inline .pull_requests, .pipelines, .branches => |list| {
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
        .branch => |b| b.repo,
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
    // header, #1, footer (the stale #2 hidden; the merged never eligible).
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
    // A per-repo tab with no state: 3 open + 1 peek + a `Show 26 more merged` footer.
    const any: TabSpec = .{ .kind = .pull_requests, .name = "Mine", .workspace = "acme", .state = "", .mine_only = true };
    const peek = try visibleRows(a, .{ .spec = any, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 6), peek.rows.len);
    try t.expectEqual(@as(usize, 26), peek.rows[5].show_more.hidden);
    try t.expect(peek.rows[5].show_more.merged);
    const lifted = try visibleRows(a, .{ .spec = any, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = true, .now_secs = now });
    // header + 3 open + 20 merged, and no footer under show_all.
    try t.expectEqual(@as(usize, 24), lifted.rows.len);
}

test "a merged PR opened to its pipeline is two cells tall, and the pipelines tree lists branches" {
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
    const v = try visibleRows(a, .{ .spec = spec, .data = .{ .repo_pr_tree = &repos }, .expanded = &ex, .show_all = false, .now_secs = now });
    try t.expectEqual(@as(usize, 3), v.rows.len);
    try t.expect(v.rows[1].pr.sub);
    try t.expect(!v.rows[2].pr.sub);
    try t.expectEqual(@as(usize, 4), v.cells);
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
