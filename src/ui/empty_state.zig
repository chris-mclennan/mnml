//! Empty state — what a panel says when it has nothing to list: "No
//! todos yet" / "No matches — Esc clears", plus an optional dim hint on
//! the row below ("Stored under .mnml/notes/*.md"). One voice for the
//! whole family so tone and spacing never drift between panels.
//!
//! Row 0: two cells of pad, then the message in `theme.muted`. Row 1
//! (when a hint is given): the same pad, the hint dimmed. A message
//! that does not fit is clipped with the terminal's ellipsis; below
//! six usable cells it is dropped — an ellipsis alone teaches nothing.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Style = vaxis.Style;

pub const EmptyState = struct {
    message: []const u8,
    hint: ?[]const u8 = null,
};

const pad: u16 = 2;
const min_usable: u16 = 6;

/// Paints the message (and hint) at the top of `area` on `bg`. Returns
/// the rows used so the caller can keep composing below.
pub fn draw(ui: Ui, area: Rect, e: EmptyState, bg: Style) u16 {
    if (area.isEmpty()) return 0;
    const t = ui.theme;
    const usable = area.w -| pad;
    if (usable < min_usable) return 0;
    var rows: u16 = 0;
    const msg_style = Theme.onBg(t.muted, bg.bg);
    _ = ui.putStr(area.x + pad, area.y, usable, ui.clipStr(e.message, usable), msg_style);
    rows += 1;
    if (e.hint) |h| {
        if (rows < area.h) {
            var hint_style = msg_style;
            hint_style.dim = true;
            _ = ui.putStr(area.x + pad, area.y + rows, usable, ui.clipStr(h, usable), hint_style);
            rows += 1;
        }
    }
    return rows;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "message and hint on two padded rows" {
    var f = try Fixture.init(40, 3);
    defer f.deinit();
    const ui = f.ui();
    const n = draw(ui, f.full(), .{ .message = "No notes yet", .hint = "Stored under .mnml/notes/*.md" }, f.theme.panel_bg);
    try testing.expectEqual(@as(u16, 2), n);
    try f.expectRows(&.{ "  No notes yet", "  Stored under .mnml/notes/*.md", "" });
    try testing.expect(f.fgEql(2, 0, f.theme.muted));
    try testing.expect(f.bgEql(2, 0, f.theme.panel_bg));
    try testing.expect(f.style(2, 1).dim);
    try testing.expect(!f.style(2, 0).dim);
    try testing.expectEqual(@as(u16, 1), draw(ui, f.full(), .{ .message = "No todos" }, f.theme.panel_bg));
}

test "a hint has no room on a one-row area; a narrow area clips or drops" {
    var f = try Fixture.init(12, 1);
    defer f.deinit();
    var ui = f.ui();
    try testing.expectEqual(@as(u16, 1), draw(ui, f.full(), .{ .message = "No findings match", .hint = "x" }, f.theme.panel_bg));
    try f.expectRow(0, "  No findin…");
    ui.ascii = true;
    _ = draw(ui, f.full(), .{ .message = "No findings match" }, f.theme.panel_bg);
    try f.expectRow(0, "  No find...");
    var g = try Fixture.init(7, 1);
    defer g.deinit();
    try testing.expectEqual(@as(u16, 0), draw(g.ui(), g.full(), .{ .message = "No findings" }, g.theme.panel_bg));
    try g.expectRow(0, "");
    try testing.expectEqual(@as(u16, 0), draw(g.ui(), Rect.empty, .{ .message = "x" }, g.theme.panel_bg));
}
