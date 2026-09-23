//! Sticky context: when the first visible line of an editor sits inside
//! a function or class whose header has scrolled off the top, that
//! header is painted over the pane's first rows (up to three, innermost
//! kept when there are more) so you always know what you are reading.
//! Off by default; `view.toggle_sticky_context` / `:set stickycontext`.
//!
//! The rows are painted after the editor view — the same gutter width,
//! the header line's own number, bold on the cursor-line ground — and
//! each registers an `.editor_cell` for its line so a click jumps to the
//! header.
//!
//! The chain is computed once per change of the top line, the text or
//! the parse and kept on the pane (`Cache`), never per frame, and it
//! never asks for a parse: the kept tree answers when it has one without
//! errors, and otherwise — a large file before its first parse, a file
//! with a syntax error mid-edit, where tree-sitter's recovery nests one
//! item inside the previous one — the line patterns of the outline's
//! fallback do, as the Rust editor's regex outline does. Either way a
//! pinned header ENCLOSES the top line: its scope starts above it and
//! ends at or below it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const PaneId = app_mod.PaneId;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const editor_view = @import("../ui/editor_view.zig");
const outline = @import("outline.zig");
const Syntax = @import("syntax.zig").Syntax;
const Editor = @import("../editor/editor.zig").Editor;

pub const max_rows = 3;

/// A scope read off the line patterns: header line, last line, indent
/// depth. The last line is the first later line at the header's depth
/// or shallower — that line itself when it closes the block (`}`,
/// `end`, `)`), the one before it otherwise.
pub const Scope = struct { line: u32, end: u32, depth: u8 };

/// What the cached chain was computed for.
pub const Key = struct {
    first: u32 = 0,
    seen: u64 = 0,
    parsed: ?u64 = null,
    root: ?usize = null,
};

/// Per pane: the pinned lines for the last key, and the fallback's
/// scope list for the last text it was asked about.
pub const Cache = struct {
    key: Key = .{},
    valid: bool = false,
    lines: [max_rows]u32 = undefined,
    len: u8 = 0,
    /// How many times the chain was computed — what the tests read.
    computed: u32 = 0,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    scopes_seq: ?u64 = null,
    scopes_root: ?usize = null,

    pub fn deinit(self: *Cache, gpa: Allocator) void {
        self.scopes.deinit(gpa);
    }

    fn current(self: *const Cache) []const u32 {
        return self.lines[0..self.len];
    }
};

/// The header lines to pin for `e`'s current viewport, outermost first;
/// empty when the feature is off, the top line is not inside a scope,
/// or every enclosing header is already on screen. Cached on the pane:
/// recomputed only when the top line, the text or the parse changed.
pub fn headerLines(app: *App, e: *EditorPane, arena: Allocator) Allocator.Error![]u32 {
    if (!app.cfg.ui.sticky_context) return &.{};
    const first = e.view.scroll_line;
    if (first == 0) return &.{};
    const c = &e.sticky;
    const key: Key = .{ .first = first, .seen = e.syntax.seen_seq, .parsed = e.syntax.parsed_seq, .root = e.syntax.hl.root };
    if (!c.valid or !std.meta.eql(c.key, key)) {
        const chain = try compute(app.gpa, c, e.syntax, e.buf.editor, arena, first);
        const keep = if (chain.len <= max_rows) chain else chain[chain.len - max_rows ..];
        @memcpy(c.lines[0..keep.len], keep);
        c.len = @intCast(keep.len);
        c.key = key;
        c.valid = true;
        c.computed +%= 1;
    }
    return try arena.dupe(u32, c.current());
}

/// The chain for top line `first`, outermost first: the kept tree's
/// when it has one without errors, the line patterns' otherwise. Never
/// parses.
fn compute(gpa: Allocator, c: *Cache, syn: *Syntax, ed: *const Editor, arena: Allocator, first: u32) Allocator.Error![]u32 {
    if (syn.keptRoot()) |root| if (!root.hasError()) return syn.scopeChainOf(root, ed, arena, first);
    const key = syn.key() orelse return &.{};
    try fallbackScopes(gpa, c, syn, ed, key);
    var out: std.ArrayListUnmanaged(u32) = .empty;
    for (c.scopes.items) |s| {
        if (s.line >= first) break;
        if (s.end >= first) try out.append(arena, s.line);
    }
    return out.items;
}

/// `c.scopes` for the current text (keyed on the edit seq and the
/// grammar), from `outline.fallback` with each scope's end inferred.
fn fallbackScopes(gpa: Allocator, c: *Cache, syn: *const Syntax, ed: *const Editor, key: []const u8) Allocator.Error!void {
    if (c.scopes_seq == syn.seen_seq and c.scopes_root == syn.hl.root) return;
    c.scopes.clearRetainingCapacity();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = ed.bytes();
    for (try outline.fallback(arena.allocator(), text, key)) |f| {
        if (!f.kind.isScope()) continue;
        try c.scopes.append(gpa, .{ .line = f.line, .end = scopeEnd(ed, f.line, f.depth), .depth = f.depth });
    }
    c.scopes_seq = syn.seen_seq;
    c.scopes_root = syn.hl.root;
}

/// The last line of the scope whose header is `line` at indent `depth`.
pub fn scopeEnd(ed: *const Editor, line: u32, depth: u8) u32 {
    const text = ed.bytes();
    const last: u32 = @intCast(ed.lineCount() - 1);
    var l = line + 1;
    while (l <= last) : (l += 1) {
        const raw = text[ed.lineStart(l)..ed.lineEnd(l)];
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (outline.indentDepth(raw) > depth) continue;
        const closes = trimmed[0] == '}' or trimmed[0] == ')' or trimmed[0] == ']' or std.mem.startsWith(u8, trimmed, "end");
        return if (closes) l else l - 1;
    }
    return last;
}

/// Paint `lines` over the top of `area` (the rect the editor view was
/// given). `text_x` is where the editor's text column starts.
pub fn draw(ui: Ui, pane: PaneId, e: *const EditorPane, area: Rect, lines: []const u32, line_numbers: bool) void {
    const t = ui.theme;
    const ed = e.buf.editor;
    const total: u32 = @intCast(ed.lineCount());
    const gutter_w: u16 = if (line_numbers) blk: {
        var digits: u16 = 1;
        var n = total;
        while (n >= 10) : (n /= 10) digits += 1;
        break :blk @min(@max(digits, 3) + 2, area.w);
    } else 0;
    var style = t.cursor_line;
    style.bold = true;
    for (lines, 0..) |line, i| {
        if (i >= area.h or line >= total) break;
        const y = area.y + @as(u16, @intCast(i));
        const r = Rect.init(area.x, y, area.w, 1);
        ui.fill(r, style);
        if (gutter_w > 2) {
            const num = ui.fmt("{d}", .{line + 1});
            _ = ui.putStrRight(area.x + gutter_w - 1, y, gutter_w - 2, num, Theme.withFg(style, t.gutter.fg));
        }
        const text = ed.bytes()[ed.lineStart(line)..ed.lineEnd(line)];
        const cells = editor_view.layoutLine(ui, text, @intCast(ed.doc.tab_width)) catch &.{};
        var x = area.x + gutter_w;
        for (cells) |c| {
            if (x + c.w > area.right()) break;
            ui.canvas.put(x, y, .{ .char = .{ .grapheme = c.bytes, .width = c.w }, .style = style });
            x += c.w;
        }
        ui.hit(r, .{ .editor_cell = .{ .pane = pane, .line = line, .col = 0 } });
    }
}

// ── tests ──

const testing = std.testing;
const command = @import("../core/command.zig");
const screen_mod = @import("../ipc/screen.zig");

test "the enclosing fn header pins to the top once it scrolls off; the toggle toasts" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/code.rs");
    e.syntax.setLanguage("/tmp/code.rs", "");
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "fn outer() {\n");
    for (0..20) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    let v{d} = {d};\n", .{ i, i });
        defer testing.allocator.free(line);
        try text.appendSlice(testing.allocator, line);
    }
    try text.appendSlice(testing.allocator, "}\n");
    try e.buf.editor.setText(text.items);
    e.buf.editor.placeCursor(20, 0);
    try app.render();
    const plain = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "fn outer()") == null);
    try command.run(&app, .{ .static = .@"view.toggle_sticky_context" });
    try testing.expectEqualStrings("sticky context: on", app.lastToast().?);
    try app.render();
    const sticky = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(sticky);
    try testing.expect(std.mem.indexOf(u8, sticky, "fn outer()") != null);
    // The pinned row is the fourth screen row (row 0 is the palette bar,
    // which paints from 40 columns; row 1 the bufferline; row 2 the
    // breadcrumb ` code.rs `).
    var rows = std.mem.splitScalar(u8, sticky, '\n');
    _ = rows.next();
    _ = rows.next();
    _ = rows.next();
    try testing.expect(std.mem.indexOf(u8, rows.next().?, "fn outer()") != null);
    try testing.expectEqual(@as(u32, 0), app.hits.at(8, 3).?.editor_cell.line);
    // Scrolled back to the top there is nothing to pin.
    e.buf.editor.placeCursor(0, 0);
    try app.render();
    const top = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, top, "fn outer()"));
    try command.run(&app, .{ .static = .@"view.toggle_sticky_context" });
    try testing.expectEqualStrings("sticky context: off", app.lastToast().?);
}

test "the chain is computed once per top line / text / parse, not per frame" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    app.cfg.ui.sticky_context = true;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/code.rs");
    e.syntax.setLanguage("/tmp/code.rs", "");
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "fn outer() {\n");
    for (0..20) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    let v{d} = {d};\n", .{ i, i });
        defer testing.allocator.free(line);
        try text.appendSlice(testing.allocator, line);
    }
    try text.appendSlice(testing.allocator, "}\n");
    try e.buf.editor.setText(text.items);
    e.buf.editor.placeCursor(20, 0);
    app.now_ms = 1000;
    try app.render();
    try testing.expectEqual(@as(u32, 1), e.sticky.computed);
    try testing.expectEqualSlices(u32, &.{0}, e.sticky.lines[0..e.sticky.len]);
    // Frames with nothing changed reuse it.
    try app.render();
    try app.render();
    try testing.expectEqual(@as(u32, 1), e.sticky.computed);
    // A scroll recomputes once.
    e.view.scroll_line += 1;
    try app.render();
    try testing.expectEqual(@as(u32, 2), e.sticky.computed);
    try app.render();
    try testing.expectEqual(@as(u32, 2), e.sticky.computed);
    // An edit recomputes from the kept tree at once (the text moved),
    // and once more when the parse lands on the idle gate.
    try e.buf.editor.splice(e.buf.editor.len(), e.buf.editor.len(), "// tail\n");
    e.syntax.dirty = true;
    try app.render();
    try testing.expectEqual(@as(u32, 3), e.sticky.computed);
    try testing.expect(e.syntax.dirty);
    try app.render();
    try testing.expectEqual(@as(u32, 3), e.sticky.computed);
    app.now_ms += @import("syntax.zig").idle_ms;
    try app.render();
    try testing.expect(!e.syntax.dirty);
    try testing.expectEqual(@as(u32, 4), e.sticky.computed);
    try app.render();
    try testing.expectEqual(@as(u32, 4), e.sticky.computed);
}

test "a file with a syntax error pins the scope that encloses the top line, from the line patterns" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    app.cfg.ui.sticky_context = true;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/broken.rs");
    e.syntax.setLanguage("/tmp/broken.rs", "");
    // `outer` is the fixture's shape: a tab-indented block whose closing
    // brace is missing, so the fn body never closes and tree-sitter's
    // recovery swallows what follows.
    const text =
        "fn outer() {\n" ++ //  0
        "\tif a {\n" ++ //  1
        "\t\tb();\n" ++ //  2
        "\t\n" ++ //  3
        "\tc();\n" ++ //  4
        "}\n" ++ //  5
        "\n" ++ //  6
        "fn later() {\n" ++ //  7
        "    let a = 1;\n" ++ //  8
        "    let b = 2;\n" ++ //  9
        "    let c = 3;\n" ++ // 10
        "    let d = 4;\n" ++ // 11
        "    let e = 5;\n" ++ // 12
        "    let f = 6;\n" ++ // 13
        "    let g = 7;\n" ++ // 14
        "    let h = 8;\n" ++ // 15
        "    let i = 9;\n" ++ // 16
        "    let j = 10;\n" ++ // 17
        "}\n" ++ // 18
        "\n" ++ // 19
        "/// doc\n" ++ // 20
        "impl Thing {\n" ++ // 21
        "    fn m(&self) {\n" ++ // 22
        "        x;\n" ++ // 23
        "        y;\n" ++ // 24
        "        z;\n" ++ // 25
        "    }\n" ++ // 26
        "}\n"; // 27
    try e.buf.editor.setText(text);
    e.syntax.dirty = true;
    try app.render();
    try testing.expect(e.syntax.parsed_seq != null);
    try testing.expect(e.syntax.keptRoot().?.hasError());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Case = struct { first: u32, chain: []const u32 };
    const cases = [_]Case{
        .{ .first = 10, .chain = &.{7} }, // inside later
        .{ .first = 18, .chain = &.{7} }, // its closing brace
        .{ .first = 19, .chain = &.{} }, // between items
        .{ .first = 20, .chain = &.{} }, // the doc comment
        .{ .first = 24, .chain = &.{ 21, 22 } }, // inside m inside impl
        .{ .first = 27, .chain = &.{21} }, // impl's closing brace
        .{ .first = 3, .chain = &.{0} }, // outer itself, from its own header
    };
    for (cases) |c| {
        e.view.scroll_line = c.first;
        const chain = try headerLines(&app, e, arena.allocator());
        try testing.expectEqualSlices(u32, c.chain, chain);
    }
    // The tree's own answer inside `outer` is not `outer`: its
    // function_item never closed, so recovery left an ERROR node where
    // the fn was, and all the tree still sees above line 3 is the `if`
    // the stray brace closed (a compound statement is a context since
    // `context_kinds`) — and the fallback's is `outer`'s header.
    const from_tree = try e.syntax.scopeChainOf(e.syntax.keptRoot().?, e.buf.editor, arena.allocator(), 3);
    try testing.expectEqualSlices(u32, &.{1}, from_tree);
    // `scopeEnd` on the pieces: a closing line at the header's depth is
    // the scope's, a shallower non-closing line is past it.
    try testing.expectEqual(@as(u32, 18), scopeEnd(e.buf.editor, 7, 0));
    try testing.expectEqual(@as(u32, 26), scopeEnd(e.buf.editor, 22, 1));
    try testing.expectEqual(@as(u32, 27), scopeEnd(e.buf.editor, 21, 0));
    // Highlighting off for this buffer (the size ceiling, or by hand) is
    // the same no-tree case: the chain still comes from the patterns.
    try @import("../core/command.zig").run(&app, .{ .static = .@"editor.highlight_toggle_file" });
    try testing.expect(e.syntax.off and e.syntax.keptRoot() == null);
    e.sticky.valid = false;
    e.view.scroll_line = 24;
    try testing.expectEqualSlices(u32, &.{ 21, 22 }, try headerLines(&app, e, arena.allocator()));
}
