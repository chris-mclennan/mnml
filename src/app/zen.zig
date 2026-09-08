//! Zen mode — the editor and nothing else. `view.fullscreen`
//! flips `App.zen`; `render.zig` then skips the palette bar, the tree,
//! the right panel, the tab strips and the statusline. The `:` line
//! stays (it is how a vim user leaves). The flag rides along in
//! `session.zon`, so quitting zoomed comes back zoomed.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const table = .{
    .@"view.fullscreen" = &toggle,
};

pub fn toggle(app: *App) CommandError!void {
    set(app, !app.zen);
    app.toast("zen {s}", .{if (app.zen) "on" else "off"});
}

pub fn set(app: *App, on: bool) void {
    app.zen = on;
    // Entering lands the keyboard on the pane so typing starts at once;
    // the tree and the panels are not painted, so they cannot hold it.
    if (on) {
        if (app.active) |a| app.focus = .{ .pane = a };
    }
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "zen: the frame drops the tree, the strip and the statusline; a second toggle brings them back" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    app.tree.visible = true;
    app.tree.loaded = true; // an empty listing: the test never touches /tmp
    try app.render();
    const screen = @import("../ipc/screen.zig");
    const before = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(before);
    try t.expect(std.mem.indexOf(u8, before, "[scratch]") != null); // the tab strip
    try t.expect(std.mem.indexOf(u8, before, "EDIT") != null); // the statusline's mode chip
    try t.expect(app.panes_area.x > 0); // the tree takes the left
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(app.zen);
    try t.expect(app.focus == .pane);
    try app.render();
    const zen = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(zen);
    try t.expect(std.mem.indexOf(u8, zen, "[scratch]") == null);
    try t.expect(std.mem.indexOf(u8, zen, "EDIT") == null);
    try t.expectEqual(@as(u16, 0), app.panes_area.x); // no tree
    try t.expectEqual(@as(u16, 100), app.panes_area.w);
    try t.expectEqual(@as(u16, 0), app.panes_area.y); // no palette bar
    try t.expectEqual(@as(u16, 23), app.panes_area.h); // only the `:` line is kept
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(!app.zen);
    try app.render();
    const after = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(after);
    try t.expect(std.mem.indexOf(u8, after, "EDIT") != null);
}
