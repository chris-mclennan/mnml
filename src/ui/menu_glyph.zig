//! The glyph a context-menu row draws before its label — one per
//! command group, so every row of every menu carries an icon without
//! any opener naming one (a `MenuItem.icon` overrides the group's).
//! Nerd Font codepoints, each with its one-character ASCII twin —
//! `--ascii` / `ui.ascii_icons` paints the twin, as every other glyph
//! site in mnml does. The whole column is `width` cells wide, glyph
//! plus one cell of air, and every row pays for it so labels line up
//! whether or not a row has a glyph.

const std = @import("std");
const command = @import("../core/command.zig");

/// Glyph column width in cells (a one-cell glyph and a space).
pub const width: u16 = 2;

pub const Entry = struct { group: []const u8, glyph: []const u8, fallback: []const u8 };

/// By command-id prefix (the part before the dot); the first match wins.
pub const by_group = [_]Entry{
    .{ .group = "file", .glyph = "\u{f15b}", .fallback = "f" }, //  file
    .{ .group = "files", .glyph = "\u{f15b}", .fallback = "f" },
    .{ .group = "buffer", .glyph = "\u{f0c5}", .fallback = "b" }, //  copy / tab
    .{ .group = "tab", .glyph = "\u{f24d}", .fallback = "t" }, //  clone
    .{ .group = "editor", .glyph = "\u{f044}", .fallback = "e" }, //  pencil-square
    .{ .group = "view", .glyph = "\u{f06e}", .fallback = "v" }, //  eye
    .{ .group = "tree", .glyph = "\u{f07b}", .fallback = "/" }, //  folder
    .{ .group = "picker", .glyph = "\u{f002}", .fallback = "?" }, //  search
    .{ .group = "git", .glyph = "\u{e702}", .fallback = "g" }, //  git
    .{ .group = "lsp", .glyph = "\u{f0e7}", .fallback = "!" }, //  bolt
    .{ .group = "http", .glyph = "\u{f0ac}", .fallback = "@" }, //  globe
    .{ .group = "ws", .glyph = "\u{f0ec}", .fallback = "~" }, //  exchange
    .{ .group = "browser", .glyph = "\u{f268}", .fallback = "w" }, //  chrome
    .{ .group = "term", .glyph = "\u{f120}", .fallback = "$" }, //  terminal
    .{ .group = "ai", .glyph = "\u{2733}", .fallback = "*" }, // ✳ claude
    .{ .group = "todos", .glyph = "\u{f0ae}", .fallback = "+" }, //  tasks
    .{ .group = "notes", .glyph = "\u{f249}", .fallback = "n" }, //  sticky-note
    .{ .group = "messages", .glyph = "\u{f0f3}", .fallback = "!" }, //  bell
    .{ .group = "toast", .glyph = "\u{f0f3}", .fallback = "!" },
    .{ .group = "perf", .glyph = "\u{f0e4}", .fallback = "%" }, //  dashboard
    .{ .group = "workspace", .glyph = "\u{f023}", .fallback = "#" }, //  lock
    .{ .group = "trusted", .glyph = "\u{f023}", .fallback = "#" },
    .{ .group = "integrations", .glyph = "\u{f1e6}", .fallback = "&" }, //  plug
    .{ .group = "marketplace", .glyph = "\u{f290}", .fallback = "&" }, //  shopping-bag
    .{ .group = "harpoon", .glyph = "\u{f08d}", .fallback = "^" }, //  thumb-tack
    .{ .group = "markdown", .glyph = "\u{f48a}", .fallback = "m" }, //  markdown
    .{ .group = "menu", .glyph = "\u{f0c9}", .fallback = "=" }, //  bars
    .{ .group = "clock", .glyph = "\u{f017}", .fallback = "o" }, //  clock
    .{ .group = "session", .glyph = "\u{f0c7}", .fallback = "s" }, //  save
    .{ .group = "dap", .glyph = "\u{f188}", .fallback = "d" }, //  bug
    .{ .group = "image", .glyph = "\u{f03e}", .fallback = "i" }, //  image
};

/// The glyph for a command id, by its group prefix (its ASCII twin
/// under `ascii`); empty when the group has none.
pub fn forCommandName(id: []const u8, ascii: bool) []const u8 {
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse return "";
    const group = id[0..dot];
    for (by_group) |e| if (std.mem.eql(u8, e.group, group)) return if (ascii) e.fallback else e.glyph;
    return "";
}

pub fn forCommand(id: command.CommandId, ascii: bool) []const u8 {
    return forCommandName(command.name(id), ascii);
}

/// What a row paints: its own icon, else its command's group glyph,
/// else a submenu marker for a row that only opens more rows. Under
/// `ascii` an own icon paints its `icon_ascii` twin, or the group's.
pub fn forItem(it: command.MenuItem, ascii: bool) []const u8 {
    if (it.icon) |g| if (!ascii) return g;
    if (ascii) if (it.icon_ascii) |a| return a;
    return switch (it.action) {
        .command => |id| forCommand(id, ascii),
        .set_panel_sort => if (ascii) "~" else "\u{f0dc}", // fa-sort
        .ai_profile => if (ascii) "!" else "\u{f0e7}", // fa-flash: a launch profile
        .dock_set => if (ascii) "%" else "\u{f013}", // fa-gear: a dock setting
        .toggle_auto_refresh => if (ascii) "@" else "\u{f021}", // fa-refresh
        .set_coverage_mode => if (ascii) "%" else "\u{f0e4}", // fa-dashboard
        .menu_bar => if (ascii) "=" else "\u{f0c9}", // fa-bars: a menu-bar menu
        .dyn, .none => if (it.submenu.len > 0) (if (ascii) "=" else "\u{f0c9}") else "",
    };
}

// ── tests ──

const testing = std.testing;

test "every group prefix maps to one glyph and one ASCII twin; an unknown group is blank; an icon overrides" {
    try testing.expectEqualStrings("\u{e702}", forCommandName("git.commit", false));
    try testing.expectEqualStrings("g", forCommandName("git.commit", true));
    try testing.expectEqualStrings("\u{f15b}", forCommand(.@"file.save", false));
    try testing.expectEqualStrings("", forCommandName("nope.what", false));
    try testing.expectEqualStrings("", forCommandName("nodot", true));
    const it: command.MenuItem = .{ .label = "x", .action = .{ .command = .@"file.save" }, .icon = "Z" };
    try testing.expectEqualStrings("Z", forItem(it, false));
    // An icon without a twin falls back to the group's twin under ascii.
    try testing.expectEqualStrings("f", forItem(it, true));
    const twin: command.MenuItem = .{ .label = "x", .action = .none, .icon = "Z", .icon_ascii = "z" };
    try testing.expectEqualStrings("z", forItem(twin, true));
    const parent: command.MenuItem = .{ .label = "More", .action = .none, .submenu = &.{it} };
    try testing.expectEqualStrings("\u{f0c9}", forItem(parent, false));
    try testing.expectEqualStrings("=", forItem(parent, true));
    // Every glyph is one cell wide under wcwidth (a Nerd Font PUA or ✳);
    // every twin is one printable ASCII byte.
    for (by_group) |e| {
        const cp = try std.unicode.utf8Decode(e.glyph);
        try testing.expect((cp >= 0xe000 and cp <= 0xf8ff) or cp == 0x2733);
        try testing.expect(e.fallback.len == 1 and std.ascii.isPrint(e.fallback[0]) and e.fallback[0] != ' ');
    }
}
