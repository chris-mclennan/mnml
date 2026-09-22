//! Border — the ratatui `Block` frame: five glyph sets, an optional title
//! on the top edge, and the inner Rect the caller lays content into.
//!
//! Only the frame is painted; the interior is the caller's (`fill` it
//! first for a background). Degenerate rects paint what fits and return an
//! empty inner rect — never a panic. The title is cut cell-wise to the top
//! edge between the corners, so a wide glyph that would touch the corner
//! is dropped whole (pre-clip with `clipCells` for an ellipsis).

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Canvas = @import("canvas.zig");
const text = @import("text.zig");

pub const Segment = vaxis.Segment;
pub const Style = vaxis.Style;

pub const Kind = enum {
    /// ┌─┐ (ratatui Plain)
    single,
    /// ╭─╮
    rounded,
    /// ╔═╗
    double,
    /// ┏━┓
    thick,
    /// +-+ for `--ascii` terminals
    ascii,
};

pub const Glyphs = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
};

pub fn glyphs(kind: Kind) Glyphs {
    return switch (kind) {
        .single => .{ .top_left = "┌", .top_right = "┐", .bottom_left = "└", .bottom_right = "┘", .horizontal = "─", .vertical = "│" },
        .rounded => .{ .top_left = "╭", .top_right = "╮", .bottom_left = "╰", .bottom_right = "╯", .horizontal = "─", .vertical = "│" },
        .double => .{ .top_left = "╔", .top_right = "╗", .bottom_left = "╚", .bottom_right = "╝", .horizontal = "═", .vertical = "║" },
        .thick => .{ .top_left = "┏", .top_right = "┓", .bottom_left = "┗", .bottom_right = "┛", .horizontal = "━", .vertical = "┃" },
        .ascii => .{ .top_left = "+", .top_right = "+", .bottom_left = "+", .bottom_right = "+", .horizontal = "-", .vertical = "|" },
    };
}

fn cell(g: []const u8, style: Style) vaxis.Cell {
    return .{ .char = .{ .grapheme = g, .width = 1 }, .style = style };
}

/// A rule's direction: `─` across a row, `│` down a column.
pub const Axis = enum { h, v };

/// The one-cell rule glyph a terminal gets — `─` / `│`, or `-` / `|`
/// under `--ascii`. The same glyphs `draw` lays a frame's edges from,
/// so a divider between two panes and the frame around a popup never
/// disagree. Eleven painters spelled the pair inline before this
/// existed (and one forgot the ascii half).
pub fn ruleGlyph(axis: Axis, ascii: bool) []const u8 {
    const g = glyphs(if (ascii) .ascii else .single);
    return switch (axis) {
        .h => g.horizontal,
        .v => g.vertical,
    };
}

/// Paints a straight rule of `len` cells from (`x`, `y`) along `axis`.
/// A divider between two panes, the line under a column header, the
/// edge of a floating column — every rule that is not part of a frame.
pub fn rule(c: Canvas, x: u16, y: u16, len: u16, axis: Axis, ascii: bool, style: Style) void {
    const g = ruleGlyph(axis, ascii);
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        switch (axis) {
            .h => c.put(x + i, y, cell(g, style)),
            .v => c.put(x, y + i, cell(g, style)),
        }
    }
}

/// Paints the frame of `r` and returns the inner rect.
pub fn draw(c: Canvas, r: Rect, kind: Kind, style: Style, title: ?[]const Segment) Rect {
    if (r.isEmpty()) return r.inset(1);
    const g = glyphs(kind);
    const x1 = r.right() - 1;
    const y1 = r.bottom() - 1;

    var x = r.x;
    while (x <= x1) : (x += 1) {
        c.put(x, r.y, cell(g.horizontal, style));
        c.put(x, y1, cell(g.horizontal, style));
    }
    var y = r.y;
    while (y <= y1) : (y += 1) {
        c.put(r.x, y, cell(g.vertical, style));
        c.put(x1, y, cell(g.vertical, style));
    }
    // Same order as ratatui so a 1×1 rect ends up a top-left corner.
    c.put(x1, y1, cell(g.bottom_right, style));
    c.put(x1, r.y, cell(g.top_right, style));
    c.put(r.x, y1, cell(g.bottom_left, style));
    c.put(r.x, r.y, cell(g.top_left, style));

    if (title) |segs| {
        if (r.w >= 3) {
            const slot = Rect.init(r.x + 1, r.y, r.w - 2, 1);
            _ = text.draw(c.sub(slot), slot, segs, .{});
        }
    }
    return r.inset(1);
}

// ── tests ──

const testing = std.testing;

const Fixture = struct {
    screen: vaxis.Screen,

    fn init(w: u16, h: u16) !Fixture {
        var screen = try vaxis.Screen.init(testing.allocator, .{ .cols = w, .rows = h, .x_pixel = 0, .y_pixel = 0 });
        screen.width_method = .unicode;
        return .{ .screen = screen };
    }

    fn deinit(f: *Fixture) void {
        f.screen.deinit(testing.allocator);
    }

    fn c(f: *Fixture) Canvas {
        return Canvas.init(&f.screen, .{});
    }

    fn expectRows(f: *Fixture, expected: []const []const u8) !void {
        var buf: [256]u8 = undefined;
        for (expected, 0..) |want, y| {
            try testing.expectEqualStrings(want, Canvas.rowText(&f.screen, @intCast(y), &buf));
        }
    }
};

test "rounded frame and inner rect" {
    var f = try Fixture.init(5, 3);
    defer f.deinit();
    const inner = draw(f.c(), Rect.init(0, 0, 5, 3), .rounded, .{}, null);
    try f.expectRows(&.{ "╭───╮", "│   │", "╰───╯" });
    try testing.expect(inner.eql(Rect.init(1, 1, 3, 1)));
}

test "every glyph set has its corners" {
    const expect = [_]struct { kind: Kind, top: []const u8, mid: []const u8, bot: []const u8 }{
        .{ .kind = .single, .top = "┌──┐", .mid = "│  │", .bot = "└──┘" },
        .{ .kind = .rounded, .top = "╭──╮", .mid = "│  │", .bot = "╰──╯" },
        .{ .kind = .double, .top = "╔══╗", .mid = "║  ║", .bot = "╚══╝" },
        .{ .kind = .thick, .top = "┏━━┓", .mid = "┃  ┃", .bot = "┗━━┛" },
        .{ .kind = .ascii, .top = "+--+", .mid = "|  |", .bot = "+--+" },
    };
    for (expect) |e| {
        var f = try Fixture.init(4, 3);
        defer f.deinit();
        _ = draw(f.c(), Rect.init(0, 0, 4, 3), e.kind, .{}, null);
        try f.expectRows(&.{ e.top, e.mid, e.bot });
    }
}

test "title sits after the corner and is cut before the far corner" {
    var f = try Fixture.init(8, 2);
    defer f.deinit();
    const t = [_]Segment{.{ .text = " T " }};
    _ = draw(f.c(), Rect.init(0, 0, 8, 2), .rounded, .{}, &t);
    try f.expectRows(&.{ "╭ T ───╮", "╰──────╯" });

    var g = try Fixture.init(6, 2);
    defer g.deinit();
    const long = [_]Segment{.{ .text = "abcdefgh" }};
    _ = draw(g.c(), Rect.init(0, 0, 6, 2), .single, .{}, &long);
    try g.expectRows(&.{ "┌abcd┐", "└────┘" });
}

test "wide title glyph never overwrites the corner" {
    var f = try Fixture.init(6, 2);
    defer f.deinit();
    const t = [_]Segment{.{ .text = "漢字漢" }};
    _ = draw(f.c(), Rect.init(0, 0, 6, 2), .single, .{}, &t);
    try f.expectRows(&.{ "┌漢字┐", "└────┘" });
    try testing.expectEqualStrings("┐", f.screen.readCell(5, 0).?.char.grapheme);

    // Odd slot: the second glyph does not fit, the cell stays a horizontal.
    var g = try Fixture.init(5, 2);
    defer g.deinit();
    _ = draw(g.c(), Rect.init(0, 0, 5, 2), .single, .{}, &t);
    try g.expectRows(&.{ "┌漢─┐", "└───┘" });
}

test "title with a style and frame style" {
    var f = try Fixture.init(6, 2);
    defer f.deinit();
    const frame: Style = .{ .fg = .{ .index = 8 } };
    const t = [_]Segment{.{ .text = "ab", .style = .{ .bold = true } }};
    _ = draw(f.c(), Rect.init(0, 0, 6, 2), .single, frame, &t);
    try testing.expectEqual(@as(u8, 8), f.screen.readCell(0, 0).?.style.fg.index);
    try testing.expect(f.screen.readCell(1, 0).?.style.bold);
}

test "degenerate rects paint what fits and yield an empty inner" {
    var f = try Fixture.init(3, 3);
    defer f.deinit();
    try testing.expect(draw(f.c(), Rect.init(0, 0, 1, 1), .single, .{}, null).isEmpty());
    try f.expectRows(&.{"┌"});
    var g = try Fixture.init(3, 3);
    defer g.deinit();
    try testing.expect(draw(g.c(), Rect.init(0, 0, 2, 2), .single, .{}, null).isEmpty());
    try g.expectRows(&.{ "┌┐", "└┘" });
    var h = try Fixture.init(4, 1);
    defer h.deinit();
    const t = [_]Segment{.{ .text = "xy" }};
    try testing.expect(draw(h.c(), Rect.init(0, 0, 4, 1), .single, .{}, &t).isEmpty());
    try h.expectRows(&.{"┌xy┐"});
    try testing.expect(draw(h.c(), Rect.empty, .single, .{}, null).isEmpty());
}

test "a rule is laid from the frame's own glyphs, in both terminals" {
    var f = try Fixture.init(5, 3);
    defer f.deinit();
    rule(f.c(), 0, 0, 5, .h, false, .{});
    rule(f.c(), 2, 1, 2, .v, false, .{});
    try f.expectRows(&.{ "─────", "  │", "  │" });
    try testing.expectEqualStrings(glyphs(.single).horizontal, ruleGlyph(.h, false));
    try testing.expectEqualStrings(glyphs(.single).vertical, ruleGlyph(.v, false));

    var g = try Fixture.init(5, 3);
    defer g.deinit();
    rule(g.c(), 0, 0, 5, .h, true, .{});
    rule(g.c(), 2, 1, 2, .v, true, .{});
    try g.expectRows(&.{ "-----", "  |", "  |" });

    // A rule past the canvas edge stops at it.
    var h = try Fixture.init(3, 1);
    defer h.deinit();
    rule(h.c(), 1, 0, 10, .h, false, .{});
    try h.expectRows(&.{" ──"});
}

test "frame respects the canvas clip" {
    var f = try Fixture.init(6, 3);
    defer f.deinit();
    const c = f.c().sub(Rect.init(0, 0, 3, 3));
    _ = draw(c, Rect.init(0, 0, 6, 3), .single, .{}, null);
    try f.expectRows(&.{ "┌──", "│", "└──" });
}
