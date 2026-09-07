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

test {
    _ = std;
}
