//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The bottom statusline: mode chip, file, position.

const std = @import("std");
const Rect = @import("rect.zig");
const context = @import("context.zig");
pub const Ui = context.Ui;

pub const Info = struct {
    mode_label: ?[]const u8,
    mode_kind: enum { none, normal, insert, visual, replace, edit },
    file: ?[]const u8,
    dirty: bool,
    line: u32,
    col: u32,
    total_lines: u32,
    input_style: []const u8,
    selection_chars: ?usize = null,
    pending: ?[]const u8 = null,
    macro_recording: ?u8 = null,
    right: []const []const u8 = &.{},
};

/// Left: mode chip, file (+ `●` when dirty). Right: `" Ln {line}/{total} Col {col} "`.
pub fn draw(ui: Ui, area: Rect, info: Info) void {
    if (area.isEmpty()) return;
    ui.canvas.fill(area, ui.theme.statusline);
    var left: std.ArrayListUnmanaged(u8) = .empty;
    const a = ui.arena;
    if (info.mode_label) |m| left.print(a, " {s} ", .{m}) catch return;
    if (info.file) |f| left.print(a, " {s}{s} ", .{ f, if (info.dirty) " ●" else "" }) catch return;
    if (info.selection_chars) |n| left.print(a, " Sel {d} ", .{n}) catch return;
    if (info.macro_recording) |r| left.print(a, " ● rec @{c} ", .{r}) catch return;
    if (info.pending) |p| left.print(a, " {s} ", .{p}) catch return;
    var right: std.ArrayListUnmanaged(u8) = .empty;
    right.print(a, " Ln {d}/{d} Col {d} ", .{ info.line, info.total_lines, info.col }) catch return;
    for (info.right) |seg| right.print(a, " {s} ", .{seg}) catch return;
    right.print(a, " {s} ", .{info.input_style}) catch return;
    _ = ui.canvas.text(area, &.{.{ .text = left.items, .style = ui.theme.statusline }}, .{});
    const rw: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(right.items) catch right.items.len, area.w));
    const rr = area.rightCells(rw);
    _ = ui.canvas.text(rr, &.{.{ .text = right.items, .style = ui.theme.statusline }}, .{});
}
