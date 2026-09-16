//! What the pane knows about a workspace, read out of Bitbucket's JSON
//! into plain structs — a pull request, a pipeline run, a branch head,
//! the per-repo groupings the two trees paint — and the few rules the
//! reference applies to them before they reach a row: which branches a
//! repo shows (`curateBranches`), how a merged PR finds the pipeline
//! that ran on its merge commit, what a date column reads.
//!
//! Every string is a slice of the arena the fetch parsed into; a
//! `RepoPrs` / `RepoPipelines` row owns nothing and is copied freely.

const std = @import("std");
const Allocator = std.mem.Allocator;
const j = @import("json.zig");
const dates = @import("dates.zig");

pub const Participant = struct {
    name: []const u8 = "",
    account_id: []const u8 = "",
    approved: bool = false,
    /// `approved` / `changes_requested` / "".
    state: []const u8 = "",
};

pub const PullRequest = struct {
    id: i64 = 0,
    title: []const u8 = "",
    /// `OPEN` / `MERGED` / `DECLINED` / `SUPERSEDED`.
    state: []const u8 = "",
    draft: bool = false,
    updated_on: []const u8 = "",
    author: []const u8 = "",
    author_id: []const u8 = "",
    source_branch: []const u8 = "",
    dest_branch: []const u8 = "",
    /// `workspace/repo`, from the destination's repository.
    repo_full: []const u8 = "",
    html_url: []const u8 = "",
    description: []const u8 = "",
    participants: []const Participant = &.{},
    /// The merge commit's hash on a MERGED PR; "" otherwise.
    merge_commit: []const u8 = "",

    pub fn updatedDate(pr: PullRequest) []const u8 {
        return dates.date(pr.updated_on);
    }

    /// `<workspace>/<repo>` split; the repo half is "" when unknown.
    pub fn repoSlug(pr: PullRequest) []const u8 {
        const i = std.mem.indexOfScalar(u8, pr.repo_full, '/') orelse return pr.repo_full;
        return pr.repo_full[i + 1 ..];
    }

    pub fn workspaceSlug(pr: PullRequest) []const u8 {
        const i = std.mem.indexOfScalar(u8, pr.repo_full, '/') orelse return "";
        return pr.repo_full[0..i];
    }

    pub fn isMerged(pr: PullRequest) bool {
        return std.ascii.eqlIgnoreCase(pr.state, "MERGED");
    }

    pub fn isOpen(pr: PullRequest) bool {
        return std.ascii.eqlIgnoreCase(pr.state, "OPEN");
    }

    /// Participants who approved.
    pub fn approvalCount(pr: PullRequest) usize {
        var n: usize = 0;
        for (pr.participants) |p| n += @intFromBool(p.approved);
        return n;
    }

    pub fn approvedBy(pr: PullRequest, account_id: []const u8) bool {
        if (account_id.len == 0) return false;
        for (pr.participants) |p| if (p.approved and std.mem.eql(u8, p.account_id, account_id)) return true;
        return false;
    }

    /// `https://bitbucket.org/<ws>/<repo>/pull-requests/<id>` when the
    /// API sent no link.
    pub fn url(pr: PullRequest, buf: []u8, workspace: []const u8, repo: []const u8) []const u8 {
        if (pr.html_url.len > 0) return pr.html_url;
        return std.fmt.bufPrint(buf, "https://bitbucket.org/{s}/{s}/pull-requests/{d}", .{ workspace, repo, pr.id }) catch "";
    }
};

pub const Comment = struct {
    id: i64 = 0,
    author: []const u8 = "",
    created_on: []const u8 = "",
    body: []const u8 = "",
    parent_id: i64 = 0,
    inline_path: []const u8 = "",
    inline_line: i64 = 0,

    pub fn createdDate(c: Comment) []const u8 {
        return dates.date(c.created_on);
    }
};

pub const Pipeline = struct {
    uuid: []const u8 = "",
    build_number: i64 = 0,
    /// `PENDING` / `IN_PROGRESS` / `COMPLETED` / `HALTED` / `STOPPED`.
    state_name: []const u8 = "",
    /// `SUCCESSFUL` / `FAILED` / `STOPPED` / `ERROR` once completed.
    result_name: []const u8 = "",
    created_on: []const u8 = "",
    duration_secs: i64 = 0,
    ref_name: []const u8 = "",
    commit_hash: []const u8 = "",
    trigger: []const u8 = "",
    creator: []const u8 = "",

    /// The result when there is one, else the state: what the flat
    /// pipelines list and the merged-PR sub-line show.
    pub fn stateLabel(p: Pipeline) []const u8 {
        if (p.result_name.len > 0) return p.result_name;
        return if (p.state_name.len > 0) p.state_name else "UNKNOWN";
    }

    /// Just the lifecycle stage, for the tree's STATE column.
    pub fn stateOnlyLabel(p: Pipeline) []const u8 {
        return if (p.state_name.len > 0) p.state_name else "UNKNOWN";
    }

    pub fn branchLabel(p: Pipeline) []const u8 {
        return if (p.ref_name.len > 0) p.ref_name else "—";
    }

    pub fn shortSha(p: Pipeline) []const u8 {
        return p.commit_hash[0..@min(p.commit_hash.len, 7)];
    }

    pub fn triggerLabel(p: Pipeline) []const u8 {
        return if (p.trigger.len > 0) p.trigger else "—";
    }

    /// `5m12s` / `40s` / `—`.
    pub fn durationLabel(p: Pipeline, buf: []u8) []const u8 {
        if (p.duration_secs <= 0) return "—";
        const m: u64 = @intCast(@divFloor(p.duration_secs, 60));
        const s: u64 = @intCast(@mod(p.duration_secs, 60));
        if (m > 0) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ m, s }) catch "—";
        return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "—";
    }

    pub fn createdDate(p: Pipeline) []const u8 {
        return dates.date(p.created_on);
    }

    /// The glyph the merged-PR sub-line paints before the label.
    pub fn glyph(p: Pipeline) []const u8 {
        return glyphFor(p.stateLabel());
    }
};

/// `✓` succeeded, `✗` failed, `⏵` running, `⊘` stopped, `?` otherwise.
pub fn glyphFor(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "SUCCESSFUL")) return "✓";
    if (std.mem.eql(u8, label, "FAILED") or std.mem.eql(u8, label, "ERROR")) return "✗";
    if (std.mem.eql(u8, label, "IN_PROGRESS") or std.mem.eql(u8, label, "PENDING") or std.mem.eql(u8, label, "RUNNING")) return "⏵";
    if (std.mem.eql(u8, label, "STOPPED") or std.mem.eql(u8, label, "HALTED")) return "⊘";
    return "?";
}

pub const BranchRef = struct {
    name: []const u8 = "",
    hash: []const u8 = "",
    date: []const u8 = "",
    message: []const u8 = "",
    /// `Name <email>` as Bitbucket sends it; `authorLabel` trims it.
    author_raw: []const u8 = "",
    author_name: []const u8 = "",

    pub fn shortSha(b: BranchRef) []const u8 {
        return b.hash[0..@min(b.hash.len, 7)];
    }

    pub fn latestDate(b: BranchRef) []const u8 {
        return dates.date(b.date);
    }

    pub fn authorLabel(b: BranchRef) []const u8 {
        if (b.author_name.len > 0) return b.author_name;
        if (b.author_raw.len == 0) return "—";
        const lt = std.mem.indexOfScalar(u8, b.author_raw, '<') orelse b.author_raw.len;
        const name = std.mem.trim(u8, b.author_raw[0..lt], " ");
        return if (name.len > 0) name else "—";
    }

    pub fn summaryLine(b: BranchRef) []const u8 {
        const end = std.mem.indexOfScalar(u8, b.message, '\n') orelse b.message.len;
        return std.mem.trim(u8, b.message[0..end], " \r");
    }
};

/// One repo's pull requests, for the PR tree.
pub const RepoPrs = struct {
    slug: []const u8,
    prs: []const PullRequest = &.{},
    /// The fetch failed even after retrying: a short label for the row.
    error_label: []const u8 = "",
    /// A repo with no open PRs shows its most recent merge inline.
    fallback_merged: ?PullRequest = null,
};

/// A branch with the latest pipeline that ran on it.
pub const BranchWithPipeline = struct {
    name: []const u8,
    latest: ?Pipeline = null,
    /// The pipeline's `created_on`, else the tip commit's date.
    last_activity_on: []const u8 = "",
};

/// One repo's branches, for the pipelines tree.
pub const RepoPipelines = struct {
    slug: []const u8,
    branches: []const BranchWithPipeline = &.{},
    error_label: []const u8 = "",

    /// The newest pipeline `created_on` across the branches, "" when none.
    pub fn newestPipeline(r: RepoPipelines) []const u8 {
        var best: []const u8 = "";
        for (r.branches) |b| if (b.latest) |p| {
            if (std.mem.order(u8, p.created_on, best) == .gt) best = p.created_on;
        };
        return best;
    }
};

// ─── reading Bitbucket's JSON ────────────────────────────────────────────

pub fn parsePullRequest(arena: Allocator, v: j.Value) Allocator.Error!PullRequest {
    var parts: std.ArrayList(Participant) = .empty;
    for (j.array(v, "participants")) |p| {
        try parts.append(arena, .{
            .name = j.pathStr(p, "user.display_name"),
            .account_id = j.pathStr(p, "user.account_id"),
            .approved = j.boolean(p, "approved", false),
            .state = j.str(p, "state"),
        });
    }
    var repo_full = j.pathStr(v, "destination.repository.full_name");
    if (repo_full.len == 0) repo_full = j.pathStr(v, "source.repository.full_name");
    return .{
        .id = j.int(v, "id", 0),
        .title = j.str(v, "title"),
        .state = j.str(v, "state"),
        .draft = j.boolean(v, "draft", false),
        .updated_on = j.str(v, "updated_on"),
        .author = j.pathStr(v, "author.display_name"),
        .author_id = j.pathStr(v, "author.account_id"),
        .source_branch = j.pathStr(v, "source.branch.name"),
        .dest_branch = j.pathStr(v, "destination.branch.name"),
        .repo_full = repo_full,
        .html_url = j.pathStr(v, "links.html.href"),
        .description = j.renderable(v, "description"),
        .participants = try parts.toOwnedSlice(arena),
        .merge_commit = j.pathStr(v, "merge_commit.hash"),
    };
}

/// A `{"values":[…]}` page of pull requests.
pub fn parsePullRequests(arena: Allocator, page: j.Value) Allocator.Error![]const PullRequest {
    var out: std.ArrayList(PullRequest) = .empty;
    for (j.array(page, "values")) |v| try out.append(arena, try parsePullRequest(arena, v));
    return out.toOwnedSlice(arena);
}

pub fn parseComments(arena: Allocator, page: j.Value) Allocator.Error![]const Comment {
    var out: std.ArrayList(Comment) = .empty;
    for (j.array(page, "values")) |v| {
        try out.append(arena, .{
            .id = j.int(v, "id", 0),
            .author = j.pathStr(v, "user.display_name"),
            .created_on = j.str(v, "created_on"),
            .body = j.renderable(v, "content"),
            .parent_id = if (j.path(v, "parent.id")) |p| (j.asInt(p) orelse 0) else 0,
            .inline_path = j.pathStr(v, "inline.path"),
            .inline_line = if (j.path(v, "inline.to")) |p| (j.asInt(p) orelse 0) else 0,
        });
    }
    return out.toOwnedSlice(arena);
}

pub fn parsePipeline(v: j.Value) Pipeline {
    return .{
        .uuid = j.str(v, "uuid"),
        .build_number = j.int(v, "build_number", 0),
        .state_name = j.pathStr(v, "state.name"),
        .result_name = j.pathStr(v, "state.result.name"),
        .created_on = j.str(v, "created_on"),
        .duration_secs = j.int(v, "duration_in_seconds", 0),
        .ref_name = j.pathStr(v, "target.ref_name"),
        .commit_hash = j.pathStr(v, "target.commit.hash"),
        .trigger = j.pathStr(v, "trigger.name"),
        .creator = j.pathStr(v, "creator.display_name"),
    };
}

pub fn parsePipelines(arena: Allocator, page: j.Value) Allocator.Error![]const Pipeline {
    var out: std.ArrayList(Pipeline) = .empty;
    for (j.array(page, "values")) |v| try out.append(arena, parsePipeline(v));
    return out.toOwnedSlice(arena);
}

pub fn parseBranches(arena: Allocator, page: j.Value) Allocator.Error![]const BranchRef {
    var out: std.ArrayList(BranchRef) = .empty;
    for (j.array(page, "values")) |v| {
        try out.append(arena, .{
            .name = j.str(v, "name"),
            .hash = j.pathStr(v, "target.hash"),
            .date = j.pathStr(v, "target.date"),
            .message = j.pathStr(v, "target.message"),
            .author_raw = j.pathStr(v, "target.author.raw"),
            .author_name = j.pathStr(v, "target.author.user.display_name"),
        });
    }
    return out.toOwnedSlice(arena);
}

pub const RepoActivity = struct { slug: []const u8, updated_on: []const u8 };

pub fn parseRepos(arena: Allocator, page: j.Value) Allocator.Error![]const RepoActivity {
    var out: std.ArrayList(RepoActivity) = .empty;
    for (j.array(page, "values")) |v| try out.append(arena, .{ .slug = j.str(v, "slug"), .updated_on = j.str(v, "updated_on") });
    return out.toOwnedSlice(arena);
}

// ─── the reference's rules ───────────────────────────────────────────────

/// The pipelines that ran on `hash`, newest first. Bitbucket's PR API
/// sends a 12-character short hash and its pipelines API a full one,
/// so either may be a prefix of the other.
pub fn pipelinesOnCommit(arena: Allocator, all: []const Pipeline, hash: []const u8) Allocator.Error![]const Pipeline {
    var out: std.ArrayList(Pipeline) = .empty;
    if (hash.len == 0) return out.toOwnedSlice(arena);
    for (all) |p| {
        const h = p.commit_hash;
        if (h.len == 0) continue;
        const match = if (h.len >= hash.len) std.ascii.startsWithIgnoreCase(h, hash) else std.ascii.startsWithIgnoreCase(hash, h);
        if (match) try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

/// Trunk / release / integration branches in the order they are shown;
/// a name that is one of these, or starts with `<major>/`, is a major.
pub const major_branch_order = [_][]const u8{ "main", "master", "trunk", "develop", "dev", "staging", "stage", "beta", "production", "prod", "release", "hotfix" };

pub fn majorRank(name: []const u8) ?usize {
    for (major_branch_order, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(name, m)) return i;
        if (name.len > m.len and name[m.len] == '/' and std.ascii.eqlIgnoreCase(name[0..m.len], m)) return i;
    }
    return null;
}

/// The literal-name majors that never go stale (release/* and
/// hotfix/* do, like a feature).
pub fn isEternalMajor(name: []const u8) bool {
    for ([_][]const u8{ "main", "master", "trunk", "develop", "dev", "staging", "stage", "beta", "production", "prod" }) |m| {
        if (std.ascii.eqlIgnoreCase(name, m)) return true;
    }
    return false;
}

/// Branches in a prefix family (`release/*`) kept per repo.
pub const max_per_family: usize = 1;
/// A feature / release / hotfix branch quiet for longer than this is
/// dropped from the tree.
pub const stale_after_days: i64 = 14;

/// The reference's shape for a repo's branches: every eternal major
/// present, the newest of each prefix family, and the single most
/// recently active feature branch — all in canonical order, with
/// stale non-eternals dropped.
pub fn curateBranches(arena: Allocator, now_secs: i64, branches: []const BranchWithPipeline) Allocator.Error![]const BranchWithPipeline {
    var kept: std.ArrayList(BranchWithPipeline) = .empty;
    for (branches) |b| {
        if (isEternalMajor(b.name)) {
            try kept.append(arena, b);
            continue;
        }
        const days = dates.daysSince(now_secs, b.last_activity_on);
        if (days == null or days.? <= stale_after_days) try kept.append(arena, b);
    }
    var out: std.ArrayList(BranchWithPipeline) = .empty;
    // The majors, family by family in canonical order, newest pipeline first, capped per family.
    for (major_branch_order, 0..) |_, rank| {
        var group: std.ArrayList(BranchWithPipeline) = .empty;
        for (kept.items) |b| if (majorRank(b.name) == rank) try group.append(arena, b);
        std.mem.sort(BranchWithPipeline, group.items, {}, newerPipelineFirst);
        for (group.items[0..@min(group.items.len, max_per_family)]) |b| try out.append(arena, b);
    }
    // Plus the one feature branch with the most recent pipeline
    // (the API's own order — newest commit first — breaks a tie).
    var best: ?BranchWithPipeline = null;
    for (kept.items) |b| {
        if (majorRank(b.name) != null) continue;
        if (best == null or newerPipelineFirst({}, b, best.?)) best = b;
    }
    if (best) |b| try out.append(arena, b);
    return out.toOwnedSlice(arena);
}

fn pipelineDate(b: BranchWithPipeline) []const u8 {
    return if (b.latest) |p| p.created_on else "";
}

fn newerPipelineFirst(_: void, a: BranchWithPipeline, b: BranchWithPipeline) bool {
    return std.mem.order(u8, pipelineDate(a), pipelineDate(b)) == .gt;
}

/// A pull request updated within the reference's 24-hour window (or
/// undated) is "recent"; the tree hides the rest behind a footer.
pub const recent_window_hours: i64 = 24;

pub fn isRecent(now_secs: i64, pr: PullRequest) bool {
    const h = dates.hoursSince(now_secs, pr.updated_on) orelse return true;
    return h <= recent_window_hours;
}

/// `^prefix` anchors at the start; anything else is a substring.
pub fn branchMatches(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '^') return std.mem.startsWith(u8, name, pattern[1..]);
    return std.mem.indexOf(u8, name, pattern) != null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const pr_json =
    \\{"id":7,"title":"Fix the thing","state":"OPEN","draft":false,"updated_on":"2026-09-15T12:00:00+00:00",
    \\ "author":{"display_name":"Chris M","account_id":"acct-chris"},
    \\ "source":{"branch":{"name":"chris/fix"},"repository":{"full_name":"acme/api"}},
    \\ "destination":{"branch":{"name":"main"},"repository":{"full_name":"acme/api"}},
    \\ "description":{"raw":"body text"},
    \\ "links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/7"}},
    \\ "participants":[{"approved":true,"state":"approved","user":{"display_name":"Dana","account_id":"acct-dana"}},{"approved":false,"user":{"display_name":"Sam","account_id":"acct-sam"}}],
    \\ "merge_commit":{"hash":"abcdef123456"}}
;

test "a pull request reads its columns, its approvals and its repo halves" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(j.Value, a, pr_json, .{});
    const pr = try parsePullRequest(a, parsed);
    try t.expectEqual(@as(i64, 7), pr.id);
    try t.expectEqualStrings("chris/fix", pr.source_branch);
    try t.expectEqualStrings("main", pr.dest_branch);
    try t.expectEqualStrings("acme", pr.workspaceSlug());
    try t.expectEqualStrings("api", pr.repoSlug());
    try t.expectEqualStrings("2026-09-15", pr.updatedDate());
    try t.expectEqual(@as(usize, 1), pr.approvalCount());
    try t.expect(pr.approvedBy("acct-dana"));
    try t.expect(!pr.approvedBy("acct-sam"));
    try t.expect(!pr.approvedBy(""));
    try t.expectEqualStrings("body text", pr.description);
    try t.expectEqualStrings("abcdef123456", pr.merge_commit);
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pull-requests/7", pr.url(&buf, "acme", "api"));
    const bare = PullRequest{ .id = 9 };
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pull-requests/9", bare.url(&buf, "acme", "api"));
}

test "a pipeline's labels: result over state, a duration, a glyph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const done = try std.json.parseFromSliceLeaky(j.Value, a,
        \\{"uuid":"{u}","build_number":412,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},"created_on":"2026-09-15T10:00:00+00:00","duration_in_seconds":312,"target":{"ref_name":"main","commit":{"hash":"9999mergecommit"}},"trigger":{"name":"push"}}
    , .{});
    const p = parsePipeline(done);
    try t.expectEqualStrings("SUCCESSFUL", p.stateLabel());
    try t.expectEqualStrings("COMPLETED", p.stateOnlyLabel());
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("5m12s", p.durationLabel(&buf));
    try t.expectEqualStrings("9999mer", p.shortSha());
    try t.expectEqualStrings("✓", p.glyph());
    const running = try std.json.parseFromSliceLeaky(j.Value, a, "{\"build_number\":1,\"state\":{\"name\":\"IN_PROGRESS\"}}", .{});
    const r = parsePipeline(running);
    try t.expectEqualStrings("IN_PROGRESS", r.stateLabel());
    try t.expectEqualStrings("—", r.durationLabel(&buf));
    try t.expectEqualStrings("—", r.branchLabel());
    try t.expectEqualStrings("⏵", r.glyph());
    try t.expectEqualStrings("✗", glyphFor("FAILED"));
    try t.expectEqualStrings("⊘", glyphFor("STOPPED"));
    try t.expectEqualStrings("?", glyphFor("odd"));
}

test "a branch head trims `Name <email>` and takes the first message line" {
    const b = BranchRef{ .name = "main", .hash = "abcdef0123", .date = "2026-09-15T10:00:00+00:00", .message = "First line\nSecond", .author_raw = "Dana R <dana@example.com>" };
    try t.expectEqualStrings("abcdef0", b.shortSha());
    try t.expectEqualStrings("2026-09-15", b.latestDate());
    try t.expectEqualStrings("Dana R", b.authorLabel());
    try t.expectEqualStrings("First line", b.summaryLine());
    try t.expectEqualStrings("—", (BranchRef{}).authorLabel());
}

test "pipelines on a commit match either way round a short hash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_]Pipeline{
        .{ .build_number = 1, .commit_hash = "ABCDEF1234567890" },
        .{ .build_number = 2, .commit_hash = "abcdef1234" },
        .{ .build_number = 3, .commit_hash = "zzz" },
    };
    const hits = try pipelinesOnCommit(a, &all, "abcdef123456");
    try t.expectEqual(@as(usize, 2), hits.len);
    try t.expectEqual(@as(usize, 0), (try pipelinesOnCommit(a, &all, "")).len);
}

test "curateBranches keeps the eternal majors, caps a family, adds one feature, and drops the stale" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1_789_500_000; // 2026-09-15
    const day = "2026-09-14T10:00:00+00:00";
    const old = "2026-08-01T10:00:00+00:00";
    const in_ = [_]BranchWithPipeline{
        .{ .name = "feat/one", .last_activity_on = day, .latest = .{ .build_number = 1, .created_on = "2026-09-14T10:00:00+00:00" } },
        .{ .name = "develop", .last_activity_on = old },
        .{ .name = "release/1.2", .last_activity_on = day, .latest = .{ .build_number = 2, .created_on = "2026-09-13T10:00:00+00:00" } },
        .{ .name = "release/1.1", .last_activity_on = day, .latest = .{ .build_number = 3, .created_on = "2026-09-10T10:00:00+00:00" } },
        .{ .name = "main", .last_activity_on = day },
        .{ .name = "feat/two", .last_activity_on = day, .latest = .{ .build_number = 4, .created_on = "2026-09-15T10:00:00+00:00" } },
        .{ .name = "feat/stale", .last_activity_on = old, .latest = .{ .build_number = 5, .created_on = "2026-09-15T12:00:00+00:00" } },
        .{ .name = "hotfix/x", .last_activity_on = old },
    };
    const out = try curateBranches(a, now, &in_);
    try t.expectEqual(@as(usize, 4), out.len);
    try t.expectEqualStrings("main", out[0].name);
    try t.expectEqualStrings("develop", out[1].name); // eternal: kept though old
    try t.expectEqualStrings("release/1.2", out[2].name); // newest of its family; 1.1 capped
    try t.expectEqualStrings("feat/two", out[3].name); // the most recent feature; stale one dropped
    try t.expectEqual(@as(?usize, 0), majorRank("Main"));
    try t.expectEqual(@as(?usize, 10), majorRank("release/2.0"));
    try t.expect(majorRank("released") == null);
    try t.expect(isEternalMajor("prod"));
    try t.expect(!isEternalMajor("release/1"));
}

test "recency and the chip's branch patterns" {
    const now: i64 = 1_789_500_000;
    try t.expect(isRecent(now, .{ .updated_on = "2026-09-15T10:00:00+00:00" }));
    try t.expect(!isRecent(now, .{ .updated_on = "2026-09-13T10:00:00+00:00" }));
    try t.expect(isRecent(now, .{ .updated_on = "" }));
    try t.expect(branchMatches("^release/", "release/1.2"));
    try t.expect(!branchMatches("^release/", "feat/release/x"));
    try t.expect(branchMatches("hotfix", "my/hotfix/x"));
    try t.expect(!branchMatches("", "anything"));
}
