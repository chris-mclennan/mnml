//! What this integration hands the shared recent-items cache
//! (`sdk.cache`): every pull request and pipeline run a poll it makes
//! anyway brings back, as records — a pull request's title, branches,
//! author's display name, state; a run's state, result and ref. Never a
//! description, never an account id.
//!
//! Ids are what the link rules match: `acme/widget#45` for a pull
//! request, `acme/widget!1234` for a pipeline run.
//!
//! The listings, by the name each is written under:
//!
//!   authored         `--values`' pull requests the account wrote
//!   reviewing        `--values`' pull requests it reviews
//!   probe            `--values`' hourly per-repo pipeline probe
//!   tab:<name>       a pane tab's fetch
//!
//! A pull-request listing is complete when every repo answered; a
//! pipeline listing never is — it is the newest page of a history, so a
//! run that dropped off it has aged out, not changed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const model = @import("model.zig");

pub const source = "bitbucket";

/// Where this process writes, and how soon what it writes goes stale.
/// `root` null: the cache is off or there is no home.
pub const Sink = struct {
    root: ?[]const u8 = null,
    /// The poll interval doubled (`staleAfter`).
    stale_after_secs: u32 = 1800,
};

/// The poll interval doubled; a manual pane (0) gets the SDK's default.
pub fn staleAfter(refresh_interval_secs: u32) u32 {
    return if (refresh_interval_secs == 0) 1800 else refresh_interval_secs *| 2;
}

/// Where this process writes: null when the host turned it off.
pub fn rootFor(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (!sdk.cache.enabled(env)) return null;
    return sdk.cache.rootDir(gpa, env);
}

/// `acme/widget#45`. `repo_full` is the listing's own when the reply
/// named none.
pub fn prId(arena: Allocator, pr: model.PullRequest, repo_full: []const u8) Allocator.Error![]const u8 {
    const repo = if (pr.repo_full.len > 0) pr.repo_full else repo_full;
    return std.fmt.allocPrint(arena, "{s}#{d}", .{ repo, pr.id });
}

pub fn prRecord(arena: Allocator, pr: model.PullRequest, repo_full: []const u8) Allocator.Error!sdk.cache.Pr {
    return .{
        .id = try prId(arena, pr, repo_full),
        .title = pr.title,
        .source_branch = pr.source_branch,
        .dest_branch = pr.dest_branch,
        .author = pr.author,
        .state = pr.state,
        .draft = pr.draft,
        .updated = pr.updated_on,
    };
}

pub fn pipelineRecord(arena: Allocator, p: model.Pipeline, repo_full: []const u8) Allocator.Error!sdk.cache.Pipeline {
    return .{
        .id = try std.fmt.allocPrint(arena, "{s}!{d}", .{ repo_full, p.build_number }),
        .state = p.state_name,
        .result = p.result_name,
        .ref_name = p.ref_name,
        .created = p.created_on,
    };
}

/// Pull requests gathered from a listing, to hand over in one write.
pub const PrBatch = struct {
    list: std.ArrayList(sdk.cache.Pr) = .empty,

    pub fn add(b: *PrBatch, arena: Allocator, pr: model.PullRequest, repo_full: []const u8) Allocator.Error!void {
        if (pr.id <= 0) return;
        try b.list.append(arena, try prRecord(arena, pr, repo_full));
    }
};

pub const PipelineBatch = struct {
    list: std.ArrayList(sdk.cache.Pipeline) = .empty,

    pub fn add(b: *PipelineBatch, arena: Allocator, p: model.Pipeline, repo_full: []const u8) Allocator.Error!void {
        if (p.build_number <= 0 or repo_full.len == 0) return;
        try b.list.append(arena, try pipelineRecord(arena, p, repo_full));
    }
};

/// One pull-request listing. Best effort.
pub fn publishPrs(gpa: Allocator, io: Io, sink: Sink, listing: []const u8, complete: bool, recs: []const sdk.cache.Pr) sdk.cache.Outcome {
    const r = sink.root orelse return .disabled;
    return sdk.cache.putAt(gpa, io, r, .{ .source = source, .kind = .pr, .listing = listing, .complete = complete, .stale_after_secs = sink.stale_after_secs }, recs);
}

/// One pipeline listing — never complete (see the module comment).
pub fn publishPipelines(gpa: Allocator, io: Io, sink: Sink, listing: []const u8, recs: []const sdk.cache.Pipeline) sdk.cache.Outcome {
    const r = sink.root orelse return .disabled;
    return sdk.cache.putAt(gpa, io, r, .{ .source = source, .kind = .pipeline, .listing = listing, .stale_after_secs = sink.stale_after_secs }, recs);
}

/// A poll of `kind` that did not answer.
pub fn failed(gpa: Allocator, io: Io, sink: Sink, kind: sdk.cache.Kind) void {
    const r = sink.root orelse return;
    _ = sdk.cache.failedAt(gpa, io, r, source, kind, null);
}

test "pull requests and pipeline runs land under their link ids, with display names and never an account id" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const root = try std.fs.path.join(t.allocator, &.{ dir, "recent" });
    defer t.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sink: Sink = .{ .root = root, .stale_after_secs = staleAfter(60) };

    var prs: PrBatch = .{};
    try prs.add(a, .{ .id = 45, .title = "Redesign the empty state", .state = "OPEN", .author = "Max Orr", .author_id = "{acct-7}", .source_branch = "feat/empty", .dest_branch = "main", .repo_full = "acme/widget" }, "acme/other");
    // No repository in the reply: the listing's repo names it.
    try prs.add(a, .{ .id = 46, .title = "Bump the client timeout", .state = "MERGED" }, "acme/widget");
    try t.expectEqual(sdk.cache.Outcome.written, publishPrs(t.allocator, t.io, sink, "authored", true, prs.list.items));

    var runs: PipelineBatch = .{};
    try runs.add(a, .{ .build_number = 1234, .state_name = "COMPLETED", .result_name = "FAILED", .ref_name = "main", .created_on = "2026-10-01T09:00:00Z", .creator = "Max Orr" }, "acme/widget");
    try t.expectEqual(sdk.cache.Outcome.written, publishPipelines(t.allocator, t.io, sink, "probe", runs.list.items));

    const now = std.Io.Timestamp.now(t.io, .real).toSeconds();
    const pr = sdk.cache.getAt(.pr, a, t.io, root, "acme/widget#45", now).?;
    try t.expectEqualStrings("Redesign the empty state", pr.record.title);
    try t.expectEqualStrings("Max Orr", pr.record.author);
    try t.expectEqualStrings("bitbucket", pr.source);
    try t.expectEqualStrings("MERGED", sdk.cache.getAt(.pr, a, t.io, root, "acme/widget#46", now).?.record.state);
    const run = sdk.cache.getAt(.pipeline, a, t.io, root, "acme/widget!1234", now).?;
    try t.expectEqualStrings("FAILED", run.record.result);
    try t.expectEqualStrings("main", run.record.ref_name);

    const text = try Io.Dir.cwd().readFileAlloc(t.io, try sdk.cache.filePath(a, root, source, .pr), a, .limited(1 << 20));
    try t.expect(std.mem.indexOf(u8, text, "acct-7") == null);
    try t.expect(std.mem.indexOf(u8, text, "\"authored\"") != null);
    try t.expectEqual(@as(i64, 120), sdk.cache.readFile(a, t.io, try sdk.cache.filePath(a, root, source, .pr)).?.stale_after_secs);

    // A failed poll moves error_at; the records stay.
    failed(t.allocator, t.io, sink, .pipeline);
    try t.expect(sdk.cache.readFile(a, t.io, try sdk.cache.filePath(a, root, source, .pipeline)).?.error_at > 0);
    try t.expect(sdk.cache.getAt(.pipeline, a, t.io, root, "acme/widget!1234", now) != null);
    // Off: nothing written.
    try t.expectEqual(sdk.cache.Outcome.disabled, publishPrs(t.allocator, t.io, .{}, "authored", true, prs.list.items));
}
