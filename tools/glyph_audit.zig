//! `zig build glyph-audit` — every Nerd Font glyph literal in `src/`
//! against the official glyph names, with its ASCII fallback beside it.
//!
//! Two subcommands, chained by the build:
//!
//!   glyph-audit bake  <nerd-glyphnames.json> <table.tsv>
//!   glyph-audit audit <table.tsv> <src dir> [--strict]
//!
//! `bake` turns ryanoasis/nerd-fonts' `glyphnames.json` (545 KB,
//! `data/nerd-glyphnames.json`, refresh with `curl -L
//! https://raw.githubusercontent.com/ryanoasis/nerd-fonts/HEAD/glyphnames.json`)
//! into a compact `<hex>\t<name>` table sorted by codepoint. `audit`
//! walks `*.zig`, finds `\u{XXXX}` escapes in the private-use planes
//! (the ranges Nerd Fonts occupy, plus mnml's own F1B00–F20FF block)
//! and prints one line per site:
//!
//!   src/ui/chip.zig:30  U+F0DC   fa-sort               ascii: "~"
//!
//! The fallback is read off the site the way the code spells it: a
//! `<x>_nerd` / `<x>_glyph` (or `<x>_codicon`) constant with an `<x>_ascii` sibling, a
//! `.fallback = "…"` on the line, or the string an `ascii` branch
//! yields on the line (`if (ui.ascii) "=" else "\u{…}"`). Assertion
//! lines (`expect…`) and anything inside a `test "…" { … }` block are
//! tests of a glyph, not sites, and are listed as such. `--strict` exits 1 on a site with no fallback or a
//! codepoint the catalog does not know; the unit test walks the real
//! `src/` and asserts the same, so a new glyph without its `--ascii`
//! twin fails `zig build test`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buf: [8192]u8 = undefined;
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const w = &stdout_file.interface;
    defer w.flush() catch {};
    if (args.len >= 4 and std.mem.eql(u8, args[1], "bake")) {
        const json = try Io.Dir.cwd().readFileAlloc(init.io, args[2], arena, .unlimited);
        const catalog = try parseCatalog(arena, json);
        var out: Io.Writer.Allocating = .init(arena);
        try bakeTable(&out.writer, catalog);
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = out.written() });
        try w.print("glyph-audit: {d} glyphs → {s}\n", .{ catalog.len, args[3] });
        return 0;
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "audit")) {
        var strict = false;
        const tsv = try Io.Dir.cwd().readFileAlloc(init.io, args[2], arena, .unlimited);
        const table = try loadTable(arena, tsv);
        // Every tree named, not just one: the pane toolkit and the
        // official integrations carry glyphs of their own, and a glyph
        // with no ascii twin is exactly as broken there as in `src/`.
        var sites: std.ArrayList(Site) = .empty;
        for (args[3..]) |a| {
            if (std.mem.eql(u8, a, "--strict")) {
                strict = true;
                continue;
            }
            try sites.appendSlice(arena, try walk(arena, init.io, a));
        }
        const summary = try report(w, sites.items, table);
        try w.print("glyph-audit: {d} sites, {d} tests, {d} without a fallback, {d} unknown to the catalog\n", .{ summary.sites, summary.tests, summary.no_fallback, summary.unknown });
        return if (strict and (summary.no_fallback > 0 or summary.unknown > 0)) 1 else 0;
    }
    try w.writeAll("usage: glyph-audit bake <glyphnames.json> <table.tsv> | audit <table.tsv> <src dir>… [--strict]\n");
    return 2;
}

// ─── the catalog ────────────────────────────────────────────────────────

pub const Glyph = struct { codepoint: u21, name: []const u8 };

/// `glyphnames.json`: `{"METADATA":{…},"cod-account":{"char":"…","code":"eb99"},…}`.
pub fn parseCatalog(arena: Allocator, json: []const u8) ![]Glyph {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const obj = switch (root) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    var out: std.ArrayListUnmanaged(Glyph) = .empty;
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "METADATA")) continue;
        const entry = switch (kv.value_ptr.*) {
            .object => |e| e,
            else => continue,
        };
        const code = switch (entry.get("code") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const cp = std.fmt.parseInt(u21, code, 16) catch continue;
        try out.append(arena, .{ .codepoint = cp, .name = kv.key_ptr.* });
    }
    std.mem.sort(Glyph, out.items, {}, struct {
        fn lt(_: void, a: Glyph, b: Glyph) bool {
            return a.codepoint < b.codepoint;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// `<hex>\t<name>\n`, ascending.
pub fn bakeTable(w: *Io.Writer, catalog: []const Glyph) Io.Writer.Error!void {
    for (catalog) |g| try w.print("{x}\t{s}\n", .{ g.codepoint, g.name });
}

pub const Table = std.AutoHashMapUnmanaged(u21, []const u8);

pub fn loadTable(arena: Allocator, tsv: []const u8) Allocator.Error!Table {
    var table: Table = .empty;
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const cp = std.fmt.parseInt(u21, line[0..tab], 16) catch continue;
        try table.put(arena, cp, line[tab + 1 ..]);
    }
    return table;
}

// ─── the sites ──────────────────────────────────────────────────────────

pub const Kind = enum { site, @"test" };

pub const Site = struct {
    file: []const u8,
    /// 1-based.
    line: u32,
    codepoint: u21,
    kind: Kind,
    /// The ASCII twin the code paints under `--ascii`; null when none was found.
    fallback: ?[]const u8,
};

/// mnml's own baked block (Rust's `BUILTIN_GLYPHS` range).
pub const mnml_block_start: u21 = 0xF1B00;
pub const mnml_block_end: u21 = 0xF20FF;

/// The private-use planes a Nerd Font glyph lives in.
pub fn isPrivateUse(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD) or (cp >= 0x100000 and cp <= 0x10FFFD);
}

/// Every `\u{XXXX}` in `text` whose codepoint is private-use.
pub fn extractSites(arena: Allocator, file: []const u8, text: []const u8) Allocator.Error![]Site {
    var out: std.ArrayListUnmanaged(Site) = .empty;
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(arena, l);
    var in_test = false;
    for (lines.items, 0..) |line, i| {
        // A `test "…" {` block at column zero, to its closing `}` at
        // column zero: everything in it is a fixture, not a painted
        // site. `zig fmt` guarantees both, and without this a test's
        // own expected string — or a `const x = (try colOfText(…))`
        // helper — reads as a glyph shipped with no twin.
        if (in_test) {
            if (line.len > 0 and line[0] == '}') in_test = false;
        } else if (std.mem.startsWith(u8, line, "test ")) {
            in_test = true;
        }
        var rest = line;
        while (std.mem.indexOf(u8, rest, "\\u{")) |at| {
            rest = rest[at + 3 ..];
            const end = std.mem.indexOfScalar(u8, rest, '}') orelse break;
            const hex = rest[0..end];
            if (hex.len == 0 or hex.len > 6) continue;
            const cp = std.fmt.parseInt(u21, hex, 16) catch continue;
            if (!isPrivateUse(cp)) continue;
            const kind: Kind = if (in_test or isAssertion(line)) .@"test" else .site;
            try out.append(arena, .{
                .file = file,
                .line = @intCast(i + 1),
                .codepoint = cp,
                .kind = kind,
                .fallback = if (kind == .site) fallbackFor(lines.items, i) else null,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// `try f.expectRow(…)`, `try testing.expectEqualStrings(…)` and kin.
fn isAssertion(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "try ") and std.mem.indexOf(u8, trimmed, "expect") != null;
}

/// The fallback the code spells for the site on line `i`, by the three
/// idioms the codebase uses.
pub fn fallbackFor(lines: []const []const u8, i: usize) ?[]const u8 {
    const line = lines[i];
    // `.fallback = "B"` on the line (a config entry).
    if (std.mem.indexOf(u8, line, ".fallback = ")) |at| return stringAt(line[at + ".fallback = ".len ..]);
    // `pub const sort_icon_nerd = "…";` with `sort_icon_ascii` in the file.
    if (constName(line)) |name| {
        const stem = if (std.mem.endsWith(u8, name, "_nerd")) name[0 .. name.len - "_nerd".len] else if (std.mem.endsWith(u8, name, "_glyph")) name[0 .. name.len - "_glyph".len] else if (std.mem.endsWith(u8, name, "_codicon")) name else null;
        if (stem) |s| {
            for (lines) |other| {
                const oname = constName(other) orelse continue;
                if (oname.len == s.len + "_ascii".len and std.mem.startsWith(u8, oname, s) and std.mem.endsWith(u8, oname, "_ascii")) {
                    const eq = std.mem.indexOf(u8, other, "= ") orelse continue;
                    return stringAt(other[eq + 2 ..]);
                }
            }
        }
    }
    // `if (ui.ascii) "=" else "\u{…}"`: the first string after `ascii`.
    if (std.mem.indexOf(u8, line, "ascii")) |at| return stringAt(line[at + "ascii".len ..]);
    return null;
}

/// `pub const name =` / `const name =` → `name`.
fn constName(line: []const u8) ?[]const u8 {
    var s = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, s, "pub ")) s = s[4..];
    if (!std.mem.startsWith(u8, s, "const ")) return null;
    s = s["const ".len..];
    const end = std.mem.indexOfAny(u8, s, " =:") orelse return null;
    return s[0..end];
}

/// The first `"…"` literal in `s`, unescaped enough for a glyph twin.
fn stringAt(s: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    var i = open + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return s[open + 1 .. i];
    }
    return null;
}

/// Every `.zig` under `root`, sorted, and its sites. Paths are
/// `root`-relative.
pub fn walk(arena: Allocator, io: Io, root: []const u8) ![]Site {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        // The auditor's own files carry glyph literals as test fixtures,
        // not as painted sites.
        if (std.mem.eql(u8, entry.basename, "glyph_audit.zig")) continue;
        try files.append(arena, try slashed(arena, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayListUnmanaged(Site) = .empty;
    for (files.items) |rel| {
        const text = try dir.readFileAlloc(io, rel, arena, .unlimited);
        try out.appendSlice(arena, try extractSites(arena, rel, text));
    }
    return out.toOwnedSlice(arena);
}

pub const Summary = struct { sites: usize = 0, tests: usize = 0, no_fallback: usize = 0, unknown: usize = 0 };

/// `nameOf`: the catalog's name, `mnml-private` for the baked block,
/// `unknown` otherwise.
pub fn nameOf(table: Table, cp: u21) []const u8 {
    if (table.get(cp)) |n| return n;
    if (cp >= mnml_block_start and cp <= mnml_block_end) return "mnml-private";
    return "unknown";
}

pub fn report(w: *Io.Writer, sites: []const Site, table: Table) Io.Writer.Error!Summary {
    var s: Summary = .{};
    for (sites) |site| {
        const name = nameOf(table, site.codepoint);
        const unknown = std.mem.eql(u8, name, "unknown");
        switch (site.kind) {
            .@"test" => {
                s.tests += 1;
                try w.print("{s}:{d}  U+{X:0>4}  {s}  (test)\n", .{ site.file, site.line, site.codepoint, name });
            },
            .site => {
                s.sites += 1;
                if (unknown) s.unknown += 1;
                if (site.fallback) |f| {
                    try w.print("{s}:{d}  U+{X:0>4}  {s}  ascii: \"{s}\"\n", .{ site.file, site.line, site.codepoint, name, f });
                } else {
                    s.no_fallback += 1;
                    try w.print("{s}:{d}  U+{X:0>4}  {s}  ascii: NONE\n", .{ site.file, site.line, site.codepoint, name });
                }
            },
        }
    }
    return s;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "bake: the JSON becomes a sorted hex/name table that loads back" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\{"METADATA":{"version":"3.5.1"},"cod-refresh":{"char":"x","code":"eb37"},"fa-sort":{"char":"y","code":"f0dc"},"md-magnify":{"char":"z","code":"f0349"},"junk":{"nope":1}}
    ;
    const cat = try parseCatalog(a, json);
    try t.expectEqual(@as(usize, 3), cat.len);
    try t.expectEqual(@as(u21, 0xeb37), cat[0].codepoint);
    try t.expectEqualStrings("md-magnify", cat[2].name);
    var out: Io.Writer.Allocating = .init(a);
    try bakeTable(&out.writer, cat);
    try t.expectEqualStrings("eb37\tcod-refresh\nf0dc\tfa-sort\nf0349\tmd-magnify\n", out.written());
    const table = try loadTable(a, out.written());
    try t.expectEqualStrings("fa-sort", nameOf(table, 0xf0dc));
    try t.expectEqualStrings("mnml-private", nameOf(table, 0xF1E00));
    try t.expectEqualStrings("unknown", nameOf(table, 0xE099));
}

test "sites: the three fallback idioms, an assertion is a test, non-PUA and format escapes are not sites" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\pub const sort_icon_nerd = "\u{f0dc}";
        \\pub const sort_icon_ascii = "~";
        \\pub const glyph_nerd = "\u{F0349}";
        \\pub const glyph_ascii = "/";
        \\    .{ .id = "browser", .glyph = "\u{EB01}", .fallback = "B", .command = "browser.open" },
        \\    const tree_glyph: []const u8 = if (ui.ascii) " = " else " \u{f1e00} ";
        \\    const box = if (uictx.ascii or !uictx.nerd_font) (if (row.done) "[x] " else "[ ] ") else (if (row.done) "\u{f14a} " else "\u{f0c8} ");
        \\    try f.expectRow(0, " TODOS   \u{f0dc}   \u{eb37}");
        \\pub const marker_glyph = "\u{258c}";
        \\            0...8 => try self.out.print("\\u{x:0>4}", .{c}),
        \\    const lonely = "\u{e0b0}";
        \\test "a fixture is not a site" {
        \\    const merge_x = colOf("[\u{f062d} Merge]");
        \\}
    ;
    const sites = try extractSites(a, "x.zig", src);
    try t.expectEqual(@as(usize, 10), sites.len);
    try t.expectEqualStrings("~", sites[0].fallback.?);
    try t.expectEqual(@as(u32, 1), sites[0].line);
    try t.expectEqualStrings("/", sites[1].fallback.?);
    try t.expectEqualStrings("B", sites[2].fallback.?);
    try t.expectEqualStrings(" = ", sites[3].fallback.?);
    try t.expectEqualStrings("[x] ", sites[4].fallback.?);
    try t.expectEqualStrings("[x] ", sites[5].fallback.?);
    try t.expectEqual(Kind.@"test", sites[6].kind);
    try t.expectEqual(Kind.@"test", sites[7].kind);
    try t.expectEqual(@as(u21, 0xe0b0), sites[8].codepoint);
    try t.expect(sites[8].fallback == null);
    // Inside a `test "…" { … }` block: a fixture, whatever the line
    // looks like. Without this the assertion heuristic alone lets a
    // `const x = …` helper in a test read as a glyph with no twin.
    try t.expectEqual(Kind.@"test", sites[9].kind);
    var out: Io.Writer.Allocating = .init(a);
    const table = try loadTable(a, "f0dc\tfa-sort\n");
    const s = try report(&out.writer, sites, table);
    try t.expectEqual(@as(usize, 7), s.sites);
    try t.expectEqual(@as(usize, 3), s.tests);
    try t.expectEqual(@as(usize, 1), s.no_fallback);
    try t.expect(std.mem.indexOf(u8, out.written(), "x.zig:1  U+F0DC  fa-sort  ascii: \"~\"") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "x.zig:11  U+E0B0  unknown  ascii: NONE") != null);
}

test "every audited site in src/, the SDK and integrations/ has its --ascii twin and a name the catalog knows" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json = try Io.Dir.cwd().readFileAlloc(t.io, build_options.glyph_json, a, .unlimited);
    const cat = try parseCatalog(a, json);
    try t.expect(cat.len > 5000);
    var baked: Io.Writer.Allocating = .init(a);
    try bakeTable(&baked.writer, cat);
    const table = try loadTable(a, baked.written());
    // The same three trees `zig build glyph-audit` walks. A chip in an
    // official integration is as much of the shipped screen as mnml's
    // own chrome, so a glyph there with no twin fails the suite too.
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    for ([_][]const u8{ build_options.src_root, build_options.sdk_root, build_options.integrations_root }) |root| {
        try sites.appendSlice(a, try walk(a, t.io, root));
    }
    var out: Io.Writer.Allocating = .init(a);
    const s = try report(&out.writer, sites.items, table);
    try t.expect(s.sites > 0);
    if (s.no_fallback > 0 or s.unknown > 0) std.debug.print("\n{s}\n", .{out.written()});
    try t.expectEqual(@as(usize, 0), s.no_fallback);
    try t.expectEqual(@as(usize, 0), s.unknown);
}

/// A walked path with `/` between its parts, the way the owner lists and
/// the report spell them; Windows' walker hands back `\`.
fn slashed(arena: Allocator, path: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}
