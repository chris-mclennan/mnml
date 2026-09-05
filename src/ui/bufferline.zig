//! Bufferline — one row of tabs on `theme.bufferline`. Each tab is
//! ` title ` (plus `● ` when dirty, in `theme.tab_dirty`), the active one
//! in `theme.tab_active`, the rest in `theme.tab_inactive`, one cell of
//! strip between them. Every painted tab registers a `.tab{leaf, idx}`
//! hit in the same statement as its paint; the `+` after the last tab
//! registers the `.button` the caller names.
//!
//! // changed: the strip is per leaf (a tab drags between leaves), so
//! `draw` takes `Opts{ leaf, new_tab }` — the leaf index the hits carry
//! and the id of the `+` button, if wanted.
//!
//! Tabs that do not fit are not painted at all: a half tab is a dead
//! click target. The active tab is always brought into view first, so
//! a strip narrower than the open set still shows what you are editing.
//!
//! Pty tabs form the session strip: they are painted after the file
//! tabs behind a `│` divider, as ` label$ × ` — the `$` marks a
//! terminal, the `×` registers a `.tab_close` hit on top of the tab's
//! own so one click closes a session. The hits carry the leaf's tab
//! index, not the painted position, so the app never re-derives the
//! order.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;

pub const Kind = enum { file, pty };

pub const Tab = struct {
    id: PaneId,
    title: []const u8,
    dirty: bool,
    active: bool,
    kind: Kind = .file,
};

pub const Opts = struct {
    /// What the `.tab` hits carry as their leaf.
    leaf: u32 = 0,
    /// Paint ` + ` after the last tab and register it as this `.button`.
    new_tab: ?u32 = null,
};

/// The width of the `+` chip.
pub const plus_w: u16 = 3;

/// The tab positions a caller needs to route a drop: the `x` each tab
/// starts at and its width, in strip order from `first`.
pub const Slot = struct { idx: usize, x: u16, w: u16 };

/// ` title ` plus ` ●` when dirty; a pty tab is ` title$ × `.
fn tabWidth(ui: Ui, tab: Tab) u16 {
    const base = 2 + ui.width(tab.title) + @as(u16, if (tab.dirty) 2 else 0);
    return if (tab.kind == .pty) base + 1 + close_w else base;
}

/// The ` ×` cells of a pty tab.
const close_w: u16 = 2;

fn countKind(tabs: []const Tab, kind: Kind) usize {
    var n: usize = 0;
    for (tabs) |tab| n += @intFromBool(tab.kind == kind);
    return n;
}

/// The tab at painted position `pos`: the file tabs in order, then
/// the pty tabs in order.
fn atVisual(tabs: []const Tab, pos: usize) usize {
    const files = countKind(tabs, .file);
    const want: Kind = if (pos < files) .file else .pty;
    var skip = if (pos < files) pos else pos - files;
    for (tabs, 0..) |tab, i| {
        if (tab.kind != want) continue;
        if (skip == 0) return i;
        skip -= 1;
    }
    unreachable;
}

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) void {
    const t = ui.theme;
    ui.fill(area, t.bufferline);
    if (area.isEmpty()) return;
    const y = area.y;
    const end = drawTabs(ui, area, tabs, opts.leaf, null);
    if (opts.new_tab) |id| {
        if (end + plus_w <= area.right()) {
            const r = Rect.init(end, y, plus_w, 1);
            _ = ui.putStr(end, y, plus_w, " + ", Theme.onBg(t.muted, t.bufferline.bg));
            ui.hit(r, .{ .button = id });
        }
    }
}

/// Where each tab would sit for `area` — the drop router asks this to
/// place a dragged tab between two others without repainting.
pub fn slots(ui: Ui, area: Rect, tabs: []const Tab, out: []Slot) []Slot {
    var n: usize = 0;
    _ = drawTabs(ui, area, tabs, 0, .{ .out = out, .n = &n });
    return out[0..n];
}

const SlotSink = struct { out: []Slot, n: *usize };

/// Paints (or, with a sink, only measures) the tabs. Returns the x
/// just past the last painted tab (plus a cell of strip).
fn drawTabs(ui: Ui, area: Rect, tabs: []const Tab, leaf: u32, sink: ?SlotSink) u16 {
    const t = ui.theme;
    const y = area.y;
    if (tabs.len == 0) return area.x;
    const files = countKind(tabs, .file);
    const has_divider = files > 0 and files < tabs.len;

    // Start from the first painted position that lets the active one fit.
    var first: usize = 0;
    var active: usize = 0;
    for (0..tabs.len) |pos| if (tabs[atVisual(tabs, pos)].active) {
        active = pos;
    };
    while (first < active) : (first += 1) {
        var w: u16 = 0;
        var pos = first;
        while (pos <= active) : (pos += 1) {
            w += tabWidth(ui, tabs[atVisual(tabs, pos)]) + 1;
            if (has_divider and pos + 1 == files) w += 2;
        }
        if (w <= area.w + 1) break;
    }

    var x = area.x;
    var pos = first;
    while (pos < tabs.len) : (pos += 1) {
        if (has_divider and pos == files and pos > first) {
            // The strip divider sits in the gap after the last file tab.
            if (x + 2 > area.right()) break;
            if (sink == null) _ = ui.putStr(x, y, 1, if (ui.ascii) "|" else "│", Theme.onBg(t.muted, t.bufferline.bg));
            x += 2;
        }
        const i = atVisual(tabs, pos);
        const tab = tabs[i];
        const w = tabWidth(ui, tab);
        if (x + w > area.right()) break;
        if (sink) |sk| {
            if (sk.n.* < sk.out.len) {
                sk.out[sk.n.*] = .{ .idx = i, .x = x, .w = w };
                sk.n.* += 1;
            }
            x += w + 1;
            continue;
        }
        const style = if (tab.active) t.tab_active else t.tab_inactive;
        const r = Rect.init(x, y, w, 1);
        ui.fill(r, style);
        var tx = x + ui.putStr(x + 1, y, w - 1, tab.title, style) + 1;
        if (tab.kind == .pty) tx += ui.putStr(tx, y, 1, "$", Theme.onBg(t.muted, style.bg));
        if (tab.dirty) tx += ui.putStr(tx, y, 2, " ●", Theme.onBg(t.tab_dirty, style.bg));
        ui.hit(r, .{ .tab = .{ .leaf = leaf, .idx = @intCast(i) } });
        if (tab.kind == .pty) {
            const cr = Rect.init(tx, y, close_w, 1);
            const hot = ui.hovered(cr);
            _ = ui.putStr(tx, y, close_w, if (ui.ascii) " x" else " ×", Theme.onBg(if (hot) t.error_fg else t.muted, style.bg));
            ui.hit(cr, .{ .tab_close = .{ .leaf = leaf, .idx = @intCast(i) } });
        }
        x += w + 1;
    }
    return x;
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
    draw(f.ui(), f.full(), &tabs, .{ .leaf = 3, .new_tab = 77 });
    try f.expectRow(0, " a.txt   b.txt ●   c.txt   +");
    try testing.expectEqual(@as(u32, 3), f.hits.at(3, 0).?.tab.leaf);
    try testing.expectEqual(@as(u32, 77), f.hits.at(26, 0).?.button);
    var slot_buf: [8]Slot = undefined;
    const sl = slots(f.ui(), f.full(), &tabs, &slot_buf);
    try testing.expectEqual(@as(usize, 3), sl.len);
    try testing.expectEqual(@as(u16, 8), sl[1].x);
    try testing.expectEqual(@as(u16, 9), sl[1].w);
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
    draw(f.ui(), f.full(), &tabs, .{});
    try f.expectRow(0, " gamma");
    try testing.expectEqual(@as(u16, 2), f.hits.at(2, 0).?.tab.idx);
    try testing.expect(f.hits.at(9, 0) == null);

    var g = try Fixture.init(14, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = true },
        .{ .id = 2, .title = "beta", .dirty = false, .active = false },
    };
    draw(g.ui(), g.full(), &two, .{});
    try g.expectRow(0, " alpha   beta");
    draw(g.ui(), Rect.empty, &two, .{});
    draw(g.ui(), g.full(), &.{}, .{ .new_tab = 1 });
    try g.expectRow(0, " +");
}

test "pty tabs cluster after the files behind a divider, carry `$` and a close hit that keeps the leaf index" {
    var f = try Fixture.init(48, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 5, .title = "zsh", .dirty = false, .active = false, .kind = .pty },
        .{ .id = 1, .title = "a.txt", .dirty = false, .active = true },
        .{ .id = 2, .title = "b.txt", .dirty = false, .active = false },
    };
    draw(f.ui(), f.full(), &tabs, .{ .leaf = 1, .new_tab = 9 });
    try f.expectRow(0, " a.txt   b.txt  │  zsh$ ×   +");
    // The file tabs keep their leaf indices; the pty tab is index 0.
    try testing.expectEqual(@as(u16, 1), f.hits.at(2, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 2), f.hits.at(10, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 0), f.hits.at(20, 0).?.tab.idx);
    // The `×` wins over the tab beneath it.
    const close = f.hits.at(24, 0).?;
    try testing.expect(close == .tab_close);
    try testing.expectEqual(@as(u16, 0), close.tab_close.idx);
    try testing.expectEqual(@as(u32, 1), close.tab_close.leaf);
    try testing.expectEqual(@as(u32, 9), f.hits.at(27, 0).?.button);
    // The divider is strip, not a tab.
    try testing.expect(f.hits.at(16, 0) == null);
    // Slots follow the painted order but name the leaf index.
    var slot_buf: [8]Slot = undefined;
    const sl = slots(f.ui(), f.full(), &tabs, &slot_buf);
    try testing.expectEqual(@as(usize, 3), sl.len);
    try testing.expectEqual(@as(usize, 1), sl[0].idx);
    try testing.expectEqual(@as(usize, 0), sl[2].idx);
    try testing.expectEqual(@as(u16, 18), sl[2].x);
    // ASCII: `x` for the close, `|` for the divider.
    f.ascii = true;
    draw(f.ui(), f.full(), &tabs, .{});
    try f.expectRow(0, " a.txt   b.txt  |  zsh$ x");
    // An active pty on a narrow strip is still brought into view.
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = false },
        .{ .id = 5, .title = "sh", .dirty = false, .active = true, .kind = .pty },
    };
    draw(g.ui(), g.full(), &two, .{});
    try g.expectRow(0, " sh$ ×");
    try testing.expectEqual(@as(u16, 1), g.hits.at(1, 0).?.tab.idx);
}
