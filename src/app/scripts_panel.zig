//! The SCRIPTS section — the same three tabs the INTEGRATIONS section
//! has (`installed · marketplace · dev`), painted by the SAME view
//! (`ui/integrations_view.zig`'s `drawSection`, told which panel it is
//! painting) so the two can never drift apart: the caps header, the
//! tab strip, the filter pill with the sort chip at its right end, the
//! three-row entries and the scrollbar are one piece of code.
//!
//!   Installed    `init.lua` first, then every installed script — name,
//!                version, source badge, enabled state, and the second
//!                row naming the commands it adds. Enter opens its
//!                README (the file itself, for `init.lua`); the row menu
//!                is enable / disable / reload / update / remove / open
//!                folder / open README, and the jumps to what it
//!                registered (`file:line`, off `Lua.origins`).
//!   Marketplace  the curated set that ships with mnml — the repo's own
//!                `lua/`, packaged as `share/mnml/lua` beside the
//!                binary — read exactly as a `local_folder`
//!                integrations source is, so the tab has rows on a
//!                fresh data root with no config at all.
//!                `scripts.marketplace_local` (or
//!                `MNML_SCRIPTS_MARKETPLACE`) points it at a folder of
//!                the user's own instead.
//!   Dev          the folders under `scripts.dev_roots`, reloaded on
//!                save.
//!
//! The workspace's `.mnml/init.lua` is still one file with no `require`,
//! and the link row that creates it from the template is still the
//! Installed tab's first row when there is none.

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
const view = @import("../ui/integrations_view.zig");
const lua_mod = @import("../scripting/lua.zig");
const manifest_mod = @import("../scripting/manifest.zig");
const scripts = @import("scripts.zig");
const auto_refresh = @import("auto_refresh.zig");
const activity_bar = @import("activity_bar.zig");
const side = @import("side.zig");
const context_menus = @import("context_menus.zig");
const watch = @import("watch.zig");
const keymap = @import("../core/keymap.zig");
const Chord = @import("../core/key.zig").Chord;
const MenuItem = command.MenuItem;

pub const Tab = view.Tab;
pub const Panel = list_panel.ListPanel(view.Entry);

/// How the Installed and Dev tabs order their rows; the Marketplace
/// tab shares it. The chip cycles them.
pub const Sort = enum {
    name,
    source,
    state,

    pub fn next(s: Sort) Sort {
        return switch (s) {
            .name => .source,
            .source => .state,
            .state => .name,
        };
    }

    pub fn label(s: Sort) []const u8 {
        return switch (s) {
            .name => "A-Z",
            .source => "Source",
            .state => "State",
        };
    }

    pub const all = [_]Sort{ .name, .source, .state };

    /// Widest label, in code points — the header chip pads to it so it
    /// never resizes under a repeat-clicking pointer.
    pub const widest_label: usize = blk: {
        var w: usize = 0;
        for (all) |m| w = @max(w, std.unicode.utf8CountCodepoints(m.label()) catch unreachable);
        break :blk w;
    };
};

pub const State = struct {
    panel: Panel.State = .{},
    tab: Tab = .installed,
    tab_cursor: [3]usize = .{ 0, 0, 0 },
    tab_scroll: [3]usize = .{ 0, 0, 0 },
    sort: Sort = .name,
    /// `script.show_dev`'s answer for the session; null defers to the
    /// config and the roots.
    show_dev_override: ?bool = null,
    /// The marketplace listing, read from the index folder once and
    /// kept: a `readdir` plus a manifest parse per frame would be a
    /// file-system walk in the paint loop.
    market: []MarketEntry = &.{},
    market_arena: ?std.heap.ArenaAllocator = null,
    market_scanned: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.panel.deinit(gpa);
        if (self.market_arena) |*a| a.deinit();
    }
};

pub const table = .{
    .@"view.activity_scripts" = &activity,
    .@"script.new_init" = &newInit,
    .@"script.show_installed" = &showInstalledCmd,
    .@"script.show_marketplace" = &showMarketplaceCmd,
    .@"script.show_dev" = &showDevCmd,
    .@"script.toggle_tab" = &toggleTab,
    .@"script.marketplace_install" = &installFocusedMarket,
};

/// The link row's words.
pub const link_label = "+ create init.lua";
/// The Installed tab's first entry: the `init.lua` state itself.
pub const init_label = "init.lua";

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
    if (!app.scripts.scanned) try scripts.scan(app);
    if (!app.scripts_panel.market_scanned) try refreshMarket(app);
}

// ─── the rows ────────────────────────────────────────────────────────────

/// One row of a tab, before the filter and the sort. `entry` indexes
/// `app.scripts.entries`; `market` indexes the marketplace listing.
pub const Kind = union(enum) {
    /// The `+ create init.lua` link.
    link,
    /// The `init.lua` state itself — always the Installed tab's first.
    init_state,
    /// An installed / private / dev script.
    entry: u16,
    /// A marketplace row, by index into `marketRows`.
    market: usize,
};

pub const Row = struct {
    kind: Kind,
    entry: view.Entry,
};

/// The marketplace index: every directory with a `script.zon` under the
/// index folder, read the way a `local_folder` integrations source is.
pub const MarketEntry = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    api: u32,
    dir: []const u8,
    commands: []const []const u8,
    hooks: []const []const u8,
};

/// The cached listing, read on first use and on every refresh.
pub fn market(app: *App) []const MarketEntry {
    const st = &app.scripts_panel;
    if (!st.market_scanned) refreshMarket(app) catch {};
    return st.market;
}

/// Read the index folder again. Cheap to call on entering the section,
/// on a tab switch and on the refresh chip — never from a draw.
pub fn refreshMarket(app: *App) Allocator.Error!void {
    const st = &app.scripts_panel;
    var fresh = std.heap.ArenaAllocator.init(app.gpa);
    errdefer fresh.deinit();
    const rows_ = try marketRows(app, fresh.allocator());
    if (st.market_arena) |*a| a.deinit();
    st.market_arena = fresh;
    st.market = rows_;
    st.market_scanned = true;
}

/// Read the index folder — the shipped `lua/` set unless an override
/// names another (`scripts.marketplaceRoot`). Empty only when neither
/// is there.
pub fn marketRows(app: *App, arena: Allocator) Allocator.Error![]MarketEntry {
    var out: std.ArrayListUnmanaged(MarketEntry) = .empty;
    const root = try scripts.marketplaceRoot(app, arena);
    if (root.len == 0) return &.{};
    var d = Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true }) catch return &.{};
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        const dir = try std.fs.path.join(arena, &.{ root, ent.name });
        const path = try std.fs.path.join(arena, &.{ dir, manifest_mod.file_name });
        const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(64 * 1024), .of(u8), 0) catch continue;
        var why: []const u8 = "";
        const m = manifest_mod.parse(arena, text, &why) catch continue;
        try out.append(arena, .{
            .name = m.name,
            .version = m.version,
            .description = m.description,
            .author = m.author,
            .api = m.api,
            .dir = dir,
            .commands = m.commands,
            .hooks = m.hooks,
        });
    }
    std.mem.sort(MarketEntry, out.items, {}, struct {
        fn lt(_: void, a: MarketEntry, b: MarketEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

fn commandsLine(arena: Allocator, cmds: []const []const u8) Allocator.Error![]const u8 {
    if (cmds.len == 0) return "no commands";
    return std.mem.join(arena, ", ", cmds);
}

/// Whether the Dev tab shows: the session's toggle, else the config and
/// the roots.
pub fn showDev(app: *App) bool {
    if (app.scripts_panel.show_dev_override) |v| return v;
    if (app.cfg.scripts.show_dev_tab) return true;
    if (app.cfg.scripts.dev_roots.len > 0) return true;
    const v = app.env.get("MNML_SCRIPTS_DEV_ROOTS") orelse return false;
    return v.len > 0;
}

fn badgeFor(e: *const scripts.Entry) view.Badge {
    if (!e.enabled) return .disabled;
    return switch (e.source) {
        .marketplace => .official,
        .community => .community,
        .private => .private,
        .dev => .dev,
    };
}

/// Every row of the active tab, after the filter and the sort. On
/// `arena`.
pub fn rows(app: *App, arena: Allocator) Allocator.Error![]Row {
    const st = &app.scripts_panel;
    const q = st.panel.filterText();
    var out: std.ArrayListUnmanaged(Row) = .empty;
    switch (st.tab) {
        .installed => {
            if (q.len == 0 and !exists(app, try workspaceInit(app))) try out.append(arena, .{ .kind = .link, .entry = .{
                .kind = .installed,
                .label = link_label,
                .line2 = "the workspace has no script yet",
            } });
            // `init.lua` is a script too: one state, one row.
            const lua = app.script();
            const s = lua.summary();
            if (q.len == 0 or fuzzy.score(q, init_label) != null) try out.append(arena, .{ .kind = .init_state, .entry = .{
                .kind = .installed,
                .label = init_label,
                .version = try std.fmt.allocPrint(arena, "api {d}", .{manifest_mod.api_version}),
                .badge = .installed_here,
                .budget_hits = lua.budget_hits,
                .line2 = try std.fmt.allocPrint(arena, "{d} command(s), {d} hook(s), {d} segment(s), {d} source(s)", .{ s.commands, s.hooks, s.segments, s.sources }),
            } });
            for (app.scripts.entries.items) |*e| {
                if (e.source == .dev) continue;
                if (q.len > 0 and fuzzy.score(q, e.name) == null and fuzzy.score(q, e.description) == null) continue;
                try out.append(arena, .{ .kind = .{ .entry = e.id }, .entry = try installedRow(app, arena, e) });
            }
        },
        .marketplace => {
            for (market(app), 0..) |m, i| {
                if (q.len > 0 and fuzzy.score(q, m.name) == null and fuzzy.score(q, m.description) == null) continue;
                const installed = app.scripts.find(m.name) != null;
                try out.append(arena, .{ .kind = .{ .market = i }, .entry = .{
                    .kind = .installed,
                    .label = m.name,
                    .version = m.version,
                    .badge = .official,
                    .dim = installed,
                    .source = if (installed) "installed" else "",
                    .line2 = if (m.description.len > 0) m.description else try commandsLine(arena, m.commands),
                } });
            }
        },
        .dev => {
            for (app.scripts.entries.items) |*e| {
                if (e.source != .dev) continue;
                if (q.len > 0 and fuzzy.score(q, e.name) == null) continue;
                try out.append(arena, .{ .kind = .{ .entry = e.id }, .entry = try installedRow(app, arena, e) });
            }
        },
    }
    const sort = st.sort;
    std.mem.sort(Row, out.items, sort, struct {
        fn lt(mode: Sort, a: Row, b: Row) bool {
            // The link and `init.lua` stay pinned at the top whatever
            // the sort: they are the workspace's own, not a listing.
            const ra = rank(a);
            const rb = rank(b);
            if (ra != rb) return ra < rb;
            return switch (mode) {
                .name => std.mem.lessThan(u8, a.entry.label, b.entry.label),
                .source => std.mem.order(u8, badgeText(a), badgeText(b)) == .lt,
                .state => stateRank(a) < stateRank(b),
            };
        }
        fn rank(r: Row) u8 {
            return switch (r.kind) {
                .link => 0,
                .init_state => 1,
                else => 2,
            };
        }
        fn badgeText(r: Row) []const u8 {
            return if (r.entry.badge) |b| b.text(true) else "";
        }
        fn stateRank(r: Row) u8 {
            return if (r.entry.badge == .disabled) 1 else 0;
        }
    }.lt);
    return out.items;
}

fn installedRow(app: *App, arena: Allocator, e: *scripts.Entry) Allocator.Error!view.Entry {
    // // changed (lua-polish): the budget overruns were words on the
    // second row, competing with the command list for a narrow column.
    // They are the `⏱ N` chip on the label row now — one shape, next to
    // the badge, and `script.doctor` still spells it out.
    const line2: []const u8 = if (e.err) |m|
        try std.fmt.allocPrint(arena, "error: {s}", .{m[0 .. std.mem.indexOfScalar(u8, m, '\n') orelse m.len]})
    else
        try commandsLine(arena, @ptrCast(e.commands));
    _ = app;
    return .{
        .kind = .installed,
        .label = e.name,
        .version = e.version,
        .badge = badgeFor(e),
        .dim = !e.enabled,
        .missing = if (!e.supported()) try std.fmt.allocPrint(arena, "script api {d}", .{e.api}) else null,
        .budget_hits = if (e.state) |l| l.budget_hits else 0,
        .line2 = line2,
    };
}

/// The entry the cursor is on, when the row is a script.
pub fn focusedEntry(app: *App) ?*scripts.Entry {
    const st = &app.scripts_panel;
    const list = rows(app, app.frame.allocator()) catch return null;
    if (st.panel.cursor >= list.len) return null;
    return switch (list[st.panel.cursor].kind) {
        .entry => |id| for (app.scripts.entries.items) |*e| {
            if (e.id == id) break e;
        } else null,
        else => null,
    };
}

// ─── drawing ─────────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.scripts_panel;
    if (!app.scripts.scanned) scripts.scan(app) catch {};
    const list = try rows(app, ui.arena);
    const entries = try ui.arena.alloc(view.Entry, list.len);
    for (list, 0..) |r, i| entries[i] = r.entry;
    st.panel.total = list.len;
    st.panel.visible = @max((area.h -| view.body_top) + 1, 1) / view.rows_per_entry;
    if (st.panel.cursor >= list.len) st.panel.cursor = list.len -| 1;
    const q = st.panel.filterText();
    var installed_count: usize = 1; // init.lua
    var dev_count: usize = 0;
    for (app.scripts.entries.items) |e| {
        if (e.source == .dev) dev_count += 1 else installed_count += 1;
    }
    const listing = market(app);
    const empty: list_panel.EmptyState = if (q.len > 0)
        .{ .message = ui.fmt("No matches for \"{s}\" — Esc clears", .{q}) }
    else switch (st.tab) {
        .installed => .{ .message = "No scripts installed yet — try the Marketplace tab", .hint = "script.install takes a git URL, an archive or a folder" },
        .marketplace => .{
            .message = "No scripts in the marketplace index",
            .hint = "the curated set ships with mnml as share/mnml/lua beside the binary; scripts.marketplace_local names another folder",
        },
        .dev => .{ .message = "No dev folders — nothing under scripts.dev_roots", .hint = "a folder is a script.zon with an init.lua beside it" },
    };
    const caret = view.drawSection(ui, area, .{
        .panel = .scripts,
        .label = "SCRIPTS",
        .tabs_at = view.script_tab_base,
        .tab = st.tab,
        .counts = .{ installed_count, listing.len, dev_count },
        .show_dev = showDev(app),
        .filter = q,
        .filter_caret = st.panel.filter_caret,
        .filter_focused = st.panel.filter_focused,
        .sort_label = st.sort.label(),
        .sort_widest = Sort.widest_label,
        .rows = entries,
        .scroll = &st.panel.scroll,
        .cursor = st.panel.cursor,
        .focused = ui.isFocused(.{ .panel = .scripts }),
        .empty = empty,
        .now_ms = app.now_ms,
    });
    if (caret) |c| if (app.focus == .panel and app.focus.panel == .scripts) {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

// ─── the tabs ────────────────────────────────────────────────────────────

pub fn setTab(app: *App, tab: Tab) void {
    const st = &app.scripts_panel;
    if (st.tab == tab) return;
    st.tab_cursor[@intFromEnum(st.tab)] = st.panel.cursor;
    st.tab_scroll[@intFromEnum(st.tab)] = st.panel.scroll;
    st.tab = tab;
    st.panel.cursor = st.tab_cursor[@intFromEnum(tab)];
    st.panel.scroll = st.tab_scroll[@intFromEnum(tab)];
    app.needs_render = true;
}

pub fn showTab(app: *App, tab: Tab) CommandError!void {
    try activity(app);
    if (tab == .dev) app.scripts_panel.show_dev_override = true;
    if (tab == .marketplace) try refreshMarket(app);
    setTab(app, tab);
    focusPanel(app);
}

fn showInstalledCmd(app: *App) CommandError!void {
    return showTab(app, .installed);
}

fn showMarketplaceCmd(app: *App) CommandError!void {
    return showTab(app, .marketplace);
}

fn showDevCmd(app: *App) CommandError!void {
    return showTab(app, .dev);
}

fn toggleTab(app: *App) CommandError!void {
    const st = &app.scripts_panel;
    if (!side.isShown(app, .scripts)) return showTab(app, .installed);
    setTab(app, st.tab.next(showDev(app)));
}

/// What `i` installs: on the Marketplace tab with a shipped row focused,
/// THAT row (its trust dialog) — the prompt for a git URL, an archive or
/// a folder is the wrong question over a row that already names the
/// script. Anywhere else, the prompt.
fn installKey(app: *App) command.CommandId {
    const st = &app.scripts_panel;
    if (st.tab != .marketplace) return .@"script.install";
    const list = rows(app, app.frame.allocator()) catch return .@"script.install";
    if (st.panel.cursor >= list.len) return .@"script.install";
    return switch (list[st.panel.cursor].kind) {
        .market => .@"script.marketplace_install",
        else => .@"script.install",
    };
}

/// `script.marketplace_install`: the focused Marketplace row, staged and
/// then put in front of the trust dialog like any other source.
fn installFocusedMarket(app: *App) CommandError!void {
    const st = &app.scripts_panel;
    if (st.tab != .marketplace) return app.diag.fail(app.frame.allocator(), "scripts: open the Marketplace tab first", .{});
    const arena = app.frame.allocator();
    const list = try rows(app, arena);
    if (st.panel.cursor >= list.len) return app.diag.fail(arena, "scripts: no marketplace row is focused", .{});
    const idx = switch (list[st.panel.cursor].kind) {
        .market => |i| i,
        else => return app.diag.fail(arena, "scripts: no marketplace row is focused", .{}),
    };
    const listing = market(app);
    if (idx >= listing.len) return;
    const dir = try arena.dupe(u8, listing[idx].dir);
    try scripts.promptTrust(app, dir, .marketplace);
}

// ─── keys and the mouse ──────────────────────────────────────────────────

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("scripts: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

/// Enter: the link creates the file, `init.lua` opens it, a script row
/// opens its README, a marketplace row installs it.
fn activateRow(app: *App, i: usize) CommandError!void {
    const arena = app.frame.allocator();
    const list = try rows(app, arena);
    if (i >= list.len) return;
    switch (list[i].kind) {
        .link => return newInit(app),
        .init_state => {
            const path = try workspaceInit(app);
            if (!exists(app, path)) return newInit(app);
            const id = app.openPath(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return app.diag.fail(arena, "cannot open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
            };
            app.showPane(id);
            app.focus = .{ .pane = id };
        },
        .entry => return command.run(app, .{ .static = .@"script.open_readme" }),
        .market => return installFocusedMarket(app),
    }
}

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.scripts_panel;
    switch (try Panel.handleKey(&st.panel, app.gpa, k)) {
        .consumed => {
            app.needs_render = true;
            return true;
        },
        .filter_changed => {
            st.panel.cursor = 0;
            app.needs_render = true;
            return true;
        },
        .activate => |i| {
            runToast(app, activateRow(app, i));
            return true;
        },
        .new_activate => return true,
        .ignored => {},
    }
    if (st.panel.filter_focused) return false;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .tab => setTab(app, st.tab.next(showDev(app))),
        .backtab => setTab(app, st.tab.prev(showDev(app))),
        .left => setTab(app, st.tab.prev(showDev(app))),
        .right => setTab(app, st.tab.next(showDev(app))),
        .char => |c| switch (c) {
            'h' => setTab(app, st.tab.prev(showDev(app))),
            'l' => setTab(app, st.tab.next(showDev(app))),
            '1' => setTab(app, .installed),
            '2' => setTab(app, .marketplace),
            '3' => if (showDev(app)) setTab(app, .dev) else return false,
            'r' => runToast(app, refreshTab(app)),
            's' => {
                st.sort = st.sort.next();
            },
            'n' => runToast(app, newInit(app)),
            'i' => runToast(app, command.run(app, .{ .static = installKey(app) })),
            'e' => runToast(app, command.run(app, .{ .static = .@"script.toggle_enabled" })),
            'x' => runToast(app, command.run(app, .{ .static = .@"script.remove" })),
            'd' => runToast(app, command.run(app, .{ .static = .@"script.doctor" })),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// The refresh chip's action for the active tab.
fn refreshTab(app: *App) CommandError!void {
    switch (app.scripts_panel.tab) {
        .installed => {
            try command.run(app, .{ .static = .@"script.reload" });
            try scripts.reloadAll(app);
        },
        .marketplace, .dev => {
            try refreshMarket(app);
            try scripts.scan(app);
            app.toast("scripts: {d} installed", .{app.scripts.entries.items.len});
        },
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .scripts };
    app.needs_render = true;
}

/// A tab's `.button` hit.
pub fn tabMouse(app: *App, tab: Tab, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    setTab(app, tab);
}

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.scripts_panel;
    switch (m.kind) {
        .press => {
            focusPanel(app);
            const was = st.panel.cursor;
            st.panel.cursor = idx;
            if (m.button == .right) return openRowMenu(app, idx, m.x, m.y);
            if (m.button == .left and was == idx) runToast(app, activateRow(app, idx));
        },
        else => {},
    }
}

/// The wheel over the list moves the cursor `step` rows.
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

/// A row's menu. A script row: enable / disable, reload, update,
/// remove, open folder, open README, then a jump per registration
/// (`Lua.origins`, the `file:line` of the `mnml.*` call). The
/// `init.lua` row: create / open, and the same jumps. A marketplace
/// row: Install.
pub fn openRowMenu(app: *App, idx: u32, x: u16, y: u16) Allocator.Error!void {
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len) return;
    const row = list[idx];
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var out: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer out.deinit(app.gpa);
    var title: []const u8 = row.entry.label;
    switch (row.kind) {
        .link => try out.append(app.gpa, .{ .label = "Create init.lua", .action = .{ .command = .@"script.new_init" } }),
        .init_state => {
            title = init_label;
            try out.append(app.gpa, .{ .label = "Open init.lua", .action = .{ .command = .@"script.new_init" } });
            try out.append(app.gpa, .{ .label = "Reload scripts", .action = .{ .command = .@"script.reload" } });
            try appendOrigins(app, arena, &out, app.script());
        },
        .entry => |id| {
            for (app.scripts.entries.items) |*e| {
                if (e.id != id) continue;
                title = try arena.dupe(u8, e.name);
                try out.append(app.gpa, .{ .label = if (e.enabled) "Disable" else "Enable", .action = .{ .command = .@"script.toggle_enabled" } });
                try out.append(app.gpa, .{ .label = "Reload", .action = .{ .command = .@"script.reload_one" } });
                if (e.url.len > 0) try out.append(app.gpa, .{ .label = "Update", .action = .{ .command = .@"script.update" } });
                if (e.source != .dev) try out.append(app.gpa, .{ .label = "Remove\u{2026}", .action = .{ .command = .@"script.remove" } });
                try out.append(app.gpa, .{ .label = "Open folder", .action = .{ .command = .@"script.open_folder" }, .separator_before = true });
                try out.append(app.gpa, .{ .label = "Open README", .action = .{ .command = .@"script.open_readme" } });
                try out.append(app.gpa, .{ .label = "Copy name", .action = .{ .copy_text = try arena.dupe(u8, e.name) } });
                if (e.state) |l| try appendOrigins(app, arena, &out, l);
            }
        },
        .market => {
            try out.append(app.gpa, .{ .label = "Install\u{2026}", .action = .{ .command = .@"script.marketplace_install" } });
            try out.append(app.gpa, .{ .label = "Copy name", .action = .{ .copy_text = try arena.dupe(u8, row.entry.label) } });
        },
    }
    try out.append(app.gpa, .{ .label = "Script doctor", .action = .{ .command = .@"script.doctor" }, .separator_before = true });
    const owned = try out.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, title, owned, x, y, mem);
}

/// One `Open <name> (<file>:<line>)` per registration of `l`, capped so
/// a script with fifty commands does not make a menu fifty rows long.
fn appendOrigins(app: *App, arena: Allocator, out: *std.ArrayListUnmanaged(MenuItem), l: *lua_mod.Lua) Allocator.Error!void {
    var n: usize = 0;
    for (l.origins.items, 0..) |o, i| {
        if (o.file.len == 0 or n >= 8) continue;
        const label = try std.fmt.allocPrint(arena, "Open {s} {s} ({s}:{d})", .{ o.kind.label(), o.name, app.relPath(o.file), o.line });
        try out.append(app.gpa, .{ .label = label, .action = .{ .script_row_open = @intCast(originKey(l.id, @intCast(i))) }, .separator_before = n == 0 });
        n += 1;
    }
}

/// `script_row_open`'s payload: the state in the high bits, the origin
/// index in the low ones, so one action id reaches any state's rows.
pub fn originKey(state: u16, index: u16) u32 {
    return (@as(u32, state) << 16) | index;
}

/// The row menu's Open: jump to the `file:line` the origin names.
pub fn openRowIndex(app: *App, key: u32) Allocator.Error!void {
    const state: u16 = @intCast(key >> 16);
    const index: usize = @intCast(key & 0xffff);
    const l = app.luaState(state) orelse return;
    if (index >= l.origins.items.len) return;
    const o = l.origins.items[index];
    if (o.file.len == 0) return;
    const path = try app.frame.allocator().dupe(u8, o.file);
    const line = o.line;
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("cannot open {s}: {s}", .{ app.relPath(path), @errorName(err) });
            return;
        },
    };
    if (app.panes.editor(id)) |e| {
        e.buf.editor.anchor = null;
        e.buf.editor.placeCursor(@min(line -| 1, e.buf.editor.lineCount() -| 1), 0);
        e.view.scroll_line = @intCast(e.buf.editor.currentLine() -| app.pane_rows / 2);
    }
    app.showPane(id);
    app.focus = .{ .pane = id };
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

/// The header's refresh chip: a click reloads the active tab; a
/// right-click is the refresh menu. The sort chip cycles.
pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    const st = &app.scripts_panel;
    switch (kind) {
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .scripts, m.x, m.y) else runToast(app, refreshTab(app)),
        .sort => {
            if (m.button == .right) return openSortMenu(app, m.x, m.y);
            st.sort = st.sort.next();
            app.needs_render = true;
        },
        .new, .view, .history => {},
    }
}

/// The sort chip's right-click: every mode with a ✓ on the live one.
pub fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var out: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer out.deinit(app.gpa);
    for ([_]Sort{ .name, .source, .state }) |s| {
        const mark: []const u8 = if (s == app.scripts_panel.sort) "\u{2713} " else "  ";
        try out.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "{s}{s}", .{ mark, s.label() }), .action = .{ .script_sort = @intFromEnum(s) } });
    }
    const owned = try out.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, "Sort", owned, x, y, mem);
}

pub fn setSort(app: *App, s: Sort) void {
    app.scripts_panel.sort = s;
    app.needs_render = true;
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

fn writeScript(dir: Io.Dir, io: Io, root: []const u8, name: []const u8, zon: []const u8, lua: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, name });
    try dir.createDirPath(io, d);
    var p: [std.fs.max_path_bytes]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&p, "{s}/script.zon", .{d}), .data = zon });
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&p, "{s}/init.lua", .{d}), .data = lua });
}

test "SCRIPTS: three tabs — Installed lists init.lua and each script, Marketplace reads the index folder, Dev lists the dev roots" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "data/scripts", "blamer",
        \\.{ .name = "blamer", .api = 1, .version = "1.2.0", .commands = .{ "user.blame" }, .source = .community }
    ,
        \\mnml.command{ id = "blame", run = function() end }
    );
    try writeScript(tmp.dir, t.io, "index", "tidy",
        \\.{ .name = "tidy", .api = 1, .version = "0.9.0", .description = "Tidies things", .source = .marketplace }
    ,
        \\mnml.command{ id = "tidy", run = function() end }
    );
    try writeScript(tmp.dir, t.io, "dev", "wip",
        \\.{ .name = "wip", .api = 1, .version = "0.0.1" }
    ,
        \\mnml.command{ id = "wip", run = function() end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var cfg: @import("../config/Config.zig") = .{};
    cfg.scripts.dev_roots = &.{"dev"};
    cfg.scripts.marketplace_local = "index";
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    try t.expectEqual(side.Section.scripts, side.shown(&app, .left).?);

    // Installed: the tab strip with all three counts, `init.lua` first,
    // then the script with its version and badge.
    var txt = try screenText(&app);
    try t.expect(std.mem.indexOf(u8, txt, "SCRIPTS") != null);
    // The shipped default `tree_width = 30` leaves 26 cells, which is
    // the compact tier: `Inst (2) Mkt (1)  <dev glyph> (1)`.
    try t.expect(std.mem.indexOf(u8, txt, "Inst (2) Mkt (1)") != null);
    // The sort control is the header's chip — the icon rung at 26 cells
    // — never a pill at the right end of the filter row, which is what
    // this section used to paint and no other section does.
    try t.expect(std.mem.indexOf(u8, txt, "A-Z") == null);
    try t.expect(std.mem.indexOf(u8, txt, "\u{F0349} / filter") != null);
    try t.expect(std.mem.indexOf(u8, txt, "init.lua") != null);
    try t.expect(std.mem.indexOf(u8, txt, "blamer") != null);
    try t.expect(std.mem.indexOf(u8, txt, "1.2.0") != null);
    try t.expect(std.mem.indexOf(u8, txt, "user.blame") != null);
    t.allocator.free(txt);
    // A wide column gets the full tier and the whole badge; the counts
    // are the same.
    app.tree.width = 46;
    txt = try screenText(&app);
    try t.expect(std.mem.indexOf(u8, txt, "Installed (2) Marketplace (1)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "~ Community") != null);
    // Wide enough, the chip's full rung reads ` sort: A-Z    ` — padded
    // to `State` / `Source`, the widest labels, so it never resizes.
    try t.expect(std.mem.indexOf(u8, txt, " sort: A-Z    ") != null);
    t.allocator.free(txt);
    app.tree.width = 30;

    // `l` cycles to Marketplace: the index folder's entry, not installed.
    try app.handle(.{ .key = Key.char('l') });
    try t.expectEqual(Tab.marketplace, app.scripts_panel.tab);
    txt = try screenText(&app);
    try t.expect(std.mem.indexOf(u8, txt, "tidy") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Tidies things") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Official") != null);
    t.allocator.free(txt);

    // `l` again: Dev, with the folder under `scripts.dev_roots`.
    try app.handle(.{ .key = Key.char('l') });
    try t.expectEqual(Tab.dev, app.scripts_panel.tab);
    txt = try screenText(&app);
    try t.expect(std.mem.indexOf(u8, txt, "wip") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Dev") != null);
    t.allocator.free(txt);

    // Installing the marketplace row: the trust dialog, then the copy.
    try app.handle(.{ .key = Key.char('2') });
    try t.expectEqual(Tab.marketplace, app.scripts_panel.tab);
    app.scripts_panel.panel.cursor = 0;
    try command.run(&app, .{ .static = .@"script.marketplace_install" });
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "tidy 0.9.0") != null);
    try app.handle(.{ .key = Key.char('i') });
    const installed = app.scripts.find("tidy").?;
    try t.expectEqual(manifest_mod.Source.marketplace, installed.source);
    try t.expect(app.dyn_commands.get("user.tidy") != null);
    // And the Marketplace row now says it is installed: dimmed, with
    // `(installed)` after the badge.
    const mkt = try rows(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 1), mkt.len);
    try t.expect(mkt[0].entry.dim);
    try t.expectEqualStrings("installed", mkt[0].entry.source);
}

test "SCRIPTS: `i` on a Marketplace row installs that row; elsewhere it asks for a source" {
    // `i` was `script.install` on every tab: over a shipped row it asked
    // for a git URL, an archive or a folder instead of installing it.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "index", "tidy",
        \\.{ .name = "tidy", .api = 1, .version = "0.9.0", .description = "Tidies things", .source = .marketplace }
    ,
        \\mnml.command{ id = "tidy", run = function() end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var cfg: @import("../config/Config.zig") = .{};
    cfg.scripts.marketplace_local = "index";
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .data_root = data, .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    focusPanel(&app);
    // Installed tab: the source prompt.
    try app.handle(.{ .key = Key.char('i') });
    try t.expect(app.overlay == .prompt);
    try app.handle(.{ .key = Key.named(.esc) });
    focusPanel(&app);
    // Marketplace tab, the shipped row focused: its trust dialog.
    try app.handle(.{ .key = Key.char('2') });
    try t.expectEqual(Tab.marketplace, app.scripts_panel.tab);
    app.scripts_panel.panel.cursor = 0;
    try app.handle(.{ .key = Key.char('i') });
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "tidy 0.9.0") != null);
}

test "SCRIPTS: a row's menu enables, disables, reloads and jumps to what the script registered" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "data/scripts", "hello",
        \\.{ .name = "hello", .api = 1, .version = "1.0.0", .commands = .{ "user.hello" } }
    ,
        \\mnml.command{ id = "hello", run = function() mnml.toast("hi") end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    // Row 0 is the link (no workspace init.lua), 1 is init.lua, 2 the script.
    const list = try rows(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 3), list.len);
    try t.expect(list[0].kind == .link);
    try t.expect(list[1].kind == .init_state);
    try t.expect(list[2].kind == .entry);
    app.scripts_panel.panel.cursor = 2;
    try t.expectEqualStrings("hello", focusedEntry(&app).?.name);

    try openRowMenu(&app, 2, 5, 5);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("hello", app.overlay.menu.title);
    const items = app.overlay.menu.items;
    try t.expectEqualStrings("Disable", items[0].label);
    try t.expectEqualStrings("Reload", items[1].label);
    try t.expectEqualStrings("Remove…", items[2].label);
    try t.expectEqualStrings("Open folder", items[3].label);
    try t.expectEqualStrings("Open README", items[4].label);
    // The jump rows carry the registration's file and line.
    var jump: ?usize = null;
    for (items, 0..) |it, i| if (std.mem.startsWith(u8, it.label, "Open command user.hello (")) {
        jump = i;
    };
    try t.expect(jump != null);
    try t.expect(std.mem.endsWith(u8, items[jump.?].label, "init.lua:1)"));
    try app.handle(.{ .key = Key.named(.esc) });

    // Disable through the command the menu row fires.
    try command.run(&app, .{ .static = .@"script.toggle_enabled" });
    try t.expect(app.dyn_commands.get("user.hello") == null);
    try t.expectEqualStrings("scripts: hello disabled", app.lastToast().?);
    try tmp.dir.access(t.io, "data/scripts/hello/.disabled", .{});
    // The row says so.
    const off = try rows(&app, app.frame.allocator());
    try t.expectEqual(@import("../ui/integrations_view.zig").Badge.disabled, off[2].entry.badge.?);
    try command.run(&app, .{ .static = .@"script.toggle_enabled" });
    try t.expect(app.dyn_commands.get("user.hello") != null);

    // The jump opens the file at the line.
    try openRowMenu(&app, 2, 5, 5);
    var key: u32 = 0;
    for (app.overlay.menu.items) |it| if (it.action == .script_row_open) {
        key = it.action.script_row_open;
    };
    try app.handle(.{ .key = Key.named(.esc) });
    try openRowIndex(&app, key);
    try t.expect(std.mem.endsWith(u8, app.activeEditor().?.buf.doc.path.?, "data/scripts/hello/init.lua"));
    try t.expectEqual(@as(usize, 0), app.activeEditor().?.buf.editor.currentLine());
}

test "SCRIPTS: a script that tripped the budget wears a ⏱ N chip, at the shipped tree_width and wider" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "data/scripts", "spinner",
        \\.{ .name = "spinner", .api = 1, .version = "1.0.0", .commands = .{ "user.spin" } }
    ,
        \\mnml.command{ id = "spin", run = function() while true do end end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    // The SHIPPED default: `ui.tree_width = 30` leaves the column 26
    // cells, which the label, version and badge already fill. The chip
    // is painted at the right edge and its cells come out of the run
    // first, so this is the width it has to survive.
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 120, .rows = 40 });
    defer app.deinit();
    try t.expectEqual(@as(u16, 30), app.cfg.ui.tree_width);
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    // Nothing has run: no chip on any row.
    {
        const list = try rows(&app, app.frame.allocator());
        for (list) |r| try t.expectEqual(@as(u32, 0), r.entry.budget_hits);
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, view.budget_glyph) == null);
    }
    // One runaway command is one toast and one chip — on the script's
    // row, not on `init.lua`'s.
    try t.expectError(error.Failed, command.run(&app, .{ .dyn = app.dyn_commands.get("user.spin").? }));
    {
        const list = try rows(&app, app.frame.allocator());
        var chipped: usize = 0;
        for (list) |r| if (r.entry.budget_hits > 0) {
            try t.expectEqualStrings("spinner", r.entry.label);
            try t.expectEqual(@as(u32, 1), r.entry.budget_hits);
            chipped += 1;
        };
        try t.expectEqual(@as(usize, 1), chipped);
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, view.budget_glyph ++ " 1") != null);
    }
    // It counts up, and the chip follows.
    try t.expectError(error.Failed, command.run(&app, .{ .dyn = app.dyn_commands.get("user.spin").? }));
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, view.budget_glyph ++ " 2") != null);
    }
    // `--ascii` has its own twin rather than a hole where the chip was.
    app.cfg.ui.ascii_icons = true;
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, view.budget_glyph) == null);
        try t.expect(std.mem.indexOf(u8, txt, view.budget_ascii ++ "2") != null);
    }
    // And a wide column keeps it, with the badge on screen beside it.
    app.cfg.ui.ascii_icons = false;
    app.tree.width = 64;
    {
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try t.expect(std.mem.indexOf(u8, txt, view.budget_glyph ++ " 2") != null);
        try t.expect(std.mem.indexOf(u8, txt, "Community") != null);
    }
}
