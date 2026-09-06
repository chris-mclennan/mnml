//! `tab.*` runners — vim's tab pages. Each page is one `Layout` (a split
//! tree); the pages live in `App.layouts`. Closing a page closes its
//! clean panes and re-homes the dirty ones into the page that takes
//! focus, so nothing with unsaved work drops out of every strip.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Layout = app_mod.Layout;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");

/// One `tab N/M` toast at a time: every page move replaces the last.
const tab_toast = "tab";

pub const table = .{
    .@"tab.new" = &tabNew,
    .@"tab.next" = &tabNext,
    .@"tab.prev" = &tabPrev,
    .@"tab.first" = &tabFirst,
    .@"tab.last" = &tabLast,
    .@"tab.close" = &tabClose,
    .@"tab.reopen" = &tabReopen,
    .@"tab.only" = &tabOnly,
    .@"tab.list" = &tabList,
    .@"tab.picker" = &tabPicker,
    .@"tab.move_left" = &tabMoveLeft,
    .@"tab.move_right" = &tabMoveRight,
    .@"tab.goto_1" = &goto1,
    .@"tab.goto_2" = &goto2,
    .@"tab.goto_3" = &goto3,
    .@"tab.goto_4" = &goto4,
    .@"tab.goto_5" = &goto5,
    .@"tab.goto_6" = &goto6,
    .@"tab.goto_7" = &goto7,
    .@"tab.goto_8" = &goto8,
    .@"tab.goto_9" = &goto9,
};

fn tabNew(app: *App) CommandError!void {
    const ls = &app.layouts;
    try ls.layouts.append(ls.gpa, Layout.init(ls.gpa));
    app.setActive(null);
    ls.active = ls.layouts.items.len - 1;
    _ = app.openScratch() catch return error.OutOfMemory;
    app.toastReplace(tab_toast, "tab {d}/{d}", .{ ls.active + 1, ls.layouts.items.len });
}

/// Show page `idx`; the page's first leaf's active pane takes focus.
pub fn switchTab(app: *App, idx: usize) void {
    const ls = &app.layouts;
    if (idx >= ls.layouts.items.len or idx == ls.active) return;
    app.setActive(null);
    ls.active = idx;
    const layout = ls.current();
    const first: ?PaneId = if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
    app.setActive(first);
    app.toastReplace(tab_toast, "tab {d}/{d}", .{ idx + 1, ls.layouts.items.len });
}

/// `{count}gt`: page `count`, or the last page when there are fewer
/// (`:help gt`); `{count}gT`: `count` pages back, wrapping.
pub fn gotoPage(app: *App, count: u32, back: bool) void {
    const n = app.layouts.layouts.items.len;
    if (n == 0 or count == 0) return;
    if (back) {
        const steps: usize = @intCast(count % n);
        switchTab(app, (app.layouts.active + n - steps) % n);
    } else switchTab(app, @min(@as(usize, count), n) - 1);
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

/// What `tab.reopen` needs of a page about to go: the files it showed,
/// in tab order, and which one was active. A page of nothing but
/// scratch buffers and terminals records nothing.
fn rememberPage(app: *App, gone: *Layout) CommandError!void {
    const arena = app.frame.allocator();
    const panes = try gone.allPanes(arena);
    const shown: ?PaneId = if (gone.firstLeaf()) |l| gone.leaf(l).?.active else null;
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (paths.items) |p| app.gpa.free(p);
        paths.deinit(app.gpa);
    }
    var active: usize = 0;
    for (panes) |id| {
        const p = app.panes.get(id) orelse continue;
        const path: []const u8 = switch (p.*) {
            .editor => |*e| e.buf.doc.path orelse continue,
            .md_preview => |*m| m.path,
            else => continue,
        };
        if (id == shown) active = paths.items.len;
        try paths.append(app.gpa, try app.gpa.dupe(u8, path));
    }
    if (paths.items.len == 0) return;
    if (app.closed_tabs.items.len >= App.max_closed_tabs) {
        var oldest = app.closed_tabs.orderedRemove(0);
        oldest.deinit(app.gpa);
    }
    try app.closed_tabs.append(app.gpa, .{ .paths = try paths.toOwnedSlice(app.gpa), .active = active });
}

/// `tab.reopen`: the last closed page comes back as a new page after
/// this one, its files as tabs of one leaf, the one that was active
/// focused. A file that went away is skipped.
fn tabReopen(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    var closed = app.closed_tabs.pop() orelse return app.diag.fail(arena, "no closed tab page to reopen", .{});
    defer closed.deinit(app.gpa);
    const ls = &app.layouts;
    try ls.layouts.insert(ls.gpa, ls.active + 1, Layout.init(ls.gpa));
    app.setActive(null);
    ls.active += 1;
    var focus: ?PaneId = null;
    var opened: usize = 0;
    for (closed.paths, 0..) |path, i| {
        const id = app.openPath(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        opened += 1;
        if (i == closed.active or focus == null) focus = id;
    }
    if (focus) |id| app.showPane(id) else _ = app.openScratch() catch return error.OutOfMemory;
    app.toastReplace(tab_toast, "tab reopened · {d}/{d} ({d} file{s})", .{ ls.active + 1, ls.layouts.items.len, opened, if (opened == 1) "" else "s" });
}

/// A page's panes when the page goes: clean ones close, dirty ones
/// become background tabs of `home` (the page that stays).
fn retirePage(app: *App, gone: *Layout, home: *Layout) CommandError!void {
    const arena = app.frame.allocator();
    try rememberPage(app, gone);
    const panes = try gone.allPanes(arena);
    for (panes) |id| {
        const p = app.panes.get(id) orelse continue;
        if (p.dirty()) {
            _ = home.showIn(home.firstLeaf(), id) catch {};
            if (home.firstLeaf()) |l| {
                const leaf = home.leaf(l).?;
                if (leaf.tabs.items.len > 1 and leaf.active == id) leaf.active = leaf.tabs.items[0];
            }
        } else {
            try app.forceClosePane(id);
        }
    }
}

/// Close the active page; the previous one takes focus.
fn tabClose(app: *App) CommandError!void {
    const ls = &app.layouts;
    if (ls.layouts.items.len < 2) {
        app.toast("only one tab page", .{});
        return;
    }
    app.setActive(null);
    var gone = ls.layouts.orderedRemove(ls.active);
    defer gone.deinit();
    ls.active = @min(ls.active -| 1, ls.layouts.items.len - 1);
    try retirePage(app, &gone, ls.current());
    const layout = ls.current();
    const first: ?PaneId = if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
    app.setActive(first);
    app.toastReplace(tab_toast, "tab {d}/{d}", .{ ls.active + 1, ls.layouts.items.len });
}

fn tabOnly(app: *App) CommandError!void {
    const ls = &app.layouts;
    const keep = app.active;
    var i: usize = 0;
    while (i < ls.layouts.items.len) {
        if (i == ls.active) {
            i += 1;
            continue;
        }
        var gone = ls.layouts.orderedRemove(i);
        defer gone.deinit();
        if (i < ls.active) ls.active -= 1;
        try retirePage(app, &gone, ls.current());
    }
    if (keep) |k| if (app.panes.get(k) != null) app.setActive(k);
    app.toastReplace(tab_toast, "tab 1/1", .{});
}

/// The page's name: its first leaf's active pane title.
pub fn pageTitle(app: *App, l: *Layout) []const u8 {
    const leaf = l.firstLeaf() orelse return "[empty]";
    const p = app.panes.get(l.leaf(leaf).?.active) orelse return "?";
    return p.title();
}

fn tabList(app: *App) CommandError!void {
    const ls = &app.layouts;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    const arena = app.frame.allocator();
    for (ls.layouts.items, 0..) |*l, i| {
        try parts.print(arena, "{s}{s}{d}:{s}", .{ if (i > 0) "  " else "", if (i == ls.active) "▸" else "", i + 1, pageTitle(app, l) });
    }
    app.toast(":tabs · {s}", .{parts.items});
}

/// `Switch tab page` — a picker over the pages; the pick switches.
fn tabPicker(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (app.layouts.layouts.items, 0..) |*l, i| {
        const n = try l.leaves(app.frame.allocator());
        const label = try std.fmt.allocPrint(gpa, "{d}: {s}{s} · {d} split{s}", .{ i + 1, pageTitle(app, l), if (i == app.layouts.active) " (current)" else "", n.len, if (n.len == 1) "" else "s" });
        errdefer gpa.free(label);
        try labels.append(gpa, label);
    }
    try cmd_picker.openPicker(app, "Switch tab page", .tabs, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn moveBy(app: *App, delta: i32) CommandError!void {
    const ls = &app.layouts;
    const n: i64 = @intCast(ls.layouts.items.len);
    const to_i = @as(i64, @intCast(ls.active)) + delta;
    if (to_i < 0 or to_i >= n or n < 2) return;
    const to: usize = @intCast(to_i);
    std.mem.swap(Layout, &ls.layouts.items[ls.active], &ls.layouts.items[to]);
    ls.active = to;
    app.toastReplace(tab_toast, "tab {d}/{d}", .{ to + 1, n });
    app.needs_render = true;
}

/// `:tabmove [N]` (`:help :tabmove`): the page goes after page N — N
/// counted with this page taken out — `0` makes it the first, no N the
/// last, `+N` / `-N` move it relative to where it is.
pub fn moveTo(app: *App, args: []const u8) CommandError!void {
    const ls = &app.layouts;
    const n = ls.layouts.items.len;
    const a = std.mem.trim(u8, args, " \t");
    if (a.len > 0 and (a[0] == '+' or a[0] == '-')) {
        const d = std.fmt.parseInt(i32, a, 10) catch return app.diag.fail(app.frame.allocator(), ":tabmove — not a number: {s}", .{a});
        return moveBy(app, d);
    }
    if (n < 2) return;
    var target: usize = n - 1;
    if (a.len > 0) target = std.fmt.parseInt(usize, a, 10) catch return app.diag.fail(app.frame.allocator(), ":tabmove — not a number: {s}", .{a});
    target = @min(target, n - 1);
    const cur = ls.active;
    if (target == cur) return;
    const page = ls.layouts.orderedRemove(cur);
    ls.layouts.insertAssumeCapacity(target, page);
    ls.active = target;
    app.toastReplace(tab_toast, "tab {d}/{d}", .{ target + 1, n });
    app.needs_render = true;
}

fn tabMoveLeft(app: *App) CommandError!void {
    return moveBy(app, -1);
}

fn tabMoveRight(app: *App) CommandError!void {
    return moveBy(app, 1);
}

/// `alt+N`: page N, or nothing when there is no such page.
fn gotoN(app: *App, n: usize) CommandError!void {
    if (n == 0 or n > app.layouts.layouts.items.len) return;
    switchTab(app, n - 1);
}

fn goto1(app: *App) CommandError!void {
    return gotoN(app, 1);
}
fn goto2(app: *App) CommandError!void {
    return gotoN(app, 2);
}
fn goto3(app: *App) CommandError!void {
    return gotoN(app, 3);
}
fn goto4(app: *App) CommandError!void {
    return gotoN(app, 4);
}
fn goto5(app: *App) CommandError!void {
    return gotoN(app, 5);
}
fn goto6(app: *App) CommandError!void {
    return gotoN(app, 6);
}
fn goto7(app: *App) CommandError!void {
    return gotoN(app, 7);
}
fn goto8(app: *App) CommandError!void {
    return gotoN(app, 8);
}
fn goto9(app: *App) CommandError!void {
    return gotoN(app, 9);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "page moves replace one `tab N/M` toast rather than stacking, and it expires" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"tab.new" });
    try command.run(&app, .{ .static = .@"tab.new" });
    try command.run(&app, .{ .static = .@"tab.prev" });
    try command.run(&app, .{ .static = .@"tab.prev" });
    try t.expectEqual(@as(usize, 1), app.toasts.items.len);
    try t.expectEqualStrings("tab 1/3", app.toasts.items[0].text);
    // An unrelated toast is not replaced by the next move.
    app.toast("hello", .{});
    try command.run(&app, .{ .static = .@"tab.next" });
    try t.expectEqual(@as(usize, 2), app.toasts.items.len);
    try t.expectEqualStrings("tab 2/3", app.toasts.items[1].text);
    try app.tick(app.now_ms + app_mod.toast_ttl_ms + 1);
    try t.expectEqual(@as(usize, 0), app.toasts.items.len);
}

test "gotoPage: a count names the page, past the end is the last page; back counts pages with wrap" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"tab.new" });
    const b = app.active.?;
    try command.run(&app, .{ .static = .@"tab.new" });
    const c = app.active.?;
    gotoPage(&app, 2, false);
    try t.expectEqual(b, app.active.?);
    gotoPage(&app, 9, false);
    try t.expectEqual(c, app.active.?);
    gotoPage(&app, 1, false);
    try t.expectEqual(a, app.active.?);
    // 2gT from page 1 wraps to page 2; 3gT is a full turn.
    gotoPage(&app, 2, true);
    try t.expectEqual(b, app.active.?);
    gotoPage(&app, 3, true);
    try t.expectEqual(b, app.active.?);
    gotoPage(&app, 1, true);
    try t.expectEqual(a, app.active.?);
}

test "tab pages: new / goto / move / close re-homes a dirty pane and closes a clean one" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"tab.new" });
    const b = app.active.?;
    try app.activeEditor().?.buf.editor.setText("dirty");
    app.activeEditor().?.buf.doc.dirty = true;
    try command.run(&app, .{ .static = .@"tab.new" });
    const c = app.active.?;
    try t.expectEqual(@as(usize, 3), app.layouts.layouts.items.len);
    try command.run(&app, .{ .static = .@"tab.goto_1" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"tab.goto_9" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"tab.move_right" });
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    try t.expectEqual(a, app.active.?);
    // Close page 2 (a's, now): a is clean → closed; b's page takes focus.
    try command.run(&app, .{ .static = .@"tab.close" });
    try t.expect(app.panes.get(a) == null);
    try t.expectEqual(b, app.active.?);
    // `only` from c's page: b is dirty → re-homed as a background tab of c's leaf.
    try command.run(&app, .{ .static = .@"tab.last" });
    try t.expectEqual(c, app.active.?);
    try command.run(&app, .{ .static = .@"tab.only" });
    try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
    try t.expectEqual(c, app.active.?);
    try t.expect(app.panes.get(b) != null);
    try t.expectEqual(@as(usize, 2), app.layouts.current().leaf(app.layouts.current().leafOf(c).?).?.tabs.items.len);
    try command.run(&app, .{ .static = .@"tab.picker" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(app_mod.PickerKind.tabs, app.overlay.picker.kind);
}

test "tab.reopen brings a closed page's files back as a new page after this one, the active one focused; nothing left toasts" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"tab.new" });
    var ids: [2]PaneId = undefined;
    for ([_][]const u8{ "a.txt", "b.txt" }, 0..) |name, i| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        ids[i] = try app.openPath(path);
    }
    app.showPane(ids[0]);
    try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
    try command.run(&app, .{ .static = .@"tab.close" });
    try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 1), app.closed_tabs.items.len);
    try t.expectEqual(@as(usize, 0), app.closed_tabs.items[0].active);
    try command.run(&app, .{ .static = .@"tab.reopen" });
    try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
    try t.expectEqual(@as(usize, 1), app.layouts.active);
    try t.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 2), layout.leaf(layout.leafOf(app.active.?).?).?.tabs.items.len);
    try t.expectEqual(@as(usize, 0), app.closed_tabs.items.len);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"tab.reopen" }));
}
