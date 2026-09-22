//! `mnml.section{}` — a rail section a script registered. It is a real
//! activity-bar row (its own glyph, its own place, from `after`), a real
//! column surface (`PanelId.script`), and a real `ListPanel` fed by the
//! script's `mnml.list{}`: the caps header with the refresh and `sort:`
//! chips, the filter pill, the folds, the row menu and every hit are the
//! ones TODOS has, because they are TODOS'.
//!
//! One slot hosts them. `Section.script` / `PanelId.script` are one
//! member each, and `Store.active` says which registered section the
//! column is showing — so two script sections cannot be on screen at
//! once, while each still has its own rail row, its own glyph and its
//! own list. A click on a row makes that section the active one and
//! places it.
//!
//! Everything goes with the Lua state: `script.reload` drops the
//! sections, their rail rows and the lists behind them (`reset`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Config = @import("../config/Config.zig");
const rail = @import("../ui/activity_bar.zig");
const script_list = @import("script_list.zig");
const side = @import("side.zig");
const activity_bar = @import("activity_bar.zig");
const Key = @import("../core/key.zig").Key;
const Mouse = @import("../core/key.zig").Mouse;

/// One registered section. Every slice is gpa-owned.
pub const Section = struct {
    id: []u8,
    title: []u8,
    glyph: []u8,
    ascii: []u8,
    /// The built-in rail section this one sits after; empty = last.
    after: []u8,
    list: u32,
    /// The Lua state that registered it — a reload of one installed
    /// script takes only its own sections.
    state: u16 = 0,
};

pub const Store = struct {
    items: std.ArrayListUnmanaged(Section) = .empty,
    /// Which registered section `PanelId.script` is showing.
    active: u16 = 0,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        self.clear(gpa);
        self.items.deinit(gpa);
    }

    pub fn clear(self: *Store, gpa: Allocator) void {
        for (self.items.items) |*s| freeSection(gpa, s);
        self.items.clearRetainingCapacity();
        self.active = 0;
    }

    /// Drop the sections ONE Lua state registered.
    pub fn clearState(self: *Store, gpa: Allocator, state: u16) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].state == state) {
                freeSection(gpa, &self.items.items[i]);
                _ = self.items.orderedRemove(i);
            } else i += 1;
        }
        if (self.active >= self.items.items.len) self.active = 0;
    }

    fn freeSection(gpa: Allocator, s: *Section) void {
        gpa.free(s.id);
        gpa.free(s.title);
        gpa.free(s.glyph);
        gpa.free(s.ascii);
        gpa.free(s.after);
    }
};

/// `script.reload`: the rail rows go, and the column falls back to
/// whatever it showed before if it was showing one.
pub fn reset(app: *App) Allocator.Error!void {
    if (app.script_sections.items.items.len == 0) return;
    for ([_]Config.Side{ .left, .right }) |s| if (app.side.open.get(s)) |shown| {
        if (shown == .script) side.remove(app, .script);
    };
    app.script_sections.clear(app.gpa);
    app.needs_render = true;
}

/// One state's sections go; the others stay, and the column only
/// closes when what it was showing was one of the ones that went.
pub fn resetState(app: *App, state: u16) Allocator.Error!void {
    var any = false;
    for (app.script_sections.items.items) |s| any = any or s.state == state;
    if (!any) return;
    const shown_idx = app.script_sections.active;
    const shown_state: ?u16 = if (shown_idx < app.script_sections.items.items.len) app.script_sections.items.items[shown_idx].state else null;
    app.script_sections.clearState(app.gpa, state);
    if (app.script_sections.items.items.len == 0 or (shown_state != null and shown_state.? == state)) {
        for ([_]Config.Side{ .left, .right }) |s| if (app.side.open.get(s)) |shown| {
            if (shown == .script) side.remove(app, .script);
        };
    }
    app.needs_render = true;
}

/// Register (or replace) a section. Takes the strings.
pub fn add(app: *App, id: []u8, title: []u8, glyph: []u8, ascii: []u8, after: []u8, list: u32, at_side: Config.Side) Allocator.Error!u16 {
    const gpa = app.gpa;
    app.side.of.set(.script, at_side);
    for (app.script_sections.items.items, 0..) |*s, i| if (std.mem.eql(u8, s.id, id)) {
        gpa.free(s.title);
        gpa.free(s.glyph);
        gpa.free(s.ascii);
        gpa.free(s.after);
        gpa.free(id);
        s.* = .{ .id = s.id, .title = title, .glyph = glyph, .ascii = ascii, .after = after, .list = list };
        app.needs_render = true;
        return @intCast(i);
    };
    try app.script_sections.items.append(gpa, .{ .id = id, .title = title, .glyph = glyph, .ascii = ascii, .after = after, .list = list });
    app.needs_render = true;
    return @intCast(app.script_sections.items.items.len - 1);
}

pub fn active(app: *App) ?*Section {
    const items = app.script_sections.items.items;
    if (items.len == 0) return null;
    return &items[@min(app.script_sections.active, items.len - 1)];
}

pub fn activeList(app: *App) ?*script_list.List {
    const s = active(app) orelse return null;
    return script_list.find(app, s.list);
}

/// The rail's rows for this frame (frame arena).
pub fn railRows(app: *App, arena: Allocator) Allocator.Error![]const rail.ScriptRow {
    const out = try arena.alloc(rail.ScriptRow, app.script_sections.items.items.len);
    for (app.script_sections.items.items, 0..) |s, i| out[i] = .{
        .glyph = s.glyph,
        .fallback = s.ascii,
        .label = s.title,
        .after = s.after,
    };
    return out;
}

/// A click on the `i`-th script section's rail row: it becomes the
/// active one and takes its column.
pub fn show(app: *App, i: u16, focus: bool) void {
    if (i >= app.script_sections.items.items.len) return;
    app.script_sections.active = i;
    activity_bar.enter(app, .script);
    side.place(app, .script, focus);
}

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const l = activeList(app) orelse {
        ui.fill(area, ui.theme.panel_bg);
        return;
    };
    const caret = try script_list.draw(app, ui, area, l, .{ .panel = .script });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const l = activeList(app) orelse return false;
    if (try script_list.handleKey(app, l, k)) return true;
    if (l.panel.filter_focused) return false;
    if (k.code == .esc) {
        if (app.active) |a| app.focus = .{ .pane = a };
        return true;
    }
    return false;
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .script };
    app.needs_render = true;
}

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const l = activeList(app) orelse return;
    if (m.kind != .press) return;
    focusPanel(app);
    const was = l.panel.cursor;
    l.panel.cursor = idx;
    l.panel.on_new = false;
    if (m.button == .right) return script_list.openRowMenu(app, l, idx, m.x, m.y);
    if (m.button != .left) return;
    const rows = try script_list.visible(app, l, app.frame.allocator());
    if (idx < rows.len and rows[idx].header) return script_list.toggleFold(app, l, rows[idx].label);
    if (was == idx) try script_list.activate(app, l, idx);
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    const l = activeList(app) orelse return;
    focusPanel(app);
    l.panel.cursor = idx;
    try script_list.openRowMenu(app, l, idx, m.x, m.y);
}

pub fn wheel(app: *App, down: bool, step: usize) Allocator.Error!void {
    const l = activeList(app) orelse return;
    try script_list.wheel(app, l, down, step);
}

pub fn chip(app: *App, kind: @import("../ui/hit.zig").ChipKind, m: Mouse) Allocator.Error!void {
    const l = activeList(app) orelse return;
    switch (kind) {
        .sort => try script_list.cycleSort(app, l),
        .refresh => try script_list.refresh(app, l),
        else => {},
    }
    _ = m;
}

pub fn filterFocus(app: *App) void {
    const l = activeList(app) orelse return;
    focusPanel(app);
    l.panel.filter_focused = true;
    app.needs_render = true;
}

pub fn scroll(app: *App, to: usize) void {
    const l = activeList(app) orelse return;
    l.panel.scroll = to;
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");
const rail_mod = @import("../ui/activity_bar.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "a script section is a rail row after the one it names, a column like TODOS, and it folds, filters, sorts and goes on reload" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    const lua = app.script();
    lua.runString(
        \\sorts = {}
        \\local l = mnml.list{ title = "TODOS (lua)", sort = { "State", "Name" },
        \\  rows = function(sort)
        \\    sorts[#sorts + 1] = tostring(sort)
        \\    return { { header = "src/app.zig", count = 2 },
        \\             { label = "fix the clamp", detail = "app.zig:12" },
        \\             { label = "drop the cast", detail = "app.zig:40" },
        \\             { header = "src/ui.zig", count = 1 },
        \\             { label = "widen the box", detail = "ui.zig:7" } }
        \\  end,
        \\  on_enter = function(row) opened = row.label end }
        \\section = mnml.section{ id = "todos_lua", title = "TODOS (lua)", glyph = "+", ascii = "T",
        \\                        list = l, side = "left", after = "todos" }
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    try t.expectEqual(@as(usize, 1), app.script_sections.items.items.len);
    // The rail row sits directly after TODOS' — the place `after` names.
    try app.render();
    const order = try rail_mod.railOrder(app.frame.allocator(), try railRows(&app, app.frame.allocator()), &.{});
    var at: usize = 0;
    for (order, 0..) |rr, i| if (rr == .section and rr.section == .todos) {
        at = i;
    };
    try t.expect(order[at + 1] == .script);
    // Its own glyph is on the rail, and a click on the row opens it.
    var rail_hit: ?@import("../ui/rect.zig") = null;
    for (app.hits.items.items) |e| if (e.target == .rail and e.target.rail == .script) {
        rail_hit = e.rect;
    };
    try t.expect(rail_hit != null);
    try app.handle(.{ .mouse = .{ .x = rail_hit.?.x + 1, .y = rail_hit.?.y, .button = .left, .kind = .press, .mods = .{} } });
    try t.expectEqual(rail_mod.Section.script, side.shown(&app, .left).?);
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        // The caps header, the count, the sort chip, the rows.
        // The caps header paints the title as the script wrote it.
        try t.expect(std.mem.indexOf(u8, txt, "TODOS (lua) (3)") != null);
        try t.expect(std.mem.indexOf(u8, txt, "fix the clamp") != null);
        try t.expect(std.mem.indexOf(u8, txt, "widen the box") != null);
    }
    // Every row and the header's chips are in the hit map, so rects.json
    // names them the way a built-in section's are named.
    {
        var aw: std.Io.Writer.Allocating = .init(t.allocator);
        defer aw.deinit();
        try app.hits.writeRectsJson(&aw.writer, null);
        const json = aw.written();
        try t.expect(std.mem.indexOf(u8, json, "\"row:script:0\"") != null);
        try t.expect(std.mem.indexOf(u8, json, "\"chip:script:refresh\"") != null);
        try t.expect(std.mem.indexOf(u8, json, "\"rail:script:0\"") != null);
    }
    // The `sort:` chip needs the room the built-ins' need: at the stock
    // 26-cell column the header drops it, at 44 it paints.
    app.tree.width = 44;
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, "State") != null);
    }
    app.tree.width = 30;
    const l = activeList(&app).?;
    // Enter on the header folds it; its two items go, the other stays.
    l.panel.cursor = 0;
    try script_list.activate(&app, l, 0);
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, "fix the clamp") == null);
        try t.expect(std.mem.indexOf(u8, txt, "widen the box") != null);
    }
    try script_list.activate(&app, l, 0);
    // Enter on an item reaches the script.
    l.panel.cursor = 1;
    try script_list.activate(&app, l, 1);
    try lua.runString("assert(opened == 'fix the clamp', tostring(opened))");
    // The filter keeps the header of a surviving row and drops the other.
    try l.panel.filter.appendSlice(t.allocator, "widen");
    {
        const rows = try script_list.visible(&app, l, app.frame.allocator());
        try t.expectEqual(@as(usize, 2), rows.len);
        try t.expect(rows[0].header);
        try t.expectEqualStrings("src/ui.zig", rows[0].label);
        try t.expectEqualStrings("widen the box", rows[1].label);
    }
    l.panel.filter.clearRetainingCapacity();
    // The sort chip cycles and asks again under the new mode.
    try lua.runString("assert(sorts[1] == 'State', sorts[1])");
    try script_list.cycleSort(&app, l);
    try lua.runString("assert(sorts[#sorts] == 'Name', sorts[#sorts])");
    try t.expectEqualStrings("Name", l.sortLabel().?);
    // A reload drops the section, its rail row and its list.
    try lua.reset();
    try t.expectEqual(@as(usize, 0), app.script_sections.items.items.len);
    try t.expectEqual(@as(usize, 0), app.script_lists.lists.items.len);
    try t.expect(side.shown(&app, .left) == null or side.shown(&app, .left).? != .script);
    try app.render();
    for (app.hits.items.items) |e| try t.expect(!(e.target == .rail and e.target.rail == .script));
}

test "a list in a pane: the same panel, its own keys, and closing the pane leaves the list alone" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 90, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    const lua = app.script();
    lua.runString(
        \\local l = mnml.list{ title = "Todos", rows = function()
        \\  return { { label = "alpha", detail = "a:1" }, { label = "beta", detail = "b:2" } }
        \\end, on_enter = function(row) chosen = row.label end }
        \\handle = l
        \\pane = mnml.pane.open{ title = "Todos", list = l }
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    const id = app.active.?;
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, "Todos") != null);
        try t.expect(std.mem.indexOf(u8, txt, "alpha") != null);
        try t.expect(std.mem.indexOf(u8, txt, "beta") != null);
    }
    // `j` moves and Enter activates — the panel's own keys, in a pane.
    try app.handle(.{ .key = .{ .code = .{ .char = 'j' } } });
    try app.handle(.{ .key = .{ .code = .enter } });
    try lua.runString("assert(chosen == 'beta', tostring(chosen))");
    // `l:refresh()` asks again.
    try lua.runString("rows2 = true handle:refresh()");
    try t.expectEqual(@as(usize, 2), app.script_lists.lists.items[0].cache.len);
    try app.forceClosePane(id);
    try t.expect(app.panes.get(id) == null);
    try t.expectEqual(@as(usize, 1), app.script_lists.lists.items.len);
    try t.expectEqual(@as(i32, 0), lua.L.getTop());
}
