//! The WebSocket pane's face: a header (state badge, URL, subprotocol),
//! the log — `→` outgoing, `←` incoming, dim system notes, red errors —
//! newest at the bottom, and the input row. Paints a plain `Model`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const ids = @import("../core/ids.zig");

pub const Caret = text_field.Caret;
pub const PaneId = ids.PaneId;

pub const Entry = struct {
    outgoing: bool,
    text: []const u8,
    kind: enum { message, system, err },
};

pub const Model = struct {
    url: []const u8,
    state: []const u8,
    protocol: ?[]const u8,
    entries: []const Entry,
    input: []const u8,
    input_caret: usize,
    input_anchor: ?usize = null,
    /// Rows from the bottom; 0 follows the tail.
    scroll: *usize,
    focused: bool,
};

pub const hit_input: u32 = 1;
pub const hit_log: u32 = 2;

pub fn draw(ui: Ui, pane: PaneId, area: Rect, m: Model) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return null;
    const head = area.row(0);
    ui.fill(head, t.panel_bg);
    const badge: []const u8 = if (std.mem.eql(u8, m.state, "open")) " ● " else if (std.mem.eql(u8, m.state, "connecting")) " … " else " · ";
    const bw = ui.putStr(head.x, head.y, head.w, badge, Theme.onBg(if (std.mem.eql(u8, m.state, "open")) t.info_fg else t.muted, t.panel_bg.bg));
    const label = if (m.protocol) |p| ui.fmt("{s}  ·  {s}  ·  {s}", .{ m.url, m.state, p }) else ui.fmt("{s}  ·  {s}", .{ m.url, m.state });
    _ = ui.putStr(head.x + bw, head.y, head.w -| bw, ui.clipStr(label, head.w -| bw), Theme.onBg(t.fg, t.panel_bg.bg));
    if (area.h < 2) return null;
    // Input row at the bottom.
    const input_row = area.row(area.h - 1);
    const prompt: []const u8 = "> ";
    const pw = ui.putStr(input_row.x, input_row.y, input_row.w, prompt, t.accent);
    const field = Rect.init(input_row.x + pw, input_row.y, input_row.w -| pw, 1);
    ui.hit(input_row, .{ .script_hit = .{ .pane = pane, .id = hit_input } });
    const caret = text_field.draw(ui, field, m.input, m.input_caret, .{
        .style = t.fg,
        .placeholder = "type a message — Enter sends · Esc disconnects",
        .focused = m.focused,
        .anchor = m.input_anchor,
        .field = .{ .pane_field = .{ .pane = pane, .sub = .ws_input } },
    });
    if (area.h < 3) return caret;
    const log = Rect.init(area.x, area.y + 1, area.w, area.h - 2);
    ui.hit(log, .{ .script_hit = .{ .pane = pane, .id = hit_log } });
    const rows: usize = log.h;
    if (m.scroll.* > m.entries.len -| rows) m.scroll.* = m.entries.len -| rows;
    const end = m.entries.len -| m.scroll.*;
    const start = end -| rows;
    var y: u16 = 0;
    for (m.entries[start..end]) |e| {
        const r = log.row(y);
        const glyph: []const u8 = switch (e.kind) {
            .message => if (e.outgoing) (if (ui.ascii) "-> " else "→ ") else (if (ui.ascii) "<- " else "← "),
            .system => "· ",
            .err => "! ",
        };
        const style = switch (e.kind) {
            .message => if (e.outgoing) t.accent else t.fg,
            .system => t.muted,
            .err => t.error_fg,
        };
        const gw = ui.putStr(r.x + 1, r.y, r.w -| 1, glyph, style);
        _ = ui.putStr(r.x + 1 + gw, r.y, r.w -| (1 + gw), ui.clipStr(std.mem.sliceTo(e.text, '\n'), r.w -| (1 + gw)), style);
        y += 1;
    }
    return caret;
}
