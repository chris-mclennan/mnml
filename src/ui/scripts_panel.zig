//! The SCRIPTS panel's row: `<kind> <name>  <file>:<line>` — the kind
//! word dim in a fixed column, the name in the text colour, the location
//! dim and clipped from the left so the file and line survive a long
//! name (the DIAGNOSTICS row's rule). A link row (`+ init.lua …`, when
//! the workspace has none) paints in the accent. The panel chrome
//! (header, refresh chip, filter, scrollbar, hits) is `ListPanel`'s.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const lua_mod = @import("../scripting/lua.zig");

pub const Kind = lua_mod.OriginKind;

pub const Row = struct {
    kind: Kind = .command,
    /// The command id, hook name, segment or source id — or the link's
    /// words.
    name: []const u8,
    /// `file:line`, workspace-relative; empty when unknown or a link.
    loc: []const u8 = "",
    /// Absolute; empty for a link row.
    file: []const u8 = "",
    /// 1-based; 0 unknown.
    line: u32 = 0,
    /// The `+ init.lua` row: Enter creates the file from the template.
    link: bool = false,
};

/// The kind column's word, four cells wide.
pub fn kindWord(k: Kind) []const u8 {
    return switch (k) {
        .command => "cmd ",
        .hook => "hook",
        .segment => "seg ",
        .source => "pick",
    };
}

pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    var x = r.x;
    const end = r.right();
    if (row.link) {
        x += ui.putStr(x, r.y, end -| x, row.name, Theme.withFg(base, t.accent.fg));
        return;
    }
    x += ui.putStr(x, r.y, end -| x, kindWord(row.kind), Theme.withFg(base, t.muted.fg));
    x += ui.putStr(x, r.y, end -| x, " ", base);
    const avail: u16 = end -| x;
    var name = row.name;
    var loc_shown = row.loc;
    const min_loc: u16 = 6;
    if (row.loc.len > 0 and ui.widthUpTo(name, avail) + 2 + ui.widthUpTo(row.loc, avail) > avail) {
        const loc_keep: u16 = @min(ui.widthUpTo(row.loc, avail), min_loc);
        name = ui.clipStr(row.name, avail -| (2 + loc_keep));
        const loc_max = avail -| (ui.widthUpTo(name, avail) + 2);
        if (ui.widthUpTo(row.loc, avail) > loc_max) {
            const ell: []const u8 = if (ui.ascii) "..." else "…";
            var start: usize = 0;
            while (start < row.loc.len and ui.width(row.loc[start..]) > loc_max -| ui.width(ell)) start += std.unicode.utf8ByteSequenceLength(row.loc[start]) catch 1;
            loc_shown = ui.fmt("{s}{s}", .{ ell, row.loc[start..] });
        }
    }
    x += ui.putStr(x, r.y, end -| x, name, Theme.onBg(t.fg, base.bg));
    if (loc_shown.len == 0) return;
    const loc_w = ui.width(loc_shown);
    const loc_x = if (end -| loc_w > x + 1) end -| loc_w else x + 2;
    _ = ui.putStr(loc_x, r.y, end -| loc_x, loc_shown, Theme.withFg(base, t.muted.fg));
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_fixture = @import("test_fixture.zig");

test "row: the kind word, the name, the location at the right edge; a long name gives way to the location; a link paints its words" {
    var f = try test_fixture.init(40, 3);
    defer f.deinit();
    paintRow(f.ui(), Rect.init(0, 0, 40, 1), .{ .kind = .command, .name = "user.hello", .loc = "init.lua:12" }, false);
    paintRow(f.ui(), Rect.init(0, 1, 40, 1), .{ .kind = .hook, .name = "a_very_long_hook_name_that_goes_on_and_on", .loc = ".mnml/init.lua:3" }, true);
    paintRow(f.ui(), Rect.init(0, 2, 40, 1), .{ .name = "+ create init.lua", .link = true }, false);
    try f.expectContains("cmd  user.hello");
    try f.expectContains("init.lua:12");
    try f.expectContains("hook a_very_long");
    try f.expectContains("…lua:3");
    try f.expectContains("+ create init.lua");
    try testing.expectEqualStrings("hook", kindWord(.hook));
}
