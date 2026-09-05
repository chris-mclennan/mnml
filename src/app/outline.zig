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
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn init(gpa: Allocator, source: PaneId, title: []const u8) Allocator.Error!OutlinePane {
        return .{ .gpa = gpa, .source = source, .title = try gpa.dupe(u8, title) };
    }

    pub fn deinit(self: *OutlinePane) void {
        self.clear();
        self.items.deinit(self.gpa);
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
};

/// Open the outline for the active editor beside it, or refresh the one
/// already watching it.
fn show(app: *App) CommandError!void {
    const active = app.active orelse return error.NoActivePane;
    const source: PaneId = if (app.panes.get(active)) |p| switch (p.*) {
        .editor => active,
        .outline => |*o| o.source,
        .md_preview => return app.diag.fail(app.frame.allocator(), "outline: not for a preview", .{}),
        .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .claude_agents, .spend_report, .debug, .dap_repl, .request, .websocket, .browser, .mount, .integrations => return error.NotAnEditor,
    } else return error.NoActivePane;
    if (app.panes.findOutline(source)) |id| {
        try refresh(app, id);
        app.showPane(id);
        return;
    }
    const src = app.panes.editor(source) orelse return error.NotAnEditor;
    const title: []const u8 = if (src.buf.path) |p| std.fs.path.basename(p) else "[scratch]";
    var pane = try OutlinePane.init(app.gpa, source, title);
    errdefer pane.deinit();
    const id = try app.panes.add(.{ .outline = pane });
    pane = undefined;
    try refresh(app, id);
    const layout = app.layouts.current();
    if (try layout.split(source, .horizontal, id) == null) _ = try layout.showIn(null, id);
    app.setActive(id);
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
    // A language server's symbols first; the tree-sitter walk otherwise.
    const from_server: ?[]const lsp_types.Symbol = if (src.buf.path) |p| lsp.symbolsFor(app, p) else null;
    if (from_server) |syms| {
        for (syms) |s| try o.items.append(o.gpa, .{ .name = try o.gpa.dupe(u8, s.name), .kind = lsp_types.symbolKindLabel(s.kind), .line = s.line, .col = s.character, .depth = s.depth });
    } else if (try src.syntax.symbols(&src.buf.editor, a)) |syms| {
        for (syms) |s| try o.items.append(o.gpa, .{ .name = try o.gpa.dupe(u8, s.name), .kind = s.kind.label(), .line = s.line, .col = s.col, .depth = s.depth });
    } else {
        var buf: [32]u8 = undefined;
        const key = languageKey(src.buf.path, &buf);
        const syms = try fallback(a, src.buf.editor.bytes(), key);
        for (syms) |s| try o.items.append(o.gpa, .{ .name = try o.gpa.dupe(u8, s.name), .kind = s.kind.label(), .line = s.line, .col = s.col, .depth = s.depth });
    }
    if (o.cursor >= o.items.items.len) o.cursor = o.items.items.len -| 1;
    app.needs_render = true;
}

fn languageKey(path: ?[]const u8, buf: []u8) []const u8 {
    const p = path orelse return "";
    const ext = std.fs.path.extension(p);
    if (ext.len < 2 or ext.len - 1 > buf.len) return "";
    return std.ascii.lowerString(buf[0 .. ext.len - 1], ext[1..]);
}

/// Put the source cursor on item `idx` and focus the source.
pub fn jump(app: *App, id: PaneId, idx: usize) void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    if (idx >= o.items.items.len) return;
    const s = o.items.items[idx];
    o.cursor = idx;
    const src = app.panes.editor(o.source) orelse return;
    src.buf.editor.anchor = null;
    src.buf.editor.placeCursor(@min(s.line, @as(u32, @intCast(src.buf.editor.lineCount() - 1))), s.col);
    app.setActive(o.source);
}

/// A click on a row: the hit names the source line/col; find the item.
pub fn clickRow(app: *App, id: PaneId, line: u32, col: u32) void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    for (o.items.items, 0..) |s, i| if (s.line == line and s.col == col) return jump(app, id, i);
}

pub fn close(app: *App, id: PaneId) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const o = pane.asOutline() orelse return;
    const back = o.source;
    try app.forceClosePane(id);
    if (app.panes.get(back) != null) app.setActive(back);
}

/// Keys while the outline has focus. False lets the chord chain see it.
pub fn handleKey(app: *App, id: PaneId, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const pane = app.panes.get(id) orelse return false;
    const o = pane.asOutline() orelse return false;
    const n = o.items.items.len;
    const page = @max(app.pane_rows -| outline_view.header_rows, 1);
    switch (k.code) {
        .down => o.cursor = @min(o.cursor + 1, n -| 1),
        .up => o.cursor -|= 1,
        .home => o.cursor = 0,
        .end => o.cursor = n -| 1,
        .page_down => o.cursor = @min(o.cursor + page, n -| 1),
        .page_up => o.cursor -|= page,
        .enter => jump(app, id, o.cursor),
        .esc => app.setActive(o.source),
        .char => |c| switch (c) {
            'j' => o.cursor = @min(o.cursor + 1, n -| 1),
            'k' => o.cursor -|= 1,
            'g' => o.cursor = 0,
            'G' => o.cursor = n -| 1,
            'r' => try refresh(app, id),
            'q' => try close(app, id),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// One frame of the pane: refresh when the source changed since the
/// last frame, then paint with the source cursor's item highlighted.
pub fn draw(app: *App, ui: Ui, id: PaneId, o: *OutlinePane, area: Rect) Allocator.Error!void {
    var current: ?usize = null;
    if (app.panes.editor(o.source)) |src| {
        if (src.hl_dirty or o.items.items.len == 0) try refresh(app, id);
        current = o.itemAt(@intCast(src.buf.editor.currentLine()));
        // Follow the source cursor when the outline is not being driven.
        if (app.active != id) if (current) |c| {
            o.cursor = c;
        };
    }
    const rows = try ui.arena.alloc(outline_view.Row, o.items.items.len);
    for (o.items.items, 0..) |s, i| rows[i] = .{ .name = s.name, .kind = s.kind, .line = s.line, .col = s.col, .depth = s.depth };
    outline_view.draw(ui, id, area, &o.scroll, .{ .title = o.title, .rows = rows, .cursor = o.cursor, .current = current, .focused = app.active == id });
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
const kt_rules = [_]Rule{ .{ .keyword = "fun", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "object", .kind = .module } };
const swift_rules = [_]Rule{ .{ .keyword = "func", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "struct", .kind = .@"struct" }, .{ .keyword = "enum", .kind = .@"enum" }, .{ .keyword = "protocol", .kind = .interface }, .{ .keyword = "extension", .kind = .impl } };
const zig_rules = [_]Rule{ .{ .keyword = "fn", .kind = .function }, .{ .keyword = "const", .kind = .constant } };
const lua_rules = [_]Rule{.{ .keyword = "function", .kind = .function }};
const php_rules = [_]Rule{ .{ .keyword = "function", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "interface", .kind = .interface }, .{ .keyword = "trait", .kind = .trait } };
const ex_rules = [_]Rule{ .{ .keyword = "def", .kind = .function }, .{ .keyword = "defp", .kind = .function }, .{ .keyword = "defmodule", .kind = .module } };
const scala_rules = [_]Rule{ .{ .keyword = "def", .kind = .function }, .{ .keyword = "class", .kind = .class }, .{ .keyword = "object", .kind = .module }, .{ .keyword = "trait", .kind = .trait } };

const modifiers = [_][]const u8{ "pub", "export", "default", "async", "static", "final", "abstract", "public", "private", "protected", "unsafe", "extern", "override", "inline", "virtual", "declare", "internal", "open", "sealed", "data", "readonly", "partial" };
const c_control = [_][]const u8{ "if", "while", "for", "switch", "return", "else", "do", "sizeof", "case" };

fn rulesFor(key: []const u8) ?[]const Rule {
    const KV = struct { []const u8, []const Rule };
    const map = [_]KV{
        .{ "rs", &rust_rules },     .{ "py", &py_rules },   .{ "js", &js_rules },   .{ "jsx", &js_rules },    .{ "ts", &js_rules },   .{ "tsx", &js_rules },
        .{ "mjs", &js_rules },      .{ "cjs", &js_rules },  .{ "go", &go_rules },   .{ "rb", &rb_rules },     .{ "c", &c_rules },     .{ "h", &c_rules },
        .{ "cpp", &c_rules },       .{ "cc", &c_rules },    .{ "hpp", &c_rules },   .{ "java", &java_rules }, .{ "cs", &java_rules }, .{ "kt", &kt_rules },
        .{ "swift", &swift_rules }, .{ "zig", &zig_rules }, .{ "lua", &lua_rules }, .{ "php", &php_rules },   .{ "ex", &ex_rules },   .{ "exs", &ex_rules },
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

fn indentDepth(line: []const u8) u8 {
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
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 20 });
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
