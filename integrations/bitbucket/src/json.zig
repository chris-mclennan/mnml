//! Reading Bitbucket's JSON without a schema. Every response field is
//! optional in practice — Bitbucket drops keys on slim projections,
//! returns `description` as an object on a detail and a bare string on
//! a list, and nests a branch three levels down — so the whole client
//! reads through these helpers rather than a typed parse that a single
//! missing key would fail.
//!
//! Values are slices into the `std.json.Parsed` they came from; the
//! caller keeps that alive (each fetch owns an arena).

const std = @import("std");

pub const Value = std.json.Value;

/// `v.key` as a string; "" when absent, null, or not a string.
pub fn str(v: Value, key: []const u8) []const u8 {
    return asStr(field(v, key) orelse return "");
}

/// A value as a string; "" when it is not one.
pub fn asStr(v: Value) []const u8 {
    return switch (v) {
        .string, .number_string => |s| s,
        else => "",
    };
}

/// `v.key`, or null when `v` is not an object or the key is missing or
/// JSON `null`.
pub fn field(v: Value, key: []const u8) ?Value {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const got = o.get(key) orelse return null;
    return switch (got) {
        .null => null,
        else => got,
    };
}

/// A dotted path — `path(pr, "source.branch.name")`. Null at the first
/// missing hop.
pub fn path(v: Value, dotted: []const u8) ?Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |seg| cur = field(cur, seg) orelse return null;
    return cur;
}

/// A dotted path as a string; "" when any hop is missing.
pub fn pathStr(v: Value, dotted: []const u8) []const u8 {
    return asStr(path(v, dotted) orelse return "");
}

/// `v.key` as an integer; `fallback` when absent or not a number.
pub fn int(v: Value, key: []const u8, fallback: i64) i64 {
    const got = field(v, key) orelse return fallback;
    return switch (got) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch fallback,
        else => fallback,
    };
}

/// A value as an integer; null when it is not a number.
pub fn asInt(v: Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// `v.key` as a bool; `fallback` when absent or not a bool.
pub fn boolean(v: Value, key: []const u8, fallback: bool) bool {
    const got = field(v, key) orelse return fallback;
    return switch (got) {
        .bool => |b| b,
        else => fallback,
    };
}

/// `v.key` as an array; empty when absent or not one.
pub fn array(v: Value, key: []const u8) []const Value {
    const got = field(v, key) orelse return &.{};
    return switch (got) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// Bitbucket's "renderable": `{raw, html, markup}` on a detail, a bare
/// string on a list. Both read as the raw markdown.
pub fn renderable(v: Value, key: []const u8) []const u8 {
    const got = field(v, key) orelse return "";
    return switch (got) {
        .string => |s| s,
        .object => asStr(field(got, "raw") orelse return ""),
        else => "",
    };
}

/// The `YYYY-MM-DD` head of an ISO-8601 stamp; the input when shorter.
pub fn date(iso: []const u8) []const u8 {
    return if (iso.len >= 10) iso[0..10] else iso;
}

/// `YYYY-MM-DDTHH:MM` — the head an activity row shows. Borrowed from
/// the input, so the `T` stays; `stampInto` is the readable spelling.
pub fn stamp(iso: []const u8) []const u8 {
    return if (iso.len >= 16) iso[0..16] else date(iso);
}

/// `YYYY-MM-DD HH:MM` — the same head with the `T` as a space, written
/// into the caller's buffer since the swap needs one byte of room.
pub fn stampInto(iso: []const u8, buf: *[16]u8) []const u8 {
    const head = stamp(iso);
    @memcpy(buf[0..head.len], head);
    if (head.len == 16) buf[10] = ' ';
    return buf[0..head.len];
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const sample =
    \\{"id":7,"title":"Fix the thing","state":"OPEN","closed":null,
    \\ "source":{"branch":{"name":"bug/fix"},"repository":{"full_name":"acme/api"}},
    \\ "description":{"raw":"body text","html":"<p>body</p>"},
    \\ "links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/7"}},
    \\ "participants":[{"approved":true},{"approved":false}],
    \\ "draft":true,"updated_on":"2026-09-01T12:34:56.789+00:00"}
;

test "fields, dotted paths, ints, bools, arrays — a missing hop is empty, never an error" {
    var p = try std.json.parseFromSlice(Value, t.allocator, sample, .{});
    defer p.deinit();
    const v = p.value;
    try t.expectEqualStrings("Fix the thing", str(v, "title"));
    try t.expectEqualStrings("", str(v, "nope"));
    try t.expectEqual(@as(i64, 7), int(v, "id", -1));
    try t.expectEqual(@as(i64, -1), int(v, "nope", -1));
    try t.expect(boolean(v, "draft", false));
    try t.expect(!boolean(v, "nope", false));
    try t.expectEqualStrings("bug/fix", pathStr(v, "source.branch.name"));
    try t.expectEqualStrings("acme/api", pathStr(v, "source.repository.full_name"));
    try t.expectEqualStrings("", pathStr(v, "destination.branch.name"));
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pull-requests/7", pathStr(v, "links.html.href"));
    try t.expectEqual(@as(usize, 2), array(v, "participants").len);
    try t.expectEqual(@as(usize, 0), array(v, "nope").len);
    // An explicit JSON null reads as absent.
    try t.expect(field(v, "closed") == null);
}

test "a renderable reads the same whether Bitbucket sent an object or a bare string" {
    var detail = try std.json.parseFromSlice(Value, t.allocator, sample, .{});
    defer detail.deinit();
    try t.expectEqualStrings("body text", renderable(detail.value, "description"));
    var list = try std.json.parseFromSlice(Value, t.allocator, "{\"description\":\"plain\"}", .{});
    defer list.deinit();
    try t.expectEqualStrings("plain", renderable(list.value, "description"));
    var none = try std.json.parseFromSlice(Value, t.allocator, "{\"description\":null}", .{});
    defer none.deinit();
    try t.expectEqualStrings("", renderable(none.value, "description"));
}

test "date and stamp slice an ISO-8601 head and never run off a short string" {
    try t.expectEqualStrings("2026-09-01", date("2026-09-01T12:34:56.789+00:00"));
    try t.expectEqualStrings("2026-09-01T12:34", stamp("2026-09-01T12:34:56.789+00:00"));
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("2026-09-01 12:34", stampInto("2026-09-01T12:34:56.789+00:00", &buf));
    try t.expectEqualStrings("2026", date("2026"));
    try t.expectEqualStrings("", stamp(""));
    try t.expectEqualStrings("2026-09-01", stampInto("2026-09-01", &buf));
}
