//! The dock widget as painted: a one-row title bar (the title, a `▼N`
//! chip when the tail has more lines than fit, the kebab, the close
//! glyph) over a body of lines. `Solid` fills the body with the overlay
//! ground; `Translucent` blends that ground into whatever the editor
//! painted underneath and writes the text over the blend, so the buffer
//! stays legible through the widget. Every part registers its hit in
//! the statement that paints it (D6): `.dock{ id, part }`.
//!
//! The drag ghost and the landing preview are painted here too, on top
//! of every widget, so a drop target is unambiguous.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const dock = @import("../core/dock.zig");

const Style = vaxis.Style;

pub const kebab_glyph = " \u{22ee} ";
pub const kebab_ascii = " : ";
pub const close_glyph = " \u{00d7} ";
pub const close_ascii = " x ";
/// Percent of the widget's ground in a translucent blend.
pub const translucent_pct: u8 = 45;

pub const Model = struct {
    id: u32,
    rect: Rect,
    title: []const u8,
    lines: []const []const u8,
    /// Rows scrolled by the wheel.
    scroll: u16 = 0,
    /// The tail anchors its END to the body's last row (a log); text
    /// anchors its start.
    anchor_end: bool = false,
    focused: bool = false,
    opacity: dock.Opacity = .solid,
};

pub const Layout = struct { title: Rect, kebab: Rect, close: Rect, body: Rect };

/// Paints one widget. Returns where the parts went.
pub fn draw(ui: Ui, m: Model) Layout {
    const t = ui.theme;
    const r = m.rect;
    var out: Layout = .{ .title = Rect.empty, .kebab = Rect.empty, .close = Rect.empty, .body = Rect.empty };
    if (r.w < 4 or r.h < 2) return out;

    // Body first, so the title bar's hits paint over the body's.
    const body = r.splitTop(1).rest;
    out.body = body;
    if (m.opacity == .solid) {
        ui.fill(body, t.overlay_bg);
    } else {
        blendGround(ui, body, t.overlay_bg.bg);
    }
    ui.hit(body, .{ .dock = .{ .id = m.id, .part = .body } });

    // The lines.
    const rows: usize = body.h;
    const start: usize = if (m.anchor_end) (m.lines.len -| rows) -| m.scroll else @min(m.scroll, m.lines.len -| 1);
    const more_above: usize = if (m.anchor_end) start else 0;
    var i: usize = 0;
    while (i < rows and start + i < m.lines.len) : (i += 1) {
        const row = body.row(@intCast(i));
        const line = ui.clipStr(m.lines[start + i], row.w -| 2);
        if (m.opacity == .solid) {
            _ = ui.putStr(row.x + 1, row.y, row.w -| 2, line, Theme.onBg(t.fg, t.overlay_bg.bg));
        } else {
            putStrOverBlend(ui, row.x + 1, row.y, row.w -| 2, line, t.fg.fg);
        }
    }

    // Title bar: `<title>`, the chip, the kebab, the close.
    const bar = r.splitTop(1).top;
    const bar_style = if (m.focused) t.chip_active else t.chip;
    ui.fill(bar, bar_style);
    const close_text = if (ui.ascii) close_ascii else close_glyph;
    const kebab_text = if (ui.ascii) kebab_ascii else kebab_glyph;
    const close_w = ui.width(close_text);
    const kebab_w = ui.width(kebab_text);
    var right = bar.right();
    if (bar.w >= close_w + 2) {
        right -= close_w;
        _ = ui.putStr(right, bar.y, close_w, close_text, bar_style);
        out.close = Rect.init(right, bar.y, close_w, 1);
        ui.hit(out.close, .{ .dock = .{ .id = m.id, .part = .close } });
    }
    if (bar.w >= close_w + kebab_w + 2) {
        right -= kebab_w;
        _ = ui.putStr(right, bar.y, kebab_w, kebab_text, bar_style);
        out.kebab = Rect.init(right, bar.y, kebab_w, 1);
        ui.hit(out.kebab, .{ .dock = .{ .id = m.id, .part = .kebab } });
    }
    var chip: []const u8 = "";
    if (more_above > 0) chip = ui.fmt(" {s}{d} ", .{ if (ui.ascii) "v" else "\u{25bc}", more_above });
    const chip_w = ui.width(chip);
    if (chip_w > 0 and right -| bar.x >= chip_w + 4) {
        right -= chip_w;
        _ = ui.putStr(right, bar.y, chip_w, chip, Theme.onBg(t.muted, bar_style.bg));
    }
    const title_rect = Rect.init(bar.x, bar.y, right -| bar.x, 1);
    var title_style = bar_style;
    title_style.bold = true;
    _ = ui.putStr(bar.x + 1, bar.y, title_rect.w -| 1, ui.clipStr(m.title, title_rect.w -| 1), title_style);
    out.title = title_rect;
    ui.hit(title_rect, .{ .dock = .{ .id = m.id, .part = .title } });
    return out;
}

/// The body ground blended into what is already painted. A cell whose
/// colours cannot be mixed (indexed / default) keeps what it had.
fn blendGround(ui: Ui, body: Rect, ground: vaxis.Color) void {
    var y = body.y;
    while (y < body.bottom()) : (y += 1) {
        var x = body.x;
        while (x < body.right()) : (x += 1) {
            var cell = ui.canvas.screen.readCell(x, y) orelse continue;
            if (dock_blend(ground, cell.style.bg)) |mixed| cell.style.bg = mixed;
            ui.canvas.put(x, y, cell);
        }
    }
}

fn dock_blend(top: vaxis.Color, under: vaxis.Color) ?vaxis.Color {
    return @import("../app/dock.zig").blend(top, under, translucent_pct);
}

/// Text over the blend: each grapheme takes the ground already under it.
fn putStrOverBlend(ui: Ui, x0: u16, y: u16, max_w: u16, s: []const u8, fg: vaxis.Color) void {
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |g| {
        const w = ui.canvas.cellWidth(g);
        if (x + w > x0 + max_w) break;
        var cell = ui.canvas.screen.readCell(x, y) orelse vaxis.Cell{};
        cell.char = .{ .grapheme = g, .width = @intCast(w) };
        cell.style.fg = fg;
        ui.canvas.put(x, y, cell);
        x += @max(w, 1);
    }
}

/// The ghost chip under the pointer and the landing rect's preview.
pub fn drawDrag(ui: Ui, x: u16, y: u16, title: []const u8, landing: ?Rect, corner_label: []const u8) void {
    const t = ui.theme;
    if (landing) |l| {
        var yy = l.y;
        while (yy < l.bottom()) : (yy += 1) {
            var xx = l.x;
            while (xx < l.right()) : (xx += 1) _ = ui.putStr(xx, yy, 1, if (ui.ascii) "." else "\u{2591}", Theme.onBg(t.muted, t.bg.bg));
        }
        const label = ui.fmt(" {s} ", .{corner_label});
        _ = ui.putStr(l.x + 1, l.y, l.w -| 2, label, t.chip_active);
    }
    const ghost = ui.fmt(" {s} {s} ", .{ if (ui.ascii) "->" else "\u{21f2}", title });
    const gw = ui.width(ghost);
    const full = ui.canvas.full();
    const gx = @min(x, full.right() -| gw);
    _ = ui.putStr(gx, y, gw, ghost, t.chip_active);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the title bar carries the title, kebab and close with their hits; the body lists the lines and hits as body" {
    var f = try Fixture.init(40, 6);
    defer f.deinit();
    const l = draw(f.ui(), .{ .id = 7, .rect = Rect.init(2, 1, 20, 4), .title = "Note", .lines = &.{ "one", "two", "three", "four" }, .focused = true });
    try f.expectRow(1, "   Note          ⋮  ×");
    try f.expectRow(2, "   one");
    try f.expectRow(4, "   three");
    try testing.expect(l.close.eql(Rect.init(19, 1, 3, 1)));
    try testing.expect(l.kebab.eql(Rect.init(16, 1, 3, 1)));
    try testing.expectEqual(dock.Corner.bottom_left, dock.Corner.bottom_left); // the enum is shared
    try testing.expect(f.hits.at(20, 1).?.dock.part == .close);
    try testing.expect(f.hits.at(17, 1).?.dock.part == .kebab);
    try testing.expect(f.hits.at(3, 1).?.dock.part == .title);
    try testing.expect(f.hits.at(5, 3).?.dock.part == .body);
    try testing.expectEqual(@as(u32, 7), f.hits.at(5, 3).?.dock.id);
    try testing.expect(f.bgEql(3, 1, f.theme.chip_active));
}

test "a tail anchors its end and the chip counts the rows above; the wheel scrolls back" {
    var f = try Fixture.init(40, 5);
    defer f.deinit();
    _ = draw(f.ui(), .{ .id = 1, .rect = Rect.init(0, 0, 30, 4), .title = "Log", .lines = &.{ "a", "b", "c", "d", "e" }, .anchor_end = true });
    try f.expectRow(3, " e");
    try f.expectRow(1, " c");
    try f.expectContains("▼2");
    f.hits.reset();
    _ = draw(f.ui(), .{ .id = 1, .rect = Rect.init(0, 0, 30, 4), .title = "Log", .lines = &.{ "a", "b", "c", "d", "e" }, .anchor_end = true, .scroll = 1 });
    try f.expectRow(3, " d");
    try f.expectContains("▼1");
    // Too small: nothing painted, nothing registered.
    f.hits.reset();
    const l = draw(f.ui(), .{ .id = 1, .rect = Rect.init(0, 0, 3, 1), .title = "Log", .lines = &.{} });
    try testing.expect(l.body.isEmpty());
    try testing.expectEqual(@as(usize, 0), f.hits.items.items.len);
}

test "translucent keeps the cells underneath and writes the text over them" {
    var f = try Fixture.init(30, 4);
    defer f.deinit();
    const ui = f.ui();
    const under: Style = .{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .bg = .{ .rgb = .{ 200, 200, 200 } } };
    _ = ui.putStr(0, 1, 30, "0123456789012345678901234567", under);
    _ = ui.putStr(0, 2, 30, "abcdefghijabcdefghijabcdefgh", under);
    _ = draw(ui, .{ .id = 1, .rect = Rect.init(0, 0, 12, 3), .title = "T", .lines = &.{"hi"}, .opacity = .translucent });
    // The widget's text sits over the blend (one cell in); the rest of
    // the row, and the margin cell, keep their glyphs.
    try f.expectRow(1, "0hi3456789012345678901234567");
    try f.expectRow(2, "abcdefghijabcdefghijabcdefgh");
    // A blended cell is neither the editor's ground nor the overlay's.
    const c = f.style(5, 2).bg;
    try testing.expect(c == .rgb);
    try testing.expect(!vaxis.Color.eql(c, under.bg));
    try testing.expect(!vaxis.Color.eql(c, f.theme.overlay_bg.bg));
    // Outside the widget nothing changed.
    try testing.expect(vaxis.Color.eql(f.style(20, 2).bg, under.bg));
}
