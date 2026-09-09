//! The expander — the fold marker of a collapsible row or section: the
//! tree's workspace headers and folders, the git panel's LOCAL / REMOTE
//! / WORKTREES / STASHES / TAGS, the DEBUG section's VARIABLES / WATCH /
//! CALL STACK / BREAKPOINTS and its scopes, the HTTP section's headers
//! and collections, a grep group, a sessions-table group. One glyph
//! pair, one colour, one slot width — every panel paints its expander
//! through here, so none can drift to a triangle of its own.
//!
//! The glyphs are the Octicons chevrons neo-tree uses and the Rust tree
//! paints (nf-oct-chevron_down / chevron_right, U+F47C / U+F460), `v` /
//! `>` under `--ascii` or without a Nerd Font, and the small triangles
//! under `ui.expand_indicator = .triangle`. The colour is the tree's
//! section-header chevron: `theme.muted.fg`, the palette's `comment`
//! grey. A slot is the glyph and one cell of air after it.
//!
//! Not an expander: a chip's dropdown mark (the sort chip, the repo
//! pill), a menu row's submenu mark, a focus marker, the debugger's
//! current-frame mark, a run glyph. Those keep their own glyphs.

const std = @import("std");
const vaxis = @import("vaxis");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

pub const Style = vaxis.Style;

/// nf-oct-chevron_down / nf-oct-chevron_right.
pub const open_glyph = "\u{F47C}";
pub const open_ascii = "v";
pub const closed_glyph = "\u{F460}";
pub const closed_ascii = ">";
/// `ui.expand_indicator = .triangle`: the small triangles.
pub const open_triangle = "\u{25BE}";
pub const closed_triangle = "\u{25B8}";

/// The cells a slot takes: the glyph and a cell of air.
pub const slot_w: u16 = 2;

/// The glyph alone.
pub fn glyph(ui: Ui, expanded: bool) []const u8 {
    if (ui.ascii or !ui.nerd_font) return if (expanded) open_ascii else closed_ascii;
    if (ui.triangle) return if (expanded) open_triangle else closed_triangle;
    return if (expanded) open_glyph else closed_glyph;
}

/// The glyph with its cell of air — what a row paints in its slot.
pub fn slot(ui: Ui, expanded: bool) []const u8 {
    if (ui.ascii or !ui.nerd_font) return if (expanded) open_ascii ++ " " else closed_ascii ++ " ";
    if (ui.triangle) return if (expanded) open_triangle ++ " " else closed_triangle ++ " ";
    return if (expanded) open_glyph ++ " " else closed_glyph ++ " ";
}

/// `base` with the expander's colour: the tree's section-header grey.
pub fn style(ui: Ui, base: Style) Style {
    return Theme.withFg(base, ui.theme.muted.fg);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "one codepoint per glyph; the slot is the glyph and a cell of air; ascii, no Nerd Font and the triangle setting pick their twins" {
    inline for (.{ open_glyph, closed_glyph, open_triangle, closed_triangle }) |g| {
        try testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(g));
    }
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    var ui = f.ui();
    try testing.expectEqualStrings(open_glyph, glyph(ui, true));
    try testing.expectEqualStrings(closed_glyph, glyph(ui, false));
    try testing.expectEqualStrings(open_glyph ++ " ", slot(ui, true));
    try testing.expectEqual(slot_w, ui.width(slot(ui, false)));
    ui.triangle = true;
    try testing.expectEqualStrings(open_triangle, glyph(ui, true));
    try testing.expectEqualStrings(closed_triangle ++ " ", slot(ui, false));
    ui.triangle = false;
    ui.nerd_font = false;
    try testing.expectEqualStrings("v", glyph(ui, true));
    ui.nerd_font = true;
    ui.ascii = true;
    try testing.expectEqualStrings("> ", slot(ui, false));
    try testing.expectEqualStrings("v", glyph(ui, true));
    // The colour is the tree's section-header grey: `muted.fg` is the
    // palette's `comment`.
    const s = style(ui, .{ .bg = f.theme.bg.bg });
    try testing.expect(vaxis.Color.eql(s.fg, f.theme.muted.fg));
    try testing.expect(vaxis.Color.eql(s.fg, f.theme.palette.comment));
    try testing.expect(vaxis.Color.eql(s.bg, f.theme.bg.bg));
}
