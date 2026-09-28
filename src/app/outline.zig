//! The outline pane: the symbols of one source file, beside it. The
//! tree-sitter walk (`highlight.structure`) supplies them for any file
//! with a grammar; for the rest a small table of line shapes — the
//! keyword a definition starts with, plus Go's receiver and the
//! `const f = () =>` arrow — reads them off the text with `std.mem`.
//!
//! `outline.show` opens the pane in a split to the right (or refreshes
//! the one already open). Enter / a click jumps to the symbol; the row
//! the source cursor is inside is highlighted so the list follows the
//! cursor; `r` refreshes, `esc` returns to the source, `q` closes.
//!
//! // changed (section-side): the outline is also a section with a side
//! (Rust's right-panel pane). While its column is open, `outline.show`
//! routes into it — `App.outline_panel` is a pane kept in the store
//! outside the layout, painted by `drawPanel` — and otherwise splits,
//! Rust's rule. The right column's walk (`side.show`) always uses the
//! column (`showInColumn`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const outline_view = @import("../ui/outline_view.zig");
const syntax = @import("syntax.zig");
const highlight = @import("highlight");
const structure = highlight.structure;
const lsp = @import("lsp.zig");
const lsp_types = @import("../lsp/types.zig");
const side = @import("side.zig");
const empty_state = @import("../ui/empty_state.zig");
const fuzzy = @import("../ui/fuzzy.zig");

pub const table = .{
    .@"outline.show" = &show,
};

pub const Symbol = struct {
    /// Owned.
    name: []u8,
    /// A literal (`Kind.label`).
    kind: []const u8,
    line: u32,
    col: u32,
    depth: u8,
};

pub const OutlinePane = struct {
    gpa: Allocator,
    source: PaneId,
    /// Owned: the source's basename.
    title: []u8,
    items: std.ArrayListUnmanaged(Symbol) = .empty,
    /// An index into the FILTERED view (`visible`), Rust's `selected`.
    cursor: usize = 0,
    scroll: usize = 0,
    /// The fuzzy filter; empty shows every symbol.
    query: std.ArrayListUnmanaged(u8) = .empty,
    /// Keys build `query` instead of moving; `⏎` / `esc` leave it.
    filter_mode: bool = false,
    /// `app.lsp.symbols_gen` as of the last refresh: a server's list
    /// landing since then is a reason to refresh, a text change the other.
    symbols_gen: u64 = 0,
    /// The source is over the highlight ceiling (`Syntax.overCeiling`):
    /// no tree, no symbol request, and the list says `outline off · N MB`
    /// with the size, not `(no symbols)`. Null when the outline is on.
    off_bytes: ?usize = null,

    pub fn init(gpa: Allocator, source: PaneId, title: []const u8) Allocator.Error!OutlinePane {
        return .{ .gpa = gpa, .source = source, .title = try gpa.dupe(u8, title) };
    }

    pub fn deinit(self: *OutlinePane) void {
        self.clear();
        self.items.deinit(self.gpa);
        self.query.deinit(self.gpa);
        self.gpa.free(self.title);
    }

    fn clear(self: *OutlinePane) void {
        for (self.items.items) |s| self.gpa.free(s.name);
        self.items.clearRetainingCapacity();
    }

    /// The item whose line is the last at or before `row`.
    pub fn itemAt(self: *const OutlinePane, row: u32) ?usize {
        var best: ?usize = null;
        for (self.items.items, 0..) |s, i| if (s.line <= row) {
            best = i;
        };
        return best;
    }

    /// Indices of the items that pass the query, in source order (so
    /// nesting depth stays readable), on `arena`.
    pub fn visible(self: *const OutlinePane, arena: Allocator) Allocator.Error![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        for (self.items.items, 0..) |s, i| {
            if (self.query.items.len > 0 and fuzzy.score(self.query.items, s.name) == null) continue;
            try out.append(arena, i);
        }
        return out.items;
    }

    /// Where item `idx` sits in the filtered view, if it passes.
    pub fn visibleIndexOf(self: *const OutlinePane, arena: Allocator, idx: usize) Allocator.Error!?usize {
        for (try self.visible(arena), 0..) |item, vi| if (item == idx) return vi;
        return null;
    }

    /// The tab's label — Rust's `tab_title`: `main.rs ⌥3`, or `main.rs ⌥`
    /// for an empty list.
    pub fn tabTitle(self: *const OutlinePane, arena: Allocator) Allocator.Error![]const u8 {
        const n = self.items.items.len;
        if (n == 0) return std.fmt.allocPrint(arena, "{s} \u{2325}", .{self.title});
        return std.fmt.allocPrint(arena, "{s} \u{2325}{d}", .{ self.title, n });
    }

    fn clampCursor(self: *OutlinePane, n: usize) void {
        if (self.cursor >= n) self.cursor = n -| 1;
    }

    /// Esc in filter mode, or with a filter held: drop both.
    fn clearFilter(self: *OutlinePane) void {
        self.query.clearRetainingCapacity();
        self.filter_mode = false;
        self.cursor = 0;
        self.scroll = 0;
    }

    fn popQuery(self: *OutlinePane) void {
        const q = self.query.items;
        if (q.len == 0) return;
        var i = q.len - 1;
        while (i > 0 and (q[i] & 0xC0) == 0x80) i -= 1;
        self.query.shrinkRetainingCapacity(i);
    }
};

/// Open the outline for the active editor beside it, or refresh the one
/// already watching it.
/// The editor an outline would list: the active editor, or the source
/// of the active outline.
fn sourceOf(app: *App) CommandError!PaneId {
    const active = app.active orelse return error.NoActivePane;
    const p = app.panes.get(active) orelse return error.NoActivePane;
    return switch (p.*) {
        .editor => active,
        .outline => |*o| o.source,
        .md_preview => app.diag.fail(app.frame.allocator(), "outline: not for a preview", .{}),
        .image, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .sessions_table, .spend_report, .ai_usage, .grep, .debug, .request, .websocket, .browser, .script, .mount, .integrations, .ai_apply, .tests, .flaky, .requests, .files, .zon, .session_changes => error.NotAnEditor,
    };
}

/// A fresh outline pane on `source`, in the store.
fn create(app: *App, source: PaneId) CommandError!PaneId {
    const src = app.panes.editor(source) orelse return error.NotAnEditor;
    const title: []const u8 = if (src.buf.doc.path) |p| std.fs.path.basename(p) else "[scratch]";
    var pane = try OutlinePane.init(app.gpa, source, title);
    errdefer pane.deinit();
    const id = try app.panes.add(.{ .outline = pane });
    pane = undefined;
    try refresh(app, id);
    return id;
}

/// The split-pane outline for `source`, if one is in the layout (the
/// column's pane is not).
fn findSplit(app: *App, source: PaneId) ?PaneId {
    const id = app.panes.findOutline(source) orelse return null;
    if (app.outline_panel == id) {
        // The column's pane matched; look past it.
        for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
            .outline => |*o| if (o.source == source and @as(PaneId, @intCast(i)) != id) return @intCast(i),
            else => {},
        };
        return null;
    }
    return id;
}

/// `outline.show` and `r` ask the source's language server for its
/// symbols again: the list a server gave while it was still
/// configuring was empty, and a repaint of that is still empty.
fn reask(app: *App, source: PaneId) void {
    const src = app.panes.editor(source) orelse return;
    if (src.buf.doc.path) |p| lsp.reaskSymbols(app, p);
}

fn show(app: *App) CommandError!void {
    const source = try sourceOf(app);
    reask(app, source);
    if (findSplit(app, source)) |id| {
        try refresh(app, id);
        app.showPane(id);
        return;
    }
    // Rust's rule: the outline routes into its column while that is
    // open, and opens a split otherwise.
    if (side.shown(app, side.sideOf(app, .outline)) != null) return showInColumn(app, false);
    const id = try create(app, source);
    const layout = app.layouts.current();
    if (try layout.split(source, .horizontal, id) == null) _ = try layout.showIn(null, id);
    app.setActive(id);
}

/// The outline in its column, on the active editor — or the column's
/// empty state when there is none. `outline.show` leaves the keys in
/// the editor (Rust's routing); the column's walk takes them.
pub fn showInColumn(app: *App, focus: bool) CommandError!void {
    const source: ?PaneId = sourceOf(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (source) |src| {
        reask(app, src);
        if (app.outline_panel) |id| {
            const same = if (app.panes.get(id)) |p| (if (p.asOutline()) |o| o.source == src else false) else false;
            if (same) {
                try refresh(app, id);
            } else {
                try app.forceClosePane(id);
                app.outline_panel = try create(app, src);
            }
        } else app.outline_panel = try create(app, src);
    }
    side.place(app, .outline, focus);
}

/// The column's outline (`PanelId.outline`), or its empty state.
pub fn drawPanel(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    if (app.outline_panel) |id| if (app.panes.get(id)) |p| if (p.asOutline()) |o| {
        return draw(app, ui, id, o, area, app.focus == .panel and app.focus.panel == .outline);
    };
    const bg = @import("../ui/theme.zig").onBg(ui.theme.fg, ui.theme.palette.bg_darker);
    ui.canvas.fill(area, bg);
    _ = empty_state.draw(ui, area, .{ .message = "No outline yet", .hint = "outline.show on an open file" }, bg);
}

/// The keys go back to the source — in a pane or in the column.
fn focusSource(app: *App, src: PaneId) void {
    app.setActive(src);
    if (app.focus == .panel) app.focus = .{ .pane = src };
}

/// Rebuild the symbol list from the source's current text.
pub fn refresh(app: *App, id: PaneId) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    const src = app.panes.editor(o.source) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    o.clear();
    o.symbols_gen = app.lsp.symbols_gen;
    o.off_bytes = null;
    // Over the ceiling nothing is asked and nothing is walked: the pane
    // says so, honestly, instead of "(no symbols)" for a file full of them.
    if (src.syntax.overCeiling()) {
        o.off_bytes = src.syntax.size_bytes;
        o.clampCursor(0);
        app.needs_render = true;
        return;
    }
    // A language server's symbols first; the tree-sitter walk otherwise.
    const from_server: ?[]const lsp_types.Symbol = if (src.buf.doc.path) |p| lsp.symbolsFor(app, p) else null;
    if (from_server) |syms| {
        for (syms) |s| try o.items.append(o.gpa, .{ .name = try o.gpa.dupe(u8, s.name), .kind = lsp_types.symbolKindLabel(s.kind), .line = s.line, .col = s.character, .depth = s.depth });
    } else if (try src.syntax.symbols(src.buf.editor, a)) |syms| {
        for (syms) |s| try o.items.append(o.gpa, .{ .name = try o.gpa.dupe(u8, s.name), .kind = s.kind.label(), .line = s.line, .col = s.col, .depth = s.depth });
    } else {
        var buf: [32]u8 = undefined;
        const key = languageKey(src.buf.doc.path, &buf);
        const syms = try fallback(a, src.buf.editor.bytes(), key);
        for (syms) |s| try o.items.append(o.gpa, .{ .name = try o.gpa.dupe(u8, s.name), .kind = s.kind.label(), .line = s.line, .col = s.col, .depth = s.depth });
    }
    o.clampCursor((try o.visible(a)).len);
    app.needs_render = true;
}

fn languageKey(path: ?[]const u8, buf: []u8) []const u8 {
    const p = path orelse return "";
    const ext = std.fs.path.extension(p);
    if (ext.len < 2 or ext.len - 1 > buf.len) return "";
    return std.ascii.lowerString(buf[0 .. ext.len - 1], ext[1..]);
}

/// Put the source cursor on the filtered view's row `vi` and focus the
/// source.
pub fn jump(app: *App, id: PaneId, vi: usize) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    const vis = try o.visible(app.frame.allocator());
    if (vi >= vis.len) return;
    o.cursor = vi;
    jumpItem(app, o, vis[vi]);
}

fn jumpItem(app: *App, o: *OutlinePane, idx: usize) void {
    if (idx >= o.items.items.len) return;
    const s = o.items.items[idx];
    const src = app.panes.editor(o.source) orelse return;
    src.buf.editor.anchor = null;
    src.buf.editor.placeCursor(@min(s.line, @as(u32, @intCast(src.buf.editor.lineCount() - 1))), s.col);
    focusSource(app, o.source);
}

/// A click on a row: the hit names the source line/col; find the item.
pub fn clickRow(app: *App, id: PaneId, line: u32, col: u32) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    for (o.items.items, 0..) |s, i| if (s.line == line and s.col == col) {
        if (try o.visibleIndexOf(app.frame.allocator(), i)) |vi| o.cursor = vi;
        return jumpItem(app, o, i);
    };
}

pub fn close(app: *App, id: PaneId) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    const back = o.source;
    // The column's outline closes its column with it.
    if (app.outline_panel == id) side.hide(app, .outline);
    try app.forceClosePane(id);
    if (app.panes.get(back) != null) focusSource(app, back);
}

/// Keys while the outline has focus. False lets the chord chain see it.
/// Filter mode takes every plain key first: it builds the query, `⏎`
/// leaves it holding the filter, `esc` clears and leaves. Outside it
/// `/` enters, and `esc` with a filter held clears it before a second
/// `esc` returns to the source (Rust's rule).
pub fn handleKey(app: *App, id: PaneId, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const pane = app.panes.get(id) orelse return false;
    const o = pane.asOutline() orelse return false;
    if (o.filter_mode) {
        switch (k.code) {
            .esc => o.clearFilter(),
            .enter => o.filter_mode = false,
            .backspace => o.popQuery(),
            .char => |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return true;
                try o.query.appendSlice(o.gpa, buf[0..n]);
            },
            else => return true,
        }
        o.cursor = 0;
        o.clampCursor((try o.visible(app.frame.allocator())).len);
        app.needs_render = true;
        return true;
    }
    const n = (try o.visible(app.frame.allocator())).len;
    const page = @max(app.pane_rows -| outline_view.header_rows, 1);
    switch (k.code) {
        .down => o.cursor = @min(o.cursor + 1, n -| 1),
        .up => o.cursor -|= 1,
        .home => o.cursor = 0,
        .end => o.cursor = n -| 1,
        .page_down => o.cursor = @min(o.cursor + page, n -| 1),
        .page_up => o.cursor -|= page,
        .enter => try jump(app, id, o.cursor),
        .esc => if (o.query.items.len > 0) o.clearFilter() else focusSource(app, o.source),
        .char => |c| switch (c) {
            'j' => o.cursor = @min(o.cursor + 1, n -| 1),
            'k' => o.cursor -|= 1,
            'g' => o.cursor = 0,
            'G' => o.cursor = n -| 1,
            '/' => o.filter_mode = true,
            'r' => {
                reask(app, o.source);
                try refresh(app, id);
            },
            'q' => try close(app, id),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// One frame of the pane: refresh when the source changed since the
/// last frame, then paint the filtered view with the source cursor's
/// item highlighted.
pub fn draw(app: *App, ui: Ui, id: PaneId, o: *OutlinePane, area: Rect, focused: bool) Allocator.Error!void {
    var current: ?usize = null;
    if (app.panes.editor(o.source)) |src| {
        if (src.syntax.dirty or o.items.items.len == 0 or o.symbols_gen != app.lsp.symbols_gen) try refresh(app, id);
        if (o.itemAt(@intCast(src.buf.editor.currentLine()))) |item| current = try o.visibleIndexOf(ui.arena, item);
        // Follow the source cursor when the outline is not being driven.
        if (!focused and !o.filter_mode) if (current) |c| {
            o.cursor = c;
        };
    }
    const vis = try o.visible(ui.arena);
    const rows = try ui.arena.alloc(outline_view.Row, vis.len);
    for (vis, 0..) |item, i| {
        const s = o.items.items[item];
        rows[i] = .{ .name = s.name, .kind = s.kind, .line = s.line, .col = s.col, .depth = s.depth };
    }
    outline_view.draw(ui, id, area, &o.scroll, .{
        .title = o.title,
        .rows = rows,
        .total = o.items.items.len,
        .cursor = o.cursor,
        .current = current,
        .focused = focused,
        .query = o.query.items,
        .filter_mode = o.filter_mode,
        .off_label = if (o.off_bytes) |n| blk: {
            var size_buf: [24]u8 = undefined;
            break :blk ui.fmt("{s}", .{syntax.Syntax.sizeLabel(&size_buf, n)});
        } else null,
    });
}

// ── the line-shape fallback ────────────────────────────────────────────

const Kind = structure.Kind;

pub const Found = struct { name: []const u8, kind: Kind, line: u32, col: u32, depth: u8 };

const Rule = struct { keyword: []const u8, kind: Kind };

const rust_rules = [_]Rule{ .{ .keyword = "fn", .kind = .function }, .{ .keyword = "struct", .kind = .@"struct" }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "trait", .kind = .trait }, .{ .keyword = "impl", .kind = .impl }, .{ .keyword = "mod", .kind = .module }, .{ .keyword = "type", .kind = .type }, .{ .keyword = "const", .kind = .constant }, .{ .keyword = "static", .kind = .constant } };
const py_rules = [_]Rule{ .{ .keyword = "def", .kind = .function }, .{ .keyword = "class", .kind = .class } };
const js_rules = [_]Rule{ .{ .keyword = "function", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "type", .kind = .type }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "namespace", .kind = .namespace } };
const go_rules = [_]Rule{ .{ .keyword = "func", .kind = .function }, .{ .keyword = "type", .kind = .type } };
const rb_rules = [_]Rule{ .{ .keyword = "def", .kind = .method }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "module", .kind = .module } };
const c_rules = [_]Rule{ .{ .keyword = "struct", .kind = .@"struct" }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "union", .kind = .@"struct" }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "namespace", .kind = .namespace }, .{ .keyword = "typedef", .kind = .type } };
const java_rules = [_]Rule{ .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "record", .kind = .@"struct" } };
const cs_rules = [_]Rule{ .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "record", .kind = .class }, .{ .keyword = "struct", .kind = .@"struct" }, .{ .keyword = "namespace", .kind = .namespace }, .{ .keyword = "delegate", .kind = .type } };
const kt_rules = [_]Rule{ .{ .keyword = "fun", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "object", .kind = .module } };
const swift_rules = [_]Rule{ .{ .keyword = "func", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "struct", .kind = .@"struct" }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "protocol", .kind = .interface }, .{ .keyword = "extension", .kind = .impl } };
const zig_rules = [_]Rule{ .{ .keyword = "fn", .kind = .function }, .{ .keyword = "const", .kind = .constant } };
const lua_rules = [_]Rule{.{ .keyword = "function", .kind = .function }};
const php_rules = [_]Rule{ .{ .keyword = "function", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "trait", .kind = .trait } };
const ex_rules = [_]Rule{ .{ .keyword = "def", .kind = .function }, .{ .keyword = "defp", .kind = .function }, .{ .keyword = "defmodule", .kind = .module } };
const scala_rules = [_]Rule{ .{ .keyword = "def", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "object", .kind = .module }, .{ .keyword = "trait", .kind = .trait } };

const modifiers = [_][]const u8{ "pub", "export", "default", "async", "static", "final", "abstract", "public", "private", "protected", "unsafe", "extern", "override", "inline", "virtual", "declare", "internal", "open", "sealed", "data", "readonly", "partial", "new" };
const c_control = [_][]const u8{ "if", "while", "for", "switch", "return", "else", "do", "sizeof", "case" };
/// A C# line that begins with one of these is a statement, not a method.
const cs_statement_heads = [_][]const u8{ "return", "await", "throw", "yield", "if", "while", "for", "foreach", "using", "else", "case", "switch", "lock", "var", "do", "try", "catch", "base", "this" };

fn rulesFor(key: []const u8) ?[]const Rule {
    const KV = struct { []const u8, []const Rule };
    const map = [_]KV{
        .{ "rs", &rust_rules },     .{ "py", &py_rules },   .{ "js", &js_rules },   .{ "jsx", &js_rules },    .{ "ts", &js_rules }, .{ "tsx", &js_rules },
        .{ "mjs", &js_rules },      .{ "cjs", &js_rules },  .{ "go", &go_rules },   .{ "rb", &rb_rules },     .{ "c", &c_rules },   .{ "h", &c_rules },
        .{ "cpp", &c_rules },       .{ "cc", &c_rules },    .{ "hpp", &c_rules },   .{ "java", &java_rules }, .{ "cs", &cs_rules }, .{ "kt", &kt_rules },
        .{ "swift", &swift_rules }, .{ "zig", &zig_rules }, .{ "lua", &lua_rules }, .{ "php", &php_rules },   .{ "ex", &ex_rules }, .{ "exs", &ex_rules },
        .{ "scala", &scala_rules },
    };
    for (map) |kv| if (std.mem.eql(u8, kv[0], key)) return kv[1];
    return null;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// The identifier at the start of `s`, allowing Ruby's `?`/`!` tail and
/// a leading `self.` / `@`.
fn identAt(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    if (std.mem.startsWith(u8, s, "self.")) i = 5;
    const start = i;
    if (i >= s.len or !isIdentStart(s[i])) return null;
    while (i < s.len and isIdent(s[i])) i += 1;
    if (i < s.len and (s[i] == '?' or s[i] == '!')) i += 1;
    return s[start..i];
}

pub fn indentDepth(line: []const u8) u8 {
    var tabs: usize = 0;
    var spaces: usize = 0;
    for (line) |c| switch (c) {
        '\t' => tabs += 1,
        ' ' => spaces += 1,
        else => break,
    };
    return @intCast(@min(tabs + spaces / 4, 8));
}

/// Strip `pub(crate) async ` and friends.
fn stripModifiers(s_in: []const u8) []const u8 {
    var s = s_in;
    outer: while (true) {
        for (modifiers) |m| {
            if (std.mem.startsWith(u8, s, m) and s.len > m.len and (s[m.len] == ' ' or s[m.len] == '(')) {
                var rest = s[m.len..];
                if (rest[0] == '(') {
                    const close_at = std.mem.indexOfScalar(u8, rest, ')') orelse break :outer;
                    rest = rest[close_at + 1 ..];
                }
                s = std.mem.trimStart(u8, rest, " \t");
                continue :outer;
            }
        }
        break;
    }
    return s;
}

/// Definitions read off the lines of `text` for language `key`. Empty
/// for a language the table does not cover.
pub fn fallback(arena: Allocator, text: []const u8, key: []const u8) Allocator.Error![]Found {
    var out: std.ArrayListUnmanaged(Found) = .empty;
    const rules = rulesFor(key) orelse return out.items;
    const is_js = rules.ptr == @as([]const Rule, &js_rules).ptr;
    const is_c = rules.ptr == @as([]const Rule, &c_rules).ptr;
    const is_cs = rules.ptr == @as([]const Rule, &cs_rules).ptr;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var ln: u32 = 0;
    while (lines.next()) |raw| : (ln += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const body = stripModifiers(trimmed);
        const depth = indentDepth(line);
        if (try matchKeyword(arena, body, rules, key, line, ln, depth)) |f| {
            try out.append(arena, f);
            continue;
        }
        if (is_js) {
            if (arrowName(body)) |name| {
                try out.append(arena, .{ .name = name, .kind = .function, .line = ln, .col = colOf(line, name), .depth = depth });
                continue;
            }
        }
        if (is_c and line.len > 0 and isIdentStart(line[0])) {
            if (cFunctionName(body)) |name| try out.append(arena, .{ .name = name, .kind = .function, .line = ln, .col = colOf(line, name), .depth = depth });
        }
        if (is_cs) {
            if (csMethodName(body)) |name| try out.append(arena, .{ .name = name, .kind = .method, .line = ln, .col = colOf(line, name), .depth = depth });
        }
    }
    return out.items;
}

fn colOf(line: []const u8, name: []const u8) u32 {
    return @intCast(@intFromPtr(name.ptr) - @intFromPtr(line.ptr));
}

fn matchKeyword(arena: Allocator, body: []const u8, rules: []const Rule, key: []const u8, line: []const u8, ln: u32, depth: u8) Allocator.Error!?Found {
    for (rules) |r| {
        if (!std.mem.startsWith(u8, body, r.keyword)) continue;
        var rest = body[r.keyword.len..];
        if (rest.len == 0) continue;
        const sep_ok = rest[0] == ' ' or rest[0] == '\t' or (rest[0] == '(' and std.mem.eql(u8, key, "go")) or (rest[0] == '<' and r.kind == .impl);
        if (!sep_ok) continue;
        rest = std.mem.trimStart(u8, rest, " \t");
        // Go's receiver: `func (r *Router) Handle(`.
        if (std.mem.eql(u8, key, "go") and r.kind == .function and rest.len > 0 and rest[0] == '(') {
            const close_at = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
            var recv = std.mem.trim(u8, rest[1..close_at], " \t");
            if (std.mem.lastIndexOfScalar(u8, recv, ' ')) |sp| recv = recv[sp + 1 ..];
            recv = std.mem.trimStart(u8, recv, "*");
            if (std.mem.indexOfScalar(u8, recv, '[')) |b| recv = recv[0..b];
            const after = std.mem.trimStart(u8, rest[close_at + 1 ..], " \t");
            const name = identAt(after) orelse continue;
            return .{ .name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ recv, name }), .kind = .method, .line = ln, .col = colOf(line, name), .depth = depth };
        }
        if (std.mem.eql(u8, key, "rs") and r.kind == .constant) {
            const name = identAt(rest) orelse continue;
            for (name) |c| if (std.ascii.isLower(c)) return null;
            return .{ .name = name, .kind = r.kind, .line = ln, .col = colOf(line, name), .depth = depth };
        }
        if (std.mem.eql(u8, key, "zig") and r.kind == .constant) {
            // `const Foo = struct {` is a type; other consts are noise.
            const name = identAt(rest) orelse continue;
            const tail = rest[name.len..];
            if (std.mem.indexOf(u8, tail, "struct") == null and std.mem.indexOf(u8, tail, "enum") == null and std.mem.indexOf(u8, tail, "union") == null) return null;
            return .{ .name = name, .kind = .@"struct", .line = ln, .col = colOf(line, name), .depth = depth };
        }
        // C's `typedef struct { … } name;` names last; skip the open form.
        if (r.kind == .type and std.mem.eql(u8, r.keyword, "typedef")) {
            const semi = std.mem.lastIndexOfScalar(u8, rest, ';') orelse continue;
            const before = std.mem.trimEnd(u8, rest[0..semi], " \t");
            const sp = std.mem.lastIndexOfAny(u8, before, " \t}") orelse continue;
            const name = std.mem.trimStart(u8, before[sp + 1 ..], "*");
            if (name.len == 0 or !isIdentStart(name[0])) continue;
            return .{ .name = name, .kind = .type, .line = ln, .col = colOf(line, name), .depth = depth };
        }
        // Rust `impl<T> Foo` — hop the generic list.
        if (r.kind == .impl and rest.len > 0 and rest[0] == '<') {
            const gt = std.mem.indexOfScalar(u8, rest, '>') orelse continue;
            rest = std.mem.trimStart(u8, rest[gt + 1 ..], " \t");
        }
        const name = identAt(rest) orelse continue;
        return .{ .name = name, .kind = r.kind, .line = ln, .col = colOf(line, name), .depth = depth };
    }
    return null;
}

/// `const App: React.FC<Props> = ({ title }) => (` and the plain
/// `const f = async (x) =>` / `= function` shapes.
fn arrowName(body: []const u8) ?[]const u8 {
    const heads = [_][]const u8{ "const ", "let ", "var " };
    var rest: []const u8 = undefined;
    var hit = false;
    for (heads) |h| if (std.mem.startsWith(u8, body, h)) {
        rest = body[h.len..];
        hit = true;
        break;
    };
    if (!hit) return null;
    const name = identAt(rest) orelse return null;
    const after = rest[name.len..];
    const eq = std.mem.indexOfScalar(u8, after, '=') orelse return null;
    const value = std.mem.trimStart(u8, after[eq + 1 ..], " \t");
    if (std.mem.startsWith(u8, value, "function")) return name;
    if (std.mem.indexOf(u8, value, "=>") != null and (value.len > 0 and (value[0] == '(' or std.mem.startsWith(u8, value, "async")))) return name;
    return null;
}

/// `static int *make(int n) {` at column 0: the identifier before `(`.
fn cFunctionName(body: []const u8) ?[]const u8 {
    const paren = std.mem.indexOfScalar(u8, body, '(') orelse return null;
    var end = paren;
    while (end > 0 and body[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and isIdent(body[start - 1])) start -= 1;
    if (start == end) return null;
    const name = body[start..end];
    for (c_control) |kw| if (std.mem.eql(u8, kw, name)) return null;
    // A return type must precede the name.
    if (std.mem.trim(u8, body[0..start], " \t*&").len == 0) return null;
    if (std.mem.indexOfScalar(u8, body[0..start], '=') != null) return null;
    return name;
}

/// `public async Task<int> Load(int id)` with the modifiers stripped:
/// a return type, then the name, then `(` — on a line that is a
/// signature, not a call (`Assert.Equal(…);`, `return Foo();`, `await
/// x.Run()`; an expression-bodied `int F() => 1;` still counts).
fn csMethodName(body: []const u8) ?[]const u8 {
    const name = cFunctionName(body) orelse return null;
    const before = std.mem.trimEnd(u8, body[0 .. @intFromPtr(name.ptr) - @intFromPtr(body.ptr)], " \t");
    if (before.len == 0 or before[before.len - 1] == '.') return null;
    const head = before[0 .. std.mem.indexOfAny(u8, before, " \t<([") orelse before.len];
    for (cs_statement_heads) |kw| if (std.mem.eql(u8, kw, head)) return null;
    const trimmed = std.mem.trimEnd(u8, body, " \t");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ';' and std.mem.indexOf(u8, trimmed, "=>") == null) return null;
    return name;
}

// ── tests ──

const testing = std.testing;

fn namesOf(arena: Allocator, syms: []const Found) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (syms, 0..) |s, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, s.name);
    }
    return out.items;
}

test "fallback: rust, python and go shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rs = "pub(crate) fn alpha() {}\nstruct Gamma {\n    x: u32,\n}\nimpl<T> Gamma {\n    pub async fn beta() {}\n}\nconst MAX_N: u32 = 1;\nconst lower: u32 = 2;\n";
    try testing.expectEqualStrings("alpha Gamma Gamma beta MAX_N", try namesOf(a, try fallback(a, rs, "rs")));
    // C#: the types by keyword, a method by its signature; calls, statements and attributes are not methods.
    const cs = "namespace Acme.Tests;\n\npublic record Point(int X, int Y);\n\npublic class CalcTests\n{\n    [Fact]\n    public async Task<int> Adds()\n    {\n        Assert.Equal(2, 1 + 1);\n        return await Task.FromResult(1);\n    }\n\n    public int Sub(int a) => a - 1;\n    private static readonly List<int> Cache = new List<int>();\n}\n\ninternal struct P { }\npublic interface IRun { void Run(); }\npublic enum Color { Red }\n";
    const cs_syms = try fallback(a, cs, "cs");
    try testing.expectEqualStrings("Acme Point CalcTests Adds Sub P IRun Color", try namesOf(a, cs_syms));
    try testing.expectEqual(Kind.method, cs_syms[3].kind);
    try testing.expectEqual(@as(u32, 7), cs_syms[3].line);
    try testing.expectEqual(Kind.method, cs_syms[4].kind);
    const py = "class Greeter:\n    def __init__(self):\n        pass\n";
    const psyms = try fallback(a, py, "py");
    try testing.expectEqualStrings("Greeter __init__", try namesOf(a, psyms));
    try testing.expectEqual(@as(u8, 1), psyms[1].depth);
    const go = "type Router struct{}\nfunc New() *Router { return nil }\nfunc (r *Router) Handle(path string) {}\n";
    const gsyms = try fallback(a, go, "go");
    try testing.expectEqualStrings("Router New Router.Handle", try namesOf(a, gsyms));
    try testing.expectEqual(Kind.method, gsyms[2].kind);
}

test "fallback: typescript arrows, classes, interfaces, types; c functions and typedefs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = "export interface User { id: number; }\nexport class AuthService {\n  async login(user: User) {}\n}\nexport type Token = string;\nexport const App: React.FC<Props> = ({ title }) => (\n);\nconst helper = ({ x }: { x: number }) => x * 2;\nexport function Logo() {}\nconst notFn = 3;\n";
    try testing.expectEqualStrings("User AuthService Token App helper Logo", try namesOf(a, try fallback(a, ts, "tsx")));
    const c = "static int *make(int n) {\n    return 0;\n}\ntypedef struct { int x; } point_t;\nif (x) {\n";
    try testing.expectEqualStrings("make point_t", try namesOf(a, try fallback(a, c, "c")));
    try testing.expectEqual(@as(usize, 0), (try fallback(a, "anything", "txt")).len);
}

test "outline.show opens a split beside the source, jumps on enter, and refreshes in place" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    const src = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/code.rs");
    e.syntax.setLanguage("/tmp/code.rs", "");
    try e.buf.editor.setText("fn alpha() {\n    println!(\"a\");\n}\n\nfn beta() {\n    println!(\"b\");\n}\n\nstruct Gamma {\n    x: u32,\n}\n");
    try command.run(&app, .{ .static = .@"outline.show" });
    const id = app.active.?;
    try testing.expect(id != src);
    const o = app.panes.get(id).?.asOutline().?;
    try testing.expectEqual(@as(usize, 4), o.items.items.len);
    try testing.expectEqualStrings("beta", o.items.items[1].name);
    try testing.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    try app.handle(.{ .key = Key.char('j') });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqual(src, app.active.?);
    try testing.expectEqual(@as(usize, 4), e.buf.editor.currentLine());
    // A second show refreshes the same pane rather than opening another.
    try command.run(&app, .{ .static = .@"outline.show" });
    try testing.expectEqual(id, app.active.?);
    try testing.expectEqual(@as(usize, 2), app.panes.count());
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "struct Gamma:9") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "3 symbols") == null);
    try app.handle(.{ .key = Key.char('q') });
    try testing.expectEqual(@as(usize, 1), app.panes.count());
    try testing.expectEqual(src, app.active.?);
}

test "the right column's strip: the outline's live title, the plus opens Add panel, the close closes the column" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/code.rs");
    e.syntax.setLanguage("/tmp/code.rs", "");
    try e.buf.editor.setText("fn alpha() {}\n\nfn beta() {}\n");
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try command.run(&app, .{ .static = .@"outline.show" });
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    var txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    try testing.expect(std.mem.indexOf(u8, txt, "code.rs \u{2325}2   \u{F0415}") != null);
    testing.allocator.free(txt);
    const plus = app.hits.at(102, 1).?;
    try testing.expectEqual(@as(u32, 20), plus.button);
    try app.handle(.{ .mouse = .{ .x = 102, .y = 1, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = 102, .y = 1, .kind = .release, .button = .left } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Add panel", app.overlay.menu.title);
    try app.render();
    txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "Add panel") != null);
    // Esc puts the menu away; the `×` one cell in from the edge closes
    // the column with its outline.
    try app.handle(.{ .key = Key.named(.esc) });
    try app.render();
    try testing.expectEqual(@as(u32, 18), app.hits.at(118, 1).?.button);
    try app.handle(.{ .mouse = .{ .x = 118, .y = 1, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = 118, .y = 1, .kind = .release, .button = .left } });
    try app.render();
    const after = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "\u{2325}2") == null);
}
