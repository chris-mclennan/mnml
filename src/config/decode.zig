//! Zoir → typed value. The bridge between `std.zon.parse` (which knows
//! structs, enums, unions, optionals, slices — but no maps and no hooks)
//! and the two shapes this schema needs on top: `Map(V)` and `Dynamic`.
//!
//! `decode(T, …)` hands any subtree the std parser can take straight to
//! `fromZoirNodeAlloc`, and walks only the ones it cannot: a struct that
//! contains a `Map` or a `Dynamic` somewhere below it, a `Map` itself,
//! or a `Dynamic`. So `.editor`, `.ui`, `.http`, … are parsed by std with
//! std's diagnostics, while `.lsp`, `.keys`, `.snippets`, `.ai` are
//! walked name by name — with per-entry isolation inside a map.
//!
//! Convention: a struct field named `extra` of type `Dynamic` collects
//! every key the struct does not declare (`.ai` uses it). Any other
//! struct rejects unknown keys.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const Dynamic = @import("Dynamic.zig").Dynamic;
const map = @import("map.zig");
const Diagnostics = @import("diag.zig").Diagnostics;

pub const Error = error{ OutOfMemory, Bad };

pub const Context = struct {
    arena: Allocator,
    ast: Ast,
    zoir: Zoir,
    diags: *Diagnostics,
    file: []const u8,

    /// Record a diagnostic at the value `node`.
    pub fn fail(ctx: *Context, node: Zoir.Node.Index, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const tok = ctx.ast.nodeMainToken(compat.zoirAstNode(node, &ctx.zoir));
        try ctx.diags.addAt(ctx.file, ctx.ast, tok, fmt, args);
    }

    /// Record a diagnostic at the field NAME of a `.name = value` pair.
    pub fn failName(ctx: *Context, value_node: Zoir.Node.Index, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try ctx.diags.addAt(ctx.file, ctx.ast, nameToken(ctx, value_node), fmt, args);
    }

    /// The identifier token of the `.name = value` pair whose value is
    /// `value_node`: two tokens back from the value (`.`, `name`, `=`).
    pub fn nameToken(ctx: *Context, value_node: Zoir.Node.Index) Ast.TokenIndex {
        const first = ctx.ast.firstToken(compat.zoirAstNode(value_node, &ctx.zoir));
        return if (first >= 2) first - 2 else first;
    }
};

/// `true` when `T` has a `Map` or a `Dynamic` somewhere inside it, i.e.
/// the std parser cannot take it.
pub fn needsWalk(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == Dynamic) return true;
    if (map.isMap(T)) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => inline for (compat.structFields(T)) |f| {
            if (needsWalk(f.type)) break true;
        } else false,
        .@"union" => inline for (compat.unionFields(T)) |f| {
            if (f.type != void and needsWalk(f.type)) break true;
        } else false,
        .optional => |o| needsWalk(o.child),
        .pointer => |p| p.size == .slice and needsWalk(p.child),
        .array => |a| needsWalk(a.child),
        else => false,
    };
}

pub fn hasExtraField(comptime T: type) bool {
    if (!@hasField(T, "extra")) return false;
    const F = @FieldType(T, "extra");
    return F == Dynamic or F == ?Dynamic;
}

pub fn decode(comptime T: type, ctx: *Context, node: Zoir.Node.Index) Error!T {
    @setEvalBranchQuota(100_000);
    if (comptime !needsWalk(T)) return decodeStd(T, ctx, node);
    if (T == Dynamic) return decodeDynamic(ctx, node);
    if (comptime map.isMap(T)) return decodeMap(T, ctx, node);
    return switch (@typeInfo(T)) {
        .optional => |o| if (compat.zoirGet(node, &ctx.zoir) == .null) null else try decode(o.child, ctx, node),
        .@"struct" => decodeStruct(T, ctx, node),
        else => @compileError("decode: no walker for " ++ @typeName(T)),
    };
}

fn decodeStd(comptime T: type, ctx: *Context, node: Zoir.Node.Index) Error!T {
    @setEvalBranchQuota(100_000);
    var problem: ?compat.ZonProblem = null;
    return compat.zonParseNode(T, ctx.arena, &ctx.ast, &ctx.zoir, node, &problem) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseZon => {
            // The message lives on the arena — nothing to free.
            if (problem) |p| {
                try ctx.diags.add(ctx.file, p.line, p.column, p.message);
            } else {
                try ctx.fail(node, "invalid value", .{});
            }
            return error.Bad;
        },
    };
}

fn decodeDynamic(ctx: *Context, node: Zoir.Node.Index) Error!Dynamic {
    const borrowed = Dynamic.fromZoir(ctx.arena, ctx.ast, ctx.zoir, node) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IntOverflow => {
            try ctx.fail(node, "integer does not fit in 64 bits", .{});
            return error.Bad;
        },
    };
    // Strings borrow `zoir.string_bytes`, which dies with the layer.
    return borrowed.dupe(ctx.arena);
}

/// Entries are decoded one by one; a bad entry is reported and skipped,
/// the rest of the map survives.
fn decodeMap(comptime M: type, ctx: *Context, node: Zoir.Node.Index) Error!M {
    var out: M = .empty;
    const lit = switch (compat.zoirGet(node, &ctx.zoir)) {
        .empty_literal => return out,
        .struct_literal => |l| l,
        else => {
            try ctx.fail(node, "expected named entries (`.{{ .name = … }}`)", .{});
            return error.Bad;
        },
    };
    for (lit.names, 0..) |name, i| {
        const val = lit.vals.at(@intCast(i));
        const v = decode(M.Value, ctx, val) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.Bad => continue,
        };
        try out.put(ctx.arena, try ctx.arena.dupe(u8, compat.zoirGet(name, &ctx.zoir)), v);
    }
    return out;
}

/// A fixed struct: every named field decoded in place, unknown names
/// rejected (or collected into `extra`). One bad field fails the struct.
fn decodeStruct(comptime T: type, ctx: *Context, node: Zoir.Node.Index) Error!T {
    @setEvalBranchQuota(100_000);
    var out: T = .{};
    const lit = switch (compat.zoirGet(node, &ctx.zoir)) {
        .empty_literal => return out,
        .struct_literal => |l| l,
        else => {
            try ctx.fail(node, "expected a struct literal", .{});
            return error.Bad;
        },
    };
    const collects_extra = comptime hasExtraField(T);
    var extra: std.ArrayList(Dynamic.Field) = .empty;
    for (lit.names, 0..) |name, i| {
        const key = compat.zoirGet(name, &ctx.zoir);
        const val = lit.vals.at(@intCast(i));
        var matched = false;
        inline for (compat.structFields(T)) |f| {
            if (!matched and std.mem.eql(u8, f.name, key)) {
                matched = true;
                @field(out, f.name) = try decode(f.type, ctx, val);
            }
        }
        if (!matched) {
            if (collects_extra) {
                try extra.append(ctx.arena, .{ .name = try ctx.arena.dupe(u8, key), .value = try decodeDynamic(ctx, val) });
            } else {
                try ctx.failName(val, "unknown field '{s}'", .{key});
                return error.Bad;
            }
        }
    }
    if (collects_extra and extra.items.len > 0) {
        // An explicit `.extra = .{…}` merges with the collected keys.
        // (`Dynamic` coerces to `?Dynamic`, so this reads both shapes.)
        const explicit: ?Dynamic = out.extra;
        if (explicit) |d| if (d == .object) try extra.appendSlice(ctx.arena, d.object);
        out.extra = .{ .object = try extra.toOwnedSlice(ctx.arena) };
    }
    return out;
}

// ─── tests ───────────────────────────────────────────────────────────────

const Config = @import("Config.zig");
const Patch = @import("patch.zig").Patch;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    ast: Ast,
    zoir: Zoir,
    diags: Diagnostics,
    ctx: Context,

    fn init(src: [:0]const u8) !*Fixture {
        const f = try std.testing.allocator.create(Fixture);
        errdefer std.testing.allocator.destroy(f);
        f.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        const arena = f.arena_state.allocator();
        f.ast = try compat.parseZonAst(arena, src);
        f.zoir = try std.zig.ZonGen.generate(arena, f.ast, .{});
        try std.testing.expect(!f.zoir.hasCompileErrors());
        f.diags = Diagnostics.init(arena);
        f.ctx = .{ .arena = arena, .ast = f.ast, .zoir = f.zoir, .diags = &f.diags, .file = "t.zon" };
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        std.testing.allocator.destroy(f);
    }

    fn rendered(f: *Fixture) ![]u8 {
        return f.diags.render(std.testing.allocator);
    }
};

test "needsWalk is precise" {
    try std.testing.expect(!needsWalk(Config.Editor));
    try std.testing.expect(!needsWalk(Patch(Config.Ui)));
    try std.testing.expect(needsWalk(Config.LspServer));
    try std.testing.expect(needsWalk(Config.Keys));
    try std.testing.expect(needsWalk(Patch(Config)));
    try std.testing.expect(needsWalk(Config.Map([]const u8)));
    try std.testing.expect(hasExtraField(Config.Ai));
    try std.testing.expect(hasExtraField(Patch(Config.Ai)));
    try std.testing.expect(!hasExtraField(Config.Ui));
}

test "a fixed section goes through std with its diagnostics" {
    const f = try Fixture.init(".{ .tab_width = 2, .input_style = .vim, .scroll_accel = .fast }");
    defer f.deinit();
    const p = try decode(Patch(Config.Editor), &f.ctx, .root);
    try std.testing.expectEqual(@as(?u8, 2), p.tab_width);
    try std.testing.expectEqual(@as(?Config.InputStyle, .vim), p.input_style);
    try std.testing.expect(p.breadcrumb == null);
}

test "a typo in a fixed section is a located diagnostic" {
    const f = try Fixture.init(
        \\.{
        \\    .tab_width = 2,
        \\    .tab_widht = 8,
        \\}
    );
    defer f.deinit();
    try std.testing.expectError(error.Bad, decode(Patch(Config.Editor), &f.ctx, .root));
    const text = try f.rendered();
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "t.zon:3:6: "));
    try std.testing.expect(std.mem.indexOf(u8, text, "tab_widht") != null);
}

test "a map decodes entry by entry and isolates a bad one" {
    const f = try Fixture.init(
        \\.{
        \\    .rust = .{ .cmd = "rust-analyzer", .extensions = .{ "rs" }, .settings = .{ .cargo = .{ .allFeatures = true } } },
        \\    .bad = .{ .cmd = 5 },
        \\    .zig = .{ .cmd = "zls" },
        \\}
    );
    defer f.deinit();
    const m = try decode(Config.Map(Config.LspServer), &f.ctx, .root);
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expectEqualStrings("rust-analyzer", m.get("rust").?.cmd.?);
    try std.testing.expectEqualStrings("zls", m.get("zig").?.cmd.?);
    try std.testing.expect(m.get("rust").?.settings.get("cargo").?.get("allFeatures").?.bool);
    try std.testing.expectEqual(@as(usize, 1), f.diags.count());
    try std.testing.expectEqual(@as(u32, 3), f.diags.items.items[0].line);
}

test "unknown keys land in .extra and named ones are typed" {
    const f = try Fixture.init(".{ .backend = .api, .anything = .{ .goes = \"here\" }, .routing = .{ .codex = .{ .backend = .off } } }");
    defer f.deinit();
    const ai = try decode(Patch(Config.Ai), &f.ctx, .root);
    try std.testing.expectEqual(@as(?Config.AiBackend, .api), ai.backend);
    try std.testing.expectEqual(@as(?Config.AiBackend, .off), ai.routing.?.codex.?.backend);
    try std.testing.expectEqualStrings("here", ai.extra.?.get("anything").?.get("goes").?.string);
}

test "keys are a map form: chord → command, dupes rejected by ZonGen" {
    const f = try Fixture.init(".{ .global = .{ .@\"ctrl+p\" = \"picker.files\", .@\"space f f\" = \"none\" } }");
    defer f.deinit();
    const k = try decode(Patch(Config.Keys), &f.ctx, .root);
    try std.testing.expectEqualStrings("picker.files", k.global.get("ctrl+p").?);
    try std.testing.expectEqualStrings("none", k.global.get("space f f").?);
    try std.testing.expectEqual(@as(usize, 0), k.vim.count());

    const src: [:0]const u8 = ".{ .global = .{ .a = \"x\", .a = \"y\" } }";
    var ast = try compat.parseZonAst(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);
    var zoir = try std.zig.ZonGen.generate(std.testing.allocator, ast, .{});
    defer zoir.deinit(std.testing.allocator);
    try std.testing.expect(zoir.hasCompileErrors());
}

test "tagged unions: md engine and marketplace sources" {
    const f = try Fixture.init(".{ .md_preview_engine = .{ .custom = \"glow -s dark\" }, .picker_position = .top }");
    defer f.deinit();
    const ui = try decode(Patch(Config.Ui), &f.ctx, .root);
    try std.testing.expectEqualStrings("glow -s dark", ui.md_preview_engine.?.custom);
    try std.testing.expectEqual(@as(?Config.PickerPosition, .top), ui.picker_position);

    const g = try Fixture.init(".{ .sources = .{ .{ .crates_keyword = .{ .id = \"c\", .keyword = \"k\" } }, .{ .github_monorepo_apps = .{ .id = \"m\", .repo = \"r\", .apps_dir = \"apps\" } } } }");
    defer g.deinit();
    const mk = try decode(Patch(Config.Marketplace), &g.ctx, .root);
    try std.testing.expectEqual(@as(usize, 2), mk.sources.?.len);
    try std.testing.expectEqualStrings("apps", mk.sources.?[1].github_monorepo_apps.apps_dir);
}
