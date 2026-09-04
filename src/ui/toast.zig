//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! Toasts stacked bottom-right.

const std = @import("std");
const Rect = @import("rect.zig");
const context = @import("context.zig");
pub const Ui = context.Ui;

pub const Toast = struct { text: []const u8, level: enum { info, warn, err } };

pub fn draw(ui: Ui, area: Rect, toasts: []const Toast) void {
    if (area.isEmpty()) return;
    var y: u16 = area.bottom();
    var i = toasts.len;
    while (i > 0 and y > area.y) {
        i -= 1;
        y -= 1;
        const t = toasts[i];
        const text = std.fmt.allocPrint(ui.arena, " {s} ", .{t.text}) catch return;
        const w: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(text) catch text.len, area.w));
        const r = Rect.init(area.right() - w, y, w, 1);
        const style = switch (t.level) {
            .info => ui.theme.chip,
            .warn => ui.theme.warn_fg,
            .err => ui.theme.error_fg,
        };
        ui.canvas.fill(r, style);
        _ = ui.canvas.text(r, &.{.{ .text = text, .style = style }}, .{});
    }
}
