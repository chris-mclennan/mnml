//! Hand-declared bindings to the tree-sitter C runtime (`lib/include/tree_sitter/api.h`,
//! v0.26). No `@cImport` — every type and function we use is spelled out here so the
//! surface is explicit and the by-value structs are asserted against the header's
//! layout at comptime. Grammar entry points (`tree_sitter_rust()` …) live in
//! `highlight/table.zig`, not here; this file is the runtime only.
//!
//! Naming: the raw externs keep their C names (`ts_parser_new`). The thin idiomatic
//! layer on each type (`Parser.init`, `Node.kind`, `Query.init`) is what the rest of
//! mnml-zig calls.

const std = @import("std");

/// `TREE_SITTER_LANGUAGE_VERSION` — the ABI this runtime was built for.
pub const language_version: u32 = 15;
/// `TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION` — oldest grammar ABI it still loads.
pub const min_compatible_language_version: u32 = 13;

// ── by-value structs (layout must match api.h) ───────────────────────────────

pub const Point = extern struct {
    row: u32,
    column: u32,
};

pub const Range = extern struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

pub const InputEncoding = enum(c_uint) {
    utf8 = 0,
    utf16le = 1,
    utf16be = 2,
    custom = 3,
};

pub const QueryError = enum(c_uint) {
    none = 0,
    syntax = 1,
    node_type = 2,
    field = 3,
    capture = 4,
    structure = 5,
    language = 6,
};

pub const QueryCapture = extern struct {
    node: Node,
    index: u32,
};

/// One step of a pattern's predicate list (`#eq?`, `#set!`, …): the runtime
/// stores predicates as flat `(type, value_id)` triples terminated by `.done`.
pub const QueryPredicateStepType = enum(c_uint) {
    done = 0,
    capture = 1,
    string = 2,
};

pub const QueryPredicateStep = extern struct {
    type: QueryPredicateStepType,
    value_id: u32,
};

pub const QueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const QueryCapture,

    pub fn slice(m: *const QueryMatch) []const QueryCapture {
        return m.captures[0..m.capture_count];
    }
};

pub const TreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,

    pub fn init(node: Node) TreeCursor {
        return ts_tree_cursor_new(node);
    }
    pub fn deinit(c: *TreeCursor) void {
        ts_tree_cursor_delete(c);
    }
    pub fn currentNode(c: *const TreeCursor) Node {
        return ts_tree_cursor_current_node(c);
    }
    pub fn gotoFirstChild(c: *TreeCursor) bool {
        return ts_tree_cursor_goto_first_child(c);
    }
    pub fn gotoNextSibling(c: *TreeCursor) bool {
        return ts_tree_cursor_goto_next_sibling(c);
    }
    pub fn gotoParent(c: *TreeCursor) bool {
        return ts_tree_cursor_goto_parent(c);
    }
};

comptime {
    const ptr = @sizeOf(*const anyopaque);
    std.debug.assert(@sizeOf(Point) == 8);
    std.debug.assert(@sizeOf(Range) == 24);
    std.debug.assert(@sizeOf(InputEdit) == 36);
    // TSNode { uint32_t context[4]; const void *id; const TSTree *tree; }
    std.debug.assert(@sizeOf(Node) == 16 + 2 * ptr);
    // TSTreeCursor { const void *tree; const void *id; uint32_t context[3]; } + tail padding
    std.debug.assert(@sizeOf(TreeCursor) == std.mem.alignForward(usize, 2 * ptr + 12, ptr));
    std.debug.assert(@sizeOf(QueryCapture) == @sizeOf(Node) + 4 + (ptr - 4));
    // TSQueryMatch { uint32_t id; uint16_t pattern_index; uint16_t capture_count; const TSQueryCapture *captures; }
    std.debug.assert(@sizeOf(QueryMatch) == 8 + ptr);
    std.debug.assert(@sizeOf(QueryError) == @sizeOf(c_uint));
    std.debug.assert(@sizeOf(QueryPredicateStep) == 8);
}

// ── opaque handles ───────────────────────────────────────────────────────────

/// A compiled grammar. Obtained from a grammar's entry point, never freed.
pub const Language = opaque {
    pub fn abiVersion(l: *const Language) u32 {
        return ts_language_abi_version(l);
    }
    /// True when this runtime can load the grammar.
    pub fn isCompatible(l: *const Language) bool {
        const v = l.abiVersion();
        return v >= min_compatible_language_version and v <= language_version;
    }
    /// Grammar name baked in by newer `tree-sitter generate`s; null on older parsers.
    pub fn name(l: *const Language) ?[:0]const u8 {
        const p = ts_language_name(l) orelse return null;
        return std.mem.span(p);
    }
    pub fn symbolCount(l: *const Language) u32 {
        return ts_language_symbol_count(l);
    }
};

pub const Parser = opaque {
    pub fn init() error{OutOfMemory}!*Parser {
        return ts_parser_new() orelse error.OutOfMemory;
    }
    pub fn deinit(p: *Parser) void {
        ts_parser_delete(p);
    }
    /// Fails when the grammar's ABI is outside `[min_compatible, language_version]`.
    pub fn setLanguage(p: *Parser, l: *const Language) error{IncompatibleLanguage}!void {
        if (!ts_parser_set_language(p, l)) return error.IncompatibleLanguage;
    }
    /// Parse a UTF-8 buffer, optionally reusing `old` for incremental parsing.
    /// Null means the parser was cancelled or has no language.
    pub fn parseString(p: *Parser, old: ?*const Tree, src: []const u8) ?*Tree {
        return ts_parser_parse_string(p, old, src.ptr, @intCast(src.len));
    }
    /// Restrict parsing to `ranges` (injections). Empty slice restores the whole document.
    pub fn setIncludedRanges(p: *Parser, ranges: []const Range) error{OverlappingRanges}!void {
        if (!ts_parser_set_included_ranges(p, ranges.ptr, @intCast(ranges.len))) return error.OverlappingRanges;
    }
    pub fn reset(p: *Parser) void {
        ts_parser_reset(p);
    }
};

pub const Tree = opaque {
    pub fn deinit(t: *Tree) void {
        ts_tree_delete(t);
    }
    pub fn rootNode(t: *const Tree) Node {
        return ts_tree_root_node(t);
    }
    pub fn edit(t: *Tree, e: *const InputEdit) void {
        ts_tree_edit(t, e);
    }
    pub fn copy(t: *const Tree) *Tree {
        return ts_tree_copy(t);
    }
    pub fn language(t: *const Tree) *const Language {
        return ts_tree_language(t);
    }
};

pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,

    /// The node's type name as the grammar spells it (`"function_item"`, `"ERROR"`).
    pub fn kind(n: Node) [:0]const u8 {
        return std.mem.span(ts_node_type(n));
    }
    pub fn startByte(n: Node) u32 {
        return ts_node_start_byte(n);
    }
    pub fn endByte(n: Node) u32 {
        return ts_node_end_byte(n);
    }
    pub fn startPoint(n: Node) Point {
        return ts_node_start_point(n);
    }
    pub fn endPoint(n: Node) Point {
        return ts_node_end_point(n);
    }
    pub fn isNull(n: Node) bool {
        return ts_node_is_null(n);
    }
    pub fn isNamed(n: Node) bool {
        return ts_node_is_named(n);
    }
    /// True for `ERROR` nodes themselves.
    pub fn isError(n: Node) bool {
        return ts_node_is_error(n);
    }
    /// True when this node or any descendant is an `ERROR` / `MISSING`.
    pub fn hasError(n: Node) bool {
        return ts_node_has_error(n);
    }
    pub fn childCount(n: Node) u32 {
        return ts_node_child_count(n);
    }
    pub fn child(n: Node, i: u32) Node {
        return ts_node_child(n, i);
    }
    pub fn namedChildCount(n: Node) u32 {
        return ts_node_named_child_count(n);
    }
    pub fn namedChild(n: Node, i: u32) Node {
        return ts_node_named_child(n, i);
    }
    pub fn parent(n: Node) Node {
        return ts_node_parent(n);
    }
    pub fn nextSibling(n: Node) Node {
        return ts_node_next_sibling(n);
    }
    pub fn prevSibling(n: Node) Node {
        return ts_node_prev_sibling(n);
    }
    pub fn nextNamedSibling(n: Node) Node {
        return ts_node_next_named_sibling(n);
    }
    /// The child bound to `field` in the grammar (`name`, `body`, `receiver`),
    /// or a null node.
    pub fn childByFieldName(n: Node, field: []const u8) Node {
        return ts_node_child_by_field_name(n, field.ptr, @intCast(field.len));
    }
    /// The smallest NAMED node spanning `[start, end]`.
    pub fn namedDescendantForByteRange(n: Node, start: u32, end: u32) Node {
        return ts_node_named_descendant_for_byte_range(n, start, end);
    }
    pub fn descendantForByteRange(n: Node, start: u32, end: u32) Node {
        return ts_node_descendant_for_byte_range(n, start, end);
    }
    /// S-expression of the subtree. Caller frees with `freeSexp`.
    pub fn sexp(n: Node) [:0]u8 {
        return std.mem.span(ts_node_string(n));
    }
    pub fn freeSexp(s: [:0]u8) void {
        ts_free(s.ptr);
    }
};

pub const Query = opaque {
    pub const CompileError = error{
        Syntax,
        NodeType,
        Field,
        Capture,
        Structure,
        Language,
    };

    /// Where and why `Query.init` failed — the byte offset into the source and the C error kind.
    pub const Failure = struct {
        offset: u32,
        err: QueryError,
    };

    /// Compile `source` against `language`. On failure `failure` (when given) receives
    /// the offset + kind so callers can print `lang:offset` diagnostics.
    pub fn init(language: *const Language, source: []const u8, failure: ?*Failure) CompileError!*Query {
        var offset: u32 = 0;
        var err: QueryError = .none;
        const q = ts_query_new(language, source.ptr, @intCast(source.len), &offset, &err);
        if (q) |ok| return ok;
        if (failure) |f| f.* = .{ .offset = offset, .err = err };
        return switch (err) {
            .none => unreachable,
            .syntax => error.Syntax,
            .node_type => error.NodeType,
            .field => error.Field,
            .capture => error.Capture,
            .structure => error.Structure,
            .language => error.Language,
        };
    }
    pub fn deinit(q: *Query) void {
        ts_query_delete(q);
    }
    pub fn patternCount(q: *const Query) u32 {
        return ts_query_pattern_count(q);
    }
    pub fn captureCount(q: *const Query) u32 {
        return ts_query_capture_count(q);
    }
    pub fn captureName(q: *const Query, index: u32) []const u8 {
        var len: u32 = 0;
        const p = ts_query_capture_name_for_id(q, index, &len);
        return p[0..len];
    }
    pub fn stringCount(q: *const Query) u32 {
        return ts_query_string_count(q);
    }
    pub fn stringValue(q: *const Query, index: u32) []const u8 {
        var len: u32 = 0;
        const p = ts_query_string_value_for_id(q, index, &len);
        return p[0..len];
    }
    /// The flat predicate steps of `pattern` — every `(#name? …)` and
    /// `(#set! …)` in source order, each list ending in a `.done` step.
    pub fn predicatesForPattern(q: *const Query, pattern: u32) []const QueryPredicateStep {
        var len: u32 = 0;
        const p = ts_query_predicates_for_pattern(q, pattern, &len);
        return p[0..len];
    }
};

pub const QueryCursor = opaque {
    /// The most in-progress matches a cursor may hold. Two reasons it is
    /// not left at the runtime's default (unbounded):
    ///
    /// - the runtime names each match's capture list with a 16-bit id and
    ///   keeps the top value for "none", so past 65535 live matches two of
    ///   them share a list and the cursor reads a freed one (a segfault in
    ///   `ts_query_cursor__compare_captures`);
    /// - every step compares the live matches of a pattern pairwise, so the
    ///   cost of a step grows with the square of the pool. Measured on the
    ///   one shipped input that fills it (the Haskell fixture repeated to
    ///   128 KB): 99 ms at 256, 473 ms at 1024, 3.0 s at 4096, and no end
    ///   in sight at 16384.
    ///
    /// At the cap the runtime drops the oldest in-progress match
    /// (`didExceedMatchLimit`), so a query that reaches it may paint
    /// differently than it would with more room — there is no exact answer
    /// to hold it to, since the uncapped query is the one that crashes.
    /// What was measured: of the 42 grammars' fixtures, once and repeated
    /// to 128 KB, that Haskell text (a 54-byte module pasted ~2400 times,
    /// not valid Haskell: every copy after the first is a parse error) is
    /// the only one that reaches 256; on it
    /// the whole-file captures agree at 256, 1024 and 4096, but one 19 KB
    /// window in six differs between 256 and 1024. Every other grammar
    /// never reaches the cap, where it changes nothing.
    ///
    /// 1024 keeps the worst measured query under half a second and leaves
    /// four times the room of 256. Whether a real file of any language
    /// reaches it is not known.
    pub const max_match_limit: u32 = 1024;

    /// A cursor whose pool is capped at `max_match_limit`.
    pub fn init() error{OutOfMemory}!*QueryCursor {
        const c = ts_query_cursor_new() orelse return error.OutOfMemory;
        ts_query_cursor_set_match_limit(c, max_match_limit);
        return c;
    }
    pub fn didExceedMatchLimit(c: *const QueryCursor) bool {
        return ts_query_cursor_did_exceed_match_limit(c);
    }
    pub fn deinit(c: *QueryCursor) void {
        ts_query_cursor_delete(c);
    }
    pub fn exec(c: *QueryCursor, q: *const Query, node: Node) void {
        ts_query_cursor_exec(c, q, node);
    }
    pub fn setByteRange(c: *QueryCursor, start: u32, end: u32) bool {
        return ts_query_cursor_set_byte_range(c, start, end);
    }
    pub fn nextMatch(c: *QueryCursor) ?QueryMatch {
        var m: QueryMatch = undefined;
        return if (ts_query_cursor_next_match(c, &m)) m else null;
    }
    /// Captures in document order. Returns the match plus which capture within it.
    pub fn nextCapture(c: *QueryCursor, capture_index: *u32) ?QueryMatch {
        var m: QueryMatch = undefined;
        return if (ts_query_cursor_next_capture(c, &m, capture_index)) m else null;
    }
};

// ── externs ──────────────────────────────────────────────────────────────────

pub extern fn ts_parser_new() ?*Parser;
pub extern fn ts_parser_delete(self: *Parser) void;
pub extern fn ts_parser_set_language(self: *Parser, language: *const Language) bool;
pub extern fn ts_parser_set_included_ranges(self: *Parser, ranges: [*]const Range, count: u32) bool;
pub extern fn ts_parser_parse_string(self: *Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32) ?*Tree;
pub extern fn ts_parser_reset(self: *Parser) void;

pub extern fn ts_tree_copy(self: *const Tree) *Tree;
pub extern fn ts_tree_delete(self: *Tree) void;
pub extern fn ts_tree_root_node(self: *const Tree) Node;
pub extern fn ts_tree_language(self: *const Tree) *const Language;
pub extern fn ts_tree_edit(self: *Tree, edit: *const InputEdit) void;

pub extern fn ts_node_type(self: Node) [*:0]const u8;
pub extern fn ts_node_start_byte(self: Node) u32;
pub extern fn ts_node_end_byte(self: Node) u32;
pub extern fn ts_node_start_point(self: Node) Point;
pub extern fn ts_node_end_point(self: Node) Point;
pub extern fn ts_node_string(self: Node) [*:0]u8;
pub extern fn ts_node_is_null(self: Node) bool;
pub extern fn ts_node_is_named(self: Node) bool;
pub extern fn ts_node_is_error(self: Node) bool;
pub extern fn ts_node_has_error(self: Node) bool;
pub extern fn ts_node_parent(self: Node) Node;
pub extern fn ts_node_child(self: Node, child_index: u32) Node;
pub extern fn ts_node_child_count(self: Node) u32;
pub extern fn ts_node_named_child(self: Node, child_index: u32) Node;
pub extern fn ts_node_named_child_count(self: Node) u32;
pub extern fn ts_node_next_sibling(self: Node) Node;
pub extern fn ts_node_prev_sibling(self: Node) Node;
pub extern fn ts_node_next_named_sibling(self: Node) Node;
pub extern fn ts_node_child_by_field_name(self: Node, name: [*]const u8, name_length: u32) Node;
pub extern fn ts_node_named_descendant_for_byte_range(self: Node, start: u32, end: u32) Node;
pub extern fn ts_node_descendant_for_byte_range(self: Node, start: u32, end: u32) Node;

pub extern fn ts_tree_cursor_new(node: Node) TreeCursor;
pub extern fn ts_tree_cursor_delete(self: *TreeCursor) void;
pub extern fn ts_tree_cursor_current_node(self: *const TreeCursor) Node;
pub extern fn ts_tree_cursor_goto_first_child(self: *TreeCursor) bool;
pub extern fn ts_tree_cursor_goto_next_sibling(self: *TreeCursor) bool;
pub extern fn ts_tree_cursor_goto_parent(self: *TreeCursor) bool;

pub extern fn ts_query_new(language: *const Language, source: [*]const u8, source_len: u32, error_offset: *u32, error_type: *QueryError) ?*Query;
pub extern fn ts_query_delete(self: *Query) void;
pub extern fn ts_query_pattern_count(self: *const Query) u32;
pub extern fn ts_query_capture_count(self: *const Query) u32;
pub extern fn ts_query_string_count(self: *const Query) u32;
pub extern fn ts_query_capture_name_for_id(self: *const Query, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_string_value_for_id(self: *const Query, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_predicates_for_pattern(self: *const Query, pattern_index: u32, step_count: *u32) [*]const QueryPredicateStep;

pub extern fn ts_query_cursor_new() ?*QueryCursor;
pub extern fn ts_query_cursor_delete(self: *QueryCursor) void;
pub extern fn ts_query_cursor_exec(self: *QueryCursor, query: *const Query, node: Node) void;
pub extern fn ts_query_cursor_set_match_limit(self: *QueryCursor, limit: u32) void;
pub extern fn ts_query_cursor_did_exceed_match_limit(self: *const QueryCursor) bool;
pub extern fn ts_query_cursor_set_byte_range(self: *QueryCursor, start_byte: u32, end_byte: u32) bool;
pub extern fn ts_query_cursor_next_match(self: *QueryCursor, match: *QueryMatch) bool;
pub extern fn ts_query_cursor_next_capture(self: *QueryCursor, match: *QueryMatch, capture_index: *u32) bool;

pub extern fn ts_language_abi_version(self: *const Language) u32;
pub extern fn ts_language_name(self: *const Language) ?[*:0]const u8;
pub extern fn ts_language_symbol_count(self: *const Language) u32;

/// tree-sitter hands out `malloc`ed strings (`ts_node_string`); release them with the
/// runtime's own `free` so a custom allocator set via `ts_set_allocator` stays paired.
extern "c" fn free(ptr: ?*anyopaque) void;
fn ts_free(ptr: [*]u8) void {
    free(@ptrCast(ptr));
}

// ── tests (runtime only; grammar coverage lives in src/highlight) ───────────

test "by-value struct layouts match api.h on a 64-bit target" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Node));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(QueryCapture));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(QueryMatch));
}

test "parser without a language yields no tree" {
    const p = try Parser.init();
    defer p.deinit();
    try std.testing.expect(p.parseString(null, "x") == null);
}
