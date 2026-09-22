//! The chrome the REVEALED side column wears and a docked one does not:
//! a one-row header strip carrying the section's name and the pin chip,
//! and the thin edge in the border colour down its inner side that says
//! the panel is floating over the editor rather than sitting beside it.
//!
//! It is a strip of its own rather than a chip pushed into each
//! section's header for two reasons. The sections' headers are already
//! tight — the tree's drops chips one at a time below 26 columns — so a
//! pin painted into one would cover a working chip at exactly the width
//! the overlay is most likely to be. And a strip costs nothing at the
//! shipped default: `ui.sidebar = .always` never reveals anything, so
//! no docked screen gains a row and no spec dump moves.
//!
//! The painter takes rects and props; `app/sidebar_auto.zig` decides
//! whether there is an overlay at all and `app/render.zig` carves it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit = @import("hit.zig");
const pin_chip = @import("pin_chip.zig");

const Style = vaxis.Style;

pub const HitTarget = hit.HitTarget;

/// The pin chip is the family's (`ui/pin_chip.zig`) — the same glyph,
/// the same hover rule the dock and the menu bar wear.
pub const pin_glyph = pin_chip.pin_glyph;
pub const pin_ascii = pin_chip.pin_ascii;
pub const chip_w: u16 = pin_chip.width;

pub const Props = struct {
    /// The section's name, as the rail's menu spells it.
    title: []const u8,
    /// The panel is pinned (docked for the session): the chip is lit.
    pinned: bool = false,
    pin_hit: ?HitTarget = null,
};

pub const Layout = struct { pin: Rect = Rect.empty };

/// The header strip: ` TITLE ` at the left, the pin chip at the right.
pub fn drawStrip(ui: Ui, row: Rect, p: Props) Layout {
    var out: Layout = .{};
    if (row.isEmpty()) return out;
    const th = ui.theme;
    const pal = th.palette;
    const ground = Theme.onBg(th.fg, pal.bg_darker);
    ui.fill(row, ground);
    var label_style = Theme.onBg(Theme.withFg(th.fg, pal.comment), pal.bg_darker);
    label_style.bold = true;
    // The chip's cells are the label's ceiling, so a long name never
    // paints under the pin.
    const room = row.w -| (chip_w + 1);
    if (room > 1) _ = ui.putStr(row.x + 1, row.y, room -| 1, ui.clipStr(p.title, room -| 1), label_style);
    if (row.w < chip_w) return out;
    const cell = Rect.init(row.right() - chip_w, row.y, chip_w, 1);
    pin_chip.draw(ui, cell, .{ .pinned = p.pinned, .bg = pal.bg_darker, .hit = p.pin_hit });
    out.pin = cell;
    return out;
}

/// The one-column edge on the panel's inner side, in the border colour
/// — the only thing that tells the eye the column is floating.
pub fn drawEdge(ui: Ui, edge: Rect) void {
    if (edge.isEmpty()) return;
    const pal = ui.theme.palette;
    const line = Theme.withFg(Theme.onBg(ui.theme.border, pal.bg_darker), pal.line);
    ui.fill(edge, line);
    ui.vrule(edge.x, edge.y, edge.h, line);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const fixture = @import("test_fixture.zig");

test "the strip: the name at the left, the pin chip in the last three cells, lit when pinned" {
    var f = try fixture.init(30, 3);
    defer f.deinit();
    const row = Rect.init(0, 0, 30, 1);
    const l = drawStrip(f.ui(), row, .{ .title = "EXPLORER", .pin_hit = .{ .button = 99 } });
    try t.expect(l.pin.eql(Rect.init(27, 0, 3, 1)));
    try f.expectContains("EXPLORER");
    try f.expectContains(pin_glyph);
    try t.expectEqual(@as(u32, 99), f.hits.at(28, 0).?.button);
    // Muted unpinned, lit pinned — the chip is the only cell that moves.
    const dim = f.style(28, 0).fg;
    _ = drawStrip(f.ui(), row, .{ .title = "EXPLORER", .pinned = true });
    try t.expect(!vaxis.Color.eql(dim, f.style(28, 0).fg));
    // A name too long for the room left by the chip is clipped, never
    // painted under it.
    _ = drawStrip(f.ui(), row, .{ .title = "AN ABSURDLY LONG SECTION NAME" });
    try t.expectEqualStrings(" ", f.cell(26, 0).char.grapheme);
}

test "the edge paints the border rule down the panel's inner side" {
    var f = try fixture.init(10, 4);
    defer f.deinit();
    drawEdge(f.ui(), Rect.init(9, 0, 1, 4));
    var y: u16 = 0;
    while (y < 4) : (y += 1) try t.expectEqualStrings("│", f.cell(9, y).char.grapheme);
}
