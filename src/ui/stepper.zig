//! The stepper — ` ‹ n/m › `, the one control that steps through a run
//! of things a strip has no room to show at once. Two strips wear it:
//!
//! * a session's tab strip, where `n/m` is the session's place — in the
//!   ring of every Claude Code / Codex session outside the sessions
//!   mode, in its column's stack inside it — and the arrows do what
//!   `ai.focus_*_session` / `sessions.column_*` do;
//! * any tab strip whose tabs overflow its width, where `n/m` is the
//!   page of tabs on show and the arrows page through the hidden ones.
//!
//! Each arrow is a button-wide `.button` hit, painted in the same
//! statement as its cells; the pointer over one lights it. The number
//! between them is in the dim role. With nothing to step — `m` of one,
//! or a strip whose tabs all fit — the control is not painted and takes
//! no cells: `width` is 0 and `draw` paints nothing.
//!
//! The ladder for a short strip: the whole ` ‹ 3/7 › `, then the arrows
//! alone, then nothing (`fit`). The caller decides how much room the
//! control may have; the control decides what fits in it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");

const Style = vaxis.Style;

/// What a stepper shows and the two `.button` ids its arrows register.
/// `index` counts from zero.
pub const Stepper = struct {
    index: usize,
    count: usize,
    prev: u32,
    next: u32,
};

/// How much of the control a strip has room for.
pub const Form = enum { none, arrows, full };

/// ` ‹ ` / ` › ` — one arrow, a button's width.
pub const button_w: u16 = 3;
pub const prev_glyph = "\u{2039}";
pub const next_glyph = "\u{203A}";
pub const prev_ascii = "<";
pub const next_ascii = ">";

/// Whether there is anything to step: two or more.
pub fn shown(s: Stepper) bool {
    return s.count > 1;
}

/// The ` 3/7 ` between the arrows.
pub fn label(ui: Ui, s: Stepper) []const u8 {
    return ui.fmt("{d}/{d}", .{ s.index + 1, s.count });
}

/// The cells `form` takes; 0 when there is nothing to step.
pub fn width(ui: Ui, s: Stepper, form: Form) u16 {
    if (!shown(s)) return 0;
    return switch (form) {
        .none => 0,
        .arrows => 2 * button_w,
        .full => 2 * button_w + ui.width(label(ui, s)),
    };
}

/// The widest form that fits in `room` cells; `.none` when nothing does
/// or there is nothing to step.
pub fn fit(ui: Ui, s: Stepper, room: u16) Form {
    if (!shown(s)) return .none;
    for ([_]Form{ .full, .arrows }) |form| if (width(ui, s, form) <= room) return form;
    return .none;
}

/// Paint `form` from `x0`, clipped at `right`; returns the cells used.
pub fn draw(ui: Ui, x0: u16, y: u16, right: u16, s: Stepper, form: Form) u16 {
    if (!shown(s) or form == .none) return 0;
    const p = ui.theme.palette;
    const bg = p.bg_darker;
    var x = x0;
    if (x + button_w > right) return 0;
    arrow(ui, x, y, if (ui.ascii) prev_ascii else prev_glyph, s.prev);
    x += button_w;
    if (form == .full) x += ui.putStr(x, y, right -| x, label(ui, s), .{ .fg = p.comment, .bg = bg });
    if (x + button_w > right) return x - x0;
    arrow(ui, x, y, if (ui.ascii) next_ascii else next_glyph, s.next);
    x += button_w;
    return x - x0;
}

/// One arrow: its cell, lit under the pointer, and its hit.
fn arrow(ui: Ui, x: u16, y: u16, glyph: []const u8, id: u32) void {
    const p = ui.theme.palette;
    const r = Rect.init(x, y, button_w, 1);
    const style: Style = if (ui.hovered(r)) .{ .fg = p.fg, .bg = p.bg2, .bold = true } else .{ .fg = p.fg, .bg = p.bg_darker, .bold = true };
    ui.fill(r, .{ .bg = style.bg });
    _ = ui.putStr(x + 1, y, 1, glyph, style);
    ui.hit(r, .{ .button = id });
}

// ─── tests ──────────────────────────────────────────────────────────────

const Fixture = @import("test_fixture.zig");

test "the stepper: ` ‹ 3/7 › ` with a button per arrow; the arrows alone when short; nothing at all with one to step" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const ui = f.ui();
    const s: Stepper = .{ .index = 2, .count = 7, .prev = 10, .next = 11 };
    try std.testing.expectEqual(Form.full, fit(ui, s, 9));
    try std.testing.expectEqual(Form.arrows, fit(ui, s, 8));
    try std.testing.expectEqual(Form.none, fit(ui, s, 5));
    try std.testing.expectEqual(@as(u16, 9), draw(ui, 2, 0, 40, s, .full));
    try f.expectContains(" " ++ prev_glyph ++ " 3/7 " ++ next_glyph);
    try std.testing.expectEqual(@as(?u32, 10), buttonAt(&f, 2, 0));
    try std.testing.expectEqual(@as(?u32, 11), buttonAt(&f, 10, 0));
    // The number between the arrows is no target.
    try std.testing.expectEqual(@as(?u32, null), buttonAt(&f, 6, 0));
    // One to step: no cells, no hits, whatever room there is.
    const one: Stepper = .{ .index = 0, .count = 1, .prev = 12, .next = 13 };
    try std.testing.expectEqual(Form.none, fit(ui, one, 40));
    try std.testing.expectEqual(@as(u16, 0), width(ui, one, .full));
    try std.testing.expectEqual(@as(u16, 0), draw(ui, 20, 0, 40, one, .full));
    try std.testing.expectEqual(@as(?u32, null), buttonAt(&f, 20, 0));
}

fn buttonAt(f: *Fixture, x: u16, y: u16) ?u32 {
    const h = f.hits.at(x, y) orelse return null;
    return if (h == .button) h.button else null;
}
