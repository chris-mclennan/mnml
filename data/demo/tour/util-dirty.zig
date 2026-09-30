const std = @import("std");

/// Sum a slice of integers.
pub fn sum(xs: []const i64) i64 {
    var total: i64 = 0;
    for (xs) |x| total += x;
    return total;
}

test "sum adds" {
    try std.testing.expectEqual(@as(i64, 6), sum(&.{ 1, 2, 3 }));
}

/// The largest element, or null for an empty slice.
pub fn max(xs: []const i64) ?i64 {
    if (xs.len == 0) return null;
    var best = xs[0];
    for (xs[1..]) |x| best = @max(best, x);
    return best;
}
