//! The things the pane shows, parsed once out of Jira's JSON: a ticket,
//! a linked pull request, a post-merge pipeline, a transition, a board,
//! a sprint, a quick filter, a version, a ticket's detail. Every slice
//! lives on the arena the parse was given — the refresh arena for a
//! tab's tickets, a picker's arena for its rows — and nothing here
//! knows about frames or keys.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const text = @import("text.zig");

pub const Value = std.json.Value;

/// The account id standing for "no assignee" in an assignee filter.
pub const unassigned_sentinel = "__unassigned__";

pub const User = struct {
    account_id: []const u8 = "",
    display_name: []const u8 = "",

    pub fn fromJson(v: ?Value) ?User {
        const val = v orelse return null;
        if (val == .null) return null;
        return .{ .account_id = json.getStrOr(val, "accountId", ""), .display_name = json.getStrOr(val, "displayName", "") };
    }
};

pub const Issue = struct {
    id: []const u8 = "",
    key: []const u8 = "",
    summary: []const u8 = "",
    status: []const u8 = "",
    status_category: []const u8 = "",
    issuetype: []const u8 = "",
    priority: []const u8 = "",
    updated: []const u8 = "",
    created: []const u8 = "",
    assignee: ?User = null,
    reporter: ?User = null,
    fix_versions: []const []const u8 = &.{},
    components: []const []const u8 = &.{},
    labels: []const []const u8 = &.{},
    /// The `parent` field: key, summary and issue type (an epic on a
    /// team-managed project, a story for a sub-task).
    parent_key: []const u8 = "",
    parent_summary: []const u8 = "",
    parent_type: []const u8 = "",
    /// The team select's `value`, when the config names the field.
    team: []const u8 = "",
    /// The sprint name(s), when the search carried them.
    sprint: []const u8 = "",
    /// The whole issue object, for the detail modal's custom fields.
    raw: Value = .null,

    pub fn fromJson(arena: Allocator, v: Value, team_field_id: []const u8) Allocator.Error!Issue {
        var i: Issue = .{
            .id = json.getStrOr(v, "id", ""),
            .key = json.getStrOr(v, "key", ""),
            .summary = json.getStrOr(v, "fields.summary", ""),
            .status = json.getStrOr(v, "fields.status.name", ""),
            .status_category = json.getStrOr(v, "fields.status.statusCategory.key", ""),
            .issuetype = json.getStrOr(v, "fields.issuetype.name", ""),
            .priority = json.getStrOr(v, "fields.priority.name", ""),
            .updated = json.getStrOr(v, "fields.updated", ""),
            .created = json.getStrOr(v, "fields.created", ""),
            .assignee = User.fromJson(json.get(v, "fields.assignee")),
            .reporter = User.fromJson(json.get(v, "fields.reporter")),
            .fix_versions = try names(arena, json.array(v, "fields.fixVersions")),
            .components = try names(arena, json.array(v, "fields.components")),
            .labels = try strings(arena, json.array(v, "fields.labels")),
            .parent_key = json.getStrOr(v, "fields.parent.key", ""),
            .parent_summary = json.getStrOr(v, "fields.parent.fields.summary", ""),
            .parent_type = json.getStrOr(v, "fields.parent.fields.issuetype.name", ""),
            .raw = v,
        };
        if (team_field_id.len > 0) {
            if (json.get(v, "fields")) |f| if (json.get(f, team_field_id)) |tv| {
                i.team = json.getStrOr(tv, "value", "");
            };
        }
        i.sprint = try sprintLabel(arena, json.get(v, "fields.customfield_10020"));
        return i;
    }

    /// Not Done / Closed / Resolved / Released — the reference's set.
    pub fn isUnresolved(i: Issue) bool {
        return !isTerminalStatus(i.status);
    }

    pub fn assigneeName(i: Issue) []const u8 {
        if (i.assignee) |a| if (a.display_name.len > 0) return a.display_name;
        return "—";
    }

    pub fn assigneeId(i: Issue) []const u8 {
        if (i.assignee) |a| return a.account_id;
        return "";
    }

    pub fn reporterName(i: Issue) []const u8 {
        if (i.reporter) |r| if (r.display_name.len > 0) return r.display_name;
        return "—";
    }

    /// The parent epic's key: a `parent` whose type is Epic (or has no
    /// type — the legacy epic-link shape).
    pub fn epicKey(i: Issue) ?[]const u8 {
        if (i.parent_key.len == 0 or !looksLikeIssueKey(i.parent_key)) return null;
        if (i.parent_type.len > 0 and !std.ascii.eqlIgnoreCase(i.parent_type, "Epic")) return null;
        return i.parent_key;
    }

    pub fn updatedDay(i: Issue) []const u8 {
        return text.dayOf(i.updated);
    }
};

pub fn isTerminalStatus(status: []const u8) bool {
    return std.ascii.eqlIgnoreCase(status, "done") or std.ascii.eqlIgnoreCase(status, "closed") or
        std.ascii.eqlIgnoreCase(status, "resolved") or std.ascii.eqlIgnoreCase(status, "released");
}

/// `ABC-123`: upper-case letters, a hyphen, digits.
pub fn looksLikeIssueKey(s: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return false;
    if (dash == 0 or dash + 1 >= s.len) return false;
    for (s[0..dash]) |c| if (!std.ascii.isUpper(c)) return false;
    for (s[dash + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `ENG-1234` → `ENG`.
pub fn projectOf(key: []const u8) ?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, key, '-') orelse return null;
    if (dash == 0) return null;
    return key[0..dash];
}

pub fn issueUrl(arena: Allocator, base: []const u8, key: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/browse/{s}", .{ base, key });
}

fn names(arena: Allocator, items: []const Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |x| {
        const n = json.getStrOr(x, "name", "");
        if (n.len > 0) try out.append(arena, n);
    }
    return out.toOwnedSlice(arena);
}

fn strings(arena: Allocator, items: []const Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |x| if (json.str(x)) |s| try out.append(arena, s);
    return out.toOwnedSlice(arena);
}

/// The sprint field: objects with a `name`, or the legacy
/// `com.atlassian.greenhopper…[id=1,…,name=Sprint 3,…]` strings.
pub fn sprintLabel(arena: Allocator, v: ?Value) Allocator.Error![]const u8 {
    const val = v orelse return "";
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => return "",
    };
    var out: std.ArrayList(u8) = .empty;
    for (items) |s| {
        var name: []const u8 = "";
        if (json.str(s)) |raw| {
            if (std.mem.indexOf(u8, raw, "name=")) |at| {
                const tail = raw[at + 5 ..];
                name = tail[0 .. std.mem.indexOfScalar(u8, tail, ',') orelse tail.len];
            } else name = raw;
        } else name = json.getStrOr(s, "name", "");
        if (name.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, name);
    }
    return out.toOwnedSlice(arena);
}

// ─── pull requests and pipelines ─────────────────────────────────────────

pub const Reviewer = struct { name: []const u8 = "", approved: bool = false };

pub const LinkedPr = struct {
    /// `#2023`, as the dev panel spells it.
    id: []const u8 = "",
    name: []const u8 = "",
    status: []const u8 = "",
    url: []const u8 = "",
    repo: []const u8 = "",
    source_branch: []const u8 = "",
    dest_branch: []const u8 = "",
    reviewers: []const Reviewer = &.{},

    pub fn fromJson(arena: Allocator, p: Value) Allocator.Error!LinkedPr {
        var rs: std.ArrayList(Reviewer) = .empty;
        for (json.array(p, "reviewers")) |r| try rs.append(arena, .{
            .name = json.getStrOr(r, "name", ""),
            .approved = json.getBool(r, "approved") orelse false,
        });
        return .{
            .id = json.getStrOr(p, "id", ""),
            .name = json.getStrOr(p, "name", ""),
            .status = json.getStrOr(p, "status", ""),
            .url = json.getStrOr(p, "url", ""),
            .repo = json.getStrOr(p, "repositoryName", ""),
            .source_branch = json.getStrOr(p, "source.branch", ""),
            .dest_branch = json.getStrOr(p, "destination.branch", ""),
            .reviewers = try rs.toOwnedSlice(arena),
        };
    }

    pub fn approvals(p: LinkedPr) u16 {
        var n: u16 = 0;
        for (p.reviewers) |r| n += @intFromBool(r.approved);
        return n;
    }

    pub fn isApproved(p: LinkedPr) bool {
        return p.approvals() > 0;
    }

    pub fn isOpen(p: LinkedPr) bool {
        return std.ascii.eqlIgnoreCase(p.status, "OPEN") or std.ascii.eqlIgnoreCase(p.status, "DRAFT") or std.ascii.eqlIgnoreCase(p.status, "IN_REVIEW");
    }

    pub fn isMerged(p: LinkedPr) bool {
        return std.ascii.eqlIgnoreCase(p.status, "MERGED");
    }
};

pub const Pipeline = struct {
    uuid: []const u8 = "",
    build_number: i64 = 0,
    state: []const u8 = "",
    result: []const u8 = "",
    branch: []const u8 = "",
    commit: []const u8 = "",
    created_on: []const u8 = "",
    duration_secs: i64 = 0,

    pub fn fromJson(p: Value) Pipeline {
        return .{
            .uuid = json.getStrOr(p, "uuid", ""),
            .build_number = json.getInt(p, "build_number") orelse 0,
            .state = json.getStrOr(p, "state.name", ""),
            .result = json.getStrOr(p, "state.result.name", ""),
            .branch = json.getStrOr(p, "target.ref_name", ""),
            .commit = json.getStrOr(p, "target.commit.hash", ""),
            .created_on = json.getStrOr(p, "created_on", ""),
            .duration_secs = json.getInt(p, "duration_in_seconds") orelse 0,
        };
    }

    /// `SUCCESSFUL` / `FAILED` over `COMPLETED`; the lifecycle name otherwise.
    pub fn stateLabel(p: Pipeline) []const u8 {
        if (p.result.len > 0) return p.result;
        if (p.state.len > 0) return p.state;
        return "UNKNOWN";
    }

    pub fn branchLabel(p: Pipeline) []const u8 {
        return if (p.branch.len > 0) p.branch else "—";
    }

    pub fn createdDate(p: Pipeline) []const u8 {
        return text.dayOf(p.created_on);
    }

    /// `3m 45s`, `12s`, `—`.
    pub fn durationLabel(p: Pipeline, buf: []u8) []const u8 {
        if (p.duration_secs <= 0) return "—";
        const m: u64 = @intCast(@divTrunc(p.duration_secs, 60));
        const r: u64 = @intCast(@mod(p.duration_secs, 60));
        if (m > 0) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ m, r }) catch "—";
        return std.fmt.bufPrint(buf, "{d}s", .{r}) catch "—";
    }
};

pub const Transition = struct { id: []const u8, name: []const u8, to_name: []const u8 };

pub const Board = struct {
    id: u64,
    name: []const u8,
    /// scrum / kanban / simple.
    kind: []const u8 = "",
};

pub const Sprint = struct {
    id: u64,
    name: []const u8,
    state: []const u8 = "",
    start_date: []const u8 = "",
    end_date: []const u8 = "",
    complete_date: []const u8 = "",

    pub fn isActive(s: Sprint) bool {
        return std.ascii.eqlIgnoreCase(s.state, "active");
    }

    fn bucket(s: Sprint) u8 {
        if (std.ascii.eqlIgnoreCase(s.state, "active")) return 0;
        if (std.ascii.eqlIgnoreCase(s.state, "future")) return 1;
        return 2;
    }

    fn before(_: void, a: Sprint, b: Sprint) bool {
        const ba = a.bucket();
        const bb = b.bucket();
        if (ba != bb) return ba < bb;
        if (ba < 2) {
            const c = cmpIsoAsc(a.start_date, b.start_date);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
        const ac = if (a.complete_date.len > 0) a.complete_date else a.end_date;
        const bc = if (b.complete_date.len > 0) b.complete_date else b.end_date;
        const c = cmpIsoAsc(ac, bc);
        if (c != .eq) return c == .gt;
        return std.mem.order(u8, a.name, b.name) == .gt;
    }

    /// The picker's order: active, future by start, then the last N
    /// closed — most recently closed first.
    pub fn sortForPicker(arena: Allocator, list: []const Sprint, last_n_closed: usize) Allocator.Error![]const Sprint {
        const copy = try arena.dupe(Sprint, list);
        std.mem.sort(Sprint, copy, {}, before);
        var out: std.ArrayList(Sprint) = .empty;
        var closed: usize = 0;
        for (copy) |s| {
            if (s.bucket() == 2) {
                closed += 1;
                if (closed > last_n_closed) continue;
            }
            try out.append(arena, s);
        }
        return out.toOwnedSlice(arena);
    }
};

/// Ascending with the empty (undated) last.
fn cmpIsoAsc(a: []const u8, b: []const u8) std.math.Order {
    if (a.len > 0 and b.len > 0) return std.mem.order(u8, a, b);
    if (a.len > 0) return .lt;
    if (b.len > 0) return .gt;
    return .eq;
}

pub const QuickFilter = struct { id: u64, name: []const u8, jql: []const u8 = "" };

pub const Version = struct {
    name: []const u8,
    released: bool = false,
    archived: bool = false,
    start_date: []const u8 = "",
    release_date: []const u8 = "",
};

pub const Comment = struct { author: []const u8, created: []const u8, body: []const u8 };

pub const IssueDetail = struct {
    description: []const u8 = "",
    comments: []const Comment = &.{},
    watching: bool = false,
    watch_count: u32 = 0,
    /// Set when the fetch failed; the pane says so instead of nothing.
    error_text: []const u8 = "",

    pub fn fromJson(arena: Allocator, v: Value) Allocator.Error!IssueDetail {
        var cs: std.ArrayList(Comment) = .empty;
        for (json.array(v, "fields.comment.comments")) |c| try cs.append(arena, .{
            .author = json.getStrOr(c, "author.displayName", "?"),
            .created = json.getStrOr(c, "created", ""),
            .body = try adfToText(arena, json.get(c, "body")),
        });
        return .{
            .description = try adfToText(arena, json.get(v, "fields.description")),
            .comments = try cs.toOwnedSlice(arena),
            .watching = json.getBool(v, "fields.watches.isWatching") orelse false,
            .watch_count = @intCast(@max(json.getInt(v, "fields.watches.watchCount") orelse 0, 0)),
        };
    }
};

/// Atlassian Document Format → text: every `text` leaf, a newline after
/// each block. A plain string (v2, or an old site) is returned as is.
pub fn adfToText(arena: Allocator, v: ?Value) Allocator.Error![]const u8 {
    const val = v orelse return "";
    if (val == .null) return "";
    if (json.str(val)) |s| return s;
    var out: std.ArrayList(u8) = .empty;
    try walkAdf(arena, &out, val);
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn walkAdf(arena: Allocator, out: *std.ArrayList(u8), node: Value) Allocator.Error!void {
    switch (node) {
        .array => |a| for (a.items) |x| try walkAdf(arena, out, x),
        .object => |o| {
            if (o.get("text")) |t| if (json.str(t)) |s| try out.appendSlice(arena, s);
            if (o.get("content")) |c| try walkAdf(arena, out, c);
            const kind = if (o.get("type")) |t| (json.str(t) orelse "") else "";
            const block = std.mem.eql(u8, kind, "paragraph") or std.mem.eql(u8, kind, "heading") or std.mem.eql(u8, kind, "codeBlock") or
                std.mem.eql(u8, kind, "blockquote") or std.mem.eql(u8, kind, "rule") or std.mem.eql(u8, kind, "listItem") or
                std.mem.eql(u8, kind, "bulletList") or std.mem.eql(u8, kind, "orderedList") or std.mem.eql(u8, kind, "hardBreak");
            if (block and (out.items.len == 0 or out.items[out.items.len - 1] != '\n')) try out.append(arena, '\n');
        },
        else => {},
    }
}

/// A field of the raw issue object as the detail modal shows it: a
/// string, `{name}`, `[{name}]`, a user's display name, ADF, a select's
/// `{value}`; `—` when it is not there.
pub fn fieldDisplay(arena: Allocator, raw: Value, field_id: []const u8) Allocator.Error![]const u8 {
    const fields = json.get(raw, "fields") orelse return "—";
    if (std.mem.eql(u8, field_id, "summary") or std.mem.eql(u8, field_id, "title")) return json.getStrOr(fields, "summary", "—");
    if (std.mem.eql(u8, field_id, "status")) return json.getStrOr(fields, "status.name", "—");
    if (std.mem.eql(u8, field_id, "type") or std.mem.eql(u8, field_id, "issuetype")) return json.getStrOr(fields, "issuetype.name", "—");
    if (std.mem.eql(u8, field_id, "priority")) return json.getStrOr(fields, "priority.name", "—");
    if (std.mem.eql(u8, field_id, "assignee")) return json.getStrOr(fields, "assignee.displayName", "—");
    if (std.mem.eql(u8, field_id, "reporter")) return json.getStrOr(fields, "reporter.displayName", "—");
    if (std.mem.eql(u8, field_id, "labels")) return joinOrDash(arena, try strings(arena, json.array(fields, "labels")));
    if (std.mem.eql(u8, field_id, "components")) return joinOrDash(arena, try names(arena, json.array(fields, "components")));
    if (std.mem.eql(u8, field_id, "fix_version") or std.mem.eql(u8, field_id, "fixversions") or std.mem.eql(u8, field_id, "fixVersions")) return joinOrDash(arena, try names(arena, json.array(fields, "fixVersions")));
    if (std.mem.eql(u8, field_id, "sprint")) {
        const s = try sprintLabel(arena, json.get(fields, "customfield_10020"));
        return if (s.len > 0) s else "—";
    }
    if (std.mem.eql(u8, field_id, "parent")) return json.getStrOr(fields, "parent.fields.summary", "—");
    if (std.mem.eql(u8, field_id, "description") or std.mem.eql(u8, field_id, "environment")) {
        const t = try adfToText(arena, json.get(fields, field_id));
        return if (std.mem.trim(u8, t, " \n").len > 0) t else "—";
    }
    const v = json.get(fields, field_id) orelse return "—";
    return switch (v) {
        .null => "—",
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .object => |o| blk: {
            if (o.get("value")) |x| if (json.str(x)) |s| break :blk s;
            if (o.get("name")) |x| if (json.str(x)) |s| break :blk s;
            if (o.get("displayName")) |x| if (json.str(x)) |s| break :blk s;
            if (o.get("content") != null) {
                const t = try adfToText(arena, v);
                break :blk if (t.len > 0) t else "—";
            }
            break :blk try json.renderBody(arena, v);
        },
        .array => |a| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (a.items) |x| {
                const s = json.str(x) orelse json.getStr(x, "name") orelse json.getStr(x, "value") orelse continue;
                if (out.items.len > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, s);
            }
            break :blk if (out.items.len > 0) out.items else "—";
        },
        else => "—",
    };
}

fn joinOrDash(arena: Allocator, items: []const []const u8) Allocator.Error![]const u8 {
    if (items.len == 0) return "—";
    return std.mem.join(arena, ", ", items);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseIssue(arena: Allocator, src: []const u8, team_field: []const u8) !Issue {
    const v = try std.json.parseFromSliceLeaky(Value, arena, src, .{});
    return Issue.fromJson(arena, v, team_field);
}

test "an issue reads its fields, its parent epic, the team select and the sprint" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const i = try parseIssue(a.allocator(),
        \\{"id":"1","key":"ENG-9","fields":{"summary":"s","status":{"name":"In PR Review","statusCategory":{"key":"indeterminate"}},
        \\ "issuetype":{"name":"Bug"},"priority":{"name":"High"},"updated":"2026-09-15T09:00:00.000+0000",
        \\ "assignee":{"accountId":"a1","displayName":"Ada"},"reporter":null,"fixVersions":[{"name":"2.8.0"}],
        \\ "components":[{"name":"web"}],"labels":["admin","tools"],"parent":{"key":"ENG-1","fields":{"summary":"Epic one","issuetype":{"name":"Epic"}}},
        \\ "customfield_10056":{"value":"Apollo"},"customfield_10020":[{"name":"Sprint 3"},"com.atlassian.greenhopper.service.sprint.Sprint@1[id=2,name=Sprint 4,state=CLOSED]"]}}
    , "customfield_10056");
    try testing.expectEqualStrings("ENG-9", i.key);
    try testing.expectEqualStrings("In PR Review", i.status);
    try testing.expectEqualStrings("Ada", i.assigneeName());
    try testing.expectEqualStrings("—", i.reporterName());
    try testing.expectEqualStrings("2.8.0", i.fix_versions[0]);
    try testing.expectEqualStrings("tools", i.labels[1]);
    try testing.expectEqualStrings("ENG-1", i.epicKey().?);
    try testing.expectEqualStrings("Apollo", i.team);
    try testing.expectEqualStrings("Sprint 3, Sprint 4", i.sprint);
    try testing.expectEqualStrings("2026-09-15", i.updatedDay());
    try testing.expect(i.isUnresolved());
    // A parent that is a story is not an epic.
    const sub = try parseIssue(a.allocator(), "{\"key\":\"ENG-2\",\"fields\":{\"parent\":{\"key\":\"ENG-3\",\"fields\":{\"issuetype\":{\"name\":\"Story\"}}},\"status\":{\"name\":\"Done\"}}}", "");
    try testing.expect(sub.epicKey() == null);
    try testing.expect(!sub.isUnresolved());
    try testing.expectEqualStrings("ENG", projectOf("ENG-2").?);
    try testing.expect(looksLikeIssueKey("NTL-12") and !looksLikeIssueKey("2026-08-21") and !looksLikeIssueKey("x"));
}

test "a linked PR knows its approvals and its openness; a pipeline its label, day and duration" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, a.allocator(),
        \\{"id":"#12","name":"n","status":"MERGED","url":"u","repositoryName":"web","source":{"branch":"f"},"destination":{"branch":"main"},
        \\ "reviewers":[{"name":"A","approved":true},{"name":"B","approved":false}]}
    , .{});
    const pr = try LinkedPr.fromJson(a.allocator(), v);
    try testing.expectEqual(@as(u16, 1), pr.approvals());
    try testing.expect(pr.isApproved() and pr.isMerged() and !pr.isOpen());
    // Openness is the three states the reference gives a Merge chip to.
    for ([_][]const u8{ "OPEN", "open", "DRAFT", "IN_REVIEW" }) |st| {
        const open_pr: LinkedPr = .{ .status = st };
        try testing.expect(open_pr.isOpen() and !open_pr.isMerged() and !open_pr.isApproved());
    }
    for ([_][]const u8{ "DECLINED", "SUPERSEDED", "" }) |st| {
        const shut: LinkedPr = .{ .status = st };
        try testing.expect(!shut.isOpen() and !shut.isMerged());
    }
    var p: Pipeline = .{ .state = "COMPLETED", .result = "SUCCESSFUL", .created_on = "2026-07-29T10:23:11.000+0000", .duration_secs = 225 };
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("SUCCESSFUL", p.stateLabel());
    try testing.expectEqualStrings("2026-07-29", p.createdDate());
    try testing.expectEqualStrings("3m 45s", p.durationLabel(&buf));
    p.result = "";
    p.state = "IN_PROGRESS";
    p.duration_secs = 12;
    try testing.expectEqualStrings("IN_PROGRESS", p.stateLabel());
    try testing.expectEqualStrings("12s", p.durationLabel(&buf));
    try testing.expectEqualStrings("—", p.branchLabel());
}

test "sprints sort active, future by start, then the last N closed newest first" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const list = [_]Sprint{
        .{ .id = 4, .name = "S4", .state = "closed", .start_date = "2026-06-01", .complete_date = "2026-06-14" },
        .{ .id = 1, .name = "S1", .state = "closed", .start_date = "2026-05-01", .complete_date = "2026-05-14" },
        .{ .id = 6, .name = "S6", .state = "future", .start_date = "2026-08-15" },
        .{ .id = 5, .name = "S5", .state = "future", .start_date = "2026-08-01" },
        .{ .id = 9, .name = "S9", .state = "active", .start_date = "2026-07-15" },
        .{ .id = 2, .name = "S2", .state = "closed", .start_date = "2026-05-15", .complete_date = "2026-05-28" },
    };
    const sorted = try Sprint.sortForPicker(a.allocator(), &list, 2);
    try testing.expectEqual(@as(usize, 5), sorted.len);
    try testing.expectEqual(@as(u64, 9), sorted[0].id);
    try testing.expectEqual(@as(u64, 5), sorted[1].id);
    try testing.expectEqual(@as(u64, 6), sorted[2].id);
    try testing.expectEqual(@as(u64, 4), sorted[3].id);
    try testing.expectEqual(@as(u64, 2), sorted[4].id);
}

test "ADF flattens to lines; the detail carries comments and watches; a field displays by shape" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, a.allocator(),
        \\{"fields":{"summary":"S","description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"two"}]}]}]}]},
        \\ "comment":{"comments":[{"author":{"displayName":"Sam"},"created":"2026-09-14T10:00:00.000+0000","body":"plain"}]},
        \\ "watches":{"watchCount":2,"isWatching":true},"labels":["a","b"],"fixVersions":[],"customfield_1":{"value":"Sel"},"customfield_2":[{"name":"x"},"y"],"customfield_3":null}}
    , .{});
    const d = try IssueDetail.fromJson(a.allocator(), v);
    try testing.expectEqualStrings("one\ntwo", d.description);
    try testing.expectEqual(@as(usize, 1), d.comments.len);
    try testing.expectEqualStrings("plain", d.comments[0].body);
    try testing.expect(d.watching);
    try testing.expectEqual(@as(u32, 2), d.watch_count);
    try testing.expectEqualStrings("a, b", try fieldDisplay(a.allocator(), v, "labels"));
    try testing.expectEqualStrings("—", try fieldDisplay(a.allocator(), v, "fix_version"));
    try testing.expectEqualStrings("Sel", try fieldDisplay(a.allocator(), v, "customfield_1"));
    try testing.expectEqualStrings("x, y", try fieldDisplay(a.allocator(), v, "customfield_2"));
    try testing.expectEqualStrings("—", try fieldDisplay(a.allocator(), v, "customfield_3"));
    try testing.expectEqualStrings("—", try fieldDisplay(a.allocator(), v, "customfield_9"));
    try testing.expectEqualStrings("one\ntwo", try fieldDisplay(a.allocator(), v, "description"));
}
