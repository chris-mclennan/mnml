//! The browser pane's face: a header (state badge, URL, port, device),
//! a panel strip (log / network / cookies / storage / perf / dom), the
//! panel's rows, and a key hint line. Paints a plain `Model`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;

pub const LogKind = enum { system, console, console_err, nav, net, eval };

pub const Panel = enum {
    log,
    net,
    cookies,
    storage,
    perf,
    dom,

    pub const all = [_]Panel{ .log, .net, .cookies, .storage, .perf, .dom };

    pub fn label(p: Panel) []const u8 {
        return switch (p) {
            .log => "Log",
            .net => "Network (n)",
            .cookies => "Cookies (K)",
            .storage => "Storage (L)",
            .perf => "Perf (P)",
            .dom => "DOM (D)",
        };
    }
};

pub const LogLine = struct { kind: LogKind, text: []const u8 };
pub const NetRow = struct { method: []const u8, url: []const u8, status: []const u8, mime: []const u8 };

pub const Model = struct {
    url: []const u8,
    state: []const u8,
    port: ?u16,
    panel: Panel,
    log: []const LogLine,
    net: []const NetRow,
    /// Rows of the cookies / storage / perf / dom panels.
    rows: []const []const u8,
    sel: usize,
    scroll: *usize,
    focused: bool,
    device: ?[]const u8,
};

pub const hit_panel_base: u32 = 1; // + Panel index
pub const hit_row_base: u32 = 100; // + row

pub fn draw(ui: Ui, pane: PaneId, area: Rect, m: Model) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    const head = area.row(0);
    ui.fill(head, t.panel_bg);
    const badge: []const u8 = if (std.mem.eql(u8, m.state, "connected")) " ● " else if (std.mem.eql(u8, m.state, "launching")) " … " else " · ";
    const bw = ui.putStr(head.x, head.y, head.w, badge, Theme.onBg(if (std.mem.eql(u8, m.state, "connected")) t.info_fg else t.muted, t.panel_bg.bg));
    var label = m.url;
    if (m.device) |d| label = ui.fmt("{s}   [{s}]", .{ m.url, d });
    if (m.port) |p| label = ui.fmt("{s}   :{d}", .{ label, p });
    _ = ui.putStr(head.x + bw, head.y, head.w -| bw, ui.clipStr(label, head.w -| bw), Theme.onBg(t.fg, t.panel_bg.bg));
    if (area.h < 2) return;
    // Panel strip.
    const strip = area.row(1);
    var x = strip.x + 1;
    for (Panel.all, 0..) |p, i| {
        const active = p == m.panel;
        const text = if (active) ui.fmt("[{s}]", .{p.label()}) else ui.fmt(" {s} ", .{p.label()});
        const w = ui.width(text);
        if (x + w > strip.right()) break;
        var st = if (active) t.accent else t.muted;
        if (active) st.bold = true;
        _ = ui.putStr(x, strip.y, w, text, st);
        ui.hit(Rect.init(x, strip.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_panel_base + @as(u32, @intCast(i)) } });
        x += w + 1;
    }
    if (area.h < 3) return;
    const hint_row = area.row(area.h - 1);
    const hint: []const u8 = switch (m.panel) {
        .log => "g navigate · e eval · r reload · n network · K cookies · L storage · P perf · D dom · m device · s screenshot · q close",
        .net => "j/k select · y copy as curl · Enter re-send as a request · Esc back",
        .cookies => "j/k select · d delete · a add · Esc back",
        .storage => "j/k select · d delete · a add · Esc back",
        .perf => "Esc back",
        .dom => "j/k select · Esc back",
    };
    _ = ui.putStr(hint_row.x + 1, hint_row.y, hint_row.w -| 1, ui.clipStr(hint, hint_row.w -| 1), t.muted);
    const body = Rect.init(area.x, area.y + 2, area.w, area.h - 3);
    if (body.isEmpty()) return;
    switch (m.panel) {
        .log => {
            const rows: usize = body.h;
            if (m.scroll.* > m.log.len -| rows) m.scroll.* = m.log.len -| rows;
            const end = m.log.len -| m.scroll.*;
            const start = end -| rows;
            var y: u16 = 0;
            for (m.log[start..end]) |l| {
                const r = body.row(y);
                const style = switch (l.kind) {
                    .system => t.muted,
                    .console => t.fg,
                    .console_err => t.error_fg,
                    .nav => t.accent,
                    .net => t.info_fg,
                    .eval => t.warn_fg,
                };
                _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(std.mem.sliceTo(l.text, '\n'), r.w -| 1), style);
                y += 1;
            }
        },
        .net => {
            if (m.net.len == 0) {
                _ = ui.putStr(body.x + 1, body.y, body.w -| 1, "no Document / XHR / Fetch requests yet", t.muted);
                return;
            }
            var first: usize = 0;
            if (m.sel >= body.h) first = m.sel + 1 - body.h;
            var y: u16 = 0;
            for (m.net[first..], first..) |n, i| {
                if (y >= body.h) break;
                const r = body.row(y);
                const selected = i == m.sel;
                if (selected) ui.fill(r, t.cursor_line);
                const bg = if (selected) t.cursor_line.bg else t.bg.bg;
                const status_style = if (std.mem.eql(u8, n.status, "✗")) t.error_fg else if (n.status.len > 0 and n.status[0] == '2') t.info_fg else t.warn_fg;
                var xx = r.x + 1;
                xx += ui.putStr(xx, r.y, 4, ui.fmt("{s: <4}", .{n.status}), Theme.onBg(status_style, bg));
                xx += ui.putStr(xx, r.y, 7, ui.fmt("{s: <7}", .{n.method}), Theme.onBg(t.accent, bg));
                _ = ui.putStr(xx, r.y, r.right() -| xx, ui.clipStr(n.url, r.right() -| xx), Theme.onBg(t.fg, bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = hit_row_base + @as(u32, @intCast(i)) } });
                y += 1;
            }
        },
        .cookies, .storage, .perf, .dom => {
            if (m.rows.len == 0) {
                _ = ui.putStr(body.x + 1, body.y, body.w -| 1, "(empty)", t.muted);
                return;
            }
            var first: usize = 0;
            if (m.panel != .perf and m.sel >= body.h) first = m.sel + 1 - body.h;
            if (m.panel == .perf) first = @min(m.scroll.*, m.rows.len -| 1);
            var y: u16 = 0;
            for (m.rows[first..], first..) |row, i| {
                if (y >= body.h) break;
                const r = body.row(y);
                const selected = m.panel != .perf and i == m.sel;
                if (selected) ui.fill(r, t.cursor_line);
                _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(row, r.w -| 1), Theme.onBg(t.fg, if (selected) t.cursor_line.bg else t.bg.bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = hit_row_base + @as(u32, @intCast(i)) } });
                y += 1;
            }
        },
    }
}
