//! Reading Jira's JSON without a schema for it.
//!
//! A Jira issue carries a hundred fields, half of them custom, and the
//! shape of `description` alone changes with the API version. Declaring
//! a Zig struct for that would break on the first site with a field we
//! did not name, so this integration parses to `std.json.Value` on an
//! arena and pulls what it needs by path:
//!
//!     const key = str(get(issue, "key")) orelse "";
//!     const status = str(get(issue, "fields.status.name")) orelse "";
//!
//! A path segment that is missing, null or the wrong type yields null,
//! never an error — a ticket without an assignee is normal, not a fault.

const std = @import("std");

pub const Value = std.json.Value;

/// Walk a dotted path. A segment of digits indexes an array.
pub fn get(v: ?Value, path: []const u8) ?Value {
    var cur = v orelse return null;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        cur = switch (cur) {
            .object => |o| o.get(seg) orelse return null,
            .array => |a| blk: {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return null;
                if (idx >= a.items.len) return null;
                break :blk a.items[idx];
            },
            else => return null,
        };
        if (cur == .null) return null;
    }
    return cur;
}

/// The string at `v`, or null when it is not one.
pub fn str(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string, .number_string => |s| s,
        else => null,
    };
}

/// `get` + `str` — the common case.
pub fn getStr(v: ?Value, path: []const u8) ?[]const u8 {
    return str(get(v, path));
}

/// `getStr`, or `""` — for a field a row prints whether or not it is set.
pub fn getStrOr(v: ?Value, path: []const u8, fallback: []const u8) []const u8 {
    return getStr(v, path) orelse fallback;
}

pub fn getInt(v: ?Value, path: []const u8) ?i64 {
    return switch (get(v, path) orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn getBool(v: ?Value, path: []const u8) ?bool {
    return switch (get(v, path) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// The array at `path`, or an empty slice.
pub fn array(v: ?Value, path: []const u8) []const Value {
    return switch (get(v, path) orelse return &.{}) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// Jira's Atlassian Document Format (the v3 `description` / comment
/// body) flattened to plain text: every `text` node in document order,
/// with a blank line between block nodes and `• ` in front of a list
/// item. A v2 site sends wiki markup as a plain string instead, which
/// `renderBody` passes through untouched.
pub fn renderBody(gpa: std.mem.Allocator, v: ?Value) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const node = v orelse return out.toOwnedSlice();
    switch (node) {
        .string => |s| out.writer.writeAll(s) catch return error.OutOfMemory,
        .object => try adf(&out.writer, node, 0),
        else => {},
    }
    return out.toOwnedSlice();
}

fn adf(w: *std.Io.Writer, node: Value, depth: u8) std.mem.Allocator.Error!void {
    const obj = switch (node) {
        .object => |o| o,
        .array => |a| {
            for (a.items) |item| try adf(w, item, depth);
            return;
        },
        else => return,
    };
    const kind = str(obj.get("type")) orelse "";
    if (std.mem.eql(u8, kind, "text")) {
        w.writeAll(str(obj.get("text")) orelse "") catch return error.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, kind, "hardBreak")) {
        w.writeByte('\n') catch return error.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, kind, "mention")) {
        // Jira writes the `@` into `attrs.text` itself; some sites do not.
        const who = str(get(node, "attrs.text")) orelse "?";
        if (!std.mem.startsWith(u8, who, "@")) w.writeByte('@') catch return error.OutOfMemory;
        w.writeAll(who) catch return error.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, kind, "inlineCard")) {
        w.writeAll(str(get(node, "attrs.url")) orelse "") catch return error.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, kind, "rule")) {
        w.writeAll("\n────\n") catch return error.OutOfMemory;
        return;
    }
    const is_block = std.mem.eql(u8, kind, "paragraph") or
        std.mem.eql(u8, kind, "heading") or
        std.mem.eql(u8, kind, "codeBlock") or
        std.mem.eql(u8, kind, "blockquote") or
        std.mem.eql(u8, kind, "panel");
    const is_item = std.mem.eql(u8, kind, "listItem");
    if (is_item) w.writeAll("• ") catch return error.OutOfMemory;
    if (obj.get("content")) |content| try adf(w, content, depth + 1);
    if (is_block or is_item) w.writeByte('\n') catch return error.OutOfMemory;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSliceLeaky(Value, arena, text, .{}));
}

test "a dotted path reaches through objects and arrays; a missing or null hop is null" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const v = try parse(a.allocator(),
        \\{"key":"ENG-1","fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},
        \\ "assignee":null,"labels":["a","b"],"votes":3,"flagged":true,"subtasks":[{"key":"ENG-2"}]}}
    );
    try testing.expectEqualStrings("ENG-1", getStr(v, "key").?);
    try testing.expectEqualStrings("In Progress", getStr(v, "fields.status.name").?);
    try testing.expectEqualStrings("indeterminate", getStr(v, "fields.status.statusCategory.key").?);
    try testing.expectEqualStrings("ENG-2", getStr(v, "fields.subtasks.0.key").?);
    try testing.expectEqualStrings("b", getStr(v, "fields.labels.1").?);
    try testing.expectEqual(@as(i64, 3), getInt(v, "fields.votes").?);
    try testing.expect(getBool(v, "fields.flagged").?);
    // A null field, a missing field, a wrong-typed hop, an index past the end.
    try testing.expect(getStr(v, "fields.assignee.displayName") == null);
    try testing.expect(getStr(v, "fields.nope") == null);
    try testing.expect(getStr(v, "key.deeper") == null);
    try testing.expect(getStr(v, "fields.labels.9") == null);
    try testing.expectEqualStrings("—", getStrOr(v, "fields.assignee.displayName", "—"));
    try testing.expectEqual(@as(usize, 2), array(v, "fields.labels").len);
    try testing.expectEqual(@as(usize, 0), array(v, "fields.nope").len);
    try testing.expectEqual(@as(usize, 0), array(v, "key").len);
}

test "ADF flattens to text: paragraphs, breaks, lists, mentions, links" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const v = try parse(a.allocator(),
        \\{"type":"doc","version":1,"content":[
        \\ {"type":"paragraph","content":[{"type":"text","text":"Login fails for "},
        \\   {"type":"mention","attrs":{"text":"@sam"}},{"type":"text","text":" on Safari."}]},
        \\ {"type":"bulletList","content":[
        \\   {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"clear cookies"}]}]},
        \\   {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"retry"}]}]}]},
        \\ {"type":"paragraph","content":[{"type":"inlineCard","attrs":{"url":"https://x/y"}}]}]}
    );
    const text = try renderBody(testing.allocator, v);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Login fails for @sam on Safari.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "• clear cookies") != null);
    try testing.expect(std.mem.indexOf(u8, text, "• retry") != null);
    try testing.expect(std.mem.indexOf(u8, text, "https://x/y") != null);
}

test "a v2 site's plain-string description passes through; a missing one is empty" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const v = try parse(a.allocator(), "{\"fields\":{\"description\":\"h2. Steps\\n# open\\n# click\"}}");
    const text = try renderBody(testing.allocator, get(v, "fields.description"));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("h2. Steps\n# open\n# click", text);
    const none = try renderBody(testing.allocator, get(v, "fields.nope"));
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("", none);
}
