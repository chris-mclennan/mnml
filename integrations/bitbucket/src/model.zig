//! The shapes the pane paints: a pull request and the four things its
//! detail is made of — participants (reviewers and their approval
//! state), build statuses, the activity stream (top-level and inline
//! comments, approvals, updates) and the diffstat.
//!
//! Every string is a slice into the `std.json.Parsed` the fetch owns,
//! so a model value lives exactly as long as the arena it came from.

const std = @import("std");
const j = @import("json.zig");

pub const Value = std.json.Value;

/// How a participant stands on the PR. Bitbucket says this two ways —
/// the boolean `approved` and the newer `state` string — and older
/// responses carry only the boolean, so both are read.
pub const Approval = enum {
    none,
    approved,
    changes_requested,

    pub fn glyph(a: Approval) []const u8 {
        return switch (a) {
            .approved => "✓",
            .changes_requested => "✗",
            .none => "○",
        };
    }

    pub fn label(a: Approval) []const u8 {
        return switch (a) {
            .approved => "approved",
            .changes_requested => "changes requested",
            .none => "no vote",
        };
    }
};

pub const Participant = struct {
    display_name: []const u8 = "",
    account_id: []const u8 = "",
    /// `REVIEWER` or `PARTICIPANT`.
    role: []const u8 = "",
    approval: Approval = .none,

    pub fn isReviewer(p: Participant) bool {
        return std.ascii.eqlIgnoreCase(p.role, "REVIEWER");
    }

    pub fn fromValue(v: Value) Participant {
        const approved = j.boolean(v, "approved", false);
        const state = j.str(v, "state");
        return .{
            .display_name = j.pathStr(v, "user.display_name"),
            .account_id = j.pathStr(v, "user.account_id"),
            .role = j.str(v, "role"),
            .approval = if (approved or std.ascii.eqlIgnoreCase(state, "approved"))
                .approved
            else if (std.ascii.eqlIgnoreCase(state, "changes_requested"))
                .changes_requested
            else
                .none,
        };
    }
};

/// A commit build status — Bitbucket's `/commit/{sha}/statuses` entry.
pub const BuildStatus = struct {
    key: []const u8 = "",
    name: []const u8 = "",
    /// `SUCCESSFUL` / `FAILED` / `INPROGRESS` / `STOPPED`.
    state: []const u8 = "",
    url: []const u8 = "",

    pub fn glyph(s: BuildStatus) []const u8 {
        if (std.ascii.eqlIgnoreCase(s.state, "SUCCESSFUL")) return "●";
        if (std.ascii.eqlIgnoreCase(s.state, "FAILED")) return "✖";
        if (std.ascii.eqlIgnoreCase(s.state, "INPROGRESS")) return "◐";
        if (std.ascii.eqlIgnoreCase(s.state, "STOPPED")) return "■";
        return "○";
    }

    pub fn fromValue(v: Value) BuildStatus {
        return .{
            .key = j.str(v, "key"),
            .name = j.str(v, "name"),
            .state = j.str(v, "state"),
            .url = j.pathStr(v, "links.self.href"),
        };
    }
};

/// One entry of the PR's activity stream. Bitbucket's `/activity`
/// returns a heterogeneous list — `{comment: …}`, `{approval: …}`,
/// `{changes_requested: …}`, `{update: …}` — and each is flattened to
/// the same row here so the detail renders one chronological list.
pub const Activity = struct {
    pub const Kind = enum { comment, approval, changes_requested, update, other };

    kind: Kind = .other,
    author: []const u8 = "",
    created_on: []const u8 = "",
    text: []const u8 = "",
    /// Set on a comment made on a diff line.
    inline_path: []const u8 = "",
    inline_from: ?i64 = null,
    inline_to: ?i64 = null,
    /// A reply's parent comment id; 0 for a top-level comment.
    parent_id: i64 = 0,
    id: i64 = 0,
    /// Bitbucket marks a deleted comment rather than dropping it.
    deleted: bool = false,

    pub fn isInline(a: Activity) bool {
        return a.inline_path.len > 0;
    }

    /// The line a diff comment hangs off: the new-file line when there
    /// is one, else the old-file line.
    pub fn inlineLine(a: Activity) ?i64 {
        return a.inline_to orelse a.inline_from;
    }

    pub fn fromValue(v: Value) Activity {
        if (j.field(v, "comment")) |c| {
            var a: Activity = .{
                .kind = .comment,
                .id = j.int(c, "id", 0),
                .author = j.pathStr(c, "user.display_name"),
                .created_on = j.str(c, "created_on"),
                .text = j.renderable(c, "content"),
                .deleted = j.boolean(c, "deleted", false),
                .parent_id = if (j.field(c, "parent")) |p| j.int(p, "id", 0) else 0,
            };
            if (j.field(c, "inline")) |inl| {
                a.inline_path = j.str(inl, "path");
                a.inline_from = if (j.field(inl, "from")) |f| j.asInt(f) else null;
                a.inline_to = if (j.field(inl, "to")) |f| j.asInt(f) else null;
            }
            return a;
        }
        if (j.field(v, "approval")) |ap| return .{
            .kind = .approval,
            .author = j.pathStr(ap, "user.display_name"),
            .created_on = j.str(ap, "date"),
            .text = "approved this pull request",
        };
        if (j.field(v, "changes_requested")) |cr| return .{
            .kind = .changes_requested,
            .author = j.pathStr(cr, "user.display_name"),
            .created_on = j.str(cr, "date"),
            .text = "requested changes",
        };
        if (j.field(v, "update")) |up| return .{
            .kind = .update,
            .author = j.pathStr(up, "author.display_name"),
            .created_on = j.str(up, "date"),
            .text = if (j.str(up, "description").len > 0) j.str(up, "description") else j.str(up, "state"),
        };
        return .{};
    }
};

/// One file in the PR's diffstat.
pub const DiffstatEntry = struct {
    /// `added` / `modified` / `removed` / `renamed`.
    status: []const u8 = "",
    path: []const u8 = "",
    old_path: []const u8 = "",
    added: i64 = 0,
    removed: i64 = 0,

    pub fn glyph(e: DiffstatEntry) []const u8 {
        if (std.mem.eql(u8, e.status, "added")) return "+";
        if (std.mem.eql(u8, e.status, "removed")) return "-";
        if (std.mem.eql(u8, e.status, "renamed")) return "→";
        return "~";
    }

    pub fn fromValue(v: Value) DiffstatEntry {
        const new_path = j.pathStr(v, "new.path");
        const old_path = j.pathStr(v, "old.path");
        return .{
            .status = j.str(v, "status"),
            .path = if (new_path.len > 0) new_path else old_path,
            .old_path = old_path,
            .added = j.int(v, "lines_added", 0),
            .removed = j.int(v, "lines_removed", 0),
        };
    }
};

pub const Pr = struct {
    id: i64 = 0,
    title: []const u8 = "",
    /// `OPEN` / `MERGED` / `DECLINED` / `SUPERSEDED`.
    state: []const u8 = "",
    updated_on: []const u8 = "",
    author: []const u8 = "",
    author_account_id: []const u8 = "",
    source_branch: []const u8 = "",
    dest_branch: []const u8 = "",
    /// `<workspace>/<repo>` when Bitbucket nested a repository.
    repo_full_name: []const u8 = "",
    html_url: []const u8 = "",
    description: []const u8 = "",
    draft: bool = false,
    comment_count: i64 = 0,
    task_count: i64 = 0,
    merge_commit: []const u8 = "",
    source_commit: []const u8 = "",
    participants: []const Participant = &.{},
    /// The declared reviewer list, which is not the same as the
    /// participants: a declared reviewer who has not voted is missing
    /// from `participants` on some responses.
    reviewers: []const Participant = &.{},

    /// The workspace half of `repo_full_name`, or "".
    pub fn workspace(p: Pr) []const u8 {
        const i = std.mem.indexOfScalar(u8, p.repo_full_name, '/') orelse return "";
        return p.repo_full_name[0..i];
    }

    /// The repo half of `repo_full_name`, or the whole string when it
    /// carries no slash.
    pub fn repo(p: Pr) []const u8 {
        const i = std.mem.indexOfScalar(u8, p.repo_full_name, '/') orelse return p.repo_full_name;
        return p.repo_full_name[i + 1 ..];
    }

    pub fn updatedDate(p: Pr) []const u8 {
        return j.date(p.updated_on);
    }

    /// How many participants have approved.
    pub fn approvals(p: Pr) usize {
        var n: usize = 0;
        for (p.participants) |q| if (q.approval == .approved) {
            n += 1;
        };
        return n;
    }

    /// How many have asked for changes.
    pub fn changesRequested(p: Pr) usize {
        var n: usize = 0;
        for (p.participants) |q| if (q.approval == .changes_requested) {
            n += 1;
        };
        return n;
    }

    /// This account's vote, `.none` when it is not a participant.
    pub fn voteOf(p: Pr, account_id: []const u8) Approval {
        if (account_id.len == 0) return .none;
        for (p.participants) |q| {
            if (std.mem.eql(u8, q.account_id, account_id)) return q.approval;
        }
        return .none;
    }

    /// The reviewer list the detail paints: every declared reviewer,
    /// plus any participant who voted but was not declared. Allocated
    /// on `arena`.
    pub fn reviewerRoster(p: Pr, arena: std.mem.Allocator) std.mem.Allocator.Error![]const Participant {
        var out: std.ArrayList(Participant) = .empty;
        for (p.reviewers) |r| {
            var row = r;
            // A declared reviewer's vote lives on the participant record.
            for (p.participants) |q| {
                if (std.mem.eql(u8, q.account_id, r.account_id) and q.account_id.len > 0) row.approval = q.approval;
            }
            try out.append(arena, row);
        }
        for (p.participants) |q| {
            if (q.approval == .none and !q.isReviewer()) continue;
            var seen = false;
            for (out.items) |r| {
                if (std.mem.eql(u8, r.account_id, q.account_id) and q.account_id.len > 0) seen = true;
            }
            if (!seen) try out.append(arena, q);
        }
        return out.toOwnedSlice(arena);
    }

    /// Parse one `values[]` entry (list) or a whole PR (detail). The
    /// participant / reviewer slices are allocated on `arena`.
    pub fn fromValue(arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!Pr {
        var p: Pr = .{
            .id = j.int(v, "id", 0),
            .title = j.str(v, "title"),
            .state = j.str(v, "state"),
            .updated_on = j.str(v, "updated_on"),
            .author = j.pathStr(v, "author.display_name"),
            .author_account_id = j.pathStr(v, "author.account_id"),
            .source_branch = j.pathStr(v, "source.branch.name"),
            .dest_branch = j.pathStr(v, "destination.branch.name"),
            .html_url = j.pathStr(v, "links.html.href"),
            .description = j.renderable(v, "description"),
            .draft = j.boolean(v, "draft", false),
            .comment_count = j.int(v, "comment_count", 0),
            .task_count = j.int(v, "task_count", 0),
            .merge_commit = j.pathStr(v, "merge_commit.hash"),
            .source_commit = j.pathStr(v, "source.commit.hash"),
        };
        const dest_repo = j.pathStr(v, "destination.repository.full_name");
        p.repo_full_name = if (dest_repo.len > 0) dest_repo else j.pathStr(v, "source.repository.full_name");
        p.participants = try parseParticipants(arena, j.array(v, "participants"));
        p.reviewers = try parseUsers(arena, j.array(v, "reviewers"));
        return p;
    }

    fn parseParticipants(arena: std.mem.Allocator, items: []const Value) std.mem.Allocator.Error![]const Participant {
        const out = try arena.alloc(Participant, items.len);
        for (items, out) |v, *slot| slot.* = Participant.fromValue(v);
        return out;
    }

    /// `reviewers[]` is a bare user list, not a participant list.
    fn parseUsers(arena: std.mem.Allocator, items: []const Value) std.mem.Allocator.Error![]const Participant {
        const out = try arena.alloc(Participant, items.len);
        for (items, out) |v, *slot| slot.* = .{
            .display_name = j.str(v, "display_name"),
            .account_id = j.str(v, "account_id"),
            .role = "REVIEWER",
        };
        return out;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

pub const pr_detail_fixture =
    \\{"id":1234,"title":"Fix the login redirect","state":"OPEN","draft":false,
    \\ "updated_on":"2026-09-01T12:34:56.000+00:00","comment_count":3,"task_count":1,
    \\ "author":{"display_name":"Chris M","account_id":"acct-chris"},
    \\ "source":{"branch":{"name":"chris/fix-login"},"commit":{"hash":"abc1234def"},
    \\           "repository":{"full_name":"acme/api"}},
    \\ "destination":{"branch":{"name":"main"},"repository":{"full_name":"acme/api"}},
    \\ "links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/1234"}},
    \\ "description":{"raw":"Fixes ENG-4210. The redirect dropped the query string.","html":""},
    \\ "reviewers":[{"display_name":"Dana R","account_id":"acct-dana"},
    \\              {"display_name":"Sam K","account_id":"acct-sam"}],
    \\ "participants":[{"user":{"display_name":"Dana R","account_id":"acct-dana"},"role":"REVIEWER","approved":true,"state":"approved"},
    \\                 {"user":{"display_name":"Sam K","account_id":"acct-sam"},"role":"REVIEWER","approved":false,"state":"changes_requested"},
    \\                 {"user":{"display_name":"Chris M","account_id":"acct-chris"},"role":"PARTICIPANT","approved":false,"state":null}]}
;

test "a PR detail parses into the row the list paints and the votes the detail shows" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(Value, t.allocator, pr_detail_fixture, .{});
    defer parsed.deinit();
    const pr = try Pr.fromValue(arena.allocator(), parsed.value);
    try t.expectEqual(@as(i64, 1234), pr.id);
    try t.expectEqualStrings("Fix the login redirect", pr.title);
    try t.expectEqualStrings("acme/api", pr.repo_full_name);
    try t.expectEqualStrings("acme", pr.workspace());
    try t.expectEqualStrings("api", pr.repo());
    try t.expectEqualStrings("chris/fix-login", pr.source_branch);
    try t.expectEqualStrings("main", pr.dest_branch);
    try t.expectEqualStrings("2026-09-01", pr.updatedDate());
    try t.expectEqual(@as(usize, 1), pr.approvals());
    try t.expectEqual(@as(usize, 1), pr.changesRequested());
    try t.expectEqual(Approval.approved, pr.voteOf("acct-dana"));
    try t.expectEqual(Approval.changes_requested, pr.voteOf("acct-sam"));
    try t.expectEqual(Approval.none, pr.voteOf("acct-chris"));
    try t.expectEqual(Approval.none, pr.voteOf("nobody"));
    try t.expectEqual(Approval.none, pr.voteOf(""));
    const roster = try pr.reviewerRoster(arena.allocator());
    try t.expectEqual(@as(usize, 2), roster.len);
    try t.expectEqualStrings("Dana R", roster[0].display_name);
    try t.expectEqual(Approval.approved, roster[0].approval);
    try t.expectEqual(Approval.changes_requested, roster[1].approval);
}

test "a list row with no participants and a bare-string description still parses" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const text =
        \\{"id":9,"title":"WIP","state":"OPEN","description":"just a string","draft":true,
        \\ "source":{"branch":{"name":"wip"},"repository":{"full_name":"acme/web"}}}
    ;
    var parsed = try std.json.parseFromSlice(Value, t.allocator, text, .{});
    defer parsed.deinit();
    const pr = try Pr.fromValue(arena.allocator(), parsed.value);
    try t.expectEqualStrings("just a string", pr.description);
    try t.expect(pr.draft);
    try t.expectEqualStrings("acme/web", pr.repo_full_name);
    try t.expectEqualStrings("", pr.dest_branch);
    try t.expectEqual(@as(usize, 0), pr.approvals());
    // No participants and no reviewers: the roster is empty, not a crash.
    try t.expectEqual(@as(usize, 0), (try pr.reviewerRoster(arena.allocator())).len);
}

test "an activity list flattens comments, inline comments, approvals and updates into one stream" {
    const text =
        \\[{"comment":{"id":1,"user":{"display_name":"Dana R"},"created_on":"2026-09-01T10:00:00+00:00",
        \\             "content":{"raw":"Looks good"}}},
        \\ {"comment":{"id":2,"user":{"display_name":"Sam K"},"created_on":"2026-09-01T11:00:00+00:00",
        \\             "content":{"raw":"this leaks"},"parent":{"id":1},
        \\             "inline":{"path":"src/auth.zig","from":null,"to":42}}},
        \\ {"approval":{"user":{"display_name":"Dana R"},"date":"2026-09-01T12:00:00+00:00"}},
        \\ {"changes_requested":{"user":{"display_name":"Sam K"},"date":"2026-09-01T12:30:00+00:00"}},
        \\ {"update":{"author":{"display_name":"Chris M"},"date":"2026-09-01T13:00:00+00:00","state":"OPEN","description":""}}]
    ;
    var parsed = try std.json.parseFromSlice(Value, t.allocator, text, .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    const a0 = Activity.fromValue(items[0]);
    try t.expectEqual(Activity.Kind.comment, a0.kind);
    try t.expectEqualStrings("Looks good", a0.text);
    try t.expect(!a0.isInline());
    try t.expectEqual(@as(i64, 0), a0.parent_id);
    const a1 = Activity.fromValue(items[1]);
    try t.expect(a1.isInline());
    try t.expectEqualStrings("src/auth.zig", a1.inline_path);
    try t.expectEqual(@as(i64, 42), a1.inlineLine().?);
    try t.expectEqual(@as(i64, 1), a1.parent_id);
    try t.expectEqual(Activity.Kind.approval, Activity.fromValue(items[2]).kind);
    try t.expectEqual(Activity.Kind.changes_requested, Activity.fromValue(items[3]).kind);
    const a4 = Activity.fromValue(items[4]);
    try t.expectEqual(Activity.Kind.update, a4.kind);
    try t.expectEqualStrings("OPEN", a4.text);
}

test "build statuses and diffstat entries carry a glyph the list can paint" {
    const text =
        \\{"statuses":[{"key":"pipe-1","name":"Pipeline #12","state":"SUCCESSFUL"},
        \\             {"key":"pipe-2","name":"Deploy","state":"FAILED"},
        \\             {"key":"pipe-3","name":"Lint","state":"INPROGRESS"},
        \\             {"key":"pipe-4","name":"Old","state":"STOPPED"},
        \\             {"key":"pipe-5","name":"Odd","state":"WAT"}],
        \\ "diffstat":[{"status":"modified","lines_added":12,"lines_removed":3,"new":{"path":"src/auth.zig"},"old":{"path":"src/auth.zig"}},
        \\             {"status":"added","lines_added":40,"lines_removed":0,"new":{"path":"src/new.zig"},"old":null},
        \\             {"status":"removed","lines_added":0,"lines_removed":9,"new":null,"old":{"path":"src/old.zig"}},
        \\             {"status":"renamed","lines_added":1,"lines_removed":1,"new":{"path":"b.zig"},"old":{"path":"a.zig"}}]}
    ;
    var parsed = try std.json.parseFromSlice(Value, t.allocator, text, .{});
    defer parsed.deinit();
    const st = j.array(parsed.value, "statuses");
    try t.expectEqualStrings("●", BuildStatus.fromValue(st[0]).glyph());
    try t.expectEqualStrings("✖", BuildStatus.fromValue(st[1]).glyph());
    try t.expectEqualStrings("◐", BuildStatus.fromValue(st[2]).glyph());
    try t.expectEqualStrings("■", BuildStatus.fromValue(st[3]).glyph());
    try t.expectEqualStrings("○", BuildStatus.fromValue(st[4]).glyph());
    try t.expectEqualStrings("Pipeline #12", BuildStatus.fromValue(st[0]).name);
    const ds = j.array(parsed.value, "diffstat");
    const e0 = DiffstatEntry.fromValue(ds[0]);
    try t.expectEqualStrings("src/auth.zig", e0.path);
    try t.expectEqual(@as(i64, 12), e0.added);
    try t.expectEqualStrings("~", e0.glyph());
    try t.expectEqualStrings("+", DiffstatEntry.fromValue(ds[1]).glyph());
    // A removed file has no `new`, so the path falls back to `old`.
    const e2 = DiffstatEntry.fromValue(ds[2]);
    try t.expectEqualStrings("src/old.zig", e2.path);
    try t.expectEqualStrings("-", e2.glyph());
    const e3 = DiffstatEntry.fromValue(ds[3]);
    try t.expectEqualStrings("→", e3.glyph());
    try t.expectEqualStrings("a.zig", e3.old_path);
}

test "the approval glyphs and labels are the three the detail paints" {
    try t.expectEqualStrings("✓", Approval.approved.glyph());
    try t.expectEqualStrings("✗", Approval.changes_requested.glyph());
    try t.expectEqualStrings("○", Approval.none.glyph());
    try t.expectEqualStrings("changes requested", Approval.changes_requested.label());
}
