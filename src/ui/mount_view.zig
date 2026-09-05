//! `Pane.mount` — paints the grid a mounted integration sent, cell by
//! cell through the canvas (which folds rgb onto the 256-cube when the
//! terminal has no truecolor), and registers one `.script_hit` per row
//! so a click can be turned back into pane-relative cells. The last
//! row carries the exit banner once the sibling is gone; a pane still
//! waiting for its first frame says so in the middle.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const host = @import("../bridge/host.zig");
const wire = @import("../bridge/wire.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;
const Style = vaxis.Style;
const Color = vaxis.Color;

pub const Props = struct {
    focused: bool,
    /// The first frame has not arrived.
    waiting: bool,
    /// `[exited] — any key closes` when set.
    exit_label: ?[]const u8 = null,
    cursor: ?wire.Cursor = null,
};

/// One-byte graphemes without allocating: ASCII cells point here.
const ascii_table: [128][1]u8 = blk: {
    var tbl: [128][1]u8 = undefined;
    for (&tbl, 0..) |*b, i| b.* = .{@intCast(i)};
    break :blk tbl;
};

pub fn colorOf(c: ?wire.Color, fallback: Color) Color {
    const v = c orelse return fallback;
    return switch (v) {
        .index => |i| .{ .index = i },
        .rgb => |rgb| .{ .rgb = rgb },
    };
}

pub fn styleOf(cell: *const host.Cell, th: *const Theme) Style {
    return .{
        .fg = colorOf(cell.fg, th.fg.fg),
        .bg = colorOf(cell.bg, th.bg.bg),
        .bold = cell.mods.bold,
        .dim = cell.mods.dim,
        .italic = cell.mods.italic,
        .blink = cell.mods.slow_blink or cell.mods.rapid_blink,
        .reverse = cell.mods.reverse,
        .invisible = cell.mods.hidden,
        .strikethrough = cell.mods.strikethrough,
        .ul_style = if (cell.mods.underline) .single else .off,
    };
}

/// The grapheme bytes of a cell: the static table for ASCII, the frame
/// arena otherwise (the grid may change under the next handler).
fn graphemeOf(ui: Ui, cell: *const host.Cell) ?[]const u8 {
    const s = cell.symbol();
    if (s.len == 0) return null;
    if (s.len == 1) return if (s[0] < 128) &ascii_table[s[0]] else null;
    return ui.arena.dupe(u8, s) catch null;
}

/// Paints the grid clipped to `area`; returns where the terminal
/// cursor goes when the pane has focus and the sibling placed one.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, grid: *const host.Grid, p: Props) ?struct { x: u16, y: u16 } {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return null;
    const rows: u16 = @min(grid.rows, area.h);
    const cols: u16 = @min(grid.cols, area.w);
    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        const row_rect = area.row(y);
        var x: u16 = 0;
        while (x < cols) : (x += 1) {
            const cell = grid.cell(x, y);
            const style = styleOf(cell, th);
            const g = graphemeOf(ui, cell) orelse {
                // A wide glyph's tail (empty symbol): the head painted it.
                if (cell.symbol().len == 0) continue;
                ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
                continue;
            };
            ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = g, .width = 0 }, .style = style });
        }
        ui.hit(row_rect, .{ .script_hit = .{ .pane = pane, .id = y } });
    }
    // Rows the grid does not cover still route clicks (as the pane).
    while (y < area.h) : (y += 1) ui.hit(area.row(y), .{ .script_hit = .{ .pane = pane, .id = y } });

    if (p.waiting and p.exit_label == null) {
        const msg: []const u8 = if (ui.ascii) "waiting for the integration..." else "waiting for the integration…";
        const w = @min(ui.width(msg), area.w);
        const cx = area.x + (area.w - w) / 2;
        const cy = area.y + area.h / 2;
        _ = ui.putStr(cx, cy, w, ui.clipStr(msg, w), th.muted);
    }
    if (p.exit_label) |label| {
        const r = area.row(area.h - 1);
        ui.fill(r, th.statusline);
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(label, r.w), Theme.onBg(th.warn_fg, th.statusline.bg));
        return null;
    }
    if (p.focused) if (p.cursor) |c| {
        if (c.x < area.w and c.y < area.h) return .{ .x = area.x + c.x, .y = area.y + c.y };
    };
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "draw paints the grid clipped to the area, one hit per row, and the exit banner on the last row" {
    var f = try Fixture.init(10, 4);
    defer f.deinit();
    const gpa = testing.allocator;
    var grid: host.Grid = .{};
    defer grid.deinit(gpa);
    const r0 = [_]wire.Cell{ .{ .symbol = "H", .fg = .{ .rgb = .{ 1, 2, 3 } }, .mods = .{ .bold = true } }, .{ .symbol = "i" }, .{ .symbol = "漢" }, .{ .symbol = "" } };
    const r1 = [_]wire.Cell{ .{ .symbol = "0" }, .{ .symbol = "1" }, .{ .symbol = "2" }, .{ .symbol = "3" }, .{ .symbol = "4" }, .{ .symbol = "5" }, .{ .symbol = "6" }, .{ .symbol = "7" }, .{ .symbol = "8" }, .{ .symbol = "9" }, .{ .symbol = "X" } };
    try grid.applyFull(gpa, &.{ &r0, &r1, &r0, &r1, &r1 });
    const area = Rect.init(1, 0, 8, 3);
    const cur = draw(f.ui(), 7, area, &grid, .{ .focused = true, .waiting = false, .cursor = .{ .x = 1, .y = 1 } });
    try f.expectRow(0, " Hi漢");
    try f.expectRow(1, " 01234567");
    try f.expectRow(2, " Hi漢");
    try f.expectRow(3, "");
    try testing.expectEqual(@as(u16, 2), cur.?.x);
    try testing.expectEqual(@as(u16, 1), cur.?.y);
    try testing.expect(f.hits.at(3, 1).?.script_hit.id == 1);
    try testing.expectEqual(@as(u32, 7), f.hits.at(3, 1).?.script_hit.pane);
    try testing.expect(f.hits.at(0, 1) == null);
    const head = f.style(1, 0);
    try testing.expect(head.bold);
    try testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, head.fg);
    _ = draw(f.ui(), 7, area, &grid, .{ .focused = true, .waiting = false, .exit_label = "[exited] — any key closes" });
    try f.expectRow(2, " [exited…");
}

test "an empty grid says it is waiting" {
    var f = try Fixture.init(40, 3);
    defer f.deinit();
    const grid: host.Grid = .{};
    _ = draw(f.ui(), 1, f.full(), &grid, .{ .focused = false, .waiting = true });
    try f.expectContains("waiting for the integration");
}
