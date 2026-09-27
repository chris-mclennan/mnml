//! The statusline clock beside the bell: `HH:MM` local time, or UTC
//! (`HH:MMZ`), or hidden. `ui.clock` seeds it (true = local); the
//! `clock.*` commands and the chip's menu switch it. The frame is due
//! again on the next minute boundary while the clock shows.
//!
//! // changed: the std library has no time-zone reader, so local time
//! comes from libc (`core/localtime.zig`: `localtime_r` on POSIX, the
//! CRT's `_localtime64_s` on Windows). `clock.utc` is a session choice
//! — the config carries `ui.clock` (on / off) and no zone key, as the
//! Rust config did not. The git graph's DATE / TIME column follows the
//! same choice (`utc`), so the two clocks on one screen agree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const settings = @import("settings.zig");
const localtime = @import("../core/localtime.zig");

pub const Mode = enum { local, utc, hidden };

pub const State = struct {
    mode: Mode = .local,
    /// The minute the last frame painted, so a new one asks for a frame.
    shown_minute: i64 = -1,
};

pub const table = .{
    .@"clock.local" = &localCmd,
    .@"clock.utc" = &utcCmd,
    .@"clock.hide" = &hideCmd,
    .@"clock.menu" = &menuCmd,
};

/// `ui.clock` → the mode: on is local, off is hidden. A UTC pick made
/// this session survives a config reload that keeps the clock on.
pub fn seed(app: *App) void {
    if (!app.cfg.ui.clock) {
        app.clock.mode = .hidden;
    } else if (app.clock.mode == .hidden) {
        app.clock.mode = .local;
    }
}

// ─── time ────────────────────────────────────────────────────────────────

/// Seconds east of UTC for `secs`, per libc; 0 when libc cannot say.
pub const localOffset = localtime.offset;

/// Is the clock reading UTC? Every wall clock the app paints asks this
/// one question.
pub fn inUtc(app: *const App) bool {
    return app.clock.mode == .utc;
}

/// Wall-clock seconds now.
fn wallSecs(app: *App) i64 {
    return std.Io.Timestamp.now(app.io, .real).toSeconds();
}

/// `HH:MM` for `secs` shifted by `offset`; `HH:MMZ` when `utc`.
pub fn format(arena: Allocator, secs: i64, offset: i64, utc: bool) Allocator.Error![]const u8 {
    const shifted = secs + offset;
    const day = @mod(shifted, 86_400);
    const h: u64 = @intCast(@divTrunc(day, 3600));
    const m: u64 = @intCast(@divTrunc(@mod(day, 3600), 60));
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}{s}", .{ h, m, if (utc) "Z" else "" });
}

/// The statusline segment, or null when hidden.
pub fn segment(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (app.clock.mode == .hidden) return null;
    const secs = wallSecs(app);
    const in_utc = inUtc(app);
    app.clock.shown_minute = @divTrunc(secs + (if (in_utc) 0 else localOffset(secs)), 60);
    return try format(arena, secs, if (in_utc) 0 else localOffset(secs), in_utc);
}

/// The next minute boundary, on the loop's clock, while the clock shows.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    if (app.clock.mode == .hidden) return null;
    const secs = std.Io.Timestamp.now(app.io, .real).toSeconds();
    const into: i64 = @mod(secs, 60);
    return app.now_ms + (60 - into) * 1000;
}

/// Every tick: a new minute wants a frame.
pub fn tick(app: *App) void {
    if (app.clock.mode == .hidden) return;
    const secs = wallSecs(app);
    const minute = @divTrunc(secs + (if (inUtc(app)) 0 else localOffset(secs)), 60);
    if (minute != app.clock.shown_minute) app.needs_render = true;
}

// ─── commands ────────────────────────────────────────────────────────────

fn set(app: *App, mode: Mode) Allocator.Error!void {
    app.clock.mode = mode;
    app.cfg.ui.clock = mode != .hidden;
    _ = try settings.persist(app, .home, &.{ "ui", "clock" }, app.cfg.ui.clock);
    app.toast("clock: {s}", .{switch (mode) {
        .local => "local time",
        .utc => "UTC",
        .hidden => "hidden",
    }});
    app.needs_render = true;
}

fn localCmd(app: *App) CommandError!void {
    try set(app, .local);
}

fn utcCmd(app: *App) CommandError!void {
    try set(app, .utc);
}

fn hideCmd(app: *App) CommandError!void {
    try set(app, .hidden);
}

/// `clock.menu`: the chip's menu, anchored at the statusline's right end.
fn menuCmd(app: *App) CommandError!void {
    try openMenu(app, app.screen.width -| 12, app.screen.height -| 2);
}

/// Local ✓ / UTC ✓ / Hide — the chip's right-click.
pub fn openMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Local time", .action = .{ .command = .@"clock.local" }, .checked = app.clock.mode == .local },
        .{ .label = "UTC", .action = .{ .command = .@"clock.utc" }, .checked = app.clock.mode == .utc },
        .{ .label = "Hide the clock", .action = .{ .command = .@"clock.hide" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Clock", rows, x, y);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "format: HH:MM with the offset applied, a Z for UTC, wrapping past midnight" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 1970-01-01 23:30:00 UTC.
    const secs: i64 = 23 * 3600 + 30 * 60;
    try t.expectEqualStrings("23:30Z", try format(a, secs, 0, true));
    try t.expectEqualStrings("00:30", try format(a, secs, 3600, false));
    try t.expectEqualStrings("18:30", try format(a, secs, -5 * 3600, false));
}

test "the clock: on by default beside the bell; utc / hide / local switch it, the config follows; ui.clock = false seeds it hidden" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try t.expectEqual(Mode.local, app.clock.mode);
    const seg = (try segment(&app, app.frame.allocator())).?;
    try t.expectEqual(@as(usize, 5), seg.len);
    try t.expectEqual(@as(u8, ':'), seg[2]);
    try t.expect(nextDeadlineMs(&app) != null);
    try command.run(&app, .{ .static = .@"clock.utc" });
    const z = (try segment(&app, app.frame.allocator())).?;
    try t.expectEqual(@as(u8, 'Z'), z[z.len - 1]);
    try command.run(&app, .{ .static = .@"clock.hide" });
    try t.expect((try segment(&app, app.frame.allocator())) == null);
    try t.expect(nextDeadlineMs(&app) == null);
    try t.expect(!app.cfg.ui.clock);
    // Owned: `configPath` answers on the frame arena, and the steps
    // below render frames before it is read again.
    const home = try t.allocator.dupe(u8, (try settings.configPath(&app, .home)).?);
    defer t.allocator.free(home);
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".clock = false") != null);
    try command.run(&app, .{ .static = .@"clock.local" });
    try t.expectEqual(Mode.local, app.clock.mode);
    try t.expect(app.cfg.ui.clock);
    // The menu lists the three, the current one checked.
    try command.run(&app, .{ .static = .@"clock.menu" });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Clock", app.overlay.menu.title);
    try t.expect(app.overlay.menu.items[0].checked);
    try t.expect(!app.overlay.menu.items[1].checked);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // `ui.clock = false` seeds it hidden.
    var cfg: app_mod.Config = .{};
    cfg.ui.clock = false;
    var quiet = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .cols = 100, .rows = 12 });
    defer quiet.deinit();
    try t.expectEqual(Mode.hidden, quiet.clock.mode);
}
