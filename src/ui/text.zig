//! Text layout — the ratatui `Paragraph` semantics over `[]const Segment`.
//!
//! Three wrap modes: `.none` (one row per logical line, cut at the width),
//! `.word` (ratatui's `WordWrapper`, `trim` selectable — mnml ships
//! `Wrap { trim: false }`), `.grapheme` (break anywhere). Alignment per
//! paragraph, vertical scroll in wrapped rows, horizontal scroll in cells
//! for unwrapped left-aligned text.
//!
//! Layout allocates nothing: a wrapped line is a `[start, end)` pair of
//! positions into the segment list, and the word wrapper's three pending
//! buffers are contiguous ranges of the grapheme stream, so they are
//! four cursors and three widths instead of three `Vec`s.

const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../core/utf8.zig");
const Rect = @import("rect.zig");
const Canvas = @import("canvas.zig");

pub const Segment = vaxis.Segment;
const Method = vaxis.gwidth.Method;

pub const Wrap = enum { none, word, grapheme };
pub const Alignment = enum { left, center, right };

pub const Options = struct {
    wrap: Wrap = .none,
    alignment: Alignment = .left,
    /// Drop whitespace at the start of wrapped continuation lines
    /// (ratatui `Wrap { trim }`). Only meaningful for `.word`.
    trim: bool = false,
    /// Wrapped rows to skip before the first painted row.
    scroll_y: u16 = 0,
    /// Cells to skip at the left of each row. Honoured for `.none` +
    /// `.left` only, like ratatui's `Paragraph::scroll`.
    scroll_x: u16 = 0,
};

/// A position in the segment list: segment index + byte offset.
pub const Pos = struct {
    seg: u32 = 0,
    off: u32 = 0,

    pub fn eql(a: Pos, b: Pos) bool {
        return a.seg == b.seg and a.off == b.off;
    }

    /// The end of one segment and the start of the next are the same
    /// place; fold the first spelling into the second so positions
    /// produced by different walks compare equal.
    pub fn canonical(p: Pos, segs: []const Segment) Pos {
        var q = p;
        while (q.seg < segs.len and q.off >= segs[q.seg].text.len) {
            q = .{ .seg = q.seg + 1, .off = 0 };
        }
        return q;
    }
};

pub const Glyph = struct {
    bytes: []const u8,
    seg: u32,
    start: Pos,
    width: u16,
    is_ws: bool,
    is_newline: bool,
};

/// Grapheme stream across segments, resumable from any `Pos`.
pub const Stream = struct {
    segs: []const Segment,
    method: Method,
    pos: Pos,
    it: ?utf8.GraphemeIterator = null,
    base: u32 = 0,

    pub fn init(segs: []const Segment, method: Method, pos: Pos) Stream {
        return .{ .segs = segs, .method = method, .pos = pos };
    }

    pub fn reset(s: *Stream, pos: Pos) void {
        s.pos = pos;
        s.it = null;
    }

    pub fn next(s: *Stream) ?Glyph {
        while (true) {
            if (s.pos.seg >= s.segs.len) return null;
            const text = s.segs[s.pos.seg].text;
            if (s.it == null) {
                if (s.pos.off >= text.len) {
                    s.pos = .{ .seg = s.pos.seg + 1, .off = 0 };
                    continue;
                }
                s.base = s.pos.off;
                s.it = utf8.graphemeIterator(text[s.pos.off..]);
            }
            const g = s.it.?.next() orelse {
                s.it = null;
                s.pos = .{ .seg = s.pos.seg + 1, .off = 0 };
                continue;
            };
            const start: u32 = s.base + @as(u32, @intCast(g.start));
            const bytes = text[start .. start + g.len];
            const glyph_pos: Pos = .{ .seg = s.pos.seg, .off = start };
            s.pos.off = start + @as(u32, @intCast(g.len));
            const nl = isNewline(bytes);
            return .{
                .bytes = bytes,
                .seg = glyph_pos.seg,
                .start = glyph_pos,
                .width = if (nl) 0 else Canvas.measureWidth(bytes, s.method),
                .is_ws = !nl and isWhitespace(bytes),
                .is_newline = nl,
            };
        }
    }
};

fn isNewline(g: []const u8) bool {
    return std.mem.eql(u8, g, "\n") or std.mem.eql(u8, g, "\r\n") or std.mem.eql(u8, g, "\r");
}

/// Rust `char::is_whitespace` on the cluster's first scalar.
fn isWhitespace(g: []const u8) bool {
    const n = std.unicode.utf8ByteSequenceLength(g[0]) catch return false;
    if (n > g.len) return false;
    const cp = std.unicode.utf8Decode(g[0..n]) catch return false;
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// One laid-out row: the glyphs in `[start, end)` minus those wider than
/// the layout width, which paint skips again.
pub const Line = struct {
    start: Pos,
    end: Pos,
    width: u16,
};

pub const Layout = struct {
    stream: Stream,
    max_w: u16,
    wrap: Wrap,
    trim: bool,
    finished: bool = false,

    // Word-wrap state. pending_line = [ls, le), pending_ws = [ws, wd),
    // pending_word = [wd, stream.pos).
    in_line: bool = false,
    ls: Pos = .{},
    le: Pos = .{},
    ws: Pos = .{},
    wd: Pos = .{},
    line_w: u16 = 0,
    ws_w: u16 = 0,
    word_w: u16 = 0,
    line_nonempty: bool = false,
    non_ws_prev: bool = false,
    emitted_any: bool = false,

    pub fn init(segs: []const Segment, max_w: u16, wrap: Wrap, trim: bool, method: Method) Layout {
        return .{ .stream = Stream.init(segs, method, .{}), .max_w = max_w, .wrap = wrap, .trim = trim };
    }

    pub fn next(l: *Layout) ?Line {
        if (l.finished) return null;
        return switch (l.wrap) {
            .none => l.nextUnwrapped(),
            .grapheme => l.nextGrapheme(),
            .word => l.nextWord(),
        };
    }

    fn nextUnwrapped(l: *Layout) ?Line {
        const start = l.stream.pos;
        var end = start;
        var w: u16 = 0;
        while (l.stream.next()) |g| {
            if (g.is_newline) return .{ .start = start, .end = end, .width = w };
            w +|= g.width;
            end = l.stream.pos;
        }
        l.finished = true;
        return .{ .start = start, .end = end, .width = w };
    }

    fn nextGrapheme(l: *Layout) ?Line {
        const start = l.stream.pos;
        var end = start;
        var w: u16 = 0;
        while (l.stream.next()) |g| {
            if (g.is_newline) return .{ .start = start, .end = end, .width = w };
            if (g.width > l.max_w) continue;
            if (w + g.width > l.max_w) {
                // `g` opens the next row.
                l.stream.reset(g.start);
                return .{ .start = start, .end = end, .width = w };
            }
            w += g.width;
            end = l.stream.pos;
        }
        l.finished = true;
        return .{ .start = start, .end = end, .width = w };
    }

    fn beginInputLine(l: *Layout) void {
        const p = l.stream.pos;
        l.ls = p;
        l.le = p;
        l.ws = p;
        l.wd = p;
        l.line_w = 0;
        l.ws_w = 0;
        l.word_w = 0;
        l.line_nonempty = false;
        l.non_ws_prev = false;
        l.emitted_any = false;
        l.in_line = true;
    }

    /// pending_line += pending_ws (unless empty+trim) + pending_word, where
    /// the word ends at `word_end`.
    fn flushInto(l: *Layout, word_end: Pos) void {
        const ws_nonempty = !l.ws.eql(l.wd);
        if (l.line_nonempty or !l.trim) {
            if (!l.line_nonempty) l.ls = l.ws;
            l.le = l.wd;
            l.line_w +|= l.ws_w;
            if (ws_nonempty) l.line_nonempty = true;
        } else {
            l.ls = l.wd;
        }
        if (!l.wd.eql(word_end)) l.line_nonempty = true;
        l.le = word_end;
        l.line_w +|= l.word_w;
        l.ws = word_end;
        l.wd = word_end;
        l.ws_w = 0;
        l.word_w = 0;
    }

    fn takeLine(l: *Layout) Line {
        const line: Line = .{ .start = l.ls, .end = l.le, .width = l.line_w };
        l.line_w = 0;
        l.line_nonempty = false;
        l.ls = l.ws;
        l.le = l.ws;
        l.emitted_any = true;
        return line;
    }

    /// End of an input line (newline or EOF). Returns the last row, if any.
    fn finishInputLine(l: *Layout, cur: Pos) ?Line {
        l.in_line = false;
        const word_nonempty = !l.wd.eql(cur);
        const ws_nonempty = !l.ws.eql(l.wd);
        if (!l.line_nonempty and !word_nonempty and ws_nonempty and l.trim) {
            return .{ .start = cur, .end = cur, .width = 0 };
        }
        l.flushInto(cur);
        if (l.line_nonempty) return l.takeLine();
        if (!l.emitted_any) return .{ .start = cur, .end = cur, .width = 0 };
        return null;
    }

    fn nextWord(l: *Layout) ?Line {
        while (true) {
            if (!l.in_line) l.beginInputLine();
            const g = l.stream.next() orelse {
                l.finished = true;
                return l.finishInputLine(l.stream.pos);
            };
            if (g.is_newline) {
                if (l.finishInputLine(g.start)) |line| return line;
                continue;
            }
            if (g.width > l.max_w) continue;

            var out: ?Line = null;
            const word_found = l.non_ws_prev and g.is_ws;
            const line_empty = !l.line_nonempty;
            const trimmed_overflow = line_empty and l.trim and l.word_w + g.width > l.max_w;
            const ws_overflow = line_empty and l.trim and l.ws_w + g.width > l.max_w;
            const untrimmed_overflow = line_empty and !l.trim and l.word_w + l.ws_w + g.width > l.max_w;
            if (word_found or trimmed_overflow or ws_overflow or untrimmed_overflow) {
                l.flushInto(g.start);
            }

            const line_full = l.line_w >= l.max_w;
            const word_overflow = g.width > 0 and l.line_w + l.ws_w + l.word_w >= l.max_w;
            if (line_full or word_overflow) {
                var remaining = l.max_w -| l.line_w;
                out = l.takeLine();
                // Drop whitespace that would sit at the end of the emitted row.
                var ws_it = Stream.init(l.stream.segs, l.stream.method, l.ws);
                while (!ws_it.pos.eql(l.wd)) {
                    const sp = ws_it.next() orelse break;
                    if (sp.width > remaining) break;
                    l.ws_w -= sp.width;
                    remaining -= sp.width;
                    l.ws = ws_it.pos;
                }
                l.ls = l.ws;
                l.le = l.ws;
                if (g.is_ws and l.ws.eql(l.wd)) {
                    // First whitespace after a wrap does not start the next row.
                    l.ws = l.stream.pos;
                    l.wd = l.stream.pos;
                    return out;
                }
            }

            if (g.is_ws) {
                l.ws_w +|= g.width;
                l.wd = l.stream.pos;
            } else {
                l.word_w +|= g.width;
            }
            l.non_ws_prev = !g.is_ws;
            if (out) |line| return line;
        }
    }
};

fn alignOffset(line_w: u16, area_w: u16, alignment: Alignment) u16 {
    if (line_w >= area_w) return 0;
    return switch (alignment) {
        .left => 0,
        .center => (area_w - line_w) / 2,
        .right => area_w - line_w,
    };
}

/// Paints `segs` into `r` (clipped by the canvas). Returns rows used.
pub fn draw(c: Canvas, r: Rect, segs: []const Segment, opts: Options) u16 {
    if (r.w == 0 or r.h == 0) return 0;
    var layout = Layout.init(segs, r.w, opts.wrap, opts.trim, c.widthMethod());
    var skip = opts.scroll_y;
    var row: u16 = 0;
    const hscroll: u16 = if (opts.wrap == .none and opts.alignment == .left) opts.scroll_x else 0;
    while (layout.next()) |line| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        if (row >= r.h) break;
        const x0 = r.x + alignOffset(line.width, r.w, opts.alignment);
        paintLine(c, x0, r.y + row, r.w, line, segs, hscroll);
        row += 1;
    }
    return row;
}

fn paintLine(c: Canvas, x0: u16, y: u16, max_w: u16, line: Line, segs: []const Segment, scroll_x: u16) void {
    var s = Stream.init(segs, c.widthMethod(), line.start);
    var hskip = scroll_x;
    var col: u16 = 0;
    const end = line.end.canonical(segs);
    while (!s.pos.canonical(segs).eql(end)) {
        const g = s.next() orelse break;
        if (g.width == 0 or g.width > max_w) continue;
        if (hskip > 0) {
            if (g.width <= hskip) {
                hskip -= g.width;
                continue;
            }
            hskip = 0;
        }
        if (col + g.width > max_w) break;
        const owner = segs[g.seg];
        c.put(x0 + col, y, .{
            .char = .{ .grapheme = g.bytes, .width = @intCast(g.width) },
            .style = owner.style,
            .link = owner.link,
        });
        col += g.width;
    }
}

/// Rows the text would occupy at `width` — for sizing before painting.
pub fn measure(segs: []const Segment, width: u16, opts: Options, method: Method) u16 {
    if (width == 0) return 0;
    var layout = Layout.init(segs, width, opts.wrap, opts.trim, method);
    var rows: u16 = 0;
    while (layout.next()) |_| rows +|= 1;
    return rows;
}

// ── tests ──

const testing = std.testing;

const Fixture = struct {
    screen: vaxis.Screen,
    canvas: Canvas,

    fn init(w: u16, h: u16) !Fixture {
        var screen = try vaxis.Screen.init(testing.allocator, .{ .cols = w, .rows = h, .x_pixel = 0, .y_pixel = 0 });
        screen.width_method = .unicode;
        return .{ .screen = screen, .canvas = undefined };
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

fn seg(t: []const u8) Segment {
    return .{ .text = t };
}

fn one(t: []const u8) [1]Segment {
    return .{seg(t)};
}

test "none: one row per logical line, cut at the width" {
    var f = try Fixture.init(5, 4);
    defer f.deinit();
    const rows = draw(f.c(), Rect.init(0, 0, 5, 4), &one("hello world\nab\r\n\nlast"), .{});
    try testing.expectEqual(@as(u16, 4), rows);
    try f.expectRows(&.{ "hello", "ab", "", "last" });
    try testing.expectEqual(@as(u16, 4), measure(&one("hello world\nab\r\n\nlast"), 5, .{}, .unicode));
    try testing.expectEqual(@as(u16, 1), measure(&one(""), 5, .{}, .unicode));
    try testing.expectEqual(@as(u16, 2), measure(&one("a\n"), 5, .{}, .unicode));
}

test "none: rows are capped by the area and reported" {
    var f = try Fixture.init(5, 2);
    defer f.deinit();
    const rows = draw(f.c(), Rect.init(0, 0, 5, 2), &one("a\nb\nc"), .{});
    try testing.expectEqual(@as(u16, 2), rows);
    try f.expectRows(&.{ "a", "b" });
    try testing.expectEqual(@as(u16, 0), draw(f.c(), Rect.init(0, 0, 0, 2), &one("a"), .{}));
}

test "grapheme: break anywhere, wide glyph moves whole to the next row" {
    var f = try Fixture.init(5, 4);
    defer f.deinit();
    _ = draw(f.c(), Rect.init(0, 0, 4, 2), &one("abcdefgh"), .{ .wrap = .grapheme });
    try f.expectRows(&.{ "abcd", "efgh" });
    var g = try Fixture.init(5, 3);
    defer g.deinit();
    const rows = draw(g.c(), Rect.init(0, 0, 5, 3), &one("漢字漢字"), .{ .wrap = .grapheme });
    try testing.expectEqual(@as(u16, 2), rows);
    try g.expectRows(&.{ "漢字", "漢字" });
    try testing.expectEqual(@as(u16, 2), measure(&one("漢字漢字"), 5, .{ .wrap = .grapheme }, .unicode));
}

test "word: ratatui WordWrapper cases, trim false" {
    const cases = [_]struct { text: []const u8, w: u16, rows: []const []const u8 }{
        .{ .text = "hello world", .w = 5, .rows = &.{ "hello", "world" } },
        .{ .text = "ab cdefg", .w = 5, .rows = &.{ "ab", "cdefg" } },
        .{ .text = "abcdefgh", .w = 4, .rows = &.{ "abcd", "efgh" } },
        .{ .text = "a  b", .w = 2, .rows = &.{ "a", "b" } },
        .{ .text = "  hi", .w = 10, .rows = &.{"  hi"} },
        .{ .text = "ab ", .w = 5, .rows = &.{"ab"} },
        .{ .text = "hello world\nfoo", .w = 5, .rows = &.{ "hello", "world", "foo" } },
        .{ .text = "漢字 漢字", .w = 5, .rows = &.{ "漢字", "漢字" } },
        .{ .text = "a b c d", .w = 3, .rows = &.{ "a b", "c d" } },
        .{ .text = "", .w = 3, .rows = &.{""} },
        .{ .text = "\n", .w = 3, .rows = &.{ "", "" } },
    };
    for (cases) |case| {
        var f = try Fixture.init(12, 6);
        defer f.deinit();
        const rows = draw(f.c(), Rect.init(0, 0, case.w, 6), &one(case.text), .{ .wrap = .word });
        testing.expectEqual(@as(u16, @intCast(case.rows.len)), rows) catch |err| {
            std.debug.print("case {s} width {d}\n", .{ case.text, case.w });
            return err;
        };
        f.expectRows(case.rows) catch |err| {
            std.debug.print("case {s} width {d}\n", .{ case.text, case.w });
            return err;
        };
        try testing.expectEqual(rows, measure(&one(case.text), case.w, .{ .wrap = .word }, .unicode));
    }
}

test "word: trailing space kept without trim is a real cell" {
    var f = try Fixture.init(6, 1);
    defer f.deinit();
    _ = draw(f.c(), Rect.init(0, 0, 6, 1), &one("ab "), .{ .wrap = .word });
    try testing.expectEqualStrings(" ", f.screen.readCell(2, 0).?.char.grapheme);
}

test "word: trim drops leading whitespace on continuation rows and the first row" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    _ = draw(f.c(), Rect.init(0, 0, 10, 4), &one("  hi there"), .{ .wrap = .word, .trim = true });
    try f.expectRows(&.{"hi there"});
    var g = try Fixture.init(12, 4);
    defer g.deinit();
    const rows = draw(g.c(), Rect.init(0, 0, 3, 4), &one("   "), .{ .wrap = .word, .trim = true });
    try testing.expectEqual(@as(u16, 1), rows);
    try g.expectRows(&.{""});
}

test "word: segments split mid-word keep their styles" {
    var f = try Fixture.init(6, 3);
    defer f.deinit();
    const red: vaxis.Style = .{ .fg = .{ .index = 1 } };
    const segs = [_]Segment{ .{ .text = "hel", .style = red }, .{ .text = "lo world" } };
    _ = draw(f.c(), Rect.init(0, 0, 5, 3), &segs, .{ .wrap = .word });
    try f.expectRows(&.{ "hello", "world" });
    try testing.expectEqual(@as(u8, 1), f.screen.readCell(2, 0).?.style.fg.index);
    try testing.expect(f.screen.readCell(3, 0).?.style.fg == .default);
}

test "alignment offsets each wrapped row by its own width" {
    var f = try Fixture.init(6, 3);
    defer f.deinit();
    _ = draw(f.c(), Rect.init(0, 0, 6, 3), &one("ab\nabc"), .{ .alignment = .center });
    try f.expectRows(&.{ "  ab", " abc" });
    var g = try Fixture.init(6, 3);
    defer g.deinit();
    _ = draw(g.c(), Rect.init(0, 0, 6, 3), &one("ab\nabcdefgh"), .{ .alignment = .right });
    try g.expectRows(&.{ "    ab", "abcdef" });
}

test "scroll_y skips wrapped rows; scroll_x skips cells of unwrapped text" {
    var f = try Fixture.init(6, 1);
    defer f.deinit();
    _ = draw(f.c(), Rect.init(0, 0, 5, 1), &one("hello world"), .{ .wrap = .word, .scroll_y = 1 });
    try f.expectRows(&.{"world"});
    var g = try Fixture.init(6, 1);
    defer g.deinit();
    _ = draw(g.c(), Rect.init(0, 0, 5, 1), &one("hello world"), .{ .scroll_x = 6 });
    try g.expectRows(&.{"world"});
    // A wide glyph straddling the skip is shown whole, like ratatui.
    var h = try Fixture.init(6, 1);
    defer h.deinit();
    _ = draw(h.c(), Rect.init(0, 0, 6, 1), &one("漢字abcd"), .{ .scroll_x = 1 });
    try h.expectRows(&.{"漢字ab"});
}

test "paint goes through the canvas clip" {
    var f = try Fixture.init(6, 2);
    defer f.deinit();
    const c = f.c().sub(Rect.init(1, 0, 3, 1));
    _ = draw(c, Rect.init(0, 0, 6, 2), &one("abcdef\nxy"), .{});
    try f.expectRows(&.{ " bcd", "" });
}

test "wide glyph that cannot fit at the row end never smears" {
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    const c = f.c();
    c.put(5, 0, .{ .char = .{ .grapheme = "│" } });
    _ = draw(c, Rect.init(0, 0, 5, 1), &one("abcd漢"), .{});
    try testing.expectEqualStrings("│", f.screen.readCell(5, 0).?.char.grapheme);
    try testing.expectEqualStrings(" ", f.screen.readCell(4, 0).?.char.grapheme);
}

test "a newline at the start of the next segment ends the row" {
    var f = try Fixture.init(10, 4);
    defer f.deinit();
    const segs = [_]Segment{ .{ .text = "ab" }, .{ .text = "\ncd" } };
    const rows = draw(f.c(), Rect.init(0, 0, 10, 4), &segs, .{ .wrap = .word });
    try testing.expectEqual(@as(u16, 2), rows);
    try f.expectRows(&.{ "ab", "cd", "", "" });
    var g = try Fixture.init(10, 4);
    defer g.deinit();
    _ = draw(g.c(), Rect.init(0, 0, 10, 4), &segs, .{ .wrap = .none });
    try g.expectRows(&.{ "ab", "cd", "", "" });
}
