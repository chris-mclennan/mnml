//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! A plain-text editor view: gutter, folds as one row, char-break wrap,
//! selection / match backgrounds, and the cursor kept visible.

const std = @import("std");
const Rect = @import("rect.zig");
const Canvas = @import("canvas.zig");
const context = @import("context.zig");
const color = @import("color.zig");
const ids = @import("../core/ids.zig");
pub const Ui = context.Ui;
pub const Style = color.Style;

/// Byte range.
pub const Span = struct { start: usize, end: usize, style: Style };
pub const Range = struct { start: usize, end: usize };
/// 0-based, inclusive, collapsed.
pub const Fold = struct { first_line: u32, last_line: u32 };

pub const Doc = struct {
    text: []const u8,
    cursor: usize,
    anchor: ?usize,
    extra_cursors: []const usize = &.{},
    folds: []const Fold = &.{},
    spans: []const Span = &.{},
    matches: []const Range = &.{},
    current_match: ?usize = null,
    wrap: bool,
    tab_width: u8,
    line_numbers: bool = true,
    cursor_shape: enum { block, bar, underline } = .block,
    focused: bool,
    visual_block: bool = false,
};

pub const ViewState = struct { scroll_line: u32 = 0, scroll_col: u32 = 0 };
pub const Cursor = struct { x: u16, y: u16 };

const Line = struct { start: usize, end: usize };

fn lineAt(text: []const u8, idx: usize) Line {
    var start: usize = 0;
    var n: usize = 0;
    while (n < idx) : (n += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return .{ .start = text.len, .end = text.len };
        start = nl + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return .{ .start = start, .end = end };
}

fn lineCount(text: []const u8) usize {
    return std.mem.count(u8, text, "\n") + 1;
}

fn lineOfByte(text: []const u8, b: usize) usize {
    return std.mem.count(u8, text[0..@min(b, text.len)], "\n");
}

fn foldAt(folds: []const Fold, line: usize) ?Fold {
    for (folds) |f| if (f.first_line == line) return f;
    return null;
}

fn insideFold(folds: []const Fold, line: usize) bool {
    for (folds) |f| if (line > f.first_line and line <= f.last_line) return true;
    return false;
}

fn styleFor(doc: Doc, ui: Ui, byte: usize, base: Style) Style {
    var s = base;
    for (doc.spans) |sp| if (byte >= sp.start and byte < sp.end) {
        s = sp.style;
        s.bg = base.bg;
        break;
    };
    for (doc.matches, 0..) |m, i| if (byte >= m.start and byte < m.end) {
        s.bg = if (doc.current_match == i) ui.theme.current_match.bg else ui.theme.match.bg;
    };
    if (doc.anchor) |a| {
        const lo = @min(a, doc.cursor);
        const hi = @max(a, doc.cursor);
        if (byte >= lo and byte < hi) s.bg = ui.theme.selection.bg;
    }
    return s;
}

/// Paints gutter + text, keeps the cursor visible (adjusting `view`),
/// registers `.editor_cell` hits per visible row, and returns the
/// cursor's screen position (null when off-screen).
pub fn draw(ui: Ui, pane: ids.PaneId, area: Rect, view: *ViewState, doc: Doc) ?Cursor {
    if (area.isEmpty()) return null;
    ui.canvas.fill(area, ui.theme.bg);
    const total = lineCount(doc.text);
    var digits: u16 = 1;
    var t = total;
    while (t >= 10) : (t /= 10) digits += 1;
    const gutter_w: u16 = if (doc.line_numbers) @min(digits + 2, area.w) else 0;
    const text_w: u16 = area.w - gutter_w;
    if (text_w == 0) return null;
    const tab_w: usize = @max(doc.tab_width, 1);

    // Visual rows per logical line under wrap (a folded line is one row).
    const cursor_line = lineOfByte(doc.text, doc.cursor);
    // Keep the cursor's line visible: scroll_line counts logical lines
    // that are not hidden inside a fold.
    if (cursor_line < view.scroll_line) view.scroll_line = @intCast(cursor_line);
    while (true) {
        var rows: usize = 0;
        var l: usize = view.scroll_line;
        var reached = false;
        while (l < total and rows < area.h) : (l += 1) {
            if (insideFold(doc.folds, l)) continue;
            if (l == cursor_line) reached = true;
            rows += rowsFor(doc, l, text_w, tab_w);
            if (l == cursor_line and rows <= area.h) break;
        }
        if (reached and rows <= area.h) break;
        if (view.scroll_line + 1 >= total) break;
        view.scroll_line += 1;
    }
    // Horizontal scroll (no wrap): keep the cursor column visible.
    const cl = lineAt(doc.text, cursor_line);
    const cursor_col = displayCol(doc.text[cl.start..@min(doc.cursor, cl.end)], tab_w);
    if (!doc.wrap) {
        if (cursor_col < view.scroll_col) view.scroll_col = @intCast(cursor_col);
        if (cursor_col >= view.scroll_col + text_w) view.scroll_col = @intCast(cursor_col + 1 - text_w);
    } else view.scroll_col = 0;

    var out: ?Cursor = null;
    var y: u16 = 0;
    var line: usize = view.scroll_line;
    while (line < total and y < area.h) : (line += 1) {
        if (insideFold(doc.folds, line)) continue;
        const ln = lineAt(doc.text, line);
        const fold = foldAt(doc.folds, line);
        // Gutter.
        if (gutter_w > 0) {
            const num = std.fmt.allocPrint(ui.arena, "{d}", .{line + 1}) catch return out;
            // The number right-aligned, then a one-cell pad before the text.
            const gr = Rect.init(area.x, area.y + y, gutter_w, 1);
            ui.canvas.fill(gr, ui.theme.gutter);
            _ = ui.canvas.text(Rect.init(gr.x, gr.y, gr.w - 1, 1), &.{.{ .text = num, .style = ui.theme.gutter }}, .{ .alignment = .right });
        }
        const row_rect = Rect.init(area.x + gutter_w, area.y + y, text_w, 1);
        ui.hits.add(ui.arena, row_rect, .{ .editor_cell = .{ .pane = pane, .line = @intCast(line), .col = view.scroll_col } }) catch {};
        // Text.
        var col: usize = 0; // display column within the logical line
        var x: u16 = 0;
        var b: usize = ln.start;
        const base = if (line == cursor_line and doc.focused) ui.theme.cursor_line else ui.theme.bg;
        if (line == cursor_line) ui.canvas.fill(row_rect, base);
        while (b <= ln.end) {
            const at_end = b == ln.end;
            const cp_len: usize = if (at_end) 1 else std.unicode.utf8ByteSequenceLength(doc.text[b]) catch 1;
            const glyph: []const u8 = if (at_end) " " else doc.text[b..@min(b + cp_len, ln.end)];
            const is_tab = !at_end and glyph[0] == '\t';
            const w: usize = if (is_tab) tab_w - (col % tab_w) else if (at_end) 1 else @max(Canvas.measureWidth(glyph, ui.canvas.widthMethod()), 1);
            // Wrap to the next visual row when the glyph would overflow.
            if (doc.wrap and x + w > text_w and x > 0) {
                y += 1;
                x = 0;
                if (y >= area.h) break;
                const rr = Rect.init(area.x + gutter_w, area.y + y, text_w, 1);
                ui.hits.add(ui.arena, rr, .{ .editor_cell = .{ .pane = pane, .line = @intCast(line), .col = @intCast(col) } }) catch {};
            }
            if (b == doc.cursor and out == null and (!doc.wrap or x < text_w)) {
                const cx = if (doc.wrap) x else @as(i64, @intCast(col)) - @as(i64, @intCast(view.scroll_col));
                if (cx >= 0 and cx < text_w) out = .{ .x = area.x + gutter_w + @as(u16, @intCast(cx)), .y = area.y + y };
            }
            if (!at_end) {
                const style = styleFor(doc, ui, b, base);
                var k: usize = 0;
                while (k < w) : (k += 1) {
                    const vis_col: i64 = if (doc.wrap) @as(i64, @intCast(x + k)) else @as(i64, @intCast(col + k)) - @as(i64, @intCast(view.scroll_col));
                    if (vis_col < 0 or vis_col >= text_w) continue;
                    const px: u16 = area.x + gutter_w + @as(u16, @intCast(vis_col));
                    if (is_tab or k > 0) {
                        if (!(k > 0 and !is_tab)) ui.canvas.put(px, area.y + y, Canvas.blank(style));
                    } else {
                        ui.canvas.put(px, area.y + y, .{ .char = .{ .grapheme = glyph, .width = @intCast(w) }, .style = style });
                    }
                }
            }
            if (at_end) break;
            col += w;
            x += @intCast(w);
            b += cp_len;
        }
        if (fold) |f| {
            const hidden = f.last_line - f.first_line;
            const chip = if (ui.ascii)
                std.fmt.allocPrint(ui.arena, " ... folded - {d} lines hidden", .{hidden}) catch return out
            else
                std.fmt.allocPrint(ui.arena, " ⋯ folded · {d} lines hidden", .{hidden}) catch return out;
            const cx: i64 = if (doc.wrap) @as(i64, @intCast(x)) else @as(i64, @intCast(col)) - @as(i64, @intCast(view.scroll_col));
            if (cx >= 0 and cx < text_w) {
                const r = Rect.init(area.x + gutter_w + @as(u16, @intCast(cx)), area.y + y, text_w - @as(u16, @intCast(cx)), 1);
                _ = ui.canvas.text(r, &.{.{ .text = chip, .style = ui.theme.fold }}, .{});
            }
        }
        y += 1;
    }
    if (out) |c| {
        ui.canvas.screen.cursor = .{ .row = c.y, .col = c.x };
        ui.canvas.screen.cursor_vis = doc.focused;
    }
    return out;
}

fn rowsFor(doc: Doc, line: usize, text_w: u16, tab_w: usize) usize {
    if (!doc.wrap) return 1;
    const ln = lineAt(doc.text, line);
    const cols = displayCol(doc.text[ln.start..ln.end], tab_w);
    return @max(1, (cols + text_w - 1) / text_w);
}

fn displayCol(s: []const u8, tab_w: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (s[i] == '\t') col += tab_w - (col % tab_w) else col += 1;
        i += n;
    }
    return col;
}

test "editor view: paints text, folds hide lines, wrap continues rows" {
    const vaxis = @import("vaxis");
    const hit = @import("hit.zig");
    const theme = @import("theme.zig");
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 40, .rows = 5, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var hits: hit.HitMap = .{};
    const ui: Ui = .{ .canvas = Canvas.init(&screen, .{}), .hits = &hits, .theme = &theme.Theme.default, .arena = arena.allocator(), .focus = .tree };
    var view: ViewState = .{};
    const doc: Doc = .{ .text = "fn main() {\n  one;\n  two;\n}\nend", .cursor = 0, .anchor = null, .folds = &.{.{ .first_line = 0, .last_line = 3 }}, .wrap = false, .tab_width = 4, .focused = true };
    const cur = draw(ui, 0, Rect.init(0, 0, 40, 5), &view, doc);
    try std.testing.expectEqual(@as(u16, 3), cur.?.x);
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, Canvas.rowText(&screen, 0, &buf), "folded") != null);
    try std.testing.expect(std.mem.indexOf(u8, Canvas.rowText(&screen, 1, &buf), "end") != null);
    // Wrap: a 31-char line on a 17-cell text area continues onto row 1.
    var view2: ViewState = .{};
    const long: Doc = .{ .text = "AAA BBB CCC DDD EEE FFF GGG ZZZ", .cursor = 0, .anchor = null, .wrap = true, .tab_width = 4, .focused = true };
    _ = draw(ui, 0, Rect.init(0, 0, 20, 5), &view2, long);
    try std.testing.expect(std.mem.indexOf(u8, Canvas.rowText(&screen, 1, &buf), "ZZZ") != null);
}
