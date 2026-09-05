//! The debug pane's paint: a status row, then three stacked sections —
//! CALL STACK (one row per frame), VARIABLES (the watches first, then
//! the flattened scope tree) and OUTPUT (the tail of what the debuggee
//! printed). The focused section's cursor row is banded; the other
//! section's cursor is dimmer so both positions stay visible.
//!
//! Rows register `.script_hit{pane, id}`: a frame is its index, a
//! variable row is `vars_base + index`, a watch is `watch_base + index`.
//! The app decodes them (`app/dap.zig`).

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const scrollbar = @import("scrollbar.zig");
const ids = @import("../core/ids.zig");
const types = @import("../dap/types.zig");

pub const PaneId = ids.PaneId;
pub const Style = vaxis.Style;
pub const VarRow = types.VarRow;

pub const vars_base: u32 = 0x1000_0000;
pub const watch_base: u32 = 0x2000_0000;

pub const Section = enum { stack, variables };

pub const Frame = struct { label: []const u8 };
pub const Watch = struct { expression: []const u8, value: []const u8, is_err: bool };

pub const Props = struct {
    /// `● stopped (breakpoint) · thread 1`, `▶ running`, `(no session)`.
    status: []const u8,
    stopped: bool,
    has_session: bool,
    frames: []const Frame,
    stack_cursor: usize,
    watches: []const Watch,
    vars: []const VarRow,
    /// Cursor over the watches + vars rows as one list (watches first).
    vars_cursor: usize,
    output: []const []const u8,
    section: Section,
    focused: bool,
};

/// The three scroll offsets the pane keeps.
pub const Scrolls = struct { stack: usize = 0, vars: usize = 0 };

pub fn draw(ui: Ui, pane: PaneId, area: Rect, scrolls: *Scrolls, p: Props) void {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.isEmpty()) return;
    const bg = t.panel_bg.bg;
    // Status row.
    var x = area.x;
    x += ui.putStr(x, area.y, area.w, " Debug ", Theme.onBg(Theme.withFg(t.tab_active, t.accent.fg), bg));
    x += 1;
    const status_style = Theme.onBg(if (p.stopped) t.error_fg else if (p.has_session) t.info_fg else t.muted, bg);
    _ = ui.putStr(x, area.y, area.right() -| x, ui.clipStr(p.status, area.right() -| x), status_style);
    if (area.h < 4) return;
    var rest = Rect.init(area.x, area.y + 1, area.w, area.h - 1);
    // Output takes the bottom: up to a quarter, at least 3 rows when
    // there is room, and only when there is something to show.
    const out_h: u16 = if (p.output.len == 0 or rest.h < 8) 0 else @max(@min(@as(u16, @intCast(@min(p.output.len + 1, 64))), rest.h / 4), 3);
    if (out_h > 0) {
        const s = rest.splitBottom(out_h);
        rest = s.top;
        drawOutput(ui, s.rest, p.output);
    }
    // The stack takes a third (at least 3 rows), the variables the rest.
    const stack_h: u16 = @max(@min(@as(u16, @intCast(@min(p.frames.len + 1, 64))), rest.h / 3), 3);
    const s = rest.splitTop(@min(stack_h, rest.h));
    drawStack(ui, pane, s.top, &scrolls.stack, p);
    if (s.rest.h > 0) drawVariables(ui, pane, s.rest, &scrolls.vars, p);
}

fn sectionHeader(ui: Ui, r: Rect, label: []const u8, active: bool) void {
    const t = ui.theme;
    const style = Theme.onBg(if (active) t.accent else t.muted, t.panel_bg.bg);
    ui.fill(r, style);
    _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ui.fmt(" {s} ", .{label}), r.w), style);
}

fn drawStack(ui: Ui, pane: PaneId, area: Rect, scroll: *usize, p: Props) void {
    const t = ui.theme;
    const bg = t.panel_bg.bg;
    sectionHeader(ui, area.row(0), "CALL STACK", p.section == .stack);
    if (area.h < 2) return;
    const list = Rect.init(area.x, area.y + 1, area.w, area.h - 1);
    if (p.frames.len == 0) {
        const msg: []const u8 = if (p.has_session) "  (no frames — waiting for a stop)" else "  (no frames — start a session + hit a breakpoint)";
        _ = ui.putStr(list.x, list.y, list.w, ui.clipStr(msg, list.w), Theme.onBg(t.muted, bg));
        return;
    }
    const win = list_panel.scrollWindow(scroll, p.stack_cursor, p.frames.len, list.h);
    const cols = list.splitRight(if (win.needs_bar and list.w > 8) 1 else 0);
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const r = cols.left.row(@intCast(i));
        const active = p.section == .stack and p.focused;
        const style: Style = if (idx == p.stack_cursor) (if (active) Theme.onBg(t.panel_bg, t.cursor_line.bg) else Theme.onBg(t.panel_bg, t.selection.bg)) else t.panel_bg;
        ui.fill(r, style);
        var cx = r.x;
        cx += ui.putStr(cx, r.y, r.w, if (idx == p.stack_cursor) (if (ui.ascii) "> " else "▶ ") else "  ", Theme.withFg(style, t.accent.fg));
        _ = ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(p.frames[idx].label, r.right() -| cx), Theme.withFg(style, t.fg.fg));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(idx) } });
    }
    if (win.needs_bar and list.w > 8) scrollbar.drawVertical(ui, cols.rest, .{ .pane = pane }, p.frames.len, list.h, scroll.*);
}

fn drawVariables(ui: Ui, pane: PaneId, area: Rect, scroll: *usize, p: Props) void {
    const t = ui.theme;
    const bg = t.panel_bg.bg;
    sectionHeader(ui, area.row(0), "VARIABLES", p.section == .variables);
    if (area.h < 2) return;
    const list = Rect.init(area.x, area.y + 1, area.w, area.h - 1);
    const total = p.watches.len + p.vars.len;
    if (total == 0) {
        const msg: []const u8 = if (p.has_session) "  (waiting for stopped state…)" else "  (no session — start one with dap.run)";
        _ = ui.putStr(list.x, list.y, list.w, ui.clipStr(msg, list.w), Theme.onBg(t.muted, bg));
        return;
    }
    const win = list_panel.scrollWindow(scroll, p.vars_cursor, total, list.h);
    const cols = list.splitRight(if (win.needs_bar and list.w > 8) 1 else 0);
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const r = cols.left.row(@intCast(i));
        const active = p.section == .variables and p.focused;
        const style: Style = if (idx == p.vars_cursor) (if (active) Theme.onBg(t.panel_bg, t.cursor_line.bg) else Theme.onBg(t.panel_bg, t.selection.bg)) else t.panel_bg;
        ui.fill(r, style);
        if (idx < p.watches.len) {
            const w = p.watches[idx];
            var cx = r.x;
            cx += ui.putStr(cx, r.y, r.w, if (ui.ascii) "  @ " else "  ⌖ ", Theme.withFg(style, t.warn_fg.fg));
            cx += ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(w.expression, r.right() -| cx), Theme.withFg(style, t.fg.fg));
            cx += ui.putStr(cx, r.y, r.right() -| cx, " = ", Theme.withFg(style, t.muted.fg));
            _ = ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(w.value, r.right() -| cx), Theme.withFg(style, if (w.is_err) t.error_fg.fg else t.info_fg.fg));
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = watch_base + @as(u32, @intCast(idx)) } });
            continue;
        }
        const row = p.vars[idx - p.watches.len];
        var cx = r.x + 2 + @as(u16, row.depth) * 2;
        const chevron: []const u8 = if (row.expandable) (if (row.expanded) (if (ui.ascii) "v " else "▾ ") else (if (ui.ascii) "> " else "▸ ")) else "  ";
        cx += ui.putStr(cx, r.y, r.right() -| cx, chevron, Theme.withFg(style, t.accent.fg));
        const label_style = Theme.withFg(style, if (row.is_scope) t.accent.fg else t.fg.fg);
        cx += ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(row.label, r.right() -| cx), label_style);
        if (row.value.len > 0) {
            cx += ui.putStr(cx, r.y, r.right() -| cx, " = ", Theme.withFg(style, t.muted.fg));
            _ = ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(row.value, r.right() -| cx), Theme.withFg(style, t.info_fg.fg));
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = vars_base + @as(u32, @intCast(idx - p.watches.len)) } });
    }
    if (win.needs_bar and list.w > 8) scrollbar.drawVertical(ui, cols.rest, .{ .pane = pane }, total, list.h, scroll.*);
}

fn drawOutput(ui: Ui, area: Rect, output: []const []const u8) void {
    const t = ui.theme;
    sectionHeader(ui, area.row(0), "OUTPUT", false);
    if (area.h < 2) return;
    const rows: usize = area.h - 1;
    const first = output.len -| rows;
    var y: u16 = area.y + 1;
    for (output[first..]) |line| {
        _ = ui.putStr(area.x + 1, y, area.w -| 1, ui.clipStr(line, area.w -| 1), Theme.onBg(t.fg, t.panel_bg.bg));
        y += 1;
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "no session: the empty-state rows and the watch list still paint" {
    var f = try Fixture.init(50, 10);
    defer f.deinit();
    var sc: Scrolls = .{};
    const watches = [_]Watch{.{ .expression = "my_var.field", .value = "(no value)", .is_err = false }};
    draw(f.ui(), 3, f.full(), &sc, .{ .status = "(no session — dap.run starts one)", .stopped = false, .has_session = false, .frames = &.{}, .stack_cursor = 0, .watches = &watches, .vars = &.{}, .vars_cursor = 0, .output = &.{}, .section = .variables, .focused = true });
    try f.expectContains(" Debug ");
    try f.expectContains("(no frames — start a session + hit a breakpoint)");
    try f.expectContains("⌖ my_var.field = (no value)");
    try testing.expectEqual(watch_base, f.hits.at(4, 5).?.script_hit.id);
}

test "a stop: frames, the variables tree with chevrons, the output tail" {
    var f = try Fixture.init(60, 14);
    defer f.deinit();
    var sc: Scrolls = .{};
    const frames = [_]Frame{ .{ .label = "main.py:3  main" }, .{ .label = "main.py:9  <module>" } };
    const vars = [_]VarRow{
        .{ .depth = 0, .is_scope = true, .label = "Locals", .name = "Locals", .value = "", .var_ref = 10, .expanded = true, .expandable = true, .parent_ref = 0 },
        .{ .depth = 1, .is_scope = false, .label = "n: int", .name = "n", .value = "3", .var_ref = 0, .expanded = false, .expandable = false, .parent_ref = 10 },
    };
    const out = [_][]const u8{ "hello", "world" };
    draw(f.ui(), 1, f.full(), &sc, .{ .status = "● stopped (breakpoint) · thread 1", .stopped = true, .has_session = true, .frames = &frames, .stack_cursor = 0, .watches = &.{}, .vars = &vars, .vars_cursor = 1, .output = &out, .section = .stack, .focused = true });
    try f.expectContains("▶ main.py:3  main");
    try f.expectContains("▾ Locals");
    try f.expectContains("    n: int = 3");
    try f.expectContains(" OUTPUT");
    try f.expectContains(" world");
    try testing.expectEqual(@as(u32, 1), f.hits.at(4, 3).?.script_hit.id);
    try testing.expectEqual(vars_base + 1, f.hits.at(6, 6).?.script_hit.id);
}
