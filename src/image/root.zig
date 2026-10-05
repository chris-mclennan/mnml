//! Inline images: which protocol the terminal speaks, the file as
//! loaded, and the paint requests a frame leaves for the terminal.
//!
//! The frame never writes an image. A pane paints a placeholder into
//! its cells and appends a `PaintRequest` (the cell box and the PNG
//! bytes) to `App.image_paints`; after `Term.render` has put the cells
//! out, `Term.paintImages` emits the protocol escapes over them. That
//! is the same two-phase paint the Rust build used, and it keeps the
//! headless / `.test` path free of anything but cells.
//!
//! Transport is decided once, from the probe and the environment
//! (`detect`): the kitty graphics protocol when the terminal answered
//! the probe (ghostty, kitty, WezTerm), iTerm2's OSC 1337 for iTerm2,
//! sixel for foot / mlterm / Black Box, and `MNML_IMAGE_PROTOCOL`
//! overrides all of it. Anything else gets the text fallback.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Rect = @import("../ui/rect.zig");

pub const kitty = @import("kitty.zig");
pub const iterm2 = @import("iterm2.zig");
pub const sixel = @import("sixel.zig");
pub const Painter = @import("painter.zig");

pub const Transport = enum {
    kitty,
    iterm2,
    sixel,
    none,

    pub fn label(t: Transport) []const u8 {
        return switch (t) {
            .kitty => "kitty graphics",
            .iterm2 => "iTerm2 inline images",
            .sixel => "sixel",
            .none => "none",
        };
    }
};

/// The probe's verdict plus the environment. `MNML_IMAGE_PROTOCOL`
/// (`kitty` / `iterm2` / `sixel` / `none`) wins; then the kitty probe;
/// then the terminals that never answer a graphics query but are known.
pub fn detect(env: *const std.process.Environ.Map, kitty_probe: bool) Transport {
    if (env.get("MNML_IMAGE_PROTOCOL")) |forced| {
        if (std.ascii.eqlIgnoreCase(forced, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(forced, "iterm2") or std.ascii.eqlIgnoreCase(forced, "iterm")) return .iterm2;
        if (std.ascii.eqlIgnoreCase(forced, "sixel")) return .sixel;
        if (std.ascii.eqlIgnoreCase(forced, "none") or std.ascii.eqlIgnoreCase(forced, "off")) return .none;
    }
    if (kitty_probe) return .kitty;
    if (env.get("KITTY_WINDOW_ID") != null) return .kitty;
    if (env.get("TERM")) |term| {
        if (containsIgnoreCase(term, "kitty")) return .kitty;
    }
    if (env.get("TERM_PROGRAM")) |prog| {
        if (containsIgnoreCase(prog, "wezterm") or std.ascii.eqlIgnoreCase(prog, "ghostty")) return .kitty;
        if (containsIgnoreCase(prog, "iterm")) return .iterm2;
        if (containsIgnoreCase(prog, "black box") or std.ascii.eqlIgnoreCase(prog, "blackbox")) return .sixel;
    }
    if (env.get("TERM")) |term| {
        if (std.ascii.eqlIgnoreCase(term, "foot") or std.ascii.startsWithIgnoreCase(term, "foot-") or std.ascii.startsWithIgnoreCase(term, "mlterm")) return .sixel;
    }
    return .none;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
    other,

    pub fn fromPath(path: []const u8) Format {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
        if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .jpeg;
        if (std.ascii.eqlIgnoreCase(ext, ".gif")) return .gif;
        if (std.ascii.eqlIgnoreCase(ext, ".webp")) return .webp;
        if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return .bmp;
        return .other;
    }

    pub fn label(f: Format) []const u8 {
        return switch (f) {
            .png => "PNG",
            .jpeg => "JPG",
            .gif => "GIF",
            .webp => "WEBP",
            .bmp => "BMP",
            .other => "IMG",
        };
    }
};

/// A path the tree opens as an image rather than text.
pub fn isImagePath(path: []const u8) bool {
    return Format.fromPath(path) != .other;
}

/// Files past this are refused, so a stray click on a raw dump does
/// not swallow the process.
pub const max_bytes: usize = 50 * 1024 * 1024;

pub const Size = struct { w: u32, h: u32 };

/// `(width, height)` from a PNG's IHDR — the first 24 bytes — or null
/// for anything else.
pub fn pngSize(bytes: []const u8) ?Size {
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{ .w = std.mem.readInt(u32, bytes[16..20], .big), .h = std.mem.readInt(u32, bytes[20..24], .big) };
}

/// One file as loaded: the bytes, the format by extension, the pixel
/// size once known, and the PNG payload every transport sends (the
/// bytes themselves for a PNG; a decode + re-encode for the rest,
/// done once on first use).
pub const Loaded = struct {
    bytes: []u8,
    format: Format,
    size: ?Size,
    /// Owned when it differs from `bytes` (`png_owned`).
    png: ?[]u8 = null,
    png_owned: bool = false,
    /// Why `png` could not be made, when it could not.
    png_error: ?[]const u8 = null,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        if (self.png_owned) if (self.png) |p| gpa.free(p);
        gpa.free(self.bytes);
    }

    /// A stable id for a placement cache: the path's hash and the size.
    pub fn key(self: *const Loaded, path: []const u8) u64 {
        var h = std.hash.Wyhash.init(0x6d6e6d6c);
        h.update(path);
        h.update(std.mem.asBytes(&self.bytes.len));
        return h.final();
    }

    /// The PNG payload, making it on first call.
    pub fn ensurePng(self: *Loaded, gpa: Allocator) ?[]const u8 {
        if (self.png) |p| return p;
        if (self.png_error != null) return null;
        if (self.format == .png and pngSize(self.bytes) != null) {
            self.png = self.bytes;
            return self.bytes;
        }
        const out = sixel.transcodePng(gpa, self.bytes) catch |err| {
            self.png_error = @errorName(err);
            return null;
        };
        self.png = out.png;
        self.png_owned = true;
        if (self.size == null) self.size = .{ .w = out.w, .h = out.h };
        return out.png;
    }
};

pub const LoadError = error{ TooLarge, OutOfMemory, FileNotFound };

/// Read `path` (absolute) into memory.
pub fn load(gpa: Allocator, io: Io, path: []const u8) LoadError!Loaded {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.TooLarge,
        else => return error.FileNotFound,
    };
    errdefer gpa.free(bytes);
    if (bytes.len > max_bytes) return error.TooLarge;
    return .{ .bytes = bytes, .format = Format.fromPath(path), .size = pngSize(bytes) };
}

/// What a frame leaves for `Term.paintImages`: the cell box and the
/// PNG bytes (borrowed from a pane's cache, which outlives the frame).
pub const PaintRequest = struct {
    rect: Rect,
    png: []const u8,
    /// `Loaded.key`: the same image in the same place costs nothing on
    /// kitty, which places by id.
    key: u64,
};

// ── tests ──

const testing = std.testing;

test "detect: the override wins, then the probe, then the terminals that never answer" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(Transport.none, detect(&env, false));
    try testing.expectEqual(Transport.kitty, detect(&env, true));
    try env.put("TERM_PROGRAM", "iTerm.app");
    try testing.expectEqual(Transport.iterm2, detect(&env, false));
    try testing.expectEqual(Transport.kitty, detect(&env, true)); // the probe outranks the name
    try env.put("TERM_PROGRAM", "ghostty");
    try testing.expectEqual(Transport.kitty, detect(&env, false));
    try env.put("TERM_PROGRAM", "WezTerm");
    try testing.expectEqual(Transport.kitty, detect(&env, false));
    try env.put("TERM_PROGRAM", "Apple_Terminal");
    try testing.expectEqual(Transport.none, detect(&env, false));
    try env.put("TERM", "foot-extra");
    try testing.expectEqual(Transport.sixel, detect(&env, false));
    try env.put("TERM", "xterm-kitty");
    try testing.expectEqual(Transport.kitty, detect(&env, false));
    try env.put("MNML_IMAGE_PROTOCOL", "sixel");
    try testing.expectEqual(Transport.sixel, detect(&env, true));
    try env.put("MNML_IMAGE_PROTOCOL", "none");
    try testing.expectEqual(Transport.none, detect(&env, true));
    try env.put("MNML_IMAGE_PROTOCOL", "bogus");
    try testing.expectEqual(Transport.kitty, detect(&env, true));
}

test "format by extension; the PNG header gives the size; a JPEG gives none" {
    try testing.expectEqual(Format.png, Format.fromPath("a/b.PNG"));
    try testing.expectEqual(Format.jpeg, Format.fromPath("x.jpeg"));
    try testing.expectEqual(Format.gif, Format.fromPath("x.gif"));
    try testing.expectEqual(Format.webp, Format.fromPath("x.webp"));
    try testing.expectEqual(Format.bmp, Format.fromPath("x.bmp"));
    try testing.expectEqual(Format.other, Format.fromPath("x.tif"));
    try testing.expect(isImagePath("shot.png") and !isImagePath("main.zig"));
    const png = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x03\x20" ++ "\x00\x00\x02\x58" ++ "\x08\x06";
    const s = pngSize(png).?;
    try testing.expectEqual(@as(u32, 800), s.w);
    try testing.expectEqual(@as(u32, 600), s.h);
    try testing.expect(pngSize("\xff\xd8\xff\xe0 not a png at all, twenty-four bytes") == null);
    try testing.expect(pngSize("short") == null);
}

test "load: reads the file, refuses one past the cap, keys by path and size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.png", .data = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x03\x08\x06" });
    const path = try std.fs.path.join(testing.allocator, &.{ root, "a.png" });
    defer testing.allocator.free(path);
    var l = try load(testing.allocator, testing.io, path);
    defer l.deinit(testing.allocator);
    try testing.expectEqual(Format.png, l.format);
    try testing.expectEqual(@as(u32, 2), l.size.?.w);
    try testing.expect(l.ensurePng(testing.allocator).?.ptr == l.bytes.ptr);
    try testing.expect(l.key(path) != l.key("other"));
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "nope.png" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, load(testing.allocator, testing.io, missing));
}
