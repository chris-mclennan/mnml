//! The launcher dock as painted — macOS's Dock in a terminal: a strip
//! of integrations, terminals, launchers and pinned commands along one
//! edge of the editor area, with the pin chip at its end.
//!
//! Two shapes, one per axis. On the **bottom** edge it is one row:
//! each item is ` <glyph> <label> `, laid left to right, and an item
//! that does not fit whole is dropped rather than half-painted. On the
//! **left** / **right** edge it is `width` cells wide — a padding
//! cell, the glyph, a padding cell, the activity bar's own column — and
//! the label lives in the tooltip instead.
//!
//! An item carries its integration's category colour, the way a pinned
//! rail icon does, because the colour is the integration's identity. A
//! running one wears the small dot macOS puts under an open app:
//! beside the glyph on the bottom edge, in the padding cell before it
//! on a side edge (there is no row underneath to put it on).
//!
//! The hover rule is the family's (`app/hover_zones.zig`): the item
//! under the pointer sheds its `dim`, keeps its own colour, and its
//! whole cell run fills one step lighter. The keyboard cursor is the
//! `▸` the rest of mnml uses, painted before the glyph.
//!
//! Every part registers its hit in the statement that paints it (D6):
//! `.launcher_dock{ .item = i }`, `.launcher_dock.pin`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit = @import("hit.zig");
const paletteColor = @import("integrations_view.zig").paletteColor;

const Style = Ui.Style;

/// A side dock's width: padding, glyph, padding — the activity bar's.
pub const width: u16 = 3;
/// The pin chip at the strip's end (`view.dock_pin`).
pub const pin_glyph = "\u{F0403}"; // 󰐃 nf-md-pin
pub const pin_ascii = "P";
/// The dot a running item wears (macOS's under-icon dot).
pub const running_dot = "\u{25cf}"; // ●
pub const running_ascii = "*";
/// The keyboard cursor.
pub const cursor_glyph = "\u{25b8}"; // ▸
pub const cursor_ascii = ">";

pub const Edge = enum { bottom, left, right };

pub const Item = struct {
    glyph: []const u8,
    fallback: []const u8,
    /// A theme role or a `#RRGGBB` literal; empty takes the accent.
    color: []const u8 = "",
    label: []const u8,
    /// The item's thing is open: a mounted integration, a live pty.
    running: bool = false,
};

pub const Props = struct {
    items: []const Item,
    edge: Edge,
    /// The keyboard cursor's item, when the dock has the keys.
    cursor: ?u16 = null,
    /// The pin chip is lit (the dock is pinned open).
    pinned: bool = false,
};

/// Where the pin chip goes on a bottom strip: the last three cells.
pub fn pinRect(area: Rect, edge: Edge) Rect {
    if (area.isEmpty()) return .empty;
    return switch (edge) {
        .bottom => if (area.w < 4) .empty else Rect.init(area.right() - 3, area.y, 3, 1),
        .left, .right => if (area.h < 2) .empty else Rect.init(area.x, area.bottom() - 1, area.w, 1),
    };
}

/// The cells an item takes on a bottom strip: the glyph, its dot, a
/// space, the label, and one cell of air either side.
fn itemWidth(ui: Ui, it: Item) u16 {
    return 1 + 1 + @as(u16, if (it.running) 1 else 0) + 1 + ui.width(it.label) + 1;
}

pub fn draw(ui: Ui, area: Rect, props: Props) void {
    if (area.isEmpty()) return;
    const th = ui.theme;
    const pal = th.palette;
    const bg = pal.bg_darker;
    const hover_bg = pal.bg2;
    ui.fill(area, Theme.onBg(th.fg, bg));
    switch (props.edge) {
        .bottom => drawRow(ui, area, props, bg, hover_bg),
        .left, .right => drawColumn(ui, area, props, bg, hover_bg),
    }
    const pin = pinRect(area, props.edge);
    if (!pin.isEmpty()) {
        const hot = ui.hovered(pin);
        const ground = if (hot) hover_bg else bg;
        if (hot) ui.fill(pin, Theme.onBg(th.fg, hover_bg));
        const style = if (props.pinned)
            bold(Theme.withFg(Theme.onBg(th.fg, ground), pal.yellow))
        else if (hot)
            bold(Theme.onBg(th.fg, ground))
        else
            dim(Theme.withFg(Theme.onBg(th.fg, ground), pal.comment));
        _ = ui.putStr(pin.x + 1, pin.y, pin.w -| 1, if (ui.ascii) pin_ascii else pin_glyph, style);
        ui.hit(pin, .{ .launcher_dock = .pin });
    }
}

fn drawRow(ui: Ui, area: Rect, props: Props, bg: vaxis.Color, hover_bg: vaxis.Color) void {
    // The pin chip owns the strip's tail; items stop before it.
    const limit = pinRect(area, .bottom);
    const right_edge = if (limit.isEmpty()) area.right() else limit.x;
    var x: u16 = area.x + 1;
    for (props.items, 0..) |it, i| {
        const w = itemWidth(ui, it);
        if (x + w > right_edge) break;
        const cell = Rect.init(x, area.y, w, 1);
        paintItem(ui, cell, it, props.cursor == @as(u16, @intCast(i)), bg, hover_bg, true);
        ui.hit(cell, .{ .launcher_dock = .{ .item = @intCast(i) } });
        x += w;
    }
}

fn drawColumn(ui: Ui, area: Rect, props: Props, bg: vaxis.Color, hover_bg: vaxis.Color) void {
    const limit = pinRect(area, .left);
    const bottom_edge = if (limit.isEmpty()) area.bottom() else limit.y;
    var y: u16 = area.y;
    for (props.items, 0..) |it, i| {
        if (y >= bottom_edge) break;
        const cell = Rect.init(area.x, y, area.w, 1);
        paintItem(ui, cell, it, props.cursor == @as(u16, @intCast(i)), bg, hover_bg, false);
        ui.hit(cell, .{ .launcher_dock = .{ .item = @intCast(i) } });
        y += 1;
    }
}

/// One item in its own cell run. `with_label` is the bottom strip; a
/// side dock paints the glyph alone and leaves the label to the tip.
fn paintItem(ui: Ui, cell: Rect, it: Item, focused: bool, bg: vaxis.Color, hover_bg: vaxis.Color, with_label: bool) void {
    const th = ui.theme;
    const pal = th.palette;
    const hot = ui.hovered(cell);
    const ground = if (hot or focused) hover_bg else bg;
    if (hot or focused) ui.fill(cell, Theme.onBg(th.fg, ground));
    const color = paletteColor(th, it.color);
    const base = Theme.withFg(Theme.onBg(th.fg, ground), color);
    // The item keeps its colour when it lights — the colour IS the
    // integration's identity — and only sheds the `dim`.
    const glyph_style = if (hot or focused) bold(base) else dim(base);
    const glyph = if (ui.ascii or !ui.nerd_font or it.glyph.len == 0) it.fallback else it.glyph;
    var x = cell.x;
    if (with_label) {
        if (focused) {
            _ = ui.putStr(x, cell.y, 1, if (ui.ascii) cursor_ascii else cursor_glyph, bold(Theme.withFg(Theme.onBg(th.fg, ground), pal.blue)));
        }
        x += 1;
        x += ui.putStr(x, cell.y, cell.right() -| x, glyph, glyph_style);
        if (it.running) x += ui.putStr(x, cell.y, cell.right() -| x, if (ui.ascii) running_ascii else running_dot, dotStyle(th, ground));
        x += 1;
        const label_style = if (hot or focused)
            Theme.onBg(th.fg, ground)
        else
            dim(Theme.withFg(Theme.onBg(th.fg, ground), pal.comment));
        _ = ui.putStr(x, cell.y, cell.right() -| x, it.label, label_style);
        return;
    }
    // A side dock: the dot takes the padding cell before the glyph,
    // and the keyboard cursor takes it when both want it.
    if (focused) {
        _ = ui.putStr(x, cell.y, 1, if (ui.ascii) cursor_ascii else cursor_glyph, bold(Theme.withFg(Theme.onBg(th.fg, ground), pal.blue)));
    } else if (it.running) {
        _ = ui.putStr(x, cell.y, 1, if (ui.ascii) running_ascii else running_dot, dotStyle(th, ground));
    }
    _ = ui.putStr(cell.x + 1, cell.y, cell.w -| 1, glyph, glyph_style);
}

fn dotStyle(th: *const Theme, ground: vaxis.Color) Style {
    return bold(Theme.withFg(Theme.onBg(th.fg, ground), th.palette.green));
}

fn dim(s: Style) Style {
    var out = s;
    out.dim = true;
    return out;
}

fn bold(s: Style) Style {
    var out = s;
    out.bold = true;
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const test_fixture = @import("test_fixture.zig");

const sample = [_]Item{
    .{ .glyph = "\u{EB01}", .fallback = "B", .color = "blue", .label = "Browser" },
    .{ .glyph = "\u{F1D8}", .fallback = "H", .color = "teal", .label = "HTTP", .running = true },
};

test "bottom: the items lay left to right with their labels, each a hit; the pin chip takes the strip's last three cells" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom });
    var buf: [256]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "Browser") != null);
    try t.expect(std.mem.indexOf(u8, row, "HTTP") != null);
    // The running item wears its dot; the idle one does not.
    try t.expect(std.mem.indexOf(u8, row, running_dot) != null);
    try t.expectEqual(@as(u16, 0), fx.hits.at(1, 5).?.launcher_dock.item);
    try t.expectEqual(@as(u16, 1), fx.hits.at(12, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(57, 5).?.launcher_dock == .pin);
    try t.expect(pinRect(area, .bottom).eql(Rect.init(57, 5, 3, 1)));
}

test "side: one item per row, glyph only, the running dot in the padding cell; the pin chip sits on the last row" {
    var fx = try test_fixture.init(10, 12);
    defer fx.deinit();
    const area = Rect.init(0, 1, width, 10);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .left });
    try t.expectEqualStrings("\u{EB01}", fx.cell(1, 1).char.grapheme);
    try t.expectEqualStrings("\u{F1D8}", fx.cell(1, 2).char.grapheme);
    try t.expectEqualStrings(running_dot, fx.cell(0, 2).char.grapheme);
    try t.expectEqualStrings(" ", fx.cell(0, 1).char.grapheme);
    try t.expectEqual(@as(u16, 0), fx.hits.at(1, 1).?.launcher_dock.item);
    try t.expectEqual(@as(u16, 1), fx.hits.at(2, 2).?.launcher_dock.item);
    try t.expect(fx.hits.at(1, 10).?.launcher_dock == .pin);
}

test "the item under the pointer brightens — it sheds its dim onto a lighter ground and keeps its colour; the keyboard cursor paints ▸" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom });
    const cold = fx.style(2, 5);
    try t.expect(cold.dim);

    fx.hits.reset();
    fx.hover = .{ .x = 2, .y = 5 };
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom });
    const hot = fx.style(2, 5);
    try t.expect(!hot.dim);
    try t.expect(!vaxis.Color.eql(cold.bg, hot.bg));
    try t.expect(vaxis.Color.eql(cold.fg, hot.fg));

    // The keyboard cursor lights its item without the pointer.
    fx.hits.reset();
    fx.hover = null;
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .cursor = 1 });
    var buf: [256]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, fx.row(5, &buf), cursor_glyph) != null);
}

test "ascii: the twins, and no Nerd Font glyph anywhere on the strip" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    var ui = fx.ui();
    ui.ascii = true;
    draw(ui, Rect.init(0, 5, 60, 1), .{ .items = &sample, .edge = .bottom, .pinned = true });
    var buf: [256]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "B Browser") != null);
    try t.expect(std.mem.indexOf(u8, row, pin_ascii) != null);
    try t.expect(std.mem.indexOf(u8, row, pin_glyph) == null);
    try t.expect(std.mem.indexOf(u8, row, "\u{EB01}") == null);
    try t.expect(std.mem.indexOf(u8, row, running_dot) == null);
}

test "a strip too narrow for the next item drops it whole rather than painting half a label" {
    var fx = try test_fixture.init(20, 6);
    defer fx.deinit();
    draw(fx.ui(), Rect.init(0, 5, 20, 1), .{ .items = &sample, .edge = .bottom });
    var buf: [64]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "Browser") != null);
    try t.expect(std.mem.indexOf(u8, row, "HTTP") == null);
    try t.expect(fx.hits.at(12, 5) == null or fx.hits.at(12, 5).?.launcher_dock == .pin);
}
