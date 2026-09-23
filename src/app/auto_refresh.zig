//! Auto-refresh per list panel. TODOS rescans on a save and on a
//! watcher event, NOTES / FINDINGS on an open / save / delete under
//! their directory, SESSIONS on a three-second cadence while shown —
//! each asks `on` first. `ui.auto_refresh_off` names the panels whose
//! automatic rescan is off; the `⟳` chip's right-click menu flips it
//! and persists the list. The chip's left click always rescans.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PanelId = app_mod.PanelId;
const command = @import("../core/command.zig");
const side = @import("side.zig");
const MenuItem = command.MenuItem;
const settings = @import("settings.zig");

pub const Set = std.EnumSet(PanelId);

/// `ui.auto_refresh_off` → the runtime set. Unknown names are skipped.
pub fn seed(app: *App) void {
    app.auto_refresh_off = Set.initEmpty();
    for (app.cfg.ui.auto_refresh_off) |name| {
        if (std.meta.stringToEnum(PanelId, name)) |p| app.auto_refresh_off.insert(p);
    }
}

/// Whether `panel` may rescan on its own.
pub fn on(app: *const App, panel: PanelId) bool {
    return !app.auto_refresh_off.contains(panel);
}

/// Flip `panel` and persist the list as `ui.auto_refresh_off`.
pub fn toggle(app: *App, panel: PanelId) Allocator.Error!void {
    app.auto_refresh_off.toggle(panel);
    const arena = app.frame.allocator();
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.auto_refresh_off.iterator();
    while (it.next()) |p| try names.append(arena, @tagName(p));
    _ = try settings.persist(app, .workspace, &.{ "ui", "auto_refresh_off" }, names.items);
    app.toast("{s}: auto-refresh {s}", .{ label(panel), if (on(app, panel)) "on" else "off" });
    app.needs_render = true;
}

fn label(panel: PanelId) []const u8 {
    return switch (panel) {
        .todos => "TODOS",
        .notes => "NOTES",
        .findings => "FINDINGS",
        .sessions => "SESSIONS",
        .git => "GIT",
        .diagnostics => "DIAGNOSTICS",
        .http => "HTTP",
        .outline => "OUTLINE",
        .debug => "DEBUG",
        .integrations => "INTEGRATIONS",
        .scripts => "SCRIPTS",
        .script => "SCRIPT SECTION",
        .search => "SEARCH",
        .jobs => "JOBS",
    };
}

fn refreshId(panel: PanelId) command.CommandId {
    return switch (panel) {
        .todos => .@"todos.refresh",
        .notes => .@"notes.refresh",
        .findings => .@"findings.refresh",
        .sessions => .@"sessions.refresh",
        .git => .@"git.refresh",
        .diagnostics => .@"lsp.diagnostics",
        .http => .@"http.refresh",
        .outline => .@"outline.show",
        .debug => .@"dap.run",
        .integrations => .@"integrations.refresh",
        .scripts => .@"script.reload",
        // A script section refreshes through its list, not a command.
        .script => .@"script.reload",
        .search => .@"search.refresh",
        // The JOBS list is live; there is nothing to refresh.
        .jobs => .@"jobs.show",
    };
}

/// The `⟳` chip's right-click: *Refresh now* and the auto-refresh
/// toggle (a ✓ when it is on), titled with the panel's name.
pub fn openRefreshMenu(app: *App, panel: PanelId, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(MenuItem, &.{
        .{ .label = "Refresh now", .action = .{ .command = refreshId(panel) } },
        .{ .label = "Auto-refresh", .action = .{ .toggle_auto_refresh = panel }, .checked = on(app, panel), .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu(label(panel), items, x, y);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const todos = @import("../todos.zig");
const sessions = @import("../sessions.zig");

test "auto-refresh: the config seeds the set; off stops the save-hook and the cadence rescans; the chip menu flips and persists it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var cfg: app_mod.Config = .{};
    cfg.ui.auto_refresh_off = &.{ "sessions", "nonsense" };
    var app = try App.initWith(testing.allocator, testing.io, .{ .cfg = cfg, .workspace = root, .cols = 80, .rows = 24 });
    defer app.deinit();
    try testing.expect(!on(&app, .sessions));
    try testing.expect(on(&app, .todos));
    // TODOS: a save rescans while on, not while off.
    app.todos.scanned_once = true;
    const gen = app.todos.generation;
    todos.onSavePost(&app, .{ .save_post = .{ .path = "x", .pane = 0, .bytes = 0 } });
    try testing.expect(app.todos.generation > gen);
    app.auto_refresh_off.insert(.todos);
    const gen2 = app.todos.generation;
    todos.onSavePost(&app, .{ .save_post = .{ .path = "x", .pane = 0, .bytes = 0 } });
    try testing.expectEqual(gen2, app.todos.generation);
    todos.noteFileChanged(&app);
    try testing.expect(app.todos.rescan_at_ms == null);
    // SESSIONS: the cadence is silent while off.
    side.place(&app, .sessions, false);
    app.sessions.scanned_once = true;
    app.sessions.last_scan_ms = 0;
    sessions.tick(&app, 100_000);
    try testing.expect(!app.sessions.scanning);
    // The chip menu: the toggle row flips it and writes the workspace config.
    try openRefreshMenu(&app, .todos, 5, 5);
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("TODOS", app.overlay.menu.title);
    try testing.expectEqual(@as(usize, 2), app.overlay.menu.items.len);
    try testing.expect(!app.overlay.menu.items[1].checked);
    const dispatch = @import("dispatch.zig");
    try dispatch.runMenuActionForTest(&app, app.overlay.menu.items[1].action);
    try testing.expect(on(&app, .todos));
    try testing.expectEqualStrings("TODOS: auto-refresh on", app.lastToast().?);
    const text = try tmp.dir.readFileAlloc(testing.io, ".mnml/config.zon", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".auto_refresh_off = .{\"sessions\"}") != null);
}
