//! The fake Bitbucket Cloud — the routing table and the canned
//! workspace, with no socket anywhere in sight. `handle` is a pure
//! function of a request and a small mutable `State`, so the routing,
//! the BBQL filtering, the approval toggle and the merge are all unit
//! testable, and `main.zig` is only the loop that carries bytes.
//!
//! The workspace is `acme`, with `api` and `web`. Four pull requests,
//! one of them merged, one with a reviewer who asked for changes, one
//! that quotes a Jira key in its description. The account the token
//! belongs to is `acct-chris` (Chris M) — so "PRs I opened" returns
//! two and "PRs to review" returns one.
//!
//! What it deliberately does *not* fake: pagination past one page,
//! pipelines, and branch listing. Those are not what the pane reads.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Reply = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    /// Owned by the arena passed to `handle`.
    body: []const u8 = "",
    /// Sent on a 429 so the client's backoff has something to read.
    retry_after_secs: ?u32 = null,
};

pub const Method = enum { GET, POST, PUT, DELETE, other };

pub fn methodOf(s: []const u8) Method {
    return std.meta.stringToEnum(Method, s) orelse .other;
}

pub const me_account_id = "acct-chris";
pub const me_display_name = "Chris M";
pub const workspace = "acme";

/// What a request changed. Everything the pane can write lands here so
/// a test can assert the effect rather than the request.
pub const State = struct {
    /// The account's own vote per PR id, in the order `Vote` declares.
    votes: [16]Vote = @splat(.none),
    /// Comments the pane posted, newest last.
    comments: [16]Posted = @splat(.{}),
    comment_count: usize = 0,
    /// PR ids the pane merged.
    merged: [8]u32 = @splat(0),
    merged_count: usize = 0,
    /// Answer the next `n` requests with a 429 — the retry path.
    rate_limit_next: u32 = 0,
    /// Answer `/2.0/user` with a 403, the way a token without
    /// **Account: Read** does. Everything else still works — which is
    /// exactly the case a `mine` tab's fallback exists for.
    deny_user: bool = false,
    /// Requests served, 429s included.
    served: u32 = 0,
    /// Requests that arrived with no (or a bad) Authorization header.
    unauthorized: u32 = 0,
    /// Set when a write arrived; the corpus proves the write token
    /// reached the wire without ever printing it.
    last_auth_was_write: bool = false,

    pub const Vote = enum { none, approved, changes_requested };

    pub const Posted = struct {
        pr_id: u32 = 0,
        text: []const u8 = "",
        path: []const u8 = "",
        line: i64 = 0,
    };

    fn voteSlot(self: *State, id: u32) *Vote {
        return &self.votes[@as(usize, id) % self.votes.len];
    }

    pub fn voteFor(self: *const State, id: u32) Vote {
        return self.votes[@as(usize, id) % self.votes.len];
    }

    pub fn isMerged(self: *const State, id: u32) bool {
        for (self.merged[0..self.merged_count]) |m| if (m == id) return true;
        return false;
    }

    pub fn commentsFor(self: *const State, id: u32, out: *[16]Posted) []const Posted {
        var n: usize = 0;
        for (self.comments[0..self.comment_count]) |c| {
            if (c.pr_id == id) {
                out[n] = c;
                n += 1;
            }
        }
        return out[0..n];
    }
};

/// A pull request in the canned workspace.
pub const Fixture = struct {
    repo: []const u8,
    id: u32,
    title: []const u8,
    state: []const u8,
    author_id: []const u8,
    author_name: []const u8,
    source_branch: []const u8,
    dest_branch: []const u8 = "main",
    source_sha: []const u8,
    description: []const u8,
    draft: bool = false,
    reviewers: []const Reviewer,
    /// `SUCCESSFUL` / `FAILED` / `INPROGRESS` — one per build status.
    builds: []const Build,
    files: []const File,
    diff: []const u8,
    /// Comments that were already there before the pane posted any.
    activity: []const Existing,

    pub const Reviewer = struct {
        id: []const u8,
        name: []const u8,
        vote: State.Vote = .none,
    };
    pub const Build = struct { key: []const u8, name: []const u8, state: []const u8 };
    pub const File = struct { status: []const u8, path: []const u8, added: i64, removed: i64 };
    pub const Existing = struct {
        id: u32,
        author: []const u8,
        date: []const u8,
        text: []const u8,
        path: []const u8 = "",
        line: i64 = 0,
        parent: u32 = 0,
    };
};

pub const fixtures = [_]Fixture{
    .{
        .repo = "api",
        .id = 1234,
        .title = "Fix the login redirect",
        .state = "OPEN",
        .author_id = me_account_id,
        .author_name = me_display_name,
        .source_branch = "chris/fix-login",
        .source_sha = "abc1234def5678",
        .description = "Fixes ENG-4210. The redirect dropped the query string when the session had expired.",
        .reviewers = &.{
            .{ .id = "acct-dana", .name = "Dana R", .vote = .approved },
            .{ .id = "acct-sam", .name = "Sam K", .vote = .changes_requested },
        },
        .builds = &.{
            .{ .key = "pipe-build", .name = "Pipeline #412", .state = "SUCCESSFUL" },
            .{ .key = "pipe-deploy", .name = "Deploy to dev", .state = "FAILED" },
        },
        .files = &.{
            .{ .status = "modified", .path = "src/auth/session.zig", .added = 18, .removed = 4 },
            .{ .status = "added", .path = "tests/redirect.test", .added = 31, .removed = 0 },
        },
        .diff =
        \\diff --git a/src/auth/session.zig b/src/auth/session.zig
        \\index 1111111..2222222 100644
        \\--- a/src/auth/session.zig
        \\+++ b/src/auth/session.zig
        \\@@ -40,7 +40,9 @@ pub fn redirectTarget(req: Request) []const u8 {
        \\     if (req.session == null) {
        \\-        return "/login";
        \\+        // Keep the query string so the user lands back where
        \\+        // they were once the login round trip finishes.
        \\+        return withQuery("/login", req.query);
        \\     }
        \\     return req.path;
        \\ }
        \\diff --git a/tests/redirect.test b/tests/redirect.test
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/tests/redirect.test
        \\@@ -0,0 +1,3 @@
        \\+open src/auth/session.zig
        \\+expect screen contains "withQuery"
        ,
        .activity = &.{
            .{ .id = 9001, .author = "Dana R", .date = "2026-09-01T10:00:00+00:00", .text = "Nice catch — this has bitten us twice." },
            .{ .id = 9002, .author = "Sam K", .date = "2026-09-01T11:00:00+00:00", .text = "withQuery needs to escape the value here.", .path = "src/auth/session.zig", .line = 44 },
            .{ .id = 9003, .author = "Chris M", .date = "2026-09-01T11:30:00+00:00", .text = "Good point, pushed an escape.", .parent = 9002, .path = "src/auth/session.zig", .line = 44 },
        },
    },
    .{
        .repo = "api",
        .id = 1198,
        .title = "Bump the client timeout to 30s",
        .state = "OPEN",
        .author_id = "acct-dana",
        .author_name = "Dana R",
        .source_branch = "dana/timeout",
        .source_sha = "bbb2222ccc3333",
        .description = "The 10s default trips on a cold start.",
        .reviewers = &.{.{ .id = me_account_id, .name = me_display_name }},
        .builds = &.{.{ .key = "pipe-build", .name = "Pipeline #409", .state = "SUCCESSFUL" }},
        .files = &.{.{ .status = "modified", .path = "src/http/client.zig", .added = 2, .removed = 2 }},
        .diff =
        \\diff --git a/src/http/client.zig b/src/http/client.zig
        \\--- a/src/http/client.zig
        \\+++ b/src/http/client.zig
        \\@@ -12,2 +12,2 @@
        \\-const timeout_ms = 10_000;
        \\+const timeout_ms = 30_000;
        ,
        .activity = &.{},
    },
    .{
        .repo = "web",
        .id = 820,
        .title = "Redesign the empty state",
        .state = "OPEN",
        .author_id = me_account_id,
        .author_name = me_display_name,
        .source_branch = "chris/empty-state",
        .source_sha = "ddd4444eee5555",
        .description = "Part of ENG-4300.",
        .draft = true,
        .reviewers = &.{},
        .builds = &.{.{ .key = "pipe-build", .name = "Pipeline #77", .state = "INPROGRESS" }},
        .files = &.{.{ .status = "modified", .path = "src/views/empty.zig", .added = 60, .removed = 22 }},
        .diff = "diff --git a/src/views/empty.zig b/src/views/empty.zig\n@@ -1,1 +1,1 @@\n-old\n+new\n",
        .activity = &.{},
    },
    .{
        .repo = "api",
        .id = 1100,
        .title = "Drop the legacy exporter",
        .state = "MERGED",
        .author_id = "acct-sam",
        .author_name = "Sam K",
        .source_branch = "sam/drop-exporter",
        .source_sha = "fff6666aaa7777",
        .description = "",
        .reviewers = &.{.{ .id = me_account_id, .name = me_display_name, .vote = .approved }},
        .builds = &.{},
        .files = &.{.{ .status = "removed", .path = "src/export/legacy.zig", .added = 0, .removed = 240 }},
        .diff = "diff --git a/src/export/legacy.zig b/src/export/legacy.zig\ndeleted file mode 100644\n",
        .activity = &.{},
    },
};

/// The two repos the canned workspace has. Anything else is a 404,
/// the way Bitbucket answers for a repo you cannot see.
pub fn knownRepo(slug: []const u8) bool {
    for (&fixtures) |*f| if (std.mem.eql(u8, f.repo, slug)) return true;
    return false;
}

pub fn find(repo: []const u8, id: u32) ?*const Fixture {
    for (&fixtures) |*f| {
        if (f.id == id and (repo.len == 0 or std.mem.eql(u8, f.repo, repo))) return f;
    }
    return null;
}

// ─── routing ─────────────────────────────────────────────────────────────

pub const Request = struct {
    method: Method,
    /// Path plus query — what the request line carries.
    target: []const u8,
    body: []const u8 = "",
    /// The `Authorization` header as it arrived.
    authorization: []const u8 = "",
};

/// Answer one request. `arena` owns the reply body.
pub fn handle(arena: Allocator, st: *State, req: Request) Allocator.Error!Reply {
    st.served += 1;
    if (!hasCredentials(req.authorization)) {
        st.unauthorized += 1;
        return .{ .status = 401, .body = "{\"type\":\"error\",\"error\":{\"message\":\"no Basic credentials\"}}" };
    }
    if (st.rate_limit_next > 0) {
        st.rate_limit_next -= 1;
        return .{
            .status = 429,
            .retry_after_secs = 1,
            .body = "{\"type\":\"error\",\"error\":{\"message\":\"Rate limit for this resource has been exceeded\"}}",
        };
    }
    const q_at = std.mem.indexOfScalar(u8, req.target, '?');
    const path = if (q_at) |i| req.target[0..i] else req.target;
    const query = if (q_at) |i| req.target[i + 1 ..] else "";

    if (std.mem.eql(u8, path, "/2.0/user")) {
        if (st.deny_user) return .{ .status = 403, .body = "{\"type\":\"error\",\"error\":{\"message\":\"This token is not authorized to access the account\"}}" };
        return json(arena,
            \\{"display_name":"Chris M","account_id":"acct-chris","nickname":"chrism","type":"user"}
        );
    }

    // `/2.0/repositories/<ws>` — the repo list.
    if (std.mem.eql(u8, path, "/2.0/repositories/" ++ workspace)) {
        return json(arena,
            \\{"pagelen":100,"size":2,"values":[{"slug":"api","full_name":"acme/api"},{"slug":"web","full_name":"acme/web"}]}
        );
    }

    var seg = Segments.init(path);
    if (!seg.eat("2.0") or !seg.eat("repositories")) return notFound(arena);
    const ws = seg.next() orelse return notFound(arena);
    if (!std.mem.eql(u8, ws, workspace)) return notFound(arena);
    const repo = seg.next() orelse return notFound(arena);
    if (!knownRepo(repo)) return notFound(arena);

    // `/commit/<sha>/statuses`
    if (seg.eat("commit")) {
        const sha = seg.next() orelse return notFound(arena);
        if (!seg.eat("statuses")) return notFound(arena);
        return statuses(arena, repo, sha);
    }

    if (!seg.eat("pullrequests")) return notFound(arena);
    const id_text = seg.next() orelse return listPrs(arena, st, repo, query);
    const id = std.fmt.parseInt(u32, id_text, 10) catch return notFound(arena);
    const fx = find(repo, id) orelse return notFound(arena);

    const tail = seg.next();
    if (tail == null) return prDetail(arena, st, fx);
    const leaf = tail.?;
    if (std.mem.eql(u8, leaf, "activity")) return activity(arena, st, fx);
    if (std.mem.eql(u8, leaf, "diffstat")) return diffstat(arena, fx);
    if (std.mem.eql(u8, leaf, "diff")) return .{ .content_type = "text/plain", .body = fx.diff };
    if (std.mem.eql(u8, leaf, "statuses")) return statuses(arena, repo, fx.source_sha);
    if (std.mem.eql(u8, leaf, "approve")) {
        st.last_auth_was_write = true;
        switch (req.method) {
            .POST => {
                st.voteSlot(id).* = .approved;
                return json(arena,
                    \\{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"Chris M","account_id":"acct-chris"}}
                );
            },
            .DELETE => {
                st.voteSlot(id).* = .none;
                return .{ .status = 204, .body = "" };
            },
            else => return .{ .status = 405, .body = "{\"error\":{\"message\":\"method not allowed\"}}" },
        }
    }
    if (std.mem.eql(u8, leaf, "request-changes")) {
        st.last_auth_was_write = true;
        switch (req.method) {
            .POST => {
                st.voteSlot(id).* = .changes_requested;
                return json(arena,
                    \\{"role":"REVIEWER","approved":false,"state":"changes_requested","user":{"display_name":"Chris M","account_id":"acct-chris"}}
                );
            },
            .DELETE => {
                st.voteSlot(id).* = .none;
                return .{ .status = 204, .body = "" };
            },
            else => return .{ .status = 405, .body = "{\"error\":{\"message\":\"method not allowed\"}}" },
        }
    }
    if (std.mem.eql(u8, leaf, "comments")) {
        if (req.method != .POST) return notFound(arena);
        st.last_auth_was_write = true;
        const text = extractJsonString(req.body, "raw") orelse "";
        if (st.comment_count < st.comments.len) {
            st.comments[st.comment_count] = .{
                .pr_id = id,
                .text = try arena.dupe(u8, text),
                .path = try arena.dupe(u8, extractJsonString(req.body, "path") orelse ""),
            };
            st.comment_count += 1;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"id\":9999,\"user\":{\"display_name\":\"Chris M\",\"account_id\":\"acct-chris\"},\"content\":{\"raw\":") catch return error.OutOfMemory;
        try writeJsonString(w, text);
        w.writeAll("},\"created_on\":\"2026-09-02T09:00:00+00:00\"}") catch return error.OutOfMemory;
        return .{ .status = 201, .body = out.toOwnedSlice() catch return error.OutOfMemory };
    }
    if (std.mem.eql(u8, leaf, "merge")) {
        if (req.method != .POST) return notFound(arena);
        st.last_auth_was_write = true;
        if (!std.mem.eql(u8, fx.state, "OPEN")) {
            return .{ .status = 409, .body = "{\"type\":\"error\",\"error\":{\"message\":\"pull request is not open\"}}" };
        }
        if (st.merged_count < st.merged.len) {
            st.merged[st.merged_count] = id;
            st.merged_count += 1;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        try writePr(&out.writer, fx, st, .detail);
        return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
    }
    return notFound(arena);
}

/// `Basic base64(user:token)` with a token that is not empty. The
/// shape is all that matters — any token authenticates — but an empty
/// one is the mistake worth answering 401 to, because that is exactly
/// what a missing environment variable produces.
pub fn hasCredentials(header: []const u8) bool {
    if (!std.mem.startsWith(u8, header, "Basic ")) return false;
    const b64 = std.mem.trim(u8, header["Basic ".len..], " ");
    var buf: [512]u8 = undefined;
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return false;
    if (n == 0 or n > buf.len) return false;
    dec.decode(buf[0..n], b64) catch return false;
    const colon = std.mem.indexOfScalar(u8, buf[0..n], ':') orelse return false;
    return colon + 1 < n;
}

fn json(arena: Allocator, body: []const u8) Allocator.Error!Reply {
    return .{ .body = try arena.dupe(u8, body) };
}

fn notFound(arena: Allocator) Allocator.Error!Reply {
    return .{ .status = 404, .body = try arena.dupe(u8, "{\"type\":\"error\",\"error\":{\"message\":\"Resource not found\"}}") };
}

/// The one query parameter the pane leans on. Values arrive
/// percent-encoded; only `%22` (a quote) and `+` matter for BBQL.
fn queryParam(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return try percentDecode(arena, pair[eq + 1 ..]);
    }
    return null;
}

fn percentDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(arena, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(arena, s[i]);
                i += 1;
                continue;
            };
            try out.append(arena, hi * 16 + lo);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(arena, ' ');
            i += 1;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

fn listPrs(arena: Allocator, st: *State, repo: []const u8, query: []const u8) Allocator.Error!Reply {
    const want_state = (try queryParam(arena, query, "state")) orelse "OPEN";
    const bbql = (try queryParam(arena, query, "q")) orelse "";
    const author_id = predicateValue(bbql, "author.account_id");
    const reviewer_id = predicateValue(bbql, "reviewers.account_id");

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var n: usize = 0;
    w.writeAll("{\"pagelen\":50,\"values\":[") catch return error.OutOfMemory;
    for (&fixtures) |*f| {
        if (!std.mem.eql(u8, f.repo, repo)) continue;
        if (!std.mem.eql(u8, effectiveState(f, st), want_state)) continue;
        if (author_id) |a| if (!std.mem.eql(u8, f.author_id, a)) continue;
        if (reviewer_id) |r| {
            var is = false;
            for (f.reviewers) |rv| if (std.mem.eql(u8, rv.id, r)) {
                is = true;
            };
            if (!is) continue;
        }
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        try writePr(w, f, st, .list);
        n += 1;
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

/// `author.account_id = "acct-chris"` → `acct-chris`.
fn predicateValue(bbql: []const u8, field: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, bbql, field) orelse return null;
    const rest = bbql[at + field.len ..];
    const open = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse return null;
    return rest[open + 1 .. close];
}

fn effectiveState(f: *const Fixture, st: *const State) []const u8 {
    return if (st.isMerged(f.id)) "MERGED" else f.state;
}

const Shape = enum { list, detail };

fn writePr(w: *std.Io.Writer, f: *const Fixture, st: *const State, shape: Shape) Allocator.Error!void {
    w.print("{{\"type\":\"pullrequest\",\"id\":{d},\"title\":", .{f.id}) catch return error.OutOfMemory;
    try writeJsonString(w, f.title);
    w.print(",\"state\":\"{s}\",\"draft\":{s},\"updated_on\":\"2026-09-0{d}T12:34:56.000+00:00\"", .{
        effectiveState(f, st),
        if (f.draft) "true" else "false",
        @as(u32, f.id % 7) + 1,
    }) catch return error.OutOfMemory;
    w.print(",\"comment_count\":{d},\"task_count\":0", .{f.activity.len}) catch return error.OutOfMemory;
    w.print(",\"author\":{{\"display_name\":\"{s}\",\"account_id\":\"{s}\"}}", .{ f.author_name, f.author_id }) catch return error.OutOfMemory;
    w.print(",\"source\":{{\"branch\":{{\"name\":\"{s}\"}},\"commit\":{{\"hash\":\"{s}\"}},\"repository\":{{\"full_name\":\"{s}/{s}\"}}}}", .{
        f.source_branch, f.source_sha, workspace, f.repo,
    }) catch return error.OutOfMemory;
    w.print(",\"destination\":{{\"branch\":{{\"name\":\"{s}\"}},\"repository\":{{\"full_name\":\"{s}/{s}\"}}}}", .{
        f.dest_branch, workspace, f.repo,
    }) catch return error.OutOfMemory;
    w.print(",\"links\":{{\"html\":{{\"href\":\"https://bitbucket.org/{s}/{s}/pull-requests/{d}\"}}}}", .{ workspace, f.repo, f.id }) catch return error.OutOfMemory;
    // A list response sends the description as a bare string and a
    // detail as a renderable object — the drift the client must absorb.
    if (shape == .list) {
        w.writeAll(",\"description\":") catch return error.OutOfMemory;
        try writeJsonString(w, f.description);
    } else {
        w.writeAll(",\"description\":{\"raw\":") catch return error.OutOfMemory;
        try writeJsonString(w, f.description);
        w.writeAll(",\"html\":\"\",\"markup\":\"markdown\"}") catch return error.OutOfMemory;
    }
    w.writeAll(",\"reviewers\":[") catch return error.OutOfMemory;
    for (f.reviewers, 0..) |r, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"display_name\":\"{s}\",\"account_id\":\"{s}\",\"type\":\"user\"}}", .{ r.name, r.id }) catch return error.OutOfMemory;
    }
    w.writeAll("],\"participants\":[") catch return error.OutOfMemory;
    for (f.reviewers, 0..) |r, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        const vote = if (std.mem.eql(u8, r.id, me_account_id)) blk: {
            const live = st.voteFor(f.id);
            break :blk if (live == .none) r.vote else live;
        } else r.vote;
        w.print("{{\"role\":\"REVIEWER\",\"approved\":{s},\"state\":{s},\"user\":{{\"display_name\":\"{s}\",\"account_id\":\"{s}\"}}}}", .{
            if (vote == .approved) "true" else "false",
            switch (vote) {
                .approved => "\"approved\"",
                .changes_requested => "\"changes_requested\"",
                .none => "null",
            },
            r.name,
            r.id,
        }) catch return error.OutOfMemory;
    }
    w.writeAll("]") catch return error.OutOfMemory;
    if (st.isMerged(f.id)) {
        w.writeAll(",\"merge_commit\":{\"hash\":\"9999mergecommit\"}") catch return error.OutOfMemory;
    }
    w.writeAll("}") catch return error.OutOfMemory;
}

fn prDetail(arena: Allocator, st: *State, f: *const Fixture) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writePr(&out.writer, f, st, .detail);
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

fn activity(arena: Allocator, st: *State, f: *const Fixture) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"values\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    for (f.activity) |c| {
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"comment\":{{\"id\":{d},\"user\":{{\"display_name\":\"{s}\"}},\"created_on\":\"{s}\",\"content\":{{\"raw\":", .{ c.id, c.author, c.date }) catch return error.OutOfMemory;
        try writeJsonString(w, c.text);
        w.writeAll("}") catch return error.OutOfMemory;
        if (c.parent != 0) w.print(",\"parent\":{{\"id\":{d}}}", .{c.parent}) catch return error.OutOfMemory;
        if (c.path.len > 0) w.print(",\"inline\":{{\"path\":\"{s}\",\"from\":null,\"to\":{d}}}", .{ c.path, c.line }) catch return error.OutOfMemory;
        w.writeAll("}}") catch return error.OutOfMemory;
        n += 1;
    }
    for (f.reviewers) |r| {
        const vote = if (std.mem.eql(u8, r.id, me_account_id)) blk: {
            const live = st.voteFor(f.id);
            break :blk if (live == .none) r.vote else live;
        } else r.vote;
        if (vote == .none) continue;
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        const key = if (vote == .approved) "approval" else "changes_requested";
        w.print("{{\"{s}\":{{\"date\":\"2026-09-01T12:00:00+00:00\",\"user\":{{\"display_name\":\"{s}\"}}}}}}", .{ key, r.name }) catch return error.OutOfMemory;
        n += 1;
    }
    var buf: [16]State.Posted = undefined;
    for (st.commentsFor(f.id, &buf)) |c| {
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"comment\":{\"id\":9999,\"user\":{\"display_name\":\"Chris M\"},\"created_on\":\"2026-09-02T09:00:00+00:00\",\"content\":{\"raw\":") catch return error.OutOfMemory;
        try writeJsonString(w, c.text);
        w.writeAll("}}}") catch return error.OutOfMemory;
        n += 1;
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

fn diffstat(arena: Allocator, f: *const Fixture) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"values\":[") catch return error.OutOfMemory;
    for (f.files, 0..) |file, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"type\":\"diffstat\",\"status\":\"{s}\",\"lines_added\":{d},\"lines_removed\":{d}", .{ file.status, file.added, file.removed }) catch return error.OutOfMemory;
        if (std.mem.eql(u8, file.status, "removed")) {
            w.print(",\"new\":null,\"old\":{{\"path\":\"{s}\"}}", .{file.path}) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, file.status, "added")) {
            w.print(",\"new\":{{\"path\":\"{s}\"}},\"old\":null", .{file.path}) catch return error.OutOfMemory;
        } else {
            w.print(",\"new\":{{\"path\":\"{s}\"}},\"old\":{{\"path\":\"{s}\"}}", .{ file.path, file.path }) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
    }
    w.print("],\"size\":{d}}}", .{f.files.len}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

fn statuses(arena: Allocator, repo: []const u8, sha: []const u8) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"values\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    for (&fixtures) |*f| {
        if (!std.mem.eql(u8, f.repo, repo)) continue;
        if (!std.mem.eql(u8, f.source_sha, sha)) continue;
        for (f.builds) |b| {
            if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
            w.print("{{\"type\":\"build\",\"key\":\"{s}\",\"name\":\"{s}\",\"state\":\"{s}\",\"links\":{{\"self\":{{\"href\":\"https://bitbucket.org/{s}/{s}/pipelines/{s}\"}}}}}}", .{
                b.key, b.name, b.state, workspace, f.repo, b.key,
            }) catch return error.OutOfMemory;
            n += 1;
        }
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

// ─── little helpers ──────────────────────────────────────────────────────

/// A `/`-separated path, walked one segment at a time.
pub const Segments = struct {
    rest: []const u8,

    pub fn init(path: []const u8) Segments {
        return .{ .rest = std.mem.trim(u8, path, "/") };
    }

    pub fn next(self: *Segments) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const slash = std.mem.indexOfScalar(u8, self.rest, '/') orelse {
            const all = self.rest;
            self.rest = "";
            return all;
        };
        const head = self.rest[0..slash];
        self.rest = self.rest[slash + 1 ..];
        return head;
    }

    /// Take the next segment only when it is `want`.
    pub fn eat(self: *Segments, want: []const u8) bool {
        const save = self.*;
        const got = self.next() orelse return false;
        if (std.mem.eql(u8, got, want)) return true;
        self.* = save;
        return false;
    }
};

/// The value of a top-level `"key": "…"` in a small JSON body — enough
/// for the two fields the pane posts, without a parse.
pub fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    var at = std.mem.indexOf(u8, body, needle) orelse return null;
    at += needle.len;
    while (at < body.len and (body[at] == ' ' or body[at] == ':')) at += 1;
    if (at >= body.len or body[at] != '"') return null;
    at += 1;
    var i = at;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            continue;
        }
        if (body[i] == '"') return body[at..i];
    }
    return null;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) Allocator.Error!void {
    w.writeByte('"') catch return error.OutOfMemory;
    for (s) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch return error.OutOfMemory,
        '\\' => w.writeAll("\\\\") catch return error.OutOfMemory,
        '\n' => w.writeAll("\\n") catch return error.OutOfMemory,
        '\r' => w.writeAll("\\r") catch return error.OutOfMemory,
        '\t' => w.writeAll("\\t") catch return error.OutOfMemory,
        else => w.writeByte(c) catch return error.OutOfMemory,
    };
    w.writeByte('"') catch return error.OutOfMemory;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn call(arena: Allocator, st: *State, method: Method, target: []const u8, body: []const u8) !Reply {
    return handle(arena, st, .{ .method = method, .target = target, .body = body, .authorization = "Basic dXNlcjp0b2tlbg==" });
}

test "deny_user is the token-without-Account-Read case: /2.0/user 403s, the lists still work" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .deny_user = true };
    try t.expectEqual(@as(u16, 403), (try call(a, &st, .GET, "/2.0/user", "")).status);
    try t.expectEqual(@as(u16, 200), (try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests", "")).status);
}

test "a repo the workspace does not have is a 404, not an empty list" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    try t.expect(knownRepo("api"));
    try t.expect(!knownRepo("ghost"));
    try t.expectEqual(@as(u16, 404), (try call(a, &st, .GET, "/2.0/repositories/acme/ghost/pullrequests", "")).status);
}

test "an Authorization header with no token, or none at all, is a 401 before anything is routed" {
    try t.expect(hasCredentials("Basic bWU6dG9r"));
    try t.expect(!hasCredentials("Basic Og=="));
    try t.expect(!hasCredentials("Bearer abc"));
    try t.expect(!hasCredentials(""));
}

test "a request with no Basic credentials is a 401 before anything is routed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var st: State = .{};
    const r = try handle(arena.allocator(), &st, .{ .method = .GET, .target = "/2.0/user" });
    try t.expectEqual(@as(u16, 401), r.status);
    try t.expectEqual(@as(u32, 1), st.unauthorized);
}

test "the PR list honours the state filter and the two BBQL predicates" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    // Every OPEN PR in api: #1234 and #1198.
    const open = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN&pagelen=50", "");
    try t.expectEqual(@as(u16, 200), open.status);
    try t.expect(std.mem.indexOf(u8, open.body, "Fix the login redirect") != null);
    try t.expect(std.mem.indexOf(u8, open.body, "Bump the client timeout") != null);
    try t.expect(std.mem.indexOf(u8, open.body, "Drop the legacy exporter") == null);
    // MERGED picks up the fourth.
    const merged = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=MERGED", "");
    try t.expect(std.mem.indexOf(u8, merged.body, "Drop the legacy exporter") != null);
    // author.account_id → the PRs I opened. Percent-encoded quotes.
    const mine = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN&q=author.account_id%20%3D%20%22acct-chris%22", "");
    try t.expect(std.mem.indexOf(u8, mine.body, "Fix the login redirect") != null);
    try t.expect(std.mem.indexOf(u8, mine.body, "Bump the client timeout") == null);
    // reviewers.account_id → the PRs I am a reviewer on.
    const review = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN&q=reviewers.account_id%3D%22acct-chris%22", "");
    try t.expect(std.mem.indexOf(u8, review.body, "Bump the client timeout") != null);
    try t.expect(std.mem.indexOf(u8, review.body, "Fix the login redirect") == null);
    // A repo nobody asked for is a 404, not an empty list.
    try t.expectEqual(@as(u16, 404), (try call(a, &st, .GET, "/2.0/repositories/other/api/pullrequests", "")).status);
}

test "a list description is a bare string and a detail description is a renderable — the drift the client absorbs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const list = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests", "");
    try t.expect(std.mem.indexOf(u8, list.body, "\"description\":\"Fixes ENG-4210.") != null);
    const detail = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234", "");
    try t.expect(std.mem.indexOf(u8, detail.body, "\"description\":{\"raw\":\"Fixes ENG-4210.") != null);
    try t.expect(std.mem.indexOf(u8, detail.body, "\"changes_requested\"") != null);
}

test "approve and request-changes flip the account's own vote, and DELETE clears it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    // #1198 lists me as a reviewer with no vote.
    try t.expectEqual(State.Vote.none, st.voteFor(1198));
    try t.expectEqual(@as(u16, 200), (try call(a, &st, .POST, "/2.0/repositories/acme/api/pullrequests/1198/approve", "")).status);
    try t.expectEqual(State.Vote.approved, st.voteFor(1198));
    try t.expect(st.last_auth_was_write);
    const after = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1198", "");
    try t.expect(std.mem.indexOf(u8, after.body, "\"state\":\"approved\"") != null);
    try t.expectEqual(@as(u16, 200), (try call(a, &st, .POST, "/2.0/repositories/acme/api/pullrequests/1198/request-changes", "")).status);
    try t.expectEqual(State.Vote.changes_requested, st.voteFor(1198));
    try t.expectEqual(@as(u16, 204), (try call(a, &st, .DELETE, "/2.0/repositories/acme/api/pullrequests/1198/approve", "")).status);
    try t.expectEqual(State.Vote.none, st.voteFor(1198));
    // GET on the approve endpoint is not a thing.
    try t.expectEqual(@as(u16, 405), (try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1198/approve", "")).status);
}

test "a posted comment lands in the state and comes back on the next activity read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const r = try call(a, &st, .POST, "/2.0/repositories/acme/api/pullrequests/1234/comments", "{\"content\":{\"raw\":\"ship it \\\"now\\\"\"}}");
    try t.expectEqual(@as(u16, 201), r.status);
    try t.expectEqual(@as(usize, 1), st.comment_count);
    try t.expectEqualStrings("ship it \\\"now\\\"", st.comments[0].text);
    const act = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234/activity", "");
    try t.expect(std.mem.indexOf(u8, act.body, "ship it") != null);
    // The pre-existing thread is there too, inline reply and all.
    try t.expect(std.mem.indexOf(u8, act.body, "\"inline\":{\"path\":\"src/auth/session.zig\",\"from\":null,\"to\":44}") != null);
    try t.expect(std.mem.indexOf(u8, act.body, "\"parent\":{\"id\":9002}") != null);
}

test "merge moves the PR to MERGED, and merging it twice is a 409" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const r = try call(a, &st, .POST, "/2.0/repositories/acme/api/pullrequests/1234/merge", "{\"merge_strategy\":\"squash\"}");
    try t.expectEqual(@as(u16, 200), r.status);
    try t.expect(st.isMerged(1234));
    try t.expect(std.mem.indexOf(u8, r.body, "\"state\":\"MERGED\"") != null);
    try t.expect(std.mem.indexOf(u8, r.body, "9999mergecommit") != null);
    // It has left the OPEN list and joined the MERGED one.
    const open = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN", "");
    try t.expect(std.mem.indexOf(u8, open.body, "Fix the login redirect") == null);
    // The already-merged fixture refuses.
    try t.expectEqual(@as(u16, 409), (try call(a, &st, .POST, "/2.0/repositories/acme/api/pullrequests/1100/merge", "{}")).status);
}

test "diffstat, diff and statuses each answer in their own shape" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const ds = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234/diffstat", "");
    try t.expect(std.mem.indexOf(u8, ds.body, "\"lines_added\":18") != null);
    try t.expect(std.mem.indexOf(u8, ds.body, "\"old\":null") != null);
    const diff = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234/diff", "");
    try t.expectEqualStrings("text/plain", diff.content_type);
    try t.expect(std.mem.startsWith(u8, diff.body, "diff --git"));
    const stt = try call(a, &st, .GET, "/2.0/repositories/acme/api/commit/abc1234def5678/statuses", "");
    try t.expect(std.mem.indexOf(u8, stt.body, "Pipeline #412") != null);
    try t.expect(std.mem.indexOf(u8, stt.body, "\"state\":\"FAILED\"") != null);
    // Via the PR alias, the same two.
    const alias = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234/statuses", "");
    try t.expectEqualStrings(stt.body, alias.body);
}

test "the rate-limit dial answers 429 with a Retry-After the client can read, then recovers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .rate_limit_next = 2 };
    const one = try call(a, &st, .GET, "/2.0/user", "");
    try t.expectEqual(@as(u16, 429), one.status);
    try t.expectEqual(@as(u32, 1), one.retry_after_secs.?);
    try t.expectEqual(@as(u16, 429), (try call(a, &st, .GET, "/2.0/user", "")).status);
    try t.expectEqual(@as(u16, 200), (try call(a, &st, .GET, "/2.0/user", "")).status);
    try t.expectEqual(@as(u32, 3), st.served);
}

test "path segments and the tiny JSON string reader" {
    var s = Segments.init("/2.0/repositories/acme/api/");
    try t.expect(s.eat("2.0"));
    try t.expect(!s.eat("nope"));
    try t.expect(s.eat("repositories"));
    try t.expectEqualStrings("acme", s.next().?);
    try t.expectEqualStrings("api", s.next().?);
    try t.expect(s.next() == null);
    try t.expectEqualStrings("hi", extractJsonString("{\"content\":{\"raw\": \"hi\"}}", "raw").?);
    try t.expectEqualStrings("a\\\"b", extractJsonString("{\"raw\":\"a\\\"b\"}", "raw").?);
    try t.expect(extractJsonString("{\"raw\":7}", "raw") == null);
    try t.expect(extractJsonString("{}", "raw") == null);
}

test "the repo list and whoami are the two endpoints a mine tab needs before it can query" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const who = try call(a, &st, .GET, "/2.0/user", "");
    try t.expect(std.mem.indexOf(u8, who.body, "acct-chris") != null);
    const repos = try call(a, &st, .GET, "/2.0/repositories/acme?role=member", "");
    try t.expect(std.mem.indexOf(u8, repos.body, "\"slug\":\"api\"") != null);
    try t.expect(std.mem.indexOf(u8, repos.body, "\"slug\":\"web\"") != null);
}
