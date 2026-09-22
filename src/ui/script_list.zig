//! The row of a script's list (`mnml.list{}`) — the pane form and the
//! rail-section form paint the same one, through the same `ListPanel`
//! every built-in section uses, so a script's section is TODOS' twin
//! rather than its lookalike.
//!
//! Two shapes. A **fold header** (`{ header = "…", count = n }`) paints
//! the expander glyph, the name in the text colour and the count muted
//! at the right edge — `ui/expander.zig`'s glyphs, so it folds like the
//! tree. An **item** paints an optional icon in the accent, the label,
//! an optional `state` word as a chip, and the detail muted and
//! right-aligned, clipped from the left so the tail survives (the
//! DIAGNOSTICS row's rule).

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const expander = @import("expander.zig");

/// One row as the panel paints it. Every slice is owned by the app (the
/// decoded copy of what the script's `rows()` answered).
pub const Row = struct {
    /// A fold header: `label` is its name, `count` what it holds.
    header: bool = false,
    label: []const u8 = "",
    detail: []const u8 = "",
    /// One glyph before the label, in the accent.
    icon: []const u8 = "",
    /// A short word in a chip after the label (`open`, `done`).
    state: []const u8 = "",
    count: u32 = 0,
    /// Header only: its items are hidden.
    collapsed: bool = false,
    /// The row's place in what `rows()` answered — what `on_enter` and
    /// `on_menu` are handed, so a fold does not shift the numbers.
    index: u32 = 0,
};

/// The least a label keeps before the detail gives way.
pub const min_label: u16 = 10;

pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    if (r.w == 0) return;
    var x = r.x;
    const end = r.right();
    if (row.header) {
        const glyph = expander.glyph(ui, !row.collapsed);
        x += ui.putStr(x, r.y, end -| x, glyph, Theme.withFg(base, t.muted.fg));
        x += ui.putStr(x, r.y, end -| x, " ", base);
        const count_text = ui.fmt(" {d}", .{row.count});
        const cw = ui.width(count_text);
        const room = (end -| x) -| cw;
        x += ui.putStr(x, r.y, room, row.label, Theme.onBg(t.fg, base.bg));
        _ = ui.putStrRight(end, r.y, cw, count_text, Theme.withFg(base, t.muted.fg));
        return;
    }
    if (row.icon.len > 0) {
        x += ui.putStr(x, r.y, end -| x, row.icon, Theme.withFg(base, t.accent.fg));
        x += ui.putStr(x, r.y, end -| x, " ", base);
    }
    // The detail takes what is left past a readable label, clipped from
    // the left so its tail (the line number, the file) survives.
    var detail = row.detail;
    const state_w: u16 = if (row.state.len > 0) ui.width(row.state) + 3 else 0;
    var avail = end -| x;
    var detail_w = ui.widthUpTo(detail, avail);
    const budget = avail -| (min_label + state_w + 1);
    if (detail_w > budget) {
        if (budget < 4) {
            detail = "";
            detail_w = 0;
        } else {
            const ell = ui.ellipsisText();
            var start: usize = 0;
            while (start < detail.len and ui.width(detail[start..]) > budget -| ui.width(ell)) start += std.unicode.utf8ByteSequenceLength(detail[start]) catch 1;
            detail = ui.fmt("{s}{s}", .{ ell, detail[start..] });
            detail_w = ui.width(detail);
        }
    }
    const detail_cost: u16 = if (detail_w > 0) detail_w + 1 else 0;
    avail = (end -| x) -| (detail_cost + state_w);
    x += ui.putStr(x, r.y, avail, row.label, Theme.onBg(t.fg, base.bg));
    if (row.state.len > 0 and end -| x > state_w) {
        x += ui.putStr(x, r.y, end -| x, " ", base);
        x += ui.putStr(x, r.y, end -| x, ui.fmt(" {s} ", .{row.state}), Theme.onBg(t.chip, base.bg));
    }
    if (detail_w > 0) _ = ui.putStrRight(end, r.y, detail_w, detail, Theme.withFg(base, t.muted.fg));
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_fixture = @import("test_fixture.zig");

test "rows: a fold header carries the expander and its count; an item carries the icon, the state chip and a detail clipped from the left" {
    var f = try test_fixture.init(30, 4);
    defer f.deinit();
    paintRow(f.ui(), Rect.init(0, 0, 30, 1), .{ .header = true, .label = "src/app.zig", .count = 3 }, false);
    paintRow(f.ui(), Rect.init(0, 1, 30, 1), .{ .header = true, .label = "src/ui.zig", .count = 1, .collapsed = true }, false);
    paintRow(f.ui(), Rect.init(0, 2, 30, 1), .{ .label = "fix the clamp", .detail = "src/ui/picker.zig:212", .icon = "+" }, true);
    paintRow(f.ui(), Rect.init(0, 3, 30, 1), .{ .label = "ship it", .state = "open", .detail = "x" }, false);
    try f.expectContains("src/app.zig");
    try f.expectContains(" 3");
    // The label keeps its ten cells; the detail takes the rest.
    try f.expectContains("+ fix the cl");
    // The detail lost its head, not its tail.
    try f.expectContains("\u{2026}");
    try f.expectContains("picker.zig:212");
    try f.expectContains(" open ");
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(0, &buf), expander.glyph(f.ui(), true)));
    try testing.expect(std.mem.startsWith(u8, f.row(1, &buf), expander.glyph(f.ui(), false)));
}

test "at the panel's 26 cells with the bar: every row's detail stays a cell short of the scrollbar" {
    var f = try test_fixture.init(26, 9);
    defer f.deinit();
    const Panel = list_panel.ListPanel(Row);
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    var rows: [12]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = if (i % 3 == 0)
        .{ .header = true, .label = "a/rather/long/path.zig", .count = @intCast(i) }
    else
        .{ .label = "a task with a long name", .detail = "src/app/dispatch.zig:2955" };
    _ = Panel.draw(&st, f.ui(), f.full(), .{
        .panel = .todos,
        .label = "SCRIPT",
        .rows = &rows,
        .paintRow = paintRow,
        .empty = .{ .message = "", .hint = "" },
    });
    try f.expectAirBeforeBar(2, 9, 25);
}
