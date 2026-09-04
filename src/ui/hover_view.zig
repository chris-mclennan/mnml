//! The hover box — also signature help, which is the same box with a
//! page counter (`2/3` overloads). A bordered box just under the cursor
//! cell (above when it will not fit), the lines clipped to the width;
//! `scroll` is the first line shown.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const editor_view = @import("editor_view.zig");

pub const Props = struct {
    lines: []const []const u8,
    page: usize,
    pages: usize,
};

pub const max_height: u16 = 18;

pub fn draw(ui: Ui, screen: Rect, cursor: ?editor_view.Cursor, scroll: *usize, p: Props) void {
    const t = ui.theme;
    if (p.lines.len == 0 or screen.w < 8 or screen.h < 5) return;
    var content_w: u16 = 8;
    for (p.lines) |l| content_w = @max(content_w, ui.width(l));
    const w = @min(content_w + 2, screen.w -| 2);
    const max_h = @min(screen.h -| 2, max_height);
    const h: u16 = @min(@as(u16, @intCast(@min(p.lines.len + 2, std.math.maxInt(u16)))), max_h);
    const inner_rows: usize = h -| 2;
    const c = cursor orelse editor_view.Cursor{ .x = screen.x + 2, .y = screen.y + 1 };
    const below = c.y +| 1;
    const y: u16 = if (below + h <= screen.bottom()) below else if (c.y >= screen.y + h) c.y - h else screen.y;
    const x: u16 = @max(@min(c.x, screen.right() -| w), screen.x);
    const title: ?[]const u8 = if (p.pages > 1) ui.fmt("{d}/{d}", .{ p.page + 1, p.pages }) else null;
    const inner = overlay.frame(ui, Rect.init(x, y, w, h), title);
    if (inner.isEmpty()) return;
    scroll.* = @min(scroll.*, p.lines.len -| inner_rows);
    var i: usize = 0;
    while (i < inner.h and scroll.* + i < p.lines.len) : (i += 1) {
        const r = inner.row(@intCast(i));
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(p.lines[scroll.* + i], r.w), Theme.onBg(t.fg, t.overlay_bg.bg));
    }
}

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "a box under the cursor with the lines; scroll clamps" {
    var f = try Fixture.init(30, 8);
    defer f.deinit();
    var scroll: usize = 99;
    const lines = [_][]const u8{ "fn main()", "", "Entry." };
    draw(f.ui(), f.full(), .{ .x = 2, .y = 1 }, &scroll, .{ .lines = &lines, .page = 0, .pages = 1 });
    try testing.expectEqual(@as(usize, 0), scroll);
    try f.expectContains("fn main()");
    try f.expectContains("Entry.");
    try testing.expect(f.bgEql(3, 3, f.theme.overlay_bg));
}
