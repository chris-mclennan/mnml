//! `zig build chrome-audit` — chrome a component already owns, drawn by
//! hand somewhere else.
//!
//! `src/ui/` is a component layer and `sdk/mnml-sdk/src/pane/` is the
//! toolkit the integrations draw through. The rule the family works to
//! is in `docs/CONVENTIONS.md`: if a thing has a component, draw it
//! through the component; if the component lacks what you need, extend
//! the component — never fork the drawing. A fork compiles, renders,
//! and reviews clean; the only way it is ever found is when someone
//! notices two screens disagreeing.
//!
//! Two rules, both cheap to detect, both shapes that actually shipped:
//!
//!   box-literal   a single box-drawing glyph (U+2500–U+257F: `┌ ┐ └ ┘
//!                 ─ │ ├ ┤ ┬ ┴ ┼ ╭ ╮ ╰ ╯ ┃ …`) as a whole string
//!                 literal, in a file that is not one of the modules
//!                 that OWN box drawing. `src/ui/border.zig` draws every
//!                 frame and every rule; `sdk/…/pane/chrome.zig` draws
//!                 the integrations'. A fourth copy of the same four
//!                 corners is how `integrations/bitbucket` came to have
//!                 a frame with no `--ascii` twin while
//!                 `integrations/jira`'s hand-rolled copy had one.
//!
//!                 The literal must be the WHOLE string: `"├─ token: {s}"`
//!                 in an integration's `--diagnose` output is prose on a
//!                 terminal, not a painted cell, and is not a finding.
//!
//!   ascii-twin    `if (<x>.ascii) "<a>" else "<b>"` where the pair is
//!                 one a component already answers — the ellipsis
//!                 (`clip.ellipsisText` / `Ui.ellipsisText`), the rule
//!                 glyphs (`border.rule` / `Ui.hrule` / `Ui.vrule`) and
//!                 the hint language's pairs (`overlay.hintText`: `·`,
//!                 `←→`, `↑↓`, `⏎`). Nine painters spelled the ellipsis
//!                 pair inline before this rule existed, and nine more
//!                 kept a whole second hint string by hand — and those
//!                 had drifted (`<- ->` beside `<-/->`, `enter` beside
//!                 `Enter`).
//!
//! Comments and `test` blocks are not audited: a test that asserts a
//! frame's corners is reading the component's output, which is exactly
//! what it should do. A true one-off carries
//! `// chrome-audit: allow — <why>` on its line; the marker is the
//! allow-list, so the reason sits beside the shape it excuses.
//!
//! `--strict` exits 1 on any finding; the unit test below walks the real
//! trees and asserts zero, so the next fork fails `zig build unit`
//! rather than shipping.

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
    if (args.len < 2) {
        try w.writeAll("usage: chrome-audit <dir> [<dir>…] [--strict]\n");
        return 2;
    }
    var strict = false;
    var findings: usize = 0;
    var files: usize = 0;
    var literals: usize = 0;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
            continue;
        }
        const r = try walk(arena, init.io, a);
        try report(w, a, r);
        findings += r.findings.len;
        files += r.counts.files;
        literals += r.counts.literals;
    }
    try w.print("chrome-audit: {d} findings over {d} files ({d} string literals inspected)\n", .{ findings, files, literals });
    return if (strict and findings > 0) 1 else 0;
}

// ─── the rules ──────────────────────────────────────────────────────────

pub const Rule = enum {
    box_literal,
    ascii_twin,

    pub fn text(r: Rule) []const u8 {
        return switch (r) {
            .box_literal => "box-literal    draw it through ui/border.zig (frame, rule / Ui.hrule, Ui.vrule) or the SDK's chrome.frameBox / vrule",
            .ascii_twin => "ascii-twin     the component answers this pair: clip.ellipsisText / border.rule / overlay.hintText",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    line: usize,
    rule: Rule,
    expr: []const u8,
};

pub const Counts = struct {
    files: usize = 0,
    literals: usize = 0,
};

pub const Result = struct {
    findings: []const Finding,
    counts: Counts,
};

/// The modules that OWN box drawing. Everything else asks them.
///
/// `border.zig` is the frame + rule component itself. `scrollbar.zig`
/// paints a bar out of `─`/`━`, which is a bar, not a frame.
/// `tree_view.zig` draws the file tree's connectors from mnml's own
/// baked glyphs and falls back to `│`/`└`; `git_graph_view.zig` draws
/// commit lanes (`●─╮`), which no frame helper can express;
/// `md_view.zig` draws a markdown table's rules, whose cell widths come
/// from the table. Each is a shape a frame helper does not have and
/// would not be better for having.
///
/// `sdk/…/pane/chrome.zig` is the same component on the integrations'
/// side of the wire — they cannot import `src/ui/`.
const box_owners = [_][]const u8{
    "ui/border.zig",
    "ui/scrollbar.zig",
    "ui/tree_view.zig",
    "ui/git_graph_view.zig",
    "ui/md_view.zig",
    "pane/chrome.zig",
};

/// The ascii twins a component already answers, as `{ ascii, unicode }`.
const twins = [_]struct { a: []const u8, u: []const u8, owner: []const u8 }{
    .{ .a = "...", .u = "\u{2026}", .owner = "clip.ellipsisText / Ui.ellipsisText" },
    .{ .a = "|", .u = "\u{2502}", .owner = "border.rule(.v) / Ui.vrule" },
    .{ .a = "-", .u = "\u{2500}", .owner = "border.rule(.h) / Ui.hrule" },
    .{ .a = "-", .u = "\u{b7}", .owner = "overlay.hintText" },
    .{ .a = "<- ->", .u = "\u{2190}\u{2192}", .owner = "overlay.hintText" },
    .{ .a = "up/down", .u = "\u{2191}\u{2193}", .owner = "overlay.hintText" },
    .{ .a = "enter", .u = "\u{23ce}", .owner = "overlay.hintText" },
};

/// The files allowed to spell a twin: the component that answers it.
const twin_owners = [_][]const u8{
    "ui/clip.zig",
    "ui/context.zig",
    "ui/border.zig",
    "ui/overlay.zig",
    "ui/scrollbar.zig",
    "ui/md_view.zig",
    "pane/chrome.zig",
};

/// The marker a true one-off carries on its line, with the reason after
/// it. The audit reads the marker off the raw line, so it works inside
/// the comment the rest of the scan strips.
pub const allow_marker = "chrome-audit: allow";

fn owned(path: []const u8, list: []const []const u8) bool {
    for (list) |o| if (std.mem.endsWith(u8, path, o)) return true;
    return false;
}

/// True when `s` is one box-drawing grapheme (U+2500–U+257F) and
/// nothing else.
pub fn isBoxCell(s: []const u8) bool {
    // U+2500–U+257F is three bytes; `utf8Decode` asserts the lead byte
    // agrees with the slice length, so `"abc"` must be turned away first.
    if (s.len != 3) return false;
    if ((std.unicode.utf8ByteSequenceLength(s[0]) catch return false) != 3) return false;
    const cp = std.unicode.utf8Decode(s) catch return false;
    return cp >= 0x2500 and cp <= 0x257F;
}

/// The comment-free part of a line. A `//` inside a string literal is
/// not a comment, so the scan tracks quotes.
fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and in_str) {
            i += 1;
            continue;
        }
        if (c == '"') in_str = !in_str;
        if (!in_str and c == '/' and i + 1 < line.len and line[i + 1] == '/') return line[0..i];
    }
    return line;
}

/// Every `"…"` on a line, contents only, in order.
fn literalsOn(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '"') continue;
        const start = i + 1;
        var j = start;
        while (j < line.len and line[j] != '"') : (j += 1) {
            if (line[j] == '\\') j += 1;
        }
        if (j >= line.len) break;
        try out.append(arena, line[start..j]);
        i = j;
    }
    return out.toOwnedSlice(arena);
}

/// `\u{2026}` written as an escape is the same glyph as the literal one.
fn unescape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, "\\u{") == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 3 < s.len and s[i] == '\\' and s[i + 1] == 'u' and s[i + 2] == '{') {
            const close = std.mem.indexOfScalarPos(u8, s, i + 3, '}') orelse break;
            const cp = std.fmt.parseInt(u21, s[i + 3 .. close], 16) catch {
                i = close + 1;
                continue;
            };
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch {
                i = close + 1;
                continue;
            };
            try out.appendSlice(arena, buf[0..n]);
            i = close + 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// `test "…" {` / `test {` starts a scope the audit does not read.
fn isTestDecl(line: []const u8) bool {
    const s = std.mem.trimStart(u8, line, " ");
    return std.mem.startsWith(u8, s, "test \"") or std.mem.eql(u8, s, "test {");
}

/// A top-level `fn` / `pub fn` / `const` ends a `test` scope.
fn isTopLevelDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "fn ") or
        std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "pub const ") or
        std.mem.startsWith(u8, line, "var ") or
        std.mem.startsWith(u8, line, "pub var ") or
        isTestDecl(line);
}

/// Every finding in one file. `path` is used for the owner check, so it
/// must carry enough of the tail to match (`src/ui/border.zig`).
pub fn extractFindings(arena: Allocator, path: []const u8, text: []const u8, counts: *Counts) Allocator.Error![]const Finding {
    counts.files += 1;
    const box_ok = owned(path, &box_owners);
    const twin_ok = owned(path, &twin_owners);
    if (box_ok and twin_ok) return &.{};
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    var in_test = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    lines: while (it.next()) |raw| {
        n += 1;
        if (isTopLevelDecl(raw)) in_test = isTestDecl(raw);
        if (in_test) continue;
        if (std.mem.indexOf(u8, raw, allow_marker) != null) continue;
        const line = stripComment(raw);
        const lits = try literalsOn(arena, line);
        for (lits) |lit| {
            counts.literals += 1;
            const s = try unescape(arena, lit);
            if (!box_ok and isBoxCell(s)) {
                try out.append(arena, .{ .file = path, .line = n, .rule = .box_literal, .expr = try arena.dupe(u8, std.mem.trim(u8, line, " ")) });
                break;
            }
        }
        if (twin_ok) continue;
        if (std.mem.indexOf(u8, line, ".ascii)") == null) continue;
        for (lits) |lit| {
            const s = try unescape(arena, lit);
            for (twins) |tw| {
                if (!std.mem.eql(u8, s, tw.a)) continue;
                // The other half has to be on the same line for this to
                // be the pair rather than a stray `-`.
                for (lits) |other| {
                    const o = try unescape(arena, other);
                    if (!std.mem.eql(u8, o, tw.u)) continue;
                    try out.append(arena, .{
                        .file = path,
                        .line = n,
                        .rule = .ascii_twin,
                        .expr = try std.fmt.allocPrint(arena, "{s}  \u{2192} {s}", .{ std.mem.trim(u8, line, " "), tw.owner }),
                    });
                    // One finding per line; the rest of the file is
                    // still read (an early return here hid a second
                    // divider in render.zig behind the first).
                    continue :lines;
                }
            }
        }
    }
    return out.toOwnedSlice(arena);
}

// ─── the walk ───────────────────────────────────────────────────────────

pub fn walk(arena: Allocator, io: Io, root: []const u8) !Result {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try files.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    var counts: Counts = .{};
    for (files.items) |rel| {
        const text = try dir.readFileAlloc(io, rel, arena, .unlimited);
        try out.appendSlice(arena, try extractFindings(arena, rel, text, &counts));
    }
    return .{ .findings = try out.toOwnedSlice(arena), .counts = counts };
}

pub fn report(w: *Io.Writer, root: []const u8, r: Result) Io.Writer.Error!void {
    for (r.findings) |f| {
        try w.print("{s}/{s}:{d}  {s}\n    {s}\n", .{ root, f.file, f.line, f.rule.text(), f.expr });
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn findingsOf(a: Allocator, path: []const u8, src: []const u8) ![]const Finding {
    var counts: Counts = .{};
    return extractFindings(a, path, src, &counts);
}

test "a hand-drawn corner is a finding; the component's own table is not" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hand =
        \\fn paintFrame(p: *Painter, b: Box, style: Style) void {
        \\    p.f.put(b.x, b.y, "\u{250c}", style);
        \\}
    ;
    const found = try findingsOf(a, "integrations/bitbucket/src/screen.zig", hand);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqual(Rule.box_literal, found[0].rule);
    try t.expectEqual(@as(usize, 2), found[0].line);

    // The same bytes in the module that owns the drawing.
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/ui/border.zig", hand)).len);

    // The escape spelling is the same glyph.
    const escaped =
        \\fn f() void {
        \\    p.put(x, y, 1, "\u{2502}", s);
        \\}
    ;
    try t.expectEqual(@as(usize, 1), (try findingsOf(a, "src/app/render.zig", escaped)).len);
}

test "a box glyph inside prose, in a comment, or in a test is not a finding" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // An integration's `--diagnose` tree is prose on a terminal.
    const prose =
        \\fn diagnose(w: *Writer) !void {
        \\    try w.print("  \u{251c}\u{2500} token: {s}\n", .{tok});
        \\}
    ;
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "integrations/jira/main.zig", prose)).len);

    const commented =
        \\fn f() void {
        \\    // the frame's "\u{250c}" corner
        \\    g();
        \\}
    ;
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/ui/toast.zig", commented)).len);

    const tested =
        \\test "the box has corners" {
        \\    try f.expectRow(0, "\u{250c}");
        \\}
    ;
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/ui/picker.zig", tested)).len);

    // …and the scope after a test is audited again.
    const after =
        \\test "x" {
        \\    try f.expectRow(0, "\u{250c}");
        \\}
        \\
        \\fn draw() void {
        \\    p.put(0, 0, "\u{250c}", s);
        \\}
    ;
    const found = try findingsOf(a, "src/ui/picker.zig", after);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqual(@as(usize, 6), found[0].line);
}

test "an ascii twin a component answers is a finding; the component itself is not" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ell =
        \\fn draw(ui: Ui) void {
        \\    const mark: []const u8 = if (ui.ascii) "..." else "\u{2026}";
        \\}
    ;
    const found = try findingsOf(a, "src/ui/settings.zig", ell);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqual(Rule.ascii_twin, found[0].rule);
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/ui/clip.zig", ell)).len);

    const rule =
        \\fn draw(ui: Ui) void {
        \\    const g = if (ui.ascii) "|" else "\u{2502}";
        \\}
    ;
    // The vertical rule is caught by BOTH rules; one finding per line.
    const r2 = try findingsOf(a, "src/app/render.zig", rule);
    try t.expect(r2.len >= 1);

    // Two twins in one file are two findings — the scan reads on
    // past the first.
    const two =
        \\fn draw(ui: Ui) void {
        \\    const a = if (ui.ascii) "..." else "\u{2026}";
        \\    const b = if (ui.ascii) "enter" else "\u{23ce}";
        \\}
    ;
    try t.expectEqual(@as(usize, 2), (try findingsOf(a, "src/app/render.zig", two)).len);

    // A lone `-` with no partner on the line is not the pair.
    const lone =
        \\fn draw(ui: Ui) void {
        \\    const s = if (ui.ascii) "-" else "x";
        \\}
    ;
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/app/render.zig", lone)).len);
}

test "an allow marker excuses one line, with its reason beside it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\fn f() void {
        \\    p.put(0, 0, "\u{2501}", s); // chrome-audit: allow — a pill's bar, not a rule
        \\    p.put(0, 1, "\u{2501}", s);
        \\}
    ;
    const found = try findingsOf(a, "src/ui/bufferline.zig", src);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqual(@as(usize, 3), found[0].line);
}

test "a hint-language twin is a finding outside overlay.zig" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\fn draw(ui: Ui) void {
        \\    const h = if (ui.ascii) "  enter open - esc back" else "  \u{23ce} open \u{b7} esc back";
        \\}
    ;
    // The whole-string twin is not the pair; the glyph pair is.
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/ui/grep_view.zig", src)).len);
    const pair =
        \\fn draw(ui: Ui) void {
        \\    const dot = if (ui.ascii) "-" else "\u{b7}";
        \\}
    ;
    const found = try findingsOf(a, "src/app/statusline.zig", pair);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqual(Rule.ascii_twin, found[0].rule);
    try t.expectEqual(@as(usize, 0), (try findingsOf(a, "src/ui/overlay.zig", pair)).len);
}

test "the real trees draw their chrome through the components" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const roots = [_][]const u8{ build_options.src_root, build_options.sdk_root, build_options.integrations_root };
    var findings: usize = 0;
    var files: usize = 0;
    var literals: usize = 0;
    for (roots) |root| {
        const r = try walk(a, t.io, root);
        if (r.findings.len > 0) {
            var out: Io.Writer.Allocating = .init(a);
            try report(&out.writer, root, r);
            std.debug.print("\n{s}\n", .{out.written()});
        }
        findings += r.findings.len;
        files += r.counts.files;
        literals += r.counts.literals;
    }
    try t.expectEqual(@as(usize, 0), findings);
    // An empty finding list is only evidence when the audit looked:
    // these are the surfaces it walked.
    try t.expect(files > 300);
    try t.expect(literals > 5000);
}
