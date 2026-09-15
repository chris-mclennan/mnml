//! The Jira REST client: one `request` through the rate limiter, and a
//! named wrapper per endpoint the pane uses. Nothing here knows about
//! panes, frames or keys — `tools/fake_jira` answers the same twelve
//! routes, so every test in this integration runs offline.
//!
//! **API version.** `v3` is Atlassian Cloud today: a description and a
//! comment body are ADF (a JSON document), and search is
//! `POST /rest/api/3/search/jql` with a `nextPageToken` — the old
//! `/rest/api/3/search` now answers 410. `v2` is a Server / Data Center
//! site: bodies are wiki-markup strings and search is
//! `GET /rest/api/2/search` with `startAt`. `Client.api` picks; the
//! callers below are written once and branch only where the wire differs.
//!
//! **Errors.** Every call returns either the parsed value or a
//! `Failure` carrying the status and a message read out of Jira's
//! `errorMessages` / `errors` object, because "400" on its own is
//! useless and Jira's own sentence is usually exactly right.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("json.zig");
const text = @import("text.zig");
const ratelimit = @import("ratelimit.zig");
const config = @import("config.zig");

pub const Value = std.json.Value;
pub const ApiVersion = config.ApiVersion;

/// The ceiling on one search, however many pages Jira offers.
pub const max_issues: usize = 500;
/// Rows per page.
pub const page_size: u32 = 100;
/// The fields every search asks for. `parent` carries the epic on a
/// team-managed project; `customfield_*` extras are added by the caller.
pub const search_fields = [_][]const u8{
    "summary",    "status",  "assignee", "reporter",       "priority",
    "issuetype",  "updated", "created",  "resolutiondate", "fixVersions",
    "components", "labels",  "parent",   "subtasks",
};

pub const Failure = struct {
    status: u16,
    /// Jira's own sentence where it sent one, else a generic line. Owned
    /// by the arena the call was given.
    message: []const u8,
};

pub const CallError = error{ Transport, OutOfMemory };

/// Every endpoint returns this: the value, or what the server said.
pub fn Answer(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: Failure,
    };
}

pub const Raw = struct {
    status: u16,
    body: []u8,
    retry_after_ms: ?u64,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    /// `https://acme.atlassian.net`, no trailing slash.
    base_url: []const u8,
    /// `Basic …`, built once by `auth.basicHeader`.
    authorization: []const u8,
    api: ApiVersion = .v3,
    limiter: ratelimit.Limiter,
    /// Milliseconds since the process started; the limiter's clock.
    clock_ms: u64 = 0,
    /// Set in tests so a wait is counted, not slept.
    sleep_enabled: bool = true,
    /// What the last `gate` made us wait — the tests read it.
    waited_ms: u64 = 0,
    user_agent: []const u8 = "mnml-jira",

    pub fn init(gpa: Allocator, io: Io, base_url: []const u8, authorization: []const u8, api: ApiVersion, rate: config.Rate) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .base_url = base_url,
            .authorization = authorization,
            .api = api,
            .limiter = ratelimit.Limiter.init(.{
                .rate_per_sec = rate.per_sec,
                .burst = rate.burst,
                .max_backoff_ms = @as(u64, rate.max_block_secs) * 1000,
                .default_retry_after_ms = @as(u64, rate.cooldown_secs) * 1000,
            }, 0),
        };
    }

    /// `/rest/api/3` or `/rest/api/2`.
    pub fn apiRoot(c: *const Client) []const u8 {
        return switch (c.api) {
            .v3 => "/rest/api/3",
            .v2 => "/rest/api/2",
        };
    }

    fn now(c: *Client) u64 {
        return c.clock_ms;
    }

    /// Wait for a permit. Returns the milliseconds spent waiting.
    fn gate(c: *Client) u64 {
        var waited: u64 = 0;
        while (true) {
            const wait = c.limiter.acquire(c.now());
            if (wait == 0) break;
            waited += wait;
            c.clock_ms += wait;
            if (c.sleep_enabled) c.io.sleep(.fromMilliseconds(@intCast(@min(wait, std.math.maxInt(i32)))), .awake) catch break;
            if (!c.sleep_enabled and waited > c.limiter.opts.max_backoff_ms) break;
        }
        c.waited_ms = waited;
        return waited;
    }

    /// One request, gated, with the body read into `arena`.
    pub fn request(c: *Client, arena: Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) CallError!Raw {
        _ = c.gate();
        var client: std.http.Client = .{ .allocator = c.gpa, .io = c.io };
        defer client.deinit();
        var out: Io.Writer.Allocating = .init(arena);
        // `std.http.Client.fetch` hands back a status and a body, not the
        // response headers, so a `Retry-After` cannot be read here: a 429
        // takes `rate.cooldown_secs` instead (the Rust tracker parses the
        // header nowhere either — its 429 path is unreached).
        const retry_after: ?u64 = null;
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = c.authorization },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "user-agent", .value = c.user_agent },
            .{ .name = "x-atlassian-force-account-id", .value = "true" },
        };
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &out.writer,
            .extra_headers = &headers,
            .headers = .{ .content_type = if (body == null) .default else .{ .override = "application/json" } },
            .keep_alive = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Transport,
        };
        const status: u16 = @intFromEnum(res.status);
        if (ratelimit.Limiter.shouldPenalise(status)) {
            c.limiter.penalise(c.now(), retry_after);
        } else {
            c.limiter.succeeded();
        }
        return .{ .status = status, .body = out.toOwnedSlice() catch return error.OutOfMemory, .retry_after_ms = retry_after };
    }
};

/// Jira's error shape: `{"errorMessages":["…"],"errors":{"field":"…"}}`.
/// Anything else becomes a line naming the status.
pub fn failureOf(arena: Allocator, status: u16, body: []const u8) Allocator.Error!Failure {
    const generic = switch (status) {
        401 => "401 — the token was refused (check the email and the API token)",
        403 => "403 — the token is valid but not allowed to do that",
        404 => "404 — no such issue, project or endpoint",
        410 => "410 — this Jira no longer serves that endpoint (try .api = .v2)",
        429 => "429 — rate limited; the next call backs off",
        else => "",
    };
    const parsed = std.json.parseFromSlice(Value, arena, body, .{}) catch {
        if (generic.len > 0) return .{ .status = status, .message = generic };
        return .{ .status = status, .message = try std.fmt.allocPrint(arena, "HTTP {d}", .{status}) };
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (json.array(parsed.value, "errorMessages")) |m| {
        if (json.str(m)) |s| {
            if (out.items.len > 0) try out.appendSlice(arena, "; ");
            try out.appendSlice(arena, s);
        }
    }
    if (json.get(parsed.value, "errors")) |errs| switch (errs) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (json.str(e.value_ptr.*)) |s| {
                    if (out.items.len > 0) try out.appendSlice(arena, "; ");
                    try out.appendSlice(arena, e.key_ptr.*);
                    try out.appendSlice(arena, ": ");
                    try out.appendSlice(arena, s);
                }
            }
        },
        else => {},
    };
    if (out.items.len == 0) {
        if (generic.len > 0) return .{ .status = status, .message = generic };
        return .{ .status = status, .message = try std.fmt.allocPrint(arena, "HTTP {d}", .{status}) };
    }
    return .{ .status = status, .message = try out.toOwnedSlice(arena) };
}

// ─── JQL surgery ─────────────────────────────────────────────────────────

/// Split a JQL into its `where` and its trailing `ORDER BY …`. Jira
/// rejects `(<where> ORDER BY x) AND <extra>`, so anything that adds a
/// clause has to take the order clause off first and put it back after.
/// The split is on the **last** case-insensitive `order by` that is not
/// inside double quotes.
pub fn splitOrderBy(jql: []const u8) struct { where: []const u8, order: []const u8 } {
    var in_quote = false;
    var best: ?usize = null;
    var i: usize = 0;
    while (i < jql.len) : (i += 1) {
        const c = jql[i];
        if (c == '\\' and in_quote) {
            i += 1;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        if (i + 8 <= jql.len and std.ascii.eqlIgnoreCase(jql[i .. i + 8], "order by")) {
            const before_ok = i == 0 or isJqlBreak(jql[i - 1]);
            if (before_ok) best = i;
        }
    }
    const cut = best orelse return .{ .where = std.mem.trim(u8, jql, " \t"), .order = "" };
    return .{
        .where = std.mem.trim(u8, jql[0..cut], " \t"),
        .order = std.mem.trim(u8, jql[cut..], " \t"),
    };
}

fn isJqlBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == ')' or c == '\n';
}

/// `"` → `\"` for a value going inside a JQL string literal.
pub fn escapeQuotes(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '"') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '"') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// `(<where>) AND ("<field>" = "<team>" OR component = "<team>" OR labels = "<team>") <order>`.
/// The team is matched three ways because sites disagree about where a
/// team lives; the clause goes to the server rather than being applied
/// client-side, which used to drop matches past the row cap.
pub fn withTeam(arena: Allocator, jql: []const u8, team: []const u8, field_name: []const u8, field_id: []const u8) Allocator.Error![]const u8 {
    if (team.len == 0) return jql;
    const parts = splitOrderBy(jql);
    const t = try escapeQuotes(arena, team);
    const field = if (field_name.len > 0) field_name else field_id;
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("({s}) AND (", .{parts.where}) catch return error.OutOfMemory;
    if (field.len > 0) w.print("\"{s}\" = \"{s}\" OR ", .{ field, t }) catch return error.OutOfMemory;
    w.print("component = \"{s}\" OR labels = \"{s}\")", .{ t, t }) catch return error.OutOfMemory;
    if (parts.order.len > 0) w.print(" {s}", .{parts.order}) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `project in (A, B) AND (<where>) <order>` — the statusline count's
/// scoping. An empty list leaves the JQL alone.
pub fn withProjects(arena: Allocator, jql: []const u8, projects: []const []const u8) Allocator.Error![]const u8 {
    if (projects.len == 0) return jql;
    const parts = splitOrderBy(jql);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("project in (") catch return error.OutOfMemory;
    for (projects, 0..) |p, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.writeAll(p) catch return error.OutOfMemory;
    }
    w.print(") AND ({s})", .{parts.where}) catch return error.OutOfMemory;
    if (parts.order.len > 0) w.print(" {s}", .{parts.order}) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `project = X AND fixVersion = "v" [AND component = "c"] ORDER BY rank`.
pub fn fixVersionJql(arena: Allocator, project: []const u8, version: []const u8, component: []const u8) Allocator.Error![]const u8 {
    const v = try escapeQuotes(arena, version);
    if (component.len == 0) return std.fmt.allocPrint(arena, "project = {s} AND fixVersion = \"{s}\" ORDER BY rank", .{ project, v });
    const c = try escapeQuotes(arena, component);
    return std.fmt.allocPrint(arena, "project = {s} AND fixVersion = \"{s}\" AND component = \"{s}\" ORDER BY rank", .{ project, v, c });
}

// ─── endpoints ───────────────────────────────────────────────────────────

pub const Page = struct {
    issues: []const Value,
    next_page_token: ?[]const u8,
    is_last: bool,
    total: ?i64,
};

/// One page of a JQL search. `token` is the previous page's
/// `next_page_token` (v3) or the row offset as a decimal string (v2).
pub fn searchPage(c: *Client, arena: Allocator, jql: []const u8, extra_fields: []const []const u8, limit: u32, token: ?[]const u8) CallError!Answer(Page) {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    try fields.appendSlice(arena, &search_fields);
    for (extra_fields) |f| if (f.len > 0) try fields.append(arena, f);

    const raw = switch (c.api) {
        .v3 => blk: {
            var body: Io.Writer.Allocating = .init(arena);
            var s: std.json.Stringify = .{ .writer = &body.writer };
            s.beginObject() catch return error.OutOfMemory;
            s.objectField("jql") catch return error.OutOfMemory;
            s.write(jql) catch return error.OutOfMemory;
            s.objectField("maxResults") catch return error.OutOfMemory;
            s.write(limit) catch return error.OutOfMemory;
            s.objectField("fields") catch return error.OutOfMemory;
            s.write(fields.items) catch return error.OutOfMemory;
            if (token) |t| {
                s.objectField("nextPageToken") catch return error.OutOfMemory;
                s.write(t) catch return error.OutOfMemory;
            }
            s.endObject() catch return error.OutOfMemory;
            const url = try std.fmt.allocPrint(arena, "{s}{s}/search/jql", .{ c.base_url, c.apiRoot() });
            break :blk try c.request(arena, .POST, url, body.written());
        },
        .v2 => blk: {
            const start = if (token) |t| std.fmt.parseInt(u32, t, 10) catch 0 else 0;
            const encoded = try text.urlEncode(arena, jql);
            const field_csv = try std.mem.join(arena, ",", fields.items);
            const url = try std.fmt.allocPrint(arena, "{s}{s}/search?jql={s}&maxResults={d}&startAt={d}&fields={s}", .{ c.base_url, c.apiRoot(), encoded, limit, start, field_csv });
            break :blk try c.request(arena, .GET, url, null);
        },
    };
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch {
        return .{ .failed = .{ .status = raw.status, .message = "the search answer was not JSON" } };
    };
    const issues = json.array(doc, "issues");
    const total = json.getInt(doc, "total");
    return .{ .ok = .{
        .issues = issues,
        .next_page_token = switch (c.api) {
            .v3 => json.getStr(doc, "nextPageToken"),
            .v2 => blk: {
                const start = if (token) |t| std.fmt.parseInt(u32, t, 10) catch 0 else 0;
                const seen: i64 = @as(i64, start) + @as(i64, @intCast(issues.len));
                if (total) |tt| if (seen < tt and issues.len > 0) break :blk try std.fmt.allocPrint(arena, "{d}", .{seen});
                break :blk null;
            },
        },
        .is_last = json.getBool(doc, "isLast") orelse false,
        .total = total,
    } };
}

/// Every page, up to `max_issues`.
pub fn search(c: *Client, arena: Allocator, jql: []const u8, extra_fields: []const []const u8) CallError!Answer([]const Value) {
    var all: std.ArrayListUnmanaged(Value) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        switch (try searchPage(c, arena, jql, extra_fields, page_size, token)) {
            .failed => |f| return .{ .failed = f },
            .ok => |p| {
                try all.appendSlice(arena, p.issues);
                if (all.items.len >= max_issues) {
                    all.shrinkRetainingCapacity(max_issues);
                    break;
                }
                const next = p.next_page_token orelse break;
                if (p.is_last or p.issues.len == 0) break;
                token = next;
            },
        }
    }
    return .{ .ok = try all.toOwnedSlice(arena) };
}

/// One issue with everything the detail pane shows.
pub fn issue(c: *Client, arena: Allocator, key: []const u8) CallError!Answer(Value) {
    const url = try std.fmt.allocPrint(
        arena,
        "{s}{s}/issue/{s}?fields=summary,status,assignee,reporter,priority,issuetype,updated,created,fixVersions,components,labels,parent,subtasks,description,comment,watches",
        .{ c.base_url, c.apiRoot(), key },
    );
    return getJson(c, arena, url);
}

pub const Transition = struct {
    id: []const u8,
    name: []const u8,
    to_name: []const u8,
};

pub fn transitions(c: *Client, arena: Allocator, key: []const u8) CallError!Answer([]const Transition) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/transitions", .{ c.base_url, c.apiRoot(), key });
    switch (try getJson(c, arena, url)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| {
            var out: std.ArrayListUnmanaged(Transition) = .empty;
            for (json.array(doc, "transitions")) |t| try out.append(arena, .{
                .id = json.getStrOr(t, "id", ""),
                .name = json.getStrOr(t, "name", "(unnamed)"),
                .to_name = json.getStrOr(t, "to.name", ""),
            });
            return .{ .ok = try out.toOwnedSlice(arena) };
        },
    }
}

pub fn doTransition(c: *Client, arena: Allocator, key: []const u8, id: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/transitions", .{ c.base_url, c.apiRoot(), key });
    const body = try std.fmt.allocPrint(arena, "{{\"transition\":{{\"id\":\"{s}\"}}}}", .{id});
    return voidCall(c, arena, .POST, url, body);
}

/// A comment. v3 takes an ADF document; v2 takes the text.
pub fn addComment(c: *Client, arena: Allocator, key: []const u8, plain: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/comment", .{ c.base_url, c.apiRoot(), key });
    var body: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &body.writer };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("body") catch return error.OutOfMemory;
    switch (c.api) {
        .v3 => writeAdf(&s, plain) catch return error.OutOfMemory,
        .v2 => s.write(plain) catch return error.OutOfMemory,
    }
    s.endObject() catch return error.OutOfMemory;
    return voidCall(c, arena, .POST, url, body.written());
}

/// `plain` as an ADF doc: one paragraph per line, a bare paragraph for a
/// blank one. No marks — a comment box is a comment box.
pub fn writeAdf(s: *std.json.Stringify, plain: []const u8) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("doc");
    try s.objectField("version");
    try s.write(1);
    try s.objectField("content");
    try s.beginArray();
    var it = std.mem.splitScalar(u8, plain, '\n');
    while (it.next()) |line| {
        try s.beginObject();
        try s.objectField("type");
        try s.write("paragraph");
        if (line.len > 0) {
            try s.objectField("content");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(line);
            try s.endObject();
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// `account_id` empty unassigns.
pub fn setAssignee(c: *Client, arena: Allocator, key: []const u8, account_id: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}", .{ c.base_url, c.apiRoot(), key });
    const body = if (account_id.len == 0)
        try arena.dupe(u8, "{\"fields\":{\"assignee\":null}}")
    else
        try std.fmt.allocPrint(arena, "{{\"fields\":{{\"assignee\":{{\"accountId\":\"{s}\"}}}}}}", .{account_id});
    return voidCall(c, arena, .PUT, url, body);
}

/// The one version this ticket is for; an empty name clears the list.
pub fn setFixVersion(c: *Client, arena: Allocator, key: []const u8, name: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}", .{ c.base_url, c.apiRoot(), key });
    var body: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &body.writer };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("fields") catch return error.OutOfMemory;
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("fixVersions") catch return error.OutOfMemory;
    s.beginArray() catch return error.OutOfMemory;
    if (name.len > 0) {
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(name) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    s.endArray() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return voidCall(c, arena, .PUT, url, body.written());
}

pub const NewIssue = struct {
    project: []const u8,
    issue_type: []const u8,
    summary: []const u8,
    description: []const u8 = "",
};

/// Create. The answer is the new key.
pub fn createIssue(c: *Client, arena: Allocator, n: NewIssue) CallError!Answer([]const u8) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue", .{ c.base_url, c.apiRoot() });
    var body: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &body.writer };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("fields") catch return error.OutOfMemory;
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("project") catch return error.OutOfMemory;
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("key") catch return error.OutOfMemory;
    s.write(n.project) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    s.objectField("issuetype") catch return error.OutOfMemory;
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("name") catch return error.OutOfMemory;
    s.write(n.issue_type) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    s.objectField("summary") catch return error.OutOfMemory;
    s.write(n.summary) catch return error.OutOfMemory;
    if (n.description.len > 0) {
        s.objectField("description") catch return error.OutOfMemory;
        switch (c.api) {
            .v3 => writeAdf(&s, n.description) catch return error.OutOfMemory,
            .v2 => s.write(n.description) catch return error.OutOfMemory,
        }
    }
    s.endObject() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    const raw = try c.request(arena, .POST, url, body.written());
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch {
        return .{ .failed = .{ .status = raw.status, .message = "the create answer was not JSON" } };
    };
    return .{ .ok = json.getStrOr(doc, "key", "") };
}

pub const PullRequest = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    url: []const u8,
    repo: []const u8,
    source_branch: []const u8,
    dest_branch: []const u8,
    approvals: u16,

    pub fn isOpen(p: PullRequest) bool {
        return std.ascii.eqlIgnoreCase(p.status, "OPEN") or
            std.ascii.eqlIgnoreCase(p.status, "DRAFT") or
            std.ascii.eqlIgnoreCase(p.status, "IN_REVIEW");
    }
};

/// The PRs a ticket carries. Two sources, in order:
///
///   1. `/rest/dev-status/latest/issue/detail` — Atlassian's dev panel,
///      which is what actually knows about the branch and the reviewers.
///      It wants the issue's numeric **id**, not its key.
///   2. `{api}/issue/{key}/remotelink` — the public remote-links list,
///      which a site without the dev panel (or a PR linked by hand)
///      still answers.
///
/// A 404 from either is "no PRs", not a failure: a ticket nobody has
/// branched for is the normal case.
pub fn pullRequests(c: *Client, arena: Allocator, key: []const u8, issue_id: []const u8) CallError!Answer([]const PullRequest) {
    var out: std.ArrayListUnmanaged(PullRequest) = .empty;
    if (issue_id.len > 0) {
        const url = try std.fmt.allocPrint(
            arena,
            "{s}/rest/dev-status/latest/issue/detail?issueId={s}&applicationType=bitbucket&dataType=pullrequest",
            .{ c.base_url, issue_id },
        );
        const raw = try c.request(arena, .GET, url, null);
        if (raw.status >= 200 and raw.status < 300) {
            const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch Value{ .null = {} };
            for (json.array(doc, "detail")) |d| {
                for (json.array(d, "pullRequests")) |p| try out.append(arena, .{
                    .id = json.getStrOr(p, "id", ""),
                    .title = json.getStrOr(p, "name", ""),
                    .status = json.getStrOr(p, "status", ""),
                    .url = json.getStrOr(p, "url", ""),
                    .repo = json.getStrOr(p, "repositoryName", ""),
                    .source_branch = json.getStrOr(p, "source.branch", ""),
                    .dest_branch = json.getStrOr(p, "destination.branch", ""),
                    .approvals = countApprovals(json.array(p, "reviewers")),
                });
            }
            if (out.items.len > 0) return .{ .ok = try out.toOwnedSlice(arena) };
        } else if (raw.status != 404) {
            // A real refusal (401/403) is worth showing once; fall
            // through to remote links only on 404.
            if (raw.status == 401 or raw.status == 403) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
        }
    }
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/remotelink", .{ c.base_url, c.apiRoot(), key });
    const raw = try c.request(arena, .GET, url, null);
    if (raw.status == 404) return .{ .ok = &.{} };
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch Value{ .null = {} };
    const links: []const Value = switch (doc) {
        .array => |a| a.items,
        else => &.{},
    };
    for (links) |l| {
        const href = json.getStrOr(l, "object.url", "");
        if (!looksLikePr(href)) continue;
        try out.append(arena, .{
            .id = json.getStrOr(l, "object.title", href),
            .title = json.getStrOr(l, "object.summary", json.getStrOr(l, "object.title", "")),
            .status = json.getStrOr(l, "object.status.icon.title", ""),
            .url = href,
            .repo = repoOf(href),
            .source_branch = "",
            .dest_branch = "",
            .approvals = 0,
        });
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

fn countApprovals(reviewers: []const Value) u16 {
    var n: u16 = 0;
    for (reviewers) |r| if (json.getBool(r, "approved") orelse false) {
        n += 1;
    };
    return n;
}

/// A remote link that points at a pull request on one of the forges.
pub fn looksLikePr(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "/pull-requests/") != null or
        std.mem.indexOf(u8, url, "/pull/") != null or
        std.mem.indexOf(u8, url, "/merge_requests/") != null;
}

/// `https://bitbucket.org/ws/repo/pull-requests/12` → `repo`.
pub fn repoOf(url: []const u8) []const u8 {
    const marker = std.mem.indexOf(u8, url, "/pull-requests/") orelse
        std.mem.indexOf(u8, url, "/pull/") orelse
        std.mem.indexOf(u8, url, "/merge_requests/") orelse return "";
    const head = url[0..marker];
    const slash = std.mem.lastIndexOfScalar(u8, head, '/') orelse return "";
    return head[slash + 1 ..];
}

pub const User = struct { account_id: []const u8, display_name: []const u8 };

/// Who the token belongs to. A scoped token often cannot answer this
/// while being perfectly able to search, so a failure here must only
/// cost the "me" features — never the pane.
pub fn myself(c: *Client, arena: Allocator) CallError!Answer(User) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/myself", .{ c.base_url, c.apiRoot() });
    switch (try getJson(c, arena, url)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| return .{ .ok = .{
            .account_id = json.getStrOr(doc, "accountId", ""),
            .display_name = json.getStrOr(doc, "displayName", ""),
        } },
    }
}

pub fn assignableUsers(c: *Client, arena: Allocator, project: []const u8) CallError!Answer([]const User) {
    const p = try text.urlEncode(arena, project);
    const url = try std.fmt.allocPrint(arena, "{s}{s}/user/assignable/search?project={s}&maxResults=50", .{ c.base_url, c.apiRoot(), p });
    const raw = try c.request(arena, .GET, url, null);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch Value{ .null = {} };
    const items: []const Value = switch (doc) {
        .array => |a| a.items,
        else => json.array(doc, "values"),
    };
    var out: std.ArrayListUnmanaged(User) = .empty;
    for (items) |u| {
        const id = json.getStrOr(u, "accountId", "");
        if (id.len == 0) continue;
        try out.append(arena, .{ .account_id = id, .display_name = json.getStrOr(u, "displayName", id) });
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

pub const Version = struct {
    name: []const u8,
    released: bool,
    archived: bool,
    start_date: []const u8,
    release_date: []const u8,
};

pub fn projectVersions(c: *Client, arena: Allocator, project: []const u8) CallError!Answer([]const Version) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/project/{s}/versions", .{ c.base_url, c.apiRoot(), project });
    const raw = try c.request(arena, .GET, url, null);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch Value{ .null = {} };
    const items: []const Value = switch (doc) {
        .array => |a| a.items,
        else => json.array(doc, "values"),
    };
    var out: std.ArrayListUnmanaged(Version) = .empty;
    for (items) |v| try out.append(arena, .{
        .name = json.getStrOr(v, "name", ""),
        .released = json.getBool(v, "released") orelse false,
        .archived = json.getBool(v, "archived") orelse false,
        .start_date = json.getStrOr(v, "startDate", ""),
        .release_date = json.getStrOr(v, "releaseDate", ""),
    });
    return .{ .ok = try out.toOwnedSlice(arena) };
}

/// The unreleased versions, in the order a release tab reads them:
/// `startDate` ascending with the undated last, and **name descending**
/// between two undated ones — which is the case that actually happens,
/// because most projects never set a start date and `13.16.0` is the one
/// being worked on, not `13.1.0`. `contains` (case-insensitive) narrows
/// to one release track first.
pub fn unreleasedVersions(arena: Allocator, all: []const Version, contains: []const u8) Allocator.Error![]const Version {
    var keep: std.ArrayListUnmanaged(Version) = .empty;
    for (all) |v| {
        if (v.released) continue;
        if (contains.len > 0 and !text.containsIgnoreCase(v.name, contains)) continue;
        try keep.append(arena, v);
    }
    std.mem.sort(Version, keep.items, {}, versionBefore);
    return keep.toOwnedSlice(arena);
}

fn versionBefore(_: void, a: Version, b: Version) bool {
    const ad = a.start_date.len > 0;
    const bd = b.start_date.len > 0;
    if (ad and bd) {
        const c = std.mem.order(u8, a.start_date, b.start_date);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, a.name, b.name) == .gt;
    }
    if (ad != bd) return ad;
    return std.mem.order(u8, a.name, b.name) == .gt;
}

/// The version a `fix_version` tab means: the newest unreleased one, or
/// the one after it.
pub fn pickVersion(list: []const Version, mode: config.ResolveMode) ?Version {
    if (list.len == 0) return null;
    return switch (mode) {
        .current_release => list[0],
        .next_release => if (list.len > 1) list[1] else list[0],
    };
}

// ─── shared shapes ───────────────────────────────────────────────────────

fn getJson(c: *Client, arena: Allocator, url: []const u8) CallError!Answer(Value) {
    const raw = try c.request(arena, .GET, url, null);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch {
        return .{ .failed = .{ .status = raw.status, .message = "the answer was not JSON" } };
    };
    return .{ .ok = doc };
}

fn voidCall(c: *Client, arena: Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) CallError!Answer(void) {
    const raw = try c.request(arena, method, url, body);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    return .{ .ok = {} };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "splitOrderBy takes the last one outside quotes, and leaves a JQL without one alone" {
    const a = splitOrderBy("project = X AND summary ~ \"order by me\" ORDER BY rank ASC");
    try testing.expectEqualStrings("project = X AND summary ~ \"order by me\"", a.where);
    try testing.expectEqualStrings("ORDER BY rank ASC", a.order);
    const b = splitOrderBy("project = X");
    try testing.expectEqualStrings("project = X", b.where);
    try testing.expectEqualStrings("", b.order);
    // Lower case, and a `)` immediately before it.
    const c = splitOrderBy("(a = 1 OR b = 2) order by updated DESC");
    try testing.expectEqualStrings("(a = 1 OR b = 2)", c.where);
    try testing.expectEqualStrings("order by updated DESC", c.order);
    // A field called `reorder by` must not be mistaken for the clause.
    const d = splitOrderBy("reorder by = 1");
    try testing.expectEqualStrings("reorder by = 1", d.where);
    try testing.expectEqualStrings("", d.order);
}

test "the team clause goes to the server, wrapping the where and keeping the order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const with = try withTeam(arena, "assignee = currentUser() ORDER BY updated DESC", "Apollo", "Team", "customfield_1");
    try testing.expectEqualStrings(
        "(assignee = currentUser()) AND (\"Team\" = \"Apollo\" OR component = \"Apollo\" OR labels = \"Apollo\") ORDER BY updated DESC",
        with,
    );
    // No display name: the custom-field id is quoted instead.
    const by_id = try withTeam(arena, "project = X", "T", "", "customfield_1");
    try testing.expect(std.mem.indexOf(u8, by_id, "\"customfield_1\" = \"T\"") != null);
    // No field at all: component and labels still match.
    const no_field = try withTeam(arena, "project = X", "T", "", "");
    try testing.expectEqualStrings("(project = X) AND (component = \"T\" OR labels = \"T\")", no_field);
    // An empty team is a no-op, not an empty clause.
    try testing.expectEqualStrings("project = X", try withTeam(arena, "project = X", "", "Team", ""));
    // A quote in the value is escaped, never left to break the query.
    const quoted = try withTeam(arena, "project = X", "a\"b", "Team", "");
    try testing.expect(std.mem.indexOf(u8, quoted, "\\\"") != null);
}

test "withProjects scopes a JQL and keeps its order clause" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings(
        "project in (ENG, OPS) AND (assignee = currentUser()) ORDER BY updated DESC",
        try withProjects(arena, "assignee = currentUser() ORDER BY updated DESC", &.{ "ENG", "OPS" }),
    );
    try testing.expectEqualStrings("a = 1", try withProjects(arena, "a = 1", &.{}));
}

test "fixVersionJql escapes the version name — in both the resolve and the picker path" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings(
        "project = ENG AND fixVersion = \"13.15.0\" ORDER BY rank",
        try fixVersionJql(arena, "ENG", "13.15.0", ""),
    );
    try testing.expectEqualStrings(
        "project = ENG AND fixVersion = \"13.15.0\" AND component = \"api\" ORDER BY rank",
        try fixVersionJql(arena, "ENG", "13.15.0", "api"),
    );
    const nasty = try fixVersionJql(arena, "ENG", "a\"b", "");
    try testing.expect(std.mem.indexOf(u8, nasty, "\"a\\\"b\"") != null);
}

test "unreleasedVersions: released ones go, the name filter narrows, and undated names sort descending" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const all = [_]Version{
        .{ .name = "13.14.0", .released = true, .archived = false, .start_date = "", .release_date = "" },
        .{ .name = "13.15.0", .released = false, .archived = false, .start_date = "", .release_date = "" },
        .{ .name = "13.16.0", .released = false, .archived = false, .start_date = "", .release_date = "" },
        .{ .name = "Mobile - 1.6.X", .released = false, .archived = false, .start_date = "", .release_date = "" },
    };
    const open = try unreleasedVersions(arena, &all, "");
    try testing.expectEqual(@as(usize, 3), open.len);
    // Name descending: the newest release is first, which is what
    // `current_release` means.
    try testing.expectEqualStrings("Mobile - 1.6.X", open[0].name);
    try testing.expectEqualStrings("13.16.0", open[1].name);
    try testing.expectEqualStrings("13.15.0", open[2].name);
    try testing.expectEqualStrings("Mobile - 1.6.X", pickVersion(open, .current_release).?.name);
    try testing.expectEqualStrings("13.15.0", pickVersion(open[1..], .next_release).?.name);
    // The name filter picks one release track out of the parallel ones.
    const track = try unreleasedVersions(arena, &all, "13.");
    try testing.expectEqual(@as(usize, 2), track.len);
    try testing.expectEqualStrings("13.16.0", track[0].name);
    try testing.expectEqualStrings("13.16.0", pickVersion(track, .current_release).?.name);
    try testing.expectEqualStrings("13.15.0", pickVersion(track, .next_release).?.name);
    // A dated version sorts before an undated one whatever its name.
    const dated = [_]Version{
        .{ .name = "1.0", .released = false, .archived = false, .start_date = "", .release_date = "" },
        .{ .name = "0.9", .released = false, .archived = false, .start_date = "2026-01-01", .release_date = "" },
    };
    const d = try unreleasedVersions(arena, &dated, "");
    try testing.expectEqualStrings("0.9", d[0].name);
    try testing.expect(pickVersion(&.{}, .current_release) == null);
}

test "a Jira error answer becomes the sentence Jira wrote, not the number" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const f = try failureOf(arena, 400, "{\"errorMessages\":[\"Field 'wat' does not exist.\"],\"errors\":{}}");
    try testing.expectEqualStrings("Field 'wat' does not exist.", f.message);
    const g = try failureOf(arena, 400, "{\"errorMessages\":[],\"errors\":{\"summary\":\"is required\"}}");
    try testing.expectEqualStrings("summary: is required", g.message);
    // No JSON, but a status worth explaining.
    const h = try failureOf(arena, 401, "<html>nope</html>");
    try testing.expect(std.mem.indexOf(u8, h.message, "token was refused") != null);
    const i = try failureOf(arena, 410, "");
    try testing.expect(std.mem.indexOf(u8, i.message, ".api = .v2") != null);
    // Nothing to say: the number, at least.
    const j = try failureOf(arena, 418, "{}");
    try testing.expectEqualStrings("HTTP 418", j.message);
}

test "ADF: one paragraph per line, a bare one for a blank line" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try writeAdf(&s, "first\n\nthird");
    try testing.expectEqualStrings(
        "{\"type\":\"doc\",\"version\":1,\"content\":[" ++
            "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"first\"}]}," ++
            "{\"type\":\"paragraph\"}," ++
            "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"third\"}]}]}",
        out.written(),
    );
}

test "a remote link is a PR link only when its URL says so; the repo is the segment before" {
    try testing.expect(looksLikePr("https://bitbucket.org/acme/web/pull-requests/12"));
    try testing.expect(looksLikePr("https://github.com/acme/web/pull/12"));
    try testing.expect(looksLikePr("https://gitlab.com/acme/web/-/merge_requests/12"));
    try testing.expect(!looksLikePr("https://confluence/x/y"));
    try testing.expectEqualStrings("web", repoOf("https://bitbucket.org/acme/web/pull-requests/12"));
    try testing.expectEqualStrings("web", repoOf("https://github.com/acme/web/pull/12"));
    try testing.expectEqualStrings("", repoOf("nope"));
}

test "a PR's open-ness is read from its status, whatever the case" {
    const open: PullRequest = .{ .id = "#1", .title = "", .status = "open", .url = "", .repo = "", .source_branch = "", .dest_branch = "", .approvals = 0 };
    const merged: PullRequest = .{ .id = "#2", .title = "", .status = "MERGED", .url = "", .repo = "", .source_branch = "", .dest_branch = "", .approvals = 2 };
    try testing.expect(open.isOpen());
    try testing.expect(!merged.isOpen());
}

test "the api root follows the version, and the search field list carries what a row paints" {
    var c: Client = .{ .gpa = testing.allocator, .io = testing.io, .base_url = "https://x", .authorization = "", .limiter = ratelimit.Limiter.init(.{}, 0) };
    try testing.expectEqualStrings("/rest/api/3", c.apiRoot());
    c.api = .v2;
    try testing.expectEqualStrings("/rest/api/2", c.apiRoot());
    var saw_parent = false;
    var saw_subtasks = false;
    for (search_fields) |f| {
        if (std.mem.eql(u8, f, "parent")) saw_parent = true;
        if (std.mem.eql(u8, f, "subtasks")) saw_subtasks = true;
    }
    try testing.expect(saw_parent and saw_subtasks);
}

// ─── the wire, end to end ────────────────────────────────────────────────
//
// `tools/fake_jira` is the same store the unit tests above drive as a
// pure function; here it is behind a real socket, so the client's URLs,
// headers, bodies and status handling are all exercised against an
// answer that came off a TCP connection.

pub const fake = @import("../tools/fake_jira/main.zig");

/// A fake Jira behind a real socket. `app.zig`'s tests drive the whole
/// pane against it, so it is public rather than test-private.
pub const Loopback = struct {
    store: *fake.Store,
    server: *Io.net.Server,
    /// Requests served, for the test to read back.
    served: usize = 0,

    /// Serve until the client asks for `/__done`. Counting requests
    /// instead would make every one of these tests brittle: adding a
    /// call to the client would hang the loop on an accept that never
    /// comes, and `group.await` with it.
    pub fn serve(io: Io, lb: *Loopback) Io.Cancelable!void {
        while (true) {
            lb.served += 1;
            const stream = lb.server.accept(io) catch return;
            defer stream.close(io);
            var arena_state = std.heap.ArenaAllocator.init(lb.store.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            // Small buffers on purpose: this runs on a pool thread, and
            // 160 KB of stack there is a corrupted arena, not a crash
            // that names itself.
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var reader = stream.reader(io, &rbuf);
            var writer = stream.writer(io, &wbuf);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http.receiveHead() catch return;
            var authorization: ?[]const u8 = null;
            var it = request.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = arena.dupe(u8, h.value) catch null;
            }
            // `head.target` and every header value are slices of the
            // reader's buffer, which reading the body refills: copy them
            // out FIRST or they turn into garbage lengths.
            const target = arena.dupe(u8, request.head.target) catch return;
            var body_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_buf);
            const body_store = arena.alloc(u8, 64 * 1024) catch return;
            const got = body_reader.readSliceShort(body_store) catch 0;
            const res = lb.store.handle(arena, request.head.method, target, authorization, body_store[0..got]) catch
                fake.Response{ .status = 500, .body = "{}" };
            request.respond(res.body, .{
                .status = @enumFromInt(res.status),
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
            if (std.mem.startsWith(u8, target, "/__done")) return;
        }
    }

    /// The last request of a test: it ends the loop so `await` returns.
    pub fn finish(lb: *Loopback, c: *Client, arena: Allocator) !void {
        _ = lb;
        const url = try std.fmt.allocPrint(arena, "{s}/__done", .{c.base_url});
        _ = c.request(arena, .GET, url, null) catch {};
    }
};

test "the client against a real socket: search, detail, transitions, a comment, an assignment, a create, the PRs" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try fake.Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var lb: Loopback = .{ .store = &store, .server = &server };
    var group: Io.Group = .init;
    try group.concurrent(io, Loopback.serve, .{ io, &lb });
    defer group.cancel(io);

    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    // `fake@acme.com` / `fake-token` is the credential the fake accepts.
    const authorization = try @import("auth.zig").basicHeader(arena, "fake@acme.com", "fake-token");
    // A rate high enough that pacing never sleeps, but not zero: zero
    // turns the limiter off, and the 429 test below needs it on.
    var c = Client.init(testing.allocator, io, base, authorization, .v3, .{ .per_sec = 10_000, .burst = 100 });

    // 1. The whole project.
    const all = switch (try search(&c, arena, "project = ENG ORDER BY rank", &.{})) {
        .ok => |v| v,
        .failed => |f| {
            std.debug.print("search failed: {d} {s}\n", .{ f.status, f.message });
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqualStrings("ENG-1", json.getStrOr(all[0], "key", ""));
    try testing.expectEqualStrings("Checkout rewrite", json.getStrOr(all[0], "fields.summary", ""));
    try testing.expectEqualStrings("indeterminate", json.getStrOr(all[0], "fields.status.statusCategory.key", ""));
    try testing.expectEqualStrings("ENG-1", json.getStrOr(all[1], "fields.parent.key", ""));

    // 2. One issue, with its description and comments.
    const one = switch (try issue(&c, arena, "ENG-2")) {
        .ok => |v| v,
        .failed => return error.TestUnexpectedResult,
    };
    const body = try json.renderBody(arena, json.get(one, "fields.description"));
    try testing.expect(std.mem.indexOf(u8, body, "loses focus") != null);
    try testing.expectEqual(@as(usize, 2), json.array(one, "fields.comment.comments").len);

    // 3. The transitions ENG-3 offers, and firing one.
    const ts = switch (try transitions(&c, arena, "ENG-3")) {
        .ok => |v| v,
        .failed => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 3), ts.len);
    var start_id: []const u8 = "";
    for (ts) |t| if (std.mem.eql(u8, t.to_name, "In Progress")) {
        start_id = t.id;
    };
    try testing.expect(start_id.len > 0);
    try testing.expect((try doTransition(&c, arena, "ENG-3", start_id)) == .ok);
    try testing.expectEqualStrings("In Progress", store.find("ENG-3").?.status);

    // 4. A comment, and an assignment.
    try testing.expect((try addComment(&c, arena, "ENG-3", "picking this up")) == .ok);
    try testing.expect(std.mem.indexOf(u8, store.find("ENG-3").?.comments.items[0], "picking this up") != null);
    try testing.expect((try setAssignee(&c, arena, "ENG-3", fake.account_me)) == .ok);
    try testing.expectEqualStrings(fake.account_me, store.find("ENG-3").?.assignee);

    // 5. Create.
    const made = switch (try createIssue(&c, arena, .{ .project = "ENG", .issue_type = "Bug", .summary = "From the pane" })) {
        .ok => |k| k,
        .failed => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("ENG-91", made);

    // 6. The PRs — the dev-status panel for ENG-2 …
    const prs = switch (try pullRequests(&c, arena, "ENG-2", "10002")) {
        .ok => |v| v,
        .failed => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), prs.len);
    try testing.expectEqualStrings("#2023", prs[0].id);
    try testing.expectEqualStrings("checkout", prs[0].repo);
    try testing.expectEqual(@as(u16, 2), prs[0].approvals);
    try testing.expect(!prs[0].isOpen());
    try testing.expect(prs[1].isOpen());

    // 7. … and the remote-links fallback for ENG-5, whose dev panel is
    //    empty and whose PR was linked by hand. The non-PR link is not
    //    a PR row.
    const links = switch (try pullRequests(&c, arena, "ENG-5", "10005")) {
        .ok => |v| v,
        .failed => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqualStrings("https://bitbucket.org/acme/basket/pull-requests/77", links[0].url);
    try testing.expectEqualStrings("basket", links[0].repo);

    try lb.finish(&c, arena);
    try group.await(io);
}

test "a refusal comes back as Jira's own sentence, and the limiter pauses after a 429" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try fake.Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var lb: Loopback = .{ .store = &store, .server = &server };
    var group: Io.Group = .init;
    try group.concurrent(io, Loopback.serve, .{ io, &lb });
    defer group.cancel(io);

    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var c = Client.init(testing.allocator, io, base, "Basic bm9wZQ==", .v3, .{ .per_sec = 10_000, .burst = 100 });
    c.sleep_enabled = false;

    // A bad credential is Jira's 401 sentence, not a number.
    switch (try search(&c, arena, "project = ENG", &.{})) {
        .ok => return error.TestUnexpectedResult,
        .failed => |f| {
            try testing.expectEqual(@as(u16, 401), f.status);
            try testing.expect(std.mem.indexOf(u8, f.message, "must be authenticated") != null);
        },
    }

    // A 429 from the server pushes the next permit out by the cooldown.
    store.require_auth = false;
    store.fail_with = 429;
    _ = try search(&c, arena, "project = ENG", &.{});
    try testing.expect(c.limiter.strikes > 0);
    try testing.expect(c.limiter.acquire(c.clock_ms) > 0);
    // A good answer clears the strikes.
    store.fail_with = null;
    c.limiter.blocked_until_ms = 0;
    _ = try search(&c, arena, "project = ENG", &.{});
    try testing.expectEqual(@as(u32, 0), c.limiter.strikes);

    try lb.finish(&c, arena);
    try group.await(io);
}
