//! The pane rail — the one-cell colour stripe down a pane's left edge
//! that says which pane you are looking at. A Claude session has worn
//! one since the sessions work (its SESSIONS card wears the same
//! colour); every other pane went without, so two shells side by side
//! were two identical grey rectangles.
//!
//! One painter, one rule: the rail is the pane's first column, full
//! pane height, in the pane's accent. A pane's body is then the rect
//! minus that column (`body`) — the rail never paints over content,
//! and content never paints over the rail.
//!
//! The rail registers no hit of its own: the pane's own hit already
//! covers the whole rect, so a click on the stripe focuses the pane
//! exactly as a click one cell to its right does.
//!
//! The editor is the one kind that does not inset. Its gutter already
//! opens with a sign column that is blank unless a diagnostic or a
//! decoration is on that line, so the rail goes into that cell after
//! the pane has painted (`drawOver`) and the numbers and the text stay
//! on the screen column they were on. A sign still wins the cell it
//! needs — an alarm is never hidden by decoration.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");

pub const Color = Theme.Color;

/// The rail is one cell, like every other marker in the app.
pub const width: u16 = list_panel.marker_w;

/// The same left half block the selection marker and the SESSIONS card
/// use — one glyph for "this thing is that colour", app-wide.
pub fn glyph(ascii: bool) []const u8 {
    return if (ascii) list_panel.marker_ascii else list_panel.marker_glyph;
}

/// What is left of `rect` for the pane's content once the rail has its
/// column. `on` false (the rail is off, or this kind paints its own)
/// gives the whole rect back, and so does a rect too narrow to spare a
/// cell — a two-column pane is all content.
pub fn body(rect: Rect, on: bool) Rect {
    if (!on or rect.w < 2) return rect;
    return Rect.init(rect.x + width, rect.y, rect.w - width, rect.h);
}

/// Paint the rail down `rect`'s first column in `color`. A rect with no
/// room for both a rail and a cell of content keeps its content.
pub fn draw(ui: Ui, rect: Rect, color: Color) void {
    if (rect.w < 2 or rect.h == 0) return;
    const bar = Rect.init(rect.x, rect.y, width, rect.h);
    ui.fill(bar, ui.theme.bg);
    const style = Theme.withFg(ui.theme.bg, color);
    const g = glyph(ui.ascii);
    var y: u16 = 0;
    while (y < rect.h) : (y += 1) _ = ui.putStr(rect.x, rect.y + y, width, g, style);
}

/// Paint the rail INTO a column the pane has already drawn: the
/// editor's gutter opens with a sign column that is blank on almost
/// every line, so the rail goes there and not one cell of the file
/// moves. A cell that is not blank keeps what it has — a diagnostic
/// sign is an alarm, and decoration never hides one — and the cell's
/// own background is kept, so the cursor line's band runs under the
/// rail unbroken.
pub fn drawOver(ui: Ui, rect: Rect, color: Color) void {
    if (rect.w < 2 or rect.h == 0) return;
    const g = glyph(ui.ascii);
    var y: u16 = 0;
    while (y < rect.h) : (y += 1) {
        const cell = ui.canvas.screen.readCell(rect.x, rect.y + y) orelse continue;
        const ch = cell.char.grapheme;
        if (ch.len != 0 and !std.mem.eql(u8, ch, " ")) continue;
        _ = ui.putStr(rect.x, rect.y + y, width, g, Theme.withFg(cell.style, color));
    }
}

/// One stripe per row, never two side by side. Several panes paint a
/// `▌` of their own in their first content column — a git graph row
/// in its lane's colour, a sessions-table row in its session's, a
/// usage account behind its gutter — and with the rail inset one cell
/// to their left that read as a double bar, `▌▌`, on every such row.
/// Called after the pane has painted: where the body's first column
/// holds the marker glyph, the pane's stripe moves into the rail's
/// cell — its colour is the row's own fact, which is why it wins that
/// row — and the cell it left keeps its ground and goes blank, so no
/// text moves. Every pane that insets gets this through
/// `render.drawPaneContent`; nothing in a pane has to know the rail
/// is there.
pub fn absorb(ui: Ui, rect: Rect) void {
    if (rect.w < 3 or rect.h == 0) return;
    const g = glyph(ui.ascii);
    const inner_x = rect.x + width;
    var y: u16 = 0;
    while (y < rect.h) : (y += 1) {
        const cell = ui.canvas.screen.readCell(inner_x, rect.y + y) orelse continue;
        if (!std.mem.eql(u8, cell.char.grapheme, g)) continue;
        const style = cell.style;
        _ = ui.putStr(rect.x, rect.y + y, width, g, style);
        _ = ui.putStr(inner_x, rect.y + y, width, " ", style);
    }
}

/// `absorb` for a pane whose body is a `ListPanel` (the sessions
/// table): the list keeps its first column for the selection marker, so
/// a row's own stripe — a session's accent — sits one cell further in,
/// and the rail, a blank and the stripe read `▌ ▌`. Either stripe moves
/// into the rail's cell: the row's own when it has one (its colour is
/// the row's fact; the selection still shows on the row's ground),
/// else the selection marker's. The cells they leave go blank on their
/// ground, so no text moves.
pub fn absorbList(ui: Ui, rect: Rect) void {
    if (rect.w < 4 or rect.h == 0) return;
    const g = glyph(ui.ascii);
    const marker_x = rect.x + width;
    const row_x = marker_x + list_panel.marker_w;
    var y: u16 = 0;
    while (y < rect.h) : (y += 1) {
        const marker = ui.canvas.screen.readCell(marker_x, rect.y + y) orelse continue;
        const own = ui.canvas.screen.readCell(row_x, rect.y + y) orelse continue;
        const marker_is = std.mem.eql(u8, marker.char.grapheme, g);
        const marker_blank = marker.char.grapheme.len == 0 or std.mem.eql(u8, marker.char.grapheme, " ");
        const own_is = std.mem.eql(u8, own.char.grapheme, g) and (marker_is or marker_blank);
        if (own_is) {
            _ = ui.putStr(rect.x, rect.y + y, width, g, own.style);
            _ = ui.putStr(row_x, rect.y + y, width, " ", own.style);
            if (marker_is) _ = ui.putStr(marker_x, rect.y + y, width, " ", marker.style);
        } else if (marker_is) {
            _ = ui.putStr(rect.x, rect.y + y, width, g, marker.style);
            _ = ui.putStr(marker_x, rect.y + y, width, " ", marker.style);
        }
    }
}

/// The focus cue on a stripe a pane painted down its own first column
/// — a mounted integration's app-colour gutter, a git pane's repo
/// gutter (`pane_accent.paintsOwnStripe`) — where the rail would have
/// been. Such a pane takes no rail, so without this its stripe said
/// nothing about the keys: an integration's gutter is its brand, dim
/// on every row but the cursor's, and read as stepped back while the
/// pane had the keys. Called after the pane has painted: each cell of
/// `rect`'s first column that holds a stripe takes `color` (the cue's
/// answer for the pane) and loses the pane's dim; its glyph, its
/// ground and its bold stay. Anything else in the column is the pane's.
pub fn recolor(ui: Ui, rect: Rect, color: Color) void {
    if (rect.w < 2 or rect.h == 0) return;
    var y: u16 = 0;
    while (y < rect.h) : (y += 1) {
        const cell = ui.canvas.screen.readCell(rect.x, rect.y + y) orelse continue;
        const g = stripeGlyph(ui.ascii, cell.char.grapheme) orelse continue;
        var s = Theme.withFg(cell.style, color);
        s.dim = false;
        _ = ui.putStr(rect.x, rect.y + y, width, g, s);
    }
}

/// `g` as a stripe: the half block, or under ASCII the rail's marker or
/// the integration SDK's `|` gutter. The literal, not the cell's own
/// bytes, so the repaint never reads the cell it is writing.
fn stripeGlyph(ascii: bool, g: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, g, list_panel.marker_glyph)) return list_panel.marker_glyph;
    if (!ascii) return null;
    if (std.mem.eql(u8, g, list_panel.marker_ascii)) return list_panel.marker_ascii;
    if (std.mem.eql(u8, g, "|")) return "|";
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the rail is one cell wide, the pane's full height, in the pane's colour" {
    var f = try Fixture.init(20, 6);
    defer f.deinit();
    const r = Rect.init(2, 1, 10, 4);
    draw(f.ui(), r, f.theme.palette.blue);
    // Every row of the rect, and only the first column.
    var y: u16 = 1;
    while (y < 5) : (y += 1) {
        try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(2, y).char.grapheme);
        try testing.expect(vaxis.Color.eql(f.cell(2, y).style.fg, f.theme.palette.blue));
        try testing.expect(!std.mem.eql(u8, list_panel.marker_glyph, f.cell(3, y).char.grapheme));
    }
    // Nothing above or below the rect.
    try testing.expect(!std.mem.eql(u8, list_panel.marker_glyph, f.cell(2, 0).char.grapheme));
    try testing.expect(!std.mem.eql(u8, list_panel.marker_glyph, f.cell(2, 5).char.grapheme));
}

test "ascii mode paints the ascii marker" {
    var f = try Fixture.init(10, 3);
    defer f.deinit();
    f.ascii = true;
    draw(f.ui(), f.full(), f.theme.palette.green);
    try testing.expectEqualStrings(list_panel.marker_ascii, f.cell(0, 0).char.grapheme);
    try testing.expectEqualStrings(">", glyph(true));
    try testing.expectEqualStrings("\u{258c}", glyph(false));
}

test "the body is the rect minus the rail; a rail that is off or has no room takes nothing" {
    const r = Rect.init(4, 2, 30, 9);
    const b = body(r, true);
    try testing.expectEqual(@as(u16, 5), b.x);
    try testing.expectEqual(@as(u16, 29), b.w);
    try testing.expectEqual(@as(u16, 2), b.y);
    try testing.expectEqual(@as(u16, 9), b.h);
    // Off: the pane keeps every cell.
    try testing.expectEqual(r.w, body(r, false).w);
    try testing.expectEqual(r.x, body(r, false).x);
    // One cell of content is the floor — a 1-wide pane is all content.
    const narrow = Rect.init(0, 0, 1, 3);
    try testing.expectEqual(@as(u16, 1), body(narrow, true).w);
    try testing.expectEqual(@as(u16, 0), body(narrow, true).x);
}

test "a rail with no room to spare paints nothing rather than eating the content" {
    var f = try Fixture.init(4, 2);
    defer f.deinit();
    draw(f.ui(), Rect.init(0, 0, 1, 2), f.theme.palette.red);
    try testing.expect(!std.mem.eql(u8, list_panel.marker_glyph, f.cell(0, 0).char.grapheme));
}

test "drawOver fills the blank cells of a column it shares, keeps their ground, and never hides a glyph" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    const ui = f.ui();
    // A pane that has already painted: a banded row, and a sign on one line.
    ui.fill(f.full(), f.theme.bg);
    ui.fill(Rect.init(0, 1, 12, 1), f.theme.cursor_line);
    _ = ui.putStr(0, 2, 1, "E", f.theme.bg);
    drawOver(ui, f.full(), f.theme.palette.orange);
    // Blank cells take the rail, in the accent.
    try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(0, 0).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.cell(0, 0).style.fg, f.theme.palette.orange));
    // The banded row keeps its ground under the rail.
    try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(0, 1).char.grapheme);
    try testing.expect(f.bgEql(0, 1, f.theme.cursor_line));
    // The sign wins its cell.
    try testing.expectEqualStrings("E", f.cell(0, 2).char.grapheme);
    // And nothing was painted one cell in.
    try testing.expect(!std.mem.eql(u8, list_panel.marker_glyph, f.cell(1, 0).char.grapheme));
}

test "absorb: a pane's own stripe beside the rail moves into the rail's cell — one bar per row, in the row's colour, no text moved" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    const ui = f.ui();
    const r = f.full();
    draw(ui, r, f.theme.palette.blue);
    const body_x = body(r, true).x;
    // Row 1: the pane painted a stripe of its own in its first column
    // (a graph lane, a session's accent) on a banded ground, text after.
    const band = Theme.withFg(f.theme.cursor_line, f.theme.palette.green);
    _ = ui.putStr(body_x, 1, 1, list_panel.marker_glyph, band);
    _ = ui.putStr(body_x + 1, 1, 3, "abc", f.theme.cursor_line);
    // Row 2: plain text right at the body's edge.
    _ = ui.putStr(body_x, 2, 3, "xyz", f.theme.bg);
    absorb(ui, r);
    // Row 1: ONE bar, in the rail's column, in the pane's colour for
    // the row; the cell it left is blank on the row's ground.
    try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(0, 1).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.cell(0, 1).style.fg, f.theme.palette.green));
    try testing.expectEqualStrings(" ", f.cell(body_x, 1).char.grapheme);
    try testing.expect(f.bgEql(body_x, 1, f.theme.cursor_line));
    try testing.expectEqualStrings("a", f.cell(body_x + 1, 1).char.grapheme);
    // Rows 0 and 2: the rail is the rail, the text untouched.
    try testing.expect(vaxis.Color.eql(f.cell(0, 0).style.fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.cell(0, 2).style.fg, f.theme.palette.blue));
    try testing.expectEqualStrings("x", f.cell(body_x, 2).char.grapheme);
}

test "absorb under --ascii matches the ascii marker, and a pane too narrow to hold both is left alone" {
    var f = try Fixture.init(8, 2);
    defer f.deinit();
    f.ascii = true;
    const ui = f.ui();
    draw(ui, f.full(), f.theme.palette.blue);
    _ = ui.putStr(1, 0, 1, list_panel.marker_ascii, Theme.withFg(f.theme.bg, f.theme.palette.red));
    absorb(ui, f.full());
    try testing.expectEqualStrings(list_panel.marker_ascii, f.cell(0, 0).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.cell(0, 0).style.fg, f.theme.palette.red));
    try testing.expectEqualStrings(" ", f.cell(1, 0).char.grapheme);
    // Two columns: the rail and one cell of content — nothing to fold.
    var g = try Fixture.init(2, 1);
    defer g.deinit();
    _ = g.ui().putStr(1, 0, 1, list_panel.marker_glyph, g.theme.bg);
    absorb(g.ui(), g.full());
    try testing.expectEqualStrings(list_panel.marker_glyph, g.cell(1, 0).char.grapheme);
}

test "absorbList: a list row's own stripe one cell in, or the selection marker, moves into the rail — never two bars on a row" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    const ui = f.ui();
    const r = f.full();
    draw(ui, r, f.theme.palette.blue);
    const g = list_panel.marker_glyph;
    // Row 0: unselected, the session's green accent in the row's first
    // cell (x 2), the marker column (x 1) blank.
    _ = ui.putStr(2, 0, 1, g, Theme.withFg(f.theme.bg, f.theme.palette.green));
    _ = ui.putStr(4, 0, 3, "abc", f.theme.bg);
    // Row 1: selected (cyan marker) with an orange accent.
    _ = ui.putStr(1, 1, 1, g, Theme.withFg(f.theme.cursor_line, f.theme.palette.cyan));
    _ = ui.putStr(2, 1, 1, g, Theme.withFg(f.theme.cursor_line, f.theme.palette.orange));
    // Row 2: selected, no accent of its own.
    _ = ui.putStr(1, 2, 1, g, Theme.withFg(f.theme.cursor_line, f.theme.palette.cyan));
    _ = ui.putStr(3, 2, 3, "xyz", f.theme.cursor_line);
    absorbList(ui, r);
    for ([_]struct { y: u16, color: vaxis.Color }{
        .{ .y = 0, .color = f.theme.palette.green },
        .{ .y = 1, .color = f.theme.palette.orange },
        .{ .y = 2, .color = f.theme.palette.cyan },
    }) |row| {
        try testing.expectEqualStrings(g, f.cell(0, row.y).char.grapheme);
        try testing.expect(vaxis.Color.eql(f.cell(0, row.y).style.fg, row.color));
        try testing.expect(!std.mem.eql(u8, g, f.cell(1, row.y).char.grapheme));
        try testing.expect(!std.mem.eql(u8, g, f.cell(2, row.y).char.grapheme));
    }
    // No text moved; row 3 is the rail alone.
    try testing.expectEqualStrings("a", f.cell(4, 0).char.grapheme);
    try testing.expectEqualStrings("x", f.cell(3, 2).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.cell(0, 3).style.fg, f.theme.palette.blue));
}

test "recolor: a pane's own stripe takes the cue's colour and loses its dim; the rest of the column is the pane's" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    const ui = f.ui();
    ui.fill(f.full(), f.theme.bg);
    // An integration's gutter: dim brand on three rows, bold on the
    // cursor's, and a letter on the last that is not a stripe.
    var dim = Theme.withFg(f.theme.bg, f.theme.palette.blue);
    dim.dim = true;
    var on = Theme.withFg(f.theme.bg, f.theme.palette.blue);
    on.bold = true;
    _ = ui.putStr(0, 0, 1, list_panel.marker_glyph, dim);
    _ = ui.putStr(0, 1, 1, list_panel.marker_glyph, on);
    _ = ui.putStr(0, 2, 1, list_panel.marker_glyph, dim);
    _ = ui.putStr(0, 3, 1, "x", dim);
    recolor(ui, f.full(), f.theme.palette.red);
    var y: u16 = 0;
    while (y < 3) : (y += 1) {
        try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(0, y).char.grapheme);
        try testing.expect(vaxis.Color.eql(f.cell(0, y).style.fg, f.theme.palette.red));
        try testing.expect(!f.cell(0, y).style.dim);
    }
    try testing.expect(f.cell(0, 1).style.bold);
    try testing.expectEqualStrings("x", f.cell(0, 3).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.cell(0, 3).style.fg, f.theme.palette.blue));
    try testing.expect(f.cell(0, 3).style.dim);
}
