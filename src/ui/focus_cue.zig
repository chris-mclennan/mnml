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
//! else. Where a theme's roles would make the cue invisible (a light
//! theme's comment grey on its ground, or a step-back that sinks into
//! it) the colour is derived from the theme's own contrast instead
//! (`contrast.zig`): never below `floor`:1 against the ground, the
//! pane's hue kept. Draw through `bufferline` (the strip), `render.drawPaneContent`
//! (the rail), `header` (a caps header) and `tree_view` (the workspace
//! header); nothing else paints a focus cue.

const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("theme.zig");
const diff_view = @import("diff_view.zig");
const contrast = @import("contrast.zig");

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
/// enough that the focused one is plainly the bright one. A theme whose
/// ground would swallow that much of a step gets less of one (`floor`).
pub const rail_alpha: u16 = 96;

/// The least contrast a dimmed word or a stepped-back rail keeps
/// against its ground, in every theme: under it a light theme's
/// unfocused pane lost its name and its colour (1.1–1.5:1).
pub const floor: f64 = 2.0;

/// How far the dim role sits from the words it dims before the palette's
/// own dim colour will do: under it the two read as one colour (1.09:1
/// in catppuccin-latte) and the cue says nothing.
pub const apart: f64 = 1.5;

/// The least contrast a pane's own words keep while it has the keys.
/// A palette whose `white` is a pale accent (catppuccin-latte's lavender,
/// 2.2:1 on its ground) leaves no room below it for a dim that still
/// reads, so the focused words step up toward the theme's text colour.
pub const focused_floor: f64 = 3.0;

/// A pane's or a section's own words — the active tab's name, the
/// tree's workspace path: as given while it has the keys (or when the
/// cue does not dim) — stepped up to `focused_floor` when the palette
/// leaves them fainter — and in the dim role, not bold, otherwise.
pub fn words(t: *const Theme, cue: Cue, focused: bool, s: Style) Style {
    if (!dims(cue)) return s;
    const lit = Theme.withFg(s, litWords(t, s.fg, s.bg));
    if (focused) return lit;
    var out = Theme.withFg(s, dimWords(t, lit.fg, s.bg));
    out.bold = false;
    return out;
}

/// The words at `fg` on `ground`, raised toward the theme's text colour
/// (whichever of `fg` and base16 `05` stands out more) until they clear
/// `focused_floor`; as given when they already do.
pub fn litWords(t: *const Theme, fg: Color, ground: Color) Color {
    const have = contrast.ratio(fg, ground) orelse return fg;
    if (have >= focused_floor) return fg;
    const text = t.palette.base16[5];
    const toward = if ((contrast.ratio(text, ground) orelse 0) > have) text else return fg;
    var a: u16 = 0;
    while (a <= 255) : (a += 5) {
        const c = contrast.blend(toward, fg, a).?;
        if (contrast.ratio(c, ground).? >= focused_floor) return c;
    }
    return toward;
}

/// The dim role for words at `fg` on `ground`: the palette's own dim
/// colour (`comment`) when it clears `floor` on the ground and sits
/// `apart` from the words; else the words themselves stepped back toward
/// the ground as far as `floor` allows — the most a light ground can
/// give, in the words' own hue.
pub fn dimWords(t: *const Theme, fg: Color, ground: Color) Color {
    const c = t.palette.comment;
    const on_ground = contrast.ratio(c, ground) orelse return c;
    const from_words = contrast.ratio(c, fg) orelse return c;
    if (on_ground >= floor and from_words >= apart) return c;
    return contrast.stepBack(fg, ground, 0, floor) orelse c;
}

/// A pane rail's colour: the accent on the focused pane (and on every
/// pane when the cue does not light), the accent stepped back toward
/// `ground` on the rest — `rail_alpha` of it, or more where that would
/// sink under `floor`:1 on the ground. A colour that is not rgb cannot
/// be blended and falls back to the dim role.
pub fn rail(t: *const Theme, cue: Cue, focused: bool, accent: Color, ground: Color) Color {
    if (focused or !lights(cue)) return accent;
    return contrast.stepBack(accent, ground, rail_alpha, floor) orelse diff_view.blendOver(accent, ground, rail_alpha, t.palette.comment);
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
