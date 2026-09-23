//! Read the visible grid out of a ghostty-vt `Terminal` as plain cells.
//!
//! ghostty's `RenderState` already does the heavy lifting — it walks the
//! viewport pages, copies each row's cells into a flat MultiArrayList and
//! denormalizes styles per cell, tracking dirtiness so an unchanged row is
//! not rebuilt. `Grid` wraps one `RenderState`, refreshes it from the
//! terminal, and hands out `Cell`s that carry no ghostty types.
//!
//! SPIKE-LOCAL TYPES. `Color`, `Cell`, `Cursor` exist so the demo can paint
//! without a UI library. Once vaxis is in the build they are replaced by
//! `vaxis.Cell` / `vaxis.Color` (or a direct `Canvas.put` from the render
//! state) and this file shrinks to the update + iteration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vt = @import("ghostty-vt");

pub const Color = union(enum) {
    /// The terminal's default fg / bg (see `Grid.foreground/background`).
    default,
    palette: u8,
    rgb: Rgb,

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    fn fromStyle(c: vt.Style.Color) Color {
        return switch (c) {
            .none => .default,
            .palette => |i| .{ .palette = i },
            .rgb => |v| .{ .rgb = .{ .r = v.r, .g = v.g, .b = v.b } },
        };
    }
};

pub const Wide = enum { narrow, wide, spacer_tail, spacer_head };

pub const Underline = enum { none, single, double, curly, dotted, dashed };

pub const Cell = struct {
    /// First (or only) codepoint; 0 for an empty cell.
    cp: u21 = 0,
    /// The codepoints AFTER `cp` when the cell holds a multi-codepoint
    /// grapheme (a skin tone, a ZWJ and the next person, VS16) — the
    /// cluster is `cp` then these. Borrowed from the render state, valid
    /// until the next `update`.
    grapheme: []const u21 = &.{},
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
    wide: Wide = .narrow,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    underline: Underline = .none,

    pub fn isEmpty(self: Cell) bool {
        return self.cp == 0 and self.grapheme.len == 0;
    }
};

pub const Cursor = struct {
    x: u16,
    y: u16,
    shape: Shape,
    /// The cursor sits on the tail half of a wide char; renderers usually
    /// draw it one cell to the left.
    wide_tail: bool,
    /// The child asked for a blinking cursor (DEC mode 12, or the odd
    /// DECSCUSR codes). Whose clock does the blinking is the host's
    /// business: a renderer that cannot blink paints the steady shape.
    blinking: bool = false,

    /// The three shapes DECSCUSR can ask for. ghostty's own renderer
    /// adds a hollow block for an unfocused surface — that is a
    /// painting decision, never something the child requests, so it is
    /// not one of these.
    pub const Shape = enum { block, bar, underline };
};

pub const Grid = struct {
    state: vt.RenderState = .empty,

    pub fn deinit(self: *Grid, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }

    /// Refresh from the terminal. Cheap when nothing changed (ghostty tracks
    /// dirtiness per row and skips clean ones). After this, `dirty()` says
    /// whether anything is worth repainting; call `markClean` once painted.
    pub fn update(self: *Grid, alloc: Allocator, term: *vt.Terminal) Allocator.Error!void {
        try self.state.update(alloc, term);
    }

    pub fn dirty(self: *const Grid) bool {
        return self.state.dirty != .false;
    }

    pub fn markClean(self: *Grid) void {
        self.state.clean();
    }

    pub fn cols(self: *const Grid) u16 {
        return self.state.cols;
    }

    pub fn rows(self: *const Grid) u16 {
        return self.state.rows;
    }

    /// The row changed since the last `markClean`.
    pub fn rowDirty(self: *const Grid, y: u16) bool {
        return self.state.row_data.items(.dirty)[y];
    }

    /// The columns of row `y` the screen's selection covers, both ends
    /// inclusive; null when the row has none.
    pub fn rowSelection(self: *const Grid, y: u16) ?[2]u16 {
        const sel = self.state.row_data.items(.selection)[y] orelse return null;
        return .{ sel[0], sel[1] };
    }

    pub fn cell(self: *const Grid, x: u16, y: u16) Cell {
        const row_cells = self.state.row_data.items(.cells)[y];
        const rc: vt.RenderState.Cell = row_cells.get(x);
        const raw = rc.raw;

        var out: Cell = .{
            .wide = switch (raw.wide) {
                .narrow => .narrow,
                .wide => .wide,
                .spacer_tail => .spacer_tail,
                .spacer_head => .spacer_head,
            },
        };

        switch (raw.content_tag) {
            .codepoint => out.cp = raw.content.codepoint.data,
            .codepoint_grapheme => {
                out.cp = raw.content.codepoint.data;
                out.grapheme = rc.grapheme;
            },
            // An empty cell that carries only a background colour (erased
            // with a bg set). The style, if any, may also apply.
            .bg_color_palette => out.bg = .{ .palette = raw.content.color_palette.data },
            .bg_color_rgb => {
                const v = raw.content.color_rgb;
                out.bg = .{ .rgb = .{ .r = v.r, .g = v.g, .b = v.b } };
            },
        }

        // style_id 0 is always the default style; `rc.style` is undefined then.
        if (raw.style_id != 0) {
            const st = rc.style;
            out.fg = Color.fromStyle(st.fg_color);
            if (st.bg_color != .none) out.bg = Color.fromStyle(st.bg_color);
            out.underline_color = Color.fromStyle(st.underline_color);
            out.bold = st.flags.bold;
            out.italic = st.flags.italic;
            out.faint = st.flags.faint;
            out.blink = st.flags.blink;
            out.inverse = st.flags.inverse;
            out.invisible = st.flags.invisible;
            out.strikethrough = st.flags.strikethrough;
            out.underline = switch (st.flags.underline) {
                .none => .none,
                .single => .single,
                .double => .double,
                .curly => .curly,
                .dotted => .dotted,
                .dashed => .dashed,
            };
        }
        return out;
    }

    /// The cursor if it is visible and inside the viewport.
    pub fn cursor(self: *const Grid) ?Cursor {
        const cur = self.state.cursor;
        if (!cur.visible) return null;
        const vp = cur.viewport orelse return null;
        return .{
            .x = vp.x,
            .y = vp.y,
            .wide_tail = vp.wide_tail,
            .blinking = cur.blinking,
            .shape = switch (cur.visual_style) {
                .bar => .bar,
                .underline => .underline,
                else => .block,
            },
        };
    }

    /// The colour the child asked its cursor to be (OSC 12), or null
    /// when it never said — the host then picks, as a terminal does.
    pub fn cursorColor(self: *const Grid) ?Color.Rgb {
        const c = self.state.colors.cursor orelse return null;
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }

    pub fn foreground(self: *const Grid) Color.Rgb {
        const c = self.state.colors.foreground;
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }

    pub fn background(self: *const Grid) Color.Rgb {
        const c = self.state.colors.background;
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }

    /// Resolve a palette index through the terminal's current palette
    /// (OSC 4 changes included).
    pub fn palette(self: *const Grid, index: u8) Color.Rgb {
        const c = self.state.colors.palette[index];
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }
};

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    term: vt.Terminal,
    grid: Grid = .{},

    fn init(cols: u16, rows: u16, bytes: []const u8) !Fixture {
        var f: Fixture = .{ .term = try .init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows }) };
        var s = f.term.vtStream();
        defer s.deinit();
        s.nextSlice(bytes);
        try f.grid.update(testing.allocator, &f.term);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.grid.deinit(testing.allocator);
        f.term.deinit(testing.allocator);
    }
};

test "SGR 31 paints the foreground red for exactly the styled cells" {
    var f = try Fixture.init(10, 2, "\x1b[31mhi\x1b[0m!");
    defer f.deinit();
    const h = f.grid.cell(0, 0);
    const i = f.grid.cell(1, 0);
    const bang = f.grid.cell(2, 0);
    try testing.expectEqual(@as(u21, 'h'), h.cp);
    try testing.expectEqual(@as(u21, 'i'), i.cp);
    try testing.expectEqual(Color{ .palette = 1 }, h.fg);
    try testing.expectEqual(Color{ .palette = 1 }, i.fg);
    try testing.expectEqual(Color.default, h.bg);
    try testing.expectEqual(@as(u21, '!'), bang.cp);
    try testing.expectEqual(Color.default, bang.fg);
    try testing.expect(f.grid.cell(3, 0).isEmpty());
}

test "a wide char occupies two cells: the glyph then a spacer tail" {
    var f = try Fixture.init(10, 1, "a\xe4\xbd\xa0b"); // a 你 b
    defer f.deinit();
    try testing.expectEqual(@as(u21, 'a'), f.grid.cell(0, 0).cp);
    const wide = f.grid.cell(1, 0);
    try testing.expectEqual(@as(u21, 0x4F60), wide.cp);
    try testing.expectEqual(Wide.wide, wide.wide);
    const tail = f.grid.cell(2, 0);
    try testing.expectEqual(Wide.spacer_tail, tail.wide);
    try testing.expectEqual(@as(u21, 0), tail.cp);
    try testing.expectEqual(@as(u21, 'b'), f.grid.cell(3, 0).cp);
}

test "bold, truecolor background and underline styles come through" {
    var f = try Fixture.init(10, 1, "\x1b[1;4;48;2;10;20;30mX\x1b[0m");
    defer f.deinit();
    const x = f.grid.cell(0, 0);
    try testing.expect(x.bold);
    try testing.expectEqual(Underline.single, x.underline);
    try testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, x.bg);
    try testing.expectEqual(Color.default, x.fg);
}

test "cursor position and dirty tracking follow the terminal" {
    var f = try Fixture.init(10, 3, "ab\r\ncd");
    defer f.deinit();
    const cur = f.grid.cursor() orelse return error.CursorHidden;
    try testing.expectEqual(@as(u16, 2), cur.x);
    try testing.expectEqual(@as(u16, 1), cur.y);
    try testing.expect(f.grid.dirty());
    f.grid.markClean();
    try testing.expect(!f.grid.dirty());

    var s = f.term.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[?25l"); // hide the cursor
    try f.grid.update(testing.allocator, &f.term);
    try testing.expect(f.grid.cursor() == null);
}

test "DECSCUSR maps each code to its shape, and the odd codes ask to blink" {
    const Case = struct { seq: []const u8, shape: Cursor.Shape, blink: bool };
    // `\x1b[N q`: 0/1 blinking block, 2 steady block, 3 blinking
    // underline, 4 steady underline, 5 blinking bar, 6 steady bar.
    const cases = [_]Case{
        .{ .seq = "\x1b[1 q", .shape = .block, .blink = true },
        .{ .seq = "\x1b[2 q", .shape = .block, .blink = false },
        .{ .seq = "\x1b[3 q", .shape = .underline, .blink = true },
        .{ .seq = "\x1b[4 q", .shape = .underline, .blink = false },
        .{ .seq = "\x1b[5 q", .shape = .bar, .blink = true },
        .{ .seq = "\x1b[6 q", .shape = .bar, .blink = false },
    };
    for (cases) |c| {
        var f = try Fixture.init(8, 2, c.seq);
        defer f.deinit();
        const cur = f.grid.cursor() orelse return error.CursorHidden;
        try testing.expectEqual(c.shape, cur.shape);
        try testing.expectEqual(c.blink, cur.blinking);
    }
}

test "OSC 12 is the cursor colour; unasked it is null" {
    var f = try Fixture.init(8, 2, "");
    defer f.deinit();
    try testing.expectEqual(@as(?Color.Rgb, null), f.grid.cursorColor());

    var s = f.term.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]12;rgb:ab/cd/ef\x07");
    try f.grid.update(testing.allocator, &f.term);
    try testing.expectEqual(Color.Rgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, f.grid.cursorColor());
}

test "palette resolves through the terminal's colour table, OSC 4 included" {
    var f = try Fixture.init(4, 1, "");
    defer f.deinit();
    const before = f.grid.palette(1);
    // ghostty's own default theme, not xterm's: index 1 is not pure red.
    try testing.expect(before.r > before.g);

    var s = f.term.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]4;1;rgb:12/34/56\x07");
    try f.grid.update(testing.allocator, &f.term);
    try testing.expectEqual(Color.Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, f.grid.palette(1));
    try testing.expect(f.grid.foreground().r != f.grid.background().r or
        f.grid.foreground().g != f.grid.background().g);
}
