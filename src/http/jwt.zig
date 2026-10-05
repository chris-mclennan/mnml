//! JWT decoding for display: split the three segments, base64url-decode
//! the header and the claims, pull the headline fields. No signature
//! check — this is for reading a token you already hold.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Claims = struct {
    /// The claims segment as JSON text. Owned.
    json: []u8,
    /// The header segment as JSON text. Owned.
    header: []u8,
    sub: ?[]const u8 = null,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    iss: ?[]const u8 = null,
    /// Seconds since the epoch.
    exp: ?i64 = null,
    iat: ?i64 = null,

    pub fn deinit(self: *Claims, gpa: Allocator) void {
        gpa.free(self.json);
        gpa.free(self.header);
        if (self.sub) |s| gpa.free(s);
        if (self.email) |s| gpa.free(s);
        if (self.name) |s| gpa.free(s);
        if (self.iss) |s| gpa.free(s);
    }

    pub fn isExpired(self: *const Claims, now_s: i64) bool {
        return if (self.exp) |e| e <= now_s else false;
    }
};

pub const DecodeError = error{ NotAJwt, BadBase64, NotJson } || Allocator.Error;

fn decodeSegment(gpa: Allocator, seg: []const u8) DecodeError![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const trimmed = std.mem.trimEnd(u8, seg, "=");
    const size = dec.calcSizeForSlice(trimmed) catch return error.BadBase64;
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    dec.decode(out, trimmed) catch return error.BadBase64;
    return out;
}

fn strField(gpa: Allocator, obj: std.json.ObjectMap, key: []const u8) Allocator.Error!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| try gpa.dupe(u8, s),
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn decode(gpa: Allocator, token_in: []const u8) DecodeError!Claims {
    var token = std.mem.trim(u8, token_in, " \t\r\n\"'");
    if (std.ascii.startsWithIgnoreCase(token, "bearer ")) token = std.mem.trim(u8, token["bearer ".len..], " \t");
    var parts = std.mem.splitScalar(u8, token, '.');
    const h = parts.next() orelse return error.NotAJwt;
    const p = parts.next() orelse return error.NotAJwt;
    _ = parts.next() orelse return error.NotAJwt;
    if (parts.next() != null) return error.NotAJwt;
    const header = try decodeSegment(gpa, h);
    errdefer gpa.free(header);
    const json = try decodeSegment(gpa, p);
    errdefer gpa.free(json);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return error.NotJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotJson,
    };
    var claims: Claims = .{ .json = json, .header = header };
    claims.sub = try strField(gpa, obj, "sub");
    errdefer if (claims.sub) |s| gpa.free(s);
    claims.email = try strField(gpa, obj, "email");
    errdefer if (claims.email) |s| gpa.free(s);
    claims.name = try strField(gpa, obj, "name");
    errdefer if (claims.name) |s| gpa.free(s);
    claims.iss = try strField(gpa, obj, "iss");
    claims.exp = intField(obj, "exp");
    claims.iat = intField(obj, "iat");
    return claims;
}

/// The bare token out of `Authorization: Bearer x`, `Bearer x`, or a
/// quoted / bare token in free text.
pub fn extractBearer(text: []const u8) ?[]const u8 {
    if (std.ascii.findIgnoreCase(text, "bearer")) |i| {
        const rest = std.mem.trim(u8, text[i + "bearer".len ..], " \t\r\n\"'");
        const end = std.mem.indexOfAny(u8, rest, " \t\r\n\"'") orelse rest.len;
        if (end > 0) return rest[0..end];
    }
    // A JWT-shaped word anywhere.
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\"'");
    while (it.next()) |word| {
        if (std.mem.count(u8, word, ".") == 2 and std.mem.startsWith(u8, word, "ey")) return word;
    }
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "decode the jwt.io example; reject non-tokens" {
    const tok = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    var c = try decode(testing.allocator, tok);
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("1234567890", c.sub.?);
    try testing.expectEqualStrings("John Doe", c.name.?);
    try testing.expectEqual(@as(?i64, 1516239022), c.iat);
    try testing.expect(c.exp == null);
    try testing.expect(!c.isExpired(2_000_000_000));
    try testing.expect(std.mem.indexOf(u8, c.header, "HS256") != null);
    try testing.expectError(error.NotAJwt, decode(testing.allocator, "abc"));
    try testing.expectError(error.NotAJwt, decode(testing.allocator, "a.b"));
    try testing.expectError(error.BadBase64, decode(testing.allocator, "!!.!!.!!"));
    var bearer = try decode(testing.allocator, "Bearer " ++ tok);
    defer bearer.deinit(testing.allocator);
    try testing.expectEqualStrings("1234567890", bearer.sub.?);
    try testing.expectEqualStrings(tok, extractBearer("Authorization: Bearer " ++ tok ++ "\n").?);
    try testing.expectEqualStrings(tok, extractBearer("token is '" ++ tok ++ "' ok").?);
    try testing.expect(extractBearer("nothing here") == null);
}
