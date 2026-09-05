//! The grep results pane (`Pane.grep`): a title row (`SEARCH · rg:
//! "query" · N matches in M files · searching…`), a hint row, the `/`
//! filter row while it is open, then the rows — a file header
//! (`▾ src/a.zig (3)`) per file and `  12:5  the line` per hit with
//! the match highlighted and a disabled hit dimmed. Hit ids are
//! `grep.zig`'s. A scrollbar takes the last column when there is room.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");
const grep = @import("../app/grep.zig");
const text_field = @import("text_field.zig");
const scrollbar = @import("scrollbar.zig");

pub const PaneId = ids.PaneId;

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *grep.GrepPane, focused: bool) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const head = area.row(0);
    ui.fill(head, th.panel_bg);
    const title_style = Theme.onBg(if (focused) th.accent else th.muted, th.panel_bg.bg);
    const n = p.hits.items.len;
    const enabled = p.enabledCount();
    const backend: []const u8 = if (p.backend) |b| b.label() else "grep";
    const state: []const u8 = if (p.loading) (if (ui.ascii) " · searching..." else " · searching…") else "";
    const capped: []const u8 = if (p.truncated) " (capped)" else "";
    const count = if (enabled == n)
        ui.fmt("{d} match{s} in {d} file{s}", .{ n, if (n == 1) "" else "es", p.groups.items.len, if (p.groups.items.len == 1) "" else "s" })
    else
        ui.fmt("{d}/{d} enabled in {d} file{s}", .{ enabled, n, p.groups.items.len, if (p.groups.items.len == 1) "" else "s" });
    const title = ui.fmt(" SEARCH · {s}: \"{s}\" · {s}{s}{s} ", .{ backend, p.query, count, capped, state });
    _ = ui.putStr(head.x, head.y, head.w, ui.clipStr(title, head.w), title_style);
    ui.hit(head, .{ .script_hit = .{ .pane = pane, .id = grep.hit_title } });
    if (area.h < 2) return;
    var body = area.splitTop(1).rest;

    const hint_row = body.row(0);
    const hint: []const u8 = if (ui.ascii) "  enter open   n/N step   space toggle   R replace   r rerun   / filter   h/l fold   esc back" else "  ⏎ open · n/N step · space toggle · R replace · r rerun · / filter · h/l fold · esc back";
    _ = ui.putStr(hint_row.x, hint_row.y, hint_row.w, ui.clipStr(hint, hint_row.w), Theme.onBg(th.muted, th.bg.bg));
    if (body.h < 2) return;
    body = body.splitTop(1).rest;

    if (p.filter_active or p.filter.items.len > 0) {
        const fr = body.row(0);
        ui.fill(fr, th.panel_bg);
        const label: []const u8 = "  filter: ";
        const lw = ui.putStr(fr.x, fr.y, fr.w, label, Theme.onBg(if (p.filter_active) th.accent else th.muted, th.panel_bg.bg));
        const field = Rect.init(fr.x + lw, fr.y, fr.w -| lw, 1);
        _ = text_field.draw(ui, field, p.filter.items, p.filter_caret, .{
            .style = Theme.onBg(th.fg, th.panel_bg.bg),
            .placeholder = "vim pattern over the line and the path",
            .placeholder_style = Theme.onBg(th.muted, th.panel_bg.bg),
            .focused = p.filter_active and focused,
        });
        ui.hit(fr, .{ .script_hit = .{ .pane = pane, .id = grep.hit_filter } });
        if (body.h < 2) return;
        body = body.splitTop(1).rest;
    }

    if (p.rows.items.len == 0) {
        const msg: []const u8 = if (p.loading)
            (if (ui.ascii) "  searching..." else "  searching…")
        else if (p.err) |e|
            ui.fmt("  {s}", .{e})
        else if (p.hits.items.len > 0)
            "  no hit survives the filter"
        else
            "  no matches";
        _ = ui.putStr(body.x, body.y, body.w, ui.clipStr(msg, body.w), Theme.onBg(th.muted, th.bg.bg));
        return;
    }

    const want_sb = body.w >= 12;
    const list = if (want_sb) Rect.init(body.x, body.y, body.w - 1, body.h) else body;
    const rows_h: usize = list.h;
    if (rows_h > 0) {
        if (p.cursor < p.scroll) p.scroll = p.cursor;
        if (p.cursor >= p.scroll + rows_h) p.scroll = p.cursor + 1 - rows_h;
        const max_scroll = p.rows.items.len -| rows_h;
        if (p.scroll > max_scroll) p.scroll = max_scroll;
    }
    var y: u16 = 0;
    var i = p.scroll;
    while (i < p.rows.items.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        const sel = i == p.cursor;
        const bg = if (sel and focused) th.cursor_line.bg else if (sel) th.panel_bg.bg else th.bg.bg;
        if (sel) ui.fill(r, if (focused) th.cursor_line else th.panel_bg);
        switch (p.rows.items[i]) {
            .file => |g| {
                const grp = p.groups.items[g];
                const chevron: []const u8 = if (grp.collapsed) (if (ui.ascii) ">" else "▸") else (if (ui.ascii) "v" else "▾");
                const line = ui.fmt("{s} {s} ({d})", .{ chevron, grp.rel, grp.count });
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(line, r.w), Theme.onBg(th.accent, bg));
            },
            .hit => |h| paintHit(ui, r, p.hits.items[h], p.isDisabled(h), bg),
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = grep.row_base + @as(u32, @intCast(i)) } });
    }
    if (want_sb) {
        const sb = Rect.init(body.right() - 1, body.y, 1, body.h);
        scrollbar.drawVertical(ui, sb, .{ .pane = pane }, p.rows.items.len, rows_h, p.scroll);
    }
}

/// `  12:5  text` with the matched bytes in the match role. The line
/// is clipped to the row; a match past the clip is simply not shown.
fn paintHit(ui: Ui, r: Rect, h: grep.Hit, disabled: bool, bg: anytype) void {
    const th = ui.theme;
    const dim = Theme.onBg(th.muted, bg);
    const fg = if (disabled) dim else Theme.onBg(th.fg, bg);
    const mark: []const u8 = if (disabled) (if (ui.ascii) " - " else " ○ ") else "   ";
    var x = r.x;
    x += ui.putStr(x, r.y, r.w, mark, dim);
    const pos = ui.fmt("{d}:{d}  ", .{ h.line, h.col + 1 });
    x += ui.putStr(x, r.y, r.right() -| x, pos, dim);
    // The line, trimmed on the left so a hit deep in a long line stays visible.
    const text = std.mem.trimStart(u8, h.text, " \t");
    const trimmed_off = h.text.len - text.len;
    const col: usize = h.col -| trimmed_off;
    const avail: u16 = r.right() -| x;
    if (avail == 0) return;
    const before = text[0..@min(col, text.len)];
    const match_end = @min(col + h.len, text.len);
    const matched = if (col < text.len) text[col..match_end] else "";
    const after = if (match_end < text.len) text[match_end..] else "";
    var w = ui.putStr(x, r.y, avail, ui.clipStr(before, avail), fg);
    if (w < avail) w += ui.putStr(x + w, r.y, avail - w, ui.clipStr(matched, avail - w), if (disabled) dim else Theme.onBg(th.match, bg));
    if (w < avail) _ = ui.putStr(x + w, r.y, avail - w, ui.clipStr(after, avail - w), fg);
}
