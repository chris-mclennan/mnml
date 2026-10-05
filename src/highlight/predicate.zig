//! Query predicates. tree-sitter's runtime records `(#eq? …)`,
//! `(#any-of? …)`, `(#match? …)` and `(#set! …)` per pattern but never
//! evaluates them — that is the caller's job. `Table.build` compiles a
//! query's predicate steps once; `Table.pass` answers "does this match
//! survive its predicates" and `Table.settings` hands back the `#set!`
//! properties the injection queries carry (`injection.language`, …).
//!
//! An unknown or uncompilable predicate makes its pattern fail closed:
//! a capture is dropped rather than painted with the wrong role.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree_sitter");
const pattern = @import("pattern.zig");

pub const Settings = struct {
    injection_language: ?[]const u8 = null,
    combined: bool = false,
    include_children: bool = false,
};

const Pred = union(enum) {
    /// `#eq? @cap "lit"` (or `#not-eq?`).
    eq: struct { capture: u32, value: []const u8, negate: bool },
    /// `#eq? @a @b`.
    eq_capture: struct { a: u32, b: u32, negate: bool },
    /// `#any-of? @cap "a" "b" …` (or `#not-any-of?`).
    any_of: struct { capture: u32, values: []const []const u8, negate: bool },
    /// `#match?` / `#lua-match?` (and their `not-` forms).
    match: struct { capture: u32, pat: *pattern.Pattern, negate: bool },
    /// Anything else: the pattern never matches.
    unsupported,
};

pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    /// Per pattern index.
    preds: []const []const Pred,
    props: []const Settings,

    pub fn build(gpa: Allocator, q: *const ts.Query) Allocator.Error!Table {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const n = q.patternCount();
        const preds = try a.alloc([]const Pred, n);
        const props = try a.alloc(Settings, n);
        var pi: u32 = 0;
        while (pi < n) : (pi += 1) {
            var list: std.ArrayListUnmanaged(Pred) = .empty;
            var props_for: Settings = .{};
            const steps = q.predicatesForPattern(pi);
            var i: usize = 0;
            while (i < steps.len) {
                // One predicate: steps up to the next `.done`.
                var j = i;
                while (j < steps.len and steps[j].type != .done) j += 1;
                const group = steps[i..j];
                i = j + 1;
                if (group.len == 0) continue;
                if (group[0].type != .string) {
                    try list.append(a, .unsupported);
                    continue;
                }
                const name = q.stringValue(group[0].value_id);
                const args = group[1..];
                if (std.mem.eql(u8, name, "set!")) {
                    applySetting(q, args, &props_for);
                    continue;
                }
                if (try compile(a, q, name, args)) |p| try list.append(a, p);
            }
            preds[pi] = list.items;
            props[pi] = props_for;
        }
        return .{ .arena = arena, .preds = preds, .props = props };
    }

    pub fn deinit(t: *Table) void {
        t.arena.deinit();
    }

    pub fn settings(t: *const Table, pattern_index: u32) Settings {
        return t.props[pattern_index];
    }

    /// True when every predicate on the match's pattern holds for `text`.
    pub fn pass(t: *const Table, m: *const ts.QueryMatch, text: []const u8) bool {
        for (t.preds[m.pattern_index]) |p| {
            const ok = switch (p) {
                .unsupported => false,
                .eq => |e| blk: {
                    const s = captureText(m, e.capture, text) orelse break :blk false;
                    break :blk std.mem.eql(u8, s, e.value) != e.negate;
                },
                .eq_capture => |e| blk: {
                    const sa = captureText(m, e.a, text) orelse break :blk false;
                    const sb = captureText(m, e.b, text) orelse break :blk false;
                    break :blk std.mem.eql(u8, sa, sb) != e.negate;
                },
                .any_of => |e| blk: {
                    const s = captureText(m, e.capture, text) orelse break :blk false;
                    var hit = false;
                    for (e.values) |v| if (std.mem.eql(u8, v, s)) {
                        hit = true;
                        break;
                    };
                    break :blk hit != e.negate;
                },
                .match => |e| blk: {
                    const s = captureText(m, e.capture, text) orelse break :blk false;
                    break :blk e.pat.matches(s) != e.negate;
                },
            };
            if (!ok) return false;
        }
        return true;
    }
};

/// The text of the first node captured as `index` in `m`.
pub fn captureText(m: *const ts.QueryMatch, index: u32, text: []const u8) ?[]const u8 {
    for (m.slice()) |c| if (c.index == index) {
        const s = c.node.startByte();
        const e = c.node.endByte();
        if (e < s or e > text.len) return null;
        return text[s..e];
    };
    return null;
}

/// The first node captured as `index` in `m`.
pub fn captureNode(m: *const ts.QueryMatch, index: u32) ?ts.Node {
    for (m.slice()) |c| if (c.index == index) return c.node;
    return null;
}

fn applySetting(q: *const ts.Query, args: []const ts.QueryPredicateStep, s: *Settings) void {
    if (args.len == 0 or args[0].type != .string) return;
    const key = q.stringValue(args[0].value_id);
    const value: ?[]const u8 = if (args.len > 1 and args[1].type == .string) q.stringValue(args[1].value_id) else null;
    if (std.mem.eql(u8, key, "injection.language")) {
        s.injection_language = value;
    } else if (std.mem.eql(u8, key, "injection.combined")) {
        s.combined = true;
    } else if (std.mem.eql(u8, key, "injection.include-children")) {
        s.include_children = true;
    }
}

/// Null means the predicate does not constrain matching (nothing to check).
fn compile(a: Allocator, q: *const ts.Query, name: []const u8, args: []const ts.QueryPredicateStep) Allocator.Error!?Pred {
    const negate = std.mem.startsWith(u8, name, "not-");
    const base = if (negate) name[4..] else name;
    if (std.mem.eql(u8, base, "eq?")) {
        if (args.len != 2 or args[0].type != .capture) return .unsupported;
        if (args[1].type == .capture) return .{ .eq_capture = .{ .a = args[0].value_id, .b = args[1].value_id, .negate = negate } };
        return .{ .eq = .{ .capture = args[0].value_id, .value = q.stringValue(args[1].value_id), .negate = negate } };
    }
    if (std.mem.eql(u8, base, "any-of?")) {
        if (args.len < 1 or args[0].type != .capture) return .unsupported;
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        for (args[1..]) |arg| {
            if (arg.type != .string) return .unsupported;
            try values.append(a, q.stringValue(arg.value_id));
        }
        return .{ .any_of = .{ .capture = args[0].value_id, .values = values.items, .negate = negate } };
    }
    const is_match = std.mem.eql(u8, base, "match?");
    const is_lua = std.mem.eql(u8, base, "lua-match?");
    if (is_match or is_lua) {
        if (args.len != 2 or args[0].type != .capture or args[1].type != .string) return .unsupported;
        const pat = try a.create(pattern.Pattern);
        const source = q.stringValue(args[1].value_id);
        pat.* = pattern.Pattern.compile(a, source, if (is_lua or usesLuaClasses(source)) .lua else .regex) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return .unsupported,
        };
        return .{ .match = .{ .capture = args[0].value_id, .pat = pat, .negate = negate } };
    }
    // `#is?` / `#is-not?` / `#offset!` carry no highlighting meaning.
    if (std.mem.eql(u8, base, "is?") or std.mem.eql(u8, base, "is-not?") or std.mem.endsWith(u8, name, "!")) return null;
    return .unsupported;
}

/// A `#match?` written with Lua's `%d` / `%a` classes — tree-sitter-sequel's
/// number patterns are — is a Lua pattern that says `match?`. No regex
/// dialect has `%` classes, so read as a regex it never matched and every
/// SQL number painted as a string.
fn usesLuaClasses(source: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == '%' and std.mem.indexOfScalar(u8, "adlpsuwxc", source[i + 1]) != null) return true;
    }
    return false;
}

// ── tests ──

const testing = std.testing;
const table = @import("table.zig");

test "a `#match?` in Lua's `%d` classes reads as the Lua pattern it is; a regex stays a regex" {
    try testing.expect(usesLuaClasses("^[-+]?%d+$"));
    try testing.expect(usesLuaClasses("^%a"));
    try testing.expect(!usesLuaClasses("^[A-Z][A-Z_]+$"));
    try testing.expect(!usesLuaClasses("^100%$"));
    try testing.expect(!usesLuaClasses("\\%d"));
}

test "eq / any-of / match predicates decide which identifiers a pattern takes" {
    const idx = table.find("rs").?;
    const lang = table.entries[idx].language();
    const src =
        \\((identifier) @constant (#match? @constant "^[A-Z][A-Z_]+$"))
        \\((identifier) @keyword (#any-of? @keyword "foo" "bar"))
        \\((identifier) @type (#eq? @type "Zed"))
        \\((identifier) @nope (#frobnicate? @nope))
        \\((identifier) @set (#set! injection.language "rust") (#set! injection.combined))
    ;
    const q = try ts.Query.init(lang, src, null);
    defer q.deinit();
    var t = try Table.build(testing.allocator, q);
    defer t.deinit();
    const parser = try ts.Parser.init();
    defer parser.deinit();
    try parser.setLanguage(lang);
    const text = "let MAX_N = foo + Zed + x;";
    const tree = parser.parseString(null, text) orelse return error.NoTree;
    defer tree.deinit();
    const cursor = try ts.QueryCursor.init();
    defer cursor.deinit();
    cursor.exec(q, tree.rootNode());
    var seen: [5]usize = @splat(0);
    while (cursor.nextMatch()) |m| {
        if (t.pass(&m, text)) seen[m.pattern_index] += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen[0]); // MAX_N
    try testing.expectEqual(@as(usize, 1), seen[1]); // foo
    try testing.expectEqual(@as(usize, 1), seen[2]); // Zed
    try testing.expectEqual(@as(usize, 0), seen[3]); // unknown predicate fails closed
    try testing.expectEqual(@as(usize, 4), seen[4]); // #set! constrains nothing
    try testing.expectEqualStrings("rust", t.settings(4).injection_language.?);
    try testing.expect(t.settings(4).combined);
    try testing.expect(t.settings(0).injection_language == null);
}
