const std = @import("std");
const Io = std.Io;

pub const version = "0.3.0-dev";

pub fn main() !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buf: [128]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), io, &out_buf);
    try out.interface.print("mnml-zig {s}\n", .{version});
    try out.interface.flush();
}

test {
    _ = @import("core/alloc.zig");
    _ = @import("core/key.zig");
    _ = @import("core/event.zig");
    _ = @import("commands/specs.zig");
    _ = @import("core/keymap.zig");
    _ = @import("core/command.zig");
    _ = @import("core/panel.zig");
    _ = @import("core/hooks.zig");
    _ = @import("app.zig");
    _ = @import("editor/edit_op.zig");
    _ = @import("editor/clipboard.zig");
    _ = @import("editor/editor.zig");
    _ = @import("editor/undo.zig");
    _ = @import("editor/motion.zig");
    _ = @import("editor/insert.zig");
    _ = @import("editor/delete.zig");
    _ = @import("editor/select.zig");
    _ = @import("editor/line.zig");
    _ = @import("editor/register.zig");
    _ = @import("editor/apply.zig");
    _ = @import("editor/buffer.zig");
    _ = @import("input/mod.zig");
    _ = @import("input/standard.zig");
    _ = @import("input/vim.zig");
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}
