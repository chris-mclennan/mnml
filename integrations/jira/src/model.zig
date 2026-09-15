//! The flat shape the pane works in: one `Issue` per row of a search,
//! read out of the JSON once so nothing above this line touches
//! `std.json.Value` again.
//!
//! Every string borrows the arena the search was parsed on, so an
//! `Issue` is cheap to copy and dies with its refresh.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const theme = @import("theme.zig");

pub const Value = std.json.Value;

/// Where an issue sits in Jira's hierarchy. Read from the issue type,
/// not from the tree — an epic is an epic whether or not its children
/// came back in the same search.
pub const Level = enum {
    epic,
    story,
    subtask,

    pub fn of(kind: []const u8, is_subtask: bool) Level {
        if (is_subtask) return .subtask;
        if (std.ascii.eqlIgnoreCase(kind, "epic")) return .epic;
        if (std.ascii.eqlIgnoreCase(kind, "sub-task") or std.ascii.eqlIgnoreCase(kind, "subtask")) return .subtask;
        return .story;
    }
};

pub const Issue = struct {
    /// The numeric id — what the dev-status endpoint wants.
    id: []const u8 = "",
    key: []const u8 = "",
    summary: []const u8 = "",
    kind: []const u8 = "",
    level: Level = .story,
    status: []const u8 = "",
    category: theme.StatusCategory = .unknown,
    assignee: []const u8 = "",
    assignee_id: []const u8 = "",
    reporter: []const u8 = "",
    priority: []const u8 = "",
    updated: []const u8 = "",
    created: []const u8 = "",
    fix_version: []const u8 = "",
    /// The epic (or the parent story of a sub-task), if the field is set.
    parent_key: []const u8 = "",
    parent_summary: []const u8 = "",
    /// The sub-task keys the issue declares, whether or not the search
    /// returned them.
    subtask_keys: []const []const u8 = &.{},
    /// The value of the configured team custom field, when there is one.
    team: []const u8 = "",

    pub fn isResolved(i: Issue) bool {
        return i.category == .done;
    }

    /// The one-line summary a row prints, whitespace already collapsed.
    pub fn line(i: Issue) []const u8 {
        return i.summary;
    }
};

/// One issue out of a search result. `team_field` is the id of the
/// custom field the config names, or empty.
pub fn fromJson(arena: Allocator, v: Value, team_field: []const u8) Allocator.Error!Issue {
    var subtasks: std.ArrayListUnmanaged([]const u8) = .empty;
    for (json.array(v, "fields.subtasks")) |s| {
        if (json.getStr(s, "key")) |k| try subtasks.append(arena, k);
    }
    const kind = json.getStrOr(v, "fields.issuetype.name", "");
    const raw_summary = json.getStrOr(v, "fields.summary", "");
    const team = if (team_field.len == 0) "" else blk: {
        var path_buf: [80]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "fields.{s}", .{team_field}) catch break :blk "";
        const node = json.get(v, path) orelse break :blk "";
        break :blk json.str(node) orelse json.getStrOr(node, "value", json.getStrOr(node, "name", ""));
    };
    return .{
        .id = json.getStrOr(v, "id", ""),
        .key = json.getStrOr(v, "key", ""),
        .summary = try @import("text.zig").oneLine(arena, raw_summary),
        .kind = kind,
        .level = Level.of(kind, json.getBool(v, "fields.issuetype.subtask") orelse false),
        .status = json.getStrOr(v, "fields.status.name", "Unknown"),
        .category = theme.StatusCategory.fromKey(json.getStrOr(v, "fields.status.statusCategory.key", "")),
        .assignee = json.getStrOr(v, "fields.assignee.displayName", ""),
        .assignee_id = json.getStrOr(v, "fields.assignee.accountId", ""),
        .reporter = json.getStrOr(v, "fields.reporter.displayName", ""),
        .priority = json.getStrOr(v, "fields.priority.name", ""),
        .updated = json.getStrOr(v, "fields.updated", ""),
        .created = json.getStrOr(v, "fields.created", ""),
        .fix_version = json.getStrOr(v, "fields.fixVersions.0.name", ""),
        .parent_key = json.getStrOr(v, "fields.parent.key", ""),
        .parent_summary = json.getStrOr(v, "fields.parent.fields.summary", ""),
        .subtask_keys = try subtasks.toOwnedSlice(arena),
        .team = team,
    };
}

pub fn listFromJson(arena: Allocator, items: []const Value, team_field: []const u8) Allocator.Error![]Issue {
    const out = try arena.alloc(Issue, items.len);
    for (items, 0..) |v, i| out[i] = try fromJson(arena, v, team_field);
    return out;
}

pub const Comment = struct {
    author: []const u8,
    created: []const u8,
    body: []const u8,
};

/// What the detail pane adds to the row it already has.
pub const Detail = struct {
    key: []const u8,
    description: []const u8 = "",
    comments: []const Comment = &.{},
    comment_total: usize = 0,
    watchers: i64 = 0,
    watching: bool = false,
};

pub fn detailFromJson(arena: Allocator, v: Value) Allocator.Error!Detail {
    var comments: std.ArrayListUnmanaged(Comment) = .empty;
    for (json.array(v, "fields.comment.comments")) |c| try comments.append(arena, .{
        .author = json.getStrOr(c, "author.displayName", "(someone)"),
        .created = json.getStrOr(c, "created", ""),
        .body = try json.renderBody(arena, json.get(c, "body")),
    });
    return .{
        .key = json.getStrOr(v, "key", ""),
        .description = try json.renderBody(arena, json.get(v, "fields.description")),
        .comments = try comments.toOwnedSlice(arena),
        .comment_total = @intCast(json.getInt(v, "fields.comment.total") orelse @as(i64, @intCast(comments.items.len))),
        .watchers = json.getInt(v, "fields.watches.watchCount") orelse 0,
        .watching = json.getBool(v, "fields.watches.isWatching") orelse false,
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(arena: Allocator, s: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, s, .{});
}

test "an issue comes out of the JSON with its level, its category and its parent" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try parse(arena,
        \\{"id":"10002","key":"ENG-2","fields":{
        \\ "summary":"Card form\n  validates  on blur",
        \\ "issuetype":{"name":"Story","subtask":false},
        \\ "status":{"name":"In Review","statusCategory":{"key":"indeterminate"}},
        \\ "assignee":{"accountId":"a1","displayName":"Ada"},
        \\ "reporter":{"accountId":"a2","displayName":"Sam"},
        \\ "priority":{"name":"Medium"},
        \\ "updated":"2026-09-15T08:30:00.000+0000","created":"2026-08-04T09:00:00.000+0000",
        \\ "fixVersions":[{"name":"13.16.0"},{"name":"13.17.0"}],
        \\ "parent":{"key":"ENG-1","fields":{"summary":"Checkout rewrite"}},
        \\ "subtasks":[{"key":"ENG-4"},{"key":"ENG-9"}],
        \\ "customfield_10056":{"value":"Apollo"}}}
    );
    const i = try fromJson(arena, v, "customfield_10056");
    try testing.expectEqualStrings("ENG-2", i.key);
    try testing.expectEqualStrings("10002", i.id);
    // The summary is one line — Jira lets a newline into one.
    try testing.expectEqualStrings("Card form validates on blur", i.summary);
    try testing.expectEqual(Level.story, i.level);
    try testing.expectEqual(theme.StatusCategory.indeterminate, i.category);
    try testing.expectEqualStrings("Ada", i.assignee);
    try testing.expectEqualStrings("a1", i.assignee_id);
    try testing.expectEqualStrings("13.16.0", i.fix_version);
    try testing.expectEqualStrings("ENG-1", i.parent_key);
    try testing.expectEqualStrings("Checkout rewrite", i.parent_summary);
    try testing.expectEqual(@as(usize, 2), i.subtask_keys.len);
    try testing.expectEqualStrings("Apollo", i.team);
    try testing.expect(!i.isResolved());
}

test "the missing halves of an issue are empty, never a crash" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try parse(arena, "{\"key\":\"ENG-3\",\"fields\":{\"summary\":\"bare\",\"assignee\":null}}");
    const i = try fromJson(arena, v, "customfield_1");
    try testing.expectEqualStrings("ENG-3", i.key);
    try testing.expectEqualStrings("", i.assignee);
    try testing.expectEqualStrings("Unknown", i.status);
    try testing.expectEqual(theme.StatusCategory.unknown, i.category);
    try testing.expectEqualStrings("", i.fix_version);
    try testing.expectEqualStrings("", i.team);
    try testing.expectEqual(@as(usize, 0), i.subtask_keys.len);
}

test "a sub-task is a sub-task by its flag or by its type name; an epic by its name" {
    try testing.expectEqual(Level.subtask, Level.of("Anything", true));
    try testing.expectEqual(Level.subtask, Level.of("Sub-task", false));
    try testing.expectEqual(Level.subtask, Level.of("subtask", false));
    try testing.expectEqual(Level.epic, Level.of("Epic", false));
    try testing.expectEqual(Level.epic, Level.of("EPIC", false));
    try testing.expectEqual(Level.story, Level.of("Bug", false));
    try testing.expectEqual(Level.story, Level.of("", false));
}

test "the detail carries the description, the comments and the watch state" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try parse(arena,
        \\{"key":"ENG-2","fields":{
        \\ "description":{"type":"doc","version":1,"content":[
        \\   {"type":"paragraph","content":[{"type":"text","text":"Validate on blur."}]}]},
        \\ "watches":{"watchCount":3,"isWatching":true},
        \\ "comment":{"total":2,"comments":[
        \\   {"author":{"displayName":"Sam"},"created":"2026-09-14T10:00:00.000+0000",
        \\    "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"note"}]}]}},
        \\   {"author":{"displayName":"Ada"},"created":"2026-09-15T08:00:00.000+0000","body":"plain v2 body"}]}}}
    );
    const d = try detailFromJson(arena, v);
    try testing.expectEqualStrings("ENG-2", d.key);
    try testing.expect(std.mem.indexOf(u8, d.description, "Validate on blur.") != null);
    try testing.expectEqual(@as(usize, 2), d.comments.len);
    try testing.expectEqualStrings("Sam", d.comments[0].author);
    try testing.expect(std.mem.indexOf(u8, d.comments[0].body, "note") != null);
    try testing.expectEqualStrings("plain v2 body", d.comments[1].body);
    try testing.expectEqual(@as(i64, 3), d.watchers);
    try testing.expect(d.watching);
    // A bare issue answers with empties.
    const bare = try detailFromJson(arena, try parse(arena, "{\"key\":\"ENG-9\",\"fields\":{}}"));
    try testing.expectEqualStrings("", bare.description);
    try testing.expectEqual(@as(usize, 0), bare.comments.len);
    try testing.expect(!bare.watching);
}
