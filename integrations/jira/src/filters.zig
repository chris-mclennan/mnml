//! The client-side filters over a tab's tickets: the `/` text, the
//! assignee set (with the Unassigned sentinel), the epic set, the type,
//! the label, the team (component / label / team field), and the
//! All / Unresolved / Resolved scope chip. One mask for the tree and the
//! kanban alike — in the reference only the kanban honoured the text
//! and assignee filters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const text = @import("text.zig");

const Issue = model.Issue;

pub const Scope = enum {
    all,
    unresolved,
    resolved,

    pub fn cycle(s: Scope) Scope {
        return switch (s) {
            .all => .unresolved,
            .unresolved => .resolved,
            .resolved => .all,
        };
    }

    pub fn label(s: Scope) []const u8 {
        return switch (s) {
            .all => "All",
            .unresolved => "Unresolved",
            .resolved => "Resolved",
        };
    }
};

pub const Criteria = struct {
    /// Substring of the key or the summary, case-insensitive.
    text: []const u8 = "",
    /// Account ids; the sentinel matches an unassigned ticket. Empty = all.
    assignees: []const []const u8 = &.{},
    /// Epic keys. Empty = all.
    epics: []const []const u8 = &.{},
    /// Exact, case-insensitive.
    issue_type: []const u8 = "",
    label: []const u8 = "",
    /// Substring against components, labels and the team field.
    team: []const u8 = "",
    scope: Scope = .all,

    pub fn any(c: Criteria) bool {
        return c.text.len > 0 or c.assignees.len > 0 or c.epics.len > 0 or c.issue_type.len > 0 or c.label.len > 0 or c.team.len > 0 or c.scope != .all;
    }
};

pub fn passes(iss: Issue, c: Criteria) bool {
    if (c.scope == .unresolved and !iss.isUnresolved()) return false;
    if (c.scope == .resolved and iss.isUnresolved()) return false;
    if (c.assignees.len > 0) {
        const id = iss.assigneeId();
        var hit = false;
        for (c.assignees) |a| {
            if (id.len == 0 and std.mem.eql(u8, a, model.unassigned_sentinel)) hit = true;
            if (id.len > 0 and std.mem.eql(u8, a, id)) hit = true;
        }
        if (!hit) return false;
    }
    if (c.epics.len > 0) {
        const epic = iss.epicKey() orelse return false;
        var hit = false;
        for (c.epics) |e| if (std.mem.eql(u8, e, epic)) {
            hit = true;
        };
        if (!hit) return false;
    }
    if (c.issue_type.len > 0 and !std.ascii.eqlIgnoreCase(iss.issuetype, c.issue_type)) return false;
    if (c.label.len > 0) {
        var hit = false;
        for (iss.labels) |l| if (std.ascii.eqlIgnoreCase(l, c.label)) {
            hit = true;
        };
        if (!hit) return false;
    }
    if (c.team.len > 0) {
        var hit = text.containsIgnoreCase(iss.team, c.team);
        for (iss.components) |x| if (text.containsIgnoreCase(x, c.team)) {
            hit = true;
        };
        for (iss.labels) |x| if (text.containsIgnoreCase(x, c.team)) {
            hit = true;
        };
        if (!hit) return false;
    }
    if (c.text.len > 0) {
        if (!text.containsIgnoreCase(iss.key, c.text) and !text.containsIgnoreCase(iss.summary, c.text)) return false;
    }
    return true;
}

/// One bool per ticket.
pub fn mask(arena: Allocator, issues: []const Issue, c: Criteria) Allocator.Error![]bool {
    const out = try arena.alloc(bool, issues.len);
    for (issues, out) |iss, *m| m.* = passes(iss, c);
    return out;
}

pub fn countTrue(m: []const bool) usize {
    var n: usize = 0;
    for (m) |b| n += @intFromBool(b);
    return n;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "every criterion narrows, and they compose" {
    const issues = [_]Issue{
        .{ .key = "ENG-1", .summary = "Fix the bufferline", .status = "To Do", .issuetype = "Bug", .assignee = .{ .account_id = "a1" }, .labels = &.{"admin"}, .components = &.{"web-team"}, .parent_key = "ENG-9", .parent_type = "Epic" },
        .{ .key = "ENG-2", .summary = "AI panel margin", .status = "Done", .issuetype = "Story", .labels = &.{"tools"}, .team = "Apollo" },
        .{ .key = "XX-3", .summary = "eng-trap", .status = "Testing", .issuetype = "Bug", .assignee = .{ .account_id = "a2" } },
    };
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const all = try mask(a.allocator(), &issues, .{});
    try testing.expectEqual(@as(usize, 3), countTrue(all));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .text = "PANEL" })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .text = "eng-1" })));
    try testing.expectEqual(@as(usize, 2), countTrue(try mask(a.allocator(), &issues, .{ .scope = .unresolved })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .scope = .resolved })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .assignees = &.{"a1"} })));
    try testing.expectEqual(@as(usize, 2), countTrue(try mask(a.allocator(), &issues, .{ .assignees = &.{ "a1", model.unassigned_sentinel } })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .epics = &.{"ENG-9"} })));
    try testing.expectEqual(@as(usize, 2), countTrue(try mask(a.allocator(), &issues, .{ .issue_type = "bug" })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .label = "ADMIN" })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .team = "apollo" })));
    try testing.expectEqual(@as(usize, 1), countTrue(try mask(a.allocator(), &issues, .{ .team = "web" })));
    try testing.expectEqual(@as(usize, 0), countTrue(try mask(a.allocator(), &issues, .{ .text = "ENG-", .scope = .resolved, .issue_type = "Bug" })));
    try testing.expect(!(Criteria{}).any() and (Criteria{ .scope = .resolved }).any());
    try testing.expectEqual(Scope.resolved, Scope.all.cycle().cycle());
    try testing.expectEqualStrings("Unresolved", Scope.unresolved.label());
}
