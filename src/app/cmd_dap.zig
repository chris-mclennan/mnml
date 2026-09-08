//! The `dap.*` runners: thin, one line each, over `app/dap.zig`.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const dap = @import("dap.zig");

pub const table = .{
    .@"dap.toggle_breakpoint" = &dap.toggleBreakpoint,
    .@"dap.clear_all_breakpoints" = &dap.clearAllBreakpoints,
    .@"dap.list_breakpoints" = &dap.listBreakpoints,
    .@"dap.toggle_breakpoint_conditional" = &dap.conditionPrompt,
    .@"dap.set_breakpoint_hit_count" = &dap.hitCountPrompt,
    .@"dap.set_breakpoint_log_message" = &dap.logMessagePrompt,
    .@"dap.toggle_breakpoint_enabled" = &dap.toggleEnabled,
    .@"dap.remove_breakpoint" = &dap.removeBreakpoint,
    .@"dap.restart" = &dap.restart,
    .@"dap.evaluate_hover" = &dap.evaluateHover,
    .@"dap.clear_console" = &dap.clearConsole,
    .@"dap.run" = &dap.run,
    .@"dotnet.debug" = &dap.dotnetDebug,
    .@"dap.attach" = &attach,
    .@"dap.continue" = &cont,
    .@"dap.next" = &next,
    .@"dap.step_in" = &stepIn,
    .@"dap.step_out" = &stepOut,
    .@"dap.pause" = &pause,
    .@"dap.step_back" = &stepBack,
    .@"dap.reverse_continue" = &reverseContinue,
    .@"dap.terminate" = &dap.terminate,
    .@"dap.show" = &dap.showDebug,
    .@"dap.repl" = &dap.openRepl,
    .@"dap.add_watch" = &dap.addWatchPrompt,
    .@"dap.remove_watch" = &dap.removeWatchPicker,
    .@"dap.clear_watches" = &dap.clearWatches,
    .@"dap.set_variable" = &setVariable,
    .@"dap.exceptions" = &dap.exceptionsPicker,
    .@"dap.pick_thread" = &dap.threadPicker,
};

fn cont(app: *App) CommandError!void {
    return dap.threadCommand(app, .@"continue", "continue");
}

fn next(app: *App) CommandError!void {
    return dap.threadCommand(app, .next, "next");
}

fn stepIn(app: *App) CommandError!void {
    return dap.threadCommand(app, .step_in, "stepIn");
}

fn stepOut(app: *App) CommandError!void {
    return dap.threadCommand(app, .step_out, "stepOut");
}

fn pause(app: *App) CommandError!void {
    return dap.threadCommand(app, .pause, "pause");
}

/// Reverse debugging: the adapter answers with a failure when it cannot.
fn stepBack(app: *App) CommandError!void {
    return dap.threadCommand(app, .step_back, "stepBack");
}

fn reverseContinue(app: *App) CommandError!void {
    return dap.threadCommand(app, .reverse_continue, "reverseContinue");
}

fn setVariable(app: *App) CommandError!void {
    return dap.setVariablePrompt(app);
}

/// Attaching is a launch body with `.request = "attach"` and the
/// adapter's own pid / port keys; there is no process picker here.
fn attach(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "dap.attach: set `.request = \"attach\"` (and the adapter's pid/port keys) in .dap.<lang>.launch, then dap.run", .{});
}

/// The two profiles' doors, pinned (`docs/KEYMAP_PROFILES.md` → Debugger).
const Door = struct { id: []const u8, vim: ?[]const u8, both: ?[]const u8 };
const doors = [_]Door{
    .{ .id = "dap.toggle_breakpoint", .vim = "space d b", .both = "f9" },
    .{ .id = "dap.toggle_breakpoint_conditional", .vim = "space d B", .both = "shift+f9" },
    .{ .id = "dap.set_breakpoint_log_message", .vim = "space d l", .both = null },
    .{ .id = "dap.run", .vim = null, .both = "f5" },
    .{ .id = "dap.continue", .vim = "space d c", .both = "shift+f5" },
    .{ .id = "dap.next", .vim = "space d o", .both = "f10" },
    .{ .id = "dap.step_in", .vim = "space d i", .both = "f11" },
    .{ .id = "dap.step_out", .vim = "space d O", .both = "shift+f11" },
    .{ .id = "dap.pause", .vim = "space d p", .both = null },
    .{ .id = "dap.restart", .vim = "space d R", .both = null },
    .{ .id = "dap.terminate", .vim = "space d t", .both = null },
    .{ .id = "dap.repl", .vim = "space d r", .both = null },
    .{ .id = "dap.add_watch", .vim = "space d w", .both = null },
    .{ .id = "dap.toggle_panel", .vim = "space d u", .both = null },
    .{ .id = "dap.evaluate_hover", .vim = "space d h", .both = null },
    .{ .id = "view.activity_debug", .vim = null, .both = "ctrl+shift+d" },
};

test "both key profiles: the vim leader chords and the F-keys, pinned; no dap chord is standard-only" {
    const specs = @import("../commands/specs.zig").specs;
    for (doors) |d| {
        var found = false;
        for (specs) |s| if (std.mem.eql(u8, s.id, d.id)) {
            found = true;
            try std.testing.expectEqual(@as(usize, if (d.vim != null) 1 else 0), s.keys.vim.len);
            if (d.vim) |v| try std.testing.expectEqualStrings(v, s.keys.vim[0]);
            try std.testing.expectEqual(@as(usize, if (d.both != null) 1 else 0), s.keys.both.len);
            if (d.both) |b| try std.testing.expectEqualStrings(b, s.keys.both[0]);
            try std.testing.expectEqual(@as(usize, 0), s.keys.standard.len);
        };
        try std.testing.expect(found);
    }
    // Every vim chord is a leaf of the which-key +debug group too.
    const whichkey = @import("whichkey.zig");
    for (doors) |d| if (d.vim) |v| {
        // `space d b` → the tree path `db`.
        var path: [whichkey.max_depth]u8 = undefined;
        var n: usize = 0;
        for (v[6..]) |c| if (c != ' ') {
            path[n] = c;
            n += 1;
        };
        const node = whichkey.lookup(path[0..n]).?;
        try std.testing.expectEqualStrings(d.id, @tagName(node.cmd.id));
    };
}
