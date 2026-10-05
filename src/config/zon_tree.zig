//! A `.zon` file as a tree of fields — the model behind the ZON view
//! pane (`app/zon_pane.zig`).
//!
//! The same two passes the loader makes (`load.zig`: `Ast.parse(.zon)`
//! then `ZonGen`), read for their shape instead of their values: every
//! struct field and list element becomes a `Node` that knows its name,
//! its literal's byte span in the source, what kind of literal it is,
//! and its children. The spans are what the pane edits through the
//! settings splice (`persist.splice`), so nothing outside a value is
//! ever touched — comments and order survive.
//!
//! A tree borrows nothing: the source is copied onto the tree's arena
//! and every name and literal is a slice of that copy.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;

/// What a literal is. `empty` is `.{}` — a struct or a list, the source
/// cannot say which.
pub const Kind = enum {
    bool,
    null,
    int,
    float,
    char,
    enum_lit,
    string,
    @"struct",
    list,
    empty,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .bool => "bool",
            .null => "null",
            .int => "int",
            .float => "float",
            .char => "char",
            .enum_lit => "enum",
            .string => "string",
            .@"struct" => "struct",
            .list => "list",
            .empty => ".{}",
        };
    }

    /// A container: the row folds and its children indent under it.
    pub fn isContainer(k: Kind) bool {
        return k == .@"struct" or k == .list or k == .empty;
    }
};

/// Byte range in the source: `[start, end)`.
pub const Span = struct { start: u32, end: u32 };

pub const Node = struct {
    /// The field name (the unescaped `name` of `.name = …`), `[i]` for
    /// a list element, `` for the root.
    name: []const u8,
    /// A list element's position.
    index: ?u32 = null,
    parent: ?u32 = null,
    depth: u16 = 0,
    kind: Kind,
    /// The value literal's bytes.
    span: Span,
    /// The `.name` token of a struct field (for a rename); null on a
    /// list element and the root.
    name_span: ?Span = null,
    children: []const u32 = &.{},
    /// `src[span.start..span.end]`.
    text: []const u8,

    pub fn isListElement(n: *const Node) bool {
        return n.index != null;
    }
};

pub const ParseError = error{ OutOfMemory, ParseFailed };

pub const Tree = struct {
    arena: *std.heap.ArenaAllocator,
    /// The source the spans index; `text` slices point into it.
    src: [:0]const u8,
    /// Pre-order: a node's children follow it. `nodes[0]` is the root.
    nodes: []const Node,

    pub fn deinit(self: *Tree) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    pub fn root(self: *const Tree) *const Node {
        return &self.nodes[0];
    }

    pub fn get(self: *const Tree, idx: u32) *const Node {
        return &self.nodes[idx];
    }

    /// The names from the root down to `idx`, the shape the splice
    /// takes: `.{ "ui", "theme" }`, `.{ "workspaces", "[1]", "group" }`.
    pub fn keyPath(self: *const Tree, alloc: Allocator, idx: u32) Allocator.Error![]const []const u8 {
        var depth: usize = 0;
        var cur: ?u32 = idx;
        while (cur) |c| : (cur = self.nodes[c].parent) {
            if (self.nodes[c].parent != null) depth += 1;
        }
        const out = try alloc.alloc([]const u8, depth);
        var i = depth;
        cur = idx;
        while (cur) |c| : (cur = self.nodes[c].parent) {
            if (self.nodes[c].parent == null) break;
            i -= 1;
            out[i] = self.nodes[c].name;
        }
        return out;
    }

    /// `ui.theme`, `workspaces[1].group`, `` for the root.
    pub fn pathString(self: *const Tree, alloc: Allocator, idx: u32) Allocator.Error![]u8 {
        const parts = try self.keyPath(alloc, idx);
        var out: std.ArrayList(u8) = .empty;
        for (parts) |p| {
            if (p.len > 0 and p[0] == '[') {
                try out.appendSlice(alloc, p);
            } else {
                if (out.items.len > 0) try out.append(alloc, '.');
                try out.appendSlice(alloc, p);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// The node at `key_path`, if the file has it.
    pub fn find(self: *const Tree, key_path: []const []const u8) ?u32 {
        var cur: u32 = 0;
        for (key_path) |k| {
            var next: ?u32 = null;
            for (self.nodes[cur].children) |c| {
                if (std.mem.eql(u8, self.nodes[c].name, k)) {
                    next = c;
                    break;
                }
            }
            cur = next orelse return null;
        }
        return cur;
    }

    /// The names of the root's fields — what a schema check looks at.
    pub fn rootNames(self: *const Tree, alloc: Allocator) Allocator.Error![]const []const u8 {
        const kids = self.nodes[0].children;
        const out = try alloc.alloc([]const u8, kids.len);
        for (kids, 0..) |c, i| out[i] = self.nodes[c].name;
        return out;
    }
};

/// Parse `src` into a tree. A file that does not parse, or that ZonGen
/// rejects (a duplicate key, an identifier), is `error.ParseFailed`
/// with the first message rendered onto `why` when one is wanted —
/// allocated on `gpa`, the caller's to free.
pub fn parse(gpa: Allocator, src: [:0]const u8, why: ?*[]const u8) ParseError!Tree {
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const copy = try arena.dupeSentinel(u8, src, 0);
    var ast = try compat.parseZonAst(arena, copy);
    if (ast.errors.len != 0) {
        if (why) |w| {
            var buf: std.Io.Writer.Allocating = .init(arena);
            ast.renderError(ast.errors[0], &buf.writer) catch {};
            const loc = ast.tokenLocation(0, ast.errors[0].token);
            w.* = try std.fmt.allocPrint(gpa, "{d}:{d}: {s}", .{ loc.line + 1, loc.column + 1, buf.written() });
        }
        return error.ParseFailed;
    }
    var zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    if (zoir.hasCompileErrors()) {
        if (why) |w| {
            const e = zoir.compile_errors[0];
            const tok: Ast.TokenIndex = if (e.token.unwrap()) |tk| tk else ast.nodeMainToken(@enumFromInt(e.node_or_offset));
            const loc = ast.tokenLocation(0, tok);
            w.* = try std.fmt.allocPrint(gpa, "{d}:{d}: {s}", .{ loc.line + 1, loc.column + 1, compat.zoirGet(e.msg, &zoir) });
        }
        return error.ParseFailed;
    }

    var b: Builder = .{ .arena = arena, .ast = ast, .zoir = zoir, .src = copy };
    _ = try b.visit(.root, "", null, null, 0);
    // Children were recorded as the visit went; the list is pre-order.
    return .{ .arena = arena_state, .src = copy, .nodes = try b.nodes.toOwnedSlice(arena) };
}

const Builder = struct {
    arena: Allocator,
    ast: Ast,
    zoir: Zoir,
    src: [:0]const u8,
    nodes: std.ArrayList(Node) = .empty,

    fn spanOf(b: *Builder, ast_node: Ast.Node.Index) Span {
        const first = b.ast.firstToken(ast_node);
        const last = b.ast.lastToken(ast_node);
        const start = b.ast.tokenStart(first);
        const end = b.ast.tokenStart(last) + b.ast.tokenSlice(last).len;
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    /// The `.name` token two back from a struct field's value.
    fn nameSpanOf(b: *Builder, ast_node: Ast.Node.Index) ?Span {
        const first = b.ast.firstToken(ast_node);
        if (first < 2) return null;
        const tok = first - 2;
        const start = b.ast.tokenStart(tok);
        return .{ .start = @intCast(start), .end = @intCast(start + b.ast.tokenSlice(tok).len) };
    }

    fn visit(b: *Builder, node: Zoir.Node.Index, name: []const u8, index: ?u32, parent: ?u32, depth: u16) Allocator.Error!u32 {
        const ast_node = compat.zoirAstNode(node, &b.zoir);
        const span = b.spanOf(ast_node);
        const got = compat.zoirGet(node, &b.zoir);
        const kind: Kind = switch (got) {
            .true, .false => .bool,
            .null => .null,
            .int_literal => .int,
            .float_literal, .pos_inf, .neg_inf, .nan => .float,
            .char_literal => .char,
            .enum_literal => .enum_lit,
            .string_literal => .string,
            .empty_literal => .empty,
            .array_literal => .list,
            .struct_literal => .@"struct",
        };
        const idx: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.arena, .{
            .name = name,
            .index = index,
            .parent = parent,
            .depth = depth,
            .kind = kind,
            .span = span,
            .name_span = if (parent != null and index == null) b.nameSpanOf(ast_node) else null,
            .text = b.src[span.start..span.end],
        });
        var kids: std.ArrayList(u32) = .empty;
        switch (got) {
            .struct_literal => |lit| {
                for (lit.names, 0..) |n, i| {
                    const child_name = try b.arena.dupe(u8, compat.zoirGet(n, &b.zoir));
                    const c = try b.visit(lit.vals.at(@intCast(i)), child_name, null, idx, depth + 1);
                    try kids.append(b.arena, c);
                }
            },
            .array_literal => |range| {
                var i: u32 = 0;
                while (i < range.len) : (i += 1) {
                    const child_name = try std.fmt.allocPrint(b.arena, "[{d}]", .{i});
                    const c = try b.visit(range.at(i), child_name, i, idx, depth + 1);
                    try kids.append(b.arena, c);
                }
            },
            else => {},
        }
        b.nodes.items[idx].children = try kids.toOwnedSlice(b.arena);
        return idx;
    }
};

/// True for a `[i]` list-element key.
pub fn isIndexKey(key: []const u8) bool {
    return key.len >= 3 and key[0] == '[' and key[key.len - 1] == ']';
}

/// The `i` of a `[i]` key.
pub fn indexOfKey(key: []const u8) ?u32 {
    if (!isIndexKey(key)) return null;
    return std.fmt.parseInt(u32, key[1 .. key.len - 1], 10) catch null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const canned: [:0]const u8 =
    \\// a config with one of everything
    \\.{
    \\    .editor = .{
    \\        .tab_width = 4, // four
    \\        .input_style = .vim,
    \\        .breadcrumb = true,
    \\    },
    \\    .ui = .{
    \\        .theme = "onedark",
    \\        .md_preview_engine = .{ .custom = "glow -s" },
    \\        .scale = 1.5,
    \\        .todo_keywords = .{ "TODO", "FIXME" },
    \\        .color = 'x',
    \\    },
    \\    .startup = .{ .default_workspace = null, .layout = .{} },
    \\    .workspaces = .{
    \\        .{ .name = "a", .path = "/a" },
    \\        .{ .name = "b", .path = "/b", .group = "g" },
    \\    },
    \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
    \\}
    \\
;

test "every literal kind gets a node with its span and its name" {
    var tree = try parse(t.allocator, canned, null);
    defer tree.deinit();
    const r = tree.root();
    try t.expectEqual(Kind.@"struct", r.kind);
    try t.expectEqual(@as(usize, 5), r.children.len);

    const tab = tree.find(&.{ "editor", "tab_width" }).?;
    try t.expectEqual(Kind.int, tree.get(tab).kind);
    try t.expectEqualStrings("4", tree.get(tab).text);
    try t.expectEqualStrings("tab_width", tree.get(tab).name);
    try t.expectEqual(@as(u16, 2), tree.get(tab).depth);
    const ns = tree.get(tab).name_span.?;
    try t.expectEqualStrings("tab_width", tree.src[ns.start..ns.end]);

    try t.expectEqual(Kind.enum_lit, tree.get(tree.find(&.{ "editor", "input_style" }).?).kind);
    try t.expectEqual(Kind.bool, tree.get(tree.find(&.{ "editor", "breadcrumb" }).?).kind);
    try t.expectEqual(Kind.string, tree.get(tree.find(&.{ "ui", "theme" }).?).kind);
    try t.expectEqualStrings("\"onedark\"", tree.get(tree.find(&.{ "ui", "theme" }).?).text);
    try t.expectEqual(Kind.float, tree.get(tree.find(&.{ "ui", "scale" }).?).kind);
    try t.expectEqual(Kind.char, tree.get(tree.find(&.{ "ui", "color" }).?).kind);
    try t.expectEqual(Kind.null, tree.get(tree.find(&.{ "startup", "default_workspace" }).?).kind);
    try t.expectEqual(Kind.empty, tree.get(tree.find(&.{ "startup", "layout" }).?).kind);

    // a nested union: a one-field struct whose field is the tag
    const engine = tree.find(&.{ "ui", "md_preview_engine" }).?;
    try t.expectEqual(Kind.@"struct", tree.get(engine).kind);
    try t.expectEqual(@as(usize, 1), tree.get(engine).children.len);
    const custom = tree.get(engine).children[0];
    try t.expectEqualStrings("custom", tree.get(custom).name);
    try t.expectEqualStrings("\"glow -s\"", tree.get(custom).text);
    try t.expectEqualStrings(".{ .custom = \"glow -s\" }", tree.get(engine).text);

    // a list of strings and a list of structs
    const kw = tree.find(&.{ "ui", "todo_keywords" }).?;
    try t.expectEqual(Kind.list, tree.get(kw).kind);
    try t.expectEqual(@as(usize, 2), tree.get(kw).children.len);
    const second = tree.get(kw).children[1];
    try t.expectEqualStrings("[1]", tree.get(second).name);
    try t.expectEqual(@as(?u32, 1), tree.get(second).index);
    try t.expect(tree.get(second).name_span == null);
    const ws1 = tree.find(&.{ "workspaces", "[1]" }).?;
    try t.expectEqual(Kind.@"struct", tree.get(ws1).kind);
    try t.expectEqualStrings("g", std.mem.trim(u8, tree.get(tree.find(&.{ "workspaces", "[1]", "group" }).?).text, "\""));

    // a quoted key is unescaped
    const ctrl_p = tree.find(&.{ "keys", "global", "ctrl+p" }).?;
    try t.expectEqualStrings("ctrl+p", tree.get(ctrl_p).name);
    const ctrl_ns = tree.get(ctrl_p).name_span.?;
    try t.expectEqualStrings("@\"ctrl+p\"", tree.src[ctrl_ns.start..ctrl_ns.end]);
}

test "keyPath and pathString spell the splice path and the breadcrumb" {
    var tree = try parse(t.allocator, canned, null);
    defer tree.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const idx = tree.find(&.{ "workspaces", "[1]", "group" }).?;
    const kp = try tree.keyPath(a, idx);
    try t.expectEqual(@as(usize, 3), kp.len);
    try t.expectEqualStrings("workspaces", kp[0]);
    try t.expectEqualStrings("[1]", kp[1]);
    try t.expectEqualStrings("group", kp[2]);
    try t.expectEqualStrings("workspaces[1].group", try tree.pathString(a, idx));
    try t.expectEqualStrings("", try tree.pathString(a, 0));
    try t.expectEqual(@as(usize, 0), (try tree.keyPath(a, 0)).len);
    try t.expect(tree.find(&.{ "nope", "x" }) == null);
    const names = try tree.rootNames(a);
    try t.expectEqualStrings("editor", names[0]);
    try t.expectEqualStrings("keys", names[4]);
    try t.expectEqual(@as(?u32, 7), indexOfKey("[7]"));
    try t.expect(indexOfKey("seven") == null);
}

test "nodes are pre-order and a parent knows its children" {
    var tree = try parse(t.allocator, ".{ .a = .{ .b = 1, .c = .{ 2, 3 } }, .d = true }", null);
    defer tree.deinit();
    const names = [_][]const u8{ "", "a", "b", "c", "[0]", "[1]", "d" };
    try t.expectEqual(names.len, tree.nodes.len);
    for (names, 0..) |n, i| try t.expectEqualStrings(n, tree.nodes[i].name);
    try t.expectEqual(@as(?u32, 3), tree.nodes[4].parent);
    try t.expectEqual(@as(u16, 3), tree.nodes[5].depth);
}

test "a broken file names its line; a duplicate key is refused" {
    var why: []const u8 = "";
    try t.expectError(error.ParseFailed, parse(t.allocator, ".{ .a = ", &why));
    try t.expect(std.mem.startsWith(u8, why, "1:"));
    t.allocator.free(why);
    try t.expectError(error.ParseFailed, parse(t.allocator, ".{ .a = 1, .a = 2 }", &why));
    try t.expect(std.mem.indexOf(u8, why, "duplicate") != null);
    t.allocator.free(why);
    // the top level need not be a struct
    var tree = try parse(t.allocator, "42", null);
    defer tree.deinit();
    try t.expectEqual(Kind.int, tree.root().kind);
    var empty = try parse(t.allocator, ".{}", null);
    defer empty.deinit();
    try t.expectEqual(Kind.empty, empty.root().kind);
}
