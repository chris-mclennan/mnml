//! The `ai.apply` review pane's paint: a header naming the file and the
//! tally (`2 of 3 hunks accepted`), then the rows — a hunk header
//! `@@ -a,b +c,d @@  [✓ accept]` / `[  skip  ]` with the focused one on
//! the cursor line, and its lines with `+` / `-` / ` ` in the diff
//! colours (a skipped hunk's lines paint muted). Every row registers
//! `.script_hit{ pane, id = row }` so a click reaches the app.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const diff_view = @import("diff_view.zig");
const ids = @import("../core/ids.zig");
const ai_apply = @import("../app/ai_apply.zig");

const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const Props = struct {
    file: []const u8,
    hunks: []const ai_apply.Hunk,
    rows: []const ai_apply.Row,
    cursor: usize,
    focused: bool,
    /// The row the cursor hunk's header is on; scroll follows it.
    cursor_row: usize,
    lineText: *const fn (row: ai_apply.Row) []const u8,
};

pub const hint = "space toggle · enter apply · esc cancel";

pub fn draw(ui: Ui, pane: PaneId, area: Rect, scroll: *usize, p: Props) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    var n: usize = 0;
    for (p.hunks) |h| n += @intFromBool(h.accepted);
    const head = ui.fmt("ai.apply → {s}   {d} of {d} hunk{s} accepted   {s}", .{ p.file, n, p.hunks.len, if (p.hunks.len == 1) "" else "s", hint });
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(head, area.w), Theme.onBg(t.accent, t.bg.bg));
    if (area.h < 2) return;
    const body = area.splitTop(1).rest;
    if (p.rows.len == 0) {
        _ = ui.putStr(body.x + 2, body.y + 1, body.w -| 2, "The proposal matches the editor — nothing to apply.", Theme.onBg(t.muted, t.bg.bg));
        return;
    }
    const win = list_panel.scrollWindow(scroll, p.cursor_row, p.rows.len, body.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < p.rows.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        const row = p.rows[i];
        const hunk_idx: usize = row.hunkOf();
        const hunk = p.hunks[hunk_idx];
        const on_cursor = hunk_idx == p.cursor and p.focused;
        const base: Style = if (on_cursor and row == .header) Theme.onBg(t.fg, t.cursor_line.bg) else t.bg;
        if (on_cursor and row == .header) ui.fill(r, t.cursor_line);
        switch (row) {
            .header => {
                const badge: []const u8 = if (hunk.accepted) (if (ui.ascii) "[x accept]" else "[✓ accept]") else (if (ui.ascii) "[  skip  ]" else "[  skip  ]");
                const label = ui.fmt("{s}  {s}", .{ ui.fmt("@@ -{d},{d} +{d},{d} @@", .{ hunk.old_start + 1, hunk.old_len, hunk.new_start + 1, hunk.new_len }), badge });
                var s = Theme.onBg(if (hunk.accepted) t.info_fg else t.muted, base.bg);
                s.bold = on_cursor;
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(label, r.w), s);
            },
            .ctx, .del, .add => {
                const sign: []const u8 = switch (row) {
                    .add => "+",
                    .del => "-",
                    else => " ",
                };
                const style: Style = if (!hunk.accepted)
                    Theme.onBg(t.muted, base.bg)
                else switch (row) {
                    .add => diff_view.addStyle(t, base),
                    .del => diff_view.delStyle(t, base),
                    else => base,
                };
                _ = ui.putStr(r.x, r.y, 1, sign, style);
                _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(p.lineText(row), r.w -| 1), style);
            },
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn fakeLine(row: ai_apply.Row) []const u8 {
    return switch (row) {
        .header => "",
        .ctx => "same",
        .del => "gone",
        .add => "fresh",
    };
}

test "the review pane paints the tally, hunk badges, signed lines and one hit per row" {
    var f = try Fixture.init(90, 6);
    defer f.deinit();
    const hunks = [_]ai_apply.Hunk{
        .{ .old_start = 0, .old_len = 2, .new_start = 0, .new_len = 2 },
        .{ .old_start = 9, .old_len = 1, .new_start = 9, .new_len = 0, .accepted = false },
    };
    const rows = [_]ai_apply.Row{
        .{ .header = 0 },
        .{ .ctx = .{ .hunk = 0, .line = 0 } },
        .{ .del = .{ .hunk = 0, .line = 1 } },
        .{ .add = .{ .hunk = 0, .line = 1 } },
        .{ .header = 1 },
        .{ .del = .{ .hunk = 1, .line = 9 } },
    };
    var scroll: usize = 0;
    draw(f.ui(), 4, f.full(), &scroll, .{ .file = "src/a.zig", .hunks = &hunks, .rows = &rows, .cursor = 1, .focused = true, .cursor_row = 4, .lineText = &fakeLine });
    try f.expectRow(0, "ai.apply → src/a.zig   1 of 2 hunks accepted   space toggle · enter apply · esc cancel");
    try f.expectRow(1, "@@ -1,2 +1,2 @@  [✓ accept]");
    try f.expectRow(2, " same");
    try f.expectRow(3, "-gone");
    try f.expectRow(4, "+fresh");
    try f.expectRow(5, "@@ -10,1 +10,0 @@  [  skip  ]");
    try testing.expectEqual(@as(u32, 4), f.hits.at(3, 5).?.script_hit.id);
    try testing.expectEqual(@as(u32, 2), f.hits.at(0, 3).?.script_hit.id);
    try testing.expect(f.bgEql(2, 5, f.theme.cursor_line));
    try testing.expect(f.style(1, 5).bold);
    try testing.expect(f.fgEql(0, 3, diff_view.delStyle(&f.theme, f.theme.bg)));
}
