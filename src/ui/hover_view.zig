//! The hover box — also signature help, which is the same box with a
//! page counter (`2/3` overloads). A bordered box just under the cursor
//! cell (above when it will not fit), the lines clipped to the width;
//! `scroll` is the first line shown. The box registers `.hover_popup`
//! over itself, so the wheel over it reaches its lines (Rust: two a
//! notch) instead of the editor under it.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const editor_view = @import("editor_view.zig");
const md_view = @import("md_view.zig");

pub const Props = struct {
    lines: []const []const u8,
    page: usize,
    pages: usize,
};

pub const max_height: u16 = 18;

pub fn draw(ui: Ui, screen: Rect, cursor: ?editor_view.Cursor, scroll: *usize, p: Props) void {
    const t = ui.theme;
    if (p.lines.len == 0 or screen.w < 8 or screen.h < 5) return;
    // A server's hover is markdown: `**bold**`, `*em*`, `` `code` `` paint
    // as such (Neovim's `stylize_markdown`), the markers dropped — a
    // fenced block's fences are already gone (`types.readHover`).
    const base = Theme.onBg(t.fg, t.overlay_bg.bg);
    const segs = ui.arena.alloc([]const md_view.Segment, p.lines.len) catch return;
    var content_w: u16 = 8;
    for (p.lines, 0..) |l, i| {
        segs[i] = md_view.inlineSegs(ui.arena, t, l, base) catch &.{};
        var w_line: u16 = 0;
        for (segs[i]) |seg| w_line +|= ui.width(seg.text);
        content_w = @max(content_w, w_line);
    }
    const w = @min(content_w + 2, screen.w -| 2);
    const max_h = @min(screen.h -| 2, max_height);
    const h: u16 = @min(@as(u16, @intCast(@min(p.lines.len + 2, std.math.maxInt(u16)))), max_h);
    const inner_rows: usize = h -| 2;
    const c = cursor orelse editor_view.Cursor{ .x = screen.x + 2, .y = screen.y + 1 };
    const below = c.y +| 1;
    const y: u16 = if (below + h <= screen.bottom()) below else if (c.y >= screen.y + h) c.y - h else screen.y;
    const x: u16 = @max(@min(c.x, screen.right() -| w), screen.x);
    const title: ?[]const u8 = if (p.pages > 1) ui.fmt("{d}/{d}", .{ p.page + 1, p.pages }) else null;
    const box = Rect.init(x, y, w, h);
    const inner = overlay.frame(ui, box, title);
    ui.hit(box, .hover_popup);
    if (inner.isEmpty()) return;
    scroll.* = @min(scroll.*, p.lines.len -| inner_rows);
    var i: usize = 0;
    while (i < inner.h and scroll.* + i < p.lines.len) : (i += 1) {
        const r = inner.row(@intCast(i));
        var col = r.x;
        for (segs[scroll.* + i]) |seg| {
            if (col >= r.right()) break;
            const left: u16 = r.right() - col;
            col += ui.putStr(col, r.y, left, ui.clipStr(seg.text, left), seg.style);
        }
    }
}

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the box registers `.hover_popup` over itself and nothing outside it" {
    var f = try Fixture.init(40, 12);
    defer f.deinit();
    const lines = [_][]const u8{ "fn foo()", "", "docs", "more", "and more" };
    var scroll: usize = 0;
    draw(f.ui(), f.full(), .{ .x = 4, .y = 1 }, &scroll, .{ .lines = &lines, .page = 0, .pages = 1 });
    // The box: from row 2 under the cursor, 7 rows (5 lines + the frame),
    // 10 wide (8 + the frame) from column 4.
    try testing.expect(f.hits.at(4, 2).? == .hover_popup);
    try testing.expect(f.hits.at(13, 8).? == .hover_popup);
    try testing.expect(f.hits.at(8, 5).? == .hover_popup);
    try testing.expect(f.hits.at(14, 5) == null);
    try testing.expect(f.hits.at(8, 1) == null);
    try testing.expect(f.hits.at(8, 9) == null);
}

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

test "markdown emphasis in the box: `**foo**` paints foo in bold without its asterisks" {
    var f = try Fixture.init(30, 8);
    defer f.deinit();
    var scroll: usize = 0;
    const lines = [_][]const u8{ "**foo** bar", "*em* `code`" };
    draw(f.ui(), f.full(), .{ .x = 2, .y = 1 }, &scroll, .{ .lines = &lines, .page = 0, .pages = 1 });
    try f.expectContains("foo bar");
    try f.expectContains("em code");
    try f.expectLacks("**");
    try f.expectLacks("`");
    // Row 3 is the first inner row: `f` at x=3 is bold, the ` ` after `foo` is not.
    try testing.expect(f.style(3, 3).bold);
    try testing.expect(!f.style(6, 3).bold);
}
