//! The edge grip — `⋯` at the middle of a hidden surface's edge, and
//! the one rule every slide-in wears it by.
//!
//! Three surfaces auto-hide and come back when the pointer rests on
//! their edge: the side columns (`app/sidebar_auto.zig`), the launcher
//! dock (`app/launcher_dock.zig`) and the menu bar (`app/menu_bar.zig`).
//! Until this module the edge that summons them was invisible — a band
//! of cells that looked like editor and behaved like chrome, which you
//! could only find by having been told about it. ghostty marks its own
//! sliding titlebar with three dots at the top centre; this is that,
//! for all three.
//!
//! **The grip names the zone's own cell.** It is painted at the middle
//! of the very band `hover_zones` watches, so there is no second
//! geometry to keep in step: dwelling on the grip reveals the surface
//! because the grip is *inside* the zone, not because anything here
//! says so. The grip is the band's NAME, never a new way in.
//!
//! **Three dots, one cell or three.** `⋯` (U+22EF) and `⋮` (U+22EE)
//! already draw three dots in a single cell, so the glyph takes the
//! middle cell of a three-cell run and the two either side are ground
//! — the pin chip's ` 󰐃 ` shape, so the two chips read as one family.
//! `--ascii` has no such glyph and spends one `.` per cell instead.
//!
//! **The colour is the family's** (`ui/pin_chip.zig`, `app/hover_zones.zig`):
//! dim, in the comment colour, so it reads as an affordance and not as
//! state; under the pointer it sheds the `dim`, takes the theme's full
//! foreground and its whole cell run fills one step lighter.
//!
//! A click on it reveals AND pins — the same pin the chip at the other
//! end of the revealed surface toggles — so the grip and the chip are
//! the two ends of one gesture: the grip brings the surface out and
//! keeps it, the chip lets it go. Which is why a pinned surface shows
//! no grip: there is nothing left to summon.
//!
//! `ui.edge_grips = false` turns all three off together, for people who
//! would rather have the invisible bands back.
//!
//! The grip paints its own ground and registers its hit in the
//! statement that paints it (D6).

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit_mod = @import("hit.zig");

pub const HitTarget = hit_mod.HitTarget;

/// U+22EF MIDLINE HORIZONTAL ELLIPSIS — the grip on a top or bottom row.
pub const grip_h = "\u{22EF}"; // ⋯
/// U+22EE VERTICAL ELLIPSIS — the grip on a left or right column.
pub const grip_v = "\u{22EE}"; // ⋮
/// What `--ascii` paints in each of the three cells instead.
pub const grip_ascii = ".";

/// The run is three cells long whichever way it lies — the pin chip's
/// width, so a grip and a chip on the same row measure the same.
pub const len: u16 = 3;

/// Which edge of the frame the grip marks. It settles both where the
/// run is centred and which of the two glyphs it wears.
pub const Edge = enum {
    top,
    bottom,
    left,
    right,

    /// Whether the run lies along a row (three columns) or down a
    /// column (three rows).
    pub fn horizontal(e: Edge) bool {
        return e == .top or e == .bottom;
    }
};

pub const Props = struct {
    /// The surface's own ground — the grip fills its cells with it so
    /// it can be dropped onto any row.
    bg: vaxis.Color,
    /// Registered over the whole run; null paints a grip nothing can
    /// click, which is only ever a test's business.
    hit: ?HitTarget = null,
};

/// Where the grip goes in `band` — three cells at its middle — or null
/// when the band is too short to hold one. `band` is the zone's own
/// rect: the bar's row, the screen's last row, a side dock's own
/// reserved columns, a side column's one-cell screen edge.
///
/// // changed (side-band): the run is centred on BOTH axes of the band
/// rather than only along it. A one-cell-thick band is unmoved — the
/// middle of one cell is that cell — so the bar's row and a side
/// column's edge place exactly where they always did; a side dock's
/// band is three columns wide and the glyph now lands in its MIDDLE
/// column, the very one its items paint their glyphs in (` glyph `),
/// so the handle stands where the things it summons stand.
pub fn place(band: Rect, edge: Edge) ?Rect {
    if (band.isEmpty()) return null;
    if (edge.horizontal()) {
        if (band.w < len) return null;
        return Rect.init(band.x + (band.w - len) / 2, band.y + (band.h - 1) / 2, len, 1);
    }
    if (band.h < len) return null;
    return Rect.init(band.x + (band.w - 1) / 2, band.y + (band.h - len) / 2, 1, len);
}

/// Paint the grip into `cell` (a `place` rect; any other size is
/// refused rather than half-painted).
pub fn draw(ui: Ui, cell: Rect, edge: Edge, p: Props) void {
    const want_w: u16 = if (edge.horizontal()) len else 1;
    const want_h: u16 = if (edge.horizontal()) 1 else len;
    if (cell.w != want_w or cell.h != want_h) return;
    const th = ui.theme;
    const pal = th.palette;
    const hot = ui.hovered(cell);
    const ground = if (hot) pal.bg2 else p.bg;
    var style = Theme.onBg(th.fg, ground);
    ui.fill(cell, style);
    if (hot) {
        style.bold = true;
    } else {
        style = Theme.withFg(style, pal.comment);
        style.dim = true;
    }
    if (ui.ascii) {
        // No ellipsis glyph to lean on: one dot per cell says the same
        // thing across the whole run.
        var i: u16 = 0;
        while (i < len) : (i += 1) {
            const x = if (edge.horizontal()) cell.x + i else cell.x;
            const y = if (edge.horizontal()) cell.y else cell.y + i;
            _ = ui.putStr(x, y, 1, grip_ascii, style);
        }
    } else {
        const mid = if (edge.horizontal()) len / 2 else 0;
        const x = cell.x + mid;
        const y = if (edge.horizontal()) cell.y else cell.y + len / 2;
        _ = ui.putStr(x, y, 1, if (edge.horizontal()) grip_h else grip_v, style);
    }
    if (p.hit) |h| ui.hit(cell, h);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Fixture = @import("test_fixture.zig");

test "place: three cells at the middle of the band, and nothing at all when the band cannot hold them" {
    // A 120-wide row: the run is 58..60, the glyph on 59.
    const row = Rect.init(0, 0, 120, 1);
    const top = place(row, .top).?;
    try t.expectEqual(Rect.init(58, 0, 3, 1), top);
    // The bottom edge is the same sum on whatever row it is given.
    try t.expectEqual(Rect.init(58, 39, 3, 1), place(Rect.init(0, 39, 120, 1), .bottom).?);
    // An odd width rounds down, so the run never runs past the band.
    const odd = place(Rect.init(0, 0, 7, 1), .top).?;
    try t.expectEqual(Rect.init(2, 0, 3, 1), odd);
    try t.expect(odd.right() <= 7);
    // A column: three ROWS at the middle of it, one cell wide.
    const col = Rect.init(0, 1, 1, 38);
    const left = place(col, .left).?;
    try t.expectEqual(Rect.init(0, 18, 1, 3), left);
    try t.expectEqual(Rect.init(119, 18, 1, 3), place(Rect.init(119, 1, 1, 38), .right).?);
    // Too small: no grip rather than a clipped one.
    try t.expect(place(Rect.init(0, 0, 2, 1), .top) == null);
    try t.expect(place(Rect.init(0, 0, 1, 2), .left) == null);
    try t.expect(place(Rect.empty, .top) == null);
    // Exactly three is enough, either way.
    try t.expectEqual(Rect.init(0, 0, 3, 1), place(Rect.init(0, 0, 3, 1), .top).?);
    try t.expectEqual(Rect.init(0, 0, 1, 3), place(Rect.init(0, 0, 1, 3), .left).?);
}

test "the horizontal grip: the glyph in the middle cell, a hit over all three, dim and in the comment colour cold" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    const cell = place(Rect.init(0, 0, 10, 1), .top).?;
    try t.expectEqual(Rect.init(3, 0, 3, 1), cell);
    draw(f.ui(), cell, .top, .{ .bg = f.theme.bg.bg, .hit = .{ .button = 91 } });
    try f.expectContains(grip_h);
    try t.expectEqualStrings(grip_h, f.cell(4, 0).char.grapheme);
    // The cells either side are ground, not glyph — the pin chip's shape.
    try t.expectEqualStrings(" ", f.cell(3, 0).char.grapheme);
    try t.expectEqualStrings(" ", f.cell(5, 0).char.grapheme);
    // The hit runs over the whole three, and stops there.
    try t.expectEqual(@as(u32, 91), f.hits.at(3, 0).?.button);
    try t.expectEqual(@as(u32, 91), f.hits.at(5, 0).?.button);
    try t.expect(f.hits.at(2, 0) == null);
    try t.expect(f.hits.at(6, 0) == null);
    const cold = f.style(4, 0);
    try t.expect(cold.dim and !cold.bold);
    try t.expect(vaxis.Color.eql(cold.fg, f.theme.palette.comment));
}

test "the vertical grip: the glyph in the middle ROW of a one-cell column, the hit down all three" {
    var f = try Fixture.init(4, 9);
    defer f.deinit();
    const cell = place(Rect.init(0, 0, 1, 9), .left).?;
    try t.expectEqual(Rect.init(0, 3, 1, 3), cell);
    draw(f.ui(), cell, .left, .{ .bg = f.theme.bg.bg, .hit = .{ .button = 92 } });
    try t.expectEqualStrings(grip_v, f.cell(0, 4).char.grapheme);
    try t.expectEqualStrings(" ", f.cell(0, 3).char.grapheme);
    try t.expectEqualStrings(" ", f.cell(0, 5).char.grapheme);
    try t.expectEqual(@as(u32, 92), f.hits.at(0, 3).?.button);
    try t.expectEqual(@as(u32, 92), f.hits.at(0, 5).?.button);
    try t.expect(f.hits.at(0, 2) == null);
    try t.expect(f.hits.at(0, 6) == null);
    // The horizontal glyph is never the one a column wears.
    try f.expectLacks(grip_h);
}

test "hover brightens one step and sheds the dim, the rail's rule" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    const cell = place(Rect.init(0, 0, 10, 1), .bottom).?;
    f.hover = .{ .x = 3, .y = 0 };
    draw(f.ui(), cell, .bottom, .{ .bg = f.theme.bg.bg });
    const hot = f.style(4, 0);
    try t.expect(hot.bold and !hot.dim);
    // The whole run fills one step lighter, not just the glyph's cell.
    try t.expect(f.bgEql(3, 0, .{ .bg = f.theme.palette.bg2 }));
    try t.expect(f.bgEql(5, 0, .{ .bg = f.theme.palette.bg2 }));
}

test "the --ascii twin spends one dot per cell, since there is no ellipsis glyph to lean on" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    f.ascii = true;
    draw(f.ui(), place(Rect.init(0, 0, 10, 1), .top).?, .top, .{ .bg = f.theme.bg.bg });
    try f.expectContains("...");
    try f.expectLacks(grip_h);

    var g = try Fixture.init(4, 9);
    defer g.deinit();
    g.ascii = true;
    draw(g.ui(), place(Rect.init(0, 0, 1, 9), .left).?, .left, .{ .bg = g.theme.bg.bg });
    try t.expectEqualStrings(grip_ascii, g.cell(0, 3).char.grapheme);
    try t.expectEqualStrings(grip_ascii, g.cell(0, 4).char.grapheme);
    try t.expectEqualStrings(grip_ascii, g.cell(0, 5).char.grapheme);
    try g.expectLacks(grip_v);
}

test "a rect that is not a place rect paints nothing rather than a clipped grip" {
    var f = try Fixture.init(10, 3);
    defer f.deinit();
    // Two cells where three were promised.
    draw(f.ui(), Rect.init(0, 0, 2, 1), .top, .{ .bg = f.theme.bg.bg, .hit = .{ .button = 1 } });
    // The vertical run handed to the horizontal edge, and the reverse.
    draw(f.ui(), Rect.init(0, 0, 1, 3), .top, .{ .bg = f.theme.bg.bg, .hit = .{ .button = 1 } });
    draw(f.ui(), Rect.init(0, 0, 3, 1), .left, .{ .bg = f.theme.bg.bg, .hit = .{ .button = 1 } });
    try f.expectLacks(grip_h);
    try f.expectLacks(grip_v);
    try t.expectEqual(@as(usize, 0), f.hits.items.items.len);
}
