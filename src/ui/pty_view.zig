//! PtyView — a terminal grid painted cell by cell onto the canvas. The
//! grid is ghostty's render state read out as plain cells (`pty.Grid`);
//! this file only maps colours and attributes onto `vaxis.Style` and
//! handles wide cells, so the pane's own bookkeeping never touches the
//! screen.
//!
//! A cell with the terminal's default colours takes the theme's, so a
//! shell sits on the same ground as an editor pane. An `exit_label`
//! paints a one-row banner over the bottom of the pane.
//!
//! ── the child's cursor ──
//! The child asks for a shape (DECSCUSR), a blink and a visibility
//! (DECTCEM); `pty.Grid` reads all three back. A terminal emulator then
//! draws the focused surface's cursor filled and every other one as a
//! hollow block — which is the shape the user recognises, and what
//! ghostty's own renderer does (`renderer/cursor.zig`: not focused →
//! `block_hollow`, hidden → nothing at all).
//!
//! mnml paints into cells, and a cell holds exactly one grapheme. On a
//! BLANK cell that grapheme can be the outline itself, so `hollow`
//! paints `U+F2001` — the full-cell rectangle MnmlSymbols bakes
//! (`glyph/builder.zig`), which is ghostty's shape rather than the
//! small centred `□` that used to stand in for it. On a cell that
//! already holds a character there is no second grapheme to put the
//! outline in, and dropping the character to draw a box would hide what
//! the shell wrote; so the character stays and takes the cursor colour,
//! which is the half of "hollow" that survives — a filled cursor
//! swallows its character (fg and bg swap), a hollow one leaves it
//! readable. `dim` is the other honest answer: a filled block at half
//! strength. `none` opts out.
//!
//! The outline is only there when the face is: `props.mnml_font` comes
//! from the installed MnmlSymbols' own cmap (`app/font_scan.zig`), and
//! a terminal without it gets `▯` (U+25AF, a tall rectangle — closer to
//! a cell than `□` is) and `|` under `--ascii`.
//!
//! The FOCUSED pane is different again: in a real terminal the host's
//! own cursor is put on that cell (`render.zig` hands the position and
//! shape to vaxis, which emits DECSCUSR), so Ghostty draws it — with its
//! blink, and with its own hollow-when-the-window-is-away behaviour for
//! free. `paint_focused` is then off and nothing is painted underneath.
//! Headless has no terminal cursor, so there it stays on and the cells
//! carry the filled cursor themselves.

const std = @import("std");
const vaxis = @import("vaxis");
const pty = @import("pty");
const Rect = @import("rect.zig");
const link_span = @import("link_span.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const blendOver = @import("diff_view.zig").blendOver;

const Style = vaxis.Style;
const Color = vaxis.Color;

/// Where the host should put its own cursor, and how it should look.
pub const Cursor = struct {
    x: u16,
    y: u16,
    shape: Shape,
    /// The child asked for a blinking cursor and the config lets it
    /// through. The host's terminal owns the clock.
    blink: bool = false,

    pub const Shape = enum { block, bar, underline };
};

/// The stand-in a pty pane that is not the focused one gets
/// (`ui.pty_cursor.unfocused`).
pub const Unfocused = enum { hollow, dim, none };

/// One row's links: the row's text as painted and the spans in it.
pub const RowLinks = struct { y: u16, text: []const u8, spans: []const link_span.Span };

pub const Props = struct {
    focused: bool,
    /// `[exited 0]` — painted on the last row when set.
    exit_label: ?[]const u8 = null,
    /// Paint the focused pane's cursor into the cells. Off when the
    /// host draws a real terminal cursor over them instead.
    paint_focused: bool = true,
    unfocused: Unfocused = .hollow,
    /// Pass the child's blink request out in the returned `Cursor`.
    blink: bool = true,
    /// The installed MnmlSymbols carries `cursor_hollow_cp`. Off by
    /// default: a caller that cannot say gets the Unicode fallback,
    /// which renders everywhere, rather than a guaranteed `?`.
    mnml_font: bool = false,
    /// Spans to call out over the cells — a scrollback search's matches
    /// (`app/pty_search.zig`), in viewport rows.
    marks: []const Mark = &.{},
    /// The links in the rows on screen (`app/pty_links.zig`): they wear
    /// the link look. The pane opens them itself, so they take no hit.
    links: []const RowLinks = &.{},
};

/// One row's run of cells, `x0` to `x1` inclusive, painted in the
/// theme's `match` role — `current_match` for the one being stepped.
pub const Mark = struct { y: u16, x0: u16, x1: u16, current: bool = false };

/// The full-cell outline MnmlSymbols bakes — the hollow cursor proper.
/// `cursor_hollow_cp` is the same codepoint for the caller that has to
/// ask the installed face whether it carries it.
pub const cursor_hollow_glyph = "\u{F2001}";
pub const cursor_hollow_ascii = "|";
pub const cursor_hollow_cp: u21 = 0xF2001;
/// Without the face: the tall rectangle, which at least fills the cell
/// vertically. `□` is a small centred square and reads as a character,
/// not as a cursor.
const hollow_fallback = "▯";
/// The bar cursor: a left-edge sliver, as a terminal draws it.
const bar_glyph = "▏";
const bar_ascii = "|";

/// One-byte graphemes without allocating: ASCII cells point here.
const ascii_table: [128][1]u8 = blk: {
    var tbl: [128][1]u8 = undefined;
    for (&tbl, 0..) |*b, i| b.* = .{@intCast(i)};
    break :blk tbl;
};

/// The vaxis colour a grid colour paints as: the terminal palette index
/// straight through (so the host resolves it as the child meant), an
/// explicit rgb verbatim, the default deferred to the caller. Every
/// surface that repaints a pane's cells — the pane itself, the SESSIONS
/// card's banner rows — goes through here, so one orange is one orange.
pub fn colorOf(c: pty.grid.Color, fallback: Color) Color {
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
    if (cell.grapheme.len > 0) {
        // The cluster: the first codepoint, then the rest the cell holds.
        var out = std.ArrayListUnmanaged(u8).empty;
        var first: [4]u8 = undefined;
        const n0 = std.unicode.utf8Encode(cell.cp, &first) catch return null;
        out.appendSlice(ui.arena, first[0..n0]) catch return null;
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

/// The colour a terminal draws the cursor in: what the child asked for
/// (OSC 12), else the theme's foreground — the default every terminal
/// falls back to.
fn cursorColor(grid: *const pty.Grid, th: *const Theme) Color {
    const c = grid.cursorColor() orelse return th.fg.fg;
    return .{ .rgb = .{ c.r, c.g, c.b } };
}

/// What a blank cell under a `.hollow` cursor shows: the baked outline
/// when the face is installed, the tall rectangle when it is not, and
/// the bar under `--ascii` (which is a terminal that was told to stay
/// inside ASCII, whatever fonts it has).
fn hollowGlyph(ui: Ui, props: Props) []const u8 {
    if (ui.ascii) return cursor_hollow_ascii;
    return if (props.mnml_font) cursor_hollow_glyph else hollow_fallback;
}

/// The cursor cell, painted. `focused` picks the filled look the child
/// asked for; otherwise `props.unfocused` picks the stand-in.
fn paintCursor(ui: Ui, area: Rect, grid: *const pty.Grid, cur: pty.grid.Cursor, props: Props) void {
    const th = ui.theme;
    const cell = grid.cell(cur.x, cur.y);
    const base = styleOf(cell, th);
    const ground = colorOf(cell.bg, th.bg.bg);
    const ink = cursorColor(grid, th);
    const glyph = graphemeOf(ui, cell) orelse " ";
    const width: u8 = if (cell.wide == .wide) 2 else 1;
    const x = area.x + cur.x;
    const y = area.y + cur.y;

    if (props.focused) {
        switch (cur.shape) {
            // Filled: fg and bg swap, so the glyph is read out of the
            // cursor's block.
            .block => ui.canvas.put(x, y, .{ .char = .{ .grapheme = glyph, .width = width }, .style = .{ .fg = ground, .bg = ink, .bold = base.bold, .italic = base.italic } }),
            // A bar sits on the cell's left edge. One cell holds one
            // grapheme, so the sliver takes it — the cell under a bar
            // cursor is the one past the text, and blank, nearly always.
            .bar => ui.canvas.put(x, y, .{ .char = .{ .grapheme = if (ui.ascii) bar_ascii else bar_glyph, .width = 1 }, .style = .{ .fg = ink, .bg = ground } }),
            // An underline keeps the glyph and rules under it.
            .underline => {
                var s = base;
                s.ul = ink;
                s.ul_style = .single;
                ui.canvas.put(x, y, .{ .char = .{ .grapheme = glyph, .width = width }, .style = s });
            },
        }
        return;
    }
    switch (props.unfocused) {
        .none => {},
        // A blank cell has a grapheme to spare, so it gets the outline
        // itself. A cell with a character does not — one cell, one
        // grapheme — so the character stays readable and takes the
        // cursor colour, which is the half of "hollow" a cell can hold.
        .hollow => {
            const blank = cell.isEmpty();
            var s = base;
            s.fg = ink;
            s.bold = true;
            ui.canvas.put(x, y, .{
                .char = .{ .grapheme = if (blank) hollowGlyph(ui, props) else glyph, .width = if (blank) 1 else width },
                .style = s,
            });
        },
        // A filled block at half strength: the cursor colour half-way to
        // the ground it sits on.
        .dim => {
            const muted = blendOver(ink, ground, 128, ink);
            ui.canvas.put(x, y, .{ .char = .{ .grapheme = glyph, .width = width }, .style = .{ .fg = ground, .bg = muted } });
        },
    }
}

/// Repaint a mark's cells in the match role, keeping what they hold.
fn paintMark(ui: Ui, area: Rect, grid: *const pty.Grid, m: Mark, rows: u16, cols: u16) void {
    if (m.y >= rows or m.x0 >= cols) return;
    const style = if (m.current) ui.theme.current_match else ui.theme.match;
    var x = m.x0;
    while (x <= @min(m.x1, cols - 1)) : (x += 1) {
        const cell = grid.cell(x, m.y);
        switch (cell.wide) {
            .spacer_tail, .spacer_head => continue,
            .narrow, .wide => {},
        }
        const g = graphemeOf(ui, cell) orelse " ";
        const width: u8 = if (cell.wide == .wide) 2 else 1;
        ui.canvas.put(area.x + x, area.y + m.y, .{ .char = .{ .grapheme = g, .width = width }, .style = style });
    }
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
            var style = styleOf(cell, th);
            if (grid.rowSelection(y)) |sel| if (x >= sel[0] and x <= sel[1]) {
                // A selection reads the way the editor's does: the
                // theme's selection ground under the cell's own ink.
                style.bg = th.selection.bg;
                style.reverse = false;
            };
            const g = graphemeOf(ui, cell) orelse {
                ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
                continue;
            };
            const width: u8 = if (cell.wide == .wide) 2 else 1;
            ui.canvas.put(area.x + x, area.y + y, .{ .char = .{ .grapheme = g, .width = width }, .style = style });
        }
    }
    for (props.marks) |m| paintMark(ui, area, grid, m, rows, cols);
    for (props.links) |l| if (l.y < rows) link_span.lookSpans(ui, area.x, area.y + l.y, cols, l.text, l.spans);
    // The link a right-click's menu is for, while that menu is open.
    link_span.paintMenuLink(ui, area);
    if (props.exit_label) |label| {
        const r = area.row(area.h - 1);
        ui.fill(r, th.statusline);
        _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(label, r.w -| 1), Theme.onBg(th.accent, th.statusline.bg));
        return null;
    }
    // `grid.cursor()` is null while the child has it hidden (DECTCEM)
    // or scrolled out of the viewport: then there is nothing to draw,
    // focused or not — the same order ghostty's own renderer uses.
    const cur = grid.cursor() orelse return null;
    if (cur.x >= cols or cur.y >= rows) return null;
    if (!props.focused or props.paint_focused) paintCursor(ui, area, grid, cur, props);
    if (!props.focused) return null;
    return .{
        .x = area.x + cur.x,
        .y = area.y + cur.y,
        .blink = props.blink and cur.blinking,
        .shape = switch (cur.shape) {
            .block => .block,
            .bar => .bar,
            .underline => .underline,
        },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

/// A grid fed `bytes`, with the terminal kept alive beside it.
const GridFixture = struct {
    term: pty.vt.Terminal,
    grid: pty.Grid = .{},

    fn init(cols: u16, rows: u16, bytes: []const u8) !GridFixture {
        var g: GridFixture = .{ .term = try .init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows }) };
        var s = g.term.vtStream();
        defer s.deinit();
        s.nextSlice(bytes);
        try g.grid.update(testing.allocator, &g.term);
        return g;
    }

    fn deinit(g: *GridFixture) void {
        g.grid.deinit(testing.allocator);
        g.term.deinit(testing.allocator);
    }
};

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

test "a multi-codepoint cluster paints whole: the thumb and its skin tone in one two-cell grapheme, the next cell after it" {
    var term: pty.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 12, .rows = 2, .default_modes = .{ .grapheme_cluster = true } });
    defer term.deinit(testing.allocator);
    var s = term.vtStream();
    defer s.deinit();
    s.nextSlice("\u{1F44D}\u{1F3FD}x");
    var grid: pty.Grid = .{};
    defer grid.deinit(testing.allocator);
    try grid.update(testing.allocator, &term);
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    _ = draw(f.ui(), Rect.init(0, 0, 12, 2), &grid, .{ .focused = false, .unfocused = .none });
    const thumb = f.screen.readCell(0, 0).?;
    try testing.expectEqualStrings("\u{1F44D}\u{1F3FD}", thumb.char.grapheme);
    try testing.expectEqual(@as(u8, 2), thumb.char.width);
    try testing.expectEqualStrings("x", f.screen.readCell(2, 0).?.char.grapheme);
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

test "focused: the block cursor swallows its glyph — the cell's ink and ground swap" {
    var g = try GridFixture.init(10, 2, "ab");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const th = f.theme;
    const cur = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = true });
    // After "ab", on the blank third cell.
    try testing.expectEqual(@as(u16, 2), cur.?.x);
    try testing.expectEqual(Cursor.Shape.block, cur.?.shape);
    try testing.expect(!cur.?.blink);
    const c = f.cell(2, 0);
    // The cursor colour (the theme's fg, unasked) is the ground; the
    // cell's own ground is the ink.
    try testing.expect(Color.eql(th.fg.fg, c.style.bg));
    try testing.expect(Color.eql(th.bg.bg, c.style.fg));
    // The cell beside it is untouched.
    try testing.expect(Color.eql(th.bg.bg, f.cell(1, 0).style.bg));
}

test "focused: a bar takes the left-edge sliver, an underline rules under the glyph" {
    var bar = try GridFixture.init(10, 2, "\x1b[6 qx\x1b[D");
    defer bar.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const cur = draw(f.ui(), Rect.init(0, 0, 10, 2), &bar.grid, .{ .focused = true });
    try testing.expectEqual(Cursor.Shape.bar, cur.?.shape);
    try testing.expectEqualStrings("▏", f.cell(0, 0).char.grapheme);
    try testing.expect(Color.eql(f.theme.fg.fg, f.cell(0, 0).style.fg));

    var ul = try GridFixture.init(10, 2, "\x1b[4 qx\x1b[D");
    defer ul.deinit();
    var f2 = try Fixture.init(10, 2);
    defer f2.deinit();
    const cur2 = draw(f2.ui(), Rect.init(0, 0, 10, 2), &ul.grid, .{ .focused = true });
    try testing.expectEqual(Cursor.Shape.underline, cur2.?.shape);
    // The glyph stays; the rule is the cursor colour.
    try testing.expectEqualStrings("x", f2.cell(0, 0).char.grapheme);
    try testing.expectEqual(vaxis.Style.Underline.single, f2.cell(0, 0).style.ul_style);
    try testing.expect(Color.eql(f2.theme.fg.fg, f2.cell(0, 0).style.ul));
}

test "focused: the blink the child asked for reaches the host, and only when the config allows" {
    var g = try GridFixture.init(10, 2, "\x1b[5 q"); // blinking bar
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    try testing.expect(draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = true }).?.blink);
    try testing.expect(!draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = true, .blink = false }).?.blink);
}

test "focused: with a real terminal cursor on top, the cells are left alone" {
    var g = try GridFixture.init(10, 2, "ab");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const cur = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = true, .paint_focused = false });
    // The host is still told where to put its own cursor…
    try testing.expectEqual(@as(u16, 2), cur.?.x);
    // …but the cell under it is the pane's ordinary ground.
    try testing.expect(Color.eql(f.theme.bg.bg, f.cell(2, 0).style.bg));
}

test "unfocused: hollow keeps the glyph readable in the cursor colour; a blank cell shows the outline" {
    var g = try GridFixture.init(10, 2, "ab\x1b[D"); // back onto the 'b'
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const th = f.theme;
    try testing.expect(draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false }) == null);
    const c = f.cell(1, 0);
    try testing.expectEqualStrings("b", c.char.grapheme);
    try testing.expect(Color.eql(th.fg.fg, c.style.fg));
    // Hollow, not filled: the ground is the pane's, not the cursor's.
    try testing.expect(Color.eql(th.bg.bg, c.style.bg));

    // A blank cell has a grapheme to spare, so the outline takes it.
    var blank = try GridFixture.init(10, 2, "ab");
    defer blank.deinit();
    var f2 = try Fixture.init(10, 2);
    defer f2.deinit();
    _ = draw(f2.ui(), Rect.init(0, 0, 10, 2), &blank.grid, .{ .focused = false, .mnml_font = true });
    try testing.expectEqualStrings("\u{F2001}", f2.cell(2, 0).char.grapheme);
}

test "unfocused hollow: which mark a blank cell gets, over font × ascii" {
    var g = try GridFixture.init(10, 2, "ab");
    defer g.deinit();
    const Case = struct { font: bool, ascii: bool, want: []const u8 };
    // The outline only when the installed face carries it; `▯` rather
    // than a certain `?` when it does not; `|` when the terminal was
    // told to stay inside ASCII, whatever it has installed.
    for ([_]Case{
        .{ .font = true, .ascii = false, .want = cursor_hollow_glyph },
        .{ .font = false, .ascii = false, .want = hollow_fallback },
        .{ .font = true, .ascii = true, .want = cursor_hollow_ascii },
        .{ .font = false, .ascii = true, .want = cursor_hollow_ascii },
    }) |c| {
        var f = try Fixture.init(10, 2);
        defer f.deinit();
        f.ascii = c.ascii;
        _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false, .mnml_font = c.font });
        errdefer std.debug.print("font={} ascii={}\n", .{ c.font, c.ascii });
        try testing.expectEqualStrings(c.want, f.cell(2, 0).char.grapheme);
    }
}

test "unfocused hollow: a cell with a character never gets the outline — one cell, one grapheme" {
    // Even with the face installed: the outline would have to replace
    // the shell's character, and hiding it is worse than tinting it.
    var g = try GridFixture.init(10, 2, "ab\x1b[D");
    defer g.deinit();
    for ([_]bool{ true, false }) |font| {
        var f = try Fixture.init(10, 2);
        defer f.deinit();
        _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false, .mnml_font = font });
        try testing.expectEqualStrings("b", f.cell(1, 0).char.grapheme);
        try testing.expect(Color.eql(f.theme.fg.fg, f.cell(1, 0).style.fg));
    }
}

test "unfocused: dim and none ignore the face entirely" {
    var g = try GridFixture.init(10, 2, "ab");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false, .unfocused = .dim, .mnml_font = true });
    try testing.expectEqualStrings(" ", f.cell(2, 0).char.grapheme);
    var f2 = try Fixture.init(10, 2);
    defer f2.deinit();
    _ = draw(f2.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false, .unfocused = .none, .mnml_font = true });
    try testing.expect(Color.eql(f2.theme.bg.bg, f2.cell(2, 0).style.bg));
}

test "unfocused: dim is a filled block half-way to the ground; none paints nothing" {
    var g = try GridFixture.init(10, 2, "ab");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const th = f.theme;
    _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false, .unfocused = .dim });
    const c = f.cell(2, 0);
    try testing.expect(Color.eql(th.bg.bg, c.style.fg));
    // Between the cursor colour and the ground, and neither of them.
    try testing.expect(!Color.eql(th.fg.fg, c.style.bg));
    try testing.expect(!Color.eql(th.bg.bg, c.style.bg));

    var f2 = try Fixture.init(10, 2);
    defer f2.deinit();
    _ = draw(f2.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false, .unfocused = .none });
    try testing.expect(Color.eql(th.bg.bg, f2.cell(2, 0).style.bg));
    try testing.expectEqualStrings(" ", f2.cell(2, 0).char.grapheme);
}

test "a hidden cursor is nothing at all, focused or not" {
    var g = try GridFixture.init(10, 2, "ab\x1b[?25l");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const th = f.theme;
    try testing.expect(draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = true }) == null);
    try testing.expect(Color.eql(th.bg.bg, f.cell(2, 0).style.bg));
    _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false });
    try testing.expect(Color.eql(th.bg.bg, f.cell(2, 0).style.bg));
    try testing.expectEqualStrings(" ", f.cell(2, 0).char.grapheme);
}

test "OSC 12 wins over the theme for the cursor's colour" {
    var g = try GridFixture.init(10, 2, "\x1b]12;rgb:10/20/30\x07ab");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = true });
    try testing.expect(Color.eql(.{ .rgb = .{ 0x10, 0x20, 0x30 } }, f.cell(2, 0).style.bg));
}

test "--ascii swaps the outline and the sliver for characters a plain font has" {
    var g = try GridFixture.init(10, 2, "ab");
    defer g.deinit();
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    f.ascii = true;
    _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &g.grid, .{ .focused = false });
    try testing.expectEqualStrings("|", f.cell(2, 0).char.grapheme);

    var bar = try GridFixture.init(10, 2, "\x1b[6 q");
    defer bar.deinit();
    _ = draw(f.ui(), Rect.init(0, 0, 10, 2), &bar.grid, .{ .focused = true });
    try testing.expectEqualStrings("|", f.cell(0, 0).char.grapheme);
}

test "marks paint their cells in the match roles and keep what the cells hold; a wide char is painted whole; out-of-range marks are ignored" {
    var g = try GridFixture.init(12, 3, "ab find cd\r\n\xe4\xbd\xa0x");
    defer g.deinit();
    var f = try Fixture.init(12, 3);
    defer f.deinit();
    const marks = [_]Mark{
        .{ .y = 0, .x0 = 3, .x1 = 6 },
        .{ .y = 1, .x0 = 0, .x1 = 1, .current = true },
        .{ .y = 9, .x0 = 0, .x1 = 3 },
        .{ .y = 0, .x0 = 40, .x1 = 50 },
    };
    _ = draw(f.ui(), Rect.init(0, 0, 12, 3), &g.grid, .{ .focused = false, .unfocused = .none, .marks = &marks });
    try f.expectRow(0, "ab find cd");
    try testing.expect(f.bgEql(3, 0, f.theme.match));
    try testing.expect(f.fgEql(6, 0, f.theme.match));
    try testing.expect(!f.bgEql(2, 0, f.theme.match));
    try testing.expect(!f.bgEql(7, 0, f.theme.match));
    const wide = f.screen.readCell(0, 1).?;
    try testing.expectEqualStrings("\u{4f60}", wide.char.grapheme);
    try testing.expect(f.bgEql(0, 1, f.theme.current_match));
    try testing.expect(f.bgEql(1, 1, f.theme.current_match));
    try testing.expect(!f.bgEql(2, 1, f.theme.current_match));
}
