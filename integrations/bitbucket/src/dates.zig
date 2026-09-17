//! ISO-8601 stamps the way Bitbucket writes them —
//! `2026-09-15T18:40:00.123456+00:00` — read as seconds since the
//! epoch and written back, with the two questions the pane asks of
//! one: how many hours ago (the 24-hour window on a pull request) and
//! how many days ago (the staleness rule on a branch). Civil dates go
//! through Howard Hinnant's `days_from_civil` / `civil_from_days`, so
//! there is no calendar table and no timezone database: an offset is
//! honoured, a `Z` is zero, and a stamp with neither is read as UTC.

const std = @import("std");

/// `YYYY-MM-DD` — the head of a stamp, or the whole of a shorter one.
pub fn date(iso: []const u8) []const u8 {
    return if (iso.len >= 10) iso[0..10] else iso;
}

/// Seconds since the epoch, UTC; null when the stamp does not parse.
pub fn parseEpoch(iso: []const u8) ?i64 {
    if (iso.len < 10) return null;
    const y = std.fmt.parseInt(i64, iso[0..4], 10) catch return null;
    if (iso[4] != '-' or iso[7] != '-') return null;
    const m = std.fmt.parseInt(i64, iso[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, iso[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    var secs = daysFromCivil(y, m, d) * 86_400;
    var i: usize = 10;
    if (i < iso.len and (iso[i] == 'T' or iso[i] == ' ')) {
        i += 1;
        if (i + 5 > iso.len) return null;
        const hh = std.fmt.parseInt(i64, iso[i .. i + 2], 10) catch return null;
        const mm = std.fmt.parseInt(i64, iso[i + 3 .. i + 5], 10) catch return null;
        secs += hh * 3600 + mm * 60;
        i += 5;
        if (i + 3 <= iso.len and iso[i] == ':') {
            const ss = std.fmt.parseInt(i64, iso[i + 1 .. i + 3], 10) catch return null;
            secs += ss;
            i += 3;
        }
        // Fractional seconds are dropped.
        if (i < iso.len and iso[i] == '.') {
            i += 1;
            while (i < iso.len and std.ascii.isDigit(iso[i])) i += 1;
        }
    }
    // The offset: `Z`, `+HH:MM`, `-HHMM`, or nothing (UTC).
    if (i < iso.len) {
        const c = iso[i];
        if (c == '+' or c == '-') {
            const rest = iso[i + 1 ..];
            if (rest.len < 2) return null;
            const oh = std.fmt.parseInt(i64, rest[0..2], 10) catch return null;
            var om: i64 = 0;
            if (rest.len >= 5 and rest[2] == ':') {
                om = std.fmt.parseInt(i64, rest[3..5], 10) catch return null;
            } else if (rest.len >= 4) {
                om = std.fmt.parseInt(i64, rest[2..4], 10) catch return null;
            }
            const off = oh * 3600 + om * 60;
            secs = if (c == '+') secs - off else secs + off;
        }
    }
    return secs;
}

/// Whole hours between `iso` and `now_secs`; null when the stamp does
/// not parse. Negative for a stamp in the future.
pub fn hoursSince(now_secs: i64, iso: []const u8) ?i64 {
    const then = parseEpoch(iso) orelse return null;
    return @divFloor(now_secs - then, 3600);
}

/// Whole days between `iso` and `now_secs`; null when it does not parse.
pub fn daysSince(now_secs: i64, iso: []const u8) ?i64 {
    const then = parseEpoch(iso) orelse return null;
    return @divFloor(now_secs - then, 86_400);
}

/// Days since 1970-01-01 for a proleptic Gregorian date.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

pub const Civil = struct { y: i64, m: i64, d: i64 };

/// The calendar date `days` after 1970-01-01.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y0 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y0 + 1 else y0, .m = m, .d = d };
}

/// `YYYY-MM-DD` for seconds since the epoch, into `buf` (10 bytes).
pub fn writeDate(buf: *[10]u8, secs: i64) []const u8 {
    const c = civilFromDays(@divFloor(secs, 86_400));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(@max(c.y, 0))), @as(u32, @intCast(c.m)), @as(u32, @intCast(c.d)),
    }) catch buf[0..0];
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the epoch and a Bitbucket stamp read as the seconds they are" {
    try t.expectEqual(@as(i64, 0), parseEpoch("1970-01-01T00:00:00+00:00").?);
    try t.expectEqual(@as(i64, 1_789_500_000), parseEpoch("2026-09-15T19:20:00.000000+00:00").?);
    // An offset shifts the instant; a Z and no offset are UTC.
    try t.expectEqual(@as(i64, 1_789_500_000 - 2 * 3600), parseEpoch("2026-09-15T19:20:00+02:00").?);
    try t.expectEqual(@as(i64, 1_789_500_000), parseEpoch("2026-09-15T19:20:00Z").?);
    try t.expectEqual(@as(i64, 1_789_500_000), parseEpoch("2026-09-15T19:20:00").?);
    // A bare date is midnight.
    try t.expectEqual(@as(i64, 1_789_500_000 - 19 * 3600 - 20 * 60), parseEpoch("2026-09-15").?);
    try t.expect(parseEpoch("yesterday") == null);
    try t.expect(parseEpoch("2026-13-01") == null);
}

test "hours and days since count whole units and never crash on junk" {
    const now: i64 = 1_789_500_000;
    try t.expectEqual(@as(i64, 30), hoursSince(now, "2026-09-14T12:40:00+00:00").?);
    try t.expectEqual(@as(i64, 1), daysSince(now, "2026-09-14T12:40:00+00:00").?);
    try t.expectEqual(@as(i64, 0), hoursSince(now, "2026-09-15T19:00:00+00:00").?);
    try t.expect(hoursSince(now, "") == null);
}

test "civil round trip agrees with itself across a leap day and a century" {
    for ([_][3]i64{ .{ 1970, 1, 1 }, .{ 2000, 2, 29 }, .{ 2026, 9, 15 }, .{ 2100, 3, 1 }, .{ 1999, 12, 31 } }) |ymd| {
        const days = daysFromCivil(ymd[0], ymd[1], ymd[2]);
        const back = civilFromDays(days);
        try t.expectEqual(ymd[0], back.y);
        try t.expectEqual(ymd[1], back.m);
        try t.expectEqual(ymd[2], back.d);
    }
    var buf: [10]u8 = undefined;
    try t.expectEqualStrings("2026-09-15", writeDate(&buf, 1_789_500_000));
    try t.expectEqualStrings("2026-09-15", date("2026-09-15T19:20:00+00:00"));
    try t.expectEqualStrings("2026", date("2026"));
}
