//! `view.*` and `tab.*` runners: wrap and gutter toggles, splits and
//! split focus, viewport scrolling, and tab pages.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Layout = app_mod.Layout;
const layout_mod = @import("layout.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Rect = @import("../ui/rect.zig");

pub const table = .{
    .@"view.toggle_wrap" = &toggleWrap,
    .@"view.toggle_line_numbers" = &toggleLineNumbers,
    .@"view.split_right" = &splitRight,
    .@"view.split_down" = &splitDown,
    .@"view.focus_left" = &focusLeft,
    .@"view.focus_right" = &focusRight,
    .@"view.focus_up" = &focusUp,
    .@"view.focus_down" = &focusDown,
    .@"view.focus_next_split" = &focusNextSplit,
    .@"view.close_split" = &closeSplit,
    .@"view.close_others" = &closeOthers,
    .@"view.focus_pane" = &focusPane,
    .@"view.cursor_to_center" = &cursorToCenter,
    .@"view.cursor_to_top" = &cursorToTop,
    .@"view.cursor_to_bottom" = &cursorToBottom,
    .@"view.scroll_buffer_down" = &scrollDown,
    .@"view.scroll_buffer_up" = &scrollUp,
    .@"view.redraw" = &redraw,
    .@"tab.new" = &tabNew,
    .@"tab.next" = &tabNext,
    .@"tab.prev" = &tabPrev,
    .@"tab.first" = &tabFirst,
    .@"tab.last" = &tabLast,
    .@"tab.close" = &tabClose,
    .@"tab.only" = &tabOnly,
    .@"tab.list" = &tabList,
};

fn toggleWrap(app: *App) CommandError!void {
    if (app.activeEditor()) |e| {
        const on = !(e.wrap orelse app.cfg.wrap);
        e.wrap = on;
        app.toast("wrap {s}", .{if (on) "on" else "off"});
    } else {
        app.cfg.wrap = !app.cfg.wrap;
        app.toast("wrap {s}", .{if (app.cfg.wrap) "on" else "off"});
    }
    app.needs_render = true;
}

fn toggleLineNumbers(app: *App) CommandError!void {
    app.cfg.line_numbers = !app.cfg.line_numbers;
    app.toast("line numbers {s}", .{if (app.cfg.line_numbers) "on" else "off"});
    app.needs_render = true;
}

fn redraw(app: *App) CommandError!void {
    app.needs_render = true;
}

// ─── splits ─────────────────────────────────────────────────────────────

/// A new leaf beside the active one, showing a fresh scratch buffer.
fn split(app: *App, dir: layout_mod.SplitDir) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    if (layout.leafOf(cur) == null) return error.NoActivePane;
    const gpa = app.gpa;
    var buf = app_mod.Buffer.init(gpa, "", app.cfg.input_style, app.cfg.editorConfig()) catch return error.OutOfMemory;
    errdefer buf.deinit();
    const id = try app.panes.add(.{ .editor = .{ .buf = buf, .find = app_mod.FindState.init(gpa), .syntax = @import("syntax.zig").Syntax.init(gpa) } });
    _ = try layout.split(cur, dir, id);
    app.setActive(id);
}

fn splitRight(app: *App) CommandError!void {
    return split(app, .horizontal);
}

fn splitDown(app: *App) CommandError!void {
    return split(app, .vertical);
}

const Dir = enum { left, right, up, down };

/// The leaf whose rect is the nearest neighbour of the active one in
/// `dir`, by the rects the body area would get.
fn focusDir(app: *App, dir: Dir) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const arena = app.frame.allocator();
    const body = Rect.init(0, 1, app.screen.width, app.screen.height -| 2);
    const rects = try layout.computeRects(body, arena);
    var mine: ?Rect = null;
    for (rects.panes) |pr| if (pr.pane == cur) {
        mine = pr.rect;
    };
    const m = mine orelse return;
    var best: ?layout_mod.PaneRect = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (rects.panes) |pr| {
        if (pr.pane == cur) continue;
        const r = pr.rect;
        const ok = switch (dir) {
            .left => r.right() <= m.x and overlaps(r.y, r.bottom(), m.y, m.bottom()),
            .right => r.x >= m.right() and overlaps(r.y, r.bottom(), m.y, m.bottom()),
            .up => r.bottom() <= m.y and overlaps(r.x, r.right(), m.x, m.right()),
            .down => r.y >= m.bottom() and overlaps(r.x, r.right(), m.x, m.right()),
        };
        if (!ok) continue;
        const d: u32 = switch (dir) {
            .left => m.x - r.right(),
            .right => r.x - m.right(),
            .up => m.y - r.bottom(),
            .down => r.y - m.bottom(),
        };
        if (d < best_d) {
            best_d = d;
            best = pr;
        }
    }
    const target = best orelse return;
    app.setActive(target.pane);
}

fn overlaps(a0: u16, a1: u16, b0: u16, b1: u16) bool {
    return a0 < b1 and b0 < a1;
}

fn focusLeft(app: *App) CommandError!void {
    return focusDir(app, .left);
}
fn focusRight(app: *App) CommandError!void {
    return focusDir(app, .right);
}
fn focusUp(app: *App) CommandError!void {
    return focusDir(app, .up);
}
fn focusDown(app: *App) CommandError!void {
    return focusDir(app, .down);
}

fn focusNextSplit(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len < 2) return;
    const mine = layout.leafOf(cur) orelse return;
    const idx = std.mem.indexOfScalar(layout_mod.NodeId, leaves, mine) orelse return;
    const next = leaves[(idx + 1) % leaves.len];
    app.setActive(layout.leaf(next).?.active);
}

/// Drop the active leaf; its tabs stay open in the background.
fn closeSplit(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len < 2) {
        app.toast("only one split", .{});
        return;
    }
    const mine = layout.leafOf(cur) orelse return;
    const tabs = try app.frame.allocator().dupe(PaneId, layout.leaf(mine).?.tabs.items);
    for (tabs) |tab| _ = layout.removePane(tab);
    const first = layout.firstLeaf() orelse return;
    app.setActive(layout.leaf(first).?.active);
}

/// Every other pane goes (dirty ones stay, with a toast).
fn closeOthers(app: *App) CommandError!void {
    const keep = app.active orelse return error.NoActivePane;
    var ids: std.ArrayListUnmanaged(PaneId) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.* != null and i != keep) try ids.append(app.frame.allocator(), @intCast(i));
    var skipped: usize = 0;
    for (ids.items) |id| {
        const p = app.panes.get(id) orelse continue;
        if (p.dirty()) {
            skipped += 1;
            continue;
        }
        try app.forceClosePane(id);
    }
    if (skipped > 0) app.toast("kept {d} buffer(s) with unsaved changes", .{skipped});
}

fn focusPane(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    app.focus = .{ .pane = id };
    app.needs_render = true;
}

// ─── viewport ───────────────────────────────────────────────────────────

fn cursorTo(app: *App, where: enum { center, top, bottom }) CommandError!void {
    const e = try app.requireEditor();
    const row = e.buf.editor.currentLine();
    const rows = @max(app.pane_rows, 1);
    e.view.scroll_line = @intCast(switch (where) {
        .top => row,
        .center => row -| rows / 2,
        .bottom => row -| (rows - 1),
    });
    app.needs_render = true;
}

fn cursorToCenter(app: *App) CommandError!void {
    return cursorTo(app, .center);
}
fn cursorToTop(app: *App) CommandError!void {
    return cursorTo(app, .top);
}
fn cursorToBottom(app: *App) CommandError!void {
    return cursorTo(app, .bottom);
}

fn scrollBy(app: *App, delta: i32) CommandError!void {
    const e = try app.requireEditor();
    const max: i64 = @intCast(e.buf.editor.lineCount() -| 1);
    const cur: i64 = e.view.scroll_line;
    e.view.scroll_line = @intCast(std.math.clamp(cur + delta, 0, max));
    // Keep the cursor inside the window so the view does not snap back.
    const row = e.buf.editor.currentLine();
    const top: usize = e.view.scroll_line;
    const bottom = top + @max(app.pane_rows, 1) - 1;
    if (row < top) e.buf.editor.placeCursor(top, e.buf.editor.goalCol());
    if (row > bottom) e.buf.editor.placeCursor(@min(bottom, e.buf.editor.lineCount() - 1), e.buf.editor.goalCol());
    app.needs_render = true;
}

fn scrollDown(app: *App) CommandError!void {
    return scrollBy(app, 1);
}
fn scrollUp(app: *App) CommandError!void {
    return scrollBy(app, -1);
}

// ─── tab pages ──────────────────────────────────────────────────────────

fn tabNew(app: *App) CommandError!void {
    const ls = &app.layouts;
    try ls.layouts.append(ls.gpa, Layout.init(ls.gpa));
    app.setActive(null);
    ls.active = ls.layouts.items.len - 1;
    _ = app.openScratch() catch return error.OutOfMemory;
    app.toast("tab {d}/{d}", .{ ls.active + 1, ls.layouts.items.len });
}

fn switchTab(app: *App, idx: usize) void {
    const ls = &app.layouts;
    if (idx >= ls.layouts.items.len or idx == ls.active) return;
    app.setActive(null);
    ls.active = idx;
    const layout = ls.current();
    const first: ?PaneId = if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
    app.setActive(first);
    app.toast("tab {d}/{d}", .{ idx + 1, ls.layouts.items.len });
}

fn tabNext(app: *App) CommandError!void {
    const n = app.layouts.layouts.items.len;
    switchTab(app, (app.layouts.active + 1) % n);
}

fn tabPrev(app: *App) CommandError!void {
    const n = app.layouts.layouts.items.len;
    switchTab(app, (app.layouts.active + n - 1) % n);
}

fn tabFirst(app: *App) CommandError!void {
    switchTab(app, 0);
}

fn tabLast(app: *App) CommandError!void {
    switchTab(app, app.layouts.layouts.items.len - 1);
}

/// Close the active tab page; its panes stay open in the background.
fn tabClose(app: *App) CommandError!void {
    const ls = &app.layouts;
    if (ls.layouts.items.len < 2) {
        app.toast("only one tab page", .{});
        return;
    }
    app.setActive(null);
    var gone = ls.layouts.orderedRemove(ls.active);
    gone.deinit();
    if (ls.active >= ls.layouts.items.len) ls.active = ls.layouts.items.len - 1;
    const layout = ls.current();
    const first: ?PaneId = if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
    app.setActive(first);
    app.toast("tab {d}/{d}", .{ ls.active + 1, ls.layouts.items.len });
}

fn tabOnly(app: *App) CommandError!void {
    const ls = &app.layouts;
    var i: usize = 0;
    while (i < ls.layouts.items.len) {
        if (i == ls.active) {
            i += 1;
            continue;
        }
        var gone = ls.layouts.orderedRemove(i);
        gone.deinit();
        if (i < ls.active) ls.active -= 1;
    }
    app.toast("tab 1/1", .{});
}

fn tabList(app: *App) CommandError!void {
    const ls = &app.layouts;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    const arena = app.frame.allocator();
    for (ls.layouts.items, 0..) |*l, i| {
        const title: []const u8 = if (l.firstLeaf()) |leaf| (if (app.panes.get(l.leaf(leaf).?.active)) |p| p.title() else "?") else "[empty]";
        try parts.print(arena, "{s}{s}{d}:{s}", .{ if (i > 0) "  " else "", if (i == ls.active) "▸" else "", i + 1, title });
    }
    app.toast(":tabs · {s}", .{parts.items});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "wrap toggles per pane; splits add leaves; focus moves between them; tabs cycle" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(true, app.activeEditor().?.wrap.?);
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(false, app.activeEditor().?.wrap.?);

    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try t.expect(a != b);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_right" });
    try t.expectEqual(b, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.split_down" });
    const c = app.active.?;
    try command.run(&app, .{ .static = .@"view.focus_up" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_down" });
    try t.expectEqual(c, app.active.?);
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    try t.expectEqual(@as(usize, 3), app.panes.count());

    try command.run(&app, .{ .static = .@"tab.new" });
    try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    try command.run(&app, .{ .static = .@"tab.prev" });
    try t.expectEqual(@as(usize, 0), app.layouts.active);
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"tab.next" });
    try command.run(&app, .{ .static = .@"tab.close" });
    try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
    try t.expectEqual(a, app.active.?);
}
