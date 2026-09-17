//! mnml-fake-jira — a deterministic Jira on the loopback, so every test
//! of the Jira integration runs offline.
//!
//! It answers the twelve routes `src/jira.zig` calls, out of a small
//! fixture: project `ENG`, one epic with two stories and a sub-task, a
//! stray bug, three fix versions and two users. Nothing is random and
//! nothing reads the clock: the same requests always produce the same
//! answers, except where a request deliberately changed something —
//! a transition, a comment, an assignment, a created ticket all mutate
//! the store and show up in the next read.
//!
//!   mnml-fake-jira [--port N] [--port-file P] [--pid-file P]
//!                  [--life-secs N] [--no-auth] [--quiet] [--version]
//!
//! It listens on the loopback only — a fake Jira has no business on a
//! real interface — so there is no `--host`. `--port 0` (the default)
//! binds a free one; the chosen port is printed as
//! `mnml-fake-jira: listening on 127.0.0.1:NNNNN` and, with
//! `--port-file`, written there so a caller can read it back.
//! `--life-secs` bounds a server nobody stopped; it can only fire on a
//! request, so a caller that wants a hard stop kills the `--pid-file`
//! pid or asks for `/__shutdown`.
//!
//! `Store.fail_with` turns every route into one status, for the refusal
//! paths — a field rather than a flag, because the tests that use it
//! drive `Store.handle` directly.
//!
//! `Store.handle` is the whole server as a pure function — method,
//! target, auth header, body in; status, content type, body out — so the
//! unit tests below drive every route with no socket at all, and the
//! socket loop in `main` is the thin part.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const version = "0.1.0";
/// `email:token` for `fake@acme.com` / `fake-token`, base64 — the one
/// credential the server accepts unless `--no-auth`.
pub const expected_auth = "Basic ZmFrZUBhY21lLmNvbTpmYWtlLXRva2Vu";
pub const account_me = "acct-me";
pub const account_sam = "acct-sam";

pub const Response = struct {
    status: u16,
    /// Owned by the arena the call was given.
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
    fix_version: []const u8,
    /// The epic (or story) this hangs off. Empty for a top-level one.
    parent: []const u8,
    description: []const u8,
    /// Newest last. Each is `author\x00created\x00body`.
    comments: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Who an accountId belongs to.
fn displayName(account: []const u8) []const u8 {
    if (std.mem.eql(u8, account, account_me)) return "Ada Lovelace";
    if (std.mem.eql(u8, account, account_sam)) return "Sam Beckett";
    return "";
}

pub const Store = struct {
    gpa: Allocator,
    /// Everything the store owns — the seeded strings' copies, a posted
    /// comment, a created ticket's key — lives here and goes in one go.
    owned: std.heap.ArenaAllocator,
    issues: std.ArrayListUnmanaged(Issue) = .empty,
    /// Bumped for each created ticket.
    next_key: u16 = 90,
    require_auth: bool = true,
    /// When set, every route answers this status with a Jira error body —
    /// for testing the refusal paths.
    fail_with: ?u16 = null,
    /// Counted so a test can assert the client paginates / caches.
    requests: usize = 0,

    pub fn init(gpa: Allocator) Allocator.Error!Store {
        var s: Store = .{ .gpa = gpa, .owned = std.heap.ArenaAllocator.init(gpa) };
        errdefer s.owned.deinit();
        try s.seed();
        return s;
    }

    pub fn deinit(s: *Store) void {
        for (s.issues.items) |*i| i.comments.deinit(s.gpa);
        s.issues.deinit(s.gpa);
        s.owned.deinit();
        s.* = undefined;
    }

    /// A copy the store keeps.
    fn keep(s: *Store, bytes: []const u8) Allocator.Error![]const u8 {
        return s.owned.allocator().dupe(u8, bytes);
    }

    /// The fixture: an epic over two stories, one of them with a
    /// sub-task, plus a bug that hangs off nothing.
    fn seed(s: *Store) Allocator.Error!void {
        try s.issues.append(s.gpa, .{
            .id = "10001",
            .key = "ENG-1",
            .summary = "Checkout rewrite",
            .kind = "Epic",
            .status = "In Progress",
            .category = "indeterminate",
            .assignee = account_me,
            .reporter = account_sam,
            .priority = "High",
            .updated = "2026-09-15T09:00:00.000+0000",
            .created = "2026-08-01T09:00:00.000+0000",
            .fix_version = "13.16.0",
            .parent = "",
            .description = "The umbrella for the checkout work.",
        });
        try s.issues.append(s.gpa, .{
            .id = "10002",
            .key = "ENG-2",
            .summary = "Card form validates on blur",
            .kind = "Story",
            .status = "In Review",
            .category = "indeterminate",
            .assignee = account_me,
            .reporter = account_sam,
            .priority = "Medium",
            .updated = "2026-09-15T08:30:00.000+0000",
            .created = "2026-08-04T09:00:00.000+0000",
            .fix_version = "13.16.0",
            .parent = "ENG-1",
            .description = "Validate the card number when the field loses focus.",
        });
        try s.issues.append(s.gpa, .{
            .id = "10003",
            .key = "ENG-3",
            .summary = "Apple Pay button on the basket",
            .kind = "Story",
            .status = "To Do",
            .category = "new",
            .assignee = "",
            .reporter = account_me,
            .priority = "Low",
            .updated = "2026-09-12T11:00:00.000+0000",
            .created = "2026-08-06T09:00:00.000+0000",
            .fix_version = "13.16.0",
            .parent = "ENG-1",
            .description = "",
        });
        try s.issues.append(s.gpa, .{
            .id = "10004",
            .key = "ENG-4",
            .summary = "Wire the blur handler",
            .kind = "Sub-task",
            .status = "Done",
            .category = "done",
            .assignee = account_sam,
            .reporter = account_me,
            .priority = "Medium",
            .updated = "2026-09-14T16:00:00.000+0000",
            .created = "2026-08-09T09:00:00.000+0000",
            .fix_version = "13.16.0",
            .parent = "ENG-2",
            .description = "",
        });
        try s.issues.append(s.gpa, .{
            .id = "10005",
            .key = "ENG-5",
            .summary = "Basket total wrong with a voucher",
            .kind = "Bug",
            .status = "To Do",
            .category = "new",
            .assignee = account_me,
            .reporter = account_sam,
            .priority = "Highest",
            .updated = "2026-09-15T07:15:00.000+0000",
            .created = "2026-09-15T07:00:00.000+0000",
            .fix_version = "13.15.0",
            .parent = "",
            .description = "Applying a percentage voucher double-counts the delivery line.",
        });
        try s.issues.items[1].comments.append(s.gpa, try s.keep("Sam Beckett\x002026-09-14T10:00:00.000+0000\x00Left a note on the PR."));
        try s.issues.items[1].comments.append(s.gpa, try s.keep("Ada Lovelace\x002026-09-15T08:00:00.000+0000\x00Rebased and pushed."));
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
        if (s.require_auth) {
            const a = authorization orelse "";
            if (!std.mem.eql(u8, a, expected_auth)) {
                return err(arena, 401, "Client must be authenticated to access this resource.");
            }
        }
        if (s.fail_with) |st| return err(arena, st, "the fake server was told to fail");

        const path = pathOf(target);
        const query = queryOf(target);

        if (std.mem.eql(u8, path, "/__shutdown")) return .{ .status = 200, .body = "{\"bye\":true}" };

        // /rest/api/{2,3}/…
        const api = apiTail(path) orelse {
            if (std.mem.startsWith(u8, path, "/rest/dev-status/latest/issue/detail")) return s.devStatus(arena, query);
            return err(arena, 404, "no such endpoint");
        };

        if (std.mem.eql(u8, api, "/myself")) return s.myself(arena);
        if (std.mem.eql(u8, api, "/search/jql") and method == .POST) return s.searchPost(arena, body);
        if (std.mem.eql(u8, api, "/search") and method == .GET) return s.searchGet(arena, query);
        if (std.mem.eql(u8, api, "/issue") and method == .POST) return s.create(arena, body);
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
            if (std.mem.eql(u8, sub, "remotelink") and method == .GET) return s.remoteLinks(arena, issue);
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
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return err(arena, 400, "the search body was not JSON");
        };
        const jql = switch (doc) {
            .object => |o| switch (o.get("jql") orelse std.json.Value{ .null = {} }) {
                .string => |v| v,
                else => "",
            },
            else => "",
        };
        return s.searchAnswer(arena, jql, true);
    }

    fn searchGet(s: *Store, arena: Allocator, query: []const u8) Allocator.Error!Response {
        const raw = paramOf(query, "jql") orelse "";
        const jql = try urlDecode(arena, raw);
        return s.searchAnswer(arena, jql, false);
    }

    fn searchAnswer(s: *Store, arena: Allocator, jql: []const u8, v3: bool) Allocator.Error!Response {
        var out: Io.Writer.Allocating = .init(arena);
        var w = &out.writer;
        var n: usize = 0;
        w.writeAll("{\"issues\":[") catch return error.OutOfMemory;
        for (s.issues.items) |*i| {
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
        // A workflow that always offers the other three states.
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
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return err(arena, 400, "the transition body was not JSON");
        };
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
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return err(arena, 400, "the comment body was not JSON");
        };
        const text = try flattenBody(arena, switch (doc) {
            .object => |o| o.get("body") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        });
        if (text.len == 0) return err(arena, 400, "comment: body is required");
        const line = try std.fmt.allocPrint(s.owned.allocator(), "Ada Lovelace\x002026-09-15T12:00:00.000+0000\x00{s}", .{text});
        try i.comments.append(s.gpa, line);
        return .{ .status = 201, .body = try std.fmt.allocPrint(arena, "{{\"id\":\"{d}\",\"body\":{{}}}}", .{i.comments.items.len}) };
    }

    /// `PUT /issue/{key}` — assignee and fixVersions, the two fields the
    /// pane sets.
    fn update(s: *Store, arena: Allocator, i: *Issue, body: []const u8) Allocator.Error!Response {
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return err(arena, 400, "the update body was not JSON");
        };
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

    fn create(s: *Store, arena: Allocator, body: []const u8) Allocator.Error!Response {
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return err(arena, 400, "the create body was not JSON");
        };
        const fields = switch (doc) {
            .object => |o| switch (o.get("fields") orelse std.json.Value{ .null = {} }) {
                .object => |f| f,
                else => return err(arena, 400, "fields is required"),
            },
            else => return err(arena, 400, "fields is required"),
        };
        const summary = switch (fields.get("summary") orelse std.json.Value{ .null = {} }) {
            .string => |v| v,
            else => "",
        };
        if (summary.len == 0) return err(arena, 400, "summary: You must specify a summary of the issue.");
        const project = switch (fields.get("project") orelse std.json.Value{ .null = {} }) {
            .object => |p| switch (p.get("key") orelse std.json.Value{ .null = {} }) {
                .string => |v| v,
                else => "",
            },
            else => "",
        };
        if (!std.mem.eql(u8, project, "ENG")) return err(arena, 400, "project: the project is not known");
        const kind = switch (fields.get("issuetype") orelse std.json.Value{ .null = {} }) {
            .object => |p| switch (p.get("name") orelse std.json.Value{ .null = {} }) {
                .string => |v| v,
                else => "Task",
            },
            else => "Task",
        };
        const description = try flattenBody(arena, fields.get("description") orelse std.json.Value{ .null = {} });
        s.next_key += 1;
        const key = try std.fmt.allocPrint(s.owned.allocator(), "ENG-{d}", .{s.next_key});
        const id = try std.fmt.allocPrint(s.owned.allocator(), "20{d}", .{s.next_key});
        try s.issues.append(s.gpa, .{
            .id = id,
            .key = key,
            .summary = try s.keep(summary),
            .kind = try s.keep(kind),
            .status = "To Do",
            .category = "new",
            .assignee = "",
            .reporter = account_me,
            .priority = "Medium",
            .updated = "2026-09-15T12:00:00.000+0000",
            .created = "2026-09-15T12:00:00.000+0000",
            .fix_version = "",
            .parent = "",
            .description = try s.keep(description),
        });
        return .{ .status = 201, .body = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"key\":\"{s}\",\"self\":\"http://127.0.0.1/rest/api/3/issue/{s}\"}}", .{ id, key, key }) };
    }

    fn versions(s: *Store, arena: Allocator, project: []const u8) Allocator.Error!Response {
        _ = s;
        if (!std.mem.eql(u8, project, "ENG")) return err(arena, 404, "No project could be found with key 'PROJ'.");
        return .{ .status = 200, .body =
        \\[{"id":"1","name":"13.14.0","released":true,"archived":false},
        \\ {"id":"2","name":"13.15.0","released":false,"archived":false},
        \\ {"id":"3","name":"13.16.0","released":false,"archived":false},
        \\ {"id":"4","name":"Mobile - 1.6.X","released":false,"archived":true}]
        };
    }

    fn assignable(s: *Store, arena: Allocator) Allocator.Error!Response {
        _ = s;
        return .{ .status = 200, .body = try std.fmt.allocPrint(arena,
            \\[{{"accountId":"{s}","displayName":"Ada Lovelace"}},
            \\ {{"accountId":"{s}","displayName":"Sam Beckett"}},
            \\ {{"accountId":"","displayName":"A legacy user with no id"}}]
        , .{ account_me, account_sam }) };
    }

    /// Atlassian's dev panel. ENG-2 has two PRs; everything else has none.
    fn devStatus(s: *Store, arena: Allocator, query: []const u8) Allocator.Error!Response {
        const id = paramOf(query, "issueId") orelse return err(arena, 400, "issueId is required");
        const issue = s.findById(id) orelse return err(arena, 404, "no such issue");
        if (!std.mem.eql(u8, issue.key, "ENG-2")) return .{ .status = 200, .body = "{\"detail\":[{\"pullRequests\":[]}]}" };
        return .{ .status = 200, .body =
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
    }

    /// The public remote-links list — what a site without the dev panel
    /// answers. ENG-5 carries one hand-linked PR.
    fn remoteLinks(s: *Store, arena: Allocator, i: *Issue) Allocator.Error!Response {
        _ = s;
        _ = arena;
        if (!std.mem.eql(u8, i.key, "ENG-5")) return .{ .status = 200, .body = "[]" };
        return .{ .status = 200, .body =
        \\[{"id":9,"object":{"url":"https://bitbucket.org/acme/basket/pull-requests/77",
        \\   "title":"#77","summary":"Fix the voucher line","status":{"icon":{"title":"OPEN"}}}},
        \\ {"id":10,"object":{"url":"https://acme.atlassian.net/wiki/spaces/ENG/pages/1","title":"Design note"}}]
        };
    }

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
        if (i.fix_version.len > 0) {
            w.print(",\"fixVersions\":[{{\"name\":\"{s}\"}}]", .{i.fix_version}) catch return error.OutOfMemory;
        } else {
            w.writeAll(",\"fixVersions\":[]") catch return error.OutOfMemory;
        }
        w.writeAll(",\"components\":[],\"labels\":[]") catch return error.OutOfMemory;
        if (i.parent.len > 0) {
            const p = s.find(i.parent);
            w.print(",\"parent\":{{\"key\":\"{s}\",\"fields\":{{\"summary\":", .{i.parent}) catch return error.OutOfMemory;
            try writeJsonString(w, if (p) |pp| pp.summary else "");
            w.print(",\"issuetype\":{{\"name\":\"{s}\"}}}}}}", .{if (p) |pp| pp.kind else "Task"}) catch return error.OutOfMemory;
        }
        // Sub-tasks, so a hierarchy can be built from one issue too.
        w.writeAll(",\"subtasks\":[") catch return error.OutOfMemory;
        var first = true;
        for (s.issues.items) |*c| {
            if (!std.mem.eql(u8, c.parent, i.key)) continue;
            if (!std.mem.eql(u8, c.kind, "Sub-task")) continue;
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
            w.print(",\"watches\":{{\"watchCount\":{d},\"isWatching\":false}}", .{i.comments.items.len}) catch return error.OutOfMemory;
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

/// The fixture's workflow — four states, every one reachable.
pub const workflow = [_]Step{
    .{ .id = "11", .name = "Back to To Do", .to = "To Do", .category = "new" },
    .{ .id = "21", .name = "Start work", .to = "In Progress", .category = "indeterminate" },
    .{ .id = "31", .name = "Send to review", .to = "In Review", .category = "indeterminate" },
    .{ .id = "41", .name = "Close", .to = "Done", .category = "done" },
};

/// The crude JQL the fixture understands: the clauses the integration
/// actually sends. Anything else matches everything, which is what a
/// test wants from a fake.
fn matches(i: *const Issue, jql: []const u8) bool {
    if (std.mem.indexOf(u8, jql, "issuekey = ''") != null) return false;
    if (std.mem.indexOf(u8, jql, "assignee = currentUser()") != null and !std.mem.eql(u8, i.assignee, account_me)) return false;
    if (std.mem.indexOf(u8, jql, "resolution = Unresolved") != null and std.mem.eql(u8, i.category, "done")) return false;
    if (std.mem.indexOf(u8, jql, "status in (Done, Closed, Resolved)") != null and !std.mem.eql(u8, i.category, "done")) return false;
    if (findQuoted(jql, "fixVersion = ")) |v| if (!std.mem.eql(u8, i.fix_version, v)) return false;
    if (findQuoted(jql, "labels = ")) |_| return false;
    return true;
}

/// The `"…"` immediately after `prefix`, if it is there.
fn findQuoted(hay: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, hay, prefix) orelse return null;
    const rest = hay[at + prefix.len ..];
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
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

/// A doc body as text: an ADF document flattened, or the string a v2
/// site sent.
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

/// `/rest/api/3/issue/X` → `/issue/X`; null when the path is not one.
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
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
        // A bound on a server nobody stopped. It can only fire on a
        // request, so a caller that wants a hard stop kills the pid.
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
    // `head.target` and every header value are slices of the reader's
    // buffer, which reading the body refills: copy them out FIRST.
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

test "without the right Authorization every route is a 401 that says so" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const no = try store.handle(a.allocator(), .GET, "/rest/api/3/myself", null, "");
    try testing.expectEqual(@as(u16, 401), no.status);
    try testing.expect(std.mem.indexOf(u8, no.body, "must be authenticated") != null);
    const wrong = try store.handle(a.allocator(), .GET, "/rest/api/3/myself", "Basic bm9wZQ==", "");
    try testing.expectEqual(@as(u16, 401), wrong.status);
    store.require_auth = false;
    const off = try store.handle(a.allocator(), .GET, "/rest/api/3/myself", null, "");
    try testing.expectEqual(@as(u16, 200), off.status);
}

test "search: the whole fixture, and the clauses the integration sends" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const all = try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG ORDER BY rank\"}");
    try testing.expectEqual(@as(u16, 200), all.status);
    try testing.expect(std.mem.indexOf(u8, all.body, "\"total\":5") != null);
    try testing.expect(std.mem.indexOf(u8, all.body, "\"isLast\":true") != null);
    try testing.expect(std.mem.indexOf(u8, all.body, "ENG-4") != null);
    // Assigned to me and unresolved: ENG-1, ENG-2, ENG-5 (ENG-3 is
    // unassigned, ENG-4 is Sam's and done).
    const mine = try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"assignee = currentUser() AND resolution = Unresolved\"}");
    try testing.expect(std.mem.indexOf(u8, mine.body, "\"total\":3") != null);
    try testing.expect(std.mem.indexOf(u8, mine.body, "ENG-3") == null);
    // A fixVersion clause narrows to one release.
    const rel = try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG AND fixVersion = \\\"13.15.0\\\" ORDER BY rank\"}");
    try testing.expect(std.mem.indexOf(u8, rel.body, "\"total\":1") != null);
    try testing.expect(std.mem.indexOf(u8, rel.body, "ENG-5") != null);
    // The sentinel an unresolvable release tab falls back to is empty.
    const none = try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"issuekey = ''\"}");
    try testing.expect(std.mem.indexOf(u8, none.body, "\"total\":0") != null);
    // v2's GET form answers the same set from a url-encoded jql.
    const v2 = try call(&store, arena, .GET, "/rest/api/2/search?jql=project%20%3D%20ENG&maxResults=100", "");
    try testing.expect(std.mem.indexOf(u8, v2.body, "\"total\":5") != null);
    try testing.expect(std.mem.indexOf(u8, v2.body, "startAt") != null);
}

test "an issue carries its parent and its sub-tasks, so a hierarchy can be built" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const one = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-2", "");
    try testing.expectEqual(@as(u16, 200), one.status);
    try testing.expect(std.mem.indexOf(u8, one.body, "\"parent\":{\"key\":\"ENG-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, one.body, "\"subtasks\":[{\"key\":\"ENG-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, one.body, "Rebased and pushed.") != null);
    try testing.expect(std.mem.indexOf(u8, one.body, "\"watchCount\":2") != null);
    // A key that is not there is Jira's own 404 sentence.
    const gone = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-999", "");
    try testing.expectEqual(@as(u16, 404), gone.status);
    try testing.expect(std.mem.indexOf(u8, gone.body, "do not have permission") != null);
}

test "transitions list the states this issue is not in, and firing one moves it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const list = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3/transitions", "");
    try testing.expect(std.mem.indexOf(u8, list.body, "Start work") != null);
    // ENG-3 is To Do, so "Back to To Do" is not offered.
    try testing.expect(std.mem.indexOf(u8, list.body, "Back to To Do") == null);
    const done = try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/transitions", "{\"transition\":{\"id\":\"21\"}}");
    try testing.expectEqual(@as(u16, 204), done.status);
    try testing.expectEqualStrings("In Progress", store.find("ENG-3").?.status);
    try testing.expectEqualStrings("indeterminate", store.find("ENG-3").?.category);
    const bad = try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/transitions", "{\"transition\":{\"id\":\"99\"}}");
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "not valid for this issue") != null);
}

test "a comment posts as ADF and reads back on the next detail fetch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const posted = try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/comment",
        \\{"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"on it"}]}]}}
    );
    try testing.expectEqual(@as(u16, 201), posted.status);
    const back = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3", "");
    try testing.expect(std.mem.indexOf(u8, back.body, "on it") != null);
    // v2's plain-string body works too.
    _ = try call(&store, arena, .POST, "/rest/api/2/issue/ENG-3/comment", "{\"body\":\"and again\"}");
    const back2 = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-3", "");
    try testing.expect(std.mem.indexOf(u8, back2.body, "and again") != null);
    // An empty body is refused.
    const empty = try call(&store, arena, .POST, "/rest/api/3/issue/ENG-3/comment", "{\"body\":\"\"}");
    try testing.expectEqual(@as(u16, 400), empty.status);
}

test "assignee and fixVersion are set through PUT, and a bad account is refused" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const assigned = try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"assignee\":{\"accountId\":\"acct-me\"}}}");
    try testing.expectEqual(@as(u16, 204), assigned.status);
    try testing.expectEqualStrings(account_me, store.find("ENG-3").?.assignee);
    const cleared = try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"assignee\":null}}");
    try testing.expectEqual(@as(u16, 204), cleared.status);
    try testing.expectEqualStrings("", store.find("ENG-3").?.assignee);
    const nobody = try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"assignee\":{\"accountId\":\"nope\"}}}");
    try testing.expectEqual(@as(u16, 400), nobody.status);
    _ = try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"fixVersions\":[{\"name\":\"13.15.0\"}]}}");
    try testing.expectEqualStrings("13.15.0", store.find("ENG-3").?.fix_version);
    _ = try call(&store, arena, .PUT, "/rest/api/3/issue/ENG-3", "{\"fields\":{\"fixVersions\":[]}}");
    try testing.expectEqualStrings("", store.find("ENG-3").?.fix_version);
}

test "create makes a ticket the next search finds, and refuses a summary-less one" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const made = try call(&store, arena, .POST, "/rest/api/3/issue",
        \\{"fields":{"project":{"key":"ENG"},"issuetype":{"name":"Bug"},"summary":"Fresh one",
        \\ "description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"why"}]}]}}}
    );
    try testing.expectEqual(@as(u16, 201), made.status);
    try testing.expect(std.mem.indexOf(u8, made.body, "\"key\":\"ENG-91\"") != null);
    try testing.expectEqualStrings("Fresh one", store.find("ENG-91").?.summary);
    try testing.expectEqualStrings("why", store.find("ENG-91").?.description);
    const all = try call(&store, arena, .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG\"}");
    try testing.expect(std.mem.indexOf(u8, all.body, "\"total\":6") != null);
    const bad = try call(&store, arena, .POST, "/rest/api/3/issue", "{\"fields\":{\"project\":{\"key\":\"ENG\"}}}");
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "must specify a summary") != null);
    const wrong_project = try call(&store, arena, .POST, "/rest/api/3/issue", "{\"fields\":{\"project\":{\"key\":\"ZZZ\"},\"summary\":\"x\"}}");
    try testing.expectEqual(@as(u16, 400), wrong_project.status);
}

test "versions, assignable users, dev-status PRs and remote links" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const v = try call(&store, arena, .GET, "/rest/api/3/project/ENG/versions", "");
    try testing.expect(std.mem.indexOf(u8, v.body, "13.16.0") != null);
    try testing.expectEqual(@as(u16, 404), (try call(&store, arena, .GET, "/rest/api/3/project/ZZZ/versions", "")).status);
    const u = try call(&store, arena, .GET, "/rest/api/3/user/assignable/search?project=ENG&maxResults=50", "");
    try testing.expect(std.mem.indexOf(u8, u.body, "Sam Beckett") != null);
    // ENG-2 (id 10002) has two PRs; ENG-1 has none.
    const prs = try call(&store, arena, .GET, "/rest/dev-status/latest/issue/detail?issueId=10002&applicationType=bitbucket&dataType=pullrequest", "");
    try testing.expect(std.mem.indexOf(u8, prs.body, "#2023") != null);
    try testing.expect(std.mem.indexOf(u8, prs.body, "MERGED") != null);
    const none = try call(&store, arena, .GET, "/rest/dev-status/latest/issue/detail?issueId=10001&applicationType=bitbucket&dataType=pullrequest", "");
    try testing.expect(std.mem.indexOf(u8, none.body, "\"pullRequests\":[]") != null);
    // ENG-5's PR is a hand-made remote link, alongside a non-PR link.
    const links = try call(&store, arena, .GET, "/rest/api/3/issue/ENG-5/remotelink", "");
    try testing.expect(std.mem.indexOf(u8, links.body, "pull-requests/77") != null);
    try testing.expect(std.mem.indexOf(u8, links.body, "Design note") != null);
    try testing.expectEqualStrings("[]", (try call(&store, arena, .GET, "/rest/api/3/issue/ENG-1/remotelink", "")).body);
}

test "--fail-with turns every route into that status, for the refusal paths" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    store.fail_with = 503;
    const r = try call(&store, a.allocator(), .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG\"}");
    try testing.expectEqual(@as(u16, 503), r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "told to fail") != null);
}

test "target parsing: the path, the query, the api tail, one parameter, percent-decoding" {
    try testing.expectEqualStrings("/a/b", pathOf("/a/b?x=1"));
    try testing.expectEqualStrings("/a/b", pathOf("/a/b"));
    try testing.expectEqualStrings("x=1&y=2", queryOf("/a?x=1&y=2"));
    try testing.expectEqualStrings("", queryOf("/a"));
    try testing.expectEqualStrings("/issue/X", apiTail("/rest/api/3/issue/X").?);
    try testing.expectEqualStrings("/issue/X", apiTail("/rest/api/2/issue/X").?);
    try testing.expect(apiTail("/rest/agile/1.0/board/1") == null);
    try testing.expectEqualStrings("2", paramOf("x=1&y=2", "y").?);
    try testing.expect(paramOf("x=1", "z") == null);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("project = ENG", try urlDecode(a.allocator(), "project%20%3D%20ENG"));
    try testing.expectEqualStrings("a b", try urlDecode(a.allocator(), "a+b"));
    try testing.expectEqualStrings("plain", try urlDecode(a.allocator(), "plain"));
}

test "an unknown route is a 404, and /__shutdown answers before anything else" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    try testing.expectEqual(@as(u16, 404), (try call(&store, a.allocator(), .GET, "/rest/api/3/nope", "")).status);
    try testing.expectEqual(@as(u16, 404), (try call(&store, a.allocator(), .GET, "/wat", "")).status);
    try testing.expectEqual(@as(u16, 200), (try call(&store, a.allocator(), .GET, "/__shutdown", "")).status);
}
