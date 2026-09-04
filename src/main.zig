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
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}
