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
        const merge = json.getStrOr(pr, "merge_commit.hash", "");
        const hash = if (merge.len > 0) merge else json.getStrOr(pr, "source.commit.hash", "");
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
            .on_merge = merge.len > 0,
            .updated_on = updated_on,
        } };
    }

    const Got = union(enum) { ok: Value, failed: []const u8 };

    fn get(c: *Client, arena: Allocator, url: []const u8) Allocator.Error!Got {
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
            else => return .{ .failed = try std.fmt.allocPrint(arena, "request failed ({s})", .{@errorName(err)}) },
        };
        const status: u16 = @intFromEnum(res.status);
        if (status < 200 or status >= 300) return .{ .failed = try std.fmt.allocPrint(arena, "{d}: {s}", .{ status, out.written() }) };
        const doc = std.json.parseFromSliceLeaky(Value, arena, out.written(), .{}) catch return .{ .failed = "the answer was not JSON" };
        return .{ .ok = doc };
    }
};

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
