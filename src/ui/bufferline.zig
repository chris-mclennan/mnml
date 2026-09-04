//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! One row of buffer tabs.

const std = @import("std");
const Rect = @import("rect.zig");
const context = @import("context.zig");
const ids = @import("../core/ids.zig");
pub const Ui = context.Ui;

pub const Tab = struct { id: ids.PaneId, title: []const u8, dirty: bool, active: bool };

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab) void {
    if (area.isEmpty()) return;
    ui.canvas.fill(area, ui.theme.bufferline);
    var x: u16 = area.x;
    for (tabs, 0..) |t, i| {
        const label = std.fmt.allocPrint(ui.arena, " {s}{s} ", .{ t.title, if (t.dirty) " ●" else "" }) catch return;
        const w: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(label) catch label.len, area.right() -| x));
        if (w == 0) break;
        const r = Rect.init(x, area.y, w, 1);
        const style = if (t.active) ui.theme.tab_active else if (t.dirty) ui.theme.tab_dirty else ui.theme.tab_inactive;
        ui.canvas.fill(r, style);
        _ = ui.canvas.text(r, &.{.{ .text = label, .style = style }}, .{});
        ui.hits.add(ui.arena, r, .{ .tab = .{ .leaf = 0, .idx = @intCast(i) } }) catch {};
        x += w;
    }
}
