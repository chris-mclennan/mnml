const std = @import("std");

/// The numbers on the command line, or null when one is not a number.
pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) !?[]i64 {
    const out = try gpa.alloc(i64, args.len);
    for (args, out) |a, *n| n.* = std.fmt.parseInt(i64, a, 10) catch {
        gpa.free(out);
        return null;
    };
    return out;
}
