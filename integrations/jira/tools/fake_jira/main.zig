//! mnml-fake-jira — a deterministic Jira (and the corner of a forge the
//! pipeline rows need) on the loopback, so every test of the Jira
//! integration runs offline, and so `tools/jira-diff.sh` can run the
//! reference tracker and this port against one answer.
//!
//! It answers every route `src/jira.zig` and `src/bitbucket.zig` call,
//! out of one fixture: project `ENG`, twelve tickets across an epic, a
//! sprint, a backlog and two releases, six assignees, a team select, a
//! five-state workflow, a scrum board with sprints and quick filters
//! and a kanban board without, and one merged PR with a pipeline.
//! Nothing is random and nothing reads the clock: the same requests
//! always produce the same answers, except where a request
//! deliberately changed something — a transition, a comment, an
//! assignment, a fix version, a watch — which shows up in the next read.
//!
//!   mnml-fake-jira [--port N] [--port-file P] [--pid-file P]
//!                  [--life-secs N] [--no-auth] [--quiet] [--version]
//!
//! Loopback only. `--port 0` (the default) binds a free one, printed as
//! `mnml-fake-jira: listening on 127.0.0.1:NNNNN` and written to
//! `--port-file`. `--life-secs` bounds a server nobody stopped (it fires
//! on a request; a hard stop is the `--pid-file` pid or `/__shutdown`).
//!
//! `Store.handle` is the whole server as a pure function — method,
//! target, auth header, body in; status, content type, body out — so
//! the unit tests drive every route with no socket at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const version = "0.2.0";
/// `email:token` for `fake@acme.com` / `fake-token`, base64 — the Jira
/// credential the server accepts unless `--no-auth`.
pub const expected_auth = "Basic ZmFrZUBhY21lLmNvbTpmYWtlLXRva2Vu";
/// The forge token (`Bearer fake-forge`).
pub const expected_forge_auth = "Bearer fake-forge";

pub const account_me = "acct-me";
pub const account_sam = "acct-sam";
pub const account_lin = "acct-lin";
pub const account_pat = "acct-pat";
pub const account_mo = "acct-mo";
pub const account_jo = "acct-jo";

pub const board_scrum: u64 = 7;
pub const board_kanban: u64 = 8;
pub const sprint_active: u64 = 41;
pub const sprint_future: u64 = 42;
pub const filter_checkout: u64 = 10;

/// What the fixture holds, for the tests that count.
pub const issue_count: usize = 12;
pub const sprint_issue_count: usize = 9;
pub const user_count: usize = 6;

pub const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

pub const Issue = struct {
    id: []const u8,
    key: []const u8,
    summary: []const u8,
    kind: []const u8,
    status: []const u8,
    category: []const u8,
    assignee: []const u8,
    reporter: []const u8,
    priority: []const u8,
    updated: []const u8,
    created: []const u8,
    resolved: []const u8 = "",
    fix_version: []const u8,
    parent: []const u8 = "",
    description: []const u8 = "",
    labels: []const []const u8 = &.{},
    components: []const []const u8 = &.{},
    team: []const u8 = "",
    /// 0 = no sprint.
    sprint: u64 = 0,
    /// Newest last. Each is `author\x00created\x00body`.
    comments: std.ArrayList([]const u8) = .empty,
    /// Account ids.
    watchers: std.ArrayList([]const u8) = .empty,
};

const User = struct { id: []const u8, name: []const u8 };
pub const users = [_]User{
    .{ .id = account_me, .name = "Ada Lovelace" },
    .{ .id = account_sam, .name = "Sam Beckett" },
    .{ .id = account_lin, .name = "Lin Zhao" },
    .{ .id = account_pat, .name = "Pat Ruiz" },
    .{ .id = account_mo, .name = "Mo Idris" },
    .{ .id = account_jo, .name = "Jo Park" },
};

fn displayName(account: []const u8) []const u8 {
    for (users) |u| if (std.mem.eql(u8, u.id, account)) return u.name;
    return "";
}

const SprintRow = struct { id: u64, name: []const u8, state: []const u8, start: []const u8, end: []const u8, complete: []const u8 = "" };
pub const sprints = [_]SprintRow{
    .{ .id = 39, .name = "Sprint 2", .state = "closed", .start = "2026-08-17T00:00:00.000Z", .end = "2026-08-28T00:00:00.000Z", .complete = "2026-08-28T12:00:00.000Z" },
    .{ .id = 40, .name = "Sprint 3", .state = "closed", .start = "2026-08-31T00:00:00.000Z", .end = "2026-09-11T00:00:00.000Z", .complete = "2026-09-11T12:00:00.000Z" },
    .{ .id = sprint_active, .name = "Sprint 4", .state = "active", .start = "2026-09-14T00:00:00.000Z", .end = "2026-09-25T00:00:00.000Z" },
    .{ .id = sprint_future, .name = "Sprint 5", .state = "future", .start = "2026-09-28T00:00:00.000Z", .end = "2026-10-09T00:00:00.000Z" },
};

pub const Store = struct {
    gpa: Allocator,
    owned: std.heap.ArenaAllocator,
    issues: std.ArrayList(Issue) = .empty,
    require_auth: bool = true,
    /// When set, every route answers this status with a Jira error body.
    fail_with: ?u16 = null,
    requests: usize = 0,

    pub fn init(gpa: Allocator) Allocator.Error!Store {
        var s: Store = .{ .gpa = gpa, .owned = std.heap.ArenaAllocator.init(gpa) };
        errdefer s.owned.deinit();
        try s.seed();
        return s;
    }

    pub fn deinit(s: *Store) void {
        for (s.issues.items) |*i| {
            i.comments.deinit(s.gpa);
            i.watchers.deinit(s.gpa);
        }
        s.issues.deinit(s.gpa);
        s.owned.deinit();
        s.* = undefined;
    }

    fn keep(s: *Store, bytes: []const u8) Allocator.Error![]const u8 {
        return s.owned.allocator().dupe(u8, bytes);
    }

    fn seed(s: *Store) Allocator.Error!void {
        const rows = [_]Issue{
            .{ .id = "10001", .key = "ENG-1", .summary = "Checkout rewrite", .kind = "Epic", .status = "In Progress", .category = "indeterminate", .assignee = account_me, .reporter = account_sam, .priority = "High", .updated = "2026-09-15T09:00:00.000+0000", .created = "2026-08-01T09:00:00.000+0000", .fix_version = "13.16.0", .description = "The umbrella for the checkout work.", .labels = &.{"checkout"}, .team = "Apollo", .sprint = sprint_active },
            .{ .id = "10002", .key = "ENG-2", .summary = "Card form validates on blur", .kind = "Story", .status = "In PR Review", .category = "indeterminate", .assignee = account_me, .reporter = account_sam, .priority = "Medium", .updated = "2026-09-15T08:30:00.000+0000", .created = "2026-08-04T09:00:00.000+0000", .fix_version = "13.16.0", .parent = "ENG-1", .description = "Validate the card number when the field loses focus.", .labels = &.{ "checkout", "web" }, .components = &.{"web"}, .team = "Apollo", .sprint = sprint_active },
            .{ .id = "10003", .key = "ENG-3", .summary = "Apple Pay button on the basket", .kind = "Story", .status = "To Do", .category = "new", .assignee = "", .reporter = account_me, .priority = "Low", .updated = "2026-09-12T11:00:00.000+0000", .created = "2026-08-06T09:00:00.000+0000", .fix_version = "13.16.0", .parent = "ENG-1", .team = "Apollo", .sprint = sprint_active },
            .{ .id = "10004", .key = "ENG-4", .summary = "Wire the blur handler", .kind = "Sub-task", .status = "Done", .category = "done", .assignee = account_sam, .reporter = account_me, .priority = "Medium", .updated = "2026-09-14T16:00:00.000+0000", .created = "2026-08-09T09:00:00.000+0000", .resolved = "2026-09-14T16:00:00.000+0000", .fix_version = "13.16.0", .parent = "ENG-2", .sprint = sprint_active },
            .{ .id = "10005", .key = "ENG-5", .summary = "Basket total wrong with a voucher", .kind = "Bug", .status = "To Do", .category = "new", .assignee = account_me, .reporter = account_sam, .priority = "Highest", .updated = "2026-09-15T07:15:00.000+0000", .created = "2026-09-15T07:00:00.000+0000", .fix_version = "13.15.0", .description = "Applying a percentage voucher double-counts the delivery line.", .labels = &.{"bug-bash"}, .sprint = sprint_active },
            .{ .id = "10006", .key = "ENG-6", .summary = "Rotate the payment keys", .kind = "Task", .status = "Testing", .category = "indeterminate", .assignee = account_lin, .reporter = account_sam, .priority = "High", .updated = "2026-09-15T06:00:00.000+0000", .created = "2026-08-20T09:00:00.000+0000", .fix_version = "13.16.0", .components = &.{"ops"}, .team = "Atlas", .sprint = sprint_active },
            .{ .id = "10007", .key = "ENG-7", .summary = "Receipt email has no total", .kind = "Bug", .status = "In Progress", .category = "indeterminate", .assignee = account_pat, .reporter = account_me, .priority = "Medium", .updated = "2026-09-14T12:00:00.000+0000", .created = "2026-09-01T09:00:00.000+0000", .fix_version = "13.16.0", .labels = &.{"email"}, .team = "Apollo", .sprint = sprint_active },
            .{ .id = "10008", .key = "ENG-8", .summary = "Gift cards at checkout", .kind = "Story", .status = "To Do", .category = "new", .assignee = account_mo, .reporter = account_sam, .priority = "Low", .updated = "2026-09-13T12:00:00.000+0000", .created = "2026-09-02T09:00:00.000+0000", .fix_version = "13.17.0", .parent = "ENG-1", .team = "Apollo", .sprint = sprint_active },
            .{ .id = "10009", .key = "ENG-9", .summary = "Upgrade the SDK", .kind = "Task", .status = "Done", .category = "done", .assignee = account_jo, .reporter = account_sam, .priority = "Low", .updated = "2026-09-13T09:00:00.000+0000", .created = "2026-08-25T09:00:00.000+0000", .resolved = "2026-09-13T09:00:00.000+0000", .fix_version = "13.16.0", .sprint = sprint_active },
            .{ .id = "10010", .key = "ENG-10", .summary = "Dark mode for the dashboard", .kind = "Task", .status = "To Do", .category = "new", .assignee = "", .reporter = account_sam, .priority = "Low", .updated = "2026-09-10T09:00:00.000+0000", .created = "2026-09-10T09:00:00.000+0000", .fix_version = "" },
            .{ .id = "10011", .key = "ENG-11", .summary = "Crash on rotate", .kind = "Bug", .status = "Reopened", .category = "new", .assignee = account_sam, .reporter = account_me, .priority = "High", .updated = "2026-09-11T09:00:00.000+0000", .created = "2026-08-15T09:00:00.000+0000", .fix_version = "" },
            .{ .id = "10012", .key = "ENG-12", .summary = "Voucher codes are case-sensitive", .kind = "Story", .status = "Done", .category = "done", .assignee = account_me, .reporter = account_sam, .priority = "Medium", .updated = "2026-09-14T10:00:00.000+0000", .created = "2026-08-28T09:00:00.000+0000", .resolved = "2026-09-14T10:00:00.000+0000", .fix_version = "13.16.0", .labels = &.{"checkout"}, .team = "Apollo" },
        };
        for (rows) |r| try s.issues.append(s.gpa, r);
        try s.issues.items[1].comments.append(s.gpa, try s.keep("Sam Beckett\x002026-09-14T10:00:00.000+0000\x00Left a note on the PR."));
        try s.issues.items[1].comments.append(s.gpa, try s.keep("Ada Lovelace\x002026-09-15T08:00:00.000+0000\x00Rebased and pushed."));
        try s.issues.items[1].watchers.append(s.gpa, account_me);
        try s.issues.items[1].watchers.append(s.gpa, account_sam);
    }

    pub fn find(s: *Store, key: []const u8) ?*Issue {
        for (s.issues.items) |*i| if (std.ascii.eqlIgnoreCase(i.key, key)) return i;
        return null;
    }

    fn findById(s: *Store, id: []const u8) ?*Issue {
        for (s.issues.items) |*i| if (std.mem.eql(u8, i.id, id)) return i;
        return null;
    }

    /// The whole server. `arena` owns everything in the answer.
    pub fn handle(s: *Store, arena: Allocator, method: std.http.Method, target: []const u8, authorization: ?[]const u8, body: []const u8) Allocator.Error!Response {
        s.requests += 1;
        const path = pathOf(target);
        const query = queryOf(target);
        if (std.mem.eql(u8, path, "/__shutdown")) return .{ .status = 200, .body = "{\"bye\":true}" };
        // The forge corner takes its own token.
        if (std.mem.startsWith(u8, path, "/2.0/")) return s.forge(arena, path, authorization);
        if (s.require_auth) {
            const a = authorization orelse "";
            if (!std.mem.eql(u8, a, expected_auth)) return err(arena, 401, "Client must be authenticated to access this resource.");
        }
        if (s.fail_with) |st| return err(arena, st, "the fake server was told to fail");

        if (std.mem.startsWith(u8, path, "/rest/dev-status/latest/issue/detail")) return s.devStatus(arena, query);
        if (std.mem.startsWith(u8, path, "/rest/agile/1.0/")) return s.agile(arena, path["/rest/agile/1.0/".len..], query);
        const api = apiTail(path) orelse return err(arena, 404, "no such endpoint");

        if (std.mem.eql(u8, api, "/myself")) return s.myself(arena);
        if (std.mem.eql(u8, api, "/search/jql") and method == .POST) return s.searchPost(arena, body);
        if (std.mem.eql(u8, api, "/search") and method == .GET) return s.searchGet(arena, query);
        if (std.mem.eql(u8, api, "/user/assignable/search")) return s.assignable(arena);
        if (std.mem.startsWith(u8, api, "/project/")) {
            const rest = api["/project/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return err(arena, 404, "no such project endpoint");
            if (!std.mem.eql(u8, rest[slash + 1 ..], "versions")) return err(arena, 404, "no such project endpoint");
            return s.versions(arena, rest[0..slash]);
        }
        if (std.mem.startsWith(u8, api, "/issue/")) {
            var rest = api["/issue/".len..];
            var sub: []const u8 = "";
            if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
                sub = rest[i + 1 ..];
                rest = rest[0..i];
            }
            const issue = s.find(rest) orelse return err(arena, 404, try std.fmt.allocPrint(arena, "Issue does not exist or you do not have permission to see it: {s}", .{rest}));
            if (sub.len == 0) return switch (method) {
                .GET => s.issueJson(arena, issue),
                .PUT => s.update(arena, issue, body),
                else => err(arena, 405, "method not allowed"),
            };
            if (std.mem.eql(u8, sub, "transitions")) return switch (method) {
                .GET => s.transitions(arena, issue),
                .POST => s.doTransition(arena, issue, body),
                else => err(arena, 405, "method not allowed"),
            };
            if (std.mem.eql(u8, sub, "comment") and method == .POST) return s.addComment(arena, issue, body);
            if (std.mem.eql(u8, sub, "watchers")) return switch (method) {
                .POST => s.watch(arena, issue),
                .DELETE => s.unwatch(arena, issue, paramOf(query, "accountId") orelse ""),
                else => err(arena, 405, "method not allowed"),
            };
            return err(arena, 404, "no such issue endpoint");
        }
        return err(arena, 404, "no such endpoint");
    }

    // ── routes ──────────────────────────────────────────────────────────

    fn myself(s: *Store, arena: Allocator) Allocator.Error!Response {
        _ = s;
        return .{ .status = 200, .body = try std.fmt.allocPrint(arena, "{{\"accountId\":\"{s}\",\"displayName\":\"Ada Lovelace\",\"emailAddress\":\"fake@acme.com\"}}", .{account_me}) };
    }

    fn searchPost(s: *Store, arena: Allocator, body: []const u8) Allocator.Error!Response {
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return err(arena, 400, "the search body was not JSON");
        const jql = switch (doc) {
            .object => |o| switch (o.get("jql") orelse std.json.Value{ .null = {} }) {
                .string => |v| v,
                else => "",
            },
            else => "",
        };
        return s.searchAnswer(arena, jql, true, null);
    }

    fn searchGet(s: *Store, arena: Allocator, query: []const u8) Allocator.Error!Response {
        const jql = try urlDecode(arena, paramOf(query, "jql") orelse "");
        return s.searchAnswer(arena, jql, false, null);
    }

    fn searchAnswer(s: *Store, arena: Allocator, jql: []const u8, v3: bool, only_sprint: ?u64) Allocator.Error!Response {
        var out: Io.Writer.Allocating = .init(arena);
        var w = &out.writer;
        var n: usize = 0;
        w.writeAll("{\"issues\":[") catch return error.OutOfMemory;
        for (s.issues.items) |*i| {
            if (only_sprint) |sp| if (i.sprint != sp) continue;
            if (!matches(i, jql)) continue;
            if (n > 0) w.writeAll(",") catch return error.OutOfMemory;
            try s.writeIssue(w, i, false);
            n += 1;
        }
        if (v3) {
            w.print("],\"isLast\":true,\"total\":{d}}}", .{n}) catch return error.OutOfMemory;
        } else {
            w.print("],\"startAt\":0,\"maxResults\":100,\"total\":{d}}}", .{n}) catch return error.OutOfMemory;
        }
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    fn issueJson(s: *Store, arena: Allocator, i: *Issue) Allocator.Error!Response {
        var out: Io.Writer.Allocating = .init(arena);
        try s.writeIssue(&out.writer, i, true);
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    fn transitions(s: *Store, arena: Allocator, i: *Issue) Allocator.Error!Response {
        _ = s;
        var out: Io.Writer.Allocating = .init(arena);
        var w = &out.writer;
        w.writeAll("{\"transitions\":[") catch return error.OutOfMemory;
        var first = true;
        for (workflow) |t| {
            if (std.mem.eql(u8, t.to, i.status)) continue;
            if (!first) w.writeAll(",") catch return error.OutOfMemory;
            first = false;
            w.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"to\":{{\"name\":\"{s}\",\"statusCategory\":{{\"key\":\"{s}\"}}}}}}", .{ t.id, t.name, t.to, t.category }) catch return error.OutOfMemory;
        }
        w.writeAll("]}") catch return error.OutOfMemory;
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    fn doTransition(s: *Store, arena: Allocator, i: *Issue, body: []const u8) Allocator.Error!Response {
        _ = s;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return err(arena, 400, "the transition body was not JSON");
        const id = switch (doc) {
            .object => |o| switch (o.get("transition") orelse std.json.Value{ .null = {} }) {
                .object => |t| switch (t.get("id") orelse std.json.Value{ .null = {} }) {
                    .string => |v| v,
                    else => "",
                },
                else => "",
            },
            else => "",
        };
        for (workflow) |t| if (std.mem.eql(u8, t.id, id)) {
            i.status = t.to;
            i.category = t.category;
            return .{ .status = 204, .body = "" };
        };
        return err(arena, 400, "Transition id is not valid for this issue's workflow.");
    }

    fn addComment(s: *Store, arena: Allocator, i: *Issue, body: []const u8) Allocator.Error!Response {
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return err(arena, 400, "the comment body was not JSON");
        const text = try flattenBody(arena, switch (doc) {
            .object => |o| o.get("body") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        });
        if (text.len == 0) return err(arena, 400, "comment: body is required");
        const line = try std.fmt.allocPrint(s.owned.allocator(), "Ada Lovelace\x002026-09-15T12:00:00.000+0000\x00{s}", .{text});
        try i.comments.append(s.gpa, line);
        return .{ .status = 201, .body = try std.fmt.allocPrint(arena, "{{\"id\":\"{d}\",\"body\":{{}}}}", .{i.comments.items.len}) };
    }

    fn watch(s: *Store, arena: Allocator, i: *Issue) Allocator.Error!Response {
        _ = arena;
        for (i.watchers.items) |wv| if (std.mem.eql(u8, wv, account_me)) return .{ .status = 204, .body = "" };
        try i.watchers.append(s.gpa, account_me);
        return .{ .status = 204, .body = "" };
    }

    fn unwatch(s: *Store, arena: Allocator, i: *Issue, account: []const u8) Allocator.Error!Response {
        _ = s;
        if (account.len == 0) return err(arena, 400, "accountId is required");
        var k: usize = 0;
        while (k < i.watchers.items.len) {
            if (std.mem.eql(u8, i.watchers.items[k], account)) {
                _ = i.watchers.orderedRemove(k);
            } else k += 1;
        }
        return .{ .status = 204, .body = "" };
    }

    fn isWatching(i: *const Issue) bool {
        for (i.watchers.items) |wv| if (std.mem.eql(u8, wv, account_me)) return true;
        return false;
    }

    /// `PUT /issue/{key}` — assignee and fixVersions.
    fn update(s: *Store, arena: Allocator, i: *Issue, body: []const u8) Allocator.Error!Response {
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return err(arena, 400, "the update body was not JSON");
        const fields = switch (doc) {
            .object => |o| o.get("fields") orelse return err(arena, 400, "fields is required"),
            else => return err(arena, 400, "fields is required"),
        };
        const obj = switch (fields) {
            .object => |o| o,
            else => return err(arena, 400, "fields must be an object"),
        };
        if (obj.get("assignee")) |a| switch (a) {
            .null => i.assignee = "",
            .object => |ao| {
                const id = switch (ao.get("accountId") orelse std.json.Value{ .null = {} }) {
                    .string => |v| v,
                    else => "",
                };
                if (displayName(id).len == 0) return err(arena, 400, "assignee: the account does not exist");
                i.assignee = try s.keep(id);
            },
            else => return err(arena, 400, "assignee: bad shape"),
        };
        if (obj.get("fixVersions")) |v| switch (v) {
            .array => |arr| {
                if (arr.items.len == 0) {
                    i.fix_version = "";
                } else {
                    const name = switch (arr.items[0]) {
                        .object => |vo| switch (vo.get("name") orelse std.json.Value{ .null = {} }) {
                            .string => |x| x,
                            else => "",
                        },
                        else => "",
                    };
                    i.fix_version = try s.keep(name);
                }
            },
            else => return err(arena, 400, "fixVersions: bad shape"),
        };
        return .{ .status = 204, .body = "" };
    }

    fn versions(s: *Store, arena: Allocator, project: []const u8) Allocator.Error!Response {
        _ = s;
        if (!std.mem.eql(u8, project, "ENG")) return err(arena, 404, "No project could be found with key 'PROJ'.");
        return .{ .status = 200, .body =
        \\[{"id":"1","name":"13.14.0","released":true,"archived":false,"startDate":"2026-08-01"},
        \\ {"id":"2","name":"13.15.0","released":false,"archived":false},
        \\ {"id":"3","name":"13.16.0","released":false,"archived":false,"startDate":"2026-09-01"},
        \\ {"id":"5","name":"13.17.0","released":false,"archived":false,"startDate":"2026-09-15"},
        \\ {"id":"4","name":"Mobile - 1.6.X","released":false,"archived":true}]
        };
    }

    fn assignable(s: *Store, arena: Allocator) Allocator.Error!Response {
        _ = s;
        var out: Io.Writer.Allocating = .init(arena);
        var w = &out.writer;
        w.writeAll("[") catch return error.OutOfMemory;
        for (users, 0..) |u, k| {
            if (k > 0) w.writeAll(",") catch return error.OutOfMemory;
            w.print("{{\"accountId\":\"{s}\",\"displayName\":\"{s}\"}}", .{ u.id, u.name }) catch return error.OutOfMemory;
        }
        w.writeAll(",{\"accountId\":\"\",\"displayName\":\"A legacy user with no id\"}]") catch return error.OutOfMemory;
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    /// Atlassian's dev panel. ENG-2 has two PRs, ENG-6 one merged PR.
    fn devStatus(s: *Store, arena: Allocator, query: []const u8) Allocator.Error!Response {
        const id = paramOf(query, "issueId") orelse return err(arena, 400, "issueId is required");
        const issue = s.findById(id) orelse return err(arena, 404, "no such issue");
        if (std.mem.eql(u8, issue.key, "ENG-2")) return .{ .status = 200, .body =
        \\{"detail":[{"pullRequests":[
        \\ {"id":"#2023","name":"Validate the card form on blur","status":"MERGED",
        \\  "url":"https://bitbucket.org/acme/checkout/pull-requests/2023",
        \\  "repositoryName":"checkout",
        \\  "source":{"branch":"feat/blur-validation"},"destination":{"branch":"main"},
        \\  "reviewers":[{"name":"Sam Beckett","approved":true},{"name":"Ada Lovelace","approved":true}]},
        \\ {"id":"#2044","name":"Follow-up: trim the whitespace","status":"OPEN",
        \\  "url":"https://bitbucket.org/acme/checkout/pull-requests/2044",
        \\  "repositoryName":"checkout",
        \\  "source":{"branch":"feat/trim"},"destination":{"branch":"main"},
        \\  "reviewers":[{"name":"Sam Beckett","approved":false}]}
        \\]}]}
        };
        if (std.mem.eql(u8, issue.key, "ENG-6")) return .{ .status = 200, .body =
        \\{"detail":[{"pullRequests":[
        \\ {"id":"#3001","name":"Rotate the payment keys","status":"MERGED",
        \\  "url":"https://bitbucket.org/acme/ops/pull-requests/3001",
        \\  "repositoryName":"ops",
        \\  "source":{"branch":"chore/rotate-keys"},"destination":{"branch":"main"},
        \\  "reviewers":[{"name":"Pat Ruiz","approved":false}]}
        \\]}]}
        };
        return .{ .status = 200, .body = "{\"detail\":[{\"pullRequests\":[]}]}" };
    }

    // ── the Agile API ────────────────────────────────────────────────────

    fn agile(s: *Store, arena: Allocator, tail: []const u8, query: []const u8) Allocator.Error!Response {
        if (std.mem.eql(u8, tail, "board")) {
            const project = paramOf(query, "projectKeyOrId") orelse "";
            if (!std.mem.eql(u8, project, "ENG")) return .{ .status = 200, .body = "{\"values\":[],\"isLast\":true}" };
            return .{ .status = 200, .body = try std.fmt.allocPrint(arena,
                \\{{"values":[{{"id":{d},"name":"Checkout board","type":"scrum"}},{{"id":{d},"name":"Ops","type":"kanban"}}],"isLast":true}}
            , .{ board_scrum, board_kanban }) };
        }
        if (!std.mem.startsWith(u8, tail, "board/")) return err(arena, 404, "no such agile endpoint");
        var rest = tail["board/".len..];
        var sub: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
            sub = rest[i + 1 ..];
            rest = rest[0..i];
        }
        const id = std.fmt.parseInt(u64, rest, 10) catch return err(arena, 404, "no such board");
        if (id != board_scrum and id != board_kanban) return err(arena, 404, try std.fmt.allocPrint(arena, "No board with id {d}", .{id}));
        const is_scrum = id == board_scrum;
        if (sub.len == 0) return .{ .status = 200, .body = try std.fmt.allocPrint(arena, "{{\"id\":{d},\"name\":\"{s}\",\"type\":\"{s}\"}}", .{ id, if (is_scrum) "Checkout board" else "Ops", if (is_scrum) "scrum" else "kanban" }) };
        if (std.mem.eql(u8, sub, "issue")) {
            const jql = try urlDecode(arena, paramOf(query, "jql") orelse "");
            if (is_scrum) return s.searchAnswer(arena, jql, false, sprint_active);
            // The kanban board: the backlog, no sprint.
            return s.searchAnswer(arena, try std.fmt.allocPrint(arena, "sprint is EMPTY AND status != Done {s}", .{jql}), false, null);
        }
        if (std.mem.eql(u8, sub, "sprint")) {
            if (!is_scrum) return err(arena, 400, "The board does not support sprints");
            const state = paramOf(query, "state") orelse "active,future,closed";
            const start = std.fmt.parseInt(usize, paramOf(query, "startAt") orelse "0", 10) catch 0;
            const max = std.fmt.parseInt(usize, paramOf(query, "maxResults") orelse "50", 10) catch 50;
            var out: Io.Writer.Allocating = .init(arena);
            var w = &out.writer;
            var total: usize = 0;
            var written: usize = 0;
            w.writeAll("{\"values\":[") catch return error.OutOfMemory;
            for (sprints) |sp| {
                if (std.mem.indexOf(u8, state, sp.state) == null) continue;
                defer total += 1;
                if (total < start or written >= max) continue;
                if (written > 0) w.writeAll(",") catch return error.OutOfMemory;
                written += 1;
                w.print("{{\"id\":{d},\"name\":\"{s}\",\"state\":\"{s}\",\"startDate\":\"{s}\",\"endDate\":\"{s}\"", .{ sp.id, sp.name, sp.state, sp.start, sp.end }) catch return error.OutOfMemory;
                if (sp.complete.len > 0) w.print(",\"completeDate\":\"{s}\"", .{sp.complete}) catch return error.OutOfMemory;
                w.print(",\"originBoardId\":{d}}}", .{board_scrum}) catch return error.OutOfMemory;
            }
            w.print("],\"total\":{d},\"isLast\":true}}", .{total}) catch return error.OutOfMemory;
            return .{ .status = 200, .body = try out.toOwnedSlice() };
        }
        if (std.mem.eql(u8, sub, "quickfilter")) {
            if (!is_scrum) return .{ .status = 200, .body = "{\"values\":[],\"isLast\":true}" };
            return .{ .status = 200, .body = try std.fmt.allocPrint(arena,
                \\{{"values":[{{"id":1,"name":"Only bugs","jql":"issuetype = Bug","boardId":{d}}},{{"id":2,"name":"Mine","jql":"assignee = currentUser()","boardId":{d}}}],"isLast":true}}
            , .{ board_scrum, board_scrum }) };
        }
        return err(arena, 404, "no such board endpoint");
    }

    // ── the forge corner ─────────────────────────────────────────────────

    fn forge(s: *Store, arena: Allocator, path: []const u8, authorization: ?[]const u8) Allocator.Error!Response {
        _ = s;
        _ = arena;
        const a = authorization orelse "";
        if (!std.mem.eql(u8, a, expected_forge_auth)) return .{ .status = 401, .body = "{\"type\":\"error\",\"error\":{\"message\":\"Access token expired.\"}}" };
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/checkout/pullrequests/2023")) return .{ .status = 200, .body = "{\"id\":2023,\"state\":\"MERGED\",\"merge_commit\":{\"hash\":\"abc123def456\"}}" };
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/checkout/pullrequests/2044")) return .{ .status = 200, .body = "{\"id\":2044,\"state\":\"OPEN\"}" };
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/ops/pullrequests/3001")) return .{ .status = 200, .body = "{\"id\":3001,\"state\":\"MERGED\",\"merge_commit\":{\"hash\":\"9f9f9f9f9f9f\"}}" };
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/checkout/pipelines/")) return .{ .status = 200, .body =
        \\{"values":[
        \\ {"uuid":"{p412}","build_number":412,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},"created_on":"2026-09-14T15:00:00.000000+00:00","duration_in_seconds":225,"target":{"ref_name":"main","commit":{"hash":"abc123def456789012345678901234567890abcd"}}},
        \\ {"uuid":"{p411}","build_number":411,"state":{"name":"COMPLETED","result":{"name":"FAILED"}},"created_on":"2026-09-14T14:00:00.000000+00:00","duration_in_seconds":80,"target":{"ref_name":"feat/blur-validation","commit":{"hash":"1111111111111111111111111111111111111111"}}}
        \\]}
        };
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/ops/pipelines/")) return .{ .status = 200, .body = "{\"values\":[]}" };
        return .{ .status = 404, .body = "{\"type\":\"error\",\"error\":{\"message\":\"Resource not found\"}}" };
    }

    // ── the issue shape ──────────────────────────────────────────────────

    fn writeIssue(s: *Store, w: *Io.Writer, i: *Issue, detail: bool) Allocator.Error!void {
        w.print("{{\"id\":\"{s}\",\"key\":\"{s}\",\"fields\":{{", .{ i.id, i.key }) catch return error.OutOfMemory;
        w.print("\"summary\":", .{}) catch return error.OutOfMemory;
        try writeJsonString(w, i.summary);
        w.print(",\"issuetype\":{{\"name\":\"{s}\",\"subtask\":{s}}}", .{ i.kind, if (std.mem.eql(u8, i.kind, "Sub-task")) "true" else "false" }) catch return error.OutOfMemory;
        w.print(",\"status\":{{\"name\":\"{s}\",\"statusCategory\":{{\"key\":\"{s}\"}}}}", .{ i.status, i.category }) catch return error.OutOfMemory;
        w.print(",\"priority\":{{\"name\":\"{s}\"}}", .{i.priority}) catch return error.OutOfMemory;
        if (i.assignee.len > 0) {
            w.print(",\"assignee\":{{\"accountId\":\"{s}\",\"displayName\":\"{s}\"}}", .{ i.assignee, displayName(i.assignee) }) catch return error.OutOfMemory;
        } else {
            w.writeAll(",\"assignee\":null") catch return error.OutOfMemory;
        }
        w.print(",\"reporter\":{{\"accountId\":\"{s}\",\"displayName\":\"{s}\"}}", .{ i.reporter, displayName(i.reporter) }) catch return error.OutOfMemory;
        w.print(",\"updated\":\"{s}\",\"created\":\"{s}\"", .{ i.updated, i.created }) catch return error.OutOfMemory;
        if (i.resolved.len > 0) {
            w.print(",\"resolutiondate\":\"{s}\",\"resolution\":{{\"name\":\"Done\"}}", .{i.resolved}) catch return error.OutOfMemory;
        } else {
            w.writeAll(",\"resolution\":null") catch return error.OutOfMemory;
        }
        if (i.fix_version.len > 0) {
            w.print(",\"fixVersions\":[{{\"name\":\"{s}\"}}]", .{i.fix_version}) catch return error.OutOfMemory;
        } else {
            w.writeAll(",\"fixVersions\":[]") catch return error.OutOfMemory;
        }
        w.writeAll(",\"components\":[") catch return error.OutOfMemory;
        for (i.components, 0..) |c, k| {
            if (k > 0) w.writeAll(",") catch return error.OutOfMemory;
            w.print("{{\"name\":\"{s}\"}}", .{c}) catch return error.OutOfMemory;
        }
        w.writeAll("],\"labels\":[") catch return error.OutOfMemory;
        for (i.labels, 0..) |l, k| {
            if (k > 0) w.writeAll(",") catch return error.OutOfMemory;
            try writeJsonString(w, l);
        }
        w.writeAll("]") catch return error.OutOfMemory;
        if (i.team.len > 0) {
            w.print(",\"customfield_10056\":{{\"value\":\"{s}\",\"id\":\"1\"}}", .{i.team}) catch return error.OutOfMemory;
        } else {
            w.writeAll(",\"customfield_10056\":null") catch return error.OutOfMemory;
        }
        if (i.sprint != 0) {
            for (sprints) |sp| if (sp.id == i.sprint) {
                w.print(",\"customfield_10020\":[{{\"id\":{d},\"name\":\"{s}\",\"state\":\"{s}\"}}]", .{ sp.id, sp.name, sp.state }) catch return error.OutOfMemory;
            };
        } else {
            w.writeAll(",\"customfield_10020\":null") catch return error.OutOfMemory;
        }
        if (i.parent.len > 0) {
            const p = s.find(i.parent);
            w.print(",\"parent\":{{\"key\":\"{s}\",\"fields\":{{\"summary\":", .{i.parent}) catch return error.OutOfMemory;
            try writeJsonString(w, if (p) |pp| pp.summary else "");
            w.print(",\"issuetype\":{{\"name\":\"{s}\"}}}}}}", .{if (p) |pp| pp.kind else "Task"}) catch return error.OutOfMemory;
        }
        w.writeAll(",\"subtasks\":[") catch return error.OutOfMemory;
        var first = true;
        for (s.issues.items) |*c| {
            if (!std.mem.eql(u8, c.parent, i.key) or !std.mem.eql(u8, c.kind, "Sub-task")) continue;
            if (!first) w.writeAll(",") catch return error.OutOfMemory;
            first = false;
            w.print("{{\"key\":\"{s}\",\"fields\":{{\"summary\":", .{c.key}) catch return error.OutOfMemory;
            try writeJsonString(w, c.summary);
            w.writeAll("}}") catch return error.OutOfMemory;
        }
        w.writeAll("]") catch return error.OutOfMemory;
        if (detail) {
            w.writeAll(",\"description\":") catch return error.OutOfMemory;
            if (i.description.len == 0) {
                w.writeAll("null") catch return error.OutOfMemory;
            } else {
                w.writeAll("{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":") catch return error.OutOfMemory;
                try writeJsonString(w, i.description);
                w.writeAll("}]}]}") catch return error.OutOfMemory;
            }
            w.print(",\"watches\":{{\"watchCount\":{d},\"isWatching\":{s}}}", .{ i.watchers.items.len, if (isWatching(i)) "true" else "false" }) catch return error.OutOfMemory;
            w.print(",\"comment\":{{\"total\":{d},\"comments\":[", .{i.comments.items.len}) catch return error.OutOfMemory;
            for (i.comments.items, 0..) |c, n| {
                if (n > 0) w.writeAll(",") catch return error.OutOfMemory;
                var it = std.mem.splitScalar(u8, c, 0);
                const author = it.next() orelse "";
                const created = it.next() orelse "";
                const text = it.next() orelse "";
                w.print("{{\"author\":{{\"displayName\":\"{s}\"}},\"created\":\"{s}\",\"body\":{{\"type\":\"doc\",\"version\":1,\"content\":[{{\"type\":\"paragraph\",\"content\":[{{\"type\":\"text\",\"text\":", .{ author, created }) catch return error.OutOfMemory;
                try writeJsonString(w, text);
                w.writeAll("}]}]}}") catch return error.OutOfMemory;
            }
            w.writeAll("]}") catch return error.OutOfMemory;
        }
        w.writeAll("}}") catch return error.OutOfMemory;
    }
};

const Step = struct { id: []const u8, name: []const u8, to: []const u8, category: []const u8 };

/// The fixture's workflow — five states, every one reachable.
pub const workflow = [_]Step{
    .{ .id = "11", .name = "Back to To Do", .to = "To Do", .category = "new" },
    .{ .id = "21", .name = "Start work", .to = "In Progress", .category = "indeterminate" },
    .{ .id = "31", .name = "Send to review", .to = "In PR Review", .category = "indeterminate" },
    .{ .id = "51", .name = "Ready to test", .to = "Testing", .category = "indeterminate" },
    .{ .id = "41", .name = "Close", .to = "Done", .category = "done" },
};

/// The JQL the fixture understands: the clauses the integration sends.
/// Anything else matches everything, which is what a test wants.
fn matches(i: *const Issue, jql: []const u8) bool {
    if (std.mem.indexOf(u8, jql, "issuekey = ''") != null) return false;
    if (std.mem.indexOf(u8, jql, "assignee = currentUser()") != null and !std.mem.eql(u8, i.assignee, account_me)) return false;
    if (std.mem.indexOf(u8, jql, "resolution = Unresolved") != null and std.mem.eql(u8, i.category, "done")) return false;
    if (std.mem.indexOf(u8, jql, "resolution is EMPTY") != null and std.mem.eql(u8, i.category, "done")) return false;
    if (std.mem.indexOf(u8, jql, "status in (Done, Closed, Resolved)") != null and !std.mem.eql(u8, i.category, "done")) return false;
    if (std.mem.indexOf(u8, jql, "status != Done") != null and std.mem.eql(u8, i.status, "Done")) return false;
    if (std.mem.indexOf(u8, jql, "sprint in openSprints()") != null and i.sprint != sprint_active) return false;
    if (std.mem.indexOf(u8, jql, "sprint is EMPTY") != null and i.sprint != 0) return false;
    if (findAfter(jql, "sprint = ")) |v| {
        const want = std.fmt.parseInt(u64, v, 10) catch 0;
        if (i.sprint != want) return false;
    }
    if (std.mem.indexOf(u8, jql, "issuetype = Bug") != null and !std.mem.eql(u8, i.kind, "Bug")) return false;
    if (findQuoted(jql, "fixVersion = ")) |v| if (!std.mem.eql(u8, i.fix_version, v)) return false;
    if (std.mem.indexOf(u8, jql, "filter = 10") != null and !hasLabel(i, "checkout")) return false;
    // The team clause: `("Team" = "X" OR component = "X" OR labels = "X")`
    // matches the team select, a component or a label.
    if (findQuoted(jql, "OR labels = ")) |v| {
        var hit = std.ascii.eqlIgnoreCase(i.team, v) or hasLabel(i, v);
        for (i.components) |c| if (std.ascii.eqlIgnoreCase(c, v)) {
            hit = true;
        };
        if (!hit) return false;
    } else if (findQuoted(jql, "labels = ")) |v| if (!hasLabel(i, v)) return false;
    return true;
}

fn hasLabel(i: *const Issue, v: []const u8) bool {
    for (i.labels) |l| if (std.ascii.eqlIgnoreCase(l, v)) return true;
    return false;
}

fn findQuoted(hay: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, hay, prefix) orelse return null;
    const rest = hay[at + prefix.len ..];
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

/// The bare token after `prefix` (digits, letters).
fn findAfter(hay: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, hay, prefix) orelse return null;
    const rest = hay[at + prefix.len ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isAlphanumeric(rest[n])) : (n += 1) {}
    if (n == 0) return null;
    return rest[0..n];
}

fn err(arena: Allocator, status: u16, message: []const u8) Allocator.Error!Response {
    var out: Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"errorMessages\":[") catch return error.OutOfMemory;
    try writeJsonString(&out.writer, message);
    out.writer.writeAll("],\"errors\":{}}") catch return error.OutOfMemory;
    return .{ .status = status, .body = try out.toOwnedSlice() };
}

fn writeJsonString(w: *Io.Writer, s: []const u8) Allocator.Error!void {
    var st: std.json.Stringify = .{ .writer = w };
    st.write(s) catch return error.OutOfMemory;
}

fn flattenBody(arena: Allocator, v: std.json.Value) Allocator.Error![]const u8 {
    switch (v) {
        .string => |s| return s,
        .object => {},
        else => return "",
    }
    var out: Io.Writer.Allocating = .init(arena);
    try flatten(&out.writer, v);
    const s = try out.toOwnedSlice();
    return std.mem.trim(u8, s, "\n ");
}

fn flatten(w: *Io.Writer, v: std.json.Value) Allocator.Error!void {
    switch (v) {
        .array => |a| for (a.items) |x| try flatten(w, x),
        .object => |o| {
            const kind = switch (o.get("type") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                else => "",
            };
            if (std.mem.eql(u8, kind, "text")) {
                switch (o.get("text") orelse std.json.Value{ .null = {} }) {
                    .string => |s| w.writeAll(s) catch return error.OutOfMemory,
                    else => {},
                }
                return;
            }
            if (o.get("content")) |c| try flatten(w, c);
            if (std.mem.eql(u8, kind, "paragraph")) w.writeByte('\n') catch return error.OutOfMemory;
        },
        else => {},
    }
}

// ── target parsing ──────────────────────────────────────────────────────

pub fn pathOf(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

pub fn queryOf(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[q + 1 ..];
}

pub fn apiTail(path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "/rest/api/3")) return path["/rest/api/3".len..];
    if (std.mem.startsWith(u8, path, "/rest/api/2")) return path["/rest/api/2".len..];
    return null;
}

pub fn paramOf(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn urlDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null and std.mem.indexOfScalar(u8, s, '+') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            try out.append(arena, ' ');
            continue;
        }
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(arena, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(arena, s[i]);
                continue;
            };
            try out.append(arena, hi * 16 + lo);
            i += 2;
            continue;
        }
        try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

// ── the socket loop ─────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    var port: u16 = 0;
    var pid_file: ?[]const u8 = null;
    var port_file: ?[]const u8 = null;
    var life_secs: u32 = 0;
    var require_auth = true;
    var quiet = false;

    var buf: [1024]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version")) {
            try out.print("mnml-fake-jira {s}\n", .{version});
            return 0;
        } else if (std.mem.eql(u8, a, "--no-auth")) {
            require_auth = false;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--life-secs") and i + 1 < args.len) {
            i += 1;
            life_secs = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--pid-file") and i + 1 < args.len) {
            i += 1;
            pid_file = args[i];
        } else if (std.mem.eql(u8, a, "--port-file") and i + 1 < args.len) {
            i += 1;
            port_file = args[i];
        } else {
            try out.print("mnml-fake-jira: unknown argument {s}\n", .{a});
            return 2;
        }
    }

    var store = try Store.init(gpa);
    defer store.deinit();
    store.require_auth = require_auth;

    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        try out.print("mnml-fake-jira: cannot listen on 127.0.0.1:{d}: {s}\n", .{ port, @errorName(e) });
        return 1;
    };
    defer server.deinit(io);
    const bound = server.socket.address.getPort();
    if (!quiet) {
        try out.print("mnml-fake-jira: listening on 127.0.0.1:{d}\n", .{bound});
        try out.flush();
    }
    if (port_file) |p| {
        var pbuf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{bound}) catch "";
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = s }) catch {};
    }
    if (pid_file) |p| {
        var pbuf: [24]u8 = undefined;
        const pid: i64 = if (@import("builtin").os.tag == .windows) 0 else @intCast(std.c.getpid());
        const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{pid}) catch "";
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = s }) catch {};
    }

    const started = Io.Timestamp.now(io, .real).toMilliseconds();
    while (true) {
        const stream = server.accept(io) catch break;
        const stop = serveOne(gpa, io, &store, stream);
        stream.close(io);
        if (stop) break;
        if (life_secs > 0 and Io.Timestamp.now(io, .real).toMilliseconds() - started > @as(i64, life_secs) * 1000) break;
    }
    return 0;
}

/// One request. True means the client asked us to stop.
fn serveOne(gpa: Allocator, io: Io, store: *Store, stream: Io.net.Stream) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch return false;
    var authorization: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = arena.dupe(u8, h.value) catch null;
    }
    const target = arena.dupe(u8, request.head.target) catch return false;
    var body_buf: [8192]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buf);
    const body_store = arena.alloc(u8, 256 * 1024) catch return false;
    // `readerExpectNone` hands back `Reader.ending` for a method
    // with no body — a `@constCast` of a const global. Reading from
    // it writes `seek` back through that const pointer: a segfault
    // on Linux, silently tolerated on macOS. Only read a body the
    // method can actually carry.
    const n = if (request.head.method.requestHasBody())
        body_reader.readSliceShort(body_store) catch 0
    else
        0;
    const stop = std.mem.startsWith(u8, pathOf(target), "/__shutdown");
    const res = store.handle(arena, request.head.method, target, authorization, body_store[0..n]) catch
        Response{ .status = 500, .body = "{\"errorMessages\":[\"out of memory\"],\"errors\":{}}" };
    request.respond(res.body, .{
        .status = @enumFromInt(res.status),
        .extra_headers = &.{.{ .name = "content-type", .value = res.content_type }},
    }) catch {};
    return stop;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn call(store: *Store, arena: Allocator, method: std.http.Method, target: []const u8, body: []const u8) !Response {
    return store.handle(arena, method, target, expected_auth, body);
}

fn countOf(body: []const u8) usize {
    return std.mem.count(u8, body, "{\"id\":\"100");
}

test "without the right Authorization every Jira route is a 401; the forge corner wants its own token" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const no = try store.handle(a.allocator(), .GET, "/rest/api/3/myself", null, "");
    try testing.expectEqual(@as(u16, 401), no.status);
    try testing.expect(std.mem.indexOf(u8, no.body, "must be authenticated") != null);
    try testing.expectEqual(@as(u16, 401), (try store.handle(a.allocator(), .GET, "/rest/api/3/myself", "Basic bm9wZQ==", "")).status);
    store.require_auth = false;
    try testing.expectEqual(@as(u16, 200), (try store.handle(a.allocator(), .GET, "/rest/api/3/myself", null, "")).status);
    try testing.expectEqual(@as(u16, 401), (try store.handle(a.allocator(), .GET, "/2.0/repositories/acme/checkout/pullrequests/2023", expected_auth, "")).status);
    try testing.expectEqual(@as(u16, 200), (try store.handle(a.allocator(), .GET, "/2.0/repositories/acme/checkout/pullrequests/2023", expected_forge_auth, "")).status);
}

test "search: the whole fixture, and every clause the integration sends" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const all = try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG ORDER BY rank\"}");
    try testing.expectEqual(@as(u16, 200), all.status);
    try testing.expectEqual(issue_count, countOf(all.body));
    try testing.expect(std.mem.indexOf(u8, all.body, "\"isLast\":true") != null);
    // Assigned to me and unresolved: ENG-1, ENG-2, ENG-5.
    try testing.expectEqual(@as(usize, 3), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"assignee = currentUser() AND resolution = Unresolved AND status not in (\\\"Done\\\") ORDER BY updated DESC\"}")).body));
    // Recently done by me: ENG-12.
    try testing.expectEqual(@as(usize, 1), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"assignee = currentUser() AND status in (Done, Closed, Resolved) AND resolved >= -30d\"}")).body));
    // The release: eight tickets on 13.16.0.
    try testing.expectEqual(@as(usize, 8), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG AND fixVersion = \\\"13.16.0\\\" ORDER BY rank\"}")).body));
    // The sprint and the backlog.
    try testing.expectEqual(sprint_issue_count, countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"sprint in openSprints() ORDER BY rank ASC\"}")).body));
    try testing.expectEqual(@as(usize, 2), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"sprint is EMPTY AND status != Done ORDER BY rank ASC\"}")).body));
    // A saved filter, a team clause, a label.
    try testing.expectEqual(@as(usize, 3), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"filter = 10 ORDER BY updated DESC\"}")).body));
    try testing.expectEqual(@as(usize, 1), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"(sprint in openSprints()) AND (\\\"Team\\\" = \\\"Atlas\\\" OR component = \\\"Atlas\\\" OR labels = \\\"Atlas\\\")\"}")).body));
    try testing.expectEqual(@as(usize, 1), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"labels = \\\"email\\\"\"}")).body));
    try testing.expectEqual(@as(usize, 0), countOf((try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"issuekey = ''\"}")).body));
    const v2 = try call(&store, arena, .GET, "/rest/api/2/search?jql=project%20%3D%20ENG&maxResults=100", "");
    try testing.expectEqual(issue_count, countOf(v2.body));
    try testing.expect(std.mem.indexOf(u8, v2.body, "startAt") != null);
    // The fields a row reads: the team select, the sprint, the parent.
    try testing.expect(std.mem.indexOf(u8, all.body, "\"customfield_10056\":{\"value\":\"Apollo\"") != null);
    try testing.expect(std.mem.indexOf(u8, all.body, "\"customfield_10020\":[{\"id\":41,\"name\":\"Sprint 4\"") != null);
    try testing.expect(std.mem.indexOf(u8, all.body, "\"parent\":{\"key\":\"ENG-1\"") != null);
}

test "an issue carries its detail, watchers toggle, transitions move it, a comment and an update land" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const one = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-2?fields=description,comment,watches", "");
    try testing.expectEqual(@as(u16, 200), one.status);
    try testing.expect(std.mem.indexOf(u8, one.body, "Rebased and pushed.") != null);
    try testing.expect(std.mem.indexOf(u8, one.body, "\"watchCount\":2,\"isWatching\":true") != null);
    try testing.expectEqual(@as(u16, 404), (try call(&store, arena, .GET, "/rest/api/3/issue/ENG-999", "")).status);
    // ENG-3: nobody watches; watch, then unwatch.
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3", "")).body, "\"watchCount\":0,\"isWatching\":false") != null);
    try testing.expectEqual(@as(u16, 204), (try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/watchers", "\"\"")).status);
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3", "")).body, "\"watchCount\":1,\"isWatching\":true") != null);
    try testing.expectEqual(@as(u16, 204), (try call(&store, arena, .DELETE, "/rest/api/3/issue/ENG-3/watchers?accountId=acct-me", "")).status);
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3", "")).body, "\"isWatching\":false") != null);
    try testing.expectEqual(@as(u16, 400), (try call(&store, arena, .DELETE, "/rest/api/3/issue/ENG-3/watchers", "")).status);
    // Transitions: four offered to a To Do ticket; firing one moves it.
    const list = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3/transitions", "");
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, list.body, "\"id\":"));
    try testing.expect(std.mem.indexOf(u8, list.body, "Back to To Do") == null);
    try testing.expectEqual(@as(u16, 204), (try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/transitions", "{\"transition\":{\"id\":\"51\"}}")).status);
    try testing.expectEqualStrings("Testing", store.find("ENG-3").?.status);
    try testing.expectEqual(@as(u16, 400), (try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/transitions", "{\"transition\":{\"id\":\"99\"}}")).status);
    // A comment, an assignment, a fix version.
    try testing.expectEqual(@as(u16, 201), (try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/comment", "{\"body\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"on it\"}]}]}}")).status);
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3", "")).body, "on it") != null);
    try testing.expectEqual(@as(u16, 400), (try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/comment", "{\"body\":\"\"}")).status);
    try testing.expectEqual(@as(u16, 204), (try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"assignee\":{\"accountId\":\"acct-lin\"}}}")).status);
    try testing.expectEqualStrings(account_lin, store.find("ENG-3").?.assignee);
    try testing.expectEqual(@as(u16, 400), (try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"assignee\":{\"accountId\":\"nope\"}}}")).status);
    try testing.expectEqual(@as(u16, 204), (try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"fixVersions\":[{\"name\":\"13.15.0\"}]}}")).status);
    try testing.expectEqualStrings("13.15.0", store.find("ENG-3").?.fix_version);
}

test "the Agile API: boards, board issues with a jql, sprints by state (paged), quick filters, and the kanban's refusals" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const boards = try call(&store, arena, .GET, "/rest/agile/1.0/board?projectKeyOrId=ENG&maxResults=100", "");
    try testing.expect(std.mem.indexOf(u8, boards.body, "Checkout board") != null and std.mem.indexOf(u8, boards.body, "\"type\":\"kanban\"") != null);
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/agile/1.0/board/7", "")).body, "\"name\":\"Checkout board\"") != null);
    try testing.expectEqual(@as(u16, 404), (try call(&store, arena, .GET, "/rest/agile/1.0/board/9", "")).status);
    try testing.expectEqual(sprint_issue_count, countOf((try call(&store, arena, .GET, "/rest/agile/1.0/board/7/issue?fields=summary&maxResults=100&startAt=0", "")).body));
    try testing.expectEqual(@as(usize, 2), countOf((try call(&store, arena, .GET, "/rest/agile/1.0/board/7/issue?maxResults=100&startAt=0&jql=%28issuetype%20%3D%20Bug%29", "")).body));
    try testing.expectEqual(@as(usize, 3), countOf((try call(&store, arena, .GET, "/rest/agile/1.0/board/7/issue?jql=assignee%20%3D%20currentUser%28%29", "")).body));
    try testing.expectEqual(@as(usize, 2), countOf((try call(&store, arena, .GET, "/rest/agile/1.0/board/8/issue?maxResults=100&startAt=0", "")).body));
    const active = try call(&store, arena, .GET, "/rest/agile/1.0/board/7/sprint?state=active&startAt=0&maxResults=50", "");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, active.body, "\"id\":"));
    try testing.expect(std.mem.indexOf(u8, active.body, "Sprint 4") != null);
    const closed = try call(&store, arena, .GET, "/rest/agile/1.0/board/7/sprint?state=closed&startAt=0&maxResults=1", "");
    try testing.expect(std.mem.indexOf(u8, closed.body, "\"total\":2") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, closed.body, "\"id\":"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, (try call(&store, arena, .GET, "/rest/agile/1.0/board/7/sprint?state=closed&startAt=0&maxResults=20", "")).body, "\"id\":"));
    try testing.expectEqual(@as(u16, 400), (try call(&store, arena, .GET, "/rest/agile/1.0/board/8/sprint?state=active", "")).status);
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/agile/1.0/board/7/quickfilter?maxResults=50", "")).body, "Only bugs") != null);
    try testing.expectEqualStrings("{\"values\":[],\"isLast\":true}", (try call(&store, arena, .GET, "/rest/agile/1.0/board/8/quickfilter?maxResults=50", "")).body);
}

test "versions, assignable users, dev-status PRs, the forge's PR and pipelines" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const v = try call(&store, arena, .GET, "/rest/api/3/project/ENG/versions", "");
    try testing.expect(std.mem.indexOf(u8, v.body, "13.17.0") != null);
    try testing.expectEqual(@as(u16, 404), (try call(&store, arena, .GET, "/rest/api/3/project/ZZZ/versions", "")).status);
    const u = try call(&store, arena, .GET, "/rest/api/3/user/assignable/search?project=ENG&query=&maxResults=50", "");
    try testing.expectEqual(user_count + 1, std.mem.count(u8, u.body, "displayName"));
    const prs = try call(&store, arena, .GET, "/rest/dev-status/latest/issue/detail?issueId=10002&applicationType=bitbucket&dataType=pullrequest", "");
    try testing.expect(std.mem.indexOf(u8, prs.body, "#2023") != null and std.mem.indexOf(u8, prs.body, "MERGED") != null);
    try testing.expect(std.mem.indexOf(u8, (try call(&store, arena, .GET, "/rest/dev-status/latest/issue/detail?issueId=10001&applicationType=bitbucket&dataType=pullrequest", "")).body, "\"pullRequests\":[]") != null);
    const pr = try store.handle(arena, .GET, "/2.0/repositories/acme/checkout/pullrequests/2023", expected_forge_auth, "");
    try testing.expect(std.mem.indexOf(u8, pr.body, "abc123def456") != null);
    const pipes = try store.handle(arena, .GET, "/2.0/repositories/acme/checkout/pipelines/?pagelen=60&sort=-created_on", expected_forge_auth, "");
    try testing.expect(std.mem.indexOf(u8, pipes.body, "\"build_number\":412") != null);
    try testing.expectEqual(@as(u16, 404), (try store.handle(arena, .GET, "/2.0/repositories/acme/nope/pullrequests/1", expected_forge_auth, "")).status);
}

test "--fail-with turns every Jira route into that status; target parsing; /__shutdown" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    store.fail_with = 503;
    const r = try call(&store, a.allocator(), .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG\"}");
    try testing.expectEqual(@as(u16, 503), r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "told to fail") != null);
    store.fail_with = null;
    try testing.expectEqualStrings("/a/b", pathOf("/a/b?x=1"));
    try testing.expectEqualStrings("x=1&y=2", queryOf("/a?x=1&y=2"));
    try testing.expectEqualStrings("/issue/X", apiTail("/rest/api/3/issue/X").?);
    try testing.expect(apiTail("/rest/agile/1.0/board/1") == null);
    try testing.expectEqualStrings("2", paramOf("x=1&y=2", "y").?);
    try testing.expectEqualStrings("project = ENG", try urlDecode(a.allocator(), "project%20%3D%20ENG"));
    try testing.expectEqual(@as(u16, 404), (try call(&store, a.allocator(), .GET, "/rest/api/3/nope", "")).status);
    try testing.expectEqual(@as(u16, 200), (try call(&store, a.allocator(), .GET, "/__shutdown", "")).status);
}
