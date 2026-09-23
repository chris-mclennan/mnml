//! What a syntax tree says about a file's shape: which nodes are
//! definitions (for the outline), which of those are scopes (for the
//! sticky context header), and where the function or class around a
//! byte begins and ends (for `if` / `af` / `ic` / `ac`).
//!
//! One node-kind table covers every grammar: the kinds are what the
//! tree-sitter grammars call their declarations (`function_item`,
//! `method_declaration`, `class_definition`, …), and the name is the
//! grammar's `name` field — with the two exceptions spelled out below
//! (C's declarator chain, Go's receiver). A grammar this table does not
//! know yields no symbols, and the outline falls back to its line
//! patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree_sitter");

pub const Kind = enum {
    function,
    method,
    class,
    @"struct",
    @"enum",
    interface,
    trait,
    impl,
    module,
    namespace,
    type,
    constant,
    field,
    /// C#'s `int X { get; set; }` and indexers.
    property,
    /// Zig's `test "name" {}`.
    @"test",

    /// The outline's kind column.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .function => "fn",
            .method => "method",
            .class => "class",
            .@"struct" => "struct",
            .@"enum" => "enum",
            .interface => "interface",
            .trait => "trait",
            .impl => "impl",
            .module => "mod",
            .namespace => "namespace",
            .type => "type",
            .constant => "const",
            .field => "field",
            .property => "prop",
            .@"test" => "test",
        };
    }

    /// A scope: something with a body worth pinning as a header.
    pub fn isScope(k: Kind) bool {
        return switch (k) {
            .type, .constant, .field, .property => false,
            else => true,
        };
    }

    pub fn isFunction(k: Kind) bool {
        return k == .function or k == .method or k == .@"test";
    }

    pub fn isClass(k: Kind) bool {
        return switch (k) {
            .class, .@"struct", .@"enum", .interface, .trait, .impl, .module, .namespace => true,
            else => false,
        };
    }
};

pub const Symbol = struct {
    /// Borrowed from the arena `symbols` was given.
    name: []const u8,
    kind: Kind,
    /// 0-based.
    line: u32,
    col: u32,
    depth: u8,
    start: u32,
    end: u32,
};

const KindEntry = struct { []const u8, Kind };

const kinds = std.StaticStringMap(Kind).initComptime([_]KindEntry{
    .{ "function_item", .function },
    .{ "function_signature_item", .function },
    .{ "function_declaration", .function },
    .{ "function_definition", .function },
    .{ "function", .function },
    .{ "method_definition", .method },
    .{ "method_declaration", .method },
    .{ "method", .method },
    .{ "singleton_method", .method },
    .{ "constructor_declaration", .method },
    .{ "destructor_declaration", .method },
    .{ "operator_declaration", .method },
    .{ "local_function_statement", .function },
    .{ "record_declaration", .class },
    .{ "file_scoped_namespace_declaration", .namespace },
    .{ "delegate_declaration", .type },
    .{ "property_declaration", .property },
    .{ "indexer_declaration", .property },
    .{ "event_declaration", .field },
    .{ "class_declaration", .class },
    // TypeScript's `abstract class` and its abstract members.
    .{ "abstract_class_declaration", .class },
    .{ "abstract_method_signature", .method },
    // Kotlin's `object Registry {}`.
    .{ "object_declaration", .class },
    .{ "class_definition", .class },
    .{ "class_specifier", .class },
    .{ "class", .class },
    .{ "struct_item", .@"struct" },
    .{ "struct_specifier", .@"struct" },
    .{ "struct_declaration", .@"struct" },
    .{ "enum_item", .@"enum" },
    .{ "enum_declaration", .@"enum" },
    .{ "enum_specifier", .@"enum" },
    .{ "union_item", .@"struct" },
    .{ "union_specifier", .@"struct" },
    .{ "interface_declaration", .interface },
    .{ "trait_item", .trait },
    .{ "trait_definition", .trait },
    .{ "impl_item", .impl },
    .{ "mod_item", .module },
    .{ "module", .module },
    .{ "object_definition", .module },
    .{ "namespace_definition", .namespace },
    .{ "namespace_declaration", .namespace },
    // TypeScript's `namespace Util {}`.
    .{ "internal_module", .namespace },
    .{ "test_declaration", .@"test" },
    .{ "type_item", .type },
    .{ "type_alias_declaration", .type },
    // Go's `type ID = int`, Kotlin's `typealias`.
    .{ "type_alias", .type },
    .{ "type_spec", .type },
    .{ "type_definition", .type },
    .{ "const_item", .constant },
    .{ "static_item", .constant },
    .{ "const_declaration", .constant },
    .{ "field_declaration", .field },
    .{ "public_field_definition", .field },
});

/// Container nodes to look through without emitting: Go wraps its type
/// specs in a declaration, C++ its bodies in a field list.
fn isTransparent(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "type_declaration");
}

/// `kind` is a `Kind`, or null for anything that is not a definition.
/// Besides the table, three shapes only the node's children tell apart:
/// Zig's `const Point = struct {…}` (a variable whose value is a
/// container), a YAML key that opens a block (`jobs:` above a mapping
/// or a list — what the Rust outline listed), and Kotlin's
/// `interface` / `enum class`, which its grammar calls a class.
pub fn kindOf(node: ts.Node) ?Kind {
    const k = node.kind();
    if (kinds.get(k)) |kind| {
        if (kind == .class and std.mem.eql(u8, k, "class_declaration")) return kotlinClassKind(node);
        return kind;
    }
    if (std.mem.eql(u8, k, "variable_declaration")) return zigContainerKind(node);
    if (std.mem.eql(u8, k, "block_mapping_pair")) {
        const value = node.childByFieldName("value");
        if (!value.isNull() and std.mem.eql(u8, value.kind(), "block_node")) return .namespace;
    }
    return null;
}

/// Kotlin names every class-like declaration `class_declaration`; the
/// keyword and the body say which it is.
fn kotlinClassKind(node: ts.Node) Kind {
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const c = node.child(i);
        const ck = c.kind();
        if (std.mem.eql(u8, ck, "interface")) return .interface;
        if (std.mem.eql(u8, ck, "enum_class_body")) return .@"enum";
    }
    return .class;
}

/// Zig's `const X = struct / enum / union / opaque {…}`.
fn zigContainerKind(node: ts.Node) ?Kind {
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const ck = node.namedChild(i).kind();
        if (std.mem.eql(u8, ck, "struct_declaration") or std.mem.eql(u8, ck, "union_declaration") or std.mem.eql(u8, ck, "opaque_declaration")) return .@"struct";
        if (std.mem.eql(u8, ck, "enum_declaration")) return .@"enum";
    }
    return null;
}

/// Anonymous function nodes `if` / `af` treat as functions too.
fn isLambda(node: ts.Node) bool {
    const k = node.kind();
    return std.mem.eql(u8, k, "arrow_function") or std.mem.eql(u8, k, "function_expression") or std.mem.eql(u8, k, "closure_expression") or std.mem.eql(u8, k, "lambda") or std.mem.eql(u8, k, "func_literal") or std.mem.eql(u8, k, "lambda_expression") or std.mem.eql(u8, k, "anonymous_method_expression");
}

/// The identifier a definition is named by. C's declarators nest
/// (`declarator: (function_declarator declarator: (identifier))`); a
/// value-less lookup walks that chain. A `variable_declarator` whose
/// value is a function counts as one (`const App = () => …`).
pub fn nameOf(node: ts.Node, text: []const u8) ?[]const u8 {
    var n = node.childByFieldName("name");
    if (n.isNull()) n = node.childByFieldName("declarator");
    if (n.isNull() and std.mem.eql(u8, node.kind(), "impl_item")) n = node.childByFieldName("type");
    if (n.isNull() and std.mem.eql(u8, node.kind(), "block_mapping_pair")) n = node.childByFieldName("key");
    if (n.isNull()) return leadingName(node, text);
    var guard: usize = 0;
    while (!n.isNull() and guard < 8) : (guard += 1) {
        const k = n.kind();
        if (std.mem.eql(u8, k, "function_declarator") or std.mem.eql(u8, k, "pointer_declarator") or std.mem.eql(u8, k, "reference_declarator") or std.mem.eql(u8, k, "parenthesized_declarator")) {
            n = n.childByFieldName("declarator");
            continue;
        }
        break;
    }
    if (n.isNull()) return null;
    return slice(n, text);
}

/// What may stand before a declaration's name: Kotlin's `modifiers`,
/// its `fun <T> String.ext()` type parameters and receiver, comments.
const leading_skip = std.StaticStringMap(void).initComptime(.{ .{"modifiers"}, .{"comment"}, .{"type_parameters"}, .{"receiver_type"}, .{"annotation"} });

/// The name of a definition whose grammar gives it no `name` field —
/// Kotlin's declarations, Zig's variables and tests: the first named
/// child past the modifiers, when that is an identifier (or, for a Zig
/// test, its string, unquoted).
fn leadingName(node: ts.Node, text: []const u8) ?[]const u8 {
    if (node.parent().isNull()) return null;
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const c = node.namedChild(i);
        const ck = c.kind();
        if (leading_skip.has(ck)) continue;
        if (std.mem.eql(u8, ck, "identifier") or std.mem.eql(u8, ck, "type_identifier") or std.mem.eql(u8, ck, "simple_identifier")) return slice(c, text);
        if (std.mem.eql(u8, ck, "string") and std.mem.eql(u8, node.kind(), "test_declaration")) {
            const raw = slice(c, text) orelse return null;
            return std.mem.trim(u8, raw, "\"");
        }
        return null;
    }
    return null;
}

fn slice(node: ts.Node, text: []const u8) ?[]const u8 {
    const s = node.startByte();
    const e = node.endByte();
    if (e <= s or e > text.len) return null;
    return text[s..e];
}

/// Go's `func (r *Router) Handle(…)`: the receiver's type name.
fn receiverType(node: ts.Node, text: []const u8) ?[]const u8 {
    const recv = node.childByFieldName("receiver");
    if (recv.isNull()) return null;
    var i: u32 = 0;
    while (i < recv.namedChildCount()) : (i += 1) {
        const param = recv.namedChild(i);
        var ty = param.childByFieldName("type");
        if (ty.isNull()) continue;
        var guard: usize = 0;
        while (guard < 4 and ty.namedChildCount() == 1 and !std.mem.eql(u8, ty.kind(), "type_identifier")) : (guard += 1) ty = ty.namedChild(0);
        var raw = slice(ty, text) orelse return null;
        raw = std.mem.trimStart(u8, raw, "*&");
        if (std.mem.indexOfScalar(u8, raw, '[')) |b| raw = raw[0..b];
        return raw;
    }
    return null;
}

/// A `variable_declarator` bound to a function is a function symbol.
fn declaratorFunction(node: ts.Node) bool {
    if (!std.mem.eql(u8, node.kind(), "variable_declarator")) return false;
    const value = node.childByFieldName("value");
    return !value.isNull() and isLambda(value);
}

pub const max_symbols = 5000;

/// Every definition in the tree, document order, with nesting depth.
/// Names are built on `arena` (a Go method is `Receiver.Name`).
pub fn symbols(arena: Allocator, root: ts.Node, text: []const u8) Allocator.Error![]Symbol {
    var out: std.ArrayListUnmanaged(Symbol) = .empty;
    try walk(arena, root, text, 0, &out);
    return out.items;
}

fn walk(arena: Allocator, node: ts.Node, text: []const u8, depth: u8, out: *std.ArrayListUnmanaged(Symbol)) Allocator.Error!void {
    if (out.items.len >= max_symbols) return;
    var child_depth = depth;
    const kind: ?Kind = kindOf(node) orelse (if (declaratorFunction(node)) Kind.function else null);
    if (kind) |k| {
        if (nameOf(node, text)) |raw| {
            const name = if (k == .method) blk: {
                if (receiverType(node, text)) |r| break :blk try std.fmt.allocPrint(arena, "{s}.{s}", .{ r, raw });
                break :blk raw;
            } else raw;
            const pt = node.startPoint();
            try out.append(arena, .{ .name = name, .kind = k, .line = pt.row, .col = pt.column, .depth = depth, .start = node.startByte(), .end = node.endByte() });
            child_depth = depth +| 1;
        }
    }
    var i: u32 = 0;
    const n = node.namedChildCount();
    while (i < n) : (i += 1) try walk(arena, node.namedChild(i), text, child_depth, out);
}

/// Start lines of the scopes that contain byte `at` and begin before
/// `line` — outermost first. What treesitter-context pins at the top.
pub fn scopeChain(arena: Allocator, root: ts.Node, at: u32, line: u32) Allocator.Error![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    var node = root.descendantForByteRange(at, at);
    // Collect innermost-first, then reverse.
    while (!node.isNull()) : (node = node.parent()) {
        // The root is the file, never a header: Python's `module` is
        // in the kind table (Ruby's `module` is a real scope), and it
        // used to paint the `def` on line 0 twice.
        if (node.parent().isNull()) continue;
        const k = node.kind();
        const is_scope = if (kindOf(node)) |kind| kind.isScope() else context_kinds.has(k);
        if (!is_scope) continue;
        const pt = node.startPoint();
        if (pt.row >= line) continue;
        if (node.endPoint().row == pt.row) continue;
        // A decorated definition and its definition share nothing, but
        // a compound statement's clause can start on the statement's
        // own line (`if x:` and its consequence in one); one row each.
        if (out.items.len > 0 and out.items[out.items.len - 1] == pt.row) continue;
        try out.append(arena, pt.row);
    }
    std.mem.reverse(u32, out.items);
    return out.items;
}

/// The compound statements the sticky context pins besides the
/// definitions — the loop or branch the cursor is forty lines into,
/// which Python's indentation makes hard to see — the list Neovim's
/// treesitter-context uses. Never in the outline: `symbols` reads the
/// kind table, not this.
const context_kinds = std.StaticStringMap(void).initComptime(.{
    // python
    .{"for_statement"},          .{"while_statement"},  .{"if_statement"},      .{"elif_clause"},
    .{"else_clause"},            .{"with_statement"},   .{"try_statement"},     .{"except_clause"},
    .{"finally_clause"},         .{"match_statement"},  .{"case_clause"},
    // javascript / typescript / c / c++ / java / c# / go
          .{"for_in_statement"},
    .{"for_of_statement"},       .{"do_statement"},     .{"switch_statement"},  .{"switch_case"},
    .{"switch_default"},         .{"catch_clause"},     .{"foreach_statement"}, .{"for_range_loop"},
    .{"enhanced_for_statement"},
    // rust / zig
    .{"for_expression"},   .{"while_expression"},  .{"loop_expression"},
    .{"if_expression"},          .{"match_expression"}, .{"for_statement_zig"},
    // ruby / lua
    .{"for"},
    .{"while"},                  .{"if"},               .{"unless"},            .{"until"},
    .{"case"},                   .{"begin"},
});

pub const Object = enum { function, class };

/// `[start, end)` of the innermost function / class around `byte`.
/// `around` is the whole definition; inner is its body with the
/// delimiting braces stripped (a brace-less body — Python — is taken
/// whole).
pub fn objectAt(root: ts.Node, text: []const u8, which: Object, byte: usize, around: bool) ?[2]usize {
    const b: u32 = @intCast(@min(byte, text.len));
    var node = root.descendantForByteRange(b, b);
    while (!node.isNull()) : (node = node.parent()) {
        const hit = switch (which) {
            .function => (if (kindOf(node)) |k| k.isFunction() else false) or isLambda(node) or declaratorFunction(node),
            .class => if (kindOf(node)) |k| k.isClass() else false,
        };
        if (!hit) continue;
        var s: usize = node.startByte();
        const e: usize = node.endByte();
        // Python's decorators belong to what they decorate: `daf` takes
        // `@cache` with the `def` (nvim-treesitter-textobjects'
        // @function.outer), never leaving it on the next statement.
        const parent = node.parent();
        if (!parent.isNull() and std.mem.eql(u8, parent.kind(), "decorated_definition")) s = parent.startByte();
        if (around) return .{ s, e };
        var body = node.childByFieldName("body");
        if (body.isNull()) {
            // The last named child is the body for grammars without the field.
            const n = node.namedChildCount();
            if (n == 0) return .{ s, e };
            body = node.namedChild(n - 1);
        }
        var bs: usize = body.startByte();
        var be: usize = body.endByte();
        if (be > bs and bs < text.len and text[bs] == '{' and text[be - 1] == '}') {
            bs += 1;
            be -= 1;
        }
        return .{ bs, @max(bs, be) };
    }
    return null;
}

// ── folds ──

/// The blocks a language folds that are not bracket pairs — `do … end`,
/// markup elements, markdown sections, `let` bindings, SQL statements —
/// by table key, after the grammars' own `folds.scm` in nvim-treesitter.
/// A bracket language needs none: its pairs are what `za` folds.
const Kinds = std.StaticStringMap(void);
const fold_kinds = blk: {
    @setEvalBranchQuota(20_000);
    break :blk std.StaticStringMap(Kinds).initComptime(.{
        .{ "rb", Kinds.initComptime(.{ .{"method"}, .{"singleton_method"}, .{"class"}, .{"module"}, .{"singleton_class"}, .{"do_block"}, .{"begin"}, .{"if"}, .{"unless"}, .{"case"}, .{"while"}, .{"until"}, .{"for"}, .{"lambda"} }) },
        .{ "lua", Kinds.initComptime(.{ .{"function_declaration"}, .{"function_definition"}, .{"if_statement"}, .{"for_statement"}, .{"while_statement"}, .{"repeat_statement"}, .{"do_statement"}, .{"table_constructor"} }) },
        .{ "ex", Kinds.initComptime(.{ .{"do_block"}, .{"stab_clause"} }) },
        .{ "html", markup_folds },
        .{ "vue", markup_folds },
        .{ "svelte", markup_folds },
        .{ "md", Kinds.initComptime(.{ .{"section"}, .{"fenced_code_block"}, .{"list"}, .{"block_quote"} }) },
        .{ "ocaml", Kinds.initComptime(.{ .{"let_binding"}, .{"module_binding"}, .{"type_binding"}, .{"class_binding"}, .{"match_expression"} }) },
        .{ "sql", Kinds.initComptime(.{ .{"statement"}, .{"subquery"}, .{"cte"}, .{"case"} }) },
    });
};

const markup_folds = Kinds.initComptime(.{ .{"element"}, .{"script_element"}, .{"style_element"}, .{"template_element"}, .{"if_statement"}, .{"each_statement"}, .{"await_statement"}, .{"key_statement"}, .{"snippet_statement"} });

/// A parsed file whose language folds tree nodes.
pub const FoldTree = struct {
    root: ts.Node,
    kinds: Kinds,

    /// Null when `lang` folds nothing but brackets and indentation.
    pub fn of(lang: ?[]const u8, root: ?ts.Node) ?FoldTree {
        const r = root orelse return null;
        const k = fold_kinds.get(lang orelse return null) orelse return null;
        return .{ .root = r, .kinds = k };
    }

    /// `(first row, last row)` of a fold node spanning more than one
    /// line; a node that ends at the start of a line (a markdown section
    /// runs up to the next heading) ends on the line before.
    fn rows(self: FoldTree, node: ts.Node) ?[2]usize {
        if (!self.kinds.has(node.kind())) return null;
        const lo: usize = node.startPoint().row;
        const end = node.endPoint();
        var hi: usize = end.row;
        if (end.column == 0 and hi > lo) hi -= 1;
        return if (hi > lo) .{ lo, hi } else null;
    }

    /// The smallest fold around `byte` that holds `row`, or that starts
    /// on `row` (at `line_start`, its first byte): a header line folds
    /// the block it opens, as `za` does on a bracket.
    pub fn around(self: FoldTree, byte: usize, row: usize, line_start: usize, line_end: usize) ?[2]usize {
        var best: ?[2]usize = null;
        var node = self.root.descendantForByteRange(@intCast(byte), @intCast(byte));
        while (!node.isNull()) : (node = node.parent()) {
            if (self.rows(node)) |r| if (r[0] <= row and row <= r[1]) {
                best = r;
                break;
            };
        }
        if (self.startingOn(row, line_start, line_end)) |r| {
            if (best == null or r[1] - r[0] < best.?[1] - best.?[0]) best = r;
        }
        return best;
    }

    /// The smallest fold that begins on `row`.
    pub fn startingOn(self: FoldTree, row: usize, line_start: usize, line_end: usize) ?[2]usize {
        var best: ?[2]usize = null;
        var b = line_start;
        while (b < line_end) : (b += 1) {
            var node = self.root.descendantForByteRange(@intCast(b), @intCast(b));
            while (!node.isNull() and node.startPoint().row == row) : (node = node.parent()) {
                if (self.rows(node)) |r| if (best == null or r[1] - r[0] < best.?[1] - best.?[0]) {
                    best = r;
                };
            }
            // One probe per token is enough: skip a token that starts
            // here to its end.
            const leaf = self.root.descendantForByteRange(@intCast(b), @intCast(b));
            if (!leaf.isNull() and leaf.startByte() == b and leaf.endByte() > b + 1) b = @min(line_end, leaf.endByte()) - 1;
        }
        return best;
    }

    /// Every fold in the file, document order.
    pub fn all(self: FoldTree, arena: Allocator, out: *std.ArrayListUnmanaged([2]usize)) Allocator.Error!void {
        try self.collect(arena, self.root, out);
    }

    fn collect(self: FoldTree, arena: Allocator, node: ts.Node, out: *std.ArrayListUnmanaged([2]usize)) Allocator.Error!void {
        if (node.endPoint().row == node.startPoint().row) return;
        if (self.rows(node)) |r| try out.append(arena, r);
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) try self.collect(arena, node.namedChild(i), out);
    }
};

// ── tests ──

const testing = std.testing;
const table = @import("table.zig");

const Parsed = struct {
    parser: *ts.Parser,
    tree: *ts.Tree,

    fn init(key: []const u8, text: []const u8) !Parsed {
        const lang = table.entries[table.find(key).?].language();
        const parser = try ts.Parser.init();
        errdefer parser.deinit();
        try parser.setLanguage(lang);
        const tree = parser.parseString(null, text) orelse return error.NoTree;
        return .{ .parser = parser, .tree = tree };
    }

    fn deinit(p: *Parsed) void {
        p.tree.deinit();
        p.parser.deinit();
    }
};

fn names(arena: Allocator, syms: []const Symbol) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (syms, 0..) |s, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, s.name);
    }
    return out.items;
}

test "rust: functions, structs, impl methods nest by depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "fn alpha() {\n    println!(\"a\");\n}\n\nstruct Gamma {\n    x: u32,\n}\n\nimpl Gamma {\n    fn new() -> Self { Self { x: 1 } }\n}\n";
    var p = try Parsed.init("rs", text);
    defer p.deinit();
    const syms = try symbols(arena.allocator(), p.tree.rootNode(), text);
    try testing.expectEqualStrings("alpha Gamma x Gamma new", try names(arena.allocator(), syms));
    try testing.expectEqual(Kind.function, syms[0].kind);
    try testing.expectEqual(Kind.@"struct", syms[1].kind);
    try testing.expectEqual(Kind.field, syms[2].kind);
    try testing.expectEqual(@as(u8, 1), syms[2].depth);
    try testing.expectEqual(Kind.impl, syms[3].kind);
    try testing.expectEqual(@as(u8, 1), syms[4].depth);
    try testing.expectEqual(@as(u32, 9), syms[4].line);
}

test "go: methods carry their receiver type, plain funcs and types stay bare" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "package http\n\ntype Router struct {\n    routes []string\n}\n\nfunc NewRouter() *Router {\n    return &Router{}\n}\n\nfunc (r *Router) Handle(path string) {\n    r.routes = append(r.routes, path)\n}\n";
    var p = try Parsed.init("go", text);
    defer p.deinit();
    const syms = try symbols(arena.allocator(), p.tree.rootNode(), text);
    try testing.expectEqualStrings("Router routes NewRouter Router.Handle", try names(arena.allocator(), syms));
    try testing.expectEqual(Kind.method, syms[3].kind);
}

test "tsx: React.FC arrows, typed arrows, classes, interfaces and functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "export interface User { id: number; }\nexport class AuthService {\n  async login(user: User): Promise<boolean> { return true; }\n}\nexport type Token = string;\nexport const App: React.FC<Props> = ({ title }) => (<h1>{title}</h1>);\nconst helper = ({ x }: { x: number }) => x * 2;\nexport function Logo() { return <img/>; }\n";
    var p = try Parsed.init("tsx", text);
    defer p.deinit();
    const syms = try symbols(arena.allocator(), p.tree.rootNode(), text);
    try testing.expectEqualStrings("User AuthService login Token App helper Logo", try names(arena.allocator(), syms));
    try testing.expectEqual(Kind.function, syms[4].kind);
    try testing.expectEqual(@as(u8, 1), syms[2].depth);
}

test "python and c: def / class and the declarator chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const py = "def greet(name):\n    return name\n\nclass Greeter:\n    def __call__(self):\n        pass\n";
    var p = try Parsed.init("py", py);
    defer p.deinit();
    try testing.expectEqualStrings("greet Greeter __call__", try names(arena.allocator(), try symbols(arena.allocator(), p.tree.rootNode(), py)));
    const c = "struct point { int x; };\nstatic int *make(int n) {\n    return 0;\n}\n";
    var q = try Parsed.init("c", c);
    defer q.deinit();
    try testing.expectEqualStrings("point x make", try names(arena.allocator(), try symbols(arena.allocator(), q.tree.rootNode(), c)));
}

const cs_text =
    \\namespace Acme.Tests;
    \\
    \\public record Point(int X, int Y);
    \\
    \\public class Calc
    \\{
    \\    public int Count { get; set; }
    \\
    \\    public Calc() { }
    \\
    \\    public int Add(int a, int b)
    \\    {
    \\        int Twice(int v) => v * 2;
    \\        return Twice(a) + b;
    \\    }
    \\
    \\    public int Sub(int a, int b) => a - b;
    \\}
    \\
    \\public struct P { public int Q() { return 1; } }
    \\public interface IRun { void Run(); }
    \\public enum Color { Red, Green }
    \\
;

test "C#: namespace, record, class, property, constructor, methods (block and expression bodied), a local function, struct, interface, enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try Parsed.init("cs", cs_text);
    defer p.deinit();
    const syms = try symbols(arena.allocator(), p.tree.rootNode(), cs_text);
    try testing.expectEqualStrings("Acme.Tests Point Calc Count Calc Add Twice Sub P Q IRun Run Color", try names(arena.allocator(), syms));
    try testing.expectEqual(Kind.namespace, syms[0].kind);
    try testing.expectEqual(Kind.class, syms[1].kind);
    try testing.expectEqual(Kind.class, syms[2].kind);
    try testing.expectEqual(Kind.property, syms[3].kind);
    try testing.expectEqual(Kind.method, syms[4].kind);
    try testing.expectEqual(Kind.method, syms[5].kind);
    try testing.expectEqual(Kind.function, syms[6].kind);
    try testing.expectEqual(Kind.@"struct", syms[8].kind);
    try testing.expectEqual(Kind.interface, syms[10].kind);
    try testing.expectEqual(Kind.@"enum", syms[12].kind);
    try testing.expectEqual(syms[2].depth + 1, syms[5].depth);
    try testing.expectEqual(syms[5].depth + 1, syms[6].depth);
    try testing.expectEqual(@as(u32, 10), syms[5].line);
    // The text objects: `if` / `af` on the block-bodied method, its local function, the expression body; `ic` / `ac` on the class.
    const root = p.tree.rootNode();
    const at_return = std.mem.indexOf(u8, cs_text, "return Twice").?;
    const inner = objectAt(root, cs_text, .function, at_return, false).?;
    try testing.expectEqualStrings("\n        int Twice(int v) => v * 2;\n        return Twice(a) + b;\n    ", cs_text[inner[0]..inner[1]]);
    const around = objectAt(root, cs_text, .function, at_return, true).?;
    try testing.expect(std.mem.startsWith(u8, cs_text[around[0]..around[1]], "public int Add(int a, int b)"));
    try testing.expect(std.mem.endsWith(u8, cs_text[around[0]..around[1]], "return Twice(a) + b;\n    }"));
    const at_twice = std.mem.indexOf(u8, cs_text, "v * 2").?;
    const local = objectAt(root, cs_text, .function, at_twice, true).?;
    try testing.expectEqualStrings("int Twice(int v) => v * 2;", cs_text[local[0]..local[1]]);
    const at_sub = std.mem.indexOf(u8, cs_text, "a - b").?;
    const expr = objectAt(root, cs_text, .function, at_sub, true).?;
    try testing.expectEqualStrings("public int Sub(int a, int b) => a - b;", cs_text[expr[0]..expr[1]]);
    const cls = objectAt(root, cs_text, .class, at_return, false).?;
    try testing.expect(std.mem.startsWith(u8, cs_text[cls[0]..cls[1]], "\n    public int Count"));
    try testing.expect(std.mem.endsWith(u8, cs_text[cls[0]..cls[1]], "=> a - b;\n"));
    const cls_around = objectAt(root, cs_text, .class, at_return, true).?;
    try testing.expect(std.mem.startsWith(u8, cs_text[cls_around[0]..cls_around[1]], "public class Calc"));
    // The scope chain over `return`: the class and the method start above it.
    const chain = try scopeChain(arena.allocator(), root, @intCast(at_return), 13);
    try testing.expect(chain.len >= 2);
    try testing.expectEqual(@as(u32, 4), chain[chain.len - 2]);
    try testing.expectEqual(@as(u32, 10), chain[chain.len - 1]);
}

test "scope chain: the enclosing definitions that start above a line, outermost first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "impl A {\n    fn outer() {\n        let a = 1;\n        let b = 2;\n    }\n}\n";
    var p = try Parsed.init("rs", text);
    defer p.deinit();
    const at: u32 = @intCast(std.mem.indexOf(u8, text, "let b").?);
    const chain = try scopeChain(arena.allocator(), p.tree.rootNode(), at, 3);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, chain);
    // Nothing starts above line 0.
    try testing.expectEqual(@as(usize, 0), (try scopeChain(arena.allocator(), p.tree.rootNode(), at, 0)).len);
}

test "scope chain: python's def › for › if pins the loop and the branch, and the module root is not a header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Line 0 def, 2 for, 3 if, 4.. the body; the `module` root spans it all.
    const text = "def walk(items):\n    total = 0\n    for item in items:\n        if item > 0:\n            total += 1\n            total += 2\n            total += 3\n    return total\n";
    var p = try Parsed.init("py", text);
    defer p.deinit();
    const at: u32 = @intCast(std.mem.indexOf(u8, text, "total += 3").?);
    // Before: `{0, 0}` — the module and the def, both painted as `def walk`
    // — and neither the for nor the if.
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, try scopeChain(arena.allocator(), p.tree.rootNode(), at, 6));
    // With the top line on the `if` itself, only what starts above it.
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, try scopeChain(arena.allocator(), p.tree.rootNode(), at, 3));
    // A class › def › for chain: three distinct rows.
    const cls = "class Walker:\n    def walk(self, items):\n        for item in items:\n            a = 1\n            b = 2\n            c = 3\n";
    var q = try Parsed.init("py", cls);
    defer q.deinit();
    const at2: u32 = @intCast(std.mem.indexOf(u8, cls, "c = 3").?);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, try scopeChain(arena.allocator(), q.tree.rootNode(), at2, 5));
}

test "objectAt: inner function is the body between the braces, around is the whole item; classes likewise" {
    const text = "fn first() {\n    one;\n    two;\n}\n\nstruct S {\n    x: u32,\n}\n";
    var p = try Parsed.init("rs", text);
    defer p.deinit();
    const root = p.tree.rootNode();
    const at = std.mem.indexOf(u8, text, "one").?;
    const inner = objectAt(root, text, .function, at, false).?;
    try testing.expectEqualStrings("\n    one;\n    two;\n", text[inner[0]..inner[1]]);
    const around = objectAt(root, text, .function, at, true).?;
    try testing.expectEqualStrings("fn first() {\n    one;\n    two;\n}", text[around[0]..around[1]]);
    const cx = std.mem.indexOf(u8, text, "x: u32").?;
    try testing.expectEqualStrings("\n    x: u32,\n", text[objectAt(root, text, .class, cx, false).?[0]..objectAt(root, text, .class, cx, false).?[1]]);
    try testing.expect(objectAt(root, text, .function, cx, true) == null);
}

test "one fixture per language: the outline names every definition the table knows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { key: []const u8, text: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .key = "rs", .text = "mod m {\n    pub fn f() {}\n}\ntrait T {}\nenum E { A }\n", .want = "m f T E" },
        .{ .key = "ts", .text = "export abstract class Store {\n  private items: number[] = [];\n  abstract load(): void;\n  save(): void {}\n}\nnamespace Util {\n  export function helper() {}\n}\nexport class Plain {}\ntype ID = string;\n", .want = "Store items load save Util helper Plain ID" },
        .{ .key = "kt", .text = "package demo\n\nobject Registry {\n    fun register() {}\n}\n\ndata class User(val id: Int)\n\ninterface Repo {\n    fun find(id: Int): User?\n}\n\nenum class Color { RED }\n\nfun String.shout() = uppercase()\n\nfun main() {\n    println(\"hi\")\n}\n", .want = "Registry register User Repo find Color shout main" },
        .{ .key = "zig", .text = "const std = @import(\"std\");\n\npub const Point = struct {\n    x: i32,\n    pub fn len(self: Point) i32 {\n        return self.x;\n    }\n};\n\nconst Color = enum { red, green };\n\npub fn main() !void {}\n\ntest \"adds\" {\n    try std.testing.expect(true);\n}\n", .want = "Point len Color main adds" },
        .{ .key = "py", .text = "@cache\ndef f():\n    return 1\n\n@dataclass\nclass A:\n    @property\n    def g(self):\n        pass\n", .want = "f A g" },
        .{ .key = "yaml", .text = "name: CI\non:\n  push:\n    branches: [main]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n  test:\n    needs: build\n", .want = "on push jobs build steps test" },
        .{ .key = "go", .text = "package p\n\ntype ID = int\n\nfunc F() {}\n", .want = "ID F" },
    };
    for (cases) |c| {
        var p = try Parsed.init(c.key, c.text);
        defer p.deinit();
        const syms = try symbols(a, p.tree.rootNode(), c.text);
        testing.expectEqualStrings(c.want, try names(a, syms)) catch |err| {
            std.debug.print("in {s}\n", .{c.key});
            return err;
        };
    }
}

test "kinds the children decide: Zig containers and tests, Kotlin interfaces and enums, YAML blocks, depth under them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zig = "pub const Point = struct {\n    pub fn len() void {}\n};\nconst Color = enum { red };\ntest \"adds\" {}\n";
    var z = try Parsed.init("zig", zig);
    defer z.deinit();
    const zs = try symbols(a, z.tree.rootNode(), zig);
    try testing.expectEqual(Kind.@"struct", zs[0].kind);
    try testing.expectEqual(@as(u8, 1), zs[1].depth);
    try testing.expectEqual(Kind.@"enum", zs[2].kind);
    try testing.expectEqual(Kind.@"test", zs[3].kind);
    try testing.expectEqual(@as(u32, 4), zs[3].line);
    const kt = "interface Repo {}\nenum class Color { RED }\nobject O {}\n";
    var k = try Parsed.init("kt", kt);
    defer k.deinit();
    const ks = try symbols(a, k.tree.rootNode(), kt);
    try testing.expectEqual(Kind.interface, ks[0].kind);
    try testing.expectEqual(Kind.@"enum", ks[1].kind);
    try testing.expectEqual(Kind.class, ks[2].kind);
    const yaml = "jobs:\n  build:\n    runs-on: x\n";
    var y = try Parsed.init("yaml", yaml);
    defer y.deinit();
    const ys = try symbols(a, y.tree.rootNode(), yaml);
    try testing.expectEqual(@as(usize, 2), ys.len);
    try testing.expectEqual(Kind.namespace, ys[0].kind);
    try testing.expectEqual(@as(u8, 1), ys[1].depth);
    try testing.expectEqual(@as(u32, 1), ys[1].line);
}

test "text objects: `af` on a decorated Python def takes its decorators; `ac` finds a TypeScript abstract class and a namespace" {
    const py = "@cache\ndef f():\n    x = 1\n\nZ = 2\n";
    var p = try Parsed.init("py", py);
    defer p.deinit();
    const r = objectAt(p.tree.rootNode(), py, .function, std.mem.indexOf(u8, py, "x = 1").?, true).?;
    try testing.expectEqualStrings("@cache\ndef f():\n    x = 1", py[r[0]..r[1]]);
    const inner = objectAt(p.tree.rootNode(), py, .function, std.mem.indexOf(u8, py, "x = 1").?, false).?;
    try testing.expectEqualStrings("x = 1", py[inner[0]..inner[1]]);
    const ts_text = "export abstract class Store {\n  load(): void {\n    go();\n  }\n}\nnamespace Util {\n  export function helper() {}\n}\n";
    var t = try Parsed.init("ts", ts_text);
    defer t.deinit();
    const root = t.tree.rootNode();
    const c = objectAt(root, ts_text, .class, std.mem.indexOf(u8, ts_text, "go()").?, true).?;
    try testing.expect(std.mem.startsWith(u8, ts_text[c[0]..c[1]], "abstract class Store"));
    const n = objectAt(root, ts_text, .class, std.mem.indexOf(u8, ts_text, "export function").?, true).?;
    try testing.expect(std.mem.startsWith(u8, ts_text[n[0]..n[1]], "namespace Util"));
}

test "folds: do / end, markup and section blocks fold by their tree nodes; a bracket language folds none here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { key: []const u8, text: []const u8, row: usize, want: [2]usize };
    const cases = [_]Case{
        .{ .key = "rb", .text = "def foo\n  bar\n  baz\nend\nZ = 2\n", .row = 1, .want = .{ 0, 3 } },
        .{ .key = "lua", .text = "local function f()\n  a()\n  b()\nend\nx = 1\n", .row = 2, .want = .{ 0, 3 } },
        .{ .key = "ex", .text = "defmodule A do\n  def f(x) do\n    x + 1\n  end\nend\n", .row = 2, .want = .{ 1, 3 } },
        .{ .key = "html", .text = "<div>\n  <p>a</p>\n  <p>b</p>\n</div>\n", .row = 1, .want = .{ 0, 3 } },
        .{ .key = "md", .text = "# One\n\ntext\nmore\n\n# Two\n\nz\n", .row = 2, .want = .{ 0, 4 } },
        .{ .key = "ocaml", .text = "let f x =\n  let y = x + 1 in\n  y * 2\n\nlet g = 3\n", .row = 2, .want = .{ 0, 2 } },
        .{ .key = "sql", .text = "SELECT id,\n  name\nFROM users\nWHERE id = 1;\n", .row = 1, .want = .{ 0, 3 } },
    };
    for (cases) |c| {
        var p = try Parsed.init(c.key, c.text);
        defer p.deinit();
        const ft = FoldTree.of(c.key, p.tree.rootNode()).?;
        const ls = lineStartOf(c.text, c.row);
        const le = std.mem.indexOfScalarPos(u8, c.text, ls, '\n') orelse c.text.len;
        const got = ft.around(ls + (le - ls) / 2, c.row, ls, le) orelse {
            std.debug.print("{s}: no fold at row {d}\n", .{ c.key, c.row });
            return error.NoFold;
        };
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("in {s}\n", .{c.key});
            return err;
        };
        // The header line folds the block it opens.
        const hs = lineStartOf(c.text, c.want[0]);
        const he = std.mem.indexOfScalarPos(u8, c.text, hs, '\n').?;
        try testing.expect(ft.startingOn(c.want[0], hs, he) != null);
        var all: std.ArrayListUnmanaged([2]usize) = .empty;
        try ft.all(a, &all);
        try testing.expect(all.items.len > 0);
    }
    try testing.expect(FoldTree.of("rs", null) == null);
    var r = try Parsed.init("rs", "fn f() {\n    x;\n}\n");
    defer r.deinit();
    try testing.expect(FoldTree.of("rs", r.tree.rootNode()) == null);
}

fn lineStartOf(text: []const u8, row: usize) usize {
    var i: usize = 0;
    var r: usize = 0;
    while (r < row) : (r += 1) i = std.mem.indexOfScalarPos(u8, text, i, '\n').? + 1;
    return i;
}
