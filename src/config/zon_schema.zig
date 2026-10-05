//! What a `.zon` field *is*, so the ZON view pane can put the right
//! widget on it.
//!
//! Two sources. A **schema** — the typed shape a known file decodes
//! into (`Config` for `config.zon`, the session's `Saved`, an
//! integration `Manifest`, a theme `Source`) — is walked by key path at
//! comptime-generic call sites: a struct by field name, a `Map` by any
//! name, a slice by `[i]`, a union by its tag. `docs/CONFIG.md`'s
//! per-key comments are the config's hover copy. A file with no schema
//! (or a `Dynamic` subtree of one) gets its widget **inferred from the
//! literal**: `true` is a bool, `.tag` an enum with one known choice,
//! a one-field struct is union-shaped, and so on.
//!
//! `Widget` is the table the pane draws from: one row shape per kind.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const map = @import("map.zig");
const Dynamic = @import("Dynamic.zig").Dynamic;
const zon_tree = @import("zon_tree.zig");
const Node = zon_tree.Node;

/// The known file shapes.
pub const Schema = enum {
    config,
    session,
    manifest,
    theme,
    none,

    pub fn label(s: Schema) []const u8 {
        return switch (s) {
            .config => "mnml config",
            .session => "mnml session",
            .manifest => "integration manifest",
            .theme => "theme",
            .none => "zon",
        };
    }
};

/// Which widget a row gets. The design's table, one variant each.
pub const Widget = enum {
    /// Enter / Space / click toggles.
    bool,
    /// `←→` cycle, Enter opens the picker.
    @"enum",
    /// `←→` step, Enter types.
    int,
    float,
    /// Inline text field.
    string,
    /// `+` add, `x` remove, `J` / `K` reorder.
    list,
    /// Folds.
    @"struct",
    /// `null` with `set…`.
    optional_null,
    /// A picker of tags; the payload widget follows the choice.
    @"union",
    /// Unknown-schema one-field struct: the field NAME is editable.
    union_shaped,
    /// Anything else (a char literal, a `.{}` of unknown shape).
    literal,

    pub fn label(w: Widget) []const u8 {
        return switch (w) {
            .bool => "bool",
            .@"enum" => "enum",
            .int => "int",
            .float => "float",
            .string => "string",
            .list => "list",
            .@"struct" => "struct",
            .optional_null => "optional",
            .@"union" => "union",
            .union_shaped => "union?",
            .literal => "literal",
        };
    }
};

/// What the schema (or the literal) says about one field.
pub const Field = struct {
    widget: Widget,
    /// The type is `?T`: `null` is a valid value (`n` clears it).
    optional: bool = false,
    /// Enum tags, or union tags.
    tags: []const []const u8 = &.{},
    /// Per union tag: the literal a swap to it writes (`.tag`, or
    /// `.{ .tag = <default payload> }`).
    tag_literals: []const []const u8 = &.{},
    /// An unknown-schema enum: any tag may be typed, not only `tags`.
    free_enum: bool = false,
    /// The literal `set…` writes on a `null`, and `+` appends to a list.
    default_literal: []const u8 = "null",
    elem_default: []const u8 = "\"\"",
    /// Integers: the type's range, for the step and the typed check.
    int_min: i128 = std.math.minInt(i64),
    int_max: i128 = std.math.maxInt(i64),
    /// A one-line description: the type, and the doc when there is one.
    type_name: []const u8 = "",
    /// Where the schema stopped knowing: a `Dynamic` subtree, or no
    /// schema at all — the widget came from the literal.
    inferred: bool = false,
};

// ─── detection ───────────────────────────────────────────────────────────

/// Which schema `path` (absolute or not) with `root_names` (the file's
/// top-level fields) decodes into. The name decides first
/// (`config.zon`, `session.zon`, `<data root>/integrations/*.zon`,
/// `themes/*.zon`); the shape confirms or, for an unnamed file, decides.
pub fn detect(path: []const u8, root_names: []const []const u8) Schema {
    const base = std.fs.path.basename(path);
    const dir = std.fs.path.basename(std.fs.path.dirname(path) orelse "");
    if (std.mem.eql(u8, base, "config.zon")) return .config;
    if (std.mem.eql(u8, base, "session.zon")) return .session;
    if (std.mem.eql(u8, dir, "integrations") and hasAll(root_names, &.{ "id", "binary" })) return .manifest;
    if (std.mem.eql(u8, dir, "themes") and hasAll(root_names, &.{"base_30"})) return .theme;
    // By shape alone.
    if (hasAll(root_names, &.{ "id", "binary", "label" })) return .manifest;
    if (hasAll(root_names, &.{ "base_30", "name" })) return .theme;
    if (hasAll(root_names, &.{ "version", "panes", "tabs" })) return .session;
    var config_hits: usize = 0;
    for (root_names) |n| {
        inline for (compat.structFields(Config)) |f| if (std.mem.eql(u8, f.name, n)) {
            config_hits += 1;
        };
    }
    if (root_names.len > 0 and config_hits == root_names.len) return .config;
    return .none;
}

fn hasAll(names: []const []const u8, want: []const []const u8) bool {
    for (want) |w| {
        var found = false;
        for (names) |n| if (std.mem.eql(u8, n, w)) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}

// ─── the typed walk ──────────────────────────────────────────────────────

const SessionSaved = @import("../app/session.zig").Saved;
const Manifest = @import("../bridge/manifest.zig").Manifest;
const ThemeSource = @import("themes").Source;

/// The schema's word on `key_path`, or null when the schema does not
/// reach it (no schema, a `Dynamic` subtree, an unknown key) — then
/// `infer` from the literal.
pub fn lookup(schema: Schema, key_path: []const []const u8) ?Field {
    @setEvalBranchQuota(1_000_000);
    return switch (schema) {
        .config => lookupIn(Config, key_path),
        .session => lookupIn(SessionSaved, key_path),
        .manifest => lookupIn(Manifest, key_path),
        .theme => lookupIn(ThemeSource, key_path),
        .none => null,
    };
}

fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child != u8,
        .array => true,
        else => false,
    };
}

fn ElemOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        .array => |a| a.child,
        else => unreachable,
    };
}

fn lookupIn(comptime T: type, key_path: []const []const u8) ?Field {
    @setEvalBranchQuota(1_000_000);
    if (key_path.len == 0) return describe(T);
    const U = Unwrapped(T);
    if (U == Dynamic) return null;
    if (comptime map.isMap(U)) return lookupIn(U.Value, key_path[1..]);
    if (comptime isString(U)) return null;
    if (comptime isSlice(U)) {
        if (!zon_tree.isIndexKey(key_path[0])) return null;
        return lookupIn(ElemOf(U), key_path[1..]);
    }
    switch (@typeInfo(U)) {
        .@"struct" => {
            inline for (compat.structFields(U)) |f| {
                if (std.mem.eql(u8, f.name, key_path[0])) return lookupIn(f.type, key_path[1..]);
            }
            return null;
        },
        .@"union" => {
            inline for (compat.unionFields(U)) |f| {
                if (std.mem.eql(u8, f.name, key_path[0])) return lookupIn(f.type, key_path[1..]);
            }
            return null;
        },
        else => return null,
    }
}

fn describe(comptime T: type) ?Field {
    @setEvalBranchQuota(1_000_000);
    const optional = @typeInfo(T) == .optional;
    const U = Unwrapped(T);
    if (U == Dynamic) return null;
    if (comptime map.isMap(U)) return .{ .widget = .@"struct", .optional = optional, .type_name = "map", .default_literal = ".{}" };
    if (U == bool) return .{ .widget = .bool, .optional = optional, .type_name = "bool", .default_literal = "false" };
    if (comptime isString(U)) return .{ .widget = .string, .optional = optional, .type_name = "string", .default_literal = "\"\"" };
    if (comptime isSlice(U)) return .{
        .widget = .list,
        .optional = optional,
        .type_name = comptime ("list of " ++ typeWord(ElemOf(U))),
        .default_literal = ".{}",
        .elem_default = comptime defaultLiteral(ElemOf(U)),
    };
    return switch (@typeInfo(U)) {
        .int => .{
            .widget = .int,
            .optional = optional,
            .type_name = @typeName(U),
            .default_literal = "0",
            .int_min = std.math.minInt(U),
            .int_max = std.math.maxInt(U),
            .elem_default = "0",
        },
        .float => .{ .widget = .float, .optional = optional, .type_name = @typeName(U), .default_literal = "0.0" },
        .@"enum" => .{
            .widget = .@"enum",
            .optional = optional,
            .tags = comptime fieldNames(compat.enumFields(U)),
            .type_name = "enum",
            .default_literal = "." ++ compat.enumFields(U)[0].name,
        },
        .@"union" => .{
            .widget = .@"union",
            .optional = optional,
            .tags = comptime fieldNames(compat.unionFields(U)),
            .tag_literals = comptime unionLiterals(U),
            .type_name = "union",
            .default_literal = comptime defaultLiteral(U),
        },
        .@"struct" => .{ .widget = .@"struct", .optional = optional, .type_name = "struct", .default_literal = ".{}" },
        else => null,
    };
}

fn typeWord(comptime T: type) []const u8 {
    const U = Unwrapped(T);
    if (U == bool) return "bool";
    if (comptime isString(U)) return "strings";
    if (comptime isSlice(U)) return "lists";
    return switch (@typeInfo(U)) {
        .int => "ints",
        .float => "floats",
        .@"enum" => "enums",
        .@"union" => "unions",
        .@"struct" => "structs",
        else => "values",
    };
}

fn fieldNames(comptime fields: anytype) []const []const u8 {
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = f.name;
    const frozen = out;
    return &frozen;
}

/// The literal a fresh value of `T` is written as.
fn defaultLiteral(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const U = Unwrapped(T);
    if (@typeInfo(T) == .optional) return "null";
    if (U == Dynamic) return ".{}";
    if (comptime map.isMap(U)) return ".{}";
    if (U == bool) return "false";
    if (comptime isString(U)) return "\"\"";
    if (comptime isSlice(U)) return ".{}";
    return switch (@typeInfo(U)) {
        .int => "0",
        .float => "0.0",
        .@"enum" => "." ++ compat.enumFields(U)[0].name,
        .@"union" => if (compat.unionFields(U)[0].type == void) "." ++ compat.unionFields(U)[0].name else ".{ ." ++ compat.unionFields(U)[0].name ++ " = " ++ defaultLiteral(compat.unionFields(U)[0].type) ++ " }",
        .@"struct" => ".{}",
        else => "null",
    };
}

fn unionLiterals(comptime U: type) []const []const u8 {
    const fields = compat.unionFields(U);
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = if (f.type == void) "." ++ f.name else ".{ ." ++ f.name ++ " = " ++ defaultLiteral(f.type) ++ " }";
    const frozen = out;
    return &frozen;
}

// ─── inference ───────────────────────────────────────────────────────────

/// The widget a literal implies when no schema reaches it. `tag` is
/// the enum literal's name (for the one-choice enum); `child_count`
/// the struct's field count (one field → union-shaped).
pub fn infer(alloc: Allocator, node: *const Node) Allocator.Error!Field {
    var f: Field = .{ .widget = .literal, .inferred = true, .type_name = node.kind.label() };
    switch (node.kind) {
        .bool => f.widget = .bool,
        .int => {
            f.widget = .int;
            f.default_literal = "0";
        },
        .float => f.widget = .float,
        .string => f.widget = .string,
        .enum_lit => {
            f.widget = .@"enum";
            f.free_enum = true;
            const tags = try alloc.alloc([]const u8, 1);
            tags[0] = node.text[1..];
            f.tags = tags;
        },
        .null => {
            f.widget = .optional_null;
            f.optional = true;
            f.default_literal = "\"\"";
        },
        .list => {
            f.widget = .list;
            // `+` copies the last element's shape.
            f.elem_default = "\"\"";
        },
        .@"struct" => {
            f.widget = if (node.children.len == 1) .union_shaped else .@"struct";
            if (f.widget == .union_shaped) f.type_name = "one-field struct";
        },
        .empty => {
            f.widget = .@"struct";
            f.type_name = ".{} (empty)";
        },
        .char => f.widget = .literal,
    }
    return f;
}

/// The field for a node: the schema's word, made concrete by the
/// literal (a `null` on an optional is the `set…` row; a bare `.tag`
/// on a union is still the union), else inferred.
pub fn fieldFor(alloc: Allocator, schema: Schema, key_path: []const []const u8, node: *const Node) Allocator.Error!Field {
    if (lookup(schema, key_path)) |f| {
        var out = f;
        if (node.kind == .null and (f.optional or f.widget != .optional_null)) {
            out.widget = .optional_null;
            out.optional = true;
            // What `set…` writes: the non-null default.
            out.default_literal = f.default_literal;
        }
        // A schema list that the file wrote as `.{}` stays a list.
        if (node.kind == .empty and f.widget == .list) out.widget = .list;
        return out;
    }
    return infer(alloc, node);
}

// ─── docs ────────────────────────────────────────────────────────────────

/// `docs/CONFIG.md`'s per-key comments, keyed by dotted path
/// (`ui.theme`, `ui.section_side.explorer`). Built once per pane from
/// the embedded markdown: the ```zon block is scanned line by line,
/// `.name = .{` opens a section and `}` closes one, and the `// …`
/// after a value is the line.
pub const Docs = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn get(d: *const Docs, path: []const u8) ?[]const u8 {
        return d.map.get(path);
    }
};

/// docs/CONFIG.md, embedded — the Settings rows read their comments
/// from it and `app/docs.zig` opens its sections as previews.
pub const config_md = @embedFile("config_md");

pub fn configDocs(alloc: Allocator) Allocator.Error!Docs {
    return parseDocs(alloc, config_md);
}

pub fn parseDocs(alloc: Allocator, md: []const u8) Allocator.Error!Docs {
    var docs: Docs = .{};
    const open = std.mem.indexOf(u8, md, "```zon\n") orelse return docs;
    const body_start = open + "```zon\n".len;
    const close = std.mem.indexOfPos(u8, md, body_start, "\n```") orelse return docs;
    const body = md[body_start..close];

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        // A pure comment line documents nothing by key.
        if (std.mem.startsWith(u8, line, "//")) continue;
        var code = line;
        var comment: ?[]const u8 = null;
        if (std.mem.indexOf(u8, line, " // ")) |c| {
            code = std.mem.trimEnd(u8, line[0..c], " \t");
            comment = std.mem.trim(u8, line[c + 4 ..], " \t");
        }
        if (std.mem.startsWith(u8, code, ".") and std.mem.indexOf(u8, code, " = ") != null) {
            const eq = std.mem.indexOf(u8, code, " = ").?;
            var name = code[1..eq];
            if (name.len >= 3 and name[0] == '@' and name[1] == '"') name = name[2 .. name.len - 1];
            const value = code[eq + 3 ..];
            if (comment) |c| {
                const path = try joinPath(alloc, stack.items, name);
                try docs.map.put(alloc, path, try alloc.dupe(u8, c));
            }
            // Opens a section when the value is `.{` left open on this line.
            const opens = std.mem.count(u8, value, "{");
            const closes = std.mem.count(u8, value, "}");
            if (opens > closes) try stack.append(alloc, name);
            continue;
        }
        // `}` / `},` closes the innermost section.
        if (std.mem.startsWith(u8, code, "}")) {
            if (stack.items.len > 0) _ = stack.pop();
        }
    }
    return docs;
}

fn joinPath(alloc: Allocator, parts: []const []const u8, last: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| {
        try out.appendSlice(alloc, p);
        try out.append(alloc, '.');
    }
    try out.appendSlice(alloc, last);
    return out.toOwnedSlice(alloc);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn expectTags(f: Field, want: []const []const u8) !void {
    try t.expectEqual(want.len, f.tags.len);
    for (want, f.tags) |w, g| try t.expectEqualStrings(w, g);
}

test "detect: by name, by folder, by shape" {
    try t.expectEqual(Schema.config, detect("/home/u/.config/mnml/config.zon", &.{}));
    try t.expectEqual(Schema.session, detect("/ws/.mnml/session.zon", &.{}));
    try t.expectEqual(Schema.manifest, detect("/home/u/.config/mnml/integrations/jira.zon", &.{ "id", "binary", "label" }));
    try t.expectEqual(Schema.theme, detect("/src/themes/onedark.zon", &.{ "name", "base_30" }));
    try t.expectEqual(Schema.config, detect("/tmp/anything.zon", &.{ "editor", "ui" }));
    try t.expectEqual(Schema.none, detect("/tmp/anything.zon", &.{ "editor", "flavour" }));
    try t.expectEqual(Schema.none, detect("/tmp/x.zon", &.{}));
    try t.expectEqual(Schema.manifest, detect("/tmp/x.zon", &.{ "id", "label", "binary", "mode" }));
    try t.expectEqual(Schema.session, detect("/tmp/x.zon", &.{ "version", "panes", "tabs" }));
    try t.expectEqual(Schema.theme, detect("/tmp/x.zon", &.{ "name", "kind", "base_30", "base_16" }));
}

test "the config schema names every widget kind" {
    const bool_f = lookup(.config, &.{ "editor", "breadcrumb" }).?;
    try t.expectEqual(Widget.bool, bool_f.widget);
    try t.expectEqualStrings("false", bool_f.default_literal);

    const style = lookup(.config, &.{ "editor", "input_style" }).?;
    try t.expectEqual(Widget.@"enum", style.widget);
    try expectTags(style, &.{ "vim", "standard" });
    try t.expectEqualStrings(".vim", style.default_literal);

    const tab = lookup(.config, &.{ "editor", "tab_width" }).?;
    try t.expectEqual(Widget.int, tab.widget);
    try t.expectEqual(@as(i128, 0), tab.int_min);
    try t.expectEqual(@as(i128, 255), tab.int_max);
    try t.expectEqualStrings("u8", tab.type_name);

    // The highlighting size limit: the settings overlay offers five
    // sizes, the ZON view types the byte count itself.
    const hl = lookup(.config, &.{ "editor", "highlight_max_bytes" }).?;
    try t.expectEqual(Widget.int, hl.widget);
    try t.expectEqual(@as(i128, 0), hl.int_min);
    try t.expectEqual(@as(i128, std.math.maxInt(u64)), hl.int_max);
    try t.expectEqualStrings("u64", hl.type_name);

    const theme = lookup(.config, &.{ "ui", "theme" }).?;
    try t.expectEqual(Widget.string, theme.widget);

    // a nested union: the engine, and the payload under its tag
    const engine = lookup(.config, &.{ "ui", "md_preview_engine" }).?;
    try t.expectEqual(Widget.@"union", engine.widget);
    try expectTags(engine, &.{ "builtin", "glow", "pandoc", "custom" });
    try t.expectEqualStrings(".builtin", engine.tag_literals[0]);
    try t.expectEqualStrings(".{ .custom = \"\" }", engine.tag_literals[3]);
    try t.expectEqual(Widget.string, lookup(.config, &.{ "ui", "md_preview_engine", "custom" }).?.widget);

    // an optional enum, an optional string
    const ws = lookup(.config, &.{ "startup", "default_workspace" }).?;
    try t.expectEqual(Widget.string, ws.widget);
    try t.expect(ws.optional);
    const side = lookup(.config, &.{ "ui", "section_side", "git" }).?;
    try t.expectEqual(Widget.@"enum", side.widget);
    try t.expect(side.optional);
    // // changed (bottom-dock): the dock is a third side.
    try expectTags(side, &.{ "left", "right", "bottom" });

    // a list of strings, a list of structs and the struct inside
    const kw = lookup(.config, &.{ "ui", "todo_keywords" }).?;
    try t.expectEqual(Widget.list, kw.widget);
    try t.expectEqualStrings("\"\"", kw.elem_default);
    const wss = lookup(.config, &.{"workspaces"}).?;
    try t.expectEqual(Widget.list, wss.widget);
    try t.expectEqualStrings(".{}", wss.elem_default);
    try t.expectEqualStrings("list of structs", wss.type_name);
    try t.expectEqual(Widget.@"struct", lookup(.config, &.{ "workspaces", "[3]" }).?.widget);
    try t.expectEqual(Widget.string, lookup(.config, &.{ "workspaces", "[0]", "name" }).?.widget);
    try t.expect(lookup(.config, &.{ "workspaces", "name" }) == null);

    // a map: any key, the value's type
    try t.expectEqual(Widget.@"struct", lookup(.config, &.{"lsp"}).?.widget);
    try t.expectEqual(Widget.string, lookup(.config, &.{ "lsp", "rust", "cmd" }).?.widget);
    try t.expectEqual(Widget.list, lookup(.config, &.{ "lsp", "zig", "extensions" }).?.widget);
    try t.expectEqual(Widget.string, lookup(.config, &.{ "keys", "global", "ctrl+p" }).?.widget);
    // a Dynamic subtree is where the schema stops
    try t.expect(lookup(.config, &.{ "lsp", "rust", "settings", "cargo" }) == null);
    try t.expect(lookup(.config, &.{ "tools", "cargo" }) == null);
    try t.expect(lookup(.config, &.{ "editor", "nope" }) == null);
    try t.expect(lookup(.none, &.{"editor"}) == null);

    // the other three schemas answer too
    try t.expectEqual(Widget.list, lookup(.session, &.{"panes"}).?.widget);
    try t.expectEqual(Widget.string, lookup(.manifest, &.{"binary"}).?.widget);
    try t.expectEqual(Widget.int, lookup(.theme, &.{ "base_30", "red" }).?.widget);
    try t.expect(lookup(.theme, &.{ "base_30", "red" }).?.optional);
}

test "inference from the literal covers the unknown-file table" {
    var tree = try zon_tree.parse(t.allocator,
        \\.{
        \\    .flag = true,
        \\    .n = 3,
        \\    .ratio = 0.5,
        \\    .name = "x",
        \\    .mode = .fast,
        \\    .maybe = null,
        \\    .items = .{ 1, 2 },
        \\    .engine = .{ .custom = "glow" },
        \\    .pair = .{ .a = 1, .b = 2 },
        \\    .nothing = .{},
        \\    .c = 'q',
        \\}
    , null);
    defer tree.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { path: []const u8, widget: Widget };
    const cases = [_]Case{
        .{ .path = "flag", .widget = .bool },
        .{ .path = "n", .widget = .int },
        .{ .path = "ratio", .widget = .float },
        .{ .path = "name", .widget = .string },
        .{ .path = "mode", .widget = .@"enum" },
        .{ .path = "maybe", .widget = .optional_null },
        .{ .path = "items", .widget = .list },
        .{ .path = "engine", .widget = .union_shaped },
        .{ .path = "pair", .widget = .@"struct" },
        .{ .path = "nothing", .widget = .@"struct" },
        .{ .path = "c", .widget = .literal },
    };
    for (cases) |c| {
        const idx = tree.find(&.{c.path}).?;
        const f = try fieldFor(a, .none, &.{c.path}, tree.get(idx));
        try t.expectEqual(c.widget, f.widget);
        try t.expect(f.inferred);
    }
    const mode = try fieldFor(a, .none, &.{"mode"}, tree.get(tree.find(&.{"mode"}).?));
    try expectTags(mode, &.{"fast"});
    try t.expect(mode.free_enum);
}

test "fieldFor: the schema wins, the literal refines it" {
    var tree = try zon_tree.parse(t.allocator, ".{ .startup = .{ .default_workspace = null, .layout = .{} }, .lsp = .{ .rust = .{ .settings = .{ .cargo = .{ .allFeatures = true } } } } }", null);
    defer tree.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ws = try fieldFor(a, .config, &.{ "startup", "default_workspace" }, tree.get(tree.find(&.{ "startup", "default_workspace" }).?));
    try t.expectEqual(Widget.optional_null, ws.widget);
    try t.expectEqualStrings("\"\"", ws.default_literal);
    try t.expect(!ws.inferred);
    const layout = try fieldFor(a, .config, &.{ "startup", "layout" }, tree.get(tree.find(&.{ "startup", "layout" }).?));
    try t.expectEqual(Widget.list, layout.widget);
    try t.expectEqualStrings(".{}", layout.elem_default);
    // under a Dynamic the literal decides
    const all = try fieldFor(a, .config, &.{ "lsp", "rust", "settings", "cargo", "allFeatures" }, tree.get(tree.find(&.{ "lsp", "rust", "settings", "cargo", "allFeatures" }).?));
    try t.expectEqual(Widget.bool, all.widget);
    try t.expect(all.inferred);
}

test "CONFIG.md's comments become the hover copy, keyed by path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const docs = try parseDocs(a,
        \\intro
        \\```zon
        \\.{
        \\    // ── editor ──
        \\    .editor = .{
        \\        .input_style = .standard, // .vim | .standard
        \\        .tab_width = 4,
        \\        .section_side = .{ // per section
        \\            .explorer = null, // .left | .right
        \\        },
        \\        .keys = .{ .global = .{ .@"ctrl+p" = "x" } }, // one line
        \\    },
        \\    .ui = .{
        \\        .theme = "onedark", // any themes/*.zon name
        \\    },
        \\}
        \\```
    );
    try t.expectEqualStrings(".vim | .standard", docs.get("editor.input_style").?);
    try t.expect(docs.get("editor.tab_width") == null);
    try t.expectEqualStrings("per section", docs.get("editor.section_side").?);
    try t.expectEqualStrings(".left | .right", docs.get("editor.section_side.explorer").?);
    try t.expectEqualStrings("one line", docs.get("editor.keys").?);
    try t.expectEqualStrings("any themes/*.zon name", docs.get("ui.theme").?);
    // and the real file has a line for the keys the settings overlay names
    const real = try configDocs(a);
    try t.expect(real.get("editor.input_style") != null);
    try t.expect(real.get("ui.sidebar_side") != null);
}
