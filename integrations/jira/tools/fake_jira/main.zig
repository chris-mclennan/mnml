//! mnml-fake-jira — a deterministic Jira (and the corner of a forge the
//! pipeline rows need) on the loopback, so every test of the Jira
//! integration runs offline, and so `tools/jira-diff.sh` can run the
//! reference tracker and this port against one answer.
//!
//! It answers every route `src/jira.zig` and `src/bitbucket.zig` call,
//! out of one fixture: project `ENG`, twelve tickets across an epic, a
//! sprint, a backlog and two releases, six assignees, a team select, a
//! five-state workflow, a scrum board with sprints and quick filters
//! and a kanban board without, and three forge pull requests — one
//! merged with a build on its merge commit, one open with two builds
//! on its branch head — so a PR row has builds to fold out whichever
//! state it is in. Nothing is random: the same requests always produce
//! the same answers, except where a request deliberately changed
//! something — a transition, a comment, an assignment, a fix version,
//! a watch — which shows up in the next read.
//!
//! The one thing that does read the clock is the forge corner's dates.
//! They are written relative to `Store.now_secs` (stamped from the real
//! clock before each request, or set by a test), because a build line
//! shows an AGE: a fixture written as an absolute date would read `52w`
//! a year later.
//!
//!   mnml-fake-jira [--port N] [--port-file P] [--url-file P] [--pid-file P]
//!                  [--life-secs N] [--parent-pid N] [--no-auth] [--quiet]
//!                  [--extra-issues N] [--log-file P] [--version]
//!                  [--rate-limit-first N] [--retry-after N]
//!                  [--rate-limit-limit N] [--rate-limit-remaining N]
//!                  [--rate-limit-reset ISO] [--gzip]
//!
//! `--gzip` answers the way Jira Cloud does when the client offers
//! compression: a body with `Content-Encoding: gzip` whenever the
//! request's `Accept-Encoding` names gzip. Off by default, so every
//! other test sees the same plain bytes it always has.
//!
//! The rate-limit flags are the budget dial. `--rate-limit-first N`
//! answers the next N Jira requests `429` with `Retry-After:
//! --retry-after` (default 1; 0 sends none). `--rate-limit-limit N`
//! sends Jira Cloud's `X-RateLimit-Limit` / `-Remaining` /
//! `-NearLimit` on every Jira answer, `-Remaining` starting at
//! `--rate-limit-remaining` and dropping one per request, and
//! `--rate-limit-reset` as `X-RateLimit-Reset`, ISO 8601 the way Jira
//! spells it.
//!
//! Two flags exist for the request-count measurements rather than for
//! the tests. `--extra-issues N` grows the fixture by N more open
//! tickets assigned to the token's own account, each with one linked
//! pull request (two in three of them merged), so a Work tab can be
//! loaded at the size a real one is rather than at three rows.
//! `--log-file P` appends one JSON line per request served — method,
//! path, query, status — which is the wire's own account of what a tab
//! load cost, owing nothing to what the client believes it sent.
//!
//! Loopback only. `--port 0` (the default) binds a free one, printed as
//! `mnml-fake-jira: listening on 127.0.0.1:NNNNN`, written to
//! `--port-file` as the bare number and to `--url-file` as the whole
//! `http://127.0.0.1:NNNNN` the config's `.jira_url` wants — which is
//! how a test script names the server without ever picking a port:
//! `JIRA_BASE_URL=@<path>` reads the file back. `--life-secs` bounds a
//! server nobody stopped, and `--parent-pid` ends one whose starter
//! died — between them a killed test run leaves no server holding a
//! port. A hard stop is the `--pid-file` pid or `/__shutdown`.
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
    /// Sent as `Retry-After: <n>` when set — a 429's hint.
    retry_after_secs: ?u32 = null,
    /// The body is gzipped: sent as `Content-Encoding: gzip`.
    gzipped: bool = false,
    /// `X-RateLimit-*`, when the budget dial is on (`Store.budget_limit`).
    budget: ?Budget = null,

    pub const Budget = struct {
        limit: u32,
        remaining: u32,
        /// A fifth or less left — Jira Cloud's `X-RateLimit-NearLimit`.
        near: bool,
        /// `X-RateLimit-Reset` as Jira Cloud spells it, ISO 8601; empty
        /// sends none.
        reset: []const u8 = "",
    };

    pub const HeaderBuf = struct {
        list: [7]std.http.Header = undefined,
        num: [3][16]u8 = undefined,
    };

    /// The response's headers, into `hb`: the content type, the
    /// `Retry-After` a 429 carries, and the budget dial's numbers.
    pub fn headers(r: *const Response, hb: *HeaderBuf) []const std.http.Header {
        var n: usize = 0;
        hb.list[n] = .{ .name = "content-type", .value = r.content_type };
        n += 1;
        if (r.gzipped) {
            hb.list[n] = .{ .name = "content-encoding", .value = "gzip" };
            n += 1;
        }
        if (r.retry_after_secs) |ra| {
            hb.list[n] = .{ .name = "retry-after", .value = std.fmt.bufPrint(&hb.num[0], "{d}", .{ra}) catch "1" };
            n += 1;
        }
        if (r.budget) |b| {
            hb.list[n] = .{ .name = "x-ratelimit-limit", .value = std.fmt.bufPrint(&hb.num[1], "{d}", .{b.limit}) catch "0" };
            hb.list[n + 1] = .{ .name = "x-ratelimit-remaining", .value = std.fmt.bufPrint(&hb.num[2], "{d}", .{b.remaining}) catch "0" };
            hb.list[n + 2] = .{ .name = "x-ratelimit-nearlimit", .value = if (b.near) "true" else "false" };
            n += 3;
            if (b.reset.len > 0) {
                hb.list[n] = .{ .name = "x-ratelimit-reset", .value = b.reset };
                n += 1;
            }
        }
        return hb.list[0..n];
    }
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
    /// Has this ticket moved since the server started?
    ///
    /// The fixture's stamps are fixed strings, so "moved recently"
    /// cannot be arithmetic on them without making the fixture depend
    /// on today's date. It is a flag instead: false for everything
    /// the fixture loads, true for anything this run has
    /// transitioned, commented on, assigned, re-versioned or watched.
    /// An `updated >= -<window>` query matches exactly the tickets
    /// with it set — which is what a delta poll is FOR, and makes
    /// "nothing changed" and "two things changed" reproducible rather
    /// than a function of the clock.
    moved: bool = false,
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
    /// Answer the next N Jira requests `429` with `Retry-After:
    /// rate_limit_retry_after` — how a test proves the pane waits what
    /// the site asked, then asks again.
    rate_limit_next: u32 = 0,
    rate_limit_retry_after: u32 = 1,
    /// The budget dial: when non-zero every Jira answer carries
    /// `X-RateLimit-Limit: budget_limit` and a `-Remaining` that starts
    /// at `budget_remaining` and drops by one per request, plus
    /// `budget_reset` as `X-RateLimit-Reset` when it is set.
    budget_limit: u32 = 0,
    budget_remaining: u32 = 0,
    budget_reset: []const u8 = "",
    /// `--gzip`: gzip every answer whose request's `Accept-Encoding`
    /// names gzip, the way Jira Cloud does.
    gzip: bool = false,
    /// Answers that went out gzipped — how a test knows the client
    /// really was sent compressed bytes, not plain ones.
    gzipped: std.atomic.Value(u32) = .init(0),
    requests: usize = 0,
    /// Where `--log-file` appends its JSON line per request; null is no
    /// log. The socket loop writes it, not `handle`, so a unit test
    /// that drives `handle` directly never touches a file.
    log_path: ?[]const u8 = null,
    /// How many tickets `--extra-issues` added past the twelve the
    /// fixture ships. Their keys are `ENG-101` upward.
    extra: usize = 0,
    /// The clock the forge corner's relative dates are written against.
    /// The listener stamps the real one before each request; a test
    /// sets its own, so a build line's age is the same every run.
    now_secs: i64 = 1_789_500_000,

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

    /// Grow the fixture by `n` open tickets assigned to the token's own
    /// account — `ENG-101` upward, each carrying one linked pull
    /// request, two in three of them merged. Only the measurements ask
    /// for this: at `n = 0` the fixture is the twelve rows every test
    /// asserts against.
    pub fn addExtraIssues(s: *Store, n: usize) Allocator.Error!void {
        const own = s.owned.allocator();
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            try s.issues.append(s.gpa, .{
                .id = try std.fmt.allocPrint(own, "{d}", .{10100 + i}),
                .key = try std.fmt.allocPrint(own, "ENG-{d}", .{100 + i}),
                .summary = try std.fmt.allocPrint(own, "Checkout follow-up {d}", .{i}),
                .kind = "Story",
                .status = "In Progress",
                .category = "indeterminate",
                .assignee = account_me,
                .reporter = account_sam,
                .priority = "Medium",
                .updated = "2026-09-15T09:00:00.000+0000",
                .created = "2026-08-01T09:00:00.000+0000",
                .fix_version = "13.16.0",
                .team = "Apollo",
                .sprint = sprint_active,
            });
        }
        s.extra += n;
    }

    /// The pull-request id an extra ticket's dev panel links to, and
    /// whether it merged. `null` for anything that is not an extra.
    fn extraPr(s: *const Store, key: []const u8) ?struct { id: u32, merged: bool } {
        if (!std.mem.startsWith(u8, key, "ENG-1")) return null;
        const n = std.fmt.parseInt(usize, key["ENG-".len..], 10) catch return null;
        if (n <= 100 or n > 100 + s.extra) return null;
        const i = n - 100;
        return .{ .id = @intCast(5000 + i), .merged = i % 3 != 0 };
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
        var res = try s.route(arena, method, target, authorization, body);
        // The dial is Jira's: the forge corner is a different service.
        if (s.budget_limit > 0 and !std.mem.startsWith(u8, pathOf(target), "/2.0/")) {
            s.budget_remaining -|= 1;
            res.budget = .{ .limit = s.budget_limit, .remaining = s.budget_remaining, .near = s.budget_remaining * 5 <= s.budget_limit, .reset = s.budget_reset };
        }
        return res;
    }

    fn route(s: *Store, arena: Allocator, method: std.http.Method, target: []const u8, authorization: ?[]const u8, body: []const u8) Allocator.Error!Response {
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
        if (s.rate_limit_next > 0) {
            s.rate_limit_next -= 1;
            var r = try err(arena, 429, "Rate limit exceeded");
            r.retry_after_secs = if (s.rate_limit_retry_after > 0) s.rate_limit_retry_after else null;
            return r;
        }

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
        // Jira refuses a `key in (…)` naming a ticket that does not
        // exist (deleted, or moved to a project the account cannot see)
        // rather than ignoring it.
        if (findList(jql, "key in (")) |list| {
            var rest = list;
            while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
                const after = rest[open + 1 ..];
                const close = std.mem.indexOfScalar(u8, after, '"') orelse break;
                const k = after[0..close];
                if (s.find(k) == null) return err(arena, 400, try std.fmt.allocPrint(arena, "An issue with key '{s}' does not exist for field 'key'.", .{k}));
                rest = after[close + 1 ..];
            }
        }
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
            i.moved = true;
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
        i.moved = true;
        return .{ .status = 201, .body = try std.fmt.allocPrint(arena, "{{\"id\":\"{d}\",\"body\":{{}}}}", .{i.comments.items.len}) };
    }

    fn watch(s: *Store, arena: Allocator, i: *Issue) Allocator.Error!Response {
        _ = arena;
        for (i.watchers.items) |wv| if (std.mem.eql(u8, wv, account_me)) return .{ .status = 204, .body = "" };
        try i.watchers.append(s.gpa, account_me);
        i.moved = true;
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
        i.moved = true;
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
        if (s.extraPr(issue.key)) |pr| return .{ .status = 200, .body = try std.fmt.allocPrint(arena,
            \\{{"detail":[{{"pullRequests":[
            \\ {{"id":"#{d}","name":"Checkout follow-up","status":"{s}",
            \\  "url":"https://bitbucket.org/acme/checkout/pull-requests/{d}",
            \\  "repositoryName":"checkout",
            \\  "source":{{"branch":"feat/follow-up"}},"destination":{{"branch":"main"}},
            \\  "reviewers":[{{"name":"Sam Beckett","approved":true}}]}}
            \\]}}]}}
        , .{ pr.id, if (pr.merged) "MERGED" else "OPEN", pr.id }) };
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
        const a = authorization orelse "";
        if (!std.mem.eql(u8, a, expected_forge_auth)) return .{ .status = 401, .body = "{\"type\":\"error\",\"error\":{\"message\":\"Access token expired.\"}}" };
        // A pull request carries `updated_on` (the key a caller skips
        // the pipelines request on), the merge commit when it merged,
        // and the source head while it is open — an OPEN PR's builds
        // are the ones a reviewer wants.
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/checkout/pullrequests/2023")) return s.forgePr(arena, 2023, "MERGED", "abc123def456", "feat/blur-validation", "2222222222222222", 30);
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/checkout/pullrequests/2044")) return s.forgePr(arena, 2044, "OPEN", "", "feat/trim", "3333333333333333", 2);
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/ops/pullrequests/3001")) return s.forgePr(arena, 3001, "MERGED", "9f9f9f9f9f9f", "chore/rotate-keys", "4444444444444444", 50);
        if (std.mem.startsWith(u8, path, "/2.0/repositories/acme/checkout/pullrequests/5")) {
            const id = std.fmt.parseInt(u32, path["/2.0/repositories/acme/checkout/pullrequests/".len..], 10) catch 0;
            const i = if (id > 5000) id - 5000 else 0;
            if (i >= 1 and i <= s.extra) {
                const merged = i % 3 != 0;
                return s.forgePr(arena, id, if (merged) "MERGED" else "OPEN", if (merged) "abc123def456" else "", "feat/follow-up", "3333333333333333", 6);
            }
        }
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/checkout/pipelines/")) return s.forgePipelines(arena);
        if (std.mem.eql(u8, path, "/2.0/repositories/acme/ops/pipelines/")) return .{ .status = 200, .body = "{\"values\":[]}" };
        return .{ .status = 404, .body = "{\"type\":\"error\",\"error\":{\"message\":\"Resource not found\"}}" };
    }

    /// One forge pull request. `merge` is its merge commit when it
    /// landed; `head` is its source head either way.
    fn forgePr(s: *Store, arena: Allocator, id: u32, state: []const u8, merge: []const u8, branch: []const u8, head: []const u8, age_hours: i64) Allocator.Error!Response {
        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.print("{{\"id\":{d},\"state\":\"{s}\",\"updated_on\":\"", .{ id, state }) catch return error.OutOfMemory;
        try writeIso(w, s.now_secs - age_hours * 3600);
        w.print("\",\"source\":{{\"branch\":{{\"name\":\"{s}\"}},\"commit\":{{\"hash\":\"{s}\"}}}}", .{ branch, head }) catch return error.OutOfMemory;
        if (merge.len > 0) w.print(",\"merge_commit\":{{\"hash\":\"{s}\"}}", .{merge}) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    /// The repo's recent runs, newest first: one on the merged PR's
    /// merge commit, one on the open PR's branch head (so an open row
    /// has builds to fold out), and one that belongs to neither.
    fn forgePipelines(s: *Store, arena: Allocator) Allocator.Error!Response {
        const Run = struct { n: u32, state: []const u8, result: []const u8, ref: []const u8, hash: []const u8, secs: u32, age_h: i64 };
        const runs = [_]Run{
            .{ .n = 414, .state = "IN_PROGRESS", .result = "", .ref = "feat/trim", .hash = "3333333333333333", .secs = 0, .age_h = 1 },
            .{ .n = 413, .state = "COMPLETED", .result = "FAILED", .ref = "feat/trim", .hash = "3333333333333333", .secs = 64, .age_h = 5 },
            .{ .n = 412, .state = "COMPLETED", .result = "SUCCESSFUL", .ref = "main", .hash = "abc123def456789012345678901234567890abcd", .secs = 225, .age_h = 28 },
            .{ .n = 411, .state = "COMPLETED", .result = "FAILED", .ref = "feat/blur-validation", .hash = "1111111111111111111111111111111111111111", .secs = 80, .age_h = 30 },
        };
        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"values\":[") catch return error.OutOfMemory;
        for (runs, 0..) |r, i| {
            if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
            w.print("{{\"uuid\":\"{{p{d}}}\",\"build_number\":{d},\"state\":{{\"name\":\"{s}\"", .{ r.n, r.n, r.state }) catch return error.OutOfMemory;
            if (r.result.len > 0) w.print(",\"result\":{{\"name\":\"{s}\"}}", .{r.result}) catch return error.OutOfMemory;
            w.writeAll("},\"created_on\":\"") catch return error.OutOfMemory;
            try writeIso(w, s.now_secs - r.age_h * 3600);
            w.print("\",\"duration_in_seconds\":{d},\"target\":{{\"ref_name\":\"{s}\",\"commit\":{{\"hash\":\"{s}\"}}}}}}", .{ r.secs, r.ref, r.hash }) catch return error.OutOfMemory;
        }
        w.writeAll("]}") catch return error.OutOfMemory;
        return .{ .status = 200, .body = try out.toOwnedSlice() };
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
    // The delta window: only what this run has moved.
    if (std.mem.indexOf(u8, jql, "updated >= -") != null and !i.moved) return false;
    if (std.mem.indexOf(u8, jql, "issuekey = ''") != null) return false;
    // `key in ("ENG-1", "ENG-2")` — a delta's question about the rows
    // already on screen.
    if (findList(jql, "key in (")) |list| if (!inQuotedList(list, i.key)) return false;
    if (std.mem.indexOf(u8, jql, "assignee = currentUser()") != null and !std.mem.eql(u8, i.assignee, account_me)) return false;
    if (std.mem.indexOf(u8, jql, "reporter = currentUser()") != null and !std.mem.eql(u8, i.reporter, account_me)) return false;
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
    // `fixVersion in ("a", "b")` — what a `jql_editable` tab's version
    // hole expands to.
    if (findList(jql, "fixVersion in (")) |list| if (!inQuotedList(list, i.fix_version)) return false;
    if (findQuoted(jql, "project = ")) |v| if (!std.mem.startsWith(u8, i.key, v)) return false;
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

/// The bytes between `prefix` and the `)` that closes it.
fn findList(hay: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, hay, prefix) orelse return null;
    const rest = hay[at + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    return rest[0..end];
}

/// Is `want` one of the quoted strings in `list`?
fn inQuotedList(list: []const u8, want: []const u8) bool {
    var rest = list;
    while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
        const after = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse return false;
        if (std.mem.eql(u8, after[0..close], want)) return true;
        rest = after[close + 1 ..];
    }
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

/// `YYYY-MM-DDTHH:MM:SS+00:00` for a wall-clock second — the shape
/// Bitbucket writes, so a relative fixture date reads like a real one.
fn writeIso(w: *Io.Writer, secs: i64) Allocator.Error!void {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch return error.OutOfMemory;
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
    var url_file: ?[]const u8 = null;
    var life_secs: u32 = 0;
    var parent_pid: i32 = 0;
    var require_auth = true;
    var quiet = false;
    var gzip = false;
    var log_file: ?[]const u8 = null;
    var extra_issues: usize = 0;
    var rate_limit_first: u32 = 0;
    var retry_after: ?u32 = null;
    var budget_limit: u32 = 0;
    var budget_remaining: ?u32 = null;
    var budget_reset: []const u8 = "";

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
        } else if (std.mem.eql(u8, a, "--gzip")) {
            gzip = true;
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--life-secs") and i + 1 < args.len) {
            i += 1;
            life_secs = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--parent-pid") and i + 1 < args.len) {
            i += 1;
            parent_pid = std.fmt.parseInt(i32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--pid-file") and i + 1 < args.len) {
            i += 1;
            pid_file = args[i];
        } else if (std.mem.eql(u8, a, "--port-file") and i + 1 < args.len) {
            i += 1;
            port_file = args[i];
        } else if (std.mem.eql(u8, a, "--url-file") and i + 1 < args.len) {
            i += 1;
            url_file = args[i];
        } else if (std.mem.eql(u8, a, "--log-file") and i + 1 < args.len) {
            i += 1;
            log_file = args[i];
        } else if (std.mem.eql(u8, a, "--extra-issues") and i + 1 < args.len) {
            i += 1;
            extra_issues = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--rate-limit-first") and i + 1 < args.len) {
            i += 1;
            rate_limit_first = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--retry-after") and i + 1 < args.len) {
            i += 1;
            retry_after = std.fmt.parseInt(u32, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, a, "--rate-limit-limit") and i + 1 < args.len) {
            i += 1;
            budget_limit = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--rate-limit-remaining") and i + 1 < args.len) {
            i += 1;
            budget_remaining = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--rate-limit-reset") and i + 1 < args.len) {
            i += 1;
            budget_reset = args[i];
        } else {
            try out.print("mnml-fake-jira: unknown argument {s}\n", .{a});
            return 2;
        }
    }

    var store = try Store.init(gpa);
    defer store.deinit();
    store.require_auth = require_auth;
    store.gzip = gzip;
    if (extra_issues > 0) try store.addExtraIssues(extra_issues);
    store.rate_limit_next = rate_limit_first;
    if (retry_after) |ra| store.rate_limit_retry_after = ra;
    store.budget_limit = budget_limit;
    store.budget_remaining = budget_remaining orelse budget_limit;
    store.budget_reset = budget_reset;
    // A fresh log per run: the measurement is one tab load's worth, not
    // everything this file has ever seen.
    if (log_file) |p| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "" }) catch {};
        store.log_path = p;
    }

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
    // The whole base URL, for `JIRA_BASE_URL=@<path>`. Written once the
    // socket is listening, so a reader that finds the file finds a
    // server behind it.
    if (url_file) |p| {
        var ubuf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&ubuf, "http://127.0.0.1:{d}", .{bound}) catch "";
        if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = s }) catch |e| {
            try out.print("mnml-fake-jira: cannot write {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
    }
    if (pid_file) |p| {
        var pbuf: [24]u8 = undefined;
        const pid: i64 = if (@import("builtin").os.tag == .windows) 0 else @intCast(std.c.getpid());
        const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{pid}) catch "";
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = s }) catch {};
    }

    var reaper: Reaper = .{ .io = io, .port = bound, .life_secs = life_secs, .parent_pid = parent_pid };
    if (life_secs > 0 or parent_pid > 0) {
        const th = std.Thread.spawn(.{}, Reaper.run, .{&reaper}) catch null;
        if (th) |t| t.detach();
    }
    serveUntil(gpa, io, &store, &server, &reaper);
    return 0;
}

/// The deadline, made real. The accept blocks, so a server nobody talks
/// to never came back to look at the clock — which is how a `--life-secs`
/// run outlived the test that started it by hours. The reaper sleeps out
/// the life, raises the flag and then knocks on the port itself, so the
/// blocking accept returns and the loop sees the flag.
const Reaper = struct {
    io: Io,
    port: u16,
    life_secs: u32,
    /// Whoever started us. Zero means nobody claimed to. A server whose
    /// starter is gone is an orphan holding a port, so it goes too —
    /// that is what a killed test run leaves behind otherwise.
    parent_pid: i32 = 0,
    expired: std.atomic.Value(bool) = .init(false),

    fn run(r: *Reaper) void {
        // No life given but a parent named: watch the parent for as long
        // as it lives.
        var left: u32 = if (r.life_secs > 0) r.life_secs else std.math.maxInt(u32);
        while (left > 0) : (left -= 1) {
            r.io.sleep(.fromMilliseconds(1000), .awake) catch break;
            // Somebody else called the run over (a test's recovery path,
            // a second reaper): stop rather than sleep out the life.
            if (r.expired.load(.acquire)) return;
            if (r.orphaned()) break;
        }
        r.expired.store(true, .release);
        r.knock();
    }

    /// True when the process that started us is gone. Signal 0 is the
    /// POSIX liveness probe: it delivers nothing and answers ESRCH when
    /// there is nobody there. (`SIG` has no zero member — the probe is
    /// not a signal — so the number goes in as itself.)
    fn orphaned(r: *const Reaper) bool {
        if (r.parent_pid <= 0) return false;
        if (@import("builtin").os.tag == .windows) return false;
        const rc = std.c.kill(r.parent_pid, @enumFromInt(0));
        return rc != 0 and std.c._errno().* == @intFromEnum(std.c.E.SRCH);
    }

    /// One connection that asks for nothing — the accept's alarm clock.
    fn knock(r: *Reaper) void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(r.port) };
        if (addr.connect(r.io, .{ .mode = .stream })) |s| s.close(r.io) else |_| {}
    }

    fn done(r: *const Reaper) bool {
        return r.expired.load(.acquire);
    }
};

/// Serve until a client asks us to stop or the life runs out.
fn serveUntil(gpa: Allocator, io: Io, store: *Store, server: *Io.net.Server, reaper: *Reaper) void {
    while (!reaper.done()) {
        // A transient accept failure (a client that gave up first, a
        // moment out of descriptors) is not the end of the fake.
        const stream = server.accept(io) catch {
            if (reaper.done()) break;
            io.sleep(.fromMilliseconds(10), .awake) catch {};
            continue;
        };
        if (reaper.done()) {
            stream.close(io);
            break;
        }
        const served = serveOne(gpa, io, store, stream, .{});
        stream.close(io);
        if (served == .stop or served == .canceled) break;
    }
}

/// What became of one connection.
pub const Served = enum {
    /// A request came in and its answer went out.
    answered,
    /// The request was the stop path: answered, and the loop ends.
    stop,
    /// The client hung up before its request was whole, or before its
    /// answer went out — a worker cancelled mid-request does exactly
    /// that. Nothing to answer; the NEXT connection must still be
    /// taken, so the loop goes on.
    dropped,
    /// This task was cancelled while it read or wrote. The cancel has
    /// been acknowledged by the read that saw it, so it must go back up
    /// as `error.Canceled`: a loop that swallowed it and went back to
    /// `accept` would never be cancelled again.
    canceled,
};

pub const ServeOptions = struct {
    /// The path that answers and then ends the loop.
    stop_path: []const u8 = "/__shutdown",
    /// Stamp `store.now_secs` from the real clock before each request.
    /// The binary does; an in-process test keeps the store's own.
    stamp_clock: bool = true,
};

/// One connection, one request. The binary's loop and the in-process
/// `jira.Loopback` both answer through this, so the two cannot drift
/// on what a hung-up client means (the Loopback's own copy ended its
/// whole loop on one, and every request after it parked for good).
pub fn serveOne(gpa: Allocator, io: Io, store: *Store, stream: Io.net.Stream, opts: ServeOptions) Served {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const lost: Served = lost: {
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http.receiveHead() catch break :lost .dropped;
        // The forge corner writes its dates relative to now, so a build
        // line's age is the same on every run rather than drifting with
        // the day the fixture was written.
        if (opts.stamp_clock) store.now_secs = Io.Timestamp.now(io, .real).toSeconds();
        var authorization: ?[]const u8 = null;
        var wants_gzip = false;
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = arena.dupe(u8, h.value) catch null;
            if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) wants_gzip = acceptsGzip(h.value);
        }
        const target = arena.dupe(u8, request.head.target) catch break :lost .dropped;
        var body_buf: [8192]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buf);
        const body_store = arena.alloc(u8, 256 * 1024) catch break :lost .dropped;
        // `readerExpectNone` hands back `Reader.ending` for a method
        // with no body — a `@constCast` of a const global. Reading from
        // it writes `seek` back through that const pointer: a segfault
        // on Linux, silently tolerated on macOS. Only read a body the
        // method can actually carry.
        const n = if (request.head.method.requestHasBody())
            body_reader.readSliceShort(body_store) catch 0
        else
            0;
        const stop = std.mem.startsWith(u8, pathOf(target), opts.stop_path);
        var res = store.handle(arena, request.head.method, target, authorization, body_store[0..n]) catch
            Response{ .status = 500, .body = "{\"errorMessages\":[\"out of memory\"],\"errors\":{}}" };
        logRequest(io, store, arena, request.head.method, target, res.status, res.body.len, body_store[0..n]);
        // The log keeps the plain size; the wire gets what Jira Cloud
        // sends a client that offered gzip.
        if (store.gzip and wants_gzip and res.body.len > 0) {
            if (gzipBody(arena, res.body)) |z| {
                res.body = z;
                res.gzipped = true;
                _ = store.gzipped.fetchAdd(1, .monotonic);
            } else |_| {}
        }
        var hbuf: Response.HeaderBuf = .{};
        request.respond(res.body, .{
            .status = @enumFromInt(res.status),
            .extra_headers = res.headers(&hbuf),
        }) catch break :lost if (stop) .stop else .dropped;
        return if (stop) .stop else .answered;
    };
    // A failed read or write keeps its real reason on the stream: a
    // cancel is this task's to hand on, anything else is the client's.
    const read_canceled = if (reader.err) |e| e == error.Canceled else false;
    const write_canceled = if (writer.err) |e| e == error.Canceled else false;
    if (read_canceled or write_canceled) return .canceled;
    return lost;
}

/// True when an `Accept-Encoding` value offers gzip: `gzip` (or
/// `x-gzip`, or `*`) in the list, and not refused with `q=0`.
pub fn acceptsGzip(value: []const u8) bool {
    var items = std.mem.tokenizeScalar(u8, value, ',');
    while (items.next()) |item| {
        var parts = std.mem.tokenizeScalar(u8, item, ';');
        const name = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (!std.ascii.eqlIgnoreCase(name, "gzip") and !std.ascii.eqlIgnoreCase(name, "x-gzip") and !std.mem.eql(u8, name, "*")) continue;
        var refused = false;
        while (parts.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (std.mem.startsWith(u8, p, "q=") and (std.fmt.parseFloat(f32, p[2..]) catch 1) == 0) refused = true;
        }
        if (!refused) return true;
    }
    return false;
}

/// `body` as a gzip stream, on `arena`.
pub fn gzipBody(arena: Allocator, body: []const u8) (Allocator.Error || Io.Writer.Error)![]const u8 {
    const flate = std.compress.flate;
    var out: Io.Writer.Allocating = try .initCapacity(arena, body.len + 64);
    const window = try arena.alloc(u8, flate.max_window_len);
    // The compressor's match tables run past a hundred kilobytes: on
    // the arena, not on a serving task's stack.
    const z = try arena.create(flate.Compress);
    z.* = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try z.writer.writeAll(body);
    try z.finish();
    return out.written();
}

/// The `jql` a search body carries, verbatim; empty for anything else.
/// A crude scan rather than a parse: this runs on every request and
/// the body is the fake's own client's.
fn jqlOf(body: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, body, "\"jql\"") orelse return "";
    const rest = body[at + 5 ..];
    const open = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    var i = open + 1;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '\\') {
            i += 1;
            continue;
        }
        if (rest[i] == '"') return rest[open + 1 .. i];
    }
    return "";
}

/// One JSON line appended to `--log-file`: what arrived on the wire,
/// which is the only account of a tab's cost that owes nothing to what
/// the client believes it sent. Best effort — a server that cannot
/// write its log still serves.
fn logRequest(io: Io, store: *Store, arena: Allocator, method: std.http.Method, target: []const u8, status: u16, bytes: usize, body: []const u8) void {
    const path = store.log_path orelse return;
    // A Jira search puts its query in the POST body, so a log of paths
    // alone cannot say what was asked for — and what was asked for is
    // exactly what a delta-window test has to assert on.
    const line = std.fmt.allocPrint(arena, "{{\"method\":\"{s}\",\"path\":\"{f}\",\"query\":\"{f}\",\"status\":{d},\"bytes\":{d},\"jql\":\"{f}\"}}\n", .{
        @tagName(method),
        std.zig.fmtString(pathOf(target)),
        std.zig.fmtString(queryOf(target)),
        status,
        bytes,
        std.zig.fmtString(jqlOf(body)),
    }) catch return;
    const file = Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .lock = .exclusive }) catch return;
    defer file.close(io);
    const end = file.length(io) catch 0;
    file.writePositionalAll(io, line, end) catch {};
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

test "the budget dial: every Jira answer carries the numbers, remaining drops per request, the forge corner carries none" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    store.require_auth = false;
    store.budget_limit = 10;
    store.budget_remaining = 3;
    store.budget_reset = "2026-09-25T14:10:00.000Z";
    const one = try store.handle(a.allocator(), .GET, "/rest/api/3/myself", null, "");
    try testing.expectEqual(@as(u32, 2), one.budget.?.remaining);
    try testing.expect(one.budget.?.near);
    var hb: Response.HeaderBuf = .{};
    const hs = one.headers(&hb);
    var saw_reset = false;
    for (hs) |h| if (std.mem.eql(u8, h.name, "x-ratelimit-reset")) {
        saw_reset = std.mem.eql(u8, h.value, "2026-09-25T14:10:00.000Z");
    };
    try testing.expect(saw_reset);
    store.rate_limit_next = 1;
    store.rate_limit_retry_after = 0;
    const limited = try store.handle(a.allocator(), .GET, "/rest/api/3/myself", null, "");
    try testing.expectEqual(@as(u16, 429), limited.status);
    try testing.expectEqual(@as(?u32, null), limited.retry_after_secs);
    const forge = try store.handle(a.allocator(), .GET, "/2.0/user", "Bearer fake-forge", "");
    try testing.expectEqual(@as(?Response.Budget, null), forge.budget);
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

test "--gzip: an Accept-Encoding that offers gzip is read as one, and the body round-trips through the std decompressor" {
    try testing.expect(acceptsGzip("gzip, deflate"));
    try testing.expect(acceptsGzip("deflate, GZIP;q=0.5"));
    try testing.expect(acceptsGzip("*"));
    try testing.expect(!acceptsGzip("identity"));
    try testing.expect(!acceptsGzip("deflate, zstd"));
    try testing.expect(!acceptsGzip("gzip;q=0"));

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    const plain = (try call(&store, a.allocator(), .POST, "/rest/api/3/search/jql", "{\"jql\":\"project = ENG ORDER BY rank\"}")).body;
    const z = try gzipBody(a.allocator(), plain);
    // The gzip magic, and fewer bytes than the JSON it carries.
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, z[0..2]);
    try testing.expect(z.len < plain.len);
    var in: Io.Reader = .fixed(z);
    const window = try a.allocator().alloc(u8, std.compress.flate.max_window_len);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    var back: Io.Writer.Allocating = .init(a.allocator());
    _ = try d.reader.streamRemaining(&back.writer);
    try testing.expectEqualStrings(plain, back.written());
}

/// `serveUntil` on a thread of its own, so a test can put a bound on it:
/// a deadline that does not work is a hang, and a hang is not a verdict.
const ServeProbe = struct {
    gpa: Allocator,
    io: Io,
    store: *Store,
    server: *Io.net.Server,
    reaper: *Reaper,
    returned: std.atomic.Value(bool) = .init(false),

    fn run(p: *ServeProbe) void {
        serveUntil(p.gpa, p.io, p.store, p.server, p.reaper);
        p.returned.store(true, .release);
    }
};

test "--life-secs is a real deadline: a server nobody talks to is gone when the life runs out" {
    const io = testing.io;
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var reaper: Reaper = .{ .io = io, .port = server.socket.address.getPort(), .life_secs = 1 };
    var probe: ServeProbe = .{ .gpa = testing.allocator, .io = io, .store = &store, .server = &server, .reaper = &reaper };
    const serving = try std.Thread.spawn(.{}, ServeProbe.run, .{&probe});
    const reaping = try std.Thread.spawn(.{}, Reaper.run, .{&reaper});
    // Nothing ever connects: the accept blocks, and only the reaper's
    // knock brings it back. Five seconds is five lives.
    var waited: u32 = 0;
    while (waited < 5000 and !probe.returned.load(.acquire)) : (waited += 50) io.sleep(.fromMilliseconds(50), .awake) catch {};
    const served = probe.returned.load(.acquire);
    if (!served) {
        // Let the threads out before the failure unwinds the stack the
        // probe points into.
        reaper.expired.store(true, .release);
        reaper.knock();
    }
    serving.join();
    reaping.join();
    try testing.expect(served);
}

test "--parent-pid: a server whose starter is gone leaves too, deadline or no deadline" {
    // The orphan check is the POSIX liveness probe (`kill(pid, 0)`); on
    // Windows `orphaned` is always false and the deadline alone applies.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var store = try Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    // A pid that cannot be alive: nothing to knock on but the port.
    // `--life-secs 0` on purpose — the parent is the whole deadline here.
    var reaper: Reaper = .{ .io = io, .port = server.socket.address.getPort(), .life_secs = 0, .parent_pid = 0x7fff_fffe };
    try testing.expect(reaper.orphaned());
    // Our own process is alive, so that one is not an orphan.
    var live: Reaper = .{ .io = io, .port = 0, .life_secs = 0, .parent_pid = @intCast(std.c.getpid()) };
    try testing.expect(!live.orphaned());
    // And a run with no parent named never calls itself orphaned.
    var none: Reaper = .{ .io = io, .port = 0, .life_secs = 0 };
    try testing.expect(!none.orphaned());

    var probe: ServeProbe = .{ .gpa = testing.allocator, .io = io, .store = &store, .server = &server, .reaper = &reaper };
    const serving = try std.Thread.spawn(.{}, ServeProbe.run, .{&probe});
    const reaping = try std.Thread.spawn(.{}, Reaper.run, .{&reaper});
    var waited: u32 = 0;
    while (waited < 5000 and !probe.returned.load(.acquire)) : (waited += 50) io.sleep(.fromMilliseconds(50), .awake) catch {};
    const served = probe.returned.load(.acquire);
    if (!served) {
        reaper.expired.store(true, .release);
        reaper.knock();
    }
    serving.join();
    reaping.join();
    try testing.expect(served);
}
