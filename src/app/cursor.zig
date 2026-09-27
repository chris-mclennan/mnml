//! The terminal cursor — who owns it, and what shape it wears.
//!
//! A frame paints cells; the cursor is not one of them. It sits above
//! every painted cell, the host terminal draws it, and there is exactly
//! one. So the rule cannot be "whoever feels like it sets
//! `screen.cursor_vis`" — two surfaces that both want it would fight,
//! and one that quietly leaves it on paints a caret over the box that
//! covered it.
//!
//! The rule instead is: **draw order is the precedence**. Every surface
//! that takes typing hands its caret to `App.cursor_pos` as it draws,
//! and the panes draw first, then the chrome rows (the find bar, the
//! `:` line), then the overlays. Whatever is still standing when the
//! frame ends is the frontmost thing the typing reaches, and that is
//! the one the cursor goes on. `render` reads it once, at the end, and
//! is the only place that touches `Screen.cursor_vis` / `cursor` /
//! `cursor_shape`.
//!
//! The one thing draw order does not answer is the overlay that paints
//! a box and takes NO typing — a menu, the which-key popup, a confirm,
//! settings, the wizard, help. Those leave the pane underneath holding
//! the caret, and the cursor would be drawn on top of the box. `blocks`
//! names them, and `resolve` hides the cursor when one is up.
//!
//! Shape: the vim shapes, from the editing mode — block in NORMAL and
//! VISUAL, a bar in INSERT, an underline in REPLACE. A text field is
//! always a bar; standard (modeless) editing is a bar too, because it
//! is an insert caret the whole time. `ui.cursor_shape` overrides all
//! of that with one fixed shape, and `editor.cursor_blink` picks the
//! blinking DECSCUSR variant — the terminal owns the clock, mnml has
//! none.
//!
//! A terminal pane is the exception both ways: its child asked for a
//! shape and a blink over DECSCUSR, and those reach the host as they
//! came (`ui.pty_cursor` is that pane's own setting). Overriding the
//! child would make vim-inside-a-terminal-pane lie about its mode.

const std = @import("std");
const vaxis = @import("vaxis");
const editor_view = @import("../ui/editor_view.zig");
const Overlay = @import("../app.zig").Overlay;
const EditingMode = @import("../input/mod.zig").EditingMode;

/// The same three shapes the editor already names for its own caret,
/// so a pane hands its shape straight over with no translation.
pub const Shape = editor_view.CursorShape;

/// What the user asked for in `ui.cursor_shape`. `terminal` is the
/// default and means "follow the mode", which is what every other
/// value opts out of.
pub const Pref = enum { terminal, block, bar, underline };

/// One frame's cursor: where it goes and how it looks.
pub const Want = struct {
    pos: editor_view.Cursor,
    shape: Shape = .bar,
    blink: bool = false,
    /// The child of a terminal pane asked for this one; `Pref` does not
    /// apply to it.
    from_child: bool = false,
};

/// Everything outside the frame's own collection that changes the
/// answer.
pub const Ctx = struct {
    /// An overlay that paints a box and takes no typing is up.
    blocked: bool = false,
    pref: Pref = .terminal,
};

/// The overlays that cover the pane without taking its typing. The
/// prompt and the picker are the two that do take it — their field
/// hands its own caret to the frame, so they must not be here.
pub fn blocks(overlay: std.meta.Tag(Overlay), menu_bar_open: bool, operator_popup: bool) bool {
    if (menu_bar_open or operator_popup) return true;
    return switch (overlay) {
        .none, .prompt, .picker => false,
        .confirm, .which_key, .menu, .settings, .wizard, .info, .discovery, .help, .jobs => true,
    };
}

/// The one rule, in one place: the frame's collected caret, hidden
/// under a box that takes no typing, and re-shaped when the user has
/// asked for one fixed shape.
pub fn resolve(want: ?Want, ctx: Ctx) ?Want {
    const w = want orelse return null;
    if (ctx.blocked) return null;
    if (w.from_child or ctx.pref == .terminal) return w;
    var out = w;
    out.shape = switch (ctx.pref) {
        .terminal => unreachable,
        .block => .block,
        .bar => .bar,
        .underline => .underline,
    };
    return out;
}

/// The DECSCUSR the host gets. vaxis writes it; the blink is the
/// terminal's own clock, so mnml never runs one.
pub fn decscusr(shape: Shape, blink: bool) vaxis.Cell.CursorShape {
    return switch (shape) {
        .block => if (blink) .block_blink else .block,
        .bar => if (blink) .beam_blink else .beam,
        .underline => if (blink) .underline_blink else .underline,
    };
}

/// The editor's shape while an operator waits for its motion: Neovim's
/// default `guicursor` has `o:hor20` (NvChad keeps it) — an underline.
pub fn forModeOp(mode: EditingMode, operator_pending: bool) Shape {
    if (operator_pending) return .underline;
    return forMode(mode);
}

/// Whether the cursor sits on the last cell of a Tab's span: Neovim's
/// Normal and Visual modes (`wincol()` on a Tab at ts=4 / 8 is 4 / 8);
/// Insert, Replace and the modeless profile sit on its first cell.
pub fn onTabEnd(mode: EditingMode) bool {
    return switch (mode) {
        .normal, .visual, .visual_line, .visual_block => true,
        .insert, .replace, .none => false,
    };
}

/// The editor's shape for an editing mode. Modeless (`none`) editing is
/// an insert caret the whole time, so it is a bar.
pub fn forMode(mode: EditingMode) Shape {
    return switch (mode) {
        .insert, .none => .bar,
        .replace => .underline,
        else => .block,
    };
}

// ── tests ──

const t = std.testing;

test "no caret this frame means no cursor" {
    try t.expect(resolve(null, .{}) == null);
}

test "a box that takes no typing hides the caret under it" {
    const w: Want = .{ .pos = .{ .x = 3, .y = 4 } };
    try t.expectEqual(@as(?Want, w), resolve(w, .{}));
    try t.expect(resolve(w, .{ .blocked = true }) == null);
}

test "blocks: the prompt and the picker take typing; the rest cover it" {
    try t.expect(!blocks(.none, false, false));
    try t.expect(!blocks(.prompt, false, false));
    try t.expect(!blocks(.picker, false, false));
    try t.expect(blocks(.confirm, false, false));
    try t.expect(blocks(.which_key, false, false));
    try t.expect(blocks(.menu, false, false));
    try t.expect(blocks(.settings, false, false));
    try t.expect(blocks(.wizard, false, false));
    try t.expect(blocks(.info, false, false));
    try t.expect(blocks(.discovery, false, false));
    try t.expect(blocks(.help, false, false));
    // A menu-bar dropdown and the vim operator popup leave `overlay`
    // alone but still paint over the pane.
    try t.expect(blocks(.none, true, false));
    try t.expect(blocks(.none, false, true));
}

test "ui.cursor_shape overrides the mode's shape" {
    const w: Want = .{ .pos = .{ .x = 1, .y = 1 }, .shape = .block };
    try t.expectEqual(Shape.block, resolve(w, .{ .pref = .terminal }).?.shape);
    try t.expectEqual(Shape.bar, resolve(w, .{ .pref = .bar }).?.shape);
    try t.expectEqual(Shape.underline, resolve(w, .{ .pref = .underline }).?.shape);
    try t.expectEqual(Shape.block, resolve(.{ .pos = .{ .x = 1, .y = 1 }, .shape = .bar }, .{ .pref = .block }).?.shape);
}

test "a terminal pane's child keeps the shape it asked for" {
    const w: Want = .{ .pos = .{ .x = 1, .y = 1 }, .shape = .underline, .blink = true, .from_child = true };
    const got = resolve(w, .{ .pref = .block }).?;
    try t.expectEqual(Shape.underline, got.shape);
    try t.expect(got.blink);
}

test "the vim shapes come off the mode" {
    try t.expectEqual(Shape.block, forMode(.normal));
    try t.expectEqual(Shape.block, forMode(.visual));
    try t.expectEqual(Shape.block, forMode(.visual_line));
    try t.expectEqual(Shape.block, forMode(.visual_block));
    try t.expectEqual(Shape.bar, forMode(.insert));
    try t.expectEqual(Shape.underline, forMode(.replace));
    // Standard (modeless) editing: a bar, always.
    try t.expectEqual(Shape.bar, forMode(.none));
}

test "decscusr: blink picks the blinking variant, and only that" {
    try t.expectEqual(vaxis.Cell.CursorShape.block, decscusr(.block, false));
    try t.expectEqual(vaxis.Cell.CursorShape.block_blink, decscusr(.block, true));
    try t.expectEqual(vaxis.Cell.CursorShape.beam, decscusr(.bar, false));
    try t.expectEqual(vaxis.Cell.CursorShape.beam_blink, decscusr(.bar, true));
    try t.expectEqual(vaxis.Cell.CursorShape.underline, decscusr(.underline, false));
    try t.expectEqual(vaxis.Cell.CursorShape.underline_blink, decscusr(.underline, true));
}

test "onTabEnd: Normal and Visual sit on a Tab's last cell; Insert, Replace and modeless on its first" {
    try std.testing.expect(onTabEnd(.normal) and onTabEnd(.visual) and onTabEnd(.visual_line) and onTabEnd(.visual_block));
    try std.testing.expect(!onTabEnd(.insert) and !onTabEnd(.replace) and !onTabEnd(.none));
}
