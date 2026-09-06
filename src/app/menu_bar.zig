//! The menu bar — the Rust editor's ten menus (the `❯_  mnml` brand menu,
//! then File / Edit / Selection / View / Go / Run / Terminal / Window /
//! Help) as words on the chrome row; `ui/menu_bar.zig` paints them. A
//! click drops the menu below its word; every row is a registered
//! command (an enum — a row cannot name an id that does not exist), its
//! first chord under the active profile as the row's hint, Rust's glyph
//! in the icon column. Words that do not fit before the centred
//! workspace chip collapse behind a ` » ` chip whose menu lists them.
//!
//! `ui.menu_bar`: `always` paints the words, `hidden` does not, `auto`
//! paints them while a menu is open or the pointer is on the row.
//! Keyboard: F10 opens File, Alt+<letter> the menu with that initial,
//! ← / → step between menus while one is open (`view.menu_bar_open`
//! opens File from the palette; `view.menu_bar_cycle` steps the setting).
//!
//! The rows are built per open — the File menu's recent-files submenu
//! and the hints live on `State.mem` until the next open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const keymap = @import("../core/keymap.zig");
const key_mod = @import("../core/key.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const settings = @import("settings.zig");
const render = @import("render.zig");
const search_glyph = @import("../ui/menu_bar.zig").search_glyph;

pub const table = .{
    .@"view.menu_bar_cycle" = &cycleCmd,
    .@"view.menu_bar_open" = &openFirstCmd,
};

pub const Menu = enum(u8) {
    brand,
    file,
    edit,
    selection,
    view,
    go,
    run,
    terminal,
    window,
    help,

    /// The word on the bar. The brand's is the prompt mark and the
    /// wordmark, as the Rust editor paints it.
    pub fn label(m: Menu) []const u8 {
        return labels[@intFromEnum(m)];
    }

    /// The dropdown's title: the wordmark alone for the brand.
    pub fn title(m: Menu) []const u8 {
        return if (m == .brand) "mnml" else m.label();
    }

    /// The Alt+<letter> accelerator: the label's first ASCII letter.
    pub fn accelerator(m: Menu) u8 {
        for (m.label()) |c| if (std.ascii.isAlphabetic(c)) return std.ascii.toLower(c);
        return 0;
    }

    pub const all = std.enums.values(Menu);
    pub const count = all.len;
};

/// The words in bar order — what the painter is handed.
pub const labels = [Menu.count][]const u8{ "❯_  mnml", "File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Window", "Help" };

/// `Button` ids for the words: `button_base + @intFromEnum(menu)`; the
/// ` » ` overflow chip is the next id.
pub const button_base: u32 = 0x6d62_0000;
pub const overflow_button: u32 = button_base + Menu.count;

pub fn buttonOf(id: u32) ?Menu {
    if (id < button_base or id >= button_base + Menu.count) return null;
    return @enumFromInt(id - button_base);
}

pub const State = struct {
    /// The menu that is open, if one is.
    open: ?Menu = null,
    /// Where each word painted last frame; null when it was hidden.
    word_x: [Menu.count]?u16 = @splat(null),
    /// The first word hidden behind the ` » ` last frame, if any.
    first_hidden: ?u8 = null,
    /// Where the words ended last frame — a hidden menu drops there.
    words_end: u16 = 0,
    /// The row the bar painted on (the dropdown goes under it).
    bar_y: u16 = 0,
    /// Owns the rows built per open: the recent-files submenu, the hints.
    mem: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *State) void {
        if (s.mem) |*m| m.deinit();
        s.mem = null;
    }
};

/// Whether the words paint this frame on the bar at `bar_y`.
pub fn shown(app: *const App, bar_y: u16) bool {
    return switch (app.cfg.ui.menu_bar) {
        .always => true,
        .hidden => false,
        .auto => app.menu_bar.open != null or (app.hover != null and app.hover.?.y == bar_y),
    };
}

/// What the painter reports back: where the words landed.
pub fn notePainted(app: *App, bar_y: u16, word_x: []const ?u16, first_hidden: ?usize, words_end: u16) void {
    const s = &app.menu_bar;
    s.bar_y = bar_y;
    s.words_end = words_end;
    s.first_hidden = if (first_hidden) |i| @intCast(i) else null;
    for (&s.word_x, 0..) |*x, i| x.* = if (i < word_x.len) word_x[i] else null;
}

// ─── the rows ───────────────────────────────────────────────────────────

/// The rows carry Rust's glyph, each with the one-character twin
/// `--ascii` paints, the label and the command.
fn sep(item: MenuItem) MenuItem {
    var out = item;
    out.separator_before = true;
    return out;
}

const brand_rows = [_]MenuItem{
    .{ .icon = "\u{F129}", .icon_ascii = "i", .label = "About mnml…", .action = .{ .command = .@"view.about" } },
    .{ .icon = "\u{F013}", .icon_ascii = "*", .label = "Settings…", .action = .{ .command = .@"view.settings" } },
    sep(.{ .icon = "\u{F011}", .icon_ascii = "q", .label = "Quit mnml", .action = .{ .command = .@"app.quit" } }),
};

/// The "Open recent file" row is index `file_recent_row`: its submenu
/// is built per open from `app.recent`.
const file_recent_row = 3;
const file_rows = [_]MenuItem{
    .{ .icon = "\u{F0224}", .icon_ascii = "+", .label = "New file", .action = .{ .command = .@"file.new" } },
    .{ .icon = "\u{F115}", .icon_ascii = "/", .label = "Open file…", .action = .{ .command = .@"picker.files" } },
    .{ .icon = "\u{EEC7}", .icon_ascii = "+", .label = "Add folder to workspace…", .action = .{ .command = .@"view.add_workspace" } },
    .{ .icon = "\u{F1DA}", .icon_ascii = "h", .label = "Open recent file", .action = .none },
    .{ .icon = "\u{F443}", .icon_ascii = "w", .label = "Switch workspace…", .action = .{ .command = .@"view.switch_workspace" } },
    sep(.{ .icon = "\u{F0193}", .icon_ascii = "s", .label = "Save", .action = .{ .command = .@"file.save" } }),
    .{ .icon = "\u{F0194}", .icon_ascii = "S", .label = "Save all", .action = .{ .command = .@"file.save_all" } },
    sep(.{ .icon = "\u{F00D}", .icon_ascii = "x", .label = "Close tab", .action = .{ .command = .@"buffer.close" } }),
    sep(.{ .icon = "\u{F013}", .icon_ascii = "*", .label = "Settings…", .action = .{ .command = .@"view.settings" } }),
    .{ .icon = "\u{F011}", .icon_ascii = "q", .label = "Quit", .action = .{ .command = .@"app.quit" } },
};

const edit_rows = [_]MenuItem{
    .{ .icon = search_glyph, .icon_ascii = "?", .label = "Find…", .action = .{ .command = .@"find.find" } },
    .{ .icon = "\u{F063}", .icon_ascii = "v", .label = "Find next", .action = .{ .command = .@"find.next" } },
    .{ .icon = "\u{F062}", .icon_ascii = "^", .label = "Find previous", .action = .{ .command = .@"find.prev" } },
    .{ .icon = "\u{F0EC}", .icon_ascii = "%", .label = "Replace…", .action = .{ .command = .@"find.replace" } },
    sep(.{ .icon = search_glyph, .icon_ascii = "?", .label = "Find in files…", .action = .{ .command = .@"find.grep" } }),
    .{ .icon = "\u{F0EC}", .icon_ascii = "%", .label = "Replace in files…", .action = .{ .command = .@"find.grep_replace" } },
};

const selection_rows = [_]MenuItem{
    .{ .icon = "\u{F065}", .icon_ascii = ">", .label = "Expand selection", .action = .{ .command = .@"lsp.selection_expand" } },
    .{ .icon = "\u{F066}", .icon_ascii = "<", .label = "Shrink selection", .action = .{ .command = .@"lsp.selection_shrink" } },
    sep(.{ .icon = "\u{F062}", .icon_ascii = "^", .label = "Add cursor above", .action = .{ .command = .@"editor.add_cursor_above" } }),
    .{ .icon = "\u{F063}", .icon_ascii = "v", .label = "Add cursor below", .action = .{ .command = .@"editor.add_cursor_below" } },
    .{ .icon = "\u{F067}", .icon_ascii = "+", .label = "Add cursor at next match", .action = .{ .command = .@"editor.add_cursor_at_next_word" } },
    .{ .icon = "\u{EB85}", .icon_ascii = "=", .label = "Select all occurrences", .action = .{ .command = .@"editor.select_all_occurrences" } },
    .{ .icon = "\u{F00D}", .icon_ascii = "x", .label = "Clear extra cursors", .action = .{ .command = .@"editor.clear_extra_cursors" } },
};

/// Rust's "Toggle bottom panel" and "Commands reference…" rows are left
/// out (here and in Help): `view.toggle_bottom_panel` and
/// `view.commands_reference` have no runner yet, and a row that toasts
/// "not implemented" is dead.
const view_rows = [_]MenuItem{
    .{ .icon = "\u{F0770}", .icon_ascii = "/", .label = "File browser pane", .action = .{ .command = .@"files.open" } },
    .{ .icon = "\u{F0770}", .icon_ascii = "/", .label = "Dual file panes (commander)", .action = .{ .command = .@"files.open_split" } },
    .{ .icon = "\u{F4B5}", .icon_ascii = ">", .label = "Command palette", .action = .{ .command = .palette } },
    sep(.{ .icon = "\u{EC02}", .icon_ascii = "|", .label = "Toggle left panel", .action = .{ .command = .@"view.toggle_tree" } }),
    .{ .icon = "\u{EC00}", .icon_ascii = "|", .label = "Toggle right panel", .action = .{ .command = .@"view.toggle_right_panel" } },
    .{ .icon = "\u{F0C9}", .icon_ascii = "=", .label = "Cycle menu bar (always / auto / hidden)", .action = .{ .command = .@"view.menu_bar_cycle" } },
    .{ .icon = "\u{EB80}", .icon_ascii = "~", .label = "Toggle line wrap", .action = .{ .command = .@"view.toggle_wrap" } },
    .{ .icon = "\u{F06E}", .icon_ascii = "o", .label = "Toggle full screen", .action = .{ .command = .@"view.fullscreen" } },
    .{ .icon = "\u{F02D6}", .icon_ascii = "?", .label = "Toggle hover-help", .action = .{ .command = .@"view.toggle_hover_help" } },
    .{ .icon = "\u{F0130}", .icon_ascii = "o", .label = "Toggle workspace dots", .action = .{ .command = .@"view.toggle_workspace_dots" } },
    sep(.{ .icon = "\u{F1FC}", .icon_ascii = "p", .label = "Pick theme…", .action = .{ .command = .@"theme.pick" } }),
    .{ .icon = "\u{F042}", .icon_ascii = "t", .label = "Toggle theme", .action = .{ .command = .@"theme.toggle" } },
};

const go_rows = [_]MenuItem{
    .{ .icon = search_glyph, .icon_ascii = "?", .label = "Go to file…", .action = .{ .command = .@"picker.files" } },
    .{ .icon = "\u{F292}", .icon_ascii = "#", .label = "Go to line…", .action = .{ .command = .@"editor.goto_line" } },
    .{ .icon = "\u{EAB5}", .icon_ascii = ">", .label = "Go to definition", .action = .{ .command = .@"lsp.goto_definition" } },
    sep(.{ .icon = "\u{F060}", .icon_ascii = "<", .label = "Previous buffer", .action = .{ .command = .@"buffer.prev" } }),
    .{ .icon = "\u{F061}", .icon_ascii = ">", .label = "Next buffer", .action = .{ .command = .@"buffer.next" } },
    .{ .icon = "\u{F050}", .icon_ascii = ">", .label = "Last buffer", .action = .{ .command = .@"buffer.last" } },
};

const run_rows = [_]MenuItem{
    .{ .icon = "\u{F04B}", .icon_ascii = ">", .label = "Start debugging", .action = .{ .command = .@"dap.run" } },
    .{ .icon = "\u{F111}", .icon_ascii = "o", .label = "Toggle breakpoint", .action = .{ .command = .@"dap.toggle_breakpoint" } },
    .{ .icon = "\u{EA97}", .icon_ascii = "?", .label = "Conditional breakpoint…", .action = .{ .command = .@"dap.toggle_breakpoint_conditional" } },
    sep(.{ .icon = "\u{F103}", .icon_ascii = "v", .label = "Step in", .action = .{ .command = .@"dap.step_in" } }),
    .{ .icon = "\u{F102}", .icon_ascii = "^", .label = "Step out", .action = .{ .command = .@"dap.step_out" } },
    .{ .icon = "\u{F048}", .icon_ascii = "<", .label = "Step back", .action = .{ .command = .@"dap.step_back" } },
};

const terminal_rows = [_]MenuItem{
    .{ .icon = "\u{F120}", .icon_ascii = "$", .label = "New terminal (split below)", .action = .{ .command = .@"term.shell" } },
    .{ .icon = "\u{F120}", .icon_ascii = "$", .label = "Toggle scratch terminal", .action = .{ .command = .@"term.scratch_toggle" } },
    .{ .icon = "\u{F040}", .icon_ascii = "e", .label = "Rename terminal", .action = .{ .command = .@"term.rename" } },
};

/// Rust's merge / spread and AI-layout rows are left out: their ids
/// (`layout.merge_to_tabs`, `layout.spread_to_splits`,
/// `view.ai_layout_grid` / `_tabs`) have no runner yet.
const window_rows = [_]MenuItem{
    .{ .icon = "\u{F0E2}", .icon_ascii = "u", .label = "Reopen closed tab", .action = .{ .command = .@"buffer.reopen" } },
    .{ .icon = "\u{F00D}", .icon_ascii = "x", .label = "Close other tabs", .action = .{ .command = .@"view.close_others" } },
    .{ .icon = "\u{F08D}", .icon_ascii = "^", .label = "Pin / unpin tab", .action = .{ .command = .@"buffer.pin_toggle" } },
    sep(.{ .icon = "\u{EB56}", .icon_ascii = "|", .label = "Split right", .action = .{ .command = .@"view.split_right" } }),
    .{ .icon = "\u{EB57}", .icon_ascii = "-", .label = "Split down", .action = .{ .command = .@"view.split_down" } },
    .{ .icon = "\u{F00D}", .icon_ascii = "x", .label = "Close split", .action = .{ .command = .@"view.close_split" } },
    .{ .icon = "\u{F02C1}", .icon_ascii = "=", .label = "Equalize splits", .action = .{ .command = .@"view.equalize_splits" } },
    .{ .icon = "\u{F0758}", .icon_ascii = "a", .label = "Auto-equalize on split / close (toggle)", .action = .{ .command = .@"view.toggle_auto_equalize_splits" } },
    sep(.{ .icon = "\u{F07E}", .icon_ascii = "<", .label = "Grow split width", .action = .{ .command = .@"view.split_grow_width" } }),
    .{ .icon = "\u{F07D}", .icon_ascii = "^", .label = "Grow split height", .action = .{ .command = .@"view.split_grow_height" } },
    sep(.{ .icon = "\u{F060}", .icon_ascii = "<", .label = "Focus split left", .action = .{ .command = .@"view.focus_left" } }),
    .{ .icon = "\u{F061}", .icon_ascii = ">", .label = "Focus split right", .action = .{ .command = .@"view.focus_right" } },
    .{ .icon = "\u{F062}", .icon_ascii = "^", .label = "Focus split up", .action = .{ .command = .@"view.focus_up" } },
    .{ .icon = "\u{F063}", .icon_ascii = "v", .label = "Focus split down", .action = .{ .command = .@"view.focus_down" } },
    sep(.{ .icon = "\u{F021}", .icon_ascii = "r", .label = "Restart mnml", .action = .{ .command = .@"app.restart" } }),
};

const help_rows = [_]MenuItem{
    .{ .icon = "\u{F0EB}", .icon_ascii = "!", .label = "Welcome", .action = .{ .command = .@"view.welcome" } },
    .{ .icon = "\u{F11C}", .icon_ascii = "k", .label = "Keybindings & help", .action = .{ .command = .@"view.help" } },
    sep(.{ .icon = "\u{F129}", .icon_ascii = "i", .label = "About mnml", .action = .{ .command = .@"view.about" } }),
};

/// The static rows of a menu — the File menu's recent-files submenu
/// is filled in by `buildRows`.
pub fn rowsOf(m: Menu) []const MenuItem {
    return switch (m) {
        .brand => &brand_rows,
        .file => &file_rows,
        .edit => &edit_rows,
        .selection => &selection_rows,
        .view => &view_rows,
        .go => &go_rows,
        .run => &run_rows,
        .terminal => &terminal_rows,
        .window => &window_rows,
        .help => &help_rows,
    };
}

/// The `file.open_recent_N` ids the submenu's rows fire, in order.
const recent_ids = [_]command.CommandId{
    .@"file.open_recent_0", .@"file.open_recent_1", .@"file.open_recent_2", .@"file.open_recent_3", .@"file.open_recent_4",
    .@"file.open_recent_5", .@"file.open_recent_6", .@"file.open_recent_7", .@"file.open_recent_8", .@"file.open_recent_9",
};

/// The rows of the "Open recent file" submenu: the newest ten recent
/// files by name, then "Clear recent files"; a placeholder when the
/// list is empty. `file.open_recent_N` counts from the newest.
fn recentRows(app: *App, arena: Allocator) Allocator.Error![]MenuItem {
    const n = @min(app.recent.items.len, recent_ids.len);
    if (n == 0) {
        const one = try arena.alloc(MenuItem, 1);
        one[0] = .{ .label = "(no recent files)", .action = .{ .command = .noop } };
        return one;
    }
    const rows = try arena.alloc(MenuItem, n + 1);
    for (rows[0..n], 0..) |*r, i| {
        const path = app.recent.items[app.recent.items.len - 1 - i];
        r.* = .{ .label = std.fs.path.basename(path), .action = .{ .command = recent_ids[i] } };
    }
    rows[n] = sep(.{ .label = "Clear recent files", .action = .{ .command = .@"file.clear_recent" } });
    return rows;
}

/// The first default chord of `keys` under the active profile, in its
/// canonical spelling, on `arena`; null when the command has none.
fn chordHint(app: *App, arena: Allocator, keys: command.Keys) Allocator.Error!?[]const u8 {
    const own = switch (App.profileOf(app.input_style)) {
        .vim => keys.vim,
        .standard => keys.standard,
    };
    const spec: []const u8 = if (keys.both.len > 0) keys.both[0] else if (own.len > 0) own[0] else return null;
    var buf: [64]u8 = undefined;
    return try arena.dupe(u8, keymap.normalizeSpec(spec, &buf) orelse spec);
}

/// The menu's rows for this open: the static table with each row's
/// chord hint, the recent-files submenu on the File menu. The slice is
/// the overlay's (gpa); what the rows point at is `State.mem`'s.
fn buildRows(app: *App, m: Menu) Allocator.Error![]MenuItem {
    const s = &app.menu_bar;
    if (s.mem) |*old| old.deinit();
    s.mem = std.heap.ArenaAllocator.init(app.gpa);
    const arena = s.mem.?.allocator();
    const rows = try app.gpa.dupe(MenuItem, rowsOf(m));
    errdefer app.gpa.free(rows);
    for (rows) |*r| switch (r.action) {
        .command => |id| r.hint = try chordHint(app, arena, command.spec(id).keys),
        else => {},
    };
    if (m == .file) rows[file_recent_row].submenu = try recentRows(app, arena);
    return rows;
}

// ─── opening ────────────────────────────────────────────────────────────

/// Drop `m`'s menu at `(x, y)` — the word's left edge, the row below it.
pub fn open(app: *App, m: Menu, x: u16, y: u16) Allocator.Error!void {
    const rows = try buildRows(app, m);
    errdefer app.gpa.free(rows);
    try app.openMenu(m.title(), rows, x, y);
    app.menu_bar.open = m;
}

/// Open menu `idx` under its word — or where the words ended when the
/// word is hidden behind the ` » `.
pub fn openIndex(app: *App, idx: usize) Allocator.Error!void {
    if (idx >= Menu.count) return;
    const s = &app.menu_bar;
    const m: Menu = @enumFromInt(idx);
    const x = s.word_x[idx] orelse s.words_end;
    try open(app, m, x, s.bar_y + 1);
}

/// ← / → while a menu is open: the neighbour, wrapping.
pub fn step(app: *App, delta: i8) Allocator.Error!void {
    const cur = app.menu_bar.open orelse return;
    const n: i16 = Menu.count;
    const next: usize = @intCast(@mod(@as(i16, @intFromEnum(cur)) + delta, n));
    try openIndex(app, next);
}

/// The ` » ` chip's menu: the words that did not fit, each opening its menu.
pub fn openOverflow(app: *App, x: u16, y: u16) Allocator.Error!void {
    const first = app.menu_bar.first_hidden orelse return;
    const n = Menu.count - first;
    const rows = try app.gpa.alloc(MenuItem, n);
    errdefer app.gpa.free(rows);
    for (rows, first..) |*r, i| r.* = .{ .label = labels[i], .action = .{ .menu_bar = @intCast(i) }, .icon = "\u{F0C9}", .icon_ascii = "=" };
    try app.openMenu("Menus", rows, x, y);
}

/// `closeOverlay` calls this: the words of an `auto` bar go with the menu.
pub fn menuClosed(app: *App) void {
    if (app.menu_bar.open != null) {
        app.menu_bar.open = null;
        app.needs_render = true;
    }
}

/// F10 opens File; Alt+<letter> the menu with that initial. Nothing
/// while an overlay is up, in a terminal pane, or (F10) while a debug
/// session owns step-over. True when a menu opened.
pub fn interceptKey(app: *App, k: key_mod.Key) Allocator.Error!bool {
    if (app.cfg.ui.menu_bar == .hidden or app.overlay != .none) return false;
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.* == .pty) return false;
    switch (k.code) {
        .f => |n| if (n == 10 and k.mods.eql(.none) and app.dap.session == null) {
            try openIndex(app, @intFromEnum(Menu.file));
            return true;
        },
        .char => |c| if (k.mods.alt and !k.mods.ctrl and !k.mods.shift and !k.mods.super and c < 0x80) {
            const want = std.ascii.toLower(@intCast(c));
            for (Menu.all) |m| if (m.accelerator() == want) {
                try openIndex(app, @intFromEnum(m));
                return true;
            };
        },
        else => {},
    }
    return false;
}

/// ← / → inside an open menu-bar menu step to the neighbour; → on a
/// row with a submenu is the submenu's (the caller's). True when taken.
pub fn menuKey(app: *App, k: key_mod.Key) Allocator.Error!bool {
    if (app.menu_bar.open == null or app.overlay != .menu) return false;
    const m = &app.overlay.menu;
    if (m.sub != null) return false;
    switch (k.code) {
        .left => {
            try step(app, -1);
            return true;
        },
        .right => {
            if (m.cursor < m.items.len and m.items[m.cursor].submenu.len > 0) return false;
            try step(app, 1);
            return true;
        },
        else => return false,
    }
}

/// `view.menu_bar_open`: the File menu, under its word.
fn openFirstCmd(app: *App) CommandError!void {
    if (app.cfg.ui.menu_bar == .hidden) return app.diag.fail(app.frame.allocator(), "the menu bar is hidden (ui.menu_bar)", .{});
    try openIndex(app, @intFromEnum(Menu.file));
}

/// `view.menu_bar_cycle`: always → auto → hidden → always, persisted.
fn cycleCmd(app: *App) CommandError!void {
    const next: Config.MenuBar = switch (app.cfg.ui.menu_bar) {
        .always => .auto,
        .auto => .hidden,
        .hidden => .always,
    };
    app.cfg.ui.menu_bar = next;
    _ = try settings.persist(app, .home, &.{ "ui", "menu_bar" }, next);
    app.toast("menu bar: {s}", .{@tagName(next)});
    app.needs_render = true;
}

// ─── hover help ─────────────────────────────────────────────────────────

const Tip = @import("discovery.zig").Tip;

/// The info-box copy for the chrome row's targets: the words, the
/// ` » `, and the bar's `render.Button` ids.
pub fn describeButton(app: *App, arena: Allocator, id: u32) Allocator.Error!?Tip {
    if (buttonOf(id)) |m| return .{
        .title = if (m == .brand) "mnml menu" else try std.fmt.allocPrint(arena, "{s} menu", .{m.label()}),
        .detail = try std.fmt.allocPrint(arena, "click: open menu · Alt+{c}", .{std.ascii.toUpper(m.accelerator())}),
    };
    if (id == overflow_button) return .{ .title = "More menus", .detail = "click lists the menus that did not fit" };
    if (render.Button.tabPageOf(id)) |page| return .{
        .title = try std.fmt.allocPrint(arena, "Tab page {d} of {d}{s}", .{ page + 1, app.layouts.layouts.items.len, if (page == app.layouts.active) " (active)" else "" }),
        .detail = if (page < 9) try std.fmt.allocPrint(arena, "click: switch tab page · Alt+{d}", .{page + 1}) else "click: switch tab page",
    };
    if (render.Button.tabPageCloseOf(id) != null) return .{ .title = "Close this tab page", .detail = "click: close it (tab.close)" };
    const n = app.panes.count();
    return switch (@as(render.Button, @enumFromInt(id))) {
        .palette => .{ .title = "command palette", .detail = "click: open files, commands, recent (Ctrl+P)" },
        .toggle_tree => .{ .title = if (app.tree.visible) "file tree: open" else "file tree: off", .detail = "click: toggle file tree (Ctrl+B)" },
        .toggle_right_panel => .{ .title = if (app.right_panel != null) "right panel: open" else "right panel: off", .detail = "click: toggle right side panel (Ctrl+Shift+B)" },
        .back => .{
            .title = if (n <= 1) "back to previous buffer (Ctrl+[)" else try std.fmt.allocPrint(arena, "click: prev buffer (MRU) · {d} open", .{n}),
            .detail = if (n <= 1) "disabled — no other buffers" else null,
        },
        .forward => .{
            .title = if (n <= 1) "forward to next buffer (Ctrl+])" else try std.fmt.allocPrint(arena, "click: next buffer (MRU) · {d} open", .{n}),
            .detail = if (n <= 1) "disabled — no other buffers" else null,
        },
        .dropdown => .{ .title = "recent files", .detail = "click: open recent" },
        .new_tab_page => .{ .title = "new tab page", .detail = "click: open a new empty tab page (workspace) · Alt+1..9 to switch" },
        .tabs_label => .{
            .title = if (app.layouts.layouts.items.len <= 1) "single tab page" else try std.fmt.allocPrint(arena, "{d} tab pages", .{app.layouts.layouts.items.len}),
            .detail = "click: switch tab page",
        },
        .theme_toggle => .{ .title = try std.fmt.allocPrint(arena, "theme: {s}", .{app.theme.name}), .detail = "click: toggle between configured themes" },
        .window_close => .{ .title = "quit mnml", .detail = "click: quit" },
        .split_term => .{ .title = "New terminal", .detail = "click: open a shell in a split (term.shell)" },
        .split_right => .{ .title = "Split right", .detail = "click: side by side (view.split_right)" },
        .split_down => .{ .title = "Split down", .detail = "click: stacked (view.split_down)" },
        .ai_claude => .{ .title = "Claude Code", .detail = "click opens the session (ai.claude_code)" },
        .ai_codex => .{ .title = "Codex", .detail = "click opens the session (ai.codex)" },
        else => null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// Every row of every menu, submenus included, as `(menu, row)`.
fn forEachRow(comptime f: fn (Menu, MenuItem) anyerror!void) !void {
    for (Menu.all) |m| for (rowsOf(m)) |row| {
        try f(m, row);
        for (row.submenu) |sub| try f(m, sub);
    };
}

test "menu rows: ten menus with Rust's row counts; every row is a registered command with a runner, or the recent-files parent" {
    try t.expectEqual(@as(usize, 10), Menu.count);
    const counts = [Menu.count]usize{ 3, 10, 6, 7, 12, 6, 6, 3, 15, 3 };
    for (Menu.all, counts) |m, n| try t.expectEqual(n, rowsOf(m).len);
    const Check = struct {
        var missing: usize = 0;
        fn check(m: Menu, row: MenuItem) !void {
            switch (row.action) {
                .command => |id| if (command.runners.get(id) == null) {
                    std.debug.print("menu row without a runner: {s} -> {s}\n", .{ row.label, command.name(id) });
                    missing += 1;
                },
                .none => {
                    try t.expectEqual(Menu.file, m);
                    try t.expectEqualStrings("Open recent file", row.label);
                },
                else => return error.UnexpectedAction,
            }
            try t.expect(row.icon != null);
        }
    };
    try forEachRow(Check.check);
    try t.expectEqual(@as(usize, 0), Check.missing);
    // Accelerators: the brand's is its wordmark's `m`.
    try t.expectEqual(@as(u8, 'm'), Menu.brand.accelerator());
    try t.expectEqual(@as(u8, 'f'), Menu.file.accelerator());
    try t.expectEqual(@as(u8, 'w'), Menu.window.accelerator());
    try t.expectEqualStrings("mnml", Menu.brand.title());
}

test "menu bar: a click drops the menu with chord hints and the recent submenu; » lists the hidden menus; F10 / Alt / arrows; auto follows the menu; cycle persists" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const screen = @import("../ipc/screen.zig");
    try app.render();
    const always = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(always);
    const row0 = always[0..std.mem.indexOfScalar(u8, always, '\n').?];
    try t.expect(std.mem.startsWith(u8, row0, " ❯_  mnml  File  Edit  » "));
    try t.expect(std.mem.indexOf(u8, row0, " Selection ") == null);
    try t.expectEqual(@as(?u16, 10), app.menu_bar.word_x[1]);
    try t.expectEqual(@as(?u8, 3), app.menu_bar.first_hidden);
    // A click on File drops it: hints from the standard profile, the
    // recent submenu on its row.
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("File", app.overlay.menu.title);
    try t.expectEqualStrings("New file", app.overlay.menu.items[0].label);
    try t.expectEqual(command.CommandId.@"file.new", app.overlay.menu.items[0].action.command);
    try t.expectEqualStrings("ctrl+s", app.overlay.menu.items[5].hint.?);
    try t.expectEqual(@as(usize, 1), app.overlay.menu.items[file_recent_row].submenu.len);
    try t.expectEqualStrings("(no recent files)", app.overlay.menu.items[file_recent_row].submenu[0].label);
    try app.render();
    const dropped = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(dropped);
    try t.expect(std.mem.indexOf(u8, dropped, "╭ File") != null);
    try t.expect(std.mem.indexOf(u8, dropped, "ctrl+s") != null);
    // → steps to Edit, ← back to File, ← again wraps to the brand menu.
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqual(Menu.edit, app.menu_bar.open.?);
    try t.expectEqualStrings("Edit", app.overlay.menu.title);
    try app.handle(.{ .key = app_mod.Key.named(.left) });
    try app.handle(.{ .key = app_mod.Key.named(.left) });
    try t.expectEqual(Menu.brand, app.menu_bar.open.?);
    try t.expectEqualStrings("mnml", app.overlay.menu.title);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(app.menu_bar.open == null);
    // The » lists the seven hidden menus; its Window row opens Window.
    try app.handle(.{ .mouse = .{ .x = 23, .y = 0, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(@as(usize, 7), app.overlay.menu.items.len);
    try t.expectEqualStrings("Selection", app.overlay.menu.items[0].label);
    try t.expectEqual(@as(u8, 8), app.overlay.menu.items[5].action.menu_bar);
    app.overlay.menu.cursor = 5;
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expectEqual(Menu.window, app.menu_bar.open.?);
    try t.expectEqual(@as(usize, 15), app.overlay.menu.items.len);
    // A hidden menu's dropdown hangs where the words ended.
    try t.expectEqual(app.menu_bar.words_end, app.overlay.menu.x);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // F10 opens File; Alt+H Help; Alt+M the brand menu.
    try app.handle(.{ .key = app_mod.Key.named(.{ .f = 10 }) });
    try t.expectEqual(Menu.file, app.menu_bar.open.?);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try app.handle(.{ .key = .{ .code = .{ .char = 'h' }, .mods = .{ .alt = true } } });
    try t.expectEqual(Menu.help, app.menu_bar.open.?);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try app.handle(.{ .key = .{ .code = .{ .char = 'M' }, .mods = .{ .alt = true } } });
    try t.expectEqual(Menu.brand, app.menu_bar.open.?);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // Shift+Alt+F is not the File menu (VS Code's format chord).
    try app.handle(.{ .key = .{ .code = .{ .char = 'f' }, .mods = .{ .alt = true, .shift = true } } });
    try t.expect(app.menu_bar.open == null);
    // Hidden: no words, and the open command refuses.
    app.cfg.ui.menu_bar = .hidden;
    try app.render();
    const hidden = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(hidden);
    try t.expect(std.mem.indexOf(u8, hidden[0..std.mem.indexOfScalar(u8, hidden, '\n').?], " File ") == null);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.menu_bar_open" }));
    try t.expect(!try interceptKey(&app, app_mod.Key.named(.{ .f = 10 })));
    // Auto: the words appear with the menu and go with it — or while
    // the pointer rests on the row.
    app.cfg.ui.menu_bar = .auto;
    app.hover = .{ .x = 5, .y = 0 };
    try app.render();
    const auto_hover = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(auto_hover);
    try t.expect(std.mem.indexOf(u8, auto_hover[0..std.mem.indexOfScalar(u8, auto_hover, '\n').?], " File ") != null);
    app.hover = null;
    try app.render();
    const auto_closed = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(auto_closed);
    try t.expect(std.mem.indexOf(u8, auto_closed[0..std.mem.indexOfScalar(u8, auto_closed, '\n').?], " File ") == null);
    try command.run(&app, .{ .static = .@"view.menu_bar_open" });
    try app.render();
    const auto_open = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(auto_open);
    try t.expect(std.mem.indexOf(u8, auto_open[0..std.mem.indexOfScalar(u8, auto_open, '\n').?], " File ") != null);
    try t.expect(app.overlay == .menu);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.menu_bar.open == null);
    // Cycle: auto → hidden → always, written to the home config.
    try command.run(&app, .{ .static = .@"view.menu_bar_cycle" });
    try t.expectEqual(Config.MenuBar.hidden, app.cfg.ui.menu_bar);
    try command.run(&app, .{ .static = .@"view.menu_bar_cycle" });
    try t.expectEqual(Config.MenuBar.always, app.cfg.ui.menu_bar);
    const home = (try settings.configPath(&app, .home)).?;
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".menu_bar = .always") != null);
}
