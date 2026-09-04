//! Toasts — the notification stack in the bottom-right corner, each a
//! small bordered box, the newest closest to the statusline. The border
//! carries the level: info and warn in the calm muted color, an error
//! in red so a failure stands out. At most five paint; past that the
//! oldest slot becomes `+K more…` so a burst never covers the pane.
//!
//! Each box registers `.button(button_base + i)` — click to dismiss —
//! in the same statement as its paint. The app passes the region above
//! the statusline; the stack keeps one spacer row above it and one
//! cell of margin on the right, and paints nothing at all on a screen
//! too small to hold a box.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Segment = vaxis.Segment;
const Style = vaxis.Style;

pub const Level = enum { info, warn, err };

pub const Toast = struct { text: []const u8, level: Level = .info };

pub const max_width: u16 = 64;
pub const min_width: u16 = 20;
pub const max_visible: usize = 5;
pub const max_text_rows: u16 = 4;
pub const right_margin: u16 = 1;
pub const bottom_margin: u16 = 1;
/// `.button(button_base + i)` dismisses toast `i`.
pub const button_base: u32 = 0x7000_0000;

pub fn borderStyle(t: *const Theme, level: Level) Style {
    const bg = t.overlay_bg.bg;
    return switch (level) {
        .info => Theme.onBg(t.muted, bg),
        .warn => Theme.onBg(t.warn_fg, bg),
        .err => Theme.onBg(t.error_fg, bg),
    };
}

/// Paints one box whose bottom edge is `bottom` (exclusive), returns
/// its rect, or null when it does not fit above `top`.
fn paintBox(ui: Ui, area: Rect, bottom: u16, text: []const u8, border: Style, hit_id: ?u32) ?Rect {
    const t = ui.theme;
    const w = @min(@max(ui.width(text) + 4, min_width), @min(max_width, area.w -| right_margin));
    if (w < 6) return null;
    const inner_w = w - 4;
    const segs = [_]Segment{.{ .text = text, .style = Theme.onBg(t.fg, t.overlay_bg.bg) }};
    const rows = @min(@max(ui.canvas.measure(&segs, inner_w, .{ .wrap = .word, .trim = true }), 1), max_text_rows);
    const h = rows + 2;
    if (bottom < area.y + h) return null;
    const r = Rect.init(area.right() - right_margin - w, bottom - h, w, h);
    ui.fill(r, t.overlay_bg);
    const kind: @import("border.zig").Kind = if (ui.ascii) .ascii else .rounded;
    const inner = ui.canvas.border(r, kind, border, null);
    _ = ui.canvas.text(inner.inset(0).splitLeft(1).rest.splitRight(1).left, &segs, .{ .wrap = .word, .trim = true });
    if (hit_id) |id| ui.hit(r, .{ .button = id });
    return r;
}

/// Newest first in `toasts`: index 0 lands closest to the bottom.
pub fn draw(ui: Ui, area: Rect, toasts: []const Toast) void {
    if (toasts.len == 0 or area.w < min_width or area.h < 3) return;
    const t = ui.theme;
    var bottom = area.bottom() -| bottom_margin;
    const overflow = toasts.len > max_visible;
    const take = if (overflow) max_visible - 1 else @min(toasts.len, max_visible);
    for (toasts[0..take], 0..) |toast, i| {
        const r = paintBox(ui, area, bottom, toast.text, borderStyle(t, toast.level), button_base + @as(u32, @intCast(i))) orelse return;
        bottom = r.y;
    }
    if (overflow) {
        const hidden = toasts.len - take;
        const more = if (ui.ascii) ui.fmt("+{d} more...", .{hidden}) else ui.fmt("+{d} more…", .{hidden});
        _ = paintBox(ui, area, bottom, more, borderStyle(t, .info), null);
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "toasts stack from the bottom right, newest lowest, with dismiss hits and level colors" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    const toasts = [_]Toast{
        .{ .text = "mark 'a set" },
        .{ .text = "no mark 'z", .level = .warn },
        .{ .text = "save failed: EACCES", .level = .err },
    };
    draw(f.ui(), f.full(), &toasts);
    try f.expectContains("mark 'a set");
    try f.expectContains("no mark 'z");
    try f.expectContains("save failed: EACCES");
    // Newest box: rows 8..10 (one spacer above row 11), 20 wide ending at col 58.
    try f.expectRow(11, "");
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(10, &buf), "╯"));
    try testing.expect(std.mem.indexOf(u8, f.row(9, &buf), "mark 'a set") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(6, &buf), "no mark 'z") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(3, &buf), "save failed") != null);
    try testing.expectEqual(button_base + 0, f.hits.at(50, 9).?.button);
    try testing.expectEqual(button_base + 1, f.hits.at(50, 6).?.button);
    try testing.expectEqual(button_base + 2, f.hits.at(50, 3).?.button);
    try testing.expect(f.hits.at(10, 9) == null);
    try testing.expect(f.fgEql(58, 9, f.theme.muted));
    try testing.expect(f.fgEql(58, 6, f.theme.warn_fg));
    try testing.expect(f.fgEql(58, 3, f.theme.error_fg));
    try testing.expect(f.bgEql(50, 9, f.theme.overlay_bg));
}

test "a long text wraps inside the box; a burst collapses into +K more" {
    var f = try Fixture.init(50, 20);
    defer f.deinit();
    const long = [_]Toast{.{ .text = "unsaved changes in notes.txt — use :q! to discard them, or :w to keep them first" }};
    draw(f.ui(), f.full(), &long);
    try f.expectContains("unsaved changes in");
    try f.expectContains("to keep them first");
    const r = f.hits.items.items[0].rect;
    try testing.expectEqual(@as(u16, 4), r.h);
    // Capped at the screen width less the margin: 49 wide from column 0.
    try testing.expectEqual(@as(u16, 49), r.w);
    try testing.expectEqual(@as(u16, 0), r.x);
    f.hits.reset();
    var burst: [8]Toast = undefined;
    for (&burst, 0..) |*b, i| b.* = .{ .text = if (i == 0) "eight" else "older" };
    draw(f.ui(), f.full(), &burst);
    try f.expectContains("+4 more…");
    try testing.expectEqual(@as(usize, 4), f.hits.items.items.len);
    var ui = f.ui();
    ui.ascii = true;
    draw(ui, f.full(), &burst);
    try f.expectContains("+4 more...");
}

test "no room, no paint" {
    var f = try Fixture.init(18, 8);
    defer f.deinit();
    draw(f.ui(), f.full(), &.{.{ .text = "hi" }});
    try f.expectRow(4, "");
    try testing.expectEqual(@as(usize, 0), f.hits.items.items.len);
    var g = try Fixture.init(40, 5);
    defer g.deinit();
    // Two boxes need 7 rows; the second is dropped, the first stays.
    draw(g.ui(), g.full(), &.{ .{ .text = "one" }, .{ .text = "two" } });
    try g.expectContains("one");
    try g.expectLacks("two");
    draw(g.ui(), Rect.empty, &.{.{ .text = "x" }});
    draw(g.ui(), g.full(), &.{});
}
