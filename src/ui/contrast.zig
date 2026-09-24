//! WCAG 2 contrast, for the chrome roles a theme must keep legible: the
//! focus cue's dim and step-back (`focus_cue.zig`) and the needs-you
//! mark (`Theme.attention_fg`). A role is derived from the theme's own
//! colours — a blend toward the ground that stops at a floor, or the
//! first of a few palette hues that clears it — so a light theme gets
//! a cue it can see without a table of per-theme exceptions.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Color = vaxis.Color;

/// WCAG 2 relative luminance of an sRGB colour; null when it is not rgb
/// (an indexed or default colour has no fixed value to measure).
pub fn luminance(c: Color) ?f64 {
    if (c != .rgb) return null;
    var out: f64 = 0;
    const weights = [3]f64{ 0.2126, 0.7152, 0.0722 };
    for (c.rgb, weights) |ch, w| {
        const v = @as(f64, @floatFromInt(ch)) / 255.0;
        const lin = if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
        out += w * lin;
    }
    return out;
}

/// WCAG 2 contrast ratio, 1.0 (none) to 21.0; null when either colour
/// is not rgb.
pub fn ratio(a: Color, b: Color) ?f64 {
    const la = luminance(a) orelse return null;
    const lb = luminance(b) orelse return null;
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// `fg` over `bg` at `alpha` of 255, in rgb; null when either is not.
pub fn blend(fg: Color, bg: Color, alpha: u16) ?Color {
    if (fg != .rgb or bg != .rgb) return null;
    const inv = 255 - alpha;
    var out: [3]u8 = undefined;
    for (0..3) |i| out[i] = @intCast((@as(u16, fg.rgb[i]) * alpha + @as(u16, bg.rgb[i]) * inv) / 255);
    return .{ .rgb = out };
}

/// `fg` stepped back toward `ground` as far as `alpha` asks, but never
/// below `floor`:1 against the ground — the hue stays, only its weight
/// over the ground rises until it clears. A colour already under the
/// floor stays as it is (it cannot be made more visible by blending it
/// into its ground). Null when either is not rgb.
pub fn stepBack(fg: Color, ground: Color, alpha: u16, floor: f64) ?Color {
    const full = ratio(fg, ground) orelse return null;
    if (full <= floor) return fg;
    var a = alpha;
    while (a < 255) : (a += 1) {
        const c = blend(fg, ground, a).?;
        if (ratio(c, ground).? >= floor) return c;
    }
    return fg;
}

/// A dimmer twin of `fg` on `ground`: the least blend toward the ground
/// that sits `apart`:1 from `fg`, never below `floor`:1 against the
/// ground. When the floor comes first, the dimmest colour that still
/// clears it — the most the ground allows. Null when either is not rgb.
pub fn dimmer(fg: Color, ground: Color, apart: f64, floor: f64) ?Color {
    const full = ratio(fg, ground) orelse return null;
    if (full <= floor) return fg;
    var best = fg;
    var a: u16 = 255;
    while (a > 0) : (a -= 1) {
        const c = blend(fg, ground, a).?;
        if (ratio(c, ground).? < floor) break;
        best = c;
        if (ratio(c, fg).? >= apart) break;
    }
    return best;
}

/// The lowest contrast `c` has against any of `grounds` (null when a
/// colour is not rgb).
pub fn worst(c: Color, grounds: []const Color) ?f64 {
    var low: f64 = 21;
    for (grounds) |g| low = @min(low, ratio(c, g) orelse return null);
    return low;
}

/// The first of `hues` that clears `floor`:1 on every one of `grounds`;
/// when none does, the one that comes closest.
pub fn firstClearing(hues: []const Color, grounds: []const Color, floor: f64) Color {
    var best = hues[0];
    var best_ratio: f64 = 0;
    for (hues) |h| {
        const r = worst(h, grounds) orelse continue;
        if (r >= floor) return h;
        if (r > best_ratio) {
            best = h;
            best_ratio = r;
        }
    }
    return best;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn rgb(hex: u24) Color {
    return .{ .rgb = .{ @intCast((hex >> 16) & 0xff), @intCast((hex >> 8) & 0xff), @intCast(hex & 0xff) } };
}

test "ratio: black on white is 21, a colour on itself is 1, indexed colours have none" {
    try testing.expectApproxEqAbs(@as(f64, 21), ratio(rgb(0x000000), rgb(0xffffff)).?, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1), ratio(rgb(0x7287fd), rgb(0x7287fd)).?, 0.001);
    try testing.expect(ratio(.{ .index = 3 }, rgb(0)) == null);
}

test "stepBack keeps the hue and stops at the floor; dimmer separates but never sinks below it" {
    const ground = rgb(0xeff1f5); // catppuccin-latte's base
    const accent = rgb(0x1e66f5);
    const back = stepBack(accent, ground, 96, 2.0).?;
    try testing.expect(ratio(back, ground).? >= 2.0);
    try testing.expect(ratio(back, ground).? < ratio(accent, ground).?);
    // Blue stays the largest channel: the hue is the accent's.
    try testing.expect(back.rgb[2] >= back.rgb[0] and back.rgb[2] >= back.rgb[1]);
    const name = rgb(0x4c4f69);
    const dim = dimmer(name, ground, 1.6, 3.0).?;
    try testing.expect(ratio(dim, ground).? >= 3.0);
    try testing.expect(ratio(dim, name).? >= 1.6);
    // Under the floor already: left alone.
    try testing.expect(Color.eql(stepBack(rgb(0xdddddd), ground, 96, 2.0).?, rgb(0xdddddd)));
}

test "firstClearing takes the first hue over the floor on every ground, else the closest" {
    const light = [_]Color{ rgb(0xffffff), rgb(0xf2f2f2) };
    const yellow = rgb(0xe5c07b);
    const orange = rgb(0xd19a66);
    const red = rgb(0xb00020);
    try testing.expect(Color.eql(firstClearing(&.{ yellow, orange, red }, &light, 3.0), red));
    const dark = [_]Color{rgb(0x1e222a)};
    try testing.expect(Color.eql(firstClearing(&.{ yellow, orange, red }, &dark, 3.0), yellow));
    try testing.expect(Color.eql(firstClearing(&.{ yellow, orange }, &light, 30.0), orange));
}
