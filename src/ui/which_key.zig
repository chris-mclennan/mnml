//! Which-key — the hint popup for a pending prefix: `<leader>`,
//! `<leader>f  +find (7)`, `Vim: g`. A square box two cells narrower
//! than the screen, sitting just above the statusline, listing every
//! continuation as `glyph key → label` in as many columns as fit (a
//! cell is the widest label plus six, plus the glyph column when any
//! row carries one), column-major so the eye reads down. Groups paint
//! in the accent — their labels carry the `+` and their chord count —
//! leaves in the text color with the key in the warning yellow and the
//! glyph dimmed; `  esc to cancel` closes the list. Stateless: the app
//! hands in the entries for the current prefix each frame.
//!
//! The glyph column is the reference plugin's look, which the reference
//! editor's own popup does not have (`docs/PARITY.md`, the which-key
//! row): `ui/whichkey_glyph.zig` is the table and `app/render.zig`
//! resolves a row's face before handing the entry over, so a popup with
//! nothing to show (the vim operator menu) pays no column for it.
//!
//! Entries are sorted by key here so a keymap can register them in any
//! order and the popup still reads alphabetically — which is why a row
//! carries the caller's own `id` for the click target rather than its
//! painted position. `→` is `->` under `--ascii`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");

const Style = vaxis.Style;

pub const Entry = struct {
    key: []const u8,
    label: []const u8,
    is_group: bool = false,
    /// The row's face, already resolved for the ui's glyph mode (one
    /// cell, or its `--ascii` twin). Empty on every row means no glyph
    /// column at all — the vim operator popup keeps its old width.
    glyph: []const u8 = "",
    /// The caller's index for this row, registered as `.overlay_item`
    /// so a click lands on the row the CALLER knows — the popup sorts
    /// its entries, so the painted order is not the caller's.
    id: ?u32 = null,
};

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
    var glyph_w: u16 = 0;
    for (entries) |e| {
        key_w = @max(key_w, ui.width(e.key));
        label_w = @max(label_w, ui.width(e.label));
        // One glyph and one cell of air, and every row in the popup pays
        // for it so the keys stay in one column.
        if (e.glyph.len > 0) glyph_w = @max(glyph_w, ui.width(e.glyph) + 1);
    }
    var cell_w = @max(min_cell_w + glyph_w, glyph_w + key_w + arr_w + label_w + 2);
    const n = entries.len;
    // More rows than the box can hold at the natural width: more,
    // narrower columns with the labels clipped, never a row cut off the
    // bottom unseen. The box keeps its frame, the hint and the rows it
    // leaves clear of the statusline (`area.h - 5` rows of entries).
    const max_rows: usize = @max(1, @as(usize, area.h -| 5));
    const natural_cols: usize = @max(1, @max(area.w -| 4, cell_w) / cell_w);
    if ((n + natural_cols - 1) / natural_cols > max_rows) {
        const need_cols = (n + max_rows - 1) / max_rows;
        const floor_w: u16 = glyph_w + key_w + arr_w + 6;
        const fit: u16 = @intCast(@min(@as(usize, cell_w), (area.w -| 4) / need_cols));
        cell_w = @max(floor_w, fit);
    }
    const avail_w = @max(area.w -| 4, cell_w);
    const cols: usize = @max(1, avail_w / cell_w);
    const rows_n: usize = @max(1, (n + cols - 1) / cols);
    const panel_h: u16 = @max(4, @min(@as(u16, @intCast(@min(rows_n, 1000))) + 3, area.h -| 2));
    const panel_w: u16 = @max(@min(area.w, 20), area.w -| 2);
    const inner = overlay.boxLook(ui, area, panel_w, panel_h, title, .above_bottom, .menu);
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
    // A group wears its face in the accent, a leaf the same face dimmed
    // — the row still says which group the chord belongs to.
    const glyph_group = Theme.onBg(t.accent, bg);
    const glyph_leaf = Theme.onBg(t.muted, bg);

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
            if (glyph_w > 0) {
                if (e.glyph.len > 0) _ = ui.putStr(x, y, end -| x, e.glyph, if (e.is_group) glyph_group else glyph_leaf);
                x += glyph_w;
            }
            // Keys right-align in their column so the arrows line up.
            const kw = ui.width(e.key);
            x += key_w -| kw;
            x += ui.putStr(x, y, end -| x, e.key, if (e.is_group) key_group else key_leaf);
            x += ui.putStr(x, y, end -| x, arr, arrow_style);
            _ = ui.putStr(x, y, end -| x, ui.clipStr(e.label, end -| x), if (e.is_group) label_group else label_leaf);
            // The whole cell is the target, not just the painted text.
            if (e.id) |id| ui.hit(Rect.init(inner.x + @as(u16, @intCast(c)) * cell_w, y, end -| (inner.x + @as(u16, @intCast(c)) * cell_w), 1), .{ .overlay_item = id });
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
    .{ .key = "s", .label = "+split", .is_group = true },
    .{ .key = "f", .label = "+find", .is_group = true },
    .{ .key = "e", .label = "explorer" },
    .{ .key = "q", .label = "quit" },
};

test "entries sort by key, groups get a + and the accent, the box sits above the last row" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    draw(f.ui(), f.full(), "<leader>", &leader);
    try f.expectContains(" <leader> ");
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
    try testing.expect(std.mem.startsWith(u8, f.row(7, &buf), " ┌ <leader> "));
    try testing.expect(std.mem.startsWith(u8, f.row(10, &buf), " └"));
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
    draw(ui, f.full(), "<leader> s", &split);
    try f.expectContains("split right");
    try f.expectContains("split down");
    try f.expectContains("<leader> s");
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

test "the glyph column: a cell per row, the keys still in one column, and no column at all without one" {
    // The faces come from the table, not from a literal here — a row
    // painted by this test is a row the popup really paints.
    const wkg = @import("whichkey_glyph.zig");
    const g_find = wkg.forGroup("+find").glyph;
    const g_split = wkg.forGroup("+split").glyph;
    const g_none = wkg.neutral.glyph;
    // 60 wide with the column: cell 18 (2 + 1 + 3 + 10 + 2), 56
    // available → 3 columns on one row.
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    const iconed = [_]Entry{
        .{ .key = "s", .label = "+split (2)", .is_group = true, .glyph = g_split },
        .{ .key = "f", .label = "+find (7)", .is_group = true, .glyph = g_find },
        .{ .key = "e", .label = "explorer", .glyph = g_none },
    };
    draw(f.ui(), f.full(), "<leader>", &iconed);
    var buf: [256]u8 = undefined;
    var c1: [64]u8 = undefined;
    var c2: [64]u8 = undefined;
    var c3: [64]u8 = undefined;
    const row = f.row(8, &buf);
    // Sorted e, f, s left to right, each behind its own face.
    const e_at = std.mem.indexOf(u8, row, try cell(g_none, "e", "explorer", &c1)) orelse return error.NoLeafRow;
    const f_at = std.mem.indexOf(u8, row, try cell(g_find, "f", "+find (7)", &c2)) orelse return error.NoFindRow;
    const s_at = std.mem.indexOf(u8, row, try cell(g_split, "s", "+split (2)", &c3)) orelse return error.NoSplitRow;
    try testing.expect(e_at < f_at and f_at < s_at);
    // The group's face paints in the accent, the leaf's in the muted
    // colour — same glyph, dimmer, when the leaf is inside a group.
    try testing.expect(f.fgEql(2, 8, f.theme.muted)); // `e`, a leaf
    try testing.expect(f.fgEql(20, 8, f.theme.accent)); // `f`, a group
    // Under --ascii the twins are one cell too, so nothing moves.
    var a = try Fixture.init(60, 12);
    defer a.deinit();
    var ui = a.ui();
    ui.ascii = true;
    const twins = [_]Entry{
        .{ .key = "s", .label = "+split (2)", .is_group = true, .glyph = wkg.forGroup("+split").fallback },
        .{ .key = "f", .label = "+find (7)", .is_group = true, .glyph = wkg.forGroup("+find").fallback },
        .{ .key = "e", .label = "explorer", .glyph = wkg.neutral.fallback },
    };
    draw(ui, a.full(), "<leader>", &twins);
    try a.expectContains("f f -> +find (7)");
    try a.expectContains(". e -> explorer");
    // No glyph on any row: the column is not reserved, so the vim
    // operator popup keeps the width it had — cell 14, all four of the
    // leader fixture's entries on the one row.
    var n = try Fixture.init(60, 12);
    defer n.deinit();
    draw(n.ui(), n.full(), "Vim: g", &leader);
    const plain = n.row(8, &buf);
    for ([_][]const u8{ "e → explorer", "f → +find", "q → quit", "s → +split" }) |want| {
        try testing.expect(std.mem.indexOf(u8, plain, want) != null);
    }
}

/// `glyph key → label`, the way a row reads on screen.
fn cell(glyph: []const u8, key: []const u8, label: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} → {s}", .{ glyph, key, label });
}

test "more rows than the box holds: narrower columns with clipped labels, every key still painted" {
    // The standard profile's Ctrl+K popup: thirty-odd chords with long
    // labels on a short screen. At the natural width they took two
    // columns of nineteen rows and the last keys fell off the bottom.
    var f = try Fixture.init(120, 20);
    defer f.deinit();
    var keys: [38][2]u8 = undefined;
    var many: [38]Entry = undefined;
    for (&many, 0..) |*e, i| {
        keys[i] = .{ 'a' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)) };
        e.* = .{ .key = &keys[i], .label = "a label long enough to want a column of its own" };
    }
    draw(f.ui(), f.full(), "Ctrl+K", &many);
    try f.expectContains("┌ Ctrl+K ");
    try f.expectContains("a0 → ");
    try f.expectContains("d7 → ");
    try f.expectContains("esc to cancel");
    // A list that fits keeps its natural width: the label is whole.
    draw(f.ui(), f.full(), "Ctrl+K", many[0..4]);
    try f.expectContains("a label long enough to want a column of its own");
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
