//! `docs/LUA.md` against `api.zig` — the two halves of the same
//! promise, checked in both directions.
//!
//! A script author reads the doc; the app registers the table. Nothing
//! made those agree: a function could be added to `root_fns` and never
//! written down (so nobody finds it), or written down and never
//! registered (so it reads as real and errors on the first call). Both
//! have happened in editors that shipped a scripting API.
//!
//! The rule the doc keeps, so this can be mechanical: **every
//! `mnml.*` function has a `####` heading whose first backticked word
//! is its call.**
//!
//!     #### `mnml.buf.range(start, end_, pane?)`
//!
//! The path is what follows `mnml.` up to the first `(`, `{`, backtick
//! or space. Sub-tables get `###` headings and are not read as
//! functions, so `### The picker` and `#### \`mnml.picker.open(id)\``
//! do not collide.
//!
//! Run by `zig build test` (and `MNML_TEST_FILTER=doc`). There is no
//! script in `tools/` for it: the doc is embedded, so the check cannot
//! drift out of the build or be skipped on a machine without python.

const std = @import("std");
const api = @import("api.zig");

/// `docs/LUA.md`, embedded by `build.zig`.
pub const text = @embedFile("lua_md");

/// The heading a function must carry, as a prefix.
const heading = "#### `mnml.";

/// Every `mnml.*` path the doc gives a `####` heading to, in order.
/// On `arena`.
pub fn documented(arena: std.mem.Allocator, md: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, heading)) continue;
        const rest = line["#### `".len..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != '(' and rest[end] != '{' and rest[end] != '`' and rest[end] != ' ') end += 1;
        try out.append(arena, rest[0..end]);
    }
    return out.items;
}

/// Every `mnml.*` path `api.zig` registers, in the order it registers
/// them. On `arena`.
pub fn registered(arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    inline for (api.root_fns) |f| try out.append(arena, "mnml." ++ f.name);
    inline for (api.tables) |tbl| {
        inline for (tbl.fns) |f| try out.append(arena, "mnml." ++ tbl.name ++ "." ++ f.name);
    }
    return out.items;
}

fn has(list: []const []const u8, want: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, want)) return true;
    return false;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "docs/LUA.md documents every registered mnml.* function, and every documented one is registered" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg = try registered(arena);
    const doc = try documented(arena, text);
    try t.expect(reg.len > 30);
    var missing: usize = 0;
    for (reg) |r| if (!has(doc, r)) {
        std.debug.print("docs/LUA.md has no `#### `{s}(…)`` heading — it is registered in api.zig\n", .{r});
        missing += 1;
    };
    var invented: usize = 0;
    for (doc) |d| if (!has(reg, d)) {
        std.debug.print("docs/LUA.md documents `{s}`, which api.zig does not register\n", .{d});
        invented += 1;
    };
    if (missing + invented > 0) return error.TestExpectedEqual;
    // A heading twice is a doc that grew a second home for one
    // function — the accretion this file exists to stop.
    for (doc, 0..) |d, i| for (doc[i + 1 ..]) |other| if (std.mem.eql(u8, d, other)) {
        std.debug.print("docs/LUA.md has two `{s}` headings\n", .{d});
        return error.TestExpectedEqual;
    };
}

test "the doc check can fail: a made-up function, and a registered one left out" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The parse itself, on a small doc: a `####` heading is a function,
    // a `###` one is a section, and the path stops at the call.
    const sample =
        \\### The picker
        \\#### `mnml.picker.open(id, query?)`
        \\Some prose about `mnml.picker.source` that is not a heading.
        \\#### `mnml.list{ title, rows }`
        \\#### `mnml.teleport(x)`
        \\
    ;
    const found = try documented(arena, sample);
    try t.expectEqual(@as(usize, 3), found.len);
    try t.expectEqualStrings("mnml.picker.open", found[0]);
    try t.expectEqualStrings("mnml.list", found[1]);
    try t.expectEqualStrings("mnml.teleport", found[2]);
    // `mnml.teleport` is not registered — the direction that keeps a
    // made-up function out of the doc.
    const reg = try registered(arena);
    try t.expect(!has(reg, "mnml.teleport"));
    try t.expect(has(reg, "mnml.picker.open"));
    // And a registered function missing from a doc is caught: the real
    // doc has `mnml.buf.text`, this sample does not.
    try t.expect(has(reg, "mnml.buf.text"));
    try t.expect(!has(found, "mnml.buf.text"));
}
