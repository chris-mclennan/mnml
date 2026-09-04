//! Scrollbars — the one-cell vertical strip on the right of a list, and
//! the one-row horizontal strip under wide content. Track and thumb are
//! the same glyph in two colors, so the column reads as a recessed
//! strip with a brighter thumb rather than a thin line running through
//! a block (the Rust mnml mixed `│` and `█` and users saw the seam).
//!
//! `thumb` is the geometry alone, so a drag router and a test can ask
//! where the thumb is without painting. Every painted bar registers a
//! `.scrollbar{owner, axis}` hit over its whole track in the same
//! statement — clicking the track is how the app pages.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit = @import("hit.zig");

const Style = vaxis.Style;

pub const Owner = hit.Owner;
pub const Axis = hit.Axis;

pub const Thumb = struct { start: u16, len: u16 };

/// Thumb placement along `cells` for `total` rows of which `viewport`
/// are visible from `scroll`. Null when everything fits.
pub fn thumb(cells: u16, total: usize, viewport: usize, scroll: usize) ?Thumb {
    if (cells == 0 or viewport == 0 or total <= viewport) return null;
    const len: u16 = @intCast(@max(1, (@as(usize, cells) * viewport) / total));
    const max_scroll = total - viewport;
    const max_start = cells - len;
    const start: u16 = @intCast((@min(scroll, max_scroll) * max_start) / max_scroll);
    return .{ .start = start, .len = len };
}

pub fn trackStyle(t: *const Theme) Style {
    return .{ .fg = t.chip.bg, .bg = t.chip.bg };
}

pub fn thumbStyle(t: *const Theme) Style {
    return .{ .fg = t.muted.fg, .bg = t.chip.bg };
}

fn glyph(ui: Ui, axis: Axis, is_thumb: bool) []const u8 {
    if (!ui.ascii) return switch (axis) {
        .v => "█",
        .h => if (is_thumb) "━" else "─",
    };
    return switch (axis) {
        .v => if (is_thumb) "#" else "|",
        .h => if (is_thumb) "=" else "-",
    };
}

/// Paints a vertical bar down `area` (any width; one cell is the norm)
/// and registers the hit. No-op when `area` is empty.
pub fn drawVertical(ui: Ui, area: Rect, owner: Owner, total: usize, viewport: usize, scroll: usize) void {
    if (area.isEmpty()) return;
    const t = ui.theme;
    const th = thumb(area.h, total, viewport, scroll);
    var y: u16 = 0;
    while (y < area.h) : (y += 1) {
        const in_thumb = if (th) |tt| y >= tt.start and y < tt.start + tt.len else false;
        const style = if (in_thumb) thumbStyle(t) else trackStyle(t);
        var x: u16 = 0;
        while (x < area.w) : (x += 1) {
            ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = glyph(ui, .v, in_thumb), .width = 1 }, .style = style });
        }
    }
    ui.hit(area, .{ .scrollbar = .{ .owner = owner, .axis = .v } });
}

/// Paints a horizontal bar along `area` (one row is the norm).
pub fn drawHorizontal(ui: Ui, area: Rect, owner: Owner, total: usize, viewport: usize, scroll: usize) void {
    if (area.isEmpty()) return;
    const t = ui.theme;
    const th = thumb(area.w, total, viewport, scroll);
    var x: u16 = 0;
    while (x < area.w) : (x += 1) {
        const in_thumb = if (th) |tt| x >= tt.start and x < tt.start + tt.len else false;
        const style = if (in_thumb) thumbStyle(t) else trackStyle(t);
        var y: u16 = 0;
        while (y < area.h) : (y += 1) {
            ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = glyph(ui, .h, in_thumb), .width = 1 }, .style = style });
        }
    }
    ui.hit(area, .{ .scrollbar = .{ .owner = owner, .axis = .h } });
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "thumb geometry: proportional length, at least one cell, ends flush" {
    try testing.expect(thumb(10, 5, 10, 0) == null);
    try testing.expect(thumb(10, 10, 10, 0) == null);
    try testing.expect(thumb(0, 100, 10, 0) == null);
    try testing.expectEqual(Thumb{ .start = 0, .len = 5 }, thumb(10, 20, 10, 0).?);
    try testing.expectEqual(Thumb{ .start = 5, .len = 5 }, thumb(10, 20, 10, 10).?);
    try testing.expectEqual(Thumb{ .start = 2, .len = 5 }, thumb(10, 20, 10, 5).?);
    // 1000 rows in 10 cells: one-cell thumb that still reaches the end.
    try testing.expectEqual(Thumb{ .start = 0, .len = 1 }, thumb(10, 1000, 10, 0).?);
    try testing.expectEqual(Thumb{ .start = 9, .len = 1 }, thumb(10, 1000, 10, 990).?);
    // A scroll past the end clamps.
    try testing.expectEqual(Thumb{ .start = 9, .len = 1 }, thumb(10, 1000, 10, 5000).?);
}

test "vertical bar paints track and thumb and registers one hit over the track" {
    var f = try Fixture.init(4, 6);
    defer f.deinit();
    const ui = f.ui();
    const bar = Rect.init(3, 0, 1, 6);
    drawVertical(ui, bar, .{ .panel = .todos }, 12, 6, 6);
    // Thumb: 3 cells, at the bottom.
    var y: u16 = 0;
    while (y < 6) : (y += 1) {
        try testing.expectEqualStrings("█", f.cell(3, y).char.grapheme);
        const is_thumb = y >= 3;
        try testing.expect(vaxis.Color.eql(f.style(3, y).fg, if (is_thumb) f.theme.muted.fg else f.theme.chip.bg));
    }
    const h = f.hits.at(3, 2).?.scrollbar;
    try testing.expectEqual(Axis.v, h.axis);
    try testing.expectEqual(hit.PanelId.todos, h.owner.panel);
    try testing.expect(f.hits.at(2, 2) == null);
    // Everything fits: track only, still clickable.
    drawVertical(ui, bar, .{ .pane = 1 }, 3, 6, 0);
    y = 0;
    while (y < 6) : (y += 1) try testing.expect(vaxis.Color.eql(f.style(3, y).fg, f.theme.chip.bg));
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 5).?.scrollbar.owner.pane);
    drawVertical(ui, Rect.empty, .{ .pane = 1 }, 3, 6, 0);
}

test "horizontal bar and the ascii glyph set" {
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    var ui = f.ui();
    drawHorizontal(ui, Rect.init(0, 1, 10, 1), .{ .pane = 2 }, 40, 10, 0);
    try f.expectRow(1, "━━────────");
    try testing.expectEqual(Axis.h, f.hits.at(9, 1).?.scrollbar.axis);
    ui.ascii = true;
    drawHorizontal(ui, Rect.init(0, 1, 10, 1), .{ .pane = 2 }, 40, 10, 30);
    try f.expectRow(1, "--------==");
    drawVertical(ui, Rect.init(9, 0, 1, 2), .{ .pane = 2 }, 4, 2, 2);
    try testing.expectEqualStrings("|", f.cell(9, 0).char.grapheme);
    try testing.expectEqualStrings("#", f.cell(9, 1).char.grapheme);
}
