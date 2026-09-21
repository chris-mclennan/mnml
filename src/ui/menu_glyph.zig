//! The glyph a menu row draws before its label, Rust's rule
//! (`ui/menu_glyph.rs`'s `command_glyph`): a verb in the command id's
//! last segment names the action glyph, else its first segment names
//! the domain's, else the play triangle — so every row of every menu
//! carries an icon without any opener naming one (a `MenuItem.icon`
//! overrides). Nerd Font codepoints, each with its one-character ASCII
//! twin — `--ascii` / `ui.ascii_icons` paints the twin, as every other
//! glyph site in mnml does (Rust paints no column there).
//! The whole column is `width` cells wide, glyph plus two cells of
//! air, and every row pays for it so labels line up whether or not a
//! row has a glyph.

const std = @import("std");
const command = @import("../core/command.zig");
const bufferline = @import("bufferline.zig");

/// Glyph column width in cells: the one-cell glyph and two cells of
/// air before the label (Rust's `COLUMN_W`).
pub const width: u16 = 3;

/// The action table: matched against the LAST dotted segment of a
/// command id, as a substring, first match wins (Rust `command_glyph`'s
/// `ACTION`). An action glyph outranks a domain one.
pub const by_action = [_]Entry{
    .{ .needle = "sort", .glyph = "\u{f0dc}", .fallback = "~" }, //  sort
    .{ .needle = "undo", .glyph = "\u{f0e2}", .fallback = "u" }, //  undo
    .{ .needle = "redo", .glyph = "\u{f01e}", .fallback = "r" }, //  repeat
    .{ .needle = "paste", .glyph = "\u{f0ea}", .fallback = "p" }, //  paste
    .{ .needle = "copy", .glyph = "\u{f0c5}", .fallback = "c" }, //  copy
    .{ .needle = "yank", .glyph = "\u{f0c5}", .fallback = "c" },
    .{ .needle = "cut", .glyph = "\u{f0c4}", .fallback = "x" }, //  scissors
    .{ .needle = "clear", .glyph = "\u{f12d}", .fallback = "-" }, //  eraser
    .{ .needle = "restart", .glyph = "\u{f021}", .fallback = "@" }, //  refresh
    .{ .needle = "refresh", .glyph = "\u{f021}", .fallback = "@" },
    .{ .needle = "reload", .glyph = "\u{f021}", .fallback = "@" },
    .{ .needle = "reset", .glyph = "\u{f0e2}", .fallback = "u" },
    .{ .needle = "close", .glyph = "\u{f00d}", .fallback = "x" }, //  close
    .{ .needle = "quit", .glyph = "\u{f00d}", .fallback = "x" },
    .{ .needle = "kill", .glyph = "\u{f00d}", .fallback = "x" },
    .{ .needle = "stop", .glyph = "\u{f04d}", .fallback = "." }, //  stop
    .{ .needle = "delete", .glyph = "\u{f1f8}", .fallback = "d" }, //  trash
    .{ .needle = "remove", .glyph = "\u{f1f8}", .fallback = "d" },
    .{ .needle = "trash", .glyph = "\u{f1f8}", .fallback = "d" },
    .{ .needle = "save", .glyph = "\u{f0c7}", .fallback = "s" }, //  floppy
    .{ .needle = "write", .glyph = "\u{f0c7}", .fallback = "s" },
    .{ .needle = "definition", .glyph = "\u{eab5}", .fallback = ">" }, //  arrow-right (codicon)
    .{ .needle = "references", .glyph = "\u{f0c1}", .fallback = "&" }, //  link
    .{ .needle = "hover", .glyph = "\u{f05a}", .fallback = "i" }, //  info-circle
    .{ .needle = "symbol", .glyph = "\u{f1b3}", .fallback = "#" }, //  cubes
    .{ .needle = "rename", .glyph = "\u{f044}", .fallback = "e" }, //  pencil-square
    .{ .needle = "format", .glyph = "\u{f036}", .fallback = "=" }, //  align-left
    .{ .needle = "comment", .glyph = "\u{f075}", .fallback = "/" }, //  comment
    .{ .needle = "indent", .glyph = "\u{f03c}", .fallback = ">" }, //  indent
    .{ .needle = "fold", .glyph = "\u{f0d7}", .fallback = "v" }, //  caret-down
    .{ .needle = "select", .glyph = "\u{f0c9}", .fallback = "=" }, //  bars
    .{ .needle = "goto", .glyph = "\u{eab5}", .fallback = ">" },
    .{ .needle = "jump", .glyph = "\u{eab5}", .fallback = ">" },
    .{ .needle = "commit", .glyph = "\u{f1d3}", .fallback = "g" }, //  git
    .{ .needle = "push", .glyph = "\u{f062}", .fallback = "^" }, //  arrow-up
    .{ .needle = "pull", .glyph = "\u{f063}", .fallback = "v" }, //  arrow-down
    .{ .needle = "fetch", .glyph = "\u{f063}", .fallback = "v" },
    .{ .needle = "stash", .glyph = "\u{f187}", .fallback = "z" }, //  archive
    .{ .needle = "branch", .glyph = "\u{f126}", .fallback = "y" }, //  code-fork
    .{ .needle = "merge", .glyph = "\u{f126}", .fallback = "y" },
    .{ .needle = "rebase", .glyph = "\u{f126}", .fallback = "y" },
    .{ .needle = "diff", .glyph = "\u{f0db}", .fallback = "|" }, //  columns
    .{ .needle = "stage", .glyph = "\u{f067}", .fallback = "+" }, //  plus
    .{ .needle = "unstage", .glyph = "\u{f068}", .fallback = "-" }, //  minus
    .{ .needle = "new", .glyph = "\u{f067}", .fallback = "+" },
    .{ .needle = "open", .glyph = "\u{f07c}", .fallback = "o" }, //  folder-open
    .{ .needle = "reveal", .glyph = "\u{f002}", .fallback = "?" }, //  search
    .{ .needle = "find", .glyph = "\u{f002}", .fallback = "?" },
    .{ .needle = "search", .glyph = "\u{f002}", .fallback = "?" },
    .{ .needle = "grep", .glyph = "\u{f002}", .fallback = "?" },
    .{ .needle = "theme", .glyph = "\u{f043}", .fallback = "t" }, //  tint
    .{ .needle = "toggle", .glyph = "\u{f205}", .fallback = "~" }, //  toggle-on
    .{ .needle = "dock", .glyph = "\u{f0db}", .fallback = "|" },
    .{ .needle = "split", .glyph = "\u{f0db}", .fallback = "|" },
    .{ .needle = "equalize", .glyph = "\u{f0db}", .fallback = "|" },
    .{ .needle = "maximize", .glyph = "\u{f065}", .fallback = "^" }, //  expand
    .{ .needle = "zoom", .glyph = "\u{f065}", .fallback = "^" },
    .{ .needle = "settings", .glyph = "\u{f013}", .fallback = "*" }, //  gear
    .{ .needle = "config", .glyph = "\u{f013}", .fallback = "*" },
    .{ .needle = "help", .glyph = "\u{f059}", .fallback = "?" }, //  question-circle
    .{ .needle = "about", .glyph = "\u{f05a}", .fallback = "i" },
    .{ .needle = "pin", .glyph = "\u{f08d}", .fallback = "^" }, //  thumb-tack
    .{ .needle = "hide", .glyph = "\u{f070}", .fallback = "-" }, //  eye-slash
    .{ .needle = "show", .glyph = "\u{f06e}", .fallback = "o" }, //  eye
    .{ .needle = "run", .glyph = "\u{f04b}", .fallback = ">" }, //  play
    .{ .needle = "test", .glyph = "\u{f0c3}", .fallback = "t" }, //  flask
    .{ .needle = "build", .glyph = "\u{f0ad}", .fallback = "%" }, //  wrench
    .{ .needle = "install", .glyph = "\u{f019}", .fallback = "v" }, //  download
    .{ .needle = "update", .glyph = "\u{f019}", .fallback = "v" },
    .{ .needle = "next", .glyph = "\u{f061}", .fallback = ">" }, //  arrow-right
    .{ .needle = "prev", .glyph = "\u{f060}", .fallback = "<" }, //  arrow-left
};

/// The domain table: the FIRST dotted segment, exact, only when the
/// action table says nothing (Rust's `DOMAIN`).
pub const by_domain = [_]Entry{
    .{ .needle = "git", .glyph = "\u{f1d3}", .fallback = "g" }, //  git
    .{ .needle = "ai", .glyph = "\u{F06A9}", .fallback = "*" }, // 󰚩 robot
    .{ .needle = "browser", .glyph = "\u{f0ac}", .fallback = "w" }, //  globe
    .{ .needle = "http", .glyph = "\u{f1d8}", .fallback = "@" }, //  paper-plane
    .{ .needle = "term", .glyph = "\u{f120}", .fallback = "$" }, //  terminal
    .{ .needle = "pty", .glyph = "\u{f120}", .fallback = "$" },
    .{ .needle = "tools", .glyph = "\u{f120}", .fallback = "$" },
    .{ .needle = "lsp", .glyph = "\u{f085}", .fallback = "!" }, //  cogs
    .{ .needle = "dap", .glyph = "\u{f188}", .fallback = "d" }, //  bug
    .{ .needle = "debug", .glyph = "\u{f188}", .fallback = "d" },
    .{ .needle = "files", .glyph = "\u{f07b}", .fallback = "/" }, //  folder
    .{ .needle = "tree", .glyph = "\u{f07b}", .fallback = "/" },
    .{ .needle = "buffer", .glyph = "\u{f15b}", .fallback = "b" }, //  file
    .{ .needle = "tab", .glyph = "\u{f15b}", .fallback = "t" },
    .{ .needle = "editor", .glyph = "\u{f044}", .fallback = "e" }, //  pencil-square
    .{ .needle = "view", .glyph = "\u{f06e}", .fallback = "v" }, //  eye
    .{ .needle = "window", .glyph = "\u{f0db}", .fallback = "|" }, //  columns
    .{ .needle = "picker", .glyph = "\u{f002}", .fallback = "?" }, //  search
    .{ .needle = "notes", .glyph = "\u{f249}", .fallback = "n" }, //  sticky-note
    .{ .needle = "todos", .glyph = "\u{f046}", .fallback = "+" }, //  check-square
    .{ .needle = "findings", .glyph = "\u{F1623}", .fallback = "?" }, // 󱘣 magnify-scan
    .{ .needle = "integrations", .glyph = "\u{f12e}", .fallback = "&" }, //  puzzle-piece
    .{ .needle = "cloud", .glyph = "\u{f0c2}", .fallback = "c" }, //  cloud
    .{ .needle = "mixr", .glyph = "\u{f001}", .fallback = "m" }, //  music
};

/// What a command with neither an action nor a domain match paints.
pub const fallback_glyph = "\u{f04b}"; //  play
pub const fallback_ascii = ">";

pub const Entry = struct { needle: []const u8, glyph: []const u8, fallback: []const u8 };

/// The glyph for a command id, Rust's rule: the action table against
/// the last dotted segment (substring, first match), then the domain
/// table against the first segment, then the play triangle — or the
/// matched entry's one-character twin under `ascii`.
pub fn forCommandName(id: []const u8, ascii: bool) []const u8 {
    var lower_buf: [96]u8 = undefined;
    const lower = std.ascii.lowerString(lower_buf[0..@min(id.len, lower_buf.len)], id[0..@min(id.len, lower_buf.len)]);
    const dot = std.mem.indexOfScalar(u8, lower, '.');
    const ns = if (dot) |d| lower[0..d] else "";
    const rest = if (dot) |d| lower[d + 1 ..] else lower;
    const action = if (std.mem.lastIndexOfScalar(u8, rest, '.')) |d| rest[d + 1 ..] else rest;
    for (by_action) |e| if (std.mem.indexOf(u8, action, e.needle) != null) return if (ascii) e.fallback else e.glyph;
    for (by_domain) |e| if (std.mem.eql(u8, e.needle, ns)) return if (ascii) e.fallback else e.glyph;
    return if (ascii) fallback_ascii else fallback_glyph;
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
        .set_panel_sort, .script_sort => if (ascii) "~" else "\u{f0dc}", // fa-sort
        .ai_profile => if (ascii) "!" else "\u{f0e7}", // fa-flash: a launch profile
        .dock_set => if (ascii) "%" else "\u{f013}", // fa-gear: a dock setting
        .toggle_auto_refresh => if (ascii) "@" else "\u{f021}", // fa-refresh
        .set_coverage_mode => if (ascii) "%" else "\u{f0e4}", // fa-dashboard
        // The launcher dock's *Show* rows: a label, on or off.
        .set_dock_labels => if (ascii) "#" else "\u{f02b}", // fa-tag
        // Its *Place* rows: which of the frame's rows the strip takes.
        .set_dock_placement => if (ascii) "^" else "\u{f07d}", // fa-arrows_v
        // Its *Align* rows: where the run sits.
        .set_dock_align => if (ascii) "|" else "\u{f036}", // fa-align_left
        // Its *Show the + button* row.
        .set_dock_plus => if (ascii) "+" else "\u{F0415}", // nf-md-plus, the tab bar's own
        // The `Icon ▸` rows on the two branded chips. The row's glyph
        // IS the icon it picks — the resolver's, not a brush: you
        // choose by the picture, and the label only says whose it is.
        // Straight from `bufferline`, the one place a tag becomes a
        // codepoint, so a row can never offer a glyph the chrome
        // would not paint. Each keeps its own `--ascii` twin.
        .set_claude_mark => |m| blk: {
            const mk = bufferline.claudeMark(m);
            break :blk if (ascii) mk.fallback else mk.glyph;
        },
        .set_terminal_mark => |m| blk: {
            const mk = bufferline.terminalMark(m);
            break :blk if (ascii) mk.fallback else mk.glyph;
        },
        .menu_bar => if (ascii) "=" else "\u{f0c9}", // fa-bars: a menu-bar menu
        .git_palette => if (ascii) "g" else "\u{e702}", // dev-git: a palette row's action
        // The chip menu's *Requests…* row: what this number cost.
        .requests_for => if (ascii) "<>" else "\u{f0aee}", // nf-md-swap_horizontal_bold
        // // changed (bottom-dock): a third arrow — down, to the dock.
        .move_section => |ms| switch (ms.side) {
            .right => if (ascii) ">" else "\u{f061}", // fa-arrow_right
            .left => if (ascii) "<" else "\u{f060}", // fa-arrow_left
            .bottom => if (ascii) "v" else "\u{f063}", // fa-arrow_down
        },
        // // changed (lua-plumbing): a script list's row menu.
        .script_list_fold => if (ascii) "+" else "\u{f0da}", // fa-caret_right
        .script_list_menu => if (ascii) "L" else "\u{f08b1}", // nf-md-language_lua
        .script_list_refresh => if (ascii) "@" else "\u{f021}", // fa-refresh
        .script_section_show => if (ascii) "L" else "\u{f08b1}", // nf-md-language_lua
        // right-click: the four string-carrying actions.
        .copy_text => if (ascii) "y" else "\u{f0c5}", // fa-copy
        .open_url => if (ascii) "w" else "\u{f0ac}", // fa-globe
        .open_path => if (ascii) "o" else "\u{f07c}", // fa-folder_open
        // colors: a `Color: …` row, the theme pill's brush.
        .set_theme, .session_color, .repo_color => if (ascii) "t" else "\u{f1fc}", // fa-paint_brush
        // // changed (lua-track): the row openers, the filter, the bind.
        .diag_row_open, .script_row_open => if (ascii) "o" else "\u{f07c}", // fa-folder_open
        .set_severity_filter => if (ascii) "~" else "\u{f0b0}", // fa-filter
        .lua_bind => if (ascii) "k" else "\u{f11c}", // fa-keyboard_o
        // // changed (lsp-defaults): the LSP chip menu's Install row.
        .lsp_install => if (ascii) "v" else "\u{f019}", // fa-download, the tools table's install row
        .dyn, .none => if (it.submenu.len > 0) (if (ascii) "=" else "\u{f0c9}") else "",
    };
}

// ── tests ──

const testing = std.testing;

test "an `Icon ▸` row draws the icon it picks, not a generic brush — the resolver's glyph, and its own `--ascii` twin" {
    // The user's report these rows are for: both marks drew
    // fa-paint_brush, so the only way to tell the two choices apart
    // was to read the label. Now the picture IS the choice.
    const bl = @import("bufferline.zig");
    const figure: command.MenuItem = .{ .label = "Claude Code", .action = .{ .set_claude_mark = .figure } };
    const spark: command.MenuItem = .{ .label = "Anthropic", .action = .{ .set_claude_mark = .spark } };
    try testing.expectEqualStrings(bl.claude_glyph, forItem(figure, false));
    try testing.expectEqualStrings(bl.spark_glyph, forItem(spark, false));
    try testing.expectEqualStrings(bl.claude_ascii, forItem(figure, true));
    try testing.expectEqualStrings(bl.spark_ascii, forItem(spark, true));
    const ghost: command.MenuItem = .{ .label = "Ghostty", .action = .{ .set_terminal_mark = .ghostty } };
    const codicon: command.MenuItem = .{ .label = "Terminal", .action = .{ .set_terminal_mark = .terminal } };
    try testing.expectEqualStrings(bl.ghost_glyph, forItem(ghost, false));
    try testing.expectEqualStrings(bl.term_glyph, forItem(codicon, false));
    try testing.expectEqualStrings(bl.ghost_ascii, forItem(ghost, true));
    try testing.expectEqualStrings(bl.term_ascii, forItem(codicon, true));
    // The two rows of a submenu are never the same picture — that was
    // the whole complaint.
    try testing.expect(!std.mem.eql(u8, forItem(figure, false), forItem(spark, false)));
    try testing.expect(!std.mem.eql(u8, forItem(ghost, false), forItem(codicon, false)));
    // `.custom` bakes the user's art behind the ghost's codepoint, so
    // its row paints the same cell — the font, not the chrome, says
    // what it looks like.
    const custom: command.MenuItem = .{ .label = "Custom SVG…", .action = .{ .set_terminal_mark = .custom } };
    try testing.expectEqualStrings(bl.ghost_glyph, forItem(custom, false));
}

test "Rust's rule: the action table by the last segment, the domain table by the first, the play triangle last; an icon overrides; a twin under ascii" {
    try testing.expectEqualStrings("\u{f1d3}", forCommandName("git.commit", false));
    try testing.expectEqualStrings("g", forCommandName("git.commit", true));
    try testing.expectEqualStrings("s", forCommandName("file.save", true));
    // `save` is an action match — not the `file` domain's glyph.
    try testing.expectEqualStrings("\u{f0c7}", forCommand(.@"file.save", false));
    try testing.expectEqualStrings("\u{f067}", forCommandName("scratch.new", false));
    try testing.expectEqualStrings("\u{f07c}", forCommandName("buffer.reopen", false));
    try testing.expectEqualStrings("\u{f07c}", forCommandName("files.open_split", false));
    try testing.expectEqualStrings("\u{f120}", forCommandName("term.shell", false));
    try testing.expectEqualStrings(fallback_glyph, forCommandName("scratch.from_clipboard", false));
    try testing.expectEqualStrings(fallback_glyph, forCommandName("nope.what", false));
    try testing.expectEqualStrings(fallback_ascii, forCommandName("nope.what", true));
    // The last dotted segment is the action: `a.b.c` matches on `c`.
    try testing.expectEqualStrings("\u{f00d}", forCommandName("ai.dashboard.kill", false));
    const it: command.MenuItem = .{ .label = "x", .action = .{ .command = .@"file.save" }, .icon = "Z" };
    try testing.expectEqualStrings("Z", forItem(it, false));
    // An icon without a twin falls back to the command's twin under ascii.
    try testing.expectEqualStrings("s", forItem(it, true));
    const twin: command.MenuItem = .{ .label = "x", .action = .none, .icon = "Z", .icon_ascii = "z" };
    try testing.expectEqualStrings("z", forItem(twin, true));
    const parent: command.MenuItem = .{ .label = "More", .action = .none, .submenu = &.{it} };
    try testing.expectEqualStrings("\u{f0c9}", forItem(parent, false));
    try testing.expectEqualStrings("=", forItem(parent, true));
    // Every glyph is one cell wide under wcwidth (a Nerd Font PUA);
    // every twin is one printable ASCII byte.
    for (by_action) |e| {
        const cp = try std.unicode.utf8Decode(e.glyph);
        try testing.expect((cp >= 0xe000 and cp <= 0xf8ff) or (cp >= 0xf0000 and cp <= 0xfffff));
    }
    for (by_domain) |e| {
        const cp = try std.unicode.utf8Decode(e.glyph);
        try testing.expect((cp >= 0xe000 and cp <= 0xf8ff) or (cp >= 0xf0000 and cp <= 0xfffff));
    }
    for (by_action ++ by_domain) |e| try testing.expect(e.fallback.len == 1 and std.ascii.isPrint(e.fallback[0]) and e.fallback[0] != ' ');
}
