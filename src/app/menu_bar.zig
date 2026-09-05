//! The menu bar — File / Edit / View / Go / Help as words on the
//! palette-bar row, after the sidebar toggle (Rust painted them on the
//! chrome row too, so a menu bar costs no row). A click drops the menu
//! below its word; every row is an existing command. `ui.menu_bar`:
//! `always` paints the words, `hidden` does not, `auto` paints them
//! only while one of the menus is open (`view.menu_bar_open`, then
//! the words are there to move along). `view.menu_bar_cycle` steps the
//! setting and persists it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const settings = @import("settings.zig");

pub const table = .{
    .@"view.menu_bar_cycle" = &cycleCmd,
    .@"view.menu_bar_open" = &openFirstCmd,
};

pub const Menu = enum(u8) {
    file,
    edit,
    view,
    go,
    help,

    pub fn label(m: Menu) []const u8 {
        return switch (m) {
            .file => "File",
            .edit => "Edit",
            .view => "View",
            .go => "Go",
            .help => "Help",
        };
    }

    pub const all = std.enums.values(Menu);
};

/// `Button` ids for the words: `button_base + @intFromEnum(menu)`.
pub const button_base: u32 = 0x6d62_0000;

pub fn buttonOf(id: u32) ?Menu {
    if (id < button_base or id >= button_base + Menu.all.len) return null;
    return @enumFromInt(id - button_base);
}

/// Whether the words paint this frame.
pub fn shown(app: *const App) bool {
    return switch (app.cfg.ui.menu_bar) {
        .always => true,
        .hidden => false,
        .auto => app.menu_bar_open != null,
    };
}

fn rowsOf(m: Menu) []const MenuItem {
    return switch (m) {
        .file => &.{
            .{ .label = "New file", .action = .{ .command = .@"file.new" } },
            .{ .label = "Open file…", .action = .{ .command = .@"picker.files" } },
            .{ .label = "Open recent…", .action = .{ .command = .@"picker.recent" } },
            .{ .label = "Save", .action = .{ .command = .@"file.save" }, .separator_before = true },
            .{ .label = "Close tab", .action = .{ .command = .@"buffer.close" }, .separator_before = true },
            .{ .label = "Reopen closed tab", .action = .{ .command = .@"buffer.reopen" } },
            .{ .label = "Settings…", .action = .{ .command = .@"view.settings" }, .separator_before = true },
            .{ .label = "Quit", .action = .{ .command = .@"app.quit" }, .separator_before = true },
        },
        .edit => &.{
            .{ .label = "Undo", .action = .{ .command = .@"editor.undo" } },
            .{ .label = "Redo", .action = .{ .command = .@"editor.redo" } },
            .{ .label = "Cut", .action = .{ .command = .@"editor.cut" }, .separator_before = true },
            .{ .label = "Copy", .action = .{ .command = .@"editor.copy" } },
            .{ .label = "Paste", .action = .{ .command = .@"editor.paste" } },
            .{ .label = "Select all", .action = .{ .command = .@"editor.select_all" } },
            .{ .label = "Find", .action = .{ .command = .@"find.find" }, .separator_before = true },
            .{ .label = "Replace", .action = .{ .command = .@"find.replace" } },
            .{ .label = "Find in files", .action = .{ .command = .@"find.grep" } },
            .{ .label = "Toggle line comment", .action = .{ .command = .@"editor.toggle_line_comment" }, .separator_before = true },
        },
        .view => &.{
            .{ .label = "Command palette", .action = .{ .command = .palette } },
            .{ .label = "Toggle left panel", .action = .{ .command = .@"view.toggle_tree" }, .separator_before = true },
            .{ .label = "Toggle right panel", .action = .{ .command = .@"view.toggle_right_panel" } },
            .{ .label = "Zen mode", .action = .{ .command = .@"view.zen" } },
            .{ .label = "Split right", .action = .{ .command = .@"view.split_right" }, .separator_before = true },
            .{ .label = "Split down", .action = .{ .command = .@"view.split_down" } },
            .{ .label = "Equalize splits", .action = .{ .command = .@"view.equalize_splits" } },
            .{ .label = "Auto-equalize on split / close", .action = .{ .command = .@"view.toggle_auto_equalize_splits" } },
            .{ .label = "Theme…", .action = .{ .command = .@"theme.pick" }, .separator_before = true },
            .{ .label = "Menu bar: always / auto / hidden", .action = .{ .command = .@"view.menu_bar_cycle" } },
        },
        .go => &.{
            .{ .label = "Go to file…", .action = .{ .command = .@"picker.files" } },
            .{ .label = "Go to line…", .action = .{ .command = .@"editor.goto_line" } },
            .{ .label = "Go to symbol…", .action = .{ .command = .@"lsp.symbols" } },
            .{ .label = "Go to definition", .action = .{ .command = .@"lsp.goto_definition" } },
            .{ .label = "Back", .action = .{ .command = .@"nav.back" }, .separator_before = true },
            .{ .label = "Forward", .action = .{ .command = .@"nav.forward" } },
            .{ .label = "Next buffer", .action = .{ .command = .@"buffer.next" }, .separator_before = true },
            .{ .label = "Previous buffer", .action = .{ .command = .@"buffer.prev" } },
        },
        .help => &.{
            .{ .label = "Cheatsheet", .action = .{ .command = .@"view.cheatsheet" } },
            .{ .label = "Keybindings & help", .action = .{ .command = .@"view.help" } },
            .{ .label = "Welcome", .action = .{ .command = .@"view.welcome" } },
            .{ .label = "Messages", .action = .{ .command = .@"messages.show" }, .separator_before = true },
            .{ .label = "About mnml", .action = .{ .command = .@"view.about" }, .separator_before = true },
        },
    };
}

/// Drop `m`'s menu at `(x, y)` — the word's left edge, the row below it.
pub fn open(app: *App, m: Menu, x: u16, y: u16) Allocator.Error!void {
    const rows = try app.gpa.dupe(MenuItem, rowsOf(m));
    errdefer app.gpa.free(rows);
    try app.openMenu(m.label(), rows, x, y);
    app.menu_bar_open = m;
}

/// `closeOverlay` calls this: the words of an `auto` bar go with the menu.
pub fn menuClosed(app: *App) void {
    if (app.menu_bar_open != null) {
        app.menu_bar_open = null;
        app.needs_render = true;
    }
}

/// `view.menu_bar_open`: the File menu, under its word.
fn openFirstCmd(app: *App) CommandError!void {
    if (app.cfg.ui.menu_bar == .hidden) return app.diag.fail(app.frame.allocator(), "the menu bar is hidden (ui.menu_bar)", .{});
    try open(app, .file, app.menu_bar_x, 1);
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

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "menu bar: always paints the words on the bar, a click drops the menu; hidden paints none; auto shows them only while a menu is open; cycle persists" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const screen = @import("../ipc/screen.zig");
    try app.render();
    const always = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(always);
    const row0 = always[0..std.mem.indexOfScalar(u8, always, '\n').?];
    try t.expect(std.mem.indexOf(u8, row0, " File ") != null);
    try t.expect(std.mem.indexOf(u8, row0, " Help ") != null);
    var file_x: ?u16 = null;
    var x: u16 = 0;
    while (x < 120) : (x += 1) if (app.hits.at(x, 0)) |h| if (h == .button and buttonOf(h.button) == .file) {
        file_x = x;
        break;
    };
    try t.expect(file_x != null);
    try app.handle(.{ .mouse = .{ .x = file_x.?, .y = 0, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("File", app.overlay.menu.title);
    try t.expectEqualStrings("New file", app.overlay.menu.items[0].label);
    try t.expectEqual(command.CommandId.@"file.new", app.overlay.menu.items[0].action.command);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(app.menu_bar_open == null);
    // Hidden: no words, and the open command refuses.
    app.cfg.ui.menu_bar = .hidden;
    try app.render();
    const hidden = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(hidden);
    try t.expect(std.mem.indexOf(u8, hidden[0..std.mem.indexOfScalar(u8, hidden, '\n').?], " File ") == null);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.menu_bar_open" }));
    // Auto: the words appear with the menu and go with it.
    app.cfg.ui.menu_bar = .auto;
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
    try t.expect(app.menu_bar_open == null);
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
