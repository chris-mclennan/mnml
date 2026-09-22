//! The completion popup: a borderless list anchored just under the
//! cursor cell (above it when there is no room below), the selected row
//! banded, a dim kind tag and detail column, and one line of the
//! selected item's documentation as a footer. The app filters and sorts;
//! the view scrolls to keep the selection inside `max_rows`.
//!
//! Rows register `.overlay_item(i)` — a click accepts row `i` of the
//! slice passed in.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const editor_view = @import("editor_view.zig");

pub const Style = vaxis.Style;
pub const max_rows: usize = 10;

pub const Row = struct {
    label: []const u8,
    /// Painted dim right after the label (LSP `labelDetails.detail`).
    label_detail: []const u8 = "",
    kind: []const u8,
    /// Its own column before `detail` (LSP `labelDetails.description`:
    /// the module an auto-import comes from).
    description: []const u8 = "",
    detail: []const u8,
};

pub const Props = struct {
    rows: []const Row,
    selected: usize,
    /// The selected item's first documentation line.
    doc: ?[]const u8,
};

pub fn draw(ui: Ui, screen: Rect, cursor: ?editor_view.Cursor, scroll: *usize, p: Props) void {
    const t = ui.theme;
    const n = p.rows.len;
    if (n == 0 or screen.w < 14 or screen.h < 4) return;
    const rows = @min(n, max_rows);
    if (p.selected < scroll.*) scroll.* = p.selected;
    if (p.selected >= scroll.* + rows) scroll.* = p.selected + 1 - rows;
    scroll.* = @min(scroll.*, n - rows);
    var label_w: u16 = 1;
    var kind_w: u16 = 0;
    var desc_w: u16 = 0;
    var detail_w: u16 = 0;
    for (p.rows[scroll.* .. scroll.* + rows]) |r| {
        label_w = @max(label_w, ui.width(r.label) + ui.width(r.label_detail));
        kind_w = @max(kind_w, ui.width(r.kind));
        desc_w = @max(desc_w, ui.width(r.description));
        detail_w = @max(detail_w, ui.width(r.detail));
    }
    const doc_h: u16 = if (p.doc != null) 1 else 0;
    var w: u16 = 2 + label_w + (if (kind_w > 0) kind_w + 2 else 0) + (if (desc_w > 0) desc_w + 2 else 0) + (if (detail_w > 0) detail_w + 2 else 0);
    if (p.doc) |d| w = @max(w, ui.width(d) + 2);
    w = std.math.clamp(w, 14, screen.w -| 2);
    const h: u16 = @as(u16, @intCast(rows)) + doc_h;
    const c = cursor orelse editor_view.Cursor{ .x = screen.x + 2, .y = screen.y + 1 };
    const below = c.y +| 1;
    const y: u16 = if (below + h <= screen.bottom()) below else if (c.y >= screen.y + h) c.y - h else screen.y;
    const x: u16 = @max(@min(c.x, screen.right() -| w), screen.x);
    const box = Rect.init(x, y, w, h);
    ui.fill(box, t.overlay_bg);
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        const idx = scroll.* + i;
        const r = p.rows[idx];
        const rr = box.row(@intCast(i));
        const selected = idx == p.selected;
        const style: Style = if (selected) Theme.onBg(t.overlay_bg, t.cursor_line.bg) else t.overlay_bg;
        ui.fill(rr, style);
        var cx = rr.x + 1;
        cx += ui.putStr(cx, rr.y, rr.right() -| cx, ui.clipStr(r.label, rr.right() -| cx), Theme.withFg(style, t.fg.fg));
        if (r.label_detail.len > 0) cx += ui.putStr(cx, rr.y, rr.right() -| cx, ui.clipStr(r.label_detail, rr.right() -| cx), Theme.withFg(style, t.muted.fg));
        if (kind_w > 0) {
            const kx = rr.x + 1 + label_w + 2;
            _ = ui.putStr(kx, rr.y, rr.right() -| kx, r.kind, Theme.withFg(style, t.syntax.keyword.fg));
        }
        const desc_x = rr.x + 1 + label_w + 2 + (if (kind_w > 0) kind_w + 2 else 0);
        if (desc_w > 0) _ = ui.putStr(desc_x, rr.y, rr.right() -| desc_x, ui.clipStr(r.description, rr.right() -| desc_x), Theme.withFg(style, t.fg.fg));
        if (detail_w > 0) {
            const dx = desc_x + (if (desc_w > 0) desc_w + 2 else 0);
            _ = ui.putStr(dx, rr.y, rr.right() -| dx, ui.clipStr(r.detail, rr.right() -| dx), Theme.withFg(style, t.muted.fg));
        }
        ui.hit(rr, .{ .overlay_item = @intCast(idx) });
    }
    if (p.doc) |d| {
        const dr = box.row(@intCast(rows));
        _ = ui.putStr(dr.x + 1, dr.y, dr.w -| 1, ui.clipStr(d, dr.w -| 1), Theme.onBg(t.muted, t.overlay_bg.bg));
    }
}

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "anchored under the cursor, the selection banded, flipped above near the bottom" {
    var f = try Fixture.init(40, 8);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Row{ .{ .label = "forEach", .kind = "method", .detail = "" }, .{ .label = "filter", .kind = "method", .detail = "" } };
    draw(f.ui(), f.full(), .{ .x = 5, .y = 1 }, &scroll, .{ .rows = &rows, .selected = 1, .doc = "Calls fn" });
    try f.expectRow(2, "      forEach  method");
    try f.expectRow(3, "      filter   method");
    try f.expectRow(4, "      Calls fn");
    try testing.expect(f.bgEql(6, 3, f.theme.cursor_line));
    try testing.expectEqual(@as(u32, 0), f.hits.at(6, 2).?.overlay_item);
    var f2 = try Fixture.init(40, 6);
    defer f2.deinit();
    draw(f2.ui(), f2.full(), .{ .x = 5, .y = 5 }, &scroll, .{ .rows = &rows, .selected = 0, .doc = null });
    try f2.expectRow(3, "      forEach  method");
}

test "a label's details sit right after it, dim; a description gets a column before the detail" {
    var f = try Fixture.init(50, 8);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Row{
        .{ .label = "Pattern", .kind = "class", .description = "re", .detail = "Auto-import" },
        .{ .label = "Pattern", .kind = "class", .description = "typing", .detail = "Auto-import" },
        .{ .label = "run", .label_detail = "(main)", .kind = "fn", .detail = "def" },
    };
    draw(f.ui(), f.full(), .{ .x = 0, .y = 0 }, &scroll, .{ .rows = &rows, .selected = 0, .doc = null });
    try f.expectRow(1, " Pattern    class  re      Auto-import");
    try f.expectRow(2, " Pattern    class  typing  Auto-import");
    try f.expectRow(3, " run(main)  fn             def");
    try testing.expect(f.fgEql(4, 3, f.theme.muted));
}
