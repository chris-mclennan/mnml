//! The pin chip — 󰐃 in three cells — and the one rule every surface
//! that can hide itself wears it by.
//!
//! Three surfaces auto-hide and slide back in when the pointer asks:
//! the side columns (`app/sidebar_auto.zig`), the launcher dock
//! (`app/launcher_dock.zig`) and the menu bar (`app/menu_bar.zig`).
//! Each ends the game the same way — a pin that docks it for the
//! session — so the chip that says so is one piece of code rather than
//! three that drift. It was three: the glyph and its `--ascii` twin
//! were declared twice and painted twice, with two different hover
//! rules, before this module took them.
//!
//! The rule is the family's (`app/hover_zones.zig`): unpinned and cold
//! the glyph is `dim` in the comment colour, so it reads as an
//! affordance and not as state; under the pointer it sheds the `dim`,
//! takes the theme's full foreground and its whole cell run fills one
//! step lighter; pinned it is the theme's yellow and bold, which is
//! its own colour and so survives the hover.
//!
//! The chip paints its own ground, so a caller hands it the surface's
//! background and nothing else — and registers its hit in the
//! statement that paints it (D6).

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit_mod = @import("hit.zig");

const Style = vaxis.Style;

pub const HitTarget = hit_mod.HitTarget;

/// nf-md-pin, and the one character `--ascii` paints in its place.
pub const pin_glyph = "\u{F0403}"; // 󰐃
pub const pin_ascii = "P";
/// ` <glyph> `, like every other chrome chip.
pub const width: u16 = 3;

pub const Props = struct {
    /// The surface is pinned: the chip is lit.
    pinned: bool = false,
    /// The surface's own ground — the chip fills its cells with it so
    /// it can be dropped onto any row.
    bg: vaxis.Color,
    /// Registered over the whole chip; null paints a chip nothing can
    /// click, which is only ever a test's business.
    hit: ?HitTarget = null,
};

/// Paint the chip into `cell` (`width` cells; a narrower rect is
/// refused rather than half-painted).
pub fn draw(ui: Ui, cell: Rect, p: Props) void {
    if (cell.isEmpty() or cell.w < width) return;
    const th = ui.theme;
    const pal = th.palette;
    const hot = ui.hovered(cell);
    const ground = if (hot) pal.bg2 else p.bg;
    ui.fill(cell, Theme.onBg(th.fg, ground));
    var style = Theme.onBg(th.fg, ground);
    if (p.pinned) {
        style = Theme.withFg(style, pal.yellow);
        style.bold = true;
    } else if (hot) {
        style.bold = true;
    } else {
        style = Theme.withFg(style, pal.comment);
        style.dim = true;
    }
    _ = ui.putStr(cell.x + 1, cell.y, cell.w -| 1, if (ui.ascii) pin_ascii else pin_glyph, style);
    if (p.hit) |h| ui.hit(cell, h);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Fixture = @import("test_fixture.zig");

test "the chip: the glyph in the middle cell, a hit over all three, dim cold and lit pinned" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    const cell = Rect.init(4, 0, width, 1);
    draw(f.ui(), cell, .{ .bg = f.theme.palette.bg_dark, .hit = .{ .button = 77 } });
    try f.expectContains(pin_glyph);
    try t.expectEqualStrings(pin_glyph, f.cell(5, 0).char.grapheme);
    try t.expectEqual(@as(u32, 77), f.hits.at(4, 0).?.button);
    try t.expectEqual(@as(u32, 77), f.hits.at(6, 0).?.button);
    try t.expect(f.hits.at(3, 0) == null);
    const cold = f.style(5, 0);
    try t.expect(cold.dim and !cold.bold);
    // Pinned: the yellow, bold, and no longer dim — the one cell that moves.
    draw(f.ui(), cell, .{ .bg = f.theme.palette.bg_dark, .pinned = true });
    const lit = f.style(5, 0);
    try t.expect(lit.bold and !lit.dim);
    try t.expect(!vaxis.Color.eql(cold.fg, lit.fg));
    try t.expect(vaxis.Color.eql(lit.fg, f.theme.palette.yellow));
}

test "hover brightens one step and sheds the dim; a rect narrower than the chip paints nothing" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    const cell = Rect.init(4, 0, width, 1);
    f.hover = .{ .x = 5, .y = 0 };
    draw(f.ui(), cell, .{ .bg = f.theme.palette.bg_dark });
    const hot = f.style(5, 0);
    try t.expect(hot.bold and !hot.dim);
    try t.expect(f.bgEql(4, 0, .{ .bg = f.theme.palette.bg2 }));
    // Too narrow for ` 󰐃 `: nothing at all, rather than a clipped chip.
    var g = try Fixture.init(10, 1);
    defer g.deinit();
    draw(g.ui(), Rect.init(4, 0, 2, 1), .{ .bg = g.theme.palette.bg_dark, .hit = .{ .button = 1 } });
    try g.expectLacks(pin_glyph);
    try t.expect(g.hits.at(4, 0) == null);
}

test "the --ascii twin replaces the glyph" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    f.ascii = true;
    draw(f.ui(), Rect.init(4, 0, width, 1), .{ .bg = f.theme.palette.bg_dark });
    try f.expectContains(pin_ascii);
    try f.expectLacks(pin_glyph);
}
