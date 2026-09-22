//! A body in a single-byte charset, for the screen. A `charset=iso-8859-1`
//! (or `latin1`, `windows-1252`, …) body is not UTF-8, and its bytes
//! painted as they are come out as replacement glyphs or torn cells.
//! `toUtf8` transcodes it for the view; the stored body, the copy and
//! the save keep the server's bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Single = enum { latin1, cp1252 };

/// The single-byte charset `content_type` names, if it is one this knows.
pub fn singleByte(content_type: ?[]const u8) ?Single {
    const ct = content_type orelse return null;
    const at = std.ascii.indexOfIgnoreCase(ct, "charset=") orelse return null;
    var name = ct[at + "charset=".len ..];
    name = std.mem.sliceTo(name, ';');
    name = std.mem.trim(u8, name, " \t\"'");
    const latin1 = [_][]const u8{ "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1", "iso_8859-1", "us-ascii", "iso-8859-15", "latin9" };
    for (latin1) |l| if (std.ascii.eqlIgnoreCase(name, l)) return .latin1;
    if (std.ascii.eqlIgnoreCase(name, "windows-1252") or std.ascii.eqlIgnoreCase(name, "cp1252")) return .cp1252;
    return null;
}

/// windows-1252's 0x80–0x9F (0 = undefined there, shown as U+FFFD).
const cp1252_high = [32]u21{ 0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0, 0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178 };

/// `bytes` in `cs`, as UTF-8. Owned.
pub fn toUtf8(alloc: Allocator, bytes: []const u8, cs: Single) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, bytes.len + bytes.len / 4);
    for (bytes) |b| {
        const cp: u21 = if (b >= 0x80 and b <= 0x9F and cs == .cp1252) (if (cp1252_high[b - 0x80] == 0) 0xFFFD else cp1252_high[b - 0x80]) else b;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "a latin-1 / windows-1252 body transcodes for the screen" {
    try testing.expectEqual(Single.latin1, singleByte("text/plain; charset=iso-8859-1").?);
    try testing.expectEqual(Single.cp1252, singleByte("text/html; charset=\"Windows-1252\"; x=y").?);
    try testing.expect(singleByte("text/plain; charset=utf-8") == null);
    try testing.expect(singleByte("text/plain") == null);
    const out = try toUtf8(testing.allocator, "caf\xe9 cr\xe8me \x80", .latin1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("café crème \u{80}", out);
    const w = try toUtf8(testing.allocator, "\x93quoted\x94 \x80", .cp1252);
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("\u{201C}quoted\u{201D} \u{20AC}", w);
}
