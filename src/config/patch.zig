//! `Patch(T)` — the overlay shape of a config section, derived at comptime
//! (E1(c)), and `apply`, the merge.
//!
//! A layer file cannot be parsed straight into `Config` and diffed against
//! the default: that cannot tell "the user wrote the default value" from
//! "the user left it out". So each layer parses into a `Patch(Config)`
//! where every leaf is `?Leaf` (null = not mentioned), every nested
//! section is `?Patch(Section)`, every `Map` is a `Map` whose entries
//! merge, and slices replace whole.
//!
//! Merge rules, in one place:
//!   scalars / enums / unions / slices   → replace
//!   `.keys.*`, `.snippets.<scope>`, `.abbr` → extend by key (a `Map` of
//!                                            scalars, or a `Map` of `Map`s)
//!   `.lsp.<name>`, `.tasks`, `.formatters`, `.linters`, `.dap`
//!                                        → replace per name (a `Map` of
//!                                           structs: the entry is the unit)
//!   `Dynamic`                            → replace

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const map = @import("map.zig");
const Dynamic = @import("Dynamic.zig").Dynamic;

pub const isMap = map.isMap;

/// What one field of `T` becomes in `Patch(T)`.
pub fn PatchField(comptime F: type) type {
    @setEvalBranchQuota(100_000);
    if (F == Dynamic) return ?Dynamic;
    if (isMap(F)) return F;
    return switch (@typeInfo(F)) {
        .@"struct" => ?Patch(F),
        // An optional leaf stays as it is: `null` in a layer means "not
        // set", so an overlay cannot clear a value back to null. That
        // is the one thing this shape cannot say, and it is documented
        // on the fields it affects.
        .optional => F,
        else => ?F,
    };
}

/// A plain struct with every field of `T` in overlay form. `T` must be a
/// fixed section (a struct that is neither a `Map` nor `Dynamic`).
pub fn Patch(comptime T: type) type {
    @setEvalBranchQuota(100_000);
    const info = @typeInfo(T);
    if (info != .@"struct" or isMap(T) or T == Dynamic) @compileError("Patch expects a fixed section struct, got " ++ @typeName(T));
    const src_fields = info.@"struct".fields;
    var names: [src_fields.len][:0]const u8 = undefined;
    var types: [src_fields.len]type = undefined;
    var attrs: [src_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (src_fields, 0..) |f, i| {
        const PF = PatchField(f.type);
        const default: PF = if (isMap(f.type)) .empty else null;
        names[i] = f.name;
        types[i] = PF;
        attrs[i] = .{ .default_value_ptr = @ptrCast(&default) };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Overlay `patch` onto `dst`. `alloc` only grows map tables; every value
/// is borrowed from `patch` (the loader keeps both on one arena).
pub fn apply(alloc: Allocator, dst: *Config, patch: Patch(Config)) Allocator.Error!void {
    try applyStruct(Config, alloc, dst, patch);
}

pub fn applyStruct(comptime T: type, alloc: Allocator, dst: *T, patch: Patch(T)) Allocator.Error!void {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const F = f.type;
        const src = @field(patch, f.name);
        const target = &@field(dst, f.name);
        if (F == Dynamic) {
            if (src) |d| target.* = d;
        } else if (comptime isMap(F)) {
            try mergeMap(F, alloc, target, src);
        } else if (@typeInfo(F) == .@"struct") {
            if (src) |p| try applyStruct(F, alloc, target, p);
        } else {
            if (src) |v| target.* = v;
        }
    }
}

fn mergeMap(comptime M: type, alloc: Allocator, dst: *M, src: M) Allocator.Error!void {
    var it = src.iterator();
    while (it.next()) |e| {
        if (comptime isMap(M.Value)) {
            const gop = try dst.getOrPut(alloc, e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try mergeMap(M.Value, alloc, gop.value_ptr, e.value_ptr.*);
        } else {
            try dst.put(alloc, e.key_ptr.*, e.value_ptr.*);
        }
    }
}

/// `true` when the patch mentions nothing at all.
pub fn isEmpty(comptime T: type, patch: Patch(T)) bool {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const src = @field(patch, f.name);
        if (comptime isMap(f.type)) {
            if (src.count() != 0) return false;
        } else if (src != null) return false;
    }
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

test "Patch shapes: leaves optional, sections optional patches, maps stay maps" {
    const P = Patch(Config);
    try std.testing.expectEqual(?Patch(Config.Editor), @FieldType(P, "editor"));
    try std.testing.expectEqual(?u8, @FieldType(Patch(Config.Editor), "tab_width"));
    try std.testing.expectEqual(?Config.InputStyle, @FieldType(Patch(Config.Editor), "input_style"));
    try std.testing.expectEqual(?Config.MdEngine, @FieldType(Patch(Config.Ui), "md_preview_engine"));
    try std.testing.expectEqual(?[]const []const u8, @FieldType(Patch(Config.Ui), "plus_menu_pinned"));
    // an optional leaf keeps its own shape
    try std.testing.expectEqual(?[]const u8, @FieldType(Patch(Config.Http), "default_env"));
    // maps are maps of full values
    try std.testing.expectEqual(Config.Map(Config.LspServer), @FieldType(P, "lsp"));
    try std.testing.expectEqual(Config.Map(Config.Map([]const u8)), @FieldType(P, "snippets"));
    try std.testing.expectEqual(?Dynamic, @FieldType(P, "tools"));
    try std.testing.expectEqual(?Dynamic, @FieldType(Patch(Config.Ai), "extra"));
    const empty: P = .{};
    try std.testing.expect(isEmpty(Config, empty));
}

test "scalars replace, unmentioned fields keep the default" {
    var cfg: Config = .{};
    const p: Patch(Config) = .{ .editor = .{ .tab_width = 2, .input_style = .vim } };
    try apply(std.testing.allocator, &cfg, p);
    try std.testing.expectEqual(@as(u8, 2), cfg.editor.tab_width);
    try std.testing.expectEqual(Config.InputStyle.vim, cfg.editor.input_style);
    try std.testing.expect(cfg.editor.breadcrumb); // untouched default
    try std.testing.expectEqual(@as(u16, 0), cfg.ui.tree_width);
}

test "keys and snippets extend by key; lsp replaces per name; arrays replace whole" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var cfg: Config = .{};
    // layer 1
    var p1: Patch(Config) = .{ .keys = .{} };
    p1.keys.?.global = .empty;
    try p1.keys.?.global.put(a, "ctrl+p", "picker.files");
    try p1.keys.?.global.put(a, "ctrl+b", "tree.toggle");
    var rust_snips: Config.Map([]const u8) = .empty;
    try rust_snips.put(a, "fn", "fn $1() {}");
    try p1.snippets.put(a, "rust", rust_snips);
    try p1.lsp.put(a, "rust", .{ .cmd = "rust-analyzer", .extensions = &.{"rs"} });
    p1.ui = .{ .plus_menu_pinned = &.{ "a", "b" } };
    try apply(a, &cfg, p1);

    // layer 2
    var p2: Patch(Config) = .{ .keys = .{} };
    try p2.keys.?.global.put(a, "ctrl+p", "none");
    var rust_snips2: Config.Map([]const u8) = .empty;
    try rust_snips2.put(a, "st", "struct $1 {}");
    try p2.snippets.put(a, "rust", rust_snips2);
    try p2.lsp.put(a, "rust", .{ .extensions = &.{ "rs", "rst" } });
    p2.ui = .{ .plus_menu_pinned = &.{"c"} };
    try apply(a, &cfg, p2);

    // keys: extended, later layer wins per chord
    try std.testing.expectEqual(@as(usize, 2), cfg.keys.global.count());
    try std.testing.expectEqualStrings("none", cfg.keys.global.get("ctrl+p").?);
    try std.testing.expectEqualStrings("tree.toggle", cfg.keys.global.get("ctrl+b").?);
    // snippets: nested extend
    try std.testing.expectEqual(@as(usize, 2), cfg.snippets.get("rust").?.count());
    // lsp: replaced per name — cmd from layer 1 is gone
    try std.testing.expect(cfg.lsp.get("rust").?.cmd == null);
    try std.testing.expectEqual(@as(usize, 2), cfg.lsp.get("rust").?.extensions.len);
    // arrays: whole replace
    try std.testing.expectEqual(@as(usize, 1), cfg.ui.plus_menu_pinned.len);
    try std.testing.expectEqualStrings("c", cfg.ui.plus_menu_pinned[0]);
}

test "Dynamic subtrees replace whole" {
    var cfg: Config = .{};
    const fields = [_]Dynamic.Field{.{ .name = "x", .value = .{ .int = 1 } }};
    try apply(std.testing.allocator, &cfg, .{ .tools = .{ .object = &fields } });
    try std.testing.expectEqual(@as(i64, 1), cfg.tools.get("x").?.int);
    try apply(std.testing.allocator, &cfg, .{ .ai = .{ .extra = .{ .object = &fields } } });
    try std.testing.expectEqual(@as(i64, 1), cfg.ai.extra.get("x").?.int);
    try std.testing.expect(cfg.ai.inline_suggestions); // sibling default intact
}
