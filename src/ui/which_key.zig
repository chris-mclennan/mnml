//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The which-key hint popup: a title and the continuations under a prefix.

const std = @import("std");
const Rect = @import("rect.zig");
const context = @import("context.zig");
pub const Ui = context.Ui;

pub const Entry = struct { key: []const u8, label: []const u8, is_group: bool = false };

pub fn draw(ui: Ui, area: Rect, title: []const u8, entries: []const Entry) void {
    const col_w: u16 = 26;
    const cols: u16 = @max(1, area.w / col_w);
    const rows: u16 = @intCast((entries.len + cols - 1) / cols);
    const h: u16 = @min(area.h, rows + 3);
    if (h < 3) return;
    const box = Rect.init(area.x, area.bottom() - h, area.w, h);
    ui.canvas.fill(box, ui.theme.overlay_bg);
    const inner = ui.canvas.border(box, .rounded, ui.theme.overlay_border, null);
    _ = ui.canvas.text(inner.row(0), &.{.{ .text = title, .style = ui.theme.overlay_title }}, .{});
    for (entries, 0..) |e, i| {
        const r: u16 = @intCast(i / cols);
        const c: u16 = @intCast(i % cols);
        if (r + 1 >= inner.h) break;
        const cell = Rect.init(inner.x + c * col_w, inner.y + 1 + r, @min(col_w, inner.right() -| (inner.x + c * col_w)), 1);
        const line = std.fmt.allocPrint(ui.arena, "{s} → {s}", .{ e.key, e.label }) catch return;
        _ = ui.canvas.text(cell, &.{.{ .text = line, .style = if (e.is_group) ui.theme.accent else ui.theme.overlay_bg }}, .{});
        ui.hits.add(ui.arena, cell, .{ .overlay_item = @intCast(i) }) catch {};
    }
}
