//! The stress meter — how long a frame takes. `App.renderInto` pushes
//! every render's duration into a rolling window of `window` samples;
//! the statusline paints a four-block bar from the p95 (green under
//! 20 ms, then 40, then 70, red above) behind `ui.stress_meter`. The
//! `perf.*` commands reset it, read it out, hide it and toggle it.
//!
//! // changed: Rust sampled tick + draw + the event wait from the loop.
//! Here the sample is the render alone, taken where the frame is made,
//! so the `.test` runner and the headless loop measure the same thing
//! as the terminal loop without any of them having to time anything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const window: usize = 120;

pub const Meter = struct {
    /// Microseconds, a ring: `head` is the next slot to write.
    samples: [window]u32 = undefined,
    len: usize = 0,
    head: usize = 0,

    pub fn push(m: *Meter, us: u32) void {
        m.samples[m.head] = us;
        m.head = (m.head + 1) % window;
        if (m.len < window) m.len += 1;
    }

    pub fn reset(m: *Meter) void {
        m.len = 0;
        m.head = 0;
    }

    pub const Stats = struct { p50_us: u32, p95_us: u32, max_us: u32, count: usize };

    pub fn stats(m: *const Meter) ?Stats {
        if (m.len == 0) return null;
        var sorted: [window]u32 = undefined;
        @memcpy(sorted[0..m.len], m.samples[0..m.len]);
        std.mem.sort(u32, sorted[0..m.len], {}, std.sort.asc(u32));
        return .{
            .p50_us = sorted[(m.len - 1) / 2],
            .p95_us = sorted[(m.len - 1) * 95 / 100],
            .max_us = sorted[m.len - 1],
            .count = m.len,
        };
    }

    /// How many of the four blocks light up for a p95.
    pub fn level(p95_us: u32) u8 {
        const ms = p95_us / 1000;
        if (ms < 20) return 1;
        if (ms < 40) return 2;
        if (ms < 70) return 3;
        return 4;
    }
};

/// The statusline segment: the bar (`▂▄▆█`, unlit blocks as `·`) and
/// the p95 in ms. Null when hidden or empty.
pub fn segment(app: *App, arena: Allocator, ascii: bool) Allocator.Error!?[]const u8 {
    if (!app.cfg.ui.stress_meter) return null;
    const s = app.stress.stats() orelse return null;
    const lit = Meter.level(s.p95_us);
    const blocks: [4][]const u8 = if (ascii) .{ "_", "-", "=", "#" } else .{ "▂", "▄", "▆", "█" };
    var out: std.Io.Writer.Allocating = .init(arena);
    for (blocks, 1..) |b, i| out.writer.writeAll(if (i <= lit) b else "·") catch return error.OutOfMemory;
    out.writer.print(" {d}.{d}ms", .{ s.p95_us / 1000, (s.p95_us % 1000) / 100 }) catch return error.OutOfMemory;
    return out.written();
}

pub const table = .{
    .@"perf.reset_stress" = &reset,
    .@"perf.toast_stress" = &toastStats,
    .@"perf.hide_stress" = &hide,
    .@"perf.toggle_stress" = &toggle,
};

fn reset(app: *App) CommandError!void {
    app.stress.reset();
    app.toast("stress meter: reset", .{});
}

fn toastStats(app: *App) CommandError!void {
    const s = app.stress.stats() orelse return app.diag.fail(app.frame.allocator(), "stress meter: no frames sampled yet", .{});
    app.toast("frames: p50 {d}.{d}ms · p95 {d}.{d}ms · max {d}.{d}ms · n={d}", .{
        s.p50_us / 1000, (s.p50_us % 1000) / 100,
        s.p95_us / 1000, (s.p95_us % 1000) / 100,
        s.max_us / 1000, (s.max_us % 1000) / 100,
        s.count,
    });
}

fn hide(app: *App) CommandError!void {
    app.cfg.ui.stress_meter = false;
    app.needs_render = true;
}

fn toggle(app: *App) CommandError!void {
    app.cfg.ui.stress_meter = !app.cfg.ui.stress_meter;
    app.toast("stress meter {s}", .{if (app.cfg.ui.stress_meter) "on" else "off"});
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "meter: percentiles over a ring that wraps, and the level thresholds" {
    var m: Meter = .{};
    try t.expect(m.stats() == null);
    var i: u32 = 0;
    while (i < 300) : (i += 1) m.push(i * 1000);
    const s = m.stats().?;
    try t.expectEqual(window, s.count);
    try t.expectEqual(@as(u32, 299_000), s.max_us);
    try t.expect(s.p50_us >= 230_000 and s.p50_us <= 250_000);
    try t.expect(s.p95_us >= 290_000);
    try t.expectEqual(@as(u8, 1), Meter.level(19_999));
    try t.expectEqual(@as(u8, 2), Meter.level(20_000));
    try t.expectEqual(@as(u8, 3), Meter.level(45_000));
    try t.expectEqual(@as(u8, 4), Meter.level(70_000));
    m.reset();
    try t.expect(m.stats() == null);
}

test "the statusline shows the bar only behind ui.stress_meter, and every render samples" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 20 });
    defer app.deinit();
    _ = try app.openScratch();
    try app.render();
    try t.expect(app.stress.len >= 1);
    try t.expect((try segment(&app, app.frame.allocator(), true)) == null);
    try command.run(&app, .{ .static = .@"perf.toggle_stress" });
    const seg = (try segment(&app, app.frame.allocator(), true)).?;
    try t.expect(std.mem.startsWith(u8, seg, "_"));
    try t.expect(std.mem.endsWith(u8, seg, "ms"));
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "ms") != null);
    try command.run(&app, .{ .static = .@"perf.toast_stress" });
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "frames: p50"));
    try command.run(&app, .{ .static = .@"perf.reset_stress" });
    try t.expectEqual(@as(usize, 0), app.stress.len);
    try command.run(&app, .{ .static = .@"perf.hide_stress" });
    try t.expect(!app.cfg.ui.stress_meter);
}
