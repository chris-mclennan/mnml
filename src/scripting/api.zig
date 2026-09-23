//! The `mnml` table (D10) — everything a script can reach. Each entry
//! is a `zlua.wrap`ped `fn (L: *State) !i32` that finds its `*Lua`
//! (and through it the App of the call in flight) from the state's
//! extra space; `*App` itself is never on the Lua side.
//!
//! What crosses in at registration (`mnml.command`, `mnml.on`,
//! `mnml.statusline.segment`, …) is duped onto the gpa or held as a
//! registry ref; what crosses in at call time (`mnml.buf.apply`'s text,
//! a picker query) lives on the frame arena; what crosses out
//! (`mnml.buf.text`) is a Lua-owned copy. Buffer mutation goes through
//! `mnml.buf.apply{ op = … }` → `EditOp` → `App.applyOps`, so undo,
//! dot-repeat, the LSP and tree-sitter all see it.
//!
//! An argument that is the wrong shape raises a Lua error (`argError`)
//! — the script's `pcall` boundary turns it into a toast with the line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlua = @import("zlua");
const lua_mod = @import("lua.zig");
const Lua = lua_mod.Lua;
const State = lua_mod.State;
const LuaRef = lua_mod.LuaRef;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const hooks = @import("../core/hooks.zig");
const edit_op = @import("../editor/edit_op.zig");
const EditOp = edit_op.EditOp;
const config = @import("../config/root.zig");
const Config = config.Config;
const Dynamic = config.Dynamic;
const script_pane = @import("../app/script_pane.zig");
const cmd_picker = @import("../app/cmd_picker.zig");
const runners = @import("../app/runners.zig");
const Side = config.Side;

/// The prefix every script command gets: `mnml.command{ id = "hello" }`
/// is `user.hello` in the palette, `.keys`, `.test` and IPC.
pub const id_prefix = "user.";

/// One `mnml.*` function: its name in the table, the doc line the
/// completion popup and the hover show, the Zig function behind it.
pub const Fn = struct { name: [:0]const u8, doc: []const u8, func: fn (*State) anyerror!i32 };
/// One sub-table (`mnml.buf`, …): its name, its doc line, its functions.
pub const Table = struct { name: [:0]const u8, doc: []const u8, fns: []const Fn };

fn fnOf(name: [:0]const u8, doc: []const u8, func: fn (*State) anyerror!i32) Fn {
    return .{ .name = name, .doc = doc, .func = func };
}

/// The functions directly on `mnml`. `install` builds the table from
/// this list and `complete.zig` reads it — the popup can never name a
/// function that is not there.
pub const root_fns = [_]Fn{
    fnOf("command", "mnml.command{ id, title?, group?, keys?, run } → \"user.<id>\" — a palette command; keys is a chord spec or a list", cmdRegister),
    fnOf("map", "mnml.map(spec, fn | command id) → \"user.map_N\" — a command bound to one chord", map),
    fnOf("on", "mnml.on(hook, fn) — subscribe; fn gets a flat table of the hook's fields plus hook = \"<name>\"", on),
    fnOf("toast", "mnml.toast(text, \"info\" | \"warn\" | \"error\") — a toast", toast),
    fnOf("run", "mnml.run(id) → true | false, reason — run any command, built-in or script", run),
    fnOf("ex", "mnml.ex(line) → true | false, reason — a \":\" line without the colon", ex),
    fnOf("workspace", "mnml.workspace() → the absolute workspace path", workspace),
    fnOf("data_root", "mnml.data_root() → the data root (~/.config/mnml, or MNML_DATA_ROOT)", dataRoot),
    fnOf("redraw", "mnml.redraw() — ask for a frame (a key or click already implies one)", redraw),
    fnOf("inspect", "mnml.inspect(v) → a string — any value written out for reading: tables walked 4 deep with their keys sorted, a repeat marked <cycle>, anything deeper {…}", inspect),
    fnOf("commands", "mnml.commands(query?) → { { id, title, group, keys = { … }, rank }, … } — every command, built-in and script, narrowed by a substring on the id or the title; rank is its place in the MRU, 1 = the one run most recently, nil = never run", commandsList),
    fnOf("list", "mnml.list{ title, rows = fn(sort), on_enter?, on_menu?, sort? } → a list handle with :refresh(); host it with pane.open{ list = } or section{ list = }", listRegister),
    fnOf("section", "mnml.section{ id, title, glyph?, ascii?, list, side?, after? } — a rail section of your own, with the caps header, filter, sort chip and folds every built-in has", sectionRegister),
    fnOf("operator", "mnml.operator{ id, keys = { vim = \"g<letter>\", standard = \"chord\" }, run = fn(range) } — operator-pending under vim, the selection or the cursor's word under standard", operatorRegister),
};

pub const tables = [_]Table{
    .{ .name = "buf", .doc = "mnml.buf — the active (or a given) editor pane's text, cursor and path; apply is the one way to change it", .fns = &.{
        fnOf("text", "mnml.buf.text(pane?) → the whole text", bufText),
        fnOf("line", "mnml.buf.line(n, pane?) → line n (1-based), or nil past the end", bufLine),
        fnOf("line_count", "mnml.buf.line_count(pane?) → how many lines", bufLineCount),
        fnOf("cursor", "mnml.buf.cursor(pane?) → line, col (1-based), byte (0-based)", bufCursor),
        fnOf("path", "mnml.buf.path(pane?) → the workspace-relative path, nil for a scratch buffer", bufPath),
        fnOf("apply", "mnml.buf.apply({ op = \"…\", … }, pane?) → true when the text changed — an EditOp, so undo, dot-repeat and the LSP see it", bufApply),
        fnOf("selection", "mnml.buf.selection(pane?) → { start, [\"end\"], mode = \"char\" | \"line\" | \"block\" }, or nil when nothing is selected", bufSelection),
        fnOf("range", "mnml.buf.range(start, end_, pane?) → the text between two bytes (0-based, end exclusive)", bufRange),
        fnOf("word_at", "mnml.buf.word_at(byte?, pane?) → { text, start, [\"end\"] } for the word under the byte (the cursor's without one), or nil", bufWordAt),
    } },
    .{ .name = "statusline", .doc = "mnml.statusline — a segment of your own on the statusline", .fns = &.{
        fnOf("segment", "mnml.statusline.segment{ id, side?, fn } — fn() is polled every 250 ms; nil hides it; side is \"left\" | \"right\"", statuslineSegment),
    } },
    .{ .name = "picker", .doc = "mnml.picker — a source of rows for the picker, and the picker over it", .fns = &.{
        fnOf("source", "mnml.picker.source{ id, title?, items = fn(query), live?, multi?, preview?, on_accept? } — items returns strings or { label, detail?, icon?, data?, on_accept? }", pickerSource),
        fnOf("open", "mnml.picker.open(id, query?) — the picker over the source's items", pickerOpen),
    } },
    .{ .name = "pane", .doc = "mnml.pane — a pane the script renders itself", .fns = &.{
        fnOf("open", "mnml.pane.open{ title, render = fn(w, h), on_hit?, on_key? } — or { title, list = l } for a list in a pane → the pane id", paneOpen),
        fnOf("close", "mnml.pane.close(id) — close a script pane", paneClose),
        fnOf("active", "mnml.pane.active() → the focused pane's id, or nil", paneActive),
    } },
    .{ .name = "task", .doc = "mnml.task — a shell command in a task pane (the one way to the shell)", .fns = &.{
        fnOf("run", "mnml.task.run{ cmd, cwd?, label?, on_done? } → the pane id; on_done{ ok, code | signal } fires when it exits", taskRun),
    } },
    .{ .name = "config", .doc = "mnml.config — a read-only copy of the merged config", .fns = &.{
        fnOf("get", "mnml.config.get(path?) → the value under the dotted path (\"editor.tab_width\", \"lsp.rust.cmd\"), or the whole config", configGet),
    } },
    .{ .name = "http", .doc = "mnml.http — the HTTP hooks' way back into the client", .fns = &.{
        fnOf("set_var", "mnml.http.set_var(name, value) → true, or false and the reason; NAME=value into the active env file", httpSetVar),
        fnOf("send", "mnml.http.send(pane?) → fire the request pane (the active one by default); not from inside http_request", httpSend),
    } },
    .{ .name = "decor", .doc = "mnml.decor — what a script paints into an editor without changing its text; every decoration lives in a namespace and follows the text through edits", .fns = &.{
        fnOf("namespace", "mnml.decor.namespace(name) → ns — the handle every other decor call takes; one per concern", decorNamespace),
        fnOf("virtual_text", "mnml.decor.virtual_text(ns, pane, line, segments, { at = \"eol\" | \"above\" | \"below\" }) — text beside (or over / under) a line; segments are strings or { text=, fg=, bg=, bold=, italic=, underline= }", decorVirtualText),
        fnOf("gutter", "mnml.decor.gutter(ns, pane, line, glyph, { fg = role, priority = n }) — one cell in the sign column; priority 50 by default (breakpoints 90, diagnostics 60, git 10)", decorGutter),
        fnOf("highlight", "mnml.decor.highlight(ns, pane, start_byte, end_byte, role) — a theme role over a byte range", decorHighlight),
        fnOf("line", "mnml.decor.line(ns, pane, line, role) — a whole-row ground", decorLine),
        fnOf("clear", "mnml.decor.clear(ns, pane?) → how many went — the namespace's decorations, or only the ones in one pane", decorClear),
    } },
    .{ .name = "diagnostics", .doc = "mnml.diagnostics — publish findings the way a language server does: the gutter, the squiggle, the statusline count, the DIAGNOSTICS panel and ]d all show them", .fns = &.{
        fnOf("set", "mnml.diagnostics.set(ns, path, { { line, col, end_col?, severity, message, source }, … }) — replaces this namespace's list for the file", diagnosticsSet),
        fnOf("clear", "mnml.diagnostics.clear(ns, path?) — this namespace's list for one file, or for every file", diagnosticsClear),
    } },
};

/// Build the `mnml` table and set it as a global.
pub fn install(self: *Lua) void {
    const L = self.L;
    L.newTable();
    inline for (root_fns) |e| put(L, e.name, e.func);
    inline for (tables) |t| {
        L.newTable();
        inline for (t.fns) |e| put(L, e.name, e.func);
        L.setField(-2, t.name);
    }
    L.setGlobal("mnml");
}

fn put(L: *State, name: [:0]const u8, comptime f: anytype) void {
    L.pushFunction(zlua.wrap(f));
    L.setField(-2, name);
}

/// `print(...)` → one toast, the arguments tab-joined like Lua's.
pub fn print(L: *State) !i32 {
    const self = Lua.of(L);
    const app = self.app;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const arena = app.frame.allocator();
    const n = L.getTop();
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) try buf.append(arena, '\t');
        try buf.appendSlice(arena, L.toStringEx(i));
        L.pop(1);
    }
    app.toast("{s}", .{buf.items});
    return 0;
}

// ─── helpers ────────────────────────────────────────────────────────────

fn ctx(L: *State) struct { self: *Lua, app: *App } {
    const self = Lua.of(L);
    return .{ .self = self, .app = self.app };
}

/// A string field of the table at `t`, borrowed from the Lua stack —
/// valid until the next stack write. `numbers` are stringified.
fn strField(L: *State, t: i32, name: [:0]const u8) ?[]const u8 {
    const at = L.absIndex(t);
    switch (L.getField(at, name)) {
        .string => {
            const s = L.toString(-1) catch unreachable;
            L.pop(1);
            return s;
        },
        else => {
            L.pop(1);
            return null;
        },
    }
}

fn intField(L: *State, t: i32, name: [:0]const u8) ?i64 {
    const at = L.absIndex(t);
    _ = L.getField(at, name);
    defer L.pop(1);
    return L.toInteger(-1) catch null;
}

fn boolField(L: *State, t: i32, name: [:0]const u8) ?bool {
    const at = L.absIndex(t);
    _ = L.getField(at, name);
    defer L.pop(1);
    if (L.isNoneOrNil(-1)) return null;
    return L.toBoolean(-1);
}

/// A function field of the table at `t` as a registry ref.
fn fnField(self: *Lua, t: i32, name: [:0]const u8) ?LuaRef {
    const L = self.L;
    const at = L.absIndex(t);
    _ = L.getField(at, name);
    if (L.isFunction(-1)) return self.ref();
    L.pop(1);
    return null;
}

// ─── argument errors ────────────────────────────────────────────────────
// One rule, everywhere below: a wrong argument raises a message that
// names the CALL, the ARGUMENT and the SHAPE it wanted —
// `mnml.picker.source: `items` must be a function(query) returning a
// table of rows`. Lua's own `luaL_check*` messages name the type and a
// `'?'` where the function's name should be, so this file does not use
// them for anything a script author can get wrong.
//
// Every check runs BEFORE the first allocation or registry ref of the
// call. A Lua error is a longjmp out of the C frame: an `errdefer`
// under one never runs, so anything already acquired would leak.

/// Every hook name, `, `-joined — what `mnml.on` shows when it is
/// handed one that is not there. Built from the enum, so a hook added
/// to `core/hooks.zig` is in the message the same day.
pub const hook_names: [:0]const u8 = blk: {
    var out: [:0]const u8 = "";
    for (std.enums.values(hooks.Hook), 0..) |h, i| {
        out = out ++ (if (i > 0) ", " else "") ++ @tagName(h);
    }
    break :blk out;
};

/// A required string field of the table at `t`, else a Lua error
/// naming the call, the field and `shape`.
fn needStr(L: *State, t: i32, name: [:0]const u8, where: [:0]const u8, shape: [:0]const u8) []const u8 {
    return strField(L, t, name) orelse L.raiseErrorStr("%s: `%s` is required and must be %s", .{ where.ptr, name.ptr, shape.ptr });
}

/// A required function field, else the same shape of message. A field
/// that is there but is not a function says so rather than reading as
/// missing.
fn needFn(self: *Lua, t: i32, name: [:0]const u8, where: [:0]const u8, shape: [:0]const u8) LuaRef {
    return fnField(self, t, name) orelse self.L.raiseErrorStr("%s: `%s` must be %s", .{ where.ptr, name.ptr, shape.ptr });
}

/// An optional function field: nil is fine, anything else that is not a
/// function is the error. Checked before the call's first allocation.
fn checkOptFn(L: *State, t: i32, name: [:0]const u8, where: [:0]const u8, shape: [:0]const u8) void {
    const at = L.absIndex(t);
    const kind = L.getField(at, name);
    defer L.pop(1);
    if (kind == .nil or kind == .none) return;
    if (!L.isFunction(-1)) L.raiseErrorStr("%s: `%s` must be %s", .{ where.ptr, name.ptr, shape.ptr });
}

/// A required function field, checked WITHOUT taking a ref — for a call
/// that allocates before it refs, so the check can run first.
fn checkFn(L: *State, t: i32, name: [:0]const u8, where: [:0]const u8, shape: [:0]const u8) void {
    const at = L.absIndex(t);
    _ = L.getField(at, name);
    defer L.pop(1);
    if (!L.isFunction(-1)) L.raiseErrorStr("%s: `%s` must be %s", .{ where.ptr, name.ptr, shape.ptr });
}

/// The one table a `mnml.x{ … }` call takes.
fn needTable(L: *State, arg: i32, where: [:0]const u8, shape: [:0]const u8) void {
    if (L.typeOf(arg) != .table) L.raiseErrorStr("%s takes one table: %s", .{ where.ptr, shape.ptr });
}

/// A positional string argument.
fn argStr(L: *State, arg: i32, where: [:0]const u8, shape: [:0]const u8) []const u8 {
    if (L.typeOf(arg) != .string) L.raiseErrorStr("%s: %s", .{ where.ptr, shape.ptr });
    return L.toString(arg) catch "";
}

/// A positional string argument that may be left out.
fn optArgStr(L: *State, arg: i32, where: [:0]const u8, shape: [:0]const u8) ?[]const u8 {
    if (L.isNoneOrNil(arg)) return null;
    return argStr(L, arg, where, shape);
}

/// A positional integer argument.
fn argInt(L: *State, arg: i32, where: [:0]const u8, shape: [:0]const u8) i64 {
    if (L.typeOf(arg) != .number or !L.isInteger(arg)) L.raiseErrorStr("%s: %s", .{ where.ptr, shape.ptr });
    return L.toInteger(arg) catch 0;
}

/// A positional function argument.
fn argFn(L: *State, arg: i32, where: [:0]const u8, shape: [:0]const u8) void {
    if (!L.isFunction(arg)) L.raiseErrorStr("%s: %s", .{ where.ptr, shape.ptr });
}

/// The `keys` field: a string or a list of strings, onto the frame arena.
fn keysField(L: *State, arena: Allocator, t: i32) Allocator.Error![]const []const u8 {
    const at = L.absIndex(t);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (L.getField(at, "keys")) {
        .string => try out.append(arena, try arena.dupe(u8, L.toString(-1) catch unreachable)),
        .table => {
            const n = L.lenRaw(-1);
            var i: usize = 1;
            while (i <= n) : (i += 1) {
                _ = L.getIndex(-1, @intCast(i));
                if (L.isString(-1)) try out.append(arena, try arena.dupe(u8, L.toString(-1) catch unreachable));
                L.pop(1);
            }
        },
        else => {},
    }
    L.pop(1);
    return out.items;
}

/// The editor pane a `buf.*` call means: the optional pane-id argument
/// at `arg`, else the active editor.
fn editorArg(L: *State, app: *App, arg: i32) *EditorPane {
    if (!L.isNoneOrNil(arg)) {
        const id = argInt(L, arg, "mnml.buf", "`pane` must be a pane id (what mnml.pane.active() answers with), or left out for the active editor");
        if (id < 0 or id > std.math.maxInt(PaneId)) L.raiseErrorStr("mnml.buf: `pane` must be a pane id (what mnml.pane.active() answers with); %d is not one", .{@as(c_int, @intCast(@min(id, std.math.maxInt(c_int))))});
        return app.panes.editor(@intCast(id)) orelse L.raiseErrorStr("mnml.buf: `pane` must name an editor pane; pane %d is not one", .{@as(c_int, @intCast(id))});
    }
    return app.activeEditor() orelse L.raiseErrorStr("mnml.buf: no active editor pane — pass a pane id, or open a file first", .{});
}

/// Register a dynamic command with a Lua runner and bind its keys.
/// A previous registration under the same id gives up its ref first.
fn registerLuaCommand(self: *Lua, full_id: []const u8, title: []const u8, group: []const u8, keys: []const []const u8, run_ref: LuaRef) !u32 {
    const app = self.app;
    if (app.dyn_commands.get(full_id)) |slot| if (app.dyn_commands.at(slot)) |old| {
        for (old.keys) |k| app.keymap.unbind(k);
        if (old.runner == .lua) self.unref(old.runner.lua);
    };
    const slot = app.dyn_commands.register(.{
        .id = full_id,
        .title = title,
        .group = group,
        .keys = keys,
        .runner = .{ .lua = run_ref },
        .owner = .{ .script = self.id },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => {
            self.unref(run_ref);
            return error.ShadowsBuiltin;
        },
    };
    for (keys) |k| try app.keymap.bind(k, full_id);
    if (keys.len > 0) try app.keymap.rebuildPrefixes();
    return slot;
}

/// Every script command's keys, bound again — the app rebuilt its keymap.
pub fn rebind(app: *App) Allocator.Error!void {
    var any = false;
    for (app.dyn_commands.list.items, app.dyn_commands.live.items) |c, alive| {
        if (!alive or c.owner != .script or c.runner != .lua) continue;
        for (c.keys) |k| {
            try app.keymap.bind(k, c.id);
            any = true;
        }
    }
    if (any) try app.keymap.rebuildPrefixes();
}

// ─── mnml.* ─────────────────────────────────────────────────────────────

/// `mnml.command{ id, title?, group?, keys?, run }` → the full id.
fn cmdRegister(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.command", "{ id, title?, group?, keys?, run }");
    const arena = c.app.frame.allocator();
    const id = needStr(L, 1, "id", "mnml.command", "a bare name — \"hello\" becomes the command user.hello");
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t\n.") != null) L.raiseErrorStr("mnml.command: `id` must be a bare name — letters, digits and `_`, no spaces or dots (\"hello\" becomes user.hello)", .{});
    const full = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ id_prefix, id }, 0);
    const title = try arena.dupe(u8, strField(L, 1, "title") orelse id);
    const group = try arena.dupe(u8, strField(L, 1, "group") orelse "user");
    const keys = try keysField(L, arena, 1);
    const run_ref = needFn(c.self, 1, "run", "mnml.command", "a function() — what the palette row, the chord and `:user.<id>` all run");
    _ = registerLuaCommand(c.self, full, title, group, keys, run_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => L.raiseErrorStr("mnml.command: `%s` shadows a built-in command", .{full.ptr}),
    };
    try c.self.noteOrigin(.command, full);
    _ = L.pushString(full);
    return 1;
}

/// `mnml.map(spec, fn)` → an anonymous command bound to `spec`. The
/// second argument may be a command id instead (`mnml.map("ctrl+shift+s",
/// "file.save")` — what *Bind in init.lua* writes): the chord then runs
/// that command, built-in or script, through `mnml.run`.
fn map(L: *State) !i32 {
    const c = ctx(L);
    const spec = argStr(L, 1, "mnml.map", "the first argument is a chord spec, a string (\"ctrl+shift+n\", \"space u n\")");
    const arena = c.app.frame.allocator();
    var title: []const u8 = spec;
    if (L.typeOf(2) == .string) {
        // A closure over the id: `function() mnml.run(id) end`.
        const id = L.toString(2) catch unreachable;
        if (command.by_name.get(id) == null and c.app.dyn_commands.get(id) == null) L.raiseErrorStr("mnml.map: the second argument names no command — `%s` is not an id mnml.commands() lists", .{id.ptr});
        title = try std.fmt.allocPrint(arena, "{s} → {s}", .{ spec, id });
        L.pushValue(2);
        L.pushClosure(zlua.wrap(runBound), 1);
    } else {
        argFn(L, 2, "mnml.map", "the second argument is a function(), or a command id as a string (\"file.save\")");
        L.pushValue(2);
    }
    c.self.map_seq += 1;
    const full = try std.fmt.allocPrint(arena, "{s}map_{d}", .{ id_prefix, c.self.map_seq });
    const run_ref = c.self.ref();
    const keys = [_][]const u8{spec};
    _ = registerLuaCommand(c.self, full, title, "user", &keys, run_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => unreachable, // `user.map_N` is never a built-in
    };
    try c.self.noteOrigin(.command, full);
    _ = L.pushString(full);
    return 1;
}

/// The runner of a `mnml.map(spec, "<id>")`: the id is its upvalue.
fn runBound(L: *State) !i32 {
    const c = ctx(L);
    const id = L.toString(zlua.Lua.upvalueIndex(1)) catch return 0;
    command.runNamed(c.app, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => L.raiseErrorStr("%s", .{(try c.app.frame.allocator().dupeZ(u8, c.app.diag.msg orelse @errorName(err))).ptr}),
    };
    return 0;
}

/// `mnml.on(hook, fn)`.
fn on(L: *State) !i32 {
    const c = ctx(L);
    const name = argStr(L, 1, "mnml.on", "the first argument is a hook name, a string");
    argFn(L, 2, "mnml.on", "the second argument is a function(args) — args is a flat table of the hook's fields plus hook = \"<name>\"");
    const hook = std.meta.stringToEnum(hooks.Hook, name) orelse L.raiseErrorStr("mnml.on: `%s` is not a hook — the names are %s", .{ (try c.app.frame.allocator().dupeZ(u8, name)).ptr, hook_names.ptr });
    L.pushValue(2);
    const r = c.self.ref();
    c.app.hooks.subscribe(hook, .{ .lua = r }) catch |err| {
        c.self.unref(r);
        return err;
    };
    // One row per hook name: a second subscriber to the same hook is
    // the same row, at the later line.
    try c.self.noteOrigin(.hook, name);
    return 0;
}

/// `mnml.toast(text, level?)` — level `info` (default) | `warn` | `error`.
fn toast(L: *State) !i32 {
    const c = ctx(L);
    const text = argStr(L, 1, "mnml.toast", "the first argument is the text, a string");
    const level: app_mod.ToastLevel = if (optArgStr(L, 2, "mnml.toast", "the second argument is the level, one of \"info\", \"warn\", \"error\"")) |lv|
        (if (std.mem.eql(u8, lv, "info")) .info else if (std.mem.eql(u8, lv, "warn")) .warn else if (std.mem.eql(u8, lv, "error")) .err else L.raiseErrorStr("mnml.toast: the level is \"info\", \"warn\" or \"error\"", .{}))
    else
        .info;
    try c.app.toastLevel(level, "{s}", .{text});
    return 0;
}

/// `mnml.run(id)` → true when the command succeeded. A failure was
/// toasted by `command.run`; the message is the second return.
fn run(L: *State) !i32 {
    const c = ctx(L);
    const id = argStr(L, 1, "mnml.run", "takes a command id, a string (\"file.save\", \"user.hello\" — mnml.commands() lists them)");
    command.runNamed(c.app, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            L.pushBoolean(false);
            _ = L.pushString(c.app.diag.msg orelse @errorName(err));
            return 2;
        },
    };
    L.pushBoolean(true);
    return 1;
}

/// `mnml.ex(line)` — a `:` line without the colon.
fn ex(L: *State) !i32 {
    const c = ctx(L);
    const line = argStr(L, 1, "mnml.ex", "takes a `:` line without the colon, a string (\"w\", \"e src/app.zig\")");
    c.app.runEx(line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            L.pushBoolean(false);
            _ = L.pushString(c.app.diag.msg orelse @errorName(err));
            return 2;
        },
    };
    L.pushBoolean(true);
    return 1;
}

fn workspace(L: *State) !i32 {
    _ = L.pushString(ctx(L).app.workspace);
    return 1;
}

fn dataRoot(L: *State) !i32 {
    _ = L.pushString(ctx(L).app.data_root);
    return 1;
}

fn redraw(L: *State) !i32 {
    ctx(L).app.needs_render = true;
    return 0;
}

// ─── mnml.inspect ───────────────────────────────────────────────────────
// `print` is the log — it toasts, the way it always has. `inspect` is
// the other half: it never prints anything itself, it answers with the
// string, so `print(mnml.inspect(a))` toasts a hook's whole payload and
// `mnml.toast(mnml.inspect(row))` does it from a picker.

/// How deep `mnml.inspect` walks before it writes `{…}` instead.
pub const inspect_depth: usize = 4;
/// The cap on the string it answers with; past it the tail is `…`.
pub const inspect_bytes: usize = 16 * 1024;

/// `mnml.inspect(v)` → the value as a string. Deterministic: the array
/// part in order, then every other key sorted, so two runs of the same
/// table read the same and a test can pin it.
fn inspect(L: *State) !i32 {
    const c = ctx(L);
    if (L.getTop() == 0) L.raiseErrorStr("mnml.inspect(v) takes one value — any type, nil included", .{});
    const arena = c.app.frame.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var seen: [inspect_depth]?*const anyopaque = @splat(null);
    try writeInspect(L, arena, &out, 1, 0, &seen);
    if (out.items.len > inspect_bytes) {
        out.shrinkRetainingCapacity(inspect_bytes);
        try out.appendSlice(arena, "…");
    }
    _ = L.pushString(out.items);
    return 1;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Whether a string key may be written bare (`x = 1`) rather than
/// bracketed (`["a b"] = 1`).
fn bareKey(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn writeQuoted(arena: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    try out.append(arena, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '\r' => try out.appendSlice(arena, "\\r"),
        else => try out.append(arena, ch),
    };
    try out.append(arena, '"');
}

/// The value at `index` written into `out`. `seen` holds the tables on
/// the path down to here, so a table that names itself reads `<cycle>`
/// instead of running until the budget stops it.
fn writeInspect(L: *State, arena: Allocator, out: *std.ArrayListUnmanaged(u8), index: i32, depth: usize, seen: []?*const anyopaque) Allocator.Error!void {
    if (out.items.len > inspect_bytes) return;
    const at = L.absIndex(index);
    switch (L.typeOf(at)) {
        .none, .nil => try out.appendSlice(arena, "nil"),
        .boolean => try out.appendSlice(arena, if (L.toBoolean(at)) "true" else "false"),
        .number => {
            if (L.isInteger(at)) {
                try out.print(arena, "{d}", .{L.toInteger(at) catch 0});
            } else {
                try out.print(arena, "{d}", .{L.toNumber(at) catch 0});
            }
        },
        // `toString` on a string reads it; on a number it would REWRITE
        // the stack slot, which would break the `next` walk above.
        .string => try writeQuoted(arena, out, L.toString(at) catch ""),
        .table => try writeTable(L, arena, out, at, depth, seen),
        .function => try out.appendSlice(arena, "<function>"),
        else => try out.print(arena, "<{s}>", .{L.typeNameIndex(at)}),
    }
}

fn writeTable(L: *State, arena: Allocator, out: *std.ArrayListUnmanaged(u8), at: i32, depth: usize, seen: []?*const anyopaque) Allocator.Error!void {
    const ptr = L.toPointer(at);
    for (seen[0..depth]) |p| if (p != null and p == ptr) return out.appendSlice(arena, "<cycle>");
    if (depth >= inspect_depth) return out.appendSlice(arena, "{…}");
    seen[depth] = ptr;
    defer seen[depth] = null;
    const start = out.items.len;
    try out.appendSlice(arena, "{ ");
    var wrote: usize = 0;
    const n = L.lenRaw(at);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        _ = L.getIndex(at, @intCast(i));
        defer L.pop(1);
        if (wrote > 0) try out.appendSlice(arena, ", ");
        try writeInspect(L, arena, out, -1, depth + 1, seen);
        wrote += 1;
    }
    // Everything the array part did not cover, rendered one at a time
    // and sorted: `next`'s order is the hash's, and a report that
    // reorders itself between runs is not a report.
    var rest: std.ArrayListUnmanaged([]const u8) = .empty;
    L.pushNil();
    while (L.next(at)) {
        const in_array = L.isInteger(-2) and blk: {
            const k = L.toInteger(-2) catch 0;
            break :blk k >= 1 and k <= @as(i64, @intCast(n));
        };
        if (in_array) {
            L.pop(1);
            continue;
        }
        var one: std.ArrayListUnmanaged(u8) = .empty;
        if (L.typeOf(-2) == .string and bareKey(L.toString(-2) catch "")) {
            try one.appendSlice(arena, L.toString(-2) catch "");
        } else {
            try one.append(arena, '[');
            try writeInspect(L, arena, &one, -2, depth + 1, seen);
            try one.append(arena, ']');
        }
        try one.appendSlice(arena, " = ");
        try writeInspect(L, arena, &one, -1, depth + 1, seen);
        try rest.append(arena, one.items);
        L.pop(1);
    }
    std.mem.sort([]const u8, rest.items, {}, lessThanStr);
    for (rest.items) |s| {
        if (wrote > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, s);
        wrote += 1;
    }
    if (wrote == 0) {
        out.shrinkRetainingCapacity(start);
        try out.appendSlice(arena, "{}");
    } else {
        try out.appendSlice(arena, " }");
    }
}

// ─── mnml.buf ───────────────────────────────────────────────────────────

fn bufText(L: *State) !i32 {
    const c = ctx(L);
    const e = editorArg(L, c.app, 1);
    _ = L.pushString(e.buf.editor.bytes());
    return 1;
}

/// `mnml.buf.line(n, pane?)` — 1-based; nil past the end.
fn bufLine(L: *State) !i32 {
    const c = ctx(L);
    const n = argInt(L, 1, "mnml.buf.line", "the first argument is a 1-based line number");
    const e = editorArg(L, c.app, 2);
    if (n < 1 or n > e.buf.editor.lineCount()) {
        L.pushNil();
        return 1;
    }
    _ = L.pushString(e.buf.editor.lineSlice(@intCast(n - 1)));
    return 1;
}

fn bufLineCount(L: *State) !i32 {
    const c = ctx(L);
    const e = editorArg(L, c.app, 1);
    L.pushInteger(@intCast(e.buf.editor.lineCount()));
    return 1;
}

/// `mnml.buf.cursor(pane?)` → line, col (1-based), byte (0-based).
fn bufCursor(L: *State) !i32 {
    const c = ctx(L);
    const e = editorArg(L, c.app, 1);
    const pos = e.buf.editor.rowCol();
    L.pushInteger(@intCast(pos.row + 1));
    L.pushInteger(@intCast(pos.col + 1));
    L.pushInteger(@intCast(e.buf.editor.cursor));
    return 3;
}

/// `mnml.buf.doc.path(pane?)` → the workspace-relative path, nil for scratch.
fn bufPath(L: *State) !i32 {
    const c = ctx(L);
    const e = editorArg(L, c.app, 1);
    if (e.buf.doc.path) |p| _ = L.pushString(c.app.relPath(p)) else L.pushNil();
    return 1;
}

/// The selection's shape, from the handler's editing mode — the one
/// handler-derived fact a script sees, and the same one the statusline
/// reads (`input.EditingMode`).
pub fn selectionMode(e: *const EditorPane) []const u8 {
    return switch (e.buf.input.mode()) {
        .visual_line => "line",
        .visual_block => "block",
        else => "char",
    };
}

/// `mnml.buf.selection(pane?)` → `{ start, ["end"], mode }`, or nil
/// when nothing is selected. Bytes, 0-based, `end` exclusive — the same
/// numbers `decor.highlight` and `replace_range` take.
fn bufSelection(L: *State) !i32 {
    const c = ctx(L);
    const e = editorArg(L, c.app, 1);
    const sel = e.buf.editor.selection() orelse {
        L.pushNil();
        return 1;
    };
    L.createTable(0, 3);
    L.pushInteger(@intCast(sel[0]));
    L.setField(-2, "start");
    L.pushInteger(@intCast(sel[1]));
    L.setField(-2, "end");
    _ = L.pushString(selectionMode(e));
    L.setField(-2, "mode");
    return 1;
}

/// `mnml.buf.range(start, end_, pane?)` → the text between two bytes.
/// A reversed pair reads the same span; both ends are clamped to the
/// buffer, so a range built from a stale position still answers.
fn bufRange(L: *State) !i32 {
    const c = ctx(L);
    const a = byteArg(L, 1, "start");
    const b = byteArg(L, 2, "end");
    const e = editorArg(L, c.app, 3);
    const text = e.buf.editor.bytes();
    const lo = @min(@min(a, b), text.len);
    const hi = @min(@max(a, b), text.len);
    _ = L.pushString(text[lo..hi]);
    return 1;
}

/// `mnml.buf.word_at(byte?, pane?)` → `{ text, start, ["end"] }`, or
/// nil when the byte is not in a word. Without a byte, the cursor's.
fn bufWordAt(L: *State) !i32 {
    const c = ctx(L);
    const at: ?usize = if (L.isNoneOrNil(1)) null else byteArg(L, 1, "byte");
    const e = editorArg(L, c.app, 2);
    const text = e.buf.editor.bytes();
    const b = @min(at orelse e.buf.editor.cursor, text.len);
    const bounds = @import("../editor/select.zig").wordBoundsAt(e.buf.editor, b);
    // Vim's `iw` classes, less the third: a run of whitespace is not a
    // word, so the space between two words is in neither.
    if (bounds[1] <= bounds[0] or std.ascii.isWhitespace(text[bounds[0]])) {
        L.pushNil();
        return 1;
    }
    L.createTable(0, 3);
    _ = L.pushString(text[bounds[0]..bounds[1]]);
    L.setField(-2, "text");
    L.pushInteger(@intCast(bounds[0]));
    L.setField(-2, "start");
    L.pushInteger(@intCast(bounds[1]));
    L.setField(-2, "end");
    return 1;
}

/// `mnml.buf.apply({ op = "…", … }, pane?)` → whether the text changed.
fn bufApply(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.buf.apply", "{ op = \"<tag>\", … } — see the op table in docs/LUA.md");
    const e = editorArg(L, c.app, 2);
    const arena = c.app.frame.allocator();
    const op = try decodeOp(L, arena, 1);
    const changed = try c.app.applyOps(e, &.{op});
    // The change is the last change, as the same op from a key would
    // be: `.` repeats it. (`App.applyOps` leaves dot to its caller —
    // the key path records itself.)
    if (changed) try e.buf.trackAppOps(&.{op}, arena);
    L.pushBoolean(changed);
    return 1;
}

/// Integer payloads are read from `value`, or from the tag's own name
/// for the field (`move_to_line{ line = 3 }`).
const int_alias = std.StaticStringMap([:0]const u8).initComptime(.{
    .{ "move_to_line", "line" },
    .{ "move_to_col", "col" },
    .{ "set_cursor_byte", "byte" },
    .{ "yank_lines_count", "count" },
    .{ "move_visual_down", "width" },
    .{ "move_visual_up", "width" },
    .{ "move_visual_line_start", "width" },
    .{ "move_visual_line_end", "width" },
});

fn firstCodepoint(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (s.len < n) return null;
    return std.unicode.utf8Decode(s[0..n]) catch null;
}

fn charField(L: *State, t: i32, name: [:0]const u8) ?u21 {
    const s = strField(L, t, name) orelse return null;
    return firstCodepoint(s);
}

/// The table at `t` → an `EditOp`. `op` names the tag; the payload
/// fields follow the tag's struct (`replace_range{ start, end, text }`,
/// `join_lines{ keep_space }`), with `text` for the string tags, `ch`
/// for the char tags, and `value` (or the alias above) for the integer
/// tags. `select_range{ start, end }` and `atomic{ ops }` are composed.
fn decodeOp(L: *State, arena: Allocator, t: i32) !EditOp {
    const at = L.absIndex(t);
    const name = strField(L, at, "op") orelse L.raiseErrorStr("mnml.buf.apply: `op` is required and must be an edit-op tag, a string (\"insert_str\", \"replace_range\", \"undo\")", .{});
    if (std.mem.eql(u8, name, "select_range")) {
        const start = intField(L, at, "start") orelse L.raiseErrorStr("mnml.buf.apply: select_range needs `start` and `end`, both byte offsets (0-based, `end` exclusive; `end` is a Lua keyword, so write [\"end\"])", .{});
        const end = intField(L, at, "end") orelse L.raiseErrorStr("mnml.buf.apply: select_range needs `start` and `end`, both byte offsets (0-based, `end` exclusive; `end` is a Lua keyword, so write [\"end\"])", .{});
        const ops = try arena.alloc(EditOp, 3);
        ops[0] = .{ .set_cursor_byte = @intCast(@max(start, 0)) };
        ops[1] = .select_start;
        ops[2] = .{ .set_cursor_byte = @intCast(@max(end, 0)) };
        return .{ .atomic = ops };
    }
    if (std.mem.eql(u8, name, "atomic")) {
        _ = L.getField(at, "ops");
        defer L.pop(1);
        if (!L.isTable(-1)) L.raiseErrorStr("mnml.buf.apply: atomic needs `ops`, a list of op tables — { ops = { { op = \"…\" }, … } }", .{});
        const n = L.lenRaw(-1);
        const ops = try arena.alloc(EditOp, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = L.getIndex(-1, @intCast(i + 1));
            defer L.pop(1);
            if (!L.isTable(-1)) L.raiseErrorStr("mnml.buf.apply: every entry of `ops` must be an op table — { op = \"…\", … }", .{});
            ops[i] = try decodeOp(L, arena, -1);
        }
        return .{ .atomic = ops };
    }
    if (std.mem.eql(u8, name, "repeat")) {
        const count = intField(L, at, "count") orelse 1;
        _ = L.getField(at, "inner");
        defer L.pop(1);
        if (!L.isTable(-1)) L.raiseErrorStr("mnml.buf.apply: repeat needs `inner`, one op table — { op = \"repeat\", count = 3, inner = { op = \"…\" } }", .{});
        const inner = try arena.create(EditOp);
        inner.* = try decodeOp(L, arena, -1);
        return .{ .repeat = .{ .count = @intCast(@max(count, 0)), .inner = inner } };
    }
    inline for (@typeInfo(EditOp).@"union".fields) |f| {
        if (comptime !(std.mem.eql(u8, f.name, "atomic") or std.mem.eql(u8, f.name, "repeat"))) {
            if (std.mem.eql(u8, f.name, name)) {
                return @unionInit(EditOp, f.name, try decodePayload(f.type, f.name, L, arena, at));
            }
        }
    }
    L.raiseErrorStr("mnml.buf.apply: `op` names no edit op — `%s` is not one of the tags in src/editor/edit_op.zig (docs/LUA.md lists them by shape)", .{(try arena.dupeZ(u8, name)).ptr});
}

/// An enum payload's accepted words, `, `-joined — so a wrong `value`
/// on an op reads as a list of the right ones rather than "unknown".
fn enumNames(comptime T: type) [:0]const u8 {
    return comptime blk: {
        var out: [:0]const u8 = "";
        for (std.enums.values(T), 0..) |v, i| out = out ++ (if (i > 0) ", " else "") ++ "\"" ++ @tagName(v) ++ "\"";
        break :blk out;
    };
}

/// What a struct payload's field must be, in words — the tail of the
/// `\`join_lines\` needs \`keep_space\`, a boolean` message.
fn fieldShape(comptime T: type) [:0]const u8 {
    return switch (@typeInfo(T)) {
        .bool => "a boolean",
        .int => if (T == u21) "one character, as a string" else "an integer",
        .pointer => "a string",
        else => "a value",
    };
}

fn decodePayload(comptime T: type, comptime tag: []const u8, L: *State, arena: Allocator, at: i32) !T {
    switch (@typeInfo(T)) {
        .void => return {},
        .int => {
            // The char tags (`insert_char`, `select_inner_quote`, …) read
            // `ch = "x"` first.
            if (T == u21) if (charField(L, at, "ch")) |ch| return ch;
            const alias: ?[:0]const u8 = int_alias.get(tag);
            const v = intField(L, at, "value") orelse (if (alias) |a| intField(L, at, a) else null) orelse
                L.raiseErrorStr("mnml.buf.apply: `%s` needs an integer `value` (or its own name for the field: line / col / byte / count / width)", .{tag.ptr});
            return std.math.cast(T, v) orelse L.raiseErrorStr("mnml.buf.apply: `%s`: value out of range", .{tag.ptr});
        },
        .bool => return boolField(L, at, "value") orelse L.raiseErrorStr("mnml.buf.apply: `%s` needs `value`, a boolean", .{tag.ptr}),
        .optional => |o| {
            if (o.child == u21) return charField(L, at, "ch");
            @compileError("unhandled optional payload for " ++ tag);
        },
        .pointer => |p| {
            if (p.child == u8) return try arena.dupe(u8, strField(L, at, "text") orelse L.raiseErrorStr("mnml.buf.apply: `%s` needs `text`, a string", .{tag.ptr}));
            @compileError("unhandled pointer payload for " ++ tag);
        },
        .@"enum" => {
            const s = strField(L, at, "value") orelse strField(L, at, "case") orelse L.raiseErrorStr("mnml.buf.apply: `%s` needs `value`, one of %s", .{ tag.ptr, enumNames(T).ptr });
            return std.meta.stringToEnum(T, s) orelse L.raiseErrorStr("mnml.buf.apply: `%s`: `value` is one of %s", .{ tag.ptr, enumNames(T).ptr });
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.fields) |sf| {
                const fname: [:0]const u8 = sf.name;
                const Ft = sf.type;
                const got: ?Ft = switch (@typeInfo(Ft)) {
                    .bool => boolField(L, at, fname),
                    .int => if (Ft == u21 and charField(L, at, fname) != null) charField(L, at, fname) else if (intField(L, at, fname)) |v| (std.math.cast(Ft, v) orelse null) else null,
                    .pointer => if (strField(L, at, fname)) |v| try arena.dupe(u8, v) else null,
                    else => @compileError("unhandled struct payload field " ++ tag ++ "." ++ sf.name),
                };
                @field(out, sf.name) = got orelse (if (sf.defaultValue()) |d| d else L.raiseErrorStr("mnml.buf.apply: `%s` needs `%s`, %s", .{ tag.ptr, fname.ptr, fieldShape(Ft).ptr }));
            }
            return out;
        },
        else => {
            // `u21` is an int; the char tags are read as `ch`.
            @compileError("unhandled payload for " ++ tag);
        },
    }
}

// ─── mnml.operator ──────────────────────────────────────────────────────

const script_ops = @import("../input/script_ops.zig");

/// `mnml.operator{ id, keys = { vim = "gs", standard = "ctrl+shift+s" },
/// run = fn(range) }`.
///
/// The two profiles reach it by their own road, and neither knows the
/// operator came from a script. Under vim the `g<letter>` chord goes
/// into `input/script_ops.zig` — the table the vim handler asks once
/// its own `g` switch has fallen through — so `gs{motion}`, `gsiw` and
/// `V…gs` all build the range the way `gU{motion}` does and hand it
/// over. Under standard the chord is an ordinary `user.<id>` command
/// (so it is in the palette and `mnml.run` too) whose runner takes the
/// selection, or the word under the cursor when there is none.
fn operatorRegister(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.operator", "{ id, title?, keys = { vim?, standard? }, run }");
    const id = needStr(L, 1, "id", "mnml.operator", "a bare name — \"surround\" becomes the command user.surround");
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t\n.") != null) L.raiseErrorStr("mnml.operator: `id` must be a bare name — letters, digits and `_`, no spaces or dots", .{});
    // Everything is checked before anything is allocated or ref'd: a
    // Lua error is a longjmp, and an `errdefer` below one never runs.
    if (L.getField(1, "keys") != .table) {
        L.pop(1);
        L.raiseErrorStr("mnml.operator: `keys` must be a table — { vim = \"g<letter>\", standard = \"a chord spec\" }, at least one of the two", .{});
    }
    const keys_at = L.getTop();
    const vim_spec = strField(L, keys_at, "vim");
    const std_spec = strField(L, keys_at, "standard");
    if (vim_spec == null and std_spec == null) {
        L.pop(1);
        L.raiseErrorStr("mnml.operator: `keys` needs a `vim` chord (\"g\" and one letter) or a `standard` one (any chord spec), or both", .{});
    }
    if (vim_spec) |v| if (!script_ops.validVimSpec(v)) {
        const owned = c.app.frame.allocator().dupeZ(u8, v) catch "?";
        L.pop(1);
        L.raiseErrorStr("mnml.operator: `keys.vim` must be `g` and one letter vim does not already use — `%s` is not; vim's own are g%s", .{ owned.ptr, script_ops.reserved.ptr });
    };
    const arena = c.app.frame.allocator();
    const full = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ id_prefix, id }, 0);
    const title = try arena.dupe(u8, strField(L, 1, "title") orelse id);
    const vim_owned: ?[]const u8 = if (vim_spec) |v| try arena.dupe(u8, v) else null;
    const std_owned: ?[]const u8 = if (std_spec) |v| try arena.dupe(u8, v) else null;
    L.pop(1); // the keys table
    const run_ref = needFn(c.self, 1, "run", "mnml.operator", "a function(range) — range is { start, [\"end\"], mode }, the shape mnml.buf.selection() answers with");
    // The slot the vim handler and the standard command both name.
    const index: u32 = blk: {
        for (c.self.operators.items, 0..) |*o, i| if (std.mem.eql(u8, o.id, full)) {
            c.self.unref(o.run);
            o.run = run_ref;
            break :blk @intCast(i);
        };
        const owned_id = c.self.gpa.dupe(u8, full) catch |err| {
            c.self.unref(run_ref);
            return err;
        };
        errdefer c.self.gpa.free(owned_id);
        try c.self.operators.append(c.self.gpa, .{ .id = owned_id, .run = run_ref });
        break :blk @intCast(c.self.operators.items.len - 1);
    };
    if (vim_owned) |v| try script_ops.register(c.self.gpa, v, c.self.id, index);
    // The standard road: a command with the chord, its runner a closure
    // over the index — `mnml.map(spec, "<id>")`'s trick.
    L.pushInteger(index);
    L.pushClosure(zlua.wrap(runOperatorCommand), 1);
    const cmd_ref = c.self.ref();
    const keys: []const []const u8 = if (std_owned) |k| try arena.dupe([]const u8, &.{k}) else &.{};
    _ = registerLuaCommand(c.self, full, title, "user", keys, cmd_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => L.raiseErrorStr("mnml.operator: `%s` shadows a built-in command", .{full.ptr}),
    };
    try c.self.noteOrigin(.operator, full);
    _ = L.pushString(full);
    return 1;
}

/// The runner behind an operator's standard chord (and its palette
/// row): the selection, or the word under the cursor when there is
/// none — and nothing at all when the cursor is not in a word.
fn runOperatorCommand(L: *State) !i32 {
    const c = ctx(L);
    const index: u32 = @intCast(L.toInteger(zlua.Lua.upvalueIndex(1)) catch 0);
    const e = c.app.activeEditor() orelse return 0;
    const sel = e.buf.editor.selection() orelse blk: {
        const text = e.buf.editor.bytes();
        const w = @import("../editor/select.zig").wordBoundsAt(e.buf.editor, @min(e.buf.editor.cursor, text.len));
        if (w[1] <= w[0] or std.ascii.isWhitespace(text[w[0]])) return 0;
        break :blk [2]usize{ w[0], w[1] };
    };
    try runOperator(c.app, c.self, index, e, sel[0], sel[1]);
    return 0;
}

/// Run the operator at `index` over `[start, end)` as ONE undo step:
/// whatever the script applies inside, one `undo` puts the text back the
/// way it was before the chord.
pub fn runOperator(app: *App, self: *Lua, index: u32, e: *EditorPane, start: usize, end: usize) Allocator.Error!void {
    return runOperatorMode(app, self, index, e, start, end, selectionMode(e));
}

/// As `runOperator`, with the range's shape given rather than read off
/// the handler — the vim road has already left Visual by then.
pub fn runOperatorMode(app: *App, self: *Lua, index: u32, e: *EditorPane, start: usize, end: usize, mode: []const u8) Allocator.Error!void {
    const pane_id = app.paneIdOf(e);
    const before = e.buf.editor.doc.history.undoLen();
    self.callOperator(index, start, end, mode);
    // The pane may be gone (a script may close panes): look it up again.
    const live = if (pane_id) |id| app.panes.editor(id) else null;
    if (live) |ep| {
        const after = ep.buf.editor.doc.history.undoLen();
        if (after > before + 1) ep.buf.editor.doc.history.truncateUndo(before + 1);
    }
}

// ─── mnml.statusline ────────────────────────────────────────────────────

/// `mnml.statusline.segment{ id, side?, fn }` — `fn()` returns the text
/// (nil hides it), polled every 250 ms.
fn statuslineSegment(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.statusline.segment", "{ id, side?, fn }");
    const id = needStr(L, 1, "id", "mnml.statusline.segment", "a name of your own — registering it again replaces the segment");
    const side: lua_mod.Side = if (strField(L, 1, "side")) |s| (std.meta.stringToEnum(lua_mod.Side, s) orelse L.raiseErrorStr("mnml.statusline.segment: `side` is \"left\" or \"right\"", .{})) else .right;
    const func = needFn(c.self, 1, "fn", "mnml.statusline.segment", "a function() returning the text — nil hides the segment; it is polled every 250 ms");
    const gpa = c.self.gpa;
    try c.self.noteOrigin(.segment, id);
    for (c.self.segments.items) |*seg| if (std.mem.eql(u8, seg.id, id)) {
        c.self.unref(seg.func);
        seg.func = func;
        seg.side = side;
        seg.next_poll_ms = 0;
        return 0;
    };
    const owned_id = gpa.dupe(u8, id) catch |err| {
        c.self.unref(func);
        return err;
    };
    errdefer gpa.free(owned_id);
    c.self.segments.append(gpa, .{ .id = owned_id, .side = side, .func = func }) catch |err| {
        c.self.unref(func);
        return err;
    };
    return 0;
}

// ─── mnml.picker ────────────────────────────────────────────────────────

/// `mnml.picker.source{ id, title?, items = fn(query), live?, multi?,
/// preview?, on_accept? }`.
fn pickerSource(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.picker.source", "{ id, title?, items, live?, multi?, preview?, on_accept? }");
    const id = needStr(L, 1, "id", "mnml.picker.source", "a name of your own — mnml.picker.open takes it back");
    const title = strField(L, 1, "title") orelse id;
    const live = boolField(L, 1, "live") orelse false;
    const multi = boolField(L, 1, "multi") orelse false;
    // Every check before the first ref: a Lua error is a longjmp.
    checkOptFn(L, 1, "preview", "mnml.picker.source", "a function(row) returning rows of segments for the preview column");
    checkOptFn(L, 1, "on_accept", "mnml.picker.source", "a function(row) — or function(rows), the marked ones, when multi = true");
    const items = needFn(c.self, 1, "items", "mnml.picker.source", "a function(query) returning a table of rows — a row is a string, or { label, detail?, icon?, data?, on_accept? }");
    const preview = fnField(c.self, 1, "preview");
    const on_accept = fnField(c.self, 1, "on_accept");
    const gpa = c.self.gpa;
    try c.self.noteOrigin(.source, id);
    if (c.self.findSource(id)) |src| {
        c.self.unref(src.items);
        if (src.preview) |r| c.self.unref(r);
        if (src.on_accept) |r| c.self.unref(r);
        src.items = items;
        src.preview = preview;
        src.on_accept = on_accept;
        src.live = live;
        src.multi = multi;
        const owned = gpa.dupe(u8, title) catch |err| return err;
        gpa.free(src.title);
        src.title = owned;
        return 0;
    }
    const owned_id = gpa.dupe(u8, id) catch |err| {
        c.self.unref(items);
        return err;
    };
    errdefer gpa.free(owned_id);
    const owned_title = try gpa.dupe(u8, title);
    errdefer gpa.free(owned_title);
    c.self.sources.append(gpa, .{
        .id = owned_id,
        .title = owned_title,
        .items = items,
        .live = live,
        .multi = multi,
        .preview = preview,
        .on_accept = on_accept,
    }) catch |err| {
        c.self.unref(items);
        return err;
    };
    return 0;
}

/// `mnml.picker.open(id, query?)` — the picker over `items(query)`.
fn pickerOpen(L: *State) !i32 {
    const c = ctx(L);
    const id = argStr(L, 1, "mnml.picker.open", "the first argument is a source id, a string — the `id` mnml.picker.source{} was given");
    const query = optArgStr(L, 2, "mnml.picker.open", "the second argument is the starting query, a string") orelse "";
    const src = c.self.findSource(id) orelse L.raiseErrorStr("mnml.picker.open: no source `%s` — mnml.picker.source{ id = … } registers one, and a reload drops them", .{id.ptr});
    openSource(c.app, c.self, src, query) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => L.raiseErrorStr("mnml.picker.open: %s", .{@errorName(err).ptr}),
    };
    return 0;
}

/// Open the one picker overlay over `src`'s rows for `query`. Shared by
/// `picker.open` and the live re-run.
pub fn openSource(app: *App, self: *Lua, src: *lua_mod.PickerSource, query: []const u8) command.CommandError!void {
    const gpa = self.gpa;
    var labels: std.ArrayList([]u8) = .empty;
    var details: std.ArrayList([]u8) = .empty;
    var icons: std.ArrayList([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
        for (icons.items) |g| gpa.free(g);
        icons.deinit(gpa);
    }
    try self.callItems(src.items, query, &labels, &details, &icons);
    // The overlay owns the slices from the call on, whatever it returned;
    // the errdefers only cover the allocations before this point.
    var handed = false;
    const owned_labels = try labels.toOwnedSlice(gpa);
    errdefer if (!handed) {
        for (owned_labels) |l| gpa.free(l);
        gpa.free(owned_labels);
    };
    const owned_details = try details.toOwnedSlice(gpa);
    errdefer if (!handed) {
        for (owned_details) |d| gpa.free(d);
        gpa.free(owned_details);
    };
    const owned_icons = try icons.toOwnedSlice(gpa);
    errdefer if (!handed) {
        for (owned_icons) |g| gpa.free(g);
        gpa.free(owned_icons);
    };
    const panes = try gpa.alloc(PaneId, 0);
    errdefer if (!handed) gpa.free(panes);
    const hints = try gpa.alloc([]u8, 0);
    errdefer if (!handed) gpa.free(hints);
    const marked = try gpa.alloc(bool, if (src.multi) owned_labels.len else 0);
    @memset(marked, false);
    errdefer if (!handed) gpa.free(marked);
    const source_id = try gpa.dupe(u8, src.id);
    errdefer if (!handed) gpa.free(source_id);
    handed = true;
    try cmd_picker.openPickerWith(app, src.title, .lua, owned_labels, panes, owned_details, hints);
    const p = &app.overlay.picker;
    p.icons = owned_icons;
    p.marked = marked;
    p.lua_source = source_id;
    p.lua_state = self.id;
    p.state.multi = src.multi;
    p.state.has_preview = src.preview != null;
    // A re-run keeps what the reader typed: the query is the overlay's.
    if (query.len > 0) {
        try p.state.query.appendSlice(gpa, query);
        p.state.caret = p.state.query.items.len;
        try @import("../app/dispatch.zig").refilterPicker(app);
    }
    try refreshPreview(app);
}

/// The cursor moved (or the rows changed): ask the source for the
/// preview column again. Lua is never entered from the paint loop, so
/// the rows are decoded here and held until the next move.
pub fn refreshPreview(app: *App) Allocator.Error!void {
    if (app.overlay != .picker or app.overlay.picker.kind != .lua) return;
    const p = &app.overlay.picker;
    if (!p.state.has_preview) return;
    const self = app.luaState(p.lua_state) orelse return;
    const src = self.findSource(p.lua_source) orelse return;
    const fnref = src.preview orelse return;
    app_mod.Overlay.freePreview(app.gpa, p.preview);
    p.preview = &.{};
    if (p.state.cursor >= p.filtered.items.len) return;
    const row = p.filtered.items[p.state.cursor];
    p.preview = try self.callPreview(fnref, row, p.labels[row]);
    app.needs_render = true;
}

/// A live source's debounced re-run: the query changed `live_debounce_ms`
/// ago and nothing has been typed since, so ask for rows again. The old
/// rows stayed on screen the whole time.
pub fn tickLivePicker(app: *App, now: i64) Allocator.Error!void {
    if (app.overlay != .picker or app.overlay.picker.kind != .lua) return;
    const due = app.overlay.picker.requery_at_ms orelse return;
    if (now < due) return;
    app.overlay.picker.requery_at_ms = null;
    const self = app.luaState(app.overlay.picker.lua_state) orelse return;
    const src = self.findSource(app.overlay.picker.lua_source) orelse return;
    if (!src.live) return;
    const query = try app.gpa.dupe(u8, app.overlay.picker.state.queryText());
    defer app.gpa.free(query);
    const cursor = app.overlay.picker.state.cursor;
    openSource(app, self, src, query) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (app.overlay == .picker) {
        const p = &app.overlay.picker;
        p.state.cursor = @min(cursor, p.filtered.items.len -| 1);
        try refreshPreview(app);
    }
    app.needs_render = true;
}

/// The query changed on a live source: arm the debounce.
pub fn noteQueryChanged(app: *App, now: i64) void {
    if (app.overlay != .picker or app.overlay.picker.kind != .lua) return;
    const lua = app.luaState(app.overlay.picker.lua_state) orelse return;
    const src = lua.findSource(app.overlay.picker.lua_source) orelse return;
    if (!src.live) return;
    app.overlay.picker.requery_at_ms = now + lua_mod.live_debounce_ms;
}

pub fn nextPickerDeadlineMs(app: *const App) ?i64 {
    if (app.overlay != .picker) return null;
    return app.overlay.picker.requery_at_ms;
}

// ─── mnml.pane ──────────────────────────────────────────────────────────

/// `mnml.pane.open{ title, render, on_hit?, on_key? }` → the pane id.
fn paneOpen(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.pane.open", "{ title, render, on_hit?, on_key? } — or { title, list = a mnml.list{} handle }");
    const title = strField(L, 1, "title") orelse "script";
    // `{ list = l }`: the pane hosts a `mnml.list{}` through `ListPanel`
    // instead of calling a `render`.
    if (listField(L, c.app, 1)) |list_id| {
        const id = try script_pane.open(c.app, c.self, title, null, null, null, list_id);
        L.pushInteger(id);
        return 1;
    }
    checkOptFn(L, 1, "on_hit", "mnml.pane.open", "a function(hit_id, \"left\" | \"right\" | \"middle\") — a segment with hit = n is the target");
    checkOptFn(L, 1, "on_key", "mnml.pane.open", "a function(chord) returning true when it consumed the key");
    const render = needFn(c.self, 1, "render", "mnml.pane.open", "a function(w, h) returning up to h rows — a row is a string or a list of segments; pass `list` instead to host a mnml.list{}");
    errdefer c.self.unref(render);
    const on_hit = fnField(c.self, 1, "on_hit");
    errdefer if (on_hit) |r| c.self.unref(r);
    const on_key = fnField(c.self, 1, "on_key");
    errdefer if (on_key) |r| c.self.unref(r);
    const id = try script_pane.open(c.app, c.self, title, render, on_hit, on_key, 0);
    L.pushInteger(id);
    return 1;
}

fn paneClose(L: *State) !i32 {
    const c = ctx(L);
    const id = argInt(L, 1, "mnml.pane.close", "takes a pane id, an integer (what mnml.pane.open{} answered with)");
    if (id < 0 or id > std.math.maxInt(PaneId)) L.raiseErrorStr("mnml.pane.close: takes a pane id (what mnml.pane.open{} answered with); %d is not one", .{@as(c_int, @intCast(@min(id, std.math.maxInt(c_int))))});
    try c.app.forceClosePane(@intCast(id));
    return 0;
}

fn paneActive(L: *State) !i32 {
    const c = ctx(L);
    if (c.app.active) |id| L.pushInteger(id) else L.pushNil();
    return 1;
}

/// `mnml.commands(query?)` — every command the app knows, built-in and
/// script, as `{ id, title, group, keys }`. `query` narrows it by a
/// case-insensitive substring on the id or the title. The cap is there
/// only to bound a runaway — every command the app has fits under it,
/// so an empty query answers with all of them and a script never has to
/// work around a truncated list.
pub const commands_cap: usize = 4000;

fn commandsList(L: *State) !i32 {
    const c = ctx(L);
    const q = optArgStr(L, 1, "mnml.commands", "takes a query, a string — a substring of an id or a title; without one, every command") orelse "";
    var qbuf: [128]u8 = undefined;
    const needle = std.ascii.lowerString(qbuf[0..@min(q.len, qbuf.len)], q[0..@min(q.len, qbuf.len)]);
    L.createTable(0, 0);
    var n: usize = 0;
    var i: usize = 0;
    while (i < command.count and n < commands_cap) : (i += 1) {
        const id: command.CommandId = @enumFromInt(i);
        if (!matches(needle, command.name(id), command.title(id))) continue;
        n += 1;
        pushCommandRow(L, c.app, command.name(id), command.title(id), command.group(id), command.spec(id).keys, &.{});
        L.setIndex(-2, @intCast(n));
    }
    for (c.app.dyn_commands.list.items, c.app.dyn_commands.live.items) |dc, alive| {
        if (!alive or n >= commands_cap) continue;
        if (!matches(needle, dc.id, dc.title)) continue;
        n += 1;
        pushCommandRow(L, c.app, dc.id, dc.title, dc.group, .{}, dc.keys);
        L.setIndex(-2, @intCast(n));
    }
    return 1;
}

fn matches(needle: []const u8, id: []const u8, title: []const u8) bool {
    if (needle.len == 0) return true;
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ id, title }) |hay| {
        const low = std.ascii.lowerString(buf[0..@min(hay.len, buf.len)], hay[0..@min(hay.len, buf.len)]);
        if (std.mem.indexOf(u8, low, needle) != null) return true;
    }
    return false;
}

fn pushCommandRow(L: *State, app: *App, id: []const u8, title: []const u8, group: []const u8, keys: command.Keys, dyn_keys: []const []const u8) void {
    L.createTable(0, 5);
    setStrField(L, "id", id);
    setStrField(L, "title", title);
    setStrField(L, "group", group);
    // The MRU the palette and `picker.recent_commands` already keep —
    // every run, from the palette, a chord, a menu or a `:` line, its
    // own. 1 is the one run most recently; a command never run has no
    // `rank` at all, so `if row.rank then` reads as the question it is.
    if (app.recentCommandRank(id)) |r| {
        L.pushInteger(@intCast(r + 1));
        L.setField(-2, "rank");
    }
    L.createTable(0, 0);
    var k: usize = 0;
    const own = switch (App.profileOf(app.input_style)) {
        .vim => keys.vim,
        .standard => keys.standard,
    };
    for ([_][]const []const u8{ keys.both, own, dyn_keys }) |list| for (list) |spec| {
        var buf: [64]u8 = undefined;
        k += 1;
        _ = L.pushString(@import("../core/keymap.zig").normalizeSpec(spec, &buf) orelse spec);
        L.setIndex(-2, @intCast(k));
    };
    L.setField(-2, "keys");
}

// ─── mnml.list, mnml.section ────────────────────────────────────────────

const script_list = @import("../app/script_list.zig");
const script_section = @import("../app/script_section.zig");

/// The `list` field of a table: the handle `mnml.list{}` answered with,
/// as a table with an `id`, or the bare id. Null when the field is
/// absent; an error when it is there but names no live list.
fn listField(L: *State, app: *App, t: i32) ?u32 {
    const at = L.absIndex(t);
    defer L.pop(1);
    switch (L.getField(at, "list")) {
        .nil, .none => return null,
        .number => {},
        .table => {
            _ = L.getField(-1, "id");
            defer L.pop(1);
            const n = L.toInteger(-1) catch L.raiseErrorStr("mnml: `list` must be what mnml.list{} answered with — the handle table, or its `id`", .{});
            const id: u32 = if (n > 0) @intCast(n) else 0;
            if (script_list.find(app, id) == null) L.raiseErrorStr("mnml: `list` names no live list — make it with mnml.list{} in this run (a reload drops them)", .{});
            return id;
        },
        else => L.raiseErrorStr("mnml: `list` must be what mnml.list{} answered with — the handle table, or its `id`", .{}),
    }
    const n = L.toInteger(-1) catch 0;
    const id: u32 = if (n > 0) @intCast(n) else 0;
    if (script_list.find(app, id) == null) L.raiseErrorStr("mnml: `list` names no live list — make it with mnml.list{} in this run (a reload drops them)", .{});
    return id;
}

/// `mnml.list{ title, rows = fn(sort), on_enter?, on_menu?, sort? }` →
/// a table `{ id = n, refresh = fn }`. Everything around the rows — the
/// header, the filter, the sort chip, the folds, the row menu — is
/// `ListPanel`'s, the one TODOS uses.
fn listRegister(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.list", "{ title, rows, on_enter?, on_menu?, sort? }");
    const title = needStr(L, 1, "title", "mnml.list", "the caps header's words, a string (\"TODOS\")");
    // Every check before the first allocation: a Lua error is a
    // longjmp, and the `sorts` below would never be freed.
    checkOptFn(L, 1, "on_enter", "mnml.list", "a function(row) — Enter, and a second click, on an item");
    checkOptFn(L, 1, "on_menu", "mnml.list", "a function(row) returning { { label, run = fn }, … } — the row's ⋮ menu");
    checkFn(L, 1, "rows", "mnml.list", "a function(sort) returning a table of rows — a row is a string, { header, count } or { label, detail?, icon?, state? }");
    if (L.getField(1, "sort") != .nil and !L.isTable(-1)) {
        L.pop(1);
        L.raiseErrorStr("mnml.list: `sort` must be a table of mode names — { \"State\", \"Name\" }; the chip cycles them and `rows(sort)` is handed the current one", .{});
    }
    var sort_n: usize = 0;
    if (L.isTable(-1)) sort_n = L.lenRaw(-1);
    const gpa = c.self.gpa;
    const sorts = try gpa.alloc([]u8, sort_n);
    var made: usize = 0;
    errdefer {
        for (sorts[0..made]) |x| gpa.free(x);
        gpa.free(sorts);
    }
    var i: usize = 1;
    while (i <= sort_n) : (i += 1) {
        _ = L.getIndex(-1, @intCast(i));
        defer L.pop(1);
        sorts[i - 1] = try gpa.dupe(u8, L.toString(-1) catch "");
        made = i;
    }
    L.pop(1); // the sort table (or the nil)
    const rows_fn = needFn(c.self, 1, "rows", "mnml.list", "a function(sort) returning a table of rows");
    const on_enter = fnField(c.self, 1, "on_enter");
    const on_menu = fnField(c.self, 1, "on_menu");
    const owned_title = gpa.dupe(u8, title) catch |err| {
        c.self.unref(rows_fn);
        return err;
    };
    errdefer gpa.free(owned_title);
    const id = try script_list.add(c.app, owned_title, rows_fn, on_enter, on_menu, sorts);
    try c.self.noteOrigin(.list, title);
    const l = script_list.find(c.app, id).?;
    try script_list.refresh(c.app, l);
    // The handle: `{ id = n, refresh = fn }`, so `l:refresh()` reads.
    L.createTable(0, 2);
    L.pushInteger(id);
    L.setField(-2, "id");
    L.pushInteger(id);
    L.pushClosure(zlua.wrap(listRefresh), 1);
    L.setField(-2, "refresh");
    return 1;
}

/// `l:refresh()` — the id is the closure's upvalue, so the `self` a
/// colon call passes is ignored.
fn listRefresh(L: *State) !i32 {
    const c = ctx(L);
    const n = L.toInteger(zlua.Lua.upvalueIndex(1)) catch return 0;
    const l = script_list.find(c.app, if (n > 0) @intCast(n) else 0) orelse return 0;
    try script_list.refresh(c.app, l);
    return 0;
}

/// `mnml.section{ id, title, glyph?, ascii?, list, side?, after? }` — a
/// rail row and a column of the script's own.
fn sectionRegister(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.section", "{ id, title?, glyph?, ascii?, list, side?, after? }");
    const id = needStr(L, 1, "id", "mnml.section", "a bare name — it also becomes the command user.<id> that shows the section");
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t\n") != null) L.raiseErrorStr("mnml.section: `id` must be a bare name — letters, digits and `_`, no spaces", .{});
    const title = strField(L, 1, "title") orelse id;
    const glyph = strField(L, 1, "glyph") orelse "";
    const ascii = strField(L, 1, "ascii") orelse "";
    const after = strField(L, 1, "after") orelse "";
    var at_side: Config.Side = .left;
    if (strField(L, 1, "side")) |sd| at_side = std.meta.stringToEnum(Config.Side, sd) orelse L.raiseErrorStr("mnml.section: `side` is \"left\" or \"right\"", .{});
    const list_id = listField(L, c.app, 1) orelse L.raiseErrorStr("mnml.section: `list` is required and must be what mnml.list{} answered with", .{});
    const gpa = c.self.gpa;
    const owned_id = try gpa.dupe(u8, id);
    errdefer gpa.free(owned_id);
    const owned_title = try gpa.dupe(u8, title);
    errdefer gpa.free(owned_title);
    const owned_glyph = try gpa.dupe(u8, if (glyph.len > 0) glyph else "\u{f0331}");
    errdefer gpa.free(owned_glyph);
    const owned_ascii = try gpa.dupe(u8, if (ascii.len > 0) ascii else "P");
    errdefer gpa.free(owned_ascii);
    const owned_after = try gpa.dupe(u8, after);
    errdefer gpa.free(owned_after);
    const idx = try script_section.add(c.app, owned_id, owned_title, owned_glyph, owned_ascii, owned_after, list_id, at_side);
    // Every built-in section has a `view.activity_*` command; a script's
    // gets one too, so the palette, `.keys` and a `.test` can reach it.
    const arena = c.app.frame.allocator();
    const full = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ id_prefix, id }, 0);
    const cmd_title = try std.fmt.allocPrint(arena, "Show {s}", .{title});
    L.pushInteger(idx);
    L.pushClosure(zlua.wrap(showSectionCommand), 1);
    const cmd_ref = c.self.ref();
    _ = registerLuaCommand(c.self, full, cmd_title, "view", &.{}, cmd_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => L.raiseErrorStr("mnml.section: `%s` shadows a built-in command", .{full.ptr}),
    };
    try c.self.noteOrigin(.list, title);
    L.pushInteger(idx);
    return 1;
}

/// The runner behind a section's `user.<id>` command: its own rail row,
/// clicked from the keyboard.
fn showSectionCommand(L: *State) !i32 {
    const c = ctx(L);
    const idx = L.toInteger(zlua.Lua.upvalueIndex(1)) catch return 0;
    script_section.show(c.app, if (idx >= 0) @intCast(idx) else 0, true);
    return 0;
}

// ─── mnml.task ──────────────────────────────────────────────────────────

/// `mnml.task.run{ cmd, cwd?, label?, hidden?, on_line?, on_done? }` →
/// the pane id, or the run's id when it is hidden. The command runs in
/// a task pane below — or with no pane at all under `hidden = true`,
/// its output going only to `on_line(text)`, a line at a time
/// (`app/script_task.zig`). `on_done{ ok, code | signal }` fires when
/// it exits either way.
fn taskRun(L: *State) !i32 {
    const c = ctx(L);
    needTable(L, 1, "mnml.task.run", "{ cmd, cwd?, label?, hidden?, on_line?, on_done? }");
    const app = c.app;
    const arena = app.frame.allocator();
    checkOptFn(L, 1, "on_done", "mnml.task.run", "a function(result) — result is { ok, code } or { ok = false, signal }");
    checkOptFn(L, 1, "on_line", "mnml.task.run", "a function(text), one output line at a time — it needs hidden = true");
    const cmd = try arena.dupe(u8, needStr(L, 1, "cmd", "mnml.task.run", "the shell line to run, a string (\"zig build\")"));
    const label = try arena.dupe(u8, strField(L, 1, "label") orelse cmd);
    const cwd: []const u8 = if (strField(L, 1, "cwd")) |d| (if (std.fs.path.isAbsolute(d)) try arena.dupe(u8, d) else try std.fs.path.join(arena, &.{ app.workspace, d })) else app.workspace;
    if (boolField(L, 1, "hidden") orelse false) return hiddenTaskRun(L, c.self, cmd, cwd);
    if (fnField(c.self, 1, "on_line")) |r| {
        c.self.unref(r);
        L.raiseErrorStr("mnml.task.run: `on_line` needs `hidden = true` — a visible task's output is its pane", .{});
    }
    const on_done = fnField(c.self, 1, "on_done");
    errdefer if (on_done) |r| c.self.unref(r);
    const id = runners.spawn(app, label, cmd, cwd, .task) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => L.raiseErrorStr("mnml.task.run: %s", .{(try arena.dupeZ(u8, app.diag.msg orelse @errorName(err))).ptr}),
    };
    if (on_done) |r| try c.self.tasks.append(c.self.gpa, .{ .pane = id, .on_done = r });
    L.pushInteger(id);
    return 1;
}

/// The `hidden = true` prong: no pane, `on_line` per output line.
fn hiddenTaskRun(L: *State, self: *Lua, cmd: []const u8, cwd: []const u8) !i32 {
    const on_line = fnField(self, 1, "on_line");
    errdefer if (on_line) |r| self.unref(r);
    const on_done = fnField(self, 1, "on_done");
    errdefer if (on_done) |r| self.unref(r);
    const id = script_task.spawn(self.app, cmd, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => L.raiseErrorStr("mnml.task.run: %s", .{@errorName(err).ptr}),
    };
    try self.hidden_tasks.append(self.gpa, .{ .id = id, .on_line = on_line, .on_done = on_done });
    L.pushInteger(id);
    return 1;
}

// ─── mnml.config ────────────────────────────────────────────────────────

/// `mnml.config.get(path?)` — a read-only copy of the merged config
/// under the dotted `path` (`"editor.tab_width"`, `"lsp.rust.cmd"`,
/// `"keys.global"`); nil when nothing is there. Without a path, the
/// whole config as nested tables.
fn configGet(L: *State) !i32 {
    const c = ctx(L);
    const path = optArgStr(L, 1, "mnml.config.get", "takes a dotted path, a string (\"editor.tab_width\", \"lsp.rust.cmd\"); without one, the whole config") orelse "";
    pushPath(L, Config, c.app.cfg, path);
    return 1;
}

fn isConfigMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_config_map");
}

fn pushPath(L: *State, comptime T: type, value: T, path: []const u8) void {
    @setEvalBranchQuota(100_000);
    if (path.len == 0) return pushValue(L, T, value);
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = if (dot) |d| path[0..d] else path;
    const rest = if (dot) |d| path[d + 1 ..] else "";
    if (T == Dynamic) return pushDynamicPath(L, value, path);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime isConfigMap(T)) {
                if (value.get(head)) |v| return pushPath(L, T.Value, v, rest);
                return L.pushNil();
            }
            inline for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, head)) return pushPath(L, f.type, @field(value, f.name), rest);
            }
            L.pushNil();
        },
        .optional => |o| if (value) |v| pushPath(L, o.child, v, path) else L.pushNil(),
        .pointer => |p| {
            if (p.size == .slice and p.child != u8) {
                const idx = std.fmt.parseInt(usize, head, 10) catch return L.pushNil();
                if (idx == 0 or idx > value.len) return L.pushNil();
                return pushPath(L, p.child, value[idx - 1], rest);
            }
            L.pushNil();
        },
        else => L.pushNil(),
    }
}

fn pushValue(L: *State, comptime T: type, value: T) void {
    @setEvalBranchQuota(100_000);
    if (T == Dynamic) return pushDynamic(L, value);
    switch (@typeInfo(T)) {
        .bool => L.pushBoolean(value),
        .int => L.pushInteger(@intCast(value)),
        .float => L.pushNumber(@floatCast(value)),
        .@"enum" => _ = L.pushString(@tagName(value)),
        .optional => |o| if (value) |v| pushValue(L, o.child, v) else L.pushNil(),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                _ = L.pushString(value);
            } else if (p.size == .slice) {
                L.newTable();
                for (value, 1..) |v, i| {
                    pushValue(L, p.child, v);
                    L.setIndex(-2, @intCast(i));
                }
            } else L.pushNil();
        },
        .@"struct" => |s| {
            L.newTable();
            if (comptime isConfigMap(T)) {
                for (value.keys(), value.values()) |k, v| {
                    _ = L.pushString(k);
                    pushValue(L, T.Value, v);
                    L.setTable(-3);
                }
                return;
            }
            inline for (s.fields) |f| {
                pushValue(L, f.type, @field(value, f.name));
                L.setField(-2, f.name);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) return L.pushNil();
            switch (value) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) {
                        _ = L.pushString(@tagName(tag));
                    } else {
                        L.newTable();
                        pushValue(L, @TypeOf(payload), payload);
                        L.setField(-2, @tagName(tag));
                    }
                },
            }
        },
        else => L.pushNil(),
    }
}

fn pushDynamic(L: *State, d: Dynamic) void {
    switch (d) {
        .null => L.pushNil(),
        .bool => |b| L.pushBoolean(b),
        .int => |i| L.pushInteger(i),
        .float => |f| L.pushNumber(f),
        .string, .enum_literal => |s| _ = L.pushString(s),
        .array => |items| {
            L.newTable();
            for (items, 1..) |item, i| {
                pushDynamic(L, item);
                L.setIndex(-2, @intCast(i));
            }
        },
        .object => |fields| {
            L.newTable();
            for (fields) |f| {
                _ = L.pushString(f.name);
                pushDynamic(L, f.value);
                L.setTable(-3);
            }
        },
    }
}

fn pushDynamicPath(L: *State, d: Dynamic, path: []const u8) void {
    if (path.len == 0) return pushDynamic(L, d);
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = if (dot) |x| path[0..x] else path;
    const rest = if (dot) |x| path[x + 1 ..] else "";
    switch (d) {
        .object => if (d.get(head)) |v| pushDynamicPath(L, v, rest) else L.pushNil(),
        .array => |items| {
            const idx = std.fmt.parseInt(usize, head, 10) catch return L.pushNil();
            if (idx == 0 or idx > items.len) return L.pushNil();
            pushDynamicPath(L, items[idx - 1], rest);
        },
        else => L.pushNil(),
    }
}

// ─── mnml.http — the HTTP hooks and the way back into the client ────────
// An additive block: nothing above it reads anything below. The two
// HTTP hooks (`core/hooks.zig`) are marshalled here by hand because
// their `headers` crosses as a name → value table, not a flat field,
// and `http_request` reads a returned table back into the rewrite.

const cmd_http = @import("../app/cmd_http.zig");
const http_app = @import("../app/http.zig");

/// `mnml.http.set_var(name, value)` — `NAME=value` into the active env
/// file (the one `@capture` writes), creating the file when it is new.
/// Returns true, or false and the reason (a bad name, a newline).
fn httpSetVar(L: *State) !i32 {
    const c = ctx(L);
    const name = argStr(L, 1, "mnml.http.set_var", "the first argument is the variable name, a string of [A-Za-z0-9_]");
    const value = argStr(L, 2, "mnml.http.set_var", "the second argument is the value, a string of one line");
    cmd_http.setEnvVar(c.app, name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidKey => {
            L.pushBoolean(false);
            _ = L.pushString("key must be [A-Za-z0-9_]");
            return 2;
        },
        error.InvalidValue => {
            L.pushBoolean(false);
            _ = L.pushString("a value cannot contain newlines");
            return 2;
        },
        error.WriteFailed => {
            L.pushBoolean(false);
            _ = L.pushString(c.app.diag.msg orelse "write failed");
            return 2;
        },
    };
    L.pushBoolean(true);
    return 1;
}

/// `mnml.http.send(pane?)` — fire the request pane (the active one
/// without an argument). From inside `http_response` the send is
/// deferred until the hook returns; from inside `http_request` it is
/// an error (the send it would start is the one in flight).
fn httpSend(L: *State) !i32 {
    const c = ctx(L);
    const app = c.app;
    const id: PaneId = if (!L.isNoneOrNil(1)) blk: {
        const n = argInt(L, 1, "mnml.http.send", "takes a pane id, an integer — the request pane to fire; without one, the active pane");
        if (n < 0 or n > std.math.maxInt(PaneId)) L.raiseErrorStr("mnml.http.send: takes a pane id; %d is not one", .{@as(c_int, @intCast(@min(n, std.math.maxInt(c_int))))});
        break :blk @intCast(n);
    } else (app.active orelse L.raiseErrorStr("mnml.http.send: no active pane — pass the request pane's id", .{}));
    const p = app.panes.get(id) orelse L.raiseErrorStr("mnml.http.send: there is no pane %d", .{@as(c_int, @intCast(id))});
    if (p.asRequest() == null) L.raiseErrorStr("mnml.http.send: pane %d is not a request pane (open a .http / .curl / .rest file)", .{@as(c_int, @intCast(id))});
    switch (app.http.hook) {
        .request => L.raiseErrorStr("mnml.http.send: not from inside http_request (that send is the one in flight)", .{}),
        .response => {
            app.http.resend_pane = id;
            L.pushBoolean(true);
            return 1;
        },
        .none => {},
    }
    http_app.fire(app, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            L.pushBoolean(false);
            _ = L.pushString(app.diag.msg orelse @errorName(err));
            return 2;
        },
    };
    L.pushBoolean(true);
    return 1;
}

fn setStrField(L: *State, name: [:0]const u8, value: []const u8) void {
    _ = L.pushString(value);
    L.setField(-2, name);
}

/// `{ name = value, … }`; a repeated name keeps the last value.
fn pushHeaderTable(L: *State, headers: []const hooks.HttpHeader) void {
    L.newTable();
    for (headers) |h| {
        _ = L.pushString(h.name);
        _ = L.pushString(h.value);
        L.setTable(-3);
    }
}

/// The `.lua` prong of `hooks.emit` for `http_request` / `http_response`:
/// the payload table (plus `hook = "<name>"`) is the one argument; an
/// `http_request` subscriber's returned table lands in the rewrite.
pub fn callHttpHook(self: *Lua, r: LuaRef, args: hooks.HookArgs) void {
    const L = self.L;
    self.pushRef(r);
    switch (args) {
        .http_request => |a| {
            L.newTable();
            setStrField(L, "hook", "http_request");
            L.pushInteger(a.pane);
            L.setField(-2, "pane");
            setStrField(L, "method", a.method);
            setStrField(L, "url", a.url);
            pushHeaderTable(L, a.headers);
            L.setField(-2, "headers");
            if (a.body) |b| setStrField(L, "body", b);
            if (a.env) |e| setStrField(L, "env", e);
            // The result is read inside the protected call: its fields
            // may be behind an `__index`, its header values behind a
            // `__tostring` — the script's own code either way.
            const Ctx = struct {
                rewrite: *hooks.HttpRewrite,
                oom: bool = false,
                pub fn decode(c: *@This(), lua: *Lua) void {
                    if (lua.L.isTable(-1)) readRewrite(lua.L, -1, c.rewrite) catch {
                        c.oom = true;
                    };
                }
            };
            var rw_ctx: Ctx = .{ .rewrite = a.rewrite };
            self.pcallThen(1, 1, &rw_ctx) catch return toastHookError(self);
            if (rw_ctx.oom) self.app.toastLevel(.err, "hook: out of memory reading the http_request result", .{}) catch {};
        },
        .http_response => |a| {
            L.newTable();
            setStrField(L, "hook", "http_response");
            L.pushInteger(a.pane);
            L.setField(-2, "pane");
            L.pushInteger(a.status);
            L.setField(-2, "status");
            pushHeaderTable(L, a.headers);
            L.setField(-2, "headers");
            setStrField(L, "body", a.body);
            L.pushBoolean(a.body_truncated);
            L.setField(-2, "body_truncated");
            L.pushInteger(@intCast(@min(a.timing_ms, std.math.maxInt(i64))));
            L.setField(-2, "timing_ms");
            self.pcall(1, 0) catch return toastHookError(self);
        },
        else => unreachable,
    }
}

fn toastHookError(self: *Lua) void {
    self.app.toastLevel(.err, "hook: {s}", .{self.last_error orelse "script error"}) catch {};
}

/// The table at `t` → the rewrite: `method` / `url` / `body` strings
/// (`body = false` drops the body), `headers` a name → value table
/// that replaces the whole set. Anything else is ignored.
fn readRewrite(L: *State, t: i32, rw: *hooks.HttpRewrite) Allocator.Error!void {
    const at = L.absIndex(t);
    const top = L.getTop();
    defer L.setTop(top);
    if (strField(L, at, "method")) |m| try rw.setMethod(m);
    if (strField(L, at, "url")) |u| try rw.setUrl(u);
    switch (L.getField(at, "body")) {
        .string, .number => try rw.setBody(L.toString(-1) catch ""),
        .boolean => if (!L.toBoolean(-1)) rw.clearBody(),
        else => {},
    }
    L.pop(1);
    if (L.getField(at, "headers") == .table) {
        rw.beginHeaders();
        const ht = L.absIndex(-1);
        L.pushNil();
        while (L.next(ht)) {
            // key at -2, value at -1; the key is left as it is for `next`
            // (`toStringEx` pushes the value's string form, popped here).
            if (L.typeOf(-2) == .string) {
                const name = L.toString(-2) catch "";
                const value = L.toStringEx(-1);
                try rw.addHeader(name, value);
                L.pop(1);
            }
            L.pop(1);
        }
    }
}

// ─── mnml.decor, mnml.diagnostics ───────────────────────────────────────
// An additive block. The store and the anchoring live in
// `app/script_decor.zig`; everything here is argument checking — a
// wrong shape raises a Lua error naming the argument and the shape it
// wanted, which the script's `pcall` boundary turns into a toast with
// the line (`docs/LUA.md`'s promise).

const script_decor = @import("../app/script_decor.zig");
const script_task = @import("../app/script_task.zig");
const types = @import("../lsp/types.zig");

/// A namespace handle argument: an integer `mnml.decor.namespace`
/// answered with.
fn nsArg(L: *State, app: *App, arg: i32) u32 {
    // These four are shared by every decor / diagnostics call, so the
    // message is Lua's own `bad argument #N to '<fn>'` frame — it names
    // the position AND the function, which a fixed prefix could not.
    if (L.typeOf(arg) != .number or !L.isInteger(arg)) L.argError(arg, "ns must be a handle from mnml.decor.namespace(name)");
    const n = L.toInteger(arg) catch 0;
    if (n < 0 or n > std.math.maxInt(u32) or !script_decor.isNamespace(app, @intCast(n))) L.argError(arg, "ns must be a handle from mnml.decor.namespace(name)");
    return @intCast(n);
}

/// The editor pane an argument names; the active one when it is nil.
fn paneArg(L: *State, app: *App, arg: i32) PaneId {
    if (L.isNoneOrNil(arg)) {
        const id = app.active orelse L.argError(arg, "pane must be a pane id (mnml.pane.active()); there is no active pane");
        if (app.panes.editor(id) == null) L.argError(arg, "pane must name an editor pane");
        return id;
    }
    if (L.typeOf(arg) != .number or !L.isInteger(arg)) L.argError(arg, "pane must be a pane id (mnml.pane.active())");
    const n = L.toInteger(arg) catch 0;
    if (n < 0 or n > std.math.maxInt(PaneId)) L.argError(arg, "pane must be a pane id (mnml.pane.active())");
    if (app.panes.editor(@intCast(n)) == null) L.argError(arg, "pane must name an editor pane");
    return @intCast(n);
}

/// A 1-based line number, as `mnml.buf.line` and `mnml.buf.cursor` count.
fn lineArg(L: *State, arg: i32) u32 {
    if (L.typeOf(arg) != .number or !L.isInteger(arg)) L.argError(arg, "line must be a 1-based line number, as mnml.buf.cursor() counts");
    const n = L.toInteger(arg) catch 0;
    if (n < 1 or n > std.math.maxInt(u32)) L.argError(arg, "line must be a 1-based line number, as mnml.buf.cursor() counts");
    return @intCast(n);
}

fn byteArg(L: *State, arg: i32, comptime what: []const u8) usize {
    if (L.typeOf(arg) != .number or !L.isInteger(arg)) L.argError(arg, what ++ " must be a byte offset, an integer (0-based, `end` exclusive; mnml.buf.cursor() answers with one)");
    const n = L.toInteger(arg) catch 0;
    if (n < 0) L.argError(arg, what ++ " must be a byte offset, 0 or more (0-based, `end` exclusive)");
    return @intCast(n);
}

/// A theme role name, duped onto the gpa. Roles only — a script never
/// sees a colour; an unknown role paints plain (`ui/script_view.zig`).
fn roleArg(L: *State, gpa: Allocator, arg: i32, what: [:0]const u8) Allocator.Error![]u8 {
    if (L.typeOf(arg) != .string) L.raiseErrorStr("%s must be a theme role name, a string (\"accent\", \"error\", \"syn_string\", … — never a colour)", .{what.ptr});
    return gpa.dupe(u8, L.toString(arg) catch "");
}

/// The `segments` argument → gpa-owned segments: a string is one plain
/// segment, a list is its rows, a bare `{ text = … }` is one segment.
fn decodeSegs(self: *Lua, index: i32) Allocator.Error![]script_decor.Seg {
    const L = self.L;
    const gpa = self.gpa;
    const t = L.absIndex(index);
    var out: std.ArrayListUnmanaged(script_decor.Seg) = .empty;
    errdefer {
        for (out.items) |s| {
            gpa.free(s.text);
            if (s.fg) |f| gpa.free(f);
            if (s.bg) |b| gpa.free(b);
        }
        out.deinit(gpa);
    }
    switch (L.typeOf(t)) {
        .string, .number => try out.append(gpa, .{ .text = try gpa.dupe(u8, L.toString(t) catch "") }),
        .table => {
            if (L.getField(t, "text") != .nil) {
                L.pop(1);
                try out.append(gpa, try decodeSeg(self, t));
            } else {
                L.pop(1);
                const n = L.lenRaw(t);
                var i: usize = 1;
                while (i <= n) : (i += 1) {
                    _ = L.getIndex(t, @intCast(i));
                    defer L.pop(1);
                    switch (L.typeOf(-1)) {
                        .table => try out.append(gpa, try decodeSeg(self, -1)),
                        else => try out.append(gpa, .{ .text = try gpa.dupe(u8, L.toString(-1) catch "") }),
                    }
                }
            }
        },
        else => L.argError(index, "segments must be a string or a list of { text=, fg=, bg=, bold=, italic=, underline= }"),
    }
    return out.toOwnedSlice(gpa);
}

fn decodeSeg(self: *Lua, index: i32) Allocator.Error!script_decor.Seg {
    const L = self.L;
    const gpa = self.gpa;
    const t = L.absIndex(index);
    var seg: script_decor.Seg = .{ .text = try gpa.dupe(u8, strField(L, t, "text") orelse "") };
    errdefer gpa.free(seg.text);
    if (strField(L, t, "fg")) |f| seg.fg = try gpa.dupe(u8, f);
    errdefer if (seg.fg) |f| gpa.free(f);
    if (strField(L, t, "bg")) |b| seg.bg = try gpa.dupe(u8, b);
    seg.bold = boolField(L, t, "bold") orelse false;
    seg.italic = boolField(L, t, "italic") orelse false;
    seg.underline = boolField(L, t, "underline") orelse false;
    return seg;
}

fn setError(L: *State, where: [:0]const u8, err: script_decor.SetError) noreturn {
    switch (err) {
        error.OutOfMemory => L.raiseErrorStr("%s: out of memory", .{where.ptr}),
        error.NotAnEditor => L.raiseErrorStr("%s: pane must name an editor pane", .{where.ptr}),
        error.TooMany => L.raiseErrorStr("%s: too many decorations (the cap is 10000; clear a namespace)", .{where.ptr}),
    }
}

/// `mnml.decor.namespace(name)` → the handle.
fn decorNamespace(L: *State) !i32 {
    const c = ctx(L);
    if (L.typeOf(1) != .string) L.argError(1, "mnml.decor.namespace(name) takes a name, a string");
    const name = L.toString(1) catch "";
    if (name.len == 0) L.argError(1, "a namespace name cannot be empty");
    L.pushInteger(@intCast(try script_decor.namespace(c.app, c.self.id, name)));
    return 1;
}

/// `mnml.decor.virtual_text(ns, pane, line, segments, opts?)`.
fn decorVirtualText(L: *State) !i32 {
    const c = ctx(L);
    const ns = nsArg(L, c.app, 1);
    const pane = paneArg(L, c.app, 2);
    const line = lineArg(L, 3);
    var at: script_decor.At = .eol;
    if (!L.isNoneOrNil(5)) {
        if (L.typeOf(5) != .table) L.argError(5, "the options are a table: { at = \"eol\" | \"above\" | \"below\" }");
        if (strField(L, 5, "at")) |s| at = std.meta.stringToEnum(script_decor.At, s) orelse L.argError(5, "at is \"eol\", \"above\" or \"below\"");
    }
    const segs = try decodeSegs(c.self, 4);
    script_decor.addVirtualText(c.app, ns, pane, line, segs, at) catch |err| setError(L, "mnml.decor.virtual_text", err);
    return 0;
}

/// `mnml.decor.gutter(ns, pane, line, glyph, opts?)`.
fn decorGutter(L: *State) !i32 {
    const c = ctx(L);
    const ns = nsArg(L, c.app, 1);
    const pane = paneArg(L, c.app, 2);
    const line = lineArg(L, 3);
    if (L.typeOf(4) != .string) L.argError(4, "glyph must be a string of one cell (\"▎\", \"●\")");
    // Everything is checked BEFORE anything is allocated: a Lua error
    // is a longjmp out of this function, so an `errdefer` below one
    // would never run.
    var role_name: []const u8 = "fg";
    var priority: u8 = @import("../ui/editor_view.zig").mark_priority.script;
    if (!L.isNoneOrNil(5)) {
        if (L.typeOf(5) != .table) L.argError(5, "the options are a table: { fg = role, priority = n }");
        if (intField(L, 5, "priority")) |p| {
            if (p < 0 or p > 255) L.argError(5, "priority is 0…255 (50 by default; breakpoints 90, diagnostics 60, git 10)");
            priority = @intCast(p);
        }
        if (strField(L, 5, "fg")) |f| role_name = f;
    }
    const glyph = try c.self.gpa.dupe(u8, L.toString(4) catch "");
    errdefer c.self.gpa.free(glyph);
    const role = try c.self.gpa.dupe(u8, role_name);
    script_decor.addGutter(c.app, ns, pane, line, glyph, role, priority) catch |err| setError(L, "mnml.decor.gutter", err);
    return 0;
}

/// `mnml.decor.highlight(ns, pane, start_byte, end_byte, role)`.
fn decorHighlight(L: *State) !i32 {
    const c = ctx(L);
    const ns = nsArg(L, c.app, 1);
    const pane = paneArg(L, c.app, 2);
    const start = byteArg(L, 3, "start_byte");
    const end = byteArg(L, 4, "end_byte");
    const role = try roleArg(L, c.self.gpa, 5, "mnml.decor.highlight: role");
    script_decor.addHighlight(c.app, ns, pane, start, end, role) catch |err| setError(L, "mnml.decor.highlight", err);
    return 0;
}

/// `mnml.decor.line(ns, pane, line, role)`.
fn decorLine(L: *State) !i32 {
    const c = ctx(L);
    const ns = nsArg(L, c.app, 1);
    const pane = paneArg(L, c.app, 2);
    const line = lineArg(L, 3);
    const role = try roleArg(L, c.self.gpa, 4, "mnml.decor.line: role");
    script_decor.addLine(c.app, ns, pane, line, role) catch |err| setError(L, "mnml.decor.line", err);
    return 0;
}

/// `mnml.decor.clear(ns, pane?)` → how many decorations went.
fn decorClear(L: *State) !i32 {
    const c = ctx(L);
    const ns = nsArg(L, c.app, 1);
    const pane: ?PaneId = if (L.isNoneOrNil(2)) null else paneArg(L, c.app, 2);
    L.pushInteger(@intCast(script_decor.clear(c.app, ns, pane)));
    return 1;
}

/// `mnml.diagnostics.set(ns, path, list)`. `path` is workspace-relative
/// (or absolute); `line` / `col` are 1-based, as every other position a
/// script sees.
fn diagnosticsSet(L: *State) !i32 {
    const c = ctx(L);
    const app = c.app;
    const ns = nsArg(L, app, 1);
    if (L.typeOf(2) != .string) L.argError(2, "path must be a string (workspace-relative, or absolute)");
    const rel = L.toString(2) catch "";
    if (L.typeOf(3) != .table) L.argError(3, "the list is a table of { line, col, end_col?, severity, message, source }");
    const arena = app.frame.allocator();
    const abs = if (std.fs.path.isAbsolute(rel)) try arena.dupe(u8, rel) else try std.fs.path.join(arena, &.{ app.workspace, rel });
    var out: std.ArrayListUnmanaged(types.Diagnostic) = .empty;
    const n = L.lenRaw(3);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        _ = L.getIndex(3, @intCast(i));
        defer L.pop(1);
        if (!L.isTable(-1)) L.argError(3, "every diagnostic is a table: { line, col, end_col?, severity, message, source }");
        const line = intField(L, -1, "line") orelse L.argError(3, "a diagnostic needs `line`, a 1-based line number");
        const col = intField(L, -1, "col") orelse 1;
        const end_col = intField(L, -1, "end_col");
        const msg = strField(L, -1, "message") orelse L.argError(3, "a diagnostic needs `message`, a string");
        const sev_name = strField(L, -1, "severity") orelse "error";
        const sev: types.Severity = if (std.mem.eql(u8, sev_name, "error"))
            .err
        else if (std.mem.eql(u8, sev_name, "warning"))
            .warning
        else if (std.mem.eql(u8, sev_name, "info"))
            .info
        else if (std.mem.eql(u8, sev_name, "hint"))
            .hint
        else
            L.argError(3, "severity is \"error\", \"warning\", \"info\" or \"hint\"");
        const start_col: u32 = @intCast(@max(col, 1) - 1);
        const end: u32 = if (end_col) |e| @intCast(@max(@max(e, 1) - 1, start_col + 1)) else start_col + 1;
        try out.append(arena, .{
            .range = .{
                .start = .{ .line = @intCast(@max(line, 1) - 1), .character = start_col },
                .end = .{ .line = @intCast(@max(line, 1) - 1), .character = end },
            },
            .severity = sev,
            .message = try arena.dupe(u8, msg),
            .source = if (strField(L, -1, "source")) |s| try arena.dupe(u8, s) else null,
            .code = null,
        });
    }
    try script_decor.setDiagnostics(app, ns, abs, out.items);
    return 0;
}

/// `mnml.diagnostics.clear(ns, path?)`.
fn diagnosticsClear(L: *State) !i32 {
    const c = ctx(L);
    const app = c.app;
    const ns = nsArg(L, app, 1);
    const arena = app.frame.allocator();
    var abs: ?[]const u8 = null;
    if (!L.isNoneOrNil(2)) {
        if (L.typeOf(2) != .string) L.argError(2, "path must be a string (workspace-relative, or absolute)");
        const rel = L.toString(2) catch "";
        abs = if (std.fs.path.isAbsolute(rel)) try arena.dupe(u8, rel) else try std.fs.path.join(arena, &.{ app.workspace, rel });
    }
    try script_decor.clearDiagnostics(app, ns, abs);
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Key = app_mod.Key;
const keymap = @import("../core/keymap.zig");
const dap_app = @import("../app/dap.zig");
const lsp_app = @import("../app/lsp.zig");

test "mnml.command registers user.<id>, binds its keys, runs, and a reload unregisters it" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    try lua.runString(
        \\hits = 0
        \\local id = mnml.command{ id = "hello", title = "Say hello", keys = { "ctrl+shift+h" }, run = function() hits = hits + 1; mnml.toast("hi from lua") end }
        \\assert(id == "user.hello")
        \\mnml.map("ctrl+shift+m", function() hits = hits + 10 end)
    );
    const slot = app.dyn_commands.get("user.hello").?;
    try testing.expectEqualStrings("Say hello", app.dyn_commands.at(slot).?.title);
    try testing.expect(app.dyn_commands.at(slot).?.runner == .lua);
    try command.runNamed(&app, "user.hello");
    try testing.expectEqualStrings("hi from lua", app.lastToast().?);
    // The chord resolves to the dynamic command, and pressing it runs it.
    var buf: [keymap.max_seq]@import("../core/key.zig").Chord = undefined;
    try testing.expectEqualStrings("user.hello", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+h", &buf).?).run.named);
    try app.handle(.{ .key = .{ .code = .{ .char = 'h' }, .mods = .{ .ctrl = true, .shift = true } } });
    try app.handle(.{ .key = .{ .code = .{ .char = 'm' }, .mods = .{ .ctrl = true, .shift = true } } });
    _ = lua.L.getGlobal("hits");
    try testing.expectEqual(@as(zlua.Integer, 12), try lua.L.toInteger(-1));
    lua.L.pop(1);
    // A failing command lands in diag + a toast, and the app survives.
    try lua.runString("mnml.command{ id = 'bad', run = function() error('kaboom') end }");
    try testing.expectError(error.Failed, command.runNamed(&app, "user.bad"));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "kaboom") != null);
    // The `user.` prefix means a script id can never shadow a built-in.
    try lua.runString("mnml.command{ id = 'quit', run = function() end }");
    try testing.expect(app.dyn_commands.get("user.quit") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.on('no_such_hook', function() end)"));
    // The keymap rebuild (input-style switch) keeps the script's chords.
    try app.setInputStyle(.vim);
    try testing.expectEqualStrings("user.hello", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+h", &buf).?).run.named);
    // Reload forgets everything script-owned; the chord is gone.
    try lua.reset();
    try testing.expect(app.dyn_commands.get("user.hello") == null);
    try testing.expect(app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+h", &buf).?) == .none);
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.buf.apply's change is the last change: vim's `.` repeats it" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratchWith("abc");
    try lua.runString("assert(mnml.buf.apply{ op = 'insert_str', text = 'X' })");
    const e = app.activeEditor().?;
    try testing.expectEqualStrings("Xabc", e.buf.editor.bytes());
    try command.run(&app, .{ .static = .@"vim.dot_repeat" });
    try testing.expectEqualStrings("XXabc", e.buf.editor.bytes());
    // A move is not a change: `.` still repeats the insert.
    try lua.runString("assert(not mnml.buf.apply{ op = 'move_to_line', line = 1 })");
    try command.run(&app, .{ .static = .@"vim.dot_repeat" });
    try testing.expectEqualStrings("XXXabc", e.buf.editor.bytes());
}

test "mnml.on fires with the marshalled args; mnml.buf.apply goes through EditOp and undo works" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratch();
    lua.runString(
        \\saved = nil
        \\mnml.on("save_post", function(a) saved = a end)
        \\mnml.on("pane_focus", function(a) focused = a.pane end)
        \\assert(mnml.buf.apply{ op = "insert_str", text = "hello world" })
        \\assert(mnml.buf.text() == "hello world")
        \\local line, col, byte = mnml.buf.cursor()
        \\assert(line == 1 and col == 12 and byte == 11, line .. ":" .. col .. ":" .. byte)
        \\assert(mnml.buf.apply{ op = "replace_range", start = 0, ["end"] = 5, text = "HELLO" })
        \\assert(mnml.buf.line(1) == "HELLO world")
        \\assert(mnml.buf.line(2) == nil and mnml.buf.line_count() == 1)
        \\assert(not mnml.buf.apply{ op = "move_to_line", line = 1 })
        \\assert(not mnml.buf.apply{ op = "select_range", start = 0, ["end"] = 5 }) -- a selection is not a text change
        \\assert(mnml.buf.apply{ op = "delete_selection" })
        \\assert(mnml.buf.text() == " world")
        \\assert(mnml.buf.path() == nil)
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    // Undo is the same history the keys use: the deletion comes back
    // first, then the replace, then the insert.
    const e = app.activeEditor().?;
    _ = try app.applyOps(e, &.{.undo});
    try testing.expectEqualStrings("HELLO world", e.buf.editor.bytes());
    var steps: usize = 0;
    while (!std.mem.eql(u8, e.buf.editor.bytes(), "hello world") and steps < 4) : (steps += 1) _ = try app.applyOps(e, &.{.undo});
    try testing.expectEqualStrings("hello world", e.buf.editor.bytes());
    _ = try app.applyOps(e, &.{.undo});
    try testing.expectEqualStrings("", e.buf.editor.bytes());
    // The hook.
    app.hooks.emit(&app, .{ .save_post = .{ .path = "notes.txt", .pane = 0, .bytes = 11 } });
    try lua.runString("assert(saved.path == 'notes.txt' and saved.pane == 0 and saved.bytes == 11 and saved.hook == 'save_post', tostring(saved))");
    app.setActive(null);
    try lua.runString("assert(focused == nil)");
    // Malformed ops are Lua errors, not crashes.
    try testing.expectError(error.Failed, lua.runString("mnml.buf.apply{ op = 'nope' }"));
    try testing.expectError(error.Failed, lua.runString("mnml.buf.apply{ op = 'insert_str' }"));
    try testing.expectError(error.Failed, lua.runString("mnml.buf.text(99)"));
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.inspect: every type, the array part before the sorted keys, a cycle marked, a depth cap, and print still toasts" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    const Case = struct { src: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .src = "mnml.inspect(nil)", .want = "nil" },
        .{ .src = "mnml.inspect(true)", .want = "true" },
        .{ .src = "mnml.inspect(7)", .want = "7" },
        .{ .src = "mnml.inspect(1.5)", .want = "1.5" },
        .{ .src = "mnml.inspect('hi')", .want = "\"hi\"" },
        .{ .src = "mnml.inspect('a\\nb\"c')", .want = "\"a\\nb\\\"c\"" },
        .{ .src = "mnml.inspect(print)", .want = "<function>" },
        .{ .src = "mnml.inspect({})", .want = "{}" },
        .{ .src = "mnml.inspect({ 1, 2, 3 })", .want = "{ 1, 2, 3 }" },
        // The array part first, then the rest of the keys in sorted
        // order — `next`'s own order is the hash's and varies.
        .{ .src = "mnml.inspect({ 'x', zed = 1, alpha = 2 })", .want = "{ \"x\", alpha = 2, zed = 1 }" },
        .{ .src = "mnml.inspect({ ['a b'] = 1, [2.5] = 2 })", .want = "{ [\"a b\"] = 1, [2.5] = 2 }" },
        .{ .src = "mnml.inspect({ a = { b = { c = 1 } } })", .want = "{ a = { b = { c = 1 } } }" },
        // Four tables deep is the cap, the outermost counted: the fifth
        // is `{…}`.
        .{ .src = "mnml.inspect({ a = { b = { c = { d = { e = 1 } } } } })", .want = "{ a = { b = { c = { d = {…} } } } }" },
        .{ .src = "local t = {} t.self = t return mnml.inspect(t)", .want = "{ self = <cycle> }" },
        // A table reached twice down two branches is not a cycle.
        .{ .src = "local s = { 1 } return mnml.inspect({ a = s, b = s })", .want = "{ a = { 1 }, b = { 1 } }" },
    };
    for (cases) |c| {
        const got = (try lua.eval(c.src)) orelse {
            std.debug.print("`{s}` answered nothing\n", .{c.src});
            return error.TestExpectedEqual;
        };
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("`{s}`\n  wanted: {s}\n  got:    {s}\n", .{ c.src, c.want, got });
            return error.TestExpectedEqual;
        }
    }
    // No argument at all is the one error: `inspect(nil)` is a question,
    // `inspect()` is a mistake.
    try testing.expectError(error.Failed, lua.runString("mnml.inspect()"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error orelse "", "takes one value") != null);
    // `print` is still the log: it toasts, and `inspect` never does.
    app.dismissToasts();
    try lua.runString("mnml.inspect({ 1 })");
    try testing.expect(app.lastToast() == null);
    try lua.runString("print(mnml.inspect({ a = 1 }))");
    try testing.expectEqualStrings("{ a = 1 }", app.lastToast().?);
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.commands: every command, narrowed by the query, each row carrying its MRU rank" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    // Nothing has run yet: every row is rank-less, and `if row.rank`
    // reads as the question it is.
    try lua.runString(
        \\local all = mnml.commands()
        \\assert(#all > 100, tostring(#all))
        \\for _, c in ipairs(all) do assert(c.rank == nil, c.id .. " has a rank") end
        \\local save = nil
        \\for _, c in ipairs(mnml.commands("toggle_line_numbers")) do save = c end
        \\assert(save and save.id == "view.toggle_line_numbers", tostring(save))
        \\assert(save.group == "view" and #save.title > 0)
    );
    // Two runs, and the MRU has them newest first — 1 is the last one.
    try command.runNamed(&app, "view.toggle_line_numbers");
    try command.runNamed(&app, "view.toggle_tree");
    try lua.runString(
        \\local rank = {}
        \\for _, c in ipairs(mnml.commands()) do rank[c.id] = c.rank end
        \\assert(rank["view.toggle_tree"] == 1, tostring(rank["view.toggle_tree"]))
        \\assert(rank["view.toggle_line_numbers"] == 2, tostring(rank["view.toggle_line_numbers"]))
        \\assert(rank["app.quit"] == nil)
    );
    // A script command is in the same list, and its own runs count.
    try lua.runString("mnml.command{ id = 'hello', title = 'Say hello', run = function() end }");
    try command.runNamed(&app, "user.hello");
    try lua.runString(
        \\local rows = mnml.commands("user.hello")
        \\assert(#rows == 1 and rows[1].rank == 1 and rows[1].title == "Say hello", tostring(#rows))
    );
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "a picker source that blows the script budget opens on (no matches), and the toast is the only thing that says why" {
    // The shape the shipped `lua/recent-commands` example hit when the
    // budget was a flat 20 ms: `items` raised `mnml: script budget
    // exceeded`, `callItems` turned the failed call into an empty list,
    // and the picker painted `(no matches)` — a source with nothing to
    // show and a source that ran out of time look identical in the list.
    // The toast is the whole difference, so it is asserted here.
    //
    // Forced with a loop that cannot finish rather than with a slow one,
    // so what is pinned is the outcome, not how fast this machine is.
    // The budget figure itself is pinned in `lua.zig`, and the shipped
    // example's real headroom by `lua_example_recent_commands.test`
    // against the built binary.
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 20 });
    defer app.deinit();
    const lua = app.script();
    try lua.runString(
        \\mnml.picker.source{ id = "runaway", title = "Runaway", items = function() while true do end end }
    );
    // The open comes back as an error too: the deadline is armed once,
    // at the outermost call, so once `items` has spent it the chunk that
    // called `open` trips at its next hook as well.
    lua.runString("mnml.picker.open('runaway')") catch {};
    try testing.expect(app.overlay == .picker);
    try testing.expectEqual(@as(usize, 0), app.overlay.picker.labels.len);
    var said_why = false;
    for (app.toasts.items) |t| {
        if (std.mem.indexOf(u8, t.text, "budget") != null) said_why = true;
    }
    try testing.expect(said_why);
    try testing.expect(lua.budget_hits >= 1);
}

test "mnml.config.get walks structs, maps, optionals and Dynamic; mnml.workspace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg: Config = .{};
    cfg.editor.tab_width = 3;
    try cfg.lsp.put(arena, "rust", .{ .cmd = "rust-analyzer", .extensions = &.{ "rs", "rst" } });
    try cfg.keys.global.put(arena, "ctrl+shift+x", "view.about");
    cfg.tools = .{ .object = &.{.{ .name = "jira", .value = .{ .object = &.{.{ .name = "url", .value = .{ .string = "https://x" } }} } }} };
    var app = try App.initWith(testing.allocator, testing.io, .{ .cfg = cfg, .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    try lua.runString(
        \\assert(mnml.config.get("editor.tab_width") == 3)
        \\assert(mnml.config.get("editor.input_style") == "standard")
        \\assert(mnml.config.get("lsp.rust.cmd") == "rust-analyzer")
        \\assert(mnml.config.get("lsp.rust.extensions.2") == "rst")
        \\assert(mnml.config.get("lsp.python") == nil)
        \\assert(mnml.config.get("keys.global")["ctrl+shift+x"] == "view.about")
        \\assert(mnml.config.get("tools.jira.url") == "https://x")
        \\assert(mnml.config.get("nope.nope") == nil)
        \\assert(mnml.config.get("editor").tab_width == 3)
        \\assert(mnml.config.get().ui.tree_width ~= nil)
        \\assert(mnml.workspace() == "/tmp")
    );
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.decor: the four decorations paint, anchored, in a namespace the reload drops" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
    app.tree.visible = false;
    const lua = app.script();
    const pane = try app.openScratchWith("alpha\nbeta\ngamma\n");
    _ = pane;
    lua.runString(
        \\ns = mnml.decor.namespace("demo")
        \\local pane = mnml.pane.active()
        \\mnml.decor.virtual_text(ns, pane, 1, { { text = "  << here", fg = "muted" } })
        \\mnml.decor.virtual_text(ns, pane, 2, "ABOVE-ROW", { at = "above" })
        \\mnml.decor.virtual_text(ns, pane, 2, "BELOW-ROW", { at = "below" })
        \\mnml.decor.gutter(ns, pane, 3, "!", { fg = "accent", priority = 70 })
        \\mnml.decor.line(ns, pane, 3, "match")
        \\mnml.decor.highlight(ns, pane, 6, 10, "match")
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    {
        const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
        defer testing.allocator.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "alpha  << here") != null);
        try testing.expect(std.mem.indexOf(u8, txt, "ABOVE-ROW") != null);
        try testing.expect(std.mem.indexOf(u8, txt, "BELOW-ROW") != null);
        try testing.expect(std.mem.indexOf(u8, txt, "!") != null);
        // The rows are in text order: above, the line, below.
        const above = std.mem.indexOf(u8, txt, "ABOVE-ROW").?;
        const beta = std.mem.indexOf(u8, txt, "beta").?;
        const below = std.mem.indexOf(u8, txt, "BELOW-ROW").?;
        try testing.expect(above < beta and beta < below);
    }
    // A line inserted above line 1 carries every decoration down with
    // its own text.
    const e = app.activeEditor().?;
    _ = try app.applyOps(e, &.{ .{ .set_cursor_byte = 0 }, .{ .insert_str = "zero\n" } });
    try app.render();
    {
        const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
        defer testing.allocator.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "alpha  << here") != null);
        const above = std.mem.indexOf(u8, txt, "ABOVE-ROW").?;
        try testing.expect(std.mem.indexOf(u8, txt, "zero").? < above);
    }
    // The namespace goes with the reload.
    try lua.reset();
    try app.render();
    {
        const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
        defer testing.allocator.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "<< here") == null);
        try testing.expect(std.mem.indexOf(u8, txt, "ABOVE-ROW") == null);
    }
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

/// One wrong call and the words its message must carry.
const ArgCase = struct { src: []const u8, want: []const u8 };

/// Every case must fail, must carry `want`, and must name the call it
/// was — either as `mnml.<path>:` (this file's own messages) or as
/// Lua's `bad argument #N to '<fn>'`. A message that says only what the
/// type was is the thing these tests exist to keep out.
fn expectArgErrors(lua: *lua_mod.Lua, cases: []const ArgCase) !void {
    for (cases) |c| {
        lua.runString(c.src) catch |err| switch (err) {
            error.Failed => {},
            else => return err,
        };
        const msg = lua.last_error orelse "";
        if (std.mem.indexOf(u8, msg, c.want) == null) {
            std.debug.print("`{s}`\n  wanted: {s}\n  got:    {s}\n", .{ c.src, c.want, msg });
            return error.TestExpectedEqual;
        }
        if (std.mem.indexOf(u8, msg, "mnml.") == null and std.mem.indexOf(u8, msg, "bad argument #") == null) {
            std.debug.print("`{s}`\n  names no call: {s}\n", .{ c.src, msg });
            return error.TestExpectedEqual;
        }
    }
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.decor: every argument error names the argument and the shape it wanted" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratchWith("alpha\nbeta\n");
    try lua.runString("ns = mnml.decor.namespace('demo')");
    const cases = [_]ArgCase{
        .{ .src = "mnml.decor.namespace()", .want = "takes a name, a string" },
        .{ .src = "mnml.decor.namespace('')", .want = "cannot be empty" },
        .{ .src = "mnml.decor.gutter(999, mnml.pane.active(), 1, '!')", .want = "mnml.decor.namespace(name)" },
        .{ .src = "mnml.decor.line(ns, 77, 1, 'match')", .want = "editor pane" },
        .{ .src = "mnml.decor.line(ns, mnml.pane.active(), 0, 'match')", .want = "1-based line number" },
        .{ .src = "mnml.decor.line(ns, mnml.pane.active(), 1, 3)", .want = "theme role name" },
        .{ .src = "mnml.decor.gutter(ns, mnml.pane.active(), 1, 7)", .want = "glyph must be a string" },
        .{ .src = "mnml.decor.gutter(ns, mnml.pane.active(), 1, '!', { priority = 900 })", .want = "priority is 0" },
        .{ .src = "mnml.decor.virtual_text(ns, mnml.pane.active(), 1, 'x', { at = 'sideways' })", .want = "at is \"eol\"" },
        .{ .src = "mnml.decor.virtual_text(ns, mnml.pane.active(), 1, true)", .want = "segments must be a string or a list" },
        .{ .src = "mnml.decor.highlight(ns, mnml.pane.active(), -1, 4, 'match')", .want = "byte offset" },
        .{ .src = "mnml.decor.highlight(ns, mnml.pane.active(), 0, 4, 9)", .want = "role must be a theme role" },
        .{ .src = "mnml.diagnostics.set(ns, 3, {})", .want = "path must be a string" },
        .{ .src = "mnml.diagnostics.set(ns, 'a.js', 'nope')", .want = "the list is a table" },
        .{ .src = "mnml.diagnostics.set(ns, 'a.js', { { col = 1, message = 'x' } })", .want = "needs `line`" },
        .{ .src = "mnml.diagnostics.set(ns, 'a.js', { { line = 1 } })", .want = "needs `message`" },
        .{ .src = "mnml.diagnostics.set(ns, 'a.js', { { line = 1, message = 'x', severity = 'loud' } })", .want = "severity is" },
        .{ .src = "mnml.diagnostics.clear(ns, 3)", .want = "path must be a string" },
    };
    try expectArgErrors(lua, &cases);
}

test "argument errors: the root functions name the call, the argument and the shape" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    const cases = [_]ArgCase{
        .{ .src = "mnml.command('hello')", .want = "mnml.command takes one table: { id, title?, group?, keys?, run }" },
        .{ .src = "mnml.command{ run = function() end }", .want = "mnml.command: `id` is required and must be a bare name" },
        .{ .src = "mnml.command{ id = 'a b', run = function() end }", .want = "mnml.command: `id` must be a bare name" },
        .{ .src = "mnml.command{ id = 'ok' }", .want = "mnml.command: `run` must be a function()" },
        .{ .src = "mnml.map(3, function() end)", .want = "mnml.map: the first argument is a chord spec, a string" },
        .{ .src = "mnml.map('ctrl+shift+n', 7)", .want = "mnml.map: the second argument is a function()" },
        .{ .src = "mnml.map('ctrl+shift+n', 'no.such.command')", .want = "mnml.map: the second argument names no command" },
        .{ .src = "mnml.on(3, function() end)", .want = "mnml.on: the first argument is a hook name, a string" },
        .{ .src = "mnml.on('save_post', 3)", .want = "mnml.on: the second argument is a function(args)" },
        // The list of hooks is built from the enum, so the message can
        // never name a hook that is gone or miss one that is new.
        .{ .src = "mnml.on('on_save', function() end)", .want = "mnml.on: `on_save` is not a hook — the names are startup, exit, open, save_pre, save_post" },
        .{ .src = "mnml.toast(3)", .want = "mnml.toast: the first argument is the text, a string" },
        .{ .src = "mnml.toast('x', 'loud')", .want = "mnml.toast: the level is \"info\", \"warn\" or \"error\"" },
        .{ .src = "mnml.toast('x', 3)", .want = "mnml.toast: the second argument is the level" },
        .{ .src = "mnml.run(3)", .want = "mnml.run: takes a command id, a string" },
        .{ .src = "mnml.ex(3)", .want = "mnml.ex: takes a `:` line without the colon" },
        .{ .src = "mnml.inspect()", .want = "mnml.inspect(v) takes one value" },
        .{ .src = "mnml.commands(3)", .want = "mnml.commands: takes a query, a string" },
        .{ .src = "mnml.operator{ id = 'a', keys = { vim = 'gs' } }", .want = "mnml.operator: `run` must be a function(range)" },
        .{ .src = "mnml.operator('a')", .want = "mnml.operator takes one table" },
    };
    try expectArgErrors(lua, &cases);
    // Nothing above left a registration behind: every check lands
    // before the first allocation or ref.
    try testing.expectEqual(@as(usize, 0), lua.operators.items.len);
    try testing.expect(app.dyn_commands.get("user.ok") == null);
}

test "argument errors: mnml.buf names the call, the argument and the shape" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratchWith("alpha\nbeta\n");
    const cases = [_]ArgCase{
        .{ .src = "mnml.buf.text('two')", .want = "mnml.buf: `pane` must be a pane id" },
        .{ .src = "mnml.buf.text(99)", .want = "mnml.buf: `pane` must name an editor pane" },
        .{ .src = "mnml.buf.line('1')", .want = "mnml.buf.line: the first argument is a 1-based line number" },
        .{ .src = "mnml.buf.apply('insert_str')", .want = "mnml.buf.apply takes one table" },
        .{ .src = "mnml.buf.apply{}", .want = "mnml.buf.apply: `op` is required and must be an edit-op tag" },
        .{ .src = "mnml.buf.apply{ op = 'nope' }", .want = "mnml.buf.apply: `op` names no edit op" },
        .{ .src = "mnml.buf.apply{ op = 'insert_str' }", .want = "mnml.buf.apply: `insert_str` needs `text`, a string" },
        .{ .src = "mnml.buf.apply{ op = 'move_to_line' }", .want = "mnml.buf.apply: `move_to_line` needs an integer `value`" },
        .{ .src = "mnml.buf.apply{ op = 'replace_range', start = 0 }", .want = "mnml.buf.apply: `replace_range` needs `end`, an integer" },
        .{ .src = "mnml.buf.apply{ op = 'select_range', start = 0 }", .want = "mnml.buf.apply: select_range needs `start` and `end`" },
        .{ .src = "mnml.buf.apply{ op = 'atomic' }", .want = "mnml.buf.apply: atomic needs `ops`, a list of op tables" },
        .{ .src = "mnml.buf.apply{ op = 'atomic', ops = { 3 } }", .want = "mnml.buf.apply: every entry of `ops` must be an op table" },
        .{ .src = "mnml.buf.apply{ op = 'repeat', count = 2 }", .want = "mnml.buf.apply: repeat needs `inner`, one op table" },
        .{ .src = "mnml.buf.range(-1, 2)", .want = "bad argument #1 to 'range' (start must be a byte offset, 0 or more" },
        .{ .src = "mnml.buf.word_at('x')", .want = "bad argument #1 to 'word_at' (byte must be a byte offset" },
    };
    try expectArgErrors(lua, &cases);
}

test "argument errors: mnml.list, mnml.section and mnml.pane name the call, the argument and the shape" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    const cases = [_]ArgCase{
        .{ .src = "mnml.list('TODOS')", .want = "mnml.list takes one table: { title, rows, on_enter?, on_menu?, sort? }" },
        .{ .src = "mnml.list{ rows = function() end }", .want = "mnml.list: `title` is required" },
        .{ .src = "mnml.list{ title = 'T' }", .want = "mnml.list: `rows` must be a function(sort)" },
        .{ .src = "mnml.list{ title = 'T', rows = function() end, sort = 'State' }", .want = "mnml.list: `sort` must be a table of mode names" },
        .{ .src = "mnml.list{ title = 'T', rows = function() end, on_enter = 3 }", .want = "mnml.list: `on_enter` must be a function(row)" },
        .{ .src = "mnml.list{ title = 'T', rows = function() end, on_menu = 3 }", .want = "mnml.list: `on_menu` must be a function(row)" },
        .{ .src = "mnml.section('todos')", .want = "mnml.section takes one table" },
        .{ .src = "mnml.section{ title = 'T' }", .want = "mnml.section: `id` is required" },
        .{ .src = "mnml.section{ id = 'a b' }", .want = "mnml.section: `id` must be a bare name" },
        .{ .src = "mnml.section{ id = 'todos_lua' }", .want = "mnml.section: `list` is required" },
        .{ .src = "mnml.section{ id = 'todos_lua', list = 99 }", .want = "`list` names no live list" },
        .{ .src = "mnml.pane.open('Notes')", .want = "mnml.pane.open takes one table" },
        .{ .src = "mnml.pane.open{ title = 'Notes' }", .want = "mnml.pane.open: `render` must be a function(w, h)" },
        .{ .src = "mnml.pane.open{ title = 'N', render = function() end, on_key = 3 }", .want = "mnml.pane.open: `on_key` must be a function(chord)" },
        .{ .src = "mnml.pane.open{ title = 'N', render = function() end, on_hit = 3 }", .want = "mnml.pane.open: `on_hit` must be a function(hit_id" },
        .{ .src = "mnml.pane.close('1')", .want = "mnml.pane.close: takes a pane id" },
    };
    try expectArgErrors(lua, &cases);
    // The `sorts` a bad `rows` used to leave behind: nothing registered.
    try testing.expectEqual(@as(u32, 0), lua.summary().lists);
}

test "argument errors: mnml.picker, mnml.statusline and mnml.task name the call, the argument and the shape" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    const cases = [_]ArgCase{
        .{ .src = "mnml.picker.source('notes')", .want = "mnml.picker.source takes one table" },
        .{ .src = "mnml.picker.source{ items = function() end }", .want = "mnml.picker.source: `id` is required" },
        .{ .src = "mnml.picker.source{ id = 'notes' }", .want = "mnml.picker.source: `items` must be a function(query) returning a table of rows" },
        .{ .src = "mnml.picker.source{ id = 'n', items = function() end, preview = 3 }", .want = "mnml.picker.source: `preview` must be a function(row)" },
        .{ .src = "mnml.picker.source{ id = 'n', items = function() end, on_accept = 3 }", .want = "mnml.picker.source: `on_accept` must be a function(row)" },
        .{ .src = "mnml.picker.open(3)", .want = "mnml.picker.open: the first argument is a source id" },
        .{ .src = "mnml.picker.open('nope')", .want = "mnml.picker.open: no source `nope`" },
        .{ .src = "mnml.statusline.segment('clock')", .want = "mnml.statusline.segment takes one table" },
        .{ .src = "mnml.statusline.segment{ fn = function() end }", .want = "mnml.statusline.segment: `id` is required" },
        .{ .src = "mnml.statusline.segment{ id = 'clock' }", .want = "mnml.statusline.segment: `fn` must be a function() returning the text" },
        .{ .src = "mnml.statusline.segment{ id = 'c', side = 'up', fn = function() end }", .want = "mnml.statusline.segment: `side` is \"left\" or \"right\"" },
        .{ .src = "mnml.task.run('ls')", .want = "mnml.task.run takes one table" },
        .{ .src = "mnml.task.run{ label = 'x' }", .want = "mnml.task.run: `cmd` is required" },
        .{ .src = "mnml.task.run{ cmd = 'ls', on_done = 3 }", .want = "mnml.task.run: `on_done` must be a function(result)" },
        .{ .src = "mnml.task.run{ cmd = 'ls', on_line = function() end }", .want = "mnml.task.run: `on_line` needs `hidden = true`" },
    };
    try expectArgErrors(lua, &cases);
    try testing.expectEqual(@as(usize, 0), lua.sources.items.len);
    try testing.expectEqual(@as(usize, 0), lua.segments.items.len);
}

test "argument errors: mnml.config and mnml.http name the call, the argument and the shape" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratch();
    const cases = [_]ArgCase{
        .{ .src = "mnml.config.get(3)", .want = "mnml.config.get: takes a dotted path, a string" },
        .{ .src = "mnml.http.set_var(3, 'x')", .want = "mnml.http.set_var: the first argument is the variable name" },
        .{ .src = "mnml.http.set_var('TOKEN', 3)", .want = "mnml.http.set_var: the second argument is the value" },
        .{ .src = "mnml.http.send('two')", .want = "mnml.http.send: takes a pane id" },
        .{ .src = "mnml.http.send(99)", .want = "mnml.http.send: there is no pane 99" },
        .{ .src = "mnml.http.send()", .want = "mnml.http.send: pane 0 is not a request pane" },
    };
    try expectArgErrors(lua, &cases);
}

test "mnml.decor.gutter: a script mark sits between a breakpoint and git's bar, and its priority moves it" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const lua = app.script();
    const pane = try app.openScratchWith("alpha\nbeta\n");
    const e = app.panes.editor(pane).?;
    // A breakpoint of the debugger's on the same line as the script's mark.
    const path = try testing.allocator.dupe(u8, "/tmp/bp.zig");
    defer testing.allocator.free(path);
    e.buf.doc.setPath(path) catch unreachable;
    try dap_app.toggleBreakpointAt(&app, path, 0);
    try lua.runString(
        \\local ns = mnml.decor.namespace("marks")
        \\mnml.decor.gutter(ns, mnml.pane.active(), 1, "S", { fg = "accent" })
        \\mnml.decor.gutter(ns, mnml.pane.active(), 2, "S", { fg = "accent" })
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const render_mod = @import("../app/render.zig");
    var marks = try render_mod.gutterMarksFor(&app, arena.allocator(), pane, e, false);
    // Line 0: the breakpoint wins the cell; line 1: the script's does.
    try testing.expectEqualStrings("\u{25CF}", firstSign(marks, 0).?.glyph);
    try testing.expectEqualStrings("S", firstSign(marks, 1).?.glyph);
    // The script asks to outrank the breakpoint and does.
    try lua.runString(
        \\local ns = mnml.decor.namespace("marks")
        \\mnml.decor.clear(ns)
        \\mnml.decor.gutter(ns, mnml.pane.active(), 1, "S", { fg = "accent", priority = 99 })
    );
    marks = try render_mod.gutterMarksFor(&app, arena.allocator(), pane, e, false);
    try testing.expectEqualStrings("S", firstSign(marks, 0).?.glyph);
}

fn firstSign(marks: []const @import("../ui/editor_view.zig").GutterMark, line: u32) ?@import("../ui/editor_view.zig").GutterMark {
    for (marks) |m| if (m.line == line and m.kind == .sign) return m;
    return null;
}

test "mnml.diagnostics: a script's findings reach the gutter, the statusline, the panel and ]d" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 90, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    const lua = app.script();
    const pane = try app.openScratchWith("one\ntwo\nthree\n");
    const e = app.panes.editor(pane).?;
    const path = try testing.allocator.dupe(u8, "/tmp/app.js");
    defer testing.allocator.free(path);
    e.buf.doc.setPath(path) catch unreachable;
    try lua.runString(
        \\ns = mnml.decor.namespace("eslint")
        \\mnml.diagnostics.set(ns, "app.js", {
        \\  { line = 1, col = 1, end_col = 4, severity = "warning", message = "unused", source = "eslint" },
        \\  { line = 3, col = 1, severity = "error", message = "no-undef", source = "eslint" },
        \\})
    );
    const list = lsp_app.diagnosticsFor(&app, path);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("eslint", list[0].source.?);
    // The squiggle and the gutter dot, from the same store a server fills.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uls = try lsp_app.underlinesFor(&app, arena.allocator(), e, &app.theme);
    try testing.expectEqual(@as(usize, 2), uls.len);
    try testing.expectEqual(@as(usize, 0), uls[0].start);
    try testing.expectEqual(@as(usize, 3), uls[0].end);
    const marks = try lsp_app.marksFor(&app, arena.allocator(), path, &app.theme, false);
    try testing.expectEqual(@as(usize, 2), marks.len);
    // The statusline chip counts them, and `]d` walks them.
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "1") != null);
    e.buf.editor.setCursor(0);
    try command.run(&app, .{ .static = .@"lsp.next_diagnostic" });
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "no-undef") != null);
    // The DIAGNOSTICS panel lists them under the script's own source.
    try command.run(&app, .{ .static = .@"lsp.diagnostics" });
    try app.render();
    const panel = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(panel);
    try testing.expect(std.mem.indexOf(u8, panel, "DIAGNOSTICS (2)") != null);
    try testing.expect(std.mem.indexOf(u8, panel, "unused") != null);
    // A second namespace's set does not replace the first's; clearing
    // one leaves the other.
    try lua.runString(
        \\local other = mnml.decor.namespace("mine")
        \\mnml.diagnostics.set(other, "app.js", { { line = 2, message = "mine", source = "mine" } })
    );
    try testing.expectEqual(@as(usize, 3), lsp_app.diagnosticsFor(&app, path).len);
    try lua.runString("mnml.diagnostics.clear(ns, 'app.js')");
    try testing.expectEqual(@as(usize, 1), lsp_app.diagnosticsFor(&app, path).len);
    try testing.expectEqualStrings("mine", lsp_app.diagnosticsFor(&app, path)[0].source.?);
    // The reload takes what is left.
    try lua.reset();
    try testing.expectEqual(@as(usize, 0), lsp_app.diagnosticsFor(&app, path).len);
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "the budget applies to a decoration set in a hot loop" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratchWith("one\ntwo\n");
    try testing.expectError(error.Failed, lua.runString(
        \\local ns = mnml.decor.namespace("hot")
        \\while true do mnml.decor.gutter(ns, mnml.pane.active(), 1, "!") ; mnml.decor.clear(ns) end
    ));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "budget exceeded") != null);
    // And the cap holds when nothing clears them.
    try testing.expectError(error.Failed, lua.runString(
        \\local ns = mnml.decor.namespace("hot")
        \\for _ = 1, 20000 do mnml.decor.gutter(ns, mnml.pane.active(), 1, "!") end
    ));
    try testing.expect(app.script_decor.items.items.len <= script_decor.max_items);
}

test "lua/git-blame-line/init.lua loads, asks git on cursor_idle and paints what comes back" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const lua = app.script();
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, "lua/git-blame-line/init.lua", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src);
    lua.runString(src) catch |err| {
        std.debug.print("example: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    try testing.expectEqual(@as(usize, 1), app.hooks.count(.cursor_idle));
    // A pane with no path (a scratch buffer) asks nothing and errors
    // on nothing.
    _ = try app.openScratchWith("alpha\nbeta\n");
    app.hooks.emit(&app, .{ .cursor_idle = .{ .pane = app.active.?, .line = 1 } });
    try testing.expectEqual(@as(usize, 0), app.script_decor.items.items.len);
    try testing.expect(app.lastToast() == null);
    // Feed the script the shape `git blame --date=relative` prints,
    // through the same `on_line` / `on_done` the task would.
    try lua.runString(
        \\seen = nil
        \\mnml.task.run = function(o)
        \\  seen = o.cmd
        \\  o.on_line("^0d9ac1f (Chris McLennan 3 days ago 1) alpha")
        \\  o.on_done({ ok = true, code = 0 })
        \\  return 1
        \\end
        \\mnml.buf.path = function() return "src/main.zig" end
    );
    app.hooks.emit(&app, .{ .cursor_idle = .{ .pane = app.active.?, .line = 2 } });
    try lua.runString("assert(seen and seen:find('git blame %-L 2,2'), tostring(seen))");
    try testing.expectEqual(@as(usize, 1), app.script_decor.items.items.len);
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "Chris McLennan 3 days ago") != null);
    // The same line again asks nothing more.
    try lua.runString("seen = nil");
    app.hooks.emit(&app, .{ .cursor_idle = .{ .pane = app.active.?, .line = 2 } });
    try lua.runString("assert(seen == nil, 'asked twice for one line')");
}

test "lua/eslint/init.lua loads and turns compact output into diagnostics on save" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, "lua/eslint/init.lua", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src);
    lua.runString(src) catch |err| {
        std.debug.print("example: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    // The task is faked so the test does not need eslint installed;
    // the parsing and the sink are the example's own.
    try lua.runString(
        \\mnml.task.run = function(o)
        \\  cmd = o.cmd
        \\  o.on_line("app.js: line 3, col 5, Warning - 'x' is assigned but never used (no-unused-vars)")
        \\  o.on_line("app.js: line 9, col 1, Error - 'y' is not defined (no-undef)")
        \\  o.on_line("2 problems")
        \\  o.on_done({ ok = false, code = 1 })
        \\end
    );
    // A `.zig` save is not eslint's business.
    app.hooks.emit(&app, .{ .save_post = .{ .path = "main.zig", .pane = 0, .bytes = 4 } });
    try lua.runString("assert(cmd == nil)");
    app.hooks.emit(&app, .{ .save_post = .{ .path = "app.js", .pane = 0, .bytes = 4 } });
    try lua.runString("assert(cmd:find('eslint'), tostring(cmd))");
    const list = lsp_app.diagnosticsFor(&app, "/tmp/app.js");
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(types.Severity.warning, list[0].severity);
    try testing.expectEqual(@as(u32, 2), list[0].range.start.line);
    try testing.expectEqual(@as(u32, 4), list[0].range.start.character);
    try testing.expectEqualStrings("eslint", list[0].source.?);
    try testing.expect(std.mem.indexOf(u8, list[0].message, "no-unused-vars") != null);
    try testing.expectEqual(types.Severity.err, list[1].severity);
    // A clean run replaces the list with nothing.
    try lua.runString(
        \\mnml.task.run = function(o) o.on_done({ ok = true, code = 0 }) end
    );
    app.hooks.emit(&app, .{ .save_post = .{ .path = "app.js", .pane = 0, .bytes = 4 } });
    try testing.expectEqual(@as(usize, 0), lsp_app.diagnosticsFor(&app, "/tmp/app.js").len);
}

test "docs/examples/init.lua loads and its surfaces are all there" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/examples/init.lua", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src);
    const lua = app.script();
    lua.runString(src) catch |err| {
        std.debug.print("example: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    try testing.expect(app.dyn_commands.get("user.hello") != null);
    try testing.expect(app.dyn_commands.get("user.notes") != null);
    try testing.expect(app.dyn_commands.get("user.notes_count") != null);
    try testing.expectEqual(@as(usize, 1), lua.segments.items.len);
    try testing.expect(lua.findSource("notes") != null);
    // Every surface this file is the reference for, present after one
    // load: the commands, the operator, the list and its rail section,
    // the two namespaces, and the hidden-task / diagnostics pair.
    try testing.expect(app.dyn_commands.get("user.notes_lint") != null);
    try testing.expect(app.dyn_commands.get("user.notes_mark") != null);
    try testing.expect(app.dyn_commands.get("user.notes_debug") != null);
    try testing.expect(app.dyn_commands.get("user.note_it") != null);
    try testing.expectEqual(@as(usize, 1), lua.operators.items.len);
    const sum = lua.summary();
    try testing.expectEqual(@as(u32, 1), sum.operators);
    try testing.expect(sum.lists >= 1);
    try testing.expect(app.script_sections.items.items.len >= 1);
    try command.runNamed(&app, "user.hello");
    try testing.expectEqualStrings("hello from init.lua", app.lastToast().?);
    // The pane opens, renders the notes, and `x` (on_key) removes one.
    try command.runNamed(&app, "user.notes");
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "write the manual") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "cut a release") != null);
    try app.handle(.{ .key = Key.char('x') });
    try lua.runString("assert(#notes == 1)");
    // The picker source lists the notes; Enter runs on_accept.
    try lua.runString("mnml.picker.open('notes')");
    try testing.expect(app.overlay == .picker);
    try testing.expectEqual(app_mod.PickerKind.lua, app.overlay.picker.kind);
    try testing.expectEqual(@as(usize, 1), app.overlay.picker.labels.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("picked write the manual", app.lastToast().?);
    try testing.expectEqual(@as(usize, 0), lua.picker_items.items.len);
    // The segment polls on tick.
    try app.tick(app.now_ms + 1000);
    const segs = try lua.segmentTexts(app.frame.allocator(), .right);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("notes 1", segs[0]);
    // The decorations: four in one namespace, over an editor pane.
    _ = try app.openScratchWith("alpha beta\ngamma\n");
    try command.runNamed(&app, "user.notes_mark");
    try testing.expectEqual(@as(usize, 4), app.script_decor.items.items.len);
    // `mnml.inspect` through `print`: a deterministic line, so the
    // reference file's own debugging command is worth pinning.
    try command.runNamed(&app, "user.notes_debug");
    try testing.expect(std.mem.startsWith(u8, app.lastToast().?, "{ notes = 1,"));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "workspace = \"/tmp\"") != null);
    // The operator, from the standard road: the word under the cursor
    // joins the notes.
    const e = app.activeEditor().?;
    e.buf.editor.setCursor(0);
    try command.runNamed(&app, "user.note_it");
    try lua.runString("assert(notes[#notes] == 'alpha', notes[#notes])");
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.buf.selection / range / word_at: the three modes, a clamped range, the word under a byte, and the argument errors" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratch();
    lua.runString(
        \\mnml.buf.apply{ op = "insert_str", text = "alpha beta\ngamma delta" }
        \\assert(mnml.buf.selection() == nil, "nothing is selected yet")
        \\mnml.buf.apply{ op = "select_range", start = 6, ["end"] = 10 }
        \\local s = mnml.buf.selection()
        \\assert(s.start == 6 and s["end"] == 10 and s.mode == "char", s.mode)
        \\assert(mnml.buf.range(s.start, s["end"]) == "beta")
        \\assert(mnml.buf.range(10, 6) == "beta", "a reversed pair reads the same span")
        \\assert(mnml.buf.range(0, 9999) == mnml.buf.text(), "both ends clamp")
        \\local w = mnml.buf.word_at(1)
        \\assert(w.text == "alpha" and w.start == 0 and w["end"] == 5, w.text)
        \\assert(mnml.buf.word_at(11).text == "gamma")
        \\assert(mnml.buf.word_at(5) == nil, "the space between two words is in neither")
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    // Without a byte: the cursor's word.
    _ = try app.applyOps(app.activeEditor().?, &.{.{ .set_cursor_byte = 12 }});
    try lua.runString("assert(mnml.buf.word_at().text == \"gamma\")");
    // The shape follows the handler's mode — the one handler-derived
    // fact a script sees.
    try app.setInputStyle(.vim);
    const e = app.activeEditor().?;
    try testing.expectEqualStrings("char", selectionMode(e));
    try app.handle(.{ .key = .{ .code = .{ .char = 'V' } } });
    try testing.expectEqualStrings("line", selectionMode(e));
    try lua.runString("assert(mnml.buf.selection().mode == \"line\")");
    try app.handle(.{ .key = .{ .code = .esc } });
    try app.handle(.{ .key = .{ .code = .{ .char = 'v' }, .mods = .{ .ctrl = true } } });
    try testing.expectEqualStrings("block", selectionMode(e));
    // Arguments are checked before anything is allocated.
    try testing.expectError(error.Failed, lua.runString("mnml.buf.range(-1, 4)"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "byte offset") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.buf.range('a', 4)"));
    try testing.expectError(error.Failed, lua.runString("mnml.buf.word_at('x')"));
    try testing.expectError(error.Failed, lua.runString("mnml.buf.selection(9999)"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "editor") != null);
}

test "mnml.operator: vim's g<letter> takes a motion, a text object and a visual selection; standard's chord takes the selection or the cursor's word; one undo step either way" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratch();
    lua.runString(
        \\ranges = {}
        \\local id = mnml.operator{ id = "surround", keys = { vim = "gs", standard = "ctrl+shift+s" },
        \\  run = function(r)
        \\    ranges[#ranges + 1] = r.start .. ":" .. r["end"] .. ":" .. r.mode
        \\    local text = mnml.buf.range(r.start, r["end"])
        \\    mnml.buf.apply{ op = "replace_range", start = r.start, ["end"] = r["end"], text = "(" .. text .. ")" }
        \\  end }
        \\assert(id == "user.surround", id)
        \\mnml.buf.apply{ op = "insert_str", text = "alpha beta\ngamma" }
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    const e = app.activeEditor().?;
    // ── vim: a motion (`gsw`), then a text object (`gsiw`) ──
    try app.setInputStyle(.vim);
    _ = try app.applyOps(e, &.{.{ .set_cursor_byte = 0 }});
    for ("gsw") |ch| try app.handle(.{ .key = .{ .code = .{ .char = ch } } });
    try testing.expectEqualStrings("(alpha )beta\ngamma", e.buf.editor.bytes());
    // One undo step: the whole operator goes in one `u`.
    _ = try app.applyOps(e, &.{.undo});
    try testing.expectEqualStrings("alpha beta\ngamma", e.buf.editor.bytes());
    _ = try app.applyOps(e, &.{.{ .set_cursor_byte = 7 }});
    for ("gsiw") |ch| try app.handle(.{ .key = .{ .code = .{ .char = ch } } });
    try testing.expectEqualStrings("alpha (beta)\ngamma", e.buf.editor.bytes());
    try testing.expect(e.buf.editor.selection() == null); // the operator clears it
    _ = try app.applyOps(e, &.{.undo});
    // ── vim: a visual selection (`V gs`) ──
    _ = try app.applyOps(e, &.{.{ .set_cursor_byte = 12 }});
    try app.handle(.{ .key = .{ .code = .{ .char = 'V' } } });
    for ("gs") |ch| try app.handle(.{ .key = .{ .code = .{ .char = ch } } });
    try testing.expectEqualStrings("alpha beta\n(gamma)", e.buf.editor.bytes());
    _ = try app.applyOps(e, &.{.undo});
    // ── standard: the chord over a selection, then over a bare cursor ──
    try app.setInputStyle(.standard);
    _ = try app.applyOps(e, &.{ .{ .set_cursor_byte = 0 }, .select_start, .{ .set_cursor_byte = 5 } });
    try command.runNamed(&app, "user.surround");
    try testing.expectEqualStrings("(alpha) beta\ngamma", e.buf.editor.bytes());
    _ = try app.applyOps(e, &.{ .undo, .select_clear, .{ .set_cursor_byte = 7 } });
    try app.handle(.{ .key = .{ .code = .{ .char = 's' }, .mods = .{ .ctrl = true, .shift = true } } });
    try testing.expectEqualStrings("alpha (beta)\ngamma", e.buf.editor.bytes());
    // The cursor in a run of whitespace is in no word: nothing happens.
    _ = try app.applyOps(e, &.{ .undo, .select_clear, .{ .set_cursor_byte = 5 } });
    try command.runNamed(&app, "user.surround");
    try testing.expectEqualStrings("alpha beta\ngamma", e.buf.editor.bytes());
    // Every road handed the same shape of range.
    try lua.runString("assert(#ranges == 5, #ranges) assert(ranges[2] == '6:10:char', ranges[2]) assert(ranges[3] == '11:16:line', ranges[3])");
    // A reload drops the claim: `gs` is an unclaimed `g` letter again.
    try testing.expectEqual(@as(usize, 1), script_ops.count());
    try lua.reset();
    try testing.expectEqual(@as(usize, 0), script_ops.count());
    try testing.expect(app.dyn_commands.get("user.surround") == null);
}

test "mnml.operator: the argument errors name the shape, and land before anything is registered" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    try testing.expectError(error.Failed, lua.runString("mnml.operator{ id = 'a' }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "`keys` must be a table") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.operator{ id = 'a', keys = {}, run = function() end }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "needs a `vim` chord") != null);
    // A `g` chord vim already uses is refused by name, not left dead.
    try testing.expectError(error.Failed, lua.runString("mnml.operator{ id = 'a', keys = { vim = 'gd' }, run = function() end }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "one letter vim does not already use") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.operator{ id = 'a', keys = { vim = 'zs' }, run = function() end }"));
    try testing.expectError(error.Failed, lua.runString("mnml.operator{ id = 'a.b', keys = { vim = 'gs' }, run = function() end }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "bare name") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.operator{ id = 'a', keys = { vim = 'gs' } }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "`run` must be a function(range)") != null);
    // Nothing above registered anything.
    try testing.expectEqual(@as(usize, 0), script_ops.count());
    try testing.expectEqual(@as(usize, 0), lua.operators.items.len);
    try testing.expect(app.dyn_commands.get("user.a") == null);
    // Registering the same id again replaces the runner and keeps one slot.
    try lua.runString("mnml.operator{ id = 'a', keys = { vim = 'gs' }, run = function() end }");
    try lua.runString("mnml.operator{ id = 'a', keys = { vim = 'gs' }, run = function() end }");
    try testing.expectEqual(@as(usize, 1), lua.operators.items.len);
    try testing.expectEqual(@as(usize, 1), script_ops.count());
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "mnml.picker.source: a live source is asked again as the query changes, debounced, and the old rows stay until the new ones land" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 20 });
    defer app.deinit();
    const lua = app.script();
    lua.runString(
        \\calls = {}
        \\mnml.picker.source{ id = "live", title = "Live", live = true,
        \\  items = function(query)
        \\    calls[#calls + 1] = query
        \\    if query == "" then return { "alpha", "beta" } end
        \\    return { { label = "for " .. query, detail = "d" } }
        \\  end }
        \\mnml.picker.open("live")
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    try testing.expect(app.overlay == .picker);
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    // Typing does not ask again on the spot: the rows on screen are the
    // ones the last call answered with.
    app.now_ms = 1000;
    try app.handle(.{ .key = .{ .code = .{ .char = 'x' } } });
    try lua.runString("assert(#calls == 1, #calls)");
    try testing.expectEqualStrings("alpha", app.overlay.picker.labels[0]);
    // The window is 80 ms — written out, not read from the constant the
    // code under test uses, so a change to it fails here.
    try testing.expectEqual(@as(i64, 80), lua_mod.live_debounce_ms);
    // Before the debounce is up, nothing.
    try app.tick(1079);
    try lua.runString("assert(#calls == 1, #calls)");
    // After it, one call carrying the whole query.
    try app.tick(1080);
    try lua.runString("assert(#calls == 2, #calls) assert(calls[2] == 'x', calls[2])");
    try testing.expectEqual(@as(usize, 1), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("for x", app.overlay.picker.labels[0]);
    try testing.expectEqualStrings("x", app.overlay.picker.state.queryText());
    // Two keys inside the window are one call, not two.
    app.now_ms = 2000;
    try app.handle(.{ .key = .{ .code = .{ .char = 'y' } } });
    app.now_ms = 2040;
    try app.handle(.{ .key = .{ .code = .{ .char = 'z' } } });
    try app.tick(2119);
    try lua.runString("assert(#calls == 2, #calls)");
    try app.tick(2120);
    try lua.runString("assert(#calls == 3, #calls) assert(calls[3] == 'xyz', calls[3])");
    // A source without `live` is asked exactly once.
    try lua.runString(
        \\once = 0
        \\mnml.picker.source{ id = "still", items = function() once = once + 1; return { "a", "b" } end }
        \\mnml.picker.open("still")
    );
    app.now_ms = 5000;
    try app.handle(.{ .key = .{ .code = .{ .char = 'a' } } });
    try app.tick(6000);
    try lua.runString("assert(once == 1, once)");
}

test "mnml.picker.source: the preview column follows the cursor, multi-select hands on_accept the marked rows, and data comes back untouched" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 120, .rows = 24 });
    defer app.deinit();
    const lua = app.script();
    lua.runString(
        \\picked = nil
        \\previewed = {}
        \\mnml.picker.source{ id = "cmds", title = "Commands", multi = true,
        \\  items = function()
        \\    return { { label = "one", detail = "1", icon = "*", data = { n = 1 } },
        \\             { label = "two", detail = "2", data = { n = 2 } },
        \\             { label = "three", detail = "3", data = { n = 3 } } }
        \\  end,
        \\  preview = function(row)
        \\    previewed[#previewed + 1] = row.label
        \\    return { { { text = row.label, fg = "accent" } }, "n = " .. row.data.n }
        \\  end,
        \\  on_accept = function(rows)
        \\    local out = {}
        \\    for _, r in ipairs(rows) do out[#out + 1] = r.data.n end
        \\    picked = table.concat(out, ",")
        \\  end }
        \\mnml.picker.open("cmds")
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    try testing.expect(app.overlay.picker.state.has_preview);
    try testing.expect(app.overlay.picker.state.multi);
    try testing.expectEqualStrings("*", app.overlay.picker.icons[0]);
    // The first row's preview is there before a key is pressed.
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.preview.len);
    try testing.expectEqualStrings("one", app.overlay.picker.preview[0][0].text);
    try testing.expectEqualStrings("n = 1", app.overlay.picker.preview[1][0].text);
    {
        const screen_mod = @import("../ipc/screen.zig");
        try app.render();
        const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
        defer testing.allocator.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "n = 1") != null);
    }
    // ↓ moves the cursor and the preview follows it.
    try app.handle(.{ .key = .{ .code = .down } });
    try lua.runString("assert(previewed[#previewed] == 'two', previewed[#previewed])");
    try testing.expectEqualStrings("n = 2", app.overlay.picker.preview[1][0].text);
    // Tab marks the row and steps on; Enter hands over every marked row.
    try app.handle(.{ .key = .{ .code = .tab } });
    try testing.expect(app.overlay.picker.marked[1]);
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.state.cursor);
    try app.handle(.{ .key = .{ .code = .tab } });
    {
        const screen_mod = @import("../ipc/screen.zig");
        try app.render();
        const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
        defer testing.allocator.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "\u{2713}two") != null);
    }
    try app.handle(.{ .key = .{ .code = .enter } });
    try lua.runString("assert(picked == '2,3', tostring(picked))");
    try testing.expect(app.overlay == .none);
    // With nothing marked, Enter hands over the row under the cursor.
    try lua.runString("picked = nil mnml.picker.open('cmds')");
    try app.handle(.{ .key = .{ .code = .enter } });
    try lua.runString("assert(picked == '1', tostring(picked))");
}

test "mnml.picker.source: the argument errors name the shape and land before anything is registered" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    try testing.expectError(error.Failed, lua.runString("mnml.picker.source{ id = 'x', items = function() end, preview = 3 }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "`preview` must be a function(row)") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.picker.source{ id = 'x', items = function() end, on_accept = 'no' }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "`on_accept` must be a function(row)") != null);
    try testing.expectError(error.Failed, lua.runString("mnml.picker.source{ id = 'x' }"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "`items` must be a function(query)") != null);
    try testing.expectEqual(@as(usize, 0), lua.sources.items.len);
    try testing.expectError(error.Failed, lua.runString("mnml.picker.open('nope')"));
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}
