//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The unsaved-changes / yes-no box.

const std = @import("std");
const Rect = @import("rect.zig");
const context = @import("context.zig");
const key_mod = @import("../core/key.zig");
pub const Key = key_mod.Key;
pub const Ui = context.Ui;

pub const Confirm = struct {
    pub const Choice = struct { key: u8, label: []const u8 };
    pub const State = struct { title: []const u8, message: []const u8, choices: []const Choice, selected: usize = 0 };
    pub const Outcome = union(enum) { consumed, cancel, choose: usize };

    pub fn handleKey(s: *State, key: Key) Outcome {
        switch (key.code) {
            .esc => return .cancel,
            .enter => return .{ .choose = s.selected },
            .left, .up => {
                if (s.selected > 0) s.selected -= 1;
                return .consumed;
            },
            .right, .down, .tab => {
                if (s.selected + 1 < s.choices.len) s.selected += 1;
                return .consumed;
            },
            .char => |c| {
                if (key.mods.ctrl or key.mods.alt) return .consumed;
                for (s.choices, 0..) |ch, i| {
                    if (c < 128 and std.ascii.toLower(@intCast(c)) == std.ascii.toLower(ch.key)) return .{ .choose = i };
                }
                return .consumed;
            },
            else => return .consumed,
        }
    }

    pub fn draw(ui: Ui, area: Rect, s: *const State) void {
        const w: u16 = @min(area.w -| 4, 64);
        const h: u16 = 5;
        if (w < 10 or area.h < h) return;
        const box = Rect.init(area.x + (area.w - w) / 2, area.y + (area.h -| h) / 3, w, h);
        ui.canvas.fill(box, ui.theme.overlay_bg);
        const inner = ui.canvas.border(box, .rounded, ui.theme.overlay_border, null);
        _ = ui.canvas.text(inner.row(0), &.{.{ .text = s.title, .style = ui.theme.overlay_title }}, .{});
        _ = ui.canvas.text(inner.row(1), &.{.{ .text = s.message, .style = ui.theme.overlay_bg }}, .{});
        var x: u16 = inner.x + 2;
        for (s.choices, 0..) |c, i| {
            const label = std.fmt.allocPrint(ui.arena, " [{c}] {s} ", .{ c.key, c.label }) catch return;
            const r = Rect.init(x, inner.y + 2, @intCast(@min(label.len, inner.right() -| x)), 1);
            const style = if (i == s.selected) ui.theme.chip_active else ui.theme.chip;
            _ = ui.canvas.text(r, &.{.{ .text = label, .style = style }}, .{});
            ui.hits.add(ui.arena, r, .{ .overlay_item = @intCast(i) }) catch {};
            x += r.w + 1;
        }
    }
};

test "confirm: letter, arrows + enter, esc" {
    var s: Confirm.State = .{ .title = "Unsaved changes", .message = "x", .choices = &.{ .{ .key = 's', .label = "Save" }, .{ .key = 'd', .label = "Discard" }, .{ .key = 'c', .label = "Cancel" } } };
    try std.testing.expectEqual(@as(usize, 1), Confirm.handleKey(&s, Key.char('d')).choose);
    try std.testing.expect(Confirm.handleKey(&s, Key.named(.right)) == .consumed);
    try std.testing.expectEqual(@as(usize, 1), Confirm.handleKey(&s, Key.named(.enter)).choose);
    try std.testing.expect(Confirm.handleKey(&s, Key.named(.esc)) == .cancel);
}
