//! The build lines that hang under a pull-request row — one per
//! pipeline that ran on the commit the pull request is about.
//!
//! Both panes show them and both used to spell them differently: one
//! wrote `✓ SUCCESSFUL  #412  on main  2026-09-14  5m12s`, the other
//! `→ #412 SUCCESSFUL  main  2026-09-14  5m12s`. Same four facts, two
//! orders, two separators, two glyph sets. The line lives here now, so
//! a reader who learns to read one pane can read the other:
//!
//!   ✓ SUCCESSFUL · main · 4h · #412
//!
//! State first because it is what the eye is after, then the branch it
//! ran on, then how long ago, then the run's number. An age rather
//! than a date: "did this run since I pushed" is the question, and
//! `4h` answers it where `2026-09-14` makes the reader do arithmetic.
//!
//! The stamp parser is small on purpose — Howard Hinnant's
//! `days_from_civil`, an offset honoured, no timezone database.

const std = @import("std");
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const text_mod = @import("text.zig");

pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;
pub const width = text_mod.width;

/// The separator between a line's four facts.
pub const sep = " \u{b7} ";
pub const sep_ascii = " - ";

/// One pipeline run, as either pane's model hands it over.
pub const Run = struct {
    /// The label the line leads with: the result when the run has one
    /// (`SUCCESSFUL`, `FAILED`), else the lifecycle stage
    /// (`IN_PROGRESS`, `PENDING`).
    state: []const u8 = "",
    branch: []const u8 = "",
    /// ISO-8601, as both APIs write it.
    created_on: []const u8 = "",
    number: i64 = 0,
};

/// `✓` succeeded, `✗` failed, `⏵` running, `⊘` stopped, `?` otherwise —
/// the glyphs both panes already used, in one place.
pub fn glyph(state: []const u8, ascii: bool) []const u8 {
    if (eq(state, "SUCCESSFUL")) return if (ascii) "+" else "\u{2713}";
    if (eq(state, "FAILED") or eq(state, "ERROR")) return if (ascii) "x" else "\u{2717}";
    if (eq(state, "IN_PROGRESS") or eq(state, "PENDING") or eq(state, "RUNNING") or eq(state, "BUILDING")) return if (ascii) ">" else "\u{23f5}";
    if (eq(state, "STOPPED") or eq(state, "HALTED")) return if (ascii) "o" else "\u{2298}";
    return "?";
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The colour a state wears — the theme's, so a pane cannot invent one.
pub fn styleOf(th: Theme, state: []const u8) Style {
    return th.pipelineState(state);
}

/// How long ago, short: `just now`, `12m`, `4h`, `3d`, `5w`. `—` when
/// the stamp does not parse, and `soon` for one in the future (a clock
/// that disagrees with the server's must not print a negative age).
pub fn ageLabel(buf: []u8, now_secs: i64, created_on: []const u8) []const u8 {
    const then = parseEpoch(created_on) orelse return "\u{2014}";
    const d = now_secs - then;
    if (d < 0) return "soon";
    if (d < 60) return "just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divFloor(d, 60)}) catch "\u{2014}";
    if (d < 86_400) return std.fmt.bufPrint(buf, "{d}h", .{@divFloor(d, 3600)}) catch "\u{2014}";
    if (d < 7 * 86_400) return std.fmt.bufPrint(buf, "{d}d", .{@divFloor(d, 86_400)}) catch "\u{2014}";
    return std.fmt.bufPrint(buf, "{d}w", .{@divFloor(d, 7 * 86_400)}) catch "\u{2014}";
}

/// `✓ SUCCESSFUL · main · 4h · #412`, written into `buf`. A run with no
/// branch says `—` for it rather than leaving a hole the reader has to
/// count separators across.
pub fn caption(buf: []u8, r: Run, now_secs: i64, ascii: bool) []const u8 {
    var age_buf: [16]u8 = undefined;
    const s = if (ascii) sep_ascii else sep;
    return std.fmt.bufPrint(buf, "{s} {s}{s}{s}{s}{s}{s}#{d}", .{
        glyph(r.state, ascii),
        if (r.state.len > 0) r.state else "UNKNOWN",
        s,
        if (r.branch.len > 0) r.branch else "\u{2014}",
        s,
        ageLabel(&age_buf, now_secs, r.created_on),
        s,
        r.number,
    }) catch "?";
}

/// Seconds since the epoch, UTC; null when the stamp does not parse.
/// `2026-09-15T18:40:00.123456+00:00`, `…Z`, and a bare date all read.
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
        if (i < iso.len and iso[i] == '.') {
            i += 1;
            while (i < iso.len and std.ascii.isDigit(iso[i])) i += 1;
        }
    }
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

/// Days since 1970-01-01 for a proleptic Gregorian date.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// The page one build line opens: Bitbucket spells a pipeline result
/// `…/<ws>/<repo>/pipelines/results/<number>`.
pub fn pageUrl(buf: []u8, workspace: []const u8, repo: []const u8, number: i64) []const u8 {
    return std.fmt.bufPrint(buf, "https://bitbucket.org/{s}/{s}/pipelines/results/{d}", .{ workspace, repo, number }) catch "";
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "one build line, four facts, the same order in both panes" {
    var buf: [128]u8 = undefined;
    const now: i64 = 1_789_500_000; // 2026-09-15T19:20Z
    try testing.expectEqualStrings(
        "\u{2713} SUCCESSFUL \u{b7} main \u{b7} 4h \u{b7} #412",
        caption(&buf, .{ .state = "SUCCESSFUL", .branch = "main", .created_on = "2026-09-15T15:20:00+00:00", .number = 412 }, now, false),
    );
    // Running, on a feature branch, minutes ago.
    try testing.expectEqualStrings(
        "\u{23f5} IN_PROGRESS \u{b7} bug/fix \u{b7} 30m \u{b7} #413",
        caption(&buf, .{ .state = "IN_PROGRESS", .branch = "bug/fix", .created_on = "2026-09-15T18:50:00+00:00", .number = 413 }, now, false),
    );
    // Ascii: plain glyphs and a plain separator, so nothing falls back
    // to a box on a terminal without the font.
    try testing.expectEqualStrings(
        "x FAILED - develop - 3d - #411",
        caption(&buf, .{ .state = "FAILED", .branch = "develop", .created_on = "2026-09-12T10:00:00+00:00", .number = 411 }, now, true),
    );
    // Nothing known: the shape holds rather than collapsing into
    // separators the reader has to count across.
    try testing.expectEqualStrings("? UNKNOWN \u{b7} \u{2014} \u{b7} \u{2014} \u{b7} #0", caption(&buf, .{}, now, false));
}

test "the age is short and never negative" {
    var buf: [16]u8 = undefined;
    const now: i64 = 1_789_500_000;
    try testing.expectEqualStrings("just now", ageLabel(&buf, now, "2026-09-15T19:19:30+00:00"));
    try testing.expectEqualStrings("12m", ageLabel(&buf, now, "2026-09-15T19:08:00+00:00"));
    try testing.expectEqualStrings("4h", ageLabel(&buf, now, "2026-09-15T15:20:00+00:00"));
    try testing.expectEqualStrings("3d", ageLabel(&buf, now, "2026-09-12T19:20:00+00:00"));
    try testing.expectEqualStrings("2w", ageLabel(&buf, now, "2026-09-01T19:20:00+00:00"));
    // A server clock ahead of ours must not print `-1h`.
    try testing.expectEqualStrings("soon", ageLabel(&buf, now, "2026-09-16T19:20:00+00:00"));
    try testing.expectEqualStrings("\u{2014}", ageLabel(&buf, now, ""));
    try testing.expectEqualStrings("\u{2014}", ageLabel(&buf, now, "not a date"));
}

test "the glyphs are one set, and a stamp reads with its offset" {
    try testing.expectEqualStrings("\u{2713}", glyph("SUCCESSFUL", false));
    try testing.expectEqualStrings("\u{2717}", glyph("FAILED", false));
    try testing.expectEqualStrings("\u{2717}", glyph("ERROR", false));
    try testing.expectEqualStrings("\u{23f5}", glyph("PENDING", false));
    try testing.expectEqualStrings("\u{2298}", glyph("STOPPED", false));
    try testing.expectEqualStrings("?", glyph("nonsense", false));
    try testing.expectEqualStrings("+", glyph("successful", true));
    // `Z`, an offset, and a bare date all land on the same clock.
    try testing.expectEqual(@as(?i64, 0), parseEpoch("1970-01-01"));
    try testing.expectEqual(@as(?i64, 3600), parseEpoch("1970-01-01T01:00:00Z"));
    try testing.expectEqual(@as(?i64, 0), parseEpoch("1970-01-01T01:00:00+01:00"));
    try testing.expectEqual(@as(?i64, 0), parseEpoch("1970-01-01T01:00:00.123456+0100"));
    try testing.expect(parseEpoch("1970-13-01") == null);
    try testing.expect(parseEpoch("short") == null);
}

test "a build line's page is the run's own result page" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("https://bitbucket.org/acme/api/pipelines/results/412", pageUrl(&buf, "acme", "api", 412));
}
