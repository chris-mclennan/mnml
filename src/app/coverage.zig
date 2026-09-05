//! The statusline coverage chip — `F 83%` (feature coverage) and
//! `C 71%` (Istanbul lines), from the two `trends.json` files the Rust
//! chip read: `<home>/.tattle-claude-artifacts/feature-coverage/_trends/
//! trends.json` and `…/code-coverage/_trends/trends.json`. Either may be
//! absent (no sync, a non-acmeco user): its number is simply not
//! shown; with neither the chip is not painted. The files are re-read
//! every five minutes at most, whatever the outcome.
//!
//! `ui.coverage_chip_mode` picks the shape: `feature` / `code` (one
//! number), `both` (`F 83% · C 71%`), `ticker` (F ⇄ C every four
//! seconds). A click toasts both numbers; a right-click picks the mode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const settings = @import("settings.zig");

pub const reload_ms: i64 = 300_000;
pub const ticker_ms: i64 = 4000;
pub const artifacts_dir = ".tattle-claude-artifacts";

pub const State = struct {
    feature: ?f64 = null,
    code: ?f64 = null,
    /// The loop clock at the last read attempt; 0 = never.
    loaded_at_ms: i64 = 0,
};

pub const table = .{
    .@"coverage.toast" = &toastCmd,
    .@"coverage.mode_menu" = &modeMenuCmd,
};

// ─── the files ───────────────────────────────────────────────────────────

const FeaturePoint = struct { ui: ?f64 = null, api: ?f64 = null, features: u32 = 0 };
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

/// The directory holding `.tattle-claude-artifacts`: `MNML_ARTIFACTS_HOME`
/// when set (the e2e driver points it at the test's own root, so a
/// developer's real coverage never paints into a test's statusline),
/// else the home directory.
fn artifactsHome(app: *App) ?[]const u8 {
    if (app.env.get("MNML_ARTIFACTS_HOME")) |v| return if (v.len == 0) null else v;
    return app.homeDir() orelse app.env.get("HOME");
}

fn readJson(comptime T: type, app: *App, arena: Allocator, rel: []const u8) ?T {
    const home = artifactsHome(app) orelse return null;
    const path = std.fs.path.join(arena, &.{ home, artifacts_dir, rel }) catch return null;
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
    st.feature = if (readJson(FeatureFile, app, arena, "feature-coverage/_trends/trends.json")) |f| featureOverall(f) else null;
    st.code = if (readJson(CodeFile, app, arena, "code-coverage/_trends/trends.json")) |f| codeOverall(f) else null;
}

// ─── the chip ────────────────────────────────────────────────────────────

fn pct(arena: Allocator, letter: []const u8, v: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s} {d}%", .{ letter, @as(u64, @intFromFloat(@round(std.math.clamp(v, 0, 100)))) });
}

/// The statusline text for the mode, or null when there is nothing to show.
pub fn segment(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    ensureLoaded(app);
    const st = &app.coverage;
    if (st.feature == null and st.code == null) return null;
    const f: ?[]const u8 = if (st.feature) |v| try pct(arena, "F", v) else null;
    const c: ?[]const u8 = if (st.code) |v| try pct(arena, "C", v) else null;
    return switch (app.cfg.ui.coverage_chip_mode) {
        .feature => f orelse c,
        .code => c orelse f,
        .both => if (f != null and c != null) try std.fmt.allocPrint(arena, "{s} · {s}", .{ f.?, c.? }) else f orelse c,
        .ticker => if (f != null and c != null) (if (@mod(@divTrunc(app.now_ms, ticker_ms), 2) == 0) f.? else c.?) else f orelse c,
    };
}

/// The ticker wants a frame at its next flip; the loader at its next read.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.coverage;
    if (st.feature == null and st.code == null) return null;
    if (app.cfg.ui.coverage_chip_mode == .ticker and st.feature != null and st.code != null) {
        return (@divTrunc(app.now_ms, ticker_ms) + 1) * ticker_ms;
    }
    return null;
}

fn toastCmd(app: *App) CommandError!void {
    ensureLoaded(app);
    const st = &app.coverage;
    if (st.feature == null and st.code == null) return app.diag.fail(app.frame.allocator(), "coverage: no trends.json under ~/{s}", .{artifacts_dir});
    const arena = app.frame.allocator();
    const f: []const u8 = if (st.feature) |v| try pct(arena, "features", v) else "features —";
    const c: []const u8 = if (st.code) |v| try pct(arena, "code lines", v) else "code lines —";
    app.toast("coverage: {s} · {s}", .{ f, c });
}

fn modeMenuCmd(app: *App) CommandError!void {
    try openModeMenu(app, app.screen.width -| 20, app.screen.height -| 2);
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
        .action = .{ .set_coverage_mode = m },
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

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "the coverage chip reads the two trends files under HOME and paints per mode; nothing without them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 12 });
    defer app.deinit();
    try app.env.put("HOME", root);
    app.now_ms = 10_000;
    try t.expect((try segment(&app, app.frame.allocator())) == null);
    // Two apps: 80/90 (ui/api) over 3 features and 60/— over 1 → (85·3 + 60·1)/4 = 78.75.
    try tmp.dir.createDirPath(t.io, artifacts_dir ++ "/feature-coverage/_trends");
    try tmp.dir.writeFile(t.io, .{ .sub_path = artifacts_dir ++ "/feature-coverage/_trends/trends.json", .data =
        \\{"latest_date":"2026-09-01","apps":[
        \\ {"slug":"a","name":"A","series":[{"date":"2026-08-01","features":1,"ui":10,"api":10},{"date":"2026-09-01","features":3,"ui":80,"api":90}]},
        \\ {"slug":"b","name":"B","series":[{"date":"2026-09-01","features":1,"ui":60}]}
        \\]}
    });
    try tmp.dir.createDirPath(t.io, artifacts_dir ++ "/code-coverage/_trends");
    try tmp.dir.writeFile(t.io, .{ .sub_path = artifacts_dir ++ "/code-coverage/_trends/trends.json", .data =
        \\{"latest_date":"2026-09-01","apps":[
        \\ {"slug":"a","name":"A","series":[{"date":"2026-09-01","files":3,"lines":70.0}]},
        \\ {"slug":"b","name":"B","series":[{"date":"2026-09-01","files":1,"lines":90.0}]}
        \\]}
    });
    // Throttled: the miss is remembered for five minutes.
    try t.expect((try segment(&app, app.frame.allocator())) == null);
    app.now_ms += reload_ms;
    try t.expectEqualStrings("F 79%", (try segment(&app, app.frame.allocator())).?);
    app.cfg.ui.coverage_chip_mode = .code;
    try t.expectEqualStrings("C 75%", (try segment(&app, app.frame.allocator())).?);
    app.cfg.ui.coverage_chip_mode = .both;
    try t.expectEqualStrings("F 79% · C 75%", (try segment(&app, app.frame.allocator())).?);
    app.cfg.ui.coverage_chip_mode = .ticker;
    app.now_ms = 400_000; // an even slot
    try t.expectEqualStrings("F 79%", (try segment(&app, app.frame.allocator())).?);
    app.now_ms += ticker_ms;
    try t.expectEqualStrings("C 75%", (try segment(&app, app.frame.allocator())).?);
    try t.expectEqual(@as(i64, 408_000), nextDeadlineMs(&app).?);
    // The chip is on the statusline, and the click toasts both.
    app.cfg.ui.coverage_chip_mode = .both;
    try app.render();
    const text = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "F 79% · C 75%") != null);
    try command.run(&app, .{ .static = .@"coverage.toast" });
    try t.expectEqualStrings("coverage: features 79% · code lines 75%", app.lastToast().?);
}
