//! The flaky-test dashboard's paint (`Pane.flaky`): `≋ N wobbly tests`,
//! the key hint, then the items grouped under a dim file line — the
//! cursor arrow, the outcome bar (`✓✗✓~`, most recent last, padded to
//! the ten the history keeps), the title with its `:line`, and how
//! many times it flipped. Every item row registers
//! `.script_hit{ pane, id = item }`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const list_panel = @import("list_panel.zig");
const ids = @import("../core/ids.zig");
const flaky = @import("../app/flaky.zig");

const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const hint = "  ⏎ jump to source   r refresh   esc close";

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *flaky.FlakyPane, focused: bool) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    const n = p.items.len;
    var head = Theme.onBg(if (n > 0) t.accent else t.muted, t.bg.bg);
    head.bold = true;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(ui.fmt("  {s} {d} wobbly test{s}", .{ if (ui.ascii) "~~" else "≋", n, if (n == 1) "" else "s" }), area.w), head);
    if (area.h < 2) return;
    _ = ui.putStr(area.x, area.y + 1, area.w, ui.clipStr(overlay.hintText(ui, hint), area.w), Theme.onBg(t.muted, t.bg.bg));
    if (area.h < 4) return;
    if (n == 0) {
        _ = ui.putStr(area.x, area.y + 3, area.w, ui.clipStr(if (ui.ascii) "  + no flaky tests in recent history" else "  ✓ no flaky tests in recent history", area.w), Theme.onBg(t.info_fg, t.bg.bg));
        return;
    }
    // Painted rows: a file line before each run of items from one file.
    const Line = union(enum) { file: []const u8, item: u32 };
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var cursor_row: usize = 0;
    var last: []const u8 = "";
    for (p.items, 0..) |it, i| {
        if (!std.mem.eql(u8, it.rel, last)) {
            lines.append(ui.arena, .{ .file = it.rel }) catch return;
            last = it.rel;
        }
        if (i == p.cursor) cursor_row = lines.items.len;
        lines.append(ui.arena, .{ .item = @intCast(i) }) catch return;
    }
    const body = Rect.init(area.x, area.y + 3, area.w, area.h - 3);
    const win = list_panel.scrollWindow(&p.scroll, cursor_row, lines.items.len, body.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < lines.items.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        switch (lines.items[i]) {
            .file => |f| _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ui.fmt("  {s}", .{f}), r.w), Theme.onBg(t.muted, t.bg.bg)),
            .item => |idx| {
                const it = p.items[idx];
                const on_cursor = idx == p.cursor and focused;
                const bg = if (on_cursor) t.cursor_line.bg else t.bg.bg;
                if (on_cursor) ui.fill(r, t.cursor_line);
                var x = r.x;
                x += ui.putStr(x, r.y, r.w, if (on_cursor) (if (ui.ascii) "> " else "▶ ") else "  ", Theme.onBg(t.accent, bg));
                var bar: [flaky.keep * 3]u8 = undefined;
                var bl: usize = 0;
                for (it.outcomes) |o| {
                    const g = o.glyph(ui.ascii);
                    @memcpy(bar[bl .. bl + g.len], g);
                    bl += g.len;
                }
                const pad = flaky.keep -| it.outcomes.len;
                x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s}{s}  ", .{ bar[0..bl], " " ** flaky.keep }), Theme.onBg(t.accent, bg));
                x -= @intCast(flaky.keep - pad);
                var title = Theme.onBg(t.fg, bg);
                title.bold = on_cursor;
                x += ui.putStr(x, r.y, r.right() -| x, ui.clipStr(it.title, r.right() -| x), title);
                if (it.line > 0) x += ui.putStr(x, r.y, r.right() -| x, ui.fmt(":{d}", .{it.line}), Theme.onBg(t.muted, bg));
                _ = ui.putStr(x, r.y, r.right() -| x, ui.fmt("  {s}{d} flip{s}", .{ if (ui.ascii) "x" else "×", it.flips, if (it.flips == 1) "" else "s" }), Theme.onBg(t.muted, bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = idx } });
            },
        }
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the dashboard paints the tally, file groups, outcome bars, flips and one hit per item; the empty state" {
    var f = try Fixture.init(80, 8);
    defer f.deinit();
    var p = flaky.FlakyPane.init(testing.allocator);
    defer p.deinit();
    const a = p.snapshot.allocator();
    const items = try a.alloc(flaky.Item, 3);
    items[0] = .{ .rel = "tests/a.spec.ts", .suite = "S", .title = "alpha", .line = 10, .outcomes = &.{ .pass, .fail, .pass, .fail }, .flips = 3 };
    items[1] = .{ .rel = "tests/a.spec.ts", .suite = "S", .title = "beta", .line = 0, .outcomes = &.{ .fail, .pass, .flaky }, .flips = 1 };
    items[2] = .{ .rel = "tests/b.spec.ts", .suite = "", .title = "gamma", .line = 4, .outcomes = &.{ .pass, .fail }, .flips = 1 };
    p.items = items;
    p.cursor = 1;
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectRow(0, "  ≋ 3 wobbly tests");
    try f.expectRow(1, "  ⏎ jump to source   r refresh   esc close");
    try f.expectRow(3, "  tests/a.spec.ts");
    try f.expectRow(4, "  ✓✗✓✗        alpha:10  ×3 flips");
    try f.expectRow(5, "▶ ✗✓~         beta  ×1 flip");
    try f.expectRow(6, "  tests/b.spec.ts");
    try f.expectRow(7, "  ✓✗          gamma:4  ×1 flip");
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 5).?.script_hit.id);
    try testing.expectEqual(@as(u32, 2), f.hits.at(3, 7).?.script_hit.id);
    try testing.expect(f.hits.at(3, 6) == null);
    try testing.expect(f.bgEql(2, 5, f.theme.cursor_line));
    p.items = &.{};
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectRow(0, "  ≋ 0 wobbly tests");
    try f.expectRow(3, "  ✓ no flaky tests in recent history");
}
