//! Canvas — a clipped painter over a tty-free `vaxis.Screen`.
//!
//! We do not own a grid: `vaxis.Screen` is the cell store, `Vaxis.render`
//! diffs it against the last frame and emits the bytes. Headless mode, the
//! `.test` runner and the terminal loop therefore render through the same
//! code path. A Canvas is a value — `sub` narrows the clip, nothing is
//! allocated, and every `put` outside the clip is silently dropped.
//!
//! Wide-cell hygiene lives here so no caller has to think about it: a
//! 2-cell grapheme always owns a real " " tail cell, a narrow write on top
//! of a tail blanks the head it belonged to, and a wide glyph that would
//! straddle the clip edge is replaced by a blank instead of smearing into
//! the neighbouring border.

const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../core/utf8.zig");
const Rect = @import("rect.zig");
const color = @import("color.zig");
const clip_mod = @import("clip.zig");
const text_mod = @import("text.zig");
const border_mod = @import("border.zig");

pub const Cell = vaxis.Cell;
pub const Style = vaxis.Style;
pub const Segment = vaxis.Segment;
pub const Screen = vaxis.Screen;
pub const TextOptions = text_mod.Options;
pub const BorderKind = border_mod.Kind;

const Canvas = @This();

screen: *Screen,
clip: Rect,
/// Fold rgb colors onto the 256-color cube at paint time. Set when the
/// terminal has no truecolor; vaxis itself emits rgb SGR unconditionally.
quantize: bool = false,

pub const Options = struct {
    quantize: bool = false,
};

pub fn init(screen: *Screen, opts: Options) Canvas {
    return .{
        .screen = screen,
        .clip = .{ .x = 0, .y = 0, .w = screen.width, .h = screen.height },
        .quantize = opts.quantize,
    };
}

/// The whole screen as a Rect, regardless of the current clip.
pub fn full(c: Canvas) Rect {
    return .{ .x = 0, .y = 0, .w = c.screen.width, .h = c.screen.height };
}

/// A canvas whose clip is the intersection of this clip and `r`.
pub fn sub(c: Canvas, r: Rect) Canvas {
    var out = c;
    out.clip = c.clip.intersect(r);
    return out;
}

pub fn widthMethod(c: Canvas) vaxis.gwidth.Method {
    return c.screen.width_method;
}

/// Cell width of one grapheme under the screen's width method.
pub fn cellWidth(c: Canvas, grapheme: []const u8) u16 {
    return measureWidth(grapheme, c.screen.width_method);
}

pub fn measureWidth(grapheme: []const u8, method: vaxis.gwidth.Method) u16 {
    if (grapheme.len == 1 and grapheme[0] >= 0x20 and grapheme[0] < 0x7f) return 1;
    return utf8.width(grapheme, method);
}

/// Truncates `s` to `max_cells` under this canvas's width method, with an
/// ellipsis. Always allocates — hand it the frame arena.
pub fn clipCells(c: Canvas, alloc: std.mem.Allocator, s: []const u8, max_cells: u16, ellipsis: clip_mod.Ellipsis) std.mem.Allocator.Error![]u8 {
    return clip_mod.clipCells(alloc, s, max_cells, .{ .method = c.screen.width_method, .ellipsis = ellipsis });
}

/// ratatui `Paragraph`: wraps `segs` into `r` per `opts` (none / word /
/// grapheme, alignment, scroll), painting through the clip. Returns the
/// rows used.
pub fn text(c: Canvas, r: Rect, segs: []const Segment, opts: TextOptions) u16 {
    return text_mod.draw(c, r, segs, opts);
}

/// Rows `segs` would need at `width` under `opts` — size before you paint.
pub fn measure(c: Canvas, segs: []const Segment, width: u16, opts: TextOptions) u16 {
    return text_mod.measure(segs, width, opts, c.screen.width_method);
}

/// ratatui `Block`: paints the frame of `r` in `kind`, an optional title on
/// the top edge, and returns the inner rect. The interior is untouched.
pub fn border(c: Canvas, r: Rect, kind: BorderKind, style: Style, title: ?[]const Segment) Rect {
    return border_mod.draw(c, r, kind, style, title);
}

pub fn blank(style: Style) Cell {
    return .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style };
}

/// Writes one cell at absolute screen coordinates, clipped. `cell.char.width`
/// may be 0 (measure here) or the caller's own measurement. Widths above 2
/// are treated as 2 — no terminal renders wider cells.
pub fn put(c: Canvas, x: u16, y: u16, cell_in: Cell) void {
    if (!c.clip.contains(x, y)) return;
    var cell = cell_in;
    // A byte that is not UTF-8 (a binary file, a legacy encoding) paints
    // as U+FFFD rather than going to the terminal raw.
    if (utf8.isInvalidUnit(cell.char.grapheme)) cell.char.grapheme = utf8.replacement;
    const measured: u16 = if (cell.char.width != 0) cell.char.width else c.cellWidth(cell.char.grapheme);
    if (measured == 0) return;
    const w: u16 = @min(measured, 2);
    if (c.quantize) cell.style = color.quantizeStyle(cell.style);

    if (w == 2 and x + 2 > c.clip.right()) {
        // Would straddle the clip edge: paint a blank rather than half a glyph.
        c.breakWideBefore(x, y);
        c.screen.writeCell(x, y, blank(cell.style));
        return;
    }

    c.breakWideBefore(x, y);
    if (w == 2) {
        // The tail cell may itself be a wide head; its own tail is orphaned.
        if (c.screen.readCell(x + 1, y)) |next| {
            if (next.char.width >= 2) c.screen.writeCell(x + 2, y, blank(next.style));
        }
        cell.char.width = 2;
        c.screen.writeCell(x, y, cell);
        c.screen.writeCell(x + 1, y, blank(cell.style));
        return;
    }
    cell.char.width = 1;
    c.screen.writeCell(x, y, cell);
}

/// If the cell left of `x` is a wide head, its tail is `x`: blank the head so
/// the terminal never sees a torn glyph.
fn breakWideBefore(c: Canvas, x: u16, y: u16) void {
    if (x == 0) return;
    const prev = c.screen.readCell(x - 1, y) orelse return;
    if (prev.char.width >= 2) c.screen.writeCell(x - 1, y, blank(prev.style));
}

/// Fills `r` (clipped) with blank cells in `style` — the ratatui `Clear`
/// plus background paint in one call.
pub fn fill(c: Canvas, r: Rect, style: Style) void {
    const area = c.clip.intersect(r);
    if (area.isEmpty()) return;
    const cell = blank(if (c.quantize) color.quantizeStyle(style) else style);
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        c.breakWideBefore(area.x, y);
        var x = area.x;
        while (x < area.right()) : (x += 1) c.screen.writeCell(x, y, cell);
        // A wide head on the last column left its tail just outside the fill;
        // tails are always real spaces, so that cell is already correct.
    }
}

/// Test helper: row `y` as text, wide tails skipped, trailing spaces trimmed.
pub fn rowText(screen: *const Screen, y: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var x: u16 = 0;
    while (x < screen.width) {
        const cell = screen.readCell(x, y) orelse break;
        const g = cell.char.grapheme;
        if (n + g.len > buf.len) break;
        @memcpy(buf[n .. n + g.len], g);
        n += g.len;
        x += @max(1, cell.char.width);
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

fn testScreen(w: u16, h: u16) !Screen {
    var s = try Screen.init(std.testing.allocator, .{ .cols = w, .rows = h, .x_pixel = 0, .y_pixel = 0 });
    s.width_method = .unicode;
    return s;
}

fn ch(g: []const u8) Cell {
    return .{ .char = .{ .grapheme = g, .width = 0 } };
}

test "put respects the clip and sub narrows it" {
    var screen = try testScreen(8, 3);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(0, 0, ch("a"));
    c.put(7, 2, ch("b"));
    c.put(8, 0, ch("x")); // off-screen: dropped, no panic
    c.put(0, 3, ch("x"));

    const inner = c.sub(Rect.init(2, 1, 3, 1));
    inner.put(2, 1, ch("c"));
    inner.put(4, 1, ch("d"));
    inner.put(5, 1, ch("x")); // outside sub clip
    inner.put(2, 0, ch("x"));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a", rowText(&screen, 0, &buf));
    try std.testing.expectEqualStrings("  c d", rowText(&screen, 1, &buf));
    try std.testing.expectEqualStrings("       b", rowText(&screen, 2, &buf));
    try std.testing.expect(c.sub(Rect.init(20, 20, 4, 4)).clip.isEmpty());
}

test "wide glyph owns a space tail and is measured at put time" {
    var screen = try testScreen(6, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(1, 0, ch("漢"));
    const head = screen.readCell(1, 0).?;
    const tail = screen.readCell(2, 0).?;
    try std.testing.expectEqual(@as(u8, 2), head.char.width);
    try std.testing.expectEqualStrings("漢", head.char.grapheme);
    try std.testing.expectEqualStrings(" ", tail.char.grapheme);
    try std.testing.expectEqual(@as(u8, 1), tail.char.width);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" 漢", rowText(&screen, 0, &buf));
}

test "narrow write over a wide tail blanks the head" {
    var screen = try testScreen(6, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(1, 0, ch("漢"));
    c.put(2, 0, ch("│"));
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("│", screen.readCell(2, 0).?.char.grapheme);
}

test "wide write over a wide tail blanks the old head and orphaned tail" {
    var screen = try testScreen(6, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(1, 0, ch("漢")); // cells 1,2
    c.put(2, 0, ch("字")); // cells 2,3 — head at 1 must go
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("字", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);

    // Now a wide glyph whose tail lands on another wide head.
    c.put(3, 0, ch("漢")); // cells 3,4 — nothing at 4 yet
    c.put(2, 0, ch("字")); // cells 2,3 — head at 3 is overwritten, its tail at 4 orphaned
    try std.testing.expectEqualStrings("字", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqual(@as(u8, 1), screen.readCell(4, 0).?.char.width);
}

test "wide glyph at the clip edge becomes a blank, never half a glyph" {
    var screen = try testScreen(6, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(5, 0, ch("│")); // a border in the last column
    const box = c.sub(Rect.init(0, 0, 5, 1));
    box.put(4, 0, ch("漢")); // would need cells 4,5
    try std.testing.expectEqualStrings(" ", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqual(@as(u8, 1), screen.readCell(4, 0).?.char.width);
    try std.testing.expectEqualStrings("│", screen.readCell(5, 0).?.char.grapheme);
}

test "fill is clipped, styled, and breaks a wide head on its left edge" {
    var screen = try testScreen(6, 2);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(1, 0, ch("漢")); // cells 1,2
    const bg: Style = .{ .bg = .{ .index = 4 } };
    c.sub(Rect.init(2, 0, 10, 1)).fill(Rect.init(0, 0, 10, 10), bg);
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expect(screen.readCell(1, 0).?.style.bg == .default);
    var x: u16 = 2;
    while (x < 6) : (x += 1) {
        const cell = screen.readCell(x, 0).?;
        try std.testing.expectEqualStrings(" ", cell.char.grapheme);
        try std.testing.expectEqual(@as(u8, 4), cell.style.bg.index);
    }
    // Row 1 untouched by the height-1 clip.
    try std.testing.expect(screen.readCell(2, 1).?.style.bg == .default);
}

test "clipCells uses the screen's width method" {
    var screen = try testScreen(4, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    const got = try c.clipCells(std.testing.allocator, "漢字漢字", 5, .unicode);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("漢字…", got);
}

test "zero-width grapheme alone paints nothing" {
    var screen = try testScreen(4, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{});
    c.put(0, 0, ch("a"));
    c.put(0, 0, ch("\u{200B}"));
    try std.testing.expectEqualStrings("a", screen.readCell(0, 0).?.char.grapheme);
}

test "quantize folds rgb styles at put and fill" {
    var screen = try testScreen(4, 1);
    defer screen.deinit(std.testing.allocator);
    const c = Canvas.init(&screen, .{ .quantize = true });
    var cell = ch("a");
    cell.style = .{ .fg = .{ .rgb = .{ 255, 0, 0 } }, .bg = .{ .rgb = .{ 0, 0, 0 } } };
    c.put(0, 0, cell);
    try std.testing.expectEqual(@as(u8, 196), screen.readCell(0, 0).?.style.fg.index);
    try std.testing.expectEqual(@as(u8, 16), screen.readCell(0, 0).?.style.bg.index);
    c.fill(Rect.init(1, 0, 1, 1), .{ .bg = .{ .rgb = .{ 255, 255, 255 } } });
    try std.testing.expectEqual(@as(u8, 231), screen.readCell(1, 0).?.style.bg.index);
    // Without the flag rgb passes through untouched.
    const raw = Canvas.init(&screen, .{});
    raw.put(2, 0, cell);
    try std.testing.expect(screen.readCell(2, 0).?.style.fg == .rgb);
}
