//! Pty panes: a login shell running inside a ghostty-vt `Terminal`.
//!
//! Layout (each file is one concern):
//!   ring.zig     — SPSC byte ring between the reader thread and the UI thread
//!   session.zig  — openpty + child process + reader thread + pump/resize
//!   grid.zig     — read the Terminal's render state out into plain cells
const std = @import("std");
pub const vt = @import("ghostty-vt");

test "ghostty-vt module is importable and prints" {
    var t: vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit(std.testing.allocator);
    try t.printString("hello, mnml");
    const s = try t.plainString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello, mnml", s);
}
