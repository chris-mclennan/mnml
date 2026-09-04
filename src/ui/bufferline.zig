//! Bufferline — one row of tabs on `theme.bufferline`. Each tab is
//! ` title ` (plus `● ` when dirty, in `theme.tab_dirty`), the active one
//! in `theme.tab_active`, the rest in `theme.tab_inactive`, one cell of
//! strip between them. Every painted tab registers a `.tab{leaf=0, idx}`
//! hit in the same statement as its paint.
//!
//! Tabs that do not fit are not painted at all: a half tab is a dead
//! click target. The active tab is always brought into view first, so
//! a strip narrower than the open set still shows what you are editing.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;

pub const Tab = struct { id: PaneId, title: []const u8, dirty: bool, active: bool };

fn tabWidth(ui: Ui, tab: Tab) u16 {
    return 2 + ui.width(tab.title) + @as(u16, if (tab.dirty) 2 else 0);
}

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab) void {
    const t = ui.theme;
    ui.fill(area, t.bufferline);
    if (area.isEmpty() or tabs.len == 0) return;
    const y = area.y;

    // Start from the first tab that lets the active one fit.
    var first: usize = 0;
    var active: usize = 0;
    for (tabs, 0..) |tab, i| if (tab.active) {
        active = i;
    };
    while (first < active) : (first += 1) {
        var w: u16 = 0;
        var i = first;
        while (i <= active) : (i += 1) w += tabWidth(ui, tabs[i]) + 1;
        if (w <= area.w + 1) break;
    }

    var x = area.x;
    var i = first;
    while (i < tabs.len) : (i += 1) {
        const tab = tabs[i];
        const w = tabWidth(ui, tab);
        if (x + w > area.right()) break;
        const style = if (tab.active) t.tab_active else t.tab_inactive;
        const r = Rect.init(x, y, w, 1);
        ui.fill(r, style);
        var tx = x + ui.putStr(x + 1, y, w - 1, tab.title, style) + 1;
        if (tab.dirty) tx += ui.putStr(tx, y, 2, " ●", Theme.onBg(t.tab_dirty, style.bg));
        ui.hit(r, .{ .tab = .{ .leaf = 0, .idx = @intCast(i) } });
        x += w + 1;
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "tabs paint in order with the active style and a dirty dot, and register hits" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "a.txt", .dirty = false, .active = false },
        .{ .id = 2, .title = "b.txt", .dirty = true, .active = true },
        .{ .id = 3, .title = "c.txt", .dirty = false, .active = false },
    };
    draw(f.ui(), f.full(), &tabs);
    try f.expectRow(0, " a.txt   b.txt ●   c.txt");
    try testing.expect(f.bgEql(1, 0, f.theme.tab_inactive));
    try testing.expect(f.bgEql(9, 0, f.theme.tab_active));
    try testing.expect(f.style(9, 0).bold);
    try testing.expect(f.fgEql(15, 0, f.theme.tab_dirty));
    try testing.expectEqual(@as(u16, 0), f.hits.at(3, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 1), f.hits.at(15, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 2), f.hits.at(20, 0).?.tab.idx);
    // The gap between tabs is strip, not a tab.
    try testing.expect(f.hits.at(7, 0) == null);
    try testing.expect(f.bgEql(7, 0, f.theme.bufferline));
}

test "a tab that does not fit is dropped whole; the active tab is always shown" {
    var f = try Fixture.init(12, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = false },
        .{ .id = 2, .title = "beta", .dirty = false, .active = false },
        .{ .id = 3, .title = "gamma", .dirty = false, .active = true },
    };
    draw(f.ui(), f.full(), &tabs);
    try f.expectRow(0, " gamma");
    try testing.expectEqual(@as(u16, 2), f.hits.at(2, 0).?.tab.idx);
    try testing.expect(f.hits.at(9, 0) == null);

    var g = try Fixture.init(14, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = true },
        .{ .id = 2, .title = "beta", .dirty = false, .active = false },
    };
    draw(g.ui(), g.full(), &two);
    try g.expectRow(0, " alpha   beta");
    draw(g.ui(), Rect.empty, &two);
    draw(g.ui(), g.full(), &.{});
}
