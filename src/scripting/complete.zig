//! The app as the language server for its own API. In an `init.lua`
//! (either of the two) or any `.lua` under `<workspace>/.mnml/`, the
//! completion popup fills from what the app knows and no server can:
//! after `mnml.` / `mnml.buf.` the functions of the `mnml` table
//! (`api.zig`'s own registration list, so the popup can never name a
//! function that is not there); after `mnml.on("` the hook names;
//! inside `mnml.run("` / `mnml.map("…", "` the command ids; inside
//! `mnml.map("` and `keys = { "` the key specs, one token at a time;
//! inside `fg = "` / `bg = "` the theme roles. Hover (`K`) on a command
//! id shows its title and chords, on an API path its doc line, on a
//! hook name what it carries.
//!
//! The rows go through the same popup a server's do
//! (`lsp.openLocalCompletion`: a `Completion` with no server), so the
//! keys, the mouse, the filtering and the accept are the ones the user
//! already has. A language server for Lua, when one is installed, takes
//! the rest of the file: this source answers only where it has rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const api = @import("api.zig");
const diag = @import("diag.zig");
const hooks = @import("../core/hooks.zig");
const command = @import("../core/command.zig");
const keymap = @import("../core/keymap.zig");
const types = @import("../lsp/types.zig");
const lsp = @import("../app/lsp.zig");
const script_view = @import("../ui/script_view.zig");

/// LSP `CompletionItemKind`s the rows use (`types.completionKindLabel`).
const kind_fn: u8 = 3;
const kind_module: u8 = 9;
const kind_event: u8 = 23;
const kind_keyword: u8 = 14;
const kind_color: u8 = 16;

/// Whether `path` (absolute) is a script this source completes: either
/// `init.lua`, or any `.lua` under `<workspace>/.mnml/`.
pub fn isScriptPath(app: *App, path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".lua")) return false;
    if (diag.isInitPath(app, path)) return true;
    const dir = std.fs.path.join(app.frame.allocator(), &.{ app.workspace, ".mnml" }) catch return false;
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
}

pub const Context = union(enum) {
    /// The functions under `mnml` or `mnml.<table>` (the parent path).
    api: []const u8,
    hooks,
    commands,
    /// One token of a key spec: what came before it on the same chord
    /// (`ctrl+shift+`, empty for the first) is `head`.
    keys: struct { head: []const u8 },
    roles,
};

pub const Result = struct {
    /// Where the word being completed starts (the popup's filter word
    /// is `text[start..cursor]`).
    start: usize,
    ctx: Context,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isPathChar(c: u8) bool {
    return isIdent(c) or c == '.';
}

/// The `[\w.]+` run ending at `end` of `s`.
fn pathBefore(s: []const u8, end: usize) []const u8 {
    var i = end;
    while (i > 0 and isPathChar(s[i - 1])) i -= 1;
    return s[i..end];
}

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " \t");
}

/// Whether `pre` (the line up to the opening quote) ends with a call
/// of `name` — `mnml.on(` — with only spaces after the paren.
fn endsWithCall(pre: []const u8, name: []const u8) bool {
    const t = trimRight(pre);
    if (t.len == 0 or t[t.len - 1] != '(') return false;
    return std.mem.endsWith(u8, trimRight(t[0 .. t.len - 1]), name);
}

/// Whether `pre` is inside the second argument of `mnml.map(`: a first
/// string closed, then a comma.
fn inMapSecondArg(pre: []const u8) bool {
    const t = trimRight(pre);
    if (t.len == 0 or t[t.len - 1] != ',') return false;
    const call = std.mem.lastIndexOf(u8, t, "mnml.map(") orelse return false;
    // One complete string between the paren and the comma.
    const between = t[call + "mnml.map(".len .. t.len - 1];
    var quotes: usize = 0;
    for (between) |c| if (c == '"' or c == '\'') {
        quotes += 1;
    };
    return quotes == 2;
}

/// Whether `pre` is inside a `keys = …` value: `keys = ` right before
/// the quote, or inside a `{ … }` list that `keys =` opened.
fn inKeys(pre: []const u8) bool {
    const t = trimRight(pre);
    const eq = std.mem.lastIndexOf(u8, t, "keys") orelse return false;
    const after = std.mem.trim(u8, t[eq + 4 ..], " \t");
    if (after.len == 0 or after[0] != '=') return false;
    var rest = std.mem.trim(u8, after[1..], " \t");
    if (rest.len == 0) return true;
    if (rest[0] != '{') return false;
    rest = rest[1..];
    // Still inside the list: no closing brace since.
    return std.mem.indexOfScalar(u8, rest, '}') == null;
}

/// Whether `pre` ends with `<name> =` (a table field about to get a string).
fn endsWithField(pre: []const u8, name: []const u8) bool {
    const t = trimRight(pre);
    if (t.len == 0 or t[t.len - 1] != '=') return false;
    const before = trimRight(t[0 .. t.len - 1]);
    if (!std.mem.endsWith(u8, before, name)) return false;
    const at = before.len - name.len;
    return at == 0 or !isIdent(before[at - 1]);
}

/// The completion context at `cursor` of `text`, if any.
pub fn contextAt(text: []const u8, cursor: usize) ?Result {
    const cur = @min(cursor, text.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..cur], '\n')) |nl| nl + 1 else 0;
    const before = text[line_start..cur];
    // Inside a string: the last quote on the line that is still open.
    // Past a `--` outside a string is a comment: nothing to complete.
    var q: ?usize = null;
    var open: u8 = 0;
    for (before, 0..) |c, i| {
        if (open == 0) {
            if (c == '"' or c == '\'') {
                open = c;
                q = i;
            } else if (c == '-' and i + 1 < before.len and before[i + 1] == '-') return null;
        } else if (c == open and (i == 0 or before[i - 1] != '\\')) {
            open = 0;
            q = null;
        }
    }
    if (q) |qi| {
        const pre = before[0..qi];
        const inner = before[qi + 1 ..];
        const inner_start = line_start + qi + 1;
        if (endsWithCall(pre, "mnml.on")) return .{ .start = inner_start, .ctx = .hooks };
        if (endsWithCall(pre, "mnml.run") or inMapSecondArg(pre)) return .{ .start = inner_start, .ctx = .commands };
        if (endsWithCall(pre, "mnml.map") or inKeys(pre)) {
            // The token under way: after the last space (a chord boundary)
            // and the last `+` (a modifier boundary).
            const chord_at = if (std.mem.lastIndexOfScalar(u8, inner, ' ')) |sp| sp + 1 else 0;
            const chord = inner[chord_at..];
            const plus = if (std.mem.lastIndexOfScalar(u8, chord, '+')) |p| p + 1 else 0;
            return .{ .start = inner_start + chord_at + plus, .ctx = .{ .keys = .{ .head = chord[0..plus] } } };
        }
        if (endsWithField(pre, "fg") or endsWithField(pre, "bg")) return .{ .start = inner_start, .ctx = .roles };
        return null;
    }
    // An API path: `mnml.` / `mnml.buf.` and the identifier under way.
    var w = cur;
    while (w > line_start and isIdent(text[w - 1])) w -= 1;
    if (w == line_start or text[w - 1] != '.') return null;
    const parent = pathBefore(text, w - 1);
    if (!std.mem.eql(u8, parent, "mnml") and !std.mem.startsWith(u8, parent, "mnml.")) return null;
    return .{ .start = w, .ctx = .{ .api = parent } };
}

fn item(label: []const u8, kind: u8, detail: ?[]const u8, doc: ?[]const u8) types.CompletionItem {
    return .{ .label = label, .kind = kind, .detail = detail, .documentation = doc, .insert_text = label, .format = .plain, .edit_range = null, .sort_text = null, .filter_text = null, .raw = .null };
}

/// The API rows keep this file's order rather than the alphabet: the
/// sort key is the index. Under `mnml.` that order puts the
/// SUB-TABLES first — `buf`, `decor`, `picker`, … — because a reader
/// who has just typed `mnml.` is looking for an area, and the popup
/// shows ten rows: with the root functions first, `buf` and `decor`
/// were below the fold and only a letter reached them.
fn ordered(arena: Allocator, it: types.CompletionItem, index: usize) Allocator.Error!types.CompletionItem {
    var out = it;
    out.sort_text = try std.fmt.allocPrint(arena, "{d:0>3}", .{index});
    return out;
}

/// What each hook carries — the popup's detail and the hover.
pub fn hookDoc(h: hooks.Hook) []const u8 {
    return switch (h) {
        .startup => "once, after every init.lua and the startup tasks",
        .exit => "on quit",
        .open => "{ path, pane } — a file opened in an editor pane",
        .save_pre => "{ path, pane } — before the bytes are written",
        .save_post => "{ path, pane, bytes } — after a save",
        .buffer_change => "{ pane, line_count } — 150 ms after the last edit",
        .cursor_idle => "{ pane, line } — 300 ms after the cursor last moved, once per resting place",
        .diagnostics => "{ path, errors, warnings } — a language server published",
        .pane_focus => "{ pane } — focus moved (pane is nil when nothing has it)",
        .lsp_attach => "{ server, pane } — a server took a buffer",
        .git_status => "{ branch, dirty } — the status refreshed",
        .http_request => "{ pane, method, url, headers, body, env } — a request pane is about to send; return a table to rewrite it",
        .http_response => "{ pane, status, headers, body, body_truncated, timing_ms } — a response landed on a request pane",
    };
}

/// The doc line of an API path (`mnml.buf.text`, `mnml.buf`, `mnml`).
pub fn apiDoc(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "mnml")) return "the mnml table — everything a script can reach (docs/LUA.md)";
    if (!std.mem.startsWith(u8, path, "mnml.")) return null;
    const rest = path["mnml.".len..];
    inline for (api.root_fns) |e| if (std.mem.eql(u8, rest, e.name)) return e.doc;
    inline for (api.tables) |t| {
        if (std.mem.eql(u8, rest, t.name)) return t.doc;
        if (std.mem.startsWith(u8, rest, t.name ++ ".")) {
            const leaf = rest[t.name.len + 1 ..];
            inline for (t.fns) |e| if (std.mem.eql(u8, leaf, e.name)) return e.doc;
        }
    }
    return null;
}

/// The named keys a spec may use, and the modifiers.
const named_keys = [_][]const u8{ "enter", "tab", "backtab", "esc", "space", "backspace", "delete", "insert", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" };
const modifiers = [_][]const u8{ "ctrl", "alt", "shift", "super" };

/// The rows for `ctx`, on `arena`.
pub fn itemsFor(app: *App, arena: Allocator, ctx: Context) Allocator.Error![]types.CompletionItem {
    var out: std.ArrayListUnmanaged(types.CompletionItem) = .empty;
    switch (ctx) {
        .api => |parent| {
            if (std.mem.eql(u8, parent, "mnml")) {
                inline for (api.tables, 0..) |t, i| try out.append(arena, try ordered(arena, item(t.name, kind_module, "table", t.doc), i));
                inline for (api.root_fns, 0..) |e, i| try out.append(arena, try ordered(arena, item(e.name, kind_fn, "mnml", e.doc), api.tables.len + i));
            } else {
                const rest = parent["mnml.".len..];
                inline for (api.tables) |t| if (std.mem.eql(u8, rest, t.name)) {
                    inline for (t.fns, 0..) |e, i| try out.append(arena, try ordered(arena, item(e.name, kind_fn, parent, e.doc), i));
                };
            }
        },
        .hooks => {
            inline for (std.enums.values(hooks.Hook)) |h| try out.append(arena, item(@tagName(h), kind_event, "hook", hookDoc(h)));
        },
        .commands => {
            var i: usize = 0;
            while (i < command.count) : (i += 1) {
                const id: command.CommandId = @enumFromInt(i);
                try out.append(arena, item(command.name(id), kind_fn, command.group(id), command.title(id)));
            }
            for (app.dyn_commands.list.items, app.dyn_commands.live.items) |c, alive| {
                if (!alive) continue;
                try out.append(arena, item(try arena.dupe(u8, c.id), kind_fn, try arena.dupe(u8, c.group), try arena.dupe(u8, c.title)));
            }
        },
        .keys => |k| {
            // A modifier not yet in the head, then the keys.
            for (modifiers) |m| {
                if (std.mem.indexOf(u8, k.head, m) != null) continue;
                try out.append(arena, item(try std.fmt.allocPrint(arena, "{s}+", .{m}), kind_keyword, "modifier", "a modifier — the key follows"));
            }
            for (named_keys) |n| try out.append(arena, item(n, kind_keyword, "key", null));
            var c: u8 = 'a';
            while (c <= 'z') : (c += 1) try out.append(arena, item(try arena.dupe(u8, &.{c}), kind_keyword, "key", null));
            c = '0';
            while (c <= '9') : (c += 1) try out.append(arena, item(try arena.dupe(u8, &.{c}), kind_keyword, "key", null));
        },
        .roles => {
            inline for (std.enums.values(script_view.Role)) |r| try out.append(arena, item(@tagName(r), kind_color, "theme role", null));
        },
    }
    return out.items;
}

/// A char typed in `e` (`pane`): when the cursor is in a context this
/// source knows, the popup opens with its rows (or stays open and
/// keeps filtering); true then, so the language server is not asked.
pub fn onTyped(app: *App, pane: PaneId, e: *EditorPane, c: u21) Allocator.Error!bool {
    _ = c;
    const path = e.buf.doc.path orelse return false;
    if (!isScriptPath(app, path)) return false;
    const ed = e.buf.editor;
    const r = contextAt(ed.bytes(), ed.cursor) orelse return false;
    if (app.lsp.completion) |comp| if (comp.pane == pane and comp.server == null and comp.start == r.start) return true;
    const items = try itemsFor(app, app.frame.allocator(), r.ctx);
    try lsp.openLocalCompletion(app, pane, r.start, items, false);
    return true;
}

/// `lsp.completion` (ctrl+space) in a script: the popup with this
/// source's rows when the cursor is in one of its contexts.
pub fn manual(app: *App) Allocator.Error!bool {
    const pane = app.active orelse return false;
    const e = app.panes.editor(pane) orelse return false;
    const path = e.buf.doc.path orelse return false;
    if (!isScriptPath(app, path)) return false;
    const ed = e.buf.editor;
    const r = contextAt(ed.bytes(), ed.cursor) orelse return false;
    const items = try itemsFor(app, app.frame.allocator(), r.ctx);
    try lsp.openLocalCompletion(app, pane, r.start, items, true);
    return true;
}

/// The chords of a command under the active profile, ` / `-joined.
fn chordsOf(app: *App, arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lists: [2][]const []const u8 = .{ &.{}, &.{} };
    if (command.by_name.get(id)) |cid| {
        const keys = command.spec(cid).keys;
        lists[0] = keys.both;
        lists[1] = switch (App.profileOf(app.input_style)) {
            .vim => keys.vim,
            .standard => keys.standard,
        };
    } else if (app.dyn_commands.get(id)) |slot| {
        if (app.dyn_commands.at(slot)) |c| lists[0] = c.keys;
    }
    for (lists) |list| for (list) |spec| {
        if (out.items.len > 0) try out.appendSlice(arena, " / ");
        var buf: [64]u8 = undefined;
        try out.appendSlice(arena, keymap.normalizeSpec(spec, &buf) orelse spec);
    };
    return out.items;
}

/// The hover lines for the thing at `cursor` of `text`: a command id
/// (in a string), a hook name (in a string), an API path. Null when
/// there is nothing this source knows there.
pub fn hoverLines(app: *App, arena: Allocator, text: []const u8, cursor: usize) Allocator.Error!?[]const []const u8 {
    const cur = @min(cursor, text.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..cur], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, cur, '\n') orelse text.len;
    const line = text[line_start..line_end];
    const col = cur - line_start;
    // Inside a string on the line?
    var q_open: ?usize = null;
    var open: u8 = 0;
    for (line, 0..) |c, i| {
        if (i > col) break;
        if (open == 0) {
            if (c == '"' or c == '\'') {
                open = c;
                q_open = i;
            }
        } else if (c == open) {
            open = 0;
            q_open = null;
        }
    }
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    if (q_open) |qi| {
        const close = std.mem.indexOfScalarPos(u8, line, qi + 1, open) orelse line.len;
        const word = line[qi + 1 .. close];
        if (command.by_name.get(word)) |cid| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "{s} — {s}", .{ word, command.title(cid) }));
            const chords = try chordsOf(app, arena, word);
            try lines.append(arena, try std.fmt.allocPrint(arena, "group {s} · {s}", .{ command.group(cid), if (chords.len > 0) chords else "no default chord" }));
            return lines.items;
        }
        if (app.dyn_commands.get(word)) |slot| if (app.dyn_commands.at(slot)) |c| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "{s} — {s}", .{ word, c.title }));
            const chords = try chordsOf(app, arena, word);
            try lines.append(arena, try std.fmt.allocPrint(arena, "group {s} · {s}", .{ c.group, if (chords.len > 0) chords else "no chord" }));
            return lines.items;
        };
        if (std.meta.stringToEnum(hooks.Hook, word)) |h| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "hook {s}", .{word}));
            try lines.append(arena, hookDoc(h));
            return lines.items;
        }
        return null;
    }
    // The `[\w.]+` run under the cursor.
    var s = col;
    while (s > 0 and isPathChar(line[s - 1])) s -= 1;
    var e = col;
    while (e < line.len and isPathChar(line[e])) e += 1;
    const path = std.mem.trim(u8, line[s..e], ".");
    const doc = apiDoc(path) orelse return null;
    try lines.append(arena, path);
    try lines.append(arena, doc);
    return lines.items;
}

/// `lsp.hover` (`K`) in a script: the box with what this source knows
/// about the thing under the cursor; false when it knows nothing there.
pub fn hover(app: *App) Allocator.Error!bool {
    const pane = app.active orelse return false;
    const e = app.panes.editor(pane) orelse return false;
    const path = e.buf.doc.path orelse return false;
    if (!isScriptPath(app, path)) return false;
    const ed = e.buf.editor;
    const lines = (try hoverLines(app, app.frame.allocator(), ed.bytes(), ed.cursor)) orelse return false;
    try lsp.showHoverLines(app, pane, ed.cursor, lines);
    return true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn ctxOf(text: []const u8) ?Result {
    return contextAt(text, text.len);
}

test "contextAt: the API path, hooks, commands, keys (per token), roles; nothing elsewhere" {
    try testing.expectEqualStrings("mnml", ctxOf("mnml.").?.ctx.api);
    try testing.expectEqual(@as(usize, 5), ctxOf("mnml.").?.start);
    try testing.expectEqualStrings("mnml", ctxOf("  x = mnml.com").?.ctx.api);
    try testing.expectEqual(@as(usize, 11), ctxOf("  x = mnml.com").?.start);
    try testing.expectEqualStrings("mnml.buf", ctxOf("local t = mnml.buf.te").?.ctx.api);
    try testing.expect(ctxOf("other.") == null);
    try testing.expect(ctxOf("mnml") == null);
    try testing.expect(ctxOf("x = 1") == null);
    try testing.expect(ctxOf("-- mnml.") == null);
    try testing.expectEqual(Context.hooks, ctxOf("mnml.on(\"sav").?.ctx);
    try testing.expectEqual(@as(usize, 9), ctxOf("mnml.on(\"sav").?.start);
    try testing.expectEqual(Context.hooks, ctxOf("mnml.on( 'x").?.ctx);
    try testing.expectEqual(Context.commands, ctxOf("mnml.run(\"file.").?.ctx);
    try testing.expectEqual(Context.commands, ctxOf("mnml.map(\"ctrl+s\", \"fi").?.ctx);
    try testing.expectEqual(@as(usize, 20), ctxOf("mnml.map(\"ctrl+s\", \"fi").?.start);
    // Keys: the token after the last `+` of the last chord.
    const k1 = ctxOf("mnml.map(\"ctrl+shift+").?;
    try testing.expectEqualStrings("ctrl+shift+", k1.ctx.keys.head);
    try testing.expectEqual(@as(usize, 21), k1.start);
    const k2 = ctxOf("  keys = { \"space u\", \"ctrl+").?;
    try testing.expectEqualStrings("ctrl+", k2.ctx.keys.head);
    try testing.expectEqual(@as(usize, 28), k2.start);
    const k3 = ctxOf("  keys = \"space ").?;
    try testing.expectEqualStrings("", k3.ctx.keys.head);
    try testing.expectEqual(@as(usize, 16), k3.start);
    try testing.expect(ctxOf("  keys = { \"a\" }, run = \"x") == null);
    try testing.expectEqual(Context.roles, ctxOf("{ text = 'x', fg = \"acc").?.ctx);
    try testing.expectEqual(Context.roles, ctxOf("bg='").?.ctx);
    // A closed string is not a context; a string on a `title` is not either.
    try testing.expect(ctxOf("mnml.on(\"save_post\")") == null);
    try testing.expect(ctxOf("title = \"Say ") == null);
}

test "itemsFor: every API function and table, the hooks, the ids, the key tokens, the roles" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    const arena = app.frame.allocator();
    const root = try itemsFor(&app, arena, .{ .api = "mnml" });
    try testing.expectEqual(api.root_fns.len + api.tables.len, root.len);
    // The sub-tables come first: `mnml.` is typed to find an area, and
    // the popup only shows ten rows.
    try testing.expectEqualStrings("buf", root[0].label);
    try testing.expectEqual(kind_module, root[0].kind);
    try testing.expect(std.mem.startsWith(u8, root[0].documentation.?, "mnml.buf —"));
    // Every table is above every root function, by the sort key the
    // popup orders on and not just by the order they were appended.
    for (root[0..api.tables.len]) |r| try testing.expectEqual(kind_module, r.kind);
    for (root[api.tables.len..]) |r| try testing.expectEqual(kind_fn, r.kind);
    var last: []const u8 = "";
    for (root) |r| {
        try testing.expect(std.mem.order(u8, last, r.sort_text.?) == .lt);
        last = r.sort_text.?;
    }
    try testing.expectEqualStrings("command", root[api.tables.len].label);
    try testing.expect(std.mem.startsWith(u8, root[api.tables.len].documentation.?, "mnml.command{ id"));
    const buf = try itemsFor(&app, arena, .{ .api = "mnml.buf" });
    try testing.expectEqual(@as(usize, 9), buf.len);
    try testing.expectEqualStrings("apply", buf[5].label);
    try testing.expectEqualStrings("word_at", buf[8].label);
    try testing.expectEqual(@as(usize, 0), (try itemsFor(&app, arena, .{ .api = "mnml.nope" })).len);
    const hs = try itemsFor(&app, arena, .hooks);
    try testing.expectEqual(std.enums.values(hooks.Hook).len, hs.len);
    try testing.expectEqualStrings("save_post", hs[4].label);
    try testing.expectEqualStrings(hookDoc(.save_post), hs[4].documentation.?);
    // Commands: every static id, then the script's.
    try app.script().runString("mnml.command{ id = 'hello', title = 'Say hello', run = function() end }");
    const cs = try itemsFor(&app, arena, .commands);
    try testing.expectEqual(command.count + 1, cs.len);
    try testing.expectEqualStrings("app.quit", cs[0].label);
    try testing.expectEqualStrings("Quit mnml", cs[0].documentation.?);
    try testing.expectEqualStrings("user.hello", cs[cs.len - 1].label);
    // Keys: the modifiers not in the head, the named keys, a-z, 0-9.
    const ks = try itemsFor(&app, arena, .{ .keys = .{ .head = "ctrl+" } });
    try testing.expectEqualStrings("alt+", ks[0].label);
    try testing.expectEqual(3 + named_keys.len + 26 + 10, ks.len);
    const ks0 = try itemsFor(&app, arena, .{ .keys = .{ .head = "" } });
    try testing.expectEqualStrings("ctrl+", ks0[0].label);
    const rs = try itemsFor(&app, arena, .roles);
    try testing.expectEqual(std.enums.values(script_view.Role).len, rs.len);
    try testing.expectEqualStrings("accent", rs[2].label);
}

test "typing in a workspace .mnml script opens the popup with the API rows; Enter inserts; a plain file gets nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .workspace_trusted = true, .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    const path = try std.fs.path.join(testing.allocator, &.{ root, ".mnml", "init.lua" });
    defer testing.allocator.free(path);
    const id = try app.openEditor(path);
    try testing.expect(isScriptPath(&app, path));
    const Key = app_mod.Key;
    for ("mnml.") |c| try app.handle(.{ .key = Key.char(c) });
    try testing.expect(app.lsp.completion != null);
    try testing.expect(app.lsp.completion.?.server == null);
    try testing.expectEqual(@as(usize, 5), app.lsp.completion.?.start);
    try testing.expectEqual(api.root_fns.len + api.tables.len, app.lsp.completion.?.items.len);
    // The popup paints its rows.
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    // The sub-tables are the first rows now, so every area a reader is
    // looking for is on screen without typing a letter; the root
    // functions follow, and `toast` falls past the popup's ten rows.
    try testing.expect(std.mem.indexOf(u8, txt, "decor") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "diagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "command") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "buf").? < std.mem.indexOf(u8, txt, "command").?);
    try testing.expect(std.mem.indexOf(u8, txt, "toast") == null);
    // Typing narrows; Enter inserts the row.
    for ("toa") |c| try app.handle(.{ .key = Key.char(c) });
    try testing.expect(app.lsp.completion != null);
    const vis = try lsp.visibleCompletions(&app, app.frame.allocator());
    try testing.expectEqualStrings("toast", app.lsp.completion.?.items[vis[0]].label);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(app.lsp.completion == null);
    const e = app.panes.editor(id).?;
    try testing.expectEqualStrings("mnml.toast", e.buf.editor.bytes());
    // A hook name after `mnml.on("`.
    for ("(\"") |c| try app.handle(.{ .key = Key.char(c) });
    try testing.expect(app.lsp.completion == null);
    try app.splice(e, 0, e.buf.editor.len(), "mnml.on(\"");
    try app.handle(.{ .key = Key.char('s') });
    try testing.expect(app.lsp.completion != null);
    try testing.expectEqual(std.enums.values(hooks.Hook).len, app.lsp.completion.?.items.len);
    lsp.closeCompletion(&app);
    // ctrl+space in a context, and the hover.
    try app.splice(e, 0, e.buf.editor.len(), "mnml.run(\"file.save\")");
    e.buf.editor.setCursor(15);
    try command.run(&app, .{ .static = .@"lsp.hover" });
    try testing.expect(app.lsp.hover != null);
    try testing.expectEqualStrings("file.save — Save file", app.lsp.hover.?.pages[0][0]);
    try testing.expect(std.mem.indexOf(u8, app.lsp.hover.?.pages[0][1], "ctrl+s") != null);
    lsp.closeHover(&app);
    e.buf.editor.setCursor(6);
    try command.run(&app, .{ .static = .@"lsp.hover" });
    try testing.expectEqualStrings("mnml.run", app.lsp.hover.?.pages[0][0]);
    lsp.closeHover(&app);
    try app.splice(e, 0, e.buf.editor.len(), "mnml.map(\"ctrl+");
    try command.run(&app, .{ .static = .@"lsp.completion" });
    try testing.expect(app.lsp.completion != null);
    try testing.expect(app.lsp.completion.?.manual);
    try testing.expectEqualStrings("alt+", app.lsp.completion.?.items[0].label);
    lsp.closeCompletion(&app);
    // A plain file: this source stays out (and there is no server).
    const other = try std.fs.path.join(testing.allocator, &.{ root, "notes.lua" });
    defer testing.allocator.free(other);
    _ = try app.openEditor(other);
    try testing.expect(!isScriptPath(&app, other));
    for ("mnml.") |c| try app.handle(.{ .key = Key.char(c) });
    try testing.expect(app.lsp.completion == null);
}
