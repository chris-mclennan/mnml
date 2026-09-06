//! The hover tooltip — the popup near the pointer (`ui.hover_tooltip`):
//! one or two lines in an overlay box, below and to the right of the
//! cell, flipped above / left when the screen ends. It registers no
//! hit — a tip is never a click target. (The info view at the bottom of
//! the sidebar is `info_view.zig`.)

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");

pub const Tip = struct {
    title: []const u8,
    detail: ?[]const u8 = null,
};

pub const max_width: u16 = 60;

/// The popup beside `(x, y)`.
pub fn draw(ui: Ui, screen: Rect, x: u16, y: u16, tip: Tip) void {
    if (screen.isEmpty()) return;
    const t = ui.theme;
    const inner_w: u16 = @min(@max(ui.width(tip.title), if (tip.detail) |d| ui.width(d) else 0), @min(max_width, screen.w -| 2));
    if (inner_w == 0) return;
    const w = inner_w + 2;
    const h: u16 = if (tip.detail != null) 4 else 3;
    if (w > screen.w or h > screen.h) return;
    // Below-right of the cell; flip when the edge is in the way.
    var bx = x + 1;
    if (bx + w > screen.right()) bx = screen.right() - w;
    var by = y + 1;
    if (by + h > screen.bottom()) by = y -| h;
    if (by < screen.y) by = screen.y;
    const r = Rect.init(bx, by, w, h);
    const inner = overlay.frame(ui, r, null);
    if (inner.isEmpty()) return;
    _ = ui.putStr(inner.x, inner.y, inner.w, ui.clipStr(tip.title, inner.w), Theme.onBg(t.fg, t.overlay_bg.bg));
    if (tip.detail) |d| if (inner.h > 1) {
        _ = ui.putStr(inner.x, inner.y + 1, inner.w, ui.clipStr(d, inner.w), Theme.onBg(t.muted, t.overlay_bg.bg));
    };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the popup sits below-right, flips at the edges, and registers no hit" {
    var f = try Fixture.init(40, 10);
    defer f.deinit();
    draw(f.ui(), f.full(), 2, 1, .{ .title = "click: toggle keymap", .detail = "right-click: menu" });
    try f.expectContains("click: toggle keymap");
    try f.expectContains("right-click: menu");
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(3, &buf), "click: toggle keymap") != null);
    try testing.expectEqual(@as(usize, 0), f.hits.items.items.len);
    // Near the bottom-right it flips above and left.
    var g = try Fixture.init(40, 10);
    defer g.deinit();
    draw(g.ui(), g.full(), 38, 9, .{ .title = "hello" });
    try testing.expect(std.mem.indexOf(u8, g.row(7, &buf), "hello") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, g.row(7, &buf), " "), "hello│"));
    // No room at all: nothing painted.
    var h = try Fixture.init(6, 2);
    defer h.deinit();
    draw(h.ui(), h.full(), 0, 0, .{ .title = "hello world" });
    try h.expectRow(0, "");
}
