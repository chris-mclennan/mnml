//! The Lua state (D10). Spike shape: opens the state, the safe libs, runs
//! a string. Grows into the budgeted call surface next.

const std = @import("std");
const zlua = @import("zlua");

pub const State = zlua.Lua;

pub fn spikeOpen(gpa: std.mem.Allocator) !*State {
    const L = try State.init(gpa);
    L.openBase();
    L.openString();
    L.openTable();
    L.openMath();
    L.openUtf8();
    return L;
}

test "spike: a Lua 5.4 state opens, runs a string, os/io are nil" {
    const L = try spikeOpen(std.testing.allocator);
    defer L.deinit();
    try L.doString("x = 1 + 2; assert(os == nil); assert(io == nil); assert(string.rep('a', 3) == 'aaa')");
    _ = L.getGlobal("x");
    try std.testing.expectEqual(@as(zlua.Integer, 3), try L.toInteger(-1));
    try std.testing.expectEqual(zlua.lang, .lua54);
}
