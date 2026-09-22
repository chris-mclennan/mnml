//! The ZON view pane's painter (`app/zon_pane.zig` owns the state).
//!
//! Row 0 is the breadcrumb of the focused field (`config.zon › ui ›
//! theme`, each crumb a jump), row 1 the shared filter pill, then one
//! row per visible field in the settings overlay's idiom — `▸` marks
//! the focus, `[brackets]` the current choice, a trailing `*` a value
//! changed since the file was opened — and a hint row at the bottom.
//! A field's widget decides its value cell: `[true] / false` for a
//! bool, `[vim] / standard` for an enum (`[x] ‹ 2/9 ›` past six
//! choices), `‹ [4] ›` for a number, the quoted text for a string,
//! `.{ 3 fields }` for a container, `null  set…` for an optional.
//! Every cell registers the hit that acts on it in the statement that
//! paints it (D6): the row, an option, an arrow, the value, `+`, `x`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const filter_input = @import("filter_input.zig");
const scrollbar = @import("scrollbar.zig");
const overlay = @import("overlay.zig");
const expander = @import("expander.zig");
const ids = @import("../core/ids.zig");
const zon_pane = @import("../app/zon_pane.zig");
const ZonPane = zon_pane.ZonPane;
const Hit = zon_pane.Hit;

const Style = vaxis.Style;
pub const PaneId = ids.PaneId;
pub const Caret = text_field.Caret;

pub const hint_text = "⏎ edit · ←→ adjust · + add · x remove · J/K move · n null · / filter · e source · ^S save · esc revert";
pub const max_listed_options: usize = 6;

/// Paints the pane; returns the caret when a field or the filter has it.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, z: *ZonPane, focused: bool) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return null;
    var rest = area;

    // ── row 0: the breadcrumb ──
    const crumb_row = rest.splitTop(1);
    drawCrumbs(ui, pane, crumb_row.top, z, focused);
    rest = crumb_row.rest;
    if (rest.isEmpty()) return null;

    // ── row 1: the filter pill ──
    const fr = rest.splitTop(1);
    var caret = filter_input.draw(ui, fr.top, .{
        .panel = .todos,
        .text = z.filter.items,
        .caret = z.filter_caret,
        .focused = z.filter_focused and focused,
        .bg = t.bg,
    });
    // The pill registers a `.filter_input` for its panel; this pane
    // routes clicks by pane, so cover it with the pane's own id.
    ui.hit(fr.top, .{ .script_hit = .{ .pane = pane, .id = Hit.filter } });
    rest = fr.rest;
    if (rest.isEmpty()) return caret;

    // ── the hint row ──
    if (rest.h >= 6) {
        const hr = rest.splitBottom(1);
        const hint = overlay.hintText(ui, hint_text);
        _ = ui.putStr(hr.rest.x + 1, hr.rest.y, hr.rest.w -| 1, ui.clipStr(hint, hr.rest.w -| 1), Theme.onBg(t.muted, t.bg.bg));
        rest = hr.top;
    }
    ui.hit(rest, .{ .script_hit = .{ .pane = pane, .id = Hit.body } });

    if (z.parse_error) |why| {
        _ = ui.putStr(rest.x + 1, rest.y, rest.w -| 1, ui.clipStr(ui.fmt("this file does not parse: {s}", .{why}), rest.w -| 1), Theme.onBg(t.error_fg, t.bg.bg));
        if (rest.h > 1) _ = ui.putStr(rest.x + 1, rest.y + 1, rest.w -| 1, "e opens the source — the tree reads the file once it parses", Theme.onBg(t.muted, t.bg.bg));
        return caret;
    }
    if (z.rows.len == 0) {
        const msg: []const u8 = if (z.filter.items.len > 0) "no field matches the filter" else "an empty file — e opens the source";
        _ = ui.putStr(rest.x + 1, rest.y, rest.w -| 1, msg, Theme.onBg(t.muted, t.bg.bg));
        return caret;
    }

    // ── the rows ──
    const list = if (z.rows.len > rest.h) rest.splitRight(1).left else rest;
    // A cell of air between a row's text and the bar; the row's ground
    // and its hit still reach it.
    const air: u16 = if (z.rows.len > rest.h) 1 else 0;
    const rows_h: usize = list.h;
    z.rows_h = rows_h;
    if (z.cursor < z.scroll) z.scroll = z.cursor;
    if (z.cursor >= z.scroll + rows_h) z.scroll = z.cursor + 1 - rows_h;
    if (z.scroll > z.rows.len -| rows_h) z.scroll = z.rows.len -| rows_h;

    // The label column: names line up within a depth.
    var picker_at: ?Rect = null;
    var y: u16 = 0;
    var i = z.scroll;
    while (i < z.rows.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        const row = z.rows[i];
        const is_cur = i == z.cursor and focused;
        const bg = if (is_cur) t.cursor_line.bg else t.bg.bg;
        if (is_cur) ui.fill(r, t.cursor_line);
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
        const tr = Rect.init(r.x, r.y, r.w -| air, 1);
        const node = z.node(row.node);
        var x = r.x;
        x += ui.putStr(x, r.y, 2, if (is_cur) (if (ui.ascii) "> " else "▸ ") else "  ", Theme.onBg(t.accent, bg));
        const indent: u16 = (node.depth -| 1) * 2;
        x += @min(indent, tr.right() -| x);
        // The fold glyph on a container.
        if (node.kind.isContainer()) {
            x += ui.putStr(x, r.y, tr.right() -| x, expander.slot(ui, !row.collapsed), expander.style(ui, Theme.onBg(t.fg, bg)));
        }
        const name_style = Theme.onBg(if (node.isListElement()) t.muted else t.fg, bg);
        x += ui.putStr(x, r.y, tr.right() -| x, ui.clipStr(node.name, tr.right() -| x), name_style);
        x += ui.putStr(x, r.y, tr.right() -| x, ":  ", Theme.onBg(t.muted, bg));
        if (x >= tr.right()) continue;
        const value = Rect.init(x, r.y, tr.right() - x, 1);
        if (z.editing) |e| if (e.node == row.node) {
            const c = drawField(ui, value, e, focused);
            if (c) |cc| caret = cc;
            continue;
        };
        const end = drawValue(ui, pane, value, z, i, row, bg, is_cur);
        if (row.modified and end < tr.right()) _ = ui.putStr(end + 1, r.y, tr.right() -| (end + 1), "*", Theme.onBg(t.warn_fg, bg));
        if (z.picker != null and z.picker.?.node == row.node) picker_at = Rect.init(value.x, r.y, value.w, 1);
    }
    if (z.rows.len > rest.h) scrollbar.drawVertical(ui, rest.rightCells(1), .{ .pane = pane }, z.rows.len, rows_h, z.scroll);
    if (picker_at) |at| drawPicker(ui, pane, list, at, z);
    return caret;
}

fn drawCrumbs(ui: Ui, pane: PaneId, r: Rect, z: *ZonPane, focused: bool) void {
    const t = ui.theme;
    ui.fill(r, t.panel_bg);
    const bg = t.panel_bg.bg;
    var x = r.x + 1;
    const sep: []const u8 = if (ui.ascii) " > " else " › ";
    // The file, then each ancestor of the focused row, then the row.
    x = crumb(ui, pane, r, x, z.title(), Theme.onBg(if (focused) t.accent else t.fg, bg), 0);
    if (z.current()) |row| {
        var chain: [64]u32 = undefined;
        var n: usize = 0;
        var cur: ?u32 = row.node;
        while (cur) |c| : (cur = z.node(c).parent) {
            if (z.node(c).parent == null) break;
            if (n < chain.len) chain[n] = c;
            n += 1;
        }
        n = @min(n, chain.len);
        var k = n;
        while (k > 0) {
            k -= 1;
            x += ui.putStr(x, r.y, r.right() -| x, sep, Theme.onBg(t.muted, bg));
            const idx = n - k; // 1 = the outermost
            x = crumb(ui, pane, r, x, z.node(chain[k]).name, Theme.onBg(if (k == 0) t.fg else t.muted, bg), idx);
        }
    }
    // The schema at the right, and the unsaved mark.
    const tag = if (z.changed) ui.fmt("{s} · unsaved", .{z.schema.label()}) else z.schema.label();
    const tw = ui.width(tag);
    if (x + tw + 2 <= r.right()) _ = ui.putStrRight(r.right() -| 1, r.y, tw, tag, Theme.onBg(if (z.changed) t.warn_fg else t.muted, bg));
}

fn crumb(ui: Ui, pane: PaneId, r: Rect, x: u16, text: []const u8, style: Style, idx: usize) u16 {
    if (x >= r.right()) return x;
    const w = ui.putStr(x, r.y, r.right() - x, ui.clipStr(text, r.right() - x), style);
    ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.crumb_base + @as(u32, @intCast(idx)) } });
    return x + w;
}

/// The open text field over the value cell.
fn drawField(ui: Ui, value: Rect, e: zon_pane.Edit, focused: bool) ?Caret {
    const t = ui.theme;
    const w: u16 = @min(value.w, @max(@as(u16, 12), ui.width(e.buf.items) + 2));
    const field = Rect.init(value.x, value.y, w, 1);
    return text_field.draw(ui, field, e.buf.items, e.caret, .{
        .style = Theme.onBg(Theme.withFg(t.chip_active, t.fg.fg), t.chip_active.bg),
        .focused = focused,
        .placeholder = switch (e.kind) {
            .string => "text",
            .number => "number",
            .literal => "literal",
            .name => "field name",
            .tag => "tag",
        },
    }) orelse null;
}

/// The value cell for `row`; returns the x after the last cell painted.
fn drawValue(ui: Ui, pane: PaneId, v: Rect, z: *ZonPane, row_i: usize, row: zon_pane.Row, bg: vaxis.Color, is_cur: bool) u16 {
    const t = ui.theme;
    const node = z.node(row.node);
    const f = row.field;
    const p = t.palette;
    var x = v.x;
    const muted = Theme.onBg(t.muted, bg);
    switch (f.widget) {
        .bool => {
            const on = std.mem.eql(u8, node.text, "true");
            x = option(ui, pane, v, x, "true", on, row_i, 0, bg);
            x += ui.putStr(x, v.y, v.right() -| x, " / ", muted);
            x = option(ui, pane, v, x, "false", !on, row_i, 1, bg);
        },
        .@"enum", .@"union" => {
            const cur_tag = currentTag(z, row.node);
            const cur_i = indexOf(f.tags, cur_tag);
            if (f.free_enum or f.tags.len == 0) {
                const label = ui.fmt("[{s}]", .{cur_tag orelse node.text});
                x = valueCell(ui, pane, v, x, label, t.chip_active, row_i);
            } else if (f.tags.len > max_listed_options) {
                const label = ui.fmt("[{s}]", .{cur_tag orelse "?"});
                x = valueCell(ui, pane, v, x, label, t.chip_active, row_i);
                x += ui.putStr(x, v.y, v.right() -| x, " ", muted);
                x = arrow(ui, pane, v, x, if (ui.ascii) "<" else "‹", Hit.dec_base, row_i, bg);
                x += ui.putStr(x, v.y, v.right() -| x, ui.fmt(" {d}/{d} ", .{ (cur_i orelse 0) + 1, f.tags.len }), muted);
                x = arrow(ui, pane, v, x, if (ui.ascii) ">" else "›", Hit.inc_base, row_i, bg);
            } else {
                for (f.tags, 0..) |tg, k| {
                    if (k > 0) x += ui.putStr(x, v.y, v.right() -| x, " / ", muted);
                    x = option(ui, pane, v, x, tg, cur_i == k, row_i, k, bg);
                }
            }
            if (f.widget == .@"union" and node.kind == .@"struct") x += ui.putStr(x, v.y, v.right() -| x, "  (payload below)", muted);
        },
        .int, .float => {
            x = arrow(ui, pane, v, x, if (ui.ascii) "<" else "‹", Hit.dec_base, row_i, bg);
            x += ui.putStr(x, v.y, v.right() -| x, " ", muted);
            x = valueCell(ui, pane, v, x, ui.fmt("[{s}]", .{node.text}), t.chip_active, row_i);
            x += ui.putStr(x, v.y, v.right() -| x, " ", muted);
            x = arrow(ui, pane, v, x, if (ui.ascii) ">" else "›", Hit.inc_base, row_i, bg);
        },
        .string => x = valueCell(ui, pane, v, x, ui.clipStr(node.text, v.right() -| x), Theme.onBg(Theme.withFg(t.fg, p.green), bg), row_i),
        .list => {
            const n = node.children.len;
            const label = if (n == 1) ".{ 1 item }" else ui.fmt(".{{ {d} items }}", .{n});
            x = valueCell(ui, pane, v, x, label, muted, row_i);
            if (is_cur) {
                x += ui.putStr(x, v.y, v.right() -| x, "  ", muted);
                x = chip(ui, pane, v, x, if (ui.ascii) " + add " else " + add ", Hit.add_base, row_i);
            }
        },
        .@"struct" => {
            const n = node.children.len;
            const label = if (node.kind == .empty) ".{}" else if (n == 1) ".{ 1 field }" else ui.fmt(".{{ {d} fields }}", .{n});
            x = valueCell(ui, pane, v, x, label, muted, row_i);
        },
        .union_shaped => x = valueCell(ui, pane, v, x, ui.fmt(".{{ .{s} }}", .{z.node(node.children[0]).name}), Theme.onBg(t.accent, bg), row_i),
        .optional_null => {
            x += ui.putStr(x, v.y, v.right() -| x, "null  ", muted);
            x = chip(ui, pane, v, x, " set… ", Hit.value_base, row_i);
        },
        .literal => x = valueCell(ui, pane, v, x, ui.clipStr(node.text, v.right() -| x), Theme.onBg(t.fg, bg), row_i),
    }
    // A list element under the cursor offers its removal.
    if (is_cur and node.isListElement() and x + 4 < v.right()) {
        x += ui.putStr(x, v.y, v.right() -| x, "  ", muted);
        x = chip(ui, pane, v, x, " x ", Hit.del_base, row_i);
    }
    return x;
}

fn currentTag(z: *ZonPane, idx: u32) ?[]const u8 {
    const n = z.node(idx);
    return switch (n.kind) {
        .enum_lit => n.text[1..],
        .@"struct" => if (n.children.len == 1) z.node(n.children[0]).name else null,
        else => null,
    };
}

fn indexOf(tags: []const []const u8, tag: ?[]const u8) ?usize {
    const tg = tag orelse return null;
    for (tags, 0..) |x, i| if (std.mem.eql(u8, x, tg)) return i;
    return null;
}

/// `[label]` when active, `label` otherwise; the option's hit.
fn option(ui: Ui, pane: PaneId, v: Rect, x: u16, label: []const u8, active: bool, row_i: usize, k: usize, bg: vaxis.Color) u16 {
    const t = ui.theme;
    if (x >= v.right()) return x;
    const text = if (active) ui.fmt("[{s}]", .{label}) else label;
    const style = if (active) t.chip_active else Theme.onBg(t.muted, bg);
    const w = ui.putStr(x, v.y, v.right() - x, ui.clipStr(text, v.right() - x), style);
    ui.hit(Rect.init(x, v.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.option_base + @as(u32, @intCast(row_i)) * Hit.option_stride + @as(u32, @intCast(@min(k, Hit.option_stride - 1))) } });
    return x + w;
}

fn valueCell(ui: Ui, pane: PaneId, v: Rect, x: u16, text: []const u8, style: Style, row_i: usize) u16 {
    if (x >= v.right()) return x;
    const w = ui.putStr(x, v.y, v.right() - x, ui.clipStr(text, v.right() - x), style);
    ui.hit(Rect.init(x, v.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.value_base + @as(u32, @intCast(row_i)) } });
    return x + w;
}

fn arrow(ui: Ui, pane: PaneId, v: Rect, x: u16, glyph: []const u8, base: u32, row_i: usize, bg: vaxis.Color) u16 {
    if (x >= v.right()) return x;
    const t = ui.theme;
    const w = ui.putStr(x, v.y, v.right() - x, glyph, Theme.onBg(t.accent, bg));
    ui.hit(Rect.init(x, v.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = base + @as(u32, @intCast(row_i)) } });
    return x + w;
}

fn chip(ui: Ui, pane: PaneId, v: Rect, x: u16, text: []const u8, base: u32, row_i: usize) u16 {
    if (x >= v.right()) return x;
    const t = ui.theme;
    const w = ui.putStr(x, v.y, v.right() - x, text, t.chip);
    ui.hit(Rect.init(x, v.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = base + @as(u32, @intCast(row_i)) } });
    return x + w;
}

/// The tag picker under (or over) the row: one line per tag, `✓` on
/// the current one, the cursor's row highlighted.
fn drawPicker(ui: Ui, pane: PaneId, list: Rect, at: Rect, z: *ZonPane) void {
    const t = ui.theme;
    const p = z.picker orelse return;
    const row = z.current() orelse return;
    const tags = row.field.tags;
    if (tags.len == 0) return;
    var widest: u16 = 0;
    for (tags) |tg| widest = @max(widest, ui.width(tg));
    const w: u16 = @min(list.w -| 2, widest + 6);
    const want_h: u16 = @intCast(@min(tags.len + 2, @as(usize, @max(list.h, 3))));
    const below = at.y + 1 + want_h <= list.bottom();
    const y: u16 = if (below) at.y + 1 else at.y -| want_h;
    const x: u16 = @min(at.x, list.right() -| w);
    const box = Rect.init(x, y, w, want_h);
    const inner = overlay.frameLook(ui, box, null, .popup);
    ui.hit(box, .{ .script_hit = .{ .pane = pane, .id = Hit.body } });
    const cur = indexOf(tags, currentTag(z, row.node));
    var first: usize = 0;
    if (p.cursor >= inner.h) first = p.cursor + 1 - inner.h;
    var ry: u16 = 0;
    var i = first;
    while (i < tags.len and ry < inner.h) : ({
        i += 1;
        ry += 1;
    }) {
        const r = inner.row(ry);
        const sel = i == p.cursor;
        const style = if (sel) Theme.onBg(t.fg, t.cursor_line.bg) else t.overlay_bg;
        ui.fill(r, style);
        const mark: []const u8 = if (cur == i) (if (ui.ascii) "* " else "✓ ") else "  ";
        var rx = r.x;
        rx += ui.putStr(rx, r.y, r.w, mark, Theme.onBg(t.accent, style.bg));
        _ = ui.putStr(rx, r.y, r.right() -| rx, ui.clipStr(tags[i], r.right() -| rx), style);
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = Hit.pick_base + @as(u32, @intCast(i)) } });
    }
}
