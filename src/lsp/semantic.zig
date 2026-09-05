//! Semantic tokens: the legend a server declares, decoded once into the
//! theme's roles; the flat `data[]` array (five integers per token,
//! line and column relative to the previous token) decoded into
//! absolute tokens; and a `full/delta` reply's sparse edits spliced
//! into the cached array so the next request can name its `resultId`.
//!
//! A token's type lands on the same `Role` a tree-sitter capture would
//! (`namespace` → `.type`, `parameter` → `.variable`, …) so the theme
//! paints both layers from one table; the modifiers that carry a
//! visible attribute (`declaration` bold, `static` italic, `deprecated`
//! struck through, `documentation` as a comment) ride alongside.

const std = @import("std");
const Allocator = std.mem.Allocator;
const highlight = @import("highlight");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const Value = jsonrpc.Value;

pub const Role = highlight.Role;

/// The token types mnml asks for, in the order the LSP spec lists them.
pub const token_type_names = [_][]const u8{
    "namespace", "type",     "class",      "enum",   "interface", "struct",   "typeParameter", "parameter",
    "variable",  "property", "enumMember", "event",  "function",  "method",   "macro",         "keyword",
    "modifier",  "comment",  "string",     "number", "regexp",    "operator", "decorator",
};

pub const modifier_names = [_][]const u8{
    "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary",
};

/// The modifiers with a visible effect. Everything else decodes to
/// `.none` and paints nothing extra.
pub const Modifier = enum(u8) {
    none,
    declaration,
    static,
    deprecated,
    documentation,
};

/// What a token type paints as.
pub fn roleForType(name: []const u8) Role {
    const KV = struct { []const u8, Role };
    const table = [_]KV{
        .{ "namespace", .type },      .{ "type", .type },          .{ "class", .type },         .{ "enum", .type },               .{ "interface", .type },
        .{ "struct", .type },         .{ "typeParameter", .type }, .{ "parameter", .variable }, .{ "variable", .default },        .{ "property", .variable },
        .{ "enumMember", .constant }, .{ "event", .variable },     .{ "function", .function },  .{ "method", .function },         .{ "macro", .function },
        .{ "keyword", .keyword },     .{ "modifier", .keyword },   .{ "comment", .comment },    .{ "string", .string },           .{ "number", .constant },
        .{ "regexp", .special },      .{ "operator", .default },   .{ "decorator", .special },  .{ "label", .type },              .{ "builtinType", .type },
        .{ "selfKeyword", .keyword }, .{ "lifetime", .special },   .{ "boolean", .constant },   .{ "escapeSequence", .special },  .{ "punctuation", .punctuation },
        .{ "attribute", .type },      .{ "derive", .type },        .{ "const", .constant },     .{ "constParameter", .constant },
    };
    for (table) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
    return .none;
}

pub fn modifierFor(name: []const u8) Modifier {
    if (std.mem.eql(u8, name, "declaration") or std.mem.eql(u8, name, "definition")) return .declaration;
    if (std.mem.eql(u8, name, "static")) return .static;
    if (std.mem.eql(u8, name, "deprecated")) return .deprecated;
    if (std.mem.eql(u8, name, "documentation")) return .documentation;
    return .none;
}

/// The legend's `tokenTypes` as roles by index. Owned by the caller.
pub fn readTypes(gpa: Allocator, names: []const Value) Allocator.Error![]Role {
    const out = try gpa.alloc(Role, names.len);
    for (names, 0..) |v, i| out[i] = roleForType(jsonrpc.asStr(v) orelse "");
    return out;
}

/// The legend's `tokenModifiers` by bit index. Owned by the caller.
pub fn readModifiers(gpa: Allocator, names: []const Value) Allocator.Error![]Modifier {
    const out = try gpa.alloc(Modifier, names.len);
    for (names, 0..) |v, i| out[i] = modifierFor(jsonrpc.asStr(v) orelse "");
    return out;
}

/// One decoded token: absolute line, start column and length in the
/// server's position units, the role its type maps to, and the
/// modifier bits (as the legend indexes them).
pub const Token = struct {
    line: u32,
    start: u32,
    len: u32,
    role: Role,
    mods: u32,

    pub fn has(t: Token, legend: []const Modifier, m: Modifier) bool {
        for (legend, 0..) |lm, i| if (lm == m and i < 32 and (t.mods >> @intCast(i)) & 1 == 1) return true;
        return false;
    }
};

/// `data[]` → absolute tokens, in document order. Entries whose type
/// index is off the legend, or that map to no role, are dropped.
pub fn decode(arena: Allocator, data: []const u32, types: []const Role) Allocator.Error![]Token {
    var out: std.ArrayListUnmanaged(Token) = .empty;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i + 5 <= data.len) : (i += 5) {
        const d_line = data[i];
        const d_start = data[i + 1];
        const len = data[i + 2];
        const type_idx = data[i + 3];
        const mods = data[i + 4];
        line += d_line;
        col = if (d_line == 0) col + d_start else d_start;
        if (type_idx >= types.len or len == 0) continue;
        const role = types[type_idx];
        if (role == .none) continue;
        try out.append(arena, .{ .line = line, .start = col, .len = len, .role = role, .mods = mods });
    }
    return out.items;
}

/// A JSON `data` array → `u32`s (negative or fractional values clamp).
pub fn readData(gpa: Allocator, v: ?Value) Allocator.Error![]u32 {
    const arr: []const Value = if (v) |val| switch (val) {
        .array => |a| a.items,
        else => &.{},
    } else &.{};
    const out = try gpa.alloc(u32, arr.len);
    for (arr, 0..) |item, i| out[i] = switch (item) {
        .integer => |n| @intCast(std.math.clamp(n, 0, std.math.maxInt(u32))),
        .float => |f| @intFromFloat(std.math.clamp(f, 0, std.math.maxInt(u32))),
        else => 0,
    };
    return out;
}

/// One splice of a `SemanticTokensDelta`.
pub const Edit = struct { start: u32, delete_count: u32, data: []const u32 };

/// Apply `edits` to `old` (the previous full array). Edits are applied
/// from the highest `start` down, as the spec asks, so each one's
/// offsets refer to the array before any of them. Owned by the caller.
pub fn applyDelta(gpa: Allocator, old: []const u32, edits_in: []const Edit) Allocator.Error![]u32 {
    const sorted = try gpa.dupe(Edit, edits_in);
    defer gpa.free(sorted);
    std.mem.sort(Edit, sorted, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.start > b.start;
        }
    }.lt);
    var list: std.ArrayListUnmanaged(u32) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, old);
    for (sorted) |e| {
        const start = @min(e.start, list.items.len);
        const end = @min(start + e.delete_count, list.items.len);
        try list.replaceRange(gpa, start, end - start, e.data);
    }
    return list.toOwnedSlice(gpa);
}

/// The `edits` of a delta reply. Arena-owned data slices.
pub fn readEdits(arena: Allocator, v: ?Value) Allocator.Error![]Edit {
    var out: std.ArrayListUnmanaged(Edit) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| {
        const start: u32 = @intCast(std.math.clamp(jsonrpc.getInt(it, "start") orelse 0, 0, std.math.maxInt(u32)));
        const del: u32 = @intCast(std.math.clamp(jsonrpc.getInt(it, "deleteCount") orelse 0, 0, std.math.maxInt(u32)));
        const data = try readData(arena, jsonrpc.getField(it, "data"));
        try out.append(arena, .{ .start = start, .delete_count = del, .data = data });
    }
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "the legend decodes to roles and modifiers; unknown names paint nothing" {
    var p = try std.json.parseFromSlice(Value, testing.allocator, "{\"tokenTypes\":[\"function\",\"parameter\",\"mystery\",\"keyword\"],\"tokenModifiers\":[\"declaration\",\"readonly\",\"deprecated\"]}", .{});
    defer p.deinit();
    const types = try readTypes(testing.allocator, jsonrpc.getArr(p.value, "tokenTypes").?);
    defer testing.allocator.free(types);
    const mods = try readModifiers(testing.allocator, jsonrpc.getArr(p.value, "tokenModifiers").?);
    defer testing.allocator.free(mods);
    try testing.expectEqualSlices(Role, &.{ .function, .variable, .none, .keyword }, types);
    try testing.expectEqualSlices(Modifier, &.{ .declaration, .none, .deprecated }, mods);
}

test "decode walks the relative encoding: same-line columns accumulate, a new line resets them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const types = [_]Role{ .keyword, .function, .none };
    // `fn main` on line 0 (fn at 0, main at 3), then `x` on line 2 col 4, then a typeless token dropped.
    const data = [_]u32{ 0, 0, 2, 0, 0, 0, 3, 4, 1, 1, 2, 4, 1, 1, 0, 0, 2, 1, 2, 0 };
    const toks = try decode(arena.allocator(), &data, &types);
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqual(Token{ .line = 0, .start = 0, .len = 2, .role = .keyword, .mods = 0 }, toks[0]);
    try testing.expectEqual(Token{ .line = 0, .start = 3, .len = 4, .role = .function, .mods = 1 }, toks[1]);
    try testing.expectEqual(Token{ .line = 2, .start = 4, .len = 1, .role = .function, .mods = 0 }, toks[2]);
    const legend = [_]Modifier{ .declaration, .deprecated };
    try testing.expect(toks[1].has(&legend, .declaration));
    try testing.expect(!toks[1].has(&legend, .deprecated));
}

test "a delta splices from the highest start down, so every edit's offsets are the old array's" {
    const old = [_]u32{ 0, 0, 2, 0, 0, 0, 3, 4, 1, 0, 1, 0, 1, 2, 0 };
    // Replace the second token (5 ints at 5) with two tokens, and drop the first token.
    const edits = [_]Edit{
        .{ .start = 0, .delete_count = 5, .data = &.{} },
        .{ .start = 5, .delete_count = 5, .data = &.{ 0, 3, 1, 1, 0, 0, 2, 2, 1, 0 } },
    };
    const fresh = try applyDelta(testing.allocator, &old, &edits);
    defer testing.allocator.free(fresh);
    try testing.expectEqualSlices(u32, &.{ 0, 3, 1, 1, 0, 0, 2, 2, 1, 0, 1, 0, 1, 2, 0 }, fresh);
    // Out-of-range starts clamp rather than panic.
    const wild = [_]Edit{.{ .start = 99, .delete_count = 99, .data = &.{7} }};
    const clamped = try applyDelta(testing.allocator, &old, &wild);
    defer testing.allocator.free(clamped);
    try testing.expectEqual(old.len + 1, clamped.len);
    try testing.expectEqual(@as(u32, 7), clamped[clamped.len - 1]);
}

test "readEdits and readData take the wire shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try std.json.parseFromSlice(Value, arena.allocator(), "{\"resultId\":\"2\",\"edits\":[{\"start\":5,\"deleteCount\":0,\"data\":[0,1,2,3,4]},{\"start\":0,\"deleteCount\":5}]}", .{});
    defer p.deinit();
    const edits = try readEdits(arena.allocator(), jsonrpc.getField(p.value, "edits"));
    try testing.expectEqual(@as(usize, 2), edits.len);
    try testing.expectEqual(@as(u32, 5), edits[0].start);
    try testing.expectEqual(@as(usize, 5), edits[0].data.len);
    try testing.expectEqual(@as(usize, 0), edits[1].data.len);
}
