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
//! Every pull request carries its source commit, and there is at least
//! one pipeline run on each open one's branch head as well as on the
//! merged one's merge commit — so a PR row has builds to fold out in
//! either state.
//!
//! Pipelines and branches are faked too, per repo, with their dates
//! relative to `State.now_secs` so the pane's recency rules (the 24-hour
//! window on a PR, the 14-day staleness on a feature branch) see the
//! same picture every run. What it deliberately does *not* fake:
//! pagination past one page.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Reply = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    /// Owned by the arena passed to `handle`.
    body: []const u8 = "",
    /// Sent on a 429 so the client's backoff has something to read.
    retry_after_secs: ?u32 = null,
    /// The body's `ETag`, when the route offers one. Bitbucket Cloud
    /// sends one on the read routes and honours `If-None-Match` on
    /// them, which is the whole reason a poll can be cheap; the fake
    /// does the same so a test can prove the client uses it. Owned by
    /// the arena.
    etag: []const u8 = "",
    /// `X-RateLimit-Limit` / `-Remaining` / `-NearLimit`, when the
    /// budget dial is on (`State.budget_limit`). Bitbucket Cloud sends
    /// these on some routes and not others; the dial sends them on
    /// every answer so a test can drive the pane's budget chip.
    budget: ?Budget = null,
};

pub const Budget = struct {
    limit: u32,
    remaining: u32,
    /// A fifth or less left — what Bitbucket's `NearLimit` flags.
    near: bool,
};

pub const Method = enum { GET, POST, PUT, DELETE, other };

pub fn methodOf(s: []const u8) Method {
    return std.meta.stringToEnum(Method, s) orelse .other;
}

pub const me_account_id = "acct-chris";
pub const me_display_name = "Chris M";
pub const workspace = "acme";

/// When the fake's answers go out gzipped (`--gzip`, `--gzip-always`).
pub const Gzip = enum {
    /// Plain bytes, whatever the client offered: every test's default.
    off,
    /// Gzipped when the request's `Accept-Encoding` offers gzip, the
    /// way Bitbucket Cloud answers a client that asks.
    when_asked,
    /// Gzipped whatever the client asked for — a proxy that
    /// compresses on its own. The client reads `Content-Encoding`,
    /// not what it offered.
    always,
};

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
    /// The `Retry-After` those 429s carry, in seconds. 0 sends none,
    /// which is what makes the client fall back to its own backoff.
    rate_limit_retry_after: u32 = 1,
    /// The budget dial: when non-zero every answer carries
    /// `X-RateLimit-Limit: budget_limit` and a `-Remaining` that
    /// starts at `budget_remaining` and drops by one per request.
    budget_limit: u32 = 0,
    budget_remaining: u32 = 0,
    /// Answer `/2.0/user` with a 403, the way a token without
    /// **Account: Read** does. Everything else still works — which is
    /// exactly the case a `mine` tab's fallback exists for.
    deny_user: bool = false,
    /// While set, every request whose path contains `fail_path`
    /// (all of them when it is empty) answers `500` with an HTML body —
    /// a proxy's error page, the way a Bitbucket outage looks from a
    /// client. How a test proves a failed refetch keeps its rows.
    failing: bool = false,
    fail_path_buf: [64]u8 = undefined,
    fail_path_len: u8 = 0,
    /// Requests served, 429s included.
    served: u32 = 0,
    /// Of those, the ones answered `304 Not Modified` — what a test
    /// counts to prove a conditional GET was conditional.
    not_modified: u32 = 0,
    /// `--extra-prs N`: N more OPEN pull requests on `acme/api`,
    /// authored by the account the fixture calls you, so a measurement
    /// runs against a workspace the size of a real one rather than the
    /// three the fixture needs to make its points.
    extra_prs: u32 = 0,
    /// `--gzip` / `--gzip-always`: when an answer goes out gzipped.
    gzip: Gzip = .off,
    /// Answers that went out gzipped — how a test knows the client was
    /// really sent compressed bytes, not plain ones.
    gzipped: u32 = 0,
    /// Requests that arrived with no (or a bad) Authorization header.
    unauthorized: u32 = 0,
    /// Set when a write arrived; the corpus proves the write token
    /// reached the wire without ever printing it.
    last_auth_was_write: bool = false,
    /// How the last request authenticated — the scheme, never the
    /// token. A test asserts the pane chose Bearer for an access token
    /// and Basic for an account one.
    last_credential: Credential = .none,
    /// The clock every relative date is written against, as seconds
    /// since the epoch; the listener stamps the real one before each
    /// request, a test sets its own.
    now_secs: i64 = 1_789_500_000,
    /// Titles a test changed (`POST /__retitle/<id>`, the body the new
    /// title): the one way to make a pull request MOVE without a write
    /// the pane itself makes — what an event feed exists to report.
    retitled: [4]Retitle = @splat(.{}),

    pub const Vote = enum { none, approved, changes_requested };

    pub const Posted = struct {
        pr_id: u32 = 0,
        text: []const u8 = "",
        path: []const u8 = "",
        line: i64 = 0,
    };

    pub const Retitle = struct {
        id: u32 = 0,
        buf: [96]u8 = undefined,
        len: u8 = 0,
    };

    pub fn titleFor(self: *const State, f: *const Fixture) []const u8 {
        for (&self.retitled) |*r| if (r.id == f.id and r.len > 0) return r.buf[0..r.len];
        return f.title;
    }

    fn retitle(self: *State, id: u32, title: []const u8) void {
        const slot = for (&self.retitled) |*r| {
            if (r.id == id or r.id == 0) break r;
        } else &self.retitled[0];
        const n: u8 = @intCast(@min(title.len, slot.buf.len));
        @memcpy(slot.buf[0..n], title[0..n]);
        slot.* = .{ .id = id, .buf = slot.buf, .len = n };
    }

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
    /// `updated_on` is this many hours before `State.now_secs`.
    age_hours: u32 = 3,
    /// Tasks still open on the pull request — Bitbucket's `task_count`
    /// counts the UNRESOLVED ones, which is what readiness reads.
    open_tasks: u32 = 0,
    /// It no longer merges cleanly into its target. Bitbucket says so
    /// by answering the diffstat with a 555.
    conflicts: bool = false,
    /// The merge commit's hash on a MERGED fixture.
    merge_sha: []const u8 = "",
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
        /// Someone marked the thread resolved — Bitbucket sends a
        /// `resolution` object and omits the key otherwise.
        resolved: bool = false,
        /// A deleted comment keeps its slot in the page with no content.
        deleted: bool = false,
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
        .open_tasks = 1,
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
        .age_hours = 30,
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
        .conflicts = true,
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
        .age_hours = 5,
        .merge_sha = "9999mergecommit",
        .reviewers = &.{.{ .id = me_account_id, .name = me_display_name, .vote = .approved }},
        .builds = &.{},
        .files = &.{.{ .status = "removed", .path = "src/export/legacy.zig", .added = 0, .removed = 240 }},
        .diff = "diff --git a/src/export/legacy.zig b/src/export/legacy.zig\ndeleted file mode 100644\n",
        .activity = &.{},
    },
    .{
        .repo = "web",
        .id = 801,
        .title = "Tidy the footer links",
        .state = "MERGED",
        .author_id = "acct-dana",
        .author_name = "Dana R",
        .source_branch = "dana/footer",
        .source_sha = "eee5555fff6666",
        .description = "",
        .age_hours = 40,
        .merge_sha = "8888mergecommit",
        .reviewers = &.{},
        .builds = &.{},
        .files = &.{.{ .status = "modified", .path = "src/views/footer.zig", .added = 3, .removed = 3 }},
        .diff = "diff --git a/src/views/footer.zig b/src/views/footer.zig\n@@ -1,1 +1,1 @@\n-old\n+new\n",
        .activity = &.{},
    },
};

/// A pipeline run. `age_hours` is `created_on` before `State.now_secs`.
pub const PipelineFixture = struct {
    repo: []const u8,
    build_number: u32,
    /// `PENDING` / `IN_PROGRESS` / `COMPLETED`.
    state: []const u8,
    /// `SUCCESSFUL` / `FAILED` / `STOPPED`, or "" while not COMPLETED.
    result: []const u8 = "",
    ref_name: []const u8,
    commit: []const u8,
    trigger: []const u8 = "push",
    creator: []const u8 = "Chris M",
    /// `target.selector.type`: which section of the pipelines file.
    selector: []const u8 = "branches",
    /// `target.type`: a ref, a pull request, a commit.
    target_type: []const u8 = "pipeline_ref_target",
    duration_secs: u32 = 0,
    age_hours: u32,
};

/// Newest first, the order Bitbucket's `sort=-created_on` returns.
pub const pipelines = [_]PipelineFixture{
    .{ .repo = "api", .build_number = 413, .state = "IN_PROGRESS", .ref_name = "chris/fix-login", .commit = "abc1234def5678", .selector = "pull-requests", .target_type = "pipeline_pullrequest_target", .age_hours = 1 },
    .{ .repo = "api", .build_number = 412, .state = "COMPLETED", .result = "SUCCESSFUL", .ref_name = "main", .commit = "9999mergecommit", .duration_secs = 312, .age_hours = 4 },
    .{ .repo = "api", .build_number = 411, .state = "COMPLETED", .result = "FAILED", .ref_name = "develop", .commit = "1212121212", .trigger = "schedule", .duration_secs = 95, .age_hours = 20 },
    // On the OPEN pull request #1198's branch head, so an open row has
    // builds to fold out — what a reviewer wants before merging.
    .{ .repo = "api", .build_number = 410, .state = "COMPLETED", .result = "SUCCESSFUL", .ref_name = "dana/timeout", .commit = "bbb2222ccc3333", .duration_secs = 120, .age_hours = 29 },
    .{ .repo = "api", .build_number = 405, .state = "COMPLETED", .result = "STOPPED", .ref_name = "release/1.2", .commit = "3434343434", .selector = "custom", .duration_secs = 40, .age_hours = 24 * 10 },
    .{ .repo = "web", .build_number = 77, .state = "PENDING", .ref_name = "chris/empty-state", .commit = "ddd4444eee5555", .trigger = "manual", .creator = "Dana R", .age_hours = 1 },
    .{ .repo = "web", .build_number = 70, .state = "COMPLETED", .result = "SUCCESSFUL", .ref_name = "main", .commit = "8888mergecommit", .duration_secs = 200, .age_hours = 24 * 3 },
};

/// A branch head. `age_hours` is the tip commit's date before now.
pub const BranchFixture = struct {
    repo: []const u8,
    name: []const u8,
    hash: []const u8,
    message: []const u8,
    author: []const u8 = "Chris M <chris@example.com>",
    age_hours: u32,
};

/// Most recently committed first, the order `sort=-target.date` returns.
pub const branches = [_]BranchFixture{
    .{ .repo = "api", .name = "chris/fix-login", .hash = "abc1234def5678", .message = "Keep the query string on the login redirect", .age_hours = 1 },
    .{ .repo = "api", .name = "main", .hash = "9999mergecommit", .message = "Merged in sam/drop-exporter (pull request #1100)", .author = "Sam K <sam@example.com>", .age_hours = 4 },
    .{ .repo = "api", .name = "develop", .hash = "1212121212", .message = "Bump the client timeout", .author = "Dana R <dana@example.com>", .age_hours = 20 },
    .{ .repo = "api", .name = "dana/timeout", .hash = "bbb2222ccc3333", .message = "Bump the client timeout to 30s", .author = "Dana R <dana@example.com>", .age_hours = 30 },
    .{ .repo = "api", .name = "release/1.2", .hash = "3434343434", .message = "Release 1.2", .age_hours = 24 * 10 },
    .{ .repo = "api", .name = "old/experiment", .hash = "5656565656", .message = "An experiment nobody finished", .age_hours = 24 * 40 },
    .{ .repo = "web", .name = "chris/empty-state", .hash = "ddd4444eee5555", .message = "Redesign the empty state", .age_hours = 1 },
    .{ .repo = "web", .name = "staging", .hash = "7878787878", .message = "Deploy 2.3 to staging", .age_hours = 24 * 2 },
    .{ .repo = "web", .name = "main", .hash = "8888mergecommit", .message = "Merged in dana/footer (pull request #801)", .author = "Dana R <dana@example.com>", .age_hours = 24 * 3 },
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
    /// The `If-None-Match` header as it arrived. A GET whose tag still
    /// matches what the route would answer with gets a 304 and no
    /// body.
    if_none_match: []const u8 = "",
};

/// Answer one request. `arena` owns the reply body.
pub fn handle(arena: Allocator, st: *State, req: Request) Allocator.Error!Reply {
    var reply = try route(arena, st, req);
    if (st.budget_limit > 0) {
        st.budget_remaining -|= 1;
        reply.budget = .{ .limit = st.budget_limit, .remaining = st.budget_remaining, .near = st.budget_remaining * 5 <= st.budget_limit };
    }
    // Every 2xx answer to a GET carries a tag over its own bytes, and
    // a GET that arrives holding that tag is told there is nothing
    // new. Bitbucket Cloud does this on its read routes; the cheap
    // poll depends on it, so the fake has to be able to prove it.
    if (req.method == .GET and reply.status >= 200 and reply.status < 300) {
        reply.etag = try etagOf(arena, reply.body);
        if (req.if_none_match.len > 0 and std.mem.eql(u8, std.mem.trim(u8, req.if_none_match, " \t"), reply.etag)) {
            st.not_modified += 1;
            return .{ .status = 304, .body = "", .etag = reply.etag, .budget = reply.budget };
        }
    }
    return reply;
}

/// A weak tag over the bytes: the same body always gets the same one,
/// and a body that moved never does.
fn etagOf(arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(body);
    return std.fmt.allocPrint(arena, "\"{x}\"", .{h.final()});
}

fn route(arena: Allocator, st: *State, req: Request) Allocator.Error!Reply {
    // The test's own door, before auth: `POST /__retitle/<id>` with the
    // new title as the body. Not Bitbucket; a test's way to move a PR.
    if (req.method == .POST and std.mem.startsWith(u8, req.target, "/__retitle/")) {
        const id = std.fmt.parseInt(u32, req.target["/__retitle/".len..], 10) catch return notFound(arena);
        if (find("", id) == null) return notFound(arena);
        st.retitle(id, req.body);
        return .{ .status = 204 };
    }
    st.served += 1;
    const cred = classify(req.authorization);
    st.last_credential = cred;
    if (cred.rejection()) |message| {
        st.unauthorized += 1;
        return .{ .status = 401, .body = try std.fmt.allocPrint(arena, "{{\"type\":\"error\",\"error\":{{\"message\":\"{s}\"}}}}", .{message}) };
    }
    if (st.rate_limit_next > 0) {
        st.rate_limit_next -= 1;
        return .{
            .status = 429,
            .retry_after_secs = if (st.rate_limit_retry_after > 0) st.rate_limit_retry_after else null,
            .body = "{\"type\":\"error\",\"error\":{\"message\":\"Rate limit for this resource has been exceeded\"}}",
        };
    }
    const q_at = std.mem.indexOfScalar(u8, req.target, '?');
    const path = if (q_at) |i| req.target[0..i] else req.target;
    const query = if (q_at) |i| req.target[i + 1 ..] else "";
    if (st.failing and std.mem.indexOf(u8, path, st.fail_path_buf[0..st.fail_path_len]) != null) {
        return .{ .status = 500, .body = "<html>oops</html>" };
    }

    if (std.mem.eql(u8, path, "/2.0/user")) {
        // An access token belongs to a repository, a project or a
        // workspace — never to a person — so there is no account for
        // this route to answer with. Bitbucket says so with a 401,
        // which is why a `--check` that probes `/2.0/user` with one
        // reads as "bad token" when the token is in fact fine.
        if (cred == .bearer_access_token) return .{ .status = 401, .body = "{\"type\":\"error\",\"error\":{\"message\":\"This API is not accessible for this authentication method\"}}" };
        if (st.deny_user) return .{ .status = 403, .body = "{\"type\":\"error\",\"error\":{\"message\":\"This token is not authorized to access the account\"}}" };
        return json(arena,
            \\{"display_name":"Chris M","account_id":"acct-chris","nickname":"chrism","type":"user"}
        );
    }

    // `/2.0/workspaces/<slug>` — the probe an access token *can*
    // answer, and what `--check` asks when there is no account to ask
    // about.
    if (std.mem.startsWith(u8, path, "/2.0/workspaces/")) {
        const slug = path["/2.0/workspaces/".len..];
        if (!std.mem.eql(u8, slug, workspace)) return notFound(arena);
        return json(arena,
            \\{"slug":"acme","name":"Acme","uuid":"{ws-acme}","type":"workspace"}
        );
    }

    // `/2.0/repositories/<ws>` — the repo list.
    if (std.mem.eql(u8, path, "/2.0/repositories/" ++ workspace)) {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"pagelen\":100,\"size\":2,\"values\":[{\"slug\":\"api\",\"full_name\":\"acme/api\",\"updated_on\":\"") catch return error.OutOfMemory;
        writeIso(w, st.now_secs - 3600) catch return error.OutOfMemory;
        w.writeAll("\"},{\"slug\":\"web\",\"full_name\":\"acme/web\",\"updated_on\":\"") catch return error.OutOfMemory;
        writeIso(w, st.now_secs - 24 * 3600) catch return error.OutOfMemory;
        w.writeAll("\"}]}") catch return error.OutOfMemory;
        return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
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

    // `/refs/branches` and `/pipelines/` — the pipelines tree's two
    // reads per repo.
    if (seg.eat("refs")) {
        if (!seg.eat("branches")) return notFound(arena);
        return listBranches(arena, st, repo);
    }
    if (seg.eat("pipelines")) return listPipelines(arena, st, repo);

    if (!seg.eat("pullrequests")) return notFound(arena);
    const id_text = seg.next() orelse return listPrs(arena, st, repo, query);
    const id = std.fmt.parseInt(u32, id_text, 10) catch return notFound(arena);
    const fx = find(repo, id) orelse {
        // A `--extra-prs` pull request exists on the listing and has no
        // fixture behind it. Answering its sub-routes 404 would make a
        // measurement read as a wall of failures — and a failure is
        // never cached, so the poller would re-ask for every one of
        // them on every cycle. It has no comments and no tasks, and it
        // says so.
        if (id >= 9000 and st.extra_prs > 0 and id < 9000 + st.extra_prs) {
            if (std.mem.eql(u8, seg.rest, "comments") or std.mem.eql(u8, seg.rest, "activity")) {
                return .{ .body = "{\"pagelen\":50,\"values\":[],\"size\":0}" };
            }
            if (std.mem.eql(u8, seg.rest, "diffstat")) {
                return .{ .body = "{\"pagelen\":50,\"values\":[],\"size\":0}" };
            }
            if (seg.rest.len == 0) {
                const f = try syntheticPr(arena, id - 9000);
                var out: std.Io.Writer.Allocating = .init(arena);
                try writePr(&out.writer, &f, st, .detail);
                return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
            }
        }
        return notFound(arena);
    };

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
        if (req.method == .GET) return comments(arena, st, fx);
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

/// Bitbucket Cloud takes two kinds of token and they are not
/// interchangeable on the wire:
///
///   - an **account** credential — an Atlassian API token or a
///     Bitbucket app password — goes over `Basic base64(email:token)`;
///   - an **access token** — repository, project or workspace scoped,
///     spelled `ATCTT…` — goes over `Bearer <token>`.
///
/// Present either one the other way round and Bitbucket answers 401,
/// with no hint that the token itself is good. That 401 is what this
/// server exists to reproduce, so the pane can be held to getting the
/// scheme right without a live call.
pub const access_token_prefix = "ATCTT";

pub const Credential = enum {
    /// No header, or one whose shape says nothing.
    none,
    /// `Basic base64(email:token)` — an Atlassian API token or an app
    /// password. The account credential.
    basic_account,
    /// `Basic base64(email:ATCTT…)` — an access token sent the account
    /// way. Bitbucket rejects this.
    basic_with_access_token,
    /// `Bearer ATCTT…` — an access token, sent correctly.
    bearer_access_token,
    /// `Bearer <an account token>` — the account credential sent the
    /// access-token way. Bitbucket rejects this too.
    bearer_without_access_token,

    /// The message Bitbucket answers 401 with, or null when the
    /// credential is accepted.
    pub fn rejection(c: Credential) ?[]const u8 {
        return switch (c) {
            .none => "no credentials",
            .basic_with_access_token => "Access tokens cannot be used with Basic authentication; send them as a Bearer token",
            .bearer_without_access_token => "Bearer authentication requires an access token",
            .basic_account, .bearer_access_token => null,
        };
    }
};

pub fn classify(header: []const u8) Credential {
    if (std.mem.startsWith(u8, header, "Bearer ")) {
        const tok = std.mem.trim(u8, header["Bearer ".len..], " ");
        if (tok.len == 0) return .none;
        return if (std.mem.startsWith(u8, tok, access_token_prefix)) .bearer_access_token else .bearer_without_access_token;
    }
    if (!std.mem.startsWith(u8, header, "Basic ")) return .none;
    const b64 = std.mem.trim(u8, header["Basic ".len..], " ");
    var buf: [512]u8 = undefined;
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return .none;
    if (n == 0 or n > buf.len) return .none;
    dec.decode(buf[0..n], b64) catch return .none;
    const colon = std.mem.indexOfScalar(u8, buf[0..n], ':') orelse return .none;
    const token = buf[colon + 1 .. n];
    if (token.len == 0) return .none;
    return if (std.mem.startsWith(u8, token, access_token_prefix)) .basic_with_access_token else .basic_account;
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

/// Every value of a repeated query parameter — `state=OPEN&state=MERGED`
/// is how Bitbucket takes more than one state.
fn queryParams(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        try out.append(arena, try percentDecode(arena, pair[eq + 1 ..]));
    }
    return out.toOwnedSlice(arena);
}

fn listPrs(arena: Allocator, st: *State, repo: []const u8, query: []const u8) Allocator.Error!Reply {
    const states = try queryParams(arena, query, "state");
    const want_states: []const []const u8 = if (states.len > 0) states else &.{"OPEN"};
    var wants_open = false;
    for (want_states) |ws| wants_open = wants_open or std.mem.eql(u8, ws, "OPEN");
    const bbql = (try queryParam(arena, query, "q")) orelse "";
    const author_id = predicateValue(bbql, "author.account_id");
    const reviewer_id = predicateValue(bbql, "reviewers.account_id");
    // `author… OR reviewers…` asks for both sets in ONE request — what
    // the statusline run does so counting "waiting on my review" costs
    // nothing extra. Anything else joining the two is an AND.
    const either = author_id != null and reviewer_id != null and std.mem.indexOf(u8, bbql, " OR ") != null;

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var n: usize = 0;
    w.writeAll("{\"pagelen\":50,\"values\":[") catch return error.OutOfMemory;
    for (&fixtures) |*f| {
        if (!std.mem.eql(u8, f.repo, repo)) continue;
        var wanted = false;
        for (want_states) |ws| wanted = wanted or std.mem.eql(u8, effectiveState(f, st), ws);
        if (!wanted) continue;
        const by_author = if (author_id) |a| std.mem.eql(u8, f.author_id, a) else false;
        var by_reviewer = false;
        if (reviewer_id) |r| for (f.reviewers) |rv| {
            if (std.mem.eql(u8, rv.id, r)) by_reviewer = true;
        };
        if (either) {
            if (!by_author and !by_reviewer) continue;
        } else {
            if (author_id != null and !by_author) continue;
            if (reviewer_id != null and !by_reviewer) continue;
        }
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        try writePr(w, f, st, .list);
        n += 1;
    }
    // `--extra-prs`: the same shape, generated, so a measurement has a
    // workspace the size of a real one. OPEN and on `api` only —
    // everything else about them is derived from the index, so two
    // runs of the same server answer identically.
    if (st.extra_prs > 0 and std.mem.eql(u8, repo, "api") and wants_open) {
        var k: u32 = 0;
        while (k < st.extra_prs) : (k += 1) {
            const f = try syntheticPr(arena, k);
            if (author_id) |a| if (!std.mem.eql(u8, f.author_id, a) and !either) continue;
            if (reviewer_id != null and !either) continue;
            if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
            try writePr(w, &f, st, .list);
            n += 1;
        }
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

/// The nth generated pull request. Invented people, invented branches,
/// derived entirely from `n`: the same server always answers the same
/// thing, which is what a measurement needs.
fn syntheticPr(arena: Allocator, n: u32) Allocator.Error!Fixture {
    const authors = [_]struct { id: []const u8, name: []const u8 }{
        .{ .id = "acct-chris", .name = "Chris M" },
        .{ .id = "acct-dev", .name = "Robin Vale" },
        .{ .id = "acct-kim", .name = "Kim Okonjo" },
    };
    const a = authors[n % authors.len];
    return .{
        .repo = "api",
        .id = 9000 + n,
        .title = try std.fmt.allocPrint(arena, "Tidy the widget cache ({d})", .{n + 1}),
        .state = "OPEN",
        .author_id = a.id,
        .author_name = a.name,
        .source_branch = try std.fmt.allocPrint(arena, "feature/widget-{d}", .{n + 1}),
        .source_sha = try std.fmt.allocPrint(arena, "{x:0>12}", .{@as(u64, n) * 0x9E3779B1}),
        .description = "Generated for a size measurement.",
        .age_hours = 1 + n % 48,
        .reviewers = &.{},
        .builds = &.{},
        .files = &.{},
        .diff = "",
        .activity = &.{},
    };
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
    try writeJsonString(w, st.titleFor(f));
    w.print(",\"state\":\"{s}\",\"draft\":{s},\"updated_on\":\"", .{
        effectiveState(f, st),
        if (f.draft) "true" else "false",
    }) catch return error.OutOfMemory;
    writeIso(w, st.now_secs - @as(i64, f.age_hours) * 3600) catch return error.OutOfMemory;
    w.writeAll("\"") catch return error.OutOfMemory;
    w.print(",\"comment_count\":{d},\"task_count\":{d}", .{ f.activity.len, f.open_tasks }) catch return error.OutOfMemory;
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
    // A vote from someone who is not a reviewer — the author approving
    // their own, say — joins the participants the way Bitbucket adds
    // them.
    var me_listed = false;
    for (f.reviewers) |r| if (std.mem.eql(u8, r.id, me_account_id)) {
        me_listed = true;
    };
    const live = st.voteFor(f.id);
    if (!me_listed and live != .none) {
        if (f.reviewers.len > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"role\":\"PARTICIPANT\",\"approved\":{s},\"state\":{s},\"user\":{{\"display_name\":\"{s}\",\"account_id\":\"{s}\"}}}}", .{
            if (live == .approved) "true" else "false",
            if (live == .approved) "\"approved\"" else "\"changes_requested\"",
            me_display_name,
            me_account_id,
        }) catch return error.OutOfMemory;
    }
    w.writeAll("]") catch return error.OutOfMemory;
    if (st.isMerged(f.id)) {
        w.writeAll(",\"merge_commit\":{\"hash\":\"9999mergecommit\"}") catch return error.OutOfMemory;
    } else if (f.merge_sha.len > 0) {
        w.print(",\"merge_commit\":{{\"hash\":\"{s}\"}}", .{f.merge_sha}) catch return error.OutOfMemory;
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

/// `GET …/comments` — the thread as Bitbucket's comments endpoint
/// lists it: the fixture's, then any the pane posted.
fn comments(arena: Allocator, st: *State, f: *const Fixture) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"pagelen\":50,\"values\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    for (f.activity) |c| {
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"id\":{d},\"user\":{{\"display_name\":\"{s}\"}},\"created_on\":\"{s}\",\"content\":{{\"raw\":", .{ c.id, c.author, c.date }) catch return error.OutOfMemory;
        try writeJsonString(w, c.text);
        w.writeAll("}") catch return error.OutOfMemory;
        if (c.parent != 0) w.print(",\"parent\":{{\"id\":{d}}}", .{c.parent}) catch return error.OutOfMemory;
        if (c.path.len > 0) w.print(",\"inline\":{{\"path\":\"{s}\",\"from\":null,\"to\":{d}}}", .{ c.path, c.line }) catch return error.OutOfMemory;
        // The two keys the unresolved-thread count reads. Bitbucket
        // omits `resolution` entirely on an open thread, which is what
        // "present means resolved" rests on.
        if (c.resolved) w.print(",\"resolution\":{{\"type\":\"pullrequest_comment_resolution\",\"user\":{{\"display_name\":\"{s}\"}}}}", .{c.author}) catch return error.OutOfMemory;
        if (c.deleted) w.writeAll(",\"deleted\":true") catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;
        n += 1;
    }
    var buf: [16]State.Posted = undefined;
    for (st.commentsFor(f.id, &buf)) |c| {
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"id\":9999,\"user\":{\"display_name\":\"Chris M\"},\"created_on\":\"2026-09-02T09:00:00+00:00\",\"content\":{\"raw\":") catch return error.OutOfMemory;
        try writeJsonString(w, c.text);
        w.writeAll("}}") catch return error.OutOfMemory;
        n += 1;
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

fn diffstat(arena: Allocator, f: *const Fixture) Allocator.Error!Reply {
    // Bitbucket answers the diffstat of a pull request that no longer
    // applies with a 555, which is the only machine-readable "this
    // conflicts" its v2 API offers.
    if (f.conflicts) return .{ .status = 555, .body = try arena.dupe(u8, "{\"type\":\"error\",\"error\":{\"message\":\"Merge conflict\"}}") };
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

fn listBranches(arena: Allocator, st: *State, repo: []const u8) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"pagelen\":100,\"values\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    for (&branches) |*b| {
        if (!std.mem.eql(u8, b.repo, repo)) continue;
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"type\":\"branch\",\"name\":\"{s}\",\"target\":{{\"hash\":\"{s}\",\"date\":\"", .{ b.name, b.hash }) catch return error.OutOfMemory;
        writeIso(w, st.now_secs - @as(i64, b.age_hours) * 3600) catch return error.OutOfMemory;
        w.writeAll("\",\"message\":") catch return error.OutOfMemory;
        try writeJsonString(w, b.message);
        w.print(",\"author\":{{\"raw\":\"{s}\"}}}},\"links\":{{\"html\":{{\"href\":\"https://bitbucket.org/{s}/{s}/branch/{s}\"}}}}}}", .{ b.author, workspace, repo, b.name }) catch return error.OutOfMemory;
        n += 1;
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

fn listPipelines(arena: Allocator, st: *State, repo: []const u8) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"pagelen\":100,\"values\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    for (&pipelines) |*p| {
        if (!std.mem.eql(u8, p.repo, repo)) continue;
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"type\":\"pipeline\",\"uuid\":\"{{{s}-{d}}}\",\"build_number\":{d},\"state\":{{\"name\":\"{s}\"", .{ repo, p.build_number, p.build_number, p.state }) catch return error.OutOfMemory;
        if (p.result.len > 0) w.print(",\"result\":{{\"name\":\"{s}\"}}", .{p.result}) catch return error.OutOfMemory;
        w.writeAll("},\"created_on\":\"") catch return error.OutOfMemory;
        writeIso(w, st.now_secs - @as(i64, p.age_hours) * 3600) catch return error.OutOfMemory;
        w.print("\",\"duration_in_seconds\":{d},\"target\":{{\"type\":\"{s}\",\"ref_name\":\"{s}\",\"ref_type\":\"branch\",\"selector\":{{\"type\":\"{s}\"}},\"commit\":{{\"hash\":\"{s}\"}}}},\"trigger\":{{\"name\":\"{s}\"}},\"creator\":{{\"display_name\":\"{s}\"}}}}", .{
            p.duration_secs, p.target_type, p.ref_name, p.selector, p.commit, p.trigger, p.creator,
        }) catch return error.OutOfMemory;
        n += 1;
    }
    w.print("],\"size\":{d}}}", .{n}) catch return error.OutOfMemory;
    return .{ .body = out.toOwnedSlice() catch return error.OutOfMemory };
}

/// `2026-09-15T10:00:00.000000+00:00` for seconds since the epoch —
/// the shape Bitbucket writes, civil date by Howard Hinnant's
/// `civil_from_days`.
pub fn writeIso(w: *std.Io.Writer, secs: i64) std.Io.Writer.Error!void {
    const days = @divFloor(secs, 86_400);
    const rem = @mod(secs, 86_400);
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y0 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = if (m <= 2) y0 + 1 else y0;
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000000+00:00", .{
        @as(u32, @intCast(y)),                    @as(u32, @intCast(m)),                              @as(u32, @intCast(d)),
        @as(u32, @intCast(@divFloor(rem, 3600))), @as(u32, @intCast(@divFloor(@mod(rem, 3600), 60))), @as(u32, @intCast(@mod(rem, 60))),
    });
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
    try t.expectEqual(Credential.basic_account, classify("Basic bWU6dG9r"));
    try t.expectEqual(Credential.none, classify("Basic Og=="));
    try t.expectEqual(Credential.none, classify("Bearer "));
    try t.expectEqual(Credential.none, classify(""));
    try t.expect(Credential.basic_account.rejection() == null);
    try t.expect(Credential.none.rejection() != null);
}

test "the scheme has to match the token kind: an access token over Basic 401s, and so does an account token over Bearer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `Basic base64(me@x.com:ATCTTsecret)` — the shape mnml-bitbucket
    // was sending, and the 401 the user saw.
    const basic_access = "Basic " ++ "bWVAeC5jb206QVRDVFRzZWNyZXQ=";
    try t.expectEqual(Credential.basic_with_access_token, classify(basic_access));
    var st: State = .{};
    const bad = try handle(a, &st, .{ .method = .GET, .target = "/2.0/user", .authorization = basic_access });
    try t.expectEqual(@as(u16, 401), bad.status);
    try t.expectEqual(@as(u32, 1), st.unauthorized);

    // The same token as a Bearer authenticates.
    const bearer = "Bearer ATCTTsecret";
    try t.expectEqual(Credential.bearer_access_token, classify(bearer));
    const ok = try handle(a, &st, .{ .method = .GET, .target = "/2.0/repositories/acme", .authorization = bearer });
    try t.expectEqual(@as(u16, 200), ok.status);
    try t.expectEqual(Credential.bearer_access_token, st.last_credential);

    // And an account token sent as a Bearer is the mirror mistake.
    try t.expectEqual(Credential.bearer_without_access_token, classify("Bearer ATATTaccount"));
    const mirror = try handle(a, &st, .{ .method = .GET, .target = "/2.0/user", .authorization = "Bearer ATATTaccount" });
    try t.expectEqual(@as(u16, 401), mirror.status);
}

test "an access token has no account, so /2.0/user 401s for it and /2.0/workspaces/<slug> is the probe that answers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const bearer = "Bearer ATCTTsecret";
    const who = try handle(a, &st, .{ .method = .GET, .target = "/2.0/user", .authorization = bearer });
    try t.expectEqual(@as(u16, 401), who.status);
    try t.expect(std.mem.indexOf(u8, who.body, "not accessible for this authentication method") != null);
    // The workspace probe answers for both kinds.
    const ws = try handle(a, &st, .{ .method = .GET, .target = "/2.0/workspaces/acme", .authorization = bearer });
    try t.expectEqual(@as(u16, 200), ws.status);
    try t.expect(std.mem.indexOf(u8, ws.body, "\"slug\":\"acme\"") != null);
    try t.expectEqual(@as(u16, 200), (try call(a, &st, .GET, "/2.0/workspaces/acme", "")).status);
    // A workspace that is not this one is a 404, not a blanket yes.
    try t.expectEqual(@as(u16, 404), (try call(a, &st, .GET, "/2.0/workspaces/other", "")).status);
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

test "GET comments lists the fixture's thread with its parent and inline fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var st: State = .{};
    const r = try call(arena.allocator(), &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234/comments?pagelen=50", "");
    try t.expectEqual(@as(u16, 200), r.status);
    try t.expect(std.mem.indexOf(u8, r.body, "\"size\":3") != null);
    try t.expect(std.mem.indexOf(u8, r.body, "\"parent\":{\"id\":9002}") != null);
    try t.expect(std.mem.indexOf(u8, r.body, "\"inline\":{\"path\":\"src/auth/session.zig\"") != null);
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

test "the budget dial counts down on every answer and flags the last fifth; a 429 can carry no Retry-After" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .budget_limit = 10, .budget_remaining = 4, .rate_limit_next = 1, .rate_limit_retry_after = 0 };
    const first = try call(a, &st, .GET, "/2.0/user", "");
    try t.expectEqual(@as(u16, 429), first.status);
    try t.expectEqual(@as(?u32, null), first.retry_after_secs);
    try t.expectEqual(@as(u32, 3), first.budget.?.remaining);
    try t.expect(!first.budget.?.near);
    const second = try call(a, &st, .GET, "/2.0/user", "");
    try t.expectEqual(@as(u32, 2), second.budget.?.remaining);
    try t.expectEqual(@as(u32, 10), second.budget.?.limit);
    try t.expect(second.budget.?.near);
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

test "branches and pipelines answer per repo, newest first, dated against the state's clock" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .now_secs = 1_789_500_000 };
    const br = try call(a, &st, .GET, "/2.0/repositories/acme/api/refs/branches?pagelen=100&sort=-target.date", "");
    try t.expectEqual(@as(u16, 200), br.status);
    try t.expect(std.mem.indexOf(u8, br.body, "\"name\":\"chris/fix-login\"") != null);
    try t.expect(std.mem.indexOf(u8, br.body, "\"name\":\"old/experiment\"") != null);
    try t.expect(std.mem.indexOf(u8, br.body, "dana/footer") == null);
    const pl = try call(a, &st, .GET, "/2.0/repositories/acme/api/pipelines/?pagelen=100&sort=-created_on", "");
    try t.expectEqual(@as(u16, 200), pl.status);
    try t.expect(std.mem.indexOf(u8, pl.body, "\"build_number\":412") != null);
    try t.expect(std.mem.indexOf(u8, pl.body, "\"result\":{\"name\":\"FAILED\"}") != null);
    try t.expect(std.mem.indexOf(u8, pl.body, "\"build_number\":77") == null);
    // The merged fixture carries its merge commit, and a PR a day old is dated a day ago.
    const merged = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=MERGED", "");
    try t.expect(std.mem.indexOf(u8, merged.body, "\"merge_commit\":{\"hash\":\"9999mergecommit\"}") != null);
    const open = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN", "");
    try t.expect(std.mem.indexOf(u8, open.body, "2026-09-1") != null);
    const repos = try call(a, &st, .GET, "/2.0/repositories/acme?role=member", "");
    try t.expect(std.mem.indexOf(u8, repos.body, "\"updated_on\":\"2026-09-1") != null);
}

test "writeIso spells the epoch the way Bitbucket does" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIso(&w, 0);
    try t.expectEqualStrings("1970-01-01T00:00:00.000000+00:00", w.buffered());
    var w2: std.Io.Writer = .fixed(&buf);
    try writeIso(&w2, 1_789_500_000);
    try t.expectEqualStrings("2026-09-15T19:20:00.000000+00:00", w2.buffered());
}

test "`--extra-prs` grows the workspace to the size a measurement needs, and answers the same way twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .extra_prs = 20 };
    const first = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN", "");
    try t.expectEqual(@as(u16, 200), first.status);
    try t.expect(std.mem.indexOf(u8, first.body, "\"id\":9000") != null);
    try t.expect(std.mem.indexOf(u8, first.body, "\"id\":9019") != null);
    try t.expect(std.mem.indexOf(u8, first.body, "\"id\":9020") == null);
    // Nothing is random: the same server answers the same bytes, which
    // is what makes a cold-vs-warm count worth reading.
    const second = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN", "");
    try t.expectEqualStrings(first.body, second.body);
    // MERGED is untouched — the generated ones are all open.
    const merged = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=MERGED", "");
    try t.expect(std.mem.indexOf(u8, merged.body, "\"id\":9000") == null);
}

test "a GET carrying the tag it was given is answered 304 with no body" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    const first = try handle(a, &st, .{ .method = .GET, .target = "/2.0/repositories/acme/api/pullrequests?state=OPEN", .authorization = "Bearer ATCTT-x" });
    try t.expectEqual(@as(u16, 200), first.status);
    try t.expect(first.etag.len > 0);

    const again = try handle(a, &st, .{ .method = .GET, .target = "/2.0/repositories/acme/api/pullrequests?state=OPEN", .authorization = "Bearer ATCTT-x", .if_none_match = first.etag });
    try t.expectEqual(@as(u16, 304), again.status);
    try t.expectEqualStrings("", again.body);
    try t.expectEqual(@as(u32, 1), st.not_modified);

    // A tag that no longer matches the body gets the body.
    const stale = try handle(a, &st, .{ .method = .GET, .target = "/2.0/repositories/acme/api/pullrequests?state=OPEN", .authorization = "Bearer ATCTT-x", .if_none_match = "\"nonsense\"" });
    try t.expectEqual(@as(u16, 200), stale.status);
    try t.expect(stale.body.len > 0);
    try t.expectEqual(@as(u32, 1), st.not_modified);

    // A write is never conditional — it carries no tag and is never
    // answered 304, whatever it arrives holding.
    const wrote = try handle(a, &st, .{ .method = .POST, .target = "/2.0/repositories/acme/api/pullrequests/1198/approve", .authorization = "Bearer ATCTT-x", .if_none_match = first.etag });
    try t.expect(wrote.status != 304);
    try t.expectEqualStrings("", wrote.etag);
}

test "a retitled pull request reads its new title on the listing and on its own" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var st: State = .{};
    const before = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234", "");
    try t.expect(std.mem.indexOf(u8, before.body, "Fix the login redirect") != null);
    const r = try handle(a, &st, .{ .method = .POST, .target = "/__retitle/1234", .body = "Fix the login redirect, again" });
    try t.expectEqual(@as(u16, 204), r.status);
    const after = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests/1234", "");
    try t.expect(std.mem.indexOf(u8, after.body, "Fix the login redirect, again") != null);
    const list = try call(a, &st, .GET, "/2.0/repositories/acme/api/pullrequests?state=OPEN", "");
    try t.expect(std.mem.indexOf(u8, list.body, "Fix the login redirect, again") != null);
    try t.expectEqual(@as(u16, 404), (try handle(a, &st, .{ .method = .POST, .target = "/__retitle/77", .body = "x" })).status);
}
