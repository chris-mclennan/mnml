//! The browser pane's face: a header (state badge, URL, port, device),
//! a panel strip (log / network / cookies / storage / perf / dom), the
//! filter pill that narrows the panel, the panel's rows, and a key hint
//! line. Paints a plain `Model`.
//!
//! The rows arrive already narrowed; each carries its index in the
//! pane's unfiltered list so the hit ids (`hit_row_base + index`) and
//! the selection keep meaning the same row whatever the filter says.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const filter_input = @import("filter_input.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;
pub const Caret = text_field.Caret;

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

/// One painted row of the log: the pane splits a multi-line entry into
/// several of these (`browser_pane.logRows`), so `text` has no newline.
pub const LogLine = struct { kind: LogKind, text: []const u8 };
pub const NetRow = struct {
    /// Position in the pane's unfiltered network list.
    index: usize,
    method: []const u8,
    url: []const u8,
    status: []const u8,
    mime: []const u8,
};

pub const Model = struct {
    url: []const u8,
    state: []const u8,
    port: ?u16,
    panel: Panel,
    /// The log lines that pass the filter.
    log: []const LogLine,
    /// The network rows that pass the filter.
    net: []const NetRow,
    /// Rows of the cookies / storage / perf / dom panels that pass the
    /// filter, and their positions in the unfiltered list.
    rows: []const []const u8,
    row_index: []const usize,
    /// How many rows the panel has before the filter.
    total: usize,
    /// The selected row's unfiltered index.
    sel: usize,
    scroll: *usize,
    focused: bool,
    device: ?[]const u8,
    filter: []const u8,
    filter_caret: usize,
    filter_focused: bool,
};

pub const hit_panel_base: u32 = 1; // + Panel index
pub const hit_filter: u32 = 50;
pub const hit_row_base: u32 = 100; // + row's unfiltered index

/// What a frame reports back: the filter's caret when it has focus,
/// and the unfiltered index of the row under the pointer.
pub const Outcome = struct {
    caret: ?Caret = null,
    hovered_row: ?usize = null,
};

pub fn draw(ui: Ui, pane: PaneId, area: Rect, m: Model) Outcome {
    const t = ui.theme;
    var out: Outcome = .{};
    ui.fill(area, t.bg);
    if (area.isEmpty()) return out;
    const head = area.row(0);
    ui.fill(head, t.panel_bg);
    const badge: []const u8 = if (std.mem.eql(u8, m.state, "connected")) " ● " else if (std.mem.eql(u8, m.state, "launching")) " … " else " · ";
    const bw = ui.putStr(head.x, head.y, head.w, badge, Theme.onBg(if (std.mem.eql(u8, m.state, "connected")) t.info_fg else t.muted, t.panel_bg.bg));
    var label = m.url;
    if (m.device) |d| label = ui.fmt("{s}   [{s}]", .{ m.url, d });
    if (m.port) |p| label = ui.fmt("{s}   :{d}", .{ label, p });
    _ = ui.putStr(head.x + bw, head.y, head.w -| bw, ui.clipStr(label, head.w -| bw), Theme.onBg(t.fg, t.panel_bg.bg));
    if (area.h < 2) return out;
    // Panel strip, with the narrowed count at its right end.
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
    if (m.filter.len > 0) {
        const shown: usize = switch (m.panel) {
            .log => m.log.len,
            .net => m.net.len,
            .cookies, .storage, .perf, .dom => m.rows.len,
        };
        const count = ui.fmt("({d} of {d})", .{ shown, m.total });
        const cw = ui.width(count);
        if (strip.right() > x + cw + 1) _ = ui.putStrRight(strip.right() - 1, strip.y, cw, count, t.muted);
    }
    if (area.h < 3) return out;
    // The filter pill: the same glyph and words as every list panel's.
    out.caret = drawFilter(ui, pane, area.row(2), m);
    if (area.h < 4) return out;
    const hint_row = area.row(area.h - 1);
    const hint: []const u8 = switch (m.panel) {
        .log => "/ filter · g navigate · e eval · r reload · n network · K cookies · L storage · P perf · D dom · m device · s screenshot · q close",
        .net => "/ filter · j/k select · y copy as curl · Enter re-send as a request · Esc back",
        .cookies => "/ filter · j/k select · d delete · a add · Esc back",
        .storage => "/ filter · j/k select · d delete · a add · Esc back",
        .perf => "/ filter · Esc back",
        .dom => "/ filter · j/k select · hover highlights the node in Chrome · Esc back",
    };
    _ = ui.putStr(hint_row.x + 1, hint_row.y, hint_row.w -| 1, ui.clipStr(hint, hint_row.w -| 1), t.muted);
    const body = Rect.init(area.x, area.y + 3, area.w, area.h - 4);
    if (body.isEmpty()) return out;
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
                _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(l.text, r.w -| 1), style);
                y += 1;
            }
        },
        .net => {
            if (m.net.len == 0) {
                _ = ui.putStr(body.x + 1, body.y, body.w -| 1, if (m.filter.len > 0) "no request matches the filter — Esc clears" else "no Document / XHR / Fetch requests yet", t.muted);
                return out;
            }
            const sel_pos = positionOfNet(m.net, m.sel);
            var first: usize = 0;
            if (sel_pos >= body.h) first = sel_pos + 1 - body.h;
            var y: u16 = 0;
            for (m.net[first..]) |n| {
                if (y >= body.h) break;
                const r = body.row(y);
                const selected = n.index == m.sel;
                if (selected) ui.fill(r, t.cursor_line);
                const bg = if (selected) t.cursor_line.bg else t.bg.bg;
                const status_style = if (std.mem.eql(u8, n.status, "✗")) t.error_fg else if (n.status.len > 0 and n.status[0] == '2') t.info_fg else t.warn_fg;
                var xx = r.x + 1;
                xx += ui.putStr(xx, r.y, 4, ui.fmt("{s: <4}", .{n.status}), Theme.onBg(status_style, bg));
                xx += ui.putStr(xx, r.y, 7, ui.fmt("{s: <7}", .{n.method}), Theme.onBg(t.accent, bg));
                _ = ui.putStr(xx, r.y, r.right() -| xx, ui.clipStr(n.url, r.right() -| xx), Theme.onBg(t.fg, bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = hit_row_base + @as(u32, @intCast(n.index)) } });
                if (ui.hovered(r)) out.hovered_row = n.index;
                y += 1;
            }
        },
        .cookies, .storage, .perf, .dom => {
            if (m.rows.len == 0) {
                _ = ui.putStr(body.x + 1, body.y, body.w -| 1, if (m.filter.len > 0) "nothing matches the filter — Esc clears" else "(empty)", t.muted);
                return out;
            }
            var first: usize = 0;
            if (m.panel == .perf) {
                first = @min(m.scroll.*, m.rows.len -| 1);
            } else {
                const sel_pos = positionOf(m.row_index, m.sel);
                if (sel_pos >= body.h) first = sel_pos + 1 - body.h;
            }
            var y: u16 = 0;
            for (m.rows[first..], m.row_index[first..]) |row, index| {
                if (y >= body.h) break;
                const r = body.row(y);
                const selected = m.panel != .perf and index == m.sel;
                if (selected) ui.fill(r, t.cursor_line);
                _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(row, r.w -| 1), Theme.onBg(t.fg, if (selected) t.cursor_line.bg else t.bg.bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = hit_row_base + @as(u32, @intCast(index)) } });
                if (ui.hovered(r)) out.hovered_row = index;
                y += 1;
            }
        },
    }
    return out;
}

/// The pill: chip ground, the search glyph, the text (or the shared
/// placeholder), one cell of the pane's ground on each side. The whole
/// pill is a `script_hit` — a pane has no `PanelId` for `.filter_input`.
fn drawFilter(ui: Ui, pane: PaneId, area: Rect, m: Model) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty() or area.w < 4) return null;
    const pill = Rect.init(area.x + 1, area.y, area.w - 2, 1);
    const style = if (m.filter_focused) Theme.withFg(t.chip, t.fg.fg) else t.chip;
    ui.fill(pill, style);
    var x = pill.x;
    x += ui.putStr(x, pill.y, pill.w, " ", style);
    x += ui.putStr(x, pill.y, pill.right() - x, filter_input.glyph(ui), Theme.withFg(style, t.accent.fg));
    x += ui.putStr(x, pill.y, pill.right() - x, " ", style);
    const field = Rect.init(x, pill.y, (pill.right() - 1) -| x, 1);
    ui.hit(pill, .{ .script_hit = .{ .pane = pane, .id = hit_filter } });
    return text_field.draw(ui, field, m.filter, m.filter_caret, .{
        .style = style,
        .placeholder = filter_input.placeholder(ui, m.filter_focused, filter_input.default_noun),
        .focused = m.filter_focused and m.focused,
    });
}

/// Where `sel` sits in the narrowed order; 0 when it was filtered out.
fn positionOfNet(rows: []const NetRow, sel: usize) usize {
    for (rows, 0..) |n, i| if (n.index == sel) return i;
    return 0;
}

fn positionOf(index: []const usize, sel: usize) usize {
    for (index, 0..) |n, i| if (n == sel) return i;
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the pill, the narrowed count and the rows' unfiltered hit ids" {
    var f = try Fixture.init(80, 24);
    defer f.deinit();
    var scroll: usize = 0;
    const net = [_]NetRow{.{ .index = 1, .method = "POST", .url = "api.example.com/items", .status = "201", .mime = "application/json" }};
    const m: Model = .{
        .url = "https://example.com",
        .state = "connected",
        .port = 9222,
        .panel = .net,
        .log = &.{},
        .net = &net,
        .rows = &.{},
        .row_index = &.{},
        .total = 2,
        .sel = 1,
        .scroll = &scroll,
        .focused = true,
        .device = null,
        .filter = "items",
        .filter_caret = 5,
        .filter_focused = false,
    };
    var out = draw(f.ui(), 3, f.full(), m);
    try testing.expect(out.caret == null);
    try f.expectContains("(1 of 2)");
    try f.expectContains("\u{F0349} items");
    try f.expectContains("201 POST   api.example.com/items");
    // The pill is a script hit; the one row keeps its unfiltered index.
    try testing.expectEqual(@as(u32, hit_filter), f.hits.at(5, 2).?.script_hit.id);
    try testing.expectEqual(@as(u32, hit_row_base + 1), f.hits.at(10, 3).?.script_hit.id);
    try testing.expect(f.bgEql(10, 3, f.theme.cursor_line));
    // Focused and empty: the shared placeholder and a caret.
    f.hits.reset();
    var focused = m;
    focused.filter = "";
    focused.filter_focused = true;
    out = draw(f.ui(), 3, f.full(), focused);
    try testing.expectEqual(Caret{ .x = 4, .y = 2 }, out.caret.?);
    try f.expectContains("type to filter…");
    try testing.expect(std.mem.indexOf(u8, try f.text(), " of ") == null);
    // The pointer over a DOM row reports that row's unfiltered index.
    f.hits.reset();
    var dom = m;
    dom.panel = .dom;
    dom.rows = &.{ "html", "  div#app" };
    dom.row_index = &.{ 0, 2 };
    dom.sel = 0;
    f.hover = .{ .x = 4, .y = 4 };
    out = draw(f.ui(), 3, f.full(), dom);
    try testing.expectEqual(@as(?usize, 2), out.hovered_row);
    f.hover = .{ .x = 4, .y = 20 };
    out = draw(f.ui(), 3, f.full(), dom);
    try testing.expect(out.hovered_row == null);
}

test "short areas never panic and register nothing off-screen" {
    var scroll: usize = 0;
    inline for (.{ .{ 1, 1 }, .{ 3, 2 }, .{ 6, 3 }, .{ 12, 4 }, .{ 40, 5 } }) |wh| {
        var f = try Fixture.init(wh[0], wh[1]);
        defer f.deinit();
        const m: Model = .{ .url = "u", .state = "closed", .port = null, .panel = .dom, .log = &.{}, .net = &.{}, .rows = &.{"x"}, .row_index = &.{0}, .total = 1, .sel = 0, .scroll = &scroll, .focused = true, .device = null, .filter = "x", .filter_caret = 1, .filter_focused = true };
        _ = draw(f.ui(), 1, f.full(), m);
        for (f.hits.items.items) |e| try testing.expect(f.full().intersect(e.rect).eql(e.rect));
    }
}
