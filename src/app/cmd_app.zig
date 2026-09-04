//! `app.*` and `whichkey.*` runners: quitting behind the unsaved-changes
//! box, the restart handshake, and the leader menu.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const table = .{
    .@"app.quit" = &quit,
    .@"app.restart" = &restart,
    .@"whichkey.leader" = &leader,
};

/// Quit — or, with unsaved changes anywhere, the Save / Discard / Cancel
/// box (`close_prompt.test` is the spec for the box; `ConfirmPurpose.quit`
/// routes the choice).
fn quit(app: *App) CommandError!void {
    if (!app.anyDirty()) {
        app.quit = true;
        return;
    }
    var n: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.dirty()) {
        n += 1;
    };
    const msg = try std.fmt.allocPrint(app.gpa, "  {d} buffer(s) have unsaved changes.", .{n});
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Unsaved changes", .message = msg, .choices = &App.close_choices },
        .purpose = .quit,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Exit 75: the `run.sh` loop rebuilds and relaunches.
fn restart(app: *App) CommandError!void {
    app.restart = true;
    app.quit = true;
}

fn leader(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .which_key = .{} };
    app.focus = .overlay;
    app.needs_render = true;
}

test "app.quit sets quit when clean and asks first when a buffer is dirty" {
    const t = std.testing;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(app.quit);
    app.quit = false;
    const e = app.activeEditor().?;
    try e.buf.editor.setText("x");
    e.buf.dirty = true;
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(!app.quit);
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Unsaved changes", app.overlay.confirm.state.title);
    try t.expect(app.overlay.confirm.purpose == .quit);
    // Discard quits.
    try app.handle(.{ .key = app_mod.Key.char('d') });
    try t.expect(app.quit);
}
