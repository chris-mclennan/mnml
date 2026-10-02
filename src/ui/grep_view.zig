//! The grep results pane (`Pane.grep`): a title row (`SEARCH · rg:
//! "query" · N matches in M files · searching…`), a hint row, the `/`
//! filter row while it is open, then the rows — a file header
//! (the expander, `src/a.zig (3)`) per file and `  12:5  the line` per hit with
//! the match highlighted and a disabled hit dimmed. Hit ids are
//! `grep.zig`'s. A scrollbar takes the last column when there is room.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const ids = @import("../core/ids.zig");
const grep = @import("../app/grep.zig");
const text_field = @import("text_field.zig");
const scrollbar = @import("scrollbar.zig");
const expander = @import("expander.zig");
const vaxis = @import("vaxis");
const utf8 = @import("../core/utf8.zig");

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
    const title = ui.fmt(" SEARCH · {s}: \"{s}\" · {s}{s}{s}{s} ", .{ backend, p.query, count, capped, grep.bigNote(ui.arena, p.skipped_big), state });
    _ = ui.putStr(head.x, head.y, head.w, ui.clipStr(title, head.w), title_style);
    ui.hit(head, .{ .script_hit = .{ .pane = pane, .id = grep.hit_title } });
    if (area.h < 2) return;
    var body = area.splitTop(1).rest;

    const hint_row = body.row(0);
    const hint = overlay.hintText(ui, "  ⏎ open · n/N step · space toggle · R replace · r rerun · / filter · h/l fold · esc back");
    _ = ui.putStr(hint_row.x, hint_row.y, hint_row.w, ui.clipStr(hint, hint_row.w), Theme.onBg(th.muted, th.bg.bg));
    if (body.h < 2) return;
    body = body.splitTop(1).rest;

    if (p.filter_active or p.filter.items.len > 0) {
        const fr = body.row(0);
        ui.fill(fr, th.panel_bg);
        const label: []const u8 = "  filter: ";
        const lw = ui.putStr(fr.x, fr.y, fr.w, label, Theme.onBg(if (p.filter_active) th.accent else th.muted, th.panel_bg.bg));
        const field = Rect.init(fr.x + lw, fr.y, fr.w -| lw, 1);
        ui.hit(fr, .{ .script_hit = .{ .pane = pane, .id = grep.hit_filter } });
        _ = text_field.draw(ui, field, p.filter.items, p.filter_caret, .{
            .style = Theme.onBg(th.fg, th.panel_bg.bg),
            .placeholder = "vim pattern over the line and the path",
            .placeholder_style = Theme.onBg(th.muted, th.panel_bg.bg),
            .focused = p.filter_active and focused,
            .anchor = p.filter_anchor,
            .field = .{ .pane_filter = pane },
        });
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
    // A cell of air between a row's text and the bar; the row's ground
    // and its hit still reach it.
    const air: u16 = if (want_sb) 1 else 0;
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
        const tr = Rect.init(r.x, r.y, r.w -| air, 1);
        const sel = i == p.cursor;
        const bg = if (sel and focused) th.cursor_line.bg else if (sel) th.panel_bg.bg else th.bg.bg;
        if (sel) ui.fill(r, if (focused) th.cursor_line else th.panel_bg);
        switch (p.rows.items[i]) {
            .file => |g| {
                const grp = p.groups.items[g];
                // The expander in its colour, the group's path in the accent.
                const chev = ui.putStr(tr.x, tr.y, tr.w, expander.slot(ui, !grp.collapsed), expander.style(ui, .{ .bg = bg }));
                const line = ui.fmt("{s} ({d})", .{ grp.rel, grp.count });
                _ = ui.putStr(tr.x + chev, tr.y, tr.w -| chev, ui.clipStr(line, tr.w -| chev), Theme.onBg(th.accent, bg));
            },
            .hit => |h| paintHit(ui, tr, p.hits.items[h], p.isDisabled(h), bg),
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
/// The text before the match is a window: its last `context_cells`
/// (fewer on a narrow row) behind `…` when more was cut — by the
/// walker (`grep.windowLine`) or here — so a hit deep in a long line
/// stays visible and nothing measures more than the row can paint.
pub const context_cells: u16 = 40;

fn paintHit(ui: Ui, r: Rect, h: grep.Hit, disabled: bool, bg: anytype) void {
    paintHitWith(ui, r, h, disabled, bg, "   ");
}

/// The same row with the caller's leading mark (the SEARCH section's
/// two cells, after the list panel's marker column). A disabled hit
/// paints its own mark whatever `mark` is.
pub fn paintHitWith(ui: Ui, r: Rect, h: grep.Hit, disabled: bool, bg: anytype, mark_in: []const u8) void {
    const th = ui.theme;
    const dim = Theme.onBg(th.muted, bg);
    const fg = if (disabled) dim else Theme.onBg(th.fg, bg);
    const mark: []const u8 = if (disabled) (if (ui.ascii) " - " else " ○ ") else mark_in;
    var x = r.x;
    x += ui.putStr(x, r.y, r.w, mark, dim);
    const pos = ui.fmt("{d}:{d}  ", .{ h.line, h.ccol + 1 });
    x += ui.putStr(x, r.y, r.right() -| x, pos, dim);
    // Leading blanks go only when the text starts the line: a window
    // that begins mid-line keeps its bytes as they are. A tab inside the
    // line paints as a space, byte for byte, so the columns hold (the
    // cell painter drops control bytes, which glued `a<Tab>b` into `ab`).
    const text0 = if (h.text_off == 0) std.mem.trimStart(u8, h.text, " \t") else h.text;
    const text = tabsAsSpaces(ui, text0);
    const trimmed_off = h.text.len - text.len;
    const col: usize = h.textCol() -| trimmed_off;
    const avail: u16 = r.right() -| x;
    if (avail == 0) return;
    const win = tailWindow(ui, text[0..@min(col, text.len)], @min(context_cells, avail / 2));
    const match_end = @min(col + h.len, text.len);
    const matched = if (col < text.len) text[col..match_end] else "";
    const after = if (match_end < text.len) text[match_end..] else "";
    var w: u16 = 0;
    if (win.cut or h.text_off > 0) w += ui.putStr(x, r.y, avail, ui.ellipsisText(), dim);
    if (w < avail) w += ui.putStr(x + w, r.y, avail - w, win.text, fg);
    if (w < avail) w += ui.putStr(x + w, r.y, avail - w, ui.clipStr(matched, avail - w), if (disabled) dim else Theme.onBg(th.match, bg));
    if (w < avail) _ = ui.putStr(x + w, r.y, avail - w, ui.clipStr(after, avail - w), fg);
}

/// `s` with every tab a space, on the frame arena; `s` itself when it
/// has none (or the arena is out).
fn tabsAsSpaces(ui: Ui, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
    const out = ui.arena.dupe(u8, s) catch return s;
    std.mem.replaceScalar(u8, out, '\t', ' ');
    return out;
}

const Tail = struct { text: []const u8, cut: bool };

/// The last `keep` cells of `s`, whole graphemes, and whether anything
/// was dropped. Bounded before it measures: at most `4 * keep + 4`
/// bytes of `s` are ever looked at, so a whole file line costs nothing.
fn tailWindow(ui: Ui, s_in: []const u8, keep: u16) Tail {
    var s = s_in;
    var cut = false;
    const byte_cap: usize = 4 * @as(usize, keep) + 4;
    if (s.len > byte_cap) {
        var start = s.len - byte_cap;
        while (start < s.len and (s[start] & 0xC0) == 0x80) start += 1;
        s = s[start..];
        cut = true;
    }
    var total = ui.width(s);
    if (total <= keep) return .{ .text = s, .cut = cut };
    var it = utf8.graphemeIterator(s);
    while (it.next()) |g| {
        total -= ui.canvas.cellWidth(g.bytes(s));
        if (total <= keep) return .{ .text = s[g.start + g.len ..], .cut = true };
    }
    return .{ .text = "", .cut = true };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "a hit on a 100k-char line paints a window: ellipsis, ~40 cells of context, the match, the clipped tail" {
    var f = try Fixture.init(100, 1);
    defer f.deinit();
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'y');
    @memcpy(long[70_000..][0..6], "needle");
    const ui = f.ui();
    // The whole line stored (an older session, or a test): the painter windows it itself.
    paintHit(ui, f.full(), .{ .path = "/x", .rel = "x", .line = 1, .col = 70_000, .ccol = 70_000, .len = 6, .text = long }, false, f.theme.bg.bg);
    var buf: [1024]u8 = undefined;
    const row = f.row(0, &buf);
    try testing.expect(std.mem.startsWith(u8, row, "   1:70001  …"));
    try testing.expect(std.mem.indexOf(u8, row, "y" ** 40 ++ "needle" ++ "y" ** 10) != null);
    try testing.expect(std.mem.indexOf(u8, row, "y" ** 41 ++ "needle") == null);
    try testing.expect(std.mem.endsWith(u8, row, "…"));
    // The walker's window carries the same picture through `text_off`.
    const win = grep.windowLine(long, 70_000, 6);
    try testing.expect(win.off > 0 and win.text.len < long.len);
    var g = try Fixture.init(100, 1);
    defer g.deinit();
    paintHit(g.ui(), g.full(), .{ .path = "/x", .rel = "x", .line = 1, .col = 70_000, .ccol = 70_000, .len = 6, .text = win.text, .text_off = win.off }, false, g.theme.bg.bg);
    try testing.expectEqualStrings(row, g.row(0, &buf));
    // A match at the head of a long line: no leading ellipsis, the tail is clipped.
    var h = try Fixture.init(60, 1);
    defer h.deinit();
    paintHit(h.ui(), h.full(), .{ .path = "/x", .rel = "x", .line = 2, .col = 0, .ccol = 0, .len = 3, .text = long }, false, h.theme.bg.bg);
    try h.expectRow(0, "   2:1  " ++ "y" ** 51 ++ "…");
}

test "a short hit paints whole: no ellipsis, leading blanks trimmed" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    paintHit(f.ui(), f.full(), .{ .path = "/x", .rel = "x", .line = 3, .col = 8, .ccol = 8, .len = 4, .text = "    let name = 1;" }, false, f.theme.bg.bg);
    try f.expectRow(0, "   3:9  let name = 1;");
}

test "a tab in a hit paints as a space, and the match stays on its bytes" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    paintHit(f.ui(), f.full(), .{ .path = "/x", .rel = "x", .line = 1, .col = 4, .ccol = 4, .len = 5, .text = "tab\talpha" }, false, f.theme.bg.bg);
    try f.expectRow(0, "   1:5  tab alpha");
}
