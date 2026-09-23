//! The focus cue — how the chrome says which pane or section has the
//! keys (`ui.focus_cue`). Focus was easy to misread between the tree, a
//! side section, an editor and a session pane: a `:` meant for an
//! editor went to the tree and ran tree actions. The rule is one place,
//! and the components that paint a pane's or a section's identity ask
//! it rather than each deciding:
//!
//! - `dim`: every pane that does NOT have the keys paints its tab
//!   strip's active name — the pane's title row — in the dim colour
//!   role, and so does a side section's header (the tree's workspace
//!   path; a caps header is in that role already, and the focused one
//!   steps up to the full foreground).
//! - `rail`: the words are left alone; the focused pane's rail keeps
//!   its full accent while every other pane's steps back toward the
//!   ground, and the focused section's caps header takes the accent.
//! - `both` (the default): the two at once.
//!
//! Colours are theme roles — `palette.comment` is the dim role, the
//! accent the lit one — so a theme changes the cue with everything
//! else. Draw through `bufferline` (the strip), `render.drawPaneContent`
//! (the rail), `header` (a caps header) and `tree_view` (the workspace
//! header); nothing else paints a focus cue.

const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("theme.zig");
const diff_view = @import("diff_view.zig");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

pub const Cue = enum { rail, dim, both };

/// Whether the cue dims what does not have the keys.
pub fn dims(cue: Cue) bool {
    return cue != .rail;
}

/// Whether the cue lights what does.
pub fn lights(cue: Cue) bool {
    return cue != .dim;
}

/// How much of an unfocused pane's accent is left over its ground
/// (of 255): enough to still tell two panes' colours apart, little
/// enough that the focused one is plainly the bright one.
pub const rail_alpha: u16 = 96;

/// A pane's or a section's own words — the active tab's name, the
/// tree's workspace path: as given while it has the keys (or when the
/// cue does not dim), in the dim role and not bold otherwise.
pub fn words(t: *const Theme, cue: Cue, focused: bool, s: Style) Style {
    if (focused or !dims(cue)) return s;
    var out = Theme.withFg(s, t.palette.comment);
    out.bold = false;
    return out;
}

/// A pane rail's colour: the accent on the focused pane (and on every
/// pane when the cue does not light), the accent stepped back toward
/// `ground` on the rest. A colour that is not rgb cannot be blended
/// and falls back to the dim role.
pub fn rail(t: *const Theme, cue: Cue, focused: bool, accent: Color, ground: Color) Color {
    if (focused or !lights(cue)) return accent;
    return diff_view.blendOver(accent, ground, rail_alpha, t.palette.comment);
}

/// A caps header's label (`header.zig`). Unfocused, the label keeps the
/// dim role it always has; focused, it takes the accent when the cue
/// lights and the full foreground when it only dims.
pub fn label(t: *const Theme, cue: Cue, focused: bool, s: Style) Style {
    if (!focused) return s;
    return Theme.withFg(s, if (lights(cue)) t.accent.fg else t.fg.fg);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "words: dim and both put an unfocused pane's words in the dim role; rail and the focused pane leave them" {
    const t = &Theme.default;
    const s = Style{ .fg = t.palette.fg, .bg = t.palette.bg, .bold = true };
    for ([_]Cue{ .dim, .both }) |c| {
        const out = words(t, c, false, s);
        try testing.expect(Color.eql(out.fg, t.palette.comment));
        try testing.expect(!out.bold);
        try testing.expect(Color.eql(out.bg, s.bg));
        try testing.expect(std.meta.eql(words(t, c, true, s), s));
    }
    try testing.expect(std.meta.eql(words(t, .rail, false, s), s));
}

test "rail: rail and both step an unfocused pane's accent back toward its ground; dim and the focused pane keep it" {
    const t = &Theme.default;
    const accent = t.palette.blue;
    const ground = t.palette.bg_dark;
    for ([_]Cue{ .rail, .both }) |c| {
        const back = rail(t, c, false, accent, ground);
        try testing.expect(!Color.eql(back, accent));
        try testing.expect(!Color.eql(back, ground));
        try testing.expect(Color.eql(rail(t, c, true, accent, ground), accent));
    }
    try testing.expect(Color.eql(rail(t, .dim, false, accent, ground), accent));
    // An indexed colour cannot be blended: the dim role stands in.
    try testing.expect(Color.eql(rail(t, .both, false, .{ .index = 15 }, ground), t.palette.comment));
}

test "label: the focused header lights in the accent (rail, both) or the full foreground (dim); an unfocused one keeps its role" {
    const t = &Theme.default;
    const s = Theme.onBg(t.muted, t.palette.bg_darker);
    try testing.expect(Color.eql(label(t, .both, true, s).fg, t.accent.fg));
    try testing.expect(Color.eql(label(t, .rail, true, s).fg, t.accent.fg));
    try testing.expect(Color.eql(label(t, .dim, true, s).fg, t.fg.fg));
    for ([_]Cue{ .rail, .dim, .both }) |c| try testing.expect(std.meta.eql(label(t, c, false, s), s));
}
