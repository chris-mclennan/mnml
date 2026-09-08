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
            if (m.button == .left and was == idx) {
                const list = try rows(app, app.frame.allocator());
                if (idx < list.len) try openRow(app, list[idx]);
            }
        },
        .scroll_up => st.panel.cursor -|= 3,
        .scroll_down => st.panel.cursor += 3,
        else => {},
    }
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    _ = app;
    _ = idx;
    _ = m;
}

/// The header's refresh chip: a click reloads every `init.lua`; a
/// right-click is the refresh menu.
pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .scripts, m.x, m.y) else runToast(app, command.run(app, .{ .static = .@"script.reload" })),
        .sort, .new, .view => {},
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
