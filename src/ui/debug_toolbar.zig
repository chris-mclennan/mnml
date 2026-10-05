//! The step toolbar — one row of debugger buttons, painted at the top
//! of the debug pane and mirrored as a strip over the editor while a
//! session is live (VS Code's floating toolbar, docked):
//!
//! ```text
//!  󰐊 Continue   󰆷 Step over   󰆹 Step into   󰆸 Step out   󰜉 Restart   󰓛 Stop
//! ```
//!
//! The first button follows the session: `Start` without one, `Pause`
//! while it runs, `Continue` while it is stopped. The step buttons
//! paint dim while nothing is stopped. Each button is ` icon label `
//! on the chip ground and registers `.script_hit{ pane, hitId(action) }`;
//! the pane's (or the editor's) click prong maps the action to its
//! `dap.*` command. The drop rule when the row is narrow: the labels
//! go first (icons alone), then buttons drop from the right; one
//! always stays.
//!
//! Zig-authored (the Rust pane had no toolbar). Glyphs are nf-md
//! codepoints with `--ascii` twins.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");
const compat = @import("mnml_sdk").zig_compat;

const Style = vaxis.Style;
const Color = vaxis.Color;
pub const PaneId = ids.PaneId;

pub const Action = enum(u8) { @"continue", step_over, step_into, step_out, restart, stop };

/// Above the git toolbar's (`git_toolbar.hit_base`); below nothing an
/// editor registers (`lsp_decor.lens_hit_base` is 0x4C45_0000).
pub const hit_base: u32 = 0xF400_0000;
const action_count: u32 = compat.enumFields(Action).len;

pub fn hitId(a: Action) u32 {
    return hit_base + @intFromEnum(a);
}

pub fn actionOf(id: u32) ?Action {
    if (id < hit_base or id >= hit_base + action_count) return null;
    return @enumFromInt(id - hit_base);
}

/// What the session is doing — the first button's word and the step
/// buttons' colour follow it.
pub const SessionState = enum { none, running, stopped };

pub const Props = struct {
    pane: PaneId,
    state: SessionState = .none,
};

const Accent = enum { green, yellow, blue, cyan, purple, orange, red, comment };

const Spec = struct { label: []const u8, action: Action, ascii: []const u8, glyph: []const u8, accent: Accent };

// nf-md-play / pause / debug_step_over / debug_step_into /
// debug_step_out / restart / stop.
const play_glyph = "\u{F040A}";
const play_ascii = ">";
const pause_glyph = "\u{F03E4}";
const pause_ascii = "|";
const specs = [_]Spec{
    .{ .label = "Continue", .action = .@"continue", .ascii = play_ascii, .glyph = play_glyph, .accent = .green },
    .{ .label = "Step over", .action = .step_over, .ascii = "\u{2192}", .glyph = "\u{F01B7}", .accent = .blue },
    .{ .label = "Step into", .action = .step_into, .ascii = "\u{2193}", .glyph = "\u{F01B9}", .accent = .blue },
    .{ .label = "Step out", .action = .step_out, .ascii = "\u{2191}", .glyph = "\u{F01B8}", .accent = .blue },
    .{ .label = "Restart", .action = .restart, .ascii = "\u{21BB}", .glyph = "\u{F0709}", .accent = .green },
    .{ .label = "Stop", .action = .stop, .ascii = "\u{25A0}", .glyph = "\u{F04DB}", .accent = .red },
};

/// Between buttons.
pub const gap: u16 = 1;
/// Below this nothing paints (one icon button and its padding).
pub const min_width: u16 = 4;

fn accentColor(p: Theme.Palette, a: Accent) Color {
    return switch (a) {
        .green => p.green,
        .yellow => p.yellow,
        .blue => p.blue,
        .cyan => p.cyan,
        .purple => p.purple,
        .orange => p.orange,
        .red => p.red,
        .comment => p.comment,
    };
}

/// The buttons for `state`: the first one's word and glyph follow it.
fn buttons(state: SessionState) [specs.len]Spec {
    var out = specs;
    out[0] = switch (state) {
        .none => .{ .label = "Start", .action = .@"continue", .ascii = play_ascii, .glyph = play_glyph, .accent = .green },
        .running => .{ .label = "Pause", .action = .@"continue", .ascii = pause_ascii, .glyph = pause_glyph, .accent = .yellow },
        .stopped => specs[0],
    };
    return out;
}

fn iconOf(ui: Ui, s: Spec) []const u8 {
    return if (ui.ascii) s.ascii else s.glyph;
}

/// ` icon label ` (or ` icon ` on the icon rung).
fn buttonWidth(ui: Ui, s: Spec, with_label: bool) u16 {
    const icon_w = ui.width(iconOf(ui, s));
    return if (with_label) icon_w + ui.width(s.label) + 3 else icon_w + 2;
}

fn totalWidth(ui: Ui, list: []const Spec, with_label: bool) u16 {
    var w: u16 = 0;
    for (list, 0..) |s, i| w += buttonWidth(ui, s, with_label) + @as(u16, if (i > 0) gap else 0);
    return w;
}

pub const Fit = struct { count: usize, with_label: bool };

/// The drop rule: every label fits → all; else icons alone → all;
/// else icons alone from the left, at least one.
pub fn fit(ui: Ui, list: []const Spec, w: u16) Fit {
    if (totalWidth(ui, list, true) <= w) return .{ .count = list.len, .with_label = true };
    if (totalWidth(ui, list, false) <= w) return .{ .count = list.len, .with_label = false };
    var used: u16 = 0;
    var n: usize = 0;
    for (list, 0..) |s, i| {
        const extra: u16 = if (i > 0) gap else 0;
        if (used + extra + buttonWidth(ui, s, false) > w) break;
        used += extra + buttonWidth(ui, s, false);
        n += 1;
    }
    return .{ .count = @max(n, 1), .with_label = false };
}

/// Paints the row into `area` and registers a hit per button. Returns
/// how it fit (tests, and the strip's own bookkeeping).
pub fn draw(ui: Ui, area: Rect, props: Props) Fit {
    const p = ui.theme.palette;
    const ground: Style = .{ .bg = p.bg_darker };
    ui.fill(area, ground);
    if (area.w < min_width or area.h < 1) return .{ .count = 0, .with_label = false };
    const list = buttons(props.state);
    const f = fit(ui, &list, area.w);
    var x = area.x + 1;
    const y = area.y;
    for (list[0..f.count], 0..) |s, i| {
        if (i > 0) x += gap;
        const w = buttonWidth(ui, s, f.with_label);
        if (x + w > area.right()) break;
        const r = Rect.init(x, y, w, 1);
        // A step button means nothing while the program runs or there
        // is no session; it paints muted and still registers (a click
        // toasts why).
        const live = switch (s.action) {
            .step_over, .step_into, .step_out => props.state == .stopped,
            .restart, .stop => props.state != .none,
            .@"continue" => true,
        };
        const fg = if (live) p.fg else p.comment;
        const base: Style = .{ .fg = fg, .bg = p.bg2, .bold = live };
        ui.fill(r, base);
        var cx = x + 1;
        cx += ui.putStr(cx, y, w, iconOf(ui, s), .{ .fg = if (live) accentColor(p, s.accent) else p.comment, .bg = p.bg2, .bold = live });
        if (f.with_label) {
            cx += 1;
            _ = ui.putStr(cx, y, area.right() -| cx, s.label, base);
        }
        ui.hit(r, .{ .script_hit = .{ .pane = props.pane, .id = hitId(s.action) } });
        x += w;
    }
    return f;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

pub fn glyphOf(a: Action) []const u8 {
    for (specs) |s| if (s.action == a) return s.glyph;
    unreachable;
}

test "stopped: six labelled buttons, every one a hit; the first reads Start / Pause / Continue by state" {
    var f = try Fixture.init(90, 1);
    defer f.deinit();
    const fit_all = draw(f.ui(), f.full(), .{ .pane = 2, .state = .stopped });
    try testing.expectEqual(@as(usize, 6), fit_all.count);
    try testing.expect(fit_all.with_label);
    try f.expectRow(0, try std.fmt.allocPrint(f.arena_state.allocator(), "  {s} Continue   {s} Step over   {s} Step into   {s} Step out   {s} Restart   {s} Stop", .{ glyphOf(.@"continue"), glyphOf(.step_over), glyphOf(.step_into), glyphOf(.step_out), glyphOf(.restart), glyphOf(.stop) }));
    try testing.expectEqual(hitId(.@"continue"), f.hits.at(2, 0).?.script_hit.id);
    try testing.expectEqual(hitId(.step_over), f.hits.at(16, 0).?.script_hit.id);
    try testing.expectEqual(hitId(.stop), f.hits.at(72, 0).?.script_hit.id);
    try testing.expectEqual(@as(u32, 2), f.hits.at(72, 0).?.script_hit.pane);
    try testing.expectEqual(@as(?Action, .stop), actionOf(hitId(.stop)));
    try testing.expectEqual(@as(?Action, null), actionOf(hit_base + action_count));
    try testing.expectEqual(@as(?Action, null), actionOf(12));
    var g = try Fixture.init(90, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), .{ .pane = 2, .state = .none });
    try g.expectContains(" Start ");
    // Without a session the step buttons paint muted.
    try testing.expect(g.fgEql(16, 0, .{ .fg = g.theme.palette.comment }));
    var h = try Fixture.init(90, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), .{ .pane = 2, .state = .running });
    try h.expectContains(" Pause ");
}

test "the drop rule: labels go first, then buttons from the right; under four cells nothing paints; ASCII twins" {
    // 6 icon buttons = 6*3 + 5 gaps = 23 cells (+1 lead).
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    const fit_icons = draw(f.ui(), f.full(), .{ .pane = 1, .state = .stopped });
    try testing.expectEqual(@as(usize, 6), fit_icons.count);
    try testing.expect(!fit_icons.with_label);
    try f.expectRow(0, try std.fmt.allocPrint(f.arena_state.allocator(), "  {s}   {s}   {s}   {s}   {s}   {s}", .{ glyphOf(.@"continue"), glyphOf(.step_over), glyphOf(.step_into), glyphOf(.step_out), glyphOf(.restart), glyphOf(.stop) }));
    try testing.expectEqual(hitId(.stop), f.hits.at(22, 0).?.script_hit.id);
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    const fit_few = draw(g.ui(), g.full(), .{ .pane = 1, .state = .stopped });
    try testing.expectEqual(@as(usize, 3), fit_few.count);
    try testing.expect(g.hits.at(6, 0) != null);
    var h = try Fixture.init(3, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), .{ .pane = 1, .state = .stopped });
    try testing.expectEqual(@as(usize, 0), h.hits.items.items.len);
    var a = try Fixture.init(90, 1);
    defer a.deinit();
    a.ascii = true;
    _ = draw(a.ui(), a.full(), .{ .pane = 1, .state = .stopped });
    try a.expectContains(" > Continue   \u{2192} Step over ");
}
