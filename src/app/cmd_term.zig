//! `term.*` runners and the `:term` line: shells in the four halves,
//! a command in a pane, paste / clear / restart on the active pty.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const pty_pane = @import("pty_pane.zig");
const pty = @import("pty");

pub const table = .{
    .@"term.shell" = &shellRight,
    .@"term.shell_left" = &shellLeft,
    .@"term.shell_right" = &shellRight,
    .@"term.shell_top" = &shellTop,
    .@"term.shell_bottom" = &shellBottom,
    .@"term.focus_or_open_shell" = &focusOrOpen,
    .@"term.paste" = &pasteClipboard,
    .@"term.clear" = &clear,
    .@"term.restart" = &restart,
};

fn shell(app: *App, placement: pty_pane.Placement) CommandError!void {
    _ = try pty_pane.open(app, .{ .placement = placement, .kind = .shell });
}

fn shellRight(app: *App) CommandError!void {
    return shell(app, .right);
}
fn shellLeft(app: *App) CommandError!void {
    return shell(app, .left);
}
fn shellTop(app: *App) CommandError!void {
    return shell(app, .above);
}
fn shellBottom(app: *App) CommandError!void {
    return shell(app, .below);
}

/// The first live shell pane gets focus; none → a new one below.
fn focusOrOpen(app: *App) CommandError!void {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .pty => |*term| if (term.kind == .shell and term.exit == null) {
            app.showPane(@intCast(i));
            return;
        },
        else => {},
    };
    return shell(app, .below);
}

fn activePty(app: *App) CommandError!*pty_pane.PtyPane {
    const id = app.active orelse return error.NoActivePane;
    return app.panes.pty(id) orelse app.diag.fail(app.frame.allocator(), "not a terminal pane", .{});
}

fn pasteClipboard(app: *App) CommandError!void {
    const p = try activePty(app);
    const text = app.clipboard.text();
    if (text.len == 0) return app.diag.fail(app.frame.allocator(), "clipboard is empty", .{});
    try pty_pane.paste(app, p, text);
}

fn clear(app: *App) CommandError!void {
    const p = try activePty(app);
    p.write("\x0c");
}

fn restart(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    _ = app.panes.pty(id) orelse return app.diag.fail(app.frame.allocator(), "not a terminal pane", .{});
    try pty_pane.restart(app, id);
}

/// `:term` opens a shell below; `:term <cmd…>` runs the line through
/// the platform's shell (`sh -c`, `cmd /d /c`) with the line as the tab
/// label.
pub fn termEx(app: *App, args: []const u8) CommandError!void {
    const line = std.mem.trim(u8, args, " \t");
    if (line.len == 0) return shell(app, .below);
    var shell_buf: [4][]const u8 = undefined;
    _ = try pty_pane.open(app, .{
        .argv = pty.shellArgv(&shell_buf, &app.env, line),
        .label = line,
        .placement = .below,
        .kind = .command,
    });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "headless smoke: `:term printf hi` opens a pane below the editor and the grid shows hi" {
    // `printf` and a login shell: POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try app.runEx("term printf hi");
    const id = app.active.?;
    try t.expect(id != ed);
    try t.expectEqualStrings("printf hi", app.panes.get(id).?.title());
    // Two leaves: the scratch editor on top, the terminal below.
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
    try t.expect(try pty_pane.tickUntilScreen(&app, "hi", 5000));
    try t.expect(try pty_pane.tickUntilScreen(&app, "[exited 0]", 5000));
    // The buffers picker lists it with the [term] marker.
    try command.run(&app, .{ .static = .@"picker.buffers" });
    var seen = false;
    for (app.overlay.picker.labels) |l| if (std.mem.eql(u8, l, "printf hi [term]")) {
        seen = true;
    };
    try t.expect(seen);
}

test "term.shell opens the login shell beside the active pane; focus_or_open_shell finds it again" {
    // `printf` and a login shell: POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try command.run(&app, .{ .static = .@"term.shell" });
    const sh = app.active.?;
    try t.expect(sh != ed);
    try t.expect(app.panes.pty(sh).?.kind == .shell);
    app.showPane(ed);
    try command.run(&app, .{ .static = .@"term.focus_or_open_shell" });
    try t.expectEqual(sh, app.active.?);
    try t.expectEqual(@as(usize, 2), app.panes.count());
}
