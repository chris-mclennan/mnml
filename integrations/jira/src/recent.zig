//! What this integration hands the shared recent-items cache
//! (`sdk.cache`): every listing it polls anyway, as ticket records —
//! key, summary, status, assignee's display name, priority, type, fix
//! versions, updated. Never the body, never an account id or an email.
//!
//! The listings, by the name each is written under:
//!
//!   assigned_open    `--values`' first figure (the work-assigned JQL)
//!   qa_actionable    `--values`' second figure (the QA tab), when set
//!   tab:<name>       a pane tab's fetch; complete unless it was a
//!                    delta window or an event feed's keys

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const model = @import("model.zig");

pub const source = "jira";

/// The issues as cache records, on `arena` (borrowing their strings).
pub fn tickets(arena: Allocator, issues: []const model.Issue) Allocator.Error![]sdk.cache.Ticket {
    const out = try arena.alloc(sdk.cache.Ticket, issues.len);
    var n: usize = 0;
    for (issues) |iss| {
        if (iss.key.len == 0) continue;
        out[n] = .{
            .id = iss.key,
            .summary = iss.summary,
            .status = iss.status,
            .status_category = iss.status_category,
            .assignee = if (iss.assignee) |u| u.display_name else "",
            .priority = iss.priority,
            .type = iss.issuetype,
            .fix_versions = iss.fix_versions,
            .updated = iss.updated,
        };
        n += 1;
    }
    return out[0..n];
}

/// The poll interval doubled; a manual pane (0) gets the SDK's default.
pub fn staleAfter(refresh_interval_secs: u32) u32 {
    return if (refresh_interval_secs == 0) 1800 else refresh_interval_secs *| 2;
}

/// One listing, written under `root` (`sdk.cache.rootDir`; null: the
/// cache is off or there is no home). Best effort.
pub fn publish(gpa: Allocator, io: Io, root: ?[]const u8, listing: []const u8, complete: bool, refresh_interval_secs: u32, issues: []const model.Issue) sdk.cache.Outcome {
    const r = root orelse return .disabled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const recs = tickets(arena.allocator(), issues) catch return .failed;
    return sdk.cache.putAt(gpa, io, r, .{
        .source = source,
        .kind = .ticket,
        .listing = listing,
        .complete = complete,
        .stale_after_secs = staleAfter(refresh_interval_secs),
    }, recs);
}

/// A poll that did not answer.
pub fn failed(gpa: Allocator, io: Io, root: ?[]const u8) void {
    const r = root orelse return;
    _ = sdk.cache.failedAt(gpa, io, r, source, .ticket, null);
}

/// Where this process writes: null when the host turned it off.
pub fn rootFor(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (!sdk.cache.enabled(env)) return null;
    return sdk.cache.rootDir(gpa, env);
}

test "a listing lands as ticket records: the display name, never the account id; a failure moves error_at" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const root = try std.fs.path.join(t.allocator, &.{ dir, "recent" });
    defer t.allocator.free(root);
    const issues = [_]model.Issue{
        .{ .key = "ACME-123", .summary = "Fix the login redirect", .status = "In Review", .status_category = "indeterminate", .issuetype = "Bug", .priority = "High", .assignee = .{ .account_id = "acct-1", .display_name = "Pat Example" }, .fix_versions = &.{"2026.10"} },
        .{ .key = "ACME-124", .summary = "Basket total" },
    };
    try t.expectEqual(sdk.cache.Outcome.written, publish(t.allocator, t.io, root, "assigned_open", true, 60, &issues));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = sdk.cache.getAt(.ticket, a, t.io, root, "ACME-123", std.Io.Timestamp.now(t.io, .real).toSeconds()).?;
    try t.expectEqualStrings("Fix the login redirect", got.record.summary);
    try t.expectEqualStrings("Pat Example", got.record.assignee);
    try t.expectEqualStrings("Bug", got.record.type);
    try t.expectEqualStrings("jira", got.source);
    const path = try sdk.cache.filePath(a, root, "jira", .ticket);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .limited(1 << 20));
    try t.expect(std.mem.indexOf(u8, text, "acct-1") == null);
    try t.expect(std.mem.indexOf(u8, text, "\"assigned_open\"") != null);
    try t.expectEqual(@as(i64, 120), sdk.cache.readFile(a, t.io, path).?.stale_after_secs);
    failed(t.allocator, t.io, root);
    try t.expect(sdk.cache.readFile(a, t.io, path).?.error_at > 0);
    // Off: nothing written.
    try t.expectEqual(sdk.cache.Outcome.disabled, publish(t.allocator, t.io, null, "assigned_open", true, 60, &issues));
}
