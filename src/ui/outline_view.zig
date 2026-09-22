//! The outline pane's paint — the Rust `outline_view.rs`, cell for
//! cell: a header naming the file and the symbol count, a key hint in
//! three width tiers, the `/ query█` line while a filter is typed or
//! held, a blank row, then one row per symbol — a two-cell arrow
//! column (`▶` on the pane's cursor row, `●` on the row the source
//! cursor sits in), the kind right-aligned in a ten-cell column in its
//! family's colour, the name indented by nesting depth, the line
//! number after it. A one-cell scrollbar column is reserved down the
//! whole right edge whenever the pane is eight cells wide, so the body
//! never reflows when the list grows past the pane.
//!
//! Every row registers an `.editor_cell{pane, line, col}` naming the
//! symbol's position in the SOURCE — a click is a jump, and the app
//! routes it by the pane's kind.
//!
//! // changed (outline): the header stays put and the list scrolls
//! under it (Rust scrolls the header lines off with the rows); the bar
//! measures the list alone.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const list_panel = @import("list_panel.zig");
const scrollbar = @import("scrollbar.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;
pub const Style = vaxis.Style;

pub const Row = struct {
    name: []const u8,
    kind: []const u8,
    /// 0-based source position.
    line: u32,
    col: u32,
    depth: u8,
};

pub const Props = struct {
    title: []const u8,
    /// The rows that pass the filter, in source order.
    rows: []const Row,
    /// The unfiltered count; `rows.len` when there is no query.
    total: usize,
    /// The pane's own cursor, an index into `rows`.
    cursor: usize,
    /// The row the source cursor is inside, if any (an index into `rows`).
    current: ?usize,
    focused: bool,
    query: []const u8 = "",
    /// Keys build the query; the query line carries a block caret.
    filter_mode: bool = false,
};

/// Rows the header takes before the list starts: the title, the hint,
/// the blank row — plus the query line while one shows.
pub const header_rows: u16 = 3;
pub fn headerRows(p: Props) u16 {
    return header_rows + @as(u16, if (showsQuery(p)) 1 else 0);
}

fn showsQuery(p: Props) bool {
    return p.filter_mode or p.query.len > 0;
}

const arrow_w: u16 = 2;
const kind_w: u16 = 10;
/// Rust reserves the bar from eight cells; below that the body is all.
const bar_min_w: u16 = 8;

/// The hint for a body `w` cells wide — Rust's three tiers, so the row
/// never clips mid-word at the right panel's default width.
pub fn hint(filter_mode: bool, w: u16) []const u8 {
    if (filter_mode) {
        if (w >= 52) return "  filter — type to narrow, ⏎ apply, esc clear";
        if (w >= 30) return "  type · ⏎ apply · esc clear";
        return "  ⏎ / esc";
    }
    if (w >= 52) return "  ⏎ jump   r refresh   / filter   esc back";
    if (w >= 30) return "  ⏎ jump · / filter · esc back";
    return "  ⏎ / r / esc";
}

/// The colour a kind's column paints in — Rust's `kind_color`.
fn kindColor(t: *const Theme, kind: []const u8) vaxis.Color {
    const p = t.palette;
    const families = .{
        .{ p.blue, [_][]const u8{ "fn", "method", "ctor" } },
        .{ p.yellow, [_][]const u8{ "struct", "class", "interface", "enum", "variant", "type" } },
        .{ p.cyan, [_][]const u8{ "const", "var", "field", "property" } },
        .{ p.green, [_][]const u8{ "module", "namespace", "package" } },
    };
    inline for (families) |fam| {
        for (fam[1]) |k| if (std.mem.eql(u8, k, kind)) return fam[0];
    }
    return p.comment;
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, scroll: *usize, p: Props) void {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.isEmpty()) return;
    const bg = t.panel_bg.bg;
    // The bar's column is reserved whether or not the list needs it.
    const cols = area.splitRight(if (area.w >= bar_min_w) 1 else 0);
    const body = cols.left;
    // One cell of air between any text and the bar.
    const air: u16 = if (cols.rest.isEmpty()) 0 else 1;
    const text_end = body.right() -| air;
    // Header.
    const glyph: []const u8 = if (ui.ascii) "outline" else "⌥";
    var x = body.x + 2;
    x += ui.putStr(x, body.y, text_end -| x, glyph, Theme.onBg(t.syntax.keyword, bg));
    x += 1;
    x += ui.putStr(x, body.y, text_end -| x, ui.clipStr(p.title, text_end -| x), Theme.onBg(Theme.withFg(t.tab_active, t.fg.fg), bg));
    const count = if (p.query.len > 0)
        ui.fmt("   {d}/{d} symbol(s)", .{ p.rows.len, p.total })
    else
        ui.fmt("   {d} symbol{s}", .{ p.total, if (p.total == 1) "" else "s" });
    _ = ui.putStr(x, body.y, text_end -| x, count, Theme.onBg(t.muted, bg));
    var y = body.y + 1;
    if (y < body.bottom()) {
        const h = overlay.hintText(ui, hint(p.filter_mode, body.w -| air));
        _ = ui.putStr(body.x, y, body.w -| air, ui.clipStr(h, body.w -| air), Theme.onBg(t.muted, bg));
        y += 1;
    }
    if (showsQuery(p) and y < body.bottom()) {
        var qx = body.x;
        qx += ui.putStr(qx, y, text_end -| qx, "  / ", Theme.onBg(Theme.withFg(t.fg, t.palette.yellow), bg));
        qx += ui.putStr(qx, y, text_end -| qx, ui.clipStr(p.query, text_end -| qx), Theme.onBg(t.fg, bg));
        if (p.filter_mode) _ = ui.putStr(qx, y, text_end -| qx, "█", Theme.onBg(Theme.withFg(t.fg, t.palette.yellow), bg));
        y += 1;
    }
    // The blank row.
    y += 1;
    const list = Rect.init(body.x, @min(y, body.bottom()), body.w, body.bottom() -| y);
    if (p.total == 0 or p.rows.len == 0) {
        scroll.* = 0;
        const note: []const u8 = if (p.total == 0) "  (no symbols)" else "  (no matches)";
        if (!list.isEmpty()) _ = ui.putStr(list.x, list.y, list.w -| air, ui.clipStr(note, list.w -| air), Theme.onBg(t.muted, bg));
        if (!cols.rest.isEmpty()) scrollbar.drawVertical(ui, cols.rest, .{ .pane = pane }, 0, @max(list.h, 1), 0);
        return;
    }
    const win = list_panel.scrollWindow(scroll, p.cursor, p.rows.len, list.h);
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const row = p.rows[idx];
        const r = list.row(@intCast(i));
        const selected = idx == p.cursor;
        const current = !selected and p.current == idx;
        const style: Style = if (selected) Theme.onBg(t.panel_bg, t.cursor_line.bg) else t.panel_bg;
        ui.fill(r, style);
        // The arrow column: `▶` on the cursor row, `●` on the row the
        // source cursor is in; selected wins.
        if (selected) {
            _ = ui.putStr(r.x, r.y, r.w, if (ui.ascii) ">" else "▶", Theme.withFg(style, t.palette.purple));
        } else if (current) {
            _ = ui.putStr(r.x, r.y, r.w, if (ui.ascii) "*" else "●", Theme.withFg(style, t.palette.yellow));
        }
        // Kind, right-aligned in its column.
        const end = r.right() -| air;
        const kind_right = r.x + arrow_w + kind_w;
        if (kind_right <= end) _ = ui.putStrRight(kind_right, r.y, kind_w, row.kind, Theme.withFg(style, kindColor(t, row.kind)));
        const name_x = kind_right + 1 + @as(u16, row.depth) * 2;
        if (name_x >= end) {
            ui.hit(r, .{ .editor_cell = .{ .pane = pane, .line = row.line, .col = row.col } });
            continue;
        }
        const avail = end - name_x;
        const label = ui.fmt("{s}:{d}", .{ row.name, row.line + 1 });
        var name_style = Theme.withFg(style, t.fg.fg);
        name_style.bold = selected;
        _ = ui.putStr(name_x, r.y, avail, ui.clipStr(label, avail), name_style);
        // The `:line` tail in muted — repainted over the label's end.
        const name_w = ui.width(row.name);
        if (name_w < avail) {
            const tail = ui.fmt(":{d}", .{row.line + 1});
            _ = ui.putStr(name_x + name_w, r.y, avail - name_w, tail, Theme.withFg(style, t.muted.fg));
        }
        ui.hit(r, .{ .editor_cell = .{ .pane = pane, .line = row.line, .col = row.col } });
    }
    if (!cols.rest.isEmpty()) scrollbar.drawVertical(ui, cols.rest, .{ .pane = pane }, p.rows.len, list.h, scroll.*);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const three = [_]Row{
    .{ .name = "alpha", .kind = "fn", .line = 0, .col = 3, .depth = 0 },
    .{ .name = "Gamma", .kind = "struct", .line = 8, .col = 7, .depth = 0 },
    .{ .name = "x", .kind = "field", .line = 9, .col = 4, .depth = 1 },
};

fn props(rows: []const Row, cursor: usize, current: ?usize) Props {
    return .{ .title = "code.rs", .rows = rows, .total = rows.len, .cursor = cursor, .current = current, .focused = true };
}

test "header, the hint, kinds right-aligned in ten cells, depth indents, the arrow column, and hits that name the source line" {
    var f = try Fixture.init(44, 8);
    defer f.deinit();
    var scroll: usize = 0;
    draw(f.ui(), 2, f.full(), &scroll, props(&three, 1, 2));
    try f.expectRow(0, "  ⌥ code.rs   3 symbols" ++ " " ** 20 ++ "█");
    try f.expectRow(1, "  ⏎ jump · / filter · esc back" ++ " " ** 13 ++ "█");
    try f.expectRow(2, " " ** 43 ++ "█");
    try f.expectRow(3, "          fn alpha:1" ++ " " ** 23 ++ "█");
    try f.expectRow(4, "▶     struct Gamma:9" ++ " " ** 23 ++ "█");
    try f.expectRow(5, "●      field   x:10" ++ " " ** 24 ++ "█");
    try testing.expectEqual(@as(u32, 8), f.hits.at(5, 4).?.editor_cell.line);
    try testing.expectEqual(@as(u32, 7), f.hits.at(5, 4).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 2), f.hits.at(5, 4).?.editor_cell.pane);
    try testing.expect(f.bgEql(3, 4, f.theme.cursor_line));
    try testing.expect(f.bgEql(3, 5, f.theme.panel_bg));
    try testing.expect(f.style(13, 4).bold);
    try testing.expect(!f.style(13, 3).bold);
    try testing.expect(vaxis.Color.eql(f.style(0, 4).fg, f.theme.palette.purple));
    try testing.expect(vaxis.Color.eql(f.style(0, 5).fg, f.theme.palette.yellow));
    // The kind column's colour follows the family.
    try testing.expect(vaxis.Color.eql(f.style(11, 3).fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.style(11, 4).fg, f.theme.palette.yellow));
    try testing.expect(vaxis.Color.eql(f.style(11, 5).fg, f.theme.palette.cyan));
    // The bar column is the whole height and hits as the pane's bar.
    try testing.expect(f.hits.at(43, 6).? == .scrollbar);
    try testing.expect(f.hits.at(43, 0).? == .scrollbar);
}

test "the hint's three tiers, and the query line with its caret" {
    try testing.expectEqualStrings("  ⏎ jump   r refresh   / filter   esc back", hint(false, 52));
    try testing.expectEqualStrings("  ⏎ jump · / filter · esc back", hint(false, 51));
    try testing.expectEqualStrings("  ⏎ jump · / filter · esc back", hint(false, 30));
    try testing.expectEqualStrings("  ⏎ / r / esc", hint(false, 29));
    try testing.expectEqualStrings("  filter — type to narrow, ⏎ apply, esc clear", hint(true, 60));
    try testing.expectEqualStrings("  type · ⏎ apply · esc clear", hint(true, 31));
    try testing.expectEqualStrings("  ⏎ / esc", hint(true, 12));
    // The `--ascii` spelling is the hint language's, not this view's.
    const ascii = try overlay.asciiHint(testing.allocator, hint(false, 40));
    defer testing.allocator.free(ascii);
    try testing.expectEqualStrings("  enter jump - / filter - esc back", ascii);

    var f = try Fixture.init(40, 8);
    defer f.deinit();
    var scroll: usize = 0;
    var p = props(&three, 0, null);
    p.query = "ga";
    p.filter_mode = true;
    const one = three[1..2];
    p.rows = one;
    draw(f.ui(), 2, f.full(), &scroll, p);
    try f.expectRow(0, "  ⌥ code.rs   1/3 symbol(s)" ++ " " ** 12 ++ "█");
    try f.expectRow(1, "  type · ⏎ apply · esc clear" ++ " " ** 11 ++ "█");
    try f.expectRow(2, "  / ga█" ++ " " ** 32 ++ "█");
    try f.expectRow(3, " " ** 39 ++ "█");
    try f.expectRow(4, "▶     struct Gamma:9" ++ " " ** 19 ++ "█");
    try testing.expectEqual(@as(u16, 4), headerRows(p));
    // A held filter (mode left) keeps the line, without the caret.
    p.filter_mode = false;
    draw(f.ui(), 2, f.full(), &scroll, p);
    try f.expectRow(1, "  ⏎ jump · / filter · esc back" ++ " " ** 9 ++ "█");
    try f.expectRow(2, "  / ga" ++ " " ** 33 ++ "█");
    // No matches keeps the header and says so.
    f.hits.reset();
    p.rows = &.{};
    draw(f.ui(), 2, f.full(), &scroll, p);
    try f.expectRow(4, "  (no matches)" ++ " " ** 25 ++ "█");
    try testing.expect(f.hits.at(5, 4) == null);
    // No symbols at all.
    draw(f.ui(), 2, f.full(), &scroll, props(&.{}, 0, null));
    try f.expectRow(0, "  ⌥ code.rs   0 symbols" ++ " " ** 16 ++ "█");
    try f.expectRow(3, "  (no symbols)" ++ " " ** 25 ++ "█");
    try testing.expectEqual(@as(u16, 3), headerRows(props(&.{}, 0, null)));
}

test "a 100k-char symbol name paints clipped without overflowing the cell sum" {
    var f = try Fixture.init(44, 5);
    defer f.deinit();
    var scroll: usize = 0;
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'n');
    const rows = [_]Row{.{ .name = long, .kind = "fn", .line = 0, .col = 0, .depth = 0 }};
    draw(f.ui(), 2, f.full(), &scroll, .{ .title = long, .rows = &rows, .total = 1, .cursor = 0, .current = null, .focused = true });
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(0, &buf), "nnnn") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(3, &buf), "fn nnnn") != null);
    try testing.expect(std.mem.endsWith(u8, f.row(3, &buf), "… █"));
}

test "the list scrolls to keep the cursor visible and the bar grows a thumb; under eight cells there is no bar" {
    var f = try Fixture.init(30, 6);
    defer f.deinit();
    var scroll: usize = 0;
    var rows: [10]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .name = "s", .kind = "fn", .line = @intCast(i), .col = 0, .depth = 0 };
    draw(f.ui(), 0, f.full(), &scroll, .{ .title = "t", .rows = &rows, .total = 10, .cursor = 9, .current = null, .focused = false });
    try testing.expectEqual(@as(usize, 7), scroll);
    var buf: [64]u8 = undefined;
    const last = f.row(5, &buf);
    try testing.expect(std.mem.startsWith(u8, last, "▶         fn s:10"));
    try testing.expect(std.mem.endsWith(u8, last, "█"));
    try testing.expect(f.hits.at(29, 5).? == .scrollbar);
    try testing.expect(scrollbar.thumb(3, 10, 3, 7) != null);
    try testing.expect(f.hits.at(29, 0).? == .scrollbar);
    // The cursor row is the pane's whether or not it has focus.
    try testing.expect(f.bgEql(3, 5, f.theme.cursor_line));
    // Narrow: no column, nothing off-screen.
    var g = try Fixture.init(7, 6);
    defer g.deinit();
    scroll = 0;
    draw(g.ui(), 0, g.full(), &scroll, .{ .title = "t", .rows = &rows, .total = 10, .cursor = 0, .current = null, .focused = true });
    try testing.expect(g.hits.at(6, 3) == null or g.hits.at(6, 3).? == .editor_cell);
    for (g.hits.items.items) |e| try testing.expect(g.full().intersect(e.rect).eql(e.rect));
}

test "a cell of air before the bar: the header, the hint and every row stop a cell short of it, a long name with the ellipsis before the air" {
    var f = try Fixture.init(30, 8);
    defer f.deinit();
    var scroll: usize = 0;
    var rows: [12]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .name = "a_symbol_name_that_is_long", .kind = "fn", .line = @intCast(i), .col = 0, .depth = 0 };
    draw(f.ui(), 0, f.full(), &scroll, .{ .title = "a-file-name-that-is-long.zig", .rows = &rows, .total = 12, .cursor = 0, .current = null, .focused = true });
    try f.expectRow(0, "  ⌥ a-file-name-that-is-lon… █");
    try f.expectRow(1, "  ⏎ / r / esc" ++ " " ** 16 ++ "█");
    try f.expectRow(3, "▶         fn a_symbol_name_… █");
    try f.expectRow(4, "          fn a_symbol_name_… █");
    try f.expectAirBeforeBar(1, 8, 29);
    try testing.expect(f.hits.at(28, 3).? == .editor_cell);
}
