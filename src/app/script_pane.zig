//! `Pane.script` (D10.3): a pane a script owns. Its `render(w, h)`
//! answers every frame with rows of styled segments, which
//! `ui/script_view.zig` paints and registers as `.script_hit{ pane,
//! id }`; a click on one reaches `on_hit(id, button)`, and while the
//! pane is focused every key reaches `on_key(name)` first (a truthy
//! return consumes it, anything else falls through to the chord chain).
//!
//! The pane holds registry refs; closing it (`forceClosePane`, a
//! reload) gives them back through `deinit`, which is why it keeps the
//! `*Lua` it was made with — `Pane.deinit` has no App.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = @import("../core/key.zig").Key;
const Chord = @import("../core/key.zig").Chord;
const Mouse = @import("../core/key.zig").Mouse;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const script_view = @import("../ui/script_view.zig");
const script_list = @import("script_list.zig");
const hit_mod = @import("../ui/hit.zig");
const lua_mod = @import("../scripting/lua.zig");
const Lua = lua_mod.Lua;
const LuaRef = lua_mod.LuaRef;

pub const ScriptPane = struct {
    lua: *Lua,
    /// Owned.
    title: []u8,
    /// Null when the pane hosts a list instead (`list`).
    render: ?LuaRef,
    on_hit: ?LuaRef,
    on_key: ?LuaRef,
    /// // changed (lua-plumbing): `mnml.pane.open{ list = l }` — the
    /// pane paints that list through `ListPanel` instead of calling
    /// `render`. 0 is "none". The list is the Lua state's, not the
    /// pane's: closing the pane leaves it for a section to host.
    list: u32 = 0,

    pub fn deinit(self: *ScriptPane, gpa: Allocator) void {
        if (self.render) |r| self.lua.unref(r);
        if (self.on_hit) |r| self.lua.unref(r);
        if (self.on_key) |r| self.lua.unref(r);
        gpa.free(self.title);
    }
};

/// Open a script pane and focus it. Takes the refs.
pub fn open(app: *App, lua: *Lua, title: []const u8, render: ?LuaRef, on_hit: ?LuaRef, on_key: ?LuaRef, list: u32) Allocator.Error!PaneId {
    const owned = try app.gpa.dupe(u8, title);
    errdefer app.gpa.free(owned);
    const id = try app.panes.add(.{ .script = .{ .lua = lua, .title = owned, .render = render, .on_hit = on_hit, .on_key = on_key, .list = list } });
    app.showPane(id);
    return id;
}

pub fn draw(app: *App, ui: Ui, pane: PaneId, sp: *ScriptPane, area: Rect) Allocator.Error!void {
    if (app.active == pane) app.pane_rows = @max(area.h, 1);
    if (sp.list != 0) {
        const l = script_list.find(app, sp.list) orelse return;
        const caret = try script_list.draw(app, ui, area, l, .{ .panel = .todos, .pane = pane, .focused = app.active == pane and app.focus == .pane and app.focus.pane == pane });
        if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
        return;
    }
    // The pane's refs belong to the state that opened it (an installed
    // script's own, or `init.lua`'s): `App.luaState`, never `script()`.
    const render = sp.render.?;
    const lua = app.luaState(render.state) orelse return;
    const rows = try lua.callRender(render, area.w, area.h);
    script_view.draw(ui, pane, area, rows);
}

/// The key's canonical spec (`ctrl+p`, `enter`, `j`) — what `on_key` gets.
fn keyName(arena: Allocator, k: Key) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{Chord.of(k)});
}

/// Focused pane, a key: `on_key(name)`; true when the script took it.
/// A list-backed pane gives the list's own keys the first turn.
pub fn handleKey(app: *App, sp: *ScriptPane, k: Key) Allocator.Error!bool {
    if (sp.list != 0) if (script_list.find(app, sp.list)) |l| {
        if (try script_list.handleKey(app, l, k)) return true;
    };
    const r = sp.on_key orelse return false;
    const name = try keyName(app.frame.allocator(), k);
    const lua = app.luaState(r.state) orelse return false;
    return lua.callKey(r, name);
}

/// A click on a segment with a `hit`: `on_hit(id, button)`. A
/// list-backed pane reads the `ListHit` instead — its rows, kebabs,
/// chips and filter are the panel's own targets.
pub fn click(app: *App, pane: PaneId, sp: *ScriptPane, id: u32, m: Mouse) Allocator.Error!void {
    if (sp.list != 0) {
        const l = script_list.find(app, sp.list) orelse return;
        return script_click(app, pane, l, id, m);
    }
    const r = sp.on_hit orelse return;
    const button: []const u8 = switch (m.button) {
        .left => "left",
        .right => "right",
        .middle => "middle",
        else => return,
    };
    const lua = app.luaState(r.state) orelse return;
    lua.callHit(r, id, button);
}

/// The `ListHit` targets of a list-backed pane (or a rail section).
pub fn script_click(app: *App, pane: ?PaneId, l: *script_list.List, hit_id: u32, m: Mouse) Allocator.Error!void {
    _ = pane;
    if (m.kind != .press) return;
    app.needs_render = true;
    if (hit_id >= hit_mod.ListHit.kebab_base) return script_list.openRowMenu(app, l, hit_id - hit_mod.ListHit.kebab_base, m.x, m.y);
    if (hit_id >= hit_mod.ListHit.row_base) {
        const idx = hit_id - hit_mod.ListHit.row_base;
        const was = l.panel.cursor;
        l.panel.cursor = idx;
        l.panel.on_new = false;
        if (m.button == .right) return script_list.openRowMenu(app, l, idx, m.x, m.y);
        if (m.button != .left) return;
        // A header folds on the first click; an item needs a second, the
        // rule every list panel follows.
        const rows = try script_list.visible(app, l, app.frame.allocator());
        if (idx < rows.len and rows[idx].header) return script_list.toggleFold(app, l, rows[idx].label);
        if (was == idx) try script_list.activate(app, l, idx);
        return;
    }
    if (hit_id == hit_mod.ListHit.filter_id) {
        l.panel.filter_focused = true;
        return;
    }
    if (hit_mod.ListHit.chipOf(hit_id)) |kind| switch (kind) {
        .sort => try script_list.cycleSort(app, l),
        .refresh => try script_list.refresh(app, l),
        else => {},
    };
}

/// The wheel over the pane: `on_key("wheel_up" | "wheel_down")`, once
/// per notch — or the list's scroll when a list hosts it.
pub fn wheel(app: *App, sp: *ScriptPane, down: bool, n: usize) void {
    if (sp.list != 0) {
        if (script_list.find(app, sp.list)) |l| script_list.wheel(app, l, down, n) catch {};
        return;
    }
    const r = sp.on_key orelse return;
    const lua = app.luaState(r.state) orelse return;
    var i: usize = 0;
    while (i < n) : (i += 1) _ = lua.callKey(r, if (down) "wheel_down" else "wheel_up");
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

test "a script pane renders its rows, a click reaches on_hit, a key reaches on_key, close unrefs" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    const lua = app.script();
    try lua.runString(
        \\clicks = {}
        \\keys = {}
        \\notes = { "alpha", "beta" }
        \\pane = mnml.pane.open{
        \\  title = "Notes",
        \\  render = function(w, h)
        \\    local rows = { { { text = "NOTES " .. w .. "x" .. h, fg = "accent", bold = true } } }
        \\    for i, n in ipairs(notes) do rows[#rows + 1] = { { text = "- ", fg = "muted" }, { text = n, hit = i } } end
        \\    return rows
        \\  end,
        \\  on_hit = function(id, button) clicks[#clicks + 1] = id .. ":" .. button end,
        \\  on_key = function(k) keys[#keys + 1] = k; return k == "a" end,
        \\}
    );
    const id = app.active.?;
    try t.expect(app.panes.get(id).?.* == .script);
    try t.expectEqualStrings("Notes", app.panes.get(id).?.title());
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    // 40 columns less the rail's: a script pane insets for it like
    // any other, and its `render` is handed the width it actually has.
    try t.expect(std.mem.indexOf(u8, txt, "NOTES 39x") != null);
    try t.expect(std.mem.indexOf(u8, txt, "- alpha") != null);
    try t.expect(std.mem.indexOf(u8, txt, "- beta") != null);
    // The hit map carries the segment ids; a click on "beta" reaches on_hit.
    var found: ?Rect = null;
    for (app.hits.items.items) |e| if (e.target == .script_hit and e.target.script_hit.id == 2) {
        found = e.rect;
    };
    try t.expect(found != null);
    try app.handle(.{ .mouse = .{ .x = found.?.x, .y = found.?.y, .button = .left, .kind = .press, .mods = .{} } });
    try lua.runString("assert(clicks[1] == '2:left', tostring(clicks[1]))");
    // Keys: `a` is consumed, `b` falls through to the chord chain.
    try app.handle(.{ .key = Key.char('a') });
    try app.handle(.{ .key = Key.char('b') });
    try lua.runString("assert(keys[1] == 'a' and keys[2] == 'b', table.concat(keys, ','))");
    // Closing the pane unrefs; the state is still fine.
    try app.forceClosePane(id);
    try t.expect(app.panes.get(id) == null);
    try lua.runString("assert(type(pane) == 'number')");
    try t.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "a render that errors paints its message instead of failing the frame" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    const lua = app.script();
    try lua.runString("mnml.pane.open{ title = 'Bad', render = function() error('render boom') end }");
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "render boom") != null);
    try t.expectEqual(@as(usize, 0), app.toasts.items.len);
}
