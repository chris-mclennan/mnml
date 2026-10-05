//! Sixel (DEC) — the protocol for the terminals the other two miss
//! (foot, mlterm, xterm built with it). Lower fidelity: the image is
//! decoded (zigimg, through vaxis), scaled to the cell box, quantised
//! to the 6×6×6 web cube (216 colours), and written band by band as
//! run-length-encoded sixel characters.
//!
//! The decoder lives here too — `transcodePng` is what the PNG-only
//! transports (kitty `f=100`) use for a JPEG / GIF / BMP source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigimg = @import("vaxis").zigimg;

pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

pub const Pixels = struct {
    w: u32,
    h: u32,
    /// Row-major, `w * h` long.
    px: []Rgba,

    pub fn deinit(self: *Pixels, gpa: Allocator) void {
        gpa.free(self.px);
    }

    pub fn at(self: *const Pixels, x: u32, y: u32) Rgba {
        return self.px[@as(usize, y) * self.w + x];
    }
};

pub const DecodeError = error{ OutOfMemory, Undecodable };

/// Any format zigimg reads → RGBA8.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Pixels {
    var img = zigimg.Image.fromMemory(gpa, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Undecodable,
    };
    defer img.deinit(gpa);
    if (img.width == 0 or img.height == 0) return error.Undecodable;
    const px = try gpa.alloc(Rgba, img.width * img.height);
    errdefer gpa.free(px);
    var it = img.iterator();
    var i: usize = 0;
    while (it.next()) |c| : (i += 1) {
        if (i >= px.len) break;
        px[i] = .{ .r = unit(c.r), .g = unit(c.g), .b = unit(c.b), .a = unit(c.a) };
    }
    return .{ .w = @intCast(img.width), .h = @intCast(img.height), .px = px };
}

fn unit(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

pub const Png = struct { png: []u8, w: u32, h: u32 };

/// Decode `bytes` and encode the pixels as a PNG.
pub fn transcodePng(gpa: Allocator, bytes: []const u8) DecodeError!Png {
    var img = zigimg.Image.fromMemory(gpa, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Undecodable,
    };
    defer img.deinit(gpa);
    if (img.width == 0 or img.height == 0) return error.Undecodable;
    img.convert(gpa, .rgba32) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Undecodable,
    };
    // Room for an uncompressed PNG plus headers; the encoder writes less.
    const cap = img.width * img.height * 4 + img.height + 4096;
    const buf = try gpa.alloc(u8, cap);
    errdefer gpa.free(buf);
    const written = img.writeToMemory(gpa, buf, .{ .png = .{} }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Undecodable,
    };
    const out = try gpa.dupe(u8, written);
    gpa.free(buf);
    return .{ .png = out, .w = @intCast(img.width), .h = @intCast(img.height) };
}

/// Nearest-neighbour resample of `src` into a box that fits
/// `max_w`×`max_h`, aspect kept (never upscaled).
pub fn fit(gpa: Allocator, src: *const Pixels, max_w: u32, max_h: u32) Allocator.Error!Pixels {
    var w = src.w;
    var h = src.h;
    if (w > max_w) {
        h = @max(1, @as(u32, @intCast((@as(u64, h) * max_w) / w)));
        w = max_w;
    }
    if (h > max_h) {
        w = @max(1, @as(u32, @intCast((@as(u64, w) * max_h) / h)));
        h = max_h;
    }
    const px = try gpa.alloc(Rgba, w * h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const sy = @min(src.h - 1, @as(u32, @intCast((@as(u64, y) * src.h) / h)));
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const sx = @min(src.w - 1, @as(u32, @intCast((@as(u64, x) * src.w) / w)));
            px[@as(usize, y) * w + x] = src.at(sx, sy);
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

/// The 6×6×6 cube index of a pixel; null for a transparent one.
pub fn cubeIndex(p: Rgba) ?u8 {
    if (p.a < 128) return null;
    const r: u8 = @intCast((@as(u16, p.r) * 5 + 127) / 255);
    const g: u8 = @intCast((@as(u16, p.g) * 5 + 127) / 255);
    const b: u8 = @intCast((@as(u16, p.b) * 5 + 127) / 255);
    return r * 36 + g * 6 + b;
}

/// The sixel stream for `px`: the palette, then each six-row band per
/// colour, run-length encoded.
pub fn encode(arena: Allocator, px: *const Pixels) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "\x1bPq\"1;1;{d};{d}", .{ px.w, px.h });
    // Palette: every cube entry, in percent as the protocol wants.
    var i: u16 = 0;
    while (i < 216) : (i += 1) {
        const r = (i / 36) * 20;
        const g = ((i / 6) % 6) * 20;
        const b = (i % 6) * 20;
        try out.print(arena, "#{d};2;{d};{d};{d}", .{ i, r, g, b });
    }
    const idx = try arena.alloc(?u8, px.px.len);
    for (px.px, 0..) |p, k| idx[k] = cubeIndex(p);
    var band: u32 = 0;
    while (band * 6 < px.h) : (band += 1) {
        const y0 = band * 6;
        var used = @as([216]bool, @splat(false));
        var y: u32 = y0;
        while (y < @min(y0 + 6, px.h)) : (y += 1) {
            var x: u32 = 0;
            while (x < px.w) : (x += 1) if (idx[@as(usize, y) * px.w + x]) |c| {
                used[c] = true;
            };
        }
        var first_color = true;
        var color: u16 = 0;
        while (color < 216) : (color += 1) {
            if (!used[color]) continue;
            if (!first_color) try out.append(arena, '$');
            first_color = false;
            try out.print(arena, "#{d}", .{color});
            var run_char: u8 = 0;
            var run_len: u32 = 0;
            var x: u32 = 0;
            while (x < px.w) : (x += 1) {
                var bits: u8 = 0;
                var dy: u32 = 0;
                while (dy < 6 and y0 + dy < px.h) : (dy += 1) {
                    if (idx[@as(usize, y0 + dy) * px.w + x]) |c| if (c == color) {
                        bits |= @as(u8, 1) << @intCast(dy);
                    };
                }
                const ch: u8 = 0x3f + bits;
                if (run_len > 0 and ch == run_char) {
                    run_len += 1;
                    continue;
                }
                try flushRun(arena, &out, run_char, run_len);
                run_char = ch;
                run_len = 1;
            }
            try flushRun(arena, &out, run_char, run_len);
        }
        try out.append(arena, '-');
    }
    try out.appendSlice(arena, "\x1b\\");
    return out.items;
}

fn flushRun(arena: Allocator, out: *std.ArrayListUnmanaged(u8), ch: u8, len: u32) Allocator.Error!void {
    if (len == 0) return;
    if (len < 4) {
        var k: u32 = 0;
        while (k < len) : (k += 1) try out.append(arena, ch);
    } else try out.print(arena, "!{d}{c}", .{ len, ch });
}

// ── tests ──

const testing = std.testing;

/// A 2×1 PNG — red then green — encoded by zigimg itself, for the
/// tests here and in `painter.zig`.
pub fn testFixturePng(gpa: Allocator) ![]u8 {
    var img = try zigimg.Image.create(gpa, 2, 1, .rgba32);
    defer img.deinit(gpa);
    img.pixels.rgba32[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    img.pixels.rgba32[1] = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const buf = try gpa.alloc(u8, 8192);
    defer gpa.free(buf);
    const written = try img.writeToMemory(gpa, buf, .{ .png = .{} });
    return gpa.dupe(u8, written);
}

test "the cube index rounds each channel to six levels and drops transparent pixels" {
    try testing.expectEqual(@as(?u8, 0), cubeIndex(.{ .r = 0, .g = 0, .b = 0, .a = 255 }));
    try testing.expectEqual(@as(?u8, 215), cubeIndex(.{ .r = 255, .g = 255, .b = 255, .a = 255 }));
    try testing.expectEqual(@as(?u8, 180), cubeIndex(.{ .r = 255, .g = 0, .b = 0, .a = 255 }));
    try testing.expect(cubeIndex(.{ .r = 255, .g = 0, .b = 0, .a = 10 }) == null);
}

test "encode: a 2×2 red / transparent image is one band, the red runs on the red colour only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const red: Rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const clear: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    var px = [_]Rgba{ red, clear, red, red };
    const img: Pixels = .{ .w = 2, .h = 2, .px = &px };
    const s = try encode(arena_state.allocator(), &img);
    try testing.expect(std.mem.startsWith(u8, s, "\x1bPq\"1;1;2;2#0;2;0;0;0"));
    try testing.expect(std.mem.endsWith(u8, s, "-\x1b\\"));
    // Colour 180 (pure red): column 0 has rows 0 and 1 set (bits 0b11 → 'B'),
    // column 1 has row 1 only (0b10 → 'A').
    try testing.expect(std.mem.indexOf(u8, s, "#180BA-") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "#180B"));
}

test "fit keeps the aspect and never upscales; long runs are `!n` encoded" {
    const src_px = try testing.allocator.alloc(Rgba, 100 * 50);
    defer testing.allocator.free(src_px);
    @memset(src_px, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    const src: Pixels = .{ .w = 100, .h = 50, .px = src_px };
    var small = try fit(testing.allocator, &src, 20, 20);
    defer small.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 20), small.w);
    try testing.expectEqual(@as(u32, 10), small.h);
    var same = try fit(testing.allocator, &src, 1000, 1000);
    defer same.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 100), same.w);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try encode(arena_state.allocator(), &small);
    // Two bands of six rows: 20 columns all set → `!20~`.
    try testing.expect(std.mem.indexOf(u8, s, "#30!20~-") != null);
}

test "transcodePng: a decoded image re-encodes as a PNG whose header carries the size; decode reads the pixels back" {
    const png = try testFixturePng(testing.allocator);
    defer testing.allocator.free(png);
    const out = try transcodePng(testing.allocator, png);
    defer testing.allocator.free(out.png);
    try testing.expectEqual(@as(u32, 2), out.w);
    try testing.expectEqual(@as(u32, 1), out.h);
    try testing.expect(std.mem.startsWith(u8, out.png, "\x89PNG\r\n\x1a\n"));
    var px = try decode(testing.allocator, out.png);
    defer px.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 255), px.at(0, 0).r);
    try testing.expectEqual(@as(u8, 255), px.at(1, 0).g);
    try testing.expectError(error.Undecodable, decode(testing.allocator, "not an image"));
}
