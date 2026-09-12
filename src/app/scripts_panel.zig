//! The SCRIPTS section: what the scripts registered — every Lua
//! command, hook subscriber, statusline segment and picker source —
//! with the `file:line` of the `mnml.*` call that made it (`Lua.origins`,
//! captured off the Lua stack at registration). Enter or a second click
//! jumps there; the header's refresh chip is `script.reload`; when the
//! workspace has no `init.lua` a link row creates one from the
//! commented template. A rail section like the rest: a `ListPanel` in
//! its column, on the left by default, moved like any other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Key = @import("../core/key.zig").Key;
const Mouse = @import("../core/key.zig").Mouse;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const fuzzy = @import("../ui/fuzzy.zig");
const view = @import("../ui/scripts_panel.zig");
const lua_mod = @import("../scripting/lua.zig");
const auto_refresh = @import("auto_refresh.zig");
const activity_bar = @import("activity_bar.zig");
const side = @import("side.zig");
const context_menus = @import("context_menus.zig");
const watch = @import("watch.zig");
const keymap = @import("../core/keymap.zig");
const Chord = @import("../core/key.zig").Chord;
const MenuItem = command.MenuItem;

pub const Row = view.Row;
pub const Panel = list_panel.ListPanel(Row);

pub const State = struct {
    panel: Panel.State = .{},

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.panel.deinit(gpa);
    }
};

pub const table = .{
    .@"view.activity_scripts" = &activity,
    .@"script.new_init" = &newInit,
};

/// The link row's words.
pub const link_label = "+ create init.lua";

/// What `script.new_init` writes: every surface, commented out, so the
/// file reads as its own reference and runs clean as it is.
pub const template =
    \\-- init.lua — mnml's script for this workspace. Runs once the
    \\-- workspace is trusted, and again on every save. Everything goes
    \\-- through the `mnml` table (docs/LUA.md); type `mnml.` for the list.
    \\
    \\-- A command: `user.hello` in the palette, `:user.hello`, and the chord.
    \\-- mnml.command{ id = "hello", title = "Say hello", keys = { "ctrl+shift+h" },
    \\--   run = function() mnml.toast("hello from init.lua") end }
    \\
    \\-- A chord bound to a built-in command.
    \\-- mnml.map("ctrl+shift+s", "file.save")
    \\
    \\-- A hook: the payload is a flat table of the hook's fields.
    \\-- mnml.on("save_post", function(a) mnml.toast(a.path .. " saved") end)
    \\
    \\-- A statusline segment, polled every 250 ms; nil hides it.
    \\-- mnml.statusline.segment{ id = "clock", fn = function() return "hi" end }
    \\
;

fn activity(app: *App) CommandError!void {
    activity_bar.enter(app, .scripts);
    side.place(app, .scripts, true);
}

/// The workspace's `init.lua`, absolute, on the frame arena.
fn workspaceInit(app: *App) Allocator.Error![]const u8 {
    return std.fs.path.join(app.frame.allocator(), &.{ app.workspace, ".mnml", lua_mod.init_file });
}

fn exists(app: *App, path: []const u8) bool {
    return if (Io.Dir.cwd().statFile(app.io, path, .{})) |_| true else |_| false;
}

/// `script.new_init`: the workspace `init.lua` from the template (a
/// file already there is left as it is), opened in an editor.
fn newInit(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const path = try workspaceInit(app);
    if (!exists(app, path)) {
        const dir = std.fs.path.dirname(path) orelse app.workspace;
        Io.Dir.cwd().createDirPath(app.io, dir) catch |err| return app.diag.fail(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = template }) catch |err| return app.diag.fail(arena, "cannot write {s}: {s}", .{ app.relPath(path), @errorName(err) });
        app.toast("created {s}", .{app.relPath(path)});
    }
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "cannot open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
    };
    app.showPane(id);
    app.needs_render = true;
}

/// The rows: the link when the workspace file is missing, then every
/// origin, in registration order, through the filter. Frame arena.
pub fn rows(app: *App, arena: Allocator) Allocator.Error![]Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    const q = app.scripts_panel.panel.filterText();
    if (q.len == 0 and !exists(app, try workspaceInit(app))) try out.append(arena, .{ .name = link_label, .link = true });
    for (app.script().origins.items) |o| {
        const rel = app.relPath(o.file);
        const loc: []const u8 = if (o.file.len == 0) "" else if (o.line > 0) try std.fmt.allocPrint(arena, "{s}:{d}", .{ rel, o.line }) else rel;
        if (q.len > 0 and fuzzy.score(q, o.name) == null and fuzzy.score(q, loc) == null) continue;
        try out.append(arena, .{ .kind = o.kind, .name = o.name, .loc = loc, .file = o.file, .line = o.line });
    }
    return out.items;
}

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.scripts_panel;
    const list = try rows(app, ui.arena);
    const total = app.script().origins.items.len;
    var shown: usize = 0;
    for (list) |r| if (!r.link) {
        shown += 1;
    };
    const subtitle = if (shown == total) ui.fmt(" ({d})", .{total}) else ui.fmt(" ({d} of {d})", .{ shown, total });
    const empty: list_panel.EmptyState = if (total == 0)
        .{ .message = "Nothing registered yet.", .hint = "init.lua registers commands, hooks, segments and picker sources." }
    else
        .{ .message = "No matches — Esc clears" };
    const caret = Panel.draw(&st.panel, ui, area, .{
        .panel = .scripts,
        .label = "SCRIPTS",
        .subtitle = subtitle,
        .rows = list,
        .paintRow = view.paintRow,
        .empty = empty,
        .show_refresh = true,
        .filter_gap = true,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

/// Enter / a second click: the link creates the file; a row opens its
/// file at its line.
fn openRow(app: *App, row: Row) Allocator.Error!void {
    if (row.link) return runToast(app, newInit(app));
    if (row.file.len == 0) {
        app.toast("{s}: registered from the `:lua` line, not a file", .{row.name});
        return;
    }
    const path = try app.frame.allocator().dupe(u8, row.file);
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("cannot open {s}: {s}", .{ app.relPath(path), @errorName(err) });
            return;
        },
    };
    if (app.panes.editor(id)) |e| {
        e.buf.editor.anchor = null;
        e.buf.editor.placeCursor(@min(row.line -| 1, e.buf.editor.lineCount() -| 1), 0);
        e.view.scroll_line = @intCast(e.buf.editor.currentLine() -| app.pane_rows / 2);
    }
    app.showPane(id);
    app.focus = .{ .pane = id };
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("scripts: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

/// Keys while the panel has focus: the list's own, then `r` reloads,
/// `n` makes the file, Esc goes back to the pane.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.scripts_panel;
    switch (try Panel.handleKey(&st.panel, app.gpa, k)) {
        .consumed, .filter_changed => return true,
        .activate => |i| {
            const list = try rows(app, app.frame.allocator());
            if (i < list.len) try openRow(app, list[i]);
            return true;
        },
        .new_activate => {},
        .ignored => {},
    }
    if (st.panel.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'r' => runToast(app, command.run(app, .{ .static = .@"script.reload" })),
                'n' => runToast(app, newInit(app)),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .scripts };
    app.needs_render = true;
}

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.scripts_panel;
    switch (m.kind) {
        .press => {
            focusPanel(app);
            const was = st.panel.cursor;
            st.panel.cursor = idx;
            // right-click is the row's menu.
            if (m.button == .right) return openRowMenu(app, idx, m.x, m.y);
            if (m.button == .left and was == idx) {
                const list = try rows(app, app.frame.allocator());
                if (idx < list.len) try openRow(app, list[idx]);
            }
        },
        else => {},
    }
}

/// The wheel over the list moves the cursor `rows` rows.
pub fn wheel(app: *App, down: bool, step: usize) Allocator.Error!void {
    const st = &app.scripts_panel;
    const n = (try rows(app, app.frame.allocator())).len;
    st.panel.cursor = if (down) @min(st.panel.cursor + step, n -| 1) else st.panel.cursor -| step;
    app.needs_render = true;
}

/// The row's `⋮`: the same menu as a right-click.
pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.scripts_panel.panel.cursor = idx;
    try openRowMenu(app, idx, m.x, m.y);
}

/// A row's menu: Run and *Bind in init.lua…* for a command, Open
/// `file:line` when the row has one, the copy, Reload scripts. The link
/// row's is Create init.lua.
pub fn openRowMenu(app: *App, idx: u32, x: u16, y: u16) Allocator.Error!void {
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len) return;
    const row = list[idx];
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var out: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer out.deinit(app.gpa);
    if (row.link) {
        try out.append(app.gpa, .{ .label = "Create init.lua", .action = .{ .command = .@"script.new_init" } });
    } else {
        const name = try arena.dupe(u8, row.name);
        if (row.kind == .command) {
            if (command.resolve(app, name)) |ref| try out.append(app.gpa, .{ .label = "Run", .action = switch (ref) {
                .static => |s| .{ .command = s },
                .dyn => |d| .{ .dyn = d },
            } });
            try out.append(app.gpa, .{ .label = "Bind in init.lua\u{2026}", .action = .{ .lua_bind = name } });
        }
        if (row.file.len > 0) try out.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Open {s}", .{row.loc}), .action = .{ .script_row_open = idx }, .separator_before = out.items.len > 0 });
        try out.append(app.gpa, .{ .label = if (row.kind == .command) "Copy id" else "Copy name", .action = .{ .copy_text = name } });
    }
    try out.append(app.gpa, .{ .label = "Reload scripts", .action = .{ .command = .@"script.reload" }, .separator_before = true });
    const owned = try out.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, if (row.link) lua_mod.init_file else row.name, owned, x, y, mem);
}

/// The row menu's Open: the row at `idx` in the panel's current order.
pub fn openRowIndex(app: *App, idx: u32) Allocator.Error!void {
    const list = try rows(app, app.frame.allocator());
    if (idx < list.len) try openRow(app, list[idx]);
}

/// *Bind in init.lua…*: the prompt for the key that will run `id`.
pub fn promptBind(app: *App, id: []const u8) Allocator.Error!void {
    const owned_id = try app.gpa.dupe(u8, id);
    errdefer app.gpa.free(owned_id);
    const title = try std.fmt.allocPrint(app.gpa, "Bind {s} to key", .{id});
    errdefer app.gpa.free(title);
    var state = app_mod.Prompt.init(app.gpa, title);
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .lua_bind = .{ .id = owned_id, .title = title } } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The key typed into the prompt: parsed as a key spec, then
/// `mnml.map("<spec>", "<id>")` on a new last line of the workspace
/// `init.lua` (the template first when there is none), the file reloaded
/// in its editor when it is open and clean — refused when it is dirty,
/// the write would sit under the buffer — and the scripts reloaded, so
/// the chord works at once.
pub fn acceptBind(app: *App, id: []const u8, text: []const u8) Allocator.Error!void {
    const spec = std.mem.trim(u8, text, " \t");
    if (spec.len == 0) return;
    var buf: [keymap.max_seq]Chord = undefined;
    if (keymap.parseKeySeqBuf(spec, &buf) == null) {
        app.toast("not a key: {s} (ctrl+shift+h, <leader>x, g d)", .{spec});
        return;
    }
    const arena = app.frame.allocator();
    const path = try workspaceInit(app);
    const rel = app.relPath(path);
    const open_pane = app.panes.findPath(path);
    if (open_pane) |pid| if (app.panes.editor(pid)) |e| if (e.buf.doc.dirty) {
        app.toast("{s} has unsaved changes — save it first", .{rel});
        return;
    };
    const existing: []const u8 = if (exists(app, path))
        Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(1 << 30)) catch |err| {
            app.toast("cannot read {s}: {s}", .{ rel, @errorName(err) });
            return;
        }
    else
        template;
    const needs_nl = existing.len > 0 and existing[existing.len - 1] != '\n';
    const line_no = std.mem.count(u8, existing, "\n") + @as(usize, if (needs_nl) 1 else 0) + 1;
    const joined = try std.fmt.allocPrint(arena, "{s}{s}mnml.map(\"{s}\", \"{s}\")\n", .{ existing, if (needs_nl) "\n" else "", spec, id });
    const dir = std.fs.path.dirname(path) orelse app.workspace;
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = joined }) catch |err| {
        app.toast("cannot write {s}: {s}", .{ rel, @errorName(err) });
        return;
    };
    if (open_pane) |pid| watch.reload(app, pid) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    command.run(app, .{ .static = .@"script.reload" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    app.toast("bound {s} → {s}  ({s}:{d})", .{ spec, id, rel, line_no });
}

/// The header's refresh chip: a click reloads every `init.lua`; a
/// right-click is the refresh menu.
pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .scripts, m.x, m.y) else runToast(app, command.run(app, .{ .static = .@"script.reload" })),
        .sort, .new, .view, .history => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.scripts_panel.panel.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.scripts_panel;
    const total = st.panel.total;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            st.panel.cursor = @min((m.y -| bar.y) * total / bar.h, total - 1);
        },
        .scroll_up => st.panel.cursor -|= 3,
        .scroll_down => st.panel.cursor = @min(st.panel.cursor + 3, total - 1),
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "SCRIPTS: the rows name what init.lua registered with file:line; Enter jumps to the line; the link row makes the file; r reloads" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .workspace_trusted = true, .cols = 120, .rows = 40 });
    defer app.deinit();
    // No workspace file: the link row alone, and Enter on it creates the file.
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    try t.expectEqual(side.Section.scripts, side.shown(&app, .left).?);
    try t.expect(app.focus == .panel and app.focus.panel == .scripts);
    var txt = try screenText(&app);
    try t.expect(std.mem.indexOf(u8, txt, "SCRIPTS (0)") != null);
    try t.expect(std.mem.indexOf(u8, txt, link_label) != null);
    t.allocator.free(txt);
    try app.handle(.{ .key = Key.named(.enter) });
    const path = try std.fs.path.join(t.allocator, &.{ root, ".mnml", "init.lua" });
    defer t.allocator.free(path);
    try t.expect(exists(&app, path));
    try t.expectEqualStrings(path, app.activeEditor().?.buf.doc.path.?);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expectEqualStrings(template, text);
    // The template runs clean and registers nothing; a real file registers rows.
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/init.lua", .data = "-- one\nmnml.command{ id = 'hello', run = function() end }\nmnml.on('save_post', function() end)\nmnml.statusline.segment{ id = 'seg', fn = function() return 'x' end }\nmnml.picker.source{ id = 'src', items = function() return {} end }\n" });
    try command.run(&app, .{ .static = .@"script.reload" });
    const list = try rows(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 4), list.len);
    try t.expectEqualStrings("user.hello", list[0].name);
    try t.expectEqualStrings(".mnml/init.lua:2", list[0].loc);
    try t.expectEqual(view.Kind.hook, list[1].kind);
    try t.expectEqualStrings(".mnml/init.lua:3", list[1].loc);
    try t.expectEqualStrings(".mnml/init.lua:4", list[2].loc);
    try t.expectEqual(view.Kind.source, list[3].kind);
    txt = try screenText(&app);
    try t.expect(std.mem.indexOf(u8, txt, "SCRIPTS (4)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "cmd  user.hello") != null);
    try t.expect(std.mem.indexOf(u8, txt, "hook save_post") != null);
    try t.expect(std.mem.indexOf(u8, txt, "pick src") != null);
    t.allocator.free(txt);
    // Enter on the hook row: the file at line 3.
    focusPanel(&app);
    app.scripts_panel.panel.cursor = 1;
    try app.handle(.{ .key = Key.named(.enter) });
    const e = app.activeEditor().?;
    try t.expectEqualStrings(path, e.buf.doc.path.?);
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try t.expect(app.focus == .pane);
    // The filter narrows by name or location.
    focusPanel(&app);
    try app.handle(.{ .key = Key.char('/') });
    try app.handle(.{ .key = Key.char('s') });
    try app.handle(.{ .key = Key.char('e') });
    try app.handle(.{ .key = Key.char('g') });
    const narrowed = try rows(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 1), narrowed.len);
    try t.expectEqualStrings("seg", narrowed[0].name);
    try app.handle(.{ .key = Key.named(.esc) });
    // `r` reloads: the file changed, the rows follow.
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/init.lua", .data = "mnml.command{ id = 'only', run = function() end }\n" });
    app.scripts_panel.panel.filter_focused = false;
    try app.handle(.{ .key = Key.char('r') });
    const after = try rows(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 1), after.len);
    try t.expectEqualStrings("user.only", after[0].name);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "scripts: reloaded — 1 command, 0 hooks"));
    // The section moves like any other.
    try command.run(&app, .{ .static = .@"view.move_section_right" });
    try t.expectEqual(side.Section.scripts, side.shown(&app, .right).?);
}

test "SCRIPTS: right-click on a command row — Run, Bind in init.lua…, Open, Copy id, Reload; the bind writes mnml.map on a new last line and the chord runs; a bad key and a dirty file are refused" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, ".mnml");
    // No trailing newline: the map line still lands on a line of its own.
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/init.lua", .data = "mnml.command{ id = 'hello', run = function() mnml.toast('hi from hello') end }" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .workspace_trusted = true, .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    try rowMouse(&app, 0, .{ .x = 5, .y = 5, .kind = .press, .button = .right });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("user.hello", app.overlay.menu.title);
    const items = app.overlay.menu.items;
    try t.expectEqual(@as(usize, 5), items.len);
    try t.expectEqualStrings("Run", items[0].label);
    try t.expectEqualStrings("Bind in init.lua…", items[1].label);
    try t.expect(items[1].action == .lua_bind);
    try t.expectEqualStrings("Open .mnml/init.lua:1", items[2].label);
    try t.expectEqualStrings("Copy id", items[3].label);
    try t.expectEqualStrings("user.hello", items[3].action.copy_text);
    try t.expectEqualStrings("Reload scripts", items[4].label);
    try app.handle(.{ .key = Key.named(.esc) });
    // The kebab opens the same menu.
    try kebabMouse(&app, 0, .{ .x = 25, .y = 5, .kind = .press, .button = .left });
    try t.expect(app.overlay == .menu);
    try app.handle(.{ .key = Key.named(.esc) });
    // The bind: the prompt names the command; a bad key is refused; a
    // good one lands on a new last line, and the chord runs the command.
    try promptBind(&app, "user.hello");
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("Bind user.hello to key", app.overlay.prompt.state.title);
    try app.handle(.{ .key = Key.named(.esc) });
    try acceptBind(&app, "user.hello", "not a key at all");
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "not a key"));
    try acceptBind(&app, "user.hello", "ctrl+alt+u");
    try t.expectEqualStrings("bound ctrl+alt+u → user.hello  (.mnml/init.lua:2)", app.lastToast().?);
    const text = try tmp.dir.readFileAlloc(t.io, ".mnml/init.lua", t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.endsWith(u8, text, "}\nmnml.map(\"ctrl+alt+u\", \"user.hello\")\n"));
    try app.handle(.{ .key = .{ .code = .{ .char = 'u' }, .mods = .{ .ctrl = true, .alt = true } } });
    try t.expectEqualStrings("hi from hello", app.lastToast().?);
    // The file open and dirty: refused, the write would sit under the buffer.
    const path = try std.fs.path.join(t.allocator, &.{ root, ".mnml", "init.lua" });
    defer t.allocator.free(path);
    _ = try app.openPath(path);
    _ = try app.applyOps(app.activeEditor().?, &.{.{ .insert_str = "-- x" }});
    try acceptBind(&app, "user.hello", "ctrl+alt+v");
    try t.expectEqualStrings(".mnml/init.lua has unsaved changes — save it first", app.lastToast().?);
}
