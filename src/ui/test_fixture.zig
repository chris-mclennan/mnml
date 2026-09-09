//! Test fixture for ui components: a headless `vaxis.Screen`, a `HitMap`,
//! a frame arena and the default theme, all on `std.testing.allocator`
//! so a leak fails the test. `ui()` hands out the `Ui` a component
//! expects; the row helpers read the painted cells back as text.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Canvas = @import("canvas.zig");
const Theme = @import("theme.zig");
const HitMap = @import("hit.zig").HitMap;
const Ui = @import("context.zig");

const testing = std.testing;

const Fixture = @This();

screen: vaxis.Screen,
hits: HitMap = .{},
arena_state: std.heap.ArenaAllocator,
theme: Theme = Theme.default,
ascii: bool = false,
nerd_font: bool = true,
triangle: bool = false,
hover: ?struct { x: u16, y: u16 } = null,

pub fn init(w: u16, h: u16) !Fixture {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .cols = w, .rows = h, .x_pixel = 0, .y_pixel = 0 });
    screen.width_method = .unicode;
    return .{ .screen = screen, .arena_state = .init(testing.allocator) };
}

pub fn deinit(f: *Fixture) void {
    f.screen.deinit(testing.allocator);
    f.arena_state.deinit();
}

pub fn ui(f: *Fixture) Ui {
    return .{
        .canvas = Canvas.init(&f.screen, .{}),
        .hits = &f.hits,
        .theme = &f.theme,
        .arena = f.arena_state.allocator(),
        .focus = .{ .pane = 0 },
        .hover = if (f.hover) |h| .{ .x = h.x, .y = h.y } else null,
        .ascii = f.ascii,
        .nerd_font = f.nerd_font,
        .triangle = f.triangle,
    };
}

pub fn full(f: *Fixture) Rect {
    return .{ .x = 0, .y = 0, .w = f.screen.width, .h = f.screen.height };
}

/// Row `y` as text, trailing spaces trimmed. Uses a caller buffer so
/// nothing is allocated.
pub fn row(f: *Fixture, y: u16, buf: []u8) []const u8 {
    return Canvas.rowText(&f.screen, y, buf);
}

pub fn expectRow(f: *Fixture, y: u16, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(expected, f.row(y, &buf));
}

pub fn expectRows(f: *Fixture, expected: []const []const u8) !void {
    for (expected, 0..) |want, y| try f.expectRow(@intCast(y), want);
}

/// The whole screen as one string (rows joined by `\n`), on the frame
/// arena — for `contains` checks like the gate's `expect screen`.
pub fn text(f: *Fixture) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const a = f.arena_state.allocator();
    var buf: [1024]u8 = undefined;
    var y: u16 = 0;
    while (y < f.screen.height) : (y += 1) {
        if (y > 0) try out.append(a, '\n');
        try out.appendSlice(a, f.row(y, &buf));
    }
    return out.items;
}

pub fn expectContains(f: *Fixture, needle: []const u8) !void {
    const t = try f.text();
    if (std.mem.indexOf(u8, t, needle) == null) {
        std.debug.print("screen lacks {s}:\n{s}\n", .{ needle, t });
        return error.TestExpectedContains;
    }
}

pub fn expectLacks(f: *Fixture, needle: []const u8) !void {
    const t = try f.text();
    if (std.mem.indexOf(u8, t, needle) != null) {
        std.debug.print("screen contains {s}:\n{s}\n", .{ needle, t });
        return error.TestExpectedLacks;
    }
}

pub fn cell(f: *Fixture, x: u16, y: u16) vaxis.Cell {
    return f.screen.readCell(x, y) orelse @panic("cell out of range");
}

pub fn style(f: *Fixture, x: u16, y: u16) vaxis.Style {
    return f.cell(x, y).style;
}

pub fn bgEql(f: *Fixture, x: u16, y: u16, s: vaxis.Style) bool {
    return vaxis.Color.eql(f.style(x, y).bg, s.bg);
}

pub fn fgEql(f: *Fixture, x: u16, y: u16, s: vaxis.Style) bool {
    return vaxis.Color.eql(f.style(x, y).fg, s.fg);
}

/// Every row from `y0` up to `y1` has the vertical bar's glyph in
/// column `bar_x` and a blank in the cell before it — the cell of air
/// every list keeps between its text and its scrollbar. Prints the
/// offending row on failure.
pub fn expectAirBeforeBar(f: *Fixture, y0: u16, y1: u16, bar_x: u16) !void {
    var y = y0;
    while (y < y1) : (y += 1) {
        const bar = f.cell(bar_x, y).char.grapheme;
        const before = f.cell(bar_x - 1, y).char.grapheme;
        const bar_ok = std.mem.eql(u8, bar, "█") or std.mem.eql(u8, bar, "|") or std.mem.eql(u8, bar, "#");
        const air_ok = std.mem.eql(u8, before, " ") or before.len == 0;
        if (!bar_ok or !air_ok) {
            var buf: [1024]u8 = undefined;
            std.debug.print("row {d} is {s} (bar {s}, before it {s})\n", .{ y, f.row(y, &buf), bar, before });
            return error.TestNoAirBeforeBar;
        }
    }
}

/// Dumps the screen — for a failing test's message.
pub fn dump(f: *Fixture) void {
    const t = f.text() catch return;
    std.debug.print("\n{s}\n", .{t});
}
