//! Frame — the cell grid a sibling paints into and sends. It remembers
//! which rows changed since the last send, so `Mount.send` can ship a
//! `frame_dirty` instead of the whole screen. A cell keeps its grapheme
//! inline (up to `max_symbol` bytes), so painting never allocates and
//! the frame is one flat slice.
//!
//! Width: a code point in the common wide ranges (CJK, Hangul, the
//! emoji blocks) takes two cells — the second is an empty tail the host
//! paints nothing into. Combining marks and ZWJ sequences are not
//! composed; each code point is a cell. Good enough for a list panel;
//! a sibling that needs full grapheme width brings its own tables.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");

pub const Cell = wire.Cell;
pub const Color = wire.Color;
pub const Mods = wire.Mods;
pub const Row = wire.Row;

pub const max_symbol = 16;

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    mods: Mods = .{},

    pub const none: Style = .{};
    pub const bold: Style = .{ .mods = .{ .bold = true } };
    pub const reverse: Style = .{ .mods = .{ .reverse = true } };
    pub const dim: Style = .{ .mods = .{ .dim = true } };
};

/// One cell of the grid; `sym[0..len]` is the grapheme.
pub const Slot = struct {
    sym: [max_symbol]u8 = [_]u8{' '} ++ @as([max_symbol - 1]u8, @splat(0)),
    len: u8 = 1,
    style: Style = .{},

    pub fn set(s: *Slot, sym_bytes: []const u8, style: Style) void {
        const n: u8 = @intCast(@min(sym_bytes.len, max_symbol));
        @memcpy(s.sym[0..n], sym_bytes[0..n]);
        s.len = n;
        s.style = style;
    }

    pub fn symbol(s: *const Slot) []const u8 {
        return s.sym[0..s.len];
    }

    pub fn cell(s: *const Slot) Cell {
        return .{ .symbol = s.symbol(), .fg = s.style.fg, .bg = s.style.bg, .mods = s.style.mods };
    }
};

/// What `take` hands `Mount.send`: the rows to put on the wire.
pub const Outgoing = union(enum) {
    full: []const []const Cell,
    dirty: []const Row,
    /// Nothing changed since the last send.
    nothing,
};

pub const Frame = struct {
    gpa: Allocator,
    cols: u16,
    rows: u16,
    slots: []Slot,
    dirty: []bool,
    /// The next send is a whole screen (first send, after a resize).
    full_pending: bool = true,

    pub fn init(gpa: Allocator, cols: u16, rows: u16) Allocator.Error!Frame {
        const n = @as(usize, cols) * rows;
        const slots = try gpa.alloc(Slot, n);
        errdefer gpa.free(slots);
        @memset(slots, .{});
        const dirty = try gpa.alloc(bool, rows);
        @memset(dirty, true);
        return .{ .gpa = gpa, .cols = cols, .rows = rows, .slots = slots, .dirty = dirty };
    }

    pub fn deinit(f: *Frame) void {
        f.gpa.free(f.slots);
        f.gpa.free(f.dirty);
        f.* = undefined;
    }

    /// A new geometry: the grid is blanked and the next send is full.
    pub fn resize(f: *Frame, cols: u16, rows: u16) Allocator.Error!void {
        if (cols == f.cols and rows == f.rows) return;
        var fresh = try Frame.init(f.gpa, cols, rows);
        fresh.full_pending = true;
        f.deinit();
        f.* = fresh;
    }

    pub fn geometry(f: *const Frame) wire.Geometry {
        return .{ .cols = f.cols, .rows = f.rows };
    }

    fn at(f: *Frame, x: u16, y: u16) *Slot {
        return &f.slots[@as(usize, y) * f.cols + x];
    }

    /// Every cell blank in `style`; every row dirty.
    pub fn clear(f: *Frame, style: Style) void {
        for (f.slots) |*s| s.set(" ", style);
        @memset(f.dirty, true);
    }

    /// One grapheme at `(x, y)`; outside the grid is ignored.
    pub fn put(f: *Frame, x: u16, y: u16, symbol: []const u8, style: Style) void {
        if (x >= f.cols or y >= f.rows) return;
        const st = f.overStyle(x, y, style);
        f.at(x, y).set(symbol, st);
        f.dirty[y] = true;
    }

    /// `style` as it lands on the cell already there: a null `bg` means
    /// "leave the ground alone", so words painted over a filled row keep
    /// the fill instead of punching a hole back to the pane's default.
    ///
    /// `fill` and `clear` are what SET a ground and stay absolute — a
    /// null `bg` there really is the pane's default. Every row-text
    /// style the panes use (`th.text()`, `th.bright()`, `th.dimText()`)
    /// carries no `bg` and relies on this, which is what makes a cursor
    /// row's highlight survive the words painted on it.
    fn overStyle(f: *Frame, x: u16, y: u16, style: Style) Style {
        if (style.bg != null) return style;
        var out = style;
        out.bg = f.at(x, y).style.bg;
        return out;
    }

    /// Blank `w × h` from `(x, y)` in `style`, clipped to the grid.
    pub fn fill(f: *Frame, x: u16, y: u16, w: u16, h: u16, style: Style) void {
        var yy = y;
        while (yy < @min(f.rows, y +| h)) : (yy += 1) {
            var xx = x;
            while (xx < @min(f.cols, x +| w)) : (xx += 1) f.at(xx, yy).set(" ", style);
            f.dirty[yy] = true;
        }
    }

    /// `s` from `(x, y)` rightwards, one code point per cell (two for a
    /// wide one), clipped at the right edge and at `max_w` cells.
    /// Returns the cells used.
    pub fn text(f: *Frame, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
        if (y >= f.rows or x >= f.cols) return 0;
        const limit = @min(max_w, f.cols - x);
        var used: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepointSlice()) |bytes| {
            const cp = std.unicode.utf8Decode(bytes) catch continue;
            if (cp == '\n' or cp == '\r' or cp == '\t') continue;
            const w: u16 = if (isWide(cp)) 2 else 1;
            if (used + w > limit) break;
            f.at(x + used, y).set(bytes, f.overStyle(x + used, y, style));
            if (w == 2) f.at(x + used + 1, y).set("", f.overStyle(x + used + 1, y, style));
            used += w;
        }
        if (used > 0) f.dirty[y] = true;
        return used;
    }

    /// The rows to send, on `arena`; the dirty marks are cleared. A
    /// full screen when one is pending (first send, after a resize),
    /// else the dirty rows, else nothing.
    pub fn take(f: *Frame, arena: Allocator) Allocator.Error!Outgoing {
        if (f.full_pending) {
            f.full_pending = false;
            @memset(f.dirty, false);
            const rows = try arena.alloc([]const Cell, f.rows);
            for (rows, 0..) |*row, y| row.* = try f.rowCells(arena, @intCast(y));
            return .{ .full = rows };
        }
        var n: usize = 0;
        for (f.dirty) |d| n += @intFromBool(d);
        if (n == 0) return .nothing;
        const rows = try arena.alloc(Row, n);
        var i: usize = 0;
        for (f.dirty, 0..) |d, y| {
            if (!d) continue;
            rows[i] = .{ .y = @intCast(y), .cells = try f.rowCells(arena, @intCast(y)) };
            i += 1;
        }
        @memset(f.dirty, false);
        return .{ .dirty = rows };
    }

    fn rowCells(f: *Frame, arena: Allocator, y: u16) Allocator.Error![]const Cell {
        const out = try arena.alloc(Cell, f.cols);
        for (out, 0..) |*c, x| c.* = f.at(@intCast(x), y).cell();
        return out;
    }
};

/// Every row's BACKGROUNDS, run-length coded, one line per row:
///
/// ```text
/// bg  6: 0-119 #2c323c
/// bg  7: 0-0 #61afef | 1-119 -
/// ```
///
/// `-` is the pane's own ground (no background of the cell's own),
/// `#rrggbb` a true colour, `i8` an ANSI index. A screen dump is text
/// and carries no colour, so this is what makes "the cursor row is a
/// filled band" checkable from outside the process — `--dump-style`
/// prints it after each `snap`.
pub fn bgDump(arena: Allocator, f: *const Frame) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [64]u8 = undefined;
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        try out.appendSlice(arena, std.fmt.bufPrint(&buf, "bg {d:>3}:", .{y}) catch "bg ?:");
        var x: u16 = 0;
        var first = true;
        while (x < f.cols) {
            const here = f.slots[@as(usize, y) * f.cols + x].style.bg;
            var run = x + 1;
            while (run < f.cols and std.meta.eql(f.slots[@as(usize, y) * f.cols + run].style.bg, here)) run += 1;
            if (!first) try out.appendSlice(arena, " |");
            try out.appendSlice(arena, std.fmt.bufPrint(&buf, " {d}-{d} ", .{ x, run - 1 }) catch " ");
            const word: []const u8 = if (here) |c| switch (c) {
                .rgb => |v| std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ v[0], v[1], v[2] }) catch "#??????",
                .index => |i| std.fmt.bufPrint(&buf, "i{d}", .{i}) catch "i?",
            } else "-";
            try out.appendSlice(arena, word);
            first = false;
            x = run;
        }
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

/// Every row's FOREGROUNDS, the same way — one line per row, the
/// modifiers of a run appended to its colour:
///
/// ```text
/// fg  7: 0-0 #61afef+b | 1-8 #5c6370 | 9-119 -
/// ```
///
/// `+b` bold, `+d` dim, `+u` underline. A chip whose whole point is
/// its colour is invisible to a screen dump and invisible to a
/// background dump too — its ground is the row's. This is where
/// `[ Merge ]` being green and `[ Open ]` being grey is checkable
/// from outside the process.
pub fn fgDump(arena: Allocator, f: *const Frame) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [64]u8 = undefined;
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        try out.appendSlice(arena, std.fmt.bufPrint(&buf, "fg {d:>3}:", .{y}) catch "fg ?:");
        var x: u16 = 0;
        var first = true;
        while (x < f.cols) {
            const here = f.slots[@as(usize, y) * f.cols + x].style;
            var run = x + 1;
            while (run < f.cols and sameInk(f.slots[@as(usize, y) * f.cols + run].style, here)) run += 1;
            if (!first) try out.appendSlice(arena, " |");
            try out.appendSlice(arena, std.fmt.bufPrint(&buf, " {d}-{d} ", .{ x, run - 1 }) catch " ");
            const word: []const u8 = if (here.fg) |c| switch (c) {
                .rgb => |v| std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ v[0], v[1], v[2] }) catch "#??????",
                .index => |i| std.fmt.bufPrint(&buf, "i{d}", .{i}) catch "i?",
            } else "-";
            try out.appendSlice(arena, word);
            if (here.mods.bold) try out.appendSlice(arena, "+b");
            if (here.mods.dim) try out.appendSlice(arena, "+d");
            if (here.mods.underline) try out.appendSlice(arena, "+u");
            first = false;
            x = run;
        }
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn sameInk(a: Style, b: Style) bool {
    return std.meta.eql(a.fg, b.fg) and a.mods.bits() == b.mods.bits();
}

/// The wide ranges a terminal renders two cells wide.
pub fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "put / text / fill land in the slots; a wide glyph owns a tail" {
    var f = try Frame.init(testing.allocator, 6, 2);
    defer f.deinit();
    try testing.expectEqual(@as(u16, 4), f.text(0, 0, 10, "ab漢", .bold));
    try testing.expectEqualStrings("a", f.at(0, 0).symbol());
    try testing.expectEqualStrings("漢", f.at(2, 0).symbol());
    try testing.expectEqualStrings("", f.at(3, 0).symbol());
    try testing.expect(f.at(0, 0).style.mods.bold);
    // Clipped at the edge and at max_w; off-grid is ignored.
    try testing.expectEqual(@as(u16, 2), f.text(4, 1, 10, "xyz", .none));
    try testing.expectEqual(@as(u16, 1), f.text(0, 1, 1, "xyz", .none));
    f.put(9, 9, "!", .none);
    f.fill(1, 1, 2, 5, .{ .bg = .{ .index = 1 } });
    try testing.expectEqual(Color{ .index = 1 }, f.at(2, 1).style.bg.?);
    try testing.expectEqualStrings(" ", f.at(2, 1).symbol());
}

test "a null bg leaves the ground alone; a real one replaces it" {
    var f = try Frame.init(testing.allocator, 8, 2);
    defer f.deinit();
    const ground: Color = .{ .rgb = .{ 0x31, 0x35, 0x3d } };
    const pane_bg: Color = .{ .rgb = .{ 0x1e, 0x22, 0x2a } };
    f.clear(.{ .bg = pane_bg });
    f.fill(0, 0, 8, 1, .{ .bg = ground });
    // Row text carries a foreground and no bg — the fill stays under it.
    _ = f.text(0, 0, 8, "ab漢", .{ .fg = .{ .index = 7 } });
    try testing.expectEqual(ground, f.at(0, 0).style.bg.?);
    try testing.expectEqual(ground, f.at(2, 0).style.bg.?);
    // …including the wide glyph's tail cell, or the row would gap.
    try testing.expectEqual(ground, f.at(3, 0).style.bg.?);
    f.put(5, 0, "!", .{ .fg = .{ .index = 7 } });
    try testing.expectEqual(ground, f.at(5, 0).style.bg.?);
    // A style that names a bg still wins: a chip on a row is its own.
    _ = f.text(6, 0, 2, "x", .{ .bg = .{ .index = 4 } });
    try testing.expectEqual(Color{ .index = 4 }, f.at(6, 0).style.bg.?);
    // A row that was never filled keeps the pane's ground, not a stale one.
    _ = f.text(0, 1, 8, "cd", .{ .fg = .{ .index = 7 } });
    try testing.expectEqual(pane_bg, f.at(0, 1).style.bg.?);
    // And `fill` is still absolute: a null bg there means the default.
    f.fill(0, 0, 8, 1, .{});
    try testing.expect(f.at(0, 0).style.bg == null);
}

test "bgDump run-length codes each row's grounds, and says which cells have none" {
    var f = try Frame.init(testing.allocator, 6, 2);
    defer f.deinit();
    f.fill(0, 0, 6, 1, .{ .bg = .{ .rgb = .{ 0x2c, 0x32, 0x3c } } });
    f.fill(0, 1, 1, 1, .{ .bg = .{ .index = 4 } });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const dump = try bgDump(arena_state.allocator(), &f);
    try testing.expectEqualStrings(
        \\bg   0: 0-5 #2c323c
        \\bg   1: 0-0 i4 | 1-5 -
        \\
    , dump);
}

test "take: full first, then only the dirty rows, then nothing; resize makes the next one full" {
    var f = try Frame.init(testing.allocator, 4, 3);
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try f.take(arena);
    try testing.expectEqual(@as(usize, 3), first.full.len);
    try testing.expectEqual(@as(usize, 4), first.full[0].len);
    try testing.expect((try f.take(arena)) == .nothing);
    _ = f.text(0, 2, 4, "hi", .none);
    const d = try f.take(arena);
    try testing.expectEqual(@as(usize, 1), d.dirty.len);
    try testing.expectEqual(@as(u16, 2), d.dirty[0].y);
    try testing.expectEqualStrings("h", d.dirty[0].cells[0].symbol);
    try testing.expect((try f.take(arena)) == .nothing);
    // The round trip through the wire keeps the symbols. (`Cell.symbol`
    // borrows the frame's slot: encode before the frame changes.)
    const body = try wire.encode(testing.allocator, wire.SiblingMessage{ .frame_dirty = .{ .rows = d.dirty } });
    defer testing.allocator.free(body);
    const back = try wire.decode(wire.SiblingMessage, arena, body);
    try testing.expectEqualStrings("i", back.frame_dirty.rows[0].cells[1].symbol);
    try f.resize(2, 2);
    const again = try f.take(arena);
    try testing.expectEqual(@as(usize, 2), again.full.len);
    try testing.expectEqualStrings(" ", again.full[1][1].symbol);
}

test "isWide covers CJK and emoji, not ASCII or box drawing" {
    try testing.expect(isWide('漢'));
    try testing.expect(isWide(0x1F600));
    try testing.expect(!isWide('a'));
    try testing.expect(!isWide('│'));
    try testing.expect(!isWide('▸'));
}
