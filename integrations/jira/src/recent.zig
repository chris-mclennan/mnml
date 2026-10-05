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
//!
//! And releases: each project's fix versions whenever the pane fetched
//! them anyway (a release tab resolving its version, the Fix Version
//! picker), as `versions:<PROJECT>`, complete; a release tab's own
//! fetch adds the keys it lists. `role` marks the project's `current`
//! release — the nearest unreleased one by release date, the undated
//! last — and the `next` after it; `recent_items.current_release` in
//! mnml's config (`$MNML_RECENT_CURRENT_RELEASE`) names `current`
//! outright.

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

/// The env var mnml sets from `recent_items.current_release`.
pub const current_release_env = "MNML_RECENT_CURRENT_RELEASE";

/// `ACME/2026.10`. On `arena`.
pub fn releaseId(arena: Allocator, project: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ project, name });
}

fn stateOf(v: model.Version) []const u8 {
    return if (v.archived) "archived" else if (v.released) "released" else "unreleased";
}

/// The order roles are read in: release date ascending, the undated
/// after every dated one, then the name.
fn nearerRelease(_: void, a: model.Version, b: model.Version) bool {
    const ad = a.release_date.len > 0;
    const bd = b.release_date.len > 0;
    if (ad != bd) return ad;
    if (ad) {
        const c = std.mem.order(u8, a.release_date, b.release_date);
        if (c != .eq) return c == .lt;
    }
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// The project's versions as release records, roles decided: `current`
/// is the nearest unreleased version by release date (undated last),
/// or `forced` (`ACME/2026.10`) when it names one of them; `next` is
/// the unreleased one after `current`. Keys empty. On `arena`.
pub fn releases(arena: Allocator, project: []const u8, versions: []const model.Version, forced: []const u8) Allocator.Error![]sdk.cache.Release {
    var open: std.ArrayList(model.Version) = .empty;
    for (versions) |v| if (!v.released and !v.archived) try open.append(arena, v);
    std.mem.sort(model.Version, open.items, {}, nearerRelease);
    var current: ?usize = if (open.items.len > 0) 0 else null;
    for (open.items, 0..) |v, i| if (std.mem.eql(u8, try releaseId(arena, project, v.name), forced)) {
        current = i;
    };
    const out = try arena.alloc(sdk.cache.Release, versions.len);
    for (versions, out) |v, *r| {
        var role: []const u8 = "";
        if (current) |c| {
            if (std.mem.eql(u8, v.name, open.items[c].name)) role = "current";
            if (c + 1 < open.items.len and std.mem.eql(u8, v.name, open.items[c + 1].name)) role = "next";
        }
        r.* = .{
            .id = try releaseId(arena, project, v.name),
            .name = v.name,
            .project = project,
            .state = stateOf(v),
            .release_date = v.release_date,
            .role = role,
        };
    }
    return out;
}

/// A project's fix versions, as fetched. The keys a release tab last
/// listed for each are kept: this fetch does not know them.
pub fn publishReleases(gpa: Allocator, io: Io, root: ?[]const u8, project: []const u8, versions: []const model.Version, forced: []const u8, refresh_interval_secs: u32) sdk.cache.Outcome {
    const r = root orelse return .disabled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = releases(a, project, versions, forced) catch return .failed;
    const now = Io.Timestamp.now(io, .real).toSeconds();
    for (recs) |*rec| if (sdk.cache.getAt(.release, a, io, r, rec.id, now)) |old| {
        rec.keys = old.record.keys;
    };
    const listing = std.fmt.allocPrint(a, "versions:{s}", .{project}) catch return .failed;
    return sdk.cache.putAt(gpa, io, r, .{
        .source = source,
        .kind = .release,
        .listing = listing,
        .complete = true,
        .stale_after_secs = staleAfter(refresh_interval_secs),
    }, recs);
}

/// The issues a release tab lists for `name`: the record's `keys`,
/// the rest of it as last written.
pub fn publishReleaseKeys(gpa: Allocator, io: Io, root: ?[]const u8, project: []const u8, name: []const u8, refresh_interval_secs: u32, issues: []const model.Issue) sdk.cache.Outcome {
    const r = root orelse return .disabled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const id = releaseId(a, project, name) catch return .failed;
    const now = Io.Timestamp.now(io, .real).toSeconds();
    var rec: sdk.cache.Release = if (sdk.cache.getAt(.release, a, io, r, id, now)) |old| old.record else .{ .id = id, .name = name, .project = project };
    const keys = a.alloc([]const u8, issues.len) catch return .failed;
    for (issues, keys) |iss, *k| k.* = iss.key;
    rec.keys = keys;
    return sdk.cache.putAt(gpa, io, r, .{ .source = source, .kind = .release, .stale_after_secs = staleAfter(refresh_interval_secs) }, &[_]sdk.cache.Release{rec});
}

/// A versions fetch that did not answer.
pub fn releasesFailed(gpa: Allocator, io: Io, root: ?[]const u8) void {
    const r = root orelse return;
    _ = sdk.cache.failedAt(gpa, io, r, source, .release, null);
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

test "releases: current is the nearest unreleased by release date, undated last; next follows; the config names current outright" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vs = [_]model.Version{
        .{ .name = "2026.09", .released = true, .release_date = "2026-09-15" },
        .{ .name = "someday" },
        .{ .name = "2026.11", .release_date = "2026-11-12" },
        .{ .name = "2026.10", .release_date = "2026-10-15" },
        .{ .name = "2026.08", .archived = true, .release_date = "2026-08-01" },
    };
    const recs = try releases(a, "ACME", &vs, "");
    const Want = struct { id: []const u8, state: []const u8, role: []const u8 };
    const want = [_]Want{
        .{ .id = "ACME/2026.09", .state = "released", .role = "" },
        .{ .id = "ACME/someday", .state = "unreleased", .role = "" },
        .{ .id = "ACME/2026.11", .state = "unreleased", .role = "next" },
        .{ .id = "ACME/2026.10", .state = "unreleased", .role = "current" },
        .{ .id = "ACME/2026.08", .state = "archived", .role = "" },
    };
    for (recs, want) |r, w| {
        try t.expectEqualStrings(w.id, r.id);
        try t.expectEqualStrings(w.state, r.state);
        try t.expectEqualStrings(w.role, r.role);
        try t.expectEqualStrings("ACME", r.project);
    }
    // The override: current where the config says, next the one after.
    const forced = try releases(a, "ACME", &vs, "ACME/2026.11");
    try t.expectEqualStrings("current", forced[2].role);
    try t.expectEqualStrings("next", forced[1].role);
    try t.expectEqualStrings("", forced[3].role);
    // Naming a version the project does not have changes nothing.
    try t.expectEqualStrings("current", (try releases(a, "ACME", &vs, "OTHER/2026.11"))[3].role);
    // Only undated ones: the first by name is current.
    const undated = [_]model.Version{ .{ .name = "b" }, .{ .name = "a" } };
    const u = try releases(a, "ACME", &undated, "");
    try t.expectEqualStrings("current", u[1].role);
    try t.expectEqualStrings("next", u[0].role);
}

test "releases land with their roles; a release tab's keys survive the next versions fetch" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const root = try std.fs.path.join(t.allocator, &.{ dir, "recent" });
    defer t.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vs = [_]model.Version{ .{ .name = "2026.10", .release_date = "2026-10-15" }, .{ .name = "2026.11", .release_date = "2026-11-12" } };
    try t.expectEqual(sdk.cache.Outcome.written, publishReleases(t.allocator, t.io, root, "ACME", &vs, "", 60));
    const issues = [_]model.Issue{ .{ .key = "ACME-123" }, .{ .key = "ACME-124" } };
    try t.expectEqual(sdk.cache.Outcome.written, publishReleaseKeys(t.allocator, t.io, root, "ACME", "2026.10", 60, &issues));
    try t.expectEqual(sdk.cache.Outcome.written, publishReleases(t.allocator, t.io, root, "ACME", &vs, "", 60));
    const now = std.Io.Timestamp.now(t.io, .real).toSeconds();
    const cur = sdk.cache.getAt(.release, a, t.io, root, "ACME/2026.10", now).?;
    try t.expectEqualStrings("current", cur.record.role);
    try t.expectEqualStrings("2026-10-15", cur.record.release_date);
    try t.expectEqual(@as(usize, 2), cur.record.keys.len);
    try t.expectEqualStrings("ACME-124", cur.record.keys[1]);
    try t.expectEqualStrings("next", sdk.cache.getAt(.release, a, t.io, root, "ACME/2026.11", now).?.record.role);
    releasesFailed(t.allocator, t.io, root);
    try t.expect(sdk.cache.readFile(a, t.io, try sdk.cache.filePath(a, root, source, .release)).?.error_at > 0);
}
