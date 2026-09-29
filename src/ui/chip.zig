//! Chips — the small pills in a panel header: the ` key: value ` mode
//! chip (`sort: Newest first`) and the icon-only
//! refresh chip. One place for their text, style and paint so every
//! panel's header reads as one family, and so a chip can never be
//! painted without its hit — `paint` registers the target in the same
//! statement as the cells.
//!
//! The mode chip pads its value to the WIDEST value it can ever hold.
//! It is right-anchored, so a shorter label would move its left edge
//! out from under a pointer that is repeat-clicking — the Rust mnml
//! shipped that bug ("the button works sometimes") and this is the fix
//! carried forward. The narrow rung of the ladder (`header.zig` decides
//! which rung fits) is an icon alone: ` ~ ` under `--ascii`, the
//! nf-fa-sort glyph otherwise.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit = @import("hit.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const ChipKind = hit.ChipKind;
pub const PanelId = hit.PanelId;

/// nf-fa-sort.
pub const sort_icon_nerd = "\u{f0dc}";
pub const sort_icon_ascii = "~";
/// nf-cod-refresh.
pub const refresh_icon_nerd = "\u{eb37}";
pub const refresh_icon_ascii = "\u{21ba}";

/// ` key: value<pad> ` — `widest` in code points, the widest value the
/// chip will ever show.
pub fn modeText(arena: Allocator, key: []const u8, value: []const u8, widest: usize) Allocator.Error![]u8 {
    const n = std.unicode.utf8CountCodepoints(value) catch value.len;
    const pad = widest -| n;
    const out = try arena.alloc(u8, 1 + key.len + 2 + value.len + pad + 1);
    var i: usize = 0;
    out[i] = ' ';
    i += 1;
    @memcpy(out[i .. i + key.len], key);
    i += key.len;
    out[i] = ':';
    out[i + 1] = ' ';
    i += 2;
    @memcpy(out[i .. i + value.len], value);
    i += value.len;
    @memset(out[i .. i + pad], ' ');
    i += pad;
    out[i] = ' ';
    return out;
}

/// The narrow rung of the ladder: an icon, no key, no value.
pub fn modeIcon(ascii: bool) []const u8 {
    return if (ascii) " " ++ sort_icon_ascii ++ " " else " " ++ sort_icon_nerd ++ " ";
}

pub fn refreshIcon(ascii: bool) []const u8 {
    return if (ascii) " " ++ refresh_icon_ascii ++ " " else " " ++ refresh_icon_nerd ++ " ";
}

/// Dark text on the accent — the chip is a button.
pub fn modeStyle(t: *const Theme) Style {
    return t.chip_active;
}

/// The refresh glyph sits on the panel ground in the accent color.
pub fn refreshStyle(t: *const Theme, bg: vaxis.Color) Style {
    return .{ .fg = t.chip_active.bg, .bg = bg };
}

/// A count on a card — ` 3 files ` on a SESSIONS card (sessiondiff):
/// yellow ink (the status pane's "modified") on the card's own ground,
/// no fill and no bold, so it reads as a thing to click without
/// shouting over the name beside it.
pub fn countStyle(t: *const Theme, bg: vaxis.Color) Style {
    return .{ .fg = t.palette.yellow, .bg = bg };
}

/// The ` + ` chip: green on the panel ground.
pub fn newStyle(t: *const Theme, bg: vaxis.Color) Style {
    return .{ .fg = t.palette.green, .bg = bg, .bold = true };
}

/// The ` + New … ` action row: dark bold text on the green fill —
/// Rust's `action_button::primary`.
pub fn newRowStyle(t: *const Theme) Style {
    return .{ .fg = t.chip_active.fg, .bg = t.palette.green, .bold = true };
}

/// Paints `text` at `(x, y)` in `style` and registers the chip target
/// for exactly the cells it took. Returns the painted rect (empty when
/// nothing fit) so a caller can lay out the next chip beside it.
pub fn paint(ui: Ui, x: u16, y: u16, max_w: u16, text: []const u8, style: Style, panel: PanelId, kind: ChipKind) Rect {
    return paintTarget(ui, x, y, max_w, text, style, .{ .chip = .{ .panel = panel, .kind = kind } });
}

/// `paint` with the target spelled out — a pane-hosted panel's chip is
/// its `.script_hit` (`hit.chipTarget`).
pub fn paintTarget(ui: Ui, x: u16, y: u16, max_w: u16, text: []const u8, style: Style, target: hit.HitTarget) Rect {
    const w = ui.putStr(x, y, max_w, text, style);
    const r = Rect.init(x, y, w, 1);
    ui.hit(r, target);
    return r;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "mode text pads to the widest value so the chip never resizes" {
    const a = try modeText(testing.allocator, "sort", "Newest first", 12);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(" sort: Newest first ", a);
    const b = try modeText(testing.allocator, "sort", "Name (A–Z)", 12);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(" sort: Name (A–Z)   ", b);
    try testing.expectEqual(try std.unicode.utf8CountCodepoints(a), try std.unicode.utf8CountCodepoints(b));
    // A value wider than `widest` is not cut.
    const c = try modeText(testing.allocator, "view", "Everything", 3);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings(" view: Everything ", c);
}

test "icons have an ascii form" {
    try testing.expectEqualStrings(" ~ ", modeIcon(true));
    try testing.expectEqualStrings(" \u{f0dc} ", modeIcon(false));
    try testing.expectEqualStrings(" \u{21ba} ", refreshIcon(true));
}

test "paint puts the cells and the hit in one stroke" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    const ui = f.ui();
    const text = try modeText(ui.arena, "sort", "Newest first", 12);
    const r = paint(ui, 4, 0, 30, text, modeStyle(&f.theme), .todos, .sort);
    try testing.expect(r.eql(Rect.init(4, 0, 20, 1)));
    try f.expectRow(0, "     sort: Newest first");
    try testing.expect(f.bgEql(5, 0, f.theme.chip_active));
    try testing.expectEqual(ChipKind.sort, f.hits.at(4, 0).?.chip.kind);
    try testing.expectEqual(PanelId.todos, f.hits.at(23, 0).?.chip.panel);
    try testing.expect(f.hits.at(3, 0) == null);
    try testing.expect(f.hits.at(24, 0) == null);

    const rr = paint(ui, 26, 0, 30 - 26, refreshIcon(false), refreshStyle(&f.theme, f.theme.panel_bg.bg), .notes, .refresh);
    try testing.expect(rr.eql(Rect.init(26, 0, 3, 1)));
    try testing.expectEqual(ChipKind.refresh, f.hits.at(27, 0).?.chip.kind);
    try testing.expect(vaxis.Color.eql(f.style(27, 0).fg, f.theme.chip_active.bg));
}

test "a chip that does not fit paints what fits and registers only that" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    const ui = f.ui();
    const r = paint(ui, 6, 0, 4, " sort: Newest ", modeStyle(&f.theme), .todos, .sort);
    try testing.expect(r.eql(Rect.init(6, 0, 4, 1)));
    try f.expectRow(0, "       sor");
    try testing.expect(f.hits.at(9, 0) != null);
    const none = paint(ui, 10, 0, 0, " x ", modeStyle(&f.theme), .todos, .sort);
    try testing.expect(none.isEmpty());
    try testing.expectEqual(@as(usize, 1), f.hits.items.items.len);
}
