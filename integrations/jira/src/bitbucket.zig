//! The one forge call the tree makes: the pipelines that ran on the
//! commit a pull request is about. A PR URL is parsed into workspace /
//! repo / id, the PR fetched, and the repo's recent pipelines filtered
//! client-side by its commit (the `?target.commit.hash=` filter is
//! unreliable on that endpoint; the PR API returns a 12-char short hash
//! and the pipelines API a full one, so either prefix matches the
//! other).
//!
//! Which commit: a MERGED pull request's `merge_commit.hash` — what
//! actually landed — and an OPEN one's `source.commit.hash`, the head
//! of the branch under review. An open PR's builds are the ones you
//! want before you merge it, and they used to be unreachable: the row
//! answered "PR not merged — no merge commit" and stopped.
//!
//! Two requests, and the second is skipped whenever it can be. The PR
//! detail carries `updated_on`, which Bitbucket moves when anything on
//! the pull request does; a caller that already has pipelines for that
//! stamp gets `.unchanged` back and pays one request instead of two.
//!
//! The token is a repository / workspace access token from
//! `$BITBUCKET_ACCESS_TOKEN`; without it the row says so.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("json.zig");
const model = @import("model.zig");
const sdk = @import("mnml_sdk");
const merge = sdk.pane.merge;
const shared_rate = sdk.ratelimit;
const request_log = sdk.request_log;

pub const Value = std.json.Value;

pub const PrRef = struct { workspace: []const u8, repo: []const u8, id: []const u8 };

/// `https://bitbucket.org/{ws}/{repo}/pull-requests/{id}[/…]` → the three
/// parts; null for anything else.
pub fn parsePrUrl(url: []const u8) ?PrRef {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "https://")) rest = rest["https://".len..];
    if (std.mem.startsWith(u8, rest, "http://")) rest = rest["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (!std.ascii.eqlIgnoreCase(rest[0..slash], "bitbucket.org")) return null;
    var it = std.mem.splitScalar(u8, rest[slash + 1 ..], '/');
    const ws = it.next() orelse return null;
    const repo = it.next() orelse return null;
    const marker = it.next() orelse return null;
    if (!std.mem.eql(u8, marker, "pull-requests")) return null;
    const raw_id = it.next() orelse return null;
    var n: usize = 0;
    while (n < raw_id.len and std.ascii.isDigit(raw_id[n])) : (n += 1) {}
    if (n == 0 or ws.len == 0 or repo.len == 0) return null;
    return .{ .workspace = ws, .repo = repo, .id = raw_id[0..n] };
}

/// The runs on one pull request's commit, and what they are keyed by.
pub const Runs = struct {
    pipelines: []const model.Pipeline = &.{},
    /// The commit they ran on — the merge commit, or the source head.
    commit: []const u8 = "",
    /// True when `commit` is the merge commit rather than the branch head.
    on_merge: bool = false,
    /// The pull request's `updated_on` when they were read: the key a
    /// caller hands back to skip the second request next time.
    updated_on: []const u8 = "",
};

/// Whether one pull request may merge, and what it cost.
pub const ReadinessOutcome = union(enum) {
    ok: struct { readiness: merge.Readiness, updated_on: []const u8 },
    /// It has not moved since `known_updated_on`: one request, and what
    /// the caller holds still stands.
    unchanged,
    failed: []const u8,
};

pub const Outcome = union(enum) {
    ok: Runs,
    /// The pull request has not moved since `known_updated_on`, so what
    /// the caller already has is still right. One request, not two.
    unchanged,
    /// The sentence the tree row paints.
    failed: []const u8,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    /// `https://api.bitbucket.org/2.0`, or the fake's.
    base_url: []const u8,
    /// Empty = no token.
    token: []const u8,
    /// The FORGE's bucket, not Jira's. These calls used to go out with
    /// no bucket at all: a Work tab quietly spent the machine's
    /// Bitbucket allowance from the Jira pane, and the forge pane in
    /// the next window paid for it with a 429. Null only in a test.
    limiter: ?*shared_rate.Limiter = null,
    /// Where every one of them is written down. Null in a test.
    log: ?*request_log.Log = null,
    /// Where a wait long enough for a person to notice is left.
    notice: ?*shared_rate.Notice = null,
    /// Why these calls are being made — the row's builds, or its
    /// merge readiness. Set by the caller that starts the flow.
    reason: request_log.Reason = .builds,

    /// The whole flow for one PR URL. `known_updated_on` is the stamp
    /// the caller already has runs for — empty when it has none.
    pub fn pipelinesForPrUrl(c: *Client, arena: Allocator, pr_url: []const u8, known_updated_on: []const u8) Allocator.Error!Outcome {
        if (c.token.len == 0) return .{ .failed = "BITBUCKET_ACCESS_TOKEN not set — needed to fetch a pull request's pipelines" };
        const ref = parsePrUrl(pr_url) orelse {
            if (std.mem.indexOf(u8, pr_url, "github.com") != null) return .{ .failed = "GitHub PR pipeline lookup not supported yet" };
            return .{ .failed = "not a bitbucket PR URL" };
        };
        const pr_url_api = try std.fmt.allocPrint(arena, "{s}/repositories/{s}/{s}/pullrequests/{s}", .{ c.base_url, ref.workspace, ref.repo, ref.id });
        const pr = switch (try c.get(arena, pr_url_api)) {
            .ok => |v| v,
            .failed => |f| return .{ .failed = try std.fmt.allocPrint(arena, "bitbucket PR detail {s}", .{f}) },
        };
        const updated_on = json.getStrOr(pr, "updated_on", "");
        // Bitbucket moves `updated_on` when anything on the pull
        // request does, a push included. Nothing has: the runs the
        // caller holds are still the right ones.
        if (known_updated_on.len > 0 and updated_on.len > 0 and std.mem.eql(u8, known_updated_on, updated_on)) return .unchanged;
        // A merged pull request is about what landed; an open one is
        // about the head of the branch under review.
        const merged_sha = json.getStrOr(pr, "merge_commit.hash", "");
        const hash = if (merged_sha.len > 0) merged_sha else json.getStrOr(pr, "source.commit.hash", "");
        if (hash.len == 0) return .{ .failed = "the PR names no commit to look up builds on" };
        const list_url = try std.fmt.allocPrint(arena, "{s}/repositories/{s}/{s}/pipelines/?pagelen=60&sort=-created_on", .{ c.base_url, ref.workspace, ref.repo });
        const page = switch (try c.get(arena, list_url)) {
            .ok => |v| v,
            .failed => |f| return .{ .failed = try std.fmt.allocPrint(arena, "bitbucket pipelines {s}", .{f}) },
        };
        var out: std.ArrayList(model.Pipeline) = .empty;
        for (json.array(page, "values")) |p| {
            const pl = model.Pipeline.fromJson(p);
            if (!sameCommit(pl.commit, hash)) continue;
            try out.append(arena, pl);
        }
        return .{ .ok = .{
            .pipelines = try out.toOwnedSlice(arena),
            .commit = hash,
            .on_merge = merged_sha.len > 0,
            .updated_on = updated_on,
        } };
    }

    /// The five conditions, in one cached look: the pull request's own
    /// detail (approvals, changes requested, open tasks), its diffstat
    /// (a non-2xx is a conflict — Bitbucket answers 555), its comments,
    /// and the newest run on the commit it is about. `known_build`
    /// short-circuits the last one when the row's builds are already
    /// open and fresh.
    pub fn readinessForPrUrl(
        c: *Client,
        arena: Allocator,
        pr_url: []const u8,
        known_updated_on: []const u8,
        required: usize,
        known_build: ?bool,
    ) Allocator.Error!ReadinessOutcome {
        if (c.token.len == 0) return .{ .failed = "BITBUCKET_ACCESS_TOKEN not set — needed to judge a pull request" };
        const ref = parsePrUrl(pr_url) orelse {
            if (std.mem.indexOf(u8, pr_url, "github.com") != null) return .{ .failed = "GitHub merge readiness not supported yet" };
            return .{ .failed = "not a bitbucket PR URL" };
        };
        const base = try std.fmt.allocPrint(arena, "{s}/repositories/{s}/{s}/pullrequests/{s}", .{ c.base_url, ref.workspace, ref.repo, ref.id });
        const pr = switch (try c.get(arena, base)) {
            .ok => |v| v,
            .failed => |f| return .{ .failed = try std.fmt.allocPrint(arena, "bitbucket PR detail {s}", .{f}) },
        };
        const updated_on = json.getStrOr(pr, "updated_on", "");
        if (known_updated_on.len > 0 and updated_on.len > 0 and std.mem.eql(u8, known_updated_on, updated_on)) return .unchanged;

        var r: merge.Readiness = .{ .required = @max(required, 1), .checked = true };
        for (json.array(pr, "participants")) |p| {
            if (json.getBool(p, "approved") orelse false) r.approvals += 1;
            const state = json.getStrOr(p, "state", "");
            if (std.ascii.eqlIgnoreCase(state, "changes_requested")) r.changes_requested = true;
        }
        r.open_tasks = @intCast(@max(json.getInt(pr, "task_count") orelse 0, 0));

        // The diffstat's STATUS is the answer; its body is not read.
        const diffstat_url = try std.fmt.allocPrint(arena, "{s}/diffstat?pagelen=50", .{base});
        r.conflicts = (try c.get(arena, diffstat_url)) != .ok;

        const comments_url = try std.fmt.allocPrint(arena, "{s}/comments?pagelen=50", .{base});
        switch (try c.get(arena, comments_url)) {
            .ok => |page| r.unanswered_comments = unansweredThreads(page),
            // A comments request that failed is not "no comments".
            .failed => r.unanswered_comments = 1,
        }

        if (known_build) |green| {
            r.build_green = green;
        } else {
            const merge_sha = json.getStrOr(pr, "merge_commit.hash", "");
            const hash = if (merge_sha.len > 0) merge_sha else json.getStrOr(pr, "source.commit.hash", "");
            const list_url = try std.fmt.allocPrint(arena, "{s}/repositories/{s}/{s}/pipelines/?pagelen=60&sort=-created_on", .{ c.base_url, ref.workspace, ref.repo });
            switch (try c.get(arena, list_url)) {
                .ok => |page| {
                    var newest: ?model.Pipeline = null;
                    for (json.array(page, "values")) |pv| {
                        const pl = model.Pipeline.fromJson(pv);
                        if (!sameCommit(pl.commit, hash)) continue;
                        if (newest == null) newest = pl;
                    }
                    r.build_green = if (newest) |n| std.ascii.eqlIgnoreCase(n.stateLabel(), "SUCCESSFUL") else false;
                },
                .failed => r.build_green = false,
            }
        }
        return .{ .ok = .{ .readiness = r, .updated_on = updated_on } };
    }

    const Got = union(enum) { ok: Value, failed: []const u8 };

    fn get(c: *Client, arena: Allocator, url: []const u8) Allocator.Error!Got {
        const gate: shared_rate.Acquired = if (c.limiter) |l| blk: {
            l.reason = @tagName(c.reason);
            break :blk l.acquireDetailed();
        } else .{ .ok = true };
        if (c.notice) |n| n.record(gate);
        const started = Io.Timestamp.now(c.io, .real);
        var client: std.http.Client = .{ .allocator = c.gpa, .io = c.io };
        defer client.deinit();
        var out: Io.Writer.Allocating = .init(arena);
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{c.token});
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "user-agent", .value = "mnml-jira" },
        };
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &out.writer,
            .extra_headers = &headers,
            .keep_alive = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                c.note(arena, url, null, 0, started, gate);
                return .{ .failed = try std.fmt.allocPrint(arena, "request failed ({s})", .{@errorName(err)}) };
            },
        };
        const status: u16 = @intFromEnum(res.status);
        c.note(arena, url, status, out.written().len, started, gate);
        // A 429 or a 5xx from the forge parks every process on the
        // forge's bucket, the same as one from Jira parks Jira's.
        if (status == 429 or (status >= 500 and status <= 599)) {
            if (c.limiter) |l| l.penalize(null);
        }
        if (status < 200 or status >= 300) return .{ .failed = try std.fmt.allocPrint(arena, "{d}: {s}", .{ status, out.written() }) };
        const doc = std.json.parseFromSliceLeaky(Value, arena, out.written(), .{}) catch return .{ .failed = "the answer was not JSON" };
        return .{ .ok = doc };
    }

    /// One line in the request log. Best effort: a log is never a
    /// reason a request fails.
    fn note(c: *Client, arena: Allocator, url: []const u8, status: ?u16, bytes: usize, started: Io.Timestamp, gate: shared_rate.Acquired) void {
        const log = c.log orelse return;
        const split = request_log.splitUrl(arena, url) catch return;
        const ms: u64 = @intCast(@max(Io.Timestamp.now(c.io, .real).toMilliseconds() - started.toMilliseconds(), 0));
        log.append(.{
            .service = "",
            .integration = "",
            .method = "GET",
            .host = split.host,
            .path = split.path,
            .status = status,
            .ms = ms,
            .bytes = bytes,
            .reason = c.reason,
            .wait_ms = gate.wait_ms,
            .waited_for = gate.waited_for,
            .tokens_after = gate.tokens_after,
        });
    }
};

/// Comment threads on a pull request that are neither resolved nor
/// replied to — the same rule the forge pane's review count uses: a
/// reply is an answer whoever wrote it, and the resolve button is used
/// unevenly across teams.
pub fn unansweredThreads(page: Value) usize {
    const values = json.array(page, "values");
    var n: usize = 0;
    for (values) |c| {
        if (json.getBool(c, "deleted") orelse false) continue;
        if (json.get(c, "resolution") != null) continue;
        const id = json.getInt(c, "id") orelse 0;
        if (id == 0) continue;
        if ((json.getInt(c, "parent.id") orelse 0) != 0) continue;
        var replied = false;
        for (values) |other| {
            if (json.getBool(other, "deleted") orelse false) continue;
            if ((json.getInt(other, "parent.id") orelse 0) == id) replied = true;
        }
        if (!replied) n += 1;
    }
    return n;
}

/// One hash is a prefix of the other, case-insensitively.
pub fn sameCommit(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const n = @min(a.len, b.len);
    return std.ascii.eqlIgnoreCase(a[0..n], b[0..n]);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a PR URL parses into workspace, repo and id; anything else does not" {
    const r = parsePrUrl("https://bitbucket.org/acme/acme-api/pull-requests/2023").?;
    try testing.expectEqualStrings("acme", r.workspace);
    try testing.expectEqualStrings("acme-api", r.repo);
    try testing.expectEqualStrings("2023", r.id);
    try testing.expectEqualStrings("42", parsePrUrl("https://bitbucket.org/foo/bar/pull-requests/42/diff").?.id);
    try testing.expectEqualStrings("9", parsePrUrl("bitbucket.org/foo/bar/pull-requests/9").?.id);
    try testing.expect(parsePrUrl("https://github.com/foo/bar/pull/1") == null);
    try testing.expect(parsePrUrl("https://bitbucket.org/foo/bar/commits/abc") == null);
    try testing.expect(parsePrUrl("https://bitbucket.org/foo/bar/pull-requests/") == null);
    try testing.expect(sameCommit("abc123def456", "ABC123DEF456789012345678901234567890abcd"));
    try testing.expect(!sameCommit("abc123", "abd123"));
    try testing.expect(!sameCommit("", "abc"));
}

test "without a token the outcome names the variable; a non-forge URL is named too" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var c: Client = .{ .gpa = testing.allocator, .io = testing.io, .base_url = "http://127.0.0.1:1", .token = "" };
    const none = try c.pipelinesForPrUrl(a.allocator(), "https://bitbucket.org/a/b/pull-requests/1", "");
    try testing.expect(std.mem.indexOf(u8, none.failed, "BITBUCKET_ACCESS_TOKEN not set") != null);
    c.token = "x";
    const gh = try c.pipelinesForPrUrl(a.allocator(), "https://github.com/a/b/pull/1", "");
    try testing.expectEqualStrings("GitHub PR pipeline lookup not supported yet", gh.failed);
    const other = try c.pipelinesForPrUrl(a.allocator(), "https://example.com/x", "");
    try testing.expectEqualStrings("not a bitbucket PR URL", other.failed);
}
