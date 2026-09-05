//! Pty panes: a shell running inside a ghostty-vt `Terminal`.
//!
//! Layout (each file is one concern):
//!   ring.zig           — SPSC byte ring between the reader thread and the UI thread
//!   common.zig         — `Notify` and `Exit`, what a backend hands the pane
//!   session_posix.zig  — openpty + fork + reader thread + pump/resize
//!   grid.zig           — read the Terminal's render state out into plain cells
//!
//! `session` is the backend; there is one today. The pane reaches the
//! session only through `Session`, `Options`, `Notify`, `Exit`.
const std = @import("std");
pub const vt = @import("ghostty-vt");
pub const ring = @import("ring.zig");
pub const Ring = ring.Ring;
pub const common = @import("common.zig");
pub const session = @import("session_posix.zig");
pub const Session = session.Session;
pub const grid = @import("grid.zig");
pub const Grid = grid.Grid;

test "ghostty-vt module is importable and prints" {
    var t: vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit(std.testing.allocator);
    try t.printString("hello, mnml");
    const s = try t.plainString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello, mnml", s);
}

test {
    std.testing.refAllDecls(@This());
}
