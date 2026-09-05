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

/// The prefix every script command gets: `mnml.command{ id = "hello" }`
/// is `user.hello` in the palette, `.keys`, `.test` and IPC.
pub const id_prefix = "user.";

/// Build the `mnml` table and set it as a global.
pub fn install(self: *Lua) void {
    const L = self.L;
    L.newTable();
    put(L, "command", cmdRegister);
    put(L, "map", map);
    put(L, "on", on);
    put(L, "toast", toast);
    put(L, "run", run);
    put(L, "ex", ex);
    put(L, "workspace", workspace);
    put(L, "data_root", dataRoot);
    put(L, "redraw", redraw);

    L.newTable();
    put(L, "text", bufText);
    put(L, "line", bufLine);
    put(L, "line_count", bufLineCount);
    put(L, "cursor", bufCursor);
    put(L, "path", bufPath);
    put(L, "apply", bufApply);
    L.setField(-2, "buf");

    L.newTable();
    put(L, "segment", statuslineSegment);
    L.setField(-2, "statusline");

    L.newTable();
    put(L, "source", pickerSource);
    put(L, "open", pickerOpen);
    L.setField(-2, "picker");

    L.newTable();
    put(L, "open", paneOpen);
    put(L, "close", paneClose);
    put(L, "active", paneActive);
    L.setField(-2, "pane");

    L.newTable();
    put(L, "run", taskRun);
    L.setField(-2, "task");

    L.newTable();
    put(L, "get", configGet);
    L.setField(-2, "config");

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

/// A required string field, else a Lua error naming it.
fn needStr(L: *State, t: i32, name: [:0]const u8) []const u8 {
    return strField(L, t, name) orelse L.raiseErrorStr("mnml: `%s` is required and must be a string", .{name.ptr});
}

fn needFn(self: *Lua, t: i32, name: [:0]const u8) LuaRef {
    return fnField(self, t, name) orelse self.L.raiseErrorStr("mnml: `%s` is required and must be a function", .{name.ptr});
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
        const id = L.checkInteger(arg);
        if (id < 0 or id > std.math.maxInt(PaneId)) L.argError(arg, "pane id out of range");
        return app.panes.editor(@intCast(id)) orelse L.raiseErrorStr("mnml.buf: pane %d is not an editor", .{@as(c_int, @intCast(id))});
    }
    return app.activeEditor() orelse L.raiseErrorStr("mnml.buf: no active editor pane", .{});
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
        .owner = .script,
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
    L.checkType(1, .table);
    const arena = c.app.frame.allocator();
    const id = needStr(L, 1, "id");
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t\n.") != null) L.raiseErrorStr("mnml.command: id must be a bare name (no spaces or dots)", .{});
    const full = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ id_prefix, id }, 0);
    const title = try arena.dupe(u8, strField(L, 1, "title") orelse id);
    const group = try arena.dupe(u8, strField(L, 1, "group") orelse "user");
    const keys = try keysField(L, arena, 1);
    const run_ref = needFn(c.self, 1, "run");
    _ = registerLuaCommand(c.self, full, title, group, keys, run_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => L.raiseErrorStr("mnml.command: `%s` shadows a built-in command", .{full.ptr}),
    };
    _ = L.pushString(full);
    return 1;
}

/// `mnml.map(spec, fn)` → an anonymous command bound to `spec`.
fn map(L: *State) !i32 {
    const c = ctx(L);
    const spec = L.checkString(1);
    L.checkType(2, .function);
    const arena = c.app.frame.allocator();
    c.self.map_seq += 1;
    const full = try std.fmt.allocPrint(arena, "{s}map_{d}", .{ id_prefix, c.self.map_seq });
    L.pushValue(2);
    const run_ref = c.self.ref();
    const keys = [_][]const u8{spec};
    _ = registerLuaCommand(c.self, full, spec, "user", &keys, run_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShadowsBuiltin => unreachable, // `user.map_N` is never a built-in
    };
    _ = L.pushString(full);
    return 1;
}

/// `mnml.on(hook, fn)`.
fn on(L: *State) !i32 {
    const c = ctx(L);
    const name = L.checkString(1);
    L.checkType(2, .function);
    const hook = std.meta.stringToEnum(hooks.Hook, name) orelse L.argError(1, "unknown hook (see docs/LUA.md for the list)");
    L.pushValue(2);
    const r = c.self.ref();
    c.app.hooks.subscribe(hook, .{ .lua = r }) catch |err| {
        c.self.unref(r);
        return err;
    };
    return 0;
}

/// `mnml.toast(text, level?)` — level `info` (default) | `warn` | `error`.
fn toast(L: *State) !i32 {
    const c = ctx(L);
    const text = L.checkString(1);
    const level: app_mod.ToastLevel = if (L.optString(2)) |lv|
        (if (std.mem.eql(u8, lv, "warn")) .warn else if (std.mem.eql(u8, lv, "error")) .err else .info)
    else
        .info;
    try c.app.toastLevel(level, "{s}", .{text});
    return 0;
}

/// `mnml.run(id)` → true when the command succeeded. A failure was
/// toasted by `command.run`; the message is the second return.
fn run(L: *State) !i32 {
    const c = ctx(L);
    const id = L.checkString(1);
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
    const line = L.checkString(1);
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
    const n = L.checkInteger(1);
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

/// `mnml.buf.path(pane?)` → the workspace-relative path, nil for scratch.
fn bufPath(L: *State) !i32 {
    const c = ctx(L);
    const e = editorArg(L, c.app, 1);
    if (e.buf.path) |p| _ = L.pushString(c.app.relPath(p)) else L.pushNil();
    return 1;
}

/// `mnml.buf.apply({ op = "…", … }, pane?)` → whether the text changed.
fn bufApply(L: *State) !i32 {
    const c = ctx(L);
    L.checkType(1, .table);
    const e = editorArg(L, c.app, 2);
    const arena = c.app.frame.allocator();
    const op = try decodeOp(L, arena, 1);
    const changed = try c.app.applyOps(e, &.{op});
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
    const name = strField(L, at, "op") orelse L.raiseErrorStr("mnml.buf.apply: `op` is required", .{});
    if (std.mem.eql(u8, name, "select_range")) {
        const start = intField(L, at, "start") orelse L.raiseErrorStr("mnml.buf.apply: select_range needs start and end", .{});
        const end = intField(L, at, "end") orelse L.raiseErrorStr("mnml.buf.apply: select_range needs start and end", .{});
        const ops = try arena.alloc(EditOp, 3);
        ops[0] = .{ .set_cursor_byte = @intCast(@max(start, 0)) };
        ops[1] = .select_start;
        ops[2] = .{ .set_cursor_byte = @intCast(@max(end, 0)) };
        return .{ .atomic = ops };
    }
    if (std.mem.eql(u8, name, "atomic")) {
        _ = L.getField(at, "ops");
        defer L.pop(1);
        if (!L.isTable(-1)) L.raiseErrorStr("mnml.buf.apply: atomic needs `ops`, a list of op tables", .{});
        const n = L.lenRaw(-1);
        const ops = try arena.alloc(EditOp, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = L.getIndex(-1, @intCast(i + 1));
            defer L.pop(1);
            if (!L.isTable(-1)) L.raiseErrorStr("mnml.buf.apply: atomic ops must be tables", .{});
            ops[i] = try decodeOp(L, arena, -1);
        }
        return .{ .atomic = ops };
    }
    if (std.mem.eql(u8, name, "repeat")) {
        const count = intField(L, at, "count") orelse 1;
        _ = L.getField(at, "inner");
        defer L.pop(1);
        if (!L.isTable(-1)) L.raiseErrorStr("mnml.buf.apply: repeat needs `inner`, an op table", .{});
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
    L.raiseErrorStr("mnml.buf.apply: unknown op `%s`", .{(try arena.dupeZ(u8, name)).ptr});
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
                L.raiseErrorStr("mnml.buf.apply: `%s` needs an integer `value`", .{tag.ptr});
            return std.math.cast(T, v) orelse L.raiseErrorStr("mnml.buf.apply: `%s`: value out of range", .{tag.ptr});
        },
        .optional => |o| {
            if (o.child == u21) return charField(L, at, "ch");
            @compileError("unhandled optional payload for " ++ tag);
        },
        .pointer => |p| {
            if (p.child == u8) return try arena.dupe(u8, strField(L, at, "text") orelse L.raiseErrorStr("mnml.buf.apply: `%s` needs `text`", .{tag.ptr}));
            @compileError("unhandled pointer payload for " ++ tag);
        },
        .@"enum" => {
            const s = strField(L, at, "value") orelse strField(L, at, "case") orelse L.raiseErrorStr("mnml.buf.apply: `%s` needs `value`", .{tag.ptr});
            return std.meta.stringToEnum(T, s) orelse L.raiseErrorStr("mnml.buf.apply: `%s`: unknown value", .{tag.ptr});
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
                @field(out, sf.name) = got orelse (if (sf.defaultValue()) |d| d else L.raiseErrorStr("mnml.buf.apply: `%s` needs `%s`", .{ tag.ptr, fname.ptr }));
            }
            return out;
        },
        else => {
            // `u21` is an int; the char tags are read as `ch`.
            @compileError("unhandled payload for " ++ tag);
        },
    }
}

// ─── mnml.statusline ────────────────────────────────────────────────────

/// `mnml.statusline.segment{ id, side?, fn }` — `fn()` returns the text
/// (nil hides it), polled every 250 ms.
fn statuslineSegment(L: *State) !i32 {
    const c = ctx(L);
    L.checkType(1, .table);
    const id = needStr(L, 1, "id");
    const side: lua_mod.Side = if (strField(L, 1, "side")) |s| (std.meta.stringToEnum(lua_mod.Side, s) orelse L.raiseErrorStr("mnml.statusline.segment: side is `left` or `right`", .{})) else .right;
    const func = needFn(c.self, 1, "fn");
    const gpa = c.self.gpa;
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

/// `mnml.picker.source{ id, title?, items = fn(query) }`.
fn pickerSource(L: *State) !i32 {
    const c = ctx(L);
    L.checkType(1, .table);
    const id = needStr(L, 1, "id");
    const title = strField(L, 1, "title") orelse id;
    const items = needFn(c.self, 1, "items");
    const gpa = c.self.gpa;
    if (c.self.findSource(id)) |src| {
        c.self.unref(src.items);
        src.items = items;
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
    c.self.sources.append(gpa, .{ .id = owned_id, .title = owned_title, .items = items }) catch |err| {
        c.self.unref(items);
        return err;
    };
    return 0;
}

/// `mnml.picker.open(id, query?)` — the picker over `items(query)`.
fn pickerOpen(L: *State) !i32 {
    const c = ctx(L);
    const id = L.checkString(1);
    const query = L.optString(2) orelse "";
    const src = c.self.findSource(id) orelse L.raiseErrorStr("mnml.picker.open: no source `%s`", .{id.ptr});
    const gpa = c.self.gpa;
    var labels: std.ArrayList([]u8) = .empty;
    var details: std.ArrayList([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    try c.self.callItems(src.items, query, &labels, &details);
    // The overlay owns the four slices from the call on, whatever the
    // call returns; the errdefers only cover the allocations before it.
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
    const panes = try gpa.alloc(PaneId, 0);
    errdefer if (!handed) gpa.free(panes);
    const hints = try gpa.alloc([]u8, 0);
    errdefer if (!handed) gpa.free(hints);
    handed = true;
    cmd_picker.openPickerWith(c.app, src.title, .lua, owned_labels, panes, owned_details, hints) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => L.raiseErrorStr("mnml.picker.open: %s", .{@errorName(err).ptr}),
    };
    return 0;
}

// ─── mnml.pane ──────────────────────────────────────────────────────────

/// `mnml.pane.open{ title, render, on_hit?, on_key? }` → the pane id.
fn paneOpen(L: *State) !i32 {
    const c = ctx(L);
    L.checkType(1, .table);
    const title = strField(L, 1, "title") orelse "script";
    const render = needFn(c.self, 1, "render");
    errdefer c.self.unref(render);
    const on_hit = fnField(c.self, 1, "on_hit");
    errdefer if (on_hit) |r| c.self.unref(r);
    const on_key = fnField(c.self, 1, "on_key");
    errdefer if (on_key) |r| c.self.unref(r);
    const id = try script_pane.open(c.app, c.self, title, render, on_hit, on_key);
    L.pushInteger(id);
    return 1;
}

fn paneClose(L: *State) !i32 {
    const c = ctx(L);
    const id = L.checkInteger(1);
    if (id < 0 or id > std.math.maxInt(PaneId)) L.argError(1, "pane id out of range");
    try c.app.forceClosePane(@intCast(id));
    return 0;
}

fn paneActive(L: *State) !i32 {
    const c = ctx(L);
    if (c.app.active) |id| L.pushInteger(id) else L.pushNil();
    return 1;
}

// ─── mnml.task ──────────────────────────────────────────────────────────

/// `mnml.task.run{ cmd, cwd?, label?, on_done? }` → the pane id. The
/// command runs in a task pane below; `on_done{ ok, code | signal }`
/// fires when it exits.
fn taskRun(L: *State) !i32 {
    const c = ctx(L);
    L.checkType(1, .table);
    const app = c.app;
    const arena = app.frame.allocator();
    const cmd = try arena.dupe(u8, needStr(L, 1, "cmd"));
    const label = try arena.dupe(u8, strField(L, 1, "label") orelse cmd);
    const cwd: []const u8 = if (strField(L, 1, "cwd")) |d| (if (std.fs.path.isAbsolute(d)) try arena.dupe(u8, d) else try std.fs.path.join(arena, &.{ app.workspace, d })) else app.workspace;
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

// ─── mnml.config ────────────────────────────────────────────────────────

/// `mnml.config.get(path?)` — a read-only copy of the merged config
/// under the dotted `path` (`"editor.tab_width"`, `"lsp.rust.cmd"`,
/// `"keys.global"`); nil when nothing is there. Without a path, the
/// whole config as nested tables.
fn configGet(L: *State) !i32 {
    const c = ctx(L);
    const path = L.optString(1) orelse "";
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

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Key = app_mod.Key;
const keymap = @import("../core/keymap.zig");

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
