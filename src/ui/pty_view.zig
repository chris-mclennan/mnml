//! PtyView — a terminal grid painted cell by cell onto the canvas. The
//! grid is ghostty's render state read out as plain cells (`pty.Grid`);
//! this file only maps colours and attributes onto `vaxis.Style` and
//! handles wide cells, so the pane's own bookkeeping never touches the
//! screen.
//!
//! A cell with the terminal's default colours takes the theme's, so a
//! shell sits on the same ground as an editor pane. An `exit_label`
//! paints a one-row banner over the bottom of the pane.

const std = @import("std");
const vaxis = @import("vaxis");
const pty = @import("pty");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;

pub const Cursor = struct { x: u16, y: u16, shape: enum { block, bar, underline } };

pub const Props = struct {
    focused: bool,
    /// `[exited 0]` — painted on the last row when set.
    exit_label: ?[]const u8 = null,
};

/// One-byte graphemes without allocating: ASCII cells point here.
const ascii_table: [128][1]u8 = blk: {
    var tbl: [128][1]u8 = undefined;
    for (&tbl, 0..) |*b, i| b.* = .{@intCast(i)};
    break :blk tbl;
};

fn colorOf(c: pty.grid.Color, fallback: Color) Color {
    return switch (c) {
        .default => fallback,
        .palette => |i| .{ .index = i },
        .rgb => |v| .{ .rgb = .{ v.r, v.g, v.b } },
    };
}

fn styleOf(cell: pty.grid.Cell, th: *const Theme) Style {
    var s: Style = .{
        .fg = colorOf(cell.fg, th.fg.fg),
        .bg = colorOf(cell.bg, th.bg.bg),
        .ul = colorOf(cell.underline_color, .default),
        .bold = cell.bold,
        .dim = cell.faint,
        .italic = cell.italic,
        .blink = cell.blink,
        .reverse = cell.inverse,
        .invisible = cell.invisible,
        .strikethrough = cell.strikethrough,
    };
    s.ul_style = switch (cell.underline) {
        .none => .off,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
    return s;
}

/// The grapheme bytes of a cell, on the frame arena unless ASCII.
fn graphemeOf(ui: Ui, cell: pty.grid.Cell) ?[]const u8 {
    if (cell.cp == 0) return null;
    if (cell.grapheme.len > 1) {
        var out = std.ArrayListUnmanaged(u8).empty;
        for (cell.grapheme) |cp| {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
            out.appendSlice(ui.arena, tmp[0..n]) catch return null;
        }
        return out.items;
    }
    if (cell.cp < 128) return &ascii_table[cell.cp];
    const buf = ui.arena.alloc(u8, 4) catch return null;
    const n = std.unicode.utf8Encode(cell.cp, buf[0..4]) catch return null;
    return buf[0..n];
}

/// Paint `grid` into `area`. Returns the terminal cursor's screen
/// position when it is visible and inside the area.
pub fn draw(ui: Ui, area: Rect, grid: *const pty.Grid, props: Props) ?Cursor {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return null;
    const rows: u16 = @min(grid.rows(), area.h);
    const cols: u16 = @min(grid.cols(), area.w);
    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        var x: u16 = 0;
        while (x < cols) : (x += 1) {
            const cell = grid.cell(x, y);
            switch (cell.wide) {
                .spacer_tail, .spacer_head => continue,
                .narrow, .wide => {},
            }
            const style = styleOf(cell, th);
            const g = graphemeOf(ui, cell) orelse {
                ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
                continue;
            };
            const width: u8 = if (cell.wide == .wide) 2 else 1;
            ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = g, .width = width }, .style = style });
        }
    }
    if (props.exit_label) |label| {
        const r = area.row(area.h - 1);
        ui.fill(r, th.statusline);
        _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(label, r.w -| 1), Theme.onBg(th.accent, th.statusline.bg));
        return null;
    }
    const cur = grid.cursor() orelse return null;
    if (cur.x >= area.w or cur.y >= area.h) return null;
    return .{ .x = area.x + cur.x, .y = area.y + cur.y, .shape = switch (cur.shape) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
    } };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "a coloured line lands in the cells with its style; wide chars keep their tail" {
    var term: pty.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 12, .rows = 2 });
    defer term.deinit(testing.allocator);
    var s = term.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[31;1mhi\x1b[0m 你\r\nok");
    var grid: pty.Grid = .{};
    defer grid.deinit(testing.allocator);
    try grid.update(testing.allocator, &term);

    var f = try Fixture.init(14, 3);
    defer f.deinit();
    const ui = f.ui();
    const cur = draw(ui, Rect.init(1, 0, 12, 2), &grid, .{ .focused = true });
    try f.expectRow(0, " hi 你");
    try f.expectRow(1, " ok");
    const h = f.screen.readCell(1, 0).?;
    try testing.expect(h.style.bold);
    try testing.expectEqual(@as(u8, 1), h.style.fg.index);
    const wide = f.screen.readCell(4, 0).?;
    try testing.expectEqual(@as(u8, 2), wide.char.width);
    try testing.expectEqualStrings("你", wide.char.grapheme);
    // The cursor sits after "ok" on row 1, offset by the area's x.
    try testing.expectEqual(@as(u16, 3), cur.?.x);
    try testing.expectEqual(@as(u16, 1), cur.?.y);
}

test "the exit banner takes the last row and hides the cursor" {
    var term: pty.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 2 });
    defer term.deinit(testing.allocator);
    var grid: pty.Grid = .{};
    defer grid.deinit(testing.allocator);
    try grid.update(testing.allocator, &term);
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    const cur = draw(f.ui(), Rect.init(0, 0, 12, 2), &grid, .{ .focused = true, .exit_label = "[exited 3]" });
    try testing.expect(cur == null);
    try f.expectRow(1, " [exited 3]");
}
