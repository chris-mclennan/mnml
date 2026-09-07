//! The right column's strip row — the Rust right panel's tab strip,
//! cell for cell: the section's chip ` title ` (bold, the active tab's
//! ground), a one-cell gap, the green ` 󰐕 ` that adds a panel, the
//! active ground bridged from the chip to the `×` so the close reads
//! as the chip's, the `×` one cell in from the right edge, and the
//! last cell left on the column's ground. A chip that does not fit is
//! clipped with `…` (Rust's rule: at least ` X… `).
//!
//! Every part registers its hit in the statement that paints it: the
//! chip, the plus, the close — each a `.button` the caller names.
//!
//! // changed (section-side): one chip — the column shows one section
//! at a time, so there is nothing to walk; the chip's hit focuses the
//! column where Rust's selects the tab.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit = @import("hit.zig");
const bufferline = @import("bufferline.zig");

const Style = vaxis.Style;

pub const HitTarget = hit.HitTarget;

/// Cells kept for the `×` and the edge cell after it.
pub const reserve_close: u16 = 2;
pub const plus_w: u16 = 3;

pub const Props = struct {
    title: []const u8,
    /// The chip is the active tab (always, with one section shown).
    active: bool = true,
    chip_hit: ?HitTarget = null,
    plus_hit: ?HitTarget = null,
    close_hit: ?HitTarget = null,
};

pub const Layout = struct { chip: Rect = Rect.empty, plus: Rect = Rect.empty, close: Rect = Rect.empty };

pub fn draw(ui: Ui, row: Rect, p: Props) Layout {
    const t = ui.theme;
    const pal = t.palette;
    var out: Layout = .{};
    const ground = Theme.onBg(t.fg, pal.bg_darker);
    ui.fill(row, ground);
    if (row.h == 0 or row.w < 4) return out;
    const strip_end = row.right() - reserve_close;
    const close_x = strip_end;
    const active_bg = if (p.active) pal.bg2 else pal.bg_dark;
    var chip_style = Theme.onBg(if (p.active) t.fg else Theme.withFg(t.fg, pal.comment), active_bg);
    chip_style.bold = true;

    // The chip, clipped to the strip: ` label `, or ` lab… `.
    var x = row.x;
    var label = p.title;
    const room = strip_end -| x;
    if (ui.width(label) + 2 > room) {
        const avail = room -| 3;
        if (avail < 2) return closeOnly(ui, row, p, out);
        label = ui.clipStr(label, avail);
    }
    const chip = ui.fmt(" {s} ", .{label});
    const chip_w = ui.width(chip);
    _ = ui.putStr(x, row.y, chip_w, chip, chip_style);
    out.chip = Rect.init(x, row.y, chip_w, 1);
    if (p.chip_hit) |h| ui.hit(out.chip, h);
    x += chip_w;
    const chip_end = x;
    if (x < strip_end) x += 1;

    // The active ground bridges the chip to the `×`.
    if (p.active and chip_end < close_x) ui.fill(Rect.init(chip_end, row.y, close_x - chip_end, 1), Theme.onBg(t.fg, pal.bg2));

    // The ` 󰐕 ` when it fits before the `×`.
    if (x + plus_w <= close_x) {
        var plus_style = Theme.onBg(Theme.withFg(t.fg, pal.green), pal.bg_dark);
        plus_style.bold = true;
        const glyph = ui.fmt(" {s} ", .{if (ui.ascii) bufferline.plus_ascii else bufferline.plus_glyph});
        _ = ui.putStr(x, row.y, plus_w, glyph, plus_style);
        out.plus = Rect.init(x, row.y, plus_w, 1);
        if (p.plus_hit) |h| ui.hit(out.plus, h);
    }
    return closeOnly(ui, row, p, out);
}

/// The `×`: on the active ground when the chip is bridged to it, else
/// dim on the inactive ground so it reads as the column's.
fn closeOnly(ui: Ui, row: Rect, p: Props, in: Layout) Layout {
    var out = in;
    const t = ui.theme;
    const pal = t.palette;
    if (row.w <= reserve_close) return out;
    const close_x = row.right() - reserve_close;
    const style = if (p.active) Theme.onBg(t.fg, pal.bg2) else Theme.onBg(Theme.withFg(t.fg, pal.comment), pal.bg_dark);
    _ = ui.putStr(close_x, row.y, 1, if (ui.ascii) "x" else "\u{D7}", style);
    out.close = Rect.init(close_x, row.y, 1, 1);
    if (p.close_hit) |h| ui.hit(out.close, h);
    return out;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the chip, the plus, the bridge and the close at Rust's cells (32 wide)" {
    var f = try Fixture.init(32, 1);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), .{ .title = "main.rs ⌥1", .chip_hit = .{ .button = 1 }, .plus_hit = .{ .button = 2 }, .close_hit = .{ .button = 3 } });
    try f.expectRow(0, " main.rs ⌥1   \u{F0415}               ×");
    try testing.expect(l.chip.eql(Rect.init(0, 0, 12, 1)));
    try testing.expect(l.plus.eql(Rect.init(13, 0, 3, 1)));
    try testing.expect(l.close.eql(Rect.init(30, 0, 1, 1)));
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 0).?.button);
    try testing.expectEqual(@as(u32, 2), f.hits.at(14, 0).?.button);
    try testing.expectEqual(@as(u32, 3), f.hits.at(30, 0).?.button);
    try testing.expect(f.hits.at(31, 0) == null);
    // The chip and the gap after it are on the active ground, the plus
    // on the inactive, the bridge active again, the edge cell the
    // column's.
    try testing.expect(vaxis.Color.eql(f.style(1, 0).bg, f.theme.palette.bg2));
    try testing.expect(f.style(1, 0).bold);
    try testing.expect(vaxis.Color.eql(f.style(12, 0).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(14, 0).bg, f.theme.palette.bg_dark));
    try testing.expect(vaxis.Color.eql(f.style(14, 0).fg, f.theme.palette.green));
    try testing.expect(vaxis.Color.eql(f.style(20, 0).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(30, 0).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(31, 0).bg, f.theme.palette.bg_darker));
}

test "a long title clips with an ellipsis, the plus drops when it has no room, and a tight row keeps only the close" {
    var f = try Fixture.init(14, 1);
    defer f.deinit();
    var l = draw(f.ui(), f.full(), .{ .title = "very-long-name.rs ⌥12" });
    try f.expectRow(0, " very-lon…  ×");
    try testing.expect(l.plus.isEmpty());
    try testing.expect(l.close.eql(Rect.init(12, 0, 1, 1)));
    // Room for the chip and the plus, just.
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    l = draw(g.ui(), g.full(), .{ .title = "ab" });
    try g.expectRow(0, " ab   \u{F0415}   ×");
    try testing.expect(l.plus.eql(Rect.init(5, 0, 3, 1)));
    // Four cells: nothing but the ground and the close.
    var h = try Fixture.init(4, 1);
    defer h.deinit();
    l = draw(h.ui(), h.full(), .{ .title = "abc", .close_hit = .{ .button = 3 } });
    try h.expectRow(0, "  ×");
    try testing.expect(l.chip.isEmpty());
    try testing.expectEqual(@as(u32, 3), h.hits.at(2, 0).?.button);
    for (h.hits.items.items) |e| try testing.expect(h.full().intersect(e.rect).eql(e.rect));
}
