//! Which-key — the hint popup for a pending prefix: `Leader`, `Vim: g`,
//! `+split`. A bottom-anchored box listing every continuation as
//! `key → label` in as many columns as fit, column-major so the eye
//! reads down. Groups paint as `+label` in the accent, leaves in the
//! text color with the key in the warning yellow. Stateless: the app
//! hands in the entries for the current prefix each frame.
//!
//! Entries are sorted by key here so a keymap can register them in any
//! order and the popup still reads alphabetically. `→` is `->` under
//! `--ascii`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");

const Style = vaxis.Style;

pub const Entry = struct { key: []const u8, label: []const u8, is_group: bool = false };

pub const arrow = " → ";
pub const arrow_ascii = " -> ";
pub const hint_text = "  esc to cancel";
pub const min_cell_w: u16 = 12;

fn keyLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

pub fn draw(ui: Ui, area: Rect, title: []const u8, entries_in: []const Entry) void {
    const t = ui.theme;
    if (area.isEmpty()) return;
    // Sorted on the frame arena; OOM paints them in the caller's order.
    const entries: []const Entry = blk: {
        const copy = ui.arena.dupe(Entry, entries_in) catch break :blk entries_in;
        std.mem.sort(Entry, copy, {}, keyLess);
        break :blk copy;
    };

    const arr = if (ui.ascii) arrow_ascii else arrow;
    const arr_w = ui.width(arr);
    var key_w: u16 = 1;
    var label_w: u16 = 0;
    for (entries) |e| {
        key_w = @max(key_w, ui.width(e.key));
        label_w = @max(label_w, ui.width(e.label) + @as(u16, if (e.is_group) 1 else 0));
    }
    const cell_w = @max(min_cell_w, key_w + arr_w + label_w + 2);
    const avail_w = @max(area.w -| 4, cell_w);
    const cols: usize = @max(1, avail_w / cell_w);
    const n = entries.len;
    const rows_n: usize = @max(1, (n + cols - 1) / cols);
    const panel_h: u16 = @max(4, @min(@as(u16, @intCast(@min(rows_n, 1000))) + 3, area.h -| 2));
    const panel_w: u16 = @max(@min(area.w, 20), area.w -| 2);
    const inner = overlay.box(ui, area, panel_w, panel_h, title, .above_bottom);
    if (inner.isEmpty()) return;

    const actual_cols: usize = @max(1, inner.w / cell_w);
    const actual_rows: usize = @max(1, (n + actual_cols - 1) / actual_cols);
    const bg = t.overlay_bg.bg;
    var key_leaf = Theme.onBg(t.warn_fg, bg);
    key_leaf.bold = true;
    var key_group = Theme.onBg(t.accent, bg);
    key_group.bold = true;
    const label_leaf = Theme.onBg(t.fg, bg);
    const label_group = Theme.onBg(t.accent, bg);
    const arrow_style = Theme.onBg(t.muted, bg);

    var r: usize = 0;
    while (r < actual_rows and r < inner.h) : (r += 1) {
        const y = inner.y + @as(u16, @intCast(r));
        var c: usize = 0;
        while (c < actual_cols) : (c += 1) {
            const idx = c * actual_rows + r;
            if (idx >= n) continue;
            const e = entries[idx];
            var x = inner.x + @as(u16, @intCast(c)) * cell_w;
            const end = @min(x + cell_w, inner.right());
            // Keys right-align in their column so the arrows line up.
            const kw = ui.width(e.key);
            x += key_w -| kw;
            x += ui.putStr(x, y, end -| x, e.key, if (e.is_group) key_group else key_leaf);
            x += ui.putStr(x, y, end -| x, arr, arrow_style);
            if (e.is_group) x += ui.putStr(x, y, end -| x, "+", label_group);
            _ = ui.putStr(x, y, end -| x, ui.clipStr(e.label, end -| x), if (e.is_group) label_group else label_leaf);
        }
    }
    if (actual_rows < inner.h) {
        overlay.hint(ui, inner.row(@intCast(actual_rows)), hint_text);
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const leader = [_]Entry{
    .{ .key = "s", .label = "split", .is_group = true },
    .{ .key = "f", .label = "find", .is_group = true },
    .{ .key = "e", .label = "explorer" },
    .{ .key = "q", .label = "quit" },
};

test "entries sort by key, groups get a + and the accent, the box sits above the last row" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    draw(f.ui(), f.full(), "Leader", &leader);
    try f.expectContains(" Leader ");
    try f.expectContains("+split");
    try f.expectContains("+find");
    try f.expectContains("e → explorer");
    try f.expectContains("q → quit");
    try f.expectContains("esc to cancel");
    // 4 entries, cell 14 (1 + 3 + 8 + 2), 56 available → 4 columns, one
    // row; h = 4 sitting above the last row: box rows 7..10.
    try f.expectRow(11, "");
    try f.expectRow(6, "");
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(7, &buf), " ╭ Leader "));
    try testing.expect(std.mem.startsWith(u8, f.row(10, &buf), " ╰"));
    // Sorted: e, f, q, s left to right.
    const row8 = try testing.allocator.dupe(u8, f.row(8, &buf));
    defer testing.allocator.free(row8);
    const e_at = std.mem.indexOf(u8, row8, "e → explorer").?;
    const f_at = std.mem.indexOf(u8, row8, "f → +find").?;
    const q_at = std.mem.indexOf(u8, row8, "q → quit").?;
    try testing.expect(e_at < f_at and f_at < q_at);
    // The accent on a group's key, the yellow on a leaf's: cells 2 and 16.
    try testing.expect(f.fgEql(2, 8, f.theme.warn_fg));
    try testing.expect(f.fgEql(16, 8, f.theme.accent));
    try testing.expect(f.fgEql(20, 8, f.theme.accent)); // the '+'
    try testing.expect(f.bgEql(20, 8, f.theme.overlay_bg));
}

test "the gate's shape: a group then its leaves; ascii arrows; narrow screens" {
    var f = try Fixture.init(40, 8);
    defer f.deinit();
    var ui = f.ui();
    draw(ui, f.full(), "Leader", &leader);
    try f.expectContains("+split");
    try f.expectLacks("split right");
    const split = [_]Entry{ .{ .key = "l", .label = "split right" }, .{ .key = "j", .label = "split down" } };
    draw(ui, f.full(), "Leader s", &split);
    try f.expectContains("split right");
    try f.expectContains("split down");
    try f.expectContains("Leader s");
    ui.ascii = true;
    draw(ui, f.full(), "Vim: g", &split);
    try f.expectContains("j -> split down");
    try f.expectContains("+ Vim: g -");
    var g = try Fixture.init(12, 3);
    defer g.deinit();
    draw(g.ui(), g.full(), "Leader", &leader);
    draw(g.ui(), Rect.empty, "Leader", &leader);
    draw(g.ui(), g.full(), "Leader", &.{});
}

test "keys of different widths line their arrows up" {
    // 22 wide: one column, so the two rows can be compared.
    var f = try Fixture.init(22, 8);
    defer f.deinit();
    const mixed = [_]Entry{ .{ .key = "ctrl+w", .label = "window" }, .{ .key = "g", .label = "goto" } };
    draw(f.ui(), f.full(), "Keys", &mixed);
    var buf: [256]u8 = undefined;
    const a = std.mem.indexOf(u8, f.row(3, &buf), "→").?;
    const b = std.mem.indexOf(u8, f.row(4, &buf), "→").?;
    try testing.expectEqual(a, b);
    try f.expectContains("     g → goto");
    try f.expectContains("ctrl+w → window");
}
