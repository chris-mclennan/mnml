//! App state, grouped by subsystem (D7). Render-free. `*App` is the
//! parameter for commands and event handlers — components never see it.
//!
//! This is the minimal App the command registry needs; the pane store,
//! layout, focus, event handling and the loop land with the app spine.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const alloc = @import("core/alloc.zig");
const command = @import("core/command.zig");

pub const App = struct {
    gpa: Allocator,
    io: Io,
    frame: alloc.FrameArena,
    diag: command.Diag = .{},
    dyn_commands: command.DynRegistry,
    toasts: Toasts,
    quit: bool = false,

    pub fn init(gpa: Allocator, io: Io) Allocator.Error!App {
        return .{
            .gpa = gpa,
            .io = io,
            .frame = .init(gpa),
            .dyn_commands = .init(gpa),
            .toasts = .init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.toasts.deinit();
        self.dyn_commands.deinit();
        self.frame.deinit();
    }

    /// Queue a toast. Formatting failure drops the toast rather than the frame.
    pub fn toast(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.toasts.push(fmt, args) catch {};
    }

    /// An ex-command line (`:w`, `:e path`). The interpreter is a later
    /// phase; today every line is unsupported.
    pub fn runEx(self: *App, line: []const u8) command.CommandError!void {
        return self.diag.fail(self.frame.allocator(), "ex: `{s}` is not supported yet", .{line}); // TODO(ex): interpreter
    }

    /// An IPC-registered command was invoked: the host learns about it
    /// through events.jsonl. The IPC writer is a later phase.
    pub fn ackPluginCommand(self: *App, id: []const u8) command.CommandError!void {
        self.toast("plugin command: {s}", .{id}); // TODO(ipc): events.jsonl `plugin-command`
    }
};

/// Recent toasts, newest last, gpa-owned. Capped so a chatty worker
/// cannot grow memory without bound.
pub const Toasts = struct {
    gpa: Allocator,
    items: std.ArrayList([]u8) = .empty,
    pub const cap = 32;

    pub fn init(gpa: Allocator) Toasts {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Toasts) void {
        for (self.items.items) |s| self.gpa.free(s);
        self.items.deinit(self.gpa);
    }

    pub fn push(self: *Toasts, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(s);
        if (self.items.items.len >= cap) self.gpa.free(self.items.orderedRemove(0));
        try self.items.append(self.gpa, s);
    }

    pub fn last(self: *const Toasts) ?[]const u8 {
        return self.items.getLastOrNull();
    }
};

test "run: an unimplemented command toasts and fails; a bad name toasts" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try std.testing.expectError(error.Failed, command.run(&app, .{ .static = .@"app.quit" }));
    try std.testing.expectEqualStrings("app.quit: not implemented yet", app.toasts.last().?);
    try std.testing.expectError(error.Failed, command.runNamed(&app, "nope.nope"));
    try std.testing.expectEqualStrings("no such command: nope.nope", app.toasts.last().?);
    // A dyn command with an ex runner reaches runEx.
    _ = try app.dyn_commands.register(.{ .id = "user.hi", .runner = .{ .ex = "echo" }, .owner = .script });
    try std.testing.expectError(error.Failed, command.runNamed(&app, "user.hi"));
    try std.testing.expectEqualStrings("ex: `echo` is not supported yet", app.toasts.last().?);
}
