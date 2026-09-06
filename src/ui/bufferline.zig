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
//! click target. The strip is a window: `Opts.first` is the first
//! painted position (the caller keeps it per leaf and re-fits it with
//! `fitActive` when the active tab changes); hidden tabs on either side
//! show as `‹` / `›` markers that register the caller's scroll buttons,
//! and the `+` keeps its place after the `›`, never pushed off.
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
    /// Paints the pin glyph before the title.
    pinned: bool = false,
};

/// The pin glyph (nf-fa-thumb_tack) and its ASCII twin, one cell each.
pub const pin_glyph = "\u{f08d}";
pub const pin_ascii = "^";

pub const Opts = struct {
    /// What the `.tab` hits carry as their leaf.
    leaf: u32 = 0,
    /// Paint ` + ` after the last tab and register it as this `.button`.
    new_tab: ?u32 = null,
    /// The first painted position (visual order); null fits the window
    /// to the active tab. Clamped so the strip never shows fewer tabs
    /// than it could.
    first: ?usize = null,
    /// The `.button` ids the `‹` / `›` markers register, when wanted.
    scroll_left: ?u32 = null,
    scroll_right: ?u32 = null,
};

/// What `draw` painted: the window it settled on and how many tabs
/// sit outside it on each side.
pub const Window = struct { first: usize = 0, hidden_left: usize = 0, hidden_right: usize = 0 };

/// The width of the `+` chip.
pub const plus_w: u16 = 3;
/// The width of a `‹ ` / ` ›` marker.
pub const marker_w: u16 = 2;

/// The tab positions a caller needs to route a drop: the `x` each tab
/// starts at and its width, in strip order from `first`.
pub const Slot = struct { idx: usize, x: u16, w: u16 };

/// ` title ` plus ` ●` when dirty; a pty tab is ` title$ × `.
fn tabWidth(ui: Ui, tab: Tab) u16 {
    const base = 2 + ui.width(tab.title) + @as(u16, if (tab.dirty) 2 else 0) + @as(u16, if (tab.pinned) 2 else 0);
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

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) Window {
    const t = ui.theme;
    ui.fill(area, t.bufferline);
    if (area.isEmpty()) return .{};
    const y = area.y;
    const plus: u16 = if (opts.new_tab != null) plus_w else 0;
    // The window: never past the first position from which the rest fits.
    const want = opts.first orelse fitActive(ui, area, tabs, plus);
    const first = @min(want, maxFirst(ui, area, tabs, plus));
    var strip = area;
    if (first > 0) {
        // `‹ `: tabs are hidden on the left.
        const lr = Rect.init(area.x, y, marker_w, 1);
        _ = ui.putStr(lr.x, y, marker_w, if (ui.ascii) "< " else "‹ ", Theme.onBg(t.accent, t.bufferline.bg));
        if (opts.scroll_left) |id| ui.hit(lr, .{ .button = id });
        strip = Rect.init(area.x + marker_w, y, area.w -| marker_w, 1);
    }
    // Does the rest fit beside the `+`? If not, reserve the `›` too.
    const fit_all = countFit(ui, strip.w -| plus, tabs, first) == tabs.len - first;
    const reserve: u16 = plus + (if (fit_all) 0 else marker_w);
    const paint_w = strip.w -| reserve;
    var res = drawTabs(ui, Rect.init(strip.x, y, paint_w, 1), tabs, first, opts.leaf, null);
    // A strip too narrow to fit one tab beside the markers still shows
    // the first windowed tab (clipped): the active tab is never hidden
    // behind a marker it left no room for.
    if (res.painted == 0 and tabs.len > first)
        res = drawTabs(ui, Rect.init(strip.x, y, strip.w, 1), tabs, first, opts.leaf, null);
    var x = res.end;
    const hidden_right = tabs.len - first - res.painted;
    if (hidden_right > 0 and x + marker_w <= area.right()) {
        const rr = Rect.init(x, y, marker_w, 1);
        _ = ui.putStr(rr.x, y, marker_w, if (ui.ascii) " >" else " ›", Theme.onBg(t.accent, t.bufferline.bg));
        if (opts.scroll_right) |id| ui.hit(rr, .{ .button = id });
        x += marker_w + 1;
    }
    if (opts.new_tab) |id| {
        if (x + plus_w <= area.right()) {
            const r = Rect.init(x, y, plus_w, 1);
            _ = ui.putStr(x, y, plus_w, " + ", Theme.onBg(t.muted, t.bufferline.bg));
            ui.hit(r, .{ .button = id });
        }
    }
    return .{ .first = first, .hidden_left = first, .hidden_right = hidden_right };
}

/// The first position from which the active tab is in view — the
/// window a change of active tab re-fits to. `area` is the whole
/// strip: the `+` and the markers a window needs are reserved here.
pub fn fitActive(ui: Ui, area: Rect, tabs: []const Tab, reserve: u16) usize {
    if (tabs.len == 0) return 0;
    var active: usize = 0;
    for (0..tabs.len) |pos| if (tabs[atVisual(tabs, pos)].active) {
        active = pos;
    };
    // Widen the window leftward from the active tab as far as the strip
    // holds, so the active tab is always the last one fully shown. A
    // window that starts past the first tab paints a `‹`; tabs after
    // the active one need the `›`.
    const right_marker: u16 = if (active + 1 < tabs.len) marker_w else 0;
    var first: usize = active;
    while (first > 0) {
        const cand = first - 1;
        const left_marker: u16 = if (cand > 0) marker_w else 0;
        const avail = area.w -| reserve -| right_marker -| left_marker;
        if (countFit(ui, avail, tabs, cand) < active - cand + 1) break;
        first = cand;
    }
    return first;
}

/// The smallest first position from which every remaining tab fits
/// beside `reserve` cells — a window past it hides tabs for nothing.
fn maxFirst(ui: Ui, area: Rect, tabs: []const Tab, reserve: u16) usize {
    var first: usize = 0;
    while (first + 1 < tabs.len) : (first += 1) {
        const w = area.w -| (if (first > 0) marker_w else 0) -| reserve;
        if (countFit(ui, w, tabs, first) == tabs.len - first) break;
    }
    return first;
}

/// How many tabs from `first` on paint whole in `width` cells.
fn countFit(ui: Ui, width: u16, tabs: []const Tab, first: usize) usize {
    const files = countKind(tabs, .file);
    const has_divider = files > 0 and files < tabs.len;
    var x: u16 = 0;
    var n: usize = 0;
    var pos = first;
    while (pos < tabs.len) : (pos += 1) {
        if (has_divider and pos == files and pos > first) {
            if (x + 2 > width) break;
            x += 2;
        }
        const w = tabWidth(ui, tabs[atVisual(tabs, pos)]);
        if (x + w > width) break;
        x += w + 1;
        n += 1;
    }
    return n;
}

/// Where each tab would sit for `area` — the drop router asks this to
/// place a dragged tab between two others without repainting.
pub fn slots(ui: Ui, area: Rect, tabs: []const Tab, out: []Slot) []Slot {
    return slotsFrom(ui, area, tabs, fitActive(ui, area, tabs, 0), out);
}

/// `slots` from a given window — the one the strip painted.
pub fn slotsFrom(ui: Ui, area: Rect, tabs: []const Tab, first: usize, out: []Slot) []Slot {
    var n: usize = 0;
    _ = drawTabs(ui, area, tabs, first, 0, .{ .out = out, .n = &n });
    return out[0..n];
}

const SlotSink = struct { out: []Slot, n: *usize };

const TabsResult = struct { end: u16, painted: usize };

/// Paints (or, with a sink, only measures) the tabs from `first`.
/// Returns the x just past the last painted tab (plus a cell of
/// strip) and how many were painted.
fn drawTabs(ui: Ui, area: Rect, tabs: []const Tab, first: usize, leaf: u32, sink: ?SlotSink) TabsResult {
    const t = ui.theme;
    const y = area.y;
    if (tabs.len == 0) return .{ .end = area.x, .painted = 0 };
    const files = countKind(tabs, .file);
    const has_divider = files > 0 and files < tabs.len;

    var x = area.x;
    var painted: usize = 0;
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
        painted += 1;
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
        var tx = x + 1;
        if (tab.pinned) tx += ui.putStr(tx, y, 2, if (ui.ascii) pin_ascii ++ " " else pin_glyph ++ " ", Theme.onBg(t.tab_dirty, style.bg));
        tx += ui.putStr(tx, y, w - (tx - x), tab.title, style);
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
    return .{ .end = x, .painted = painted };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn hasButton(f: *Fixture, id: u32) bool {
    for (f.hits.items.items) |h| if (h.target == .button and h.target.button == id) return true;
    return false;
}

fn hasTab(f: *Fixture, idx: u16) bool {
    for (f.hits.items.items) |h| if (h.target == .tab and h.target.tab.idx == idx) return true;
    return false;
}

test "an overflowing strip shows ‹ › markers with their buttons and keeps the + reachable; the window is clamped" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "one.txt", .dirty = false, .active = false },
        .{ .id = 2, .title = "two.txt", .dirty = false, .active = false },
        .{ .id = 3, .title = "three.txt", .dirty = false, .active = false },
        .{ .id = 4, .title = "four.txt", .dirty = false, .active = false },
        .{ .id = 5, .title = "five.txt", .dirty = false, .active = true },
    };
    // From the start: the ones that fit, then › and the +.
    const w0 = draw(f.ui(), f.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .first = 0 });
    try f.expectRow(0, " one.txt   two.txt   three.txt   ›  +");
    try testing.expectEqual(@as(usize, 0), w0.first);
    try testing.expectEqual(@as(usize, 2), w0.hidden_right);
    try testing.expect(hasButton(&f, 71)); // the › marker's scroll button
    try testing.expect(hasButton(&f, 77)); // the + is still reachable
    // The active tab is last: fitActive windows to it, ‹ marks the hidden ones.
    const first = fitActive(f.ui(), f.full(), &tabs, plus_w);
    try testing.expectEqual(@as(usize, 2), first);
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const w1 = draw(g.ui(), g.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .first = first });
    try g.expectRow(0, "‹  three.txt   four.txt   five.txt   +");
    try testing.expectEqual(@as(usize, 2), w1.hidden_left);
    try testing.expectEqual(@as(usize, 0), w1.hidden_right);
    try testing.expectEqual(@as(u32, 70), g.hits.at(0, 0).?.button); // the ‹ marker
    try testing.expect(hasButton(&g, 77)); // + still there
    try testing.expect(hasTab(&g, 4)); // five.txt (idx 4) visible
    // A window past the point where the rest fits is pulled back.
    var h = try Fixture.init(40, 1);
    defer h.deinit();
    const w2 = draw(h.ui(), h.full(), &tabs, .{ .new_tab = 77, .first = 4 });
    try testing.expectEqual(@as(usize, 2), w2.first);
    // Everything fits: no markers at all.
    var k = try Fixture.init(80, 1);
    defer k.deinit();
    const w3 = draw(k.ui(), k.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71 });
    try testing.expectEqual(@as(usize, 0), w3.hidden_right);
    try k.expectLacks("›");
    try k.expectLacks("‹");
}

test "tabs paint in order with the active style and a dirty dot, and register hits" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "a.txt", .dirty = false, .active = false },
        .{ .id = 2, .title = "b.txt", .dirty = true, .active = true },
        .{ .id = 3, .title = "c.txt", .dirty = false, .active = false },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{ .leaf = 3, .new_tab = 77 });
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
    _ = draw(f.ui(), f.full(), &tabs, .{});
    // The active tab is last, so the window starts past the first: `‹`.
    try f.expectRow(0, "‹  gamma");
    try testing.expectEqual(@as(u16, 2), f.hits.at(2, 0).?.tab.idx);
    try testing.expect(f.hits.at(9, 0) == null);

    var g = try Fixture.init(14, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = true },
        .{ .id = 2, .title = "beta", .dirty = false, .active = false },
    };
    _ = draw(g.ui(), g.full(), &two, .{});
    try g.expectRow(0, " alpha   beta");
    _ = draw(g.ui(), Rect.empty, &two, .{});
    _ = draw(g.ui(), g.full(), &.{}, .{ .new_tab = 1 });
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
    _ = draw(f.ui(), f.full(), &tabs, .{ .leaf = 1, .new_tab = 9 });
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
    _ = draw(f.ui(), f.full(), &tabs, .{});
    try f.expectRow(0, " a.txt   b.txt  |  zsh$ x");
    // An active pty on a narrow strip is still brought into view.
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = false },
        .{ .id = 5, .title = "sh", .dirty = false, .active = true, .kind = .pty },
    };
    _ = draw(g.ui(), g.full(), &two, .{});
    try g.expectRow(0, "‹  sh$ ×");
    try testing.expect(hasTab(&g, 1)); // the active pty tab (idx 1) shows
}
