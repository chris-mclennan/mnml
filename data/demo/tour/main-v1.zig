const std = @import("std");
const util = @import("util.zig");

pub fn main() !void {
    const total = util.sum(&.{ 1, 2, 3, 4 });
    std.debug.print("total: {d}\n", .{total});
}
