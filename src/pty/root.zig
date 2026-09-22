//! Pty panes: a shell running inside a ghostty-vt `Terminal`.
//!
//! Layout (each file is one concern):
//!   ring.zig             — SPSC byte ring between the reader thread and the UI thread
//!   common.zig           — `Notify`, `Exit` and `SpinLock`, shared by both backends
//!   outbox.zig           — the queue the UI thread writes the child's input into
//!   session_posix.zig    — openpty + fork + reader thread + pump/resize
//!   session_windows.zig  — ConPTY + CreateProcessW + reader/watcher threads
//!   win_cmdline.zig      — the Windows session's host-neutral, tested pieces
//!   grid.zig             — read the Terminal's render state out into plain cells
//!
//! `session` is picked at comptime by the target OS; both backends export
//! the same `Session`, `Options`, `Notify`, `Exit`, so the pane never
//! branches on the platform.
const std = @import("std");
const builtin = @import("builtin");
pub const vt = @import("ghostty-vt");
pub const ring = @import("ring.zig");
pub const Ring = ring.Ring;
pub const common = @import("common.zig");
pub const outbox = @import("outbox.zig");
pub const win_cmdline = @import("win_cmdline.zig");
pub const is_windows = builtin.os.tag == .windows;
pub const session = if (is_windows) @import("session_windows.zig") else @import("session_posix.zig");
pub const Session = session.Session;
pub const grid = @import("grid.zig");
pub const Grid = grid.Grid;

/// `line` as an argv the platform's shell runs and exits: `sh -c` on
/// POSIX, `%COMSPEC% /d /c` on Windows (`/d` skips AutoRun, as a
/// non-interactive shell should). Fills `buf`; the returned slice
/// borrows `line`, `buf` and `env`.
pub fn shellArgv(buf: *[4][]const u8, env: *const std.process.Environ.Map, line: []const u8) []const []const u8 {
    if (is_windows) {
        buf.* = .{ win_cmdline.defaultShell(env), "/d", "/c", line };
        return buf[0..4];
    }
    buf.* = .{ "/bin/sh", "-c", line, "" };
    return buf[0..3];
}

test "ghostty-vt module is importable and prints" {
    var t: vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit(std.testing.allocator);
    try t.printString("hello, mnml");
    const s = try t.plainString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello, mnml", s);
}

test "the backend follows the target: POSIX here, ConPTY on Windows" {
    if (is_windows) {
        try std.testing.expect(session == @import("session_windows.zig"));
    } else {
        try std.testing.expect(session == @import("session_posix.zig"));
    }
    // Whichever it is, the pane's view of it is the shared one.
    try std.testing.expect(session.Exit == common.Exit);
    try std.testing.expect(session.Notify == common.Notify);
    try std.testing.expect(@hasDecl(session.Session, "spawn"));
    try std.testing.expect(@hasDecl(session.Session, "pump"));
    try std.testing.expect(@hasDecl(session.Session, "write"));
    try std.testing.expect(@hasDecl(session.Session, "resize"));
    try std.testing.expect(@hasDecl(session.Session, "exited"));
    try std.testing.expect(@hasDecl(session.Session, "eof"));
    try std.testing.expect(@hasDecl(session.Session, "terminal"));
    try std.testing.expect(@hasDecl(session.Session, "deinit"));
}

test "shellArgv: sh -c on POSIX, COMSPEC /d /c on Windows" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("COMSPEC", "C:\\Windows\\system32\\cmd.exe");
    var buf: [4][]const u8 = undefined;
    const argv = shellArgv(&buf, &env, "echo hi");
    if (is_windows) {
        try std.testing.expectEqual(@as(usize, 4), argv.len);
        try std.testing.expectEqualStrings("C:\\Windows\\system32\\cmd.exe", argv[0]);
        try std.testing.expectEqualStrings("/d", argv[1]);
        try std.testing.expectEqualStrings("/c", argv[2]);
    } else {
        try std.testing.expectEqual(@as(usize, 3), argv.len);
        try std.testing.expectEqualStrings("/bin/sh", argv[0]);
        try std.testing.expectEqualStrings("-c", argv[1]);
    }
    try std.testing.expectEqualStrings("echo hi", argv[argv.len - 1]);
}

test {
    std.testing.refAllDecls(@This());
    // The host-neutral half of the Windows backend runs everywhere.
    std.testing.refAllDecls(win_cmdline);
}
