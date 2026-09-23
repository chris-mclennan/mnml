//! Ui — what a draw function receives instead of `*App` (D6).
//!
//! The canvas to paint on, the hit map to register into, the theme, the
//! frame arena for anything the draw allocates, who has focus, where the
//! pointer is, and the two terminal facts that change glyph choices
//! (`ascii`, `nerd_font`). A component paints inside the rect it is
//! handed and never reaches past this struct.
//!
//! The small helpers here are the strokes every component makes: paint a
//! string cell by cell, measure it, clip it with the right ellipsis,
//! register a hit without an error path (a frame that cannot afford a
//! hit entry loses that click until the next frame — never the paint).

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Canvas = @import("canvas.zig");
const Theme = @import("theme.zig");
const hit_mod = @import("hit.zig");
const clip = @import("clip.zig");
const border = @import("border.zig");
const ids = @import("../core/ids.zig");
const focus_cue_mod = @import("focus_cue.zig");

const Allocator = std.mem.Allocator;

pub const Style = vaxis.Style;
pub const Cell = vaxis.Cell;
pub const HitMap = hit_mod.HitMap;
pub const HitTarget = hit_mod.HitTarget;
pub const FocusId = ids.FocusId;

const Ui = @This();

canvas: Canvas,
hits: *HitMap,
theme: *const Theme,
/// Frame arena — everything a draw allocates.
arena: Allocator,
focus: FocusId,
hover: ?struct { x: u16, y: u16 } = null,
ascii: bool = false,
nerd_font: bool = true,
/// `ui.expand_indicator = .triangle`: every expander paints the small
/// triangle instead of the chevron (`expander.zig`).
triangle: bool = false,
/// `ui.focus_cue`: how the chrome marks what has the keys
/// (`focus_cue.zig`).
focus_cue: focus_cue_mod.Cue = .both,

/// Registers `t` for `r`. OOM drops the entry: the paint already
/// happened and the next frame re-registers it.
pub fn hit(ui: Ui, r: Rect, t: HitTarget) void {
    ui.hits.add(ui.arena, r, t) catch {};
}

pub fn fill(ui: Ui, r: Rect, style: Style) void {
    ui.canvas.fill(r, style);
}

/// The same context with the canvas clipped to `r` — hand this to a
/// callback that paints one row so it cannot reach past its cell.
pub fn withClip(ui: Ui, r: Rect) Ui {
    var out = ui;
    out.canvas = ui.canvas.sub(r);
    return out;
}

/// True when the pointer is inside `r`.
pub fn hovered(ui: Ui, r: Rect) bool {
    const h = ui.hover orelse return false;
    return r.contains(h.x, h.y);
}

/// Paints `s` from `(x, y)` leftwards-to-rightwards within `max_w`
/// cells, one grapheme per cell (two for wide ones). Returns the cells
/// used. A glyph that would cross `max_w` is not painted.
pub fn putStr(ui: Ui, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const bytes = g.bytes(s);
        const w = ui.canvas.cellWidth(bytes);
        if (w == 0) continue;
        if (used + w > max_w) break;
        ui.canvas.put(x + used, y, .{ .char = .{ .grapheme = bytes, .width = @intCast(w) }, .style = style });
        used += w;
    }
    return used;
}

/// Paints `s` so that it ends at `right_x` (exclusive), within `max_w`.
/// Returns the x it started at.
pub fn putStrRight(ui: Ui, right_x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
    const w = ui.widthUpTo(s, max_w);
    const x = right_x -| w;
    _ = ui.putStr(x, y, w, s, style);
    return x;
}

/// Cell width of `s` under the screen's width method.
pub fn width(ui: Ui, s: []const u8) u16 {
    var total: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| total +|= ui.canvas.cellWidth(g.bytes(s));
    return total;
}

pub fn ellipsis(ui: Ui) clip.Ellipsis {
    return clip.ellipsisFor(ui.ascii);
}

/// A horizontal rule of `w` cells from (`x`, `y`): `─`, or `-` under
/// `--ascii` — the glyph `border.draw` lays a frame's top edge from.
pub fn hrule(ui: Ui, x: u16, y: u16, w: u16, style: Style) void {
    border.rule(ui.canvas, x, y, w, .h, ui.ascii, style);
}

/// A vertical rule of `h` cells from (`x`, `y`): `│`, or `|` under
/// `--ascii` — a divider between two panes, the edge of a floating
/// column.
pub fn vrule(ui: Ui, x: u16, y: u16, h: u16, style: Style) void {
    border.rule(ui.canvas, x, y, h, .v, ui.ascii, style);
}

/// The ellipsis glyph itself — for a painter that cuts a string on its
/// own terms (a column header, a grep row's tail) and needs the same
/// mark `clipStr` would have left.
pub fn ellipsisText(ui: Ui) []const u8 {
    return ui.ellipsis().text();
}

/// Cell width of `s` capped at `cap`: stops measuring at the first
/// grapheme past it, so a whole file line costs `cap` of work.
pub fn widthUpTo(ui: Ui, s: []const u8, cap: u16) u16 {
    return if (ui.fitsIn(s, cap)) ui.width(s) else cap;
}

/// True when `s` paints in `max` cells — the measure every clip does
/// first, bounded by `max` rather than by the text.
pub fn fitsIn(ui: Ui, s: []const u8, max: u16) bool {
    return clip.fits(s, max, ui.canvas.widthMethod());
}

/// `s` cut to `max` cells with the terminal's ellipsis, on the frame
/// arena. OOM returns `s` uncut; the paint will clip it instead. Never
/// measures past `max`: a 545k-char line clipped to a row is `max`
/// graphemes of work, and cannot overflow the cell sum.
pub fn clipStr(ui: Ui, s: []const u8, max: u16) []const u8 {
    if (ui.fitsIn(s, max)) return s;
    return ui.canvas.clipCells(ui.arena, s, max, ui.ellipsis()) catch s;
}

/// `std.fmt` onto the frame arena; OOM yields an empty string.
pub fn fmt(ui: Ui, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(ui.arena, f, args) catch "";
}

pub fn isFocused(ui: Ui, f: FocusId) bool {
    return std.meta.eql(ui.focus, f);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "putStr paints cell-wise, respects max_w and wide glyphs" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    const ui = f.ui();
    try testing.expectEqual(@as(u16, 5), ui.putStr(1, 0, 5, "abcdefg", .{}));
    try f.expectRow(0, " abcde");
    try testing.expectEqual(@as(u16, 2), ui.putStr(0, 0, 3, "漢字", .{}));
    try f.expectRow(0, "漢bcde"); // rowText skips the wide tail
    try testing.expectEqual(@as(u16, 4), ui.width("a漢b"));
}

test "putStrRight anchors the end" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    const ui = f.ui();
    try testing.expectEqual(@as(u16, 5), ui.putStrRight(8, 0, 8, "abc", .{}));
    try f.expectRow(0, "     abc");
    try testing.expectEqual(@as(u16, 6), ui.putStrRight(8, 0, 2, "abc", .{}));
}

test "clipStr uses the ascii ellipsis under --ascii and hit swallows nothing else" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    var ui = f.ui();
    try testing.expectEqualStrings("abcd…", ui.clipStr("abcdefgh", 5));
    ui.ascii = true;
    try testing.expectEqualStrings("ab...", ui.clipStr("abcdefgh", 5));
    try testing.expectEqualStrings("abc", ui.clipStr("abc", 5));
    ui.hit(Rect.init(0, 0, 2, 1), .{ .button = 9 });
    try testing.expectEqual(@as(u32, 9), f.hits.at(1, 0).?.button);
    try testing.expectEqualStrings("(3)", ui.fmt("({d})", .{3}));
}

test "withClip narrows the canvas and nothing else" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    const ui = f.ui();
    const inner = ui.withClip(Rect.init(2, 0, 3, 1));
    _ = inner.putStr(0, 0, 8, "abcdefgh", .{});
    try f.expectRow(0, "  cde");
    try testing.expect(inner.hits == ui.hits);
    inner.hit(Rect.init(0, 0, 8, 1), .{ .button = 1 });
    try testing.expect(f.hits.at(7, 0) != null);
}

test "hovered reads the pointer" {
    var f = try Fixture.init(8, 2);
    defer f.deinit();
    var ui = f.ui();
    try testing.expect(!ui.hovered(Rect.init(0, 0, 8, 2)));
    ui.hover = .{ .x = 3, .y = 1 };
    try testing.expect(ui.hovered(Rect.init(0, 1, 8, 1)));
    try testing.expect(!ui.hovered(Rect.init(0, 0, 8, 1)));
}

test "ellipsisText is the mark clipStr actually leaves, in both terminals" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    var ui = f.ui();
    // The painters that cut a string themselves append this; if it ever
    // disagreed with what `clipStr` paints, a row would end `\u{2026}`
    // beside one ending `...` on the same screen.
    try testing.expectEqualStrings("\u{2026}", ui.ellipsisText());
    try testing.expect(std.mem.endsWith(u8, ui.clipStr("abcdefgh", 5), ui.ellipsisText()));
    ui.ascii = true;
    try testing.expectEqualStrings("...", ui.ellipsisText());
    try testing.expect(std.mem.endsWith(u8, ui.clipStr("abcdefgh", 5), ui.ellipsisText()));
}
