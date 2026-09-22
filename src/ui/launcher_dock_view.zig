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
//! `Props.labels` (`ui.dock.labels`) is how much of an item the bottom
//! row paints. `.icon` gives each item the same three cells a side dock
//! has, laid left to right, and the name moves to the tooltip; `.label`
//! drops the glyph instead and paints the word alone, with the running
//! dot (and the keyboard cursor) in the one padding cell before it. A
//! side dock is icon-only by geometry and ignores the field — three
//! cells is all it has, `.label` included.
//!
//! Under `.label` the word takes the glyph's own styling, because with
//! no glyph beside it the word is what carries the item's colour.
//!
//! `Props.align` (`ui.dock.align`) is where the run sits: `.center` is
//! the shipped look, the way macOS's Dock centres its icons, and the
//! pin chip keeps the far end whatever it says. A run too long to
//! centre falls back to `.start` — it is never clipped on the left.
//!
//! An item carries its integration's category colour, the way a pinned
//! rail icon does, because the colour is the integration's identity;
//! the app resolves the role to a colour before it hands the item over
//! (`Item.color`), so a terminal item can wear the split cluster's own
//! chip colour rather than a role name that stands in for it.
//!
//! // changed (dock-polish): a running one is told from the idle ones
//! by BRIGHTNESS (`Props.running_mark = .bright`, the default) — its
//! glyph and its word at full strength, the idle ones dim — the way
//! the tab bar tells its active tab from the rest, and no extra cell.
//! macOS's under-icon dot has no row to sit on in a one-row strip, and
//! the `●` that stood in for it read as large and out of place. `.dot`
//! brings a small `•` back, in the ITEM's colour rather than a green
//! of its own, in the padding cell before the glyph; `.none` marks
//! nothing. None of the three moves the row: the cell the dot takes is
//! the padding cell every form already keeps.
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
const pin_chip = @import("pin_chip.zig");

const Style = Ui.Style;

/// A side dock's width: padding, glyph, padding — the activity bar's.
pub const width: u16 = 3;
/// The pin chip at the strip's end (`view.dock_pin`) — the family's
/// (`ui/pin_chip.zig`), the same one the sidebar and the menu bar wear.
pub const pin_glyph = pin_chip.pin_glyph;
pub const pin_ascii = pin_chip.pin_ascii;
/// The dot a running item wears under `.dot` — a SMALL one, macOS's
/// under-icon dot as near as a cell grid gets; the large `●` it used to
/// be is the dirty dot's, and it read as a second glyph on the strip.
pub const running_dot = "\u{2022}"; // •
pub const running_ascii = "*";
/// The keyboard cursor.
pub const cursor_glyph = "\u{25b8}"; // ▸
pub const cursor_ascii = ">";

pub const Edge = enum { bottom, left, right };
/// `ui.dock.labels` — how much of an item a bottom strip paints.
pub const Labels = enum { icon, icon_label, label };
/// `ui.dock.align` — where the run sits along the strip.
pub const Align = enum { start, center, end };
/// `ui.dock.running_mark` — how a running item is told from the rest.
pub const RunningMark = enum { bright, dot, none };

pub const Item = struct {
    glyph: []const u8,
    fallback: []const u8,
    /// The item's colour, already chosen: an integration's category
    /// colour resolved from its role, the terminal chip's own.
    color: vaxis.Color,
    label: []const u8,
    /// The item's thing is open: a mounted integration, a live pty.
    running: bool = false,
};

pub const Props = struct {
    items: []const Item,
    edge: Edge,
    /// How much of an item a bottom strip paints; a side one is
    /// icon-only whatever this says.
    labels: Labels = .icon_label,
    /// Where the run sits along the strip.
    @"align": Align = .center,
    /// The keyboard cursor's item, when the dock has the keys.
    cursor: ?u16 = null,
    /// The pin chip is lit (the dock is pinned open).
    pinned: bool = false,
    /// How a running item is marked.
    running_mark: RunningMark = .bright,
};

/// Where the pin chip goes on a bottom strip: the last three cells.
pub fn pinRect(area: Rect, edge: Edge) Rect {
    if (area.isEmpty()) return .empty;
    return switch (edge) {
        .bottom => if (area.w < 4) .empty else Rect.init(area.right() - 3, area.y, 3, 1),
        .left, .right => if (area.h < 2) .empty else Rect.init(area.x, area.bottom() - 1, area.w, 1),
    };
}

/// The cells an item takes on a bottom strip. Under `.icon_label`:
/// the glyph, its dot under `.dot`, a space, the label, and one cell
/// of air either side. Under `.icon` it is the side form's three — a
/// padding cell (the dot's, or the keyboard cursor's), the glyph, a
/// padding cell — whether or not it is running, so the row does not
/// shuffle when a thing opens. Under `.label` it is that same padding
/// cell, the word, and one cell of air: the dot keeps a cell, it is
/// just the one the glyph is not in, so this form does not shuffle
/// either. `.bright` and `.none` buy no cell in any form.
fn itemWidth(ui: Ui, it: Item, labels: Labels, mark: RunningMark) u16 {
    return switch (labels) {
        .icon => width,
        .label => 1 + ui.width(it.label) + 1,
        .icon_label => 1 + 1 + @as(u16, if (it.running and mark == .dot) 1 else 0) + 1 + ui.width(it.label) + 1,
    };
}

/// Where the run starts on a bottom strip, given the cells it needs.
/// `left` is the strip's first cell and `right` the first cell the pin
/// chip (or the frame) has taken; the run always keeps the strip's one
/// leading cell of air, so a run with nowhere to go reads from the
/// start rather than off the left edge.
fn rowStart(left: u16, right: u16, total: u16, a: Align) u16 {
    const first = left + 1;
    return switch (a) {
        .start => first,
        .center => @max(first, left + (right -| left -| total) / 2),
        .end => @max(first, right -| total),
    };
}

/// The same sum down a side strip, where every item is one row and
/// there is no leading cell of air to keep.
fn colStart(top: u16, bottom: u16, rows: u16, a: Align) u16 {
    return switch (a) {
        .start => top,
        .center => top + (bottom -| top -| rows) / 2,
        .end => @max(top, bottom -| rows),
    };
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
    pin_chip.draw(ui, pinRect(area, props.edge), .{ .pinned = props.pinned, .bg = bg, .hit = .{ .launcher_dock = .pin } });
}

fn drawRow(ui: Ui, area: Rect, props: Props, bg: vaxis.Color, hover_bg: vaxis.Color) void {
    // The pin chip owns the strip's tail; items stop before it.
    const limit = pinRect(area, .bottom);
    const right_edge = if (limit.isEmpty()) area.right() else limit.x;
    // Which items fit, and what they cost — measured from the strip's
    // own start, so the answer is the alignment's input, never its
    // output: moving the run must never change which items are on it.
    var fits: usize = 0;
    var total: u16 = 0;
    {
        var x: u16 = area.x + 1;
        for (props.items) |it| {
            const w = itemWidth(ui, it, props.labels, props.running_mark);
            if (x + w > right_edge) break;
            x += w;
            total += w;
            fits += 1;
        }
    }
    var x = rowStart(area.x, right_edge, total, props.@"align");
    for (props.items[0..fits], 0..) |it, i| {
        const w = itemWidth(ui, it, props.labels, props.running_mark);
        const cell = Rect.init(x, area.y, w, 1);
        paintItem(ui, cell, it, props.cursor == @as(u16, @intCast(i)), bg, hover_bg, props.labels, props.running_mark);
        ui.hit(cell, .{ .launcher_dock = .{ .item = @intCast(i) } });
        x += w;
    }
}

fn drawColumn(ui: Ui, area: Rect, props: Props, bg: vaxis.Color, hover_bg: vaxis.Color) void {
    const limit = pinRect(area, .left);
    const bottom_edge = if (limit.isEmpty()) area.bottom() else limit.y;
    const fits = @min(props.items.len, bottom_edge -| area.y);
    var y = colStart(area.y, bottom_edge, @intCast(fits), props.@"align");
    for (props.items[0..fits], 0..) |it, i| {
        const cell = Rect.init(area.x, y, area.w, 1);
        paintItem(ui, cell, it, props.cursor == @as(u16, @intCast(i)), bg, hover_bg, .icon, props.running_mark);
        ui.hit(cell, .{ .launcher_dock = .{ .item = @intCast(i) } });
        y += 1;
    }
}

/// One item in its own cell run, in one of the three forms: a side
/// dock and a bottom one under `.icon` paint the glyph alone and leave
/// the label to the tip, `.icon_label` paints both, and `.label`
/// paints the word with no glyph at all.
fn paintItem(ui: Ui, cell: Rect, it: Item, focused: bool, bg: vaxis.Color, hover_bg: vaxis.Color, form: Labels, mark: RunningMark) void {
    const th = ui.theme;
    const pal = th.palette;
    const hot = ui.hovered(cell);
    const ground = if (hot or focused) hover_bg else bg;
    if (hot or focused) ui.fill(cell, Theme.onBg(th.fg, ground));
    const base = Theme.withFg(Theme.onBg(th.fg, ground), it.color);
    // The item keeps its colour when it lights — the colour IS the
    // integration's identity — and only sheds the `dim`. A running one
    // under `.bright` has shed it already: that is the mark.
    const lit = it.running and mark == .bright;
    const glyph_style = if (hot or focused) bold(base) else if (lit) base else dim(base);
    const glyph = if (ui.ascii or !ui.nerd_font or it.glyph.len == 0) it.fallback else it.glyph;
    const grey = Theme.withFg(Theme.onBg(th.fg, ground), pal.comment);
    const label_style = if (hot or focused)
        Theme.onBg(th.fg, ground)
    else if (lit)
        grey
    else
        dim(grey);
    // The dot, when there is one, is the item's own colour — never a
    // colour of its own, which made every running thing look alike.
    const show_dot = it.running and mark == .dot;
    const dot = if (ui.ascii) running_ascii else running_dot;
    var x = cell.x;
    if (form == .label) {
        // The word alone. The padding cell before it is the cursor's,
        // then the dot's — the same cell the icon form shares them on,
        // so the run's width never moves when a thing opens.
        if (focused) {
            _ = ui.putStr(x, cell.y, 1, if (ui.ascii) cursor_ascii else cursor_glyph, bold(Theme.withFg(Theme.onBg(th.fg, ground), pal.blue)));
        } else if (show_dot) {
            _ = ui.putStr(x, cell.y, 1, dot, base);
        }
        x += 1;
        // The word wears the item's own colour here, not the label
        // grey the `.icon_label` form gives it: with no glyph beside
        // it the word IS the icon, and the colour is the item's
        // identity (the rule at the top of this file). So it takes the
        // glyph's treatment exactly — `dim` when cold, `bold` when the
        // pointer or the cursor is on it.
        _ = ui.putStr(x, cell.y, cell.right() -| x, it.label, glyph_style);
        return;
    }
    if (form == .icon_label) {
        if (focused) {
            _ = ui.putStr(x, cell.y, 1, if (ui.ascii) cursor_ascii else cursor_glyph, bold(Theme.withFg(Theme.onBg(th.fg, ground), pal.blue)));
        }
        x += 1;
        x += ui.putStr(x, cell.y, cell.right() -| x, glyph, glyph_style);
        if (show_dot) x += ui.putStr(x, cell.y, cell.right() -| x, dot, base);
        x += 1;
        _ = ui.putStr(x, cell.y, cell.right() -| x, it.label, label_style);
        return;
    }
    // The icon form: the dot takes the padding cell before the glyph,
    // and the keyboard cursor takes it when both want it.
    if (focused) {
        _ = ui.putStr(x, cell.y, 1, if (ui.ascii) cursor_ascii else cursor_glyph, bold(Theme.withFg(Theme.onBg(th.fg, ground), pal.blue)));
    } else if (show_dot) {
        _ = ui.putStr(x, cell.y, 1, dot, base);
    }
    _ = ui.putStr(cell.x + 1, cell.y, cell.w -| 1, glyph, glyph_style);
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

const blue = Theme.rgb(0x61afef);
const teal = Theme.rgb(0x56b6c2);
const sample = [_]Item{
    .{ .glyph = "\u{EB01}", .fallback = "B", .color = blue, .label = "Browser" },
    .{ .glyph = "\u{F1D8}", .fallback = "H", .color = teal, .label = "HTTP", .running = true },
};

test "bottom: the items lay left to right with their labels, each a hit; the pin chip takes the strip's last three cells" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    // `.start` is this test's subject: the run from the strip's first
    // cell. Where the shipped `.center` puts it is its own test.
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .start });
    var buf: [256]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "Browser") != null);
    try t.expect(std.mem.indexOf(u8, row, "HTTP") != null);
    // // changed (dock-polish): the shipped mark is brightness, so no
    // dot is on the row; the running item is the one whose glyph is
    // not dim. Item 0 is ` <glyph> Browser ` from x=1 (glyph at 2),
    // item 1 ` <glyph> HTTP ` from x=12 (glyph at 13).
    try t.expect(std.mem.indexOf(u8, row, running_dot) == null);
    try t.expect(fx.style(2, 5).dim);
    try t.expect(!fx.style(13, 5).dim);
    try t.expectEqual(@as(u16, 0), fx.hits.at(1, 5).?.launcher_dock.item);
    try t.expectEqual(@as(u16, 1), fx.hits.at(12, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(57, 5).?.launcher_dock == .pin);
    try t.expect(pinRect(area, .bottom).eql(Rect.init(57, 5, 3, 1)));
}

test "the running mark: `.bright` lifts the running item's glyph and word out of the dim and spends no cell; `.dot` paints a small dot in the ITEM's colour and buys it a cell under .icon_label; `.none` marks nothing" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    const ui = fx.ui();
    // `.bright` — the default: the glyph at 13 and the word at 15 shed
    // their dim; the idle item's (2, 4) keep it. Neither is bold: bold
    // is the pointer's and the cursor's.
    draw(ui, area, .{ .items = &sample, .edge = .bottom, .@"align" = .start });
    try t.expect(fx.style(2, 5).dim and fx.style(4, 5).dim);
    try t.expect(!fx.style(13, 5).dim and !fx.style(15, 5).dim);
    try t.expect(!fx.style(13, 5).bold);
    try t.expect(vaxis.Color.eql(teal, fx.style(13, 5).fg));
    try t.expectEqual(@as(u16, 8), itemWidth(ui, sample[1], .icon_label, .bright));
    try t.expectEqual(itemWidth(ui, sample[1], .icon_label, .bright), itemWidth(ui, sample[1], .icon_label, .none));
    // `.dot`: the dot follows the glyph, in the item's own colour —
    // teal, not a green of its own — and the glyph goes back to dim.
    fx.hits.reset();
    draw(ui, area, .{ .items = &sample, .edge = .bottom, .@"align" = .start, .running_mark = .dot });
    try t.expectEqualStrings(running_dot, fx.cell(14, 5).char.grapheme);
    try t.expect(vaxis.Color.eql(teal, fx.style(14, 5).fg));
    try t.expect(!vaxis.Color.eql(ui.theme.palette.green, fx.style(14, 5).fg));
    try t.expect(fx.style(13, 5).dim);
    try t.expectEqual(@as(u16, 9), itemWidth(ui, sample[1], .icon_label, .dot));
    // `.none`: no dot, nothing lifted.
    fx.hits.reset();
    var buf: [256]u8 = undefined;
    draw(ui, area, .{ .items = &sample, .edge = .bottom, .@"align" = .start, .running_mark = .none });
    try t.expect(std.mem.indexOf(u8, fx.row(5, &buf), running_dot) == null);
    try t.expect(fx.style(13, 5).dim);
    // The idle item's width is the same under all three: the mark is
    // the running item's business alone.
    for ([_]RunningMark{ .bright, .dot, .none }) |m| try t.expectEqual(@as(u16, 11), itemWidth(ui, sample[0], .icon_label, m));
}

test "side: one item per row, glyph only, the running item bright — or, under `.dot`, its dot in the padding cell; the pin chip sits on the last row" {
    var fx = try test_fixture.init(10, 12);
    defer fx.deinit();
    const area = Rect.init(0, 1, width, 10);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .left, .@"align" = .start });
    try t.expectEqualStrings("\u{EB01}", fx.cell(1, 1).char.grapheme);
    try t.expectEqualStrings("\u{F1D8}", fx.cell(1, 2).char.grapheme);
    try t.expectEqualStrings(" ", fx.cell(0, 2).char.grapheme);
    try t.expectEqualStrings(" ", fx.cell(0, 1).char.grapheme);
    try t.expect(fx.style(1, 1).dim);
    try t.expect(!fx.style(1, 2).dim);
    try t.expectEqual(@as(u16, 0), fx.hits.at(1, 1).?.launcher_dock.item);
    try t.expectEqual(@as(u16, 1), fx.hits.at(2, 2).?.launcher_dock.item);
    try t.expect(fx.hits.at(1, 10).?.launcher_dock == .pin);
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .left, .@"align" = .start, .running_mark = .dot });
    try t.expectEqualStrings(running_dot, fx.cell(0, 2).char.grapheme);
    try t.expect(vaxis.Color.eql(teal, fx.style(0, 2).fg));
}

test "the item under the pointer brightens — it sheds its dim onto a lighter ground and keeps its colour; the keyboard cursor paints ▸" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .start });
    const cold = fx.style(2, 5);
    try t.expect(cold.dim);

    fx.hits.reset();
    fx.hover = .{ .x = 2, .y = 5 };
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .start });
    const hot = fx.style(2, 5);
    try t.expect(!hot.dim);
    try t.expect(!vaxis.Color.eql(cold.bg, hot.bg));
    try t.expect(vaxis.Color.eql(cold.fg, hot.fg));

    // The keyboard cursor lights its item without the pointer.
    fx.hits.reset();
    fx.hover = null;
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .start, .cursor = 1 });
    var buf: [256]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, fx.row(5, &buf), cursor_glyph) != null);
}

test "ascii: the twins, and no Nerd Font glyph anywhere on the strip" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    var ui = fx.ui();
    ui.ascii = true;
    draw(ui, Rect.init(0, 5, 60, 1), .{ .items = &sample, .edge = .bottom, .@"align" = .start, .pinned = true });
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
    draw(fx.ui(), Rect.init(0, 5, 20, 1), .{ .items = &sample, .edge = .bottom, .@"align" = .start });
    var buf: [64]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "Browser") != null);
    try t.expect(std.mem.indexOf(u8, row, "HTTP") == null);
    try t.expect(fx.hits.at(12, 5) == null or fx.hits.at(12, 5).?.launcher_dock == .pin);
}

test "itemWidth: the label form pays for its label and its dot; the icon form is the side dock's three cells, running or not" {
    var fx = try test_fixture.init(20, 2);
    defer fx.deinit();
    const ui = fx.ui();
    // ` ▸/pad <glyph> <label> ` — 1 + glyph + space + label + 1, plus
    // the dot's cell when it is running and the mark is the dot.
    try t.expectEqual(@as(u16, 11), itemWidth(ui, sample[0], .icon_label, .dot)); // "Browser" = 7
    try t.expectEqual(@as(u16, 9), itemWidth(ui, sample[1], .icon_label, .dot)); // "HTTP" = 4, + the dot
    // The icon form does not resize with the label or with the dot, so
    // the row cannot shuffle under a pointer when a thing opens.
    try t.expectEqual(width, itemWidth(ui, sample[0], .icon, .dot));
    try t.expectEqual(width, itemWidth(ui, sample[1], .icon, .dot));
    const long = Item{ .glyph = "\u{EB01}", .fallback = "B", .color = blue, .label = "a much longer label than any of these" };
    try t.expectEqual(width, itemWidth(ui, long, .icon, .dot));
    try t.expect(itemWidth(ui, long, .icon_label, .dot) > itemWidth(ui, sample[0], .icon_label, .dot));
}

test "bottom under .icon: the glyph alone in the side form's three cells, no label text, the dot in the padding cell, and the hits match the painted run" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .icon, .@"align" = .start, .running_mark = .dot });
    var buf: [256]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "Browser") == null);
    try t.expect(std.mem.indexOf(u8, row, "HTTP") == null);
    // Item 0 starts at x=1: padding, glyph, padding. Item 1 follows at 4.
    try t.expectEqualStrings("\u{EB01}", fx.cell(2, 5).char.grapheme);
    try t.expectEqualStrings("\u{F1D8}", fx.cell(5, 5).char.grapheme);
    // The running dot keeps its place — the padding cell before the
    // glyph, exactly as a side dock puts it.
    try t.expectEqualStrings(running_dot, fx.cell(4, 5).char.grapheme);
    try t.expectEqualStrings(" ", fx.cell(1, 5).char.grapheme);
    // Every painted cell of a run is that item's hit, and no more.
    for ([_]u16{ 1, 2, 3 }) |x| try t.expectEqual(@as(u16, 0), fx.hits.at(x, 5).?.launcher_dock.item);
    for ([_]u16{ 4, 5, 6 }) |x| try t.expectEqual(@as(u16, 1), fx.hits.at(x, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(7, 5) == null);
}

test "bottom under .icon: the keyboard cursor and the hover still read, on the same cells the icons take" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .icon, .@"align" = .start });
    const cold = fx.style(2, 5);
    try t.expect(cold.dim);

    // The pointer on the item's run brightens it and keeps its colour.
    fx.hits.reset();
    fx.hover = .{ .x = 2, .y = 5 };
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .icon, .@"align" = .start });
    const hot = fx.style(2, 5);
    try t.expect(!hot.dim);
    try t.expect(!vaxis.Color.eql(cold.bg, hot.bg));
    try t.expect(vaxis.Color.eql(cold.fg, hot.fg));

    // The cursor paints ▸ in the padding cell — the dot's cell, which
    // it takes when both want it.
    fx.hits.reset();
    fx.hover = null;
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .icon, .@"align" = .start, .cursor = 1 });
    try t.expectEqualStrings(cursor_glyph, fx.cell(4, 5).char.grapheme);
}

test "itemWidth: the third form pays for its word and nothing else — no glyph cell, and the dot shares the padding cell so the run never shuffles" {
    var fx = try test_fixture.init(20, 2);
    defer fx.deinit();
    const ui = fx.ui();
    // ` <label> ` — the padding cell (the cursor's, then the dot's),
    // the word, one cell of air.
    try t.expectEqual(@as(u16, 9), itemWidth(ui, sample[0], .label, .dot)); // "Browser" = 7
    try t.expectEqual(@as(u16, 6), itemWidth(ui, sample[1], .label, .dot)); // "HTTP" = 4
    // Running or not is the same width, as under `.icon` — unlike
    // `.icon_label`, which buys the dot its own cell under `.dot`.
    var idle = sample[1];
    idle.running = false;
    try t.expectEqual(itemWidth(ui, sample[1], .label, .dot), itemWidth(ui, idle, .label, .dot));
    try t.expect(itemWidth(ui, sample[1], .icon_label, .dot) != itemWidth(ui, idle, .icon_label, .dot));
    // The three forms in order: icons are narrowest, words next, both widest.
    try t.expect(itemWidth(ui, sample[0], .icon, .dot) < itemWidth(ui, sample[0], .label, .dot));
    try t.expect(itemWidth(ui, sample[0], .label, .dot) < itemWidth(ui, sample[0], .icon_label, .dot));
}

test "rowStart / colStart: the three alignments' offsets, and a run with no room clamps to the start rather than off the left edge" {
    // A 60-cell strip from x=0 whose pin chip starts at 57, holding a
    // 20-cell run: 1..57 is what the items may have.
    try t.expectEqual(@as(u16, 1), rowStart(0, 57, 20, .start));
    try t.expectEqual(@as(u16, 18), rowStart(0, 57, 20, .center)); // (57-0-20)/2
    try t.expectEqual(@as(u16, 37), rowStart(0, 57, 20, .end)); // 57-20
    // Off the origin, the sum travels with it.
    try t.expectEqual(@as(u16, 11), rowStart(10, 67, 20, .start));
    try t.expectEqual(@as(u16, 28), rowStart(10, 67, 20, .center)); // 10 + (67-10-20)/2
    try t.expectEqual(@as(u16, 47), rowStart(10, 67, 20, .end)); // 67-20
    // A run that fills the strip: every alignment is the start, and no
    // alignment can push it left of the strip's own leading cell.
    for ([_]Align{ .start, .center, .end }) |a| {
        try t.expectEqual(@as(u16, 1), rowStart(0, 57, 56, a));
        try t.expectEqual(@as(u16, 1), rowStart(0, 57, 200, a));
        try t.expectEqual(@as(u16, 1), rowStart(0, 2, 1, a));
    }
    // A column: rows 1..11 holding three items.
    try t.expectEqual(@as(u16, 1), colStart(1, 11, 3, .start));
    try t.expectEqual(@as(u16, 4), colStart(1, 11, 3, .center)); // (11-1-3)/2 = 3
    try t.expectEqual(@as(u16, 8), colStart(1, 11, 3, .end));
    for ([_]Align{ .start, .center, .end }) |a| try t.expectEqual(@as(u16, 1), colStart(1, 11, 10, a));
}

test "bottom under .label: the word alone — no glyph on the strip at all — the dot in the padding cell before it, and the hits match the painted run" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .label, .@"align" = .start, .running_mark = .dot });
    var buf: [256]u8 = undefined;
    const row = fx.row(5, &buf);
    try t.expect(std.mem.indexOf(u8, row, "Browser") != null);
    try t.expect(std.mem.indexOf(u8, row, "HTTP") != null);
    try t.expect(std.mem.indexOf(u8, row, "\u{EB01}") == null);
    try t.expect(std.mem.indexOf(u8, row, "\u{F1D8}") == null);
    // Item 0 is ` Browser ` from x=1: the word starts at 2 and the run
    // ends at 9. Item 1 follows at 10, and its dot takes that cell.
    try t.expectEqualStrings("B", fx.cell(2, 5).char.grapheme);
    try t.expectEqualStrings(running_dot, fx.cell(10, 5).char.grapheme);
    try t.expectEqualStrings("H", fx.cell(11, 5).char.grapheme);
    for ([_]u16{ 1, 2, 9 }) |x| try t.expectEqual(@as(u16, 0), fx.hits.at(x, 5).?.launcher_dock.item);
    for ([_]u16{ 10, 11, 15 }) |x| try t.expectEqual(@as(u16, 1), fx.hits.at(x, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(16, 5) == null);
    // The word carries the item's colour, the way the glyph does in
    // every other form: cold it is dim, and the pointer on it brightens
    // it without changing the colour.
    const cold = fx.style(2, 5);
    try t.expect(cold.dim);
    try t.expect(vaxis.Color.eql(cold.fg, fx.style(11, 5).fg) == false); // Browser's blue is not HTTP's teal
    fx.hits.reset();
    fx.hover = .{ .x = 3, .y = 5 };
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .label, .@"align" = .start, .running_mark = .dot });
    const hot = fx.style(2, 5);
    try t.expect(!hot.dim);
    try t.expect(vaxis.Color.eql(cold.fg, hot.fg));
    fx.hover = null;
    // The keyboard cursor takes the dot's cell, the way it does under
    // `.icon` — so focusing an open thing never moves the word.
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .labels = .label, .@"align" = .start, .cursor = 1, .running_mark = .dot });
    try t.expectEqualStrings(cursor_glyph, fx.cell(10, 5).char.grapheme);
    try t.expectEqualStrings("H", fx.cell(11, 5).char.grapheme);
}

test "the run is centred by default and the alignment slides it whole — the same items, the same widths, a different offset; the pin chip never moves" {
    var fx = try test_fixture.init(60, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 60, 1);
    // `.icon_label`: 11 + 8 = 19 cells of items (the running mark is
    // brightness, so no dot cell), 1..57 to put them in, so the centred
    // run is 19..38.
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .center });
    try t.expectEqual(@as(u16, 0), fx.hits.at(19, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(18, 5) == null);
    try t.expectEqual(@as(u16, 1), fx.hits.at(30, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(38, 5) == null);
    // The centre is the shipped default: omitting the field is the
    // same paint.
    var buf: [256]u8 = undefined;
    var centred: [256]u8 = undefined;
    const with = fx.row(5, &centred);
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom });
    try t.expectEqualStrings(with, fx.row(5, &buf));

    // `.start` puts it back at the strip's first cell.
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .start });
    try t.expectEqual(@as(u16, 0), fx.hits.at(1, 5).?.launcher_dock.item);
    try t.expectEqual(@as(u16, 1), fx.hits.at(12, 5).?.launcher_dock.item);

    // `.end` puts it against the pin chip — and never under it.
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = .end, .pinned = true });
    try t.expectEqual(@as(u16, 1), fx.hits.at(56, 5).?.launcher_dock.item);
    try t.expectEqual(@as(u16, 0), fx.hits.at(38, 5).?.launcher_dock.item);
    try t.expect(fx.hits.at(37, 5) == null);
    // The pin chip's three cells are its own whatever the run does.
    try t.expect(fx.hits.at(57, 5).?.launcher_dock == .pin);
    try t.expect(pinRect(area, .bottom).eql(Rect.init(57, 5, 3, 1)));
}

test "a narrow strip drops the item that will not fit and never pushes the rest off the left edge — which items are on the strip is the alignment's input, not its output" {
    var fx = try test_fixture.init(20, 6);
    defer fx.deinit();
    const area = Rect.init(0, 5, 20, 1);
    // 1..17 for the items: only ` Browser ` (11) fits, and the SAME one
    // fits under every alignment — sliding the run must never change
    // what is on it. Its six spare cells put the start at 1 / 3 / 6.
    const starts = [_]u16{ 1, 3, 6 };
    for ([_]Align{ .start, .center, .end }, starts) |a, at| {
        fx.hits.reset();
        draw(fx.ui(), area, .{ .items = &sample, .edge = .bottom, .@"align" = a });
        var buf: [64]u8 = undefined;
        const row = fx.row(5, &buf);
        try t.expect(std.mem.indexOf(u8, row, "Browser") != null);
        try t.expect(std.mem.indexOf(u8, row, "HTTP") == null);
        try t.expect(fx.hits.at(0, 5) == null);
        try t.expectEqual(@as(u16, 0), fx.hits.at(at, 5).?.launcher_dock.item);
    }
    // Narrower still, with nothing to spare: every alignment reads from
    // the strip's own first cell rather than off the edge.
    const tight = Rect.init(0, 5, 15, 1); // pin at 12, items 1..12 — exactly ` Browser `
    for ([_]Align{ .start, .center, .end }) |a| {
        fx.hits.reset();
        draw(fx.ui(), tight, .{ .items = &sample, .edge = .bottom, .@"align" = a });
        try t.expect(fx.hits.at(0, 5) == null);
        try t.expectEqual(@as(u16, 0), fx.hits.at(1, 5).?.launcher_dock.item);
    }
}

test "side: the alignment centres the items down the column, and the pin chip keeps the last row" {
    var fx = try test_fixture.init(10, 12);
    defer fx.deinit();
    const area = Rect.init(0, 1, width, 10);
    // Rows 1..10 are the items' (the pin chip takes 10): centred puts
    // the two of them at 4 and 5.
    draw(fx.ui(), area, .{ .items = &sample, .edge = .left, .@"align" = .center });
    try t.expectEqualStrings("\u{EB01}", fx.cell(1, 4).char.grapheme);
    try t.expectEqualStrings("\u{F1D8}", fx.cell(1, 5).char.grapheme);
    try t.expectEqual(@as(u16, 0), fx.hits.at(1, 4).?.launcher_dock.item);
    try t.expect(fx.hits.at(1, 1) == null);
    // `.start` is the top of the column; `.end` sits on the pin chip's row.
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .left, .@"align" = .start });
    try t.expectEqualStrings("\u{EB01}", fx.cell(1, 1).char.grapheme);
    fx.hits.reset();
    draw(fx.ui(), area, .{ .items = &sample, .edge = .left, .@"align" = .end });
    try t.expectEqualStrings("\u{EB01}", fx.cell(1, 8).char.grapheme);
    try t.expectEqualStrings("\u{F1D8}", fx.cell(1, 9).char.grapheme);
    try t.expect(fx.hits.at(1, 10).?.launcher_dock == .pin);
}
