//! The statusline coverage chip — `F 83% ▲1.0` (feature coverage and
//! its move over seven days) and `C 71% ±0.0` (Istanbul lines and the
//! move since the previous commit), from two `trends.json` files in the
//! machine's shared-state directory, `$MNML_SHARED_STATE_DIR`:
//! `feature-coverage/_trends/trends.json` and
//! `code-coverage/_trends/trends.json`, written by whatever coverage
//! tooling the machine runs. Either may be absent: its number is simply
//! not shown; with neither — or with no shared-state directory — the
//! chip is not painted. The files are re-read every five minutes at
//! most, whatever the outcome.
//!
//! `ui.coverage_chip_mode` picks the shape: `feature` / `code` (one
//! number), `both` (`F 83% ▲1.0 · C 71% ±0.0`), `ticker` (F ⇄ C every
//! four seconds). A click toasts both numbers; a right-click picks the
//! mode. `shown` hands the app the readings; `segment` is the text.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const settings = @import("settings.zig");

pub const reload_ms: i64 = 300_000;
pub const ticker_ms: i64 = 4000;

pub const State = struct {
    /// A test's wall clock for the ticker; null reads the real one.
    ticker_clock_ms: ?i64 = null,
    feature: ?f64 = null,
    code: ?f64 = null,
    /// The feature number seven days before its latest point.
    feature_prev: ?f64 = null,
    /// The code number at the previous commit's point.
    code_prev: ?f64 = null,
    /// The loop clock at the last read attempt; 0 = never.
    loaded_at_ms: i64 = 0,
};

pub const table = .{
    .@"coverage.toast" = &toastCmd,
    .@"coverage.chip_show_both" = modeRunner(.both, "coverage chip: showing Feature + Code"),
    .@"coverage.chip_show_feature" = modeRunner(.feature, "coverage chip: showing Feature only"),
    .@"coverage.chip_show_code" = modeRunner(.code, "coverage chip: showing Code only"),
    .@"coverage.chip_show_ticker" = modeRunner(.ticker, "coverage chip: ticker (F ⇄ C)"),
};

// ─── the files ───────────────────────────────────────────────────────────

const FeaturePoint = struct { date: []const u8 = "", ui: ?f64 = null, api: ?f64 = null, features: u32 = 0 };
const FeatureApp = struct { series: []const FeaturePoint = &.{} };
const FeatureFile = struct { apps: []const FeatureApp = &.{} };

const CodePoint = struct { files: u32 = 0, lines: f64 = 0 };
const CodeApp = struct { series: []const CodePoint = &.{} };
const CodeFile = struct { apps: []const CodeApp = &.{} };

/// The feature number: each app's latest point scores the mean of its
/// `ui` / `api` axes (one axis alone counts as itself), weighted by
/// the app's feature count (Rust's `weighted_axis_avg`).
pub fn featureOverall(f: FeatureFile) ?f64 {
    var sum: f64 = 0;
    var weight: f64 = 0;
    for (f.apps) |a| {
        if (a.series.len == 0) continue;
        const p = a.series[a.series.len - 1];
        const score: f64 = if (p.ui != null and p.api != null) (p.ui.? + p.api.?) / 2 else p.ui orelse p.api orelse continue;
        const w: f64 = @floatFromInt(@max(p.features, 1));
        sum += score * w;
        weight += w;
    }
    return if (weight > 0) sum / weight else null;
}

/// The code number: each app's latest `lines` %, weighted by its file count.
pub fn codeOverall(f: CodeFile) ?f64 {
    var sum: f64 = 0;
    var weight: f64 = 0;
    for (f.apps) |a| {
        if (a.series.len == 0) continue;
        const p = a.series[a.series.len - 1];
        const w: f64 = @floatFromInt(@max(p.files, 1));
        sum += p.lines * w;
        weight += w;
    }
    return if (weight > 0) sum / weight else null;
}

/// `featureOverall` over the point of each app closest to `days` days
/// before its latest — the first point, walking back, dated on or
/// before the target; the series' first point when none is. Null with
/// no data at all.
pub fn featureAt(f: FeatureFile, days: u32) ?f64 {
    var sum: f64 = 0;
    var weight: f64 = 0;
    for (f.apps) |a| {
        if (a.series.len == 0) continue;
        const latest = a.series[a.series.len - 1];
        var target_buf: [16]u8 = undefined;
        const target = dateMinusDays(&target_buf, latest.date, days);
        var pick = a.series[0];
        if (target) |tgt| {
            var i = a.series.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.order(u8, a.series[i].date, tgt) != .gt) {
                    pick = a.series[i];
                    break;
                }
            }
        }
        const score: f64 = if (pick.ui != null and pick.api != null) (pick.ui.? + pick.api.?) / 2 else pick.ui orelse pick.api orelse continue;
        const w: f64 = @floatFromInt(@max(pick.features, 1));
        sum += score * w;
        weight += w;
    }
    return if (weight > 0) sum / weight else null;
}

/// `codeOverall` over each app's second-to-last point (its first when
/// there is only one) — the previous commit, since Istanbul reports
/// per merge, not per day.
pub fn codePrev(f: CodeFile) ?f64 {
    var sum: f64 = 0;
    var weight: f64 = 0;
    for (f.apps) |a| {
        if (a.series.len == 0) continue;
        const p = if (a.series.len >= 2) a.series[a.series.len - 2] else a.series[0];
        const w: f64 = @floatFromInt(@max(p.files, 1));
        sum += p.lines * w;
        weight += w;
    }
    return if (weight > 0) sum / weight else null;
}

/// `YYYY-MM-DD` less `days`, or null for a date that does not parse.
fn dateMinusDays(buf: []u8, date: []const u8, days: u32) ?[]const u8 {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return null;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, date[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, date[8..10], 10) catch return null;
    const civil = civilFromDays(daysFromCivil(y, m, d) - @as(i64, days));
    if (civil.y < 0) return null;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(civil.y)), @as(u32, @intCast(civil.m)), @as(u32, @intCast(civil.d)) }) catch null;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @intFromBool(m <= 2);
    return .{ .y = y, .m = m, .d = d };
}

/// The directory the trends files are under: `MNML_ARTIFACTS_HOME`
/// when set (the e2e driver points it at the test's own root, so a
/// developer's real coverage never paints into a test's statusline),
/// else the shared-state directory, `MNML_SHARED_STATE_DIR` — except
/// under the test runner, where only the first variable counts: a unit
/// test that builds an App on the process environment must not read
/// the developer's own trends files (they widened the row by a chip
/// and cut the position out of a 48-column frame on the author's
/// machine, and on no one else's). Nothing under the home directory is
/// probed for.
fn trendsDir(env: *const std.process.Environ.Map, under_test: bool) ?[]const u8 {
    if (env.get("MNML_ARTIFACTS_HOME")) |v| return if (v.len == 0) null else v;
    if (under_test) return null;
    const v = env.get("MNML_SHARED_STATE_DIR") orelse return null;
    return if (v.len == 0) null else v;
}

fn readJson(comptime T: type, app: *App, arena: Allocator, rel: []const u8) ?T {
    const dir = trendsDir(&app.env, builtin.is_test) orelse return null;
    const path = std.fs.path.join(arena, &.{ dir, rel }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(4 * 1024 * 1024)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(T, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed;
}

/// Read both files when the throttle allows. Frame arena for the parse.
pub fn ensureLoaded(app: *App) void {
    const st = &app.coverage;
    if (st.loaded_at_ms != 0 and app.now_ms - st.loaded_at_ms < reload_ms) return;
    st.loaded_at_ms = if (app.now_ms == 0) 1 else app.now_ms;
    const arena = app.frame.allocator();
    const feature = readJson(FeatureFile, app, arena, "feature-coverage/_trends/trends.json");
    st.feature = if (feature) |f| featureOverall(f) else null;
    st.feature_prev = if (feature) |f| featureAt(f, 7) else null;
    const code = readJson(CodeFile, app, arena, "code-coverage/_trends/trends.json");
    st.code = if (code) |f| codeOverall(f) else null;
    st.code_prev = if (code) |f| codePrev(f) else null;
}

// ─── the chip ────────────────────────────────────────────────────────────

/// One number and where it was.
pub const Reading = struct { now: f64, prev: ?f64 = null };

/// What the chip shows for the mode: the feature reading, the code
/// reading, either or both. Null when there is nothing to show.
pub const Shown = struct { feature: ?Reading = null, code: ?Reading = null };

pub fn shown(app: *App) ?Shown {
    ensureLoaded(app);
    const st = &app.coverage;
    if (st.feature == null and st.code == null) return null;
    const f: ?Reading = if (st.feature) |v| .{ .now = v, .prev = st.feature_prev } else null;
    const c: ?Reading = if (st.code) |v| .{ .now = v, .prev = st.code_prev } else null;
    return switch (app.cfg.ui.coverage_chip_mode) {
        .feature => .{ .feature = f, .code = if (f == null) c else null },
        .code => .{ .code = c, .feature = if (c == null) f else null },
        .both => .{ .feature = f, .code = c },
        .ticker => if (f != null and c != null) (if (@mod(@divTrunc(wallMs(app), ticker_ms), 2) == 0) Shown{ .feature = f } else Shown{ .code = c }) else Shown{ .feature = f, .code = c },
    };
}

/// The ticker's clock: the wall clock, as Rust's (`SystemTime` seconds
/// / 4 % 2), so two editors on one machine show the same half at the
/// same moment — `app.now_ms` is monotonic since boot and put them out
/// of phase. Tests pin it through `State.ticker_clock_ms`.
fn wallMs(app: *const App) i64 {
    return app.coverage.ticker_clock_ms orelse Io.Timestamp.now(app.io, .real).toMilliseconds();
}

pub const Direction = enum { up, down, flat, none };

/// ` ▲1.0` / ` ▼0.3` / ` ±0.0` for a reading with a past, "" without.
pub const Delta = struct { text: []const u8, dir: Direction };

pub fn delta(arena: Allocator, r: Reading) Allocator.Error!Delta {
    const p = r.prev orelse return .{ .text = "", .dir = .none };
    const d = r.now - p;
    const dir: Direction = if (@abs(d) < 0.05) .flat else if (d > 0) .up else .down;
    const arrow: []const u8 = switch (dir) {
        .flat => "±",
        .up => "▲",
        .down, .none => "▼",
    };
    const tenths = roundScaled(@abs(d), 10);
    return .{ .text = try std.fmt.allocPrint(arena, " {s}{d}.{d}", .{ arrow, tenths / 10, tenths % 10 }), .dir = dir };
}

/// `F 83%` — the letter and the rounded percent.
pub fn pct(arena: Allocator, letter: []const u8, v: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s} {d}%", .{ letter, roundScaled(std.math.clamp(v, 0, 100), 1) });
}

/// Rust's `{:.0}` / `{:.1}` of a non-negative double: `v × scale`
/// rounded to the nearest integer on the EXACT value, ties to even —
/// `56.5` reads `56`, `0.15` (a hair under) reads `0.1`, `0.25` reads
/// `0.2`. `std.fmt`'s `{d:.1}` rounds the shortest decimal half away
/// from zero and reads `0.2`, `0.3` — a chip that disagrees with Rust's
/// by a digit at every tie. The value is `m × 2^e`; the round is
/// integer arithmetic on `m × scale` against the half at `2^(-e-1)`.
pub fn roundScaled(v: f64, scale: u64) u64 {
    if (!(v > 0) or v > 1.0e12) return 0;
    const bits: u64 = @bitCast(v);
    const exp_raw: u64 = (bits >> 52) & 0x7ff;
    var mant: u128 = bits & ((@as(u64, 1) << 52) - 1);
    const e: i32 = if (exp_raw == 0) -1074 else blk: {
        mant |= @as(u128, 1) << 52;
        break :blk @as(i32, @intCast(exp_raw)) - 1075;
    };
    const num: u128 = mant * scale;
    if (e >= 0) return @intCast(num << @intCast(e));
    const shift: u32 = @intCast(-e);
    if (shift >= 127) return 0;
    const q = num >> @intCast(shift);
    const rem = num - (q << @intCast(shift));
    const half = @as(u128, 1) << @intCast(shift - 1);
    const up = rem > half or (rem == half and (q & 1) == 1);
    return @intCast(if (up) q + 1 else q);
}

/// The chip's whole text for the mode (`F 79% ▲43.8 · C 75% ±0.0`),
/// or null when there is nothing to show.
pub fn segment(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    const s = shown(app) orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (s.feature) |f| {
        try out.appendSlice(arena, try pct(arena, "F", f.now));
        try out.appendSlice(arena, (try delta(arena, f)).text);
    }
    if (s.code) |c| {
        if (out.items.len > 0) try out.appendSlice(arena, " · ");
        try out.appendSlice(arena, try pct(arena, "C", c.now));
        try out.appendSlice(arena, (try delta(arena, c)).text);
    }
    return out.items;
}

/// The ticker wants a frame at its next flip; the loader at its next read.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.coverage;
    if (st.feature == null and st.code == null) return null;
    if (app.cfg.ui.coverage_chip_mode == .ticker and st.feature != null and st.code != null) {
        // The next flip on the wall clock, as a moment on `now_ms`.
        return app.now_ms + (ticker_ms - @mod(wallMs(app), ticker_ms));
    }
    return null;
}

fn toastCmd(app: *App) CommandError!void {
    ensureLoaded(app);
    const st = &app.coverage;
    if (st.feature == null and st.code == null) return app.diag.fail(app.frame.allocator(), "coverage: no trends.json under $MNML_SHARED_STATE_DIR", .{});
    const arena = app.frame.allocator();
    const f: []const u8 = if (st.feature) |v| try pct(arena, "features", v) else "features —";
    const c: []const u8 = if (st.code) |v| try pct(arena, "code lines", v) else "code lines —";
    app.toast("coverage: {s} · {s}", .{ f, c });
}

/// The chip's right-click: one row per mode, the current one checked.
pub fn openModeMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const modes = comptime std.enums.values(Config.CoverageChipMode);
    const rows = try app.gpa.alloc(command.MenuItem, modes.len);
    errdefer app.gpa.free(rows);
    inline for (modes, 0..) |m, i| rows[i] = .{
        .label = switch (m) {
            .feature => "Feature coverage (F)",
            .code => "Code coverage (C)",
            .both => "Both",
            .ticker => "Ticker (F ⇄ C)",
        },
        .action = .{ .command = switch (m) {
            .both => .@"coverage.chip_show_both",
            .feature => .@"coverage.chip_show_feature",
            .code => .@"coverage.chip_show_code",
            .ticker => .@"coverage.chip_show_ticker",
        } },
        .checked = app.cfg.ui.coverage_chip_mode == m,
    };
    try app.openMenu("Coverage chip", rows, x, y);
}

/// A menu row: the mode, persisted to the home config.
pub fn setMode(app: *App, mode: Config.CoverageChipMode) Allocator.Error!void {
    app.cfg.ui.coverage_chip_mode = mode;
    _ = try settings.persist(app, .home, &.{ "ui", "coverage_chip_mode" }, mode);
    app.needs_render = true;
}

/// `coverage.chip_show_*`: the mode menu's rows and the palette's names
/// for `setMode`, each saying what the chip shows now.
fn modeRunner(comptime mode: Config.CoverageChipMode, comptime label: []const u8) command.CommandFn {
    return &struct {
        fn run(app: *App) command.CommandError!void {
            try setMode(app, mode);
            app.toast(label, .{});
        }
    }.run;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "the coverage chip reads the two trends files in its directory and paints per mode; nothing without them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 12 });
    defer app.deinit();
    try app.env.put("MNML_ARTIFACTS_HOME", root);
    app.now_ms = 10_000;
    try t.expect((try segment(&app, app.frame.allocator())) == null);
    // Two apps: 80/90 (ui/api) over 3 features and 60/— over 1 → (85·3 + 60·1)/4 = 78.75.
    try tmp.dir.createDirPath(t.io, "feature-coverage/_trends");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "feature-coverage/_trends/trends.json", .data =
        \\{"latest_date":"2026-09-01","apps":[
        \\ {"slug":"a","name":"A","series":[{"date":"2026-08-01","features":1,"ui":10,"api":10},{"date":"2026-09-01","features":3,"ui":80,"api":90}]},
        \\ {"slug":"b","name":"B","series":[{"date":"2026-09-01","features":1,"ui":60}]}
        \\]}
    });
    try tmp.dir.createDirPath(t.io, "code-coverage/_trends");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "code-coverage/_trends/trends.json", .data =
        \\{"latest_date":"2026-09-01","apps":[
        \\ {"slug":"a","name":"A","series":[{"date":"2026-09-01","files":3,"lines":70.0}]},
        \\ {"slug":"b","name":"B","series":[{"date":"2026-09-01","files":1,"lines":90.0}]}
        \\]}
    });
    // Throttled: the miss is remembered for five minutes.
    try t.expect((try segment(&app, app.frame.allocator())) == null);
    app.now_ms += reload_ms;
    // Seven days before 2026-09-01 is 08-25: app a's point on or before
    // it is 08-01 (score 10, weight 1); b has one point, which stands in
    // for its past (60, weight 1) → 35, so the feature delta is +43.75.
    // Both code series are single points, so the code delta is flat.
    try t.expectEqualStrings("F 79% ▲43.8", (try segment(&app, app.frame.allocator())).?);
    app.cfg.ui.coverage_chip_mode = .code;
    try t.expectEqualStrings("C 75% ±0.0", (try segment(&app, app.frame.allocator())).?);
    app.cfg.ui.coverage_chip_mode = .both;
    try t.expectEqualStrings("F 79% ▲43.8 · C 75% ±0.0", (try segment(&app, app.frame.allocator())).?);
    app.cfg.ui.coverage_chip_mode = .ticker;
    app.coverage.ticker_clock_ms = 400_000; // an even slot on the wall clock
    try t.expectEqualStrings("F 79% ▲43.8", (try segment(&app, app.frame.allocator())).?);
    app.coverage.ticker_clock_ms.? += ticker_ms + 1000;
    try t.expectEqualStrings("C 75% ±0.0", (try segment(&app, app.frame.allocator())).?);
    // 3 s into the odd slot: the flip is 1 s away on `now_ms`.
    try t.expectEqual(app.now_ms + 3000, nextDeadlineMs(&app).?);
    // The chip is on the statusline, and the click toasts both.
    app.cfg.ui.coverage_chip_mode = .both;
    try app.render();
    const text = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "F 79% ▲43.8 · C 75% ±0.0") != null);
    try command.run(&app, .{ .static = .@"coverage.toast" });
    try t.expectEqualStrings("coverage: features 79% · code lines 75%", app.lastToast().?);
}

test "the trends directory is the shared-state directory, never the home; the test hook wins and only it counts under test" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/u");
    try t.expect(trendsDir(&env, false) == null);
    try env.put("MNML_SHARED_STATE_DIR", "");
    try t.expect(trendsDir(&env, false) == null);
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    try t.expectEqualStrings("/shared", trendsDir(&env, false).?);
    try t.expect(trendsDir(&env, true) == null);
    try env.put("MNML_ARTIFACTS_HOME", "/test-root");
    try t.expectEqualStrings("/test-root", trendsDir(&env, false).?);
    try t.expectEqualStrings("/test-root", trendsDir(&env, true).?);
    try env.put("MNML_ARTIFACTS_HOME", "");
    try t.expect(trendsDir(&env, false) == null);
}

test "the seven-day lookback walks ISO dates across a month boundary; a falling number reads ▼" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("2026-08-25", dateMinusDays(&buf, "2026-09-01", 7).?);
    try t.expectEqualStrings("2025-12-30", dateMinusDays(&buf, "2026-01-06", 7).?);
    try t.expectEqualStrings("2024-02-29", dateMinusDays(&buf, "2024-03-01", 1).?);
    try t.expect(dateMinusDays(&buf, "yesterday", 7) == null);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings(" ▼0.3", (try delta(a, .{ .now = 74.2, .prev = 74.5 })).text);
    try t.expectEqual(Direction.down, (try delta(a, .{ .now = 74.2, .prev = 74.5 })).dir);
    try t.expectEqualStrings(" ±0.0", (try delta(a, .{ .now = 74.2, .prev = 74.21 })).text);
    try t.expectEqualStrings("", (try delta(a, .{ .now = 74.2 })).text);
    try t.expectEqual(Direction.none, (try delta(a, .{ .now = 74.2 })).dir);
}

test "the chip's numbers round as Rust's `{:.0}` / `{:.1}` do: the exact value, ties to even" {
    // `rustc`, 2026-09-07: 56.5→56 57.5→58 0.5→0 2.5→2; 0.05→0.1
    // 0.15→0.1 0.25→0.2 1.05→1.1 56.49→56.5.
    try t.expectEqual(@as(u64, 56), roundScaled(56.5, 1));
    try t.expectEqual(@as(u64, 58), roundScaled(57.5, 1));
    try t.expectEqual(@as(u64, 0), roundScaled(0.5, 1));
    try t.expectEqual(@as(u64, 2), roundScaled(2.5, 1));
    try t.expectEqual(@as(u64, 57), roundScaled(56.51, 1));
    try t.expectEqual(@as(u64, 1), roundScaled(0.05, 10));
    try t.expectEqual(@as(u64, 1), roundScaled(0.15, 10));
    try t.expectEqual(@as(u64, 2), roundScaled(0.25, 10));
    try t.expectEqual(@as(u64, 11), roundScaled(1.05, 10));
    try t.expectEqual(@as(u64, 565), roundScaled(56.49, 10));
    try t.expectEqual(@as(u64, 10), roundScaled(1.0, 10));
    try t.expectEqual(@as(u64, 0), roundScaled(0.0, 10));
    try t.expectEqual(@as(u64, 0), roundScaled(-0.3, 10));
    try t.expectEqual(@as(u64, 0), roundScaled(1.0e-30, 10));
    try t.expectEqual(@as(u64, 1000), roundScaled(100.0, 10));
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The chip's text on fixed inputs: the letter, a space, the percent,
    // then the delta — an arrow or ± and one decimal — after one space.
    try t.expectEqualStrings("F 57%", try pct(a, "F", 57.0));
    try t.expectEqualStrings("F 56%", try pct(a, "F", 56.5));
    try t.expectEqualStrings("C 74%", try pct(a, "C", 74.2));
    try t.expectEqualStrings("C 100%", try pct(a, "C", 250.0));
    try t.expectEqualStrings(" ▲1.0", (try delta(a, .{ .now = 57.0, .prev = 56.0 })).text);
    try t.expectEqualStrings(" ±0.0", (try delta(a, .{ .now = 74.2, .prev = 74.21 })).text);
    try t.expectEqualStrings(" ▲0.2", (try delta(a, .{ .now = 10.25, .prev = 10.0 })).text);
    try t.expectEqualStrings(" ▼43.8", (try delta(a, .{ .now = 35.4, .prev = 79.2 })).text);
    try t.expectEqualStrings(" ▲12.0", (try delta(a, .{ .now = 62.0, .prev = 50.0 })).text);
}

test "coverage.chip_show_* set the chip mode, write it to the home config and say so; the mode menu's rows fire them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"coverage.chip_show_code" });
    try std.testing.expectEqual(Config.CoverageChipMode.code, app.cfg.ui.coverage_chip_mode);
    try std.testing.expectEqualStrings("coverage chip: showing Code only", app.lastToast().?);
    try command.run(&app, .{ .static = .@"coverage.chip_show_both" });
    try std.testing.expectEqual(Config.CoverageChipMode.both, app.cfg.ui.coverage_chip_mode);
    try std.testing.expectEqualStrings("coverage chip: showing Feature + Code", app.lastToast().?);
    try command.run(&app, .{ .static = .@"coverage.chip_show_ticker" });
    try std.testing.expectEqual(Config.CoverageChipMode.ticker, app.cfg.ui.coverage_chip_mode);
    try std.testing.expectEqualStrings("coverage chip: ticker (F ⇄ C)", app.lastToast().?);
    try command.run(&app, .{ .static = .@"coverage.chip_show_feature" });
    try std.testing.expectEqual(Config.CoverageChipMode.feature, app.cfg.ui.coverage_chip_mode);
    try std.testing.expectEqualStrings("coverage chip: showing Feature only", app.lastToast().?);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(app.frame.allocator(), &.{ root, "config.zon" }), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".coverage_chip_mode = .feature") != null);
    // The menu: one row per mode, each a command, the current one checked.
    try openModeMenu(&app, 3, 4);
    try std.testing.expect(app.overlay == .menu);
    try std.testing.expectEqual(@as(usize, 4), app.overlay.menu.items.len);
    try std.testing.expectEqual(command.CommandId.@"coverage.chip_show_ticker", app.overlay.menu.items[3].action.command);
    try std.testing.expect(app.overlay.menu.items[1].checked);
}
