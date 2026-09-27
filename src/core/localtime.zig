//! The machine's time zone, for anything that prints a wall clock: the
//! statusline clock and the git graph's DATE / TIME column read the SAME
//! offset here, so the two clocks on one screen agree.
//!
//! // changed: the std library has no time-zone reader, so the offset
//! comes from libc: `localtime_r` on POSIX, the CRT's `_localtime64_s`
//! on Windows (DST included either way — the offset is asked for the
//! instant being printed, not for now).

const std = @import("std");
const builtin = @import("builtin");

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

/// The CRT's `struct tm`: no `tm_gmtoff`, so the offset is the local
/// broken-down time read back as if it were UTC, less the instant.
const TmWin = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};
extern "c" fn _localtime64_s(result: *TmWin, timep: *const i64) c_int;
extern "c" fn _mkgmtime64(tm: *TmWin) i64;

/// Seconds east of UTC at `secs` (Unix time), per libc; 0 when libc
/// cannot say.
pub fn offset(secs: i64) i64 {
    if (builtin.os.tag == .windows) {
        var tm: TmWin = undefined;
        const at: i64 = secs;
        if (_localtime64_s(&tm, &at) != 0) return 0;
        const as_utc = _mkgmtime64(&tm);
        if (as_utc == -1) return 0;
        return as_utc - secs;
    }
    var tm: Tm = undefined;
    const at: i64 = secs;
    if (localtime_r(&at, &tm) == null) return 0;
    return @intCast(tm.tm_gmtoff);
}

test "offset: the machine's zone is within a day of UTC, and the same instant asked twice answers the same" {
    const a = offset(1_757_188_800);
    try std.testing.expect(a > -14 * 3600 and a < 15 * 3600);
    try std.testing.expectEqual(a, offset(1_757_188_800));
}
