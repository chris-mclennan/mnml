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
    /// `REVIEWER` / `PARTICIPANT` — asked to review, or merely
    /// joined in (a comment, a vote of their own).
    role: []const u8 = "",
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
    /// The head of the source branch — what an OPEN pull request's
    /// builds ran on.
    source_commit: []const u8 = "",

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

    /// The commit this pull request's builds are about: what landed
    /// once it merged, the head of the branch under review before
    /// that. "" when the API named neither, which is the only reason a
    /// row has nothing to fold out.
    pub fn buildCommit(pr: PullRequest) []const u8 {
        if (pr.merge_commit.len > 0) return pr.merge_commit;
        return pr.source_commit;
    }

    /// Participants who approved.
    pub fn approvalCount(pr: PullRequest) usize {
        var n: usize = 0;
        for (pr.participants) |p| n += @intFromBool(p.approved);
        return n;
    }

    /// Is this pull request waiting on `account_id`'s review? A
    /// reviewer who has neither approved nor asked for changes has not
    /// answered yet, and the author's own row is never waiting on them.
    pub fn awaitingApproval(pr: PullRequest, account_id: []const u8) bool {
        if (account_id.len == 0) return false;
        if (std.mem.eql(u8, pr.author_id, account_id)) return false;
        for (pr.participants) |p| {
            if (!std.mem.eql(u8, p.account_id, account_id)) continue;
            // Someone who only commented is a PARTICIPANT, and nothing
            // is waiting on them; a listing that sends no role at all
            // is read as it was before roles were parsed.
            if (p.role.len > 0 and !std.ascii.eqlIgnoreCase(p.role, "REVIEWER")) return false;
            return !p.approved and !std.ascii.eqlIgnoreCase(p.state, "changes_requested");
        }
        return false;
    }

    pub fn approvedBy(pr: PullRequest, account_id: []const u8) bool {
        if (account_id.len == 0) return false;
        for (pr.participants) |p| if (p.approved and std.mem.eql(u8, p.account_id, account_id)) return true;
        return false;
    }

    /// Is `account_id` one of this pull request's REVIEWERS — asked to
    /// review it, voted or not? The web's "Reviewing" dropdown. The
    /// author's own row is never something they review, and a
    /// participant who only commented is not reviewing either.
    pub fn reviewedBy(pr: PullRequest, account_id: []const u8) bool {
        if (account_id.len == 0) return false;
        if (std.mem.eql(u8, pr.author_id, account_id)) return false;
        for (pr.participants) |p| {
            if (!std.mem.eql(u8, p.account_id, account_id)) continue;
            return std.ascii.eqlIgnoreCase(p.role, "REVIEWER");
        }
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
    /// Someone marked the thread resolved (Bitbucket's `resolution`
    /// object is present).
    resolved: bool = false,
    /// A deleted comment keeps its slot in the page with no content.
    deleted: bool = false,

    pub fn createdDate(c: Comment) []const u8 {
        return dates.date(c.created_on);
    }
};

/// How many review threads on one pull request are still waiting on
/// someone: a top-level comment that nobody has marked resolved and
/// that nobody — the author included — has replied to.
///
/// A reply is an answer whoever wrote it: "I disagree" closes the loop
/// as surely as a fix does, and Bitbucket's resolve button is used
/// unevenly across teams, so counting only `resolution` would call
/// every answered thread unanswered.
pub fn unresolvedThreads(comments: []const Comment) usize {
    var n: usize = 0;
    for (comments) |c| {
        if (c.deleted or c.resolved or c.parent_id != 0) continue;
        var replied = false;
        for (comments) |other| {
            if (other.deleted or other.parent_id == 0) continue;
            if (other.parent_id == c.id) replied = true;
        }
        if (!replied) n += 1;
    }
    return n;
}

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
    /// `target.type`: `pipeline_ref_target` / `pipeline_pullrequest_target`
    /// / `pipeline_commit_target`.
    target_type: []const u8 = "",
    /// `target.ref_type`: `branch` / `tag` / `bookmark` / `named_branch`.
    ref_type: []const u8 = "",
    /// `target.selector.type`: `branches` / `default` / `custom` /
    /// `pull-requests` / `tags` — which section of the pipelines file
    /// the run came from.
    selector_type: []const u8 = "",

    /// The web's "Pipeline type" — one word off the three facts
    /// Bitbucket sends: `custom` when it was run from the custom
    /// section, `pull-request` when it ran on a pull request, `tag`
    /// when it ran on a tag, else `branch`. A selector this pane does
    /// not know is passed through as the API spelled it.
    pub fn typeLabel(p: Pipeline) []const u8 {
        if (std.ascii.eqlIgnoreCase(p.selector_type, "custom")) return "custom";
        if (std.ascii.indexOfIgnoreCase(p.target_type, "pullrequest") != null or std.ascii.eqlIgnoreCase(p.selector_type, "pull-requests")) return "pull-request";
        if (std.ascii.eqlIgnoreCase(p.ref_type, "tag") or std.ascii.eqlIgnoreCase(p.selector_type, "tags")) return "tag";
        if (p.selector_type.len == 0 or std.ascii.eqlIgnoreCase(p.selector_type, "branches") or std.ascii.eqlIgnoreCase(p.selector_type, "default")) return "branch";
        return p.selector_type;
    }

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
            .role = j.str(p, "role"),
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
        .source_commit = j.pathStr(v, "source.commit.hash"),
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
            .resolved = j.path(v, "resolution") != null,
            .deleted = j.boolean(v, "deleted", false),
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
        .target_type = j.pathStr(v, "target.type"),
        .ref_type = j.pathStr(v, "target.ref_type"),
        .selector_type = j.pathStr(v, "target.selector.type"),
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
    \\ "author":{"display_name":"Max Orr","account_id":"acct-max"},
    \\ "source":{"branch":{"name":"bug/fix"},"commit":{"hash":"head1234"},"repository":{"full_name":"acme/api"}},
    \\ "destination":{"branch":{"name":"main"},"repository":{"full_name":"acme/api"}},
    \\ "description":{"raw":"body text"},
    \\ "links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/7"}},
    \\ "participants":[{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"Dana","account_id":"acct-dana"}},{"role":"PARTICIPANT","approved":false,"user":{"display_name":"Sam","account_id":"acct-sam"}}],
    \\ "merge_commit":{"hash":"abcdef123456"}}
;

test "a pull request reads its columns, its approvals and its repo halves" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(j.Value, a, pr_json, .{});
    const pr = try parsePullRequest(a, parsed);
    try t.expectEqual(@as(i64, 7), pr.id);
    try t.expectEqualStrings("bug/fix", pr.source_branch);
    try t.expectEqualStrings("main", pr.dest_branch);
    try t.expectEqualStrings("acme", pr.workspaceSlug());
    try t.expectEqualStrings("api", pr.repoSlug());
    try t.expectEqualStrings("2026-09-15", pr.updatedDate());
    try t.expectEqual(@as(usize, 1), pr.approvalCount());
    try t.expect(pr.approvedBy("acct-dana"));
    try t.expect(!pr.approvedBy("acct-sam"));
    try t.expect(!pr.approvedBy(""));
    // Reviewing is the ROLE, not the vote: Dana was asked, Sam only
    // joined in, the author never reviews their own.
    try t.expectEqualStrings("REVIEWER", pr.participants[0].role);
    try t.expect(pr.reviewedBy("acct-dana"));
    try t.expect(!pr.reviewedBy("acct-sam"));
    try t.expect(!pr.reviewedBy("acct-max"));
    try t.expect(!pr.reviewedBy(""));
    try t.expectEqualStrings("body text", pr.description);
    try t.expectEqualStrings("abcdef123456", pr.merge_commit);
    try t.expectEqualStrings("abcdef123456", pr.buildCommit());
    // An OPEN pull request's builds are about its branch head.
    var open_pr = pr;
    open_pr.state = "OPEN";
    open_pr.merge_commit = "";
    open_pr.source_commit = "head9999";
    try t.expectEqualStrings("head9999", open_pr.buildCommit());
    try t.expectEqualStrings("", (PullRequest{}).buildCommit());
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
    // The web's "Pipeline type", off the target's three facts.
    try t.expectEqualStrings("branch", p.typeLabel());
    const custom = try std.json.parseFromSliceLeaky(j.Value, a, "{\"build_number\":2,\"trigger\":{\"name\":\"MANUAL\"},\"target\":{\"type\":\"pipeline_ref_target\",\"ref_type\":\"branch\",\"ref_name\":\"main\",\"selector\":{\"type\":\"custom\",\"pattern\":\"deploy\"}}}", .{});
    try t.expectEqualStrings("custom", parsePipeline(custom).typeLabel());
    try t.expectEqualStrings("MANUAL", parsePipeline(custom).trigger);
    const on_pr = try std.json.parseFromSliceLeaky(j.Value, a, "{\"build_number\":3,\"target\":{\"type\":\"pipeline_pullrequest_target\",\"source\":\"x\",\"destination\":\"main\",\"selector\":{\"type\":\"pull-requests\",\"pattern\":\"**\"}}}", .{});
    try t.expectEqualStrings("pull-request", parsePipeline(on_pr).typeLabel());
    const tagged = try std.json.parseFromSliceLeaky(j.Value, a, "{\"build_number\":4,\"target\":{\"type\":\"pipeline_ref_target\",\"ref_type\":\"tag\",\"ref_name\":\"v1.2\",\"selector\":{\"type\":\"tags\",\"pattern\":\"v*\"}}}", .{});
    try t.expectEqualStrings("tag", parsePipeline(tagged).typeLabel());
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

test "a thread is waiting on someone only when nobody resolved it and nobody replied" {
    const threads = [_]Comment{
        // Nobody has answered this one: it is waiting.
        .{ .id = 1, .author = "Dana R", .body = "this has bitten us twice" },
        // Answered — by anyone. A reply closes the loop whoever wrote
        // it: "I disagree" is an answer as much as a fix is.
        .{ .id = 2, .author = "Sam K", .body = "escape the value here" },
        .{ .id = 3, .author = "Max Orr", .body = "pushed an escape", .parent_id = 2 },
        // Marked resolved, never replied to: not waiting.
        .{ .id = 4, .author = "Ada L", .body = "nit: name", .resolved = true },
        // Deleted: gone, not waiting.
        .{ .id = 5, .author = "Ada L", .body = "", .deleted = true },
    };
    try t.expectEqual(@as(usize, 1), unresolvedThreads(&threads));

    // A reply is not itself a thread, so a page of nothing but replies
    // counts nothing.
    try t.expectEqual(@as(usize, 0), unresolvedThreads(&.{
        .{ .id = 10, .parent_id = 9 },
        .{ .id = 11, .parent_id = 9 },
    }));
    // A deleted REPLY does not answer anything — the thread is waiting
    // again.
    try t.expectEqual(@as(usize, 1), unresolvedThreads(&.{
        .{ .id = 20, .body = "still?" },
        .{ .id = 21, .parent_id = 20, .deleted = true },
    }));
    try t.expectEqual(@as(usize, 0), unresolvedThreads(&.{}));
    // An id of zero is not an id. Without the guard every top-level
    // comment (parent 0) would look like a reply to it and the count
    // would silently come out low.
    try t.expectEqual(@as(usize, 2), unresolvedThreads(&.{
        .{ .id = 0, .body = "malformed" },
        .{ .id = 30, .body = "waiting" },
    }));
}

test "the two keys behind that rule are read off Bitbucket's own shape" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page =
        \\{"pagelen":50,"size":3,"values":[
        \\{"id":1,"user":{"display_name":"Dana R"},"created_on":"2026-09-01T10:00:00+00:00","content":{"raw":"open"}},
        \\{"id":2,"user":{"display_name":"Sam K"},"created_on":"2026-09-01T11:00:00+00:00","content":{"raw":"done"},"resolution":{"type":"pullrequest_comment_resolution","user":{"display_name":"Sam K"}}},
        \\{"id":3,"user":{"display_name":"Ada L"},"created_on":"2026-09-01T12:00:00+00:00","content":{"raw":""},"deleted":true}
        \\]}
    ;
    const v = try std.json.parseFromSliceLeaky(j.Value, a, page, .{});
    const cs = try parseComments(a, v);
    try t.expectEqual(@as(usize, 3), cs.len);
    // An open thread has no `resolution` key at all, which is what
    // "present means resolved" rests on.
    try t.expect(!cs[0].resolved);
    try t.expect(!cs[0].deleted);
    try t.expect(cs[1].resolved);
    try t.expect(cs[2].deleted);
    try t.expectEqual(@as(usize, 1), unresolvedThreads(cs));
}
