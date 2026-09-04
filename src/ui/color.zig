//! Color helpers on top of `vaxis.Color`.
//!
//! vaxis emits rgb SGR for `.rgb` colors no matter what the terminal said,
//! and its `caps.rgb` never becomes true in 0.6.0. Truecolor detection is
//! therefore ours (see `tui/term.zig`), and when it says no, the Canvas
//! folds every rgb color onto the xterm 256-color cube here, at paint time.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Color = vaxis.Color;
pub const Style = vaxis.Style;

/// The six per-channel levels of the 6×6×6 cube (indices 16…231).
const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

fn nearestLevel(v: u8) u8 {
    var best: u8 = 0;
    var best_d: u16 = std.math.maxInt(u16);
    for (cube_levels, 0..) |lvl, i| {
        const d: u16 = @abs(@as(i16, v) - @as(i16, lvl));
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn dist2(a: [3]u8, b: [3]u8) u32 {
    var sum: u32 = 0;
    for (a, b) |x, y| {
        const d: i32 = @as(i32, x) - @as(i32, y);
        sum += @intCast(d * d);
    }
    return sum;
}

/// Nearest 256-color index for an rgb triple: the closer of the cube
/// candidate and the 24-step grayscale ramp (232…255).
pub fn rgbToIndex(rgb: [3]u8) u8 {
    const ri = nearestLevel(rgb[0]);
    const gi = nearestLevel(rgb[1]);
    const bi = nearestLevel(rgb[2]);
    const cube_rgb = [3]u8{ cube_levels[ri], cube_levels[gi], cube_levels[bi] };
    const cube_idx: u8 = 16 + 36 * ri + 6 * gi + bi;

    // Gray ramp: value = 8 + 10 * i for i in 0…23.
    const avg: i32 = @divTrunc(@as(i32, rgb[0]) + rgb[1] + rgb[2], 3);
    const gray_i: u8 = @intCast(std.math.clamp(@divTrunc(avg - 8 + 5, 10), 0, 23));
    const gray_v: u8 = @intCast(8 + 10 * @as(u16, gray_i));
    const gray_rgb = [3]u8{ gray_v, gray_v, gray_v };
    const gray_idx: u8 = 232 + gray_i;

    return if (dist2(rgb, gray_rgb) < dist2(rgb, cube_rgb)) gray_idx else cube_idx;
}

/// `.rgb` → `.index`; `.default` and `.index` pass through.
pub fn quantize(c: Color) Color {
    return switch (c) {
        .rgb => |rgb| .{ .index = rgbToIndex(rgb) },
        else => c,
    };
}

pub fn quantizeStyle(s: Style) Style {
    var out = s;
    out.fg = quantize(s.fg);
    out.bg = quantize(s.bg);
    out.ul = quantize(s.ul);
    return out;
}

test "cube corners and exact levels" {
    try std.testing.expectEqual(@as(u8, 16), rgbToIndex(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 231), rgbToIndex(.{ 255, 255, 255 }));
    try std.testing.expectEqual(@as(u8, 196), rgbToIndex(.{ 255, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 46), rgbToIndex(.{ 0, 255, 0 }));
    try std.testing.expectEqual(@as(u8, 21), rgbToIndex(.{ 0, 0, 255 }));
    // 16 + 36*1 + 6*2 + 3
    try std.testing.expectEqual(@as(u8, 67), rgbToIndex(.{ 95, 135, 175 }));
}

test "grays prefer the ramp when it is closer" {
    try std.testing.expectEqual(@as(u8, 244), rgbToIndex(.{ 128, 128, 128 })); // 8 + 10*12 = 128
    try std.testing.expectEqual(@as(u8, 232), rgbToIndex(.{ 8, 8, 8 }));
    try std.testing.expectEqual(@as(u8, 255), rgbToIndex(.{ 238, 238, 238 }));
    // Near-black: the cube's 0 is exact, the ramp starts at 8.
    try std.testing.expectEqual(@as(u8, 16), rgbToIndex(.{ 2, 2, 2 }));
    // A tinted gray stays on the cube.
    try std.testing.expectEqual(@as(u8, 137), rgbToIndex(.{ 175, 135, 95 })); // 16 + 36*3 + 6*2 + 1
}

test "quantize leaves default and index alone" {
    try std.testing.expect(quantize(.default) == .default);
    try std.testing.expectEqual(@as(u8, 7), quantize(.{ .index = 7 }).index);
    const s = quantizeStyle(.{
        .fg = .{ .rgb = .{ 255, 0, 0 } },
        .bg = .{ .index = 3 },
        .ul = .{ .rgb = .{ 0, 0, 0 } },
        .bold = true,
    });
    try std.testing.expectEqual(@as(u8, 196), s.fg.index);
    try std.testing.expectEqual(@as(u8, 3), s.bg.index);
    try std.testing.expectEqual(@as(u8, 16), s.ul.index);
    try std.testing.expect(s.bold);
}
