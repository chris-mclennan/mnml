//! The small text work every panel needs: fitting a string to a column,
//! wrapping a description to the detail pane's width, and turning a Jira
//! timestamp into something a row can hold.
//!
//! Widths are counted the way `sdk.Frame` paints — one cell per code
//! point, two for the wide ranges — so a column that says 20 really
//! occupies 20 cells.

const std = @import("std");
const sdk = @import("mnml_sdk");

/// Cells `s` would take if it were painted whole.
pub fn width(s: []const u8) u16 {
    var w: u16 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        if (cp == '\n' or cp == '\r' or cp == '\t') continue;
        w +|= if (sdk.frame.isWide(cp)) 2 else 1;
    }
    return w;
}

/// The longest prefix of `s` that fits in `max` cells, plus `…` when
/// something was cut. The slice is borrowed; the ellipsis is not, so the
/// result is written into `buf` (which must hold `max * 4 + 3` bytes to
/// be safe).
pub fn fit(buf: []u8, s: []const u8, max: u16) []const u8 {
    if (max == 0) return "";
    if (width(s) <= max) {
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
    // Room for the single-cell ellipsis.
    const budget = max - 1;
    var used: u16 = 0;
    var out: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        if (cp == '\n' or cp == '\r' or cp == '\t') continue;
        const w: u16 = if (sdk.frame.isWide(cp)) 2 else 1;
        if (used + w > budget) break;
        if (out + bytes.len + 3 > buf.len) break;
        @memcpy(buf[out..][0..bytes.len], bytes);
        out += bytes.len;
        used += w;
    }
    const ell = "\u{2026}";
    if (out + ell.len <= buf.len) {
        @memcpy(buf[out..][0..ell.len], ell);
        out += ell.len;
    }
    return buf[0..out];
}

/// A newline-free, single-spaced version of `s` — a summary out of Jira
/// may carry a stray newline or a run of spaces, and a table row cannot.
pub fn oneLine(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var space = false;
    for (s) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(gpa, ' ');
        space = false;
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// `s` broken into lines no wider than `w`, on word boundaries where it
/// can and mid-word where a word is longer than the column. Existing
/// newlines are kept. The lines are slices of `s`, so nothing is copied.
pub fn wrap(gpa: std.mem.Allocator, s: []const u8, w: u16) std.mem.Allocator.Error![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    if (w == 0) return lines.toOwnedSlice(gpa);
    var para = std.mem.splitScalar(u8, s, '\n');
    while (para.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) {
            try lines.append(gpa, "");
            continue;
        }
        var rest = line;
        while (rest.len > 0) {
            if (width(rest) <= w) {
                try lines.append(gpa, rest);
                break;
            }
            const cut = breakAt(rest, w);
            try lines.append(gpa, std.mem.trimEnd(u8, rest[0..cut], " \t"));
            rest = std.mem.trimStart(u8, rest[cut..], " \t");
        }
    }
    return lines.toOwnedSlice(gpa);
}

/// The byte offset to cut `s` at so the prefix fits `w` cells, preferring
/// the last space inside the budget.
fn breakAt(s: []const u8, w: u16) usize {
    var used: u16 = 0;
    var last_space: ?usize = null;
    var i: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch {
            i += bytes.len;
            continue;
        };
        const cw: u16 = if (sdk.frame.isWide(cp)) 2 else 1;
        if (used + cw > w) break;
        if (cp == ' ') last_space = i;
        used += cw;
        i += bytes.len;
    }
    if (i == 0) i = @min(s.len, 1);
    return if (last_space) |ls| if (ls > 0) ls else i else i;
}

/// `2026-09-15T08:30:00.000+0100` → `2026-09-15`. Anything that is not a
/// Jira timestamp comes back as it went in.
pub fn dayOf(ts: []const u8) []const u8 {
    if (ts.len >= 10 and ts[4] == '-' and ts[7] == '-') return ts[0..10];
    return ts;
}

/// `2026-09-15T08:30:00.000+0100` → `2026-09-15 08:30`, written into
/// `buf` (16 bytes is enough) because the `T` becomes a space.
pub fn minuteOf(buf: *[16]u8, ts: []const u8) []const u8 {
    if (ts.len >= 16 and ts[4] == '-' and ts[7] == '-' and ts[10] == 'T') {
        @memcpy(buf, ts[0..16]);
        buf[10] = ' ';
        return buf[0..16];
    }
    return dayOf(ts);
}

/// A rough age, for the `Updated` column: `3h`, `5d`, `2w`, `8mo`. Both
/// arguments are Jira timestamps; `now` is the one the app captured when
/// the refresh started, so every row on screen agrees.
pub fn ageOf(buf: []u8, ts: []const u8, now: []const u8) []const u8 {
    const then = epochDays(ts) orelse return dayOf(ts);
    const today = epochDays(now) orelse return dayOf(ts);
    if (today < then) return "now";
    const days = today - then;
    if (days == 0) {
        const t_min = minutesOf(ts) orelse return "today";
        const n_min = minutesOf(now) orelse return "today";
        if (n_min <= t_min) return "now";
        const mins = n_min - t_min;
        if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "now";
        return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(mins, 60)}) catch "today";
    }
    if (days < 14) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "";
    if (days < 70) return std.fmt.bufPrint(buf, "{d}w", .{@divTrunc(days, 7)}) catch "";
    if (days < 365) return std.fmt.bufPrint(buf, "{d}mo", .{@divTrunc(days, 30)}) catch "";
    return std.fmt.bufPrint(buf, "{d}y", .{@divTrunc(days, 365)}) catch "";
}

/// Days since 1970 for the `YYYY-MM-DD` at the head of a Jira timestamp.
/// The offset is ignored: the column says `3d`, not a wall clock.
fn epochDays(ts: []const u8) ?i64 {
    if (ts.len < 10 or ts[4] != '-' or ts[7] != '-') return null;
    const y = std.fmt.parseInt(i64, ts[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, ts[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, ts[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    // Howard Hinnant's days-from-civil.
    const yy = y - @intFromBool(m <= 2);
    const era = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400;
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn minutesOf(ts: []const u8) ?i64 {
    if (ts.len < 16 or ts[10] != 'T' or ts[13] != ':') return null;
    const h = std.fmt.parseInt(i64, ts[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, ts[14..16], 10) catch return null;
    return h * 60 + mi;
}

/// Percent-encode `s` for a query string (`RFC 3986` unreserved kept).
pub fn urlEncode(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(gpa, c),
        else => {
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0x0f]);
        },
    };
    return out.toOwnedSlice(gpa);
}

/// A case-insensitive substring test — what the filter box does.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "width counts cells, not bytes; fit cuts with an ellipsis" {
    try testing.expectEqual(@as(u16, 3), width("abc"));
    try testing.expectEqual(@as(u16, 4), width("a漢b"));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("abc", fit(&buf, "abc", 5));
    try testing.expectEqualStrings("ab\u{2026}", fit(&buf, "abcdef", 3));
    try testing.expectEqualStrings("", fit(&buf, "abc", 0));
    // A wide glyph is never half-painted.
    try testing.expectEqualStrings("a\u{2026}", fit(&buf, "a漢b", 3));
}

test "oneLine collapses every run of whitespace" {
    const s = try oneLine(testing.allocator, "  Login  fails\n\ton   Safari  ");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Login fails on Safari", s);
    const empty = try oneLine(testing.allocator, "   \n  ");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "wrap breaks on words, keeps blank lines, and splits a word too long for the column" {
    const lines = try wrap(testing.allocator, "the quick brown fox\n\njumped", 10);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("the quick", lines[0]);
    try testing.expectEqualStrings("brown fox", lines[1]);
    try testing.expectEqualStrings("", lines[2]);
    try testing.expectEqualStrings("jumped", lines[3]);
    const long = try wrap(testing.allocator, "supercalifragilistic", 8);
    defer testing.allocator.free(long);
    try testing.expectEqual(@as(usize, 3), long.len);
    try testing.expectEqualStrings("supercal", long[0]);
    try testing.expectEqualStrings("ifragili", long[1]);
    try testing.expectEqualStrings("stic", long[2]);
}

test "timestamps: the day, the minute, and an age the Updated column can hold" {
    try testing.expectEqualStrings("2026-09-15", dayOf("2026-09-15T08:30:00.000+0100"));
    var mbuf: [16]u8 = undefined;
    try testing.expectEqualStrings("2026-09-15 08:30", minuteOf(&mbuf, "2026-09-15T08:30:00.000+0100"));
    try testing.expectEqualStrings("2026-09-15", minuteOf(&mbuf, "2026-09-15"));
    try testing.expectEqualStrings("not a date", dayOf("not a date"));
    var buf: [16]u8 = undefined;
    const now = "2026-09-15T12:00:00.000+0000";
    try testing.expectEqualStrings("30m", ageOf(&buf, "2026-09-15T11:30:00.000+0000", now));
    try testing.expectEqualStrings("4h", ageOf(&buf, "2026-09-15T08:00:00.000+0000", now));
    try testing.expectEqualStrings("3d", ageOf(&buf, "2026-09-12T08:00:00.000+0000", now));
    try testing.expectEqualStrings("4w", ageOf(&buf, "2026-08-15T08:00:00.000+0000", now));
    try testing.expectEqualStrings("4mo", ageOf(&buf, "2026-05-15T08:00:00.000+0000", now));
    try testing.expectEqualStrings("2y", ageOf(&buf, "2024-05-15T08:00:00.000+0000", now));
    try testing.expectEqualStrings("now", ageOf(&buf, "2026-09-16T08:00:00.000+0000", now));
}

test "urlEncode keeps the unreserved set and escapes the rest" {
    const s = try urlEncode(testing.allocator, "project = \"ENG\" AND assignee=currentUser()");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("project%20%3D%20%22ENG%22%20AND%20assignee%3DcurrentUser%28%29", s);
}

test "the filter is case-insensitive and an empty needle matches" {
    try testing.expect(containsIgnoreCase("Login Fails", "fails"));
    try testing.expect(containsIgnoreCase("Login Fails", ""));
    try testing.expect(!containsIgnoreCase("Login", "Loginx"));
    try testing.expect(!containsIgnoreCase("ab", "b c"));
}
