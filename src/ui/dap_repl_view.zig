//! The DAP REPL pane's paint: a header row (the pane's name, then the
//! filter line or a key hint), the history — two rows per entry, the
//! `▶ expr` row and its `= value` / `err:` / `(evaluating…)` row, plus
//! the expanded children of a composite — and the `(repl) > ` input row
//! at the bottom with the caret.
//!
//! The app hands in a flat, already-filtered list of entries built on
//! the frame arena; the view knows nothing about sessions. History rows
//! register `.script_hit{pane, id}` naming the entry so a click selects
//! it; the input row registers `.script_hit` with `input_hit`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;
pub const Style = vaxis.Style;
pub const Caret = text_field.Caret;

pub const prompt = "(repl) > ";
/// The `.script_hit` id of the input row.
pub const input_hit: u32 = std.math.maxInt(u32);
/// Follow the tail.
pub const scroll_tail: usize = std.math.maxInt(usize);

pub const Child = struct { name: []const u8, ty: ?[]const u8, value: []const u8 };

pub const Entry = struct {
    /// Index into the pane's history (what the hit names).
    index: u32,
    expression: []const u8,
    value: []const u8,
    ty: ?[]const u8,
    err: ?[]const u8,
    pending: bool,
    expandable: bool,
    expanded: bool,
    /// Present when expanded and fetched; null while fetching.
    children: ?[]const Child,
    selected: bool,
};

pub const Props = struct {
    entries: []const Entry,
    /// How many entries the history holds before the filter.
    total: usize,
    input: []const u8,
    caret: usize,
    filter: []const u8,
    filter_mode: bool,
    /// Index into `entries` the view should keep visible; `scroll_tail`
    /// pins the end.
    scroll: usize,
    focused: bool,
};

fn entryRows(e: Entry) usize {
    var n: usize = 2;
    if (e.expanded and e.expandable) n += if (e.children) |k| @max(k.len, 1) else 1;
    return n;
}

/// Returns the input caret when focused.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: Props) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.isEmpty()) return null;
    const bg = t.panel_bg.bg;
    // Header.
    var x = area.x;
    x += ui.putStr(x, area.y, area.w, " DAP REPL ", Theme.onBg(Theme.withFg(t.tab_active, t.accent.fg), bg));
    const hint: []const u8 = if (p.filter_mode)
        ui.fmt("  filter: {s}_ · Backspace · Enter applies · Esc clears", .{p.filter})
    else if (p.filter.len > 0)
        ui.fmt("  ({d}/{d} match \"{s}\")  Enter: eval · ↑↓: history · /: refilter · Esc clears filter", .{ p.entries.len, p.total, p.filter })
    else
        "  Enter: eval · ↑↓: history · Sh-↑↓: select row · o: expand · /: filter · Esc: back";
    const hint_style = Theme.onBg(if (p.filter_mode or p.filter.len > 0) t.warn_fg else t.muted, bg);
    _ = ui.putStr(x, area.y, area.right() -| x, ui.clipStr(hint, area.right() -| x), hint_style);
    if (area.h < 2) return null;
    // Input row.
    const input_row = area.row(area.h - 1);
    const pw = ui.putStr(input_row.x, input_row.y, input_row.w, prompt, Theme.onBg(t.warn_fg, bg));
    const field = Rect.init(input_row.x + pw, input_row.y, input_row.w -| pw, 1);
    const caret = text_field.draw(ui, field, p.input, p.caret, .{ .style = Theme.onBg(t.fg, bg), .focused = p.focused and !p.filter_mode });
    ui.hit(input_row, .{ .script_hit = .{ .pane = pane, .id = input_hit } });
    if (area.h < 3) return caret;
    // History.
    const body = Rect.init(area.x, area.y + 1, area.w, area.h - 2);
    if (p.total == 0) {
        _ = ui.putStr(body.x, body.y, body.w, ui.clipStr("  (no evaluations yet — type an expression below)", body.w), Theme.onBg(t.muted, bg));
        return caret;
    }
    if (p.entries.len == 0) {
        _ = ui.putStr(body.x, body.y, body.w, ui.clipStr(ui.fmt("  No matches for \"{s}\" — Esc clears", .{p.filter}), body.w), Theme.onBg(t.muted, bg));
        return caret;
    }
    // Which entry the walk starts at: from the tail, back until the
    // rows run out; or the pinned entry.
    var first: usize = 0;
    if (p.scroll == scroll_tail) {
        var budget: usize = body.h;
        var idx = p.entries.len;
        while (idx > 0) {
            const rows = entryRows(p.entries[idx - 1]);
            if (budget < rows) break;
            budget -= rows;
            idx -= 1;
        }
        first = idx;
    } else first = @min(p.scroll, p.entries.len - 1);
    var y: u16 = body.y;
    const bottom = body.bottom();
    for (p.entries[first..]) |e| {
        if (y >= bottom) break;
        const row_bg = if (e.selected) t.cursor_line.bg else bg;
        const r = Rect.init(body.x, y, body.w, 1);
        ui.fill(r, Theme.onBg(t.fg, row_bg));
        var cx = r.x;
        cx += ui.putStr(cx, y, r.w, if (e.selected) "● ▶ " else "  ▶ ", Theme.onBg(t.accent, row_bg));
        const chip: []const u8 = if (e.expandable) (if (e.expanded) "▾ " else "▸ ") else "  ";
        cx += ui.putStr(cx, y, r.right() -| cx, if (ui.ascii) (if (e.expandable) (if (e.expanded) "v " else "> ") else "  ") else chip, Theme.onBg(t.muted, row_bg));
        _ = ui.putStr(cx, y, r.right() -| cx, ui.clipStr(e.expression, r.right() -| cx), Theme.onBg(t.fg, row_bg));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = e.index } });
        y += 1;
        if (y >= bottom) break;
        const r2 = Rect.init(body.x, y, body.w, 1);
        ui.fill(r2, Theme.onBg(t.fg, row_bg));
        const line: []const u8, const style: Style = if (e.pending)
            .{ "    (evaluating…)", Theme.onBg(t.muted, row_bg) }
        else if (e.err) |err|
            .{ ui.fmt("    err: {s}", .{err}), Theme.onBg(t.error_fg, row_bg) }
        else if (e.ty) |ty|
            .{ ui.fmt("    = {s} : {s}", .{ e.value, ty }), Theme.onBg(t.info_fg, row_bg) }
        else
            .{ ui.fmt("    = {s}", .{e.value}), Theme.onBg(t.info_fg, row_bg) };
        _ = ui.putStr(r2.x, y, r2.w, ui.clipStr(line, r2.w), style);
        ui.hit(r2, .{ .script_hit = .{ .pane = pane, .id = e.index } });
        y += 1;
        if (e.expanded and e.expandable) {
            if (e.children) |kids| {
                for (kids) |k| {
                    if (y >= bottom) break;
                    const kl = if (k.ty) |ty| ui.fmt("      {s} : {s} = {s}", .{ k.name, ty, k.value }) else ui.fmt("      {s} = {s}", .{ k.name, k.value });
                    _ = ui.putStr(body.x, y, body.w, ui.clipStr(kl, body.w), Theme.onBg(t.fg, bg));
                    y += 1;
                }
            } else if (y < bottom) {
                _ = ui.putStr(body.x, y, body.w, "      (fetching children…)", Theme.onBg(t.muted, bg));
                y += 1;
            }
        }
    }
    return caret;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "header, two rows per entry, the input row with its caret, hits by entry" {
    var f = try Fixture.init(60, 8);
    defer f.deinit();
    const entries = [_]Entry{
        .{ .index = 0, .expression = "x + 1", .value = "", .ty = null, .err = "no DAP session (run dap.run first)", .pending = false, .expandable = false, .expanded = false, .children = null, .selected = false },
        .{ .index = 1, .expression = "self", .value = "Foo", .ty = "Foo", .err = null, .pending = false, .expandable = true, .expanded = true, .children = &.{.{ .name = "n", .ty = "i32", .value = "3" }}, .selected = true },
    };
    const caret = draw(f.ui(), 4, f.full(), .{ .entries = &entries, .total = 2, .input = "y", .caret = 1, .filter = "", .filter_mode = false, .scroll = scroll_tail, .focused = true });
    try f.expectContains(" DAP REPL ");
    try f.expectContains("  ▶   x + 1");
    try f.expectContains("    err: no DAP session (run dap.run first)");
    try f.expectContains("● ▶ ▾ self");
    try f.expectContains("    = Foo : Foo");
    try f.expectContains("      n : i32 = 3");
    try f.expectRow(7, "(repl) > y");
    try testing.expectEqual(@as(u16, 10), caret.?.x);
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 3).?.script_hit.id);
    try testing.expectEqual(input_hit, f.hits.at(3, 7).?.script_hit.id);
}

test "filter mode header and the no-matches row" {
    var f = try Fixture.init(70, 5);
    defer f.deinit();
    _ = draw(f.ui(), 0, f.full(), .{ .entries = &.{}, .total = 3, .input = "", .caret = 0, .filter = "alp", .filter_mode = true, .scroll = scroll_tail, .focused = true });
    try f.expectContains("filter: alp_");
    try f.expectContains("No matches for \"alp\"");
}
