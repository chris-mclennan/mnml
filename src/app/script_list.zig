//! `mnml.list{}` — a script's list, backed by the same `ListPanel`
//! TODOS is. The script answers with rows; everything around them —
//! the caps header with the refresh and `sort:` chips, the filter pill,
//! `j`/`k`/`g`/`G`/Enter, the fold headers, the scrollbar, the row
//! menu, the hits — is the panel's, so a script's list is the built-in
//! one rather than a copy of it.
//!
//! Two hosts, one list: `mnml.pane.open{ list = l }` puts it in a pane
//! (`app/script_pane.zig`), `mnml.section{ list = l }` puts it in the
//! sidebar as a rail section (`app/script_section.zig`). Both draw
//! through `draw` here.
//!
//! The rows are cached: `rows()` is called when the list is created,
//! when the script calls `l:refresh()`, when the `⟳` chip is clicked,
//! and when the sort changes — never per frame, because Lua is never
//! entered from the paint loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const view = @import("../ui/script_list.zig");
const fuzzy = @import("../ui/fuzzy.zig");
const panel_mod = @import("../core/panel.zig");
const command = @import("../core/command.zig");
const Key = @import("../core/key.zig").Key;
const Mouse = @import("../core/key.zig").Mouse;
const context_menus = @import("context_menus.zig");
const MenuItem = command.MenuItem;
const lua_mod = @import("../scripting/lua.zig");
const LuaRef = lua_mod.LuaRef;

pub const Row = view.Row;
pub const Panel = list_panel.ListPanel(Row);

/// A list as the app keeps it. `rows` / `on_enter` / `on_menu` are
/// registry refs into the Lua state, so the whole table dies with it.
pub const List = struct {
    /// The handle the script holds (1-based; 0 is "no list").
    id: u32,
    title: []u8,
    rows_fn: LuaRef,
    on_enter: ?LuaRef = null,
    on_menu: ?LuaRef = null,
    /// The sort modes the script named, in order; empty = no chip.
    sorts: [][]u8 = &.{},
    sort_idx: usize = 0,
    /// The decoded rows of the last `rows()` call (gpa).
    cache: []Row = &.{},
    panel: Panel.State = .{},
    /// The labels of the collapsed headers (gpa), so a refresh that
    /// answers the same headers keeps them folded.
    folded: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn sortLabel(self: *const List) ?[]const u8 {
        if (self.sorts.len == 0) return null;
        return self.sorts[@min(self.sort_idx, self.sorts.len - 1)];
    }

    /// The widest sort name, so the chip pads to it and never resizes
    /// under a repeat-clicking pointer (the built-in chips' rule).
    pub fn sortWidest(self: *const List) usize {
        var w: usize = 0;
        for (self.sorts) |s| w = @max(w, std.unicode.utf8CountCodepoints(s) catch s.len);
        return w;
    }

    pub fn isFolded(self: *const List, label: []const u8) bool {
        for (self.folded.items) |f| if (std.mem.eql(u8, f, label)) return true;
        return false;
    }
};

/// Every list a script registered. Cleared with the Lua state.
pub const Store = struct {
    lists: std.ArrayListUnmanaged(List) = .empty,
    next_id: u32 = 1,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        self.clear(gpa);
        self.lists.deinit(gpa);
    }

    pub fn clear(self: *Store, gpa: Allocator) void {
        for (self.lists.items) |*l| freeList(gpa, l);
        self.lists.clearRetainingCapacity();
        self.next_id = 1;
    }

    /// Drop the lists ONE Lua state registered. The ids keep counting
    /// up, so a handle another state still holds stays valid.
    pub fn clearState(self: *Store, gpa: Allocator, state: u16) void {
        var i: usize = 0;
        while (i < self.lists.items.len) {
            if (self.lists.items[i].rows_fn.state == state) {
                freeList(gpa, &self.lists.items[i]);
                _ = self.lists.orderedRemove(i);
            } else i += 1;
        }
        if (self.lists.items.len == 0) self.next_id = 1;
    }

    fn freeList(gpa: Allocator, l: *List) void {
        gpa.free(l.title);
        freeRows(gpa, l.cache);
        for (l.sorts) |s| gpa.free(s);
        gpa.free(l.sorts);
        for (l.folded.items) |f| gpa.free(f);
        l.folded.deinit(gpa);
        l.panel.deinit(gpa);
    }
};

pub fn freeRows(gpa: Allocator, rows: []Row) void {
    for (rows) |r| {
        gpa.free(r.label);
        gpa.free(r.detail);
        gpa.free(r.icon);
        gpa.free(r.state);
    }
    gpa.free(rows);
}

pub fn find(app: *App, id: u32) ?*List {
    for (app.script_lists.lists.items) |*l| if (l.id == id) return l;
    return null;
}

/// Register a list; the caller owns nothing after this.
pub fn add(app: *App, title: []u8, rows_fn: LuaRef, on_enter: ?LuaRef, on_menu: ?LuaRef, sorts: [][]u8) Allocator.Error!u32 {
    const id = app.script_lists.next_id;
    app.script_lists.next_id += 1;
    try app.script_lists.lists.append(app.gpa, .{
        .id = id,
        .title = title,
        .rows_fn = rows_fn,
        .on_enter = on_enter,
        .on_menu = on_menu,
        .sorts = sorts,
    });
    return id;
}

/// Ask the script for its rows again. A failing call leaves the rows
/// that were there — a script that errors mid-edit does not blank the
/// panel the reader is looking at.
///
/// The rows fn lives in the state that registered the list — an
/// installed script's own, not `init.lua`'s (`App.luaState`, as a
/// script-owned command is run). Asking `init.lua`'s state to call a
/// ref from another registry tripped `pushRef`'s assert and took the
/// process down the moment the shipped `todo-list` was installed.
pub fn refresh(app: *App, l: *List) Allocator.Error!void {
    const lua = app.luaState(l.rows_fn.state) orelse return;
    const fresh = try lua.callListRows(l.rows_fn, l.sortLabel()) orelse return;
    freeRows(app.gpa, l.cache);
    l.cache = fresh;
    // A header the script no longer answers with stops being folded.
    var i: usize = 0;
    while (i < l.folded.items.len) {
        const still = for (l.cache) |r| {
            if (r.header and std.mem.eql(u8, r.label, l.folded.items[i])) break true;
        } else false;
        if (still) {
            i += 1;
        } else app.gpa.free(l.folded.orderedRemove(i));
    }
    app.needs_render = true;
}

/// The rows the panel paints: the filter applied, a collapsed header's
/// items dropped. Frame arena.
pub fn visible(app: *App, l: *List, arena: Allocator) Allocator.Error![]Row {
    _ = app;
    var out: std.ArrayListUnmanaged(Row) = .empty;
    const q = l.panel.filterText();
    var hidden = false;
    for (l.cache) |row| {
        if (row.header) {
            hidden = l.isFolded(row.label);
            // A filtered list is flat: a header whose items all went is
            // noise, so only headers with a surviving item are kept.
            if (q.len > 0) {
                if (!anyMatchUnder(l, row, q)) continue;
                hidden = false;
            }
            var copy = row;
            copy.collapsed = hidden;
            try out.append(arena, copy);
            continue;
        }
        if (hidden) continue;
        if (q.len > 0 and fuzzy.score(q, row.label) == null and fuzzy.score(q, row.detail) == null) continue;
        try out.append(arena, row);
    }
    return out.items;
}

fn anyMatchUnder(l: *const List, header: Row, q: []const u8) bool {
    var seen = false;
    for (l.cache) |row| {
        if (row.header) {
            if (seen) return false;
            seen = row.index == header.index;
            continue;
        }
        if (!seen) continue;
        if (fuzzy.score(q, row.label) != null or fuzzy.score(q, row.detail) != null) return true;
    }
    return false;
}

pub const DrawOpts = struct {
    panel: panel_mod.PanelId,
    /// Set when a pane hosts the list; null for a sidebar section.
    pane: ?PaneId = null,
    focused: ?bool = null,
};

pub fn draw(app: *App, ui: Ui, area: Rect, l: *List, opts: DrawOpts) Allocator.Error!?list_panel.Caret {
    const rows = try visible(app, l, ui.arena);
    var items: usize = 0;
    for (l.cache) |r| {
        if (!r.header) items += 1;
    }
    var shown: usize = 0;
    for (rows) |r| {
        if (!r.header) shown += 1;
    }
    const subtitle = if (shown == items) ui.fmt(" ({d})", .{items}) else ui.fmt(" ({d} of {d})", .{ shown, items });
    const empty: list_panel.EmptyState = if (items == 0)
        .{ .message = "Nothing to list yet.", .hint = "the script's rows() answered with none" }
    else
        .{ .message = "No matches — Esc clears" };
    return Panel.draw(&l.panel, ui, area, .{
        .panel = opts.panel,
        .label = l.title,
        .subtitle = subtitle,
        .sort_chip = l.sortLabel(),
        .sort_widest = l.sortWidest(),
        .rows = rows,
        .paintRow = view.paintRow,
        .has_kebab = l.on_menu != null,
        .empty = empty,
        .show_refresh = true,
        .filter_gap = true,
        .pane = opts.pane,
        .focused = opts.focused,
    });
}

/// Enter (or a second click) on a row: a header folds, an item goes to
/// the script's `on_enter(row)`.
pub fn activate(app: *App, l: *List, idx: usize) Allocator.Error!void {
    const rows = try visible(app, l, app.frame.allocator());
    if (idx >= rows.len) return;
    const row = rows[idx];
    if (row.header) return toggleFold(app, l, row.label);
    const on_enter = l.on_enter orelse return;
    const lua = app.luaState(on_enter.state) orelse return;
    lua.callRow(on_enter, l, row.index);
    app.needs_render = true;
}

pub fn toggleFold(app: *App, l: *List, label: []const u8) Allocator.Error!void {
    for (l.folded.items, 0..) |f, i| if (std.mem.eql(u8, f, label)) {
        app.gpa.free(l.folded.orderedRemove(i));
        app.needs_render = true;
        return;
    };
    try l.folded.append(app.gpa, try app.gpa.dupe(u8, label));
    app.needs_render = true;
}

/// The `sort:` chip: the next mode, and the rows again under it.
pub fn cycleSort(app: *App, l: *List) Allocator.Error!void {
    if (l.sorts.len == 0) return;
    l.sort_idx = (l.sort_idx + 1) % l.sorts.len;
    try refresh(app, l);
}

/// The keys the panel does not take: `r` refreshes, `E` / `C` open and
/// close every fold, `s` cycles the sort.
pub fn handleKey(app: *App, l: *List, k: Key) Allocator.Error!bool {
    switch (try Panel.handleKey(&l.panel, app.gpa, k)) {
        .consumed, .filter_changed => return true,
        .activate => |i| {
            try activate(app, l, i);
            return true;
        },
        .new_activate => return true,
        .ignored => {},
    }
    if (l.panel.filter_focused) return false;
    switch (k.code) {
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'r' => try refresh(app, l),
                's' => try cycleSort(app, l),
                'E' => {
                    for (l.folded.items) |f| app.gpa.free(f);
                    l.folded.clearRetainingCapacity();
                    app.needs_render = true;
                },
                'C' => {
                    for (l.cache) |row| if (row.header and !l.isFolded(row.label)) try l.folded.append(app.gpa, try app.gpa.dupe(u8, row.label));
                    app.needs_render = true;
                },
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

/// The row's menu: what the script's `on_menu(row)` answered, plus the
/// panel's own Refresh. A list with no `on_menu` has only the latter.
pub fn openRowMenu(app: *App, l: *List, idx: u32, x: u16, y: u16) Allocator.Error!void {
    const rows = try visible(app, l, app.frame.allocator());
    if (idx >= rows.len) return;
    const row = rows[idx];
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var out: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer out.deinit(app.gpa);
    if (row.header) {
        try out.append(app.gpa, .{
            .label = if (row.collapsed) "Expand" else "Collapse",
            .action = .{ .script_list_fold = .{ .list = l.id, .row = idx } },
        });
    } else if (l.on_menu) |fnref| {
        const labels: []const []const u8 = if (app.luaState(fnref.state)) |lua| try lua.callMenu(fnref, l, row.index, arena) else &.{};
        for (labels) |label| {
            try out.append(app.gpa, .{
                .label = label,
                .action = .{ .script_list_menu = .{ .list = l.id, .item = @intCast(out.items.len) } },
            });
        }
    }
    try out.append(app.gpa, .{ .label = "Refresh", .action = .{ .script_list_refresh = l.id }, .separator_before = out.items.len > 0 });
    const owned = try out.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    const title = try arena.dupe(u8, if (row.label.len > 0) row.label else l.title);
    try context_menus.openOwned(app, title, owned, x, y, mem);
}

/// The wheel over the list moves the cursor `step` rows.
pub fn wheel(app: *App, l: *List, down: bool, step: usize) Allocator.Error!void {
    const n = (try visible(app, l, app.frame.allocator())).len;
    l.panel.cursor = if (down) @min(l.panel.cursor + step, n -| 1) else l.panel.cursor -| step;
    app.needs_render = true;
}
