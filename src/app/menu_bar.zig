//! The menu bar — the Rust editor's ten menus (the `❯_  mnml` brand menu,
//! then File / Edit / Selection / View / Go / Run / Terminal / Window /
//! Help) as words on the chrome row; `ui/menu_bar.zig` paints them. A
//! click drops the menu below its word; every row is a registered
//! command (an enum — a row cannot name an id that does not exist),
//! Rust's glyph in the icon column. Words that do not fit before the centred
//! workspace chip collapse behind a ` » ` chip whose menu lists them.
//!
//! `ui.menu_bar`: `always` paints the words, `hidden` does not, `auto`
//! paints them while a menu is open or the pointer is on the row.
//! Keyboard: F10 opens File, Alt+<letter> the menu with that initial,
//! ← / → step between menus while one is open (`view.menu_bar_open`
//! opens File from the palette; `view.menu_bar_cycle` steps the
//! setting). With a menu open the pointer resting on another word
//! switches to it, on the ` » ` to its list (`hoverSwitch`).
//!
//! The rows are built per open — the File menu's recent-files submenu
//! lives on `State.mem` until the next open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const key_mod = @import("../core/key.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const settings = @import("settings.zig");
const render = @import("render.zig");
const Rect = @import("../ui/rect.zig");
const side = @import("side.zig");
const search_glyph = @import("../ui/menu_bar.zig").search_glyph;
const hover_zones = @import("hover_zones.zig");
const zen = @import("zen.zig");
const ai_app = @import("ai.zig");

pub const table = .{
    .@"view.menu_bar_cycle" = &cycleCmd,
    .@"view.menu_bar_open" = &openFirstCmd,
    .@"view.menu_bar_pin" = &pinCmd,
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
    /// How the open menu was summoned — a hover-switch to another word
    /// keeps it (Rust preserves `keyboard_opened` across the switch).
    keyboard: bool = false,
    /// The ` » ` chip's list of hidden menus is the open overlay.
    overflow_open: bool = false,
    /// Pinned for this session: an auto-hiding bar keeps its words
    /// wherever the pointer goes and `mode` reads `.always`. Never
    /// written to the config — unpinning is meant to be one click.
    pinned: bool = false,
    /// Owns the rows built per open: the recent-files submenu.
    mem: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *State) void {
        if (s.mem) |*m| m.deinit();
        s.mem = null;
    }
};

/// `ui.menu_bar`, with the session's pin on top of it — the shape
/// `sidebar_auto.mode` already has. // changed (menu-bar-pin).
pub fn mode(app: *const App) Config.MenuBar {
    if (app.menu_bar.pinned) return .always;
    return app.cfg.ui.menu_bar;
}

/// Whether the words paint this frame on the bar at `bar_y`.
/// // changed (sidebar-autohide): the bar's row is a `hover_zones`
/// zone now, registered from the geometry rather than compared here,
/// so it can outrank the side columns' edge zone at the top-left cell.
/// `bar_y` is kept as the caller's assertion that it is asking about
/// the row the zone was cut from.
pub fn shown(app: *const App, bar_y: u16) bool {
    return switch (mode(app)) {
        .always => true,
        .hidden => false,
        .auto => app.menu_bar.open != null or
            (hover_zones.dwelled(app, .menu_bar_top) and app.hover != null and app.hover.?.y == bar_y),
    };
}

/// Whether the pin chip paints at the end of the words this frame.
/// // changed (menu-bar-pin): only a bar that CAN hide itself wears
/// one — under `ui.menu_bar = .always` there is nothing to pin, so
/// the shipped default's chrome row is exactly what it was. The words
/// have to be up for it, which under `.auto` means revealed or pinned
/// and under `.hidden` means pinned.
pub fn pinShown(app: *const App, bar_y: u16) bool {
    return app.cfg.ui.menu_bar != .always and shown(app, bar_y);
}

/// // changed (edge-grip): whether the `⋯` grip paints on the bar's
/// row instead of the words. Only `.auto` wears one: `.hidden`
/// registers no hover zone at all, so a grip there would be a handle
/// that does nothing, and `.always` has nothing to summon. Pinned, the
/// words are up and the chip at their end is the handle.
pub fn gripShown(app: *const App, bar_y: u16) bool {
    return app.cfg.ui.edge_grips and app.cfg.ui.menu_bar == .auto and !app.menu_bar.pinned and !shown(app, bar_y);
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
/// The View menu's full-screen row is index `view_fullscreen_row`: its
/// label reads the way out while inside (`zen.title`).
const view_fullscreen_row = 8;
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

/// Rust's "Commands reference…" row is left out (here and in Help):
/// `view.commands_reference` has no runner yet, and a row that toasts
/// "not implemented" is dead. // changed (bottom-dock): "Toggle bottom
/// panel" was left out for the same reason and is back — the dock runs.
const layouts_rows = [_]MenuItem{
    .{ .icon = "\u{F0193}", .icon_ascii = "s", .label = "Save this tab page as…", .action = .{ .command = .@"layout.save" } },
    .{ .icon = "\u{F115}", .icon_ascii = "/", .label = "Load layout…", .action = .{ .command = .@"layout.pick" } },
    sep(.{ .icon = "\u{F1F8}", .icon_ascii = "x", .label = "Delete layout…", .action = .{ .command = .@"layout.delete" } }),
};

const view_rows = [_]MenuItem{
    .{ .icon = "\u{F0770}", .icon_ascii = "/", .label = "File browser pane", .action = .{ .command = .@"files.open" } },
    .{ .icon = "\u{F0770}", .icon_ascii = "/", .label = "Dual file panes (commander)", .action = .{ .command = .@"files.open_split" } },
    .{ .icon = "\u{F4B5}", .icon_ascii = ">", .label = "Command palette", .action = .{ .command = .palette } },
    sep(.{ .icon = "\u{EC02}", .icon_ascii = "|", .label = "Toggle left panel", .action = .{ .command = .@"view.toggle_tree" } }),
    .{ .icon = "\u{EC00}", .icon_ascii = "|", .label = "Toggle right panel", .action = .{ .command = .@"view.toggle_right_panel" } },
    // // changed (bottom-dock): Rust's own View row, back in the menu.
    .{ .icon = "\u{EC17}", .icon_ascii = "_", .label = "Toggle bottom panel", .action = .{ .command = .@"view.toggle_bottom_panel" } },
    .{ .icon = "\u{F0C9}", .icon_ascii = "=", .label = "Cycle menu bar (always / auto / hidden)", .action = .{ .command = .@"view.menu_bar_cycle" } },
    .{ .icon = "\u{EB80}", .icon_ascii = "~", .label = "Toggle line wrap", .action = .{ .command = .@"view.toggle_wrap" } },
    .{ .icon = "\u{F06E}", .icon_ascii = "o", .label = "Enter full screen", .action = .{ .command = .@"view.fullscreen" } },
    .{ .icon = "\u{F02D6}", .icon_ascii = "?", .label = "Toggle hover-help", .action = .{ .command = .@"view.toggle_hover_help" } },
    .{ .icon = "\u{F0130}", .icon_ascii = "o", .label = "Toggle workspace dots", .action = .{ .command = .@"view.toggle_workspace_dots" } },
    // Named layouts: this tab page under a name, and back
    // (`app/named_layouts.zig`). The rows are the four commands; the
    // saved names are the picker's.
    sep(.{ .icon = "\u{F0DB}", .icon_ascii = "#", .label = "Layouts", .action = .none, .submenu = &layouts_rows }),
    sep(.{ .icon = "\u{F1FC}", .icon_ascii = "p", .label = "Pick theme…", .action = .{ .command = .@"theme.pick" } }),
    .{ .icon = "\u{F042}", .icon_ascii = "t", .label = "Toggle theme", .action = .{ .command = .@"theme.toggle" } },
    // The way back when the frame has been hidden piece by piece: full
    // screen, the zoom, the tree, the bars, the split sizes.
    sep(.{ .icon = "\u{F0E2}", .icon_ascii = "0", .label = "Reset view to default", .action = .{ .command = .@"view.reset_layout" } }),
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
    .{ .icon = "\u{F120}", .icon_ascii = "$", .label = "New terminal (split below)", .action = .{ .command = .@"term.shell_bottom" } },
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

/// The menu's rows for this open: the static table, the recent-files
/// submenu on the File menu. The slice is the overlay's (gpa); what
/// the rows point at is `State.mem`'s.
fn buildRows(app: *App, m: Menu) Allocator.Error![]MenuItem {
    const s = &app.menu_bar;
    if (s.mem) |*old| old.deinit();
    s.mem = std.heap.ArenaAllocator.init(app.gpa);
    const arena = s.mem.?.allocator();
    const rows = try app.gpa.dupe(MenuItem, rowsOf(m));
    errdefer app.gpa.free(rows);
    if (m == .file) rows[file_recent_row].submenu = try recentRows(app, arena);
    if (m == .view) rows[view_fullscreen_row].label = zen.title(app);
    return rows;
}

// ─── opening ────────────────────────────────────────────────────────────

/// Drop `m`'s menu at `(x, y)` — the word's left edge, the row below
/// it — in the dropdown shape. `keyboard` is how it was summoned: a
/// keyboard-opened menu highlights its first row at once, a
/// mouse-opened one waits for a hover or an arrow (Rust's
/// `MenuOpenState::new_keyboard` / `new_mouse`).
pub fn open(app: *App, m: Menu, x: u16, y: u16, keyboard: bool) Allocator.Error!void {
    const rows = try buildRows(app, m);
    errdefer app.gpa.free(rows);
    try app.openMenu(m.title(), rows, x, y);
    app.overlay.menu.dropdown = true;
    app.overlay.menu.highlight = keyboard;
    app.menu_bar.open = m;
    app.menu_bar.keyboard = keyboard;
    app.menu_bar.overflow_open = false;
}

/// Open menu `idx` under its word — or where the words ended when the
/// word is hidden behind the ` » ` — the way `keyboard` says.
pub fn openIndexAs(app: *App, idx: usize, keyboard: bool) Allocator.Error!void {
    if (idx >= Menu.count) return;
    const s = &app.menu_bar;
    const m: Menu = @enumFromInt(idx);
    const x = s.word_x[idx] orelse s.words_end;
    try open(app, m, x, s.bar_y + 1, keyboard);
}

/// `openIndexAs` from the keyboard (F10, Alt+<letter>, ← / →, the
/// palette, a ` » ` row).
pub fn openIndex(app: *App, idx: usize) Allocator.Error!void {
    try openIndexAs(app, idx, true);
}

/// ← / → while a menu is open: the neighbour, wrapping.
pub fn step(app: *App, delta: i8) Allocator.Error!void {
    const cur = app.menu_bar.open orelse return;
    const n: i16 = Menu.count;
    const next: usize = @intCast(@mod(@as(i16, @intFromEnum(cur)) + delta, n));
    try openIndexAs(app, next, true);
}

/// The ` » ` chip's menu: the words that did not fit, each opening its
/// menu. It hangs from the bar in the dropdown shape the words' own
/// menus use — the `▸ ` marker column, no title row — so an arrow key
/// lights a visible cursor, as it does in File or Edit (a context menu
/// marks its row by colour alone, which the text dump cannot show and a
/// hover-less keyboard user could not see).
pub fn openOverflow(app: *App, x: u16, y: u16) Allocator.Error!void {
    const first = app.menu_bar.first_hidden orelse return;
    const n = Menu.count - first;
    const rows = try app.gpa.alloc(MenuItem, n);
    errdefer app.gpa.free(rows);
    for (rows, first..) |*r, i| r.* = .{ .label = labels[i], .action = .{ .menu_bar = @intCast(i) }, .icon = "\u{F0C9}", .icon_ascii = "=" };
    try app.openMenu("Menus", rows, x, y);
    app.overlay.menu.dropdown = true;
    app.overlay.menu.highlight = false;
    app.menu_bar.open = null;
    app.menu_bar.overflow_open = true;
}

/// `closeOverlay` calls this: the words of an `auto` bar go with the menu.
pub fn menuClosed(app: *App) void {
    const s = &app.menu_bar;
    if (s.open != null or s.overflow_open) {
        s.open = null;
        s.overflow_open = false;
        app.needs_render = true;
    }
}

/// The pointer resting on chrome-row button `id` (its rect `r`) while
/// a menu-bar menu — or the ` » ` list — is open: another word opens
/// its menu in place of the current one, the ` » ` its list, the way
/// it was summoned kept (Rust `mouse/mod.rs`: `new_mouse(hovered_idx)`
/// / `new_keyboard`). Nothing while no bar menu is open, nothing on
/// the word already open. True when a menu was switched.
pub fn hoverSwitch(app: *App, id: u32, r: Rect) Allocator.Error!bool {
    const s = &app.menu_bar;
    if (s.open == null and !s.overflow_open) return false;
    if (buttonOf(id)) |which| {
        if (s.open != null and s.open.? == which) return false;
        const keyboard = s.keyboard;
        try open(app, which, r.x, r.y + 1, keyboard);
        return true;
    }
    if (id == overflow_button and !s.overflow_open) {
        try openOverflow(app, r.x, r.y + 1);
        return true;
    }
    return false;
}

/// F10 opens File; Alt+<letter> the menu with that initial. Nothing
/// while an overlay is up, in a terminal pane, or (F10) while a debug
/// session owns step-over. True when a menu opened.
pub fn interceptKey(app: *App, k: key_mod.Key) Allocator.Error!bool {
    if (mode(app) == .hidden or app.overlay != .none) return false;
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
    if (mode(app) == .hidden) return app.diag.fail(app.frame.allocator(), "the menu bar is hidden (ui.menu_bar)", .{});
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

/// `view.menu_bar_pin`: the words stay wherever the pointer goes and
/// `mode` reads `.always` for the rest of the session; again hands the
/// bar back to `ui.menu_bar`. Nothing is persisted — the pin is a
/// session, not an edit to the config file, the rule
/// `sidebar_auto.togglePin` set. A bar that is already `.always` has
/// nothing to pin, and says so rather than toggling a flag that would
/// change nothing on screen.
fn pinCmd(app: *App) CommandError!void {
    return togglePin(app);
}

pub fn togglePin(app: *App) CommandError!void {
    const s = &app.menu_bar;
    if (s.pinned) {
        s.pinned = false;
        app.toast("menu bar: auto-hide on (ui.menu_bar = .{s})", .{@tagName(app.cfg.ui.menu_bar)});
        app.needs_render = true;
        return;
    }
    if (app.cfg.ui.menu_bar == .always) {
        return app.diag.fail(app.frame.allocator(), "the menu bar is already always on (ui.menu_bar = .always)", .{});
    }
    s.pinned = true;
    app.toast("menu bar pinned \u{2014} shown for this session", .{});
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
    if (id == @intFromEnum(render.Button.menu_bar_pin)) return .{
        .title = if (app.menu_bar.pinned) "Menu bar pinned" else "Pin the menu bar",
        .detail = "click keeps the words up for this session (view.menu_bar_pin) \u{b7} right-click: the bar's modes",
    };
    if (render.Button.tabPageOf(id)) |page| return .{
        .title = try std.fmt.allocPrint(arena, "Tab page {d} of {d}{s}", .{ page + 1, app.layouts.layouts.items.len, if (page == app.layouts.active) " (active)" else "" }),
        .detail = if (page < 9) try std.fmt.allocPrint(arena, "click: switch tab page · Alt+{d}", .{page + 1}) else "click: switch tab page",
    };
    if (render.Button.tabPageCloseOf(id) != null) return .{ .title = "Close this tab page", .detail = "click: close it (tab.close)" };
    const n = app.panes.count();
    return switch (@as(render.Button, @enumFromInt(id))) {
        .palette => .{ .title = "command palette", .detail = "click: open files, commands, recent (Ctrl+P)" },
        .toggle_tree => .{ .title = if (app.tree.visible) "file tree: open" else "file tree: off", .detail = "click: toggle file tree (Ctrl+B)" },
        .toggle_right_panel => .{ .title = if (side.shown(app, .right) != null) "right column: open" else "right column: off", .detail = "click: toggle the right column (Ctrl+Shift+B)" },
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
        // The line names the mode the click will run, because the
        // button has two and `ui.maximize_click` picks which
        // (`app/zen.zig`); while something is maximized it names the
        // way back instead.
        .split_max => if (app.zen or app.zoomedPane() != null) .{
            .title = "Restore",
            .detail = try std.fmt.allocPrint(arena, "click: the frame comes back ({s}) · right-click: the modes", .{command.name(zen.clickCommand(app))}),
        } else .{
            .title = try std.fmt.allocPrint(arena, "Maximize — {s}", .{zen.modeLabel(app.cfg.ui.maximize_click)}),
            .detail = try std.fmt.allocPrint(arena, "click: {s} · right-click: the modes · Settings → UI to change", .{command.name(zen.clickCommand(app))}),
        },
        .fullscreen_exit => .{ .title = "Exit full screen", .detail = "click: the frame comes back (view.fullscreen) · Esc Esc" },
        .hidden_tabs => .{ .title = "Hidden tabs", .detail = "click: the buffer picker lists every tab, shown or not (picker.buffers)" },
        // The chip shows SESSIONS, and starts a session only when
        // there is none (`app/ai.zig`'s `chipClick`).
        .ai_claude => .{
            .title = "Claude Code",
            .detail = if (ai_app.findSession(app, .claude) != null) "click: show the SESSIONS panel" else "click: show SESSIONS and start a session",
        },
        .ai_codex => .{
            .title = "Codex",
            .detail = if (ai_app.findSession(app, .codex) != null) "click: show the SESSIONS panel" else "click: show SESSIONS and start a session",
        },
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
    // // changed (bottom-dock): View grew "Toggle bottom panel" (14).
    // // changed (layouts): View grew the "Layouts" submenu row (15).
    const counts = [Menu.count]usize{ 3, 10, 6, 7, 15, 6, 6, 3, 15, 3 };
    for (Menu.all, counts) |m, n| try t.expectEqual(n, rowsOf(m).len);
    const Check = struct {
        var missing: usize = 0;
        fn check(m: Menu, row: MenuItem) !void {
            switch (row.action) {
                .command => |id| if (command.runners.get(id) == null) {
                    std.debug.print("menu row without a runner: {s} -> {s}\n", .{ row.label, command.name(id) });
                    missing += 1;
                },
                // The two parents of a submenu: File's recent files, View's layouts.
                .none => if (m == .view) {
                    try t.expectEqualStrings("Layouts", row.label);
                    // Save, Load, Delete — "Load layout by name…" was the
                    // Load picker twice.
                    try t.expectEqual(@as(usize, 3), row.submenu.len);
                } else {
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
    try t.expectEqual(command.CommandId.@"view.fullscreen", view_rows[view_fullscreen_row].action.command);
}

test "the Terminal menu's \"split below\" row opens its shell under the active pane, not beside it" {
    // A login shell: POSIX.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (!@import("pty_pane.zig").supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    const row = terminal_rows[0];
    try t.expectEqualStrings("New terminal (split below)", row.label);
    try command.run(&app, .{ .static = row.action.command });
    const sh = app.active.?;
    try t.expect(sh != ed);
    try app.render();
    const body = app.panes.pty(sh).?.body;
    // Below: the full width's left edge, the lower half's rows.
    try t.expect(body.x < 10);
    try t.expect(body.y >= 8);
}

test "menu bar: the View menu's full-screen row reads the way in outside and the way out inside" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    try openIndex(&app, @intFromEnum(Menu.view));
    try t.expectEqualStrings("Enter full screen", app.overlay.menu.items[view_fullscreen_row].label);
    try t.expectEqualStrings("Reset view to default", app.overlay.menu.items[app.overlay.menu.items.len - 1].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try openIndex(&app, @intFromEnum(Menu.view));
    try t.expectEqualStrings("Exit full screen", app.overlay.menu.items[view_fullscreen_row].label);
    try t.expectEqual(command.CommandId.@"view.fullscreen", app.overlay.menu.items[view_fullscreen_row].action.command);
}

test "menu bar: a click drops the menu in Rust's dropdown shape with the recent submenu; hover lights and switches; » lists the hidden menus; F10 / Alt / arrows; auto follows the menu; cycle persists" {
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
    // A click on File drops it in the dropdown shape — Rust's
    // `rust-menu-file-120x40.txt` rows: no title, a two-cell marker
    // column, the icon, two cells of air, the label; ` ▸` ends the
    // recent-files row; no highlight until a hover or an arrow.
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expect(app.overlay.menu.dropdown);
    try t.expect(!app.overlay.menu.highlight);
    try t.expectEqualStrings("File", app.overlay.menu.title);
    try t.expectEqualStrings("New file", app.overlay.menu.items[0].label);
    try t.expectEqual(command.CommandId.@"file.new", app.overlay.menu.items[0].action.command);
    try t.expectEqual(@as(usize, 1), app.overlay.menu.items[file_recent_row].submenu.len);
    try t.expectEqualStrings("(no recent files)", app.overlay.menu.items[file_recent_row].submenu[0].label);
    try app.render();
    const dropped = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(dropped);
    try t.expect(std.mem.indexOf(u8, dropped, "╭ File") == null);
    try t.expect(std.mem.indexOf(u8, dropped, "┌─────────────────────────────┐") != null);
    try t.expect(std.mem.indexOf(u8, dropped, "│  \u{F0224}  New file                │") != null);
    try t.expect(std.mem.indexOf(u8, dropped, "│  \u{F1DA}  Open recent file       ▸│") != null);
    try t.expect(std.mem.indexOf(u8, dropped, "│─────────────────────────────│") != null);
    try t.expect(std.mem.indexOf(u8, dropped, "ctrl+s") == null);
    // The first ↓ only turns the highlight on (row 0); the marker
    // column shows it; the next ↓ moves.
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expect(app.overlay.menu.highlight);
    try t.expectEqual(@as(usize, 0), app.overlay.menu.cursor);
    try app.render();
    const lit = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(lit);
    try t.expect(std.mem.indexOf(u8, lit, "│▸ \u{F0224}  New file") != null);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expectEqual(@as(usize, 1), app.overlay.menu.cursor);
    // The pointer over a row moves the highlight there; the keyboard
    // carries on from where the pointer left it; a hover on the
    // recent-files row opens its child, a hover back on a leaf closes it.
    try app.handle(.{ .mouse = .{ .x = 20, .y = 6, .kind = .motion } });
    try t.expectEqual(@as(usize, 4), app.overlay.menu.cursor);
    try app.render();
    const hovered = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(hovered);
    try t.expect(std.mem.indexOf(u8, hovered, "│▸ \u{F443}  Switch workspace…") != null);
    try t.expect(std.mem.indexOf(u8, hovered, "│▸ \u{F0224}  New file") == null);
    try app.handle(.{ .key = app_mod.Key.named(.up) });
    try t.expectEqual(@as(usize, 3), app.overlay.menu.cursor);
    try app.handle(.{ .mouse = .{ .x = 20, .y = 5, .kind = .motion } });
    try t.expect(app.overlay.menu.sub != null);
    try t.expectEqual(@as(usize, 3), app.overlay.menu.sub.?.parent);
    try app.handle(.{ .mouse = .{ .x = 20, .y = 2, .kind = .motion } });
    try t.expect(app.overlay.menu.sub == null);
    try t.expectEqual(@as(usize, 0), app.overlay.menu.cursor);
    // A fresh mouse-open again shows no highlight until a hover.
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .press, .button = .left } });
    try t.expect(!app.overlay.menu.highlight);
    try app.handle(.{ .mouse = .{ .x = 20, .y = 3, .kind = .motion } });
    try t.expect(app.overlay.menu.highlight);
    try t.expectEqual(@as(usize, 1), app.overlay.menu.cursor);
    // With File open the pointer on Edit opens Edit (mouse-opened: no
    // highlight), on the brand its menu, on the » its list, back on
    // File its menu; off the bar the open menu stays; the word already
    // open is left alone.
    try app.handle(.{ .mouse = .{ .x = 18, .y = 0, .kind = .motion } });
    try t.expectEqual(Menu.edit, app.menu_bar.open.?);
    try t.expectEqualStrings("Edit", app.overlay.menu.title);
    try t.expect(!app.overlay.menu.highlight);
    try t.expectEqual(@as(u16, 16), app.overlay.menu.x);
    try app.handle(.{ .mouse = .{ .x = 3, .y = 0, .kind = .motion } });
    try t.expectEqual(Menu.brand, app.menu_bar.open.?);
    try app.handle(.{ .mouse = .{ .x = 23, .y = 0, .kind = .motion } });
    try t.expect(app.menu_bar.open == null);
    try t.expect(app.menu_bar.overflow_open);
    try t.expectEqualStrings("Menus", app.overlay.menu.title);
    try app.handle(.{ .mouse = .{ .x = 23, .y = 0, .kind = .motion } });
    try t.expect(app.menu_bar.overflow_open);
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .motion } });
    try t.expectEqual(Menu.file, app.menu_bar.open.?);
    try t.expect(!app.menu_bar.overflow_open);
    try app.handle(.{ .mouse = .{ .x = 60, .y = 12, .kind = .motion } });
    try t.expectEqual(Menu.file, app.menu_bar.open.?);
    try t.expect(app.overlay == .menu);
    app.overlay.menu.cursor = 2;
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .motion } });
    try t.expectEqual(@as(usize, 2), app.overlay.menu.cursor);
    // A keyboard-opened menu keeps its highlight across the switch.
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.menu_bar.open == null);
    try app.handle(.{ .key = app_mod.Key.named(.{ .f = 10 }) });
    try t.expect(app.overlay.menu.highlight);
    try app.handle(.{ .mouse = .{ .x = 18, .y = 0, .kind = .motion } });
    try t.expectEqual(Menu.edit, app.menu_bar.open.?);
    try t.expect(app.overlay.menu.highlight);
    // No menu open: the pointer on a word opens nothing.
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .motion } });
    try t.expect(app.overlay == .none);
    try t.expect(app.menu_bar.open == null);
    try app.handle(.{ .mouse = .{ .x = 12, .y = 0, .kind = .press, .button = .left } });
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
    // Owned: `configPath` answers on the frame arena, and the steps
    // below render frames before it is read again.
    const home = try t.allocator.dupe(u8, (try settings.configPath(&app, .home)).?);
    defer t.allocator.free(home);
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".menu_bar = .always") != null);
}

test "the » list is a dropdown: no title row, no blank row above the bottom border, and the first arrow paints the ▸ cursor" {
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
    try app.handle(.{ .mouse = .{ .x = 23, .y = 0, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expect(app.overlay.menu.dropdown);
    try t.expect(!app.overlay.menu.highlight);
    try app.render();
    const plain = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(plain);
    // Seven rows between the borders — Selection … Help — and nothing else.
    try t.expect(std.mem.indexOf(u8, plain, "Menus") == null);
    try t.expect(std.mem.indexOf(u8, plain, "\u{25b8} ") == null);
    var rows = std.mem.splitScalar(u8, plain, '\n');
    var top: ?usize = null;
    var bottom: ?usize = null;
    var i: usize = 0;
    while (rows.next()) |row| : (i += 1) {
        if (std.mem.indexOf(u8, row, "\u{250c}") != null and top == null and i > 0) top = i;
        if (std.mem.indexOf(u8, row, "\u{2514}") != null and bottom == null and i > 0) bottom = i;
    }
    try t.expectEqual(@as(usize, 7 + 1), bottom.? - top.?);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expect(app.overlay.menu.highlight);
    try app.render();
    const lit = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(lit);
    try t.expect(std.mem.indexOf(u8, lit, "\u{25b8} ") != null);
    // The marker sits on the Selection row: `▸ <icon>  Selection`.
    var lit_rows = std.mem.splitScalar(u8, lit, '\n');
    var marked = false;
    while (lit_rows.next()) |row| if (std.mem.indexOf(u8, row, "Selection") != null and std.mem.indexOf(u8, row, "\u{25b8} ") != null) {
        marked = true;
    };
    try t.expect(marked);
}

// ─── the pin (menu-bar-pin) ─────────────────────────────────────────────

const pin_chip = @import("../ui/pin_chip.zig");

/// The pin chip's rect this frame, by the hit its paint registered —
/// the same question the sidebar's own pin test asks, so a chip that
/// paints without a hit fails rather than passing on the glyph alone.
fn pinHit(app: *const App) ?Rect {
    for (app.hits.items.items) |h| {
        if (h.target == .button and h.target.button == @intFromEnum(render.Button.menu_bar_pin)) return h.rect;
    }
    return null;
}

test "the pin: ui.menu_bar reads always while pinned, the config is untouched, and unpinning gives the mode back" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.menu_bar = .auto;
    try t.expectEqual(Config.MenuBar.auto, mode(&app));
    // Nothing revealed it: the words are down.
    app.hover = null;
    try app.render();
    try t.expect(!shown(&app, app.menu_bar.bar_y));
    try togglePin(&app);
    try t.expect(app.menu_bar.pinned);
    try t.expectEqual(Config.MenuBar.always, mode(&app));
    // The words stay with the pointer nowhere near the row.
    try app.render();
    try t.expect(shown(&app, app.menu_bar.bar_y));
    // A pin is a session, not an edit: the config still says auto.
    try t.expectEqual(Config.MenuBar.auto, app.cfg.ui.menu_bar);
    try togglePin(&app);
    try t.expect(!app.menu_bar.pinned);
    try t.expectEqual(Config.MenuBar.auto, mode(&app));
    try app.render();
    try t.expect(!shown(&app, app.menu_bar.bar_y));
    // Already always on: refused out loud rather than flipping a flag
    // that would change nothing on screen.
    app.cfg.ui.menu_bar = .always;
    try t.expectError(error.Failed, togglePin(&app));
    try t.expect(!app.menu_bar.pinned);
    // Pinned under `.hidden`, the words come up — that is the only
    // thing a pin can mean there, and it is how they go away again.
    app.cfg.ui.menu_bar = .hidden;
    try app.render();
    try t.expect(!shown(&app, app.menu_bar.bar_y));
    try togglePin(&app);
    try app.render();
    try t.expect(shown(&app, app.menu_bar.bar_y));
}

test "the pin chip paints under auto — revealed or pinned — and never under always, where there is nothing to pin" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const screen = @import("../ipc/screen.zig");
    app.tree.visible = false;

    // `.always`, as mnml ships: the words are up and there is no chip.
    try app.render();
    try t.expect(!pinShown(&app, app.menu_bar.bar_y));
    try t.expect(pinHit(&app) == null);
    const always = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(always);
    try t.expect(std.mem.indexOf(u8, always, pin_chip.pin_glyph) == null);

    // `.auto` with the pointer away: no words, so no chip either.
    app.cfg.ui.menu_bar = .auto;
    app.hover = null;
    try app.render();
    try t.expect(!pinShown(&app, app.menu_bar.bar_y));
    try t.expect(pinHit(&app) == null);

    // Revealed: the chip is there, past the words, and it is a hit.
    app.hover = .{ .x = 5, .y = 0 };
    try app.render();
    try t.expect(pinShown(&app, app.menu_bar.bar_y));
    const chip = pinHit(&app) orelse return error.NoPinChip;
    try t.expectEqual(@as(u16, pin_chip.width), chip.w);
    try t.expectEqual(app.menu_bar.bar_y, chip.y);
    try t.expect(chip.x >= app.menu_bar.words_end);
    const revealed = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(revealed);
    try t.expect(std.mem.indexOf(u8, revealed, pin_chip.pin_glyph) != null);

    // A click on it pins, and the chip survives the pointer leaving —
    // which is the whole point of the pin.
    try app.handle(.{ .mouse = .{ .x = chip.x + 1, .y = chip.y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = chip.x + 1, .y = chip.y, .kind = .release, .button = .left } });
    try t.expect(app.menu_bar.pinned);
    app.hover = null;
    try app.render();
    try t.expect(pinHit(&app) != null);
    const pinned = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(pinned);
    try t.expect(std.mem.indexOf(u8, pinned, pin_chip.pin_glyph) != null);

    // Back to `.always` with the pin on: the bar cannot hide, so the
    // chip goes even though `pinned` is still set.
    app.cfg.ui.menu_bar = .always;
    try app.render();
    try t.expect(!pinShown(&app, app.menu_bar.bar_y));
    try t.expect(pinHit(&app) == null);
}

test "the pin chip's menus: the bar's word menu grows a pin row, and the chip's own right press is the pin and the mode" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const context_menus = @import("context_menus.zig");
    app.cfg.ui.menu_bar = .auto;
    app.hover = .{ .x = 5, .y = 0 };
    try app.render();
    const chip = pinHit(&app) orelse return error.NoPinChip;
    try t.expect(try context_menus.openButtonMenu(&app, @intFromEnum(render.Button.menu_bar_pin), chip.x, chip.y));
    try t.expectEqualStrings("Menu bar", app.overlay.menu.title);
    try t.expectEqualStrings("Pin menu bar", app.overlay.menu.items[0].label);
    try t.expectEqual(command.CommandId.@"view.menu_bar_pin", app.overlay.menu.items[0].action.command);
    try t.expectEqualStrings("Menu bar: auto \u{2192} hidden", app.overlay.menu.items[1].label);
    // Run the row: the bar is pinned and the row now reads the way out.
    try command.run(&app, .{ .static = app.overlay.menu.items[0].action.command });
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try t.expect(app.menu_bar.pinned);
    try app.render();
    try t.expect(try context_menus.openButtonMenu(&app, @intFromEnum(render.Button.menu_bar_pin), chip.x, chip.y));
    try t.expectEqualStrings("Unpin menu bar", app.overlay.menu.items[0].label);
    try t.expect(app.overlay.menu.items[0].checked);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // A word's own right-click menu carries the same row after Open.
    try t.expect(try context_menus.openButtonMenu(&app, button_base + @intFromEnum(Menu.file), 12, 0));
    try t.expectEqualStrings("Open", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("Unpin menu bar", app.overlay.menu.items[1].label);
}
