//! `Dynamic` — a ZON value tree for the subtrees mnml forwards verbatim
//! (`lsp.<name>.settings`, `dap.<name>.launch`, `.ai.extra`, `.tools`).
//!
//! It is built from Zoir nodes and only ever read back through `toJson`,
//! which is how those subtrees reach a language server / debug adapter /
//! integration. There is no schema here on purpose: the point is that
//! mnml never has to know what a server's `initializationOptions` look
//! like. Values are borrowed from the arena the tree was built on.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;

pub const Dynamic = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    enum_literal: []const u8,
    array: []const Dynamic,
    object: []const Field,

    pub const Field = struct { name: []const u8, value: Dynamic };

    /// `.{}` — the value an omitted subtree carries.
    pub const empty_object: Dynamic = .{ .object = &.{} };

    pub const FromZoirError = error{ OutOfMemory, IntOverflow };

    /// Build the tree under `node`. Everything is allocated on `arena`
    /// (strings are borrowed from `zoir` / `ast`, which the caller keeps
    /// alive as long as the tree, or dupes on the same arena — see
    /// `load.zig`). An integer that does not fit `i64` is the one
    /// failure that is not OOM.
    pub fn fromZoir(arena: Allocator, ast: Ast, zoir: Zoir, node: Zoir.Node.Index) FromZoirError!Dynamic {
        return switch (compat.zoirGet(node, &zoir)) {
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            .null => .null,
            .pos_inf => .{ .float = std.math.inf(f64) },
            .neg_inf => .{ .float = -std.math.inf(f64) },
            .nan => .{ .float = std.math.nan(f64) },
            .int_literal => |int| switch (int) {
                .small => |v| .{ .int = v },
                .big => |big| .{ .int = big.toInt(i64) catch return error.IntOverflow },
            },
            .float_literal => |f| .{ .float = @floatCast(f) },
            .char_literal => |c| .{ .int = c },
            .enum_literal => |s| .{ .enum_literal = compat.zoirGet(s, &zoir) },
            .string_literal => |s| .{ .string = s },
            .empty_literal => empty_object,
            .array_literal => |range| blk: {
                const items = try arena.alloc(Dynamic, range.len);
                for (items, 0..) |*item, i| item.* = try fromZoir(arena, ast, zoir, range.at(@intCast(i)));
                break :blk .{ .array = items };
            },
            .struct_literal => |lit| blk: {
                const fields = try arena.alloc(Field, lit.names.len);
                for (fields, lit.names, 0..) |*f, name, i| {
                    f.* = .{ .name = compat.zoirGet(name, &zoir), .value = try fromZoir(arena, ast, zoir, lit.vals.at(@intCast(i))) };
                }
                break :blk .{ .object = fields };
            },
        };
    }

    /// Look a field up on an object. `null` for a non-object or a
    /// missing name.
    pub fn get(self: Dynamic, name: []const u8) ?Dynamic {
        const fields = switch (self) {
            .object => |f| f,
            else => return null,
        };
        for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    pub fn isEmpty(self: Dynamic) bool {
        return switch (self) {
            .object => |f| f.len == 0,
            .array => |a| a.len == 0,
            else => false,
        };
    }

    /// Write the tree as JSON. Enum literals become strings (`.foo` →
    /// `"foo"`) because that is what every consumer on the other side
    /// of a JSON-RPC pipe expects; non-finite floats become `null`
    /// (JSON has no spelling for them).
    pub fn toJson(self: Dynamic, out: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            .null => try out.write(null),
            .bool => |b| try out.write(b),
            .int => |i| try out.write(i),
            .float => |f| if (std.math.isFinite(f)) try out.write(f) else try out.write(null),
            .string, .enum_literal => |s| try out.write(s),
            .array => |items| {
                try out.beginArray();
                for (items) |item| try item.toJson(out);
                try out.endArray();
            },
            .object => |fields| {
                try out.beginObject();
                for (fields) |f| {
                    try out.objectField(f.name);
                    try f.value.toJson(out);
                }
                try out.endObject();
            },
        }
    }

    /// Deep copy onto `arena` — strings included, so the copy outlives
    /// whatever the original borrowed from.
    pub fn dupe(self: Dynamic, arena: Allocator) Allocator.Error!Dynamic {
        return switch (self) {
            .null, .bool, .int, .float => self,
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .enum_literal => |s| .{ .enum_literal = try arena.dupe(u8, s) },
            .array => |items| blk: {
                const copy = try arena.alloc(Dynamic, items.len);
                for (copy, items) |*dst, src| dst.* = try src.dupe(arena);
                break :blk .{ .array = copy };
            },
            .object => |fields| blk: {
                const copy = try arena.alloc(Field, fields.len);
                for (copy, fields) |*dst, src| dst.* = .{ .name = try arena.dupe(u8, src.name), .value = try src.value.dupe(arena) };
                break :blk .{ .object = copy };
            },
        };
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

fn parseToDynamic(arena: Allocator, src: [:0]const u8) !Dynamic {
    var ast = try compat.parseZonAst(arena, src);
    defer ast.deinit(arena);
    var zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    defer zoir.deinit(arena);
    try std.testing.expect(!zoir.hasCompileErrors());
    // Strings borrow from `zoir.string_bytes`, which we are about to
    // free — dupe the tree first, exactly as the loader does.
    const borrowed = try Dynamic.fromZoir(arena, ast, zoir, .root);
    return borrowed.dupe(arena);
}

fn jsonOf(gpa: Allocator, value: Dynamic) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try value.toJson(&s);
    return out.toOwnedSlice();
}

test "every ZON value kind round-trips to JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseToDynamic(arena,
        \\.{
        \\    .flag = true,
        \\    .n = 42,
        \\    .neg = -7,
        \\    .f = 1.5,
        \\    .s = "hi\n",
        \\    .e = .verbose,
        \\    .nothing = null,
        \\    .list = .{ 1, "two", .{ .three = 3 } },
        \\    .empty = .{},
        \\    .ch = 'a',
        \\}
    );
    const json = try jsonOf(std.testing.allocator, v);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"flag":true,"n":42,"neg":-7,"f":1.5,"s":"hi\n","e":"verbose","nothing":null,"list":[1,"two",{"three":3}],"empty":{},"ch":97}
    , json);
}

test "get walks an object and refuses everything else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try parseToDynamic(arena, ".{ .a = .{ .b = 2 } }");
    try std.testing.expectEqual(@as(i64, 2), v.get("a").?.get("b").?.int);
    try std.testing.expect(v.get("zzz") == null);
    try std.testing.expect(v.get("a").?.get("b").?.get("anything") == null);
    try std.testing.expect(Dynamic.empty_object.isEmpty());
    try std.testing.expect(!v.isEmpty());
}

test "an integer beyond i64 is a reported failure, not a wrap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.IntOverflow, parseToDynamic(arena_state.allocator(), ".{ .big = 99999999999999999999999 }"));
}

test "non-finite floats become JSON null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const v = try parseToDynamic(arena_state.allocator(), ".{ .a = inf, .b = -inf, .c = nan }");
    const json = try jsonOf(std.testing.allocator, v);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"a\":null,\"b\":null,\"c\":null}", json);
}
