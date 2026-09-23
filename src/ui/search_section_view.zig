//! The SEARCH section's painters (`app/search_section.zig` owns the
//! state): the three header flags — ` Aa` ` \b` ` .*`, Rust's
//! `draw_search_section` chips, right-aligned before the refresh glyph
//! — the status row (`16 hits (git grep)`) and the list rows a
//! `ListPanel(Row)` hands here: a file header in the accent, a hit as
//! `  12:5  the line` with the match lit. Every target registers in the
//! statement that paints it (D6).
//!
//! // changed (panel-consistency): the query is `ui/filter_input.zig`'s
//! pill now — the same widget, glyph and grey band every other section
//! puts on its second row — instead of this file's own bare ` / query█`
//! run, which put a blank row where the input belonged.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const expander = @import("expander.zig");
const grep = @import("../app/grep.zig");
const grep_view = @import("grep_view.zig");
const list_panel = @import("list_panel.zig");

const Style = vaxis.Style;

pub const Caret = text_field.Caret;

/// A header flag. `label` is the chip's text, Rust's three.
pub const Flag = enum {
    case_sensitive,
    whole_word,
    regex,

    pub const all = [_]Flag{ .case_sensitive, .whole_word, .regex };

    pub fn label(f: Flag) []const u8 {
        return switch (f) {
            .case_sensitive => "Aa",
            .whole_word => "\\b",
            .regex => ".*",
        };
    }

    pub fn isOn(f: Flag, flags: grep.Flags) bool {
        return switch (f) {
            .case_sensitive => flags.case_sensitive,
            .whole_word => flags.whole_word,
            .regex => flags.regex,
        };
    }
};

/// Each chip is ` Aa`: three cells.
pub const chip_w: u16 = 3;
pub const chips_w: u16 = chip_w * Flag.all.len;

/// A file's header row: the path, how many hits it holds, whether they
/// are folded away.
pub const File = struct { rel: []const u8, count: u32, collapsed: bool };

pub const Row = union(enum) { file: File, hit: grep.Hit };

/// The flags on the header row, right-aligned before `refresh_w` cells
/// of refresh chip (one cell of air between): an active flag paints
/// bold on the accent (Rust: `fg = bg, bg = yellow, BOLD`), an inactive
/// one muted. Dropped whole when the title would lose its room, as
/// Rust drops them.
pub fn drawFlags(ui: Ui, header: Rect, flags: grep.Flags, refresh_w: u16) void {
    const t = ui.theme;
    const title_reserve: u16 = 8; // " SEARCH" + a cell of air
    const need: u16 = title_reserve + chips_w + (if (refresh_w > 0) refresh_w + 1 else 0);
    if (header.h == 0 or header.w < need) return;
    var x = header.right() - chips_w - (if (refresh_w > 0) refresh_w + 1 else 0);
    for (Flag.all) |f| {
        const on = f.isOn(flags);
        var style: Style = if (on) Theme.onBg(t.panel_bg, t.palette.yellow) else Theme.onBg(t.muted, t.panel_bg.bg);
        if (on) {
            style.fg = t.panel_bg.bg;
            style.bold = true;
        }
        const r = Rect.init(x, header.y, chip_w, 1);
        ui.fill(r, style);
        _ = ui.putStr(x + 1, header.y, chip_w - 1, f.label(), style);
        ui.hit(r, .{ .search_chip = f });
        x += chip_w;
    }
}

/// The status row: muted and dim, as Rust's.
pub fn drawStatus(ui: Ui, row: Rect, text: []const u8) void {
    const t = ui.theme;
    if (row.h == 0 or row.w == 0) return;
    var style = Theme.onBg(t.muted, t.panel_bg.bg);
    style.dim = true;
    _ = ui.putStr(row.x, row.y, row.w, ui.clipStr(text, row.w), style);
}

/// A row for `ListPanel`: a file header is its path in the accent
/// (Rust's row); folded, it leads with the closed expander and ends
/// with its count so the hidden hits are accounted for. A hit is
/// `grep_view`'s row with a two-cell mark, so the marker column and the
/// mark together give Rust's three leading cells.
pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    switch (row) {
        .file => |f| {
            var x = r.x;
            if (f.collapsed) x += ui.putStr(x, r.y, r.right() -| x, expander.slot(ui, false), expander.style(ui, .{ .bg = base.bg }));
            const line = if (f.collapsed) ui.fmt("{s} ({d})", .{ f.rel, f.count }) else f.rel;
            _ = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(line, r.right() -| x), Theme.onBg(t.accent, base.bg));
        },
        .hit => |h| grep_view.paintHitWith(ui, r, h, false, base.bg, "  "),
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "flags: three chips before the refresh glyph, the active one on the accent, each a search_chip hit; dropped on a narrow header" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    const ui = f.ui();
    drawFlags(ui, f.full(), .{ .whole_word = true }, 3);
    // 30 - 3 (refresh) - 1 (air) - 9 = 17: chips at 17, 20, 23.
    var buf: [128]u8 = undefined;
    const row = f.row(0, &buf);
    try testing.expect(std.mem.indexOf(u8, row, " Aa \\b .*") != null);
    try testing.expectEqual(Flag.case_sensitive, f.hits.at(18, 0).?.search_chip);
    try testing.expectEqual(Flag.whole_word, f.hits.at(21, 0).?.search_chip);
    try testing.expectEqual(Flag.regex, f.hits.at(25, 0).?.search_chip);
    try testing.expect(f.bgEql(21, 0, .{ .bg = f.theme.palette.yellow }));
    try testing.expect(f.bgEql(18, 0, f.theme.panel_bg));
    var g = try Fixture.init(19, 1);
    defer g.deinit();
    drawFlags(g.ui(), g.full(), .{}, 3);
    try testing.expect(g.hits.at(10, 0) == null);
}

test "rows: a file header is its path; folded it leads with the expander and ends with the count; a hit is line:col and the line" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    paintRow(f.ui(), f.full(), .{ .file = .{ .rel = "src/a.zig", .count = 3, .collapsed = false } }, false);
    try f.expectRow(0, "src/a.zig");
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    paintRow(g.ui(), g.full(), .{ .file = .{ .rel = "src/a.zig", .count = 3, .collapsed = true } }, false);
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, g.row(0, &buf), "src/a.zig (3)"));
    var h = try Fixture.init(40, 1);
    defer h.deinit();
    paintRow(h.ui(), h.full(), .{ .hit = .{ .path = "/x", .rel = "x", .line = 3, .col = 8, .ccol = 8, .len = 4, .text = "    let name = 1;" } }, false);
    try h.expectRow(0, "  3:9  let name = 1;");
}
