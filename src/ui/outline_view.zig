//! The outline pane's paint: a header naming the file and the symbol
//! count, a key hint, then one row per symbol — the kind right-aligned
//! in its own column, the name indented by nesting depth, the line
//! number after it. The pane's cursor row carries `▶`; the symbol the
//! source cursor sits in is highlighted so the list follows you.
//!
//! Every row registers an `.editor_cell{pane, line, col}` naming the
//! symbol's position in the SOURCE — a click is a jump, and the app
//! routes it by the pane's kind.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
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
    rows: []const Row,
    /// The pane's own cursor.
    cursor: usize,
    /// The row the source cursor is inside, if any.
    current: ?usize,
    focused: bool,
};

/// Rows the header takes before the list starts.
pub const header_rows: u16 = 3;
const kind_w: u16 = 9;

pub fn draw(ui: Ui, pane: PaneId, area: Rect, scroll: *usize, p: Props) void {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.isEmpty()) return;
    const bg = t.panel_bg.bg;
    // Header.
    const glyph: []const u8 = if (ui.ascii) "outline" else "⌥";
    var x = area.x + 2;
    x += ui.putStr(x, area.y, area.right() -| x, glyph, Theme.onBg(t.syntax.keyword, bg));
    x += 1;
    x += ui.putStr(x, area.y, area.right() -| x, ui.clipStr(p.title, area.right() -| x), Theme.onBg(Theme.withFg(t.tab_active, t.fg.fg), bg));
    const count = ui.fmt("   {d} symbol{s}", .{ p.rows.len, if (p.rows.len == 1) "" else "s" });
    _ = ui.putStr(x, area.y, area.right() -| x, count, Theme.onBg(t.muted, bg));
    if (area.h > 1) {
        const hint: []const u8 = if (ui.ascii) "  enter jump - r refresh - esc back" else "  ⏎ jump · r refresh · esc back";
        _ = ui.putStr(area.x, area.y + 1, area.w, ui.clipStr(hint, area.w), Theme.onBg(t.muted, bg));
    }
    if (area.h <= header_rows) return;
    const list = Rect.init(area.x, area.y + header_rows, area.w, area.h - header_rows);
    const win = list_panel.scrollWindow(scroll, p.cursor, p.rows.len, list.h);
    const cols = list.splitRight(if (win.needs_bar and list.w > 8) 1 else 0);
    const body = cols.left;
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const row = p.rows[idx];
        const y = body.y + @as(u16, @intCast(i));
        const r = Rect.init(body.x, y, body.w, 1);
        const selected = idx == p.cursor and p.focused;
        const style: Style = if (selected) Theme.onBg(t.panel_bg, t.cursor_line.bg) else if (p.current == idx) Theme.onBg(t.panel_bg, t.selection.bg) else t.panel_bg;
        ui.fill(r, style);
        if (idx == p.cursor) _ = ui.putStr(r.x, y, 1, if (ui.ascii) ">" else "▶", Theme.withFg(style, t.accent.fg));
        // Kind, right-aligned in its column.
        const kind_right = r.x + 1 + kind_w;
        _ = ui.putStrRight(kind_right, y, kind_w, row.kind, Theme.withFg(style, t.syntax.keyword.fg));
        var nx = kind_right + 1 + @as(u16, row.depth) * 2;
        const label = ui.fmt("{s}:{d}", .{ row.name, row.line + 1 });
        const avail = r.right() -| nx;
        const name_w = ui.width(row.name);
        nx += ui.putStr(nx, y, avail, ui.clipStr(label, avail), Theme.withFg(style, t.fg.fg));
        // The `:line` tail in muted — repainted over the label's end.
        if (name_w < avail) {
            const tail = ui.fmt(":{d}", .{row.line + 1});
            _ = ui.putStr(kind_right + 1 + @as(u16, row.depth) * 2 + name_w, y, avail -| name_w, tail, Theme.withFg(style, t.muted.fg));
        }
        ui.hit(r, .{ .editor_cell = .{ .pane = pane, .line = row.line, .col = row.col } });
    }
    if (win.needs_bar and list.w > 8) scrollbar.drawVertical(ui, cols.rest, .{ .pane = pane }, p.rows.len, list.h, scroll.*);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "header, kinds right-aligned, depth indents, the cursor row and hits that name the source line" {
    var f = try Fixture.init(44, 8);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Row{
        .{ .name = "alpha", .kind = "fn", .line = 0, .col = 3, .depth = 0 },
        .{ .name = "Gamma", .kind = "struct", .line = 8, .col = 7, .depth = 0 },
        .{ .name = "x", .kind = "field", .line = 9, .col = 4, .depth = 1 },
    };
    draw(f.ui(), 2, f.full(), &scroll, .{ .title = "code.rs", .rows = &rows, .cursor = 1, .current = 2, .focused = true });
    try f.expectRow(0, "  ⌥ code.rs   3 symbols");
    try f.expectRow(3, "        fn alpha:1");
    try f.expectRow(4, "▶   struct Gamma:9");
    try f.expectRow(5, "     field   x:10");
    try testing.expectEqual(@as(u32, 8), f.hits.at(5, 4).?.editor_cell.line);
    try testing.expectEqual(@as(u32, 7), f.hits.at(5, 4).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 2), f.hits.at(5, 4).?.editor_cell.pane);
    try testing.expect(f.bgEql(3, 4, f.theme.cursor_line));
    try testing.expect(f.bgEql(3, 5, f.theme.selection));
}

test "a 100k-char symbol name paints clipped without overflowing the cell sum" {
    var f = try Fixture.init(44, 5);
    defer f.deinit();
    var scroll: usize = 0;
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'n');
    const rows = [_]Row{.{ .name = long, .kind = "fn", .line = 0, .col = 0, .depth = 0 }};
    draw(f.ui(), 2, f.full(), &scroll, .{ .title = long, .rows = &rows, .cursor = 0, .current = null, .focused = true });
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(0, &buf), "nnnn") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(3, &buf), "fn nnnn") != null);
    try testing.expect(std.mem.endsWith(u8, f.row(3, &buf), "…"));
}

test "the list scrolls to keep the cursor visible and paints a bar" {
    var f = try Fixture.init(30, 6);
    defer f.deinit();
    var scroll: usize = 0;
    var rows: [10]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .name = "s", .kind = "fn", .line = @intCast(i), .col = 0, .depth = 0 };
    draw(f.ui(), 0, f.full(), &scroll, .{ .title = "t", .rows = &rows, .cursor = 9, .current = null, .focused = false });
    try testing.expectEqual(@as(usize, 7), scroll);
    var buf: [64]u8 = undefined;
    const last = f.row(5, &buf);
    try testing.expect(std.mem.startsWith(u8, last, "▶       fn s:10"));
    try testing.expect(std.mem.endsWith(u8, last, "█"));
    try testing.expect(f.hits.at(29, 5).? == .scrollbar);
}
