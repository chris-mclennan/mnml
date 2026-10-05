//! Syntax highlighting: the tree-sitter language table and the embedded queries.
//!
//! The tests below are the Phase-0 gate for tree-sitter-from-Zig — every language in the
//! table has to load, every query has to compile, and every fixture has to parse cleanly.

const std = @import("std");
pub const ts = @import("tree_sitter");
pub const queries = @import("ts_queries");
pub const table = @import("table.zig");
pub const engine = @import("engine.zig");
pub const role = @import("role.zig");
pub const predicate = @import("predicate.zig");
pub const pattern = @import("pattern.zig");
pub const structure = @import("structure.zig");
pub const detect = @import("detect.zig");
pub const Highlighter = engine.Highlighter;
pub const Role = role.Role;

const testing = std.testing;

test "every language loads with an ABI this runtime accepts" {
    for (table.entries) |e| {
        const lang = e.language();
        if (!lang.isCompatible()) {
            std.debug.print("{s}: grammar ABI {d} outside [{d}, {d}]\n", .{ e.key, lang.abiVersion(), ts.min_compatible_language_version, ts.language_version });
            return error.IncompatibleGrammar;
        }
        try testing.expect(lang.symbolCount() > 0);
    }
}

test "every highlights query compiles" {
    for (table.entries, 0..) |e, i| {
        try expectQueryCompiles(e.key, "highlights", e.language(), table.highlightSource(i));
    }
}

test "every injections query compiles" {
    for (table.entries, 0..) |e, i| {
        if (e.injections.len == 0) continue;
        try expectQueryCompiles(e.key, "injections", e.language(), table.injectionSource(i));
    }
}

fn expectQueryCompiles(key: []const u8, kind: []const u8, lang: *const ts.Language, source: []const u8) !void {
    var failure: ts.Query.Failure = undefined;
    const query = ts.Query.init(lang, source, &failure) catch |err| {
        const start = failure.offset;
        const end = @min(source.len, start + 60);
        std.debug.print("{s}: {s} query failed at byte {d} ({s}): {s}\n  near: {s}\n", .{ key, kind, start, @tagName(failure.err), @errorName(err), source[@min(start, source.len)..end] });
        return err;
    };
    defer query.deinit();
    try testing.expect(query.patternCount() > 0);
    try testing.expect(query.captureCount() > 0);
}

test "every fixture parses without an ERROR node" {
    const parser = try ts.Parser.init();
    defer parser.deinit();
    for (table.entries) |e| {
        try parser.setLanguage(e.language());
        const tree = parser.parseString(null, e.fixture) orelse {
            std.debug.print("{s}: parse returned no tree\n", .{e.key});
            return error.NoTree;
        };
        defer tree.deinit();
        const root = tree.rootNode();
        if (root.hasError()) {
            const s = root.sexp();
            defer ts.Node.freeSexp(s);
            std.debug.print("{s}: fixture parsed with errors:\n  {s}\n", .{ e.key, s });
            return error.FixtureHasError;
        }
        try testing.expectEqual(@as(u32, @intCast(e.fixture.len)), root.endByte());
    }
}

test "parseCancelable: the tree parseString builds, read in place; told to stop, it stops" {
    const gpa = testing.allocator;
    const e = table.entries[table.find("rs").?];
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    while (text.items.len < 256 * 1024) try text.appendSlice(gpa, e.fixture);
    const parser = try ts.Parser.init();
    defer parser.deinit();
    try parser.setLanguage(e.language());
    const plain = parser.parseString(null, text.items).?;
    defer plain.deinit();
    const Ctx = struct {
        asked: usize = 0,
        stop_after: usize,
        fn keepGoing(p: ?*anyopaque) bool {
            const c: *@This() = @ptrCast(@alignCast(p.?));
            c.asked += 1;
            return c.asked <= c.stop_after;
        }
    };
    var go: Ctx = .{ .stop_after = std.math.maxInt(usize) };
    const same = parser.parseCancelable(null, text.items, &go, Ctx.keepGoing).?;
    defer same.deinit();
    const a = plain.rootNode().sexp();
    defer ts.Node.freeSexp(a);
    const b = same.rootNode().sexp();
    defer ts.Node.freeSexp(b);
    try testing.expectEqualStrings(a, b);
    try testing.expect(go.asked > 0);
    // Refused part-way: no tree, and the parser is usable again after a reset.
    var stop: Ctx = .{ .stop_after = 2 };
    try testing.expect(parser.parseCancelable(null, text.items, &stop, Ctx.keepGoing) == null);
    parser.reset();
    const again = parser.parseString(null, e.fixture).?;
    again.deinit();
}

test "highlights queries produce captures on their fixtures" {
    const parser = try ts.Parser.init();
    defer parser.deinit();
    const cursor = try ts.QueryCursor.init();
    defer cursor.deinit();
    for (table.entries, 0..) |e, i| {
        try parser.setLanguage(e.language());
        const tree = parser.parseString(null, e.fixture) orelse return error.NoTree;
        defer tree.deinit();
        const query = try ts.Query.init(e.language(), table.highlightSource(i), null);
        defer query.deinit();
        cursor.exec(query, tree.rootNode());
        var captures: usize = 0;
        while (cursor.nextMatch()) |m| captures += m.capture_count;
        if (captures == 0) {
            std.debug.print("{s}: highlights query matched nothing on its fixture\n", .{e.key});
            return error.NoCaptures;
        }
    }
}

test "layering: js = js + extra, ts = js + extra + ts, tsx = js + jsx + extra + ts, jsx = js + jsx + extra" {
    // mnml's own `javascript.extra.scm` (decorators) sits after the crate's
    // JavaScript query — and after the JSX one — on every JavaScript-family
    // key, and before TypeScript's.
    const js = table.highlightSource(table.find("js").?);
    const ts_src = table.highlightSource(table.find("ts").?);
    const tsx = table.highlightSource(table.find("tsx").?);
    const jsx = table.highlightSource(table.find("jsx").?);
    try testing.expectEqualStrings(queries.javascript_highlights ++ "\n" ++ queries.javascript_highlights_extra, js);
    try testing.expect(std.mem.startsWith(u8, ts_src, js));
    try testing.expect(std.mem.endsWith(u8, ts_src, queries.typescript_highlights));
    const js_plus_jsx = queries.javascript_highlights ++ "\n" ++ queries.javascript_highlights_jsx ++ "\n" ++ queries.javascript_highlights_extra;
    try testing.expect(std.mem.startsWith(u8, tsx, js_plus_jsx));
    try testing.expect(std.mem.endsWith(u8, tsx, queries.typescript_highlights));
    try testing.expectEqualStrings(js_plus_jsx, jsx);
    try testing.expect(std.mem.indexOf(u8, queries.javascript_highlights_extra, "(decorator") != null);
    // The interface grammar shares ocaml's query whole: it names no node the interface
    // grammar lacks (the crate dropped `shebang` from it). The two Markdown grammars have
    // distinct queries.
    const ocaml = table.highlightSource(table.find("ocaml").?);
    const mli = table.highlightSource(table.find("mli").?);
    try testing.expectEqualStrings(ocaml, mli);
    try testing.expect(std.mem.indexOf(u8, mli, "shebang") == null);
    try testing.expect(std.mem.indexOf(u8, mli, "(line_number_directive) (directive)] @comment") != null);
    try testing.expect(!std.mem.eql(u8, table.highlightSource(table.find("md").?), table.highlightSource(table.find("markdown_inline").?)));
}

test "extension, filename and injection-name lookups" {
    try testing.expectEqualStrings("js", table.keyForExtension("mjs").?);
    try testing.expectEqualStrings("ts", table.keyForExtension("cts").?);
    try testing.expectEqualStrings("cpp", table.keyForExtension("hxx").?);
    try testing.expectEqualStrings("dockerfile", table.keyForExtension("containerfile").?);
    try testing.expect(table.keyForExtension("xyz") == null);

    try testing.expectEqualStrings("make", table.keyForFilename("GNUmakefile").?);
    try testing.expectEqualStrings("rb", table.keyForFilename("Gemfile").?);
    try testing.expectEqualStrings("sh", table.keyForFilename(".envrc").?);
    try testing.expectEqualStrings("dockerfile", table.keyForFilename("Dockerfile.dev").?);
    try testing.expect(table.keyForFilename("main.rs") == null);

    try testing.expectEqualStrings("markdown_inline", table.keyForLanguageName("Markdown-Inline").?);
    try testing.expectEqualStrings("sh", table.keyForLanguageName(" console\n").?);
    try testing.expectEqualStrings("cs", table.keyForLanguageName("C#").?);
    try testing.expectEqualStrings("mli", table.keyForLanguageName("ocaml_interface").?);
    try testing.expect(table.keyForLanguageName("") == null);
    try testing.expect(table.keyForLanguageName("brainfuck") == null);

    // Every table key resolves to itself.
    for (table.entries, 0..) |e, i| try testing.expectEqual(i, table.find(e.key).?);
}

test {
    _ = queries;
    _ = engine;
    _ = role;
    _ = predicate;
    _ = pattern;
    _ = structure;
}
