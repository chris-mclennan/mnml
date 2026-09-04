//! The spend report (`Pane.spend_report`): a title row with the sort
//! chip and the totals — ` · computing…` while the worker runs — a
//! column header whose cells are clickable sort keys, then one row per
//! workspace. Ids are `spend.zig`'s.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");
const spend = @import("../app/spend.zig");
const transcript = @import("../ai/transcript.zig");

pub const PaneId = ids.PaneId;

pub const cost_w: u16 = 12;
pub const tokens_w: u16 = 14;
pub const sessions_w: u16 = 9;
pub const pad: u16 = 2;

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *spend.SpendPane, focused: bool) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const head = area.row(0);
    ui.fill(head, th.panel_bg);
    const title_style = Theme.onBg(if (focused) th.accent else th.muted, th.panel_bg.bg);
    const arrow: []const u8 = if (p.desc) (if (ui.ascii) "v" else "↓") else (if (ui.ascii) "^" else "↑");
    const loading: []const u8 = if (p.loading) " · computing…" else "";
    const title = ui.fmt(" AI spend (24h) · sort: {s} {s}{s} · {d} sessions · ${d:.4} total · r refresh · s sort · e export · esc back ", .{ p.sort.label(), arrow, loading, p.sessions(), p.total_cost_usd });
    _ = ui.putStr(head.x, head.y, head.w, ui.clipStr(title, head.w), title_style);
    ui.hit(head, .{ .script_hit = .{ .pane = pane, .id = spend.hit_title } });
    if (area.h < 2) return;
    const body = area.splitTop(1).rest;

    // Column header.
    const hr = body.row(0);
    const ws_w: u16 = hr.w -| (cost_w + tokens_w + sessions_w + pad * 4);
    var x = hr.x;
    x = header(ui, x, hr, ws_w, "workspace", .left, p.sort == .workspace, arrow, pane, spend.hit_head_workspace);
    x = header(ui, x, hr, sessions_w, "sessions", .right, false, arrow, pane, 999);
    x = header(ui, x, hr, tokens_w, "tokens", .right, p.sort == .tokens, arrow, pane, spend.hit_head_tokens);
    _ = header(ui, x, hr, cost_w, "cost", .right, p.sort == .cost, arrow, pane, spend.hit_head_cost);
    if (body.h < 2) return;
    const list = body.splitTop(1).rest;
    if (p.rows.len == 0) {
        const msg: []const u8 = if (p.loading) "  computing… reading ~/.claude/projects and ~/.codex/sessions" else if (p.home == null) "  no home directory — transcripts live under ~/.claude and ~/.codex" else "  no AI sessions in the last 24 hours";
        _ = ui.putStr(list.x, list.y, list.w, ui.clipStr(msg, list.w), Theme.onBg(th.muted, th.bg.bg));
        return;
    }
    const rows_h: usize = list.h;
    if (rows_h > 0) {
        if (p.cursor < p.scroll) p.scroll = p.cursor;
        if (p.cursor >= p.scroll + rows_h) p.scroll = p.cursor + 1 - rows_h;
    }
    var y: u16 = 0;
    var i = p.scroll;
    while (i < p.rows.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        const row = p.rows[i];
        const sel = i == p.cursor and focused;
        const bg = if (sel) th.cursor_line.bg else th.bg.bg;
        if (sel) ui.fill(r, th.cursor_line);
        var rx = r.x;
        rx += ui.putStr(rx, r.y, ws_w, ui.fmt("{s}", .{ui.clipStr(row.workspace, ws_w)}), Theme.onBg(th.fg, bg));
        rx = r.x + ws_w + pad;
        var tb: [16]u8 = undefined;
        rx += ui.putStr(rx, r.y, sessions_w, ui.fmt("{d:>9}", .{row.sessions}), Theme.onBg(th.muted, bg));
        rx += pad;
        rx += ui.putStr(rx, r.y, tokens_w, ui.fmt("{s:>14}", .{transcript.fmtTokens(&tb, row.tokens)}), Theme.onBg(th.fg, bg));
        rx += pad;
        _ = ui.putStr(rx, r.y, cost_w, ui.fmt("{s:>12}", .{ui.fmt("${d:.4}", .{row.cost_usd})}), Theme.onBg(th.accent, bg));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = spend.row_base + @as(u32, @intCast(i)) } });
    }
}

const Align = enum { left, right };

fn header(ui: Ui, x: u16, hr: Rect, w: u16, label: []const u8, al: Align, active: bool, arrow: []const u8, pane: PaneId, id: u32) u16 {
    const th = ui.theme;
    var style = Theme.onBg(if (active) th.warn_fg else th.muted, th.bg.bg);
    style.bold = true;
    if (active) style.ul_style = .single;
    const text = if (active) ui.fmt("{s} {s}", .{ label, arrow }) else label;
    const r = Rect.init(x, hr.y, @min(w, hr.right() -| x), 1);
    if (r.w == 0) return x;
    switch (al) {
        .left => _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(text, r.w), style),
        .right => _ = ui.putStrRight(r.right(), r.y, r.w, ui.clipStr(text, r.w), style),
    }
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = id } });
    return x + w + pad;
}
