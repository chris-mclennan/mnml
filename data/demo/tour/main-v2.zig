const std = @import("std");
const util = @import("util.zig");

/// The entry point: add a few numbers and print the total.
pub fn main() !void {
    // TODO: read the numbers from the command line.
    const numbers = [_]i64{ 1, 2, 3, 4, 5 };
    const total = util.sum(&numbers);
    std.debug.print("total: {d}\n", .{total});
    // FIXME: an empty list should print a friendlier message.
    if (total == 0) std.debug.print("nothing to add\n", .{});
}
