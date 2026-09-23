//! The fields a ZON text names that a type does not have. `std.zon`
//! parses with `ignore_unknown_fields` for manifests — a file written for
//! a newer mnml must still load — which also means a typo'd field
//! (`.commmands`) loads as a valid manifest with that field silently
//! empty. This walk finds those names so the loader can say so: it
//! follows the type through structs, tagged unions, optionals, slices
//! and arrays, and reports each unknown name by its path
//! (`commands[1].titel`). Text that does not parse reports nothing; the
//! parse that loads the manifest owns that error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Zoir = std.zig.Zoir;

/// The unknown field paths in `text` read as a `T`, on `arena`.
pub fn unknown(comptime T: type, arena: Allocator, text: [:0]const u8) Allocator.Error![]const []const u8 {
    const ast = try std.zig.Ast.parse(arena, text, .zon);
    if (ast.errors.len > 0) return &.{};
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = false });
    if (zoir.hasCompileErrors()) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    try walk(T, arena, zoir, .root, "", &out);
    return out.items;
}

fn walk(comptime T: type, arena: Allocator, zoir: Zoir, node: Zoir.Node.Index, path: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    switch (@typeInfo(T)) {
        .optional => |o| return walk(o.child, arena, zoir, node, path, out),
        .pointer => |p| {
            if (p.size != .slice or p.child == u8) return;
            return walkElems(p.child, arena, zoir, node, path, out);
        },
        .array => |a| {
            if (a.child == u8) return;
            return walkElems(a.child, arena, zoir, node, path, out);
        },
        .@"struct", .@"union" => {
            const lit = switch (node.get(zoir)) {
                .struct_literal => |l| l,
                else => return,
            };
            const fields = switch (@typeInfo(T)) {
                .@"struct" => |s| s.fields,
                .@"union" => |u| u.fields,
                else => unreachable,
            };
            for (lit.names, 0..) |name_idx, i| {
                const name = name_idx.get(zoir);
                const val = lit.vals.at(@intCast(i));
                const sub = if (path.len == 0) name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, name });
                const known = inline for (fields) |f| {
                    if (std.mem.eql(u8, f.name, name)) {
                        try walk(f.type, arena, zoir, val, sub, out);
                        break true;
                    }
                } else false;
                if (!known) try out.append(arena, try arena.dupe(u8, sub));
            }
        },
        else => {},
    }
}

fn walkElems(comptime E: type, arena: Allocator, zoir: Zoir, node: Zoir.Node.Index, path: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    const range = switch (node.get(zoir)) {
        .array_literal => |r| r,
        else => return,
    };
    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        const sub = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ path, i });
        try walk(E, arena, zoir, range.at(i), sub, out);
    }
}

test "unknown fields are named by path; known ones, and text that does not parse, report nothing" {
    const Inner = struct { title: []const u8 = "", keys: []const []const u8 = &.{} };
    const Kind = union(enum) { a: u32, b: Inner };
    const T = struct {
        name: []const u8 = "",
        commands: []const Inner = &.{},
        chip: ?Inner = null,
        kind: Kind = .{ .a = 0 },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try unknown(T, arena,
        \\.{
        \\    .name = "x",
        \\    .commmands = .{ "user.a" },
        \\    .commands = .{ .{ .title = "A" }, .{ .titel = "B", .keys = .{ "ctrl+b" } } },
        \\    .chip = .{ .glyph = "g" },
        \\    .kind = .{ .b = .{ .extra = 1 } },
        \\}
    );
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("commmands", got[0]);
    try std.testing.expectEqualStrings("commands[1].titel", got[1]);
    try std.testing.expectEqualStrings("chip.glyph", got[2]);
    try std.testing.expectEqualStrings("kind.b.extra", got[3]);
    try std.testing.expectEqual(@as(usize, 0), (try unknown(T, arena, ".{ .name = \"x\", .commands = .{} }")).len);
    try std.testing.expectEqual(@as(usize, 0), (try unknown(T, arena, ".{ .name = ")).len);
}
